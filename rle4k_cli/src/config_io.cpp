#include "config_io.h"

#include <algorithm>
#include <fstream>
#include <ostream>
#include <sstream>
#include <cctype>
#include <vector>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <cwchar>
#else
#include <climits>
#include <cstdlib>
#include <unistd.h>
#endif

namespace rle4k {
namespace {

static std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        if (c == '\\') out += "\\\\";
        else if (c == '"') out += "\\\"";
        else if (c == '\n') out += "\\n";
        else if (c == '\r') out += "\\r";
        else if (c == '\t') out += "\\t";
        else out += static_cast<char>(c);
    }
    return out;
}

static std::string extract_object_body(const std::string& s, const std::string& key) {
    const std::string pattern = "\"" + key + "\"";
    size_t p = s.find(pattern);
    if (p == std::string::npos) return "";
    p = s.find('{', p);
    if (p == std::string::npos) return "";
    int depth = 0;
    const size_t start = p;
    for (size_t i = p; i < s.size(); ++i) {
        if (s[i] == '{') depth++;
        else if (s[i] == '}') {
            depth--;
            if (depth == 0) return s.substr(start, i - start + 1);
        }
    }
    return "";
}

static std::string extract_string_in_object(const std::string& obj, const std::string& key) {
    const std::string pat = "\"" + key + "\"";
    size_t p = obj.find(pat);
    if (p == std::string::npos) return "";
    p = obj.find(':', p);
    if (p == std::string::npos) return "";
    ++p;
    while (p < obj.size() && std::isspace(static_cast<unsigned char>(obj[p]))) ++p;
    if (p >= obj.size() || obj[p] != '"') return "";
    ++p;
    std::string out;
    while (p < obj.size()) {
        if (obj[p] == '\\' && p + 1 < obj.size()) {
            const char n = obj[p + 1];
            if (n == 'n') out += '\n';
            else if (n == 'r') out += '\r';
            else if (n == 't') out += '\t';
            else if (n == '\\' || n == '"') out += n;
            else { out += '\\'; out += n; }
            p += 2;
            continue;
        }
        if (obj[p] == '"') break;
        out += obj[p++];
    }
    return out;
}

static bool extract_bool_in_object(const std::string& obj, const std::string& key, bool default_val);

static int extract_int_in_object(const std::string& obj, const std::string& key, int default_val) {
    const std::string pat = "\"" + key + "\"";
    size_t p = obj.find(pat);
    if (p == std::string::npos) return default_val;
    p = obj.find(':', p);
    if (p == std::string::npos) return default_val;
    ++p;
    while (p < obj.size() && std::isspace(static_cast<unsigned char>(obj[p]))) ++p;
    size_t q = p;
    if (p < obj.size() && (obj[p] == '-' || std::isdigit(static_cast<unsigned char>(obj[p])))) {
        if (obj[p] == '-') ++q;
        while (q < obj.size() && std::isdigit(static_cast<unsigned char>(obj[q]))) ++q;
        try {
            return std::stoi(obj.substr(p, q - p));
        } catch (...) {
            return default_val;
        }
    }
    return default_val;
}

static std::string path_join(const std::string& a, const std::string& b) {
    if (a.empty()) return b;
    if (b.empty()) return a;
    const char last = a.back();
    if (last == '/' || last == '\\') return a + b;
#ifdef _WIN32
    return a + "\\" + b;
#else
    return a + "/" + b;
#endif
}

static std::string fallback_dir_from_argv0(const char* argv0) {
    std::string p(argv0 ? argv0 : "");
    const size_t slash = p.find_last_of("/\\");
    if (slash != std::string::npos) return p.substr(0, slash);
    return ".";
}

static std::string application_basename_from_argv0(const char* argv0) {
    std::string p(argv0 ? argv0 : "");
    const size_t slash = p.find_last_of("/\\");
    if (slash != std::string::npos) p = p.substr(slash + 1);
    if (p.size() >= 4) {
        std::string low = p;
        std::transform(low.begin(), low.end(), low.begin(), [](unsigned char c) {
            return static_cast<char>(std::tolower(c));
        });
        if (low.size() >= 4 && low.compare(low.size() - 4, 4, ".exe") == 0) p = p.substr(0, p.size() - 4);
    }
    if (p.empty()) p = "rle4k";
    return p;
}

