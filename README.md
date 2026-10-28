# PanelBridge

Play games rendered by the NVIDIA GPU on a laptop's built-in screen when the Intel graphics driver can't
drive that screen.

## The problem

On some Optimus laptops without a MUX switch, the built-in screen is wired only to the Intel iGPU. The
NVIDIA GPU can render, but every frame reaches the screen through the Intel driver. On the tested
laptop, the Intel driver makes the screen flicker or go black, which points to a faulty panel or eDP
cable. Tuning PSR, refresh rate and other driver settings didn't help.

Without the Intel driver, Windows falls back to *Microsoft Basic Display Adapter*. That keeps the
screen working but forces slow software compositing: about 25 fps even for frames the NVIDIA GPU
renders. So the usual choices were an external monitor, about 25 fps, or replacing hardware.

PanelBridge gets around this without the Intel driver.

## The solution

The panel stays on the image the firmware set up at boot. A virtual monitor (an IddCx Virtual Display
Driver) is rendered by the NVIDIA GPU. A small user-mode client captures it with DXGI Desktop
Duplication, and an experimental KMDF driver copies each frame into the panel's firmware framebuffer.

> [!WARNING]
> This is an experimental kernel driver, tested on **one laptop model only**. It needs Windows
> test-signing mode with Secure Boot and HVCI off. Games with kernel anti-cheat usually refuse to run
> in test-signing mode. A mistake can leave the built-in screen black until a restart. There is no
> warranty: use it only if you can recover a machine without its built-in screen, for example over HDMI.

## Supported hardware

- ASUS TUF Dash F15 class laptop: Intel Iris Xe `PCI\VEN_8086&DEV_9A49&SUBSYS_160C1043` (panel) and
  an NVIDIA RTX 3070 Laptop GPU. The driver refuses other devices.
- The firmware must leave exactly one enabled, linear, unrotated 1920x1080 BGRX plane inside the
  graphics aperture. Other layouts expose diagnostics but reject frames.
- On the tested laptop, the firmware lights the panel only if HDMI is unplugged at power-on.

## Results

- In a demanding DX12 game capped at 60 fps, the panel showed a steady 60 fps. Capture and copy took
  about 2–4 ms per frame.
- With the GPU fully loaded (*Resident Evil 4* with a DLSS neural-rendering mod, about 35 fps), every game
  frame reached the panel over a 30-minute session. Before readback copies were pipelined, a busy GPU
  held the panel to about 12 fps.
- The earlier user-mode mirror through Windows' Basic Display output was limited to about 25 fps.

## How it works

1. The Intel GPU is left on *Microsoft Basic Display Adapter*, the generic driver, and never runs the
   Intel driver.
2. During a session, `install-test.ps1` binds PanelBridge to the Intel PCI function as a System-class
   KMDF 1.15 driver. It does the following:
   - It reads the plane registers through the MMIO BAR and validates the framebuffer.
   - It maps only that range of the aperture BAR.
   - It accepts pixel buffers through an IOCTL that only administrators and SYSTEM can open.
   - It never writes GPU registers or changes eDP timing, link or power. It is **not** a WDDM driver.
3. Windows keeps its own firmware fallback output (`ROOT\BASICDISPLAY`), which draws into the same
   framebuffer. The session attaches the virtual display (it stays off the desktop otherwise, so
   windows cannot open on an invisible screen), detaches that output and makes the virtual display
   primary. The client stops writing, and ends the session, if Windows reattaches it.
4. The client (`PanelMirror.exe --driver`) raises its GPU scheduling priority so a busy game cannot
   starve the capture. It then copies every new frame of the virtual display to the panel.
5. A watchdog restores the normal layout and Basic Display and removes the driver package when the
   client exits. A startup task as SYSTEM does the same if the PC restarts during a session.

## Requirements

- Windows 11 x64; Secure Boot and HVCI off.
- [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver) (`Root\MttVDD`),
  rendering on the NVIDIA GPU at 1920x1080.
- .NET 10 SDK.
- LLVM 20.1.8, extracted to `driver\tools\llvm`, or pass `-Llvm <bin folder>` to `build.ps1`.
- Microsoft WDK/SDK NuGet packages 10.0.26100.6584. A `.nupkg` is a zip file; extract them as follows:

  | Package | Folder |
  |---|---|
  | `Microsoft.Windows.WDK.x64` | `driver\tools\wdk` |
  | `Microsoft.Windows.SDK.CPP` | `driver\tools\sdk` |
  | `Microsoft.Windows.SDK.CPP.x64` | `driver\tools\sdk-x64` |

