// ============================================================================
// selftest_verdict -- offline proof of the verify PASS/FAIL criterion
// ============================================================================
// Runs without Npcap and without a board. Exercises the Defect A fix:
//   * a healthy status word (LOW8 == 0x07, bit12 == 0) must NOT be read as an
//     error, so a complete decode with matching CRC yields PASS;
//   * bit12 == 1 with a nonzero LOW8 must yield FAIL with that LOW8 reported
//     as the error code.
// ============================================================================

#include "verify_verdict.h"
#include "protocol_v8.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace rle4k;

namespace {

int g_failures = 0;
int g_checks = 0;

void check(bool cond, const std::string& what) {
    ++g_checks;
    if (cond) {
        std::printf("  [ ok ] %s\n", what.c_str());
    } else {
        ++g_failures;
        std::printf("  [FAIL] %s\n", what.c_str());
    }
}

/** Status word of a real healthy strip: 771 lines, end_recv, blk_done, LOW8=0x07. */
uint32_t healthy_status(uint32_t lines = 771) {
    return (lines << DecodeStatus::LINES_SHIFT)
         | DecodeStatus::END_RECV_MASK
         | DecodeStatus::BLK_DONE_MASK
         | DecodeStatus::LOW8_HEALTHY_IDLE;
}

/** Same, but with the new unambiguous error flag and an error code in LOW8. */
uint32_t error_status(uint32_t err_code, uint32_t lines = 771) {
    return (lines << DecodeStatus::LINES_SHIFT)
         | DecodeStatus::ERROR_PRESENT_MASK
         | DecodeStatus::END_RECV_MASK
         | (err_code & DecodeStatus::LOW8_MASK);
}

VerifyEvidence good_evidence() {
    VerifyEvidence ev;
    ev.crc_query_ok   = true;
    ev.done           = 1;
    ev.word_count     = 98688;
    ev.expected_words = 98688;
    ev.decode_status  = healthy_status();
    ev.fpga_crc32     = 0xf87c04d1u;   // post-XOR
    ev.have_reference = true;
    ev.ref_crc32      = 0xf87c04d1u;
    ev.ref_word_count = 98688;
    ev.diag_match_count = 7;
    ev.diag_total_count = 7;
    return ev;
}

void banner(const char* s) { std::printf("\n-- %s\n", s); }

}  // namespace

