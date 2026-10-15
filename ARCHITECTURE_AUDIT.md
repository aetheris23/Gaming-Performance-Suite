# Gaming Performance Suite - Architecture Audit & Microphone Enhancement Integration Analysis

**Date:** 2026-10-15  
**Version:** 3.2 (post-Phase 1 error handling fixes)  
**Repository:** E:\Projects\Desktops\Gaming-Performance-Suite

---

## <analysis>

### 1. Repository Architecture Overview

**Project Structure:**
```
Gaming-Performance-Suite/
├── src/
│   ├── Main.ps1              # Entry point (640 lines) - interactive menu + background watcher
│   ├── Config.ps1            # User configuration hashtable (395 lines)
│   ├── Common.psm1           # Shared infrastructure (580 lines) - logging, admin, mutex, recovery journal
│   ├── GameBoost.psm1        # Core watcher logic (2091 lines) - game detection, boosting, display scaling
│   ├── DisplayScale.psm1     # Dynamic resolution scaling (394 lines) - ChangeDisplaySettingsExW via DXGI
│   ├── GpuDetect.psm1        # GPU inventory & classification (594 lines) - DXGI/Registry/CIM
│   ├── NetTune.psm1          # Network latency & packet-loss profile (1250 lines) - registry/driver tweaks
│   └── Build-Suite.ps1       # Build script generating .bat launchers
├── logs/                     # Runtime logs + recovery journal (gitignored)
│   ├── runtime/
│   │   ├── watcher.pid       # Background watcher PID file
│   │   └── watcher_state.json # Recovery journal (JSON)
│   └── suite_YYYYMMDD.log    # Daily session logs
└── *.bat                     # Generated launchers (Start-GamingSuite, Start-Watcher-Hidden, Stop-GamingSuite)
```

**Module Dependencies (Import Order in Main.ps1):**
```
Common.psm1 → GpuDetect.psm1 → GameBoost.psm1 → DisplayScale.psm1 → NetTune.psm1
     ↑                                                         ↑
     └───────────────── Cross-references ──────────────────────┘
```

**Key Architectural Principles:**
- **Windows-only**: All Linux/macOS/Android branches removed to eliminate cross-platform overhead
- **Session-scoped**: Watcher auto-exits when game session ends (`ExitWhenGameSessionEnds = $true` by default)
- **Crash-safe**: Every system change is journaled to `watcher_state.json` for automatic recovery
- **Low-spec optimized**: Lazy compilation, reduced polling, skip heavy ops on weak hardware
- **Single-instance**: Kernel Mutex prevents multiple watchers; kernel EventWaitHandle for instant stop
- **Elevated-only**: All system tweaks require Admin; .bat launchers self-elevate via `net session` check

---

### 2. Programming Languages & Technologies

| Layer | Technology | Purpose |
|-------|------------|---------|
| **Scripting** | PowerShell 5.1+ | Primary language; strict mode, module system |
| **Native Interop** | C# via `Add-Type` | Win32 API calls (user32, winmm, ntdll, kernel32, advapi32, powrprof, dxgi) |
| **System APIs** | WMI/CIM (`Get-CimInstance`) | Battery, CPU, network adapter queries |
| **Serialization** | JSON (`ConvertTo-Json`/`ConvertFrom-Json`) | Recovery journal persistence |
| **Build** | .NET `ZipArchive` | Runtime package generation |

**Win32 APIs Used (via Add-Type):**
- `user32.dll`: `ChangeDisplaySettingsExW`, `GetForegroundWindow`, `GetWindowThreadProcessId`, `GetWindowRect`, `MonitorFromWindow`, `GetMonitorInfo`
- `winmm.dll`: `timeBeginPeriod`, `timeEndPeriod` (1-2ms timer resolution)
- `ntdll.dll`: `NtSetSystemInformation` (SystemMemoryListInformation=80, PurgeStandbyList=4)
- `kernel32.dll`: `QueryPerformanceCounter`, `QueryPerformanceFrequency`, `GlobalMemoryStatusEx`
- `advapi32.dll`: `OpenProcessToken`, `LookupPrivilegeValue`, `AdjustTokenPrivileges` (SeProfileSingleProcessPrivilege)
- `powrprof.dll`: `PowerActiveScheme`, `PowerReadACValueIndex` (wireless power mode)
- `dxgi.dll`: `CreateDXGIFactory1`, `EnumAdapters1`, `GetDesc1` (GPU enumeration)

---

### 3. Dependencies

**External Dependencies:**
- **Windows 10/11** (PowerShell 5.1+)
- **.NET Framework** 4.7.2+ / **.NET Core/5+** (for `Add-Type` compilation)
- **Administrator privileges** (mandatory for all system modifications)

