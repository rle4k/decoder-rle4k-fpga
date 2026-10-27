// ============================================================================
// tb_decoder_crc -- N-block strip CRC32 verification testbench
// ============================================================================
// Feeds an N-block strip through the decoder core, computes CRC32 on
// decoded 512-bit words, and compares with PC reference.
// Block heights are loaded from block_heights.hex via $readmemh.
// ============================================================================
`timescale 1ns / 1ps

module tb_decoder_crc;

// Strip parameters (from tb/sim_data/sim_config.txt — gen_sim_data on rle4k_sim_strip)
localparam LINE_WIDTH       = 32'd65536;
localparam LINE_STRIDE      = 32'd65536;
localparam STREAM_WORDS     = 3470;
localparam BLOCK_COUNT      = 2;
localparam MAX_BLOCKS       = 16;  // max supported for array sizing

// Expected results (from tb/sim_data/sim_config.txt / ref_crc.txt)
localparam [31:0] EXPECTED_TOTAL_WORDS = 32'd98688;
localparam [31:0] EXPECTED_CRC_ACCUM   = 32'h0783fb2e;
localparam [31:0] EXPECTED_CRC32       = 32'hf87c04d1;

// Defect-B A/B switch: rle4k_lan_top_v8 hard-wires .block_start(1'b0), this TB
// pulses it for block 0. Compile with -d BLOCK_START_ZERO to match the shipped
// top level and confirm the strip results are identical.
`ifdef BLOCK_START_ZERO
localparam BLOCK_START_EN = 1'b0;
`else
localparam BLOCK_START_EN = 1'b1;
`endif

// Clock: 125 MHz (8ns period)
reg clk;
initial clk = 0;
always #4 clk = ~clk;

reg rst_n;

// Decoder input
reg  [31:0] encoded_data_in;
reg         encoded_data_valid;
reg         block_start;
reg         stream_end_sig;
wire        decoder_fifo_ready;

// Decoder output
wire [511:0] decoded_data_out;
wire         word_decoded_valid;
wire         block_done;
wire         strip_end_out;
wire [31:0]  decode_status;

// Configuration
reg  [31:0] cfg_block_index;
reg  [31:0] cfg_line_width;
reg  [31:0] cfg_line_stride;
reg  [31:0] cfg_block_height;

// Stream data memory
reg [31:0] stream_mem [0:STREAM_WORDS-1];
// Block heights memory
reg [31:0] block_heights [0:MAX_BLOCKS-1];

// Full-strip cfg (V08): total decoded lines = sum(block heights); RLE bytes = 32b words * 4
reg [31:0] cfg_strip_line_total_r;
reg [31:0] cfg_rle_payload_bytes_r;

integer hi_bh;
initial begin
    // Paths relative to sim_out/ (run_sim_crc.tcl sets cwd there)
    $readmemh("../tb/sim_data/stream_data.hex", stream_mem);
    $readmemh("../tb/sim_data/block_heights.hex", block_heights);
    cfg_strip_line_total_r = 32'd0;
    for (hi_bh = 0; hi_bh < BLOCK_COUNT; hi_bh = hi_bh + 1)
        cfg_strip_line_total_r = cfg_strip_line_total_r + block_heights[hi_bh];
    cfg_rle_payload_bytes_r = STREAM_WORDS * 32'd4;
end

reg strip_byte_cnt_rst_sig;

// DUT
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
    .cfg_strip_line_count(cfg_strip_line_total_r),
    .cfg_rle_payload_bytes(cfg_rle_payload_bytes_r),
    .strip_byte_cnt_rst(strip_byte_cnt_rst_sig),
    .upstream_busy(1'b0),
    .decode_status     (decode_status),
    .block_done        (block_done),
    .strip_end_out     (strip_end_out),
    .block_index_out   ()
);

