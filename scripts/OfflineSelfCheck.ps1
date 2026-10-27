# OfflineSelfCheck.ps1 -- board-free regression for the PC/CLI side
#
# Runs everything that can be proven WITHOUT the FPGA:
#   1. selftest_verdict  -- verify PASS/FAIL criterion (Defect A)
#   2. pc_reference      -- PC reference decode + CRC32 in post-XOR caliber,
#                           plus an encoder round-trip
#   3. rle4k_v8 --dry-run -- full-speed send path + throughput instrumentation
#
# No Npcap device is opened and no frame is transmitted.
#
# Usage (from repo root):
#   .\scripts\OfflineSelfCheck.ps1
#   .\scripts\OfflineSelfCheck.ps1 -StripDir "D:\outputs\rle4k_sim_strip" -ExpectCrc 0xf87c04d1 -ExpectWords 98688

param(
    [string] $StripDir   = "D:\outputs\rle4k_sim_strip",
    [string] $ExpectCrc  = "0xf87c04d1",   # post-XOR acceptance caliber
    [int]    $ExpectWords = 98688,
    [switch] $SkipDryRun
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$V08     = Get-V08RepoRoot
$BinDir  = Join-Path $V08 "rle4k_cli\build\Release"
$failed  = 0

function Invoke-Step {
    param([string] $Name, [string] $Exe, [string[]] $CliArgs)
    Write-Host "`n=== $Name ===" -ForegroundColor Cyan
    if (-not (Test-Path $Exe)) {
        Write-Host "MISSING $Exe (build Release first)" -ForegroundColor Red
        $script:failed++
        return
    }
    & $Exe @CliArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "$Name FAILED (exit $LASTEXITCODE)" -ForegroundColor Red
        $script:failed++
    } else {
        Write-Host "$Name OK" -ForegroundColor Green
    }
}

Invoke-Step -Name "1. verdict self-test" `
            -Exe (Join-Path $BinDir "selftest_verdict.exe") -CliArgs @()

if (Test-Path $StripDir) {
    Invoke-Step -Name "2. PC reference CRC32 (post-XOR) + encoder round-trip" `
                -Exe (Join-Path $BinDir "pc_reference.exe") `
                -CliArgs @($StripDir, "--expect-crc", $ExpectCrc,
                           "--expect-words", "$ExpectWords", "--roundtrip")
} else {
    Write-Host "`nSKIP 2: $StripDir not found" -ForegroundColor Yellow
}

if (-not $SkipDryRun -and (Test-Path $StripDir)) {
    # wpcap.dll is needed to load rle4k_v8.exe, but --dry-run opens no device.
    $env:PATH = "C:\Windows\System32\npcap;$env:PATH"
    Invoke-Step -Name "3. full-speed send path (dry-run, no NIC)" `
                -Exe (Join-Path $BinDir "rle4k_v8.exe") `
                -CliArgs @("--dry-run", "--json", "send", "folder", $StripDir)
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "=== OFFLINE SELF-CHECK PASSED ===" -ForegroundColor Green
    exit 0
}
Write-Host "=== OFFLINE SELF-CHECK FAILED ($failed step(s)) ===" -ForegroundColor Red
exit 1
