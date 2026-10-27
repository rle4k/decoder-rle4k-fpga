// ============================================================================
// RLE4K Stream Adapter v0.8 -- Pure Stream Decode (MAC layer)
// ============================================================================
// Based on V05 single-FSM architecture (proven on board).
// Protocol v0.7: STREAM_START/DATA/END replace all BLOCK_* commands.
// No STRIP_DATA_ACK, no per-packet confirmations, no flow control.
// CLI sends a continuous compressed stream; FPGA decodes it as one block.
//
// Retained commands: PING/PONG, ECHO, STATUS, GET, RESET, ERROR_RSP
// Activity watchdog: soft-reset if no host command / stream feed and no decoder block_done
// edge for P_WDT_TIMEOUT_TICKS @ clk (decoder progress also clears the inactivity counter).
// ============================================================================

`timescale 1ns / 1ps

module rle4k_stream_adapter_v8 #(
    // Watchdog: host must send a valid command (S_DISPATCH) or stream data (dec_valid in feed),
    // or decoder must assert block_done (rising), within this many clk cycles (default 60 s @ 15.625 MHz).
    parameter [31:0] P_WDT_TIMEOUT_TICKS = 32'd937_500_000,
    // K-parallel decode modules (lanes). Top demuxes dec_* onto lane buses via active_lane.
    parameter integer P_NUM_LANES = 4
) (
    input  wire        clk,
    input  wire        rst_n,

    // --- Supplier UDP RX ---
    input  wire        rx_valid,
    input  wire [63:0] rx_data,
    input  wire [7:0]  rx_keep,
    input  wire        rx_last,
    input  wire [15:0] rx_length,
    output wire        rx_ready,
    // Early PAUSE: high while waiting in S_BLOCK_ASSIGN (no free lane / ring not ready).
    output wire        rx_congested,

    // --- Supplier UDP TX ---
    output reg         tx_request,
    input  wire        tx_ack,
    input  wire        tx_ready,
    output reg         tx_valid,
    output reg  [63:0] tx_data,
    output reg  [7:0]  tx_keep,
    output reg         tx_last,
    output reg  [15:0] tx_length,

    // --- Decoder compressed data (32-bit); top steers to active_lane ---
    output reg  [31:0] dec_data,
    output reg         dec_valid,
    output reg         dec_stream_end,    // Pulse when STREAM_END received (to active lane)
    output reg  [1:0]  active_lane,       // 0..P_NUM_LANES-1
    output reg         parallel_mode,     // 1 after first STREAM_BLOCK_START this strip

    // --- Decoder config (legacy shared + per-lane mirrors for bank) ---
    output reg  [31:0] cfg_block_index,
    output reg  [31:0] cfg_line_width,
    output reg  [31:0] cfg_line_stride,
    output reg  [31:0] cfg_block_height,
    // Total decoded lines in strip (= STREAM_START total_height); constant for whole strip (cfg-only strip_done).
    output reg  [31:0] cfg_strip_line_count,
    output reg  [31:0] cfg_rle_payload_bytes,
    // Toggles each time STREAM_START payload is latched (CDC to 125 MHz for decoder byte counter reset).
    output reg         strip_cfg_toggle,
    // Per-lane cfg buses (MAC domain); strip_cfg_toggle_lane pulses the assigned lane only.
    output reg  [32*P_NUM_LANES-1:0] cfg_block_index_bus,
    output reg  [32*P_NUM_LANES-1:0] cfg_block_height_bus,
    output reg  [32*P_NUM_LANES-1:0] cfg_strip_line_count_bus,
    output reg  [32*P_NUM_LANES-1:0] cfg_rle_payload_bytes_bus,
    output reg  [P_NUM_LANES-1:0]    lane_cfg_toggle_bus,

    // --- Decoder status feedback ---
    input  wire [31:0] decode_status,
    input  wire        block_done,                    // OR of lanes (WDT / legacy)
    input  wire [P_NUM_LANES-1:0] block_done_bus,     // per-lane done

    // --- CDC FIFO status (active lane almost_full from top) ---
    input  wire        cdc_full,

    // --- Soft reset ---
    output reg         soft_rst,

    // --- Decode CRC32 (from top, CDC-synced); legacy strip CRC still wired ---
    input  wire [31:0] decode_crc32,
    input  wire [31:0] decode_crc32_wcnt,
    input  wire        decode_crc32_done,

    // --- Diagnostic CRC at 5 word checkpoints (from top, CDC-synced) ---
    input  wire [31:0] diag_crc_0,   // word 0
    input  wire [31:0] diag_crc_1,   // word 1
    input  wire [31:0] diag_crc_2,   // word 9
    input  wire [31:0] diag_crc_3,   // word 127
    input  wire [31:0] diag_crc_4,   // word 128
    // Relative to the END of the strip. The five above are all inside the first 257
    // words, which made the response blind to any late corruption.
    input  wire [31:0] diag_crc_5,   // accumulator excluding the last 128 words
    input  wire [31:0] diag_crc_6,   // accumulator excluding the last 256 words

    // --- Ring window / per-block CRC bank (from parallel bank) ---
    output reg         ring_accept_valid,
    output reg  [31:0] ring_accept_block_index,
    input  wire        ring_accept_ready,
    input  wire        ring_retx_pending,
    input  wire [31:0] ring_retx_count,
    input  wire [31:0] ring_complete_bitmap,
    input  wire [31:0] ring_window_base,
    input  wire [31:0] ring_last_byte_addr,
    input  wire [31:0] ring_blocks_completed,
    input  wire [31:0] last_block_index,
    input  wire [31:0] last_block_crc32,
    input  wire [31:0] last_block_words,
    input  wire [7:0]  last_block_lane,
    input  wire        last_block_valid,

    // CRC slot-file read (MAC domain, 1-cycle latency after crc_rd_en)
    output reg         crc_rd_en,
    output reg  [11:0] crc_rd_index,
    input  wire [31:0] crc_rd_crc32,
    input  wire [31:0] crc_rd_words,
    input  wire        crc_rd_done,
    input  wire [7:0]  crc_rd_lane,

    // --- Debug (224b: mon_wdt_timeout + 6x32b legacy counters) ---
    output wire [223:0] dbg_cnt_bus,
    output wire [63:0]  dbg_state_bus
);

// ============================================================================
// Command constants (must match protocol_v7.h)
// ============================================================================
localparam CMD_STREAM_START       = 8'h40;
localparam CMD_STREAM_DATA        = 8'h41;
localparam CMD_STREAM_END         = 8'h42;
localparam CMD_STREAM_BLOCK_START = 8'h43;

localparam CMD_PING        = 8'h10;
localparam CMD_PONG        = 8'h11;
localparam CMD_ECHO_REQ    = 8'h12;
localparam CMD_ECHO_RSP    = 8'h13;
localparam CMD_STATUS_REQ  = 8'h20;
localparam CMD_STATUS_RSP  = 8'h21;
localparam CMD_GET_REQ     = 8'h22;
localparam CMD_GET_RSP     = 8'h23;
localparam CMD_RESET       = 8'hF0;
localparam CMD_ERROR_RSP   = 8'hFE;

// ErrorType codes
localparam ERRT_INVALID_CMD     = 8'h01;
localparam ERRT_INVALID_LEN     = 8'h02;

// GET item ids
localparam [15:0] GET_ID_VERSION      = 16'h0101;
localparam [15:0] GET_ID_FORMATS      = 16'h0102;
localparam [15:0] GET_ID_MAC          = 16'h0103;
localparam [15:0] GET_ID_FPGA         = 16'h0104;
localparam [15:0] GET_ID_DDR4         = 16'h0201;
localparam [15:0] GET_ID_WINDOW       = 16'h0301;
localparam [15:0] GET_ID_STATUS_GROUP = 16'h0400;
localparam [15:0] GET_ID_DECODE_CRC       = 16'h0501;
localparam [15:0] GET_ID_DECODE_BLOCK_CRC = 16'h0502;
localparam [15:0] GET_ID_PARALLEL_INFO    = 16'h0503;
localparam [15:0] GET_ID_ACTIVITY_WDT     = 16'h0601; // activity watchdog: counts + threshold (GET dog)
localparam [15:0] GET_ID_ALL              = 16'hFFFF;

// Board/Firmware version fields
localparam [31:0] VER_FW_VERSION   = 32'h00080110; // v0.8.1.16 earlier stg PAUSE (8 KiB headroom)
localparam [31:0] VER_BOARD_VERSION= 32'h00000001;
localparam [31:0] VER_BOARD_VENDOR = 32'h52444C41; // "RDLA"
localparam [31:0] VER_FW_BUILDER   = 32'h41493533; // "AI53"
localparam [31:0] VER_BURN_TIME    = 32'h20260810; // YYYYMMDD

localparam [31:0] RING_BASE         = 32'h20000000;
localparam [31:0] RING_BLOCK_BYTES  = 32'd4194304;
localparam [7:0]  RING_WINDOWS      = 8'd32;

localparam [7:0] VT_NULL         = 8'h00;
localparam [7:0] VT_U8           = 8'h01;
localparam [7:0] VT_U16          = 8'h02;
localparam [7:0] VT_U32          = 8'h03;
localparam [7:0] VT_U64          = 8'h04;
localparam [7:0] VT_MAC6         = 8'h11;
localparam [7:0] VT_INT4_PACKED  = 8'h20;
localparam [7:0] VT_TLV_LIST     = 8'hF0;

localparam [7:0] GST_OK       = 8'h00;
localparam [7:0] GST_NOT_FOUND = 8'h01;

localparam MAX_PKT_WORDS = 188;

// ============================================================================
// RX Packet Buffer
// ============================================================================
reg [63:0] pkt_buf [0:MAX_PKT_WORDS-1];
reg [7:0]  pkt_keep_buf [0:MAX_PKT_WORDS-1];
reg [7:0]  pkt_word_cnt;
reg [15:0] pkt_byte_len;

// ============================================================================
// Stream state
// ============================================================================
reg        stream_active;
reg [31:0] stream_total_bytes;
reg [31:0] stream_rx_bytes;

// Multi-block tracking
reg [31:0] default_block_height;  // from STREAM_START (typically 512)
reg [31:0] remaining_height;      // lines left to decode in strip
reg        block_done_prev_a;     // rising-edge detector for block_done

// ============================================================================
// TX response buffer
// ============================================================================
reg [63:0] tx_buf [0:15];
reg [7:0]  tx_buf_keep [0:15];
reg [7:0]  tx_word_idx;
reg [7:0]  tx_word_total;

// ERROR_RSP fields
reg [7:0]  err_type_r;
reg [7:0]  err_orig_cmd_r;
reg [15:0] err_orig_seq_r;
reg [15:0] err_detail_r;

// GET / ECHO helpers
reg [15:0] get_item_id_r;
reg        get_crc_by_index_r;   // DECODE_BLOCK_CRC with u32 index after item_id
reg [31:0] get_crc_index_r;
reg        tx_mode_echo;
reg [7:0]  tx_last_keep;

// Feed state for STREAM_DATA
reg [15:0] feed_byte_idx;
reg [15:0] feed_end_byte;

// K-parallel lane occupancy (module = lane)
reg [P_NUM_LANES-1:0] lane_busy;
reg [31:0]            lane_block_index [0:P_NUM_LANES-1];
reg [P_NUM_LANES-1:0] block_done_bus_d;
// Lane-overlap telemetry (clk ticks while parallel_mode): sample + multi-busy.
reg [31:0]            lane_sample_cyc;
reg [31:0]            lane_busy_ge2_cyc;
reg [31:0]            lane_busy_ge3_cyc;
reg [31:0]            lane_busy_ge4_cyc;
integer               lane_busy_pop;
integer               lane_i;
integer               lane_off;
reg [1:0]             free_lane_sel;
reg [1:0]             free_lane_cand;
reg [1:0]             last_lane_sel;   // RR cursor: next search starts at last+1
reg                   free_lane_found;
reg [31:0]            pending_block_index;
reg [31:0]            pending_block_height;
reg [31:0]            pending_rle_bytes;

// ============================================================================
// State Machine
// ============================================================================
localparam S_RX_IDLE      = 6'd0;
localparam S_RX_RECV      = 6'd1;
localparam S_DISPATCH     = 6'd2;
localparam S_STREAM_CFG   = 6'd3;
localparam S_STREAM_FEED  = 6'd4;
localparam S_PONG_TX      = 6'd5;
localparam S_PONG_TX_ACK  = 6'd6;
localparam S_ECHO_TX_REQ  = 6'd7;
localparam S_TX_WAIT_ACK  = 6'd8;
localparam S_TX_PKT_DATA  = 6'd9;
localparam S_STATUS_TX    = 6'd10;
localparam S_STATUS_ACK   = 6'd11;
localparam S_STATUS_SEND  = 6'd12;
localparam S_BLOCK_ASSIGN = 6'd13; // STREAM_BLOCK_START: wait free lane + ring accept
localparam S_ERROR_BUILD  = 6'd17;
localparam S_ERROR_TX     = 6'd18;
localparam S_ERROR_ACK    = 6'd19;
localparam S_ERROR_SEND   = 6'd20;
localparam S_TX_DONE      = 6'd21;
localparam S_GET_BUILD    = 6'd22;
localparam S_GET_TX       = 6'd23;
localparam S_GET_ACK      = 6'd24;
localparam S_GET_SEND     = 6'd25;
localparam S_GET_CRC_RD   = 6'd26; // pulse crc_rd_en for by-index DECODE_BLOCK_CRC
localparam S_GET_CRC_WAIT = 6'd28; // 1-cycle wait for slot-file registered read
localparam S_GET_CRC_BUILD= 6'd27; // pack slot-file response

reg [5:0]  state;
reg [7:0]  pkt_cmd;
reg [15:0] pkt_seq;
reg [15:0] pkt_data_len;

// Incoming words are only latched in the two receive states; anywhere else they
// used to be dropped on the floor because nothing upstream could be told to
// wait. Publishing that condition lets rle4k_mac_proto_v8 hold its replay.
// The transmit stall is folded in as well: while a beat is being rejected the
// whole FSM is frozen, so it cannot latch a receive word either.
wire tx_beat_stalled = tx_valid && !tx_ready;

assign rx_ready = ((state == S_RX_IDLE) || (state == S_RX_RECV)) && !tx_beat_stalled;
// Early PAUSE: ASSIGN wait, or active-lane hard stall (staging/CDC full).
// Per-lane staging pause_level is OR'd in lan_top (earlier watermark).
assign rx_congested =
    (state == S_BLOCK_ASSIGN) |
    (state == S_STREAM_FEED && cdc_full);

// Statistics
reg [31:0] mon_rx_datagrams;
reg [31:0] mon_stream_start;
reg [31:0] mon_stream_data;
reg [31:0] mon_stream_end;
reg [31:0] mon_err_rsp;
reg [31:0] mon_reset_cmd;
reg [31:0] mon_wdt_timeout;

// Watchdog (activity-based): see P_WDT_TIMEOUT_TICKS
reg        block_done_d_wdt;
wire       wdt_kick_block_done = block_done & ~block_done_d_wdt;
wire       wdt_kick = (state == S_DISPATCH) || (state == S_STREAM_FEED && dec_valid)
                    || wdt_kick_block_done;
reg  [31:0] wdt_cnt;
reg  [31:0] wdt_cnt_prev;
wire        wdt_timeout_pulse;

always @(posedge clk) begin
    if (!rst_n) begin
        block_done_d_wdt <= 1'b0;
        wdt_cnt          <= 32'd0;
        wdt_cnt_prev     <= 32'd0;
    end else begin
        block_done_d_wdt <= block_done;
        wdt_cnt_prev     <= wdt_cnt;
        if (wdt_kick)
            wdt_cnt <= 32'd0;
        else if (wdt_cnt < P_WDT_TIMEOUT_TICKS)
            wdt_cnt <= wdt_cnt + 32'd1;
    end
end

assign wdt_timeout_pulse = (wdt_cnt == P_WDT_TIMEOUT_TICKS) &&
                           (wdt_cnt_prev == P_WDT_TIMEOUT_TICKS - 32'd1);

// ============================================================================
// Byte access helpers
// ============================================================================
function [7:0] get_byte;
    input [15:0] idx;
    begin
        get_byte = pkt_buf[idx[15:3]] >> (idx[2:0] * 8);
    end
endfunction

function [15:0] get_u16;
    input [15:0] idx;
    begin
        get_u16 = {get_byte(idx + 1), get_byte(idx)};
    end
endfunction

function [31:0] get_u32;
    input [15:0] idx;
    begin
        get_u32 = {get_byte(idx+3), get_byte(idx+2), get_byte(idx+1), get_byte(idx)};
    end
endfunction

function [31:0] mon_inc;
    input [31:0] v;
    begin
        mon_inc = (v == 32'hFFFFFFFF) ? v : (v + 32'd1);
    end
endfunction

assign dbg_cnt_bus = {
    mon_wdt_timeout,
    mon_reset_cmd,
    mon_err_rsp,
    mon_stream_end,
    mon_stream_data,
    mon_stream_start,
    mon_rx_datagrams
};

assign dbg_state_bus = {
    stream_rx_bytes,
    stream_total_bytes[15:0],
    stream_active,
    cfg_block_height[14:0],
    state
};

// ============================================================================
// Main FSM
// ============================================================================
always @(posedge clk) begin
    if (!rst_n) begin
        state              <= S_RX_IDLE;
        pkt_word_cnt       <= 0;
        pkt_byte_len       <= 0;
        tx_request         <= 0;
        tx_valid           <= 0;
        tx_last            <= 0;
        tx_keep            <= 8'hFF;
        tx_length          <= 0;
        tx_data            <= 0;
        dec_data           <= 0;
        dec_valid          <= 0;
        dec_stream_end     <= 0;
        soft_rst           <= 0;
        cfg_block_index    <= 0;
        cfg_line_width     <= 0;
        cfg_line_stride    <= 0;
        cfg_block_height   <= 0;
        cfg_strip_line_count <= 0;
        cfg_rle_payload_bytes <= 32'd0;
        strip_cfg_toggle   <= 1'b0;
        feed_byte_idx      <= 0;
        feed_end_byte      <= 0;
        tx_word_idx        <= 0;
        tx_word_total      <= 0;
        get_item_id_r      <= 0;
        get_crc_by_index_r <= 1'b0;
        get_crc_index_r    <= 32'd0;
        crc_rd_en          <= 1'b0;
        crc_rd_index       <= 12'd0;
        tx_mode_echo       <= 1'b0;
        tx_last_keep       <= 8'hFF;
        stream_active      <= 1'b0;
        stream_total_bytes <= 32'd0;
        stream_rx_bytes    <= 32'd0;
        default_block_height <= 32'd512;
        remaining_height     <= 32'd0;
        block_done_prev_a    <= 1'b0;
        mon_rx_datagrams   <= 32'd0;
        mon_stream_start   <= 32'd0;
        mon_stream_data    <= 32'd0;
        mon_stream_end     <= 32'd0;
        mon_err_rsp        <= 32'd0;
        mon_reset_cmd      <= 32'd0;
        mon_wdt_timeout    <= 32'd0;
        active_lane        <= 2'd0;
        parallel_mode      <= 1'b0;
        lane_busy          <= {P_NUM_LANES{1'b0}};
        // Seed so first RR pick is lane 0: search starts at (K-1)+1.
        last_lane_sel      <= P_NUM_LANES[1:0] - 2'd1;
        block_done_bus_d   <= {P_NUM_LANES{1'b0}};
        ring_accept_valid  <= 1'b0;
        ring_accept_block_index <= 32'd0;
        lane_cfg_toggle_bus <= {P_NUM_LANES{1'b0}};
        cfg_block_index_bus <= {32*P_NUM_LANES{1'b0}};
        cfg_block_height_bus <= {32*P_NUM_LANES{1'b0}};
        cfg_strip_line_count_bus <= {32*P_NUM_LANES{1'b0}};
        cfg_rle_payload_bytes_bus <= {32*P_NUM_LANES{1'b0}};
        for (lane_i = 0; lane_i < P_NUM_LANES; lane_i = lane_i + 1)
            lane_block_index[lane_i] <= 32'd0;
        pending_block_index  <= 32'd0;
        pending_block_height <= 32'd0;
        pending_rle_bytes    <= 32'd0;
        lane_sample_cyc      <= 32'd0;
        lane_busy_ge2_cyc    <= 32'd0;
        lane_busy_ge3_cyc    <= 32'd0;
        lane_busy_ge4_cyc    <= 32'd0;
    end else if (tx_beat_stalled) begin
        // Downstream rejected the current transmit beat. Freeze the FSM so the
        // beat is re-presented unchanged, but still retire the one-cycle pulses
        // -- holding dec_valid would feed the decoder the same word twice.
        dec_valid       <= 0;
        dec_stream_end  <= 0;
        soft_rst        <= 0;
        ring_accept_valid <= 0;
        crc_rd_en       <= 0;
        lane_cfg_toggle_bus <= {P_NUM_LANES{1'b0}};
    end else begin
        dec_valid       <= 0;
        dec_stream_end  <= 0;  // Clear pulse each cycle
        soft_rst        <= 0;
        ring_accept_valid <= 0;
        crc_rd_en       <= 0;
        lane_cfg_toggle_bus <= {P_NUM_LANES{1'b0}};

        // Free lanes on block_done rising edges (complete => release module)
        block_done_bus_d <= block_done_bus;
        for (lane_i = 0; lane_i < P_NUM_LANES; lane_i = lane_i + 1) begin
            if (block_done_bus[lane_i] && !block_done_bus_d[lane_i])
                lane_busy[lane_i] <= 1'b0;
        end

        // Lane overlap telemetry (strip-scoped; cleared on STREAM_START / RESET)
        if (parallel_mode) begin
            lane_sample_cyc <= lane_sample_cyc + 32'd1;
            lane_busy_pop = 0;
            for (lane_i = 0; lane_i < P_NUM_LANES; lane_i = lane_i + 1)
                if (lane_busy[lane_i]) lane_busy_pop = lane_busy_pop + 1;
            if (lane_busy_pop >= 2)
                lane_busy_ge2_cyc <= lane_busy_ge2_cyc + 32'd1;
            if (lane_busy_pop >= 3)
                lane_busy_ge3_cyc <= lane_busy_ge3_cyc + 32'd1;
            if (lane_busy_pop >= P_NUM_LANES)
                lane_busy_ge4_cyc <= lane_busy_ge4_cyc + 32'd1;
        end

        if (wdt_timeout_pulse) begin
            // Host idle too long: same effect as CMD_RESET (see product spec watchdog).
            soft_rst           <= 1'b1;
            stream_active      <= 1'b0;
            stream_rx_bytes    <= 32'd0;
            parallel_mode      <= 1'b0;
            lane_busy          <= {P_NUM_LANES{1'b0}};
            last_lane_sel      <= P_NUM_LANES[1:0] - 2'd1;
            lane_sample_cyc    <= 32'd0;
            lane_busy_ge2_cyc  <= 32'd0;
            lane_busy_ge3_cyc  <= 32'd0;
            lane_busy_ge4_cyc  <= 32'd0;
            state              <= S_RX_IDLE;
            tx_request         <= 1'b0;
            tx_valid           <= 1'b0;
            tx_last            <= 1'b0;
            mon_wdt_timeout    <= mon_inc(mon_wdt_timeout);
        end else case (state)

        // ==========================================================
        // RX: buffer incoming UDP payload
        // ==========================================================
        S_RX_IDLE: begin
            tx_request   <= 0;
            tx_valid     <= 0;
            pkt_word_cnt <= 0;
            if (rx_valid) begin
                pkt_buf[0]      <= rx_data;
                pkt_keep_buf[0] <= rx_keep;
                pkt_byte_len    <= rx_length;
                pkt_word_cnt    <= 1;
                state <= rx_last ? S_DISPATCH : S_RX_RECV;
            end
        end

        S_RX_RECV: begin
            if (rx_valid) begin
                if (pkt_word_cnt < MAX_PKT_WORDS) begin
                    pkt_buf[pkt_word_cnt]      <= rx_data;
                    pkt_keep_buf[pkt_word_cnt] <= rx_keep;
                end
                pkt_word_cnt <= pkt_word_cnt + 1;
                if (rx_last) state <= S_DISPATCH;
            end
        end

        // ==========================================================
        // DISPATCH: parse header + route
        // ==========================================================
        S_DISPATCH: begin
            mon_rx_datagrams <= mon_inc(mon_rx_datagrams);
            pkt_cmd      <= get_byte(0);
            pkt_seq      <= get_u16(1);
            pkt_data_len <= get_u16(3);

            case (get_byte(0))
                CMD_PING:       state <= S_PONG_TX;
                CMD_ECHO_REQ:   state <= S_ECHO_TX_REQ;
                CMD_STATUS_REQ: state <= S_STATUS_TX;

                CMD_STREAM_START: begin
                    mon_stream_start <= mon_inc(mon_stream_start);
                    if (get_u16(3) < 16'd24) begin
                        err_type_r     <= ERRT_INVALID_LEN;
                        err_orig_cmd_r <= CMD_STREAM_START;
                        err_orig_seq_r <= get_u16(1);
                        err_detail_r   <= get_u16(3);
                        state          <= S_ERROR_BUILD;
                    end else begin
                        state <= S_STREAM_CFG;
                    end
                end

                CMD_STREAM_DATA: begin
                    mon_stream_data <= mon_inc(mon_stream_data);
                    if (!stream_active) begin
                        err_type_r     <= ERRT_INVALID_CMD;
                        err_orig_cmd_r <= CMD_STREAM_DATA;
                        err_orig_seq_r <= get_u16(1);
                        err_detail_r   <= 16'd0;
                        state          <= S_ERROR_BUILD;
                    end else begin
                        feed_byte_idx <= 16'd5; // skip PayloadHeader
                        feed_end_byte <= 16'd5 + get_u16(3);
                        state         <= S_STREAM_FEED;
                    end
                end

                CMD_STREAM_BLOCK_START: begin
                    if (!stream_active) begin
                        err_type_r     <= ERRT_INVALID_CMD;
                        err_orig_cmd_r <= CMD_STREAM_BLOCK_START;
                        err_orig_seq_r <= get_u16(1);
                        err_detail_r   <= 16'd0;
                        state          <= S_ERROR_BUILD;
                    end else if (get_u16(3) < 16'd16) begin
                        err_type_r     <= ERRT_INVALID_LEN;
                        err_orig_cmd_r <= CMD_STREAM_BLOCK_START;
                        err_orig_seq_r <= get_u16(1);
                        err_detail_r   <= get_u16(3);
                        state          <= S_ERROR_BUILD;
                    end else begin
                        // StreamBlockStartPayload @ offset 5: bi, height, rle_bytes, reserved
                        pending_block_index  <= get_u32(16'd5);
                        pending_block_height <= get_u32(16'd9);
                        pending_rle_bytes    <= get_u32(16'd13);
                        parallel_mode        <= 1'b1;
                        state                <= S_BLOCK_ASSIGN;
                    end
                end

                CMD_STREAM_END: begin
                    mon_stream_end <= mon_inc(mon_stream_end);
                    stream_active  <= 1'b0;
                    dec_stream_end <= 1'b1;  // Pulse to active lane
                    state          <= S_RX_IDLE;
                end

                CMD_RESET: begin
                    mon_reset_cmd  <= mon_inc(mon_reset_cmd);
                    soft_rst       <= 1;
                    stream_active  <= 1'b0;
                    stream_rx_bytes <= 32'd0;
                    parallel_mode  <= 1'b0;
                    lane_busy      <= {P_NUM_LANES{1'b0}};
                    last_lane_sel  <= P_NUM_LANES[1:0] - 2'd1;
                    lane_sample_cyc   <= 32'd0;
                    lane_busy_ge2_cyc <= 32'd0;
                    lane_busy_ge3_cyc <= 32'd0;
                    lane_busy_ge4_cyc <= 32'd0;
                    state          <= S_RX_IDLE;
                end

                CMD_GET_REQ: begin
                    if (get_u16(3) < 16'd2) begin
                        err_type_r     <= ERRT_INVALID_LEN;
                        err_orig_cmd_r <= CMD_GET_REQ;
                        err_orig_seq_r <= get_u16(1);
                        err_detail_r   <= get_u16(3);
                        state          <= S_ERROR_BUILD;
                    end else begin
                        get_item_id_r <= get_u16(16'd5);
                        // Optional u32 LE block_index after item_id (body len >= 6)
                        // selects CRC slot-file read instead of last_block_*.
                        if (get_u16(16'd5) == GET_ID_DECODE_BLOCK_CRC &&
                            get_u16(3) >= 16'd6) begin
                            get_crc_by_index_r <= 1'b1;
                            get_crc_index_r    <= get_u32(16'd7);
                            state              <= S_GET_CRC_RD;
                        end else begin
                            get_crc_by_index_r <= 1'b0;
                            state              <= S_GET_BUILD;
                        end
                    end
                end

                default: begin
                    err_type_r     <= ERRT_INVALID_CMD;
                    err_orig_cmd_r <= get_byte(0);
                    err_orig_seq_r <= get_u16(1);
                    err_detail_r   <= {8'h00, get_byte(0)};
                    state          <= S_ERROR_BUILD;
                end
            endcase
        end

        // ==========================================================
        // STREAM_CFG: parse STREAM_START payload, configure decoder
        // First cycle: set config (must happen BEFORE block_start for CDC timing)
        // ==========================================================
        S_STREAM_CFG: begin
            // StreamStartPayload at offset 5 (after PayloadHeader), 24 bytes (protocol_v8.h):
            //   [5..8]    line_width_bits   (u32 LE)
            //   [9..12]   line_stride_bits  (u32 LE)
            //   [13..16]  total_height      (u32 LE)
            //   [17..20]  total_bytes       (u32 LE) wire length incl. tail 0x00 pad
            //   [21..22]  strip_index       (u16 LE)
            //   [23..24]  block_height      (u16 LE)
            //   [25..28]  rle_payload_bytes (u32 LE) logical RLE bytes only
            cfg_line_width     <= get_u32(16'd5);
            cfg_line_stride    <= get_u32(16'd9);
            cfg_block_index    <= 32'd0;
            stream_total_bytes <= get_u32(16'd17);
            stream_rx_bytes    <= 32'd0;
            stream_active      <= 1'b1;
            cfg_rle_payload_bytes <= get_u32(16'd25);
            strip_cfg_toggle     <= ~strip_cfg_toggle;
            parallel_mode        <= 1'b0;
            lane_busy            <= {P_NUM_LANES{1'b0}};
            last_lane_sel        <= P_NUM_LANES[1:0] - 2'd1;
            active_lane          <= 2'd0;
            lane_sample_cyc      <= 32'd0;
            lane_busy_ge2_cyc    <= 32'd0;
            lane_busy_ge3_cyc    <= 32'd0;
            lane_busy_ge4_cyc    <= 32'd0;

            // Multi-block: parse block_height, compute first block height
            default_block_height <= {16'd0, get_u16(16'd23)};
            remaining_height     <= get_u32(16'd13);
            cfg_strip_line_count   <= get_u32(16'd13);
            if (get_u32(16'd13) > {16'd0, get_u16(16'd23)})
                cfg_block_height <= {16'd0, get_u16(16'd23)};
            else
                cfg_block_height <= get_u32(16'd13);

            // Seed lane 0 cfg for legacy (no BLOCK_START) path
            cfg_block_index_bus[31:0]         <= 32'd0;
            cfg_block_height_bus[31:0]        <= (get_u32(16'd13) > {16'd0, get_u16(16'd23)})
                                                 ? {16'd0, get_u16(16'd23)} : get_u32(16'd13);
            cfg_strip_line_count_bus[31:0]    <= get_u32(16'd13);
            cfg_rle_payload_bytes_bus[31:0]   <= get_u32(16'd25);
            lane_cfg_toggle_bus[0]            <= 1'b1;

            state              <= S_RX_IDLE;
        end

        // ==========================================================
        // BLOCK_ASSIGN: pick free lane + ring accept (may wait)
        // RR-among-free: start at last_lane_sel+1 so idle-host gaps still
        // rotate through all K modules. Lowest-free (old) collapsed to
        // lane0/1 only on board (fw=0x80108: 1237/1166/0/0).
        // ==========================================================
        S_BLOCK_ASSIGN: begin
            free_lane_found = 1'b0;
            free_lane_sel   = 2'd0;
            free_lane_cand  = 2'd0;
            for (lane_off = 0; lane_off < P_NUM_LANES; lane_off = lane_off + 1) begin
                free_lane_cand = last_lane_sel + 2'd1 + lane_off[1:0];
                if (free_lane_cand >= P_NUM_LANES[1:0])
                    free_lane_cand = free_lane_cand - P_NUM_LANES[1:0];
                if (!lane_busy[free_lane_cand] && !free_lane_found) begin
                    free_lane_found = 1'b1;
                    free_lane_sel   = free_lane_cand;
                end
            end
            if (free_lane_found && ring_accept_ready) begin
                active_lane <= free_lane_sel;
                last_lane_sel <= free_lane_sel;
                lane_busy[free_lane_sel] <= 1'b1;
                lane_block_index[free_lane_sel] <= pending_block_index;
                cfg_block_index    <= pending_block_index;
                cfg_block_height   <= pending_block_height;
                // Per-block: strip_line_count == block_height so strip_end follows block
                cfg_strip_line_count   <= pending_block_height;
                cfg_rle_payload_bytes  <= pending_rle_bytes;
                cfg_block_index_bus[32*free_lane_sel +: 32]        <= pending_block_index;
                cfg_block_height_bus[32*free_lane_sel +: 32]       <= pending_block_height;
                cfg_strip_line_count_bus[32*free_lane_sel +: 32]   <= pending_block_height;
                cfg_rle_payload_bytes_bus[32*free_lane_sel +: 32]  <= pending_rle_bytes;
                lane_cfg_toggle_bus[free_lane_sel]                 <= 1'b1;
                ring_accept_block_index <= pending_block_index;
                ring_accept_valid       <= 1'b1;
                state <= S_RX_IDLE;
            end
            // else wait: all lanes busy or ring would overwrite incomplete (retx sticky in bank)
        end

        // ==========================================================
        // STREAM_FEED: push raw compressed data to decoder
        // Backpressure: stall when CDC FIFO is full to prevent data loss
        // ==========================================================
        S_STREAM_FEED: begin
            if (cdc_full) begin
                // CDC FIFO full -- hold current position, do not advance
            end else if (feed_byte_idx + 4 <= feed_end_byte) begin
                dec_data      <= get_u32(feed_byte_idx);
                dec_valid     <= 1;
                feed_byte_idx <= feed_byte_idx + 4;
                stream_rx_bytes <= stream_rx_bytes + 32'd4;
            end else if (feed_byte_idx < feed_end_byte) begin
                dec_data <= 32'd0;
                case (feed_end_byte - feed_byte_idx)
                    16'd1: dec_data[7:0]  <= get_byte(feed_byte_idx);
                    16'd2: dec_data[15:0] <= {get_byte(feed_byte_idx+1), get_byte(feed_byte_idx)};
                    16'd3: dec_data[23:0] <= {get_byte(feed_byte_idx+2), get_byte(feed_byte_idx+1), get_byte(feed_byte_idx)};
                    default: ;
                endcase
                dec_valid     <= 1;
                feed_byte_idx <= feed_end_byte;
                stream_rx_bytes <= stream_rx_bytes + {16'd0, feed_end_byte - feed_byte_idx};
            end else begin
                state <= S_RX_IDLE;
            end
        end

        // ==========================================================
        // PONG response (5 bytes)
        // ==========================================================
        S_PONG_TX: begin
            tx_request <= 1;
            tx_length  <= 16'd5;
            state      <= S_PONG_TX_ACK;
        end

        S_PONG_TX_ACK: begin
            if (tx_ack) begin
                tx_request <= 0;
                tx_valid   <= 1;
                tx_data    <= {24'd0, 8'h00, 8'h00, pkt_seq[15:8], pkt_seq[7:0], CMD_PONG};
                tx_keep    <= 8'h1F;
                tx_last    <= 1;
                state      <= S_TX_DONE;
            end
        end

        // ==========================================================
        // ECHO response: swap cmd to 0x13, replay entire packet
        // ==========================================================
        S_ECHO_TX_REQ: begin
            pkt_buf[0][7:0] <= CMD_ECHO_RSP;
            tx_mode_echo    <= 1'b1;
            tx_request    <= 1;
            tx_length     <= pkt_byte_len;
            tx_word_idx   <= 0;
            tx_word_total <= (pkt_byte_len + 7) >> 3;
            state         <= S_TX_WAIT_ACK;
        end

        S_TX_WAIT_ACK: begin
            if (tx_ack) begin
                tx_request <= 0;
                state      <= S_TX_PKT_DATA;
            end
        end

        S_TX_PKT_DATA: begin
            tx_valid <= 1;
            tx_data  <= pkt_buf[tx_word_idx];
            if (tx_word_idx + 1 >= tx_word_total) begin
                tx_last <= 1;
                if (tx_mode_echo)
                    tx_keep <= pkt_keep_buf[tx_word_idx];
                else
                    tx_keep <= tx_last_keep;
                state   <= S_TX_DONE;
            end else begin
                tx_last <= 0;
                tx_keep <= 8'hFF;
            end
            tx_word_idx <= tx_word_idx + 1;
        end

        // ==========================================================
        // STATUS response (17 bytes)
        // ==========================================================
        S_STATUS_TX: begin
            tx_buf[0] <= {
                block_done ? 8'h01 : 8'h00,
                8'h0C, 8'h00,
                pkt_seq[15:8], pkt_seq[7:0],
                CMD_STATUS_RSP
            };
            tx_buf[1] <= {
                8'h00, 8'h00, 8'h00, 8'h00,
                8'h00, 8'h00,
                decode_status[7:0],
                8'h00
            };
            tx_buf[2] <= 64'd0;
            tx_buf_keep[0] <= 8'hFF;
            tx_buf_keep[1] <= 8'hFF;
            tx_buf_keep[2] <= 8'h01;
            tx_request    <= 1;
            tx_length     <= 16'd17;
            tx_word_idx   <= 0;
            tx_word_total <= 3;
            state         <= S_STATUS_ACK;
        end

        S_STATUS_ACK: begin
            if (tx_ack) begin
                tx_request <= 0;
                state      <= S_STATUS_SEND;
            end
        end

        S_STATUS_SEND: begin
            tx_valid <= 1;
            tx_data  <= tx_buf[tx_word_idx];
            tx_keep  <= tx_buf_keep[tx_word_idx];
            if (tx_word_idx + 1 >= tx_word_total) begin
                tx_last <= 1;
                state   <= S_TX_DONE;
            end else begin
                tx_last <= 0;
            end
            tx_word_idx <= tx_word_idx + 1;
        end

        // ==========================================================
        // ERROR_RSP: build 11-byte response
        // ==========================================================
        S_ERROR_BUILD: begin
            mon_err_rsp <= mon_inc(mon_err_rsp);
            tx_buf[0] <= {
                err_orig_seq_r[7:0],
                err_orig_cmd_r,
                err_type_r,
                8'h06, 8'h00,
                8'h00, 8'h00,
                CMD_ERROR_RSP
            };
            tx_buf[1] <= {
                40'd0,
                err_detail_r[15:8],
                err_detail_r[7:0],
                err_orig_seq_r[15:8]
            };
            tx_buf_keep[0] <= 8'hFF;
            tx_buf_keep[1] <= 8'h07;
            tx_word_total  <= 2;
            state          <= S_ERROR_TX;
        end

        S_ERROR_TX: begin
            tx_request  <= 1;
            tx_length   <= 16'd11;
            tx_word_idx <= 0;
            state       <= S_ERROR_ACK;
        end

        S_ERROR_ACK: begin
            if (tx_ack) begin
                tx_request <= 0;
                state      <= S_ERROR_SEND;
            end
        end

        S_ERROR_SEND: begin
            tx_valid <= 1;
            tx_data  <= tx_buf[tx_word_idx];
            tx_keep  <= tx_buf_keep[tx_word_idx];
            if (tx_word_idx + 1 >= tx_word_total) begin
                tx_last <= 1;
                state   <= S_TX_DONE;
            end else begin
                tx_last <= 0;
            end
            tx_word_idx <= tx_word_idx + 1;
        end

        // ==========================================================
        // GET_REQ -> GET_RSP (same as V05)
        // ==========================================================
        S_GET_CRC_RD: begin
            // Request slot read this cycle; bank registers the result on the
            // *next* posedge, so we must not sample until S_GET_CRC_BUILD.
            crc_rd_en    <= 1'b1;
            crc_rd_index <= get_crc_index_r[11:0];
            state        <= S_GET_CRC_WAIT;
        end

        S_GET_CRC_WAIT: begin
            crc_rd_en <= 1'b0;
            state     <= S_GET_CRC_BUILD;
        end

        S_GET_CRC_BUILD: begin
            // crc_rd_* valid (bank updated on previous posedge while en was high).
            tx_buf[0] <= {
                GET_ID_DECODE_BLOCK_CRC[15:8], GET_ID_DECODE_BLOCK_CRC[7:0], GST_OK,
                8'h00, 8'h14,
                pkt_seq[15:8], pkt_seq[7:0], CMD_GET_RSP
            };
            tx_buf[1] <= {
                crc_rd_crc32[7:0],
                get_crc_index_r[31:24], get_crc_index_r[23:16],
                get_crc_index_r[15:8], get_crc_index_r[7:0],
                8'h00, 8'h0E, 8'h20
            };
            tx_buf[2] <= {
                {7'd0, crc_rd_done},
                crc_rd_words[31:24], crc_rd_words[23:16],
                crc_rd_words[15:8], crc_rd_words[7:0],
                crc_rd_crc32[31:24], crc_rd_crc32[23:16],
                crc_rd_crc32[15:8]
            };
            tx_buf[3] <= {
                56'd0,
                crc_rd_lane
            };
            tx_buf_keep[0] <= 8'hFF;
            tx_buf_keep[1] <= 8'hFF;
            tx_buf_keep[2] <= 8'hFF;
            tx_buf_keep[3] <= 8'h01;
            tx_length      <= 16'd25;
            tx_word_total  <= 6'd4;
            tx_word_idx    <= 0;
            state          <= S_GET_TX;
        end

        S_GET_BUILD: begin
            case (get_item_id_r)
            GET_ID_VERSION: begin
                tx_buf[0] <= {
                    GET_ID_VERSION[15:8], GET_ID_VERSION[7:0], GST_OK,
                    8'h00, 8'h1A,
                    pkt_seq[15:8], pkt_seq[7:0], CMD_GET_RSP
                };
                tx_buf[1] <= {
                    VER_BOARD_VERSION[7:0],
                    VER_FW_VERSION[31:24], VER_FW_VERSION[23:16],
                    VER_FW_VERSION[15:8],  VER_FW_VERSION[7:0],
                    8'h00, 8'h14, 8'h10
                };
                tx_buf[2] <= {
                    VER_FW_BUILDER[7:0],
                    VER_BOARD_VENDOR[31:24], VER_BOARD_VENDOR[23:16],
                    VER_BOARD_VENDOR[15:8],  VER_BOARD_VENDOR[7:0],
                    VER_BOARD_VERSION[31:24], VER_BOARD_VERSION[23:16],
                    VER_BOARD_VERSION[15:8]
                };
                tx_buf[3] <= {
                    8'h00,
                    VER_BURN_TIME[31:24], VER_BURN_TIME[23:16],
                    VER_BURN_TIME[15:8],  VER_BURN_TIME[7:0],
                    VER_FW_BUILDER[31:24], VER_FW_BUILDER[23:16],
                    VER_FW_BUILDER[15:8]
                };
                tx_buf_keep[0] <= 8'hFF;
                tx_buf_keep[1] <= 8'hFF;
                tx_buf_keep[2] <= 8'hFF;
                tx_buf_keep[3] <= 8'h7F;
                tx_length     <= 16'd31;
                tx_word_total <= 6'd4;
            end
            GET_ID_FORMATS: begin
                tx_buf[0] <= {
                    GET_ID_FORMATS[15:8], GET_ID_FORMATS[7:0], GST_OK,
                    8'h00, 8'h0A,
                    pkt_seq[15:8], pkt_seq[7:0], CMD_GET_RSP
                };
                tx_buf[1] <= 64'h0000000010000403;
                tx_buf_keep[0] <= 8'hFF;
                tx_buf_keep[1] <= 8'h7F;
                tx_length     <= 16'd15;
                tx_word_total <= 6'd2;
            end
            GET_ID_MAC: begin
                tx_buf[0] <= {
                    GET_ID_MAC[15:8], GET_ID_MAC[7:0], GST_OK,
                    8'h00, 8'h0C,
                    pkt_seq[15:8], pkt_seq[7:0], CMD_GET_RSP
                };
                tx_buf[1] <= 64'h0100350a00000611;
                tx_buf[2] <= 64'h0000000000000002;
                tx_buf_keep[0] <= 8'hFF;
                tx_buf_keep[1] <= 8'hFF;
                tx_buf_keep[2] <= 8'h01;
                tx_length     <= 16'd17;
                tx_word_total <= 6'd3;
            end
            GET_ID_FPGA: begin
                tx_buf[0] <= {
                    GET_ID_FPGA[15:8], GET_ID_FPGA[7:0], GST_OK,
                    8'h00, 8'h0A,
                    pkt_seq[15:8], pkt_seq[7:0], CMD_GET_RSP
                };
                tx_buf[1] <= 64'h0000000002000403;
                tx_buf_keep[0] <= 8'hFF;
                tx_buf_keep[1] <= 8'h7F;
                tx_length     <= 16'd15;
                tx_word_total <= 6'd2;
            end
            GET_ID_DDR4: begin
                tx_buf[0] <= {
                    GET_ID_DDR4[15:8], GET_ID_DDR4[7:0], GST_OK,
                    8'h00, 8'h0A,
                    pkt_seq[15:8], pkt_seq[7:0], CMD_GET_RSP
                };
                tx_buf[1] <= 64'h0000200004000403;
                tx_buf_keep[0] <= 8'hFF;
                tx_buf_keep[1] <= 8'h7F;
                tx_length     <= 16'd15;
                tx_word_total <= 6'd2;
            end
            GET_ID_WINDOW: begin
                // WindowStatusPayload 20 B after GetRspHeader (vt=0x10 raw)
                tx_buf[0] <= {
                    GET_ID_WINDOW[15:8], GET_ID_WINDOW[7:0], GST_OK,
                    8'h00, 8'h1A,
                    pkt_seq[15:8], pkt_seq[7:0], CMD_GET_RSP
                };
                tx_buf[1] <= {
                    ring_complete_bitmap[15:8], ring_complete_bitmap[7:0],
                    8'h00, {7'd0, ring_retx_pending},
                    RING_WINDOWS, 8'h00,
                    8'h14, 8'h10
                };
                tx_buf[2] <= {
                    ring_last_byte_addr[7:0],
                    ring_window_base[31:24], ring_window_base[23:16],
                    ring_window_base[15:8], ring_window_base[7:0],
                    ring_complete_bitmap[31:24], ring_complete_bitmap[23:16],
                    ring_complete_bitmap[15:8]
                };
                tx_buf[3] <= {
                    8'h00,
                    ring_retx_count[31:24], ring_retx_count[23:16],
                    ring_retx_count[15:8], ring_retx_count[7:0],
                    ring_last_byte_addr[31:24], ring_last_byte_addr[23:16],
                    ring_last_byte_addr[15:8]
                };
                tx_buf_keep[0] <= 8'hFF;
                tx_buf_keep[1] <= 8'hFF;
                tx_buf_keep[2] <= 8'hFF;
                tx_buf_keep[3] <= 8'h7F;
                tx_length     <= 16'd31;
                tx_word_total <= 6'd4;
            end
            GET_ID_PARALLEL_INFO: begin
                tx_buf[0] <= {
                    GET_ID_PARALLEL_INFO[15:8], GET_ID_PARALLEL_INFO[7:0], GST_OK,
                    8'h00, 8'h1E,
                    pkt_seq[15:8], pkt_seq[7:0], CMD_GET_RSP
                };
                // value_len=0x28: ParallelInfoPayload 40 B (ge2/sample/ge3/ge4)
                tx_buf[1] <= {
                    RING_BASE[7:0],
                    ring_retx_pending, parallel_mode, RING_WINDOWS, P_NUM_LANES[7:0],
                    8'h28, 8'h10
                };
                tx_buf[2] <= {
                    ring_complete_bitmap[7:0],
                    RING_BLOCK_BYTES[31:24], RING_BLOCK_BYTES[23:16],
                    RING_BLOCK_BYTES[15:8], RING_BLOCK_BYTES[7:0],
                    RING_BASE[31:24], RING_BASE[23:16], RING_BASE[15:8]
                };
                tx_buf[3] <= {
                    ring_blocks_completed[7:0],
                    ring_window_base[31:24], ring_window_base[23:16],
                    ring_window_base[15:8], ring_window_base[7:0],
                    ring_complete_bitmap[31:24], ring_complete_bitmap[23:16],
                    ring_complete_bitmap[15:8]
                };
                // value[16..]: bc[15:8..] + ge2 LE + sample[7:0]
                tx_buf[4] <= {
                    lane_sample_cyc[7:0],
                    lane_busy_ge2_cyc[31:24], lane_busy_ge2_cyc[23:16],
                    lane_busy_ge2_cyc[15:8],  lane_busy_ge2_cyc[7:0],
                    ring_blocks_completed[31:24], ring_blocks_completed[23:16],
                    ring_blocks_completed[15:8]
                };
                // value[28..35]: sample[31:8] + ge3 LE + ge4[7:0]
                tx_buf[5] <= {
                    lane_busy_ge4_cyc[7:0],
                    lane_busy_ge3_cyc[31:24], lane_busy_ge3_cyc[23:16],
                    lane_busy_ge3_cyc[15:8],  lane_busy_ge3_cyc[7:0],
                    lane_sample_cyc[31:24], lane_sample_cyc[23:16],
                    lane_sample_cyc[15:8]
                };
                // value[36..39]: ge4[31:8]
                tx_buf[6] <= {
                    40'd0,
                    lane_busy_ge4_cyc[31:24], lane_busy_ge4_cyc[23:16],
                    lane_busy_ge4_cyc[15:8]
                };
                tx_buf_keep[0] <= 8'hFF;
                tx_buf_keep[1] <= 8'hFF;
                tx_buf_keep[2] <= 8'hFF;
                tx_buf_keep[3] <= 8'hFF;
                tx_buf_keep[4] <= 8'hFF;
                tx_buf_keep[5] <= 8'hFF;
                tx_buf_keep[6] <= 8'h07;
                tx_length     <= 16'd50;
                tx_word_total <= 6'd7;
            end
            GET_ID_DECODE_BLOCK_CRC: begin
                // Match DECODE_CRC byte order: after PayloadHeader, GetRspHeader is
                // status, id(LE), vtype, vlen(LE), then value LE.
                // value (14 B): block_index, crc32, word_count, done, lane
                tx_buf[0] <= {
                    GET_ID_DECODE_BLOCK_CRC[15:8], GET_ID_DECODE_BLOCK_CRC[7:0], GST_OK,
                    8'h00, 8'h14,
                    pkt_seq[15:8], pkt_seq[7:0], CMD_GET_RSP
                };
                tx_buf[1] <= {
                    last_block_crc32[7:0],
                    last_block_index[31:24], last_block_index[23:16],
                    last_block_index[15:8], last_block_index[7:0],
                    8'h00, 8'h0E, 8'h20
                };
                tx_buf[2] <= {
                    {7'd0, last_block_valid},
                    last_block_words[31:24], last_block_words[23:16],
                    last_block_words[15:8], last_block_words[7:0],
                    last_block_crc32[31:24], last_block_crc32[23:16],
                    last_block_crc32[15:8]
                };
                tx_buf[3] <= {
                    56'd0,
                    last_block_lane
                };
                tx_buf_keep[0] <= 8'hFF;
                tx_buf_keep[1] <= 8'hFF;
                tx_buf_keep[2] <= 8'hFF;
                tx_buf_keep[3] <= 8'h01;
                tx_length     <= 16'd25;
                tx_word_total <= 6'd4;
            end
            GET_ID_STATUS_GROUP: begin
                tx_buf[0] <= {
                    GET_ID_STATUS_GROUP[15:8], GET_ID_STATUS_GROUP[7:0], GST_OK,
                    8'h00, 8'h26,
                    pkt_seq[15:8], pkt_seq[7:0], CMD_GET_RSP
                };
                tx_buf[1] <= 64'h0000000000002020;
                tx_buf[2] <= 64'h0;
                tx_buf[3] <= 64'h0;
                tx_buf[4] <= 64'h0;
                tx_buf[5] <= 64'h0;
                tx_buf_keep[0] <= 8'hFF;
                tx_buf_keep[1] <= 8'hFF;
                tx_buf_keep[2] <= 8'hFF;
                tx_buf_keep[3] <= 8'hFF;
                tx_buf_keep[4] <= 8'hFF;
                tx_buf_keep[5] <= 8'h07;
                tx_length     <= 16'd43;
                tx_word_total <= 6'd6;
            end
            GET_ID_ACTIVITY_WDT: begin
                // Total MAC payload 23 B: PH(5) + GetRspHeader(6) + body(12).
                // Body: three u32 LE — timeout_count (mon_wdt_timeout), wdt_counter, P_WDT_TIMEOUT_TICKS.
                // Per-word LE byte order [7:0] first (same as DECODE_CRC / FORMATS).
                tx_buf[0] <= {
                    GET_ID_ACTIVITY_WDT[15:8], GET_ID_ACTIVITY_WDT[7:0], GST_OK,
                    8'h00, 8'h0C,
                    pkt_seq[15:8], pkt_seq[7:0], CMD_GET_RSP
                };
                // Word1 bytes 8..15: GetRspHeader vtype+vlen(LE=12), then body mon[31:0] LE, wdt_cnt[7:0]
                tx_buf[1] <= {
                    wdt_cnt[7:0],
                    mon_wdt_timeout[31:24], mon_wdt_timeout[23:16],
                    mon_wdt_timeout[15:8], mon_wdt_timeout[7:0],
                    8'h00, 8'h0C, VT_U32
                };
                // Word2 bytes 16..22: wdt_cnt[31:8] + P_WDT_TIMEOUT_TICKS[31:0] LE (4 bytes), MSB padding
                tx_buf[2] <= {
                    8'h00,
                    P_WDT_TIMEOUT_TICKS[31:24], P_WDT_TIMEOUT_TICKS[23:16],
                    P_WDT_TIMEOUT_TICKS[15:8], P_WDT_TIMEOUT_TICKS[7:0],
                    wdt_cnt[31:24], wdt_cnt[23:16], wdt_cnt[15:8]
                };
                tx_buf_keep[0] <= 8'hFF;
                tx_buf_keep[1] <= 8'hFF;
                tx_buf_keep[2] <= 8'h7F;
                tx_length     <= 16'd23;
                tx_word_total <= 6'd3;
            end
            GET_ID_DECODE_CRC: begin
                // Byte layout (44 bytes total):
                //  [0..4]   PayloadHeader: cmd, seq(LE), len(LE)
                //  [5..10]  GetRspHeader: status, id(LE), vtype=0x20, vlen(LE)
                //  [11..14] crc32 (LE)
                //  [15..18] word_count (LE)
                //  [19]     done
                //  [20..23] decode_status (LE)
                //  [24..27] diag_crc[0] (LE) -- word 0
                //  [28..31] diag_crc[1] (LE) -- word 1
                //  [32..35] diag_crc[2] (LE) -- word 9
                //  [36..39] diag_crc[3] (LE) -- word 127
                //  [40..43] diag_crc[4] (LE) -- word 128
                //  [44..47] diag_crc[5] (LE) -- total-128 (tail, one line back)
                //  [48..51] diag_crc[6] (LE) -- total-256 (tail, two lines back)
                // body = 47 (0x2F), vlen = 41 (0x29), tx_length = 5+47 = 52
                // bytes 0-7
                tx_buf[0] <= {
                    GET_ID_DECODE_CRC[15:8], GET_ID_DECODE_CRC[7:0], GST_OK,
                    8'h00, 8'h2F,
                    pkt_seq[15:8], pkt_seq[7:0], CMD_GET_RSP
                };
                // bytes 8-15
                tx_buf[1] <= {
                    decode_crc32_wcnt[7:0],
                    decode_crc32[31:24], decode_crc32[23:16],
                    decode_crc32[15:8], decode_crc32[7:0],
                    8'h00, 8'h29, 8'h20
                };
                // bytes 16-23
                tx_buf[2] <= {
                    decode_status[31:24], decode_status[23:16],
                    decode_status[15:8], decode_status[7:0],
                    {7'd0, decode_crc32_done},
                    decode_crc32_wcnt[31:24], decode_crc32_wcnt[23:16],
                    decode_crc32_wcnt[15:8]
                };
                // bytes 24-31: diag_crc[0] + diag_crc[1]
                tx_buf[3] <= {
                    diag_crc_1[31:24], diag_crc_1[23:16],
                    diag_crc_1[15:8],  diag_crc_1[7:0],
                    diag_crc_0[31:24], diag_crc_0[23:16],
                    diag_crc_0[15:8],  diag_crc_0[7:0]
                };
                // bytes 32-39: diag_crc[2] + diag_crc[3]
                tx_buf[4] <= {
                    diag_crc_3[31:24], diag_crc_3[23:16],
                    diag_crc_3[15:8],  diag_crc_3[7:0],
                    diag_crc_2[31:24], diag_crc_2[23:16],
                    diag_crc_2[15:8],  diag_crc_2[7:0]
                };
                // bytes 40-47: diag_crc[4] + diag_crc[5]
                tx_buf[5] <= {
                    diag_crc_5[31:24], diag_crc_5[23:16],
                    diag_crc_5[15:8],  diag_crc_5[7:0],
                    diag_crc_4[31:24], diag_crc_4[23:16],
                    diag_crc_4[15:8],  diag_crc_4[7:0]
                };
                // bytes 48-51: diag_crc[6] + padding
                tx_buf[6] <= {
                    32'd0,
                    diag_crc_6[31:24], diag_crc_6[23:16],
                    diag_crc_6[15:8],  diag_crc_6[7:0]
                };
                tx_buf_keep[0] <= 8'hFF;
                tx_buf_keep[1] <= 8'hFF;
                tx_buf_keep[2] <= 8'hFF;
                tx_buf_keep[3] <= 8'hFF;
                tx_buf_keep[4] <= 8'hFF;
                tx_buf_keep[5] <= 8'hFF;
                tx_buf_keep[6] <= 8'h0F;
                tx_length     <= 16'd52;
                tx_word_total <= 6'd7;
            end
            GET_ID_ALL: begin
                tx_buf[0] <= {
                    GET_ID_ALL[15:8], GET_ID_ALL[7:0], GST_OK,
                    8'h00, 8'h65,
                    pkt_seq[15:8], pkt_seq[7:0], CMD_GET_RSP
                };
                tx_buf[1]  <= 64'h0008040101005ff0;
                tx_buf[2]  <= 64'h0002000000010000;
                tx_buf[3]  <= 64'h0000100004030102;
                tx_buf[4]  <= 64'h0a00000611010300;
                tx_buf[5]  <= 64'h0403010402010035;
                tx_buf[6]  <= 64'h0302010000000200;
                tx_buf[7]  <= 64'h0301002000040004;
                tx_buf[8]  <= 64'h2004000040000202;
                tx_buf[9]  <= 64'h0000000000000020;
                tx_buf[10] <= 64'h0;
                tx_buf[11] <= 64'h0;
                tx_buf[12] <= 64'h0;
                tx_buf[13] <= 64'h0;
                tx_buf_keep[0]  <= 8'hFF;
                tx_buf_keep[1]  <= 8'hFF;
                tx_buf_keep[2]  <= 8'hFF;
                tx_buf_keep[3]  <= 8'hFF;
                tx_buf_keep[4]  <= 8'hFF;
                tx_buf_keep[5]  <= 8'hFF;
                tx_buf_keep[6]  <= 8'hFF;
                tx_buf_keep[7]  <= 8'hFF;
                tx_buf_keep[8]  <= 8'hFF;
                tx_buf_keep[9]  <= 8'hFF;
                tx_buf_keep[10] <= 8'hFF;
                tx_buf_keep[11] <= 8'hFF;
                tx_buf_keep[12] <= 8'hFF;
                tx_buf_keep[13] <= 8'h03;
                tx_length     <= 16'd106;
                tx_word_total <= 6'd14;
            end
            default: begin
                tx_buf[0] <= {
                    8'h00, 8'h00, GST_NOT_FOUND,
                    8'h00, 8'h06,
                    pkt_seq[15:8], pkt_seq[7:0], CMD_GET_RSP
                };
                tx_buf[1] <= 64'h0;
                tx_buf_keep[0] <= 8'hFF;
                tx_buf_keep[1] <= 8'h07;
                tx_length     <= 16'd11;
                tx_word_total <= 6'd2;
            end
            endcase
            tx_word_idx <= 0;
            state       <= S_GET_TX;
        end

        S_GET_TX: begin
            tx_request    <= 1;
            state         <= S_GET_ACK;
        end

        S_GET_ACK: begin
            if (tx_ack) begin
                tx_request <= 0;
                state      <= S_GET_SEND;
            end
        end

        S_GET_SEND: begin
            tx_valid <= 1;
            tx_data  <= tx_buf[tx_word_idx];
            tx_keep  <= tx_buf_keep[tx_word_idx];
            if (tx_word_idx + 1 >= tx_word_total) begin
                tx_last <= 1;
                state   <= S_TX_DONE;
            end else begin
                tx_last <= 0;
            end
            tx_word_idx <= tx_word_idx + 1;
        end

        // ==========================================================
        // TX done
        // ==========================================================
        S_TX_DONE: begin
            tx_valid     <= 0;
            tx_last      <= 0;
            tx_mode_echo <= 1'b0;
            state        <= S_RX_IDLE;
        end

        default: state <= S_RX_IDLE;
        endcase

        // ==========================================================
        // Multi-block auto-restart: detect block_done rising edge
        // and update config for the next block in the strip.
        // Disabled in parallel_mode (STREAM_BLOCK_START drives indices).
        // ==========================================================
        block_done_prev_a <= block_done;
        if (!parallel_mode && block_done && !block_done_prev_a && stream_active && remaining_height > cfg_block_height) begin
            remaining_height <= remaining_height - cfg_block_height;
            cfg_block_index  <= cfg_block_index + 32'd1;
            if (remaining_height - cfg_block_height > default_block_height)
                cfg_block_height <= default_block_height;
            else
                cfg_block_height <= remaining_height - cfg_block_height;
            cfg_block_index_bus[31:0]  <= cfg_block_index + 32'd1;
            cfg_block_height_bus[31:0] <= (remaining_height - cfg_block_height > default_block_height)
                                          ? default_block_height
                                          : (remaining_height - cfg_block_height);
            lane_cfg_toggle_bus[0]     <= 1'b1;
        end else if (!parallel_mode && block_done && !block_done_prev_a && stream_active && remaining_height <= cfg_block_height) begin
            remaining_height <= 32'd0;
        end
    end
end

endmodule
