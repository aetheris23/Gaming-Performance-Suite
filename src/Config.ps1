# ============================================================
#  Config.ps1 - user-tunable settings
#  Edit values here; no other file needs changing.
# ============================================================

@{
    # ---- Game watcher ---------------------------------------
    # Process names (WITHOUT .exe) to auto-boost when detected.
    # Expanded to cover all major game sources and stores.
    GameProcesses = @(
        # === Riot Games (actual game processes, not launchers) ===
        'VALORANT-Win64'
        'League of Legends'
        'lol_dragon'

        # === Steam ===
        'hl2', 'cs2', 'csgo', 'dota2'
        'GTA5', 'RDR2'
        'FortniteClient-Win64Shipping'
        'Minecraft.Windows', 'javaw'
        'Cyberpunk2077'
        'eldenring'
        'HogwartsLegacy'
        'BaldursGate3', 'bg3_dx11'
        'Witcher3'
        'stardewvalley'
        'Terraria'
        'HollowKnight'
        'Celeste'
        'Hades'
        'Portal2'
        'HaloInfinite'
        'ForzaHorizon5', 'ForzaMotorsport'
        'RedDeadRedemption2'
        'Starfield'
        'Palworld'
        'LethalCompany'
        'ContentWarning'
        'Helldivers2'
        'MarvelRivals'
        'Stalker2'
        'OnceHuman'
        'DeltaForce'
        'TheFirstDescendant'
        'ZenlessZoneZero'

        # === Epic Games ===
        'ShooterGame'

        # === PlayStation emulators ===
        'pcsx2', 'pcsx2-qt', 'pcsx2-qtx64'
        'AetherSX2'
        'play!'
        'duckstation'

        # === Nintendo emulators ===
        'yuzu', 'suyu', 'ryujinx', 'sudachi', 'citron'
        'dolphin'
        'cemu'

        # === Multi-system emulators ===
        'RetroArch'

        # === Other emulators ===
        'ppsspp', 'PPSSPPWindows'
        'xemu'
        'qemu-system'
        'mame', 'mame64'
        'mednafen'
        'snes9x'
        'fceux'
        'epsxe'
        'bizhawk'

        # === Android emulators on PC ===
        'LdBoxHeadless', 'LdVBoxHeadless'   # LDPlayer
        'dnplayer'
        'Nox', 'NoxHandle', 'NoxVMHandle'   # NoxPlayer
        'MuMuPlayer', 'MuMuVMMHeadless'     # MuMu
        'BlueStacks', 'HD-Player', 'BstkVMM'  # BlueStacks
        'MEmu', 'MEmuHeadless'              # MEmu

        # === Roblox / Android games ===
        'RobloxPlayerBeta'
        'com.mobile.legends'
        'com.levelinfinite.haop'
        'com.tencent.tmgp.sgame'

        # === EA ===
        'NeedForSpeed'

        # === Ubisoft ===
        'thehuntercotw', 'orleanspawn', 'ghostreconbreakpoint'

        # === Blizzard ===
        'Overwatch'
        'Diablo'
        'WoW'

        # === VR ===
        'vrcompositor'
        'oculus'
        'openvr'

    )

    # Processes NEVER boosted or touched - NOT even temporarily during a
    # watcher session. Reserved for anti-cheat, kernel services and
    # launcher/driver helpers that can flag priority changes as tampering
    # (e.g. 'vgc', 'BEService', 'EasyAntiCheat', 'Battle.net'). The built-in
    # safety list in GameBoost never changes; extend it here if a tool on your
    # custom build is missing from that list.
    NeverWatchProcesses    = @(
        'vgc', 'vgtray', 'vgk'                          # Riot Vanguard (kernel)
        'BEService', 'EasyAntiCheat', 'EasyAntiCheatService'   # BattlEye / EAC
        'BattlEyeService'
        'agent', 'battle.net', 'blizzardbrowserhelper'  # Battle.net / Blizzard
        'eadesktop', 'eabackgroundservice', 'eacore', 'eaapperror'  # EA app
    )

    # Only boost the game owning the active window. If the desktop backend
    # cannot report a foreground process, the watcher safely falls back to
    # matching the configured game list.
    ActiveGameOnly         = $true
    WatcherPollSeconds     = 10      # scan cadence while a game is running (reduced from 15s for responsiveness)
    IdlePollSeconds        = 35      # slower cadence while NO game runs (lighter idle load)
    ExtendedIdlePollSeconds= 90      # ultra-low polling after 5+ min idle (saves CPU on old PCs)
    IdleHeartbeatMinutes   = 5       # log "watcher alive" every N minutes while idle (0 = off)

    # ---- Usage Profiles (conservative presets) ------------------
    # Select ONE profile at startup to apply a coherent set of defaults.
    # These are REVERSIBLE - all session-scoped changes are undone on exit.
    # Profile values OVERRIDE the individual settings below when applied.
    # Usage: set ActiveProfile = 'Gaming' | 'Development' | 'DailyUse' | 'Custom'
    #   'Custom' means use the individual settings below without profile override.
    ActiveProfile = 'Custom'   # 'Gaming' | 'Development' | 'DailyUse' | 'Custom'
    Profiles = @{
        # GAMING: Maximum FPS stability, willing to trade visuals for consistency
        # - Aggressive resolution scaling (75% target)
        # - Priority boost + timer + purge on launch
        # - Adaptive tuning ON for effect bursts / large maps
        # - Background apps silenced
        # - Frame-gen bridge enabled if tool configured
        # - Network optimizations ON
        Gaming = @{
            ActiveGameOnly         = $true
            WatcherPollSeconds     = 10
            IdlePollSeconds        = 35
            ExtendedIdlePollSeconds= 90
            ExitWhenGameSessionEnds= $true
            PurgeOnGameLaunch      = $true
            AllowMidGamePurge      = $false
            CriticalRamFloorMB     = 768
            PreGameOptimization    = $true
            PrePurgeBeforeLaunch   = $true
            LowSpecMode            = @{ Mode = 'Auto'; SkipFrameGenBridge = $false; SkipResolutionSwitch = $false; SkipStandbyPurge = $false; SkipBackgroundSilence = $false }
            AdaptiveTuning         = @{ Enabled = $true; AdaptivePurgeFloor = 10; PressureCooldownSec = 60; ReassertPriorities = $true; ReassertEveryCycles = 3 }
            ResolutionScalePercent = 75
            PreferIntegerScale     = $true
            StretchedResolution    = $false
            ProfileTiers           = @{ Emulator = 'Medium'; Steam = 'Medium'; Competitive = 'Native'; Android = 'Medium'; Default = 'Medium' }
            GameTierOverrides      = @{ 'VALORANT-Win64' = 'Native' }
            UniversalWatch         = $true
            ImmersiveWindowThreshold = 0.90
            FrameGeneration        = @{ Enabled = $false; ToolPath = '' }  # set Enabled=$true + ToolPath if you own Lossless Scaling
            NetworkOptimization    = @{ Enabled = $true; WatchLocalPacketLoss = $true; DisableInterruptModeration = $true; DisableReceiveSegmentCoalescing = $false; DisableLargeSendOffload = $false }
            PowerOptimization      = @{ Enabled = $true; ForceMaxCpuOnBattery = $false; ForcePcieOffOnBattery = $false }
            MicrophoneEnhancement  = @{ Enabled = $false; ToolPath = ''; Profile = 'VoiceFocus'; AutoLaunchWithGame = $true; RestoreOnExit = $true }
            LegacyGpuSupport       = @{ Mode = 'Auto'; SkipResolutionSwitch = $null; EnableHags = $null; DisableFullscreenOptimizations = $null; ScalePercentOverride = 0 }
            FrameTimeDiagnostics   = @{ Enabled = $false; SampleIntervalMs = 16; LogIntervalSeconds = 30; MaxSamples = 10000; LogPercentiles = @(50, 99, 99.9) }
        }

        # DEVELOPMENT: No visual changes, no aggressive tweaks, minimal overhead
        # - Native resolution (no scaling)
        # - No priority boosting, no timer changes
        # - No standby purges
        # - No background silencing
        # - No frame-gen, no network tweaks, no power plan changes
        # - Watcher still runs but only logs; useful for monitoring
        Development = @{
            ActiveGameOnly         = $true
            WatcherPollSeconds     = 30
            IdlePollSeconds        = 60
            ExtendedIdlePollSeconds= 120
            ExitWhenGameSessionEnds= $true
            PurgeOnGameLaunch      = $false
            AllowMidGamePurge      = $false
            CriticalRamFloorMB     = 1024
            PreGameOptimization    = $false
            PrePurgeBeforeLaunch   = $false
            LowSpecMode            = @{ Mode = 'Off'; SkipFrameGenBridge = $true; SkipResolutionSwitch = $true; SkipStandbyPurge = $true; SkipBackgroundSilence = $true }
            AdaptiveTuning         = @{ Enabled = $false }
            ResolutionScalePercent = 0
            PreferIntegerScale     = $true
            StretchedResolution    = $false
            ProfileTiers           = @{ Emulator = 'Native'; Steam = 'Native'; Competitive = 'Native'; Android = 'Native'; Default = 'Native' }
            GameTierOverrides      = @{}
            UniversalWatch         = $false
            ImmersiveWindowThreshold = 0.95
            FrameGeneration        = @{ Enabled = $false; ToolPath = '' }
            NetworkOptimization    = @{ Enabled = $false }
            PowerOptimization      = @{ Enabled = $false }
            MicrophoneEnhancement  = @{ Enabled = $false; ToolPath = ''; Profile = 'Default'; AutoLaunchWithGame = $false; RestoreOnExit = $true }
            LegacyGpuSupport       = @{ Mode = 'Off'; SkipResolutionSwitch = $true; EnableHags = $false; DisableFullscreenOptimizations = $false; ScalePercentOverride = 0 }
            FrameTimeDiagnostics   = @{ Enabled = $true; SampleIntervalMs = 16; LogIntervalSeconds = 60; MaxSamples = 5000; LogPercentiles = @(50, 99) }
        }

        # DAILY USE: Light background optimization, no gaming-specific tweaks
        # - No resolution scaling, no game-specific boosting
        # - Pre-game optimizations (Game DVR off, MMCSS) applied once
        # - Standby purge only on explicit launch (not automatic)
        # - Universal watch OFF - only configured games
        # - Network: monitoring only, no driver tweaks
        # - Power: only on AC, not forced on battery
        DailyUse = @{
            ActiveGameOnly         = $true
            WatcherPollSeconds     = 20
            IdlePollSeconds        = 45
            ExtendedIdlePollSeconds= 90
            ExitWhenGameSessionEnds= $true
            PurgeOnGameLaunch      = $false
            AllowMidGamePurge      = $false
            CriticalRamFloorMB     = 1024
            PreGameOptimization    = $true
            PrePurgeBeforeLaunch   = $false
            LowSpecMode            = @{ Mode = 'Auto'; SkipFrameGenBridge = $true; SkipResolutionSwitch = $true; SkipStandbyPurge = $true; SkipBackgroundSilence = $true }
            AdaptiveTuning         = @{ Enabled = $true; AdaptivePurgeFloor = 15; PressureCooldownSec = 120; ReassertPriorities = $false; ReassertEveryCycles = 5 }
            ResolutionScalePercent = 0
            PreferIntegerScale     = $true
            StretchedResolution    = $false
            ProfileTiers           = @{ Emulator = 'Native'; Steam = 'Native'; Competitive = 'Native'; Android = 'Native'; Default = 'Native' }
            GameTierOverrides      = @{}
            UniversalWatch         = $false
            ImmersiveWindowThreshold = 0.95
            FrameGeneration        = @{ Enabled = $false; ToolPath = '' }
            NetworkOptimization    = @{ Enabled = $true; WatchLocalPacketLoss = $true; DisableInterruptModeration = $false; DisableReceiveSegmentCoalescing = $false; DisableLargeSendOffload = $false }
            PowerOptimization      = @{ Enabled = $true; ForceMaxCpuOnBattery = $false; ForcePcieOffOnBattery = $false }
            MicrophoneEnhancement  = @{ Enabled = $false; ToolPath = ''; Profile = 'Default'; AutoLaunchWithGame = $false; RestoreOnExit = $true }
            LegacyGpuSupport       = @{ Mode = 'Auto'; SkipResolutionSwitch = $null; EnableHags = $null; DisableFullscreenOptimizations = $null; ScalePercentOverride = 0 }
            FrameTimeDiagnostics   = @{ Enabled = $false; SampleIntervalMs = 16; LogIntervalSeconds = 60; MaxSamples = 5000; LogPercentiles = @(50, 99) }
        }

        # CUSTOM: Use individual settings below (no profile override)
        Custom = @{}
    }

    # ---- Session lifecycle ----------------------------------
    # When the last monitored game exits, the watcher undoes every
    # SESSION-scoped change (process priorities, display mode, pacing
    # timer, silenced apps, FSO flags, network profile) and EXITS
    # completely instead of staying resident and polling for a "next
    # game". System-wide registry tweaks set with PreGameOptimization
    # (Game DVR off, MMCSS games priority, HAGS) are deliberate
    # persistent optimizer settings and stay applied. Set $false to
    # keep the old always-on behavior (watcher waits for future games).
    ExitWhenGameSessionEnds = $true

    # ---- Standby memory (stutter-safe policy) -----------------
    # A standby-list purge stalls the whole memory manager, so it is
    # never repeated mid-gameplay on a timer. It runs once when a game
    # is detected (the loading screen absorbs the cost) and during play
    # only below the critical floor, at most once per cooldown.
    PurgeOnGameLaunch           = $true   # one purge right when a game is detected
    # Standby purges pause the memory manager and can cause a visible hitch
    # during combat/effects. Keep this off unless the machine is genuinely
    # exhausting RAM while a game is already running.
    AllowMidGamePurge           = $false
    CriticalRamFloorMB          = 768     # mid-game purge ONLY below this free-RAM floor
    StandbyPurgeCooldownSeconds = 900     # minimum seconds between two purges

    # ---- Pre-game optimization -------------------------------
    # Apply optimizations BEFORE the game process appears to
    # eliminate launch stutter entirely.
    PreGameOptimization         = $true   # apply system-wide FPS tweaks on idle detect
    PrePurgeBeforeLaunch        = $true   # purge standby memory before game launches (not after)

    # ---- Low-spec / legacy PC mode ---------------------------
    # For older or low-spec hardware (e.g. Intel i3 7th Gen,
    # 8-16GB RAM, Intel HD/UHD Graphics). Reduces overhead and
    # skips heavy optimizations that cause stutter on weak hardware.
    # Recommended for any PC that struggles with modern games.
    #
    #   Mode = 'Auto'   AUTO-DETECT weak hardware (legacy GPU + low CPU
    #                   cores/clock) and enable low-spec mode for you -
    #                   no config edit needed on a low-spec laptop.
    #          'On'     always force low-spec mode on.
    #          'Off'    always force it off (strong desktop).
    #   Enabled is a legacy manual override: $null = follow Mode,
    #                   $true/$false = force on/off regardless of Mode.
    LowSpecMode = @{
        Mode                    = 'Auto'   # 'Auto' | 'On' | 'Off'
        Enabled                 = $null    # manual override ($null = follow Mode)
        SkipResolutionSwitch    = $false  # skip display resolution changes
        SkipStandbyPurge        = $false  # skip standby memory purging
        SkipBackgroundSilence   = $false  # skip background app deprioritization
        SkipFrameGenBridge      = $true   # skip frame-generation companion app
        ReducedPolling          = $true   # use longer poll intervals (15s/35s)
        SkipHags                = $true   # skip HAGS registry write on old GPUs
        MaxCpuCores             = 0       # 0 = auto-detect; >0 = limit affinity to N cores
        AggressiveTimer         = $true   # use 1ms timer for better frame pacing on low-spec
    }

    # ---- Adaptive mid-game tuning ---------------------------------
    # Smooth FPS during heavy moments (skill/effect bursts, large maps).
    # When a game runs, the watcher monitors memory pressure and re-asserts
    # the game's priority/affinity so drops don't cause visible hitches.
    #   Enabled              : master switch (ON by default so effect/ability
    #                          bursts and big map loads are caught without
    #                          needing a config edit)
    #   AdaptivePurgeFloor   : % of total RAM treated as "under pressure".
    #                          Scales with the machine (small/large maps).
    #   PressureCooldownSec  : min seconds between adaptive purges (tightens
    #                          automatically while pressure persists).
    #                          NOTE: the purge needs the floor crossed on TWO
    #                          consecutive checks before it runs, so a single
    #                          transient dip (one ability splash / map corner)
    #                          can never stall a frame mid-combat.
    #   ReassertPriorities   : periodically re-apply the game's priority/
    #                          affinity if the OS or heavy load knocked it back
    #   ReassertEveryCycles  : re-check every N poll cycles during play
    AdaptiveTuning = @{
        # The adaptive purge is RAM-relative and cooldown-gated - it only runs
        # below the floor, at most once per cooldown. The classic always-on
        # mid-game purge (AllowMidGamePurge) stays OFF because THAT path can
        # hitch frames; the adaptive path is what catches combat spikes.
        Enabled              = $true
        AdaptivePurgeFloor   = 10
        PressureCooldownSec  = 60
        ReassertPriorities   = $true
        ReassertEveryCycles  = 3
    }

    # ---- Frame-time diagnostics ---------------------------------
    # Lightweight frame-time sampling for measuring actual game smoothness.
    # Uses high-resolution timer (QueryPerformanceCounter) to measure frame
    # intervals. Logs percentile stats (avg, 1% low, 0.1% low) periodically.
    # Enable for troubleshooting; adds minimal overhead (~0.1% CPU).
    FrameTimeDiagnostics = @{
        Enabled            = $true    # master switch - enabled for measurable FPS/frame-time evidence
        SampleIntervalMs   = 16       # target frame interval to sample (~60 FPS = 16.67ms)
        LogIntervalSeconds = 30       # how often to log percentile stats
        MaxSamples         = 10000    # max samples per log interval (ring buffer)
        LogPercentiles     = @(50, 99, 99.9)  # percentiles to report (median, 1% low, 0.1% low)
    }

    # ---- Universal watch: ANY game or video ------------------
    # By default the watcher targets ANY foreground window that is immersive
    # (a borderless-fullscreen game or a maximized video player) in ADDITION
    # to the known-game list above. This makes FPS stability + dynamic
    # resolution scaling apply to titles that are not in the list - new or
    # unknown games, borderless-windowed games, and video players of any kind.
    # Set $false to restrict the watcher to the configured game list only.
    UniversalWatch = $true
    # A foreground window is treated as a game/video when it covers at least
    # this fraction of its own monitor. 0.90 catches maximized and
    # borderless-fullscreen windows reliably while ignoring windowed apps
    # that are merely large. Lower it (e.g. 0.60) to also optimize smaller
    # windowed games and videos.
    ImmersiveWindowThreshold = 0.90

    # ---- Per-game classification -----------------------------
    # The watcher auto-detects: Emulator / Steam / Competitive / Default
    # (by install path, then process name). Force a classification here:
    ProfileOverrides = @{
        # 'MyEmuGame'   = 'Emulator'
        # 'SomeGame'    = 'Steam'
        # 'MyOnlineGame'= 'Competitive'
    }

    # ---- Dynamic resolution scaling --------------------------
    # While a game runs the display drops to a lower same-aspect
    # mode (GPU load falls hard); native is restored on exit/stop.
    #
    # One of four QUALITY TIERS is picked per game, so different
    # titles get the resolution that suits them automatically:
    #   Low    -> aggressive drop - the biggest FPS gain
    #   Medium -> balanced (the classic default)
    #   High   -> mild drop - nearly native sharpness, still helps
    #   Native -> no switch (keep the panel's native resolution)
    # Each tier = target render width as % of native (25-99).
    ResolutionTiers = @{
        Low    = 55
        Medium = 75
        High   = 88
        Native = 0
    }

    # Default tier for every detected profile:
    #   Emulator / Steam / Competitive / Android / Default
    #
    # IMPORTANT: 'Competitive' defaults to 'Native' (no fullscreen mode switch).
    # For aim-oriented shooters (Valorant, CS2, Dota 2) a resolution drop on a
    # 144Hz panel almost always lands on a mode that only exists at 60Hz, which:
    #   - makes distant enemies blurry/mushy upscaled back to fullscreen (they
    #     blend into the environment and are very hard to see at range)
    #   - changes the effective mouse aim / reduces input smoothness
    #   - forces a display-mode switch (and back) that hitches the renderer
    #     right around round start
    #   - feels like input lag even though the game runs fine
    # These titles already run fine at native on low-spec hardware, so they get
    # the wins that DON'T touch the display: priority, timer, purge.
    # To restore the aggressive "max FPS at lower resolution" behavior, set the
    # per-game override below to 'Low' (or set Competitive to 'Low' here).
    ProfileTiers = @{
        Emulator    = 'Medium'   # emulators upscale crisp at half/quarter steps
        Steam       = 'Medium'   # balanced for most AAA titles
        Competitive = 'Native'   # NO display/fullscreen-mode switch (keeps aim + range visibility)
        Android     = 'Medium'   # Android emulators are very GPU-heavy
        Default     = 'Medium'   # any unclassified game
    }

    # Per-game tier override (process name WITHOUT .exe -> tier).
    # Beats the profile default above. VALORANT is pinned to Native so a
    # re-edit of the competitive default above can never silently re-enable
    # the 540p/60Hz drop for it. Delete this line to let other esports titles
    # follow the Competitive default instead:
    GameTierOverrides = @{
        'VALORANT-Win64' = 'Native'   # keep aim + long-range visibility intact
        # 'pcsx2'          = 'Low'
        # 'cs2'            = 'High'
        # 'dolphin'        = 'Native'
    }

    # Legacy single-value override: this is the fallback only for a
    # profile/game that resolves to no tier (or uses the old setting).
    ResolutionScalePercent = 75      # target width as % of native (25-99)
    PreferIntegerScale     = $true   # at equal distance to the tier target,
                                     # prefer an exact integer-ratio mode
                                     # (e.g. exactly 1/2 native): crisp upscale

    # FPS "stretched resolution" look: pick the scaled mode at the tier
    # percent EVEN IF it has a different aspect ratio (e.g. a 4:3 mode on a
    # 16:9 panel) and fill the WHOLE screen with it (no black bars).
    # Classic for CS2 / Valorant / shooters. Requires a lower tier to be
    # active (native tier never stretches). See DisplayScale.psm1.
    StretchedResolution = $false

    # ---- Legacy GPU support ----------------------------------
    # Relaxes aggressive tricks on older graphics hardware
    # (pre-Pascal GeForce, pre-RX Radeon/GCN, Intel HD 2000-4000,
    # all GMA chips) that can misbehave with display-mode switches,
    # HAGS or fullscreen optimizations.
    #   Mode = 'Auto' : detect via src/GpuDetect.psm1 and decide
    #         'On'    : force legacy-safe behavior
    #         'Off'   : never treat any GPU as legacy
    # Individual values below override what 'Auto' would pick
    # (leave at $null / 0 to follow Mode).
    LegacyGpuSupport = @{
        Mode                          = 'Auto'
        SkipResolutionSwitch          = $null   # $true = never change display mode
        EnableHags                    = $null   # $false = do NOT write HwSchMode=2
        DisableFullscreenOptimizations= $null   # $true = per-game FSO compat flag
        ScalePercentOverride          = 0       # >0 = gentler target width % for legacy runs
    }

    # ---- Frame generation ------------------------------------
    # Frames cannot be invented by an external script; real frame
    # insertion happens in GPU drivers or a dedicated interpolator.
    # If you own one (e.g. Lossless Scaling), point ToolPath at its
    # exe and it launches automatically with each detected game.
    FrameGeneration = @{
        Enabled = $false
        ToolPath = ''                  # e.g. 'C:\Program Files\Lossless Scaling\LosslessScaling.exe'
    }

    # ---- Microphone enhancement ---------------------------------
    # Real-time audio processing requires native code with deterministic
    # latency (sub-10ms). PowerShell cannot provide this. This module
    # launches a configured companion tool (like the frame-gen bridge)
    # that handles the DSP pipeline and exposes a virtual microphone.
    #
    # COMPANION TOOL REQUIREMENTS:
    #   - Must accept microphone input and produce enhanced output
    #   - Must expose a virtual microphone endpoint (VB-Cable, Voicemeeter,
    #     or custom WDM/KS driver) so apps/games can select it as input
    #   - Must run headless/minimized
    #   - Recommended: RNNoise-based tool (native, ~2MB, <5% CPU)
    #
    # VIRTUAL MICROPHONE NOTE:
    #   Windows has no built-in virtual microphone that a user-mode app
    #   can create without a kernel driver. The companion tool MUST install
    #   its own virtual audio driver. This is a hard requirement.
    #   Without a virtual cable, the module can still capture + process +
    #   monitor (playback to default render device) for testing.
    #
    #   Built-in DSP pipeline parameters (used when ToolPath is empty):
    #     GainDb             : pre-amp gain in dB (default 0)
    #     NoiseGateEnabled   : attenuate below threshold (default $true)
    #     NoiseGateThresholdDb: gate opening threshold (default -40)
    #     NoiseGateFloorDb   : gain applied when gated (default -60)
    #     NoiseSuppressionEnabled : spectral subtraction (default $true)
    #     NoiseSuppressionStrength: 0-1, how aggressively to suppress (default 0.5)
    #     CompressorEnabled  : reduce dynamic range (default $true)
    #     CompressorThresholdDb: compression threshold (default -20)
    #     CompressorRatio    : compression ratio (default 4)
    #     LimiterEnabled     : clipping protection (default $true)
    #     LimiterCeilingDb   : max output level (default -3)
    #     AgcEnabled         : automatic gain control (default $false)
    #     AgcTargetDb        : AGC target level (default -18)
    #     AgcRate            : AGC adaptation speed 0-1 (default 0.01)
    MicrophoneEnhancement = @{
        Enabled                 = $false    # master switch
        ToolPath                = ''        # e.g. 'C:\Tools\MicEnhance\MicEnhance.exe'
        Profile                 = 'Default' # 'VoiceFocus' | 'NoiseSuppression' | 'Custom'
        AutoLaunchWithGame      = $true     # launch when game detected
        RestoreOnExit           = $true     # stop tool when watcher stops
        # Built-in DSP parameters
        GainDb                  = 0         # pre-amp gain in dB
        NoiseGateEnabled        = $true     # attenuate silent frames
        NoiseGateThresholdDb    = -40       # gate opening threshold (dB)
        NoiseGateFloorDb        = -60       # gain when gated (dB)
        NoiseSuppressionEnabled = $true     # spectral noise suppression
        NoiseSuppressionStrength= 0.5       # 0-1 suppression aggressiveness
        CompressorEnabled       = $true     # dynamic range compression
        CompressorThresholdDb   = -20       # compressor threshold (dB)
        CompressorRatio         = 4         # compressor ratio
        LimiterEnabled          = $true     # clipping protection
        LimiterCeilingDb        = -3        # max output level (dB)
        AgcEnabled              = $false    # automatic gain control
        AgcTargetDb             = -18       # AGC target level (dB)
        AgcRate                 = 0.01      # AGC adaptation speed (0-1)
    }

    # ---- Network latency & packet loss (menu option 1 / watcher) ----
    # Applied ONCE per session - before the game connects - and reverted
    # when the session ends, the watcher stops, or a crash is repaired
    # (see NetTune.psm1). Every switch is independent.
    #
    # Network monitoring is enabled by default. System/driver tweaks are
    # opt-in because their effects vary by adapter, driver, and connection.
    # No local setting can lower the route/server RTT baseline.
    #
    # Anti-cheat safe: only documented Windows settings are changed. No
    # packet is injected, filtered, spoofed or reordered, and no game or
    # anti-cheat process (Vanguard/BattlEye/EAC) is touched.
    NetworkOptimization = @{
        # Master switch for local link monitoring and optional tweaks.
        Enabled                  = $true

        # Optional changes. Leave defaults unless a measured, repeatable
        # test identifies a specific local cause on this machine.
        DisableNetworkThrottling = $false
        RemoveBandwidthLimit     = $false
        TcpLowLatency            = $false # TCP only; does not affect UDP game traffic
        DisableNicPowerSaving    = $false
        WirelessMaxPerformance   = $false
        DisableReceiveSegmentCoalescing = $false # Driver-specific; does not tune UDP
        DisableLargeSendOffload         = $false # Driver-specific; does not tune UDP
        WifiStayOnStrongest      = $false # Legacy key; lowest roaming can delay AP handoff
        PauseBackgroundDownloads = $false # Prefer pausing the specific download in its app
        DisableInterruptModeration = $false
        RestartChangedAdapters = $false # Avoid disconnecting active links

        # Samples adapter error/discard counters while a game is detected.
        # These counters are clues, not a complete end-to-end loss measure.
        WatchLocalPacketLoss   = $true
    }

    # ---- Power profile (menu option 1 / full optimization) -----
    # The gaming power plan forces min processor state 100% and PCIe link
    # power-management OFF to remove FPS dips. On a laptop those aggressive
    # values drain the battery, so by default they apply ONLY while on AC.
    # Set the two switches to $true only if you want them forced on battery
    # too (matches the old always-on behavior).
    PowerOptimization = @{
        Enabled                = $true
        ForceMaxCpuOnBattery   = $false
        ForcePcieOffOnBattery  = $false
    }
}
