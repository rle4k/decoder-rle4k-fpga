# run_sim_cycles.ps1 -- per-block cycle accounting for rle4k_decoder_core (E9)
#
# Measures the decoder's intrinsic time for one real .rle4k block: how many
# cycles emit a word, how many idle, and why. Input never starves and the
# downstream never backpressures, so the number is the decoder alone and can be
# compared against the board's block-period floor.
#
#   scripts\run_sim_cycles.ps1 -Block D:\outputs\rle4k_1\raster_strip0_block1856.rle4k
#
# Not a gate: it reports rather than passes/fails the build. It exists so a
# change to the decoder front end can be measured before and after.
# Background and the numbers it produced:
#   reports/2026-08-09-e9-per-block-cycle-accounting.md

param(
    [Parameter(Mandatory = $true)][string]$Block,
    [string]$VivadoBin
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$src  = Join-Path $repo 'src'
$tb   = Join-Path $repo 'tb'
$data = Join-Path $tb   'sim_data_e9'
$work = Join-Path $repo 'sim_out_e9'
$gen  = Join-Path $repo 'rle4k_cli\build\Release\gen_sim_data.exe'

if (-not (Test-Path $Block)) { throw "no such block file: $Block" }
if (-not (Test-Path $gen))   { throw "gen_sim_data.exe not built; see docs/V1.0/04-cli-cpp.md" }

Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $data, $work | Out-Null
& $gen $Block $data | Out-Null
if ($LASTEXITCODE -ne 0) { throw "gen_sim_data failed on $Block" }

# The TB reads its scalars through $readmemh, so sim_config.txt becomes params.hex.
$cfg = @{}
Get-Content (Join-Path $data 'sim_config.txt') | ForEach-Object {
    $kv = $_ -split '\s+'
    if ($kv.Count -ge 2) { $cfg[$kv[0]] = $kv[1] }
}
function Hex32([string]$v) {
    if ($v -like '0x*') { return '{0:x8}' -f [Convert]::ToUInt32($v.Substring(2), 16) }
    return '{0:x8}' -f [uint32]$v
}
Set-Content -Path (Join-Path $data 'params.hex') -Encoding ascii -Value @(
    Hex32 $cfg['STREAM_WORDS']
    Hex32 $cfg['BLOCK0_HEIGHT']
    Hex32 $cfg['TOTAL_WORDS']
    Hex32 $cfg['CRC32_ACCUM']
    Hex32 $cfg['LINE_WIDTH']
    Hex32 $cfg['LINE_STRIDE']
    Hex32 $cfg['BLOCK0_COMPRESSED']
    '00000000'
)

if (-not $VivadoBin) { $VivadoBin = $env:V08LAN_XILINX_BIN }
if (-not $VivadoBin -and $env:XILINX_VIVADO) { $VivadoBin = Join-Path $env:XILINX_VIVADO 'bin' }
if (-not $VivadoBin) { $VivadoBin = 'C:\Xilinx\Vivado\2022.2\bin' }

Push-Location $work
try {
    & (Join-Path $VivadoBin 'xvlog.bat') -sv `
        (Join-Path $src 'rle4k_decoder_code_parser.v') `
        (Join-Path $src 'decoder_output_accumulator.v') `
        (Join-Path $src 'rle4k_decoder_core.v') `
        (Join-Path $tb  'tb_decoder_cycles.v') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed; see $work\xvlog.log" }
    & (Join-Path $VivadoBin 'xelab.bat') tb_decoder_cycles -s e9_snap -timescale 1ns/1ps -debug off | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "xelab failed; see $work\xelab.log" }
    & (Join-Path $VivadoBin 'xsim.bat') e9_snap -runall -onerror quit | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "xsim failed; see $work\xsim.log" }
} finally {
    Pop-Location
}

Write-Host "=== $(Split-Path -Leaf $Block) ==="
Select-String -Path (Join-Path $work 'xsim.log') -Pattern '^E9' | ForEach-Object { $_.Line }
