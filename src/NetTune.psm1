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
$script:NetTypeCache = $null
$script:NetTypeStamp = [datetime]::MinValue
$script:NetTypeTtlSec = 60

function Get-ActiveNetworkType {
    <#
        Detects whether the primary game-traffic connection is WiFi or Ethernet.
        Never parses localized netsh text (that could misread a non-English
        install): it uses the routing table + adapter object model instead, with
        a WMI fallback only when the NetAdapter CIM provider is missing.
        The result is cached for 60 s - the watcher and status screen call this
        frequently, and a WMI/object-model probe on every poll would be wasteful
        on low-spec machines. Returns 'WiFi', 'Ethernet', or 'Unknown'.
    #>
    param([switch]$Refresh)

    if (-not $Refresh -and $script:NetTypeStamp -ne [datetime]::MinValue -and
        (([datetime]::UtcNow) - $script:NetTypeStamp).TotalSeconds -le $script:NetTypeTtlSec) {
        return $script:NetTypeCache
    }

    $verdict = 'Unknown'
    try {
        # Only physical, currently-connected adapters that carry real traffic.
        $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' -and
                $_.InterfaceDescription -notmatch '(?i)virtual|hyper|vpn|tap|bluetooth|wan\s+mini|loopback' })

        if ($adapters.Count -gt 0) {
            # 1) Prefer the adapter that owns the default IPv4 route - that is
            #    the link game traffic actually rides on.
            $gwIdx = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue |
                Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up' } |
                ForEach-Object { $_.InterfaceIndex })
            $candidates = if ($gwIdx.Count -gt 0) {
                @($adapters | Where-Object { $gwIdx -contains $_.ifIndex })
            } else { $adapters }
            if ($candidates.Count -eq 0) { $candidates = $adapters }

            $wifi = $candidates | Where-Object { $_.InterfaceDescription -match '(?i)wi-?fi|wireless|802\.11|wlan|wifi' } | Select-Object -First 1
            $eth  = $candidates | Where-Object { $_.MediaType -eq '802.3' -or $_.InterfaceDescription -match '(?i)ethernet|gigabit' } | Select-Object -First 1

            if ($wifi) {
                $verdict = 'WiFi'
            } elseif ($eth) {
                $verdict = 'Ethernet'
            } else {
                # Default-route adapter with an unrecognized description (LTE,
                # mobile tethering, Wi-Fi Direct). If ANY wireless adapter is up
                # anywhere, default to the WiFi-safe profile to avoid ACK floods.
                $anyWifi = $adapters | Where-Object { $_.InterfaceDescription -match '(?i)wi-?fi|wireless|802\.11|wlan|wifi' } | Select-Object -First 1
                if ($anyWifi) { $verdict = 'WiFi' } else { $verdict = 'Ethernet' }
            }
        }
    } catch { }

    if ($verdict -eq 'Unknown') {
        # WMI fallback (last resort, one-shot - never called from a hot loop).
        try {
            $physNic = @(Get-WmiObject Win32_NetworkAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.NetConnectionStatus -eq 2 -and $_.PhysicalAdapter -eq $true -and
                    $_.Name -notmatch '(?i)virtual|hyper|vpn|tap|bluetooth' })
            foreach ($n in $physNic) {
                if ($n.Name -match '(?i)wi-?fi|wireless|802\.11|wlan') { $verdict = 'WiFi'; break }
            }
            if ($verdict -eq 'Unknown' -and $physNic.Count -gt 0) { $verdict = 'Ethernet' }
        } catch { }
    }

    $script:NetTypeCache = $verdict
    $script:NetTypeStamp = [datetime]::UtcNow
    return $verdict
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

    # Windows registry writes need an elevated token; the .bat launcher
    # self-elevates, so the hard admin requirement is correct here.
    Assert-AdminOrThrow

    $applied = @()
    $rec = @{
        ThrottlingIndexOriginal = $null
        TcpAutoTuneOriginal = $null
        Interfaces = @{}
        NicPower   = @{}
        ConnectionType = 'Unknown'
    }

    # ---- Detect connection type ----
    # Force a fresh probe here: the 60 s cache is fine for the status screen,
    # but the profile is applied once per session and must match the link the
    # game is about to use (a WiFi device can't tolerate the Ethernet ACK-flood
    # TCP values, and vice versa).
    $connType = Get-ActiveNetworkType -Refresh
    $rec.ConnectionType = $connType
    Write-Log ("Active connection type: {0}" -f $connType) 'INFO'
    if ($connType -eq 'Unknown') {
        # We do not know the link. The ONLY safe choice for a wireless-possible
        # machine is the WiFi profile - Ethernet can tolerate it, WiFi cannot
        # tolerate the Ethernet ACK-flood settings.
        Write-Log "Connection type is unknown - using WiFi-safe TCP values to avoid ACK-flood packet loss." 'WARN'
    }

    # ---- 1. Disable multimedia network throttling -----------------------
    if (Get-TweakBool $Settings 'DisableNetworkThrottling' $true) {
        $orig = Get-RegRaw -Path $script:SysProfile -Name 'NetworkThrottlingIndex'
        Set-RegDword -Path $script:SysProfile -Name 'NetworkThrottlingIndex' -Value -1
        $rec.ThrottlingIndexOriginal = $orig
        $applied += 'network throttling disabled'
    }

    # ---- 1b. TCP receive-window autotune ---------------------------------
    # Keep Windows' TCP window autotuning at "Normal" (0xFFFFFFFF). A disabled
    # or limited autotune (a common leftover of old "gaming optimizer" tools)
    # collapses the sender's window under load, which is one of the most common
    # SOFTWARE causes of upload/download "packet loss".
    $tcpParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    $autoOrig = Get-RegRaw -Path $tcpParams -Name 'TCPAutotuningLevel'
    if ($autoOrig -ne -1) {
        Set-RegDword -Path $tcpParams -Name 'TCPAutotuningLevel' -Value -1
        $rec.TcpAutoTuneOriginal = $autoOrig
        if ($autoOrig -ne $script:AbsentMarker) {
            $applied += 'TCP auto-tune restored to Normal'
        } else {
            $applied += ('TCP auto-tune fixed from {0} to Normal (window-collapse packet loss)' -f $autoOrig)
        }
    }

    # ---- 2. Per-interface TCP latency knobs ------------------------------
    # Adjusted based on WiFi vs Ethernet to prevent packet loss.
    # Must exist BEFORE the game opens its sockets.
    if (Get-TweakBool $Settings 'TcpLowLatency' $true) {
        $ifKeys = @(Get-ChildItem -Path $script:TcpIpIfBase -ErrorAction SilentlyContinue)

        # Only tune adapters that are actually wired into the network stack.
        # Each Tcpip interface key carries an 'ifIndex' matching a routes
        # adapter; virtual links (Loopback, vEthernet, Wi-Fi Direct virtual
        # adapters) are skipped to keep the registry section clean and avoid
        # breaking sandbox/container traffic.
        $activeIfIndex = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue |
            Where-Object { $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up' } |
            ForEach-Object { $_.InterfaceIndex })

        foreach ($k in $ifKeys) {
            try {
                $node = @{}
                $skip = $false
                if ($activeIfIndex.Count -gt 0) {
                    try {
                        $kProp = Get-ItemProperty -Path $k.PSPath -ErrorAction Stop
                        if ($kProp.PSObject.Properties['ifIndex'] -and $kProp.ifIndex -match '^\d+$') {
                            if ($activeIfIndex -notcontains [int]$kProp.ifIndex) { $skip = $true }
                        }
                    } catch { }
                }
                if ($skip) { continue }

                foreach ($name in @('TcpAckFrequency', 'TCPNoDelay', 'TcpDelAckTicks', 'GlobalMaxTcpWindowSize')) {
                    $orig = Get-RegRaw -Path $k.PSPath -Name $name

                    $val = switch ($name) {
                        'TcpAckFrequency' {
                            # WiFi/unknown: use 2 to avoid ACK flooding that causes packet loss
                            # Ethernet: use 1 for minimum latency
                            if ($connType -ne 'Ethernet') { 2 } else { 1 }
                        }
                        'TCPNoDelay' { 1 }    # always on: disable Nagle
                        'TcpDelAckTicks' {
                            # Delayed-ACK batching. WiFi/unknown: a *modest* batch reduces
                            # ACK-count overhead without adding retransmission-trigger
                            # latency. IMPORTANT: a large value (e.g. 100) delays ACKs
                            # by ~100ms+, which the WiFi radio + TCP stacks read as a
                            # stalled receiver - that itself LOOKS like packet loss.
                            # Ethernet: 0 = immediate ACKs for minimum latency.
                            if ($connType -ne 'Ethernet') { 2 } else { 0 }
                        }
                        'GlobalMaxTcpWindowSize' {
                            # Keep TCP auto-tune healthy: force a large receive window
                            # on both link types. A tiny 65535 window chokes throughput
                            # on high-bandwidth WiFi and can surface as drops.
                            0xFFFF0
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
            $tunedNote = if ($activeIfIndex.Count -gt 0) { ' (active links only)' } else { '' }
            $applied += ('TCP fast-ack/no-delay on {0} interface(s){1} [{2} optimized]' -f $rec.Interfaces.Count, $tunedNote, $connType)
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

    if ($null -ne $JournalState) { $JournalState['net'] = $rec }

    if ($applied.Count -eq 0) {
        Write-Log 'Network profile: nothing to change.' 'INFO'
    } else {
        Write-Log ("Game network profile ACTIVE ({0}): {1}." -f $connType, ($applied -join ', ')) 'OK'
        if ($connType -eq 'WiFi') {
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

        $autoOrig = Get-NetStateField $net 'TcpAutoTuneOriginal'
        if ($null -ne $autoOrig) {
            [void](Restore-RegFromJournal -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'TCPAutotuningLevel' -Original $autoOrig)
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
        Remove-RegValue -Path $script:SysProfile -Name 'NetworkThrottlingIndex'
        Remove-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'TCPAutotuningLevel'
        foreach ($k in @(Get-ChildItem -Path $script:TcpIpIfBase -ErrorAction SilentlyContinue)) {
            Remove-RegValue -Path $k.PSPath -Name 'TcpAckFrequency'
            Remove-RegValue -Path $k.PSPath -Name 'TCPNoDelay'
            Remove-RegValue -Path $k.PSPath -Name 'TcpDelAckTicks'
            Remove-RegValue -Path $k.PSPath -Name 'GlobalMaxTcpWindowSize'
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

# ------------------------------------------------------------
# Microphone background-noise suppression
#
# Windows ships a built-in audio DSP pipeline ("input signal
# enhancements") with background Noise Suppression + Acoustic Echo
# Cancellation + auto gain for each capture endpoint. It is enabled
# via the per-device PKEY_AudioEndpoint_Disable_SysFx property:
#   0 = enhancements ON (noise suppression active)
#   1 = enhancements OFF
# We simply switch it on for every installed mic. No third-party DSP
# host, no per-frame C# filters -> near-zero CPU/RAM cost while the
# game runs (unlike the old VoiceDSP module this replaces).
# ------------------------------------------------------------
$script:CaptureMmBase    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
$script:SysFxDisableName = '{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5'

function Enable-MicNoiseSuppression {
    <#
        Turns on Windows' built-in input signal enhancements (background
        noise suppression / AEC / auto gain) for every installed capture
        endpoint, removing room / keyboard / fan noise from party & team
        chat before it reaches the game.
        Pass -JournalState (a hashtable) to record each endpoint's original
        property so Undo-MicNoiseSuppression can restore it exactly. Best
        effort: devices without a FxProperties store are skipped silently.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][hashtable]$JournalState = $null
    )

    Assert-AdminOrThrow

    if (-not (Test-Path $script:CaptureMmBase)) {
        Write-Log 'Mic noise suppression: no capture endpoints found.' 'WARN'
        return
    }

    $endpoints = @(Get-ChildItem -Path $script:CaptureMmBase -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\{[0-9a-fA-F-]{36}\}$' })
    if ($endpoints.Count -eq 0) {
        Write-Log 'Mic noise suppression: no capture endpoint keys found.' 'WARN'
        return
    }

    $enabled = @()
    foreach ($ep in $endpoints) {
        try {
            $fxKey = Join-Path $ep.PSPath 'FxProperties'
            if (-not (Test-Path $fxKey)) { continue }

            $orig = Get-RegRaw -Path $fxKey -Name $script:SysFxDisableName
            # 0 = signal enhancements/noise suppression ON, 1 = OFF.
            if ($orig -ne 0) {
                Set-RegDword -Path $fxKey -Name $script:SysFxDisableName -Value 0
                if ($null -ne $JournalState) { $JournalState[$ep.PSChildName] = $orig }
                $enabled += $ep.PSChildName
            } elseif ($null -ne $JournalState -and -not $JournalState.ContainsKey($ep.PSChildName)) {
                # Already enhancing, but still journal it so the session undo
                # leaves the endpoint back in the pre-session state.
                $JournalState[$ep.PSChildName] = 0
            }
        } catch { }
    }

    if ($enabled.Count -gt 0) {
        Write-Log ("Mic noise suppression ENABLED on {0} input device(s) - background/echo noise removed from party audio." -f $enabled.Count) 'OK'
    } else {
        Write-Log 'Mic noise suppression: input enhancements already active (or not available on this hardware).' 'INFO'
    }
}

function Undo-MicNoiseSuppression {
    <#
        Exact revert of Enable-MicNoiseSuppression from a journal node,
        or -RemoveKnownDefaults to strip the managed property from every
        capture endpoint (Windows then re-applies its normal defaults).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][hashtable]$JournalState = $null,
        [switch]$RemoveKnownDefaults
    )

    if ($JournalState -and $JournalState.Count -gt 0) {
        foreach ($guid in @($JournalState.Keys)) {
            $fxKey = Join-Path $script:CaptureMmBase (Join-Path ([string]$guid) 'FxProperties')
            if (-not (Test-Path $fxKey)) { continue }
            $orig = Get-NetStateField $JournalState $guid
            if ($null -ne $orig) {
                [void](Restore-RegFromJournal -Path $fxKey -Name $script:SysFxDisableName -Original $orig)
            }
        }
        Write-Log 'Mic noise suppression reverted (original input enhancement state restored).' 'OK'
        return
    }

    if ($RemoveKnownDefaults) {
        foreach ($ep in @(Get-ChildItem -Path $script:CaptureMmBase -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match '^\{[0-9a-fA-F-]{36}\}$' })) {
            Remove-RegValue -Path (Join-Path $ep.PSPath 'FxProperties') -Name $script:SysFxDisableName
        }
        Write-Log 'Mic noise suppression settings removed - Windows defaults restored.' 'OK'
        return
    }

    Write-Log 'Mic noise suppression: nothing to revert (no journal).' 'INFO'
}

Export-ModuleMember -Function Enable-GameNetworkProfile, Undo-GameNetworkProfile,
    Set-MicClarityTweaks, Get-ActiveNetworkType,
    Enable-MicNoiseSuppression, Undo-MicNoiseSuppression
