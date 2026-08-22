# Gaming Performance Suite

Zero-install Windows toolkit (PowerShell 5.1 — preinstalled on every Windows 10/11 PC,
nothing to download or install) that stabilizes FPS in games like **Valorant, Steam
titles, and PS2 emulators (PCSX2)**, **cuts GPU load dynamically** while you play,
**identifies every integrated and discrete GPU** in your system, and **adapts itself
to older graphics hardware** automatically.

## Quick start

1. Double-click **`Start-Watcher-Hidden.bat`** → accept the UAC prompt.
   The watcher starts hidden in the background — no console window to keep open or minimize.
2. Launch your game normally.
3. Stop the watcher any time with **`Stop-GamingSuite.bat`**.

Prefer a menu? Double-click **`Start-GamingSuite.bat`** for interactive options.

## What happens when you start a game

The watcher polls cheaply — every 10 s while a game runs, every 25 s while idle
(both tunable in `src/Config.ps1`). On detection of a known game process it:

| Step | Action |
|---|---|
| Detect | Classifies the title (Emulator / Steam / Competitive / Default) |
| Boost | Priority → High, steered off core 0, background hogs silenced |
| **Scale down** | Display switches to a lower same-aspect resolution → render target shrinks → GPU load drops hard |
| Frame pacing | Global timer locked to 1 ms — engaged only for the game session and released on exit, so idle interrupt load stays near zero |
| Optional | If configured, launches your frame-generation app alongside the game |

On detected **legacy GPUs** the *Scale down* step is skipped automatically
(see *Legacy GPU support* below); every other step still applies.

When you close the game — or stop the watcher — everything reverts automatically:
**native resolution restored**, priorities reset, timer released.

## Resolution scaling & upscale quality

Only modes with the **same aspect ratio** are selected (no distortion), and an exact
**1/2-native mode is preferred when available** — integer upscaling is mathematically
pixel-perfect. The upscale itself is performed by GPU scanout hardware at your panel's
native refresh rate: no CPU cost, no added input lag.

For strictly pixel-perfect edges, enable **GPU Scaling + Integer Scaling** once in your
NVIDIA/AMD driver panel (a one-time driver toggle; software cannot flip it reliably).
Tune the target in `src/Config.ps1`: `ResolutionScalePercent` (default 66 %).

## GPU detection — integrated AND discrete

`src/GpuDetect.psm1` builds a full graphics-adapter inventory at startup and
tags every chip as **Integrated** or **Discrete** (virtual/software adapters
are flagged too, so gaming logic can skip them):

| Vendor | Integrated examples | Discrete examples |
|---|---|---|
| Intel | HD Graphics 620, UHD/Iris, "Arc Graphics" (Meteor Lake iGPU) | Arc A380/A750/B580, Iris Xe MAX |
| AMD | Radeon(TM) Graphics, Vega 8, R7 Graphics, 680M/780M/890M, HD xxxx D/G | RX 460→RX 9070, R5–R9, HD 7970, Fury/VII, Pro W/FirePro/Instinct |
| NVIDIA | *(no consumer iGPUs)* | GeForce GTX/RTX all series, Quadro, TITAN, MX |

Detection sources, in order of reliability: **DXGI adapter enumeration**
(what games actually see — PCI vendor/device IDs + dedicated VRAM), then the
driver **registry class keys** (also catches disabled adapters + true VRAM),
with **Win32_VideoController** only as a last-resort fallback. The result is
cached: one-shot cost at startup, zero work inside the watcher's polling loop.

### Legacy GPU support (older integrated or discrete cards)

The `LegacyGpuSupport = @{ ... }` block in `src/Config.ps1` relaxes aggressive
tricks on older hardware — pre-Pascal GeForce (FX through GTX 2xx–8xx), Radeon
7xxx–9xxx / X-series / all HD families / R-series / Fury / Vega-GCN, and Intel
GMA plus every "HD Graphics"-branded iGPU (UHD, Iris and Arc stay modern) —
where display-mode switches, HAGS or fullscreen optimizations misbehave or do
nothing:

| Setting | What happens on a legacy GPU (Mode = 'Auto') |
|---|---|
| `SkipResolutionSwitch` | dynamic resolution switching is skipped entirely |
| `DisableFullscreenOptimizations` | per-game FSO-off compat flag while gaming; always undone on exit |
| `EnableHags` | the `HwSchMode=2` registry write is skipped (unsupported/unstable on old drivers) |
| `ScalePercentOverride` | e.g. `50` = gentler render target when scaling is still used |

- `Mode = 'Auto'` (default): detection decides per system — works identically
  for integrated and discrete cards.
- `Mode = 'On'` / `'Off'`: force or disable the legacy profile.
- Any explicitly set value (`$true`/`$false`) overrides what Auto would pick,
  so a single tweak can be forced regardless of detection.

## Frame generation — honest explanation

