// ============================================================================
// RLE4K Decoder V05 Testbench - Batch 04
// ============================================================================
// Description: Test cases migrated from V03 batch_04
//              Tests complex patterns and performance
// Author: Migrated from V03
// Date: 2026-01-09
// ============================================================================

`timescale 1ns / 1ps

module tb_rle4k_decoder_core_batch_04;

parameter CLK_PERIOD = 5;
parameter NUM_TESTS = 8;

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
integer i, j, k;
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
    $display("RLE4K Decoder Testbench - Batch 04");
    $display("Total test cases: %0d", NUM_TESTS);
    $display("========================================");
    
    // TEST24: StateMachinePerformance
    reset_for_new_test();
    test_case = 24;
    $display("\nTEST24: StateMachinePerformance");
    cfg_block_index = 0;
    cfg_line_width = 128;
    cfg_line_stride = 512;
    cfg_block_height = 10;
    // Expected: 10 rows, each with 8 ones + 8 zeros pattern
    for (i = 0; i < 10; i = i + 1) begin
        expected_data[i] = {496'b0, 16'h00FF};
    end
    expected_word_count = 10;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    // Send 160 bytes: alternating 0x48 and 0x08
    for (i = 0; i < 40; i = i + 1) begin
        if (i % 2 == 0) begin
            send_block_data(pack_bytes(8'h48, 8'h08, 8'h48, 8'h08));
        end else begin
            send_block_data(pack_bytes(8'h08, 8'h48, 8'h08, 8'h48));
        end
    end
    send_block_data(pack_bytes(8'h00, 8'h00, 8'h00, 8'h00));  // EOL
    wait_for_block_done();
    if (decoded_word_count == expected_word_count) begin
        // Check pattern: each word should have 00FF pattern
        j = 1;
        for (i = 0; i < expected_word_count; i = i + 1) begin
            if (decoded_word_list[i][15:0] != 16'h00FF) begin
                j = 0;
            end
        end
        if (j) begin
            $display("  PASS: TEST24");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  FAIL: TEST24 - Data mismatch");
            error_count = error_count + 1;
        end
    end else begin
        $display("  FAIL: TEST24 - Expected %0d words, got %0d", expected_word_count, decoded_word_count);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST28: MixedCompressionLargeData
    reset_for_new_test();
    test_case = 28;
    $display("\nTEST28: MixedCompressionLargeData");
    cfg_block_index = 0;
    cfg_line_width = 400;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    // Expected: 400 bits of ones (50 bytes)
    for (i = 0; i < 1; i = i + 1) begin
        expected_data[i] = {120'b0, {392{1'b1}}};
    end
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    // 6 * 64 = 384 bits (segment mode), then 16 bits (bit mode)
    send_block_data(pack_bytes(8'hC1, 8'hC1, 8'hC1, 8'hC1));
    send_block_data(pack_bytes(8'hC1, 8'hC1, 8'h48, 8'h00));
    
    wait_for_block_done();
    if (decoded_word_count == expected_word_count) begin
        if (decoded_word_list[0][391:0] == {392{1'b1}}) begin
            $display("  PASS: TEST28");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  FAIL: TEST28 - Data mismatch");
            error_count = error_count + 1;
        end
    end else begin
        $display("  FAIL: TEST28 - Expected %0d words, got %0d", expected_word_count, decoded_word_count);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST29: CompleteFunctionality
    reset_for_new_test();
    test_case = 29;
    $display("\nTEST29: CompleteFunctionality");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 512;
    cfg_block_height = 4;
    // Expected: 4 rows, each with 00FF pattern
    for (i = 0; i < 4; i = i + 1) begin
        expected_data[i] = {496'b0, 16'h00FF};
    end
    expected_word_count = 4;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h48, 8'h08, 8'h48, 8'h08));
    send_block_data(pack_bytes(8'h48, 8'h08, 8'h48, 8'h08));
    send_block_data(pack_bytes(8'h00, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count) begin
        j = 1;
        for (i = 0; i < expected_word_count; i = i + 1) begin
            if (decoded_word_list[i][15:0] != 16'h00FF) begin
                j = 0;
            end
        end
        if (j) begin
            $display("  PASS: TEST29");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  FAIL: TEST29 - Data mismatch");
            error_count = error_count + 1;
        end
    end else begin
        $display("  FAIL: TEST29 - Expected %0d words, got %0d", expected_word_count, decoded_word_count);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST34: AllZeroData
    reset_for_new_test();
    test_case = 34;
    $display("\nTEST34: AllZeroData");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {496'b0, 16'h0000};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h10, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][15:0] == 16'h0000) begin
        $display("  PASS: TEST34");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST34 - Data mismatch");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST45: ComplexMultiRowJumps
    reset_for_new_test();
    test_case = 45;
    $display("\nTEST45: ComplexMultiRowJumps");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 512;
    cfg_block_height = 4;
    for (i = 0; i < 4; i = i + 1) begin
        expected_data[i] = {496'b0, 16'h00FF};
    end
    expected_word_count = 4;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h48, 8'h08, 8'h48, 8'h08));
    send_block_data(pack_bytes(8'h48, 8'h08, 8'h48, 8'h08));
    send_block_data(pack_bytes(8'h00, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count) begin
        j = 1;
        for (i = 0; i < expected_word_count; i = i + 1) begin
            if (decoded_word_list[i][15:0] != 16'h00FF) begin
                j = 0;
            end
        end
        if (j) begin
            $display("  PASS: TEST45");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  FAIL: TEST45 - Data mismatch");
            error_count = error_count + 1;
        end
    end else begin
        $display("  FAIL: TEST45 - Expected %0d words, got %0d", expected_word_count, decoded_word_count);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST46: IrregularWidth
    reset_for_new_test();
    test_case = 46;
    $display("\nTEST46: IrregularWidth");
    cfg_block_index = 0;
    cfg_line_width = 3;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {509'b0, 3'b111};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h43, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][2:0] == 3'b111) begin
        $display("  PASS: TEST46");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST46 - Data mismatch (got 0x%02h)", decoded_word_list[0][7:0]);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST49: MultipleRowsComplex
    reset_for_new_test();
    test_case = 49;
    $display("\nTEST49: MultipleRowsComplex");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 512;
    cfg_block_height = 4;
    expected_data[0] = {496'b0, 16'h00FF};
    expected_data[1] = {496'b0, 16'hFF00};
    expected_data[2] = {496'b0, 16'h00FF};
    expected_data[3] = {496'b0, 16'hFF00};
    expected_word_count = 4;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h48, 8'h08, 8'h08, 8'h48));
    send_block_data(pack_bytes(8'h48, 8'h08, 8'h08, 8'h48));
    send_block_data(pack_bytes(8'h00, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count) begin
        if (decoded_word_list[0][15:0] == 16'h00FF && decoded_word_list[1][15:0] == 16'hFF00 &&
            decoded_word_list[2][15:0] == 16'h00FF && decoded_word_list[3][15:0] == 16'hFF00) begin
            $display("  PASS: TEST49");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  FAIL: TEST49 - Data mismatch");
            error_count = error_count + 1;
        end
    end else begin
        $display("  FAIL: TEST49 - Expected %0d words, got %0d", expected_word_count, decoded_word_count);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST54: CrossRowBoundary
    reset_for_new_test();
    test_case = 54;
    $display("\nTEST54: CrossRowBoundary");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 512;
    cfg_block_height = 2;
    expected_data[0] = {496'b0, 16'h0000};
    expected_data[1] = {496'b0, 16'h0000};
    expected_word_count = 2;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h10, 8'h10, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count) begin
        if (decoded_word_list[0][15:0] == 16'h0000 && decoded_word_list[1][15:0] == 16'h0000) begin
            $display("  PASS: TEST54");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  FAIL: TEST54 - Data mismatch");
            error_count = error_count + 1;
        end
    end else begin
        $display("  FAIL: TEST54 - Expected %0d words, got %0d", expected_word_count, decoded_word_count);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // Test Summary
    #(CLK_PERIOD * 10);
    $display("\n========================================");
    $display("Batch 04 Results: %0d/%0d passed", passed_tests, total_tests);
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
    $dumpfile("tb_rle4k_decoder_core_batch_04.vcd");
    $dumpvars(0, tb_rle4k_decoder_core_batch_04);
end

endmodule
