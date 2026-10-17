# Gaming Performance Suite v3.2

A portable Windows toolkit for game-process monitoring, display scaling, performance diagnostics, and optional companion-tool integration (frame generation, microphone enhancement). Built with PowerShell 5.1 and Windows components; no package installs or third-party runtime dependencies.

> **Network expectations:** this suite cannot reduce the physical round-trip time (RTT) to an internet game server, guarantee lower ping, or repair packet loss on an ISP route or server. Network settings vary by adapter and driver, so this version leaves them unchanged by default and reports local adapter counters as diagnostic clues instead.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or later
- Administrator approval to run the optimization launcher and change system settings
- Administrator rights are **not** required to build the ZIP

Linux, macOS, and Android/Termux are not supported.

## Build and Install

1. Download or clone this repository.
2. Run `build.bat` from the project folder, or run:

   ```bat
   powershell -NoProfile -ExecutionPolicy Bypass -File src\Build-Suite.ps1
   ```

3. The build creates `GamingPerformanceSuite.zip` in the project folder. Extract it to a location of your choice.
4. Run one of the generated launchers:
   - `Start-GamingSuite.bat` — opens the interactive menu.
   - `Start-Watcher-Hidden.bat` — starts the background game watcher.
   - `Stop-GamingSuite.bat` — stops the watcher and restores journaled settings.

The launchers request Administrator approval when needed. The ZIP is a runtime package: it contains the launchers, `src/`, `README.md`, and `.gitignore`; it does **not** contain `build.bat` or `src/Build-Suite.ps1`.

## Features

- Detects configured game processes and immersive foreground windows (borderless-fullscreen games, maximized video players).
- Applies per-game process profiles: priority, CPU affinity, timer resolution (1-2 ms), standby-memory purge.
- Optional dynamic display resolution scaling: drops to a lower same-aspect mode during play, restores native on exit. Stretch mode (e.g., 4:3 on 16:9) available.
- Low-spec auto-detection (legacy GPU + weak CPU) with automatic reduced-mode profile.
- Adaptive mid-game tuning: reacts to memory pressure from effect bursts / large-map loads with cooldown-gated purges and priority re-assertion.
- Companion-tool bridges (zero idle overhead):
  - **Frame generation** — launches configured tool (e.g., Lossless Scaling) alongside detected game.
  - **Microphone enhancement** — two modes:
    - **Companion tool bridge** (recommended): launches an external audio tool that exposes a virtual microphone (requires kernel driver such as VB-Cable or Voicemeeter). See `Invoke-MicEnhanceTool` / `Stop-MicEnhanceTool`.
    - **Built-in DSP pipeline** (alternative): native C# processing within PowerShell via WASAPI capture/render. Chain: pre-amp gain → noise gate → spectral noise suppression (FFT) → compressor → limiter → optional AGC. See `Start-MicEnhancement` / `Stop-MicEnhancement` / `Test-MicEnhancement` / `Get-MicDevices`.
- Network latency profile (opt-in): registry/driver tweaks (RSC, LSO, interrupt moderation, wireless power, QoS, TCP no-delay), packet-loss monitoring.
- Pre-game optimization: Game DVR off, MMCSS Games priority, HAGS (optional, reboot required).
- Crash-safe recovery journal: every system change logged to JSON; auto-repaired on next start/stop.
- Usage profiles: **Gaming**, **Development**, **DailyUse**, **Custom** — one-line switch in `Config.ps1`.

## Usage Profiles

Set `ActiveProfile` in `src/Config.ps1` to one of:

| Profile | Target | Key Behavior |
|---------|--------|--------------|
| **Gaming** | Max FPS stability | 75% resolution scale, aggressive polling (10s), adaptive tuning ON, background silence ON, frame-gen bridge ready, network tweaks ON, pre-game purge ON |
| **Development** | Zero interference | Native resolution, minimal polling (30s/60s/120s), NO priority/timer/purge/silence, NO frame-gen, NO network tweaks, NO power changes, frame-time diagnostics ON |
| **DailyUse** | Light background | Native resolution, moderate polling (20s/45s/90s), pre-game optimizations only (Game DVR/MMCSS), adaptive tuning conservative (15% floor), universal watch OFF, network monitoring only |
| **Custom** | User-defined | Uses individual settings below (no profile override) |

