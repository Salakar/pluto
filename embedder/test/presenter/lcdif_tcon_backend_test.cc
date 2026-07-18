#include "presenter/native/rm2/lcdif_tcon_backend.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <optional>
#include <span>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <fcntl.h>
#include <gtest/gtest.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "presenter/native/rm2/rm2_scan_encoder.h"
#include "wbf_synth.h"

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
    if (open_error != 0) {
      errno = open_error;
      return -1;
    }
    return 91;
  }
  int ioctl(int, unsigned long request, void *argument) override {
    if (request == uapi::kGetFixedScreenInfo) {
      ++get_fixed_count;
      if (fail_get_fixed_on_call == get_fixed_count) {
        errno = ioctl_error;
        return -1;
      }
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
      ++blank_count;
      if (fail_blank_on_call == blank_count) {
        errno = ioctl_error;
        return -1;
      }
      blank_values.push_back(reinterpret_cast<std::uintptr_t>(argument));
      return 0;
    }
    if (request == uapi::kPanDisplay) {
      const auto *requested =
          static_cast<uapi::FramebufferVariableInfoArm32 *>(argument);
      panned_offsets.push_back(requested->yoffset);
      pan_threads.push_back(std::this_thread::get_id());
      const std::size_t slot_index = requested->yoffset / kRm2ScanoutHeight;
      std::array<std::uint16_t, 3> before{};
      if (capture_phase_cells && slot_index < kRm2ActiveSlots) {
        before = sample_phase_cells(slot_index);
      }
      if (pan_delay > std::chrono::nanoseconds::zero()) {
        std::this_thread::sleep_for(pan_delay);
      }
      if (capture_phase_cells && slot_index < kRm2ActiveSlots) {
        const std::array<std::uint16_t, 3> after =
            sample_phase_cells(slot_index);
        latched_slot_mutations += before != after;
        panned_phase_cells.push_back(after);
      }
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

  std::array<std::uint16_t, 3>
  sample_phase_cells(std::size_t slot_index) const {
    std::array<std::uint16_t, 3> result{};
    for (std::size_t index = 0; index < result.size(); ++index) {
      std::uint32_t cell = 0;
      std::memcpy(&cell,
                  storage.data() + slot_index * kRm2SlotBytes +
                      phase_cell_offsets[index],
                  sizeof(cell));
      result[index] = static_cast<std::uint16_t>(cell);
    }
    return result;
  }

  uapi::FramebufferFixedInfoArm32 fixed{};
  uapi::FramebufferVariableInfoArm32 variable{};
  std::vector<std::byte> storage;
  std::vector<std::uintptr_t> blank_values;
  std::vector<std::uint32_t> panned_offsets;
  std::vector<std::thread::id> pan_threads;
  std::vector<std::array<std::uint16_t, 3>> panned_phase_cells;
  std::array<std::size_t, 3> phase_cell_offsets{};
  std::chrono::nanoseconds pan_delay{};
  std::size_t latched_slot_mutations = 0;
  bool capture_phase_cells = false;
  int open_error = 0;
  int ioctl_error = EIO;
  int fail_get_fixed_on_call = 0;
  int get_fixed_count = 0;
  int fail_blank_on_call = 0;
  int blank_count = 0;
  int open_count = 0;
  int close_count = 0;
};

std::size_t active_pan_count(const BackendFakeLcdifSyscalls &syscalls) {
  return static_cast<std::size_t>(
      std::count_if(syscalls.panned_offsets.begin(),
                    syscalls.panned_offsets.end(), [](std::uint32_t offset) {
                      return offset < kRm2ActiveSlots * kRm2ScanoutHeight;
                    }));
}

std::optional<std::uint16_t> snapshot_pixel(LcdifTconDisplayBackend *backend,
                                            std::uint32_t x, std::uint32_t y) {
  if (backend == nullptr || x >= kRm2PanelWidth || y >= kRm2PanelHeight) {
    return std::nullopt;
  }
  std::vector<std::uint16_t> pixels(kRm2PanelWidth * kRm2PanelHeight);
  PlutoSurface snapshot{
      .pixels = reinterpret_cast<const std::uint8_t *>(pixels.data()),
      .stride_bytes = kRm2PanelWidth * sizeof(std::uint16_t),
      .width = static_cast<std::int32_t>(kRm2PanelWidth),
      .height = static_cast<std::int32_t>(kRm2PanelHeight),
      .format = kPlutoPixelFormatRgb565,
  };
  if (backend->snapshot(&snapshot) != kPlutoStatusOk) {
    return std::nullopt;
  }
  return pixels[static_cast<std::size_t>(y) * kRm2PanelWidth + x];
}

class ScopedStderrCapture final {
public:
  ScopedStderrCapture() {
    std::fflush(stderr);
    capture_ = std::tmpfile();
    if (capture_ == nullptr) {
      return;
    }
    saved_fd_ = ::dup(STDERR_FILENO);
    if (saved_fd_ < 0 ||
        ::dup2(::fileno(capture_), STDERR_FILENO) != STDERR_FILENO) {
      if (saved_fd_ >= 0) {
        ::close(saved_fd_);
        saved_fd_ = -1;
      }
      return;
    }
    active_ = true;
  }

  ~ScopedStderrCapture() {
    restore();
    if (capture_ != nullptr) {
      std::fclose(capture_);
    }
  }

  ScopedStderrCapture(const ScopedStderrCapture &) = delete;
  ScopedStderrCapture &operator=(const ScopedStderrCapture &) = delete;

  bool valid() const { return active_; }

  std::string finish() {
    restore();
    if (capture_ == nullptr || std::fseek(capture_, 0, SEEK_SET) != 0) {
      return {};
    }
    std::string result;
    std::array<char, 512> buffer{};
    while (const std::size_t count =
               std::fread(buffer.data(), 1, buffer.size(), capture_)) {
      result.append(buffer.data(), count);
    }
    return result;
  }

private:
  void restore() {
    if (!active_) {
      return;
    }
    std::fflush(stderr);
    (void)::dup2(saved_fd_, STDERR_FILENO);
    ::close(saved_fd_);
    saved_fd_ = -1;
    active_ = false;
  }

  std::FILE *capture_ = nullptr;
  int saved_fd_ = -1;
  bool active_ = false;
};

std::size_t phase_cell_offset_for_user(std::size_t x, std::size_t y) {
  const std::size_t panel_column = kRm2PanelWidth - 1U - x;
  const std::size_t panel_row = kRm2PanelHeight - 1U - y;
  return (4U + panel_column) * kRm2ScanoutStrideBytes +
         (26U + panel_row / 8U) * sizeof(std::uint32_t);
}

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
             ("pluto_rm2_handoff_320_R124_TEST_EDSYNTHRM2_" +
              std::to_string(static_cast<long long>(::getpid())) + "_" +
              std::to_string(sequence.fetch_add(1, std::memory_order_relaxed)) +
              ".wbf"))
                .string();
    const test::SyntheticWbf fixture = test::make_synthetic_rm2_program_wbf();
    std::ofstream output(path_, std::ios::binary | std::ios::trunc);
    output.write(reinterpret_cast<const char *>(fixture.bytes.data()),
                 static_cast<std::streamsize>(fixture.bytes.size()));
    output.close();
    if (!output) {
      return;
    }
    sha256_ = wbf_sha256_hex(fixture.expected.sha256);
    panel_signature_ = fixture.expected.panel_signature;
    profile_ = *generated_device_profile_by_id("rm2");
    profile_.panel.signature = panel_signature_;
    sources_[0] = {
        .path = path_,
        .sha256 = sha256_,
        .panel_signature = panel_signature_,
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
  std::string sha256_;
  std::string panel_signature_;
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

class BackendTemporaryCpuPolicy final {
public:
  BackendTemporaryCpuPolicy() {
    std::string pattern = (std::filesystem::temp_directory_path() /
                           "pluto-rm2-backend-cpufreq-XXXXXX")
                              .string();
    char *created = ::mkdtemp(pattern.data());
    if (created == nullptr) {
      return;
    }
    root_ = created;
    policy_ = root_ / "policy0";
    runtime_ = root_ / "run";
    std::filesystem::create_directories(policy_);
    std::filesystem::create_directories(runtime_);
    write("related_cpus", "0 1\n");
    write("scaling_min_freq", "792000\n");
    write("scaling_max_freq", "1200000\n");
    write("scaling_governor", "ondemand\n");
    write("thermal_type", "imx_thermal_zone\n");
    write("cpu_temperature", "33000\n");
  }

  ~BackendTemporaryCpuPolicy() {
    std::error_code error;
    std::filesystem::remove_all(root_, error);
  }

  bool valid() const { return !root_.empty(); }

  Rm2CpuFrequencyLeasePaths paths() const {
    return {
        .policy_path = policy_.string(),
        .receipt_path = (runtime_ / "rm2-cpufreq-burst").string(),
        .lock_path = (runtime_ / "rm2-cpufreq-burst.lock").string(),
        .cpu_thermal_type_path = (policy_ / "thermal_type").string(),
        .cpu_temperature_path = (policy_ / "cpu_temperature").string(),
        .owner_start_ticks_for_testing = 67890,
    };
  }

  void write(std::string_view name, std::string_view value) const {
    std::ofstream output(policy_ / name, std::ios::binary | std::ios::trunc);
    output.write(value.data(), static_cast<std::streamsize>(value.size()));
  }

  std::string read(std::string_view name) const {
    std::ifstream input(policy_ / name, std::ios::binary);
    return {std::istreambuf_iterator<char>(input),
            std::istreambuf_iterator<char>()};
  }

  bool receipt_exists() const {
    return std::filesystem::exists(paths().receipt_path);
  }

  std::uintmax_t receipt_inode() const {
    struct stat metadata {};
    return ::stat(paths().receipt_path.c_str(), &metadata) == 0
               ? static_cast<std::uintmax_t>(metadata.st_ino)
               : 0;
  }

private:
  std::filesystem::path root_;
  std::filesystem::path policy_;
  std::filesystem::path runtime_;
};

struct BackendTransientTemperatureReader {
  unsigned remaining_eagain = 0;
  unsigned eagain_returns = 0;

  static std::ptrdiff_t read(void *context, int fd, void *buffer,
                             std::size_t capacity) {
    auto *reader = static_cast<BackendTransientTemperatureReader *>(context);
    if (reader->remaining_eagain != 0) {
      --reader->remaining_eagain;
      ++reader->eagain_returns;
      errno = EAGAIN;
      return -1;
    }
    return static_cast<std::ptrdiff_t>(::read(fd, buffer, capacity));
  }
};

bool wait_for_cpu_policy(const BackendTemporaryCpuPolicy &policy,
                         std::string_view minimum, bool receipt_exists,
                         std::chrono::milliseconds timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  do {
    if (policy.read("scaling_min_freq") == minimum &&
        policy.receipt_exists() == receipt_exists) {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  } while (std::chrono::steady_clock::now() < deadline);
  return false;
}

Rm2HandoffOptions handoff_options(const std::string &path,
                                  GlassHandoffClock (*now)() = nullptr) {
  return {
      .path = path,
      .allow_insecure_path_for_testing = true,
      .now_for_testing = now,
  };
}

Rm2PanelPowerStateReader blanked_baseline_then_power_good_reader() {
  return [sample = 0](std::string *) mutable {
    ++sample;
    return Rm2PanelPowerState{true, sample != 1, {}};
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

bool probe_and_start_profile(LcdifTconDisplayBackend *backend,
                             const GeneratedDeviceProfile &profile,
                             std::string_view waveform_path,
                             CompletionState *completion = nullptr) {
  if (backend == nullptr || waveform_path.empty()) {
    return false;
  }
  const PlutoStatus probe_status = backend->probe(profile);
  if (probe_status != kPlutoStatusOk) {
    std::fprintf(stderr, "synthetic RM2 fixture probe failed: %d\n",
                 static_cast<int>(probe_status));
    return false;
  }
  const std::string options = "wbf=" + std::string(waveform_path);
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = options.c_str(),
      .on_complete = completion == nullptr ? nullptr : record_completion,
      .user_data = completion,
  };
  const PlutoStatus start_status = backend->start(config);
  if (start_status != kPlutoStatusOk) {
    std::fprintf(stderr, "synthetic RM2 fixture start failed: %d\n",
                 static_cast<int>(start_status));
  }
  return start_status == kPlutoStatusOk;
}

bool probe_and_start(LcdifTconDisplayBackend *backend,
                     const LocalRm2Profile &fixture,
                     CompletionState *completion = nullptr) {
  return fixture.valid() &&
         probe_and_start_profile(backend, fixture.profile(),
                                 fixture.waveform_path(), completion);
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
  constexpr std::size_t kBaseHeaderBytes = 188u;
  constexpr std::size_t kSectionBytes = 28u;
  const std::uint32_t count = read_u32_le(wire, 20u);
  const std::uint32_t header_bytes = read_u32_le(wire, 4u);
  if (header_bytes != kBaseHeaderBytes + count * kSectionBytes ||
      header_bytes > wire.size()) {
    return std::nullopt;
  }
  for (std::uint32_t index = 0; index < count; ++index) {
    const std::size_t directory = kBaseHeaderBytes + index * kSectionBytes;
    if (read_u32_le(wire, directory) == static_cast<std::uint32_t>(type)) {
      const WireSection section{
          .offset = read_u64_le(wire, directory + 4u),
          .size = read_u64_le(wire, directory + 12u),
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
      blanked_baseline_then_power_good_reader(),
      handoff_options(handoff_path, now));
  ASSERT_TRUE(probe_and_start(&backend, fixture));
  draw_fast_pixel(&backend, 17, 29, 0x7befU, 81);
  ASSERT_EQ(backend.stage_handoff(&payload->payload, 3000), kPlutoStatusOk);
  backend.stop();
  ASSERT_EQ(::access(handoff_path.c_str(), F_OK), 0);
}

TEST(LcdifTconBackend, ProbeFailureReportsFramebufferStageAndDeviceError) {
  const GeneratedDeviceProfile &profile =
      *generated_device_profile_by_id("rm2");
  BackendFakeLcdifSyscalls syscalls;
  syscalls.open_error = ENODEV;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{.path = ""};
  LcdifTconDisplayBackend backend(profile, std::move(device), {}, {},
                                  std::move(options));

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  const PlutoStatus status = backend.probe(profile);
  const std::string diagnostics = capture.finish();

  EXPECT_EQ(status, kPlutoStatusDeviceLost);
  EXPECT_TRUE(diagnostics.find("stage=probe.framebuffer-open status=4") !=
              std::string::npos);
  EXPECT_TRUE(diagnostics.find("mxs_lcdif_error=\"open(/dev/fb0):") !=
              std::string::npos);
}

TEST(LcdifTconBackend,
     PoweredStartFailureReportsSafeIdleStageBeforeErrorIsCleared) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  // Probe and initialize each read the fixed mode once; fail the subsequent
  // powered safe-idle validation.
  syscalls.fail_get_fixed_on_call = 3;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{.path = ""};
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), std::move(options));
  ASSERT_EQ(backend.probe(fixture.profile()), kPlutoStatusOk);
  const std::string config_options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = config_options.c_str(),
  };

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  const PlutoStatus status = backend.start(config);
  const std::string diagnostics = capture.finish();

  EXPECT_EQ(status, kPlutoStatusDeviceLost);
  EXPECT_TRUE(diagnostics.find("stage=start.safe-idle-validate status=4") !=
              std::string::npos);
  EXPECT_TRUE(
      diagnostics.find("mxs_lcdif_error=\"validate RM2 safe-idle scan:") !=
      std::string::npos);
  EXPECT_EQ(static_cast<int>(backend.health().state),
            static_cast<int>(NativeBackendHealthState::kDeviceLost));
}

TEST(LcdifTconBackend,
     ColdInitializeReportsUnblankDeviceErrorBeforeSafetyPowerdown) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  // Initialization powers down once. Fail the following cold-start unblank;
  // later fail-safe powerdowns must not erase its diagnostic.
  syscalls.fail_blank_on_call = 2;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{.path = ""};
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), std::move(options));
  ASSERT_EQ(backend.probe(fixture.profile()), kPlutoStatusOk);
  const std::string config_options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = config_options.c_str(),
  };

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  const PlutoStatus status = backend.start(config);
  const std::string diagnostics = capture.finish();

  EXPECT_EQ(status, kPlutoStatusDeviceLost);
  EXPECT_TRUE(
      diagnostics.find(
          "stage=start.cold-initialize.powered-temperature-unblank status=4") !=
      std::string::npos);
  EXPECT_TRUE(diagnostics.find("mxs_lcdif_error=\"FBIOBLANK(UNBLANK):") !=
              std::string::npos);
  EXPECT_TRUE(diagnostics.find("stage=start.cold-initialize status=4") ==
              std::string::npos);
}

