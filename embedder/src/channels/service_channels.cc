#include "channels/service_channels.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <sys/stat.h>
#include <sys/wait.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include "channels/wpa_supplicant_client.h"

namespace pluto {
namespace {

namespace fs = std::filesystem;

std::string env_or(const char* name, const std::string& fallback) {
  const char* value = std::getenv(name);
  return value != nullptr && *value != '\0' ? std::string(value) : fallback;
}

std::string trim(const std::string& text) {
  size_t begin = 0;
  size_t end = text.size();
  while (begin < end && std::isspace(static_cast<unsigned char>(text[begin]))) {
    ++begin;
  }
  while (end > begin && std::isspace(static_cast<unsigned char>(text[end - 1]))) {
    --end;
  }
  return text.substr(begin, end - begin);
}

std::optional<std::string> read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    return std::nullopt;
  }
  std::ostringstream buffer;
  buffer << in.rdbuf();
  if (in.bad()) {
    return std::nullopt;
  }
  return buffer.str();
}

std::optional<int64_t> read_int_file(const std::string& path) {
  std::optional<std::string> content = read_file(path);
  if (!content.has_value()) {
    return std::nullopt;
  }
  const std::string text = trim(*content);
  if (text.empty()) {
    return std::nullopt;
  }
  char* end = nullptr;
  const long long value = std::strtoll(text.c_str(), &end, 10);
  if (end == text.c_str()) {
    return std::nullopt;
  }
  return static_cast<int64_t>(value);
}

bool write_file(const std::string& path, const std::string& content) {
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  if (!out) {
    return false;
  }
  out << content;
  out.flush();
  return static_cast<bool>(out);
}

bool write_file_atomic(const std::string& path, const std::string& content) {
  const std::string temporary = path + ".tmp";
  if (!write_file(temporary, content)) {
    return false;
  }
  if (std::rename(temporary.c_str(), path.c_str()) == 0) {
    return true;
  }
  std::error_code ec;
  fs::remove(temporary, ec);
  return false;
}

bool ensure_dir(const std::string& path) {
  std::error_code ec;
  fs::create_directories(path, ec);
  return !ec || fs::is_directory(path, ec);
}

int64_t file_mtime_ms(const std::string& path) {
  struct stat st {};
  if (::stat(path.c_str(), &st) != 0) {
    return 0;
  }
  return static_cast<int64_t>(st.st_mtime) * 1000;
}

int64_t directory_size_bytes(const fs::path& dir) {
  std::error_code ec;
  if (!fs::is_directory(dir, ec) || ec) {
    return 0;
  }
  int64_t total = 0;
  fs::recursive_directory_iterator it(
      dir, fs::directory_options::skip_permission_denied, ec);
  const fs::recursive_directory_iterator end;
  while (!ec && it != end) {
    std::error_code entry_ec;
    if (it->is_regular_file(entry_ec) && !entry_ec) {
      const uintmax_t size = it->file_size(entry_ec);
      if (!entry_ec) {
        total += static_cast<int64_t>(size);
      }
    }
    it.increment(ec);
  }
  return total;
}

// Runs a shell command, returning stdout on exit status 0.
std::optional<std::string> run_command(const std::string& command) {
  FILE* pipe = ::popen((command + " 2>/dev/null").c_str(), "r");
  if (pipe == nullptr) {
    return std::nullopt;
  }
  std::string output;
  char buffer[512];
  size_t count = 0;
  while ((count = std::fread(buffer, 1, sizeof buffer, pipe)) > 0) {
    output.append(buffer, count);
  }
  const int status = ::pclose(pipe);
  if (status == -1 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    return std::nullopt;
  }
  return output;
}

std::string shell_quote(const std::string& value) {
  std::string quoted = "'";
  for (const char c : value) {
    if (c == '\'') {
      quoted += "'\\''";
    } else {
      quoted += c;
    }
  }
  quoted += "'";
  return quoted;
}

std::vector<std::string> split_lines(const std::string& text) {
  std::vector<std::string> lines;
  std::istringstream stream(text);
  std::string line;
  while (std::getline(stream, line)) {
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    lines.push_back(line);
  }
  return lines;
}

std::unordered_map<std::string, std::string> parse_key_values(
    const std::string& text) {
  std::unordered_map<std::string, std::string> result;
  for (const std::string& line : split_lines(text)) {
    const size_t pos = line.find('=');
    if (pos == std::string::npos || pos == 0) {
      continue;
    }
    result[line.substr(0, pos)] = line.substr(pos + 1);
  }
  return result;
}

// ---- method-call argument helpers -----------------------------------------

const StandardValue* arg_value(const MethodCall& call, const char* key) {
  const StandardValue::Map* map = call.arguments.map();
  if (map == nullptr) {
    return nullptr;
  }
  for (const auto& [k, v] : *map) {
    const std::string* name = k.string();
    if (name != nullptr && *name == key) {
      return &v;
    }
  }
  return nullptr;
}

const std::string* string_arg(const MethodCall& call, const char* key) {
  const StandardValue* value = arg_value(call, key);
  return value == nullptr ? nullptr : value->string();
}

std::optional<int64_t> int_arg(const MethodCall& call, const char* key) {
  const StandardValue* value = arg_value(call, key);
  if (value == nullptr) {
    return std::nullopt;
  }
  const int64_t* integer = value->integer();
  if (integer == nullptr) {
    return std::nullopt;
  }
  return *integer;
}

bool bool_arg(const MethodCall& call, const char* key, bool fallback) {
  const StandardValue* value = arg_value(call, key);
  if (value == nullptr) {
    return fallback;
  }
  const bool* boolean = value->boolean();
  return boolean == nullptr ? fallback : *boolean;
}

// App ids are used as path components; reject anything that could escape the
// registry directory.
bool is_safe_app_id(const std::string& id) {
  if (id.empty() || id == "." || id == "..") {
    return false;
  }
  return id.find('/') == std::string::npos &&
         id.find('\\') == std::string::npos;
}

// ---- pinned-app state ------------------------------------------------------

std::string pinned_file(const ServicePaths& paths) {
  return (fs::path(paths.config_dir) / "pinned").string();
}

std::set<std::string> read_pinned(const ServicePaths& paths) {
  std::set<std::string> pinned;
  const std::optional<std::string> content = read_file(pinned_file(paths));
  if (!content.has_value()) {
    return pinned;
  }
  for (const std::string& line : split_lines(*content)) {
    const std::string id = trim(line);
    if (!id.empty()) {
      pinned.insert(id);
    }
  }
  return pinned;
}

bool write_pinned(const ServicePaths& paths, const std::set<std::string>& ids) {
  if (!ensure_dir(paths.config_dir)) {
    return false;
  }
  std::string content;
  for (const std::string& id : ids) {
    content += id;
    content += '\n';
  }
  return write_file(pinned_file(paths), content);
}

// ---- pluto/session -------------------------------------------------------

void request_shutdown(ChannelRegistry* registry) {
  if (registry->context().request_shutdown) {
    registry->context().request_shutdown();
  }
}

void request_handoff(ChannelRegistry* registry) {
  if (registry->context().request_hibernate) {
    registry->context().request_hibernate();
  } else {
    request_shutdown(registry);
  }
}

PlatformResponse session_write_control(ChannelRegistry* registry,
                                       const ServicePaths& paths,
                                       const char* leaf,
                                       const std::string& content,
                                       StandardValue reply) {
  if (!ensure_dir(paths.run_dir) ||
      !write_file((fs::path(paths.run_dir) / leaf).string(), content)) {
    return standard_error("io",
                          std::string("Unable to write control file ") + leaf);
  }
  request_handoff(registry);
  return standard_success(reply);
}

