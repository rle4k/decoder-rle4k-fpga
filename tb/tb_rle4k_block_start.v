// ============================================================================
// tb_rle4k_block_start -- Defect B: is .block_start(1'b0) intentional or a bug?
// ============================================================================
// rle4k_decoder_core.v uses block_start for three things:
//   1. line 431-450  full re-init of the run-dispatcher datapath
//   2. line 499      .clear on decoder_output_accumulator
//   3. line 601-616  reset of decoded_block_line_count AND the only place where
//                    the configuration is validated (error_code 0x01 EmptyData /
//                    0x03 ParamError) and where error_code / param_error_flag
//                    are ever cleared.
// rle4k_lan_top_v8.v line 356 ties it to 1'b0, so (3) is unreachable in the
// shipped design: an illegal STREAM_START can never raise 0x03.
//
// This testbench sends a STREAM_START with line_stride < line_width, which
// rle4k_decoder_core.v line 607-608 is written to reject with error 0x03, and
// checks decode_status[7:0].
//
//   default build          -> tb_rle4k_chain BLOCK_START_MODE=0 (shipped)
//                             expect NO 0x03: the check is dead code -> FAIL
//   -d BLOCK_START_FIX     -> BLOCK_START_MODE=1 (proposed fix)
//                             expect 0x03 -> PASS
//
// No RLE payload is sent: the parameter check happens at configuration time.
// ============================================================================

`timescale 1ns / 1ps

module tb_rle4k_block_start;

`ifdef BLOCK_START_FIX
localparam integer BS_MODE = 1;
localparam         BS_NAME = "BLOCK_START_MODE=1 (proposed fix)";
`else
localparam integer BS_MODE = 0;
localparam         BS_NAME = "BLOCK_START_MODE=0 (shipped rle4k_lan_top_v8)";
`endif

reg clk_125    = 1'b0;
reg clk_15_625 = 1'b0;
always #4  clk_125    = ~clk_125;
always #32 clk_15_625 = ~clk_15_625;

reg locked     = 1'b0;
reg core_reset = 1'b1;

reg         mac_rx_data_valid = 1'b0;
reg  [63:0] mac_rx_data       = 64'd0;
reg  [7:0]  mac_rx_keep       = 8'd0;
reg         mac_rx_last       = 1'b0;
wire        mac_rx_ready;

wire        mac_tx_data_valid;
wire [63:0] mac_tx_data;
wire [7:0]  mac_tx_keep;
wire        mac_tx_last;
reg         mac_tx_ready = 1'b1;

wire        app_rx_data_valid;
wire        app_rx_data_last;
wire [15:0] app_rx_data_length;
wire        soft_rst;
wire        cdc_full;
wire        dec_valid;
wire [31:0] stream_rx_bytes;
wire [31:0] mon_rx_datagrams;
wire [31:0] mon_stream_start;
wire [31:0] mon_stream_data;
wire [31:0] mon_stream_end;
wire [31:0] mon_err_rsp;
wire [5:0]  adapter_state;
wire        word_decoded_valid;
wire        block_done_raw;
wire        strip_end_raw;
wire [31:0] decode_status_raw;
wire [31:0] crc32_accum;
wire [31:0] crc32_latched;
wire [31:0] crc32_word_count;
wire [31:0] crc32_word_count_latched;
wire        crc32_done;

tb_rle4k_chain #(
    .LOCAL_MAC        (48'h000A35000102),
    .BLOCK_START_MODE (BS_MODE)
) u_chain (
    .clk_15_625 (clk_15_625),
    .clk_125    (clk_125),
    .core_reset (core_reset),
    .locked     (locked),

    .mac_rx_data_valid (mac_rx_data_valid),
    .mac_rx_data       (mac_rx_data),
    .mac_rx_keep       (mac_rx_keep),
    .mac_rx_last       (mac_rx_last),
    .mac_rx_ready       (mac_rx_ready),

    .mac_tx_data_valid (mac_tx_data_valid),
    .mac_tx_data       (mac_tx_data),
    .mac_tx_keep       (mac_tx_keep),
    .mac_tx_ready      (mac_tx_ready),
    .mac_tx_last       (mac_tx_last),

    .app_rx_data_valid  (app_rx_data_valid),
    .app_rx_data_last   (app_rx_data_last),
    .app_rx_data_length (app_rx_data_length),
    .soft_rst           (soft_rst),
    .cdc_full           (cdc_full),
    .dec_valid          (dec_valid),
    .stream_rx_bytes    (stream_rx_bytes),
    .mon_rx_datagrams   (mon_rx_datagrams),
    .mon_stream_start   (mon_stream_start),
    .mon_stream_data    (mon_stream_data),
    .mon_stream_end     (mon_stream_end),
    .mon_err_rsp        (mon_err_rsp),
    .adapter_state      (adapter_state),
    .word_decoded_valid (word_decoded_valid),
    .block_done_raw     (block_done_raw),
    .strip_end_raw      (strip_end_raw),
    .decode_status_raw  (decode_status_raw),

    .crc32_accum_o              (crc32_accum),
    .crc32_latched_o            (crc32_latched),
    .crc32_word_count_o         (crc32_word_count),
    .crc32_word_count_latched_o (crc32_word_count_latched),
    .crc32_done_o               (crc32_done)
);

