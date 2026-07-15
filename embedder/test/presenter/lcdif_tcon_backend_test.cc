#include "presenter/native/rm2/lcdif_tcon_backend.h"

#include <array>
#include <atomic>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#include <fcntl.h>
#include <gtest/gtest.h>
#include <sys/mman.h>
#include <unistd.h>

#include "presenter/native/rm2/rm2_scan_encoder.h"

namespace pluto::native::rm2 {
namespace {

class BackendFakeLcdifSyscalls final : public MxsLcdifSyscalls {
public:
  BackendFakeLcdifSyscalls() : storage(32U * 1024U * 1024U) {
    std::memcpy(fixed.id, "mxs-lcdif", sizeof("mxs-lcdif"));
    fixed.smem_start = 0xa9d00000U;
    fixed.smem_len = static_cast<std::uint32_t>(storage.size());
    fixed.type = uapi::kFramebufferTypePackedPixels;
    fixed.visual = uapi::kFramebufferVisualTrueColor;
    fixed.ypanstep = 1;
    fixed.ywrapstep = 1;
    fixed.line_length = kRm2ScanoutStrideBytes;

    variable.xres = kRm2ScanoutWidth;
    variable.yres = kRm2ScanoutHeight;
    variable.xres_virtual = kRm2ScanoutWidth;
    variable.yres_virtual = kRm2ScanoutHeight * kRm2MappedSlots;
    variable.yoffset = 14 * kRm2ScanoutHeight;
    variable.bits_per_pixel = 32;
    variable.red = {.offset = 16, .length = 8, .msb_right = 0};
    variable.green = {.offset = 8, .length = 8, .msb_right = 0};
    variable.blue = {.offset = 0, .length = 8, .msb_right = 0};
    variable.pixclock = 28800;
    variable.left_margin = 1;
    variable.right_margin = 1;
    variable.upper_margin = 1;
    variable.lower_margin = 143;
    variable.hsync_len = 1;
    variable.vsync_len = 1;
  }

  int open(const char *, int) override { return 91; }
  int ioctl(int, unsigned long request, void *argument) override {
    if (request == uapi::kGetFixedScreenInfo) {
      std::memcpy(argument, &fixed, sizeof(fixed));
      return 0;
    }
    if (request == uapi::kGetVariableScreenInfo) {
      std::memcpy(argument, &variable, sizeof(variable));
      return 0;
    }
    if (request == uapi::kPutVariableScreenInfo) {
      variable = *static_cast<uapi::FramebufferVariableInfoArm32 *>(argument);
      return 0;
    }
    if (request == uapi::kBlank) {
      blank_values.push_back(reinterpret_cast<std::uintptr_t>(argument));
      return 0;
    }
    if (request == uapi::kPanDisplay) {
      panned_offsets.push_back(
          static_cast<uapi::FramebufferVariableInfoArm32 *>(argument)->yoffset);
      return 49;
    }
    errno = ENOTTY;
    return -1;
  }
  void *mmap(void *, std::size_t, int, int, int, off_t) override {
    return storage.data();
  }
  int munmap(void *, std::size_t) override { return 0; }
  int close(int) override {
    ++close_count;
    return 0;
  }