PlatformResponse handle_session(ChannelRegistry* registry,
                                const ServicePaths& paths,
                                const MethodCall& call) {
  if (call.method == "powerMenuInfo") {
    const std::optional<std::string> content =
        read_file((fs::path(paths.run_dir) / "power-menu-active").string());
    if (!content.has_value()) {
      return standard_success(make_map({{"active", false}}));
    }
    const std::vector<std::string> lines = split_lines(*content);
    if (lines.empty() || !is_safe_app_id(trim(lines.front()))) {
      return standard_error("invalid-state",
                            "Power menu state has no valid origin app");
    }
    return standard_success(make_map({
        {"active", true},
        {"originAppId", trim(lines.front())},
    }));
  }
  if (call.method == "statusInfo") {
    const std::optional<std::string> content =
        read_file((fs::path(paths.run_dir) / "status-active").string());
    if (!content.has_value()) {
      return standard_success(make_map({{"active", false}}));
    }
    const std::vector<std::string> lines = split_lines(*content);
    if (lines.empty() || !is_safe_app_id(trim(lines.front()))) {
      return standard_error("invalid-state",
                            "Status shade state has no valid origin app");
    }
    const std::string origin = trim(lines.front());
    return standard_success(make_map({
        {"active", true},
        {"originAppId", origin},
        {"previewPath",
         (fs::path(paths.run_dir) / "previews" / (origin + ".bmp")).string()},
    }));
  }
  if (call.method == "switcherInfo") {
    const std::optional<std::string> content =
        read_file((fs::path(paths.run_dir) / "switcher-active").string());
    if (!content.has_value()) {
      return standard_success(make_map({{"active", false}}));
    }
    const std::vector<std::string> lines = split_lines(*content);
    if (lines.empty() || !is_safe_app_id(trim(lines.front()))) {
      return standard_error("invalid-state",
                            "App switcher state has no valid origin app");
    }
    const std::string origin = trim(lines.front());
    StandardValue::List apps;
    for (size_t i = 1; i < lines.size(); ++i) {
      const std::string id = trim(lines[i]);
      if (!is_safe_app_id(id) || id == origin ||
          id == "dev.pluto.launcher") {
        continue;
      }
      apps.push_back(make_map({
          {"appId", id},
          {"previewPath",
           (fs::path(paths.run_dir) / "previews" / (id + ".bmp")).string()},
      }));
    }
    return standard_success(make_map({
        {"active", true},
        {"originAppId", origin},
        {"apps", StandardValue(std::move(apps))},
    }));
  }
  if (call.method == "systemUiReady") {
    if (!registry->context().system_ui_ready) {
      return standard_error("unavailable",
                            "System UI presentation gate is unavailable");
    }
    if (!registry->context().system_ui_ready()) {
      return standard_error("not-ready",
                            "System UI frame could not be presented");
    }
    return standard_success(make_map({{"ok", true}}));
  }
  if (call.method == "forceStop") {
    const std::string* app_id = string_arg(call, "appId");
    if (app_id == nullptr || !is_safe_app_id(*app_id) ||
        *app_id == "dev.pluto.launcher") {
      return standard_error("bad-args",
                            "forceStop requires a non-launcher appId");
    }
    if (!ensure_dir(paths.run_dir) ||
        !write_file_atomic((fs::path(paths.run_dir) / "force-stop").string(),
                           *app_id + "\n")) {
      return standard_error("io", "Unable to publish force-stop request");
    }
    // The switcher launcher stays foreground. Its supervisor monitor consumes
    // this marker and terminates the selected background process in place.
    return standard_success(make_map({{"ok", true}}));
  }
  if (call.method == "launch") {
    const std::string* app_id = string_arg(call, "appId");
    if (app_id == nullptr || !is_safe_app_id(*app_id)) {
      return standard_error("bad-args", "launch requires a valid appId");
    }
    return session_write_control(registry, paths, "launch", *app_id,
                                 make_map({{"ok", true}}));
  }
  if (call.method == "cancelLaunch") {
    std::error_code ec;
    fs::remove(fs::path(paths.run_dir) / "launch", ec);
    return standard_success();
  }
  if (call.method == "home") {
    return session_write_control(registry, paths, "home", "", StandardValue());
  }
  if (call.method == "exitToStock") {
    if (!ensure_dir(paths.run_dir) ||
        !write_file((fs::path(paths.run_dir) / "stock").string(), "")) {
      return standard_error("io", "Unable to write control file stock");
    }
    request_shutdown(registry);
    return standard_success();
  }
  if (call.method == "powerOff") {
    if (paths.app_id != "dev.pluto.launcher" ||
        !fs::exists(fs::path(paths.run_dir) / "power-menu-active")) {
      return standard_error(
          "not-authorized",
          "Power off is available only from the active launcher power menu");
    }
    if (!ensure_dir(paths.run_dir) ||
        !write_file_atomic(
            (fs::path(paths.run_dir) / "poweroff").string(), "ui\n")) {
      return standard_error("io", "Unable to publish power-off request");
    }
    request_handoff(registry);
    return standard_success(make_map({{"ok", true}}));
  }
  if (call.method == "sleepNow") {
    const std::optional<int64_t> raw = read_int_file(
        (fs::path(paths.backlight_dir) / "brightness").string());
    if (!raw.has_value() || *raw < 0) {
      return standard_error(
          "unavailable",
          "Cannot enter standby without capturing frontlight brightness");
    }
    if (!ensure_dir(paths.run_dir) ||
        !write_file_atomic(
            (fs::path(paths.run_dir) / "standby-frontlight").string(),
            std::to_string(*raw) + "\n")) {
      return standard_error("io", "Unable to persist standby frontlight");
    }
    return session_write_control(registry, paths, "standby", "launcher\n",
                                 make_map({{"ok", true}}));
  }
  if (call.method == "suspendNow") {
    // VCOM disable normally starts a 30-second delayed VPDD-off timer. The
    // regulator rejects system suspend while that timer is pending, so change
    // its configured hold length while the CRTC is still active. The next
    // normal presenter open reapplies the standard 30000 ms value.
    const std::optional<int64_t> vpdd_length =
        read_int_file(paths.vpdd_length_file);
    if (!vpdd_length.has_value() || *vpdd_length < 0) {
      return standard_error("unavailable",
                            "Unable to read the VPDD hold length");
    }
    const fs::path suspend_marker = fs::path(paths.run_dir) / "suspend";
    if (!ensure_dir(paths.run_dir) ||
        !write_file(suspend_marker.string(), "system\n")) {
      return standard_error("io", "Unable to write control file suspend");
    }
    if (!write_file(paths.vpdd_length_file, "0\n")) {
      std::error_code ec;
      fs::remove(suspend_marker, ec);
      return standard_error("io", "Unable to prepare VPDD for standby");
    }
    request_shutdown(registry);
    return standard_success(make_map({{"ok", true}}));
  }
  if (call.method == "info") {
    const ChannelContext& ctx = registry->context();
    return standard_success(make_map({
        {"plutoVersion", "0.1.0"},
        {"presenter", ctx.presenter_name},
    }));
  }
  if (call.method == "developerStats") {
    return standard_success(make_map({
        {"renderer", registry->context().presenter_name},
    }));
  }
  return standard_unimplemented(call.method);
}

// ---- pluto/settings ------------------------------------------------------

int64_t frontlight_max(const ServicePaths& paths) {
  const std::optional<int64_t> max = read_int_file(
      (fs::path(paths.backlight_dir) / "max_brightness").string());
  return max.has_value() && *max > 0 ? *max : 2047;
}

PlatformResponse settings_frontlight_get(const ServicePaths& paths) {
  const std::optional<int64_t> raw =
      read_int_file((fs::path(paths.backlight_dir) / "brightness").string());
  if (!raw.has_value()) {
    return standard_error("unavailable", "Frontlight sysfs is unreadable");
  }
  return standard_success(
      make_map({{"raw", *raw}, {"max", frontlight_max(paths)}}));
}

PlatformResponse settings_frontlight_set(const ServicePaths& paths,
                                         const MethodCall& call) {
  const std::optional<int64_t> raw = int_arg(call, "raw");
  if (!raw.has_value()) {
    return standard_error("bad-args", "frontlightSet requires an int raw");
  }
  const int64_t clamped = std::clamp<int64_t>(*raw, 0, frontlight_max(paths));
  if (!write_file((fs::path(paths.backlight_dir) / "brightness").string(),
                  std::to_string(clamped))) {
    return standard_error("unavailable", "Frontlight sysfs is unwritable");
  }
  return standard_success();
}