#ifdef _WIN32
static std::string utf8_from_wide(const wchar_t* w, int len) {
    if (!w || len == 0) return {};
    if (len < 0) len = static_cast<int>(wcslen(w));
    const int n = WideCharToMultiByte(CP_UTF8, 0, w, len, nullptr, 0, nullptr, nullptr);
    if (n <= 0) return {};
    std::vector<char> buf(static_cast<size_t>(n) + 1);
    WideCharToMultiByte(CP_UTF8, 0, w, len, buf.data(), n, nullptr, nullptr);
    buf[static_cast<size_t>(n)] = '\0';
    return std::string(buf.data());
}

static std::string executable_directory(const char* argv0) {
    std::vector<wchar_t> wbuf(32768);
    const DWORD n = GetModuleFileNameW(nullptr, wbuf.data(), static_cast<DWORD>(wbuf.size()));
    if (n > 0 && n < wbuf.size()) {
        std::wstring wpath(wbuf.data());
        const size_t pos = wpath.find_last_of(L"\\/");
        if (pos != std::wstring::npos) {
            std::wstring wdir = wpath.substr(0, pos);
            return utf8_from_wide(wdir.c_str(), static_cast<int>(wdir.size()));
        }
    }
    return fallback_dir_from_argv0(argv0);
}
#else
static std::string executable_directory(const char* argv0) {
#if defined(__linux__)
    char buf[PATH_MAX];
    const ssize_t len = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (len > 0) {
        buf[len] = '\0';
        std::string p(buf);
        const size_t pos = p.find_last_of('/');
        if (pos != std::string::npos) return p.substr(0, pos);
    }
#endif
    return fallback_dir_from_argv0(argv0);
}
#endif

static bool parse_channel_entries_array(const std::string& s, const char* json_key,
                                         std::vector<ChannelEntry>& out) {
    const std::string key = std::string("\"") + json_key + "\"";
    size_t p = s.find(key);
    if (p == std::string::npos) return true;
    p = s.find('[', p);
    if (p == std::string::npos) return false;
    size_t i = p + 1;
    while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) ++i;
    if (i < s.size() && s[i] == ']') return true;
    for (;;) {
        while (i < s.size() && (std::isspace(static_cast<unsigned char>(s[i])) || s[i] == ',')) ++i;
        if (i < s.size() && s[i] == ']') break;
        if (i >= s.size() || s[i] != '{') return false;
        int depth = 0;
        size_t j = i;
        for (; j < s.size(); ++j) {
            if (s[j] == '{') depth++;
            else if (s[j] == '}') {
                depth--;
                if (depth == 0) {
                    ++j;
                    break;
                }
            }
        }
        const std::string obj = s.substr(i, j - i);
        ChannelEntry e;
        e.id = extract_string_in_object(obj, "id");
        e.name = extract_string_in_object(obj, "name");
        {
            const std::string t = extract_string_in_object(obj, "type");
            if (!t.empty()) e.type = t;
        }
        e.interface_name = extract_string_in_object(obj, "interface_name");
        e.local_mac = extract_string_in_object(obj, "local_mac");
        e.target_mac = extract_string_in_object(obj, "target_mac");
        e.sink_address = extract_string_in_object(obj, "sink_address");
        e.mtu = extract_int_in_object(obj, "mtu", e.mtu);
        e.enabled = extract_bool_in_object(obj, "enabled", e.enabled);
        if (!e.id.empty()) out.push_back(std::move(e));
        i = j;
    }
    return true;
}

static bool extract_bool_in_object(const std::string& obj, const std::string& key, bool default_val) {
    const std::string pat = "\"" + key + "\"";
    size_t p = obj.find(pat);
    if (p == std::string::npos) return default_val;
    p = obj.find(':', p);
    if (p == std::string::npos) return default_val;
    ++p;
    while (p < obj.size() && std::isspace(static_cast<unsigned char>(obj[p]))) ++p;
    if (p + 4 <= obj.size() && obj.compare(p, 4, "true") == 0) return true;
    if (p + 5 <= obj.size() && obj.compare(p, 5, "false") == 0) return false;
    return default_val;
}

}  // namespace

void materialize_active_channel(AppConfig& cfg) {
    if (cfg.active_channel.empty()) return;
    for (const auto& e : cfg.channels) {
        if (e.id == cfg.active_channel) {
            cfg.interface_name = e.interface_name;
            cfg.local_mac = e.local_mac;
            cfg.target_mac = e.target_mac;
            return;
        }
    }
}