TEST(LcdifTconBackend, ColdInitializationPansRunOnDedicatedPanWorker) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{.path = ""};
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), std::move(options));

  const std::thread::id caller = std::this_thread::get_id();
  ASSERT_TRUE(probe_and_start(&backend, fixture));
  ASSERT_TRUE(!syscalls.pan_threads.empty());
  const std::thread::id pan_worker = syscalls.pan_threads.front();
  EXPECT_TRUE(pan_worker != caller);
  EXPECT_TRUE(std::all_of(syscalls.pan_threads.begin(),
                          syscalls.pan_threads.end(),
                          [pan_worker](std::thread::id pan_thread) {
                            return pan_thread == pan_worker;
                          }));
  backend.stop();
}

TEST(LcdifTconBackend,
     Rm2FrequencyBurstLeaseDebouncesAcrossWorkAndRestoresExactly) {
  LocalRm2Profile fixture;
  BackendTemporaryCpuPolicy policy;
  if (!fixture.valid() || !policy.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{
      .path = "",
      .allow_insecure_path_for_testing = true,
      .cpu_frequency_paths_for_testing = policy.paths(),
      .cpu_frequency_debounce_for_testing = std::chrono::milliseconds(500),
  };
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), std::move(options));

  ASSERT_TRUE(probe_and_start(&backend, fixture));
  ASSERT_EQ(policy.read("scaling_min_freq"), "1200000\n");
  ASSERT_TRUE(policy.receipt_exists());
  const std::uintmax_t receipt_inode = policy.receipt_inode();
  ASSERT_NE(receipt_inode, 0U);

  draw_fast_pixel(&backend, 3, 5, 0, 101);
  draw_fast_pixel(&backend, 4, 6, 0x7befU, 102);
  EXPECT_EQ(policy.read("scaling_min_freq"), "1200000\n");
  EXPECT_TRUE(policy.receipt_exists());
  EXPECT_EQ(policy.receipt_inode(), receipt_inode);

  backend.stop();
  EXPECT_EQ(policy.read("scaling_min_freq"), "792000\n");
  EXPECT_FALSE(policy.receipt_exists());
}

TEST(LcdifTconBackend, Rm2FrequencyBurstLeaseRestoresAfterIdleDebounce) {
  LocalRm2Profile fixture;
  BackendTemporaryCpuPolicy policy;
  if (!fixture.valid() || !policy.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{
      .path = "",
      .allow_insecure_path_for_testing = true,
      .cpu_frequency_paths_for_testing = policy.paths(),
      .cpu_frequency_debounce_for_testing = std::chrono::milliseconds(10),
  };
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), std::move(options));

  ASSERT_TRUE(probe_and_start(&backend, fixture));
  ASSERT_TRUE(
      wait_for_cpu_policy(policy, "792000\n", false, std::chrono::seconds(1)));
  draw_fast_pixel(&backend, 9, 11, 0, 103);
  ASSERT_TRUE(
      wait_for_cpu_policy(policy, "792000\n", false, std::chrono::seconds(1)));
  backend.stop();
}

TEST(LcdifTconBackend,
     Rm2FrequencyGuardFailurePreventsFramebufferInitializationAndAdmission) {
  LocalRm2Profile fixture;
  BackendTemporaryCpuPolicy policy;
  if (!fixture.valid() || !policy.valid()) {
    return;
  }
  policy.write("scaling_max_freq", "996000\n");
  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{
      .path = "",
      .allow_insecure_path_for_testing = true,
      .cpu_frequency_paths_for_testing = policy.paths(),
  };
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), std::move(options));

  ASSERT_EQ(backend.probe(fixture.profile()), kPlutoStatusOk);
  const std::string config_options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = config_options.c_str(),
  };
  EXPECT_EQ(backend.start(config), kPlutoStatusDeviceLost);
  EXPECT_TRUE(syscalls.blank_values.empty());
  EXPECT_TRUE(syscalls.panned_offsets.empty());
  EXPECT_FALSE(policy.receipt_exists());
  EXPECT_EQ(policy.read("scaling_min_freq"), "792000\n");
}

