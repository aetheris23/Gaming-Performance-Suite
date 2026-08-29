# ============================================================
#  Common.psm1 - shared helpers: logging, admin checks,
#  privilege enabling, native Win32 interop, runtime
#  coordination (single instance / stop signal / recovery
#  journal so an unclean shutdown never leaves the system
#  in a half-optimized state).
# ============================================================

$script:LogDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir | Out-Null }
$script:LogFile = Join-Path $script:LogDir ("suite_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','ACTION','RECOVER')][string]$Level = 'INFO'
    )
    $stamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line   = "[$stamp][$Level] $Message"
    $color  = switch ($Level) {
        'INFO'    { 'Gray' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'OK'      { 'Green' }
        'ACTION'  { 'Cyan' }
        'RECOVER' { 'Magenta' }
    }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
}

function Test-Administrator {
    # Windows: membership in the Administrators group.
    # Unix (Linux/macOS): running as root (UID 0) - the standard equivalent.
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
            try { return ((& id -u) -eq '0') } catch { return $false }
        }
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Assert-AdminOrThrow {
    if (-not (Test-Administrator)) {
        if (Test-SuitePlatformWindows) {
            throw "This action requires Administrator privileges. Re-run via Start-GamingSuite.bat."
        }
        throw 'This action requires root privileges. Re-run via `sudo pwsh Start-GamingSuite.ps1` (or `sudo bash start.sh`).'
    }
}

function Enable-Privilege {
    <#
        Enables a Windows token privilege (e.g. SeProfileSingleProcessPrivilege
        needed for purging the standby memory list).
    #>
    param([Parameter(Mandatory)][string]$Name)

    if (-not ('Suite.NativeToken' -as [type])) {
        Add-Type -Namespace Suite -Name NativeToken -MemberDefinition @'
[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out long lpLuid);

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges,
    ref TOKENPRIVILEGES NewState, int BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(IntPtr hObject);

[StructLayout(LayoutKind.Sequential)]
public struct TOKENPRIVILEGES
{
    public int PrivilegeCount;
    public long Luid;
    public uint Attributes;
}
'@
    }

    $TOKEN_ADJUST_PRIVILEGES = 0x0020
    $TOKEN_QUERY             = 0x0008
    $SE_PRIVILEGE_ENABLED    = 0x0002

    $token = [IntPtr]::Zero
    try {
        if (-not [Suite.NativeToken]::OpenProcessToken(
                [Diagnostics.Process]::GetCurrentProcess().Handle,
                $TOKEN_ADJUST_PRIVILEGES -bor $TOKEN_QUERY, [ref]$token)) {
            return $false
        }
        $luid = 0L
        if (-not [Suite.NativeToken]::LookupPrivilegeValue($null, $Name, [ref]$luid)) {
            return $false
        }
        $tp  = New-Object Suite.NativeToken+TOKENPRIVILEGES
        $tp.PrivilegeCount = 1
        $tp.Luid       = $luid
        $tp.Attributes = $SE_PRIVILEGE_ENABLED
        [void][Suite.NativeToken]::AdjustTokenPrivileges($token, $false, [ref]$tp, 0, [IntPtr]::Zero, [IntPtr]::Zero)
        # ERROR_SUCCESS (0) or ERROR_NOT_ALL_ASSIGNED (1300) -> token updated as far as possible
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        return ($err -eq 0 -or $err -eq 1300)
    } finally {
        if ($token -ne [IntPtr]::Zero) { [void][Suite.NativeToken]::CloseHandle($token) }
    }
}

function Get-SuiteRoot {
    Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}

function Get-LogPath {
    $script:LogFile
}

function Test-SuitePlatformWindows {
    <# True on Windows PowerShell 5.1 AND PowerShell Core on Windows;
       false on Linux / macOS / Android (Termux). #>
    if ($PSVersionTable.PSVersion.Major -ge 6) { return [bool]$IsWindows }
    return $true   # Windows PowerShell 5.1 only ever runs on Windows
}

