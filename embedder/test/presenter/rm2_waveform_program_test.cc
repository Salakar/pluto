#include "presenter/native/rm2/rm2_waveform_program.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include <gtest/gtest.h>
#include <unistd.h>

namespace pluto::native::rm2 {
namespace {

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

  fs::remove(local_path, filesystem_error);
}
#endif

} // namespace
} // namespace pluto::native::rm2