TEST(LcdifTconBackend,
     Rm2FrequencyGuardRejectsAChangedPolicyBeforeNextPanelSubmission) {
  LocalRm2Profile fixture;
  BackendTemporaryCpuPolicy policy;
  if (!fixture.valid() || !policy.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{
      .path = "",
      .allow_insecure_path_for_testing = true,
      .cpu_frequency_paths_for_testing = policy.paths(),
      .cpu_frequency_debounce_for_testing = std::chrono::milliseconds(10),
  };
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), std::move(options));
  ASSERT_TRUE(probe_and_start(&backend, fixture));
  ASSERT_TRUE(
      wait_for_cpu_policy(policy, "792000\n", false, std::chrono::seconds(1)));

  policy.write("scaling_max_freq", "996000\n");
  syscalls.blank_values.clear();
  syscalls.panned_offsets.clear();
  OwnedPixelRequest request(3, 7, 0, 104);
  EXPECT_EQ(backend.submit(&request.request), kPlutoStatusDeviceLost);
  EXPECT_TRUE(syscalls.panned_offsets.empty());
  EXPECT_FALSE(policy.receipt_exists());
  EXPECT_EQ(policy.read("scaling_min_freq"), "792000\n");
  backend.stop();
}

TEST(LcdifTconBackend,
     Rm2CpuThermalHoldDefersStartupWithoutFramebufferMutation) {
  LocalRm2Profile fixture;
  BackendTemporaryCpuPolicy policy;
  if (!fixture.valid() || !policy.valid()) {
    return;
  }
  policy.write("cpu_temperature", "45000\n");
  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{
      .path = "",
      .allow_insecure_path_for_testing = true,
      .cpu_frequency_paths_for_testing = policy.paths(),
  };
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), std::move(options));
  ASSERT_EQ(backend.probe(fixture.profile()), kPlutoStatusOk);
  const std::string config_options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = config_options.c_str(),
  };

  EXPECT_EQ(backend.start(config), kPlutoStatusAgain);
  EXPECT_TRUE(syscalls.blank_values.empty());
  EXPECT_TRUE(syscalls.panned_offsets.empty());
  EXPECT_EQ(backend.health().hardware_faults, 0U);
  EXPECT_FALSE(policy.receipt_exists());
  EXPECT_EQ(policy.read("scaling_min_freq"), "792000\n");

  policy.write("cpu_temperature", "33000\n");
  ASSERT_EQ(backend.start(config), kPlutoStatusOk);
  backend.stop();
}

TEST(LcdifTconBackend, Rm2UnavailableCpuTemperatureFailsStartupClosed) {
  LocalRm2Profile fixture;
  BackendTemporaryCpuPolicy policy;
  if (!fixture.valid() || !policy.valid()) {
    return;
  }
  policy.write("cpu_temperature", "unavailable\n");
  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{
      .path = "",
      .allow_insecure_path_for_testing = true,
      .cpu_frequency_paths_for_testing = policy.paths(),
  };
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), std::move(options));
  ASSERT_EQ(backend.probe(fixture.profile()), kPlutoStatusOk);
  const std::string config_options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = config_options.c_str(),
  };

  EXPECT_EQ(backend.start(config), kPlutoStatusDeviceLost);
  EXPECT_TRUE(syscalls.blank_values.empty());
  EXPECT_TRUE(syscalls.panned_offsets.empty());
  EXPECT_EQ(backend.health().hardware_faults, 1U);
  EXPECT_FALSE(policy.receipt_exists());
  EXPECT_EQ(policy.read("scaling_min_freq"), "792000\n");
}

TEST(LcdifTconBackend, Rm2TransientCpuTemperatureEagainDuringStartupRecovers) {
  LocalRm2Profile fixture;
  BackendTemporaryCpuPolicy policy;
  if (!fixture.valid() || !policy.valid()) {
    return;
  }
  BackendTransientTemperatureReader reader{.remaining_eagain = 1};
  auto frequency_paths = policy.paths();
  frequency_paths.temperature_read_for_testing =
      &BackendTransientTemperatureReader::read;
  frequency_paths.temperature_read_context_for_testing = &reader;
  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{
      .path = "",
      .allow_insecure_path_for_testing = true,
      .cpu_frequency_paths_for_testing = std::move(frequency_paths),
  };
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), std::move(options));
  ASSERT_EQ(backend.probe(fixture.profile()), kPlutoStatusOk);
  const std::string config_options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = config_options.c_str(),
  };

  ASSERT_EQ(backend.start(config), kPlutoStatusOk);
  EXPECT_EQ(reader.eagain_returns, 1U);
  EXPECT_EQ(backend.health().hardware_faults, 0U);
  backend.stop();
  EXPECT_EQ(policy.read("scaling_min_freq"), "792000\n");
  EXPECT_FALSE(policy.receipt_exists());
}

TEST(LcdifTconBackend,
     Rm2ExhaustedCpuTemperatureEagainDefersStartupWithoutDeviceLoss) {
  LocalRm2Profile fixture;
  BackendTemporaryCpuPolicy policy;
  if (!fixture.valid() || !policy.valid()) {
    return;
  }
  BackendTransientTemperatureReader reader{
      .remaining_eagain = kRm2CpuTemperatureReadAttempts * 2U};
  auto frequency_paths = policy.paths();
  frequency_paths.temperature_read_for_testing =
      &BackendTransientTemperatureReader::read;
  frequency_paths.temperature_read_context_for_testing = &reader;
  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{
      .path = "",
      .allow_insecure_path_for_testing = true,
      .cpu_frequency_paths_for_testing = std::move(frequency_paths),
      .cpu_thermal_retry_delay_for_testing = std::chrono::milliseconds(1),
  };
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), std::move(options));
  ASSERT_EQ(backend.probe(fixture.profile()), kPlutoStatusOk);
  const std::string config_options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = config_options.c_str(),
  };

  EXPECT_EQ(backend.start(config), kPlutoStatusAgain);
  EXPECT_EQ(reader.eagain_returns, kRm2CpuTemperatureReadAttempts * 2U);
  EXPECT_TRUE(syscalls.blank_values.empty());
  EXPECT_TRUE(syscalls.panned_offsets.empty());
  EXPECT_EQ(backend.health().hardware_faults, 0U);
  EXPECT_FALSE(policy.receipt_exists());
  EXPECT_EQ(policy.read("scaling_min_freq"), "792000\n");

  ASSERT_EQ(backend.start(config), kPlutoStatusOk);
  EXPECT_EQ(backend.health().hardware_faults, 0U);
  backend.stop();
  EXPECT_EQ(policy.read("scaling_min_freq"), "792000\n");
  EXPECT_FALSE(policy.receipt_exists());
}

TEST(LcdifTconBackend,
     Rm2LocalStartupRetryRecoversAfterOneExhaustedEagainWindow) {
  LocalRm2Profile fixture;
  BackendTemporaryCpuPolicy policy;
  if (!fixture.valid() || !policy.valid()) {
    return;
  }
  BackendTransientTemperatureReader reader{.remaining_eagain =
                                               kRm2CpuTemperatureReadAttempts};
  auto frequency_paths = policy.paths();
  frequency_paths.temperature_read_for_testing =
      &BackendTransientTemperatureReader::read;
  frequency_paths.temperature_read_context_for_testing = &reader;
  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{
      .path = "",
      .allow_insecure_path_for_testing = true,
      .cpu_frequency_paths_for_testing = std::move(frequency_paths),
      .cpu_thermal_retry_delay_for_testing = std::chrono::milliseconds(1),
  };
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), std::move(options));
  ASSERT_EQ(backend.probe(fixture.profile()), kPlutoStatusOk);
  const std::string config_options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = config_options.c_str(),
  };

  ASSERT_EQ(backend.start(config), kPlutoStatusOk);
  EXPECT_EQ(reader.eagain_returns, kRm2CpuTemperatureReadAttempts);
  EXPECT_EQ(backend.health().hardware_faults, 0U);
  backend.stop();
  EXPECT_EQ(policy.read("scaling_min_freq"), "792000\n");
  EXPECT_FALSE(policy.receipt_exists());
}

TEST(LcdifTconBackend,
     Rm2ExhaustedCpuTemperatureEagainBackpressuresAdmissionAndRecovers) {
  LocalRm2Profile fixture;
  BackendTemporaryCpuPolicy policy;
  if (!fixture.valid() || !policy.valid()) {
    return;
  }
  BackendTransientTemperatureReader reader;
  auto frequency_paths = policy.paths();
  frequency_paths.temperature_read_for_testing =
      &BackendTransientTemperatureReader::read;
  frequency_paths.temperature_read_context_for_testing = &reader;
  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{
      .path = "",
      .allow_insecure_path_for_testing = true,
      .cpu_frequency_paths_for_testing = std::move(frequency_paths),
      .cpu_frequency_debounce_for_testing = std::chrono::milliseconds(10),
      .cpu_thermal_retry_delay_for_testing = std::chrono::milliseconds(20),
  };
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), std::move(options));
  ASSERT_TRUE(probe_and_start(&backend, fixture));
  ASSERT_TRUE(
      wait_for_cpu_policy(policy, "792000\n", false, std::chrono::seconds(1)));

  reader.remaining_eagain = kRm2CpuTemperatureReadAttempts;
  syscalls.blank_values.clear();
  syscalls.panned_offsets.clear();
  OwnedPixelRequest request(3, 7, 0, 107);
  EXPECT_EQ(backend.submit(&request.request), kPlutoStatusAgain);
  EXPECT_EQ(reader.eagain_returns, kRm2CpuTemperatureReadAttempts);
  EXPECT_EQ(backend.wait_idle(0), kPlutoStatusOk);
  EXPECT_FALSE(backend.ready(kPlutoRefreshFast));
  EXPECT_EQ(static_cast<int>(backend.health().state),
            static_cast<int>(NativeBackendHealthState::kBusy));
  EXPECT_EQ(backend.health().hardware_faults, 0U);
  EXPECT_EQ(backend.health().completed_jobs, 0U);
  EXPECT_TRUE(syscalls.panned_offsets.empty());
  ASSERT_TRUE(!syscalls.blank_values.empty());
  EXPECT_EQ(syscalls.blank_values.back(), uapi::kBlankPowerdown);
  EXPECT_FALSE(policy.receipt_exists());
  EXPECT_EQ(policy.read("scaling_min_freq"), "792000\n");

  const std::size_t blank_count_during_retry = syscalls.blank_values.size();
  EXPECT_EQ(backend.submit(&request.request), kPlutoStatusAgain);
  EXPECT_EQ(reader.eagain_returns, kRm2CpuTemperatureReadAttempts);
  EXPECT_EQ(syscalls.blank_values.size(), blank_count_during_retry);

  const auto ready_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(1);
  while (!backend.ready(kPlutoRefreshFast) &&
         std::chrono::steady_clock::now() < ready_deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  ASSERT_TRUE(backend.ready(kPlutoRefreshFast));
  ASSERT_EQ(backend.submit(&request.request), kPlutoStatusOk);
  ASSERT_EQ(backend.wait_idle(3000), kPlutoStatusOk);
  EXPECT_EQ(backend.health().hardware_faults, 0U);
  EXPECT_EQ(backend.health().completed_jobs, 1U);
  backend.stop();
  EXPECT_EQ(policy.read("scaling_min_freq"), "792000\n");
  EXPECT_FALSE(policy.receipt_exists());
}

