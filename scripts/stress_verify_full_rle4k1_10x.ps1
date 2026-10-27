# stress_verify_full_rle4k1_10x.ps1 -- multi-run verify batch + TSV summary in reports/
#
# Usage (from repo root):
#   .\scripts\stress_verify_full_rle4k1_10x.ps1
#   .\scripts\stress_verify_full_rle4k1_10x.ps1 -Runs 5 -GapSeconds 2 -TimeoutMs 120000 -FpgaOnly
#   .\scripts\stress_verify_full_rle4k1_10x.ps1 -InterChunkDelayMs 1 -TargetRoundBudgetSec 600
#
# InterChunkDelayMs < 0 (default) does not pass the flag, so the CLI runs at full
# speed (0 ms between STREAM_DATA frames). Pass a positive value only to debug
# the FPGA adapter; on Windows a 1 ms Sleep costs ~2 ms per frame in practice.
#
# Board iface/MAC: .cursor/rules/03-v08mac-board.mdc

param(
    [int] $Runs = 10,
    [string] $Root = "D:\outputs\rle4k_1",
    [int] $GapSeconds = 1,
    [int] $TimeoutMs = 120000,
    [switch] $FpgaOnly = $false,
    [int] $InterChunkDelayMs = -1,
    [int] $TargetRoundBudgetSec = 600,
    [string] $Iface = "\Device\NPF_{0F60CD7D-397C-4595-813D-2A381F9E1170}",
    [string] $LocalMac = "EE:EE:EE:EE:B6:4A",
    [string] $TargetMac = "00:0A:35:00:01:02"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$V08 = Get-V08RepoRoot
$Reports = Ensure-V08ReportsDir -RepoRoot $V08
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
            [Environment]::GetEnvironmentVariable("Path", "User")
$Exe = Get-V08CliExe -RepoRoot $V08

$Common = Get-V08BoardCliArgs -Iface $Iface -LocalMac $LocalMac -TargetMac $TargetMac -TimeoutMs $TimeoutMs

$Extra = @()
if ($FpgaOnly) { $Extra += @("--fpga-only") }
if ($InterChunkDelayMs -ge 0) {
    $Extra += @("--inter-chunk-delay-ms", "$InterChunkDelayMs")
}
if ($TargetRoundBudgetSec -gt 0) {
    $Extra += @("--round-budget-sec", "$TargetRoundBudgetSec")
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Summary = Join-Path $Reports "full_rle4k1_stress_${stamp}_summary.tsv"
"run`texit`twall_ms`tfpga_path_ms`tsend_ms`tfpga_wait_ms`tpc_ref_ms`tbudget`tbudget_warn`tsum_send_ms`tsum_fpga_wait_ms`telapsed_ms`tlog" |
    Set-Content -Path $Summary -Encoding UTF8

function Parse-MetricsLine([string]$line) {
    $o = [ordered]@{
        fpga_path_ms = ""
        send_ms = ""
        fpga_wait_ms = ""
        pc_ref_ms = ""
        budget = ""
    }
    if ($line -match "fpga_path_ms=(\d+)") { $o.fpga_path_ms = $Matches[1] }
    if ($line -match "send_ms=(\d+)") { $o.send_ms = $Matches[1] }
    if ($line -match "fpga_wait_ms=(\d+)") { $o.fpga_wait_ms = $Matches[1] }
    if ($line -match "pc_ref_ms=(\d+)") { $o.pc_ref_ms = $Matches[1] }
    if ($line -match "budget=(\w+)") { $o.budget = $Matches[1] }
    return [pscustomobject]$o
}

function Parse-BatchSummary([string]$line) {
    $sumSend = ""; $sumFpga = ""; $elapsed = ""
    if ($line -match "sum_send_ms=(\d+)") { $sumSend = $Matches[1] }
    if ($line -match "sum_fpga_wait_ms=(\d+)") { $sumFpga = $Matches[1] }
    if ($line -match "elapsed_ms=(\d+)") { $elapsed = $Matches[1] }
    return [pscustomobject]@{ sum_send_ms = $sumSend; sum_fpga_wait_ms = $sumFpga; elapsed_ms = $elapsed }
}

$budgetMs = $TargetRoundBudgetSec * 1000
Write-Host "Stress verify batch: root=$Root runs=$Runs FpgaOnly=$FpgaOnly gap=${GapSeconds}s budget=${TargetRoundBudgetSec}s" -ForegroundColor Cyan
& $Exe @($Common + @("hardware", "--version")) 2>&1

for ($i = 1; $i -le $Runs; $i++) {
    if ($GapSeconds -gt 0) { Start-Sleep -Seconds $GapSeconds }
    Write-Host "--- run $i / $Runs : ping ---" -ForegroundColor Yellow
    & $Exe @($Common + @("ping")) 2>&1 | Out-Null

    $log = Join-Path $Reports ("full_rle4k1_stress_{0}_run{1}.log" -f $stamp, $i)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $Exe @($Common + @("verify", "batch", $Root, "--continue", "--log", $log) + $Extra) 2>&1
    $sw.Stop()
    $exit = $LASTEXITCODE

    $mLine = Get-Content $log -ErrorAction SilentlyContinue | Select-String "METRICS" | Select-Object -Last 1
    $m = $null
    if ($mLine) { $m = Parse-MetricsLine $mLine.Line }

    $bLine = Get-Content $log -ErrorAction SilentlyContinue | Select-String "BATCH_SUMMARY" | Select-Object -Last 1
    $b = $null
    if ($bLine) { $b = Parse-BatchSummary $bLine.Line }

    $fpgaPath = if ($m) { $m.fpga_path_ms } else { "" }
    $warn = ""
    if ($fpgaPath -ne "" -and $budgetMs -gt 0) {
        try {
            if ([int64]$fpgaPath -gt $budgetMs) { $warn = "OVER" }
            else { $warn = "ok" }
        } catch { $warn = "" }
    }
    if ($warn -eq "OVER") {
        Write-Host "BUDGET WARN run $i : fpga_path_ms=$fpgaPath > ${budgetMs} ms" -ForegroundColor Yellow
    }

    $sumSend = if ($b) { $b.sum_send_ms } else { "" }
    $sumFpga = if ($b) { $b.sum_fpga_wait_ms } else { "" }
    $elapsedBatch = if ($b) { $b.elapsed_ms } else { "" }

    "${i}`t${exit}`t$($sw.ElapsedMilliseconds)`t${fpgaPath}`t$(if($m){$m.send_ms}else{''})`t$(if($m){$m.fpga_wait_ms}else{''})`t$(if($m){$m.pc_ref_ms}else{''})`t$(if($m){$m.budget}else{''})`t${warn}`t${sumSend}`t${sumFpga}`t${elapsedBatch}`t$log" |
        Add-Content -Path $Summary -Encoding UTF8
    Write-Host ("run {0}: exit={1} wall_ms={2} fpga_path_ms={3} budget={4}" -f $i, $exit, $sw.ElapsedMilliseconds, $fpgaPath, $(if($m){$m.budget}else{"?"})) -ForegroundColor $(if ($exit -eq 0) { "Green" } else { "Red" })
}

Write-Host "Wrote $Summary" -ForegroundColor Cyan
