// ============================================================================
// tb_rle4k_eth_stim.vh -- raw-Ethernet stimulus helpers shared by the
//                         V08MAC integration / full-speed testbenches
// ============================================================================
// Included into a testbench that provides:
//   clk_15_625                          protocol-domain clock
//   mac_rx_data_valid / _data / _keep / _last   MAC RX drive signals (reg)
//
// Everything here builds real on-wire frames: 14-byte Ethernet II header with
// EtherType 0x4B52, then the v8 PayloadHeader (cmd, seq LE, len LE) and the
// command payload. Frames shorter than 60 bytes are zero padded exactly like a
// real NIC does, so rle4k_mac_proto_v8 sees a wire-accurate frame.
// ============================================================================

// --- Protocol constants (rle4k_cli/src/protocol_v8.h) -----------------------
localparam [7:0]  CMDB_STREAM_START = 8'h40;
localparam [7:0]  CMDB_STREAM_DATA  = 8'h41;
localparam [7:0]  CMDB_STREAM_END   = 8'h42;
localparam [7:0]  CMDB_PING         = 8'h10;
localparam [7:0]  CMDB_RESET        = 8'hF0;
localparam integer MAX_DATA_PER_FRAME = 1492;   // (1500 - 5) & ~3
localparam integer ETH_MIN_FRAME      = 60;
localparam integer FRAME_BUF_BYTES    = 1600;

localparam [47:0] FPGA_MAC_C = 48'h000A35000102;   // 00:0A:35:00:01:02
localparam [47:0] HOST_MAC_C = 48'hEEEEEEEEB64A;   // EE:EE:EE:EE:B6:4A

// --- Frame assembly buffer --------------------------------------------------
reg [7:0] fbytes [0:FRAME_BUF_BYTES-1];
integer   flen;
reg [15:0] seq_ctr;

// --- Stimulus / reference data ---------------------------------------------
localparam integer MAX_STREAM_WORDS = 262144;
reg [31:0] stream_mem [0:MAX_STREAM_WORDS-1];

integer cfg_line_width_i;
integer cfg_line_stride_i;
integer cfg_total_height_i;
integer cfg_stream_words_i;
integer cfg_block_count_i;
integer cfg_block0_height_i;
integer cfg_rle_payload_i;      // sum of BLOCKn_COMPRESSED (logical RLE bytes)
integer cfg_wire_bytes_i;       // stream_words * 4 (includes tail 0x00 pad)

integer ref_total_words_i;
reg [31:0] ref_crc_final_r;     // post-XOR  (acceptance caliber)
reg [31:0] ref_crc_accum_r;     // pre-XOR   (raw accumulator)

