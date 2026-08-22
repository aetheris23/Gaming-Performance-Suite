# ============================================================
#  DisplayScale.psm1 - dynamic resolution scaling while gaming
#
#  When a supported fullscreen game launches, the desktop
#  display mode is temporarily switched to a lower resolution
#  so the game's render target shrinks (GPU load drops hard).
#  When the game closes - or the watcher stops - the native
#  resolution is restored instantly.
#
#  Why the upscale stays sharp (no pixelation / no blur):
#    - Only SAME-ASPECT-RATIO modes are ever selected, so the
#      GPU/monitor scaler stretches uniformly (no distortion).
#    - Integer modes (exactly 1/2 native WxH) are preferred;
#      an integer upscale is mathematically pixel-perfect.
#    - The upscale happens in the GPU scanout hardware at the
#      panel's native refresh - zero CPU cost, zero input lag
#      added by this script.
#  For a strictly pixel-perfect image enable "GPU Scaling" /
#  "Integer Scaling" once in your NVIDIA/AMD driver panel -
#  that is a driver toggle, software cannot flip it reliably.
# ============================================================

Set-StrictMode -Version Latest

function Add-NativeDisplayType {
    <#
        Compiles the display interop lazily, on first real use.
        Add-Type spins up the C# compiler, which costs noticeable time
        on low-spec machines; deferring it keeps watcher startup fast
        (the one-time compile then lands inside the game's loading
        screen instead of before the watcher is even up).
    #>
    if ('Suite.NativeDisplay' -as [type]) { return }
    Add-Type -Namespace Suite -Name NativeDisplay -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern bool EnumDisplaySettingsExW(string lpszDeviceName,
    int iModeNum, ref DEVMODEW lpDevMode, uint dwFlags);

[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int ChangeDisplaySettingsExW(string lpszDeviceName,
    ref DEVMODEW lpDevMode, IntPtr hwnd, uint dwFlags, IntPtr lParam);

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct DEVMODEW
{
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
    public string dmDeviceName;
    public ushort dmSpecVersion;
    public ushort dmDriverVersion;
    public ushort dmSize;
    public ushort dmDriverExtra;
    public uint   dmFields;
    public int    dmPositionX;
    public int    dmPositionY;
    public uint   dmDisplayOrientation;
    public uint   dmDisplayFixedOutput;
    public short  dmColor;
    public short  dmDuplex;
    public short  dmYResolution;
    public short  dmTTOption;
    public short  dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
    public string dmFormName;
    public ushort dmLogPixels;
    public uint   dmBitsPerPel;
    public uint   dmPelsWidth;
    public uint   dmPelsHeight;
    public uint   dmDisplayFlags;
    public uint   dmDisplayFrequency;
    public uint   dmICMMethod;
    public uint   dmICMIntent;
    public uint   dmMediaType;
    public uint   dmDitherType;
    public uint   dmReserved1;
    public uint   dmReserved2;
    public uint   dmPanningWidth;
    public uint   dmPanningHeight;

    public static DEVMODEW Create()
    {
        var dm = new DEVMODEW();
        dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODEW));
        return dm;
    }
}
'@
}

# ENUM_CURRENT_SETTINGS / change flags
$script:ENUM_CURRENT   = -1
$script:CDS_DYNAMIC    = 0x00000004   # session-only: auto-reverts on reboot even if we crash
$script:DISP_SUCCESS   = 0

# Native mode remembered for the lifetime of the watcher session
$script:NativeMode     = $null
$script:ScaledActive   = $false

function Get-CurrentDisplayMode {
    <# Returns the ACTIVE mode of the primary display as a hashtable. #>
    Add-NativeDisplayType
    $dm = [Suite.NativeDisplay+DEVMODEW]::Create()
    if (-not [Suite.NativeDisplay]::EnumDisplaySettingsExW($null, $script:ENUM_CURRENT, [ref]$dm, 0)) {
        throw 'EnumDisplaySettingsExW failed for the primary display.'
    }
    @{
        Width    = [int]$dm.dmPelsWidth
        Height   = [int]$dm.dmPelsHeight
        Bits     = [int]$dm.dmBitsPerPel
        Frequency= [int]$dm.dmDisplayFrequency
    }
}

function Get-AvailableDisplayModes {
    <# All distinct WxH@Hz modes the display advertises. #>
    Add-NativeDisplayType
    $modes = @()
    for ($i = 0; $i -lt 400; $i++) {
        $dm = [Suite.NativeDisplay+DEVMODEW]::Create()
        if (-not [Suite.NativeDisplay]::EnumDisplaySettingsExW($null, $i, [ref]$dm, 0)) { break }
        $modes += @{
            Width     = [int]$dm.dmPelsWidth
            Height    = [int]$dm.dmPelsHeight
            Frequency = [int]$dm.dmDisplayFrequency
        }
    }
    ,$modes
}

function Test-SameAspectRatio {
    param([int]$W1, [int]$H1, [int]$W2, [int]$H2)
    # cross-multiply with 2% tolerance (driver-listed modes are rarely exact)
    [math]::Abs(($W1 * $H2) - ($W2 * $H1)) -le (0.02 * $W2 * $H2)
}

