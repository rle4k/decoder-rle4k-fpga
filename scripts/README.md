---
IOF: RYIOF_DWS20260807004
title: V08MAC 脚本清单与可用状态
class: 规范类/脚本索引
version: v1.2.0
status: draft
company: ReeGenius
author: 项目组
date: 2026-08-07
lastmod: 2026-08-08
memo: 路径相对化；板级 iface/MAC 对齐 03-v08mac-board；新增无板离线自检 §4.1
project: RDLA2026
---

# `scripts/` 脚本清单

永久脚本目录。调用约定：**从仓根运行**；Vivado 一律经 `vivado.bat`；板级网卡参数以
`.cursor/rules/03-v08mac-board.mdc` 为准（禁止 auto-detect）。路径基线见 `docs/V1.0/V1017-*.md`。

```powershell
$env:XILINX_VIVADO = "C:\Xilinx\Vivado\2022.2"
$env:PATH = "C:\Windows\System32\npcap;$env:PATH"
& "$env:XILINX_VIVADO\bin\vivado.bat" -mode batch -notrace -source scripts\<name>.tcl
# 或 PowerShell：
.\scripts\<name>.ps1
```

状态列含义：

| 状态 | 含义 |
|------|------|
| **OK** | 仓根相对路径 / 本机默认可跑（依赖 bit、数据目录时另注明） |
| **受限** | 脚本路径已修好，但依赖历史 `build/*.xpr`（2025.1 技术债）或外部数据集 |
| **遗留** | 已移出主流程；见归档节 |

共享辅助：`common.ps1`（`Get-VivadoBat` / `Get-V08BoardCliArgs` / `Invoke-VivadoSource`），勿单独当入口。

---

## 1. 仿真门禁

| 脚本 | 作用 | 状态 |
|------|------|------|
| `run_sim_crc.tcl` | **CRC 仿真门禁**：跑 `tb_decoder_crc`；出新 bit 前必须 `ALL TESTS PASSED` | **OK**（`[info script]`→仓根；Vivado 优先 `$env:XILINX_VIVADO` 否则 2022.2；产物 `sim_out/`） |
| `run_sim_block_gate.tcl` | 块级门禁入口，内部 `source run_sim_crc.tcl` | **OK** |
| `run_v05_batches.ps1` | `tb_rle4k_decoder_core_batch_00~04` 批量 xsim 回归 | **OK**（缺 TB 文件则该项记 MISSING） |
| `run_sim_rxchain.tcl` | **接收路径吞吐门禁**：`tb_rle4k_rxchain`，把 8→64 位宽转换与两级 FIFO 纳入 DUT | **OK**（线速下应 FAIL，`V08MAC_XVLOG_DEFINES=RXCHAIN_PACED` 放慢后 PASS） |
| `run_sim_cycles.ps1` | **量具，非门禁**：单块解码的逐拍核算（出字/空转/空转成因/十分位分布）。改解码器前端前后做对照用 | **OK**（直接调 xvlog/xelab/xsim；产物 `sim_out_e9/` + `tb/sim_data_e9/`，均已 gitignore） |

```powershell
& "$env:XILINX_VIVADO\bin\vivado.bat" -mode batch -notrace -source scripts/run_sim_crc.tcl
.\scripts\run_v05_batches.ps1
# 量一块真实块要多少拍（口径与结论见 reports/2026-08-09-e9-per-block-cycle-accounting.md）
.\scripts\run_sim_cycles.ps1 -Block D:\outputs\rle4k_1\raster_strip0_block1856.rle4k
```

### 1.1 把板级用例导进仿真：`gen_sim_data --folder`

`tb/sim_data/` 是所有 TB 的激励来源。要在仿真里复现某次板级失败，必须喂**同一条 strip**，
而不是手工挑几个块文件——挑错顺序或数量，复现出来的就是另一个用例。

`rle4k_cli/src/gen_sim_data.cpp` 的 `--folder` 模式走的是 `BlockReader::read_directory`，
与 `rle4k_v8 verify folder --max-blocks N` **同一个选块函数**，因此选出的块序完全一致：

```powershell
# 构建（注意：本机 cmake 生成器不可用，直接用 MSBuild 打这个 target）
& "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe" `
    rle4k_cli\build\gen_sim_data.vcxproj /p:Configuration=Release /p:Platform=x64

