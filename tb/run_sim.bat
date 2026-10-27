@echo off
setlocal
REM Legacy stim TB runner ? sources live under tb/; artifacts under sim/
set REPO=%~dp0..
set VIVADO=C:\Xilinx\Vivado\2022.2\bin
if defined XILINX_VIVADO set VIVADO=%XILINX_VIVADO%\bin
set TB_DIR=%REPO%\tb
set SRC_DIR=%REPO%\src
set OUT_DIR=%REPO%\sim

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
cd /d "%OUT_DIR%"

echo === COMPILE ===
"%VIVADO%\xvlog.bat" -sv ^
  "%SRC_DIR%\rle4k_decoder_core.v" ^
  "%SRC_DIR%\decoder_output_accumulator.v" ^
  "%SRC_DIR%\rle4k_decoder_code_parser.v" ^
  "%SRC_DIR%\rle4k_decoder_mask_lut.v" ^
  "%SRC_DIR%\rle4k_decoder_mask_tables.v" ^
  "%TB_DIR%\tb_decoder_core.v"
if errorlevel 1 (echo COMPILE FAILED & exit /b 1)

echo === ELABORATE ===
"%VIVADO%\xelab.bat" -debug typical tb_decoder_core -s tb_sim
if errorlevel 1 (echo ELABORATE FAILED & exit /b 1)

echo === SIMULATE ===
"%VIVADO%\xsim.bat" tb_sim -runall -log sim_log.txt
echo === DONE ===