TEST(LcdifTconBackend, Rm2CpuThermalHoldBackpressuresAdmissionAndRecovers) {
  LocalRm2Profile fixture;
  BackendTemporaryCpuPolicy policy;
  if (!fixture.valid() || !policy.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{
      .path = "",
      .allow_insecure_path_for_testing = true,
      .cpu_frequency_paths_for_testing = policy.paths(),
      .cpu_frequency_debounce_for_testing = std::chrono::milliseconds(10),
      .cpu_thermal_retry_delay_for_testing = std::chrono::milliseconds(20),
  };
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), std::move(options));
  ASSERT_TRUE(probe_and_start(&backend, fixture));
  ASSERT_TRUE(
      wait_for_cpu_policy(policy, "792000\n", false, std::chrono::seconds(1)));

  policy.write("cpu_temperature", "45000\n");
  syscalls.blank_values.clear();
  syscalls.panned_offsets.clear();
  OwnedPixelRequest request(3, 7, 0, 106);
  EXPECT_EQ(backend.submit(&request.request), kPlutoStatusAgain);
  EXPECT_EQ(backend.wait_idle(0), kPlutoStatusOk);
  EXPECT_FALSE(backend.ready(kPlutoRefreshFast));
  EXPECT_EQ(static_cast<int>(backend.health().state),
            static_cast<int>(NativeBackendHealthState::kBusy));
  EXPECT_EQ(backend.health().hardware_faults, 0U);
  EXPECT_EQ(backend.health().completed_jobs, 0U);
  EXPECT_TRUE(syscalls.panned_offsets.empty());
  ASSERT_TRUE(!syscalls.blank_values.empty());
  EXPECT_EQ(syscalls.blank_values.back(), uapi::kBlankPowerdown);
  EXPECT_FALSE(policy.receipt_exists());
  EXPECT_EQ(policy.read("scaling_min_freq"), "792000\n");

  const std::size_t blank_count_during_hold = syscalls.blank_values.size();
  EXPECT_EQ(backend.submit(&request.request), kPlutoStatusAgain);
  EXPECT_FALSE(backend.ready(kPlutoRefreshFast));
  EXPECT_EQ(syscalls.blank_values.size(), blank_count_during_hold);
  EXPECT_TRUE(syscalls.panned_offsets.empty());

  policy.write("cpu_temperature", "33000\n");
  const auto ready_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(1);
  while (!backend.ready(kPlutoRefreshFast) &&
         std::chrono::steady_clock::now() < ready_deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  ASSERT_TRUE(backend.ready(kPlutoRefreshFast));
  EXPECT_EQ(static_cast<int>(backend.health().state),
            static_cast<int>(NativeBackendHealthState::kReady));
  const std::size_t unblank_count_before = static_cast<std::size_t>(
      std::count(syscalls.blank_values.begin(), syscalls.blank_values.end(),
                 static_cast<std::uintptr_t>(uapi::kBlankUnblank)));
  ASSERT_EQ(backend.submit(&request.request), kPlutoStatusOk);
  ASSERT_EQ(backend.wait_idle(3000), kPlutoStatusOk);
  const std::size_t unblank_count_after = static_cast<std::size_t>(
      std::count(syscalls.blank_values.begin(), syscalls.blank_values.end(),
                 static_cast<std::uintptr_t>(uapi::kBlankUnblank)));
  EXPECT_GT(unblank_count_after, unblank_count_before);
  EXPECT_EQ(backend.health().hardware_faults, 0U);
  EXPECT_EQ(backend.health().completed_jobs, 1U);
  backend.stop();
}

TEST(LcdifTconBackend, Rm2FrequencyBurstRejectsPanelTemperatureAt45C) {
  LocalRm2Profile fixture;
  BackendTemporaryCpuPolicy policy;
  if (!fixture.valid() || !policy.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{
      .path = "",
      .allow_insecure_path_for_testing = true,
      .cpu_frequency_paths_for_testing = policy.paths(),
      .cpu_frequency_debounce_for_testing = std::chrono::milliseconds(10),
  };
  int temperature_reads = 0;
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [&](std::string *) -> std::optional<int> {
        return ++temperature_reads == 1 ? 24000 : 45000;
      },
      blanked_baseline_then_power_good_reader(), std::move(options));
  ASSERT_TRUE(probe_and_start(&backend, fixture));
  ASSERT_TRUE(
      wait_for_cpu_policy(policy, "792000\n", false, std::chrono::seconds(1)));
  syscalls.panned_offsets.clear();

  OwnedPixelRequest request(4, 8, 0, 105);
  EXPECT_EQ(backend.submit(&request.request), kPlutoStatusDeviceLost);
  EXPECT_TRUE(std::all_of(syscalls.panned_offsets.begin(),
                          syscalls.panned_offsets.end(),
                          [](std::uint32_t offset) {
                            return offset == kRm2IdleSlot * kRm2ScanoutHeight;
                          }));
  EXPECT_EQ(policy.read("scaling_min_freq"), "792000\n");
  EXPECT_FALSE(policy.receipt_exists());
  backend.stop();
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
  int power_checks_at_last_temperature = 0;
  bool power_checks_follow_safe_hold = true;
  bool temperature_reads_follow_power_check = true;
  auto device = std::make_unique<MxsLcdifDevice>(&fake);
  LcdifTconDisplayBackend backend(
      profile, std::move(device),
      [&](std::string *) -> std::optional<int> {
        ++temperature_reads;
        temperature_reads_follow_power_check &=
            power_checks > power_checks_at_last_temperature &&
            !fake.blank_values.empty() &&
            fake.blank_values.back() == uapi::kBlankUnblank &&
            !fake.panned_offsets.empty() &&
            fake.panned_offsets.back() == kRm2IdleSlot * kRm2ScanoutHeight;
        power_checks_at_last_temperature = power_checks;
        return 24000;
      },
      [&](std::string *) {
        ++power_checks;
        if (power_checks == 1) {
          return Rm2PanelPowerState{true, false, {}};
        }
        const bool follows_safe_hold =
            !fake.blank_values.empty() &&
            fake.blank_values.back() == uapi::kBlankUnblank &&
            !fake.panned_offsets.empty() &&
            fake.panned_offsets.back() == kRm2IdleSlot * kRm2ScanoutHeight;
        power_checks_follow_safe_hold &= follows_safe_hold;
        return Rm2PanelPowerState{follows_safe_hold};
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
  EXPECT_EQ(power_checks, 5);
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
  EXPECT_EQ(power_checks, 9);
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
          if (power_checks == 1) {
            return Rm2PanelPowerState{true, false, {}};
          }
          return Rm2PanelPowerState{power_checks == 2};
        });
    ASSERT_EQ(backend.probe(profile), kPlutoStatusOk);
    EXPECT_EQ(backend.start(config), kPlutoStatusDeviceLost);
    EXPECT_EQ(power_checks, 3);
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
          return Rm2PanelPowerState{true, power_checks != 1, {}};
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

  fs::remove(local_path, filesystem_error);
}

TEST(LcdifTconBackend,
     ChangingPanelFaultDiagnosticsRemainNonFatalWhilePowerGoodStable) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  CompletionState completion;
  int power_samples = 0;
  bool sample_followed_powerdown = false;
  bool sample_preceded_any_pan = true;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      [&](std::string *) {
        ++power_samples;
        if (power_samples == 1) {
          sample_followed_powerdown =
              syscalls.blank_values.size() == 1U &&
              syscalls.blank_values.back() == uapi::kBlankPowerdown;
          sample_preceded_any_pan = !syscalls.panned_offsets.empty();
          return Rm2PanelPowerState{true, false, "UVP at VNEG rail"};
        }
        constexpr std::array<std::string_view, 4> kChangingDiagnostics = {
            "UVP at VNEG rail",
            "UVP at VN rail",
            "no fault event",
            "UVP at VEE rail",
        };
        const std::string_view diagnostic =
            kChangingDiagnostics[static_cast<std::size_t>(power_samples - 2) %
                                 kChangingDiagnostics.size()];
        return Rm2PanelPowerState{true, true,
                                  diagnostic == "no fault event"
                                      ? std::string{}
                                      : std::string(diagnostic)};
      },
      Rm2HandoffOptions{.path = ""});

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  ASSERT_TRUE(probe_and_start(&backend, fixture, &completion));
  draw_fast_pixel(&backend, 3, 5, 0, 201);
  draw_fast_pixel(&backend, 4, 6, 0x7befU, 202);
  draw_fast_pixel(&backend, 5, 7, 0, 203);
  EXPECT_EQ(completion.count.load(std::memory_order_acquire), 3);
  EXPECT_EQ(backend.health().completed_jobs, 3U);
  EXPECT_EQ(backend.health().hardware_faults, 0U);
  EXPECT_EQ(power_samples, 17);
  EXPECT_TRUE(sample_followed_powerdown);
  EXPECT_FALSE(sample_preceded_any_pan);
  backend.stop();
  const std::string diagnostics = capture.finish();

  EXPECT_TRUE(diagnostics.find(
                  "powered-down fault diagnostic power_good=OFF state=\"UVP "
                  "at VNEG rail\"") != std::string::npos);
  EXPECT_TRUE(
      diagnostics.find("panel fault-register diagnostic "
                       "stage=start.cold-initialize.powered-temperature-power-"
                       "precheck previous=\"<unobserved>\" observed=\"UVP at "
                       "VNEG rail\"") != std::string::npos);
  EXPECT_TRUE(diagnostics.find("fault_diagnostic_samples=16 "
                               "fault_diagnostic_changes=15") !=
              std::string::npos);
  EXPECT_TRUE(diagnostics.find("RM2 present failure") == std::string::npos);
}

