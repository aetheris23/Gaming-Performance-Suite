# ============================================================
#  GameBoost.psm1 - FPS stability + dynamic game handling
#  (Valorant, Steam titles, PCSX2 and other emulators, plus ANY
#  foreground game or video: see UniversalWatch in Config.ps1).
#
#  Windows-only build (Linux/macOS/Android support removed -
#  the cross-platform branches added per-poll scanning overhead
#  that degraded long gaming sessions). Optimized for low-spec
#  PCs and laptops.
#
#  On detection of a game/video the watcher:
#    - classifies the title (Emulator / Steam / Competitive /
#      Android / Default); unknown immersive windows become
#      Default so ANY game/video in windowed mode is covered
#    - raises its scheduling priority + steers it off core 0
#    - silences known background hogs (browsers, Steam helper)
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
    <# Compiles the timer/memory interop lazily, on first real use. #>
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
$script:TimerPeriod = 2   # period actually requested by timeBeginPeriod
$script:StandbyPurgeUnavailableLogged = $false

# ------------------------------------------------------------
# Free RAM (native Win32 call)
# ------------------------------------------------------------
function Get-FreeRamMB {
    Add-NativeBoostType
    if (-not ('Suite.NativeBoost' -as [type])) { return 0 }
    $ms = New-Object Suite.NativeBoost+MEMORYSTATUSEX
    $ms.dwLength = [uint32][Runtime.InteropServices.Marshal]::SizeOf([type][Suite.NativeBoost+MEMORYSTATUSEX])
    [void][Suite.NativeBoost]::GlobalMemoryStatusEx([ref]$ms)
    [int]($ms.ullAvailPhys / 1MB)
}

# ------------------------------------------------------------
# Power-plan GUIDs the suite works with. Debloated custom builds
# (ReviOS / AtlasOS / Ghost Spectre / Tiny11) REMOVE the stock
# "High performance" scheme (and often "Balanced"/"Power saver"
# too), so the suite never hard-codes a single source scheme: it
# clones High performance, else Ultimate Performance, else the
# ACTIVE scheme - whichever actually exists on this machine.
# ------------------------------------------------------------
$script:GuidMatch = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
$script:PlanHighPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:PlanUltimate       = 'e9a42b02-d5df-448d-aa00-03f14749eb61'

# ------------------------------------------------------------
# Processes the watcher must NEVER treat as games. Anti-cheat
# (BattlEye, EasyAntiCheat, Vanguard, EAC/BE kernel services) and
# store launchers must never get priority boosts - touching them
# can trip anti-cheat integrity checks or just waste the boost.
# This is a safety net on top of the Config.ps1 game list.
# ------------------------------------------------------------
$script:NeverWatchProcesses = @(
    # Riot Vanguard
    'vgc', 'vgtray', 'vgk'
    # BattlEye + EasyAntiCheat
    'beservice', 'easyanticheat', 'easyanticheatservice', 'eacgameclient'
    # Crash handlers / bootstrappers
    'crashhandler', 'rbxcrashhandler', 'eaclauncher', 'bepadornfh'
    # Steam family
    'steam', 'steamservice', 'steamwebhelper', 'steamclient'
    # Riot
    'riotclientservices'
    # EA
    'eadesktop', 'eabackgroundservice', 'eacore', 'eaapperror'
    # Ubisoft
    'ubisoftconnect', 'upc', 'uplay', 'uplay_service'
    # Epic
    'epicwebhelper', 'epicgameslauncher', 'epicgamesbootstrap'
    # Blizzard
    'agent', 'battle.net', 'blizzardbrowserhelper'
    # GOG / itch
    'goggalaxy', 'galaxyclient', 'galaxynotifications', 'itch', 'itch-electron'
    # Overlays / launcher frameworks
    'overwolf', 'overwolflauncher'
    # Windows gaming services
    'gamingservices', 'gamingservicesnet', 'gamingservicesui', 'gamebar', 'gamebarpresencewriter'
)

# ------------------------------------------------------------
# Universal-watch blocklist.
#
# UniversalWatch treats ANY foreground window that fills its monitor as a
# game/video candidate. This list keeps the desktop, shell, system helpers,
# stores, browsers and productivity apps out of that path so an everyday
# maximized window is never boosted/downscaled. Anti-cheat + launchers are
# already covered by $script:NeverWatchProcesses; the universal path merges
# both. Extend here if a tool on your custom build is missing.
# ------------------------------------------------------------
$script:UniversalBlocklist = @(
    # Windows shell / desktop / system
    'explorer', 'progman', 'dwm', 'cmd', 'conhost', 'openssh', 'taskmgr'
    'winlogon', 'lsass', 'csrss', 'system', 'runtimebroker', 'sihost'
    'searchhost', 'searchindexer', 'startmenuexperiencehost', 'textinputhost'
    'shellexperiencehost', 'smartscreen', 'securityhealthsystray'
    # Built-in utilities / applets
    'calculator', 'notepad', 'wordpad', 'mspaint', 'regedit', 'mmc'
    'control', 'sndvol', 'osk', 'magnify', 'narrator', 'winver', 'dosprompt'
    # Office / productivity
    'winword', 'excel', 'powerpnt', 'outlook', 'onenote', 'ms-teams', 'msteams'
    'teams2', 'code', 'code-insiders', 'notion', 'slack', 'acrobat'
    'acrord32', 'libreoffice', 'soffice', 'obs64', 'obs32',
    # Browsers (videos inside a browser play fine - never downscale surfing)
    'chrome', 'msedge', 'firefox', 'opera', 'brave', 'vivaldi', 'chromium'
    'iexplore', 'qqbrowser', '360se', 'seamonkey', 'waterfox'
)

