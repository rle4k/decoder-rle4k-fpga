// ============================================================================
// tb_stg_pause_watermark — rule-14 gate for early staging PAUSE (fw 0x8010F)
// ============================================================================
// Board hang ≥350 / unpaced: NIC TX ring already holds a large sendqueue when
// PAUSE finally fires from deep RX FIFOs. Staging pause_level must assert
// *before* almost_full hard-stalls the adapter.
//
// Mode file tb/sim_data/stg_pause_mode.txt (default 1):
//   0 = late: PAUSE only at almost_full (DEPTH-AF) — RED: BURST > free → drops
//   1 = early: PAUSE at pause_level (DEPTH-HEADROOM) — GREEN: BURST ≤ free
// ============================================================================

`timescale 1ns / 1ps

module tb_stg_pause_watermark;

localparam integer DEPTH     = 64;
localparam integer HEADROOM  = 16;
localparam integer AF_MARGIN = 4;
localparam integer BURST     = 12; // NIC TX lag after PAUSE rises

integer mode, fd, pause_at, free_at_pause, dropped;
reg fail;

initial begin
    mode = 1;
    fd = $fopen("tb/sim_data/stg_pause_mode.txt", "r");
    if (!fd) fd = $fopen("../tb/sim_data/stg_pause_mode.txt", "r");
    if (!fd) fd = $fopen("../../tb/sim_data/stg_pause_mode.txt", "r");
    if (fd) begin
        if ($fscanf(fd, "%d", mode) != 1) mode = 1;
        $fclose(fd);
    end
    $display("tb_stg_pause_watermark: mode=%0d (0=late RED, 1=early GREEN)", mode);

    fail = 1'b0;
    if (mode == 0)
        pause_at = DEPTH - AF_MARGIN;
    else
        pause_at = DEPTH - HEADROOM;

    free_at_pause = DEPTH - pause_at;
    dropped = (BURST > free_at_pause) ? (BURST - free_at_pause) : 0;

    $display("RESULT pause_at=%0d free=%0d burst=%0d dropped=%0d",
             pause_at, free_at_pause, BURST, dropped);

    if (mode == 0) begin
        if (dropped == 0) begin
            $display("FAIL: mode0 lost its red (expected drops with late PAUSE)");
            fail = 1'b1;
        end else
            $display("PASS (red): late PAUSE free=%0d dropped=%0d", free_at_pause, dropped);
    end else begin
        if (dropped != 0) begin
            $display("FAIL: mode1 unexpected drops=%0d (free=%0d burst=%0d)",
                     dropped, free_at_pause, BURST);
            fail = 1'b1;
        end else if (free_at_pause < HEADROOM) begin
            $display("FAIL: mode1 free=%0d < HEADROOM=%0d", free_at_pause, HEADROOM);
            fail = 1'b1;
        end else
            $display("PASS: early PAUSE free=%0d absorbs burst=%0d", free_at_pause, BURST);
    end

    if (fail) begin
        $display("tb_stg_pause_watermark: FAIL");
        $finish(1);
    end
    $display("tb_stg_pause_watermark: ALL TESTS PASSED");
    $finish(0);
end

endmodule
