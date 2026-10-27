// RLE4K Protocol v0.8 — Raw Ethernet (MAC layer)
// V08LAN: replaces UDP with raw Ethernet frames using EtherType 0x4B52.
// Payload format is identical to V07: PayloadHeader(5) + data.
// Transport changed from UDP socket to Npcap raw Ethernet.

#ifndef RLE4K_PROTOCOL_V8_H
#define RLE4K_PROTOCOL_V8_H

#include <cstdint>
#include <cstring>
#include <array>

namespace rle4k {

// --- Ethernet ---
static constexpr uint16_t ETHERTYPE_RLE4K = 0x4B52;
static constexpr size_t   ETH_HEADER_SIZE = 14;        // DA(6) + SA(6) + EtherType(2)
static constexpr size_t   ETH_FRAME_MAX   = 1514;      // standard Ethernet II max
static constexpr size_t   ETH_PAYLOAD_MAX = ETH_FRAME_MAX - ETH_HEADER_SIZE; // 1500

// --- Protocol Payload ---
static constexpr size_t PAYLOAD_HEADER_SIZE = 5;        // cmd(1) + seq(2) + len(2)
static constexpr size_t MAX_DATA_PER_FRAME  = (ETH_PAYLOAD_MAX - PAYLOAD_HEADER_SIZE) & ~3u; // 1492 (4-byte aligned for FPGA 32-bit feed)

// --- MAC addresses ---
static constexpr uint8_t FPGA_MAC[6] = {0x00, 0x0A, 0x35, 0x00, 0x01, 0x02};
static constexpr uint8_t BROADCAST_MAC[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

// --- Command Bytes (same as V07) ---
enum class Cmd : uint8_t {
    STREAM_START       = 0x40,
    STREAM_DATA        = 0x41,
    STREAM_END         = 0x42,
    /** Per-block boundary for K-parallel dispatch (V1023 e2). Payload: StreamBlockStartPayload. */
    STREAM_BLOCK_START = 0x43,

    PING         = 0x10,
    PONG         = 0x11,
    ECHO_REQ     = 0x12,
    ECHO_RSP     = 0x13,
    STATUS_REQ   = 0x20,
    STATUS_RSP   = 0x21,
    GET_REQ      = 0x22,
    GET_RSP      = 0x23,
    RESET        = 0xF0,
    ERROR_RSP    = 0xFE,
};

// --- GET item id space ---
enum class GetItemId : uint16_t {
    VERSION             = 0x0101,
    FORMATS             = 0x0102,
    LIST                = FORMATS,
    MAC                 = 0x0103,
    FPGA                = 0x0104,
    DDR4                = 0x0201,
    WINDOW              = 0x0301,
    STATUS_RX_BYTES     = 0x0401,
    STATUS_DECODE_BYTES = 0x0402,
    STATUS_RETX_COUNT   = 0x0403,
    STATUS_GROUP        = 0x0400,
    DECODE_CRC          = 0x0501,
    /** Per-block CRC query/status for K-parallel (see DecodeBlockCrcPayload). */
    DECODE_BLOCK_CRC    = 0x0502,
    /** Parallel decode bank info: K, W, mode flags (see ParallelInfoPayload). */
    PARALLEL_INFO       = 0x0503,
    /** Activity watchdog: cumulative soft-reset count, current tick counter, threshold ticks @ 15.625 MHz */
    ACTIVITY_WDT        = 0x0601,
    /**
     * Retransmit request (STUB / protocol gap): not yet a host→FPGA command.
     * FPGA may raise STATUS_RETX_COUNT / WINDOW retx_pending; frame format TBD.
     */
    RETX_REQ_STUB       = 0x0701,
    ALL                 = 0xFFFF,
};

enum class ValueType : uint8_t {
    VT_NULL        = 0x00,
    VT_U8          = 0x01,
    VT_U16         = 0x02,
    VT_U32         = 0x03,
    VT_U64         = 0x04,
    VT_STRING      = 0x10,
    VT_MAC6        = 0x11,
    VT_INT4_PACKED = 0x20,
    VT_TLV_LIST    = 0xF0,
};

// --- Payload Structures ---
#pragma pack(push, 1)
struct PayloadHeader {
    uint8_t  cmd;
    uint16_t seq;
    uint16_t len;
};
static_assert(sizeof(PayloadHeader) == 5, "PayloadHeader must be 5 bytes");
#pragma pack(pop)

#pragma pack(push, 1)
struct StreamStartPayload {
    uint32_t line_width_bits;
    uint32_t line_stride_bits;
    uint32_t total_height;
    // Wire length of all STREAM_DATA payloads for this strip (bytes): sum of block compressed
    // payloads plus 0..3 trailing 0x00 bytes so length % 4 == 0 (32b CDC + input_fifo_32to8).
    uint32_t total_bytes;
    uint16_t strip_index;
    uint16_t block_height;   // default block height (e.g. 512); last block = total_height mod this
    // Logical RLE compressed bytes (sum of .rle4k compressed), WITHOUT tail 0x00 alignment.
    // FPGA uses this to gate bytes into the code parser; tail bytes only shift through input_fifo_32to8.
    uint32_t rle_payload_bytes;
};
static_assert(sizeof(StreamStartPayload) == 24, "StreamStartPayload must be 24 bytes");
#pragma pack(pop)

/** STREAM_BLOCK_START payload — one frame before each block's STREAM_DATA. */
#pragma pack(push, 1)
struct StreamBlockStartPayload {
    uint32_t block_index;         // logical block index in strip
    uint32_t block_height;        // lines in this block (may be < default for tail)
    uint32_t rle_payload_bytes;   // compressed bytes for this block (no tail pad)
    uint32_t reserved;            // keep 16 B; must be 0
};
static_assert(sizeof(StreamBlockStartPayload) == 16, "StreamBlockStartPayload must be 16 bytes");
#pragma pack(pop)

// --- Version Payloads ---
#pragma pack(push, 1)
struct VersionInfoPayload {
    uint8_t  firmware_version[4];
    uint8_t  hardware_version[4];
    uint32_t firmware_date;
    uint16_t firmware_publisher;
    uint16_t board_vendor;
    uint32_t board_date;
    uint8_t  reserved[44];
};
static_assert(sizeof(VersionInfoPayload) == 64, "VersionInfoPayload must be 64 bytes");

/** GET(VERSION): 20-byte compact layout returned by current firmware (see CLI hardware --version). */
struct Rle4kVersionPayload20 {
    uint32_t firmware_version;
    uint32_t board_version;
    uint32_t board_vendor;
    uint32_t firmware_builder;
    uint32_t firmware_burn_time;
};
static_assert(sizeof(Rle4kVersionPayload20) == 20, "Rle4kVersionPayload20 must be 20 bytes");
#pragma pack(pop)

enum class GetStatus : uint8_t {
    OK = 0,
    NOT_FOUND = 1,
    BAD_REQ = 2,
};

#pragma pack(push, 1)
struct GetReqPayload {
    uint16_t item_id;
};
static_assert(sizeof(GetReqPayload) == 2, "GetReqPayload must be 2 bytes");

/** Optional extension for GET(DECODE_BLOCK_CRC): item_id + u32 LE block_index.
 *  fw >= 0x80106 reads the CRC slot file at that index; older fw ignores the
 *  trailing u32 and returns last_block_* (last completed only). */
struct GetReqDecodeBlockCrc {
    uint16_t item_id;
    uint32_t block_index;
};
static_assert(sizeof(GetReqDecodeBlockCrc) == 6, "GetReqDecodeBlockCrc must be 6 bytes");

struct GetRspHeader {
    uint8_t  status;
    uint16_t item_id;
    uint8_t  value_type;
    uint16_t value_len;
};
static_assert(sizeof(GetRspHeader) == 6, "GetRspHeader must be 6 bytes");

struct GetTlvEntryHeader {
    uint16_t item_id;
    uint8_t  value_type;
    uint16_t value_len;
};
static_assert(sizeof(GetTlvEntryHeader) == 5, "GetTlvEntryHeader must be 5 bytes");
#pragma pack(pop)

#pragma pack(push, 1)
struct StatusResponse {
    uint8_t  block_done;
    uint8_t  error_code;
    uint16_t reserved;
    uint32_t words_written;
    uint32_t current_addr;
};
static_assert(sizeof(StatusResponse) == 12, "StatusResponse must be 12 bytes");
#pragma pack(pop)

#pragma pack(push, 1)
struct DecodeCrcPayload {
    /** CRC32 in post-XOR caliber: RTL emits crc32_accum ^ 0xFFFFFFFF. */
    uint32_t crc32;
    uint32_t word_count;
    uint8_t  done;
    uint32_t decode_status;   // see DecodeStatus below
    /**
     * CRC accumulator snapshots. [0..4] are at absolute words 0, 128, 255, 256 and
     * 32768; [5] and [6] are relative to the END of the strip (total-128 and
     * total-256). The absolute five all sit inside the first 257 words of a strip that
     * is normally 100k words or longer, which left the whole scheme blind to late
     * corruption -- the STREAM_END zero-fill defect matched all five while the last two
     * dozen lines were zeros. Anything that only degrades the tail needs [5] and [6].
     */
    uint32_t diag_crc[7];
};
static_assert(sizeof(DecodeCrcPayload) == 41, "DecodeCrcPayload must be 41 bytes");
#pragma pack(pop)

#pragma pack(push, 1)
/** GET(DECODE_BLOCK_CRC): last completed block. Wire size 14 = 3xu32 + done + lane. */
struct DecodeBlockCrcPayload {
    uint32_t block_index;
    uint32_t crc32;          // post-XOR
    uint32_t word_count;
    uint8_t  done;           // 1 = this block's CRC is valid
    uint8_t  lane;           // module/lane that finished it (0..K-1)
};
#if defined(_MSC_VER)
// MSVC may round packed trailing-byte structs to 16; wire value_len stays 14.
static_assert(sizeof(DecodeBlockCrcPayload) == 14 || sizeof(DecodeBlockCrcPayload) == 16,
              "DecodeBlockCrcPayload must be 14 or 16 bytes");
#else
static_assert(sizeof(DecodeBlockCrcPayload) == 14, "DecodeBlockCrcPayload must be 14 bytes");
#endif

/** GET(PARALLEL_INFO). */
struct ParallelInfoPayload {
    uint8_t  k_lanes;            // compile-time K (4)
    uint8_t  window_w;           // W for ring/bitmap (e.g. 32)
    uint8_t  parallel_mode;      // 1 after first STREAM_BLOCK_START this strip
    uint8_t  retx_pending;       // 1 = window would overwrite incomplete slot (stub)
    uint32_t base_addr;          // DDR BASE (0x20000000); address gen only until MIG
    uint32_t block_bytes;        // full-block slot size (4 MiB)
    uint32_t complete_bitmap;    // INT32 completion bits for current window base
    uint32_t window_base_index;  // lowest outstanding block_index tracked by bitmap
    uint32_t blocks_completed;   // strip-scope count
    // fw>=0x8010D: lane-overlap telem (clk ticks while parallel_mode)
    uint32_t lane_busy_ge2_cyc;  // cycles with >=2 lanes busy
    uint32_t lane_sample_cyc;    // parallel_mode sample cycles
    // fw>=0x8010E: higher-order overlap (value_len=40)
    uint32_t lane_busy_ge3_cyc;  // cycles with >=3 lanes busy
    uint32_t lane_busy_ge4_cyc;  // cycles with >=4 lanes busy
};
static_assert(sizeof(ParallelInfoPayload) == 40, "ParallelInfoPayload must be 40 bytes");

/** GET(WINDOW) extended value for ring+bitmap (additive; old 2-byte stub superseded). */
struct WindowStatusPayload {
    uint16_t window_w;
    uint16_t flags;              // bit0=retx_pending, bit1=ddr_write_en (0 in Phase A)
    uint32_t complete_bitmap;
    uint32_t window_base_index;
    uint32_t last_byte_addr;     // last computed ring write address (no MIG required)
    uint32_t retx_count;
};
static_assert(sizeof(WindowStatusPayload) == 20, "WindowStatusPayload must be 20 bytes");
#pragma pack(pop)

// Ring / DDR address constants (SSOT with HANDOVER C.5 / V1024 D0).
static constexpr uint32_t DDR_RING_BASE        = 0x20000000u;
static constexpr uint32_t DDR_RING_BLOCK_BYTES = 4194304u;  // 4 MiB full block
static constexpr uint32_t DDR_RING_WINDOWS     = 32u;
static constexpr uint8_t  PARALLEL_K_LANES     = 4u;

// ---------------------------------------------------------------------------
// decode_status bit layout (SSOT)
// ---------------------------------------------------------------------------
// Produced by src/rle4k_decoder_core.v `assign decode_status = {...}`.
//
//   [31:16] lines          decoded_block_line_count[15:0]
//   [15:13] reserved       must read 0
//   [12]    error_present  1 = LOW8 carries an error code (error_code != 0)
//                          0 = LOW8 carries informational status bits
//   [11]    end_recv       stream_end_received (STREAM_END latched by adapter)
//   [10]    filling        stream_end_filling (zero-fill in progress)
//   [9]     line_end       output_line_end
//   [8]     blk_done       block_done_reg
//   [7:0]   LOW8           dual meaning, disambiguated by bit 12
//
// LOW8 when error_present == 0 (healthy / informational):
//   [7] 0 (deprecated bit-mode)   [6] parsed_valid        [5] code_byte_valid
//   [4] encoded_data_valid        [3] word_decoded_valid  [2] word_decoded_ready
//   [1] decoder_fifo_ready        [0] rst_n
// A healthy idle decoder therefore reads 0x07 (word_decoded_ready | decoder_fifo_ready | rst_n).
// 0x07 is NOT an error. Never derive a verdict from LOW8 unless bit 12 is set.
//
// Backward compatibility: firmware predating the bit-12 flag leaves [15:12] == 0,
// so error_present reads 0 and LOW8 stays informational. That is the safe default:
// PASS/FAIL is then decided purely by done + word_count + CRC32.
namespace DecodeStatus {

static constexpr uint32_t LINES_SHIFT        = 16;
static constexpr uint32_t LINES_MASK         = 0xFFFF0000u;

static constexpr uint32_t RESERVED_MASK      = 0x0000E000u;  // [15:13] must be 0

static constexpr uint32_t ERROR_PRESENT_BIT  = 12;
static constexpr uint32_t ERROR_PRESENT_MASK = 1u << ERROR_PRESENT_BIT;   // 0x00001000

static constexpr uint32_t END_RECV_MASK      = 1u << 11;                  // 0x00000800
static constexpr uint32_t FILLING_MASK       = 1u << 10;                  // 0x00000400
static constexpr uint32_t LINE_END_MASK      = 1u << 9;                   // 0x00000200
static constexpr uint32_t BLK_DONE_MASK      = 1u << 8;                   // 0x00000100

static constexpr uint32_t LOW8_MASK          = 0x000000FFu;

/** LOW8 value of a healthy idle decoder: rdy | fifo_rdy | rst_n. */
static constexpr uint32_t LOW8_HEALTHY_IDLE  = 0x07u;

// Informational LOW8 bits (only meaningful when error_present == 0).
static constexpr uint32_t LOW8_RST_N             = 1u << 0;
static constexpr uint32_t LOW8_DECODER_FIFO_RDY  = 1u << 1;
static constexpr uint32_t LOW8_WORD_DEC_READY    = 1u << 2;
static constexpr uint32_t LOW8_WORD_DEC_VALID    = 1u << 3;
static constexpr uint32_t LOW8_ENCODED_VALID     = 1u << 4;
static constexpr uint32_t LOW8_CODE_BYTE_VALID   = 1u << 5;
static constexpr uint32_t LOW8_PARSED_VALID      = 1u << 6;

static_assert((LINES_MASK | RESERVED_MASK | ERROR_PRESENT_MASK | END_RECV_MASK |
               FILLING_MASK | LINE_END_MASK | BLK_DONE_MASK | LOW8_MASK) == 0xFFFFFFFFu,
              "decode_status masks must tile the full 32-bit word");
static_assert((ERROR_PRESENT_MASK & RESERVED_MASK) == 0,
              "error_present must not overlap the reserved field");
static_assert((LOW8_HEALTHY_IDLE & LOW8_MASK) == LOW8_HEALTHY_IDLE,
              "healthy idle pattern must fit in LOW8");

inline uint32_t lines(uint32_t ds)        { return (ds & LINES_MASK) >> LINES_SHIFT; }
inline bool     error_present(uint32_t ds){ return (ds & ERROR_PRESENT_MASK) != 0; }
inline bool     end_recv(uint32_t ds)     { return (ds & END_RECV_MASK) != 0; }
inline bool     filling(uint32_t ds)      { return (ds & FILLING_MASK) != 0; }
inline bool     line_end(uint32_t ds)     { return (ds & LINE_END_MASK) != 0; }
inline bool     blk_done(uint32_t ds)     { return (ds & BLK_DONE_MASK) != 0; }
inline uint32_t low8(uint32_t ds)         { return ds & LOW8_MASK; }

/** Error code, or 0 when the firmware is not reporting an error. */
inline uint32_t error_code(uint32_t ds)   { return error_present(ds) ? low8(ds) : 0u; }

}  // namespace DecodeStatus

/** GET(ACTIVITY_WDT): 12-byte value (three u32 LE), same order as FPGA `GET_ID_ACTIVITY_WDT` body. */
#pragma pack(push, 1)
struct ActivityWdtPayload {
    uint32_t timeout_count;   // mon_wdt_timeout: cumulative watchdog timeout events
    uint32_t wdt_counter;     // current inactivity tick counter (cleared on feed)
    uint32_t timeout_ticks; // P_WDT_TIMEOUT_TICKS (e.g. 60 s @ 15.625 MHz)
};
static_assert(sizeof(ActivityWdtPayload) == 12, "ActivityWdtPayload must be 12 bytes");
#pragma pack(pop)

// Absolute word indices for diag_crc[0..4]. diag_crc[5] and [6] are not on this list
// because they are relative to the end of the strip; see DIAG_CRC_TAIL_BACK.
static constexpr uint32_t DIAG_CRC_WORD_INDEX[5] = {0, 128, 255, 256, 32768};
// How far back from the final word diag_crc[5] and diag_crc[6] are taken.
static constexpr uint32_t DIAG_CRC_TAIL_BACK[2] = {128, 256};
static constexpr int      DIAG_CRC_COUNT = 7;

enum class ErrorType : uint8_t {
    ERR_INVALID_CMD      = 0x01,
    ERR_INVALID_LEN      = 0x02,
    ERR_INVALID_V2_HDR   = 0x03,
    ERR_SEQ_OUT_OF_RANGE = 0x04,
    ERR_BLOCK_MISMATCH   = 0x05,
    ERR_BUFFER_OVERFLOW  = 0x06,
};

#pragma pack(push, 1)
struct ErrorRspPayload {
    uint8_t  error_type;
    uint8_t  original_cmd;
    uint16_t original_seq;
    uint16_t detail;
};
static_assert(sizeof(ErrorRspPayload) == 6, "ErrorRspPayload must be 6 bytes");
#pragma pack(pop)

#pragma pack(push, 4)
struct BitMapInfoHeader {
    uint32_t index;
    uint32_t width;
    uint32_t height;
    uint32_t data_length;
    uint64_t data_ptr;
    uint32_t source_length;
    uint8_t  format;
    uint8_t  align_mode;
    uint16_t reserved0;
    uint64_t extends_ptr;

    static uint32_t align_bits_from_mode(uint8_t mode) {
        static constexpr uint32_t kAlignBits[7] = {8u,16u,32u,64u,128u,256u,512u};
        return (mode < 7u) ? kAlignBits[mode] : 8u;
    }
    static uint32_t align_up_bits(uint32_t w, uint32_t a) {
        if (a == 0u) return w;
        return ((w + a - 1u) / a) * a;
    }
    uint32_t block_index() const { return index; }
    uint32_t line_width_bits() const { return width; }
    uint32_t block_height_lines() const { return height; }
    uint32_t compressed_size_bytes() const { return data_length; }
    uint32_t line_stride_bits() const {
        if (height != 0u && source_length % height == 0u)
            return (source_length / height) * 8u;
        return align_up_bits(width, align_bits_from_mode(align_mode));
    }
};
static_assert(sizeof(BitMapInfoHeader) == 40, "BitMapInfoHeader must be 40 bytes");
#pragma pack(pop)

// --- Ethernet Header ---
struct EthHeader {
    uint8_t dst_mac[6];
    uint8_t src_mac[6];
    uint8_t ethertype[2];
};
static_assert(sizeof(EthHeader) == 14, "EthHeader must be 14 bytes");

inline void set_ethertype(EthHeader& hdr, uint16_t et) {
    hdr.ethertype[0] = static_cast<uint8_t>(et >> 8);
    hdr.ethertype[1] = static_cast<uint8_t>(et & 0xFF);
}

inline uint16_t get_ethertype(const EthHeader& hdr) {
    return (static_cast<uint16_t>(hdr.ethertype[0]) << 8) | hdr.ethertype[1];
}

}  // namespace rle4k

#endif  // RLE4K_PROTOCOL_V8_H