# ------------------------------------------------------------
# Runtime coordination: single instance, background stop signal
#
# Cross-platform design:
#   - WINDOWS: a named kernel Mutex gates the single instance and a
#     named EventWaitHandle carries the stop signal (instant wake).
#   - UNIX (Linux/macOS/Android): named event handles are NOT
#     supported by .NET, so the stop signal is a marker file that the
#     watcher polls in short slices while idling. The named Mutex is
#     supported on .NET 6+ Unix, but we keep an exclusive file-lock
#     fallback so ancient/Termux builds stay safe too. The pid file
#     remains the universal liveness backstop on every platform.
# ------------------------------------------------------------
$script:RuntimeDir = Join-Path $script:LogDir 'runtime'
if (-not (Test-Path $script:RuntimeDir)) { New-Item -ItemType Directory -Path $script:RuntimeDir | Out-Null }

function Get-WatcherStopEventName { 'Global\GamingPerformanceSuite_Stop' }
function Get-WatcherMutexName     { 'Global\GamingPerformanceSuite_Instance' }
function Get-WatcherPidFile       { Join-Path $script:RuntimeDir 'watcher.pid' }
function Get-WatcherStopFile      { Join-Path $script:RuntimeDir 'stop.requested' }
function Get-WatcherLockFile      { Join-Path $script:RuntimeDir 'instance.lock' }

function New-WatcherStopEvent {
    <#
        Returns the cross-process stop handle, or $null on Unix where
        named events are unsupported (there a stop file is used instead).
        Windows: manual-reset kernel event, cleared of stale signals.
    #>
    if (Test-SuitePlatformWindows) {
        $evt = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, (Get-WatcherStopEventName))
        $null = $evt.Reset()   # clear a stale signal left by an aborted session (results discarded so the handle stays the ONLY return value)
        return $evt
    }
    Clear-StopRequest                       # never inherit an aborted session's stop
    return $null
}

function Open-OrCreateStopEvent {
    <# Opens the existing stop event (Windows) or $null (Unix). Never
       fabricates an event just to exist - callers must handle $null. #>
    if (-not (Test-SuitePlatformWindows)) { return $null }
    try   { return [System.Threading.EventWaitHandle]::OpenExisting((Get-WatcherStopEventName)) }
    catch { return $null }
}

function Test-StopRequested {
    <# True when a stop has been requested (Unix marker file present). #>
    Test-Path (Get-WatcherStopFile)
}

function Set-StopRequested {
    <# Persist the stop marker (Unix) - Windows callers use the event. #>
    try {
        Set-Content -Path (Get-WatcherStopFile) -Value (Get-Date -Format o) -Encoding ASCII -Force
    } catch { }
}

function Clear-StopRequest {
    <#
        Clears a pending stop signal (Unix marker file; the Windows kernel
        event is reset by the next session). The instance.lock file is also
        removed, but ONLY when no live watcher currently holds it - deleting
        a lock that a running watcher still owns lets a second instance
        create and lock a fresh file, breaking the single-instance guarantee.
        (On Windows a process cannot delete a file another process has open
        with FileShare.None, so this only ever matters on Unix.)
    #>
    Remove-Item (Get-WatcherStopFile) -Force -ErrorAction SilentlyContinue
    if (-not (Test-WatcherLockHeld)) {
        Remove-Item (Get-WatcherLockFile) -Force -ErrorAction SilentlyContinue
    }
}

