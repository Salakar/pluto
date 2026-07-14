#include "presenter/swtcon/swtcon_temperature.h"

#include <algorithm>
#include <cerrno>
#include <charconv>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <thread>

namespace pluto::swtcon {
namespace {

void set_error(std::string* error, const std::string& message) {
  if (error != nullptr) {
    *error = message;
  }
}

std::string errno_message(const std::string& what) {
  return what + ": " + std::strerror(errno);
}

std::string trimmed_lower(const std::string& text) {
  std::size_t begin = 0;
  std::size_t end = text.size();
  while (begin < end && (text[begin] == ' ' || text[begin] == '\t' ||
                         text[begin] == '\n' || text[begin] == '\r')) {
    ++begin;
  }
  while (end > begin && (text[end - 1] == ' ' || text[end - 1] == '\t' ||
                         text[end - 1] == '\n' || text[end - 1] == '\r')) {
    --end;
  }
  std::string result = text.substr(begin, end - begin);
  for (char& c : result) {
    if (c >= 'A' && c <= 'Z') {
      c = static_cast<char>(c - 'A' + 'a');
    }
  }
  return result;
}

// Greatest per-record lower threshold <= the reading, clamped to the first or
// last record — mirrors Xochitl 3.27 selector 0x9af630 and
// WaveformTable::temp_bin.
int raw_temp_bin(const std::vector<std::uint8_t>& thresholds_celsius,
                 float temperature_celsius) {
  const int count = static_cast<int>(thresholds_celsius.size());
  int bin = 0;
  for (int i = 1; i < count; ++i) {
    const float threshold =
        static_cast<float>(thresholds_celsius[static_cast<std::size_t>(i)]);
    if (temperature_celsius >= threshold) {
      bin = i;
    } else {
      break;
    }
  }
  return bin;
}

}  // namespace

int TemperatureBinSelector::select(
    const std::vector<std::uint8_t>& thresholds_celsius,
    float temperature_celsius) {
  const int count = static_cast<int>(thresholds_celsius.size());
  if (count <= 0) {
    held_bin_ = -1;
    return 0;
  }
  const int raw = raw_temp_bin(thresholds_celsius, temperature_celsius);
  // Xochitl's ordered comparisons send NaN to record 0. Do not let sticky
  // hysteresis retain a previously warm record for that sentinel value.
  if (std::isnan(temperature_celsius)) {
    held_bin_ = 0;
    return held_bin_;
  }
  if (held_bin_ < 0 || held_bin_ >= count) {
    held_bin_ = raw;
    return held_bin_;
  }
  if (raw > held_bin_) {
    // Warming into the next record: its lower threshold is the shared
    // boundary. A large swing may jump directly to `raw` after crossing it.
    const float boundary = static_cast<float>(
        thresholds_celsius[static_cast<std::size_t>(held_bin_ + 1)]);
    if (temperature_celsius >= boundary + hysteresis_celsius_) {
      held_bin_ = raw;
    }
  } else if (raw < held_bin_) {
    // Cooling below the held record's own lower threshold.
    const float boundary = static_cast<float>(
        thresholds_celsius[static_cast<std::size_t>(held_bin_)]);
    if (temperature_celsius < boundary - hysteresis_celsius_) {
      held_bin_ = raw;
    }
  }
  return held_bin_;
}

bool RealTemperatureFs::list_directory(const std::string& path,
                                       std::vector<std::string>* names,
                                       std::string* error) const {
  if (names == nullptr) {
    set_error(error, "null directory listing output");
    return false;
  }
  names->clear();
  std::error_code ec;
  for (const auto& entry : std::filesystem::directory_iterator(path, ec)) {
    names->push_back(entry.path().filename().string());
  }
  if (ec) {
    set_error(error, "list " + path + ": " + ec.message());
    return false;
  }
  return true;
}

bool RealTemperatureFs::read_file(const std::string& path,
                                  std::string* contents,
                                  std::string* error) const {
  if (contents == nullptr) {
    set_error(error, "null file read output");
    return false;
  }
  std::ifstream in(path);
  if (!in) {
    set_error(error, errno_message("open " + path));
    return false;
  }
  *contents = std::string(std::istreambuf_iterator<char>(in),
                          std::istreambuf_iterator<char>());
  if (contents->empty()) {
    set_error(error, "temperature file is empty: " + path);
    return false;
  }
  return true;
}

bool parse_milli_celsius(const std::string& text, int* out_milli_celsius) {
  if (out_milli_celsius == nullptr) {
    return false;
  }
  const char* begin = text.data();
  const char* end = text.data() + text.size();
  while (begin < end && (*begin == ' ' || *begin == '\t' || *begin == '\n' ||
                         *begin == '\r')) {
    ++begin;
  }
  const char* number_begin = begin;
  if (begin < end && (*begin == '-' || *begin == '+')) {
    ++begin;
  }
  const char* digit_begin = begin;
  while (begin < end && *begin >= '0' && *begin <= '9') {
    ++begin;
  }
  if (begin == digit_begin) {
    return false;
  }
  int value = 0;
  const std::from_chars_result result =
      std::from_chars(number_begin, begin, value);
  if (result.ec != std::errc()) {
    return false;
  }
  while (begin < end && (*begin == ' ' || *begin == '\t' || *begin == '\n' ||
                         *begin == '\r')) {
    ++begin;
  }
  if (begin != end) {
    return false;
  }
  *out_milli_celsius = value;
  return true;
}

SwtconTemperatureMonitor::SwtconTemperatureMonitor(const TemperatureFs* fs)
    : fs_(fs) {}

SwtconTemperatureMonitor::~SwtconTemperatureMonitor() {
  stop();
}

bool SwtconTemperatureMonitor::poll_once(const Config& config,
                                         std::string* error) {
  current_milli_celsius_.store(config.default_milli_celsius,
                               std::memory_order_relaxed);
  std::lock_guard<std::mutex> lock(mutex_);
  if (fs_ == nullptr) {
    set_error(error, "temperature monitor has no filesystem");
    return false;
  }
  if (selected_path_.empty() && !scan_locked(config, error)) {
    return false;
  }
  return read_selected_locked(error);
}

void SwtconTemperatureMonitor::start(Config config) {
  stop();
  // Establish a deterministic panel reading before any cold-clear waveform
  // can be admitted. A failed scan/read leaves the configured default, but a
  // real thermistor is consumed synchronously rather than racing the worker.
  (void)poll_once(config, nullptr);
  stop_.store(false, std::memory_order_release);
  thread_ =
      std::thread(&SwtconTemperatureMonitor::run, this, std::move(config));
}

void SwtconTemperatureMonitor::stop() {
  stop_.store(true, std::memory_order_release);
  if (thread_.joinable()) {
    thread_.join();
  }
}

float SwtconTemperatureMonitor::current_celsius() const {
  return static_cast<float>(current_milli_celsius()) * 0.001f;
}

int SwtconTemperatureMonitor::current_milli_celsius() const {
  return current_milli_celsius_.load(std::memory_order_relaxed);
}

std::string SwtconTemperatureMonitor::selected_path() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return selected_path_;
}

