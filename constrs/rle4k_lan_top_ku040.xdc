# ============================================================================
# rle4k_lan_top -- KU040 (xcku040-ffva1156-2-i) pin & timing constraints
# ============================================================================
# Authoritative constraint file for the Vivado 2022.2 rebuild.
#
# Supersedes:
#   constrs/rle4k_lan_top.xdc            self-declared TEMPLATE, pins belong to
#                                        a different board; never add to a build
#   src/vendor/uisrc/04_pin/fpga_pin.xdc PHYB ports absent from this top level,
#                                        and led[3] on AK14 is not a legal pin
#                                        in this package
#   constrs/led_only.xdc                 LED-only patch, folded in below (AD16)
#
# PHYA pin assignments are taken verbatim from the vendor pin file; only port A
# is wired on this design.
# ============================================================================

# ---------- System differential clock: 100 MHz ----------
# MMCM x10 -> VCO 1000 MHz -> /64 = 15.625, /3 = 333.33, /8 = 125, /40 = 25 MHz.
# The 100 MHz figure is not cosmetic: clk_wiz_0 sizes its multiplier from it, and
# a wrong value halves every output while still locking (see the IP comment in
# scripts/create_project_2022_2.tcl).
set_property PACKAGE_PIN E22  [get_ports sysclk_p]
set_property PACKAGE_PIN E23  [get_ports sysclk_n]
set_property IOSTANDARD  LVDS [get_ports sysclk_p]
set_property IOSTANDARD  LVDS [get_ports sysclk_n]
# The clocking wizard's own constraints already create the 200 MHz input clock
# and derive the four outputs from it. Creating it again here renames it and
# silently discards every constraint that referenced the original, which left
# the MMCM outputs unconstrained (Constraints 18-1055).

# ---------- PHY reset ----------
set_property PACKAGE_PIN AP31    [get_ports phy_rst_o]
set_property IOSTANDARD LVCMOS18 [get_ports phy_rst_o]

# ---------- PHY A RGMII ----------
set_property PACKAGE_PIN AL30 [get_ports PHYA_rgmii_rxc]
set_property PACKAGE_PIN AP33 [get_ports PHYA_rgmii_rx_ctl]
set_property PACKAGE_PIN AN33 [get_ports {PHYA_rgmii_rxd[0]}]
set_property PACKAGE_PIN AN32 [get_ports {PHYA_rgmii_rxd[1]}]
set_property PACKAGE_PIN AM32 [get_ports {PHYA_rgmii_rxd[2]}]
set_property PACKAGE_PIN AM30 [get_ports {PHYA_rgmii_rxd[3]}]
set_property PACKAGE_PIN AM29 [get_ports PHYA_rgmii_txc]
set_property PACKAGE_PIN AL29 [get_ports PHYA_rgmii_tx_ctl]
set_property PACKAGE_PIN AL28 [get_ports {PHYA_rgmii_txd[0]}]
set_property PACKAGE_PIN AL27 [get_ports {PHYA_rgmii_txd[1]}]
set_property PACKAGE_PIN AK27 [get_ports {PHYA_rgmii_txd[2]}]
set_property PACKAGE_PIN AK26 [get_ports {PHYA_rgmii_txd[3]}]

set_property IOSTANDARD LVCMOS18 [get_ports PHYA_rgmii_rxc]
set_property IOSTANDARD LVCMOS18 [get_ports PHYA_rgmii_rx_ctl]
set_property IOSTANDARD LVCMOS18 [get_ports {PHYA_rgmii_rxd[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports PHYA_rgmii_txc]
set_property IOSTANDARD LVCMOS18 [get_ports PHYA_rgmii_tx_ctl]
set_property IOSTANDARD LVCMOS18 [get_ports {PHYA_rgmii_txd[*]}]

set_property SLEW FAST [get_ports PHYA_rgmii_txc]
set_property SLEW FAST [get_ports PHYA_rgmii_tx_ctl]
set_property SLEW FAST [get_ports {PHYA_rgmii_txd[*]}]

# ---------- LEDs ----------
set_property PACKAGE_PIN AG14 [get_ports {led[0]}]
set_property PACKAGE_PIN AH14 [get_ports {led[1]}]
set_property PACKAGE_PIN AJ14 [get_ports {led[2]}]
set_property PACKAGE_PIN AD16 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led[*]}]

# ---------- Clocks ----------
# Both the system clock and the RGMII receive clock come from IP constraints
# (clk_wiz_0 and the TEMAC respectively). Clock domain crossings are grouped in
# rle4k_lan_top_ku040_timing.xdc, which runs in implementation only because the
# MMCM output clocks do not exist yet while the top level is being synthesised.

# ---------- Bitstream ----------
set_property BITSTREAM.GENERAL.COMPRESS true [current_design]
