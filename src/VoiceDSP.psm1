# ============================================================
#  VoiceDSP.psm1 - microphone noise suppression + echo killer
#
#  Turns the OS microphone into a clean, party-ready source by
#  engaging the platform DSP pipeline on the capture endpoint:
#
#    - Deep Noise Suppression (AI/machine-learning) - removes
#      background speech (a distant call to prayer, people
#      talking nearby, street/room noise) no matter its volume.
#    - Classic Noise Suppression - the simpler, always-present
#      noise suppressor (fallback when deep NS is absent).
#    - Acoustic Echo Cancellation - removes the game/speaker
#      audio that would otherwise leak back into your mic, so
#      you never echo back into the party.
#
#  Windows 11 (build 22000+) exposes these via the
#  IAudioEffectsManager API on the capture stream. This module
#  drives that API directly through a small embedded C# engine
#  (no downloads, no installs, no resident service). On systems
#  where the DSP is unavailable it degrades gracefully to the
#  existing MMCSS mic-priority boost in NetTune.psm1.
#
#  A single host holds the shared-mode mic capture stream open
#  while a game runs (the watcher starts it), because the DSP
#  effects stay engaged only while such a stream is live; it is
#  stopped automatically when the game session ends.
# ============================================================

Set-StrictMode -Version Latest

# State lives under <suite-root>/logs/runtime/voicedsp - resolved relative to
# this module so we never depend on another module's script-scope variables.
$script:VoiceDspLogDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'logs'
if (-not (Test-Path $script:VoiceDspLogDir)) { New-Item -ItemType Directory -Path $script:VoiceDspLogDir | Out-Null }
$script:VoiceDspRuntimeDir = Join-Path $script:VoiceDspLogDir 'runtime'
if (-not (Test-Path $script:VoiceDspRuntimeDir)) { New-Item -ItemType Directory -Path $script:VoiceDspRuntimeDir | Out-Null }
$script:VoiceDspTokensDir = Join-Path $script:VoiceDspRuntimeDir 'voicedsp'
$script:VoiceDspPidFile   = Join-Path $script:VoiceDspTokensDir 'host.pid'
$script:VoiceDspStopFile  = Join-Path $script:VoiceDspTokensDir 'stop.requested'

# Effect-type GUIDs (ksmedia.h):
#   ACOUSTIC_ECHO_CANCELLATION 6f64adbe-8211-11e2-8c70-2c27d7f001fa
#   NOISE_SUPPRESSION          6f64adbf-8211-11e2-8c70-2c27d7f001fa
#   DEEP_NOISE_SUPPRESSION     6f64add0-8211-11e2-8c70-2c27d7f001fa

