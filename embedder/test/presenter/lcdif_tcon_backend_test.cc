#include "presenter/native/rm2/lcdif_tcon_backend.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <optional>
#include <span>
#include <string>
#include <utility>
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

  int open(const char *, int) override {
    ++open_count;
    return 91;
  }
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
      const auto *requested =
          static_cast<uapi::FramebufferVariableInfoArm32 *>(argument);
      panned_offsets.push_back(requested->yoffset);
      variable.yoffset = requested->yoffset;
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
  int open_count = 0;
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
class LocalRm2Profile final {
public:
  LocalRm2Profile() {
    namespace fs = std::filesystem;
    static std::atomic<std::uint64_t> sequence{1};
    path_ = (fs::temp_directory_path() /
             ("pluto_rm2_handoff_320_R405_AFA011_ED103TC2C5_" +
              std::to_string(sequence.fetch_add(1, std::memory_order_relaxed)) +
              ".wbf"))
                .string();
    std::error_code error;
    fs::copy_file(PLUTO_RM2_WBF_FIXTURE, path_,
                  fs::copy_options::overwrite_existing, error);
    if (error) {
      return;
    }
    profile_ = *generated_device_profile_by_id("rm2");
    sources_[0] = {
        .path = path_,
        .sha256 = "79783d751ba066af12c6ac5aca46279fe7c79d4ef834105bd46824f870"
                  "f9c6f8",
        .panel_signature = "ED103TC2C5",
    };
    profile_.runtime.waveform.accepted_sources = sources_;
    valid_ = true;
  }

  ~LocalRm2Profile() {
    std::error_code error;
    std::filesystem::remove(path_, error);
  }

  bool valid() const { return valid_; }
  const GeneratedDeviceProfile &profile() const { return profile_; }
  const std::string &waveform_path() const { return path_; }

private:
  std::string path_;
  std::array<GeneratedWaveformSourceProfile, 1> sources_{};
  GeneratedDeviceProfile profile_{};
  bool valid_ = false;
};

class IsolatedHandoffPath final {
public:
  IsolatedHandoffPath() {
    static std::atomic<std::uint64_t> sequence{1};
    path_ = std::filesystem::temp_directory_path().string() +
            "/pluto-rm2-handoff-" + std::to_string(::getpid()) + "-" +
            std::to_string(sequence.fetch_add(1, std::memory_order_relaxed));
  }

  ~IsolatedHandoffPath() {
    (void)std::remove(path_.c_str());
    (void)std::remove((path_ + ".lease").c_str());
  }

  const std::string &get() const { return path_; }

private:
  std::string path_;
};

Rm2HandoffOptions handoff_options(const std::string &path,
                                  GlassHandoffClock (*now)() = nullptr) {
  return {
      .path = path,
      .allow_insecure_path_for_testing = true,
      .now_for_testing = now,
  };
}

GlassHandoffClock handoff_clock_100() {
  return {
      .realtime_sec = 100,
      .boottime_ns = 10'000'000'000ULL,
      .boot_id_hash = 0x123456789abcdef0ULL,
  };
}

GlassHandoffClock handoff_clock_161() {
  return {
      .realtime_sec = 161,
      .boottime_ns = 71'000'000'000ULL,
      .boot_id_hash = 0x123456789abcdef0ULL,
  };
}

class OwnedHandoffPayload final {
public:
  explicit OwnedHandoffPayload(std::vector<std::uint8_t> contents = {0x52, 0x4d,
                                                                     0x32,
                                                                     0x01})
      : bytes(std::move(contents)) {
    payload = {
        .struct_size = sizeof(PlutoHandoffPayload),
        .bytes = bytes.data(),
        .byte_count = bytes.size(),
        .width = static_cast<std::int32_t>(kRm2PanelWidth),
        .height = static_cast<std::int32_t>(kRm2PanelHeight),
        .rotation = 0,
        .pixel_format = kPlutoPixelFormatRgb565,
        .configuration_hash = 0x5b7f8a91c2d3e405ULL,
    };
  }