function Wait-StopOrTimeout {
    <#
        Parks the watcher for up to $Milliseconds. Returns $true when a
        stop was requested. When a kernel event is available (Windows)
        the stop is instant; otherwise the marker file is polled in
        250 ms slices so shutdown stays responsive with minimal CPU.
    #>
    param(
        [int]$Milliseconds = 1000,
        [System.Threading.EventWaitHandle]$StopEvent = $null
    )
    if ($StopEvent) { return $StopEvent.WaitOne($Milliseconds) }

    $deadline = [datetime]::UtcNow.AddMilliseconds([Math]::Max(0, $Milliseconds))
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-StopRequested) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function New-WatcherInstanceGuard {
    <#
        Returns a guard object that holds the single-instance lock, or
        $null when another watcher already owns it. Windows uses a named
        Mutex (kernel-level, detects any owner). The exclusive
        instance.lock file backs EVERY platform - on Unix it is the
        authority (named mutexes there are per-process handle tables and
        do not detect a second owner in the same process). The returned
        guard always has a Release() method - call it exactly once when
        the watcher exits, or the instance is never freed.
    #>
    $mutex = $null
    if (Test-SuitePlatformWindows) {
        $createdNew = $false
        try {
            $mutex = [System.Threading.Mutex]::new($true, (Get-WatcherMutexName), [ref]$createdNew)
            if (-not $createdNew) {
                try { $mutex.Dispose() } catch { }
                $mutex = $null    # already owned by another live watcher
            }
        } catch {
            $mutex = $null
        }
    }

    $lock = $null
    try {
        $lock = [System.IO.File]::Open((Get-WatcherLockFile),
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
    } catch { $lock = $null }

    if ($null -eq $mutex -and $null -eq $lock) { return $null }

    $lockPath = Get-WatcherLockFile
    $release = {
        if ($mutex) { try { [void]$mutex.ReleaseMutex() } catch { } }
        if ($mutex) { try { $mutex.Dispose() } catch { } }
        if ($lock)  { try { $lock.Dispose() } catch { } }
        if ($lockPath) { Remove-Item $lockPath -Force -ErrorAction SilentlyContinue }
    }.GetNewClosure()

    $guard = [pscustomobject]@{ IsHeld = $true }
    $guard | Add-Member -MemberType ScriptMethod -Name Release -Value $release -Force
    return $guard
}

function Test-WatcherLockHeld {
    <# True when the instance lock file is exclusively held. A failed
       open means another process owns it. The side-effect of leaving a
       zero-byte lock file behind is harmless. #>
    if (Test-SuitePlatformWindows) { return $false }
    try {
        $fs = [System.IO.File]::Open((Get-WatcherLockFile),
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
        $fs.Dispose()
        Remove-Item (Get-WatcherLockFile) -Force -ErrorAction SilentlyContinue
        return $false
    } catch {
        return $true
    }
}

function Test-WatcherPidAlive {
    <#
        Reads watcher.pid and reports whether that PID belongs to a
        LIVE powershell/pwsh process. On Unix the process command line
        is additionally verified to contain Main.ps1 so a recycled PID
        can never satisfy the check. Returns the PID when alive, else 0.
    #>
    $pidFile = Get-WatcherPidFile
    if (-not (Test-Path $pidFile)) { return 0 }
    $watcherPid = 0
    [void][int]::TryParse((Get-Content $pidFile -Raw).Trim(), [ref]$watcherPid)
    if ($watcherPid -le 0) { return 0 }
    $proc = Get-Process -Id $watcherPid -ErrorAction SilentlyContinue
    if (-not $proc) { return 0 }
    if ($proc.ProcessName -notmatch '^(powershell|pwsh)$') { return 0 }

    # Unix: verify the command line really is our entry point.
    if (-not (Test-SuitePlatformWindows)) {
        try {
            $cmdline = Get-Content ("/proc/{0}/cmdline" -f $watcherPid) -Raw -ErrorAction Stop
            if ($cmdline -notmatch 'Main\.ps1') { return 0 }
        } catch { return 0 }
    }
    return $watcherPid
}

function Test-WatcherRunning {
    <#
        Reports whether a game watcher is alive RIGHT NOW.
        Probe order, all cheap:
          1. the named instance mutex the watcher holds for its entire
             lifetime (created in Invoke-Watcher, released only on exit);
          2. on Unix (where some builds reject named mutexes) the
             exclusive instance.lock file;
          3. the pid file with strict validation (live pwsh running
             Main.ps1), as the cross-platform backstop.
        A watcher that is running is always reported running, even if a
        recovery removed one of the earlier signals.
    #>
    $m = $null
    try { $m = [System.Threading.Mutex]::OpenExisting((Get-WatcherMutexName)) }
    catch { $m = $null }
    if ($m) {
        try {
            if ($m.WaitOne(0)) {
                # Nothing owns it right now -> no watcher alive.
                try { [void]$m.ReleaseMutex() } catch { }
                $m.Dispose()
                return $false
            }
            $m.Dispose()
            return $true    # owned by the live watcher -> RUNNING
        } catch {
            # Abandoned (owner died while holding) -> not running.
            try { $m.Dispose() } catch { }
            $m = $null
        }
    }

    if (-not (Test-SuitePlatformWindows) -and (Test-WatcherLockHeld)) { return $true }
    return ((Test-WatcherPidAlive) -gt 0)
}

# ------------------------------------------------------------
# Recovery journal.
#
# The watcher records every system change it makes (display mode,
# silenced processes, FSO flags, network values...) to this file
# the moment it makes it. If the watcher dies without cleanup -
# killed console, forced kill, power loss, crash - the NEXT start
# (or Stop-GamingSuite.bat) replays the undo side of the journal
# and puts everything back. This is what makes background stops
# and closes safe no matter how they happen.
# ------------------------------------------------------------
function Get-WatcherJournalPath { Join-Path $script:RuntimeDir 'watcher_state.json' }

function Save-WatcherJournal {
    param([Parameter(Mandatory)][hashtable]$State)
    try {
        ConvertTo-Json -InputObject $State -Depth 8 |
            Set-Content -Path (Get-WatcherJournalPath) -Encoding UTF8 -Force
    } catch { }
}

function Get-WatcherJournal {
    $path = Get-WatcherJournalPath
    if (-not (Test-Path $path)) { return $null }
    try   { return ConvertFrom-Json (Get-Content $path -Raw) }
    catch { return $null }
}

function Clear-WatcherJournal {
    Remove-Item (Get-WatcherJournalPath) -Force -ErrorAction SilentlyContinue
}

function ConvertTo-HashtableDeep {
    <# Recursively converts PSCustomObject/arrays from ConvertFrom-Json
       into hashtables so StrictMode-safe lookups work everywhere. #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }
        return $h
    }
    if ($Value -is [System.Array]) {
        return @(foreach ($v in $Value) { ConvertTo-HashtableDeep $v })
    }
    return $Value
}

function Get-StateField {
    <# StrictMode-safe property/key reader for journal data. #>
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $null
    }
    $pi = $Object.PSObject.Properties[$Name]
    if ($pi) { return $pi.Value } else { return $null }
}