std::optional<std::string> wpa_request(const ServicePaths& paths,
                                       const std::string& command) {
  return WpaSupplicantClient(paths.wpa_control_dir, paths.wifi_interface)
      .request(command);
}

bool wpa_ok(const std::optional<std::string>& response) {
  return response.has_value() && trim(*response) == "OK";
}

std::vector<std::string> split_fields(const std::string& line,
                                      const char separator) {
  std::vector<std::string> fields;
  size_t begin = 0;
  while (true) {
    const size_t end = line.find(separator, begin);
    fields.push_back(line.substr(begin, end - begin));
    if (end == std::string::npos) {
      break;
    }
    begin = end + 1;
  }
  return fields;
}

int hex_digit(const char value) {
  if (value >= '0' && value <= '9') {
    return value - '0';
  }
  if (value >= 'a' && value <= 'f') {
    return value - 'a' + 10;
  }
  if (value >= 'A' && value <= 'F') {
    return value - 'A' + 10;
  }
  return -1;
}

// wpa_supplicant renders non-printable SSID bytes as \xNN and escapes a small
// set of characters. Decode that representation before sending it to Dart.
std::string decode_wpa_text(const std::string& value) {
  std::string decoded;
  decoded.reserve(value.size());
  for (size_t index = 0; index < value.size(); ++index) {
    if (value[index] != '\\' || index + 1 >= value.size()) {
      decoded += value[index];
      continue;
    }
    const char escaped = value[++index];
    if (escaped == 'x' && index + 2 < value.size()) {
      const int high = hex_digit(value[index + 1]);
      const int low = hex_digit(value[index + 2]);
      if (high >= 0 && low >= 0) {
        decoded += static_cast<char>((high << 4) | low);
        index += 2;
        continue;
      }
    }
    switch (escaped) {
      case 'n':
        decoded += '\n';
        break;
      case 'r':
        decoded += '\r';
        break;
      case 't':
        decoded += '\t';
        break;
      case 'e':
        decoded += static_cast<char>(27);
        break;
      default:
        decoded += escaped;
        break;
    }
  }
  return decoded;
}

std::string hex_encode(const std::string& value) {
  static constexpr char kHex[] = "0123456789abcdef";
  std::string encoded;
  encoded.reserve(value.size() * 2);
  for (const unsigned char byte : value) {
    encoded += kHex[byte >> 4];
    encoded += kHex[byte & 0x0f];
  }
  return encoded;
}

std::string wpa_quoted(const std::string& value) {
  std::string quoted = "\"";
  for (const char character : value) {
    if (character == '\\' || character == '"') {
      quoted += '\\';
    }
    quoted += character;
  }
  quoted += '"';
  return quoted;
}

std::unordered_map<std::string, std::string> wpa_properties(
    const std::string& response) {
  std::unordered_map<std::string, std::string> properties;
  for (const std::string& line : split_lines(response)) {
    const size_t separator = line.find('=');
    if (separator == std::string::npos || separator == 0) {
      continue;
    }
    properties[line.substr(0, separator)] = line.substr(separator + 1);
  }
  return properties;
}

std::string wpa_security(const std::string& flags) {
  if (flags.find("SAE") != std::string::npos) {
    return "sae";
  }
  if (flags.find("EAP") != std::string::npos ||
      flags.find("IEEE8021X") != std::string::npos) {
    return "wpaEap";
  }
  if (flags.find("WEP") != std::string::npos) {
    return "wep";
  }
  if (flags.find("WPA") != std::string::npos ||
      flags.find("PSK") != std::string::npos) {
    return "wpaPsk";
  }
  if (flags.empty() || flags == "[ESS]") {
    return "open";
  }
  return "unknown";
}

int64_t signal_percent(const std::string& dbm_text) {
  char* end = nullptr;
  const long dbm = std::strtol(dbm_text.c_str(), &end, 10);
  if (end == dbm_text.c_str()) {
    return 0;
  }
  return std::clamp<int64_t>((static_cast<int64_t>(dbm) + 100) * 2, 0,
                             100);
}

struct WpaNetwork {
  std::string ssid;
  std::string bssid;
  int64_t signal = 0;
  std::string security;
  std::string flags;
  bool active = false;
};

struct WpaKnownNetwork {
  int id = -1;
  std::string ssid;
  std::string flags;
  bool current = false;
};

std::optional<std::vector<WpaNetwork>> wpa_networks(
    const ServicePaths& paths) {
  const std::optional<std::string> response =
      wpa_request(paths, "SCAN_RESULTS");
  if (!response.has_value() || response->rfind("FAIL", 0) == 0) {
    return std::nullopt;
  }
  std::vector<WpaNetwork> networks;
  const std::vector<std::string> lines = split_lines(*response);
  for (size_t index = 1; index < lines.size(); ++index) {
    const std::vector<std::string> fields = split_fields(lines[index], '\t');
    if (fields.size() < 5) {
      continue;
    }
    const std::string ssid = decode_wpa_text(fields[4]);
    if (ssid.empty()) {
      continue;
    }
    networks.push_back(WpaNetwork{ssid, fields[0], signal_percent(fields[2]),
                                  wpa_security(fields[3]), fields[3], false});
  }
  return networks;
}

std::optional<std::vector<WpaKnownNetwork>> wpa_known_networks(
    const ServicePaths& paths) {
  const std::optional<std::string> response =
      wpa_request(paths, "LIST_NETWORKS");
  if (!response.has_value() || response->rfind("FAIL", 0) == 0) {
    return std::nullopt;
  }
  std::vector<WpaKnownNetwork> networks;
  const std::vector<std::string> lines = split_lines(*response);
  for (size_t index = 1; index < lines.size(); ++index) {
    const std::vector<std::string> fields = split_fields(lines[index], '\t');
    if (fields.size() < 4) {
      continue;
    }
    char* end = nullptr;
    const long id = std::strtol(fields[0].c_str(), &end, 10);
    if (end == fields[0].c_str() || id < 0) {
      continue;
    }
    networks.push_back(WpaKnownNetwork{
        static_cast<int>(id), decode_wpa_text(fields[1]),
        fields[3],
        fields[3].find("[CURRENT]") != std::string::npos});
  }
  return networks;
}

bool is_wifi_setting(const std::string& line) {
  const std::string text = trim(line);
  if (text.empty() || text[0] == '#' || text[0] == ';') {
    return false;
  }
  const size_t equals = text.find('=');
  return equals != std::string::npos && trim(text.substr(0, equals)) == "wifi";
}

bool wifi_setting_is_off(const ServicePaths& paths) {
  const std::optional<std::string> settings =
      read_file(paths.wifi_settings_file);
  if (!settings.has_value()) {
    return false;
  }
  for (const std::string& line : split_lines(*settings)) {
    if (!is_wifi_setting(line)) {
      continue;
    }
    const size_t equals = line.find('=');
    if (equals != std::string::npos && trim(line.substr(equals + 1)) == "off") {
      return true;
    }
  }
  return false;
}

std::string wifi_settings_with_enabled(const std::string& settings,
                                       const bool enabled) {
  std::string updated;
  for (const std::string& line : split_lines(settings)) {
    if (!is_wifi_setting(line)) {
      updated += line + "\n";
    }
  }
  updated += std::string("wifi = ") + (enabled ? "on\n" : "off\n");
  return updated;
}

std::string interface_ipv4_address(const std::string& interface_name) {
  ifaddrs* raw_addresses = nullptr;
  if (::getifaddrs(&raw_addresses) != 0 || raw_addresses == nullptr) {
    return "";
  }
  std::string address;
  for (const ifaddrs* current = raw_addresses; current != nullptr;
       current = current->ifa_next) {
    if (current->ifa_addr == nullptr || current->ifa_name == nullptr ||
        interface_name != current->ifa_name ||
        current->ifa_addr->sa_family != AF_INET) {
      continue;
    }
    char buffer[INET_ADDRSTRLEN] = {};
    const auto* ipv4 =
        reinterpret_cast<const sockaddr_in*>(current->ifa_addr);
    if (::inet_ntop(AF_INET, &ipv4->sin_addr, buffer, sizeof(buffer)) !=
        nullptr) {
      address = buffer;
      break;
    }
  }
  ::freeifaddrs(raw_addresses);
  return address;
}