TEST(LcdifTconBackend,
     BlankedPanelPowerGoodContradictionFailsPowerdownWithExactStage) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  int power_samples = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      [&](std::string *) {
        ++power_samples;
        return Rm2PanelPowerState{true, true, {}};
      },
      Rm2HandoffOptions{
          .path = "",
          .panel_powerdown_settle_timeout_for_testing =
              std::chrono::milliseconds(2),
          .panel_powerdown_poll_interval_for_testing =
              std::chrono::milliseconds(1),
      });
  ASSERT_EQ(backend.probe(fixture.profile()), kPlutoStatusOk);
  const std::string config_options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = config_options.c_str(),
  };

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  EXPECT_EQ(backend.start(config), kPlutoStatusDeviceLost);
  EXPECT_GE(power_samples, 1);
  ASSERT_TRUE(!syscalls.blank_values.empty());
  EXPECT_EQ(syscalls.blank_values.back(), uapi::kBlankPowerdown);
  const std::string diagnostics = capture.finish();

  EXPECT_TRUE(diagnostics.find("stage=start.panel-powerdown-state status=4") !=
              std::string::npos);
  EXPECT_TRUE(diagnostics.find(
                  "reason=\"SY7636A panel power-good remained 'ON' after 2 ms "
                  "framebuffer powerdown settle\"") != std::string::npos);
}

TEST(LcdifTconBackend,
     BlankedPanelPowerGoodDecayRetriesUnstableSampleThenSettles) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  int power_samples = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      [&](std::string *) {
        ++power_samples;
        if (power_samples == 1) {
          return Rm2PanelPowerState{true, true, {}};
        }
        if (power_samples == 2) {
          Rm2PanelPowerState changing{true, false, "UVP at VN rail"};
          changing.power_good_stable = false;
          return changing;
        }
        return Rm2PanelPowerState{true, power_samples != 3, {}};
      },
      Rm2HandoffOptions{
          .path = "",
          .panel_powerdown_settle_timeout_for_testing =
              std::chrono::milliseconds(10),
          .panel_powerdown_poll_interval_for_testing =
              std::chrono::milliseconds(1),
      });

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  ASSERT_TRUE(probe_and_start(&backend, fixture));
  EXPECT_GE(power_samples, 7);
  EXPECT_EQ(backend.health().hardware_faults, 0U);
  backend.stop();
  const std::string diagnostics = capture.finish();

  EXPECT_TRUE(diagnostics.find("RM2 panel powerdown settled samples=3") !=
              std::string::npos);
  EXPECT_TRUE(diagnostics.find("stage=start.panel-powerdown-state status=") ==
              std::string::npos);
}

TEST(LcdifTconBackend,
     ValidWarmHandoffMayRetainPoweredCanonicalSafeHoldAfterSettleWindow) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  IsolatedHandoffPath path;
  OwnedHandoffPayload payload;
  stage_candidate(fixture, path.get(), &payload);

  BackendFakeLcdifSyscalls incoming_syscalls;
  ASSERT_TRUE(
      fill_rm2_scan_slot(std::span<std::byte>(incoming_syscalls.storage.data() +
                                                  kRm2IdleSlot * kRm2SlotBytes,
                                              kRm2SlotBytes),
                         0));
  int power_samples = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&incoming_syscalls);
  LcdifTconDisplayBackend incoming(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      [&](std::string *) {
        ++power_samples;
        return Rm2PanelPowerState{true, true, "UVP at VNEG rail"};
      },
      Rm2HandoffOptions{
          .path = path.get(),
          .allow_insecure_path_for_testing = true,
          .panel_powerdown_settle_timeout_for_testing =
              std::chrono::milliseconds(2),
          .panel_powerdown_poll_interval_for_testing =
              std::chrono::milliseconds(1),
      });

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  ASSERT_TRUE(probe_and_start(&incoming, fixture));
  EXPECT_FALSE(incoming.ready(kPlutoRefreshFast));
  EXPECT_GE(power_samples, 1);
  EXPECT_TRUE(incoming_syscalls.panned_offsets.empty());
  PlutoHandoffPayload received{.struct_size = sizeof(PlutoHandoffPayload)};
  ASSERT_EQ(incoming.get_handoff(&received), kPlutoStatusOk);
  ASSERT_EQ(incoming.confirm_handoff(true), kPlutoStatusOk);
  EXPECT_TRUE(incoming.ready(kPlutoRefreshFast));
  incoming.stop();
  const std::string diagnostics = capture.finish();

  EXPECT_TRUE(
      diagnostics.find("RM2 retained-powered safe-HOLD accepted samples=") !=
      std::string::npos);
  EXPECT_TRUE(diagnostics.find("power_good=ON state=\"UVP at VNEG rail\"") !=
              std::string::npos);
  EXPECT_TRUE(diagnostics.find("RM2 startup failure") == std::string::npos);
}

TEST(LcdifTconBackend, PoweredWarmHandoffStillRejectsNoncanonicalLiveIdleSlot) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  IsolatedHandoffPath path;
  OwnedHandoffPayload payload;
  stage_candidate(fixture, path.get(), &payload);

  BackendFakeLcdifSyscalls incoming_syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&incoming_syscalls);
  LcdifTconDisplayBackend incoming(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      [](std::string *) { return Rm2PanelPowerState{true, true, {}}; },
      Rm2HandoffOptions{
          .path = path.get(),
          .allow_insecure_path_for_testing = true,
          .panel_powerdown_settle_timeout_for_testing =
              std::chrono::milliseconds(2),
          .panel_powerdown_poll_interval_for_testing =
              std::chrono::milliseconds(1),
      });

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  ASSERT_EQ(incoming.probe(fixture.profile()), kPlutoStatusOk);
  const std::string config_options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = config_options.c_str(),
  };
  EXPECT_EQ(incoming.start(config), kPlutoStatusDeviceLost);
  EXPECT_TRUE(incoming_syscalls.panned_offsets.empty());
  const std::string diagnostics = capture.finish();

  EXPECT_TRUE(
      diagnostics.find("stage=start.powered-handoff-safe-idle status=4") !=
      std::string::npos);
  EXPECT_TRUE(diagnostics.find("retained-powered handoff is not on the "
                               "canonical safe HOLD slot") !=
              std::string::npos);
}

TEST(LcdifTconBackend,
     UnreadablePanelPowerdownStateFailsExactStageBeforeAnyPan) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  int power_samples = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      [&](std::string *error) {
        ++power_samples;
        if (error != nullptr) {
          *error = "synthetic unreadable panel powerdown state";
        }
        return Rm2PanelPowerState{};
      },
      Rm2HandoffOptions{.path = ""});
  ASSERT_EQ(backend.probe(fixture.profile()), kPlutoStatusOk);
  const std::string config_options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = config_options.c_str(),
  };

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  EXPECT_EQ(backend.start(config), kPlutoStatusDeviceLost);
  EXPECT_EQ(power_samples, 1);
  EXPECT_TRUE(syscalls.panned_offsets.empty());
  EXPECT_EQ(backend.health().hardware_faults, 1U);
  ASSERT_TRUE(!syscalls.blank_values.empty());
  EXPECT_EQ(syscalls.blank_values.back(), uapi::kBlankPowerdown);
  const std::string diagnostics = capture.finish();

  EXPECT_TRUE(diagnostics.find("stage=start.panel-powerdown-state status=4") !=
              std::string::npos);
  EXPECT_TRUE(diagnostics.find(
                  "reason=\"synthetic unreadable panel powerdown state\"") !=
              std::string::npos);
}

TEST(LcdifTconBackend,
     UnreadablePoweredPanelStateReportsExactPreAndPostStages) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  const std::string config_options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = config_options.c_str(),
  };

  {
    BackendFakeLcdifSyscalls syscalls;
    int power_samples = 0;
    auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
    LcdifTconDisplayBackend backend(
        fixture.profile(), std::move(device),
        [](std::string *) -> std::optional<int> { return 24000; },
        [&](std::string *error) {
          ++power_samples;
          if (power_samples == 1) {
            return Rm2PanelPowerState{true, false, {}};
          }
          if (error != nullptr) {
            *error = "synthetic powered precheck unavailable";
          }
          return Rm2PanelPowerState{};
        },
        Rm2HandoffOptions{.path = ""});
    ASSERT_EQ(backend.probe(fixture.profile()), kPlutoStatusOk);
    ScopedStderrCapture capture;
    ASSERT_TRUE(capture.valid());
    EXPECT_EQ(backend.start(config), kPlutoStatusDeviceLost);
    EXPECT_EQ(power_samples, 2);
    EXPECT_EQ(backend.health().hardware_faults, 1U);
    const std::string diagnostics = capture.finish();
    EXPECT_TRUE(
        diagnostics.find(
            "stage=start.cold-initialize.powered-temperature-power-precheck "
            "status=4") != std::string::npos);
    EXPECT_TRUE(
        diagnostics.find("reason=\"synthetic powered precheck unavailable\"") !=
        std::string::npos);
  }

  {
    BackendFakeLcdifSyscalls syscalls;
    int power_samples = 0;
    auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
    LcdifTconDisplayBackend backend(
        fixture.profile(), std::move(device),
        [](std::string *) -> std::optional<int> { return 24000; },
        [&](std::string *error) {
          ++power_samples;
          if (power_samples == 1) {
            return Rm2PanelPowerState{true, false, {}};
          }
          if (power_samples == 2) {
            return Rm2PanelPowerState{true, true, {}};
          }
          if (error != nullptr) {
            *error = "synthetic powered postcheck unavailable";
          }
          return Rm2PanelPowerState{};
        },
        Rm2HandoffOptions{.path = ""});
    ASSERT_EQ(backend.probe(fixture.profile()), kPlutoStatusOk);
    ScopedStderrCapture capture;
    ASSERT_TRUE(capture.valid());
    EXPECT_EQ(backend.start(config), kPlutoStatusDeviceLost);
    EXPECT_EQ(power_samples, 3);
    EXPECT_EQ(backend.health().hardware_faults, 1U);
    const std::string diagnostics = capture.finish();
    EXPECT_TRUE(
        diagnostics.find(
            "stage=start.cold-initialize.powered-temperature-power-postcheck "
            "status=4") != std::string::npos);
    EXPECT_TRUE(diagnostics.find(
                    "reason=\"synthetic powered postcheck unavailable\"") !=
                std::string::npos);
  }
}

