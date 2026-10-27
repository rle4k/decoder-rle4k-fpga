// gen_stim.cpp -- Generate Verilog simulation stimulus from .rle4k block file(s)
// Single block:  gen_stim <file.rle4k> [output_dir]
// Multi-block:   gen_stim <file0.rle4k> <file1.rle4k> ... [output_dir]
//
// Outputs:
//   stim_data.hex   : 32-bit words (compressed stream with 0xC0+0x80+pad)
//   stim_params.txt : num_blocks total_words \n per-block: width stride height
//   ref_output.hex  : 512-bit words from C++ reference decoder (all blocks)
//   ref_crc.txt     : PC reference CRC32 and word count (strip-level)
//
// Build: cl /EHsc /std:c++17 /O2 /DDISALBE_RLE4K_LIB gen_stim.cpp <rle4k_cpp>/rle4k_decoder.cpp /I<rle4k_cpp>

#include "rle4k.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <string>

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
};
#pragma pack(pop)

static uint32_t align_bits_from_mode(uint8_t mode) {
    static constexpr uint32_t k[7] = {8,16,32,64,128,256,512};
    return (mode < 7) ? k[mode] : 8;
}
static uint32_t align_up(uint32_t w, uint32_t a) {
    return a ? ((w + a - 1) / a) * a : w;
}

struct BlockInfo {
    BitMapInfoHeader hdr;
    std::vector<uint8_t> compressed;
    uint32_t width_bits;
    uint32_t stride_bits;
    uint32_t stride_bytes;
    uint32_t height;
};

