#ifndef PLUTO_PRESENTER_SWTCON_SWTCON_TEMPERATURE_H_
#define PLUTO_PRESENTER_SWTCON_SWTCON_TEMPERATURE_H_

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace pluto::swtcon {

class TemperatureFs {
 public:
  virtual ~TemperatureFs() = default;
  virtual bool list_directory(const std::string& path,
                              std::vector<std::string>* names,
                              std::string* error) const = 0;
  virtual bool read_file(const std::string& path, std::string* contents,
                         std::string* error) const = 0;
};

class RealTemperatureFs final : public TemperatureFs {
 public:
  bool list_directory(const std::string& path, std::vector<std::string>* names,
                      std::string* error) const override;
  bool read_file(const std::string& path, std::string* contents,
                 std::string* error) const override;
};

bool parse_milli_celsius(const std::string& text, int* out_milli_celsius);

// Sticky waveform temp-bin selection over the .eink ladder (ascending
// per-record lower thresholds in degC; raw bin = greatest threshold <= the
// reading, clamped coldest/warmest — WaveformTable::temp_bin semantics).
// Switching bins requires the reading to move hysteresis_celsius past the
// shared boundary, so a reading hovering at a threshold cannot flap.
class TemperatureBinSelector final {
 public:
  static constexpr float kDefaultHysteresisCelsius = 2.0f;

  TemperatureBinSelector() = default;
  explicit TemperatureBinSelector(float hysteresis_celsius)
      : hysteresis_celsius_(hysteresis_celsius) {}

  int select(const std::vector<std::uint8_t>& thresholds_celsius,
             float temperature_celsius);
  void reset() { held_bin_ = -1; }
  int held_bin() const { return held_bin_; }

  // Restore the sticky selector without fabricating a temperature reading.
  // `bin_count` is the currently loaded waveform ladder length. Invalid
  // seeds leave the held bin unchanged.
  bool seed_held_bin(int held_bin, std::size_t bin_count) {
    if (held_bin < 0 || static_cast<std::size_t>(held_bin) >= bin_count) {
      return false;
    }
    held_bin_ = held_bin;
    return true;
  }

 private:
  float hysteresis_celsius_ = kDefaultHysteresisCelsius;
  int held_bin_ = -1;
};

class SwtconTemperatureMonitor final {
 public:
  struct Config {
    std::string hwmon_root = "/sys/class/hwmon";
    // Explicit override: exact path of the temperature file to read;
    // bypasses the hwmon scan entirely.
    std::string sensor_path;
    // Explicit override: hwmon whose `name` file matches this exactly
    // (case-insensitive). The scan fails when it is absent rather than
    // silently falling back to another sensor.
    std::string sensor_name;
    // Fallback ladder when no explicit override is set: case-insensitive
    // substrings matched against each hwmon `name`, most-preferred first.
    // The EPD thermistor must win over the SoC sensor — waveform LUT bins
    // key on glass temperature, not die temperature. When nothing matches,
    // the first hwmon with a temp*_input is kept (legacy behavior).
    std::vector<std::string> sensor_name_preference = {
        "epd", "epaper", "eink", "g2194", "panel", "ntc"};
    std::chrono::milliseconds poll_interval{15000};
    int default_milli_celsius = 25000;
  };

  explicit SwtconTemperatureMonitor(const TemperatureFs* fs);
  SwtconTemperatureMonitor(const SwtconTemperatureMonitor&) = delete;
  SwtconTemperatureMonitor& operator=(const SwtconTemperatureMonitor&) = delete;
  ~SwtconTemperatureMonitor();

  bool poll_once(const Config& config, std::string* error);
  void start(Config config);
  void stop();

  float current_celsius() const;
  int current_milli_celsius() const;
  std::string selected_path() const;

 private:
  static bool is_temp_input_name(const std::string& name);
  static std::string join_path(const std::string& base,
                               const std::string& leaf);
  bool scan_locked(const Config& config, std::string* error);
  bool read_selected_locked(std::string* error);
  void run(Config config);

  const TemperatureFs* fs_ = nullptr;
  mutable std::mutex mutex_;
  std::string selected_path_;
  std::atomic<int> current_milli_celsius_{25000};
  std::thread thread_;
  std::atomic<bool> stop_{false};
};

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_SWTCON_TEMPERATURE_H_
