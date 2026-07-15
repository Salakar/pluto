#include "presenter/native/mxcfb/mxcfb_backend.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <gtest/gtest.h>
#include <sys/mman.h>
#include <unistd.h>

#include "generated/rm1_rgb565_optical_lut.h"
#include "renderer/quantize.h"

namespace {

using pluto::native::NativeBackendHealthState;
using pluto::native::mxcfb::MxcfbDevice;
using pluto::native::mxcfb::MxcfbDisplayBackend;
using pluto::native::mxcfb::MxcfbHandoffOptions;
using pluto::native::mxcfb::MxcfbSyscalls;
namespace uapi = pluto::native::mxcfb::uapi;

constexpr std::uint32_t kWidth = 1404;
constexpr std::uint32_t kHeight = 1872;
constexpr std::uint32_t kVirtualWidth = 1408;
constexpr std::uint32_t kVirtualHeight = 3840;
constexpr std::uint32_t kStride = kVirtualWidth * 2;
constexpr std::size_t kTightStride = kWidth * 2;
constexpr std::uint32_t kMappingBytes = kStride * kVirtualHeight;
constexpr std::uint8_t kInitialPixel = 0x5a;
constexpr std::uint8_t kSafeInitialPixel = 0xff;
constexpr std::uint8_t kPaperWhiteOpticalLevel = 30;

const pluto::GeneratedDeviceProfile &rm1_profile() {
  return *pluto::generated_device_profile_by_id("rm1");
}

class BlockingMxcfbSyscalls final : public MxcfbSyscalls {
public:
  BlockingMxcfbSyscalls() : mapped_storage(kMappingBytes, kInitialPixel) {
    std::memcpy(fixed.id, "mxc_epdc_fb", sizeof("mxc_epdc_fb"));
    fixed.smem_len = kMappingBytes;
    fixed.type = uapi::kFramebufferTypePackedPixels;
    fixed.visual = uapi::kFramebufferVisualTrueColor;
    fixed.xpanstep = 1;
    fixed.ypanstep = 1;
    fixed.line_length = kStride;

    variable.xres = kWidth;
    variable.yres = kHeight;
    variable.xres_virtual = kVirtualWidth;
    variable.yres_virtual = kVirtualHeight;
    variable.bits_per_pixel = 16;
    variable.rotate = uapi::kFramebufferRotateClockwise;
    variable.red = {.offset = 11, .length = 5, .msb_right = 0};
    variable.green = {.offset = 5, .length = 6, .msb_right = 0};
    variable.blue = {.offset = 0, .length = 5, .msb_right = 0};
    variable.transp = {.offset = 0, .length = 0, .msb_right = 0};
  }

  std::string kernel_release() override { return "5.4.70-v1.6.3-rm10x"; }

  int open(const char *, int flags) override {
    open_flags = flags;
    ++open_count;
    return framebuffer_fd;
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
      ++put_count;
      return 0;
    }
    if (request == uapi::kFramebufferBlank) {
      blank_value = reinterpret_cast<std::uintptr_t>(argument);
      ++blank_count;
      return 0;
    }
    if (request == uapi::kSendUpdate) {
      std::lock_guard<std::mutex> lock(mutex_);
      if (send_error != 0) {
        errno = send_error;
        return -1;
      }
      sent_updates_.push_back(*static_cast<uapi::UpdateData *>(argument));
      condition_.notify_all();
      return 0;
    }
    if (request == uapi::kWaitForUpdateComplete) {
      auto *completion = static_cast<uapi::UpdateMarkerData *>(argument);
      std::unique_lock<std::mutex> lock(mutex_);
      waited_markers_.push_back(completion->update_marker);
      condition_.notify_all();
      condition_.wait(
          lock, [this] { return !block_waits || completion_permits_ > 0; });
      if (completion_permits_ > 0) {
        --completion_permits_;
      }
      if (wait_error != 0) {
        errno = wait_error;
        return -1;
      }
      completion->collision_test = report_collision ? 1U : 0U;
      return 0;
    }
    errno = ENOTTY;
    return -1;
  }

  void *mmap(void *, std::size_t, int, int, int, off_t) override {
    ++mmap_count;
    return mapped_storage.data();
  }

  int munmap(void *, std::size_t) override {
    ++munmap_count;
    return 0;
  }

  int close(int) override {
    ++close_count;
    return 0;
  }

  bool wait_for_wait_count(
      std::size_t count,
      std::chrono::milliseconds timeout = std::chrono::milliseconds(1000)) {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(lock, timeout, [this, count] {
      return waited_markers_.size() >= count;
    });
  }

  void complete_one() {
    std::lock_guard<std::mutex> lock(mutex_);
    ++completion_permits_;
    condition_.notify_all();
  }

  void block_initial_completion() {
    std::lock_guard<std::mutex> lock(mutex_);
    completion_permits_ = 0;
  }

  void clear_update_history() {
    std::lock_guard<std::mutex> lock(mutex_);
    sent_updates_.clear();
    waited_markers_.clear();
  }

  std::vector<uapi::UpdateData> sent_updates() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return sent_updates_;
  }

  std::vector<std::uint32_t> waited_markers() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return waited_markers_;
  }

  static constexpr int framebuffer_fd = 61;

  uapi::FramebufferFixedInfoArm32 fixed{};
  uapi::FramebufferVariableInfoArm32 variable{};
  std::vector<std::uint8_t> mapped_storage;
  int send_error = 0;
  int wait_error = 0;
  bool block_waits = true;
  bool report_collision = false;
  int open_flags = 0;
  int open_count = 0;
  int mmap_count = 0;
  int put_count = 0;
  int blank_count = 0;
  std::uintptr_t blank_value = std::numeric_limits<std::uintptr_t>::max();
  int munmap_count = 0;
  int close_count = 0;

private:
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  // The backend synchronously proves one known-state full update during
  // start(). App submissions block until tests grant later permits.
  std::size_t completion_permits_ = 1;
  std::vector<uapi::UpdateData> sent_updates_;
  std::vector<std::uint32_t> waited_markers_;
};

class CallbackCapture final {
public:
  static void callback(std::uint64_t frame_id, void *user_data) {
    auto *capture = static_cast<CallbackCapture *>(user_data);
    {
      std::lock_guard<std::mutex> lock(capture->mutex_);
      capture->frame_ids_.push_back(frame_id);
    }
    capture->condition_.notify_all();
  }

  bool wait_for_count(std::size_t count, std::chrono::milliseconds timeout =
                                             std::chrono::milliseconds(1000)) {
    std::unique_lock<std::mutex> lock(mutex_);
    return condition_.wait_for(
        lock, timeout, [this, count] { return frame_ids_.size() >= count; });
  }

  std::vector<std::uint64_t> frame_ids() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return frame_ids_;
  }

private:
  mutable std::mutex mutex_;
  std::condition_variable condition_;
  std::vector<std::uint64_t> frame_ids_;
};

class OwnedRequest final {
public:
  explicit OwnedRequest(std::vector<PlutoRect> rects,
                        PlutoRefreshClass refresh_class = kPlutoRefreshUi,
                        std::uint64_t frame_id = 19,
                        std::size_t row_padding = 10)
      : stride(kTightStride + row_padding), pixels(stride * kHeight, 0xee),
        damage(std::move(rects)) {
    for (std::uint32_t y = 0; y < kHeight; ++y) {
      for (std::uint32_t x = 0; x < kWidth * 2; ++x) {
        pixels[static_cast<std::size_t>(y) * stride + x] =
            static_cast<std::uint8_t>((x * 13U + y * 7U) & 0xffU);
      }
    }
    request = {
        .struct_size = sizeof(PlutoPresentRequest),
        .surface =
            {
                .pixels = pixels.data(),
                .stride_bytes = stride,
                .width = static_cast<std::int32_t>(kWidth),
                .height = static_cast<std::int32_t>(kHeight),
                .format = kPlutoPixelFormatRgb565,
            },
        .damage = damage.data(),
        .damage_count = damage.size(),
        .refresh_class = refresh_class,
        .flags = 0,
        .frame_id = frame_id,
    };
  }

  std::size_t stride;
  std::vector<std::uint8_t> pixels;
  std::vector<PlutoRect> damage;
  PlutoPresentRequest request{};
};

std::unique_ptr<MxcfbDevice> fake_device(BlockingMxcfbSyscalls *syscalls) {
  return std::make_unique<MxcfbDevice>(syscalls);
}

PlutoPresenterConfig presenter_config(CallbackCapture *capture = nullptr) {
  return {
      .struct_size = sizeof(PlutoPresenterConfig),
      .backend_name = "native",
      .options = nullptr,
      .on_complete = capture == nullptr ? nullptr : CallbackCapture::callback,
      .user_data = capture,
  };
}

bool probe_and_start(MxcfbDisplayBackend *backend,
                     BlockingMxcfbSyscalls *syscalls,
                     CallbackCapture *capture = nullptr) {
  if (backend->probe(rm1_profile()) != kPlutoStatusOk) {
    return false;
  }
  const PlutoPresenterConfig config = presenter_config(capture);
  if (backend->start(config) != kPlutoStatusOk) {
    return false;
  }
  syscalls->clear_update_history();
  return true;
}

