# ============================================================
#  NetTune.psm1 - in-game network latency & packet-loss profile
#
#  Goal: remove the LOCAL causes of RTT spikes and packet loss
#  while a game is running, then put every setting back exactly
#  as it was. Windows built-ins only - no installs, no drivers,
#  no extra services, nothing resident after the session.
#
#  WHAT THIS CAN AND CANNOT DO (read this before judging results)
#  -----------------------------------------------------------
#  Your RTT *baseline* (that steady ~30ms) is set by the physical
#  path: router -> ISP -> route -> the game servers. No script can
#  shorten it. What a local tool CAN do is remove the reasons your
#  RTT suddenly jumps to 100-300ms, and the reasons packets go
#  missing while you play:
#
#    1. Adapter/NIC power saving - Windows parks a wireless or
#       copper NIC between bursts and wakes it on a timer. The
#       wake-up costs milliseconds and stalls in-flight traffic;
#       on Wi-Fi it is the most common source of "packet loss
#       that the router swears isn't there".
#    2. Background downloads - a Steam/Store/Delivery-Optimization
#       transfer fills the link queue and the resulting buffer
#       bloom shows up as 100-300ms RTT spikes. Uploads are worse
#       still: one large upload can add 50-200ms to every other
#       packet, indefinitely.
#    3. Adapter aggregation/offload - Receive Segment Coalescing
#       and Large Send Offload let the driver hold small packets
#       to build big ones. That is pure added latency, and on some
#       drivers small UDP game packets are dropped outright.
#    4. Windows multimedia/QoS throttling - NetworkThrottlingIndex
#       deliberately delays packets while "multimedia" plays, and
#       the QoS NonBestEffortLimit caps reserved bandwidth.
#    5. A collapsed TCP receive window - left behind by an older
#       "game booster" that set TcpAutotuningLevel. This is a pure
#       software cause of phantom packet loss; it is detected and
#       repaired.
#    6. Aggressive Wi-Fi roaming - the card hopping to a weaker
#       access point mid-match moves the RTT by tens of ms.
#
#  HONEST NOTE ON TCP SETTINGS: the only per-connection latency
#  knobs Windows exposes are TCP-only (Nagle / delayed ACK), and
#  Valorant's in-match traffic is UDP, so those values change
#  nothing for your RTT. They are kept because they still matter
#  for the TCP traffic around a session (launchers, stores,
#  updates), and every one of them is switched individually in
#  Config.ps1 > NetworkOptimization.
#
#  SAFETY / ANTI-CHEAT: nothing here inspects, injects, filters,
#  spoofs or reorders game traffic, and no game or anti-cheat
#  process (Vanguard, BattlEye, EAC...) is ever touched. Only
#  documented Windows system/adapter/driver settings are read or
#  written, and only on adapters that are actually connected.
#
#  Applied ONCE per session (before the game connects) and
#  reverted from the recovery journal when the session ends, the
#  watcher is stopped, or a crash is repaired.
# ============================================================

Set-StrictMode -Version Latest

# Common.psm1 (Write-Log / Assert-AdminOrThrow / Get-StateField) is
# imported by Main.ps1 before this module, so its exported functions
# resolve through the global scope. Import it here only in case this
# module is ever loaded on its own.
if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    try { Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -ErrorAction Stop } catch { }
}

$script:TcpParams    = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
$script:TcpIpIfBase  = "$script:TcpParams\Interfaces"
$script:NicClassBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
$script:SysProfile   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$script:QosPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched'

# Sentinel meaning "this registry value did not exist before we wrote
# it" - the undo step then REMOVES it instead of restoring a wrong value.
$script:AbsentMarker = '<ABSENT>'

# Wireless Adapter Settings / Power Saving Mode. Index 0 = maximum
# performance; Windows ships 2 (balanced) or 3 (max power saving).
$script:WirelessSubgroup  = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
$script:WirelessPowerMode = '12bbebe6-58d6-4636-95bb-3217ef867c1a'

# Adapter descriptions that are not a real cable/Wi-Fi link. Tuning
# these only breaks sandboxes, VPNs and loopback traffic.
$script:VirtualAdapterPattern = '(?i)virtual|hyper-?v|tap-|vEthernet|loopback|bluetooth|wan\s+miniport|isatap|teredo|vmware|virtualbox|openvpn|wg-?tun|microsoft\s+kernel|wintun'

$script:AdapterCache        = $null
$script:AdapterCacheTime    = [datetime]::MinValue
$script:LinkCache           = $null
$script:LinkCacheTime       = [datetime]::MinValue
$script:LossBaseline        = $null
$script:WirelessProbeWarned = $false

# ------------------------------------------------------------
# Small helpers
# ------------------------------------------------------------
function Get-TweakBool {
    <# Reads a boolean switch from a Config.ps1 sub-table, with a default. #>
    param([AllowNull()]$Settings, [Parameter(Mandatory)][string]$Key, [bool]$Default)
    if ($null -ne $Settings -and $Settings -is [System.Collections.IDictionary] -and $Settings.Contains($Key)) {
        return [bool]$Settings[$Key]
    }
    return $Default
}

function ConvertTo-NativeRegPath {
    <#
        A registry key object reports PSPath as a provider-qualified string
        (Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\...).
        The recovery journal is read by other code (and by humans), so
        normalize to the plain HKLM: form that every registry cmdlet accepts.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -match '^HKEY_LOCAL_MACHINE\\') {
        return $Path -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM:\'
    }
    if ($Path -match '(?i)^Microsoft\.PowerShell\.Core\\Registry::') {
        return ($Path -replace '(?i)^Microsoft\.PowerShell\.Core\\Registry::', '') -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM:\'
    }
    return $Path
}

function Get-RegRawValue {
    <# Current DWORD value, or the absent-marker when the value does not exist. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    try {
        $p = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return [int]$p.$Name
    } catch { return $script:AbsentMarker }
}

function Set-RegDwordValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Value)
    # -ErrorAction Stop is deliberate: a silent write failure would be
    # reported by the caller as "applied" while nothing actually changed,
    # and the undo step would then have nothing to restore.
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
}

function Remove-RegValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
}

function Add-RegRecord {
    <#
        Records the ORIGINAL value of a registry value exactly once per
        session (re-running the profile inside one session must not
        overwrite the pristine original with our own value) and then
        writes the new one.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Record,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )
    $key = "$Path|$Name"
    if (-not $Record.ContainsKey($key)) {
        $Record[$key] = (Get-RegRawValue -Path $Path -Name $Name)
    }
    Set-RegDwordValue -Path $Path -Name $Name -Value $Value
}

