// ============================================================================
// tb_rle4k_integration -- end-to-end RTL gate for the shipped V08MAC datapath
// ============================================================================
// Covers the real chain, driven with real raw-Ethernet frames:
//
//   [TB frame generator]  EtherType 0x4B52, DA 00:0A:35:00:01:02
//        |  64-bit MAC RX stream @ 15.625 MHz
//        v
//   rle4k_mac_proto_v8  ->  rle4k_stream_adapter_v8  ->  rle4k_cdc_fifo_36
//        ->  rle4k_decoder_core  ->  CRC32 accumulator
//
// The glue (clock-domain crossings, skid buffer, CRC accumulator/latch) lives
// in tb_rle4k_chain.v and is copied verbatim from rle4k_lan_top_v8.v, including
// its .block_start(1'b0) tie-off. This is the gate that tb_decoder_crc.v cannot
// provide: tb_decoder_crc drives block_start=1 and bypasses the MAC protocol,
// the adapter and the CDC FIFO entirely.
//
// Protocol exercised: CMD_RESET, CMD_STREAM_START (24-byte StreamStartPayload),
// CMD_STREAM_DATA (1492-byte chunks, same as the CLI), CMD_STREAM_END.
//
// Frame pacing mirrors the CLI's --inter-chunk-delay-ms: the next frame is only
// sent once the adapter is back in S_RX_IDLE. See tb_rle4k_fullspeed.v for the
// zero-gap stress case.
// ============================================================================

`timescale 1ns / 1ps

module tb_rle4k_integration;

// ----------------------------------------------------------------------------
// Clocks: same ratio as clk_wiz_0 (15.625 MHz protocol, 125 MHz decoder)
// ----------------------------------------------------------------------------
reg clk_125    = 1'b0;
reg clk_15_625 = 1'b0;
always #4  clk_125    = ~clk_125;      // 125 MHz

// Starting both clocks at t=0 makes every 15.625 MHz edge land exactly on a
// 125 MHz edge, because 64 ns is a whole multiple of 8 ns. The board never sees
// that alignment: both clocks come from one MMCM but arrive with real skew. The
// degenerate case hides any race on the signals crossing between the domains,
// so the skew below moves the slow clock off the grid.
//
// The value comes from a file rather than a +define, because xvlog on Windows
// splits the argument at the '=' and then tries to open the value as a file
// path. tb/sim_data/fullspeed_gap.txt exists for the same reason. Missing file
// means zero skew, which is the historical behaviour the gate scripts rely on.
real clk_skew_ns = 0.0;
initial begin : slow_clock
    integer fh, rc;
    real    v;
    fh = $fopen("../tb/sim_data/clk_skew_ns.txt", "r");
    if (fh != 0) begin
        rc = $fscanf(fh, "%f", v);
        if (rc == 1) clk_skew_ns = v;
        $fclose(fh);
    end
    if (clk_skew_ns != 0.0)
        $display("=== clk_15_625 skewed %0.3f ns off the 125 MHz grid ===", clk_skew_ns);
    #(clk_skew_ns);
    forever #32 clk_15_625 = ~clk_15_625;   // 15.625 MHz
end

reg locked     = 1'b0;
reg core_reset = 1'b1;

// ----------------------------------------------------------------------------
// MAC RX drive / MAC TX observe
// ----------------------------------------------------------------------------
reg         mac_rx_data_valid = 1'b0;
reg  [63:0] mac_rx_data       = 64'd0;
reg  [7:0]  mac_rx_keep       = 8'd0;
reg         mac_rx_last       = 1'b0;
wire        mac_rx_ready;

wire        mac_tx_data_valid;
wire [63:0] mac_tx_data;
wire [7:0]  mac_tx_keep;
wire        mac_tx_last;
reg         mac_tx_ready = 1'b1;

wire        app_rx_data_valid;
wire        app_rx_data_last;
wire [15:0] app_rx_data_length;
wire        soft_rst;
wire        cdc_full;
wire        dec_valid;
wire [31:0] stream_rx_bytes;
wire [31:0] mon_rx_datagrams;
wire [31:0] mon_stream_start;
wire [31:0] mon_stream_data;
wire [31:0] mon_stream_end;
wire [31:0] mon_err_rsp;
wire [5:0]  adapter_state;
wire        word_decoded_valid;
wire        block_done_raw;
wire        strip_end_raw;
wire [31:0] decode_status_raw;
wire [31:0] crc32_accum;
wire [31:0] crc32_latched;
wire [31:0] crc32_word_count;
wire [31:0] crc32_word_count_latched;
wire        crc32_done;

// Compile with -d BLOCK_START_FIX to run the same gate against the proposed
// Defect-B fix (see tb_rle4k_block_start.v) and confirm it does not regress.
`ifdef BLOCK_START_FIX
localparam integer BS_MODE = 1;
`else
localparam integer BS_MODE = 0;
`endif