enum class WifiStateKind { kDisabled, kDisconnected, kConnecting, kConnected };

struct WifiState {
  WifiStateKind kind = WifiStateKind::kDisconnected;
  std::string ssid;
  std::string ip_address;
  double signal = 0.0;
};

std::optional<WifiState> read_wifi_state(const ServicePaths& paths) {
  const std::optional<std::string> response = wpa_request(paths, "STATUS");
  if (!response.has_value()) {
    if (wifi_setting_is_off(paths)) {
      return WifiState{WifiStateKind::kDisabled, "", "", 0.0};
    }
    return std::nullopt;
  }
  if (response->rfind("FAIL", 0) == 0) {
    return std::nullopt;
  }
  const std::unordered_map<std::string, std::string> status =
      wpa_properties(*response);
  const auto state_it = status.find("wpa_state");
  if (state_it == status.end()) {
    return std::nullopt;
  }
  const std::string& state = state_it->second;
  if (state == "AUTHENTICATING" || state == "ASSOCIATING" ||
      state == "ASSOCIATED" || state == "4WAY_HANDSHAKE" ||
      state == "GROUP_HANDSHAKE") {
    const auto ssid = status.find("ssid");
    return WifiState{WifiStateKind::kConnecting,
                     ssid == status.end() ? ""
                                          : decode_wpa_text(ssid->second),
                     "", 0.0};
  }
  if (state != "COMPLETED") {
    return WifiState{WifiStateKind::kDisconnected, "", "", 0.0};
  }

  const auto ssid = status.find("ssid");
  std::string ip_address;
  const auto reported_ip = status.find("ip_address");
  if (reported_ip != status.end()) {
    ip_address = reported_ip->second;
  }
  if (ip_address.empty()) {
    ip_address = interface_ipv4_address(paths.wifi_interface);
  }
  // COMPLETED is only the link-layer association. Keep reporting connecting
  // until systemd-networkd has installed the DHCP address expected by callers.
  if (ip_address.empty()) {
    return WifiState{WifiStateKind::kConnecting,
                     ssid == status.end() ? ""
                                          : decode_wpa_text(ssid->second),
                     "", 0.0};
  }
  double signal = 0.0;
  const std::optional<std::string> signal_response =
      wpa_request(paths, "SIGNAL_POLL");
  if (signal_response.has_value()) {
    const auto values = wpa_properties(*signal_response);
    const auto rssi = values.find("RSSI");
    if (rssi != values.end()) {
      signal = static_cast<double>(signal_percent(rssi->second)) / 100.0;
    }
  }
  return WifiState{WifiStateKind::kConnected,
                   ssid == status.end() ? "" : decode_wpa_text(ssid->second),
                   ip_address, signal};
}

PlatformResponse settings_wifi_status(const ServicePaths& paths) {
  const std::optional<WifiState> state = read_wifi_state(paths);
  if (!state.has_value()) {
    return standard_error("unavailable",
                          "wpa_supplicant control socket is unavailable");
  }
  switch (state->kind) {
    case WifiStateKind::kDisabled:
      return standard_success(make_map({{"status", "disabled"}}));
    case WifiStateKind::kDisconnected:
      return standard_success(make_map({{"status", "disconnected"}}));
    case WifiStateKind::kConnecting:
      return standard_success(make_map(
          {{"status", "connecting"}, {"ssid", state->ssid}}));
    case WifiStateKind::kConnected:
      return standard_success(make_map({
          {"status", "connected"},
          {"ssid", state->ssid},
          {"ipAddress", state->ip_address},
          {"signal", state->signal},
      }));
  }
  return standard_error("unavailable", "Unknown wpa_supplicant state");
}

PlatformResponse settings_wifi_scan(const ServicePaths& paths) {
  const std::optional<std::string> response = wpa_request(paths, "SCAN");
  if (!response.has_value() ||
      (trim(*response) != "OK" && trim(*response) != "FAIL-BUSY")) {
    return standard_error("unavailable", "wpa_supplicant Wi-Fi scan failed");
  }
  return standard_success();
}

PlatformResponse settings_wifi_scan_results(const ServicePaths& paths) {
  const std::optional<std::vector<WpaNetwork>> found = wpa_networks(paths);
  if (!found.has_value()) {
    return standard_error("unavailable",
                          "wpa_supplicant Wi-Fi results are unavailable");
  }
  std::set<std::string> known_ssids;
  const std::optional<std::vector<WpaKnownNetwork>> known =
      wpa_known_networks(paths);
  if (!known.has_value()) {
    return standard_error("unavailable",
                          "wpa_supplicant saved networks are unavailable");
  }
  for (const WpaKnownNetwork& network : *known) {
    known_ssids.insert(network.ssid);
  }
  std::string active_ssid;
  std::string active_bssid;
  const std::optional<std::string> status_response =
      wpa_request(paths, "STATUS");
  if (status_response.has_value()) {
    const auto status = wpa_properties(*status_response);
    const auto state = status.find("wpa_state");
    if (state != status.end() && state->second == "COMPLETED") {
      const auto ssid = status.find("ssid");
      const auto bssid = status.find("bssid");
      active_ssid =
          ssid == status.end() ? "" : decode_wpa_text(ssid->second);
      active_bssid = bssid == status.end() ? "" : bssid->second;
    }
  }
  std::unordered_map<std::string, WpaNetwork> strongest;
  std::vector<std::string> order;
  for (WpaNetwork network : *found) {
    network.active = (!active_bssid.empty() && network.bssid == active_bssid) ||
                     (!active_ssid.empty() && network.ssid == active_ssid);
    const auto existing = strongest.find(network.ssid);
    if (existing == strongest.end()) {
      strongest[network.ssid] = network;
      order.push_back(network.ssid);
    } else if (network.signal > existing->second.signal) {
      network.active = network.active || existing->second.active;
      existing->second = network;
    } else if (network.active) {
      existing->second.active = true;
    }
  }
  std::sort(order.begin(), order.end(),
            [&strongest](const std::string& a, const std::string& b) {
              return strongest[a].signal > strongest[b].signal;
  });
  StandardValue::List networks;
  for (const std::string& ssid : order) {
    const WpaNetwork& network = strongest[ssid];
    networks.push_back(make_map({
        {"ssid", ssid},
        {"signal", static_cast<double>(network.signal) / 100.0},
        {"security", network.security},
        {"isKnown", known_ssids.count(ssid) != 0},
        {"isActive", network.active},
    }));
  }
  return standard_success(StandardValue(std::move(networks)));
}