function Restore-RegRecord {
    <#
        Puts one recorded registry value back: removes it when we created
        it, otherwise rewrites the original. Returns $true when something
        was actually changed.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Record,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    $key = "$Path|$Name"
    if (-not $Record.ContainsKey($key)) { return $false }
    $original = $Record[$key]
    $null = $Record.Remove($key)
    if ("$original" -eq $script:AbsentMarker) {
        Remove-RegValue -Path $Path -Name $Name
        return $true
    }
    $num = 0
    if ([int]::TryParse("$original", [ref]$num)) {
        Set-RegDwordValue -Path $Path -Name $Name -Value $num
        return $true
    }
    return $false
}

# ------------------------------------------------------------
# Adapter inventory / connection type
# ------------------------------------------------------------
function Get-NetworkAdapterInventory {
    <#
        The adapters that are actually connected right now, plus which
        one carries the default route. Never parses localized netsh/WMI
        text (that misreads non-English installs): it uses the NetAdapter
        object model and the routing table, with a CIM fallback for builds
        that stripped the module. Cached for 30s so the status screen and
        the watcher can both ask without an object-model probe each time.
        Returns @() when nothing usable is found - never throws.
    #>
    param([switch]$Refresh, [int]$TtlSeconds = 30)

    if (-not $Refresh -and $null -ne $script:AdapterCache -and
        $script:AdapterCacheTime -ne [datetime]::MinValue -and
        (([datetime]::UtcNow) - $script:AdapterCacheTime).TotalSeconds -le $TtlSeconds) {
        return $script:AdapterCache
    }

    $result = @()
    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop)
    } catch { $adapters = @() }

    if ($adapters.Count -eq 0) {
        # Debloated/trimmed builds can miss the NetAdapter module: fall back
        # to the CIM adapter table (never the deprecated WMI cmdlet).
        try {
            $cimIfs = @(Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction Stop |
                Where-Object { $_.NetEnabled -eq $true -and $_.NetConnectionStatus -eq 2 })
            foreach ($c in $cimIfs) {
                $desc = "$($c.Name)"
                if ($desc -match $script:VirtualAdapterPattern) { continue }
                $result += @{
                    Name        = $desc
                    Description = $desc
                    IfIndex     = [int]$c.Index
                    IsWireless  = [bool]($c.PhysicalAdapter -and $desc -match '(?i)wi-?fi|wireless|802\.11|wlan')
                    IsDefault   = $false
                    LinkSpeed   = ''
                    InterfaceGuid = ''
                }
            }
        } catch { }
        $script:AdapterCache = $result
        $script:AdapterCacheTime = [datetime]::UtcNow
        return $script:AdapterCache
    }

    # Which interface carries the default route? That is the link the game
    # traffic rides on, so it decides the Wi-Fi vs Ethernet profile.
    $defaultIfIndexes = @()
    try {
        $defaultIfIndexes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' `
            -ErrorAction Stop | ForEach-Object { [int]$_.InterfaceIndex })
    } catch { }

    foreach ($a in $adapters) {
        $desc = ''
        try { $desc = [string]$a.InterfaceDescription } catch { }
        if (-not $desc) { continue }
        if ($desc -match $script:VirtualAdapterPattern) { continue }
        $status = ''
        try { $status = [string]$a.Status } catch { }
        if ($status -and $status -ne 'Up') { continue }

        $ifIndex = 0
        try { $ifIndex = [int]$a.ifIndex } catch { }

        $isWireless = $false
        # NdisPhysicalMedium is the authoritative signal (Native 802.11);
        # the description regex is only a fallback for odd driver names.
        try { if ("$($a.NdisPhysicalMedium)" -match '802\.11') { $isWireless = $true } } catch { }
        if (-not $isWireless -and $desc -match '(?i)wi-?fi|wireless|802\.11|wlan') { $isWireless = $true }

        $guid = ''
        try { $guid = [string]$a.InterfaceGuid } catch { }

        $linkSpeed = ''
        try { $linkSpeed = [string]$a.LinkSpeed } catch { }
        if (-not $linkSpeed) {
            try { $linkSpeed = ('Up {0} Mbps' -f [int]($a.ReceiveSpeed / 1000000)) } catch { }
        }

        $result += @{
            Name          = [string]$a.Name
            Description   = $desc
            IfIndex       = $ifIndex
            IsWireless    = $isWireless
            IsDefault     = ($defaultIfIndexes.Count -gt 0 -and $defaultIfIndexes -contains $ifIndex)
            LinkSpeed     = $linkSpeed
            InterfaceGuid = $guid
        }
    }

    $script:AdapterCache = $result
    $script:AdapterCacheTime = [datetime]::UtcNow
    return $script:AdapterCache
}

function Get-ConnectionTypeFromAdapters {
    <# 'WiFi' | 'Ethernet' | 'Unknown' for an already-fetched adapter list. #>
    param([AllowNull()]$Adapters)
    $list = @($Adapters)
    if ($list.Count -eq 0) { return 'Unknown' }
    $chosen = $null
    foreach ($a in $list) { if ($a['IsDefault']) { $chosen = $a; break } }
    if (-not $chosen) { foreach ($a in $list) { if ($a['IsWireless']) { $chosen = $a; break } } }
    if (-not $chosen) { $chosen = $list[0] }
    if ($chosen['IsWireless']) { return 'WiFi' }
    return 'Ethernet'
}

function Get-ActiveNetworkType {
    <#
        'WiFi', 'Ethernet' or 'Unknown' for the link that carries the
        default route. Cached for 60s; -Refresh forces a fresh probe (the
        profile is applied once per session and must match the link the
        game is about to use).
    #>
    param([switch]$Refresh)
    return (Get-ConnectionTypeFromAdapters @(Get-NetworkAdapterInventory -Refresh:$Refresh))
}