All profiles are **reversible** — every session-scoped change is undone when the watcher exits.

## Configuration

Edit `src/Config.ps1` to adjust:

- `ActiveProfile` — `'Gaming' | 'Development' | 'DailyUse' | 'Custom'`
- `GameProcesses` — process names (without `.exe`) to auto-boost
- `WatcherPollSeconds` / `IdlePollSeconds` / `ExtendedIdlePollSeconds` — polling cadence
- `UniversalWatch` / `ImmersiveWindowThreshold` — detect ANY immersive foreground window
- `ResolutionTiers` / `ProfileTiers` / `GameTierOverrides` — per-game resolution scaling
- `LowSpecMode` — auto/on/off, skip flags, CPU core limiting
- `AdaptiveTuning` — memory-pressure reaction
- `FrameGeneration` — companion tool path (e.g., Lossless Scaling)
- `MicrophoneEnhancement` — companion tool path and/or built-in DSP settings:
  - Companion mode: `ToolPath`, `Profile`, `AutoLaunchWithGame`, `RestoreOnExit`
  - Built-in DSP mode: `Enabled`, `GainDb`, `NoiseGateEnabled`, `NoiseSuppressionEnabled`, `CompressorEnabled`, `LimiterEnabled`, `AgcEnabled`, plus per-block DSP parameters (see Config.ps1 defaults)
- `NetworkOptimization` — opt-in driver/registry tweaks
- `PowerOptimization` — gaming power plan (AC-only by default)
- `LegacyGpuSupport` — legacy-safe behavior for pre-WDDM2.x GPUs
- `FrameTimeDiagnostics` — lightweight frame-time sampling (percentiles)

Use the existing values as the supported configuration surface; back up the file before making changes.

### Microphone Enhancement — Two Operating Modes

#### Mode 1: Companion Tool Bridge (Recommended)

The `MicrophoneEnhancement` section can launch a **companion tool** that does the actual DSP (gain, noise gate, noise suppression, compressor, clip protection, optional neural suppression via RNNoise). PowerShell cannot provide the sub-10 ms deterministic latency required for real-time neural audio processing.

**The companion tool MUST install its own virtual audio driver** (VB-Cable, Voicemeeter virtual I/O, or a custom WDM/KS driver) so communication apps and games can select the enhanced signal as an input device. Windows has no built-in virtual microphone that a user-mode app can create without a kernel driver — this is a hard requirement.

Recommended companion: an RNNoise-based tool (~2 MB, <5% CPU, native code, headless/minimized).

#### Mode 2: Built-in DSP Pipeline (Alternative)

When no companion tool is configured (`ToolPath` is empty), the suite can run a **built-in native C# DSP pipeline** inside PowerShell via WASAPI capture/render. This is suitable for basic processing (gain, noise gate, spectral suppression, compressor, limiter) on weaker hardware where a companion tool is not available.

**Chain:** pre-amp gain → noise gate → spectral noise suppression (radix-2 Cooley-Tukey FFT) → compressor → limiter → optional AGC → safety clip.

**Latency target:** ~10-20 ms per frame (depends on frame size and CPU). Not suitable for sub-10 ms professional audio requirements.

**Virtual microphone requirement (hard):** Same as companion mode — to route the enhanced signal to communication apps/games, install a virtual audio driver (VB-Cable, Voicemeeter, or similar WDM/KS driver), set the DSP render output to that virtual cable, and set the app/game input device to the virtual cable. Without a virtual cable, the module can still capture + process + monitor (playback to default render device) for testing.

**Enable built-in DSP:** Set `MicrophoneEnhancement.Enabled = $true` and leave `ToolPath = ''` in `Config.ps1`. The watcher launches `Start-MicEnhancement` on game detect and `Stop-MicEnhancement` on game exit. Test without hardware using `Test-MicEnhancement`.

