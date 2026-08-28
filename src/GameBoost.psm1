# ============================================================
#  GameBoost.psm1 - FPS stability + dynamic game handling
#  (Valorant, Steam titles, PCSX2 and other emulators).
#
#  On game detection the watcher:
#    - classifies the title (Emulator / Steam / Competitive)
#    - raises its scheduling priority + steers it off core 0
#    - silences known background hogs (NEVER voice apps -
#      your microphone stays clean for other players)
#    - optionally boosts voice-chat apps so comms stay smooth
#    - DROPS THE DISPLAY RESOLUTION to cut GPU load
#      (restored to native automatically on game exit/stop)
#    - optionally launches a driver-level frame-generation
#      companion app if one is installed (see Config.ps1)
#
#  Stutter-free ramp-up: heavy, system-wide actions (standby
#  memory purge, display-mode switch) are STAGED with optimized
#  timing to eliminate launch stutter:
#    - Pre-game optimizations applied BEFORE game process appears
#    - Standby purge happens BEFORE launch (not after)
#    - Display switch uses longer delay to avoid loading-screen hitch
#    - Low-spec mode skips heavy operations entirely
#
#  Crash safety: every change is mirrored into a recovery
#  journal (logs/runtime/watcher_state.json) the moment it is
#  made; an unclean death is repaired automatically on next
#  start or stop (see Common.psm1 Repair-OrphanedWatcherState).
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
if (-not (Get-Module -Name 'NetTune')) {
    Import-Module (Join-Path $PSScriptRoot 'NetTune.psm1') -Force
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
        Windows-only (winmm/ntdll P/Invokes); on Linux/macOS/Android
        these native calls do not exist so we never compile them and
        the helper functions transparently use platform equivalents.
    #>
    if ('Suite.NativeBoost' -as [type]) { return }
    if (-not (Test-SuitePlatformWindows)) { return }
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
# Free RAM (per-platform, single call)
# ------------------------------------------------------------
function Get-FreeRamMB {
    Add-NativeBoostType
    if (Test-SuitePlatformWindows) {
        if (-not ('Suite.NativeBoost' -as [type])) { return 0 }
        $ms = New-Object Suite.NativeBoost+MEMORYSTATUSEX
        $ms.dwLength = [uint32][Runtime.InteropServices.Marshal]::SizeOf([type][Suite.NativeBoost+MEMORYSTATUSEX])
        [void][Suite.NativeBoost]::GlobalMemoryStatusEx([ref]$ms)
        [int]($ms.ullAvailPhys / 1MB)
    } elseif ($PSVersionTable.PSVersion.Major -ge 6 -and $IsLinux) {
        try {
            $memo = Get-Content /proc/meminfo -ErrorAction Stop
            foreach ($line in $memo) {
                if ($line -match '^MemAvailable:\s+(\d+)\s*kB') {
                    return [int](([int64]$Matches[1] * 1024) / 1MB)
                }
            }
        } catch { }
        0
    } elseif ($PSVersionTable.PSVersion.Major -ge 6 -and $IsMacOS) {
        try {
            $out = & vm_stat 2>$null | Out-String
            $free = 0L; $inactive = 0L
            if ($out -match 'Pages free:\s+(\d+)')            { $free = [int64]$Matches[1] }
            if ($out -match 'Pages inactive:\s+(\d+)')        { $inactive = [int64]$Matches[1] }
            [int](($free + $inactive) * 4096 / 1MB)
        } catch { 0 }
    } else { 0 }
}

# ------------------------------------------------------------
# 1. High-performance power plan + PCIe/CPU floor at max perf
# ------------------------------------------------------------
function Enable-GamingPowerPlan {
    [CmdletBinding()] param()

    if (-not (Test-SuitePlatformWindows)) {
        Write-Log 'Power-plan switching is Windows-only; skipped on this platform.' 'INFO'
        return
    }
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
    if (-not (Test-SuitePlatformWindows)) {
        Write-Log 'Game DVR / Game Bar tuning is Windows-only; skipped on this platform.' 'INFO'
        return
    }
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

    if (-not (Test-SuitePlatformWindows)) {
        Write-Log 'MMCSS scheduling tweaks are Windows-only; skipped on this platform.' 'INFO'
        return
    }
    Assert-AdminOrThrow

    $sysProfile = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    if (-not (Test-Path $sysProfile)) { New-Item -Path $sysProfile -Force | Out-Null }
    New-ItemProperty -Path $sysProfile -Name 'SystemResponsiveness' `
        -Value 10 -PropertyType DWord -Force | Out-Null

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
# 4. Timer resolution locked to 1-2 ms (frame pacing)
# ------------------------------------------------------------
function Set-TimerResolution {
    param(
        [switch]$Restore,
        [bool]$UseAggressive = $false
    )
    if (-not (Test-SuitePlatformWindows)) {
        if (-not $Restore) { Write-Log 'Windows timer-resolution locking is unavailable on this platform; skipping.' 'INFO' }
        return
    }
    Add-NativeBoostType
    if ($Restore) {
        if ($script:TimerActive) {
            [void][Suite.NativeBoost]::timeEndPeriod(2)
            $script:TimerActive = $false
            Write-Log 'Timer resolution restored to system default' 'INFO'
        }
        return
    }
    $period = if ($UseAggressive) { 1 } else { 2 }
    $result = [Suite.NativeBoost]::timeBeginPeriod($period)
    if ($result -eq 0) {
        $script:TimerActive = $true
        Write-Log "Global timer resolution locked at $period ms" 'OK'
    } else {
        Write-Log "timeBeginPeriod returned $result" 'WARN'
    }
}

# ------------------------------------------------------------
# 5. Standby memory purge (the #1 fix for sudden stutters
#    after the PC has been on for hours)
# ------------------------------------------------------------
function Clear-StandbyMemory {
    <#
        Frees the OS standby/cleanable memory. Windows uses the classic
        EmptyStandbyList system call; Linux drops page caches via
        /proc/sys/vm/drop_caches; macOS uses the system 'purge' tool.
        Elevation is required wherever a write is involved.
    #>
    if (Test-SuitePlatformWindows) {
        Assert-AdminOrThrow

        Add-NativeBoostType
        if (-not ('Suite.NativeBoost' -as [type])) { return }
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
        return
    }

    if ($PSVersionTable.PSVersion.Major -ge 6 -and $IsLinux) {
        try {
            if (-not (Test-Path /proc/sys/vm/drop_caches)) {
                Write-Log 'Standby purge unavailable (no /proc/sys/vm/drop_caches).' 'WARN'
                return
            }
            Set-Content -Path /proc/sys/vm/drop_caches -Value '3' -NoNewline -ErrorAction Stop
            $freeGB = [math]::Round((Get-FreeRamMB) / 1024.0, 2)
            Write-Log "Standby memory purged (free RAM now ~$freeGB GB)" 'OK'
        } catch {
            Write-Log ("Linux standby purge failed: {0}" -f $_.Exception.Message) 'ERROR'
        }
        return
    }

    if ($PSVersionTable.PSVersion.Major -ge 6 -and $IsMacOS) {
        try {
            & /usr/sbin/purge 2>$null | Out-Null
            $freeGB = [math]::Round((Get-FreeRamMB) / 1024.0, 2)
            Write-Log "Standby memory purged (free RAM now ~$freeGB GB)" 'OK'
        } catch {
            Write-Log ("macOS purge failed: {0}" -f $_.Exception.Message) 'ERROR'
        }
        return
    }

    Write-Log 'Standby memory purge is unavailable on this platform.' 'WARN'
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
        Priority         = 'AboveNormal'
        AvoidCores       = @(0)
        # NOTE: Discord/voice apps are deliberately NOT silenced - they carry
        # your microphone. See $script:VoiceAppPatterns + Update-VoiceChatSupport.
        Deprioritize     = @('steamwebhelper','chrome','msedge','firefox','spotify')
        Description      = 'Latency-critical online play: AboveNormal priority + browsers/Steam silenced'
    }
    'Android' = @{
        Priority         = 'High'
        AvoidCores       = @(0)
        Deprioritize     = @()
        Description      = 'Android emulator: High CPU priority for emulation threads'
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
    'epsxe*', 'mesen*', 'fceux*', 'snes9x*', 'bizhawk*', 'mame*',
    'play!', 'mednafen*', 'citron*', 'ruffle*'
)
$script:OnlineNames = @(
    'valorant-win64', 'cs2', 'csgo', 'dota2', 'fortniteclient*', 'javaw',
    'r5apex*', 'overwatch*', 'roguecompany*', 'rocketleague*',
    'paladins*', 'warframe*', 'destiny2*', 'tsgame*',
    'marvelrivals*', 'helldivers2*', 'deltaforce*',
    'stalker2*', 'oncehuman*', 'the_first_descendant*',
    'leagueclient', 'lol_dragon'
)
$script:SteamNames = @(
    'gta5*', 'rdr2*', 'cyberpunk2077', 'eldenring*', 'hogwarts*',
    'baldursgate3', 'bg3_dx11*', 'witcher3', 'stardew*', 'terraria',
    'hollowknight*', 'celeste*', 'hades*', 'portal2', 'halo*', 'forza*',
    'starfield*', 'palworld*', 'lethalcompany*', 'contentwarning*',
    'cyberpunk2077'
)

# Android emulator process patterns
$script:AndroidEmulatorNames = @(
    'ldboxheadless', 'ldvboxheadless', 'ldplayer', 'dnplayer',
    'nox', 'noxhandle', 'noxvmhandle',
    'mumuplayer', 'mumuvmmheadless',
    'bluestacks', 'hd-player', 'bstkvmm',
    'memu', 'memuheadless'
)

# Voice/chat apps that must NEVER be silenced while gaming - they carry
# your microphone and team audio. Extended via Config.ps1
# VoiceClarity.ExtraProtectedProcessNames.
$script:VoiceAppPatterns = @(
    'discord*', 'voicemeter*', 'ts3client*', 'teamspeak*',
    'zoom*', 'skype*', 'webex*'
)

# Recording/capture software that must NEVER be deprioritized or
# disrupted. These processes compete with the game for GPU/CPU and
# any hitch in their scheduling causes visible stutter in recordings.
# Extended via Config.ps1 RecordingSoftware.ProtectedProcesses.
$script:RecordingPatterns = @(
    'obs64', 'obs32',                   # OBS Studio
    'streamlabs',                        # Streamlabs Desktop
    'streamelements',                    # StreamElements
    'twitchstudio'                       # Twitch Studio
)

function Test-MatchAny {
    <# Wildcard matcher over many patterns (all lowercase). Returns $true
       when $Name matches any pattern. Case-insensitive on every platform. #>
    param([string]$Name, [string[]]$Patterns)
    foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
    return $false
}

function Get-GameProfile {
    <#
        Classifies a running game process into one of the profile names:
        'Emulator' | 'Steam' | 'Competitive' | 'Android' | 'Default'.
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
        if ($lp -match 'bluestacks|nox|ldplayer|memu|mumu|memuplay') { return 'Android' }
    }

    # 3. Process-name heuristics
    foreach ($n in $script:AndroidEmulatorNames) { if ($name -like $n) { return 'Android' } }
    foreach ($n in $script:EmulatorNames) { if ($name -like $n) { return 'Emulator' } }
    foreach ($n in $script:OnlineNames)   { if ($name -like $n) { return 'Competitive' } }
    foreach ($n in $script:SteamNames)    { if ($name -like $n) { return 'Steam' } }

    return 'Default'
}

function Get-GameScalePercent {
    <#
        Resolves the display-scaling target (% of native width) for a
        detected game. Could be met by ANY display mode the monitor
        advertises (480p / 720p / 900p / 1080p / etc.) because
        Select-ScaledMode picks the closest same-aspect mode to the
        target percent.
        Resolution precedence:
          1. GameTierOverrides keyed by the exact process name
          2. ProfileTiers default for the game's profile
             (Emulator / Steam / Competitive / Android / Default)
          3. the global ScalePercent fallback (legacy single value)
        Tier values come from ResolutionTiers (Low/Medium/High/Native).
        Returns 0 for 'Native' (keep the panel resolution - no switch).
        Never throws.
    #>
    param(
        [string]$ProfileName,
        [string]$ProcessName,
        [hashtable]$Settings = @{}
    )

    $tiers  = @{}
    $pTiers = @{}
    $o      = @{}
    if ($Settings.ContainsKey('Tiers'))             { $tiers  = $Settings['Tiers'] }
    if ($Settings.ContainsKey('ProfileTiers'))      { $pTiers = $Settings['ProfileTiers'] }
    if ($Settings.ContainsKey('GameTierOverrides')) { $o      = $Settings['GameTierOverrides'] }

    $fallback = 66
    if ($Settings.ContainsKey('ScalePercent')) { $fallback = [int]$Settings['ScalePercent'] }

    # 1) per-game override (exact, case-insensitive process name)
    $tier = $null
    foreach ($k in $o.Keys) {
        if ([string]::Equals([string]$k, $ProcessName, [StringComparison]::OrdinalIgnoreCase)) {
            $tier = $o[$k]
            break
        }
    }
    # 2) default tier for this profile
    if (-not $tier -and $pTiers.ContainsKey($ProfileName)) { $tier = $pTiers[$ProfileName] }

    # 3) tier name -> target percent
    $percent = $null
    if ($tier) {
        foreach ($tk in $tiers.Keys) {
            if ([string]::Equals([string]$tk, [string]$tier, [StringComparison]::OrdinalIgnoreCase)) {
                $percent = $tiers[$tk]
                break
            }
        }
    }
    if ($null -eq $percent) { $percent = $fallback }

    $p = [int]$percent
    if ($p -ge 25 -and $p -le 99) { return $p }   # valid scaled target
    return 0                                      # <=0/<25 -> Native (no switch)
}

# ------------------------------------------------------------
# 6. Per-process boost driven by the game's profile
# ------------------------------------------------------------
$script:PriorityCapable = $true
$script:PriorityCapWarned = $false

function Invoke-ProcessBoost {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][hashtable]$Profile,
        [int]$MaxCores = 0
    )

    try {
        if ($Process.HasExited) { return }

        # Realtime is deliberately never used - it starves input threads
        $wantPri = [string]$Profile.Priority
        if ($script:PriorityCapable) {
            try {
                if ($Process.PriorityClass -ne $wantPri) {
                    $Process.PriorityClass = $wantPri
                    Write-Log ("Priority -> {0} for '{1}' (PID {2})" -f $wantPri, $Process.ProcessName, $Process.Id) 'OK'
                }
            } catch {
                # Not elevated on Unix (or exotic process): drop PR permanently
                # instead of hammering the watcher with a warning every poll.
                if (-not (Test-SuitePlatformWindows)) {
                    $script:PriorityCapable = $false
                    if (-not $script:PriorityCapWarned) {
                        $script:PriorityCapWarned = $true
                        Write-Log 'Process-priority boosting unavailable (needs root on this platform); falling back to affinity steering only.' 'WARN'
                    }
                } else {
                    throw
                }
            }
        }

        # Spread the game off the interrupt core (USB/NIC DPCs land there)
        $avoid = @($Profile.AvoidCores)
        $total = [Environment]::ProcessorCount
        if ($MaxCores -gt 0 -and $MaxCores -lt $total) { $total = $MaxCores }
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
# Background-app silencing used by the Steam/Competitive profiles.
# Voice-chat apps (see $script:VoiceAppPatterns + extra names from
# Config.ps1) are ALWAYS skipped so microphone audio stays clean.
# ------------------------------------------------------------
function Update-BackgroundSilence {
    param(
        [string[]]$Names,
        [int]$ExceptPid,
        [hashtable]$State,           # pid -> info of processes currently silenced
        [hashtable]$Journal,         # recovery journal (optional)
        [string[]]$ProtectedPatterns = @(),
        [string[]]$RecordingPatterns = @(),
        [switch]$Activate            # off = restore everything in $State to Normal
    )

    if (-not $Activate) {
        foreach ($procId in @($State.Keys)) {
            try {
                $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($p -and $p.PriorityClass -eq 'BelowNormal') { $p.PriorityClass = 'Normal' }
            } catch { }
            $null = $State.Remove($procId)
            if ($Journal -and $Journal['silenced'].ContainsKey($procId)) {
                $null = $Journal['silenced'].Remove($procId)
            }
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
            # Never touch voice/chat apps - they carry the microphone
            $isVoice = $false
            foreach ($pat in $ProtectedPatterns) {
                if ($t.ProcessName -like $pat) { $isVoice = $true; break }
            }
            if ($isVoice) { continue }
            # Never touch recording/capture software - causes frame drops in recordings
            $isRecorder = $false
            foreach ($pat in $RecordingPatterns) {
                if ($t.ProcessName -like $pat) { $isRecorder = $true; break }
            }
            if ($isRecorder) { continue }
            if (-not $State.ContainsKey($t.Id)) {
                $t.PriorityClass = 'BelowNormal'
                $State[$t.Id] = @{ Name = $t.ProcessName; Priority = 'BelowNormal' }
                if ($Journal) {
                    $Journal['silenced'][$t.Id] = @{ Name = $t.ProcessName; Priority = 'BelowNormal' }
                    Save-WatcherJournal -State $Journal
                }
                Write-Log ("Silenced background app '{0}' (PID {1}) while gaming" -f $t.ProcessName, $t.Id) 'INFO'
            }
        } catch { }
    }
}

# ------------------------------------------------------------
# Voice-chat support: while a game runs, give Discord & friends a
# modest AboveNormal bump so voice encoding/capture never starves
# behind the boosted game - clear mic for other players even on
# weak CPUs. Original priorities are journaled and restored.
# ------------------------------------------------------------
function Update-VoiceChatSupport {
    param(
        [Parameter(Mandatory)][string[]]$Patterns,
        [int]$ExceptPid,
        [hashtable]$State,           # pid -> @{ Name; Prev }
        [hashtable]$Journal,
        [switch]$Activate
    )

    if (-not $Patterns -or @($Patterns).Count -eq 0) { return }

    if (-not $Activate) {
        foreach ($procId in @($State.Keys)) {
            try {
                $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($p -and $p.PriorityClass -eq 'AboveNormal') {
                    $prev = $State[$procId]['Prev']
                    $p.PriorityClass = $(if ($prev) { $prev } else { 'Normal' })
                }
            } catch { }
            $null = $State.Remove($procId)
            if ($Journal -and $Journal['voiceBoosted'].ContainsKey($procId)) {
                $null = $Journal['voiceBoosted'].Remove($procId)
            }
        }
        return
    }

    $targets = @(Get-Process -Name @($Patterns) -ErrorAction SilentlyContinue)
    foreach ($t in $targets) {
        try {
            if ($t.Id -eq $ExceptPid -or $t.Id -eq $PID) { continue }
            if ($State.ContainsKey($t.Id)) { continue }
            $prev = [string]$t.PriorityClass
            if ($prev -eq 'RealTime') { continue }
            if ($prev -ne 'AboveNormal') { $t.PriorityClass = 'AboveNormal' }
            $State[$t.Id] = @{ Name = $t.ProcessName; Prev = $prev }
            if ($Journal) {
                $Journal['voiceBoosted'][$t.Id] = @{ Name = $t.ProcessName; Prev = $prev }
                Save-WatcherJournal -State $Journal
            }
            Write-Log ("Voice app '{0}' (PID {1}) -> AboveNormal for stutter-free mic" -f $t.ProcessName, $t.Id) 'INFO'
        } catch { }
    }
}

# ------------------------------------------------------------
# Recording-software detection: lightweight one-shot check
# ------------------------------------------------------------
function Test-RecordingSoftwareActive {
    <#
        Returns $true if any known recording/capture software is running.
        Uses a focused Get-Process -Name call (kernel-level, no WMI/CIM).
        The result is cached for the duration of one poll cycle so multiple
        checks within the same iteration don't repeat the syscall.
    #>
    param(
        [string[]]$ExtraPatterns = @(),
        [ref]$CacheVar
    )

    $all = @($script:RecordingPatterns) + @($ExtraPatterns)
    if ($all.Count -eq 0) { return $false }

    # Return cached result if still valid this poll cycle
    if ($CacheVar -and $CacheVar.Value -ne $null) { return [bool]$CacheVar.Value }

    $found = $false
    try {
        $procs = Get-Process -Name @($all) -ErrorAction SilentlyContinue
        if ($procs -and $procs.Count -gt 0) { $found = $true }
    } catch { }

    if ($CacheVar) { $CacheVar.Value = $found }
    return $found
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
        [hashtable]$Journal,
        [switch]$Undo
    )
    if (-not (Test-SuitePlatformWindows)) { return }   # AppCompat registry is Windows-only
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
            if ($Journal) {
                $Journal['fsoFlags'] = @(@($Journal['fsoFlags']) + $path)
                Save-WatcherJournal -State $Journal
            }
            Write-Log ("Legacy mode: FSO disabled for '{0}' (applies on next launch)." -f $exe) 'INFO'
        }
    } catch {
        Write-Log "FSO compat flag failed for '$($Process.ProcessName)': $_" 'WARN'
    }
}

function Undo-FsoCompatFlags {
    param([hashtable]$State, [hashtable]$Journal)
    if (-not (Test-SuitePlatformWindows)) { return }
    foreach ($path in @($State.Keys)) {
        try {
            Remove-ItemProperty -Path $script:FsoKey -Name ([string]$path) -ErrorAction SilentlyContinue
        } catch { }
        $null = $State.Remove($path)
    }
    if ($Journal) {
        $Journal['fsoFlags'] = @()
        Save-WatcherJournal -State $Journal
    }
}

# ------------------------------------------------------------
# 8. Game watcher: auto-detects games, boosts them, drops the
#    display resolution for the session, restores everything on
#    exit or stop. Parks on a wait handle => ~0% idle CPU and an
#    instantly-responsive stop signal.
#
#    SESSION-SCOPED LIFE (ExitWhenGameSessionEnds, default on):
#    - before any game appears it waits patiently (no heavy load)
#    - when the last monitored game exits it undoes every change
#      and EXITS completely instead of staying resident, so no
#      background process keeps polling for a "next game" on a
#      low-spec machine. Stop-GamingSuite.bat / menu option 5
#      still stop it instantly at any time.
#    Set ExitWhenGameSessionEnds = $false in Config.ps1 for the
#    old always-on behavior.
#
#    STUTTER-FREE DESIGN:
#    - Pre-game optimizations applied BEFORE game process appears
#    - Standby purge BEFORE game launch (during pre-detect phase)
#    - Staged ramp-up with optimized delays
#    - Low-spec mode skips heavy operations entirely
#    - Adaptive timing based on hardware capability
#    All changes are mirrored to the crash-recovery journal.
# ------------------------------------------------------------
function Start-GameWatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$GameNames,
        [int]$PollSeconds = 10,              # scan cadence while a game is running
        [int]$IdlePollSeconds = 25,          # slower cadence while NO game runs (idle load)
        [int]$ExtendedIdlePollSeconds = 60,  # even slower when idle for a long time (ultra-low CPU)
        [int]$IdleHeartbeatMinutes = 5,      # log "watcher alive" every N minutes while idle
        [int]$FreeRamThresholdMB = 2048,     # deprecated: mid-game purges use CriticalRamFloorMB
        [int]$CriticalRamFloorMB = 768,      # standby purge during play ONLY below this floor
        [int]$PurgeCooldownSeconds = 900,    # minimum seconds between two standby purges
        [switch]$PurgeOnGameLaunch,          # one purge shortly after a game is detected
        [hashtable]$ProfileOverrides = @{},
        [hashtable]$ResolutionSettings = @{ ScalePercent = 66; PreferIntegerScale = $true },
        [hashtable]$FrameGenSettings   = @{ Enabled = $false; ToolPath = '' },
        [hashtable]$LegacySettings     = @{},
        [hashtable]$NetworkSettings    = @{ Enabled = $true },
        [hashtable]$VoiceSettings      = @{},
        [hashtable]$LowSpecSettings    = @{ Enabled = $false },
        [hashtable]$RecordingSettings  = @{ Enabled = $true },
        [bool]$PreGameOptimization = $true,
        [bool]$PrePurgeBeforeLaunch = $true,
        [bool]$ExitWhenGameSessionEnds = $true,
        [System.Threading.EventWaitHandle]$StopEvent = $null
    )

    Assert-AdminOrThrow

    # ---- recover anything a previous unclean session left behind ----
    try { Repair-OrphanedWatcherState | Out-Null } catch { }

    # A killed watcher can leave a stale stop marker behind (Unix stop
    # file; on Windows the kernel event dies with the process). Clear it
    # so this fresh session is not stopped before it even starts.
    Clear-StopRequest

    # Never compete with the game: our own watcher yields under any load
    try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }

    # ---- resolve low-spec mode ----
    $isLowSpec = [bool]$LowSpecSettings['Enabled']
    $lowSpecSkipRes = [bool]$LowSpecSettings['SkipResolutionSwitch']
    $lowSpecSkipPurge = [bool]$LowSpecSettings['SkipStandbyPurge']
    $lowSpecSkipSilence = [bool]$LowSpecSettings['SkipBackgroundSilence']
    $lowSpecSkipFrameGen = [bool]$LowSpecSettings['SkipFrameGenBridge']
    $lowSpecReducedPoll = [bool]$LowSpecSettings['ReducedPolling']
    $lowSpecMaxCores = if ($LowSpecSettings['MaxCpuCores']) { [int]$LowSpecSettings['MaxCpuCores'] } else { 0 }
    $lowSpecAggressiveTimer = [bool]$LowSpecSettings['AggressiveTimer']

    if ($isLowSpec) {
        Write-Log 'Low-spec mode ACTIVE: optimizing for older/weaker hardware.' 'WARN'
        if ($lowSpecSkipRes) { Write-Log '  - Resolution switching: DISABLED' 'INFO' }
        if ($lowSpecSkipPurge) { Write-Log '  - Standby memory purge: DISABLED' 'INFO' }
        if ($lowSpecSkipSilence) { Write-Log '  - Background silencing: DISABLED' 'INFO' }
        if ($lowSpecSkipFrameGen) { Write-Log '  - Frame-gen bridge: DISABLED' 'INFO' }
        if ($lowSpecReducedPoll) {
            $PollSeconds = [Math]::Max($PollSeconds, 15)
            $IdlePollSeconds = [Math]::Max($IdlePollSeconds, 35)
            $ExtendedIdlePollSeconds = [Math]::Max($ExtendedIdlePollSeconds, 90)
            Write-Log ("  - Polling: {0}s gaming / {1}s idle / {2}s extended idle" -f $PollSeconds, $IdlePollSeconds, $ExtendedIdlePollSeconds) 'INFO'
        }
    }

    # ---- resolve recording software settings --------------------
    $recOn = $true
    if ($RecordingSettings -and $RecordingSettings.ContainsKey('Enabled')) { $recOn = [bool]$RecordingSettings['Enabled'] }
    $recSkipRes  = $false
    $recSkipPurge = $false
    $recExtraProtected = @()
    if ($recOn) {
        if ($RecordingSettings.ContainsKey('SkipResolutionSwitch')) { $recSkipRes = [bool]$RecordingSettings['SkipResolutionSwitch'] }
        if ($RecordingSettings.ContainsKey('SkipStandbyPurge'))    { $recSkipPurge = [bool]$RecordingSettings['SkipStandbyPurge'] }
        if ($RecordingSettings.ContainsKey('ProtectedProcesses')) {
            $recExtraProtected = @($RecordingSettings['ProtectedProcesses']) | ForEach-Object { "$_*" }
        }
        if ($recSkipRes -or $recSkipPurge) {
            Write-Log 'Recording software detection ACTIVE: capture-safe paths enabled.' 'INFO'
            if ($recSkipRes)  { Write-Log '  - Resolution switch: DEFERRED while recorder running' 'INFO' }
            if ($recSkipPurge) { Write-Log '  - Standby purge: DEFERRED while recorder running' 'INFO' }
        }
    }

    Write-GpuInventory

    $skipScale  = [bool]$LegacySettings['SkipResolutionSwitch'] -or $lowSpecSkipRes
    # Display scaling picks its own backend by platform (user32 / xrandr /
    # displayplacer) and is a safe no-op where none is available, so Unix
    # hosts are only excluded here if the user or legacy profile asks.
    $fsoDisable = [bool]$LegacySettings['DisableFullscreenOptimizations'] -and (Test-SuitePlatformWindows)
    if ($skipScale)  { Write-Log 'Resolution switching is DISABLED for this session.' 'INFO' }
    if ($fsoDisable) { Write-Log 'Fullscreen optimizations will be disabled for detected games.' 'INFO' }

    # ---- resolve network + voice settings ------------------------------
    $netOn = $true
    if ($NetworkSettings -and $NetworkSettings.ContainsKey('Enabled')) { $netOn = [bool]$NetworkSettings['Enabled'] }

    $micMmcss = $true
    if ($VoiceSettings -and $VoiceSettings.ContainsKey('MmcssAudioPriority')) { $micMmcss = [bool]$VoiceSettings['MmcssAudioPriority'] }

    $protectedExtra = @()
    if ($VoiceSettings -and $VoiceSettings.ContainsKey('ExtraProtectedProcessNames')) {
        $protectedExtra = @($VoiceSettings['ExtraProtectedProcessNames']) | ForEach-Object { "$_*" }
    }
    $protectedNames = @($script:VoiceAppPatterns) + $protectedExtra + $recExtraProtected

    $boostVoice = $true
    if ($VoiceSettings -and $VoiceSettings.ContainsKey('BoostVoiceAppsDuringGame')) { $boostVoice = [bool]$VoiceSettings['BoostVoiceAppsDuringGame'] }

    # Recovery journal - written through at EVERY state change so any
    # kind of death (kill, console close, crash, power loss) is fully
    # repairable by the next start/stop.
    $journal = @{
        scaledActive = $false
        nativeMode   = $null
        silenced     = @{}
        voiceBoosted = @{}
        fsoFlags     = @()
        fgToolPid    = 0
        net          = $null
    }
    function Save-Journal { Save-WatcherJournal -State $journal }

    # ---- PRE-GAME OPTIMIZATION: apply network/multimedia BEFORE
    #     any game is detected, so tweaks are in place when the
    #     first game opens its sockets (eliminates launch stutter
    #     caused by applying network tweaks after connection).
    if ($PreGameOptimization) {
        Write-Log 'Pre-game optimizations: applying power/network/multimedia tweaks...' 'ACTION'
        try {
            if ($netOn) {
                Enable-GameNetworkProfile -Settings $NetworkSettings -JournalState $journal
                Save-Journal
            }
        } catch {
            Write-Log "Network optimization unavailable: $_" 'WARN'
            $netOn = $false
        }
        try {
            if ($micMmcss) { Set-MicClarityTweaks -IncludeMmcss $micMmcss }
        } catch { Write-Log "Mic clarity tweak skipped: $_" 'WARN' }
    } else {
        # Apply network profile BEFORE games connect (legacy path)
        if ($netOn) {
            try { Enable-GameNetworkProfile -Settings $NetworkSettings -JournalState $journal; Save-Journal }
            catch {
                Write-Log "Network optimization unavailable: $_" 'WARN'
                $netOn = $false
            }
        }
        if ($micMmcss) {
            try { Set-MicClarityTweaks -IncludeMmcss $micMmcss } catch { Write-Log "Mic clarity tweak skipped: $_" 'WARN' }
        }
    }

    Write-Log ("Game watcher started (poll {0}s while gaming, {1}s idle). Watching: {2}" -f `
        $PollSeconds, [Math]::Max($PollSeconds, $IdlePollSeconds), ($GameNames -join ',')) 'ACTION'
    Write-Log 'Games are auto-classified (Emulator / Steam / Competitive / Android / Default) on launch.' 'INFO'
    if ($protectedNames.Count -gt 0) {
        Write-Log ("Voice apps protected from silencing: {0}" -f (($protectedNames | ForEach-Object { $_.TrimEnd('*') }) -join ', ')) 'INFO'
    }
    if ($StopEvent) { Write-Log 'Background mode: stop via Stop-GamingSuite.bat.' 'INFO' }
    else            { Write-Log 'Press Ctrl+C to stop the watcher.' 'INFO' }

    $boosted       = @{}   # pid -> profile name
    $scalePctByPid = @{}   # pid -> resolution tier percent chosen on detect
    $silenced      = @{}   # pid -> info (background apps we deprioritized)
    $voiceBoosted  = @{}   # pid -> info (voice apps bumped for mic clarity)
    $fsoDone       = @{}   # exe paths we flagged for FSO-off this session
    $fgByUs        = $false
    $fgPid         = 0
    $hadSession    = $false   # any game was actually detected+boosted this run
    $pollMs        = $PollSeconds * 1000
    $idleMs        = [Math]::Max($pollMs, $IdlePollSeconds * 1000)
    $extIdleMs     = [Math]::Max($idleMs, $ExtendedIdlePollSeconds * 1000)
    $timerOn       = $false                  # 1ms/2ms pacing timer currently engaged
    $lastPurgeUtc  = [datetime]::MinValue    # cooldown gate for mid-game purges
    $sessionPurged = $false                  # launch-time purge done for this game session
    $scaledApplied = $false                  # display currently scaled by us
    $preGamePurged = $false                  # pre-launch purge has run (stutter prevention)

    # ---- idle tracking: ultra-low resource mode ---------------------------
    $idleSinceUtc     = [datetime]::UtcNow   # when we last transitioned to idle
    $lastHeartbeatUtc = [datetime]::MinValue  # last time we logged "watcher alive"
    $wasIdle           = $true                # start idle (no games yet)
    $idleHeartbeatMs   = $IdleHeartbeatMinutes * 60 * 1000

    $scalePct = if ($ResolutionSettings['ScalePercent'])      { [int]$ResolutionSettings['ScalePercent'] }      else { 66 }
    $prefInt  = if ($null -ne $ResolutionSettings['PreferIntegerScale']) { [bool]$ResolutionSettings['PreferIntegerScale'] } else { $true }

    # ---- staged ramp-up queue -------------------------------------------
    # Detection enqueues; the loop executes each stage when due. While
    # stages are pending the loop wakes early, still parking on the
    # kernel event, so the stop signal stays instant.
    $ramp = [System.Collections.Generic.List[object]]::new()
    function Add-Ramp { param([string]$Kind, [double]$DelaySec, [int]$TargetPid, [int]$Value = 0)
        $ramp.Add(@{ DueUtc = [datetime]::UtcNow.AddSeconds($DelaySec); Kind = $Kind; Pid = $TargetPid; Value = $Value })
    }
    function Test-RampPending { param([string]$Kind)
        foreach ($a in $ramp) { if ($a.Kind -eq $Kind) { return $true } }
        return $false
    }
    $extrasQueued = @{}

    # ---- performance throttling: avoid redundant work per cycle --
    # Background silence is expensive (iterates all target processes);
    # only re-run it every N cycles (30s at 15s poll) instead of every poll.
    $silenceThrottleSec = if ($isLowSpec) { 45 } else { 30 }
    $lastSilenceUtc     = [datetime]::MinValue
    # PID exit checks: only scan the boosted table every other cycle
    # when gaming (the common case is no exits), halving the process
    # checks inside the cleanup loop.
    $exitCheckCounter   = 0

    # ---- precompiled matchers (once per watcher run) -----------------
    # Watching 100+ game names individually via Get-Process -Name forces
    # PowerShell to enumerate the whole process table per name-list. We
    # instead snapshot the table ONCE per poll and run cheap lowercase
    # wildcard matches in-process - cheaper on every platform, and on a
    # low-spec machine this is the difference between 1% and 0.05% CPU.
    $gameWatchPatterns = @($GameNames | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $recWatchPatterns  = @($script:RecordingPatterns + $recExtraProtected | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $recWatchPatterns  = @($recWatchPatterns | Where-Object { $_ })

    try {
        while ($true) {
            # One native process snapshot serves both the game lookup and
            # the recording-detection check for this poll cycle.
            try {
                $allProc = [Diagnostics.Process]::GetProcesses()
            } catch {
                Write-Log ("Process snapshot failed: {0}" -f $_.Exception.Message) 'WARN'
                $allProc = @()
            }
            $processes = @($allProc | ForEach-Object {
                $n = ''
                try { $n = $_.ProcessName } catch { }
                if (-not $n) { return }
                $nl = $n.ToLowerInvariant()
                $isGameMatch = Test-MatchAny -Name $nl -Patterns $gameWatchPatterns
                $isRecMatch  = $recOn -and (Test-MatchAny -Name $nl -Patterns $recWatchPatterns)
                if ($isGameMatch -or $isRecMatch) {
                    $_                     # game OR recorder - keep the Process object
                }
            })

            $running = @($processes | Where-Object {
                try { $nl = $_.ProcessName.ToLowerInvariant() } catch { return $false }
                Test-MatchAny -Name $nl -Patterns $gameWatchPatterns
            })
            $isRecording = $false
            if ($recOn) {
                $isRecording = @($processes | Where-Object {
                    try { $nl = $_.ProcessName.ToLowerInvariant() } catch { return $false }
                    Test-MatchAny -Name $nl -Patterns $recWatchPatterns
                }).Count -gt 0
            }

            foreach ($game in $running) {
                try {
                    if ($game.HasExited) { continue }
                    if (-not $boosted.ContainsKey($game.Id)) {
                        # ---- classify, then apply that type's profile ----
                        $profName = Get-GameProfile -Process $game -Overrides $ProfileOverrides
                        if (-not $script:GameProfiles.ContainsKey($profName)) { $profName = 'Default' }
                        $prof = $script:GameProfiles[$profName]

                        # ---- resolve this game's resolution tier ----
                        #     Low/Medium/High/Native -> a % of native width.
                        #     Zero means "Native" = no display switch at all.
                        $scalePctForGame = Get-GameScalePercent -ProfileName $profName `
                            -ProcessName $game.ProcessName -Settings $ResolutionSettings
                        $scalePctByPid[$game.Id] = $scalePctForGame

                        Write-Log ("Detected '{0}' (PID {1}) -> {2} profile [{3}] ; res tier {4} (target {5}% of native)" -f `
                            $game.ProcessName, $game.Id, $profName, $prof.Description, `
                            $(if ($scalePctForGame -gt 0) { "scaled" } else { "native" }), `
                            $(if ($scalePctForGame -gt 0) { $scalePctForGame } else { 100 })) 'ACTION'

                        # ---- INSTANT, cheap steps: pacing timer + scheduling ----
                        if (-not $timerOn) {
                            Set-TimerResolution -UseAggressive:([bool]$lowSpecAggressiveTimer)
                            $timerOn = $true
                        }
                        Invoke-ProcessBoost -Process $game -Profile $prof -MaxCores $lowSpecMaxCores

                        # ---- PRE-LAUNCH PURGE: run BEFORE game fully loads ----
                        #     to prevent launch stutter. The game's own loading
                        #     screen will mask any remaining memory pressure.
                        #     DEFERRED while recording software is active to
                        #     prevent hitch in the captured output.
                        $recSkipPurgeNow = $isRecording -and $recSkipPurge
                        if ($PrePurgeBeforeLaunch -and -not $preGamePurged -and -not $lowSpecSkipPurge -and -not $recSkipPurgeNow -and -not (Test-RampPending 'purge')) {
                            Add-Ramp 'purge' 0.5 0   # 0.5s delay - fast enough to run before game loads
                        }
                        $preGamePurged = $true

                        # ---- HEAVY steps go onto the staged ramp so the loading
                        #      screen absorbs them one at a time (no launch hitch) ----
                        if ($PurgeOnGameLaunch -and -not $sessionPurged -and -not $lowSpecSkipPurge -and -not $recSkipPurgeNow -and -not (Test-RampPending 'purge2')) {
                            Add-Ramp 'purge2' 8 0   # secondary purge during loading
                        }
                        $recSkipResNow = $isRecording -and $recSkipRes
                        if (-not $skipScale -and -not $recSkipResNow -and -not $scaledApplied -and -not (Test-RampPending 'resscale') -and $scalePctForGame -gt 0) {
                            Add-Ramp 'resscale' 12 0 $scalePctForGame   # display switch after game stabilizes
                        }
                        if (-not $extrasQueued.ContainsKey($game.Id)) {
                            $extrasQueued[$game.Id] = $true
                            Add-Ramp 'extras' 1 $game.Id
                        }

                        $boosted[$game.Id] = $profName
                        $hadSession = $true

                        if (-not $lowSpecSkipSilence) {
                            Update-BackgroundSilence -Names @($prof.Deprioritize) `
                                -ExceptPid $game.Id -State $silenced -Journal $journal `
                                -ProtectedPatterns $protectedNames -RecordingPatterns $script:RecordingPatterns -Activate
                            $lastSilenceUtc = [datetime]::UtcNow
                        }

                        if ($boostVoice) {
                            Update-VoiceChatSupport -Patterns $protectedNames `
                                -ExceptPid $game.Id -State $voiceBoosted -Journal $journal -Activate
                        }
                    } else {
                        $prof = $script:GameProfiles[$boosted[$game.Id]]
                        $needBoost = $true
                        try { $needBoost = ($game.PriorityClass -ne [string]$prof.Priority) } catch { }
                        if ($needBoost -and $script:PriorityCapable) {
                            # Re-assert if something knocked it back down
                            Invoke-ProcessBoost -Process $game -Profile $prof -MaxCores $lowSpecMaxCores
                        }
                    }
                } catch {
                    Write-Log "Boost check failed for PID $($game.Id): $_" 'WARN'
                }
            }

            # Clean exited PIDs from tracking table
            # Throttled: only scan every other cycle to halve Get-Process calls.
            $removedAny = $false
            $exitCheckCounter++
            $exitCheckInterval = if ($running.Count -gt 0) { 2 } else { 1 }
            if ($exitCheckCounter -ge $exitCheckInterval) {
                $exitCheckCounter = 0
                foreach ($procId in @($boosted.Keys)) {
                    if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
                        Write-Log ("'{0}' session ended (PID {1})." -f $boosted[$procId], $procId) 'INFO'
                        $null = $boosted.Remove($procId)
                        $null = $scalePctByPid.Remove($procId)
                        $removedAny = $true
                    }
                }
            }

            # Last game closed -> undo every session change, then shut the
            # watcher down completely (final cleanup runs in the finally block).
            # The watcher is session-scoped, NOT a resident background service.
            if ($boosted.Count -eq 0) {
                if ($silenced.Count -gt 0) {
                    Update-BackgroundSilence -State $silenced -Journal $journal
                    Write-Log 'Background app priorities restored.' 'OK'
                }
                if ($voiceBoosted.Count -gt 0) {
                    Update-VoiceChatSupport -Patterns $protectedNames -State $voiceBoosted -Journal $journal
                    Write-Log 'Voice chat priorities restored.' 'OK'
                }
                if ($removedAny) {
                    Restore-NativeResolution          # back to full native sharpness
                    if ($scaledApplied) {
                        $scaledApplied = $false
                        $journal['scaledActive'] = $false
                        $journal['nativeMode']   = $null
                        Save-Journal
                    }
                    Stop-FrameGenerationTool -LaunchedByUs $fgByUs -ToolPid $fgPid
                    if ($fgByUs) { $journal['fgToolPid'] = 0; Save-Journal }
                    $fgByUs = $false; $fgPid = 0
                    if ($fsoDone.Count -gt 0) {
                        Undo-FsoCompatFlags -State $fsoDone -Journal $journal
                        Write-Log 'Fullscreen-optimization overrides cleared.' 'OK'
                    }
                    if ($ExitWhenGameSessionEnds) {
                        Write-Log 'Game session ended. Watcher shutting down completely - nothing keeps polling for another game.' 'ACTION'
                    } else {
                        Write-Log 'Game session ended. Watcher still running - waiting for next game...' 'INFO'
                        $idleSinceUtc = [datetime]::UtcNow
                    }
                }
                # Release the pacing timer while idle (guarded, so this runs
                # once per game session, not on every idle poll).
                if ($timerOn) {
                    Set-TimerResolution -Restore
                    $timerOn = $false
                }
                $sessionPurged = $false
                $preGamePurged = $false

                # COMPLETE SHUTDOWN after a real game session: undo steps above
                # already restored the system; break out so the finally block
                # reverts the network profile, clears the recovery journal and
                # removes the pid file, then this watcher process exits.
                if ($ExitWhenGameSessionEnds -and $hadSession -and $removedAny) {
                    break
                }
            }

            # ---- execute due ramp stages ---------------------------------
            $nowUtc = [datetime]::UtcNow
            for ($i = $ramp.Count - 1; $i -ge 0; $i--) {
                if ($ramp[$i].DueUtc -gt $nowUtc) { continue }
                $item = $ramp[$i]
                $ramp.RemoveAt($i)

                switch ([string]$item.Kind) {
                    'purge' {
                        # Pre-launch purge: eliminates launch stutter by
                        # clearing standby memory before game loads.
                        # RE-CHECK for recording at execution time: a capture
                        # app might have started since the ramp was queued,
                        # and a purge mid-recording hammers the captured FPS.
                        if ($recOn -and $recSkipPurge -and (Test-RecordingSoftwareActive -ExtraPatterns $recExtraProtected)) {
                            Write-Log 'Standby purge deferred: recording software active.' 'INFO'
                        } else {
                            try   { Clear-StandbyMemory } catch { }
                            $sessionPurged = $true
                            $lastPurgeUtc  = [datetime]::UtcNow
                        }
                    }
                    'purge2' {
                        # Secondary purge during loading screen
                        if ($recOn -and $recSkipPurge -and (Test-RecordingSoftwareActive -ExtraPatterns $recExtraProtected)) {
                            Write-Log 'Secondary standby purge deferred: recording software active.' 'INFO'
                        } else {
                            try   { Clear-StandbyMemory } catch { }
                            $lastPurgeUtc  = [datetime]::UtcNow
                        }
                    }
                    'resscale' {
                        try {
                            if (-not $scaledApplied) {
                                # A resolution flip while OBS/Bandicam is
                                # capturing causes black frames + 1fps drops,
                                # so if a recorder appeared since we queued the
                                # switch, hold native until it exits.
                                if ($recOn -and $recSkipRes -and (Test-RecordingSoftwareActive -ExtraPatterns $recExtraProtected)) {
                                    Write-Log 'Display switch deferred: recording software active (keeps captured output clean).' 'INFO'
                                } else {
                                    # Remember native FIRST so even a crash between the
                                    # two calls below is recoverable via the journal.
                                    # The target comes from the game's resolution tier
                                    # (set when it was detected); 0 falls back to the
                                    # legacy global percent.
                                    $targetPct = $item.Value
                                    if ($targetPct -le 0) { $targetPct = $scalePct }
                                    $nativeNow = Get-CurrentDisplayMode
                                    $ok = Enable-LowResolutionMode -ScalePercent $targetPct -PreferInteger:([bool]$prefInt)
                                    if ($ok) {
                                        $scaledApplied = $true
                                        $journal['scaledActive'] = $true
                                        $journal['nativeMode']   = $nativeNow
                                        Save-Journal
                                        Write-Log ("Display switched to {0}% of native (tier {1}%)." -f $targetPct, $targetPct) 'OK'
                                    }
                                }
                            }
                        } catch {
                            Write-Log "Resolution switch failed: $_" 'WARN'
                        }
                    }
                    default {
                        # per-game extras: legacy FSO flag + frame-gen bridge
                        try {
                            $xpid = 0
                            [void][int]::TryParse("$([string]$item.Pid)", [ref]$xpid)
                            if ($xpid -gt 0) {
                                $xp = Get-Process -Id $xpid -ErrorAction SilentlyContinue
                                if ($xp -and -not $xp.HasExited) {
                                    if ($fsoDisable) {
                                        Invoke-FsoCompatFlag -Process $xp -State $fsoDone -Journal $journal
                                    }
                                    if (-not $lowSpecSkipFrameGen) {
                                        Invoke-FrameGenerationTool -Settings $FrameGenSettings `
                                            -LaunchedByUs ([ref]$fgByUs) -ToolPid ([ref]$fgPid)
                                        if ($fgByUs) {
                                            $journal['fgToolPid'] = $fgPid
                                            Save-Journal
                                        }
                                    }
                                }
                            }
                        } catch { }
                    }
                }
            }

            # Memory pressure check - deliberately rare now. A standby purge
            # stalls the whole memory manager (a visible hitch if it lands
            # mid-frame), so during play it happens ONLY below the critical
            # floor AND at most once per cooldown window. Skipped entirely
            # in low-spec mode or while recording software is active.
            if ($running.Count -gt 0 -and -not $lowSpecSkipPurge -and -not ($isRecording -and $recSkipPurge)) {
                if (([datetime]::UtcNow - $lastPurgeUtc).TotalSeconds -ge $PurgeCooldownSeconds) {
                    $freeMB = Get-FreeRamMB
                    if ($freeMB -lt $CriticalRamFloorMB) {
                        Write-Log ("Free RAM critical ({0} MB) - cooldown-gated standby purge..." -f $freeMB) 'WARN'
                        Clear-StandbyMemory
                        $lastPurgeUtc = [datetime]::UtcNow
                    }
                }
            }

            # Adaptive parking: 3-tier resource usage
            #   - Gaming:     $pollMs (10-15s) - active game detection
            #   - Idle:       $idleMs (25-35s) - recently had a game, watching for next
            #   - Extended:   $extIdleMs (60-90s) - long idle, ultra-low CPU
            # Wake early while ramp stages are pending.
            # Either way we park on the kernel event, so the stop signal
            # still wakes us instantly. On old/low-spec PCs this means
            # near-zero CPU usage between games.
            $isCurrentlyIdle = ($running.Count -eq 0)
            if ($isCurrentlyIdle) {
                $idleSec = ([datetime]::UtcNow - $idleSinceUtc).TotalSeconds
                if ($idleSec -gt 300) {
                    # Extended idle: >5 minutes since last game - ultra-low polling
                    $waitMs = $extIdleMs
                } else {
                    $waitMs = $idleMs
                }
            } else {
                $waitMs = $pollMs
            }

            # Log heartbeat while idle so the user knows the watcher is alive
            if ($isCurrentlyIdle -and $IdleHeartbeatMinutes -gt 0) {
                $hbDueMs = $idleHeartbeatMs - [int]([datetime]::UtcNow - $lastHeartbeatUtc).TotalMilliseconds
                if ($hbDueMs -le 0) {
                    $idleMin = [int]([datetime]::UtcNow - $idleSinceUtc).TotalMinutes
                    Write-Log ("Watcher idle for {0} min - monitoring for games (poll every {1}s)..." -f `
                        $idleMin, [int]($waitMs / 1000)) 'INFO'
                    $lastHeartbeatUtc = [datetime]::UtcNow
                    # Heartbeat wakes us early
                    if ($hbDueMs + $idleHeartbeatMs -lt $waitMs) {
                        $waitMs = [Math]::Max(200, $idleHeartbeatMs)
                    }
                } else {
                    # Wake for heartbeat before the full idle wait
                    if ($hbDueMs -lt $waitMs) { $waitMs = [Math]::Max(200, $hbDueMs) }
                }
            }
            $wasIdle = $isCurrentlyIdle

            if ($ramp.Count -gt 0) {
                $minDue = $null
                foreach ($a in $ramp) {
                    if ($null -eq $minDue -or $a.DueUtc -lt $minDue) { $minDue = $a.DueUtc }
                }
                $untilDueMs = [int][math]::Ceiling(($minDue - [datetime]::UtcNow).TotalMilliseconds)
                if ($untilDueMs -lt $waitMs) { $waitMs = [Math]::Max(200, $untilDueMs) }
            }

            # Park on the stop signal (instant on Windows) or poll the stop
            # marker in 250ms slices elsewhere, then loop again.
            $stopping = Wait-StopOrTimeout -Milliseconds $waitMs -StopEvent $StopEvent
            if ($stopping) {
                Write-Log 'Stop signal received.' 'ACTION'
                break
            }
        }
    } finally {
        Update-BackgroundSilence -State $silenced -Journal $journal
        Update-VoiceChatSupport -Patterns $protectedNames -State $voiceBoosted -Journal $journal
        Stop-FrameGenerationTool -LaunchedByUs $fgByUs -ToolPid $fgPid
        $journal['fgToolPid'] = 0
        Restore-NativeResolution           # never leave the screen scaled down
        Undo-FsoCompatFlags -State $fsoDone -Journal $journal
        Set-TimerResolution -Restore
        if ($netOn) {
            try { Undo-GameNetworkProfile -JournalState $journal['net'] } catch { }
        }
        Clear-StopRequest                  # Unix stop marker (Windows: event reset by next start)
        Save-Journal                       # persist the all-clear state briefly
        Clear-WatcherJournal               # clean exit => nothing left to repair
        Write-Log 'Game watcher stopped, priorities/timer/resolution/network restored.' 'INFO'
    }
}

Export-ModuleMember -Function Enable-GamingPowerPlan, Disable-GameDVR, Set-MultimediaTweaks,
    Set-TimerResolution, Clear-StandbyMemory, Invoke-ProcessBoost,
    Start-GameWatcher, Get-FreeRamMB, Get-GameProfile,
    Invoke-FrameGenerationTool, Stop-FrameGenerationTool
