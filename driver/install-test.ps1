param([switch]$DetachFallback, [switch]$Session, [int]$SessionSeconds = 0)
. "$PSScriptRoot\common.ps1"
Assert-Administrator
Start-Transcript -Path "$PSScriptRoot\logs\install.log" -Force | Out-Null
$armed = $false
try {
    $null = Assert-Package
    if (!([PanelBridgeNative]::IntegrityOptions() -band 2)) {
        throw 'Test signing is not active yet. Restart before installing the test driver.'
    }
    if (Confirm-SecureBootUEFI) { throw 'Secure Boot must already be off.' }
    $device = Get-PnpDevice -InstanceId $DeviceId -PresentOnly
    if ($device.FriendlyName -ne 'Microsoft Basic Display Adapter') { throw 'Intel GPU is not on the expected Basic Display driver.' }
    # Recovery runs as SYSTEM, so its code must be writable only by administrators/SYSTEM.
    $recovery = Join-Path $env:ProgramData 'PanelBridgeRecovery'
    New-Item -ItemType Directory -Force $recovery | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $admin = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $acl.SetOwner($admin)
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($identity in @($admin,$system)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $recovery -AclObject $acl
    New-Item -ItemType Directory -Force "$recovery\logs" | Out-Null
    foreach ($name in @('common.ps1','rollback.ps1','watchdog.ps1','display-topology.ps1','recover-layout.ps1')) {
        Copy-Item -LiteralPath "$PSScriptRoot\$name" -Destination $recovery -Force
    }
    "$PSScriptRoot\client\PanelMirror.exe" | Set-Content -Encoding UTF8 -LiteralPath "$recovery\client-path.txt"
    $topologyState = "$recovery\logs\topology.json"
    Remove-Item -LiteralPath $topologyState -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$recovery\logs\session.json" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$recovery\logs\install-result.txt" -Force -ErrorAction SilentlyContinue
    if ($DetachFallback) {
        & "$recovery\display-topology.ps1" -Mode Snapshot -StatePath $topologyState
        Copy-Item -LiteralPath $topologyState -Destination "$PSScriptRoot\logs\normal-layout.json" -Force
    }
    $shell = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
    # A crash/reboot before acceptance restores Basic Display automatically at startup.
    $action = New-ScheduledTaskAction -Execute $shell -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$recovery\watchdog.ps1`" -Seconds 30"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName 'PanelBridgeEmergencyRollback' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    # A separate process handles a blank screen or an unresponsive client during this session.
    $watchArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$recovery\watchdog.ps1`"")
    $watchArgs += if ($Session) { @('-Session') } else { @('-Seconds','90') }
    $watchdog = Start-Process -FilePath $shell -ArgumentList $watchArgs -WindowStyle Hidden -PassThru
    $armed = $true
    $reboot = [PanelBridgeNative]::Bind($HardwareId, "$PSScriptRoot\package\PanelBridge.inf")
    if ($reboot) { throw 'Binding requires a restart; rolling back this first test.' }
    Get-PnpDevice -InstanceId $DeviceId | Select-Object FriendlyName,Status,InstanceId |
        ConvertTo-Json | Set-Content -Encoding UTF8 "$PSScriptRoot\logs\device-state.json"
    Get-PnpDeviceProperty -InstanceId $DeviceId -KeyName DEVPKEY_Device_ProblemCode,DEVPKEY_Device_ProblemStatus |
        Select-Object KeyName,Data | ConvertTo-Json | Set-Content -Encoding UTF8 "$PSScriptRoot\logs\device-problem.json"
    $diagnostic = Start-Process -FilePath "$PSScriptRoot\client\PanelMirror.exe" -ArgumentList @('--driver-info','--require-driver-ready') `
        -RedirectStandardOutput "$PSScriptRoot\logs\driver-info.txt" -RedirectStandardError "$PSScriptRoot\logs\driver-info-error.txt" -WindowStyle Hidden -PassThru -Wait
    Get-Content -LiteralPath "$PSScriptRoot\logs\driver-info.txt"
    if ($diagnostic.ExitCode) {
        $message = Get-Content -LiteralPath "$PSScriptRoot\logs\driver-info-error.txt" -Raw
        throw "Driver diagnostic failed (exit $($diagnostic.ExitCode)): $message"
    }
    if ($DetachFallback) {
        & "$recovery\display-topology.ps1" -Mode Detach -StatePath $topologyState
        & "$recovery\display-topology.ps1" -Mode StageRestore -StatePath $topologyState
    }
    $clientArgs = @(if ($Session) { '--driver' } else { '--driver';'--pattern';'--duration';'65' })
    if ($Session -and $SessionSeconds -gt 0) { $clientArgs += @('--duration',$SessionSeconds.ToString()) }
    $client = Start-Process -FilePath "$PSScriptRoot\client\PanelMirror.exe" -ArgumentList $clientArgs `
        -RedirectStandardOutput "$PSScriptRoot\logs\capture.log" -RedirectStandardError "$PSScriptRoot\logs\capture-error.log" -WindowStyle Hidden -PassThru
    $ready = $false
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and !$client.HasExited) {
        $ready = [bool](Select-String -LiteralPath "$PSScriptRoot\logs\capture.log" -Pattern '^Capturing ' -Quiet)
        if ($ready) { break }
        Start-Sleep -Milliseconds 100
    }
    if (!$ready) {
        $message = Get-Content -LiteralPath "$PSScriptRoot\logs\capture-error.log" -Raw
        throw "Framebuffer client did not start capturing: $message"
    }
    Remove-Item -LiteralPath "$PSScriptRoot\logs\install-error.txt" -Force -ErrorAction SilentlyContinue
    if ($Session) {
        @{ProcessId=$client.Id;StartTicks=$client.StartTime.ToUniversalTime().Ticks.ToString()} |
            ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath "$recovery\logs\session.json"
    }
    if ($Session) {
        'SESSION_RUNNING' | Set-Content "$PSScriptRoot\logs\install-result.txt"
        Write-Output "Mirror session PID $($client.Id). Ctrl+Alt+F12 restores the normal display."
    } else {
        'TEST_RUNNING_AUTO_ROLLBACK_90_SECONDS' | Set-Content "$PSScriptRoot\logs\install-result.txt"
        Write-Output "Test client PID $($client.Id). Automatic rollback in 90 seconds."
    }
} catch {
    $_ | Out-String | Set-Content "$PSScriptRoot\logs\install-error.txt"
    if ($watchdog -and !$watchdog.HasExited) { Stop-Process -Id $watchdog.Id -Force -ErrorAction SilentlyContinue }
    if ($armed) { & "$PSScriptRoot\rollback.ps1" }
    throw
} finally { Stop-Transcript | Out-Null }