  uapi::FramebufferFixedInfoArm32 fixed{};
  uapi::FramebufferVariableInfoArm32 variable{};
  std::vector<std::byte> storage;
  std::vector<std::uintptr_t> blank_values;
  std::vector<std::uint32_t> panned_offsets;
  int close_count = 0;
};

struct CompletionState {
  std::atomic<int> count{0};
  std::atomic<std::uint64_t> frame_id{0};
};

void record_completion(std::uint64_t frame_id, void *user_data) {
  auto *state = static_cast<CompletionState *>(user_data);
  state->frame_id.store(frame_id, std::memory_order_relaxed);
  state->count.fetch_add(1, std::memory_order_release);
}

#if defined(PLUTO_RM2_WBF_FIXTURE)
TEST(LcdifTconBackend, PreflightsThenInitScansAndCompletesOnlyOnFinalIdlePage) {
  namespace fs = std::filesystem;
  if (!fs::exists(PLUTO_RM2_WBF_FIXTURE)) {
    return;
  }
  const fs::path local_path =
      fs::temp_directory_path() /
      ("pluto_rm2_backend_320_R405_AFA011_ED103TC2C5_" +
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

  BackendFakeLcdifSyscalls fake;
  int power_checks = 0;
  int temperature_reads = 0;
  bool power_checks_follow_safe_hold = true;
  bool temperature_reads_follow_power_check = true;
  auto device = std::make_unique<MxsLcdifDevice>(&fake);
  LcdifTconDisplayBackend backend(
      profile, std::move(device),
      [&](std::string *) -> std::optional<int> {
        ++temperature_reads;
        temperature_reads_follow_power_check &=
            power_checks == temperature_reads * 2 - 1 &&
            !fake.blank_values.empty() &&
            fake.blank_values.back() == uapi::kBlankUnblank &&
            !fake.panned_offsets.empty() &&
            fake.panned_offsets.back() == kRm2IdleSlot * kRm2ScanoutHeight;
        return 24000;
      },
      [&](std::string *) {
        ++power_checks;
        const bool follows_safe_hold =
            !fake.blank_values.empty() &&
            fake.blank_values.back() == uapi::kBlankUnblank &&
            !fake.panned_offsets.empty() &&
            fake.panned_offsets.back() == kRm2IdleSlot * kRm2ScanoutHeight;
        power_checks_follow_safe_hold &= follows_safe_hold;
        return follows_safe_hold;
      });
  ASSERT_EQ(backend.probe(profile), kPlutoStatusOk);
  EXPECT_TRUE(fake.blank_values.empty());
  EXPECT_TRUE(fake.panned_offsets.empty());

  CompletionState completion;
  const std::string options = "wbf=" + path;
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = options.c_str(),
      .on_complete = record_completion,
      .user_data = &completion,
  };
  ASSERT_EQ(backend.start(config), kPlutoStatusOk);
  ASSERT_TRUE(fake.blank_values.size() >= 3U);
  EXPECT_EQ(fake.blank_values.front(), uapi::kBlankPowerdown);
  EXPECT_EQ(fake.blank_values[fake.blank_values.size() - 2U],
            uapi::kBlankUnblank);
  EXPECT_EQ(fake.blank_values.back(), uapi::kBlankPowerdown);
  EXPECT_EQ(power_checks, 2);
  EXPECT_EQ(temperature_reads, 1);
  EXPECT_TRUE(power_checks_follow_safe_hold);
  EXPECT_TRUE(temperature_reads_follow_power_check);
  ASSERT_TRUE(!fake.panned_offsets.empty());
  EXPECT_EQ(fake.panned_offsets.back(), kRm2IdleSlot * kRm2ScanoutHeight);

  std::vector<std::uint16_t> pixels(kRm2PanelWidth * kRm2PanelHeight, 0xffffU);
  pixels[0] = 0;
  const PlutoRect damage{.x = 0, .y = 0, .width = 1, .height = 1};
  const PlutoPresentRequest request{
      .struct_size = sizeof(PlutoPresentRequest),
      .surface =
          {
              .pixels = reinterpret_cast<const std::uint8_t *>(pixels.data()),
              .stride_bytes = kRm2PanelWidth * sizeof(std::uint16_t),
              .width = static_cast<std::int32_t>(kRm2PanelWidth),
              .height = static_cast<std::int32_t>(kRm2PanelHeight),
              .format = kPlutoPixelFormatRgb565,
          },
      .damage = &damage,
      .damage_count = 1,
      .refresh_class = kPlutoRefreshFast,
      .flags = kPlutoPresentFlagInkPriority,
      .frame_id = 73,
  };
  PlutoPresentRequest sparkle_request = request;
  sparkle_request.flags =
      kPlutoPresentFlagSparkle | kPlutoPresentFlagSparkleDevelop | (17U << 8U);
  sparkle_request.frame_id = 72;
  const std::size_t pans_before_sparkle = fake.panned_offsets.size();
  ASSERT_EQ(backend.submit(&sparkle_request), kPlutoStatusOk);
  EXPECT_EQ(completion.count.load(std::memory_order_acquire), 1);
  EXPECT_EQ(completion.frame_id.load(std::memory_order_relaxed), 72U);
  EXPECT_EQ(fake.panned_offsets.size(), pans_before_sparkle);
  EXPECT_TRUE(backend.ready(kPlutoRefreshFast));
  EXPECT_EQ(backend.health().completed_jobs, 1U);

  ASSERT_EQ(backend.submit(&request), kPlutoStatusOk);
  EXPECT_FALSE(backend.ready(kPlutoRefreshFast));
  ASSERT_EQ(backend.wait_idle(2000), kPlutoStatusOk);
  EXPECT_EQ(completion.count.load(std::memory_order_acquire), 2);
  EXPECT_EQ(completion.frame_id.load(std::memory_order_relaxed), 73U);
  EXPECT_TRUE(backend.ready(kPlutoRefreshFast));
  EXPECT_EQ(backend.health().completed_jobs, 2U);
  EXPECT_EQ(power_checks, 4);
  EXPECT_EQ(temperature_reads, 2);
  EXPECT_TRUE(power_checks_follow_safe_hold);
  EXPECT_TRUE(temperature_reads_follow_power_check);
  EXPECT_EQ(fake.panned_offsets.back(), kRm2IdleSlot * kRm2ScanoutHeight);

  std::vector<std::uint16_t> snapshot_pixels(pixels.size());
  PlutoSurface snapshot{
      .pixels = reinterpret_cast<const std::uint8_t *>(snapshot_pixels.data()),
      .stride_bytes = kRm2PanelWidth * sizeof(std::uint16_t),
      .width = static_cast<std::int32_t>(kRm2PanelWidth),
      .height = static_cast<std::int32_t>(kRm2PanelHeight),
      .format = kPlutoPixelFormatRgb565,
  };
  ASSERT_EQ(backend.snapshot(&snapshot), kPlutoStatusOk);
  EXPECT_EQ(snapshot_pixels[0], 0U);
  EXPECT_EQ(snapshot_pixels[1], 0xffffU);

  backend.stop();
  EXPECT_EQ(fake.blank_values.back(), uapi::kBlankPowerdown);
  EXPECT_EQ(fake.close_count, 1);

  BackendFakeLcdifSyscalls bad_power_fake;
  int bad_power_temperature_reads = 0;
  auto bad_power_device = std::make_unique<MxsLcdifDevice>(&bad_power_fake);
  LcdifTconDisplayBackend bad_power_backend(
      profile, std::move(bad_power_device),
      [&](std::string *) -> std::optional<int> {
        ++bad_power_temperature_reads;
        return 24000;
      },
      [](std::string *) { return false; });
  ASSERT_EQ(bad_power_backend.probe(profile), kPlutoStatusOk);
  EXPECT_EQ(bad_power_backend.start(config), kPlutoStatusDeviceLost);
  EXPECT_EQ(bad_power_temperature_reads, 0);
  ASSERT_TRUE(!bad_power_fake.blank_values.empty());
  EXPECT_EQ(bad_power_fake.blank_values.back(), uapi::kBlankPowerdown);
  EXPECT_EQ(bad_power_fake.close_count, 1);
  EXPECT_EQ(static_cast<int>(bad_power_backend.health().state),
            static_cast<int>(NativeBackendHealthState::kDeviceLost));
  EXPECT_EQ(bad_power_backend.submit(&sparkle_request), kPlutoStatusDeviceLost);

  fs::remove(local_path, filesystem_error);
}

TEST(LcdifTconBackend,
     PostTemperaturePowerDropAndMissingTemperatureFailClosed) {
  namespace fs = std::filesystem;
  if (!fs::exists(PLUTO_RM2_WBF_FIXTURE)) {
    return;
  }
  const fs::path local_path =
      fs::temp_directory_path() /
      ("pluto_rm2_power_failure_320_R405_AFA011_ED103TC2C5_" +
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
  const std::string options = "wbf=" + path;
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = options.c_str(),
  };

  {
    BackendFakeLcdifSyscalls fake;
    int power_checks = 0;
    int temperature_reads = 0;
    auto device = std::make_unique<MxsLcdifDevice>(&fake);
    LcdifTconDisplayBackend backend(
        profile, std::move(device),
        [&](std::string *) -> std::optional<int> {
          ++temperature_reads;
          return 24000;
        },
        [&](std::string *) {
          ++power_checks;
          return power_checks == 1;
        });
    ASSERT_EQ(backend.probe(profile), kPlutoStatusOk);
    EXPECT_EQ(backend.start(config), kPlutoStatusDeviceLost);
    EXPECT_EQ(power_checks, 2);
    EXPECT_EQ(temperature_reads, 1);
    ASSERT_TRUE(!fake.blank_values.empty());
    EXPECT_EQ(fake.blank_values.back(), uapi::kBlankPowerdown);
    EXPECT_EQ(fake.close_count, 1);
    EXPECT_EQ(static_cast<int>(backend.health().state),
              static_cast<int>(NativeBackendHealthState::kDeviceLost));
  }

  {
    BackendFakeLcdifSyscalls fake;
    int power_checks = 0;
    int temperature_reads = 0;
    auto device = std::make_unique<MxsLcdifDevice>(&fake);
    LcdifTconDisplayBackend backend(
        profile, std::move(device),
        [&](std::string *) -> std::optional<int> {
          ++temperature_reads;
          return std::nullopt;
        },
        [&](std::string *) {
          ++power_checks;
          return true;
        });
    ASSERT_EQ(backend.probe(profile), kPlutoStatusOk);
    EXPECT_EQ(backend.start(config), kPlutoStatusDeviceLost);
    EXPECT_EQ(power_checks, 1);
    EXPECT_EQ(temperature_reads, 1);
    ASSERT_TRUE(!fake.blank_values.empty());
    EXPECT_EQ(fake.blank_values.back(), uapi::kBlankPowerdown);
    EXPECT_EQ(fake.close_count, 1);
    EXPECT_EQ(static_cast<int>(backend.health().state),
              static_cast<int>(NativeBackendHealthState::kDeviceLost));
  }

  fs::remove(local_path, filesystem_error);
}
#endif

} // namespace
} // namespace pluto::native::rm2
