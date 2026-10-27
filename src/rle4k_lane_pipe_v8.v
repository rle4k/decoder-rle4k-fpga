// ============================================================================
// rle4k_lane_pipe_v8 — one parallel decode module (lane)
// ============================================================================
// CDC FIFO (15.625→125) + skid + rle4k_decoder_core + per-block CRC32 (post-XOR).
// Output words are discarded; CRC / word_count / block_done are the product path.
// ============================================================================

`timescale 1ns / 1ps

module rle4k_lane_pipe_v8 (
    input  wire        clk_mac,       // 15.625 MHz
    input  wire        clk_dec,       // 125 MHz
    input  wire        rst,           // async-ish: core_reset | soft_rst
    input  wire        sys_rst_n,     // locked & ~soft_rst (125 MHz)

    // Compressed feed (MAC domain)
    input  wire [31:0] dec_data,
    input  wire        dec_valid,
    output wire        cdc_full,
    output wire        cdc_almost_full,
    // Early 802.3x PAUSE (staging watermark; fires before hard almost_full)
    output wire        stg_pause_req,

    // Stream end pulse (MAC domain, 1 cycle @ 15.625) — CDC inside
    input  wire        dec_stream_end,

    // Config (MAC domain; 2FF sync inside)
    input  wire [31:0] cfg_block_index,
    input  wire [31:0] cfg_line_width,
    input  wire [31:0] cfg_line_stride,
    input  wire [31:0] cfg_block_height,
    input  wire [31:0] cfg_strip_line_count,
    input  wire [31:0] cfg_rle_payload_bytes,
    input  wire        strip_cfg_toggle,   // edge resets byte counter

    // Status (125 MHz)
    output wire [31:0] decode_status,
    output wire        block_done,
    output wire        strip_end,
    output wire [31:0] block_index_out,

    // Per-block CRC (post-XOR), latched on block_done rising edge
    output reg  [31:0] block_crc32,
    output reg  [31:0] block_word_count,
    output reg         block_crc_valid,    // 1-cycle pulse with latch
    output reg  [31:0] block_crc_index     // block_index at latch time
);

wire        cdc_full_raw;
wire        cdc_almost_full_raw;
wire [35:0] cdc_dout;
wire        cdc_empty;
wire        cdc_valid;
wire        cdc_rd_en;

// -------------------------------------------------------------------------
// Per-lane MAC staging FIFO (ahead of async CDC)
// -------------------------------------------------------------------------
// Adapter STREAM_FEED used to push straight into a shallow CDC (512). When the
// 125 MHz decoder drained slowly, almost_full stalled the *shared* adapter FSM
// for the whole block — so BLOCK_START for the next lane could not run and
// lane_busy overlap stayed ~15%. Staging (~8 KiB) absorbs the dump at MAC rate;
// drain to CDC continues while the adapter assigns/feeds other lanes.
wire        stg_full;
wire        stg_almost_full;
wire        stg_pause_level;
wire        stg_empty;
wire [35:0] stg_dout;
wire        stg_rd_valid;
reg         stg_hold_valid;
reg  [35:0] stg_hold_data;

wire stg_wr = dec_valid & ~stg_full;
// Prefetch when hold empty, or when hold will be consumed this cycle by CDC.
wire stg_rd = !stg_empty & (~stg_hold_valid | (stg_hold_valid & ~cdc_full_raw));

rle4k_sync_fifo_36 #(
    .P_ADDR_BITS(12),       // 4096 × 36b ≈ 16 KiB / lane
    // PAUSE when <8 KiB free (50%). Safe host batch ≲ headroom so one
    // pcap_sendqueue_transmit after PAUSE still fits without RX drop.
    .P_PAUSE_HEADROOM(2048)
) u_stage (
    .clk         (clk_mac),
    .rst         (rst),
    .din         ({4'b0, dec_data}),
    .wr_en       (stg_wr),
    .full        (stg_full),
    .almost_full (stg_almost_full),
    .pause_level (stg_pause_level),
    .rd_en       (stg_rd),
    .dout        (stg_dout),
    .empty       (stg_empty),
    .valid       (stg_rd_valid)
);

assign stg_pause_req = stg_pause_level;

// Skid: registered FIFO read → CDC write when CDC has room (1 word/clk sustained)
always @(posedge clk_mac) begin
    if (rst) begin
        stg_hold_valid <= 1'b0;
        stg_hold_data  <= 36'd0;
    end else if (stg_hold_valid && !cdc_full_raw) begin
        if (stg_rd_valid) begin
            stg_hold_data  <= stg_dout;
            stg_hold_valid <= 1'b1;
        end else begin
            stg_hold_valid <= 1'b0;
        end
    end else if (stg_rd_valid) begin
        stg_hold_data  <= stg_dout;
        stg_hold_valid <= 1'b1;
    end
end

wire        cdc_wr_en = stg_hold_valid & ~cdc_full_raw;
wire [35:0] cdc_din   = stg_hold_data;

// Back-pressure to adapter: staging almost full (CDC drain is local per lane)
assign cdc_almost_full = stg_almost_full | cdc_almost_full_raw;
assign cdc_full        = stg_full;

rle4k_cdc_fifo_36 u_cdc (
    .rst         (rst),
    .wr_clk      (clk_mac),
    .rd_clk      (clk_dec),
    .din         (cdc_din),
    .wr_en       (cdc_wr_en),
    .rd_en       (cdc_rd_en),
    .dout        (cdc_dout),
    .full        (cdc_full_raw),
    .almost_full (cdc_almost_full_raw),
    .empty       (cdc_empty),
    .valid       (cdc_valid)
);

wire [31:0] cdc_data = cdc_dout[31:0];

reg [31:0] cfg_bi_s1, cfg_bi_s2;
reg [31:0] cfg_lw_s1, cfg_lw_s2;
reg [31:0] cfg_ls_s1, cfg_ls_s2;
reg [31:0] cfg_bh_s1, cfg_bh_s2;
reg [31:0] cfg_rpb_s1, cfg_rpb_s2;
reg [31:0] cfg_sc_s1, cfg_sc_s2;

always @(posedge clk_dec) begin
    cfg_bi_s1  <= cfg_block_index;       cfg_bi_s2  <= cfg_bi_s1;
    cfg_lw_s1  <= cfg_line_width;        cfg_lw_s2  <= cfg_lw_s1;
    cfg_ls_s1  <= cfg_line_stride;       cfg_ls_s2  <= cfg_ls_s1;
    cfg_bh_s1  <= cfg_block_height;      cfg_bh_s2  <= cfg_bh_s1;
    cfg_rpb_s1 <= cfg_rle_payload_bytes; cfg_rpb_s2 <= cfg_rpb_s1;
    cfg_sc_s1  <= cfg_strip_line_count;  cfg_sc_s2  <= cfg_sc_s1;
end

reg strip_t_s1, strip_t_s2, strip_t_dly;
always @(posedge clk_dec or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        strip_t_s1  <= 1'b0;
        strip_t_s2  <= 1'b0;
        strip_t_dly <= 1'b0;
    end else begin
        strip_t_s1  <= strip_cfg_toggle;
        strip_t_s2  <= strip_t_s1;
        strip_t_dly <= strip_t_s2;
    end
end
wire strip_byte_cnt_rst_pulse = strip_t_s2 ^ strip_t_dly;

reg stream_end_s1, stream_end_s2, stream_end_s3;
always @(posedge clk_dec or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        stream_end_s1 <= 1'b0;
        stream_end_s2 <= 1'b0;
        stream_end_s3 <= 1'b0;
    end else begin
        stream_end_s1 <= dec_stream_end;
        stream_end_s2 <= stream_end_s1;
        stream_end_s3 <= stream_end_s2;
    end
end
wire stream_end_pulse = stream_end_s2 & ~stream_end_s3;

wire        decoder_fifo_ready;
wire [511:0] decoded_data_out;
wire         word_decoded_valid;

reg decoder_ready_r;
always @(posedge clk_dec) begin
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

always @(posedge clk_dec) begin
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
    .clk               (clk_dec),
    .rst_n             (sys_rst_n),
    .encoded_data_in   (dec_input_data),
    .encoded_data_valid(dec_input_valid),
    .block_start       (1'b0),
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
    .decode_status     (decode_status),
    .block_done        (block_done),
    .strip_end_out     (strip_end),
    .block_index_out   (block_index_out),
    .dbg_core          ()
);

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
reg [31:0] crc32_word_count;
reg        block_done_prev;

reg [31:0] crc32_next;
integer crc_j;
always @(*) begin
    crc32_next = crc32_accum;
    for (crc_j = 0; crc_j < 64; crc_j = crc_j + 1)
        crc32_next = crc32_byte(crc32_next, decoded_data_out[crc_j*8 +: 8]);
end

always @(posedge clk_dec) begin
    if (!sys_rst_n) begin
        crc32_accum       <= 32'hFFFFFFFF;
        crc32_word_count  <= 32'd0;
        block_done_prev   <= 1'b0;
        block_crc32       <= 32'd0;
        block_word_count  <= 32'd0;
        block_crc_valid   <= 1'b0;
        block_crc_index   <= 32'd0;
    end else begin
        block_done_prev <= block_done;
        block_crc_valid <= 1'b0;

        // New block starts when cfg index changes after a done, or strip cfg toggle
        if (strip_byte_cnt_rst_pulse) begin
            crc32_accum      <= 32'hFFFFFFFF;
            crc32_word_count <= 32'd0;
        end

        if (word_decoded_valid) begin
            crc32_accum      <= crc32_next;
            crc32_word_count <= crc32_word_count + 32'd1;
        end

        if (block_done && !block_done_prev) begin
            block_crc32      <= crc32_accum ^ 32'hFFFFFFFF;
            block_word_count <= crc32_word_count;
            block_crc_index  <= cfg_bi_s2;
            block_crc_valid  <= 1'b1;
            // Prepare for next block on this lane
            crc32_accum      <= 32'hFFFFFFFF;
            crc32_word_count <= 32'd0;
        end
    end
end

endmodule
