# ============================================================
#  NetTune.psm1 - in-game network latency + microphone clarity
#
#  Pure registry/MMCSS tuning with Windows built-ins only (no
#  downloads, no extra services, nothing resident). Applied once
#  when the watcher starts (BEFORE the game connects, so the TCP
#  settings are picked up by the game's new connections) and
#  reverted from the recovery journal when the watcher stops.
#
#  What each piece does:
#    - NetworkThrottlingIndex = 0xFFFFFFFF
#      Windows periodically throttles network traffic while
#      multimedia is playing; disabling it removes periodic
#      packet-delay spikes during gaming.
#    - TcpAckFrequency=1 / TCPNoDelay=1 per active interface
#      Acknowledgements go out immediately and Nagle batching is
#      disabled -> lower input/round-trip latency, fewer
#      burst-loss stalls on Wi-Fi and VPN paths.
#    - NIC power saving off (PnPCapabilities)
#      Stops Windows powering down the adapter between bursts -
#      a classic source of Wi-Fi/Ethernet micro-dropouts ("packet
#      loss" that isn't the router's fault).
#    - MMCSS Audio / Pro Audio / Capture classes raised
#      The mic capture + voice-encode threads keep scheduling
#      priority even while the game hogs CPU -> clear voice for
#      other players.
#
#  Everything is journaled: Enable records original values,
#  Undo restores them. A standalone apply (no journal) can be
#  reverted later with Undo -RemoveKnownDefaults.
# ============================================================

Set-StrictMode -Version Latest

$script:AbsentMarker = '<ABSENT>'
$script:TcpIpIfBase  = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
$script:NicClassBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
$script:SysProfile   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'

function Get-NetStateField {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $null
    }
    $pi = $Object.PSObject.Properties[$Name]
    if ($pi) { return $pi.Value } else { return $null }
}

function Get-TweakBool {
    param([AllowNull()][hashtable]$Settings, [Parameter(Mandatory)][string]$Key, [bool]$Default)
    if ($null -ne $Settings -and $Settings.ContainsKey($Key)) { return [bool]$Settings[$Key] }
    return $Default
}

function Get-RegRaw {
    <# Value or $script:AbsentMarker when the property does not exist. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    try {
        $p = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return [int]$p.$Name
    } catch { return $script:AbsentMarker }
}

function Set-RegDword {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Value)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Remove-RegValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
}

function Restore-RegFromJournal {
    <# marker = we created it -> remove; otherwise write original back. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, $Original)
    if ($null -eq $Original) { return $false }
    if ("$Original" -eq $script:AbsentMarker) {
        Remove-RegValue -Path $Path -Name $Name
    } else {
        $num = 0
        if ([int]::TryParse("$Original", [ref]$num)) { Set-RegDword -Path $Path -Name $Name -Value $num }
    }
    return $true
}

