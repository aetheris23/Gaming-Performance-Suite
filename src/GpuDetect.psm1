# ============================================================
#  GpuDetect.psm1 - GPU inventory & classification
#
#  Identifies every graphics adapter in the system and tags it
#  as INTEGRATED (iGPU) or DISCRETE (dGPU), across all vendors:
#
#    - Intel   : HD/UHD/Iris iGPUs AND Arc dGPUs are told apart.
#                ("Arc A750" = discrete, bare "Arc Graphics" /
#                 "Arc 140V" naming = Meteor/Lunar-Lake iGPU.)
#    - AMD     : APU graphics ("Radeon(TM) Graphics", Vega 8,
#                R7 Graphics, 680M/780M/890M, HD xxxx D/G) vs
#                every Radeon series (HD/R5-R9/RX/Fury/VII/
#                Pro/Instinct/FirePro).
#    - NVIDIA  : GeForce/Quadro/TITAN/Tesla - always discrete
#                (NVIDIA has no consumer iGPU).
#    + virtual/software adapters (Hyper-V, Basic Render, VMware)
#      are detected so gaming logic can ignore them.
#
#  Detection sources, tried in order of reliability:
#    1. DXGI adapter enumeration (what games actually see;
#       includes vendor/device PCI IDs + dedicated VRAM bytes)
#    2. Registry display-class keys (catches disabled adapters,
#       exact VRAM via HardwareInformation.qwMemorySize)
#    3. Win32_VideoController via CIM - LAST RESORT only.
#
#  Results are cached: one-shot cost at startup/watcher start,
#  zero overhead inside the polling loop (keeps the suite's
#  "no WMI in the hot loop" promise intact).
# ============================================================

Set-StrictMode -Version Latest

# ------------------------------------------------------------
# Native interop: DXGI factory enumeration (Windows only; compiled
# LAZILY on first real use, not at module import - on low-spec
# machines the C# compile at startup cost real seconds).
# ------------------------------------------------------------
function Add-NativeDxgiType {
    if ('Suite.Gpu.DxgiNative' -as [type]) { return }
    if (-not (Test-SuitePlatformWindows)) { return }
    Add-Type -Namespace Suite.Gpu -Name DxgiNative -MemberDefinition @'
[DllImport("dxgi.dll", EntryPoint = "CreateDXGIFactory1")]
public static extern int CreateDXGIFactory1(ref Guid riid, out IntPtr ppFactory);

[UnmanagedFunctionPointer(CallingConvention.StdCall)]
public delegate int EnumAdapters1Delegate(IntPtr self, uint index, out IntPtr ppAdapter);

[UnmanagedFunctionPointer(CallingConvention.StdCall)]
public delegate int GetDesc1Delegate(IntPtr self, out DXGI_ADAPTER_DESC1 pDesc);

[UnmanagedFunctionPointer(CallingConvention.StdCall)]
public delegate uint ReleaseDelegate(IntPtr self);

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct DXGI_ADAPTER_DESC1
{
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
    public string Description;
    public uint VendorId;
    public uint DeviceId;
    public uint SubSysId;
    public uint Revision;
    public UIntPtr DedicatedVideoMemory;
    public UIntPtr DedicatedSystemMemory;
    public UIntPtr SharedSystemMemory;
    public uint LuidLow;
    public int LuidHigh;
    public uint Flags;      // bit 2 (0x2) = DXGI_ADAPTER_FLAG_SOFTWARE
}
'@
}

# IDXGIFactory1 vtable slots after IUnknown(0-2): EnumAdapters=3,
# MakeWindowAssociation=4, GetWindowAssociation=5, CreateSwapChain=6,
# CreateSoftwareAdapter=7, EnumAdapters1=8, IsCurrent=9
$script:VT_FACTORY_ENUMADAPTERS1 = 8
# IDXGIAdapter1 vtable slots after IUnknown(0-2): EnumOutputs=3,
# GetDesc=4, CheckInterfaceSupport=5, GetDesc1=6
$script:VT_ADAPTER_GETDESC1      = 6
$script:VT_RELEASE               = 2
$script:IID_IDXGIFACTORY1        = [Guid]'770aae78-f26f-4dba-a829-253c83d1b38e'

$script:DetectedGpus = $null

