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
#  Windows 10 (1809+) / 11 and later expose these via the
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
        [PreserveSig] int GetMixFormat(out IntPtr ppDeviceFormat);
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

    [Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient
    {
        [PreserveSig] int GetBuffer(out IntPtr ppData, out uint pNumFramesToRead, out int pdwFlags,
            IntPtr pu64DevicePosition, IntPtr pu64QPCPosition);
        [PreserveSig] int ReleaseBuffer(uint NumFramesRead);
        [PreserveSig] int GetNextPacketSize(out uint pNumFramesInNextPacket);
    }

    [Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioRenderClient
    {
        [PreserveSig] int GetBuffer(uint NumFramesRequested, out IntPtr ppData);
        [PreserveSig] int ReleaseBuffer(uint NumFramesWritten, int dwFlags);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct WAVEFORMATEX
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
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

        // Report which OS effects are exposed on the default comms capture
        // endpoint (no state change). Used to decide if a real-time software
        // fallback is needed when Deep Noise Suppression is absent (e.g. the
        // classic Windows 10 case).
        public static string AvailableEffects()
        {
            try
            {
                object enumerator = new MMDeviceEnumeratorComObject();
                IMMDeviceEnumerator devEnum = (IMMDeviceEnumerator)enumerator;
                IMMDevice device;
                int hr = devEnum.GetDefaultAudioEndpoint(eCapture, eCommunications, out device);
                if (hr != 0) { return "error:no-device"; }
                IntPtr actsite;
                try
                {
                    Guid iid = IID_IAudioClient;
                    hr = device.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out actsite);
                    if (hr != 0) { return "error:activate"; }
                }
                finally { if (device != null) Marshal.ReleaseComObject(device); if (devEnum != null) Marshal.ReleaseComObject(devEnum); }

                IAudioClient client = (IAudioClient)Marshal.GetObjectForIUnknown(actsite);
                object mgr; Guid iidM = IID_IAudioEffectsManager;
                int hrSvc = client.GetService(ref iidM, out mgr);
                if (hrSvc != 0 || mgr == null) { Marshal.Release(actsite); return "no-effects-manager"; }

                IAudioEffectsManager eMgr = (IAudioEffectsManager)mgr;
                IntPtr effPtr; uint count;
                int hrGet = eMgr.GetAudioEffects(out effPtr, out count);
                bool deep = false, ns = false, aec = false;
                if (hrGet == 0)
                {
                    try
                    {
                        for (uint i = 0; i < count; i++)
                        {
                            IntPtr slot = new IntPtr(effPtr.ToInt64() + (i * Marshal.SizeOf(typeof(AUDIO_EFFECT))));
                            AUDIO_EFFECT fx = (AUDIO_EFFECT)Marshal.PtrToStructure(slot, typeof(AUDIO_EFFECT));
                            if (fx.id == EFFECT_DEEP_NS) deep = true;
                            if (fx.id == EFFECT_NS)      ns   = true;
                            if (fx.id == EFFECT_AEC)     aec  = true;
                        }
                    }
                    finally { Marshal.FreeCoTaskMem(effPtr); }
                }
                Marshal.ReleaseComObject(mgr);
                client.Stop();
                Marshal.Release(actsite);
                return "deepNS=" + deep + ",ns=" + ns + ",aec=" + aec;
            }
            catch (Exception) { return "error"; }
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

    // ------------------------------------------------------------
    // Real-time software noise suppressor (Windows 10 fallback).
    //
    // Captures the default communications mic (shared mode), strips
    // steady + intermittent background noise (fans, traffic, distant
    // broadcasts/speech) with a spectral-subtraction filter plus a
    // voice-activity gate, and renders the cleaned stream to the
    // default audio output. Purely self-contained (no installs).
    //
    // Every failure is caught and reported as a status string so the
    // suite degrades gracefully instead of crashing.
    // ------------------------------------------------------------
    public static class RealTimeNoiseSuppressor
    {
        const int eRender = 0;
        const int eCapture = 1;
        const int eConsole = 0;
        const int eCommunications = 3;
        const int CLSCTX_ALL = 0x17;
        const int AUDCLNT_SHAREMODE_SHARED = 0;
        const int AUDCLNT_STREAMFLAGS_EVENTCALLBACK = 0x00040000;
        const int AUDCLNT_BUFFERFLAGS_SILENT = 0x2;
        const int WAVE_FORMAT_IEEE_FLOAT = 3;

        static readonly Guid IID_IAudioClient   = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
        static readonly Guid IID_IAudioCapture  = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
        static readonly Guid IID_IAudioRender   = new Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2");

        const int FFTSIZE = 512;   // 10.6 ms @ 48 kHz
        const int ADVANCE = 256;   // 50% overlap

        // Streaming state
        static volatile bool _running;
        static AutoResetEvent _captureEvent;
        static AutoResetEvent _renderEvent;
        static IntPtr _capClientPtr;
        static IntPtr _renClientPtr;
        static object _capRcw;      // keep IAudioClient RCW alive for the capture thread
        static object _renClientRcw;// keep IAudioClient RCW alive for the render thread
        static Thread _capThread;
        static Thread _renThread;

        // Capture metadata (set once at Start, read from the real mix format)
        static int _channels;
        static int _sampleRate;
        static bool _capFloat;       // capture mix format is IEEE float (else 16-bit PCM)

        // Interleaved capture -> mono rolling window for the DSP
        static float[] _monoIn;      // rolling buffer (raw mono samples)
        static int _monoCount;
        // Processed mono output ring, drained by the render thread
        static float[] _outRing;
        static int _outHead, _outTail;

        // DSP scratch / state
        static float[] _win;
        static float[] _tail;         // overlap-add carry (FFTSIZE)
        static float[] _noisePow;
        static float[] _re, _im, _pow;
        static double _aAggr;
        static float _noiseFloor;
        static int _frameStart;        // index into _monoIn where the active frame begins

        public static void Configure(int channels, int sampleRate, bool capFloat)
        {
            _channels = Math.Max(1, channels);
            _sampleRate = sampleRate > 0 ? sampleRate : 48000;
            _capFloat = capFloat;
        }

        static float Before(float[] a, int i) { return (i - 1 < 0) ? 0f : a[i - 1]; }

        public static string Start(double aggressiveness)
        {
            if (_running) { try { Stop(); } catch { } }
            // Keep the expensive FFT fixed at 512 samples, but allow a deeper
            // spectral subtraction pass for loud, intermittent background
            // speech and fans.  The soft floor preserves consonants.
            _aAggr = aggressiveness < 0.5 ? 0.5 : (aggressiveness > 2.0 ? 2.0 : aggressiveness);
            // Spectral floor: higher aggressiveness -> deeper suppression of
            // residual musical noise, still keeps low-level voice harmonics.
            _noiseFloor = _aAggr >= 1.55f ? 0.008f : (_aAggr >= 1.3f ? 0.02f : 0.06f);

            try
            {
                object enumObj = new MMDeviceEnumeratorComObject();
                IMMDeviceEnumerator devEnum = (IMMDeviceEnumerator)enumObj;

                // ---- capture (comms mic) ----
                IMMDevice capDev;
                int hr = devEnum.GetDefaultAudioEndpoint(eCapture, eCommunications, out capDev);
                if (hr != 0) return "error:cap-no-device";
                IntPtr capAct;
                Guid iidCap = IID_IAudioClient;
                hr = capDev.Activate(ref iidCap, CLSCTX_ALL, IntPtr.Zero, out capAct);
                if (hr != 0) return "error:cap-activate";
                IAudioClient capClient = (IAudioClient)Marshal.GetObjectForIUnknown(capAct);

                IntPtr mixPtr; int mhr = capClient.GetMixFormat(out mixPtr);
                if (mhr != 0) return "error:mixformat";
                WAVEFORMATEX wfx = (WAVEFORMATEX)Marshal.PtrToStructure(mixPtr, typeof(WAVEFORMATEX));
                int capCh = wfx.nChannels > 0 ? wfx.nChannels : 2;
                int capRate = (int)(wfx.nSamplesPerSec > 0 ? wfx.nSamplesPerSec : (uint)48000);
                Configure(capCh, capRate, wfx.wFormatTag == WAVE_FORMAT_IEEE_FLOAT);

                _captureEvent = new AutoResetEvent(false);
                hr = capClient.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                    (long)(50 * 10000), (long)(5 * 10000), IntPtr.Zero, IntPtr.Zero);
                if (hr != 0) return "error:cap-init:" + hr.ToString("X8");
                IntPtr capEvt = Win32.CreateEventW(IntPtr.Zero, false, false, null);
                if (capEvt == IntPtr.Zero) return "error:cap-event";
                capClient.SetEventHandle(capEvt);
                object capSvcObj;
                Guid iidCapSvc = IID_IAudioCapture;
                int capSvcHr = capClient.GetService(ref iidCapSvc, out capSvcObj);
                if (capSvcHr != 0 || capSvcObj == null) return "error:cap-service";
                IAudioCaptureClient capGrab = (IAudioCaptureClient)capSvcObj;

                // ---- render (default multimedia output) ----
                IMMDevice renDev;
                int rhr = devEnum.GetDefaultAudioEndpoint(eRender, eConsole, out renDev);
                if (rhr != 0) return "error:ren-no-device";
                IntPtr renAct;
                Guid iidRen = IID_IAudioClient;
                rhr = renDev.Activate(ref iidRen, CLSCTX_ALL, IntPtr.Zero, out renAct);
                if (rhr != 0) return "error:ren-activate";
                IAudioClient renClient = (IAudioClient)Marshal.GetObjectForIUnknown(renAct);

                IntPtr renMixPtr; mhr = renClient.GetMixFormat(out renMixPtr);
                int renCh = 2, renRate = capRate;
                if (mhr == 0)
                {
                    WAVEFORMATEX rwfx = (WAVEFORMATEX)Marshal.PtrToStructure(renMixPtr, typeof(WAVEFORMATEX));
                    renCh = rwfx.nChannels > 0 ? rwfx.nChannels : 2;
                    renRate = (int)(rwfx.nSamplesPerSec > 0 ? rwfx.nSamplesPerSec : (uint)capRate);
                }
                IntPtr fmt = Wav.Float32PCMFormat(renRate, renCh);
                _renderEvent = new AutoResetEvent(false);
                rhr = renClient.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                    (long)(50 * 10000), (long)(5 * 10000), fmt, IntPtr.Zero);
                if (rhr != 0)
                {
                    FormatFree(fmt);
                    fmt = Wav.Clone(renMixPtr);
                    rhr = renClient.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                        (long)(50 * 10000), (long)(5 * 10000), fmt, IntPtr.Zero);
                    if (rhr != 0) return "error:ren-init:" + rhr.ToString("X8");
                }
                FormatFree(fmt);
                IntPtr renEvt = Win32.CreateEventW(IntPtr.Zero, false, false, null);
                if (renEvt == IntPtr.Zero) return "error:ren-event";
                renClient.SetEventHandle(renEvt);
                object renSvcObj;
                Guid iidRenSvc = IID_IAudioRender;
                int renSvcHr = renClient.GetService(ref iidRenSvc, out renSvcObj);
                if (renSvcHr != 0 || renSvcObj == null) return "error:ren-service";
                IAudioRenderClient renGrab = (IAudioRenderClient)renSvcObj;

                _capClientPtr = capAct;
                _renClientPtr = renAct;
                _capRcw = capClient;
                _renClientRcw = renClient;
                _capThread = new Thread(new ThreadStart(() => CaptureLoop(capGrab)));
                _renThread = new Thread(new ThreadStart(() => RenderLoop(renClient, renGrab, renRate, renCh)));

                // Rolling buffers sized for ~0.5 s at the capture rate.
                _monoIn = new float[_sampleRate / 2];
                _monoCount = 0;
                _outRing = new float[_sampleRate];
                _outHead = _outTail = 0;
                _frameStart = 0;
                InitDsp();

                capClient.Start();
                renClient.Start();
                _running = true;
                _capThread.IsBackground = true;
                _renThread.IsBackground = true;
                _capThread.Start();
                _renThread.Start();

                return "running:realtime=1,rate=" + _sampleRate + ",ch=" + _channels;
            }
            catch (Exception ex) { try { Stop(); } catch { } return "error:" + ex.GetType().Name; }
        }

        static void FormatFree(IntPtr p) { if (p != IntPtr.Zero) { try { Marshal.FreeHGlobal(p); } catch { } } }

        static void InitDsp()
        {
            _win = new float[FFTSIZE];
            // Hann window (periodic variant)
            for (int i = 0; i < FFTSIZE; i++) _win[i] = (float)(0.5 - 0.5 * Math.Cos(2.0 * Math.PI * i / FFTSIZE));
            _tail = new float[FFTSIZE];
            _noisePow = new float[FFTSIZE / 2 + 1];
            _re = new float[FFTSIZE];
            _im = new float[FFTSIZE];
            _pow = new float[FFTSIZE / 2 + 1];
        }

        // Push a cooked mono sample to the output ring.
        static void PushOut(float v)
        {
            _outRing[_outTail] = v;
            _outTail = (_outTail + 1) % _outRing.Length;
            if (_outTail == _outHead) _outHead = (_outHead + 1) % _outRing.Length;
        }
        static float PopOut()
        {
            if (_outHead == _outTail) return 0f;
            float v = _outRing[_outHead];
            _outHead = (_outHead + 1) % _outRing.Length;
            return v;
        }

        // Feed one raw mono sample into the framing/DSP pipeline.
        // Frames the stream with 50% overlap (ADVANCE = FFTSIZE/2) so adjacent
        // Hann windows sum to unity and there is no amplitude modulation.
        static void FeedSample(float s)
        {
            _monoIn[_monoCount++] = s;
            // Compact the rolling buffer so it never runs off the end.
            if (_monoCount == _monoIn.Length)
            {
                Array.Copy(_monoIn, ADVANCE, _monoIn, 0, _monoCount - ADVANCE);
                _monoCount -= ADVANCE;
                _frameStart -= ADVANCE;
                if (_frameStart < 0) _frameStart = 0;
            }
            if (_monoCount - _frameStart >= FFTSIZE)
            {
                for (int i = 0; i < FFTSIZE; i++)
                {
                    _re[i] = _monoIn[_frameStart + i] * _win[i];
                    _im[i] = 0f;
                }
                ProcessFrame();
                _frameStart += ADVANCE;
            }
        }

        static void ProcessFrame()
        {
            // 1) power spectrum of the windowed frame
            Fft(_re, _im, false);
            for (int i = 0; i <= FFTSIZE / 2; i++)
                _pow[i] = _re[i] * _re[i] + _im[i] * _im[i];
            // 2) adapt the per-bin noise estimate (slow; frozen while speech)
            float framePow = 0f;
            for (int i = 0; i <= 32; i++) framePow += _pow[i];
            bool speech = framePow > _noiseFrameEnergy * 1.6f;
            for (int i = 0; i <= FFTSIZE / 2; i++)
            {
                float p = _pow[i];
                float np = _noisePow[i];
                if (speech) { _noisePow[i] = np + (p - np) * 0.01f; }        // hold while voice
                else        { _noisePow[i] = (p < np) ? (np + (p - np) * 0.25f) : (np + (p - np) * 0.035f); }
            }
            _noiseFrameEnergy = framePow;
            // 3) oversubtractive spectral gating with a soft floor
            for (int i = 0; i <= FFTSIZE / 2; i++)
            {
                float p = _pow[i];
                float np = _noisePow[i];
                float gain = (p - np * (float)_aAggr) / (p + 1e-6f);
                if (gain < _noiseFloor) gain = _noiseFloor;
                if (gain > 1f) gain = 1f;
                _re[i] *= gain; _im[i] *= gain;
                if (i > 0 && i < FFTSIZE / 2) { _re[FFTSIZE - i] *= gain; _im[FFTSIZE - i] *= gain; }
            }
            // 4) IFFT + overlap-add (50% overlap)
            Fft(_re, _im, true);
            for (int i = 0; i < FFTSIZE; i++)
            {
                float v = _re[i] / FFTSIZE;
                float merged = v + _tail[i];
                _tail[i] = v;
                if (i < ADVANCE) PushOut(merged);
            }
        }
        static float _noiseFrameEnergy;

        // Capture thread: read packets -> decorrelate to mono -> FeedSample.
        static void CaptureLoop(IAudioCaptureClient cap)
        {
            try
            {
                while (_running)
                {
                    _captureEvent.WaitOne(200);
                    uint next;
                    while (_running && cap.GetNextPacketSize(out next) == 0 && next > 0)
                    {
                        IntPtr data; uint frames; int flags;
                        if (cap.GetBuffer(out data, out frames, out flags, IntPtr.Zero, IntPtr.Zero) != 0) break;
                        bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
                        FeedRaw(data, frames, silent);
                        cap.ReleaseBuffer(frames);
                    }
                }
            }
            catch { }
        }

        static void FeedRaw(IntPtr data, uint frames, bool silent)
        {
            long base_ = data.ToInt64();
            int ch = _channels;
            if (_capFloat)
            {
                for (uint f = 0; f < frames; f++)
                {
                    float s = 0f;
                    for (int c = 0; c < ch; c++)
                        s += Marshal.PtrToStructure<float>(new IntPtr(base_ + ((long)(f * ch + c) * 4)));
                    s /= ch;
                    FeedSample(silent ? 0f : s);
                }
            }
            else
            {
                for (uint f = 0; f < frames; f++)
                {
                    float s = 0f;
                    for (int c = 0; c < ch; c++)
                    {
                        short v = Marshal.PtrToStructure<short>(new IntPtr(base_ + ((long)(f * ch + c) * 2)));
                        s += v / 32768f;
                    }
                    s /= ch;
                    FeedSample(silent ? 0f : s);
                }
            }
        }

        // Render thread: drain cleaned mono and upmix to float32 render buffer.
        static void RenderLoop(IAudioClient renClient, IAudioRenderClient ren, int rate, int ch)
        {
            try
            {
                while (_running)
                {
                    _renderEvent.WaitOne(200);
                    uint pad;
                    if (renClient.GetCurrentPadding(out pad) != 0) continue;
                    uint bufFrames;
                    renClient.GetBufferSize(out bufFrames);
                    uint available = bufFrames - pad;
                    if (available < (uint)(rate / 100)) continue;
                    IntPtr ptr;
                    if (ren.GetBuffer(available, out ptr) != 0) continue;
                    long b = ptr.ToInt64();
                    for (uint f = 0; f < available; f++)
                    {
                        float v = PopOut();
                        for (int c = 0; c < ch; c++)
                            Marshal.WriteInt32(new IntPtr(b + ((long)(f * ch + c) * 4)), BitConverter.ToInt32(BitConverter.GetBytes(v), 0));
                    }
                    ren.ReleaseBuffer(available, 0);
                }
            }
            catch { }
        }

        public static string Stop()
        {
            _running = false;
            try { if (_capThread != null) _capThread.Join(300); } catch { }
            try { if (_renThread != null) _renThread.Join(300); } catch { }
            try
            {
                if (_capClientPtr != IntPtr.Zero)
                {
                    IAudioClient c = (IAudioClient)Marshal.GetObjectForIUnknown(_capClientPtr);
                    try { c.Stop(); } catch { }
                    Marshal.Release(_capClientPtr); _capClientPtr = IntPtr.Zero;
                }
            } catch { }
            try
            {
                if (_renClientPtr != IntPtr.Zero)
                {
                    IAudioClient c = (IAudioClient)Marshal.GetObjectForIUnknown(_renClientPtr);
                    try { c.Stop(); } catch { }
                    Marshal.Release(_renClientPtr); _renClientPtr = IntPtr.Zero;
                }
            } catch { }
            _capRcw = null;
            _renClientRcw = null;
            return "stopped";
        }

        public static bool IsRunningSimple() { return _running; }

        // ---- in-place radix-2 complex FFT ----
        static void Fft(float[] re, float[] im, bool inverse)
        {
            int n = re.Length;
            for (int i = 1, j = 0; i < n; i++)
            {
                int bit = n >> 1;
                for (; (j & bit) != 0; bit >>= 1) j ^= bit;
                j ^= bit;
                if (i < j)
                {
                    float t = re[i]; re[i] = re[j]; re[j] = t;
                    t = im[i]; im[i] = im[j]; im[j] = t;
                }
            }
            for (int len = 2; len <= n; len <<= 1)
            {
                double ang = 2.0 * Math.PI / len * (inverse ? 1 : -1);
                float wr = (float)Math.Cos(ang), wi = (float)Math.Sin(ang);
                for (int i = 0; i < n; i += len)
                {
                    float cur_r = 1f, cur_i = 0f;
                    for (int k = 0; k < len / 2; k++)
                    {
                        int a = i + k, b = i + k + len / 2;
                        float tr = cur_r * re[b] - cur_i * im[b];
                        float ti = cur_r * im[b] + cur_i * re[b];
                        re[b] = re[a] - tr; im[b] = im[a] - ti;
                        re[a] += tr; im[a] += ti;
                        float ncr = cur_r * wr - cur_i * wi;
                        cur_i = cur_r * wi + cur_i * wr;
                        cur_r = ncr;
                    }
                }
            }
        }
    }

    static class Win32
    {
        [DllImport("kernel32.dll")]
        public static extern IntPtr CreateEventW(IntPtr lpEventAttributes, bool bManualReset, bool bInitialState, string lpName);
        [DllImport("kernel32.dll")]
        public static extern bool CloseHandle(IntPtr hObject);
    }

    static class Wav
    {
        public static IntPtr Float32PCMFormat(int rate, int channels)
        {
            IntPtr p = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(WAVEFORMATEX)));
            WAVEFORMATEX w = new WAVEFORMATEX();
            w.wFormatTag = 3;                 // IEEE_FLOAT
            w.nChannels = (ushort)channels;
            w.nSamplesPerSec = (uint)rate;
            w.wBitsPerSample = 32;
            w.nBlockAlign = (ushort)(channels * 4);
            w.nAvgBytesPerSec = (uint)(rate * channels * 4);
            w.cbSize = 0;
            Marshal.StructureToPtr(w, p, false);
            return p;
        }
        public static IntPtr Clone(IntPtr src)
        {
            int sz = Marshal.SizeOf(typeof(WAVEFORMATEX));
            IntPtr p = Marshal.AllocHGlobal(sz);
            for (int i = 0; i < sz; i++) Marshal.WriteByte(p, i, Marshal.ReadByte(src, i));
            return p;
        }
    }
}
'@