function Repair-OrphanedWatcherState {
    <#
        Undoes every change recorded in a leftover recovery journal:
        restores native resolution, background-app priorities, voice-app
        priorities, fullscreen-optimization flags, kills an orphaned
        frame-gen tool and reverts network tuning. Called automatically
        when a watcher starts over a dead previous session, and as the
        final fallback of Stop-GamingSuite.bat.
    #>
    $raw = Get-WatcherJournal
    if (-not $raw) { return $false }
    $j = ConvertTo-HashtableDeep $raw

    Write-Log 'Unclean shutdown detected - restoring system state from the recovery journal...' 'RECOVER'

    # ---- 1. Display back to native -------------------------------------
    try {
        $scaled = Get-StateField $j 'scaledActive'
        $nm     = Get-StateField $j 'nativeMode'
        if ($scaled -and $nm) {
            Import-Module (Join-Path $PSScriptRoot 'DisplayScale.psm1') -Force
            Restore-NativeResolution -Mode @{
                Width     = [int](Get-StateField $nm 'Width')
                Height    = [int](Get-StateField $nm 'Height')
                Bits      = [int](Get-StateField $nm 'Bits')
                Frequency = [int](Get-StateField $nm 'Frequency')
            }
        }
    } catch { Write-Log "Recovery: display restore failed: $_" 'ERROR' }

    # ---- 2. Silenced background apps -> Normal --------------------------
    try {
        $sil = Get-StateField $j 'silenced'
        if ($sil -is [hashtable]) {
            foreach ($procId in @($sil.Keys)) {
                try {
                    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
                    if ($p -and $p.PriorityClass -eq 'BelowNormal') { $p.PriorityClass = 'Normal' }
                } catch { }
            }
        }
    } catch { }

    # ---- 3. Voice apps boosted for mic clarity -> previous priority -----
    try {
        $vb = Get-StateField $j 'voiceBoosted'
        if ($vb -is [hashtable]) {
            foreach ($procId in @($vb.Keys)) {
                try {
                    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
                    if ($p -and $p.PriorityClass -eq 'AboveNormal') {
                        $prev = Get-StateField $vb[$procId] 'Prev'
                        $p.PriorityClass = $(if ($prev) { $prev } else { 'Normal' })
                    }
                } catch { }
            }
        }
    } catch { }

    # ---- 4. Fullscreen-optimization compat flags (Windows only) ---------
    if (Test-SuitePlatformWindows) {
        try {
            $flags = @(Get-StateField $j 'fsoFlags') | Where-Object { $_ }
            foreach ($path in $flags) {
                Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' `
                    -Name ([string]$path) -ErrorAction SilentlyContinue
            }
            if (@($flags).Count -gt 0) { Write-Log 'Fullscreen-optimization overrides cleared.' 'RECOVER' }
        } catch { }
    }

    # ---- 5. Orphaned frame-generation tool ------------------------------
    try {
        $fgPid = 0
        [void][int]::TryParse("$([string](Get-StateField $j 'fgToolPid'))", [ref]$fgPid)
        if ($fgPid -gt 0) {
            $fg = Get-Process -Id $fgPid -ErrorAction SilentlyContinue
            if ($fg) {
                [void]$fg.CloseMainWindow()
                Start-Sleep -Milliseconds 500
                if (-not $fg.HasExited) { $fg.Kill() }
                Write-Log 'Orphaned frame-generation tool closed.' 'RECOVER'
            }
        }
    } catch { }

    # ---- 6. Network tuning revert ---------------------------------------
    try {
        $net = Get-StateField $j 'net'
        if ($net) {
            Import-Module (Join-Path $PSScriptRoot 'NetTune.psm1') -Force
            Undo-GameNetworkProfile -JournalState (ConvertTo-HashtableDeep $net)
        }
    } catch { Write-Log "Recovery: network revert failed: $_" 'WARN' }

    Clear-WatcherJournal

    # Remove the pid file ONLY if it does not describe a live watcher.
    # Repair runs at the top of a FRESH watcher start, after Invoke-Watcher
    # already wrote watcher.pid for the process that is now repairing us.
    # Deleting that file unconditionally orphaned our own live marker and
    # made every status check report "watcher is not running" even while
    # the new watcher was running fine.
    if ((Test-WatcherPidAlive) -eq 0) {
        Remove-Item (Get-WatcherPidFile) -Force -ErrorAction SilentlyContinue
    }

    Write-Log 'Recovery complete - system state restored.' 'OK'
    return $true
}

