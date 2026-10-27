// ============================================================================
// rle4k_v8 -- Board-level verification CLI for RLE4K V08LAN (Raw Ethernet)
// ============================================================================
// Replaces UDP socket transport with Npcap raw Ethernet (EtherType 0x4B52).
// Payload protocol is identical to V07: STREAM_START/DATA/END, PING/PONG, etc.
// No IP/UDP involved -- CLI sends/receives raw Ethernet II frames.
//
// Commands: echo, ping, send, verify (file|folder|batch), hardware, dog|wdt, status, reset, help
// New options: --iface (select NIC), --target-mac, --local-mac
// ============================================================================

#include "protocol_v8.h"
#include "block_reader.h"
#include "config_io.h"
#include "cli_timestamp.h"
#include "verify_verdict.h"
#include "rle4k.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <fstream>
#include <numeric>
#include <string>
#include <sstream>
#include <thread>
#include <vector>
#include <sys/stat.h>

#ifdef _WIN32
#include <winsock2.h>
#include <iphlpapi.h>
#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ws2_32.lib")
#endif

#include <pcap.h>

using namespace rle4k;

static constexpr const char* kRle4kCliVersion = "v0.8.3";

// Pad strip to a multiple of 4 bytes with trailing 0x00 so the FPGA 32-bit CDC path and
// input_fifo_32to8 always complete full 32b words. These bytes are not part of the RLE
// payload for PC reference decode (verify still uses per-block .rle4k compressed only).
static void pad_strip_stream_to_32bit_alignment(std::vector<uint8_t>& stream)
{
    const size_t n = stream.size();
    const size_t r = n & 3u;
    if (r != 0)
        stream.insert(stream.end(), 4u - r, static_cast<uint8_t>(0));
}

struct CliConfig {
    std::string iface_name;                              // pcap device name
    uint8_t     target_mac[6] = {0x00,0x0A,0x35,0x00,0x01,0x02};
    uint8_t     local_mac[6]  = {0};                     // auto-detect
    int         timeout_ms    = 2000;
    int         bench_target_max_ms   = 1000;
    int         bench_target_ideal_ms = 400;
    // verify / bench (JSON v8_verify + CLI flags; CLI wins after merge)
    // Full speed is the default: STREAM_DATA frames go out back-to-back.
    // --inter-chunk-delay-ms N re-enables pacing for debugging only.
    int         inter_chunk_delay_ms = 0;
    // Sub-millisecond send pacing. 0 = unpaced. Sleep(1) is >=1 ms per frame, so
    // inter_chunk_delay_ms can only reach ~12.7 Mbit/s or full speed, nothing between.
    double      target_mbps = 0.0;
    // Per-block pacing. 0 = off. Constrains the interval between block starts instead
    // of the byte rate, which matches a decoder whose per-block time is size-independent.
    double      block_period_us = 0.0;
    // Spread each block's bytes across this fraction of the block period instead of
    // sending it as one burst. 0 = burst. The receiver only buffers a few KB, so a
    // line-rate burst overruns it even when the block period is comfortably long.
    double      block_spread = 0.0;
    // Give every block its own period, predicted from its code bytes, instead of one
    // constant period sized for the slowest block. Overrides --block-period-us.
    bool        block_budget = false;
    // Safety factor on the predicted period. See predict_block_cycles() for why this
    // is not zero even though the model matches simulation to within 0.02%.
    double      block_margin_pct = 8.0;
    // Hand the STREAM_DATA burst to the driver in batches (pcap_sendqueue) instead
    // of one pcap_sendpacket per frame. --no-sendqueue restores the per-frame path
    // the E4/E7 baselines were measured on.
    bool        use_sendqueue = true;
    // 0 = auto (paced 1MiB / high 256KiB / unpaced SAFE_UNPACED). Override KiB.
    int         sendqueue_chunk_kib = 0;
    // After each unpaced flush: sleep this many µs so PAUSE can stop the NIC
    // before the next transmit. 0 disables (default: rely on small chunk + NIC FC).
    int         unpaced_gap_us = 0;
    bool        fpga_only = false;                       // skip PC reference decode + CRC compare
    int         progress_send_pct = 10;                  // 0 disables send progress lines
    bool        decode_progress = true;
    int         round_budget_sec = 600;                  // WARN if fpga_path_ms exceeds this
    int         pc_spot_check = 0;                       // when fpga_only: PC-decode first N blocks
    bool        emit_json = false;                       // append a machine-readable JSON line
    bool        dry_run = false;                         // build+time frames, never touch the NIC
    // K=4 parallel: emit STREAM_BLOCK_START before each block's STREAM_DATA (V1023 e2).
    bool        parallel = false;
    // With --verify-block-crc and depth>1: send ahead up to CRC slot hold (W-2),
    // harvest in waves. Lane / ring pacing is hardware (S_BLOCK_ASSIGN → rx_ready).
    // DEFAULT 4 (=K): send-only blasts with HW PAUSE. Use --parallel-depth 1 for
    // K_eff≈1 serial wait (send-only) or sync-style CRC hold.
    int         parallel_depth = 4;
    // Alias for depth=1 wait-after-each-block. Implies verify_block_crc.
    bool        parallel_sync = false;
    // Optional decode-correctness gate (GET DECODE_BLOCK_CRC). DEFAULT OFF.
    // Transport integrity = Ethernet FCS + FPGA backpressure — not per-block poll.
    // Leaving CRC poll on inflates wall ~1.3s → ~20s and falsifies K=4 vs K=1.
    bool        verify_block_crc = false;
    // When verify_block_crc: 1 = compare every block; N>1 = compare bi%N==0 and last
    // (still wave-harvests all slots before reuse — compare filter only).
    int         verify_block_crc_every = 1;
};

static CliConfig g_cfg;
static pcap_t*   g_pcap = nullptr;

// ---------------------------------------------------------------------------
// Throughput accounting for the STREAM_DATA burst
// ---------------------------------------------------------------------------
struct SendThroughput {
    uint64_t payload_bytes = 0;   // STREAM_DATA payload only
    uint64_t wire_bytes    = 0;   // including Ethernet + PayloadHeader + min-frame padding
    uint64_t frames        = 0;
    double   wall_ms       = 0.0;
    int      delay_ms      = 0;   // configured inter-frame delay actually applied
    double   target_mbps   = 0.0; // configured pacer setpoint, 0 = unpaced
    uint64_t pace_slips    = 0;   // frames where the sender fell behind the setpoint
    double   block_period_us = 0.0; // configured block-start interval, 0 = off
    uint64_t blocks_paced  = 0;   // block starts gated by the block pacer
    uint64_t blocks_late   = 0;   // block starts already past due when reached
    uint64_t send_batches  = 0;   // pcap_sendqueue_transmit calls, 0 = per-frame path
    bool     block_budget  = false; // block_period_us below is then the per-block mean
    double   send_only_ms  = 0.0; // parallel: BLOCK_START+DATA only (excludes CRC poll)
    double   poll_ms       = 0.0; // parallel: GET(DECODE_BLOCK_CRC) harvest waits

    double seconds() const { return wall_ms / 1000.0; }
    double payload_mb_per_s() const {
        const double s = seconds();
        return s > 0.0 ? (static_cast<double>(payload_bytes) / (1024.0 * 1024.0)) / s : 0.0;
    }
    double wire_mbit_per_s() const {
        const double s = seconds();
        return s > 0.0 ? (static_cast<double>(wire_bytes) * 8.0 / 1e6) / s : 0.0;
    }
    double frames_per_s() const {
        const double s = seconds();
        return s > 0.0 ? static_cast<double>(frames) / s : 0.0;
    }
};

// ---------------------------------------------------------------------------
// Sub-millisecond send pacer
//
// Holds the STREAM_DATA burst to a target wire rate. The setpoint counts the same
// bytes as SendThroughput::wire_bytes (Ethernet header + payload + min-frame pad),
// so --target-mbps N and the reported wire_Mbps are the same quantity; preamble and
// IPG add a further 20 B/frame on the medium and are outside both.
//
// The deadline is cumulative rather than per frame: per-frame rounding at 66 us a
// frame would otherwise accumulate into a systematic undershoot over 20k frames.
//
// Falling behind is forgiven rather than made up. Whenever Windows deschedules the
// sender for a few milliseconds, a catch-up would empty the whole accumulated credit
// at line rate, and a burst like that overruns the receiver's ~20 KB of buffering
// even when the average rate is far below its limit. That showed up as a stochastic
// 0.1% frame loss floor at every rate, which looks like a second defect but is not.
// ---------------------------------------------------------------------------
class SendPacer {
public:
    void start(double target_mbps) {
        bits_per_second_ = target_mbps * 1e6;
        sent_bits_ = 0;
        catch_up_forgiven_ = 0;
#ifdef _WIN32
        // Always primed: the block pacer can turn this pacer on later via set_rate().
        LARGE_INTEGER f, t;
        QueryPerformanceFrequency(&f);
        QueryPerformanceCounter(&t);
        qpf_ = static_cast<double>(f.QuadPart);
        t0_  = t.QuadPart;
#endif
    }

    // Change the setpoint mid-stream and restart the deadline from now.
    void set_rate(double target_mbps) {
        bits_per_second_ = target_mbps * 1e6;
        rebase();
    }

    bool active() const { return bits_per_second_ > 0.0; }

    // Restart the cumulative deadline from now. Used by the block pacer so that the
    // rate cap applies within a block instead of across the whole strip; without this
    // the idle time between blocks would be banked as credit for a line-rate burst.
    void rebase() {
        if (!active()) return;
        sent_bits_ = 0;
#ifdef _WIN32
        LARGE_INTEGER t;
        QueryPerformanceCounter(&t);
        t0_ = t.QuadPart;
#endif
    }

    void wait_for(uint64_t wire_bytes) {
        if (!active()) return;
        sent_bits_ += wire_bytes * 8ull;
        const double due_s = static_cast<double>(sent_bits_) / bits_per_second_;
#ifdef _WIN32
        // One frame of burst tolerance, so ordinary jitter is still smoothed out.
        const double slack_s = static_cast<double>(wire_bytes * 8ull) / bits_per_second_;
        for (;;) {
            LARGE_INTEGER now;
            QueryPerformanceCounter(&now);
            const double elapsed_s = static_cast<double>(now.QuadPart - t0_) / qpf_;
            if (elapsed_s > due_s + slack_s) {
                t0_ += static_cast<int64_t>((elapsed_s - due_s) * qpf_);
                ++catch_up_forgiven_;
                return;
            }
            if (elapsed_s >= due_s) return;
            // Sleep() only has ~1 ms granularity, so it can only be used when the
            // remaining wait is comfortably larger than that; otherwise spin.
            if (due_s - elapsed_s > 0.002) Sleep(1);
            else YieldProcessor();
        }
#endif
    }

    // How often the sender fell more than one frame behind. A large count means the
    // machine cannot hold this rate and the achieved rate will read low.
    uint64_t catch_up_forgiven() const { return catch_up_forgiven_; }

private:
    double   bits_per_second_ = 0.0;
    uint64_t sent_bits_ = 0;
    uint64_t catch_up_forgiven_ = 0;
#ifdef _WIN32
    double   qpf_ = 1.0;
    int64_t  t0_  = 0;
#endif
};

// ---------------------------------------------------------------------------
// Per-block send budget
//
// A constant block period has to be sized for the slowest block, and the decoder's
// per-block time is not constant: it tracks the number of code bytes, from 545 us
// for the smallest real block to 800 us for the largest. Sizing the period for the
// worst case wastes the difference on every other block.
//
// The prediction is the structural model calibrated in
// reports/2026-08-09-e9-per-block-cycle-accounting.md, refreshed for the pipelined
// front end: a code costs one cycle unless its run spans more than one 512-bit
// output word, in which case it costs one cycle per word, plus two cycles per
// output line. Against tb_decoder_cycles it is exact to within one cycle on blocks
// of 9,216 / 11,264 / 52,800 code bytes.
//
// Margin. The model describes the decoder core alone; on the board the same block
// also pays for adapter dispatch, the CDC crossing and the block_done handshake.
// The E8 constant-period scan put the whole-dataset knee between 600 us (fails) and
// 620 us (passes) against a model mean of 597.6 us, so the board wants about 3.7%
// more than the model says. Underestimating is not a graceful degradation: the
// decoder stalls and the entire strip is lost (fpga_words=0), while overestimating
// costs only the excess time. The default is therefore 8%, roughly twice the
// observed shortfall, and --block-margin-pct exists so the real threshold can be
// measured rather than assumed.
// ---------------------------------------------------------------------------
static double predict_block_cycles(const uint8_t* codes, size_t n, uint32_t lines) {
    double cycles = 0.0;
    for (size_t i = 0; i < n; ++i) {
        const uint8_t c = codes[i];
        const int bits = (c & 0x80) ? (c & 0x3F) * 64 : (c & 0x3F);
        int words = (bits + 511) / 512;
        if (words < 1) words = 1;      // the front end still spends a cycle on it
        cycles += words;
    }
    return cycles + 2.0 * static_cast<double>(lines);
}

struct BlockBudget {
    std::vector<double> period_s;   // per block
    std::vector<double> rate_bps;   // per block, spreads the block over its period

    bool active() const { return !period_s.empty(); }
    double period_of(size_t i) const { return i < period_s.size() ? period_s[i] : 0.0; }
    double rate_of(size_t i) const { return i < rate_bps.size() ? rate_bps[i] : 0.0; }
    double total_s() const {
        double t = 0.0;
        for (double p : period_s) t += p;
        return t;
    }
    double min_us() const {
        double v = 0.0;
        for (double p : period_s) if (v == 0.0 || p < v) v = p;
        return v * 1e6;
    }
    double max_us() const {
        double v = 0.0;
        for (double p : period_s) if (p > v) v = p;
        return v * 1e6;
    }
    double max_rate_mbps() const {
        double v = 0.0;
        for (double r : rate_bps) if (r > v) v = r;
        return v / 1e6;
    }

    // rle_payload_bytes excludes the 32-bit alignment padding at the end of the strip.
    void build(const std::vector<uint8_t>& stream,
               const std::vector<size_t>& block_starts,
               size_t rle_payload_bytes, uint32_t lines_per_block, double margin_pct) {
        period_s.clear();
        rate_bps.clear();
        if (block_starts.empty()) return;
        const double scale = 1.0 + margin_pct / 100.0;
        period_s.reserve(block_starts.size());
        rate_bps.reserve(block_starts.size());
        for (size_t b = 0; b < block_starts.size(); ++b) {
            const size_t beg = block_starts[b];
            const size_t end = (b + 1 < block_starts.size()) ? block_starts[b + 1]
                                                             : rle_payload_bytes;
            const size_t n = end > beg ? end - beg : 0;
            const double cyc = predict_block_cycles(stream.data() + beg, n, lines_per_block);
            const double p = cyc / 125e6 * scale;
            period_s.push_back(p);
            // Deliver the block evenly across its own period. Arrival then tracks
            // consumption, so the RX FIFO never has to hold more than the jitter,
            // and there is no separate intra-block cap to tune per dataset.
            const size_t frames = (n + MAX_DATA_PER_FRAME - 1) / MAX_DATA_PER_FRAME;
            const double wire = static_cast<double>(n) +
                                static_cast<double>(frames) * (ETH_HEADER_SIZE + PAYLOAD_HEADER_SIZE);
            rate_bps.push_back(p > 0.0 ? wire * 8.0 / p : 0.0);
        }
    }
};

static std::string block_budget_kv(const BlockBudget& b, double margin_pct) {
    std::ostringstream o;
    o << std::fixed << std::setprecision(1);
    o << "blocks=" << b.period_s.size()
      << " margin_pct=" << margin_pct
      << " period_min_us=" << b.min_us()
      << " period_max_us=" << b.max_us()
      << " period_mean_us=" << (b.period_s.empty() ? 0.0
                                : b.total_s() * 1e6 / static_cast<double>(b.period_s.size()))
      << " predicted_total_ms=" << b.total_s() * 1e3
      << " peak_rate_mbps=" << b.max_rate_mbps();
    return o.str();
}

// ---------------------------------------------------------------------------
// Per-block send pacer
//
// The decoder's per-block time is dominated by the 65,536 output words it always
// emits, so it is far closer to constant than the compressed size is: a constant
// byte rate has to be set for the worst (smallest) block in the set and leaves the
// decoder idle for every block above that size. This pacer instead sends each block
// as fast as the machine allows and only holds the interval between block *starts*
// to a period. (Per-block time is not exactly constant -- it grows with code count,
// 545 to 800 us across this dataset -- which is what BlockBudget above corrects for.)
//
// The deadline is relative to the previous block's actual start, not to a cumulative
// schedule. Blocks larger than period x send-rate take longer than the period to push
// out; a cumulative schedule would treat that as debt and release the following blocks
// back to back to repay it, which is the same catch-up burst that produced a spurious
// loss floor in the constant-rate pacer.
// ---------------------------------------------------------------------------
class BlockPacer {
public:
    // block_starts must be ascending byte offsets into the strip, starting at 0.
    void start(double period_us, const std::vector<size_t>* block_starts,
               size_t stream_bytes, double spread, const BlockBudget* budget = nullptr) {
        budget_ = (budget && budget->active()) ? budget : nullptr;
        period_s_ = budget_ ? budget_->period_of(0) : period_us / 1e6;
        starts_ = block_starts;
        stream_bytes_ = stream_bytes;
        spread_ = spread;
        next_ = 0;
        paced_ = 0;
        late_ = 0;
        armed_ = false;
    }

    // Rate, in Mbit/s of wire bytes, that spreads the block starting at index
    // `block` evenly over spread_ x period. 0 when spreading is disabled.
    double spread_rate_mbps(size_t block) const {
        if (budget_) return budget_->rate_of(block) / 1e6;
        if (spread_ <= 0.0 || !starts_ || block >= starts_->size()) return 0.0;
        const size_t end = (block + 1 < starts_->size()) ? (*starts_)[block + 1] : stream_bytes_;
        const size_t payload = end - (*starts_)[block];
        const size_t frames = (payload + MAX_DATA_PER_FRAME - 1) / MAX_DATA_PER_FRAME;
        const double wire = static_cast<double>(payload) +
                            static_cast<double>(frames) * (ETH_HEADER_SIZE + PAYLOAD_HEADER_SIZE);
        return wire * 8.0 / (period_s_ * spread_) / 1e6;
    }

    // Index of the block opened by the most recent gate() that returned true.
    size_t current_block() const { return next_ > 0 ? next_ - 1 : 0; }

    bool active() const { return period_s_ > 0.0 && starts_ && !starts_->empty(); }

    // Call before sending the frame whose first payload byte is at `offset`.
    // Returns true if this frame opens a new block (the caller may want to rebase
    // an intra-block rate cap).
    bool gate(size_t offset) {
        if (!active()) return false;
        if (next_ >= starts_->size() || offset < (*starts_)[next_]) return false;
        while (next_ < starts_->size() && offset >= (*starts_)[next_]) ++next_;
#ifdef _WIN32
        LARGE_INTEGER f, now;
        QueryPerformanceFrequency(&f);
        QueryPerformanceCounter(&now);
        const double qpf = static_cast<double>(f.QuadPart);
        if (armed_) {
            ++paced_;
            const double due = static_cast<double>(prev_start_) + period_s_ * qpf;
            if (static_cast<double>(now.QuadPart) >= due) {
                ++late_;   // the sender itself could not keep the period
            } else {
                for (;;) {
                    QueryPerformanceCounter(&now);
                    const double remain_s = (due - static_cast<double>(now.QuadPart)) / qpf;
                    if (remain_s <= 0.0) break;
                    if (remain_s > 0.002) Sleep(1); else YieldProcessor();
                }
            }
        }
        prev_start_ = now.QuadPart;
        armed_ = true;
#endif
        // The gap just enforced belonged to the outgoing block; from here on the
        // deadline is the newly opened block's own predicted period.
        if (budget_) period_s_ = budget_->period_of(current_block());
        return true;
    }

    uint64_t blocks_paced() const { return paced_; }
    uint64_t blocks_late() const { return late_; }

private:
    double  period_s_ = 0.0;
    const std::vector<size_t>* starts_ = nullptr;
    size_t  stream_bytes_ = 0;
    double  spread_ = 0.0;
    const BlockBudget* budget_ = nullptr;
    size_t  next_ = 0;
    uint64_t paced_ = 0;
    uint64_t late_ = 0;
    bool    armed_ = false;
#ifdef _WIN32
    int64_t prev_start_ = 0;
#endif
};