# 导出与 `verify folder --max-blocks 3` 等价的激励
rle4k_cli\build\Release\gen_sim_data.exe --folder "D:\outputs\rle4k_1" --max-blocks 3 .temp\simdata_n3
Copy-Item .temp\simdata_n3\* tb\sim_data\ -Force      # 用完记得还原原样本
```

选项：`--max-blocks N`（取前 N 块，0 = 全部）、`--strip N`（按文件名里的 strip 过滤）。
写出 `stream_data.hex` / `sim_config.txt` / `ref_crc.txt` / `block_heights.hex` 四个文件。

**注意**：`tb/sim_data/` 是受版本控制的通过样本，覆盖后务必还原，否则后续门禁会拿着别的用例判绿。

另有 `tb/sim_data/clk_skew_ns.txt`（可选，缺省视为 0）：把 `tb_rle4k_integration` 的
15.625 MHz 时钟从 125 MHz 的整数栅格上挪开。TB 默认让两个时钟在 t=0 同时起振，
每个慢时钟沿都正好压在快时钟沿上，这是板上不会出现的退化情形，会掩盖跨域竞态。
用文件而非 `-d NAME=VALUE` 传参，是因为 Windows 上 xvlog 会在 `=` 处截断并把值当文件名打开
（`fullspeed_gap.txt` 同理）。

## 2. 综合 / 实现 / 比特流

| 脚本 | 作用 | 状态 |
|------|------|------|
| `quick_build.tcl` | 打开 `build/rle4k_fpga_v08.xpr`，reset → synth → impl → bitstream | **受限**（路径 OK；`.xpr` 可能为 2025.1 历史产物，2022.2 未必能重开） |
| `vivado_open_project_smoke.tcl` | 只打开工程验证可加载（无综合） | **受限**（同上） |
| `check_ip_params.ps1` | **防复发门禁**：核对 `build/ip` 关键 IP 参数与基线；重建工程后必跑 | **OK** |

### 2.1 重建工程后必做：IP 参数核对

`create_project_2022_2.tcl -tclargs -force` **之前不删 `build/ip`**，Vivado 的 `create_ip`
会把新配置消歧成 `<name>_1/` 并**保留旧的 `<name>/`**：工程用其中一份构建，而磁盘上那个
"看起来对"的目录仍是旧配置。2026-08-08 的 `MAC_Speed` 改动"看起来没生效"就是这么来的。
该脚本现已在 `-force` 分支里 `file delete -force build/ip`。

但目录删干净不代表参数写对了。`clk_wiz_0` 的 `PRIM_IN_FREQ` 曾被填成 200 MHz（实际板卡
100 MHz）：MMCM 照样 lock，**不报任何错**，只是每路输出都减半，RGMII_TXC 不再是合法的
千兆发送时钟——表现为"板卡发送方向静默"。当时是靠逐个 `.xci` 手工比对才定位的。

因此重建后跑：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check_ip_params.ps1
# 或与已知良好 bit 的 IP 目录对比：
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check_ip_params.ps1 `
    -Reference reports\bitstreams\2026-08-08-clkfix-100mhz\ip