// ============================================================================
// Text helpers: parse "KEY VALUE" files; VALUE may be decimal or 0x-hex
// ============================================================================
function [31:0] parse_num;
    input [8*40-1:0] s;
    integer j;
    reg [7:0] c;
    reg       is_hex;
    reg [31:0] acc;
    begin
        acc    = 32'd0;
        is_hex = 1'b0;
        for (j = 39; j >= 0; j = j - 1) begin
            c = s[j*8 +: 8];
            if (c != 8'd0) begin
                if (c == "x" || c == "X") begin
                    is_hex = 1'b1;
                    acc    = 32'd0;
                end else if (c >= "0" && c <= "9")
                    acc = (is_hex ? acc * 32'd16 : acc * 32'd10) + (c - "0");
                else if (c >= "a" && c <= "f")
                    acc = acc * 32'd16 + (c - "a") + 32'd10;
                else if (c >= "A" && c <= "F")
                    acc = acc * 32'd16 + (c - "A") + 32'd10;
            end
        end
        parse_num = acc;
    end
endfunction

task load_sim_config;
    integer fh, rc;
    reg [8*40-1:0] k, v;
    begin
        cfg_line_width_i    = 0;
        cfg_line_stride_i   = 0;
        cfg_total_height_i  = 0;
        cfg_stream_words_i  = 0;
        cfg_block_count_i   = 0;
        cfg_block0_height_i = 0;
        cfg_rle_payload_i   = 0;

        fh = $fopen("../tb/sim_data/sim_config.txt", "r");
        if (fh == 0) begin
            $display("ERROR: cannot open ../tb/sim_data/sim_config.txt");
            $finish;
        end
        rc = $fscanf(fh, "%s %s", k, v);
        while (rc == 2) begin
            if      (k == "LINE_WIDTH")         cfg_line_width_i    = parse_num(v);
            else if (k == "LINE_STRIDE")        cfg_line_stride_i   = parse_num(v);
            else if (k == "TOTAL_HEIGHT")       cfg_total_height_i  = parse_num(v);
            else if (k == "STREAM_WORDS")       cfg_stream_words_i  = parse_num(v);
            else if (k == "BLOCK_COUNT")        cfg_block_count_i   = parse_num(v);
            else if (k == "BLOCK0_HEIGHT")      cfg_block0_height_i = parse_num(v);
            else if (k == "BLOCK0_COMPRESSED")  cfg_rle_payload_i   = cfg_rle_payload_i + parse_num(v);
            else if (k == "BLOCK1_COMPRESSED")  cfg_rle_payload_i   = cfg_rle_payload_i + parse_num(v);
            else if (k == "BLOCK2_COMPRESSED")  cfg_rle_payload_i   = cfg_rle_payload_i + parse_num(v);
            else if (k == "BLOCK3_COMPRESSED")  cfg_rle_payload_i   = cfg_rle_payload_i + parse_num(v);
            else if (k == "BLOCK4_COMPRESSED")  cfg_rle_payload_i   = cfg_rle_payload_i + parse_num(v);
            else if (k == "BLOCK5_COMPRESSED")  cfg_rle_payload_i   = cfg_rle_payload_i + parse_num(v);
            else if (k == "BLOCK6_COMPRESSED")  cfg_rle_payload_i   = cfg_rle_payload_i + parse_num(v);
            else if (k == "BLOCK7_COMPRESSED")  cfg_rle_payload_i   = cfg_rle_payload_i + parse_num(v);
            rc = $fscanf(fh, "%s %s", k, v);
        end
        $fclose(fh);

        cfg_wire_bytes_i = cfg_stream_words_i * 4;
        if (cfg_rle_payload_i == 0 || cfg_rle_payload_i > cfg_wire_bytes_i)
            cfg_rle_payload_i = cfg_wire_bytes_i;   // fallback: no tail padding info
    end
endtask

task load_ref_crc;
    integer fh, rc;
    reg [8*40-1:0] k, v;
    begin
        ref_total_words_i = 0;
        ref_crc_final_r   = 32'd0;
        ref_crc_accum_r   = 32'd0;
        fh = $fopen("../tb/sim_data/ref_crc.txt", "r");
        if (fh == 0) begin
            $display("ERROR: cannot open ../tb/sim_data/ref_crc.txt");
            $finish;
        end
        rc = $fscanf(fh, "%s %s", k, v);
        while (rc == 2) begin
            if      (k == "TOTAL_WORDS") ref_total_words_i = parse_num(v);
            else if (k == "CRC32_FINAL") ref_crc_final_r   = parse_num(v);
            else if (k == "CRC32_ACCUM") ref_crc_accum_r   = parse_num(v);
            rc = $fscanf(fh, "%s %s", k, v);
        end
        $fclose(fh);
    end
endtask

function [7:0] stream_byte;
    input integer idx;
    begin
        stream_byte = stream_mem[idx >> 2][(idx % 4) * 8 +: 8];
    end
endfunction

// ============================================================================
// Frame builders
// ============================================================================
task put_u16le;
    input integer off;
    input [15:0]  v;
    begin
        fbytes[off]   = v[7:0];
        fbytes[off+1] = v[15:8];
    end
endtask

task put_u32le;
    input integer off;
    input [31:0]  v;
    begin
        fbytes[off]   = v[7:0];
        fbytes[off+1] = v[15:8];
        fbytes[off+2] = v[23:16];
        fbytes[off+3] = v[31:24];
    end
endtask

// Ethernet II header + v8 PayloadHeader. Returns first payload-data offset (19).
task build_hdr;
    input [7:0]  cmd;
    input [15:0] datalen;
    integer i;
    begin
        for (i = 0; i < FRAME_BUF_BYTES; i = i + 1)
            fbytes[i] = 8'h00;
        // DA = FPGA MAC
        fbytes[0] = FPGA_MAC_C[47:40];  fbytes[1] = FPGA_MAC_C[39:32];
        fbytes[2] = FPGA_MAC_C[31:24];  fbytes[3] = FPGA_MAC_C[23:16];
        fbytes[4] = FPGA_MAC_C[15:8];   fbytes[5] = FPGA_MAC_C[7:0];
        // SA = host MAC
        fbytes[6]  = HOST_MAC_C[47:40]; fbytes[7]  = HOST_MAC_C[39:32];
        fbytes[8]  = HOST_MAC_C[31:24]; fbytes[9]  = HOST_MAC_C[23:16];
        fbytes[10] = HOST_MAC_C[15:8];  fbytes[11] = HOST_MAC_C[7:0];
        // EtherType 0x4B52, big endian on the wire
        fbytes[12] = 8'h4B;
        fbytes[13] = 8'h52;
        // PayloadHeader: cmd(1) seq(2 LE) len(2 LE)
        fbytes[14] = cmd;
        put_u16le(15, seq_ctr);
        put_u16le(17, datalen);
        seq_ctr = seq_ctr + 16'd1;
        flen = 19 + datalen;
        if (flen < ETH_MIN_FRAME) flen = ETH_MIN_FRAME;
    end
endtask

task build_reset_frame;
    begin
        seq_ctr = 16'd0;
        build_hdr(CMDB_RESET, 16'd0);
    end
endtask

task build_ping_frame;
    begin
        build_hdr(CMDB_PING, 16'd0);
    end
endtask

// StreamStartPayload (24 B) at payload offset 5 == frame offset 19
task build_stream_start_frame_ex;
    input [31:0] lw;
    input [31:0] ls;
    input [31:0] th;
    input [31:0] wire_bytes;
    input [15:0] bh;
    input [31:0] rpb;
    begin
        build_hdr(CMDB_STREAM_START, 16'd24);
        put_u32le(19, lw);          // line_width_bits
        put_u32le(23, ls);          // line_stride_bits
        put_u32le(27, th);          // total_height
        put_u32le(31, wire_bytes);  // total_bytes (wire, padded)
        put_u16le(35, 16'd0);       // strip_index
        put_u16le(37, bh);          // default block_height
        put_u32le(39, rpb);         // rle_payload_bytes (logical)
    end
endtask

task build_stream_start_frame;
    begin
        build_stream_start_frame_ex(cfg_line_width_i, cfg_line_stride_i,
                                    cfg_total_height_i, cfg_wire_bytes_i,
                                    cfg_block0_height_i, cfg_rle_payload_i);
    end
endtask

task build_stream_data_frame;
    input integer offset;
    input integer nbytes;
    integer i;
    begin
        build_hdr(CMDB_STREAM_DATA, nbytes);
        for (i = 0; i < nbytes; i = i + 1)
            fbytes[19 + i] = stream_byte(offset + i);
    end
endtask

task build_stream_end_frame;
    begin
        build_hdr(CMDB_STREAM_END, 16'd0);
    end
endtask

// ============================================================================
// Wire driver: push fbytes[0..flen-1] into the MAC RX interface,
// 64-bit little endian, one word per clk_15_625 cycle (no bubbles).
// ============================================================================
integer frames_driven;
integer words_driven;

task drive_frame;
    input integer gap_cycles;
    integer nwords, w, b, idx;
    reg [63:0] d;
    reg [7:0]  k;
    begin
        nwords = (flen + 7) / 8;
        for (w = 0; w < nwords; w = w + 1) begin
            d = 64'd0;
            k = 8'd0;
            for (b = 0; b < 8; b = b + 1) begin
                idx = w * 8 + b;
                if (idx < flen) begin
                    d[b*8 +: 8] = fbytes[idx];
                    k[b]        = 1'b1;
                end
            end
            @(negedge clk_15_625);
            mac_rx_data       = d;
            mac_rx_keep       = k;
            mac_rx_last       = (w == nwords - 1);
            mac_rx_data_valid = 1'b1;
            words_driven      = words_driven + 1;
            // Hold the beat until the sink takes it. mac_rx_ready is registered
            // state, so its value at this negedge is what the next posedge sees.
            while (!mac_rx_ready) @(negedge clk_15_625);
        end
        @(negedge clk_15_625);
        mac_rx_data_valid = 1'b0;
        mac_rx_last       = 1'b0;
        mac_rx_keep       = 8'd0;
        mac_rx_data       = 64'd0;
        frames_driven     = frames_driven + 1;
        if (gap_cycles > 0)
            repeat (gap_cycles) @(negedge clk_15_625);
    end
endtask

// Back-to-back variant: no trailing idle cycle at all, so the next frame's
// first word lands on the cycle immediately after tlast. Zero inter-frame gap.
// Caller must call end_burst() after the last frame of the burst.
task drive_frame_btb;
    integer nwords, w, b, idx;
    reg [63:0] d;
    reg [7:0]  k;
    begin
        nwords = (flen + 7) / 8;
        for (w = 0; w < nwords; w = w + 1) begin
            d = 64'd0;
            k = 8'd0;
            for (b = 0; b < 8; b = b + 1) begin
                idx = w * 8 + b;
                if (idx < flen) begin
                    d[b*8 +: 8] = fbytes[idx];
                    k[b]        = 1'b1;
                end
            end
            @(negedge clk_15_625);
            mac_rx_data       = d;
            mac_rx_keep       = k;
            mac_rx_last       = (w == nwords - 1);
            mac_rx_data_valid = 1'b1;
            words_driven      = words_driven + 1;
            while (!mac_rx_ready) @(negedge clk_15_625);
        end
        frames_driven = frames_driven + 1;
    end
endtask

task end_burst;
    begin
        @(negedge clk_15_625);
        mac_rx_data_valid = 1'b0;
        mac_rx_last       = 1'b0;
        mac_rx_keep       = 8'd0;
        mac_rx_data       = 64'd0;
    end
endtask