function Select-ScaledMode {
    <#
        Chooses the best lower-resolution mode:
          1. exactly half of native (perfect integer upscale) if allowed
          2. otherwise the same-aspect mode whose width is closest
             to ScalePercent% of native width
        Refresh rate is kept at the native value whenever offered.
    #>
    param(
        [Parameter(Mandatory)]$Native,
        [Parameter(Mandatory)][ValidateRange(25,99)][int]$ScalePercent,
        [switch]$PreferInteger
    )

    $modes = Get-AvailableDisplayModes
    if ($modes.Count -eq 0) { return $null }

    # ---- candidate pool: strictly smaller, same aspect ratio ----
    $candidates = @($modes | Where-Object {
        $_.Width  -lt $Native.Width  -and
        $_.Height -lt $Native.Height -and
        (Test-SameAspectRatio $_.Width $_.Height $Native.Width $Native.Height)
    })
    if ($candidates.Count -eq 0) { return $null }

    # ---- integer path: exact 1/2 dimensions -> flawless upscale ----
    if ($PreferInteger) {
        $halfW = [int]($Native.Width  / 2)
        $halfH = [int]($Native.Height / 2)
        if (($halfW * 2) -eq $Native.Width -and ($halfH * 2) -eq $Native.Height) {
            $integers = @($candidates | Where-Object {
                $_.Width -eq $halfW -and $_.Height -eq $halfH
            })
            if ($integers.Count -gt 0) {
                $best = $integers | Sort-Object { [math]::Abs($_.Frequency - $Native.Frequency) } |
                        Select-Object -First 1
                return $best
            }
        }
    }

    # ---- percentage path: closest width to the requested scale ----
    $targetW = [math]::Round($Native.Width * ($ScalePercent / 100.0))
    $best = $candidates | Sort-Object {
        [math]::Abs($_.Width - $targetW) * 10000 + [math]::Abs($_.Frequency - $Native.Frequency)
    } | Select-Object -First 1
    $best
}

function Enable-LowResolutionMode {
    <#
        Switches the primary display to a scaled-down mode.
        Remembers the native mode for the matching restore call.
        Idempotent: calling twice does nothing the second time.
    #>
    param(
        [Parameter(Mandatory)][ValidateRange(25,99)][int]$ScalePercent,
        [switch]$PreferInteger
    )

    if ($script:ScaledActive) { return $true }

    Add-NativeDisplayType
    $native = Get-CurrentDisplayMode
    $target = Select-ScaledMode -Native $native -ScalePercent $ScalePercent -PreferInteger:$PreferInteger
    if (-not $target) {
        Write-Log 'No suitable same-aspect lower mode found; staying at native.' 'WARN'
        return $false
    }

    $dm = [Suite.NativeDisplay+DEVMODEW]::Create()
    $dm.dmPelsWidth       = [uint32]$target.Width
    $dm.dmPelsHeight      = [uint32]$target.Height
    $dm.dmBitsPerPel      = [uint32]$native.Bits
    $dm.dmDisplayFrequency= [uint32]$target.Frequency
    $dm.dmFields          = 0x00080000 -bor 0x00100000 -bor 0x00400000  # DM_PELSHEIGHT|DM_PELSWIDTH|DM_BITSPERPEL

    $rc = [Suite.NativeDisplay]::ChangeDisplaySettingsExW($null, [ref]$dm, [IntPtr]::Zero, $script:CDS_DYNAMIC, [IntPtr]::Zero)
    if ($rc -ne $script:DISP_SUCCESS) {
        Write-Log ("Display switch rejected by driver (code {0}); staying native." -f $rc) 'WARN'
        return $false
    }

    $script:NativeMode   = $native
    $script:ScaledActive = $true
    Write-Log ("Render resolution dropped: {0}x{1}@{2}Hz -> {3}x{4}Hz  (GPU load down, upscaled to {5}x{6})" -f `
        $native.Width, $native.Height, $native.Frequency, `
        $target.Width, $target.Height, $target.Frequency, `
        $native.Width, $native.Height) 'OK'
    return $true
}

function Restore-NativeResolution {
    <#
        Puts the display back to its native mode. Safe to call any
        time; silently no-ops when nothing was scaled. Used on game
        exit AND in the watcher's finally block, so the screen is
        ALWAYS returned to normal.
    #>
    if (-not $script:ScaledActive -or -not $script:NativeMode) { return }

    Add-NativeDisplayType
    $n = $script:NativeMode
    try {
        $dm = [Suite.NativeDisplay+DEVMODEW]::Create()
        $dm.dmPelsWidth        = [uint32]$n.Width
        $dm.dmPelsHeight       = [uint32]$n.Height
        $dm.dmBitsPerPel       = [uint32]$n.Bits
        $dm.dmDisplayFrequency = [uint32]$n.Frequency
        $dm.dmFields           = 0x00080000 -bor 0x00100000 -bor 0x00400000
        [void][Suite.NativeDisplay]::ChangeDisplaySettingsExW($null, [ref]$dm, [IntPtr]::Zero, $script:CDS_DYNAMIC, [IntPtr]::Zero)
        Write-Log ("Native resolution restored ({0}x{1}@{2}Hz)" -f $n.Width, $n.Height, $n.Frequency) 'OK'
    } catch {
        Write-Log "Could not restore native resolution: $_" 'ERROR'
    } finally {
        $script:ScaledActive = $false
        $script:NativeMode   = $null
    }
}

Export-ModuleMember -Function Get-CurrentDisplayMode, Get-AvailableDisplayModes,
    Select-ScaledMode, Enable-LowResolutionMode, Restore-NativeResolution