bool SwtconTemperatureMonitor::is_temp_input_name(const std::string& name) {
  constexpr char kPrefix[] = "temp";
  constexpr char kSuffix[] = "_input";
  if (name.size() <= sizeof(kPrefix) - 1 + sizeof(kSuffix) - 1 ||
      name.rfind(kPrefix, 0) != 0 ||
      name.substr(name.size() - (sizeof(kSuffix) - 1)) != kSuffix) {
    return false;
  }
  for (std::size_t i = sizeof(kPrefix) - 1;
       i < name.size() - (sizeof(kSuffix) - 1); ++i) {
    if (name[i] < '0' || name[i] > '9') {
      return false;
    }
  }
  return true;
}

std::string SwtconTemperatureMonitor::join_path(const std::string& base,
                                                const std::string& leaf) {
  if (base.empty() || base.back() == '/') {
    return base + leaf;
  }
  return base + "/" + leaf;
}

bool SwtconTemperatureMonitor::scan_locked(const Config& config,
                                           std::string* error) {
  if (!config.sensor_path.empty()) {
    selected_path_ = config.sensor_path;
    return true;
  }
  std::vector<std::string> hwmons;
  if (!fs_->list_directory(config.hwmon_root, &hwmons, error)) {
    return false;
  }
  std::sort(hwmons.begin(), hwmons.end());

  struct Candidate {
    std::string name_lower;
    std::string temp_input_path;
  };
  std::vector<Candidate> candidates;
  for (const std::string& hwmon : hwmons) {
    const std::string hwmon_path = join_path(config.hwmon_root, hwmon);
    std::vector<std::string> names;
    if (!fs_->list_directory(hwmon_path, &names, nullptr)) {
      continue;
    }
    std::sort(names.begin(), names.end());
    std::string temp_input_path;
    for (const std::string& name : names) {
      if (is_temp_input_name(name)) {
        temp_input_path = join_path(hwmon_path, name);
        break;
      }
    }
    if (temp_input_path.empty()) {
      continue;
    }
    std::string sensor_name;
    (void)fs_->read_file(join_path(hwmon_path, "name"), &sensor_name, nullptr);
    candidates.push_back(
        Candidate{trimmed_lower(sensor_name), std::move(temp_input_path)});
  }

  if (!config.sensor_name.empty()) {
    const std::string wanted = trimmed_lower(config.sensor_name);
    for (const Candidate& candidate : candidates) {
      if (candidate.name_lower == wanted) {
        selected_path_ = candidate.temp_input_path;
        return true;
      }
    }
    set_error(error, "no hwmon named '" + config.sensor_name +
                         "' with a temp*_input under " + config.hwmon_root);
    return false;
  }

  for (const std::string& preferred : config.sensor_name_preference) {
    const std::string token = trimmed_lower(preferred);
    if (token.empty()) {
      continue;
    }
    for (const Candidate& candidate : candidates) {
      if (candidate.name_lower.find(token) != std::string::npos) {
        selected_path_ = candidate.temp_input_path;
        return true;
      }
    }
  }

  if (!candidates.empty()) {
    selected_path_ = candidates.front().temp_input_path;
    return true;
  }
  set_error(error,
            "no hwmon temp*_input path found under " + config.hwmon_root);
  return false;
}

bool SwtconTemperatureMonitor::read_selected_locked(std::string* error) {
  std::string text;
  if (!fs_->read_file(selected_path_, &text, error)) {
    selected_path_.clear();
    return false;
  }
  int milli_celsius = 0;
  if (!parse_milli_celsius(text, &milli_celsius)) {
    set_error(error, "unable to parse milli-Celsius from " + selected_path_);
    selected_path_.clear();
    return false;
  }
  current_milli_celsius_.store(milli_celsius, std::memory_order_relaxed);
  return true;
}

void SwtconTemperatureMonitor::run(Config config) {
  while (!stop_.load(std::memory_order_acquire)) {
    std::string ignored;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (fs_ != nullptr) {
        if (selected_path_.empty()) {
          (void)scan_locked(config, &ignored);
        }
        if (!selected_path_.empty()) {
          (void)read_selected_locked(&ignored);
        }
      }
    }
    const auto interval = config.poll_interval.count() <= 0
                              ? std::chrono::milliseconds(15000)
                              : config.poll_interval;
    const auto deadline = std::chrono::steady_clock::now() + interval;
    while (!stop_.load(std::memory_order_acquire) &&
           std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
  }
}

}  // namespace pluto::swtcon
