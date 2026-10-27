# ============================================================================
# RLE4K LAN Top — Pin & Timing Constraints
# ============================================================================
# Target: Kintex UltraScale (milianke board — adjust package/pin as needed)
# This file is a TEMPLATE. Update pin LOC/IOSTANDARD for your board.
#
# NOT USED BY THE BUILD. scripts/create_project_2022_2.tcl adds only
# constrs/rle4k_lan_top_ku040.xdc, which is the authoritative pin-out for
# xcku040-ffva1156. Kept as a starting point for a different board; do not
# assume any value here matches the hardware in the lab.
#
# The 200 MHz note below is one of those stale values -- the board clock is
# 100 MHz. See the header of rle4k_lan_top_ku040.xdc.
# ============================================================================

# ---------- System differential clock (200 MHz assumed) ----------
set_property PACKAGE_PIN AE10 [get_ports sysclk_p]
set_property PACKAGE_PIN AF10 [get_ports sysclk_n]
set_property IOSTANDARD LVDS [get_ports sysclk_p]
set_property IOSTANDARD LVDS [get_ports sysclk_n]
create_clock -period 5.000 -name sys_clk_in [get_ports sysclk_p]

# ---------- PHY A RGMII ----------
# RX clock from PHY
set_property PACKAGE_PIN AD11 [get_ports PHYA_rgmii_rxc]
set_property IOSTANDARD LVCMOS18 [get_ports PHYA_rgmii_rxc]
create_clock -period 8.000 -name phya_rxc [get_ports PHYA_rgmii_rxc]

# RX data / control (example pins — MUST update for actual board)
set_property PACKAGE_PIN AH11 [get_ports {PHYA_rgmii_rxd[0]}]
set_property PACKAGE_PIN AJ11 [get_ports {PHYA_rgmii_rxd[1]}]
set_property PACKAGE_PIN AH12 [get_ports {PHYA_rgmii_rxd[2]}]
set_property PACKAGE_PIN AJ12 [get_ports {PHYA_rgmii_rxd[3]}]
set_property PACKAGE_PIN AK11 [get_ports PHYA_rgmii_rx_ctl]
set_property IOSTANDARD LVCMOS18 [get_ports {PHYA_rgmii_rxd[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports PHYA_rgmii_rx_ctl]

# TX data / control / clock
set_property PACKAGE_PIN AE12 [get_ports {PHYA_rgmii_txd[0]}]
set_property PACKAGE_PIN AF12 [get_ports {PHYA_rgmii_txd[1]}]
set_property PACKAGE_PIN AG12 [get_ports {PHYA_rgmii_txd[2]}]
set_property PACKAGE_PIN AH13 [get_ports {PHYA_rgmii_txd[3]}]
set_property PACKAGE_PIN AE13 [get_ports PHYA_rgmii_tx_ctl]
set_property PACKAGE_PIN AD12 [get_ports PHYA_rgmii_txc]
set_property IOSTANDARD LVCMOS18 [get_ports {PHYA_rgmii_txd[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports PHYA_rgmii_tx_ctl]
set_property IOSTANDARD LVCMOS18 [get_ports PHYA_rgmii_txc]

# PHY reset
set_property PACKAGE_PIN AF13 [get_ports phy_rst_o]
set_property IOSTANDARD LVCMOS18 [get_ports phy_rst_o]

# LEDs
set_property PACKAGE_PIN AG14 [get_ports {led[0]}]
set_property PACKAGE_PIN AH14 [get_ports {led[1]}]
set_property PACKAGE_PIN AJ14 [get_ports {led[2]}]
# AK14 is not a legal pin on this package; the real board routes led[3] to AD16.
set_property PACKAGE_PIN AD16 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS18 [get_ports {led[3]}]

# ---------- Timing constraints ----------
# RGMII timing constraints are handled by the TEMAC IP (tri_mode_ethernet_mac_0_clocks.xdc)
# Only define CDC false paths here to avoid duplicate constraints

# CDC false paths between system clock and RGMII RX clock
set_false_path -from [get_clocks sys_clk_in] -to [get_clocks phya_rxc]
set_false_path -from [get_clocks phya_rxc]   -to [get_clocks sys_clk_in]