function Get-NetworkLinkStatus {
    <#
        One-shot link report for the status screen: connection type, the
        connected adapters with their negotiated speed, and the NIC
        error/discard counters. Those counters are the only honest LOCAL
        packet-loss evidence available - clean counters while the game
        reports loss means the loss happens somewhere after this PC.
        Cached for 20s; never throws.
    #>
    param([switch]$Refresh, [int]$TtlSeconds = 20)

    if (-not $Refresh -and $null -ne $script:LinkCache -and
        $script:LinkCacheTime -ne [datetime]::MinValue -and
        (([datetime]::UtcNow) - $script:LinkCacheTime).TotalSeconds -le $TtlSeconds) {
        return $script:LinkCache
    }

    $adapters = @(Get-NetworkAdapterInventory -Refresh:$Refresh)
    $report = @{
        ConnectionType = (Get-ConnectionTypeFromAdapters $adapters)
        Adapters       = @()
        RxErrors       = 0L
        RxDiscards     = 0L
        TxDiscards     = 0L
        StatsAvailable = $false
    }

    $statAdapters = @()
    try { $statAdapters = @(Get-NetAdapterStatistics -ErrorAction Stop) } catch { $statAdapters = @() }

    foreach ($a in $adapters) {
        $line = @{
            Name        = $a['Name']
            Description = $a['Description']
            IfIndex     = $a['IfIndex']
            IsWireless  = $a['IsWireless']
            IsDefault   = $a['IsDefault']
            LinkSpeed   = $a['LinkSpeed']
            RxErrors    = 0L
            RxDiscards  = 0L
            TxDiscards  = 0L
        }
        foreach ($s in $statAdapters) {
            if ("$($s.Name)" -ne "$($a['Name'])") { continue }
            $line.RxErrors   = [long]$s.ReceivedPacketErrors
            $line.RxDiscards = [long]$s.ReceivedDiscardedPackets
            $line.TxDiscards = [long]$s.OutboundDiscardedPackets
            $report.RxErrors   += $line.RxErrors
            $report.RxDiscards += $line.RxDiscards
            $report.TxDiscards += $line.TxDiscards
            $report.StatsAvailable = $true
            break
        }
        $report.Adapters += $line
    }

    $script:LinkCache = $report
    $script:LinkCacheTime = [datetime]::UtcNow
    return $script:LinkCache
}

function Update-PacketLossWatch {
    <#
        Samples the NIC error/discard counters and reports only what
        CHANGED since the previous call; the first call just records a
        baseline. Returns '' while nothing new is happening, so the
        caller can log real local packet loss and stay silent otherwise
        (no per-poll log spam).
    #>
    param([switch]$Reset)

    if ($Reset) { $script:LossBaseline = $null; return '' }

    $status = Get-NetworkLinkStatus -Refresh
    $current = @{}
    foreach ($a in @($status.Adapters)) {
        if ($a['IfIndex'] -le 0) { continue }
        $current[[string]$a['IfIndex']] = @{
            Name       = $a['Name']
            RxErrors   = $a['RxErrors']
            RxDiscards = $a['RxDiscards']
            TxDiscards = $a['TxDiscards']
        }
    }
    if ($current.Count -eq 0) { return '' }

    if ($null -eq $script:LossBaseline) {
        $script:LossBaseline = $current
        return ''
    }

    $notes = @()
    foreach ($key in $current.Keys) {
        $now = $current[$key]
        $was = $script:LossBaseline[$key]
        $script:LossBaseline[$key] = $now
        if ($null -eq $was) { continue }
        $dRxErr = $now.RxErrors   - $was.RxErrors
        $dRxDis = $now.RxDiscards - $was.RxDiscards
        $dTxDis = $now.TxDiscards - $was.TxDiscards
        if ($dRxErr -le 0 -and $dRxDis -le 0 -and $dTxDis -le 0) { continue }
        $parts = @()
        if ($dRxErr -gt 0) { $parts += "$dRxErr RX errors" }
        if ($dRxDis -gt 0) { $parts += "$dRxDis RX discards" }
        if ($dTxDis -gt 0) { $parts += "$dTxDis TX discards" }
        $notes += ('{0}: {1}' -f $now.Name, ($parts -join ', '))
    }

    if ($notes.Count -eq 0) { return '' }
    return ('LOCAL packet loss on the network adapter - ' + ($notes -join '; ') +
        '. This is the link/driver dropping packets, not the game server. Check the cable, the Wi-Fi band/signal or the driver.')
}

# ------------------------------------------------------------
# Wireless adapter power mode (powercfg, read back via powrprof
# so the original index is recovered without parsing localized
# `powercfg /query` labels)
# ------------------------------------------------------------
function Add-NativePowerType {
    <# Compiled lazily on first real use - never at module import. #>
    if ('Suite.NativePower' -as [type]) { return }
    Add-Type -Namespace Suite -Name NativePower -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct POWER_READ_AC_VALUE_INDEX
{
    public Guid SchemeGuid;
    public Guid SubGroupOfPowerSettingsGuid;
    public Guid PowerSettingGuid;
    public uint AcValueIndex;
}

[DllImport("powrprof.dll", SetLastError = true)]
public static extern uint PowerActiveScheme(IntPtr UserRootPowerKey, out IntPtr ActivePolicyGuid);

[DllImport("powrprof.dll", SetLastError = true)]
public static extern uint PowerReadACValueIndex(IntPtr RootPowerKey, ref POWER_READ_AC_VALUE_INDEX AcValueIndex);
'@
}

function Get-WirelessPowerIndex {
    <#
        The active power plan's AC index for the wireless "Power Saving
        Mode" setting, or $null when it cannot be read. powrprof is used
        instead of `powercfg /query` because that output is localized and
        guessing which hex value belongs to AC could restore the wrong
        setting. Returns $null rather than a guess - the caller then
        leaves the plan alone, because a value we cannot read is a value
        we could not restore.
    #>
    try {
        Add-NativePowerType
        if (-not ('Suite.NativePower' -as [type])) { return $null }
        $schemePtr = [IntPtr]::Zero
        if ([Suite.NativePower]::PowerActiveScheme([IntPtr]::Zero, [ref]$schemePtr) -ne 0) { return $null }
        if ($schemePtr -eq [IntPtr]::Zero) { return $null }
        try {
            $scheme = [Runtime.InteropServices.Marshal]::PtrToStructure($schemePtr, [type][guid])
            $entry = New-Object Suite.NativePower+POWER_READ_AC_VALUE_INDEX
            $entry.SchemeGuid = $scheme
            $entry.SubGroupOfPowerSettingsGuid = [guid]$script:WirelessSubgroup
            $entry.PowerSettingGuid = [guid]$script:WirelessPowerMode
            $entry.AcValueIndex = 0
            if ([Suite.NativePower]::PowerReadACValueIndex([IntPtr]::Zero, [ref]$entry) -ne 0) { return $null }
            return [int]$entry.AcValueIndex
        } finally {
            # PowerActiveScheme hands back a LocalAlloc'd GUID.
            [void][Runtime.InteropServices.Marshal]::Release($schemePtr)
        }
    } catch { return $null }
}

function Set-WirelessPowerIndex {
    <# 0 = maximum performance. Returns $true when the write was accepted. #>
    param([Parameter(Mandatory)][int]$Index)
    try {
        $pc = Get-Command powercfg -ErrorAction SilentlyContinue
        if (-not $pc) { return $false }
        & $pc /setacvalueindex 'SCHEME_CURRENT' $script:WirelessSubgroup $script:WirelessPowerMode $Index | Out-Null
        # A value-index write only takes effect once the plan is re-applied.
        & $pc /setactive 'SCHEME_CURRENT' | Out-Null
        return $true
    } catch { return $false }
}

