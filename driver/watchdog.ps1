param([int]$Seconds = 90, [switch]$Session)
$ErrorActionPreference = 'Stop'
if ($Session) {
    $path = "$PSScriptRoot\logs\session.json"
    $deadline = (Get-Date).AddSeconds(30)
    while (!(Test-Path -LiteralPath $path) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    if (Test-Path -LiteralPath $path) {
        $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        while ($true) {
            $client = Get-Process -Id $state.ProcessId -ErrorAction SilentlyContinue
            if (!$client) { break }
            try { if ($client.StartTime.ToUniversalTime().Ticks.ToString() -ne $state.StartTicks) { break } }
            catch { break }
            Start-Sleep -Seconds 1
        }
    }
} else {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
}
& "$PSScriptRoot\rollback.ps1"
