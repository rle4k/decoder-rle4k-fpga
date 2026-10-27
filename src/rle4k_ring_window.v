// ============================================================================
// rle4k_ring_window — whole-block DDR ring address + completion bitmap
// ============================================================================
// SSOT: HANDOVER §C.5
//   slot      = block_index % W
//   byte_addr = BASE + slot * block_bytes
//
// Occupancy per slot: busy + owner block_index. Accept of a different owner into
// a busy slot → retx_pending (sticky) + retx_count++; accept_ready=0 that cycle.
// RETX wire protocol is still a stub (protocol_v8.h RETX_REQ_STUB).
// ============================================================================

`timescale 1ns / 1ps

module rle4k_ring_window #(
    parameter [31:0] P_BASE        = 32'h2000_0000,
    parameter [31:0] P_BLOCK_BYTES = 32'd4194304,
    parameter integer P_W          = 32
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,

    input  wire        accept_valid,
    input  wire [31:0] accept_block_index,
    output reg         accept_ready,
    output reg         retx_pending,
    output reg  [31:0] retx_count,

    input  wire        complete_valid,
    input  wire [31:0] complete_block_index,

    output wire [31:0] slot,
    output wire [31:0] byte_addr,

    output reg  [31:0] complete_bitmap,   // INT32; bit[i]=1 ⇒ slot i complete & freeable
    output reg  [31:0] window_base_index,
    output reg  [31:0] last_byte_addr,
    output reg  [31:0] blocks_completed
);

localparam [31:0] W_MASK = P_W - 1;

initial begin
    if (P_W > 32)
        $error("rle4k_ring_window: P_W must be <= 32 for INT32 bitmap");
    if ((P_W & (P_W - 1)) != 0)
        $error("rle4k_ring_window: P_W must be power of 2");
end

function automatic [31:0] slot_of;
    input [31:0] bi;
    begin
        slot_of = bi & W_MASK;
    end
endfunction

function automatic [31:0] addr_of;
    input [31:0] bi;
    begin
        addr_of = P_BASE + (slot_of(bi) * P_BLOCK_BYTES);
    end
endfunction

assign slot      = slot_of(accept_valid ? accept_block_index : window_base_index);
assign byte_addr = last_byte_addr;

reg [P_W-1:0] slot_busy;
reg [31:0]    slot_owner [0:P_W-1];

wire [31:0] a_slot = slot_of(accept_block_index);
wire [31:0] c_slot = slot_of(complete_block_index);

wire accept_conflict =
    accept_valid && slot_busy[a_slot] &&
    (slot_owner[a_slot] != accept_block_index);

integer si;
always @(posedge clk) begin
    if (!rst_n || clear) begin
        accept_ready       <= 1'b1;
        retx_pending       <= 1'b0;
        retx_count         <= 32'd0;
        complete_bitmap    <= 32'd0;
        window_base_index  <= 32'd0;
        last_byte_addr     <= P_BASE;
        blocks_completed   <= 32'd0;
        slot_busy          <= {P_W{1'b0}};
        for (si = 0; si < P_W; si = si + 1)
            slot_owner[si] <= 32'd0;
    end else begin
        accept_ready <= ~accept_conflict;

        if (accept_valid && accept_conflict) begin
            retx_pending <= 1'b1;
            retx_count   <= retx_count + 32'd1;
        end else if (accept_valid && !accept_conflict) begin
            slot_busy[a_slot]        <= 1'b1;
            slot_owner[a_slot]       <= accept_block_index;
            complete_bitmap[a_slot]  <= 1'b0;
            last_byte_addr           <= addr_of(accept_block_index);
            if (!(|slot_busy) && blocks_completed == 32'd0)
                window_base_index <= accept_block_index & ~W_MASK;
        end

        if (complete_valid) begin
            if (slot_busy[c_slot] && slot_owner[c_slot] == complete_block_index) begin
                complete_bitmap[c_slot] <= 1'b1;
                slot_busy[c_slot]       <= 1'b0;
                blocks_completed        <= blocks_completed + 32'd1;
            end
        end

        // Advance base while the oldest slot is complete and idle
        if (!slot_busy[slot_of(window_base_index)] &&
            complete_bitmap[slot_of(window_base_index)]) begin
            complete_bitmap[slot_of(window_base_index)] <= 1'b0;
            window_base_index <= window_base_index + 32'd1;
        end
    end
end

endmodule
