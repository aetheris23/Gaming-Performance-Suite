# ============================================================
#  Config.ps1 - user-tunable settings
#  Edit values here; no other file needs changing.
# ============================================================

@{
    # ---- Game watcher ---------------------------------------
    # Process names (WITHOUT .exe) to auto-boost when detected.
    # Expanded to cover all major platforms and game sources.
    GameProcesses = @(
        # === Riot Games ===
        'VALORANT-Win64'
        'RiotClientServices'
        'LeagueClient'
        'League of Legends'
        'lol_dragon'

        # === Steam ===
        'steam', 'steamservice', 'steamwebhelper'
        'hl2', 'cs2', 'csgo', 'dota2'
        'GTA5', 'GTA5.exe', 'RDR2'
        'FortniteClient-Win64Shipping'
        'Minecraft.Windows', 'javaw'
        'Cyberpunk2077', 'cyberpunk2077'
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
        'FortniteClient-Win64Shipping'
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
        'Ryujinx'

        # === Multi-system emulators ===
        'RetroArch'
        'RetroArch.exe'

        # === Other emulators ===
        'ppsspp', 'PPSSPPWindows'
        'xemu'
        'qemu-system'
        'Dolphin'
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
        '夜神模拟器', 'Nox'
        'bluestacks'

        # === Xbox app / Microsoft Store ===
        'gamingservices'
        'Xbox.TCUI'
        'ms-store'

        # === EA ===
        'EADesktop'
        'EABackgroundService'
        'BEService'
        'NeedForSpeed'

        # === Ubisoft ===
        'UbisoftConnect'
        'upc'

        # === Blizzard ===
        'Battle.net'
        'Agent.exe'
        'Overwatch'
        'Diablo'
        'WoW'

        # === Other launchers ===
        'goggalaxy'
        'itch'
        'Itch.io'

        # === VR ===
        'vrcompositor'
        'oculus'
        'openvr'

        # === General gaming patterns ===
        'game', 'gamer', 'gaming'
    )

    WatcherPollSeconds     = 10      # scan cadence while a game is running
    IdlePollSeconds        = 25      # slower cadence while NO game runs (lighter idle load)
    ExtendedIdlePollSeconds= 60      # ultra-low polling after 5+ min idle (saves CPU on old PCs)
    IdleHeartbeatMinutes   = 5       # log "watcher alive" every N minutes while idle (0 = off)

    # ---- Session lifecycle ----------------------------------
    # When the last monitored game exits, the watcher undoes every
    # optimization and EXITS completely instead of staying resident
    # and polling for a "next game". Nothing is left running in the
    # background on low-spec machines. It still stops instantly via
    # Stop-GamingSuite.bat or menu option 5. Set $false to keep the
    # old always-on behavior (watcher waits for future games).
    ExitWhenGameSessionEnds = $true

    # ---- Standby memory (stutter-safe policy) -----------------
    # A standby-list purge stalls the whole memory manager, so it is
    # never repeated mid-gameplay on a timer. It runs once when a game
    # is detected (the loading screen absorbs the cost) and during play
    # only below the critical floor, at most once per cooldown.
    PurgeOnGameLaunch           = $true   # one purge right when a game is detected
    CriticalRamFloorMB          = 768     # mid-game purge ONLY below this free-RAM floor
    StandbyPurgeCooldownSeconds = 900     # minimum seconds between two purges
    FreeRamThresholdMB          = 2048    # deprecated (kept for compatibility)

    # ---- Pre-game optimization -------------------------------
    # Apply optimizations BEFORE the game process appears to
    # eliminate launch stutter entirely.
    PreGameOptimization         = $true   # apply power/network/multimedia tweaks on idle detect
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
        MinimalNetworkTweaks    = $false  # apply only essential network tweaks
        SkipHags                = $true   # skip HAGS registry write on old GPUs
        MaxCpuCores             = 0       # 0 = auto-detect; >0 = limit affinity to N cores
        AggressiveTimer         = $false  # use 1ms timer instead of 2ms (causes more interrupts)
    }

    # ---- Adaptive mid-game tuning ---------------------------------
    # Smooth FPS during heavy moments (skill/effect bursts, large maps).
    # When a game runs, the watcher monitors memory pressure and re-asserts
    # the game's priority/affinity so drops don't cause visible hitches.
    #   Enabled              : master switch
    #   AdaptivePurgeFloor   : % of total RAM treated as "under pressure".
    #                          Scales with the machine (small/large maps).
    #   PressureCooldownSec  : min seconds between adaptive purges (tightens
    #                          automatically while pressure persists).
    #   ReassertPriorities   : periodically re-apply the game's priority/
    #                          affinity if the OS or heavy load knocked it back
    #   ReassertEveryCycles  : re-check every N poll cycles during play
    AdaptiveTuning = @{
        Enabled              = $true
        AdaptivePurgeFloor   = 10
        PressureCooldownSec  = 60
        ReassertPriorities   = $true
        ReassertEveryCycles  = 3
    }

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
    ProfileTiers = @{
        Emulator    = 'Medium'   # emulators upscale crisp at half/quarter steps
        Steam       = 'Medium'   # balanced for most AAA titles
        Competitive = 'Low'      # max FPS + lowest input latency for esports
        Android     = 'Medium'   # Android emulators are very GPU-heavy
        Default     = 'Medium'   # any unclassified game
    }

    # Per-game tier override (process name WITHOUT .exe -> tier):
    GameTierOverrides = @{
        # 'pcsx2'          = 'Low'
        # 'cs2'            = 'High'
        # 'VALORANT-Win64' = 'Low'
        # 'dolphin'        = 'Native'
    }

    # Legacy single-value override: this is the fallback only for a
    # profile/game that resolves to no tier (or uses the old setting).
    ResolutionScalePercent = 75      # target width as % of native (25-99)
    PreferIntegerScale     = $true   # use exactly 1/2 native when available:
                                     # pixel-perfect upscale, no blur/pixelation

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

    # ---- Network optimization (applied while the watcher runs) --
    # Reduces in-game latency and packet-loss stalls. Applied once when
    # the watcher starts (BEFORE the game opens its sockets) and reverted
    # to your original values when it stops.
    #   DisableNetworkThrottling : off switches the multimedia network
    #                              throttle that periodically delays packets
    #   TcpLowLatency            : per-interface fast ACK + no Nagle delay
    #                              (auto-adjusts for WiFi vs Ethernet)
    #   DisableNicPowerSaving    : stops Windows powering down the Wi-Fi/
    #                              Ethernet adapter between bursts (micro-
    #                              dropouts that look like packet loss)
    #   ConnectionTypeDetection   : auto-detect WiFi vs LAN for optimal
    #                              TCP settings (prevents packet loss on WiFi)
    NetworkOptimization = @{
        Enabled                  = $true
        DisableNetworkThrottling = $true
        TcpLowLatency            = $true
        DisableNicPowerSaving    = $true
        ConnectionTypeDetection  = $true   # detect WiFi vs LAN and adjust TCP settings
    }

    # ---- Microphone / voice clarity -----------------------------
    # Keeps comms smooth and clear for other players while gaming:
    #   ProtectVoiceApps         : Discord & friends are NEVER deprioritized
    #                              by the background-silencing logic
    #   BoostVoiceAppsDuringGame : voice apps get AboveNormal priority so
    #                              mic capture/encode never starve on weak CPUs
    #   MmcssAudioPriority       : raises MMCSS Audio/Pro Audio/Capture classes
    #   ExtraProtectedProcessNames: additional voice app process names
    #                              (without .exe), e.g. @('MyChatApp')
    VoiceClarity = @{
        ProtectVoiceApps           = $true
        BoostVoiceAppsDuringGame   = $true
        MmcssAudioPriority         = $true
        ExtraProtectedProcessNames = @()
    }

    # ---- Microphone noise suppression & echo cancellation --------
    # Turns the OS microphone into a clean, party-ready source while you
    # game. On Windows 10 1809+/11 the suite drives the platform DSP (Deep
    # Noise Suppression + classic Noise Suppression + Acoustic Echo
    # Cancellation), and where Windows lacks Deep NS (Windows 10) it also
    # layers in an embedded real-time spectral suppressor, so distant
    # background speech (a call to prayer, people talking nearby, room/street
    # noise), fans, traffic and the game's own audio leaking into your mic
    # are removed regardless of volume - only your voice reaches the party.
    #   Enabled          : master switch (auto-engages while a game runs)
    #   ElevateMicBoost  : also raise the mic thread scheduling priority
    #   ExternalEngine   : optional path to your own noise-suppression host
    #                      (e.g. an RNNoise filter app / EqualizerAPO session).
    #                      Leave '' to use the built-in Windows DSP.
    NoiseSuppression = @{
        Enabled         = $true
        ElevateMicBoost = $true
        ExternalEngine  = ''     # e.g. 'C:\Tools\mynoise.exe'
        ExternalArgs    = ''
    }
}
