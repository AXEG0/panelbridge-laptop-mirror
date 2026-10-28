using System.Runtime.InteropServices;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace PanelMirror;

// A game that keeps the GPU busy makes the mirror's copy wait behind its frames (about 100 ms each in RE4),
// so the panel drops to a few fps. Raising the mirror's GPU priority lets the copy go first, as OBS does for
// game capture. Both calls need SeIncreaseBasePriorityPrivilege, which an elevated process holds but must enable.
static class GpuPriority
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct TOKEN_PRIVILEGES { public int PrivilegeCount; public long Luid; public int Attributes; }

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

    const int TOKEN_ADJUST_PRIVILEGES = 0x20, SE_PRIVILEGE_ENABLED = 2;
    const int D3DKMT_SCHEDULINGPRIORITYCLASS_HIGH = 4;

    public static void Raise(ID3D11Device device)
    {
        bool privilege = EnablePrivilege("SeIncreaseBasePriorityPrivilege");
        int status = D3DKMTSetProcessSchedulingPriorityClass(GetCurrentProcess(), D3DKMT_SCHEDULINGPRIORITYCLASS_HIGH);
        using var dxgi = device.QueryInterface<IDXGIDevice>();
        var thread = dxgi.SetGPUThreadPriority(7);
        Console.WriteLine($"GPU priority: privilege {(privilege ? "enabled" : "missing")}, " +
            $"high class status 0x{status:X8}, thread priority 7 result 0x{thread.Code:X8}");
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
