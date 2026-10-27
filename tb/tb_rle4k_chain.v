// ============================================================================
// tb_rle4k_chain -- simulation stand-in for rle4k_lan_top_v8 (pure RTL only)
// ============================================================================
// Contains everything rle4k_lan_top_v8.v instantiates EXCEPT the two blocks
// that need generated Xilinx IP:
//   - clk_wiz_0        -> clocks are supplied by the testbench
//   - master_wrapper_v8 -> TEMAC / axis_data_fifo_* / axis_dwidth_converter_* /
//                          vio_0 are IP; only its rle4k_mac_proto_v8 instance is
//                          pure RTL and is instantiated here directly, with the
//                          same LOCAL_MAC parameter and the same
//                          udp_tx_ready = 1'b1 tie-off master_wrapper_v8 uses.
//
// Everything else (CDC synchronizers, strip_cfg_toggle pulse, stream_end
// synchronizer, decoder_ready_r / skid buffer, CRC32 accumulator + latch, the
// 125 -> 15.625 status CDC) is copied verbatim from rle4k_lan_top_v8.v so that
// simulation results are directly comparable with the board.
//
// The testbench drives raw Ethernet frames at the MAC RX interface, i.e. at the
// exact point where rx_packet_fifo0 hands data to rle4k_mac_proto_v8.
// ============================================================================

