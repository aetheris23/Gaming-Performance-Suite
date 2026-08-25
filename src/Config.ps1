# ============================================================
#  Config.ps1 - user-tunable settings
#  Edit values here; no other file needs changing.
# ============================================================

@{
    # ---- Game watcher ---------------------------------------
    # Process names (WITHOUT .exe) to auto-boost when detected.
    GameProcesses = @(
        'VALORANT-Win64'            # Valorant
        'pcsx2'                     # PS2 emulator (PCSX2)
        'pcsx2-qt'                  # PCSX2 Qt build
        'AetherSX2'                 # ARM PS2 emulator (if run via PC frontends)
        'RetroArch'                 # multi-system emulator
        'dolphin'                   # GameCube/Wii emulator
        'cemu'                      # Wii-U emulator
        'yuzu', 'suyu', 'ryujinx'   # Switch emulators
        'steam', 'steamservice'     # Steam client (gets normal priority, see below)
        'hl2', 'cs2', 'dota2'       # common Source/Steam titles
        'GTA5', 'RDR2'              # Rockstar titles
        'FortniteClient-Win64Shipping'
        'Minecraft.Windows', 'javaw'# Minecraft (store + java)
    )

    WatcherPollSeconds     = 10      # scan cadence while a game is running
    IdlePollSeconds        = 25      # slower cadence while NO game runs (lighter idle load)

    # ---- Standby memory (stutter-safe policy) -----------------
    # A standby-list purge stalls the whole memory manager, so it is
    # never repeated mid-gameplay on a timer. It runs once when a game
    # is detected (the loading screen absorbs the cost) and during play
    # only below the critical floor, at most once per cooldown.
    PurgeOnGameLaunch           = $true   # one purge right when a game is detected
    CriticalRamFloorMB          = 768     # mid-game purge ONLY below this free-RAM floor
    StandbyPurgeCooldownSeconds = 900     # minimum seconds between two purges
    FreeRamThresholdMB          = 2048    # deprecated (kept for compatibility)

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
    #   DisableNicPowerSaving    : stops Windows powering down the Wi-Fi/
    #                              Ethernet adapter between bursts (micro-
    #                              dropouts that look like packet loss)
    NetworkOptimization = @{
        Enabled                  = $true
        DisableNetworkThrottling = $true
        TcpLowLatency            = $true
        DisableNicPowerSaving    = $true
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
}
