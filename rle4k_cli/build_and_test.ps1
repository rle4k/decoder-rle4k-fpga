# Build and test script for RLE4K V8 CLI
# Run in an elevated PowerShell or Developer Command Prompt

$ErrorActionPreference = "Continue"

$srcDir = "<repo-root>\rle4k_cli"
$npcap = "$srcDir\..\npcap-sdk"
$rle4kCpp = "<path-redacted>\rle4k-cpp\src"
$outExe = "$srcDir\build\Release\rle4k_v8.exe"

$sources = @(
    "$srcDir\src\main_cli_v8.cpp",
    "$srcDir\src\block_reader.cpp",
    "$srcDir\src\config_io.cpp",
    "$rle4kCpp\rle4k_decoder.cpp"
) -join " "

$includes = "/I`"$srcDir\src`" /I`"$npcap\Include`" /I`"$rle4kCpp`""
$libs = "`"$npcap\Lib\x64\wpcap.lib`" `"$npcap\Lib\x64\Packet.lib`" ws2_32.lib iphlpapi.lib"
$defs = "/DNOMINMAX /DDISALBE_RLE4K_LIB"

Write-Host "=== Building CLI ===" -ForegroundColor Cyan
$cmd = "cl /EHsc /O2 /std:c++17 $defs $includes $sources /Fe:`"$outExe`" /link $libs"
cmd /c "`"C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat`" >nul 2>&1 && $cmd"

if ($LASTEXITCODE -ne 0) {
    Write-Host "BUILD FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "BUILD OK" -ForegroundColor Green

$iface = "\Device\NPF_{D1D26F21-A8CC-48EA-A9E2-232A95278010}"
$blk = "D:\outputs\rle4k_1\raster_strip0_block0000.rle4k"

Write-Host "`n=== Ping ===" -ForegroundColor Cyan
& $exe --iface $iface --timeout 2000 ping

Write-Host "`n=== Verify file ===" -ForegroundColor Cyan
& $exe --iface $iface --timeout 5000 verify file $blk

Write-Host "`n=== CRC poll (3x @2s intervals) ===" -ForegroundColor Cyan
for ($i = 0; $i -lt 3; $i++) {
    Start-Sleep -Seconds 2
    Write-Host "--- CRC poll $($i+1) ---"
    & $exe --iface $iface --timeout 2000 crc
}

Write-Host "`nDone." -ForegroundColor Cyan
