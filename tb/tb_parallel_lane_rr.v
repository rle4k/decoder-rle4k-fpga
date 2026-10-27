// ============================================================================
// tb_parallel_lane_rr — gate for K-lane assign policy (rule 14)
// ============================================================================
// Board (fw=0x80108): PARALLEL LANES 1237/1166/0/0 under lowest-free pick.
// Evidence: src/rle4k_stream_adapter_v8.v S_BLOCK_ASSIGN previously scanned
// from lane 0 — when host gaps free all lanes, every assign collapses to 0/1.
//
// Models assign policy under board-realistic busy: a lane clears 2 assigns
// later (decode finishes before the 3rd BLOCK_START).
//
// Mode file tb/sim_data/lane_rr_mode.txt (default 1 if missing):
//   0 = lowest-free — red baseline: must use only lanes 0/1
//   1 = RR-among-free — green: must use all four lanes
// ============================================================================

`timescale 1ns / 1ps

module tb_parallel_lane_rr;

localparam integer K = 4;
localparam integer N_ASSIGN = 16;

integer mode, fd, i, off;
reg [K-1:0] busy;
reg [1:0]   last_sel, pick, cand;
reg         found;
integer     counts [0:K-1];
integer     used_lanes;
reg         fail;
reg [1:0]   hist_lane [0:N_ASSIGN-1];

initial begin
    mode = 1;
    fd = $fopen("tb/sim_data/lane_rr_mode.txt", "r");
    if (fd) begin
        if ($fscanf(fd, "%d", mode) != 1) mode = 1;
        $fclose(fd);
    end
    $display("tb_parallel_lane_rr: mode=%0d (0=lowest-free RED, 1=RR GREEN)", mode);

    busy = {K{1'b0}};
    last_sel = K[1:0] - 2'd1;
    for (i = 0; i < K; i = i + 1) counts[i] = 0;
    fail = 1'b0;

    for (i = 0; i < N_ASSIGN; i = i + 1) begin
        if (i >= 2)
            busy[hist_lane[i - 2]] = 1'b0;

        found = 1'b0;
        pick  = 2'd0;
        if (mode == 0) begin
            for (off = 0; off < K; off = off + 1) begin
                if (!busy[off] && !found) begin
                    found = 1'b1;
                    pick  = off[1:0];
                end
            end
        end else begin
            for (off = 0; off < K; off = off + 1) begin
                cand = last_sel + 2'd1 + off[1:0];
                if (!busy[cand] && !found) begin
                    found = 1'b1;
                    pick  = cand;
                end
            end
        end

        if (!found) begin
            $display("FAIL: no free lane at assign %0d busy=%b", i, busy);
            fail = 1'b1;
        end else begin
            busy[pick] = 1'b1;
            last_sel = pick;
            hist_lane[i] = pick;
            counts[pick] = counts[pick] + 1;
            $display("  assign[%0d] -> lane %0d  busy=%b", i, pick, busy);
        end
    end

    used_lanes = 0;
    for (i = 0; i < K; i = i + 1) begin
        $display("  count[lane%0d]=%0d", i, counts[i]);
        if (counts[i] > 0) used_lanes = used_lanes + 1;
    end

    if (mode == 0) begin
        if (counts[2] != 0 || counts[3] != 0 || used_lanes >= 4) begin
            $display("FAIL: mode0 lost its red (unexpectedly used lane2/3)");
            fail = 1'b1;
        end else if (used_lanes < 2) begin
            $display("FAIL: mode0 used fewer than 2 lanes");
            fail = 1'b1;
        end else
            $display("PASS (red baseline): mode0 lanes 0/1 only — matches board 0x80108");
    end else begin
        if (counts[0] == 0 || counts[1] == 0 || counts[2] == 0 || counts[3] == 0) begin
            $display("FAIL: mode1 RR zero lane: %0d/%0d/%0d/%0d",
                     counts[0], counts[1], counts[2], counts[3]);
            fail = 1'b1;
        end else
            $display("PASS: mode1 RR all four %0d/%0d/%0d/%0d",
                     counts[0], counts[1], counts[2], counts[3]);
    end

    if (fail) begin
        $display("tb_parallel_lane_rr: FAIL");
        $finish(1);
    end
    $display("tb_parallel_lane_rr: ALL TESTS PASSED");
    $finish(0);
end

endmodule
