# ============================================================
#  RawInputBuffer.psm1 - always-on raw mouse input tuning
#
#  Applies safe, reversible Windows mouse-input optimizations so
#  games receive responsive raw mouse input even when the mouse
#  has no vendor driver / gaming software. Settings are chosen
#  automatically from the detected pointing device(s) and can
#  be reverted at any time from the recovery journal.
#
#  "Always on" (Config.ps1 > RawInputBuffer.AlwaysOn): the
#  profile is applied for every suite session (full optimization
#  and/or watcher session) and restored when the session ends or
#  is recovered after an unclean exit.
#
#  Notes:
#   - No game/anti-cheat process is touched; only documented
#     user/system mouse settings are changed.
#   - Polling/report rate is a hardware/driver property and cannot
#     be forced from user mode without a vendor driver; this
#     module tunes the OS-side buffering path instead.
# ============================================================

Set-StrictMode -Version Latest

if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    try { Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -ErrorAction Stop } catch { }
}

$script:MouClassParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters'
$script:MouseKeyHKCU   = 'HKCU:\Control Panel\Mouse'
$script:AbsentMarker   = '<ABSENT>'

function Get-RawInputBool {
    param([AllowNull()]$Settings, [Parameter(Mandatory)][string]$Key, [bool]$Default)
    if ($null -ne $Settings -and $Settings -is [System.Collections.IDictionary] -and $Settings.Contains($Key)) {
        return [bool]$Settings[$Key]
    }
    return $Default
}

function Get-RawInputInt {
    param([AllowNull()]$Settings, [Parameter(Mandatory)][string]$Key, [int]$Default)
    if ($null -ne $Settings -and $Settings -is [System.Collections.IDictionary] -and $Settings.Contains($Key)) {
        try { return [int]$Settings[$Key] } catch { return $Default }
    }
    return $Default
}

function Get-RawRegValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    try {
        $p = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $p.$Name
    } catch {
        return $script:AbsentMarker
    }
}

function Set-RawRegDword {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Value)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
}

function Set-RawRegString {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force -ErrorAction Stop | Out-Null
}

function Restore-RawRegValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, $Original)
    try {
        if ("$Original" -eq $script:AbsentMarker) {
            Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
            return $true
        }
        # MouseSpeed/Threshold* are REG_SZ in HKCU; MouseDataQueueSize is DWORD in HKLM.
        if ($Original -is [int] -or $Original -is [uint32] -or $Original -is [long] -or $Original -is [byte]) {
            Set-RawRegDword -Path $Path -Name $Name -Value ([int]$Original)
        } else {
            Set-RawRegString -Path $Path -Name $Name -Value ([string]$Original)
        }
        return $true
    } catch {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log ("Raw input buffer: failed to restore {0}\{1}: {2}" -f $Path, $Name, $_.Exception.Message) 'WARN'
        }
        return $false
    }
}

function Save-RawInputJournal {
    param([AllowNull()][hashtable]$JournalState)
    if ($null -eq $JournalState) { return }
    if (Get-Command Save-WatcherJournal -ErrorAction SilentlyContinue) {
        try { Save-WatcherJournal -State $JournalState } catch { }
    }
}