// ---------------------------------------------------------------------------
// Batched, kernel-timed STREAM_DATA sender
//
// pcap_sendpacket costs ~43 us per frame on this machine while building the frame
// costs 0.12 us, so the whole send path is user/kernel transitions, not work: the
// ceiling is ~279 Mbit/s no matter what the link can do. pcap_sendqueue_transmit
// hands a whole batch to the driver in one call and, with sync=1, releases each
// frame at the timestamp attached to it, so the pacing decision also stops
// depending on Windows scheduling the sender thread on time.
//
// The batch is capped and always flushed on a block boundary: a flush is a gap in
// the schedule, and a gap between blocks only delays the next block start, which
// is the harmless direction.
// ---------------------------------------------------------------------------
// pcap_sendqueue_transmit hands the whole queue to the NIC before returning.
// Large chunks leave the wire for hundreds of microseconds after FPGA asserts
// 802.3x PAUSE — too late.
//
// Quantify (fw≥0x80110 staging): DEPTH=16 KiB, PAUSE headroom=8 KiB free when
// pause_level asserts. One quantum@1G = 512 ns. PAUSE path (2FF+TEMAC) ≲10 µs;
// NIC Rx-FC → Tx-stop is driver-dependent (often 10–200 µs) and Npcap may never
// surface MAC-control frames to userland. Bound:
//   safe_batch ≲ headroom = 8 KiB  (conservative; leave margin for eth headers)
// Empirically 32 KiB unpaced hung on 8010F (2 KiB headroom); 4 KiB + gap is the
// default unpaced cooperative mode.
static const size_t kSendQueueChunkBytesPaced   = 1024u * 1024u; // 1 MiB (<200 Mbps)
static const size_t kSendQueueChunkBytesHigh    = 256u * 1024u;  // paced >=200
static const size_t kSendQueueChunkBytesUnpaced = 4u * 1024u;    // ≤ staging headroom
// Headroom kept free at a block boundary. The largest block in the reference set is
// 52,840 B of payload; 128 KB covers it with room for headers.
static const size_t kMaxBlockWireBytes = 128u * 1024u;

static size_t sendqueue_chunk_bytes(double target_mbps) {
    if (g_cfg.sendqueue_chunk_kib > 0)
        return static_cast<size_t>(g_cfg.sendqueue_chunk_kib) * 1024u;
    if (target_mbps <= 0.0)
        return kSendQueueChunkBytesUnpaced;
    if (target_mbps >= 200.0)
        return kSendQueueChunkBytesHigh;
    return kSendQueueChunkBytesPaced;
}

static uint64_t g_pause_frames_seen = 0;
static bool     g_unpaced_coop_flush = false;

// Count PAUSE frames only when a longer RX poll is already happening (not on
// the send hot path). pcap_next_ex blocks up to the handle timeout — calling it
// after every 4 KiB flush collapses wire rate to ~10 Mbps.
static void drain_and_honor_pause(int budget_us) {
    if (!g_pcap || g_cfg.dry_run || budget_us <= 0) return;
    const auto t0 = std::chrono::steady_clock::now();
    while (true) {
        const auto us = std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - t0).count();
        if (us >= budget_us) break;
        struct pcap_pkthdr* hdr = nullptr;
        const u_char* pkt = nullptr;
        const int rc = pcap_next_ex(g_pcap, &hdr, &pkt);
        if (rc != 1) break;
        if (!hdr || !pkt || hdr->caplen < 18) continue;
        const uint16_t et = (static_cast<uint16_t>(pkt[12]) << 8) | pkt[13];
        if (et != 0x8808) continue;
        const uint16_t opcode = (static_cast<uint16_t>(pkt[14]) << 8) | pkt[15];
        if (opcode != 0x0001) continue;
        ++g_pause_frames_seen;
    }
}

static void unpaced_post_flush_yield(size_t flushed_chunk_hint) {
    (void)flushed_chunk_hint;
    // No pcap_next_ex here — see drain_and_honor_pause comment. Rely on:
    // (1) chunk ≤ staging PAUSE headroom, (2) peer NIC Rx FC, (3) optional gap.
    int gap = g_cfg.unpaced_gap_us;
    if (gap < 0) gap = 0;
    if (gap > 0)
        std::this_thread::sleep_for(std::chrono::microseconds(gap));
}

// Release schedule for the STREAM_DATA burst, in seconds from the burst start.
// Mirrors what BlockPacer/SendPacer would do in real time, but computed up front
// so the driver can do the waiting.
struct SendSchedule {
    double block_period_s = 0.0;  // period of the block currently open, 0 = no gating
    double rate_bps       = 0.0;  // 0 = no intra-block rate cap
    double block_open_s   = 0.0;  // release time of the current block's first frame
    double cursor_s       = 0.0;  // release time of the next frame
    double block_bits     = 0.0;  // wire bits already released inside this block
    const BlockBudget* budget = nullptr;

    void start(double block_period_us, double target_mbps, const BlockBudget* b) {
        budget         = (b && b->active()) ? b : nullptr;
        block_period_s = budget ? budget->period_of(0) : block_period_us / 1e6;
        rate_bps       = budget ? budget->rate_of(0)   : target_mbps * 1e6;
        block_open_s = cursor_s = block_bits = 0.0;
    }
    // Open block `idx`. Deadline is relative to the previous block's actual open,
    // never a cumulative schedule -- blocks that take longer than the period are
    // routine and must not be repaid as a catch-up burst. block_period_s still holds
    // the outgoing block's period at this point, which is the one that sets the gap.
    void open_block(size_t idx) {
        block_open_s = (std::max)(block_open_s + block_period_s, cursor_s);
        if (budget) {
            block_period_s = budget->period_of(idx);
            rate_bps       = budget->rate_of(idx);
        }
        cursor_s = block_open_s;
        block_bits = 0.0;
    }
    double release_of(size_t wire_bytes) {
        const double t = cursor_s;
        if (rate_bps > 0.0) {
            block_bits += static_cast<double>(wire_bytes) * 8.0;
            cursor_s = block_open_s + block_bits / rate_bps;
        }
        return t;
    }
    bool timed() const { return block_period_s > 0.0 || rate_bps > 0.0; }
};

class BatchSender {
public:
    bool begin(size_t chunk_bytes) {
        chunk_bytes_ = chunk_bytes ? chunk_bytes : kSendQueueChunkBytesPaced;
        queue_ = pcap_sendqueue_alloc(static_cast<u_int>(chunk_bytes_));
        return queue_ != nullptr;
    }
    ~BatchSender() { if (queue_) pcap_sendqueue_destroy(queue_); }

    bool room_for(size_t wire_bytes) const {
        return queue_ && queue_->len + sizeof(struct pcap_pkthdr) + wire_bytes <= queue_->maxlen;
    }
    bool empty() const { return !queue_ || queue_->len == 0; }

    bool add(const uint8_t* frame, size_t wire_bytes, double release_s) {
        struct pcap_pkthdr h{};
        h.caplen = static_cast<bpf_u_int32>(wire_bytes);
        h.len    = static_cast<bpf_u_int32>(wire_bytes);
        h.ts.tv_sec  = static_cast<long>(release_s);
        h.ts.tv_usec = static_cast<long>((release_s - static_cast<double>(h.ts.tv_sec)) * 1e6);
        return pcap_sendqueue_queue(queue_, &h, frame) == 0;
    }

    // Returns false if the driver sent fewer bytes than queued.
    bool flush(pcap_t* p, bool sync) {
        if (empty()) return true;
        const u_int want = queue_->len;
        const u_int got = pcap_sendqueue_transmit(p, queue_, sync ? 1 : 0);
        queue_->len = 0;
        ++flushes_;
        if (got < want) return false;
        if (g_unpaced_coop_flush)
            unpaced_post_flush_yield(chunk_bytes_);
        return true;
    }
    uint64_t flushes() const { return flushes_; }
    size_t chunk_bytes() const { return chunk_bytes_; }

private:
    pcap_send_queue* queue_ = nullptr;
    uint64_t flushes_ = 0;
    size_t chunk_bytes_ = kSendQueueChunkBytesPaced;
};

static size_t build_frame(Cmd cmd, uint16_t seq, const uint8_t* data, uint16_t len, uint8_t* out);
static bool raw_send(Cmd cmd, uint16_t seq, const uint8_t* data, uint16_t len);
static int raw_recv(uint8_t* payload_buf, size_t buf_size, int timeout_ms);
extern size_t g_last_frame_wire_bytes;

// Send the whole STREAM_DATA burst and fill in `tp`. Returns false on a send error.
// block_starts may be empty when the caller has no block structure to pace on.
static bool send_stream_data(const std::vector<uint8_t>& stream,
                             const std::vector<size_t>& block_starts,
                             uint16_t& seq, SendThroughput& tp,
                             const BlockBudget* budget = nullptr) {
    const size_t max_chunk = MAX_DATA_PER_FRAME;
    tp.delay_ms        = g_cfg.inter_chunk_delay_ms;
    tp.target_mbps     = g_cfg.target_mbps;
    tp.block_period_us = g_cfg.block_period_us;

    // Batching cannot express a per-frame Sleep(), and there is no point batching
    // frames that are never handed to a NIC.
    bool batched = g_cfg.use_sendqueue && !g_cfg.dry_run &&
                   g_cfg.inter_chunk_delay_ms == 0;

    BatchSender batch;
    SendSchedule sched;
    SendPacer pacer;
    BlockPacer bpacer;
    if (batched && !batch.begin(sendqueue_chunk_bytes(g_cfg.target_mbps))) {
        CLI_LOG_ERR << "pcap_sendqueue_alloc failed; falling back to per-frame send\n";
        batched = false;
    }
    if (batched) {
        sched.start(g_cfg.block_period_us, g_cfg.target_mbps, budget);
        g_unpaced_coop_flush = (g_cfg.target_mbps <= 0.0);
        g_pause_frames_seen = 0;
    } else {
        pacer.start(g_cfg.target_mbps);
        bpacer.start(g_cfg.block_period_us, &block_starts, stream.size(), g_cfg.block_spread, budget);
        g_unpaced_coop_flush = false;
    }

    uint8_t frame[64 + MAX_DATA_PER_FRAME];
    size_t offset = 0, next_block = 0;
    int last_send_pct = -999;
    bool ok = true;
    const auto t0 = std::chrono::steady_clock::now();

    while (offset < stream.size()) {
        const size_t chunk = (std::min)(max_chunk, stream.size() - offset);
        const bool opens_block = next_block < block_starts.size() &&
                                 offset >= block_starts[next_block];
        if (opens_block)
            while (next_block < block_starts.size() && offset >= block_starts[next_block])
                ++next_block;

        if (batched) {
            if (opens_block && next_block > 1) {
                if (sched.block_period_s > 0.0) {
                    // "Late" means the block's own bytes took longer than the period,
                    // i.e. the intra-block cap, not the period, is what set the pace.
                    if (sched.cursor_s > sched.block_open_s + sched.block_period_s)
                        ++tp.blocks_late;
                    ++tp.blocks_paced;
                }
                // A flush is a hole in the schedule, so only ever take one between
                // blocks, where it just delays the next block start. Reserve a whole
                // block's worth of room, not one frame's: the next chance to flush
                // is a whole block away.
                if (!batch.room_for(kMaxBlockWireBytes) &&
                    !batch.flush(g_pcap, sched.timed())) { ok = false; break; }
                sched.open_block(next_block - 1);
            }
            const size_t wire = build_frame(Cmd::STREAM_DATA, ++seq, stream.data() + offset,
                                            static_cast<uint16_t>(chunk), frame);
            // Only reachable without block structure to flush on, or with a block
            // larger than the reserve above.
            if (!batch.room_for(wire) && !batch.flush(g_pcap, sched.timed())) { ok = false; break; }
            if (!batch.add(frame, wire, sched.release_of(wire))) { ok = false; break; }
            tp.wire_bytes += wire;
        } else {
            if (bpacer.gate(offset)) {
                const double r = bpacer.spread_rate_mbps(bpacer.current_block());
                if (r > 0.0) pacer.set_rate(r); else pacer.rebase();
            }
            if (!raw_send(Cmd::STREAM_DATA, ++seq, stream.data() + offset,
                          static_cast<uint16_t>(chunk))) { ok = false; break; }
            tp.wire_bytes += g_last_frame_wire_bytes;
        }
        offset += chunk;
        tp.frames++;
        tp.payload_bytes += chunk;

        if (g_cfg.progress_send_pct > 0 && !stream.empty()) {
            const int pct = static_cast<int>((100ull * offset) / stream.size());
            if (pct >= last_send_pct + g_cfg.progress_send_pct || offset == stream.size()) {
                CLI_LOG_OUT << "progress send " << pct << "% (" << offset << "/"
                            << stream.size() << " B)\n";
                last_send_pct = pct;
            }
        }
        if (!batched && offset < stream.size()) {
            pacer.wait_for(g_last_frame_wire_bytes);
            if (g_cfg.inter_chunk_delay_ms > 0) {
#ifdef _WIN32
                Sleep(static_cast<DWORD>(g_cfg.inter_chunk_delay_ms));
#endif
            }
        }
    }

    if (ok && batched && !batch.flush(g_pcap, sched.timed())) ok = false;
    g_unpaced_coop_flush = false;

    tp.wall_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - t0).count();
    if (batched) {
        tp.send_batches = batch.flushes();
    } else {
        tp.pace_slips   = pacer.catch_up_forgiven();
        tp.blocks_paced = bpacer.blocks_paced();
        tp.blocks_late  = bpacer.blocks_late();
    }
    if (!ok) CLI_LOG_ERR << "STREAM_DATA send failed at offset=" << offset << "\n";
    return ok;
}

static bool query_decode_block_crc(DecodeBlockCrcPayload& out, int timeout_ms,
                                   int64_t by_index);

static void log_parallel_block(size_t bi, const DecodeBlockCrcPayload& bc) {
    CLI_LOG_OUT << "PARALLEL block=" << bi
                << " fpga_crc=0x" << std::hex << bc.crc32 << std::dec
                << " words=" << bc.word_count
                << " lane=" << static_cast<int>(bc.lane) << "\n";
}

// Opportunistic harvest of GET(DECODE_BLOCK_CRC) "last completed" into a sparse
// result vector. Returns true when a *new* outstanding block was recorded.
static bool try_harvest_last_block(std::vector<DecodeBlockCrcPayload>& crcs,
                                   std::vector<uint8_t>& got,
                                   size_t& got_count,
                                   int timeout_ms) {
    DecodeBlockCrcPayload bc{};
    if (!query_decode_block_crc(bc, timeout_ms, -1)) return false;
    if (!bc.done) return false;
    const size_t bi = static_cast<size_t>(bc.block_index);
    if (bi >= got.size() || got[bi]) return false;
    got[bi] = 1;
    crcs[bi] = bc;
    ++got_count;
    log_parallel_block(bi, bc);
    return true;
}

// fw>=0x80106: query CRC slot by block index. Safe for depth>1 windows.
static bool try_harvest_block_at(size_t bi,
                                 std::vector<DecodeBlockCrcPayload>& crcs,
                                 std::vector<uint8_t>& got,
                                 size_t& got_count,
                                 int timeout_ms) {
    if (bi >= got.size() || got[bi]) return false;
    DecodeBlockCrcPayload bc{};
    if (!query_decode_block_crc(bc, timeout_ms, static_cast<int64_t>(bi))) {
        return false;
    }
    // Indexed query always echoes the requested index; done=0 means slot empty/mismatch.
    if (!bc.done || bc.block_index != static_cast<uint32_t>(bi)) {
        static int s_miss;
        if ((++s_miss % 200) == 1) {
            CLI_LOG_ERR << "INDEX_CRC miss bi=" << bi
                        << " rsp_idx=" << bc.block_index
                        << " done=" << (int)bc.done
                        << " crc=0x" << std::hex << bc.crc32 << std::dec
                        << " words=" << bc.word_count << "\n";
        }
        return false;
    }
    got[bi] = 1;
    crcs[bi] = bc;
    ++got_count;
    log_parallel_block(bi, bc);
    return true;
}

// Scan outstanding [next_send - depth, next_send) via slot-index GET.
static bool harvest_outstanding_indexed(size_t next_send,
                                        size_t depth,
                                        std::vector<DecodeBlockCrcPayload>& crcs,
                                        std::vector<uint8_t>& got,
                                        size_t& got_count,
                                        int timeout_ms) {
    bool any = false;
    const size_t start = (next_send > depth) ? (next_send - depth) : 0;
    for (size_t bi = start; bi < next_send; ++bi) {
        if (got[bi]) continue;
        if (try_harvest_block_at(bi, crcs, got, got_count, timeout_ms)) any = true;
    }
    return any;
}

// Queue or send one wire frame. When `batch` is non-null, frames go into the
// pcap_sendqueue (flushing when full); otherwise per-frame pcap_sendpacket.
// `sched` may be null; when set, release timestamps pace the driver (E8-style).
static bool enqueue_or_send(BatchSender* batch,
                            SendSchedule* sched,
                            Cmd cmd,
                            uint16_t& seq,
                            const uint8_t* data,
                            uint16_t len,
                            SendThroughput& tp,
                            bool count_payload) {
    uint8_t frame[64 + MAX_DATA_PER_FRAME];
    if (batch) {
        const size_t wire = build_frame(cmd, ++seq, data, len, frame);
        const bool sync = sched && sched->timed();
        if (!batch->room_for(wire) && !batch->flush(g_pcap, sync))
            return false;
        const double release = sched ? sched->release_of(wire) : 0.0;
        if (!batch->add(frame, wire, release)) return false;
        tp.wire_bytes += wire;
        tp.frames += 1;
        if (count_payload) tp.payload_bytes += len;
        return true;
    }
    if (!raw_send(cmd, ++seq, data, len)) return false;
    tp.wire_bytes += g_last_frame_wire_bytes;
    tp.frames += 1;
    if (count_payload) tp.payload_bytes += len;
    return true;
}

// Send one block's STREAM_DATA. Prefer BatchSender (same path as legacy E8);
// --no-sendqueue keeps per-frame pcap_sendpacket.
// mid_harvest: only meaningful on the per-frame path (depth=1 / legacy). When
// batching, callers must flush before any GET — mid-queue harvest is impossible.
static bool send_block_data_harvesting(const std::vector<uint8_t>& chunk,
                                       uint16_t& seq,
                                       SendThroughput& tp,
                                       std::vector<DecodeBlockCrcPayload>& crcs,
                                       std::vector<uint8_t>& got,
                                       size_t& got_count,
                                       double& poll_ms_acc,
                                       bool mid_harvest,
                                       BatchSender* batch = nullptr,
                                       SendSchedule* sched = nullptr) {
    const size_t max_chunk = MAX_DATA_PER_FRAME;
    size_t offset = 0;
    while (offset < chunk.size()) {
        const size_t n = (std::min)(max_chunk, chunk.size() - offset);
        if (!enqueue_or_send(batch, sched, Cmd::STREAM_DATA, seq,
                             chunk.data() + offset, static_cast<uint16_t>(n),
                             tp, /*count_payload=*/true)) {
            return false;
        }
        offset += n;
        if (!mid_harvest || batch) continue;
        const auto t_p0 = std::chrono::steady_clock::now();
        while (try_harvest_last_block(crcs, got, got_count, 1)) {
        }
        poll_ms_acc += std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t_p0).count();
    }
    return true;
}

