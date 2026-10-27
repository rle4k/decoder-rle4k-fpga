// ============================================================================
// diag_decode -- Standalone stub decode + CRC32 verification (no FPGA needed)
// ============================================================================
// Reads .rle4k block files, decodes with rle4k_decode_block(), computes CRC32
// over 64-byte (512-bit) words, and prints intermediate CRC at key points.
// This tool verifies the C++ decode+CRC pipeline independently of the FPGA.
// ============================================================================

#ifndef DISALBE_RLE4K_LIB
#define DISALBE_RLE4K_LIB
#endif
#include "rle4k.h"
#include "block_reader.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>
#include <array>
#include <algorithm>

#ifdef _WIN32
#include <windows.h>
#endif

using namespace rle4k;

// ---------------------------------------------------------------------------
// CRC32 (same algorithm as main CLI and FPGA)
// ---------------------------------------------------------------------------
static uint32_t crc32_table[256];
static bool crc32_table_ready = false;

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
// Hex dump helper
// ---------------------------------------------------------------------------
static void hex_dump(const char* label, const uint8_t* data, size_t len) {
    printf("  %s: ", label);
    for (size_t i = 0; i < len && i < 16; ++i)
        printf("%02x", data[i]);
    if (len > 16) printf("...");
    printf("\n");
}

// ---------------------------------------------------------------------------
// File/dir helpers
// ---------------------------------------------------------------------------
static bool is_directory_path(const std::string& p) {
#ifdef _WIN32
    DWORD attr = GetFileAttributesA(p.c_str());
    return (attr != INVALID_FILE_ATTRIBUTES) && (attr & FILE_ATTRIBUTE_DIRECTORY);
#else
    return false;
#endif
}

static bool is_regular_file_path(const std::string& p) {
#ifdef _WIN32
    DWORD attr = GetFileAttributesA(p.c_str());
    return (attr != INVALID_FILE_ATTRIBUTES) && !(attr & FILE_ATTRIBUTE_DIRECTORY);
#else
    return false;
#endif
}

// ---------------------------------------------------------------------------
// FPGA-style CRC32 reference: byte-by-byte, matching Verilog crc32_byte()
// ---------------------------------------------------------------------------
static uint32_t fpga_crc32_byte(uint32_t prev, uint8_t b) {
    uint32_t c = prev ^ static_cast<uint32_t>(b);
    for (int i = 0; i < 8; ++i)
        c = (c & 1) ? ((c >> 1) ^ 0xEDB88320u) : (c >> 1);
    return c;
}

static uint32_t fpga_crc32_word(uint32_t prev, const uint8_t* word64) {
    uint32_t c = prev;
    for (int j = 0; j < 64; ++j)
        c = fpga_crc32_byte(c, word64[j]);
    return c;
}

