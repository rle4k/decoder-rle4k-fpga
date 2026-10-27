// ============================================================================
// tb_rle4k_fullspeed -- zero inter-frame-gap stress of the shipped RX/TX path
// ============================================================================
// Same chain as tb_rle4k_integration (tb_rle4k_chain = rle4k_lan_top_v8 minus
// the Xilinx IP), but the STREAM_DATA frames are driven back to back with no
// idle cycle at all between tlast and the next frame's first word.
//
// This is a DIAGNOSTIC testbench, not a pass/fail gate: it quantifies the two
// suspected frame-loss defects.
//
//   Phase A -- RX back-pressure.
//     master_wrapper_v8 leaves rx_axis_dwidth_converter0.s_axis_tready
//     unconnected (line 266) and ties rx_packet_fifo0.m_axis_tready to 1'b1
//     (line 305), so nothing can stall the RX stream. Meanwhile
//     rle4k_mac_proto_v8 only consumes words in RXS_CAPTURE; while it is in
//     RXS_CHECK / RXS_REPLAY, and while rle4k_stream_adapter_v8 is busy in
//     S_STREAM_FEED, arriving frames are silently discarded.
//
//   Phase B -- TX back-pressure.
//     rle4k_mac_proto_v8 declares mac_tx_ready (line 34) but its TX FSM never
//     reads it, so mac_tx_data_valid is asserted regardless. Holding
//     mac_tx_ready low and counting valid cycles measures exactly how many
//     words a real AXI-Stream FIFO would drop.
// ============================================================================

