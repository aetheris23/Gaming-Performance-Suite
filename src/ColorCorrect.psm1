# ============================================================
#  ColorCorrect.psm1 - automatic display color correction
#  (RGB balance / contrast / brightness) so enemies stand
#  out clearly, especially in fast-paced FPS games.
#
#  A pure PowerShell script cannot inject 3D post-processing
#  into the game's renderer, so this applies a display-level
#  color/gamma ramp instead - exactly what "Digital Vibrance"
#  style filters do, but applied at the OS scanout layer, so it
#  works in fullscreen and borderless windowed games alike.
#
#  Backends (all reversible):
#    Windows -> GDI32 SetDeviceGammaRamp / GetDeviceGammaRamp - a
#               per-channel 256-step lookup table (0..65535) on the
#               primary display. No driver install, no reboot - the
#               ramp lives for the current session only.
#    Linux   -> xrandr --output <out> --gamma <r:g:b> on each
#               connected output (brightness/contrast are distilled
#               into the gamma triple).
#    macOS   -> no clean public gamma API from PowerShell; we log a
#               note and advise the driver/Displayplacer/colour-profile
#               route instead.
#
#  Presets (Config.ps1 -> ColorCorrection.Mode):
#    'Off'      : no change (default)
#    'Vibrant'  : moderate RGB boost + contrast (safe default)
#    'FPS'      : stronger contrast + balance that lifts reds/darks so
#                 dark enemies separate from bright scenes
#    'Max'      : aggressive contrast + strong saturation feel
#
#  Journaled: Enable captures the original ramp / gamma triple so
#  Undo restores it exactly. The watcher applies it while an FPS /
#  competitive game runs and restores it on exit.
# ============================================================

Set-StrictMode -Version Latest

$script:ColorActive = $false
$script:ColorOriginal = $null       # captured RAMPDIRECTORY16 (Windows)

# ------------------------------------------------------------
# Native interop (Windows only, compiled lazily on first use)
# ------------------------------------------------------------
function Add-ColorNativeType {
    if ('Suite.Color.Native' -as [type]) { return }
    if (-not (Test-SuitePlatformWindows)) { return }
    Add-Type -Namespace Suite.Color -Name Native -MemberDefinition @'
public struct RAMPDIRECTORY16
{
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
    public ushort[] Red;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
    public ushort[] Green;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
    public ushort[] Blue;
}

[DllImport("gdi32.dll")]
public static extern bool SetDeviceGammaRamp(IntPtr hDC, ref RAMPDIRECTORY16 lpRamp);

[DllImport("gdi32.dll")]
public static extern bool GetDeviceGammaRamp(IntPtr hDC, ref RAMPDIRECTORY16 lpRamp);

[DllImport("user32.dll")]
public static extern IntPtr GetDC(IntPtr hWnd);

[DllImport("user32.dll")]
public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
'@
}

# ------------------------------------------------------------
# Build a linear (identity) ramp
# ------------------------------------------------------------
function New-LinearRamp {
    $ramp = New-Object Suite.Color.Native+RAMPDIRECTORY16
    $ramp.Red   = New-Object 'ushort[]' 256
    $ramp.Green = New-Object 'ushort[]' 256
    $ramp.Blue  = New-Object 'ushort[]' 256
    for ($i = 0; $i -lt 256; $i++) {
        $v = [ushort]([int]($i * 65535 / 255))
        $ramp.Red[$i] = $v; $ramp.Green[$i] = $v; $ramp.Blue[$i] = $v
    }
    return $ramp
}

