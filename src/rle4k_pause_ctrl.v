// ============================================================================
// rle4k_pause_ctrl — 802.3x PAUSE requestor for TEMAC (tx_mac_aclk domain)
// ============================================================================
// When the RX path backs up (congested_async, typically !m_axis_tready4 from
// rx_packet_fifo0), pulse pause_req with a non-zero pause_val so the TEMAC
// emits an 802.3x PAUSE frame toward the peer. Retrigger before the quanta
// expires while still congested. On decongest, pulse once with pause_val=0 (XON).
//
// congested_async may be in udp_core_clk; it is 2FF-synced here.
// TEMAC Flow Control Config (0x40C) TX enable must already be set — see
// master_wrapper_v8 AXI wdata OR-mux on bring-up writes to 0x40C.
// ============================================================================

`timescale 1ns / 1ps

module rle4k_pause_ctrl #(
    // Pause quanta (1 quantum = 512 bit times ≈ 512 ns @ 1 Gbit/s).
    parameter [15:0]  P_PAUSE_QUANTA   = 16'hFFFF,
    // Retrigger period while congested, in tx_clk cycles.
    // Default ~800 µs @ 125 MHz — well under max-quanta hold (~33.5 ms).
    parameter integer P_RETRIG_CYCLES  = 100_000,
    // Minimum XOFF hold after the last congestion assertion, in tx_clk cycles.
    // 25_000 @ 125 MHz = 200 us: long enough for the PAUSE frame to reach the
    // peer and take effect, and long enough for rx_async_fifo0 (2048 x 8 B) to
    // drain on its 15.625 MHz read side (~125 MB/s => ~25 KB in 200 us).
    parameter integer P_MIN_HOLD_CYCLES = 25_000
) (
    input  wire        tx_clk,
    input  wire        tx_reset,          // active-high, tx_mac_aclk domain
    input  wire        congested_async,   // any domain; level
    output reg         pause_req,
    output reg  [15:0] pause_val,
    // Observability (optional VIO / TB)
    output wire        congested_sync
);

reg c0, c1;
always @(posedge tx_clk) begin
    if (tx_reset) begin
        c0 <= 1'b0;
        c1 <= 1'b0;
    end else begin
        c0 <= congested_async;
        c1 <= c0;
    end
end

assign congested_sync = c1;

// Minimum XOFF hold. congested_async is assembled in master_wrapper_v8 out of
// instantaneous refuse/full indications (~rx_dwc_s_axis_tready, ~m_axis_tready3,
// ~m_axis_tready4). Each of those clears again as soon as a single word drains,
// i.e. within a few tx_clk cycles, while a PAUSE frame needs microseconds to be
// serialised and acted upon by the peer. The falling-edge XON below therefore
// used to cancel the XOFF long before it could have any effect: PAUSE was wired
// end to end and still produced no backpressure on the wire. Holding congestion
// for P_MIN_HOLD_CYCLES past the last assertion turns a transient full into real
// backpressure and gives rx_async_fifo0 time to drain before the peer resumes.
reg [31:0] hold_cnt;
always @(posedge tx_clk) begin
    if (tx_reset)
        hold_cnt <= 32'd0;
    else if (congested_sync)
        hold_cnt <= P_MIN_HOLD_CYCLES[31:0];
    else if (hold_cnt != 32'd0)
        hold_cnt <= hold_cnt - 32'd1;
end

wire congested_hold = congested_sync | (hold_cnt != 32'd0);

reg        congested_d;
reg [31:0] retrig_cnt;

always @(posedge tx_clk) begin
    if (tx_reset) begin
        pause_req    <= 1'b0;
        pause_val    <= 16'd0;
        congested_d  <= 1'b0;
        retrig_cnt   <= 32'd0;
    end else begin
        congested_d <= congested_hold;
        pause_req   <= 1'b0; // default: single-cycle pulse when set below

        if (congested_hold && !congested_d) begin
            // Rising edge: assert PAUSE
            pause_req  <= 1'b1;
            pause_val  <= P_PAUSE_QUANTA;
            retrig_cnt <= P_RETRIG_CYCLES[31:0];
        end else if (!congested_hold && congested_d) begin
            // Falling edge: XON
            pause_req  <= 1'b1;
            pause_val  <= 16'h0;
            retrig_cnt <= 32'd0;
        end else if (congested_hold) begin
            if (retrig_cnt == 32'd0) begin
                pause_req  <= 1'b1;
                pause_val  <= P_PAUSE_QUANTA;
                retrig_cnt <= P_RETRIG_CYCLES[31:0];
            end else begin
                retrig_cnt <= retrig_cnt - 32'd1;
            end
        end
    end
end

endmodule
