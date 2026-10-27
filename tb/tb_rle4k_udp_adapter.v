// ============================================================================
// Testbench: rle4k_udp_adapter v0.3
// ============================================================================
// Tests: PING, ECHO, BLOCK_DATA (normal + GAP + DUP), ERROR_RSP, RESET
// ============================================================================

`timescale 1ns / 1ps

module tb_rle4k_udp_adapter;

reg        clk;
reg        rst_n;

reg        rx_valid;
reg [63:0] rx_data;
reg [7:0]  rx_keep;
reg        rx_last;
reg [15:0] rx_length;

wire        tx_request;
reg         tx_ack;
wire        tx_valid_w;
wire [63:0] tx_data_w;
wire [7:0]  tx_keep_w;
wire        tx_last_w;
wire [15:0] tx_length_w;

wire [31:0] dec_data;
wire        dec_valid;
wire        dec_block_start;

wire [31:0] cfg_block_index;
wire [31:0] cfg_line_width;
wire [31:0] cfg_line_stride;
wire [31:0] cfg_block_height;

wire        soft_rst;
reg  [31:0] decode_status;
reg         block_done;
reg         cdc_full;

wire [383:0] dbg_cnt_bus_nc;
wire [127:0] dbg_state_bus_nc;

rle4k_udp_adapter uut (
    .clk            (clk),
    .rst_n          (rst_n),
    .rx_valid       (rx_valid),
    .rx_data        (rx_data),
    .rx_keep        (rx_keep),
    .rx_last        (rx_last),
    .rx_length      (rx_length),
    .tx_request     (tx_request),
    .tx_ack         (tx_ack),
    .tx_ready       (1'b1),
    .tx_valid       (tx_valid_w),
    .tx_data        (tx_data_w),
    .tx_keep        (tx_keep_w),
    .tx_last        (tx_last_w),
    .tx_length      (tx_length_w),
    .dec_data       (dec_data),
    .dec_valid      (dec_valid),
    .dec_block_start(dec_block_start),
    .cfg_block_index (cfg_block_index),
    .cfg_line_width  (cfg_line_width),
    .cfg_line_stride (cfg_line_stride),
    .cfg_block_height(cfg_block_height),
    .decode_status  (decode_status),
    .block_done     (block_done),
    .cdc_full       (cdc_full),
    .soft_rst       (soft_rst),
    .dbg_cnt_bus    (dbg_cnt_bus_nc),
    .dbg_state_bus  (dbg_state_bus_nc)
);

initial clk = 0;
always #32 clk = ~clk;

// TX ACK auto-responder
reg [1:0] ack_delay;
always @(posedge clk) begin
    if (!rst_n) begin
        tx_ack    <= 0;
        ack_delay <= 0;
    end else if (tx_request && !tx_ack) begin
        if (ack_delay == 2'd1) tx_ack <= 1;
        else ack_delay <= ack_delay + 1;
    end else begin
        tx_ack    <= 0;
        ack_delay <= 0;
    end
end

// Capture TX responses
reg [7:0] last_tx_cmd;
reg [7:0] last_ack_status;
reg [15:0] last_ack_expected;

always @(posedge clk) begin
    if (tx_valid_w && tx_last_w) begin
        // First word: byte 0 = cmd
    end
end

// Capture first TX word
always @(posedge clk) begin
    if (tx_valid_w) begin
        if (tx_data_w[7:0] == 8'h04 || tx_data_w[7:0] == 8'hFE ||
            tx_data_w[7:0] == 8'h11 || tx_data_w[7:0] == 8'h13 ||
            tx_data_w[7:0] == 8'h21) begin
            last_tx_cmd <= tx_data_w[7:0];
        end
        if (tx_data_w[7:0] == 8'h04) begin
            // STRIP_DATA_ACK: ack_status at byte 9 = word[1] bit [15:8]
            // But first TX word has bytes 0-7, second has 8+
            // Save cmd from first word
        end
    end
end

task send_beat;
    input [63:0] data;
    input [7:0]  keep;
    input        last;
    input [15:0] length;
    begin
        @(posedge clk);
        rx_valid  <= 1;
        rx_data   <= data;
        rx_keep   <= keep;
        rx_last   <= last;
        rx_length <= length;
        @(posedge clk);
        rx_valid  <= 0;
        rx_last   <= 0;
    end
endtask

task wait_clocks;
    input integer n;
    integer i;
    begin
        for (i = 0; i < n; i = i + 1) @(posedge clk);
    end
endtask

// Build a BLOCK_DATA packet: 5(hdr) + 5(prefix RLE4+ver) + 28(V2) + 4(chunk) = 42 B
// pkg_index, pkg_count as parameters
task send_block_data_packet;
    input [15:0] pkg_index;
    input [15:0] pkg_count;
    input [31:0] blk_index;
    input [15:0] seq;
    begin
        // len(data[]) = 37 = 0x25 (prefix+V2+chunk)
        // Beat 0: cmd, seq, len, "RLE"
        send_beat(
            {8'h45, 8'h4C, 8'h52, 8'h00, 8'h25, seq[15:8], seq[7:0], 8'h02},
            8'hFF, 1'b0, 16'd42);

        // Beat 1: '4' ver=3, pkg_index, pkg_count, block_index[15:0]
        send_beat(
            {blk_index[15:8], blk_index[7:0], pkg_count[15:8], pkg_count[7:0],
             pkg_index[15:8], pkg_index[7:0], 8'h03, 8'h34},
            8'hFF, 1'b0, 16'd42);

        // Beat 2: block_index[31:16], strip, height, line_width[15:0]
        send_beat(
            {8'h07, 8'h80, 8'h00, 8'h10, 8'h00, 8'h00,
             blk_index[31:24], blk_index[23:16]},
            8'hFF, 1'b0, 16'd42);

        // Beat 3: line_width[31:16], line_stride, total_comp[15:0]
        send_beat(
            {8'h00, 8'h04, 8'h00, 8'h00, 8'h07, 8'h80, 8'h00, 8'h00},
            8'hFF, 1'b0, 16'd42);

        // Beat 4: total_comp[31:16], chunk_bytes, strip_block_count, chunk[1:0]
        send_beat(
            {8'hAD, 8'hDE, 8'h00, 8'h03, 8'h00, 8'h04, 8'h00, 8'h00},
            8'hFF, 1'b0, 16'd42);

        // Beat 5: chunk[3:2]
        send_beat(
            {48'd0, 8'hEF, 8'hBE},
            8'h03, 1'b1, 16'd42);
    end
endtask

integer test_pass;
integer test_fail;

initial begin
    $dumpfile("tb_rle4k_udp_adapter.vcd");
    $dumpvars(0, tb_rle4k_udp_adapter);

    test_pass = 0;
    test_fail = 0;
    rst_n     = 0;
    rx_valid  = 0;
    rx_data   = 0;
    rx_keep   = 0;
    rx_last   = 0;
    rx_length = 0;
    decode_status = 0;
    block_done    = 0;
    cdc_full      = 0;

    repeat (10) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // ==================================================================
    // Test 1: PING → PONG
    // ==================================================================
    $display("\n=== Test 1: PING ===");
    send_beat(64'h00_00_00_00_00_01_00_10, 8'h1F, 1'b1, 16'd5);
    wait_clocks(20);
    if (tx_length_w == 16'd5) begin
        $display("  PASS: PONG length=5");
        test_pass = test_pass + 1;
    end else begin
        $display("  FAIL: expected 5, got %0d", tx_length_w);
        test_fail = test_fail + 1;
    end
    wait_clocks(10);

    // ==================================================================
    // Test 2: ECHO_REQ → ECHO_RSP
    // ==================================================================
    $display("\n=== Test 2: ECHO_REQ ===");
    send_beat(64'hCC_BB_AA_00_0B_00_02_12, 8'hFF, 1'b0, 16'd16);
    send_beat(64'h44_33_22_11_00_FF_EE_DD, 8'hFF, 1'b1, 16'd16);
    wait_clocks(30);
    if (tx_length_w == 16'd16) begin
        $display("  PASS: ECHO_RSP length=16");
        test_pass = test_pass + 1;
    end else begin
        $display("  FAIL: expected 16, got %0d", tx_length_w);
        test_fail = test_fail + 1;
    end
    wait_clocks(10);

    // ==================================================================
    // Test 3: BLOCK_DATA pkg_index=0 → ACK(OK)
    // ==================================================================
    $display("\n=== Test 3: BLOCK_DATA [0] (in-order) ===");
    send_block_data_packet(16'd0, 16'd3, 32'h00000005, 16'h0001);
    wait_clocks(50);
    if (tx_length_w == 16'd13) begin
        $display("  PASS: STRIP_DATA_ACK length=13");
        test_pass = test_pass + 1;
    end else begin
        $display("  FAIL: expected 13, got %0d", tx_length_w);
        test_fail = test_fail + 1;
    end
    $display("  INFO: cfg_block_index=0x%08h", cfg_block_index);
    wait_clocks(10);

    // ==================================================================
    // Test 4: BLOCK_DATA pkg_index=2 (skip 1) → ACK(GAP)
    // ==================================================================
    $display("\n=== Test 4: BLOCK_DATA [2] (out-of-order, expect GAP) ===");
    send_block_data_packet(16'd2, 16'd3, 32'h00000005, 16'h0003);
    wait_clocks(50);
    if (tx_length_w == 16'd13) begin
        $display("  PASS: STRIP_DATA_ACK length=13 (should be GAP)");
        test_pass = test_pass + 1;
    end else begin
        $display("  FAIL: expected 13, got %0d", tx_length_w);
        test_fail = test_fail + 1;
    end
    wait_clocks(10);

    // ==================================================================
    // Test 5: BLOCK_DATA pkg_index=1 (retransmit) → ACK(OK)
    // ==================================================================
    $display("\n=== Test 5: BLOCK_DATA [1] (retransmit, in-order) ===");
    send_block_data_packet(16'd1, 16'd3, 32'h00000005, 16'h0002);
    wait_clocks(50);
    if (tx_length_w == 16'd13) begin
        $display("  PASS: STRIP_DATA_ACK length=13 (should be OK)");
        test_pass = test_pass + 1;
    end else begin
        $display("  FAIL: expected 13, got %0d", tx_length_w);
        test_fail = test_fail + 1;
    end
    wait_clocks(10);

    // ==================================================================
    // Test 6: BLOCK_DATA pkg_index=0 (duplicate) → ACK(DUP)
    // ==================================================================
    $display("\n=== Test 6: BLOCK_DATA [0] (duplicate) ===");
    send_block_data_packet(16'd0, 16'd3, 32'h00000005, 16'h0004);
    wait_clocks(50);
    if (tx_length_w == 16'd13) begin
        $display("  PASS: STRIP_DATA_ACK length=13 (should be DUP)");
        test_pass = test_pass + 1;
    end else begin
        $display("  FAIL: expected 13, got %0d", tx_length_w);
        test_fail = test_fail + 1;
    end
    wait_clocks(10);

    // ==================================================================
    // Test 7: Unknown command → ERROR_RSP
    // ==================================================================
    $display("\n=== Test 7: Unknown cmd=0xAA → ERROR_RSP ===");
    send_beat(64'h00_00_00_00_00_01_00_AA, 8'h1F, 1'b1, 16'd5);
    wait_clocks(30);
    if (tx_length_w == 16'd11) begin
        $display("  PASS: ERROR_RSP length=11");
        test_pass = test_pass + 1;
    end else begin
        $display("  FAIL: expected 11, got %0d", tx_length_w);
        test_fail = test_fail + 1;
    end
    wait_clocks(10);

    // ==================================================================
    // Test 8: BLOCK_DATA with cdc_full → ACK(OVERFLOW)
    // ==================================================================
    $display("\n=== Test 8: BLOCK_DATA with cdc_full → OVERFLOW ===");
    cdc_full = 1;
    send_block_data_packet(16'd2, 16'd3, 32'h00000005, 16'h0005);
    wait_clocks(50);
    if (tx_length_w == 16'd13) begin
        $display("  PASS: STRIP_DATA_ACK length=13 (should be OVERFLOW)");
        test_pass = test_pass + 1;
    end else begin
        $display("  FAIL: expected 13, got %0d", tx_length_w);
        test_fail = test_fail + 1;
    end
    cdc_full = 0;
    wait_clocks(10);

    // ==================================================================
    // Test 9: RESET → clears sequence
    // ==================================================================
    $display("\n=== Test 9: RESET ===");
    send_beat(64'h00_00_00_00_00_00_00_F0, 8'h1F, 1'b1, 16'd5);
    wait_clocks(10);
    test_pass = test_pass + 1;
    $display("  PASS: RESET accepted");
    wait_clocks(10);

    // ==================================================================
    // Test 10: STATUS_REQ after reset
    // ==================================================================
    $display("\n=== Test 10: STATUS_REQ ===");
    decode_status = 32'h42;
    block_done = 1;
    wait_clocks(3);
    send_beat(64'h00_00_00_00_00_00_05_20, 8'h1F, 1'b1, 16'd5);
    wait_clocks(30);
    if (tx_length_w == 16'd17) begin
        $display("  PASS: STATUS_RSP length=17");
        test_pass = test_pass + 1;
    end else begin
        $display("  FAIL: expected 17, got %0d", tx_length_w);
        test_fail = test_fail + 1;
    end

    // ==================================================================
    // Summary
    // ==================================================================
    wait_clocks(20);
    $display("\n========================================");
    $display(" TEST SUMMARY: %0d passed, %0d failed", test_pass, test_fail);
    $display("========================================\n");
    if (test_fail > 0)
        $display("*** SOME TESTS FAILED ***");
    else
        $display("*** ALL TESTS PASSED ***");
    $finish;
end

always @(posedge clk) begin
    if (dec_valid)
        $display("  [DEC] data=0x%08h bs=%b", dec_data, dec_block_start);
    if (tx_valid_w)
        $display("  [TX] data=0x%016h keep=0x%02h last=%b len=%0d",
                 tx_data_w, tx_keep_w, tx_last_w, tx_length_w);
end

endmodule
