// ============================================================================
// tb_rle4k_rxchain -- receive-path throughput gate at master_wrapper_v8 scope
// ============================================================================
// tb_rle4k_integration and tb_rle4k_fullspeed drive rle4k_mac_proto_v8 directly
// on its 64-bit port, which is downstream of everything master_wrapper_v8 puts
// between the MAC and the protocol engine. That is why both of them report zero
// loss while the board loses roughly one frame in six at line rate: the losing
// stage is not in their device under test.
//
// This bench reinstates the missing stages, modelled behaviourally so the gate
// still runs from plain xvlog with no generated IP:
//
//   8-bit MAC RX at 125 MHz  ->  axis_dwidth_converter_1 (8->64)
//     ->  axis_data_fifo_1 (async 125 -> 15.625, depth 2048)
//     ->  axis_data_fifo_0 (packet mode, depth 2048)
//     ->  tb_rle4k_chain  (rle4k_mac_proto_v8 + adapter + decoder + CRC)
//
// The one detail that makes the defect visible is master_wrapper_v8.v line 377:
// the width converter's s_axis_tready is left unconnected. Ethernet cannot be
// back-pressured onto the wire, so whatever the downstream cannot absorb is
// dropped here rather than stalling. Every stage after it must therefore sustain
// line rate, and rle4k_mac_proto_v8's CAPTURE -> CHECK -> REPLAY receive engine
// does not: it reads a frame into a buffer before replaying it to the adapter,
// which costs about twice the cycles a frame takes to arrive.
//
// Pass criterion: every frame offered on the wire is received by the protocol
// engine. Run with -d RXCHAIN_PACED to confirm the same stimulus passes when
// frames are spaced out, which separates a throughput defect from a functional
// one.
// ============================================================================

`timescale 1ns / 1ps

module tb_rle4k_rxchain;

// ---------------------------------------------------------------------------
// Clocks and reset
// ---------------------------------------------------------------------------
reg clk_125    = 1'b0;
reg clk_15_625 = 1'b0;
always #4  clk_125    = ~clk_125;      // 125 MHz    -> 8 ns period
always #32 clk_15_625 = ~clk_15_625;   // 15.625 MHz -> 64 ns period

reg core_reset = 1'b1;
reg locked     = 1'b0;

// ---------------------------------------------------------------------------
// Frame assembly. The include builds fbytes[]/flen; only its 64-bit driver is
// unused here, replaced by the byte-serial source below.
// ---------------------------------------------------------------------------
reg        mac_rx_data_valid = 1'b0;
reg [63:0] mac_rx_data       = 64'd0;
reg [7:0]  mac_rx_keep       = 8'd0;
reg        mac_rx_last       = 1'b0;

wire        chain_rx_ready;
wire        mac_rx_ready = chain_rx_ready;

`include "tb_rle4k_eth_stim.vh"