# ------------------------------------------------------------
# 1a. Power plan: High performance + PCIe/CPU floor at max perf
#
# The old WinDetect module probed the whole Windows build (registry reads,
# powercfg lists, netsh checks) on every startup just to decide which power
# plan could be cloned. That probes are now done HERE, only when this
# function is actually invoked (menu option 1), so the background watcher
# never pays for it. On battery power the aggressive CPU floor / PCIe LPM
# settings are limited to AC so laptops are not drained (-Force* switches
# override via Config.ps1 PowerOptimization).
# ------------------------------------------------------------
function Get-PowerPlanState {
    <#
        Cheap one-shot powercfg probe used ONLY when the gaming power plan is
        actually needed. Returns the facts Enable-GamingPowerPlan relies on:
        scheme availability / the active scheme GUID. Never throws.
    #>
    $powerCfg = Get-Command powercfg -ErrorAction SilentlyContinue
    if (-not $powerCfg) {
        return @{ PowerCfgAvailable = $false; HighPerfPowerPlan = $false; UltimatePowerPlan = $false; ActivePowerGuid = $null }
    }
    $schemesText = ''
    $activeGuid  = $null
    try {
        $schemesText = (@(& powercfg /list 2>$null) -join "`n")
        $activeOut   = (& powercfg /getactivescheme 2>$null | Out-String)
        if ($activeOut -match $script:GuidMatch) { $activeGuid = $Matches[1].ToLowerInvariant() }
    } catch { }
    return @{
        PowerCfgAvailable  = $true
        HighPerfPowerPlan  = ($schemesText -match '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
        UltimatePowerPlan  = ($schemesText -match 'e9a42b02-d5df-448d-aa00-03f14749eb61')
        ActivePowerGuid    = $activeGuid
    }
}

function Test-OnBattery {
    <# $true when the machine is currently running from battery power.
       Desktops (no battery) always report $false. One-shot CIM probe. #>
    try {
        $b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $b) { return $false }
        # BatteryStatus: 1 = discharging (on battery), 2 = on AC
        return ([int]$b.BatteryStatus -eq 1)
    } catch { return $false }
}