function Get-MouseDevices {
    <#
        Enumerates pointing devices from multiple sources so generic,
        PS/2, touchpad, Bluetooth, USB and no-vendor-driver mice are seen.
        Never throws.
    #>
    $devices = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    try {
        $pnp = @(Get-CimInstance -ClassName Win32_PointingDevice -ErrorAction SilentlyContinue)
        foreach ($d in $pnp) {
            $name = ''
            foreach ($prop in @('Name','Description','Caption','Manufacturer')) {
                if ($d.PSObject.Properties[$prop] -and $d.$prop) { $name = [string]$d.$prop; break }
            }
            if (-not $name) { $name = 'Pointing device' }
            $id = ''
            foreach ($prop in @('DeviceID','PNPDeviceID')) {
                if ($d.PSObject.Properties[$prop] -and $d.$prop) { $id = [string]$d.$prop; break }
            }
            $pnpId = if ($d.PSObject.Properties['PNPDeviceID']) { [string]$d.PNPDeviceID } else { '' }
            $iface = if ($d.PSObject.Properties['PointingType']) { [string]$d.PointingType } else { '' }
            $mfr = if ($d.PSObject.Properties['Manufacturer']) { [string]$d.Manufacturer } else { '' }
            $key = if ($id) { $id } else { $name }
            if ($seen.Add($key)) {
                $devices.Add([pscustomobject]@{
                    Name         = $name
                    DeviceID     = $id
                    PnpId        = $pnpId
                    PointingType = $iface
                    Manufacturer = $mfr
                    Source       = 'Win32_PointingDevice'
                })
            }
        }
    } catch { }

    # Registry fallback: mouse class driver entries (helps on trimmed/custom builds)
    try {
        $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96f-e325-11ce-bfc1-08002be10318}'
        if (Test-Path $classKey) {
            $subs = @(Get-ChildItem -Path $classKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^00\d+$' })
            foreach ($s in $subs) {
                try {
                    $p = Get-ItemProperty -Path $s.PSPath -ErrorAction SilentlyContinue
                    if (-not $p) { continue }
                    $desc = $null
                    foreach ($n in @('DriverDesc','DeviceDesc')) {
                        if ($p.PSObject.Properties[$n] -and $p.$n) { $desc = [string]$p.$n; break }
                    }
                    if (-not $desc) { continue }
                    if ($seen.Add("REG:$desc")) {
                        $devices.Add([pscustomobject]@{
                            Name         = $desc
                            DeviceID     = $s.PSChildName
                            PnpId        = ''
                            PointingType = ''
                            Manufacturer = if ($p.PSObject.Properties['ProviderName']) { [string]$p.ProviderName } else { '' }
                            Source       = 'MouseClassRegistry'
                        })
                    }
                } catch { }
            }
        }
    } catch { }

    return @($devices.ToArray())
}

function Resolve-MouseInputProfile {
    <#
        Chooses an OS input-buffer profile automatically from detected mice.
        Works without vendor drivers by relying on generic HID/PNP strings and
        safe defaults. Never throws.
    #>
    param([AllowNull()]$Settings)

    $devices = @(Get-MouseDevices)
    $names = @($devices | ForEach-Object { [string]$_.Name } | Where-Object { $_ })
    $joined = ($names -join ' | ').ToLowerInvariant()

    # Gaming mice often advertise these keywords even without vendor software.
    $gamingHints = @(
        'gaming','gamer','esports',
        'logitech g','g pro','g502','g703','g903','lightspeed',
        'razer','deathadder','viper','basilisk','naga',
        'steelseries','rival','sensei','aerox',
        'zowie','glorious','model o','model d',
        'pulsar','xlite','x2','x3','lamzu','finalmouse','ultralight',
        'hyperx','pulsefire','corsair','sabre','harpoon','dark core','m65','katar',
        'cooler master','mm7','mm8','roccat','kone','burst',
        'asus rog','spatha','keris','gladius','harpe',
        'endgame gear','xm1','op1','ninjutso','sora','vxe','atk'
    )
    $isGaming = $false
    foreach ($h in $gamingHints) {
        if ($joined.Contains($h.ToLowerInvariant())) { $isGaming = $true; break }
    }

    # Detect touch-only / trackpoint-only systems so we avoid aggressive tuning.
    $isTouchOnly = $false
    if ($devices.Count -gt 0) {
        $allTouch = $true
        foreach ($n in $names) {
            if ($n -notmatch '(?i)touchpad|trackpoint|pointing stick|synaptics|elan|precision touchpad|hid-compliant touch') {
                $allTouch = $false
                break
            }
        }
        $isTouchOnly = $allTouch
    }

    $manualQueue = Get-RawInputInt -Settings $Settings -Key 'MouseDataQueueSize' -Default 0

    # Auto queue sizing for mouclass MouseDataQueueSize (default commonly 100):
    #  - gaming/high-performance mouse: smaller buffer for lower latency
    #  - generic/office/unknown mouse:   balanced buffer (works without driver)
    #  - touch-only:                     conservative
    $queue = 50
    $profile = 'GenericMouse'
    if ($isTouchOnly) {
        $queue = 64
        $profile = 'TouchOnly'
    } elseif ($isGaming) {
        $queue = 32
        $profile = 'GamingMouse'
    } elseif ($devices.Count -eq 0) {
        $queue = 50
        $profile = 'UnknownMouse'
    }

    if ($manualQueue -gt 0) {
        $queue = [Math]::Max(16, [Math]::Min(256, $manualQueue))
        $profile = "$profile+ManualQueue"
    }

    $disableAccel = Get-RawInputBool -Settings $Settings -Key 'DisablePointerPrecision' -Default $false

    return @{
        Profile                 = $profile
        IsGaming                = $isGaming
        IsTouchOnly             = $isTouchOnly
        DeviceCount             = $devices.Count
        DeviceNames             = $names
        QueueSize               = $queue
        DisablePointerPrecision = $disableAccel
    }
}

