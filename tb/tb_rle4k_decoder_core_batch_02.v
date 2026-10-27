// ============================================================================
// RLE4K Decoder V05 Testbench - Batch 02
// ============================================================================
// Description: Test cases migrated from V03 batch_02
//              Tests complex patterns and boundary conditions
// Author: Migrated from V03
// Date: 2026-01-09
// ============================================================================

`timescale 1ns / 1ps

module tb_rle4k_decoder_core_batch_02;

parameter CLK_PERIOD = 5;
parameter NUM_TESTS = 12;

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
    $display("RLE4K Decoder Testbench - Batch 02");
    $display("Total test cases: %0d", NUM_TESTS);
    $display("========================================");
    
    // TEST17: ComplexPattern (144 bits)
    reset_for_new_test();
    test_case = 17;
    $display("\nTEST17: ComplexPattern (144 bits)");
    cfg_block_index = 0;
    cfg_line_width = 144;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {368'b0, 144'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'hC1, 8'hC1, 8'h50, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][143:0] == 144'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) begin
        $display("  PASS: TEST17");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST17 - Data mismatch");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST18: MaxBlockMode (4032 bits)
    reset_for_new_test();
    test_case = 18;
    $display("\nTEST18: MaxBlockMode (4032 bits)");
    cfg_block_index = 0;
    cfg_line_width = 4032;
    cfg_line_stride = 4096;  // Align to 512 bits
    cfg_block_height = 1;
    // 4032 bits = 8 words - 32 bits, so we need 8 words
    for (i = 0; i < 8; i = i + 1) begin
        if (i < 7) begin
            expected_data[i] = {512{1'b1}};
        end else begin
            expected_data[i] = {480'b0, 32'hFFFFFFFF};
        end
    end
    expected_word_count = 8;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'hFF, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count) begin
        if (decoded_word_list[0][511:0] == {512{1'b1}}  && decoded_word_list[7][31:0] == {32{1'b1}} ) begin
            $display("  PASS: TEST18");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  FAIL: TEST18 - Data mismatch. %64h, %8h", decoded_word_list[0][511:0], decoded_word_list[7][31:0]);
            error_count = error_count + 1;
        end
    end else begin
        $display("  FAIL: TEST18 - Expected %0d words, got %0d", expected_word_count, decoded_word_count);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST25: MinimalValidData (1 bit)
    reset_for_new_test();
    test_case = 25;
    $display("\nTEST25: MinimalValidData (1 bit)");
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
        $display("  PASS: TEST25");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST25");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST26: BlockCompressionBoundary (64 bits)
    reset_for_new_test();
    test_case = 26;
    $display("\nTEST26: BlockCompressionBoundary (64 bits)");
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
        $display("  PASS: TEST26");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST26");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST27: BitCompressionMaxLength (63 bits)
    reset_for_new_test();
    test_case = 27;
    $display("\nTEST27: BitCompressionMaxLength (63 bits)");
    cfg_block_index = 0;
    cfg_line_width = 63;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {449'b0, 63'h7FFFFFFFFFFFFFFF};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h7F, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][62:0] == 63'h7FFFFFFFFFFFFFFF) begin
        $display("  PASS: TEST27");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST27");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST30: MemoryAlignment
    reset_for_new_test();
    test_case = 30;
    $display("\nTEST30: MemoryAlignment");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {504'b0, 8'h00, 8'hFF};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h48, 8'h08, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][15:0] == 16'h00FF) begin
        $display("  PASS: TEST30");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST30");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST31: BufferBoundaryExact
    reset_for_new_test();
    test_case = 31;
    $display("\nTEST31: BufferBoundaryExact");
    cfg_block_index = 0;
    cfg_line_width = 16;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {504'b0, 8'h00, 8'hFF};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h48, 8'h08, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][15:0] == 16'h00FF) begin
        $display("  PASS: TEST31");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST31");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST37: Boundary1BitWidth
    reset_for_new_test();
    test_case = 37;
    $display("\nTEST37: Boundary1BitWidth");
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
        $display("  PASS: TEST37");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST37");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST38: Boundary8BitWidth
    reset_for_new_test();
    test_case = 38;
    $display("\nTEST38: Boundary8BitWidth");
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
        $display("  PASS: TEST38");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST38");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST39: Boundary9BitWidth
    reset_for_new_test();
    test_case = 39;
    $display("\nTEST39: Boundary9BitWidth");
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
        $display("  PASS: TEST39");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST39");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST51: ByteAlignment (15 bits)
    reset_for_new_test();
    test_case = 51;
    $display("\nTEST51: ByteAlignment (15 bits)");
    cfg_block_index = 0;
    cfg_line_width = 15;
    cfg_line_stride = 512;
    cfg_block_height = 1;
    expected_data[0] = {497'b0, 15'h7FFF};
    expected_word_count = 1;
    decoded_word_count = 0;
    block_send_start();
    data_verification_enabled = 1;
    send_block_data(pack_bytes(8'h4F, 8'h00, 8'h00, 8'h00));
    wait_for_block_done();
    if (decoded_word_count == expected_word_count && decoded_word_list[0][14:0] == 15'h7FFF) begin
        $display("  PASS: TEST51");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST51 - Expected 7FFF, got %04h", decoded_word_list[0][15:0]);
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // TEST55: OutputSizeExactMatch
    reset_for_new_test();
    test_case = 55;
    $display("\nTEST55: OutputSizeExactMatch");
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
        $display("  PASS: TEST55");
        passed_tests = passed_tests + 1;
    end else begin
        $display("  FAIL: TEST55");
        error_count = error_count + 1;
    end
    total_tests = total_tests + 1;
    
    // Test Summary
    #(CLK_PERIOD * 10);
    $display("\n========================================");
    $display("Batch 02 Results: %0d/%0d passed", passed_tests, total_tests);
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
    $dumpfile("tb_rle4k_decoder_core_batch_02.vcd");
    $dumpvars(0, tb_rle4k_decoder_core_batch_02);
end

endmodule