  std::vector<std::uint8_t> bytes;
  PlutoHandoffPayload payload{};
};

class OwnedPixelRequest final {
public:
  OwnedPixelRequest(std::uint32_t x, std::uint32_t y, std::uint16_t pixel,
                    std::uint64_t frame_id,
                    PlutoRefreshClass refresh_class = kPlutoRefreshFast)
      : pixels(kRm2PanelWidth * kRm2PanelHeight, 0xffffU),
        damage{.x = static_cast<std::int32_t>(x),
               .y = static_cast<std::int32_t>(y),
               .width = 1,
               .height = 1} {
    pixels[static_cast<std::size_t>(y) * kRm2PanelWidth + x] = pixel;
    request = {
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
        .refresh_class = refresh_class,
        .flags = 0,
        .frame_id = frame_id,
    };
  }

  std::vector<std::uint16_t> pixels;
  PlutoRect damage{};
  PlutoPresentRequest request{};
};

bool probe_and_start(LcdifTconDisplayBackend *backend,
                     const LocalRm2Profile &fixture,
                     CompletionState *completion = nullptr) {
  if (backend == nullptr || !fixture.valid() ||
      backend->probe(fixture.profile()) != kPlutoStatusOk) {
    return false;
  }
  const std::string options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = options.c_str(),
      .on_complete = completion == nullptr ? nullptr : record_completion,
      .user_data = completion,
  };
  return backend->start(config) == kPlutoStatusOk;
}

void draw_fast_pixel(LcdifTconDisplayBackend *backend, std::uint32_t x,
                     std::uint32_t y, std::uint16_t pixel,
                     std::uint64_t frame_id) {
  OwnedPixelRequest request(x, y, pixel, frame_id);
  ASSERT_EQ(backend->submit(&request.request), kPlutoStatusOk);
  ASSERT_EQ(backend->wait_idle(3000), kPlutoStatusOk);
}

std::vector<std::uint8_t> read_wire(const std::string &path) {
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  if (!input) {
    return {};
  }
  const std::streamoff size = input.tellg();
  if (size <= 0) {
    return {};
  }
  std::vector<std::uint8_t> bytes(static_cast<std::size_t>(size));
  input.seekg(0);
  input.read(reinterpret_cast<char *>(bytes.data()), size);
  return input ? bytes : std::vector<std::uint8_t>{};
}

std::uint32_t read_u32_le(std::span<const std::uint8_t> bytes,
                          std::size_t offset) {
  if (offset > bytes.size() || bytes.size() - offset < 4u) {
    return 0;
  }
  std::uint32_t value = 0;
  for (unsigned shift = 0; shift < 32; shift += 8) {
    value |= static_cast<std::uint32_t>(bytes[offset++]) << shift;
  }
  return value;
}

std::uint64_t read_u64_le(std::span<const std::uint8_t> bytes,
                          std::size_t offset) {
  if (offset > bytes.size() || bytes.size() - offset < 8u) {
    return 0;
  }
  std::uint64_t value = 0;
  for (unsigned shift = 0; shift < 64; shift += 8) {
    value |= static_cast<std::uint64_t>(bytes[offset++]) << shift;
  }
  return value;
}

struct WireSection {
  std::uint64_t offset = 0;
  std::uint64_t size = 0;
};

