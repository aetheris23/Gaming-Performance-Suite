# ============================================================
#  Common.psm1 - shared helpers: logging, admin checks,
#  privilege enabling, native Win32 interop, runtime
#  coordination (single instance / stop signal / recovery
#  journal so an unclean shutdown never leaves the system
#  in a half-optimized state).
#
#  Windows-only: Linux/macOS/Android support has been removed
#  to eliminate cross-platform scanning overhead that degraded
#  performance over long sessions.
# ============================================================

$script:LogDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir | Out-Null }
$script:LogFile = Join-Path $script:LogDir ("suite_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

# Scope named coordination objects to this installation. Without a stable
# per-folder suffix, two extracted copies on different drives share one global
# mutex/event and a moved copy can incorrectly report the other copy as running.
$script:SuiteIdentity = $null
try {
    $suiteRootForIdentity = [System.IO.Path]::GetFullPath(
        (Split-Path -Parent (Split-Path -Parent $PSCommandPath))).TrimEnd('\').ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($suiteRootForIdentity))
    } finally {
        $sha.Dispose()
    }
    $script:SuiteIdentity = (-join ($hashBytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
} catch {
    # The script path is always available for normal execution; this fallback
    # keeps module import usable in constrained PowerShell hosts.
    $script:SuiteIdentity = 'default'
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][WARN] Failed to compute suite identity: $_" -ForegroundColor Yellow
}

function Remove-SuiteLogs {
    <#
        Logs are diagnostic-only session artifacts. Remove old files at
        startup and the current file when PowerShell exits so repeated games
        cannot slowly accumulate runtime data.
    #>
    try {
        Get-ChildItem -Path $script:LogDir -Filter 'suite_*.log' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        # Log cleanup failure but don't break startup
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][WARN] Failed to clean old log files: $_" -ForegroundColor Yellow
    }
}

Remove-SuiteLogs
$logPathForExit = $script:LogFile
$script:LogWriteCount = 0
# Repeated Import-Module -Force calls recreate this module's session
# state, so a $script guard cannot help - stack the flag in the global
# scope instead, otherwise every -Force import adds one more Exiting
# subscription (each spawning its own async event job).
if (-not $Global:GamingPerfSuite_ExitHook) {
    $Global:GamingPerfSuite_ExitHook = $true
    Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action {
        try { Close-SuiteLogWriter } catch { Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][WARN] Failed to close log writer on exit: $_" -ForegroundColor Yellow }
        Remove-Item -LiteralPath $logPathForExit -Force -ErrorAction SilentlyContinue
    } | Out-Null
}

# The log file is opened ONCE per session and cached, instead of
# Add-Content re-creating a file handle on every line. Handle create/
# destroy churn on every informational message is real I/O work on an
# HDD/weak machine. AutoFlush keeps lines durable for a crash; the
# low-end fix is the single open handle, not a buffering queue.
function Close-SuiteLogWriter {
    $w = $Global:GamingPerfSuite_LogWriter
    if ($w) {
        try { $w.Flush(); $w.Dispose() } catch { Write-Log "Failed to close log writer: $_" 'WARN' }
    }
    $Global:GamingPerfSuite_LogWriter = $null
    $Global:GamingPerfSuite_LogWriterPath = $null
    $script:LogWriteCount = 0
}

function Get-SuiteLogWriter {
    if ($Global:GamingPerfSuite_LogWriter -and
        $Global:GamingPerfSuite_LogWriterPath -eq $script:LogFile -and
        (Test-Path -LiteralPath $script:LogFile)) {
        return $Global:GamingPerfSuite_LogWriter
    }
    # File was rotated out (Remove-SuiteLogs at a later -Force import) or
    # the path moved: reopen against the current path. Dispose first so
    # handles are never stacked.
    Close-SuiteLogWriter
    $fs = [System.IO.File]::Open($script:LogFile, [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $w = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
    $w.AutoFlush = $true
    $Global:GamingPerfSuite_LogWriter = $w
    $Global:GamingPerfSuite_LogWriterPath = $script:LogFile
    $script:LogWriteCount = 0
    return $w
}

# Soft cap on the log file. A runaway loop must never fill the disk on a
# low-end machine: when the file crosses the cap, the tail is kept.
function Limit-SuiteLogSize {
    $script:LogWriteCount++
    if ($script:LogWriteCount % 25 -ne 0) { return }   # cheap: stat every 25 lines only
    try {
        $fi = Get-Item -LiteralPath $script:LogFile -ErrorAction SilentlyContinue
        if (-not $fi -or $fi.Length -lt 2MB) { return }
        Close-SuiteLogWriter
        $bytes = [System.IO.File]::ReadAllBytes($script:LogFile)
        $keepFrom = [Math]::Max(0, $bytes.Length - 1MB)
        # Keep the tail as complete lines.
        while ($keepFrom -lt $bytes.Length -and $bytes[$keepFrom] -ne 10) { $keepFrom++ }
        $tailLen = $bytes.Length - $keepFrom
        $tail = New-Object byte[] $tailLen
        [Array]::Copy($bytes, $keepFrom, $tail, 0, $tailLen)
        $stampHdr = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][INFO] Log truncated (size cap); keeping the most recent lines.`r`n"
        $hdr = [System.Text.Encoding]::UTF8.GetBytes($stampHdr)
        $combined = New-Object byte[] ($hdr.Length + $tailLen)
        [Array]::Copy($hdr, 0, $combined, 0, $hdr.Length)
        [Array]::Copy($tail, 0, $combined, $hdr.Length, $tailLen)
        [System.IO.File]::WriteAllBytes($script:LogFile, $combined)
        $script:LogWriteCount = 0
    } catch {
        Write-Log "Failed to limit log size: $_" 'WARN'
    }
}

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
    try {
        $w = Get-SuiteLogWriter
        $w.WriteLine($line)
        Limit-SuiteLogSize
    } catch {
        # The log file must never be able to break a session.
        try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 }
        catch { Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][ERROR] Write-Log failed completely: $_" -ForegroundColor Red }
    }
}