// K-parallel path: STREAM_BLOCK_START before each block, then that block's STREAM_DATA.
//
// CRC poll is NOT a correctness condition for decode — FPGA latches post-XOR CRC into
// the W-deep slot file. Per-block sync poll was CLI flow-control laziness.
//
// What *is* required for per-block CRC verify:
//   - Harvest each index before slot reuse (block_index % W); hold <= W-2.
//   - Data-path pacing is hardware: lane_busy + ring_accept_ready → S_BLOCK_ASSIGN
//     drops rx_ready (mac_proto back-pressures). Do not throttle send on CRC GET.
//
// depth>1: send waves up to hold=W-2 with no mid-send GET; batch slot-index harvest
// when the hold fills (or after all sends). --parallel-sync: legacy wait-each-block.
//
// Host send: DEFAULT uses pcap_sendqueue for BLOCK_START+DATA (same as E8 legacy
// send_stream_data). --no-sendqueue restores per-frame pcap_sendpacket.
static bool query_parallel_info(ParallelInfoPayload& out, int timeout_ms = 2000) {
    static uint16_t s_seq = 0x2200;
    const uint16_t req_seq = ++s_seq;

    // Drop any TX-loopback / stale frames so GET_RSP matching is not starved.
    {
        struct pcap_pkthdr* hdr = nullptr;
        const u_char* pkt = nullptr;
        for (int i = 0; i < 256; ++i) {
            if (pcap_next_ex(g_pcap, &hdr, &pkt) != 1) break;
        }
    }

    GetReqPayload req{};
    req.item_id = static_cast<uint16_t>(GetItemId::PARALLEL_INFO);
    if (!raw_send(Cmd::GET_REQ, req_seq, reinterpret_cast<const uint8_t*>(&req), sizeof(req)))
        return false;

    std::array<uint8_t, 512> rxbuf{};
    auto t0 = std::chrono::steady_clock::now();
    while (true) {
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - t0).count();
        if (elapsed >= timeout_ms) break;

        int n = raw_recv(rxbuf.data(), rxbuf.size(), static_cast<int>(timeout_ms - elapsed));
        if (n <= 0 || n < static_cast<int>(PAYLOAD_HEADER_SIZE + sizeof(GetRspHeader) + 24))
            continue;

        const uint8_t cmd = rxbuf[0];
        const uint16_t rseq = static_cast<uint16_t>(rxbuf[1]) |
                              (static_cast<uint16_t>(rxbuf[2]) << 8);
        if (cmd == static_cast<uint8_t>(Cmd::GET_RSP) && rseq == req_seq) {
            GetRspHeader hdr{};
            std::memcpy(&hdr, rxbuf.data() + PAYLOAD_HEADER_SIZE, sizeof(hdr));
            if (hdr.status != static_cast<uint8_t>(GetStatus::OK)) return false;
            if (hdr.item_id != static_cast<uint16_t>(GetItemId::PARALLEL_INFO)) continue;
            // fw<0x8010D: 24 B; 0x8010D: 32 B; >=0x8010E: 40 B (ge3/ge4). Accept any.
            if (hdr.value_len < 24) return false;
            std::memset(&out, 0, sizeof(out));
            const size_t copy_n =
                (std::min)(sizeof(out), static_cast<size_t>(hdr.value_len));
            std::memcpy(&out, rxbuf.data() + PAYLOAD_HEADER_SIZE + sizeof(GetRspHeader),
                        copy_n);
            return true;
        }
    }
    return false;
}

static bool send_parallel_blocks(const std::vector<BlockData>& blocks,
                                 uint16_t& seq,
                                 SendThroughput& tp,
                                 std::vector<DecodeBlockCrcPayload>* out_block_crcs = nullptr) {
    tp = {};
    tp.delay_ms = g_cfg.inter_chunk_delay_ms;
    tp.target_mbps = g_cfg.target_mbps;
    if (out_block_crcs) out_block_crcs->clear();
    const size_t nblocks = blocks.size();
    std::vector<DecodeBlockCrcPayload> crcs(nblocks);
    std::vector<uint8_t> got(nblocks, 0);
    size_t got_count = 0;
    size_t next_send = 0;
    double poll_ms_acc = 0.0;

    const bool need_crc = out_block_crcs != nullptr;
    const int k_lanes = static_cast<int>(PARALLEL_K_LANES);
    const int depth_cfg = g_cfg.parallel_sync ? 1
        : (std::max)(1, g_cfg.parallel_depth);
    // Send-only: blast all; HW BP paces lanes/ring. Verify depth>1: CRC hold = W-2
    // (slot file), not K — K is enforced by S_BLOCK_ASSIGN, not by GET.
    const size_t hold = (!need_crc)
        ? nblocks
        : (depth_cfg <= 1
               ? 1u
               : static_cast<size_t>(DDR_RING_WINDOWS) - 2u);
    const bool sync_crc = need_crc && hold == 1;
    const bool use_indexed = need_crc && hold > 1;

    // Match send_stream_data: no batching under Sleep pacing or dry-run.
    bool batched = g_cfg.use_sendqueue && !g_cfg.dry_run &&
                   g_cfg.inter_chunk_delay_ms == 0;
    BatchSender batch;
    if (batched && !batch.begin(sendqueue_chunk_bytes(g_cfg.target_mbps))) {
        CLI_LOG_ERR << "pcap_sendqueue_alloc failed; falling back to per-frame send\n";
        batched = false;
    }
    BatchSender* batch_ptr = batched ? &batch : nullptr;
    SendSchedule sched;
    if (batched) {
        sched.start(g_cfg.block_period_us, g_cfg.target_mbps, nullptr);
    }
    SendSchedule* sched_ptr = batched ? &sched : nullptr;
    const bool unpaced_flush_each =
        batched && g_cfg.target_mbps <= 0.0;
    // At high paced rates also flush each block so PAUSE can bite between
    // NIC TX ring dumps (1 MiB / 256 KiB chunks still outrun early PAUSE).
    const bool highrate_flush_each =
        batched && g_cfg.target_mbps >= 250.0;
    const bool flush_each_block = unpaced_flush_each || highrate_flush_each;
    const bool unpaced_coop = unpaced_flush_each;
    // depth=1 send-only: wait for each block_done before next BLOCK_START so
    // K_eff≈1 on the same K=4 bit (compare vs depth>=2 pipelined blast).
    const bool serial_assign = !need_crc && depth_cfg <= 1;

    g_pause_frames_seen = 0;
    // Mid-block enqueue_or_send flushes go through BatchSender::flush — enable
    // cooperative yield there so every transmit (not only flush_each_block) gaps.
    g_unpaced_coop_flush = unpaced_coop;
    CLI_LOG_OUT << "PARALLEL pipeline hold=" << hold
                << " depth_cfg=" << depth_cfg
                << " K=" << k_lanes
                << (sync_crc ? " (sync CRC)"
                             : (need_crc ? " (send+wave CRC harvest)" : " (send-only)"))
                << " sendqueue=" << (batched ? 1 : 0)
                << " chunk_kib=" << (batched ? (batch.chunk_bytes() / 1024) : 0)
                << " flush_each_block=" << (flush_each_block ? 1 : 0)
                << " unpaced_gap_us=" << (unpaced_coop ? g_cfg.unpaced_gap_us : 0)
                << " serial_assign=" << (serial_assign ? 1 : 0)
                << " blocks=" << nblocks << "\n";
    if (use_indexed) {
        CLI_LOG_OUT << "PARALLEL harvest=slot-index waves (fw>=0x80106); "
                       "poll not on send hot path; CRC hold=W-2\n";
        CLI_LOG_OUT.flush();
    }

    auto flush_batch = [&]() -> bool {
        if (!batched || batch.empty()) return true;
        // Yield is inside BatchSender::flush when g_unpaced_coop_flush.
        if (!batch.flush(g_pcap, sched.timed())) {
            CLI_LOG_ERR << "pcap_sendqueue_transmit failed (parallel)\n";
            return false;
        }
        return true;
    };

    auto send_one_block = [&](size_t bi) -> bool {
        const auto& bd = blocks[bi];
        StreamBlockStartPayload bsp{};
        bsp.block_index = static_cast<uint32_t>(bi);
        bsp.block_height = bd.header.block_height_lines();
        bsp.rle_payload_bytes = static_cast<uint32_t>(bd.compressed.size());
        bsp.reserved = 0;
        std::vector<uint8_t> chunk = bd.compressed;
        pad_strip_stream_to_32bit_alignment(chunk);

        // Flush between blocks when the next block may not fit — same reserve
        // policy as send_stream_data (gap only delays the next BLOCK_START).
        if (batched && !batch.room_for(kMaxBlockWireBytes) && !flush_batch())
            return false;
        if (batched && bi > 0)
            sched.open_block(bi);

        if (!enqueue_or_send(batch_ptr, sched_ptr, Cmd::STREAM_BLOCK_START, seq,
                             reinterpret_cast<const uint8_t*>(&bsp),
                             static_cast<uint16_t>(sizeof(bsp)),
                             tp, /*count_payload=*/false)) {
            CLI_LOG_ERR << "STREAM_BLOCK_START failed at block=" << bi << "\n";
            return false;
        }
        // Never mid-frame GET on the hot path (would collapse K_eff to 1).
        if (!send_block_data_harvesting(chunk, seq, tp, crcs, got, got_count,
                                       poll_ms_acc, /*mid_harvest=*/false,
                                       batch_ptr, sched_ptr)) {
            CLI_LOG_ERR << "STREAM_DATA failed at block=" << bi << "\n";
            return false;
        }
        // CRC harvest needs the block on the wire before GET; flush each block
        // when verifying so a giant unpaced burst cannot desync the MAC FSM.
        // Unpaced send-only: also flush each block so PAUSE can gap the NIC TX ring.
        if ((need_crc || flush_each_block) && !flush_batch()) return false;
        tp.blocks_paced += 1;
        return true;
    };

    // Batch-harvest [from, next_send) by slot index. Blocks until all in range are
    // got, or stall. Used only when hold is full or after the send phase ends —
    // not between every block.
    auto harvest_range_blocking = [&](size_t from, size_t until) -> bool {
        // Frames still in the sendqueue must hit the wire before GET can observe
        // completed blocks.
        if (!flush_batch()) return false;
        size_t got_at_last = got_count;
        int stall_spins = 0;
        while (true) {
            bool all = true;
            for (size_t bi = from; bi < until; ++bi) {
                if (!got[bi]) { all = false; break; }
            }
            if (all) return true;

            const auto t_p0 = std::chrono::steady_clock::now();
            bool progressed = false;
            if (use_indexed) {
                for (size_t bi = from; bi < until; ++bi) {
                    if (got[bi]) continue;
                    if (try_harvest_block_at(bi, crcs, got, got_count, 20))
                        progressed = true;
                }
            }
            if (!progressed) {
                progressed = try_harvest_last_block(crcs, got, got_count, 20);
            }
            if (!progressed) Sleep(1);
            poll_ms_acc += std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - t_p0).count();

            if (got_count > got_at_last) {
                got_at_last = got_count;
                stall_spins = 0;
            } else if (++stall_spins > 20000) {
                CLI_LOG_ERR << "DECODE_BLOCK_CRC wave stall: got=" << got_count
                            << " from=" << from << " until=" << until
                            << " sent=" << next_send << "\n";
                return false;
            }
        }
    };

    const auto t0 = std::chrono::steady_clock::now();

    if (sync_crc) {
        // Legacy: send one, wait for its CRC (last_block), repeat.
        for (size_t bi = 0; bi < nblocks; ++bi) {
            if (!send_one_block(bi)) return false;
            if (!flush_batch()) return false;
            ++next_send;
            for (int retry = 0; !got[bi] && retry < 400; ++retry) {
                const auto t_p0 = std::chrono::steady_clock::now();
                if (retry >= 40) Sleep(retry < 80 ? 2 : (retry < 160 ? 10 : 50));
                (void)try_harvest_last_block(crcs, got, got_count, retry < 40 ? 2 : 50);
                poll_ms_acc += std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - t_p0).count();
            }
            if (!got[bi]) {
                CLI_LOG_ERR << "DECODE_BLOCK_CRC timeout waiting for block=" << bi << "\n";
                return false;
            }
        }
    } else if (!need_crc) {
        while (next_send < nblocks) {
            if (!send_one_block(next_send)) return false;
            ++next_send;
            if (serial_assign) {
                // Wait for this block's decode via last_block CRC (PARALLEL_INFO
                // mid-strip GET is unreliable while lanes are still draining).
                const uint32_t want_bi = static_cast<uint32_t>(next_send - 1);
                int stall = 0;
                for (;;) {
                    DecodeBlockCrcPayload bc{};
                    if (query_decode_block_crc(bc, 50, -1) && bc.done &&
                        bc.block_index == want_bi)
                        break;
                    if (++stall > 20000) {
                        CLI_LOG_ERR << "serial_assign stall at sent=" << next_send
                                    << " want_bi=" << want_bi << "\n";
                        return false;
                    }
                    Sleep(1);
                }
            }
        }
        if (!flush_batch()) return false;
    } else {
        // Send hot path: no GET. When unharvested reach hold (W-2), wave-harvest
        // oldest outstanding so CRC slots are not overwritten (index % W).
        while (next_send < nblocks) {
            while (next_send < nblocks && (next_send - got_count) < hold) {
                if (!send_one_block(next_send)) return false;
                ++next_send;
            }
            if (got_count < next_send) {
                // Harvest a full wave of outstanding indices (not just one).
                const size_t wave_from =
                    (next_send > hold) ? (next_send - hold) : 0;
                // Prefer harvesting everything outstanding so send can resume a full hold.
                if (!harvest_range_blocking(wave_from, next_send)) return false;
            }
        }
        if (got_count < nblocks) {
            if (!harvest_range_blocking(0, nblocks)) return false;
        }
    }

    const auto t1 = std::chrono::steady_clock::now();
    g_unpaced_coop_flush = false;
    tp.wall_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    tp.poll_ms = poll_ms_acc;
    // Wall minus CRC harvest. With sendqueue, pcap_sendqueue_transmit is part of wall.
    tp.send_only_ms = (std::max)(0.0, tp.wall_ms - tp.poll_ms);
    if (batched) tp.send_batches = batch.flushes();

    if (out_block_crcs) {
        out_block_crcs->assign(crcs.begin(), crcs.end());
        for (size_t i = 0; i < nblocks; ++i) {
            if (!got[i]) {
                CLI_LOG_ERR << "PARALLEL missing CRC for block=" << i << "\n";
                return false;
            }
        }
    }
    CLI_LOG_OUT << "PARALLEL harvest done got=" << got_count
                << " send_only_ms=" << std::fixed << std::setprecision(1) << tp.send_only_ms
                << " poll_ms=" << tp.poll_ms
                << " wall_ms=" << tp.wall_ms
                << " send_batches=" << tp.send_batches
                << " pause_seen=" << g_pause_frames_seen << "\n";
    return true;
}

static std::string throughput_kv(const SendThroughput& tp) {
    std::ostringstream o;
    o << std::fixed << std::setprecision(3);
    o << "frames=" << tp.frames
      << " payload_bytes=" << tp.payload_bytes
      << " wire_bytes=" << tp.wire_bytes
      << " wall_ms=" << tp.wall_ms
      << " payload_MBps=" << tp.payload_mb_per_s()
      << " wire_Mbps=" << tp.wire_mbit_per_s()
      << " frames_per_s=" << tp.frames_per_s()
      << " delay_ms=" << tp.delay_ms
      << " target_mbps=" << tp.target_mbps
      << " pace_slips=" << tp.pace_slips
      << " block_period_us=" << tp.block_period_us
      << " blocks_paced=" << tp.blocks_paced
      << " blocks_late=" << tp.blocks_late
      << " send_batches=" << tp.send_batches
      << " send_only_ms=" << tp.send_only_ms
      << " poll_ms=" << tp.poll_ms;
    return o.str();
}

static std::string throughput_json(const SendThroughput& tp) {
    std::ostringstream o;
    o << std::fixed << std::setprecision(3);
    o << "\"frames\":" << tp.frames
      << ",\"payload_bytes\":" << tp.payload_bytes
      << ",\"wire_bytes\":" << tp.wire_bytes
      << ",\"wall_ms\":" << tp.wall_ms
      << ",\"payload_MBps\":" << tp.payload_mb_per_s()
      << ",\"wire_Mbps\":" << tp.wire_mbit_per_s()
      << ",\"frames_per_s\":" << tp.frames_per_s()
      << ",\"inter_chunk_delay_ms\":" << tp.delay_ms
      << ",\"target_mbps\":" << tp.target_mbps
      << ",\"pace_slips\":" << tp.pace_slips
      << ",\"block_period_us\":" << tp.block_period_us
      << ",\"blocks_paced\":" << tp.blocks_paced
      << ",\"blocks_late\":" << tp.blocks_late
      << ",\"send_batches\":" << tp.send_batches
      << ",\"send_only_ms\":" << tp.send_only_ms
      << ",\"poll_ms\":" << tp.poll_ms;
    return o.str();
}

static std::string json_escape(const std::string& s) {
    std::string r;
    r.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '\\': r += "\\\\"; break;
            case '"':  r += "\\\""; break;
            case '\n': r += "\\n";  break;
            case '\r': r += "\\r";  break;
            case '\t': r += "\\t";  break;
            default:   r += c;      break;
        }
    }
    return r;
}

struct VerifyTimings {
    int64_t prepare_ms = 0;
    int64_t send_ms = 0;
    int64_t fpga_wait_ms = 0;
    int64_t pc_ref_ms = 0;
};
static VerifyTimings g_last_verify_timings;

static inline int64_t steady_ms(std::chrono::steady_clock::time_point a,
                                std::chrono::steady_clock::time_point b) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(b - a).count();
}

static uint32_t expected_word_count_for_decoded_bytes(uint32_t decoded_bytes) {
    if (decoded_bytes == 0) return 0;
    const uint32_t full = decoded_bytes / 64u;
    const uint32_t rem = decoded_bytes % 64u;
    return full + (rem != 0u ? 1u : 0u);
}

// ---------------------------------------------------------------------------
// MAC address parsing / formatting
// ---------------------------------------------------------------------------
static bool parse_mac(const std::string& s, uint8_t out[6]) {
    unsigned a[6];
    if (std::sscanf(s.c_str(), "%x:%x:%x:%x:%x:%x",
                    &a[0],&a[1],&a[2],&a[3],&a[4],&a[5]) != 6 &&
        std::sscanf(s.c_str(), "%x-%x-%x-%x-%x-%x",
                    &a[0],&a[1],&a[2],&a[3],&a[4],&a[5]) != 6)
        return false;
    for (int i = 0; i < 6; ++i) out[i] = static_cast<uint8_t>(a[i]);
    return true;
}

static void merge_app_config_into_g_cfg(const AppConfig& ac) {
    if (!ac.interface_name.empty()) g_cfg.iface_name = ac.interface_name;
    if (!ac.local_mac.empty()) {
        uint8_t m[6]{};
        if (parse_mac(ac.local_mac, m)) std::memcpy(g_cfg.local_mac, m, 6);
    }
    if (!ac.target_mac.empty()) {
        uint8_t m[6]{};
        if (parse_mac(ac.target_mac, m)) std::memcpy(g_cfg.target_mac, m, 6);
    }

    if (!ac.v8_verify.loaded_from_json) return;
    const auto& v = ac.v8_verify;
    g_cfg.fpga_only = v.fpga_only;
    if (v.inter_chunk_delay_set) g_cfg.inter_chunk_delay_ms = v.inter_chunk_delay_ms;
    if (v.progress_send_pct_set) g_cfg.progress_send_pct = v.progress_send_pct;
    if (v.decode_progress_set) g_cfg.decode_progress = v.decode_progress;
    if (v.round_budget_sec_set) g_cfg.round_budget_sec = v.round_budget_sec;
    if (v.pc_spot_check_set) g_cfg.pc_spot_check = v.pc_spot_check;
}

static std::string mac_to_str(const uint8_t m[6]) {
    char buf[20];
    std::snprintf(buf, sizeof(buf), "%02x:%02x:%02x:%02x:%02x:%02x",
                  m[0],m[1],m[2],m[3],m[4],m[5]);
    return buf;
}

// ---------------------------------------------------------------------------
// Interface helpers: list, auto-detect, get local MAC
// ---------------------------------------------------------------------------
static void list_interfaces() {
    pcap_if_t* alldevs = nullptr;
    char errbuf[PCAP_ERRBUF_SIZE];
    if (pcap_findalldevs(&alldevs, errbuf) == -1) {
        CLI_LOG_ERR << "pcap_findalldevs failed: " << errbuf << "\n";
        return;
    }
    int idx = 0;
    for (auto* d = alldevs; d; d = d->next) {
        CLI_LOG_OUT << "[" << idx++ << "] " << d->name;
        if (d->description) CLI_LOG_OUT << "  (" << d->description << ")";
        CLI_LOG_OUT << "\n";
    }
    pcap_freealldevs(alldevs);
}