TEST(LcdifTconBackend,
     NewPanelFaultDiagnosticOnThirdJobRemainsNonFatalWhilePowerGood) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  CompletionState completion;
  int power_samples = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      [&](std::string *) {
        ++power_samples;
        if (power_samples == 1) {
          return Rm2PanelPowerState{true, false, {}};
        }
        return Rm2PanelPowerState{true, true,
                                  power_samples >= 14 ? "SCP at V COM rail"
                                                      : std::string{}};
      },
      Rm2HandoffOptions{.path = ""});

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  ASSERT_TRUE(probe_and_start(&backend, fixture, &completion));
  draw_fast_pixel(&backend, 3, 5, 0, 211);
  draw_fast_pixel(&backend, 4, 6, 0x7befU, 212);
  draw_fast_pixel(&backend, 5, 7, 0, 213);
  EXPECT_EQ(completion.count.load(std::memory_order_acquire), 3);
  EXPECT_EQ(backend.health().completed_jobs, 3U);
  EXPECT_EQ(backend.health().hardware_faults, 0U);
  EXPECT_EQ(power_samples, 17);
  backend.stop();
  const std::string diagnostics = capture.finish();

  EXPECT_TRUE(diagnostics.find(
                  "panel fault-register diagnostic "
                  "stage=present.powered-temperature-power-precheck "
                  "previous=\"no fault event\" observed=\"SCP at V COM rail\" "
                  "changes=1; stable power_good=ON") != std::string::npos);
  EXPECT_TRUE(diagnostics.find("fault_diagnostic_samples=16 "
                               "fault_diagnostic_changes=1") !=
              std::string::npos);
  EXPECT_TRUE(diagnostics.find("RM2 present failure") == std::string::npos);
}

TEST(LcdifTconBackend, PoweredDownFaultDiagnosticDoesNotBindPoweredColdStart) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  int power_samples = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      [&](std::string *) {
        ++power_samples;
        if (power_samples == 1) {
          return Rm2PanelPowerState{true, false, "UVP at VNEG rail"};
        }
        return Rm2PanelPowerState{true, true, {}};
      },
      Rm2HandoffOptions{.path = ""});
  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  ASSERT_TRUE(probe_and_start(&backend, fixture));
  EXPECT_EQ(power_samples, 5);
  EXPECT_EQ(backend.health().hardware_faults, 0U);
  backend.stop();
  const std::string diagnostics = capture.finish();

  EXPECT_TRUE(diagnostics.find(
                  "powered-down fault diagnostic power_good=OFF state=\"UVP "
                  "at VNEG rail\"") != std::string::npos);
  EXPECT_TRUE(diagnostics.find("fault_diagnostic_samples=4 "
                               "fault_diagnostic_changes=0") !=
              std::string::npos);
  EXPECT_TRUE(diagnostics.find("RM2 startup failure") == std::string::npos);
}

TEST(LcdifTconBackend,
     LivePowerGoodLossOnThirdJobPostcheckFailsClosedWithExactStage) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  CompletionState completion;
  int power_samples = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      [&](std::string *error) {
        ++power_samples;
        if (power_samples == 1) {
          return Rm2PanelPowerState{true, false, {}};
        }
        if (power_samples == 15) {
          if (error != nullptr) {
            *error = "SY7636A panel power-good='OFF' state='no fault event'";
          }
          return Rm2PanelPowerState{true, false, {}};
        }
        return Rm2PanelPowerState{true};
      },
      Rm2HandoffOptions{.path = ""});

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  ASSERT_TRUE(probe_and_start(&backend, fixture, &completion));
  draw_fast_pixel(&backend, 3, 5, 0, 221);
  draw_fast_pixel(&backend, 4, 6, 0x7befU, 222);
  OwnedPixelRequest third(5, 7, 0, 223);
  EXPECT_EQ(backend.submit(&third.request), kPlutoStatusDeviceLost);
  EXPECT_EQ(completion.count.load(std::memory_order_acquire), 2);
  EXPECT_EQ(backend.health().completed_jobs, 2U);
  EXPECT_EQ(backend.health().hardware_faults, 1U);
  EXPECT_EQ(power_samples, 15);
  ASSERT_TRUE(!syscalls.blank_values.empty());
  EXPECT_EQ(syscalls.blank_values.back(), uapi::kBlankPowerdown);
  backend.stop();
  const std::string diagnostics = capture.finish();

  EXPECT_TRUE(
      diagnostics.find(
          "RM2 present failure "
          "stage=present.powered-temperature-power-postcheck status=4") !=
      std::string::npos);
  EXPECT_TRUE(diagnostics.find("reason=\"SY7636A panel power-good='OFF' "
                               "state='no fault event'\"") !=
              std::string::npos);
}

TEST(LcdifTconBackend,
     ColdInitPreDriveStateFailureStopsAfterSlotPreparationWithoutActivePan) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  constexpr std::size_t kDriveCellOffset =
      3U * kRm2ScanoutStrideBytes + 26U * sizeof(std::uint32_t);
  syscalls.phase_cell_offsets = {
      kDriveCellOffset,
      kDriveCellOffset,
      kDriveCellOffset,
  };
  CompletionState completion;
  int power_samples = 0;
  bool armed_at_pre_drive_sample = false;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      [&](std::string *error) {
        ++power_samples;
        if (power_samples == 1) {
          return Rm2PanelPowerState{true, false, {}};
        }
        const bool slots_prepared =
            syscalls.sample_phase_cells(0)[0] == 0U &&
            syscalls.sample_phase_cells(1)[0] == 0x5555U &&
            syscalls.sample_phase_cells(2)[0] == 0xaaaaU;
        if (slots_prepared && active_pan_count(syscalls) == 0U) {
          armed_at_pre_drive_sample = true;
          if (error != nullptr) {
            *error = "synthetic cold INIT pre-drive state unavailable";
          }
          return Rm2PanelPowerState{};
        }
        return Rm2PanelPowerState{true, true, {}};
      },
      Rm2HandoffOptions{.path = ""});
  ASSERT_EQ(backend.probe(fixture.profile()), kPlutoStatusOk);
  const std::string config_options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = config_options.c_str(),
      .on_complete = record_completion,
      .user_data = &completion,
  };

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  EXPECT_EQ(backend.start(config), kPlutoStatusDeviceLost);
  EXPECT_TRUE(armed_at_pre_drive_sample);
  EXPECT_EQ(power_samples, 4);
  EXPECT_EQ(active_pan_count(syscalls), 0U);
  EXPECT_EQ(syscalls.sample_phase_cells(0)[0], 0U);
  EXPECT_EQ(syscalls.sample_phase_cells(1)[0], 0x5555U);
  EXPECT_EQ(syscalls.sample_phase_cells(2)[0], 0xaaaaU);
  EXPECT_EQ(completion.count.load(std::memory_order_acquire), 0);
  EXPECT_FALSE(snapshot_pixel(&backend, 0, 0).has_value());
  EXPECT_EQ(backend.health().completed_jobs, 0U);
  EXPECT_EQ(backend.health().hardware_faults, 1U);
  ASSERT_TRUE(!syscalls.blank_values.empty());
  EXPECT_EQ(syscalls.blank_values.back(), uapi::kBlankPowerdown);
  const std::string diagnostics = capture.finish();

  EXPECT_TRUE(
      diagnostics.find(
          "stage=start.cold-initialize.pre-drive-power-state status=4") !=
      std::string::npos);
  EXPECT_TRUE(
      diagnostics.find(
          "reason=\"synthetic cold INIT pre-drive state unavailable\"") !=
      std::string::npos);
  EXPECT_TRUE(diagnostics.find("stage=start.cold-initialize.init-clear") ==
              std::string::npos);
}

TEST(LcdifTconBackend,
     ColdInitPostDriveFaultDiagnosticChangeStillCommitsState) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  int power_samples = 0;
  bool injected_after_drive = false;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      [&](std::string *) {
        ++power_samples;
        if (power_samples == 1) {
          return Rm2PanelPowerState{true, false, {}};
        }
        const bool final_idle_after_drive =
            active_pan_count(syscalls) != 0 &&
            !syscalls.panned_offsets.empty() &&
            syscalls.panned_offsets.back() == kRm2IdleSlot * kRm2ScanoutHeight;
        if (final_idle_after_drive) {
          injected_after_drive = true;
          return Rm2PanelPowerState{true, true, "SCP at VPOS rail"};
        }
        return Rm2PanelPowerState{true, true, {}};
      },
      Rm2HandoffOptions{.path = ""});
  ASSERT_EQ(backend.probe(fixture.profile()), kPlutoStatusOk);
  const std::string config_options = "wbf=" + fixture.waveform_path();
  const PlutoPresenterConfig config{
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = config_options.c_str(),
  };

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  EXPECT_EQ(backend.start(config), kPlutoStatusOk);
  EXPECT_TRUE(injected_after_drive);
  EXPECT_EQ(power_samples, 5);
  EXPECT_GT(active_pan_count(syscalls), 0U);
  ASSERT_TRUE(!syscalls.panned_offsets.empty());
  EXPECT_EQ(syscalls.panned_offsets.back(), kRm2IdleSlot * kRm2ScanoutHeight);
  const std::optional<std::uint16_t> pixel = snapshot_pixel(&backend, 0, 0);
  ASSERT_TRUE(pixel.has_value());
  EXPECT_EQ(*pixel, 0xffffU);
  EXPECT_EQ(backend.health().completed_jobs, 0U);
  EXPECT_EQ(backend.health().hardware_faults, 0U);
  backend.stop();
  const std::string diagnostics = capture.finish();

  EXPECT_TRUE(diagnostics.find(
                  "panel fault-register diagnostic "
                  "stage=start.cold-initialize.post-drive-power-state "
                  "previous=\"no fault event\" observed=\"SCP at VPOS rail\" "
                  "changes=1; stable power_good=ON") != std::string::npos);
  EXPECT_TRUE(diagnostics.find("RM2 startup failure") == std::string::npos);
  EXPECT_TRUE(diagnostics.find("fail-safe blank failure") == std::string::npos);
}

