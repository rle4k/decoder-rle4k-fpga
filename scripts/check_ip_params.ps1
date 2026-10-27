<#
.SYNOPSIS
    Compare critical IP parameters in build/ip against the expected baseline.

.DESCRIPTION
    The 2026-08-08 "board is silent on transmit" regression was a single wrong
    number in a generated IP: clk_wiz_0 was told the reference clock was 200 MHz
    when the board supplies 100 MHz. The MMCM still locked, so nothing failed
    loudly -- every derived clock simply came out at half rate and RGMII_TXC was
    never a valid gigabit transmit clock. It took a manual .xci-by-.xci diff
    against a recovered known-good bitstream to find it.

    This script makes that diff automatic. Run it after any project rebuild,
    before spending time on the board.

.PARAMETER BuildDir
    Directory holding the generated IP. Defaults to build/ip next to the repo.

.PARAMETER Reference
    Optional directory of known-good .xci files to compare against instead of
    the built-in expectations. Every parameter listed below is compared.

.EXAMPLE
    pwsh scripts/check_ip_params.ps1
    pwsh scripts/check_ip_params.ps1 -Reference reports/bitstreams/2026-08-08-clkfix-100mhz/ip

.OUTPUTS
    Exit code 0 when every checked parameter matches, 1 otherwise.
#>
[CmdletBinding()]
param(
    [string] $BuildDir  = '',
    [string] $Reference = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $BuildDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $BuildDir  = Join-Path $scriptDir '..\build\ip'
}

# Parameters whose value has previously been wrong, or whose value silently
# changes behaviour instead of failing the build. Keep this list short: it is a
# tripwire, not a full IP dump.
$expected = @(
    @{ Ip = 'clk_wiz_0';              Param = 'CONFIG.PRIM_IN_FREQ';           Value = '100.000'
       Why = 'Board reference clock. 200 halves every output while still locking.' }
    @{ Ip = 'clk_wiz_0';              Param = 'CONFIG.PRIM_SOURCE';            Value = 'Differential_clock_capable_pin'
       Why = 'LVDS sysclk pair.' }
    @{ Ip = 'tri_mode_ethernet_mac_0'; Param = 'CONFIG.MAC_Speed';             Value = '1000_Mbps'
       Why = 'Fixed gigabit; Tri_speed re-introduces speed auto-negotiation.' }
    @{ Ip = 'tri_mode_ethernet_mac_0'; Param = 'CONFIG.Management_Frequency';  Value = '125'
       Why = 'Must track the AXI-Lite clock actually driven into the MAC.' }
    @{ Ip = 'tri_mode_ethernet_mac_0'; Param = 'CONFIG.Physical_Interface';    Value = 'RGMII'
       Why = 'PHY attachment.' }
    @{ Ip = 'axis_data_fifo_1';       Param = 'CONFIG.FIFO_DEPTH';            Value = '8192'
       Why = 'RX CDC FIFO. The MAC is never backpressured, so a stage too small to hold one whole block (53,524 B) drops frames at line rate.' }
    @{ Ip = 'axis_data_fifo_0';       Param = 'CONFIG.FIFO_DEPTH';            Value = '8192'
       Why = 'RX packet FIFO (shared config with the TX one). Same burst requirement as axis_data_fifo_1.' }
)

