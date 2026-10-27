@echo off
setlocal
REM Legacy stim generator ? prefers encoder-rle4k if present; else fails with clear message
set REPO=%~dp0..
set OUT=%REPO%\tb
call "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvarsall.bat" x64 >nul 2>&1
if not defined EZDI_ROOT set EZDI_ROOT=<path-redacted>
set RLE_INC=%EZDI_ROOT%\encoders\encoder-rle4k\librle4k\src
if not exist "%RLE_INC%\rle4k_decoder.cpp" (
  echo ERROR: rle4k_decoder.cpp not found at %RLE_INC%
  echo Set EZDI_ROOT or place encoder-rle4k sources.
  exit /b 1
)
cl /EHsc /std:c++17 /O2 /DDISALBE_RLE4K_LIB ^
  /I"%RLE_INC%" ^
  /Fe:"%OUT%\gen_stim.exe" ^
  /Fo:"%OUT%\\" ^
  "%OUT%\gen_stim.cpp" ^
  "%RLE_INC%\rle4k_decoder.cpp"
