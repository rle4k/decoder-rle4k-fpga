NOTICE
======
rle4k-decoder-fpga incorporates the following third-party RTL helper files,
retained under their original terms with provenance noted here:

- src/vendor/uisrc/01_rtl/tri_mode_ethernet_mac_0_axi_lite_sm.v
- src/vendor/uisrc/01_rtl/tri_mode_ethernet_mac_0_example_design_resets.v
- src/vendor/uisrc/01_rtl/tri_mode_ethernet_mac_0_reset_sync.v
- src/vendor/uisrc/01_rtl/tri_mode_ethernet_mac_0_sync_block.v
  Origin: reference design material for the Xilinx Tri-Mode Ethernet MAC
  (TEMAC) example design, as shipped with a third-party Kintex UltraScale
  development board. Only these four files are used by the build; the rest of
  that vendor package (UDP/IP stack, documentation, board pin constraints) is
  NOT needed by, NOT built into, and NOT redistributed with this repository.

- bitstreams/k1, bitstreams/k2: compiled outputs of this source tree plus the
  Xilinx TEMAC IP (Vivado 2022.2); subject to Xilinx IP license terms for the
  generated bitstreams as normally applies to FPGA bitstreams.

The host-side tool `rle4k_cli` links Npcap at runtime (Windows packet driver);
Npcap is a separate third-party product and is NOT included here.