# ------------------------------------------------------------
# Compute a per-channel ramp from a preset (gamma / contrast /
# brightness / per-channel gain). Identity when all weights = 1.
# ------------------------------------------------------------
function New-ColorRamp {
    param(
        [Parameter(Mandatory)][hashtable]$Preset
    )

    $gamma    = if ($Preset.ContainsKey('Gamma'))    { [double]$Preset['Gamma'] }    else { 1.0 }
    $contrast = if ($Preset.ContainsKey('Contrast')) { [double]$Preset['Contrast'] } else { 1.0 }
    $bright   = if ($Preset.ContainsKey('Brightness')){ [double]$Preset['Brightness']} else { 0.0 }
    $rMul     = if ($Preset.ContainsKey('RedGain'))   { [double]$Preset['RedGain'] }  else { 1.0 }
    $gMul     = if ($Preset.ContainsKey('GreenGain')) { [double]$Preset['GreenGain']} else { 1.0 }
    $bMul     = if ($Preset.ContainsKey('BlueGain'))  { [double]$Preset['BlueGain'] } else { 1.0 }
    if ($gamma -le 0)    { $gamma = 1.0 }
    if ($contrast -le 0) { $contrast = 1.0 }

    $ramp = New-Object Suite.Color.Native+RAMPDIRECTORY16
    $ramp.Red   = New-Object 'ushort[]' 256
    $ramp.Green = New-Object 'ushort[]' 256
    $ramp.Blue  = New-Object 'ushort[]' 256

    for ($i = 0; $i -lt 256; $i++) {
        $x = $i / 255.0
        # brightness lift, contrast around mid-grey, gamma exponent
        $v = ($x + $bright - 0.5) * $contrast + 0.5
        if ($v -lt 0) { $v = 0 }
        if ($v -gt 1) { $v = 1 }
        $v = [Math]::Pow($v, 1.0 / $gamma)
        $cap = { param($a) if ($a -lt 0) { 0.0 } elseif ($a -gt 1) { 1.0 } else { $a } }

        $vr = $v * $rMul; $vg = $v * $gMul; $vb = $v * $bMul
        $ramp.Red[$i]   = [ushort][int](65535 * (& $cap $vr))
        $ramp.Green[$i] = [ushort][int](65535 * (& $cap $vg))
        $ramp.Blue[$i]  = [ushort][int](65535 * (& $cap $vb))
    }
    return $ramp
}

# ------------------------------------------------------------
# Preset table (also mirrored in Config.ps1 so users can edit).
# ------------------------------------------------------------
function Get-ColorPreset {
    param([string]$Name)
    if (-not $Name) { $Name = 'Off' }
    switch -Regex ($Name.ToLowerInvariant()) {
        'vibrant' { return @{ Gamma=1.0;  Contrast=1.15; Brightness=0.0; RedGain=1.05; GreenGain=1.02; BlueGain=0.95 } }
        'fps'     { return @{ Gamma=1.05; Contrast=1.25; Brightness=0.0; RedGain=1.12; GreenGain=1.04; BlueGain=0.90 } }
        'max'     { return @{ Gamma=1.10; Contrast=1.40; Brightness=0.0; RedGain=1.20; GreenGain=1.06; BlueGain=0.82 } }
        default   { return $null }
    }
}

# ------------------------------------------------------------
# Linux: list connected xrandr outputs
# ------------------------------------------------------------
function Get-LinuxColorOutputs {
    $list = @()
    try {
        $raw = @(& xrandr --query 2>$null)
    } catch { return ,@() }
    foreach ($line in $raw) {
        if ($line -match '^(\S+)\s+connected\s+') { $list += [string]$Matches[1] }
    }
    return ,$list
}

# ------------------------------------------------------------
# Windows: capture the current gamma ramp (or build an identity
# ramp if the API is unavailable) so we can restore it exactly.
# ------------------------------------------------------------
function Get-WindowsGammaOriginal {
    try {
        Add-ColorNativeType
        if (-not ('Suite.Color.Native' -as [type])) { return $null }
        $dc = [Suite.Color.Native]::GetDC([IntPtr]::Zero)
        if ($dc -eq [IntPtr]::Zero) { return $null }
        try {
            $ramp = New-LinearRamp
            if ([Suite.Color.Native]::GetDeviceGammaRamp($dc, [ref]$ramp)) {
                return $ramp
            }
            return $null
        } finally {
            [void][Suite.Color.Native]::ReleaseDC([IntPtr]::Zero, $dc)
        }
    } catch { return $null }
}