**Internal Module Dependencies:**
```
Main.ps1
├── Common.psm1 (REQUIRED - logging, mutex, journal, admin)
├── GpuDetect.psm1 (REQUIRED - GPU classification for low-spec/legacy)
├── GameBoost.psm1 (CORE - watcher, boosting, profiles)
├── DisplayScale.psm1 (REQUIRED - resolution switching)
└── NetTune.psm1 (OPTIONAL - network profile, loaded on-demand)
```

**No third-party PowerShell modules or NuGet packages required.**

---

### 4. Build System

**Build Script:** `src/Build-Suite.ps1` (invoked via `build.bat` in repo root)

**Build Process:**
1. Creates `.build_generated/` temp directory
2. Generates 3 `.bat` launchers:
   - `Start-GamingSuite.bat` - Interactive menu (self-elevates)
   - `Start-Watcher-Hidden.bat` - Background watcher (hidden window)
   - `Stop-GamingSuite.bat` - Stops watcher via kernel event
3. Packages runtime-only ZIP:
   - **Includes:** 3 launchers, `README.md`, `.gitignore`, all `src/*.ps1/.psm1`
   - **Excludes:** `build.bat`, `src/Build-Suite.ps1` (builder never in distribution)
4. Cleans up temp directory

**Output:** `GamingPerformanceSuite.zip` (~100-200KB)

---

### 5. Graphics APIs & Rendering Pipeline Integration

**Display Scaling Mechanism (`DisplayScale.psm1`):**
- Uses `ChangeDisplaySettingsExW` with `CDS_DYNAMIC` (0x00000004) flag
- Session-only: auto-reverts on reboot even if watcher crashes
- **Mode Selection (`Select-ScaledMode`):**
  - Enumerates all display modes via `EnumDisplaySettingsExW`
  - Filters: strictly smaller width, height ≤ native, same aspect ratio (unless Stretch mode)
  - **Refresh Rate Preservation**: Only selects modes matching native Hz (or 0="driver default")
  - **Integer Scaling Preference**: Tie-breaker for exact 1/2, 1/3, 1/4 ratios
  - **Stretch Mode**: Relaxes aspect guard, sets `dmDisplayFixedOutput = DMDFO_STRETCH` (fill panel)

**GPU Detection (`GpuDetect.psm1`):**
- **Primary**: DXGI enumeration (what games actually see) - vendor/device IDs + dedicated VRAM
- **Secondary**: Registry display class (catches disabled adapters, exact VRAM)
- **Fallback**: CIM `Win32_VideoController` (last resort)
- **Classification:** Integrated / Discrete / Virtual / Unknown
- **Era Detection:** Legacy (pre-WDDM2.x) vs Modern - drives legacy-safe profile

**Frame-Generation Bridge (`GameBoost.psm1`):**
- Launches configured companion app (e.g., Lossless Scaling) alongside detected game
- Does NOT inject frames - only launches the tool that does driver-level frame insertion
- Journaled for cleanup on session end/crash

---

### 6. Windows Integration Points

| Subsystem | Integration Method | Persistence |
|-----------|-------------------|-------------|
| **Power Plans** | `powercfg` CLI + registry (`HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power`) | Persistent (cloned scheme) |
| **Game DVR/Game Bar** | Registry policies (`HKLM/HKCU\...\GameDVR`, `GameBar`) | Persistent |
| **MMCSS (Multimedia Scheduling)** | Registry (`HKLM\...\Multimedia\SystemProfile\Tasks\Games`) | Persistent |
| **HAGS (Hardware-Accelerated GPU Scheduling)** | Registry (`HKLM\...\Control\GraphicsDrivers\HwSchMode`) | Persistent (requires reboot) |
| **Timer Resolution** | `timeBeginPeriod`/`timeEndPeriod` (winmm.dll) | Session-only |
| **Standby Memory Purge** | `NtSetSystemInformation` (ntdll.dll, SystemMemoryListInformation=80) | One-shot |
| **Process Priority/Affinity** | `Process.PriorityClass`, `Process.ProcessorAffinity` (.NET) | Session-only |
| **Fullscreen Optimizations** | AppCompatFlags registry (`HKCU\...\AppCompatFlags\Layers`) | Per-game, session-only |
| **Display Resolution** | `ChangeDisplaySettingsExW` with `CDS_DYNAMIC` (user32.dll) | Session-only (auto-revert on reboot) |
| **Network Stack** | Registry (TCP/IP, QoS, NIC class keys), `Set-NetAdapter*` cmdlets | Session-only (journaled revert) |
| **Delivery Optimization** | Service control (`DoSvc`) | Session-only |
| **Wireless Power Mode** | `powercfg` + `powrprof.dll` | Session-only |
| **Single Instance** | Named Kernel Mutex (`Global\GamingPerformanceSuite_<hash>_Instance`) | Process lifetime |
| **Stop Signal** | Named Kernel EventWaitHandle (`Global\GamingPerformanceSuite_<hash>_Stop`) | Process lifetime |

