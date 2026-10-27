@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1

set SRCDIR=<repo-root>\rle4k_cli
set NPCAP=%SRCDIR%\..\npcap-sdk
set RLE4KCPP=<path-redacted>\rle4k-cpp\src
set OUTEXE=%SRCDIR%\build_vs2022\Release\rle4k_v8.exe

echo === Building CLI ===
cl /EHsc /O2 /std:c++17 /DNOMINMAX /DDISALBE_RLE4K_LIB /I"%SRCDIR%\src" /I"%NPCAP%\Include" /I"%RLE4KCPP%" "%SRCDIR%\src\main_cli_v8.cpp" "%SRCDIR%\src\block_reader.cpp" "%SRCDIR%\src\config_io.cpp" "%RLE4KCPP%\rle4k_decoder.cpp" /Fe:"%OUTEXE%" /link "%NPCAP%\Lib\x64\wpcap.lib" "%NPCAP%\Lib\x64\Packet.lib" ws2_32.lib iphlpapi.lib
if errorlevel 1 (
    echo BUILD FAILED
    exit /b 1
)
echo BUILD OK

set IFACE=\Device\NPF_{8ACF9959-6C5D-4AFD-A04E-E9DC8B9C5A8E}
set BLK=D:\outputs\rle4k_1\raster_strip0_block0000.rle4k

echo.
echo === Ping ===
"%OUTEXE%" --iface "%IFACE%" --timeout 2000 ping

echo.
echo === Verify ===
"%OUTEXE%" --iface "%IFACE%" --timeout 8000 verify file "%BLK%"

echo.
echo === CRC polls ===
timeout /t 2 >nul
"%OUTEXE%" --iface "%IFACE%" --timeout 2000 crc
timeout /t 2 >nul
"%OUTEXE%" --iface "%IFACE%" --timeout 2000 crc
timeout /t 5 >nul
"%OUTEXE%" --iface "%IFACE%" --timeout 2000 crc

echo.
echo === Done ===
