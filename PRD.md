# Product Requirements Document (PRD)
**Project:** Gaming Performance Suite  
**Version:** 3.2  
**Date:** 2026-10-24  
**Status:** Implementation-ready  
**Author:** Engineering Team  

---

## 1. Product Vision
Gaming Performance Suite is a portable, reversible Windows toolkit that improves gaming stability and frame pacing on constrained hardware (primarily Intel Core i3-7020U + 16 GB RAM + Intel HD Graphics 620) while remaining safe, transparent, and user-controllable. The product prioritizes evidence-based optimizations with full undo/rollback capabilities and minimal system footprint.

---

## 2. Target Users
- **Competitive gamers** on low/mid-spec hardware seeking more stable frame pacing in titles like VALORANT, CS2, League of Legends
- **Power users** running background workloads (VS Code, AI coding agents, browsers) while gaming
- **Users with limited hardware resources** needing intelligent resource management without hardware upgrades
- **System administrators/power users** requiring reversible, auditable system optimizations

---

## 3. Supported Platforms & Hardware
### Supported Windows Versions
- Windows 10 (22H2+ recommended)
- Windows 11 (current supported releases)
- PowerShell 5.1+ required

### Hardware Targets
- **Primary target:** Intel Core i3-7020U (2C/4T), 16 GB RAM, Intel HD Graphics 620 (Integrated)
- **Secondary:** Other x86_64 Windows systems with varying GPU configurations
- **Low-spec detection:** Automatic detection of legacy GPUs and weak modern iGPUs

### Limitations
- Linux, macOS, Android/Termux not supported
- Administrator privileges required for system-level optimizations
- Anti-cheat compatible (never touches protected processes/services)

---

## 4. Architecture
### Core Components
| Module | Purpose | Dependencies |
|--------|---------|-------------|
| `Main.ps1` | Entry point, menu, watcher orchestration | All modules |
| `Common.psm1` | Logging, mutex, recovery journal, admin checks | Base utilities |
| `GameBoost.psm1` | Game detection, process boosting, ramp system, companion bridges | Common, GpuDetect, DisplayScale |
| `DisplayScale.psm1` | Resolution scaling via ChangeDisplaySettingsExW | Common |
| `GpuDetect.psm1` | GPU inventory, classification, era detection | Common |
| `NetTune.psm1` | Network diagnostics and opt-in tuning | Common |
| `MicEnhance.psm1` | Audio enhancement (companion + built-in DSP) | Common |
| `Config.ps1` | User configuration and profiles | All |

### Design Principles
- **Reversibility:** All session changes journaled to JSON; auto-restored on exit/crash
- **Session-scoped:** Optimizations apply only while gaming/session active
- **Zero idle overhead:** Watcher parks on kernel events; minimal CPU when idle
- **Opt-in by default:** Risky features disabled unless explicitly enabled
- **Evidence-based:** No speculative registry tweaks without justification

---

## 5. Functional Requirements

### 5.1 Game Detection & Boosting (MUST)
- **FR-001:** Detect configured game processes (VALORANT, CS2, Roblox, Steam games, etc.)
- **FR-002:** Apply per-game process profiles (priority, CPU affinity steering)
- **FR-003:** Set high-resolution timer (1-2ms) during gaming sessions
- **FR-004:** Deprioritize background hogs while game is running
- **FR-005:** Auto-restore all changes on game exit/session end

### 5.2 Display Optimization (MUST)
- **FR-006:** Dynamic resolution scaling with same-aspect preservation
- **FR-007:** Integer scaling preference option
- **FR-008:** Stretch mode for ultrawide/legacy aspect ratios
- **FR-009:** Native resolution restoration guaranteed

### 5.3 Performance Profiles (MUST)
- **FR-010:** Support Gaming, Development, DailyUse, Custom profiles
- **FR-011:** Auto-apply profile based on ActiveProfile setting
- **FR-012:** Profile-specific polling rates, features, and optimizations

### 5.4 Network Diagnostics & Tuning (MUST)
- **FR-013:** Read-only network diagnostics (gateway, external ping, link status)
- **FR-014:** Distinguish ICMP failures from game packet loss
- **FR-015:** Local adapter packet loss monitoring (evidence-based)
- **FR-016:** Opt-in network tuning only with explicit authorization
- **FR-017:** Full rollback of all network changes

### 5.5 Microphone Enhancement (MUST)
- **FR-018:** Companion tool bridge mode (launch external tool)
- **FR-019:** Built-in WASAPI DSP pipeline (gain, noise gate, FFT suppression, compressor, limiter, AGC)
- **FR-020:** Configurable per-parameter DSP settings
- **FR-021:** Audio processing non-blocking to graphics/rendering
- **FR-022:** Independent enable/disable per subsystem

### 5.6 Installation & Lifecycle (MUST)
- **FR-023:** Build process generates runtime-only package
- **FR-024:** Safe installation with shortcuts
- **FR-025:** Optional auto-start at user sign-in
- **FR-026:** Complete uninstall removes only app-owned components
- **FR-027:** Crash recovery from journal

### 5.7 Optional Features (SHOULD)
- **FR-028:** Frame generation companion bridge
- **FR-029:** Frame-time diagnostics with percentiles
- **FR-030:** Adaptive memory pressure tuning
- **FR-031:** Universal window watch mode