function Test-Administrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-Log "Test-Administrator failed: $_" 'WARN'
        return $false
    }
}

function Assert-AdminOrThrow {
    if (-not (Test-Administrator)) {
        throw "This action requires Administrator privileges. Re-run via Start-GamingSuite.bat."
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
        $adjusted = [Suite.NativeToken]::AdjustTokenPrivileges(
            $token, $false, [ref]$tp, 0, [IntPtr]::Zero, [IntPtr]::Zero)
        if (-not $adjusted) { return $false }
        # ERROR_NOT_ALL_ASSIGNED (1300) means the token does not contain this
        # privilege; treating it as success causes privileged native calls to
        # fail later with STATUS_PRIVILEGE_NOT_HELD.
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        return ($err -eq 0)
    } finally {
        if ($token -ne [IntPtr]::Zero) { [void][Suite.NativeToken]::CloseHandle($token) }
    }
}

function Get-LogPath {
    $script:LogFile
}

# ------------------------------------------------------------
# Runtime coordination: single instance, background stop signal
#
# Windows-only: named kernel Mutex gates the single instance
# and a named EventWaitHandle carries the stop signal (instant wake).
# ------------------------------------------------------------
$script:RuntimeDir = Join-Path $script:LogDir 'runtime'
if (-not (Test-Path $script:RuntimeDir)) {
    try { New-Item -ItemType Directory -Path $script:RuntimeDir | Out-Null }
    catch { Write-Log "Failed to create runtime directory: $_" 'WARN' }
}

function Get-WatcherStopEventName { "Global\GamingPerformanceSuite_${script:SuiteIdentity}_Stop" }
function Get-WatcherMutexName     { "Global\GamingPerformanceSuite_${script:SuiteIdentity}_Instance" }
function Get-WatcherPidFile       { Join-Path $script:RuntimeDir 'watcher.pid' }

function New-WatcherStopEvent {
    <# Returns the cross-process stop handle. #>
    $evt = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, (Get-WatcherStopEventName))
    $null = $evt.Reset()
    return $evt
}

function Open-OrCreateStopEvent {
    <# Opens the existing stop event. Never fabricates an event just to exist. #>
    try   { return [System.Threading.EventWaitHandle]::OpenExisting((Get-WatcherStopEventName)) }
    catch { Write-Log "Open-OrCreateStopEvent failed: $_" 'WARN'; return $null }
}

function Wait-StopOrTimeout {
    <#
        Parks the watcher for up to $Milliseconds. Returns $true when a
        stop was requested. Uses the kernel event for instant wake.
    #>
    param(
        [int]$Milliseconds = 1000,
        [System.Threading.EventWaitHandle]$StopEvent = $null
    )
    if ($StopEvent) { return $StopEvent.WaitOne($Milliseconds) }
    Start-Sleep -Milliseconds $Milliseconds
    return $false
}

