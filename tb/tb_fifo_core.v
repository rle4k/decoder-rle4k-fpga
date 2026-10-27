// Test FIFO inside decoder_core with known data
`timescale 1ns / 1ps

module tb_fifo_core;

reg clk = 0;
always #4 clk = ~clk;
reg rst_n = 0;

reg [31:0] encoded_data_in;
reg        encoded_data_valid;
reg        block_start;
wire       decoder_fifo_ready;

reg [31:0] cfg_block_index  = 0;
reg [31:0] cfg_line_width   = 65536;
reg [31:0] cfg_line_stride  = 65536;
reg [31:0] cfg_block_height = 512;

wire [511:0] decoded_data_out;
wire         word_decoded_valid;
reg          word_decoded_ready = 1;

wire [31:0] decode_status;
wire        block_done;
wire [31:0] block_index_out;

rle4k_decoder_core u_dut (
    .clk               (clk),
    .rst_n             (rst_n),
    .upstream_busy(1'b0),
    .encoded_data_in   (encoded_data_in),
    .encoded_data_valid(encoded_data_valid),
    .block_start       (block_start),
    .decoder_fifo_ready(decoder_fifo_ready),
    .decoded_data_out  (decoded_data_out),
    .word_decoded_valid(word_decoded_valid),
    .word_decoded_ready(word_decoded_ready),
    .cfg_block_index   (cfg_block_index),
    .cfg_line_width    (cfg_line_width),
    .cfg_line_stride   (cfg_line_stride),
    .cfg_block_height  (cfg_block_height),
    .decode_status     (decode_status),
    .block_done        (block_done),
    .block_index_out   (block_index_out)
);

wire [7:0]  fb = u_dut.code_byte;
wire        fv = u_dut.code_byte_valid;
wire        fr = u_dut.code_byte_ready;

wire [1:0]  f_byte_cnt = u_dut.u_input_fifo.byte_cnt;
wire [3:0]  f_wr_ptr   = u_dut.u_input_fifo.wr_ptr;
wire [3:0]  f_rd_ptr   = u_dut.u_input_fifo.rd_ptr;
wire [4:0]  f_count    = u_dut.u_input_fifo.fifo_count;
wire        f_wr_en    = u_dut.u_input_fifo.wr_en;
wire        f_rd_en    = u_dut.u_input_fifo.rd_en;
wire [31:0] f_buf0     = u_dut.u_input_fifo.fifo_buffer[0];
wire [31:0] f_buf1     = u_dut.u_input_fifo.fifo_buffer[1];

reg [31:0] fb_cnt = 0;
reg [31:0] cycle = 0;
always @(posedge clk) begin
    cycle <= cycle + 1;
    if (rst_n && cycle < 40) begin
        $display("T=%0t cy=%0d: din=%08h dv=%b rdy=%b | wr=%b rd=%b cnt=%0d wrp=%0d rdp=%0d bc=%0d | dout=%02h vo=%b ri=%b | buf0=%08h buf1=%08h",
                 $time, cycle,
                 encoded_data_in, encoded_data_valid, decoder_fifo_ready,
                 f_wr_en, f_rd_en, f_count, f_wr_ptr, f_rd_ptr, f_byte_cnt,
                 fb, fv, fr,
                 f_buf0, f_buf1);
    end
    if (rst_n && fv && fr) begin
        $display("  >>> ACCEPTED BYTE[%0d]: 0x%02h", fb_cnt, fb);
        fb_cnt <= fb_cnt + 1;
    end
end

initial begin
    encoded_data_in   = 0;
    encoded_data_valid = 0;
    block_start       = 0;

    rst_n = 0;
    repeat(10) @(posedge clk);
    rst_n = 1;
    repeat(3) @(posedge clk);

    // block_start
    block_start = 1;
    @(posedge clk);
    block_start = 0;
    @(posedge clk);

    // Feed exactly one word: 0xFFFF89BF
    // Expected byte output: BF, 89, FF, FF
    $display("Feeding 0xFFFF89BF...");
    encoded_data_in   = 32'hFFFF89BF;
    encoded_data_valid = 1;
    @(posedge clk);
    // Feed second word: 0xFFFFFFFF
    encoded_data_in   = 32'hFFFFFFFF;
    @(posedge clk);
    // Stop
    encoded_data_valid = 0;

    repeat(100) @(posedge clk);
    $display("Done. fb_cnt=%0d", fb_cnt);
    $finish;
end

endmodule