```

退出码非 0 即停，不要拿这个 bit 上板。脚本同时会报 `<name>_1/` 这类残留重复 IP 目录。

覆盖工程路径：`V08MAC_XPR` 环境变量，或 Tcl `set ::V08MAC_XPR <path>`。

默认 bit 落点：`build/rle4k_fpga_v08.runs/impl_1/rle4k_lan_top.bit`。

## 3. 烧写

| 脚本 | 作用 | 状态 |
|------|------|------|
| `program_fpga.tcl` | **JTAG 烧写主入口**；打印 BEFORE/AFTER（DONE / ILA / VIO）便于核对设计身份 | **OK**（默认 bit 相对仓根；可用 `V08MAC_BIT_FILE` 覆盖） |
| `program_fpga.ps1` | 上一条的 PowerShell 包装（`-BitFile` 可选） | **OK** |

```powershell
.\scripts\program_fpga.ps1
.\scripts\program_fpga.ps1 -BitFile "D:\path\to\rle4k_lan_top.bit"
# 或直接 Tcl：
& "$env:XILINX_VIVADO\bin\vivado.bat" -mode batch -notrace -source scripts/program_fpga.tcl
```

烧写后核对 JTAG 探针 vs `.ltx`（known-good：`0 ILA + 1 VIO`，`fw=0x80104`）。

## 4. 板级冒烟与压测

默认 iface / PC MAC / FPGA MAC 与 `03-v08mac-board.mdc` 一致，可用参数覆盖。

| 脚本 | 作用 | 状态 |
|------|------|------|
| `run_impl_program_boardtest.ps1` | **一键**：`quick_build` → `program_fpga` → `hardware` / `dog` / `verify batch`；`-SkipImpl` / `-SkipProgram` | **受限**（烧写/CLI 段 OK；impl 依赖 `.xpr`） |
| `BatchSendStrip.ps1` | 轻量冒烟：`ping` → `echo` → `hardware` → `send file|folder` | **OK**（需 CLI + 链路；缺条带目录则 SKIP send） |
| `stress_verify_full_rle4k1_10x.ps1` | 全量目录多轮 `verify batch`，TSV 汇总到 `reports/` | **OK**（默认根 `D:\outputs\rle4k_1`） |

```powershell
.\scripts\run_impl_program_boardtest.ps1 -SkipImpl -SkipProgram
.\scripts\BatchSendStrip.ps1 -StripDir "D:\outputs\rle4k_sim_strip"
.\scripts\stress_verify_full_rle4k1_10x.ps1 -Runs 5 -FpgaOnly
```

推荐冒烟顺序：网卡自检 →（需时）烧写+`.ltx` → `hardware --version` → `ping`≥5 → `dog` → `reports/`。

`stress_verify_full_rle4k1_10x.ps1` 的 `-InterChunkDelayMs` 默认 `-1` = **不传该参数**，
CLI 因此按默认的**全速**（0 ms）发送；只有排查 FPGA adapter 节拍时才传正数。

## 4.1 无板离线自检（不触碰硬件）

| 脚本 | 作用 | 状态 |
|------|------|------|
| `OfflineSelfCheck.ps1` | `selftest_verdict`（判据自测）→ `pc_reference`（PC 参考解码 + CRC32 post-XOR + 编码器往返）→ `rle4k_v8 --dry-run`（全速发送计时埋点） | **OK**（不打开网卡、不发包；需先构建 Release） |

```powershell
.\scripts\OfflineSelfCheck.ps1
.\scripts\OfflineSelfCheck.ps1 -StripDir "D:\outputs\rle4k_sim_strip" -ExpectCrc 0xf87c04d1 -ExpectWords 98688
```

板卡/bit 不可用时，这是唯一可复现的验收证据链；判据与位域见 `docs/V1.0/04-cli-cpp.md` §5.1 与 `02-mac-protocol.md` §6.2。

## 5. 已归档到 `.temp/legacy-scripts/`

指向 **V05UDP** 叠加工程或历史绝对路径的脚本，已移出 `scripts/`（`.temp/` gitignored）：

| 文件 | 原用途 |
|------|--------|
| `.temp/legacy-scripts/vivado_inproc_build_v8.tcl` | 在 V05UDP `.xpr` 上叠加 V08 源并 in-process 出 bit（非本仓主线） |
| `.temp/legacy-scripts/vivado_impl_from_synth.tcl` | 从 V05UDP synth `.dcp` 跑 impl（非本仓主线） |

历史上曾归档（若本地仍有）：`_program_temp.tcl` / `_program_xsdb.tcl` / `program_board.tcl`。

README 曾列出但仓内已不存在、勿再寻找：`_build_v08_inproc.tcl`、`_program_now.tcl`。

恢复方式（仅排查用）：`Move-Item .temp\legacy-scripts\<name> scripts\`。

## 6. 新增脚本约定

1. **永久脚本**放 `scripts/`，并在本表补一行（用途 + 状态）。
2. **一次性试验脚本**放仓根 `.temp/`（gitignored）；禁止新建无点前缀的 `temp/`。
3. **禁止内嵌仓根绝对路径**，统一相对推导：

```tcl
set repo_root [file normalize [file join [file dirname [file normalize [info script]]] ..]]
```

```powershell
. (Join-Path $PSScriptRoot "common.ps1")
$Repo = Get-V08RepoRoot
```

4. Vivado：优先 `$env:XILINX_VIVADO`，回退 `C:\Xilinx\Vivado\2022.2`（日常不用 2025.1）。
5. 板级 CLI：优先复用 `Get-V08BoardCliArgs`；禁止依赖 auto-detect。
6. 日志写 `reports/`，文件名带时间戳；相机抓拍勿提交。

## 修订历史

| 版本 | 日期 | 修订人 | 修订内容 |
|------|------|--------|----------|
| v1.2.0 | 2026-08-08 | AI-assisted | 新增 §4.1 `OfflineSelfCheck.ps1`（无板自检）；说明全速发送为默认 |
| v1.1.0 | 2026-08-08 | 项目组 | 路径相对化；`common.ps1`；板级 MAC/iface 对齐 board 规则；归档 2 个 V05UDP 构建脚本；去掉已消失条目 |
| v1.0.1 | 2026-08-08 | 项目组 | 仿真三脚本路径修复为相对仓根；CRC/block 门禁实测 PASS |
| v1.0.0 | 2026-08-07 | 项目组 | 初版：全量盘点脚本用途与可用状态；归档 3 个 V05UDP 遗留烧写脚本 |
