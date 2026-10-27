// Behavioral model of rle4k_cdc_fifo_36 for simulation only
// Port interface matches FIFO Generator IP (single rst, wr_rst_busy/rd_rst_busy outputs)
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
    output wire        empty,
    output wire        valid,
    output wire        wr_rst_busy,
    output wire        rd_rst_busy
);

assign wr_rst_busy = 1'b0;
assign rd_rst_busy = 1'b0;

reg [35:0] mem [0:511];
reg [8:0] wr_ptr = 0, rd_ptr = 0;
reg [9:0] count = 0;

assign full  = (count >= 10'd510);
assign empty = (count == 10'd0);
assign valid = rd_en & ~empty;
assign dout  = mem[rd_ptr];

always @(posedge wr_clk) begin
    if (rst) begin wr_ptr <= 0; count <= 0; end
    else if (wr_en && !full) begin
        mem[wr_ptr] <= din;
        wr_ptr <= wr_ptr + 1;
        count <= count + 1;
    end
end
always @(posedge rd_clk) begin
    if (rst) begin rd_ptr <= 0; end
    else if (rd_en && !empty) begin
        rd_ptr <= rd_ptr + 1;
        count <= count - 1;
    end
end

endmodule
