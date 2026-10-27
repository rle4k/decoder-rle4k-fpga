// ============================================================================
// tb_phy_reset -- pulse width and strap-latch behaviour of rle4k_phy_reset
// ============================================================================
// Gate before the board: the RTL this replaced asserted PHY reset for 4 us,
// which is far below the millisecond-range minimum every gigabit PHY specifies
// and below anything that reliably latches the configuration straps. This
// checks the replacement actually holds reset long enough, releases exactly
// once, and re-asserts if the MMCM drops lock.
// ============================================================================

`timescale 1ns / 1ps

module tb_phy_reset;

localparam real CLK_HZ     = 25_000_000.0;
localparam      CLK_HALF   = 20;        // ns -> 25 MHz
localparam real MIN_MS     = 10.0;      // datasheet floor we must clear

reg clk = 1'b0;
reg enable = 1'b0;
wire phy_rst_n;

always #CLK_HALF clk = ~clk;

rle4k_phy_reset u_dut (
    .clk       (clk),
    .enable    (enable),
    .phy_rst_n (phy_rst_n)
);

integer errors = 0;
integer release_edges = 0;
real    assert_start_ns;
real    assert_width_ns;
real    assert_width_ms;

// Count every low->high transition so a glitching or re-triggering reset is
// caught rather than averaged away.
reg phy_rst_n_d = 1'b0;
always @(posedge clk) begin
    phy_rst_n_d <= phy_rst_n;
    if (phy_rst_n && !phy_rst_n_d)
        release_edges = release_edges + 1;
end

task check;
    input        cond;
    input [1023:0] name;
    begin
        if (cond) begin
            $display("  PASS  %0s", name);
        end else begin
            $display("  FAIL  %0s", name);
            errors = errors + 1;
        end
    end
endtask

initial begin
    $display("=== tb_phy_reset ===");

    @(negedge clk);
    check(phy_rst_n === 1'b0, "reset asserted while enable low");

    // Release the MMCM lock and time the assertion.
    assert_start_ns = $realtime;
    enable = 1'b1;

    @(posedge phy_rst_n);
    assert_width_ns = $realtime - assert_start_ns;
    assert_width_ms = assert_width_ns / 1_000_000.0;
    $display("  assertion width = %0.3f ms (%0.0f ns)", assert_width_ms, assert_width_ns);

    check(assert_width_ms >= MIN_MS,
          "assertion width clears the 10 ms datasheet floor");

    // Stay released: the strap pins are sampled on this edge, so a second edge
    // would resample them and is a defect in itself.
    // release_edges is registered, so give it a clock to catch up before
    // reading it -- otherwise this races the edge it is meant to count.
    repeat (2000) @(posedge clk);
    check(phy_rst_n === 1'b1, "reset stays released after the terminal count");
    check(release_edges == 1, "exactly one release edge");

    // Losing MMCM lock must re-run the whole sequence, not leave the PHY
    // running against a clock that stopped.
    enable = 1'b0;
    repeat (10) @(posedge clk);
    check(phy_rst_n === 1'b0, "reset re-asserts when lock is lost");

    assert_start_ns = $realtime;
    enable = 1'b1;
    @(posedge phy_rst_n);
    assert_width_ms = ($realtime - assert_start_ns) / 1_000_000.0;
    $display("  re-assertion width = %0.3f ms", assert_width_ms);
    check(assert_width_ms >= MIN_MS, "re-assertion is full length, not shortened");
    repeat (4) @(posedge clk);
    check(release_edges == 2, "second release edge accounted for");

    $display("--------------------------------------------");
    if (errors == 0)
        $display("*** ALL TESTS PASSED ***");
    else
        $display("*** %0d CHECK(S) FAILED -- TEST FAILED ***", errors);
    $finish;
end

// $fatal leaves XSim sitting at an interactive prompt instead of exiting, so
// every exit path here is $finish and the runner script gates on the log text.
initial begin
    #200_000_000;   // 200 ms
    $display("*** TIMEOUT ***");
    $finish;
end

endmodule