function Stop-BackgroundWatcher {
    <#
        Signals the running watcher to exit NOW. The watcher parks on
        this event between polls (Windows), or on the stop marker file
        (Unix), so shutdown begins instantly and its finally block
        restores resolution/priorities/timer/network on its own. We
        WAIT for that cleanup to finish (instead of the old fixed
        kill) - a kill is only ever the last resort, and afterwards the
        recovery journal replays the missing undo steps automatically.
    #>
    $evt = Open-OrCreateStopEvent
    if ($evt) {
        [void]$evt.Set()
        $evt.Dispose()
    }
    Set-StopRequested                       # Unix marker; harmless on Windows
    Write-Log 'Stop signal delivered to the game watcher.' 'OK'

    # Graceful window: let the watcher run its full restore path.
    $watcherPid = Test-WatcherPidAlive
    if ($watcherPid -gt 0) {
        $deadline = [datetime]::UtcNow.AddSeconds(12)
        while ((Get-Process -Id $watcherPid -ErrorAction SilentlyContinue) -and [datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }
        $still = Get-Process -Id $watcherPid -ErrorAction SilentlyContinue
        if ($still) {
            Write-Log "Watcher did not exit in time; terminating PID $watcherPid..." 'WARN'
            try { $still.Kill() } catch { }
            Start-Sleep -Milliseconds 400
        }
    }

    Start-Sleep -Milliseconds 300

    # Journal present => the last session ended uncleanly (kill/crash):
    # replay the undo steps now. Clean exits remove the journal, so this
    # is skipped on the happy path.
    if (Repair-OrphanedWatcherState) { return }

    $pidFile = Get-WatcherPidFile
    if (Test-Path $pidFile) {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        if ($watcherPid -le 0) { Write-Log 'Watcher is not running.' 'INFO' }
        else                   { Write-Log 'Watcher stopped cleanly.' 'OK' }
    } elseif (-not $evt) {
        Write-Log 'Watcher is not running.' 'INFO'
    }

    Clear-StopRequest                       # never leave a stale stop marker
}

# ------------------------------------------------------------
# Cross-platform detection helpers
# ------------------------------------------------------------
function Get-PlatformInfo {
    <#
        Returns platform information for cross-platform awareness.
        Works on Windows PowerShell 5.1+ and PowerShell Core 7+.
    #>
    $info = @{
        Platform     = 'Unknown'
        IsWindows    = $false
        IsLinux      = $false
        IsMacOS      = $false
        IsAndroid    = $false
        PSVersion    = $PSVersionTable.PSVersion.ToString()
        Arch         = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
    }

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # PowerShell Core 7+
        $info.IsLinux = $IsLinux
        $info.IsMacOS = $IsMacOS
        $info.IsWindows = $IsWindows
        if ($IsLinux) {
            $info.Platform = 'Linux'
            # Detect Android via system properties
            try {
                $brand = & getprop ro.build.brand 2>$null
                $maker = & getprop ro.product.manufacturer 2>$null
                if ($brand -or $maker) { $info.IsAndroid = $true; $info.Platform = 'Android' }
            } catch { }
        }
        if ($IsMacOS) { $info.Platform = 'macOS' }
    } else {
        # Windows PowerShell 5.1
        $info.IsWindows = $true
        $info.Platform = 'Windows'
    }
    return $info
}

Export-ModuleMember -Function Write-Log, Test-Administrator, Assert-AdminOrThrow, Enable-Privilege,
    Get-SuiteRoot, Get-LogPath, Test-SuitePlatformWindows,
    Get-WatcherStopEventName, Get-WatcherMutexName, Get-WatcherPidFile,
    New-WatcherStopEvent, Open-OrCreateStopEvent, Test-WatcherPidAlive, Test-WatcherRunning,
    New-WatcherInstanceGuard, Test-WatcherLockHeld, Test-StopRequested, Set-StopRequested,
    Clear-StopRequest, Wait-StopOrTimeout,
    Get-WatcherJournalPath, Save-WatcherJournal, Get-WatcherJournal, Clear-WatcherJournal,
    ConvertTo-HashtableDeep, Get-StateField, Repair-OrphanedWatcherState, Stop-BackgroundWatcher,
    Get-PlatformInfo