std::optional<WireSection> find_wire_section(std::span<const std::uint8_t> wire,
                                             GlassHandoffSection type) {
  constexpr std::size_t kBaseHeaderBytes = 192u;
  constexpr std::size_t kSectionBytes = 32u;
  const std::uint32_t count = read_u32_le(wire, 24u);
  const std::uint32_t header_bytes = read_u32_le(wire, 8u);
  if (header_bytes != kBaseHeaderBytes + count * kSectionBytes ||
      header_bytes > wire.size()) {
    return std::nullopt;
  }
  for (std::uint32_t index = 0; index < count; ++index) {
    const std::size_t directory = kBaseHeaderBytes + index * kSectionBytes;
    if (read_u32_le(wire, directory) == static_cast<std::uint32_t>(type)) {
      const WireSection section{
          .offset = read_u64_le(wire, directory + 8u),
          .size = read_u64_le(wire, directory + 16u),
      };
      if (section.offset <= wire.size() &&
          section.size <= wire.size() - section.offset) {
        return section;
      }
      return std::nullopt;
    }
  }
  return std::nullopt;
}

void corrupt_bundle_byte(const std::string &path) {
  const int fd = ::open(path.c_str(), O_RDWR | O_CLOEXEC);
  ASSERT_GE(fd, 0);
  const off_t size = ::lseek(fd, 0, SEEK_END);
  ASSERT_GT(size, 0);
  const off_t offset = size / 2;
  std::uint8_t byte = 0;
  ASSERT_EQ(::pread(fd, &byte, sizeof(byte), offset),
            static_cast<ssize_t>(sizeof(byte)));
  byte ^= 0x80u;
  ASSERT_EQ(::pwrite(fd, &byte, sizeof(byte), offset),
            static_cast<ssize_t>(sizeof(byte)));
  ASSERT_EQ(::fsync(fd), 0);
  ASSERT_EQ(::close(fd), 0);
}

void stage_candidate(const LocalRm2Profile &fixture,
                     const std::string &handoff_path,
                     OwnedHandoffPayload *payload,
                     GlassHandoffClock (*now)() = nullptr) {
  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      [](std::string *) { return true; }, handoff_options(handoff_path, now));
  ASSERT_TRUE(probe_and_start(&backend, fixture));
  draw_fast_pixel(&backend, 17, 29, 0x7befU, 81);
  ASSERT_EQ(backend.stage_handoff(&payload->payload, 3000), kPlutoStatusOk);
  backend.stop();
  ASSERT_EQ(::access(handoff_path.c_str(), F_OK), 0);
}

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