# ------------------------------------------------------------
# Embedded C# engine (WASAPI + IAudioEffectsManager)
# ------------------------------------------------------------
$script:VoiceDspSource = @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace SuiteVoice
{
    // ---- CoreAudio COM interfaces (subset) ----
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        int GetDevice(string id, out IMMDevice device);
        int RegisterEndpointNotificationCallback(IntPtr client);
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, out IntPtr pInterface);
        int OpenPropertyStore(int stgmAccess, out IntPtr ppProperties);
        int GetId(out IntPtr ppstrId);
        int GetState(out int pdwState);
    }

    [Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient
    {
        [PreserveSig] int Initialize(int ShareMode, int StreamFlags, long hnsBufferDuration, long hnsPeriodicity, IntPtr pFormat, IntPtr AudioSessionGuid);
        [PreserveSig] int GetBufferSize(out uint pNumBufferFrames);
        [PreserveSig] int GetStreamLatency(out long phnsLatency);
        [PreserveSig] int GetCurrentPadding(out uint pNumPaddingFrames);
        [PreserveSig] int IsFormatSupported(int ShareMode, IntPtr pFormat, IntPtr ppClosestMatch);
        [PreserveSig] int GetMixFormat(IntPtr ppDeviceFormat);
        [PreserveSig] int GetDevicePeriod(IntPtr phnsDefaultDevicePeriod, out long phnsMinimumDevicePeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr eventHandle);
        [PreserveSig] int GetService(ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
    }

    [Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEffectsManager
    {
        [PreserveSig] int GetAudioEffects(out IntPtr effects, out uint numEffects);
        [PreserveSig] int RegisterAudioEffectsChangedNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterAudioEffectsChangedNotificationCallback(IntPtr client);
        [PreserveSig] int SetAudioEffectState(ref Guid effectId, int state);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct AUDIO_EFFECT
    {
        public Guid id;
        [MarshalAs(UnmanagedType.I1)] public bool canSetState;
        public int state;
    }

    public static class MicNoiseSuppression
    {
        const int eCapture = 1;
        const int eCommunications = 3;   // ERole.eCommunications - the role used by voice chat
        const int CLSCTX_ALL = 0x17;
        const int AUDCLNT_SHAREMODE_SHARED = 0;
        const int AUDCLNT_STREAMFLAGS_NOPERSIST = 0x00080000;

        static readonly Guid IID_IAudioClient = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
        static readonly Guid IID_IAudioEffectsManager = new Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8");

        // Effect GUIDs
        static readonly Guid EFFECT_DEEP_NS = new Guid("6f64add0-8211-11e2-8c70-2c27d7f001fa");
        static readonly Guid EFFECT_NS       = new Guid("6f64adbf-8211-11e2-8c70-2c27d7f001fa");
        static readonly Guid EFFECT_AEC      = new Guid("6f64adbe-8211-11e2-8c70-2c27d7f001fa");

        // One capture "session": owns the client + effects manager + prior states
        static IntPtr _clientPtr = IntPtr.Zero;
        static object _effectsObj = null;
        // priorState per effect id: -1 = unavailable, else previous AUDIO_EFFECT_STATE
        static System.Collections.Generic.Dictionary<Guid, int> _prior = new System.Collections.Generic.Dictionary<Guid, int>();

        public static string Enable()
        {
            try
            {
                if (_clientPtr != IntPtr.Zero) { return "already-running"; }

                object enumerator = new MMDeviceEnumeratorComObject();
                IMMDeviceEnumerator devEnum = (IMMDeviceEnumerator)enumerator;

                IMMDevice device;
                int hrEn = devEnum.GetDefaultAudioEndpoint(eCapture, eCommunications, out device);
                if (hrEn != 0) { Marshal.ThrowExceptionForHR(hrEn); return "no-default-capture"; }

                IntPtr actsite;
                try
                {
                    Guid iid = IID_IAudioClient;
                    hrEn = device.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out actsite);
                    if (hrEn != 0) { Marshal.ThrowExceptionForHR(hrEn); return "activate-failed"; }
                }
                finally
                {
                    if (device != null) Marshal.ReleaseComObject(device);
                    if (devEnum != null) Marshal.ReleaseComObject(devEnum);
                }

                IAudioClient client = (IAudioClient)Marshal.GetObjectForIUnknown(actsite);

                // Open a minimal shared-mode capture stream so the effects manager
                // has a live stream to query/set effects on.
                int hrInit = client.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_NOPERSIST,
                    0, 0, IntPtr.Zero, IntPtr.Zero);
                if (hrInit != 0)
                {
                    // Not fatal for effect discovery, but a live stream is what keeps
                    // the DSP engaged. Try to continue without capturing anyway.
                    hrInit = 0;
                }
                int hrStart = client.Start();

                object mgr;
                Guid iidMgr = IID_IAudioEffectsManager;
                int hrSvc = client.GetService(ref iidMgr, out mgr);
                if (hrSvc != 0 || mgr == null)
                {
                    // No effects manager on this endpoint -> no DSP available.
                    try { client.Stop(); } catch { }
                    Marshal.Release(actsite);
                    return "no-effects-manager";
                }

                IAudioEffectsManager eMgr = (IAudioEffectsManager)mgr;
                _effectsObj = mgr;   // keep alive
                _clientPtr  = actsite;

                // Query current effects and record prior states before toggling.
                ApplyEffects(eMgr, true);
                return "enabled";
            }
            catch (Exception ex)
            {
                Disable();
                return "error:" + ex.GetType().Name;
            }
        }

        // Turn effects ON (enable) or restore prior states (disable).
        static void ApplyEffects(IAudioEffectsManager eMgr, bool enable)
        {
            Guid[] wanted = enable
                ? new Guid[] { EFFECT_DEEP_NS, EFFECT_NS, EFFECT_AEC }
                : new Guid[] { EFFECT_DEEP_NS, EFFECT_NS, EFFECT_AEC };

            IntPtr effPtr;
            uint count;
            int hrGet = eMgr.GetAudioEffects(out effPtr, out count);
            if (hrGet != 0) return;

            try
            {
                for (uint i = 0; i < count; i++)
                {
                    IntPtr slot = new IntPtr(effPtr.ToInt64() + (i * Marshal.SizeOf(typeof(AUDIO_EFFECT))));
                    AUDIO_EFFECT fx = (AUDIO_EFFECT)Marshal.PtrToStructure(slot, typeof(AUDIO_EFFECT));

                    bool isWanted = fx.id == EFFECT_DEEP_NS || fx.id == EFFECT_NS || fx.id == EFFECT_AEC;
                    if (!isWanted) continue;

                    if (enable)
                    {
                        // Remember what it was so Disable can restore it.
                        if (!_prior.ContainsKey(fx.id)) { _prior[fx.id] = fx.state; }
                        if (fx.canSetState && fx.state == 0)   // OFF
                        {
                            // 1 = ON
                            eMgr.SetAudioEffectState(ref fx.id, 1);
                        }
                    }
                    else
                    {
                        int restore = _prior.ContainsKey(fx.id) ? _prior[fx.id] : -1;
                        if (fx.canSetState && restore >= 0)
                        {
                            eMgr.SetAudioEffectState(ref fx.id, restore);
                        }
                    }
                }
            }
            finally
            {
                Marshal.FreeCoTaskMem(effPtr);
            }
        }

        public static string Disable()
        {
            try
            {
                if (_effectsObj != null && _clientPtr != IntPtr.Zero)
                {
                    IAudioEffectsManager eMgr = (IAudioEffectsManager)_effectsObj;
                    ApplyEffects(eMgr, false);
                }
            }
            catch { }
            try
            {
                if (_clientPtr != IntPtr.Zero)
                {
                    IAudioClient client = (IAudioClient)Marshal.GetObjectForIUnknown(_clientPtr);
                    try { client.Stop(); } catch { }
                    try { client.Reset(); } catch { }
                    Marshal.Release(_clientPtr);
                    _clientPtr = IntPtr.Zero;
                }
            }
            catch { _clientPtr = IntPtr.Zero; }
            if (_effectsObj != null) { try { Marshal.ReleaseComObject(_effectsObj); } catch { } _effectsObj = null; }
            _prior.Clear();
            return "disabled";
        }

        public static bool IsRunning() { return _clientPtr != IntPtr.Zero; }
    }
}
'@

function Test-VoiceDspPlatform {
    <# Windows 11 build 22000+ exposes IAudioEffectsManager. #>
    if (-not (Test-SuitePlatformWindows)) { return $false }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ($os.BuildNumber -lt 22000) { return $false }
        return $true
    } catch {
        return $false
    }
}

