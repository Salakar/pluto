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
  auto device = std::make_unique<MxsLcdifDevice>(&fake);
  LcdifTconDisplayBackend backend(
      profile, std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; });
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
  ASSERT_EQ(backend.submit(&request), kPlutoStatusOk);
  EXPECT_FALSE(backend.ready(kPlutoRefreshFast));
  ASSERT_EQ(backend.wait_idle(2000), kPlutoStatusOk);
  EXPECT_EQ(completion.count.load(std::memory_order_acquire), 1);
  EXPECT_EQ(completion.frame_id.load(std::memory_order_relaxed), 73U);
  EXPECT_TRUE(backend.ready(kPlutoRefreshFast));
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
  fs::remove(local_path, filesystem_error);
}
#endif

} // namespace
} // namespace pluto::native::rm2
