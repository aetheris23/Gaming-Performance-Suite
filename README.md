# Gaming Performance Suite v3.0

Zero-install performance toolkit for gaming on **Windows 10/11** (PowerShell 5.1+,
nothing to install). Stabilizes FPS, cuts GPU load dynamically, identifies every GPU in
your system, and adapts to older hardware. Almost any game or video in windowed or
borderless-fullscreen mode is detected and optimized automatically - no need to add
its process name first - and launch stutter is eliminated.

**Windows-only build.** Linux, macOS and Android/Termux support have been removed so
the watcher no longer carries cross-platform code paths (sysproc `/proc` scans,
`xrandr`/`displayplacer` calls, `sysctl`/`iw` tuning, stop-marker polling). Every
scan now stays native to Windows and much lighter on the CPU.

## What's new in v3.0

- **Universal windowed-mode optimization.** The watcher no longer needs your game on
  the list. Whenever a foreground window fills its own monitor (≥ `ImmersiveWindowThreshold`
  in `Config.ps1`, default 90%) it is treated as a game/video session - any game running
  borderless-fullscreen or maximized, and any maximized video player. The window's *own*
  monitor is used for the coverage ratio, so multi-monitor setups classify correctly, and
  a built-in blocklist (Windows shell, consoles, browsers, stores/launchers, office,
  productivity) keeps everyday maximized windows out. Once detected a window stays
  boosted until its process exits - no flip-flop when you alt-tab. Unknown immersive
  titles get the **Default** profile (`AboveNormal` + Medium resolution tier).
- **Network tuning and voice/audio features removed.** The suite no longer touches TCP
  settings, WiFi/LAN detection, mic noise suppression, or voice/party-app priorities.
  `src/NetTune.psm1` is gone, along with every menu option, status line and recovery
  journal entry for them. Voice apps are no longer protected from background silencing
  (the default `Deprioritize` lists don't include comms apps anyway), and pre-game
  optimization now applies the system-wide FPS tweaks (Game DVR off, multimedia
  scheduling + HAGS) before games launch.
- **Adaptive purge can no longer cost a frame on a single transient dip.** A standby
  purge stalls the whole memory manager, and it used to fire the moment free RAM slipped
  under the 10% floor — during ability effects and heavy map spots. It now requires the
  floor to be crossed on **two consecutive checks** before purging (then keeps the
  tightening cooldown), so a brief combat/map spike never causes a mid-render hitch
  while genuinely sustained low-RAM pressure is still recovered.
- **Dead code & duplicate entries removed.** Unused watcher bookkeeping
  (`$lastSilenceUtc`, `$silenceThrottleSec`, `$wasIdle`), the deprecated
  `FreeRamThresholdMB` parameter/config key, the voice-app pattern list, voice-chat
  support, the never-read `$script:PriorityCapWarned` and `$script:StretchActive`
  flags, a duplicate `ryujinx` entry, and a redundant journal-key check in the boost
  loop are all gone. The foreground-window interop is compiled once via a shared
  helper and doubled as an immersive-window geometry probe. No behavior change to the
  remaining features.

## What's new in v2.9

- **Adaptive tuning is now ON by default** (`AdaptiveTuning.Enabled = $true`). Fixed a
  gating bug so the adaptive mid-game purge actually runs: it previously required
  `AllowMidGamePurge` (default OFF), which made the adaptive path inert on out-of-box
  configs — the exact situation where skill/effect bursts and large-map loads spike RAM
  and drop FPS. The classic purge stays opt-in (it can hitch a frame), while the
  adaptive path fires only under a RAM-relative floor with its own tightening cooldown.
- **Uneven combat/map FPS drops addressed** for Valorant & friends. Adaptive
  `AdaptivePurgeFloor` and `PressureCooldownSec` are now validated/clamped in code
  (1–90 % and ≥5 s), so a bad config value can no longer disable or over-tighten
  the burst purger.
- **Cleanup - dead code removed.** Cross-platform leftovers that were never called
  (`Test-SuitePlatformWindows`, `Get-PlatformInfo`, `Test-WatcherLockHeld`,
  `Test/Set/Clear-StopRequest`) are gone from `src/Common.psm1`, and duplicate entries
  were dropped from game-process lists and never-watch lists. No behavior change.
- **Removed in v3.0:** the network-profile refresh and voice-clarity features
  described below no longer exist (see v3.0 note above).

## What's new in v2.7

- **Network packet-loss fixes.** *(Removed in v3.0 - the suite no longer tunes any TCP
  settings.)* Connection detection no longer parsed localized
  `netsh` text (which misread non-English installs and forced Ethernet ACK settings
  onto WiFi). It read the routing table + adapter object model, cached for
  60 s, and TCP tuning only touched adapters that were actually connected.
- **Background noise removed from party/team chat.** *(Removed in v3.0 - mic/audio
  features are gone.)* The Windows built-in per-mic input signal enhancements were
  enabled at game start and reverted on stop.
- **WinDetect module removed - lighter startup.** The background watcher no longer
  probes powercfg/netsh/WMI/registry on every start. Build detection is now a single
  registry read for the status line, and power-plan facts are probed once, only when
  option 1 (full optimization) actually needs them.
- **Battery-aware power plan.** The 100% minimum-CPU floor and PCIe power-management
  off now apply **only on AC** by default, so laptops don't drain battery while the
  aggressive values still remove FPS dips on mains. Override via
  `Config.ps1 > PowerOptimization`.
- **Performance / bug fixes.** Watcher startup performs zero WinDetect work in the hot
  path.

> Note: v2.6's "auto-detect every Windows flavor / debloated build" feature
> (`src/WinDetect.psm1`) was **removed** in v2.7 - the diagnostic value did not justify
> its startup cost. It leaves no traces: the old WinDetect import is gone from every
> module.

## What's new in v2.8

- **Competitive shooters now stay at NATIVE resolution by default** (Valorant, CS2,
  Dota 2). The old `Competitive = Low` tier dropped the display to ~540p on a 1080p
  panel and upscaled it back: distant enemies became mushy and blended into the
  environment, effective aim changed, and the fullscreen mode switch added hitches
  around round start. These titles already run fine at native on low-spec hardware,
  so they keep every win *that doesn't touch the display* (priority, timer,
  purge). Re-enable the aggressive drop per game via `GameTierOverrides` in
  `src/Config.ps1` (e.g. `'cs2' = 'Low'`).