// ---------------------------------------------------------------------------
// Main: stub decode + CRC
// ---------------------------------------------------------------------------
int main(int argc, char* argv[]) {
    if (argc < 2) {
        fprintf(stderr,
            "Usage: diag_decode <file_or_dir> [--max-blocks N] [-s strip]\n"
            "\n"
            "Standalone decode + CRC32 verification (no FPGA needed).\n"
            "Reads .rle4k blocks, decodes, computes CRC32, prints diagnostics.\n");
        return 1;
    }

    std::string path = argv[1];
    size_t max_blocks = 0;
    int strip_filter = -1;

    for (int i = 2; i < argc; ++i) {
        std::string a(argv[i]);
        if ((a == "--max-blocks" || a == "--max") && i + 1 < argc)
            max_blocks = static_cast<size_t>(std::atoi(argv[++i]));
        else if ((a == "-s" || a == "--strip") && i + 1 < argc)
            strip_filter = std::atoi(argv[++i]);
    }

    // 1. Read blocks
    std::vector<BlockData> blocks;
    if (is_directory_path(path))
        blocks = BlockReader::read_directory(path, max_blocks, strip_filter);
    else if (is_regular_file_path(path)) {
        BlockData bd;
        if (!BlockReader::read_block(path, bd)) {
            fprintf(stderr, "Cannot read: %s\n", path.c_str());
            return 1;
        }
        blocks.push_back(std::move(bd));
    } else {
        fprintf(stderr, "Not a file or directory: %s\n", path.c_str());
        return 1;
    }

    if (blocks.empty()) {
        fprintf(stderr, "No block files found.\n");
        return 1;
    }

    // 2. Print block info
    uint32_t total_height = 0;
    uint64_t total_compressed = 0;
    for (const auto& bd : blocks) {
        total_height += bd.header.block_height_lines();
        total_compressed += bd.compressed.size();
    }

    const auto& first = blocks.front();
    const uint32_t lw = first.header.line_width_bits();
    const uint32_t ls = first.header.line_stride_bits();
    const uint32_t stride_bytes = (ls + 7) / 8;

    printf("=== diag_decode: Stub Decode + CRC32 ===\n");
    printf("Blocks:     %zu\n", blocks.size());
    printf("Width:      %u bits\n", lw);
    printf("Stride:     %u bits (%u bytes)\n", ls, stride_bytes);
    printf("Height:     %u lines (total across blocks)\n", total_height);
    printf("Compressed: %llu bytes (total)\n", (unsigned long long)total_compressed);
    printf("Expected decoded: %u bytes = %u words (64B each)\n",
           stride_bytes * total_height,
           (stride_bytes * total_height + 63) / 64);
    printf("\n");

    // 3. Compressed data dump (first 32 bytes)
    printf("--- Compressed data (first block, first 32 bytes) ---\n");
    const auto& b0 = blocks[0];
    printf("  ");
    for (size_t i = 0; i < 32 && i < b0.compressed.size(); ++i)
        printf("%02X ", b0.compressed[i]);
    printf("\n\n");

    // 4. Decode each block and compute CRC
    uint32_t pc_word_count = 0;
    uint32_t crc_table_method = 0xFFFFFFFFu;
    uint32_t crc_fpga_method  = 0xFFFFFFFFu;
    uint32_t words_per_line = (stride_bytes + 63) / 64;

    printf("--- Decode + CRC32 per-block ---\n");

    for (size_t bi = 0; bi < blocks.size(); ++bi) {
        const auto& bd = blocks[bi];
        const uint32_t bh = bd.header.block_height_lines();
        const uint32_t block_decoded_size = stride_bytes * bh;
        std::vector<uint8_t> blk_out(block_decoded_size, 0);

        int ret = rle4k_decode_block(
            bd.compressed.data(),
            static_cast<uint32_t>(bd.compressed.size()),
            blk_out.data(),
            lw, bh, stride_bytes);

        printf("Block[%zu] '%s': height=%u compressed=%zu ret=%d\n",
               bi, bd.filename.c_str(), bh,
               bd.compressed.size(), ret);

        if (ret < 0) {
            fprintf(stderr, "  DECODE FAILED (error=%d)\n", ret);
            return 1;
        }

        // CRC32 over decoded output, 64-byte words
        size_t pos = 0;
        uint32_t block_word_start = pc_word_count;
        while (pos + 64 <= static_cast<size_t>(ret)) {
            uint32_t prev_table = crc_table_method;
            uint32_t prev_fpga  = crc_fpga_method;

            crc_table_method = crc32_update(crc_table_method, blk_out.data() + pos, 64);
            crc_fpga_method  = fpga_crc32_word(crc_fpga_method, blk_out.data() + pos);
            pc_word_count++;

            // Print at key word indices
            uint32_t wi = pc_word_count - 1; // 0-based word index
            uint32_t line_in_block = (pc_word_count - block_word_start - 1) / words_per_line;
            uint32_t word_in_line  = (pc_word_count - block_word_start - 1) % words_per_line;

            bool print_it = (wi < 4)
                || (wi == 8) || (wi == 9)
                || (wi == words_per_line - 1)
                || (wi == words_per_line)
                || (wi == 2 * words_per_line - 1)
                || (wi == 2 * words_per_line)
                || (pc_word_count == (stride_bytes * total_height) / 64);

            if (print_it) {
                printf("  word[%5u] L%u:W%3u  tbl=0x%08x fpga=0x%08x %s  d[0..7]=",
                       wi, line_in_block, word_in_line,
                       crc_table_method, crc_fpga_method,
                       (crc_table_method == crc_fpga_method) ? "OK" : "MISMATCH!");
                for (int di = 0; di < 8; ++di)
                    printf("%02x", blk_out[pos + di]);
                printf("\n");
            }
            pos += 64;
        }

        // Handle partial last word (pad to 64 bytes)
        if (pos < static_cast<size_t>(ret)) {
            std::array<uint8_t, 64> tail{};
            std::memcpy(tail.data(), blk_out.data() + pos, static_cast<size_t>(ret) - pos);
            crc_table_method = crc32_update(crc_table_method, tail.data(), 64);
            crc_fpga_method  = fpga_crc32_word(crc_fpga_method, tail.data());
            pc_word_count++;
            printf("  word[%5u] (partial %zu bytes) tbl=0x%08x fpga=0x%08x\n",
                   pc_word_count - 1, static_cast<size_t>(ret) - pos,
                   crc_table_method, crc_fpga_method);
        }

        printf("  Block[%zu] words=%u cumulative_crc_accum=0x%08x\n\n",
               bi, pc_word_count - block_word_start, crc_table_method);
    }

    // 5. Final results
    uint32_t final_crc_table = crc32_final(crc_table_method);
    uint32_t final_crc_fpga  = crc_fpga_method ^ 0xFFFFFFFFu;

    printf("=== FINAL RESULTS ===\n");
    printf("Total words:    %u\n", pc_word_count);
    printf("CRC32 (table):  0x%08x (accum=0x%08x)\n", final_crc_table, crc_table_method);
    printf("CRC32 (fpga):   0x%08x (accum=0x%08x)\n", final_crc_fpga, crc_fpga_method);
    printf("Table vs FPGA:  %s\n",
           (final_crc_table == final_crc_fpga) ? "MATCH" : "MISMATCH!");

    // 6. Verify data pattern at transition points
    if (blocks.size() == 1 && blocks[0].header.block_height_lines() > 0) {
        const auto& bd = blocks[0];
        const uint32_t bh = bd.header.block_height_lines();
        std::vector<uint8_t> blk_out(stride_bytes * bh, 0);
        rle4k_decode_block(bd.compressed.data(),
            static_cast<uint32_t>(bd.compressed.size()),
            blk_out.data(), lw, bh, stride_bytes);

        printf("\n--- Data pattern check (line 0) ---\n");
        // Find first non-zero byte
        uint32_t first_nonzero = stride_bytes;
        for (uint32_t i = 0; i < stride_bytes; ++i) {
            if (blk_out[i] != 0x00) { first_nonzero = i; break; }
        }
        // Find first non-0xFF byte after the transition
        uint32_t first_non_ff = stride_bytes;
        for (uint32_t i = first_nonzero; i < stride_bytes; ++i) {
            if (blk_out[i] != 0xFF) { first_non_ff = i; break; }
        }
        printf("  Line 0: zeros[0..%u] ones[%u..%u] total=%u bytes\n",
               first_nonzero > 0 ? first_nonzero - 1 : 0,
               first_nonzero, first_non_ff > 0 ? first_non_ff - 1 : 0,
               stride_bytes);
        printf("  Transition at byte %u (word %u, byte-in-word %u)\n",
               first_nonzero, first_nonzero / 64, first_nonzero % 64);

        // Dump around transition
        if (first_nonzero > 0 && first_nonzero < stride_bytes) {
            uint32_t start = (first_nonzero > 4) ? first_nonzero - 4 : 0;
            uint32_t end = (std::min)(first_nonzero + 4, stride_bytes);
            printf("  Bytes around transition [%u..%u]: ", start, end - 1);
            for (uint32_t i = start; i < end; ++i)
                printf("%02x ", blk_out[i]);
            printf("\n");
        }

        // Verify all lines are identical
        bool all_same = true;
        for (uint32_t line = 1; line < bh; ++line) {
            if (memcmp(blk_out.data(), blk_out.data() + line * stride_bytes, stride_bytes) != 0) {
                all_same = false;
                printf("  WARNING: Line %u differs from line 0!\n", line);
                // Find first difference
                for (uint32_t i = 0; i < stride_bytes; ++i) {
                    if (blk_out[i] != blk_out[line * stride_bytes + i]) {
                        printf("  First diff at byte %u: line0=0x%02x line%u=0x%02x\n",
                               i, blk_out[i], line, blk_out[line * stride_bytes + i]);
                        break;
                    }
                }
                break;
            }
        }
        if (all_same)
            printf("  All %u lines are identical. OK\n", bh);
    }

    printf("\n=== DONE ===\n");
    return 0;
}
