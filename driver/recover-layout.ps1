param([string]$StatePath = "$PSScriptRoot\logs\normal-layout.json", [int]$WaitSeconds = 180)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $StatePath)) { $StatePath = "$PSScriptRoot\logs\visible-layout.json" }
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ($true) {
    try {
        & "$PSScriptRoot\display-topology.ps1" -Mode Restore -StatePath $StatePath
        # Same lookup as common.ps1; the client is user-writable, so it never runs as SYSTEM (session 0).
        $client = if (Test-Path -LiteralPath "$PSScriptRoot\client-path.txt") {
            (Get-Content -LiteralPath "$PSScriptRoot\client-path.txt" -TotalCount 1).Trim()
        } else { "$PSScriptRoot\client\PanelMirror.exe" }
        if ([Diagnostics.Process]::GetCurrentProcess().SessionId -ne 0 -and (Test-Path -LiteralPath $client)) {
            & $client --restore-windows
        }
        break
    } catch {
        if ((Get-Date) -ge $deadline) { throw }
        Start-Sleep -Seconds 1
    }
}