std::uint8_t source_byte(const OwnedRequest &owned, std::uint32_t x_byte,
                         std::uint32_t y) {
  return owned.pixels[static_cast<std::size_t>(y) * owned.stride + x_byte];
}

void store_rgb565(std::vector<std::uint8_t> *bytes, std::size_t stride,
                  std::uint32_t x, std::uint32_t y, std::uint16_t pixel) {
  const std::size_t offset = static_cast<std::size_t>(y) * stride + x * 2u;
  (*bytes)[offset] = static_cast<std::uint8_t>(pixel);
  (*bytes)[offset + 1u] = static_cast<std::uint8_t>(pixel >> 8u);
}

std::uint16_t load_rgb565(const std::uint8_t *pixel) {
  return static_cast<std::uint16_t>(
      static_cast<std::uint16_t>(pixel[0]) |
      (static_cast<std::uint16_t>(pixel[1]) << 8u));
}

std::uint8_t expected_optical_level(std::uint16_t pixel) {
  const std::uint8_t gray8 =
      pluto::quantize_gray16(pluto::rgb565_luma8(pixel), 127);
  return static_cast<std::uint8_t>((gray8 / 17u) * 2u);
}

std::vector<std::uint8_t>
tight_visible_frame(const std::vector<std::uint8_t> &mapped) {
  std::vector<std::uint8_t> tight(kTightStride * kHeight);
  for (std::uint32_t y = 0; y < kHeight; ++y) {
    std::memcpy(tight.data() + static_cast<std::size_t>(y) * kTightStride,
                mapped.data() + static_cast<std::size_t>(y) * kStride,
                kTightStride);
  }
  return tight;
}

class IsolatedHandoffPath final {
public:
  IsolatedHandoffPath() {
    static std::atomic<std::uint64_t> sequence{1};
    path_ = "/tmp/pluto-rm1-handoff-" + std::to_string(::getpid()) + "-" +
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

MxcfbHandoffOptions
handoff_options(const std::string &path,
                pluto::GlassHandoffClock (*now)() = nullptr) {
  return {
      .path = path,
      .allow_insecure_path_for_testing = true,
      .now_for_testing = now,
  };
}

class OwnedHandoffPayload final {
public:
  explicit OwnedHandoffPayload(std::vector<std::uint8_t> data = {0x52, 0x4d,
                                                                 0x31, 0x01})
      : bytes(std::move(data)) {
    payload = {
        .struct_size = sizeof(PlutoHandoffPayload),
        .bytes = bytes.data(),
        .byte_count = bytes.size(),
        .width = static_cast<std::int32_t>(kWidth),
        .height = static_cast<std::int32_t>(kHeight),
        .rotation = 0,
        .pixel_format = kPlutoPixelFormatRgb565,
        .configuration_hash = 0x7f4a9d281b03c6e5ULL,
    };
  }

  std::vector<std::uint8_t> bytes;
  PlutoHandoffPayload payload{};
};

void draw_and_stage_handoff(MxcfbDisplayBackend *backend,
                            BlockingMxcfbSyscalls *syscalls,
                            OwnedHandoffPayload *handoff) {
  ASSERT_TRUE(probe_and_start(backend, syscalls));
  OwnedRequest content({{{.x = 3, .y = 4, .width = 5, .height = 6}}},
                       kPlutoRefreshUi, 91);
  store_rgb565(&content.pixels, content.stride, 3, 4, 0x0000u);
  store_rgb565(&content.pixels, content.stride, 4, 4, 0xffffu);
  store_rgb565(&content.pixels, content.stride, 5, 4, 0xf800u);
  store_rgb565(&content.pixels, content.stride, 6, 4, 0x07e0u);
  store_rgb565(&content.pixels, content.stride, 7, 4, 0x001fu);
  ASSERT_EQ(backend->submit(&content.request), kPlutoStatusOk);
  ASSERT_TRUE(syscalls->wait_for_wait_count(1));
  syscalls->complete_one();
  ASSERT_EQ(backend->wait_idle(1000), kPlutoStatusOk);
  ASSERT_EQ(backend->stage_handoff(&handoff->payload, 1000), kPlutoStatusOk);
}

bool load_handoff_bundle(const std::string &path,
                         pluto::GlassHandoffBundle *out) {
  pluto::GlassHandoffIdentity identity;
  pluto::GlassHandoffLease lease;
  return out != nullptr &&
         pluto::native::mxcfb::build_mxcfb_handoff_identity_for_testing(
             rm1_profile(), &identity) &&
         pluto::glass_handoff_acquire_lease(path, &lease) &&
         pluto::glass_handoff_load(lease, path, identity,
                                   pluto::glass_handoff_now(),
                                   out) == pluto::GlassHandoffReject::kNone;
}

enum class PresenterPayloadMutation {
  kMissing,
  kWrongSize,
  kSameLevelPixel,
  kOpticalLevel,
};

bool rewrite_handoff_bundle(const std::string &path,
                            PresenterPayloadMutation mutation) {
  pluto::GlassHandoffIdentity identity;
  pluto::GlassHandoffLease lease;
  pluto::GlassHandoffBundle bundle;
  if (!pluto::native::mxcfb::build_mxcfb_handoff_identity_for_testing(
          rm1_profile(), &identity) ||
      !pluto::glass_handoff_acquire_lease(path, &lease) ||
      pluto::glass_handoff_load(lease, path, identity,
                                pluto::glass_handoff_now(),
                                &bundle) != pluto::GlassHandoffReject::kNone) {
    return false;
  }
  switch (mutation) {
  case PresenterPayloadMutation::kMissing:
    bundle.presenter_payload.clear();
    break;
  case PresenterPayloadMutation::kWrongSize:
    if (bundle.presenter_payload.empty()) {
      return false;
    }
    bundle.presenter_payload.pop_back();
    break;
  case PresenterPayloadMutation::kSameLevelPixel: {
    constexpr std::uint16_t kNearWhite = 0xfffeu;
    if (bundle.presenter_payload.size() < 2u ||
        expected_optical_level(kNearWhite) != kPaperWhiteOpticalLevel) {
      return false;
    }
    bundle.presenter_payload[0] = static_cast<std::uint8_t>(kNearWhite);
    bundle.presenter_payload[1] = static_cast<std::uint8_t>(kNearWhite >> 8u);
    break;
  }
  case PresenterPayloadMutation::kOpticalLevel:
    if (bundle.core.engine_levels.empty()) {
      return false;
    }
    bundle.core.engine_levels[0] = 0;
    break;
  }
  bundle.written = pluto::glass_handoff_now();
  return pluto::glass_handoff_save(lease, path, bundle);
}

pluto::GlassHandoffClock handoff_clock_100() {
  return {
      .realtime_sec = 100,
      .boottime_ns = 10'000'000'000ULL,
      .boot_id_hash = 0x123456789abcdef0ULL,
  };
}

pluto::GlassHandoffClock handoff_clock_161() {
  return {
      .realtime_sec = 161,
      .boottime_ns = 71'000'000'000ULL,
      .boot_id_hash = 0x123456789abcdef0ULL,
  };
}

} // namespace

TEST(MxcfbBackend, ReportsStrictAcceptedProductCapabilities) {
  BlockingMxcfbSyscalls syscalls;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
  ASSERT_TRUE(probe_and_start(&backend, &syscalls));

  PlutoDisplayInfo info{};
  info.struct_size = sizeof(info);
  ASSERT_EQ(backend.info(&info), kPlutoStatusOk);
  EXPECT_EQ(backend.driver_name(), "mxcfb_epdc");
  EXPECT_EQ(info.width, static_cast<std::int32_t>(kWidth));
  EXPECT_EQ(info.height, static_cast<std::int32_t>(kHeight));
  EXPECT_EQ(info.dpi, 226);
  EXPECT_EQ(info.preferred_format, kPlutoPixelFormatRgb565);
  EXPECT_FALSE(info.is_color);
  EXPECT_TRUE(info.controls_refresh_class);
  EXPECT_TRUE(info.reports_completion);
  EXPECT_FALSE(info.wants_pre_dithered);
  EXPECT_EQ(info.rect_alignment, 1);
  EXPECT_EQ(info.max_inflight_updates, 1);
  EXPECT_FALSE(info.backend_quantizes_color);
  EXPECT_FALSE(info.supports_overlap_supersession);
  EXPECT_TRUE(backend.ready(kPlutoRefreshFast));
  EXPECT_TRUE(backend.ready(kPlutoRefreshFull));
  EXPECT_EQ(syscalls.put_count, 1);
}

TEST(MxcfbBackend, ProbeIsObservationalAndStartReassertsThePinnedMode) {
  BlockingMxcfbSyscalls syscalls;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));

  ASSERT_EQ(backend.probe(rm1_profile()), kPlutoStatusOk);
  EXPECT_EQ(syscalls.put_count, 0);
  const PlutoPresenterConfig config = presenter_config();
  ASSERT_EQ(backend.start(config), kPlutoStatusOk);
  EXPECT_EQ(syscalls.put_count, 1);
  EXPECT_EQ(syscalls.blank_count, 1);
  EXPECT_EQ(syscalls.blank_value, uapi::kFramebufferUnblank);
  const auto sent = syscalls.sent_updates();
  const auto waited = syscalls.waited_markers();
  ASSERT_EQ(sent.size(), 1U);
  ASSERT_EQ(waited.size(), 1U);
  EXPECT_EQ(waited[0], sent[0].update_marker);
  EXPECT_EQ(sent[0].update_region.left, 0U);
  EXPECT_EQ(sent[0].update_region.top, 0U);
  EXPECT_EQ(sent[0].update_region.width, kWidth);
  EXPECT_EQ(sent[0].update_region.height, kHeight);
  EXPECT_EQ(sent[0].waveform_mode, uapi::kWaveformModeQuality);
  EXPECT_EQ(sent[0].update_mode, uapi::kUpdateModePartial);
  EXPECT_EQ(sent[0].temperature, uapi::kTemperatureUseAmbient);
  EXPECT_EQ(syscalls.mapped_storage.front(), kSafeInitialPixel);
  EXPECT_EQ(syscalls.mapped_storage.back(), kSafeInitialPixel);
}

