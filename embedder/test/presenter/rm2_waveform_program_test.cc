#include "presenter/native/rm2/rm2_waveform_program.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include <gtest/gtest.h>
#include <sys/stat.h>
#include <unistd.h>

namespace pluto::native::rm2 {
namespace {

void write_text(const std::filesystem::path &path, std::string_view value) {
  std::ofstream output(path);
  output << value << '\n';
}

TEST(Rm2WaveformProgram,
     DiscoversExactSy7636aAndBracketsLivePowerAroundDiagnosticState) {
  namespace fs = std::filesystem;
  const fs::path root = fs::temp_directory_path() /
                        ("pluto_rm2_power_state_" +
                         std::to_string(static_cast<long long>(::getpid())));
  std::error_code filesystem_error;
  fs::remove_all(root, filesystem_error);
  const fs::path device = root / "3-0062";
  fs::create_directories(device);
  write_text(device / "name", "sy7636a");
  write_text(device / "power_good", "ON");
  write_text(device / "state", "no fault event");

  std::string error;
  Rm2PanelPowerState power = read_rm2_panel_power_state(&error, root.string());
  EXPECT_TRUE(power.ready()) << error;
  EXPECT_TRUE(power.attributes_readable);
  EXPECT_TRUE(power.power_good);
  EXPECT_TRUE(power.power_good_stable);
  EXPECT_TRUE(power.fault_state.empty());

  write_text(device / "power_good", "OFF");
  power = read_rm2_panel_power_state(&error, root.string());
  EXPECT_FALSE(power.ready());
  EXPECT_TRUE(power.attributes_readable);
  EXPECT_FALSE(power.power_good);
  EXPECT_TRUE(power.power_good_stable);
  EXPECT_EQ(error, "SY7636A panel power-good='OFF' state='no fault event'");

  constexpr std::array<std::string_view, 16> kAcceptedFaultStates = {
      "no fault event",   "UVP at VP rail",    "UVP at VN rail",
      "UVP at VPOS rail", "UVP at VNEG rail",  "UVP at VDDH rail",
      "UVP at VEE rail",  "SCP at VP rail",    "SCP at VN rail",
      "SCP at VPOS rail", "SCP at VNEG rail",  "SCP at VDDH rail",
      "SCP at VEE rail",  "SCP at V COM rail", "UVLO",
      "Thermal shutdown",
  };
  write_text(device / "power_good", "ON");
  for (const std::string_view state : kAcceptedFaultStates) {
    write_text(device / "state", state);
    power = read_rm2_panel_power_state(&error, root.string());
    EXPECT_TRUE(power.ready()) << state << ": " << error;
    EXPECT_EQ(power.fault_state,
              state == "no fault event" ? std::string{} : std::string(state));
    EXPECT_TRUE(error.empty()) << state;
  }

  fs::remove(device / "power_good", filesystem_error);
  ASSERT_EQ(::mkfifo((device / "power_good").c_str(), 0600), 0);
  std::thread changing_power_writer([&] {
    {
      std::ofstream first(device / "power_good");
      first << "ON\n";
    }
    {
      std::ofstream second(device / "power_good");
      second << "OFF\n";
    }
  });
  write_text(device / "state", "UVP at VN rail");
  power = read_rm2_panel_power_state(&error, root.string());
  changing_power_writer.join();
  EXPECT_FALSE(power.ready());
  EXPECT_TRUE(power.attributes_readable);
  EXPECT_FALSE(power.power_good);
  EXPECT_FALSE(power.power_good_stable);
  EXPECT_EQ(power.fault_state, "UVP at VN rail");
  EXPECT_EQ(error,
            "SY7636A panel power-good changed during state sample first='ON' "
            "second='OFF' state='UVP at VN rail'");

  fs::remove(device / "power_good", filesystem_error);
  write_text(device / "power_good", "MAYBE");
  power = read_rm2_panel_power_state(&error, root.string());
  EXPECT_FALSE(power.ready());
  EXPECT_FALSE(power.attributes_readable);
  EXPECT_EQ(error, "SY7636A power-good attribute has unknown value='MAYBE'");

  write_text(device / "power_good", "ON");
  write_text(device / "state", "invented fault");
  power = read_rm2_panel_power_state(&error, root.string());
  EXPECT_FALSE(power.ready());
  EXPECT_FALSE(power.attributes_readable);
  EXPECT_EQ(error,
            "SY7636A fault-state attribute has unknown value='invented fault'");

  write_text(device / "state", "no fault event");
  fs::remove(device / "power_good", filesystem_error);
  power = read_rm2_panel_power_state(&error, root.string());
  EXPECT_FALSE(power.ready());
  EXPECT_FALSE(power.attributes_readable);
  EXPECT_EQ(error, "SY7636A power/fault attributes are unreadable");

  write_text(device / "power_good", "ON");
  fs::remove(device / "state", filesystem_error);
  power = read_rm2_panel_power_state(&error, root.string());
  EXPECT_FALSE(power.ready());
  EXPECT_FALSE(power.attributes_readable);
  EXPECT_EQ(error, "SY7636A power/fault attributes are unreadable");

  write_text(device / "state", "no fault event");
  const fs::path ambiguous = root / "4-0062";
  fs::create_directories(ambiguous);
  write_text(ambiguous / "name", "sy7636a");
  write_text(ambiguous / "power_good", "ON");
  write_text(ambiguous / "state", "no fault event");
  power = read_rm2_panel_power_state(&error, root.string());
  EXPECT_FALSE(power.ready());
  EXPECT_FALSE(power.attributes_readable);
  EXPECT_EQ(error, "multiple SY7636A I2C parents are ambiguous");

  fs::remove_all(root, filesystem_error);
}

#if defined(PLUTO_RM2_WBF_FIXTURE)
TEST(Rm2WaveformProgram, BindsExactArtifactAndPreexpandsEveryRuntimeMode) {
  namespace fs = std::filesystem;
  if (!fs::exists(PLUTO_RM2_WBF_FIXTURE)) {
    return;
  }

  const fs::path local_path =
      fs::temp_directory_path() /
      ("pluto_rm2_320_R405_AFA011_ED103TC2C5_" +
       std::to_string(static_cast<long long>(::getpid())) + ".wbf");
  std::error_code filesystem_error;
  fs::copy_file(PLUTO_RM2_WBF_FIXTURE, local_path,
                fs::copy_options::overwrite_existing, filesystem_error);
  ASSERT_TRUE(!filesystem_error);

  GeneratedDeviceProfile profile = *generated_device_profile_by_id("rm2");
  const std::string path = local_path.string();
  const std::array<GeneratedWaveformSourceProfile, 1> sources = {{
      {
          .path = path,
          .sha256 = "79783d751ba066af12c6ac5aca46279fe7c79d4ef834105bd46824f870"
                    "f9c6f8",
          .panel_signature = "ED103TC2C5",
      },
  }};
  profile.runtime.waveform.accepted_sources = sources;

  Rm2WaveformProgram program;
  std::string error;
  ASSERT_TRUE(program.open(profile, path, &error)) << error;
  EXPECT_TRUE(program.temperature_supported(0));
  EXPECT_TRUE(program.temperature_supported(47999));
  EXPECT_FALSE(program.temperature_supported(-1));
  EXPECT_FALSE(program.temperature_supported(48000));

  Rm2WaveformSelection fast;
  Rm2WaveformSelection ui;
  Rm2WaveformSelection text;
  Rm2WaveformSelection full;
  ASSERT_TRUE(program.select(kPlutoRefreshFast, 24000, &fast));
  ASSERT_TRUE(program.select(kPlutoRefreshUi, 24000, &ui));
  ASSERT_TRUE(program.select(kPlutoRefreshText, 24000, &text));
  ASSERT_TRUE(program.select(kPlutoRefreshFull, 24000, &full));
  EXPECT_EQ(fast.mode, 6U);
  EXPECT_EQ(fast.phase_count, 10U);
  EXPECT_EQ(ui.mode, 3U);
  EXPECT_EQ(ui.phase_count, 38U);
  EXPECT_EQ(text.mode, 2U);
  EXPECT_EQ(text.phase_count, 38U);
  EXPECT_EQ(full.mode, 2U);
  EXPECT_EQ(full.phase_count, 38U);
  EXPECT_EQ(text.drive_lut.data(), full.drive_lut.data());
  EXPECT_EQ(fast.drive_lut.size(), fast.phase_count * 16U * 16U);
  EXPECT_EQ(fast.partial_drive_lut.size(), fast.drive_lut.size());
  for (std::uint32_t phase = 0; phase < fast.phase_count; ++phase) {
    for (std::uint32_t level = 0; level < 16; ++level) {
      EXPECT_EQ(fast.partial_drive_lut[phase * 16U * 16U + level * 17U], 0U);
    }
  }

  std::vector<std::uint8_t> init_codes;
  ASSERT_TRUE(program.init_pan_codes(24000, &init_codes));
  EXPECT_EQ(init_codes.size(), 105U);
  EXPECT_TRUE(std::all_of(init_codes.begin(), init_codes.end(),
                          [](std::uint8_t code) { return code <= 2U; }));
  EXPECT_FALSE(program.select(kPlutoRefreshFast, 48000, &fast));
  EXPECT_FALSE(program.init_pan_codes(48000, &init_codes));

  fs::remove(local_path, filesystem_error);
}
#endif

} // namespace
} // namespace pluto::native::rm2
