// gen_sim_data -- Generate simulation stimulus and reference CRC
// Reads N .rle4k block files, builds a strip stream, exports:
//   1. stream_data.hex   -- 32-bit words (compressed stream for FPGA decoder input)
//   2. sim_config.txt    -- block/strip configuration parameters
//   3. ref_crc.txt       -- PC reference CRC for each block and final strip CRC
//   4. block_heights.hex -- block heights for testbench $readmemh

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

#ifdef _WIN32
#include <windows.h>
#endif

using namespace rle4k;

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

int main(int argc, char* argv[]) {
    if (argc < 3) {
        fprintf(stderr,
            "Usage:\n"
            "  gen_sim_data <block0.rle4k> [block1.rle4k ...] <output_dir>\n"
            "  gen_sim_data --folder <dir> [--max-blocks N] [--strip N] <output_dir>\n"
            "\n"
            "  Last argument is the output directory.\n"
            "  Folder mode selects blocks through the same BlockReader::read_directory\n"
            "  call that 'rle4k_v8 verify folder --max-blocks N' uses, so the stimulus\n"
            "  it writes is the same strip the board was sent. That is what makes a\n"
            "  board-only failure reproducible in simulation.\n");
        return 1;
    }

    std::vector<BlockData> blocks;
    std::string outdir = argv[argc - 1];

    if (std::strcmp(argv[1], "--folder") == 0) {
        if (argc < 4) {
            fprintf(stderr, "--folder needs a directory and an output directory\n");
            return 1;
        }
        std::string dir = argv[2];
        size_t max_blocks = 0;
        int strip_index = -1;
        for (int i = 3; i < argc - 1; ++i) {
            if (std::strcmp(argv[i], "--max-blocks") == 0 && i + 1 < argc - 1)
                max_blocks = static_cast<size_t>(std::atoi(argv[++i]));
            else if (std::strcmp(argv[i], "--strip") == 0 && i + 1 < argc - 1)
                strip_index = std::atoi(argv[++i]);
            else {
                fprintf(stderr, "Unknown option: %s\n", argv[i]);
                return 1;
            }
        }
        blocks = BlockReader::read_directory(dir, max_blocks, strip_index);
        if (blocks.empty()) {
            fprintf(stderr, "No blocks read from: %s\n", dir.c_str());
            return 1;
        }
        printf("Folder mode: %s (max_blocks=%zu, strip=%d)\n",
               dir.c_str(), max_blocks, strip_index);
    } else {
        int n = argc - 2;
        blocks.resize(n);
        for (int bi = 0; bi < n; ++bi) {
            if (!BlockReader::read_block(argv[bi + 1], blocks[bi])) {
                fprintf(stderr, "Cannot read: %s\n", argv[bi + 1]);
                return 1;
            }
        }
    }

    const int nblocks = static_cast<int>(blocks.size());

    const auto& first = blocks[0];
    const uint32_t lw = first.header.line_width_bits();
    const uint32_t ls = first.header.line_stride_bits();
    const uint32_t stride_bytes = (ls + 7) / 8;

    uint32_t total_height = 0;
    for (const auto& bd : blocks)
        total_height += bd.header.block_height_lines();

    printf("Strip: %d blocks, total height=%u lines\n", nblocks, total_height);
    printf("Width=%u bits, Stride=%u bits (%u bytes)\n", lw, ls, stride_bytes);
    for (int bi = 0; bi < nblocks; ++bi)
        printf("  Block %d: height=%u compressed=%zu '%s'\n",
               bi, blocks[bi].header.block_height_lines(),
               blocks[bi].compressed.size(), blocks[bi].filename.c_str());

    // V1.0 cfg delimiters: concatenate compressed payloads only (no in-band 0xC0/0x80).
    // Match CLI main_cli_v8 strip assembly; pad 0..3 zero bytes for 32-bit wire align.
    std::vector<uint8_t> stream;
    for (int bi = 0; bi < nblocks; ++bi) {
        stream.insert(stream.end(), blocks[bi].compressed.begin(), blocks[bi].compressed.end());
    }
    while (stream.size() % 4 != 0)
        stream.push_back(0x00);

    printf("Strip stream: %zu bytes (%zu 32-bit words)\n", stream.size(), stream.size() / 4);

    // 1. Export stream_data.hex
    {
        std::string path = outdir + "/stream_data.hex";
        FILE* fp = fopen(path.c_str(), "w");
        if (!fp) { fprintf(stderr, "Cannot write %s\n", path.c_str()); return 1; }
        for (size_t i = 0; i < stream.size(); i += 4) {
            uint32_t w = 0;
            for (int b = 0; b < 4 && (i + b) < stream.size(); ++b)
                w |= static_cast<uint32_t>(stream[i + b]) << (b * 8);
            fprintf(fp, "%08x\n", w);
        }
        fclose(fp);
        printf("Wrote: %s (%zu words)\n", path.c_str(), stream.size() / 4);
    }

    // 2. Export block_heights.hex (one 32-bit height per line, for $readmemh)
    {
        std::string path = outdir + "/block_heights.hex";
        FILE* fp = fopen(path.c_str(), "w");
        if (!fp) { fprintf(stderr, "Cannot write %s\n", path.c_str()); return 1; }
        for (int bi = 0; bi < nblocks; ++bi)
            fprintf(fp, "%08x\n", blocks[bi].header.block_height_lines());
        fclose(fp);
        printf("Wrote: %s\n", path.c_str());
    }

    // 3. PC decode + CRC
    uint32_t pc_word_count = 0;
    uint32_t crc_accum = 0xFFFFFFFFu;
    std::vector<uint32_t> block_end_crc(nblocks);
    std::vector<uint32_t> block_end_words(nblocks);

    for (int bi = 0; bi < nblocks; ++bi) {
        const auto& bd = blocks[bi];
        const uint32_t bh = bd.header.block_height_lines();
        std::vector<uint8_t> decoded(stride_bytes * bh, 0);
        int ret = rle4k_decode_block(
            bd.compressed.data(),
            static_cast<uint32_t>(bd.compressed.size()),
            decoded.data(), lw, bh, stride_bytes);

        if (ret < 0) {
            fprintf(stderr, "PC decode failed block %d, error=%d\n", bi, ret);
            return 1;
        }

        size_t pos = 0;
        while (pos + 64 <= static_cast<size_t>(ret)) {
            crc_accum = crc32_update(crc_accum, decoded.data() + pos, 64);
            pc_word_count++;
            pos += 64;
        }
        if (pos < static_cast<size_t>(ret)) {
            std::array<uint8_t, 64> tail{};
            std::memcpy(tail.data(), decoded.data() + pos, static_cast<size_t>(ret) - pos);
            crc_accum = crc32_update(crc_accum, tail.data(), 64);
            pc_word_count++;
        }
        block_end_crc[bi] = crc_accum;
        block_end_words[bi] = pc_word_count;
        printf("Block %d: decoded=%d bytes, cumul_words=%u, crc_accum=0x%08x\n",
               bi, ret, pc_word_count, crc_accum);
    }

    uint32_t final_crc = crc_accum ^ 0xFFFFFFFFu;
    printf("\nFinal: total_words=%u, crc32=0x%08x, crc_accum=0x%08x\n",
           pc_word_count, final_crc, crc_accum);

    // 4. Export sim_config.txt
    {
        std::string path = outdir + "/sim_config.txt";
        FILE* fp = fopen(path.c_str(), "w");
        if (!fp) { fprintf(stderr, "Cannot write %s\n", path.c_str()); return 1; }
        fprintf(fp, "LINE_WIDTH %u\n", lw);
        fprintf(fp, "LINE_STRIDE %u\n", ls);
        fprintf(fp, "TOTAL_HEIGHT %u\n", total_height);
        fprintf(fp, "STREAM_WORDS %zu\n", stream.size() / 4);
        fprintf(fp, "BLOCK_COUNT %d\n", nblocks);
        for (int bi = 0; bi < nblocks; ++bi) {
            fprintf(fp, "BLOCK%d_HEIGHT %u\n", bi, blocks[bi].header.block_height_lines());
            fprintf(fp, "BLOCK%d_COMPRESSED %zu\n", bi, blocks[bi].compressed.size());
        }
        fprintf(fp, "STRIDE_BYTES %u\n", stride_bytes);
        fprintf(fp, "TOTAL_WORDS %u\n", pc_word_count);
        fprintf(fp, "CRC32_FINAL 0x%08x\n", final_crc);
        fprintf(fp, "CRC32_ACCUM 0x%08x\n", crc_accum);
        fclose(fp);
        printf("Wrote: %s\n", path.c_str());
    }

    // 5. Export ref_crc.txt
    {
        std::string path = outdir + "/ref_crc.txt";
        FILE* fp = fopen(path.c_str(), "w");
        if (!fp) { fprintf(stderr, "Cannot write %s\n", path.c_str()); return 1; }
        fprintf(fp, "TOTAL_WORDS %u\n", pc_word_count);
        fprintf(fp, "CRC32_FINAL 0x%08x\n", final_crc);
        fprintf(fp, "CRC32_ACCUM 0x%08x\n", crc_accum);
        fprintf(fp, "BLOCK_COUNT %d\n", nblocks);
        for (int bi = 0; bi < nblocks; ++bi) {
            uint32_t bw = (bi > 0) ? block_end_words[bi] - block_end_words[bi-1] : block_end_words[bi];
            fprintf(fp, "BLOCK%d_WORDS %u\n", bi, bw);
            fprintf(fp, "BLOCK%d_CRC_ACCUM 0x%08x\n", bi, block_end_crc[bi]);
        }
        fclose(fp);
        printf("Wrote: %s\n", path.c_str());
    }

    printf("\n=== DONE ===\n");
    return 0;
}