TEST(MxcfbBackend, DefaultMarkerEpochDoesNotRestartAtOnePerProcess) {
  std::uint32_t first_marker = 0;
  {
    BlockingMxcfbSyscalls syscalls;
    MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
    ASSERT_EQ(backend.probe(rm1_profile()), kPlutoStatusOk);
    const PlutoPresenterConfig config = presenter_config();
    ASSERT_EQ(backend.start(config), kPlutoStatusOk);
    const auto sent = syscalls.sent_updates();
    ASSERT_EQ(sent.size(), 1U);
    first_marker = sent[0].update_marker;
  }

  BlockingMxcfbSyscalls syscalls;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
  ASSERT_EQ(backend.probe(rm1_profile()), kPlutoStatusOk);
  const PlutoPresenterConfig config = presenter_config();
  ASSERT_EQ(backend.start(config), kPlutoStatusOk);
  const auto sent = syscalls.sent_updates();
  ASSERT_EQ(sent.size(), 1U);
  EXPECT_NE(first_marker, 0U);
  EXPECT_NE(first_marker & 0x80000000U, 0U);
  EXPECT_NE(sent[0].update_marker, 0U);
  EXPECT_NE(sent[0].update_marker & 0x80000000U, 0U);
  EXPECT_NE(sent[0].update_marker, first_marker);
}

TEST(MxcfbBackend, StartAcceptsNoAppWorkUntilKnownStateMarkerCompletes) {
  BlockingMxcfbSyscalls syscalls;
  syscalls.block_initial_completion();
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
  ASSERT_EQ(backend.probe(rm1_profile()), kPlutoStatusOk);
  const PlutoPresenterConfig config = presenter_config();
  std::atomic<bool> start_returned = false;
  PlutoStatus start_status = kPlutoStatusInternal;
  std::thread starter([&] {
    start_status = backend.start(config);
    start_returned.store(true, std::memory_order_release);
  });

  ASSERT_TRUE(syscalls.wait_for_wait_count(1));
  EXPECT_FALSE(start_returned.load(std::memory_order_acquire));
  EXPECT_FALSE(backend.ready(kPlutoRefreshUi));
  syscalls.complete_one();
  starter.join();

  EXPECT_EQ(start_status, kPlutoStatusOk);
  EXPECT_TRUE(start_returned.load(std::memory_order_acquire));
  EXPECT_TRUE(backend.ready(kPlutoRefreshUi));
}

TEST(MxcfbBackend, KnownStateSendOrCompletionFailureFailsStartClosed) {
  for (const int send_error : {EAGAIN, EBUSY, EINVAL, ETIMEDOUT, EIO}) {
    BlockingMxcfbSyscalls syscalls;
    syscalls.send_error = send_error;
    MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
    ASSERT_EQ(backend.probe(rm1_profile()), kPlutoStatusOk);
    const PlutoPresenterConfig config = presenter_config();

    EXPECT_EQ(backend.start(config), kPlutoStatusDeviceLost);
    EXPECT_FALSE(backend.ready(kPlutoRefreshUi));
    EXPECT_EQ(static_cast<int>(backend.health().state),
              static_cast<int>(NativeBackendHealthState::kDeviceLost));
    EXPECT_EQ(syscalls.close_count, 1);
  }
  {
    BlockingMxcfbSyscalls syscalls;
    syscalls.block_waits = false;
    syscalls.wait_error = ETIMEDOUT;
    MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
    ASSERT_EQ(backend.probe(rm1_profile()), kPlutoStatusOk);
    const PlutoPresenterConfig config = presenter_config();

    EXPECT_EQ(backend.start(config), kPlutoStatusDeviceLost);
    EXPECT_FALSE(backend.ready(kPlutoRefreshUi));
    EXPECT_EQ(static_cast<int>(backend.health().state),
              static_cast<int>(NativeBackendHealthState::kDeviceLost));
    EXPECT_EQ(syscalls.close_count, 1);
  }
}

TEST(MxcfbBackend, CopiesOnlyExactDamageRowsAndPreservesBothStrides) {
  BlockingMxcfbSyscalls syscalls;
  CallbackCapture callbacks;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
  ASSERT_TRUE(probe_and_start(&backend, &syscalls, &callbacks));
  OwnedRequest owned({
      {.x = 2, .y = 1, .width = 3, .height = 2},
      {.x = 8, .y = 4, .width = 2, .height = 1},
  });

  ASSERT_EQ(backend.submit(&owned.request), kPlutoStatusOk);
  ASSERT_TRUE(syscalls.wait_for_wait_count(1));
  EXPECT_EQ(callbacks.frame_ids().size(), 0U);

  const auto sent = syscalls.sent_updates();
  ASSERT_EQ(sent.size(), 1U);
  EXPECT_EQ(sent[0].update_region.left, 2U);
  EXPECT_EQ(sent[0].update_region.top, 1U);
  EXPECT_EQ(sent[0].update_region.width, 8U);
  EXPECT_EQ(sent[0].update_region.height, 4U);
  EXPECT_EQ(sent[0].waveform_mode, uapi::kWaveformModeQuality);
  EXPECT_EQ(sent[0].update_mode, uapi::kUpdateModePartial);
  EXPECT_NE(sent[0].update_marker, 0U);
  EXPECT_EQ(sent[0].temperature, uapi::kTemperatureUseAmbient);

  for (std::uint32_t y = 1; y <= 2; ++y) {
    for (std::uint32_t x_byte = 4; x_byte < 10; ++x_byte) {
      EXPECT_EQ(syscalls.mapped_storage[static_cast<std::size_t>(y) * kStride +
                                        x_byte],
                source_byte(owned, x_byte, y));
    }
  }
  for (std::uint32_t x_byte = 16; x_byte < 20; ++x_byte) {
    EXPECT_EQ(syscalls.mapped_storage[4U * kStride + x_byte],
              source_byte(owned, x_byte, 4));
  }
  EXPECT_EQ(syscalls.mapped_storage[3U * kStride + 6U], kSafeInitialPixel);
  EXPECT_EQ(syscalls.mapped_storage[kTightStride], kSafeInitialPixel);
  EXPECT_EQ(syscalls.mapped_storage[kStride - 1], kSafeInitialPixel);

  const std::size_t output_stride = kTightStride + 17;
  std::vector<std::uint8_t> output(output_stride * kHeight, 0xcc);
  PlutoSurface snapshot{
      .pixels = output.data(),
      .stride_bytes = output_stride,
      .width = static_cast<std::int32_t>(kWidth),
      .height = static_cast<std::int32_t>(kHeight),
      .format = kPlutoPixelFormatRgb565,
  };
  ASSERT_EQ(backend.snapshot(&snapshot), kPlutoStatusOk);
  EXPECT_EQ(output[1U * output_stride + 4U], source_byte(owned, 4, 1));
  EXPECT_EQ(output[3U * output_stride + 6U], kSafeInitialPixel);
  EXPECT_EQ(output[kTightStride], 0xcc);

  syscalls.complete_one();
  ASSERT_TRUE(callbacks.wait_for_count(1));
  EXPECT_EQ(callbacks.frame_ids()[0], owned.request.frame_id);
  EXPECT_EQ(backend.wait_idle(1000), kPlutoStatusOk);
}

TEST(MxcfbBackend, MapsFullClassToObservedQualityFullScreenUpdate) {
  BlockingMxcfbSyscalls syscalls;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
  ASSERT_TRUE(probe_and_start(&backend, &syscalls));
  OwnedRequest owned({{{.x = 100, .y = 200, .width = 4, .height = 5}}},
                     kPlutoRefreshFull);

  ASSERT_EQ(backend.submit(&owned.request), kPlutoStatusOk);
  ASSERT_TRUE(syscalls.wait_for_wait_count(1));
  const auto sent = syscalls.sent_updates();
  ASSERT_EQ(sent.size(), 1U);
  EXPECT_EQ(sent[0].update_mode, uapi::kUpdateModePartial);
  EXPECT_EQ(sent[0].update_region.left, 0U);
  EXPECT_EQ(sent[0].update_region.top, 0U);
  EXPECT_EQ(sent[0].update_region.width, kWidth);
  EXPECT_EQ(sent[0].update_region.height, kHeight);
  EXPECT_EQ(sent[0].waveform_mode, uapi::kWaveformModeQuality);
  EXPECT_EQ(sent[0].temperature, uapi::kTemperatureUseAmbient);
  syscalls.complete_one();
  EXPECT_EQ(backend.wait_idle(1000), kPlutoStatusOk);
}