tb_rle4k_chain #(
    .LOCAL_MAC        (48'h000A35000102),
    .BLOCK_START_MODE (BS_MODE)
) u_chain (
    .clk_15_625 (clk_15_625),
    .clk_125    (clk_125),
    .core_reset (core_reset),
    .locked     (locked),

    .mac_rx_data_valid (mac_rx_data_valid),
    .mac_rx_data       (mac_rx_data),
    .mac_rx_keep       (mac_rx_keep),
    .mac_rx_last       (mac_rx_last),
    .mac_rx_ready       (mac_rx_ready),

    .mac_tx_data_valid (mac_tx_data_valid),
    .mac_tx_data       (mac_tx_data),
    .mac_tx_keep       (mac_tx_keep),
    .mac_tx_ready      (mac_tx_ready),
    .mac_tx_last       (mac_tx_last),

    .app_rx_data_valid  (app_rx_data_valid),
    .app_rx_data_last   (app_rx_data_last),
    .app_rx_data_length (app_rx_data_length),
    .soft_rst           (soft_rst),
    .cdc_full           (cdc_full),
    .dec_valid          (dec_valid),
    .stream_rx_bytes    (stream_rx_bytes),
    .mon_rx_datagrams   (mon_rx_datagrams),
    .mon_stream_start   (mon_stream_start),
    .mon_stream_data    (mon_stream_data),
    .mon_stream_end     (mon_stream_end),
    .mon_err_rsp        (mon_err_rsp),
    .adapter_state      (adapter_state),
    .word_decoded_valid (word_decoded_valid),
    .block_done_raw     (block_done_raw),
    .strip_end_raw      (strip_end_raw),
    .decode_status_raw  (decode_status_raw),

    .crc32_accum_o              (crc32_accum),
    .crc32_latched_o            (crc32_latched),
    .crc32_word_count_o         (crc32_word_count),
    .crc32_word_count_latched_o (crc32_word_count_latched),
    .crc32_done_o               (crc32_done)
);

