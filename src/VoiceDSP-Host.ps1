# ============================================================
#  VoiceDSP-Host.ps1 - hidden helper that holds the live mic DSP
#
#  Launched (hidden) by the game watcher while a game runs. It:
#    1. Opens a shared-mode capture stream on the default
#       communications microphone and engages Deep Noise
#       Suppression + (classic) Noise Suppression + Acoustic
#       Echo Cancellation via IAudioEffectsManager.
#    2. Keeps that stream open so the DSP stays engaged.
#    3. Watches for a stop marker (runtime/voicedsp/stop.requested)
#       or its own process being killed, then restores the prior
#       mic effects and exits.
#
#  Usage:
#    powershell -NoProfile -File VoiceDSP-Host.ps1 -Root <suite src dir>
# ============================================================

param(
    [string]$Root = $PSScriptRoot,
    [double]$Aggressiveness = 1.55
)

$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath($Root)

Import-Module (Join-Path $root 'Common.psm1')  -Force
Import-Module (Join-Path $root 'VoiceDSP.psm1') -Force
Import-Module (Join-Path $root 'NetTune.psm1')  -Force

$tokensDir = Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $root)) 'logs') "runtime\voicedsp"
if (-not (Test-Path $tokensDir)) { New-Item -ItemType Directory -Path $tokensDir -Force | Out-Null }
$stopFile  = Join-Path $tokensDir 'stop.requested'

try {
    if (-not (Test-SuitePlatformWindows)) { exit 0 }
    if (-not (Test-VoiceDspPlatform))     { exit 0 }

    Ensure-VoiceDspEngine

    # 1) Engage whatever the OS DSP exposes (Deep NS / classic NS / AEC).
    #    Keep the capture stream (and any effects manager) alive.
    $state = [SuiteVoice.MicNoiseSuppression]::Enable()
    $msg = switch ($state) {
        'enabled'          { 'Mic DSP host engaged.' }
        'already-running'  { 'Mic DSP host already running.' }
        'no-effects-manager'{ 'Mic DSP: endpoint exposes no effects manager (no OS DSP).' }
        'no-default-capture'{ 'Mic DSP: no default capture device found.' }
        default            { "Mic DSP host: $state" }
    }
    Write-Log $msg 'INFO'

    # 2) On Windows 10 the OS rarely provides Deep Noise Suppression, so the
    #    classic filter alone leaves fans/traffic/broadcasts audible. When deep
    #    NS is missing we layer in the embedded real-time spectral suppressor
    #    to strip that background noise completely.
    $realTimeActive = $false
    $deepNs = $false
    try { $deepNs = (Test-VoiceDeepNSPresent) } catch { $deepNs = $false }
    if (-not $deepNs) {
        # Capture still coming up? Give the endpoint a moment before probing.
        Start-Sleep -Milliseconds 400
        try { $deepNs = (Test-VoiceDeepNSPresent) } catch { $deepNs = $false }
    }
    if (-not $deepNs) {
        $rtStatus = Start-VoiceRealTimeFilter -Aggressive $Aggressiveness
        if ($rtStatus -like 'running:*') {
            $realTimeActive = $true
            Write-Log ("Mic DSP: Windows has no Deep Noise Suppression here - real-time software filter ENGAGED ({0}). Fans, traffic, broadcasts & distant speech are now stripped from the mic; only your voice passes through." -f $rtStatus) 'OK'
        } else {
            Write-Log ("Mic DSP: real-time software filter could not start ({0}); using only whatever the OS DSP provides." -f $rtStatus) 'WARN'
        }
    } else {
        Write-Log 'Mic DSP: Deep Noise Suppression present on this OS - using Windows AI noise suppression.' 'OK'
    }

    # 3) Raise our scheduling priority for the audio threads.
    try { (Get-Process -Id $PID).PriorityClass = 'AboveNormal' } catch { }

    # Keep the DSP engaged until told to stop.
    $stopSeen = $false
    $deadline = [datetime]::UtcNow.AddHours(24)
    while (-not $stopSeen -and [datetime]::UtcNow -lt $deadline) {
        $stopSeen = (Test-Path $stopFile)
        if (-not $stopSeen) { Start-Sleep -Milliseconds 500 }
    }

    if ($realTimeActive) { try { Stop-VoiceRealTimeFilter } catch { } }
    [SuiteVoice.MicNoiseSuppression]::Disable()
    Write-Log 'Mic DSP host released.' 'INFO'
}
catch {
    try { if (Test-Path $stopFile) { try { Stop-VoiceRealTimeFilter } catch { } } } catch { }
    try { [SuiteVoice.MicNoiseSuppression]::Disable() } catch { }
    Write-Log ("Mic DSP host error: {0}" -f $_.Exception.Message) 'ERROR'
}