function New-WatcherInstanceGuard {
    <#
        Returns a guard object that holds the single-instance lock via
        a named kernel Mutex, or $null when another watcher already owns it.
        The guard always has a Release() method - call it exactly once when
        the watcher exits.
    #>
    $mutex = $null
    $createdNew = $false
    try {
        $mutex = [System.Threading.Mutex]::new($true, (Get-WatcherMutexName), [ref]$createdNew)
        if (-not $createdNew) {
            try { $mutex.Dispose() } catch { Write-Log "Failed to dispose mutex (not created new): $_" 'WARN' }
            $mutex = $null
        }
    } catch { Write-Log "New-WatcherInstanceGuard mutex creation failed: $_" 'WARN'; $mutex = $null }

    if ($null -eq $mutex) { return $null }

    $release = {
        if ($mutex) { try { [void]$mutex.ReleaseMutex() } catch { Write-Log "Failed to release mutex: $_" 'WARN' } }
        if ($mutex) { try { $mutex.Dispose() } catch { Write-Log "Failed to dispose mutex: $_" 'WARN' } }
    }.GetNewClosure()

    $guard = [pscustomobject]@{ IsHeld = $true }
    $guard | Add-Member -MemberType ScriptMethod -Name Release -Value $release -Force
    return $guard
}

function Test-WatcherPidAlive {
    <#
        Reads watcher.pid and reports whether that PID belongs to a
        LIVE powershell/pwsh process. Returns the PID when alive, else 0.
    #>
    $pidFile = Get-WatcherPidFile
    if (-not (Test-Path $pidFile)) { return 0 }
    $watcherPid = 0
    [void][int]::TryParse((Get-Content $pidFile -Raw).Trim(), [ref]$watcherPid)
    if ($watcherPid -le 0) { return 0 }
    $proc = Get-Process -Id $watcherPid -ErrorAction SilentlyContinue
    if (-not $proc) { return 0 }
    if ($proc.ProcessName -notmatch '^(powershell|pwsh)$') { return 0 }
    return $watcherPid
}

function Test-WatcherRunning {
    <#
        Reports whether a game watcher is alive RIGHT NOW via the named
        instance mutex.
    #>
    $m = $null
    try { $m = [System.Threading.Mutex]::OpenExisting((Get-WatcherMutexName)) }
    catch { Write-Log "Test-WatcherRunning OpenExisting failed: $_" 'WARN'; $m = $null }
    if ($m) {
        try {
            if ($m.WaitOne(0)) {
                try { [void]$m.ReleaseMutex() } catch { Write-Log "Test-WatcherRunning ReleaseMutex failed: $_" 'WARN' }
                $m.Dispose()
                return $false
            }
            $m.Dispose()
            return $true
        } catch {
            try { $m.Dispose() } catch { Write-Log "Test-WatcherRunning inner Dispose failed: $_" 'WARN' }
            $m = $null
        }
    }
    return ((Test-WatcherPidAlive) -gt 0)
}

# ------------------------------------------------------------
# Recovery journal.
#
# The watcher records every system change it makes (display mode,
# silenced processes, FSO flags, the network latency profile...)
# to this file the moment it makes it. If the watcher dies without
# cleanup - killed console, forced kill, power loss, crash - the NEXT
# start (or Stop-GamingSuite.bat) replays the undo side of the journal
# and puts everything back. This is what makes background stops
# and closes safe no matter how they happen.
# ------------------------------------------------------------
function Get-WatcherJournalPath { Join-Path $script:RuntimeDir 'watcher_state.json' }

