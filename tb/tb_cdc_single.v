// Single block CRC verification with CDC FIFO (simulates actual FPGA path)
`timescale 1ns / 1ps

module tb_cdc_single;

localparam LINE_WIDTH       = 32'd65536;
localparam LINE_STRIDE      = 32'd65536;
localparam STREAM_WORDS     = 2305;
localparam BLOCK_HEIGHT     = 512;

localparam [31:0] EXPECTED_TOTAL_WORDS = 32'd65536;
localparam [31:0] EXPECTED_CRC_ACCUM   = 32'h3e1e302d;
localparam [31:0] EXPECTED_W32768_CRC  = 32'h954a9583;

// Real system: 15.625 MHz write, 125 MHz read
reg clk_wr;
reg clk_rd;
initial begin clk_wr = 0; forever #32 clk_wr = ~clk_wr; end  // 15.625 MHz
initial begin clk_rd = 0; forever #4 clk_rd = ~clk_rd; end   // 125 MHz

reg rst;

// Adapter -> CDC FIFO
reg  [31:0] adapter_data;
reg         adapter_valid;
reg         adapter_block_start;
wire        cdc_full;

// CDC FIFO -> Decoder
wire [35:0] cdc_dout;
wire        cdc_empty;
wire        cdc_valid;
reg         cdc_rd_en;

wire cdc_block_start = cdc_dout[32];
wire [31:0] cdc_data = cdc_dout[31:0];

// Decoder I/O
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

// Stream data
reg [31:0] stream_mem [0:STREAM_WORDS-1];

initial begin
    $readmemh("tb/sim_single/stream_data.hex", stream_mem);
end

// CDC FIFO
rle4k_cdc_fifo_36 u_cdc_fifo (
    .rst    (rst),
    .wr_clk (clk_wr),
    .rd_clk (clk_rd),
    .din    ({3'b0, adapter_block_start, adapter_data}),
    .wr_en  ((adapter_valid | adapter_block_start) & ~cdc_full),
    .rd_en  (cdc_rd_en),
    .dout   (cdc_dout),
    .full   (cdc_full),
    .empty  (cdc_empty),
    .valid  (cdc_valid)
);

// Skid buffer (same as top module)
reg decoder_ready_r;
always @(posedge clk_rd or posedge rst) begin
    if (rst) decoder_ready_r <= 1'b1;
    else     decoder_ready_r <= decoder_fifo_ready;
end

reg [31:0] skid_data;
reg        skid_valid;
reg        skid_block_start;

wire cdc_read_occurred = cdc_rd_en;
wire decoder_rejected  = cdc_read_occurred & ~decoder_fifo_ready & ~cdc_block_start;

always @(posedge clk_rd or posedge rst) begin
    if (rst) begin
        skid_valid <= 1'b0;
        skid_data <= 32'd0;
        skid_block_start <= 1'b0;
    end else begin
        if (decoder_rejected) begin
            skid_data <= cdc_data;
            skid_valid <= 1'b1;
            skid_block_start <= 1'b0;
        end else if (skid_valid && decoder_fifo_ready) begin
            skid_valid <= 1'b0;
        end
    end
end

wire [31:0] dec_input_data  = skid_valid ? skid_data : cdc_data;
// Match fixed top module logic (with decoder_fifo_ready check)
wire        dec_input_valid = skid_valid ? (decoder_fifo_ready & ~skid_block_start)
                                         : (cdc_rd_en & decoder_fifo_ready & ~cdc_block_start);

// Block start detection (same as top module)
reg cdc_bs_prev;
reg bs_delay_active;
reg [4:0] bs_delay_cnt;
reg block_start_delayed;

always @(posedge clk_rd or posedge rst) begin
    if (rst) cdc_bs_prev <= 1'b0;
    else if (cdc_rd_en) cdc_bs_prev <= cdc_block_start;
end
wire block_start_raw = cdc_rd_en & cdc_block_start & ~cdc_bs_prev;

// 16-cycle delay for block_start (match real design)
always @(posedge clk_rd or posedge rst) begin
    if (rst) begin
        bs_delay_cnt <= 5'd0;
        block_start_delayed <= 1'b0;
    end else begin
        block_start_delayed <= 1'b0;
        if (block_start_raw) begin
            bs_delay_cnt <= 5'd16;  // Match real design delay
        end else if (bs_delay_cnt != 5'd0) begin
            bs_delay_cnt <= bs_delay_cnt - 5'd1;
            if (bs_delay_cnt == 5'd1)
                block_start_delayed <= 1'b1;
        end
    end
end
assign bs_delay_active = (bs_delay_cnt != 5'd0);

assign cdc_rd_en = ~cdc_empty & decoder_ready_r & ~bs_delay_active
                 & ~block_start_delayed & ~skid_valid;

// Debug: track block_start signals
wire decoder_sees_bs = decode_status[0];
reg dbs_prev;
always @(posedge clk_rd) begin
    if (rst) dbs_prev <= 1'b0;
    else begin
        dbs_prev <= decoder_sees_bs;
        if (block_start_raw)
            $display("block_start_raw at time %t", $time);
        if (block_start_delayed)
            $display("block_start_delayed at time %t, status=0x%08x", $time, decode_status);
        if (decoder_sees_bs && !dbs_prev)
            $display("decoder block_start ROSE at time %t, status=0x%08x", $time, decode_status);
    end
end

// Debug: track decoder_fifo_ready transitions
reg dfr_prev;
always @(posedge clk_rd) begin
    if (rst) dfr_prev <= 1'b1;
    else begin
        dfr_prev <= decoder_fifo_ready;
        if (decoder_fifo_ready && !dfr_prev && rd_word_cnt < 100)
            $display("decoder_fifo_ready ROSE at rd=%d, wc=%d", rd_word_cnt, word_count);
        if (!decoder_fifo_ready && dfr_prev && rd_word_cnt < 100)
            $display("decoder_fifo_ready FELL at rd=%d, wc=%d", rd_word_cnt, word_count);
    end
end

// Debug: track stream_end_filling (decode_status[10], NOT [2]!)
wire stream_end_filling = decode_status[10];
reg sef_prev;
reg [31:0] sef_rise_count;
always @(posedge clk_rd) begin
    if (rst) begin
        sef_prev <= 1'b0;
        sef_rise_count <= 0;
    end else begin
        sef_prev <= stream_end_filling;
        if (stream_end_filling && !sef_prev) begin
            sef_rise_count <= sef_rise_count + 1;
            $display("stream_end_filling ROSE #%d at time=%t, rd=%d, wc=%d, lines=%d",
                     sef_rise_count+1, $time, rd_word_cnt, word_count, decode_status[31:16]);
        end
        if (!stream_end_filling && sef_prev)
            $display("stream_end_filling FELL at time=%t, rd=%d", $time, rd_word_cnt);
    end
end

// Decoder
rle4k_decoder_core u_decoder (
    .clk               (clk_rd),
    .rst_n             (~rst),
    .encoded_data_in   (dec_input_data),
    .encoded_data_valid(dec_input_valid),
    .block_start       (block_start_delayed),
    .stream_end        (1'b0),
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

// CRC calculation
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

function [31:0] crc32_4bytes;
    input [31:0] crc;
    input [31:0] data;
    reg [31:0] c;
    integer i;
    begin
        c = crc;
        for (i = 0; i < 4; i = i + 1)
            c = crc32_byte(c, data[i*8 +: 8]);
        crc32_4bytes = c;
    end
endfunction

reg [31:0] crc_accum;
reg [31:0] word_count;
reg [31:0] crc_w32768;

// Debug counters
reg [31:0] wr_word_cnt;
reg [31:0] rd_word_cnt;
reg [31:0] dec_in_word_cnt;
reg [31:0] skid_hit_cnt;
reg [31:0] empty_block_cnt;
reg [31:0] ready_block_cnt;
reg [31:0] delay_block_cnt;
reg [31:0] input_crc;
reg [31:0] fifo_read_crc;

integer feed_idx;
reg [2:0] state;
localparam S_RESET = 3'd0, S_START = 3'd1, S_FEED = 3'd2, S_WAIT = 3'd3, S_DONE = 3'd4;

initial begin
    rst = 1;
    adapter_data = 0;
    adapter_valid = 0;
    adapter_block_start = 0;
    cfg_block_index = 0;
    cfg_line_width = LINE_WIDTH;
    cfg_line_stride = LINE_STRIDE;
    cfg_block_height = BLOCK_HEIGHT;
    crc_accum = 32'hFFFFFFFF;
    word_count = 0;
    crc_w32768 = 0;
    feed_idx = 0;
    state = S_RESET;
    wr_word_cnt = 0;
    rd_word_cnt = 0;
    dec_in_word_cnt = 0;
    skid_hit_cnt = 0;
    empty_block_cnt = 0;
    ready_block_cnt = 0;
    delay_block_cnt = 0;
    input_crc = 32'hFFFFFFFF;
    fifo_read_crc = 32'hFFFFFFFF;

    #500;
    rst = 0;
    #200;
    state = S_START;
end

// Adapter state machine (write domain)
always @(posedge clk_wr) begin
    if (rst) begin
        adapter_block_start <= 0;
        adapter_valid <= 0;
        feed_idx <= 0;
        state <= S_RESET;
    end else begin
        adapter_block_start <= 0;

        case (state)
            S_START: begin
                adapter_block_start <= 1;
                state <= S_FEED;
            end

            S_FEED: begin
                if (cdc_full) begin
                    // Hold - backpressure
                end else if (feed_idx < STREAM_WORDS) begin
                    adapter_data <= stream_mem[feed_idx];
                    adapter_valid <= 1;
                    feed_idx <= feed_idx + 1;
                end else begin
                    adapter_valid <= 0;
                    state <= S_WAIT;
                end
            end

            S_WAIT: begin
                if (word_count >= EXPECTED_TOTAL_WORDS)
                    state <= S_DONE;
            end

            S_DONE: begin
            end
        endcase
    end
end

// Debug: count write domain words and calculate input CRC
reg [31:0] full_block_cnt;
reg cdc_full_prev;
always @(posedge clk_wr) begin
    if (rst) begin
        wr_word_cnt <= 0;
        input_crc <= 32'hFFFFFFFF;
        full_block_cnt <= 0;
        cdc_full_prev <= 0;
    end else begin
        cdc_full_prev <= cdc_full;
        if (adapter_valid & ~cdc_full) begin
            wr_word_cnt <= wr_word_cnt + 1;
            input_crc <= crc32_4bytes(input_crc, adapter_data);
        end
        if (adapter_valid & cdc_full)
            full_block_cnt <= full_block_cnt + 1;
        // Report when full first goes high
        if (cdc_full && !cdc_full_prev && wr_word_cnt > 0)
            $display("FIFO FULL at wr_word_cnt=%d", wr_word_cnt);
    end
end

// Debug: count read domain words from FIFO and calculate read CRC
always @(posedge clk_rd) begin
    if (rst) begin
        rd_word_cnt <= 0;
        fifo_read_crc <= 32'hFFFFFFFF;
    end else if (cdc_rd_en & ~cdc_block_start) begin
        rd_word_cnt <= rd_word_cnt + 1;
        fifo_read_crc <= crc32_4bytes(fifo_read_crc, cdc_data);
        // Print first 5 words and word around 1160
        if (rd_word_cnt < 5 || (rd_word_cnt >= 1158 && rd_word_cnt <= 1165))
            $display("FIFO rd[%d] = 0x%08x (expected 0x%08x)",
                     rd_word_cnt, cdc_data, stream_mem[rd_word_cnt]);
    end
end

// Debug: count decoder input words and skid hits
always @(posedge clk_rd) begin
    if (rst) begin
        dec_in_word_cnt <= 0;
        skid_hit_cnt <= 0;
        empty_block_cnt <= 0;
        ready_block_cnt <= 0;
        delay_block_cnt <= 0;
    end else begin
        if (dec_input_valid) dec_in_word_cnt <= dec_in_word_cnt + 1;
        if (decoder_rejected) skid_hit_cnt <= skid_hit_cnt + 1;
        // Track what's blocking cdc_rd_en
        if (!cdc_rd_en && !skid_valid) begin
            if (cdc_empty) empty_block_cnt <= empty_block_cnt + 1;
            else if (!decoder_ready_r) ready_block_cnt <= ready_block_cnt + 1;
            else if (bs_delay_active || block_start_delayed) delay_block_cnt <= delay_block_cnt + 1;
        end
    end
end

// CRC accumulation (read domain)
always @(posedge clk_rd) begin
    if (rst) begin
        crc_accum <= 32'hFFFFFFFF;
        word_count <= 0;
        crc_w32768 <= 0;
    end else if (word_decoded_valid && !block_done) begin
        crc_accum <= crc32_64bytes(crc_accum, decoded_data_out);
        word_count <= word_count + 1;
        if (word_count == 32768)
            crc_w32768 <= crc32_64bytes(crc_accum, decoded_data_out);
    end
end

// Debug: report when block_done first fires
reg block_done_reported;
reg block_done_prev;
wire [15:0] lines_decoded = decode_status[31:16];
always @(posedge clk_rd) begin
    if (rst) begin
        block_done_reported <= 1'b0;
        block_done_prev <= 1'b0;
    end else begin
        block_done_prev <= block_done;
        // Detect rising edge of block_done
        if (block_done && !block_done_prev && !block_done_reported) begin
            $display("block_done RISING at word_count=%d, rd_word_cnt=%d, dec_in=%d, lines=%d, status=0x%08x",
                     word_count, rd_word_cnt, dec_in_word_cnt, lines_decoded, decode_status);
            block_done_reported <= 1'b1;
        end
    end
end

// Debug: track output_line_end equivalently via word_count increments
reg [31:0] prev_word_count;
reg [31:0] line_end_count;
always @(posedge clk_rd) begin
    if (rst) begin
        prev_word_count <= 0;
        line_end_count <= 0;
    end else begin
        prev_word_count <= word_count;
        // Each line is 128 words, so track line boundaries
        if (word_count > 0 && word_count % 128 == 0 && word_count != prev_word_count)
            line_end_count <= line_end_count + 1;
    end
end

// Report - Complete when output count reached
always @(posedge clk_rd) begin
    if (state == S_DONE && word_count >= EXPECTED_TOTAL_WORDS) begin
        $display("=== CDC SINGLE BLOCK TEST ===");
        $display("Debug counters:");
        $display("  wr_word_cnt:     %d (expected %d)", wr_word_cnt, STREAM_WORDS);
        $display("  rd_word_cnt:     %d", rd_word_cnt);
        $display("  dec_in_word_cnt: %d", dec_in_word_cnt);
        $display("  skid_hit_cnt:    %d", skid_hit_cnt);
        $display("  empty_block_cnt: %d", empty_block_cnt);
        $display("  ready_block_cnt: %d", ready_block_cnt);
        $display("  delay_block_cnt: %d", delay_block_cnt);
        $display("  input_crc:       0x%08x", input_crc);
        $display("  fifo_read_crc:   0x%08x (should match input_crc if complete)", fifo_read_crc);
        $display("Word count: %d (expected %d) %s", word_count, EXPECTED_TOTAL_WORDS,
                 (word_count == EXPECTED_TOTAL_WORDS) ? "PASS" : "FAIL");
        $display("CRC at w32768: 0x%08x (expected 0x%08x) %s", crc_w32768, EXPECTED_W32768_CRC,
                 (crc_w32768 == EXPECTED_W32768_CRC) ? "PASS" : "FAIL");
        $display("CRC accum: 0x%08x (expected 0x%08x) %s", crc_accum, EXPECTED_CRC_ACCUM,
                 (crc_accum == EXPECTED_CRC_ACCUM) ? "PASS" : "FAIL");

        if (word_count == EXPECTED_TOTAL_WORDS && crc_w32768 == EXPECTED_W32768_CRC && crc_accum == EXPECTED_CRC_ACCUM)
            $display("*** TEST PASSED ***");
        else
            $display("*** TEST FAILED ***");
        $finish;
    end
end

initial begin
    #200000000;
    $display("TIMEOUT!");
    $finish;
end

endmodule