static bool load_block(const char* path, BlockInfo& bi) {
    FILE* fp = fopen(path, "rb");
    if (!fp) { fprintf(stderr, "Cannot open %s\n", path); return false; }

    if (fread(&bi.hdr, 1, sizeof(bi.hdr), fp) != sizeof(bi.hdr)) {
        fprintf(stderr, "Cannot read header from %s\n", path); fclose(fp); return false;
    }

    bi.compressed.resize(bi.hdr.data_length);
    if (fread(bi.compressed.data(), 1, bi.hdr.data_length, fp) != bi.hdr.data_length) {
        fprintf(stderr, "Cannot read data from %s (%u bytes)\n", path, bi.hdr.data_length);
        fclose(fp); return false;
    }
    fclose(fp);

    bi.width_bits = bi.hdr.width;
    bi.height = bi.hdr.height;
    if (bi.height != 0 && bi.hdr.source_length % bi.height == 0)
        bi.stride_bits = (bi.hdr.source_length / bi.height) * 8;
    else
        bi.stride_bits = align_up(bi.width_bits, align_bits_from_mode(bi.hdr.align_mode));
    bi.stride_bytes = (bi.stride_bits + 7) / 8;
    return true;
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: gen_stim <file0.rle4k> [file1.rle4k ...] [output_dir]\n");
        return 1;
    }

    // Parse args: last arg is output_dir if it doesn't end with .rle4k
    std::vector<const char*> files;
    std::string outdir = ".";

    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (i == argc - 1 && arg.size() >= 6 &&
            arg.substr(arg.size() - 6) != ".rle4k") {
            outdir = arg;
        } else {
            files.push_back(argv[i]);
        }
    }

    if (files.empty()) {
        fprintf(stderr, "No input files specified\n");
        return 1;
    }

    // Load all blocks
    std::vector<BlockInfo> blocks(files.size());
    for (size_t i = 0; i < files.size(); i++) {
        if (!load_block(files[i], blocks[i])) return 1;
        printf("Block[%zu]: %s\n", i, files[i]);
        printf("  index=%u width=%u height=%u compressed=%u source=%u\n",
               blocks[i].hdr.index, blocks[i].width_bits, blocks[i].height,
               blocks[i].hdr.data_length, blocks[i].hdr.source_length);
        printf("  stride_bits=%u stride_bytes=%u\n",
               blocks[i].stride_bits, blocks[i].stride_bytes);
    }

    // Build stream: [blk0][0xC0][blk1][0xC0]...[blkN][0xC0][0x80][pad]
    std::vector<uint8_t> stream;
    for (size_t i = 0; i < blocks.size(); i++) {
        stream.insert(stream.end(), blocks[i].compressed.begin(), blocks[i].compressed.end());
        stream.push_back(0xC0);
    }
    stream.push_back(0x80);
    while (stream.size() % 4 != 0)
        stream.push_back(0x00);

    printf("\nStrip: %zu blocks, stream=%zu bytes\n", blocks.size(), stream.size());

    // Write stim_data.hex
    uint32_t total_stim_words = (uint32_t)(stream.size() / 4);
    {
        std::string path = outdir + "/stim_data.hex";
        FILE* fout = fopen(path.c_str(), "w");
        if (!fout) { fprintf(stderr, "Cannot create %s\n", path.c_str()); return 1; }
        for (uint32_t i = 0; i < total_stim_words; i++) {
            uint32_t w = stream[i*4] | (stream[i*4+1]<<8) |
                         (stream[i*4+2]<<16) | (stream[i*4+3]<<24);
            fprintf(fout, "%08X\n", w);
        }
        fclose(fout);
        printf("  stim_data.hex: %u words\n", total_stim_words);
    }

    // Write stim_params.txt
    // Line 1: num_blocks total_stim_words
    // Lines 2+: width_bits stride_bits height (per block)
    {
        std::string path = outdir + "/stim_params.txt";
        FILE* fout = fopen(path.c_str(), "w");
        fprintf(fout, "%zu %u\n", blocks.size(), total_stim_words);
        for (size_t i = 0; i < blocks.size(); i++) {
            fprintf(fout, "%u %u %u\n",
                    blocks[i].width_bits, blocks[i].stride_bits, blocks[i].height);
        }
        fclose(fout);
    }

    // Reference decode all blocks and write ref_output.hex
    uint32_t total_ref_words = 0;
    std::vector<std::vector<uint8_t>> decoded_blocks(blocks.size());

    // CRC32 table
    static uint32_t crc_table[256];
    for (uint32_t i = 0; i < 256; ++i) {
        uint32_t c = i;
        for (int j = 0; j < 8; ++j)
            c = (c & 1) ? (c >> 1) ^ 0xEDB88320u : (c >> 1);
        crc_table[i] = c;
    }

    uint32_t crc = 0xFFFFFFFFu;
    uint32_t crc_word_count = 0;

    {
        std::string path = outdir + "/ref_output.hex";
        FILE* fout = fopen(path.c_str(), "w");

        for (size_t bi = 0; bi < blocks.size(); bi++) {
            const auto& b = blocks[bi];
            uint32_t decoded_size = b.stride_bytes * b.height;
            decoded_blocks[bi].resize(decoded_size, 0);

            int ret = rle4k_decode_block(b.compressed.data(), b.hdr.data_length,
                                          decoded_blocks[bi].data(),
                                          b.width_bits, b.height, b.stride_bytes);
            if (ret < 0) {
                fprintf(stderr, "Block[%zu] decode FAILED: error=%d\n", bi, ret);
                fclose(fout); return 1;
            }
            printf("  Block[%zu] decode OK: %d bytes\n", bi, ret);

            // Write 512-bit words and accumulate CRC
            uint32_t block_words = 0;
            for (size_t off = 0; off < (size_t)ret; off += 64) {
                // Write hex (MSB first for readmemh)
                for (int b2 = 63; b2 >= 0; b2--) {
                    uint8_t v = (off + b2 < (size_t)ret) ? decoded_blocks[bi][off + b2] : 0;
                    fprintf(fout, "%02X", v);
                }
                fprintf(fout, "\n");

                // CRC (byte 0 first, matching FPGA)
                for (int b2 = 0; b2 < 64; b2++) {
                    uint8_t v = (off + b2 < (size_t)ret) ? decoded_blocks[bi][off + b2] : 0;
                    crc = crc_table[(crc ^ v) & 0xFF] ^ (crc >> 8);
                }
                crc_word_count++;
                block_words++;
            }
            total_ref_words += block_words;
            printf("  Block[%zu] ref words: %u (cumulative CRC=0x%08X)\n",
                   bi, block_words, crc ^ 0xFFFFFFFFu);
        }
        fclose(fout);
        printf("  ref_output.hex: %u total words\n", total_ref_words);
    }

    uint32_t crc_final = crc ^ 0xFFFFFFFFu;
    printf("\nStrip CRC32: 0x%08X  words: %u\n", crc_final, crc_word_count);

    // Write ref_crc.txt
    {
        std::string path = outdir + "/ref_crc.txt";
        FILE* fout = fopen(path.c_str(), "w");
        fprintf(fout, "%08X %u\n", crc_final, crc_word_count);
        fclose(fout);
    }

    printf("Done.\n");
    return 0;
}
