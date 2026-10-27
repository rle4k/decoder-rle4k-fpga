# rle4k-decoder-fpga

Board-level RLE4K decoder RTL, build scripts and compiled bitstreams for the
paper *"RLE4K FPGA Board-Level Decoding for High-Throughput Maskless-Lithography
Data Paths"* (target: IEEE Transactions on Industrial Electronics).

Companion repositories and data:

- Host-side reference codec & benchmark CLI (`redcli`):
  [rle4k/encoder-rle4k-cpu](https://github.com/rle4k/encoder-rle4k-cpu) (MIT)
- Board-level raw logs, timing reports, round records:
  [rle4k/rle4k-fpga-artifacts](https://github.com/rle4k/rle4k-fpga-artifacts)
- Gerber sample dataset (64 files): DOI
  [10.21227/t0cy-rb10](https://dx.doi.org/10.21227/t0cy-rb10)
- RLE4K test dataset (strip / bitstream bundle): [IEEE DataPort dataset page](https://ieee-dataport.org/documents/rle4k-pcb-raster-data-and-compression-code-real-time-maskless-lithography)

## What is in the paper's evidence chain

| Item | Where |
|---|---|
| Exact RTL of the shipped measurement bitstreams | `src/`, `constrs/`, `tb/` — taken verbatim from the project branch `exp/20260814-flowctl-fix`, commit `993cb9b` |
| Shipped bitstreams (K=1 / K=2, fw `0x80110`, 2026-08-14) | `bitstreams/k1/`, `bitstreams/k2/` |
| Host feed / diagnostic CLI used on the board | `rle4k_cli/` |
| Project creation, build, programming, batch-feed scripts | `scripts/` |
| Routed timing & utilization reports, all raw round logs | sister repo `rle4k-fpga-artifacts`, dir `sm1/` |

## Hardware target

Xilinx Kintex UltraScale **XCKU040-FFVA1156-2-I** on a commercial off-the-shelf
industrial data-processing card (MILIANKE KU040/060 series); single 1 GbE copper
port (RGMII, raw Layer-2 frames with EtherType `0x4B52`, a local value used only
on this point-to-point link and not IEEE-assigned); decode clock 125 MHz; output discarded on-chip after CRC32
statistics. Tool flow: **Vivado 2022.2**, Windows host with Npcap.

## Build

```tcl
# Vivado 2022.2 tcl shell, from the repo root
source scripts/create_project_2022_2.tcl   ;# project + TEMAC IP generation
source scripts/quick_build.tcl             ;# synth + impl + write_bitstream
```

`NUM_LANES` is bound as a generic (`P_NUM_LANES`); synthesis logs in the
artifacts repo prove the binding for the two shipped builds.

## Board test

```powershell
powershell scripts/program_fpga.ps1 -Bit <bitstream>   # program + signature check
powershell scripts/BatchSendStrip.ps1 ...              # block-gated/flush/constant-rate feed shapes
```

Pass criterion of every round: `blocks_completed = 2403` plus link health via
`ping` (50/50 pre-round gate, 5/5 post-round). Content-correctness CRC evidence
is a separate round family — see `sm1/rounds/output-correctness/` in the
artifacts repo.

## Key measured results (median sustained decode throughput, dataset B,
expansion ratio 321.367:1)

| Configuration | Median sustained decode throughput |
|---|---|
| 1 decode lane, block-gated send | 56.38 Gbit/s |
| 2 decode lanes, per-block flush | 93.53 Gbit/s |
| matched constant-rate pair | 44.18 / 93.60 Gbit/s |

Both builds carry routed WNS of −0.326 ns confined to five RGMII TX output
endpoints; the 125 MHz decode domain has zero timing violations. See the paper
and `sm1/timing-utilization/` for full context.

## License

MIT (see `LICENSE`). Third-party provenance notes in `NOTICE.md`.
