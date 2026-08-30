# ============================================================
#  Main.ps1 - Gaming Performance Suite entry point
#
#  Interactive menu:      Start-GamingSuite.bat
#  Hidden background run: Start-Watcher-Hidden.bat
#                         (equivalent: powershell -File src\Main.ps1 -BackgroundWatch)
#  Stop the background watcher at any time: Stop-GamingSuite.bat
#
#  The watcher journals every change it makes and auto-repairs
#  any unclean shutdown (kill / crash / closed console) on the
#  next start or stop - see Common.psm1 Repair-OrphanedWatcherState.
# ============================================================

param([switch]$BackgroundWatch)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $root 'Common.psm1')    -Force
Import-Module (Join-Path $root 'GpuDetect.psm1') -Force
Import-Module (Join-Path $root 'GameBoost.psm1') -Force
Import-Module (Join-Path $root 'DisplayScale.psm1') -Force
Import-Module (Join-Path $root 'NetTune.psm1')   -Force
Import-Module (Join-Path $root 'ColorCorrect.psm1') -Force
Import-Module (Join-Path $root 'VoiceDSP.psm1')  -Force

# Load user config with safe fallbacks
$cfgPath = Join-Path $root 'Config.ps1'
$cfg = if (Test-Path $cfgPath) { & $cfgPath } else { @{} }
$gameNames  = if ($cfg['GameProcesses'])      { $cfg['GameProcesses'] }      else { @('VALORANT-Win64','pcsx2','cs2') }
$pollSecs   = if ($cfg['WatcherPollSeconds']) { [int]$cfg['WatcherPollSeconds'] } else { 10 }
$ramFloorMB = if ($cfg['FreeRamThresholdMB']) { [int]$cfg['FreeRamThresholdMB'] } else { 2048 }
$profOv     = if ($cfg['ProfileOverrides'])   { $cfg['ProfileOverrides'] }   else { @{} }

# Stutter-safe standby-purge policy (see Config.ps1 for details)
$idleSecs     = if ($cfg['IdlePollSeconds'])             { [int]$cfg['IdlePollSeconds'] }             else { 25 }
$extIdleSecs  = if ($cfg['ExtendedIdlePollSeconds'])      { [int]$cfg['ExtendedIdlePollSeconds'] }      else { 60 }
$heartbeatMin = if ($cfg['IdleHeartbeatMinutes'])         { [int]$cfg['IdleHeartbeatMinutes'] }         else { 5 }
$critFloorMB  = if ($cfg['CriticalRamFloorMB'])          { [int]$cfg['CriticalRamFloorMB'] }          else { 768 }
$purgeCoolSec = if ($cfg['StandbyPurgeCooldownSeconds']) { [int]$cfg['StandbyPurgeCooldownSeconds'] } else { 900 }
$purgeLaunch  = if ($null -ne $cfg['PurgeOnGameLaunch']) { [bool]$cfg['PurgeOnGameLaunch'] }          else { $true }

# Pre-game optimization (applies tweaks before game process appears)
$preGameOpt   = if ($null -ne $cfg['PreGameOptimization'])   { [bool]$cfg['PreGameOptimization'] }   else { $true }
$prePurge     = if ($null -ne $cfg['PrePurgeBeforeLaunch'])  { [bool]$cfg['PrePurgeBeforeLaunch'] }  else { $true }