# ------------------------------------------------------------
# Small StrictMode-safe property reader
# ------------------------------------------------------------
function Get-GpuProp {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $pi = $Object.PSObject.Properties[$Name]
    if ($pi) { return $pi.Value } else { return $null }
}

function ConvertTo-MemoryBytes {
    <# Registry stores VRAM as REG_BINARY blobs (QWORD or DWORD),
       drivers occasionally as integers. Normalize to UInt64 bytes. #>
    param($Value)
    if ($null -eq $Value) { return $null }
    try {
        if ($Value -is [System.Array]) {
            # some providers hand back object[] instead of typed byte[]
            $b = [byte[]]$Value
            if ($b.Length -ge 8) { return [BitConverter]::ToUInt64($b, 0) }
            if ($b.Length -ge 4) { return [uint64][BitConverter]::ToUInt32($b, 0) }
            return $null
        }
        if ($Value -is [byte]) { return [uint64]$Value }
        if ($Value -is [int] -or $Value -is [long]) { return [uint64][long]$Value }
        return $null
    } catch { return $null }
}

# ------------------------------------------------------------
# Source 1: DXGI - adapters currently visible to applications
# ------------------------------------------------------------
function Get-GpuViaDxgi {
    if (-not (Test-SuitePlatformWindows)) { return $null }
    Add-NativeDxgiType
    if (-not ('Suite.Gpu.DxgiNative' -as [type])) { return $null }
    $list  = New-Object System.Collections.Generic.List[object]
    $m     = [Runtime.InteropServices.Marshal]
    $fact  = [IntPtr]::Zero
    $relFD = $null
    try {
        $iid = $script:IID_IDXGIFACTORY1
        $hr  = [Suite.Gpu.DxgiNative]::CreateDXGIFactory1([ref]$iid, [ref]$fact)
        if ($hr -ne 0 -or $fact -eq [IntPtr]::Zero) { return $null }

        $vtbl  = $m::ReadIntPtr($fact)
        $enumD = $m::GetDelegateForFunctionPointer(
                     $m::ReadIntPtr($vtbl, $script:VT_FACTORY_ENUMADAPTERS1 * [IntPtr]::Size),
                     [Suite.Gpu.DxgiNative+EnumAdapters1Delegate])
        $relFD = $m::GetDelegateForFunctionPointer(
                     $m::ReadIntPtr($vtbl, $script:VT_RELEASE * [IntPtr]::Size),
                     [Suite.Gpu.DxgiNative+ReleaseDelegate])

        # Hard cap: no sane system has more than a handful of adapters; a
        # misbehaving driver must not be able to spin this loop forever.
        $maxAdapters = 32

        for ($i = 0; $i -lt $maxAdapters; $i++) {
            $adp   = [IntPtr]::Zero
            $relAD = $null
            try {
                if ($enumD.Invoke($fact, [uint32]$i, [ref]$adp) -ne 0 -or $adp -eq [IntPtr]::Zero) { break }
                $avtbl = $m::ReadIntPtr($adp)
                $relAD = $m::GetDelegateForFunctionPointer(
                             $m::ReadIntPtr($avtbl, $script:VT_RELEASE * [IntPtr]::Size),
                             [Suite.Gpu.DxgiNative+ReleaseDelegate])
                $descD = $m::GetDelegateForFunctionPointer(
                             $m::ReadIntPtr($avtbl, $script:VT_ADAPTER_GETDESC1 * [IntPtr]::Size),
                             [Suite.Gpu.DxgiNative+GetDesc1Delegate])
                $desc  = New-Object Suite.Gpu.DxgiNative+DXGI_ADAPTER_DESC1
                if ($descD.Invoke($adp, [ref]$desc) -eq 0 -and $desc.Description) {
                    $list.Add(@{
                        Name           = ([string]$desc.Description).Trim()
                        VendorId       = [uint32]$desc.VendorId
                        DeviceId       = [uint32]$desc.DeviceId
                        DedicatedBytes = [uint64]$desc.DedicatedVideoMemory
                        SoftwareFlag   = (($desc.Flags -band 0x2) -ne 0)
                        DriverVersion  = $null
                        Present        = $true
                    })
                }
            } catch { continue }   # one bad adapter must not stop enumeration
            finally {
                if ($null -ne $relAD -and $adp -ne [IntPtr]::Zero) { [void]$relAD.Invoke($adp) }
            }
        }

        if ($list.Count -eq 0) { return $null }
        return ,$list.ToArray()
    } catch {
        return $null
    } finally {
        if ($null -ne $relFD -and $fact -ne [IntPtr]::Zero) { [void]$relFD.Invoke($fact) }
    }
}