**Built-in DSP parameters (all in Config.ps1 `MicrophoneEnhancement` hashtable):**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Enabled` | `$false` | Master switch for microphone enhancement |
| `ToolPath` | `''` | Companion tool path (empty = use built-in DSP) |
| `Profile` | `'Default'` | Companion tool profile (`'VoiceFocus'` \| `'NoiseSuppression'` \| `'Custom'`) |
| `AutoLaunchWithGame` | `$true` | Launch when game is detected |
| `RestoreOnExit` | `$true` | Stop enhancement when watcher stops |
| `GainDb` | `0` | Pre-amp gain in dB |
| `NoiseGateEnabled` | `$true` | RMS-based noise gate |
| `NoiseGateThresholdDb` | `-40` | Gate threshold in dB |
| `NoiseGateFloorDb` | `-60` | Gate floor in dB |
| `NoiseSuppressionEnabled` | `$true` | Spectral noise suppression (FFT-based) |
| `NoiseSuppressionStrength` | `0.5` | Suppression strength (0-1) |
| `CompressorEnabled` | `$true` | Dynamic range compression |
| `CompressorThresholdDb` | `-20` | Compressor threshold in dB |
| `CompressorRatio` | `4` | Compression ratio |
| `LimiterEnabled` | `$true` | Clipping protection |
| `LimiterCeilingDb` | `-3` | Limiter ceiling in dB |
| `AgcEnabled` | `$false` | Automatic gain control |
| `AgcTargetDb` | `-18` | AGC target level in dB |
| `AgcRate` | `0.01` | AGC adaptation speed (0-1) |

All profiles (Gaming, Development, DailyUse, Custom) default to `Enabled = $false` (conservative).

## Safety and Recovery

- All system changes are opt-in (disabled by default where they carry risk).
- The recovery journal records original values before each mutation.
- A normal watcher stop restores the session state. On the next start or stop, an interrupted session is repaired from the journal.
- Avoid force-killing the watcher. If the PC loses power, run `Stop-GamingSuite.bat` after restarting Windows to trigger recovery.
- Review the log and journal under `logs/` if a restoration reports an error.

## Project Layout

```text
build.bat
src/
  Build-Suite.ps1        Generates launchers and packages the runtime ZIP
  Main.ps1               Interactive menu and watcher entry point
  Config.ps1             User configuration (including usage profiles)
  Common.psm1            Logging, coordination, single-instance mutex, recovery journal
  GameBoost.psm1         Game watcher, process profiles, ramp system, companion bridges
  DisplayScale.psm1      Display-mode selection, integer scaling, stretch mode
  GpuDetect.psm1         GPU inventory, classification, era detection
  NetTune.psm1           Network diagnostics and opt-in latency settings
  MicEnhance.psm1        Microphone enhancement companion-tool bridge + built-in DSP pipeline
