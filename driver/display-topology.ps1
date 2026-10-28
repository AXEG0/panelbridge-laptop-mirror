param([ValidateSet('Snapshot','Detach','Restore','StageRestore')][string]$Mode,
    [string]$StatePath = "$PSScriptRoot\logs\topology.json")
$ErrorActionPreference = 'Stop'
if (!('PanelBridgeTopology' -as [type])) {
    Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class PanelBridgeTopology {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct Device {
  public int cb;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string Name;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string Description;
  public int Flags;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string Id;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string Key;
 }
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct DevMode {
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string DeviceName;
  public short SpecVersion,DriverVersion,Size,Extra;
  public int Fields,X,Y,Orientation,FixedOutput;
  public short Color,Duplex,YResolution,TTOption,Collate;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string FormName;
  public short LogPixels;
  public int BitsPerPixel,Width,Height,DisplayFlags,Frequency,ICMMethod,ICMIntent,
      MediaType,DitherType,Reserved1,Reserved2,PanningWidth,PanningHeight;
 }
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool EnumDisplayDevices(string name,uint index,ref Device device,uint flags);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool EnumDisplaySettings(string name,int mode,ref DevMode settings);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string name,ref DevMode settings,IntPtr hwnd,int flags,IntPtr param);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string name,IntPtr settings,IntPtr hwnd,int flags,IntPtr param);
 public static Device[] Devices() {
  var list=new List<Device>();
  for(uint i=0;;i++) { var d=new Device {cb=Marshal.SizeOf(typeof(Device))};
   if(!EnumDisplayDevices(null,i,ref d,0))break; list.Add(d); }
  return list.ToArray();
 }
 public static DevMode Current(string name) {
  var m=new DevMode {Size=(short)Marshal.SizeOf(typeof(DevMode))};
  if(!EnumDisplaySettings(name,-1,ref m))throw new InvalidOperationException("No current mode for "+name);
  return m;
 }
 public static void Place(string name,int x,int y,int width,int height,bool primary) {
  var m=new DevMode {Size=(short)Marshal.SizeOf(typeof(DevMode)),Fields=0x180020,
      X=x,Y=y,Width=width,Height=height};
  int result=ChangeDisplaySettingsEx(name,ref m,IntPtr.Zero,0x10000001|(primary?0x10:0),IntPtr.Zero);
  if(result!=0)throw new InvalidOperationException("Display layout rejected for "+name+": "+result);
 }
 public static void Apply() {
  int result=ChangeDisplaySettingsEx(null,IntPtr.Zero,IntPtr.Zero,0,IntPtr.Zero);
  if(result!=0)throw new InvalidOperationException("Display layout apply failed: "+result);
 }
 [DllImport("user32.dll",SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetUserObjectInformation(IntPtr handle,int index,System.Text.StringBuilder text,int size,out int needed);
 [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr handle);
 public static bool InputAvailable() {
  var desktop=OpenInputDesktop(0,false,1);
  if(desktop==IntPtr.Zero)return false;
  try { int needed; var text=new System.Text.StringBuilder(128);
   return GetUserObjectInformation(desktop,2,text,256,out needed) && text.ToString().Equals("Default",StringComparison.OrdinalIgnoreCase);
  } finally { CloseDesktop(desktop); }
 }
}
'@
}
if ($Mode -eq 'Snapshot') {
    $state = foreach ($d in [PanelBridgeTopology]::Devices()) {
        if ($d.Flags -band 1) {
            $m = [PanelBridgeTopology]::Current($d.Name)
            [PSCustomObject]@{Id=$d.Id; Name=$d.Name; Primary=[bool]($d.Flags -band 4); X=$m.X;Y=$m.Y;Width=$m.Width;Height=$m.Height}
        }
    }
    if (!$state) { throw 'No interactive display layout is available.' }
    $state | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath $StatePath
} elseif ($Mode -eq 'Detach') {
    if (!(Test-Path -LiteralPath $StatePath)) { throw 'Saved display layout is required before detaching.' }
    $devices = [PanelBridgeTopology]::Devices()
    $fallback = $devices | Where-Object { $_.Id -ieq 'ROOT\BasicDisplay' -and ($_.Flags -band 1) } | Select-Object -First 1
    $virtual = $devices | Where-Object { $_.Id -ieq 'Root\MttVDD' -and ($_.Flags -band 1) } | Select-Object -First 1
    if (!$fallback -or !$virtual) { throw 'Expected an attached fallback output and VDD before this test.' }
    $m = [PanelBridgeTopology]::Current($virtual.Name)
    [PanelBridgeTopology]::Place($virtual.Name,0,0,$m.Width,$m.Height,$true)
    [PanelBridgeTopology]::Place($fallback.Name,0,0,0,0,$false)
    [PanelBridgeTopology]::Apply()
    $stillAttached = [PanelBridgeTopology]::Devices() | Where-Object { $_.Id -ieq 'ROOT\BasicDisplay' -and ($_.Flags -band 1) }
    if ($stillAttached) { throw 'Windows kept the fallback output attached; direct presentation remains blocked.' }
    Write-Output 'Fallback output detached from the desktop.'
} else {
    if ($Mode -eq 'Restore' -and ![PanelBridgeTopology]::InputAvailable()) {
        throw 'The secure desktop is active; display recovery must wait for the prompt to close.'
    }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $devices = [PanelBridgeTopology]::Devices()
    foreach ($saved in $state | Sort-Object Primary -Descending) {
        $d = $devices | Where-Object Id -ieq $saved.Id | Select-Object -First 1
        if (!$d) { Write-Output "Display no longer present: $($saved.Id)"; continue }
        [PanelBridgeTopology]::Place($d.Name,$saved.X,$saved.Y,$saved.Width,$saved.Height,$saved.Primary)
    }
    if ($Mode -eq 'Restore') {
        [PanelBridgeTopology]::Apply()
        Write-Output 'Original display layout restored.'
    } else { Write-Output 'Normal display layout staged for the next login/restart; current mirror layout retained.' }
}
