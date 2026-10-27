// ============================================================================
// tb_parallel_feed_overlap — rule-14 gate for parallel compressed feed
// ============================================================================
// Board (fw=0x8010D): LANE_OVERLAP ge2≈15% because STREAM_FEED stalled on a
// shallow per-lane CDC — the shared adapter could not ASSIGN/feed lane N+1
// while lane N still held mid-block occupancy of the feed FSM.
//
// This TB models K=4 lanes with independent input buffers + a serial adapter
// that only feeds one lane at a time (matches protocol: BLOCK_START then all
// DATA for that block). Decode drains 1 word / N_DEC cycles per busy lane.
//
// Mode file tb/sim_data/feed_depth_mode.txt (default 1 if missing):
//   0 = shallow (512)  — RED: feed stalls mid-block → peak concurrent < 4,
//                        ge2_pct stays low (< 25%) over the send window
//   1 = deep (16384+stg) — GREEN: each block dumps without stall → all 4
//                        lanes hold in-flight data → ge2_pct >> 25%
// ============================================================================

`timescale 1ns / 1ps

module tb_parallel_feed_overlap;

localparam integer K           = 4;
localparam integer N_BLOCKS    = 8;
localparam integer WORDS_BLOCK = 2048;   // compressed words / block
localparam integer N_DEC       = 8;      // decode ticks per consumed word
localparam integer SAMPLE_MAX  = 200000;

integer mode, fd, bi, wi, li, t, peeks;
integer depth_lim;
integer buf_count [0:K-1];
reg     lane_busy [0:K-1];
integer decode_div [0:K-1];
integer last_sel, pick, cand, off;
reg     found;
integer busy_pop;
integer sample_cyc, ge2_cyc, ge3_cyc, ge4_cyc;
integer peak_busy;
reg     feeding;
integer feed_lane, feed_left;
integer stall_cycles;
real    ge2_pct;
reg     fail;

function integer popcount4;
    input integer b0, b1, b2, b3;
    begin
        popcount4 = b0 + b1 + b2 + b3;
    end
endfunction

task sample_overlap;
    begin
        busy_pop = popcount4(lane_busy[0], lane_busy[1], lane_busy[2], lane_busy[3]);
        if (busy_pop > peak_busy) peak_busy = busy_pop;
        sample_cyc = sample_cyc + 1;
        if (busy_pop >= 2) ge2_cyc = ge2_cyc + 1;
        if (busy_pop >= 3) ge3_cyc = ge3_cyc + 1;
        if (busy_pop >= 4) ge4_cyc = ge4_cyc + 1;
    end
endtask

task drain_one_tick;
    begin
        for (li = 0; li < K; li = li + 1) begin
            if (lane_busy[li]) begin
                if (buf_count[li] > 0) begin
                    if (decode_div[li] == 0) begin
                        buf_count[li] = buf_count[li] - 1;
                        decode_div[li] = N_DEC - 1;
                    end else
                        decode_div[li] = decode_div[li] - 1;
                end else begin
                    // Empty buffer: block done
                    lane_busy[li] = 1'b0;
                    decode_div[li] = 0;
                end
            end
        end
    end
endtask

task assign_lane;
    output integer out_lane;
    begin
        found = 1'b0;
        pick  = 0;
        for (off = 0; off < K; off = off + 1) begin
            cand = (last_sel + 1 + off) % K;
            if (!lane_busy[cand] && !found) begin
                found = 1'b1;
                pick  = cand;
            end
        end
        if (!found) begin
            $display("FAIL: no free lane (all busy) at block boundary");
            fail = 1'b1;
            out_lane = 0;
        end else begin
            last_sel = pick;
            lane_busy[pick] = 1'b1;
            decode_div[pick] = N_DEC - 1;
            out_lane = pick;
        end
    end
endtask

initial begin
    mode = 1;
    fd = $fopen("tb/sim_data/feed_depth_mode.txt", "r");
    if (!fd) fd = $fopen("../tb/sim_data/feed_depth_mode.txt", "r");
    if (!fd) fd = $fopen("../../tb/sim_data/feed_depth_mode.txt", "r");
    if (fd) begin
        if ($fscanf(fd, "%d", mode) != 1) mode = 1;
        $fclose(fd);
    end
    depth_lim = (mode == 0) ? 512 : 16384;
    $display("tb_parallel_feed_overlap: mode=%0d depth_lim=%0d (0=shallow RED, 1=deep GREEN)",
             mode, depth_lim);

    for (li = 0; li < K; li = li + 1) begin
        buf_count[li]  = 0;
        lane_busy[li]  = 1'b0;
        decode_div[li] = 0;
    end
    last_sel     = K - 1;
    sample_cyc   = 0;
    ge2_cyc      = 0;
    ge3_cyc      = 0;
    ge4_cyc      = 0;
    peak_busy    = 0;
    feeding      = 0;
    feed_lane    = 0;
    feed_left    = 0;
    stall_cycles = 0;
    fail         = 1'b0;
    bi           = 0;

    // Drive N_BLOCKS: ASSIGN then push WORDS_BLOCK into that lane's buffer,
    // stalling when buf_count[lane] >= depth_lim (models CDC almost_full).
    // Between push attempts, all busy lanes decode one tick — board-realistic.
    for (t = 0; t < SAMPLE_MAX && (bi < N_BLOCKS || feeding ||
         lane_busy[0] || lane_busy[1] || lane_busy[2] || lane_busy[3]);
         t = t + 1) begin

        if (!feeding && bi < N_BLOCKS) begin
            // Wait until a free lane exists
            busy_pop = popcount4(lane_busy[0], lane_busy[1], lane_busy[2], lane_busy[3]);
            if (busy_pop < K) begin
                assign_lane(feed_lane);
                feeding   = 1'b1;
                feed_left = WORDS_BLOCK;
                bi        = bi + 1;
                $display("  BLOCK_START[%0d] -> lane %0d  busy=%0d/%0d/%0d/%0d",
                         bi - 1, feed_lane,
                         lane_busy[0], lane_busy[1], lane_busy[2], lane_busy[3]);
            end
        end

        if (feeding) begin
            if (buf_count[feed_lane] < depth_lim && feed_left > 0) begin
                buf_count[feed_lane] = buf_count[feed_lane] + 1;
                feed_left = feed_left - 1;
                if (feed_left == 0) begin
                    feeding = 1'b0;
                    $display("  FEED_DONE lane %0d  buf=%0d  peak_busy_so_far=%0d",
                             feed_lane, buf_count[feed_lane], peak_busy);
                end
            end else if (feed_left > 0) begin
                stall_cycles = stall_cycles + 1;
            end
        end

        drain_one_tick;
        sample_overlap;
    end

    if (sample_cyc == 0) begin
        $display("FAIL: no samples");
        fail = 1'b1;
    end
    ge2_pct = 100.0 * ge2_cyc / sample_cyc;

    $display("RESULT peak_busy=%0d ge2_pct=%0.2f ge3=%0d ge4=%0d sample=%0d stall=%0d",
             peak_busy, ge2_pct, ge3_cyc, ge4_cyc, sample_cyc, stall_cycles);

    if (mode == 0) begin
        // Shallow: must stall; cannot sustain 4-lane in-flight (board 8010D story).
        if (stall_cycles < 100) begin
            $display("FAIL: mode0 lost its red (expected mid-feed stalls, stall=%0d)",
                     stall_cycles);
            fail = 1'b1;
        end else if (peak_busy >= 4 || ge4_cyc != 0) begin
            $display("FAIL: mode0 lost its red (peak=%0d ge4=%0d — 4-lane in-flight)",
                     peak_busy, ge4_cyc);
            fail = 1'b1;
        end else if (ge2_pct >= 40.0) begin
            $display("FAIL: mode0 ge2_pct=%0.2f too high for shallow red baseline", ge2_pct);
            fail = 1'b1;
        end else
            $display("PASS (red baseline): shallow stalls=%0d ge2_pct=%0.2f peak=%0d",
                     stall_cycles, ge2_pct, peak_busy);
    end else begin
        // Deep: dump without stall; 4 lanes must be simultaneously in-flight.
        if (stall_cycles != 0) begin
            $display("FAIL: mode1 unexpected stalls=%0d", stall_cycles);
            fail = 1'b1;
        end else if (peak_busy < 4) begin
            $display("FAIL: mode1 peak_busy=%0d (need 4 lanes in-flight)", peak_busy);
            fail = 1'b1;
        end else if (ge2_pct < 40.0) begin
            $display("FAIL: mode1 ge2_pct=%0.2f (need >>15%% board baseline)", ge2_pct);
            fail = 1'b1;
        end else if (ge3_cyc == 0 || ge4_cyc == 0) begin
            $display("FAIL: mode1 missing ge3/ge4 (ge3=%0d ge4=%0d)", ge3_cyc, ge4_cyc);
            fail = 1'b1;
        end else
            $display("PASS: deep feed ge2_pct=%0.2f peak=%0d ge3=%0d ge4=%0d",
                     ge2_pct, peak_busy, ge3_cyc, ge4_cyc);
    end

    if (fail) begin
        $display("tb_parallel_feed_overlap: FAIL");
        $finish(1);
    end
    $display("tb_parallel_feed_overlap: ALL TESTS PASSED");
    $finish(0);
end

endmodule