TEST(LcdifTconBackend, WorkerPreDriveUnavailableStateFailsBeforePhaseOrCommit) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  CompletionState completion;
  int power_samples = 0;
  std::atomic<bool> armed{false};
  std::atomic<int> armed_samples{0};
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      [&](std::string *error) {
        ++power_samples;
        if (power_samples == 1) {
          return Rm2PanelPowerState{true, false, {}};
        }
        if (armed.load(std::memory_order_acquire) &&
            armed_samples.fetch_add(1, std::memory_order_acq_rel) == 2) {
          if (error != nullptr) {
            *error = "synthetic worker pre-drive state unavailable";
          }
          return Rm2PanelPowerState{};
        }
        return Rm2PanelPowerState{true, true, {}};
      },
      Rm2HandoffOptions{.path = ""});

  ASSERT_TRUE(probe_and_start(&backend, fixture, &completion));
  const std::size_t active_pans_before = active_pan_count(syscalls);
  armed.store(true, std::memory_order_release);
  OwnedPixelRequest request(9, 11, 0, 301);

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  ASSERT_EQ(backend.submit(&request.request), kPlutoStatusOk);
  EXPECT_EQ(backend.wait_idle(3000), kPlutoStatusDeviceLost);
  EXPECT_EQ(active_pan_count(syscalls), active_pans_before);
  EXPECT_EQ(completion.count.load(std::memory_order_acquire), 0);
  EXPECT_EQ(backend.health().completed_jobs, 0U);
  EXPECT_EQ(backend.health().hardware_faults, 1U);
  const std::optional<std::uint16_t> pixel = snapshot_pixel(&backend, 9, 11);
  ASSERT_TRUE(pixel.has_value());
  EXPECT_EQ(*pixel, 0xffffU);
  ASSERT_TRUE(!syscalls.blank_values.empty());
  EXPECT_EQ(syscalls.blank_values.back(), uapi::kBlankPowerdown);
  const std::string diagnostics = capture.finish();

  EXPECT_TRUE(
      diagnostics.find("stage=present.pre-drive-power-state status=4") !=
      std::string::npos);
  EXPECT_TRUE(diagnostics.find(
                  "reason=\"synthetic worker pre-drive state unavailable\"") !=
              std::string::npos);
}

TEST(LcdifTconBackend,
     WorkerPostDriveFaultDiagnosticChangeStillCommitsAndCompletes) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  CompletionState completion;
  int power_samples = 0;
  std::atomic<bool> armed{false};
  std::size_t active_pans_before = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      [&](std::string *) {
        ++power_samples;
        if (power_samples == 1) {
          return Rm2PanelPowerState{true, false, {}};
        }
        const bool final_idle_after_new_drive =
            armed.load(std::memory_order_acquire) &&
            active_pan_count(syscalls) > active_pans_before &&
            !syscalls.panned_offsets.empty() &&
            syscalls.panned_offsets.back() == kRm2IdleSlot * kRm2ScanoutHeight;
        return Rm2PanelPowerState{
            true, true,
            final_idle_after_new_drive ? "SCP at V COM rail" : std::string{}};
      },
      Rm2HandoffOptions{.path = ""});

  ASSERT_TRUE(probe_and_start(&backend, fixture, &completion));
  active_pans_before = active_pan_count(syscalls);
  armed.store(true, std::memory_order_release);
  OwnedPixelRequest request(13, 17, 0, 302);

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  ASSERT_EQ(backend.submit(&request.request), kPlutoStatusOk);
  EXPECT_EQ(backend.wait_idle(3000), kPlutoStatusOk);
  EXPECT_GT(active_pan_count(syscalls), active_pans_before);
  ASSERT_TRUE(!syscalls.panned_offsets.empty());
  EXPECT_EQ(syscalls.panned_offsets.back(), kRm2IdleSlot * kRm2ScanoutHeight);
  EXPECT_EQ(completion.count.load(std::memory_order_acquire), 1);
  EXPECT_EQ(backend.health().completed_jobs, 1U);
  EXPECT_EQ(backend.health().hardware_faults, 0U);
  const std::optional<std::uint16_t> pixel = snapshot_pixel(&backend, 13, 17);
  ASSERT_TRUE(pixel.has_value());
  EXPECT_EQ(*pixel, 0U);
  backend.stop();
  const std::string diagnostics = capture.finish();

  EXPECT_TRUE(diagnostics.find(
                  "panel fault-register diagnostic "
                  "stage=present.post-drive-power-state "
                  "previous=\"no fault event\" observed=\"SCP at V COM rail\" "
                  "changes=1; stable power_good=ON") != std::string::npos);
  EXPECT_TRUE(diagnostics.find("RM2 present failure") == std::string::npos);
}

TEST(LcdifTconBackend,
     WorkerPostDrivePowerGoodLossRunsPhasesButDoesNotCommitOrComplete) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  BackendFakeLcdifSyscalls syscalls;
  CompletionState completion;
  int power_samples = 0;
  std::atomic<bool> armed{false};
  std::size_t active_pans_before = 0;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      [&](std::string *error) {
        ++power_samples;
        if (power_samples == 1) {
          return Rm2PanelPowerState{true, false, {}};
        }
        const bool final_idle_after_new_drive =
            armed.load(std::memory_order_acquire) &&
            active_pan_count(syscalls) > active_pans_before &&
            !syscalls.panned_offsets.empty() &&
            syscalls.panned_offsets.back() == kRm2IdleSlot * kRm2ScanoutHeight;
        if (final_idle_after_new_drive) {
          if (error != nullptr) {
            *error = "SY7636A panel power-good='OFF' state='no fault event'";
          }
          return Rm2PanelPowerState{true, false, {}};
        }
        return Rm2PanelPowerState{true, true, {}};
      },
      Rm2HandoffOptions{.path = ""});

  ASSERT_TRUE(probe_and_start(&backend, fixture, &completion));
  active_pans_before = active_pan_count(syscalls);
  armed.store(true, std::memory_order_release);
  OwnedPixelRequest request(19, 23, 0, 303);

  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  ASSERT_EQ(backend.submit(&request.request), kPlutoStatusOk);
  EXPECT_EQ(backend.wait_idle(3000), kPlutoStatusDeviceLost);
  EXPECT_GT(active_pan_count(syscalls), active_pans_before);
  EXPECT_EQ(completion.count.load(std::memory_order_acquire), 0);
  EXPECT_EQ(backend.health().completed_jobs, 0U);
  EXPECT_EQ(backend.health().hardware_faults, 1U);
  const std::optional<std::uint16_t> pixel = snapshot_pixel(&backend, 19, 23);
  ASSERT_TRUE(pixel.has_value());
  EXPECT_EQ(*pixel, 0xffffU);
  ASSERT_TRUE(!syscalls.blank_values.empty());
  EXPECT_EQ(syscalls.blank_values.back(), uapi::kBlankPowerdown);
  const std::string diagnostics = capture.finish();

  EXPECT_TRUE(
      diagnostics.find("stage=present.post-drive-power-state status=4") !=
      std::string::npos);
  EXPECT_TRUE(diagnostics.find("reason=\"SY7636A panel power-good='OFF' "
                               "state='no fault event'\"") !=
              std::string::npos);
}

TEST(LcdifTconBackend,
     SparseFullDamageKeepsDisjointRegionsSeparateAndDoesNotExpandPanel) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  constexpr std::size_t kFirstX = 10;
  constexpr std::size_t kFirstY = 10;
  constexpr std::size_t kSecondX = 1300;
  constexpr std::size_t kSecondY = 1800;
  constexpr std::size_t kUndamagedX = 700;
  constexpr std::size_t kUndamagedY = 900;
  BackendFakeLcdifSyscalls syscalls;
  syscalls.capture_phase_cells = true;
  syscalls.phase_cell_offsets = {
      phase_cell_offset_for_user(kFirstX, kFirstY),
      phase_cell_offset_for_user(kSecondX, kSecondY),
      phase_cell_offset_for_user(kUndamagedX, kUndamagedY),
  };
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader());
  ASSERT_TRUE(probe_and_start(&backend, fixture));
  syscalls.panned_phase_cells.clear();
  syscalls.latched_slot_mutations = 0;

  std::vector<std::uint16_t> pixels(kRm2PanelWidth * kRm2PanelHeight, 0xffffU);
  pixels[kFirstY * kRm2PanelWidth + kFirstX] = 0;
  pixels[kSecondY * kRm2PanelWidth + kSecondX] = 0x7befU;
  pixels[kUndamagedY * kRm2PanelWidth + kUndamagedX] = 0x39e7U;
  const std::array<PlutoRect, 2> damage{{
      {.x = static_cast<std::int32_t>(kFirstX),
       .y = static_cast<std::int32_t>(kFirstY),
       .width = 1,
       .height = 1},
      {.x = static_cast<std::int32_t>(kSecondX),
       .y = static_cast<std::int32_t>(kSecondY),
       .width = 1,
       .height = 1},
  }};
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
      .damage = damage.data(),
      .damage_count = damage.size(),
      .refresh_class = kPlutoRefreshFull,
      .flags = 0,
      .frame_id = 0x5a5aU,
  };
  ASSERT_EQ(backend.submit(&request), kPlutoStatusOk);
  ASSERT_EQ(backend.wait_idle(3000), kPlutoStatusOk);
  EXPECT_EQ(syscalls.latched_slot_mutations, 0U);
  ASSERT_TRUE(!syscalls.panned_phase_cells.empty());
  bool first_region_driven = false;
  bool second_region_driven = false;
  for (const auto &samples : syscalls.panned_phase_cells) {
    first_region_driven |= samples[0] != 0;
    second_region_driven |= samples[1] != 0;
    EXPECT_EQ(samples[2], 0U);
  }
  EXPECT_TRUE(first_region_driven);
  EXPECT_TRUE(second_region_driven);

  std::vector<std::uint16_t> snapshot_pixels(kRm2PanelWidth * kRm2PanelHeight);
  PlutoSurface snapshot{
      .pixels = reinterpret_cast<const std::uint8_t *>(snapshot_pixels.data()),
      .stride_bytes = kRm2PanelWidth * sizeof(std::uint16_t),
      .width = static_cast<std::int32_t>(kRm2PanelWidth),
      .height = static_cast<std::int32_t>(kRm2PanelHeight),
      .format = kPlutoPixelFormatRgb565,
  };
  ASSERT_EQ(backend.snapshot(&snapshot), kPlutoStatusOk);
  EXPECT_EQ(snapshot_pixels[kFirstY * kRm2PanelWidth + kFirstX], 0U);
  EXPECT_EQ(snapshot_pixels[kSecondY * kRm2PanelWidth + kSecondX], 0x7befU);
  EXPECT_EQ(snapshot_pixels[kUndamagedY * kRm2PanelWidth + kUndamagedX],
            0xffffU);
  backend.stop();
}

TEST(LcdifTconBackend, DamageAmplificationUsesUniqueRequestedUnionArea) {
  const std::array<PlutoRect, 3> damage{{
      {.x = 0, .y = 0, .width = 10, .height = 10},
      {.x = 0, .y = 0, .width = 10, .height = 10},
      {.x = 5, .y = 0, .width = 10, .height = 10},
  }};
  EXPECT_EQ(rm2_damage_union_area(damage), 150U);
}

