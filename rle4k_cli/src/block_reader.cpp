// Block file reader implementation
// .blk format: [BitMapInfoHeader 40B] [compressed data N bytes]

#include "block_reader.h"
#include "cli_timestamp.h"
#include <fstream>
#include <iostream>
#include <algorithm>
#include <cctype>
#include <limits>
#include <set>

#ifdef _WIN32
#include <windows.h>
#endif

namespace rle4k {

namespace {

std::string get_filename(const std::string& path) {
    size_t p1 = path.find_last_of("/\\");
    if (p1 == std::string::npos) return path;
    return path.substr(p1 + 1);
}

std::string to_lower_copy(const std::string& s) {
    std::string out = s;
    for (char& ch : out) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return out;
}

bool has_supported_ext(const std::string& path) {
    size_t pos = path.find_last_of('.');
    if (pos == std::string::npos) return false;
    std::string ext = to_lower_copy(path.substr(pos));
    // Default suffix: .rle4k, keep backward compatibility with .blk/.bin
    return (ext == ".rle4k" || ext == ".blk" || ext == ".bin");
}

bool parse_decimal_after_token(const std::string& lower_name, const std::string& token, int& value) {
    const size_t token_pos = lower_name.find(token);
    if (token_pos == std::string::npos) return false;
    size_t pos = token_pos + token.size();
    if (pos >= lower_name.size() || !std::isdigit(static_cast<unsigned char>(lower_name[pos]))) {
        return false;
    }

    uint64_t parsed = 0;
    while (pos < lower_name.size() && std::isdigit(static_cast<unsigned char>(lower_name[pos]))) {
        parsed = parsed * 10 + static_cast<uint64_t>(lower_name[pos] - '0');
        if (parsed > static_cast<uint64_t>((std::numeric_limits<int>::max)())) {
            return false;
        }
        ++pos;
    }
    value = static_cast<int>(parsed);
    return true;
}

bool parse_strip_block_indices(const std::string& filename, int& strip_idx, int& block_idx) {
    const std::string lower = to_lower_copy(filename);
    if (!parse_decimal_after_token(lower, "strip", strip_idx)) return false;
    if (!parse_decimal_after_token(lower, "block", block_idx)) return false;
    return true;
}

bool is_directory_path(const std::string& path) {
#ifdef _WIN32
    DWORD attr = GetFileAttributesA(path.c_str());
    if (attr == INVALID_FILE_ATTRIBUTES) return false;
    return (attr & FILE_ATTRIBUTE_DIRECTORY) != 0;
#else
    return false;
#endif
}

void list_block_files(const std::string& dirpath, std::vector<std::string>& files) {
#ifdef _WIN32
    std::string pattern = dirpath;
    if (!pattern.empty() && pattern.back() != '\\' && pattern.back() != '/')
        pattern += "\\";
    pattern += "*";

    WIN32_FIND_DATAA ffd;
    HANDLE hFind = FindFirstFileA(pattern.c_str(), &ffd);
    if (hFind == INVALID_HANDLE_VALUE) return;

    do {
        if (ffd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        std::string name = ffd.cFileName;
        if (!has_supported_ext(name)) continue;

        std::string full = dirpath;
        if (!full.empty() && full.back() != '\\' && full.back() != '/')
            full += "\\";
        full += name;
        files.push_back(full);
    } while (FindNextFileA(hFind, &ffd));

    FindClose(hFind);
#else
    (void)dirpath;
    (void)files;
#endif
}

} // namespace

bool BlockReader::read_block(const std::string& filepath, BlockData& out) {
    std::ifstream ifs(filepath, std::ios::binary);
    if (!ifs) {
        CLI_LOG_ERR << "Cannot open block file: " << filepath << std::endl;
        return false;
    }

    ifs.seekg(0, std::ios::end);
    auto file_size = ifs.tellg();
    ifs.seekg(0, std::ios::beg);

    if (file_size < static_cast<std::streamoff>(sizeof(BitMapInfoHeader))) {
        CLI_LOG_ERR << "Block file too small: " << filepath
                  << " (" << file_size << " bytes)" << std::endl;
        return false;
    }

    ifs.read(reinterpret_cast<char*>(&out.header), sizeof(BitMapInfoHeader));
    if (!ifs) {
        CLI_LOG_ERR << "Failed to read header: " << filepath << std::endl;
        return false;
    }

    size_t data_size = static_cast<size_t>(file_size) - sizeof(BitMapInfoHeader);
    if (out.header.compressed_size_bytes() != data_size) {
        CLI_LOG_ERR << "Header DataLength mismatch: " << filepath
                    << " header=" << out.header.compressed_size_bytes()
                    << " file_payload=" << data_size << std::endl;
    }
    out.compressed.resize(data_size);
    if (data_size > 0) {
        ifs.read(reinterpret_cast<char*>(out.compressed.data()), data_size);
        if (!ifs) {
            CLI_LOG_ERR << "Failed to read compressed data: " << filepath << std::endl;
            return false;
        }
    }

    out.filename = get_filename(filepath);
    parse_strip_block_indices(out.filename, out.strip_index, out.filename_block_index);
    return true;
}

std::vector<BlockData> BlockReader::read_directory(const std::string& dirpath,
                                                    size_t max_blocks,
                                                    int strip_index) {
    std::vector<BlockData> blocks;
    std::vector<std::string> files;

    if (!is_directory_path(dirpath)) {
        CLI_LOG_ERR << "Not a directory: " << dirpath << std::endl;
        return blocks;
    }

    list_block_files(dirpath, files);
    if (strip_index >= 0) {
        files.erase(
            std::remove_if(files.begin(), files.end(),
                           [&](const std::string& path) {
                               int parsed_strip = -1;
                               int parsed_block = -1;
                               if (!parse_strip_block_indices(get_filename(path), parsed_strip, parsed_block)) {
                                   return true;
                               }
                               return parsed_strip != strip_index;
                           }),
            files.end());
    }

    std::sort(files.begin(), files.end(),
              [](const std::string& lhs_path, const std::string& rhs_path) {
                  const std::string lhs_name = get_filename(lhs_path);
                  const std::string rhs_name = get_filename(rhs_path);
                  int lhs_strip = -1;
                  int lhs_block = -1;
                  int rhs_strip = -1;
                  int rhs_block = -1;
                  const bool lhs_ok = parse_strip_block_indices(lhs_name, lhs_strip, lhs_block);
                  const bool rhs_ok = parse_strip_block_indices(rhs_name, rhs_strip, rhs_block);

                  if (lhs_ok && rhs_ok) {
                      if (lhs_strip != rhs_strip) return lhs_strip < rhs_strip;
                      if (lhs_block != rhs_block) return lhs_block < rhs_block;
                  } else if (lhs_ok != rhs_ok) {
                      return lhs_ok; // Prefer parsed names before unparsed names
                  }
                  return lhs_name < rhs_name;
              });
    if (max_blocks > 0 && files.size() > max_blocks)
        files.resize(max_blocks);

    for (const auto& f : files) {
        BlockData bd;
        if (read_block(f, bd))
            blocks.push_back(std::move(bd));
    }

    return blocks;
}

std::vector<int> BlockReader::list_strip_indices_in_directory(const std::string& dirpath) {
    std::vector<std::string> files;
    std::set<int> strips;
    if (!is_directory_path(dirpath)) return {};

    list_block_files(dirpath, files);
    for (const auto& path : files) {
        int strip_idx = -1;
        int block_idx = -1;
        if (parse_strip_block_indices(get_filename(path), strip_idx, block_idx))
            strips.insert(strip_idx);
    }
    return std::vector<int>(strips.begin(), strips.end());
}

bool BlockReader::read_raw(const std::string& filepath, std::vector<uint8_t>& out) {
    std::ifstream ifs(filepath, std::ios::binary);
    if (!ifs) return false;

    ifs.seekg(0, std::ios::end);
    auto sz = ifs.tellg();
    ifs.seekg(0, std::ios::beg);

    out.resize(static_cast<size_t>(sz));
    ifs.read(reinterpret_cast<char*>(out.data()), sz);
    return ifs.good();
}

}  // namespace rle4k