- **The display scaler can no longer drop your refresh rate.** `Select-ScaledMode`
  only selects a lower resolution when that mode keeps the panel's native Hz (e.g.
  144Hz); modes that only exist at 60Hz are rejected and the screen stays native. A
  144→60Hz drop while the game runs was a major source of the *"lag / missed shots"*
  feeling during effects, flashes and large-map rendering, even as the game ran fine.
- **Lighter polling under load.** The memory-pressure RAM probe only runs on cycles
  where a purge could legally fire; the watcher stays off the CPU during map renders
  and effect bursts.

## What's new in v2.6

- **Auto-detects every Windows flavor — official and custom builds.** The suite now
  reads the registry to identify *exactly* which Windows is running: major version +
  build (10 vs 11), edition (Home/Pro/Server/LTSC), feature release (21H2…24H2) and any
  custom build marker. Debloated gaming builds like **ReviOS, AtlasOS, Ghost Spectre,
  Tiny11/12 and Windows Server** are recognized automatically and shown on the banner
  and the status screen.
- **Power plans tailored to debloated builds.** On builds that strip the stock
  "High performance" / "Ultimate performance" schemes (or even `powercfg` itself), the
  suite no longer fails: it clones the active scheme, or skips the plan switch cleanly
  and continues every other optimization. No whitelist to maintain — it just probes
  powercfg and works around whatever is missing.
- **Never-boost safety list.** Anti-cheat, kernel services and launcher helper
  processes (`vgc`, `BEService`, `EasyAntiCheat`, `Battle.net`, …) are never touched,
  even temporarily. The list is built-in and safely extensible via
  `NeverWatchProcesses` in `Config.ps1`.
- **Shallower CLI polling.** Watcher cadence auto-slows when no game is running to cut
  idle CPU load (still catches launches instantly), and `ActiveGameOnly` keeps boosting
  focused on the foreground window.

## What's new in v2.5

