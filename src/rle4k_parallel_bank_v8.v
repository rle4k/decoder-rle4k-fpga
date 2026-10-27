// ============================================================================
// rle4k_parallel_bank_v8 — K=4 decode modules + ring window + CRC bank
// ============================================================================
// Instantiates P_NUM_LANES × rle4k_lane_pipe_v8. Adapter drives one active lane
// at a time for STREAM_DATA (lane_sel), with per-lane CDC almost_full for
// backpressure. Per-block CRC results land in a small BRAM addressed by
// block_index[11:0] (up to 4096 blocks).
// ============================================================================

`timescale 1ns / 1ps

module rle4k_parallel_bank_v8 #(
    parameter integer P_NUM_LANES = 4,
    parameter integer P_W         = 32,
    parameter [31:0]  P_BASE      = 32'h2000_0000,
    parameter [31:0]  P_BLOCK_BYTES = 32'd4194304
) (
    input  wire        clk_mac,
    input  wire        clk_dec,
    input  wire        rst,          // core_reset | soft_rst
    input  wire        sys_rst_n,
    input  wire        strip_clear,  // MAC domain: STREAM_START / RESET

    // Per-lane compressed feed (MAC)
    input  wire [32*P_NUM_LANES-1:0] dec_data_bus,
    input  wire [P_NUM_LANES-1:0]    dec_valid_bus,
    output wire [P_NUM_LANES-1:0]    cdc_almost_full_bus,
    output wire [P_NUM_LANES-1:0]    cdc_full_bus,
    output wire [P_NUM_LANES-1:0]    stg_pause_bus,
    input  wire [P_NUM_LANES-1:0]    dec_stream_end_bus,

    // Shared geometry from STREAM_START (MAC); per-block overrides via *_lane
    input  wire [31:0] cfg_line_width,
    input  wire [31:0] cfg_line_stride,

    // Per-lane block config (MAC)
    input  wire [32*P_NUM_LANES-1:0] cfg_block_index_bus,
    input  wire [32*P_NUM_LANES-1:0] cfg_block_height_bus,
    input  wire [32*P_NUM_LANES-1:0] cfg_strip_line_count_bus,
    input  wire [32*P_NUM_LANES-1:0] cfg_rle_payload_bytes_bus,
    input  wire [P_NUM_LANES-1:0]    lane_cfg_toggle_bus,

    // Status to adapter (MAC-synced externally or use raw 125 and 2FF in top)
    output wire [32*P_NUM_LANES-1:0] decode_status_bus,
    output wire [P_NUM_LANES-1:0]    block_done_bus,

    // Ring window (MAC domain control; clocked on clk_dec for complete, clk_mac for accept —
    // both driven here on clk_dec; adapter should pulse accept_* after CDC or share clk_mac
    // with a dual-clock-safe handshake. Phase A: run window on clk_mac; complete pulses
    // are synced up from 125.)
    input  wire        accept_valid,
    input  wire [31:0] accept_block_index,
    output wire        accept_ready,
    output wire        retx_pending,
    output wire [31:0] retx_count,
    output wire [31:0] complete_bitmap,
    output wire [31:0] window_base_index,
    output wire [31:0] last_byte_addr,
    output wire [31:0] blocks_completed_win,
    output wire [31:0] ring_slot,
    output wire [31:0] ring_byte_addr,

    // CRC bank read (MAC domain query — 1-cycle latency after crc_rd_en)
    input  wire        crc_rd_en,
    input  wire [11:0] crc_rd_index,
    output reg  [31:0] crc_rd_crc32,
    output reg  [31:0] crc_rd_words,
    output reg         crc_rd_done,
    output reg  [7:0]  crc_rd_lane,

    // Last completed block (for quick GET)
    output reg  [31:0] last_block_index,
    output reg  [31:0] last_block_crc32,
    output reg  [31:0] last_block_words,
    output reg  [7:0]  last_block_lane,
    output reg         last_block_valid
);

wire [P_NUM_LANES-1:0] block_crc_valid;
wire [32*P_NUM_LANES-1:0] block_crc32_bus;
wire [32*P_NUM_LANES-1:0] block_word_count_bus;
wire [32*P_NUM_LANES-1:0] block_crc_index_bus;

genvar gi;
generate
for (gi = 0; gi < P_NUM_LANES; gi = gi + 1) begin : lanes
    rle4k_lane_pipe_v8 u_lane (
        .clk_mac              (clk_mac),
        .clk_dec              (clk_dec),
        .rst                  (rst),
        .sys_rst_n            (sys_rst_n),
        .dec_data             (dec_data_bus[32*gi +: 32]),
        .dec_valid            (dec_valid_bus[gi]),
        .cdc_full             (cdc_full_bus[gi]),
        .cdc_almost_full      (cdc_almost_full_bus[gi]),
        .stg_pause_req        (stg_pause_bus[gi]),
        .dec_stream_end       (dec_stream_end_bus[gi]),
        .cfg_block_index      (cfg_block_index_bus[32*gi +: 32]),
        .cfg_line_width       (cfg_line_width),
        .cfg_line_stride      (cfg_line_stride),
        .cfg_block_height     (cfg_block_height_bus[32*gi +: 32]),
        .cfg_strip_line_count (cfg_strip_line_count_bus[32*gi +: 32]),
        .cfg_rle_payload_bytes(cfg_rle_payload_bytes_bus[32*gi +: 32]),
        .strip_cfg_toggle     (lane_cfg_toggle_bus[gi]),
        .decode_status        (decode_status_bus[32*gi +: 32]),
        .block_done           (block_done_bus[gi]),
        .strip_end            (),
        .block_index_out      (),
        .block_crc32          (block_crc32_bus[32*gi +: 32]),
        .block_word_count     (block_word_count_bus[32*gi +: 32]),
        .block_crc_valid      (block_crc_valid[gi]),
        .block_crc_index      (block_crc_index_bus[32*gi +: 32])
    );
end
endgenerate

// ---- Complete events: clk_dec → async FIFO → CRC slots on clk_mac ----
// Phase A: do NOT use a 4096-deep dual-clock multi-write BRAM — Vivado cannot
// infer it (Synth 8-3391). Store CRC by ring slot on the MAC domain after CDC.
//
// CRITICAL: clk_dec=125 MHz, clk_mac=15.625 MHz. A 1-cycle pulse at 125 sampled
// with 2FF into 15.625 is almost always lost — slots stay empty (done=0) while
// sticky last_block_* (held in clk_dec, multi-cycle synced in top) still works.
// That is why depth=1 (last_block harvest) passed and indexed GET never did.
// Completions cross domains only via this gray-code async FIFO (same rule as
// rle4k_cdc_fifo_36 / docs CDC red line).
integer li;

reg strip_c_s1, strip_c_s2, strip_c_s3;
always @(posedge clk_dec or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        strip_c_s1 <= 1'b0; strip_c_s2 <= 1'b0; strip_c_s3 <= 1'b0;
    end else begin
        strip_c_s1 <= strip_clear;
        strip_c_s2 <= strip_c_s1;
        strip_c_s3 <= strip_c_s2;
    end
end
wire strip_clear_pulse = strip_c_s2 & ~strip_c_s3;

// Sticky per-lane pending: absorb same-cycle multi-lane block_crc_valid pulses.
reg [P_NUM_LANES-1:0] pend_v;
reg [31:0] pend_idx  [0:P_NUM_LANES-1];
reg [31:0] pend_crc  [0:P_NUM_LANES-1];
reg [31:0] pend_wcnt [0:P_NUM_LANES-1];

localparam integer C_AW = 3;                 // depth 8
localparam integer C_DEPTH = (1 << C_AW);
localparam integer C_W = 104;                // {lane[7:0], words, crc, idx}
(* ram_style = "distributed" *) reg [C_W-1:0] c_mem [0:C_DEPTH-1];
reg [C_AW:0] c_wr_bin, c_wr_gray;
reg [C_AW:0] c_rd_bin, c_rd_gray;
reg [C_AW:0] c_rd_gray_w1, c_rd_gray_w2;
reg [C_AW:0] c_wr_gray_r1, c_wr_gray_r2;

function [C_AW:0] c_bin2gray;
    input [C_AW:0] b;
    c_bin2gray = b ^ (b >> 1);
endfunction

wire [C_AW:0] c_rd_gray_w2_inv = {~c_rd_gray_w2[C_AW:C_AW-1], c_rd_gray_w2[C_AW-2:0]};
wire c_full  = (c_wr_gray == c_rd_gray_w2_inv);
wire c_empty = (c_rd_gray == c_wr_gray_r2);

// Capture lane pulses + push one pending/cycle into CDC FIFO (lowest lane first).
reg        fire_dec;
reg [31:0] fire_idx_dec;
reg [31:0] fire_crc_dec;
reg [31:0] fire_wcnt_dec;
reg [7:0]  fire_lane_dec;
reg        fire_take; // combinatorial: will push this cycle
integer    pk;
always @(*) begin
    fire_dec      = 1'b0;
    fire_idx_dec  = 32'd0;
    fire_crc_dec  = 32'd0;
    fire_wcnt_dec = 32'd0;
    fire_lane_dec = 8'd0;
    fire_take     = 1'b0;
    for (pk = 0; pk < P_NUM_LANES; pk = pk + 1) begin
        if (!fire_take && pend_v[pk]) begin
            fire_take     = 1'b1;
            fire_dec      = ~c_full;
            fire_idx_dec  = pend_idx[pk];
            fire_crc_dec  = pend_crc[pk];
            fire_wcnt_dec = pend_wcnt[pk];
            fire_lane_dec = pk[7:0];
        end
    end
end

always @(posedge clk_dec) begin
    if (!sys_rst_n || strip_clear_pulse) begin
        pend_v           <= {P_NUM_LANES{1'b0}};
        c_wr_bin         <= {(C_AW+1){1'b0}};
        c_wr_gray        <= {(C_AW+1){1'b0}};
        c_rd_gray_w1     <= {(C_AW+1){1'b0}};
        c_rd_gray_w2     <= {(C_AW+1){1'b0}};
        last_block_valid <= 1'b0;
        last_block_index <= 32'd0;
        last_block_crc32 <= 32'd0;
        last_block_words <= 32'd0;
        last_block_lane  <= 8'd0;
        for (li = 0; li < P_NUM_LANES; li = li + 1) begin
            pend_idx[li]  <= 32'd0;
            pend_crc[li]  <= 32'd0;
            pend_wcnt[li] <= 32'd0;
        end
    end else begin
        c_rd_gray_w1 <= c_rd_gray;
        c_rd_gray_w2 <= c_rd_gray_w1;

        for (li = 0; li < P_NUM_LANES; li = li + 1) begin
            if (block_crc_valid[li]) begin
                pend_v[li]    <= 1'b1;
                pend_idx[li]  <= block_crc_index_bus[32*li +: 32];
                pend_crc[li]  <= block_crc32_bus[32*li +: 32];
                pend_wcnt[li] <= block_word_count_bus[32*li +: 32];
            end else if (fire_dec && (fire_lane_dec == li[7:0])) begin
                pend_v[li] <= 1'b0;
            end
        end

        if (fire_dec) begin
            c_mem[c_wr_bin[C_AW-1:0]] <= {fire_lane_dec, fire_wcnt_dec,
                                          fire_crc_dec, fire_idx_dec};
            c_wr_bin  <= c_wr_bin + 1'b1;
            c_wr_gray <= c_bin2gray(c_wr_bin + 1'b1);
            last_block_index <= fire_idx_dec;
            last_block_crc32 <= fire_crc_dec;
            last_block_words <= fire_wcnt_dec;
            last_block_lane  <= fire_lane_dec;
            last_block_valid <= 1'b1;
        end
    end
end

// MAC domain: pop FIFO → write CRC slot file + ring complete.
// c_rd_bin/c_rd_gray live here; clk_dec samples c_rd_gray via 2FF for full flag.
always @(posedge clk_mac) begin
    if (rst || strip_clear) begin
        c_rd_bin     <= {(C_AW+1){1'b0}};
        c_rd_gray    <= {(C_AW+1){1'b0}};
        c_wr_gray_r1 <= {(C_AW+1){1'b0}};
        c_wr_gray_r2 <= {(C_AW+1){1'b0}};
    end else begin
        c_wr_gray_r1 <= c_wr_gray;
        c_wr_gray_r2 <= c_wr_gray_r1;
        if (!c_empty) begin
            c_rd_bin  <= c_rd_bin + 1'b1;
            c_rd_gray <= c_bin2gray(c_rd_bin + 1'b1);
        end
    end
end

wire [C_W-1:0] c_dout = c_mem[c_rd_bin[C_AW-1:0]];
wire [31:0] c_idx_s2  = c_dout[31:0];
wire [31:0] c_crc_s2  = c_dout[63:32];
wire [31:0] c_w_s2    = c_dout[95:64];
wire [7:0]  c_lane_s2 = c_dout[103:96];
wire        complete_mac = ~c_empty;

// Window-sized CRC file on clk_mac (distributed; P_W=32 fits easily).
(* ram_style = "distributed" *) reg [31:0] crc_slot  [0:P_W-1];
(* ram_style = "distributed" *) reg [31:0] wcnt_slot [0:P_W-1];
(* ram_style = "distributed" *) reg [7:0]  lane_slot [0:P_W-1];
(* ram_style = "distributed" *) reg        done_slot [0:P_W-1];
(* ram_style = "distributed" *) reg [31:0] idx_slot  [0:P_W-1];
integer si;
localparam integer SLOT_AW = $clog2(P_W);

always @(posedge clk_mac) begin
    if (rst || strip_clear) begin
        for (si = 0; si < P_W; si = si + 1)
            done_slot[si] <= 1'b0;
    end else if (complete_mac) begin
        crc_slot [c_idx_s2[SLOT_AW-1:0]] <= c_crc_s2;
        wcnt_slot[c_idx_s2[SLOT_AW-1:0]] <= c_w_s2;
        lane_slot[c_idx_s2[SLOT_AW-1:0]] <= c_lane_s2;
        idx_slot [c_idx_s2[SLOT_AW-1:0]] <= c_idx_s2;
        done_slot[c_idx_s2[SLOT_AW-1:0]] <= 1'b1;
    end
end

always @(posedge clk_mac) begin
    if (rst) begin
        crc_rd_crc32 <= 32'd0;
        crc_rd_words <= 32'd0;
        crc_rd_done  <= 1'b0;
        crc_rd_lane  <= 8'd0;
    end else if (crc_rd_en) begin
        crc_rd_crc32 <= crc_slot [crc_rd_index[SLOT_AW-1:0]];
        crc_rd_words <= wcnt_slot[crc_rd_index[SLOT_AW-1:0]];
        crc_rd_lane  <= lane_slot[crc_rd_index[SLOT_AW-1:0]];
        crc_rd_done  <= done_slot[crc_rd_index[SLOT_AW-1:0]] &&
                        (idx_slot[crc_rd_index[SLOT_AW-1:0]][11:0] == crc_rd_index);
    end
end

rle4k_ring_window #(
    .P_BASE        (P_BASE),
    .P_BLOCK_BYTES (P_BLOCK_BYTES),
    .P_W           (P_W)
) u_ring (
    .clk                  (clk_mac),
    .rst_n                (~rst),
    .clear                (strip_clear),
    .accept_valid         (accept_valid),
    .accept_block_index   (accept_block_index),
    .accept_ready         (accept_ready),
    .retx_pending         (retx_pending),
    .retx_count           (retx_count),
    .complete_valid       (complete_mac),
    .complete_block_index (c_idx_s2),
    .slot                 (ring_slot),
    .byte_addr            (ring_byte_addr),
    .complete_bitmap      (complete_bitmap),
    .window_base_index    (window_base_index),
    .last_byte_addr       (last_byte_addr),
    .blocks_completed     (blocks_completed_win)
);

endmodule