function Save-WatcherJournal {
    param([Parameter(Mandatory)][hashtable]$State)
    $path = Get-WatcherJournalPath
    $tempPath = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$tempPath.bak"
    try {
        $json = ConvertTo-Json -InputObject $State -Depth 8 -ErrorAction Stop
        [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
        if ([System.IO.File]::Exists($path)) {
            [System.IO.File]::Replace($tempPath, $path, $backupPath)
            if ([System.IO.File]::Exists($backupPath)) { [System.IO.File]::Delete($backupPath) }
        } else {
            [System.IO.File]::Move($tempPath, $path)
        }
    } finally {
        if ([System.IO.File]::Exists($tempPath)) { [System.IO.File]::Delete($tempPath) }
        if ([System.IO.File]::Exists($backupPath)) { [System.IO.File]::Delete($backupPath) }
    }
}

function Get-WatcherJournal {
    $path = Get-WatcherJournalPath
    if (-not (Test-Path $path)) { return $null }
    try   { return ConvertFrom-Json (Get-Content $path -Raw) }
    catch { Write-Log "Get-WatcherJournal failed to parse JSON: $_" 'WARN'; return $null }
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
        restores native resolution, background-app priorities,
        fullscreen-optimization flags, the network latency profile and
        kills an orphaned frame-gen tool. Called automatically when a
        watcher starts over a dead previous session, and as the final
        fallback of Stop-GamingSuite.bat.
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
                Name      = (Get-StateField $nm 'Name')
                Stretched = [bool](Get-StateField $nm 'Stretched')
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
                } catch {
                    Write-Log "Recovery: failed to restore priority for PID ${procId}: $_" 'WARN'
                }
            }
        }
    } catch { Write-Log "Recovery: silenced apps restore failed: $_" 'ERROR' }

    # ---- 3. Fullscreen-optimization compat flags ------------------------
    try {
        $flags = @(Get-StateField $j 'fsoFlags') | Where-Object { $_ }
        foreach ($path in $flags) {
            Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' `
                -Name ([string]$path) -ErrorAction SilentlyContinue
        }
        if (@($flags).Count -gt 0) { Write-Log 'Fullscreen-optimization overrides cleared.' 'RECOVER' }
    } catch { Write-Log "Recovery: FSO flags restore failed: $_" 'ERROR' }

    # ---- 4. Orphaned frame-generation tool ------------------------------
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
    } catch { Write-Log "Recovery: frame-gen tool cleanup failed: $_" 'ERROR' }

    # ---- 4b. Orphaned microphone enhancement tool -------------------------
    try {
        $micPid = 0
        [void][int]::TryParse("$([string](Get-StateField $j 'micToolPid'))", [ref]$micPid)
        if ($micPid -gt 0) {
            $mic = Get-Process -Id $micPid -ErrorAction SilentlyContinue
            if ($mic) {
                [void]$mic.CloseMainWindow()
                Start-Sleep -Milliseconds 500
                if (-not $mic.HasExited) { $mic.Kill() }
                Write-Log 'Orphaned microphone enhancement tool closed.' 'RECOVER'
            }
        }
    } catch { Write-Log "Recovery: mic-enhance tool cleanup failed: $_" 'ERROR' }

    # ---- 5. Network latency profile -------------------------------
    # The journal's `netLatency` node holds the original value of every
    # registry/driver/service change NetTune.psm1 made. Reverting it here
    # is what makes a killed watcher (or a power loss mid-match) safe:
    # without a journal entry the machine could keep RSC/LSO disabled, the
    # adapter out of power saving and Delivery Optimization stopped.
    try {
        if (Get-StateField $j 'netLatency') {
            Import-Module (Join-Path $PSScriptRoot 'NetTune.psm1') -Force
            Undo-NetworkLatencyProfile -JournalState $j
        }
    } catch { Write-Log "Recovery: network profile revert failed: $_" 'ERROR' }

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
        Signals the running watcher to exit NOW via the kernel event.
        The watcher parks on this event between polls, so shutdown
        begins instantly and its finally block restores everything.
        We WAIT for that cleanup to finish; a kill is only the last
        resort, and afterwards the recovery journal replays missing
        undo steps automatically.
    #>
    $evt = Open-OrCreateStopEvent
    if ($evt) {
        [void]$evt.Set()
        $evt.Dispose()
    }
    Write-Log 'Stop signal delivered to the game watcher.' 'OK'

    $watcherPid = Test-WatcherPidAlive
    if ($watcherPid -gt 0) {
        $deadline = [datetime]::UtcNow.AddSeconds(12)
        while ((Get-Process -Id $watcherPid -ErrorAction SilentlyContinue) -and [datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }
        $still = Get-Process -Id $watcherPid -ErrorAction SilentlyContinue
        if ($still) {
            Write-Log "Watcher did not exit in time; terminating PID $watcherPid..." 'WARN'
            try { $still.Kill() } catch { Write-Log "Failed to kill watcher process: $_" 'ERROR' }
            Start-Sleep -Milliseconds 400
        }
    }

    Start-Sleep -Milliseconds 300

    if (Repair-OrphanedWatcherState) { return }

    $pidFile = Get-WatcherPidFile
    if (Test-Path $pidFile) {
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        if ($watcherPid -le 0) { Write-Log 'Watcher is not running.' 'INFO' }
        else                   { Write-Log 'Watcher stopped cleanly.' 'OK' }
    }
}

# ------------------------------------------------------------
# Platform detection helpers
# ------------------------------------------------------------
Export-ModuleMember -Function Write-Log, Test-Administrator, Assert-AdminOrThrow, Enable-Privilege,
    Remove-SuiteLogs, Get-LogPath,
    Get-WatcherStopEventName, Get-WatcherMutexName, Get-WatcherPidFile,
    New-WatcherStopEvent, Open-OrCreateStopEvent, Test-WatcherPidAlive, Test-WatcherRunning,
    New-WatcherInstanceGuard, Wait-StopOrTimeout,
    Get-WatcherJournalPath, Save-WatcherJournal, Get-WatcherJournal, Clear-WatcherJournal,
    ConvertTo-HashtableDeep, Get-StateField, Repair-OrphanedWatcherState, Stop-BackgroundWatcher
