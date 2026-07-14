#include "presenter/swtcon/swtcon_temperature.h"

#include <gtest/gtest.h>

#include <chrono>
#include <cstdint>
#include <limits>
#include <map>
#include <string>
#include <vector>

namespace {

class FakeTemperatureFs final : public pluto::swtcon::TemperatureFs {
 public:
  bool list_directory(const std::string& path, std::vector<std::string>* names,
                      std::string* error) const override {
    const auto found = directories.find(path);
    if (found == directories.end()) {
      if (error != nullptr) {
        *error = "missing directory";
      }
      return false;
    }
    *names = found->second;
    return true;
  }

  bool read_file(const std::string& path, std::string* contents,
                 std::string* error) const override {
    const auto found = files.find(path);
    if (found == files.end()) {
      if (error != nullptr) {
        *error = "missing file";
      }
      return false;
    }
    *contents = found->second;
    return true;
  }

  std::map<std::string, std::vector<std::string>> directories;
  std::map<std::string, std::string> files;
};

}  // namespace

TEST(SwtconTemperatureTest, ParsesMilliCelsiusText) {
  int value = 0;
  EXPECT_TRUE(pluto::swtcon::parse_milli_celsius("27625\n", &value));
  EXPECT_EQ(value, 27625);
  EXPECT_TRUE(pluto::swtcon::parse_milli_celsius(" -1250 ", &value));
  EXPECT_EQ(value, -1250);
  EXPECT_FALSE(pluto::swtcon::parse_milli_celsius("27.5", &value));
  EXPECT_FALSE(pluto::swtcon::parse_milli_celsius("temp=27000", &value));
}

TEST(SwtconTemperatureTest, ScansHwmonAndPollsSelectedTempInput) {
  FakeTemperatureFs fs;
  fs.directories["/hwmon"] = {"hwmon1", "hwmon0"};
  fs.directories["/hwmon/hwmon0"] = {"name", "temp2_input"};
  fs.directories["/hwmon/hwmon1"] = {"name"};
  fs.files["/hwmon/hwmon0/temp2_input"] = "27625\n";

  pluto::swtcon::SwtconTemperatureMonitor monitor(&fs);
  pluto::swtcon::SwtconTemperatureMonitor::Config config;
  config.hwmon_root = "/hwmon";
  std::string error;
  ASSERT_TRUE(monitor.poll_once(config, &error)) << error;

  EXPECT_EQ(monitor.selected_path(), std::string("/hwmon/hwmon0/temp2_input"));
  EXPECT_EQ(monitor.current_milli_celsius(), 27625);

  fs.files["/hwmon/hwmon0/temp2_input"] = "28000\n";
  ASSERT_TRUE(monitor.poll_once(config, &error)) << error;
  EXPECT_EQ(monitor.current_milli_celsius(), 28000);
}

TEST(SwtconTemperatureTest, StartSamplesPanelSynchronouslyBeforeReturning) {
  FakeTemperatureFs fs;
  fs.directories["/hwmon"] = {"hwmon0"};
  fs.directories["/hwmon/hwmon0"] = {"name", "temp1_input"};
  fs.files["/hwmon/hwmon0/name"] = "epd_ntc\n";
  fs.files["/hwmon/hwmon0/temp1_input"] = "7000\n";

  pluto::swtcon::SwtconTemperatureMonitor monitor(&fs);
  pluto::swtcon::SwtconTemperatureMonitor::Config config;
  config.hwmon_root = "/hwmon";
  config.default_milli_celsius = 25000;
  config.poll_interval = std::chrono::hours(1);
  monitor.start(config);
  EXPECT_EQ(monitor.current_milli_celsius(), 7000);
  monitor.stop();
}

// Regression: the scan used to pick the alphabetically-first temp*_input,
// which on device is the SoC sensor, not the EPD thermistor. Name matching
// must prefer the panel sensor regardless of hwmon ordering.
TEST(SwtconTemperatureTest, PrefersEpdThermistorByHwmonNameOverScanOrder) {
  FakeTemperatureFs fs;
  fs.directories["/hwmon"] = {"hwmon0", "hwmon1"};
  fs.directories["/hwmon/hwmon0"] = {"name", "temp1_input"};
  fs.directories["/hwmon/hwmon1"] = {"name", "temp1_input"};
  fs.files["/hwmon/hwmon0/name"] = "soc_thermal\n";
  fs.files["/hwmon/hwmon0/temp1_input"] = "45000\n";
  fs.files["/hwmon/hwmon1/name"] = "EPD_NTC\n";
  fs.files["/hwmon/hwmon1/temp1_input"] = "27000\n";

  pluto::swtcon::SwtconTemperatureMonitor monitor(&fs);
  pluto::swtcon::SwtconTemperatureMonitor::Config config;
  config.hwmon_root = "/hwmon";
  std::string error;
  ASSERT_TRUE(monitor.poll_once(config, &error)) << error;

  EXPECT_EQ(monitor.selected_path(), std::string("/hwmon/hwmon1/temp1_input"));
  EXPECT_EQ(monitor.current_milli_celsius(), 27000);
}

