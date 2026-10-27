// ============================================================================
// Testbench: RLE4K LAN Top (UDP adapter + decoder integration)
// ============================================================================
// Simulates the rle4k_udp_adapter + rle4k_decoder_core pipeline without
// the RGMII PHY or supplier MAC/IP stack. Instead, drives the adapter's
// RX interface directly with synthetic UDP payloads.
// ============================================================================

`timescale 1ns / 1ps

module tb_rle4k_lan_top;

// Clock periods
localparam CLK_PERIOD = 64;  // 15.625 MHz = 64 ns
localparam SYS_CLK_PERIOD = 8; // 125 MHz = 8 ns

reg clk;
reg sys_clk;
reg rst_n;

initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

initial sys_clk = 0;
always #(SYS_CLK_PERIOD/2) sys_clk = ~sys_clk;

initial begin
    rst_n = 0;
    #200;
    rst_n = 1;
end

// --- Adapter RX stimulus ---
reg        rx_valid;
reg [63:0] rx_data;
reg [7:0]  rx_keep;
reg        rx_last;
reg [15:0] rx_length;

// --- Adapter TX capture ---
wire        tx_request;
wire        tx_valid;
wire [63:0] tx_data;
wire [7:0]  tx_keep;
wire        tx_last;
wire [15:0] tx_length;

// --- Decoder outputs ---
wire [31:0] dec_data;
wire        dec_valid;
wire        dec_block_start;
wire        soft_rst;

wire [31:0] cfg_block_index;
wire [31:0] cfg_line_width;
wire [31:0] cfg_line_stride;
wire [31:0] cfg_block_height;

// Stub decoder feedback / CDC
wire [31:0] decode_status = 32'd0;
wire        block_done    = 1'b0;
wire        cdc_full      = 1'b0;

wire [383:0] dbg_cnt_bus_nc;
wire [127:0] dbg_state_bus_nc;

rle4k_udp_adapter u_dut (
    .clk             (clk),
    .rst_n           (rst_n),
    .rx_valid        (rx_valid),
    .rx_data         (rx_data),
    .rx_keep         (rx_keep),
    .rx_last         (rx_last),
    .rx_length       (rx_length),
    .tx_request      (tx_request),
    .tx_ack          (1'b1),
    .tx_ready        (1'b1),
    .tx_valid        (tx_valid),
    .tx_data         (tx_data),
    .tx_keep         (tx_keep),
    .tx_last         (tx_last),
    .tx_length       (tx_length),
    .dec_data        (dec_data),
    .dec_valid       (dec_valid),
    .dec_block_start (dec_block_start),
    .cfg_block_index (cfg_block_index),
    .cfg_line_width  (cfg_line_width),
    .cfg_line_stride (cfg_line_stride),
    .cfg_block_height(cfg_block_height),
    .decode_status   (decode_status),
    .block_done      (block_done),
    .cdc_full        (cdc_full),
    .soft_rst        (soft_rst),
    .dbg_cnt_bus     (dbg_cnt_bus_nc),
    .dbg_state_bus   (dbg_state_bus_nc)
);

// ============================================================================
// Test stimulus
// ============================================================================
initial begin
    rx_valid  = 0;
    rx_data   = 64'd0;
    rx_keep   = 8'hFF;
    rx_last   = 0;
    rx_length = 16'd0;

    @(posedge rst_n);
    #500;

    // --- Test 1: PING ---
    $display("[TB] Sending PING");
    @(posedge clk);
    rx_valid  = 1;
    // PayloadHeader: cmd=0x10(PING), seq=0x0001, len=0x0000
    rx_data   = {24'd0, 8'h00, 8'h00, 8'h01, 8'h00, 8'h10};
    rx_keep   = 8'h1F; // 5 valid bytes
    rx_last   = 1;
    rx_length = 16'd5;
    @(posedge clk);
    rx_valid  = 0;
    rx_last   = 0;
    #1000;

    // --- Test 2: ECHO_REQ with 4-byte payload ---
    $display("[TB] Sending ECHO_REQ (4 bytes)");
    @(posedge clk);
    rx_valid  = 1;
    // PayloadHeader: cmd=0x12(ECHO_REQ), seq=0x0002, len=0x0004
    // Data: 0xDEADBEEF (bytes 5-8)
    rx_data   = {8'hDE, 8'hAD, 8'hBE, 8'h04, 8'h00, 8'h02, 8'h00, 8'h12};
    rx_keep   = 8'hFF;
    rx_last   = 0;
    rx_length = 16'd9;
    @(posedge clk);
    rx_data   = {56'd0, 8'hEF};
    rx_keep   = 8'h01;
    rx_last   = 1;
    @(posedge clk);
    rx_valid  = 0;
    rx_last   = 0;
    #1000;

    // --- Test 3: RESET ---
    $display("[TB] Sending RESET");
    @(posedge clk);
    rx_valid  = 1;
    rx_data   = {24'd0, 8'h00, 8'h00, 8'h00, 8'h00, 8'hF0};
    rx_keep   = 8'h1F;
    rx_last   = 1;
    rx_length = 16'd5;
    @(posedge clk);
    rx_valid  = 0;
    rx_last   = 0;
    #500;

    $display("[TB] All tests complete");
    $finish;
end

// Monitor
always @(posedge clk) begin
    if (dec_valid)
        $display("[TB] dec_data=%h dec_block_start=%b", dec_data, dec_block_start);
    if (soft_rst)
        $display("[TB] soft_rst asserted");
end

endmodule