#ifdef _WIN32
static bool get_adapter_mac(const std::string& pcap_name, uint8_t out[6]) {
    // pcap name is like \Device\NPF_{GUID}; Windows adapter name is the GUID part
    // Extract GUID from pcap name
    auto pos = pcap_name.find('{');
    if (pos == std::string::npos) return false;
    std::string guid = pcap_name.substr(pos);

    ULONG bufLen = 0;
    GetAdaptersInfo(nullptr, &bufLen);
    std::vector<uint8_t> buf(bufLen);
    auto* info = reinterpret_cast<IP_ADAPTER_INFO*>(buf.data());
    if (GetAdaptersInfo(info, &bufLen) != NO_ERROR) return false;

    for (auto* p = info; p; p = p->Next) {
        std::string name = std::string("\\Device\\Tcpip_") + p->AdapterName;
        // Compare adapter name (GUID)
        if (pcap_name.find(p->AdapterName) != std::string::npos) {
            if (p->AddressLength == 6) {
                std::memcpy(out, p->Address, 6);
                return true;
            }
        }
    }
    return false;
}
#endif

static std::string auto_detect_interface() {
    pcap_if_t* alldevs = nullptr;
    char errbuf[PCAP_ERRBUF_SIZE];
    if (pcap_findalldevs(&alldevs, errbuf) == -1) return "";

    std::string result;
    for (auto* d = alldevs; d; d = d->next) {
        // Skip loopback
        if (d->flags & PCAP_IF_LOOPBACK) continue;

        // Prefer interface with description containing "Ethernet"
        std::string desc = d->description ? d->description : "";
        if (desc.find("Ethernet") != std::string::npos ||
            desc.find("ethernet") != std::string::npos) {
            result = d->name;
            break;
        }
        if (result.empty()) result = d->name;
    }
    pcap_freealldevs(alldevs);
    return result;
}

// ---------------------------------------------------------------------------
// Pcap open / close / send / recv
// ---------------------------------------------------------------------------
static bool open_pcap() {
    if (g_cfg.dry_run) {
        // No NIC is opened and no frame ever leaves the host. Frames are still
        // fully built and timed so the throughput instrumentation is exercised.
        CLI_LOG_OUT << "DRY-RUN: no interface opened, frames are built and timed but not sent.\n";
        CLI_LOG_OUT << "DRY-RUN: throughput numbers cover frame construction only "
                       "(no NIC, no link); use them to validate instrumentation, not the link.\n";
        return true;
    }
    if (g_cfg.iface_name.empty()) {
        g_cfg.iface_name = auto_detect_interface();
        if (g_cfg.iface_name.empty()) {
            CLI_LOG_ERR << "No network interface found. Use --iface or --list-ifaces.\n";
            return false;
        }
        CLI_LOG_OUT << "Auto-selected interface: " << g_cfg.iface_name << "\n";
    }

    char errbuf[PCAP_ERRBUF_SIZE];
    g_pcap = pcap_open_live(g_cfg.iface_name.c_str(), 65536, 1, 1, errbuf);
    if (!g_pcap) {
        CLI_LOG_ERR << "pcap_open_live failed: " << errbuf << "\n";
        return false;
    }

    // Set BPF filter: protocol frames + 802.3x PAUSE (0x8808) for cooperative yield.
    struct bpf_program fp{};
    const std::string filter = "ether proto 0x4b52 or ether proto 0x8808";
    if (pcap_compile(g_pcap, &fp, filter.c_str(), 1, PCAP_NETMASK_UNKNOWN) == 0) {
        pcap_setfilter(g_pcap, &fp);
        pcap_freecode(&fp);
    }

#ifdef _WIN32
    // Auto-detect local MAC if not specified
    if (g_cfg.local_mac[0] == 0 && g_cfg.local_mac[1] == 0 &&
        g_cfg.local_mac[2] == 0 && g_cfg.local_mac[3] == 0 &&
        g_cfg.local_mac[4] == 0 && g_cfg.local_mac[5] == 0) {
        if (!get_adapter_mac(g_cfg.iface_name, g_cfg.local_mac)) {
            CLI_LOG_ERR << "WARNING: Cannot detect local MAC. Use --local-mac.\n";
            // Use a default
            g_cfg.local_mac[0] = 0x00; g_cfg.local_mac[1] = 0x00;
            g_cfg.local_mac[2] = 0x00; g_cfg.local_mac[3] = 0x00;
            g_cfg.local_mac[4] = 0x00; g_cfg.local_mac[5] = 0x01;
        }
    }
#endif

    CLI_LOG_OUT << "Local MAC:  " << mac_to_str(g_cfg.local_mac) << "\n";
    CLI_LOG_OUT << "Target MAC: " << mac_to_str(g_cfg.target_mac) << "\n";
    return true;
}

static void close_pcap() {
    if (g_pcap) { pcap_close(g_pcap); g_pcap = nullptr; }
}

// Wire bytes of the frame most recently built by raw_send() (excludes FCS).
size_t g_last_frame_wire_bytes = 0;

// Build a raw Ethernet frame into `out` (must hold >= 60 + len bytes).
// Returns the wire size, i.e. the frame including min-frame padding, excluding FCS.
static size_t build_frame(Cmd cmd, uint16_t seq, const uint8_t* data, uint16_t len,
                          uint8_t* out) {
    const size_t frame_size = ETH_HEADER_SIZE + PAYLOAD_HEADER_SIZE + len;
    const size_t pad_size = (std::max)(frame_size, size_t{60});
    std::memset(out, 0, pad_size);

    std::memcpy(out, g_cfg.target_mac, 6);       // DA
    std::memcpy(out + 6, g_cfg.local_mac, 6);    // SA
    out[12] = static_cast<uint8_t>(ETHERTYPE_RLE4K >> 8);
    out[13] = static_cast<uint8_t>(ETHERTYPE_RLE4K & 0xFF);

    // PayloadHeader at offset 14
    out[14] = static_cast<uint8_t>(cmd);
    out[15] = static_cast<uint8_t>(seq & 0xFF);
    out[16] = static_cast<uint8_t>((seq >> 8) & 0xFF);
    out[17] = static_cast<uint8_t>(len & 0xFF);
    out[18] = static_cast<uint8_t>((len >> 8) & 0xFF);

    if (data && len > 0)
        std::memcpy(out + ETH_HEADER_SIZE + PAYLOAD_HEADER_SIZE, data, len);
    return pad_size;
}

// Build and send a raw Ethernet frame: EthHeader + PayloadHeader + data
static bool raw_send(Cmd cmd, uint16_t seq, const uint8_t* data, uint16_t len) {
    static uint8_t frame[64 + MAX_DATA_PER_FRAME];
    const size_t pad_size = build_frame(cmd, seq, data, len, frame);
    g_last_frame_wire_bytes = pad_size;
    if (g_cfg.dry_run) return true;
    return pcap_sendpacket(g_pcap, frame, static_cast<int>(pad_size)) == 0;
}

// Receive a frame, strip Ethernet header, return payload.
// Returns payload length (>0) on success, 0 on timeout, -1 on error.
static bool g_debug_recv = false;

static int raw_recv(uint8_t* payload_buf, size_t buf_size, int timeout_ms) {
    if (g_cfg.dry_run) return 0;   // nothing was sent, so nothing can answer
    if (timeout_ms < 0) timeout_ms = g_cfg.timeout_ms;

    auto t0 = std::chrono::steady_clock::now();
    int pkt_seen = 0;
    while (true) {
        struct pcap_pkthdr* hdr = nullptr;
        const uint8_t* pkt = nullptr;
        int rc = pcap_next_ex(g_pcap, &hdr, &pkt);

        if (rc == 1) {
            pkt_seen++;
            if (g_debug_recv && pkt_seen <= 20) {
                char dbg[256];
                std::snprintf(dbg, sizeof(dbg),
                    "  [dbg] pkt#%d len=%u DA=%02x:%02x:%02x:%02x:%02x:%02x SA=%02x:%02x:%02x:%02x:%02x:%02x ET=%02x%02x",
                    pkt_seen, hdr->caplen,
                    pkt[0],pkt[1],pkt[2],pkt[3],pkt[4],pkt[5],
                    pkt[6],pkt[7],pkt[8],pkt[9],pkt[10],pkt[11],
                    pkt[12],pkt[13]);
                CLI_LOG_OUT << dbg << "\n";
            }
            if (hdr->caplen >= ETH_HEADER_SIZE + PAYLOAD_HEADER_SIZE) {
                uint16_t et = (static_cast<uint16_t>(pkt[12]) << 8) | pkt[13];
                if (et != ETHERTYPE_RLE4K) goto check_timeout;

                if (std::memcmp(pkt + 6, g_cfg.target_mac, 6) != 0) {
                    if (g_debug_recv) {
                        CLI_LOG_OUT << "  [dbg] ET match but SA mismatch, skip\n";
                    }
                    goto check_timeout;
                }

                size_t payload_len = hdr->caplen - ETH_HEADER_SIZE;
                if (payload_len > buf_size) payload_len = buf_size;
                std::memcpy(payload_buf, pkt + ETH_HEADER_SIZE, payload_len);
                return static_cast<int>(payload_len);
            }
        }

    check_timeout:
        auto elapsed = std::chrono::steady_clock::now() - t0;
        if (std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count() >= timeout_ms)
            return 0;

        if (rc < 0) return -1;
    }
}

// ---------------------------------------------------------------------------
// echo
// ---------------------------------------------------------------------------
static int cmd_echo(int count, int payload_size) {
    if (payload_size < 0) payload_size = 32;
    if (count <= 0) count = 10;

    std::vector<uint8_t> payload(static_cast<size_t>(payload_size), 0xAB);
    std::array<uint8_t, 65536> rxbuf{};
    int success = 0, fail = 0;
    double total_rtt = 0.0;

    for (int i = 0; i < count; ++i) {
        uint16_t seq = static_cast<uint16_t>(i + 1);
        if (payload_size >= 2) {
            payload[0] = static_cast<uint8_t>(seq & 0xFF);
            payload[1] = static_cast<uint8_t>((seq >> 8) & 0xFF);
        }
        auto t0 = std::chrono::steady_clock::now();
        if (!raw_send(Cmd::ECHO_REQ, seq, payload.data(), static_cast<uint16_t>(payload.size()))) {
            CLI_LOG_ERR << "send failed\n"; ++fail; continue;
        }
        int n = raw_recv(rxbuf.data(), rxbuf.size(), -1);
        auto t1 = std::chrono::steady_clock::now();
        if (n <= 0) {
            CLI_LOG_OUT << "echo " << (i+1) << "/" << count << " timeout\n";
            ++fail; continue;
        }
        double rtt = std::chrono::duration<double, std::milli>(t1 - t0).count();
        total_rtt += rtt;
        ++success;
        CLI_LOG_OUT << "echo " << (i+1) << "/" << count
                    << " bytes=" << n << " rtt=" << rtt << " ms\n";
    }

    CLI_LOG_OUT << "\n--- echo statistics ---\n"
                << count << " sent, " << success << " received, "
                << fail << " lost (" << (100.0*fail/count) << "% loss)\n";
    if (success > 0)
        CLI_LOG_OUT << "avg rtt = " << (total_rtt / success) << " ms\n";
    return (fail == 0) ? 0 : 1;
}

// ---------------------------------------------------------------------------
// ping
// ---------------------------------------------------------------------------
static int cmd_ping(int count) {
    if (count <= 0) count = 5;
    std::array<uint8_t, 256> rxbuf{};
    int ok = 0;
    for (int i = 0; i < count; ++i) {
        uint16_t seq = static_cast<uint16_t>(i + 1);
        auto t0 = std::chrono::steady_clock::now();
        raw_send(Cmd::PING, seq, nullptr, 0);
        int n = raw_recv(rxbuf.data(), rxbuf.size(), -1);
        auto t1 = std::chrono::steady_clock::now();
        if (n > 0 && rxbuf[0] == static_cast<uint8_t>(Cmd::PONG)) {
            double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
            CLI_LOG_OUT << "pong seq=" << seq << " rtt=" << ms << " ms\n";
            ++ok;
        } else {
            CLI_LOG_OUT << "ping seq=" << seq << " timeout\n";
        }
    }
    CLI_LOG_OUT << ok << "/" << count << " pong received\n";
    return (ok == count) ? 0 : 1;
}

// ---------------------------------------------------------------------------
// hardware --version
// ---------------------------------------------------------------------------
static int cmd_query(const std::string& item) {
    const std::string qi = item.empty() ? "version" : item;
    if (qi != "version") { CLI_LOG_ERR << "Unsupported: " << qi << "\n"; return 1; }

    static uint16_t s_seq = 0x1000;
    const uint16_t req_seq = ++s_seq;

    GetReqPayload req{};
    req.item_id = static_cast<uint16_t>(GetItemId::VERSION);
    if (!raw_send(Cmd::GET_REQ, req_seq, reinterpret_cast<const uint8_t*>(&req), sizeof(req))) {
        CLI_LOG_ERR << "GET_REQ send failed\n"; return 1;
    }

    std::array<uint8_t, 512> rxbuf{};
    for (int i = 0; i < 8; ++i) {
        int n = raw_recv(rxbuf.data(), rxbuf.size(), -1);
        if (n <= 0 || n < static_cast<int>(PAYLOAD_HEADER_SIZE)) continue;

        const uint8_t cmd = rxbuf[0];
        const uint16_t rseq = static_cast<uint16_t>(rxbuf[1]) |
                              (static_cast<uint16_t>(rxbuf[2]) << 8);

        if (cmd == static_cast<uint8_t>(Cmd::GET_RSP) && rseq == req_seq) {
            if (n < static_cast<int>(PAYLOAD_HEADER_SIZE + sizeof(GetRspHeader))) continue;
            GetRspHeader hdr{};
            std::memcpy(&hdr, rxbuf.data() + PAYLOAD_HEADER_SIZE, sizeof(hdr));
            if (hdr.status != static_cast<uint8_t>(GetStatus::OK) || hdr.value_len == 0) {
                CLI_LOG_ERR << "GET_RSP status=" << static_cast<int>(hdr.status)
                            << " len=" << hdr.value_len << "\n";
                return 1;
            }
            const uint8_t* pl = rxbuf.data() + PAYLOAD_HEADER_SIZE + sizeof(GetRspHeader);
            if (hdr.value_len >= sizeof(Rle4kVersionPayload20)) {
                Rle4kVersionPayload20 v{};
                std::memcpy(&v, pl, sizeof(v));
                CLI_LOG_OUT << "hardware.firmware=0x" << std::hex << v.firmware_version << std::dec << "\n";
                CLI_LOG_OUT << "hardware.board=0x" << std::hex << v.board_version << std::dec << "\n";
                CLI_LOG_OUT << "hardware.vendor=0x" << std::hex << v.board_vendor << std::dec << "\n";
                CLI_LOG_OUT << "hardware.builder=0x" << std::hex << v.firmware_builder << std::dec << "\n";
                CLI_LOG_OUT << "hardware.burn_time=0x" << std::hex << v.firmware_burn_time << std::dec << "\n";
                return 0;
            }
            CLI_LOG_ERR << "VERSION payload too short: " << hdr.value_len << "\n";
            return 1;
        }
        if (cmd == static_cast<uint8_t>(Cmd::ERROR_RSP) &&
            n >= static_cast<int>(PAYLOAD_HEADER_SIZE + sizeof(ErrorRspPayload))) {
            ErrorRspPayload err{};
            std::memcpy(&err, rxbuf.data() + PAYLOAD_HEADER_SIZE, sizeof(err));
            if (err.original_cmd == static_cast<uint8_t>(Cmd::GET_REQ) &&
                err.original_seq == req_seq) {
                CLI_LOG_ERR << "GET ERROR: type=0x" << std::hex << (int)err.error_type
                            << " detail=0x" << err.detail << std::dec << "\n";
                return 1;
            }
        }
    }
    CLI_LOG_ERR << "GET_RSP timeout\n";
    return 1;
}

static int cmd_hardware(const std::vector<std::string>& args) {
    if (args.size() == 1 && args[0] == "--version") return cmd_query("version");
    CLI_LOG_ERR << "Usage: hardware --version\n"; return 1;
}

// ---------------------------------------------------------------------------
// dog / wdt -- GET(ACTIVITY_WDT): host inactivity watchdog counters
// ---------------------------------------------------------------------------
static bool query_activity_wdt(ActivityWdtPayload& out, int timeout_ms = 2000) {
    static uint16_t s_seq = 0x3000;
    const uint16_t req_seq = ++s_seq;

    GetReqPayload req{};
    req.item_id = static_cast<uint16_t>(GetItemId::ACTIVITY_WDT);
    if (!raw_send(Cmd::GET_REQ, req_seq, reinterpret_cast<const uint8_t*>(&req), sizeof(req)))
        return false;

    std::array<uint8_t, 256> rxbuf{};
    auto t0 = std::chrono::steady_clock::now();
    while (true) {
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - t0).count();
        if (elapsed >= timeout_ms) break;

        int n = raw_recv(rxbuf.data(), rxbuf.size(), static_cast<int>(timeout_ms - elapsed));
        if (n <= 0 || n < static_cast<int>(PAYLOAD_HEADER_SIZE + sizeof(GetRspHeader) + sizeof(ActivityWdtPayload)))
            continue;

        const uint8_t cmd = rxbuf[0];
        const uint16_t rseq = static_cast<uint16_t>(rxbuf[1]) |
                              (static_cast<uint16_t>(rxbuf[2]) << 8);

        if (cmd == static_cast<uint8_t>(Cmd::GET_RSP) && rseq == req_seq) {
            GetRspHeader hdr{};
            std::memcpy(&hdr, rxbuf.data() + PAYLOAD_HEADER_SIZE, sizeof(hdr));
            if (hdr.status != static_cast<uint8_t>(GetStatus::OK)) return false;
            if (hdr.item_id != static_cast<uint16_t>(GetItemId::ACTIVITY_WDT)) continue;
            if (hdr.value_len < sizeof(ActivityWdtPayload)) return false;
            std::memcpy(&out, rxbuf.data() + PAYLOAD_HEADER_SIZE + sizeof(GetRspHeader), sizeof(out));
            return true;
        }
    }
    return false;
}

static int cmd_dog() {
    ActivityWdtPayload w{};
    if (!query_activity_wdt(w, g_cfg.timeout_ms)) {
        CLI_LOG_ERR << "dog: no GET_RSP(ACTIVITY_WDT) or firmware too old\n";
        return 1;
    }
    const uint32_t ticks = w.timeout_ticks;
    const double sec_approx = (ticks > 0u && ticks <= 0x0FFFFFFFu)
        ? (static_cast<double>(ticks) / 15625000.0)
        : 0.0;
    CLI_LOG_OUT << "activity_wdt timeout_count=" << w.timeout_count
                << " wdt_counter=" << w.wdt_counter
                << " timeout_ticks=" << w.timeout_ticks
                << " (~" << sec_approx << " s @ 15.625 MHz if in default range)\n";
    return 0;
}

// ---------------------------------------------------------------------------
// status / reset
// ---------------------------------------------------------------------------
static bool query_decoder_snapshot(StatusResponse& out, int timeout_ms) {
    if (!raw_send(Cmd::STATUS_REQ, 0, nullptr, 0)) return false;
    std::array<uint8_t, 256> rxbuf{};
    int n = raw_recv(rxbuf.data(), rxbuf.size(), timeout_ms);
    if (n < static_cast<int>(PAYLOAD_HEADER_SIZE + sizeof(StatusResponse))) return false;
    if (rxbuf[0] != static_cast<uint8_t>(Cmd::STATUS_RSP)) return false;
    std::memcpy(&out, rxbuf.data() + PAYLOAD_HEADER_SIZE, sizeof(out));
    return true;
}

static int cmd_status() {
    StatusResponse sr{};
    if (!query_decoder_snapshot(sr, g_cfg.timeout_ms)) {
        CLI_LOG_ERR << "No status response\n"; return 1;
    }
    CLI_LOG_OUT << "block_done=" << (int)sr.block_done
                << " error=" << (int)sr.error_code
                << " words_written=" << sr.words_written
                << " addr=0x" << std::hex << sr.current_addr << std::dec << "\n";
    return 0;
}

static int cmd_reset() {
    raw_send(Cmd::RESET, 0, nullptr, 0);
    CLI_LOG_OUT << "Reset sent.\n";
    return 0;
}

// ---------------------------------------------------------------------------
// File/dir helpers
// ---------------------------------------------------------------------------
static bool is_regular_file_path(const std::string& p) {
    struct _stat st{}; return (_stat(p.c_str(), &st) == 0) && (st.st_mode & _S_IFREG);
}
static bool is_directory_path(const std::string& p) {
    struct _stat st{}; return (_stat(p.c_str(), &st) == 0) && (st.st_mode & _S_IFDIR);
}

