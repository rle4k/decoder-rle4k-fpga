// ============================================================================
// pc_reference -- offline PC reference decode + CRC32 (post-XOR acceptance)
// ============================================================================
// No Npcap, no board. Computes exactly the CRC32 the FPGA is expected to report
// for a strip, in the *acceptance caliber* (post-XOR), and optionally round-trips
// the decoded image back through rle4k_encode_block() to exercise the encoder.
//
//   pc_reference <file_or_dir> [-s N] [--max-blocks N] [--expect-crc 0xf87c04d1]
//                              [--expect-words 98688] [--roundtrip] [--json]
//
// Exit code 0 when every requested expectation matches.
// ============================================================================

#ifndef DISALBE_RLE4K_LIB
#define DISALBE_RLE4K_LIB
#endif

#include "rle4k.h"
#include "block_reader.h"

#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <sys/stat.h>

using namespace rle4k;

// --- CRC32: reflected, poly 0xEDB88320, init 0xFFFFFFFF, final XOR 0xFFFFFFFF -
static uint32_t g_crc_table[256];
static bool     g_crc_table_ready = false;

static void crc32_init_table() {
    if (g_crc_table_ready) return;
    for (uint32_t i = 0; i < 256; ++i) {
        uint32_t c = i;
        for (int j = 0; j < 8; ++j)
            c = (c & 1) ? (c >> 1) ^ 0xEDB88320u : (c >> 1);
        g_crc_table[i] = c;
    }
    g_crc_table_ready = true;
}

static uint32_t crc32_update(uint32_t crc, const uint8_t* data, size_t len) {
    crc32_init_table();
    for (size_t i = 0; i < len; ++i)
        crc = g_crc_table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    return crc;
}

static bool is_dir(const std::string& p) {
    struct _stat st{}; return (_stat(p.c_str(), &st) == 0) && (st.st_mode & _S_IFDIR);
}
static bool is_file(const std::string& p) {
    struct _stat st{}; return (_stat(p.c_str(), &st) == 0) && (st.st_mode & _S_IFREG);
}

