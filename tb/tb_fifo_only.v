// Minimal testbench: test input_fifo_32to8 byte output order
`timescale 1ns / 1ps

module tb_fifo_only;

reg clk = 0;
always #4 clk = ~clk;
reg rst_n = 0;

reg [31:0] data_in;
reg        valid_in;
wire       ready_out;

wire [7:0] data_out;
wire       valid_out;
reg        ready_in;

input_fifo_32to8 u_fifo (
    .clk      (clk),
    .rst_n    (rst_n),
    .data_in  (data_in),
    .valid_in (valid_in),
    .ready_out(ready_out),
    .data_out (data_out),
    .valid_out(valid_out),
    .ready_in (ready_in)
);

initial begin
    data_in  = 0;
    valid_in = 0;
    ready_in = 1;

    rst_n = 0;
    repeat(5) @(posedge clk);
    rst_n = 1;
    repeat(2) @(posedge clk);

    // Feed word 0xFFFF89BF (should produce bytes: BF, 89, FF, FF)
    data_in  = 32'hFFFF89BF;
    valid_in = 1;
    @(posedge clk);
    valid_in = 0;

    // Wait and capture 4 output bytes
    repeat(20) begin
        @(posedge clk);
        if (valid_out)
            $display("T=%0t FIFO_OUT: 0x%02h", $time, data_out);
    end

    $display("--- Test 2: back-to-back ---");
    // Feed two words
    data_in  = 32'h44332211;
    valid_in = 1;
    @(posedge clk);
    data_in  = 32'h88776655;
    @(posedge clk);
    valid_in = 0;

    repeat(20) begin
        @(posedge clk);
        if (valid_out)
            $display("T=%0t FIFO_OUT: 0x%02h", $time, data_out);
    end

    $finish;
end

endmodule
