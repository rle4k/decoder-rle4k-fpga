// RLE4K Block File Reader
// Reads .blk files (40B BitMapInfoHeader + compressed data)
// Supports single file and directory batch modes

#ifndef RLE4K_BLOCK_READER_H
#define RLE4K_BLOCK_READER_H

#include "protocol.h"
#include <cstdint>
#include <string>
#include <vector>

namespace rle4k {

struct BlockData {
    BitMapInfoHeader header;
    std::vector<uint8_t> compressed;
    std::string filename;
    int strip_index = -1;        // parsed from filename token: strip{N}
    int filename_block_index = -1; // parsed from filename token: block{N}
};

class BlockReader {
public:
    // Read a single .blk file (40B header + compressed data)
    static bool read_block(const std::string& filepath, BlockData& out);

    // Read all .rle4k files from a directory (also accepts .blk/.bin).
    // File order prefers parsed strip/block index from filename:
    //   raster_strip0_block0002.rle4k -> strip=0, block=2
    // Files that cannot be parsed fall back to filename sort.
    // strip_index < 0 means no strip filter.
    static std::vector<BlockData> read_directory(const std::string& dirpath,
                                                  size_t max_blocks = 0,
                                                  int strip_index = -1);

    // Sorted unique strip indices parsed from filenames (raster_strip{N}_block{M}.rle4k).
    // Empty if directory missing or no parseable names.
    static std::vector<int> list_strip_indices_in_directory(const std::string& dirpath);

    // Read raw compressed file without 40B header (for testing).
    // Caller must provide header separately.
    static bool read_raw(const std::string& filepath, std::vector<uint8_t>& out);
};

}  // namespace rle4k

#endif  // RLE4K_BLOCK_READER_H
