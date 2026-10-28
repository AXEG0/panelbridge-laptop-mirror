// PanelMirror: shows the virtual display (rendered by the NVIDIA GPU) on the laptop panel, which stays on
// Microsoft Basic Display. Frames come from DXGI Desktop Duplication and are drawn with GDI.
using System.Runtime.InteropServices;

namespace PanelMirror;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        try { return Run(args); }
        catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
    }

    static int Run(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        if (args.Contains("--restore-windows"))
        {
            var virtualScreen = Displays.FindByAdapter("MttVDD", "Virtual Display Driver");
            var panel = Displays.FindByAdapter("VEN_8086", null) ??
                Displays.FindByAdapter(@"ROOT\BasicDisplay", "Microsoft Basic Display Driver");
            if (virtualScreen != null && panel != null)
                Console.WriteLine($"Restored {Windows.MoveAll(virtualScreen.Bounds, panel.Bounds)} windows to the laptop screen.");
            return 0;
        }
        if (args.Contains("--driver-info"))
        {
            using var diagnostics = new FramebufferSink(diagnosticsOnly: true);
            diagnostics.PrintInfo();
            return args.Contains("--require-driver-ready") && diagnostics.Layout.State != 1 ? 2 : 0;
        }
        bool direct = args.Contains("--driver");
        bool clip = !args.Contains("--noclip");

        var source = Displays.FindByAdapter("MttVDD", "Virtual Display Driver");
        var target = Displays.FindByAdapter("VEN_8086", null) ??
            Displays.FindByAdapter(@"ROOT\BasicDisplay", "Microsoft Basic Display Driver");
        if (source == null || (!direct && target == null))
        {
            Console.Error.WriteLine($"Virtual display: {source?.DeviceName ?? "not found"}, laptop panel: {target?.DeviceName ?? "not found"}");
            return 1;
        }
        using var sink = direct ? new FramebufferSink() : null;
        if (direct) sink.PrintInfo();
        Console.WriteLine(direct ? $"Mirroring {source.DeviceName} {source.Bounds} -> firmware framebuffer" :
            $"Mirroring {source.DeviceName} {source.Bounds} -> {target.DeviceName} {target.Bounds}");
        Console.WriteLine("Ctrl+Alt+F12 or Ctrl+C quits." + (clip ? " The mouse is kept on the virtual display." : ""));

        // The mirror window covers the panel, so whatever was open there would be hidden behind it.
        if (!direct && !args.Contains("--keep-windows"))
            Console.WriteLine($"Moved {Windows.MoveAll(target.Bounds, source.Bounds)} windows to the virtual display");

        // Capture-only runs keep a 1x1 window so the panel itself is left untouched.
        var formBounds = direct ? new Rectangle(source.Bounds.Location, new Size(1, 1)) :
            args.Contains("--noblit") ? new Rectangle(target.Bounds.Location, new Size(1, 1)) : target.Bounds;
        using var form = new MirrorForm(formBounds, clip ? source.Bounds : Rectangle.Empty);
        int areaArg = Array.IndexOf(args, "--area");
        double area = areaArg >= 0 ? double.Parse(args[areaArg + 1], System.Globalization.CultureInfo.InvariantCulture) : 1;
        using var mirror = new Mirror(source.DeviceName, blit: !args.Contains("--noblit"), area: area, sink: sink,
            onPanelLost: direct ? () => { if (!form.IsDisposed) form.BeginInvoke(form.Close); } : null,
            onPanelReattached: direct ? DetachPanelAgain : null);
        int heavyArg = Array.IndexOf(args, "--heavy");
        int heavy = heavyArg >= 0 ? int.Parse(args[heavyArg + 1]) : 0;
        using var pattern = args.Contains("--pattern") ? new PatternForm(source.Bounds, heavy) : null;
        form.Shown += (_, _) => { mirror.Start(form.Handle); pattern?.Show(); };
        form.FormClosing += (_, _) => mirror.Stop();
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; form.BeginInvoke(form.Close); };
        int durationArg = Array.IndexOf(args, "--duration");
        using var duration = new System.Windows.Forms.Timer();
        if (durationArg >= 0)
        {
            duration.Interval = checked(int.Parse(args[durationArg + 1]) * 1000);
            duration.Tick += (_, _) => form.Close();
            duration.Start();
        }
        Application.Run(form);
        // Without the mirror the virtual display is invisible, so bring the windows back to the panel.
        if (!direct && !args.Contains("--keep-windows"))
            Console.WriteLine($"Moved {Windows.MoveAll(source.Bounds, target.Bounds)} windows back to the panel");
        return 0;
    }

    // Games that reset the display mode (RE4 a few seconds after starting borderless, or on alt-tab out of exclusive
    // fullscreen) apply the normal layout staged for restarts, which reattaches the panel output. Detach it again with
    // the session's own topology script and re-stage the normal layout, at most three times a minute, instead of
    // ending the session.
    static readonly Queue<DateTime> Redetaches = new();

    static bool DetachPanelAgain()
    {
        while (Redetaches.Count > 0 && DateTime.UtcNow - Redetaches.Peek() > TimeSpan.FromMinutes(1)) Redetaches.Dequeue();
        if (Redetaches.Count >= 3) return false;
        Redetaches.Enqueue(DateTime.UtcNow);
        Console.WriteLine("Windows reattached its own panel output; detaching it again.");
        return RunTopology("Detach") && RunTopology("StageRestore") && !FramebufferSink.FallbackOwnsPanel();
    }

    static bool RunTopology(string mode)
    {
        string recovery = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "PanelBridgeRecovery");
        var start = new System.Diagnostics.ProcessStartInfo("powershell.exe",
            $"-NoProfile -ExecutionPolicy Bypass -File \"{recovery}\\display-topology.ps1\" -Mode {mode} -StatePath \"{recovery}\\logs\\topology.json\"")
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
        };
        using var process = System.Diagnostics.Process.Start(start);
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(30000))
        {
            process.Kill();
            Console.WriteLine($"Display topology {mode} timed out.");
            return false;
        }
        Console.Write(output.Result + error.Result);
        return process.ExitCode == 0;
    }
}

