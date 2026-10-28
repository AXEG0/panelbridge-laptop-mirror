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
 // A staged removal of a non-primary output is rejected on Apply (-5); removing it immediately works.
 public static void Remove(string name) {
  var m=new DevMode {Size=(short)Marshal.SizeOf(typeof(DevMode)),Fields=0x180020};
  int result=ChangeDisplaySettingsEx(name,ref m,IntPtr.Zero,1,IntPtr.Zero);
  if(result!=0)throw new InvalidOperationException("Display removal rejected for "+name+": "+result);
 }
 [StructLayout(LayoutKind.Sequential)] public struct Luid { public uint Low; public int High; }
 [StructLayout(LayoutKind.Sequential)] public struct PathInfo {
  public Luid SourceAdapter; public uint SourceId,SourceMode,SourceStatus;
  public Luid TargetAdapter; public uint TargetId,TargetMode,Output,Rotation,Scaling,RefreshNum,RefreshDen,ScanLine;
  public int TargetAvailable; public uint TargetStatus,Flags;
 }
 [StructLayout(LayoutKind.Sequential)] public struct ModeInfo { public uint Type,Id; public Luid Adapter; public ulong A,B,C,D,E,F; }
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct SourceName {
  public uint Type,Size; public Luid Adapter; public uint Id;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string Gdi;
 }
 [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags,out uint paths,out uint modes);
 [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags,ref uint paths,[Out] PathInfo[] pathArray,ref uint modes,[Out] ModeInfo[] modeArray,IntPtr topology);
 [DllImport("user32.dll")] static extern int SetDisplayConfig(uint paths,[In] PathInfo[] pathArray,uint modes,[In] ModeInfo[] modeArray,uint flags);
 [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref SourceName info);
 static string SourceGdi(PathInfo p) {
  var s=new SourceName {Type=1,Size=(uint)Marshal.SizeOf(typeof(SourceName)),Adapter=p.SourceAdapter,Id=p.SourceId};
  return DisplayConfigGetDeviceInfo(ref s)==0 ? s.Gdi : null;
 }
 // ChangeDisplaySettingsEx cannot re-attach a removed IddCx output (-1), so add its path through CCD.
 public static void Activate(string name) {
  uint pathCount,modeCount;
  int result=GetDisplayConfigBufferSizes(1,out pathCount,out modeCount);
  if(result!=0)throw new InvalidOperationException("Display path query failed: "+result);
  var paths=new PathInfo[pathCount]; var modes=new ModeInfo[modeCount];
  result=QueryDisplayConfig(1,ref pathCount,paths,ref modeCount,modes,IntPtr.Zero);
  if(result!=0)throw new InvalidOperationException("Display path query failed: "+result);
  var active=new List<PathInfo>(); PathInfo? added=null;
  for(int i=0;i<pathCount;i++) {
   if((paths[i].Flags&1)!=0) active.Add(paths[i]);
   else if(added==null && paths[i].TargetAvailable!=0 && SourceGdi(paths[i])==name) added=paths[i];
  }
  if(added==null)throw new InvalidOperationException("No available display path for "+name);
  var path=added.Value; path.Flags|=1; path.SourceMode=0xFFFFFFFF; path.TargetMode=0xFFFFFFFF; active.Add(path);
  // SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES
  result=SetDisplayConfig((uint)active.Count,active.ToArray(),modeCount,modes,0x80|0x20|0x400);
  if(result!=0)throw new InvalidOperationException("Display path activation failed for "+name+": "+result);
 }
 // A re-attached VDD comes back at 60 Hz; the mirror was tuned with it at its fastest mode.
 public static int Fastest(string name) {
  var current=Current(name); int best=current.Frequency;
  for(int i=0;;i++) {
   var m=new DevMode {Size=(short)Marshal.SizeOf(typeof(DevMode))};
   if(!EnumDisplaySettings(name,i,ref m))break;
   if(m.Width==current.Width && m.Height==current.Height && m.Frequency>best) best=m.Frequency;
  }
  if(best==current.Frequency)return best;
  // ChangeDisplaySettingsEx refuses mode changes on the VDD (-1); ask CCD for the rate instead.
  uint pathCount,modeCount;
  if(GetDisplayConfigBufferSizes(2,out pathCount,out modeCount)!=0)return current.Frequency;
  var paths=new PathInfo[pathCount]; var modes=new ModeInfo[modeCount];
  if(QueryDisplayConfig(2,ref pathCount,paths,ref modeCount,modes,IntPtr.Zero)!=0)return current.Frequency;
  for(int i=0;i<pathCount;i++) if(SourceGdi(paths[i])==name) {
   paths[i].TargetMode=0xFFFFFFFF; paths[i].RefreshNum=(uint)best; paths[i].RefreshDen=1;
  }
  SetDisplayConfig(pathCount,paths,modeCount,modes,0x80|0x20|0x400);
  return Current(name).Frequency;
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
    # After a restart the panel starts on the PCI adapter; the ROOT fallback output only
    # appears a few seconds after PanelBridge takes that device, and may not be attached yet.
    # The VDD stays off the desktop outside mirror sessions, so attach it here; the layout change
    # caused by the driver bind can detach it again, so keep retrying until the deadline.
    $deadline = (Get-Date).AddSeconds(20)
    $nextAttach = Get-Date
    $attached = $false
    do {
        $devices = [PanelBridgeTopology]::Devices()
        $fallback = $devices | Where-Object { $_.Id -ieq 'ROOT\BasicDisplay' } | Select-Object -First 1
        $virtual = $devices | Where-Object { $_.Id -ieq 'Root\MttVDD' -and ($_.Flags -band 1) } | Select-Object -First 1
        if ($fallback -and $virtual) {
            if ($attached) {
                try { Write-Output "VDD refresh: $([PanelBridgeTopology]::Fastest($virtual.Name)) Hz" }
                catch { Write-Output "VDD refresh unchanged: $($_.Exception.Message)" }
            }
            break
        }
        $detached = $devices | Where-Object { $_.Id -ieq 'Root\MttVDD' } | Select-Object -First 1
        if ($fallback -and $detached -and (Get-Date) -ge $nextAttach) {
            try { [PanelBridgeTopology]::Activate($detached.Name); $attached = $true; Write-Output 'VDD attached to the desktop.' }
            catch { Write-Output "VDD attach retry: $($_.Exception.Message)" }
            $nextAttach = (Get-Date).AddSeconds(2)
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    if (!$fallback -or !$virtual) { throw 'Expected the fallback output and an attached VDD before this test.' }
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
    # The panel is either the Intel PCI output (fresh boot) or the ROOT fallback (after a switch).
    $panelIds = @('ROOT\BasicDisplay','PCI\VEN_8086&DEV_9A49&SUBSYS_160C1043&REV_01')
    foreach ($saved in $state | Sort-Object Primary -Descending) {
        $d = $devices | Where-Object Id -ieq $saved.Id | Select-Object -First 1
        if (!$d -and $panelIds -icontains $saved.Id) { $d = $devices | Where-Object { $panelIds -icontains $_.Id } | Select-Object -First 1 }
        if (!$d) {
            # Never leave the invisible VDD as the only desktop; recover-layout retries until the panel returns.
            if ($saved.Primary) { throw "Primary display not present yet: $($saved.Id)" }
            Write-Output "Display no longer present: $($saved.Id)"; continue
        }
        [PanelBridgeTopology]::Place($d.Name,$saved.X,$saved.Y,$saved.Width,$saved.Height,$saved.Primary)
    }
    $vdd = [PanelBridgeTopology]::Devices() | Where-Object { $_.Id -ieq 'Root\MttVDD' -and ($_.Flags -band 1) } | Select-Object -First 1
    $savedVdd = $state | Where-Object Id -ieq 'Root\MttVDD' | Select-Object -First 1
    if ($Mode -eq 'Restore') {
        [PanelBridgeTopology]::Apply()
        Write-Output 'Original display layout restored.'
        # The VDD is only needed while mirroring; left attached it is an invisible screen that windows open on.
        $others = [PanelBridgeTopology]::Devices() | Where-Object { $_.Id -ine 'Root\MttVDD' -and ($_.Flags -band 1) }
        if ($vdd -and !$savedVdd.Primary -and $others) {
            try { [PanelBridgeTopology]::Remove($vdd.Name); Write-Output 'VDD removed from the desktop.' }
            catch { Write-Output "VDD left attached: $($_.Exception.Message)" }
        }
    } else {
        # Keep the VDD staged to the left so a game's mode reset never removes the display it runs on.
        if ($vdd -and !$savedVdd) {
            $m = [PanelBridgeTopology]::Current($vdd.Name)
            $left = ($state | Measure-Object X -Minimum).Minimum - $m.Width
            [PanelBridgeTopology]::Place($vdd.Name,$left,0,$m.Width,$m.Height,$false)
        }
        Write-Output 'Normal display layout staged for the next login/restart; current mirror layout retained.'
    }
}
