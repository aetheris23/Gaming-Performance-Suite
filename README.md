# Gaming Performance Suite v2.5

Zero-install performance toolkit for gaming on **Windows 10/11** (PowerShell 5.1+,
nothing to install). Stabilizes FPS, cuts GPU load dynamically, identifies every GPU in
your system, tunes your network for lower latency (with WiFi vs LAN awareness to
prevent packet loss), keeps your microphone clear and noise-free, adapts to older
hardware, and eliminates launch stutter.

**Windows-only build.** Linux, macOS and Android/Termux support have been removed so
the watcher no longer carries cross-platform code paths (sysfs `/proc` scans,
`xrandr`/`displayplacer` calls, `sysctl`/`iw` tuning, stop-marker polling). Every
scan now stays native to Windows and much lighter on the CPU.

## What's new in v2.5

- **Windows-only, lighter scanning.** All Linux/macOS/Android branches were stripped
  out, and the game-poll matcher was rewritten: the 100+ game names are compiled once
  into a `HashSet` (O(1) lookups), with wildcard `-like` matching reserved for the few
  patterns that actually contain `?`/`*`. A single native process snapshot per poll now
  uses a `List<Process>` instead of a pipeline filter - near-zero watcher CPU while
  idle, and no lag/voice cutouts that accumulate during long sessions on weak CPUs.
- **Microphone noise suppression + echo cancellation (Windows 10 1809+ / 11).**
  The suite drives the OS capture-stream DSP - Deep Noise Suppression + classic Noise
  Suppression + Acoustic Echo Cancellation. The software fallback is now opt-in
  because it has no virtual-microphone sink and sending processed mic audio to the
  default speakers can cause feedback, volume pumping, and voice-chat delay. It
  engages when a game starts and is released the moment the last game closes.
- **Watcher auto-stops on game close.** The background watcher now exits completely
  when your game session ends instead of idling resident in memory, so there is no
  lingering overhead, priority/timer/network state is fully restored, and nothing
  keeps polling for another game.
- **Removed recording / OBS support entirely.** The obsolete recording-software
  detection, config, menu entries and dependencies have been stripped out - fully
  focused on frame time over the capture stack.
- **Competitive enemy-highlight presets.** `src/Config.ps1` now exposes the Valorant
  presets `Red`, `PurpleTritanopia`, `YellowProtanopia`, and `YellowDeuteranopia` for a
  consistent setup. The suite intentionally does not apply a whole-desktop gamma/color
  matrix: that would tint menus and non-game content, add scanout work on low-spec
  hardware, and may conflict with anti-cheat. Select the configured preset in
  Valorant's enemy-highlight setting.
- **Less watcher overhead during hot gameplay.** Standby-memory pressure is now probed
  only when a purge could legally run (cooldown-gated), eliminating useless per-poll
  memory reads; process affinity is only re-applied when it has actually drifted, so no
  redundant scheduler re-balance can hitch a frame mid-render (effect bursts / shooting
  / big maps).
- **Active-game-only watching.** Launchers and generic helper processes are no longer
  watched by default. The watcher selects the game owning the foreground window, with a
  safe process-list fallback when the desktop cannot report one. Add a title's process
  name to `GameProcesses` for additional games.
- **Automatic log cleanup.** Diagnostic `suite_*.log` files are removed when a session
  exits and stale files are cleared at the next startup.

## What's new in v2.4

- **Fixed false "Watcher is not running" reports.** The background-watcher liveness
  probe now checks the live instance signal correctly (named mutex + strict
  PID/name validation), and a crash-recovery no longer deletes the new watcher's PID
  file while it is running.
- **Lower idle resource use:** one native process snapshot per poll serves the whole
  game lookup (no repeated `Get-Process` scans), plus cross-process watchdog
  coordination that clears hardware even after kills.
- **Per-game resolution tiers (Low / Medium / High / Native).** Instead of one global
  percentage, the watcher now assigns a quality tier per game profile - Steam,
  Riot/esports, PS2/console emulators and Android emulators each get a resolution that
  suits them, tunable via `ResolutionTiers`, `ProfileTiers` and per-game
  `GameTierOverrides` in `src/Config.ps1`.