# ------------------------------------------------------------
# Source 2: Registry display class - catches everything the
# driver stack knows about, incl. disabled adapters + true VRAM
# ------------------------------------------------------------
$script:DisplayClassKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'

function Get-GpuViaRegistry {
    if (-not (Test-SuitePlatformWindows)) { return $null }
    $list = New-Object System.Collections.Generic.List[object]
    try {
        $keys = @(Get-ChildItem -Path $script:DisplayClassKey -ErrorAction Stop |
                  Where-Object { $_.PSChildName -match '^00\d+$' })
    } catch { return $null }

    foreach ($k in $keys) {
        try   { $p = Get-ItemProperty -Path $k.PSPath -ErrorAction Stop } catch { continue }
        $desc = Get-GpuProp $p 'DriverDesc'
        if (-not $desc) { continue }

        $mem = ConvertTo-MemoryBytes (Get-GpuProp $p 'HardwareInformation.qwMemorySize')
        if (-not $mem) { $mem = ConvertTo-MemoryBytes (Get-GpuProp $p 'HardwareInformation.MemorySize') }

        $venId = $null; $devId = $null
        $mid = Get-GpuProp $p 'MatchingDeviceId'
        if ($mid -and "$mid" -match 'VEN_([0-9A-Fa-f]{4}).*DEV_([0-9A-Fa-f]{4})') {
            $venId = [Convert]::ToUInt32($Matches[1], 16)
            $devId = [Convert]::ToUInt32($Matches[2], 16)
        }

        $drv = Get-GpuProp $p 'DriverVersion'
        if ($drv -and $drv -isnot [string]) { $drv = $null }   # often REG_BINARY here

        $list.Add(@{
            Name           = ([string]$desc).Trim()
            VendorId       = $venId
            DeviceId       = $devId
            DedicatedBytes = $mem
            SoftwareFlag   = $false
            DriverVersion  = $drv
            Present        = $false
        })
    }
    if ($list.Count -eq 0) { return $null }
    return ,$list.ToArray()
}

# ------------------------------------------------------------
# Source 3 (last resort): classic WMI video controller table
# One-shot at startup only - never called from the poll loop.
# ------------------------------------------------------------
function Get-GpuViaCim {
    $list = New-Object System.Collections.Generic.List[object]
    try {
        $ctrls = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
    } catch {
        try   { $ctrls = @(Get-WmiObject -Class Win32_VideoController -ErrorAction Stop) }
        catch { return $null }
    }
    foreach ($c in $ctrls) {
        $name = Get-GpuProp $c 'Name'
        if (-not $name) { continue }
        $venId = $null; $devId = $null
        $pnpid = Get-GpuProp $c 'PNPDeviceID'
        if ($pnpid -and "$pnpid" -match 'VEN_([0-9A-Fa-f]{4}).*DEV_([0-9A-Fa-f]{4})') {
            $venId = [Convert]::ToUInt32($Matches[1], 16)
            $devId = [Convert]::ToUInt32($Matches[2], 16)
        }
        $ram = Get-GpuProp $c 'AdapterRAM'          # UInt32 -> capped ~4 GB, approximate
        $bytes = $null
        if ($ram) { $bytes = [uint64]$ram }
        $list.Add(@{
            Name           = ([string]$name).Trim()
            VendorId       = $venId
            DeviceId       = $devId
            DedicatedBytes = $bytes
            SoftwareFlag   = $false
            DriverVersion  = Get-GpuProp $c 'DriverVersion'
            Present        = $true
        })
    }
    if ($list.Count -eq 0) { return $null }
    return ,$list.ToArray()
}

