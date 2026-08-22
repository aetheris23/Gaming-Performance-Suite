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

    WatcherPollSeconds     = 10      # how often to scan for game processes
    FreeRamThresholdMB     = 2048    # purge standby RAM below this while gaming

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
    ResolutionScalePercent = 66      # target width as % of native (25-99)
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
}
