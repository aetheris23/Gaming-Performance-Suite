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

param([string]$Root = $PSScriptRoot)

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
    $state = [SuiteVoice.MicNoiseSuppression]::Enable()

    $msg = switch ($state) {
        'enabled'          { 'Mic DSP host engaged.' }
        'already-running'  { 'Mic DSP host already running.' }
        'no-effects-manager'{ 'Mic DSP: endpoint exposes no effects manager (no DSP). Exiting.' }
        'no-default-capture'{ 'Mic DSP: no default capture device found.' }
        default            { "Mic DSP host exited ($state)." }
    }
    Write-Log $msg 'INFO'

    if ($state -ne 'enabled' -and $state -ne 'already-running') { exit 0 }

    # Raise our own scheduling priority for the audio capture thread path.
    try { (Get-Process -Id $PID).PriorityClass = 'AboveNormal' } catch { }

    # Keep the stream alive until told to stop.
    $stopSeen = $false
    $deadline = [datetime]::UtcNow.AddHours(24)
    while (-not $stopSeen -and [datetime]::UtcNow -lt $deadline) {
        $stopSeen = (Test-Path $stopFile)
        if (-not $stopSeen) { Start-Sleep -Milliseconds 500 }
    }

    [SuiteVoice.MicNoiseSuppression]::Disable()
    Write-Log 'Mic DSP host released.' 'INFO'
}
catch {
    try { [SuiteVoice.MicNoiseSuppression]::Disable() } catch { }
    Write-Log ("Mic DSP host error: {0}" -f $_.Exception.Message) 'ERROR'
}
