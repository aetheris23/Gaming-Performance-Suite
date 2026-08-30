# Gaming Performance Suite v2.5

Zero-install performance toolkit for gaming across **Windows, Linux, and macOS**
(PowerShell 5.1+ / PowerShell Core 7+), with foundational Android support via
Termux. Stabilizes FPS, cuts GPU load dynamically, identifies every GPU in your
system, tunes your network for lower latency (with WiFi vs LAN awareness to
prevent packet loss), keeps your microphone clear and noise-free, adapts to
older hardware, and eliminates launch stutter.

## What's new in v2.5

- **Microphone noise suppression + echo cancellation (Windows 11).** The suite
  now drives the OS capture-stream DSP - Deep Noise Suppression + classic Noise
  Suppression + Acoustic Echo Cancellation - so distant background speech (a call
  to prayer, people talking nearby, room/street noise) and the game's own audio
  leaking into your mic are removed automatically while you game. It engages when
  a game starts and is released the moment the last game closes.
- **Watcher auto-stops on game close.** The background watcher now exits
  completely when your game session ends instead of idling resident in memory, so
  there is no lingering overhead, priority/timer/network/color state is fully
  restored, and nothing keeps polling for another game.
- **Removed recording / OBS support entirely.** The obsolete recording-software
  detection, config, menu entries and dependencies have been stripped out - fully
  focused on frame time over the capture stack.

## What's new in v2.4

- **Fixed false "Watcher is not running" reports.** The background-watcher
  liveness probe now checks the live instance signal correctly on every
  platform (named mutex on Windows, exclusive file lock + strict PID/command-line
  validation on Linux/macOS), and a crash-recovery no longer deletes the new
  watcher's PID file while it is running.
- **Fixed a startup error that crashed the watcher on Linux/macOS.** Named
  `EventWaitHandle` sync objects are Windows-only; non-Windows now uses a
  journaled stop marker + polling instead, so watcher start/stop work on all
  platforms without exceptions.
- **Real network tuning on Linux/macOS** (journaled `sysctl` changes + WiFi
  power-save off on Linux) instead of only Windows registry tweaks - fixes
  wireless packet loss outside Windows too.
- **Lower idle resource use:** one native process snapshot per poll serves the
  whole game lookup (no repeated `Get-Process` scans), plus cross-process
  watchdog coordination that clears hardware even after kills.
- Graceful no-op display scaling everywhere (Linux `xrandr` / macOS
  `displayplacer` / none elsewhere) - resolution switching can never throw.
- **Per-game resolution tiers (Low / Medium / High / Native).** Instead of one
  global percentage, the watcher now assigns a quality tier per game profile -
  Steam, Riot/esports, PS2/console emulators and Android emulators each get a
  resolution that suits them, tunable via `ResolutionTiers`, `ProfileTiers` and
  per-game `GameTierOverrides` in `src/Config.ps1`.
- **Tier-correct display scaling.** `Select-ScaledMode` now picks the actual
  mode closest to the requested tier instead of always snapping to *exactly
  half* resolution (e.g. 1280&times;720 no longer jumps straight to 640&times;360
  for a Medium game - it lands on ~960&times;540). Integer-ratio modes are still
  preferred for a crisp upscale, so low-spec PCs get a real, blur-free FPS gain
  without over-shrinking.
- **Automatic color correction (FPS enemy clarity).** New display-level filter
  that boosts contrast/RGB/gamma in real time for easier spotting: option **9**
  applies it now, option **0** removes it, and the watcher can auto-apply it
  (and remove it) around a game session. Presets (Off/Vibrant/FPS/Max) and
  per-profile gating are in `src/Config.ps1` under `ColorCorrection`. Uses the
  GPU display gamma ramp on Windows (`SetDeviceGammaRamp`), `xrandr --gamma` on
  Linux, and is a graceful no-op elsewhere.
- **Non-elevated graceful degradation.** On Linux/macOS the menu and watcher no
  longer abort when run without `sudo`. A standard-user session warns once and
  still applies everything that works without root (display scaling, color
  correction, game detection), skipping only priority/power/network writes.