static class Displays
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE dd, uint flags);

    const int DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 1;

    // The desktop screen of the first attached adapter whose PnP id contains idPart (or whose name is adapterName).
    public static Screen FindByAdapter(string idPart, string adapterName)
    {
        for (uint i = 0; ; i++)
        {
            var dd = new DISPLAY_DEVICE { cb = Marshal.SizeOf<DISPLAY_DEVICE>() };
            if (!EnumDisplayDevices(null, i, ref dd, 0)) return null;
            if ((dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) == 0) continue;
            if (dd.DeviceID.Contains(idPart, StringComparison.OrdinalIgnoreCase) || dd.DeviceString == adapterName)
                return Screen.AllScreens.FirstOrDefault(s => s.DeviceName == dd.DeviceName);
        }
    }
}

// Borderless, never-activated window covering the laptop panel. The mirror thread draws every pixel.
sealed class MirrorForm : Form
{
    const int WS_EX_TOPMOST = 0x8, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000;
    const int WM_HOTKEY = 0x312, MOD_ALT = 1, MOD_CONTROL = 2, VK_F12 = 0x7B;

    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hwnd, int id, int mods, int vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hwnd, int id);

    readonly Rectangle _bounds;
    readonly Rectangle _cursorClip;
    readonly System.Windows.Forms.Timer _clipTimer = new() { Interval = 250 };

    public MirrorForm(Rectangle bounds, Rectangle cursorClip)
    {
        _bounds = bounds;
        _cursorClip = cursorClip;
        AutoScaleMode = AutoScaleMode.None;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = bounds;
        BackColor = Color.Black;
        ShowInTaskbar = false;
        TopMost = true;
        Text = "PanelMirror";
        // Other windows can reset the clip (focus changes, UAC), so it is reapplied periodically.
        _clipTimer.Tick += (_, _) => { if (!_cursorClip.IsEmpty) Cursor.Clip = _cursorClip; };
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            return cp;
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        RegisterHotKey(Handle, 1, MOD_CONTROL | MOD_ALT, VK_F12);
    }

    protected override void OnShown(EventArgs e)
    {
        Bounds = _bounds;
        _clipTimer.Start();
        base.OnShown(e);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        _clipTimer.Stop();
        Cursor.Clip = Rectangle.Empty;
        UnregisterHotKey(Handle, 1);
        base.OnFormClosing(e);
    }

    // Keep the exact panel rectangle instead of the size Windows suggests after a DPI change.
    protected override void OnDpiChanged(DpiChangedEventArgs e) => e.Cancel = true;

    protected override void OnPaintBackground(PaintEventArgs e) { }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY) Close();
        base.WndProc(ref m);
    }
}