TEST(SwtconTemperatureTest, SensorNameOverrideIsStrict) {
  FakeTemperatureFs fs;
  fs.directories["/hwmon"] = {"hwmon0", "hwmon1"};
  fs.directories["/hwmon/hwmon0"] = {"name", "temp1_input"};
  fs.directories["/hwmon/hwmon1"] = {"name", "temp1_input"};
  fs.files["/hwmon/hwmon0/name"] = "epd_ntc\n";
  fs.files["/hwmon/hwmon0/temp1_input"] = "27000\n";
  fs.files["/hwmon/hwmon1/name"] = "board_sensor\n";
  fs.files["/hwmon/hwmon1/temp1_input"] = "31000\n";

  pluto::swtcon::SwtconTemperatureMonitor monitor(&fs);
  pluto::swtcon::SwtconTemperatureMonitor::Config config;
  config.hwmon_root = "/hwmon";
  // Overrides the preference ladder (which would pick epd_ntc).
  config.sensor_name = "Board_Sensor";
  std::string error;
  ASSERT_TRUE(monitor.poll_once(config, &error)) << error;
  EXPECT_EQ(monitor.selected_path(), std::string("/hwmon/hwmon1/temp1_input"));
  EXPECT_EQ(monitor.current_milli_celsius(), 31000);

  // An absent override fails instead of silently reading another sensor.
  pluto::swtcon::SwtconTemperatureMonitor strict(&fs);
  config.sensor_name = "missing_sensor";
  error.clear();
  EXPECT_FALSE(strict.poll_once(config, &error));
  EXPECT_NE(error.find("missing_sensor"), std::string::npos);
  EXPECT_EQ(strict.current_milli_celsius(), config.default_milli_celsius);
}

TEST(SwtconTemperatureTest, SensorPathOverrideBypassesHwmonScan) {
  FakeTemperatureFs fs;
  // No hwmon tree at all: the explicit path must still be used.
  fs.files["/custom/epd_temp"] = "18500\n";

  pluto::swtcon::SwtconTemperatureMonitor monitor(&fs);
  pluto::swtcon::SwtconTemperatureMonitor::Config config;
  config.hwmon_root = "/hwmon";
  config.sensor_path = "/custom/epd_temp";
  std::string error;
  ASSERT_TRUE(monitor.poll_once(config, &error)) << error;
  EXPECT_EQ(monitor.selected_path(), std::string("/custom/epd_temp"));
  EXPECT_EQ(monitor.current_milli_celsius(), 18500);
}

TEST(SwtconTemperatureTest, FallsBackToFirstTempInputWhenNoNameMatches) {
  FakeTemperatureFs fs;
  fs.directories["/hwmon"] = {"hwmon1", "hwmon0"};
  fs.directories["/hwmon/hwmon0"] = {"name", "temp2_input"};
  fs.directories["/hwmon/hwmon1"] = {"name"};
  fs.files["/hwmon/hwmon0/name"] = "soc_thermal\n";
  fs.files["/hwmon/hwmon0/temp2_input"] = "27625\n";

  pluto::swtcon::SwtconTemperatureMonitor monitor(&fs);
  pluto::swtcon::SwtconTemperatureMonitor::Config config;
  config.hwmon_root = "/hwmon";
  std::string error;
  ASSERT_TRUE(monitor.poll_once(config, &error)) << error;
  EXPECT_EQ(monitor.selected_path(), std::string("/hwmon/hwmon0/temp2_input"));
}

namespace {

// The proven .eink ladder — per-record lower thresholds, degC.
const std::vector<std::uint8_t> kLadder = {0, 7, 13, 18, 22, 28, 33, 38, 43};

}  // namespace