- **Tier-correct display scaling.** `Select-ScaledMode` now picks the actual mode
  closest to the requested tier instead of always snapping to *exactly half* resolution
  (e.g. 1280&times;720 no longer jumps straight to 640&times;360 for a Medium game - it
  lands on ~960&times;540). Integer-ratio modes are still preferred for a crisp
  upscale, so low-spec PCs get a real, blur-free FPS gain without over-shrinking.
- **Fixed a watcher crash on the idle heartbeat.** A `[datetime]::MinValue` sentinel
  made the first idle-heartbeat math overflow `Int32` (~6.4e13 ms) and throw, silently
  killing a watcher that had been left running with no game open; the heartbeat is now
  overflow-safe.

## Installation & usage (Windows)

Prerequisite: Windows 10/11 with built-in PowerShell 5.1+ - nothing to install.

1. **Download** - `git clone <repository-url>`, or download the repository as a ZIP
   and extract it.
2. **Build** - generate `GamingPerformanceSuite.zip` once:
   - double-click **`build.bat`**, or
   - run `powershell -NoProfile -ExecutionPolicy Bypass -File src\Build-Suite.ps1`
3. **Install** - extract the ZIP anywhere - `D:\`, a USB stick, or your home folder.
   Copyable to any PC; nothing is registered system-wide.
4. **Run**
   - **Background watcher (recommended):** double-click **`Start-Watcher-Hidden.bat`**
     and accept the UAC prompt. Play your game normally - the watcher detects it, boosts
     it and drops the render resolution, then restores everything and shuts itself down
     when you close the game. Use **`Stop-GamingSuite.bat`** to stop it at any time.
   - **Interactive menu:** double-click **`Start-GamingSuite.bat`** for one-click
     optimization, starting/stopping the watcher, network & mic tuning, and status.
   - **Stop:** double-click **`Stop-GamingSuite.bat`** - restores native resolution,
     priorities, timer and network settings.

> **What the build produces:** the ZIP is a **runtime-only** package. It ships the
> Windows launchers (`Start-GamingSuite.bat`, `Start-Watcher-Hidden.bat`,
> `Stop-GamingSuite.bat`), the `src/` suite, `README.md` and `.gitignore`. The build
> tooling (`build.bat` / `src/Build-Suite.ps1`) is deliberately **excluded**, so
> extracting the ZIP can never duplicate or overwrite the builder. Rebuild only from
> the source repository (step 2).

### Portable operation and low-resource behavior

The runtime package is drive-letter independent. After extraction or after moving
the folder, the launchers and PowerShell modules resolve the suite root from their
own location rather than from a fixed `C:\` or `D:\` path. This remains true when
the folder is placed on another internal drive, an external drive, or a USB stick.
The suite does not install services, drivers, scheduled tasks, registry startup
entries, or system-wide files; its diagnostic logs and recovery journal stay under
the package's own `logs/` directory.

The optimizer is also designed to stay lightweight on older PCs and laptops:

- Low-spec mode is auto-detected and uses longer polling intervals, a
  `BelowNormal` watcher priority, throttled scans, and gentler optional actions.
- The watcher uses one native process snapshot per poll, avoids repeated WMI work
  in the hot loop, and exits when the monitored game session ends.
- Expensive actions are staged around game launch and guarded by cooldowns so they
  do not continuously consume CPU, memory, or power during gameplay.
- Moving the package between an HDD and SSD does not change runtime behavior or
  require reconfiguration. An SSD can improve startup and log I/O latency, but the
  suite's in-game CPU, memory, and polling footprint is the same.

Peak FPS still depends on the game, drivers, thermals, and available hardware;
portability guarantees the suite can run from the new location, while the
low-spec controls minimize the suite's own overhead.

## What happens when you start a game

The watcher polls cheaply - every 15 s while a game runs (low-spec default), every
35 s while idle (both tunable in `src/Config.ps1`). On detection of a known game
process it:

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
> resolution is picked for Steam, Riot/esports, PS2/console emulators (PCSX2, PPSSPP,
> Dolphin, RetroArch, DuckStation...), Android emulators on PC (Bluestacks, LDPlayer,
> NOX, MuMu...), and anything else:

| Tier | Target width | Typical use |
|---|---|---|
| **Low** | 55% of native | Competitive/esports (max FPS, lowest input latency) |
| **Medium** | 75% of native | Balanced default for Steam & emulators |
| **High** | 88% of native | Nearly-native sharpness, still a solid gain |
| **Native** | 100% (no switch) | When you want zero display changes |

Supported games run at 480p, 720p, 900p, 1080p etc. - `Select-ScaledMode` picks the
closest **same-aspect-ratio** mode to the tier's target, preferring exact 1/2 integer
scaling when available (crisp, never stretched or blurry). With `StretchedResolution`
enabled, a different-aspect lower mode is chosen and scaled to fill the whole panel
via `dmDisplayFixedOutput = DMDFO_STRETCH` - the classic FPS "stretched" look. You can
adjust every tier, every profile default, and even add per-game overrides in
`src/Config.ps1` (`ResolutionTiers`, `ProfileTiers`, `GameTierOverrides`).

> **Session-scoped:** the moment the last monitored game closes, the watcher undoes
> every change (native resolution, priorities, timer, network) and exits completely.
> It is a single-session optimizer, not a resident service - it will not keep polling
> on a low-spec machine waiting to detect a "next game". To play again later, just
> start it again. (For the old always-on behavior set `ExitWhenGameSessionEnds = $false`
> in `src/Config.ps1`.)

## Network optimization - WiFi and LAN aware

The suite now **auto-detects your connection type** (`netsh wlan`, `Get-NetAdapter`,
`Win32_NetworkAdapter` fallback chain) and adjusts TCP settings to prevent packet loss
on wireless links:

| Tweak | Ethernet (LAN) | WiFi |
|---|---|---|
| `NetworkThrottlingIndex = 0xFFFFFFFF` | Disabled | Disabled |
| `TcpAckFrequency` | **1** (minimum latency) | **2** (prevents ACK-flood packet loss) |
| `TCPNoDelay` | 1 (Nagle off) | 1 (Nagle off) |
| `TcpDelAckTicks` | **0** (immediate ACKs) | **2** (batches ACKs to reduce overhead) |
| `GlobalMaxTcpWindowSize` | 65535 | 65535 |
| NIC power-saving off | Yes | Yes (more aggressive) |

### Additional network fixes

- **QoS packet scheduler**: removes best-effort limit so game traffic gets priority
- **TCP delayed ACK tuning**: WiFi gets a modest ACK batch to reduce wireless overhead
- **Per-adapter power management**: prevents deep sleep states that cause reconnection drops

Every value is read *before* it is written, stored in the recovery journal, and restored
exactly when the watcher stops.

## Microphone noise suppression & echo cancellation

Turns your mic into a clean, party-ready source while you game. The suite cleans
the capture stream so distant background speech, traffic, fans and game echo never
reach the party:

- **Distant background speech removed** (a call to prayer, people talking nearby,
  room/street noise) regardless of how loud it is - only your voice gets through.
- **Echo/kill**: the game's own audio leaking into your mic is cancelled, so the
  party doesn't hear their own voices echo back.
- **Deep Noise Suppression** + classic **Noise Suppression** + **Acoustic Echo
  Cancellation** are engaged at the OS level (native DSP, no downloads).

The suite supports **every modern Windows edition** (10 1809+ and 11), not just
Windows 11:

- **Windows 11 (and any Windows that exposes Deep NS):** the OS AI Deep Noise
  Suppression pipeline is driven directly - automatic and instant.
- **Windows 10 (or where deep NS is absent):** Windows 10's classic NS remains
  available through the platform effects manager. The optional embedded
  real-time spectral suppressor is disabled by default because it requires a
  virtual-microphone routing setup.

The DSP engages **automatically while a game runs** (per-game-session) and is released
the moment the last game closes - it never lingers on the desktop and the host process
exits completely.

> **Note on routing.** The OS effects apply to every app using the mic. If you
> explicitly enable `SoftwareFallback`, route its output through a virtual cable
> to a chat app; do not use the default speakers as the microphone destination.

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
EqualizerAPO session, etc.), set `ExternalEngine` to its path - the suite will launch
it during a session and stop it when the session ends, instead of using the built-in
Windows DSP. Leave it empty to use the built-in effect.

**Menu:** Option **6** engages mic noise suppression (plus network + MMCSS tweaks)
right now; option **7** reverts. During a game session the watcher handles
engage/release automatically.

## Low-spec / legacy PC support

For older or low-spec hardware (e.g. **Intel i3 7th Gen, 8-16GB RAM, Intel HD/UHD
Graphics**).

> **New: low-spec mode is AUTO-DETECTED by default.** At startup the suite checks
> your actual hardware - legacy iGPU/dGPU, low CPU core/thread count and low CPU clock
> - and **enables low-spec mode automatically** on weak machines (like an i3-7020U
> 2-core/4-thread + HD Graphics 620 + 16GB laptop). No `Config.ps1` edit is needed; it
> also stays **light on strong machines** because the reduced polling/throttled scans
> only tighten the suite's own footprint further.

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
- **Polling intervals**: 15s gaming / 35s idle - less CPU overhead
- **BelowNormal watcher priority**: yields to everything else on the system
- **No HAGS**: Hardware-Accelerated GPU Scheduling is unsupported on pre-Xe Intel
- **Gentler standby purges**: only when RAM critically low, with cooldown gates
- **Throttled exit checks**: process exit scans every other cycle during gaming

## GPU detection - integrated AND discrete

`src/GpuDetect.psm1` builds a full graphics-adapter inventory at startup and tags
every chip as **Integrated** or **Discrete** (virtual/software adapters are flagged
too). Sources, in order of reliability: **DXGI** adapter enumeration (what games
actually see), **display-class registry keys** (catch disabled adapters + true VRAM),
and **Win32_VideoController via CIM** as last resort. Results are cached once -
zero overhead inside the polling loop ("no WMI in the hot loop").

| Vendor | Integrated | Discrete |
|---|---|---|
| Intel | HD Graphics 620, UHD/Iris, "Arc Graphics" iGPU | Arc A380/A750/B580, Iris Xe MAX |
| AMD | Radeon(TM) Graphics, Vega 8, 680M/780M/890M | RX 460->RX 9070, R5-R9, Fury/VII |
| NVIDIA | *(no consumer iGPUs)* | GeForce GTX/RTX all series, Quadro, TITAN |

Older / integrated chips are additionally flagged as **legacy** (pre-Pascal GeForce,
pre-RX Radeon, Intel HD 620 and earlier, all GMA chips) so the suite relaxes aggressive
tweaks that can misbehave on that hardware. DXGI EnumAdapters1 is called via raw vtable
(P/Invoke) and compiled lazily, so weak machines don't pay a startup C#-compile cost.

## Supported games

The suite detects and optimizes for **100+ game processes** across all major PC stores:

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
v2.2 introduced pre-game optimization; v2.4 re-checks that no deferred step can ever
stall a game's launch loop:

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

This build adds an in-game adaptation layer that keeps FPS smooth during the exact
moments that used to cause drops - **skill/effect bursts** (particle storms, ability
spam) and **maps of every scale** (small arenas to huge open worlds), which spike
memory and CPU load.

- **RAM-relative pressure floor.** Instead of one fixed value, the watcher treats a
  percentage of your **total** RAM as the "under pressure" threshold (default 10%), so
  it scales correctly whether you have 8 GB or 64 GB and whether the current map is
  tiny or enormous. When free RAM drops under the floor, a cooldown-gated standby purge
  reclaims memory without ever stalling a frame in the middle of a render.
- **Tightening cooldown under stress.** While memory pressure *persists* (a long skill
  fight or a huge map still loading), the purge cooldown shortens automatically (down
  to half) so recurring bursts are caught sooner - and it relaxes back to normal the
  moment memory is healthy, so it never over-purges.
- **Priority re-assertion.** Skill effects and big map loads can let the OS or a
  background hog steal CPU from the game. The watcher periodically re-applies the
  game's priority/affinity during play (cheap, throttled) so heavy moments don't
  translate into hitches.
- These sit **on top** of the existing per-game resolution tiers, so the GPU load is
  already low before adaptive tuning kicks in.

Configure in `src/Config.ps1` under `AdaptiveTuning`:

```powershell
AdaptiveTuning = @{
    Enabled              = $false
    AdaptivePurgeFloor   = 10      # % of total RAM treated as "under pressure"
    PressureCooldownSec  = 60      # min seconds between adaptive purges
    ReassertPriorities   = $true   # periodically re-apply game priority/affinity
    ReassertEveryCycles  = 3       # re-check every N poll cycles during play
}
```

Standby purges remain session-safe: still never repeated mid-frame on a timer, still
gated by a cooldown, and any change is journaled so an unclean stop is fully restored.

## Background reliability & crash recovery

Every change is mirrored to a recovery journal (`logs/runtime/watcher_state.json`) at
the moment it is made. Unclean shutdowns (kill, crash, power loss) are repaired
automatically on next start or stop. Cross-process shutdown uses a named kernel event
(instant wake) and single-instance protection uses a named mutex - no lock-file
polling, no stop-marker files.

## File layout

```
build.bat                     one-click rebuild of GamingPerformanceSuite.zip
Start-GamingSuite.bat         (generated by build) interactive menu
Start-Watcher-Hidden.bat      (generated by build) background watcher
Stop-GamingSuite.bat          (generated by build) stops watcher, restores everything
src/
  Main.ps1                    menu + hidden background mode (-BackgroundWatch)
  Config.ps1                  game list, thresholds, scale %, low-spec mode,
                              network tuning, voice clarity
  Common.psm1                 logging, privileges, platform detection,
                              stop-signal / single-instance + recovery journal
  GameBoost.psm1              FPS stability engine + watcher loop (stutter-free,
                              low-spec optimized)
  DisplayScale.psm1           dynamic display-mode switching + native restore (user32)
  GpuDetect.psm1              GPU inventory: iGPUs AND dGPUs, legacy detection
                              (DXGI / registry / CIM)
  NetTune.psm1                network latency (WiFi/LAN aware) + mic/MMCSS clarity
  VoiceDSP.psm1               microphone noise suppression + echo cancellation
                              (Windows 10 1809+/11 native DSP + embedded real-time
                              spectral suppressor + external engine)
  VoiceDSP-Host.ps1           hidden capture-stream host that holds/engages the
                              mic DSP effects during a game session
  Build-Suite.ps1             generates .bat launchers + repacks ZIP