TEST(MxcfbBackend, MapsFastClassToObservedDirectDrawUpdate) {
  BlockingMxcfbSyscalls syscalls;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
  ASSERT_TRUE(probe_and_start(&backend, &syscalls));
  OwnedRequest owned({{{.x = 20, .y = 30, .width = 6, .height = 7}}},
                     kPlutoRefreshFast);

  ASSERT_EQ(backend.submit(&owned.request), kPlutoStatusOk);
  ASSERT_TRUE(syscalls.wait_for_wait_count(1));
  const auto sent = syscalls.sent_updates();
  ASSERT_EQ(sent.size(), 1U);
  EXPECT_EQ(sent[0].update_region.left, 20U);
  EXPECT_EQ(sent[0].update_region.top, 30U);
  EXPECT_EQ(sent[0].update_region.width, 6U);
  EXPECT_EQ(sent[0].update_region.height, 7U);
  EXPECT_EQ(sent[0].waveform_mode, uapi::kWaveformModeDirect);
  EXPECT_EQ(sent[0].update_mode, uapi::kUpdateModePartial);
  EXPECT_EQ(sent[0].temperature, uapi::kTemperatureRemarkableDraw);
  syscalls.complete_one();
  EXPECT_EQ(backend.wait_idle(1000), kPlutoStatusOk);
}

TEST(MxcfbBackend, PenTruthFullPreservesExactRegionalDamage) {
  BlockingMxcfbSyscalls syscalls;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
  ASSERT_TRUE(probe_and_start(&backend, &syscalls));
  OwnedRequest owned(
      {
          {.x = 40, .y = 50, .width = 8, .height = 9},
          {.x = 60, .y = 70, .width = 10, .height = 11},
      },
      kPlutoRefreshFull);
  owned.request.flags = kPlutoPresentFlagPenTruth;

  ASSERT_EQ(backend.submit(&owned.request), kPlutoStatusOk);
  ASSERT_TRUE(syscalls.wait_for_wait_count(1));
  const auto sent = syscalls.sent_updates();
  ASSERT_EQ(sent.size(), 1U);
  EXPECT_EQ(sent[0].update_region.left, 40U);
  EXPECT_EQ(sent[0].update_region.top, 50U);
  EXPECT_EQ(sent[0].update_region.width, 30U);
  EXPECT_EQ(sent[0].update_region.height, 31U);
  EXPECT_EQ(sent[0].waveform_mode, uapi::kWaveformModeQuality);
  EXPECT_EQ(sent[0].update_mode, uapi::kUpdateModePartial);
  EXPECT_EQ(sent[0].temperature, uapi::kTemperatureUseAmbient);
  syscalls.complete_one();
  EXPECT_EQ(backend.wait_idle(1000), kPlutoStatusOk);
}

TEST(MxcfbBackend, SparkleCompletesSynchronouslyAsAnAcceptedNoOp) {
  BlockingMxcfbSyscalls syscalls;
  CallbackCapture callbacks;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
  ASSERT_TRUE(probe_and_start(&backend, &syscalls, &callbacks));
  OwnedRequest owned({{{.x = 10, .y = 20, .width = 4, .height = 5}}},
                     kPlutoRefreshFast, 88);
  owned.request.flags =
      kPlutoPresentFlagSparkle | kPlutoPresentFlagSparkleDevelop | (17U << 8U);

  EXPECT_EQ(backend.submit(&owned.request), kPlutoStatusOk);
  ASSERT_TRUE(callbacks.wait_for_count(1));
  EXPECT_EQ(callbacks.frame_ids()[0], 88U);
  EXPECT_TRUE(syscalls.sent_updates().empty());
  EXPECT_TRUE(syscalls.waited_markers().empty());
  EXPECT_TRUE(backend.ready(kPlutoRefreshFast));
  EXPECT_EQ(backend.health().completed_jobs, 1U);
}

TEST(MxcfbBackend, UsesUniqueNonzeroMarkersAcrossWrap) {
  BlockingMxcfbSyscalls syscalls;
  CallbackCapture callbacks;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls),
                              std::numeric_limits<std::uint32_t>::max());
  ASSERT_TRUE(probe_and_start(&backend, &syscalls, &callbacks));
  OwnedRequest first({{{.x = 0, .y = 0, .width = 2, .height = 2}}},
                     kPlutoRefreshUi, 1);
  OwnedRequest second({{{.x = 2, .y = 2, .width = 2, .height = 2}}},
                      kPlutoRefreshUi, 2);

  ASSERT_EQ(backend.submit(&first.request), kPlutoStatusOk);
  ASSERT_TRUE(syscalls.wait_for_wait_count(1));
  syscalls.complete_one();
  ASSERT_TRUE(callbacks.wait_for_count(1));
  ASSERT_EQ(backend.submit(&second.request), kPlutoStatusOk);
  ASSERT_TRUE(syscalls.wait_for_wait_count(2));

  const auto sent = syscalls.sent_updates();
  ASSERT_EQ(sent.size(), 2U);
  EXPECT_EQ(sent[0].update_marker, 1U);
  EXPECT_EQ(sent[1].update_marker, 2U);
  EXPECT_NE(sent[0].update_marker, sent[1].update_marker);
  const auto waited = syscalls.waited_markers();
  ASSERT_EQ(waited.size(), 2U);
  EXPECT_EQ(waited[0], sent[0].update_marker);
  EXPECT_EQ(waited[1], sent[1].update_marker);
  syscalls.complete_one();
  ASSERT_TRUE(callbacks.wait_for_count(2));
}

TEST(MxcfbBackend, AppliesOneRequestBackpressureUntilRealCompletion) {
  BlockingMxcfbSyscalls syscalls;
  CallbackCapture callbacks;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
  ASSERT_TRUE(probe_and_start(&backend, &syscalls, &callbacks));
  OwnedRequest first({{{.x = 0, .y = 0, .width = 2, .height = 2}}},
                     kPlutoRefreshUi, 10);
  OwnedRequest second({{{.x = 4, .y = 4, .width = 2, .height = 2}}},
                      kPlutoRefreshUi, 11);

  ASSERT_EQ(backend.submit(&first.request), kPlutoStatusOk);
  ASSERT_TRUE(syscalls.wait_for_wait_count(1));
  EXPECT_FALSE(backend.ready(kPlutoRefreshUi));
  EXPECT_EQ(backend.submit(&second.request), kPlutoStatusAgain);
  EXPECT_EQ(backend.wait_idle(0), kPlutoStatusTimeout);
  const auto busy_health = backend.health();
  EXPECT_EQ(static_cast<int>(busy_health.state),
            static_cast<int>(NativeBackendHealthState::kBusy));
  EXPECT_EQ(busy_health.queue_depth, 1U);
  EXPECT_EQ(busy_health.completed_jobs, 0U);
  EXPECT_EQ(syscalls.sent_updates().size(), 1U);
  EXPECT_EQ(callbacks.frame_ids().size(), 0U);

  syscalls.complete_one();
  ASSERT_TRUE(callbacks.wait_for_count(1));
  EXPECT_EQ(backend.wait_idle(1000), kPlutoStatusOk);
  EXPECT_TRUE(backend.ready(kPlutoRefreshUi));
  const auto ready_health = backend.health();
  EXPECT_EQ(static_cast<int>(ready_health.state),
            static_cast<int>(NativeBackendHealthState::kReady));
  EXPECT_EQ(ready_health.queue_depth, 0U);
  EXPECT_EQ(ready_health.completed_jobs, 1U);
}

TEST(MxcfbBackend, MarkerTimeoutFailsClosedWithoutFalseCallback) {
  BlockingMxcfbSyscalls syscalls;
  CallbackCapture callbacks;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
  ASSERT_TRUE(probe_and_start(&backend, &syscalls, &callbacks));
  syscalls.block_waits = false;
  syscalls.wait_error = ETIMEDOUT;
  OwnedRequest owned({{{.x = 0, .y = 0, .width = 2, .height = 2}}});

  ASSERT_EQ(backend.submit(&owned.request), kPlutoStatusOk);
  EXPECT_EQ(backend.wait_idle(1000), kPlutoStatusDeviceLost);
  EXPECT_EQ(callbacks.frame_ids().size(), 0U);
  EXPECT_FALSE(backend.ready(kPlutoRefreshUi));
  const auto health = backend.health();
  EXPECT_EQ(static_cast<int>(health.state),
            static_cast<int>(NativeBackendHealthState::kDeviceLost));
  EXPECT_EQ(health.queue_depth, 0U);
  EXPECT_EQ(health.completed_jobs, 0U);
  EXPECT_EQ(health.hardware_faults, 1U);
}

