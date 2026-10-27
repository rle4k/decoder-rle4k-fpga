@echo off
setlocal enabledelayedexpansion

REM Multi-block CRC verification test script
REM Tests various block combinations against D:\outputs\rle4k_1 data
REM MLK板 MAC: 6C-1F-F7-BD-D6-D3

set CLI="%~dp0build_vs2022\Release\rle4k_v8.exe"
set DATA=D:\outputs\rle4k_1
set IFACE={8ACF9959-6C5D-4AFD-A04E-E9DC8B9C5A8E}
set RESULTS=test_results_%date:~0,4%%date:~5,2%%date:~8,2%_%time:~0,2%%time:~3,2%.txt

echo ============================================================
echo   RLE4K Multi-Block CRC Verification Test
echo   Data: %DATA%
echo   Interface: %IFACE%
echo ============================================================
echo.

REM First check connectivity
echo [TEST 0] Ping test...
%CLI% --iface %IFACE% ping 3
if errorlevel 1 (
    echo FAIL: Cannot communicate with FPGA
    exit /b 1
)
echo.

REM Test Group A: Single block (baseline)
echo [TEST A] Single block verification...
%CLI% --iface %IFACE% verify folder %DATA% --max-blocks 1
echo.

REM Test Group B: 2 blocks (first + last)
echo [TEST B] 2 blocks (first + last)...
%CLI% --iface %IFACE% verify folder %DATA% --max-blocks 2
echo.

REM Test Group C: 5 blocks
echo [TEST C] 5 blocks...
%CLI% --iface %IFACE% verify folder %DATA% --max-blocks 5
echo.

REM Test Group D: 10 blocks
echo [TEST D] 10 blocks...
%CLI% --iface %IFACE% verify folder %DATA% --max-blocks 10
echo.

REM Test Group E: 50 blocks
echo [TEST E] 50 blocks...
%CLI% --iface %IFACE% verify folder %DATA% --max-blocks 50
echo.

REM Test Group F: 100 blocks
echo [TEST F] 100 blocks...
%CLI% --iface %IFACE% verify folder %DATA% --max-blocks 100
echo.

REM Test Group G: Full strip (2403 blocks)
echo [TEST G] Full strip (2403 blocks)...
%CLI% --iface %IFACE% verify folder %DATA%
echo.

echo ============================================================
echo   All tests completed
echo ============================================================