TEST(LcdifTconBackend,
     WarmHandoffKeepsPhysicalBinaryStateSeparateFromLogicalRgb565) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  IsolatedHandoffPath handoff_path;
  OwnedHandoffPayload outgoing_payload({0x10, 0x20, 0x30, 0x40, 0x50});
  constexpr std::uint32_t kX = 17;
  constexpr std::uint32_t kY = 29;
  constexpr std::uint16_t kLogicalPixel = 0x7befU;
  const std::uint8_t expected_physical =
      rm2_fast_level(rgb565_to_rm2_level(kLogicalPixel));
  ASSERT_TRUE(expected_physical == 0u || expected_physical == 15u);

  BackendFakeLcdifSyscalls outgoing_syscalls;
  {
    auto device = std::make_unique<MxsLcdifDevice>(&outgoing_syscalls);
    LcdifTconDisplayBackend outgoing(
        fixture.profile(), std::move(device),
        [](std::string *) -> std::optional<int> { return 24000; },
        [](std::string *) { return true; },
        handoff_options(handoff_path.get()));
    ASSERT_TRUE(probe_and_start(&outgoing, fixture));
    draw_fast_pixel(&outgoing, kX, kY, kLogicalPixel, 101);
    ASSERT_EQ(outgoing.stage_handoff(&outgoing_payload.payload, 3000),
              kPlutoStatusOk);

    const std::vector<std::uint8_t> wire = read_wire(handoff_path.get());
    const std::span<const std::uint8_t> bytes(wire);
    const auto levels =
        find_wire_section(bytes, GlassHandoffSection::kEngineLevels);
    const auto dc = find_wire_section(bytes, GlassHandoffSection::kEngineDc);
    const auto renderer =
        find_wire_section(bytes, GlassHandoffSection::kRenderer);
    const auto presenter =
        find_wire_section(bytes, GlassHandoffSection::kPresenter);
    ASSERT_TRUE(levels.has_value());
    ASSERT_TRUE(dc.has_value());
    ASSERT_TRUE(renderer.has_value());
    ASSERT_TRUE(presenter.has_value());
    constexpr std::size_t kStorageStride = 1408u;
    EXPECT_EQ(levels->size, kStorageStride * kRm2PanelHeight);
    EXPECT_EQ(dc->size, levels->size);
    EXPECT_EQ(presenter->size,
              kRm2PanelWidth * kRm2PanelHeight * sizeof(std::uint16_t));
    const std::size_t physical_row = kRm2PanelHeight - 1u - kY;
    const std::size_t physical_index = physical_row * kStorageStride + kX;
    ASSERT_TRUE(levels->offset + physical_index < wire.size());
    ASSERT_TRUE(dc->offset + physical_index < wire.size());
    EXPECT_EQ(wire[levels->offset + physical_index], expected_physical);
    EXPECT_EQ(wire[dc->offset + physical_index], 0u);
    for (std::size_t x = kRm2PanelWidth; x < kStorageStride; ++x) {
      EXPECT_EQ(wire[levels->offset + physical_row * kStorageStride + x], 0u);
    }
    const std::size_t logical_index =
        (static_cast<std::size_t>(kY) * kRm2PanelWidth + kX) *
        sizeof(std::uint16_t);
    ASSERT_TRUE(presenter->offset + logical_index + 1u < wire.size());
    EXPECT_EQ(wire[presenter->offset + logical_index],
              static_cast<std::uint8_t>(kLogicalPixel));
    EXPECT_EQ(wire[presenter->offset + logical_index + 1u],
              static_cast<std::uint8_t>(kLogicalPixel >> 8u));
    EXPECT_NE(static_cast<std::uint16_t>(expected_physical), kLogicalPixel);
    EXPECT_EQ(renderer->size, outgoing_payload.bytes.size());
    EXPECT_TRUE(
        std::equal(wire.begin() + static_cast<std::size_t>(renderer->offset),
                   wire.begin() + static_cast<std::size_t>(renderer->offset +
                                                           renderer->size),
                   outgoing_payload.bytes.begin()));
    outgoing.stop();
  }

  BackendFakeLcdifSyscalls incoming_syscalls;
  int incoming_temperature_reads = 0;
  int incoming_power_checks = 0;
  auto incoming_device = std::make_unique<MxsLcdifDevice>(&incoming_syscalls);
  LcdifTconDisplayBackend incoming(
      fixture.profile(), std::move(incoming_device),
      [&](std::string *) -> std::optional<int> {
        ++incoming_temperature_reads;
        return 24000;
      },
      [&](std::string *) {
        ++incoming_power_checks;
        return true;
      },
      handoff_options(handoff_path.get()));
  ASSERT_TRUE(probe_and_start(&incoming, fixture));
  EXPECT_FALSE(incoming.ready(kPlutoRefreshFast));
  EXPECT_EQ(incoming_temperature_reads, 0);
  EXPECT_EQ(incoming_power_checks, 0);
  EXPECT_TRUE(incoming_syscalls.panned_offsets.empty());
  ASSERT_EQ(incoming_syscalls.blank_values.size(), 1u);
  EXPECT_EQ(incoming_syscalls.blank_values.front(), uapi::kBlankPowerdown);

  PlutoHandoffPayload received{.struct_size = sizeof(PlutoHandoffPayload)};
  ASSERT_EQ(incoming.get_handoff(&received), kPlutoStatusOk);
  EXPECT_EQ(received.byte_count, outgoing_payload.bytes.size());
  EXPECT_TRUE(std::equal(received.bytes, received.bytes + received.byte_count,
                         outgoing_payload.bytes.begin()));
  ASSERT_EQ(incoming.confirm_handoff(true), kPlutoStatusOk);
  EXPECT_TRUE(incoming.ready(kPlutoRefreshFast));
  EXPECT_TRUE(incoming_syscalls.panned_offsets.empty());
  EXPECT_EQ(incoming_temperature_reads, 0);
  EXPECT_EQ(incoming_power_checks, 0);
  ASSERT_EQ(incoming_syscalls.blank_values.size(), 1u);
  EXPECT_EQ(incoming_syscalls.blank_values.front(), uapi::kBlankPowerdown);

  std::vector<std::uint16_t> snapshot_pixels(kRm2PanelWidth * kRm2PanelHeight,
                                             0);
  PlutoSurface snapshot{
      .pixels = reinterpret_cast<const std::uint8_t *>(snapshot_pixels.data()),
      .stride_bytes = kRm2PanelWidth * sizeof(std::uint16_t),
      .width = static_cast<std::int32_t>(kRm2PanelWidth),
      .height = static_cast<std::int32_t>(kRm2PanelHeight),
      .format = kPlutoPixelFormatRgb565,
  };
  ASSERT_EQ(incoming.snapshot(&snapshot), kPlutoStatusOk);
  EXPECT_EQ(snapshot_pixels[static_cast<std::size_t>(kY) * kRm2PanelWidth + kX],
            kLogicalPixel);

  OwnedHandoffPayload restaged_payload({0xa1, 0xb2, 0xc3});
  ASSERT_EQ(incoming.stage_handoff(&restaged_payload.payload, 3000),
            kPlutoStatusOk);
  const std::vector<std::uint8_t> restaged = read_wire(handoff_path.get());
  const auto restaged_levels =
      find_wire_section(restaged, GlassHandoffSection::kEngineLevels);
  const auto restaged_presenter =
      find_wire_section(restaged, GlassHandoffSection::kPresenter);
  ASSERT_TRUE(restaged_levels.has_value());
  ASSERT_TRUE(restaged_presenter.has_value());
  const std::size_t physical_index = (kRm2PanelHeight - 1u - kY) * 1408u + kX;
  const std::size_t logical_index =
      (static_cast<std::size_t>(kY) * kRm2PanelWidth + kX) * 2u;
  EXPECT_EQ(restaged[restaged_levels->offset + physical_index],
            expected_physical);
  EXPECT_EQ(restaged[restaged_presenter->offset + logical_index],
            static_cast<std::uint8_t>(kLogicalPixel));
  EXPECT_EQ(restaged[restaged_presenter->offset + logical_index + 1u],
            static_cast<std::uint8_t>(kLogicalPixel >> 8u));
}