---

### 7. Current Performance Limitations & Bottlenecks

**Identified Bottlenecks:**

| Area | Issue | Impact | Mitigation in Place |
|------|-------|--------|---------------------|
| **Process Snapshot** | `Get-Process` / `[Diagnostics.Process]::GetProcesses()` every poll | ~1-2ms per poll on low-spec | Pre-compiled matchers (HashSet + wildcards); single snapshot per cycle |
| **Add-Type Compilation** | C# compilation at first native call | 1-3s startup lag on HDD/weak CPU | Lazy compilation (`Add-Native*Type` functions) |
| **Display Mode Switch** | `ChangeDisplaySettingsExW` causes mode flash | Visible hitch (~200-500ms) | Staged ramp: applied during loading screen (6-10s delay) |
| **Standby Purge** | `NtSetSystemInformation` stalls memory manager | Visible hitch if mid-frame | Cooldown-gated (900s), only below critical floor, pre-launch purge |
| **WMI/CIM Queries** | `Get-CimInstance` for battery/CPU/adapter | ~50-200ms per query | Cached (30-60s TTL); only at startup or status check |
| **Log File I/O** | `Add-Content` per log line | HDD seek overhead | Single cached `StreamWriter` with `AutoFlush`; size cap with tail truncation |

**Resource Leaks (Fixed in Phase 1):**
- Process objects from `Get-Process -Id` not disposed → kernel handle leak
- Fixed: Explicit `.Dispose()` on all transient process objects per cycle

**Low-Spec Optimizations (`LowSpecMode`):**
- Skip resolution switch, standby purge, background silence, frame-gen bridge
- Reduced polling: 15s/35s/90s (vs 10s/25s/60s)
- Skip HAGS registry write
- Aggressive 1ms timer option
- CPU core limiting via affinity

---

### 8. Unnecessary Background Processes & Resource Usage

**Background Processes Created:**
1. **Game Watcher** (Main.ps1 -BackgroundWatch): Single PowerShell process
   - Priority: BelowNormal (yields to game)
   - CPU: ~0% idle (parks on kernel EventWaitHandle)
   - Memory: ~30-50MB typical
   - Exits when game session ends (default)

2. **Frame-Generation Tool** (optional): External process (e.g., LosslessScaling.exe)
   - Launched by watcher, tracked in journal, killed on session end

**No persistent services, scheduled tasks, or startup entries created.**

**What Stays After Exit (Persistent):**
- Cloned power plan ("Gaming Performance Suite")
- Game DVR disabled registry keys
- MMCSS Games priority registry keys
- HAGS registry key (if enabled)
- Network registry tweaks (only if applied via menu option 1 without watcher)

**All session-scoped changes are reverted on watcher stop/crash recovery.**

---

### 9. Integration Requirements for Microphone Enhancement Module

**Proposed Module:** `MicEnhance.psm1` - Lightweight microphone audio processing

**Integration Architecture:**

```
Main.ps1
    │
    ├── Import-Module MicEnhance.psm1 (lazy, on-demand)
    │
    ├── Config.ps1 additions:
    │   MicrophoneEnhancement = @{
    │       Enabled = $false
    │       ToolPath = ''              # e.g., 'C:\Tools\MicEnhance\MicEnhance.exe'
    │       Profile = 'Default'        # 'VoiceFocus' | 'NoiseSuppression' | 'Custom'
    │       AutoLaunchWithGame = $true # Launch when game detected
    │       RestoreOnExit = $true      # Stop tool when watcher stops
    │   }
    │
    └── GameBoost.psm1 integration:
        ├── Start-GameWatcher parameter: -MicEnhanceSettings @{...}
        ├── Ramp stage: 'micenhance' (delay ~1-2s after game detect)
        ├── Journal entries: micToolPid, micLaunchedByUs
        └── Cleanup: Stop-MicEnhanceTool in finally block
```

**Design Requirements for Lightweight Integration:**

| Requirement | Implementation |
|-------------|----------------|
| **Zero idle overhead** | Lazy import; only compile/load when `Enabled=$true` |
| **No audio pipeline injection** | Launch companion tool (like frame-gen bridge), don't process audio in PowerShell |
| **Crash-safe** | Journal mic tool PID; auto-kill orphaned process on recovery |
| **Anti-cheat safe** | Never touch game processes; only launch user-space audio tool |
| **Session-scoped** | Start with game detect, stop when last game exits (honor `ExitWhenGameSessionEnds`) |
| **Config-driven** | All settings in Config.ps1; no code changes for users |
| **Low-spec friendly** | Respect `LowSpecMode.SkipFrameGenBridge` equivalent flag |

