// Human-readable local timestamp prefix for console logs (CLI + stub).

#ifndef RLE4K_CLI_TIMESTAMP_H
#define RLE4K_CLI_TIMESTAMP_H

#include <chrono>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <ctime>
#include <iomanip>
#include <ostream>
#include <sstream>
#include <string>
#include <string_view>

inline std::string cli_timestamp_prefix() {
    using clock = std::chrono::system_clock;
    const auto now = clock::now();
    const std::time_t tt = clock::to_time_t(now);
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                        now.time_since_epoch()) %
                    1000;
    std::tm tm{};
#ifdef _WIN32
    localtime_s(&tm, &tt);
#else
    localtime_r(&tt, &tm);
#endif
    std::ostringstream oss;
    oss << '[' << std::setfill('0') << std::setw(4) << (tm.tm_year + 1900) << '-'
        << std::setw(2) << (tm.tm_mon + 1) << '-' << std::setw(2) << tm.tm_mday << ' '
        << std::setw(2) << tm.tm_hour << ':' << std::setw(2) << tm.tm_min << ':'
        << std::setw(2) << tm.tm_sec << '.' << std::setw(3) << static_cast<int>(ms.count()) << "] ";
    return oss.str();
}

inline void cli_ts_fprintf(FILE* stream, const char* fmt, ...) {
    std::fputs(cli_timestamp_prefix().c_str(), stream);
    va_list ap;
    va_start(ap, fmt);
    std::vfprintf(stream, fmt, ap);
    va_end(ap);
}

// Print a multi-line C string; each output line gets its own timestamp prefix.
inline void cli_print_multiline_ts(std::ostream& os, const char* text) {
    const char* p = text ? text : "";
    while (*p != '\0') {
        const char* nl = std::strchr(p, '\n');
        if (nl == nullptr) {
            os << cli_timestamp_prefix() << p << '\n';
            break;
        }
        if (nl == p) {
            os << cli_timestamp_prefix() << '\n';
        } else {
            os << cli_timestamp_prefix()
               << std::string_view(p, static_cast<size_t>(nl - p)) << '\n';
        }
        p = nl + 1;
    }
}

#define CLI_LOG_OUT (std::cout << cli_timestamp_prefix())
#define CLI_LOG_ERR (std::cerr << cli_timestamp_prefix())

#endif  // RLE4K_CLI_TIMESTAMP_H