function Enable-GamingPowerPlan {
    [CmdletBinding()] param(
        [bool]$ForceMaxCpuOnBattery   = $false,   # force 100% min processor state on DC too
        [bool]$ForcePcieOffOnBattery  = $false    # force PCIe ASPM off on DC too
    )

    Assert-AdminOrThrow

    $os = Get-PowerPlanState

    if (-not $os.PowerCfgAvailable) {
        Write-Log 'powercfg is not available on this Windows build - power-plan switch skipped. Other optimizations continue.' 'WARN'
        return
    }

    # --- reuse the dedicated gaming plan when it already exists ---
    $planGuid = $null
    try {
        foreach ($ln in @(& powercfg /list 2>$null)) {
            if ($ln -match 'Gaming Performance Suite' -and $ln -match $script:GuidMatch) {
                $planGuid = $Matches[1]
                break
            }
        }
    } catch { }

    # --- otherwise clone a scheme that actually exists on THIS build ---
    if (-not $planGuid) {
        Write-Log 'Creating dedicated gaming power plan...' 'ACTION'
        $sources = @()
        if ($os.HighPerfPowerPlan) { $sources += $script:PlanHighPerformance }
        if ($os.UltimatePowerPlan) { $sources += $script:PlanUltimate }
        if ($os.ActivePowerGuid)   { $sources += $os.ActivePowerGuid }

        $cloned = ''
        foreach ($src in $sources) {
            try {
                $dupOut = (& powercfg /duplicatescheme $src 2>$null | Out-String)
                if ($dupOut -match $script:GuidMatch) { $planGuid = $Matches[1]; $cloned = $src; break }
            } catch { }
        }

        if ($planGuid) {
            try {
                $srcName = if ($cloned -eq $script:PlanHighPerformance) { 'High performance' }
                           elseif ($cloned -eq $script:PlanUltimate)   { 'Ultimate Performance' }
                           else { 'currently active' }
                Write-Log ("Power plan cloned from {0} (stock schemes may be missing on this build - the suite adapts)." -f $srcName) 'INFO'
                & powercfg /changename $planGuid 'Gaming Performance Suite' 'Max FPS stability profile' | Out-Null
            } catch { }
        }
    }

    if (-not $planGuid) {
        Write-Log 'Could not create a dedicated power plan (no scheme available on this build); leaving the current power plan untouched.' 'WARN'
        return
    }

    & powercfg /setactive $planGuid | Out-Null
    Write-Log "Active power plan set to 'Gaming Performance Suite' ($planGuid)" 'OK'

    # Battery awareness: the aggressive values below force the CPU to idle at
    # 100% and keep PCIe links out of low-power mode - fantastic for FPS on
    # AC, a constant battery drain on a laptop. By default they apply ONLY on
    # AC so a low-spec laptop keeps its battery; flipping the Config.ps1
    # PowerOptimization switches replicates the old always-on behavior.
    $onBattery = Test-OnBattery
    if ($onBattery) {
        Write-Log 'Running on battery: the 100% CPU floor and PCIe-LPM-off are skipped on DC to save power (Config.ps1 > PowerOptimization can override).' 'INFO'
    }

    $cpuTargets = @('AC')
    if ($ForceMaxCpuOnBattery) { $cpuTargets += 'DC' }
    # Minimum processor state 100% (AC, optionally DC) - kills core-throttle dips
    foreach ($src in $cpuTargets) {
        & powercfg "/set${src}valueindex" $planGuid `
            54533251-82be-4824-96c1-47b60b740d00 `
            bc5038f7-23e0-4960-96da-33abaf5935ec 100 | Out-Null
    }

    $pcieTargets = @('AC')
    if ($ForcePcieOffOnBattery) { $pcieTargets += 'DC' }
    # PCI Express Link State Power Management -> Off (GPU latency spikes)
    foreach ($src in $pcieTargets) {
        & powercfg "/set${src}valueindex" $planGuid `
            501a4d13-42af-4429-9fd1-a8218c268e20 `
            ee12f906-d277-404b-b6da-e5fa1a576df5 0 | Out-Null
    }

    & powercfg /setactive $planGuid | Out-Null
    Write-Log ("PCIe link + CPU floor set for Maximum Performance ({0}); battery values left untouched." -f ($cpuTargets -join '+')) 'OK'
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
    Add-NativeBoostType
    if ($Restore) {
        if ($script:TimerActive) {
            # timeEndPeriod must pair with the SAME period timeBeginPeriod used,
            # or an aggressive 1 ms timer request is never released and keeps
            # firing interrupts after "restore".
            [void][Suite.NativeBoost]::timeEndPeriod([uint32]$script:TimerPeriod)
            $script:TimerActive  = $false
            $script:TimerPeriod  = 2
            Write-Log 'Timer resolution restored to system default' 'INFO'
        }
        return
    }
    $period = if ($UseAggressive) { 1 } else { 2 }
    $result = [Suite.NativeBoost]::timeBeginPeriod($period)
    if ($result -eq 0) {
        $script:TimerActive = $true
        $script:TimerPeriod = $period
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
        Frees the OS standby/cleanable memory via the classic
        EmptyStandbyList system call. Elevation is required.
    #>
    Assert-AdminOrThrow

    Add-NativeBoostType
    if (-not ('Suite.NativeBoost' -as [type])) { return }

    # The standby-list purge (SystemMemoryListInformation = 80, command
    # PurgeStandbyList = 4) requires SeProfileSingleProcessPrivilege to be
    # ENABLED in THIS process token at the instant of the call. Enable it
    # first (and verify), then retry a few times - on some builds the first
    # NtSetSystemInformation after enabling can still race with the token
    # refresh, so we re-enable and re-attempt.
    $status = -1
    for ($attempt = 1; $attempt -le 3 -and $status -ne 0; $attempt++) {
        $priv = Enable-Privilege 'SeProfileSingleProcessPrivilege'
        if (-not $priv) {
            if (-not $script:StandbyPurgeUnavailableLogged) {
                Write-Log 'Standby purge skipped: SeProfileSingleProcessPrivilege is not available in this elevated token. Check the user right assignment or use the Windows built-in Administrator account.' 'WARN'
                $script:StandbyPurgeUnavailableLogged = $true
            }
            return
        }
        # Small yield so the token adjust is fully committed inside ntdll.
        Start-Sleep -Milliseconds 25
        $cmd = 4
        $status = [Suite.NativeBoost]::NtSetSystemInformation(80, [ref]$cmd, 4)
        if ($status -ne 0 -and $attempt -lt 3) {
            Start-Sleep -Milliseconds 50
        }
    }

    if ($status -eq 0) {
        $freeGB = [math]::Round((Get-FreeRamMB) / 1024.0, 2)
        Write-Log "Standby memory purged (free RAM now ~$freeGB GB)" 'OK'
    } else {
        Write-Log ("Standby purge skipped: Windows rejected the memory-list request with NTSTATUS 0x{0:X8} (SeProfileSingleProcessPrivilege is not held)." -f ([uint32]$status)) 'WARN'
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
        Priority         = 'AboveNormal'
        AvoidCores       = @(0)
        # Silencing only covers the profile's Deprioritize list, so comms apps
        # you actively use are never touched unless you add them here.
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
    'starfield*', 'palworld*', 'lethalcompany*', 'contentwarning*'
)

# Android emulator process patterns
$script:AndroidEmulatorNames = @(
    'ldboxheadless', 'ldvboxheadless', 'ldplayer', 'dnplayer',
    'nox', 'noxhandle', 'noxvmhandle',
    'mumuplayer', 'mumuvmmheadless',
    'bluestacks', 'hd-player', 'bstkvmm',
    'memu', 'memuheadless'
)

function Test-MatchAny {
    <# Wildcard matcher over many patterns (all lowercase). Returns $true
       when $Name matches any pattern. Case-insensitive. #>
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
# Low-spec hardware auto-detection.
#
# Determines at startup whether the detected hardware is weak enough
# that the suite should run in low-spec mode AUTOMATICALLY - so users
# on old laptops / low-spec PCs never have to edit Config.ps1 to get a
# safe, lightweight experience. The program also stays light on strong
# machines because LowSpecMode's reduced polling, throttled silence and
# skipped HAGS/timer are internal and only tighten the watcher's own
# footprint further.
#
# Signals (all cheap, gathered once at startup):
#   - legacy iGPU/dGPU  (Test-LegacyGpuPresent - the weakest GPU class)
#   - low CPU core/thread count (<= 4 logical processors)
#   - low CPU clock (base/max < ~2.6 GHz, when the OS exposes it)
#   - low total RAM (< ~6 GB - only a tiebreaker, never a hard gate)
#
# A machine is considered low-spec when it has a legacy GPU AND is
# CPU-weaker (few cores OR low clocks). This captures the classic weak
# laptop (e.g. i3-7020U 2C/4T + HD Graphics 620) while letting modern
# multi-core iGPU systems run at full strength.
#
# Never throws; returns a hashtable with an IsLowSpec verdict plus the
# individual signals so callers can log exactly WHY.
# ------------------------------------------------------------
function Test-LowSpecHardware {
    [CmdletBinding()] param()

    $signals = @{
        LegacyGpu = $false
        LowCores  = $false
        LowClock  = $false
        LowRam    = $false
        Threads   = [Environment]::ProcessorCount
        ClockMHz  = 0
        RamMB     = 0
    }

    # GPU: reuse the legacy-era detector (already cached after first call)
    try { $signals.LegacyGpu = [bool](Test-LegacyGpuPresent) } catch { }

    # RAM: lightweight probe
    try {
        Add-NativeBoostType   # ensure Suite.NativeBoost is compiled
        if ('Suite.NativeBoost' -as [type]) {
            $ms = New-Object Suite.NativeBoost+MEMORYSTATUSEX
            $ms.dwLength = [uint32][Runtime.InteropServices.Marshal]::SizeOf([type][Suite.NativeBoost+MEMORYSTATUSEX])
            [void][Suite.NativeBoost]::GlobalMemoryStatusEx([ref]$ms)
            $signals.RamMB = [int]($ms.ullTotalPhys / 1MB)
        }
    } catch { }

    $signals.LowCores = ($signals.Threads -le 4)

    # CPU clock: best-effort; never fatal.
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Measure-Object -Property MaxClockSpeed -Maximum
        if ($cpu -and $cpu.Maximum) { $signals.ClockMHz = [int]$cpu.Maximum }
    } catch { }
    if ($signals.ClockMHz -gt 0 -and $signals.ClockMHz -lt 2600) { $signals.LowClock = $true }

    $signals.LowRam = ($signals.RamMB -gt 0 -and $signals.RamMB -lt 6144)

    # Verdict: legacy GPU AND (few cores OR low clock). RAM is informational.
    $signals.IsLowSpec = ($signals.LegacyGpu -and ($signals.LowCores -or $signals.LowClock))
    return $signals
}

# ------------------------------------------------------------
# 6. Per-process boost driven by the game's profile
# ------------------------------------------------------------
$script:PriorityCapable = $true

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
                # Not elevated: throw so the caller can log the failure.
                throw
            }
        }

        # Spread the game off the interrupt core (USB/NIC DPCs land there).
        # Only ever WRITE the affinity when it has actually drifted from the
        # computed mask: a redundant affinity update on an already-pinned game
        # forces a scheduler re-balance, which can cause a visible micro-stutter
        # at the very moment it is applied mid-render (effect bursts, shooting).
        $avoid = @($Profile.AvoidCores)
        $total = [Environment]::ProcessorCount
        if ($MaxCores -gt 0 -and $MaxCores -lt $total) { $total = $MaxCores }
        if ($total -gt 2 -and $avoid.Count -gt 0 -and $avoid.Count -lt $total) {
            $mask = 0L
            for ($i = 0; $i -lt $total; $i++) {
                if ($avoid -notcontains $i) { $mask = $mask -bor ([long]1 -shl $i) }
            }
            try {
                $cur = $Process.ProcessorAffinity.ToInt64()
                if ($cur -ne $mask) { $Process.ProcessorAffinity = [IntPtr]$mask }
            } catch {
                $Process.ProcessorAffinity = [IntPtr]$mask
            }
        }
    } catch {
        Write-Log "Could not fully boost PID $($Process.Id): $_" 'WARN'
    }
}