// ---------------------------------------------------------------------------
// send command -- STREAM_START + STREAM_DATA + STREAM_END (raw Ethernet)
// ---------------------------------------------------------------------------
static int cmd_send(const std::string& path, int strip_filter, size_t max_blocks) {
    const auto send_t0 = std::chrono::steady_clock::now();

    std::vector<BlockData> blocks;
    if (is_directory_path(path))
        blocks = BlockReader::read_directory(path, max_blocks, strip_filter);
    else {
        BlockData bd;
        if (!BlockReader::read_block(path, bd)) {
            CLI_LOG_ERR << "Cannot read: " << path << "\n"; return 1;
        }
        blocks.push_back(std::move(bd));
    }
    if (blocks.empty()) {
        CLI_LOG_ERR << "No block files found in: " << path << "\n"; return 1;
    }

    uint32_t total_height = 0;
    uint64_t total_compressed = 0, total_source = 0;
    for (const auto& bd : blocks) {
        total_height += bd.header.block_height_lines();
        total_compressed += bd.compressed.size();
        total_source += bd.header.source_length;
    }

    const auto& first = blocks.front();
    const uint32_t lw = first.header.line_width_bits();
    const uint32_t ls = first.header.line_stride_bits();
    const uint16_t si = static_cast<uint16_t>(first.strip_index >= 0 ? first.strip_index : 0);
    const uint16_t bh = static_cast<uint16_t>(first.header.block_height_lines());

    std::vector<uint8_t> stream;
    std::vector<size_t>  block_starts;
    stream.reserve(static_cast<size_t>(total_compressed));
    block_starts.reserve(blocks.size());
    for (const auto& bd : blocks) {
        block_starts.push_back(stream.size());
        stream.insert(stream.end(), bd.compressed.begin(), bd.compressed.end());
    }

    const uint32_t rle_payload_u32 = static_cast<uint32_t>(stream.size());
    pad_strip_stream_to_32bit_alignment(stream);

    CLI_LOG_OUT << "Stream: blocks=" << blocks.size()
                << " height=" << total_height
                << " block_height=" << bh
                << " width=" << lw << " stride=" << ls
                << " rle_payload=" << rle_payload_u32
                << " wire_bytes=" << stream.size()
                << " source=" << total_source << "\n";

    // RESET
    raw_send(Cmd::RESET, 0, nullptr, 0);
    Sleep(20);

    uint16_t seq = 0;

    // STREAM_START
    StreamStartPayload ssp{};
    ssp.line_width_bits  = lw;
    ssp.line_stride_bits = ls;
    ssp.total_height        = total_height;
    ssp.total_bytes         = static_cast<uint32_t>(stream.size());
    ssp.strip_index         = si;
    ssp.block_height        = bh;
    ssp.rle_payload_bytes   = rle_payload_u32;
    if (!raw_send(Cmd::STREAM_START, ++seq, reinterpret_cast<const uint8_t*>(&ssp), sizeof(ssp))) {
        CLI_LOG_ERR << "STREAM_START send failed\n"; return 1;
    }
    CLI_LOG_OUT << "STREAM_START sent\n";

    SendThroughput tp;
    if (g_cfg.parallel) {
        CLI_LOG_OUT << "PARALLEL K-send: STREAM_BLOCK_START per block\n";
        if (!send_parallel_blocks(blocks, seq, tp)) return 1;
    } else {
        // STREAM_DATA — full speed by default (no inter-frame delay).
        // --inter-chunk-delay-ms N reinstates pacing for debugging the FPGA adapter.
        BlockBudget budget;
        if (g_cfg.block_budget) {
            budget.build(stream, block_starts, rle_payload_u32, bh, g_cfg.block_margin_pct);
            CLI_LOG_OUT << "BLOCK_BUDGET " << block_budget_kv(budget, g_cfg.block_margin_pct) << "\n";
        }
        if (!send_stream_data(stream, block_starts, seq, tp, &budget)) return 1;
    }
    const double data_ms = tp.wall_ms;

    CLI_LOG_OUT << "STREAM_DATA: pkts=" << tp.frames
                << " bytes=" << stream.size()
                << " data_ms=" << data_ms << "\n";
    CLI_LOG_OUT << "THROUGHPUT " << throughput_kv(tp) << "\n";

    // STREAM_END
    raw_send(Cmd::STREAM_END, ++seq, nullptr, 0);
    CLI_LOG_OUT << "STREAM_END sent\n";

    // Stats
    const auto send_t1 = std::chrono::steady_clock::now();
    const double elapsed_ms = std::chrono::duration<double, std::milli>(send_t1 - send_t0).count();
    const double elapsed_s = elapsed_ms / 1000.0;
    const double compressed_mbps = (elapsed_s > 0.0) ?
        (static_cast<double>(total_compressed) * 8.0 / 1e6 / elapsed_s) : 0.0;
    const double source_mbps = (elapsed_s > 0.0) ?
        (static_cast<double>(total_source) * 8.0 / 1e6 / elapsed_s) : 0.0;
    const double avg_block_ms = elapsed_ms / (std::max)(size_t{1}, blocks.size());

    CLI_LOG_OUT << "Send: blocks=" << blocks.size()
                << " compressed=" << total_compressed
                << " source=" << total_source
                << " elapsed_ms=" << elapsed_ms
                << " avg_block_ms=" << avg_block_ms << "\n";
    CLI_LOG_OUT << "Throughput: compressed_Mbps=" << compressed_mbps
                << " source_Mbps=" << source_mbps << "\n";

    StatusResponse sr{};
    if (query_decoder_snapshot(sr, 500)) {
        CLI_LOG_OUT << "Decoder: done=" << (int)sr.block_done
                    << " err=" << (int)sr.error_code
                    << " words=" << sr.words_written
                    << " addr=0x" << std::hex << sr.current_addr << std::dec << "\n";
    } else {
        CLI_LOG_OUT << "Decoder: (not available)\n";
    }
    CLI_LOG_OUT << "Send complete.\n";

    if (blocks.size() > 1u && g_cfg.bench_target_max_ms > 0) {
        const char* rm = (elapsed_ms <= g_cfg.bench_target_max_ms) ? "PASS" : "FAIL";
        const char* ri = (elapsed_ms <= g_cfg.bench_target_ideal_ms) ? "PASS" : "FAIL";
        CLI_LOG_OUT << "STRIP_BENCH blocks=" << blocks.size()
                    << " elapsed_ms=" << elapsed_ms
                    << " max=" << g_cfg.bench_target_max_ms
                    << " ideal=" << g_cfg.bench_target_ideal_ms
                    << " result_max=" << rm << " result_ideal=" << ri << "\n";
    }

    if (g_cfg.emit_json) {
        std::ostringstream j;
        j << std::fixed << std::setprecision(3);
        j << "{\"command\":\"send\""
          << ",\"dry_run\":" << (g_cfg.dry_run ? "true" : "false")
          << ",\"path\":\"" << json_escape(path) << "\""
          << ",\"blocks\":" << blocks.size()
          << ",\"total_height\":" << total_height
          << ",\"compressed_bytes\":" << total_compressed
          << ",\"source_bytes\":" << total_source
          << ",\"rle_payload_bytes\":" << rle_payload_u32
          << ",\"stream_wire_payload_bytes\":" << stream.size()
          << ",\"total_elapsed_ms\":" << elapsed_ms
          << ",\"throughput\":{" << throughput_json(tp) << "}"
          << "}";
        CLI_LOG_OUT << "JSON " << j.str() << "\n";
    }
    return 0;
}

// ---------------------------------------------------------------------------
// CRC32 (standard Ethernet, polynomial 0x04C11DB7, reflected)
// ---------------------------------------------------------------------------
static uint32_t crc32_table[256];
static bool     crc32_table_ready = false;

static void crc32_init_table() {
    if (crc32_table_ready) return;
    for (uint32_t i = 0; i < 256; ++i) {
        uint32_t c = i;
        for (int j = 0; j < 8; ++j)
            c = (c & 1) ? (c >> 1) ^ 0xEDB88320u : (c >> 1);
        crc32_table[i] = c;
    }
    crc32_table_ready = true;
}

static uint32_t crc32_update(uint32_t crc, const uint8_t* data, size_t len) {
    crc32_init_table();
    for (size_t i = 0; i < len; ++i)
        crc = crc32_table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    return crc;
}

static uint32_t crc32_final(uint32_t crc) { return crc ^ 0xFFFFFFFFu; }

// ---------------------------------------------------------------------------
// Query FPGA decode CRC32 via GET_REQ(DECODE_CRC)
// ---------------------------------------------------------------------------
// False when the board answered with a pre-tail-checkpoint payload. Firmware older than
// the STREAM_END drain fix returns 39 body bytes and simply has no diag_crc[5..6]; the
// known-good rollback bitstream is one of those, so comparing those two slots against a
// PC reference that does compute them would produce a bogus FAIL.
static bool g_decode_crc_has_tail = false;

static bool query_decode_crc(DecodeCrcPayload& out, int timeout_ms = 2000) {
    static uint16_t s_seq = 0x2000;
    const uint16_t req_seq = ++s_seq;

    GetReqPayload req{};
    req.item_id = static_cast<uint16_t>(GetItemId::DECODE_CRC);
    if (!raw_send(Cmd::GET_REQ, req_seq, reinterpret_cast<const uint8_t*>(&req), sizeof(req)))
        return false;

    std::array<uint8_t, 512> rxbuf{};
    auto t0 = std::chrono::steady_clock::now();
    while (true) {
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - t0).count();
        if (elapsed >= timeout_ms) break;

        int n = raw_recv(rxbuf.data(), rxbuf.size(), static_cast<int>(timeout_ms - elapsed));
        if (n <= 0 || n < static_cast<int>(PAYLOAD_HEADER_SIZE)) continue;

        const uint8_t cmd = rxbuf[0];
        const uint16_t rseq = static_cast<uint16_t>(rxbuf[1]) |
                              (static_cast<uint16_t>(rxbuf[2]) << 8);

        if (cmd == static_cast<uint8_t>(Cmd::GET_RSP) && rseq == req_seq) {
            const size_t min_body = 13;
            if (n < static_cast<int>(PAYLOAD_HEADER_SIZE + sizeof(GetRspHeader) + min_body))
                continue;
            GetRspHeader hdr{};
            std::memcpy(&hdr, rxbuf.data() + PAYLOAD_HEADER_SIZE, sizeof(hdr));
            if (hdr.status != static_cast<uint8_t>(GetStatus::OK)) return false;
            std::memset(&out, 0, sizeof(out));
            size_t avail = static_cast<size_t>(n) - PAYLOAD_HEADER_SIZE - sizeof(GetRspHeader);
            size_t copy_len = (std::min)(avail, sizeof(out));
            std::memcpy(&out, rxbuf.data() + PAYLOAD_HEADER_SIZE + sizeof(GetRspHeader), copy_len);
            g_decode_crc_has_tail = (copy_len >= sizeof(DecodeCrcPayload));
            return true;
        }
    }
    return false;
}