PlatformResponse settings_wifi_connect(const ServicePaths& paths,
                                       const MethodCall& call) {
  const std::string* ssid = string_arg(call, "ssid");
  if (ssid == nullptr || ssid->empty()) {
    return standard_error("bad-args", "wifiConnect requires an ssid");
  }
  if (ssid->size() > 32) {
    return standard_error("bad-args", "Wi-Fi SSIDs are limited to 32 bytes");
  }
  const std::string* psk = string_arg(call, "psk");
  if (psk == nullptr) {
    psk = string_arg(call, "passphrase");
  }
  const bool has_psk = psk != nullptr && !psk->empty();
  if (has_psk && (psk->size() < 8 || psk->size() > 63)) {
    return standard_error("wifi.bad-passphrase",
                          "WPA passphrases must contain 8 to 63 bytes");
  }
  if (has_psk &&
      std::any_of(psk->begin(), psk->end(), [](const unsigned char byte) {
        return byte < 32 || byte > 126;
      })) {
    return standard_error("wifi.bad-passphrase",
                          "WPA passphrases must use printable characters");
  }

  const std::optional<std::vector<WpaKnownNetwork>> known =
      wpa_known_networks(paths);
  if (!known.has_value()) {
    return standard_error("unavailable",
                          "wpa_supplicant saved networks are unavailable");
  }
  int network_id = -1;
  for (const WpaKnownNetwork& network : *known) {
    if (network.ssid == *ssid) {
      network_id = network.id;
      break;
    }
  }
  const bool added = network_id < 0;
  if (added) {
    const std::optional<std::string> response =
        wpa_request(paths, "ADD_NETWORK");
    if (!response.has_value()) {
      return standard_error("wifi.connect-failed",
                            "wpa_supplicant could not add " + *ssid);
    }
    const std::string id_text = trim(*response);
    char* end = nullptr;
    const long parsed = std::strtol(id_text.c_str(), &end, 10);
    if (end == id_text.c_str() || *end != '\0' || parsed < 0) {
      return standard_error("wifi.connect-failed",
                            "wpa_supplicant could not add " + *ssid);
    }
    network_id = static_cast<int>(parsed);
  }

  const std::string id = std::to_string(network_id);
  const auto command_ok = [&paths](const std::string& command) {
    return wpa_ok(wpa_request(paths, command));
  };
  const auto rollback_added = [&paths, &id, added] {
    if (added) {
      wpa_request(paths, "REMOVE_NETWORK " + id);
    } else {
      wpa_request(paths, "RECONFIGURE");
    }
  };
  if (!command_ok("SET_NETWORK " + id + " ssid " + hex_encode(*ssid))) {
    rollback_added();
    return standard_error("wifi.connect-failed",
                          "wpa_supplicant rejected the SSID " + *ssid);
  }

  std::string security = has_psk ? "wpaPsk" : "open";
  const std::optional<std::vector<WpaNetwork>> scan = wpa_networks(paths);
  if (scan.has_value()) {
    for (const WpaNetwork& network : *scan) {
      if (network.ssid == *ssid) {
        security = network.security;
        break;
      }
    }
  }
  if (security == "wpaEap" || security == "wep" || security == "unknown") {
    rollback_added();
    return standard_error("wifi.unsupported-security",
                          "This Wi-Fi security mode is not supported yet");
  }
  if (security != "open" && !has_psk && added) {
    rollback_added();
    return standard_error("bad-args", "This Wi-Fi network requires a password");
  }
  if (has_psk) {
    const std::string key_management =
        security == "sae" ? "SAE WPA-PSK" : "WPA-PSK";
    if (!command_ok("SET_NETWORK " + id + " key_mgmt " + key_management) ||
        !command_ok("SET_NETWORK " + id + " psk " + wpa_quoted(*psk)) ||
        (security == "sae" &&
         !command_ok("SET_NETWORK " + id + " ieee80211w 1"))) {
      rollback_added();
      return standard_error("wifi.connect-failed",
                            "wpa_supplicant rejected the credentials for " +
                                *ssid);
    }
  } else if (added &&
             !command_ok("SET_NETWORK " + id + " key_mgmt NONE")) {
    rollback_added();
    return standard_error("wifi.connect-failed",
                          "wpa_supplicant rejected the open network " + *ssid);
  }

  const bool remember = bool_arg(call, "remember", true);
  if (!command_ok("SELECT_NETWORK " + id) ||
      !command_ok("ENABLE_NETWORK all") ||
      (remember && !command_ok("SAVE_CONFIG"))) {
    rollback_added();
    return standard_error("wifi.connect-failed",
                          "wpa_supplicant could not connect to " + *ssid);
  }
  return standard_success();
}

PlatformResponse settings_wifi_forget(const ServicePaths& paths,
                                      const MethodCall& call) {
  const std::string* ssid = string_arg(call, "ssid");
  if (ssid == nullptr || ssid->empty()) {
    return standard_error("bad-args", "wifiForget requires an ssid");
  }
  const std::optional<std::vector<WpaKnownNetwork>> known =
      wpa_known_networks(paths);
  if (!known.has_value()) {
    return standard_error("unavailable",
                          "wpa_supplicant saved networks are unavailable");
  }
  bool removed = false;
  for (const WpaKnownNetwork& network : *known) {
    if (network.ssid != *ssid) {
      continue;
    }
    if (!wpa_ok(wpa_request(paths,
                            "REMOVE_NETWORK " + std::to_string(network.id)))) {
      return standard_error("wifi.forget-failed",
                            "wpa_supplicant could not forget " + *ssid);
    }
    removed = true;
  }
  if (removed && !wpa_ok(wpa_request(paths, "SAVE_CONFIG"))) {
    return standard_error("wifi.forget-failed",
                          "wpa_supplicant could not persist the change");
  }
  // Forget is idempotent: a profile that disappeared between list/delete is
  // already in the requested state.
  return standard_success();
}

