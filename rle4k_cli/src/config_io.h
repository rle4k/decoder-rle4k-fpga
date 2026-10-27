// Minimal JSON load/save (see docs/JSON_CONFIG_SPEC.md). Default file: <applicationName>.json

#ifndef RLE4K_CONFIG_IO_H
#define RLE4K_CONFIG_IO_H

#include <iosfwd>
#include <string>
#include <vector>

namespace rle4k {

// One local NIC <-> one remote FPGA link. JSON uses only "channels"[] + "active_channel".
struct ChannelEntry {
    std::string id;
    std::string name;
    std::string type = "mac"; // mac | sink
    std::string interface_name;
    std::string local_mac;
    std::string target_mac;
    std::string sink_address; // required when type == sink
    int         mtu = 1500;
    bool        enabled = true;
};

// Optional JSON object "v8_verify" (see docs/rle4k_cli_json.md).
struct V8VerifySettings {
    bool loaded_from_json = false;  // true when "v8_verify" key exists in file
    bool fpga_only = false;
    bool inter_chunk_delay_set = false;
    int  inter_chunk_delay_ms = 0;   // full speed; >0 is debug pacing only
    bool progress_send_pct_set = false;
    int  progress_send_pct = 10;
    bool decode_progress_set = false;
    bool decode_progress = true;
    bool round_budget_sec_set = false;
    int  round_budget_sec = 600;
    bool pc_spot_check_set = false;
    int  pc_spot_check = 0;
};

struct AppConfig {
    std::string schema_version = "1.0";
    // Runtime-only materialized view from channels[active_channel].
    std::string interface_name;
    std::string local_mac;
    std::string target_mac;
    std::string input_mode = "directory";
    std::string input_path = ".";
    int         max_blocks = 0;
    int         mtu = 1500;
    int         delay_us = 0;
    int         loop_count = 1;
    bool        verify = false;
    bool        verbose_cfg = false;
    bool        do_ping = true;
    bool        do_reset = true;
    std::string notes;

    // Ping defaults: retries <= 0 means infinite attempts; timeout in ms.
    int         ping_retry = 3;
    int         ping_timeout_ms = 15000;

    std::vector<ChannelEntry> channels;
    std::string               active_channel;

    V8VerifySettings v8_verify;
};

// Best-effort read; missing fields keep defaults in |out|.
bool load_app_config(const std::string& path, AppConfig& out);

// Writes UTF-8 JSON with escaped strings.
bool save_app_config(const std::string& path, const AppConfig& cfg);

// <exe_dir>/<applicationName>.json (e.g. .../rle4k_cli.exe -> .../rle4k.json).
std::string default_config_json_path_from_argv0(const char* argv0);

// Tries <exe_dir>/rle4k_cli.json then default_config_json_path_from_argv0.
bool load_first_existing_app_config(const char* argv0, AppConfig& out, std::string* loaded_path = nullptr);

// Keep in-memory active channel materialized to helper fields when needed by runtime.
void materialize_active_channel(AppConfig& cfg);

void print_app_config(const AppConfig& cfg, std::ostream& os);

// Dot-notation keys: active_channel, send.mtu, ...
bool apply_config_field(AppConfig& cfg, const std::string& key, const std::string& value,
                        std::string* err_msg);

}  // namespace rle4k

#endif  // RLE4K_CONFIG_IO_H