static bool parse_u32(const char* s, uint32_t& out) {
    char* end = nullptr;
    const unsigned long long v = std::strtoull(s, &end, 0);
    if (end == s || v > 0xFFFFFFFFull) return false;
    out = static_cast<uint32_t>(v);
    return true;
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::fprintf(stderr,
            "Usage: pc_reference <file_or_dir> [options]\n"
            "\n"
            "Offline PC reference decode + CRC32 (post-XOR acceptance caliber).\n"
            "No Npcap, no board.\n"
            "\n"
            "Options:\n"
            "  -s, --strip N        Only blocks of strip N\n"
            "  --max-blocks N       Limit block count\n"
            "  --expect-crc V       Fail unless post-XOR CRC32 == V\n"
            "  --expect-words N     Fail unless decoded word count == N\n"
            "  --roundtrip          Re-encode the decoded image and decode again\n"
            "  --json               Emit a single JSON object\n");
        return 2;
    }

    std::string path = argv[1];
    int      strip_filter = -1;
    size_t   max_blocks   = 0;
    uint32_t expect_crc   = 0;   bool have_expect_crc   = false;
    uint32_t expect_words = 0;   bool have_expect_words = false;
    bool     roundtrip    = false;
    bool     json         = false;

    for (int i = 2; i < argc; ++i) {
        const std::string a(argv[i]);
        if ((a == "-s" || a == "--strip") && i + 1 < argc) strip_filter = std::atoi(argv[++i]);
        else if ((a == "--max-blocks" || a == "--max") && i + 1 < argc)
            max_blocks = static_cast<size_t>(std::atoll(argv[++i]));
        else if (a == "--expect-crc" && i + 1 < argc)
            have_expect_crc = parse_u32(argv[++i], expect_crc);
        else if (a == "--expect-words" && i + 1 < argc)
            have_expect_words = parse_u32(argv[++i], expect_words);
        else if (a == "--roundtrip") roundtrip = true;
        else if (a == "--json") json = true;
        else { std::fprintf(stderr, "Unknown option: %s\n", a.c_str()); return 2; }
    }

    std::vector<BlockData> blocks;
    if (is_dir(path)) {
        blocks = BlockReader::read_directory(path, max_blocks, strip_filter);
    } else if (is_file(path)) {
        BlockData bd;
        if (!BlockReader::read_block(path, bd)) {
            std::fprintf(stderr, "Cannot read: %s\n", path.c_str());
            return 1;
        }
        blocks.push_back(std::move(bd));
    } else {
        std::fprintf(stderr, "Not a file or directory: %s\n", path.c_str());
        return 1;
    }
    if (blocks.empty()) {
        std::fprintf(stderr, "No block files found in: %s\n", path.c_str());
        return 1;
    }

    const auto& first = blocks.front();
    const uint32_t lw = first.header.line_width_bits();
    const uint32_t ls = first.header.line_stride_bits();
    const uint32_t stride_bytes = (ls + 7) / 8;

    uint32_t total_height = 0;
    uint64_t total_compressed = 0;
    for (const auto& bd : blocks) {
        total_height += bd.header.block_height_lines();
        total_compressed += bd.compressed.size();
    }

    const auto t0 = std::chrono::steady_clock::now();

    uint32_t crc_accum = 0xFFFFFFFFu;   // pre-XOR accumulator (TB caliber)
    uint32_t word_count = 0;
    bool     decode_ok = true;
    bool     roundtrip_ok = true;
    int      roundtrip_blocks = 0;

    for (const auto& bd : blocks) {
        const uint32_t bh = bd.header.block_height_lines();
        std::vector<uint8_t> out(static_cast<size_t>(stride_bytes) * bh, 0);

        const int ret = rle4k_decode_block(
            bd.compressed.data(), static_cast<uint32_t>(bd.compressed.size()),
            out.data(), lw, bh, stride_bytes);
        if (ret < 0) {
            std::fprintf(stderr, "decode failed: block=%u file=%s ret=%d\n",
                         bd.header.block_index(), bd.filename.c_str(), ret);
            decode_ok = false;
            break;
        }

        size_t pos = 0;
        while (pos + 64 <= static_cast<size_t>(ret)) {
            crc_accum = crc32_update(crc_accum, out.data() + pos, 64);
            ++word_count;
            pos += 64;
        }
        if (pos < static_cast<size_t>(ret)) {
            std::array<uint8_t, 64> tail{};
            std::memcpy(tail.data(), out.data() + pos, static_cast<size_t>(ret) - pos);
            crc_accum = crc32_update(crc_accum, tail.data(), 64);
            ++word_count;
        }

        if (roundtrip) {
            // Encoder exercise: decoded image -> encode -> decode -> must match.
            std::vector<uint8_t> enc(static_cast<size_t>(ret) + (static_cast<size_t>(ret) / 2) + 1024, 0);
            const int elen = rle4k_encode_block(out.data(), bh, lw, enc.data(), stride_bytes,
                                                static_cast<uint32_t>(enc.size()));
            if (elen < 0) {
                std::fprintf(stderr, "encode failed: block=%u ret=%d\n",
                             bd.header.block_index(), elen);
                roundtrip_ok = false;
            } else {
                std::vector<uint8_t> back(static_cast<size_t>(ret), 0);
                const int dlen = rle4k_decode_block(enc.data(), static_cast<uint32_t>(elen),
                                                    back.data(), lw, bh, stride_bytes);
                if (dlen != ret || std::memcmp(back.data(), out.data(), static_cast<size_t>(ret)) != 0) {
                    std::fprintf(stderr, "roundtrip mismatch: block=%u dlen=%d ret=%d\n",
                                 bd.header.block_index(), dlen, ret);
                    roundtrip_ok = false;
                } else {
                    ++roundtrip_blocks;
                }
            }
        }
    }

    const double elapsed_ms =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();

    const uint32_t crc_post_xor = crc_accum ^ 0xFFFFFFFFu;

    const bool crc_match   = !have_expect_crc   || (crc_post_xor == expect_crc);
    const bool words_match = !have_expect_words || (word_count == expect_words);
    const bool overall = decode_ok && roundtrip_ok && crc_match && words_match;

    if (json) {
        std::printf("{");
        std::printf("\"path\":\"");
        for (char c : path) { if (c == '\\') std::printf("\\\\"); else std::printf("%c", c); }
        std::printf("\",");
        std::printf("\"blocks\":%zu,", blocks.size());
        std::printf("\"width_bits\":%u,\"stride_bits\":%u,\"stride_bytes\":%u,", lw, ls, stride_bytes);
        std::printf("\"total_height\":%u,", total_height);
        std::printf("\"compressed_bytes\":%llu,", (unsigned long long)total_compressed);
        std::printf("\"decoded_bytes\":%llu,",
                    (unsigned long long)stride_bytes * total_height);
        std::printf("\"word_count\":%u,", word_count);
        std::printf("\"crc32_post_xor\":\"0x%08x\",", crc_post_xor);
        std::printf("\"crc32_accum_pre_xor\":\"0x%08x\",", crc_accum);
        std::printf("\"decode_ok\":%s,", decode_ok ? "true" : "false");
        std::printf("\"roundtrip\":%s,", roundtrip ? "true" : "false");
        std::printf("\"roundtrip_ok\":%s,", roundtrip_ok ? "true" : "false");
        std::printf("\"roundtrip_blocks\":%d,", roundtrip_blocks);
        if (have_expect_crc)
            std::printf("\"expect_crc32_post_xor\":\"0x%08x\",\"crc_match\":%s,",
                        expect_crc, crc_match ? "true" : "false");
        if (have_expect_words)
            std::printf("\"expect_words\":%u,\"words_match\":%s,",
                        expect_words, words_match ? "true" : "false");
        std::printf("\"elapsed_ms\":%.3f,", elapsed_ms);
        std::printf("\"result\":\"%s\"}\n", overall ? "PASS" : "FAIL");
    } else {
        std::printf("=== pc_reference (offline, post-XOR acceptance caliber) ===\n");
        std::printf("path             : %s\n", path.c_str());
        std::printf("blocks           : %zu\n", blocks.size());
        std::printf("width / stride   : %u bits / %u bits (%u bytes)\n", lw, ls, stride_bytes);
        std::printf("total height     : %u lines\n", total_height);
        std::printf("compressed       : %llu bytes\n", (unsigned long long)total_compressed);
        std::printf("decoded          : %llu bytes\n",
                    (unsigned long long)stride_bytes * total_height);
        std::printf("word_count       : %u (64B words)\n", word_count);
        std::printf("CRC32 post-XOR   : 0x%08x   <-- acceptance value\n", crc_post_xor);
        std::printf("CRC32 accum      : 0x%08x   (pre-XOR, TB caliber)\n", crc_accum);
        std::printf("decode_ok        : %s\n", decode_ok ? "yes" : "NO");
        if (roundtrip)
            std::printf("encoder roundtrip: %s (%d/%zu blocks bit-exact)\n",
                        roundtrip_ok ? "OK" : "MISMATCH", roundtrip_blocks, blocks.size());
        if (have_expect_crc)
            std::printf("expect CRC       : 0x%08x -> %s\n", expect_crc, crc_match ? "MATCH" : "MISMATCH");
        if (have_expect_words)
            std::printf("expect words     : %u -> %s\n", expect_words, words_match ? "MATCH" : "MISMATCH");
        std::printf("elapsed_ms       : %.3f\n", elapsed_ms);
        std::printf("RESULT           : %s\n", overall ? "PASS" : "FAIL");
    }

    return overall ? 0 : 1;
}