PlatformResponse settings_wifi_set_enabled(const ServicePaths& paths,
                                           const MethodCall& call) {
  const bool enabled = bool_arg(call, "enabled", true);
  const std::optional<std::string> previous =
      read_file(paths.wifi_settings_file);
  const fs::path settings_path(paths.wifi_settings_file);
  if (!ensure_dir(settings_path.parent_path().string()) ||
      !write_file_atomic(paths.wifi_settings_file,
                         wifi_settings_with_enabled(previous.value_or(""),
                                                    enabled))) {
    return standard_error("unavailable",
                          "The firmware Wi-Fi preference is unwritable");
  }
  const auto restore_preference = [&paths, &previous] {
    if (previous.has_value()) {
      write_file_atomic(paths.wifi_settings_file, *previous);
    } else {
      std::error_code ec;
      fs::remove(paths.wifi_settings_file, ec);
    }
  };
  const std::string action = enabled ? "start" : "stop";
  if (!run_command(shell_quote(paths.systemctl) + " " + action +
                   " wpa_supplicant.service")
           .has_value()) {
    restore_preference();
    return standard_error("unavailable",
                          "The firmware could not change the Wi-Fi radio state");
  }
  if (enabled) {
    bool ready = false;
    for (int attempt = 0; attempt < 20; ++attempt) {
      const std::optional<std::string> response = wpa_request(paths, "PING");
      if (response.has_value() && trim(*response) == "PONG") {
        ready = true;
        break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    if (!ready) {
      restore_preference();
      return standard_error("unavailable",
                            "wpa_supplicant did not become ready");
    }
  }
  return standard_success();
}

StandardValue wifi_connection_value(const WifiState& state) {
  return make_map({
      {"ssid", state.ssid},
      {"ipAddress", state.ip_address},
      {"signal", state.signal},
  });
}

PlatformResponse settings_wifi_is_enabled(const ServicePaths& paths) {
  const std::optional<WifiState> state = read_wifi_state(paths);
  if (!state.has_value()) {
    return standard_error("unavailable",
                          "wpa_supplicant control socket is unavailable");
  }
  return standard_success(state->kind != WifiStateKind::kDisabled);
}

PlatformResponse settings_wifi_active(const ServicePaths& paths) {
  const std::optional<WifiState> state = read_wifi_state(paths);
  if (!state.has_value()) {
    return standard_error("unavailable",
                          "wpa_supplicant control socket is unavailable");
  }
  if (state->kind != WifiStateKind::kConnected) {
    return standard_success();
  }
  return standard_success(wifi_connection_value(*state));
}

PlatformResponse settings_wifi_scan_combined(const ServicePaths& paths,
                                             const MethodCall& call) {
  const PlatformResponse trigger = settings_wifi_scan(paths);
  if (trigger.empty() || trigger[0] != 0) {
    return trigger;
  }
  const int64_t requested_ms = int_arg(call, "timeoutMs").value_or(2500);
  const int64_t settle_ms = std::clamp<int64_t>(requested_ms, 0, 2500);
  if (settle_ms > 0) {
    std::this_thread::sleep_for(std::chrono::milliseconds(settle_ms));
  }
  return settings_wifi_scan_results(paths);
}

bool network_is_temporarily_disabled(const ServicePaths& paths,
                                     const std::string& ssid) {
  const std::optional<std::vector<WpaKnownNetwork>> known =
      wpa_known_networks(paths);
  if (!known.has_value()) {
    return false;
  }
  for (const WpaKnownNetwork& network : *known) {
    if (network.ssid == ssid &&
        network.flags.find("[TEMP-DISABLED]") != std::string::npos) {
      return true;
    }
  }
  return false;
}

PlatformResponse settings_wifi_connect_and_wait(const ServicePaths& paths,
                                                const MethodCall& call) {
  const PlatformResponse started = settings_wifi_connect(paths, call);
  if (started.empty() || started[0] != 0) {
    return started;
  }
  const std::string* ssid = string_arg(call, "ssid");
  if (ssid == nullptr) {
    return standard_error("bad-args", "wifi.connect requires an ssid");
  }
  const int64_t requested_ms = int_arg(call, "timeoutMs").value_or(45000);
  const int64_t timeout_ms = std::clamp<int64_t>(requested_ms, 0, 60000);
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(timeout_ms);
  while (true) {
    const std::optional<WifiState> state = read_wifi_state(paths);
    if (state.has_value() && state->kind == WifiStateKind::kConnected &&
        state->ssid == *ssid) {
      return standard_success(wifi_connection_value(*state));
    }
    if (state.has_value() && state->kind == WifiStateKind::kDisabled) {
      return standard_error("wifi.radio-disabled", "Wi-Fi is disabled");
    }
    if (network_is_temporarily_disabled(paths, *ssid)) {
      return standard_error("wifi.bad-passphrase",
                            "Wi-Fi authentication was rejected");
    }
    if (std::chrono::steady_clock::now() >= deadline) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
  }
  return standard_error("wifi.timeout", "Timed out connecting to " + *ssid);
}

PlatformResponse settings_wifi_disconnect(const ServicePaths& paths) {
  if (!wpa_ok(wpa_request(paths, "DISCONNECT"))) {
    return standard_error("unavailable",
                          "wpa_supplicant could not disconnect Wi-Fi");
  }
  return standard_success();
}

PlatformResponse settings_wifi_known(const ServicePaths& paths) {
  const std::optional<std::vector<WpaKnownNetwork>> known =
      wpa_known_networks(paths);
  if (!known.has_value()) {
    return standard_error("unavailable",
                          "wpa_supplicant saved networks are unavailable");
  }
  StandardValue::List result;
  for (const WpaKnownNetwork& network : *known) {
    const std::optional<std::string> key_management = wpa_request(
        paths, "GET_NETWORK " + std::to_string(network.id) + " key_mgmt");
    std::string security = "unknown";
    if (key_management.has_value()) {
      const std::string value = trim(*key_management);
      security = value == "NONE" ? "open" : wpa_security(value);
    }
    result.push_back(
        make_map({{"ssid", network.ssid}, {"security", security}}));
  }
  return standard_success(StandardValue(std::move(result)));
}

std::optional<std::string> active_usb_interface(const ServicePaths& paths) {
  std::error_code ec;
  fs::directory_iterator it(paths.network_class_dir, ec);
  const fs::directory_iterator end;
  while (!ec && it != end) {
    const fs::path interface = it->path();
    const std::string name = interface.filename().string();
    if (name.rfind(paths.usb_interface_prefix, 0) == 0) {
      const std::optional<int64_t> carrier =
          read_int_file((interface / "carrier").string());
      const std::string operstate =
          trim(read_file((interface / "operstate").string()).value_or(""));
      // When sysfs exposes carrier it is authoritative. Some USB gadget
      // interfaces report operstate=up while no host is attached; use that
      // weaker signal only on kernels that do not expose a carrier value.
      const bool connected = carrier.has_value() ? *carrier == 1
                                                  : operstate == "up";
      if (connected) {
        return name;
      }
    }
    it.increment(ec);
  }
  return std::nullopt;
}

PlatformResponse settings_network_info(const ServicePaths& paths) {
  const std::optional<std::string> usb = active_usb_interface(paths);
  const std::optional<WifiState> wifi = read_wifi_state(paths);
  const std::string wifi_ip =
      wifi.has_value() && wifi->kind == WifiStateKind::kConnected
          ? wifi->ip_address
          : "";
  return standard_success(make_map({
      {"usbConnected", usb.has_value()},
      {"usbInterface", usb.value_or("")},
      {"usbIp", usb.has_value() ? "10.11.99.1" : ""},
      {"wifiIp", wifi_ip},
  }));
}

PlatformResponse settings_battery_get(const ServicePaths& paths) {
  int64_t level = -1;
  int64_t marker_level = -1;
  bool charging = false;
  bool usb_present = false;
  std::error_code ec;
  fs::directory_iterator it(paths.power_supply_dir, ec);
  const fs::directory_iterator end;
  while (!ec && it != end) {
    const fs::path supply = it->path();
    const std::string type =
        trim(read_file((supply / "type").string()).value_or(""));
    const bool marker_supply =
        type == "Wireless" ||
        supply.filename().string().find("marker") != std::string::npos;
    if (marker_supply) {
      const std::optional<int64_t> capacity =
          read_int_file((supply / "capacity").string());
      // Some models expose both a zero-valued NFC cell and the actual marker
      // battery. Retain the strongest candidate when several marker supplies
      // exist, while preserving 0% as a truthful value when it is the only
      // attached marker telemetry.
      if (capacity.has_value() && *capacity > marker_level) {
        marker_level = std::clamp<int64_t>(*capacity, 0, 100);
      }
    } else if (type == "Battery" && level < 0) {
      const std::optional<int64_t> capacity =
          read_int_file((supply / "capacity").string());
      if (capacity.has_value()) {
        level = std::clamp<int64_t>(*capacity, 0, 100);
        const std::string status =
            trim(read_file((supply / "status").string()).value_or(""));
        charging = status == "Charging" || status == "Full";
      }
    } else if (type == "USB" || type == "Mains") {
      if (read_int_file((supply / "online").string()).value_or(0) == 1) {
        usb_present = true;
      }
    }
    it.increment(ec);
  }
  if (level < 0) {
    return standard_error("unavailable", "No battery telemetry");
  }
  StandardValue::Map values{
      {"levelPercent", level},
      {"isCharging", charging},
      {"isUsbPowerPresent", usb_present},
      {"isUsbNetworkConnected", active_usb_interface(paths).has_value()},
  };
  if (marker_level >= 0) {
    values.emplace_back("markerLevelPercent", marker_level);
  }
  return standard_success(StandardValue(std::move(values)));
}

std::string pin_file(const ServicePaths& paths) {
  return (fs::path(paths.config_dir) / "pin").string();
}

std::string rotation_file(const ServicePaths& paths) {
  return (fs::path(paths.config_dir) / "rotation").string();
}

PlatformResponse settings_pin_set(const ServicePaths& paths,
                                  const MethodCall& call) {
  const std::string* digits = string_arg(call, "digits");
  if (digits == nullptr || digits->size() < 4 || digits->size() > 8 ||
      digits->find_first_not_of("0123456789") != std::string::npos) {
    return standard_error("bad-args", "PIN must be 4-8 digits");
  }
  if (!ensure_dir(paths.config_dir) || !write_file(pin_file(paths), *digits)) {
    return standard_error("io", "Unable to persist PIN");
  }
  ::chmod(pin_file(paths).c_str(), 0600);
  return standard_success();
}

PlatformResponse handle_settings(const ServicePaths& paths,
                                 const MethodCall& call) {
  if (call.method == "frontlightGet") {
    return settings_frontlight_get(paths);
  }
  if (call.method == "frontlightSet") {
    return settings_frontlight_set(paths, call);
  }
  if (call.method == "wifiStatus") {
    return settings_wifi_status(paths);
  }
  if (call.method == "wifiScan") {
    return settings_wifi_scan(paths);
  }
  if (call.method == "wifiScanResults") {
    return settings_wifi_scan_results(paths);
  }
  if (call.method == "wifiConnect") {
    return settings_wifi_connect(paths, call);
  }
  if (call.method == "wifiForget") {
    return settings_wifi_forget(paths, call);
  }
  if (call.method == "wifiSetEnabled") {
    return settings_wifi_set_enabled(paths, call);
  }
  // Canonical pluto_settings protocol. The camelCase methods above remain
  // as a compatibility surface for the current launcher while it migrates.
  if (call.method == "wifi.isEnabled") {
    return settings_wifi_is_enabled(paths);
  }
  if (call.method == "wifi.setEnabled") {
    return settings_wifi_set_enabled(paths, call);
  }
  if (call.method == "wifi.scan") {
    return settings_wifi_scan_combined(paths, call);
  }
  if (call.method == "wifi.active") {
    return settings_wifi_active(paths);
  }
  if (call.method == "wifi.connect") {
    return settings_wifi_connect_and_wait(paths, call);
  }
  if (call.method == "wifi.disconnect") {
    return settings_wifi_disconnect(paths);
  }
  if (call.method == "wifi.forget") {
    return settings_wifi_forget(paths, call);
  }
  if (call.method == "wifi.known") {
    return settings_wifi_known(paths);
  }
  if (call.method == "networkInfo") {
    return settings_network_info(paths);
  }
  if (call.method == "standbySet") {
    const std::optional<int64_t> ms = int_arg(call, "ms");
    if (!ms.has_value()) {
      return standard_error("bad-args", "standbySet requires an int ms");
    }
    if (!ensure_dir(paths.config_dir) ||
        !write_file((fs::path(paths.config_dir) / "standby_ms").string(),
                    std::to_string(*ms))) {
      return standard_error("io", "Unable to persist standby timeout");
    }
    return standard_success();
  }
  if (call.method == "rotationGet") {
    const std::string value =
        trim(read_file(rotation_file(paths)).value_or("auto"));
    if (value == "portrait" || value == "landscape" || value == "auto") {
      return standard_success(value);
    }
    // Invalid or legacy state must not leave the device stuck in one mode.
    return standard_success("auto");
  }
  if (call.method == "rotationSet") {
    const std::string* value = string_arg(call, "value");
    if (value == nullptr || (*value != "portrait" && *value != "landscape" &&
                             *value != "auto")) {
      return standard_error(
          "bad-args", "rotationSet requires portrait, landscape, or auto");
    }
    if (!ensure_dir(paths.config_dir) ||
        !write_file_atomic(rotation_file(paths), *value + "\n")) {
      return standard_error("io", "Unable to persist rotation preference");
    }
    return standard_success();
  }
  if (call.method == "batteryGet") {
    return settings_battery_get(paths);
  }
  if (call.method == "pinIsSet") {
    const std::optional<std::string> pin = read_file(pin_file(paths));
    return standard_success(pin.has_value() && !trim(*pin).empty());
  }
  if (call.method == "pinSet") {
    return settings_pin_set(paths, call);
  }
  if (call.method == "pinRemove") {
    std::error_code ec;
    fs::remove(pin_file(paths), ec);
    return standard_success();
  }
  return standard_unimplemented(call.method);
}

// ---- pluto/core ----------------------------------------------------------

StandardValue capability_list(const ChannelContext& ctx) {
  StandardValue::List capabilities{"frontlight", "wifi", "devicePin",
                                   "powerPolicy"};
  if (ctx.is_color) {
    capabilities.push_back("colorPanel");
  }
  return StandardValue(std::move(capabilities));
}

PlatformResponse handle_core(ChannelRegistry* registry,
                             const MethodCall& call) {
  if (call.method == "handshake") {
    return standard_success(make_map({
        {"protocol", int64_t{1}},
        {"embedderVersion", "0.1.0"},
        {"presenter", registry->context().presenter_name},
    }));
  }
  if (call.method == "capabilities") {
    return standard_success(capability_list(registry->context()));
  }
  return standard_unimplemented(call.method);
}

// ---- pluto/device --------------------------------------------------------

std::string unquote(const std::string& value) {
  if (value.size() >= 2 && value.front() == '"' && value.back() == '"') {
    return value.substr(1, value.size() - 2);
  }
  return value;
}

std::string os_release_value(
    const std::unordered_map<std::string, std::string>& kv,
    std::initializer_list<const char*> keys) {
  for (const char* key : keys) {
    const auto it = kv.find(key);
    if (it != kv.end() && !it->second.empty()) {
      return unquote(it->second);
    }
  }
  return "unknown";
}

PlatformResponse device_info(ChannelRegistry* registry,
                             const ServicePaths& paths) {
  const ChannelContext& ctx = registry->context();
  std::string firmware = "unknown";
  std::string os_version = "unknown";
  const std::optional<std::string> os_release =
      read_file(paths.os_release_file);
  if (os_release.has_value()) {
    const auto kv = parse_key_values(*os_release);
    firmware = os_release_value(kv, {"BUILD_ID", "IMG_VERSION", "VERSION_ID"});
    os_version = os_release_value(kv, {"VERSION_ID", "VERSION", "IMG_VERSION"});
  }
  StandardValue serial;
  if (!paths.serial_command.empty()) {
    const std::optional<std::string> out = run_command(paths.serial_command);
    if (out.has_value()) {
      const std::string trimmed = trim(*out);
      if (!trimmed.empty()) {
        serial = StandardValue(trimmed);
      }
    }
  }
  return standard_success(make_map({
      {"model", ctx.device_model},
      {"codename", ctx.device_codename},
      {"firmwareBuild", firmware},
      {"osVersion", os_version},
      {"panel", make_map({
                    {"width", static_cast<int64_t>(ctx.panel_width)},
                    {"height", static_cast<int64_t>(ctx.panel_height)},
                    {"dpi", static_cast<int64_t>(ctx.dpi)},
                    {"pixelFormat", ctx.pixel_format},
                    {"colorMode", ctx.is_color ? "gallery3" : "monochrome"},
                })},
      {"serialNumber", serial},
  }));
}

PlatformResponse device_temperature(const ServicePaths& paths) {
  std::vector<std::pair<std::string, double>> readings;
  std::error_code ec;
  fs::directory_iterator it(paths.hwmon_dir, ec);
  const fs::directory_iterator end;
  while (!ec && it != end) {
    const fs::path entry = it->path();
    const std::optional<int64_t> milli_c =
        read_int_file((entry / "temp1_input").string());
    if (milli_c.has_value()) {
      std::string name =
          trim(read_file((entry / "name").string()).value_or(""));
      if (name.empty()) {
        name = entry.filename().string();
      }
      readings.emplace_back(std::move(name),
                            static_cast<double>(*milli_c) / 1000.0);
    }
    it.increment(ec);
  }
  if (readings.empty()) {
    return standard_error("unavailable", "No temperature sensors");
  }
  std::sort(readings.begin(), readings.end());
  StandardValue::List sensors;
  for (const auto& [name, celsius] : readings) {
    sensors.push_back(make_map({{"name", name}, {"celsius", celsius}}));
  }
  return standard_success(make_map({
      {"celsius", readings.front().second},
      {"sensor", readings.front().first},
      {"sensors", StandardValue(std::move(sensors))},
  }));
}

PlatformResponse handle_device(ChannelRegistry* registry,
                               const ServicePaths& paths,
                               const MethodCall& call) {
  const ChannelContext& ctx = registry->context();
  // v1 package contract (pluto_device).
  if (call.method == "deviceInfo") {
    return device_info(registry, paths);
  }
  if (call.method == "capabilities") {
    return standard_success(capability_list(ctx));
  }
  if (call.method == "battery") {
    return settings_battery_get(paths);
  }
  if (call.method == "temperature") {
    return device_temperature(paths);
  }
  // Legacy launcher methods.
  if (call.method == "getInfo") {
    return standard_success(make_map({
        {"model", ctx.device_model},
        {"codename", ctx.device_codename},
        {"panelSize", make_map({
                          {"width", static_cast<int64_t>(ctx.panel_width)},
                          {"height", static_cast<int64_t>(ctx.panel_height)},
                      })},
        {"dpi", static_cast<int64_t>(ctx.dpi)},
        {"isColor", ctx.is_color},
        {"firmwareVersion", "unknown"},
        {"presenter", ctx.presenter_name},
    }));
  }
  if (call.method == "getOrientation") {
    return standard_success(static_cast<int64_t>(ctx.rotation));
  }
  if (call.method == "setOrientation") {
    const int64_t* value = call.arguments.integer();
    if (value == nullptr ||
        (*value != 0 && *value != 90 && *value != 180 && *value != 270)) {
      return standard_error("bad-args",
                            "Orientation must be 0, 90, 180, or 270");
    }
    if (ctx.set_rotation) {
      ctx.set_rotation(static_cast<int32_t>(*value));
    }
    return standard_success();
  }
  return standard_unimplemented(call.method);
}

// ---- pluto/paths ---------------------------------------------------------

PlatformResponse handle_paths(const ServicePaths& paths,
                              const MethodCall& call) {
  if (call.method == "getPaths") {
    // Always scoped to the id the supervisor launched us with; the argument
    // is intentionally ignored so apps cannot reach each other's data.
    const fs::path root = fs::path(paths.data_dir) / paths.app_id;
    const fs::path documents = root / "documents";
    const fs::path cache = root / "cache";
    const fs::path support = root / "support";
    if (!ensure_dir(documents.string()) || !ensure_dir(cache.string()) ||
        !ensure_dir(support.string())) {
      return standard_error("io", "Unable to create app data directories");
    }
    return standard_success(make_map({
        {"appId", paths.app_id},
        {"root", root.string()},
        {"documents", documents.string()},
        {"cache", cache.string()},
        {"support", support.string()},
    }));
  }
  return standard_unimplemented(call.method);
}

// ---- pluto/apps ----------------------------------------------------------

PlatformResponse apps_list(const ServicePaths& paths) {
  StandardValue::List apps;
  std::error_code ec;
  if (!fs::is_directory(paths.apps_dir, ec) || ec) {
    return standard_success(StandardValue(std::move(apps)));
  }
  const std::set<std::string> pinned = read_pinned(paths);
  std::vector<std::string> ids;
  fs::directory_iterator it(paths.apps_dir, ec);
  const fs::directory_iterator end;
  while (!ec && it != end) {
    std::error_code entry_ec;
    if (it->is_directory(entry_ec) && !entry_ec) {
      ids.push_back(it->path().filename().string());
    }
    it.increment(ec);
  }
  std::sort(ids.begin(), ids.end());
  for (const std::string& id : ids) {
    const fs::path app_dir = fs::path(paths.apps_dir) / id;
    const std::string manifest_path = (app_dir / "manifest.json").string();
    const std::optional<std::string> manifest = read_file(manifest_path);
    const std::optional<std::string> install =
        read_file((app_dir / "install.json").string());
    apps.push_back(make_map({
        {"id", id},
        {"path", app_dir.string()},
        {"manifest",
         manifest.has_value() ? StandardValue(*manifest) : StandardValue()},
        {"install",
         install.has_value() ? StandardValue(*install) : StandardValue()},
        {"isPinned", pinned.count(id) != 0},
        {"sizeBytes", directory_size_bytes(app_dir)},
        {"dataSizeBytes", directory_size_bytes(fs::path(paths.data_dir) / id)},
        {"updatedAtMs", file_mtime_ms(manifest_path)},
        {"error", manifest.has_value()
                      ? StandardValue()
                      : StandardValue("manifest.json is missing or unreadable")},
    }));
  }
  return standard_success(StandardValue(std::move(apps)));
}

PlatformResponse handle_apps(const ServicePaths& paths,
                             const MethodCall& call) {
  if (call.method == "list") {
    return apps_list(paths);
  }
  if (call.method == "uninstall" || call.method == "clearAppData" ||
      call.method == "setPinned") {
    const std::string* app_id = string_arg(call, "appId");
    if (app_id == nullptr || !is_safe_app_id(*app_id)) {
      return standard_error("bad-args", call.method + " requires a valid appId");
    }
    std::error_code ec;
    if (call.method == "clearAppData") {
      fs::remove_all(fs::path(paths.data_dir) / *app_id, ec);
      return ec ? standard_error("io", "Unable to clear app data")
                : standard_success();
    }
    if (call.method == "setPinned") {
      std::set<std::string> pinned = read_pinned(paths);
      if (bool_arg(call, "isPinned", false)) {
        pinned.insert(*app_id);
      } else {
        pinned.erase(*app_id);
      }
      return write_pinned(paths, pinned)
                 ? standard_success()
                 : standard_error("io", "Unable to persist pinned apps");
    }
    fs::remove_all(fs::path(paths.apps_dir) / *app_id, ec);
    if (ec) {
      return standard_error("io", "Unable to remove app directory");
    }
    if (bool_arg(call, "deleteData", false)) {
      std::error_code data_ec;
      fs::remove_all(fs::path(paths.data_dir) / *app_id, data_ec);
    }
    std::set<std::string> pinned = read_pinned(paths);
    if (pinned.erase(*app_id) != 0) {
      write_pinned(paths, pinned);
    }
    return standard_success();
  }
  return standard_unimplemented(call.method);
}

}  // namespace

ServicePaths service_paths_from_env() {
  ServicePaths paths;
  paths.run_dir = env_or("PLUTO_RUN_DIR", paths.run_dir);
  paths.apps_dir = env_or("PLUTO_APPS_DIR", paths.apps_dir);
  paths.data_dir = env_or("PLUTO_DATA_DIR", paths.data_dir);
  paths.config_dir = env_or("PLUTO_CONFIG_DIR", paths.config_dir);
  paths.backlight_dir = env_or("PLUTO_BACKLIGHT", paths.backlight_dir);
  paths.vpdd_length_file =
      env_or("PLUTO_VPDD_LENGTH_FILE", paths.vpdd_length_file);
  paths.power_supply_dir =
      env_or("PLUTO_POWER_SUPPLY", paths.power_supply_dir);
  paths.wpa_control_dir =
      env_or("PLUTO_WPA_CONTROL_DIR", paths.wpa_control_dir);
  paths.wifi_settings_file =
      env_or("PLUTO_WIFI_SETTINGS_FILE", paths.wifi_settings_file);
  paths.systemctl = env_or("PLUTO_SYSTEMCTL", paths.systemctl);
  paths.wifi_interface = env_or("PLUTO_WIFI_IFACE", paths.wifi_interface);
  paths.network_class_dir =
      env_or("PLUTO_NETWORK_CLASS", paths.network_class_dir);
  paths.usb_interface_prefix =
      env_or("PLUTO_USB_IFACE_PREFIX", paths.usb_interface_prefix);
  paths.os_release_file = env_or("PLUTO_OS_RELEASE", paths.os_release_file);
  paths.serial_command = env_or("PLUTO_SERIAL_CMD", paths.serial_command);
  paths.hwmon_dir = env_or("PLUTO_HWMON", paths.hwmon_dir);
  paths.app_id = env_or("PLUTO_APP_ID", paths.app_id);
  return paths;
}

void register_service_channels(ChannelRegistry* registry, ServicePaths paths) {
  const auto shared = std::make_shared<const ServicePaths>(std::move(paths));
  registry->register_standard_method_channel(
      "pluto/core", [registry](const MethodCall& call) {
        return handle_core(registry, call);
      });
  registry->register_standard_method_channel(
      "pluto/device", [registry, shared](const MethodCall& call) {
        return handle_device(registry, *shared, call);
      });
  registry->register_standard_method_channel(
      "pluto/paths", [shared](const MethodCall& call) {
        return handle_paths(*shared, call);
      });
  registry->register_standard_method_channel(
      "pluto/session", [registry, shared](const MethodCall& call) {
        return handle_session(registry, *shared, call);
      });
  registry->register_standard_method_channel(
      "pluto/settings", [shared](const MethodCall& call) {
        return handle_settings(*shared, call);
      });
  registry->register_standard_method_channel(
      "pluto/apps", [shared](const MethodCall& call) {
        return handle_apps(*shared, call);
      });
}

}  // namespace pluto