# ------------------------------------------------------------
# Network profile for gaming sessions
# ------------------------------------------------------------
function Enable-GameNetworkProfile {
    <#
        Applies the low-latency network profile. Pass -JournalState
        (a hashtable) to record originals for exact revert; without
        it values are applied persistently until manually reverted.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][hashtable]$Settings,
        [AllowNull()][hashtable]$JournalState
    )

    Assert-AdminOrThrow

    $applied = @()
    $rec = @{
        ThrottlingIndexOriginal = $null
        Interfaces = @{}
        NicPower   = @{}
    }

    # ---- 1. Disable multimedia network throttling -----------------------
    if (Get-TweakBool $Settings 'DisableNetworkThrottling' $true) {
        $orig = Get-RegRaw -Path $script:SysProfile -Name 'NetworkThrottlingIndex'
        # -1 as Int32 writes DWORD 0xFFFFFFFF = "never throttle"
        Set-RegDword -Path $script:SysProfile -Name 'NetworkThrottlingIndex' -Value -1
        $rec.ThrottlingIndexOriginal = $orig
        $applied += 'network throttling disabled'
    }

    # ---- 2. Per-interface TCP latency knobs ------------------------------
    # Must exist BEFORE the game opens its sockets, which is why this
    # runs at watcher start rather than at game detection.
    if (Get-TweakBool $Settings 'TcpLowLatency' $true) {
        $ifKeys = @(Get-ChildItem -Path $script:TcpIpIfBase -ErrorAction SilentlyContinue)
        foreach ($k in $ifKeys) {
            try {
                $node = @{}
                foreach ($name in @('TcpAckFrequency', 'TCPNoDelay')) {
                    $orig = Get-RegRaw -Path $k.PSPath -Name $name
                    if ($orig -ne 1) {
                        Set-RegDword -Path $k.PSPath -Name $name -Value 1
                    }
                    $node[$name] = $orig
                }
                $rec.Interfaces[[string]$k.PSChildName] = $node
            } catch { }
        }
        if ($rec.Interfaces.Count -gt 0) { $applied += ('TCP fast-ack/no-delay on {0} interface(s)' -f $rec.Interfaces.Count) }
    }

    # ---- 3. Keep physical NICs out of power saving ------------------------
    if (Get-TweakBool $Settings 'DisableNicPowerSaving' $true) {
        $skip = '(?i)wan\s+miniport|loopback|teredo|isatap|bluetooth|microsoft\s+kernel|virtual|hyper-v|vmware|virtualbox|tap-(?:windows|adapter)|wi-?fi\s+direct|km-test|nds|rasserver|raspp|qos|mslltdio'
        $nicKeys = @(Get-ChildItem -Path $script:NicClassBase -ErrorAction SilentlyContinue |
                     Where-Object { $_.PSChildName -match '^00\d+$' })
        foreach ($k in $nicKeys) {
            try {
                $p = Get-ItemProperty -Path $k.PSPath -ErrorAction Stop
                $desc = $null
                $pi = $p.PSObject.Properties['DriverDesc']
                if ($pi) { $desc = $pi.Value }
                if (-not $desc) { continue }
                if ("$desc" -match $skip) { continue }
                $orig = Get-RegRaw -Path $k.PSPath -Name 'PnPCapabilities'
                if ($orig -ne 24) {
                    Set-RegDword -Path $k.PSPath -Name 'PnPCapabilities' -Value 24   # 0x18: no PnP power-down
                    $rec.NicPower[[string]$k.PSChildName] = $orig
                }
            } catch { }
        }
        if ($rec.NicPower.Count -gt 0) { $applied += ('NIC power-saving disabled on {0} adapter(s)' -f $rec.NicPower.Count) }
    }

    if ($null -ne $JournalState) { $JournalState['net'] = $rec }

    if ($applied.Count -eq 0) {
        Write-Log 'Network profile: nothing to change.' 'INFO'
    } else {
        Write-Log ("Game network profile ACTIVE: {0}." -f ($applied -join ', ')) 'OK'
        Write-Log '(Takes effect for connections opened from now on - keep the watcher running before you launch the game.)' 'INFO'
    }
}

