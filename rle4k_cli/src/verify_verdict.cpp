#include "verify_verdict.h"
#include "protocol_v8.h"

#include <sstream>
#include <iomanip>

namespace rle4k {

namespace {

std::string hex32(uint32_t v) {
    std::ostringstream o;
    o << "0x" << std::hex << std::setw(8) << std::setfill('0') << v;
    return o.str();
}

std::string hex8(uint32_t v) {
    std::ostringstream o;
    o << "0x" << std::hex << std::setw(2) << std::setfill('0') << (v & 0xFFu);
    return o.str();
}

}  // namespace

const char* verify_fail_reason_name(VerifyFailReason r) {
    switch (r) {
        case VerifyFailReason::None:                   return "OK";
        case VerifyFailReason::CrcQueryFailed:         return "CRC_QUERY_FAILED";
        case VerifyFailReason::FpgaError:              return "FPGA_ERROR";
        case VerifyFailReason::NotDone:                return "NOT_DONE";
        case VerifyFailReason::WordCountMismatch:      return "WORD_COUNT_MISMATCH";
        case VerifyFailReason::PcDecodeFailed:         return "PC_DECODE_FAILED";
        case VerifyFailReason::ReferenceMissing:       return "REFERENCE_MISSING";
        case VerifyFailReason::RefWordCountMismatch:   return "REF_WORD_COUNT_MISMATCH";
        case VerifyFailReason::DiagCheckpointMismatch: return "DIAG_CHECKPOINT_MISMATCH";
        case VerifyFailReason::CrcMismatch:            return "CRC_MISMATCH";
    }
    return "UNKNOWN";
}

std::string format_decode_status(uint32_t ds) {
    namespace S = DecodeStatus;
    std::ostringstream o;
    o << "lines=" << S::lines(ds)
      << " err_present=" << (S::error_present(ds) ? 1 : 0)
      << " end_recv=" << (S::end_recv(ds) ? 1 : 0)
      << " filling=" << (S::filling(ds) ? 1 : 0)
      << " line_end=" << (S::line_end(ds) ? 1 : 0)
      << " blk_done=" << (S::blk_done(ds) ? 1 : 0);
    if (S::error_present(ds)) {
        o << " err_code=" << hex8(S::low8(ds));
    } else {
        // LOW8 is informational here: never report it as an error code.
        o << " info=" << hex8(S::low8(ds))
          << "(rst_n=" << ((ds & S::LOW8_RST_N) ? 1 : 0)
          << ",fifo_rdy=" << ((ds & S::LOW8_DECODER_FIFO_RDY) ? 1 : 0)
          << ",out_rdy=" << ((ds & S::LOW8_WORD_DEC_READY) ? 1 : 0)
          << ",out_vld=" << ((ds & S::LOW8_WORD_DEC_VALID) ? 1 : 0)
          << ",in_vld=" << ((ds & S::LOW8_ENCODED_VALID) ? 1 : 0)
          << ",code_vld=" << ((ds & S::LOW8_CODE_BYTE_VALID) ? 1 : 0)
          << ",parsed=" << ((ds & S::LOW8_PARSED_VALID) ? 1 : 0) << ")";
    }
    o << " raw=" << hex32(ds);
    return o.str();
}

VerifyVerdict evaluate_verify(const VerifyEvidence& ev, VerifyMode mode) {
    namespace S = DecodeStatus;

    VerifyVerdict v;
    v.error_present     = S::error_present(ev.decode_status);
    v.error_code        = S::error_code(ev.decode_status);
    v.reserved_bits_set = (ev.decode_status & S::RESERVED_MASK) != 0;

    std::ostringstream d;
    auto fail = [&](VerifyFailReason r, const std::string& why) {
        v.pass = false;
        v.reason = r;
        d << why;
        if (v.reserved_bits_set)
            d << " [warn: decode_status[15:13] nonzero, unknown firmware revision]";
        v.detail = d.str();
        return v;
    };

    // 1. We must actually have an answer from the board.
    if (!ev.crc_query_ok)
        return fail(VerifyFailReason::CrcQueryFailed,
                    "no GET(DECODE_CRC) response from FPGA");

    // 2. Explicit firmware error flag. Only bit 12 makes LOW8 an error code;
    //    firmware without bit 12 leaves it clear and LOW8 stays informational.
    if (v.error_present)
        return fail(VerifyFailReason::FpgaError,
                    "FPGA reported error_code=" + hex8(v.error_code) +
                    " (decode_status[12] set)");

    // 3. Decode must have completed.
    if (ev.done == 0)
        return fail(VerifyFailReason::NotDone,
                    "FPGA decode not complete (done=0), " +
                    format_decode_status(ev.decode_status));

    // 4. The FPGA must have CRC'd exactly the volume the headers predict.
    if (ev.word_count != ev.expected_words) {
        std::ostringstream w;
        w << "word count mismatch: fpga=" << ev.word_count
          << " expected=" << ev.expected_words
          << " delta=" << (static_cast<int64_t>(ev.word_count) -
                           static_cast<int64_t>(ev.expected_words));
        return fail(VerifyFailReason::WordCountMismatch, w.str());
    }

    // 5. Any PC-side decode we attempted must have succeeded.
    if (ev.pc_decode_attempted && !ev.pc_decode_ok)
        return fail(VerifyFailReason::PcDecodeFailed,
                    "PC reference decode returned an error");

    if (mode == VerifyMode::FpgaOnly) {
        v.pass = true;
        v.reason = VerifyFailReason::None;
        d << "done=1 words=" << ev.word_count << "==expected"
          << " fpga_crc32=" << hex32(ev.fpga_crc32) << " (post-XOR, not compared:"
          << " --fpga-only)"
          << " status[" << format_decode_status(ev.decode_status) << "]";
        if (v.reserved_bits_set)
            d << " [warn: decode_status[15:13] nonzero, unknown firmware revision]";
        v.detail = d.str();
        return v;
    }

    // --- FullReference: CRC32 against the PC reference decode ---
    if (!ev.have_reference)
        return fail(VerifyFailReason::ReferenceMissing,
                    "PC reference CRC unavailable in full-verify mode");

    if (ev.ref_word_count != ev.word_count) {
        std::ostringstream w;
        w << "reference word count mismatch: fpga=" << ev.word_count
          << " pc=" << ev.ref_word_count;
        return fail(VerifyFailReason::RefWordCountMismatch, w.str());
    }

    if (ev.diag_match_count != ev.diag_total_count) {
        std::ostringstream w;
        w << "diag checkpoints " << ev.diag_match_count << "/" << ev.diag_total_count << " match";
        if (ev.diag_first_fail >= 0)
            w << ", first divergence at checkpoint index " << ev.diag_first_fail;
        return fail(VerifyFailReason::DiagCheckpointMismatch, w.str());
    }

    if (ev.fpga_crc32 != ev.ref_crc32)
        return fail(VerifyFailReason::CrcMismatch,
                    "CRC32 mismatch (post-XOR): fpga=" + hex32(ev.fpga_crc32) +
                    " pc=" + hex32(ev.ref_crc32));

    v.pass = true;
    v.reason = VerifyFailReason::None;
    d << "done=1 words=" << ev.word_count << "==expected"
      << " crc32=" << hex32(ev.fpga_crc32) << " (post-XOR) == PC reference"
      << " diag=" << ev.diag_match_count << "/" << ev.diag_total_count
      << " status[" << format_decode_status(ev.decode_status) << "]";
    if (v.reserved_bits_set)
        d << " [warn: decode_status[15:13] nonzero, unknown firmware revision]";
    v.detail = d.str();
    return v;
}

}  // namespace rle4k
