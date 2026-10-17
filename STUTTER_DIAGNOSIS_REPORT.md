# Stutter/Frame-Pacing Diagnosis Report
## Gaming Performance Suite v3.2 Investigation

### Environment
- CPU: Intel Core i3-7020U (2C/4T, 2.3GHz, Kaby Lake)
- RAM: 16 GB
- GPU: Intel HD Graphics 620 (Integrated, shared)
- OS: Windows 10 Home Single Language 22H2 (19045.6466)
- LowSpecMode: Auto-detected ACTIVE

### Current System Load Analysis
**CPU:** 76-87% total utilization, all 4 logical cores 75-99% loaded
- Severe CPU saturation - classic bottleneck for low-power dual-core ULV CPU
- Background workloads: VS Code (9 instances, ~5440s CPU time total), Firefox, RobloxPlayerBeta, Python processes
- Committed: 70.8% of virtual memory; 5.9GB free RAM available (adequate)

**GPU:** Peak ~28%, average ~3% utilization - NOT GPU-bound. HD 620 is not the limiting factor.

**Frame Pacing:** High-res timer sampling shows deltas 34-60ms during busy desktop (vs 16.7ms for 60fps). This indicates significant scheduling jitter due to CPU contention.

### Root Causes (in order of likelihood)
1. **CPU Contention / Scheduling Jitter** (Primary) - Background dev tools (AI coding agents + VS Code + browsers) consume massive CPU on dual-core CPU. i3-7020U cannot sustain both heavy background workloads and competitive gaming without drops.
2. **Background Workload Interference** (Secondary) - Development tools/AI coding agents create frequent context switches, competing for limited CPU cores. This directly causes frame-time variance (stutter), 1% lows collapse, input latency spikes.
3. **Thermal/Power** (Possible) - ULV CPU may throttle under sustained load, though thermal throttling events not visible in recent logs; power plan handled by suite.
4. **Timer Resolution & Scheduling** (Contributing) - Without active watcher boosting game process priority and setting timer resolution, Windows scheduler gives equal time to competing processes.

### Why VALORANT combat is most affected
- Competitive shooters are CPU-sensitive (hit registration, player movement, netcode). Small frame-time spikes cause visible stutter and perceived input lag
- Combat produces bursty load; when CPU is already near 100%, any additional spike causes dropped frames/long frames
- Background AI coding agents (linting, indexing, completions, tool calls) create unpredictable CPU bursts

### Existing Mitigations in Suite
The Gaming Performance Suite already implements:
- Process priority boosting (High/AboveNormal per profile), affinity steering away from core 0
- Timer resolution (1-2ms via timeBeginPeriod) - reduces timer granularity
- Background silence (deprioritize hogs like browsers/Steam helpers)
- Adaptive tuning (RAM pressure detection, priority re-assertion every N cycles)
- LowSpecMode optimizations (reduced polling, skips heavy ops)
- VALORANT pinned to Native tier (no display scaling) to avoid mode switches
- Frame-time diagnostics infrastructure exists (QueryPerformanceCounter-based)

### Recommendations
1. **Reduce background load** - Close/limit VS Code workspaces, pause AI agents, close Firefox/tabs while gaming. Biggest impact on i3-7020U.
2. **Enable Game Boosting** - Run watcher (Start-Watcher-Hidden.bat as Admin) to apply priority/timer/background-silence during VALORANT sessions.
3. **Enable FrameTimeDiagnostics** in Gaming profile or Custom for measurement (logs avg/1%/0.1% lows). Currently disabled in Custom.
4. **Profile with active watcher** - Measure with/without background dev tools to quantify impact.
5. **Consider Development vs Gaming profile** - Development profile has FrameTimeDiagnostics enabled (good for benchmarking); Gaming profile tuned for stability.

### Verified Findings
- GPU not bottlenecked (confirmed via perf counters)
- CPU saturated by background dev/AI workloads (confirmed: 9 VS Code processes + others)
- Memory pressure not critical (6GB free)
- Suite has full instrumentation for frame pacing (infrastructure present, logging ready)
- No network diagnostics explain CPU-induced stutter (separating concerns correctly)