function Get-XciParam {
    param([string] $XciPath, [string] $Name)

    if (-not (Test-Path -LiteralPath $XciPath)) { return $null }

    # .xci is JSON for recent Vivado, but stays readable as text for both the
    # JSON and the older XML flavour, so match on the key rather than parsing.
    $text = Get-Content -LiteralPath $XciPath -Raw

    # Parameters are stored under their bare name; the CONFIG. prefix only
    # exists in the Tcl-facing view used by create_ip / set_property.
    $key = [regex]::Escape(($Name -replace '^CONFIG\.', ''))

    $m = [regex]::Match($text, "`"$key`"\s*:\s*\[?\s*{[^}]*?`"value`"\s*:\s*`"([^`"]*)`"")
    if ($m.Success) { return $m.Groups[1].Value }

    $m = [regex]::Match($text, "<spirit:configurableElementValue[^>]*$key`"[^>]*>([^<]*)<")
    if ($m.Success) { return $m.Groups[1].Value }

    return $null
}

$buildDirFull = (Resolve-Path -LiteralPath $BuildDir -ErrorAction SilentlyContinue)
if (-not $buildDirFull) {
    Write-Host "FAIL: IP directory not found: $BuildDir" -ForegroundColor Red
    Write-Host "      Build the project first (scripts/create_project_2022_2.tcl -tclargs -force)."
    exit 1
}

Write-Host "Checking IP parameters under $buildDirFull"
if ($Reference) { Write-Host "Reference: $Reference" }
Write-Host ''

$failures = @()

foreach ($check in $expected) {
    $xci = Join-Path $buildDirFull ("{0}\{1}.xci" -f $check.Ip, $check.Ip)

    $want = $check.Value
    if ($Reference) {
        $refXci = Join-Path $Reference ("{0}\{1}.xci" -f $check.Ip, $check.Ip)
        $refVal = Get-XciParam -XciPath $refXci -Name $check.Param
        if ($null -ne $refVal) { $want = $refVal }
    }

    $got = Get-XciParam -XciPath $xci -Name $check.Param

    if ($null -eq $got) {
        $failures += "{0}: {1} not found in {2}" -f $check.Ip, $check.Param, $xci
        Write-Host ("  MISSING  {0,-28} {1}" -f $check.Ip, $check.Param) -ForegroundColor Red
    }
    elseif ($got -ne $want) {
        $failures += "{0}: {1} is '{2}', expected '{3}' -- {4}" -f `
            $check.Ip, $check.Param, $got, $want, $check.Why
        Write-Host ("  MISMATCH {0,-28} {1} = {2} (expected {3})" -f `
            $check.Ip, $check.Param, $got, $want) -ForegroundColor Red
        Write-Host ("           {0}" -f $check.Why) -ForegroundColor DarkYellow
    }
    else {
        Write-Host ("  ok       {0,-28} {1} = {2}" -f $check.Ip, $check.Param, $got) -ForegroundColor Green
    }
}

# The RGMII transmit clock delay lives in the XDC, not in any .xci, so it
# survives an IP regeneration and is easy to lose in a constraint edit. Leaving
# it at the TEMAC default of 1000 costs roughly one ping in four on this board,
# because the PHY adds a transmit delay of its own. See docs/V1.0/V1022.
$txDelayXdc = Join-Path (Split-Path -Parent $buildDirFull) '..\constrs\rle4k_lan_top_ku040_timing.xdc'
if (Test-Path -LiteralPath $txDelayXdc) {
    $xdcText = Get-Content -LiteralPath $txDelayXdc -Raw
    $active  = ($xdcText -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $m = [regex]::Match($active, 'set_property\s+DELAY_VALUE\s+(\d+)[\s\S]{0,200}?delay_rgmii_tx_clk')

    if (-not $m.Success) {
        $failures += 'RGMII TX clock DELAY_VALUE constraint is missing or commented out'
        Write-Host '  MISSING  rgmii tx delay          set_property DELAY_VALUE ... delay_rgmii_tx_clk' -ForegroundColor Red
        Write-Host '           Without it the TEMAC default (1000) drops ~1 ping in 4. See docs/V1.0/V1022.' -ForegroundColor DarkYellow
    }
    elseif ([int]$m.Groups[1].Value -gt 750) {
        $failures += "RGMII TX clock DELAY_VALUE is $($m.Groups[1].Value); measured pass band is 0..750, use 250"
        Write-Host ("  MISMATCH rgmii tx delay          DELAY_VALUE = {0} (pass band 0..750, use 250)" -f $m.Groups[1].Value) -ForegroundColor Red
    }
    else {
        Write-Host ("  ok       rgmii tx delay          DELAY_VALUE = {0}" -f $m.Groups[1].Value) -ForegroundColor Green
    }
}

# A stale <name>_1 directory means create_ip disambiguated instead of
# regenerating: the project then builds from a config that is not the one in the
# obvious-looking directory. That is how a MAC_Speed change once appeared to
# have no effect.
$dupes = Get-ChildItem -LiteralPath $buildDirFull -Directory -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -match '_\d+$' -and
                        (Test-Path (Join-Path $buildDirFull ($_.Name -replace '_\d+$',''))) }

foreach ($d in $dupes) {
    $failures += "stale duplicate IP directory: $($d.Name)"
    Write-Host ("  STALE    duplicate IP directory {0} -- rebuild with -force" -f $d.Name) -ForegroundColor Red
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "FAIL: $($failures.Count) problem(s) found." -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

Write-Host 'PASS: all checked IP parameters match.' -ForegroundColor Green
exit 0