logs/
  runtime/watcher.pid         background watcher PID (removed on clean stop)
  runtime/watcher_state.json  crash-recovery journal (removed on clean stop)
  suite_YYYYMMDD.log          timestamped operation log
```

> The ZIP only ships the runtime layout (the three launchers + `src/` + `README.md` +
> `.gitignore`). `build.bat` and `src/Build-Suite.ps1` are build tooling and live only
> in the source repository, never inside the ZIP.

## Portable install

The suite is fully portable. Copy the folder (or extracted ZIP) anywhere - `C:\`,
`D:\`, `E:\`, `F:\`, another drive letter, an HDD, an SSD, or a USB stick - and run.
Everything resolves relative to its own folder; no drive letter is embedded in the
runtime. Nothing is registered system-wide, and deleting the folder removes the
suite's files completely.

## Notes & safety

- All actions use standard OS APIs/registry values; no installs, no downloads.
- Anti-cheat processes (Vanguard, EAC, BattlEye) are never touched.
- Voice apps (Discord, TeamSpeak, etc.) are never silenced - your mic stays clean.
- Mic noise suppression/echo cancellation uses the OS DSP (plus a self-contained
  real-time spectral suppressor on Windows 10) - still no installs, no downloads, and
  it only engages while a game runs.
- Network/voice tweaks are journaled and reverted exactly on stop.
- If an action fails, check `logs/` - most failures mean the script wasn't elevated
  (run as Administrator).