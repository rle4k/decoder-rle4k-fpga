# run_impl_program_boardtest.ps1 -- one-shot: impl -> program -> hardware/dog/verify
#
# Usage (from repo root):
#   .\scripts\run_impl_program_boardtest.ps1
#   .\scripts\run_impl_program_boardtest.ps1 -SkipImpl -SkipProgram
#
# Board iface/MAC: .cursor/rules/03-v08mac-board.mdc (override via -Iface / -LocalMac)

param(
    [switch] $SkipImpl,
    [switch] $SkipProgram,
    [string] $Iface = "\Device\NPF_{0F60CD7D-397C-4595-813D-2A381F9E1170}",
    [string] $LocalMac = "EE:EE:EE:EE:B6:4A",
    [string] $TargetMac = "00:0A:35:00:01:02",
    [string] $StripRoot = "D:\outputs\rle4k_sim_strip",
    [int] $TimeoutMs = 120000
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$V08 = Get-V08RepoRoot
$Reports = Ensure-V08ReportsDir -RepoRoot $V08
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path", "User")

if (-not $SkipImpl) {
    Invoke-VivadoSource -RelTcl "scripts\quick_build.tcl" -LogName "vivado_quick_build_manual.log" -RepoRoot $V08
    Write-Host "IMPL OK" -ForegroundColor Green
} else {
    Write-Host "Skipping impl (-SkipImpl)" -ForegroundColor Yellow
}

if (-not $SkipProgram) {
    Invoke-VivadoSource -RelTcl "scripts\program_fpga.tcl" -LogName "vivado_program_fpga_manual.log" -RepoRoot $V08
    Write-Host "PROGRAM OK" -ForegroundColor Green
} else {
    Write-Host "Skipping program (-SkipProgram)" -ForegroundColor Yellow
}

$Cli = Get-V08CliExe -RepoRoot $V08
$Common = Get-V08BoardCliArgs -Iface $Iface -LocalMac $LocalMac -TargetMac $TargetMac -TimeoutMs $TimeoutMs

Write-Host "=== hardware --version (known-good fw=0x80104) ===" -ForegroundColor Cyan
& $Cli @($Common + @("hardware", "--version"))

Write-Host "=== dog ===" -ForegroundColor Cyan
& $Cli @($Common + "dog")

Write-Host "=== verify batch (smoke strip) ===" -ForegroundColor Cyan
$blog = Join-Path $Reports ("rle4k_v8_batch_after_impl_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
& $Cli @($Common + @("verify", "batch", $StripRoot, "--max-strips", "1", "--max-blocks", "2", "--log", $blog))
Write-Host "batch log: $blog exit=$LASTEXITCODE" -ForegroundColor $(if ($LASTEXITCODE -eq 0) { "Green" } else { "Yellow" })