bool load_app_config(const std::string& path, AppConfig& out) {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs) return false;
    std::stringstream ss;
    ss << ifs.rdbuf();
    std::string s = ss.str();
    if (s.empty()) return false;

    AppConfig c;
    {
        const std::string inp = extract_object_body(s, "input");
        if (!inp.empty()) {
            c.input_mode = extract_string_in_object(inp, "mode");
            c.input_path = extract_string_in_object(inp, "path");
        }
    }
    {
        const std::string snd = extract_object_body(s, "send");
        if (!snd.empty()) {
            c.max_blocks = extract_int_in_object(snd, "max_blocks", c.max_blocks);
            c.mtu = extract_int_in_object(snd, "mtu", c.mtu);
            c.delay_us = extract_int_in_object(snd, "delay_us", c.delay_us);
            c.loop_count = extract_int_in_object(snd, "loop_count", c.loop_count);
            c.verify = extract_bool_in_object(snd, "verify", c.verify);
            c.verbose_cfg = extract_bool_in_object(snd, "verbose", c.verbose_cfg);
            c.do_ping = extract_bool_in_object(snd, "do_ping", c.do_ping);
            c.do_reset = extract_bool_in_object(snd, "do_reset", c.do_reset);
        }
    }
    {
        const std::string ping = extract_object_body(s, "ping");
        if (!ping.empty()) {
            c.ping_retry = extract_int_in_object(ping, "retries", c.ping_retry);
            c.ping_retry = extract_int_in_object(ping, "retry", c.ping_retry); // compatibility
            c.ping_timeout_ms = extract_int_in_object(ping, "timeout", c.ping_timeout_ms);
        }
    }
    {
        const std::string sv = extract_string_in_object(s, "schema_version");
        if (!sv.empty()) c.schema_version = sv;
    }
    {
        std::string n = extract_string_in_object(s, "notes");
        c.notes = n;
    }
    parse_channel_entries_array(s, "channels", c.channels);
    {
        const std::string ac = extract_string_in_object(s, "active_channel");
        if (!ac.empty()) c.active_channel = ac;
    }
    if (s.find("\"v8_verify\"") != std::string::npos) {
        c.v8_verify.loaded_from_json = true;
        const std::string vv = extract_object_body(s, "v8_verify");
        if (!vv.empty()) {
            c.v8_verify.fpga_only = extract_bool_in_object(vv, "fpga_only", false);
            if (vv.find("\"inter_chunk_delay_ms\"") != std::string::npos) {
                c.v8_verify.inter_chunk_delay_set = true;
                c.v8_verify.inter_chunk_delay_ms =
                    extract_int_in_object(vv, "inter_chunk_delay_ms", 1);
            }
            if (vv.find("\"progress_send_pct\"") != std::string::npos) {
                c.v8_verify.progress_send_pct_set = true;
                c.v8_verify.progress_send_pct = extract_int_in_object(vv, "progress_send_pct", 10);
            }
            if (vv.find("\"decode_progress\"") != std::string::npos) {
                c.v8_verify.decode_progress_set = true;
                c.v8_verify.decode_progress = extract_bool_in_object(vv, "decode_progress", true);
            }
            if (vv.find("\"round_budget_sec\"") != std::string::npos) {
                c.v8_verify.round_budget_sec_set = true;
                c.v8_verify.round_budget_sec = extract_int_in_object(vv, "round_budget_sec", 600);
            }
            if (vv.find("\"pc_spot_check\"") != std::string::npos) {
                c.v8_verify.pc_spot_check_set = true;
                c.v8_verify.pc_spot_check = extract_int_in_object(vv, "pc_spot_check", 0);
            }
        }
    }

    materialize_active_channel(c);

    out = c;
    return true;
}