- **Fixed a watcher crash on the idle heartbeat.** A `[datetime]::MinValue`
  sentinel made the first idle-heartbeat math overflow `Int32` (~6.4e13 ms)
  and throw, silently killing a watcher that had been left running with no game
  open; the heartbeat is now overflow-safe.

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
> Windows launchers (`Start-GamingSuite.bat`, `Start-Watcher-Hidden.bat`,
> `Stop-GamingSuite.bat`), the Linux/macOS launchers (`Start-GamingSuite.sh`,
> `Start-Watcher-Hidden.sh`), the `src/` suite, `README.md` and `.gitignore`. The
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
   Produces `GamingPerformanceSuite.zip` (includes a Linux `Start-GamingSuite.sh`
   launcher), or just run the suite straight from the source folder (steps 3-4).
3. **Install**
   ```bash
   unzip GamingPerformanceSuite.zip -d ~/gaming-suite
   cd ~/gaming-suite
   ```
   or keep running from the cloned source folder.
4. **Run**
   ```bash
   # interactive menu (elevates to root via sudo for full capabilities)
   ./Start-GamingSuite.sh

   # background watcher (runs until the game session ends, then exits)
   ./Start-Watcher-Hidden.sh
   ```
   Equivalent manual commands:
   ```bash
   pwsh -NoProfile -File src/Main.ps1
   pwsh -NoProfile -File src/Main.ps1 -BackgroundWatch
   ```
   Elevate with `sudo` for full capabilities (process priority boosting, network
   tuning). Display scaling uses `xrandr` when available; otherwise scaling is a
   safe no-op. Stop the background watcher with menu option 5, or
   `pwsh -NoProfile -Command "Import-Module ./src/Common.psm1 -Force; Stop-BackgroundWatcher"`.

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
   ./Start-GamingSuite.sh                         # interactive menu
   ./Start-Watcher-Hidden.sh                      # background watcher
   ```
   Equivalent manual commands are `pwsh -NoProfile -File src/Main.ps1` and
   `pwsh -NoProfile -File src/Main.ps1 -BackgroundWatch`. Elevate with `sudo` for
   full capabilities. Display scaling uses `displayplacer` when installed (safe
   no-op otherwise); stop the watcher with menu option 5 or
   `Stop-BackgroundWatcher`.

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
| **~12 s later** | Display switches to the game's resolution tier (Low / Medium / High / Native) -> GPU load drops hard |

Heavy steps are **staged with optimized timing** to eliminate the stutter/frame-drop
burst that used to hit when launching games. The pre-game optimization ensures network
tweaks are in place BEFORE the game opens its sockets.

> **Resolution tiers (auto per game):** instead of one global percentage, every
> detected game is assigned a quality tier based on its **profile**, so the right
> resolution is picked for Steam, Riot/esports, PS2/console emulators (PCSX2,
> PPSSPP, Dolphin, RetroArch, DuckStation...), Android emulators (Bluestacks, LDPlayer,
> NOX, MuMu...), and anything else:

| Tier | Target width | Typical use |
|---|---|---|
| **Low** | 55% of native | Competitive/esports (max FPS, lowest input latency) |
| **Medium** | 75% of native | Balanced default for Steam & emulators |
| **High** | 88% of native | Nearly-native sharpness, still a solid gain |
| **Native** | 100% (no switch) | When you want zero display changes |

Supported games run at 480p, 720p, 900p, 1080p etc. - `Select-ScaledMode`
picks the closest **same-aspect-ratio** mode to the tier's target, preferring
exact 1/2 integer scaling when available (crisp, never stretched or blurry).
You can adjust every tier, every profile default, and even add per-game
overrides in `src/Config.ps1` (`ResolutionTiers`, `ProfileTiers`,
`GameTierOverrides`).

> **Session-scoped:** the moment the last monitored game closes, the watcher undoes
> every change (native resolution, priorities, timer, network) and exits completely.
> It is a single-session optimizer, not a resident service - it will not keep polling
> on a low-spec machine waiting to detect a "next game". To play again later, just
> start it again. (For the old always-on behavior set `ExitWhenGameSessionEnds = $false`
> in `src/Config.ps1`.)

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

### Network tuning on Linux / macOS

v2.4 applies the same journaled, exactly-reverted tuning on non-Windows hosts:

| Platform | Tuning |
|---|---|
| **Linux** | `net.core.rmem_max` / `wmem_max`, `net.core.netdev_max_backlog`, `net.ipv4.tcp_fastopen`, `net.ipv4.tcp_low_latency`, plus **WiFi power-save off** (`iw dev ... set power_save off`) - the biggest wireless packet-loss fix |
| **macOS** | `net.inet.tcp.delayed_ack=0`, `net.inet.tcp.rfc1323=1` |

Every value is read *before* it is written, stored in the recovery journal, and
restored exactly when the watcher stops. Writes need root (`sudo`); a key that is
missing or unwritable is logged as a warning and skipped - it never stops the watcher.

## Microphone noise suppression & echo cancellation

Turns your mic into a clean, party-ready source while you game. The suite drives
the **Windows 11 native audio DSP** on your capture device so distant background
speech and game echo never reach the party:

- **Distant background speech removed** (a call to prayer, people talking nearby,
  room/street noise) regardless of how loud it is - only your voice gets through.
- **Echo/kill**: the game's own audio leaking into your mic is cancelled, so the
  party doesn't hear their own voices echo back.
- **Deep Noise Suppression** + classic **Noise Suppression** + **Acoustic Echo
  Cancellation** are engaged at the OS level (native DSP, no downloads).

The DSP engages **automatically while a game runs** (per-game-session) and is
released the moment the last game closes - it never lingers on the desktop and the
host process exits completely.

> **Windows only.** Deep echo/NS requires Windows 11 (effect GUIDs are present on
> Windows 11 22H2+). On other platforms this feature is skipped gracefully and the
> existing MMCSS mic-priority tweak (`Set-MicClarityTweaks`) still applies.

Configured in `src/Config.ps1`:

```powershell
NoiseSuppression = @{
    Enabled         = $true      # auto-engages while a game runs
    ElevateMicBoost = $true      # also raise the mic thread scheduling priority
    ExternalEngine  = ''         # optional path to your own NS host (RNNoise / APO)
    ExternalArgs    = ''
}
```

If you already use an external noise-suppression host (an RNNoise filter app,
EqualizerAPO session, etc.), set `ExternalEngine` to its path - the suite will
launch it during a session and stop it when the session ends, instead of using the
built-in Windows DSP. Leave it empty to use the built-in effect.

**Menu:** Option **6** engages mic noise suppression (plus network + MMCSS tweaks)
right now; option **7** reverts. During a game session the watcher handles engage/
release automatically.

## Cross-platform support

| Platform | Support Level | Features |
|---|---|---|
| **Windows** | Full | All features: display scaling, GPU detection, network tuning, priority boosting, memory management |
| **Linux** | Good | Process priority, sysctl network tuning (+ WiFi power-save off), game detection, memory purge. Display scaling via xrandr (when available) |
| **macOS** | Good | Process priority, sysctl network tuning, game detection, memory purge. Display scaling via displayplacer (when available) |
| **Android** | Basic | Game detection, network optimization (root). Priority boosting requires root access |

The suite auto-detects the platform via PowerShell Core's `$IsWindows`/`$IsLinux`/`$IsMacOS`
variables and adapts behavior accordingly. Windows-specific features (Registry, DXGI, etc.)
are gracefully skipped on other platforms.

## Low-spec / legacy PC support

For older or low-spec hardware (e.g. **Intel i3 7th Gen, 8-16GB RAM, Intel HD/UHD Graphics**).

> **New: low-spec mode is AUTO-DETECTED by default.** At startup the suite
> checks your actual hardware - legacy iGPU/dGPU, low CPU core/thread count
> and low CPU clock - and **enables low-spec mode automatically** on weak
> machines (like an i3-7020U 2-core/4-thread + HD Graphics 620 + 16GB
> laptop). No `Config.ps1` edit is needed; it also stays **light on strong
> machines** because the reduced polling/throttled scans only tighten the
> suite's own footprint further.

Configure with `Mode` in `src/Config.ps1`:

```powershell
LowSpecMode = @{
    Mode                  = 'Auto'   # 'Auto' auto-detect | 'On' force | 'Off' force off
    Enabled               = $null    # manual override ($null = follow Mode; $true/$false force)
    SkipResolutionSwitch  = $false   # Keep display scaling (helps FPS on weak GPUs)
    SkipStandbyPurge      = $false   # Keep memory purging (helps with 8-16GB)
    SkipBackgroundSilence = $false   # Keep background silencing
    SkipFrameGenBridge    = $true    # Skip frame-gen (no compatible GPU)
    ReducedPolling        = $true    # Use 15s/35s intervals (less CPU overhead)
    SkipHags              = $true    # Skip HAGS (unsupported on Intel HD)
    AggressiveTimer       = $false   # Use 2ms timer (1ms causes too many interrupts)
}
```

What low-spec mode does:
- **Auto-detection**: weak CPU (≤4 threads or low clock) + legacy GPU → enabled
  for you automatically; strong machines stay at full strength
- **Polling intervals**: 15s gaming / 35s idle (vs 10s/25s) - less CPU overhead
- **BelowNormal watcher priority**: yields to everything else on the system
- **No HAGS**: Hardware-Accelerated GPU Scheduling is unsupported on pre-Xe Intel
- **Gentler standby purges**: only when RAM critically low, with cooldown gates
- **Throttled exit checks**: process exit scans every other cycle during gaming

## Color correction - FPS enemy clarity

An in-place display filter that boosts contrast/RGB/gamma so enemies and
crosshairs stand out in bright or washed-out scenes.

- **Option 9** in the menu applies it immediately; **option 0** removes it and
  restores the original color.
- The **watcher** can also auto-apply it the moment a matching game launches
  and remove it again when the session ends (no permanent change).
- It is implemented as a live GPU display ramp/filter, so it does **not**
  require capture/overlay injection and works while playing:
  - **Windows** - `SetDeviceGammaRamp` / `GetDeviceGammaRamp` (GDI32); the
    original ramp is captured and cleanly restored.
  - **Linux** - `xrandr --gamma` (per-output RGB gamma), also restored on exit.
  - **macOS / other** - logged as unsupported and skipped gracefully.

Configure in `src/Config.ps1` under `ColorCorrection`:

```powershell
ColorCorrection = @{
    Enabled     = $true      # $false = feature off (never auto-applied)
    Mode        = 'Auto'     # Auto | Off | Vibrant | FPS | Max | Red | Tritanopia | Protanopia | Deuteranopia
    OnlyProfiles= @('Competitive', 'Default')   # game profiles that trigger it
}
```

> **New in this build: `Auto` mode.** Instead of relying on one hand-picked
> color, `Auto` derives the **strongest, most balanced** contrast/RGB preset
> from the running game's profile every launch - so enemies stay clearly
> visible **no matter which color is configured** (Red, Purple/Tritanopia,
> Yellow/Protanopia or Yellow/Deuteranopia). Competitive/esports titles get
> the most aggressive separation curve; emulators and AAA titles get a
> strong-but-faithful boost. Pick `Auto` and visibility is handled for you.

The preset table (`Get-ColorPreset`) tunes
red/green/blue gain, gamma and contrast per mode; `Max` is the strongest
for dark competitive games. The color-blind presets mimic classic FPS
filters: `Red` (strong red boost), `Tritanopia` (purple tint),
`Protanopia` (yellow tint) and `Deuteranopia` (yellow/warm tint) - pick
whichever makes enemy outlines pop clearest for you in Valorant and
switch it any time (menu option 9 re-applies instantly).

## GPU detection - integrated AND discrete

`src/GpuDetect.psm1` builds a full graphics-adapter inventory at startup and
tags every chip as **Integrated** or **Discrete** (virtual/software adapters
are flagged too):

| Vendor | Integrated | Discrete |
|---|---|---|
| Intel | HD Graphics 620, UHD/Iris, "Arc Graphics" iGPU | Arc A380/A750/B580, Iris Xe MAX |
| AMD | Radeon(TM) Graphics, Vega 8, 680M/780M/890M | RX 460->RX 9070, R5-R9, Fury/VII |
| NVIDIA | *(no consumer iGPUs)* | GeForce GTX/RTX all series, Quadro, TITAN |

Older / integrated chips are additionally flagged as **legacy** (pre-Pascal
GeForce, pre-RX Radeon, Intel HD 620 and earlier, all GMA chips) so the suite
relaxes aggressive tweaks that can misbehave on that hardware.

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
v2.2 introduced pre-game optimization; v2.4 re-checks that no deferred step can
ever stall a game's launch loop:

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

## Adaptive mid-game tuning - no FPS drops on skill effects or large maps

This build adds an in-game adaptation layer that keeps FPS smooth during the
exact moments that used to cause drops - **skill/effect bursts** (particle
storms, ability spam) and **maps of every scale** (small arenas to huge open
worlds), which spike memory and CPU load.

- **RAM-relative pressure floor.** Instead of one fixed value, the watcher
  treats a percentage of your **total** RAM as the "under pressure" threshold
  (default 10%), so it scales correctly whether you have 8 GB or 64 GB and
  whether the current map is tiny or enormous. When free RAM drops under the
  floor, a cooldown-gated standby purge reclaims memory without ever stalling
  a frame in the middle of a render.
- **Tightening cooldown under stress.** While memory pressure *persists* (a
  long skill fight or a huge map still loading), the purge cooldown shortens
  automatically (down to half) so recurring bursts are caught sooner - and it
  relaxes back to normal the moment memory is healthy, so it never over-purges.
- **Priority re-assertion.** Skill effects and big map loads can let the OS or
  a background hog steal CPU from the game. The watcher periodically re-applies
  the game's priority/affinity during play (cheap, throttled) so heavy moments
  don't translate into hitches.
- These sit **on top** of the existing per-game resolution tiers, so the GPU
  load is already low before adaptive tuning kicks in.

Configure in `src/Config.ps1` under `AdaptiveTuning`:

```powershell
AdaptiveTuning = @{
    Enabled              = $true
    AdaptivePurgeFloor   = 10      # % of total RAM treated as "under pressure"
    PressureCooldownSec  = 60      # min seconds between adaptive purges
    ReassertPriorities   = $true   # periodically re-apply game priority/affinity
    ReassertEveryCycles  = 3       # re-check every N poll cycles during play
}
```

Standby purges remain session-safe: still never repeated mid-frame on a timer,
still gated by a cooldown, and any change is journaled so an unclean stop is
fully restored.

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
Start-GamingSuite.sh          (generated by build) interactive menu (Linux/macOS)
Start-Watcher-Hidden.sh       (generated by build) background watcher (Linux/macOS)
src/
  Main.ps1                    menu + hidden background mode (-BackgroundWatch)
  Config.ps1                  game list, thresholds, scale %, low-spec mode,
                              network tuning, voice clarity, color correction
  Common.psm1                 logging, privileges, cross-platform detection,
                              stop-signal / single-instance + recovery journal
  GameBoost.psm1              FPS stability engine + watcher loop (stutter-free,
                              low-spec optimized)
  DisplayScale.psm1           dynamic display-mode switching + native restore
                              (user32 / xrandr / displayplacer; no-op elsewhere)
  GpuDetect.psm1              GPU inventory: iGPUs AND dGPUs, legacy detection
                              (DXGI / sysfs+lspci / system_profiler)
  NetTune.psm1                network latency (WiFi/LAN aware) + mic/MMCSS clarity
                              (registry on Windows, sysctl on Linux/macOS)
  ColorCorrect.psm1           automatic display filter: contrast/RGB/gamma
                              (SetDeviceGammaRamp on Windows, xrandr --gamma
                              on Linux, no-op elsewhere) for FPS enemy clarity
  VoiceDSP.psm1               microphone noise suppression + echo cancellation
                              (Windows 11 native DSP engine + external engine)
  VoiceDSP-Host.ps1           hidden capture-stream host that holds/engages the
                              mic DSP effects during a game session
  Build-Suite.ps1             generates .bat/.sh launchers + repacks ZIP
logs/
  runtime/watcher.pid         background watcher PID (removed on clean stop)
  runtime/watcher_state.json  crash-recovery journal (removed on clean stop)
  runtime/stop.requested      stop signal (non-Windows only, removed on clean stop)
  runtime/instance.lock       single-instance guard (non-Windows)
  suite_YYYYMMDD.log          timestamped operation log
```

> The ZIP only ships the runtime layout (the five launchers + `src/` +
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
- Mic noise suppression/echo cancellation uses the Windows 11 native DSP - still
  no installs, no downloads, and it only engages while a game runs.
- Network/voice tweaks are journaled and reverted exactly on stop.
- If an action fails, check `logs/` - most failures mean the script wasn't elevated
  (Windows: run as Administrator; Linux/macOS: run with `sudo`).
