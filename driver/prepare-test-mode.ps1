param([string]$Backup)
. "$PSScriptRoot\common.ps1"
Assert-Administrator
Start-Transcript -Path "$PSScriptRoot\logs\prepare.log" -Force | Out-Null
try {
    $manifest = Assert-Package
    $device = Get-PnpDevice -InstanceId $DeviceId -PresentOnly
    if ($device.FriendlyName -ne 'Microsoft Basic Display Adapter') {
        throw "Expected the Intel GPU on Basic Display, found $($device.FriendlyName)."
    }
    $secureBoot = Confirm-SecureBootUEFI
    $integrity = [PanelBridgeNative]::IntegrityOptions()
    if ($secureBoot) { throw 'Secure Boot is enabled; leave the active driver unchanged.' }
    if ($integrity -band 0x400) { throw 'HVCI is active; leave the active driver unchanged.' }
    $state = [ordered]@{
        CapturedAt = (Get-Date).ToString('o'); DeviceId = $DeviceId
        IntegrityOptions = $integrity; SecureBoot = $secureBoot
        OriginalDriver = (Get-CimInstance Win32_PnPSignedDriver | Where-Object DeviceID -eq $DeviceId |
            Select-Object DeviceName,InfName,DriverVersion)
        Backup = $Backup
    }
    if ($Backup -and !(Test-Path -LiteralPath $Backup)) { throw "Backup not found: $Backup" }
    if (!(Test-Path -LiteralPath "$PSScriptRoot\logs\original-state.json")) {
        $state | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 "$PSScriptRoot\logs\original-state.json"
    }
    & bcdedit.exe /enum all | Set-Content -Encoding UTF8 "$PSScriptRoot\logs\preparation-bcd.txt"
    if ($LASTEXITCODE) { throw 'Could not read boot configuration.' }
    if (!(Test-Path -LiteralPath "$PSScriptRoot\logs\original-bcd.txt")) {
        Copy-Item -LiteralPath "$PSScriptRoot\logs\preparation-bcd.txt" -Destination "$PSScriptRoot\logs\original-bcd.txt"
    }
    Import-Certificate -FilePath "$PSScriptRoot\package\PanelBridge.cer" -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Import-Certificate -FilePath "$PSScriptRoot\package\PanelBridge.cer" -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
    & bcdedit.exe /set testsigning on
    if ($LASTEXITCODE) { throw 'Could not enable test signing.' }
    & bcdedit.exe /enum | Set-Content -Encoding UTF8 "$PSScriptRoot\logs\prepared-bcd.txt"
    'READY_FOR_RESTART' | Set-Content "$PSScriptRoot\logs\prepare-result.txt"
    Write-Output 'Test signing configured. Restart with HDMI unplugged. The active display driver has not been replaced.'
} catch {
    $_ | Out-String | Set-Content "$PSScriptRoot\logs\prepare-error.txt"
    throw
} finally { Stop-Transcript | Out-Null }