bool save_app_config(const std::string& path, const AppConfig& cfg) {
    std::ofstream ofs(path, std::ios::binary | std::ios::trunc);
    if (!ofs) return false;
    ofs << "{\n";
    ofs << "  \"schema_version\": \"" << json_escape(cfg.schema_version) << "\",\n";
    ofs << "  \"ping\": {\n";
    ofs << "    \"retries\": " << cfg.ping_retry << ",\n";
    ofs << "    \"timeout\": " << cfg.ping_timeout_ms << "\n";
    ofs << "  },\n";
    ofs << "  \"input\": {\n";
    ofs << "    \"mode\": \"" << json_escape(cfg.input_mode) << "\",\n";
    ofs << "    \"path\": \"" << json_escape(cfg.input_path) << "\"\n";
    ofs << "  },\n";
    ofs << "  \"send\": {\n";
    ofs << "    \"max_blocks\": " << cfg.max_blocks << ",\n";
    ofs << "    \"mtu\": " << cfg.mtu << ",\n";
    ofs << "    \"delay_us\": " << cfg.delay_us << ",\n";
    ofs << "    \"loop_count\": " << cfg.loop_count << ",\n";
    ofs << "    \"verify\": " << (cfg.verify ? "true" : "false") << ",\n";
    ofs << "    \"verbose\": " << (cfg.verbose_cfg ? "true" : "false") << ",\n";
    ofs << "    \"do_ping\": " << (cfg.do_ping ? "true" : "false") << ",\n";
    ofs << "    \"do_reset\": " << (cfg.do_reset ? "true" : "false") << "\n";
    ofs << "  },\n";
    if (!cfg.channels.empty() || !cfg.active_channel.empty()) {
        ofs << "  \"channels\": [\n";
        for (size_t i = 0; i < cfg.channels.size(); ++i) {
            const ChannelEntry& e = cfg.channels[i];
            ofs << "    {\n";
            ofs << "      \"id\": \"" << json_escape(e.id) << "\",\n";
            ofs << "      \"name\": \"" << json_escape(e.name) << "\",\n";
            ofs << "      \"type\": \"" << json_escape(e.type) << "\",\n";
            ofs << "      \"interface_name\": \"" << json_escape(e.interface_name) << "\",\n";
            ofs << "      \"local_mac\": \"" << json_escape(e.local_mac) << "\",\n";
            ofs << "      \"target_mac\": \"" << json_escape(e.target_mac) << "\",\n";
            ofs << "      \"sink_address\": \"" << json_escape(e.sink_address) << "\",\n";
            ofs << "      \"mtu\": " << e.mtu << ",\n";
            ofs << "      \"enabled\": " << (e.enabled ? "true" : "false") << "\n";
            ofs << "    }";
            if (i + 1 < cfg.channels.size()) ofs << ",";
            ofs << "\n";
        }
        ofs << "  ],\n";
        ofs << "  \"active_channel\": \"" << json_escape(cfg.active_channel) << "\",\n";
    }
    {
        const int icd =
            cfg.v8_verify.inter_chunk_delay_set ? cfg.v8_verify.inter_chunk_delay_ms : 1;
        const int psp = cfg.v8_verify.progress_send_pct_set ? cfg.v8_verify.progress_send_pct : 10;
        const int rbs = cfg.v8_verify.round_budget_sec_set ? cfg.v8_verify.round_budget_sec : 600;
        const int psc = cfg.v8_verify.pc_spot_check_set ? cfg.v8_verify.pc_spot_check : 0;
        const bool dp = cfg.v8_verify.decode_progress_set ? cfg.v8_verify.decode_progress : true;
        ofs << "  \"v8_verify\": {\n";
        ofs << "    \"fpga_only\": " << (cfg.v8_verify.fpga_only ? "true" : "false") << ",\n";
        ofs << "    \"inter_chunk_delay_ms\": " << icd << ",\n";
        ofs << "    \"progress_send_pct\": " << psp << ",\n";
        ofs << "    \"decode_progress\": " << (dp ? "true" : "false") << ",\n";
        ofs << "    \"round_budget_sec\": " << rbs << ",\n";
        ofs << "    \"pc_spot_check\": " << psc << "\n";
        ofs << "  },\n";
    }
    ofs << "  \"notes\": \"" << json_escape(cfg.notes) << "\"\n";
    ofs << "}\n";
    return ofs.good();
}

std::string default_config_json_path_from_argv0(const char* argv0) {
    return path_join(executable_directory(argv0), application_basename_from_argv0(argv0) + ".json");
}

