using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace PanelMirror;

// The driver owns the PCI resources. This interface accepts pixels and exposes
// layout diagnostics; it never accepts a physical address or register writes.
sealed unsafe class FramebufferSink : IDisposable
{
    const uint InfoIoctl = (0x22u << 16) | (1u << 14) | (0x800u << 2);
    const uint FrameIoctl = (0x22u << 16) | (2u << 14) | (0x801u << 2) | 1u;

    [StructLayout(LayoutKind.Sequential)]
    public struct Info
    {
        public uint Version, Bytes, State, ActivePlanes;
        public uint Width, Height, Pitch, Reserved;
        public ulong MmioPhysical, AperturePhysical, ApertureLength, FrameOffset, FrameLength;
        public fixed uint Planes[28 * 8];
    }

    [StructLayout(LayoutKind.Sequential)]
    struct Frame { public uint Version, Width, Height, Pitch, Bytes; }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle file, uint ioctl, void* input,
        uint inputBytes, void* output, uint outputBytes, out uint returned, IntPtr overlapped);

    readonly SafeFileHandle _file;
    public Info Layout { get; }

    public FramebufferSink(bool diagnosticsOnly = false)
    {
        if (!diagnosticsOnly && FallbackOwnsPanel())
            throw new InvalidOperationException("Windows' fallback output still owns the panel. Detach that output before direct presentation to prevent framebuffer corruption.");
        _file = CreateFile(@"\\.\PanelBridge", diagnosticsOnly ? 0x80000000u : 0xc0000000u,
            0, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (_file.IsInvalid)
        {
            var error = new Win32Exception(Marshal.GetLastWin32Error(),
                "Cannot open PanelBridge. The test driver must be installed, and this process must run as administrator.");
            _file.Dispose();
            throw error;
        }
        try
        {
            Info info = default;
            if (!DeviceIoControl(_file, InfoIoctl, null, 0, &info, (uint)sizeof(Info), out uint returned, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "PanelBridge diagnostics failed");
            if (returned != sizeof(Info) || info.Version != 1 || info.Bytes != sizeof(Info))
                throw new InvalidOperationException("PanelBridge protocol version or structure size differs.");
            Layout = info;
            if (!diagnosticsOnly && info.State != 1)
                throw new InvalidOperationException($"PanelBridge cannot present: {StateName(info.State)}. Run --driver-info for the register snapshot.");
        }
        catch { _file.Dispose(); throw; }
    }

    // Windows' own output on the panel draws into the same framebuffer, so frames must not be written while it is attached.
    public static bool FallbackOwnsPanel() =>
        Displays.FindByAdapter(@"ROOT\BasicDisplay", "Microsoft Basic Display Driver") != null;

    public void Present(IntPtr pixels, uint width, uint height, uint pitch)
    {
        if (width != Layout.Width || height != Layout.Height || pitch < width * 4)
            throw new InvalidOperationException("Captured frame must match the firmware framebuffer (1920x1080 BGRA).");
        var frame = new Frame { Version = 1, Width = width, Height = height, Pitch = pitch,
            Bytes = checked((height - 1) * pitch + width * 4) };
        if (!DeviceIoControl(_file, FrameIoctl, &frame, (uint)sizeof(Frame),
            pixels.ToPointer(), frame.Bytes, out _, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "PanelBridge frame transfer stopped");
    }

    public void PrintInfo()
    {
        var info = Layout;
        Console.WriteLine($"PanelBridge v{info.Version}: {StateName(info.State)}, {info.ActivePlanes} active plane(s)");
        Console.WriteLine($"MMIO 0x{info.MmioPhysical:X}, aperture 0x{info.AperturePhysical:X}, length 0x{info.ApertureLength:X}");
        Console.WriteLine($"Framebuffer {info.Width}x{info.Height}, pitch {info.Pitch}, offset 0x{info.FrameOffset:X}, length {info.FrameLength}");
        for (int i = 0; i < 28; ++i)
        {
            uint* p = info.Planes + i * 8;
            if ((p[2] & 0x80000000u) == 0) continue;
            Console.WriteLine($"Pipe {p[0]} plane {p[1]}: ctl={p[2]:X8} stride={p[3]:X8} size={p[4]:X8} surf={p[5]:X8} offset={p[6]:X8} live={p[7]:X8}");
        }
    }

    static string StateName(uint state) => state switch
    {
        0 => "offline", 1 => "ready", 2 => "no active plane", 3 => "multiple active planes",
        4 => "unsupported framebuffer layout", 5 => "framebuffer outside aperture",
        6 => "framebuffer mapping failed", 7 => "display layout changed", _ => $"unknown state {state}"
    };

    public void Dispose() => _file.Dispose();
}