TEST(MxcfbBackend, SendBackpressureDoesNotPublishSnapshotOrCompletion) {
  BlockingMxcfbSyscalls syscalls;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
  ASSERT_TRUE(probe_and_start(&backend, &syscalls));
  syscalls.send_error = EBUSY;
  OwnedRequest owned({{{.x = 1, .y = 1, .width = 2, .height = 2}}});

  EXPECT_EQ(backend.submit(&owned.request), kPlutoStatusAgain);
  EXPECT_TRUE(backend.ready(kPlutoRefreshUi));
  EXPECT_EQ(backend.wait_idle(0), kPlutoStatusOk);
  EXPECT_EQ(syscalls.mapped_storage[kStride + 2U], kSafeInitialPixel);

  std::vector<std::uint8_t> output(kTightStride * kHeight, 0);
  PlutoSurface snapshot{
      .pixels = output.data(),
      .stride_bytes = kTightStride,
      .width = static_cast<std::int32_t>(kWidth),
      .height = static_cast<std::int32_t>(kHeight),
      .format = kPlutoPixelFormatRgb565,
  };
  ASSERT_EQ(backend.snapshot(&snapshot), kPlutoStatusOk);
  EXPECT_EQ(output[kTightStride + 2U], kSafeInitialPixel);

  syscalls.send_error = EIO;
  EXPECT_EQ(backend.submit(&owned.request), kPlutoStatusDeviceLost);
  EXPECT_EQ(static_cast<int>(backend.health().state),
            static_cast<int>(NativeBackendHealthState::kDeviceLost));
  EXPECT_EQ(backend.health().hardware_faults, 1U);
}

TEST(MxcfbBackend, StrictlyRejectsMalformedAndUnsupportedRequests) {
  BlockingMxcfbSyscalls syscalls;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
  ASSERT_TRUE(probe_and_start(&backend, &syscalls));
  OwnedRequest owned({{{.x = 0, .y = 0, .width = 2, .height = 2}}});

  EXPECT_EQ(backend.submit(nullptr), kPlutoStatusInvalidArgument);
  const std::size_t valid_struct_size = owned.request.struct_size;
  owned.request.struct_size = 0;
  EXPECT_EQ(backend.submit(&owned.request), kPlutoStatusInvalidArgument);
  owned.request.struct_size = valid_struct_size;

  const auto valid_format = owned.request.surface.format;
  owned.request.surface.format = kPlutoPixelFormatGray8;
  EXPECT_EQ(backend.submit(&owned.request), kPlutoStatusInvalidArgument);
  owned.request.surface.format = valid_format;

  const std::size_t valid_stride = owned.request.surface.stride_bytes;
  owned.request.surface.stride_bytes = kTightStride - 1;
  EXPECT_EQ(backend.submit(&owned.request), kPlutoStatusInvalidArgument);
  owned.request.surface.stride_bytes = valid_stride;

  const PlutoRect valid_rect = owned.damage[0];
  owned.damage[0].x = -1;
  EXPECT_EQ(backend.submit(&owned.request), kPlutoStatusInvalidArgument);
  owned.damage[0] = valid_rect;

  owned.request.flags = 1U << 31U;
  EXPECT_EQ(backend.submit(&owned.request), kPlutoStatusInvalidArgument);
  owned.request.flags = kPlutoPresentFlagSparkleDevelop;
  EXPECT_EQ(backend.submit(&owned.request), kPlutoStatusInvalidArgument);
  owned.request.flags = kPlutoPresentFlagSparkle;
  EXPECT_EQ(backend.submit(&owned.request), kPlutoStatusOk);
  EXPECT_EQ(syscalls.sent_updates().size(), 0U);
}

TEST(MxcfbBackend, SuspendTimesOutClosedThenDrainsAndClosesCleanly) {
  BlockingMxcfbSyscalls syscalls;
  CallbackCapture callbacks;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
  ASSERT_TRUE(probe_and_start(&backend, &syscalls, &callbacks));
  OwnedRequest owned({{{.x = 0, .y = 0, .width = 2, .height = 2}}});
  ASSERT_EQ(backend.submit(&owned.request), kPlutoStatusOk);
  ASSERT_TRUE(syscalls.wait_for_wait_count(1));

  EXPECT_EQ(backend.suspend(0), kPlutoStatusTimeout);
  EXPECT_FALSE(backend.ready(kPlutoRefreshUi));
  syscalls.complete_one();
  ASSERT_TRUE(callbacks.wait_for_count(1));
  EXPECT_EQ(backend.suspend(1000), kPlutoStatusOk);
  EXPECT_EQ(syscalls.munmap_count, 1);
  EXPECT_EQ(syscalls.close_count, 1);
  EXPECT_EQ(backend.wait_idle(0), kPlutoStatusOk);
  EXPECT_EQ(backend.resume(), kPlutoStatusUnsupported);
}

TEST(MxcfbBackend, StopWaitsForAcceptedMarkerBeforeClosingDevice) {
  BlockingMxcfbSyscalls syscalls;
  CallbackCapture callbacks;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
  ASSERT_TRUE(probe_and_start(&backend, &syscalls, &callbacks));
  OwnedRequest owned({{{.x = 0, .y = 0, .width = 2, .height = 2}}});
  ASSERT_EQ(backend.submit(&owned.request), kPlutoStatusOk);
  ASSERT_TRUE(syscalls.wait_for_wait_count(1));

  std::atomic<bool> stop_started = false;
  std::atomic<bool> stop_returned = false;
  std::thread stopper([&backend, &stop_started, &stop_returned] {
    stop_started.store(true, std::memory_order_release);
    backend.stop();
    stop_returned.store(true, std::memory_order_release);
  });
  while (!stop_started.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }
  EXPECT_FALSE(stop_returned.load(std::memory_order_acquire));
  syscalls.complete_one();
  stopper.join();

  EXPECT_TRUE(stop_returned.load(std::memory_order_acquire));
  EXPECT_TRUE(callbacks.wait_for_count(1));
  EXPECT_EQ(syscalls.close_count, 1);
  EXPECT_EQ(syscalls.munmap_count, 1);
  EXPECT_FALSE(backend.ready(kPlutoRefreshUi));
  EXPECT_EQ(backend.wait_idle(0), kPlutoStatusOk);
}

TEST(MxcfbBackend, ValidatesLifecyclePenFocusSnapshotAndHandoffBoundaries) {
  BlockingMxcfbSyscalls syscalls;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls));
  PlutoPresenterConfig config = presenter_config();
  EXPECT_EQ(backend.start(config), kPlutoStatusInvalidArgument);

  const auto *move = pluto::generated_device_profile_by_id("move");
  ASSERT_NE(move, nullptr);
  EXPECT_EQ(backend.probe(*move), kPlutoStatusUnsupported);
  ASSERT_EQ(backend.probe(rm1_profile()), kPlutoStatusOk);
  config.options = "unsupported=1";
  EXPECT_EQ(backend.start(config), kPlutoStatusInvalidArgument);
  config.options = nullptr;
  ASSERT_EQ(backend.start(config), kPlutoStatusOk);

  PlutoPenFocus focus{
      .struct_size = sizeof(PlutoPenFocus),
      .rect = {.x = 1, .y = 1, .width = 2, .height = 2},
      .flags = kPlutoPenFocusInRange,
      .sequence = 1,
  };
  EXPECT_EQ(backend.set_pen_focus(&focus), kPlutoStatusOk);
  focus.flags = kPlutoPenFocusContact;
  EXPECT_EQ(backend.set_pen_focus(&focus), kPlutoStatusInvalidArgument);
  focus.flags = 0;
  EXPECT_EQ(backend.set_pen_focus(&focus), kPlutoStatusOk);

  EXPECT_EQ(backend.snapshot(nullptr), kPlutoStatusInvalidArgument);
  EXPECT_EQ(backend.stage_handoff(nullptr, 0), kPlutoStatusUnsupported);
  EXPECT_EQ(backend.get_handoff(nullptr), kPlutoStatusUnsupported);
  EXPECT_EQ(backend.confirm_handoff(false), kPlutoStatusUnsupported);
}