$resSettings = @{
    ScalePercent      = if ($cfg['ResolutionScalePercent']) { [int]$cfg['ResolutionScalePercent'] } else { 66 }
    PreferIntegerScale= if ($null -ne $cfg['PreferIntegerScale']) { [bool]$cfg['PreferIntegerScale'] } else { $true }
    Tiers             = if ($cfg['ResolutionTiers'])      { $cfg['ResolutionTiers'] }      else { @{ Low = 55; Medium = 75; High = 88; Native = 0 } }
    ProfileTiers      = if ($cfg['ProfileTiers'])         { $cfg['ProfileTiers'] }         else { @{ Emulator = 'Medium'; Steam = 'Medium'; Competitive = 'Low'; Android = 'Medium'; Default = 'Medium' } }
    GameTierOverrides = if ($cfg['GameTierOverrides'])    { $cfg['GameTierOverrides'] }    else { @{} }
}
# Session lifecycle: after the last monitored game closes, the watcher
# undoes every change and exits completely instead of staying resident
# and polling for a "next game" in the background.
$exitWhenGameEnds = if ($null -ne $cfg['ExitWhenGameSessionEnds']) { [bool]$cfg['ExitWhenGameSessionEnds'] } else { $true }
$fgSettings = if ($cfg['FrameGeneration']) { $cfg['FrameGeneration'] } else { @{ Enabled = $false; ToolPath = '' } }
$lgsCfg     = if ($cfg['LegacyGpuSupport']) { $cfg['LegacyGpuSupport'] } else { @{ Mode = 'Auto' } }
$netCfg     = if ($cfg['NetworkOptimization']) { $cfg['NetworkOptimization'] } else { @{ Enabled = $true } }
$voiceCfg   = if ($cfg['VoiceClarity'])        { $cfg['VoiceClarity'] }        else { @{} }
$nsCfg      = if ($cfg['NoiseSuppression'])     { $cfg['NoiseSuppression'] }     else { @{ Enabled = $false } }
$lowSpecCfg = if ($cfg['LowSpecMode'])         { $cfg['LowSpecMode'] }         else { @{ Enabled = $false } }
$colorCfg   = if ($cfg['ColorCorrection'])     { $cfg['ColorCorrection'] }     else { @{ Enabled = $false; Mode = 'Off' } }

# Apply LowSpec polling overrides early
if ($null -ne $lowSpecCfg -and $lowSpecCfg['Enabled']) {
    if ($lowSpecCfg['ReducedPolling']) {
        $pollSecs = [Math]::Max($pollSecs, 15)
        $idleSecs = [Math]::Max($idleSecs, 35)
    }
}

# ---------------- legacy GPU profile resolution ----------------
function Resolve-LegacySettings {
    <#
        Combines Config.ps1 LegacyGpuSupport with runtime GPU detection
        (src/GpuDetect.psm1). Mode 'auto' -> Test-LegacyGpuPresent decides;
        'on' / 'off' force the outcome. Explicit per-key values in the
        config always win over what Auto would pick.
    #>
    $mode = 'auto'
    if ($lgsCfg['Mode']) { $mode = ([string]$lgsCfg['Mode']).ToLowerInvariant() }

    $isLegacy = $false
    try {
        if     ($mode -eq 'on')  { $isLegacy = $true }
        elseif ($mode -ne 'off') { $isLegacy = Test-LegacyGpuPresent }
    } catch { }

    # Also treat LowSpecMode's SkipHags as legacy signal
    $lowSpecHags = $false
    if ($null -ne $lowSpecCfg -and $lowSpecCfg['Enabled'] -and $lowSpecCfg['SkipHags']) {
        $lowSpecHags = $true
    }

    $eff = @{
        IsLegacy                       = $isLegacy
        SkipResolutionSwitch           = $isLegacy          # old drivers can hang on mode changes
        DisableFullscreenOptimizations = $isLegacy          # FSO stutters on pre-WDDM2.x stacks
        EnableHags                     = (-not $isLegacy -and -not $lowSpecHags)
        ScalePercentOverride           = 0
    }
    foreach ($k in @('SkipResolutionSwitch','DisableFullscreenOptimizations','EnableHags')) {
        if ($null -ne $lgsCfg[$k]) { $eff[$k] = [bool]$lgsCfg[$k] }
    }
    if ($lgsCfg['ScalePercentOverride'] -and [int]$lgsCfg['ScalePercentOverride'] -gt 0) {
        $eff.ScalePercentOverride = [int]$lgsCfg['ScalePercentOverride']
    }
    return $eff
}

# ---------------- color correction settings ----------------
function Resolve-ColorMode {
    <# Returns the configured color mode name ('Off' if disabled). #>
    if (-not $colorCfg -or -not $colorCfg['Enabled']) { return 'Off' }
    $m = 'Off'
    if ($colorCfg['Mode']) { $m = [string]$colorCfg['Mode'] }
    return $m
}