function Test-VoiceDspPlatform {
    <#
        Whether the WASAPI IAudioEffectsManager DSP pipeline may be available,
        and therefore worth ATTEMPTING on this platform.

        The IAudioEffectsManager API (and the classic Noise Suppression and
        Acoustic Echo Cancellation effects behind ksmedia GUIDs) is present on
        ALL modern Windows editions - 10 (build 1809+), 11 and later - not just
        Windows 11. Only the very old / broken pre-1809 builds lack it, so we
        treat everything 1809+ as "try it" and let the live capture query decide
        definitively (Enable returns 'no-effects-manager' when the endpoint has
        nothing to offer). This no longer hard-blocks Windows 10.
    #>
    if (-not (Test-SuitePlatformWindows)) { return $false }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ([int]$os.BuildNumber -lt 17763) { return $false }   # pre-1809 (RS5): no effects manager
        return $true
    } catch {
        # Windows PowerShell 5.1 only ever runs on Windows; treat a failed probe
        # as "try it" so the positive path decides rather than a hard block.
        return $true
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
    param([double]$Aggressiveness = 1.55)

    if (-not (Test-VoiceDspPlatform)) {
        Write-Log 'Mic DSP: not supported on this Windows build (needs Windows 10 1809+). Falling back to MMCSS priority only.' 'WARN'
        return $false
    }

    # A DSP engine instance is already active -> nothing more to do.
    if (Test-VoiceDspActive) { return $true }

    try {
        Ensure-VoiceDspEngine
        # The DSP stays engaged only while a capture stream is held open, so we
        # spawn a hidden host process that owns the stream until told to stop.
        $launched = Start-VoiceDspHost -Aggressiveness $Aggressiveness
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
    param([double]$Aggressiveness = 1.55)
    if (-not (Test-Path $script:VoiceDspTokensDir)) { New-Item -ItemType Directory -Path $script:VoiceDspTokensDir -Force | Out-Null }
    Remove-Item $script:VoiceDspStopFile -Force -ErrorAction SilentlyContinue

    $hostScript = Get-VoiceDspHostScript
    $mainsrc    = (Split-Path -Parent $PSCommandPath)

    $pwsh = if (Test-SuitePlatformWindows) { (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source }
            else { (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
    if (-not $pwsh) { return $false }

    $safeAggressiveness = [Math]::Max(0.5, [Math]::Min(2.0, $Aggressiveness))
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $hostScript,
              "-Root", $mainsrc, '-Aggressiveness', "$safeAggressiveness")
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

# ------------------------------------------------------------
# Real-time software noise filter (Windows 10 fallback when the
# OS has no Deep Noise Suppression). Purely self-contained; no
# installs. Runs in the DSP host process.
# ------------------------------------------------------------
function Test-VoiceDeepNSPresent {
    <#
        False when the OS exposes no Deep Noise Suppression on the default
        comms mic (the common Windows 10 case) - meaning the weak classic NS
        alone cannot remove loud/intermittent background noise, and the
        real-time software filter is needed. Returns $true when deep NS is
        present. Never throws.
    #>
    try {
        Ensure-VoiceDspEngine
        $info = [SuiteVoice.MicNoiseSuppression]::AvailableEffects()
        return ($info -match 'deepNS=True')
    } catch { return $false }
}

function Start-VoiceRealTimeFilter {
    <#
        Starts the embedded real-time spectral noise suppressor. Returns a
        status string; 'running:...' indicates success.         Aggressive: higher strips more background (0.5 low .. 2.0 max).
        Never throws.
    #>
    [CmdletBinding()]
    param([double]$Aggressive = 1.55)
    try {
        Ensure-VoiceDspEngine
        return [SuiteVoice.RealTimeNoiseSuppressor]::Start($Aggressive)
    } catch {
        return ("error:{0}" -f $_.Exception.GetType().Name)
    }
}

function Stop-VoiceRealTimeFilter {
    [CmdletBinding()]
    param()
    try {
        Ensure-VoiceDspEngine
        [void][SuiteVoice.RealTimeNoiseSuppressor]::Stop()
    } catch { }
}

Export-ModuleMember -Function Enable-VoiceNoiseSuppression, Disable-VoiceNoiseSuppression,
    Test-VoiceDspActive, Test-VoiceDspPlatform,
    Start-NoiseSuppressionExternal, Stop-NoiseSuppressionExternal, Test-NoiseSuppressionExternalActive,
    Test-VoiceDeepNSPresent, Start-VoiceRealTimeFilter, Stop-VoiceRealTimeFilter
