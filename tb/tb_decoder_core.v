// ============================================================================
// Testbench: rle4k_decoder_core (multi-block strip support)
// Feeds real .rle4k compressed data with 0xC0/0x80 markers,
// captures 512-bit output, compares to reference, and verifies CRC32.
// ============================================================================

`timescale 1ns / 1ps

module tb_decoder_core;

// Clock: 125 MHz = 8 ns period
reg clk = 0;
always #4 clk = ~clk;

reg rst_n = 0;

// Stimulus
reg [31:0] encoded_data_in;
reg        encoded_data_valid;
reg        block_start;
wire       decoder_fifo_ready;

// Config
reg [31:0] cfg_block_index;
reg [31:0] cfg_line_width;
reg [31:0] cfg_line_stride;
reg [31:0] cfg_block_height;

// Output
wire [511:0] decoded_data_out;
wire         word_decoded_valid;
reg          word_decoded_ready;

// Status
wire [31:0] decode_status;
wire        block_done;
wire        strip_end_out;
wire [31:0] block_index_out;

// DUT
rle4k_decoder_core u_dut (
    .clk               (clk),
    .rst_n             (rst_n),
    .upstream_busy(1'b0),
    .encoded_data_in   (encoded_data_in),
    .encoded_data_valid(encoded_data_valid),
    .block_start       (block_start),
    .stream_end        (1'b0),
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
    .strip_end_out     (strip_end_out),
    .block_index_out   (block_index_out)
);

// Load stimulus
parameter MAX_STIM = 131072;
reg [31:0] stim_data [0:MAX_STIM-1];

// Load reference
parameter MAX_REF = 262144;
reg [511:0] ref_data [0:MAX_REF-1];

// Multi-block params
parameter MAX_BLOCKS = 64;
integer num_blocks;
integer total_stim_words;
integer blk_width  [0:MAX_BLOCKS-1];
integer blk_stride [0:MAX_BLOCKS-1];
integer blk_height [0:MAX_BLOCKS-1];

// Read params
integer param_fd, scan_ret;

// Output capture
integer out_idx;
integer mismatch_count;
integer pass_count;
integer total_ref_count;

// Data feeder state
integer feed_idx;
reg     feed_done;

// CRC32 computation (matching rle4k_lan_top_v8.v)
function [31:0] crc32_byte;
    input [31:0] crc_in;
    input [7:0]  byte_in;
    reg [31:0]   c;
    integer i;
    begin
        c = crc_in ^ {24'b0, byte_in};
        for (i = 0; i < 8; i = i + 1)
            c = c[0] ? (c >> 1) ^ 32'hEDB88320 : (c >> 1);
        crc32_byte = c;
    end
endfunction

reg [31:0] crc32_accum;
reg [31:0] crc32_word_count;
reg [31:0] crc32_latched;
reg [31:0] crc32_word_count_latched;
reg        crc32_done;
reg        strip_end_prev;

// Reference CRC
integer ref_crc_fd;
reg [31:0] ref_crc_value;
reg [31:0] ref_crc_words;

// CRC32 combinational
reg [31:0] crc32_next;
integer crc_j;
always @(*) begin
    crc32_next = crc32_accum;
    for (crc_j = 0; crc_j < 64; crc_j = crc_j + 1)
        crc32_next = crc32_byte(crc32_next, decoded_data_out[crc_j*8 +: 8]);
end

// CRC accumulation (clocked)
always @(posedge clk) begin
    if (!rst_n) begin
        crc32_accum <= 32'hFFFFFFFF;
        crc32_word_count <= 0;
        crc32_latched <= 0;
        crc32_word_count_latched <= 0;
        crc32_done <= 0;
        strip_end_prev <= 0;
    end else begin
        strip_end_prev <= strip_end_out;

        if (word_decoded_valid && word_decoded_ready && !block_done) begin
            crc32_accum <= crc32_next;
            crc32_word_count <= crc32_word_count + 1;

            if (crc32_word_count < 4) begin
                $display("  SIM word[%0d] crc_accum=0x%08h byte[0..7]=%02h %02h %02h %02h %02h %02h %02h %02h",
                    crc32_word_count, crc32_next,
                    decoded_data_out[7:0],   decoded_data_out[15:8],
                    decoded_data_out[23:16], decoded_data_out[31:24],
                    decoded_data_out[39:32], decoded_data_out[47:40],
                    decoded_data_out[55:48], decoded_data_out[63:56]);
            end
        end

        if (strip_end_out && !strip_end_prev) begin
            crc32_latched <= crc32_accum ^ 32'hFFFFFFFF;
            crc32_word_count_latched <= crc32_word_count;
            crc32_done <= 1;
            $display("CRC LATCHED: 0x%08h  words: %0d", crc32_accum ^ 32'hFFFFFFFF, crc32_word_count);
        end
    end
end

// Output capture and comparison
always @(posedge clk) begin
    if (rst_n && word_decoded_valid && word_decoded_ready) begin
        if (out_idx < total_ref_count) begin
            if (decoded_data_out !== ref_data[out_idx]) begin
                if (mismatch_count < 20)
                    $display("MISMATCH at word %0d: DUT=%0128h REF=%0128h",
                             out_idx, decoded_data_out, ref_data[out_idx]);
                mismatch_count = mismatch_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        end
        out_idx = out_idx + 1;

        if (out_idx % 20000 == 0)
            $display("T=%0t output %0d / %0d", $time, out_idx, total_ref_count);
    end
end

// Main test sequence
initial begin
    // Initialize
    encoded_data_in    = 0;
    encoded_data_valid = 0;
    block_start        = 0;
    word_decoded_ready = 1;
    cfg_block_index    = 0;
    cfg_line_width     = 0;
    cfg_line_stride    = 0;
    cfg_block_height   = 0;
    out_idx            = 0;
    mismatch_count     = 0;
    pass_count         = 0;
    feed_idx           = 0;
    feed_done          = 0;
    total_ref_count    = 0;

    // Read parameters
    param_fd = $fopen("stim_params.txt", "r");
    if (param_fd == 0) begin
        $display("ERROR: cannot open stim_params.txt");
        $finish;
    end
    scan_ret = $fscanf(param_fd, "%d %d\n", num_blocks, total_stim_words);
    $display("Strip: %0d blocks, %0d stim words", num_blocks, total_stim_words);

    begin : read_block_params
        integer bi;
        for (bi = 0; bi < num_blocks; bi = bi + 1) begin
            scan_ret = $fscanf(param_fd, "%d %d %d\n", blk_width[bi], blk_stride[bi], blk_height[bi]);
            $display("  Block[%0d]: width=%0d stride=%0d height=%0d",
                     bi, blk_width[bi], blk_stride[bi], blk_height[bi]);
            total_ref_count = total_ref_count + (blk_stride[bi] / 512) * blk_height[bi];
        end
    end
    $fclose(param_fd);
    $display("Total expected output: %0d x 512-bit words", total_ref_count);

    // Load reference CRC
    ref_crc_value = 0;
    ref_crc_words = 0;
    ref_crc_fd = $fopen("ref_crc.txt", "r");
    if (ref_crc_fd != 0) begin
        scan_ret = $fscanf(ref_crc_fd, "%h %d\n", ref_crc_value, ref_crc_words);
        $fclose(ref_crc_fd);
        $display("Reference CRC: 0x%08h  words: %0d", ref_crc_value, ref_crc_words);
    end

    // Load stimulus and reference data
    $readmemh("stim_data.hex", stim_data);
    $readmemh("ref_output.hex", ref_data);

    // Reset
    rst_n = 0;
    repeat(10) @(negedge clk);
    rst_n = 1;
    repeat(5) @(negedge clk);

    // --- Fork: data feeder + block controller ---
    fork
        // Thread 1: Continuous data feeder
        begin : data_feeder
            $display("T=%0t Start feeding %0d words", $time, total_stim_words);
            for (feed_idx = 0; feed_idx < total_stim_words; feed_idx = feed_idx + 1) begin
                encoded_data_in    = stim_data[feed_idx];
                encoded_data_valid = 1;
                @(negedge clk);
                while (!decoder_fifo_ready) begin
                    encoded_data_valid = 0;
                    @(negedge clk);
                    encoded_data_valid = 1;
                end
            end
            encoded_data_valid = 0;
            encoded_data_in    = 0;
            feed_done = 1;
            $display("T=%0t All %0d stim words fed", $time, total_stim_words);
        end

        // Thread 2: Block start controller
        begin : block_controller
            integer bi;
            for (bi = 0; bi < num_blocks; bi = bi + 1) begin
                // Configure for this block
                cfg_block_index = bi;
                cfg_line_width  = blk_width[bi];
                cfg_line_stride = blk_stride[bi];
                cfg_block_height = blk_height[bi];
                @(negedge clk);

                // Pulse block_start
                $display("T=%0t Block[%0d] START (height=%0d)", $time, bi, blk_height[bi]);
                block_start = 1;
                @(negedge clk);
                block_start = 0;

                // Wait for block_done
                begin : wait_blk_done
                    integer timeout;
                    timeout = 0;
                    while (!block_done && timeout < 10000000) begin
                        @(posedge clk);
                        timeout = timeout + 1;
                    end
                    if (block_done)
                        $display("T=%0t Block[%0d] DONE after %0d cycles (out_idx=%0d)",
                                 $time, bi, timeout, out_idx);
                    else
                        $display("T=%0t Block[%0d] TIMEOUT after %0d cycles", $time, bi, timeout);
                end

                // Wait a few cycles for post_block_drain to consume 0xC0
                repeat(20) @(negedge clk);
            end
        end
    join

    // Wait for strip_end or timeout
    begin : wait_strip
        integer timeout;
        timeout = 0;
        while (!strip_end_out && timeout < 100000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (strip_end_out)
            $display("T=%0t strip_end_out asserted after %0d extra cycles", $time, timeout);
        else
            $display("T=%0t WARN: strip_end_out NOT asserted after %0d cycles", $time, timeout);
    end

    repeat(10) @(posedge clk);

    // Summary
    $display("");
    $display("===== SIMULATION SUMMARY =====");
    $display("Blocks:         %0d", num_blocks);
    $display("Output words:   %0d / %0d expected", out_idx, total_ref_count);
    $display("Pass:           %0d", pass_count);
    $display("Mismatch:       %0d", mismatch_count);
    $display("strip_end_out:  %0b", strip_end_out);
    $display("block_done:     %0b", block_done);
    if (mismatch_count == 0 && out_idx >= total_ref_count)
        $display("DATA RESULT:    PASS");
    else
        $display("DATA RESULT:    FAIL");
    $display("");
    $display("===== CRC32 COMPARISON =====");
    $display("SIM CRC32:  0x%08h  words: %0d  done: %0b",
             crc32_latched, crc32_word_count_latched, crc32_done);
    $display("REF CRC32:  0x%08h  words: %0d", ref_crc_value, ref_crc_words);
    if (crc32_done && crc32_latched == ref_crc_value && crc32_word_count_latched == ref_crc_words)
        $display("CRC RESULT:     PASS");
    else if (!crc32_done)
        $display("CRC RESULT:     FAIL (done=0, strip_end not detected)");
    else
        $display("CRC RESULT:     FAIL (mismatch)");
    $display("==============================");

    repeat(20) @(posedge clk);
    $finish;
end

endmodule