TEST(MxcfbBackend,
     WarmHandoffPreservesFramebufferAndSkipsColdRefreshUntilFirstAdmission) {
  IsolatedHandoffPath path;
  OwnedHandoffPayload staged_payload({0x10, 0x20, 0x30, 0x40, 0x50});
  BlockingMxcfbSyscalls outgoing_syscalls;
  std::vector<std::uint8_t> inherited_framebuffer;
  {
    MxcfbDisplayBackend outgoing(rm1_profile(), fake_device(&outgoing_syscalls),
                                 100, handoff_options(path.get()));
    draw_and_stage_handoff(&outgoing, &outgoing_syscalls, &staged_payload);
    inherited_framebuffer = outgoing_syscalls.mapped_storage;
    ASSERT_EQ(::access(path.get().c_str(), F_OK), 0);
    outgoing.stop();
  }

  BlockingMxcfbSyscalls incoming_syscalls;
  incoming_syscalls.mapped_storage = inherited_framebuffer;
  CallbackCapture callbacks;
  MxcfbDisplayBackend incoming(rm1_profile(), fake_device(&incoming_syscalls),
                               200, handoff_options(path.get()));
  ASSERT_EQ(incoming.probe(rm1_profile()), kPlutoStatusOk);
  const PlutoPresenterConfig config = presenter_config(&callbacks);
  ASSERT_EQ(incoming.start(config), kPlutoStatusOk);

  EXPECT_FALSE(incoming.ready(kPlutoRefreshUi));
  EXPECT_TRUE(incoming_syscalls.sent_updates().empty());
  EXPECT_TRUE(incoming_syscalls.waited_markers().empty());
  EXPECT_EQ(incoming_syscalls.blank_count, 0);

  PlutoHandoffPayload received{.struct_size = sizeof(PlutoHandoffPayload)};
  ASSERT_EQ(incoming.get_handoff(&received), kPlutoStatusOk);
  EXPECT_EQ(received.byte_count, staged_payload.bytes.size());
  EXPECT_TRUE(std::vector<std::uint8_t>(received.bytes,
                                        received.bytes + received.byte_count) ==
              staged_payload.bytes);
  EXPECT_EQ(received.width, static_cast<std::int32_t>(kWidth));
  EXPECT_EQ(received.height, static_cast<std::int32_t>(kHeight));
  EXPECT_EQ(received.pixel_format, kPlutoPixelFormatRgb565);
  EXPECT_EQ(received.configuration_hash,
            staged_payload.payload.configuration_hash);

  ASSERT_EQ(incoming.confirm_handoff(true), kPlutoStatusOk);
  EXPECT_TRUE(incoming.ready(kPlutoRefreshUi));
  EXPECT_EQ(incoming_syscalls.blank_count, 1);
  EXPECT_TRUE(incoming_syscalls.sent_updates().empty());
  EXPECT_TRUE(incoming_syscalls.waited_markers().empty());
  ASSERT_EQ(::access(path.get().c_str(), F_OK), 0);

  std::vector<std::uint8_t> snapshot_bytes(kTightStride * kHeight, 0);
  PlutoSurface snapshot{
      .pixels = snapshot_bytes.data(),
      .stride_bytes = kTightStride,
      .width = static_cast<std::int32_t>(kWidth),
      .height = static_cast<std::int32_t>(kHeight),
      .format = kPlutoPixelFormatRgb565,
  };
  ASSERT_EQ(incoming.snapshot(&snapshot), kPlutoStatusOk);
  EXPECT_EQ(snapshot_bytes[4U * kTightStride + 6U],
            inherited_framebuffer[4U * kStride + 6U]);
  EXPECT_NE(snapshot_bytes[4U * kTightStride + 6U], kSafeInitialPixel);

  OwnedRequest next({{{.x = 20, .y = 30, .width = 2, .height = 2}}},
                    kPlutoRefreshFast, 92);
  ASSERT_EQ(incoming.submit(&next.request), kPlutoStatusOk);
  EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
  ASSERT_TRUE(incoming_syscalls.wait_for_wait_count(1));
  incoming_syscalls.complete_one();
  ASSERT_TRUE(callbacks.wait_for_count(1));
  EXPECT_TRUE(callbacks.frame_ids() == std::vector<std::uint64_t>({92}));
  EXPECT_EQ(incoming.wait_idle(1000), kPlutoStatusOk);
}

TEST(MxcfbBackend, GeneratedRgb565OpticalLutMatchesReferenceExhaustively) {
  const auto &lut = pluto::native::mxcfb::kRm1Rgb565OpticalLevelLut;
  ASSERT_EQ(lut.size(), 1u << 16u);
  for (std::uint32_t pixel = 0; pixel <= 0xffffu; ++pixel) {
    const std::uint8_t actual = lut[pixel];
    const std::uint8_t expected =
        expected_optical_level(static_cast<std::uint16_t>(pixel));
    if (actual != expected) {
      EXPECT_EQ(actual, expected) << "RGB565 pixel=" << pixel;
      return;
    }
  }
}

TEST(MxcfbBackend, BundleSeparatesExactRgb565MirrorFromMonoOpticalState) {
  IsolatedHandoffPath path;
  OwnedHandoffPayload staged_payload;
  BlockingMxcfbSyscalls syscalls;
  std::vector<std::uint8_t> expected_mirror;
  {
    MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls), 250,
                                handoff_options(path.get()));
    draw_and_stage_handoff(&backend, &syscalls, &staged_payload);
    expected_mirror = tight_visible_frame(syscalls.mapped_storage);
    backend.stop();
  }

  pluto::GlassHandoffBundle bundle;
  ASSERT_TRUE(load_handoff_bundle(path.get(), &bundle));
  EXPECT_EQ(bundle.presenter_payload.size(), kTightStride * kHeight);
  EXPECT_TRUE(bundle.presenter_payload == expected_mirror);
  EXPECT_EQ(bundle.core.engine_levels.size(),
            static_cast<std::size_t>(kVirtualWidth) * kHeight);
  EXPECT_TRUE(std::all_of(
      bundle.core.engine_levels.begin(), bundle.core.engine_levels.end(),
      [](std::uint8_t level) {
        return level <= kPaperWhiteOpticalLevel && (level & 1u) == 0;
      }));
  EXPECT_EQ(bundle.core.engine_dc.size(), bundle.core.engine_levels.size());
  EXPECT_TRUE(std::all_of(bundle.core.engine_dc.begin(),
                          bundle.core.engine_dc.end(),
                          [](std::int8_t value) { return value == 0; }));
  EXPECT_TRUE(std::all_of(bundle.core.engine_stress.begin(),
                          bundle.core.engine_stress.end(),
                          [](std::uint16_t value) { return value == 0; }));
  EXPECT_TRUE(std::all_of(bundle.core.engine_rescan.begin(),
                          bundle.core.engine_rescan.end(),
                          [](std::int32_t value) { return value == 0; }));

  const auto payload_pixel = [&bundle](std::uint32_t x, std::uint32_t y) {
    return load_rgb565(bundle.presenter_payload.data() +
                       static_cast<std::size_t>(y) * kTightStride + x * 2u);
  };
  const auto optical_level = [&bundle](std::uint32_t x, std::uint32_t y) {
    return bundle.core
        .engine_levels[static_cast<std::size_t>(y) * kVirtualWidth + x];
  };
  EXPECT_EQ(payload_pixel(3, 4), 0x0000u);
  EXPECT_EQ(payload_pixel(4, 4), 0xffffu);
  EXPECT_EQ(payload_pixel(5, 4), 0xf800u);
  EXPECT_EQ(payload_pixel(6, 4), 0x07e0u);
  EXPECT_EQ(payload_pixel(7, 4), 0x001fu);
  for (std::uint32_t x = 3; x <= 7; ++x) {
    EXPECT_EQ(optical_level(x, 4), expected_optical_level(payload_pixel(x, 4)));
  }
  EXPECT_EQ(optical_level(kWidth, 4), kPaperWhiteOpticalLevel);
  EXPECT_EQ(optical_level(kVirtualWidth - 1u, 4), kPaperWhiteOpticalLevel);

  bool complete_plane_matches = true;
  for (std::uint32_t y = 0; y < kHeight && complete_plane_matches; ++y) {
    const std::size_t payload_row = static_cast<std::size_t>(y) * kTightStride;
    const std::size_t level_row = static_cast<std::size_t>(y) * kVirtualWidth;
    for (std::uint32_t x = 0; x < kWidth; ++x) {
      const std::uint16_t pixel =
          load_rgb565(bundle.presenter_payload.data() + payload_row + x * 2u);
      if (bundle.core.engine_levels[level_row + x] !=
          expected_optical_level(pixel)) {
        complete_plane_matches = false;
        break;
      }
    }
    for (std::uint32_t x = kWidth; x < kVirtualWidth && complete_plane_matches;
         ++x) {
      if (bundle.core.engine_levels[level_row + x] != kPaperWhiteOpticalLevel) {
        complete_plane_matches = false;
      }
    }
  }
  EXPECT_TRUE(complete_plane_matches);
}

TEST(MxcfbBackend, MissingOrWrongSizePresenterPayloadFallsBackCold) {
  for (const PresenterPayloadMutation mutation :
       {PresenterPayloadMutation::kMissing,
        PresenterPayloadMutation::kWrongSize}) {
    IsolatedHandoffPath path;
    OwnedHandoffPayload staged_payload;
    BlockingMxcfbSyscalls outgoing_syscalls;
    std::vector<std::uint8_t> inherited_framebuffer;
    {
      MxcfbDisplayBackend outgoing(rm1_profile(),
                                   fake_device(&outgoing_syscalls), 260,
                                   handoff_options(path.get()));
      draw_and_stage_handoff(&outgoing, &outgoing_syscalls, &staged_payload);
      inherited_framebuffer = outgoing_syscalls.mapped_storage;
      outgoing.stop();
    }
    ASSERT_TRUE(rewrite_handoff_bundle(path.get(), mutation));

    BlockingMxcfbSyscalls incoming_syscalls;
    incoming_syscalls.mapped_storage = inherited_framebuffer;
    MxcfbDisplayBackend incoming(rm1_profile(), fake_device(&incoming_syscalls),
                                 270, handoff_options(path.get()));
    ASSERT_EQ(incoming.probe(rm1_profile()), kPlutoStatusOk);
    const PlutoPresenterConfig config = presenter_config();
    ASSERT_EQ(incoming.start(config), kPlutoStatusOk);
    EXPECT_TRUE(incoming.ready(kPlutoRefreshUi));
    EXPECT_EQ(incoming_syscalls.sent_updates().size(), 1U);
    EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
    PlutoHandoffPayload received{.struct_size = sizeof(PlutoHandoffPayload)};
    EXPECT_EQ(incoming.get_handoff(&received), kPlutoStatusAgain);
  }
}