**Proposed Native Interop (if needed for advanced features):**
- `AudioClient` / `IAudioCaptureClient` (Windows Audio Session API - WASAPI) for direct capture
- `rnnoise` / `RNNoise` via P/Invoke for noise suppression (if embedding)
- **Recommendation:** Avoid native audio processing in PowerShell; launch dedicated tool instead

**Integration Points in Existing Code:**

1. **Main.ps1** (lines 196-248 `Invoke-Watcher`):
   - Add `$micCfg` config resolution (like `$fgSettings`)
   - Pass to `Start-GameWatcher`

2. **GameBoost.psm1** (Start-GameWatcher):
   - Add `-MicEnhanceSettings` parameter
   - Add `$micByUs`, `$micPid` tracking variables
   - Add `Add-Ramp 'micenhance' 1.5 $game.Id` in detection block
   - Add `Invoke-MicEnhanceTool` / `Stop-MicEnhanceTool` functions
   - Handle in ramp `switch` (like `'extras'` case)
   - Journal `$journal['micToolPid']` and `$journal['micLaunchedByUs']`
   - Cleanup in `finally` block

3. **Common.psm1** (Recovery Journal):
   - `Repair-OrphanedWatcherState` → add mic tool cleanup (kill orphaned PID)

---

## <summary>

### Executive Summary

The **Gaming Performance Suite v3.2** is a **Windows-only, PowerShell 5.1+ modular performance optimization toolkit** designed for FPS stability in games. It uses a **session-scoped background watcher** that auto-detects games, applies optimizations (priority, affinity, timer resolution, display scaling, standby purge), and **fully reverts all changes on exit or crash** via a JSON recovery journal.

### Key Architectural Strengths

1. **Crash-Safe Design**: Every system change is journaled atomically; `Repair-OrphanedWatcherState` restores state on next start
2. **Zero Idle Overhead**: Watcher parks on kernel `EventWaitHandle` (~0% CPU); 3-tier adaptive polling (10s/25s/60s)
3. **Low-Spec First**: Auto-detects weak hardware (legacy GPU + low cores/clock); enables reduced mode automatically
4. **Stutter-Free Ramp**: Heavy ops (display switch, standby purge) staged during game loading screens
5. **Anti-Cheat Safe**: Hard-coded never-watch lists for Vanguard, BattlEye, EAC, launchers
6. **Universal Watch**: Detects ANY immersive foreground window (borderless games, video players) without hardcoded names

### Critical Integration Points for Microphone Enhancement

| Integration Layer | Location | Pattern to Follow |
|-------------------|----------|-------------------|
| **Config** | `Config.ps1` | Add `MicrophoneEnhancement` hashtable (like `FrameGeneration`) |
| **Entry Point** | `Main.ps1:Invoke-Watcher` | Resolve config → pass to watcher (like `$fgSettings`) |
| **Watcher Core** | `GameBoost.psm1:Start-GameWatcher` | Add param, ramp stage, journal fields, cleanup in `finally` |
| **Launch Tool** | `GameBoost.psm1` | Add `Invoke-MicEnhanceTool`/`Stop-MicEnhanceTool` (mirror frame-gen) |
| **Recovery** | `Common.psm1:Repair-OrphanedWatcherState` | Add mic tool PID cleanup |

### Recommended Implementation Approach

1. **Phase 1**: Add `MicEnhance.psm1` with `Invoke-MicEnhanceTool`/`Stop-MicEnhanceTool` (mirroring frame-gen bridge pattern)
2. **Phase 2**: Integrate into `Config.ps1`, `Main.ps1`, `GameBoost.psm1` ramp system
3. **Phase 3**: Add recovery journal handling in `Common.psm1`
4. **Phase 4**: Test with `LowSpecMode` flag to skip on weak hardware

### Risk Assessment

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Audio tool conflicts with game anti-cheat | Low | Launch only user-space tool; never inject into game process |
| Microphone access permission prompts | Medium | Document requirement; tool should handle gracefully |
| Additional CPU overhead on low-spec | Low | Respect `LowSpecMode` skip flag; launch during loading screen |
| Recovery journal bloat | Low | Single PID entry; cleaned on session end |

---

**Conclusion:** The architecture is **highly modular and extensible**. The frame-generation bridge pattern in `GameBoost.psm1` provides a **proven template** for integrating a microphone enhancement companion tool with zero idle overhead, crash-safe journaling, and session-scoped lifecycle management. The integration requires ~50-80 lines of new code across 3 files, following existing patterns exactly.