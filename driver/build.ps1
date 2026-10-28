param([string]$Llvm = "$PSScriptRoot\tools\llvm\bin")
$ErrorActionPreference = 'Stop'
$wdk = "$PSScriptRoot\tools\wdk\c"
$sdk = "$PSScriptRoot\tools\sdk\c"
$kit = '10.0.26100.0'
$out = "$PSScriptRoot\package"
$obj = "$PSScriptRoot\obj"
New-Item -ItemType Directory -Force $out,$obj | Out-Null
$includes = @("/imsvc$wdk\Include\$kit\km", "/imsvc$wdk\Include\$kit\km\crt", "/imsvc$wdk\Include\wdf\kmdf\1.15",
    "/imsvc$sdk\Include\$kit\shared", "/imsvc$sdk\Include\$kit\ucrt",
    "/I$PSScriptRoot")
& "$Llvm\clang-cl.exe" /nologo /c /TC /O2 /W4 /WX /GS- /Zl /kernel /D_AMD64_ /DAMD64 /D_WIN64 /D_KERNEL_MODE /DWINVER=0x0A00 /D_WIN32_WINNT=0x0A00 /DNTDDI_VERSION=0x0A000000 @includes "/Fo$obj\PanelBridge.obj" "$PSScriptRoot\PanelBridge.c"
if ($LASTEXITCODE) { throw 'Driver compilation failed' }
# lld defaults to TSAWARE for non-DLL images, including /driver. Windows rejects
# that session-image flag here with STATUS_CONFLICTING_ADDRESSES (Win32 487).
& "$Llvm\lld-link.exe" /nologo /driver /tsaware:no /subsystem:native,10.00 /entry:FxDriverEntry /nodefaultlib /machine:x64 /dynamicbase /nxcompat /integritycheck /release "/out:$out\PanelBridge.sys" "/libpath:$wdk\Lib\$kit\km\x64" "/libpath:$wdk\Lib\wdf\kmdf\x64\1.15" "$obj\PanelBridge.obj" WdfDriverEntry.lib WdfLdr.lib ntoskrnl.lib hal.lib wmilib.lib BufferOverflowFastFailK.lib
if ($LASTEXITCODE) { throw 'Driver link failed' }
$bytes = [IO.File]::ReadAllBytes("$out\PanelBridge.sys")
$pe = [BitConverter]::ToInt32($bytes,0x3c)
$dllFlags = [BitConverter]::ToUInt16($bytes,$pe + 24 + 70)
if ($dllFlags -band 0x8000) { throw 'Kernel image incorrectly has TERMINAL_SERVER_AWARE set.' }
& "$Llvm\clang-cl.exe" /nologo /c /TC /O2 /W4 /WX /GS- /Zl "/I$PSScriptRoot" "/Fo$obj\LayoutTests.obj" "$PSScriptRoot\LayoutTests.c"
if ($LASTEXITCODE) { throw 'Test compilation failed' }
& "$Llvm\lld-link.exe" /nologo /subsystem:console /entry:mainCRTStartup /nodefaultlib /machine:x64 "/out:$obj\LayoutTests.exe" "$obj\LayoutTests.obj" "$PSScriptRoot\tools\sdk-x64\c\um\x64\kernel32.Lib"
if ($LASTEXITCODE) { throw 'Test link failed' }
& "$obj\LayoutTests.exe"
if ($LASTEXITCODE) { throw 'Layout boundary tests failed' }
Copy-Item -LiteralPath "$PSScriptRoot\PanelBridge.inf" -Destination $out -Force
& "$wdk\tools\$kit\x64\infverif.exe" /w "$out\PanelBridge.inf"
if ($LASTEXITCODE) { throw 'INF validation failed' }
& "$wdk\bin\$kit\x86\Inf2Cat.exe" "/driver:$out" /os:10_GE_X64 /uselocaltime
if ($LASTEXITCODE) { throw 'Catalog creation failed' }
Write-Output "Built and checked $out\PanelBridge.sys"
