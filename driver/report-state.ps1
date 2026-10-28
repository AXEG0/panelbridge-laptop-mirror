. "$PSScriptRoot\common.ps1"
Assert-Administrator
$recovery = Join-Path $env:ProgramData 'PanelBridgeRecovery\logs'
foreach ($name in @('rollback.log','install-result.txt','topology.json')) {
    $path = Join-Path $recovery $name
    if (Test-Path -LiteralPath $path) {
        Copy-Item -LiteralPath $path -Destination "$PSScriptRoot\logs\recovery-$name" -Force
    }
}
Get-PnpDevice -PresentOnly | Where-Object FriendlyName -match 'PanelBridge|Basic Display' |
    Select-Object FriendlyName,InstanceId,Status | ConvertTo-Json |
    Set-Content -Encoding UTF8 "$PSScriptRoot\logs\reported-devices.json"
'REPORT_COMPLETE' | Set-Content "$PSScriptRoot\logs\report-result.txt"