TEST(LcdifTconBackend, RendererRejectionDiscardsCandidateAndRunsInit) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  IsolatedHandoffPath path;
  OwnedHandoffPayload payload;
  stage_candidate(fixture, path.get(), &payload);

  BackendFakeLcdifSyscalls incoming_syscalls;
  int temperature_reads = 0;
  int power_checks = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&incoming_syscalls);
  LcdifTconDisplayBackend incoming(
      fixture.profile(), std::move(device),
      [&](std::string *) -> std::optional<int> {
        ++temperature_reads;
        return 24000;
      },
      [&](std::string *) {
        ++power_checks;
        return true;
      },
      handoff_options(path.get()));
  ASSERT_TRUE(probe_and_start(&incoming, fixture));
  EXPECT_FALSE(incoming.ready(kPlutoRefreshUi));
  EXPECT_EQ(temperature_reads, 0);
  ASSERT_EQ(incoming.confirm_handoff(false), kPlutoStatusOk);
  EXPECT_TRUE(incoming.ready(kPlutoRefreshUi));
  EXPECT_EQ(temperature_reads, 1);
  EXPECT_EQ(power_checks, 2);
  EXPECT_TRUE(!incoming_syscalls.panned_offsets.empty());
  ASSERT_TRUE(incoming_syscalls.blank_values.size() >= 3U);
  EXPECT_EQ(incoming_syscalls.blank_values.front(), uapi::kBlankPowerdown);
  EXPECT_EQ(incoming_syscalls
                .blank_values[incoming_syscalls.blank_values.size() - 2U],
            uapi::kBlankUnblank);
  EXPECT_EQ(incoming_syscalls.blank_values.back(), uapi::kBlankPowerdown);
  EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
}

