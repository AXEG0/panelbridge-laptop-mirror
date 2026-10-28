. "$PSScriptRoot\common.ps1"
Assert-Administrator
Start-Transcript -Path "$PSScriptRoot\logs\rollback.log" -Append | Out-Null
try {
    Get-CimInstance Win32_Process -Filter "Name='PanelMirror.exe'" |
        Where-Object ExecutablePath -eq $ClientPath |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $recoveryPath = Join-Path $env:ProgramData 'PanelBridgeRecovery'
    $layoutState = "$recoveryPath\logs\topology.json"
    $layoutPending = $false
    if (Test-Path -LiteralPath $layoutState) {
        try { & "$recoveryPath\recover-layout.ps1" -StatePath $layoutState -WaitSeconds $(if ($InteractiveSession) { 180 } else { 0 }) -MissingPanelSeconds 5 }
        catch { $layoutPending = $true; Write-Output "Display layout restore needs the interactive session: $($_.Exception.Message)" }
    }
    $fallback = Get-PnpDevice -InstanceId 'ROOT\BASICDISPLAY\0000' -PresentOnly -ErrorAction SilentlyContinue
    if ($fallback) {
        $problem = Get-PnpDeviceProperty -InstanceId $fallback.InstanceId -KeyName DEVPKEY_Device_ProblemCode
        if ($problem.Data -eq 22) { Enable-PnpDevice -InstanceId $fallback.InstanceId -Confirm:$false }
    }
    # The experimental client's binary is separate from the original working mirror.
    Get-CimInstance Win32_Process -Filter "Name='PanelMirror.exe'" |
        Where-Object ExecutablePath -eq $ClientPath |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $device = Get-PnpDevice -InstanceId $DeviceId -PresentOnly
    if ($device.FriendlyName -like 'PanelBridge*') {
        # If the rebind fails, removing the package below still reinstalls the best remaining driver.
        try {
            $reboot = [PanelBridgeNative]::Bind($HardwareId, "$env:windir\INF\display.inf")
            Write-Output "Restored Microsoft Basic Display. Restart needed: $reboot"
        } catch { Write-Output "Basic Display rebind failed, continuing with package removal: $($_.Exception.Message)" }
    }
    # Remove only this experimental package; keep NVIDIA, VDD and Intel extensions.
    Get-WindowsDriver -Online | Where-Object {
        [IO.Path]::GetFileName($_.OriginalFileName) -ieq 'PanelBridge.inf'
    } | ForEach-Object {
        & pnputil.exe /delete-driver $_.Driver /uninstall /force
        if ($LASTEXITCODE -notin @(0,3010)) { throw 'Could not remove the experimental driver package.' }
    }
    # The panel output can return only after the rebind; retry so the VDD is not left as primary.
    if ($layoutPending) {
        try { & "$recoveryPath\recover-layout.ps1" -StatePath $layoutState -WaitSeconds $(if ($InteractiveSession) { 60 } else { 0 }) }
        catch { Write-Output "Display layout restore still pending: $($_.Exception.Message)" }
    }
    if ($InteractiveSession -and (Test-Path -LiteralPath $ClientPath)) { & $ClientPath --restore-windows }
    Unregister-ScheduledTask -TaskName 'PanelBridgeEmergencyRollback' -Confirm:$false -ErrorAction SilentlyContinue
    'ROLLED_BACK' | Set-Content "$PSScriptRoot\logs\install-result.txt"
    Write-Output 'Rollback complete. If the panel remains blank, restart with HDMI unplugged.'
} finally { Stop-Transcript | Out-Null }
