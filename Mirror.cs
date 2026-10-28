using System.Diagnostics;
using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace PanelMirror;

// Captures one output with Desktop Duplication on the GPU that renders it, reads each new frame back
// to system memory and blits it into the mirror window. Prints per-stage timings once a second.
sealed class Mirror : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER
    {
        public int biSize, biWidth, biHeight;
        public short biPlanes, biBitCount;
        public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
    }

    [DllImport("gdi32.dll")]
    static extern int StretchDIBits(IntPtr hdc, int xDest, int yDest, int wDest, int hDest, int xSrc, int ySrc, int wSrc, int hSrc,
        IntPtr bits, ref BITMAPINFOHEADER bmi, uint usage, uint rop);
    [DllImport("gdi32.dll")] static extern int SetStretchBltMode(IntPtr hdc, int mode);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd, out Rectangle rect);
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint period);
    [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint period);
    [DllImport("kernel32.dll")]
    static extern bool SetProcessInformation(IntPtr process, int infoClass, ref PROCESS_POWER_THROTTLING_STATE info, int size);

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_POWER_THROTTLING_STATE { public uint Version, ControlMask, StateMask; }

    const uint SRCCOPY = 0x00CC0020;
    const int COLORONCOLOR = 3;
    const int ProcessPowerThrottling = 4;
    const uint PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION = 4;

    readonly string _deviceName;
    readonly bool _blit;
    readonly double _area;
    readonly FramebufferSink _sink;
    readonly Action _onPanelLost;
    readonly Func<bool> _onPanelReattached;
    Thread _thread;
    volatile bool _stop;
    IntPtr _hwnd;

    // blit=false only captures, to measure how fast the virtual display produces frames on its own.
    // area < 1 draws only that fraction of the width and height, to see how panel cost scales with pixels.
    // onPanelReattached returns true once Windows' panel output is detached again; false ends the session.
    public Mirror(string deviceName, bool blit = true, double area = 1, FramebufferSink sink = null, Action onPanelLost = null,
        Func<bool> onPanelReattached = null)
    {
        _deviceName = deviceName;
        _blit = blit;
        _area = area;
        _sink = sink;
        _onPanelLost = onPanelLost;
        _onPanelReattached = onPanelReattached;
    }

    public void Start(IntPtr hwnd)
    {
        _hwnd = hwnd;
        _thread = new Thread(Run) { IsBackground = true, Priority = ThreadPriority.Highest, Name = "mirror" };
        _thread.Start();
    }

    public void Stop()
    {
        _stop = true;
        _thread?.Join(2000);
    }

    public void Dispose() => Stop();

    void Run()
    {
        // The 1 ms frame polling in Loop otherwise sleeps a whole 15.6 ms timer tick. Windows 11 may ignore the
        // request for a process without a visible window unless timer-resolution throttling is turned off.
        var throttling = new PROCESS_POWER_THROTTLING_STATE { Version = 1, ControlMask = PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION };
        SetProcessInformation(Process.GetCurrentProcess().Handle, ProcessPowerThrottling, ref throttling,
            Marshal.SizeOf<PROCESS_POWER_THROTTLING_STATE>());
        timeBeginPeriod(1);
        try
        {
            while (!_stop)
            {
                try { Capture(); }
                catch (PanelLostException e)
                {
                    Console.WriteLine(e.Message);
                    _onPanelLost?.Invoke();
                    return;
                }
                catch (Exception e)
                {
                    if (_sink != null && e.HResult == unchecked((int)0x80070005) && _onPanelLost != null)
                    {
                        Console.WriteLine("Secure desktop detected; restoring the normal display.");
                        _onPanelLost();
                        return;
                    }
                    // Mode changes, UAC prompts and fullscreen switches invalidate the duplication; start over.
                    Console.WriteLine($"Capture restarted: {e.Message}");
                    Thread.Sleep(500);
                }
            }
        }
        finally
        {
            timeEndPeriod(1);
        }
    }

    void Capture()
    {
        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
        var (adapter, output) = FindOutput(factory, _deviceName);
        using (adapter)
        using (output)
        {
            D3D11.D3D11CreateDevice(adapter, DriverType.Unknown, DeviceCreationFlags.BgraSupport,
                new[] { FeatureLevel.Level_11_0 }, out ID3D11Device device, out ID3D11DeviceContext ctx).CheckError();
            using (device)
            using (ctx)
            using (var output1 = output.QueryInterface<IDXGIOutput1>())
            using (var dup = output1.DuplicateOutput(device))
            {
                GpuPriority.Raise(device);
                var mode = dup.Description.ModeDescription;
                Console.WriteLine($"Capturing {_deviceName} on {adapter.Description1.Description}: {mode.Width}x{mode.Height} {mode.Format}");
                var desc = new Texture2DDescription
                {
                    Width = mode.Width,
                    Height = mode.Height,
                    MipLevels = 1,
                    ArraySize = 1,
                    Format = Format.B8G8R8A8_UNorm,
                    SampleDescription = new SampleDescription(1, 0),
                    Usage = ResourceUsage.Staging,
                    BindFlags = BindFlags.None,
                    CPUAccessFlags = CpuAccessFlags.Read,
                };
                var staging = new ID3D11Texture2D[StagingDepth];
                try
                {
                    for (int i = 0; i < staging.Length; i++) staging[i] = device.CreateTexture2D(desc);
                    Loop(dup, ctx, staging, (int)mode.Width, (int)mode.Height);
                }
                finally
                {
                    foreach (var s in staging) s?.Dispose();
                }
            }
        }
    }

    // A game that saturates the GPU (RE4 with DLSS 5) delays each readback copy by up to ~75 ms. Waiting for one
    // copy before taking the next frame held the panel to 12 fps, so several copies stay in flight instead.
    const int StagingDepth = 3;

    readonly record struct Pending(int Slot, long Submitted, long PresentTime, long Wait, int Skipped);

    void Loop(IDXGIOutputDuplication dup, ID3D11DeviceContext ctx, ID3D11Texture2D[] staging, int w, int h)
    {
        IntPtr hdc = _sink == null && _blit ? GetDC(_hwnd) : IntPtr.Zero;
        if (hdc != IntPtr.Zero) SetStretchBltMode(hdc, COLORONCOLOR);
        var bmi = new BITMAPINFOHEADER { biSize = Marshal.SizeOf<BITMAPINFOHEADER>(), biHeight = -h, biPlanes = 1, biBitCount = 32 };
        var stats = new Stats();
        var pending = new Queue<Pending>();
        int next = 0;
        long nextFallbackCheck = 0;
        try
        {
            while (!_stop)
            {
                // Apps that reset the display mode (games often do on exit) can apply the normal layout staged in
                // the registry, which reattaches Windows' own panel output. Writing frames then corrupts the picture.
                if (_sink != null && Stopwatch.GetTimestamp() >= nextFallbackCheck)
                {
                    if (FramebufferSink.FallbackOwnsPanel() && !(_onPanelReattached?.Invoke() ?? false))
                        throw new PanelLostException("Windows reattached its own panel output; restoring the normal display.");
                    nextFallbackCheck = Stopwatch.GetTimestamp() + Stopwatch.Frequency / 4;
                }
                // Show finished copies oldest first; block only when every staging texture is in flight.
                while (pending.Count > 0 && Show(ctx, staging, pending.Peek(), pending.Count == staging.Length, hdc, ref bmi, w, h, stats))
                    pending.Dequeue();

                long t0 = Stopwatch.GetTimestamp();
                // While copies are pending, poll briefly so a finished one isn't held behind a 100 ms wait.
                var r = dup.AcquireNextFrame(pending.Count > 0 ? 1u : 100u, out OutduplFrameInfo info, out IDXGIResource res);
                if (r.Code == Vortice.DXGI.ResultCode.WaitTimeout.Code) { stats.Report(); continue; }
                r.CheckError();
                long t1 = Stopwatch.GetTimestamp();
                try
                {
                    if (info.LastPresentTime == 0) continue; // only the pointer moved
                    using (var tex = res.QueryInterface<ID3D11Texture2D>())
                        ctx.CopyResource(staging[next], tex);
                    ctx.Flush();
                    pending.Enqueue(new Pending(next, t1, info.LastPresentTime, t1 - t0, (int)info.AccumulatedFrames - 1));
                    next = (next + 1) % staging.Length;
                }
                finally
                {
                    res.Dispose();
                    dup.ReleaseFrame();
                }
            }
        }
        finally
        {
            if (hdc != IntPtr.Zero) ReleaseDC(_hwnd, hdc);
        }
    }

    // Maps one copied frame and hands it to the panel or window. Returns false if the copy hasn't finished and wait is off.
    bool Show(ID3D11DeviceContext ctx, ID3D11Texture2D[] staging, Pending p, bool wait, IntPtr hdc, ref BITMAPINFOHEADER bmi,
        int w, int h, Stats stats)
    {
        var tex = staging[p.Slot];
        var r = ctx.Map(tex, 0, MapMode.Read, wait ? Vortice.Direct3D11.MapFlags.None : Vortice.Direct3D11.MapFlags.DoNotWait,
            out MappedSubresource map);
        if (r.Code == Vortice.DXGI.ResultCode.WasStillDrawing.Code) return false;
        r.CheckError();
        long t2 = Stopwatch.GetTimestamp();
        try
        {
            if (_blit && _sink != null)
                _sink.Present(map.DataPointer, (uint)w, (uint)h, map.RowPitch);
            else if (_blit)
            {
                GetClientRect(_hwnd, out var client); // Rectangle holds left, top, right, bottom
                bmi.biWidth = (int)(map.RowPitch / 4);
                int dw = (int)(client.Width * _area), dh = (int)(client.Height * _area);
                StretchDIBits(hdc, 0, 0, dw, dh, 0, 0, (int)(w * _area), (int)(h * _area), map.DataPointer, ref bmi, 0, SRCCOPY);
            }
        }
        finally
        {
            ctx.Unmap(tex, 0);
        }
        long t3 = Stopwatch.GetTimestamp();
        stats.Add(p.Wait, t2 - p.Submitted, t3 - t2, t3 - p.PresentTime, p.Skipped);
        stats.Report();
        return true;
    }

    static (IDXGIAdapter1, IDXGIOutput) FindOutput(IDXGIFactory1 factory, string deviceName)
    {
        for (uint a = 0; factory.EnumAdapters1(a, out IDXGIAdapter1 adapter).Success; a++)
        {
            for (uint o = 0; adapter.EnumOutputs(o, out IDXGIOutput output).Success; o++)
            {
                if (output.Description.DeviceName == deviceName) return (adapter, output);
                output.Dispose();
            }
            adapter.Dispose();
        }
        throw new InvalidOperationException($"No DXGI output for {deviceName}");
    }

    // Once-a-second summary: frames shown, frames the virtual display produced but we skipped, and stage timings.
    sealed class Stats
    {
        static readonly double MsPerTick = 1000.0 / Stopwatch.Frequency;
        long _since = Stopwatch.GetTimestamp();
        int _frames, _skipped;
        long _wait, _copy, _blit, _latency, _maxLatency;

        public void Add(long wait, long copy, long blit, long latency, int skipped)
        {
            _frames++; _skipped += Math.Max(0, skipped);
            _wait += wait; _copy += copy; _blit += blit; _latency += latency;
            _maxLatency = Math.Max(_maxLatency, latency);
        }

        public void Report()
        {
            long now = Stopwatch.GetTimestamp();
            if ((now - _since) * MsPerTick < 1000) return;
            if (_frames > 0)
                Console.WriteLine($"{_frames,3} fps  skipped {_skipped,3}  wait {_wait * MsPerTick / _frames,5:F1} ms  " +
                    $"copy {_copy * MsPerTick / _frames,4:F1} ms  blit {_blit * MsPerTick / _frames,4:F1} ms  " +
                    $"present->blit avg {_latency * MsPerTick / _frames,4:F1} ms max {_maxLatency * MsPerTick,4:F1} ms");
            else
                Console.WriteLine("  0 fps  (virtual display unchanged)");
            _since = now; _frames = _skipped = 0; _wait = _copy = _blit = _latency = _maxLatency = 0;
        }
    }
}

sealed class PanelLostException(string message) : Exception(message);
