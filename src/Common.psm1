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
    } catch { }
}

Remove-SuiteLogs
$logPathForExit = $script:LogFile
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action {
    Remove-Item -LiteralPath $logPathForExit -Force -ErrorAction SilentlyContinue
} | Out-Null

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
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
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

function Get-SuiteRoot {
    Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}

function Get-LogPath {
    $script:LogFile
}

function Test-SuitePlatformWindows {
    <# Always true - Windows-only build. #>
    return $true
}

# ------------------------------------------------------------
# Runtime coordination: single instance, background stop signal
#
# Windows-only: named kernel Mutex gates the single instance
# and a named EventWaitHandle carries the stop signal (instant wake).
# ------------------------------------------------------------
$script:RuntimeDir = Join-Path $script:LogDir 'runtime'
if (-not (Test-Path $script:RuntimeDir)) { New-Item -ItemType Directory -Path $script:RuntimeDir | Out-Null }

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
    catch { return $null }
}

function Test-StopRequested {
    <# Windows uses the kernel stop event, never a marker file. #>
    return $false
}

function Set-StopRequested {
    <# Windows callers use the kernel event instead. #>
}

function Clear-StopRequest {
    <# No-op on Windows - the kernel stop event is reset by the next session. #>
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
            try { $mutex.Dispose() } catch { }
            $mutex = $null
        }
    } catch {
        $mutex = $null
    }

    if ($null -eq $mutex) { return $null }

    $release = {
        if ($mutex) { try { [void]$mutex.ReleaseMutex() } catch { } }
        if ($mutex) { try { $mutex.Dispose() } catch { } }
    }.GetNewClosure()

    $guard = [pscustomobject]@{ IsHeld = $true }
    $guard | Add-Member -MemberType ScriptMethod -Name Release -Value $release -Force
    return $guard
}

function Test-WatcherLockHeld {
    <# Always false on Windows (named mutex handles this). #>
    return $false
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
    catch { $m = $null }
    if ($m) {
        try {
            if ($m.WaitOne(0)) {
                try { [void]$m.ReleaseMutex() } catch { }
                $m.Dispose()
                return $false
            }
            $m.Dispose()
            return $true
        } catch {
            try { $m.Dispose() } catch { }
            $m = $null
        }
    }
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

    # ---- 4. Fullscreen-optimization compat flags ------------------------
    try {
        $flags = @(Get-StateField $j 'fsoFlags') | Where-Object { $_ }
        foreach ($path in $flags) {
            Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' `
                -Name ([string]$path) -ErrorAction SilentlyContinue
        }
        if (@($flags).Count -gt 0) { Write-Log 'Fullscreen-optimization overrides cleared.' 'RECOVER' }
    } catch { }

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
            try { $still.Kill() } catch { }
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
function Get-PlatformInfo {
    <# Returns Windows platform information. #>
    return @{
        Platform     = 'Windows'
        IsWindows    = $true
        IsLinux      = $false
        IsMacOS      = $false
        IsAndroid    = $false
        PSVersion    = $PSVersionTable.PSVersion.ToString()
        Arch         = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
    }
}

Export-ModuleMember -Function Write-Log, Test-Administrator, Assert-AdminOrThrow, Enable-Privilege,
    Remove-SuiteLogs, Get-SuiteRoot, Get-LogPath, Test-SuitePlatformWindows,
    Get-WatcherStopEventName, Get-WatcherMutexName, Get-WatcherPidFile,
    New-WatcherStopEvent, Open-OrCreateStopEvent, Test-WatcherPidAlive, Test-WatcherRunning,
    New-WatcherInstanceGuard, Test-WatcherLockHeld, Test-StopRequested, Set-StopRequested,
    Clear-StopRequest, Wait-StopOrTimeout,
    Get-WatcherJournalPath, Save-WatcherJournal, Get-WatcherJournal, Clear-WatcherJournal,
    ConvertTo-HashtableDeep, Get-StateField, Repair-OrphanedWatcherState, Stop-BackgroundWatcher,
    Get-PlatformInfo