TEST(LcdifTconBackend, CorruptCandidateFallsBackColdAndCannotBeRead) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  IsolatedHandoffPath path;
  OwnedHandoffPayload payload;
  stage_candidate(fixture, path.get(), &payload);
  corrupt_bundle_byte(path.get());

  BackendFakeLcdifSyscalls incoming_syscalls;
  int temperature_reads = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&incoming_syscalls);
  LcdifTconDisplayBackend incoming(
      fixture.profile(), std::move(device),
      [&](std::string *) -> std::optional<int> {
        ++temperature_reads;
        return 24000;
      },
      [](std::string *) { return true; }, handoff_options(path.get()));
  ASSERT_TRUE(probe_and_start(&incoming, fixture));
  EXPECT_TRUE(incoming.ready(kPlutoRefreshUi));
  EXPECT_EQ(temperature_reads, 1);
  EXPECT_TRUE(!incoming_syscalls.panned_offsets.empty());
  ASSERT_TRUE(incoming_syscalls.blank_values.size() >= 3U);
  EXPECT_EQ(incoming_syscalls.blank_values.front(), uapi::kBlankPowerdown);
  EXPECT_EQ(incoming_syscalls
                .blank_values[incoming_syscalls.blank_values.size() - 2U],
            uapi::kBlankUnblank);
  EXPECT_EQ(incoming_syscalls.blank_values.back(), uapi::kBlankPowerdown);
  EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
  PlutoHandoffPayload received{.struct_size = sizeof(PlutoHandoffPayload)};
  EXPECT_EQ(incoming.get_handoff(&received), kPlutoStatusAgain);
}

TEST(LcdifTconBackend, ExpiredCandidateFallsBackCold) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  IsolatedHandoffPath path;
  OwnedHandoffPayload payload;
  stage_candidate(fixture, path.get(), &payload, handoff_clock_100);

  BackendFakeLcdifSyscalls incoming_syscalls;
  int temperature_reads = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&incoming_syscalls);
  LcdifTconDisplayBackend incoming(
      fixture.profile(), std::move(device),
      [&](std::string *) -> std::optional<int> {
        ++temperature_reads;
        return 24000;
      },
      [](std::string *) { return true; },
      handoff_options(path.get(), handoff_clock_161));
  ASSERT_TRUE(probe_and_start(&incoming, fixture));
  EXPECT_TRUE(incoming.ready(kPlutoRefreshUi));
  EXPECT_EQ(temperature_reads, 1);
  EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
}

TEST(LcdifTconBackend, ExactPipelineIdentityMismatchFallsBackCold) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  IsolatedHandoffPath path;
  OwnedHandoffPayload payload;
  stage_candidate(fixture, path.get(), &payload);

  GeneratedDeviceProfile drifted_profile = fixture.profile();
  drifted_profile.tested_os = "3.28.0.162-pipeline-drift";
  BackendFakeLcdifSyscalls incoming_syscalls;
  int temperature_reads = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&incoming_syscalls);
  LcdifTconDisplayBackend incoming(
      drifted_profile, std::move(device),
      [&](std::string *) -> std::optional<int> {
        ++temperature_reads;
        return 24000;
      },
      [](std::string *) { return true; }, handoff_options(path.get()));
  ASSERT_EQ(incoming.probe(drifted_profile), kPlutoStatusOk);
  const std::string options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = options.c_str(),
  };
  ASSERT_EQ(incoming.start(config), kPlutoStatusOk);
  EXPECT_TRUE(incoming.ready(kPlutoRefreshUi));
  EXPECT_EQ(temperature_reads, 1);
  EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
}

