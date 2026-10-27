# BatchSendStrip.ps1 -- board smoke: ping / echo / hardware / send file|folder
#
# Usage (from repo root):
#   .\scripts\BatchSendStrip.ps1
#   .\scripts\BatchSendStrip.ps1 -StripDir "D:\outputs\rle4k_sim_strip"
#
# Board iface/MAC: .cursor/rules/03-v08mac-board.mdc
# Requires Npcap on PATH: $env:PATH = "C:\Windows\System32\npcap;$env:PATH"

param(
    [string] $StripDir = "D:\outputs\rle4k_1",
    [string] $Iface = "\Device\NPF_{0F60CD7D-397C-4595-813D-2A381F9E1170}",
    [string] $LocalMac = "EE:EE:EE:EE:B6:4A",
    [string] $TargetMac = "00:0A:35:00:01:02",
    [int] $TimeoutMs = 120000
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$env:PATH = "C:\Windows\System32\npcap;$env:PATH"
$cliExe = Get-V08CliExe
$Common = Get-V08BoardCliArgs -Iface $Iface -LocalMac $LocalMac -TargetMac $TargetMac -TimeoutMs $TimeoutMs

Write-Host "=== V08MAC Board Test Sequence (Raw MAC) ===" -ForegroundColor Cyan

Write-Host "`n--- ping ---"
& $cliExe @($Common + @("ping", "5"))
if ($LASTEXITCODE -ne 0) { Write-Host "PING FAILED" -ForegroundColor Red; exit 1 }

Write-Host "`n--- echo ---"
& $cliExe @($Common + @("echo", "5", "64"))
if ($LASTEXITCODE -ne 0) { Write-Host "ECHO FAILED" -ForegroundColor Red; exit 1 }

Write-Host "`n--- hardware --version ---"
& $cliExe @($Common + @("hardware", "--version"))
if ($LASTEXITCODE -ne 0) { Write-Host "HARDWARE VERSION FAILED" -ForegroundColor Red; exit 1 }

if (Test-Path $StripDir) {
    $firstFile = Get-ChildItem $StripDir -Filter "*.rle4k" | Select-Object -First 1
    if ($firstFile) {
        Write-Host "`n--- send file (single block) ---"
        & $cliExe @($Common + @("send", "file", $firstFile.FullName))
        if ($LASTEXITCODE -ne 0) { Write-Host "SEND FILE FAILED" -ForegroundColor Red; exit 1 }
    }

    Write-Host "`n--- send folder (full strip) ---"
    & $cliExe @($Common + @("send", "folder", $StripDir))
    if ($LASTEXITCODE -ne 0) { Write-Host "SEND FOLDER FAILED" -ForegroundColor Red; exit 1 }
} else {
    Write-Host "SKIP: $StripDir not found" -ForegroundColor Yellow
}

Write-Host "`n=== ALL TESTS PASSED ===" -ForegroundColor Green