# ------------------------------------------------------------
# Source 3b (Linux): sysfs DRM cards + lspci descriptions.
# One-shot at startup only - never called from the poll loop.
# ------------------------------------------------------------
function Get-GpuViaLinux {
    $list = New-Object System.Collections.Generic.List[object]
    $cards = @(Get-ChildItem '/sys/class/drm' -Directory -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match '^card\d+$' })
    if ($cards.Count -eq 0) { return $null }

    # Optional lspci map: "vendor:device" -> human model string.
    $lspciMap = @{}
    try {
        foreach ($line in @(& lspci -nn 2>$null)) {
            if ($line -match '(?i)(vga compatible controller|3d controller|display controller)') {
                $vm = [regex]::Match($line, '\[([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\]')
                if ($vm.Success) {
                    $desc = [regex]::Replace($line, '^.*?\]:\s*', '')
                    $desc = ($desc -replace '\s*\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\].*$', '').Trim(' .')
                    if ($desc) {
                        $lspciMap['{0}:{1}' -f $vm.Groups[1].Value.ToLowerInvariant(), $vm.Groups[2].Value.ToLowerInvariant()] = $desc
                    }
                }
            }
        }
    } catch { }

    $seen = @{}
    foreach ($card in $cards) {
        try {
            $dev = Join-Path $card.FullName 'device'
            if (-not (Test-Path $dev)) { continue }

            $vendor = ''; $device = ''; $driver = ''
            try { $vendor = (Get-Content (Join-Path $dev 'vendor') -Raw).Trim() } catch { }
            try { $device = (Get-Content (Join-Path $dev 'device') -Raw).Trim() } catch { }
            try {
                $target = Get-Item (Join-Path $dev 'driver') -ErrorAction SilentlyContinue
                if ($target) { $driver = (Split-Path -Leaf $target.Target) }
            } catch { }
            if ($driver -match 'vfio|drm|mgag200|virtio') { continue }
            if (-not $driver) {
                try {
                    $uevent = Get-Content (Join-Path $dev 'uevent') -Raw
                    if ($uevent -match 'DRIVER=([^\r\n]+)') { $driver = $Matches[1] }
                } catch { }
            }

            $vid = $null; $did = $null
            if ($vendor -match '0x([0-9a-fA-F]{4})$') { $vid = [Convert]::ToUInt32($Matches[1], 16) }
            if ($device -match '0x([0-9a-fA-F]{4})$') { $did = [Convert]::ToUInt32($Matches[1], 16) }

            $key = $null
            if ($vid -and $did) { $key = '{0:x4}:{1:x4}' -f $vid, $did }
            $name = $null
            if ($key -and $lspciMap.ContainsKey($key)) { $name = $lspciMap[$key] }
            if (-not $name) {
                $name = switch -Regex ([string]$driver) {
                    'amdgpu|^radeon$'        { 'AMD Graphics' }
                    'i915|i965|^intel'       { 'Intel Graphics' }
                    '^nvidia$'               { 'NVIDIA Graphics' }
                    '^nouveau$'              { 'NVIDIA Graphics (nouveau)' }
                    default                  { if ($driver) { "$driver Graphics Adapter" } else { 'Graphics Adapter' } }
                }
            }

            $sk = $key
            if (-not $sk) { $sk = $name }
            if ($seen.ContainsKey($sk)) { continue }
            $seen[$sk] = $true

            $ded = $null
            try {
                $vram = Get-Content (Join-Path $dev 'mem_info_vram_total') -Raw -ErrorAction SilentlyContinue
                if ($vram -and $vram.Trim() -match '^\d+$') { $ded = [uint64][int64]$vram.Trim() }
            } catch { }

            $list.Add(@{
                Name           = $name
                VendorId       = $vid
                DeviceId       = $did
                DedicatedBytes = $ded
                SoftwareFlag   = $false
                DriverVersion  = $null
                Present        = $true
            })
        } catch { continue }
    }
    if ($list.Count -eq 0) { return $null }
    return ,$list.ToArray()
}

