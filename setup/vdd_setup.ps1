# Elevated: puts the iGPU back on Microsoft Basic Display (takes effect after reboot) and installs the
# Virtual Display Driver as a root device rendered by the NVIDIA GPU.
param([Parameter(Mandatory)][string]$VddDir)
Start-Transcript "$PSScriptRoot\vdd_setup.log" -Force | Out-Null

Get-WindowsDriver -Online | Where-Object { $_.OriginalFileName -like '*\iigd_dch.inf' } | ForEach-Object {
    "Removing Intel driver $($_.Driver) ($($_.Version))"
    pnputil /delete-driver $_.Driver /uninstall /force
}

New-Item -ItemType Directory -Force C:\VirtualDisplayDriver | Out-Null
@'
<?xml version='1.0' encoding='utf-8'?>
<vdd_settings>
    <monitors>
        <count>1</count>
    </monitors>
    <gpu>
        <friendlyname>NVIDIA GeForce RTX 3070 Laptop GPU</friendlyname>
    </gpu>
    <global>
        <g_refresh_rate>60</g_refresh_rate>
        <g_refresh_rate>120</g_refresh_rate>
        <g_refresh_rate>240</g_refresh_rate>
    </global>
    <resolutions>
        <resolution>
            <width>1920</width>
            <height>1080</height>
            <refresh_rate>60</refresh_rate>
        </resolution>
    </resolutions>
    <options>
        <CustomEdid>false</CustomEdid>
        <PreventSpoof>false</PreventSpoof>
        <EdidCeaOverride>false</EdidCeaOverride>
        <HardwareCursor>false</HardwareCursor>
        <SDR10bit>false</SDR10bit>
        <HDRPlus>false</HDRPlus>
        <logging>true</logging>
        <debuglogging>false</debuglogging>
    </options>
</vdd_settings>
'@ | Set-Content C:\VirtualDisplayDriver\vdd_settings.xml -Encoding utf8

# Same steps as "devcon install": create a Root\MttVDD device node, then bind the INF to it.
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class RootDevice {
  [StructLayout(LayoutKind.Sequential)] struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool SetupDiGetINFClass(string inf, out Guid cls, StringBuilder name, int size, IntPtr req);
  [DllImport("setupapi.dll", SetLastError=true)] static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid cls, IntPtr hwnd);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool SetupDiCreateDeviceInfo(IntPtr set, string name, ref Guid cls, string desc, IntPtr hwnd, int flags, ref SP_DEVINFO_DATA data);
  [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool SetupDiSetDeviceRegistryProperty(IntPtr set, ref SP_DEVINFO_DATA data, int prop, byte[] buf, int size);
  [DllImport("setupapi.dll", SetLastError=true)] static extern bool SetupDiCallClassInstaller(int fn, IntPtr set, ref SP_DEVINFO_DATA data);
  [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
  [DllImport("newdev.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr hwnd, string hwid, string inf, int flags, out bool reboot);
  public static string Install(string inf, string hwid) {
    Guid cls; var name = new StringBuilder(64);
    if (!SetupDiGetINFClass(inf, out cls, name, 64, IntPtr.Zero)) return "SetupDiGetINFClass failed " + Marshal.GetLastWin32Error();
    IntPtr set = SetupDiCreateDeviceInfoList(ref cls, IntPtr.Zero);
    try {
      var d = new SP_DEVINFO_DATA(); d.cbSize = Marshal.SizeOf(d);
      if (!SetupDiCreateDeviceInfo(set, name.ToString(), ref cls, null, IntPtr.Zero, 1 /*DICD_GENERATE_ID*/, ref d)) return "SetupDiCreateDeviceInfo failed " + Marshal.GetLastWin32Error();
      byte[] id = Encoding.Unicode.GetBytes(hwid + "\0\0");
      if (!SetupDiSetDeviceRegistryProperty(set, ref d, 1 /*SPDRP_HARDWAREID*/, id, id.Length)) return "Set hardware id failed " + Marshal.GetLastWin32Error();
      if (!SetupDiCallClassInstaller(0x19 /*DIF_REGISTERDEVICE*/, set, ref d)) return "DIF_REGISTERDEVICE failed " + Marshal.GetLastWin32Error();
    } finally { SetupDiDestroyDeviceInfoList(set); }
    bool reboot;
    if (!UpdateDriverForPlugAndPlayDevices(IntPtr.Zero, hwid, inf, 1 /*INSTALLFLAG_FORCE*/, out reboot)) return "UpdateDriverForPlugAndPlayDevices failed " + Marshal.GetLastWin32Error();
    return "Installed, reboot needed: " + reboot;
  }
}
'@
if (Get-PnpDevice -PresentOnly | Where-Object HardwareID -contains 'Root\MttVDD') {
    'Virtual Display Driver already present'
} else {
    [RootDevice]::Install("$VddDir\MttVDD.inf", 'Root\MttVDD')
}
Get-PnpDevice -Class Display -PresentOnly | Format-Table FriendlyName, Status, InstanceId -AutoSize | Out-String -Width 200
Stop-Transcript | Out-Null
