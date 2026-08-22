# ============================================================
#  GameBoost.psm1 - FPS stability + dynamic game handling
#  (Valorant, Steam titles, PCSX2 and other emulators).
#
#  On game detection the watcher:
#    - classifies the title (Emulator / Steam / Competitive)
#    - raises its scheduling priority + steers it off core 0
#    - silences known background hogs
#    - DROPS THE DISPLAY RESOLUTION to cut GPU load
#      (restored to native automatically on game exit/stop)
#    - optionally launches a driver-level frame-generation
#      companion app if one is installed (see Config.ps1)
#
#  The watcher loop parks on a kernel wait event between polls:
#    near-zero CPU while idle, INSTANT response to stop signal.
# ============================================================

Set-StrictMode -Version Latest

# GPU inventory (iGPU/dGPU identification) - one-shot at startup.
# Skip the reload when Main.ps1 already imported it (-Force would re-parse
# the whole module and adds avoidable startup lag on low-spec machines).
if (-not (Get-Module -Name 'GpuDetect')) {
    Import-Module (Join-Path $PSScriptRoot 'GpuDetect.psm1') -Force
}

function Write-GpuInventory {
    <# Logs every detected adapter once (integrated AND discrete),
       so hybrid setups show exactly which chips are present. #>
    try {
        $gpus = @(Get-GpuInfo)
        if ($gpus.Count -eq 0) {
            Write-Log 'GPU detection returned no adapters.' 'WARN'
            return
        }
        foreach ($g in $gpus) {
            $vram = if ($null -ne $g.DedicatedMB) { ", $($g.DedicatedMB) MB dedicated" } else { '' }
            Write-Log ("GPU {0}: {1} [{2}] vendor={3} ids={4}/{5}{6} driver={7}" -f `
                $g.Index, $g.Name, $g.Type, $g.Vendor,
                $(if ($g.VendorId) { $g.VendorId } else { '?' }),
                $(if ($g.DeviceId) { $g.DeviceId } else { '?' }),
                $vram,
                $(if ($g.DriverVersion) { $g.DriverVersion } else { 'n/a' })) 'INFO'
        }
    } catch {
        Write-Log "GPU detection failed: $_" 'WARN'
    }
}

# ------------------------------------------------------------
# Native interop: timer resolution + standby memory purge
# ------------------------------------------------------------
function Add-NativeBoostType {
    <#
        Compiles the timer/memory interop lazily, on first real use.
        None of these native calls are needed while the watcher idles,
        so deferring the one-time C# compile keeps startup instant on
        low-spec machines (it lands at first game detection instead).
    #>
    if ('Suite.NativeBoost' -as [type]) { return }
    Add-Type -Namespace Suite -Name NativeBoost -MemberDefinition @'
[DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint uPeriod);
[DllImport("winmm.dll")] public static extern uint timeEndPeriod(uint uPeriod);

[DllImport("ntdll.dll")]
public static extern int NtSetSystemInformation(int InfoClass, ref int Info, int Length);

[StructLayout(LayoutKind.Sequential)]
public struct MEMORYSTATUSEX
{
    public uint dwLength;
    public uint dwMemoryLoad;
    public ulong ullTotalPhys;
    public ulong ullAvailPhys;
    public ulong ullTotalPageFile;
    public ulong ullAvailPageFile;
    public ulong ullTotalVirtual;
    public ulong ullAvailVirtual;
    public ulong ullAvailExtendedVirtual;
}

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);
'@
}

$script:TimerActive = $false

# ------------------------------------------------------------
# Free RAM via a single native call (no WMI/CIM session overhead)
# ------------------------------------------------------------
function Get-FreeRamMB {
    Add-NativeBoostType
    $ms = New-Object Suite.NativeBoost+MEMORYSTATUSEX
    $ms.dwLength = [uint32][Runtime.InteropServices.Marshal]::SizeOf([type][Suite.NativeBoost+MEMORYSTATUSEX])
    [void][Suite.NativeBoost]::GlobalMemoryStatusEx([ref]$ms)
    [int]($ms.ullAvailPhys / 1MB)
}

# ------------------------------------------------------------
# 1. High-performance power plan + PCIe/CPU floor at max perf
# ------------------------------------------------------------
function Enable-GamingPowerPlan {
    [CmdletBinding()] param()

    Assert-AdminOrThrow

    # Duplicate "High performance" into a dedicated gaming plan if missing
    $planLine = powercfg /list | Where-Object { $_ -match 'Gaming Performance Suite' } | Select-Object -First 1
    if (-not $planLine) {
        Write-Log 'Creating dedicated gaming power plan...' 'ACTION'
        $dupOut = powercfg /duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-String
        if ($dupOut -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
            powercfg /changename $Matches[1] 'Gaming Performance Suite' 'Max FPS stability profile' | Out-Null
        }
        $planLine = powercfg /list | Where-Object { $_ -match 'Gaming Performance Suite' } | Select-Object -First 1
    }

    if ($planLine -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
        $guid = $Matches[1]
        powercfg /setactive $guid | Out-Null
        Write-Log "Active power plan set to 'Gaming Performance Suite' ($guid)" 'OK'

        # PCI Express Link State Power Management -> Off (GPU latency spikes)
        foreach ($src in 'AC','DC') {
            powercfg /set${src}valueindex $guid `
                501a4d13-42af-4429-9fd1-a8218c268e20 `
                ee12f906-d277-404b-b6da-e5fa1a576df5 0 | Out-Null
        }
        # Minimum processor state 100% (AC + DC) - kills core-throttle dips
        foreach ($src in 'AC','DC') {
            powercfg /set${src}valueindex $guid `
                54533251-82be-4824-96c1-47b60b740d00 `
                bc5038f7-23e0-4960-96da-33abaf5935ec 100 | Out-Null
        }
        powercfg /setactive $guid | Out-Null
        Write-Log 'PCIe link + CPU floor forced to Maximum Performance' 'OK'
    } else {
        Write-Log 'Could not resolve a power plan GUID; falling back to High performance.' 'WARN'
        powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null
    }
}

# ------------------------------------------------------------
# 2. Kill Game DVR / Game Bar capture (classic Valorant stutters)
# ------------------------------------------------------------
function Disable-GameDVR {
    Assert-AdminOrThrow

    $paths = @(
        @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR';          Name = 'AllowGameDVR';       Value = 0 },
        @{ Key = 'HKCU:\System\GameConfigStore';                               Name = 'GameDVR_Enabled';    Value = 0 },
        @{ Key = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR';    Name = 'AppCaptureEnabled';  Value = 0 },
        @{ Key = 'HKCU:\SOFTWARE\Microsoft\GameBar';                           Name = 'ShowStartupPanel';   Value = 0 },
        @{ Key = 'HKCU:\SOFTWARE\Microsoft\GameBar';                           Name = 'AutoGameModeEnabled';Value = 1 }  # keep Auto Game Mode ON - it helps
    )
    foreach ($p in $paths) {
        if (-not (Test-Path $p.Key)) { New-Item -Path $p.Key -Force | Out-Null }
        New-ItemProperty -Path $p.Key -Name $p.Name -Value $p.Value `
            -PropertyType DWord -Force | Out-Null
    }
    Write-Log 'Game DVR background recording disabled (Game Bar auto mode kept on)' 'OK'
}

# ------------------------------------------------------------
# 3. System-wide multimedia scheduling registry tweaks
# ------------------------------------------------------------
function Set-MultimediaTweaks {
    <#
        $EnableHags = $false leaves Hardware-Accelerated GPU
        Scheduling untouched - the right choice for older GPUs
        (pre-Pascal GeForce / pre-RX Radeon / Intel pre-Xe), where
        HwSchMode is unsupported at best and unstable at worst.
    #>
    [CmdletBinding()] param([bool]$EnableHags = $true)

    Assert-AdminOrThrow

    $sysProfile = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    if (-not (Test-Path $sysProfile)) { New-Item -Path $sysProfile -Force | Out-Null }
    New-ItemProperty -Path $sysProfile -Name 'SystemResponsiveness' `
        -Value 0 -PropertyType DWord -Force | Out-Null

    # Elevate the "Games" task class inside MMCSS
    $games = "$sysProfile\Tasks\Games"
    if (-not (Test-Path $games)) { New-Item -Path $games -Force | Out-Null }
    New-ItemProperty -Path $games -Name 'GPU Priority'        -Value 8    -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $games -Name 'Priority'            -Value 6    -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $games -Name 'Scheduling Category' -Value 'High'  -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $games -Name 'SFIO Priority'       -Value 'High'  -PropertyType String -Force | Out-Null

    if ($EnableHags) {
        # HAGS (Hardware Accelerated GPU Scheduling) - reduces render queue latency
        $hags = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        if (-not (Test-Path $hags)) { New-Item -Path $hags -Force | Out-Null }
        New-ItemProperty -Path $hags -Name 'HwSchMode' -Value 2 -PropertyType DWord -Force | Out-Null

        Write-Log 'MMCSS games priority raised, HAGS enabled' 'OK'
        Write-Log '(HAGS takes effect after next reboot)' 'INFO'
    } else {
        Write-Log 'MMCSS games priority raised; HAGS left untouched (legacy GPU mode)' 'OK'
    }
}

# ------------------------------------------------------------
# 4. Timer resolution locked to 1 ms (frame pacing)
# ------------------------------------------------------------
function Set-TimerResolution {
    param([switch]$Restore)
    Add-NativeBoostType
    if ($Restore) {
        if ($script:TimerActive) {
            [void][Suite.NativeBoost]::timeEndPeriod(1)
            $script:TimerActive = $false
            Write-Log 'Timer resolution restored to system default' 'INFO'
        }
        return
    }
    $result = [Suite.NativeBoost]::timeBeginPeriod(1)
    if ($result -eq 0) {
        $script:TimerActive = $true
        Write-Log 'Global timer resolution locked at 1 ms' 'OK'
    } else {
        Write-Log "timeBeginPeriod returned $result" 'WARN'
    }
}

# ------------------------------------------------------------
# 5. Standby memory purge (the #1 fix for sudden stutters
#    after the PC has been on for hours)
# ------------------------------------------------------------
function Clear-StandbyMemory {
    Assert-AdminOrThrow

    Add-NativeBoostType
    [void](Enable-Privilege 'SeProfileSingleProcessPrivilege')

    # SystemMemoryListInformation(80): command 4 = PurgeStandbyList
    $cmd = 4
    $status = [Suite.NativeBoost]::NtSetSystemInformation(80, [ref]$cmd, 4)
    if ($status -eq 0) {
        $freeGB = [math]::Round((Get-FreeRamMB) / 1024.0, 2)
        Write-Log "Standby memory purged (free RAM now ~$freeGB GB)" 'OK'
    } else {
        Write-Log ("Standby purge failed with NTSTATUS 0x{0:X8} (privilege not held?)" -f $status) 'ERROR'
    }
}

# ------------------------------------------------------------
# Per-game-type optimization profiles
# ------------------------------------------------------------
$script:GameProfiles = @{
    'Emulator' = @{
        Priority         = 'High'
        AvoidCores       = @(0)      # keep interrupt core free; emulation loves clean cores
        Deprioritize     = @()
        Description      = 'CPU-bound emulation: max CPU scheduling, quiet background'
    }
    'Steam' = @{
        Priority         = 'High'
        AvoidCores       = @(0)
        Deprioritize     = @('steamwebhelper')   # Steam store/overlay steals CPU mid-game
        Description      = 'GPU-heavy title: High priority + Steam client silenced'
    }
    'Competitive' = @{
        Priority         = 'High'
        AvoidCores       = @(0)
        Deprioritize     = @('steamwebhelper','discord','chrome','msedge','firefox','spotify')
        Description      = 'Latency-critical online play: High priority + browsers/Discord silenced'
    }
    'Default' = @{
        Priority         = 'AboveNormal'
        AvoidCores       = @(0)
        Deprioritize     = @()
        Description      = 'Unknown title: safe moderate boost'
    }
}

# Name fingerprints used when path detection is unavailable (elevated/store apps)
$script:EmulatorNames = @(
    'pcsx2*', 'aethersx2*', 'pcsx*', 'retroarch*', 'duckstation*', 'ppsspp*',
    'dolphin*', 'cemu*', 'yuzu*', 'suyu*', 'sudachi*', 'ryujinx*', 'xemu*',
    'epsxe*', 'mesen*', 'fceux*', 'snes9x*', 'bizhawk*', 'mame*'
)
$script:OnlineNames = @(
    'valorant-win64', 'cs2', 'csgo', 'dota2', 'fortniteclient*', 'javaw',
    'r5apex*', 'overwatch*', 'roguecompany*', 'rocketleague*',
    'paladins*', 'warframe*', 'destiny2*', 'tsgame*'
)
$script:SteamNames = @(
    'gta5*', 'rdr2*', 'cyberpunk2077', 'eldenring*', 'hogwarts*',
    'baldursgate3', 'bg3_dx11*', 'witcher3', 'stardew*', 'terraria',
    'hollowknight*', 'celeste*', 'hades*', 'portal2', 'halo*', 'forza*'
)

function Get-GameProfile {
    <#
        Classifies a running game process into one of the profile names:
        'Emulator' | 'Steam' | 'Competitive' | 'Default'.
        Order of evidence: user override map > install path > process name.
    #>
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [hashtable]$Overrides = @{}
    )

    $name = $Process.ProcessName

    # 1. Explicit user mapping wins
    if ($Overrides.Count -gt 0 -and $Overrides.ContainsKey($name)) {
        return [string]$Overrides[$name]
    }

    # 2. Install-path detection (most reliable signal available)
    $path = $null
    try { $path = $Process.Path } catch { }
    if (-not $path) {
        try { $path = $Process.MainModule.FileName } catch { }
    }
    if ($path) {
        $lp = $path.ToLowerInvariant()
        if ($lp -match '\\steamapps\\common\\') { return 'Steam' }
        if ($lp -match 'pcsx2|aethersx2|retroarch|duckstation|dolphin|cemu|yuzu|suyu|ryujinx|xemu|pcsx-redux|ppsspp') { return 'Emulator' }
    }

    # 3. Process-name heuristics
    foreach ($n in $script:EmulatorNames) { if ($name -like $n) { return 'Emulator' } }
    foreach ($n in $script:OnlineNames)   { if ($name -like $n) { return 'Competitive' } }
    foreach ($n in $script:SteamNames)    { if ($name -like $n) { return 'Steam' } }

    return 'Default'
}

# ------------------------------------------------------------
# 6. Per-process boost driven by the game's profile
# ------------------------------------------------------------
function Invoke-ProcessBoost {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][hashtable]$Profile
    )

    try {
        if ($Process.HasExited) { return }

        # Realtime is deliberately never used - it starves input threads
        $wantPri = [string]$Profile.Priority
        if ($Process.PriorityClass -ne $wantPri) {
            $Process.PriorityClass = $wantPri
            Write-Log ("Priority -> {0} for '{1}' (PID {2})" -f $wantPri, $Process.ProcessName, $Process.Id) 'OK'
        }

        # Spread the game off the interrupt core (USB/NIC DPCs land there)
        $avoid = @($Profile.AvoidCores)
        $total = [Environment]::ProcessorCount
        if ($total -gt 2 -and $avoid.Count -gt 0 -and $avoid.Count -lt $total) {
            $mask = 0L
            for ($i = 0; $i -lt $total; $i++) {
                if ($avoid -notcontains $i) { $mask = $mask -bor ([long]1 -shl $i) }
            }
            $Process.ProcessorAffinity = [IntPtr]$mask
        }
    } catch {
        Write-Log "Could not fully boost PID $($Process.Id): $_" 'WARN'
    }
}

# ------------------------------------------------------------
# Background-app silencing used by the Steam/Competitive profiles
# ------------------------------------------------------------
function Update-BackgroundSilence {
    param(
        [string[]]$Names,
        [int]$ExceptPid,
        [hashtable]$State,     # pid -> process name currently silenced
        [switch]$Activate      # off = restore everything in $State to Normal
    )

    if (-not $Activate) {
        foreach ($procId in @($State.Keys)) {
            try {
                $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($p -and $p.PriorityClass -eq 'BelowNormal') { $p.PriorityClass = 'Normal' }
            } catch { }
            $null = $State.Remove($procId)
        }
        return
    }

    if (-not $Names -or @($Names).Count -eq 0) { return }

    $targets = @(Get-Process -Name @($Names) -ErrorAction SilentlyContinue)
    foreach ($t in $targets) {
        try {
            if ($t.Id -eq $ExceptPid -or $t.Id -eq $PID) { continue }
            # Never touch anti-cheat services, whatever happens
            if ($t.ProcessName -in @('vgc','vgtray','vgk','BEService','EasyAntiCheat')) { continue }
            if (-not $State.ContainsKey($t.Id)) {
                $t.PriorityClass = 'BelowNormal'
                $State[$t.Id] = $t.ProcessName
                Write-Log ("Silenced background app '{0}' (PID {1}) while gaming" -f $t.ProcessName, $t.Id) 'INFO'
            }
        } catch { }
    }
}

# ------------------------------------------------------------
# 7. Frame-generation bridge.
#    True frame insertion happens in GPU drivers or dedicated
#    interpolators (DLSS3-FG / FSR3-FG / Lossless Scaling);
#    no external script can inject frames itself. If a tool is
#    configured we launch it alongside the detected game so the
#    whole flow stays one-click.
# ------------------------------------------------------------
function Invoke-FrameGenerationTool {
    param(
        [hashtable]$Settings,
        [ref][bool]$LaunchedByUs,
        [ref][int]$ToolPid
    )

    if (-not $Settings -or -not $Settings['Enabled']) { return }
    $exe = [string]$Settings['ToolPath']
    if (-not $exe -or -not (Test-Path $exe)) {
        Write-Log 'Frame generation enabled but tool path not found (Config.ps1).' 'WARN'
        return
    }

    $already = Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($exe)) -ErrorAction SilentlyContinue
    if ($already) {
        Write-Log ("Frame-generation tool already running (PID {0}); leaving it alone." -f $already[0].Id) 'INFO'
        return
    }

    try {
        $proc = Start-Process -FilePath $exe -WindowStyle Minimized -PassThru
        $LaunchedByUs.Value = $true
        $ToolPid.Value      = $proc.Id
        Write-Log ("Frame-generation tool launched (PID {0}) - it inserts interpolated frames." -f $proc.Id) 'OK'
    } catch {
        Write-Log "Could not launch frame-generation tool: $_" 'WARN'
    }
}

function Stop-FrameGenerationTool {
    param([bool]$LaunchedByUs, [int]$ToolPid)
    if (-not $LaunchedByUs -or $ToolPid -le 0) { return }
    try {
        $p = Get-Process -Id $ToolPid -ErrorAction SilentlyContinue
        if ($p) {
            [void]$p.CloseMainWindow()          # graceful first
            Start-Sleep -Milliseconds 800
            if (-not $p.HasExited) { $p.Kill() }
            Write-Log 'Frame-generation tool closed.' 'INFO'
        }
    } catch { }
}

# ------------------------------------------------------------
# Legacy-GPU helper: per-game fullscreen-optimization compat flag.
# Old drivers stutter inside the DWM compositor path; disabling
# FSO for the game exe (standard AppCompatFlags registry value)
# forces true-exclusive behavior. Takes effect from the game's
# NEXT launch; we always undo our own entries on session end.
# ------------------------------------------------------------
$script:FsoKey = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'

function Invoke-FsoCompatFlag {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [hashtable]$State,     # exe paths we wrote -> $true
        [switch]$Undo
    )
    $path = $null
    try   { $path = $Process.Path } catch { }
    if (-not $path) { try { $path = $Process.MainModule.FileName } catch { } }
    if (-not $path) { return }

    try {
        if (-not (Test-Path $script:FsoKey)) {
            if ($Undo) { return }
            New-Item -Path $script:FsoKey -Force | Out-Null
        }
        $exe = [IO.Path]::GetFileName($path)
        if ($Undo) {
            Remove-ItemProperty -Path $script:FsoKey -Name $path -ErrorAction SilentlyContinue
            Write-Log ("Fullscreen-optimizations override removed for '{0}'." -f $exe) 'INFO'
        } else {
            if ($State.ContainsKey($path)) { return }
            New-ItemProperty -Path $script:FsoKey -Name $path `
                -Value '~ DISABLEDXMAXIMIZEDWINDOWEDMODE' -PropertyType String -Force | Out-Null
            $State[$path] = $true
            Write-Log ("Legacy mode: FSO disabled for '{0}' (applies on next launch)." -f $exe) 'INFO'
        }
    } catch {
        Write-Log "FSO compat flag failed for '$($Process.ProcessName)': $_" 'WARN'
    }
}