`timescale 1ns / 1ps

module tb_rle4k_chain #(
    parameter [47:0] LOCAL_MAC           = 48'h000A35000102,
    parameter [31:0] P_WDT_TIMEOUT_TICKS = 32'd937_500_000,
    // 0 = shipped rle4k_lan_top_v8 behaviour: .block_start(1'b0)
    // 1 = proposed fix: strip_byte_cnt_rst_pulse delayed one clk_125 cycle, so
    //     the decoder's per-strip re-init and parameter validation actually run.
    parameter integer BLOCK_START_MODE   = 0
)(
    // Clocks / resets (top: clk_wiz_0 outputs + example_design_resets)
    input  wire        clk_15_625,
    input  wire        clk_125,
    input  wire        core_reset,
    input  wire        locked,

    // --- MAC RX: raw Ethernet frames, 64-bit LE, udp_core_clk domain ---
    input  wire        mac_rx_data_valid,
    input  wire [63:0] mac_rx_data,
    input  wire [7:0]  mac_rx_keep,
    input  wire        mac_rx_last,
    output wire        mac_rx_ready,

    // --- MAC TX: observed, ready is driven by the TB (see defect probe) ---
    output wire        mac_tx_data_valid,
    output wire [63:0] mac_tx_data,
    output wire [7:0]  mac_tx_keep,
    input  wire        mac_tx_ready,
    output wire        mac_tx_last,

    // --- Observation taps ---
    output wire        app_rx_data_valid,
    output wire        app_rx_data_last,
    output wire [15:0] app_rx_data_length,
    output wire        soft_rst,
    output wire        cdc_full,
    output wire        dec_valid,
    output wire [31:0] stream_rx_bytes,
    output wire [31:0] mon_rx_datagrams,
    output wire [31:0] mon_stream_start,
    output wire [31:0] mon_stream_data,
    output wire [31:0] mon_stream_end,
    output wire [31:0] mon_err_rsp,
    output wire [5:0]  adapter_state,
    output wire        word_decoded_valid,
    output wire        block_done_raw,
    output wire        strip_end_raw,
    output wire [31:0] decode_status_raw,
    output wire [31:0] crc32_accum_o,
    output wire [31:0] crc32_latched_o,
    output wire [31:0] crc32_word_count_o,
    output wire [31:0] crc32_word_count_latched_o,
    output wire        crc32_done_o
);

// ============================================================================
// MAC protocol (the only pure-RTL block inside master_wrapper_v8)
// ============================================================================
wire        app_rx_data_valid_w;
wire [63:0] app_rx_data;
wire [7:0]  app_rx_data_keep;
wire        app_rx_data_last_w;
wire [15:0] app_rx_data_length_w;

wire        app_rx_ready_w;
wire        app_tx_ready_w;
wire        cdc_almost_full;
wire        app_tx_ack;
wire        app_tx_request;
wire        app_tx_data_valid;
wire [63:0] app_tx_data;
wire [7:0]  app_tx_data_keep;
wire        app_tx_data_last;
wire [15:0] app_tx_data_length;

// master_wrapper_v8 now routes the adapter's tx_ready from mac_proto's
// app_tx_ready instead of tying it high, so the chain mirrors that.

assign app_rx_data_valid  = app_rx_data_valid_w;
assign app_rx_data_last   = app_rx_data_last_w;
assign app_rx_data_length = app_rx_data_length_w;

rle4k_mac_proto_v8 #(
    .LOCAL_MAC (LOCAL_MAC)
) u_mac_proto (
    .clk               (clk_15_625),
    .rst               (core_reset),

    .mac_rx_data_valid (mac_rx_data_valid),
    .mac_rx_data       (mac_rx_data),
    .mac_rx_keep       (mac_rx_keep),
    .mac_rx_last       (mac_rx_last),
    .mac_rx_ready      (mac_rx_ready),

    .mac_tx_data_valid (mac_tx_data_valid),
    .mac_tx_data       (mac_tx_data),
    .mac_tx_keep       (mac_tx_keep),
    .mac_tx_ready      (mac_tx_ready),
    .mac_tx_last       (mac_tx_last),
    .mac_tx_user       (),

    .app_rx_data_valid (app_rx_data_valid_w),
    .app_rx_data       (app_rx_data),
    .app_rx_data_keep  (app_rx_data_keep),
    .app_rx_data_last  (app_rx_data_last_w),
    .app_rx_data_length(app_rx_data_length_w),
    .app_rx_ready      (app_rx_ready_w),

    .app_tx_ready      (app_tx_ready_w),
    .app_tx_ack        (app_tx_ack),
    .app_tx_request    (app_tx_request),
    .app_tx_data_valid (app_tx_data_valid),
    .app_tx_data       (app_tx_data),
    .app_tx_data_keep  (app_tx_data_keep),
    .app_tx_data_last  (app_tx_data_last),
    .app_tx_data_length(app_tx_data_length)
);

// ============================================================================
// Stream Adapter v8 (15.625 MHz domain)  -- rle4k_lan_top_v8.v lines 108..185
// ============================================================================
wire [31:0] dec_data_mac;
wire        dec_valid_mac;
wire        dec_stream_end_mac;

wire [31:0] cfg_block_index;
wire [31:0] cfg_line_width;
wire [31:0] cfg_line_stride;
wire [31:0] cfg_block_height;
wire [31:0] cfg_strip_line_count_mac;
wire [31:0] cfg_rle_payload_bytes_mac;
wire        strip_cfg_toggle_mac;

wire [223:0] dbg_cnt_bus;
wire [63:0]  dbg_state_bus;

assign dec_valid = dec_valid_mac;

// dbg_cnt_bus = {wdt, reset, err, stream_end, stream_data, stream_start, rx_datagrams}
assign mon_rx_datagrams = dbg_cnt_bus[31:0];
assign mon_stream_start = dbg_cnt_bus[63:32];
assign mon_stream_data  = dbg_cnt_bus[95:64];
assign mon_stream_end   = dbg_cnt_bus[127:96];
assign mon_err_rsp      = dbg_cnt_bus[159:128];

// dbg_state_bus concat is 70 bits truncated into 64: the top 6 bits of
// stream_rx_bytes are dropped by the adapter, so only [25:0] survive.
assign adapter_state   = dbg_state_bus[5:0];
assign stream_rx_bytes = {6'd0, dbg_state_bus[63:38]};

// Declared here (top-level file relies on implicit nets); see the 125 -> 15.625
// status CDC block near the end of this file for the driving logic.
reg [31:0] crc32_lat_s1, crc32_lat_s2;
reg [31:0] crc32_wcnt_s1, crc32_wcnt_s2;
reg        crc32_done_s1, crc32_done_s2;
reg [31:0] dc_w0_s1, dc_w0_s2;
reg [31:0] dc_w1_s1, dc_w1_s2;
reg [31:0] dc_w9_s1, dc_w9_s2;
reg [31:0] dc_w127_s1, dc_w127_s2;
reg [31:0] dc_w128_s1, dc_w128_s2;

reg [31:0] decode_status_sync1, decode_status_sync2;
reg        block_done_sync1, block_done_sync2;

always @(posedge clk_15_625) begin
    decode_status_sync1 <= decode_status_raw;
    decode_status_sync2 <= decode_status_sync1;
    block_done_sync1    <= block_done_raw;
    block_done_sync2    <= block_done_sync1;
end

reg [31:0] diag_crc_tail128;
reg [31:0] diag_crc_tail256;

rle4k_stream_adapter_v8 #(
    .P_WDT_TIMEOUT_TICKS(P_WDT_TIMEOUT_TICKS),
    .P_NUM_LANES(1)
) u_adapter (
    .clk           (clk_15_625),
    .rst_n         (~core_reset),

    .rx_valid      (app_rx_data_valid_w),
    .rx_data       (app_rx_data),
    .rx_keep       (app_rx_data_keep),
    .rx_last       (app_rx_data_last_w),
    .rx_length     (app_rx_data_length_w),
    .rx_ready      (app_rx_ready_w),
    .rx_congested  (),

    .tx_request    (app_tx_request),
    .tx_ack        (app_tx_ack),
    .tx_ready      (app_tx_ready_w),
    .tx_valid      (app_tx_data_valid),
    .tx_data       (app_tx_data),
    .tx_keep       (app_tx_data_keep),
    .tx_last       (app_tx_data_last),
    .tx_length     (app_tx_data_length),

    .dec_data      (dec_data_mac),
    .dec_valid     (dec_valid_mac),
    .dec_stream_end(dec_stream_end_mac),
    .active_lane   (),
    .parallel_mode (),

    .cfg_block_index (cfg_block_index),
    .cfg_line_width  (cfg_line_width),
    .cfg_line_stride (cfg_line_stride),
    .cfg_block_height(cfg_block_height),
    .cfg_strip_line_count(cfg_strip_line_count_mac),
    .cfg_rle_payload_bytes(cfg_rle_payload_bytes_mac),
    .strip_cfg_toggle(strip_cfg_toggle_mac),
    .cfg_block_index_bus(),
    .cfg_block_height_bus(),
    .cfg_strip_line_count_bus(),
    .cfg_rle_payload_bytes_bus(),
    .lane_cfg_toggle_bus(),

    .decode_status (decode_status_sync2),
    .block_done    (block_done_sync2),
    .block_done_bus(block_done_sync2),
    .cdc_full      (cdc_almost_full),
    .soft_rst      (soft_rst),

    .decode_crc32       (crc32_lat_s2),
    .decode_crc32_wcnt  (crc32_wcnt_s2),
    .decode_crc32_done  (crc32_done_s2),

    .diag_crc_0         (dc_w0_s2),
    .diag_crc_1         (dc_w1_s2),
    .diag_crc_2         (dc_w9_s2),
    .diag_crc_3         (dc_w127_s2),
    .diag_crc_4         (dc_w128_s2),
    .diag_crc_5         (diag_crc_tail128),
    .diag_crc_6         (diag_crc_tail256),

    .ring_accept_valid(),
    .ring_accept_block_index(),
    .ring_accept_ready(1'b1),
    .ring_retx_pending(1'b0),
    .ring_retx_count(32'd0),
    .ring_complete_bitmap(32'd0),
    .ring_window_base(32'd0),
    .ring_last_byte_addr(32'h20000000),
    .ring_blocks_completed(32'd0),
    .last_block_index(32'd0),
    .last_block_crc32(crc32_lat_s2),
    .last_block_words(crc32_wcnt_s2),
    .last_block_lane(8'd0),
    .last_block_valid(crc32_done_s2),

    .dbg_cnt_bus   (dbg_cnt_bus),
    .dbg_state_bus (dbg_state_bus)
);

// ============================================================================
// CDC FIFO: 15.625 MHz -> 125 MHz  -- top lines 187..212
// ============================================================================
wire [35:0] cdc_din = {4'b0, dec_data_mac};
wire        cdc_wr_en = dec_valid_mac & ~cdc_full;

wire [35:0] cdc_dout;
wire        cdc_empty;
wire        cdc_rd_en;
wire        cdc_valid;

rle4k_cdc_fifo_36 u_cdc_fifo (
    .rst    (core_reset | soft_rst),
    .wr_clk (clk_15_625),
    .rd_clk (clk_125),
    .din    (cdc_din),
    .wr_en  (cdc_wr_en),
    .rd_en  (cdc_rd_en),
    .dout        (cdc_dout),
    .full        (cdc_full),
    .almost_full (cdc_almost_full),
    .empty       (cdc_empty),
    .valid       (cdc_valid)
);

wire [31:0] cdc_data = cdc_dout[31:0];

// ============================================================================
// Decoder Core (125 MHz domain)  -- top lines 214..376
// ============================================================================
wire        sys_rst_n = locked & ~soft_rst;
wire        decoder_fifo_ready;
wire [511:0] decoded_data_out;
wire [31:0]  block_index_out;

reg [31:0] cfg_bi_s1, cfg_bi_s2;
reg [31:0] cfg_lw_s1, cfg_lw_s2;
reg [31:0] cfg_ls_s1, cfg_ls_s2;
reg [31:0] cfg_bh_s1, cfg_bh_s2;
reg [31:0] cfg_rpb_s1, cfg_rpb_s2;
reg [31:0] cfg_sc_s1, cfg_sc_s2;

always @(posedge clk_125) begin
    cfg_bi_s1 <= cfg_block_index;  cfg_bi_s2 <= cfg_bi_s1;
    cfg_lw_s1 <= cfg_line_width;   cfg_lw_s2 <= cfg_lw_s1;
    cfg_ls_s1 <= cfg_line_stride;  cfg_ls_s2 <= cfg_ls_s1;
    cfg_bh_s1 <= cfg_block_height; cfg_bh_s2 <= cfg_bh_s1;
    cfg_rpb_s1 <= cfg_rle_payload_bytes_mac;
    cfg_rpb_s2 <= cfg_rpb_s1;
    cfg_sc_s1  <= cfg_strip_line_count_mac;
    cfg_sc_s2  <= cfg_sc_s1;
end

reg strip_t_s1, strip_t_s2, strip_t_dly;
always @(posedge clk_125 or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        strip_t_s1  <= 1'b0;
        strip_t_s2  <= 1'b0;
        strip_t_dly <= 1'b0;
    end else begin
        strip_t_s1  <= strip_cfg_toggle_mac;
        strip_t_s2  <= strip_t_s1;
        strip_t_dly <= strip_t_s2;
    end
end
wire strip_byte_cnt_rst_pulse = strip_t_s2 ^ strip_t_dly;

// Proposed fix (BLOCK_START_MODE=1): one-cycle-delayed copy of the strip pulse.
// The delay matters: in rle4k_decoder_core.v line 595 the strip_byte_cnt_rst
// branch has priority over the block_start branch, so a block_start coincident
// with strip_byte_cnt_rst would still skip parameter validation.
reg strip_rst_d1;
always @(posedge clk_125 or negedge sys_rst_n) begin
    if (!sys_rst_n) strip_rst_d1 <= 1'b0;
    else            strip_rst_d1 <= strip_byte_cnt_rst_pulse;
end
wire block_start_w = (BLOCK_START_MODE != 0) ? strip_rst_d1 : 1'b0;

reg stream_end_s1, stream_end_s2, stream_end_s3;
always @(posedge clk_125 or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        stream_end_s1 <= 1'b0;
        stream_end_s2 <= 1'b0;
        stream_end_s3 <= 1'b0;
    end else begin
        stream_end_s1 <= dec_stream_end_mac;
        stream_end_s2 <= stream_end_s1;
        stream_end_s3 <= stream_end_s2;
    end
end
wire stream_end_pulse = stream_end_s2 & ~stream_end_s3;

reg decoder_ready_r;
always @(posedge clk_125) begin
    if (!sys_rst_n)
        decoder_ready_r <= 1'b1;
    else
        decoder_ready_r <= decoder_fifo_ready;
end

reg [31:0] skid_data;
reg        skid_valid;

assign cdc_rd_en = ~cdc_empty & decoder_ready_r & ~skid_valid;

wire cdc_read_occurred = cdc_rd_en;
wire decoder_rejected  = cdc_read_occurred & ~decoder_fifo_ready;

always @(posedge clk_125) begin
    if (!sys_rst_n) begin
        skid_valid <= 1'b0;
        skid_data  <= 32'd0;
    end else begin
        if (decoder_rejected) begin
            skid_data  <= cdc_data;
            skid_valid <= 1'b1;
        end else if (skid_valid && decoder_fifo_ready) begin
            skid_valid <= 1'b0;
        end
    end
end

wire [31:0] dec_input_data  = skid_valid ? skid_data : cdc_data;
wire        dec_input_valid = skid_valid ? decoder_fifo_ready
                                         : (cdc_rd_en & decoder_fifo_ready);

rle4k_decoder_core u_decoder (
    .clk               (clk_125),
    .rst_n             (sys_rst_n),

    .encoded_data_in   (dec_input_data),
    .encoded_data_valid(dec_input_valid),
    .block_start       (block_start_w),
    .stream_end        (stream_end_pulse),
    .decoder_fifo_ready(decoder_fifo_ready),

    .decoded_data_out  (decoded_data_out),
    .word_decoded_valid(word_decoded_valid),
    .word_decoded_ready(1'b1),

    .cfg_block_index   (cfg_bi_s2),
    .cfg_line_width    (cfg_lw_s2),
    .cfg_line_stride   (cfg_ls_s2),
    .cfg_block_height  (cfg_bh_s2),
    .cfg_strip_line_count(cfg_sc_s2),
    .cfg_rle_payload_bytes(cfg_rpb_s2),
    .strip_byte_cnt_rst(strip_byte_cnt_rst_pulse),
    .upstream_busy     (~cdc_empty | cdc_valid | skid_valid),

    .decode_status     (decode_status_raw),
    .block_done        (block_done_raw),
    .strip_end_out     (strip_end_raw),
    .block_index_out   (block_index_out)
);

// ============================================================================
// CRC32 on decoded output (125 MHz domain)  -- top lines 378..460
// ============================================================================
function [31:0] crc32_byte;
    input [31:0] prev;
    input [7:0]  b;
    reg [31:0] c;
    integer i;
    begin
        c = prev ^ {24'd0, b};
        for (i = 0; i < 8; i = i + 1)
            c = c[0] ? ({1'b0, c[31:1]} ^ 32'hEDB88320) : {1'b0, c[31:1]};
        crc32_byte = c;
    end
endfunction

reg [31:0] crc32_accum;
reg [31:0] crc32_latched;
reg [31:0] crc32_word_count;
reg        crc32_done;

reg [31:0] crc32_next;
integer crc_j;
always @(*) begin
    crc32_next = crc32_accum;
    for (crc_j = 0; crc_j < 64; crc_j = crc_j + 1)
        crc32_next = crc32_byte(crc32_next, decoded_data_out[crc_j*8 +: 8]);
end

reg [31:0] crc32_word_count_latched;
reg        strip_end_prev;

reg [31:0] diag_crc_w0;
reg [31:0] diag_crc_w1;
reg [31:0] diag_crc_w9;
reg [31:0] diag_crc_w127;
reg [31:0] diag_crc_w128;
// Same tail-relative checkpoints as rle4k_lan_top_v8.v, so the simulation gate covers
// the part of the strip the five absolute checkpoints are blind to.
reg [31:0] crc_hist [0:511];
reg [8:0]  tail_rd_addr_a, tail_rd_addr_b;
reg        tail_rd_pend;

always @(posedge clk_125) begin
    if (!sys_rst_n) begin
        crc32_accum              <= 32'hFFFFFFFF;
        crc32_latched            <= 32'd0;
        crc32_word_count         <= 32'd0;
        crc32_word_count_latched <= 32'd0;
        crc32_done               <= 1'b0;
        strip_end_prev           <= 1'b0;
        diag_crc_w0              <= 32'd0;
        diag_crc_w1              <= 32'd0;
        diag_crc_w9              <= 32'd0;
        diag_crc_w127            <= 32'd0;
        diag_crc_w128            <= 32'd0;
    end else begin
        strip_end_prev <= strip_end_raw;

        if (word_decoded_valid) begin
            crc32_accum      <= crc32_next;
            crc32_word_count <= crc32_word_count + 32'd1;

            if (crc32_word_count == 32'd0)     diag_crc_w0   <= crc32_next;
            if (crc32_word_count == 32'd128)   diag_crc_w1   <= crc32_next;
            if (crc32_word_count == 32'd255)   diag_crc_w9   <= crc32_next;
            if (crc32_word_count == 32'd256)   diag_crc_w127 <= crc32_next;
            if (crc32_word_count == 32'd32768) diag_crc_w128 <= crc32_next;
        end

        if (strip_end_raw && !strip_end_prev) begin
            crc32_latched <= crc32_accum ^ 32'hFFFFFFFF;
            crc32_word_count_latched <= crc32_word_count;
            crc32_done    <= 1'b1;
        end
    end
end

// CDC: 125 MHz -> 15.625 MHz  -- top lines 462..480 (regs declared at the top)
always @(posedge clk_15_625) begin
    crc32_lat_s1  <= crc32_latched;   crc32_lat_s2  <= crc32_lat_s1;
    crc32_wcnt_s1 <= crc32_word_count_latched; crc32_wcnt_s2 <= crc32_wcnt_s1;
    crc32_done_s1 <= crc32_done;      crc32_done_s2 <= crc32_done_s1;
    dc_w0_s1   <= diag_crc_w0;   dc_w0_s2   <= dc_w0_s1;
    dc_w1_s1   <= diag_crc_w1;   dc_w1_s2   <= dc_w1_s1;
    dc_w9_s1   <= diag_crc_w9;   dc_w9_s2   <= dc_w9_s1;
    dc_w127_s1 <= diag_crc_w127; dc_w127_s2 <= dc_w127_s1;
    dc_w128_s1 <= diag_crc_w128; dc_w128_s2 <= dc_w128_s1;
end

assign crc32_accum_o              = crc32_accum;
assign crc32_latched_o            = crc32_latched;
assign crc32_word_count_o         = crc32_word_count;
assign crc32_word_count_latched_o = crc32_word_count_latched;
assign crc32_done_o               = crc32_done;

endmodule