- **Windows-only, lighter scanning.** All Linux/macOS/Android branches were stripped
  out, and the game-poll matcher was rewritten: the 100+ game names are compiled once
  into a `HashSet` (O(1) lookups), with wildcard `-like` matching reserved for the few
  patterns that actually contain `?`/`*`. A single native process snapshot per poll now
  uses a `List<Process>` instead of a pipeline filter - near-zero watcher CPU while
  idle, and no stutter that accumulates during long sessions on weak CPUs.
- **Watcher auto-stops on game close.** The background watcher now exits completely
  when your game session ends instead of idling resident in memory, so there is no
  lingering overhead, priority/timer/resolution state is fully restored, and nothing
  keeps polling for another game.
- **Removed recording / OBS support entirely.** The obsolete recording-software
  detection, config, menu entries and dependencies have been stripped out - fully
  focused on frame time over the capture stack.
- **Competitive enemy-highlight presets.** *(Removed in v3.0 - the unused
  `EnemyHighlight` config block was deleted.)* This described `src/Config.ps1` presets
  for Valorant's enemy-highlight color setting. The suite never applied a whole-desktop
  gamma/color matrix (it could tint menus, add scanout work on low-spec hardware, and
  conflict with anti-cheat). If distant enemies are hard to spot, keep the game at
  **native resolution** - v2.8 no longer downsamples competitive shooters (a blurry
  upscaled image is what made long-range targets blend into the environment).
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
      optimization, starting/stopping the watcher, and status.
   - **Stop:** double-click **`Stop-GamingSuite.bat`** - restores native resolution,
      priorities and timer.

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
35 s while idle (both tunable in `src/Config.ps1`). On detection of a game or an
immersive windowed video/game it:

| When | Action |
|---|---|
| **Before launch** | Pre-game optimizations: power plan, multimedia scheduling + HAGS, Game DVR off - applied BEFORE the game process appears (eliminates launch stutter) |
| **Instantly** | Classifies the title (Emulator / Steam / Competitive / Android / Default); priority boosted; steered off core 0; frame pacing timer engaged |
| **~0.5 s** | Standby-memory purge (BEFORE game fully loads - eliminates launch stutter) |
| **~1 s later** | Legacy FSO flag + optional frame-generation companion app |
| **~8 s later** | Secondary standby purge during loading screen |
| **~12 s later** | Display switches to the game's resolution tier (Low / Medium / High / Native) -> GPU load drops hard |

Heavy steps are **staged with optimized timing** to eliminate the stutter/frame-drop
burst that used to hit when launching games. The pre-game pass ensures the system-wide
scheduling/DVR tweaks are in place BEFORE the game process appears.

> **Resolution tiers (auto per game):** instead of one global percentage, every
> detected game is assigned a quality tier based on its **profile**, so the right
> resolution is picked for Steam, Riot/esports, PS2/console emulators (PCSX2, PPSSPP,
> Dolphin, RetroArch, DuckStation...), Android emulators on PC (Bluestacks, LDPlayer,
> NOX, MuMu...), and anything else. Competitive shooters default to **Native** (no
> display switch) so aim and long-range visibility are never degraded.

| Tier | Target width | Typical use |
|---|---|---|
| **Low** | 55% of native | Opt-in aggressive drop for weak GPUs (set via `GameTierOverrides`) |
| **Medium** | 75% of native | Balanced default for Steam & emulators |
| **High** | 88% of native | Nearly-native sharpness, still a solid gain |
| **Native** | 100% (no switch) | Competitive shooters (Valorant/CS2/Dota) - keeps aim + Hz |

Any scaled mode is only ever selected if it **keeps the panel's native refresh
rate**; if the monitor only offers the lower resolution at 60Hz, the suite stays at
native instead of downclocking your display mid-game.

Supported games run at 480p, 720p, 900p, 1080p etc. - `Select-ScaledMode` picks the
closest **same-aspect-ratio** mode to the tier's target, preferring exact 1/2 integer
scaling when available (crisp, never stretched or blurry). With `StretchedResolution`
enabled, a different-aspect lower mode is chosen and scaled to fill the whole panel
via `dmDisplayFixedOutput = DMDFO_STRETCH` - the classic FPS "stretched" look. You can
adjust every tier, every profile default, and even add per-game overrides in
`src/Config.ps1` (`ResolutionTiers`, `ProfileTiers`, `GameTierOverrides`).