`timescale 1ns / 1ps

module tb_rle4k_fullspeed;

reg clk_125    = 1'b0;
reg clk_15_625 = 1'b0;
always #4  clk_125    = ~clk_125;
always #32 clk_15_625 = ~clk_15_625;

reg locked     = 1'b0;
reg core_reset = 1'b1;

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

tb_rle4k_chain #(
    .LOCAL_MAC (48'h000A35000102)
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
integer app_frames_delivered   = 0;  // frames mac_proto replayed to the adapter
integer dec_words_fed          = 0;
integer data_frames_sent       = 0;
integer sent_while_mac_busy    = 0;  // frame started while rx_state != RXS_CAPTURE
integer sent_while_adapter_busy= 0;  // frame started while adapter != S_RX_IDLE
integer tx_valid_while_nready  = 0;  // Phase B: words a real FIFO would drop
integer tx_valid_total         = 0;

// Per-block trace, mirroring tb_rle4k_integration so the two runs can be
// compared block by block rather than only on the final CRC.
integer block_done_edges       = 0;
integer strip_end_edges        = 0;
reg     block_done_d           = 1'b0;
reg     strip_end_d            = 1'b0;

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

integer phase_b_stalled        = 0;
integer phase_b_leaked         = 0;
integer tx_words_accepted      = 0;  // beats that actually completed a handshake
integer tx_beat_mutated        = 0;  // payload changed while a beat was rejected
reg [63:0] tx_hold_data        = 64'd0;
reg        tx_hold_active      = 1'b0;

always @(posedge clk_15_625) begin
    if (app_rx_data_valid && app_rx_data_last)
        app_frames_delivered = app_frames_delivered + 1;
    if (dec_valid)
        dec_words_fed = dec_words_fed + 1;
    if (mac_tx_data_valid) begin
        tx_valid_total = tx_valid_total + 1;
        if (!mac_tx_ready)
            tx_valid_while_nready = tx_valid_while_nready + 1;
    end
    if (mac_tx_data_valid && mac_tx_ready)
        tx_words_accepted = tx_words_accepted + 1;

    // A rejected beat must be re-presented byte for byte. Catching a mutation
    // here is what separates "held correctly" from "advanced and lost a word".
    if (mac_tx_data_valid && !mac_tx_ready) begin
        if (tx_hold_active && tx_hold_data !== mac_tx_data)
            tx_beat_mutated = tx_beat_mutated + 1;
        tx_hold_data   <= mac_tx_data;
        tx_hold_active <= 1'b1;
    end else begin
        tx_hold_active <= 1'b0;
    end
end

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
integer guard_cnt;
integer expected_frames;
integer i;
integer gap_cycles;
integer gap_fh;
integer gap_rc;

initial begin
    frames_driven = 0;
    words_driven  = 0;
    seq_ctr       = 16'd0;
    // The gap comes from a file rather than a plusarg because cmd.exe eats the
    // '=' in -testplusarg when xsim is launched through its .bat wrapper.
    gap_cycles = 0;
    gap_fh = $fopen("../tb/sim_data/fullspeed_gap.txt", "r");
    if (gap_fh != 0) begin
        gap_rc = $fscanf(gap_fh, "%d", gap_cycles);
        if (gap_rc != 1) gap_cycles = 0;
        $fclose(gap_fh);
    end

    load_sim_config();
    load_ref_crc();
    $readmemh("../tb/sim_data/stream_data.hex", stream_mem);

    expected_frames = (cfg_wire_bytes_i + MAX_DATA_PER_FRAME - 1) / MAX_DATA_PER_FRAME;

    $display("================================================================");
    $display(" tb_rle4k_fullspeed -- zero inter-frame-gap stress (diagnostic)");
    $display("================================================================");
    $display("  wire_bytes=%0d rle_payload_bytes=%0d chunk=%0d -> %0d STREAM_DATA frames",
             cfg_wire_bytes_i, cfg_rle_payload_i, MAX_DATA_PER_FRAME, expected_frames);
    $display("  ref TOTAL_WORDS=%0d CRC32_FINAL(post-XOR)=0x%08x CRC32_ACCUM(pre-XOR)=0x%08x",
             ref_total_words_i, ref_crc_final_r, ref_crc_accum_r);

    core_reset = 1'b1;
    locked     = 1'b0;
    repeat (5)  @(negedge clk_15_625);
    locked     = 1'b1;
    repeat (10) @(negedge clk_15_625);
    core_reset = 1'b0;
    repeat (10) @(negedge clk_15_625);

    // --- Setup frames are paced so the configuration itself is never in doubt
    build_reset_frame();
    drive_frame(0);
    wait_chain_idle();
    repeat (20) @(negedge clk_15_625);

    build_stream_start_frame();
    drive_frame(0);
    wait_chain_idle();
    $display("[%0t] STREAM_START applied: lw=%0d ls=%0d bh=%0d strip_lines=%0d",
             $time, u_chain.cfg_line_width, u_chain.cfg_line_stride,
             u_chain.cfg_block_height, u_chain.cfg_strip_line_count_mac);

    // ========================================================================
    // Phase A: STREAM_DATA at line rate, zero inter-frame gap
    // ========================================================================
    $display("");
    $display("--- Phase A: %0d STREAM_DATA frames, inter-frame gap = %0d cycles ---",
             expected_frames, gap_cycles);
    offset = 0;
    while (offset < cfg_wire_bytes_i) begin
        chunk = cfg_wire_bytes_i - offset;
        if (chunk > MAX_DATA_PER_FRAME) chunk = MAX_DATA_PER_FRAME;
        build_stream_data_frame(offset, chunk);
        if (u_chain.u_mac_proto.rx_state !== 2'd0) begin
            sent_while_mac_busy = sent_while_mac_busy + 1;
            $display("[%0t] frame %0d starts while mac_proto rx_state=%0d (not RXS_CAPTURE)",
                     $time, data_frames_sent, u_chain.u_mac_proto.rx_state);
        end
        if (u_chain.u_adapter.state !== 6'd0) begin
            sent_while_adapter_busy = sent_while_adapter_busy + 1;
            $display("[%0t] frame %0d starts while adapter state=%0d (not S_RX_IDLE)",
                     $time, data_frames_sent, u_chain.u_adapter.state);
        end
        // +gap=N pads N idle cycles between frames so the zero-gap result can be
        // bisected against a paced one without touching the integration gate.
        if (gap_cycles == 0)
            drive_frame_btb();
        else
            drive_frame(gap_cycles);
        offset           = offset + chunk;
        data_frames_sent = data_frames_sent + 1;
    end
    if (gap_cycles == 0) end_burst();
    $display("[%0t] Phase A burst done: %0d frames driven with zero gap",
             $time, data_frames_sent);

    // Let whatever survived work its way through, then close the stream.
    wait_pipeline_drained();
    build_stream_end_frame();
    drive_frame(0);

    guard_cnt = 0;
    while (!crc32_done && guard_cnt < 4_000_000) begin
        @(posedge clk_125);
        guard_cnt = guard_cnt + 1;
    end
    repeat (200) @(posedge clk_125);

    $display("");
    $display("  ======== PHASE A: RX FULL-SPEED RESULT ========");
    $display("  STREAM_DATA frames sent on the wire      : %0d", data_frames_sent);
    $display("  Frames accepted+replayed by mac_proto    : %0d", app_frames_delivered - 2);
    $display("     (total app_rx frames incl. RESET/START: %0d)", app_frames_delivered);
    $display("  Frames dispatched by adapter (rx_datagrams): %0d", mon_rx_datagrams);
    $display("  STREAM_DATA seen by adapter (mon)        : %0d (expected %0d)",
             mon_stream_data, expected_frames);
    $display("  Frames started while mac_proto busy      : %0d", sent_while_mac_busy);
    $display("  Frames started while adapter busy        : %0d", sent_while_adapter_busy);
    $display("  Bytes fed to CDC FIFO                    : %0d (expected %0d) -> %0d bytes lost",
             stream_rx_bytes, cfg_wire_bytes_i, cfg_wire_bytes_i - stream_rx_bytes);
    $display("  32-bit words fed to CDC                  : %0d (expected %0d)",
             dec_words_fed, cfg_stream_words_i);
    $display("  Decoded words                            : %0d (expected %0d)",
             crc32_word_count, ref_total_words_i);
    $display("  CRC32 pre-XOR  accumulator               : 0x%08x (expected 0x%08x)",
             crc32_accum, ref_crc_accum_r);
    $display("  CRC32 post-XOR (accum ^ 0xFFFFFFFF)      : 0x%08x (expected 0x%08x)",
             crc32_accum ^ 32'hFFFFFFFF, ref_crc_final_r);
    $display("  CRC32 post-XOR latched on strip_end      : 0x%08x  done=%0d",
             crc32_latched, crc32_done);
    $display("  Adapter ERROR_RSP count                  : %0d", mon_err_rsp);
    $display("  CDC writes discarded on overflow         : %0d (must be 0)",
             u_chain.u_cdc_fifo.dbg_overflow_drops);

    if (mon_stream_data != expected_frames || stream_rx_bytes != cfg_wire_bytes_i)
        $display("  >>> RX FRAME LOSS PROVEN <<<");
    else
        $display("  >>> no RX frame loss observed <<<");

    // ========================================================================
    // Phase B: TX FSM ignores mac_tx_ready
    // ========================================================================
    $display("");
    // A PONG is a 19-byte frame: two full header words plus a 3-byte tail.
    $display("--- Phase B: reject every TX beat, then release ---");
    tx_valid_total        = 0;
    tx_valid_while_nready = 0;
    tx_words_accepted     = 0;
    tx_beat_mutated       = 0;

    mac_tx_ready = 1'b0;
    build_ping_frame();
    drive_frame(0);
    repeat (400) @(negedge clk_15_625);

    phase_b_stalled  = tx_valid_while_nready;
    phase_b_leaked   = tx_words_accepted;

    // Release and let the held frame drain.
    mac_tx_ready = 1'b1;
    repeat (200) @(negedge clk_15_625);

    $display("  ======== PHASE B: TX BACK-PRESSURE RESULT ========");
    $display("  Cycles a beat was held under ready=0 : %0d", phase_b_stalled);
    $display("  Beats that completed while ready=0   : %0d (must be 0)", phase_b_leaked);
    $display("  Payload mutated while being rejected : %0d (must be 0)", tx_beat_mutated);
    $display("  Beats accepted after release         : %0d (expect 3 for a PONG)",
             tx_words_accepted);

    if (phase_b_stalled == 0)
        $display("  >>> INCONCLUSIVE: back-pressure was never exercised <<<");
    else if (phase_b_leaked != 0 || tx_beat_mutated != 0)
        $display("  >>> TX FSM IGNORES mac_tx_ready <<<");
    else if (tx_words_accepted != 3)
        $display("  >>> TX FRAME INCOMPLETE: %0d/3 beats <<<", tx_words_accepted);
    else
        $display("  >>> TX honours mac_tx_ready, frame delivered intact <<<");
    $display("  ==================================================");
    $finish;
end

initial begin
    #400_000_000;
    $display("TIMEOUT at %0t", $time);
    $finish;
end

endmodule