`include "tb_rle4k_eth_stim.vh"

task wait_chain_idle;
    integer guard;
    begin
        guard = 0;
        while ((u_chain.u_adapter.state !== 6'd0 ||
                u_chain.u_mac_proto.rx_state !== 2'd0) && guard < 1_000_000) begin
            @(negedge clk_15_625);
            guard = guard + 1;
        end
        repeat (4) @(negedge clk_15_625);
    end
endtask

reg [7:0] status_low;
reg [7:0] err_seen;
reg       saw_param_error;
reg       test_pass;
integer   i;

// Latch any error code the core raises (error_code is sticky once set)
always @(posedge clk_125) begin
    if (!saw_param_error &&
        (decode_status_raw[7:0] == 8'h01 || decode_status_raw[7:0] == 8'h03)) begin
        saw_param_error <= 1'b1;
        err_seen        <= decode_status_raw[7:0];
    end
end

initial begin
    saw_param_error = 1'b0;
    err_seen        = 8'h00;
    test_pass       = 1'b1;
    frames_driven   = 0;
    words_driven    = 0;
    seq_ctr         = 16'd0;

    load_sim_config();

    $display("================================================================");
    $display(" tb_rle4k_block_start -- %0s", BS_NAME);
    $display("================================================================");
    $display("  Stimulus: STREAM_START with line_stride(1024) < line_width(65536)");
    $display("  rle4k_decoder_core.v:607 should latch error_code 0x03 (ParamError)");

    core_reset = 1'b1;
    locked     = 1'b0;
    repeat (5)  @(negedge clk_15_625);
    locked     = 1'b1;
    repeat (10) @(negedge clk_15_625);
    core_reset = 1'b0;
    repeat (10) @(negedge clk_15_625);

    build_reset_frame();
    drive_frame(0);
    wait_chain_idle();
    repeat (20) @(negedge clk_15_625);

    // Illegal geometry: stride < width
    build_stream_start_frame_ex(32'd65536, 32'd1024, 32'd771,
                                cfg_wire_bytes_i, 16'd512, cfg_rle_payload_i);
    drive_frame(0);
    wait_chain_idle();
    repeat (400) @(posedge clk_125);

    status_low = decode_status_raw[7:0];

    $display("");
    $display("  ======== block_start SEMANTICS PROBE ========");
    $display("  cfg reaching the core : lw=%0d ls=%0d bh=%0d",
             u_chain.cfg_lw_s2, u_chain.cfg_ls_s2, u_chain.cfg_bh_s2);
    $display("  block_start pulses seen by the core : %0s",
             (BS_MODE != 0) ? "yes (strip_byte_cnt_rst delayed 1 cycle)" : "no (tied 1'b0)");
    $display("  decode_status            = 0x%08x", decode_status_raw);
    $display("  decode_status[7:0]       = 0x%02x", status_low);
    $display("  param error latched      = %0d (code 0x%02x)", saw_param_error, err_seen);
    $display("  core error_code register = 0x%02x  param_error_flag = %0d",
             u_chain.u_decoder.error_code, u_chain.u_decoder.param_error_flag);

    if (saw_param_error && err_seen == 8'h03) begin
        $display("  Parameter validation RAN and rejected the geometry: PASS");
    end else begin
        $display("  Parameter validation NEVER RAN (error_code stayed 0x%02x): FAIL",
                 u_chain.u_decoder.error_code);
        $display("  -> decode_status[7:0]=0x%02x is live status bits, not an error code",
                 status_low);
        test_pass = 1'b0;
    end

    if (test_pass)
        $display("  *** ALL TESTS PASSED ***");
    else
        $display("  *** TEST FAILED ***");
    $display("  =============================================");
    $finish;
end

initial begin
    #20_000_000;
    $display("TIMEOUT at %0t", $time);
    $display("  *** TEST FAILED ***");
    $finish;
end

endmodule