```

## Quick Start (Gaming)

1. Build: `build.bat` → extract `GamingPerformanceSuite.zip` → `Start-GamingSuite.bat`
2. In `Config.ps1`, set:
   ```powershell
   ActiveProfile = 'Gaming'
   FrameGeneration = @{ Enabled = $true; ToolPath = 'C:\Path\To\LosslessScaling.exe' }
   # Option A: companion tool (requires virtual audio driver)
   MicrophoneEnhancement = @{ Enabled = $true; ToolPath = 'C:\Path\To\MicEnhance.exe'; Profile = 'VoiceFocus' }
   # Option B: built-in DSP (no companion tool needed; still needs virtual audio driver for routing)
   # MicrophoneEnhancement = @{ Enabled = $true; ToolPath = ''; GainDb = 0; NoiseSuppressionEnabled = $true }
   ```
3. Run `Start-GamingSuite.bat` as Administrator.
4. Launch your game. The watcher detects it, applies the Gaming profile, launches companion tools during the loading screen, and restores everything on exit.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Watcher won't start | Run as Administrator; check `logs/suite_YYYYMMDD.log` |
| Resolution didn't restore | Run `Stop-GamingSuite.bat`; check `logs/runtime/watcher_state.json` |
| No FPS improvement | Verify game runs in borderless/fullscreen; check GPU is not already bottlenecked |
| Mic enhancement not working | Companion: verify tool installs a virtual audio driver; select that device in Discord/game. Built-in: run `Test-MicEnhancement` to verify DSP pipeline; check `logs/` for WASAPI errors; verify `MicrophoneEnhancement.Enabled = $true` and `ToolPath = ''` in Config.ps1. |
| Network tweaks made it worse | Revert with Menu option 7 or `Stop-GamingSuite.bat`; disable the specific switch in `Config.ps1` |
| Low-spec mode unwanted | Set `LowSpecMode.Mode = 'Off'` in `Config.ps1` |

## Compatibility Limitations

- **Anti-cheat:** Never touches Vanguard, BattlEye, EAC, or launcher processes (hard-coded blocklist).
- **Display scaling:** Only same-aspect modes by default; stretch mode requires a lower mode with different aspect. Refresh rate is preserved — if no scaled mode offers the native Hz, scaling is skipped (a 60 Hz drop feels like input lag).
- **Microphone enhancement:** Two modes. Companion tool requires virtual audio driver (VB-Cable, Voicemeeter, etc.). Built-in DSP processes audio natively via WASAPI but still requires a virtual audio driver to route the enhanced signal to apps/games. The suite does not inject into games or manipulate game audio.
- **Frame generation:** Requires external tool (Lossless Scaling, etc.). The suite does not inject frames.
- **Network:** Cannot lower server RTT, fix ISP routing, or repair server-side packet loss.
- **Power plan:** Cloned scheme persists after uninstall; delete "Gaming Performance Suite" in Power Options if unwanted.
- **HAGS:** Registry change requires reboot; not toggled per-session.

## Performance Impact (Toolkit Overhead)

| Metric | Typical Value |
|--------|---------------|
| Idle CPU | ~0% (parks on kernel `EventWaitHandle`) |
| Gaming poll CPU | ~1-2 ms per 10 s cycle (`Get-Process` snapshot) |
| Memory | ~30-50 MB (PowerShell process) |
| Startup lag | 1-3 s (first `Add-Type` compilation) on HDD/weak CPU |
| Disk I/O | Single cached `StreamWriter` with auto-flush; log capped at ~5 MB |
| Built-in DSP (per frame) | ~0.5-2 ms per 10 ms frame on modern CPU; FFT dominates spectral suppression |

**Measured (synthetic, no audio hardware):** `Test-MicEnhancement` processed 300 frames of 48 kHz audio in 864-1847 ms (sandbox timing variation; output stable: peak 0.4508→0.0009, RMS 0.265→0.0005, gain -55.15 dB). Real-world audio latency depends on hardware, WASAPI buffer size, and CPU load.

**What the toolkit does NOT measure:** Game FPS, GPU utilization, VRAM, audio latency, speech quality. Those require in-game overlays (PresentMon, NVIDIA FrameView) or the companion tool's own diagnostics. The `FrameTimeDiagnostics` module in this suite samples frame intervals via `QueryPerformanceCounter` and logs percentiles (avg, 1% low, 0.1% low) — enable it in `Config.ps1` for troubleshooting.

## Safe Removal

1. Run `Stop-GamingSuite.bat` (restores all session state).
2. Delete the extracted folder.
3. Optional: In Power Options, delete the "Gaming Performance Suite" plan if present.
4. Optional: Remove any virtual audio drivers installed by your microphone companion tool (VB-Cable, Voicemeeter, etc.) via Device Manager or their uninstallers.
5. Optional: If using built-in DSP, any WASAPI shared-mode endpoints are released automatically when the watcher stops; no residual audio drivers remain.

No services, scheduled tasks, or startup entries are created by this suite.

## Version History

- **v3.2** — Phase 1 hardening: eliminated empty catch blocks, fixed adaptive purge cooldown bug, fixed parser errors, verified module loads. Added built-in microphone DSP pipeline (`Start-MicEnhancement` / `Stop-MicEnhancement` / `Test-MicEnhancement` / `Get-MicDevices`), crash-recovery journal tracking for `micDspStarted`, orphaned DSP recovery logging in `Repair-OrphanedWatcherState`, and mic enhancement state in `Show-Status`.
- **v3.1** — Added usage profiles (Gaming/Development/DailyUse), microphone enhancement companion bridge, low-spec auto-detection, universal watch, frame-time diagnostics, staged ramp system, crash-safe recovery journal.
- **v3.0** — Windows-only rewrite; removed cross-platform code; session-scoped watcher with auto-exit.