TEST(MxcfbBackend, CrcValidPresenterOrOpticalTamperFallsBackCold) {
  for (const PresenterPayloadMutation mutation :
       {PresenterPayloadMutation::kSameLevelPixel,
        PresenterPayloadMutation::kOpticalLevel}) {
    IsolatedHandoffPath path;
    OwnedHandoffPayload staged_payload;
    BlockingMxcfbSyscalls outgoing_syscalls;
    std::vector<std::uint8_t> inherited_framebuffer;
    {
      MxcfbDisplayBackend outgoing(rm1_profile(),
                                   fake_device(&outgoing_syscalls), 280,
                                   handoff_options(path.get()));
      draw_and_stage_handoff(&outgoing, &outgoing_syscalls, &staged_payload);
      inherited_framebuffer = outgoing_syscalls.mapped_storage;
      outgoing.stop();
    }
    ASSERT_TRUE(rewrite_handoff_bundle(path.get(), mutation));

    BlockingMxcfbSyscalls incoming_syscalls;
    incoming_syscalls.mapped_storage = inherited_framebuffer;
    MxcfbDisplayBackend incoming(rm1_profile(), fake_device(&incoming_syscalls),
                                 290, handoff_options(path.get()));
    ASSERT_EQ(incoming.probe(rm1_profile()), kPlutoStatusOk);
    const PlutoPresenterConfig config = presenter_config();
    ASSERT_EQ(incoming.start(config), kPlutoStatusOk);
    EXPECT_TRUE(incoming.ready(kPlutoRefreshUi));
    EXPECT_EQ(incoming_syscalls.sent_updates().size(), 1U);
    EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
  }
}

TEST(MxcfbBackend, RendererRejectionDiscardsCandidateAndPerformsColdRefresh) {
  IsolatedHandoffPath path;
  OwnedHandoffPayload staged_payload;
  BlockingMxcfbSyscalls outgoing_syscalls;
  std::vector<std::uint8_t> inherited_framebuffer;
  {
    MxcfbDisplayBackend outgoing(rm1_profile(), fake_device(&outgoing_syscalls),
                                 300, handoff_options(path.get()));
    draw_and_stage_handoff(&outgoing, &outgoing_syscalls, &staged_payload);
    inherited_framebuffer = outgoing_syscalls.mapped_storage;
    outgoing.stop();
  }

  BlockingMxcfbSyscalls incoming_syscalls;
  incoming_syscalls.mapped_storage = inherited_framebuffer;
  MxcfbDisplayBackend incoming(rm1_profile(), fake_device(&incoming_syscalls),
                               400, handoff_options(path.get()));
  ASSERT_EQ(incoming.probe(rm1_profile()), kPlutoStatusOk);
  const PlutoPresenterConfig config = presenter_config();
  ASSERT_EQ(incoming.start(config), kPlutoStatusOk);
  EXPECT_FALSE(incoming.ready(kPlutoRefreshUi));
  ASSERT_EQ(incoming.confirm_handoff(false), kPlutoStatusOk);

  EXPECT_TRUE(incoming.ready(kPlutoRefreshUi));
  EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
  const auto updates = incoming_syscalls.sent_updates();
  const auto waits = incoming_syscalls.waited_markers();
  ASSERT_EQ(updates.size(), 1U);
  ASSERT_EQ(waits.size(), 1U);
  EXPECT_EQ(waits[0], updates[0].update_marker);
  EXPECT_EQ(updates[0].update_region.width, kWidth);
  EXPECT_EQ(updates[0].update_region.height, kHeight);
  EXPECT_EQ(updates[0].waveform_mode, uapi::kWaveformModeQuality);
  EXPECT_EQ(incoming_syscalls.mapped_storage.front(), kSafeInitialPixel);
  EXPECT_EQ(incoming_syscalls.mapped_storage.back(), kSafeInitialPixel);
}

TEST(MxcfbBackend, CorruptCandidateFallsBackColdAndCannotBeRead) {
  IsolatedHandoffPath path;
  OwnedHandoffPayload staged_payload;
  BlockingMxcfbSyscalls outgoing_syscalls;
  std::vector<std::uint8_t> inherited_framebuffer;
  {
    MxcfbDisplayBackend outgoing(rm1_profile(), fake_device(&outgoing_syscalls),
                                 500, handoff_options(path.get()));
    draw_and_stage_handoff(&outgoing, &outgoing_syscalls, &staged_payload);
    inherited_framebuffer = outgoing_syscalls.mapped_storage;
    outgoing.stop();
  }

  const int fd = ::open(path.get().c_str(), O_RDWR | O_CLOEXEC);
  ASSERT_GE(fd, 0);
  const off_t file_bytes = ::lseek(fd, 0, SEEK_END);
  ASSERT_GT(file_bytes, 0);
  std::uint8_t byte = 0;
  const off_t offset = file_bytes / 2;
  ASSERT_EQ(::pread(fd, &byte, sizeof(byte), offset),
            static_cast<ssize_t>(sizeof(byte)));
  byte ^= 0x80U;
  ASSERT_EQ(::pwrite(fd, &byte, sizeof(byte), offset),
            static_cast<ssize_t>(sizeof(byte)));
  ASSERT_EQ(::fsync(fd), 0);
  ASSERT_EQ(::close(fd), 0);

  BlockingMxcfbSyscalls incoming_syscalls;
  incoming_syscalls.mapped_storage = inherited_framebuffer;
  MxcfbDisplayBackend incoming(rm1_profile(), fake_device(&incoming_syscalls),
                               600, handoff_options(path.get()));
  ASSERT_EQ(incoming.probe(rm1_profile()), kPlutoStatusOk);
  const PlutoPresenterConfig config = presenter_config();
  ASSERT_EQ(incoming.start(config), kPlutoStatusOk);
  EXPECT_TRUE(incoming.ready(kPlutoRefreshUi));
  EXPECT_EQ(incoming_syscalls.sent_updates().size(), 1U);
  EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
  PlutoHandoffPayload received{.struct_size = sizeof(PlutoHandoffPayload)};
  EXPECT_EQ(incoming.get_handoff(&received), kPlutoStatusAgain);
}

TEST(MxcfbBackend, StaleCandidateFallsBackCold) {
  IsolatedHandoffPath path;
  OwnedHandoffPayload staged_payload;
  BlockingMxcfbSyscalls outgoing_syscalls;
  std::vector<std::uint8_t> inherited_framebuffer;
  {
    MxcfbDisplayBackend outgoing(
        rm1_profile(), fake_device(&outgoing_syscalls), 700,
        handoff_options(path.get(), handoff_clock_100));
    draw_and_stage_handoff(&outgoing, &outgoing_syscalls, &staged_payload);
    inherited_framebuffer = outgoing_syscalls.mapped_storage;
    outgoing.stop();
  }

  BlockingMxcfbSyscalls incoming_syscalls;
  incoming_syscalls.mapped_storage = inherited_framebuffer;
  MxcfbDisplayBackend incoming(rm1_profile(), fake_device(&incoming_syscalls),
                               800,
                               handoff_options(path.get(), handoff_clock_161));
  ASSERT_EQ(incoming.probe(rm1_profile()), kPlutoStatusOk);
  const PlutoPresenterConfig config = presenter_config();
  ASSERT_EQ(incoming.start(config), kPlutoStatusOk);
  EXPECT_TRUE(incoming.ready(kPlutoRefreshUi));
  EXPECT_EQ(incoming_syscalls.sent_updates().size(), 1U);
  EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
}

TEST(MxcfbBackend, ExactPipelineIdentityMismatchFallsBackCold) {
  IsolatedHandoffPath path;
  OwnedHandoffPayload staged_payload;
  BlockingMxcfbSyscalls outgoing_syscalls;
  std::vector<std::uint8_t> inherited_framebuffer;
  {
    MxcfbDisplayBackend outgoing(rm1_profile(), fake_device(&outgoing_syscalls),
                                 900, handoff_options(path.get()));
    draw_and_stage_handoff(&outgoing, &outgoing_syscalls, &staged_payload);
    inherited_framebuffer = outgoing_syscalls.mapped_storage;
    outgoing.stop();
  }

  pluto::GeneratedDeviceProfile drifted_profile = rm1_profile();
  drifted_profile.tested_os = "3.23.0.0-test-drift";
  BlockingMxcfbSyscalls incoming_syscalls;
  incoming_syscalls.mapped_storage = inherited_framebuffer;
  MxcfbDisplayBackend incoming(drifted_profile, fake_device(&incoming_syscalls),
                               1000, handoff_options(path.get()));
  ASSERT_EQ(incoming.probe(drifted_profile), kPlutoStatusOk);
  const PlutoPresenterConfig config = presenter_config();
  ASSERT_EQ(incoming.start(config), kPlutoStatusOk);
  EXPECT_TRUE(incoming.ready(kPlutoRefreshUi));
  EXPECT_EQ(incoming_syscalls.sent_updates().size(), 1U);
  EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
}