void print_app_config(const AppConfig& cfg, std::ostream& os) {
    os << "# channels[].* define local NIC <-> remote MAC links\n";
    os << "schema_version: " << cfg.schema_version << "\n";
    os << "active_channel: " << cfg.active_channel << "\n";
    for (size_t i = 0; i < cfg.channels.size(); ++i) {
        const ChannelEntry& e = cfg.channels[i];
        os << "channels[" << i << "].id: " << e.id << "\n";
        os << "channels[" << i << "].name: " << e.name << "\n";
        os << "channels[" << i << "].type: " << e.type << "\n";
        os << "channels[" << i << "].interface_name: " << e.interface_name << "\n";
        os << "channels[" << i << "].local_mac: " << e.local_mac << "\n";
        os << "channels[" << i << "].target_mac: " << e.target_mac << "\n";
        os << "channels[" << i << "].sink_address: " << e.sink_address << "\n";
        os << "channels[" << i << "].mtu: " << e.mtu << "\n";
        os << "channels[" << i << "].enabled: " << (e.enabled ? "true" : "false") << "\n";
    }
    os << "ping.retries: " << cfg.ping_retry << "\n";
    os << "ping.timeout: " << cfg.ping_timeout_ms << "\n";
    os << "input.mode: " << cfg.input_mode << "\n";
    os << "input.path: " << cfg.input_path << "\n";
    os << "send.max_blocks: " << cfg.max_blocks << "\n";
    os << "send.mtu: " << cfg.mtu << "\n";
    os << "send.delay_us: " << cfg.delay_us << "\n";
    os << "send.loop_count: " << cfg.loop_count << "\n";
    os << "send.verify: " << (cfg.verify ? "true" : "false") << "\n";
    os << "send.verbose: " << (cfg.verbose_cfg ? "true" : "false") << "\n";
    os << "send.do_ping: " << (cfg.do_ping ? "true" : "false") << "\n";
    os << "send.do_reset: " << (cfg.do_reset ? "true" : "false") << "\n";
    os << "v8_verify.loaded_from_json: " << (cfg.v8_verify.loaded_from_json ? "true" : "false") << "\n";
    os << "v8_verify.fpga_only: " << (cfg.v8_verify.fpga_only ? "true" : "false") << "\n";
    os << "v8_verify.inter_chunk_delay_ms: "
       << (cfg.v8_verify.inter_chunk_delay_set ? std::to_string(cfg.v8_verify.inter_chunk_delay_ms)
                                               : std::string("(default)"))
       << "\n";
    os << "v8_verify.progress_send_pct: "
       << (cfg.v8_verify.progress_send_pct_set ? std::to_string(cfg.v8_verify.progress_send_pct)
                                               : std::string("(default)"))
       << "\n";
    os << "v8_verify.decode_progress: "
       << (cfg.v8_verify.decode_progress_set ? (cfg.v8_verify.decode_progress ? "true" : "false")
                                             : std::string("(default)"))
       << "\n";
    os << "v8_verify.round_budget_sec: "
       << (cfg.v8_verify.round_budget_sec_set ? std::to_string(cfg.v8_verify.round_budget_sec)
                                              : std::string("(default)"))
       << "\n";
    os << "v8_verify.pc_spot_check: "
       << (cfg.v8_verify.pc_spot_check_set ? std::to_string(cfg.v8_verify.pc_spot_check)
                                           : std::string("(default)"))
       << "\n";
    os << "notes: " << cfg.notes << "\n";
}

namespace {

static bool parse_bool_token(const std::string& v, bool* out) {
    std::string s = v;
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    if (s == "true" || s == "1" || s == "yes") {
        *out = true;
        return true;
    }
    if (s == "false" || s == "0" || s == "no") {
        *out = false;
        return true;
    }
    return false;
}

}  // namespace