# ------------------------------------------------------------
# Source 3c (macOS): system_profiler SPDisplaysDataType.
# One-shot at startup only - never called from the poll loop.
# ------------------------------------------------------------
function Get-GpuViaMacos {
    $list = New-Object System.Collections.Generic.List[object]
    try {
        $jsonText = & /usr/sbin/system_profiler SPDisplaysDataType -json 2>$null | Out-String
        if (-not $jsonText) { return $null }
        $js = $jsonText | ConvertFrom-Json -ErrorAction Stop
        $arr = @($js.SPDisplaysDataType)
        if ($arr.Count -eq 0) { return $null }
        foreach ($g in $arr) {
            $name = $g.'_name'
            if (-not $name) { $name = $g.sppci_model }
            if (-not $name) { continue }
            $list.Add(@{
                Name           = ([string]$name).Trim()
                VendorId       = $null
                DeviceId       = $null
                DedicatedBytes = $null
                SoftwareFlag   = $false
                DriverVersion  = $null
                Present        = $true
            })
        }
    } catch { return $null }
    if ($list.Count -eq 0) { return $null }
    return ,$list.ToArray()
}
$script:PciVendorNames = @{
    '0x10DE' = 'NVIDIA'
    '0x1002' = 'AMD'
    '0x1022' = 'AMD'
    '0x8086' = 'INTEL'
    '0x1414' = 'MICROSOFT'
}

function Resolve-GpuVendor {
    param([string]$Name, $VendorId)
    if ($null -ne $VendorId) {
        $hex = '0x{0:X4}' -f [uint32]$VendorId
        if ($script:PciVendorNames.ContainsKey($hex)) { return $script:PciVendorNames[$hex] }
    }
    $n = ''; if ($Name) { $n = $Name.ToLowerInvariant() }
    if ($n -match 'nvidia|geforce|quadro|titan\b')                    { return 'NVIDIA' }
    if ($n -match 'radeon|\bati\b|firepro|firegl|instinct|amdati')    { return 'AMD' }
    if ($n -match '\bintel\b')                                        { return 'INTEL' }
    if ($n -match 'vmware|virtualbox|qemu|citrix|parallels')          { return 'VIRTUAL' }
    if ($n -match 'microsoft')                                        { return 'MICROSOFT' }
    return 'UNKNOWN'
}