TEST(LcdifTconBackend, FirstSparkleClaimsBundleAndPreventsReplay) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  IsolatedHandoffPath path;
  OwnedHandoffPayload payload;
  stage_candidate(fixture, path.get(), &payload);

  BackendFakeLcdifSyscalls consumer_syscalls;
  int consumer_temperature_reads = 0;
  {
    auto device = std::make_unique<MxsLcdifDevice>(&consumer_syscalls);
    LcdifTconDisplayBackend consumer(
        fixture.profile(), std::move(device),
        [&](std::string *) -> std::optional<int> {
          ++consumer_temperature_reads;
          return 24000;
        },
        [](std::string *) { return true; }, handoff_options(path.get()));
    ASSERT_TRUE(probe_and_start(&consumer, fixture));
    ASSERT_EQ(consumer.confirm_handoff(true), kPlutoStatusOk);
    OwnedPixelRequest sparkle(0, 0, 0xffffU, 111);
    sparkle.request.flags = kPlutoPresentFlagSparkle;
    const std::size_t pans_before = consumer_syscalls.panned_offsets.size();
    ASSERT_EQ(consumer.submit(&sparkle.request), kPlutoStatusOk);
    EXPECT_EQ(consumer_syscalls.panned_offsets.size(), pans_before);
    EXPECT_EQ(consumer_temperature_reads, 0);
    EXPECT_EQ(consumer.health().completed_jobs, 1u);
    EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
    consumer.stop();
  }

  BackendFakeLcdifSyscalls replay_syscalls;
  int replay_temperature_reads = 0;
  auto replay_device = std::make_unique<MxsLcdifDevice>(&replay_syscalls);
  LcdifTconDisplayBackend replay(
      fixture.profile(), std::move(replay_device),
      [&](std::string *) -> std::optional<int> {
        ++replay_temperature_reads;
        return 24000;
      },
      [](std::string *) { return true; }, handoff_options(path.get()));
  ASSERT_TRUE(probe_and_start(&replay, fixture));
  EXPECT_TRUE(replay.ready(kPlutoRefreshUi));
  EXPECT_EQ(replay_temperature_reads, 1);
  EXPECT_TRUE(!replay_syscalls.panned_offsets.empty());
  PlutoHandoffPayload received{.struct_size = sizeof(PlutoHandoffPayload)};
  EXPECT_EQ(replay.get_handoff(&received), kPlutoStatusAgain);
}

TEST(LcdifTconBackend, LiveIdlePageTamperFailsClosedBeforeInitSkip) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  IsolatedHandoffPath path;
  OwnedHandoffPayload payload;
  stage_candidate(fixture, path.get(), &payload);

  BackendFakeLcdifSyscalls incoming_syscalls;
  int temperature_reads = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&incoming_syscalls);
  LcdifTconDisplayBackend incoming(
      fixture.profile(), std::move(device),
      [&](std::string *) -> std::optional<int> {
        ++temperature_reads;
        return 24000;
      },
      [](std::string *) { return true; }, handoff_options(path.get()));
  ASSERT_TRUE(probe_and_start(&incoming, fixture));
  const std::size_t idle_cell = kRm2IdleSlot * kRm2SlotBytes +
                                4u * kRm2ScanoutStrideBytes +
                                26u * sizeof(std::uint32_t);
  ASSERT_TRUE(idle_cell < incoming_syscalls.storage.size());
  incoming_syscalls.storage[idle_cell] ^= std::byte{1};
  EXPECT_EQ(incoming.confirm_handoff(true), kPlutoStatusDeviceLost);
  EXPECT_EQ(temperature_reads, 0);
  EXPECT_EQ(static_cast<int>(incoming.health().state),
            static_cast<int>(NativeBackendHealthState::kDeviceLost));
  EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
}

