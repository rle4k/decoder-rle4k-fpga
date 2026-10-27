// Minimal debug testbench: feed compressed data, print first 256 outputs
`timescale 1ns / 1ps

module tb_decoder_debug;

reg clk = 0;
always #4 clk = ~clk;
reg rst_n = 0;

reg [31:0] encoded_data_in;
reg        encoded_data_valid;
reg        block_start;
wire       decoder_fifo_ready;

reg [31:0] cfg_block_index;
reg [31:0] cfg_line_width;
reg [31:0] cfg_line_stride;
reg [31:0] cfg_block_height;

wire [511:0] decoded_data_out;
wire         word_decoded_valid;
reg          word_decoded_ready;

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

// Internal signal probes
wire [7:0]  probe_code_byte  = u_dut.code_byte;
wire        probe_code_valid = u_dut.code_byte_valid;
wire        probe_code_ready = u_dut.code_byte_ready;
wire [7:0]  probe_fifo_out = u_dut.u_input_fifo.data_out;
wire        probe_fifo_valid = u_dut.u_input_fifo.valid_out;
wire        probe_fifo_ready = u_dut.u_input_fifo.ready_in;
wire        probe_parsed_valid = u_dut.parsed_valid;
wire        probe_parsed_ready = u_dut.parsed_ready;
wire        probe_code_color = u_dut.code_color;
wire [11:0] probe_code_length = u_dut.code_length;
wire        probe_is_line_end = u_dut.is_line_end;
wire        probe_decoder_ready = u_dut.decoder_ready;
wire        probe_need_pad = u_dut.need_line_end_padding;
wire [31:0] probe_line_bits = u_dut.line_bits_counter;
wire [11:0] probe_remaining = u_dut.remaining_length;
wire        probe_accum_valid = u_dut.accumulator_output_valid;
wire [9:0]  probe_accum_len   = u_dut.accumulator_output_length;
wire        probe_accum_ready = u_dut.accumulator_output_ready;
wire [9:0]  probe_accum_bits  = u_dut.accumulated_bits;
wire        probe_output_le   = u_dut.output_line_end;
wire [31:0] probe_line_count  = u_dut.decoded_block_line_count;
wire        probe_param_err   = u_dut.param_error_flag;
wire [7:0]  probe_error_code  = u_dut.error_code;

parameter MAX_STIM = 65536;
reg [31:0] stim_data [0:MAX_STIM-1];

integer param_fd;
integer width_bits, stride_bits, height, num_words;
integer out_idx;
integer i;

initial begin
    encoded_data_in   = 0;
    encoded_data_valid = 0;
    block_start       = 0;
    word_decoded_ready = 1;
    cfg_block_index   = 0;
    cfg_line_width    = 0;
    cfg_line_stride   = 0;
    cfg_block_height  = 0;
    out_idx           = 0;

    param_fd = $fopen("stim_params.txt", "r");
    if (param_fd == 0) begin $display("ERROR: cannot open stim_params.txt"); $finish; end
    $fscanf(param_fd, "%d %d %d %d\n", width_bits, stride_bits, height, num_words);
    $fclose(param_fd);
    $display("Params: width=%0d stride=%0d height=%0d words=%0d",
             width_bits, stride_bits, height, num_words);

    $readmemh("stim_data.hex", stim_data);

    // Reset
    rst_n = 0;
    repeat(10) @(posedge clk);
    rst_n = 1;
    repeat(5) @(posedge clk);

    // Configure
    cfg_block_index = 0;
    cfg_line_width  = width_bits;
    cfg_line_stride = stride_bits;
    cfg_block_height = height;
    @(posedge clk);

    $display("T=%0t Config set: w=%0d s=%0d h=%0d", $time, cfg_line_width, cfg_line_stride, cfg_block_height);

    // block_start pulse
    block_start = 1;
    @(posedge clk);
    $display("T=%0t block_start=1 -> param_err=%b error_code=%02h", $time, probe_param_err, probe_error_code);
    block_start = 0;
    @(posedge clk);
    $display("T=%0t block_start=0 -> param_err=%b error_code=%02h block_done=%b", $time, probe_param_err, probe_error_code, block_done);

    // Feed first 50 words and watch carefully
    $display("--- Feeding data ---");
    for (i = 0; i < num_words && i < 100; i = i + 1) begin
        encoded_data_in   = stim_data[i];
        encoded_data_valid = 1;
        @(posedge clk);
        if (i < 10)
            $display("T=%0t Feed[%0d]=%08h fifo_rdy=%b", $time, i, stim_data[i], decoder_fifo_ready);
        while (!decoder_fifo_ready) begin
            encoded_data_valid = 0;
            @(posedge clk);
            encoded_data_valid = 1;
        end
    end
    // Feed remaining
    for (i = 100; i < num_words; i = i + 1) begin
        encoded_data_in   = stim_data[i];
        encoded_data_valid = 1;
        @(posedge clk);
        while (!decoder_fifo_ready) begin
            encoded_data_valid = 0;
            @(posedge clk);
            encoded_data_valid = 1;
        end
    end
    encoded_data_valid = 0;
    $display("T=%0t All %0d words fed", $time, num_words);

    // Wait for output to settle or block_done
    begin : wait_blk
        integer w;
        for (w = 0; w < 2000000; w = w + 1) begin
            @(posedge clk);
            if (block_done) begin
                $display("T=%0t block_done after %0d extra cycles, out_idx=%0d, lines=%0d",
                         $time, w, out_idx, probe_line_count);
                disable wait_blk;
            end
        end
        $display("T=%0t TIMEOUT: block_done=0, out_idx=%0d, lines=%0d, line_bits=%0d, remaining=%0d, need_pad=%b, accum_bits=%0d, decoder_ready=%b",
                 $time, out_idx, probe_line_count, probe_line_bits, probe_remaining,
                 probe_need_pad, probe_accum_bits, probe_decoder_ready);
    end

    $display("Total outputs: %0d, block_done=%b", out_idx, block_done);
    repeat(100) @(posedge clk);
    $finish;
end

// Monitor FIFO byte output (first N)
reg [31:0] fifo_byte_count = 0;
always @(posedge clk) begin
    if (rst_n && probe_fifo_valid && probe_fifo_ready) begin
        if (fifo_byte_count < 30)
            $display("T=%0t FIFO_BYTE[%0d]: 0x%02h (bit7=%b bit6=%b)", $time,
                     fifo_byte_count, probe_fifo_out, probe_fifo_out[7], probe_fifo_out[6]);
        fifo_byte_count <= fifo_byte_count + 1;
    end
end

// Monitor parsed codes (first N)
reg [31:0] parse_count = 0;
always @(posedge clk) begin
    if (rst_n && probe_parsed_valid && probe_parsed_ready) begin
        if (parse_count < 30)
            $display("T=%0t PARSED[%0d]: color=%b len=%0d is_le=%b  line_bits=%0d",
                     $time, parse_count, probe_code_color, probe_code_length, probe_is_line_end,
                     probe_line_bits);
        parse_count <= parse_count + 1;
    end
end

// Monitor outputs (first N)
always @(posedge clk) begin
    if (rst_n && word_decoded_valid && word_decoded_ready) begin
        if (out_idx < 20)
            $display("T=%0t OUT[%0d]: %0128h  lines=%0d line_bits=%0d",
                     $time, out_idx, decoded_data_out, probe_line_count, probe_line_bits);
        out_idx = out_idx + 1;
    end
end

// Monitor line_end
always @(posedge clk) begin
    if (rst_n && probe_output_le) begin
        if (probe_line_count < 5)
            $display("T=%0t LINE_END: count=%0d->%0d  line_bits=%0d",
                     $time, probe_line_count, probe_line_count+1, probe_line_bits);
    end
end

endmodule
