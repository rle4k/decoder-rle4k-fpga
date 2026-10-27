// ============================================================================
// RLE4K Decoder V05 Testbench - Batch 01
// ============================================================================
// Description: Test cases migrated from V03 batch_01
//              Tests various decode patterns and edge cases
// Author: Migrated from V03
// Date: 2026-01-09
// ============================================================================

`timescale 1ns / 1ps

module tb_rle4k_decoder_core_batch_01;

// ============================================================================
// Parameter Definitions
// ============================================================================
parameter CLK_PERIOD = 5;
parameter NUM_TESTS = 15;

// ============================================================================
// Signal Definitions
// ============================================================================
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

// ============================================================================
// DUT Instantiation
// ============================================================================
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

// ============================================================================
// Clock Generation
// ============================================================================
initial begin
    clk = 0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// ============================================================================
// Output Data Capture
// ============================================================================
always @(posedge clk) begin
    if (word_decoded_valid && word_decoded_ready) begin
        if (data_verification_enabled && decoded_word_count < 32) begin
            decoded_word_list[decoded_word_count] = decoded_data_out;
            decoded_word_count = decoded_word_count + 1;
        end
    end
end

// ============================================================================
// Helper Tasks
// ============================================================================
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

// ============================================================================
// Test Cases
// ============================================================================
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
    $display("RLE4K Decoder Testbench - Batch 01");
    $display("Total test cases: %0d", NUM_TESTS);
    $display("========================================");
    
    // TEST01: BasicDecode
    reset_for_new_test();
    test_case = 1;
    $display("\nTEST01: BasicDecode");
    cfg_block_index = 0;
    cfg_line_width = 1;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {511'b0, 1'b1};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h41, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][0] == 1'b1) begin
        $display("  PASS: TEST01");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST01");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST02: LongRun
    reset_for_new_test();
    test_case = 2;
    $display("\nTEST02: LongRun");
    cfg_block_index = 0;
    cfg_line_width = 64;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {448'b0, 64'hFFFFFFFFFFFFFFFF};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'hC1, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][63:0] == 64'hFFFFFFFFFFFFFFFF) begin
        $display("  PASS: TEST02");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST02 - Data mismatch");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST03: ShortRun (63 ones)
    reset_for_new_test();
    test_case = 3;
    $display("\nTEST03: ShortRun (63 ones)");
    cfg_block_index = 0;
    cfg_line_width = 69;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {449'b0, 63'h7FFFFFFFFFFFFFFF};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h7F, 8'h01, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count) begin
        if (decoded_word_list[0][62:0] == 63'h7FFFFFFFFFFFFFFF) begin
            $display("  PASS: TEST03");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  FAIL: TEST03 - Expected 63'h7FFFFFFFFFFFFFFF, got 63'h%016h", decoded_word_list[0][62:0]);
            error_count = error_count + 1;
        end
    end else begin
        $display("  FAIL: TEST03 - Expected %0d words, got %0d", expected_word_count, decoded_word_count);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST04: MixedMode (80 bits: 8 ones + 8 zeros + 64 zeros)
    reset_for_new_test();
    test_case = 4;
    $display("\nTEST04: MixedMode (80 bits: 8 ones + 8 zeros + 64 zeros)");
    cfg_block_index = 0;
    cfg_line_width = 80;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {432'b0, 16'h00FF};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h48, 8'h08, 8'h81, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count) begin
        if (decoded_word_list[0][15:0] == 16'h00FF && decoded_word_list[0][79:16] == 64'h0) begin
            $display("  PASS: TEST04");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  FAIL: TEST04 - Data mismatch");
            error_count = error_count + 1;
        end
    end else begin
        $display("  FAIL: TEST04 - Expected %0d words, got %0d", expected_word_count, decoded_word_count);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST05: SimpleBitMode
    reset_for_new_test();
    test_case = 5;
    $display("\nTEST05: SimpleBitMode");
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
        $display("  PASS: TEST05");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST05");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST06: SimpleBlockMode (128 ones)
    reset_for_new_test();
    test_case = 6;
    $display("\nTEST06: SimpleBlockMode (128 ones)");
    cfg_block_index = 0;
    cfg_line_width = 128;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {384'b0, 128'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'hC1, 8'hC1, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][127:0] == 128'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) begin
        $display("  PASS: TEST06");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST06");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST07: CrossByteBoundary
    reset_for_new_test();
    test_case = 7;
    $display("\nTEST07: CrossByteBoundary");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {504'b0, 4'b0000, 12'hFFF};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h4C, 8'h04, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][15:0] == 16'h0FFF) begin
        $display("  PASS: TEST07");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST07");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST08: SinglePixel
    reset_for_new_test();
    test_case = 8;
    $display("\nTEST08: SinglePixel");
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
        $display("  PASS: TEST08");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST08");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST09: AlternatingPattern
    reset_for_new_test();
    test_case = 9;
    $display("\nTEST09: AlternatingPattern");
    cfg_block_index = 0;
    cfg_line_width = 4;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {508'b0, 4'b0101};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h41, 8'h01, 8'h41, 8'h01));
    send_block_data(pack_bytes(8'h00, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][3:0] == 4'b0101) begin
        $display("  PASS: TEST09");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST09");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST10: SevenBitLength
    reset_for_new_test();
    test_case = 10;
    $display("\nTEST10: SevenBitLength");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {504'b0, 8'h00, 8'h7F};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h47, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][15:0] == 16'h007F) begin
        $display("  PASS: TEST10");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST10 - Expected 7F 00, got %04h", decoded_word_list[0][15:0]);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST11: SixtyThreeBitLength
    reset_for_new_test();
    test_case = 11;
    $display("\nTEST11: SixtyThreeBitLength");
    cfg_block_index = 0;
    cfg_line_width = 63;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {449'b0, 63'h7FFFFFFFFFFFFFFF};
    expected_word_count = 2;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h7F, 8'h41, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count) begin
        if (decoded_word_list[0][62:0] == 63'h7FFFFFFFFFFFFFFF && decoded_word_list[1][62:0] == 63'h1) begin
            $display("  PASS: TEST11");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  FAIL: TEST11 - Expected 63'h7FFFFFFFFFFFFFFF, got 63'h%016h", decoded_word_list[0][62:0]);
            error_count = error_count + 1;
        end
    end else begin
        $display("  FAIL: TEST11 - Expected %0d words, got %0d", expected_word_count, decoded_word_count);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST12: OneByteWidth
    reset_for_new_test();
    test_case = 12;
    $display("\nTEST12: OneByteWidth");
    cfg_block_index = 0;
    cfg_line_width = 8;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {504'b0, 8'hFF};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h48, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][7:0] == 8'hFF) begin
        $display("  PASS: TEST12");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST12");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST13: NineBitWidth
    reset_for_new_test();
    test_case = 13;
    $display("\nTEST13: NineBitWidth");
    cfg_block_index = 0;
    cfg_line_width = 9;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {503'b0, 9'h1FF};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h49, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][8:0] == 9'h1FF) begin
        $display("  PASS: TEST13");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST13");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST14: AllZeroRow
    reset_for_new_test();
    test_case = 14;
    $display("\nTEST14: AllZeroRow");
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
        $display("  PASS: TEST14");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST14");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST15: MultipleRows
    reset_for_new_test();
    test_case = 15;
    $display("\nTEST15: MultipleRows");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 512;
    cfg_block_height = 2;
    expected_data[0] = {496'b0, 16'h00FF};
    expected_data[1] = {496'b0, 16'hFF00};
    expected_word_count = 2;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h48, 8'h08, 8'h08, 8'h48));
    send_block_data(pack_bytes(8'h00, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][15:0] == 16'h00FF && decoded_word_list[1][15:0] == 16'hFF00) begin
        $display("  PASS: TEST15");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST15");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // Test Summary
    #(CLK_PERIOD * 10);
    $display("\n========================================");
    $display("Batch 01 Results: %0d/%0d passed", passed_tests, total_tests);
    $display("Error count: %0d", error_count);
    $display("========================================");
    
    if (error_count == 0) begin
        $display("*** All tests passed ***");
    end else begin
        $display("*** %d tests failed ***", error_count);
    end
    
    $finish;
end

// ============================================================================
// Timeout Watchdog
// ============================================================================
initial begin
    #(CLK_PERIOD * 100000);
    $display("[ERROR] Testbench timeout!");
    $finish;
end

// ============================================================================
// Waveform Dump
// ============================================================================
initial begin
    $dumpfile("tb_rle4k_decoder_core_batch_01.vcd");
    $dumpvars(0, tb_rle4k_decoder_core_batch_01);
end

endmodule