# ---------------- shared watcher invocation ----------------
function Invoke-Watcher {
    param(
        [AllowNull()][System.Threading.EventWaitHandle]$StopEvent = $null,
        [switch]$TrackPidFile
    )
    # Single-instance guard: a second watcher would fight itself.
    # Named mutex on Windows/modern .NET, exclusive file lock elsewhere.
    $guard = New-WatcherInstanceGuard
    if (-not $guard) {
        Write-Log 'A game watcher is already running. Use Stop-GamingSuite.bat first.' 'WARN'
        return
    }
    try {
        # PID file only AFTER we own the instance mutex - writing it any
        # earlier let a rejected second launcher overwrite the live PID.
        if ($TrackPidFile) {
            Set-Content -Path (Get-WatcherPidFile) -Value $PID -Encoding ASCII
        }
        $leg = Resolve-LegacySettings
        if ($leg.IsLegacy) {
            Write-Log 'Legacy GPU profile ACTIVE (older integrated/discrete hardware detected or forced).' 'WARN'
            if ($leg.ScalePercentOverride -gt 0) {
                Write-Log ("Legacy scale override: render target width {0}% of native." -f $leg.ScalePercentOverride) 'INFO'
                $resSettings.ScalePercent = [int]$leg.ScalePercentOverride
            }
        } else {
            Write-Log 'GPU profile: standard (no legacy adjustments).' 'INFO'
        }

        Start-GameWatcher -GameNames $gameNames -PollSeconds $pollSecs `
            -IdlePollSeconds $idleSecs -ExtendedIdlePollSeconds $extIdleSecs `
            -IdleHeartbeatMinutes $heartbeatMin `
            -FreeRamThresholdMB $ramFloorMB `
            -CriticalRamFloorMB $critFloorMB -PurgeCooldownSeconds $purgeCoolSec `
            -PurgeOnGameLaunch:([bool]$purgeLaunch) -ProfileOverrides $profOv `
            -ResolutionSettings $resSettings -FrameGenSettings $fgSettings `
            -LegacySettings $leg -NetworkSettings $netCfg -VoiceSettings $voiceCfg `
            -LowSpecSettings $lowSpecCfg `
            -ColorSettings $colorCfg `
            -NoiseSuppressionSettings $nsCfg `
            -PreGameOptimization:([bool]$preGameOpt) `
            -PrePurgeBeforeLaunch:([bool]$prePurge) `
            -ExitWhenGameSessionEnds:([bool]$exitWhenGameEnds) `
            -StopEvent $StopEvent
    } finally {
        if ($TrackPidFile) {
            Remove-Item (Get-WatcherPidFile) -Force -ErrorAction SilentlyContinue
        }
        try { $guard.Release() } catch { }
    }
}

# ---------------- background (hidden) session ----------------
if ($BackgroundWatch) {
    try {
        $stopEvt = New-WatcherStopEvent
        Write-Log ("Background watcher starting (PID {0})." -f $PID) 'ACTION'
        Invoke-Watcher -StopEvent $stopEvt -TrackPidFile
    } catch {
        Write-Log $_.Exception.Message 'ERROR'
    } finally {
        if ($stopEvt) { $stopEvt.Dispose() }
    }
    exit 0
}