// timeout_ms: pcap wait. by_index: if >=0, send GetReqDecodeBlockCrc (fw>=0x80106
// reads the slot file; older fw returns last_block and may not match).
static bool query_decode_block_crc(DecodeBlockCrcPayload& out, int timeout_ms,
                                   int64_t by_index) {
    static uint16_t s_seq = 0x2100;
    const uint16_t req_seq = ++s_seq;

    if (by_index >= 0) {
        GetReqDecodeBlockCrc req{};
        req.item_id = static_cast<uint16_t>(GetItemId::DECODE_BLOCK_CRC);
        req.block_index = static_cast<uint32_t>(by_index);
        if (!raw_send(Cmd::GET_REQ, req_seq, reinterpret_cast<const uint8_t*>(&req),
                      sizeof(req)))
            return false;
    } else {
        GetReqPayload req{};
        req.item_id = static_cast<uint16_t>(GetItemId::DECODE_BLOCK_CRC);
        if (!raw_send(Cmd::GET_REQ, req_seq, reinterpret_cast<const uint8_t*>(&req),
                      sizeof(req)))
            return false;
    }

    std::array<uint8_t, 512> rxbuf{};
    auto t0 = std::chrono::steady_clock::now();
    while (true) {
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - t0).count();
        if (elapsed >= timeout_ms) break;

        int n = raw_recv(rxbuf.data(), rxbuf.size(), static_cast<int>(timeout_ms - elapsed));
        if (n <= 0 || n < static_cast<int>(PAYLOAD_HEADER_SIZE)) continue;

        const uint8_t cmd = rxbuf[0];
        const uint16_t rseq = static_cast<uint16_t>(rxbuf[1]) |
                              (static_cast<uint16_t>(rxbuf[2]) << 8);

        if (cmd == static_cast<uint8_t>(Cmd::GET_RSP) && rseq == req_seq) {
            if (n < static_cast<int>(PAYLOAD_HEADER_SIZE + sizeof(GetRspHeader) + 14))
                continue;
            GetRspHeader hdr{};
            std::memcpy(&hdr, rxbuf.data() + PAYLOAD_HEADER_SIZE, sizeof(hdr));
            if (hdr.status != static_cast<uint8_t>(GetStatus::OK)) return false;
            std::memset(&out, 0, sizeof(out));
            // Wire value is always 14 bytes (value_len=0x0E); ignore MSVC trailing pad.
            std::memcpy(&out, rxbuf.data() + PAYLOAD_HEADER_SIZE + sizeof(GetRspHeader), 14);
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Default batch log filename (cwd), timestamped
// ---------------------------------------------------------------------------
static std::string default_batch_log_filename() {
    std::time_t t = std::time(nullptr);
    std::tm tm{};
#ifdef _WIN32
    if (localtime_s(&tm, &t) != 0) return "rle4k_v8_batch.log";
#else
    const std::tm* pt = std::localtime(&t);
    if (!pt) return "rle4k_v8_batch.log";
    tm = *pt;
#endif
    char buf[96];
    if (std::strftime(buf, sizeof(buf), "rle4k_v8_batch_%Y%m%d_%H%M%S.log", &tm) == 0)
        return "rle4k_v8_batch.log";
    return std::string(buf);
}

// ---------------------------------------------------------------------------
// verify command: send + FPGA CRC vs PC reference decode CRC
// ---------------------------------------------------------------------------
static void emit_verify_metrics_line(std::ostream* sink,
                                     int metrics_strip,
                                     size_t num_blocks,
                                     const VerifyTimings& tm,
                                     bool fpga_only_mode,
                                     int budget_sec,
                                     uint32_t decode_status_raw,
                                     uint8_t done,
                                     uint32_t fpga_words,
                                     uint32_t expected_words,
                                     const char* result_tag,
                                     const char* fail_reason = "OK") {
    // decode_status[7:0] is informational unless bit 12 (error_present) is set;
    // reporting it as "err" unconditionally is what caused the historical false FAIL.
    const uint32_t err_code = DecodeStatus::error_code(decode_status_raw);
    const int err_present = DecodeStatus::error_present(decode_status_raw) ? 1 : 0;
    const int64_t fpga_path = tm.send_ms + tm.fpga_wait_ms;
    const int64_t budget_ms = static_cast<int64_t>(budget_sec) * 1000;
    const char* budget_state =
        (budget_ms > 0 && fpga_path > budget_ms) ? "WARN" : "PASS";
    if (budget_ms > 0 && fpga_path > budget_ms) {
        CLI_LOG_ERR << "BUDGET round fpga_path_ms=" << fpga_path << " exceeds budget_ms=" << budget_ms
                    << " (report only)\n";
    }
    std::ostringstream oss;
    oss << "METRICS strip=" << metrics_strip
        << " blocks=" << num_blocks
        << " prepare_ms=" << tm.prepare_ms
        << " send_ms=" << tm.send_ms
        << " fpga_wait_ms=" << tm.fpga_wait_ms
        << " pc_ref_ms=" << tm.pc_ref_ms
        << " fpga_path_ms=" << fpga_path
        << " fpga_only=" << (fpga_only_mode ? 1 : 0)
        << " err_present=" << err_present
        << " err=0x" << std::hex << std::setfill('0') << std::setw(2) << err_code
        << " status=0x" << std::setw(8) << decode_status_raw
        << std::dec << std::setfill(' ')
        << " done=" << static_cast<int>(done)
        << " fpga_words=" << fpga_words
        << " expected_words=" << expected_words
        << " budget_sec=" << budget_sec
        << " budget=" << budget_state
        << " reason=" << fail_reason
        << " result=" << result_tag;
    const std::string line = oss.str();
    CLI_LOG_OUT << line << "\n";
    if (sink) *sink << line << "\n";
}

// Machine-readable verify result (one line, emitted only with --json).
static void emit_verify_json(const std::string& path,
                             int metrics_strip,
                             size_t num_blocks,
                             const VerifyTimings& tm,
                             const SendThroughput& tp,
                             bool fpga_only_mode,
                             const VerifyEvidence& ev,
                             const VerifyVerdict& vd) {
    std::ostringstream j;
    j << std::fixed << std::setprecision(3);
    j << "{\"command\":\"verify\""
      << ",\"dry_run\":" << (g_cfg.dry_run ? "true" : "false")
      << ",\"path\":\"" << json_escape(path) << "\""
      << ",\"strip\":" << metrics_strip
      << ",\"blocks\":" << num_blocks
      << ",\"mode\":\"" << (fpga_only_mode ? "fpga_only" : "full_reference") << "\""
      << ",\"result\":\"" << vd.tag() << "\""
      << ",\"reason\":\"" << verify_fail_reason_name(vd.reason) << "\""
      << ",\"detail\":\"" << json_escape(vd.detail) << "\""
      << ",\"done\":" << static_cast<int>(ev.done)
      << ",\"fpga_words\":" << ev.word_count
      << ",\"expected_words\":" << ev.expected_words
      << ",\"crc32_caliber\":\"post_xor\""
      << ",\"fpga_crc32\":\"0x" << std::hex << std::setw(8) << std::setfill('0')
      << ev.fpga_crc32 << "\"" << std::dec << std::setfill(' ');
    if (ev.have_reference) {
        j << ",\"pc_crc32\":\"0x" << std::hex << std::setw(8) << std::setfill('0')
          << ev.ref_crc32 << "\"" << std::dec << std::setfill(' ')
          << ",\"pc_words\":" << ev.ref_word_count
          << ",\"diag_match\":" << ev.diag_match_count;
    }
    j << ",\"decode_status\":{"
      << "\"raw\":\"0x" << std::hex << std::setw(8) << std::setfill('0')
      << ev.decode_status << "\"" << std::dec << std::setfill(' ')
      << ",\"lines\":" << DecodeStatus::lines(ev.decode_status)
      << ",\"error_present\":" << (vd.error_present ? "true" : "false")
      << ",\"error_code\":" << vd.error_code
      << ",\"low8\":" << DecodeStatus::low8(ev.decode_status)
      << ",\"end_recv\":" << (DecodeStatus::end_recv(ev.decode_status) ? 1 : 0)
      << ",\"filling\":" << (DecodeStatus::filling(ev.decode_status) ? 1 : 0)
      << ",\"line_end\":" << (DecodeStatus::line_end(ev.decode_status) ? 1 : 0)
      << ",\"blk_done\":" << (DecodeStatus::blk_done(ev.decode_status) ? 1 : 0)
      << ",\"reserved_bits_set\":" << (vd.reserved_bits_set ? "true" : "false")
      << "}"
      << ",\"timings_ms\":{"
      << "\"prepare\":" << tm.prepare_ms
      << ",\"send\":" << tm.send_ms
      << ",\"fpga_wait\":" << tm.fpga_wait_ms
      << ",\"pc_ref\":" << tm.pc_ref_ms
      << "}"
      << ",\"throughput\":{" << throughput_json(tp) << "}"
      << "}";
    CLI_LOG_OUT << "JSON " << j.str() << "\n";
}

static int cmd_verify(const std::string& path, int strip_filter, size_t max_blocks, bool verbose,
                      std::ostream* metrics_sink = nullptr) {
    VerifyTimings t{};
    SendThroughput tp;
    tp.delay_ms = g_cfg.inter_chunk_delay_ms;
    tp.target_mbps = g_cfg.target_mbps;
    tp.block_period_us = g_cfg.block_period_us;
    const auto t_fn0 = std::chrono::steady_clock::now();
    int metrics_strip = strip_filter;
    size_t num_blocks = 0;
    uint32_t expected_words_total = 0;

    // 1. Read blocks (same as cmd_send)
    std::vector<BlockData> blocks;
    if (is_directory_path(path))
        blocks = BlockReader::read_directory(path, max_blocks, strip_filter);
    else {
        BlockData bd;
        if (!BlockReader::read_block(path, bd)) {
            CLI_LOG_ERR << "Cannot read: " << path << "\n"; return 1;
        }
        blocks.push_back(std::move(bd));
    }
    if (blocks.empty()) {
        CLI_LOG_ERR << "No block files found in: " << path << "\n";
        return 1;
    }
    num_blocks = blocks.size();

    uint32_t total_height = 0;
    uint64_t total_compressed = 0;
    for (const auto& bd : blocks) {
        total_height += bd.header.block_height_lines();
        total_compressed += bd.compressed.size();
    }

    const auto& first = blocks.front();
    if (metrics_strip < 0) metrics_strip = first.strip_index >= 0 ? first.strip_index : -1;
    const uint32_t lw = first.header.line_width_bits();
    const uint32_t ls = first.header.line_stride_bits();
    const uint16_t si = static_cast<uint16_t>(first.strip_index >= 0 ? first.strip_index : 0);
    const uint16_t bh = static_cast<uint16_t>(first.header.block_height_lines());
    const uint32_t stride_bytes = (ls + 7) / 8;

    std::vector<uint8_t> stream;
    std::vector<size_t>  block_starts;
    stream.reserve(static_cast<size_t>(total_compressed));
    block_starts.reserve(blocks.size());
    for (const auto& bd : blocks) {
        block_starts.push_back(stream.size());
        stream.insert(stream.end(), bd.compressed.begin(), bd.compressed.end());
    }

    const uint32_t rle_payload_u32 = static_cast<uint32_t>(stream.size());
    pad_strip_stream_to_32bit_alignment(stream);
    const auto t_prep1 = std::chrono::steady_clock::now();
    t.prepare_ms = steady_ms(t_fn0, t_prep1);

    for (const auto& bd : blocks) {
        const uint32_t bhl = bd.header.block_height_lines();
        expected_words_total += expected_word_count_for_decoded_bytes(stride_bytes * bhl);
    }

    if (verbose) {
        CLI_LOG_OUT << "Verify: blocks=" << blocks.size()
                    << " height=" << total_height
                    << " block_height=" << bh
                    << " width=" << lw << " stride=" << ls
                    << " rle_payload=" << rle_payload_u32
                    << " wire_bytes=" << stream.size()
                    << " expected_words=" << expected_words_total << "\n";
    }

    // 2. Send to FPGA (RESET + STREAM_START/DATA/END)
    const auto t_send0 = std::chrono::steady_clock::now();
    raw_send(Cmd::RESET, 0, nullptr, 0);
    Sleep(20);

    uint16_t seq = 0;
    StreamStartPayload ssp{};
    ssp.line_width_bits  = lw;
    ssp.line_stride_bits = ls;
    ssp.total_height        = total_height;
    ssp.total_bytes         = static_cast<uint32_t>(stream.size());
    ssp.strip_index         = si;
    ssp.block_height        = bh;
    ssp.rle_payload_bytes   = rle_payload_u32;
    if (!raw_send(Cmd::STREAM_START, ++seq, reinterpret_cast<const uint8_t*>(&ssp), sizeof(ssp))) {
        CLI_LOG_ERR << "STREAM_START send failed\n";
        const auto t_send1 = std::chrono::steady_clock::now();
        t.send_ms = steady_ms(t_send0, t_send1);
        emit_verify_metrics_line(metrics_sink, metrics_strip, num_blocks, t, g_cfg.fpga_only,
                                 g_cfg.round_budget_sec, 0, 0, 0, expected_words_total,
                                 "STREAM_START_FAIL", "STREAM_START_FAIL");
        g_last_verify_timings = t;
        return 1;
    }

    // STREAM_DATA burst (or per-block STREAM_BLOCK_START + DATA when --parallel).
    BlockBudget budget;
    bool send_ok = false;
    std::vector<DecodeBlockCrcPayload> parallel_crcs;
    // Parallel DEFAULT = send-only (FCS + backpressure). CRC only with
    // --verify-block-crc / --parallel-sync (--no-verify-block-crc is explicit alias).
    const bool parallel_crc_gate =
        g_cfg.parallel && (g_cfg.verify_block_crc || g_cfg.parallel_sync);
    if (g_cfg.parallel) {
        CLI_LOG_OUT << "PARALLEL K-send: STREAM_BLOCK_START per block"
                    << (g_cfg.parallel_sync ? " (sync CRC)"
                        : (parallel_crc_gate ? " (verify-block-crc harvest)"
                                             : " (send-only, no CRC poll)"))
                    << "\n";
        send_ok = parallel_crc_gate
            ? send_parallel_blocks(blocks, seq, tp, &parallel_crcs)
            : send_parallel_blocks(blocks, seq, tp);
    } else {
        if (g_cfg.block_budget) {
            budget.build(stream, block_starts, rle_payload_u32, bh, g_cfg.block_margin_pct);
            CLI_LOG_OUT << "BLOCK_BUDGET " << block_budget_kv(budget, g_cfg.block_margin_pct) << "\n";
        }
        send_ok = send_stream_data(stream, block_starts, seq, tp, &budget);
    }
    if (!send_ok) {
        const auto t_send1 = std::chrono::steady_clock::now();
        t.send_ms = steady_ms(t_send0, t_send1);
        emit_verify_metrics_line(metrics_sink, metrics_strip, num_blocks, t, g_cfg.fpga_only,
                                 g_cfg.round_budget_sec, 0, 0, 0, expected_words_total,
                                 "STREAM_DATA_FAIL", "STREAM_DATA_FAIL");
        g_last_verify_timings = t;
        return 1;
    }
    raw_send(Cmd::STREAM_END, ++seq, nullptr, 0);
    const auto t_send1 = std::chrono::steady_clock::now();
    t.send_ms = steady_ms(t_send0, t_send1);
    if (verbose) CLI_LOG_OUT << "Data sent to FPGA.\n";
    CLI_LOG_OUT << "THROUGHPUT " << throughput_kv(tp) << "\n";

    // Parallel: send-only throughput (default) or optional per-block CRC gate.
    if (g_cfg.parallel) {
        const int64_t parallel_send_only =
            static_cast<int64_t>(tp.send_only_ms + 0.5);
        const int64_t parallel_poll =
            static_cast<int64_t>(tp.poll_ms + 0.5);
        t.send_ms = parallel_send_only;
        t.fpga_wait_ms = parallel_poll;

        if (!parallel_crc_gate) {
            ParallelInfoPayload pinfo{};
            bool got_pinfo = false;
            bool complete = false;
            // Line-rate sendqueue can leave the MAC FSM quiet to GET until the
            // RX path drains; wait for a pong (or budget) then poll PARALLEL_INFO.
            const int64_t info_budget_ms =
                (std::max)(int64_t{8000},
                           static_cast<int64_t>(blocks.size()) * 2);
            const auto t_info0 = std::chrono::steady_clock::now();
            {
                std::array<uint8_t, 64> pbuf{};
                for (;;) {
                    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::steady_clock::now() - t_info0).count();
                    if (elapsed > info_budget_ms) break;
                    // Drain stale RX so PONG/GET_RSP matching is not starved.
                    {
                        struct pcap_pkthdr* hdr = nullptr;
                        const u_char* pkt = nullptr;
                        for (int i = 0; i < 64; ++i) {
                            if (pcap_next_ex(g_pcap, &hdr, &pkt) != 1) break;
                        }
                    }
                    static uint16_t s_ping = 0x7700;
                    const uint16_t ps = ++s_ping;
                    raw_send(Cmd::PING, ps, nullptr, 0);
                    const int n = raw_recv(pbuf.data(), pbuf.size(), 20);
                    if (n > 0 && pbuf[0] == static_cast<uint8_t>(Cmd::PONG))
                        break;
                    Sleep(2);
                }
            }
            while (true) {
                const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - t_info0).count();
                if (elapsed > info_budget_ms) break;
                if (query_parallel_info(pinfo, 50)) {
                    got_pinfo = true;
                    if (pinfo.blocks_completed >= static_cast<uint32_t>(blocks.size())) {
                        complete = true;
                        break;
                    }
                }
                Sleep(2);
            }
            const double end_sync_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - t_info0).count();
            // Wall from first BLOCK_START through blocks_completed==N (or timeout).
            const double decode_complete_ms = tp.send_only_ms + end_sync_ms;
            t.fpga_wait_ms = static_cast<int64_t>(end_sync_ms + 0.5);
            // Missing PARALLEL_INFO after a full send is a hang/wedge signal — fail.
            // (Older fw without GET still returns got_pinfo=false; fw>=0x80106 has it.)
            const bool pass = got_pinfo && complete;
            // One end-of-strip GET only. Per-lane hist needs --verify-block-crc (triage);
            // wire packing of k_lanes/window_w is not relied on here — use compile-time K.
            CLI_LOG_OUT << "PARALLEL_INFO got=" << (got_pinfo ? 1 : 0)
                        << " K=" << (int)PARALLEL_K_LANES
                        << " blocks_completed=" << (got_pinfo ? pinfo.blocks_completed : 0)
                        << " expected=" << blocks.size()
                        << " end_sync_ms=" << std::fixed << std::setprecision(1) << end_sync_ms
                        << " decode_complete_ms=" << decode_complete_ms
                        << "\n";
            if (got_pinfo && pinfo.lane_sample_cyc > 0) {
                const double inv =
                    100.0 / static_cast<double>(pinfo.lane_sample_cyc);
                const double ge2_pct = inv * static_cast<double>(pinfo.lane_busy_ge2_cyc);
                const double ge3_pct = inv * static_cast<double>(pinfo.lane_busy_ge3_cyc);
                const double ge4_pct = inv * static_cast<double>(pinfo.lane_busy_ge4_cyc);
                CLI_LOG_OUT << "LANE_OVERLAP ge2_cyc=" << pinfo.lane_busy_ge2_cyc
                            << " ge3_cyc=" << pinfo.lane_busy_ge3_cyc
                            << " ge4_cyc=" << pinfo.lane_busy_ge4_cyc
                            << " sample_cyc=" << pinfo.lane_sample_cyc
                            << " ge2_pct=" << std::setprecision(2) << ge2_pct
                            << " ge3_pct=" << ge3_pct
                            << " ge4_pct=" << ge4_pct
                            << "\n";
            }
            CLI_LOG_OUT << "PARALLEL RESULT " << (pass ? "PASS" : "FAIL")
                        << " mode=send_only"
                        << " blocks=" << blocks.size()
                        << " wall_ms=" << tp.wall_ms
                        << " send_only_ms=" << tp.send_only_ms
                        << " poll_ms=" << tp.poll_ms
                        << " end_sync_ms=" << end_sync_ms
                        << " decode_complete_ms=" << decode_complete_ms
                        << " send_batches=" << tp.send_batches
                        << " (MAC+BP; CRC gate off -- triage: --verify-block-crc)\n";
            emit_verify_metrics_line(metrics_sink, metrics_strip, num_blocks, t, g_cfg.fpga_only,
                                     g_cfg.round_budget_sec, 0, pass ? 1 : 0, 0, expected_words_total,
                                     pass ? "PASS" : "FAIL",
                                     pass ? "SEND_ONLY" : "PARALLEL_INFO");
            g_last_verify_timings = t;
            return pass ? 0 : 1;
        }

        // Optional correctness: independent per-block CRC (not strip-chained DECODE_CRC).
        int mismatches = 0;
        int missing = 0;
        int compared = 0;
        const int every = (std::max)(1, g_cfg.verify_block_crc_every);
        if (parallel_crcs.size() != blocks.size()) {
            CLI_LOG_ERR << "PARALLEL CRC count mismatch: got=" << parallel_crcs.size()
                        << " expected=" << blocks.size() << "\n";
            missing = static_cast<int>(blocks.size() - parallel_crcs.size());
        }
        const auto t_pc0 = std::chrono::steady_clock::now();
        for (size_t bi = 0; bi < blocks.size() && bi < parallel_crcs.size(); ++bi) {
            const bool sample = (every <= 1)
                || (bi % static_cast<size_t>(every) == 0)
                || (bi + 1 == blocks.size());
            if (!sample) continue;
            ++compared;
            const auto& bd = blocks[bi];
            const auto& fc = parallel_crcs[bi];
            const uint32_t bhl = bd.header.block_height_lines();
            const uint32_t bdsz = stride_bytes * bhl;
            const uint32_t exp_words = expected_word_count_for_decoded_bytes(bdsz);
            if (g_cfg.fpga_only) {
                if (!fc.done || fc.word_count != exp_words) {
                    CLI_LOG_ERR << "PARALLEL FPGA-only FAIL block=" << bi
                                << " done=" << (int)fc.done
                                << " words=" << fc.word_count << " expected=" << exp_words << "\n";
                    ++mismatches;
                } else {
                    CLI_LOG_OUT << "PARALLEL FPGA-only PASS block=" << bi
                                << " crc=0x" << std::hex << fc.crc32 << std::dec
                                << " words=" << fc.word_count << "\n";
                }
                continue;
            }
            std::vector<uint8_t> blk_out(bdsz, 0);
            const int ret = rle4k_decode_block(
                bd.compressed.data(),
                static_cast<uint32_t>(bd.compressed.size()),
                blk_out.data(),
                lw, bhl, stride_bytes);
            if (ret < 0) {
                CLI_LOG_ERR << "PARALLEL PC decode FAIL block=" << bi << " ret=" << ret << "\n";
                ++mismatches;
                continue;
            }
            uint32_t pc = 0xFFFFFFFFu;
            uint32_t words = 0;
            for (uint32_t off = 0; off + 64 <= bdsz; off += 64) {
                pc = crc32_update(pc, blk_out.data() + off, 64);
                ++words;
            }
            if (bdsz % 64u) {
                std::array<uint8_t, 64> tail{};
                const uint32_t rem = bdsz % 64u;
                std::memcpy(tail.data(), blk_out.data() + (bdsz - rem), rem);
                pc = crc32_update(pc, tail.data(), 64);
                ++words;
            }
            const uint32_t pc_final = crc32_final(pc);
            if (pc_final != fc.crc32 || words != fc.word_count) {
                CLI_LOG_ERR << "PARALLEL CRC FAIL block=" << bi
                            << " fpga=0x" << std::hex << fc.crc32
                            << " pc=0x" << pc_final << std::dec
                            << " fpga_words=" << fc.word_count
                            << " pc_words=" << words << "\n";
                ++mismatches;
            } else {
                CLI_LOG_OUT << "PARALLEL CRC PASS block=" << bi
                            << " crc=0x" << std::hex << fc.crc32 << std::dec
                            << " words=" << fc.word_count
                            << " lane=" << (int)fc.lane << "\n";
            }
        }
        t.pc_ref_ms = steady_ms(t_pc0, std::chrono::steady_clock::now());
        // Do NOT fold pc_ref into fpga_wait — that was inflating fpga_path_ms.
        const bool pass = (mismatches == 0 && missing == 0);
        // Lane load from harvested FPGA CRCs (proof of multi-lane dispatch).
        int lane_hist[4] = {0, 0, 0, 0};
        int lane_other = 0;
        for (const auto& fc : parallel_crcs) {
            if (fc.lane < 4) ++lane_hist[fc.lane];
            else ++lane_other;
        }
        CLI_LOG_OUT << "PARALLEL LANES lane0=" << lane_hist[0]
                    << " lane1=" << lane_hist[1]
                    << " lane2=" << lane_hist[2]
                    << " lane3=" << lane_hist[3]
                    << " other=" << lane_other
                    << " depth=" << g_cfg.parallel_depth << "\n";
        CLI_LOG_OUT << "PARALLEL RESULT " << (pass ? "PASS" : "FAIL")
                    << " mode=verify_block_crc"
                    << " compared=" << compared
                    << " every=" << every
                    << " blocks=" << blocks.size()
                    << " mismatches=" << mismatches
                    << " missing=" << missing
                    << " wall_ms=" << tp.wall_ms
                    << " send_only_ms=" << tp.send_only_ms
                    << " poll_ms=" << tp.poll_ms
                    << " fpga_path_ms=" << (t.send_ms + t.fpga_wait_ms)
                    << " pc_ref_ms=" << t.pc_ref_ms << "\n";
        emit_verify_metrics_line(metrics_sink, metrics_strip, num_blocks, t, g_cfg.fpga_only,
                                 g_cfg.round_budget_sec, 0, pass ? 1 : 0, 0, expected_words_total,
                                 pass ? "PASS" : "FAIL",
                                 pass ? "OK" : "PARALLEL_BLOCK_CRC");
        g_last_verify_timings = t;
        return pass ? 0 : 1;
    }

    // 3. Wait for FPGA to finish decoding, then query CRC
    const auto t_fpga0 = std::chrono::steady_clock::now();
    const int qtimeout_ms = 2000;
    int max_retries = 80 + static_cast<int>(stream.size() / (48 * 1024));
    if (total_height > 200000) max_retries += 400;
    if (max_retries > 2400) max_retries = 2400;
    // The first 50 retries are 2 ms polls, so the floor has to clear them plus enough
    // 500 ms polls for the stall detector (retry >= 90) to reach kStallPolls.
    if (max_retries < 200) max_retries = 200;
    if (g_cfg.dry_run) max_retries = 0;   // nothing was sent, so nothing can answer
    DecodeCrcPayload fpga_crc{};
    bool got_crc = false;
    uint32_t last_lines = 0;
    int last_dec_pct = -999;
    // Overrunning the decoder does not lose a few words, it stops the decoder for
    // good: done never asserts and every remaining poll is dead time. A whole strip
    // decodes in under two seconds, so 20 s without the line counter moving is a
    // stall, not slow progress. Bailing out early is what makes a pacing scan
    // affordable -- each failing point used to cost the full 545 s poll.
    const int kStallPolls = 40;
    int no_progress = 0;
    bool stalled = false;
    // The first polls are deliberately fine grained. When the sender is the limiter the
    // decoder finishes within a few ms of the last frame, so a 100 ms first sleep does
    // not measure the hardware, it measures the sleep -- and it was being reported as
    // FPGA time. Coarsen only once the fast polls have shown this is a long wait.
    for (int retry = 0; retry < max_retries; ++retry) {
        const int sleep_ms = (retry < 50) ? 2 : (retry < 58) ? 100 : (retry < 90 ? 250 : 500);
        Sleep(sleep_ms);
        if (query_decode_crc(fpga_crc, qtimeout_ms)) {
            got_crc = true;
            const uint32_t lines = fpga_crc.decode_status >> 16;
            if (lines != last_lines) {
                no_progress = 0;
                if (g_cfg.decode_progress && total_height > 0) {
                    const int pct = static_cast<int>((100ull * lines) / total_height);
                    if (pct >= last_dec_pct + 5 || fpga_crc.done) {
                        CLI_LOG_OUT << "progress decode lines=" << lines << "/" << total_height
                                    << " (" << pct << "%)"
                                    << " done=" << (int)fpga_crc.done << "\n";
                        last_dec_pct = pct;
                    }
                }
                last_lines = lines;
            } else if (!fpga_crc.done && sleep_ms >= 500 && ++no_progress >= kStallPolls) {
                stalled = true;
                CLI_LOG_ERR << "decoder stalled at lines=" << lines << "/" << total_height
                            << " (no progress for " << kStallPolls << " polls); giving up\n";
                break;
            }
            if (fpga_crc.done) break;
        }
    }
    (void)stalled;
    const auto t_fpga1 = std::chrono::steady_clock::now();
    t.fpga_wait_ms = steady_ms(t_fpga0, t_fpga1);

    // ------------------------------------------------------------------
    // Evidence gathering. The verdict is computed by evaluate_verify() from
    // this struct alone (see verify_verdict.h); decode_status[7:0] is only an
    // error code when decode_status[12] (error_present) is set.
    // ------------------------------------------------------------------
    const VerifyMode mode = g_cfg.fpga_only ? VerifyMode::FpgaOnly : VerifyMode::FullReference;
    VerifyEvidence ev;
    ev.crc_query_ok   = got_crc;
    ev.expected_words = expected_words_total;
    if (got_crc) {
        ev.done          = fpga_crc.done;
        ev.word_count    = fpga_crc.word_count;
        ev.decode_status = fpga_crc.decode_status;
        ev.fpga_crc32    = fpga_crc.crc32;   // post-XOR caliber
    }

    if (!got_crc) {
        const VerifyVerdict vd = evaluate_verify(ev, mode);
        CLI_LOG_ERR << "Failed to query FPGA decode CRC: " << vd.detail << "\n";
        emit_verify_metrics_line(metrics_sink, metrics_strip, num_blocks, t, g_cfg.fpga_only,
                                 g_cfg.round_budget_sec, 0, 0, 0, expected_words_total,
                                 vd.tag(), verify_fail_reason_name(vd.reason));
        g_last_verify_timings = t;
        if (g_cfg.emit_json)
            emit_verify_json(path, metrics_strip, num_blocks, t, tp, g_cfg.fpga_only, ev, vd);
        return 1;
    }

    if (verbose && !g_cfg.fpga_only) {
        CLI_LOG_OUT << "FPGA: crc32=0x" << std::hex << fpga_crc.crc32 << std::dec
                    << " (post-XOR) words=" << fpga_crc.word_count
                    << " done=" << (int)fpga_crc.done
                    << " | " << format_decode_status(fpga_crc.decode_status) << "\n";
        CLI_LOG_OUT << "DIAG CRC checkpoints:";
        for (int ci = 0; ci < 5; ++ci)
            CLI_LOG_OUT << " [w" << DIAG_CRC_WORD_INDEX[ci] << "]=0x"
                        << std::hex << fpga_crc.diag_crc[ci] << std::dec;
        for (int ci = 0; g_decode_crc_has_tail && ci < 2; ++ci)
            CLI_LOG_OUT << " [end-" << DIAG_CRC_TAIL_BACK[ci] << "]=0x"
                        << std::hex << fpga_crc.diag_crc[5 + ci] << std::dec;
        CLI_LOG_OUT << "\n";
    }

    if (fpga_crc.done == 0)
        CLI_LOG_ERR << "FPGA decode not done (done=0), continuing PC decode for diagnostics\n";

    // 4. PC-side reference decode + CRC with 5 diagnostic checkpoints (skipped in --fpga-only)
    const uint32_t decoded_size = stride_bytes * total_height;

    if (g_cfg.fpga_only) {
        t.pc_ref_ms = 0;
        if (g_cfg.pc_spot_check > 0) {
            const auto t_spot0 = std::chrono::steady_clock::now();
            ev.pc_decode_attempted = true;
            const int ncheck =
                (std::min)(g_cfg.pc_spot_check, static_cast<int>(blocks.size()));
            for (int bi = 0; bi < ncheck; ++bi) {
                const auto& bd = blocks[static_cast<size_t>(bi)];
                const uint32_t bhl = bd.header.block_height_lines();
                const uint32_t bdsz = stride_bytes * bhl;
                std::vector<uint8_t> blk_out(bdsz, 0);
                const int ret = rle4k_decode_block(
                    bd.compressed.data(),
                    static_cast<uint32_t>(bd.compressed.size()),
                    blk_out.data(),
                    lw, bhl, stride_bytes);
                if (ret < 0) {
                    ev.pc_decode_ok = false;
                    CLI_LOG_ERR << "PC spot-check decode failed block_index=" << bd.header.block_index()
                                << " ret=" << ret << "\n";
                    break;
                }
            }
            t.pc_ref_ms = steady_ms(t_spot0, std::chrono::steady_clock::now());
        }

        const VerifyVerdict vd = evaluate_verify(ev, VerifyMode::FpgaOnly);
        emit_verify_metrics_line(metrics_sink, metrics_strip, num_blocks, t, true, g_cfg.round_budget_sec,
                                 fpga_crc.decode_status, fpga_crc.done, fpga_crc.word_count,
                                 expected_words_total, vd.tag(), verify_fail_reason_name(vd.reason));
        g_last_verify_timings = t;

        if (verbose) {
            CLI_LOG_OUT << "\nFPGA-only verify: " << vd.tag()
                        << " (" << verify_fail_reason_name(vd.reason) << ")\n";
            CLI_LOG_OUT << "  " << vd.detail << "\n";
            CLI_LOG_OUT << "  expected_words=" << expected_words_total
                        << " fpga_words=" << fpga_crc.word_count
                        << " fpga_crc32=0x" << std::hex << fpga_crc.crc32 << std::dec
                        << " (post-XOR; not compared in --fpga-only mode)\n";
            CLI_LOG_OUT << "  decode_status: " << format_decode_status(fpga_crc.decode_status) << "\n";
        }
        if (g_cfg.emit_json)
            emit_verify_json(path, metrics_strip, num_blocks, t, tp, true, ev, vd);
        return vd.pass ? 0 : 1;
    }

    const auto t_pc0 = std::chrono::steady_clock::now();

    uint32_t pc_word_count = 0;
    uint32_t pc_crc = 0xFFFFFFFFu;
    uint32_t pc_diag_crc[DIAG_CRC_COUNT] = {};
    // Rolling history so the tail checkpoints can be taken once the total is known.
    // Mirrors the crc_hist buffer in rle4k_lan_top_v8.v: hist[j] is the accumulator
    // after word j, and the depth must exceed the largest DIAG_CRC_TAIL_BACK.
    constexpr size_t PC_HIST = 512;
    std::vector<uint32_t> pc_hist(PC_HIST, 0);

    for (const auto& bd : blocks) {
        const uint32_t bh = bd.header.block_height_lines();
        const uint32_t block_decoded_size = stride_bytes * bh;
        std::vector<uint8_t> blk_out(block_decoded_size, 0);

        int ret = rle4k_decode_block(
            bd.compressed.data(),
            static_cast<uint32_t>(bd.compressed.size()),
            blk_out.data(),
            lw, bh, stride_bytes);

        if (ret < 0) {
            CLI_LOG_ERR << "PC decode failed for block " << bd.header.block_index()
                        << " error=" << ret << "\n";
            t.pc_ref_ms = steady_ms(t_pc0, std::chrono::steady_clock::now());
            ev.pc_decode_attempted = true;
            ev.pc_decode_ok = false;
            const VerifyVerdict vd = evaluate_verify(ev, VerifyMode::FullReference);
            emit_verify_metrics_line(metrics_sink, metrics_strip, num_blocks, t, false,
                                     g_cfg.round_budget_sec, fpga_crc.decode_status, fpga_crc.done,
                                     fpga_crc.word_count, expected_words_total,
                                     vd.tag(), verify_fail_reason_name(vd.reason));
            g_last_verify_timings = t;
            if (g_cfg.emit_json)
                emit_verify_json(path, metrics_strip, num_blocks, t, tp, false, ev, vd);
            return 1;
        }

        size_t pos = 0;
        while (pos + 64 <= static_cast<size_t>(ret)) {
            pc_crc = crc32_update(pc_crc, blk_out.data() + pos, 64);
            for (int ci = 0; ci < 5; ++ci) {
                if (pc_word_count == DIAG_CRC_WORD_INDEX[ci])
                    pc_diag_crc[ci] = pc_crc;
            }
            pc_hist[pc_word_count % PC_HIST] = pc_crc;
            pc_word_count++;
            pos += 64;
        }
        if (pos < static_cast<size_t>(ret)) {
            std::array<uint8_t, 64> tail{};
            std::memcpy(tail.data(), blk_out.data() + pos, static_cast<size_t>(ret) - pos);
            pc_crc = crc32_update(pc_crc, tail.data(), 64);
            pc_hist[pc_word_count % PC_HIST] = pc_crc;
            pc_word_count++;
        }
    }

    // Acceptance caliber: post-XOR. crc32_final() applies the final ^0xFFFFFFFF,
    // matching the RTL top which emits crc32_accum ^ 0xFFFFFFFF.
    uint32_t pc_crc_final = crc32_final(pc_crc);

    // The RTL leaves the tail checkpoints at 0 for strips too short to look back.
    for (int ci = 0; ci < 2; ++ci) {
        if (pc_word_count > DIAG_CRC_TAIL_BACK[1])
            pc_diag_crc[5 + ci] =
                pc_hist[(pc_word_count - DIAG_CRC_TAIL_BACK[ci] - 1) % PC_HIST];
    }

    const int diag_n = g_decode_crc_has_tail ? DIAG_CRC_COUNT : 5;
    int step2_match_count = 0;
    int step2_first_fail = -1;
    for (int ci = 0; ci < diag_n; ++ci) {
        const bool m = (fpga_crc.diag_crc[ci] == pc_diag_crc[ci]);
        if (m)
            ++step2_match_count;
        else if (step2_first_fail < 0)
            step2_first_fail = ci;
    }

    ev.have_reference     = true;
    ev.ref_crc32          = pc_crc_final;
    ev.ref_word_count     = pc_word_count;
    ev.diag_match_count   = step2_match_count;
    ev.diag_total_count   = diag_n;
    ev.diag_first_fail    = step2_first_fail;
    ev.pc_decode_attempted = true;
    ev.pc_decode_ok        = true;

    const VerifyVerdict vd = evaluate_verify(ev, VerifyMode::FullReference);
    const bool all_pass = vd.pass;

    // Per-step views kept for the human report below.
    const bool step1_pass = (fpga_crc.word_count == pc_word_count);
    const bool step2_pass = (step2_match_count == diag_n);
    const bool step3_pass = (fpga_crc.done != 0) && (fpga_crc.crc32 == pc_crc_final);

    t.pc_ref_ms = steady_ms(t_pc0, std::chrono::steady_clock::now());

    emit_verify_metrics_line(metrics_sink, metrics_strip, num_blocks, t, false, g_cfg.round_budget_sec,
                             fpga_crc.decode_status, fpga_crc.done, fpga_crc.word_count,
                             expected_words_total, vd.tag(), verify_fail_reason_name(vd.reason));
    g_last_verify_timings = t;
    if (g_cfg.emit_json)
        emit_verify_json(path, metrics_strip, num_blocks, t, tp, false, ev, vd);

    if (!verbose) return all_pass ? 0 : 1;

    // ===================================================================
    //  Three-step verification report
    // ===================================================================
    CLI_LOG_OUT << "\n";
    CLI_LOG_OUT << "============================================================\n";
    CLI_LOG_OUT << "  THREE-STEP VERIFICATION REPORT\n";
    CLI_LOG_OUT << "============================================================\n";

    // --- Step 1: Word Count ---
    CLI_LOG_OUT << "\n[Step 1] Word Count (decoded data volume)\n";
    CLI_LOG_OUT << "  FPGA word_count = " << fpga_crc.word_count << "\n";
    CLI_LOG_OUT << "  PC   word_count = " << pc_word_count << "\n";
    CLI_LOG_OUT << "  Expected bytes  = " << decoded_size
                << " (" << decoded_size / 64 << " words x 64B)\n";
    CLI_LOG_OUT << "  Result: " << (step1_pass ? "PASS" : "FAIL") << "\n";
    if (!step1_pass) {
        int32_t diff = static_cast<int32_t>(fpga_crc.word_count) - static_cast<int32_t>(pc_word_count);
        CLI_LOG_OUT << "  Delta: FPGA has " << (diff > 0 ? "+" : "") << diff << " words\n";
        uint32_t fpga_lines_approx = 0;
        uint32_t words_per_line = (stride_bytes + 63) / 64;
        if (words_per_line > 0)
            fpga_lines_approx = fpga_crc.word_count / words_per_line;
        CLI_LOG_OUT << "  FPGA decoded ~" << fpga_lines_approx << " lines"
                    << " (expected " << total_height << ")\n";
    }

    // --- Step 2: CRC Algorithm + Data Path (5 checkpoint comparison) ---
    CLI_LOG_OUT << "\n[Step 2] CRC Checkpoint Comparison (" << diag_n << " points)\n";
    CLI_LOG_OUT << "  Word#    FPGA CRC     PC CRC       Match\n";
    CLI_LOG_OUT << "  ------   ----------   ----------   -----\n";
    for (int ci = 0; ci < diag_n; ++ci) {
        const bool m = (fpga_crc.diag_crc[ci] == pc_diag_crc[ci]);
        const std::string label =
            ci < 5 ? ("w" + std::to_string(DIAG_CRC_WORD_INDEX[ci]))
                   : ("e-" + std::to_string(DIAG_CRC_TAIL_BACK[ci - 5]));
        CLI_LOG_OUT << "  " << std::setw(6) << std::setfill(' ') << label
                    << "   0x" << std::hex << std::setw(8) << std::setfill('0') << fpga_crc.diag_crc[ci]
                    << "   0x" << std::setw(8) << std::setfill('0') << pc_diag_crc[ci]
                    << std::dec << "   " << (m ? "PASS" : "FAIL") << "\n";
    }
    CLI_LOG_OUT << "  Result: " << step2_match_count << "/" << diag_n << " checkpoints match";
    if (step2_pass) {
        CLI_LOG_OUT << " -> CRC algorithm + data path verified\n";
    } else {
        CLI_LOG_OUT << " -> DIVERGENCE detected!\n";
        if (step2_first_fail >= 0) {
            int prev = step2_first_fail - 1;
            CLI_LOG_OUT << "  Divergence between word "
                        << (prev >= 0 ? DIAG_CRC_WORD_INDEX[prev] : 0)
                        << " and word " << DIAG_CRC_WORD_INDEX[step2_first_fail] << "\n";
        }
    }

    // --- Step 3: Final CRC Result ---
    CLI_LOG_OUT << "\n[Step 3] Final CRC Result (acceptance caliber = post-XOR)\n";
    CLI_LOG_OUT << "  FPGA crc32       = 0x" << std::hex << fpga_crc.crc32 << std::dec << "  (post-XOR)\n";
    CLI_LOG_OUT << "  PC   crc32       = 0x" << std::hex << pc_crc_final << std::dec << "  (post-XOR)\n";
    CLI_LOG_OUT << "  FPGA crc_accum   = 0x" << std::hex << (fpga_crc.crc32 ^ 0xFFFFFFFFu) << std::dec
                << "  (pre-XOR, TB caliber)\n";
    CLI_LOG_OUT << "  PC   crc_accum   = 0x" << std::hex << pc_crc << std::dec
                << "  (pre-XOR, TB caliber)\n";
    CLI_LOG_OUT << "  FPGA done        = " << (int)fpga_crc.done << "\n";
    CLI_LOG_OUT << "  Result: " << (step3_pass ? "PASS" : "FAIL") << "\n";
    if (!step3_pass && step1_pass && step2_pass) {
        CLI_LOG_OUT << "  Analysis: word count OK, CRC algorithm OK, but final CRC differs\n";
        CLI_LOG_OUT << "  -> Decoder produces DIFFERENT data at some word > 0\n";
        CLI_LOG_OUT << "  -> Need more diagnostic checkpoints (word 128, 256, etc.)\n";
    } else if (!step3_pass && !step1_pass) {
        CLI_LOG_OUT << "  Analysis: word count mismatch -> CRC covers different data volume\n";
    }

    // --- Overall ---
    CLI_LOG_OUT << "\n============================================================\n";
    CLI_LOG_OUT << "  OVERALL: " << (all_pass ? "ALL PASS" : "FAIL")
                << "  (" << verify_fail_reason_name(vd.reason) << ")\n";
    CLI_LOG_OUT << "  " << vd.detail << "\n";
    if (!all_pass) {
        CLI_LOG_OUT << "  Step 1 (Word Count):    " << (step1_pass ? "PASS" : "FAIL") << "\n";
        CLI_LOG_OUT << "  Step 2 (CRC Checkpoints): " << step2_match_count << "/" << diag_n << " "
                    << (step2_pass ? "PASS" : "FAIL") << "\n";
        CLI_LOG_OUT << "  Step 3 (CRC Result):    " << (step3_pass ? "PASS" : "FAIL") << "\n";
    }
    CLI_LOG_OUT << "============================================================\n";

    CLI_LOG_OUT << "\nFPGA decode_status: " << format_decode_status(fpga_crc.decode_status) << "\n";
    if (vd.reserved_bits_set)
        CLI_LOG_ERR << "WARNING decode_status[15:13] is nonzero: firmware revision "
                       "does not match this CLI's status contract.\n";

    return all_pass ? 0 : 1;
}

