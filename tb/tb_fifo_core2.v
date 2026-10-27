// Test: hardcode 3 different words, verify byte output order
`timescale 1ns / 1ps

module tb_fifo_core2;

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
wire [7:0]  parser_code_in = u_dut.u_code_parser.code_in;
wire        dbg_bypass = u_dut.u_input_fifo.bypass;
wire        dbg_store  = u_dut.u_input_fifo.store_to_fifo;
wire        dbg_pop    = u_dut.u_input_fifo.pop_fifo;
wire        dbg_hv     = u_dut.u_input_fifo.hold_valid;
wire [31:0] dbg_hr     = u_dut.u_input_fifo.hold_reg;
wire [1:0]  dbg_bs     = u_dut.u_input_fifo.byte_sel;
wire [4:0]  dbg_occ    = u_dut.u_input_fifo.occupancy;

reg [31:0] cyc = 0;
always @(posedge clk) begin
    cyc <= cyc + 1;
    if (rst_n && cyc >= 14 && cyc < 35)
        $display("T=%0t cy=%0d: din=%08h dv=%b | byp=%b sto=%b pop=%b | hv=%b hr=%08h bs=%0d occ=%0d | dout=%02h vo=%b ri=%b",
                 $time, cyc,
                 encoded_data_in, encoded_data_valid,
                 dbg_bypass, dbg_store, dbg_pop,
                 dbg_hv, dbg_hr, dbg_bs, dbg_occ,
                 fb, fv, fr);
end

reg [31:0] fb_cnt = 0;
always @(posedge clk) begin
    if (rst_n && fv && fr) begin
        $display("T=%0t ACCEPTED[%0d]: fifo_out=0x%02h parser_in=0x%02h", $time, fb_cnt, fb, parser_code_in);
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

    block_start = 1;
    @(posedge clk);
    block_start = 0;
    @(posedge clk);

    // Feed 3 words with distinct byte patterns
    // Word 0: 0x44332211 -> bytes: 11, 22, 33, 44
    // Word 1: 0x88776655 -> bytes: 55, 66, 77, 88
    // Word 2: 0xCCBBAA99 -> bytes: 99, AA, BB, CC
    $display("Feeding 3 words back-to-back...");
    @(negedge clk);
    encoded_data_in   = 32'h44332211;
    encoded_data_valid = 1;
    @(negedge clk);
    encoded_data_in   = 32'h88776655;
    @(negedge clk);
    encoded_data_in   = 32'hCCBBAA99;
    @(negedge clk);
    encoded_data_valid = 0;

    repeat(200) @(posedge clk);
    $display("Done. fb_cnt=%0d", fb_cnt);
    $finish;
end

endmodule
