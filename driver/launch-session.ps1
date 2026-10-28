$ErrorActionPreference = 'Stop'
$shell = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe"
Start-Process -FilePath $shell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSScriptRoot\install-test.ps1`"",'-Session','-DetachFallback') -WindowStyle Hidden | Out-Null
