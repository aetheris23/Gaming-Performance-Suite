# ============================================================
#  MicEnhance.psm1 - Microphone enhancement module
#
#  Real-time audio processing requires native code with deterministic
#  latency (sub-10ms) which PowerShell cannot provide. This module
#  compiles a C# DSP pipeline via Add-Type that captures microphone
#  audio via WASAPI, processes it through a DSP chain (gain, noise
#  gate, spectral noise suppression, compressor, limiter, optional
#  AGC), and renders the enhanced signal to an output endpoint.
#
#  Two operating modes:
#    1. Companion tool bridge (recommended): launches an external
#       audio tool (e.g. RNNoise-based) that handles DSP and exposes
#       a virtual microphone. See Invoke-MicEnhanceTool / Stop-MicEnhanceTool.
#    2. Built-in DSP pipeline: native C# processing within PowerShell.
#       Use Start-MicEnhancement / Stop-MicEnhancement when no companion
#       tool is configured.
#
#  VIRTUAL MICROPHONE REQUIREMENT (hard):
#    Windows has no built-in virtual microphone that a user-mode app
#    can create without a kernel driver. To route the enhanced signal
#    to communication apps/games, install a virtual audio driver
#    (VB-Cable, Voicemeeter, or similar WDM/KS driver), set the DSP
#    render output to that virtual cable, and set the app/game input
#    device to the virtual cable. Without a virtual cable, the module
#    can still capture + process + monitor (playback to default render
#    device) for testing.
# ============================================================

Set-StrictMode -Version Latest

# Minimal Write-Log fallback for standalone use (when Common.psm1 isn't loaded).
# When imported via Main.ps1, Common.psm1's full Write-Log takes precedence.
if (-not (Test-Path function:\Write-Log)) {
    function Write-Log {
        param([string]$Message, [string]$Level = 'INFO')
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $color = switch ($Level) {
            'INFO'  { 'Gray'  }
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red'   }
            'OK'    { 'Green'  }
            default { 'Gray'   }
        }
        Write-Host "[$stamp][$Level] $Message" -ForegroundColor $color
    }
}

