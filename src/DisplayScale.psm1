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
#  "Integer Scaling" once in your NVIDIA/AMD/Intel driver panel -
#  that is a driver toggle, software cannot flip it reliably.
#
#  STRETCH MODE (the FPS "stretched resolution" look):
#    When the caller passes -Stretch, the aspect-ratio guard is
#    deliberately relaxed: a lower-resolution mode may have a
#    DIFFERENT aspect ratio (e.g. a 4:3 mode on a 16:9 panel) and
#    is scaled to FILL the whole panel. Everything on screen then
#    looks wider - the classic stretched look many FPS players
#    use. Implemented via dmDisplayFixedOutput = DMDFO_STRETCH
#    (driver scaling set to "fill screen"). Restore always returns
#    the panel to native 1:1.
#
#  Windows-only backend (session-only, no permanent changes):
#    user32 ChangeDisplaySettingsExW with CDS_DYNAMIC (auto-reverts
#    on reboot even if a watcher crashes mid-session).
# ============================================================

Set-StrictMode -Version Latest

function Add-NativeDisplayType {
    <#
        Compiles the Windows display interop lazily, on first real use.
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

# DEVMODEW.dmFields masks we care about
$script:DM_BITSPERPEL         = 0x00040000
$script:DM_DISPLAYFREQUENCY   = 0x00400000
$script:DM_PELSWIDTH          = 0x00080000
$script:DM_PELSHEIGHT         = 0x00100000
$script:DM_DISPLAYFIXEDOUTPUT = 0x20000000

# dmDisplayFixedOutput values (DMDFO_*) - how a non-native mode is scaled:
# DEFAULT=0 (driver), STRETCH=1 (fill the whole panel), CENTER=2, ORIGINAL=3
$script:DMDFO_DEFAULT  = 0
$script:DMDFO_STRETCH  = 1

# Native mode remembered for the lifetime of the watcher session
$script:NativeMode     = $null
$script:ScaledActive   = $false
# State is kept in the restore path so native is always restored 1:1

function Get-CurrentDisplayMode {
    <# Returns the ACTIVE mode of the primary display as a hashtable. #>
    Add-NativeDisplayType
    $dm = [Suite.NativeDisplay+DEVMODEW]::Create()
    if (-not [Suite.NativeDisplay]::EnumDisplaySettingsExW($null, $script:ENUM_CURRENT, [ref]$dm, 0)) {
        return $null
    }
    return @{
        Width     = [int]$dm.dmPelsWidth
        Height    = [int]$dm.dmPelsHeight
        Bits      = [int]$dm.dmBitsPerPel
        Frequency = [int]$dm.dmDisplayFrequency
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
    return ,$modes
}

function Test-SameAspectRatio {
    param([int]$W1, [int]$H1, [int]$W2, [int]$H2)
    # cross-multiply with 2% tolerance (driver-listed modes are rarely exact)
    [math]::Abs(($W1 * $H2) - ($W2 * $H1)) -le (0.02 * $W2 * $H2)
}

function Select-ScaledMode {
    <#
        Chooses the best lower-resolution mode. Without -Stretch this is the
        same-aspect mode whose width is closest to ScalePercent% of native,
        preferring exact integer-ratio modes (crisp upscale). With -Stretch
        the aspect-ratio guard is relaxed: any mode that is smaller than the
        panel (width < native, height <= native) is eligible, and modes whose
        aspect DIFFERS from native win ties - so a 4:3 mode on a 16:9 panel is
        selected and the GPU fills the whole screen (the FPS stretched look).
        Refresh rate is kept at the native value whenever offered.
    #>
    param(
        [Parameter(Mandatory)]$Native,
        [Parameter(Mandatory)][ValidateRange(25,99)][int]$ScalePercent,
        [switch]$PreferInteger,
        [switch]$Stretch
    )

    $modes = Get-AvailableDisplayModes
    if ($modes.Count -eq 0) { return $null }

    # ---- candidate pool ----
    # Same-aspect mode: strictly smaller and same ratio (undistorted upscale).
    # Stretch mode:     strictly narrower (height may equal native, so modes
    #                   like 1440x1080 on a 1920x1080 panel are eligible) and
    #                   NEVER taller than the panel.
    $candidates = @($modes | Where-Object {
        if ($_.Width  -ge $Native.Width)  { return $false }
        if ($_.Height -gt $Native.Height) { return $false }
        if ($Stretch) { return $true }
        (Test-SameAspectRatio $_.Width $_.Height $Native.Width $Native.Height)
    })
    if ($candidates.Count -eq 0) { return $null }

    # ---- refresh-rate preservation (never drop the panel's Hz) ----
    # A lower-resolution mode that only exists at a LOW refresh silently drops
    # the panel from e.g. 144Hz to 60Hz for the whole session. In a fast FPS
    # that reads as lag / stutter and it ruins aim (input feels
    # delayed). This is also the mechanism by which "effects / flashes / large
    # maps" suddenly look stuttery: the game is being rendered and upscaled at
    # a low refresh while every effect adds frame time on top.
    #
    # Rule: only ever scale to a mode that keeps the panel's native refresh.
    # Modes advertising no explicit frequency (0 = "driver default") are kept.
    # When NO such mode exists we refuse to scale at all - staying at native
    # resolution is always smoother than a framerated 60Hz mode.
    $keptHz = @($candidates | Where-Object {
        $_.Frequency -eq 0 -or $_.Frequency -eq $Native.Frequency
    })
    # If the driver reports an unknown current refresh (Frequency = 0) we cannot
    # tell what to preserve - keep every candidate and skip the guard.
    if ($Native.Frequency -gt 0) {
        if ($keptHz.Count -gt 0) {
            $candidates = @($keptHz)
        } else {
            Write-Log ("No '{0}' scaled mode keeps the panel's native {1}Hz - display scaling skipped, staying at native (a 60Hz drop would feel like lag/stutter)." -f $Native.Width, $Native.Frequency) 'INFO'
            return $null
        }
    }

    # Choose the ACTUAL mode that is closest to the requested ScalePercent
    # target, while preferring exact integer-ratio modes (whose dimensions
    # evenly divide native -> crisp GPU upscale, no blur, less upscale cost)
    # whenever one exists near the target. In stretch mode a mode whose aspect
    # ratio differs from the panel's is preferred at equal distance because
    # that is what produces the visible stretched look.
    $targetW       = [math]::Round($Native.Width * ($ScalePercent / 100.0))
    $nativeAspect  = $Native.Width / [double]$Native.Height

    $scored = foreach ($c in $candidates) {
        $factor    = $Native.Width / [double]$c.Width
        $isInteger = ($factor -ge 1.9999 -and [math]::Abs($factor - [math]::Round($factor)) -lt 0.0001)
        $aspectDiff = if ($Stretch) {
            [math]::Abs(($c.Width / [double]$c.Height) - $nativeAspect)
        } else { 0 }
        [pscustomobject]@{
            Mode    = $c
            Dist    = [math]::Abs($c.Width - $targetW)          # closeness to tier target
            Integer = [int]$isInteger                            # 1 = crisp integer upscale
            Stretch = $aspectDiff                                # 0 = same aspect; >0 = will stretch
            Freq    = [math]::Abs($c.Frequency - $Native.Frequency)
        }
    }

    $sort = @(
        @{Expression='Dist';Ascending=$true},
        @{Expression='Integer';Ascending=$false}
    )
    if ($Stretch) { $sort += @{Expression='Stretch';Ascending=$false} }
    $sort += @{Expression='Freq';Ascending=$true}

    $best = $scored | Sort-Object $sort | Select-Object -First 1
    if (-not $best) { return $null }
    $best.Mode
}

function Enable-LowResolutionMode {
    <#
        Switches the primary display to a scaled-down mode.
        Remembers the native mode for the matching restore call.
        Idempotent: calling twice does nothing the second time.
        -Stretch picks a (possibly different-aspect) lower mode and scales it
        to fill the whole panel - the FPS "stretched" look. The full-screen
        stretch is requested via dmDisplayFixedOutput (driver "fill screen").
        Returns $false (never throws) when no suitable mode exists.
    #>
    param(
        [Parameter(Mandatory)][ValidateRange(25,99)][int]$ScalePercent,
        [switch]$PreferInteger,
        [switch]$Stretch
    )

    if ($script:ScaledActive) { return $true }

    $native = Get-CurrentDisplayMode
    if (-not $native) {
        Write-Log 'No display scaling backend available; staying at native.' 'WARN'
        return $false
    }
    $target = Select-ScaledMode -Native $native -ScalePercent $ScalePercent -PreferInteger:$PreferInteger -Stretch:$Stretch
    if (-not $target) {
        Write-Log 'No suitable lower mode found; staying at native.' 'WARN'
        return $false
    }

    Add-NativeDisplayType
    $dm = [Suite.NativeDisplay+DEVMODEW]::Create()
    $dm.dmPelsWidth       = [uint32]$target.Width
    $dm.dmPelsHeight      = [uint32]$target.Height
    $dm.dmBitsPerPel      = [uint32]$native.Bits
    $dm.dmDisplayFrequency= [uint32]$target.Frequency
    # PELSWIDTH | PELSHEIGHT | BITSPERPEL | DISPLAYFREQUENCY - the missing
    # DISPLAYFREQUENCY bit meant the requested refresh was silently ignored.
    $dm.dmFields = $script:DM_PELSWIDTH -bor $script:DM_PELSHEIGHT -bor $script:DM_BITSPERPEL -bor $script:DM_DISPLAYFREQUENCY
    if ($Stretch) {
        # Fill the whole screen: the driver stretches the non-native mode
        # rather than letterboxing it (the classic FPS stretched look).
        $dm.dmDisplayFixedOutput = $script:DMDFO_STRETCH
        $dm.dmFields = $dm.dmFields -bor $script:DM_DISPLAYFIXEDOUTPUT
    }

    $rc = [Suite.NativeDisplay]::ChangeDisplaySettingsExW($null, [ref]$dm, [IntPtr]::Zero, $script:CDS_DYNAMIC, [IntPtr]::Zero)
    if ($rc -ne $script:DISP_SUCCESS) {
        Write-Log ("Display switch rejected by driver (code {0}); staying native." -f $rc) 'WARN'
        return $false
    }

    # Remember stretch state so Restore returns to native 1:1.
    $native.Stretched = [bool]$Stretch
    $script:NativeMode   = $native
    $script:ScaledActive = $true
    if ($Stretch) {
        Write-Log ("Render resolution dropped AND stretched to fill: {0}x{1}@{2}Hz -> {3}x{4}@{5}Hz on a {6}x{7} panel (FPS stretched look, GPU load down)" -f `
            $native.Width, $native.Height, $native.Frequency, `
            $target.Width, $target.Height, $target.Frequency, `
            $native.Width, $native.Height) 'OK'
    } else {
        Write-Log ("Render resolution dropped: {0}x{1}@{2}Hz -> {3}x{4}@{5}Hz  (GPU load down, upscaled to {6}x{7})" -f `
            $native.Width, $native.Height, $native.Frequency, `
            $target.Width, $target.Height, $target.Frequency, `
            $native.Width, $native.Height) 'OK'
    }
    return $true
}

function Restore-NativeResolution {
    <#
        Puts the display back to its native mode. Safe to call any
        time; silently no-ops when nothing was scaled. Used on game
        exit AND in the watcher's finally block, so the screen is
        ALWAYS returned to normal.
        -Mode lets the crash-recovery path pass an explicitly
        remembered mode (from the recovery journal) even when this
        process never scaled the screen itself.
    #>
    param([hashtable]$Mode)

    if ($Mode) {
        $n = $Mode
    } else {
        if (-not $script:ScaledActive -or -not $script:NativeMode) { return }
        $n = $script:NativeMode
    }

    try {
        Add-NativeDisplayType
        $dm = [Suite.NativeDisplay+DEVMODEW]::Create()
        $dm.dmPelsWidth        = [uint32]$n.Width
        $dm.dmPelsHeight       = [uint32]$n.Height
        $dm.dmBitsPerPel       = [uint32]$n.Bits
        $dm.dmDisplayFrequency = [uint32]$n.Frequency
        # BITSPERPEL|PELSWIDTH|PELSHEIGHT|DISPLAYFREQUENCY. The native
        # (default) scaling mode is restored simply by NOT setting
        # DM_DISPLAYFIXEDOUTPUT - the driver returns to 1:1 pixels.
        $dm.dmFields           = 0x00040000 -bor 0x00080000 -bor 0x00100000 -bor 0x00400000
        [void][Suite.NativeDisplay]::ChangeDisplaySettingsExW($null, [ref]$dm, [IntPtr]::Zero, $script:CDS_DYNAMIC, [IntPtr]::Zero)
        Write-Log ("Native resolution restored ({0}x{1}@{2}Hz)" -f $n.Width, $n.Height, $n.Frequency) 'OK'
    } catch {
        Write-Log "Could not restore native resolution: $_" 'ERROR'
    } finally {
        $script:ScaledActive  = $false
        $script:NativeMode    = $null
    }
}

Export-ModuleMember -Function Get-CurrentDisplayMode, Get-AvailableDisplayModes,
    Select-ScaledMode, Enable-LowResolutionMode, Restore-NativeResolution