# ---------------- interactive mode ----------------
function Show-Banner {
    Clear-Host
    Write-Host '=====================================================' -ForegroundColor DarkCyan
    Write-Host '        GAMING PERFORMANCE SUITE  v2.5'                -ForegroundColor Cyan
    Write-Host '  FPS stability | Dynamic res | Net + mic tuning'      -ForegroundColor Cyan
    Write-Host '  Cross-platform | Low-spec optimized | Noise-free voice' -ForegroundColor Cyan
    Write-Host '=====================================================' -ForegroundColor DarkCyan
    $admin = Test-Administrator
    $tag = if ($admin) { 'Administrator' } else { 'STANDARD USER (some actions will fail)' }
    Write-Host (" Session: {0} | Log: {1}" -f $tag, (Get-LogPath)) -ForegroundColor DarkGray
    try { Write-Host (" GPU: " + (Get-GpuStatusLine)) -ForegroundColor DarkGray } catch { }

    # Show connection type
    try {
        $connType = Get-ActiveNetworkType
        Write-Host (" Network: {0}" -f $connType) -ForegroundColor DarkGray
    } catch { }

    # Show low-spec mode
    if ($null -ne $lowSpecCfg -and $lowSpecCfg['Enabled']) {
        Write-Host (' Low-spec mode: ACTIVE - minimal resource usage') -ForegroundColor Yellow
    }

    # Show color correction mode
    try {
        $cm = Resolve-ColorMode
        if ($cm -ne 'Off') {
            Write-Host (" Color correction: {0}" -f (Get-ColorCorrectionStatus -Mode $cm)) -ForegroundColor Green
        }
    } catch { }

    # ---- WATCHER STATUS: prominent warning when not running ----
    $watcherAlive = $false
    try { $watcherAlive = Test-WatcherAlive } catch { }
    if ($watcherAlive) {
        Write-Host (' Game watcher running.') -ForegroundColor Green
    } else {
        Write-Host ''
        Write-Host ' !!! WARNING: Game watcher is not running !!' -ForegroundColor Red -BackgroundColor Black
        Write-Host ' Games will NOT be auto-optimized. Start the watcher' -ForegroundColor Red
        Write-Host ' with option 3 below, or run Start-Watcher-Hidden.bat' -ForegroundColor Red
        Write-Host ''
    }

    Write-Host ''
}

function Show-Menu {
    Write-Host ' --- FPS STABILITY ------------------------------------' -ForegroundColor Yellow
    Write-Host '  1) Apply FULL one-click game optimization'
    Write-Host '  2) Purge standby memory NOW (fixes hour-2 stutters)'
    Write-Host ' --- GAME WATCHER (detect -> scale down -> boost) ------' -ForegroundColor Yellow
    Write-Host '  3) Start watcher HIDDEN in background (recommended)'
    Write-Host '  4) Start watcher in THIS window (Ctrl+C to stop)'
    Write-Host '  5) STOP background watcher'
    Write-Host ' --- NETWORK & MICROPHONE ------------------------------' -ForegroundColor Yellow
    Write-Host '  6) Apply network + mic optimizations NOW (incl. noise suppression)'
    Write-Host '  7) Revert network + mic optimizations (restore originals)'
    Write-Host ' --- COLOR & VISIBILITY (FPS enemy clarity) -------------' -ForegroundColor Yellow
    Write-Host '  9) Apply color correction NOW (contrast/RGB)'
    Write-Host '  0) Remove color correction (restore normal color)'
    Write-Host ' --- STATUS --------------------------------------------' -ForegroundColor Yellow
    Write-Host '  8) Show watcher / display / network / GPU status'
    Write-Host ' -------------------------------------------------------' -ForegroundColor Yellow
    Write-Host '  Q) Quit'
    Write-Host ''
}

function Invoke-FullOptimization {
    $leg = Resolve-LegacySettings
    Write-Log '=== FULL OPTIMIZATION: starting ===' 'ACTION'
    Enable-GamingPowerPlan
    Disable-GameDVR
    Set-MultimediaTweaks -EnableHags:([bool]$leg.EnableHags)
    Set-TimerResolution
    if (-not ($null -ne $lowSpecCfg -and $lowSpecCfg['Enabled'] -and $lowSpecCfg['SkipStandbyPurge'])) {
        Clear-StandbyMemory
    }
    try { Set-MicClarityTweaks } catch { Write-Log $_.Exception.Message 'ERROR' }
    try { Enable-GameNetworkProfile -Settings $netCfg -JournalState $null } catch { Write-Log $_.Exception.Message 'ERROR' }
    if ($leg.EnableHags) {
        Write-Log '=== FULL OPTIMIZATION complete. Reboot once for HAGS. ===' 'OK'
    } else {
        Write-Log '=== FULL OPTIMIZATION complete (legacy-safe: HAGS untouched). ===' 'OK'
    }
}

function Test-WatcherAlive {
    # Robust liveness: probes the named instance mutex (falling back to the
    # pid file) - not just the pid file, which a recovery could have removed.
    return [bool](Test-WatcherRunning)
}