TEST(LcdifTconBackend,
     BlockingPanUsesLatchTimeInsteadOfDelayedCompletionDelivery) {
  LocalRm2Profile fixture;
  ASSERT_TRUE(fixture.valid());
  BackendFakeLcdifSyscalls syscalls;
  syscalls.capture_phase_cells = true;
  const std::size_t sampled_cell =
      phase_cell_offset_for_user(32U, kRm2PanelHeight / 2U);
  syscalls.phase_cell_offsets = {sampled_cell, sampled_cell, sampled_cell};
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  Rm2HandoffOptions options{
      .path = {},
      .phase_encode_delay_for_testing = std::chrono::milliseconds(5),
      .pan_completion_delivery_delay_for_testing = std::chrono::milliseconds(8),
  };
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), std::move(options));
  ASSERT_TRUE(probe_and_start(&backend, fixture));
  syscalls.pan_delay = std::chrono::milliseconds(8);
  syscalls.panned_phase_cells.clear();
  syscalls.latched_slot_mutations = 0;

  std::vector<std::uint16_t> pixels(kRm2PanelWidth * kRm2PanelHeight, 0x2104U);
  const PlutoRect damage{
      .x = 0,
      .y = 0,
      .width = 64,
      .height = static_cast<std::int32_t>(kRm2PanelHeight),
  };
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
      .refresh_class = kPlutoRefreshUi,
      .flags = 0,
      .frame_id = 0x90U,
  };
  ASSERT_EQ(backend.submit(&request), kPlutoStatusOk);
  // The former caller-side timestamp charged the injected 8 ms post-latch
  // delivery delay to each 8 ms pan and failed the 12.351 ms cadence limit.
  // The device timestamp excludes that scheduler jitter while the production
  // pipeline still overlaps the injected 5 ms encode work.
  ASSERT_EQ(backend.wait_idle(3000), kPlutoStatusOk);
  EXPECT_EQ(backend.health().completed_jobs, 1U);
  EXPECT_EQ(syscalls.latched_slot_mutations, 0U);
  EXPECT_EQ(syscalls.panned_phase_cells.size(), 4U);
  backend.stop();
}

TEST(LcdifTconBackend, PhysicalPanOverrunStillFailsClosed) {
  LocalRm2Profile fixture;
  ASSERT_TRUE(fixture.valid());
  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend backend(
      fixture.profile(), std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(), {});
  ASSERT_TRUE(probe_and_start(&backend, fixture));

  // Delivery jitter after CUR_FRAME_DONE is harmless, but a physical latch
  // that exceeds the 5% ioctl-duration allowance remains a hardware fault.
  syscalls.pan_delay = std::chrono::milliseconds(13);
  OwnedPixelRequest request(3, 7, 0, 0x91U);
  EXPECT_EQ(backend.submit(&request.request), kPlutoStatusDeviceLost);
  EXPECT_EQ(backend.wait_idle(3000), kPlutoStatusDeviceLost);
  EXPECT_EQ(backend.health().completed_jobs, 0U);
  EXPECT_EQ(backend.health().hardware_faults, 1U);
  backend.stop();
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
        blanked_baseline_then_power_good_reader(),
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
        return Rm2PanelPowerState{true, incoming_power_checks != 1, {}};
      },
      handoff_options(handoff_path.get()));
  ASSERT_TRUE(probe_and_start(&incoming, fixture));
  EXPECT_FALSE(incoming.ready(kPlutoRefreshFast));
  EXPECT_EQ(incoming_temperature_reads, 0);
  EXPECT_EQ(incoming_power_checks, 1);
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
  EXPECT_EQ(incoming_power_checks, 1);
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

TEST(LcdifTconBackend,
     FirstWarmHandoffFullPanelReplayWhitePreconditionsExactlyOnce) {
  LocalRm2Profile fixture;
  if (!fixture.valid()) {
    return;
  }
  IsolatedHandoffPath handoff_path;
  OwnedHandoffPayload payload;
  GeneratedDeviceProfile relaxed_profile = fixture.profile();
  relaxed_profile.runtime.display.phase_interval_nanoseconds = 100'000'000U;
  Rm2WaveformProgram expected_waveforms;
  std::string waveform_error;
  ASSERT_TRUE(expected_waveforms.open(relaxed_profile, fixture.waveform_path(),
                                      &waveform_error))
      << waveform_error;
  Rm2WaveformSelection expected_precondition;
  Rm2WaveformSelection expected_content;
  ASSERT_TRUE(expected_waveforms.select(kPlutoRefreshFast, 24000,
                                        &expected_precondition));
  ASSERT_TRUE(
      expected_waveforms.select(kPlutoRefreshText, 24000, &expected_content));
  constexpr std::size_t kSampleX = 700;
  constexpr std::size_t kSampleY = 900;
  BackendFakeLcdifSyscalls outgoing_syscalls;
  {
    auto outgoing_device = std::make_unique<MxsLcdifDevice>(&outgoing_syscalls);
    LcdifTconDisplayBackend outgoing(
        relaxed_profile, std::move(outgoing_device),
        [](std::string *) -> std::optional<int> { return 24000; },
        blanked_baseline_then_power_good_reader(),
        handoff_options(handoff_path.get()));
    ASSERT_TRUE(probe_and_start_profile(&outgoing, relaxed_profile,
                                        fixture.waveform_path()));
    draw_fast_pixel(&outgoing, static_cast<std::uint32_t>(kSampleX),
                    static_cast<std::uint32_t>(kSampleY), 0x0000U, 200);
    ASSERT_EQ(outgoing.stage_handoff(&payload.payload, 3000), kPlutoStatusOk);
    outgoing.stop();
  }

  BackendFakeLcdifSyscalls syscalls;
  auto device = std::make_unique<MxsLcdifDevice>(&syscalls);
  LcdifTconDisplayBackend incoming(
      relaxed_profile, std::move(device),
      [](std::string *) -> std::optional<int> { return 24000; },
      blanked_baseline_then_power_good_reader(),
      handoff_options(handoff_path.get()));
  ScopedStderrCapture capture;
  ASSERT_TRUE(capture.valid());
  ASSERT_TRUE(probe_and_start_profile(&incoming, relaxed_profile,
                                      fixture.waveform_path()));
  PlutoHandoffPayload received{.struct_size = sizeof(PlutoHandoffPayload)};
  ASSERT_EQ(incoming.get_handoff(&received), kPlutoStatusOk);
  ASSERT_EQ(incoming.confirm_handoff(true), kPlutoStatusOk);

  syscalls.capture_phase_cells = true;
  const std::size_t sampled_cell =
      phase_cell_offset_for_user(kSampleX, kSampleY);
  syscalls.phase_cell_offsets = {sampled_cell, sampled_cell, sampled_cell};
  std::vector<std::uint16_t> pixels(kRm2PanelWidth * kRm2PanelHeight, 0xffffU);
  const PlutoRect full{
      .x = 0,
      .y = 0,
      .width = static_cast<std::int32_t>(kRm2PanelWidth),
      .height = static_cast<std::int32_t>(kRm2PanelHeight),
  };
  PlutoPresentRequest request{
      .struct_size = sizeof(PlutoPresentRequest),
      .surface =
          {
              .pixels = reinterpret_cast<const std::uint8_t *>(pixels.data()),
              .stride_bytes = kRm2PanelWidth * sizeof(std::uint16_t),
              .width = static_cast<std::int32_t>(kRm2PanelWidth),
              .height = static_cast<std::int32_t>(kRm2PanelHeight),
              .format = kPlutoPixelFormatRgb565,
          },
      .damage = &full,
      .damage_count = 1,
      .refresh_class = kPlutoRefreshText,
      .flags = 0,
      .frame_id = 201,
  };

  syscalls.panned_phase_cells.clear();
  ASSERT_EQ(incoming.submit(&request), kPlutoStatusOk);
  ASSERT_EQ(incoming.wait_idle(5000), kPlutoStatusOk);
  ASSERT_EQ(syscalls.panned_phase_cells.size(),
            expected_precondition.phase_count + expected_content.phase_count);
  EXPECT_TRUE(std::any_of(syscalls.panned_phase_cells.begin(),
                          syscalls.panned_phase_cells.begin() +
                              expected_precondition.phase_count,
                          [](const std::array<std::uint16_t, 3> &samples) {
                            return samples[0] != 0;
                          }));

  syscalls.panned_phase_cells.clear();
  request.frame_id = 202;
  ASSERT_EQ(incoming.submit(&request), kPlutoStatusOk);
  ASSERT_EQ(incoming.wait_idle(5000), kPlutoStatusOk);
  ASSERT_EQ(syscalls.panned_phase_cells.size(), expected_content.phase_count);
  EXPECT_TRUE(std::all_of(syscalls.panned_phase_cells.begin(),
                          syscalls.panned_phase_cells.end(),
                          [](const std::array<std::uint16_t, 3> &samples) {
                            return samples[0] == 0;
                          }));

  incoming.stop();
  const std::string diagnostics = capture.finish();
  EXPECT_TRUE(diagnostics.find("warm handoff full-panel replay completed "
                               "white mode-6 precondition then complete "
                               "mode-2 content") != std::string::npos);
  EXPECT_TRUE(diagnostics.find("handoff_cleanup_jobs=1") != std::string::npos);
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
        return Rm2PanelPowerState{true, power_checks != 1, {}};
      },
      handoff_options(path.get()));
  ASSERT_TRUE(probe_and_start(&incoming, fixture));
  EXPECT_FALSE(incoming.ready(kPlutoRefreshUi));
  EXPECT_EQ(temperature_reads, 0);
  ASSERT_EQ(incoming.confirm_handoff(false), kPlutoStatusOk);
  EXPECT_TRUE(incoming.ready(kPlutoRefreshUi));
  EXPECT_EQ(temperature_reads, 1);
  EXPECT_EQ(power_checks, 5);
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
      blanked_baseline_then_power_good_reader(), handoff_options(path.get()));
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
      blanked_baseline_then_power_good_reader(),
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
      blanked_baseline_then_power_good_reader(), handoff_options(path.get()));
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
        blanked_baseline_then_power_good_reader(), handoff_options(path.get()));
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
      blanked_baseline_then_power_good_reader(), handoff_options(path.get()));
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
      blanked_baseline_then_power_good_reader(), handoff_options(path.get()));
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
      blanked_baseline_then_power_good_reader(), handoff_options(path.get()));
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
      blanked_baseline_then_power_good_reader(), handoff_options(path.get()));
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
      blanked_baseline_then_power_good_reader(), handoff_options(path.get()));
  {
    BackendFakeLcdifSyscalls first_syscalls;
    LcdifTconDisplayBackend first(
        fixture.profile(), std::make_unique<MxsLcdifDevice>(&first_syscalls),
        [](std::string *) -> std::optional<int> { return 24000; },
        blanked_baseline_then_power_good_reader(), handoff_options(path.get()));
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