// ---------------------------------------------------------------------------
// verify batch: every strip index in directory (raster_stripN_blockM names)
// ---------------------------------------------------------------------------
static int cmd_verify_batch(const std::string& root, bool fail_fast, int max_strips,
                            size_t max_blocks_per_strip, const std::string& log_path) {
    std::ofstream flog(log_path.c_str(), std::ios::out | std::ios::trunc);
    if (!flog) {
        CLI_LOG_ERR << "Cannot open batch log: " << log_path << "\n";
        return 1;
    }
    const auto wall0 = std::chrono::steady_clock::now();
    auto emit = [&](const std::string& line) {
        flog << line << "\n";
        flog.flush();
        CLI_LOG_OUT << line << "\n";
    };

    emit("V08LAN verify batch");
    emit("log=" + log_path);
    emit("root=" + root + " fail_fast=" + std::string(fail_fast ? "1" : "0") +
         " max_strips=" + std::to_string(max_strips) +
         " max_blocks_per_strip=" + std::to_string(max_blocks_per_strip) +
         " fpga_only=" + std::string(g_cfg.fpga_only ? "1" : "0") +
         " inter_chunk_delay_ms=" + std::to_string(g_cfg.inter_chunk_delay_ms) +
         " target_mbps=" + std::to_string(g_cfg.target_mbps) +
         " block_period_us=" + std::to_string(g_cfg.block_period_us));

    if (!is_directory_path(root)) {
        CLI_LOG_ERR << "Not a directory: " << root << "\n";
        emit("ERROR not_a_directory");
        return 1;
    }

    std::vector<int> strips = BlockReader::list_strip_indices_in_directory(root);
    int64_t sum_prepare_ms = 0, sum_send_ms = 0, sum_fpga_wait_ms = 0, sum_pc_ref_ms = 0;
    if (strips.empty()) {
        emit("NOTE no_strip_tokens_in_filenames running_single_folder_verify");
        int rc = cmd_verify(root, -1, max_blocks_per_strip, false, &flog);
        sum_prepare_ms += g_last_verify_timings.prepare_ms;
        sum_send_ms += g_last_verify_timings.send_ms;
        sum_fpga_wait_ms += g_last_verify_timings.fpga_wait_ms;
        sum_pc_ref_ms += g_last_verify_timings.pc_ref_ms;
        emit(rc == 0 ? "SUMMARY mode=folder PASS" : "SUMMARY mode=folder FAIL rc=" + std::to_string(rc));
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                            std::chrono::steady_clock::now() - wall0).count();
        std::ostringstream sum;
        sum << "BATCH_SUMMARY strips_ran=1 pass=" << (rc == 0 ? 1 : 0) << " fail=" << (rc == 0 ? 0 : 1)
            << " elapsed_ms=" << ms
            << " sum_prepare_ms=" << sum_prepare_ms
            << " sum_send_ms=" << sum_send_ms
            << " sum_fpga_wait_ms=" << sum_fpga_wait_ms
            << " sum_pc_ref_ms=" << sum_pc_ref_ms
            << " fpga_only=" << (g_cfg.fpga_only ? 1 : 0);
        emit(sum.str());
        return rc;
    }

    int ran = 0, passed = 0, failed = 0;
    for (int sid : strips) {
        if (max_strips > 0 && ran >= max_strips) break;

        std::ostringstream pfx;
        pfx << "[strip " << sid << "] ";
        CLI_LOG_OUT << pfx.str() << "quiet verify...\n";

        int rc = cmd_verify(root, sid, max_blocks_per_strip, false, &flog);
        sum_prepare_ms += g_last_verify_timings.prepare_ms;
        sum_send_ms += g_last_verify_timings.send_ms;
        sum_fpga_wait_ms += g_last_verify_timings.fpga_wait_ms;
        sum_pc_ref_ms += g_last_verify_timings.pc_ref_ms;
        ++ran;
        if (rc == 0) {
            ++passed;
            emit(pfx.str() + "PASS");
        } else {
            ++failed;
            emit(pfx.str() + "FAIL rc=" + std::to_string(rc));
            if (fail_fast) {
                CLI_LOG_ERR << pfx.str() << "FAILED — full diagnostic report follows.\n";
                cmd_verify(root, sid, max_blocks_per_strip, true, &flog);
                emit("STOP fail_fast=1");
                break;
            }
        }
    }

    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::steady_clock::now() - wall0).count();
    std::ostringstream sum;
    sum << "BATCH_SUMMARY strips_ran=" << ran << " pass=" << passed << " fail=" << failed
        << " elapsed_ms=" << ms
        << " sum_prepare_ms=" << sum_prepare_ms
        << " sum_send_ms=" << sum_send_ms
        << " sum_fpga_wait_ms=" << sum_fpga_wait_ms
        << " sum_pc_ref_ms=" << sum_pc_ref_ms
        << " fpga_only=" << (g_cfg.fpga_only ? 1 : 0);
    emit(sum.str());
    return failed > 0 ? 1 : 0;
}

