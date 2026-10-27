// ============================================================================
// tb_rle4k_pause_ctrl -- PAUSE backpressure gate (rule 14)
// ============================================================================
// plusarg honor=0 -> peer ignores PAUSE (RED baseline)
// plusarg honor=1 -> peer honors PAUSE (GREEN, default)
// ============================================================================

`timescale 1ns / 1ps

module tb_rle4k_pause_ctrl;

reg tx_clk = 1'b0;
always #4 tx_clk = ~tx_clk;

reg tx_reset = 1'b1;
reg congested = 1'b0;

wire        pause_req;
wire [15:0] pause_val;
wire        congested_sync;

rle4k_pause_ctrl #(
    .P_PAUSE_QUANTA  (16'h0010),
    .P_RETRIG_CYCLES (64)
) dut (
    .tx_clk          (tx_clk),
    .tx_reset        (tx_reset),
    .congested_async (congested),
    .pause_req       (pause_req),
    .pause_val       (pause_val),
    .congested_sync  (congested_sync)
);

integer mode;
integer lat_mode;
integer sink_depth;
integer offered, dropped, drained;
integer cycles;
integer pause_pulses, xon_pulses;
reg     peer_paused;
reg     fail;
reg     saw_pause_nonzero;
reg     pause_hold;

// Sink headroom. A PAUSE controller cannot save a buffer smaller than the
// latency-bandwidth product, so in lat_mode the sink is sized the way the board
// is: rx_async_fifo0 alone is 2048 x 8 B = 16 KB against a ~2.5 KB PAUSE round
// trip. Keeping 8 for lat_mode=0 leaves the legacy modes bit-identical.
integer sink_cap;
// lat_mode needs long enough for a controller that cancels its own XOFF to walk
// the sink past sink_cap; 400 cycles ends while it is still only ~half full.
integer offer_cycles;
localparam integer DRAIN_EVERY  = 8;
// Peer PAUSE reaction latency in tx_clk cycles. A NIC cannot stop the instant
// the TEMAC requests PAUSE: the 64-byte pause frame has to be serialised
// (512 ns = 64 cycles @125 MHz) and then parsed. 24 cycles is a deliberately
// generous under-estimate -- the point is only that it is non-zero.
localparam integer PEER_LAT     = 24;
reg [31:0] peer_pipe;

initial begin
    mode = 1;
    lat_mode = 0;
    peer_pipe = 32'd0;
    if ($test$plusargs("latency1")) lat_mode = 1;
    // Avoid honor=N plusarg: Windows may split on '='. Use honor0 / honor1 flags.
    if ($test$plusargs("honor0")) mode = 0;
    else if ($test$plusargs("honor1")) mode = 1;
    $display("tb_rle4k_pause_ctrl: mode=%0d (0=ignore RED, 1=honor GREEN) peer_lat=%0d",
             mode, lat_mode ? PEER_LAT : 0);

    sink_cap     = lat_mode ? 64 : 8;
    offer_cycles = lat_mode ? 4000 : 400;
    sink_depth = 0;
    offered = 0;
    dropped = 0;
    drained = 0;
    pause_pulses = 0;
    xon_pulses = 0;
    peer_paused = 1'b0;
    pause_hold = 1'b0;
    fail = 1'b0;
    saw_pause_nonzero = 1'b0;
    congested = 1'b0;

    tx_reset = 1'b1;
    repeat (10) @(posedge tx_clk);
    tx_reset = 1'b0;
    repeat (4) @(posedge tx_clk);

    for (cycles = 0; cycles < offer_cycles; cycles = cycles + 1) begin
        @(posedge tx_clk);
        #1;
        if (pause_req) begin
            if (pause_val != 16'h0) begin
                pause_pulses = pause_pulses + 1;
                saw_pause_nonzero = 1'b1;
                if (mode == 1) pause_hold = 1'b1;
            end else begin
                xon_pulses = xon_pulses + 1;
                if (mode == 1) pause_hold = 1'b0;
            end
        end
        // With lat_mode the peer applies the latest XOFF/XON PEER_LAT cycles
        // late. That is what makes an XOFF cancelled a few cycles later useless:
        // the peer never sees a window in which it is supposed to be stopped.
        if (lat_mode) begin
            peer_pipe = (peer_pipe << 1) | {31'd0, pause_hold};
            peer_paused = (mode == 1) && peer_pipe[PEER_LAT];
        end else begin
            peer_paused = (mode == 1) && pause_hold;
        end

        if ((cycles % DRAIN_EVERY) == 0 && sink_depth > 0) begin
            sink_depth = sink_depth - 1;
            drained = drained + 1;
        end

        if (!peer_paused) begin
            offered = offered + 1;
            if (sink_depth < sink_cap)
                sink_depth = sink_depth + 1;
            else
                dropped = dropped + 1;
        end

        congested = (sink_depth >= (sink_cap / 2));
    end

    repeat (80) begin
        @(posedge tx_clk);
        #1;
        if (pause_req && pause_val == 16'h0) begin
            xon_pulses = xon_pulses + 1;
            pause_hold = 1'b0;
        end
        if ((cycles % DRAIN_EVERY) == 0 && sink_depth > 0)
            sink_depth = sink_depth - 1;
        congested = (sink_depth >= (sink_cap / 2));
        cycles = cycles + 1;
    end

    $display("  offered=%0d dropped=%0d drained=%0d sink=%0d",
             offered, dropped, drained, sink_depth);
    $display("  pause_pulses=%0d xon_pulses=%0d saw_pause=%0d",
             pause_pulses, xon_pulses, saw_pause_nonzero);

    if (!saw_pause_nonzero) begin
        $display("FAIL: never pulsed non-zero pause_val");
        fail = 1'b1;
    end

    if (mode == 0) begin
        if (dropped == 0) begin
            $display("FAIL: mode0 lost its red (no drops)");
            fail = 1'b1;
        end else
            $display("PASS (red baseline): mode0 ignored PAUSE, dropped=%0d", dropped);
    end else begin
        if (dropped != 0) begin
            $display("FAIL: mode1 still dropped=%0d", dropped);
            fail = 1'b1;
        end else if (pause_pulses < 1) begin
            $display("FAIL: mode1 no PAUSE pulses");
            fail = 1'b1;
        end else
            $display("PASS: mode1 honor PAUSE, dropped=0 pause_pulses=%0d", pause_pulses);
    end

    if (fail) begin
        $display("tb_rle4k_pause_ctrl: FAIL");
        $finish(1);
    end
    $display("tb_rle4k_pause_ctrl: ALL TESTS PASSED");
    $finish(0);
end

endmodule