// ============================================================================
// CRC32 computation (Ethernet CRC32, poly 0xEDB88320)
// ============================================================================
function [31:0] crc32_byte;
    input [31:0] prev;
    input [7:0]  b;
    reg [31:0] c;
    integer i;
    begin
        c = prev ^ {24'd0, b};
        for (i = 0; i < 8; i = i + 1)
            c = c[0] ? ({1'b0, c[31:1]} ^ 32'hEDB88320) : {1'b0, c[31:1]};
        crc32_byte = c;
    end
endfunction

reg [31:0] crc32_accum;
reg [31:0] crc32_word_count;

reg [31:0] crc32_next;
integer crc_j;
always @(*) begin
    crc32_next = crc32_accum;
    for (crc_j = 0; crc_j < 64; crc_j = crc_j + 1)
        crc32_next = crc32_byte(crc32_next, decoded_data_out[crc_j*8 +: 8]);
end

always @(posedge clk) begin
    if (!rst_n) begin
        crc32_accum      <= 32'hFFFFFFFF;
        crc32_word_count <= 32'd0;
    end else begin
        // Count every decoded word (do not gate on block_done — last words of a
        // block can arrive with block_done high; top/CRC path counts them too).
        if (word_decoded_valid) begin
            crc32_accum      <= crc32_next;
            crc32_word_count <= crc32_word_count + 32'd1;
        end
    end
end

// ============================================================================
// N-block state machine
// ============================================================================
localparam S_RESET      = 3'd0;
localparam S_BLK_START  = 3'd1;
localparam S_BLK_FEED   = 3'd2;
localparam S_BLK_WAIT   = 3'd3;
localparam S_DONE_WAIT  = 3'd4;
localparam S_FINISH     = 3'd5;

reg [2:0]  state;
reg [31:0] feed_idx;
reg [31:0] wait_cnt;
reg        block_done_prev;
reg        test_pass;
reg [31:0] current_block;    // which block we're processing (0..BLOCK_COUNT-1)
reg [31:0] block_word_start; // word count at start of current block
reg [31:0] block_done_rise_cnt;
reg        strip_end_prev;
reg [31:0] strip_end_rise_cnt;

always @(posedge clk) begin
    block_done_prev <= block_done;
    strip_end_prev    <= strip_end_out;
    if (!rst_n) begin
        block_done_rise_cnt <= 32'd0;
        strip_end_rise_cnt  <= 32'd0;
    end else begin
        if (block_done && !block_done_prev)
            block_done_rise_cnt <= block_done_rise_cnt + 32'd1;
        if (strip_end_out && !strip_end_prev)
            strip_end_rise_cnt <= strip_end_rise_cnt + 32'd1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state              <= S_RESET;
        encoded_data_in    <= 32'd0;
        encoded_data_valid <= 1'b0;
        block_start        <= 1'b0;
        stream_end_sig     <= 1'b0;
        cfg_block_index    <= 32'd0;
        cfg_line_width     <= LINE_WIDTH;
        cfg_line_stride    <= LINE_STRIDE;
        cfg_block_height   <= 32'd512;
        feed_idx           <= 32'd0;
        wait_cnt           <= 32'd0;
        test_pass          <= 1'b1;
        current_block      <= 32'd0;
        block_word_start   <= 32'd0;
    end else begin
        block_start <= 1'b0;
        strip_byte_cnt_rst_sig <= 1'b0;

        // AXI-stream backpressure: hold valid+data in ANY state until FIFO accepts
        if (encoded_data_valid && !decoder_fifo_ready) begin
            // hold
        end else begin
            encoded_data_valid <= 1'b0;
        end

        case (state)
            S_RESET: begin
                wait_cnt <= wait_cnt + 32'd1;
                // One-cycle strip_byte_cnt_rst after reset (aligns byte idx / strip counters for full strip)
                if (wait_cnt == 32'd0)
                    strip_byte_cnt_rst_sig <= 1'b1;
                if (wait_cnt == 32'd10) begin
                    state <= S_BLK_START;
                    $display("[%0t] === Starting %0d-block strip simulation (strip_lines=%0d rle_bytes=%0d) ===",
                             $time, BLOCK_COUNT, cfg_strip_line_total_r, cfg_rle_payload_bytes_r);
                end
            end

            // Match rle4k_lan_top_v8 / stream_adapter: block_start only for strip/first
            // block; later blocks advance by changing cfg_block_index/height only.
            S_BLK_START: begin
                cfg_block_index  <= current_block;
                cfg_block_height <= block_heights[current_block];
                if (current_block == 32'd0 && BLOCK_START_EN)
                    block_start <= 1'b1;
                block_word_start <= crc32_word_count;
                state            <= S_BLK_FEED;
                $display("[%0t] Block %0d start: height=%0d feed_idx=%0d block_start=%0d",
                         $time, current_block, block_heights[current_block], feed_idx,
                         (current_block == 32'd0) && BLOCK_START_EN);
            end

            // Keep feeding across block boundaries (V1.0 continuous strip). Do not starve
            // the input FIFO for hundreds of cycles — that desyncs parser vs block_start.
            S_BLK_FEED: begin
                if (block_done && !block_done_prev) begin
                    $display("[%0t] Block %0d done: words=%0d (+%0d) crc=0x%08x feed_idx=%0d",
                             $time, current_block,
                             crc32_word_count,
                             crc32_word_count - block_word_start,
                             crc32_accum, feed_idx);
                    if (current_block < BLOCK_COUNT - 1) begin
                        current_block <= current_block + 32'd1;
                        state <= S_BLK_START;
                    end else begin
                        wait_cnt <= 32'd0;
                        state    <= S_DONE_WAIT;
                    end
                end
                if (decoder_fifo_ready && feed_idx < STREAM_WORDS &&
                    !(encoded_data_valid && !decoder_fifo_ready)) begin
                    encoded_data_in    <= stream_mem[feed_idx];
                    encoded_data_valid <= 1'b1;
                    feed_idx           <= feed_idx + 32'd1;
                end
            end

            S_BLK_WAIT: begin
                // retained for FSM completeness; multi-block path skips long wait
                if (current_block < BLOCK_COUNT - 1) begin
                    current_block <= current_block + 32'd1;
                    state <= S_BLK_START;
                end else begin
                    wait_cnt <= 32'd0;
                    state    <= S_DONE_WAIT;
                end
            end

            S_DONE_WAIT: begin
                wait_cnt <= wait_cnt + 32'd1;
                if (wait_cnt == 32'd500) begin
                    state <= S_FINISH;
                end
            end

            S_FINISH: begin
                $display("");
                $display("  ======== STRIP CRC VERIFICATION ========");
                $display("  Blocks:      %0d", BLOCK_COUNT);
                $display("  Total words: %0d (expected %0d) %s",
                         crc32_word_count, EXPECTED_TOTAL_WORDS,
                         (crc32_word_count == EXPECTED_TOTAL_WORDS) ? "PASS" : "FAIL");
                $display("  CRC accum:   0x%08x (expected 0x%08x) %s",
                         crc32_accum, EXPECTED_CRC_ACCUM,
                         (crc32_accum == EXPECTED_CRC_ACCUM) ? "PASS" : "FAIL");
                $display("  CRC32 final: 0x%08x (expected 0x%08x) %s",
                         crc32_accum ^ 32'hFFFFFFFF, EXPECTED_CRC32,
                         ((crc32_accum ^ 32'hFFFFFFFF) == EXPECTED_CRC32) ? "PASS" : "FAIL");
                $display("  block_done edges: %0d (expected %0d) %s",
                         block_done_rise_cnt, BLOCK_COUNT,
                         (block_done_rise_cnt == BLOCK_COUNT) ? "PASS" : "FAIL");
                $display("  strip_end edges:  %0d (expected >=1) %s",
                         strip_end_rise_cnt,
                         (strip_end_rise_cnt >= 32'd1) ? "PASS" : "FAIL");

                if (crc32_word_count != EXPECTED_TOTAL_WORDS) test_pass <= 1'b0;
                if (crc32_accum != EXPECTED_CRC_ACCUM) test_pass <= 1'b0;
                if (block_done_rise_cnt != BLOCK_COUNT) test_pass <= 1'b0;
                if (strip_end_rise_cnt < 32'd1) test_pass <= 1'b0;

                if (test_pass && crc32_word_count == EXPECTED_TOTAL_WORDS && crc32_accum == EXPECTED_CRC_ACCUM)
                    $display("  *** ALL TESTS PASSED ***");
                else
                    $display("  *** TEST FAILED ***");
                $display("  ========================================");
                $finish;
            end
        endcase
    end
end

// Reset
initial begin
    rst_n = 0;
    #100;
    rst_n = 1;
end

// Timeout
initial begin
    #200_000_000;
    $display("TIMEOUT at %0t", $time);
    $finish;
end

endmodule