`include "tb_rle4k_eth_stim.vh"

// ----------------------------------------------------------------------------
// Observers
// ----------------------------------------------------------------------------
integer app_frames_delivered = 0;   // frames mac_proto handed to the adapter
integer dec_words_fed        = 0;   // 32-bit words the adapter pushed at dec_valid
integer block_done_edges     = 0;
integer strip_end_edges      = 0;
reg     block_done_d = 1'b0;
reg     strip_end_d  = 1'b0;

always @(posedge clk_15_625) begin
    if (app_rx_data_valid && app_rx_data_last)
        app_frames_delivered = app_frames_delivered + 1;
    if (dec_valid)
        dec_words_fed = dec_words_fed + 1;
end

always @(posedge clk_125) begin
    block_done_d <= block_done_raw;
    strip_end_d  <= strip_end_raw;
    if (block_done_raw && !block_done_d) begin
        block_done_edges = block_done_edges + 1;
        $display("[%0t] block_done rise #%0d: words=%0d accum=0x%08x",
                 $time, block_done_edges, crc32_word_count, crc32_accum);
    end
    if (strip_end_raw && !strip_end_d) begin
        strip_end_edges = strip_end_edges + 1;
        $display("[%0t] strip_end rise #%0d: words=%0d accum=0x%08x",
                 $time, strip_end_edges, crc32_word_count, crc32_accum);
    end
end

// ----------------------------------------------------------------------------
// Pacing: wait until the adapter and the MAC parser are both idle again.
// ----------------------------------------------------------------------------
task wait_chain_idle;
    integer guard;
    begin
        guard = 0;
        while ((u_chain.u_adapter.state !== 6'd0 ||
                u_chain.u_mac_proto.rx_state !== 2'd0) && guard < 20_000_000) begin
            @(negedge clk_15_625);
            guard = guard + 1;
        end
        repeat (4) @(negedge clk_15_625);
    end
endtask

// Model the CLI's --inter-chunk-delay-ms 1 (default): at 1 ms per frame the host
// is far slower than the decoder (a full 771-line strip decodes in <1 ms), so on
// the board the pipeline is always fully drained before the next frame and
// before STREAM_END. Rather than burning a magic 1 ms of simulated time per
// frame, wait for the equivalent steady state: CDC FIFO empty, decoder input
// FIFO empty and no decoded word for QUIET_CYCLES.
//
// This matters: dec_stream_end is pulsed by the adapter straight out of
// S_DISPATCH and immediately puts the core into stream_end_filling, which gates
// parsed_ready off. Any payload still sitting in the CDC / input FIFO when
// STREAM_END lands is replaced by zero fill. See tb_rle4k_fullspeed.v.
// DEFAULT IS drain_mode = 0, i.e. the drain above is NOT used. That is deliberate.
//
// This testbench used to call wait_pipeline_drained() after every STREAM_DATA frame,
// which meant STREAM_END could never arrive while payload was still in flight. That is
// exactly the condition that fails on the board, so the gate was green for months while
// the hardware lost the tail of roughly one strip in two. A testbench that steers around
// the failure condition is not a gate. Board evidence:
// reports/2026-08-09-stream-end-race-root-cause.md.
//
// drain_mode is read from tb/sim_data/drain_mode.txt; a missing file means 0.
//   0 = frames back to back, STREAM_END right behind the last one (board-realistic)
//   1 = legacy drained variant, kept only so the old behaviour stays reproducible
// The value comes from a file rather than -d NAME=VALUE because xvlog on Windows splits
// the argument at '=' and tries to open the value as a path (same reason as
// fullspeed_gap.txt and clk_skew_ns.txt).
integer drain_mode = 0;
initial begin : load_drain_mode
    integer fh, rc, v;
    fh = $fopen("../tb/sim_data/drain_mode.txt", "r");
    if (fh != 0) begin
        rc = $fscanf(fh, "%d", v);
        if (rc == 1) drain_mode = v;
        $fclose(fh);
    end
    $display("=== drain_mode=%0d (%s) ===", drain_mode,
             drain_mode ? "legacy: drain before STREAM_END" :
                          "board-realistic: STREAM_END may overtake in-flight payload");
end

// Mirror of the board ILA capture: how much real payload was still owed at the instant
// the core gave up and started zero filling. On the board (N=5) it was 24 lines / 2944
// words. A nonzero number here is the same defect, reproduced in simulation.
reg [31:0] fill_start_words = 32'd0;
reg [31:0] fill_start_lines = 32'd0;
reg        fill_seen        = 1'b0;
reg        fill_prev        = 1'b0;
always @(posedge clk_125) begin
    fill_prev <= u_chain.u_decoder.stream_end_filling;
    if (u_chain.u_decoder.stream_end_filling && !fill_prev && !fill_seen) begin
        fill_seen        <= 1'b1;
        fill_start_words <= crc32_word_count;
        fill_start_lines <= u_chain.u_decoder.strip_line_count;
    end
end

localparam integer QUIET_CYCLES = 500;
integer quiet_cnt;

task wait_pipeline_drained;
    integer guard;
    begin
        wait_chain_idle();
        quiet_cnt = 0;
        guard     = 0;
        while (quiet_cnt < QUIET_CYCLES && guard < 40_000_000) begin
            @(posedge clk_125);
            guard = guard + 1;
            if (word_decoded_valid || !u_chain.cdc_empty || u_chain.dec_input_valid ||
                u_chain.u_decoder.u_input_fifo.occupancy != 0 ||
                u_chain.u_decoder.u_input_fifo.hold_valid)
                quiet_cnt = 0;
            else
                quiet_cnt = quiet_cnt + 1;
        end
    end
endtask

// ----------------------------------------------------------------------------
// Main sequence
// ----------------------------------------------------------------------------
integer offset;
integer chunk;
integer data_frames;
integer guard_cnt;
reg     test_pass;
reg [31:0] post_xor_from_accum;

initial begin
    test_pass     = 1'b1;
    frames_driven = 0;
    words_driven  = 0;
    seq_ctr       = 16'd0;

    load_sim_config();
    load_ref_crc();
    $readmemh("../tb/sim_data/stream_data.hex", stream_mem);

    $display("================================================================");
    $display(" tb_rle4k_integration -- mac_proto -> adapter -> cdc -> decoder");
    $display("================================================================");
    $display("  line_width=%0d line_stride=%0d total_height=%0d",
             cfg_line_width_i, cfg_line_stride_i, cfg_total_height_i);
    $display("  stream_words=%0d wire_bytes=%0d rle_payload_bytes=%0d",
             cfg_stream_words_i, cfg_wire_bytes_i, cfg_rle_payload_i);
    $display("  blocks=%0d block_height=%0d",
             cfg_block_count_i, cfg_block0_height_i);
    $display("  ref TOTAL_WORDS=%0d CRC32_FINAL(post-XOR)=0x%08x CRC32_ACCUM(pre-XOR)=0x%08x",
             ref_total_words_i, ref_crc_final_r, ref_crc_accum_r);

    // Reset: MMCM lock, then release core_reset
    core_reset = 1'b1;
    locked     = 1'b0;
    repeat (5)  @(negedge clk_15_625);
    locked     = 1'b1;
    repeat (10) @(negedge clk_15_625);
    core_reset = 1'b0;
    repeat (10) @(negedge clk_15_625);

    // --- CMD_RESET (the CLI sends this before every strip) ---
    build_reset_frame();
    drive_frame(0);
    wait_chain_idle();
    repeat (20) @(negedge clk_15_625);

    // --- CMD_STREAM_START ---
    build_stream_start_frame();
    drive_frame(0);
    wait_chain_idle();
    $display("[%0t] STREAM_START done: cfg lw=%0d ls=%0d bh=%0d strip_lines=%0d rle_bytes=%0d",
             $time, u_chain.cfg_line_width, u_chain.cfg_line_stride,
             u_chain.cfg_block_height, u_chain.cfg_strip_line_count_mac,
             u_chain.cfg_rle_payload_bytes_mac);

    // --- CMD_STREAM_DATA, 1492-byte chunks like the CLI ---
    offset      = 0;
    data_frames = 0;
    while (offset < cfg_wire_bytes_i) begin
        chunk = cfg_wire_bytes_i - offset;
        if (chunk > MAX_DATA_PER_FRAME) chunk = MAX_DATA_PER_FRAME;
        build_stream_data_frame(offset, chunk);
        drive_frame(0);
        if (drain_mode) wait_pipeline_drained();
        offset      = offset + chunk;
        data_frames = data_frames + 1;
        $display("[%0t] STREAM_DATA frame %0d: +%0d bytes (total %0d), decoded words so far=%0d",
                 $time, data_frames, chunk, offset, crc32_word_count);
    end
    $display("[%0t] STREAM_DATA done: %0d frames, %0d bytes, adapter rx_bytes=%0d",
             $time, data_frames, offset, stream_rx_bytes);

    // --- CMD_STREAM_END ---
    build_stream_end_frame();
    drive_frame(0);
    $display("[%0t] STREAM_END sent", $time);

    // --- Wait for strip completion ---
    guard_cnt = 0;
    while (!crc32_done && guard_cnt < 40_000_000) begin
        @(posedge clk_125);
        guard_cnt = guard_cnt + 1;
    end
    if (!crc32_done) begin
        $display("TIMEOUT waiting for strip_end / crc32_done at %0t", $time);
        test_pass = 1'b0;
    end
    repeat (200) @(posedge clk_125);

    post_xor_from_accum = crc32_accum ^ 32'hFFFFFFFF;

    $display("");
    $display("  ======== INTEGRATION CHAIN VERIFICATION ========");
    $display("  Frames driven on the wire : %0d (%0d 64-bit MAC words)",
             frames_driven, words_driven);
    $display("  Frames accepted by mac_proto (app_rx last) : %0d", app_frames_delivered);
    $display("  Adapter counters: rx_datagrams=%0d stream_start=%0d stream_data=%0d stream_end=%0d err_rsp=%0d",
             mon_rx_datagrams, mon_stream_start, mon_stream_data, mon_stream_end, mon_err_rsp);
    $display("  Adapter bytes fed to CDC  : %0d (expected %0d)",
             stream_rx_bytes, cfg_wire_bytes_i);
    $display("  32-bit words fed to CDC   : %0d (expected %0d)",
             dec_words_fed, cfg_stream_words_i);
    $display("  block_done edges=%0d  strip_end edges=%0d",
             block_done_edges, strip_end_edges);
    if (fill_seen)
        $display("  ZERO-FILL ENGAGED at word %0d of %0d, strip line %0d of %0d -> %0d words (%0d lines) of real payload were discarded",
                 fill_start_words, ref_total_words_i,
                 fill_start_lines, cfg_total_height_i,
                 ref_total_words_i - fill_start_words,
                 cfg_total_height_i - fill_start_lines);
    else
        $display("  ZERO-FILL never engaged before the strip completed (clean drain)");
    $display("  BLOCK_START_MODE=%0d  decode_status=0x%08x (low byte 0x%02x)",
             BS_MODE, decode_status_raw, decode_status_raw[7:0]);
    $display("");
    $display("  --- CRC32 calibers ---");
    $display("  pre-XOR  accumulator (TB/RTL raw) : 0x%08x", crc32_accum);
    $display("  post-XOR = pre-XOR ^ 0xFFFFFFFF   : 0x%08x", post_xor_from_accum);
    $display("  post-XOR latched by RTL on strip_end (board caliber) : 0x%08x", crc32_latched);
    $display("  conversion check: 0x%08x ^ 0xFFFFFFFF = 0x%08x",
             ref_crc_accum_r, ref_crc_accum_r ^ 32'hFFFFFFFF);
    $display("");
    $display("  --- Acceptance (post-XOR caliber) ---");
    $display("  Decoded words (latched) : %0d (expected %0d) %s",
             crc32_word_count_latched, ref_total_words_i,
             (crc32_word_count_latched == ref_total_words_i) ? "PASS" : "FAIL");
    $display("  Decoded words (live)    : %0d (expected %0d) %s",
             crc32_word_count, ref_total_words_i,
             (crc32_word_count == ref_total_words_i) ? "PASS" : "FAIL");
    $display("  CRC32 post-XOR          : 0x%08x (expected 0x%08x) %s",
             crc32_latched, ref_crc_final_r,
             (crc32_latched == ref_crc_final_r) ? "PASS" : "FAIL");
    $display("  CRC32 pre-XOR accum     : 0x%08x (expected 0x%08x) %s",
             crc32_accum, ref_crc_accum_r,
             (crc32_accum == ref_crc_accum_r) ? "PASS" : "FAIL");

    if (crc32_word_count_latched != ref_total_words_i) test_pass = 1'b0;
    if (crc32_word_count         != ref_total_words_i) test_pass = 1'b0;
    if (crc32_latched            != ref_crc_final_r)   test_pass = 1'b0;
    if (crc32_accum              != ref_crc_accum_r)   test_pass = 1'b0;
    if (ref_crc_final_r != (ref_crc_accum_r ^ 32'hFFFFFFFF)) begin
        $display("  ERROR: ref_crc.txt calibers inconsistent");
        test_pass = 1'b0;
    end
    if (app_frames_delivered != frames_driven) begin
        $display("  Frame loss: driven=%0d delivered=%0d FAIL",
                 frames_driven, app_frames_delivered);
        test_pass = 1'b0;
    end
    if (mon_err_rsp != 32'd0) begin
        $display("  Adapter emitted %0d ERROR_RSP FAIL", mon_err_rsp);
        test_pass = 1'b0;
    end

    if (test_pass)
        $display("  *** ALL TESTS PASSED ***");
    else
        $display("  *** TEST FAILED ***");
    $display("  ================================================");
    $finish;
end

// Global timeout
initial begin
    #400_000_000;
    $display("TIMEOUT at %0t", $time);
    $display("  *** TEST FAILED ***");
    $finish;
end

endmodule