## Build

```powershell
powershell -ExecutionPolicy Bypass -File driver\build.ps1   # driver, layout boundary tests, INF check, catalog
powershell -ExecutionPolicy Bypass -File driver\sign.ps1    # creates a local, non-exportable test certificate and signs
dotnet publish PanelMirror.csproj -c Release -o driver\client
```

`build.ps1` fails the build if the image has the `TERMINAL_SERVER_AWARE` flag set. lld sets that flag
by default, and Windows then refuses to load the driver (Win32 error 487).

## One-time setup (administrator)

1. `setup\vdd_setup.ps1 -VddDir <folder containing MttVDD.inf>`
   - **This removes the Intel graphics driver package** (`iigd_dch.inf`), so the Intel GPU falls back to
     Basic Display after a restart.
   - It also installs the Virtual Display Driver and writes `C:\VirtualDisplayDriver\vdd_settings.xml`.
     Edit the GPU name there if yours differs.
2. `driver\prepare-test-mode.ps1 [-Backup <path to your backup>]`
   - It records the original device and boot state in `driver\logs`.
   - It trusts the local test certificate and turns on test signing.
3. Check that `$DeviceId` in `driver\common.ps1` matches your Intel GPU:
   `Get-PnpDevice | ? InstanceId -like 'PCI\VEN_8086&DEV_9A49*'`.
4. Restart with HDMI unplugged.

## Use

- Run `driver\launch-session.ps1`, or a desktop shortcut to it, and approve the prompt while the laptop
  screen is still primary.
- **Ctrl+Alt+F12** ends the session and restores the normal display.
- In games, choose the virtual display and cap the frame rate at 60, the panel's firmware mode. Some
  games remember the monitor. For example, *Resident Evil 4* stores it as `DisplayName` in
  `local_config.ini`, and a game pointed at the laptop screen ends the session.
- Games that reset the display mode, for example on alt-tab out of exclusive fullscreen, make Windows
  reattach its own laptop-screen output. The mirror detaches it again, up to three times a minute, before
  it ends the session. Prefer exclusive fullscreen: *Resident Evil 4* resets the mode when it starts in
  borderless and then ran at a few fps.
- Don't run the launcher again while a session is running. Its administrator prompt ends the session.
- **Administrator prompts can't be shown.** The secure desktop can't be captured, so the mirror closes
  and the screen looks frozen. Press Esc once to cancel a hidden prompt; Ctrl+Alt+Del also cancels it.
  Do administrator work, including one-time game installers, without a session running.

## Recovery and uninstall

- Run `driver\rollback.ps1` as administrator for an immediate rollback. If the panel stays blank,
  restart with HDMI unplugged.
- To uninstall completely:
  1. Run `rollback.ps1`.
  2. Run `bcdedit /set testsigning off` (the original boot settings are in `driver\logs\original-bcd.txt`).
  3. Remove the `CN=PanelBridge Local Test` certificate from LocalMachine Root and TrustedPublisher and
     from CurrentUser My.
  4. Delete `C:\ProgramData\PanelBridgeRecovery`.

## Limitations

- CPU copies have no vblank sync, so tearing is possible.
- Only 1920x1080 BGRX is supported.
- Sleep/resume is untested.
- Secure-desktop frames can't be mirrored.

## References

- [Intel Tiger Lake PRM, volume 12: display engine](https://cdrdv2-public.intel.com/705833/intel-gfx-prm-osrc-tgl-vol-12-display-engine.pdf)
- [Linux i915 plane register definitions, v6.16](https://github.com/torvalds/linux/blob/v6.16/drivers/gpu/drm/i915/display/skl_universal_plane_regs.h)
- [Microsoft: raw and translated resources](https://learn.microsoft.com/en-us/windows-hardware/drivers/wdf/raw-and-translated-resources)
- [Microsoft: WDK NuGet distribution](https://learn.microsoft.com/en-us/windows-hardware/drivers/install-the-wdk-using-nuget)

## License

MIT, see [LICENSE](LICENSE).