int main() {
    std::printf("=== selftest_verdict (offline, no Npcap, no board) ===\n");

    // --- Case 1 (Defect A core): healthy 0x07 status must PASS --------------
    banner("Case 1: healthy status LOW8=0x07, bit12=0 -> PASS");
    {
        const VerifyEvidence ev = good_evidence();
        check(DecodeStatus::low8(ev.decode_status) == 0x07u,
              "status LOW8 is 0x07 (the historical false-FAIL pattern)");
        check(!DecodeStatus::error_present(ev.decode_status),
              "error_present (bit 12) is clear");

        const VerifyVerdict full = evaluate_verify(ev, VerifyMode::FullReference);
        check(full.pass, "full-reference verdict is PASS");
        check(full.reason == VerifyFailReason::None, "no fail reason recorded");
        check(full.error_code == 0, "no error code derived from LOW8");

        const VerifyVerdict fo = evaluate_verify(ev, VerifyMode::FpgaOnly);
        check(fo.pass, "--fpga-only verdict is PASS (was a false FAIL before)");
        std::printf("        detail: %s\n", fo.detail.c_str());
    }

    // --- Case 2: bit12 set with nonzero LOW8 must FAIL ----------------------
    banner("Case 2: error_present=1 with LOW8=0x05 -> FAIL");
    {
        VerifyEvidence ev = good_evidence();
        ev.decode_status = error_status(0x05u);
        check(DecodeStatus::error_present(ev.decode_status), "error_present is set");

        for (VerifyMode m : {VerifyMode::FpgaOnly, VerifyMode::FullReference}) {
            const VerifyVerdict v = evaluate_verify(ev, m);
            const char* mn = (m == VerifyMode::FpgaOnly) ? "fpga-only" : "full";
            check(!v.pass, std::string(mn) + ": verdict is FAIL");
            check(v.reason == VerifyFailReason::FpgaError,
                  std::string(mn) + ": reason is FPGA_ERROR");
            check(v.error_code == 0x05u,
                  std::string(mn) + ": LOW8 reported as error code 0x05");
        }
    }

    // --- Case 3: every LOW8 value stays harmless while bit12 is clear -------
    banner("Case 3: backward compatibility -- bit12=0 never yields an error");
    {
        bool all_pass = true;
        uint32_t worst = 0;
        for (uint32_t low8 = 0; low8 <= 0xFFu; ++low8) {
            VerifyEvidence ev = good_evidence();
            ev.decode_status = (771u << DecodeStatus::LINES_SHIFT)
                             | DecodeStatus::END_RECV_MASK
                             | DecodeStatus::BLK_DONE_MASK
                             | low8;
            const VerifyVerdict v = evaluate_verify(ev, VerifyMode::FullReference);
            if (!v.pass || v.error_code != 0) { all_pass = false; worst = low8; break; }
        }
        check(all_pass, all_pass
                  ? "all 256 LOW8 values PASS when bit12 is clear"
                  : "LOW8=0x" + std::to_string(worst) + " wrongly produced a failure");
    }

    // --- Case 4: real evidence still governs the verdict --------------------
    banner("Case 4: real evidence failures are still caught");
    {
        {   VerifyEvidence ev = good_evidence(); ev.done = 0;
            const VerifyVerdict v = evaluate_verify(ev, VerifyMode::FullReference);
            check(!v.pass && v.reason == VerifyFailReason::NotDone, "done=0 -> NOT_DONE"); }

        {   VerifyEvidence ev = good_evidence(); ev.word_count = 98687;
            const VerifyVerdict v = evaluate_verify(ev, VerifyMode::FullReference);
            check(!v.pass && v.reason == VerifyFailReason::WordCountMismatch,
                  "word_count != expected -> WORD_COUNT_MISMATCH"); }

        {   VerifyEvidence ev = good_evidence(); ev.ref_crc32 = 0x0783fb2eu;  // pre-XOR accum
            const VerifyVerdict v = evaluate_verify(ev, VerifyMode::FullReference);
            check(!v.pass && v.reason == VerifyFailReason::CrcMismatch,
                  "pre-XOR reference vs post-XOR board -> CRC_MISMATCH"); }

        {   VerifyEvidence ev = good_evidence(); ev.diag_match_count = 6; ev.diag_first_fail = 2;
            const VerifyVerdict v = evaluate_verify(ev, VerifyMode::FullReference);
            check(!v.pass && v.reason == VerifyFailReason::DiagCheckpointMismatch,
                  "6/7 checkpoints -> DIAG_CHECKPOINT_MISMATCH"); }

        {   VerifyEvidence ev = good_evidence(); ev.crc_query_ok = false;
            const VerifyVerdict v = evaluate_verify(ev, VerifyMode::FullReference);
            check(!v.pass && v.reason == VerifyFailReason::CrcQueryFailed,
                  "no board response -> CRC_QUERY_FAILED"); }

        {   VerifyEvidence ev = good_evidence();
            ev.pc_decode_attempted = true; ev.pc_decode_ok = false;
            const VerifyVerdict v = evaluate_verify(ev, VerifyMode::FpgaOnly);
            check(!v.pass && v.reason == VerifyFailReason::PcDecodeFailed,
                  "spot-check decode error -> PC_DECODE_FAILED"); }
    }

    // --- Case 5: CRC caliber -- post-XOR is the acceptance value ------------
    banner("Case 5: CRC caliber (post-XOR == pre-XOR accumulator ^ 0xFFFFFFFF)");
    {
        const uint32_t tb_accum_pre_xor = 0x0783fb2eu;
        const uint32_t board_post_xor   = 0xf87c04d1u;
        check((tb_accum_pre_xor ^ 0xFFFFFFFFu) == board_post_xor,
              "0x0783fb2e ^ 0xFFFFFFFF == 0xf87c04d1");

        VerifyEvidence ev = good_evidence();
        ev.fpga_crc32 = board_post_xor;
        ev.ref_crc32  = tb_accum_pre_xor ^ 0xFFFFFFFFu;
        check(evaluate_verify(ev, VerifyMode::FullReference).pass,
              "converted TB accumulator matches the board value");
    }

    // --- Case 6: status formatting never calls 0x07 an error ----------------
    banner("Case 6: status rendering");
    {
        const std::string s = format_decode_status(healthy_status());
        check(s.find("err_present=0") != std::string::npos, "renders err_present=0");
        check(s.find("err_code") == std::string::npos,
              "does not print an err_code for a healthy status");
        check(s.find("info=0x07") != std::string::npos, "renders LOW8 as info=0x07");
        std::printf("        %s\n", s.c_str());

        const std::string e = format_decode_status(error_status(0x05u));
        check(e.find("err_code=0x05") != std::string::npos,
              "renders err_code=0x05 when bit12 is set");
        std::printf("        %s\n", e.c_str());
    }

    std::printf("\n=== %d checks, %d failures -> %s ===\n",
                g_checks, g_failures, g_failures == 0 ? "PASS" : "FAIL");
    return g_failures == 0 ? 0 : 1;
}
