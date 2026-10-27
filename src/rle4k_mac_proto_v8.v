// ============================================================================
// RLE4K MAC Protocol v0.8 -- Raw Ethernet frame parser/builder
// ============================================================================
// Replaces uiudp_stack inside master_wrapper. MAC layer only.
// Filters by EtherType 0x4B52 and destination MAC. Strips 14-byte Ethernet
// header on RX, prepends it on TX.
//
// Data format: 64-bit little-endian AXI-Stream words.
//   Frame byte 0  -> word0[7:0],  byte 7 -> word0[63:56]
//   Frame byte 14 -> word1[47:40] (first payload byte)
//
// RX: buffer-then-replay to avoid complex barrel shift.
// TX: 6-byte barrel shift using residue register.
// ============================================================================

`timescale 1ns / 1ps

module rle4k_mac_proto_v8 #(
    parameter [47:0] LOCAL_MAC = 48'h000A35000102
)(
    input  wire        clk,
    input  wire        rst,

    // --- MAC RX (64-bit AXI-Stream from rx CDC FIFO) ---
    input  wire        mac_rx_data_valid,
    input  wire [63:0] mac_rx_data,
    input  wire [7:0]  mac_rx_keep,
    input  wire        mac_rx_last,
    output wire        mac_rx_ready,

    // --- MAC TX (64-bit AXI-Stream to tx CDC FIFO) ---
    output reg         mac_tx_data_valid,
    output reg  [63:0] mac_tx_data,
    output reg  [7:0]  mac_tx_keep,
    input  wire        mac_tx_ready,
    output reg         mac_tx_last,
    output wire        mac_tx_user,

    // --- APP RX (to adapter) ---
    output reg         app_rx_data_valid,
    output reg  [63:0] app_rx_data,
    output reg  [7:0]  app_rx_data_keep,
    output reg         app_rx_data_last,
    output reg  [15:0] app_rx_data_length,
    input  wire        app_rx_ready,

    // --- APP TX (from adapter) ---
    output wire        app_tx_ready,
    output wire        app_tx_ack,
    input  wire        app_tx_request,
    input  wire        app_tx_data_valid,
    input  wire [63:0] app_tx_data,
    input  wire [7:0]  app_tx_data_keep,
    input  wire        app_tx_data_last,
    input  wire [15:0] app_tx_data_length
);

assign mac_tx_user  = 1'b0;

localparam [15:0] ETHERTYPE_RLE4K = 16'h4B52;

// ============================================================================
// RX: Buffer entire frame, verify header, replay payload
// ============================================================================
// Max frame = 1518 bytes = 190 words. Use 192.
localparam RX_BUF_DEPTH = 192;

reg [63:0] rx_buf  [0:RX_BUF_DEPTH-1];
reg [7:0]  rx_kbuf [0:RX_BUF_DEPTH-1];
reg [7:0]  rx_wcnt;
reg [15:0] rx_frame_bytes;

localparam [1:0] RXS_CAPTURE = 2'd0,
                 RXS_CHECK   = 2'd1,
                 RXS_REPLAY  = 2'd2;

reg [1:0]  rx_state;
reg [7:0]  rx_rd_idx;
reg [15:0] rx_payload_bytes;
reg [47:0] last_src_mac;

// Back-pressure towards the RX FIFO. Words are only consumed in RXS_CAPTURE;
// during RXS_CHECK and RXS_REPLAY this module has nowhere to put them, so it
// must tell the FIFO to hold rather than let it pop into the void. Without
// this the FIFO free-runs and every frame that arrives while a previous one is
// being checked or replayed is silently lost -- which on the board showed up as
// the FPGA answering only 5 of 14 requests in a single ping run.
// The adapter can only take replayed words while it sits in its receive states,
// so the replay has to be a real handshake too. Holding valid and the payload
// until the sink accepts is plain AXI-Stream behaviour.
wire rx_out_stall = app_rx_data_valid && !app_rx_ready;

assign mac_rx_ready = (rx_state == RXS_CAPTURE) && !rx_out_stall;

// Count valid bytes from keep mask
function [3:0] popcount8;
    input [7:0] k;
    begin
        popcount8 = k[0]+k[1]+k[2]+k[3]+k[4]+k[5]+k[6]+k[7];
    end
endfunction

always @(posedge clk) begin
    if (rst) begin
        rx_state           <= RXS_CAPTURE;
        rx_wcnt            <= 8'd0;
        rx_frame_bytes     <= 16'd0;
        app_rx_data_valid  <= 1'b0;
        app_rx_data_last   <= 1'b0;
        app_rx_data        <= 64'd0;
        app_rx_data_keep   <= 8'd0;
        app_rx_data_length <= 16'd0;
        rx_rd_idx          <= 8'd0;
        rx_payload_bytes   <= 16'd0;
        last_src_mac       <= 48'hFFFFFFFFFFFF;
    end else if (rx_out_stall) begin
        // Sink is not ready: freeze the output word and the read pointer.
    end else begin
        app_rx_data_valid <= 1'b0;
        app_rx_data_last  <= 1'b0;

        case (rx_state)

        // ----- Capture incoming frame into buffer -----
        RXS_CAPTURE: begin
            if (mac_rx_data_valid) begin
                if (rx_wcnt < RX_BUF_DEPTH[7:0]) begin
                    rx_buf[rx_wcnt]  <= mac_rx_data;
                    rx_kbuf[rx_wcnt] <= mac_rx_keep;
                end
                if (mac_rx_last) begin
                    rx_frame_bytes <= {5'd0, rx_wcnt, 3'd0} +
                                     {12'd0, popcount8(mac_rx_keep)};
                    rx_wcnt  <= rx_wcnt + 8'd1;
                    rx_state <= RXS_CHECK;
                end else begin
                    rx_wcnt <= rx_wcnt + 8'd1;
                end
            end
        end

        // ----- Verify Ethernet header -----
        RXS_CHECK: begin
            begin : check_hdr
                // DA = frame bytes 0-5 = buf[0][47:0]
                // SA = frame bytes 6-11 = {buf[1][31:0], buf[0][63:48]}
                // ET = frame bytes 12-13 = {buf[1][39:32], buf[1][47:40]} big-endian
                reg da_ok, et_ok;
                reg [47:0] sa;
                reg [15:0] et;

                et = {rx_buf[1][39:32], rx_buf[1][47:40]};
                et_ok = (et == ETHERTYPE_RLE4K);

                // DA match: each byte vs LOCAL_MAC or 0xFF
                // LOCAL_MAC[47:40]=byte0, [39:32]=byte1, ..., [7:0]=byte5
                // buf[0][7:0]=frame byte0, [15:8]=frame byte1, etc.
                da_ok = ((rx_buf[0][7:0]   == LOCAL_MAC[47:40]) || (rx_buf[0][7:0]   == 8'hFF)) &&
                        ((rx_buf[0][15:8]  == LOCAL_MAC[39:32]) || (rx_buf[0][15:8]  == 8'hFF)) &&
                        ((rx_buf[0][23:16] == LOCAL_MAC[31:24]) || (rx_buf[0][23:16] == 8'hFF)) &&
                        ((rx_buf[0][31:24] == LOCAL_MAC[23:16]) || (rx_buf[0][31:24] == 8'hFF)) &&
                        ((rx_buf[0][39:32] == LOCAL_MAC[15:8])  || (rx_buf[0][39:32] == 8'hFF)) &&
                        ((rx_buf[0][47:40] == LOCAL_MAC[7:0])   || (rx_buf[0][47:40] == 8'hFF));

                if (rx_frame_bytes < 16'd15 || !da_ok || !et_ok) begin
                    // Drop frame
                    rx_wcnt  <= 8'd0;
                    rx_state <= RXS_CAPTURE;
                end else begin
                    sa = {rx_buf[1][31:0], rx_buf[0][63:48]};
                    last_src_mac       <= sa;
                    rx_payload_bytes   <= rx_frame_bytes - 16'd14;
                    app_rx_data_length <= rx_frame_bytes - 16'd14;
                    rx_rd_idx          <= 8'd0;
                    rx_state           <= RXS_REPLAY;
                end
            end
        end

        // ----- Replay payload (6-byte realigned) -----
        // Payload byte 0 is at frame byte 14 = buf[1] bit 48.
        // Output word N = {buf[N+2][47:0], buf[N+1][63:48]}
        RXS_REPLAY: begin
            begin : replay_blk
                reg [63:0] lo_w, hi_w;
                reg [15:0] remaining;
                reg [7:0]  ok;

                lo_w = (rx_rd_idx + 8'd1 < rx_wcnt) ? rx_buf[rx_rd_idx + 8'd1] : 64'd0;
                hi_w = (rx_rd_idx + 8'd2 < rx_wcnt) ? rx_buf[rx_rd_idx + 8'd2] : 64'd0;

                app_rx_data <= {hi_w[47:0], lo_w[63:48]};

                remaining = rx_payload_bytes - {5'd0, rx_rd_idx, 3'd0};

                if (remaining <= 16'd8) begin
                    case (remaining)
                        16'd1:   ok = 8'h01;
                        16'd2:   ok = 8'h03;
                        16'd3:   ok = 8'h07;
                        16'd4:   ok = 8'h0F;
                        16'd5:   ok = 8'h1F;
                        16'd6:   ok = 8'h3F;
                        16'd7:   ok = 8'h7F;
                        default: ok = 8'hFF;
                    endcase
                    app_rx_data_valid <= (remaining > 16'd0);
                    app_rx_data_keep  <= ok;
                    app_rx_data_last  <= 1'b1;
                    rx_wcnt           <= 8'd0;
                    rx_state          <= RXS_CAPTURE;
                end else begin
                    app_rx_data_valid <= 1'b1;
                    app_rx_data_keep  <= 8'hFF;
                    app_rx_data_last  <= 1'b0;
                    rx_rd_idx         <= rx_rd_idx + 8'd1;
                end
            end
        end

        default: begin
            rx_wcnt  <= 8'd0;
            rx_state <= RXS_CAPTURE;
        end
        endcase
    end
end

// ============================================================================
// TX: Prepend 14-byte Ethernet header (6-byte forward shift)
// ============================================================================
// The adapter asserts app_tx_data_valid on the SAME clock edge it sees
// app_tx_ack, and may deassert it the very next cycle. To avoid losing
// that first (and possibly only) data word, we capture it into a
// registered buffer (tx_cap_*) during TXS_ACK.
//
// Header word 0: DA[0..5] + SA[0..1]  (frame bytes 0-7)
// Header word 1: SA[2..5] + ET[0..1] + payload[0..1] (frame bytes 8-15)
// Subsequent:    {new_payload[15:0], prev_residue[47:0]}

localparam [2:0] TXS_IDLE = 3'd0,
                 TXS_ACK  = 3'd1,
                 TXS_HDR0 = 3'd2,
                 TXS_HDR1 = 3'd3,
                 TXS_DATA = 3'd4,
                 TXS_TAIL = 3'd5;

reg [2:0]  tx_state;
reg [47:0] tx_residue;
reg [47:0] tx_dst_mac;

// Captured first TX word from adapter
reg [63:0] tx_cap_data;
reg [7:0]  tx_cap_keep;
reg        tx_cap_last;
reg        tx_cap_valid;
reg [7:0]  tx_tail_keep;

assign app_tx_ack = (tx_state == TXS_ACK);

// mac_tx_ready used to be declared and then ignored, so every word the FSM
// produced while the downstream FIFO was full went straight on the floor -- the
// full-speed gate measured 12 lost words on a single held ping. Stalling the
// whole FSM on a rejected beat is what makes this a real AXI-Stream source.
// app_tx_ready propagates the same stall to the adapter, which has no other way
// of knowing it must stop producing.
wire tx_stall = mac_tx_data_valid && !mac_tx_ready;

assign app_tx_ready = !tx_stall;

wire [47:0] hdr_w1_lo = {ETHERTYPE_RLE4K[7:0], ETHERTYPE_RLE4K[15:8],
                         LOCAL_MAC[7:0],  LOCAL_MAC[15:8],
                         LOCAL_MAC[23:16], LOCAL_MAC[31:24]};

always @(posedge clk) begin
    if (rst) begin
        tx_state          <= TXS_IDLE;
        mac_tx_data_valid <= 1'b0;
        mac_tx_data       <= 64'd0;
        mac_tx_keep       <= 8'hFF;
        mac_tx_last       <= 1'b0;
        tx_residue        <= 48'd0;
        tx_dst_mac        <= 48'hFFFFFFFFFFFF;
        tx_cap_data       <= 64'd0;
        tx_cap_keep       <= 8'd0;
        tx_cap_last       <= 1'b0;
        tx_cap_valid      <= 1'b0;
        tx_tail_keep      <= 8'h3F;
    end else if (tx_stall) begin
        // Sink rejected the current beat: hold valid, payload and state.
    end else begin
        mac_tx_data_valid <= 1'b0;
        mac_tx_last       <= 1'b0;

        case (tx_state)

        TXS_IDLE: begin
            if (app_tx_request) begin
                tx_dst_mac <= last_src_mac;
                tx_state   <= TXS_ACK;
            end
        end

        // ACK cycle: adapter sees tx_ack and drives tx_valid + data.
        // Capture them into registers so they survive into HDR0/HDR1.
        TXS_ACK: begin
            tx_cap_valid <= app_tx_data_valid;
            tx_cap_data  <= app_tx_data;
            tx_cap_keep  <= app_tx_data_keep;
            tx_cap_last  <= app_tx_data_last;
            tx_state     <= TXS_HDR0;
        end

        TXS_HDR0: begin
            // Build header word 0: DA[0..5] + SA[0..1]
            mac_tx_data_valid <= 1'b1;
            mac_tx_data <= {LOCAL_MAC[39:32], LOCAL_MAC[47:40],
                           tx_dst_mac[47:40], tx_dst_mac[39:32],
                           tx_dst_mac[31:24], tx_dst_mac[23:16],
                           tx_dst_mac[15:8],  tx_dst_mac[7:0]};
            mac_tx_keep <= 8'hFF;
            mac_tx_last <= 1'b0;

            // Also capture any new data the adapter provides this cycle
            if (app_tx_data_valid && !tx_cap_valid) begin
                tx_cap_valid <= 1'b1;
                tx_cap_data  <= app_tx_data;
                tx_cap_keep  <= app_tx_data_keep;
                tx_cap_last  <= app_tx_data_last;
            end

            tx_state <= TXS_HDR1;
        end

        // Header word 1 + first 2 bytes of payload
        TXS_HDR1: begin
            // Use captured data or live data
            if (tx_cap_valid || app_tx_data_valid) begin : hdr1_blk
                reg [63:0] d;
                reg [7:0]  k;
                reg        l;
                reg [3:0]  app_vb; // valid byte count from keep
                if (tx_cap_valid) begin
                    d = tx_cap_data;
                    k = tx_cap_keep;
                    l = tx_cap_last;
                    tx_cap_valid <= 1'b0;
                end else begin
                    d = app_tx_data;
                    k = app_tx_data_keep;
                    l = app_tx_data_last;
                end
                app_vb = popcount8(k);

                mac_tx_data_valid <= 1'b1;
                mac_tx_data       <= {d[15:0], hdr_w1_lo};
                mac_tx_keep       <= 8'hFF;
                tx_residue        <= d[63:16];

                if (l) begin
                    if (app_vb <= 4'd2) begin
                        mac_tx_last <= 1'b1;
                        tx_state    <= TXS_IDLE;
                    end else begin
                        mac_tx_last <= 1'b0;
                        // Residue has (app_vb - 2) valid bytes
                        case (app_vb - 4'd2)
                            4'd1: tx_tail_keep <= 8'h01;
                            4'd2: tx_tail_keep <= 8'h03;
                            4'd3: tx_tail_keep <= 8'h07;
                            4'd4: tx_tail_keep <= 8'h0F;
                            4'd5: tx_tail_keep <= 8'h1F;
                            4'd6: tx_tail_keep <= 8'h3F;
                            default: tx_tail_keep <= 8'hFF;
                        endcase
                        tx_state <= TXS_TAIL;
                    end
                end else begin
                    mac_tx_last <= 1'b0;
                    tx_state    <= TXS_DATA;
                end
            end
        end

        TXS_DATA: begin
            if (app_tx_data_valid) begin : data_blk
                reg [3:0] dvb;
                dvb = popcount8(app_tx_data_keep);
                mac_tx_data_valid <= 1'b1;
                mac_tx_data       <= {app_tx_data[15:0], tx_residue};
                mac_tx_keep       <= 8'hFF;
                tx_residue        <= app_tx_data[63:16];

                if (app_tx_data_last) begin
                    if (dvb <= 4'd2) begin
                        mac_tx_last <= 1'b1;
                        tx_state    <= TXS_IDLE;
                    end else begin
                        mac_tx_last <= 1'b0;
                        case (dvb - 4'd2)
                            4'd1: tx_tail_keep <= 8'h01;
                            4'd2: tx_tail_keep <= 8'h03;
                            4'd3: tx_tail_keep <= 8'h07;
                            4'd4: tx_tail_keep <= 8'h0F;
                            4'd5: tx_tail_keep <= 8'h1F;
                            4'd6: tx_tail_keep <= 8'h3F;
                            default: tx_tail_keep <= 8'hFF;
                        endcase
                        tx_state <= TXS_TAIL;
                    end
                end else begin
                    mac_tx_last <= 1'b0;
                end
            end
        end

        TXS_TAIL: begin
            mac_tx_data_valid <= 1'b1;
            mac_tx_data       <= {16'd0, tx_residue};
            mac_tx_last       <= 1'b1;
            mac_tx_keep       <= tx_tail_keep;
            tx_state          <= TXS_IDLE;
        end

        default: tx_state <= TXS_IDLE;
        endcase
    end
end

endmodule
