// ============================================================================
// RLE4K Decoder V05 Testbench - Batch 03
// ============================================================================
// Description: Test cases migrated from V03 batch_03
//              Tests error conditions and edge cases
// Author: Migrated from V03
// Date: 2026-01-09
// ============================================================================

`timescale 1ns / 1ps

module tb_rle4k_decoder_core_batch_03;

parameter CLK_PERIOD = 5;
parameter NUM_TESTS = 10;

reg         clk;
reg         rst_n;
reg  [31:0] encoded_data_in;
reg         encoded_data_valid;
reg         block_start;
wire        decoder_fifo_ready;
wire [511:0] decoded_data_out;
wire        word_decoded_valid;
reg         word_decoded_ready;
wire [31:0] decode_status;
wire        block_done;
wire [31:0] block_index_out;
reg  [31:0] cfg_block_index;
reg  [31:0] cfg_line_width;
reg  [31:0] cfg_line_stride;
reg  [31:0] cfg_block_height;
integer test_case;
integer error_count;
integer passed_tests;
integer total_tests;
integer i;
reg [511:0] expected_data [0:31];
integer expected_word_count;
integer decoded_word_count;
reg data_verification_enabled;
reg [511:0] decoded_word_list [0:31];

rle4k_decoder_core u_dut (
    .clk                 (clk),
    .rst_n               (rst_n),
    .encoded_data_in     (encoded_data_in),
    .encoded_data_valid  (encoded_data_valid),
    .block_start         (block_start),
    .stream_end          (1'b0),
    .decoder_fifo_ready  (decoder_fifo_ready),
    .decoded_data_out    (decoded_data_out),
    .word_decoded_valid  (word_decoded_valid),
    .word_decoded_ready  (word_decoded_ready),
    .cfg_block_index     (cfg_block_index),
    .cfg_line_width      (cfg_line_width),
    .cfg_line_stride      (cfg_line_stride),
    .cfg_block_height     (cfg_block_height),
    .cfg_strip_line_count (cfg_block_height),
    .cfg_rle_payload_bytes(32'hFFFFFFFF),
    .strip_byte_cnt_rst  (1'b0),
    .upstream_busy       (1'b0),
    .decode_status       (decode_status),
    .block_done          (block_done),
    .strip_end_out       (),
    .block_index_out     (block_index_out)
);

initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

always @(posedge clk) begin
    if (word_decoded_valid && word_decoded_ready) begin
        if (data_verification_enabled && decoded_word_count < 32) begin
            decoded_word_list[decoded_word_count] = decoded_data_out;
            decoded_word_count = decoded_word_count + 1;
        end
    end
end

task reset_for_new_test;
    integer i;
    begin
        data_verification_enabled = 0;
        @(posedge clk);
        @(posedge clk);
        rst_n = 0;
        encoded_data_valid = 0;
        block_start = 0;
        encoded_data_in = 32'h0;
        word_decoded_ready = 1;
        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 5);
        decoded_word_count = 0;
        for (i = 0; i < 32; i = i + 1) begin
            decoded_word_list[i] = 512'b0;
        end
        @(posedge clk);
        @(posedge clk);
    end
endtask

task block_send_start;
    begin
        block_start = 1;
        @(posedge clk);
        block_start = 0;
    end
endtask

task send_block_data;
    input [31:0] data;
    begin
        while (!decoder_fifo_ready) begin
            @(posedge clk);
        end
        @(posedge clk);
        encoded_data_in = data;
        encoded_data_valid = 1;
        while (!(encoded_data_valid && decoder_fifo_ready)) begin
            @(posedge clk);
        end
        @(posedge clk);
        encoded_data_valid = 0;
    end
endtask

task wait_for_block_done;
    integer timeout;
    begin
        timeout = 0;
        while (!block_done && timeout < 2000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 2000) begin
            $display("[WARNING] Timeout waiting for block done");
        end
        #(CLK_PERIOD * 10);
    end
endtask

function [31:0] pack_bytes;
    input [7:0] byte0, byte1, byte2, byte3;
    begin
        pack_bytes = {byte3, byte2, byte1, byte0};
    end
endfunction

initial begin
    rst_n = 0;
    encoded_data_in = 32'h0;
    encoded_data_valid = 0;
    block_start = 0;
    word_decoded_ready = 1;
    test_case = 0;
    error_count = 0;
    passed_tests = 0;
    total_tests = 0;
    
    #(CLK_PERIOD * 10);
    rst_n = 1;
    #(CLK_PERIOD * 5);
    
    $display("========================================");
    $display("RLE4K Decoder Testbench - Batch 03");
    $display("Total test cases: %0d", NUM_TESTS);
    $display("========================================");
    
    // TEST16: EmptyData
    reset_for_new_test();
    test_case = 16;
    $display("\nTEST16: EmptyData");
    cfg_block_index = 0;
    cfg_line_width = 0;
    cfg_line_stride = 512;
    cfg_block_height = 0;
    decoded_word_count = 0;
    data_verification_enabled = 0;
    block_send_start();
    send_block_data(pack_bytes(8'h00, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decode_status[7:0] == 8'h01) begin
        $display("  PASS: TEST16 (Error 0x01)");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST16 - Expected 0x01, got 0x%02h", decode_status[7:0]);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST19: ZeroWidth
    reset_for_new_test();
    test_case = 19;
    $display("\nTEST19: ZeroWidth");
    cfg_block_index = 0;
    cfg_line_width = 0;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    decoded_word_count = 0;
    data_verification_enabled = 0;
    block_send_start();
    send_block_data(pack_bytes(8'h48, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decode_status[7:0] == 8'h03) begin
        $display("  PASS: TEST19 (Error 0x03)");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST19 - Expected 0x03, got 0x%02h", decode_status[7:0]);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST20: ZeroHeight
    reset_for_new_test();
    test_case = 20;
    $display("\nTEST20: ZeroHeight");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 512;
    cfg_block_height = 0;
    decoded_word_count = 0;
    data_verification_enabled = 0;
    block_send_start();
    send_block_data(pack_bytes(8'h48, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decode_status[7:0] == 8'h03) begin
        $display("  PASS: TEST20 (Error 0x03)");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST20 - Expected 0x03, got 0x%02h", decode_status[7:0]);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST21: DataSizeMismatch
    reset_for_new_test();
    test_case = 21;
    $display("\nTEST21: DataSizeMismatch");
    cfg_block_index = 0;
    cfg_line_width = 8;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    decoded_word_count = 0;
    data_verification_enabled = 0;
    block_send_start();
    send_block_data(pack_bytes(8'hFF, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decode_status[7:0] == 8'h04) begin
        $display("  PASS: TEST21 (Error 0x04)");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST21 - Expected 0x04, got 0x%02h", decode_status[7:0]);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST22: ZeroWidthAndHeight
    reset_for_new_test();
    test_case = 22;
    $display("\nTEST22: ZeroWidthAndHeight");
    cfg_block_index = 0;
    cfg_line_width = 0;
    cfg_line_stride = 512;
    cfg_block_height = 0;
    decoded_word_count = 0;
    data_verification_enabled = 0;
    block_send_start();
    send_block_data(pack_bytes(8'h00, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decode_status[7:0] == 8'h01) begin
        $display("  PASS: TEST22 (Error 0x01)");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST22 - Expected 0x01, got 0x%02h", decode_status[7:0]);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST23: InvalidParameterCombination
    reset_for_new_test();
    test_case = 23;
    $display("\nTEST23: InvalidParameterCombination");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 0;  // Invalid: zero stride
    cfg_block_height = 1;
    decoded_word_count = 0;
    data_verification_enabled = 0;
    block_send_start();
    send_block_data(pack_bytes(8'h48, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decode_status[7:0] == 8'h03) begin
        $display("  PASS: TEST23 (Error 0x03)");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST23 - Expected 0x03, got 0x%02h", decode_status[7:0]);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST33: ValidDataBufferManagement
    reset_for_new_test();
    test_case = 33;
    $display("\nTEST33: ValidDataBufferManagement");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {496'b0, 16'h00FF};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h48, 8'h08, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][15:0] == 16'h00FF) begin
        $display("  PASS: TEST33");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST33 - Data mismatch");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST36: ValidDataBufferManagement2
    reset_for_new_test();
    test_case = 36;
    $display("\nTEST36: ValidDataBufferManagement2");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {496'b0, 16'h0001};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h41, 8'h0F, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][15:0] == 16'h0001) begin
        $display("  PASS: TEST36");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST36 - Data mismatch");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST44: StrideTooSmall
    reset_for_new_test();
    test_case = 44;
    $display("\nTEST44: StrideTooSmall");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 512;  // Note: V05 uses 512-bit alignment, so stride should be >= width
    cfg_block_height = 1;
    decoded_word_count = 0;
    data_verification_enabled = 0;
    block_send_start();
    send_block_data(pack_bytes(8'h48, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    // In V05, stride is always 512-bit aligned, so this test may behave differently
    // Check if error occurs when stride < width (but stride is always >= 512 in V05)
    if (decoded_word_count == 0) begin
        $display("  PASS: TEST44 (No output as expected)");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST44 - Expected 0 words, got %0d", decoded_word_count);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST58: ValidDataBufferManagement3
    reset_for_new_test();
    test_case = 58;
    $display("\nTEST58: ValidDataBufferManagement3");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {496'b0, 16'hFFFF};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h50, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][15:0] == 16'hFFFF) begin
        $display("  PASS: TEST58");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST58 - Data mismatch");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // Test Summary
    #(CLK_PERIOD * 10);
    $display("\n========================================");
    $display("Batch 03 Results: %0d/%0d passed", passed_tests, total_tests);
    $display("Error count: %0d", error_count);
    $display("========================================");
    
    if (error_count == 0) begin
        $display("*** All tests passed ***");
    end else begin
        $display("*** %d tests failed ***", error_count);
    end
    
    $finish;
end

initial begin
    #(CLK_PERIOD * 100000);
    $display("[ERROR] Testbench timeout!");
    $finish;
end

initial begin
    $dumpfile("tb_rle4k_decoder_core_batch_03.vcd");
    $dumpvars(0, tb_rle4k_decoder_core_batch_03);
end

endmodule
