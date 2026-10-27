// ============================================================================
// rle4k_cdc_fifo_36 — Pure RTL async FIFO with FWFT (36-bit, dual-clock)
// ============================================================================
// Gray-code pointer CDC, no vendor IP dependency.
// FWFT behavior: empty=0 implies dout is valid; rd_en consumes current word.
// Implementation: standard FIFO + 1-deep output register for FWFT.
// ============================================================================

`timescale 1ns / 1ps

module rle4k_cdc_fifo_36 (
    input  wire        rst,
    input  wire        wr_clk,
    input  wire        rd_clk,
    input  wire [35:0] din,
    input  wire        wr_en,
    input  wire        rd_en,
    output wire [35:0] dout,
    output wire        full,
    output wire        almost_full,
    output wire        empty,
    output wire        valid
);

// Deepen per-lane CDC so STREAM_FEED can dump a full max-size block (~53 KB)
// into one lane without stalling the adapter FSM on decoder drain — freeing the
// FSM to ASSIGN+feed the next lane while prior lanes keep decoding.
// Was ADDR_BITS=9 (depth 512 ≈ 2 KiB). Parallel feed needs room for a full
// compressed block (~53 KB max) so STREAM_FEED can finish without stalling the
// shared adapter on that lane — depth 16384 ≈ 64 KiB / lane.
localparam ADDR_BITS = 14;
localparam DEPTH     = 1 << ADDR_BITS;

(* ram_style = "block" *) reg [35:0] mem [0:DEPTH-1];

reg [ADDR_BITS:0] wr_ptr_bin  = 0;
reg [ADDR_BITS:0] wr_ptr_gray = 0;
reg [ADDR_BITS:0] rd_ptr_bin  = 0;
reg [ADDR_BITS:0] rd_ptr_gray = 0;

reg [ADDR_BITS:0] rd_ptr_gray_sync1 = 0, rd_ptr_gray_sync2 = 0;
reg [ADDR_BITS:0] wr_ptr_gray_sync1 = 0, wr_ptr_gray_sync2 = 0;

// Write reset synchronizer
reg wr_rst_ff1 = 1, wr_rst_ff2 = 1;
always @(posedge wr_clk or posedge rst) begin
    if (rst) begin wr_rst_ff1 <= 1'b1; wr_rst_ff2 <= 1'b1; end
    else      begin wr_rst_ff1 <= 1'b0; wr_rst_ff2 <= wr_rst_ff1; end
end
wire wr_rst = wr_rst_ff2;

// Read reset synchronizer
reg rd_rst_ff1 = 1, rd_rst_ff2 = 1;
always @(posedge rd_clk or posedge rst) begin
    if (rst) begin rd_rst_ff1 <= 1'b1; rd_rst_ff2 <= 1'b1; end
    else      begin rd_rst_ff1 <= 1'b0; rd_rst_ff2 <= rd_rst_ff1; end
end
wire rd_rst = rd_rst_ff2;

function [ADDR_BITS:0] bin2gray;
    input [ADDR_BITS:0] bin;
    bin2gray = bin ^ (bin >> 1);
endfunction

// ============================================================================
// Write domain
// ============================================================================
wire wr_en_actual = wr_en & ~full;

always @(posedge wr_clk) begin
    if (wr_rst) begin
        wr_ptr_bin  <= 0;
        wr_ptr_gray <= 0;
    end else if (wr_en_actual) begin
        wr_ptr_bin  <= wr_ptr_bin + 1'b1;
        wr_ptr_gray <= bin2gray(wr_ptr_bin + 1'b1);
    end
end

always @(posedge wr_clk) begin
    if (wr_en_actual)
        mem[wr_ptr_bin[ADDR_BITS-1:0]] <= din;
end

always @(posedge wr_clk) begin
    if (wr_rst) begin rd_ptr_gray_sync1 <= 0; rd_ptr_gray_sync2 <= 0; end
    else        begin rd_ptr_gray_sync1 <= rd_ptr_gray; rd_ptr_gray_sync2 <= rd_ptr_gray_sync1; end
end

wire [ADDR_BITS:0] rd_ptr_gray_inv = {~rd_ptr_gray_sync2[ADDR_BITS:ADDR_BITS-1],
                                       rd_ptr_gray_sync2[ADDR_BITS-2:0]};

assign full = (wr_ptr_gray == rd_ptr_gray_inv);

// The producer decides whether to push a cycle before the write actually lands
// (the adapter registers dec_valid), so a write authorised against a not-full
// FIFO can arrive when it has just filled. Gating that write on `full` drops it
// silently while the producer has already moved on -- which is what corrupted
// the decoded stream as soon as the FIFO ran full at speed. `almost_full` is
// published one slot early so the producer stops in time and the write already
// in flight still has somewhere to go.
assign almost_full = full | (bin2gray(wr_ptr_bin + 1'b1) == rd_ptr_gray_inv);

// Any write that still gets discarded is a design error, not back-pressure.
// It is counted rather than ignored so a gate can fail on it.
reg [15:0] dbg_overflow_drops = 16'd0;
always @(posedge wr_clk) begin
    if (wr_rst)
        dbg_overflow_drops <= 16'd0;
    else if (wr_en && full)
        dbg_overflow_drops <= dbg_overflow_drops + 16'd1;
end

// ============================================================================
// Read domain
// ============================================================================
// Internal empty flag based on Gray pointers
wire int_empty = (rd_ptr_gray == wr_ptr_gray_sync2);

always @(posedge rd_clk) begin
    if (rd_rst) begin wr_ptr_gray_sync1 <= 0; wr_ptr_gray_sync2 <= 0; end
    else        begin wr_ptr_gray_sync1 <= wr_ptr_gray; wr_ptr_gray_sync2 <= wr_ptr_gray_sync1; end
end

// Forward declarations for int_rd condition
reg out_valid;
reg rd_pending;

// Internal read: advance pointer
// FIX: Don't start new read while previous read is pending (rd_pending=1)
// This prevents mem_dout from being overwritten before captured into out_data
wire int_rd = ~int_empty & ~rd_pending & (~out_valid | (rd_en & out_valid));

always @(posedge rd_clk) begin
    if (rd_rst) begin
        rd_ptr_bin  <= 0;
        rd_ptr_gray <= 0;
    end else if (int_rd) begin
        rd_ptr_bin  <= rd_ptr_bin + 1'b1;
        rd_ptr_gray <= bin2gray(rd_ptr_bin + 1'b1);
    end
end

// BRAM read: registered output (1 cycle after int_rd)
reg [35:0] mem_dout;
always @(posedge rd_clk) begin
    if (int_rd)
        mem_dout <= mem[rd_ptr_bin[ADDR_BITS-1:0]];
end

// Track that a valid read was issued (data arrives next cycle)
// (rd_pending declared above as forward declaration)
always @(posedge rd_clk) begin
    if (rd_rst)
        rd_pending <= 1'b0;
    else
        rd_pending <= int_rd;
end

// FWFT output register
reg [35:0] out_data;

always @(posedge rd_clk) begin
    if (rd_rst) begin
        out_data  <= 36'd0;
        out_valid <= 1'b0;
    end else begin
        if (rd_pending && !out_valid) begin
            out_data  <= mem_dout;
            out_valid <= 1'b1;
        end else if (rd_pending && rd_en && out_valid) begin
            out_data  <= mem_dout;
            out_valid <= 1'b1;
        end else if (rd_en && out_valid && !rd_pending) begin
            out_valid <= 1'b0;
        end
    end
end

assign dout  = out_data;
assign empty = ~out_valid;
assign valid = out_valid;

endmodule
