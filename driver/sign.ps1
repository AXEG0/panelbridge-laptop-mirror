$ErrorActionPreference = 'Stop'
$subject = 'CN=PanelBridge Local Test'
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
    Where-Object { $_.Subject -eq $subject -and $_.NotAfter -gt (Get-Date).AddDays(7) } |
    Sort-Object NotAfter -Descending | Select-Object -First 1
if (!$cert) {
    $cert = New-SelfSignedCertificate -Subject $subject -Type CodeSigningCert `
        -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 2048 `
        -HashAlgorithm SHA256 -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears(1)
}
Export-Certificate -Cert $cert -FilePath "$PSScriptRoot\package\PanelBridge.cer" -Force | Out-Null
$signtool = "$PSScriptRoot\tools\sdk\c\bin\10.0.26100.0\x64\signtool.exe"
& $signtool sign /s My /sha1 $cert.Thumbprint /fd SHA256 "$PSScriptRoot\package\PanelBridge.sys"
if ($LASTEXITCODE) { throw 'Driver signing failed' }
# Regenerate the catalog after the embedded signature changes the image bytes.
& "$PSScriptRoot\tools\wdk\c\bin\10.0.26100.0\x86\Inf2Cat.exe" "/driver:$PSScriptRoot\package" /os:10_GE_X64 /uselocaltime
if ($LASTEXITCODE) { throw 'Signed-image catalog creation failed' }
& $signtool sign /s My /sha1 $cert.Thumbprint /fd SHA256 "$PSScriptRoot\package\PanelBridge.cat"
if ($LASTEXITCODE) { throw 'Catalog signing failed' }
$manifest = [ordered]@{ CertificateThumbprint = $cert.Thumbprint; Files = @{} }
foreach ($name in @('PanelBridge.sys','PanelBridge.inf','PanelBridge.cat','PanelBridge.cer')) {
    $manifest.Files[$name] = (Get-FileHash -LiteralPath "$PSScriptRoot\package\$name" -Algorithm SHA256).Hash
}
$manifest | ConvertTo-Json | Set-Content -Encoding UTF8 "$PSScriptRoot\package\manifest.json"
Write-Output "Test-signed package, certificate $($cert.Thumbprint)"
