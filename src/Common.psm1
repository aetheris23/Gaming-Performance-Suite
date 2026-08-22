# ============================================================
#  Common.psm1 - shared helpers: logging, admin checks,
#  privilege enabling, native Win32 interop.
# ============================================================

$script:LogDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir | Out-Null }
$script:LogFile = Join-Path $script:LogDir ("suite_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','ACTION')][string]$Level = 'INFO'
    )
    $stamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line   = "[$stamp][$Level] $Message"
    $color  = switch ($Level) {
        'INFO'   { 'Gray' }
        'WARN'   { 'Yellow' }
        'ERROR'  { 'Red' }
        'OK'     { 'Green' }
        'ACTION' { 'Cyan' }
    }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
}

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

# ------------------------------------------------------------
# Runtime coordination: single instance, background stop signal
# ------------------------------------------------------------
$script:RuntimeDir = Join-Path $script:LogDir 'runtime'
if (-not (Test-Path $script:RuntimeDir)) { New-Item -ItemType Directory -Path $script:RuntimeDir | Out-Null }

function Get-WatcherStopEventName { 'Global\GamingPerformanceSuite_Stop' }
function Get-WatcherMutexName     { 'Global\GamingPerformanceSuite_Instance' }
function Get-WatcherPidFile       { Join-Path $script:RuntimeDir 'watcher.pid' }

function New-WatcherStopEvent {
    <# Manual-reset kernel event; visible across sessions (Global). #>
    $evt = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, (Get-WatcherStopEventName))
    $evt.Reset()   # clear a stale signal left by an aborted session
    return $evt
}

function Open-OrCreateStopEvent {
    try   { return [System.Threading.EventWaitHandle]::OpenExisting((Get-WatcherStopEventName)) }
    catch { return $null }
}

function Stop-BackgroundWatcher {
    <#
        Signals the running watcher to exit NOW. The watcher parks on
        this event between polls, so shutdown is instant; its finally
        block then restores resolution/priorities/timer on its own.
        Fallback: if the event is gone but a stale PID exists, kill it.
    #>
    $evt = Open-OrCreateStopEvent
    if ($evt) {
        [void]$evt.Set()
        $evt.Dispose()
        Write-Log 'Stop signal delivered to the game watcher.' 'OK'
    }

    Start-Sleep -Milliseconds 600

    $pidFile = Get-WatcherPidFile
    if (Test-Path $pidFile) {
        $watcherPid = 0
        [void][int]::TryParse((Get-Content $pidFile -Raw).Trim(), [ref]$watcherPid)
        if ($watcherPid -gt 0 -and (Get-Process -Id $watcherPid -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-Process -Id $watcherPid
                $p.Kill()
                Write-Log "Watcher process (PID $watcherPid) terminated." 'WARN'
            } catch {
                Write-Log "Could not terminate watcher PID ${watcherPid}: $_" 'ERROR'
            }
        } else {
            Write-Log 'Watcher is not running.' 'INFO'
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    } elseif (-not $evt) {
        Write-Log 'Watcher is not running.' 'INFO'
    }
}

Export-ModuleMember -Function Write-Log, Test-Administrator, Assert-AdminOrThrow, Enable-Privilege,
    Get-SuiteRoot, Get-LogPath, Get-WatcherStopEventName, Get-WatcherMutexName, Get-WatcherPidFile,
    New-WatcherStopEvent, Open-OrCreateStopEvent, Stop-BackgroundWatcher
