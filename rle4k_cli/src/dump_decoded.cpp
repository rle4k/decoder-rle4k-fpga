// dump_decoded -- Dump first N bytes of decoded output for verification
#ifndef DISALBE_RLE4K_LIB
#define DISALBE_RLE4K_LIB
#endif
#include "rle4k.h"
#include "block_reader.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using namespace rle4k;

int main(int argc, char* argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: dump_decoded <block_file> [--bytes N]\n");
        return 1;
    }
    BlockData bd;
    if (!BlockReader::read_block(argv[1], bd)) {
        fprintf(stderr, "Cannot read: %s\n", argv[1]);
        return 1;
    }
    int dump_bytes = 640;
    for (int i = 2; i < argc; ++i) {
        if (std::string(argv[i]) == "--bytes" && i + 1 < argc)
            dump_bytes = std::atoi(argv[++i]);
    }
    uint32_t lw = bd.header.line_width_bits();
    uint32_t ls = bd.header.line_stride_bits();
    uint32_t bh = bd.header.block_height_lines();
    uint32_t stride_bytes = (ls + 7) / 8;

    printf("Width=%u bits, Stride=%u bits (%u bytes), Height=%u lines\n", lw, ls, stride_bytes, bh);
    printf("Compressed: %zu bytes\n", bd.compressed.size());
    printf("Compressed[0..17]: ");
    for (int i = 0; i < 18 && i < (int)bd.compressed.size(); ++i)
        printf("%02X ", bd.compressed[i]);
    printf("\n\n");

    std::vector<uint8_t> decoded(stride_bytes * bh, 0);
    int ret = rle4k_decode_block(bd.compressed.data(),
        static_cast<uint32_t>(bd.compressed.size()),
        decoded.data(), lw, bh, stride_bytes);

    printf("Decode ret=%d (expected %u)\n\n", ret, stride_bytes * bh);

    printf("=== Decoded data dump (first %d bytes, line 0) ===\n", dump_bytes);
    for (int i = 0; i < dump_bytes && i < ret; ++i) {
        if (i % 64 == 0) printf("\n  word[%d] (byte %d): ", i / 64, i);
        if (i % 16 == 0 && i % 64 != 0) printf(" | ");
        printf("%02X", decoded[i]);
    }
    printf("\n\n");

    // Summary per 64-byte word
    printf("=== Per-word summary (first %d words) ===\n", dump_bytes / 64);
    for (int w = 0; w < dump_bytes / 64 && w * 64 < ret; ++w) {
        bool all_zero = true, all_ff = true;
        for (int b = 0; b < 64; ++b) {
            if (decoded[w * 64 + b] != 0x00) all_zero = false;
            if (decoded[w * 64 + b] != 0xFF) all_ff = false;
        }
        printf("  word[%3d]: %s\n", w,
               all_zero ? "ALL_ZERO" : all_ff ? "ALL_FF" : "MIXED");
    }
    return 0;
}