---

## 6. Non-Functional Requirements

### 6.1 Performance (MUST)
| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| Idle CPU overhead | < 0.5% | Task Manager/PerfMon during idle |
| Memory usage (watcher) | < 60 MB | Process memory monitoring |
| Startup time | < 5 seconds | Time to menu ready |
| Timer resolution latency | < 2ms | winmm timeBeginPeriod active |
| Audio DSP latency | 10-20ms | Built-in pipeline target |

### 6.2 Reliability (MUST)
- **NFR-001:** No orphaned processes after clean shutdown
- **NFR-002:** No orphaned scheduled tasks/services/drivers
- **NFR-003:** Crash recovery works on next start
- **NFR-004:** All changes reversible
- **NFR-005:** Mutex prevents multiple watcher instances

### 6.3 Security & Privacy (MUST)
- **NFR-006:** No game memory injection/modification
- **NFR-007:** No anti-cheat bypass attempts
- **NFR-008:** No telemetry or external data collection
- **NFR-009:** No silent network/service changes
- **NFR-010:** Logs stay local in `logs/` directory

### 6.4 Compatibility (MUST)
- **NFR-011:** Works on Intel HD Graphics 620
- **NFR-012:** Respects low-spec hardware constraints
- **NFR-013:** No interference with anti-cheat protected games
- **NFR-014:** PowerShell 5.1 compatible

---

## 7. User Experience
### Primary Flows
1. **Quick Start:** Extract ZIP → Run Start-GamingSuite.bat → Select option 3 to start watcher
2. **Gaming:** Launch game → Watcher auto-detects → Applies optimizations → Auto-restores on exit
3. **Diagnostics:** Menu option 6 shows status, network diagnostics available
4. **Configuration:** Edit Config.ps1 for customization

### UX Principles
- Transparent operation with clear logging
- Minimal user interaction required
- Safe defaults (conservative, reversible)
- Clear warnings for risky operations

---

## 8. Risk Assessment

| Risk | Severity | Mitigation | Status |
|------|----------|------------|--------|
| Timer resolution not released on crash | High | Journal tracks timer state; recovery restores | Mitigated |
| Process affinity causes issues | Medium | Only change if drifted; reversible per-session | Mitigated |
| Network changes break connectivity | High | Opt-in only, full rollback, no persistent changes by default | Mitigated |
| Driver conflicts | High | No drivers installed, only registry settings with rollback | Mitigated |
| Anti-cheat false positives | Critical | Never touch protected processes, read-only where possible | Mitigated |

---

## 9. Phased Roadmap

### Phase 1: Foundation (Complete)
- [x] Core architecture and modules
- [x] Game detection and boosting
- [x] Display scaling
- [x] Recovery journal system
- [x] Build system

### Phase 2: Diagnostics & Audio (Complete)
- [x] Network diagnostics (read-only)
- [x] Frame-time diagnostics infrastructure
- [x] Built-in microphone DSP pipeline
- [x] Companion bridges

### Phase 3: Packaging & Polish (Complete)
- [x] Installer script (Inno Setup)
- [x] Auto-start support
- [x] Uninstall documentation
- [x] Shortcut creation

### Phase 4: Future Enhancements (Planned)
- [ ] GUI frontend (optional)
- [ ] Enhanced telemetry dashboard
- [ ] Additional game profiles
- [ ] Tray icon application

---

## 10. Testing Strategy

### Unit Testing
- Module import validation
- Configuration parsing
- Helper function correctness

### Integration Testing
- Full build process
- Watcher start/stop lifecycle
- Game detection simulation
- Recovery from simulated crash

### Hardware Testing
- Intel HD Graphics 620 validation
- Low-spec mode behavior
- Timer resolution verification
- Process boosting on target hardware

### Regression Testing
- Ensure existing functionality preserved
- Verify all rollback paths
- Check for resource leaks

---

## 11. Release Criteria
- [x] All modules load without errors
- [x] Build produces valid runtime package
- [x] No syntax errors in PowerShell
- [x] Recovery journal system functional
- [x] All changes reversible
- [x] Documentation complete
- [x] Security requirements met

---

## 12. Known Limitations
- PowerShell-based (some overhead vs native)
- Requires admin for system tweaks
- Cannot fix ISP routing/bufferbloat (can only diagnose)
- Display scaling limited by GPU/driver capabilities
- Built-in mic DSP has higher latency than professional tools
- Cannot measure in-game FPS directly (use external tools)

---

## 13. Acceptance Criteria
| Category | Criteria | Verification |
|----------|----------|--------------|
| **CPU Usage** | < 2% during active gaming polls, < 0.5% idle | Process monitor |
| **RAM Usage** | < 60MB for watcher process | Task Manager |
| **Startup** | Menu loads < 5s from launch | Manual timing |
| **Frame Pacing** | Timer resolution locked at 1-2ms when gaming | Diagnostic logging |
| **Network** | Diagnostics provide accurate gateway/external measurements | Test-NetworkDiagnostics |
| **Audio** | DSP processes without blocking render thread | Test-MicEnhancement passes |
| **Stability** | No crashes in normal operation, clean shutdown | Extended testing |
| **Install/Uninstall** | Clean install/removal, no orphans | Manual verification |

---

**Document Status:** Approved for implementation. All requirements traced to existing codebase functionality.
