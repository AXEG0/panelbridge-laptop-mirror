using System.Runtime.InteropServices;

namespace PanelMirror;

static class Windows
{
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    const int GWL_EXSTYLE = -20, WS_EX_TOOLWINDOW = 0x80, SW_RESTORE = 9, SW_MAXIMIZE = 3;
    const uint SWP_NOSIZE = 1, SWP_NOZORDER = 4, SWP_NOACTIVATE = 0x10;

    // Moves every visible top-level window centred on `from` to the same spot on `to`. Returns how many moved.
    public static int MoveAll(Rectangle from, Rectangle to)
    {
        int moved = 0;
        EnumWindows((h, _) =>
        {
            if (!IsWindowVisible(h) || IsIconic(h) || (GetWindowLong(h, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0) return true;
            GetWindowRect(h, out var r);
            if (!from.Contains((r.Left + r.Right) / 2, (r.Top + r.Bottom) / 2)) return true;
            bool maximized = IsZoomed(h);
            if (maximized) ShowWindow(h, SW_RESTORE);
            GetWindowRect(h, out r);
            if (SetWindowPos(h, IntPtr.Zero, to.X + r.Left - from.X, to.Y + r.Top - from.Y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)) moved++;
            if (maximized) ShowWindow(h, SW_MAXIMIZE);
            return true;
        }, IntPtr.Zero);
        return moved;
    }
}

// Game-like test load on the virtual display: a Direct3D 11 flip-model swap chain presenting a sweeping bar
// as fast as possible (no vsync), so the mirror's fps shows what a game would get.
sealed class PatternForm : Form
{
    readonly int _heavy;
    Thread _thread;
    volatile bool _stop;

    // heavy = extra full-window clears per frame, to push the GPU out of its idle clocks like a game would.
    public PatternForm(Rectangle screen, int heavy = 0)
    {
        _heavy = heavy;
        AutoScaleMode = AutoScaleMode.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = new Rectangle(screen.X + screen.Width / 4, screen.Y + screen.Height / 4, screen.Width / 2, screen.Height / 2);
        Text = "PanelMirror test pattern";
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        IntPtr hwnd = Handle;
        var size = ClientSize;
        _thread = new Thread(() => Render(hwnd, size.Width, size.Height)) { IsBackground = true, Name = "pattern" };
        _thread.Start();
    }

    void Render(IntPtr hwnd, int w, int h)
    {
        using var factory = Vortice.DXGI.DXGI.CreateDXGIFactory2<Vortice.DXGI.IDXGIFactory2>(false);
        // The default adapter follows the primary display, which may be Basic Display (software rendering); games use the NVIDIA GPU.
        Vortice.DXGI.IDXGIAdapter1 nvidia = null;
        for (uint i = 0; nvidia == null && factory.EnumAdapters1(i, out var a).Success; i++)
            if (a.Description1.VendorId == 0x10DE) nvidia = a; else a.Dispose();
        using var _ = nvidia;
        Console.WriteLine($"pattern renders on {nvidia.Description1.Description}");
        Vortice.Direct3D11.D3D11.D3D11CreateDevice(nvidia, Vortice.Direct3D.DriverType.Unknown, Vortice.Direct3D11.DeviceCreationFlags.BgraSupport,
            new[] { Vortice.Direct3D.FeatureLevel.Level_11_0 }, out Vortice.Direct3D11.ID3D11Device device, out Vortice.Direct3D11.ID3D11DeviceContext ctx).CheckError();
        using (device)
        using (ctx)
        using (var ctx1 = ctx.QueryInterface<Vortice.Direct3D11.ID3D11DeviceContext1>())
        using (var swap = factory.CreateSwapChainForHwnd(device, hwnd, new Vortice.DXGI.SwapChainDescription1
        {
            Width = (uint)w, Height = (uint)h, Format = Vortice.DXGI.Format.B8G8R8A8_UNorm, BufferCount = 2,
            BufferUsage = Vortice.DXGI.Usage.RenderTargetOutput, SampleDescription = new Vortice.DXGI.SampleDescription(1, 0),
            SwapEffect = Vortice.DXGI.SwapEffect.FlipDiscard,
        }))
        using (var back = swap.GetBuffer<Vortice.Direct3D11.ID3D11Texture2D>(0))
        using (var rtv = device.CreateRenderTargetView(back))
        {
            var second = System.Diagnostics.Stopwatch.StartNew();
            int presents = 0;
            Vortice.DXGI.FrameStatistics last = default;
            for (int frame = 0; !_stop; frame++)
            {
                if (second.ElapsedMilliseconds >= 1000)
                {
                    // Displayed = presents DWM actually put on screen; refreshes = vblanks DXGI saw on this output.
                    string shown = "n/a";
                    if (swap.GetFrameStatistics(out var fs).Success)
                    {
                        if (last.PresentCount != 0)
                            shown = $"displayed {fs.PresentRefreshCount - last.PresentRefreshCount}, refreshes {fs.SyncRefreshCount - last.SyncRefreshCount}";
                        last = fs;
                    }
                    Console.WriteLine($"pattern presents/s {presents}, {shown}");
                    presents = 0;
                    second.Restart();
                }
                presents++;
                int x = frame * 4 % w;
                for (int i = 0; i <= _heavy; i++)
                    ctx1.ClearView(rtv, new Vortice.Mathematics.Color4(0.05f, 0.05f, 0.1f, 1), Array.Empty<Vortice.RawRect>());
                ctx1.ClearView(rtv, new Vortice.Mathematics.Color4(1, 1, 1, 1), new[] { new Vortice.RawRect(x, 0, x + 24, h) });
                swap.Present(0, Vortice.DXGI.PresentFlags.None);
            }
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        _stop = true;
        _thread?.Join(1000);
        base.OnFormClosing(e);
    }
}