# ------------------------------------------------------------
# Integrated vs Discrete classification
#
# Pattern tables below encode real-world driver naming quirks:
#   - "AMD Radeon(TM) RX Vega 10"  = Raven Ridge iGPU, while
#     "Radeon RX Vega 56/64"/VII  = dGPU  -> Vega checked FIRST.
#   - RDNA mobile iGPUs are bare numbers with M (680M/780M/890M);
#     mobile dGPUs always carry a 4-digit model (RX 7600M XT), and
#     word-boundary rules keep them apart automatically.
#   - Intel Arc WITH a letter-model (A380/B580/Pro A40) = dGPU;
#     bare "Arc Graphics" / "Arc 140V" = Meteor/Lunar-Lake iGPU.
#   - Old ATI chipset/APU graphics (Radeon Xpress, Mobility HD
#     2xxx-3xxx, HD xxxx D/G suffix) land in the iGPU table.
# ------------------------------------------------------------
function Resolve-GpuType {
    param(
        [AllowEmptyString()][string]$Name,
        [string]$Vendor,
        $DedicatedBytes
    )

    $n = ''
    if ($Name)  { $n = $Name.ToLowerInvariant() }

    # ---- virtual / software adapters ----
    $virtualTokens = @('basic render', 'render driver', 'basic display',
                       'remote display', 'hyper-v', 'vmware svga',
                       'virtualbox', 'qxl', 'cirrus', 'indirect display',
                       'parallels')
    foreach ($t in $virtualTokens) { if ($n.Contains($t)) { return 'Virtual' } }

    $v = ''
    if ($Vendor) { $v = $Vendor.ToUpperInvariant() }

    $isNvidia = ($v -eq 'NVIDIA') -or ($n -match 'nvidia|geforce|quadro|titan\b')
    $isAmd    = ($v -eq 'AMD')    -or ($n -match '\bradeon\b|\bati\b|firepro|firegl')
    $isIntel  = ($v -eq 'INTEL')  -or ($n -match '\bintel\b')

    # ---- NVIDIA: every consumer/pro product line is discrete ----
    if ($isNvidia) { return 'Discrete' }

    # ---- INTEL ----
    if ($isIntel) {
        # Arc dGPU cards carry an explicit letter-model: A380, B570, Pro A60...
        if ($n -match '\barc\b[^0-9]*\b[a-z]\d{2,3}[hm]?\b') { return 'Discrete' }
        # DG1 was marketed as Iris Xe MAX; datacenter/Arc codenames too
        if ($n -match 'iris xe max|data center|arctic sound|alchemist|battlemage|\bdg1\b') { return 'Discrete' }
        # Everything else Intel makes is an iGPU: HD Graphics, UHD Graphics,
        # Iris / Iris Plus / Iris Pro / Iris Xe, GMA, bare "Graphics",
        # and un-numbered "Arc Graphics" (Meteor Lake+) / "Arc 140V".
        return 'Integrated'
    }

    # ---- AMD ----
    if ($isAmd) {
        # 1) Vega family split (APU Vegas vs dGPU Vegas)
        if ($n -match '\bvega\b') {
            if ($n -match '\bvega\s*(56|64)\b|radeon vii|frontier') { return 'Discrete' }
            return 'Integrated'
        }
        # 2) Ancient chipset/APU graphics reuse numbers that also exist as
        #    real dGPU series - resolve them by their fixed model list FIRST.
        if ($n -match '\bmobility radeon hd [1-3]\d{3}\b|\bradeon (hd )?(2100|3000|3100|3200|3300|4200|4250|4290)\b') { return 'Integrated' }
        # 3) Discrete series across all generations
        if ($n -match '\brx\s*\d')                              { return 'Discrete' }  # RX 460..RX 9070
        if ($n -match '\bhd\s*\d{4}\b')                         { return 'Discrete' }  # HD 7970 etc (D/G suffixes fail \b)
        if ($n -match '\br[5-9]\s*\d{3}[a-z]?\b')               { return 'Discrete' }  # R9 280X, R7 370
        if ($n -match '\bfury\b|radeon vii|pro duo|firepro|firegl|\binstinct\b') { return 'Discrete' }
        if ($n -match '\bw\d{4}\b')                             { return 'Discrete' }  # Radeon Pro W7900
        if ($n -match '\bmobility radeon hd [4-9]\d{3}\b')      { return 'Discrete' }  # laptop dGPUs
        # 4) Remaining integrated / APU families
        if ($n -match '\(tm\)\s*(graphics|r[2-8])\s*$')         { return 'Integrated' } # Radeon(TM) Graphics / (TM) R7
        if ($n -match '\br[2-7]\s*graphics\b')                  { return 'Integrated' } # Radeon R7 Graphics
        if ($n -match '\bhd\s*\d{4}[dg]\b')                     { return 'Integrated' } # APU D/G suffix (6530D)
        if ($n -match '\b[678]\d{2}m\b')                        { return 'Integrated' } # 660M/680M/780M/890M
        if ($n -match '\b8\d{3}s\b')                            { return 'Integrated' } # Strix Halo 8060S
        if ($n -match 'radeon xpress|radeon \d{3,4}e\b|x1\d{3}\b') { return 'Integrated' }
    }

    # ---- Unknown vendor/name: fall back to dedicated VRAM size ----
    if ($null -ne $DedicatedBytes) {
        $mb = [double]$DedicatedBytes / 1MB
        if ($mb -ge 1024) { return 'Discrete' }
        if ($mb -le 512 -and $mb -gt 0) { return 'Integrated' }
    }
    return 'Unknown'
}