Frames cannot be invented by an external script; real frame insertion happens inside
GPU drivers (DLSS 3 FG / FSR 3 FG) or dedicated interpolator apps (e.g. Lossless
Scaling). What this suite does:

- **Frame pacing**: locks the system timer at 1 ms while gaming (smoother perceived motion)
- **HAGS**: enables Hardware-Accelerated GPU Scheduling (full optimization option);
  the registry write is skipped automatically on legacy GPUs
- **Companion bridge**: if you own a frame-gen app, set `FrameGeneration.Enabled = $true`
  and its `ToolPath` in `src/Config.ps1` — it launches with each detected game and closes
  afterwards. Off by default; nothing is ever downloaded.

## File layout

```
.gitignore                    keeps generated ZIPs and runtime logs out of git
build.bat                     one-click rebuild of GamingPerformanceSuite.zip
Start-GamingSuite.bat         ← interactive menu
Start-Watcher-Hidden.bat      ← background watcher, no window (recommended)
Stop-GamingSuite.bat          ← stops the watcher instantly, restores everything
src/
  Main.ps1                    menu + hidden background mode (-BackgroundWatch)
  Config.ps1                  game list, thresholds, scale %, frame-gen bridge
  Common.psm1                 logging, privileges, stop-event / single-instance helpers
  GameBoost.psm1              FPS stability engine + watcher loop
  DisplayScale.psm1           dynamic display-mode switching + native restore
  GpuDetect.psm1              GPU inventory: finds iGPUs AND dGPUs, classifies
                              each, flags legacy hardware for the safe profile
  Build-Suite.ps1             zip builder used by build.bat
logs/
  runtime/watcher.pid         background watcher PID (removed on clean stop)
  suite_YYYYMMDD.log          everything the suite does, timestamped
```

## Stopping the program

- **`Stop-GamingSuite.bat`** — wakes the watcher instantly through a kernel event;
  it restores native resolution, priorities and timer, then exits.
- In the interactive menu: option `5`.
- Closing a game alone already restores the resolution; stopping the watcher is only
  needed when you're done playing entirely.

## Resource footprint (designed not to hurt your FPS)

- Everything except the watcher is one-shot — applies settings and returns.
- The watcher runs **hidden**, at **BelowNormal priority**, and **parks on a kernel
  wait event** between polls: ~0 % idle CPU, a few MB of RAM. It never enumerates all
  processes, and its polling loop never touches WMI/CIM or re-queries the GPU
  (the GPU inventory *and* the legacy-hardware decision are one-shot snapshots
  resolved from cache at startup, milliseconds before any game launches).
- **Stutter-safe housekeeping**: the 1 ms pacing timer and the standby-memory
  purge are engaged only around actual game sessions — the purge lands in the
  loading screen at launch; mid-game it requires free RAM below
  `CriticalRamFloorMB` (default 768 MB) *and* a `StandbyPurgeCooldownSeconds`
  (default 15 min) gap between purges. This removes the periodic hitch that
  timer-based purges cause.
- **Adaptive cadence**: scans every `WatcherPollSeconds` (10 s) while gaming,
  every `IdlePollSeconds` (25 s) while idle — half the background work of a
  fixed-interval poller on low-spec laptops.
- **Lazy native interop**: display/timer/memory P/Invoke types compile on first
  real use instead of at module import, so watcher startup skips the C# compiler
  spin-up entirely (it lands inside a game's loading screen if ever needed).
- A single-instance mutex prevents accidental double launches.
- The lower display mode is applied session-only (`CDS_DYNAMIC`): even if the PC loses
  power mid-game, the mode reverts on reboot.

## Building the ZIP from source

The ready-to-run **`GamingPerformanceSuite.zip`** is deliberately **not** stored
in the repository (`*.zip` and runtime `logs/` are excluded by `.gitignore`).
After cloning or downloading, generate it with one command:

- Double-click **`build.bat`**, or
- run: `powershell -NoProfile -ExecutionPolicy Bypass -File src\Build-Suite.ps1`

The builder verifies that every required source file exists and repacks the
portable archive (clean forward-slash entry names, no admin rights needed).
Then continue with *Quick start* above.

## Portable install (any drive, zero setup)

Copy the folder (or `GamingPerformanceSuite.zip` extracted) anywhere — `D:\`, `E:\`,
a USB stick — and double-click a `.bat`. Everything resolves relative to its own
folder; nothing is registered system-wide. Delete the folder and it is completely gone.

## Notes & safety

- All actions use standard Windows APIs/registry values; no installs, no downloads.
- Anti-cheat processes (Vanguard `vgc`/`vgtray`, EAC, BattlEye) are never touched —
  we only use documented OS-level scheduling APIs, never inject into games.
- Exclusive-fullscreen titles follow the display switch directly; if a game runs
  borderless-windowed, set *its* internal resolution once and the watcher still boosts
  priority/silence/pacing around it.
- If an action fails, check `logs/` — most failures mean the script wasn't elevated.