bool apply_config_field(AppConfig& cfg, const std::string& key, const std::string& value,
                        std::string* err_msg) {
    auto fail = [&](const char* msg) {
        if (err_msg) *err_msg = msg;
        return false;
    };

    if (key == "schema_version") {
        cfg.schema_version = value;
        return true;
    }
    if (key == "active_channel") {
        if (!value.empty()) {
            const bool all_digits = std::all_of(value.begin(), value.end(), [](unsigned char ch) {
                return std::isdigit(ch) != 0;
            });
            if (!all_digits) return fail("active_channel must be numeric id string (0,1,2,...)");
        }
        cfg.active_channel = value;
        materialize_active_channel(cfg);
        return true;
    }
    if (key == "retry" || key == "retries" || key == "ping.retry" || key == "ping.retries") {
        try {
            cfg.ping_retry = std::stoi(value);
        } catch (...) {
            return fail("Invalid integer for ping.retries / retries");
        }
        return true;
    }
    if (key == "timeout" || key == "ping.timeout") {
        try {
            const int t = std::stoi(value);
            if (t <= 0) return fail("ping.timeout must be positive (milliseconds)");
            cfg.ping_timeout_ms = t;
        } catch (...) {
            return fail("Invalid integer for ping.timeout / timeout");
        }
        return true;
    }
    if (key == "input.mode") {
        cfg.input_mode = value;
        return true;
    }
    if (key == "input.path") {
        cfg.input_path = value;
        return true;
    }
    if (key == "notes") {
        cfg.notes = value;
        return true;
    }
    if (key == "send.max_blocks") {
        try {
            cfg.max_blocks = std::stoi(value);
        } catch (...) {
            return fail("Invalid integer for send.max_blocks");
        }
        return true;
    }
    if (key == "send.mtu") {
        try {
            cfg.mtu = std::stoi(value);
        } catch (...) {
            return fail("Invalid integer for send.mtu");
        }
        return true;
    }
    if (key == "send.delay_us") {
        try {
            cfg.delay_us = std::stoi(value);
        } catch (...) {
            return fail("Invalid integer for send.delay_us");
        }
        return true;
    }
    if (key == "send.loop_count") {
        try {
            cfg.loop_count = std::stoi(value);
        } catch (...) {
            return fail("Invalid integer for send.loop_count");
        }
        return true;
    }
    if (key == "send.verify") {
        bool b = false;
        if (!parse_bool_token(value, &b)) return fail("Invalid boolean for send.verify (use true/false)");
        cfg.verify = b;
        return true;
    }
    if (key == "send.verbose") {
        bool b = false;
        if (!parse_bool_token(value, &b)) return fail("Invalid boolean for send.verbose (use true/false)");
        cfg.verbose_cfg = b;
        return true;
    }
    if (key == "send.do_ping") {
        bool b = false;
        if (!parse_bool_token(value, &b)) return fail("Invalid boolean for send.do_ping (use true/false)");
        cfg.do_ping = b;
        return true;
    }
    if (key == "send.do_reset") {
        bool b = false;
        if (!parse_bool_token(value, &b)) return fail("Invalid boolean for send.do_reset (use true/false)");
        cfg.do_reset = b;
        return true;
    }
    if (key == "v8_verify.fpga_only") {
        bool b = false;
        if (!parse_bool_token(value, &b)) return fail("Invalid boolean for v8_verify.fpga_only");
        cfg.v8_verify.loaded_from_json = true;
        cfg.v8_verify.fpga_only = b;
        return true;
    }
    if (key == "v8_verify.inter_chunk_delay_ms") {
        try {
            cfg.v8_verify.inter_chunk_delay_ms = std::stoi(value);
            cfg.v8_verify.inter_chunk_delay_set = true;
            cfg.v8_verify.loaded_from_json = true;
        } catch (...) {
            return fail("Invalid integer for v8_verify.inter_chunk_delay_ms");
        }
        return true;
    }
    if (key == "v8_verify.progress_send_pct") {
        try {
            cfg.v8_verify.progress_send_pct = std::stoi(value);
            cfg.v8_verify.progress_send_pct_set = true;
            cfg.v8_verify.loaded_from_json = true;
        } catch (...) {
            return fail("Invalid integer for v8_verify.progress_send_pct");
        }
        return true;
    }
    if (key == "v8_verify.decode_progress") {
        bool b = false;
        if (!parse_bool_token(value, &b)) return fail("Invalid boolean for v8_verify.decode_progress");
        cfg.v8_verify.decode_progress = b;
        cfg.v8_verify.decode_progress_set = true;
        cfg.v8_verify.loaded_from_json = true;
        return true;
    }
    if (key == "v8_verify.round_budget_sec") {
        try {
            cfg.v8_verify.round_budget_sec = std::stoi(value);
            cfg.v8_verify.round_budget_sec_set = true;
            cfg.v8_verify.loaded_from_json = true;
        } catch (...) {
            return fail("Invalid integer for v8_verify.round_budget_sec");
        }
        return true;
    }
    if (key == "v8_verify.pc_spot_check") {
        try {
            cfg.v8_verify.pc_spot_check = std::stoi(value);
            cfg.v8_verify.pc_spot_check_set = true;
            cfg.v8_verify.loaded_from_json = true;
        } catch (...) {
            return fail("Invalid integer for v8_verify.pc_spot_check");
        }
        return true;
    }
    return fail("Unknown key (use dot notation, e.g. active_channel, send.mtu)");
}

bool load_first_existing_app_config(const char* argv0, AppConfig& out, std::string* loaded_path) {
    const std::string p1 = path_join(executable_directory(argv0), "rle4k_cli.json");
    if (load_app_config(p1, out)) {
        if (loaded_path) *loaded_path = p1;
        return true;
    }
    const std::string p2 = default_config_json_path_from_argv0(argv0);
    if (load_app_config(p2, out)) {
        if (loaded_path) *loaded_path = p2;
        return true;
    }
    if (loaded_path) loaded_path->clear();
    return false;
}

}  // namespace rle4k
