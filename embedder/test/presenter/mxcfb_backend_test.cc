#include "presenter/native/mxcfb/mxcfb_backend.h"

#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <gtest/gtest.h>
#include <sys/mman.h>

namespace {

using pluto::native::NativeBackendHealthState;
using pluto::native::mxcfb::MxcfbDevice;
using pluto::native::mxcfb::MxcfbDisplayBackend;
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
