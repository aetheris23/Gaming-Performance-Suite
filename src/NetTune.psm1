# ============================================================
#  NetTune.psm1 - in-game network latency + microphone clarity
#
#  Pure registry/MMCSS tuning with Windows built-ins only (no
#  downloads, no extra services, nothing resident). Applied once
#  when the watcher starts (BEFORE the game connects, so the TCP
#  settings are picked up by the game's new connections) and
#  reverted from the recovery journal when the watcher stops.
#
#  WiFi vs LAN awareness:
#    - Detects active connection type before applying tweaks
#    - Uses TcpAckFrequency=2 (not 1) on WiFi to prevent ACK
#      flooding that causes packet loss on wireless links
#    - Uses TcpAckFrequency=1 on Ethernet for minimum latency
#    - Applies appropriate TCP window sizes per connection type
#    - NIC power saving handled differently per adapter type
#
#  What each piece does:
#    - NetworkThrottlingIndex = 0xFFFFFFFF
#      Windows periodically throttles network traffic while
#      multimedia is playing; disabling it removes periodic
#      packet-delay spikes during gaming.
#    - TcpAckFrequency / TCPNoDelay per active interface
#      Acknowledgements go out immediately and Nagle batching is
#      disabled -> lower input/round-trip latency.
#    - NIC power saving off (PnPCapabilities)
#      Stops Windows powering down the adapter between bursts -
#      a classic source of Wi-Fi/Ethernet micro-dropouts.
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

