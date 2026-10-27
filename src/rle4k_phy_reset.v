// ============================================================================
// rle4k_phy_reset -- RGMII PHY reset pulse generator
// ============================================================================
// Holds the PHY in reset for ASSERT_CYCLES clocks after `enable` (MMCM lock)
// goes high, then releases it and stays released.
//
// The width matters. Gigabit PHYs specify a minimum RESET_N assertion in the
// millisecond range (10 ms is the usual figure) measured from the point where
// supplies and the reference clock are stable, and -- more importantly for this
// design, which has no MDIO -- the configuration strap pins are sampled on the
// RESET_N *rising* edge. A pulse shorter than the specified minimum can leave
// the PHY partially initialised or latch the straps unreliably, which is a
// failure mode that lets auto-negotiation come up while a direction of the
// RGMII datapath stays dead.
//
// The version this replaced counted to 100 at 25 MHz, i.e. asserted reset for
// 4 us -- roughly three orders of magnitude short.
// ============================================================================

`timescale 1ns / 1ps

module rle4k_phy_reset #(
    // 500_000 cycles of a 25 MHz clock = 20 ms, double the usual 10 ms minimum.
    parameter [19:0] ASSERT_CYCLES = 20'd500000
) (
    input  wire clk,
    input  wire enable,
    output wire phy_rst_n
);

reg [19:0] cnt = 20'd0;

always @(posedge clk) begin
    if (!enable)
        cnt <= 20'd0;
    else if (cnt != ASSERT_CYCLES)
        cnt <= cnt + 20'd1;
end

// Low while counting, high once the terminal count is reached and held.
assign phy_rst_n = (cnt == ASSERT_CYCLES);

endmodule
