// Single block CRC verification testbench with w32768 checkpoint
`timescale 1ns / 1ps

module tb_single_crc;

localparam LINE_WIDTH       = 32'd65536;
localparam LINE_STRIDE      = 32'd65536;
localparam STREAM_WORDS     = 2305;
localparam BLOCK_HEIGHT     = 512;

localparam [31:0] EXPECTED_TOTAL_WORDS = 32'd65536;
localparam [31:0] EXPECTED_CRC_ACCUM   = 32'h3e1e302d;
localparam [31:0] EXPECTED_CRC32       = 32'hc1e1cfd2;
localparam [31:0] EXPECTED_W32768_CRC  = 32'h954a9583;

reg clk;
initial clk = 0;
always #4 clk = ~clk;

reg rst_n;

reg  [31:0] encoded_data_in;
reg         encoded_data_valid;
reg         block_start;
reg         stream_end_sig;
wire        decoder_fifo_ready;

wire [511:0] decoded_data_out;
wire         word_decoded_valid;
wire         block_done;
wire         strip_end_out;
wire [31:0]  decode_status;

reg  [31:0] cfg_block_index;
reg  [31:0] cfg_line_width;
reg  [31:0] cfg_line_stride;
reg  [31:0] cfg_block_height;

reg [31:0] stream_mem [0:STREAM_WORDS-1];

initial begin
    $readmemh("tb/sim_single/stream_data.hex", stream_mem);
end

rle4k_decoder_core u_decoder (
    .clk               (clk),
    .rst_n             (rst_n),
    .encoded_data_in   (encoded_data_in),
    .encoded_data_valid(encoded_data_valid),
    .block_start       (block_start),
    .stream_end        (stream_end_sig),
    .decoder_fifo_ready(decoder_fifo_ready),
    .decoded_data_out  (decoded_data_out),
    .word_decoded_valid(word_decoded_valid),
    .word_decoded_ready(1'b1),
    .cfg_block_index   (cfg_block_index),
    .cfg_line_width    (cfg_line_width),
    .cfg_line_stride   (cfg_line_stride),
    .cfg_block_height  (cfg_block_height),
    .cfg_strip_line_count(cfg_block_height),
    .cfg_rle_payload_bytes(32'hFFFFFFFF),
    .strip_byte_cnt_rst(1'b0),
    .upstream_busy(1'b0),
    .decode_status     (decode_status),
    .block_done        (block_done),
    .strip_end_out     (strip_end_out),
    .block_index_out   ()
);

// CRC32 calculation
function [31:0] crc32_byte;
    input [31:0] crc;
    input [7:0] data;
    reg [31:0] c;
    integer i;
    begin
        c = crc ^ {24'd0, data};
        for (i = 0; i < 8; i = i + 1)
            c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
        crc32_byte = c;
    end
endfunction

reg [31:0] crc_accum;
reg [31:0] word_count;
reg [31:0] crc_w32768;

integer feed_idx;

reg [2:0] state;
localparam S_RESET   = 3'd0;
localparam S_START   = 3'd1;
localparam S_FEED    = 3'd2;
localparam S_WAIT    = 3'd3;
localparam S_DONE    = 3'd4;

reg done;
reg pass;

initial begin
    rst_n = 0;
    encoded_data_in = 0;
    encoded_data_valid = 0;
    block_start = 0;
    stream_end_sig = 0;
    cfg_block_index = 0;
    cfg_line_width = LINE_WIDTH;
    cfg_line_stride = LINE_STRIDE;
    cfg_block_height = BLOCK_HEIGHT;
    crc_accum = 32'hFFFFFFFF;
    word_count = 0;
    crc_w32768 = 0;
    feed_idx = 0;
    state = S_RESET;
    done = 0;
    pass = 1;

    #100;
    rst_n = 1;
    #100;
    state = S_START;
end

always @(posedge clk) begin
    if (!rst_n) begin
        state <= S_RESET;
    end else begin
        block_start <= 0;

        case (state)
            S_START: begin
                block_start <= 1;
                state <= S_FEED;
            end

            S_FEED: begin
                if (feed_idx < STREAM_WORDS) begin
                    if (!encoded_data_valid || decoder_fifo_ready) begin
                        encoded_data_in <= stream_mem[feed_idx];
                        encoded_data_valid <= 1;
                        feed_idx <= feed_idx + 1;
                    end
                end else begin
                    if (decoder_fifo_ready) encoded_data_valid <= 0;
                    if (block_done) state <= S_WAIT;
                end
            end

            S_WAIT: begin
                if (word_count >= EXPECTED_TOTAL_WORDS) begin
                    state <= S_DONE;
                    done <= 1;
                end
            end

            S_DONE: begin
                // Stay here
            end
        endcase
    end
end

// CRC accumulation
always @(posedge clk) begin
    if (!rst_n) begin
        crc_accum <= 32'hFFFFFFFF;
        word_count <= 0;
    end else if (word_decoded_valid && !block_done) begin
        // Process 64 bytes
        crc_accum <= crc32_64bytes(crc_accum, decoded_data_out);
        word_count <= word_count + 1;

        if (word_count == 32768) crc_w32768 <= crc32_64bytes(crc_accum, decoded_data_out);
    end
end

function [31:0] crc32_64bytes;
    input [31:0] crc;
    input [511:0] data;
    reg [31:0] c;
    integer i;
    begin
        c = crc;
        for (i = 0; i < 64; i = i + 1)
            c = crc32_byte(c, data[i*8 +: 8]);
        crc32_64bytes = c;
    end
endfunction

// Monitor and report
always @(posedge clk) begin
    if (done && !pass) begin
        // Already reported
    end else if (done) begin
        $display("=== SINGLE BLOCK CRC TEST ===");
        $display("feed_idx: %d (expected %d)", feed_idx, STREAM_WORDS);
        $display("Word count: %d (expected %d) %s", word_count, EXPECTED_TOTAL_WORDS,
                 (word_count == EXPECTED_TOTAL_WORDS) ? "PASS" : "FAIL");
        $display("CRC at w32768: 0x%08x (expected 0x%08x) %s", crc_w32768, EXPECTED_W32768_CRC,
                 (crc_w32768 == EXPECTED_W32768_CRC) ? "PASS" : "FAIL");
        $display("CRC accum: 0x%08x (expected 0x%08x) %s", crc_accum, EXPECTED_CRC_ACCUM,
                 (crc_accum == EXPECTED_CRC_ACCUM) ? "PASS" : "FAIL");

        if (word_count != EXPECTED_TOTAL_WORDS || crc_w32768 != EXPECTED_W32768_CRC || crc_accum != EXPECTED_CRC_ACCUM) begin
            $display("*** TEST FAILED ***");
            pass <= 0;
        end else begin
            $display("*** TEST PASSED ***");
        end
        $finish;
    end
end

// Timeout
initial begin
    #100000000;  // 100ms timeout
    $display("TIMEOUT!");
    $finish;
end

endmodule