function Enable-RawInputBuffer {
    <#
        Applies the auto-selected raw input buffer profile. Records originals
        in JournalState['rawInputBuffer'] so the session can be reverted on
        clean exit or crash recovery. Safe to call multiple times.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Settings,
        [AllowNull()][hashtable]$JournalState
    )

    $enabled = Get-RawInputBool -Settings $Settings -Key 'Enabled' -Default $true
    $alwaysOn = Get-RawInputBool -Settings $Settings -Key 'AlwaysOn' -Default $true
    # "Always on" request: treat as enabled for suite sessions unless explicitly disabled.
    if (-not $enabled) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log 'Raw input buffer: disabled by configuration.' 'INFO'
        }
        return $false
    }

    $decision = Resolve-MouseInputProfile -Settings $Settings

    $canWriteSystem = $true
    if (Get-Command Assert-AdminOrThrow -ErrorAction SilentlyContinue) {
        try { Assert-AdminOrThrow } catch {
            $canWriteSystem = $false
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log ("Raw input buffer: admin rights required to tune system mouse queue; skipping system changes ({0})." -f $_.Exception.Message) 'WARN'
            }
        }
    }

    $record = $null
    if ($null -ne $JournalState) {
        if (-not $JournalState.ContainsKey('rawInputBuffer') -or $null -eq $JournalState['rawInputBuffer']) {
            $JournalState['rawInputBuffer'] = @{ Values = @{}; Applied = $false; Profile = $null }
        }
        $record = $JournalState['rawInputBuffer']
        if (-not ($record -is [System.Collections.IDictionary])) { $record = @{ Values = @{}; Applied = $false; Profile = $null }; $JournalState['rawInputBuffer'] = $record }
        if (-not $record.ContainsKey('Values') -or $null -eq $record['Values']) { $record['Values'] = @{} }
    }

    $applied = @()

    # 1) System mouse data queue size (HKLM) - applies to all mice incl. generic/no-driver.
    if ($canWriteSystem) {
        try {
            $orig = Get-RawRegValue -Path $script:MouClassParams -Name 'MouseDataQueueSize'
            $key = 'MouClass|MouseDataQueueSize'
            if ($record -and -not $record['Values'].ContainsKey($key)) {
                $record['Values'][$key] = @{ Path = $script:MouClassParams; Name = 'MouseDataQueueSize'; Original = $orig }
            }
            Save-RawInputJournal -JournalState $JournalState
            Set-RawRegDword -Path $script:MouClassParams -Name 'MouseDataQueueSize' -Value ([int]$decision.QueueSize)
            $applied += ("MouseDataQueueSize={0}" -f $decision.QueueSize)
        } catch {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log ("Raw input buffer: could not set MouseDataQueueSize: {0}" -f $_.Exception.Message) 'WARN'
            }
        }
    }

    # 2) Optional pointer precision (acceleration) toggle - only when explicitly requested.
    if ($decision.DisablePointerPrecision) {
        try {
            foreach ($pair in @(
                @{ Name = 'MouseSpeed';      Value = '0' },
                @{ Name = 'MouseThreshold1'; Value = '0' },
                @{ Name = 'MouseThreshold2'; Value = '0' }
            )) {
                $orig = Get-RawRegValue -Path $script:MouseKeyHKCU -Name $pair.Name
                $rkey = "HKCU|$($pair.Name)"
                if ($record -and -not $record['Values'].ContainsKey($rkey)) {
                    $record['Values'][$rkey] = @{ Path = $script:MouseKeyHKCU; Name = $pair.Name; Original = $orig }
                }
                Save-RawInputJournal -JournalState $JournalState
                Set-RawRegString -Path $script:MouseKeyHKCU -Name $pair.Name -Value $pair.Value
            }
            $applied += 'PointerPrecision=Off'
        } catch {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log ("Raw input buffer: could not adjust pointer precision: {0}" -f $_.Exception.Message) 'WARN'
            }
        }
    }

    $isApplied = ($applied.Count -gt 0)
    if ($record) {
        $record['Applied'] = $isApplied
        $record['Profile'] = $decision
        $record['AlwaysOn'] = $alwaysOn
        Save-RawInputJournal -JournalState $JournalState
    }

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        $devStr = if ($decision.DeviceNames -and $decision.DeviceNames.Count -gt 0) {
            ($decision.DeviceNames -join ', ')
        } else { 'no pointing device reported (generic/no-driver path active)' }
        $stateMsg = if ($isApplied) { 'ENABLED (always on)' } else { 'checked (no system values changed)' }
        $detail = if ($applied.Count -gt 0) { "Applied: $($applied -join '; ')" } else { 'No system values changed (insufficient privileges or nothing to adjust).' }
        Write-Log ("Raw input buffer {0} [{1}] for mouse(s): {2}. Queue={3}. {4}" -f $stateMsg, $decision.Profile, $devStr, $decision.QueueSize, $detail) 'OK'
        if ($decision.Profile -eq 'UnknownMouse' -or $decision.DeviceCount -eq 0) {
            Write-Log 'Raw input buffer: using generic auto profile so non-gaming mice and devices without vendor drivers stay optimized.' 'INFO'
        }
    }

    return $true
}