# ------------------------------------------------------------
# Hardware era classification (drives the legacy-safe profile)
#
#   Legacy = pre-WDDM2.x-era drivers where display-mode switches,
#   fullscreen optimizations and HAGS misbehave or do nothing:
#     - INTEL : all GMA / Express-Chipset graphics, plus "HD
#               Graphics" families numbered below 5xxx and the
#               bare un-numbered "HD Graphics" (Sandy..Haswell)
#     - NVIDIA: FX, GeForce 4-digit (4xxx-9xxx), GT/GTS/GTX
#               2xx-8xx (incl. mobile M variants). GTX 9xx/10xx+,
#               RTX and MX stay Modern.
#     - AMD   : Radeon 7xxx-9xxx, X-series/Xpress/Mobility, every
#               HD xxxx family, R-series, Fury/VII/Frontier/Vega
#               (GCN), FirePro. RX 400+/Pro-W/Instinct/RDNA iGPUs
#               stay Modern.
# Unrecognized names default to Modern so existing behavior never
# regresses; virtual adapters report their own tag.
# ------------------------------------------------------------
function Resolve-GpuEra {
    param(
        [AllowEmptyString()][string]$Name,
        [string]$Vendor,
        [string]$Type
    )

    if ($Type -eq 'Virtual') { return 'Virtual' }

    $n = ''
    if ($Name)  { $n = $Name.ToLowerInvariant() }
    $v = ''
    if ($Vendor) { $v = $Vendor.ToUpperInvariant() }

    $isNvidia = ($v -eq 'NVIDIA') -or ($n -match 'nvidia|geforce|quadro|titan\b')
    $isAmd    = ($v -eq 'AMD')    -or ($n -match '\bradeon\b|\bati\b|firepro|firegl')
    $isIntel  = ($v -eq 'INTEL')  -or ($n -match '\bintel\b')

    if ($isNvidia) {
        if ($n -match 'geforce fx|quadro fx|\bfx\s*\d{3,4}')      { return 'Legacy' }
        if ($n -match '\bgeforce\s*[4-9]\d{3}\b')                  { return 'Legacy' }  # 6800/8800/9400...
        if ($n -match '\bg(t[xs]?)\s*[2-8]\d{2}[hm]?\b')           { return 'Legacy' }  # GT/GTS/GTX 2xx-8xx
        return 'Modern'
    }

    if ($isIntel) {
        if ($n -match 'graphics media accelerator|\bgma\b|express chipset') { return 'Legacy' }
        if ($n -match '\buhd\b|\biris\b|\barc\b')                  { return 'Modern' }  # Gen9.5+ / Xe / Arc naming
        if ($n -match '\bhd graphics\b')                           { return 'Legacy' }  # every HD Graphics generation
        return 'Modern'
    }

    if ($isAmd) {
        if ($n -match '\bradeon\s*[7-9]\d{3}\b')                   { return 'Legacy' }  # 7000..9800
        if ($n -match '\bx[1-9]\d{2,3}\b|radeon xpress|mobility radeon') { return 'Legacy' }  # X-series etc
        if ($n -match '\brx\s*\d|\bw\d{4}\b|\binstinct\b')         { return 'Modern' }  # Polaris+
        if ($n -match '\bvega\b|\bfury\b|radeon vii|pro duo|firepro|firegl') { return 'Legacy' }
        if ($n -match '\br[2-9]')                                  { return 'Legacy' }  # R-series (cards+APUs)
        if ($n -match '\bhd\s*\d{4}[dg]?\b')                       { return 'Legacy' }  # every HD family (incl. APU D/G)
        if ($n -match '\(tm\)\s*(graphics)?\s*$|\(tm\)\s*r\d')     { return 'Modern' }  # Zen+ APU names
        if ($n -match '\b[6789]\d{2}m\b|\b8\d{3}s\b')              { return 'Modern' }  # RDNA mobile iGPU
        return 'Modern'
    }

    return 'Unknown'
}

function Test-LegacyGpuPresent {
    <# True when at least one PRESENT physical adapter classifies
       as Legacy (integrated or discrete alike). Cached with the
       inventory itself; use -Refresh to re-evaluate. #>
    param([switch]$Refresh)

    foreach ($g in @(Get-GpuInfo -Refresh:$Refresh)) {
        if ($g.Present -and $g.Type -ne 'Virtual' -and $g.Era -eq 'Legacy') { return $true }
    }
    return $false
}

