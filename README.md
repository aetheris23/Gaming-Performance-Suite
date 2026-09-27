# Gaming Performance Suite v3.2

A portable Windows toolkit for game-process monitoring, display scaling, and
performance diagnostics. It is built with PowerShell 5.1 and Windows components;
there are no package installs or third-party runtime dependencies.

> **Network expectations:** this suite cannot reduce the physical round-trip time
> (RTT) to an internet game server, guarantee lower ping, or repair packet loss on
> an ISP route or server. Network settings vary by adapter and driver, so this
> version leaves them unchanged by default and reports local adapter counters as
> diagnostic clues instead.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or later
- Administrator approval to run the optimization launcher and change system settings
- Administrator rights are **not** required to build the ZIP

Linux, macOS, and Android/Termux are not supported.

## Build and install

1. Download or clone this repository.
2. Run `build.bat` from the project folder, or run:

   ```bat
   powershell -NoProfile -ExecutionPolicy Bypass -File src\Build-Suite.ps1
   ```

3. The build creates `GamingPerformanceSuite.zip` in the project folder. Extract
   it to a location of your choice.
4. Run one of the generated launchers:
   - `Start-GamingSuite.bat` opens the interactive menu.
   - `Start-Watcher-Hidden.bat` starts the background game watcher.
   - `Stop-GamingSuite.bat` stops the watcher and restores journaled settings.

The launchers request Administrator approval when needed. The ZIP is a runtime
package: it contains the launchers, `src/`, `README.md`, and `.gitignore`; it does
not contain `build.bat` or `src/Build-Suite.ps1`.

## Features

- Detects configured game processes and immersive foreground windows.
- Applies per-game process profiles and optional display-resolution tiers.
- Includes low-spec detection and configurable polling/memory-pressure behavior.
- Tracks changed state in a recovery journal and restores it when a session ends
  or a later launch repairs an interrupted session.
- Displays adapter link information and samples local adapter error/discard
  counters while a monitored game is running.

The suite does not inject into, filter, spoof, or reorder game traffic. Some
optional performance settings can change system-wide or driver behavior; review
the configuration before enabling them.

## Network behavior and troubleshooting

### Safe defaults

Network monitoring is enabled by default, but registry, service, power-plan, and
network-driver changes are **disabled by default** in `src/Config.ps1`. This
avoids forcing Wi-Fi roaming behavior, disabling adapter offloads, stopping
Windows services, or restarting an active adapter without evidence that a
specific change helps that machine.

The local packet-loss watch samples Windows adapter error/discard counters about
once per minute during a game session. A counter increase can help identify a
local adapter, driver, cable, or Wi-Fi problem. These counters are not a complete
end-to-end packet-loss measurement; unchanged counters do **not** prove that
packets reached the game server, and they do not measure game RTT.

Menu option **6** shows adapter status and available counters. Option **7**
reverts network settings recorded in the recovery journal. Stop the watcher
normally with `Stop-GamingSuite.bat` to restore its session settings cleanly.

### If RTT is unstable or above 133 ms

1. Check the game's selected region/server and choose the closest suitable one.
2. Compare latency to your default gateway and the game server while idle and
   while playing. Find the gateway with `ipconfig`, then run:

   ```powershell
   ping -n 60 <default-gateway>
   ping -n 60 <game-server-IP>
   tracert <game-server-IP>
   ```

   Some game servers do not answer ICMP, so a missing ping reply is not by itself
   proof of packet loss. Prefer the game's network graph and provider diagnostics
   when available.
3. If gateway latency/loss changes too, test Ethernet, check the cable and router,
   improve Wi-Fi signal, and try a less congested Wi-Fi band/channel.
4. Pause downloads or uploads in the application that is using the connection.
   For persistent queueing under load, check whether the router supports
   Smart Queue Management (SQM), CAKE, or FQ-CoDel.
5. If the gateway is stable but the game path is not, save the timestamps and
   results and contact the ISP or game provider. A local registry tweak cannot
   repair a congested route or a distant server.

### Optional network settings

The switches below are in `src/Config.ps1` under `NetworkOptimization`. Keep
them disabled unless controlled before/after tests show a repeatable benefit.
Change one switch at a time, record results, and revert it if latency or loss
gets worse. Driver behavior differs; changes are not universal fixes.

```powershell
NetworkOptimization = @{
    Enabled                          = $true
    DisableNetworkThrottling         = $false
    RemoveBandwidthLimit             = $false
    TcpLowLatency                    = $false
    DisableNicPowerSaving            = $false
    WirelessMaxPerformance           = $false
    DisableReceiveSegmentCoalescing  = $false
    DisableLargeSendOffload          = $false
    WifiStayOnStrongest              = $false
    PauseBackgroundDownloads        = $false
    DisableInterruptModeration       = $false
    RestartChangedAdapters           = $false
    WatchLocalPacketLoss             = $true
}
```

TCP options affect TCP traffic only; they do not tune game traffic carried over
UDP. RSC and LSO are driver offload features and are not general-purpose UDP
latency switches. The `WifiStayOnStrongest` name is retained for older configs:
it selects the driver's lowest roaming aggressiveness, which may delay a handoff
to a stronger access point and is therefore opt-in. Disabling power saving can
increase power use. Pausing Delivery Optimization affects Windows Update
downloads. Driver changes may require an adapter restart, which briefly
disconnects the network; `RestartChangedAdapters` is off by default.

The old `TcpAutotuningLevel` registry write has been removed. It was not a safe
or reliable way to configure Windows TCP auto-tuning. The suite does not claim
that a TCP tweak lowers the in-game RTT baseline.

## Configuration

Edit `src/Config.ps1` to adjust the game-process list, watcher timing,
`UniversalWatch`, resolution tiers, low-spec behavior, adaptive tuning, and
`NetworkOptimization`. Use the existing values as the supported configuration
surface; back up the file before making changes.

## Safety and recovery

- Network changes are only attempted when individually enabled.
- The recovery journal records original values before each network mutation.
- A normal watcher stop restores the session state. On the next start or stop,
  an interrupted session is repaired from the journal.
- Avoid force-killing the watcher. If the PC loses power, run
  `Stop-GamingSuite.bat` after restarting Windows to trigger recovery.
- Review the log and journal under `logs/` if a restoration reports an error.

## Project layout

```text
build.bat
src/
  Build-Suite.ps1    Generates launchers and packages the runtime ZIP
  Main.ps1           Interactive menu and watcher entry point
  Config.ps1         User configuration
  Common.psm1        Logging, coordination, and recovery journal
  GameBoost.psm1     Game watcher and process profiles
  DisplayScale.psm1  Display-mode selection and restoration
  GpuDetect.psm1     GPU inventory and classification
  NetTune.psm1       Network diagnostics and opt-in settings
```