// ---------------------------------------------------------------------------
// Usage
// ---------------------------------------------------------------------------
static void print_usage() {
    cli_print_multiline_ts(std::cout, R"(
rle4k_v8 -- RLE4K V08LAN board-level test tool (Raw Ethernet / MAC)

Usage:
  rle4k_v8 [options] <command> [args...]

Commands:
  echo  [count] [size]   Echo test (default: 10 x 32B)
  ping  [count]          Link test (default: 5)
  send file <file>       Send one .rle4k block
  send folder <dir> [-s N] [--max-blocks N]  Send all blocks as stream
  send path <path> [-s N] [--max-blocks N]   Auto-detect file/folder
  verify file <file>     Send + CRC32 verify decode correctness
  verify folder <dir> [-s N] [--max-blocks N] [verify flags...]  Send + CRC32 verify
  verify batch <dir> [--log <path>] [--max-strips N] [--max-blocks N] [--continue|--fail-fast] [verify flags...]
                         Each strip index (from filenames); default log rle4k_v8_batch_*.log
  Verify flags (also in exe-dir rle4k_cli.json under "v8_verify"; CLI overrides JSON):
  --fpga-only            Skip PC reference CRC; PASS needs done=1 and word_count==expected
  --full-verify          Force full PC verify (overrides JSON fpga_only)
  --progress-send-pct N  Send progress every N percent of bytes (0=off)
  --no-decode-progress   Disable FPGA lines/done progress lines
  --round-budget-sec N   WARN if send+fpga_wait exceeds N s (default 600)
  --pc-spot-check N      With --fpga-only: PC-decode first N blocks after FPGA checks
  crc                    Query last decode CRC (GET DECODE_CRC, no stream)
  dog | wdt              Query activity watchdog (GET 0x0601): timeout_count, wdt_counter, threshold ticks
  hardware --version     Query firmware version
  status                 Query decoder status
  reset                  Soft-reset decoder
  list-ifaces            List available network interfaces
  help                   Show this help

Options:
  --iface <name>         Pcap device name (auto-detect if omitted)
  --target-mac <mac>     FPGA MAC (default: 00:0a:35:00:01:02)
  --local-mac <mac>      PC MAC (auto-detect if omitted)
  --timeout <ms>         Receive timeout (default: 2000)
  --bench-max-ms <ms>    STRIP_BENCH max target (default 1000)
  --bench-ideal-ms <ms>  STRIP_BENCH ideal target (default 400)
  --inter-chunk-delay-ms N  Debug pacing between STREAM_DATA frames (DEFAULT 0 = full speed)
  --target-mbps <r>      Optional pace STREAM_DATA to r Mbit/s on the wire
                         (DEFAULT 0 = unpaced / full speed). Prefer FPGA 802.3x
                         PAUSE backpressure for sustainable bulk; use this only
                         to cap host send when debugging. Counts the same bytes
                         as THROUGHPUT wire_Mbps.
  --block-period-us <us> Pace block *starts* to one every us microseconds and send each
                         block as fast as possible (DEFAULT 0 = off). One constant period
                         for every block. Per-block decode time is NOT constant -- it
                         tracks compressed code count -- but a constant period still wins
                         because the RX FIFO lets a slow block borrow the slack left by
                         the fast blocks around it. Combine with --target-mbps to cap the
                         rate inside a block; the receiver needs that cap.
  --block-budget         Give each block its own period, proportional to its predicted
                         decode cycles (DEFAULT off = use --block-period-us instead).
                         Removes the borrowing described above, so every block must be
                         individually safe; measured slower and less repeatable than a
                         constant period. Kept as a measurement tool, not the default.
  --block-margin-pct <p> Margin added to every --block-budget period (DEFAULT 8). Below
                         about 12 the strip stalls outright rather than losing a little
                         data, so do not tune this down casually.
  --block-spread <f>     With --block-period-us, spread each block evenly over f x the
                         period instead of bursting it (DEFAULT 0 = burst). The receiver
                         buffers only a few KB, so a burst is lost long before the period
                         itself becomes the limit. f=1 uses the whole period.
  --no-sendqueue         Send BLOCK_START/STREAM_DATA one pcap_sendpacket per frame
                         instead of batching into pcap_sendqueue (DEFAULT batched for
                         both legacy strip and --parallel). Batching is ~4x faster to
                         the wire; the driver, not the Windows scheduler, honours
                         pacing timestamps. Use this to reproduce pre-batch baselines.
  --sendqueue-chunk-kib N  Override sendqueue alloc size (KiB). DEFAULT auto:
                         paced 1024 / >=200 Mbps 256 / unpaced 4 (safe vs staging
                         PAUSE headroom ~8 KiB on fw>=0x80110).
  --unpaced-gap-us N     After each unpaced sendqueue flush: sleep N us (+ optional
                         PAUSE drain). DEFAULT 0. Set >0 only if debugging FC.
  --full-speed           Force 0 ms pacing (overrides JSON v8_verify.inter_chunk_delay_ms)
  --json                 Also print one machine-readable "JSON {...}" line
  --dry-run              Build and time frames without opening the NIC or sending
  --parallel             K=4 path: STREAM_BLOCK_START before each block.
                         DEFAULT: send-only (no per-block CRC poll). Link integrity =
                         Ethernet FCS + FPGA RX backpressure.
  --parallel-depth <n>   With --verify-block-crc: max in-flight before wave harvest
                         (DEFAULT 1=sync; recommended 4=K; hold capped at W-2).
                         Send-only ignores this (pipelines the whole strip).
                         Depth>1 needs fw>=0x80106 (slot-index GET).
  --parallel-sync        depth=1 wait-each-block CRC (implies --verify-block-crc)
  --verify-block-crc     Opt-in GET(DECODE_BLOCK_CRC) harvest+compare (debug/triage).
                         DEFAULT OFF — not daily acceptance.
  --no-verify-block-crc  Explicit alias: force CRC gate off (same as default).
  --verify-block-crc-every N  With --verify-block-crc: compare bi%%N==0 and last
                         (still wave-harvests all slots before reuse).
  --version              Show CLI version

Verdict (send/verify):
  Non-parallel: PASS needs done=1, word_count == expected, CRC32 == PC reference.
  --parallel (default): send-only; wall/send_only; optional end PARALLEL_INFO.
                         Undercount FAIL; missing GET does not fail. No per-block CRC.
  --parallel --verify-block-crc: per-block CRC (post-XOR) vs PC / --fpga-only words.
  CRC32 acceptance caliber is post-XOR. decode_status[7:0] is informational
  unless decode_status[12] (error_present) is set; 0x07 is a healthy idle value.
)");
}

// ---------------------------------------------------------------------------
static bool parse_int_arg(const std::string& s, int& out) {
    try { out = std::stoi(s); return true; } catch (...) { return false; }
}

int main(int argc, char* argv[]) {
    std::string command;
    std::vector<std::string> cmd_args;
    bool show_version = false, show_help = false;

    AppConfig loaded_cfg;
    if (load_first_existing_app_config(argv[0], loaded_cfg, nullptr))
        merge_app_config_into_g_cfg(loaded_cfg);

    for (int i = 1; i < argc; ++i) {
        std::string a(argv[i]);
        if (a == "--help" || a == "-h") {
            if (command.empty()) show_help = true;
            else cmd_args.push_back(a);
            continue;
        }
        if (a == "--iface" && i+1 < argc) { g_cfg.iface_name = argv[++i]; continue; }
        if (a == "--target-mac" && i+1 < argc) {
            parse_mac(argv[++i], g_cfg.target_mac); continue;
        }
        if (a == "--local-mac" && i+1 < argc) {
            parse_mac(argv[++i], g_cfg.local_mac); continue;
        }
        if (a == "--timeout" && i+1 < argc) {
            g_cfg.timeout_ms = std::stoi(argv[++i]); continue;
        }
        if (a == "--bench-max-ms" && i+1 < argc) {
            g_cfg.bench_target_max_ms = std::stoi(argv[++i]); continue;
        }
        if (a == "--bench-ideal-ms" && i+1 < argc) {
            g_cfg.bench_target_ideal_ms = std::stoi(argv[++i]); continue;
        }
        // Global so `send` and `verify` share them.
        if (a == "--inter-chunk-delay-ms" && i+1 < argc) {
            g_cfg.inter_chunk_delay_ms = std::stoi(argv[++i]); continue;
        }
        if (a == "--target-mbps" && i+1 < argc) {
            g_cfg.target_mbps = std::stod(argv[++i]); continue;
        }
        if (a == "--block-period-us" && i+1 < argc) {
            g_cfg.block_period_us = std::stod(argv[++i]); continue;
        }
        if (a == "--block-spread" && i+1 < argc) {
            g_cfg.block_spread = std::stod(argv[++i]); continue;
        }
        if (a == "--block-budget") { g_cfg.block_budget = true; continue; }
        if (a == "--block-margin-pct" && i+1 < argc) {
            g_cfg.block_margin_pct = std::stod(argv[++i]); continue;
        }
        if (a == "--no-sendqueue") { g_cfg.use_sendqueue = false; continue; }
        if (a == "--sendqueue-chunk-kib" && i + 1 < argc) {
            g_cfg.sendqueue_chunk_kib = std::stoi(argv[++i]); continue;
        }
        if (a == "--unpaced-gap-us" && i + 1 < argc) {
            g_cfg.unpaced_gap_us = std::stoi(argv[++i]); continue;
        }
        if (a == "--full-speed") {
            g_cfg.inter_chunk_delay_ms = 0; g_cfg.target_mbps = 0.0;
            g_cfg.block_period_us = 0.0; g_cfg.block_spread = 0.0;
            g_cfg.block_budget = false;
            continue;
        }
        if (a == "--json") { g_cfg.emit_json = true; continue; }
        if (a == "--dry-run") { g_cfg.dry_run = true; continue; }
        if (a == "--parallel") { g_cfg.parallel = true; continue; }
        if (a == "--parallel-sync") {
            g_cfg.parallel = true;
            g_cfg.parallel_sync = true;
            g_cfg.verify_block_crc = true;
            continue;
        }
        if (a == "--parallel-depth" && i + 1 < argc) {
            g_cfg.parallel = true;
            g_cfg.parallel_depth = std::stoi(argv[++i]);
            continue;
        }
        if (a == "--verify-block-crc") {
            g_cfg.verify_block_crc = true;
            continue;
        }
        if (a == "--no-verify-block-crc") {
            g_cfg.verify_block_crc = false;
            continue;
        }
        if (a == "--verify-block-crc-every" && i + 1 < argc) {
            g_cfg.verify_block_crc = true;
            g_cfg.verify_block_crc_every = std::stoi(argv[++i]);
            continue;
        }
        if (a == "--debug") { g_debug_recv = true; continue; }
        if (a == "--version" || a == "-V") {
            if (command.empty()) show_version = true;
            else cmd_args.push_back(a);
            continue;
        }
        if (command.empty()) command = a;
        else cmd_args.push_back(a);
    }

    if (show_version) { CLI_LOG_OUT << "rle4k_v8 " << kRle4kCliVersion << "\n"; return 0; }
    if (command == "list-ifaces") { list_interfaces(); return 0; }
    if (show_help || command.empty() || command == "help") { print_usage(); return 0; }

    if (!open_pcap()) return 1;

    int rc = 0;
    if (command == "echo") {
        int cnt = 10, sz = 32;
        if (cmd_args.size() > 0) parse_int_arg(cmd_args[0], cnt);
        if (cmd_args.size() > 1) parse_int_arg(cmd_args[1], sz);
        rc = cmd_echo(cnt, sz);
    } else if (command == "ping") {
        int cnt = 5;
        if (!cmd_args.empty()) {
            if ((cmd_args[0] == "-n" || cmd_args[0] == "--count") && cmd_args.size() > 1)
                parse_int_arg(cmd_args[1], cnt);
            else parse_int_arg(cmd_args[0], cnt);
        }
        rc = cmd_ping(cnt);
    } else if (command == "send") {
        if (cmd_args.empty()) {
            CLI_LOG_ERR << "send requires: file|folder|path\n"; rc = 1;
        } else {
            const std::string mode = cmd_args[0];
            if ((mode != "file" && mode != "folder" && mode != "path") || cmd_args.size() < 2) {
                CLI_LOG_ERR << "send <file|folder|path> <path>\n"; rc = 1;
            } else {
                const std::string dp = cmd_args[1];
                int sf = -1; size_t mb = 0;
                for (size_t i = 2; i < cmd_args.size(); ++i) {
                    if ((cmd_args[i] == "-s" || cmd_args[i] == "--strip") && i+1 < cmd_args.size())
                        sf = std::stoi(cmd_args[++i]);
                    else if ((cmd_args[i] == "--max-blocks" || cmd_args[i] == "--max") && i+1 < cmd_args.size())
                        mb = static_cast<size_t>((std::max)(0LL, std::stoll(cmd_args[++i])));
                }
                if (mode == "file" && !is_regular_file_path(dp))
                    { CLI_LOG_ERR << "Not a file: " << dp << "\n"; rc = 1; }
                else if (mode == "folder" && !is_directory_path(dp))
                    { CLI_LOG_ERR << "Not a dir: " << dp << "\n"; rc = 1; }
                else rc = cmd_send(dp, sf, mb);
            }
        }
    } else if (command == "verify") {
        if (cmd_args.empty()) {
            CLI_LOG_ERR << "verify requires: file|folder|batch <path>\n"; rc = 1;
        } else {
            const std::string mode = cmd_args[0];
            if (mode == "batch") {
                if (cmd_args.size() < 2) {
                    CLI_LOG_ERR << "verify batch <dir> [--log <path>] [--max-strips N] [--max-blocks N] [--continue]\n";
                    rc = 1;
                } else if (!is_directory_path(cmd_args[1])) {
                    CLI_LOG_ERR << "Not a dir: " << cmd_args[1] << "\n"; rc = 1;
                } else {
                    bool fail_fast = true;
                    int max_strips = 0;
                    size_t mb = 0;
                    std::string log_path;
                    for (size_t i = 2; i < cmd_args.size(); ++i) {
                        if ((cmd_args[i] == "--log" || cmd_args[i] == "--log-file") && i + 1 < cmd_args.size())
                            log_path = cmd_args[++i];
                        else if (cmd_args[i] == "--continue")
                            fail_fast = false;
                        else if (cmd_args[i] == "--fail-fast")
                            fail_fast = true;
                        else if (cmd_args[i] == "--max-strips" && i + 1 < cmd_args.size())
                            max_strips = std::stoi(cmd_args[++i]);
                        else if ((cmd_args[i] == "--max-blocks" || cmd_args[i] == "--max") && i + 1 < cmd_args.size())
                            mb = static_cast<size_t>((std::max)(0LL, std::stoll(cmd_args[++i])));
                        else if (cmd_args[i] == "--fpga-only")
                            g_cfg.fpga_only = true;
                        else if (cmd_args[i] == "--full-verify")
                            g_cfg.fpga_only = false;
                        else if (cmd_args[i] == "--no-decode-progress")
                            g_cfg.decode_progress = false;
                        else if (cmd_args[i] == "--progress-send-pct" && i + 1 < cmd_args.size())
                            g_cfg.progress_send_pct = std::stoi(cmd_args[++i]);
                        else if (cmd_args[i] == "--round-budget-sec" && i + 1 < cmd_args.size())
                            g_cfg.round_budget_sec = std::stoi(cmd_args[++i]);
                        else if (cmd_args[i] == "--pc-spot-check" && i + 1 < cmd_args.size())
                            g_cfg.pc_spot_check = std::stoi(cmd_args[++i]);
                    }
                    if (log_path.empty()) log_path = default_batch_log_filename();
                    rc = cmd_verify_batch(cmd_args[1], fail_fast, max_strips, mb, log_path);
                }
            } else if ((mode != "file" && mode != "folder") || cmd_args.size() < 2) {
                CLI_LOG_ERR << "verify <file|folder|batch> <path> ...\n"; rc = 1;
            } else {
                const std::string dp = cmd_args[1];
                int sf = -1; size_t mb = 0;
                for (size_t i = 2; i < cmd_args.size(); ++i) {
                    if ((cmd_args[i] == "-s" || cmd_args[i] == "--strip") && i + 1 < cmd_args.size())
                        sf = std::stoi(cmd_args[++i]);
                    else if ((cmd_args[i] == "--max-blocks" || cmd_args[i] == "--max") && i + 1 < cmd_args.size())
                        mb = static_cast<size_t>((std::max)(0LL, std::stoll(cmd_args[++i])));
                    else if (cmd_args[i] == "--fpga-only")
                        g_cfg.fpga_only = true;
                    else if (cmd_args[i] == "--full-verify")
                        g_cfg.fpga_only = false;
                    else if (cmd_args[i] == "--no-decode-progress")
                        g_cfg.decode_progress = false;
                    else if (cmd_args[i] == "--progress-send-pct" && i + 1 < cmd_args.size())
                        g_cfg.progress_send_pct = std::stoi(cmd_args[++i]);
                    else if (cmd_args[i] == "--round-budget-sec" && i + 1 < cmd_args.size())
                        g_cfg.round_budget_sec = std::stoi(cmd_args[++i]);
                    else if (cmd_args[i] == "--pc-spot-check" && i + 1 < cmd_args.size())
                        g_cfg.pc_spot_check = std::stoi(cmd_args[++i]);
                }
                if (mode == "file" && !is_regular_file_path(dp))
                    { CLI_LOG_ERR << "Not a file: " << dp << "\n"; rc = 1; }
                else if (mode == "folder" && !is_directory_path(dp))
                    { CLI_LOG_ERR << "Not a dir: " << dp << "\n"; rc = 1; }
                else rc = cmd_verify(dp, sf, mb, true);
            }
        }
    } else if (command == "status") { rc = cmd_status();
    } else if (command == "crc") {
        DecodeCrcPayload crc{};
        if (query_decode_crc(crc, g_cfg.timeout_ms)) {
            CLI_LOG_OUT << "crc32=0x" << std::hex << crc.crc32 << std::dec
                        << " (post-XOR) words=" << crc.word_count
                        << " done=" << (int)crc.done
                        << " | " << format_decode_status(crc.decode_status) << "\n";
        } else { CLI_LOG_ERR << "No CRC response\n"; rc = 1; }
    } else if (command == "hardware") { rc = cmd_hardware(cmd_args);
    } else if (command == "dog" || command == "wdt") { rc = cmd_dog();
    } else if (command == "reset") { rc = cmd_reset();
    } else if (command == "capture") {
        CLI_LOG_OUT << "Capture: removing BPF filter, listening for ALL frames...\n";
        struct bpf_program fp_empty{};
        if (pcap_compile(g_pcap, &fp_empty, "", 1, PCAP_NETMASK_UNKNOWN) == 0) {
            pcap_setfilter(g_pcap, &fp_empty);
            pcap_freecode(&fp_empty);
        }
        CLI_LOG_OUT << "Sending 1 ping to FPGA...\n";
        raw_send(Cmd::PING, 1, nullptr, 0);
        CLI_LOG_OUT << "Capturing for 5s (up to 20 pkts)...\n";
        auto t0 = std::chrono::steady_clock::now();
        int cnt = 0;
        while (cnt < 20) {
            struct pcap_pkthdr* h = nullptr;
            const uint8_t* p = nullptr;
            int r = pcap_next_ex(g_pcap, &h, &p);
            if (r == 1) {
                cnt++;
                char line[256];
                std::snprintf(line, sizeof(line),
                    "pkt#%d len=%u DA=%02x:%02x:%02x:%02x:%02x:%02x SA=%02x:%02x:%02x:%02x:%02x:%02x ET=%02x%02x",
                    cnt, h->caplen,
                    p[0],p[1],p[2],p[3],p[4],p[5],
                    p[6],p[7],p[8],p[9],p[10],p[11],
                    p[12],p[13]);
                CLI_LOG_OUT << line << "\n";
            }
            auto el = std::chrono::steady_clock::now() - t0;
            if (std::chrono::duration_cast<std::chrono::milliseconds>(el).count() >= 5000) break;
        }
        CLI_LOG_OUT << "Captured " << cnt << " frames.\n";
        rc = 0;
    } else {
        CLI_LOG_ERR << "Unknown command: " << command << "\n";
        print_usage(); rc = 1;
    }

    close_pcap();
    return rc;
}