function Undo-FsoCompatFlags {
    param([hashtable]$State)
    foreach ($path in @($State.Keys)) {
        try {
            Remove-ItemProperty -Path $script:FsoKey -Name ([string]$path) -ErrorAction SilentlyContinue
        } catch { }
        $null = $State.Remove($path)
    }
}

# ------------------------------------------------------------
# 8. Game watcher: auto-detects games, boosts them, drops the
#    display resolution for the session, restores everything on
#    exit or stop. Parks on a wait handle => ~0% idle CPU and an
#    instantly-responsive stop signal.
#    LegacySettings: conservative profile for older GPUs -
#    SkipResolutionSwitch / DisableFullscreenOptimizations flags.
#    Stutter-safe resource policy: the 1 ms global timer and the
#    standby-memory purge are engaged only around actual game
#    sessions (purge lands in the loading screen; mid-game purges
#    require a critical RAM floor AND a long cooldown), and the
#    scan cadence slows down while no game is running.
# ------------------------------------------------------------
function Start-GameWatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$GameNames,
        [int]$PollSeconds = 10,              # scan cadence while a game is running
        [int]$IdlePollSeconds = 25,          # slower cadence while NO game runs (idle load)
        [int]$FreeRamThresholdMB = 2048,     # deprecated: mid-game purges use CriticalRamFloorMB
        [int]$CriticalRamFloorMB = 768,      # standby purge during play ONLY below this floor
        [int]$PurgeCooldownSeconds = 900,    # minimum seconds between two standby purges
        [switch]$PurgeOnGameLaunch,          # one purge when a game session starts
        [hashtable]$ProfileOverrides = @{},
        [hashtable]$ResolutionSettings = @{ ScalePercent = 66; PreferIntegerScale = $true },
        [hashtable]$FrameGenSettings   = @{ Enabled = $false; ToolPath = '' },
        [hashtable]$LegacySettings     = @{},
        [System.Threading.EventWaitHandle]$StopEvent = $null
    )

    Assert-AdminOrThrow

    # Never compete with the game: our own watcher yields under any load
    try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }

    # NOTE: the 1 ms timer is NOT taken here. Holding it for the whole
    # session raised idle interrupt load on low-spec laptops; it is now
    # engaged only while a game is actually running (see loop below).

    Write-GpuInventory

    $skipScale  = [bool]$LegacySettings['SkipResolutionSwitch']
    $fsoDisable = [bool]$LegacySettings['DisableFullscreenOptimizations']
    if ($skipScale)  { Write-Log 'Legacy GPU mode: dynamic resolution switching is DISABLED for this session.' 'INFO' }
    if ($fsoDisable) { Write-Log 'Legacy GPU mode: fullscreen optimizations will be disabled for detected games.' 'INFO' }

    Write-Log ("Game watcher started (poll {0}s while gaming, {1}s idle). Watching: {2}" -f `
        $PollSeconds, [Math]::Max($PollSeconds, $IdlePollSeconds), ($GameNames -join ',')) 'ACTION'
    Write-Log 'Games are auto-classified (Emulator / Steam / Competitive / Default) on launch.' 'INFO'
    if ($StopEvent) { Write-Log 'Background mode: stop via Stop-GamingSuite.bat.' 'INFO' }
    else            { Write-Log 'Press Ctrl+C to stop the watcher.' 'INFO' }

    $boosted   = @{}   # pid -> profile name
    $silenced  = @{}   # pid -> process name (background apps we deprioritized)
    $fsoDone   = @{}   # exe paths we flagged for FSO-off this session
    $fgByUs    = $false
    $fgPid     = 0
    $pollMs    = $PollSeconds * 1000
    $idleMs    = [Math]::Max($pollMs, $IdlePollSeconds * 1000)
    $timerOn       = $false                  # 1 ms pacing timer currently engaged
    $lastPurgeUtc  = [datetime]::MinValue    # cooldown gate for mid-game purges
    $sessionPurged = $false                  # launch-time purge done for this game session

    try {
        while ($true) {
            # Name-filtered lookup at the provider level - no full process
            # enumeration, no WMI. Two cheap native calls per poll total.
            $running = @(Get-Process -Name $GameNames -ErrorAction SilentlyContinue)

            foreach ($game in $running) {
                try {
                    if ($game.HasExited) { continue }
                    if (-not $boosted.ContainsKey($game.Id)) {
                        # ---- classify, then apply that type's profile ----
                        $profName = Get-GameProfile -Process $game -Overrides $ProfileOverrides
                        if (-not $script:GameProfiles.ContainsKey($profName)) { $profName = 'Default' }
                        $prof = $script:GameProfiles[$profName]

                        Write-Log ("Detected '{0}' (PID {1}) -> {2} profile [{3}]" -f `
                            $game.ProcessName, $game.Id, $profName, $prof.Description) 'ACTION'

                        # ---- frame pacing + memory hygiene at the quietest moment ----
                        # Both actions briefly cost system-wide time: the 1 ms timer
                        # raises interrupt frequency and a standby purge stalls the
                        # memory manager. Doing them here means the game's loading
                        # screen absorbs it instead of live gameplay.
                        if (-not $timerOn) {
                            Set-TimerResolution
                            $timerOn = $true
                        }
                        if ($PurgeOnGameLaunch -and -not $sessionPurged) {
                            try   { Clear-StandbyMemory } catch { }
                            $sessionPurged = $true
                            $lastPurgeUtc  = [datetime]::UtcNow
                        }

                        Invoke-ProcessBoost -Process $game -Profile $prof

                        # ---- GPU load relief: drop render resolution ----
                        if ($skipScale) {
                            Write-Log 'Legacy GPU mode: display switch skipped.' 'INFO'
                        } else {
                            $scalePct = if ($ResolutionSettings['ScalePercent']) { [int]$ResolutionSettings['ScalePercent'] } else { 66 }
                            $prefInt  = if ($null -ne $ResolutionSettings['PreferIntegerScale']) { [bool]$ResolutionSettings['PreferIntegerScale'] } else { $true }
                            Enable-LowResolutionMode -ScalePercent $scalePct -PreferInteger:([bool]$prefInt) | Out-Null
                        }

                        # ---- legacy comfort: kill FSO for this title ----
                        if ($fsoDisable) {
                            Invoke-FsoCompatFlag -Process $game -State $fsoDone
                        }

                        # ---- optional real frame generation via companion app ----
                        Invoke-FrameGenerationTool -Settings $FrameGenSettings `
                            -LaunchedByUs ([ref]$fgByUs) -ToolPid ([ref]$fgPid)

                        $boosted[$game.Id] = $profName

                        Update-BackgroundSilence -Names @($prof.Deprioritize) `
                            -ExceptPid $game.Id -State $silenced -Activate
                    } else {
                        $prof = $script:GameProfiles[$boosted[$game.Id]]
                        if ($game.PriorityClass -ne [string]$prof.Priority) {
                            # Re-assert if something knocked it back down
                            Invoke-ProcessBoost -Process $game -Profile $prof
                        }
                    }
                } catch {
                    Write-Log "Boost check failed for PID $($game.Id): $_" 'WARN'
                }
            }

            # Clean exited PIDs from tracking table
            $removedAny = $false
            foreach ($procId in @($boosted.Keys)) {
                if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
                    Write-Log ("'{0}' session ended (PID {1})." -f $boosted[$procId], $procId) 'INFO'
                    $null = $boosted.Remove($procId)
                    $removedAny = $true
                }
            }

            # Last game closed -> undo every session change
            if ($boosted.Count -eq 0) {
                if ($silenced.Count -gt 0) {
                    Update-BackgroundSilence -State $silenced
                    Write-Log 'Background app priorities restored.' 'OK'
                }
                if ($removedAny) {
                    Restore-NativeResolution          # back to full native sharpness
                    Stop-FrameGenerationTool -LaunchedByUs $fgByUs -ToolPid $fgPid
                    $fgByUs = $false; $fgPid = 0
                    if ($fsoDone.Count -gt 0) {
                        Undo-FsoCompatFlags -State $fsoDone
                        Write-Log 'Fullscreen-optimization overrides cleared.' 'OK'
                    }
                }
                # Release the pacing timer while idle (guarded, so this runs
                # once per game session, not on every idle poll).
                if ($timerOn) {
                    Set-TimerResolution -Restore
                    $timerOn = $false
                }
                $sessionPurged = $false
            }

            # Memory pressure check - deliberately rare now. A standby purge
            # stalls the whole memory manager (a visible hitch if it lands
            # mid-frame), so during play it happens ONLY below the critical
            # floor AND at most once per cooldown window. Anything less urgent
            # waits for the next game launch, where the loading screen absorbs
            # the cost.
            if ($running.Count -gt 0) {
                $nowUtc = [datetime]::UtcNow
                if (($nowUtc - $lastPurgeUtc).TotalSeconds -ge $PurgeCooldownSeconds) {
                    $freeMB = Get-FreeRamMB
                    if ($freeMB -lt $CriticalRamFloorMB) {
                        Write-Log ("Free RAM critical ({0} MB) - cooldown-gated standby purge..." -f $freeMB) 'WARN'
                        Clear-StandbyMemory
                        $lastPurgeUtc = [datetime]::UtcNow
                    }
                }
            }

            # Adaptive parking: full scan cadence while a game runs, slower
            # cadence while idle. Either way we park on the kernel event, so
            # the stop signal still wakes us instantly.
            $waitMs = if ($running.Count -gt 0) { $pollMs } else { $idleMs }
            if ($StopEvent) {
                if ($StopEvent.WaitOne($waitMs)) {
                    Write-Log 'Stop signal received.' 'ACTION'
                    break
                }
            } else {
                Start-Sleep -Milliseconds $waitMs
            }
        }
    } finally {
        Update-BackgroundSilence -State $silenced
        Stop-FrameGenerationTool -LaunchedByUs $fgByUs -ToolPid $fgPid
        Restore-NativeResolution           # never leave the screen scaled down
        Undo-FsoCompatFlags -State $fsoDone
        Set-TimerResolution -Restore
        Write-Log 'Game watcher stopped, priorities/timer/resolution restored.' 'INFO'
    }
}

Export-ModuleMember -Function Enable-GamingPowerPlan, Disable-GameDVR, Set-MultimediaTweaks,
    Set-TimerResolution, Clear-StandbyMemory, Invoke-ProcessBoost,
    Start-GameWatcher, Get-FreeRamMB, Get-GameProfile,
    Invoke-FrameGenerationTool, Stop-FrameGenerationTool
