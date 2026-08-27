# Gaming Performance Suite v2.3

Zero-install performance toolkit for gaming across **Windows, Linux, and macOS**
(PowerShell 5.1+ / PowerShell Core 7+), with foundational Android support via
Termux. Stabilizes FPS, cuts GPU load dynamically, identifies every GPU in your
system, tunes your network for lower latency (with WiFi vs LAN awareness to
prevent packet loss), keeps your microphone clear, adapts to older hardware,
eliminates launch stutter, and **works smoothly alongside OBS/capture software**.

## Installation & usage

Every platform follows the same four steps: **download** the source, **run the
build** to generate `GamingPerformanceSuite.zip`, **install** it, and **run** it.

| Step | Windows | Linux | macOS | Android (Termux) |
|---|---|---|---|---|
| **1. Download** | `git clone` or download the repo ZIP | `git clone` or download the repo ZIP | `git clone` or download the repo ZIP | `git clone` or copy onto the device |
| **2. Build** | double-click `build.bat`, or `powershell -File src\Build-Suite.ps1` | `pwsh -File src/Build-Suite.ps1` | `pwsh -File src/Build-Suite.ps1` | `pwsh -File src/Build-Suite.ps1` (optional) |
| **3. Install** | extract `GamingPerformanceSuite.zip` anywhere | extract the ZIP, or run from the source folder | extract the ZIP, or run from the source folder | run from the source folder |
| **4. Run** | `Start-Watcher-Hidden.bat` / `Start-GamingSuite.bat` / `Stop-GamingSuite.bat` | `pwsh -File src/Main.ps1` | `pwsh -File src/Main.ps1` | `pwsh -File src/Main.ps1` |

> **What the build produces:** the ZIP is a **runtime-only** package. It ships the
> three Windows launchers (`Start-GamingSuite.bat`, `Start-Watcher-Hidden.bat`,
> `Stop-GamingSuite.bat`), the `src/` suite, `README.md` and `.gitignore`. The
> build tooling (`build.bat` / `src/Build-Suite.ps1`) is deliberately **excluded**,
> so extracting the ZIP can never duplicate or overwrite the builder. Rebuild only
> from the source repository (step 2 of each platform below).

### Windows (full support)

Prerequisite: Windows 10/11 with built-in PowerShell 5.1+ - nothing to install.

1. **Download** - `git clone <repository-url>`, or download the repository as a
   ZIP and extract it.
2. **Build** - generate `GamingPerformanceSuite.zip` once:
   - double-click **`build.bat`**, or
   - run `powershell -NoProfile -ExecutionPolicy Bypass -File src\Build-Suite.ps1`