function Undo-GameNetworkProfile {
    <#
        Exact revert from a journal node, or -RemoveKnownDefaults to
        strip the values this suite manages (used after a standalone
        apply where no journal exists).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][hashtable]$JournalState,
        [switch]$RemoveKnownDefaults
    )

    $net = $JournalState

    if ($net) {
        $orig = Get-NetStateField $net 'ThrottlingIndexOriginal'
        if ($null -ne $orig) {
            [void](Restore-RegFromJournal -Path $script:SysProfile -Name 'NetworkThrottlingIndex' -Original $orig)
        }

        $ifs = Get-NetStateField $net 'Interfaces'
        if ($ifs -is [hashtable]) {
            foreach ($guid in @($ifs.Keys)) {
                $path = Join-Path $script:TcpIpIfBase ([string]$guid)
                if (-not (Test-Path $path)) { continue }
                $node = Get-NetStateField $ifs $guid
                foreach ($name in @('TcpAckFrequency', 'TCPNoDelay')) {
                    $val = Get-NetStateField $node $name
                    if ($null -ne $val) {
                        [void](Restore-RegFromJournal -Path $path -Name $name -Original $val)
                    }
                }
            }
        }

        $nics = Get-NetStateField $net 'NicPower'
        if ($nics -is [hashtable]) {
            foreach ($id in @($nics.Keys)) {
                $path = Join-Path $script:NicClassBase ([string]$id)
                if (-not (Test-Path $path)) { continue }
                $val = Get-NetStateField $nics $id
                if ($null -ne $val) {
                    [void](Restore-RegFromJournal -Path $path -Name 'PnPCapabilities' -Original $val)
                }
            }
        }

        Write-Log 'Game network profile reverted (originals restored).' 'OK'
        return
    }

    if ($RemoveKnownDefaults) {
        Remove-RegValue -Path $script:SysProfile -Name 'NetworkThrottlingIndex'
        $count = 1
        foreach ($k in @(Get-ChildItem -Path $script:TcpIpIfBase -ErrorAction SilentlyContinue)) {
            Remove-RegValue -Path $k.PSPath -Name 'TcpAckFrequency'
            Remove-RegValue -Path $k.PSPath -Name 'TCPNoDelay'
            $count++
        }
        foreach ($k in @(Get-ChildItem -Path $script:NicClassBase -ErrorAction SilentlyContinue |
                         Where-Object { $_.PSChildName -match '^00\d+$' })) {
            try {
                $p = Get-ItemProperty -Path $k.PSPath -ErrorAction Stop
                $pi = $p.PSObject.Properties['PnPCapabilities']
                if ($pi -and [int]$pi.Value -eq 24) {
                    Remove-RegValue -Path $k.PSPath -Name 'PnPCapabilities'
                }
            } catch { }
        }
        Write-Log 'Network optimizations reverted to Windows defaults.' 'OK'
        return
    }

    Write-Log 'Nothing to revert (no journal).' 'INFO'
}

# ------------------------------------------------------------
# Microphone clarity: keep audio capture threads prioritized
# ------------------------------------------------------------
function Set-MicClarityTweaks {
    <#
        Raises the MMCSS scheduling class of Audio / Pro Audio /
        Capture so mic capture + voice encoding stay smooth while a
        game saturates the CPU. Only touches classes that already
        exist (driver-provided); never installs anything.
    #>
    [CmdletBinding()]
    param([bool]$IncludeMmcss = $true)

    Assert-AdminOrThrow

    if (-not $IncludeMmcss) {
        Write-Log 'Microphone MMCSS priority left untouched (disabled in config).' 'INFO'
        return
    }

    $changed = @()
    foreach ($task in @('Audio', 'Pro Audio', 'Capture')) {
        $key = Join-Path "$script:SysProfile\Tasks" $task
        if (-not (Test-Path $key)) { continue }
        New-ItemProperty -Path $key -Name 'Scheduling Category' -Value 'High' -PropertyType String  -Force | Out-Null
        New-ItemProperty -Path $key -Name 'SFIO Priority'       -Value 'High' -PropertyType String  -Force | Out-Null
        New-ItemProperty -Path $key -Name 'Priority'            -Value 6      -PropertyType DWord  -Force | Out-Null
        $changed += $task
    }

    if ($changed.Count -gt 0) {
        Write-Log ("Voice clarity: MMCSS '{0}' prioritized - microphone stays clean under load." -f ($changed -join ', ')) 'OK'
    } else {
        Write-Log 'Voice clarity: no MMCSS audio classes found to tune.' 'WARN'
    }
}

Export-ModuleMember -Function Enable-GameNetworkProfile, Undo-GameNetworkProfile, Set-MicClarityTweaks