TEST(MxcfbBackend, FramebufferContinuityMismatchFallsBackCold) {
  IsolatedHandoffPath path;
  OwnedHandoffPayload staged_payload;
  BlockingMxcfbSyscalls outgoing_syscalls;
  {
    MxcfbDisplayBackend outgoing(rm1_profile(), fake_device(&outgoing_syscalls),
                                 1100, handoff_options(path.get()));
    draw_and_stage_handoff(&outgoing, &outgoing_syscalls, &staged_payload);
    outgoing.stop();
  }

  BlockingMxcfbSyscalls incoming_syscalls;
  MxcfbDisplayBackend incoming(rm1_profile(), fake_device(&incoming_syscalls),
                               1200, handoff_options(path.get()));
  ASSERT_EQ(incoming.probe(rm1_profile()), kPlutoStatusOk);
  const PlutoPresenterConfig config = presenter_config();
  ASSERT_EQ(incoming.start(config), kPlutoStatusOk);
  EXPECT_TRUE(incoming.ready(kPlutoRefreshUi));
  EXPECT_EQ(incoming_syscalls.sent_updates().size(), 1U);
  EXPECT_EQ(incoming_syscalls.mapped_storage.front(), kSafeInitialPixel);
  EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
}

TEST(MxcfbBackend,
     MissingFirstAdmissionClaimFailsClosedBeforeFramebufferWrite) {
  IsolatedHandoffPath path;
  OwnedHandoffPayload staged_payload;
  BlockingMxcfbSyscalls outgoing_syscalls;
  std::vector<std::uint8_t> inherited_framebuffer;
  {
    MxcfbDisplayBackend outgoing(rm1_profile(), fake_device(&outgoing_syscalls),
                                 1300, handoff_options(path.get()));
    draw_and_stage_handoff(&outgoing, &outgoing_syscalls, &staged_payload);
    inherited_framebuffer = outgoing_syscalls.mapped_storage;
    outgoing.stop();
  }

  BlockingMxcfbSyscalls incoming_syscalls;
  incoming_syscalls.mapped_storage = inherited_framebuffer;
  MxcfbDisplayBackend incoming(rm1_profile(), fake_device(&incoming_syscalls),
                               1400, handoff_options(path.get()));
  ASSERT_EQ(incoming.probe(rm1_profile()), kPlutoStatusOk);
  const PlutoPresenterConfig config = presenter_config();
  ASSERT_EQ(incoming.start(config), kPlutoStatusOk);
  ASSERT_EQ(incoming.confirm_handoff(true), kPlutoStatusOk);
  ASSERT_EQ(std::remove(path.get().c_str()), 0);
  const std::vector<std::uint8_t> before = incoming_syscalls.mapped_storage;

  OwnedRequest request({{{.x = 1, .y = 2, .width = 3, .height = 4}}});
  EXPECT_EQ(incoming.submit(&request.request), kPlutoStatusDeviceLost);
  EXPECT_EQ(static_cast<int>(incoming.health().state),
            static_cast<int>(NativeBackendHealthState::kDeviceLost));
  EXPECT_TRUE(incoming_syscalls.sent_updates().empty());
  EXPECT_TRUE(incoming_syscalls.mapped_storage == before);
}

TEST(MxcfbBackend, LeaseExcludesCompetingPresenterBeforeDeviceOpen) {
  IsolatedHandoffPath path;
  BlockingMxcfbSyscalls first_syscalls;
  BlockingMxcfbSyscalls second_syscalls;
  auto second = std::make_unique<MxcfbDisplayBackend>(
      rm1_profile(), fake_device(&second_syscalls), 1600,
      handoff_options(path.get()));
  {
    MxcfbDisplayBackend first(rm1_profile(), fake_device(&first_syscalls), 1500,
                              handoff_options(path.get()));
    ASSERT_EQ(first.probe(rm1_profile()), kPlutoStatusOk);
    EXPECT_EQ(second->probe(rm1_profile()), kPlutoStatusAgain);
    EXPECT_EQ(second_syscalls.open_count, 0);
  }

  EXPECT_EQ(second->probe(rm1_profile()), kPlutoStatusOk);
  EXPECT_EQ(second_syscalls.open_count, 1);
}

TEST(MxcfbBackend, ConsumedCandidateCannotReplayIntoAThirdPresenter) {
  IsolatedHandoffPath path;
  OwnedHandoffPayload staged_payload;
  BlockingMxcfbSyscalls outgoing_syscalls;
  std::vector<std::uint8_t> inherited_framebuffer;
  {
    MxcfbDisplayBackend outgoing(rm1_profile(), fake_device(&outgoing_syscalls),
                                 1650, handoff_options(path.get()));
    draw_and_stage_handoff(&outgoing, &outgoing_syscalls, &staged_payload);
    inherited_framebuffer = outgoing_syscalls.mapped_storage;
    outgoing.stop();
  }

  {
    BlockingMxcfbSyscalls consumer_syscalls;
    consumer_syscalls.mapped_storage = inherited_framebuffer;
    MxcfbDisplayBackend consumer(rm1_profile(), fake_device(&consumer_syscalls),
                                 1660, handoff_options(path.get()));
    ASSERT_EQ(consumer.probe(rm1_profile()), kPlutoStatusOk);
    const PlutoPresenterConfig config = presenter_config();
    ASSERT_EQ(consumer.start(config), kPlutoStatusOk);
    ASSERT_EQ(consumer.confirm_handoff(true), kPlutoStatusOk);
    OwnedRequest claim({{{.x = 0, .y = 0, .width = 1, .height = 1}}},
                       kPlutoRefreshFast, 93);
    claim.request.flags = kPlutoPresentFlagSparkle;
    ASSERT_EQ(consumer.submit(&claim.request), kPlutoStatusOk);
    ASSERT_NE(::access(path.get().c_str(), F_OK), 0);
    inherited_framebuffer = consumer_syscalls.mapped_storage;
    consumer.stop();
  }

  BlockingMxcfbSyscalls replay_syscalls;
  replay_syscalls.mapped_storage = inherited_framebuffer;
  MxcfbDisplayBackend replay(rm1_profile(), fake_device(&replay_syscalls), 1670,
                             handoff_options(path.get()));
  ASSERT_EQ(replay.probe(rm1_profile()), kPlutoStatusOk);
  const PlutoPresenterConfig replay_config = presenter_config();
  ASSERT_EQ(replay.start(replay_config), kPlutoStatusOk);
  EXPECT_TRUE(replay.ready(kPlutoRefreshUi));
  EXPECT_EQ(replay_syscalls.sent_updates().size(), 1U);
  PlutoHandoffPayload received{.struct_size = sizeof(PlutoHandoffPayload)};
  EXPECT_EQ(replay.get_handoff(&received), kPlutoStatusAgain);
}

TEST(MxcfbBackend, InsecureProductionOverrideCannotEnableHandoff) {
  IsolatedHandoffPath path;
  BlockingMxcfbSyscalls syscalls;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls), 1680,
                              MxcfbHandoffOptions{
                                  .path = path.get(),
                                  .allow_insecure_path_for_testing = false,
                                  .now_for_testing = nullptr,
                              });
  ASSERT_EQ(backend.probe(rm1_profile()), kPlutoStatusOk);
  const PlutoPresenterConfig config = presenter_config();
  ASSERT_EQ(backend.start(config), kPlutoStatusOk);
  EXPECT_EQ(syscalls.sent_updates().size(), 1U);
  OwnedHandoffPayload payload;
  EXPECT_EQ(backend.stage_handoff(&payload.payload, 0),
            kPlutoStatusUnsupported);
  EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
  EXPECT_NE(::access((path.get() + ".lease").c_str(), F_OK), 0);
}

TEST(MxcfbBackend, StageRequiresRealMarkerQuiescenceAndBoundedPayload) {
  IsolatedHandoffPath path;
  BlockingMxcfbSyscalls syscalls;
  MxcfbDisplayBackend backend(rm1_profile(), fake_device(&syscalls), 1700,
                              handoff_options(path.get()));
  ASSERT_TRUE(probe_and_start(&backend, &syscalls));
  OwnedRequest request({{{.x = 1, .y = 2, .width = 3, .height = 4}}});
  ASSERT_EQ(backend.submit(&request.request), kPlutoStatusOk);
  ASSERT_TRUE(syscalls.wait_for_wait_count(1));

  PlutoHandoffPayload oversized{
      .struct_size = sizeof(PlutoHandoffPayload),
      .bytes = reinterpret_cast<const std::uint8_t *>(1),
      .byte_count = (32U << 20U) + 1U,
      .width = static_cast<std::int32_t>(kWidth),
      .height = static_cast<std::int32_t>(kHeight),
      .rotation = 0,
      .pixel_format = kPlutoPixelFormatRgb565,
      .configuration_hash = 1,
  };
  EXPECT_EQ(backend.stage_handoff(&oversized, 0), kPlutoStatusInvalidArgument);

  OwnedHandoffPayload payload;
  const std::uint64_t configuration_hash = payload.payload.configuration_hash;
  payload.payload.configuration_hash = 0;
  EXPECT_EQ(backend.stage_handoff(&payload.payload, 0),
            kPlutoStatusInvalidArgument);
  payload.payload.configuration_hash = configuration_hash;
  EXPECT_EQ(backend.stage_handoff(&payload.payload, 0), kPlutoStatusAgain);
  EXPECT_FALSE(backend.ready(kPlutoRefreshUi));
  EXPECT_NE(::access(path.get().c_str(), F_OK), 0);
  syscalls.complete_one();
  ASSERT_EQ(backend.wait_idle(1000), kPlutoStatusOk);
  EXPECT_EQ(backend.stage_handoff(&payload.payload, 1000), kPlutoStatusOk);
  EXPECT_EQ(::access(path.get().c_str(), F_OK), 0);
}
