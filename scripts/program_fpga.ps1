# program_fpga.ps1 -- PowerShell wrapper around scripts/program_fpga.tcl
#
# Usage (from repo root):
#   .\scripts\program_fpga.ps1
#   .\scripts\program_fpga.ps1 -BitFile "D:\path\to\rle4k_lan_top.bit"
#
# Default bit: build/rle4k_fpga_v08.runs/impl_1/rle4k_lan_top.bit
# Vivado: $env:XILINX_VIVADO or C:\Xilinx\Vivado\2022.2

param(
    [string] $BitFile = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$Repo = Get-V08RepoRoot
if ($BitFile) {
    if (-not (Test-Path $BitFile)) { throw "bitstream not found: $BitFile" }
    $env:V08MAC_BIT_FILE = (Resolve-Path $BitFile).Path
} else {
    Remove-Item Env:\V08MAC_BIT_FILE -ErrorAction SilentlyContinue
}

try {
    Invoke-VivadoSource -RelTcl "scripts\program_fpga.tcl" -LogName "vivado_program_fpga.ps1.log" -RepoRoot $Repo
    Write-Host "FPGA programmed successfully." -ForegroundColor Green
} finally {
    Remove-Item Env:\V08MAC_BIT_FILE -ErrorAction SilentlyContinue
}