# ------------------------------------------------------------
# Native types: WASAPI capture/render + real-time DSP pipeline.
# Compiled once on module import, reused for the session.
# ------------------------------------------------------------
function Add-NativeMicTypes {
    if ('NativeMicDsp' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Collections.Concurrent;
using System.Collections.Generic;

// ============================================================
// WASAPI / MMDevice COM interop
// ============================================================

[ComImport]
[Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
class MMDeviceEnumerator { }

[ComImport]
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator
{
    int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    int GetDevice(string id, out IMMDevice device);
    int RegisterEndpointNotificationCallback(IntPtr client);
    int UnregisterEndpointNotificationCallback(IntPtr client);
}

[ComImport]
[Guid("0BD7A1BE-7CAA-4DF6-93CB-86BBAD557AF4")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceCollection
{
    int GetCount(out int count);
    int Item(int index, out IMMDevice device);
}

[ComImport]
[Guid("D666063F-1587-4E43-81F1-B948E807363F")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice
{
    int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, out IntPtr clientPtr);
    int OpenPropertyStore(int stgm, out IntPtr props);
    int GetId(out string id);
    int GetState(out int state);
}

[ComImport]
[Guid("1CB9AD4C-DBFA-4c34-B147-1E1E9B00B71A")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioClient
{
    int Initialize(int shareMode, int streamFlags, long hnsBufferDuration, long hnsPeriodicity, ref WAVEFORMATEX format, IntPtr audioSessionGuid);
    int GetBufferSize(out int numFrames);
    int GetStreamFormat(out IntPtr format);
    int GetCurrentPadding(out int numFrames);
    int IsFormatSupported(int shareMode, ref WAVEFORMATEX format, out IntPtr closest);
    int GetMixFormat(out IntPtr format);
    int GetDevicePeriod(out int defaultPeriod, out int minimumPeriod);
    int Start();
    int Stop();
    int Reset();
    int GetEventHandle(out IntPtr eventHandle);
    int GetService(ref Guid iid, out IntPtr service);
}

[ComImport]
[Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD917")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioCaptureClient
{
    int GetBuffer(out IntPtr data, out int numFrames, out int flags, out long timestamp, out long counter);
    int GetBufferSize(out int numFrames);
    int ReleaseBuffer(int numFrames);
    int GetNextPacketSize(out int numFrames);
}

[ComImport]
[Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioRenderClient
{
    int GetBuffer(int numFrames, out IntPtr data);
    int ReleaseBuffer(int numFrames, int flags);
}

[StructLayout(LayoutKind.Sequential)]
struct WAVEFORMATEX
{
    public short wFormatTag;
    public short nChannels;
    public int nSamplesPerSec;
    public int nAvgBytesPerSec;
    public short nBlockAlign;
    public short wBitsPerSample;
    public short cbSize;
}

// ============================================================
// Constants
// ============================================================
internal static class WasapiConsts
{
    public const int eRender = 0;
    public const int eCapture = 1;
    public const int eAll = 2;
    public const int eConsole = 0;
    public const int eMultimedia = 1;
    public const int eCommunications = 2;
    public const int AUDCLNT_SHAREMODE_SHARED = 0;
    public const int WAVE_FORMAT_IEEE_FLOAT = 3;
    public const int CLSCTX_ALL = 23;
    public const int S_OK = 0;
}

// ============================================================
// Minimal math helper (avoid System.Numerics dependency)
// ============================================================
public static class Mathf
{
    public static float Pow(float x, float y) => (float)Math.Pow(x, y);
    public static float Sqrt(float x) => (float)Math.Sqrt(x);
    public static float Lerp(float a, float b, float t) => a + (b - a) * t;
    public static float Clamp(float v, float min, float max) => v < min ? min : (v > max ? max : v);
    public static float Abs(float v) => v < 0 ? -v : v;
}

// ============================================================
// Public device enumeration helper (PowerShell-callable).
// MMDeviceEnumerator and COM interfaces are internal to the
// assembly; this is the public surface for device listing.
// ============================================================
public class DeviceInfo
{
    public string Id { get; set; }
    public string Name { get; set; }
    public int State { get; set; }
    public bool IsCapture { get; set; }
}

public static class NativeAudioDevice
{
    public static DeviceInfo[] EnumerateDevices(bool capture)
    {
        var results = new List<DeviceInfo>();
        try
        {
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            int dataFlow = capture ? 1 : 0; // eCapture=1, eRender=0
            IMMDeviceCollection collection;
            enumerator.EnumAudioEndpoints(dataFlow, 1, out collection); // stateMask=1 = active
            collection.GetCount(out int count);
            for (int i = 0; i < count; i++)
            {
                IMMDevice device;
                collection.Item(i, out device);
                device.GetId(out string id);
                device.GetState(out int state);
                results.Add(new DeviceInfo
                {
                    Id = id,
                    Name = id,
                    State = state,
                    IsCapture = capture
                });
            }
        }
        catch { /* enumeration failure returns empty list */ }
        return results.ToArray();
    }
}

// ============================================================
// Real-time DSP pipeline
// Chain: gain -> noise gate -> spectral suppression -> compressor -> limiter -> AGC
// ============================================================
public class NativeMicDsp
{
    public float GainDb { get; set; } = 0f;
    public bool NoiseGateEnabled { get; set; } = true;
    public float NoiseGateThresholdDb { get; set; } = -40f;
    public float NoiseGateFloorDb { get; set; } = -60f;
    public bool NoiseSuppressionEnabled { get; set; } = true;
    public float NoiseSuppressionStrength { get; set; } = 0.5f;
    public bool CompressorEnabled { get; set; } = true;
    public float CompressorThresholdDb { get; set; } = -20f;
    public float CompressorRatio { get; set; } = 4f;
    public bool LimiterEnabled { get; set; } = true;
    public float LimiterCeilingDb { get; set; } = -3f;
    public bool AgcEnabled { get; set; } = false;
    public float AgcTargetDb { get; set; } = -18f;
    public float AgcRate { get; set; } = 0.01f;

    private int sampleRate = 48000;
    private int frameSize;
    private int fftSize;

    private float gateEnvelope = 0f;
    private const float GateAttack = 0.2f;
    private const float GateRelease = 0.005f;

    private float compEnvelope = 0f;
    private const float CompAttack = 0.02f;
    private const float CompRelease = 0.1f;

    private float agcGain = 1f;

    private float[] fftReal;
    private float[] fftImag;
    private float[] noiseSpectrum;
    private int noiseCount;
    private bool noiseEstimated;

    public NativeMicDsp(int sampleRate, int frameSize)
    {
        this.sampleRate = sampleRate;
        this.frameSize = frameSize;
        int fftSize = 1;
        while (fftSize < frameSize * 2) fftSize <<= 1;
        this.fftSize = fftSize;
        this.fftReal = new float[fftSize];
        this.fftImag = new float[fftSize];
        this.noiseSpectrum = new float[fftSize / 2 + 1];
    }

    public void ProcessBlock(float[] samples, int count)
    {
        // 1. Pre-amp gain
        float gainLinear = Mathf.Pow(10f, GainDb / 20f);
        for (int i = 0; i < count; i++) samples[i] *= gainLinear;

        // 2. Noise gate (RMS-based envelope)
        if (NoiseGateEnabled)
        {
            float rms = 0f;
            for (int i = 0; i < count; i++) rms += samples[i] * samples[i];
            rms = Mathf.Sqrt(rms / count);
            float thresholdLinear = Mathf.Pow(10f, NoiseGateThresholdDb / 20f);
            float floorLinear = Mathf.Pow(10f, NoiseGateFloorDb / 20f);
            float target = rms > thresholdLinear ? 1f : floorLinear;
            gateEnvelope = Mathf.Lerp(gateEnvelope, target, rms > thresholdLinear ? GateAttack : GateRelease);
            for (int i = 0; i < count; i++) samples[i] *= gateEnvelope;
        }

        // 3. Spectral noise suppression
        if (NoiseSuppressionEnabled && count > 0)
        {
            ApplySpectralSuppression(samples, count);
        }

        // 4. Compressor
        if (CompressorEnabled)
        {
            float thresholdLinear = Mathf.Pow(10f, CompressorThresholdDb / 20f);
            for (int i = 0; i < count; i++)
            {
                float abs = Mathf.Abs(samples[i]);
                if (abs > thresholdLinear)
                {
                    float compressed = thresholdLinear * Mathf.Pow(abs / thresholdLinear, 1f / CompressorRatio);
                    float ratio = compressed / abs;
                    compEnvelope = Mathf.Lerp(compEnvelope, ratio, CompAttack);
                    samples[i] *= compEnvelope;
                }
                else
                {
                    compEnvelope = Mathf.Lerp(compEnvelope, 1f, CompRelease);
                    samples[i] *= compEnvelope;
                }
            }
        }

        // 5. Limiter (clipping protection)
        if (LimiterEnabled)
        {
            float ceilingLinear = Mathf.Pow(10f, LimiterCeilingDb / 20f);
            for (int i = 0; i < count; i++)
            {
                if (samples[i] > ceilingLinear) samples[i] = ceilingLinear;
                if (samples[i] < -ceilingLinear) samples[i] = -ceilingLinear;
            }
        }

        // 6. AGC (automatic gain control)
        if (AgcEnabled)
        {
            float rms = 0f;
            for (int i = 0; i < count; i++) rms += samples[i] * samples[i];
            rms = Mathf.Sqrt(rms / count);
            float targetLinear = Mathf.Pow(10f, AgcTargetDb / 20f);
            if (rms > 0.0001f)
            {
                float needed = targetLinear / rms;
                agcGain = Mathf.Lerp(agcGain, needed, AgcRate);
                agcGain = Mathf.Clamp(agcGain, 0.1f, 10f);
            }
            for (int i = 0; i < count; i++) samples[i] *= agcGain;
        }

        // Final safety clip
        for (int i = 0; i < count; i++)
        {
            if (samples[i] > 1f) samples[i] = 1f;
            if (samples[i] < -1f) samples[i] = -1f;
        }
    }

    private void ApplySpectralSuppression(float[] samples, int count)
    {
        for (int i = 0; i < fftSize; i++) fftReal[i] = i < count ? samples[i] : 0f;
        for (int i = 0; i < fftSize; i++) fftImag[i] = 0f;

        Fft(fftReal, fftImag, fftSize, false);

        int half = fftSize / 2;
        float[] mag = new float[half + 1];
        for (int i = 0; i <= half; i++)
        {
            float r = fftReal[i];
            float im = fftImag[i];
            mag[i] = Mathf.Sqrt(r * r + im * im);
        }

        float frameEnergy = 0f;
        for (int i = 0; i < count; i++) frameEnergy += samples[i] * samples[i];
        frameEnergy /= count;

        if (!noiseEstimated || frameEnergy < 0.001f)
        {
            for (int i = 0; i <= half; i++)
            {
                noiseSpectrum[i] = noiseCount > 0
                    ? (noiseSpectrum[i] * noiseCount + mag[i]) / (noiseCount + 1)
                    : mag[i];
            }
            noiseCount++;
            if (noiseCount >= 20) noiseEstimated = true;
        }

        float strength = NoiseSuppressionStrength;
        for (int i = 0; i <= half; i++)
        {
            float noiseMag = noiseEstimated ? noiseSpectrum[i] * 0.5f : 0f;
            float suppressed = mag[i] - strength * noiseMag;
            if (suppressed < 0f) suppressed = 0f;
            mag[i] = suppressed;
        }

        for (int i = 0; i <= half && i < fftSize; i++)
        {
            float r = fftReal[i];
            float im = fftImag[i];
            float oldMag = Mathf.Sqrt(r * r + im * im);
            float scale = oldMag > 0.0001f ? mag[i] / oldMag : 0f;
            fftReal[i] = r * scale;
            fftImag[i] = im * scale;
        }

        Fft(fftReal, fftImag, fftSize, true);

        float scaleFactor = 1f / fftSize;
        for (int i = 0; i < count; i++)
        {
            samples[i] = fftReal[i] * scaleFactor;
        }
    }

    private static void Fft(float[] real, float[] imag, int n, bool inverse)
    {
        int j = 0;
        for (int i = 0; i < n; i++)
        {
            if (i < j)
            {
                float tr = real[i]; real[i] = real[j]; real[j] = tr;
                float ti = imag[i]; imag[i] = imag[j]; imag[j] = ti;
            }
            int m = n >> 1;
            while (m >= 1 && j >= m)
            {
                j -= m;
                m >>= 1;
            }
            j += m;
        }

        for (int len = 2; len <= n; len <<= 1)
        {
            double ang = -2 * Math.PI / len * (inverse ? -1 : 1);
            float wlenReal = (float)Math.Cos(ang);
            float wlenImag = (float)Math.Sin(ang);
            for (int i = 0; i < n; i += len)
            {
                float wReal = 1f, wImag = 0f;
                for (int k = 0; k < len / 2; k++)
                {
                    int i1 = i + k;
                    int i2 = i1 + len / 2;
                    float uReal = real[i1];
                    float uImag = imag[i1];
                    float vReal = real[i2] * wReal - imag[i2] * wImag;
                    float vImag = real[i2] * wImag + imag[i2] * wReal;
                    real[i1] = uReal + vReal;
                    imag[i1] = uImag + vImag;
                    real[i2] = uReal - vReal;
                    imag[i2] = uImag - vImag;
                    float nextWReal = wReal * wlenReal - wImag * wlenImag;
                    float nextWImag = wReal * wlenImag + wImag * wlenReal;
                    wReal = nextWReal;
                    wImag = nextWImag;
                }
            }
        }

        if (inverse)
        {
            for (int i = 0; i < n; i++)
            {
                real[i] /= n;
                imag[i] /= n;
            }
        }
    }
}

// ============================================================
// WASAPI audio capture
// ============================================================
public class NativeAudioCapture : IDisposable
{
    private IMMDeviceEnumerator enumerator;
    private IMMDevice device;
    private IAudioClient audioClient;
    private IAudioCaptureClient captureClient;
    private Thread captureThread;
    private ManualResetEvent stopEvent;
    private bool running;
    private WAVEFORMATEX waveFormat;
    private int sampleRate;
    private int frameSize;
    private Action<float[], int> callback;

    public bool IsRunning => running;

    public bool Start(string deviceId, Action<float[], int> callback, int desiredSampleRate = 48000, int desiredFrameSize = 480)
    {
        if (running) return false;
        this.callback = callback;
        stopEvent = new ManualResetEvent(false);
        running = true;

        try
        {
            enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();

            IMMDevice targetDevice = null;
            if (!string.IsNullOrEmpty(deviceId))
            {
                enumerator.GetDevice(deviceId, out targetDevice);
            }
            else
            {
                enumerator.GetDefaultAudioEndpoint(WasapiConsts.eCapture, WasapiConsts.eCommunications, out targetDevice);
            }
            if (targetDevice == null)
            {
                enumerator.GetDefaultAudioEndpoint(WasapiConsts.eCapture, WasapiConsts.eConsole, out targetDevice);
            }
            device = targetDevice;

            Guid iidAudioClient = new Guid("1CB9AD4C-DBFA-4c34-B147-1E1E9B00B71A");
            IntPtr clientPtr;
            int hr = device.Activate(ref iidAudioClient, WasapiConsts.CLSCTX_ALL, IntPtr.Zero, out clientPtr);
            if (hr != WasapiConsts.S_OK) throw new Exception($"IAudioClient Activate failed: 0x{hr:X8}");
            audioClient = (IAudioClient)Marshal.GetTypedObjectForIUnknown(clientPtr, typeof(IAudioClient));

            IntPtr mixFormatPtr;
            audioClient.GetMixFormat(out mixFormatPtr);
            waveFormat = (WAVEFORMATEX)Marshal.PtrToStructure(mixFormatPtr, typeof(WAVEFORMATEX));
            sampleRate = waveFormat.nSamplesPerSec;

            waveFormat.wFormatTag = WasapiConsts.WAVE_FORMAT_IEEE_FLOAT;
            waveFormat.wBitsPerSample = 32;
            waveFormat.nBlockAlign = (short)(waveFormat.nChannels * 4);
            waveFormat.nAvgBytesPerSec = waveFormat.nSamplesPerSec * waveFormat.nBlockAlign;
            waveFormat.cbSize = 0;

            long hnsDuration = (long)(desiredFrameSize * 10000000.0 / sampleRate);
            hr = audioClient.Initialize(WasapiConsts.AUDCLNT_SHAREMODE_SHARED, 0, hnsDuration, hnsDuration, ref waveFormat, IntPtr.Zero);
            if (hr != WasapiConsts.S_OK) throw new Exception($"IAudioClient Initialize failed: 0x{hr:X8}");

            audioClient.GetBufferSize(out int bufferSize);
            frameSize = bufferSize;

            Guid iidCapture = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD917");
            IntPtr capturePtr;
            audioClient.GetService(ref iidCapture, out capturePtr);
            captureClient = (IAudioCaptureClient)Marshal.GetTypedObjectForIUnknown(capturePtr, typeof(IAudioCaptureClient));

            audioClient.Start();

            captureThread = new Thread(CaptureLoop) { IsBackground = true };
            captureThread.Start();

            return true;
        }
        catch (Exception ex)
        {
            Dispose();
            throw new Exception("NativeAudioCapture.Start failed: " + ex.Message, ex);
        }
    }

    private void CaptureLoop()
    {
        while (running && stopEvent.WaitOne(0) == false)
        {
            try
            {
                audioClient.GetCurrentPadding(out int padding);
                int bufferSize;
                audioClient.GetBufferSize(out bufferSize);
                int available = bufferSize - padding;
                if (available <= 0) { Thread.Sleep(1); continue; }

                int toRead = Math.Min(available, frameSize);
                IntPtr dataPtr;
                int frames;
                int flags;
                long timestamp, counter;
                int hr = captureClient.GetBuffer(out dataPtr, out frames, out flags, out timestamp, out counter);
                if (hr != WasapiConsts.S_OK) { Thread.Sleep(1); continue; }

                if (frames > 0 && dataPtr != IntPtr.Zero)
                {
                    int ch = waveFormat.nChannels;
                    float[] samples = new float[frames * ch];
                    Marshal.Copy(dataPtr, samples, 0, samples.Length);
                    callback(samples, samples.Length);
                }

                captureClient.ReleaseBuffer(frames);
            }
            catch
            {
                Thread.Sleep(5);
            }
        }
    }

    public void Stop()
    {
        if (!running) return;
        running = false;
        stopEvent.Set();
        try { captureThread?.Join(1000); } catch { }
        try { audioClient?.Stop(); } catch { }
        Dispose();
    }

    public void Dispose()
    {
        running = false;
        stopEvent?.Dispose();
        captureClient = null;
        audioClient = null;
        device = null;
        enumerator = null;
    }
}

// ============================================================
// WASAPI audio render
// ============================================================
public class NativeAudioRender : IDisposable
{
    private IMMDeviceEnumerator enumerator;
    private IMMDevice device;
    private IAudioClient audioClient;
    private IAudioRenderClient renderClient;
    private Thread renderThread;
    private ManualResetEvent stopEvent;
    private bool running;
    private WAVEFORMATEX waveFormat;
    private int sampleRate;
    private int frameSize;
    private ConcurrentQueue<float[]> sampleQueue = new ConcurrentQueue<float[]>();

    public bool IsRunning => running;

    public bool Start(string deviceId, int desiredSampleRate = 48000, int desiredFrameSize = 480)
    {
        if (running) return false;
        stopEvent = new ManualResetEvent(false);
        running = true;

        try
        {
            enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();

            IMMDevice targetDevice = null;
            if (!string.IsNullOrEmpty(deviceId))
            {
                enumerator.GetDevice(deviceId, out targetDevice);
            }
            else
            {
                enumerator.GetDefaultAudioEndpoint(WasapiConsts.eRender, WasapiConsts.eMultimedia, out targetDevice);
            }
            if (targetDevice == null)
            {
                enumerator.GetDefaultAudioEndpoint(WasapiConsts.eRender, WasapiConsts.eConsole, out targetDevice);
            }
            device = targetDevice;

            Guid iidAudioClient = new Guid("1CB9AD4C-DBFA-4c34-B147-1E1E9B00B71A");
            IntPtr clientPtr;
            int hr = device.Activate(ref iidAudioClient, WasapiConsts.CLSCTX_ALL, IntPtr.Zero, out clientPtr);
            if (hr != WasapiConsts.S_OK) throw new Exception($"IAudioClient Activate failed: 0x{hr:X8}");
            audioClient = (IAudioClient)Marshal.GetTypedObjectForIUnknown(clientPtr, typeof(IAudioClient));

            IntPtr mixFormatPtr;
            audioClient.GetMixFormat(out mixFormatPtr);
            waveFormat = (WAVEFORMATEX)Marshal.PtrToStructure(mixFormatPtr, typeof(WAVEFORMATEX));
            sampleRate = waveFormat.nSamplesPerSec;

            waveFormat.wFormatTag = WasapiConsts.WAVE_FORMAT_IEEE_FLOAT;
            waveFormat.wBitsPerSample = 32;
            waveFormat.nBlockAlign = (short)(waveFormat.nChannels * 4);
            waveFormat.nAvgBytesPerSec = waveFormat.nSamplesPerSec * waveFormat.nBlockAlign;
            waveFormat.cbSize = 0;

            long hnsDuration = (long)(desiredFrameSize * 10000000.0 / sampleRate);
            hr = audioClient.Initialize(WasapiConsts.AUDCLNT_SHAREMODE_SHARED, 0, hnsDuration, hnsDuration, ref waveFormat, IntPtr.Zero);
            if (hr != WasapiConsts.S_OK) throw new Exception($"IAudioClient Initialize failed: 0x{hr:X8}");

            audioClient.GetBufferSize(out int bufferSize);
            frameSize = bufferSize;

            Guid iidRender = new Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2");
            IntPtr renderPtr;
            audioClient.GetService(ref iidRender, out renderPtr);
            renderClient = (IAudioRenderClient)Marshal.GetTypedObjectForIUnknown(renderPtr, typeof(IAudioRenderClient));

            audioClient.Start();

            renderThread = new Thread(RenderLoop) { IsBackground = true };
            renderThread.Start();

            return true;
        }
        catch (Exception ex)
        {
            Dispose();
            throw new Exception("NativeAudioRender.Start failed: " + ex.Message, ex);
        }
    }

    public void WriteSamples(float[] samples)
    {
        sampleQueue.Enqueue(samples);
    }

    private void RenderLoop()
    {
        while (running && stopEvent.WaitOne(0) == false)
        {
            try
            {
                float[] block = null;
                if (!sampleQueue.TryDequeue(out block)) { Thread.Sleep(1); continue; }

                audioClient.GetCurrentPadding(out int padding);
                int bufferSize;
                audioClient.GetBufferSize(out bufferSize);
                int available = bufferSize - padding;
                if (available <= 0) { Thread.Sleep(1); continue; }

                int ch = waveFormat.nChannels;
                int toWrite = Math.Min(available, block.Length / ch);
                if (toWrite <= 0) { Thread.Sleep(1); continue; }

                IntPtr dataPtr;
                int hr = renderClient.GetBuffer(toWrite, out dataPtr);
                if (hr != WasapiConsts.S_OK) { Thread.Sleep(1); continue; }

                Marshal.Copy(block, 0, dataPtr, toWrite * ch);
                renderClient.ReleaseBuffer(toWrite, 0);
            }
            catch
            {
                Thread.Sleep(5);
            }
        }
    }

    public void Stop()
    {
        if (!running) return;
        running = false;
        stopEvent.Set();
        try { renderThread?.Join(1000); } catch { }
        try { audioClient?.Stop(); } catch { }
        Dispose();
    }

    public void Dispose()
    {
        running = false;
        stopEvent?.Dispose();
        renderClient = null;
        audioClient = null;
        device = null;
        enumerator = null;
    }
}
'@
}

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

$script:MicEnhanceContext = $null

# ------------------------------------------------------------
# Start-MicEnhancement - built-in DSP pipeline (WASAPI capture +
# real-time processing + WASAPI render). Used when no companion
# tool is configured. Runs capture + DSP + render on background
# threads with sub-20ms target latency.
# ------------------------------------------------------------
function Start-MicEnhancement {
    param(
        [string]$CaptureDeviceId = '',
        [string]$RenderDeviceId = '',
        [float]$GainDb = 0,
        [switch]$NoiseGate = $true,
        [float]$NoiseGateThresholdDb = -40,
        [float]$NoiseGateFloorDb = -60,
        [switch]$NoiseSuppression = $true,
        [float]$NoiseSuppressionStrength = 0.5,
        [switch]$Compressor = $true,
        [float]$CompressorThresholdDb = -20,
        [float]$CompressorRatio = 4,
        [switch]$Limiter = $true,
        [float]$LimiterCeilingDb = -3,
        [switch]$Agc = $false,
        [float]$AgcTargetDb = -18,
        [float]$AgcRate = 0.01,
        [int]$FrameSizeMs = 10
    )

    if ($script:MicEnhanceContext -ne $null) {
        Write-Log 'Microphone enhancement already running.' 'WARN'
        return $false
    }

    try { Add-NativeMicTypes } catch {
        Write-Log "Failed to compile native DSP types: $_" 'ERROR'
        return $false
    }

    if (-not ('NativeMicDsp' -as [type])) {
        Write-Log 'NativeMicDsp type not available.' 'ERROR'
        return $false
    }

    $sampleRate = 48000
    $frameSize = [Math]::Max(64, [int]($sampleRate * $FrameSizeMs / 1000))

    $dsp = New-Object NativeMicDsp -ArgumentList $sampleRate, $frameSize
    $dsp.GainDb = $GainDb
    $dsp.NoiseGateEnabled = $NoiseGate
    $dsp.NoiseGateThresholdDb = $NoiseGateThresholdDb
    $dsp.NoiseGateFloorDb = $NoiseGateFloorDb
    $dsp.NoiseSuppressionEnabled = $NoiseSuppression
    $dsp.NoiseSuppressionStrength = $NoiseSuppressionStrength
    $dsp.CompressorEnabled = $Compressor
    $dsp.CompressorThresholdDb = $CompressorThresholdDb
    $dsp.CompressorRatio = $CompressorRatio
    $dsp.LimiterEnabled = $Limiter
    $dsp.LimiterCeilingDb = $LimiterCeilingDb
    $dsp.AgcEnabled = $Agc
    $dsp.AgcTargetDb = $AgcTargetDb
    $dsp.AgcRate = $AgcRate

    $capture = New-Object NativeAudioCapture
    $render  = New-Object NativeAudioRender

    try {
        $captureStarted = $capture.Start($CaptureDeviceId, [Action[float[], int]]{
            param($samples, $count)
            if ($script:MicEnhanceContext -eq $null) { return }
            $dsp.ProcessBlock($samples, $count)
            $render.WriteSamples($samples)
        }, $sampleRate, $frameSize)
        if (-not $captureStarted) {
            Write-Log 'Failed to start audio capture.' 'ERROR'
            return $false
        }

        $renderStarted = $render.Start($RenderDeviceId, $sampleRate, $frameSize)
        if (-not $renderStarted) {
            Write-Log 'Failed to start audio render.' 'ERROR'
            $capture.Stop()
            return $false
        }

        $script:MicEnhanceContext = @{
            Capture = $capture
            Render  = $render
            Dsp     = $dsp
            Started = [datetime]::UtcNow
        }
        Write-Log "Microphone enhancement started (capture={0} render={1} frameSize={2} samples @ {3}Hz)" -f `
            $(if ($CaptureDeviceId) { $CaptureDeviceId } else { 'default' }), `
            $(if ($RenderDeviceId) { $RenderDeviceId } else { 'default' }), `
            $frameSize, $sampleRate 'OK'
        return $true
    } catch {
        try { $capture.Stop() } catch {}
        try { $render.Stop() } catch {}
        Write-Log "Failed to start microphone enhancement: $_" 'ERROR'
        return $false
    }
}

# ------------------------------------------------------------
# Stop-MicEnhancement - stop the built-in DSP pipeline and
# release all audio resources.
# ------------------------------------------------------------
function Stop-MicEnhancement {
    if ($script:MicEnhanceContext -eq $null) { return }
    try {
        $ctx = $script:MicEnhanceContext
        $ctx.Capture.Stop()
        $ctx.Render.Stop()
        $elapsed = [datetime]::UtcNow - $ctx.Started
        Write-Log ("Microphone enhancement stopped (ran {0} seconds)" -f [int]$elapsed.TotalSeconds) 'OK'
    } catch { Write-Log "Failed to stop microphone enhancement: $_" 'WARN' }
    finally { $script:MicEnhanceContext = $null }
}

# ------------------------------------------------------------
# Get-MicDevices - enumerate audio capture and render endpoints
# ------------------------------------------------------------
function Get-MicDevices {
    param(
        [switch]$Capture,
        [switch]$Render
    )
    if (-not $Capture -and -not $Render) { $Capture = $true; $Render = $true }

    try { Add-NativeMicTypes } catch {
        Write-Log "Failed to compile native types: $_" 'ERROR'
        return
    }

    $results = @()

    if ($Capture) {
        try {
            $captureDevices = [NativeAudioDevice]::EnumerateDevices($true)
            foreach ($d in $captureDevices) {
                $results += [pscustomobject]@{
                    Type    = 'Capture'
                    Id      = $d.Id
                    Name    = $d.Name
                    State   = $d.State
                }
            }
        } catch { Write-Log "Failed to enumerate capture devices: $_" 'WARN' }
    }

    if ($Render) {
        try {
            $renderDevices = [NativeAudioDevice]::EnumerateDevices($false)
            foreach ($d in $renderDevices) {
                $results += [pscustomobject]@{
                    Type    = 'Render'
                    Id      = $d.Id
                    Name    = $d.Name
                    State   = $d.State
                }
            }
        } catch { Write-Log "Failed to enumerate render devices: $_" 'WARN' }
    }

    return $results
}

# ------------------------------------------------------------
# Test-MicEnhancement - run the DSP pipeline on synthetic audio
# to verify processing works without hardware.
# ------------------------------------------------------------
function Test-MicEnhancement {
    param(
        [int]$DurationSeconds = 3,
        [int]$SampleRate = 48000,
        [float]$GainDb = 6,
        [float]$NoiseSuppressionStrength = 0.5
    )

    try { Add-NativeMicTypes } catch {
        Write-Log "Failed to compile native types: $_" 'ERROR'
        return $null
    }

    $dsp = New-Object NativeMicDsp -ArgumentList $SampleRate, 480
    $dsp.GainDb = $GainDb
    $dsp.NoiseGateEnabled = $true
    $dsp.NoiseSuppressionEnabled = $true
    $dsp.NoiseSuppressionStrength = $NoiseSuppressionStrength
    $dsp.CompressorEnabled = $true
    $dsp.LimiterEnabled = $true
    $dsp.AgcEnabled = $false

    $totalSamples = $SampleRate * $DurationSeconds
    $frameSize = 480
    $samples = New-Object float[] $totalSamples
    $rand = New-Object Random

    # Generate synthetic audio: speech-like sine + noise
    for ($i = 0; $i -lt $totalSamples; $i++) {
        $t = $i / $SampleRate
        $speech = [Math]::Sin(2 * [Math]::PI * 220 * $t) * 0.3 +
                  [Math]::Sin(2 * [Math]::PI * 440 * $t) * 0.2 +
                  [Math]::Sin(2 * [Math]::PI * 880 * $t) * 0.1
        $noise = (($rand.NextDouble() - 0.5) * 0.05)
        $samples[$i] = [float]($speech + $noise)
    }

    $processed = New-Object float[] $totalSamples
    [Array]::Copy($samples, $processed, $totalSamples)

    $start = [datetime]::UtcNow
    $framesProcessed = 0
    $peakInput = 0.0; $peakOutput = 0.0
    $rmsInput = 0.0; $rmsOutput = 0.0

    for ($offset = 0; $offset -lt $totalSamples; $offset += $frameSize) {
        $remaining = $totalSamples - $offset
        $thisFrame = [Math]::Min($frameSize, $remaining)
        $frame = New-Object float[] $thisFrame
        [Array]::Copy($processed, $offset, $frame, 0, $thisFrame)
        $dsp.ProcessBlock($frame, $thisFrame)
        [Array]::Copy($frame, 0, $processed, $offset, $thisFrame)
        $framesProcessed++

        for ($i = 0; $i -lt $thisFrame; $i++) {
            $s = $samples[$offset + $i]
            $p = $processed[$offset + $i]
            if ([Math]::Abs($s) -gt $peakInput) { $peakInput = [Math]::Abs($s) }
            if ([Math]::Abs($p) -gt $peakOutput) { $peakOutput = [Math]::Abs($p) }
            $rmsInput += $s * $s
            $rmsOutput += $p * $p
        }
    }
    $elapsed = [datetime]::UtcNow - $start
    $rmsInput = [Math]::Sqrt($rmsInput / $totalSamples)
    $rmsOutput = [Math]::Sqrt($rmsOutput / $totalSamples)

    $result = [pscustomobject]@{
        DurationSeconds    = $DurationSeconds
        SampleRate         = $SampleRate
        FramesProcessed    = $framesProcessed
        ElapsedMs          = [int]$elapsed.TotalMilliseconds
        PeakInput          = [Math]::Round($peakInput, 4)
        PeakOutput         = [Math]::Round($peakOutput, 4)
        RmsInput           = [Math]::Round($rmsInput, 4)
        RmsOutput          = [Math]::Round($rmsOutput, 4)
        GainAppliedDb      = [Math]::Round(20 * [Math]::Log10([Math]::Max($rmsOutput, 0.00001) / [Math]::Max($rmsInput, 0.00001)), 2)
    }

    Write-Log ("Mic-enhancement test: {0} frames in {1}ms | peak {2}->{3} | rms {4}->{5} | gain {6} dB" -f `
        $framesProcessed, $result.ElapsedMs, $result.PeakInput, $result.PeakOutput, `
        $result.RmsInput, $result.RmsOutput, $result.GainAppliedDb) 'OK'

    return $result
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

Export-ModuleMember -Function Invoke-MicEnhanceTool, Stop-MicEnhanceTool, Add-NativeAudioDspType,
    Add-NativeMicTypes, Start-MicEnhancement, Stop-MicEnhancement, Get-MicDevices, Test-MicEnhancement