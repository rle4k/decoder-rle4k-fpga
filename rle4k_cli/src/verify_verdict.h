// ============================================================================
// verify_verdict -- evidence-based PASS/FAIL decision for `verify`
// ============================================================================
// Pure logic, no Npcap and no board. Kept separate from main_cli_v8.cpp so the
// criterion can be exercised offline by selftest_verdict.
//
// The verdict is derived from *real evidence* only:
//   done == 1, decoded word_count == expected, CRC32 (post-XOR) == PC reference.
// decode_status[7:0] is informational unless decode_status[12] (error_present)
// is set; see DecodeStatus in protocol_v8.h.
// ============================================================================

#ifndef RLE4K_VERIFY_VERDICT_H
#define RLE4K_VERIFY_VERDICT_H

#include <cstdint>
#include <string>

namespace rle4k {

enum class VerifyMode {
    FpgaOnly,       // --fpga-only: no PC reference CRC available
    FullReference,  // PC reference decode + CRC comparison
};

/** Everything the verdict is allowed to look at. */
struct VerifyEvidence {
    // --- transport / firmware ---
    bool     crc_query_ok  = false;  // GET(DECODE_CRC) returned a response
    uint8_t  done          = 0;      // DecodeCrcPayload::done
    uint32_t word_count    = 0;      // words the FPGA actually CRC'd
    uint32_t expected_words = 0;     // words derived from block headers
    uint32_t decode_status = 0;      // raw status word
    uint32_t fpga_crc32    = 0;      // post-XOR caliber

    // --- PC reference (FullReference only) ---
    bool     have_reference     = false;
    uint32_t ref_crc32          = 0;  // post-XOR caliber
    uint32_t ref_word_count     = 0;
    int      diag_match_count   = 7;  // of diag_total_count checkpoints
    int      diag_total_count   = 7;  // 5 when the board predates the tail checkpoints
    int      diag_first_fail    = -1; // index of first mismatching checkpoint

    // --- PC decode health (full decode, or --pc-spot-check) ---
    bool     pc_decode_ok       = true;
    bool     pc_decode_attempted = false;
};

enum class VerifyFailReason {
    None,
    CrcQueryFailed,
    FpgaError,              // decode_status[12] set
    NotDone,
    WordCountMismatch,
    PcDecodeFailed,
    ReferenceMissing,
    RefWordCountMismatch,
    DiagCheckpointMismatch,
    CrcMismatch,
};

struct VerifyVerdict {
    bool             pass   = false;
    VerifyFailReason reason = VerifyFailReason::None;

    // Mirrors of the status decode, so callers do not re-implement it.
    bool     error_present = false;
    uint32_t error_code    = 0;   // LOW8 when error_present, else 0
    bool     reserved_bits_set = false;  // decode_status[15:13] != 0 (warning only)

    std::string detail;           // one-line human readable explanation

    const char* tag() const { return pass ? "PASS" : "FAIL"; }
};

/** Decide PASS/FAIL from evidence alone. Never inspects globals or hardware. */
VerifyVerdict evaluate_verify(const VerifyEvidence& ev, VerifyMode mode);

/** Stable machine-readable token for METRICS / JSON output. */
const char* verify_fail_reason_name(VerifyFailReason r);

/** "lines=771 err_present=0 end_recv=1 filling=0 line_end=0 blk_done=1 low8=0x07 raw=0x03030107" */
std::string format_decode_status(uint32_t decode_status);

}  // namespace rle4k

#endif  // RLE4K_VERIFY_VERDICT_H
