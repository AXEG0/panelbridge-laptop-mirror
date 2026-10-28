$ErrorActionPreference = 'Stop'
$HardwareId = 'PCI\VEN_8086&DEV_9A49&SUBSYS_160C1043'
# The instance path of the Intel GPU on the tested laptop; check yours with Get-PnpDevice and edit if it differs.
$DeviceId = 'PCI\VEN_8086&DEV_9A49&SUBSYS_160C1043&REV_01\3&11583659&0&10'
# Recovery copies of these scripts live in ProgramData; install-test.ps1 records where the client is.
$ClientPath = if (Test-Path -LiteralPath "$PSScriptRoot\client-path.txt") {
    (Get-Content -LiteralPath "$PSScriptRoot\client-path.txt" -TotalCount 1).Trim()
} else { "$PSScriptRoot\client\PanelMirror.exe" }
# The startup recovery task runs as SYSTEM in session 0, where moving windows is meaningless and the
# user-writable client must not be run with SYSTEM rights.
$InteractiveSession = [Diagnostics.Process]::GetCurrentProcess().SessionId -ne 0
function Assert-Administrator {
    if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script as administrator.' }
}
function Assert-Package {
    $manifest = Get-Content -LiteralPath "$PSScriptRoot\package\manifest.json" -Raw | ConvertFrom-Json
    foreach ($entry in $manifest.Files.PSObject.Properties) {
        $actual = (Get-FileHash -LiteralPath "$PSScriptRoot\package\$($entry.Name)" -Algorithm SHA256).Hash
        if ($actual -ne $entry.Value) { throw "Package hash mismatch: $($entry.Name)" }
    }
    $manifest
}
if (!('PanelBridgeNative' -as [type])) {
    Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class PanelBridgeNative {
    [StructLayout(LayoutKind.Sequential)] struct CodeIntegrity { public uint Length, Options; }
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int type, ref CodeIntegrity data, int size, out int returned);
    [DllImport("newdev.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr hwnd, string hardwareId, string inf, uint flags, out bool reboot);
    public static uint IntegrityOptions() {
        var info = new CodeIntegrity { Length=8 }; int returned;
        int status = NtQuerySystemInformation(103, ref info, 8, out returned);
        if (status != 0 || returned != 8) throw new InvalidOperationException("Code integrity query failed: " + status);
        return info.Options;
    }
    public static bool Bind(string hardwareId, string inf) {
        bool reboot;
        if (!UpdateDriverForPlugAndPlayDevices(IntPtr.Zero, hardwareId, inf, 1, out reboot))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Driver binding failed: " + inf);
        return reboot;
    }
}
'@
}
