# common.ps1 -- shared helpers for V08MAC permanent scripts
# Dot-source from other scripts:  . (Join-Path $PSScriptRoot "common.ps1")
# Canonical board params: .cursor/rules/03-v08mac-board.mdc

$ErrorActionPreference = "Stop"

function Get-V08RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

function Get-VivadoBat {
    if ($env:XILINX_VIVADO) {
        $c = Join-Path $env:XILINX_VIVADO "bin\vivado.bat"
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }
    foreach ($p in @(
        "C:\Xilinx\Vivado\2022.2\bin\vivado.bat"
    )) {
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    $g = Get-Command "vivado.bat" -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    throw "vivado.bat not found (set XILINX_VIVADO=C:\Xilinx\Vivado\2022.2 or add ...\Vivado\bin to PATH)"
}

# Default board CLI args (must match 03-v08mac-board.mdc). Override via params in callers.
function Get-V08BoardCliArgs {
    param(
        [string] $Iface = "\Device\NPF_{0F60CD7D-397C-4595-813D-2A381F9E1170}",
        [string] $LocalMac = "EE:EE:EE:EE:B6:4A",
        [string] $TargetMac = "00:0A:35:00:01:02",
        [int] $TimeoutMs = 120000
    )
    return @(
        "--iface", $Iface,
        "--local-mac", $LocalMac,
        "--target-mac", $TargetMac,
        "--timeout", "$TimeoutMs"
    )
}

function Get-V08CliExe {
    param([string] $RepoRoot = (Get-V08RepoRoot))
    $exe = Join-Path $RepoRoot "rle4k_cli\build\Release\rle4k_v8.exe"
    if (-not (Test-Path $exe)) {
        throw "Missing CLI: $exe (build Release rle4k_v8 first)"
    }
    return (Resolve-Path $exe).Path
}

function Ensure-V08ReportsDir {
    param([string] $RepoRoot = (Get-V08RepoRoot))
    $reports = Join-Path $RepoRoot "reports"
    if (-not (Test-Path $reports)) {
        New-Item -ItemType Directory -Path $reports | Out-Null
    }
    return $reports
}

function Invoke-VivadoSource {
    param(
        [Parameter(Mandatory)][string] $RelTcl,
        [string] $LogName = "",
        [string] $RepoRoot = (Get-V08RepoRoot)
    )
    $tcl = Join-Path $RepoRoot $RelTcl
    if (-not (Test-Path $tcl)) { throw "Missing $tcl" }
    $vivadoBat = Get-VivadoBat
    $reports = Ensure-V08ReportsDir -RepoRoot $RepoRoot
    $extra = @()
    if ($LogName) {
        $extra += @("-nojournal", "-log", (Join-Path $reports $LogName))
    }
    Write-Host "=== $vivadoBat -source $RelTcl ===" -ForegroundColor Cyan
    Push-Location $RepoRoot
    try {
        & $vivadoBat -mode batch -notrace @extra -source $tcl
        if ($LASTEXITCODE -ne 0) { throw "Vivado exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}