> **Session-scoped:** the moment the last monitored game closes, the watcher undoes
> every change (native resolution, priorities, timer) and exits completely.
> It is a single-session optimizer, not a resident service - it will not keep polling
> on a low-spec machine waiting to detect a "next game". To play again later, just
> start it again. (For the old always-on behavior set `ExitWhenGameSessionEnds = $false`
> in `src/Config.ps1`.)

## Universal windowed-mode optimization

Network tuning and voice/audio features have been **removed** from the suite in v3.0.
The watcher now focuses purely on FPS stability and works for **almost any game or
video**, even titles that were never added to the game list.

While the configured `GameProcesses` list still covers 100+ names, the watcher also
runs a **universal path**: when the foreground window covers at least
`ImmersiveWindowThreshold` of its *own* monitor (default `0.90`/90%), it is treated
as a game/video session. This catches:

- Games running **borderless-fullscreen** or **maximized** in a window
- **Video players** (any maximized player - no hardcoded media-app list needed)
- New or obscure titles you haven't added to `GameProcesses`

Unknown immersive titles get the **Default** profile (`AboveNormal` priority +
**Medium** resolution tier). Once a window is registered it stays boosted until its
process exits - switching away (alt-tab, second monitor work) never drops the boost
mid-session.

The coverage ratio uses the window's own monitor via
`MonitorFromWindow`/`GetMonitorInfo`, so multi-monitor rigs classify correctly.
`ImmersiveWindowThreshold` is validated/clamped to 40–99.5% in code.

A built-in blocklist keeps everyday maximized windows out of the gaming path:

- Windows shell / system (`explorer`, `dwm`, `cmd`, `taskmgr`, `control`, …)
- Consoles and terminals (`conhost`, prompt apps, terminal emulators)
- Browsers (`chrome`, `msedge`, `firefox`, `opera`, `brave`, …)
- Stores & launchers (covered by `NeverWatchProcesses` too)
- Office & productivity (`winword`, `excel`, `code`, `notion`, `slack`, `acrobat`, …)

Note: the anti-cheat / store-launcher safety list (`NeverWatchProcesses`) is merged
into the universal path, so `vgc`, `BEService`, `EasyAntiCheat`, browsers and the
like can never be boosted or downscaled.

Configure in `src/Config.ps1`:

```powershell
UniversalWatch            = $true    # detect ANY immersive foreground game/video, not just the list
ImmersiveWindowThreshold  = 0.90     # fraction of the window's OWN monitor it must fill (0.40-0.995)
```

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
(standby purge, display switch, pre-game tweaks) ran AFTER the game was detected.
v2.2 introduced pre-game optimization; v2.4 re-checks that no deferred step can ever
stall a game's launch loop:

1. **Pre-game phase** (before any game detected):
   - Power plan switched to High Performance
   - Multimedia scheduling raised + HAGS enabled (per config)
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
- **Two-check gate (v3.0).** A standby purge briefly pauses the whole memory manager,
  so it only runs after free RAM stays under the floor on **two consecutive checks**.
  One transient dip (a single ability splash, a short effect burst, one map corner)
  can no longer cost a frame mid-combat; only genuinely sustained pressure triggers
  a purge.
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
    Enabled              = $true    # ON so ability/effect bursts and large maps are handled out-of-the-box
    AdaptivePurgeFloor   = 10      # % of total RAM treated as "under pressure"
    PressureCooldownSec  = 60      # min seconds between adaptive purges (needs 2 consecutive sub-floor checks)
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
                              universal-watch & adaptive-tuning settings
  Common.psm1                 logging, privileges, platform detection,
                              stop-signal / single-instance + recovery journal
  GameBoost.psm1              FPS stability engine + watcher loop + universal
                              immersive-window detection (stutter-free, low-spec)
  DisplayScale.psm1           dynamic display-mode switching + native restore (user32)
  GpuDetect.psm1              GPU inventory: iGPUs AND dGPUs, legacy detection
                              (DXGI / registry / CIM)
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
- Anti-cheat processes (Vanguard, EAC, BattlEye) are never touched, and the universal
  watch never boosts the shell, browsers, stores or office apps.
- Every tweak is journaled and reverted exactly on stop.
- If an action fails, check `logs/` - most failures mean the script wasn't elevated
  (run as Administrator).