TEST(TemperatureBinSelectorTest, MatchesLadderSemanticsOnFirstSelect) {
  pluto::swtcon::TemperatureBinSelector selector;
  // Raw bin = greatest threshold <= the reading, clamped at both ends.
  EXPECT_EQ(selector.select(kLadder, -5.0f), 0);
  selector.reset();
  EXPECT_EQ(selector.select(kLadder, 0.0f), 0);
  selector.reset();
  EXPECT_EQ(selector.select(kLadder, 7.0f), 1);
  selector.reset();
  EXPECT_EQ(selector.select(kLadder, 21.0f), 3);
  selector.reset();
  EXPECT_EQ(selector.select(kLadder, 25.0f), 4);
  selector.reset();
  EXPECT_EQ(selector.select(kLadder, 80.0f), 8);
  selector.reset();
  EXPECT_EQ(selector.select(kLadder, -std::numeric_limits<float>::infinity()),
            0);
  selector.reset();
  EXPECT_EQ(selector.select(kLadder, std::numeric_limits<float>::quiet_NaN()),
            0);
  selector.reset();
  EXPECT_EQ(selector.select(kLadder, std::numeric_limits<float>::infinity()),
            8);
  selector.reset();
  EXPECT_EQ(selector.select({}, 25.0f), 0);

  ASSERT_EQ(selector.select(kLadder, 80.0f), 8);
  EXPECT_EQ(selector.select(kLadder, std::numeric_limits<float>::quiet_NaN()),
            0);
}

// Regression: bins used to flap on every reading that hovered around a ladder
// threshold; a 2 degC hysteresis band must absorb the jitter both ways.
TEST(TemperatureBinSelectorTest,
     CrossingBackAndForthAroundThresholdDoesNotFlap) {
  pluto::swtcon::TemperatureBinSelector selector;
  ASSERT_EQ(selector.select(kLadder, 21.0f), 3);  // bin 3 = [18, 22)

  // Jitter across the 22 degC boundary stays inside the hysteresis band.
  for (int i = 0; i < 8; ++i) {
    EXPECT_EQ(selector.select(kLadder, 22.5f), 3);
    EXPECT_EQ(selector.select(kLadder, 21.5f), 3);
  }
  EXPECT_EQ(selector.select(kLadder, 23.9f), 3);

  // A real warm-up beyond boundary + 2 switches up.
  EXPECT_EQ(selector.select(kLadder, 24.0f), 4);

  // Jitter back across the same boundary holds the new bin.
  for (int i = 0; i < 8; ++i) {
    EXPECT_EQ(selector.select(kLadder, 21.5f), 4);
    EXPECT_EQ(selector.select(kLadder, 22.5f), 4);
  }
  EXPECT_EQ(selector.select(kLadder, 20.0f), 4);

  // A real cool-down below boundary - 2 switches back.
  EXPECT_EQ(selector.select(kLadder, 19.9f), 3);
}

TEST(TemperatureBinSelectorTest, LargeSwingsJumpStraightToTheRawBin) {
  pluto::swtcon::TemperatureBinSelector selector;
  ASSERT_EQ(selector.select(kLadder, 21.0f), 3);
  // Multi-bin jumps are not rate-limited by hysteresis.
  EXPECT_EQ(selector.select(kLadder, 40.0f), 7);
  EXPECT_EQ(selector.select(kLadder, 5.0f), 0);
}

TEST(TemperatureBinSelectorTest, HeldBinSeedIsValidatedAndRemainsSticky) {
  pluto::swtcon::TemperatureBinSelector selector;
  EXPECT_EQ(selector.held_bin(), -1);
  ASSERT_TRUE(selector.seed_held_bin(4, kLadder.size()));
  EXPECT_EQ(selector.held_bin(), 4);

  // 21.5 C is below bin 4's boundary but inside the two-degree cool-down
  // hysteresis, so a correctly restored selector must hold bin 4.
  EXPECT_EQ(selector.select(kLadder, 21.5f), 4);
  EXPECT_FALSE(selector.seed_held_bin(-1, kLadder.size()));
  EXPECT_FALSE(selector.seed_held_bin(static_cast<int>(kLadder.size()),
                                      kLadder.size()));
  EXPECT_FALSE(selector.seed_held_bin(0, 0));
  EXPECT_EQ(selector.held_bin(), 4) << "rejected seeds must not mutate state";

  selector.reset();
  EXPECT_EQ(selector.held_bin(), -1);
}

TEST(TemperatureBinSelectorTest, WarmestBinHoldsUntilCooledPastHysteresis) {
  pluto::swtcon::TemperatureBinSelector selector;
  ASSERT_EQ(selector.select(kLadder, 80.0f), 8);
  EXPECT_EQ(selector.select(kLadder, 48.0f), 8);  // still >= 43
  EXPECT_EQ(selector.select(kLadder, 41.5f), 8);  // inside 43 - 2 band
  EXPECT_EQ(selector.select(kLadder, 40.9f), 7);  // past the band
}