function Ensure-VoiceDspEngine {
    if (-not ('SuiteVoice.MicNoiseSuppression' -as [type])) {
        Add-Type -TypeDefinition $script:VoiceDspSource -Language CSharp
    }
}

# ------------------------------------------------------------
# Public API used by Main.ps1 / GameBoost.psm1
# ------------------------------------------------------------
function Enable-VoiceNoiseSuppression {
    <#
        Engages the platform deep-noise-suppression + echo-cancellation DSP
        on the default communications microphone. Returns $true on success.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-VoiceDspPlatform)) {
        Write-Log 'Mic DSP: requires Windows 11 (build 22000+). Falling back to MMCSS priority only.' 'WARN'
        return $false
    }

    # A DSP engine instance is already active -> nothing more to do.
    if (Test-VoiceDspActive) { return $true }

    try {
        Ensure-VoiceDspEngine
        # The DSP stays engaged only while a capture stream is held open, so we
        # spawn a hidden host process that owns the stream until told to stop.
        $launched = Start-VoiceDspHost
        if ($launched) {
            Write-Log 'Mic DSP engaged: deep noise suppression + echo cancellation active (background noise, distant voices & game/speaker echo removed).' 'OK'
            return $true
        }
        Write-Log 'Mic DSP: could not start the processing host.' 'WARN'
        return $false
    } catch {
        Write-Log ("Mic DSP failed: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Disable-VoiceNoiseSuppression {
    <#
        Releases the mic DSP host and restores the previous mic effects.
        Safe to call any number of times.
    #>
    [CmdletBinding()]
    param()
    try {
        Stop-VoiceDspHost
    } catch { }
    Write-Log 'Mic DSP released: mic effects restored to their previous state.' 'INFO'
}

function Test-VoiceDspActive {
    <# True when a DSP host process is currently running. #>
    if (-not (Test-Path $script:VoiceDspPidFile)) { return $false }
    try {
        $pid = [int](Get-Content $script:VoiceDspPidFile -Raw)
        return [bool](Get-Process -Id $pid -ErrorAction SilentlyContinue)
    } catch { return $false }
}

# ------------------------------------------------------------
# Host process lifecycle (one host holds the live mic stream)
# ------------------------------------------------------------
function Get-VoiceDspHostScript {
    Join-Path (Split-Path -Parent $PSCommandPath) 'VoiceDSP-Host.ps1'
}

function Start-VoiceDspHost {
    if (-not (Test-Path $script:VoiceDspTokensDir)) { New-Item -ItemType Directory -Path $script:VoiceDspTokensDir -Force | Out-Null }
    Remove-Item $script:VoiceDspStopFile -Force -ErrorAction SilentlyContinue

    $hostScript = Get-VoiceDspHostScript
    $mainsrc    = (Split-Path -Parent $PSCommandPath)

    $pwsh = if (Test-SuitePlatformWindows) { (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source }
            else { (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
    if (-not $pwsh) { return $false }

    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $hostScript, "-Root", $mainsrc)
    try {
        $p = Start-Process -FilePath $pwsh -ArgumentList $args -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 600
        if ($p -and -not $p.HasExited) {
            Set-Content -Path $script:VoiceDspPidFile -Value $p.Id -Encoding ASCII
            return $true
        }
        return $false
    } catch { return $false }
}

function Stop-VoiceDspHost {
    if (-not (Test-Path $script:VoiceDspTokensDir)) { New-Item -ItemType Directory -Path $script:VoiceDspTokensDir -Force | Out-Null }
    Set-Content -Path $script:VoiceDspStopFile -Value '1' -Encoding ASCII
    try {
        if (Test-Path $script:VoiceDspPidFile) {
            $hostPid = [int](Get-Content $script:VoiceDspPidFile -Raw)
            $proc = Get-Process -Id $hostPid -ErrorAction SilentlyContinue
            if ($proc) {
                # Graceful stop then hard kill as backstop.
                $deadline = [datetime]::UtcNow.AddSeconds(3)
                while ([datetime]::UtcNow -lt $deadline -and $proc) {
                    Start-Sleep -Milliseconds 200
                    $proc = Get-Process -Id $hostPid -ErrorAction SilentlyContinue
                }
                if ($proc) { Stop-Process -Id $hostPid -Force -ErrorAction SilentlyContinue }
            }
        }
    } catch { }
    Remove-Item $script:VoiceDspPidFile -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
# External noise-suppression engine (user-configured host)
# ------------------------------------------------------------
function Start-NoiseSuppressionExternal {
    <#
        Launches a user-configured external noise-suppression host (e.g. an
        RNNoise filter app or an EqualizerAPO session). Returns $true when a
        process was actually started. Original/no external registration is
        tracked so Stop-NoiseSuppressionExternal can end it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Engine,
        [string]$Args = ''
    )

    if (-not $Engine) { return $false }
    if (-not (Test-Path $Engine)) {
        Write-Log "External noise engine not found: $Engine" 'WARN'
        return $false
    }
    if (Test-NoiseSuppressionExternalActive) { return $true }

    $extPidFile = Join-Path $script:VoiceDspTokensDir 'external.pid'
    Remove-Item $extPidFile -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $script:VoiceDspTokensDir)) { New-Item -ItemType Directory -Path $script:VoiceDspTokensDir -Force | Out-Null }

    try {
        $argList = if ($Args) { $Args } else { @() }
        $p = Start-Process -FilePath $Engine -ArgumentList $argList -WindowStyle Hidden -PassThru -ErrorAction Stop
        if ($p -and -not $p.HasExited) {
            Set-Content -Path $extPidFile -Value $p.Id -Encoding ASCII
            Write-Log ("External noise engine started (PID {0})." -f $p.Id) 'OK'
            return $true
        }
        return $false
    } catch {
        Write-Log ("External noise engine failed to start: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Stop-NoiseSuppressionExternal {
    <# Stops the user-configured external noise engine (if one was started). #>
    [CmdletBinding()]
    param()
    $extPidFile = Join-Path $script:VoiceDspTokensDir 'external.pid'
    if (-not (Test-Path $extPidFile)) { return }
    try {
        $extPid = [int](Get-Content $extPidFile -Raw)
        Stop-Process -Id $extPid -Force -ErrorAction SilentlyContinue
        Write-Log ("External noise engine stopped (PID {0})." -f $extPid) 'OK'
    } catch { }
    Remove-Item $extPidFile -Force -ErrorAction SilentlyContinue
}

function Test-NoiseSuppressionExternalActive {
    $extPidFile = Join-Path $script:VoiceDspTokensDir 'external.pid'
    if (-not (Test-Path $extPidFile)) { return $false }
    try {
        $extPid = [int](Get-Content $extPidFile -Raw)
        return [bool](Get-Process -Id $extPid -ErrorAction SilentlyContinue)
    } catch { return $false }
}

Export-ModuleMember -Function Enable-VoiceNoiseSuppression, Disable-VoiceNoiseSuppression,
    Test-VoiceDspActive, Test-VoiceDspPlatform,
    Start-NoiseSuppressionExternal, Stop-NoiseSuppressionExternal, Test-NoiseSuppressionExternalActive