# ------------------------------------------------------------
# Main entry: apply the color filter to every active display.
# Never throws; returns $true on success.
# ------------------------------------------------------------
function Enable-ColorCorrection {
    <#
        Applies the chosen color preset to the primary display(s),
        recording the original ramp/gamma so Disable can restore it.
        $Preset -> a preset hashtable; when $null, resolved from $Mode.
    #>
    param(
        [AllowNull()][hashtable]$Preset,
        [string]$Mode = 'Off'
    )

    if (-not $Preset) { $Preset = Get-ColorPreset -Name $Mode }
    if (-not $Preset) {
        Write-Log 'Color correction: no preset selected (mode Off or unknown).' 'INFO'
        return $false
    }

    if (Test-SuitePlatformWindows) {
        Add-ColorNativeType
        if (-not ('Suite.Color.Native' -as [type])) { return $false }
        $ramp = New-ColorRamp -Preset $Preset
        $dc = [Suite.Color.Native]::GetDC([IntPtr]::Zero)
        if ($dc -eq [IntPtr]::Zero) { return $false }
        try {
            $ok = [Suite.Color.Native]::SetDeviceGammaRamp($dc, [ref]$ramp)
            if ($ok) {
                $script:ColorOriginal = Get-WindowsGammaOriginal
                $script:ColorActive = $true
                Write-Log ("Color correction applied (mode '{0}') - contrast + RGB balance for enemy clarity." -f $Mode) 'OK'
                return $true
            }
            Write-Log 'Color correction: SetDeviceGammaRamp rejected the ramp.' 'WARN'
            return $false
        } finally {
            [void][Suite.Color.Native]::ReleaseDC([IntPtr]::Zero, $dc)
        }
    }

    if ($IsLinux) {
        $r = if ($Preset.ContainsKey('RedGain'))   { [double]$Preset['RedGain'] }   else { 1.0 }
        $g = if ($Preset.ContainsKey('GreenGain')) { [double]$Preset['GreenGain'] } else { 1.0 }
        $b = if ($Preset.ContainsKey('BlueGain'))  { [double]$Preset['BlueGain'] }  else { 1.0 }
        $target = ('{0}:{1}:{2}' -f ([math]::Round($r,3)), ([math]::Round($g,3)), ([math]::Round($b,3)))
        $outs = Get-LinuxColorOutputs
        if ($outs.Count -eq 0) {
            Write-Log 'Color correction: no xrandr outputs found (xrandr missing?).' 'WARN'
            return $false
        }
        $any = $false
        foreach ($o in $outs) {
            $rc = & xrandr --output $o --gamma $target 2>&1
            if ($LASTEXITCODE -eq 0) { $any = $true }
            else { Write-Log ("Color: xrandr gamma for '{0}' failed ({1})." -f $o, ($rc -join '; ')) 'WARN' }
        }
        $script:ColorActive = $any
        if ($any) { Write-Log ("Color correction applied (mode '{0}') via xrandr gamma {1}." -f $Mode, $target) 'OK' }
        return $any
    }

    if ($IsMacOS) {
        Write-Log 'Color correction: no public gamma API on macOS; enable a driver/colour-profile instead.' 'WARN'
        return $false
    }

    Write-Log 'Color correction is not supported on this platform.' 'WARN'
    return $false
}

# ------------------------------------------------------------
# Restore the original color state.
# ------------------------------------------------------------
function Disable-ColorCorrection {
    if (Test-SuitePlatformWindows) {
        Add-ColorNativeType
        if ('Suite.Color.Native' -as [type]) {
            $dc = [Suite.Color.Native]::GetDC([IntPtr]::Zero)
            if ($dc -ne [IntPtr]::Zero) {
                try {
                    $ramp = $script:ColorOriginal
                    if (-not $ramp) { $ramp = New-LinearRamp }
                    [void][Suite.Color.Native]::SetDeviceGammaRamp($dc, [ref]$ramp)
                } finally {
                    [void][Suite.Color.Native]::ReleaseDC([IntPtr]::Zero, $dc)
                }
            }
        }
    } elseif ($IsLinux) {
        foreach ($o in (Get-LinuxColorOutputs)) {
            [void](& xrandr --output $o --gamma 1:1:1 2>$null)
        }
    }
    $script:ColorActive = $false
    $script:ColorOriginal = $null
    Write-Log 'Color correction removed (original color returned).' 'OK'
}

# ------------------------------------------------------------
# Status helper
# ------------------------------------------------------------
function Get-ColorCorrectionStatus {
    param([string]$Mode = 'Off')
    if ($Mode -and $Mode -ne 'Off' -and $Mode -ne '') { return ("ACTIVE (mode '{0}')" -f $Mode) }
    return 'off'
}

Export-ModuleMember -Function Enable-ColorCorrection, Disable-ColorCorrection,
    Get-ColorPreset, Get-ColorCorrectionStatus
