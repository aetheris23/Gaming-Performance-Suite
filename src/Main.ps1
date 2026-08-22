# ============================================================
#  Main.ps1 - Gaming Performance Suite entry point
#
#  Interactive menu:      Start-GamingSuite.bat
#  Hidden background run: Start-Watcher-Hidden.bat
#                         (equivalent: powershell -File src\Main.ps1 -BackgroundWatch)
#  Stop the background watcher at any time: Stop-GamingSuite.bat
# ============================================================

param([switch]$BackgroundWatch)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $root 'Common.psm1')    -Force
Import-Module (Join-Path $root 'GpuDetect.psm1') -Force
Import-Module (Join-Path $root 'GameBoost.psm1') -Force
Import-Module (Join-Path $root 'DisplayScale.psm1') -Force

# Load user config with safe fallbacks
$cfgPath = Join-Path $root 'Config.ps1'
$cfg = if (Test-Path $cfgPath) { & $cfgPath } else { @{} }
$gameNames  = if ($cfg['GameProcesses'])      { $cfg['GameProcesses'] }      else { @('VALORANT-Win64','pcsx2','cs2') }
$pollSecs   = if ($cfg['WatcherPollSeconds']) { [int]$cfg['WatcherPollSeconds'] } else { 10 }
$ramFloorMB = if ($cfg['FreeRamThresholdMB']) { [int]$cfg['FreeRamThresholdMB'] } else { 2048 }
$profOv     = if ($cfg['ProfileOverrides'])   { $cfg['ProfileOverrides'] }   else { @{} }

$resSettings = @{
    ScalePercent      = if ($cfg['ResolutionScalePercent']) { [int]$cfg['ResolutionScalePercent'] } else { 66 }
    PreferIntegerScale= if ($null -ne $cfg['PreferIntegerScale']) { [bool]$cfg['PreferIntegerScale'] } else { $true }
}
$fgSettings = if ($cfg['FrameGeneration']) { $cfg['FrameGeneration'] } else { @{ Enabled = $false; ToolPath = '' } }
$lgsCfg     = if ($cfg['LegacyGpuSupport']) { $cfg['LegacyGpuSupport'] } else { @{ Mode = 'Auto' } }

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

    $eff = @{
        IsLegacy                       = $isLegacy
        SkipResolutionSwitch           = $isLegacy          # old drivers can hang on mode changes
        DisableFullscreenOptimizations = $isLegacy          # FSO stutters on pre-WDDM2.x stacks
        EnableHags                     = (-not $isLegacy)   # HwSchMode unsupported/unstable on old GPUs
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

# ---------------- shared watcher invocation ----------------
function Invoke-Watcher {
    param([System.Threading.EventWaitHandle]$StopEvent)
    # Single-instance guard: a second watcher would fight itself
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($true, (Get-WatcherMutexName), [ref]$createdNew)
    if (-not $createdNew) {
        Write-Log 'A game watcher is already running. Use Stop-GamingSuite.bat first.' 'WARN'
        $mutex.Dispose()
        return
    }
    try {
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
            -FreeRamThresholdMB $ramFloorMB -ProfileOverrides $profOv `
            -ResolutionSettings $resSettings -FrameGenSettings $fgSettings `
            -LegacySettings $leg -StopEvent $StopEvent
    } finally {
        if ($BackgroundWatch) {
            Remove-Item (Get-WatcherPidFile) -Force -ErrorAction SilentlyContinue
        }
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

# ---------------- background (hidden) session ----------------
if ($BackgroundWatch) {
    try {
        $stopEvt = New-WatcherStopEvent
        Set-Content -Path (Get-WatcherPidFile) -Value $PID -Encoding ASCII
        Write-Log ("Background watcher starting (PID {0})." -f $PID) 'ACTION'
        Invoke-Watcher -StopEvent $stopEvt
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
    Write-Host '        GAMING PERFORMANCE SUITE  v2.0'                -ForegroundColor Cyan
    Write-Host '  FPS stability | Dynamic resolution | Frame pacing'   -ForegroundColor Cyan
    Write-Host '=====================================================' -ForegroundColor DarkCyan
    $admin = Test-Administrator
    $tag = if ($admin) { 'Administrator' } else { 'STANDARD USER (some actions will fail)' }
    Write-Host (" Session: {0} | Log: {1}" -f $tag, (Get-LogPath)) -ForegroundColor DarkGray
    try { Write-Host (" GPU: " + (Get-GpuStatusLine)) -ForegroundColor DarkGray } catch { }
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
    Write-Host ' --- STATUS --------------------------------------------' -ForegroundColor Yellow
    Write-Host '  6) Show watcher / display status'
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
    Clear-StandbyMemory
    if ($leg.EnableHags) {
        Write-Log '=== FULL OPTIMIZATION complete. Reboot once for HAGS. ===' 'OK'
    } else {
        Write-Log '=== FULL OPTIMIZATION complete (legacy-safe: HAGS untouched). ===' 'OK'
    }
}

function Test-WatcherAlive {
    $pidFile = Get-WatcherPidFile
    if (-not (Test-Path $pidFile)) { return $false }
    $watcherPid = 0
    [void][int]::TryParse((Get-Content $pidFile -Raw).Trim(), [ref]$watcherPid)
    return ($watcherPid -gt 0 -and (Get-Process -Id $watcherPid -ErrorAction SilentlyContinue))
}

function Show-Status {
    $alive = Test-WatcherAlive
    $state = if ($alive) { 'RUNNING (background)' } elseif (Open-OrCreateStopEvent) { 'RUNNING' } else { 'stopped' }
    Write-Log "Watcher state: $state" 'INFO'
    try {
        $mode = Get-CurrentDisplayMode
        Write-Log ("Display: {0}x{1} @ {2} Hz ({3} bpp)" -f $mode.Width, $mode.Height, $mode.Frequency, $mode.Bits) 'INFO'
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
    Write-Log ("Resolution scaling: {0}% (integer preferred: {1})" -f $resSettings.ScalePercent, $resSettings.PreferIntegerScale) 'INFO'
    try {
        $leg = Resolve-LegacySettings
        $lgState = if ($leg.IsLegacy) { 'ACTIVE (legacy-safe tweaks)' } else { 'off (standard profile)' }
        Write-Log "Legacy GPU support: $lgState" 'INFO'
    } catch { }
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
                    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList @(
                        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                        '-File', "`"$PSCommandPath`"", '-BackgroundWatch'
                    )
                    Start-Sleep -Seconds 1
                    if (Test-WatcherAlive) { Write-Log 'Background watcher started. No window needed - play your game.' 'OK' }
                }
            } catch { Write-Log $_.Exception.Message 'ERROR' }
            Wait-MenuKey
        }
        '4' { try { Invoke-Watcher } catch { Write-Log $_.Exception.Message 'ERROR' }; Wait-MenuKey }
        '5' { try { Stop-BackgroundWatcher } catch { Write-Log $_.Exception.Message 'ERROR' }; Wait-MenuKey }
        '6' { try { Show-Status } catch { Write-Log $_.Exception.Message 'ERROR' }; Wait-MenuKey }
        { $_ -in 'Q','q' } { break menu }
        default { }
    }
}