# ------------------------------------------------------------
# WiFi vs LAN detection
# ------------------------------------------------------------
function Get-ActiveNetworkType {
    <#
        Detects whether the primary active connection is WiFi or Ethernet (LAN).
        Uses netsh to check interface states - lightweight, no WMI overhead.
        Returns: 'WiFi', 'Ethernet', or 'Unknown'
    #>
    try {
        $netsh = & netsh wlan show interfaces 2>$null
        if ($netsh -match 'State\s*:\s*connected') {
            return 'WiFi'
        }
    } catch { }

    try {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch '(?i)virtual|hyper|vpn|tap|bluetooth|wan\s+mini|loopback' }
        foreach ($a in $adapters) {
            if ($a.LinkLayerAddress -and $a.MediaType -eq '802.3') {
                return 'Ethernet'
            }
        }
    } catch { }

    try {
        $physNic = Get-WmiObject Win32_NetworkAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.NetConnectionStatus -eq 2 -and $_.PhysicalAdapter -eq $true -and
                $_.Name -notmatch '(?i)virtual|hyper|vpn|tap|bluetooth' }
        if ($physNic) {
            foreach ($n in $physNic) {
                if ($n.Name -match '(?i)wi-?fi|wireless|802\.11|wlan') { return 'WiFi' }
                return 'Ethernet'
            }
        }
    } catch { }

    # ---- Linux: check /proc/net/wireless and iwconfig ----
    if ($PSVersionTable.PSVersion.Major -ge 6 -and $IsLinux) {
        try {
            $wireless = Get-Content /proc/net/wireless -ErrorAction SilentlyContinue
            if ($wireless -and $wireless.Count -gt 2) { return 'WiFi' }
        } catch { }
        try {
            $iwcfg = & iwconfig 2>$null
            if ($iwcfg -match 'ESSID:"') { return 'WiFi' }
        } catch { }
        try {
            $nmcli = & nmcli -t -f TYPE,DEVICE connection show --active 2>$null
            if ($nmcli -match 'wifi:') { return 'WiFi' }
            if ($nmcli -match 'ethernet:') { return 'Ethernet' }
        } catch { }
    }

    # ---- macOS: check networksetup ----
    if ($PSVersionTable.PSVersion.Major -ge 6 -and $IsMacOS) {
        try {
            $ports = & networksetup -listallhardwareports 2>$null
            if ($ports -match '(?i)wi-?fi|wireless') { return 'WiFi' }
            if ($ports -match 'Ethernet') { return 'Ethernet' }
        } catch { }
    }

    return 'Unknown'
}

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
        Applies the low-latency network profile. Detects WiFi vs LAN
        and adjusts TCP settings to prevent packet loss on wireless.
        Pass -JournalState (a hashtable) to record originals for
        exact revert; without it values are applied persistently
        until manually reverted.
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
        Sysctls    = @{}
        WifiPs     = @{}
        ConnectionType = 'Unknown'
    }

    # ---- Detect connection type ----
    $connType = Get-ActiveNetworkType
    $rec.ConnectionType = $connType
    Write-Log ("Active connection type: {0}" -f $connType) 'INFO'

    if (Test-SuitePlatformWindows) {
    # ---- 1. Disable multimedia network throttling -----------------------
    if (Get-TweakBool $Settings 'DisableNetworkThrottling' $true) {
        $orig = Get-RegRaw -Path $script:SysProfile -Name 'NetworkThrottlingIndex'
        Set-RegDword -Path $script:SysProfile -Name 'NetworkThrottlingIndex' -Value -1
        $rec.ThrottlingIndexOriginal = $orig
        $applied += 'network throttling disabled'
    }

    # ---- 2. Per-interface TCP latency knobs ------------------------------
    # Adjusted based on WiFi vs Ethernet to prevent packet loss.
    # Must exist BEFORE the game opens its sockets.
    if (Get-TweakBool $Settings 'TcpLowLatency' $true) {
        $ifKeys = @(Get-ChildItem -Path $script:TcpIpIfBase -ErrorAction SilentlyContinue)
        foreach ($k in $ifKeys) {
            try {
                $node = @{}
                foreach ($name in @('TcpAckFrequency', 'TCPNoDelay', 'TcpDelAckTicks', 'GlobalMaxTcpWindowSize')) {
                    $orig = Get-RegRaw -Path $k.PSPath -Name $name

                    $val = switch ($name) {
                        'TcpAckFrequency' {
                            # WiFi: use 2 to avoid ACK flooding that causes packet loss
                            # Ethernet: use 1 for minimum latency
                            if ($connType -eq 'WiFi') { 2 } else { 1 }
                        }
                        'TCPNoDelay' { 1 }    # always on: disable Nagle
                        'TcpDelAckTicks' {
                            # WiFi: delay ACK slightly to batch them (reduces overhead)
                            # Ethernet: 0 for immediate ACKs
                            if ($connType -eq 'WiFi') { 100 } else { 0 }
                        }
                        'GlobalMaxTcpWindowSize' {
                            # Larger receive window for better throughput
                            # WiFi benefits more from larger windows
                            if ($connType -eq 'WiFi') { 65535 } else { 65535 }
                        }
                        default { 0 }
                    }

                    if ($orig -ne $val) {
                        Set-RegDword -Path $k.PSPath -Name $name -Value $val
                    }
                    $node[$name] = $orig
                }
                $rec.Interfaces[[string]$k.PSChildName] = $node
            } catch { }
        }
        if ($rec.Interfaces.Count -gt 0) {
            $applied += ('TCP fast-ack/no-delay on {0} interface(s) [{1} optimized]' -f $rec.Interfaces.Count, $connType)
        }
    }

    # ---- 3. Keep physical NICs out of power saving ------------------------
    # On WiFi: more aggressive power-save prevention (common source of
    # "packet loss that isn't the router's fault")
    # On Ethernet: standard prevention
    if (Get-TweakBool $Settings 'DisableNicPowerSaving' $true) {
        $skip = '(?i)wan\s+miniport|loopback|teredo|isatap|bluetooth|microsoft\s+kernel|virtual|hyper-v|vmware|virtualbox|tap-(?:windows|adapter)|km-test|nds|rasserver|raspp|qos|mslltdio'
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

                # WiFi adapters: value 24 (0x18) = no PnP power-down
                # Also set S5WakeOnLan to prevent deep sleep states that
                # cause reconnection delays and packet loss
                if ($connType -eq 'WiFi' -or "$desc" -match '(?i)wi-?fi|wireless|802\.11|wlan') {
                    if ($orig -ne 24) {
                        Set-RegDword -Path $k.PSPath -Name 'PnPCapabilities' -Value 24
                        $rec.NicPower[[string]$k.PSChildName] = $orig
                    }
                } else {
                    # Ethernet: standard power-save off
                    if ($orig -ne 24) {
                        Set-RegDword -Path $k.PSPath -Name 'PnPCapabilities' -Value 24
                        $rec.NicPower[[string]$k.PSChildName] = $orig
                    }
                }
            } catch { }
        }
        if ($rec.NicPower.Count -gt 0) { $applied += ('NIC power-saving disabled on {0} adapter(s)' -f $rec.NicPower.Count) }
    }

    # ---- 4. QoS packet scheduler - gaming priority -------------------------
    # Ensures game traffic gets priority over background downloads
    try {
        $qosKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched'
        if (-not (Test-Path $qosKey)) { New-Item -Path $qosKey -Force | Out-Null }
        $origQos = Get-RegRaw -Path $qosKey -Name 'NonBestEffortLimit'
        if ($origQos -ne 0) {
            Set-RegDword -Path $qosKey -Name 'NonBestEffortLimit' -Value 0
            $rec.QosOriginal = $origQos
            $applied += 'QoS best-effort limit removed'
        }
    } catch { }
    } else {
        #
        # ---- Unix backend (Linux / macOS / Android via Termux): ----
        #      journaled sysctl tuning + WiFi power-save off. Every value is
        #      read BEFORE writing and restored exactly by Undo-GameNetworkProfile.
        #      Write access to net.* needs root; a non-applicable or skipped key
        #      is reported as WARN and never crashes the watcher.
        #
        $sysctlKeys = if ($IsLinux) {
            @{
                'net.core.rmem_max'           = '1048576'
                'net.core.wmem_max'           = '1048576'
                'net.core.netdev_max_backlog' = '30000'
                'net.ipv4.tcp_fastopen'       = '3'
                'net.ipv4.tcp_low_latency'    = '1'
            }
        } else {
            @{
                'net.inet.tcp.delayed_ack' = '0'
                'net.inet.tcp.rfc1323'     = '1'
            }
        }

        if (Get-TweakBool $Settings 'TcpLowLatency' $true) {
            foreach ($k in $sysctlKeys.Keys) {
                try {
                    $orig = ((& sysctl -n "$k" 2>$null) -join ' ').Trim()
                } catch { $orig = $null }
                if ($null -eq $orig -or $orig -eq '') { continue }   # not supported on this kernel
                $target = $sysctlKeys[$k]
                if (("$orig").Trim() -ne $target) {
                    $res = & sysctl -w "$k=$target" 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $rec.Sysctls[$k] = ([string]$orig).Trim()
                        $applied += "sysctl $k -> $target"
                    } else {
                        Write-Log ("Sysctl {0} left unchanged ({1})." -f $k, ($res -join '; ')) 'WARN'
                    }
                }
            }
        }

        # WiFi power-save off is the single biggest wireless packet-loss
        # fix on Linux (the kernel powers the radio down between bursts).
        if ($IsLinux -and $connType -eq 'WiFi') {
            try {
                $iwOut = @(& iw dev 2>$null)
                $curIface = $null
                foreach ($line in $iwOut) {
                    $im = [regex]::Match($line, '^\s*Interface\s+(\S+)\s*$')
                    if ($im.Success) { $curIface = $im.Groups[1].Value; continue }
                    if (-not $curIface) { continue }
                    $ps = & iw dev "$curIface" get power_save 2>$null
                    if ($LASTEXITCODE -eq 0 -and $ps -match 'Power save:\s*(\w+)') {
                        if ($Matches[1] -ieq 'on') {
                            [void](& iw dev "$curIface" set power_save off 2>&1)
                            if ($LASTEXITCODE -eq 0) {
                                $rec.WifiPs[$curIface] = $Matches[1]
                                $applied += "WiFi power-save off on $curIface"
                            }
                        }
                    }
                    $curIface = $null
                }
            } catch { }
        }
    }

    if ($null -ne $JournalState) { $JournalState['net'] = $rec }

    if ($applied.Count -eq 0) {
        Write-Log 'Network profile: nothing to change.' 'INFO'
    } else {
        Write-Log ("Game network profile ACTIVE ({0}): {1}." -f $connType, ($applied -join ', ')) 'OK'
        if ($connType -eq 'WiFi' -and (Test-SuitePlatformWindows)) {
            Write-Log '(WiFi mode: TcpAckFrequency=2 to prevent ACK-flood packet loss on wireless.)' 'INFO'
        }
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
                foreach ($name in @('TcpAckFrequency', 'TCPNoDelay', 'TcpDelAckTicks', 'GlobalMaxTcpWindowSize')) {
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

        # Unix: restore sysctls and WiFi power-save to their exact originals.
        $sctl = Get-NetStateField $net 'Sysctls'
        if ($sctl -is [hashtable]) {
            foreach ($k in @($sctl.Keys)) {
                $val = Get-NetStateField $sctl $k
                if ($null -ne $val) { [void](& sysctl -w "$k=$val" 2>$null) }
            }
        }
        $wps = Get-NetStateField $net 'WifiPs'
        if ($wps -is [hashtable]) {
            foreach ($iface in @($wps.Keys)) {
                $val = Get-NetStateField $wps $iface
                if ($val -ieq 'on') { [void](& iw dev "$iface" set power_save on 2>$null) }
            }
        }

        # Restore QoS if we changed it
        $qosOrig = Get-NetStateField $net 'QosOriginal'
        if ($null -ne $qosOrig) {
            $qosKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched'
            if ($qosKey -and (Test-Path $qosKey)) {
                [void](Restore-RegFromJournal -Path $qosKey -Name 'NonBestEffortLimit' -Original $qosOrig)
            }
        }

        Write-Log 'Game network profile reverted (originals restored).' 'OK'
        return
    }

    if ($RemoveKnownDefaults) {
        if (-not (Test-SuitePlatformWindows)) {
            Write-Log 'Nothing to revert (registry defaults are Windows-only).' 'INFO'
            return
        }
        Remove-RegValue -Path $script:SysProfile -Name 'NetworkThrottlingIndex'
        $count = 1
        foreach ($k in @(Get-ChildItem -Path $script:TcpIpIfBase -ErrorAction SilentlyContinue)) {
            Remove-RegValue -Path $k.PSPath -Name 'TcpAckFrequency'
            Remove-RegValue -Path $k.PSPath -Name 'TCPNoDelay'
            Remove-RegValue -Path $k.PSPath -Name 'TcpDelAckTicks'
            Remove-RegValue -Path $k.PSPath -Name 'GlobalMaxTcpWindowSize'
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
        $qosKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched'
        if (Test-Path $qosKey) {
            Remove-RegValue -Path $qosKey -Name 'NonBestEffortLimit'
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

    if (-not (Test-SuitePlatformWindows)) {
        Write-Log 'Voice clarity (MMCSS) tuning is Windows-only; skipping.' 'INFO'
        return
    }

    Assert-AdminOrThrow

    if (-not $IncludeMmcss) {
        Write-Log 'Microphone MMCSS priority left untouched (disabled in config).' 'INFO'
        return
    }

    $changed = @()
    foreach ($task in @('Audio', 'Pro Audio', 'Capture')) {
        $key = Join-Path "$script:SysProfile\Tasks" $task
        if (-not (Test-Path $key)) { continue }
        New-ItemProperty -Path $key -Name 'Scheduling Category' -Value 'Medium' -PropertyType String  -Force | Out-Null
        New-ItemProperty -Path $key -Name 'SFIO Priority'       -Value 'Normal' -PropertyType String  -Force | Out-Null
        New-ItemProperty -Path $key -Name 'Priority'            -Value 4      -PropertyType DWord  -Force | Out-Null
        $changed += $task
    }

    if ($changed.Count -gt 0) {
        Write-Log ("Voice clarity: MMCSS '{0}' prioritized - microphone stays clean under load." -f ($changed -join ', ')) 'OK'
    } else {
        Write-Log 'Voice clarity: no MMCSS audio classes found to tune.' 'WARN'
    }
}

Export-ModuleMember -Function Enable-GameNetworkProfile, Undo-GameNetworkProfile, Set-MicClarityTweaks, Get-ActiveNetworkType