function Show-Status {
    $alive = Test-WatcherAlive
    $state = if ($alive) { 'RUNNING (background)' } else { 'stopped' }
    Write-Log "Watcher state: $state" 'INFO'
    if (-not $alive) {
        Write-Log '!!! Watcher is NOT running - games will NOT be auto-optimized !!!' 'ERROR'
        Write-Log 'Start it with option 3 or run Start-Watcher-Hidden.bat' 'WARN'
    }
    if (Get-WatcherJournal) {
        Write-Log 'Recovery journal present: last session ended uncleanly; it will be repaired on next watcher start.' 'WARN'
    }
    try {
        $mode = Get-CurrentDisplayMode
        if ($mode) {
            $bppStr = if ($mode.ContainsKey('Bits')) { " ({0} bpp)" -f $mode.Bits } else { '' }
            Write-Log ("Display: {0}x{1} @ {2} Hz{3}" -f $mode.Width, $mode.Height, $mode.Frequency, $bppStr) 'INFO'
        } else {
            Write-Log 'Display: no scaling backend available (xrandr / displayplacer missing).' 'INFO'
        }
    } catch { }
    try {
        $gpus = @(Get-GpuInfo)
        if ($gpus.Count -eq 0) {
            Write-Log 'GPU: none detected' 'WARN'
        }
        foreach ($gpu in $gpus) {
            $vram = if ($null -ne $gpu.DedicatedMB) { ", $($gpu.DedicatedMB) MB VRAM" } else { '' }
            $drv  = if ($gpu.DriverVersion)         { ", driver $($gpu.DriverVersion)" } else { '' }
            Write-Log ("GPU [{0}] {1}: {2} ({3}{4}{5})" -f `
                $gpu.Index, $gpu.Type, $gpu.Name, $gpu.Vendor, $vram, $drv) 'INFO'
        }
    } catch { }
    $fg = if ($fgSettings['Enabled']) { "enabled -> $($fgSettings['ToolPath'])" } else { 'disabled (enable in Config.ps1)' }
    Write-Log "Frame generation: $fg" 'INFO'

    # ---- resolution tiers summary --------------------------------------
    $tierStr = ''
    if ($resSettings['Tiers'] -is [hashtable]) {
        $tierStr = (@($resSettings['Tiers'].GetEnumerator() | Sort-Object { $_.Value } |
            ForEach-Object { "$($_.Key)=$($_.Value)%" }) -join ', ')
    }
    $profTierStr = ''
    if ($resSettings['ProfileTiers'] -is [hashtable]) {
        $profTierStr = (@($resSettings['ProfileTiers'].GetEnumerator() |
            ForEach-Object { "$($_.Key)->$($_.Value)" }) -join ', ')
    }
    Write-Log ("Resolution tiers: {0}  [default {1}%; per-profile: {2}]" -f `
        $(if ($tierStr) { $tierStr } else { "$($resSettings.ScalePercent)% (single mode)" }), `
        $resSettings.ScalePercent, $(if ($profTierStr) { $profTierStr } else { 'default' })) 'INFO'
    Write-Log ("Integer scaling preferred: {0}" -f $resSettings.PreferIntegerScale) 'INFO'

    # ---- network + voice summary ---------------------------------------
    $netOn  = if ($null -ne $netCfg['Enabled'])   { [bool]$netCfg['Enabled'] }   else { $true }
    try {
        $connType = Get-ActiveNetworkType
        Write-Log ("Network tuning: {0} (connection: {1}, TCP auto-optimized for connection type)" -f $(if ($netOn) { 'enabled' } else { 'disabled' }), $connType) 'INFO'
    } catch {
        Write-Log ("Network tuning: {0}" -f $(if ($netOn) { 'enabled' } else { 'disabled' })) 'INFO'
    }
    $micMmcss = if ($null -ne $voiceCfg['MmcssAudioPriority']) { [bool]$voiceCfg['MmcssAudioPriority'] } else { $true }
    $extraProt = @()
    if ($voiceCfg['ExtraProtectedProcessNames']) { $extraProt = @($voiceCfg['ExtraProtectedProcessNames']) }
    Write-Log ("Voice clarity: MMCSS mic priority {0}; voice apps protected from silencing{1}" -f `
        $(if ($micMmcss) { 'on' } else { 'off' }), $(if ($extraProt.Count -gt 0) { ' (+ your extras)' } else { '' })) 'INFO'
    # ---- noise suppression status ----
    $nsEnabled = if ($null -ne $nsCfg['Enabled']) { [bool]$nsCfg['Enabled'] } else { $false }
    $nsActive = if ((Get-Command Test-VoiceDspActive -ErrorAction SilentlyContinue) -and (Test-VoiceDspActive)) { 'ACTIVE' } else { 'inactive' }
    if ($nsEnabled -and $nsCfg['ExternalEngine']) {
        Write-Log ("Mic noise suppression: external engine configured ({0}) - {1}" -f $nsCfg['ExternalEngine'], $nsActive) 'INFO'
    } elseif ($nsEnabled) {
        Write-Log ("Mic noise suppression (deep NS + echo cancellation): {0} (Windows 11 DSP)" -f $nsActive) 'INFO'
    } else {
        Write-Log 'Mic noise suppression: DISABLED in Config.ps1' 'INFO'
    }

    try {
        $leg = Resolve-LegacySettings
        $lgState = if ($leg.IsLegacy) { 'ACTIVE (legacy-safe tweaks)' } else { 'off (standard profile)' }
        Write-Log "Legacy GPU support: $lgState" 'INFO'
    } catch { }

    # ---- low-spec mode summary ------------------------------------------
    if ($null -ne $lowSpecCfg -and $lowSpecCfg['Enabled']) {
        Write-Log 'Low-spec mode: ACTIVE' 'WARN'
        Write-Log ("  Polling: {0}s gaming / {1}s idle / {2}s extended idle" -f $pollSecs, $idleSecs, $extIdleSecs) 'INFO'
        Write-Log ("  Pre-game optimization: {0}" -f $(if ($preGameOpt) { 'enabled' } else { 'disabled' })) 'INFO'
        Write-Log ("  Pre-launch purge: {0}" -f $(if ($prePurge) { 'enabled' } else { 'disabled' })) 'INFO'
    } else {
        Write-Log ("  Polling: {0}s gaming / {1}s idle / {2}s extended idle" -f $pollSecs, $idleSecs, $extIdleSecs) 'INFO'
    }
    Write-Log ("  Idle heartbeat: every {0} min" -f $heartbeatMin) 'INFO'

    # ---- color correction status ----------------------------------
    try {
        $cm = Resolve-ColorMode
        Write-Log ("Color correction: {0}" -f (Get-ColorCorrectionStatus -Mode $cm)) 'INFO'
    } catch { Write-Log 'Color correction: n/a' 'INFO' }

    # ---- platform info ------------------------------------------
    Write-Log ("Platform: {0} | PowerShell {1}" -f $PSVersionTable.Platform, $PSVersionTable.PSVersion) 'INFO'
}

function Wait-MenuKey {
    Write-Host 'Press Enter to return to the menu...' -ForegroundColor DarkGray
    Read-Host | Out-Null
}

# ---------------- main loop ----------------
:menu while ($true) {
    Show-Banner
    Show-Menu
    switch (Read-Host 'Select an option') {
        '1' { try { Invoke-FullOptimization } catch { Write-Log $_.Exception.Message 'ERROR' }; Wait-MenuKey }
        '2' { try { Clear-StandbyMemory } catch { Write-Log $_.Exception.Message 'ERROR' }; Wait-MenuKey }
        '3' {
            try {
                if (Test-WatcherAlive) {
                    Write-Log 'Watcher already running in background.' 'WARN'
                } else {
                    Write-Log 'Launching hidden background watcher...' 'ACTION'
                    if (Test-SuitePlatformWindows) {
                        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList @(
                            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                            '-File', "`"$PSCommandPath`"", '-BackgroundWatch'
                        )
                    } else {
                        $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
                        if (-not $pwsh) { throw 'pwsh (PowerShell 7+) is required on this platform but was not found.' }
                        $args = @('-NoProfile', '-File', $PSCommandPath, '-BackgroundWatch')
                        if (Test-Administrator) {
                            Start-Process -FilePath $pwsh.Source -ArgumentList $args -WindowStyle Hidden
                        } else {
                            # non-root: elevate through sudo. Try a non-interactive,
                            # passwordless launch first (works with NOPASSWD sudoers
                            # rules); if sudo needs a password, prompt the user in
                            # THIS terminal instead of silently failing in the
                            # background - sudo can only prompt from a TTY.
                            $sudoNonInteractive = (& sudo -n true 2>$null)
                            if ($LASTEXITCODE -eq 0) {
                                Start-Process -FilePath 'sudo' -ArgumentList (@('-b', $pwsh.Source) + $args) -WindowStyle Hidden
                            } else {
                                Write-Log 'This menu cannot start the watcher in the background because it needs root and sudo must prompt for a password.' 'WARN'
                                Write-Log 'Open a terminal and run:  sudo pwsh -NoProfile -File src/Main.ps1 -BackgroundWatch' 'WARN'
                                Write-Log '(or use the Start-Watcher-Hidden.sh launcher from a terminal.)' 'WARN'
                                Wait-MenuKey
                                continue
                            }
                        }
                    }
                    # Wait for the watcher to announce itself (instance mutex /
                    # pid file) instead of a fixed 1s guess - module import and
                    # GPU detection can take a moment on slower machines.
                    $deadline = [datetime]::UtcNow.AddSeconds(8)
                    $launched = $false
                    while ([datetime]::UtcNow -lt $deadline -and -not $launched) {
                        Start-Sleep -Milliseconds 400
                        $launched = Test-WatcherAlive
                    }
                    if ($launched) { Write-Log 'Background watcher started. No window needed - play your game.' 'OK' }
                    else          { Write-Log 'Watcher did not come up within 8s; check logs/ for errors.' 'WARN' }
                }
            } catch { Write-Log $_.Exception.Message 'ERROR' }
            Wait-MenuKey
        }
        '4' { try { Invoke-Watcher } catch { Write-Log $_.Exception.Message 'ERROR' }; Wait-MenuKey }
        '5' { try { Stop-BackgroundWatcher } catch { Write-Log $_.Exception.Message 'ERROR' }; Wait-MenuKey }
        '6' {
            try {
                Set-MicClarityTweaks
                Enable-GameNetworkProfile -Settings $netCfg -JournalState $null
                $nsEnabledNow = if ($null -ne $nsCfg['Enabled']) { [bool]$nsCfg['Enabled'] } else { $false }
                if ($nsEnabledNow) {
                    if ($nsCfg['ExternalEngine']) {
                        Start-NoiseSuppressionExternal -Engine $nsCfg['ExternalEngine'] -Args $nsCfg['ExternalArgs']
                    } elseif (Test-VoiceDspPlatform) {
                        Enable-VoiceNoiseSuppression
                    } else {
                        Write-Log 'Mic DSP unavailable on this platform (needs Windows 11).' 'WARN'
                    }
                }
            } catch { Write-Log $_.Exception.Message 'ERROR' }
            Wait-MenuKey
        }
        '7' {
            try {
                Undo-GameNetworkProfile -RemoveKnownDefaults
                Disable-VoiceNoiseSuppression
                Stop-NoiseSuppressionExternal
            } catch { Write-Log $_.Exception.Message 'ERROR' }
            Wait-MenuKey
        }
        '8' { try { Show-Status } catch { Write-Log $_.Exception.Message 'ERROR' }; Wait-MenuKey }
        '9' {
            try {
                $m = Resolve-ColorMode
                if ($m -eq 'Off') {
                    Write-Log 'Color correction is disabled in Config.ps1 (ColorCorrection.Enabled).' 'WARN'
                } else {
                    if (-not (Enable-ColorCorrection -Mode $m)) {
                        Write-Log 'Could not apply color correction (see above / logs).' 'ERROR'
                    }
                }
            } catch { Write-Log $_.Exception.Message 'ERROR' }
            Wait-MenuKey
        }
        '0' { try { Disable-ColorCorrection } catch { Write-Log $_.Exception.Message 'ERROR' }; Wait-MenuKey }
        { $_ -in 'Q','q' } { break menu }
        default { }
    }
}
