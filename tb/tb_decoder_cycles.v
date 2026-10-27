// ============================================================================
// tb_decoder_cycles -- per-block cycle accounting for rle4k_decoder_core
// ============================================================================
// Measurement harness, not a gate. Feeds ONE block through the decoder core
// with an input that never starves and a downstream that never backpressures,
// so the cycle count it reports is the decoder's intrinsic per-block time --
// the thing the board's block-period floor has to be compared against.
//
// Every cycle between the first decoded word and block_done is charged to
// exactly one bucket, so the buckets sum to the total and the accounting can
// be checked rather than believed.
//
// Stimulus comes from tb/sim_data_e9/ (written by .temp/e9_run.ps1 from
// gen_sim_data output) so the same TB measures any block of the real dataset.
// ============================================================================
`timescale 1ns / 1ps

module tb_decoder_cycles;

localparam MAX_STREAM_WORDS = 32768;
localparam PARAM_WORDS      = 8;

reg clk;
initial clk = 0;
always #4 clk = ~clk;          // 125 MHz

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
reg  [31:0] cfg_strip_line_total_r;
reg  [31:0] cfg_rle_payload_bytes_r;
reg         strip_byte_cnt_rst_sig;

reg [31:0] stream_mem [0:MAX_STREAM_WORDS-1];
reg [31:0] params     [0:PARAM_WORDS-1];

reg [31:0] p_stream_words;
reg [31:0] p_block_height;
reg [31:0] p_expected_words;
reg [31:0] p_expected_crc;
reg [31:0] p_line_width;
reg [31:0] p_line_stride;
reg [31:0] p_payload_bytes;

initial begin
    $readmemh("../tb/sim_data_e9/params.hex", params);
    $readmemh("../tb/sim_data_e9/stream_data.hex", stream_mem);
    p_stream_words   = params[0];
    p_block_height   = params[1];
    p_expected_words = params[2];
    p_expected_crc   = params[3];
    p_line_width     = params[4];
    p_line_stride    = params[5];
    p_payload_bytes  = params[6];
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
    .cfg_block_index   (32'd0),
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
// CRC32 over decoded words -- proves the measured run actually decoded right
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
reg [31:0] crc32_next;
integer crc_j;
always @(*) begin
    crc32_next = crc32_accum;
    for (crc_j = 0; crc_j < 64; crc_j = crc_j + 1)
        crc32_next = crc32_byte(crc32_next, decoded_data_out[crc_j*8 +: 8]);
end

// ============================================================================
// Feed FSM -- input is deliberately never allowed to starve
// ============================================================================
localparam S_RESET = 2'd0;
localparam S_FEED  = 2'd1;
localparam S_DONE  = 2'd2;

reg [1:0]  state;
reg [31:0] feed_idx;
reg [31:0] wait_cnt;
reg        block_done_prev;

// ---- accounting ----
reg        measuring;
reg [63:0] cyc_total;        // first decoded word .. block_done
reg [63:0] cyc_lead_in;      // feed start .. first decoded word
reg [63:0] n_words;
reg [63:0] idle_starved;     // code FIFO empty
reg [63:0] idle_line_end;    // line-end padding / flush bookkeeping
reg [63:0] idle_parser;      // waiting on the parser handshake
reg [63:0] idle_backpressure;// accumulator not ready
reg [63:0] idle_other;
reg [63:0] n_codes;
reg [63:0] n_codes_short;    // length <= 512 bits: cannot sustain 1 word/cycle
reg [63:0] n_codes_long;
reg [63:0] n_line_ends;
reg [63:0] bits_short;
reg [63:0] bits_long;
// Idle per tenth of the block, to see whether the stalls sit at the start, the
// end, or are spread through the payload.
reg [63:0] idle_decile [0:9];
integer    di;
wire [63:0] decile_idx_w = (n_words * 64'd10) / p_expected_words;
wire [3:0]  decile_idx   = (decile_idx_w > 64'd9) ? 4'd9 : decile_idx_w[3:0];

// DUT internals used for attribution
wire dut_fifo_code_valid = u_decoder.fifo_code_valid;
wire dut_parsed_valid    = u_decoder.parsed_valid;
wire dut_parsed_ready    = u_decoder.parsed_ready;
wire dut_need_pad        = u_decoder.need_line_end_padding;
wire dut_pad_pending     = u_decoder.need_line_end_padding_pending;
wire dut_pad_done        = u_decoder.padding_completed;
wire dut_acc_ready       = u_decoder.accumulator_output_ready;
wire dut_out_valid       = u_decoder.decoder_output_valid;
wire dut_pad_valid       = u_decoder.padding_output_valid;
wire dut_line_end        = u_decoder.output_line_end;
wire [11:0] dut_remaining = u_decoder.remaining_length;
wire [11:0] dut_code_len  = u_decoder.code_length;

always @(posedge clk) begin
    if (!rst_n) begin
        measuring         <= 1'b0;
        cyc_total         <= 64'd0;
        cyc_lead_in       <= 64'd0;
        n_words           <= 64'd0;
        idle_starved      <= 64'd0;
        idle_line_end     <= 64'd0;
        idle_parser       <= 64'd0;
        idle_backpressure <= 64'd0;
        idle_other        <= 64'd0;
        n_codes           <= 64'd0;
        n_codes_short     <= 64'd0;
        n_codes_long      <= 64'd0;
        n_line_ends       <= 64'd0;
        bits_short        <= 64'd0;
        bits_long         <= 64'd0;
        crc32_accum       <= 32'hFFFFFFFF;
        for (di = 0; di < 10; di = di + 1) idle_decile[di] <= 64'd0;
    end else begin
        if (state == S_FEED && !measuring && !word_decoded_valid)
            cyc_lead_in <= cyc_lead_in + 64'd1;

        if (word_decoded_valid)
            measuring <= 1'b1;

        if (measuring || word_decoded_valid) begin
            cyc_total <= cyc_total + 64'd1;
            if (word_decoded_valid) begin
                n_words     <= n_words + 64'd1;
                crc32_accum <= crc32_next;
            end else begin
                idle_decile[decile_idx] <= idle_decile[decile_idx] + 64'd1;
                // Priority order is the causal order: a cycle can satisfy more
                // than one predicate, and charging it twice would break the sum.
                if (!dut_fifo_code_valid)
                    idle_starved <= idle_starved + 64'd1;
                else if (dut_need_pad || dut_pad_pending || dut_pad_done || dut_line_end)
                    idle_line_end <= idle_line_end + 64'd1;
                else if (!dut_acc_ready)
                    idle_backpressure <= idle_backpressure + 64'd1;
                else if (!dut_parsed_valid && dut_remaining == 12'd0)
                    idle_parser <= idle_parser + 64'd1;
                else
                    idle_other <= idle_other + 64'd1;
            end
        end

        if (dut_parsed_valid && dut_parsed_ready) begin
            n_codes <= n_codes + 64'd1;
            if (dut_code_len <= 12'd512) begin
                n_codes_short <= n_codes_short + 64'd1;
                bits_short    <= bits_short + {52'd0, dut_code_len};
            end else begin
                n_codes_long <= n_codes_long + 64'd1;
                bits_long    <= bits_long + {52'd0, dut_code_len};
            end
        end

        if (dut_line_end)
            n_line_ends <= n_line_ends + 64'd1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state                   <= S_RESET;
        encoded_data_in         <= 32'd0;
        encoded_data_valid      <= 1'b0;
        block_start             <= 1'b0;
        stream_end_sig          <= 1'b0;
        cfg_line_width          <= 32'd65536;
        cfg_line_stride         <= 32'd65536;
        cfg_block_height        <= 32'd512;
        cfg_strip_line_total_r  <= 32'd512;
        cfg_rle_payload_bytes_r <= 32'd0;
        strip_byte_cnt_rst_sig  <= 1'b0;
        feed_idx                <= 32'd0;
        wait_cnt                <= 32'd0;
        block_done_prev         <= 1'b0;
    end else begin
        block_start            <= 1'b0;
        strip_byte_cnt_rst_sig <= 1'b0;
        block_done_prev        <= block_done;

        if (encoded_data_valid && !decoder_fifo_ready) begin
            // hold data and valid until the input FIFO takes it
        end else begin
            encoded_data_valid <= 1'b0;
        end

        case (state)
            S_RESET: begin
                wait_cnt <= wait_cnt + 32'd1;
                if (wait_cnt == 32'd0) begin
                    strip_byte_cnt_rst_sig  <= 1'b1;
                    cfg_line_width          <= p_line_width;
                    cfg_line_stride         <= p_line_stride;
                    cfg_block_height        <= p_block_height;
                    cfg_strip_line_total_r  <= p_block_height;
                    cfg_rle_payload_bytes_r <= p_payload_bytes;
                end
                if (wait_cnt == 32'd10) begin
                    block_start <= 1'b1;
                    state       <= S_FEED;
                end
            end

            S_FEED: begin
                if (decoder_fifo_ready && feed_idx < p_stream_words &&
                    !(encoded_data_valid && !decoder_fifo_ready)) begin
                    encoded_data_in    <= stream_mem[feed_idx];
                    encoded_data_valid <= 1'b1;
                    feed_idx           <= feed_idx + 32'd1;
                end
                if (block_done && !block_done_prev) begin
                    wait_cnt <= 32'd0;
                    state    <= S_DONE;
                end
            end

            S_DONE: begin
                report;
                $finish;
            end
        endcase
    end
end

task report;
    reg [63:0] idle_sum;
    real us_total, us_floor;
    begin
        idle_sum = idle_starved + idle_line_end + idle_parser +
                   idle_backpressure + idle_other;
        us_total = cyc_total / 125.0;
        us_floor = n_words / 125.0;
        $display("");
        $display("E9_BEGIN");
        $display("E9 payload_bytes    %0d", p_payload_bytes);
        $display("E9 codes            %0d", n_codes);
        $display("E9 codes_short      %0d", n_codes_short);
        $display("E9 codes_long       %0d", n_codes_long);
        $display("E9 bits_short       %0d", bits_short);
        $display("E9 bits_long        %0d", bits_long);
        $display("E9 words            %0d (expected %0d)", n_words, p_expected_words);
        $display("E9 line_ends        %0d (expected %0d)", n_line_ends, p_block_height);
        $display("E9 lead_in_cyc      %0d", cyc_lead_in);
        $display("E9 total_cyc        %0d", cyc_total);
        $display("E9 idle_cyc         %0d", idle_sum);
        $display("E9   idle_starved   %0d", idle_starved);
        $display("E9   idle_line_end  %0d", idle_line_end);
        $display("E9   idle_parser    %0d", idle_parser);
        $display("E9   idle_backpress %0d", idle_backpressure);
        $display("E9   idle_other     %0d", idle_other);
        $display("E9 sum_check        %0d (words+idle, must equal total_cyc)",
                 n_words + idle_sum);
        $display("E9 idle_decile      %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                 idle_decile[0], idle_decile[1], idle_decile[2], idle_decile[3],
                 idle_decile[4], idle_decile[5], idle_decile[6], idle_decile[7],
                 idle_decile[8], idle_decile[9]);
        $display("E9 us_total         %0.3f", us_total);
        $display("E9 us_floor         %0.3f", us_floor);
        $display("E9 crc_accum        0x%08x (expected 0x%08x) %s",
                 crc32_accum, p_expected_crc,
                 (crc32_accum == p_expected_crc) ? "PASS" : "FAIL");
        $display("E9_END");
        if (crc32_accum != p_expected_crc)
            $display("E9 RESULT FAIL crc mismatch");
        else if (n_words != p_expected_words)
            $display("E9 RESULT FAIL word count");
        else if (n_words + idle_sum != cyc_total)
            $display("E9 RESULT FAIL accounting does not sum");
        else
            $display("E9 RESULT PASS");
    end
endtask

initial begin
    rst_n = 0;
    #100;
    rst_n = 1;
end

initial begin
    #500_000_000;
    $display("E9 RESULT FAIL timeout at %0t", $time);
    $finish;
end

endmodule
