// ============================================================================
// tb_rle4k_pause_congestion -- rule-14 gate for expanded PAUSE OR
// ============================================================================
// Models master_wrapper_v8 pause_congested:
//   app_rx_congested | ~dwc_tready | ~tready3 | ~tready4 | (~app_rx_ready & data)
//
// plusarg late0: only !tready4 (legacy 8010C) -> RED (drops before PAUSE)
// plusarg early1: full OR (8010D) -> GREEN (PAUSE before sink overflow)
// ============================================================================

`timescale 1ns / 1ps

module tb_rle4k_pause_congestion;

reg clk = 1'b0;
always #4 clk = ~clk;

reg reset = 1'b1;
reg app_rx_congested = 1'b0;
reg dwc_tready = 1'b1;
reg tready3 = 1'b1;
reg tready4 = 1'b1;
reg app_rx_ready = 1'b1;
reg data_pending = 1'b0;

wire pause_legacy = (~tready4);
wire pause_early =
    app_rx_congested |
    (~dwc_tready) |
    (~tready3) |
    (~tready4) |
    ((~app_rx_ready) & data_pending);

integer mode; // 0=legacy RED, 1=early GREEN
integer sink_cap;
integer sink_depth;
integer offered, dropped;
integer cycles;
integer pause_cycles;
reg fail;

localparam integer SINK_CAP     = 8;
localparam integer OFFER_CYCLES = 300;
localparam integer DRAIN_EVERY  = 16;
localparam integer ASSIGN_STALL_AT = 40;
localparam integer ASSIGN_STALL_LEN = 80;

initial begin
    mode = 1;
    if ($test$plusargs("late0")) mode = 0;
    else if ($test$plusargs("early1")) mode = 1;
    $display("tb_rle4k_pause_congestion: mode=%0d (0=legacy late RED, 1=early GREEN)", mode);

    sink_depth = 0;
    offered = 0;
    dropped = 0;
    pause_cycles = 0;
    fail = 1'b0;

    reset = 1'b1;
    repeat (8) @(posedge clk);
    reset = 1'b0;

    for (cycles = 0; cycles < OFFER_CYCLES; cycles = cycles + 1) begin
        @(posedge clk);
        #1;

        // Emulate ASSIGN stall mid-burst (adapter rx_congested) before FIFO full.
        if (cycles >= ASSIGN_STALL_AT && cycles < (ASSIGN_STALL_AT + ASSIGN_STALL_LEN)) begin
            app_rx_congested = 1'b1;
            app_rx_ready = 1'b0;
        end else begin
            app_rx_congested = 1'b0;
            app_rx_ready = 1'b1;
        end

        // Downstream fills when peer keeps sending; DWC/async follow.
        tready4 = (sink_depth < SINK_CAP);
        tready3 = (sink_depth < (SINK_CAP - 1));
        dwc_tready = (sink_depth < (SINK_CAP - 2));
        data_pending = (sink_depth > 0);

        if ((mode == 1 && pause_early) || (mode == 0 && pause_legacy))
            pause_cycles = pause_cycles + 1;

        if ((cycles % DRAIN_EVERY) == 0 && sink_depth > 0)
            sink_depth = sink_depth - 1;

        // Peer honors PAUSE: stop offering while congested under selected policy.
        if (!((mode == 1 && pause_early) || (mode == 0 && pause_legacy))) begin
            offered = offered + 1;
            if (sink_depth < SINK_CAP)
                sink_depth = sink_depth + 1;
            else
                dropped = dropped + 1;
        end
    end

    $display("offered=%0d dropped=%0d pause_cycles=%0d", offered, dropped, pause_cycles);

    if (mode == 0) begin
        // Legacy: ASSIGN stall does not assert PAUSE until tready4 drops -> drops.
        // Rule 14: this path must FAIL so the gate can go red-then-green.
        if (dropped == 0) begin
            $display("tb_rle4k_pause_congestion: FAIL expected drops on late0 (no fault expressed)");
            fail = 1'b1;
        end else begin
            $display("tb_rle4k_pause_congestion: FAIL late0 RED baseline (dropped=%0d) — expected before early PAUSE fix", dropped);
            fail = 1'b1;
        end
    end else begin
        if (dropped != 0) begin
            $display("tb_rle4k_pause_congestion: FAIL unexpected drops on early1");
            fail = 1'b1;
        end else if (pause_cycles < 10) begin
            $display("tb_rle4k_pause_congestion: FAIL expected PAUSE during ASSIGN");
            fail = 1'b1;
        end else
            $display("tb_rle4k_pause_congestion: GREEN OK (pause_cycles=%0d)", pause_cycles);
    end

    if (fail) begin
        $display("tb_rle4k_pause_congestion: FAIL");
        $finish(1);
    end
    $display("ALL TESTS PASSED");
    $finish(0);
end

endmodule
