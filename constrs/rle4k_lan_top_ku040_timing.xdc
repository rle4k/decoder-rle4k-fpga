# ============================================================================
# rle4k_lan_top -- clock domain crossings (implementation only)
# ============================================================================
# Registered with used_in_synthesis = false. The clk_wiz_0 and TEMAC cores are
# synthesised out of context, so the clocks referenced below only exist once the
# design has been linked for implementation; reading this during synthesis of
# the top level would only produce "no valid object" critical warnings.
#
# Every path between the four MMCM outputs goes through an explicit CDC element
# (rle4k_cdc_fifo_36, or a 2-flop synchroniser in rle4k_lan_top_v8), and the
# RGMII receive clock is recovered from the link, so none of these domains is
# phase-comparable. Without this grouping the 15.625/125 MHz crossings are timed
# as if they were synchronous, which is what produced the -2.745 ns hold slack
# and the CRITICAL "Timing 38-282" in the pre-rebuild bitstream.
# ============================================================================

set_clock_groups -asynchronous \
    -group [get_clocks -quiet clk_out1_clk_wiz_0] \
    -group [get_clocks -quiet clk_out2_clk_wiz_0] \
    -group [get_clocks -quiet clk_out3_clk_wiz_0] \
    -group [get_clocks -quiet clk_out4_clk_wiz_0] \
    -group [get_clocks -quiet -of_objects [get_ports PHYA_rgmii_rxc]]

# ---------- RGMII transmit clock skew ----------
# THIS IS THE FIX for the board dropping roughly one ping in four. The TEMAC
# default delays RGMII_TXC by 2 ns (an ODELAYE3 the signal traverses twice,
# cascaded through an IDELAYE3), which is right for a PHY that applies no
# transmit delay of its own. This board's PHY does apply one, so the two delays
# add and push the clock edge out of the data eye.
#
# Measured on hardware, 10 x "ping 5" per point (see
# reports/2026-08-08-rgmii-delay-sweep.md):
#
#   DELAY_VALUE   0    250    500    750   1000(default)   1250
#   pong rate   100%   100%   100%   100%       72%          0%
#
# 250 is an interior point of the passing band: verified at 100%, and the only
# observed degradation is upward, starting between 750 and 1000.
set_property DELAY_VALUE 250 \
    [get_cells -quiet -hier -filter {NAME =~ *rgmii_interface/delay_rgmii_tx_clk}]
#
# Overriding it to 0 -- the setting that would be correct if this board's PHY
# were strapped for RGMII internal delay -- was tried on 2026-08-08 and the board
# stayed just as silent as with the default.
#
# WARNING: that comparison is void. It ran on the plain 2022.2 rebuild, which the
# A/B statistics later measured at 0/50 pongs -- the board was dead for an
# unrelated reason, so of course both delay settings failed. Do not cite it as
# evidence that transmit skew is fine. Against the current ~70% baseline the same
# sweep is discriminating again, and setting DELAY_VALUE on the routed checkpoint
# and re-running write_bitstream skips place and route entirely. See
# reports/2026-08-08-ab-bitstream-comparison.md.
#
#   set_property DELAY_VALUE 0 \
#       [get_cells -quiet -hier -filter {NAME =~ *rgmii_interface/delay_rgmii_tx_clk*}]
#
# It does work as written (the RGMII output requirement moves from 2 ns to 0 and
# five TXD paths then fail max-delay), so reuse it if a delay sweep is revived.
# See docs/V1.0/V1021 §5.
