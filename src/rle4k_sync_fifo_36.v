// ============================================================================
// rle4k_sync_fifo_36 — single-clock staging FIFO (36-bit, registered read)
// ============================================================================
// Per-lane MAC-domain buffer ahead of rle4k_cdc_fifo_36. Lets STREAM_FEED dump
// into one lane while other lanes drain staging→CDC→decoder in parallel.
// Depth = 2^P_ADDR_BITS (default 4096).
//
// almost_full  : hard back-pressure to adapter (DEPTH-16)
// pause_level  : earlier watermark for 802.3x PAUSE (leave P_PAUSE_HEADROOM free)
// ============================================================================

`timescale 1ns / 1ps

module rle4k_sync_fifo_36 #(
    parameter integer P_ADDR_BITS      = 12,
    parameter integer P_PAUSE_HEADROOM = 512
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [35:0] din,
    input  wire        wr_en,
    output wire        full,
    output wire        almost_full,
    output wire        pause_level,
    input  wire        rd_en,
    output reg  [35:0] dout,
    output wire        empty,
    output reg         valid       // 1-cycle after successful rd_en (pipe)
);

localparam integer DEPTH = 1 << P_ADDR_BITS;

(* ram_style = "block" *) reg [35:0] mem [0:DEPTH-1];

reg [P_ADDR_BITS:0] wr_ptr;
reg [P_ADDR_BITS:0] rd_ptr;
reg [P_ADDR_BITS:0] count;

wire wr_fire = wr_en & ~full;
wire rd_fire = rd_en & ~empty;

assign full        = (count == DEPTH[P_ADDR_BITS:0]);
assign empty       = (count == {(P_ADDR_BITS+1){1'b0}});
assign almost_full = (count >= (DEPTH[P_ADDR_BITS:0] - 5'd16));
// Assert PAUSE while occupancy leaves < P_PAUSE_HEADROOM free slots (or full).
assign pause_level = (count >= (DEPTH[P_ADDR_BITS:0] - P_PAUSE_HEADROOM[P_ADDR_BITS:0]))
                   | full;

always @(posedge clk) begin
    if (rst) begin
        wr_ptr <= {(P_ADDR_BITS+1){1'b0}};
        rd_ptr <= {(P_ADDR_BITS+1){1'b0}};
        count  <= {(P_ADDR_BITS+1){1'b0}};
        dout   <= 36'd0;
        valid  <= 1'b0;
    end else begin
        if (wr_fire) begin
            mem[wr_ptr[P_ADDR_BITS-1:0]] <= din;
            wr_ptr <= wr_ptr + 1'b1;
        end
        if (rd_fire) begin
            dout   <= mem[rd_ptr[P_ADDR_BITS-1:0]];
            rd_ptr <= rd_ptr + 1'b1;
        end
        valid <= rd_fire;

        case ({wr_fire, rd_fire})
            2'b10: count <= count + 1'b1;
            2'b01: count <= count - 1'b1;
            default: ;
        endcase
    end
end

endmodule
