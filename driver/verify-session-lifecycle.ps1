. "$PSScriptRoot\common.ps1"
Assert-Administrator
try {
    $started = Get-Date
    & "$PSScriptRoot\install-test.ps1" -Session -DetachFallback -SessionSeconds 5
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $client = Get-CimInstance Win32_Process -Filter "Name='PanelMirror.exe'" |
            Where-Object ExecutablePath -eq "$PSScriptRoot\client\PanelMirror.exe"
        $device = Get-PnpDevice -InstanceId $DeviceId
        $result = Get-Item -LiteralPath "$env:ProgramData\PanelBridgeRecovery\logs\install-result.txt" -ErrorAction SilentlyContinue
        if (!$client -and $device.FriendlyName -eq 'Microsoft Basic Display Adapter' -and $result -and $result.LastWriteTime -ge $started) { break }
        Start-Sleep -Seconds 1
    }
    & "$PSScriptRoot\display-topology.ps1" -Mode Snapshot -StatePath "$PSScriptRoot\logs\lifecycle-layout.json"
    $layout = Get-Content -LiteralPath "$PSScriptRoot\logs\lifecycle-layout.json" -Raw | ConvertFrom-Json
    $panel = $layout | Where-Object { $_.Id -ieq 'ROOT\BasicDisplay' -and $_.Primary }
    if (!$panel -or $client -or $device.FriendlyName -ne 'Microsoft Basic Display Adapter') {
        throw 'Session shutdown did not restore the normal display state.'
    }
    & "$PSScriptRoot\report-state.ps1"
    'SESSION_EXITED_LAYOUT_RESTORED' | Set-Content "$PSScriptRoot\logs\install-result.txt"
    'PASSED' | Set-Content "$PSScriptRoot\logs\lifecycle-result.txt"
} catch {
    $_ | Out-String | Set-Content "$PSScriptRoot\logs\lifecycle-error.txt"
    throw
}
