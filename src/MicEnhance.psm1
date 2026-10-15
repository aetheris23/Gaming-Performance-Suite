# ============================================================
#  MicEnhance.psm1 - Microphone enhancement companion bridge
#
#  This module does NOT process audio in PowerShell. Real-time
#  audio processing requires native code with deterministic
#  latency (sub-10ms) which PowerShell cannot provide.
#
#  Instead, this follows the frame-generation bridge pattern:
#  it launches a configured companion audio tool alongside the
#  detected game so the whole flow stays one-click.
#
#  COMPANION TOOL REQUIREMENTS:
#    - Must accept microphone input and produce enhanced output
#    - Must expose a virtual microphone endpoint (VB-Cable,
#      Voicemeeter, or custom WDM/KS driver) so communication
#      apps/games can select it as input device
#    - Must be able to run headless/minimized
#    - Recommended: RNNoise-based tool (native, ~2MB, <5% CPU)
#
#  VIRTUAL MICROPHONE NOTE:
#    Windows has no built-in "virtual microphone" that a user-
#    mode app can create without a kernel driver. The companion
#    tool MUST install its own virtual audio driver (e.g. the
#    VB-Cable driver that comes with RNNoise Windows builds, or
#    Voicemeeter's virtual I/O). This is a hard requirement.
# ============================================================

Set-StrictMode -Version Latest

# ------------------------------------------------------------
# Launch the configured microphone enhancement tool.
# Mirrors Invoke-FrameGenerationTool pattern exactly.
# ------------------------------------------------------------
function Invoke-MicEnhanceTool {
    param(
        [hashtable]$Settings,
        [ref]$LaunchedByUs,
        [ref]$ToolPid
    )

    if (-not $Settings -or -not $Settings['Enabled']) { return }
    $exe = [string]$Settings['ToolPath']
    if (-not $exe -or -not (Test-Path $exe)) {
        Write-Log 'Microphone enhancement enabled but tool path not found (Config.ps1).' 'WARN'
        return
    }

    $name = [IO.Path]::GetFileNameWithoutExtension($exe)
    $already = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($already) {
        Write-Log ("Mic-enhance tool already running (PID {0}); leaving it alone." -f $already[0].Id) 'INFO'
        return
    }

    try {
        # Launch minimized to avoid stealing focus from the game
        $proc = Start-Process -FilePath $exe -WindowStyle Minimized -PassThru
        $LaunchedByUs.Value = $true
        $ToolPid.Value      = $proc.Id
        Write-Log ("Microphone enhancement tool launched (PID {0})" -f $proc.Id) 'OK'
    } catch {
        Write-Log "Could not launch microphone enhancement tool: $_" 'WARN'
    }
}

# ------------------------------------------------------------
# Stop the microphone enhancement tool if we launched it.
# Mirrors Stop-FrameGenerationTool pattern exactly.
# ------------------------------------------------------------
function Stop-MicEnhanceTool {
    param([bool]$LaunchedByUs, [int]$ToolPid)
    if (-not $LaunchedByUs -or $ToolPid -le 0) { return }
    try {
        $p = Get-Process -Id $ToolPid -ErrorAction SilentlyContinue
        if ($p) {
            [void]$p.CloseMainWindow()          # graceful first
            Start-Sleep -Milliseconds 800
            if (-not $p.HasExited) { $p.Kill() }
            Write-Log 'Microphone enhancement tool closed.' 'INFO'
        }
    } catch { Write-Log "Failed to stop microphone enhancement tool: $_" 'WARN' }
}

# ------------------------------------------------------------
# OPTIONAL: Native C# DSP pipeline for basic processing
# Compiles lazily on first use. Only used if no companion tool
# is configured AND user wants basic gain/noise-gate/compressor.
# NOT a replacement for neural noise suppression.
# ------------------------------------------------------------
function Add-NativeAudioDspType {
    if ('Suite.NativeAudioDsp' -as [type]) { return }
    Add-Type -Namespace Suite -Name NativeAudioDsp -MemberDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NativeAudioDsp
{
    // Simple gain/clip protection - can be called from PowerShell
    // for basic microphone level adjustment without a full tool.
    // NOT a real-time pipeline - just a utility for one-shot use.

    public static float ApplyGain(float sample, float gainDb)
    {
        float linear = (float)Math.Pow(10.0, gainDb / 20.0);
        float result = sample * linear;
        // Hard clip protection at -0.1dBFS
        const float clipThreshold = 0.9886f;
        if (result > clipThreshold) return clipThreshold;
        if (result < -clipThreshold) return -clipThreshold;
        return result;
    }

    public static float NoiseGate(float sample, float thresholdDb, float floorDb)
    {
        float threshLinear = (float)Math.Pow(10.0, thresholdDb / 20.0);
        float floorLinear = (float)Math.Pow(10.0, floorDb / 20.0);
        float abs = Math.Abs(sample);
        if (abs < threshLinear) return sample * floorLinear;
        return sample;
    }
}
'@
}

Export-ModuleMember -Function Invoke-MicEnhanceTool, Stop-MicEnhanceTool, Add-NativeAudioDspType