# ------------------------------------------------------------
# NIC driver settings (offloads, roaming, interrupt moderation)
# ------------------------------------------------------------
function Get-NicClassKeyPath {
    <#
        The driver class key of ONE specific adapter, matched through
        NetCfgInstanceId (the adapter's interface GUID). An earlier
        version walked every {4d36e972...} subkey and patched any NIC it
        recognised by description, which can also hit adapters that are
        not even in this machine. Matching a single adapter means only
        the NIC the game actually uses is changed. Returns $null when the
        mapping is unknown, so we skip instead of guessing.
    #>
    param([string]$InterfaceGuid)
    if (-not $InterfaceGuid) { return $null }
    $wanted = $InterfaceGuid.Trim()
    try {
        foreach ($k in @(Get-ChildItem -Path $script:NicClassBase -ErrorAction SilentlyContinue |
                        Where-Object { $_.PSChildName -match '^00\d+$' })) {
            $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $pi = $p.PSObject.Properties['NetCfgInstanceId']
            if (-not $pi) { continue }
            if ([string]::Equals("$($pi.Value)".Trim(), $wanted, [StringComparison]::OrdinalIgnoreCase)) {
                return (ConvertTo-NativeRegPath $k.Name)
            }
        }
    } catch { }
    return $null
}

function Get-NicAdvancedPropertyState {
    <#
        Reads one advanced driver property of one adapter and returns its
        current state (registry value + display value + name), or $null
        when the driver does not expose that property at all.
    #>
    param([Parameter(Mandatory)][string]$AdapterName, [string]$RegistryKeyword, [string]$DisplayName)
    try {
        foreach ($p in @(Get-NetAdapterAdvancedProperty -Name $AdapterName -ErrorAction Stop)) {
            $kw = ''
            try { $kw = [string]$p.RegistryKeyword } catch { }
            $nm = ''
            try { $nm = [string]$p.Name } catch { }
            $hit = $false
            if ($RegistryKeyword) { $hit = ($kw -eq $RegistryKeyword) }
            elseif ($DisplayName)  { $hit = ($nm -eq $DisplayName) }
            if (-not $hit) { continue }
            return @{
                Name          = $nm
                RegistryValue = [string]$p.RegistryValue
                DisplayValue  = [string]$p.DisplayValue
            }
        }
    } catch { }
    return $null
}

function Set-NicAdvancedProperty {
    <#
        Writes one advanced driver property. -Name is always the ADAPTER;
        the property itself is selected by -RegistryKeyword (locale
        independent, preferred) or, on drivers that do not expose the
        keyword, by its current -DisplayValue. Never throws: an
        unsupported property is a no-op, not an error.
    #>
    param(
        [Parameter(Mandatory)][string]$AdapterName,
        [string]$RegistryKeyword,
        [string]$RegistryValue,
        [string]$DisplayName
    )
    if ($RegistryKeyword -and $RegistryValue) {
        try {
            Set-NetAdapterAdvancedProperty -Name $AdapterName -RegistryKeyword $RegistryKeyword `
                -RegistryValue $RegistryValue -NoRestart -ErrorAction Stop | Out-Null
            return $true
        } catch { }
    }
    if ($DisplayName) {
        try {
            $splat = @{ Name = $AdapterName; DisplayValue = $DisplayName; NoRestart = $true; ErrorAction = 'Stop' }
            if ($RegistryValue) { $splat['RegistryValue'] = $RegistryValue }
            Set-NetAdapterAdvancedProperty @splat | Out-Null
            return $true
        } catch { }
    }
    return $false
}

function Restore-NicAdvancedProperty {
    <#
        Puts a previously read advanced property back. -Name is always the
        adapter, the property is selected by -RegistryKeyword, and the
        value is written numerically from the journal, so a localized
        display value never has to be parsed back. Never throws.
    #>
    param([Parameter(Mandatory)][string]$AdapterName, [string]$RegistryKeyword, $Original)
    $origValue = [string](Get-StateField $Original 'RegistryValue')
    if (-not $origValue) { return $false }
    try {
        if ($RegistryKeyword) {
            Set-NetAdapterAdvancedProperty -Name $AdapterName -RegistryKeyword $RegistryKeyword `
                -RegistryValue $origValue -NoRestart -ErrorAction Stop | Out-Null
            return $true
        }
        # No keyword recorded: select the property by the display value it
        # has RIGHT NOW (the value we replaced is the one being restored,
        # so the recorded DisplayValue no longer matches anything).
        $cur = Get-NicAdvancedPropertyState -AdapterName $AdapterName -DisplayName ([string](Get-StateField $Original 'Name'))
        if (-not $cur) { return $false }
        Set-NetAdapterAdvancedProperty -Name $AdapterName -DisplayValue ([string]$cur['DisplayValue']) `
            -RegistryValue $origValue -NoRestart -ErrorAction Stop | Out-Null
        return $true
    } catch { return $false }
}

function Get-AdapterOffloadState {
    <#
        Current Receive-Segment-Coalescing / Large-Send-Offload state of
        one adapter: 'Enabled', 'Disabled' or 'NotSupported'. RSC and LSO
        let the driver hold small packets back to build large ones - pure
        added latency for a game, and on some drivers a cause of dropped
        small UDP packets. Returns $null when the module cannot report it.
    #>
    param([Parameter(Mandatory)][string]$AdapterName, [Parameter(Mandatory)][ValidateSet('Rsc','Lso')][string]$Kind)
    try {
        $o = if ($Kind -eq 'Rsc') { @(Get-NetAdapterRsc -Name $AdapterName -ErrorAction Stop)[0] }
             else                  { @(Get-NetAdapterLso -Name $AdapterName -ErrorAction Stop)[0] }
        if (-not $o) { return $null }
        $pi = $o.PSObject.Properties['State']
        if (-not $pi) { return $null }
        return [string]$pi.Value
    } catch { return $null }
}

function Set-AdapterOffloadState {
    param([Parameter(Mandatory)][string]$AdapterName, [Parameter(Mandatory)][ValidateSet('Rsc','Lso')][string]$Kind, [Parameter(Mandatory)][string]$Value)
    try {
        if ($Kind -eq 'Rsc') { Set-NetAdapterRsc -Name $AdapterName -Value $Value -NoRestart -ErrorAction Stop | Out-Null }
        else                  { Set-NetAdapterLso -Name $AdapterName -Value $Value -NoRestart -ErrorAction Stop | Out-Null }
        return $true
    } catch { return $false }
}

function Merge-AdapterRec {
    <# Adds one property to an adapter's journal node without losing the rest. #>
    param([Parameter(Mandatory)][hashtable]$Map, $Adapter, [string]$Key, $Value)
    $id = [string]$Adapter['IfIndex']
    $node = @{}
    if ($Map.ContainsKey($id)) { $node = $Map[$id] }
    $node['Name'] = $Adapter['Name']
    $node[$Key]   = $Value
    $Map[$id] = $node
    return $Map
}

# ------------------------------------------------------------
# Delivery Optimization (the LAN peer-download service)
# ------------------------------------------------------------
function Set-BackgroundDownloadState {
    <#
        Delivery Optimization (DoSvc) shares the upload bandwidth with
        strangers on the LAN and can saturate the link in the background -
        the classic cause of "ping jumps to 200ms while I am not even
        downloading anything". It is stopped for the session, and its exact
        startup mode + running state are recorded so it comes back
        untouched.
    #>
    param([Parameter(Mandatory)][hashtable]$Record)
    try {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='DoSvc'" -ErrorAction Stop
        if (-not $svc) { return $false }
        $wasRunning = ([string]$svc.State -eq 'Running')
        # Recorded BEFORE the first change: a crash between here and the
        # undo step must not leave the service disabled with no journal.
        $Record['StartMode']  = [string]$svc.StartMode
        $Record['WasRunning'] = $wasRunning
        try {
            if ($wasRunning) { Stop-Service -Name 'DoSvc' -Force -ErrorAction Stop }
            Set-Service -Name 'DoSvc' -StartupType Disabled -ErrorAction Stop
        } catch {
            # A partial failure (stopped but not disabled) still has to be
            # undone, so the record is honored and the undo step runs.
            Write-Log ("Delivery Optimization: could not be disabled (" + $_.Exception.Message + ') - it may keep running this session.') 'WARN'
        }
        return $true
    } catch { return $false }
}

function Restore-BackgroundDownloadState {
    param($Original)
    $startMode  = Get-StateField $Original 'StartMode'
    $wasRunning = Get-StateField $Original 'WasRunning'
    if ($null -eq $startMode) { return $false }
    try {
        # TriggerStart is a flavour of Manual and Set-Service has no
        # separate mode for it; Disabled / Automatic map directly.
        $target = 'Manual'
        if ("$startMode" -eq 'Auto')     { $target = 'Automatic' }
        if ("$startMode" -eq 'Disabled') { $target = 'Disabled' }
        Set-Service -Name 'DoSvc' -StartupType $target -ErrorAction SilentlyContinue
        if ($wasRunning) { Start-Service -Name 'DoSvc' -ErrorAction SilentlyContinue }
        return $true
    } catch { return $false }
}

function Remove-ManagedNetDefaults {
    <#
        Undo for a standalone apply that has no journal: reverts the exact
        values this profile writes, and only when the current value still
        looks like the one we would have set - so a value the user (or
        another tool) changed afterwards is left alone.

        Restoring what a journal WOULD have recorded means guessing the
        Windows default for two groups, and the guess is logged:
          - offloads: we only ever turn RSC/LSO off, so "off" -> "on"
          - Delivery Optimization: we only ever disable it, so
            "Disabled" -> Automatic + running (Windows 10/11 default)
        The wireless power-plan index is deliberately NOT guessed - the
        original was 0 (Max performance), 2 (Balanced) or 3 (Saver) and
        picking the wrong one would either waste battery or keep the old
        latency problem. It is reported so the user can set it in
        `powercfg` if a standalone apply left it at Maximum performance.

        -RestartAdapters honors the user's RestartChangedAdapters choice: a
        queued driver write only takes effect after a reload, but a user who
        turned restarts off must not get them anyway.
    #>
    param([bool]$RestartAdapters = $true)

    $cleaned = @()

    $simple = @(
        @{ Path = $script:SysProfile;   Name = 'NetworkThrottlingIndex'; Value = -1 },
        @{ Path = $script:QosPolicyKey; Name = 'NonBestEffortLimit';     Value = 0  },
        @{ Path = $script:TcpParams;    Name = 'TcpAutotuningLevel';     Value = -1 }
    )
    foreach ($s in $simple) {
        try {
            if ((Get-RegRawValue -Path $s.Path -Name $s.Name) -eq $s.Value) {
                Remove-RegValue -Path $s.Path -Name $s.Name
                $cleaned += $s.Name
            }
        } catch { }
    }

    foreach ($k in @(Get-ChildItem -Path $script:TcpIpIfBase -ErrorAction SilentlyContinue)) {
        $path = ConvertTo-NativeRegPath $k.Name
        foreach ($n in @(@('TCPNoDelay', @(1)), @('TcpAckFrequency', @(1, 2)), @('TcpDelAckTicks', @(0, 2)))) {
            try {
                $cur = Get-RegRawValue -Path $path -Name $n[0]
                if ("$cur" -eq $script:AbsentMarker) { continue }
                if (@($n[1]) -contains [int]$cur) {
                    Remove-RegValue -Path $path -Name $n[0]
                    $cleaned += "$($n[0]) on $path"
                }
            } catch { }
        }
    }

    $pnpRemoved = @()
    foreach ($k in @(Get-ChildItem -Path $script:NicClassBase -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -match '^00\d+$' })) {
        try {
            $path = ConvertTo-NativeRegPath $k.Name
            if ((Get-RegRawValue -Path $path -Name 'PnPCapabilities') -eq 24) {
                Remove-RegValue -Path $path -Name 'PnPCapabilities'
                $pnpRemoved += $path
                $cleaned += "PnPCapabilities on $path"
            }
        } catch { }
    }

    # ---- adapter offloads: this profile only ever disables them -------
    $offloadRestored = @()
    foreach ($a in @(Get-NetworkAdapterInventory -Refresh)) {
        foreach ($kind in @('Rsc','Lso')) {
            try {
                $state = Get-AdapterOffloadState -AdapterName $a['Name'] -Kind $kind
                if ($state -ne 'Disabled') { continue }
                if (Set-AdapterOffloadState -AdapterName $a['Name'] -Kind $kind -Value 'Enabled') {
                    $offloadRestored += $a['Name']
                }
            } catch { }
        }
    }

    # ---- Delivery Optimization: we only ever disable it ---------------
    $doRestored = $false
    try {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='DoSvc'" -ErrorAction Stop
        if ($svc -and "$($svc.StartMode)" -eq 'Disabled') {
            Set-Service -Name 'DoSvc' -StartupType Automatic -ErrorAction SilentlyContinue
            if ("$($svc.State)" -ne 'Running') { Start-Service -Name 'DoSvc' -ErrorAction SilentlyContinue }
            $doRestored = $true
        }
    } catch { }

    $wirelessNote = ''
    try {
        $wp = Get-WirelessPowerIndex
        if ($null -ne $wp -and $wp -eq 0) {
            $wirelessNote = ('wireless adapter power mode is still Maximum performance (index 0) - set it back with: powercfg /setacvalueindex SCHEME_CURRENT {0} {1} 2' -f $script:WirelessSubgroup, $script:WirelessPowerMode)
        }
    } catch { }

    if ($offloadRestored.Count -gt 0) {
        $cleaned += ("RSC/LSO re-enabled on: " + (($offloadRestored | Select-Object -Unique) -join ', '))
    }
    if ($doRestored) { $cleaned += 'Delivery Optimization re-enabled' }
    if ($wirelessNote) { $cleaned += $wirelessNote }

    # ---- reload the drivers that actually changed --------------------
    # Offload/PnPCapabilities writes are queued by the driver; only the
    # adapters that were actually touched get restarted.
    $needsRestart = @()
    if ($RestartAdapters) {
        foreach ($a in @(Get-NetworkAdapterInventory)) {
            if ($offloadRestored -contains $a['Name']) {
                $needsRestart += $a['Name']
                continue
            }
            if ($pnpRemoved.Count -gt 0) {
                try {
                    if ($pnpRemoved -contains (Get-NicClassKeyPath -InterfaceGuid $a['InterfaceGuid'])) {
                        $needsRestart += $a['Name']
                    }
                } catch { }
            }
        }
    }
    foreach ($name in @($needsRestart | Select-Object -Unique)) {
        try { Restart-NetAdapter -Name $name -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
    }

    return $cleaned
}

# ------------------------------------------------------------
# Main entry points
# ------------------------------------------------------------
function Enable-NetworkLatencyProfile {
    <#
        Applies the low-latency profile. Every tweak is individually
        switchable through Config.ps1 > NetworkOptimization, and every
        change records its ORIGINAL value in the recovery journal, so
        Undo-NetworkLatencyProfile restores the machine exactly -
        including values that did not exist before, which are removed
        again instead of being left behind.

        -JournalState is the watcher recovery journal hashtable. Pass $null
        for a standalone apply (the settings then persist until reverted
        with -RemoveKnownDefaults).

        Never throws apart from the administrator check.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Settings,
        [AllowNull()]$JournalState
    )

    # Master switch: Config.ps1 > NetworkOptimization > Enabled. Checked
    # BEFORE the admin test so a disabled profile never demands elevation.
    if (-not (Get-TweakBool $Settings 'Enabled' $true)) {
        Write-Log 'Network profile disabled in Config.ps1 - nothing applied.' 'INFO'
        return
    }

    # HKLM / adapter / service writes need an elevated token; the .bat
    # launcher self-elevates, so the hard requirement is correct here.
    Assert-AdminOrThrow

    $adapters    = @(Get-NetworkAdapterInventory -Refresh)
    $connType    = Get-ConnectionTypeFromAdapters $adapters
    $hasWireless = (@($adapters | Where-Object { $_['IsWireless'] }).Count -gt 0)

    # The record is created FIRST and is a reference type, so every later
    # mutation is already covered: a crash halfway through this function
    # still leaves the repair step a complete list of what to undo.
    $rec = @{
        ConnectionType = $connType
        Reg            = @{}
        Adapters       = @{}
        AdvancedProps  = @{}
        WirelessPower  = $null
        DeliveryOpt    = $null
    }
    if ($null -ne $JournalState) { $JournalState['netLatency'] = $rec }

    if ($adapters.Count -eq 0) {
        Write-Log 'Network profile: no connected physical adapter found - nothing to tune.' 'WARN'
        return
    }
    Write-Log ("Network profile: connection is {0}{1}." -f $connType,
        $(if ($hasWireless) { ' (wireless adapter present)' } else { '' })) 'INFO'

    $applied = @()
    $skipped = @()
    $restartAdapters = @()

    # ---- 1. Windows multimedia network throttling ---------------------
    if (Get-TweakBool $Settings 'DisableNetworkThrottling' $true) {
        try {
            Add-RegRecord -Record $rec.Reg -Path $script:SysProfile -Name 'NetworkThrottlingIndex' -Value -1
            $applied += 'multimedia network throttling off'
        } catch { $skipped += "throttling: $($_.Exception.Message)" }
    }

    # ---- 2. QoS reserved-bandwidth limit ------------------------------
    if (Get-TweakBool $Settings 'RemoveBandwidthLimit' $true) {
        try {
            Add-RegRecord -Record $rec.Reg -Path $script:QosPolicyKey -Name 'NonBestEffortLimit' -Value 0
            $applied += 'QoS bandwidth limit removed'
        } catch { $skipped += "QoS: $($_.Exception.Message)" }
    }

    # ---- 3. TCP receive-window health ---------------------------------
    # A previous "game booster" often left TcpAutotuningLevel at 0
    # (disabled) or 1/2 (limited). A limited receive window collapses
    # under load and is one of the most common SOFTWARE causes of
    # phantom packet loss, so it goes back to Normal. A fixed
    # GlobalMaxTcpWindowSize is deliberately NOT forced any more: 1 MB is
    # SMALLER than a healthy autotuned window on a modern link, so
    # hard-coding it caps throughput and becomes its own kind of stall.
    if (Get-TweakBool $Settings 'RepairTcpWindow' $true) {
        try {
            $current = Get-RegRawValue -Path $script:TcpParams -Name 'TcpAutotuningLevel'
            if ("$current" -ne $script:AbsentMarker -and [int]$current -ne -1) {
                Add-RegRecord -Record $rec.Reg -Path $script:TcpParams -Name 'TcpAutotuningLevel' -Value -1
                $applied += "TCP auto-tuning restored to Normal (was $current)"
            } else {
                $applied += 'TCP auto-tuning already Normal'
            }
        } catch { $skipped += "TCP auto-tune: $($_.Exception.Message)" }
    }

    # ---- 4. Per-interface TCP latency (TCP traffic only) --------------
    if (Get-TweakBool $Settings 'TcpLowLatency' $true) {
        try {
            $activeIf = @($adapters | Where-Object { $_['IfIndex'] -gt 0 } | ForEach-Object { $_['IfIndex'] })
            $tuned = 0
            foreach ($k in @(Get-ChildItem -Path $script:TcpIpIfBase -ErrorAction SilentlyContinue)) {
                try {
                    # Only adapters that are actually connected: every Tcpip
                    # interface key carries the matching ifIndex.
                    if ($activeIf.Count -gt 0) {
                        $kProp = Get-ItemProperty -Path $k.PSPath -ErrorAction Stop
                        if ($kProp.PSObject.Properties['ifIndex'] -and "$($kProp.ifIndex)" -match '^\d+$') {
                            if ($activeIf -notcontains [int]$kProp.ifIndex) { continue }
                        }
                    }
                    $path = ConvertTo-NativeRegPath $k.Name
                    Add-RegRecord -Record $rec.Reg -Path $path -Name 'TCPNoDelay' -Value 1
                    if ($connType -eq 'Ethernet') {
                        Add-RegRecord -Record $rec.Reg -Path $path -Name 'TcpAckFrequency' -Value 1
                        Add-RegRecord -Record $rec.Reg -Path $path -Name 'TcpDelAckTicks'    -Value 0
                    } else {
                        # Wireless: acknowledge every 2nd segment. Forcing
                        # value 1 on Wi-Fi floods the radio with ACKs and
                        # CAUSES packet loss - the mistake the old profile
                        # made on Wi-Fi machines.
                        Add-RegRecord -Record $rec.Reg -Path $path -Name 'TcpAckFrequency' -Value 2
                        Add-RegRecord -Record $rec.Reg -Path $path -Name 'TcpDelAckTicks'    -Value 2
                    }
                    $tuned++
                } catch { }
            }
            if ($tuned -gt 0) {
                $applied += "TCP no-delay/ACK tuned on $tuned connected interface(s) [$connType profile]"
            }
        } catch { $skipped += "TCP interface tuning: $($_.Exception.Message)" }
    }

    # ---- 5. NIC power saving ------------------------------------------
    # The biggest local cause of "packet loss that is not the router's
    # fault" on wireless, and of millisecond hitches on copper: Windows
    # otherwise parks the adapter between bursts and wakes it on a timer.
    if (Get-TweakBool $Settings 'DisableNicPowerSaving' $true) {
        foreach ($a in $adapters) {
            try {
                $classPath = Get-NicClassKeyPath -InterfaceGuid $a['InterfaceGuid']
                if (-not $classPath) {
                    $skipped += "power saving: driver key for '$($a['Name'])' not identified (left untouched)"
                    continue
                }
                # 0x18 = never let Windows power this adapter down.
                if ((Get-RegRawValue -Path $classPath -Name 'PnPCapabilities') -ne 24) {
                    Add-RegRecord -Record $rec.Reg -Path $classPath -Name 'PnPCapabilities' -Value 24
                    $restartAdapters += $a['Name']
                    $applied += "adapter power-down disabled on $($a['Name'])"
                }
            } catch { }
        }
    }

    # ---- 6. Wireless adapter power plan -------------------------------
    if ($hasWireless -and (Get-TweakBool $Settings 'WirelessMaxPerformance' $true)) {
        try {
            $orig = Get-WirelessPowerIndex
            if ($null -eq $orig) {
                if (-not $script:WirelessProbeWarned) {
                    Write-Log 'Wireless power mode: current power-plan index could not be read - left untouched (a value we cannot read is a value we could not restore).' 'WARN'
                    $script:WirelessProbeWarned = $true
                }
            } elseif ($orig -ne 0) {
                if (Set-WirelessPowerIndex -Index 0) {
                    $rec.WirelessPower = @{ OriginalIndex = $orig }
                    $applied += 'wireless adapter power mode = Maximum performance (AC)'
                }
            } else {
                $applied += 'wireless adapter already at Maximum performance'
            }
        } catch { $skipped += "wireless power plan: $($_.Exception.Message)" }
    }

    # ---- 7. Receive Segment Coalescing off ----------------------------
    if (Get-TweakBool $Settings 'DisableReceiveSegmentCoalescing' $true) {
        foreach ($a in $adapters) {
            try {
                $state = Get-AdapterOffloadState -AdapterName $a['Name'] -Kind 'Rsc'
                if (-not $state -or $state -eq 'NotSupported' -or $state -eq 'Disabled') { continue }
                if (Set-AdapterOffloadState -AdapterName $a['Name'] -Kind 'Rsc' -Value 'Disabled') {
                    $rec.Adapters = Merge-AdapterRec $rec.Adapters $a 'Rsc' $state
                    $restartAdapters += $a['Name']
                    $applied += "RSC off on $($a['Name'])"
                }
            } catch { }
        }
    }

    # ---- 8. Large Send Offload off ------------------------------------
    if (Get-TweakBool $Settings 'DisableLargeSendOffload' $true) {
        foreach ($a in $adapters) {
            try {
                $state = Get-AdapterOffloadState -AdapterName $a['Name'] -Kind 'Lso'
                if (-not $state -or $state -eq 'NotSupported' -or $state -eq 'Disabled') { continue }
                if (Set-AdapterOffloadState -AdapterName $a['Name'] -Kind 'Lso' -Value 'Disabled') {
                    $rec.Adapters = Merge-AdapterRec $rec.Adapters $a 'Lso' $state
                    $restartAdapters += $a['Name']
                    $applied += "large-send offload off on $($a['Name'])"
                }
            } catch { }
        }
    }

    # ---- 9. Wi-Fi roaming ---------------------------------------------
    # 0 = lowest roaming aggressiveness: the card stays on the access
    # point it already has instead of hopping to a weaker one mid-round,
    # and a roaming event can move the RTT by tens of milliseconds.
    if ($hasWireless -and (Get-TweakBool $Settings 'WifiStayOnStrongest' $true)) {
        foreach ($a in $adapters) {
            if (-not $a['IsWireless']) { continue }
            try {
                $state = Get-NicAdvancedPropertyState -AdapterName $a['Name'] -RegistryKeyword '*RoamingAggressiveness'
                if ($null -eq $state) { continue }
                if (Set-NicAdvancedProperty -AdapterName $a['Name'] -RegistryKeyword '*RoamingAggressiveness' `
                        -RegistryValue '0' -DisplayName 'Lowest') {
                    $rec.AdvancedProps[("{0}|*RoamingAggressiveness" -f $a['Name'])] = $state
                    # Queued driver property: the adapter restart below is
                    # what actually makes the new value take effect.
                    $restartAdapters += $a['Name']
                    $applied += "Wi-Fi roaming set to lowest on $($a['Name'])"
                }
            } catch { }
        }
    }

    # ---- 10. Interrupt moderation (OFF by default) --------------------
    # Disabling it lowers jitter but raises CPU during the match, which is
    # a bad trade on the low-spec machines this suite targets - so it ships
    # disabled and is one config line away.
    if (Get-TweakBool $Settings 'DisableInterruptModeration' $false) {
        foreach ($a in $adapters) {
            try {
                $state = Get-NicAdvancedPropertyState -AdapterName $a['Name'] -RegistryKeyword '*InterruptModeration'
                if ($null -eq $state) { continue }
                if (Set-NicAdvancedProperty -AdapterName $a['Name'] -RegistryKeyword '*InterruptModeration' `
                        -RegistryValue '0' -DisplayName 'Disabled') {
                    $rec.AdvancedProps[("{0}|*InterruptModeration" -f $a['Name'])] = $state
                    $restartAdapters += $a['Name']
                    $applied += "interrupt moderation off on $($a['Name'])"
                }
            } catch { }
        }
    }

    # ---- 11. Background downloads -------------------------------------
    if (Get-TweakBool $Settings 'PauseBackgroundDownloads' $true) {
        $do = @{}
        if (Set-BackgroundDownloadState -Record $do) {
            $rec.DeliveryOpt = $do
            $applied += 'Delivery Optimization (background P2P downloads) paused'
        }
    }

    # Driver-level changes are queued until the adapter restarts. Do it
    # now - while the profile is applied before the game starts, or after
    # it closed - and only for the adapters we actually changed, so VMs,
    # VPNs and virtual switches are never bounced.
    if ($restartAdapters.Count -gt 0 -and (Get-TweakBool $Settings 'RestartChangedAdapters' $true)) {
        $unique = @($restartAdapters | Select-Object -Unique)
        Write-Log ('Reapplying adapter driver settings (network blips for a few seconds on: ' + ($unique -join ', ') + ').') 'INFO'
        foreach ($name in $unique) {
            try { Restart-NetAdapter -Name $name -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
    }

    if ($applied.Count -gt 0) {
        Write-Log ("Network latency profile ACTIVE ($connType): " + ($applied -join '; ') + '.') 'OK'
    } else {
        Write-Log 'Network profile: nothing to change on this machine.' 'INFO'
    }
    if ($skipped.Count -gt 0) {
        Write-Log ('Network profile skipped: ' + ($skipped -join '; ') + '.') 'WARN'
    }
    Write-Log 'Network settings are reverted when the game session ends or the watcher stops.' 'INFO'
}

function Undo-NetworkLatencyProfile {
    <#
        Exact revert of Enable-NetworkLatencyProfile from its journal node,
        or -RemoveKnownDefaults to strip the values this profile manages
        (for a standalone apply where no journal exists; -Settings is only
        consulted there, for the RestartChangedAdapters preference).

        Every group is restored independently, so one failing driver
        never prevents the rest of the machine from being put back.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$JournalState,
        [AllowNull()]$Settings,
        [switch]$RemoveKnownDefaults
    )

    $net = $null
    if ($null -ne $JournalState) { $net = Get-StateField $JournalState 'netLatency' }
    if ($null -eq $net) {
        if (-not $RemoveKnownDefaults) {
            Write-Log 'Network profile: nothing to revert (no journal).' 'INFO'
            return
        }
        $wantRestart = $true
        if ($null -ne $Settings -and $Settings -is [System.Collections.IDictionary] -and $Settings.Contains('RestartChangedAdapters')) {
            $wantRestart = [bool]$Settings['RestartChangedAdapters']
        }
        $removed = Remove-ManagedNetDefaults -RestartAdapters $wantRestart
        if (@($removed).Count -gt 0) {
            Write-Log ('Network profile cleanup (no journal found): ' + (@($removed) -join '; ') + '.') 'OK'
        } else {
            Write-Log 'No managed network values found - nothing to remove.' 'INFO'
        }
        return
    }

    $restored = @()
    $restartAdapters = @()

    # ---- advanced driver properties -----------------------------------
    $adv = Get-StateField $net 'AdvancedProps'
    if ($adv -is [System.Collections.IDictionary]) {
        foreach ($key in @($adv.Keys)) {
            try {
                $parts = ([string]$key) -split '\|'
                if ($parts.Count -lt 2) { continue }
                if (Restore-NicAdvancedProperty -AdapterName $parts[0] -RegistryKeyword $parts[1] -Original $adv[$key]) {
                    $restored += "driver property $($parts[1]) on $($parts[0])"
                    $restartAdapters += $parts[0]
                }
            } catch { }
        }
    }

    # ---- adapter offloads (restore the recorded ORIGINAL state) -------
    $ads = Get-StateField $net 'Adapters'
    if ($ads -is [System.Collections.IDictionary]) {
        foreach ($id in @($ads.Keys)) {
            $node = $ads[$id]
            $name = [string](Get-StateField $node 'Name')
            if (-not $name) { continue }
            foreach ($kind in @('Rsc','Lso')) {
                $state = Get-StateField $node $kind
                if (-not $state) { continue }
                if (Set-AdapterOffloadState -AdapterName $name -Kind $kind -Value ([string]$state)) {
                    $restored += "$kind back to $state on $name"
                    $restartAdapters += $name
                }
            }
        }
    }

    # ---- wireless power plan ------------------------------------------
    $wp = Get-StateField $net 'WirelessPower'
    if ($null -ne $wp) {
        $orig = Get-StateField $wp 'OriginalIndex'
        $num = 0
        if ($null -ne $orig -and [int]::TryParse("$orig", [ref]$num)) {
            if (Set-WirelessPowerIndex -Index $num) {
                $restored += "wireless power mode back to index $num"
            }
        }
    }

    # ---- Delivery Optimization ----------------------------------------
    $do = Get-StateField $net 'DeliveryOpt'
    if ($null -ne $do) {
        if (Restore-BackgroundDownloadState -Original $do) {
            $restored += 'Delivery Optimization restored'
        }
    }

    # ---- registry values (cheap and always available, do them last) ---
    $reg = Get-StateField $net 'Reg'
    if ($reg -is [System.Collections.IDictionary]) {
        foreach ($key in @($reg.Keys)) {
            try {
                $parts = ([string]$key) -split '\|'
                if ($parts.Count -lt 2) { continue }
                if (Restore-RegRecord -Record $reg -Path $parts[0] -Name $parts[1]) {
                    $restored += "$($parts[1])"
                }
            } catch { }
        }
    }

    if ($restartAdapters.Count -gt 0) {
        foreach ($name in @($restartAdapters | Select-Object -Unique)) {
            try { Restart-NetAdapter -Name $name -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
    }

    if ($restored.Count -gt 0) {
        Write-Log ('Network latency profile reverted: ' + ($restored -join '; ') + '.') 'OK'
    } else {
        Write-Log 'Network profile: nothing needed reverting.' 'INFO'
    }
}

Export-ModuleMember -Function Enable-NetworkLatencyProfile, Undo-NetworkLatencyProfile,
    Get-ActiveNetworkType, Get-NetworkLinkStatus, Update-PacketLossWatch