# ------------------------------------------------------------
# Background-app silencing used by the Steam/Competitive profiles.
# Anti-cheat services are always skipped; leaning on the profile's
# Deprioritize list keeps the change minimal and reversible.
# ------------------------------------------------------------
function Update-BackgroundSilence {
    param(
        [string[]]$Names,
        [int]$ExceptPid,
        [hashtable]$State,           # pid -> info of processes currently silenced
        [hashtable]$Journal,         # recovery journal (optional)
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
# Foreground game selection
# ------------------------------------------------------------
function Add-ForegroundWindowType {
    <# Compiles the foreground-window interop lazily, on first real use. #>
    if ('Suite.ForegroundWindow' -as [type]) { return }
    Add-Type -Namespace Suite -Name ForegroundWindow -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
[DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct MONITORINFO
{
    public uint cbSize;
    public RECT rcMonitor;
    public RECT rcWork;
    public uint dwFlags;
}
'@
}

function Get-ActiveWindowProcessId {
    <#
        Returns the process owning the foreground window, or 0 when the
        desktop cannot provide that information. A missing desktop backend
        must not prevent headless game detection.
    #>
    try {
        Add-ForegroundWindowType
        $window = [Suite.ForegroundWindow]::GetForegroundWindow()
        if ($window -eq [IntPtr]::Zero) { return 0 }
        $pid = [uint32]0
        [void][Suite.ForegroundWindow]::GetWindowThreadProcessId($window, [ref]$pid)
        return [int]$pid
    } catch { return 0 }
}

function Test-ImmersiveForegroundWindow {
    <#
        Returns $true when the foreground window covers at least $Threshold of
        its own monitor - the signature of a game or video running in
        borderless-fullscreen / maximized ("windowed") mode. Geometry is read
        against the window's OWN monitor so multi-monitor setups classify
        correctly. Used by UniversalWatch to catch ANY game/video without a
        hardcoded process name.
    #>
    param([double]$Threshold = 0.90)
    try {
        Add-ForegroundWindowType
        $hwnd = [Suite.ForegroundWindow]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return $false }
        $r = New-Object Suite.ForegroundWindow+RECT
        if (-not [Suite.ForegroundWindow]::GetWindowRect($hwnd, [ref]$r)) { return $false }
        if ($r.Right -le $r.Left -or $r.Bottom -le $r.Top) { return $false }

        # Window's own monitor bounds (right for secondary screens / scaling).
        $mon = [Suite.ForegroundWindow]::MonitorFromWindow($hwnd, 2)   # MONITOR_DEFAULTTONEAREST
        if ($mon -eq [IntPtr]::Zero) { return $false }
        $mi = New-Object Suite.ForegroundWindow+MONITORINFO
        $mi.cbSize = [uint32][Runtime.InteropServices.Marshal]::SizeOf([type][Suite.ForegroundWindow+MONITORINFO])
        if (-not [Suite.ForegroundWindow]::GetMonitorInfo($mon, [ref]$mi)) { return $false }

        $w = [double]($r.Right - $r.Left)
        $h = [double]($r.Bottom - $r.Top)
        $mw = [double]($mi.rcMonitor.Right - $mi.rcMonitor.Left)
        $mh = [double]($mi.rcMonitor.Bottom - $mi.rcMonitor.Top)
        if ($w -le 0 -or $h -le 0 -or $mw -le 0 -or $mh -le 0) { return $false }
        return ((($w * $h) / ($mw * $mh)) -ge $Threshold)
    } catch { return $false }
}

function Test-ActiveGameProcess {
    param(
        [Parameter(Mandatory)]$Process,
        [bool]$ActiveOnly = $true
    )
    if (-not $ActiveOnly) { return $true }
    $activePid = Get-ActiveWindowProcessId
    if ($activePid -le 0) { return $true }
    return ([int]$Process.Id -eq $activePid)
}

# ------------------------------------------------------------
function Start-GameWatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$GameNames,
        [bool]$ActiveGameOnly = $true,
        [int]$PollSeconds = 10,              # scan cadence while a game is running
        [int]$IdlePollSeconds = 25,          # slower cadence while NO game runs (idle load)
        [int]$ExtendedIdlePollSeconds = 60,  # even slower when idle for a long time (ultra-low CPU)
        [int]$IdleHeartbeatMinutes = 5,      # log "watcher alive" every N minutes while idle
        [int]$CriticalRamFloorMB = 768,      # standby purge during play ONLY below this floor
        [int]$PurgeCooldownSeconds = 900,    # minimum seconds between two standby purges
        [switch]$PurgeOnGameLaunch,          # one purge shortly after a game is detected
        [bool]$AllowMidGamePurge = $false,   # opt-in: standby purges can hitch active gameplay
        [hashtable]$ProfileOverrides = @{},
        [hashtable]$ResolutionSettings = @{ ScalePercent = 66; PreferIntegerScale = $true; Stretched = $false },
        [hashtable]$FrameGenSettings   = @{ Enabled = $false; ToolPath = '' },
        [hashtable]$LegacySettings     = @{},
        [hashtable]$LowSpecSettings    = @{ Enabled = $false },
        [hashtable]$UniversalSettings  = @{ Enabled = $true; ImmersiveWindowThreshold = 0.90 },
        [hashtable]$AdaptiveTuningSettings = @{ Enabled = $false },
        [bool]$PreGameOptimization = $true,
        [bool]$PrePurgeBeforeLaunch = $true,
        [bool]$ExitWhenGameSessionEnds = $true,
        [string[]]$NeverWatchProcesses = @(),
        [System.Threading.EventWaitHandle]$StopEvent = $null
    )

    # Windows must be elevated for the registry/driver tweaks - the .bat
    # launcher self-elevates, so a hard requirement there is correct.
    Assert-AdminOrThrow

    # ---- recover anything a previous unclean session left behind ----
    try { Repair-OrphanedWatcherState | Out-Null } catch { }

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

    # ---- resolve adaptive mid-game tuning -------------------------------
    # Reacts to heavy-load moments (skill/effect bursts, large maps) where
    # memory pressure spikes and frame drops show up. Standby purges are
    # gated by a cooldown AND a two-consecutive-check pressure streak, so a
    # purge can never stall the middle of a frame on a single transient dip.
    # The floor adapts to total RAM and the cooldown tightens under pressure.
    $adaptiveOn           = $false
    $adaptiveFloorPct     = 10
    $adaptiveCoolSec      = 60
    $reassertPriorities   = $true
    $reassertEveryCycles  = 3
    if ($AdaptiveTuningSettings) {
        if ($AdaptiveTuningSettings.ContainsKey('Enabled'))            { $adaptiveOn          = [bool]$AdaptiveTuningSettings['Enabled'] }
        if ($AdaptiveTuningSettings.ContainsKey('AdaptivePurgeFloor')) { $adaptiveFloorPct   = [Math]::Max(1, [Math]::Min(90, [int]$AdaptiveTuningSettings['AdaptivePurgeFloor'])) }
        if ($AdaptiveTuningSettings.ContainsKey('PressureCooldownSec')){ $adaptiveCoolSec    = [Math]::Max(5, [int]$AdaptiveTuningSettings['PressureCooldownSec']) }
        if ($AdaptiveTuningSettings.ContainsKey('ReassertPriorities')) { $reassertPriorities = [bool]$AdaptiveTuningSettings['ReassertPriorities'] }
        if ($AdaptiveTuningSettings.ContainsKey('ReassertEveryCycles')){ $reassertEveryCycles= [Math]::Max(1, [int]$AdaptiveTuningSettings['ReassertEveryCycles']) }
    }
    if ($adaptiveOn) {
        Write-Log 'Adaptive mid-game tuning ENABLED - reacts to skill-effect / large-map load spikes for smooth FPS.' 'INFO'
    }

    Write-GpuInventory

    $skipScale  = [bool]$LegacySettings['SkipResolutionSwitch'] -or $lowSpecSkipRes
    $fsoDisable = [bool]$LegacySettings['DisableFullscreenOptimizations']
    if ($skipScale)  { Write-Log 'Resolution switching is DISABLED for this session.' 'INFO' }
    if ($fsoDisable) { Write-Log 'Fullscreen optimizations will be disabled for detected games.' 'INFO' }

    # ---- resolve universal watch settings -------------------------------
    # UniversalWatch targets ANY foreground window that fills its monitor
    # (borderless-fullscreen games, maximized video players) in addition to
    # the configured game list. When ON the watcher optimizes titles that
    # were never added to GameProcesses - new/known games, windowed games,
    # media players. The threshold is the fraction of the window's own
    # monitor it must cover to count as a game/video session.
    $universalOn      = $true
    $immersivePercent = 0.90
    if ($UniversalSettings) {
        if ($UniversalSettings.ContainsKey('Enabled'))                   { $universalOn      = [bool]$UniversalSettings['Enabled'] }
        if ($UniversalSettings.ContainsKey('ImmersiveWindowThreshold'))  {
            try { $immersivePercent = [double]$UniversalSettings['ImmersiveWindowThreshold'] } catch { }
        }
    }
    # Clamp: below ~40% every app counts; above ~99.5% even fullscreen is skipped.
    if ($immersivePercent -le 0 -or $immersivePercent -ge 1 -or [double]::IsNaN($immersivePercent)) {
        $immersivePercent = 0.90
    }
    $immersivePercent = [Math]::Max(0.40, [Math]::Min(0.995, $immersivePercent))
    if ($universalOn) {
        Write-Log ("Universal watch ON: any immersive foreground game/video (>= {0:P0} of its monitor) is optimized in addition to the configured game list." -f $immersivePercent) 'INFO'
    }

    # Recovery journal - written through at EVERY state change so any
    # kind of death (kill, console close, crash, power loss) is fully
    # repairable by the next start/stop.
    $journal = @{
        scaledActive = $false
        nativeMode   = $null
        silenced     = @{}
        fsoFlags     = @()
        fgToolPid    = 0
    }
    function Save-Journal { Save-WatcherJournal -State $journal }

    # ---- PRE-GAME OPTIMIZATION: apply the cheap, system-wide FPS tweaks
    #     BEFORE any game is detected so they are in place when the first
    #     game appears (eliminates launch stutter). Network tuning is no
    #     longer part of the suite.
    if ($PreGameOptimization) {
        Write-Log 'Pre-game optimizations: applying system-wide FPS tweaks before games launch...' 'ACTION'
        try { Disable-GameDVR } catch { Write-Log "Game DVR tweak skipped: $_" 'WARN' }
        try { Set-MultimediaTweaks -EnableHags:([bool]$LegacySettings['EnableHags']) } catch { Write-Log "Multimedia tweak skipped: $_" 'WARN' }
    }

    Write-Log ("Game watcher started (poll {0}s while gaming, {1}s idle). Watching active games only: {2}" -f `
        $PollSeconds, [Math]::Max($PollSeconds, $IdlePollSeconds), $ActiveGameOnly) 'ACTION'
    Write-Log 'Games are auto-classified (Emulator / Steam / Competitive / Android / Default) on launch.' 'INFO'
    if ($StopEvent) { Write-Log 'Background mode: stop via Stop-GamingSuite.bat.' 'INFO' }
    else            { Write-Log 'Press Ctrl+C to stop the watcher.' 'INFO' }

    $boosted       = @{}   # pid -> profile name
    $scalePctByPid = @{}   # pid -> resolution tier percent chosen on detect
    $silenced      = @{}   # pid -> info (background apps we deprioritized)
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

    # ---- adaptive mid-game tuning state ----
    # Tracks sustained memory pressure (skill/effect bursts, large maps load
    # lots of assets) so an adaptive purge can react without ever stalling a
    # frame - always cooldown-gated and only under real pressure.
    $adaptiveLastUtc     = [datetime]::MinValue  # last adaptive purge
    $adaptiveCoolMs      = [int]$adaptiveCoolSec * 1000
    $adaptiveConsecutive = 0                      # consecutive sub-floor readings (>=2 required before purging)
    $adaptiveTotalMB     = 0                      # total physical RAM, resolved once
    Add-NativeBoostType
    try { $ms = New-Object Suite.NativeBoost+MEMORYSTATUSEX; $ms.dwLength = [uint32][Runtime.InteropServices.Marshal]::SizeOf([type][Suite.NativeBoost+MEMORYSTATUSEX]); [void][Suite.NativeBoost]::GlobalMemoryStatusEx([ref]$ms); $adaptiveTotalMB = [int]($ms.ullTotalPhys / 1MB) } catch { }
    $reassertCounter     = 0                      # throttles per-game priority re-assertion

    # ---- idle tracking: ultra-low resource mode ---------------------------
    $idleSinceUtc     = [datetime]::UtcNow   # when we last transitioned to idle
    # Start at NOW so the first idle-heartbeat math is small; a sentinel
    # [datetime]::MinValue here made [int](now - sentinel).TotalMilliseconds
    # overflow Int32 (~6.4e13 ms) and crash the watcher on its first idle poll.
    $lastHeartbeatUtc = [datetime]::UtcNow  # last time we logged "watcher alive"
    $idleHeartbeatMs   = $IdleHeartbeatMinutes * 60 * 1000

    $scalePct = if ($ResolutionSettings['ScalePercent'])      { [int]$ResolutionSettings['ScalePercent'] }      else { 66 }
    $prefInt  = if ($null -ne $ResolutionSettings['PreferIntegerScale']) { [bool]$ResolutionSettings['PreferIntegerScale'] } else { $true }
    $stretch  = if ($null -ne $ResolutionSettings['Stretched']) { [bool]$ResolutionSettings['Stretched'] } else { $false }

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
    # PID exit checks: only scan the boosted table every other cycle
    # when gaming (the common case is no exits), halving the process
    # checks inside the cleanup loop.
    $exitCheckCounter   = 0

    # ---- precompiled matchers (once per watcher run) -----------------
    # Watching 100+ game names individually via Get-Process -Name forces
    # PowerShell to enumerate the whole process table per name-list. We
    # instead snapshot the table ONCE per poll and run cheap in-process
    # matching. Almost every game entry is an EXACT name, so those go into
    # a HashSet for O(1) lookups; only the handful of genuinely wildcard
    # patterns (eg 'discord*', 'r5apex*') fall back to -like. On a low-spec
    # machine this is the difference between ~1% CPU and <0.05% while idle.
    $gameWatchPatterns = @($GameNames | ForEach-Object {
        ([string]$_ -replace '\.exe$','').ToLowerInvariant()
    } | Where-Object { $_ -and $_ -notmatch '^(steam|steamservice|steamwebhelper|riotclientservices|gamingservices)$' })

    $exactGameNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($p in $gameWatchPatterns) { if ($p -notmatch '[*?]') { $null = $exactGameNames.Add($p) } }
    $wildGamePatterns = @($gameWatchPatterns | Where-Object { $_ -match '[*?]' })
    $wildMatcher = if ($wildGamePatterns.Count -gt 0) { $true } else { $false }

    # Merged exclusion list: hard anti-cheat/launcher safety net + anything the
    # user added via Config.ps1 NeverWatchProcesses. Never watched or boosted.
    $neverWatch = @($script:NeverWatchProcesses)
    foreach ($uw in @($NeverWatchProcesses)) {
        $nw = ([string]$uw -replace '\.exe$', '').ToLowerInvariant().Trim()
        if ($nw -and $neverWatch -notcontains $nw) { $neverWatch += $nw }
    }

    try {
        while ($true) {
            # One native process snapshot serves the whole game lookup for
            # this poll cycle. A generic List avoids the pipeline overhead a
            # ForEach-Object filter would add per process.
            try {
                $allProc = [Diagnostics.Process]::GetProcesses()
            } catch {
                Write-Log ("Process snapshot failed: {0}" -f $_.Exception.Message) 'WARN'
                $allProc = @()
            }
            $matchedGames = [System.Collections.Generic.List[Diagnostics.Process]]::new()
            foreach ($p in $allProc) {
                $n = ''
                try { $n = $p.ProcessName } catch { }
                if (-not $n) { continue }
                $nl = $n.ToLowerInvariant()
                # Anti-cheat services / store launchers are NEVER watched or
                # boosted - boosting them can trip anti-cheat integrity checks.
                if ($neverWatch -contains $nl) { continue }
                # O(1) exact-name lookup; only rare wildcard patterns pay the -like loop.
                $isGame = $exactGameNames.Contains($nl)
                if (-not $isGame -and $wildMatcher -and (Test-MatchAny -Name $nl -Patterns $wildGamePatterns)) {
                    $isGame = $true
                }
                if ($isGame) {
                    $matchedGames.Add($p)    # matched game - keep the Process object
                }
            }

            # ---- universal watch: any immersive foreground app counts -----
            # Games/playlists not on the configured list (new indies, windowed
            # titles, media players) rarely appear in GameProcesses. If the
            # foreground window fills its own monitor it IS the game/video the
            # user is focused on - optimize it with the Default profile unless
            # it is a shell/productivity/browser tool. Registration only
            # happens while the window is immersive AND foreground (an alt-tab
            # to a spreadsheet won't start a session), but once registered it
            # stays boosted until the process exits - no flip-flop on alt-tab.
            if ($universalOn -and $matchedGames.Count -eq 0) {
                try {
                    $fgPidNow = Get-ActiveWindowProcessId
                    if ($fgPidNow -gt 0) {
                        $fgProc = Get-Process -Id $fgPidNow -ErrorAction SilentlyContinue
                        if ($fgProc -and -not $fgProc.HasExited -and -not $boosted.ContainsKey($fgProc.Id)) {
                            $fgn = ''
                            try { $fgn = $fgProc.ProcessName } catch { }
                            if ($fgn -and -not ($neverWatch -contains $fgn.ToLowerInvariant()) -and
                                -not ($script:UniversalBlocklist -contains $fgn.ToLowerInvariant()) -and
                                (Test-ImmersiveForegroundWindow -Threshold $immersivePercent)) {
                                $matchedGames.Add($fgProc)
                                Write-Log ("Universal watch: foreground '{0}' (PID {1}) fills its monitor - treating as game/video session." -f $fgn, $fgProc.Id) 'INFO'
                            }
                        }
                    }
                } catch {
                    Write-Log "Universal-watch scan failed: $_" 'WARN'
                }
            }

            # Prefer the game owning the foreground window, but do not treat
            # an overlay, launcher, or transient desktop window as proof that
            # the game ended. During combat this could otherwise restore the
            # boost/resolution state for one poll and introduce a hitch.
            $running = [System.Collections.Generic.List[Diagnostics.Process]]::new()
            if (-not $ActiveGameOnly) {
                foreach ($game in $matchedGames) { $running.Add($game) }
            } else {
                $activeMatches = @($matchedGames | Where-Object {
                    Test-ActiveGameProcess -Process $_ -ActiveOnly $true
                })
                if ($activeMatches.Count -gt 0) {
                    foreach ($game in $activeMatches) { $running.Add($game) }
                } else {
                    foreach ($game in $matchedGames) { $running.Add($game) }
                }
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
                        if ($PrePurgeBeforeLaunch -and -not $preGamePurged -and -not $lowSpecSkipPurge -and -not (Test-RampPending 'purge')) {
                            Add-Ramp 'purge' 0.5 0   # 0.5s delay - fast enough to run before game loads
                        }
                        $preGamePurged = $true

                        # ---- HEAVY steps go onto the staged ramp so the loading
                        #      screen absorbs them one at a time (no launch hitch) ----
                        if ($PurgeOnGameLaunch -and -not $sessionPurged -and -not $lowSpecSkipPurge -and -not (Test-RampPending 'purge2')) {
                            Add-Ramp 'purge2' 8 0   # secondary purge during loading
                        }
                        if (-not $skipScale -and -not $scaledApplied -and -not (Test-RampPending 'resscale') -and $scalePctForGame -gt 0) {
                            # Apply the drop while the game is likely still on its loading
                            # screen so the mode-flash is hidden and the GPU is already at
                            # the lower load when gameplay begins. Low-spec machines feel
                            # this far more, so they get it slightly earlier.
                            $resDelay = if ($isLowSpec) { 6 } else { 10 }
                            Add-Ramp 'resscale' $resDelay 0 $scalePctForGame
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
                                -Activate
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
                # restores the remaining state, clears the recovery journal and
                # removes the pid file, then this watcher process exits.
                # We rely on $hadSession (a game was actually boosted this run),
                # not on $removedAny, so a session that closes while the exit
                # scan is throttled still triggers a clean auto-shutdown.
                if ($ExitWhenGameSessionEnds -and $hadSession -and $boosted.Count -eq 0) {
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
                        try   { Clear-StandbyMemory } catch { }
                        $sessionPurged = $true
                        $lastPurgeUtc  = [datetime]::UtcNow
                    }
                    'purge2' {
                        # Secondary purge during loading screen
                        try   { Clear-StandbyMemory } catch { }
                        $lastPurgeUtc  = [datetime]::UtcNow
                    }
                    'resscale' {
                        try {
                            if (-not $scaledApplied) {
                                # Remember native FIRST so even a crash between the
                                # two calls below is recoverable via the journal.
                                # The target comes from the game's resolution tier
                                # (set when it was detected); 0 falls back to the
                                # legacy global percent.
                                $targetPct = $item.Value
                                if ($targetPct -le 0) { $targetPct = $scalePct }
                                $nativeNow = Get-CurrentDisplayMode
                                $ok = Enable-LowResolutionMode -ScalePercent $targetPct -PreferInteger:([bool]$prefInt) -Stretch:([bool]$stretch)
                                if ($ok) {
                                    $scaledApplied = $true
                                    $journal['scaledActive'] = $true
                                    # Record whether the mode was stretched so a
                                    # crash-recovery restore returns the driver to
                                    # native 1:1 scaling (not just the mode switch).
                                    $nativeNow['Stretched'] = [bool]$stretch
                                    $journal['nativeMode']   = $nativeNow
                                    Save-Journal
                                    Write-Log ("Display switched to {0}% of native (tier {1}%){2}." -f $targetPct, $targetPct, $(if ($stretch) { ' - STRETCHED to fill the panel' } else { '' })) 'OK'
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
            # mid-frame), so during play the CLASSIC purge happens ONLY below
            # the critical floor AND at most once per cooldown window.
            #
            # The ADAPTIVE purge is a separate, self-gated path: it fires only
            # under a RAM-relative floor (scales with the machine) with its own
            # tightening cooldown, and only after the floor is crossed on TWO
            # consecutive checks, so skill/effect bursts and large-map loads are
            # caught WITHOUT needing AllowMidGamePurge (the always-on path that
            # can hitch frames) and a single transient dip never stalls a frame
            # mid-combat. Adaptive tuning is enabled by default.
            # Skipped entirely in low-spec mode when purge is disabled there.
            if ($running.Count -gt 0 -and -not $lowSpecSkipPurge) {
                $nowMs = [datetime]::UtcNow
                # Only probe free RAM when a purge could ACTUALLY run. Both
                # purge paths are cooldown-gated, so probing memory on every
                # poll right after a purge is pure waste. Skipping the probe
                # until a path is eligible trims steady-state watcher CPU during
                # the exact moments (map rendering, effect bursts) the game is busy.
                $classicEligible = $false
                if ($AllowMidGamePurge) {
                    $classicEligible = (($nowMs - $lastPurgeUtc).TotalSeconds -ge $PurgeCooldownSeconds)
                }
                $adaptiveEligible = $false
                if ($adaptiveOn) {
                    if ($adaptiveTotalMB -le 0) {
                        # Resolve total RAM once if the probe failed earlier
                        try { $ms = New-Object Suite.NativeBoost+MEMORYSTATUSEX; $ms.dwLength = [uint32][Runtime.InteropServices.Marshal]::SizeOf([type][Suite.NativeBoost+MEMORYSTATUSEX]); [void][Suite.NativeBoost]::GlobalMemoryStatusEx([ref]$ms); $adaptiveTotalMB = [int]($ms.ullTotalPhys / 1MB) } catch { }
                    }
                    $adaptiveFloorMB = if ($adaptiveTotalMB -gt 0) { [int]($adaptiveTotalMB * $adaptiveFloorPct / 100.0) } else { $CriticalRamFloorMB }
                    # Under pressure the cooldown tightens (down to half the
                    # configured value) so recurring bursts are caught sooner;
                    # it relaxes back out as soon as memory is healthy again.
                    $effCoolMs = [Math]::Max(1000, [int]($adaptiveCoolMs * [Math]::Pow(0.85, [Math]::Min(4, $adaptiveConsecutive - 1))))
                    $adaptiveEligible = (($nowMs - $adaptiveLastUtc).TotalMilliseconds -ge $effCoolMs)
                }

                # Both purge paths are cooldown-gated. When neither is eligible
                # this cycle we skip the RAM probe entirely - probing memory on
                # every poll right after a purge is pure waste, and it keeps the
                # watcher off the CPU during the exact moments (map rendering,
                # effect bursts) the game is busy.
                if ($classicEligible -or $adaptiveEligible) {
                    $freeMB = Get-FreeRamMB
                    $pressureNote = ''

                    # 1) Classic fixed-floor purge (behaves exactly as before).
                    #    Stays opt-in via AllowMidGamePurge because it runs on a
                    #    timer cadence and can hitch a frame mid-render.
                    if ($classicEligible) {
                        if ($freeMB -lt $CriticalRamFloorMB) {
                            Write-Log ("Free RAM critical ({0} MB) - cooldown-gated standby purge..." -f $freeMB) 'WARN'
                            Clear-StandbyMemory
                            $lastPurgeUtc = [datetime]::UtcNow
                        }
                    }

                    # 2) ADAPTIVE purge for skill-effect / large-map load spikes.
                    #    Uses a RAM-relative floor (so it scales with the machine,
                    #    big or small) and tightens its cooldown while pressure
                    #    persists. A standby purge stalls the whole memory manager,
                    #    so it only fires after the floor is crossed on TWO
                    #    consecutive checks - a single transient dip (an ability
                    #    splash, a short effect burst, one map corner) never costs
                    #    a frame in the middle of combat.
                    if ($adaptiveOn) {
                        if ($freeMB -lt $adaptiveFloorMB) {
                            $adaptiveConsecutive++
                            $pressureNote = "adaptive floor ${adaptiveFloorMB}MB; sustained pressure"
                            if ($adaptiveConsecutive -ge 2 -and
                                (([datetime]::UtcNow - $adaptiveLastUtc).TotalMilliseconds -ge $effCoolMs)) {
                                Write-Log ("Adaptive purge: free RAM {0} MB under {1} for {2} consecutive checks ({3})." -f $freeMB, $adaptiveFloorMB, $adaptiveConsecutive, $pressureNote) 'WARN'
                                Clear-StandbyMemory
                                $adaptiveLastUtc       = [datetime]::UtcNow
                                $adaptiveConsecutive   = 0
                            }
                        } else {
                            $adaptiveConsecutive = 0
                        }
                    }
                }
            }

            # Re-assert per-game priority/affinity during play. Skill-effect
            # bursts and big-map loads can re-prioritize other processes or the
            # OS can knock players back; re-asserting keeps the game ahead of
            # hogs so heavy effects don't cause visible hitches. Cheap (only
            # touches processes that already exist in our table) and throttled
            # to every N cycles.
            if ($reassertPriorities -and $running.Count -gt 0) {
                $reassertCounter++
                if (($reassertCounter % $reassertEveryCycles) -eq 0) {
                    foreach ($bid in @($boosted.Keys)) {
                        $bprof = $script:GameProfiles[$boosted[$bid]]
                        try {
                            $bproc = Get-Process -Id $bid -ErrorAction SilentlyContinue
                            if ($bproc -and -not $bproc.HasExited) {
                                $needBoost = $false
                                try { $needBoost = ($bproc.PriorityClass -ne [string]$bprof.Priority) } catch { $needBoost = $true }
                                if ($needBoost -and $script:PriorityCapable) {
                                    Invoke-ProcessBoost -Process $bproc -Profile $bprof -MaxCores $lowSpecMaxCores
                                }
                            }
                        } catch { }
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
                # Guard the ms math against overflow: with an unset/far-past
                # timestamp the interval exceeds Int32 and crashes the watcher.
                $hbSinceMs = (([datetime]::UtcNow - $lastHeartbeatUtc).TotalMilliseconds)
                if ($hbSinceMs -gt [int]::MaxValue) { $hbSinceMs = [int]::MaxValue }
                $hbDueMs = $idleHeartbeatMs - [int]$hbSinceMs
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
            # Process.GetProcesses returns live handles. Dispose the snapshot
            # every cycle so long sessions do not accumulate kernel handles or
            # trigger expensive full-process GC pauses.
            foreach ($procSnapshot in @($allProc)) {
                try { $procSnapshot.Dispose() } catch { }
            }
            $allProc = @()
            $stopping = Wait-StopOrTimeout -Milliseconds $waitMs -StopEvent $StopEvent
            if ($stopping) {
                Write-Log 'Stop signal received.' 'ACTION'
                break
            }
        }
    } finally {
        Update-BackgroundSilence -State $silenced -Journal $journal
        Stop-FrameGenerationTool -LaunchedByUs $fgByUs -ToolPid $fgPid
        $journal['fgToolPid'] = 0
        Restore-NativeResolution           # never leave the screen scaled down
        Undo-FsoCompatFlags -State $fsoDone -Journal $journal
        Set-TimerResolution -Restore
        Save-Journal                       # persist the all-clear state briefly
        Clear-WatcherJournal               # clean exit => nothing left to repair
        Write-Log 'Game watcher stopped, priorities/timer/resolution restored.' 'INFO'
    }
}

Export-ModuleMember -Function Enable-GamingPowerPlan, Disable-GameDVR, Set-MultimediaTweaks,
    Set-TimerResolution, Clear-StandbyMemory, Invoke-ProcessBoost,
    Start-GameWatcher, Get-FreeRamMB, Get-GameProfile, Test-LowSpecHardware,
    Invoke-FrameGenerationTool, Stop-FrameGenerationTool