TEST(LcdifTconBackend, LiveIdleOffsetDriftFailsClosedBeforeInitSkip) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  IsolatedHandoffPath path;
  OwnedHandoffPayload payload;
  stage_candidate(fixture, path.get(), &payload);

  BackendFakeLcdifSyscalls incoming_syscalls;
  int temperature_reads = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&incoming_syscalls);
  LcdifTconDisplayBackend incoming(
      fixture.profile(), std::move(device),
      [&](std::string *) -> std::optional<int> {
        ++temperature_reads;
        return 24000;
      },
      [](std::string *) { return true; }, handoff_options(path.get()));
  ASSERT_TRUE(probe_and_start(&incoming, fixture));
  EXPECT_TRUE(incoming_syscalls.panned_offsets.empty());
  incoming_syscalls.variable.yoffset = 0;
  EXPECT_EQ(incoming.confirm_handoff(true), kPlutoStatusDeviceLost);
  EXPECT_TRUE(incoming_syscalls.panned_offsets.empty());
  EXPECT_EQ(temperature_reads, 0);
  EXPECT_EQ(static_cast<int>(incoming.health().state),
            static_cast<int>(NativeBackendHealthState::kDeviceLost));
  EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
}

TEST(LcdifTconBackend, LostFirstAdmissionClaimFailsBeforeAnyDrive) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  IsolatedHandoffPath path;
  OwnedHandoffPayload payload;
  stage_candidate(fixture, path.get(), &payload);

  BackendFakeLcdifSyscalls incoming_syscalls;
  int temperature_reads = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&incoming_syscalls);
  LcdifTconDisplayBackend incoming(
      fixture.profile(), std::move(device),
      [&](std::string *) -> std::optional<int> {
        ++temperature_reads;
        return 24000;
      },
      [](std::string *) { return true; }, handoff_options(path.get()));
  ASSERT_TRUE(probe_and_start(&incoming, fixture));
  ASSERT_EQ(incoming.confirm_handoff(true), kPlutoStatusOk);
  ASSERT_EQ(std::remove(path.get().c_str()), 0);
  const std::size_t pans_before = incoming_syscalls.panned_offsets.size();
  OwnedPixelRequest request(2, 3, 0, 121);
  EXPECT_EQ(incoming.submit(&request.request), kPlutoStatusDeviceLost);
  EXPECT_EQ(incoming_syscalls.panned_offsets.size(), pans_before);
  EXPECT_EQ(temperature_reads, 0);
  EXPECT_EQ(static_cast<int>(incoming.health().state),
            static_cast<int>(NativeBackendHealthState::kDeviceLost));
}

TEST(LcdifTconBackend, LeaseExcludesCompetingBackendBeforeFramebufferOpen) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  IsolatedHandoffPath path;
  BackendFakeLcdifSyscalls second_syscalls;
  auto second = std::make_unique<LcdifTconDisplayBackend>(
      fixture.profile(), std::make_unique<MxsLcdifDevice>(&second_syscalls),
      [](std::string *) -> std::optional<int> { return 24000; },
      [](std::string *) { return true; }, handoff_options(path.get()));
  {
    BackendFakeLcdifSyscalls first_syscalls;
    LcdifTconDisplayBackend first(
        fixture.profile(), std::make_unique<MxsLcdifDevice>(&first_syscalls),
        [](std::string *) -> std::optional<int> { return 24000; },
        [](std::string *) { return true; }, handoff_options(path.get()));
    ASSERT_EQ(first.probe(fixture.profile()), kPlutoStatusOk);
    EXPECT_EQ(second->probe(fixture.profile()), kPlutoStatusAgain);
    EXPECT_EQ(second_syscalls.open_count, 0);
  }
  EXPECT_EQ(second->probe(fixture.profile()), kPlutoStatusOk);
  EXPECT_EQ(second_syscalls.open_count, 1);
}
#endif

} // namespace
} // namespace pluto::native::rm2
