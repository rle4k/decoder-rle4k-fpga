// ============================================================================
// tb_rle4k_ring_window — gate for whole-block ring address + completion bitmap
// ============================================================================
// Rule 14: default path must be able to fail. Case A deliberately accepts a
// second block into a busy slot without completing the first — expect
// retx_pending. Case B is the green path (complete then reuse slot).
// ============================================================================

`timescale 1ns / 1ps

module tb_rle4k_ring_window;

reg clk = 0;
always #5 clk = ~clk;

reg rst_n = 0;
reg clear = 0;
reg accept_valid = 0;
reg [31:0] accept_block_index = 0;
wire accept_ready;
wire retx_pending;
wire [31:0] retx_count;
reg complete_valid = 0;
reg [31:0] complete_block_index = 0;
wire [31:0] slot, byte_addr, complete_bitmap, window_base_index, last_byte_addr, blocks_completed;

localparam [31:0] BASE = 32'h2000_0000;
localparam [31:0] BBYTES = 32'd4194304;
localparam integer W = 32;

rle4k_ring_window #(
    .P_BASE(BASE), .P_BLOCK_BYTES(BBYTES), .P_W(W)
) dut (
    .clk(clk), .rst_n(rst_n), .clear(clear),
    .accept_valid(accept_valid), .accept_block_index(accept_block_index),
    .accept_ready(accept_ready), .retx_pending(retx_pending), .retx_count(retx_count),
    .complete_valid(complete_valid), .complete_block_index(complete_block_index),
    .slot(slot), .byte_addr(byte_addr),
    .complete_bitmap(complete_bitmap), .window_base_index(window_base_index),
    .last_byte_addr(last_byte_addr), .blocks_completed(blocks_completed)
);

integer errors = 0;

task automatic tick;
    begin
        @(posedge clk);
        #1;
    end
endtask

task automatic do_accept;
    input [31:0] bi;
    begin
        accept_block_index = bi;
        accept_valid = 1;
        tick;
        accept_valid = 0;
        tick;
    end
endtask

task automatic do_complete;
    input [31:0] bi;
    begin
        complete_block_index = bi;
        complete_valid = 1;
        tick;
        complete_valid = 0;
        tick;
    end
endtask

initial begin
    $display("=== tb_rle4k_ring_window ===");
    rst_n = 0;
    repeat (4) tick;
    rst_n = 1;
    tick;

    // Address check: block 0 → BASE, block 1 → BASE+4MiB, block 32 → BASE (wrap)
    do_accept(32'd0);
    if (last_byte_addr !== BASE) begin
        $display("FAIL addr0 got %h", last_byte_addr);
        errors = errors + 1;
    end
    do_complete(32'd0);

    do_accept(32'd1);
    if (last_byte_addr !== (BASE + BBYTES)) begin
        $display("FAIL addr1 got %h", last_byte_addr);
        errors = errors + 1;
    end
    do_complete(32'd1);

    // ---- Case A (must be able to RED): reuse slot 0 while block 32's sibling
    // still busy — accept block 0, do NOT complete, then accept block 32
    // (same slot). Expect retx_pending and accept_ready low on conflict cycle.
    clear = 1; tick; clear = 0; tick;
    do_accept(32'd0);
    if (retx_pending) begin
        $display("FAIL unexpected retx on first accept");
        errors = errors + 1;
    end
    accept_block_index = 32'd32;
    accept_valid = 1;
    @(posedge clk);
    #1;
    if (accept_ready !== 1'b0) begin
        $display("FAIL CaseA: accept_ready should be 0 on busy-slot conflict");
        errors = errors + 1;
    end
    if (retx_pending !== 1'b1) begin
        $display("FAIL CaseA: retx_pending should stick after conflict");
        errors = errors + 1;
    end
    accept_valid = 0;
    tick;

    // ---- Case B (green): complete then reuse
    clear = 1; tick; clear = 0; tick;
    do_accept(32'd0);
    do_complete(32'd0);
    do_accept(32'd32);
    if (retx_pending) begin
        $display("FAIL CaseB: retx after proper complete+reuse");
        errors = errors + 1;
    end
    if (last_byte_addr !== BASE) begin
        $display("FAIL CaseB wrap addr got %h", last_byte_addr);
        errors = errors + 1;
    end
    do_complete(32'd32);

    if (errors == 0)
        $display("PASS tb_rle4k_ring_window");
    else
        $display("FAIL tb_rle4k_ring_window errors=%0d", errors);
    $finish;
end

endmodule