function Disable-RawInputBuffer {
    <#
        Restores any values recorded by Enable-RawInputBuffer.
        Safe to call when nothing was applied.
    #>
    [CmdletBinding()]
    param([AllowNull()][hashtable]$JournalState)

    $record = $null
    if ($null -ne $JournalState -and $JournalState -is [System.Collections.IDictionary] -and $JournalState.ContainsKey('rawInputBuffer')) {
        $record = $JournalState['rawInputBuffer']
    }
    if ($null -eq $record) {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log 'Raw input buffer: nothing to revert (no journal record).' 'INFO'
        }
        return
    }

    $values = $null
    if ($record -is [System.Collections.IDictionary] -and $record.Contains('Values')) { $values = $record['Values'] }
    $restored = 0
    if ($values -is [System.Collections.IDictionary]) {
        foreach ($k in @($values.Keys)) {
            try {
                $entry = $values[$k]
                if ($null -eq $entry) { continue }
                $path = [string](if ($entry -is [System.Collections.IDictionary]) { $entry['Path'] } else { $entry.Path })
                $name = [string](if ($entry -is [System.Collections.IDictionary]) { $entry['Name'] } else { $entry.Name })
                $orig = if ($entry -is [System.Collections.IDictionary]) { $entry['Original'] } else { $entry.Original }
                if ($path -and $name) {
                    if (Restore-RawRegValue -Path $path -Name $name -Original $orig) { $restored++ }
                }
            } catch { }
        }
    }

    if ($JournalState -is [System.Collections.IDictionary]) { $null = $JournalState.Remove('rawInputBuffer') }
    Save-RawInputJournal -JournalState $JournalState

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log ("Raw input buffer reverted ({0} value(s) restored)." -f $restored) 'OK'
    }
}

function Get-RawInputBufferStatus {
    <#
        Returns a summary object for UI/status display. Never throws.
    #>
    param([AllowNull()]$Settings)

    $decision = Resolve-MouseInputProfile -Settings $Settings
    $currentQueue = Get-RawRegValue -Path $script:MouClassParams -Name 'MouseDataQueueSize'
    return [pscustomobject]@{
        Enabled          = (Get-RawInputBool -Settings $Settings -Key 'Enabled' -Default $true)
        AlwaysOn         = (Get-RawInputBool -Settings $Settings -Key 'AlwaysOn' -Default $true)
        Profile          = $decision.Profile
        DeviceCount      = $decision.DeviceCount
        DeviceNames      = $decision.DeviceNames
        RecommendedQueue = $decision.QueueSize
        CurrentQueue     = $currentQueue
        IsGamingMouse    = $decision.IsGaming
    }
}

Export-ModuleMember -Function Get-MouseDevices, Resolve-MouseInputProfile,
    Enable-RawInputBuffer, Disable-RawInputBuffer, Get-RawInputBufferStatus
