// ============================================================================
// RLE4K LAN Top Module v8 -- Raw MAC Protocol (no UDP/IP stack)
// ============================================================================
// Uses master_wrapper_v8 (raw MAC) + rle4k_stream_adapter_v8 (same as V07).
// Identical clock/CDC/decoder structure as V07.
// ============================================================================

`timescale 1ns / 1ps

module rle4k_lan_top (
    input  wire        sysclk_p,
    input  wire        sysclk_n,
    output wire        phy_rst_o,

    // RGMII PHY A
    input  wire [3:0]  PHYA_rgmii_rxd,
    input  wire        PHYA_rgmii_rx_ctl,
    input  wire        PHYA_rgmii_rxc,
    output wire [3:0]  PHYA_rgmii_txd,
    output wire        PHYA_rgmii_tx_ctl,
    output wire        PHYA_rgmii_txc,

    // Debug LEDs
    output wire [3:0]  led
);

// ============================================================================
// Clock generation
// ============================================================================
wire clk_15_625, clk_333_33, clk_125, clk_25;
wire locked;
(* keep = "true" *) wire clk_125_n = ~clk_125;
(* keep = "true" *) wire clk_15_625_n = ~clk_15_625;

clk_wiz_0 u_clk_wiz (
    .clk_in1_p (sysclk_p),
    .clk_in1_n (sysclk_n),
    .clk_out1  (clk_15_625),
    .clk_out2  (clk_333_33),
    .clk_out3  (clk_125),
    .clk_out4  (clk_25),
    .locked    (locked)
);

// ============================================================================
// PHY reset
// ============================================================================
// Previously a counter to 100 on clk_25, i.e. reset asserted for 4 us. Gigabit
// PHYs specify a millisecond-range minimum and sample their configuration
// straps on the release edge, so that pulse was about three orders of magnitude
// too short. rle4k_phy_reset holds it for 20 ms; see tb/tb_phy_reset.v.
wire phy_rst_n_auto;

// Held at the original 100 cycles (4 us) for now. Lengthening it is a real
// improvement, but it was introduced in the same rebuild that made the board go
// silent on transmit, and the recovered 2026-04-27 design that works uses 100 --
// so it stays matched to the working design until the transmit regression is
// isolated, then gets raised on its own.
rle4k_phy_reset #(
    .ASSERT_CYCLES (20'd100)
) u_phy_reset (
    .clk       (clk_25),
    .enable    (locked),
    .phy_rst_n (phy_rst_n_auto)
);

// Runtime override so the PHY can be re-reset from the host without rebuilding.
// vio_phy_rst_force drives RESET_N low for as long as it is held; releasing it
// re-runs the strap latch. Driven from master_wrapper's VIO, defaults to 0.
wire vio_phy_rst_force;
assign phy_rst_o = phy_rst_n_auto & ~vio_phy_rst_force;

// ============================================================================
// MAC Wrapper v8 (Raw Ethernet, no UDP)
// ============================================================================
localparam integer NUM_LANES = 1;

wire        core_reset;
wire        udp_tx_ready, app_tx_ack;
wire        app_rx_data_valid, app_rx_data_last, app_rx_ready;
wire [NUM_LANES-1:0]    cdc_almost_full_bus;
wire [NUM_LANES-1:0]    cdc_full_bus;
wire [NUM_LANES-1:0]    stg_pause_bus;
wire                    adapter_rx_congested;
// Early PAUSE: staging watermark / any-lane CDC AF / adapter ASSIGN·FEED·K-1 busy
wire                    app_rx_congested =
    adapter_rx_congested | (|stg_pause_bus) | (|cdc_almost_full_bus);
wire [63:0] app_rx_data;
wire [7:0]  app_rx_data_keep;
wire [15:0] app_rx_data_length;

wire        app_tx_request;
wire        app_tx_data_valid;
wire [63:0] app_tx_data;
wire [7:0]  app_tx_data_keep;
wire        app_tx_data_last;
wire [15:0] app_tx_data_length;

master_wrapper_v8 #(
    .LOCAL_MAC_ADDRESS (48'h000A35000102)
) u_master_wrapper (
    .reset             (1'b0),
    .dcm_locked        (locked),
    .refclk            (clk_333_33),
    .udp_core_clk      (clk_15_625),
    .gtx_clk           (clk_125),
    .core_reset        (core_reset),
    .phy_rst_force     (vio_phy_rst_force),

    .udp_tx_ready      (udp_tx_ready),
    .app_tx_ack        (app_tx_ack),
    .app_tx_request    (app_tx_request),
    .app_tx_data_valid (app_tx_data_valid),
    .app_tx_data       (app_tx_data),
    .app_tx_data_keep  (app_tx_data_keep),
    .app_tx_data_last  (app_tx_data_last),
    .app_tx_data_length(app_tx_data_length),

    .app_rx_data_valid (app_rx_data_valid),
    .app_rx_data       (app_rx_data),
    .app_rx_data_keep  (app_rx_data_keep),
    .app_rx_data_last  (app_rx_data_last),
    .app_rx_data_length(app_rx_data_length),
    .app_rx_ready      (app_rx_ready),
    .app_rx_congested  (app_rx_congested),

    .rgmii_rxd         (PHYA_rgmii_rxd),
    .rgmii_rx_ctl      (PHYA_rgmii_rx_ctl),
    .rgmii_rxc         (PHYA_rgmii_rxc),
    .rgmii_txd         (PHYA_rgmii_txd),
    .rgmii_tx_ctl      (PHYA_rgmii_tx_ctl),
    .rgmii_txc         (PHYA_rgmii_txc)
);

// ============================================================================
// Stream Adapter v8 + K=4 parallel decode bank (Phase A: discard + per-block CRC)
// ============================================================================
wire [31:0] dec_data_mac;
wire        dec_valid_mac;
wire        dec_stream_end_mac;
wire [1:0]  active_lane_mac;
wire        parallel_mode_mac;
wire        soft_rst;

wire [31:0] cfg_block_index;
wire [31:0] cfg_line_width;
wire [31:0] cfg_line_stride;
wire [31:0] cfg_block_height;
wire [31:0] cfg_strip_line_count_mac;
wire [31:0] cfg_rle_payload_bytes_mac;
wire        strip_cfg_toggle_mac;
wire [32*NUM_LANES-1:0] cfg_block_index_bus;
wire [32*NUM_LANES-1:0] cfg_block_height_bus;
wire [32*NUM_LANES-1:0] cfg_strip_line_count_bus;
wire [32*NUM_LANES-1:0] cfg_rle_payload_bytes_bus;
wire [NUM_LANES-1:0]    lane_cfg_toggle_bus;

wire [32*NUM_LANES-1:0] decode_status_bus;
wire [NUM_LANES-1:0]    block_done_bus;

wire        ring_accept_valid;
wire [31:0] ring_accept_block_index;
wire        ring_accept_ready;
wire        ring_retx_pending;
wire [31:0] ring_retx_count;
wire [31:0] ring_complete_bitmap;
wire [31:0] ring_window_base;
wire [31:0] ring_last_byte_addr;
wire [31:0] ring_blocks_completed;
wire [31:0] last_block_index_dec;
wire [31:0] last_block_crc32_dec;
wire [31:0] last_block_words_dec;
wire [7:0]  last_block_lane_dec;
wire        last_block_valid_dec;
wire        crc_rd_en_mac;
wire [11:0] crc_rd_index_mac;
wire [31:0] crc_rd_crc32_mac;
wire [31:0] crc_rd_words_mac;
wire        crc_rd_done_mac;
wire [7:0]  crc_rd_lane_mac;

reg [31:0] decode_status_sync1, decode_status_sync2;
reg        block_done_sync1, block_done_sync2;
reg [NUM_LANES-1:0] block_done_bus_s1, block_done_bus_s2;

// last_block_* CDC: 125 MHz -> 15.625 MHz
reg [31:0] lb_idx_s1, lb_idx_s2;
reg [31:0] lb_crc_s1, lb_crc_s2;
reg [31:0] lb_w_s1, lb_w_s2;
reg [7:0]  lb_lane_s1, lb_lane_s2;
reg        lb_v_s1, lb_v_s2;

wire block_done_any = |block_done_bus_s2;
wire [31:0] decode_status_or = decode_status_bus[31:0];

always @(posedge clk_15_625) begin
    decode_status_sync1 <= decode_status_or;
    decode_status_sync2 <= decode_status_sync1;
    block_done_sync1    <= block_done_any;
    block_done_sync2    <= block_done_sync1;
    block_done_bus_s1   <= block_done_bus;
    block_done_bus_s2   <= block_done_bus_s1;
    lb_idx_s1  <= last_block_index_dec;  lb_idx_s2  <= lb_idx_s1;
    lb_crc_s1  <= last_block_crc32_dec;  lb_crc_s2  <= lb_crc_s1;
    lb_w_s1    <= last_block_words_dec;  lb_w_s2    <= lb_w_s1;
    lb_lane_s1 <= last_block_lane_dec;   lb_lane_s2 <= lb_lane_s1;
    lb_v_s1    <= last_block_valid_dec;  lb_v_s2    <= lb_v_s1;
end

wire [31:0] last_block_index = lb_idx_s2;
wire [31:0] last_block_crc32 = lb_crc_s2;
wire [31:0] last_block_words = lb_w_s2;
wire [7:0]  last_block_lane  = lb_lane_s2;
wire        last_block_valid = lb_v_s2;

// Active-lane CDC almost_full back to adapter
wire cdc_full_active = cdc_almost_full_bus[active_lane_mac];

// Per-block CRC presented as legacy DECODE_CRC for smoke
wire [31:0] crc32_lat_s2  = last_block_crc32;
wire [31:0] crc32_wcnt_s2 = last_block_words;
wire        crc32_done_s2 = last_block_valid;
wire [31:0] dc_w0_s2 = 32'd0;
wire [31:0] dc_w1_s2 = 32'd0;
wire [31:0] dc_w9_s2 = 32'd0;
wire [31:0] dc_w127_s2 = 32'd0;
wire [31:0] dc_w128_s2 = 32'd0;
wire [31:0] dc_t128_s2 = 32'd0;
wire [31:0] dc_t256_s2 = 32'd0;

rle4k_stream_adapter_v8 #(
    .P_WDT_TIMEOUT_TICKS(32'd937_500_000),
    .P_NUM_LANES(NUM_LANES)
) u_adapter (
    .clk           (clk_15_625),
    .rst_n         (~core_reset),
    .rx_valid      (app_rx_data_valid),
    .rx_data       (app_rx_data),
    .rx_keep       (app_rx_data_keep),
    .rx_last       (app_rx_data_last),
    .rx_length     (app_rx_data_length),
    .rx_ready      (app_rx_ready),
    .rx_congested  (adapter_rx_congested),
    .tx_request    (app_tx_request),
    .tx_ack        (app_tx_ack),
    .tx_ready      (udp_tx_ready),
    .tx_valid      (app_tx_data_valid),
    .tx_data       (app_tx_data),
    .tx_keep       (app_tx_data_keep),
    .tx_last       (app_tx_data_last),
    .tx_length     (app_tx_data_length),
    .dec_data      (dec_data_mac),
    .dec_valid     (dec_valid_mac),
    .dec_stream_end(dec_stream_end_mac),
    .active_lane   (active_lane_mac),
    .parallel_mode (parallel_mode_mac),
    .cfg_block_index (cfg_block_index),
    .cfg_line_width  (cfg_line_width),
    .cfg_line_stride (cfg_line_stride),
    .cfg_block_height(cfg_block_height),
    .cfg_strip_line_count(cfg_strip_line_count_mac),
    .cfg_rle_payload_bytes(cfg_rle_payload_bytes_mac),
    .strip_cfg_toggle(strip_cfg_toggle_mac),
    .cfg_block_index_bus(cfg_block_index_bus),
    .cfg_block_height_bus(cfg_block_height_bus),
    .cfg_strip_line_count_bus(cfg_strip_line_count_bus),
    .cfg_rle_payload_bytes_bus(cfg_rle_payload_bytes_bus),
    .lane_cfg_toggle_bus(lane_cfg_toggle_bus),
    .decode_status (decode_status_sync2),
    .block_done    (block_done_sync2),
    .block_done_bus(block_done_bus_s2),
    .cdc_full      (cdc_full_active),
    .soft_rst      (soft_rst),
    .decode_crc32       (crc32_lat_s2),
    .decode_crc32_wcnt  (crc32_wcnt_s2),
    .decode_crc32_done  (crc32_done_s2),
    .diag_crc_0(dc_w0_s2), .diag_crc_1(dc_w1_s2), .diag_crc_2(dc_w9_s2),
    .diag_crc_3(dc_w127_s2), .diag_crc_4(dc_w128_s2),
    .diag_crc_5(dc_t128_s2), .diag_crc_6(dc_t256_s2),
    .ring_accept_valid(ring_accept_valid),
    .ring_accept_block_index(ring_accept_block_index),
    .ring_accept_ready(ring_accept_ready),
    .ring_retx_pending(ring_retx_pending),
    .ring_retx_count(ring_retx_count),
    .ring_complete_bitmap(ring_complete_bitmap),
    .ring_window_base(ring_window_base),
    .ring_last_byte_addr(ring_last_byte_addr),
    .ring_blocks_completed(ring_blocks_completed),
    .last_block_index(last_block_index),
    .last_block_crc32(last_block_crc32),
    .last_block_words(last_block_words),
    .last_block_lane(last_block_lane),
    .last_block_valid(last_block_valid),
    .crc_rd_en(crc_rd_en_mac),
    .crc_rd_index(crc_rd_index_mac),
    .crc_rd_crc32(crc_rd_crc32_mac),
    .crc_rd_words(crc_rd_words_mac),
    .crc_rd_done(crc_rd_done_mac),
    .crc_rd_lane(crc_rd_lane_mac),
    .dbg_cnt_bus(), .dbg_state_bus()
);

wire sys_rst_n = locked & ~soft_rst;

// Demux adapter feed onto K lane buses
reg  [32*NUM_LANES-1:0] dec_data_bus;
reg  [NUM_LANES-1:0]    dec_valid_bus;
reg  [NUM_LANES-1:0]    dec_stream_end_bus;
integer di;
always @(*) begin
    dec_data_bus = {32*NUM_LANES{1'b0}};
    dec_valid_bus = {NUM_LANES{1'b0}};
    dec_stream_end_bus = {NUM_LANES{1'b0}};
    for (di = 0; di < NUM_LANES; di = di + 1) begin
        if (active_lane_mac == di[1:0]) begin
            dec_data_bus[32*di +: 32] = dec_data_mac;
            dec_valid_bus[di]         = dec_valid_mac;
            dec_stream_end_bus[di]    = dec_stream_end_mac;
        end
    end
end

// strip_clear: pulse on STREAM_START (strip_cfg_toggle edge) or soft_rst
reg strip_t_d;
always @(posedge clk_15_625) begin
    if (core_reset) strip_t_d <= 1'b0;
    else            strip_t_d <= strip_cfg_toggle_mac;
end
wire strip_clear_pulse = soft_rst | (strip_cfg_toggle_mac ^ strip_t_d);

rle4k_parallel_bank_v8 #(
    .P_NUM_LANES(NUM_LANES),
    .P_W(32),
    .P_BASE(32'h20000000),
    .P_BLOCK_BYTES(32'd4194304)
) u_bank (
    .clk_mac(clk_15_625),
    .clk_dec(clk_125),
    .rst(core_reset | soft_rst),
    .sys_rst_n(sys_rst_n),
    .strip_clear(strip_clear_pulse),
    .dec_data_bus(dec_data_bus),
    .dec_valid_bus(dec_valid_bus),
    .cdc_almost_full_bus(cdc_almost_full_bus),
    .cdc_full_bus(cdc_full_bus),
    .stg_pause_bus(stg_pause_bus),
    .dec_stream_end_bus(dec_stream_end_bus),
    .cfg_line_width(cfg_line_width),
    .cfg_line_stride(cfg_line_stride),
    .cfg_block_index_bus(cfg_block_index_bus),
    .cfg_block_height_bus(cfg_block_height_bus),
    .cfg_strip_line_count_bus(cfg_strip_line_count_bus),
    .cfg_rle_payload_bytes_bus(cfg_rle_payload_bytes_bus),
    .lane_cfg_toggle_bus(lane_cfg_toggle_bus),
    .decode_status_bus(decode_status_bus),
    .block_done_bus(block_done_bus),
    .accept_valid(ring_accept_valid),
    .accept_block_index(ring_accept_block_index),
    .accept_ready(ring_accept_ready),
    .retx_pending(ring_retx_pending),
    .retx_count(ring_retx_count),
    .complete_bitmap(ring_complete_bitmap),
    .window_base_index(ring_window_base),
    .last_byte_addr(ring_last_byte_addr),
    .blocks_completed_win(ring_blocks_completed),
    .ring_slot(),
    .ring_byte_addr(),
    .crc_rd_en(crc_rd_en_mac),
    .crc_rd_index(crc_rd_index_mac),
    .crc_rd_crc32(crc_rd_crc32_mac),
    .crc_rd_words(crc_rd_words_mac),
    .crc_rd_done(crc_rd_done_mac),
    .crc_rd_lane(crc_rd_lane_mac),
    .last_block_index(last_block_index_dec),
    .last_block_crc32(last_block_crc32_dec),
    .last_block_words(last_block_words_dec),
    .last_block_lane(last_block_lane_dec),
    .last_block_valid(last_block_valid_dec)
);

wire word_decoded_valid = 1'b0; // observation only; Phase A discards
wire block_done_raw = block_done_any;

reg [24:0] heartbeat;
always @(posedge clk_125) heartbeat <= heartbeat + 1'b1;
assign led[0] = heartbeat[24];
assign led[1] = ~core_reset;
assign led[2] = |block_done_bus; // any lane activity proxy
assign led[3] = block_done_raw;

endmodule