# ------------------------------------------------------------
# Public: merged, deduplicated, classified inventory (cached)
# ------------------------------------------------------------
function Get-GpuInfo {
    <#
        Returns one object per physical/virtual adapter:
        Index, Name, Vendor, Type (Integrated|Discrete|Virtual|Unknown),
        Primary (bool), Present (bool), DedicatedMB, VendorId, DeviceId,
        DriverVersion, Source.
        Use -Refresh to bypass the cache (adapter hotplug scenarios).
    #>
    param([switch]$Refresh)

    if (-not $Refresh -and $null -ne $script:DetectedGpus) { return $script:DetectedGpus }

    $dxgi = $null; $reg = $null; $os = $null
    if (Test-SuitePlatformWindows) {
        $dxgi = Get-GpuViaDxgi
        $reg  = Get-GpuViaRegistry
    } elseif ($IsLinux) {
        $os = Get-GpuViaLinux
    } elseif ($IsMacOS) {
        $os = Get-GpuViaMacos
    }

    $sources = @()
    if ($dxgi) { $sources += @{ Tag = 'DXGI';     List = $dxgi } }
    if ($reg)  { $sources += @{ Tag = 'Registry'; List = $reg  } }
    if ($os)   { $sources += @{ Tag = 'OS';       List = $os   } }
    if ($sources.Count -eq 0) {
        $cim = Get-GpuViaCim
        if ($cim) { $sources += @{ Tag = 'CIM'; List = $cim } }
    }

    $merged = [ordered]@{}
    foreach ($src in $sources) {
        $tag = $src.Tag
        foreach ($g in $src.List) {
            $nameIn = ''
            if ($g.Name) { $nameIn = ([string]$g.Name).Trim() }
            $key = $nameIn.ToLowerInvariant()
            if ($key -eq '') { $key = ('vid{0}-did{1}' -f $g.VendorId, $g.DeviceId) }

            if (-not $merged.Contains($key)) {
                $merged[$key] = @{
                    Name           = $nameIn
                    VendorId       = $g.VendorId
                    DeviceId       = $g.DeviceId
                    DedicatedBytes = $g.DedicatedBytes
                    SoftwareFlag   = [bool]$g.SoftwareFlag
                    DriverVersion  = $g.DriverVersion
                    Present        = [bool]$g.Present
                    Source         = $tag
                }
            } else {
                $cur = $merged[$key]
                # enrich missing details from secondary sources
                if (-not $cur.VendorId)       { $cur.VendorId       = $g.VendorId }
                if (-not $cur.DeviceId)       { $cur.DeviceId       = $g.DeviceId }
                if (-not $cur.DedicatedBytes) { $cur.DedicatedBytes = $g.DedicatedBytes }
                if (-not $cur.DriverVersion)  { $cur.DriverVersion  = $g.DriverVersion }
                if ($g.Present)               { $cur.Present        = $true }
                if ($cur.Source -notlike "*$tag*") { $cur.Source = "$($cur.Source)+$tag" }
            }
        }
    }

    $result = @()
    $idx = 0
    foreach ($key in $merged.Keys) {
        $g = $merged[$key]
        $vendor = Resolve-GpuVendor -Name $g.Name -VendorId $g.VendorId
        $type   = Resolve-GpuType   -Name $g.Name -Vendor $vendor -DedicatedBytes $g.DedicatedBytes
        if ($g.SoftwareFlag -or $vendor -eq 'VIRTUAL') { $type = 'Virtual' }
        $era    = Resolve-GpuEra    -Name $g.Name -Vendor $vendor -Type $type

        $dedMB = $null
        if ($g.DedicatedBytes) { $dedMB = [int][math]::Round(([uint64]$g.DedicatedBytes) / 1MB) }

        $result += [PSCustomObject]@{
            Index          = $idx
            Name           = $g.Name
            Vendor         = $vendor
            Type           = $type
            Era            = $era
            Primary        = ($idx -eq 0 -and $g.Present)
            Present        = [bool]$g.Present
            DedicatedMB    = $dedMB
            VendorId       = if ($null -ne $g.VendorId) { '0x{0:X4}' -f [uint32]$g.VendorId } else { $null }
            DeviceId       = if ($null -ne $g.DeviceId) { '0x{0:X4}' -f [uint32]$g.DeviceId } else { $null }
            DriverVersion  = $g.DriverVersion
            Source         = $g.Source
        }
        $idx++
    }

    $script:DetectedGpus = @($result)
    return $script:DetectedGpus
}

function Get-GpuStatusLine {
    <# Compact one-line summary for banners/logs:
       "Intel(R) HD Graphics 620 [Integrated] + NVIDIA GeForce RTX 3060 [Discrete]" #>
    param([switch]$Refresh)

    $gpus = @(Get-GpuInfo -Refresh:$Refresh)
    if ($gpus.Count -eq 0) { return 'No GPUs detected' }
    return (@($gpus | ForEach-Object {
        $eraTag = ''
        if ($_.Era -eq 'Legacy') { $eraTag = ', legacy' }
        '{0} [{1}{2}{3}]' -f $_.Name, $_.Type, $eraTag, $(if ($_.Primary) { ', primary' } else { '' })
    }) -join ' + ')
}

Export-ModuleMember -Function Get-GpuInfo, Get-GpuStatusLine, Resolve-GpuType, Resolve-GpuEra, Test-LegacyGpuPresent
