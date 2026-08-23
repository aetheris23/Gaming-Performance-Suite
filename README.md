# Gaming Performance Suite

Zero-install Windows toolkit (PowerShell 5.1 — preinstalled on every Windows 10/11 PC,
nothing to download or install) that stabilizes FPS in games like **Valorant, Steam
titles, and PS2 emulators (PCSX2)**, **cuts GPU load dynamically** while you play,
**identifies every integrated and discrete GPU** in your system, **tunes your network
for lower latency and fewer packet-loss stalls**, **keeps your microphone clear for
other players**, and **adapts itself to older graphics hardware** automatically.

## Quick start

1. Double-click **`Start-Watcher-Hidden.bat`** → accept the UAC prompt.
   The watcher starts hidden in the background — no console window to keep open or minimize.
2. Launch your game normally.
3. Stop the watcher any time with **`Stop-GamingSuite.bat`**.

Prefer a menu? Double-click **`Start-GamingSuite.bat`** for interactive options.

## What happens when you start a game

The watcher polls cheaply — every 10 s while a game runs, every 25 s while idle
(both tunable in `src/Config.ps1`). On detection of a known game process it:

| When | Action |
|---|---|
| Instantly | Classifies the title (Emulator / Steam / Competitive / Default); priority → High; steered off core 0; frame pacing timer engaged |
| ~1 s later | Legacy FSO flag + optional frame-generation companion app |
| ~2 s later | Standby-memory purge (the loading screen absorbs the brief stall) |
| ~5 s later | Display switches to a lower same-aspect resolution → render target shrinks → GPU load drops hard |

The heavy, system-wide steps are **staged seconds apart** instead of fired
back-to-back, so the game's loading screen absorbs each transition — this removes
the stutter/frame-drop burst that used to hit shortly after launching a game.

On detected **legacy GPUs** the *Scale down* step is skipped automatically
(see *Legacy GPU support* below); every other step still applies.

While you play, background hogs (Steam web helper, browsers, Spotify) are silenced —
but **voice-chat apps (Discord & friends) never are**, and optionally get an
*AboveNormal* bump so microphone capture/encoding stays smooth.

When you close the game — or stop the watcher — everything reverts automatically:
**native resolution restored**, priorities reset, timer released, network values
returned to your originals.

## Background reliability & crash recovery

Every change the watcher makes (display mode, priorities, FSO flags, network
values, frame-gen tool PID) is mirrored **at the moment it is made** into a
recovery journal (`logs/runtime/watcher_state.json`). This means:

- **Stopping is safe however it happens.** `Stop-GamingSuite.bat` signals the
  kernel event and then *waits* for the watcher to finish restoring everything
  (up to 12 s). Only if that fails is the process killed — and the journal then
  replays all missing undo steps automatically.
- **Crashes / closed consoles / power loss repair themselves.** The next watcher
  start (or next `Stop-GamingSuite.bat`) detects the orphaned journal, restores
  native resolution, un-silences apps, clears FSO flags, closes an orphaned
  frame-gen tool and reverts network tuning — then starts fresh.
- The old failure mode — a hard kill 600 ms into cleanup leaving the screen
  scaled down and games stuck at High priority — cannot happen anymore.

## Network optimization during gameplay

Applied once when the watcher starts (before the game opens its sockets) and
reverted from the journal when it stops (`src/NetTune.psm1`, config-gated):

| Tweak | Effect |
|---|---|
| `NetworkThrottlingIndex = 0xFFFFFFFF` | Windows' periodic multimedia network throttle is off → no periodic packet-delay spikes mid-match |
| `TcpAckFrequency=1` + `TCPNoDelay=1` per interface | immediate ACKs, no Nagle batching → lower RTT and fewer burst-loss stalls (helps on Wi-Fi/VPN) |
| NIC `PnPCapabilities` power-saving off | adapter never powers down between bursts → kills micro-dropouts that look like packet loss |

All original registry values are recorded before writing and restored exactly.
Menu options `6`/`7` apply/revert manually.

## Microphone clarity for other players

- Voice apps (Discord, TeamSpeak, Voicemeter, Zoom, Skype, Webex — extendable in
  `Config.ps1`) are **excluded from background silencing**, always.
- Optionally they get **AboveNormal priority during play** so voice encode/capture
  threads never starve behind the boosted game (weak-CPU laptops benefit most).
- MMCSS **Audio / Pro Audio / Capture** classes are raised so Windows keeps the
  audio capture pipeline prioritized system-wide.

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
  Config.ps1                  game list, thresholds, scale %, frame-gen bridge,
                              network tuning, voice clarity
  Common.psm1                 logging, privileges, stop-event / single-instance
                              helpers + recovery journal (save/repair)
  GameBoost.psm1              FPS stability engine + watcher loop
  DisplayScale.psm1           dynamic display-mode switching + native restore
  GpuDetect.psm1              GPU inventory: finds iGPUs AND dGPUs, classifies
                              each, flags legacy hardware for the safe profile
  NetTune.psm1                network latency profile + mic/MMCSS clarity
  Build-Suite.ps1             zip builder used by build.bat
logs/
  runtime/watcher.pid         background watcher PID (removed on clean stop)
  runtime/watcher_state.json  crash-recovery journal (removed on clean stop)
  suite_YYYYMMDD.log          everything the suite does, timestamped
```

## Stopping the program

- **`Stop-GamingSuite.bat`** — wakes the watcher instantly through a kernel event,
  then *waits* while it restores native resolution, priorities, timer and network
  values. If the process is beyond saving it is killed — and the recovery journal
  automatically replays every missing undo step.
- In the interactive menu: option `5`.
- Closing a game alone already restores the resolution; stopping the watcher is only
  needed when you're done playing entirely.
- If anything ever ends uncleanly (power loss, forced kill, crash), the next start
  or stop repairs the leftovers on its own — no manual cleanup needed.

## Resource footprint (designed not to hurt your FPS)

- Everything except the watcher is one-shot — applies settings and returns.
- The watcher runs **hidden**, at **BelowNormal priority**, and **parks on a kernel
  wait event** between polls: ~0 % idle CPU, a few MB of RAM. It never enumerates all
  processes, and its polling loop never touches WMI/CIM or re-queries the GPU
  (the GPU inventory *and* the legacy-hardware decision are one-shot snapshots
  resolved from cache at startup, milliseconds before any game launches).
- **Stutter-free ramp-up**: heavy steps (standby purge, display-mode switch) run
  staged seconds apart after detection — the loading screen absorbs each one; the
  loop only wakes slightly earlier while stages are pending (a few extra 200 ms
  kernel waits per game launch, nothing periodic).
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
- Network/voice registry tweaks are journaled and reverted exactly; menu option `7`
  restores Windows defaults for the values the suite manages.
- Anti-cheat processes (Vanguard `vgc`/`vgtray`, EAC, BattlEye) are never touched —
  we only use documented OS-level scheduling APIs, never inject into games.
- Exclusive-fullscreen titles follow the display switch directly; if a game runs
  borderless-windowed, set *its* internal resolution once and the watcher still boosts
  priority/silence/pacing around it.
- If an action fails, check `logs/` — most failures mean the script wasn't elevated.
