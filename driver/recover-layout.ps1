param([string]$StatePath = "$PSScriptRoot\logs\normal-layout.json", [int]$WaitSeconds = 180, [int]$MissingPanelSeconds = 0)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $StatePath)) { $StatePath = "$PSScriptRoot\logs\visible-layout.json" }
$deadline = (Get-Date).AddSeconds($WaitSeconds)
# A missing panel output may need the Basic Display rebind first, so the caller can stop waiting early.
$panelDeadline = if ($MissingPanelSeconds -gt 0) { (Get-Date).AddSeconds($MissingPanelSeconds) } else { $deadline }
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
        if ($_.Exception.Message -like 'Primary display not present yet*' -and (Get-Date) -ge $panelDeadline) { throw }
        Start-Sleep -Seconds 1
    }
}