3. **Install** - extract the ZIP anywhere - `D:\`, a USB stick, or your home
   folder. Copyable to any PC; nothing is registered system-wide.
4. **Run**
   - **Background watcher (recommended):** double-click **`Start-Watcher-Hidden.bat`**
     and accept the UAC prompt. Play your game normally - the watcher detects it,
     boosts it and drops the render resolution, then restores everything and shuts
     itself down when you close the game. Use **`Stop-GamingSuite.bat`** to stop it
     at any time.
   - **Interactive menu:** double-click **`Start-GamingSuite.bat`** for one-click
     optimization, starting/stopping the watcher, network & mic tuning, and status.
   - **Stop:** double-click **`Stop-GamingSuite.bat`** - restores native
     resolution, priorities, timer and network settings.

### Linux

Prerequisite: PowerShell Core 7+ (`pwsh`) and an unzip tool.

```bash
# Ubuntu / Debian
sudo apt install powershell unzip
# Fedora
sudo dnf install powershell unzip
# Snap
sudo snap install powershell --classic
```

1. **Download**
   ```bash
   git clone <repository-url>
   cd <repository-folder>
   ```
2. **Build**
   ```bash
   pwsh -NoProfile -ExecutionPolicy Bypass -File src/Build-Suite.ps1
   ```
   Produces `GamingPerformanceSuite.zip`. The launchers inside are Windows `.bat`
   files, so Linux users normally just run the suite straight from the source
   folder instead (steps 3-4).
3. **Install**
   ```bash
   unzip GamingPerformanceSuite.zip -d ~/gaming-suite
   cd ~/gaming-suite
   ```
   or keep running from the cloned source folder.
4. **Run**
   ```bash
   # interactive menu
   pwsh -NoProfile -File src/Main.ps1

   # background watcher (runs until the game session ends, then exits)
   pwsh -NoProfile -File src/Main.ps1 -BackgroundWatch
   ```
   Elevate with `sudo` for full capabilities (process priority boosting, network
   tuning). Display scaling uses `xrandr` when available. The clickable `.bat`
   launch/stop channels are Windows-specific; on Linux, stop the watcher with
   Ctrl+C in its own terminal, or open the menu and choose "STOP background
   watcher".

### macOS

Prerequisite: PowerShell Core 7+ (`pwsh`) via Homebrew; `displayplacer` enables
display scaling.

```bash
brew install --cask powershell
brew install displayplacer       # optional: display scaling support
```

1. **Download**
   ```bash
   git clone <repository-url>
   cd <repository-folder>
   ```
2. **Build**
   ```bash
   pwsh -NoProfile -ExecutionPolicy Bypass -File src/Build-Suite.ps1
   ```
3. **Install**
   ```bash
   unzip GamingPerformanceSuite.zip -d ~/gaming-suite
   cd ~/gaming-suite
   ```
   or run from the cloned source folder.
4. **Run**
   ```bash
   pwsh -NoProfile -File src/Main.ps1                        # interactive menu
   pwsh -NoProfile -File src/Main.ps1 -BackgroundWatch       # background watcher
   ```
   Elevate with `sudo` for full capabilities. The `.bat` launchers are
   Windows-specific; use the menu or Ctrl+C to stop the watcher.

### Android (Termux)

Prerequisite: **Termux** from F-Droid (not the Play Store) and PowerShell.

```bash
pkg install git
pkg install powershell
```

1. **Download** - `git clone <repository-url>`, or copy the suite folder onto the
   device.
2. **Build** - *optional*: `pwsh -NoProfile -ExecutionPolicy Bypass -File src/Build-Suite.ps1`
   produces the Windows-targeted ZIP. Android users normally skip this step and
   run directly from the source folder.
3. **Install** - there is no system install; run from the downloaded/cloned folder.
4. **Run**
   ```bash
   pwsh -NoProfile -File src/Main.ps1
   ```

> **Note:** Android support is limited. Game detection and network optimization
> work without root; process priority boosting and display scaling require root.

## What happens when you start a game

The watcher polls cheaply - every 15 s while a game runs (low-spec default),
every 35 s while idle (both tunable in `src/Config.ps1`). On detection of a
known game process it:

| When | Action |
|---|---|
| **Before launch** | Pre-game optimizations: power plan, network tweaks, multimedia scheduling applied BEFORE the game process appears (eliminates launch stutter) |
| **Instantly** | Classifies the title (Emulator / Steam / Competitive / Android / Default); priority boosted; steered off core 0; frame pacing timer engaged |
| **~0.5 s** | Standby-memory purge (BEFORE game fully loads - eliminates launch stutter) |
| **~1 s later** | Legacy FSO flag + optional frame-generation companion app |
| **~8 s later** | Secondary standby purge during loading screen |
| **~12 s later** | Display switches to a lower same-aspect resolution -> GPU load drops hard |

Heavy steps are **staged with optimized timing** to eliminate the stutter/frame-drop
burst that used to hit when launching games. The pre-game optimization ensures network
tweaks are in place BEFORE the game opens its sockets.

> **Session-scoped:** the moment the last monitored game closes, the watcher undoes
> every change (native resolution, priorities, timer, network) and exits completely.
> It is a single-session optimizer, not a resident service - it will not keep polling
> on a low-spec machine waiting to detect a "next game". To play again later, just
> start it again. (For the old always-on behavior set `ExitWhenGameSessionEnds = $false`
> in `src/Config.ps1`.)

> **Recording software detected?** When OBS, Streamlabs, or another capture tool
> is running, the suite automatically takes **capture-safe paths**: display resolution
> switches and standby purges are deferred to prevent black frames or hitches in
> your recording. Game priority/CPU/network boosts still apply normally.

## Network optimization - WiFi and LAN aware

The suite now **auto-detects your connection type** and adjusts TCP settings
to prevent packet loss on wireless links:

| Tweak | Ethernet (LAN) | WiFi |
|---|---|---|
| `NetworkThrottlingIndex = 0xFFFFFFFF` | Disabled | Disabled |
| `TcpAckFrequency` | **1** (minimum latency) | **2** (prevents ACK-flood packet loss) |
| `TCPNoDelay` | 1 (Nagle off) | 1 (Nagle off) |
| `TcpDelAckTicks` | **0** (immediate ACKs) | **100** (batches ACKs to reduce overhead) |
| `GlobalMaxTcpWindowSize` | 65535 | 65535 |
| NIC power-saving off | Yes | Yes (more aggressive) |

Connection detection uses `netsh wlan`, `Get-NetAdapter`, and `Win32_NetworkAdapter`
(fallback chain). WiFi mode uses `TcpAckFrequency=2` instead of `1` to avoid flooding
the wireless NIC with tiny ACKs that cause packet loss. All changes are journaled and
reverted exactly on stop.

### Additional network fixes

- **QoS packet scheduler**: removes best-effort limit so game traffic gets priority
- **TCP delayed ACK tuning**: WiFi gets 100ms delayed ACK batching to reduce overhead
- **Per-adapter power management**: prevents deep sleep states that cause reconnection drops

## Cross-platform support

| Platform | Support Level | Features |
|---|---|---|
| **Windows** | Full | All features: display scaling, GPU detection, network tuning, priority boosting, memory management |
| **Linux** | Good | Process priority, network tuning, game detection. Display scaling via xrandr (when available) |
| **macOS** | Good | Process priority, network tuning, game detection. Display scaling via displayplacer (when available) |
| **Android** | Basic | Game detection, network optimization (root). Priority boosting requires root access |

The suite auto-detects the platform via PowerShell Core's `$IsWindows`/`$IsLinux`/`$IsMacOS`
variables and adapts behavior accordingly. Windows-specific features (Registry, DXGI, etc.)
are gracefully skipped on other platforms.

## Low-spec / legacy PC support

For older or low-spec hardware (e.g. **Intel i3 7th Gen, 8-16GB RAM, Intel HD/UHD Graphics**).

Low-spec mode is **enabled by default** in v2.3 for minimal resource usage.
If you have a high-end PC, set `Enabled = $false` in `src/Config.ps1`:

```powershell
LowSpecMode = @{
    Enabled = $true        # Master switch (ON by default in v2.3)
    SkipResolutionSwitch = $false  # Keep display scaling (helps FPS on weak GPUs)
    SkipStandbyPurge = $false      # Keep memory purging (helps with 8-16GB)
    SkipBackgroundSilence = $false # Keep background silencing
    SkipFrameGenBridge = $true     # Skip frame-gen (no compatible GPU)
    ReducedPolling = $true         # Use 15s/35s intervals (less CPU overhead)
    SkipHags = $true               # Skip HAGS (unsupported on Intel HD)
    AggressiveTimer = $false       # Use 2ms timer (1ms causes too many interrupts)
}
```

What low-spec mode does:
- **Polling intervals**: 15s gaming / 35s idle (vs 10s/25s) - less CPU overhead
- **Lazy native interop**: C# types compile on first use, not at module import
- **BelowNormal watcher priority**: yields to everything else on the system
- **No HAGS**: Hardware-Accelerated GPU Scheduling is unsupported on pre-Xe Intel
- **Gentler standby purges**: only when RAM critically low, with cooldown gates
- **Throttled exit checks**: process exit scans every other cycle during gaming

## Recording software support (OBS, Streamlabs, etc.)

The suite **auto-detects** when capture/recording software is running alongside a
game and automatically takes **capture-safe paths** to prevent frame drops, black
frames, or hitches in your recording:

| When recorder is active | Behavior |
|---|---|
| Display resolution switch | **Deferred** - prevents black-frame flashes in the recording |
| Standby memory purge | **Deferred** - prevents visible hitch mid-recording |
| Game priority boost | **Still applied** - game stays smooth |
| CPU/affinity steering | **Still applied** - game gets clean cores |
| Network optimization | **Still applied** - low latency for streaming |
| Background silencing | **Still applied** - but recorder process is never touched |

### Protected recording processes

These processes are **never deprioritized** by background silencing:

- OBS Studio (`obs64`, `obs32`)
- Streamlabs Desktop
- StreamElements OBS Live
- Twitch Studio
- x264 / NVENC encoder helpers

Additional processes can be added in `Config.ps1`:

```powershell
RecordingSoftware = @{
    Enabled                 = $true
    SkipResolutionSwitch    = $true   # Prevents black frames in recording
    SkipStandbyPurge        = $true   # Prevents hitch in recording
    ProtectedProcesses      = @(
        'obs64', 'obs32',
        'Streamlabs',
        'MyCustomRecorder'            # Add your own
    )
}
```

> **Tip:** If you record with OBS, leave both `Skip` options at `$true` for the
> smoothest recording. The game still gets all priority/CPU/network boosts - only
> the capture-disruptive operations are deferred.

The legacy GPU auto-detection (`src/GpuDetect.psm1`) identifies hardware like:
- Intel HD Graphics 620 (Kaby Lake iGPU) -> Legacy mode
- Intel UHD 620+ / Iris -> Modern mode
- NVIDIA GeForce GTX 9xx and older -> Legacy mode
- AMD Radeon HD 7xxx-9xxx / R-series -> Legacy mode

## GPU detection - integrated AND discrete

`src/GpuDetect.psm1` builds a full graphics-adapter inventory at startup and
tags every chip as **Integrated** or **Discrete** (virtual/software adapters
are flagged too):

| Vendor | Integrated | Discrete |
|---|---|---|
| Intel | HD Graphics 620, UHD/Iris, "Arc Graphics" iGPU | Arc A380/A750/B580, Iris Xe MAX |
| AMD | Radeon(TM) Graphics, Vega 8, 680M/780M/890M | RX 460->RX 9070, R5-R9, Fury/VII |
| NVIDIA | *(no consumer iGPUs)* | GeForce GTX/RTX all series, Quadro, TITAN |

## Supported games and platforms

The suite detects and optimizes for **100+ game processes** across all major platforms:

### Game sources supported
- **Steam** - all Steam games (auto-detected via `\steamapps\common\` path)
- **Riot Games** - Valorant, League of Legends
- **Epic Games** - Fortnite and others
- **EA** - EA Desktop, Battlefield, Need for Speed
- **Ubisoft** - Ubisoft Connect games
- **Blizzard** - Battle.net, Overwatch, WoW, Diablo
- **Xbox/Microsoft Store** - Game Services, Xbox titles
- **GOG** - Galaxy client games
- **itch.io** - Indie games

### Emulators supported
- **PlayStation**: PCSX2, AetherSX2, DuckStation, Play!
- **Nintendo**: Yuzu, Suyu, Ryujinx, Sudachi, Citron, Dolphin, Cemu
- **Multi-system**: RetroArch, MAME, Mednafen, BizHawk, SNES9x, FCEUX, ePSXe
- **PSP**: PPSSPP
- **Xbox**: xemu, QEMU
- **Arcade**: MAME, MAME64

### Android emulators on PC
- **LDPlayer** - LDPlayer, LDBoxHeadless
- **NoxPlayer** - Nox, NoxHandle, NoxVMHandle
- **BlueStacks** - BlueStacks, HD-Player, BstkVMM
- **MuMu** - MuMuPlayer, MuMuVMMHeadless
- **MEmu** - MEmu, MEmuHeadless

### Game profiles
Each detected game is auto-classified:
| Profile | Priority | Silenced | Examples |
|---|---|---|---|
| **Emulator** | High | none | PCSX2, RetroArch, Dolphin |
| **Steam** | High | steamwebhelper | GTA5, RDR2, Elden Ring |
| **Competitive** | AboveNormal | browsers, Spotify | Valorant, CS2, Dota 2 |
| **Android** | High | none | BlueStacks, LDPlayer |
| **Default** | AboveNormal | none | Unknown games |

Override any classification in `Config.ps1` `ProfileOverrides`.

## Launch stutter elimination

Previous versions caused stutter when launching games because heavy operations
(standby purge, display switch, network tweaks) ran AFTER the game was detected.
v2.2 introduced pre-game optimization; v2.3 adds recording-aware capture-safe paths:

1. **Pre-game phase** (before any game detected):
   - Power plan switched to High Performance
   - Network tweaks applied (TCP settings in place for new connections)
   - MMCSS scheduling raised
   - Game DVR disabled

2. **Pre-launch phase** (0.5s after detection):
   - Standby memory purge (BEFORE game fully loads)
   - Game's loading screen absorbs any brief stall

3. **Staged ramp-up** (during loading):
   - FSO flags at ~1s
   - Secondary purge at ~8s
   - Display switch at ~12s

The result: **zero visible stutter** when launching games, even on weak hardware.

## Background reliability & crash recovery

Every change is mirrored to a recovery journal (`logs/runtime/watcher_state.json`)
at the moment it is made. Unclean shutdowns (kill, crash, power loss) are repaired
automatically on next start or stop.

## File layout

```
build.bat                     one-click rebuild of GamingPerformanceSuite.zip
Start-GamingSuite.bat         (generated by build) interactive menu
Start-Watcher-Hidden.bat      (generated by build) background watcher
Stop-GamingSuite.bat          (generated by build) stops watcher, restores everything
src/
  Main.ps1                    menu + hidden background mode (-BackgroundWatch)
  Config.ps1                  game list, thresholds, scale %, low-spec mode,
                              network tuning, voice clarity, recording detection
  Common.psm1                 logging, privileges, cross-platform detection,
                              stop-event / single-instance + recovery journal
  GameBoost.psm1              FPS stability engine + watcher loop (stutter-free,
                              recording-aware, low-spec optimized)
  DisplayScale.psm1           dynamic display-mode switching + native restore
  GpuDetect.psm1              GPU inventory: iGPUs AND dGPUs, legacy detection
  NetTune.psm1                network latency (WiFi/LAN aware) + mic/MMCSS clarity
  Build-Suite.ps1             generates .bat files + repacks ZIP
logs/
  runtime/watcher.pid         background watcher PID (removed on clean stop)
  runtime/watcher_state.json  crash-recovery journal (removed on clean stop)
  suite_YYYYMMDD.log          timestamped operation log
```

> The ZIP only ships the runtime layout (the three `.bat` launchers + `src/` +
> `README.md` + `.gitignore`). `build.bat` and `src/Build-Suite.ps1` are build
> tooling and live only in the source repository, never inside the ZIP.

## Portable install

The suite is fully portable. Copy the folder (or extracted ZIP) anywhere -
`D:\`, USB stick, home directory - and run. Everything resolves relative to its
own folder; nothing is registered system-wide. Delete the folder and it is
completely gone.

## Notes & safety

- All actions use standard OS APIs/registry values; no installs, no downloads.
- Anti-cheat processes (Vanguard, EAC, BattlEye) are never touched.
- Voice apps (Discord, TeamSpeak, etc.) are never silenced - your mic stays clean.
- Recording software (OBS, Streamlabs, etc.) is never deprioritized or disrupted.
- Capture-safe paths prevent black frames and hitches while recording.
- Network/voice tweaks are journaled and reverted exactly on stop.
- If an action fails, check `logs/` - most failures mean the script wasn't elevated.