// ---------------------------------------------------------------------------
// Byte-serial MAC receive source
// ---------------------------------------------------------------------------
// One byte per 125 MHz cycle is exactly 1 Gbit/s. IFG_CYCLES covers the 12-byte
// interframe gap plus the 8-byte preamble the MAC strips before this point.
// ---------------------------------------------------------------------------
localparam integer IFG_CYCLES = 20;
`ifdef RXCHAIN_PACED
localparam integer EXTRA_GAP = 4000;   // ~32 us, comfortably slower than the sink
`else
localparam integer EXTRA_GAP = 0;      // line rate
`endif

reg        src_valid = 1'b0;
reg [7:0]  src_data  = 8'd0;
reg        src_last  = 1'b0;

integer frames_offered = 0;
integer bytes_offered  = 0;

task drive_frame_wire;
    integer i;
    begin
        for (i = 0; i < flen; i = i + 1) begin
            @(negedge clk_125);
            src_data  = fbytes[i];
            src_last  = (i == flen - 1);
            src_valid = 1'b1;
            bytes_offered = bytes_offered + 1;
        end
        @(negedge clk_125);
        src_valid = 1'b0;
        src_last  = 1'b0;
        frames_offered = frames_offered + 1;
        repeat (IFG_CYCLES + EXTRA_GAP) @(negedge clk_125);
    end
endtask

// ---------------------------------------------------------------------------
// axis_dwidth_converter_1: 8 -> 64, little endian, s_axis_tready unconnected
// ---------------------------------------------------------------------------
reg [63:0] cv_acc  = 64'd0;
reg [7:0]  cv_keep = 8'd0;
reg [2:0]  cv_idx  = 3'd0;

reg [63:0] cv_data  = 64'd0;
reg [7:0]  cv_kmask = 8'd0;
reg        cv_valid = 1'b0;
reg        cv_last  = 1'b0;
wire       cv_ready;

// A beat the async FIFO cannot take is lost, exactly as it is on the board.
integer beats_dropped   = 0;
integer frames_damaged  = 0;
reg     frame_damaged_r = 1'b0;

task cv_emit;
    input [63:0] d;
    input [7:0]  k;
    input        l;
    begin
        if (cv_valid && !cv_ready) begin
            beats_dropped = beats_dropped + 1;
            if (!frame_damaged_r) begin
                frame_damaged_r = 1'b1;
                frames_damaged  = frames_damaged + 1;
            end
        end else begin
            cv_data  <= d;
            cv_kmask <= k;
            cv_last  <= l;
            cv_valid <= 1'b1;
        end
    end
endtask

always @(posedge clk_125) begin
    if (core_reset) begin
        cv_idx   <= 3'd0;
        cv_acc   <= 64'd0;
        cv_keep  <= 8'd0;
        cv_valid <= 1'b0;
    end else begin
        if (cv_valid && cv_ready)
            cv_valid <= 1'b0;

        if (src_valid) begin
            cv_acc[cv_idx*8 +: 8] = src_data;
            cv_keep[cv_idx]       = 1'b1;
            if (cv_idx == 3'd7 || src_last) begin
                cv_emit(cv_acc, cv_keep, src_last);
                cv_acc  <= 64'd0;
                cv_keep <= 8'd0;
                cv_idx  <= 3'd0;
                if (src_last) frame_damaged_r <= 1'b0;
            end else begin
                cv_idx <= cv_idx + 3'd1;
            end
        end
    end
end

// ---------------------------------------------------------------------------
// axis_data_fifo_1: asynchronous, depth 2048, 125 MHz in / 15.625 MHz out
// ---------------------------------------------------------------------------
localparam integer AFIFO_DEPTH = 2048;

reg [72:0] afifo_mem [0:AFIFO_DEPTH-1];   // {last, keep, data}
integer    afifo_wr = 0;
integer    afifo_rd = 0;

wire integer afifo_count = afifo_wr - afifo_rd;
assign cv_ready = (afifo_count < AFIFO_DEPTH);

always @(posedge clk_125) begin
    if (core_reset) begin
        afifo_wr <= 0;
    end else if (cv_valid && cv_ready) begin
        afifo_mem[afifo_wr % AFIFO_DEPTH] <= {cv_last, cv_kmask, cv_data};
        afifo_wr <= afifo_wr + 1;
    end
end

wire        af_out_valid = (afifo_count > 0);
wire [72:0] af_out_word  = afifo_mem[afifo_rd % AFIFO_DEPTH];
wire        af_out_ready;

always @(posedge clk_15_625) begin
    if (core_reset)
        afifo_rd <= 0;
    else if (af_out_valid && af_out_ready)
        afifo_rd <= afifo_rd + 1;
end

// ---------------------------------------------------------------------------
// axis_data_fifo_0: packet mode (FIFO_MODE 2), depth 2048, 15.625 MHz
// ---------------------------------------------------------------------------
// Store and forward: a frame is only offered downstream once its tlast has been
// written, which is what keeps a truncated frame from reaching the protocol
// engine mid-flight.
// ---------------------------------------------------------------------------
localparam integer PFIFO_DEPTH = 2048;

reg [72:0] pfifo_mem [0:PFIFO_DEPTH-1];
integer    pfifo_wr       = 0;
integer    pfifo_rd       = 0;
integer    pfifo_commit   = 0;   // words belonging to fully written frames

wire integer pfifo_count = pfifo_wr - pfifo_rd;
assign af_out_ready = (pfifo_count < PFIFO_DEPTH);

always @(posedge clk_15_625) begin
    if (core_reset) begin
        pfifo_wr     <= 0;
        pfifo_commit <= 0;
    end else if (af_out_valid && af_out_ready) begin
        pfifo_mem[pfifo_wr % PFIFO_DEPTH] <= af_out_word;
        pfifo_wr <= pfifo_wr + 1;
        if (af_out_word[72])
            pfifo_commit <= pfifo_wr + 1;
    end
end

wire        pf_out_valid = (pfifo_rd < pfifo_commit);
wire [72:0] pf_out_word  = pfifo_mem[pfifo_rd % PFIFO_DEPTH];

always @(posedge clk_15_625) begin
    if (core_reset)
        pfifo_rd <= 0;
    else if (pf_out_valid && chain_rx_ready)
        pfifo_rd <= pfifo_rd + 1;
end

// ---------------------------------------------------------------------------
// Device under test
// ---------------------------------------------------------------------------
wire [31:0] mon_rx_datagrams;
wire [31:0] mon_stream_start, mon_stream_data, mon_stream_end, mon_err_rsp;
wire [31:0] stream_rx_bytes;
wire [31:0] crc32_latched_o, crc32_word_count_latched_o;
wire        crc32_done_o;

tb_rle4k_chain u_chain (
    .clk_15_625        (clk_15_625),
    .clk_125           (clk_125),
    .core_reset        (core_reset),
    .locked            (locked),

    .mac_rx_data_valid (pf_out_valid),
    .mac_rx_data       (pf_out_word[63:0]),
    .mac_rx_keep       (pf_out_word[71:64]),
    .mac_rx_last       (pf_out_word[72]),
    .mac_rx_ready      (chain_rx_ready),

    .mac_tx_data_valid (),
    .mac_tx_data       (),
    .mac_tx_keep       (),
    .mac_tx_ready      (1'b1),
    .mac_tx_last       (),

    .app_rx_data_valid (),
    .app_rx_data_last  (),
    .app_rx_data_length(),
    .soft_rst          (),
    .cdc_full          (),
    .dec_valid         (),
    .stream_rx_bytes   (stream_rx_bytes),
    .mon_rx_datagrams  (mon_rx_datagrams),
    .mon_stream_start  (mon_stream_start),
    .mon_stream_data   (mon_stream_data),
    .mon_stream_end    (mon_stream_end),
    .mon_err_rsp       (mon_err_rsp),
    .adapter_state     (),
    .word_decoded_valid(),
    .block_done_raw    (),
    .strip_end_raw     (),
    .decode_status_raw (),
    .crc32_accum_o     (),
    .crc32_latched_o   (crc32_latched_o),
    .crc32_word_count_o(),
    .crc32_word_count_latched_o(crc32_word_count_latched_o),
    .crc32_done_o      (crc32_done_o)
);

// ---------------------------------------------------------------------------
// Stimulus
// ---------------------------------------------------------------------------
// Full-size frames, and enough of them to overrun the 2048-entry FIFOs several
// times over. A short burst of small frames proves nothing here: 16 KB of
// buffering absorbs it entirely and the gate passes while the board still loses
// frames.
localparam integer N_DATA_FRAMES = 120;

integer i;
integer j;
integer expected_frames;

initial begin
    seq_ctr = 16'd0;

    core_reset = 1'b1;
    locked     = 1'b0;
    repeat (40) @(posedge clk_15_625);
    core_reset = 1'b0;
    locked     = 1'b1;
    repeat (20) @(posedge clk_15_625);

    // A synthetic payload keeps the gate independent of sim_data/, whose block
    // geometry the decoder would otherwise have to agree with. What is measured
    // here is how many frames survive the receive path, not what they decode to.
    for (i = 0; i < N_DATA_FRAMES; i = i + 1) begin
        build_hdr(CMDB_STREAM_DATA, MAX_DATA_PER_FRAME[15:0]);
        for (j = 0; j < MAX_DATA_PER_FRAME; j = j + 1)
            fbytes[19 + j] = j[7:0];
        drive_frame_wire();
    end

    expected_frames = N_DATA_FRAMES;

    // Drain: the sink is the slow end, so allow it well past the offered time.
    repeat (60000) @(posedge clk_15_625);

    $display("");
    $display("=== RX chain throughput ===");
    $display("  frames offered on wire : %0d", frames_offered);
    $display("  bytes  offered on wire : %0d", bytes_offered);
    $display("  beats dropped at 8->64 : %0d", beats_dropped);
    $display("  frames damaged by drop : %0d", frames_damaged);
    $display("  frames seen by mac_proto: %0d", mon_rx_datagrams);
    $display("  frames lost             : %0d", frames_offered - mon_rx_datagrams);
    if (frames_offered > 0)
        $display("  loss rate               : %0d.%02d %%",
                 ((frames_offered - mon_rx_datagrams) * 100) / frames_offered,
                 (((frames_offered - mon_rx_datagrams) * 10000) / frames_offered) % 100);

    if (mon_rx_datagrams == expected_frames) begin
        $display("ALL TESTS PASSED");
    end else begin
        $display("TEST FAILED: receive path dropped %0d of %0d frames",
                 expected_frames - mon_rx_datagrams, expected_frames);
    end
    $finish;
end

initial begin
    #20_000_000;
    $display("TIMEOUT");
    $finish;
end

endmodule
