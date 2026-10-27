# run_v05_batches.ps1 -- batch_00..04 decoder core regression via xsim
# Usage (from repo root):
#   $env:XILINX_VIVADO = "C:\Xilinx\Vivado\2022.2"
#   .\scripts\run_v05_batches.ps1

$ErrorActionPreference = "Continue"
$Repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$srcDir = Join-Path $Repo "src"
$tbDir  = Join-Path $Repo "tb"
$simDir = Join-Path $Repo "sim_out"

if ($env:XILINX_VIVADO -and (Test-Path (Join-Path $env:XILINX_VIVADO "bin"))) {
    $vivadoBin = Join-Path $env:XILINX_VIVADO "bin"
} else {
    $vivadoBin = "C:\Xilinx\Vivado\2022.2\bin"
}
$env:PATH = "$vivadoBin;$env:PATH"

if (-not (Test-Path $simDir)) { New-Item -ItemType Directory $simDir -Force | Out-Null }
Set-Location $simDir

$srcFiles = @(
    (Join-Path $srcDir "rle4k_decoder_code_parser.v"),
    (Join-Path $srcDir "decoder_output_accumulator.v"),
    (Join-Path $srcDir "rle4k_decoder_core.v")
)

$totalPassed = 0
$totalFailed = 0
$results = @()

foreach ($batch in 0..4) {
    $batchFile = Join-Path $tbDir "tb_rle4k_decoder_core_batch_0$batch.v"
    $modName = "tb_rle4k_decoder_core_batch_0$batch"
    $snapName = "sim_batch_0$batch"

    Write-Host "`n===== BATCH 0$batch =====" -ForegroundColor Cyan

    if (-not (Test-Path $batchFile)) {
        Write-Host "MISSING TB: $batchFile" -ForegroundColor Red
        $results += "batch_0$batch : MISSING TB"
        $totalFailed++
        continue
    }

    # Compile
    $compOut = & xvlog.bat -work work @srcFiles $batchFile 2>&1
    $errors = $compOut | Select-String "ERROR"
    if ($errors) {
        Write-Host "COMPILE ERROR in batch_0$batch" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host $_ }
        $results += "batch_0$batch : COMPILE ERROR"
        $totalFailed++
        continue
    }

    # Elaborate
    $elabOut = & xelab.bat $modName -s $snapName -timescale "1ns/1ps" -debug off 2>&1
    $errors = $elabOut | Select-String "ERROR"
    if ($errors) {
        Write-Host "ELABORATE ERROR in batch_0$batch" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host $_ }
        $results += "batch_0$batch : ELABORATE ERROR"
        $totalFailed++
        continue
    }

    # Run
    $simOut = & xsim.bat $snapName -runall -onerror quit 2>&1

    $passLine = $simOut | Select-String "Passed:\s*(\d+)" | Select-Object -Last 1
    $failLine = $simOut | Select-String "Failed:\s*(\d+)" | Select-Object -Last 1
    $finalLines = $simOut | Select-String "(Passed|Failed|Total|ALL TESTS)"

    $batchPass = 0
    $batchFail = 0
    if ($passLine) {
        $batchPass = [int]$passLine.Matches.Groups[1].Value
    }
    if ($failLine) {
        $batchFail = [int]$failLine.Matches.Groups[1].Value
    }

    $totalPassed += $batchPass
    $totalFailed += $batchFail

    $failTests = $simOut | Select-String "FAIL:"
    foreach ($ft in $failTests) { Write-Host "  $ft" -ForegroundColor Yellow }

    foreach ($fl in $finalLines) { Write-Host "  $fl" }

    $results += "batch_0$batch : pass=$batchPass fail=$batchFail"
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  V05 BATCH TEST SUMMARY" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
foreach ($r in $results) { Write-Host "  $r" }
Write-Host "  TOTAL: passed=$totalPassed failed=$totalFailed"
Write-Host "========================================" -ForegroundColor Green

if ($totalFailed -gt 0) { exit 1 } else { exit 0 }
