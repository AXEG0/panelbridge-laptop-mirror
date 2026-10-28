using System.Runtime.InteropServices;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace PanelMirror;

// A game that keeps the GPU busy makes the mirror's copy wait behind its frames (about 100 ms each in RE4),
// so the panel drops to a few fps. Raising the mirror's GPU priority lets the copy go first, as OBS does for
// game capture. Both calls need SeIncreaseBasePriorityPrivilege, which an elevated process holds but must enable.
// With hardware GPU scheduling on, HIGH still left the copy ~75 ms behind RE4 with DLSS 5, so the realtime class
// is used there instead.
static class GpuPriority
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct TOKEN_PRIVILEGES { public int PrivilegeCount; public long Luid; public int Attributes; }
    [StructLayout(LayoutKind.Sequential)]
    struct OPENADAPTERFROMLUID { public uint LowPart; public int HighPart; public uint Adapter; }
    [StructLayout(LayoutKind.Sequential)]
    struct QUERYADAPTERINFO { public uint Adapter; public int Type; public IntPtr Data; public uint DataSize; }

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, int access, out IntPtr token);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool LookupPrivilegeValue(string system, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES state, int length,
        IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("gdi32.dll")] static extern int D3DKMTSetProcessSchedulingPriorityClass(IntPtr process, int priorityClass);
    [DllImport("gdi32.dll")] static extern int D3DKMTOpenAdapterFromLuid(ref OPENADAPTERFROMLUID open);
    [DllImport("gdi32.dll")] static extern int D3DKMTQueryAdapterInfo(ref QUERYADAPTERINFO query);
    [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(ref uint adapter);

    const int TOKEN_ADJUST_PRIVILEGES = 0x20, SE_PRIVILEGE_ENABLED = 2;
    const int D3DKMT_SCHEDULINGPRIORITYCLASS_HIGH = 4, D3DKMT_SCHEDULINGPRIORITYCLASS_REALTIME = 5;
    const int KMTQAITYPE_WDDM_2_7_CAPS = 70, HWSCH_ENABLED = 2;

    public static void Raise(ID3D11Device device)
    {
        bool privilege = EnablePrivilege("SeIncreaseBasePriorityPrivilege");
        using var dxgi = device.QueryInterface<IDXGIDevice>();
        using var adapter = dxgi.GetAdapter();
        bool hags = HardwareScheduling(adapter.Description.Luid);
        int status = D3DKMTSetProcessSchedulingPriorityClass(GetCurrentProcess(),
            hags ? D3DKMT_SCHEDULINGPRIORITYCLASS_REALTIME : D3DKMT_SCHEDULINGPRIORITYCLASS_HIGH);
        var thread = dxgi.SetGPUThreadPriority(7);
        Console.WriteLine($"GPU priority: privilege {(privilege ? "enabled" : "missing")}, hardware scheduling {(hags ? "on" : "off")}, " +
            $"{(hags ? "realtime" : "high")} class status 0x{status:X8}, thread priority 7 result 0x{thread.Code:X8}");
    }

    static unsafe bool HardwareScheduling(Vortice.Luid luid)
    {
        var open = new OPENADAPTERFROMLUID { LowPart = (uint)luid.LowPart, HighPart = (int)luid.HighPart };
        if (D3DKMTOpenAdapterFromLuid(ref open) != 0) return false;
        try
        {
            uint caps = 0;
            var query = new QUERYADAPTERINFO { Adapter = open.Adapter, Type = KMTQAITYPE_WDDM_2_7_CAPS, Data = (IntPtr)(&caps), DataSize = 4 };
            return D3DKMTQueryAdapterInfo(ref query) == 0 && (caps & HWSCH_ENABLED) != 0;
        }
        finally { D3DKMTCloseAdapter(ref open.Adapter); }
    }

    static bool EnablePrivilege(string name)
    {
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES, out IntPtr token)) return false;
        try
        {
            if (!LookupPrivilegeValue(null, name, out long luid)) return false;
            var state = new TOKEN_PRIVILEGES { PrivilegeCount = 1, Luid = luid, Attributes = SE_PRIVILEGE_ENABLED };
            // It reports success even when the token lacks the privilege; the last error says whether it was granted.
            return AdjustTokenPrivileges(token, false, ref state, 0, IntPtr.Zero, IntPtr.Zero) && Marshal.GetLastWin32Error() == 0;
        }
        finally { CloseHandle(token); }
    }
}
