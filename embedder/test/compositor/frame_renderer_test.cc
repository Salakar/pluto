// FrameRenderer-level tests for the renderer frame path: exact post-quantize
// rects into the scheduler, phantom-damage elimination (sub-quantum RGB
// change => zero scheduler activity), PreDithered flag semantics, the
// color-panel crush/delegate contracts, and the PLUTO_RECORD_FRAMES
// capture stream.

#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "compositor/frame_recording.h"
#include "compositor/software_compositor.h"
#include "input/ink_thread.h"
#include "presenter_ops_test_support.h"
#include "renderer/bluenoise_64.h"
#include "renderer/quantize.h"
#include "renderer/rect_utils.h"
#include "gtest/gtest.h"

namespace {

using pluto::FrameRenderer;
using pluto::FrameRendererConfig;
using pluto::GhostControlMode;
using pluto::PenRenderHintMailbox;
using pluto::PenRenderHintSnapshot;
using pluto::PlutoFramePacket;
using pluto::RendererSnapshot;
using pluto::RendererSnapshotSurface;

bool rect_equals(const PlutoRect &a, const PlutoRect &b) {
  return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;
}

bool is_gray16_rgb565(uint16_t value) {
  for (int level = 0; level < 256; level += 17) {
    const int r5 = level >> 3;
    const int g6 = level >> 2;
    const int b5 = level >> 3;
    if (value == static_cast<uint16_t>((r5 << 11) | (g6 << 5) | b5)) {
      return true;
    }
  }
  return false;
}

// A capture presenter: mono e-ink panel shape (RGB565, pre-dither consumer),
// rect_alignment=1 so the scheduler's drive rect exposes the fed damage
// exactly (guard dilation is deterministic: +4 px for fast/ui).
struct MonoCapture {
  std::mutex mutex;
  std::condition_variable wait_idle_cv;
  size_t presents = 0;
  PlutoStatus present_status = kPlutoStatusOk;
  bool ready = true;
  bool reports_completion = false;
  size_t wait_idle_calls = 0;
  size_t wait_idle_timeouts_before_ok = 0;
  FrameRenderer *completion_target_on_wait = nullptr;
  uint64_t completion_frame_on_wait = 0;
  bool completion_on_wait_sent = false;
  bool complete_latest_frame_on_wait = false;
  uint64_t latest_frame_completed_on_wait = 0;
  FrameRenderer *synchronous_completion_target = nullptr;
  bool complete_present_synchronously = false;
  uint64_t synchronous_wrong_frame_id = 0;
  bool block_next_wait_idle = false;
  bool wait_idle_entered = false;
  bool release_wait_idle = false;
  PlutoStatus wait_idle_status = kPlutoStatusOk;
  uint32_t last_flags = 0;
  PlutoRefreshClass last_class = kPlutoRefreshUi;
  PlutoRect last_rect{0, 0, 0, 0};
  std::vector<uint16_t> last_pixels; // full 64x64 surface snapshot
  std::vector<uint32_t> flags_history;
  std::vector<PlutoRefreshClass> class_history;
  std::vector<uint64_t> frame_id_history;
  std::vector<std::vector<uint16_t>> pixel_history;
  PlutoStatus pen_focus_status = kPlutoStatusOk;
  size_t pen_focus_failures_before_ok = 0;
  std::vector<PlutoPenFocus> pen_focus_history;
  bool handoff_enabled = false;
  PlutoStatus handoff_stage_status = kPlutoStatusOk;
  PlutoStatus handoff_confirm_status = kPlutoStatusOk;
  size_t handoff_stage_calls = 0;
  size_t handoff_get_calls = 0;
  size_t handoff_confirm_calls = 0;
  bool handoff_last_confirmed = false;
  bool handoff_available = false;
  bool handoff_report_color = false;
  std::vector<uint8_t> handoff_bytes;
  PlutoHandoffPayload handoff_metadata{};
};
MonoCapture g_mono_capture;

void reset_mono_capture() {
  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  g_mono_capture.presents = 0;
  g_mono_capture.present_status = kPlutoStatusOk;
  g_mono_capture.ready = true;
  g_mono_capture.reports_completion = false;
  g_mono_capture.wait_idle_calls = 0;
  g_mono_capture.wait_idle_timeouts_before_ok = 0;
  g_mono_capture.completion_target_on_wait = nullptr;
  g_mono_capture.completion_frame_on_wait = 0;
  g_mono_capture.completion_on_wait_sent = false;
  g_mono_capture.complete_latest_frame_on_wait = false;
  g_mono_capture.latest_frame_completed_on_wait = 0;
  g_mono_capture.synchronous_completion_target = nullptr;
  g_mono_capture.complete_present_synchronously = false;
  g_mono_capture.synchronous_wrong_frame_id = 0;
  g_mono_capture.block_next_wait_idle = false;
  g_mono_capture.wait_idle_entered = false;
  g_mono_capture.release_wait_idle = false;
  g_mono_capture.wait_idle_status = kPlutoStatusOk;
  g_mono_capture.last_flags = 0;
  g_mono_capture.last_class = kPlutoRefreshUi;
  g_mono_capture.last_rect = PlutoRect{0, 0, 0, 0};
  g_mono_capture.last_pixels.clear();
  g_mono_capture.flags_history.clear();
  g_mono_capture.class_history.clear();
  g_mono_capture.frame_id_history.clear();
  g_mono_capture.pixel_history.clear();
  g_mono_capture.pen_focus_status = kPlutoStatusOk;
  g_mono_capture.pen_focus_failures_before_ok = 0;
  g_mono_capture.pen_focus_history.clear();
  g_mono_capture.handoff_enabled = false;
  g_mono_capture.handoff_stage_status = kPlutoStatusOk;
  g_mono_capture.handoff_confirm_status = kPlutoStatusOk;
  g_mono_capture.handoff_stage_calls = 0;
  g_mono_capture.handoff_get_calls = 0;
  g_mono_capture.handoff_confirm_calls = 0;
  g_mono_capture.handoff_last_confirmed = false;
  g_mono_capture.handoff_available = false;
  g_mono_capture.handoff_report_color = false;
  g_mono_capture.handoff_bytes.clear();
  g_mono_capture.handoff_metadata = {};
}

const PlutoPresenterOps *mono_capture_ops() {
  static PlutoPresenterOps ops = [] {
    PlutoPresenterOps o =
        pluto::test::current_test_presenter_ops("mono-capture");
    o.info = [](PlutoPresenter *, PlutoDisplayInfo *out_info) {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      PlutoDisplayInfo info{};
      info.struct_size = sizeof(info);
      info.width = 64;
      info.height = 64;
      info.dpi = 264;
      info.preferred_format = kPlutoPixelFormatRgb565;
      info.is_color = g_mono_capture.handoff_report_color;
      info.wants_pre_dithered = true;
      info.backend_quantizes_color = g_mono_capture.handoff_report_color;
      info.rect_alignment = 1;
      info.reports_completion = g_mono_capture.reports_completion;
      for (int i = 0; i < 4; ++i) {
        info.nominal_latency_ms[i] = 0;
      }
      *out_info = info;
      return kPlutoStatusOk;
    };
    o.present = [](PlutoPresenter *, const PlutoPresentRequest *request) {
      FrameRenderer *completion_target = nullptr;
      bool complete_exact = false;
      uint64_t wrong_frame_id = 0;
      PlutoStatus status = kPlutoStatusInternal;
      {
        std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
        ++g_mono_capture.presents;
        g_mono_capture.last_flags = request->flags;
        g_mono_capture.last_class = request->refresh_class;
        g_mono_capture.last_rect = request->damage[0];
        const auto *px =
            reinterpret_cast<const uint16_t *>(request->surface.pixels);
        const size_t row_pixels = request->surface.stride_bytes / sizeof(*px);
        g_mono_capture.last_pixels.assign(
            px, px + row_pixels * static_cast<size_t>(request->surface.height));
        g_mono_capture.flags_history.push_back(request->flags);
        g_mono_capture.class_history.push_back(request->refresh_class);
        g_mono_capture.frame_id_history.push_back(request->frame_id);
        g_mono_capture.pixel_history.push_back(g_mono_capture.last_pixels);
        completion_target = g_mono_capture.synchronous_completion_target;
        complete_exact = g_mono_capture.complete_present_synchronously;
        wrong_frame_id = g_mono_capture.synchronous_wrong_frame_id;
        status = g_mono_capture.present_status;
      }
      if (completion_target != nullptr && wrong_frame_id != 0) {
        completion_target->notify_present_complete(wrong_frame_id);
      }
      if (completion_target != nullptr && complete_exact) {
        completion_target->notify_present_complete(request->frame_id);
      }
      return status;
    };
    o.ready = [](PlutoPresenter *, PlutoRefreshClass) {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      return g_mono_capture.ready;
    };
    o.wait_idle = [](PlutoPresenter *, uint32_t) {
      FrameRenderer *completion_target = nullptr;
      uint64_t completion_frame = 0;
      PlutoStatus status = kPlutoStatusOk;
      {
        std::unique_lock<std::mutex> lock(g_mono_capture.mutex);
        ++g_mono_capture.wait_idle_calls;
        if (g_mono_capture.block_next_wait_idle) {
          g_mono_capture.wait_idle_entered = true;
          g_mono_capture.wait_idle_cv.notify_all();
          g_mono_capture.wait_idle_cv.wait(
              lock, [] { return g_mono_capture.release_wait_idle; });
          g_mono_capture.block_next_wait_idle = false;
        }
        status = g_mono_capture.wait_idle_status != kPlutoStatusOk
                     ? g_mono_capture.wait_idle_status
                     : (g_mono_capture.wait_idle_calls <=
                                g_mono_capture.wait_idle_timeouts_before_ok
                            ? kPlutoStatusTimeout
                            : kPlutoStatusOk);
        if (status == kPlutoStatusOk &&
            g_mono_capture.completion_target_on_wait != nullptr &&
            g_mono_capture.completion_frame_on_wait != 0 &&
            !g_mono_capture.completion_on_wait_sent) {
          completion_target = g_mono_capture.completion_target_on_wait;
          completion_frame = g_mono_capture.completion_frame_on_wait;
          g_mono_capture.completion_on_wait_sent = true;
        } else if (status == kPlutoStatusOk &&
                   g_mono_capture.complete_latest_frame_on_wait &&
                   g_mono_capture.completion_target_on_wait != nullptr &&
                   !g_mono_capture.frame_id_history.empty() &&
                   g_mono_capture.frame_id_history.back() !=
                       g_mono_capture.latest_frame_completed_on_wait) {
          completion_target = g_mono_capture.completion_target_on_wait;
          completion_frame = g_mono_capture.frame_id_history.back();
          g_mono_capture.latest_frame_completed_on_wait = completion_frame;
        }
      }
      // Model a correct real-completion presenter: wait_idle returns only after
      // its final callback has been delivered, but the callback itself is
      // enqueue-only and therefore still awaits FrameRenderer reconciliation.
      if (completion_target != nullptr) {
        completion_target->notify_present_complete(completion_frame);
      }
      return status;
    };
    o.set_pen_focus = [](PlutoPresenter *, const PlutoPenFocus *focus) {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      if (focus == nullptr) {
        return kPlutoStatusInvalidArgument;
      }
      g_mono_capture.pen_focus_history.push_back(*focus);
      if (g_mono_capture.pen_focus_failures_before_ok > 0) {
        --g_mono_capture.pen_focus_failures_before_ok;
        return kPlutoStatusInternal;
      }
      return g_mono_capture.pen_focus_status;
    };
    o.stage_handoff = [](PlutoPresenter *, const PlutoHandoffPayload *payload,
                         uint32_t) {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      if (!g_mono_capture.handoff_enabled || payload == nullptr ||
          payload->bytes == nullptr || payload->byte_count == 0) {
        return kPlutoStatusAgain;
      }
      ++g_mono_capture.handoff_stage_calls;
      if (g_mono_capture.handoff_stage_status != kPlutoStatusOk) {
        return g_mono_capture.handoff_stage_status;
      }
      g_mono_capture.handoff_bytes.assign(payload->bytes,
                                          payload->bytes + payload->byte_count);
      g_mono_capture.handoff_metadata = *payload;
      g_mono_capture.handoff_metadata.bytes =
          g_mono_capture.handoff_bytes.data();
      g_mono_capture.handoff_available = true;
      return kPlutoStatusOk;
    };
    o.get_handoff = [](PlutoPresenter *, PlutoHandoffPayload *out) {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      ++g_mono_capture.handoff_get_calls;
      if (!g_mono_capture.handoff_enabled ||
          !g_mono_capture.handoff_available || out == nullptr) {
        return kPlutoStatusAgain;
      }
      g_mono_capture.handoff_metadata.bytes =
          g_mono_capture.handoff_bytes.data();
      *out = g_mono_capture.handoff_metadata;
      return kPlutoStatusOk;
    };
    o.confirm_handoff = [](PlutoPresenter *, bool accepted) {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      ++g_mono_capture.handoff_confirm_calls;
      g_mono_capture.handoff_last_confirmed = accepted;
      g_mono_capture.handoff_available = false;
      return g_mono_capture.handoff_confirm_status;
    };
    return o;
  }();
  return &ops;
}

FrameRendererConfig mono_capture_config() {
  FrameRendererConfig config{};
  config.width = 64;
  config.height = 64;
  config.format = kPlutoPixelFormatRgb565;
  config.start_presenter_thread = false;
  config.presenter_ops = mono_capture_ops();
  config.presenter =
      reinterpret_cast<PlutoPresenter *>(&g_mono_capture); // opaque
  return config;
}

bool wait_for_present_count(size_t expected, int attempts = 400) {
  for (int attempt = 0; attempt < attempts; ++attempt) {
    {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      if (g_mono_capture.pixel_history.size() >= expected) {
        return true;
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  return false;
}

PlutoFramePacket packet_for(const std::vector<uint16_t> &pixels, uint32_t width,
                            uint32_t height, uint64_t time_ns) {
  PlutoFramePacket packet{};
  packet.pixels = pixels.data();
  packet.row_bytes = width * sizeof(uint16_t);
  packet.width = width;
  packet.height = height;
  packet.format = kPlutoPixelFormatRgb565;
  packet.did_update = true;
  packet.presentation_time_ns = time_ns;
  return packet;
}

class TempReadyMarker {
public:
  explicit TempReadyMarker(const char *suffix)
      : directory_(std::filesystem::temp_directory_path() /
                   ("pluto-ready-marker-" + std::to_string(::getpid()) + "-" +
                    suffix)),
        marker_(directory_ / "ready") {
    std::filesystem::remove_all(directory_);
    std::filesystem::create_directories(directory_);
  }

  ~TempReadyMarker() { std::filesystem::remove_all(directory_); }

  const std::filesystem::path &marker() const { return marker_; }

private:
  std::filesystem::path directory_;
  std::filesystem::path marker_;
};

std::string read_file(const std::filesystem::path &path) {
  std::ifstream input(path);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

struct ParsedHealthRecord {
  long pid = 0;
  uint64_t sequence = 0;
  uint64_t monotonic_ms = 0;
};

bool parse_health_record(const std::string &record, ParsedHealthRecord *out) {
  if (out == nullptr) {
    return false;
  }
  unsigned long long sequence = 0;
  unsigned long long monotonic_ms = 0;
  int consumed = 0;
  const int fields =
      std::sscanf(record.c_str(), "pid=%ld seq=%llu mono_ms=%llu%n", &out->pid,
                  &sequence, &monotonic_ms, &consumed);
  if (fields != 3 || consumed < 0 ||
      static_cast<size_t>(consumed) + 1 != record.size() ||
      record[static_cast<size_t>(consumed)] != '\n') {
    return false;
  }
  out->sequence = static_cast<uint64_t>(sequence);
  out->monotonic_ms = static_cast<uint64_t>(monotonic_ms);
  return true;
}

// The diff runs after quantization: a sub-quantum RGB change (different
// bytes, identical luma) quantizes to identical levels and produces ZERO
// scheduler activity -- no damage, no diffed frame, no present.
TEST(FrameRendererTest, PhantomDamageProducesZeroSchedulerActivity) {
  // Two below-chroma-floor dark neutrals with identical luma. Chromatic raw
  // changes are intentionally real damage now, even on a luma-only backend;
  // this test pins only genuinely invisible achromatic byte noise.
  const uint16_t base = 0x0020;
  const uint16_t alt = 0x0021;
  ASSERT_NE(alt, base);
  ASSERT_EQ(pluto::rgb565_luma8(base), pluto::rgb565_luma8(alt));
  ASSERT_TRUE(!pluto::rgb565_has_chroma(base));
  ASSERT_TRUE(!pluto::rgb565_has_chroma(alt));

  reset_mono_capture();
  FrameRenderer renderer(mono_capture_config());
  ASSERT_TRUE(renderer.valid());
  std::vector<uint16_t> pixels(64 * 64, base);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  EXPECT_EQ(renderer.diffed_frames(), 1u);
  EXPECT_EQ(renderer.last_damage_count(), 1u);

  std::fill(pixels.begin(), pixels.end(), alt);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
  EXPECT_EQ(renderer.last_damage_count(), 0u);
  EXPECT_EQ(renderer.diffed_frames(), 1u);

  // Idle gate unchanged.
  PlutoFramePacket idle = packet_for(pixels, 64, 64, 3000);
  idle.did_update = false;
  ASSERT_TRUE(renderer.submit_frame(idle));
  EXPECT_EQ(renderer.idle_frames(), 1u);
  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  EXPECT_EQ(g_mono_capture.presents, 1u);
}

TEST(FrameRendererTest, DetachRejectsFramesAndAttachRebuildsPresenterState) {
  reset_mono_capture();
  FrameRenderer renderer(mono_capture_config());
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  EXPECT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));
  EXPECT_TRUE(renderer.detach_presenter());
  EXPECT_FALSE(renderer.valid());

  pixels[0] = 0;
  EXPECT_FALSE(renderer.submit_frame(packet_for(pixels, 64, 64, 2)));
  EXPECT_TRUE(renderer.attach_presenter(
      mono_capture_ops(), reinterpret_cast<PlutoPresenter *>(&g_mono_capture)));
  EXPECT_TRUE(renderer.valid());
  EXPECT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 3)));
}

TEST(FrameRendererTest,
     ExactFullReceiptRejectsLatePreActionUnknownAndOutOfOrderCompletions) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.reports_completion = true;
  }
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));
  ASSERT_TRUE(wait_for_present_count(1));
  std::uint64_t pre_action_frame_id = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.frame_id_history.size(), 1u);
    pre_action_frame_id = g_mono_capture.frame_id_history.front();
  }

  bool completed = true;
  FrameRenderer::ExactPresentationReceipt receipt{UINT64_MAX, UINT64_MAX};
  std::atomic<bool> waiter_started{false};
  std::atomic<bool> waiter_done{false};
  std::thread control_worker([&] {
    waiter_started.store(true, std::memory_order_release);
    completed = renderer.present_retained_surface_full(
        std::chrono::milliseconds(500), &receipt);
    waiter_done.store(true, std::memory_order_release);
  });
  while (!waiter_started.load(std::memory_order_acquire)) {
    std::this_thread::yield();
  }

  // A new retained Flutter surface arrives while the old present is still in
  // flight. The proof must drain that exact app-owned update first and its
  // eventual Full must replay these newer pixels, not the pre-action surface.
  pixels[0] = 0;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2)));

  // Future ids arriving out of order, an unrelated maintenance/Sparkle-like
  // id, and stale duplicates are not proof. The real older presents must
  // retire before the dedicated Full dispatch.
  renderer.notify_present_complete(pre_action_frame_id + 1);
  renderer.notify_present_complete(pre_action_frame_id + 2);
  renderer.notify_present_complete(999999);
  std::this_thread::sleep_for(std::chrono::milliseconds(15));
  EXPECT_FALSE(waiter_done.load(std::memory_order_acquire));
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    EXPECT_EQ(g_mono_capture.presents, 1u);
  }
  renderer.notify_present_complete(pre_action_frame_id);
  ASSERT_TRUE(wait_for_present_count(2));
  std::uint64_t post_action_frame_id = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    post_action_frame_id = g_mono_capture.frame_id_history.back();
  }
  ASSERT_EQ(post_action_frame_id, pre_action_frame_id + 1);
  renderer.notify_present_complete(post_action_frame_id);
  ASSERT_TRUE(wait_for_present_count(3));
  std::uint64_t proof_frame_id = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.frame_id_history.size(), 3u);
    proof_frame_id = g_mono_capture.frame_id_history.back();
    EXPECT_EQ(g_mono_capture.class_history.back(), kPlutoRefreshFull);
    EXPECT_EQ(g_mono_capture.flags_history.back(),
              kPlutoPresentFlagPreDithered);
    ASSERT_TRUE(!g_mono_capture.pixel_history.back().empty());
    EXPECT_EQ(g_mono_capture.pixel_history.back()[0], 0u);
    EXPECT_TRUE(rect_equals(g_mono_capture.last_rect, PlutoRect{0, 0, 64, 64}));
  }
  ASSERT_EQ(proof_frame_id, pre_action_frame_id + 2);
  renderer.notify_present_complete(pre_action_frame_id);
  renderer.notify_present_complete(proof_frame_id + 50);
  std::this_thread::sleep_for(std::chrono::milliseconds(15));
  EXPECT_FALSE(waiter_done.load(std::memory_order_acquire));
  renderer.notify_present_complete(proof_frame_id);
  control_worker.join();

  EXPECT_TRUE(completed);
  EXPECT_EQ(receipt.surface_generation, 2u);
  EXPECT_EQ(receipt.frame_id, proof_frame_id);
}

TEST(FrameRendererTest, ExactFullReceiptHandlesSynchronousExactCompletion) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.reports_completion = true;
  }
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));
  ASSERT_TRUE(wait_for_present_count(1));
  uint64_t initial_frame_id = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    initial_frame_id = g_mono_capture.frame_id_history.back();
  }
  renderer.notify_present_complete(initial_frame_id);
  // Reconcile the initial completion before enabling synchronous callbacks.
  const auto initial_deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(250);
  while (std::chrono::steady_clock::now() < initial_deadline) {
    if (renderer.queued_present_completions_for_testing() == 0) {
      break;
    }
    std::this_thread::yield();
  }
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.synchronous_completion_target = &renderer;
    g_mono_capture.synchronous_wrong_frame_id = 777777;
    g_mono_capture.complete_present_synchronously = true;
  }

  FrameRenderer::ExactPresentationReceipt receipt;
  ASSERT_TRUE(renderer.present_retained_surface_full(
      std::chrono::milliseconds(250), &receipt));
  EXPECT_EQ(receipt.surface_generation, 1u);
  EXPECT_NE(receipt.frame_id, 0u);
}

TEST(FrameRendererTest, ExactFullReceiptTimesOutWithoutItsExactCompletion) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.reports_completion = true;
  }
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));
  ASSERT_TRUE(wait_for_present_count(1));
  uint64_t initial_frame_id = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    initial_frame_id = g_mono_capture.frame_id_history.back();
  }
  renderer.notify_present_complete(initial_frame_id);

  FrameRenderer::ExactPresentationReceipt receipt{UINT64_MAX, UINT64_MAX};
  EXPECT_FALSE(renderer.present_retained_surface_full(
      std::chrono::milliseconds(35), &receipt));
  EXPECT_EQ(receipt.surface_generation, 0u);
  EXPECT_EQ(receipt.frame_id, 0u);
}

TEST(FrameRendererTest, FlutterSurfaceFenceRequiresStrictlyNewFrame) {
  reset_mono_capture();
  FrameRenderer renderer(mono_capture_config());
  ASSERT_TRUE(renderer.valid());
  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));
  const uint64_t baseline = renderer.flutter_surface_generation();
  ASSERT_EQ(baseline, 1u);
  uint64_t generation = 0;
  EXPECT_FALSE(renderer.wait_for_flutter_surface_after(
      baseline, std::chrono::milliseconds(2), &generation));
  EXPECT_EQ(generation, baseline);
  renderer.notify_idle_frame();
  EXPECT_TRUE(renderer.wait_for_flutter_surface_after(
      baseline, std::chrono::milliseconds(20), &generation));
  EXPECT_EQ(generation, baseline + 1);
}

TEST(FrameRendererTest,
     ReattachReplaysRetainedSurfaceAndRecreatesHealthWithoutFlutterFrame) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.reports_completion = true;
    g_mono_capture.handoff_enabled = true;
  }
  TempReadyMarker health("health-warm-resume");
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  config.health_file_path = health.marker().string();
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  ASSERT_TRUE(wait_for_present_count(1));

  uint64_t initial_frame_id = 0;
  uint16_t initial_presented_pixel = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.frame_id_history.size(), 1u);
    initial_frame_id = g_mono_capture.frame_id_history.back();
    ASSERT_TRUE(!g_mono_capture.pixel_history.back().empty());
    initial_presented_pixel = g_mono_capture.pixel_history.back()[0];
  }
  renderer.notify_present_complete(initial_frame_id);

  ParsedHealthRecord initial_health{};
  const auto initial_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (std::chrono::steady_clock::now() < initial_deadline) {
    if (std::filesystem::exists(health.marker()) &&
        parse_health_record(read_file(health.marker()), &initial_health)) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  ASSERT_EQ(initial_health.pid, static_cast<long>(::getpid()));
  ASSERT_EQ(initial_health.sequence, 1u);

  ASSERT_TRUE(renderer.detach_presenter());
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_TRUE(g_mono_capture.handoff_available);
  }

  // This is the supervisor's real warm-resume boundary: stale proof from the
  // stopped presenter generation is removed before SIGCONT/SIGUSR2.
  ASSERT_TRUE(std::filesystem::remove(health.marker()));
  ASSERT_TRUE(!std::filesystem::exists(health.marker()));

  // No Flutter packet is submitted after attach. Reattach itself must replay
  // the retained app surface, including the zero-diff/same-glass case.
  ASSERT_TRUE(renderer.attach_presenter(
      mono_capture_ops(), reinterpret_cast<PlutoPresenter *>(&g_mono_capture)));
  ASSERT_TRUE(wait_for_present_count(2));
  EXPECT_EQ(renderer.submitted_frames(), 1u)
      << "an exact same-surface handoff should skip full tile traversal";

  uint64_t resumed_frame_id = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.frame_id_history.size(), 2u);
    resumed_frame_id = g_mono_capture.frame_id_history.back();
    EXPECT_EQ(g_mono_capture.class_history.back(), kPlutoRefreshFast);
    EXPECT_TRUE(rect_equals(g_mono_capture.last_rect, PlutoRect{0, 0, 1, 1}));
    ASSERT_TRUE(!g_mono_capture.last_pixels.empty());
    EXPECT_EQ(g_mono_capture.last_pixels[0], initial_presented_pixel);
  }
  renderer.notify_present_complete(resumed_frame_id);

  ParsedHealthRecord resumed_health{};
  const auto resumed_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (std::chrono::steady_clock::now() < resumed_deadline) {
    if (std::filesystem::exists(health.marker()) &&
        parse_health_record(read_file(health.marker()), &resumed_health)) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  EXPECT_EQ(resumed_health.pid, static_cast<long>(::getpid()));
  EXPECT_GT(resumed_health.sequence, initial_health.sequence);
  EXPECT_GE(resumed_health.monotonic_ms, initial_health.monotonic_ms);
}

TEST(FrameRendererTest,
     WarmReattachReconcilesDifferentForegroundSurfaceBeforeHealthProof) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.handoff_enabled = true;
  }
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  config.enable_auto_ghostbuster = false;
  FrameRenderer resumed(config);
  ASSERT_TRUE(resumed.valid());

  const std::vector<uint16_t> resumed_pixels(64 * 64, 0x0000);
  ASSERT_TRUE(resumed.submit_frame(packet_for(resumed_pixels, 64, 64, 1000)));
  ASSERT_TRUE(wait_for_present_count(1));
  std::this_thread::sleep_for(std::chrono::milliseconds(80));
  ASSERT_TRUE(resumed.detach_presenter());

  // A different foreground owns the panel while the first isolate sleeps.
  const std::vector<uint16_t> foreground_pixels(64 * 64, 0xffff);
  {
    FrameRenderer foreground(config);
    ASSERT_TRUE(foreground.valid());
    ASSERT_TRUE(
        foreground.submit_frame(packet_for(foreground_pixels, 64, 64, 2000)));
    ASSERT_TRUE(wait_for_present_count(2));
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    ASSERT_TRUE(foreground.detach_presenter());
  }

  size_t before_resume = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    before_resume = g_mono_capture.presents;
  }
  ASSERT_TRUE(resumed.attach_presenter(
      mono_capture_ops(), reinterpret_cast<PlutoPresenter *>(&g_mono_capture)));
  ASSERT_TRUE(wait_for_present_count(before_resume + 1));
  EXPECT_EQ(resumed.submitted_frames(), 2u)
      << "different glass must take the complete normal reconciliation path";
  EXPECT_GT(resumed.last_damage_count(), 0u);
  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  EXPECT_TRUE(g_mono_capture.last_pixels == resumed_pixels)
      << "the sleeping app's retained pixels, not the outgoing handoff, must "
         "be presented";
}

TEST(FrameRendererTest, RotationAndDetachDrainCompletionBeforeFrameIdReuse) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.reports_completion = true;
  }
  FrameRenderer renderer(mono_capture_config());
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));
  uint64_t first_generation_id = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.frame_id_history.size(), 1u);
    first_generation_id = g_mono_capture.frame_id_history.back();
    g_mono_capture.completion_target_on_wait = &renderer;
    g_mono_capture.completion_frame_on_wait = first_generation_id;
    g_mono_capture.completion_on_wait_sent = false;
  }

  // Rotation already uses wait_idle as a generation boundary. Its delivered
  // callback must be drained against the old scheduler before configure()
  // restarts frame ids from 1.
  ASSERT_TRUE(renderer.set_rotation(90, 64, 64));
  EXPECT_EQ(renderer.queued_present_completions_for_testing(), 0u);
  pixels[0] = 0x0000;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2)));

  uint64_t rotation_generation_id = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.frame_id_history.size(), 2u);
    rotation_generation_id = g_mono_capture.frame_id_history.back();
    EXPECT_EQ(rotation_generation_id, first_generation_id)
        << "RegionScheduler frame ids intentionally restart after configure";
    g_mono_capture.completion_target_on_wait = &renderer;
    g_mono_capture.completion_frame_on_wait = rotation_generation_id;
    g_mono_capture.completion_on_wait_sent = false;
  }

  // Detach must provide the same boundary before attach recreates the
  // scheduler. The callback has run, but its enqueue is deliberately left for
  // detach to reconcile under the renderer mutex.
  ASSERT_TRUE(renderer.detach_presenter());
  EXPECT_EQ(renderer.queued_present_completions_for_testing(), 0u);
  ASSERT_TRUE(renderer.attach_presenter(
      mono_capture_ops(), reinterpret_cast<PlutoPresenter *>(&g_mono_capture)));
  pixels[1] = 0x0000;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 3)));

  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.frame_id_history.size(), 3u);
    EXPECT_EQ(g_mono_capture.frame_id_history.back(), first_generation_id);
  }

  // With no completion for the new generation, overlapping work must remain
  // behind its real fence. A stale id carried across detach would retire it and
  // incorrectly allow this fourth present immediately.
  pixels[1] = 0xffff;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 4)));
  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  EXPECT_EQ(g_mono_capture.frame_id_history.size(), 3u);
}

TEST(FrameRendererTest, DetachSerializesLateFrameAcrossIdleFence) {
  reset_mono_capture();
  FrameRenderer renderer(mono_capture_config());
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.block_next_wait_idle = true;
  }

  std::atomic<bool> detach_result{false};
  std::thread detacher(
      [&] { detach_result.store(renderer.detach_presenter(5000)); });
  bool idle_fence_entered = false;
  {
    std::unique_lock<std::mutex> lock(g_mono_capture.mutex);
    idle_fence_entered =
        g_mono_capture.wait_idle_cv.wait_for(lock, std::chrono::seconds(2), [] {
          return g_mono_capture.wait_idle_entered;
        });
  }
  if (!idle_fence_entered) {
    {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      g_mono_capture.release_wait_idle = true;
    }
    g_mono_capture.wait_idle_cv.notify_all();
    detacher.join();
    EXPECT_TRUE(idle_fence_entered) << "detach never entered wait_idle";
    return;
  }

  pixels[0] = 0x0000;
  std::atomic<bool> submit_started{false};
  std::atomic<bool> submit_returned{false};
  std::atomic<bool> submit_result{true};
  std::thread late_submit([&] {
    submit_started.store(true, std::memory_order_release);
    submit_result.store(renderer.submit_frame(packet_for(pixels, 64, 64, 2)),
                        std::memory_order_release);
    submit_returned.store(true, std::memory_order_release);
  });
  const auto start_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (!submit_started.load(std::memory_order_acquire) &&
         std::chrono::steady_clock::now() < start_deadline) {
    std::this_thread::yield();
  }
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  EXPECT_FALSE(submit_returned.load(std::memory_order_acquire))
      << "late raster must stay behind detach's renderer mutex";

  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.release_wait_idle = true;
  }
  g_mono_capture.wait_idle_cv.notify_all();
  detacher.join();
  late_submit.join();

  EXPECT_TRUE(detach_result.load(std::memory_order_acquire));
  EXPECT_TRUE(submit_returned.load(std::memory_order_acquire));
  EXPECT_FALSE(submit_result.load(std::memory_order_acquire))
      << "the late frame must observe the detached invalid renderer";
}

TEST(FrameRendererTest,
     DetachDrainsUserTruthUnparkedByFinalCompletionBeforeStaging) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.handoff_enabled = true;
    g_mono_capture.reports_completion = true;
  }
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = false;
  config.enable_auto_ghostbuster = false;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));
  pixels[0] = 0x001f;
  pixels[1] = 0xf800;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2)));
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.frame_id_history.size(), 1u);
    g_mono_capture.completion_target_on_wait = &renderer;
    g_mono_capture.complete_latest_frame_on_wait = true;
  }

  ASSERT_TRUE(renderer.detach_presenter());
  std::vector<uint8_t> encoded;
  uint64_t configuration_hash = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.frame_id_history.size(), 2u)
        << "the completion fence must unpark and present the newer truth";
    ASSERT_EQ(g_mono_capture.handoff_stage_calls, 1u);
    ASSERT_TRUE(g_mono_capture.handoff_available);
    encoded = g_mono_capture.handoff_bytes;
    configuration_hash = g_mono_capture.handoff_metadata.configuration_hash;
  }
  pluto::RendererHandoffState decoded;
  pluto::RendererHandoffReject reject = pluto::RendererHandoffReject::kArgument;
  ASSERT_TRUE(pluto::renderer_handoff_decode(encoded, configuration_hash,
                                             &decoded, &reject));
  ASSERT_EQ(decoded.retained_frame.size(), pixels.size() * sizeof(uint16_t));
  EXPECT_EQ(std::memcmp(decoded.retained_frame.data(), pixels.data(),
                        decoded.retained_frame.size()),
            0)
      << "the staged mirror must contain B, not the just-completed A frame";
}

TEST(FrameRendererTest,
     BackpressuredUserTruthReachesDeadlineWithoutPublishingWarmState) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.handoff_enabled = true;
    g_mono_capture.ready = false;
  }
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = false;
  config.enable_auto_ghostbuster = false;
  FrameRenderer renderer(config);
  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));

  const auto before = std::chrono::steady_clock::now();
  EXPECT_TRUE(renderer.detach_presenter(10));
  const auto elapsed = std::chrono::steady_clock::now() - before;
  EXPECT_TRUE(elapsed < std::chrono::seconds(1))
      << "cold fallback must remain bounded by the detach deadline";
  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  EXPECT_EQ(g_mono_capture.handoff_stage_calls, 0u);
  EXPECT_FALSE(g_mono_capture.handoff_available);
  EXPECT_EQ(g_mono_capture.presents, 0u)
      << "never discard or fabricate backpressured app-owned pixels";
}

TEST(FrameRendererTest,
     WarmReattachResetRestoresRetainedContentBeforeNewFrame) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.handoff_enabled = true;
  }
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0x8410);
  pixels[0] = 0x0000;
  pixels[1] = 0xffff;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));
  std::vector<uint16_t> expected;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_TRUE(!g_mono_capture.pixel_history.empty());
    expected = g_mono_capture.pixel_history.back();
  }

  // Give the synthetic-completion scheduler one presenter-loop turn, then
  // stage the complete renderer transaction before the old scheduler dies.
  std::this_thread::sleep_for(std::chrono::milliseconds(80));
  ASSERT_TRUE(renderer.detach_presenter());
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.handoff_stage_calls, 1u);
    ASSERT_TRUE(g_mono_capture.handoff_available);
    ASSERT_TRUE(!g_mono_capture.handoff_bytes.empty());
  }
  ASSERT_TRUE(renderer.attach_presenter(
      mono_capture_ops(), reinterpret_cast<PlutoPresenter *>(&g_mono_capture)));
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    EXPECT_EQ(g_mono_capture.handoff_confirm_calls, 1u);
    EXPECT_TRUE(g_mono_capture.handoff_last_confirmed);
  }

  // Resume must not depend on Flutter deciding that an unchanged layer tree
  // needs another raster. Reattach has already reconciled this app's complete
  // retained surface against the imported physical baseline and queued a real
  // presentation, so the reset source is app-owned before any new packet.
  ASSERT_TRUE(wait_for_present_count(2));
  size_t before_reset = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    before_reset = g_mono_capture.pixel_history.size();
  }
  ASSERT_TRUE(renderer.request_pixel_reset());
  ASSERT_TRUE(wait_for_present_count(before_reset + 7));
  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  EXPECT_TRUE(g_mono_capture.pixel_history[before_reset + 6] == expected);
  EXPECT_EQ(g_mono_capture.class_history[before_reset + 6], kPlutoRefreshFull);
  EXPECT_NE(g_mono_capture.flags_history[before_reset + 6] &
                kPlutoPresentFlagPixelResetRestore,
            0u);
}

TEST(FrameRendererTest,
     WarmExactColorBaselineFindsSameLumaHueOnFirstIncomingFrame) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.handoff_enabled = true;
    g_mono_capture.handoff_report_color = true;
  }
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  config.enable_auto_ghostbuster = false;
  constexpr uint16_t kHueA = 0x023b;
  constexpr uint16_t kHueB = 0x88df;
  ASSERT_EQ(pluto::rgb565_luma8(kHueA), pluto::rgb565_luma8(kHueB));
  std::vector<uint16_t> pixels(64 * 64, kHueA);
  {
    FrameRenderer outgoing(config);
    ASSERT_TRUE(outgoing.valid());
    ASSERT_TRUE(outgoing.submit_frame(packet_for(pixels, 64, 64, 1)));
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    ASSERT_TRUE(outgoing.detach_presenter());
  }
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.handoff_stage_calls, 1u);
    g_mono_capture.presents = 0;
    g_mono_capture.pixel_history.clear();
    g_mono_capture.flags_history.clear();
    g_mono_capture.class_history.clear();
    g_mono_capture.frame_id_history.clear();
  }

  FrameRenderer incoming(config);
  ASSERT_TRUE(incoming.valid());
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.handoff_confirm_calls, 1u);
    ASSERT_TRUE(g_mono_capture.handoff_last_confirmed);
  }
  EXPECT_FALSE(incoming.request_pixel_reset())
      << "a physical seed is not yet this app's reset source";
  for (int32_t y = 12; y < 16; ++y) {
    for (int32_t x = 20; x < 24; ++x) {
      pixels[static_cast<size_t>(y) * 64 + x] = kHueB;
    }
  }
  PlutoRect misleading_bound{20, 12, 1, 1};
  PlutoFramePacket first = packet_for(pixels, 64, 64, 2);
  first.paint_bounds = &misleading_bound;
  first.paint_bounds_count = 1;
  ASSERT_TRUE(incoming.submit_frame(first));
  EXPECT_GT(incoming.last_damage_count(), 0u)
      << "the first incoming pass must scan the whole app surface while "
         "comparing against retained exact RGB";
  std::this_thread::sleep_for(std::chrono::milliseconds(80));
  ASSERT_TRUE(incoming.detach_presenter());
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    EXPECT_EQ(g_mono_capture.handoff_stage_calls, 2u)
        << "an admitted exact-color owner must publish a successor bundle";
    EXPECT_TRUE(g_mono_capture.handoff_available);
  }
}

TEST(FrameRendererTest,
     WarmHandoffDoesNotImportOutgoingSupervisorMaintenanceGate) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.handoff_enabled = true;
  }
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  config.enable_auto_ghostbuster = false;
  std::vector<uint16_t> pixels(64 * 64, 0x8410);
  {
    FrameRenderer outgoing(config);
    ASSERT_TRUE(outgoing.valid());
    ASSERT_TRUE(outgoing.submit_frame(packet_for(pixels, 64, 64, 1)));
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    // EngineHost closes every production process with this external gate
    // disabled. It is not panel history and must not cross into a new owner.
    outgoing.set_auto_maintenance_allowed(false);
    ASSERT_TRUE(outgoing.detach_presenter());
  }

  FrameRenderer incoming(config);
  ASSERT_TRUE(incoming.valid());
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.handoff_confirm_calls, 1u);
    ASSERT_TRUE(g_mono_capture.handoff_last_confirmed);
  }
  EXPECT_TRUE(incoming.auto_maintenance_allowed_for_testing())
      << "a newly spawned owner must retain its own enabled supervisor gate";
}

TEST(FrameRendererTest,
     CorruptAndConfigurationMismatchedRendererCandidatesConfirmColdFallback) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.handoff_enabled = true;
  }
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  config.enable_auto_ghostbuster = false;
  std::vector<uint16_t> pixels(64 * 64, 0x8410);
  {
    FrameRenderer outgoing(config);
    ASSERT_TRUE(outgoing.submit_frame(packet_for(pixels, 64, 64, 1)));
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    ASSERT_TRUE(outgoing.detach_presenter());
  }

  std::vector<uint8_t> valid_bytes;
  PlutoHandoffPayload valid_metadata{};
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_TRUE(g_mono_capture.handoff_available);
    valid_bytes = g_mono_capture.handoff_bytes;
    valid_metadata = g_mono_capture.handoff_metadata;
    g_mono_capture.handoff_bytes.back() ^= 0x40u;
    g_mono_capture.handoff_confirm_status = kPlutoStatusDeviceLost;
  }
  std::atomic<size_t> fatal_callbacks{0};
  config.on_presenter_device_lost = [&fatal_callbacks] {
    fatal_callbacks.fetch_add(1, std::memory_order_acq_rel);
  };
  {
    FrameRenderer corrupt(config);
    ASSERT_TRUE(corrupt.valid());
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    EXPECT_EQ(g_mono_capture.handoff_confirm_calls, 1u);
    EXPECT_FALSE(g_mono_capture.handoff_last_confirmed);
  }
  EXPECT_EQ(fatal_callbacks.load(std::memory_order_acquire), 1u)
      << "failed candidate invalidation must request a cold process restart";

  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.handoff_confirm_status = kPlutoStatusOk;
    g_mono_capture.handoff_bytes = valid_bytes;
    g_mono_capture.handoff_metadata = valid_metadata;
    g_mono_capture.handoff_metadata.configuration_hash ^= 1u;
    g_mono_capture.handoff_available = true;
    g_mono_capture.handoff_last_confirmed = true;
  }
  {
    FrameRenderer mismatch(config);
    ASSERT_TRUE(mismatch.valid());
    EXPECT_FALSE(mismatch.request_pixel_reset());
    ASSERT_TRUE(mismatch.submit_frame(packet_for(pixels, 64, 64, 2)));
    EXPECT_GT(mismatch.last_damage_count(), 0u)
        << "rejected candidate must retain the ordinary cold invalid ledger";
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    EXPECT_EQ(g_mono_capture.handoff_confirm_calls, 2u);
    EXPECT_FALSE(g_mono_capture.handoff_last_confirmed);
  }
}

TEST(FrameRendererTest, UnacknowledgedCompletionNeverStagesRendererHandoff) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.handoff_enabled = true;
    g_mono_capture.reports_completion = true;
  }
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = false;
  config.enable_auto_ghostbuster = false;
  FrameRenderer renderer(config);
  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));
  ASSERT_TRUE(renderer.detach_presenter());
  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  EXPECT_EQ(g_mono_capture.handoff_stage_calls, 0u)
      << "presenter idle alone cannot retire the renderer's unacknowledged "
         "completion ledger";
  EXPECT_FALSE(g_mono_capture.handoff_available);
}

TEST(FrameRendererTest, ShutdownDuringBlackCompletesWhiteAndContent) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.reports_completion = true;
    g_mono_capture.wait_idle_timeouts_before_ok = 1;
  }
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0x8410);
  pixels[0] = 0x0000;
  pixels[1] = 0xffff;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));
  uint64_t initial_frame_id = 0;
  std::vector<uint16_t> expected;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.frame_id_history.size(), 1u);
    initial_frame_id = g_mono_capture.frame_id_history[0];
    expected = g_mono_capture.pixel_history[0];
  }
  renderer.notify_present_complete(initial_frame_id);
  ASSERT_TRUE(renderer.request_pixel_reset());
  ASSERT_TRUE(wait_for_present_count(2));
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_NE(
        g_mono_capture.flags_history[1] & kPlutoPresentFlagPixelResetBlack, 0u);
  }

  // The fake reports true device completions but deliberately drops every
  // reset callback. wait_idle() is the shutdown fence proving each stage is
  // physically complete; teardown must still finish white and restore.
  renderer.shutdown();

  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  ASSERT_EQ(g_mono_capture.pixel_history.size(), 4u);
  EXPECT_TRUE(std::all_of(g_mono_capture.pixel_history[2].begin(),
                          g_mono_capture.pixel_history[2].end(),
                          [](uint16_t px) { return px == 0xffff; }));
  EXPECT_TRUE(g_mono_capture.pixel_history[3] == expected);
  EXPECT_NE(
      g_mono_capture.flags_history[3] & kPlutoPresentFlagPixelResetRestore, 0u);
  EXPECT_EQ(g_mono_capture.class_history[3], kPlutoRefreshFull);
  EXPECT_GT(g_mono_capture.wait_idle_calls, 3u);
}

TEST(FrameRendererTest,
     ActiveResetDetachFencesNewestLedgerFollowupBeforeGenerationReset) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.reports_completion = true;
  }
  FrameRenderer renderer(mono_capture_config());
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));

  const auto complete_latest = [&] {
    uint64_t frame_id = 0;
    {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      ASSERT_TRUE(!g_mono_capture.frame_id_history.empty());
      frame_id = g_mono_capture.frame_id_history.back();
    }
    renderer.notify_present_complete(frame_id);
  };
  const auto expect_latest_flags = [](uint32_t flags) {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_TRUE(!g_mono_capture.flags_history.empty());
    EXPECT_NE(g_mono_capture.flags_history.back() & flags, 0u);
  };
  const auto complete_change_and_expect = [&](size_t pixel, uint64_t time_ns,
                                              uint32_t flags) {
    complete_latest();
    pixels[pixel] = 0x0000;
    ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, time_ns)));
    expect_latest_flags(flags);
  };

  complete_latest();
  ASSERT_TRUE(renderer.request_ghost_control(GhostControlMode::kBleachNow));
  expect_latest_flags(kPlutoPresentFlagPixelResetBlack);
  complete_change_and_expect(0, 2, kPlutoPresentFlagPixelResetWhite);
  complete_change_and_expect(1, 3, kPlutoPresentFlagPixelResetBlack);
  complete_change_and_expect(2, 4, kPlutoPresentFlagPixelResetWhite);
  complete_change_and_expect(3, 5, kPlutoPresentFlagPixelResetRestore);

  // The restore presenter has already snapshotted pixels[0..3]. This newer
  // Flutter frame must remain ledger-only until restore completes, then be
  // sent as the reset FSM's current-ledger Fast follow-up.
  pixels[4] = 0x0000;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 6)));
  size_t before_detach = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    before_detach = g_mono_capture.frame_id_history.size();
    ASSERT_EQ(before_detach, 6u);
    g_mono_capture.completion_target_on_wait = &renderer;
    g_mono_capture.complete_latest_frame_on_wait = true;
    // The manually delivered white completion precedes the in-flight restore.
    g_mono_capture.latest_frame_completed_on_wait =
        g_mono_capture.frame_id_history[before_detach - 2];
  }

  ASSERT_TRUE(renderer.detach_presenter(5000));
  EXPECT_FALSE(renderer.valid());
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.frame_id_history.size(), before_detach + 1);
    EXPECT_EQ(g_mono_capture.class_history.back(), kPlutoRefreshFast);
    EXPECT_EQ(g_mono_capture.flags_history.back() &
                  (kPlutoPresentFlagPixelResetBlack |
                   kPlutoPresentFlagPixelResetWhite |
                   kPlutoPresentFlagPixelResetRestore),
              0u);
    EXPECT_TRUE(g_mono_capture.pixel_history.back() == pixels);
    EXPECT_GE(g_mono_capture.wait_idle_calls, 2u)
        << "restore and newest-ledger follow-up need separate optical fences";
  }
}

TEST(FrameRendererTest, ActiveResetDetachBackpressureHonorsAbsoluteDeadline) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.reports_completion = true;
  }
  FrameRenderer renderer(mono_capture_config());
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));
  const auto complete_latest = [&] {
    uint64_t frame_id = 0;
    {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      ASSERT_TRUE(!g_mono_capture.frame_id_history.empty());
      frame_id = g_mono_capture.frame_id_history.back();
    }
    renderer.notify_present_complete(frame_id);
  };
  const auto complete_and_change = [&](size_t pixel, uint64_t time_ns) {
    complete_latest();
    pixels[pixel] = 0x0000;
    ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, time_ns)));
  };

  complete_latest();
  ASSERT_TRUE(renderer.request_ghost_control(GhostControlMode::kBleachNow));
  complete_and_change(0, 2); // black -> white
  complete_and_change(1, 3); // first white -> second black
  complete_and_change(2, 4); // black -> white
  complete_and_change(3, 5); // white -> balanced restore
  pixels[4] = 0x0000;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 6)));

  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_EQ(g_mono_capture.frame_id_history.size(), 6u);
    g_mono_capture.completion_target_on_wait = &renderer;
    g_mono_capture.complete_latest_frame_on_wait = true;
    g_mono_capture.latest_frame_completed_on_wait =
        g_mono_capture.frame_id_history[4];
    // Restore can finish, but its required newest-ledger follow-up cannot be
    // admitted. wait_idle() still reports Ok because no presenter work was
    // accepted; detach must nevertheless honor its scheduler-aware deadline.
    g_mono_capture.ready = false;
  }

  const auto started = std::chrono::steady_clock::now();
  EXPECT_FALSE(renderer.detach_presenter(25));
  const auto elapsed = std::chrono::steady_clock::now() - started;
  EXPECT_TRUE(elapsed < std::chrono::seconds(1))
      << "idle presenter plus declined scheduler work must not spin forever";
  EXPECT_TRUE(renderer.valid()) << "a failed detach keeps the presenter live";

  // Leave the fixture in a clean, completable state for destructor teardown.
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.ready = true;
  }
  pixels[5] = 0x0000;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 7)));
  EXPECT_TRUE(renderer.detach_presenter(5000));
}

TEST(FrameRendererTest, RejectsNonCurrentPresenterOperationTables) {
  reset_mono_capture();
  FrameRendererConfig config = mono_capture_config();

  PlutoPresenterOps short_table = *mono_capture_ops();
  short_table.struct_size = sizeof(short_table) - 1u;
  config.presenter_ops = &short_table;
  FrameRenderer short_renderer(config);
  EXPECT_FALSE(short_renderer.valid());

  PlutoPresenterOps oversized_table = *mono_capture_ops();
  oversized_table.struct_size = sizeof(oversized_table) + 1u;
  config.presenter_ops = &oversized_table;
  FrameRenderer oversized_renderer(config);
  EXPECT_FALSE(oversized_renderer.valid());

  PlutoPresenterOps missing_hook = *mono_capture_ops();
  missing_hook.wait_idle = nullptr;
  config.presenter_ops = &missing_hook;
  FrameRenderer missing_hook_renderer(config);
  EXPECT_FALSE(missing_hook_renderer.valid());
}

TEST(FrameRendererTest, UnsupportedMandatoryPenFocusHookDoesNotBlockDetach) {
  reset_mono_capture();
  PlutoPresenterOps ops = *mono_capture_ops();
  ops.set_pen_focus = [](PlutoPresenter *, const PlutoPenFocus *) {
    return kPlutoStatusUnsupported;
  };
  FrameRendererConfig config = mono_capture_config();
  config.presenter_ops = &ops;
  config.presenter_pen_focus_from_host = true;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());
  EXPECT_TRUE(renderer.detach_presenter());
}

TEST(FrameRendererTest, WritesBoundedAtomicBmpPreview) {
  reset_mono_capture();
  FrameRenderer renderer(mono_capture_config());
  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  pixels[0] = 0xf800;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));

  const std::filesystem::path directory =
      std::filesystem::temp_directory_path() /
      ("pluto-preview-" + std::to_string(::getpid()));
  const std::filesystem::path preview = directory / "app.bmp";
  std::filesystem::remove_all(directory);
  ASSERT_TRUE(renderer.write_preview_bmp(preview.string(), 32));
  std::ifstream input(preview, std::ios::binary);
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(input)),
                             std::istreambuf_iterator<char>());
  ASSERT_TRUE(bytes.size() > 54u);
  EXPECT_EQ(bytes[0], static_cast<uint8_t>('B'));
  EXPECT_EQ(bytes[1], static_cast<uint8_t>('M'));
  const auto read_u32 = [&bytes](size_t offset) {
    return static_cast<uint32_t>(bytes[offset]) |
           (static_cast<uint32_t>(bytes[offset + 1]) << 8) |
           (static_cast<uint32_t>(bytes[offset + 2]) << 16) |
           (static_cast<uint32_t>(bytes[offset + 3]) << 24);
  };
  EXPECT_EQ(read_u32(18), 32u);
  EXPECT_EQ(read_u32(22), 32u);
  EXPECT_TRUE(std::find(bytes.begin() + 54, bytes.end(), 0xffu) != bytes.end());
  const auto [darkest, lightest] =
      std::minmax_element(bytes.begin() + 54, bytes.end());
  EXPECT_LT(*darkest, *lightest);
  EXPECT_TRUE(std::filesystem::exists(preview));
  std::filesystem::remove_all(directory);
}

TEST(FrameRendererTest, SnapshotRejectsBeforeRetainedContentIsReady) {
  reset_mono_capture();
  FrameRendererConfig config = mono_capture_config();
  config.width = 13;
  config.height = 7;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  RendererSnapshot untouched;
  untouched.width = 99;
  untouched.pixels = {1, 2, 3};
  EXPECT_FALSE(
      renderer.snapshot(RendererSnapshotSurface::kLogical, &untouched));
  renderer.notify_idle_frame();
  EXPECT_FALSE(
      renderer.snapshot(RendererSnapshotSurface::kPostDither, &untouched));
  EXPECT_EQ(untouched.width, 99u);
  ASSERT_EQ(untouched.pixels.size(), 3u);
  EXPECT_EQ(untouched.pixels[0], 1u);
  EXPECT_FALSE(renderer.snapshot(RendererSnapshotSurface::kLogical, nullptr));
}

TEST(FrameRendererTest, SnapshotCopiesDynamicLogicalAndPostDitherSurfaces) {
  constexpr uint32_t kWidth = 13;
  constexpr uint32_t kHeight = 7;
  constexpr size_t kSourceStridePixels = kWidth + 3;
  reset_mono_capture();
  FrameRendererConfig config = mono_capture_config();
  config.width = kWidth;
  config.height = kHeight;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> source(kSourceStridePixels * kHeight, 0x5aa5u);
  for (uint32_t y = 0; y < kHeight; ++y) {
    for (uint32_t x = 0; x < kWidth; ++x) {
      static constexpr uint16_t kColors[] = {0x0000u, 0xffffu, 0xf800u,
                                             0x07e0u, 0x001fu, 0x7befu};
      source[static_cast<size_t>(y) * kSourceStridePixels + x] =
          kColors[(x + 3u * y) % (sizeof(kColors) / sizeof(kColors[0]))];
    }
  }
  PlutoFramePacket packet{};
  packet.pixels = source.data();
  packet.row_bytes = kSourceStridePixels * sizeof(uint16_t);
  packet.width = kWidth;
  packet.height = kHeight;
  packet.format = kPlutoPixelFormatRgb565;
  packet.did_update = true;
  packet.presentation_time_ns = 1;
  ASSERT_TRUE(renderer.submit_frame(packet));

  RendererSnapshot logical;
  ASSERT_TRUE(renderer.snapshot(RendererSnapshotSurface::kLogical, &logical));
  EXPECT_EQ(logical.width, kWidth);
  EXPECT_EQ(logical.height, kHeight);
  EXPECT_EQ(logical.stride_bytes, kWidth * sizeof(uint16_t));
  EXPECT_EQ(logical.format, kPlutoPixelFormatRgb565);
  ASSERT_EQ(logical.pixels.size(), logical.stride_bytes * kHeight);
  for (uint32_t y = 0; y < kHeight; ++y) {
    for (uint32_t x = 0; x < kWidth; ++x) {
      uint16_t captured = 0;
      std::memcpy(&captured,
                  logical.pixels.data() +
                      static_cast<size_t>(y) * logical.stride_bytes +
                      static_cast<size_t>(x) * sizeof(captured),
                  sizeof(captured));
      EXPECT_EQ(captured,
                source[static_cast<size_t>(y) * kSourceStridePixels + x]);
    }
  }

  RendererSnapshot post_dither;
  ASSERT_TRUE(
      renderer.snapshot(RendererSnapshotSurface::kPostDither, &post_dither));
  EXPECT_EQ(post_dither.width, kWidth);
  EXPECT_EQ(post_dither.height, kHeight);
  EXPECT_EQ(post_dither.stride_bytes, static_cast<size_t>(kWidth));
  EXPECT_EQ(post_dither.format, kPlutoPixelFormatGray8);
  ASSERT_EQ(post_dither.pixels.size(), post_dither.stride_bytes * kHeight);
  for (uint32_t y = 0; y < kHeight; ++y) {
    for (uint32_t x = 0; x < kWidth; ++x) {
      const uint16_t pixel =
          source[static_cast<size_t>(y) * kSourceStridePixels + x];
      const uint8_t expected = pluto::quantize_gray16(
          pluto::rgb565_luma8(pixel),
          pluto::blue_noise_64_at(static_cast<int32_t>(x),
                                  static_cast<int32_t>(y)));
      EXPECT_EQ(
          post_dither
              .pixels[static_cast<size_t>(y) * post_dither.stride_bytes + x],
          expected);
    }
  }
}

TEST(FrameRendererTest, LogicalSnapshotPreservesLiveGray8Format) {
  constexpr uint32_t kWidth = 9;
  constexpr uint32_t kHeight = 5;
  constexpr size_t kSourceStride = kWidth + 3;
  reset_mono_capture();
  FrameRendererConfig config = mono_capture_config();
  config.width = kWidth;
  config.height = kHeight;
  config.format = kPlutoPixelFormatGray8;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint8_t> source(kSourceStride * kHeight, 0xa5u);
  for (uint32_t y = 0; y < kHeight; ++y) {
    for (uint32_t x = 0; x < kWidth; ++x) {
      source[static_cast<size_t>(y) * kSourceStride + x] =
          static_cast<uint8_t>(17u * ((x + y) % 16u));
    }
  }
  PlutoFramePacket packet{};
  packet.pixels = source.data();
  packet.row_bytes = kSourceStride;
  packet.width = kWidth;
  packet.height = kHeight;
  packet.format = kPlutoPixelFormatGray8;
  packet.did_update = true;
  packet.presentation_time_ns = 1;
  ASSERT_TRUE(renderer.submit_frame(packet));

  RendererSnapshot logical;
  ASSERT_TRUE(renderer.snapshot(RendererSnapshotSurface::kLogical, &logical));
  EXPECT_EQ(logical.width, kWidth);
  EXPECT_EQ(logical.height, kHeight);
  EXPECT_EQ(logical.stride_bytes, static_cast<size_t>(kWidth));
  EXPECT_EQ(logical.format, kPlutoPixelFormatGray8);
  ASSERT_EQ(logical.pixels.size(), logical.stride_bytes * kHeight);
  for (uint32_t y = 0; y < kHeight; ++y) {
    for (uint32_t x = 0; x < kWidth; ++x) {
      EXPECT_EQ(
          logical.pixels[static_cast<size_t>(y) * logical.stride_bytes + x],
          source[static_cast<size_t>(y) * kSourceStride + x]);
    }
  }
}

TEST(FrameRendererTest, DeferredSystemUiNeverPresentsTheStaleFrame) {
  reset_mono_capture();
  FrameRenderer renderer(mono_capture_config());
  renderer.set_presentation_suspended(true);

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    EXPECT_EQ(g_mono_capture.presents, 0u);
  }

  ASSERT_TRUE(renderer.arm_presentation_resume());
  PlutoFramePacket routed = packet_for(pixels, 64, 64, 2);
  routed.did_update = false;
  ASSERT_TRUE(renderer.submit_frame(routed));
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    EXPECT_GT(g_mono_capture.presents, 0u);
    EXPECT_EQ(g_mono_capture.last_class, kPlutoRefreshFull);
  }
}

TEST(FrameRendererTest,
     WarmReattachKeepsNativeReplayHiddenUntilSystemUiReveal) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.handoff_enabled = true;
  }
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0x7bef);
  pixels[0] = 0x0000;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));
  ASSERT_TRUE(wait_for_present_count(1));
  std::vector<uint16_t> expected_presented;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    expected_presented = g_mono_capture.pixel_history.back();
  }
  std::this_thread::sleep_for(std::chrono::milliseconds(80));
  ASSERT_TRUE(renderer.detach_presenter());

  // EngineHost arms this gate after reopening the presenter but before attach
  // when the warm launcher is about to route the switcher/status/power UI.
  renderer.set_presentation_suspended(true);
  ASSERT_TRUE(renderer.attach_presenter(
      mono_capture_ops(), reinterpret_cast<PlutoPresenter *>(&g_mono_capture)));
  std::this_thread::sleep_for(std::chrono::milliseconds(80));
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    EXPECT_EQ(g_mono_capture.presents, 1u)
        << "the retained Home replay must not flash before routing";
  }

  // The watchdog/routed reveal discards all hidden replay work and emits one
  // authoritative Full frame from the current retained surface.
  ASSERT_TRUE(renderer.force_presentation_resume());
  ASSERT_TRUE(wait_for_present_count(2));
  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  EXPECT_EQ(g_mono_capture.presents, 2u);
  EXPECT_EQ(g_mono_capture.last_class, kPlutoRefreshFull);
  EXPECT_TRUE(rect_equals(g_mono_capture.last_rect, PlutoRect{0, 0, 64, 64}));
  EXPECT_TRUE(g_mono_capture.last_pixels == expected_presented);
}

TEST(FrameRendererTest, DeferredSystemUiWatchdogCanForceCurrentFullFrame) {
  reset_mono_capture();
  FrameRenderer renderer(mono_capture_config());
  renderer.set_presentation_suspended(true);
  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1)));
  ASSERT_TRUE(renderer.force_presentation_resume());
  EXPECT_FALSE(renderer.presentation_suspended());
  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  EXPECT_EQ(g_mono_capture.last_class, kPlutoRefreshFull);
}

TEST(FrameRendererTest, ExplicitFullRefreshReplaysTheSettledWholeFrame) {
  reset_mono_capture();
  FrameRenderer renderer(mono_capture_config());
  ASSERT_TRUE(renderer.valid());
  EXPECT_FALSE(renderer.request_full_refresh());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  ASSERT_TRUE(renderer.request_full_refresh());

  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  ASSERT_EQ(g_mono_capture.presents, 2u);
  EXPECT_EQ(g_mono_capture.last_class, kPlutoRefreshFull);
  EXPECT_TRUE(rect_equals(g_mono_capture.last_rect, PlutoRect{0, 0, 64, 64}));
}

TEST(FrameRendererTest, PixelResetUsesFastBlinkBleachThenRestoresContent) {
  reset_mono_capture();
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0x8410);
  pixels[0] = 0x0000;
  pixels[1] = 0xffff;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));

  std::vector<uint16_t> expected;
  size_t before = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_TRUE(!g_mono_capture.pixel_history.empty());
    expected = g_mono_capture.pixel_history.back();
    before = g_mono_capture.pixel_history.size();
  }
  ASSERT_TRUE(renderer.request_pixel_reset());

  bool completed = false;
  for (int attempt = 0; attempt < 200; ++attempt) {
    {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      completed = g_mono_capture.pixel_history.size() >= before + 7;
    }
    if (completed) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  ASSERT_TRUE(completed);

  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  const size_t count = g_mono_capture.pixel_history.size();
  const std::vector<uint16_t> &black = g_mono_capture.pixel_history[count - 3];
  const std::vector<uint16_t> &white = g_mono_capture.pixel_history[count - 2];
  const std::vector<uint16_t> &restored =
      g_mono_capture.pixel_history[count - 1];
  EXPECT_TRUE(std::all_of(black.begin(), black.end(),
                          [](uint16_t px) { return px == 0x0000; }));
  EXPECT_TRUE(std::all_of(white.begin(), white.end(),
                          [](uint16_t px) { return px == 0xffff; }));
  EXPECT_TRUE(restored == expected);
  EXPECT_TRUE((g_mono_capture.flags_history[count - 3] &
               kPlutoPresentFlagPixelResetBlack) != 0u);
  EXPECT_TRUE((g_mono_capture.flags_history[count - 2] &
               kPlutoPresentFlagPixelResetWhite) != 0u);
  EXPECT_EQ(
      g_mono_capture.flags_history[count - 1] &
          (kPlutoPresentFlagPixelResetBlack | kPlutoPresentFlagPixelResetWhite),
      0u);
  EXPECT_NE(g_mono_capture.flags_history[count - 1] &
                kPlutoPresentFlagPixelResetRestore,
            0u);
  EXPECT_EQ(g_mono_capture.class_history[count - 1], kPlutoRefreshFull);
}

TEST(FrameRendererTest, SupportsEveryStockGhostControlModeWithFastRails) {
  struct Case {
    GhostControlMode mode;
    size_t expected_stages;
    bool deferred;
  };
  const Case cases[] = {
      {GhostControlMode::kBlinkNow, 7, false},
      {GhostControlMode::kBlinkLater, 7, true},
      {GhostControlMode::kBleachNow, 5, false},
      {GhostControlMode::kFactoryReset, 11, false},
  };

  for (const Case &test_case : cases) {
    reset_mono_capture();
    FrameRendererConfig config = mono_capture_config();
    config.start_presenter_thread = true;
    FrameRenderer renderer(config);
    ASSERT_TRUE(renderer.valid());
    std::vector<uint16_t> pixels(64 * 64, 0xffff);
    pixels[0] = 0x0000;
    ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));

    size_t before = 0;
    {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      before = g_mono_capture.pixel_history.size();
    }
    ASSERT_TRUE(renderer.request_ghost_control(test_case.mode));
    if (test_case.deferred) {
      std::this_thread::sleep_for(std::chrono::milliseconds(275));
      ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
    }

    bool completed = false;
    for (int attempt = 0; attempt < 1000; ++attempt) {
      {
        std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
        completed = g_mono_capture.pixel_history.size() >=
                    before + test_case.expected_stages;
      }
      if (completed) {
        break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    ASSERT_TRUE(completed);

    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    const size_t end = before + test_case.expected_stages;
    for (size_t i = before; i + 1 < end; ++i) {
      const uint32_t expected_flag = ((i - before) % 2 == 0)
                                         ? kPlutoPresentFlagPixelResetBlack
                                         : kPlutoPresentFlagPixelResetWhite;
      EXPECT_TRUE((g_mono_capture.flags_history[i] & expected_flag) != 0u);
    }
    EXPECT_EQ(g_mono_capture.flags_history[end - 1] &
                  (kPlutoPresentFlagPixelResetBlack |
                   kPlutoPresentFlagPixelResetWhite),
              0u);
    EXPECT_NE(g_mono_capture.flags_history[end - 1] &
                  kPlutoPresentFlagPixelResetRestore,
              0u);
    EXPECT_EQ(g_mono_capture.class_history[end - 1], kPlutoRefreshFull);
  }
}

TEST(FrameRendererTest, AutoGhostbusterRunsDistinctBlinkBleachAndBothPlans) {
  struct Case {
    uint16_t ghost_threshold;
    uint16_t pigment_threshold;
    bool pigment_supported;
    size_t expected_rail_and_restore_stages;
    bool balanced_restore;
  };
  const Case cases[] = {
      // Blink-only: black, white, one retained-content restore.
      {1, 0xffffu, false, 3, false},
      // Bleach-only: two black/white cycles and one restore.
      {0xffffu, 1, true, 5, true},
      // Both: one Blink plus two Bleach cycles, one shared restore.
      {1, 1, true, 7, true},
  };

  for (const Case &test_case : cases) {
    reset_mono_capture();
    std::atomic<size_t> holds{0};
    std::atomic<size_t> resumes{0};
    FrameRendererConfig config = mono_capture_config();
    config.start_presenter_thread = true;
    config.pigment_hygiene_supported = test_case.pigment_supported;
    config.auto_ghostbuster_config.ghost_tile_threshold_q8 =
        test_case.ghost_threshold;
    config.auto_ghostbuster_config.yellow_tile_threshold_q8 =
        test_case.pigment_threshold;
    config.auto_ghostbuster_config.ghost_display_percent = 1;
    config.auto_ghostbuster_config.yellow_display_percent = 1;
    config.auto_ghostbuster_config.ghost_low_water_percent = 0;
    config.auto_ghostbuster_config.yellow_low_water_percent = 0;
    config.auto_ghostbuster_config.damage_quiescence_us = 0;
    config.auto_ghostbuster_config.input_release_grace_us = 0;
    config.auto_ghostbuster_config.scan_cadence_us = 1;
    config.auto_ghostbuster_config.pigment_hygiene_supported =
        test_case.pigment_supported;
    config.set_flutter_rendering_paused = [&](bool paused) {
      (paused ? holds : resumes).fetch_add(1, std::memory_order_relaxed);
    };
    FrameRenderer renderer(config);
    ASSERT_TRUE(renderer.valid());

    std::vector<uint16_t> pixels(64 * 64, 0xffff);
    renderer.set_auto_maintenance_allowed(false);
    ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
    size_t before = 0;
    {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      before = g_mono_capture.pixel_history.size();
    }
    // One local pure-B/W change takes the Fast path and crosses the
    // deliberately tiny test threshold without relying on app semantics.
    for (int y = 8; y < 24; ++y) {
      for (int x = 8; x < 24; ++x) {
        pixels[static_cast<size_t>(y) * 64 + x] = 0x0000;
      }
    }
    ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
    ASSERT_TRUE(wait_for_present_count(before + 1));
    renderer.set_auto_maintenance_allowed(true);
    ASSERT_TRUE(wait_for_present_count(
        before + 1 + test_case.expected_rail_and_restore_stages));
    for (int attempt = 0;
         attempt < 200 && resumes.load(std::memory_order_relaxed) == 0;
         ++attempt) {
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    EXPECT_EQ(renderer.automatic_ghost_actions(), 1u);
    EXPECT_EQ(holds.load(std::memory_order_relaxed), 1u);
    EXPECT_EQ(resumes.load(std::memory_order_relaxed), 1u);
    {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      ASSERT_TRUE(!g_mono_capture.flags_history.empty());
      const bool marked = (g_mono_capture.flags_history.back() &
                           kPlutoPresentFlagPixelResetRestore) != 0;
      EXPECT_EQ(marked, test_case.balanced_restore);
      EXPECT_EQ(g_mono_capture.class_history.back(), test_case.balanced_restore
                                                         ? kPlutoRefreshFull
                                                         : kPlutoRefreshFast);
    }
  }
}

TEST(FrameRendererTest, AutoGhostbusterDefersExistingNeedUntilTouchRelease) {
  reset_mono_capture();
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  config.auto_ghostbuster_config.ghost_tile_threshold_q8 = 1;
  config.auto_ghostbuster_config.yellow_tile_threshold_q8 = 0xffffu;
  config.auto_ghostbuster_config.ghost_display_percent = 1;
  config.auto_ghostbuster_config.ghost_low_water_percent = 0;
  config.auto_ghostbuster_config.yellow_display_percent = 1;
  config.auto_ghostbuster_config.yellow_low_water_percent = 0;
  config.auto_ghostbuster_config.damage_quiescence_us = 0;
  config.auto_ghostbuster_config.input_release_grace_us = 20'000;
  config.auto_ghostbuster_config.scan_cadence_us = 1;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());
  // Arm the input gate before any asynchronous present can accrue debt. The
  // contract under test is that debt created while touch is active remains
  // deferred until release; setting touch after the baseline submit leaves a
  // scheduler race in which maintenance can legitimately start first.
  renderer.set_touch_active(true);

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  for (int y = 8; y < 24; ++y) {
    for (int x = 8; x < 24; ++x) {
      pixels[static_cast<size_t>(y) * 64 + x] = 0x0000;
    }
  }
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
  std::this_thread::sleep_for(std::chrono::milliseconds(40));
  EXPECT_EQ(renderer.automatic_ghost_actions(), 0u);

  renderer.set_touch_active(false);
  for (int attempt = 0;
       attempt < 200 && renderer.automatic_ghost_actions() == 0; ++attempt) {
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  EXPECT_EQ(renderer.automatic_ghost_actions(), 1u);
}

TEST(FrameRendererTest, InputReleaseWithoutDebtNeverStartsMaintenance) {
  reset_mono_capture();
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  config.auto_ghostbuster_config.input_release_grace_us = 0;
  config.auto_ghostbuster_config.scan_cadence_us = 1;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());
  renderer.set_touch_active(true);
  renderer.set_touch_active(false);
  renderer.set_pen_active(true);
  renderer.set_pen_active(false);
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  EXPECT_EQ(renderer.automatic_ghost_actions(), 0u);
}

TEST(FrameRendererTest, FailedPresentDoesNotPublishReadyMarker) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.present_status = kPlutoStatusInternal;
  }
  TempReadyMarker ready("failed-present");
  FrameRendererConfig config = mono_capture_config();
  config.ready_file_path = ready.marker().string();
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  EXPECT_FALSE(std::filesystem::exists(ready.marker()));
}

TEST(FrameRendererTest, DeviceLostPresentRequestsFatalShutdownExactlyOnce) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.present_status = kPlutoStatusDeviceLost;
  }
  std::atomic<size_t> fatal_callbacks{0};
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  config.on_presenter_device_lost = [&fatal_callbacks] {
    fatal_callbacks.fetch_add(1, std::memory_order_acq_rel);
  };
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (fatal_callbacks.load(std::memory_order_acquire) == 0u &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  EXPECT_EQ(fatal_callbacks.load(std::memory_order_acquire), 1u);
  std::this_thread::sleep_for(std::chrono::milliseconds(350));
  EXPECT_EQ(fatal_callbacks.load(std::memory_order_acquire), 1u);
}

TEST(FrameRendererTest,
     AsyncPresenterFaultRequestsFatalShutdownWithoutAnotherPresent) {
  reset_mono_capture();
  std::atomic<size_t> fatal_callbacks{0};
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  config.on_presenter_device_lost = [&fatal_callbacks] {
    fatal_callbacks.fetch_add(1, std::memory_order_acq_rel);
  };
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.wait_idle_status = kPlutoStatusDeviceLost;
  }

  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (fatal_callbacks.load(std::memory_order_acquire) == 0u &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  EXPECT_EQ(fatal_callbacks.load(std::memory_order_acquire), 1u);
  std::this_thread::sleep_for(std::chrono::milliseconds(350));
  EXPECT_EQ(fatal_callbacks.load(std::memory_order_acquire), 1u);
}

TEST(FrameRendererTest, FirstSuccessfulPresentPublishesReadyMarkerOnce) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.present_status = kPlutoStatusInternal;
  }
  TempReadyMarker ready("first-success");
  FrameRendererConfig config = mono_capture_config();
  config.ready_file_path = ready.marker().string();
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  ASSERT_TRUE(!std::filesystem::exists(ready.marker()));

  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.present_status = kPlutoStatusOk;
  }
  std::fill(pixels.begin(), pixels.end(), 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
  ASSERT_TRUE(std::filesystem::exists(ready.marker()));
  EXPECT_EQ(read_file(ready.marker()), "ready\n");

  // A later accepted present must not republish or replace the marker.
  std::ofstream(ready.marker(), std::ios::trunc) << "owned-by-observer\n";
  std::fill(pixels.begin(), pixels.end(), 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 3000)));
  EXPECT_EQ(read_file(ready.marker()), "owned-by-observer\n");
}

TEST(FrameRendererTest,
     HealthStartsAfterRealCompletionAndAdvancesWhileUiIsStatic) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.reports_completion = true;
  }
  TempReadyMarker health("health-cadence");
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  config.health_file_path = health.marker().string();
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  uint64_t frame_id = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_TRUE(!g_mono_capture.frame_id_history.empty());
    frame_id = g_mono_capture.frame_id_history.back();
  }

  // Presenter acceptance alone is not enough to arm liveness.
  std::this_thread::sleep_for(std::chrono::milliseconds(350));
  EXPECT_FALSE(std::filesystem::exists(health.marker()));
  renderer.notify_present_complete(frame_id);

  ParsedHealthRecord first{};
  const auto first_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (std::chrono::steady_clock::now() < first_deadline) {
    if (std::filesystem::exists(health.marker()) &&
        parse_health_record(read_file(health.marker()), &first)) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  ASSERT_EQ(first.pid, static_cast<long>(::getpid()));
  ASSERT_EQ(first.sequence, 1u);

  // No more Flutter frames or presenter completions are supplied. The same
  // renderer/presenter-loop health tick must still advance the record.
  ParsedHealthRecord later{};
  const auto cadence_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (std::chrono::steady_clock::now() < cadence_deadline) {
    if (parse_health_record(read_file(health.marker()), &later) &&
        later.sequence > first.sequence) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  EXPECT_GT(later.sequence, first.sequence);
  EXPECT_GE(later.monotonic_ms, first.monotonic_ms);
}

TEST(FrameRendererTest,
     HealthDoesNotAdvanceOnPermanentBusyWithoutCompletionProgress) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.reports_completion = true;
    g_mono_capture.wait_idle_status = kPlutoStatusTimeout;
  }
  TempReadyMarker health("health-busy");
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  config.health_file_path = health.marker().string();
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  uint64_t frame_id = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_TRUE(!g_mono_capture.frame_id_history.empty());
    frame_id = g_mono_capture.frame_id_history.back();
  }
  renderer.notify_present_complete(frame_id);

  ParsedHealthRecord first{};
  const auto first_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (std::chrono::steady_clock::now() < first_deadline) {
    if (parse_health_record(read_file(health.marker()), &first)) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  ASSERT_EQ(first.sequence, 1u);

  std::this_thread::sleep_for(std::chrono::milliseconds(1250));
  ParsedHealthRecord stalled{};
  ASSERT_TRUE(parse_health_record(read_file(health.marker()), &stalled));
  EXPECT_EQ(stalled.sequence, first.sequence);

  // Leave the fake presenter internally consistent for renderer teardown.
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.wait_idle_status = kPlutoStatusOk;
  }
}

TEST(FrameRendererTest, MissingRealCompletionTriggersFatalHealthDeadline) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.reports_completion = true;
  }
  TempReadyMarker health("health-overdue");
  std::atomic<size_t> fatal_callbacks{0};
  std::atomic<uint64_t> now_us{1'000'000};
  const pluto::RegionSchedulerConfig scheduler_defaults{};
  ASSERT_EQ(scheduler_defaults.fence_timeout_ms, 5500u);
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  config.health_file_path = health.marker().string();
  config.on_health_file_failure = [&fatal_callbacks] {
    fatal_callbacks.fetch_add(1, std::memory_order_release);
  };
  config.monotonic_now_for_testing = [](void *context) {
    return static_cast<std::atomic<uint64_t> *>(context)->load(
        std::memory_order_acquire);
  };
  config.monotonic_now_context_for_testing = &now_us;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  now_us.fetch_add(
      static_cast<uint64_t>(scheduler_defaults.fence_timeout_ms) * 1000u + 1u,
      std::memory_order_release);
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (fatal_callbacks.load(std::memory_order_acquire) == 0u &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  EXPECT_EQ(fatal_callbacks.load(std::memory_order_acquire), 1u);
  EXPECT_FALSE(renderer.valid());
  EXPECT_FALSE(std::filesystem::exists(health.marker()));
}

TEST(FrameRendererTest, HealthPublicationFailureRequestsFatalShutdownOnce) {
  reset_mono_capture();
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.reports_completion = true;
  }
  TempReadyMarker health("health-failure");
  const auto missing_path =
      health.marker().parent_path() / "missing" / "health";
  std::atomic<size_t> fatal_callbacks{0};
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  config.health_file_path = missing_path.string();
  config.on_health_file_failure = [&fatal_callbacks] {
    fatal_callbacks.fetch_add(1, std::memory_order_release);
  };
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  uint64_t frame_id = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_TRUE(!g_mono_capture.frame_id_history.empty());
    frame_id = g_mono_capture.frame_id_history.back();
  }
  renderer.notify_present_complete(frame_id);

  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (fatal_callbacks.load(std::memory_order_acquire) == 0u &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  EXPECT_EQ(fatal_callbacks.load(std::memory_order_acquire), 1u);
  EXPECT_FALSE(renderer.valid());
  EXPECT_FALSE(std::filesystem::exists(missing_path));
  std::this_thread::sleep_for(std::chrono::milliseconds(350));
  EXPECT_EQ(fatal_callbacks.load(std::memory_order_acquire), 1u);
}

TEST(FrameRendererTest, HealthRequiresCompletionCapablePresenterLoop) {
  reset_mono_capture();
  TempReadyMarker health("health-capabilities");
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  config.health_file_path = health.marker().string();

  FrameRenderer renderer(config);
  EXPECT_FALSE(renderer.valid());
  EXPECT_FALSE(std::filesystem::exists(health.marker()));
}

TEST(FrameRendererTest, EmptyReadyPathLeavesPresentBehaviorUnchanged) {
  reset_mono_capture();
  FrameRendererConfig config = mono_capture_config();
  ASSERT_TRUE(config.ready_file_path.empty());
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  EXPECT_EQ(g_mono_capture.presents, 1u);
}

// The scheduler is fed exact post-quantize rects (no alignment padding).
// With rect_alignment=1 the presented rect IS the exact damage: the old
// +4/+8 scheduler dilation died with the GuardBandPackager cutover (the
// guard fringe is null-band geometry in the package, not presented area).
TEST(FrameRendererTest, SchedulerSeesExactPostQuantizeRects) {
  reset_mono_capture();
  FrameRenderer renderer(mono_capture_config());
  ASSERT_TRUE(renderer.valid());
  std::vector<uint16_t> pixels(64 * 64, 0xffff); // white
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));

  // Unaligned 6x6 black square at (41, 9).
  for (int32_t y = 9; y < 15; ++y) {
    for (int32_t x = 41; x < 47; ++x) {
      pixels[y * 64 + x] = 0x0000;
    }
  }
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
  EXPECT_EQ(renderer.last_damage_count(), 1u);

  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  ASSERT_EQ(g_mono_capture.presents, 2u);
  EXPECT_TRUE(rect_equals(g_mono_capture.last_rect, PlutoRect{41, 9, 6, 6}))
      << "rect [" << g_mono_capture.last_rect.x << ","
      << g_mono_capture.last_rect.y << " " << g_mono_capture.last_rect.width
      << "x" << g_mono_capture.last_rect.height << "]";
}

// PreDithered semantics on a mono panel: presented content is quantized for
// glass (16-level gray in RGB565) and flagged. The bytes come from the
// ledger's settled levels, not a dispatch re-quantization.
TEST(FrameRendererTest, PreDitheredSetAndGray16OnMonoPanel) {
  reset_mono_capture();
  FrameRenderer renderer(mono_capture_config());
  ASSERT_TRUE(renderer.valid());
  // Saturated red: no gray pipeline may pass it through unquantized.
  std::vector<uint16_t> pixels(64 * 64, 0xf800);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));

  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  ASSERT_EQ(g_mono_capture.presents, 1u);
  EXPECT_TRUE((g_mono_capture.last_flags & kPlutoPresentFlagPreDithered) != 0u);
  const PlutoRect rect = g_mono_capture.last_rect;
  for (int32_t y = rect.y; y < rect.y + rect.height; ++y) {
    for (int32_t x = rect.x; x < rect.x + rect.width; ++x) {
      ASSERT_TRUE(is_gray16_rgb565(g_mono_capture.last_pixels[y * 64 + x]))
          << "x=" << x << " y=" << y
          << " px=" << g_mono_capture.last_pixels[y * 64 + x];
    }
  }
}

// Color-panel contracts: sub-Full content reaches the glass
// chroma-free with PreDithered set; the chroma-pending tiles settle as a
// Full-class update whose delegated raw RGB keeps PreDithered UNSET
// (backend_quantizes_color -- the presenter must receive raw RGB).
struct ColorCapture {
  std::mutex mutex;
  struct Record {
    PlutoRefreshClass refresh_class = kPlutoRefreshUi;
    uint32_t flags = 0;
    uint64_t frame_id = 0;
    PlutoRect rect{0, 0, 0, 0};
    std::vector<uint16_t> pixels;
  };
  std::vector<Record> records;
};
ColorCapture g_color_capture;

const PlutoPresenterOps *color_capture_ops() {
  static PlutoPresenterOps ops = [] {
    PlutoPresenterOps o =
        pluto::test::current_test_presenter_ops("color-capture");
    o.info = [](PlutoPresenter *, PlutoDisplayInfo *out_info) {
      PlutoDisplayInfo info{};
      info.struct_size = sizeof(info);
      info.width = 64;
      info.height = 64;
      info.dpi = 264;
      info.preferred_format = kPlutoPixelFormatRgb565;
      info.is_color = true;
      info.backend_quantizes_color = true;
      info.supports_overlap_supersession = true;
      info.rect_alignment = 8;
      for (int i = 0; i < 4; ++i) {
        info.nominal_latency_ms[i] = 0;
      }
      *out_info = info;
      return kPlutoStatusOk;
    };
    o.present = [](PlutoPresenter *, const PlutoPresentRequest *request) {
      std::lock_guard<std::mutex> lock(g_color_capture.mutex);
      ColorCapture::Record record;
      record.refresh_class = request->refresh_class;
      record.flags = request->flags;
      record.frame_id = request->frame_id;
      record.rect = request->damage[0];
      const auto *px =
          reinterpret_cast<const uint16_t *>(request->surface.pixels);
      record.pixels.assign(px, px + 64 * 64);
      g_color_capture.records.push_back(record);
      return kPlutoStatusOk;
    };
    o.ready = [](PlutoPresenter *, PlutoRefreshClass) { return true; };
    return o;
  }();
  return &ops;
}

TEST(FrameRendererTest, ColorPanelCrushesSubFullAndDelegatesFull) {
  {
    std::lock_guard<std::mutex> lock(g_color_capture.mutex);
    g_color_capture.records.clear();
  }
  FrameRendererConfig config{};
  config.width = 64;
  config.height = 64;
  config.format = kPlutoPixelFormatRgb565;
  // The presenter loop must run: the chroma settle fires on an idle tick.
  config.start_presenter_thread = true;
  config.presenter_ops = color_capture_ops();
  config.presenter = reinterpret_cast<PlutoPresenter *>(&g_color_capture);
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  // Frame 1: all white (first-frame damage covers the surface and promotes
  // to a structural Full; its delegated copy is white).
  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 0)));

  // Frame 2: a small saturated-red square -- small enough to stay sub-Full,
  // so its chroma is crushed on glass and left pending for the settle.
  for (int32_t y = 8; y < 24; ++y) {
    for (int32_t x = 8; x < 24; ++x) {
      pixels[y * 64 + x] = 0xf800;
    }
  }
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 0)));
  EXPECT_GT(renderer.chroma_marked_tiles(), 0u);

  // Wait for the chroma settle: a Full-class present whose delegated raw RGB
  // carries the red square.
  bool saw_red_full = false;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (!saw_red_full && std::chrono::steady_clock::now() < deadline) {
    {
      std::lock_guard<std::mutex> lock(g_color_capture.mutex);
      for (const ColorCapture::Record &record : g_color_capture.records) {
        if (record.refresh_class == kPlutoRefreshFull &&
            record.pixels[10 * 64 + 10] == 0xf800u) {
          saw_red_full = true;
        }
      }
    }
    if (!saw_red_full) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
  }
  renderer.shutdown();
  ASSERT_TRUE(saw_red_full);

  std::lock_guard<std::mutex> lock(g_color_capture.mutex);
  ASSERT_TRUE(g_color_capture.records.size() >= 2u);
  bool saw_sub_full = false;
  for (const ColorCapture::Record &record : g_color_capture.records) {
    if (record.refresh_class == kPlutoRefreshFull) {
      // Delegated settled color: raw RGB from the mirror, flag UNSET.
      EXPECT_EQ(record.flags & kPlutoPresentFlagPreDithered, 0u);
      continue;
    }
    // Sub-Full: chroma crushed to settled 16-gray, flag set.
    saw_sub_full = true;
    EXPECT_TRUE((record.flags & kPlutoPresentFlagPreDithered) != 0u);
    const PlutoRect rect = record.rect;
    for (int32_t y = rect.y; y < rect.y + rect.height; ++y) {
      for (int32_t x = rect.x; x < rect.x + rect.width; ++x) {
        ASSERT_TRUE(is_gray16_rgb565(record.pixels[y * 64 + x]))
            << "x=" << x << " y=" << y << " px=" << record.pixels[y * 64 + x];
      }
    }
  }
  EXPECT_TRUE(saw_sub_full);
  // The red-carrying Full present: raw red inside the square, raw white
  // outside it -- never palette-crushed, never gray.
  for (const ColorCapture::Record &record : g_color_capture.records) {
    if (record.refresh_class != kPlutoRefreshFull ||
        record.pixels[10 * 64 + 10] != 0xf800u) {
      continue;
    }
    for (int32_t y = 8; y < 24; ++y) {
      for (int32_t x = 8; x < 24; ++x) {
        ASSERT_EQ(record.pixels[y * 64 + x], 0xf800u)
            << "x=" << x << " y=" << y;
      }
    }
    EXPECT_EQ(record.pixels[40 * 64 + 40], 0xffffu);
  }
}

// ---- pen-aware app-damage path -------------------------------------------
// A per-present recording presenter: mono e-ink shape,
// rect_alignment=1, zero nominal latency (synthetic completions land on the
// next tick), no presenter thread. Pen hints alone never reach this seam.
struct InkCapture {
  std::mutex mutex;
  struct Record {
    PlutoRefreshClass refresh_class = kPlutoRefreshUi;
    uint32_t flags = 0;
    uint64_t frame_id = 0;
    PlutoRect rect{0, 0, 0, 0};
    std::vector<PlutoRect> rects;
    std::vector<uint16_t> pixels; // full 64x64 surface snapshot
  };
  std::vector<Record> records;
};
InkCapture g_ink_capture;

const PlutoPresenterOps *ink_capture_ops() {
  static PlutoPresenterOps ops = [] {
    PlutoPresenterOps o =
        pluto::test::current_test_presenter_ops("ink-capture");
    o.info = [](PlutoPresenter *, PlutoDisplayInfo *out_info) {
      PlutoDisplayInfo info{};
      info.struct_size = sizeof(info);
      info.width = 64;
      info.height = 64;
      info.dpi = 264;
      info.preferred_format = kPlutoPixelFormatRgb565;
      info.is_color = false;
      info.wants_pre_dithered = true;
      info.backend_quantizes_color = false;
      info.rect_alignment = 1;
      for (int i = 0; i < 4; ++i) {
        info.nominal_latency_ms[i] = 0;
      }
      *out_info = info;
      return kPlutoStatusOk;
    };
    o.present = [](PlutoPresenter *, const PlutoPresentRequest *request) {
      std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
      InkCapture::Record record;
      record.refresh_class = request->refresh_class;
      record.flags = request->flags;
      record.frame_id = request->frame_id;
      record.rect = request->damage[0];
      record.rects.assign(request->damage,
                          request->damage + request->damage_count);
      const auto *px =
          reinterpret_cast<const uint16_t *>(request->surface.pixels);
      record.pixels.assign(px, px + 64 * 64);
      g_ink_capture.records.push_back(std::move(record));
      return kPlutoStatusOk;
    };
    o.ready = [](PlutoPresenter *, PlutoRefreshClass) { return true; };
    return o;
  }();
  return &ops;
}

FrameRendererConfig ink_capture_config() {
  FrameRendererConfig config{};
  config.width = 64;
  config.height = 64;
  config.format = kPlutoPixelFormatRgb565;
  config.start_presenter_thread = false;
  config.presenter_ops = ink_capture_ops();
  config.presenter = reinterpret_cast<PlutoPresenter *>(&g_ink_capture);
  config.renderer_config.pen_hover_radius_px = 6;
  config.renderer_config.pen_contact_radius_px = 4;
  config.renderer_config.pen_max_preview_area_percent = 25;
  return config;
}

InkCapture g_exact_focus_capture;

const PlutoPresenterOps *exact_focus_capture_ops() {
  static PlutoPresenterOps ops = [] {
    PlutoPresenterOps o =
        pluto::test::current_test_presenter_ops("exact-focus-capture");
    o.info = [](PlutoPresenter *, PlutoDisplayInfo *out_info) {
      PlutoDisplayInfo info{};
      info.struct_size = sizeof(info);
      info.width = 64;
      info.height = 64;
      info.dpi = 264;
      info.preferred_format = kPlutoPixelFormatRgb565;
      info.is_color = true;
      info.backend_quantizes_color = true;
      info.supports_overlap_supersession = false;
      info.reports_completion = true;
      info.rect_alignment = 8;
      for (int i = 0; i < 4; ++i) {
        info.nominal_latency_ms[i] = 0;
      }
      *out_info = info;
      return kPlutoStatusOk;
    };
    o.present = [](PlutoPresenter *, const PlutoPresentRequest *request) {
      std::lock_guard<std::mutex> lock(g_exact_focus_capture.mutex);
      InkCapture::Record record;
      record.refresh_class = request->refresh_class;
      record.flags = request->flags;
      record.frame_id = request->frame_id;
      record.rect = request->damage[0];
      record.rects.assign(request->damage,
                          request->damage + request->damage_count);
      g_exact_focus_capture.records.push_back(std::move(record));
      return kPlutoStatusOk;
    };
    o.ready = [](PlutoPresenter *, PlutoRefreshClass) { return true; };
    return o;
  }();
  return &ops;
}

FrameRendererConfig exact_focus_capture_config() {
  FrameRendererConfig config = ink_capture_config();
  config.presenter_ops = exact_focus_capture_ops();
  config.presenter = reinterpret_cast<PlutoPresenter *>(&g_exact_focus_capture);
  return config;
}

PenRenderHintSnapshot pen_hint_at(int32_t x, int32_t y, bool contact,
                                  uint64_t sequence) {
  PenRenderHintSnapshot hint;
  hint.in_range = true;
  hint.contact = contact;
  hint.previous_x = x - 2;
  hint.previous_y = y;
  hint.current_x = x;
  hint.current_y = y;
  hint.predicted_x = x + 3;
  hint.predicted_y = y;
  hint.sequence = sequence;
  return hint;
}

PenRenderHintSnapshot terminal_pen_hint_at(int32_t x, int32_t y,
                                           uint64_t sequence) {
  PenRenderHintSnapshot hint = pen_hint_at(x, y, /*contact=*/false, sequence);
  hint.in_range = false;
  hint.previous_x = x;
  hint.previous_y = y;
  hint.predicted_x = x;
  hint.predicted_y = y;
  return hint;
}

TEST(FrameRendererTest,
     PresenterPenFocusUsesPhysicalRotationAndClearsOnRangeExit) {
  struct RotationCase {
    uint32_t rotation;
    PlutoRect expected;
  };
  // The configured hover focus for pen_hint_at(20,24) is logical
  // {12,18,18,13}. These are RegionScheduler::presenter_rect's exact results
  // over a deliberately non-square 80x64 logical domain.
  const RotationCase cases[] = {
      {0, {12, 18, 18, 13}},
      {90, {33, 12, 13, 18}},
      {180, {50, 33, 18, 13}},
      {270, {18, 50, 13, 18}},
  };
  for (const RotationCase &test : cases) {
    reset_mono_capture();
    FrameRendererConfig config = mono_capture_config();
    config.width = 80;
    config.height = 64;
    config.rotation = test.rotation;
    config.renderer_config.pen_hover_radius_px = 4;
    config.renderer_config.pen_contact_radius_px = 3;
    FrameRenderer renderer(config);
    ASSERT_TRUE(renderer.valid());
    renderer.note_pen_render_hint(pen_hint_at(20, 24, /*contact=*/false, 1));
    std::vector<uint16_t> pixels(80u * 64u, 0xffffu);
    ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 80, 64, 1000)));
    {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      ASSERT_TRUE(!g_mono_capture.pen_focus_history.empty());
      const PlutoPenFocus &focus = g_mono_capture.pen_focus_history.front();
      EXPECT_EQ(focus.flags, kPlutoPenFocusInRange);
      EXPECT_TRUE(rect_equals(focus.rect, test.expected));
      EXPECT_EQ(focus.sequence, 1u);
    }

    renderer.note_pen_render_hint(terminal_pen_hint_at(20, 24, 2));
    pixels[63u * 80u + 79u] = 0u;
    ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 80, 64, 2000)));
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_GE(g_mono_capture.pen_focus_history.size(), 2u);
    EXPECT_EQ(g_mono_capture.pen_focus_history.back().flags, kPlutoPenFocusNone)
        << "rotation=" << test.rotation;
  }
}

TEST(FrameRendererTest,
     RotationAndDetachFailClosedWhenPresenterFocusClearFails) {
  reset_mono_capture();
  FrameRenderer renderer(mono_capture_config());
  ASSERT_TRUE(renderer.valid());
  renderer.note_pen_render_hint(pen_hint_at(20, 20, false, 1));
  std::vector<uint16_t> pixels(64u * 64u, 0xffffu);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  size_t health_poll_waits = 0;
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_TRUE(!g_mono_capture.pen_focus_history.empty());
    g_mono_capture.pen_focus_status = kPlutoStatusInternal;
    health_poll_waits = g_mono_capture.wait_idle_calls;
  }
  EXPECT_FALSE(renderer.set_rotation(90, 64, 64));
  EXPECT_FALSE(renderer.detach_presenter(10));
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    EXPECT_EQ(g_mono_capture.wait_idle_calls, health_poll_waits)
        << "lifecycle must not fence behind an uncleared backend focus";
    g_mono_capture.pen_focus_status = kPlutoStatusOk;
  }
  EXPECT_TRUE(renderer.detach_presenter(1000));
}

TEST(FrameRendererTest, TransientAsynchronousPenFocusClearIsRetried) {
  reset_mono_capture();
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = true;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());
  renderer.note_pen_render_hint(pen_hint_at(20, 20, false, 1));

  const auto active_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(1);
  for (;;) {
    {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      if (!g_mono_capture.pen_focus_history.empty() &&
          (g_mono_capture.pen_focus_history.back().flags &
           kPlutoPenFocusInRange) != 0) {
        g_mono_capture.pen_focus_failures_before_ok = 1;
        break;
      }
    }
    ASSERT_TRUE(std::chrono::steady_clock::now() < active_deadline);
    std::this_thread::yield();
  }

  renderer.note_pen_render_hint(terminal_pen_hint_at(20, 20, 2));
  const auto clear_deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(1);
  size_t clear_attempts = 0;
  for (;;) {
    {
      std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
      clear_attempts = static_cast<size_t>(
          std::count_if(g_mono_capture.pen_focus_history.begin(),
                        g_mono_capture.pen_focus_history.end(),
                        [](const PlutoPenFocus &focus) {
                          return focus.flags == kPlutoPenFocusNone;
                        }));
      if (clear_attempts >= 2u) {
        break;
      }
    }
    ASSERT_TRUE(std::chrono::steady_clock::now() < clear_deadline);
    std::this_thread::yield();
  }
  EXPECT_GE(clear_attempts, 2u);
}

TEST(FrameRendererTest, ActivePresenterFocusIsClearedBeforeAutoReconfigure) {
  reset_mono_capture();
  FrameRenderer renderer(mono_capture_config());
  ASSERT_TRUE(renderer.valid());
  renderer.note_pen_render_hint(pen_hint_at(20, 20, false, 1));
  std::vector<uint16_t> pixels(64u * 64u, 0xffffu);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    ASSERT_TRUE(!g_mono_capture.pen_focus_history.empty());
    ASSERT_TRUE((g_mono_capture.pen_focus_history.back().flags &
                 kPlutoPenFocusInRange) != 0);
  }

  std::vector<uint16_t> resized(80u * 64u, 0xffffu);
  ASSERT_TRUE(renderer.submit_frame(packet_for(resized, 80, 64, 2000)));
  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  ASSERT_GE(g_mono_capture.pen_focus_history.size(), 2u);
  EXPECT_EQ(g_mono_capture.pen_focus_history.back().flags, kPlutoPenFocusNone);
}

void fill_rect(std::vector<uint16_t> *pixels, const PlutoRect &rect,
               uint16_t value) {
  for (int32_t y = rect.y; y < rect.y + rect.height; ++y) {
    for (int32_t x = rect.x; x < rect.x + rect.width; ++x) {
      (*pixels)[static_cast<size_t>(y) * 64 + x] = value;
    }
  }
}

TEST(FrameRendererTest, PenHintAloneNeverPresentsOrChangesContent) {
  {
    std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
    g_ink_capture.records.clear();
  }
  FrameRenderer renderer(ink_capture_config());
  ASSERT_TRUE(renderer.valid());
  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  for (uint64_t i = 1; i <= 100; ++i) {
    renderer.note_pen_render_hint(pen_hint_at(10 + static_cast<int32_t>(i % 20),
                                              20,
                                              /*contact=*/i > 20, i));
  }
  EXPECT_EQ(renderer.pen_priority_regions(), 0u);
  std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
  ASSERT_EQ(g_ink_capture.records.size(), 1u);
  for (uint16_t pixel : g_ink_capture.records[0].pixels) {
    EXPECT_EQ(pixel, 0xffffu);
  }
}

TEST(FrameRendererTest, StationaryHighRateHoverCoalescesReservationWakes) {
  FrameRenderer renderer(ink_capture_config());
  ASSERT_TRUE(renderer.valid());
  for (uint64_t sequence = 1; sequence <= 200; ++sequence) {
    renderer.note_pen_render_hint(
        pen_hint_at(24, 24, /*contact=*/false, sequence));
  }
  EXPECT_EQ(renderer.pen_focus_wakes(), 1u)
      << "stationary 200 Hz input must not drive a 200 Hz renderer tick";
  renderer.note_pen_render_hint(terminal_pen_hint_at(24, 24, 201));
  EXPECT_EQ(renderer.pen_focus_wakes(), 2u)
      << "range exit must wake once to arm the terminal focus lease";
  EXPECT_EQ(renderer.pen_priority_regions(), 0u);
}

TEST(FrameRendererTest,
     StickyActiveFocusSurvivesLeaseIntervalAndTerminalFocusExpires) {
  {
    std::lock_guard<std::mutex> lock(g_exact_focus_capture.mutex);
    g_exact_focus_capture.records.clear();
  }
  FrameRenderer renderer(exact_focus_capture_config());
  ASSERT_TRUE(renderer.valid());
  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  uint64_t initial_frame = 0;
  {
    std::lock_guard<std::mutex> lock(g_exact_focus_capture.mutex);
    ASSERT_EQ(g_exact_focus_capture.records.size(), 1u);
    initial_frame = g_exact_focus_capture.records[0].frame_id;
  }
  renderer.notify_present_complete(initial_frame);

  renderer.note_pen_render_hint(pen_hint_at(18, 18, false, 1));
  fill_rect(&pixels, PlutoRect{16, 16, 4, 4}, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
  uint64_t preview_frame = 0;
  {
    std::lock_guard<std::mutex> lock(g_exact_focus_capture.mutex);
    for (const InkCapture::Record &record : g_exact_focus_capture.records) {
      if ((record.flags & kPlutoPresentFlagInkPriority) != 0) {
        preview_frame = record.frame_id;
      }
      EXPECT_EQ(record.flags & kPlutoPresentFlagPenTruth, 0u);
    }
  }
  ASSERT_NE(preview_frame, 0u);
  renderer.notify_present_complete(preview_frame);

  // No new digitizer sample arrives. The mailbox's sticky active hover must
  // still prevent a completion-only mapped truth start after the 24 ms tail
  // used exclusively by terminal focus.
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  pixels[63 * 64 + 63] = 0x0000;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 3000)));
  {
    std::lock_guard<std::mutex> lock(g_exact_focus_capture.mutex);
    for (const InkCapture::Record &record : g_exact_focus_capture.records) {
      EXPECT_EQ(record.flags & kPlutoPresentFlagPenTruth, 0u);
    }
  }

  renderer.note_pen_render_hint(terminal_pen_hint_at(18, 18, 2));
  pixels[62 * 64 + 63] = 0x0000;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 4000)));
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  pixels[61 * 64 + 63] = 0x0000;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 5000)));
  bool saw_truth = false;
  {
    std::lock_guard<std::mutex> lock(g_exact_focus_capture.mutex);
    for (const InkCapture::Record &record : g_exact_focus_capture.records) {
      saw_truth = saw_truth || (record.flags & kPlutoPresentFlagPenTruth) != 0;
    }
  }
  EXPECT_TRUE(saw_truth)
      << "terminal focus did not expire after its 24 ms tail";
}

TEST(PenRenderHintMailboxTest, ConcurrentSnapshotsNeverMixGenerations) {
  PenRenderHintMailbox mailbox;
  std::atomic<bool> writer_done{false};
  std::atomic<bool> clearer_done{false};
  constexpr uint64_t kGenerations = 50'000;

  auto hint_for = [](uint64_t sequence) {
    PenRenderHintSnapshot hint;
    hint.timestamp_us = static_cast<int64_t>(sequence * 1000 + 7);
    hint.in_range = true;
    hint.contact = (sequence & 1u) != 0;
    hint.previous_x = static_cast<int32_t>(sequence * 4 + 1);
    hint.previous_y = -static_cast<int32_t>(sequence * 4 + 2);
    hint.current_x = static_cast<int32_t>(sequence * 4 + 3);
    hint.current_y = -static_cast<int32_t>(sequence * 4 + 4);
    hint.predicted_x = static_cast<int32_t>(sequence * 4 + 5);
    hint.predicted_y = -static_cast<int32_t>(sequence * 4 + 6);
    hint.sequence = sequence;
    return hint;
  };
  auto coherent = [&](const PenRenderHintSnapshot &hint) {
    const uint64_t sequence = hint.sequence;
    return sequence != 0 &&
           hint.timestamp_us == static_cast<int64_t>(sequence * 1000 + 7) &&
           hint.in_range && hint.contact == ((sequence & 1u) != 0) &&
           hint.previous_x == static_cast<int32_t>(sequence * 4 + 1) &&
           hint.previous_y == -static_cast<int32_t>(sequence * 4 + 2) &&
           hint.current_x == static_cast<int32_t>(sequence * 4 + 3) &&
           hint.current_y == -static_cast<int32_t>(sequence * 4 + 4) &&
           hint.predicted_x == static_cast<int32_t>(sequence * 4 + 5) &&
           hint.predicted_y == -static_cast<int32_t>(sequence * 4 + 6);
  };

  std::thread writer([&] {
    for (uint64_t sequence = 1; sequence <= kGenerations; ++sequence) {
      mailbox.publish(hint_for(sequence));
    }
    writer_done.store(true, std::memory_order_release);
  });
  std::thread clearer([&] {
    for (size_t i = 0; i < 2000; ++i) {
      mailbox.clear();
    }
    clearer_done.store(true, std::memory_order_release);
  });

  bool mixed = false;
  size_t observed = 0;
  while (!writer_done.load(std::memory_order_acquire) ||
         !clearer_done.load(std::memory_order_acquire)) {
    const PenRenderHintMailbox::Batch batch = mailbox.snapshot();
    for (size_t i = 0; i < batch.count; ++i) {
      ++observed;
      if (!coherent(batch.entries[i].hint)) {
        mixed = true;
        break;
      }
    }
    if (batch.count != 0) {
      mailbox.acknowledge(batch.entries[batch.count - 1].ticket, batch.epoch);
    }
    if (mixed) {
      break;
    }
  }
  writer.join();
  clearer.join();
  const PenRenderHintMailbox::Batch final_batch = mailbox.snapshot();
  for (size_t i = 0; i < final_batch.count; ++i) {
    ++observed;
    mixed = mixed || !coherent(final_batch.entries[i].hint);
  }
  EXPECT_FALSE(mixed);
  EXPECT_GT(observed, 0u);
}

TEST(PenRenderHintMailboxTest, RotationGenerationRejectsLateOldHint) {
  PenRenderHintMailbox mailbox;
  mailbox.set_generation(2);
  mailbox.publish(pen_hint_at(10, 10, false, 1), 0);
  EXPECT_EQ(mailbox.snapshot().count, 0u);

  mailbox.publish(pen_hint_at(20, 20, false, 2), 2);
  const PenRenderHintMailbox::Batch batch = mailbox.snapshot();
  ASSERT_EQ(batch.count, 1u);
  EXPECT_EQ(batch.entries[0].hint.sequence, 2u);
  EXPECT_EQ(batch.entries[0].hint.current_x, 20);
}

TEST(PenRenderHintMailboxTest, CountsOnlyUnconsumedCapacityOverwrites) {
  PenRenderHintMailbox mailbox;
  for (uint64_t sequence = 1; sequence <= PenRenderHintMailbox::kCapacity + 7;
       ++sequence) {
    mailbox.publish(
        pen_hint_at(static_cast<int32_t>(sequence), 12, true, sequence));
  }
  EXPECT_EQ(mailbox.overwritten_unconsumed(), 7u);
  const PenRenderHintMailbox::Batch retained = mailbox.snapshot();
  ASSERT_EQ(retained.count, PenRenderHintMailbox::kCapacity);
  EXPECT_EQ(retained.entries.front().hint.sequence, 8u);
  EXPECT_EQ(retained.entries.back().hint.sequence,
            PenRenderHintMailbox::kCapacity + 7);

  mailbox.acknowledge(retained.entries.back().ticket, retained.epoch);
  mailbox.publish(
      pen_hint_at(100, 12, true, PenRenderHintMailbox::kCapacity + 8));
  EXPECT_EQ(mailbox.overwritten_unconsumed(), 7u)
      << "consumed history must not be counted as overwritten";
}

TEST(PenRenderHintMailboxTest,
     ClearRetiresBacklogFromOverwriteAccountingWithoutRoutingIt) {
  PenRenderHintMailbox mailbox;
  constexpr uint64_t kOldBacklog = 11;
  for (uint64_t sequence = 1; sequence <= kOldBacklog; ++sequence) {
    mailbox.publish(
        pen_hint_at(static_cast<int32_t>(sequence), 12, true, sequence));
  }
  ASSERT_EQ(mailbox.snapshot().count, kOldBacklog);
  mailbox.clear();
  EXPECT_EQ(mailbox.snapshot().count, 0u);

  // A complete fresh epoch fits the ring. Global ticket numbers are already
  // above capacity near the end, but the intentionally invalidated old epoch
  // is an accounting floor, not lost unconsumed input.
  for (uint64_t offset = 1; offset <= PenRenderHintMailbox::kCapacity;
       ++offset) {
    const uint64_t sequence = kOldBacklog + offset;
    mailbox.publish(
        pen_hint_at(static_cast<int32_t>(sequence), 20, true, sequence));
  }
  EXPECT_EQ(mailbox.overwritten_unconsumed(), 0u);
  EXPECT_EQ(mailbox.snapshot().count, PenRenderHintMailbox::kCapacity);
}

TEST(PenRenderHintMailboxTest,
     InitialNoPenSnapshotIsNotTerminalButActivePositionIsSticky) {
  PenRenderHintMailbox mailbox;

  // Fresh EVIOCGKEY state with every tool bit clear must not retain stale ABS
  // coordinates as a terminal erase ROI.
  mailbox.publish(terminal_pen_hint_at(18, 18, 1));
  EXPECT_EQ(mailbox.snapshot().count, 0u);

  mailbox.publish(pen_hint_at(20, 20, false, 2));
  PenRenderHintMailbox::Batch active = mailbox.snapshot();
  ASSERT_EQ(active.count, 1u);
  ASSERT_NE(active.entries[0].ticket, 0u);
  mailbox.acknowledge(active.entries[0].ticket, active.epoch);

  // The history ticket is consumed, but the latest in-range position remains
  // reusable for app animation until a true range exit.
  active = mailbox.snapshot();
  ASSERT_EQ(active.count, 1u);
  EXPECT_EQ(active.entries[0].ticket, 0u);
  EXPECT_TRUE(active.entries[0].hint.in_range);
  EXPECT_EQ(active.entries[0].hint.current_x, 20);

  mailbox.publish(terminal_pen_hint_at(20, 20, 3));
  const PenRenderHintMailbox::Batch terminal = mailbox.snapshot();
  ASSERT_EQ(terminal.count, 1u);
  EXPECT_FALSE(terminal.entries[0].hint.in_range);
  mailbox.acknowledge(terminal.entries[0].ticket, terminal.epoch);
  EXPECT_EQ(mailbox.snapshot().count, 0u);
}

TEST(FrameRendererTest,
     OneHoverHintAcceleratesTwoLocalAppFramesButNoPenSnapshotDoesNot) {
  {
    std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
    g_ink_capture.records.clear();
  }
  FrameRenderer renderer(ink_capture_config());
  ASSERT_TRUE(renderer.valid());
  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));

  // No active episode: a fresh out-of-range snapshot near the damage cannot
  // promote it, even though the timestamp is recent.
  PenRenderHintSnapshot absent = terminal_pen_hint_at(18, 18, 1);
  absent.timestamp_us = 1500;
  renderer.note_pen_render_hint(absent);
  fill_rect(&pixels, PlutoRect{16, 16, 4, 4}, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
  EXPECT_EQ(renderer.pen_priority_regions(), 0u);

  renderer.note_pen_render_hint(pen_hint_at(18, 18, false, 2));
  fill_rect(&pixels, PlutoRect{16, 16, 4, 4}, 0x7bef);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 3000)));
  EXPECT_EQ(renderer.pen_priority_regions(), 1u);

  // No new evdev sample: an app-owned cursor pulse at the stationary hover
  // position still takes Fast preview plus truth.
  fill_rect(&pixels, PlutoRect{16, 16, 4, 4}, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 4000)));
  EXPECT_EQ(renderer.pen_priority_regions(), 2u);
}

TEST(FrameRendererTest, RotationRequiresPresenterIdleBeforeGeometryRebuild) {
  reset_mono_capture();
  FrameRenderer renderer(mono_capture_config());
  ASSERT_TRUE(renderer.valid());
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    g_mono_capture.wait_idle_timeouts_before_ok = 1;
  }

  EXPECT_FALSE(renderer.set_rotation(90, 64, 64));
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    EXPECT_EQ(g_mono_capture.wait_idle_calls, 1u);
  }
  EXPECT_TRUE(renderer.set_rotation(90, 64, 64));
  {
    std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
    EXPECT_EQ(g_mono_capture.wait_idle_calls, 2u);
  }
}

TEST(FrameRendererTest, LateOldGeometryFrameCannotUndoRotation) {
  FrameRendererConfig config{};
  config.width = 64;
  config.height = 32;
  config.format = kPlutoPixelFormatRgb565;
  config.start_presenter_thread = false;
  config.enable_present_bridge = false;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  // Rotation establishes 32x64 as the only legal logical geometry. A raster
  // callback that began under the old 64x32 metrics is acknowledged so
  // Flutter can retire it, but it must not rebuild the renderer.
  ASSERT_TRUE(renderer.set_rotation(90, 32, 64));
  std::vector<uint16_t> old_pixels(64 * 32, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(old_pixels, 64, 32, 1000)));
  EXPECT_EQ(renderer.stale_geometry_frames(), 1u);
  EXPECT_EQ(renderer.diffed_frames(), 0u);

  std::vector<uint16_t> current_pixels(32 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(current_pixels, 32, 64, 2000)));
  EXPECT_EQ(renderer.stale_geometry_frames(), 1u);
  EXPECT_EQ(renderer.diffed_frames(), 1u);
}

TEST(FrameRendererTest, TerminalHoverEraseUsesRetainedRoiButExitDrawsNothing) {
  {
    std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
    g_ink_capture.records.clear();
  }
  FrameRenderer renderer(ink_capture_config());
  ASSERT_TRUE(renderer.valid());
  std::vector<uint16_t> pixels(64 * 64, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  renderer.set_pen_active(true);
  renderer.note_pen_render_hint(pen_hint_at(18, 18, false, 1));
  renderer.set_pen_active(false);
  renderer.note_pen_render_hint(terminal_pen_hint_at(18, 18, 2));
  {
    std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
    ASSERT_EQ(g_ink_capture.records.size(), 1u)
        << "range exit and its retained ROI must not present by themselves";
  }

  const PlutoRect erased{14, 14, 10, 10};
  fill_rect(&pixels, erased, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
  std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
  ASSERT_EQ(g_ink_capture.records.size(), 2u);
  const InkCapture::Record &preview = g_ink_capture.records.back();
  EXPECT_EQ(preview.refresh_class, kPlutoRefreshFast);
  EXPECT_NE(preview.flags & kPlutoPresentFlagInkPriority, 0u);
  EXPECT_EQ(preview.pixels[18 * 64 + 18], 0xffffu);
}

TEST(FrameRendererTest, StaleTerminalHoverRoiCannotCaptureLaterAppDamage) {
  {
    std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
    g_ink_capture.records.clear();
  }
  FrameRenderer renderer(ink_capture_config());
  ASSERT_TRUE(renderer.valid());
  std::vector<uint16_t> pixels(64 * 64, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  PenRenderHintSnapshot stale = terminal_pen_hint_at(18, 18, 1);
  stale.timestamp_us = 1; // far older than the 250 ms terminal grace window
  renderer.note_pen_render_hint(stale);
  fill_rect(&pixels, PlutoRect{14, 14, 10, 10}, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
  EXPECT_EQ(renderer.pen_priority_regions(), 0u);
  std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
  ASSERT_GE(g_ink_capture.records.size(), 2u);
  EXPECT_EQ(g_ink_capture.records.back().flags & kPlutoPresentFlagInkPriority,
            0u);
}

TEST(FrameRendererTest, QueuedFastHoverFramesCorrelateWithBoundedHistory) {
  {
    std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
    g_ink_capture.records.clear();
  }
  FrameRenderer renderer(ink_capture_config());
  ASSERT_TRUE(renderer.valid());
  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));

  // Input reaches B before Flutter rasterizes the queued pointer at A. A
  // latest-only mailbox would miss the first app frame entirely.
  renderer.note_pen_render_hint(pen_hint_at(10, 10, false, 1));
  renderer.note_pen_render_hint(pen_hint_at(52, 52, false, 2));
  fill_rect(&pixels, PlutoRect{7, 7, 6, 6}, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
  EXPECT_EQ(renderer.pen_priority_regions(), 1u);
  {
    std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
    ASSERT_GE(g_ink_capture.records.size(), 2u);
    EXPECT_NE(g_ink_capture.records.back().flags & kPlutoPresentFlagInkPriority,
              0u);
  }

  // Consuming A leaves the newer B segment available for its later frame.
  fill_rect(&pixels, PlutoRect{49, 49, 6, 6}, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 3000)));
  EXPECT_EQ(renderer.pen_priority_regions(), 2u);
  std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
  ASSERT_GE(g_ink_capture.records.size(), 3u);
}

TEST(FrameRendererTest, CoalescedStrokePrioritizesNewestMatchingTip) {
  {
    std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
    g_ink_capture.records.clear();
  }
  FrameRenderer renderer(ink_capture_config());
  ASSERT_TRUE(renderer.valid());
  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));

  renderer.note_pen_render_hint(pen_hint_at(10, 10, false, 1));
  renderer.note_pen_render_hint(pen_hint_at(52, 10, false, 2));
  // One connected app-owned stroke arrives after Flutter coalesces both
  // queued samples. The current tip at B, not merely the stale tail at A,
  // must enter the Fast lane.
  fill_rect(&pixels, PlutoRect{7, 7, 48, 6}, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));

  bool fast_covers_current_tip = false;
  std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
  for (const InkCapture::Record &record : g_ink_capture.records) {
    if (record.refresh_class != kPlutoRefreshFast ||
        (record.flags & kPlutoPresentFlagInkPriority) == 0) {
      continue;
    }
    for (const PlutoRect &rect : record.rects) {
      if (52 >= rect.x && 52 < rect.x + rect.width && 10 >= rect.y &&
          10 < rect.y + rect.height) {
        fast_covers_current_tip = true;
      }
    }
  }
  EXPECT_TRUE(fast_covers_current_tip)
      << "coalesced damage must accelerate the newest verified tip pixels";
}

TEST(FrameRendererTest, OverlappingFutureHintSurvivesOlderRasterFrame) {
  {
    std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
    g_ink_capture.records.clear();
  }
  FrameRenderer renderer(ink_capture_config());
  ASSERT_TRUE(renderer.valid());
  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));

  // B's focus overlaps A's small dirty rect, but the first Flutter frame was
  // rasterized from A only. Routing A covers every changed pixel, so B must
  // remain queued instead of being prefix-acknowledged without contribution.
  renderer.note_pen_render_hint(pen_hint_at(10, 10, false, 1));
  renderer.note_pen_render_hint(pen_hint_at(15, 10, false, 2));
  fill_rect(&pixels, PlutoRect{7, 7, 6, 6}, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
  EXPECT_EQ(renderer.pen_priority_regions(), 1u);

  fill_rect(&pixels, PlutoRect{14, 7, 6, 6}, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 3000)));
  EXPECT_EQ(renderer.pen_priority_regions(), 2u)
      << "unused overlapping future hint must survive the older frame";
}

TEST(FrameRendererTest, AppRenderedEraseNearHoverIsFastThenTruthAndNeverBlack) {
  {
    std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
    g_ink_capture.records.clear();
  }
  FrameRenderer renderer(ink_capture_config());
  ASSERT_TRUE(renderer.valid());
  std::vector<uint16_t> pixels(64 * 64, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  renderer.note_pen_render_hint(pen_hint_at(18, 18, /*contact=*/false, 1));
  const PlutoRect erased{14, 14, 10, 10};
  fill_rect(&pixels, erased, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
  {
    std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
    ASSERT_EQ(g_ink_capture.records.size(), 2u);
    const InkCapture::Record &preview = g_ink_capture.records.back();
    EXPECT_EQ(preview.refresh_class, kPlutoRefreshFast);
    EXPECT_NE(preview.flags & kPlutoPresentFlagInkPriority, 0u);
    EXPECT_EQ(preview.pixels[18 * 64 + 18], 0xffffu)
        << "pen priority must present the app's white erase, not native ink";
  }

  // Any subsequent real app damage supplies a scheduler tick. With zero
  // synthetic latency, the already-enqueued truth follows immediately; no
  // pen-up/quiescence timer participates.
  pixels[60 * 64 + 60] = 0xffffu;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 3000)));
  std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
  bool saw_truth = false;
  for (const InkCapture::Record &record : g_ink_capture.records) {
    if ((record.flags & kPlutoPresentFlagPenTruth) != 0 &&
        record.refresh_class == kPlutoRefreshText &&
        pluto::rect_intersects(record.rect, erased)) {
      saw_truth = true;
      EXPECT_EQ(record.pixels[18 * 64 + 18], 0xffffu);
    }
  }
  EXPECT_TRUE(saw_truth);
  EXPECT_GE(renderer.pen_priority_regions(), 1u);
}

TEST(FrameRendererTest, ColorAppDamagePreviewsGrayThenChasesRegionalRawColor) {
  {
    std::lock_guard<std::mutex> lock(g_color_capture.mutex);
    g_color_capture.records.clear();
  }
  FrameRendererConfig config{};
  config.width = 64;
  config.height = 64;
  config.format = kPlutoPixelFormatRgb565;
  config.start_presenter_thread = false;
  config.presenter_ops = color_capture_ops();
  config.presenter = reinterpret_cast<PlutoPresenter *>(&g_color_capture);
  config.renderer_config.pen_contact_radius_px = 4;
  config.renderer_config.pen_hover_radius_px = 6;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  renderer.note_pen_render_hint(pen_hint_at(18, 18, true, 1));
  const PlutoRect colored{12, 12, 12, 12};
  fill_rect(&pixels, colored, 0xf800);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));

  {
    std::lock_guard<std::mutex> lock(g_color_capture.mutex);
    ASSERT_GE(g_color_capture.records.size(), 2u);
    const ColorCapture::Record *preview = nullptr;
    for (const ColorCapture::Record &record : g_color_capture.records) {
      if ((record.flags & kPlutoPresentFlagInkPriority) != 0) {
        preview = &record;
      }
    }
    ASSERT_NE(preview, nullptr);
    EXPECT_EQ(preview->refresh_class, kPlutoRefreshFast);
    EXPECT_NE(preview->flags & kPlutoPresentFlagPreDithered, 0u);
    EXPECT_NE(preview->pixels[18 * 64 + 18], 0xf800u);
    EXPECT_TRUE(is_gray16_rgb565(preview->pixels[18 * 64 + 18]));
  }

  // Collision-safe delegated color may chase in this same tick; a later real
  // frame boundary also polls its zero-latency completion.
  pixels[63 * 64 + 63] = 0x0000;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 3000)));
  std::lock_guard<std::mutex> lock(g_color_capture.mutex);
  bool saw_truth = false;
  for (const ColorCapture::Record &record : g_color_capture.records) {
    if ((record.flags & kPlutoPresentFlagPenTruth) == 0) {
      continue;
    }
    saw_truth = true;
    EXPECT_EQ(record.refresh_class, kPlutoRefreshFull);
    EXPECT_EQ(record.flags & kPlutoPresentFlagPreDithered, 0u);
    EXPECT_EQ(record.pixels[18 * 64 + 18], 0xf800u);
    EXPECT_LT(record.rect.width * record.rect.height, 64 * 64)
        << "pen color truth must stay regional";
  }
  EXPECT_TRUE(saw_truth);
}

TEST(FrameRendererTest,
     SameLumaHueChangeIsDamageAndChasesLatestRegionalRawColor) {
  {
    std::lock_guard<std::mutex> lock(g_color_capture.mutex);
    g_color_capture.records.clear();
  }
  FrameRendererConfig config{};
  config.width = 64;
  config.height = 64;
  config.format = kPlutoPixelFormatRgb565;
  config.start_presenter_thread = false;
  config.presenter_ops = color_capture_ops();
  config.presenter = reinterpret_cast<PlutoPresenter *>(&g_color_capture);
  config.renderer_config.pen_contact_radius_px = 4;
  config.renderer_config.pen_hover_radius_px = 6;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  // Proven RGB565 pair with identical rgb565_luma8()==66 but different,
  // chromatic raw values. A luma-only ledger would incorrectly see no diff.
  constexpr uint16_t kHueA = 0x023b;
  constexpr uint16_t kHueB = 0x88df;
  static_assert(kHueA != kHueB);
  ASSERT_EQ(pluto::rgb565_luma8(kHueA), pluto::rgb565_luma8(kHueB));
  ASSERT_TRUE(pluto::rgb565_has_chroma(kHueA));
  ASSERT_TRUE(pluto::rgb565_has_chroma(kHueB));

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  fill_rect(&pixels, PlutoRect{16, 16, 4, 4}, kHueA);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  {
    std::lock_guard<std::mutex> lock(g_color_capture.mutex);
    g_color_capture.records.clear();
  }
  renderer.note_pen_render_hint(pen_hint_at(18, 18, true, 1));
  const PlutoRect changed{16, 16, 4, 4};
  fill_rect(&pixels, changed, kHueB);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
  EXPECT_GT(renderer.last_damage_count(), 0u);
  EXPECT_GT(renderer.chroma_marked_tiles(), 0u);
  {
    std::lock_guard<std::mutex> lock(g_color_capture.mutex);
    ASSERT_TRUE(!g_color_capture.records.empty());
    const ColorCapture::Record &preview = g_color_capture.records.front();
    EXPECT_EQ(preview.refresh_class, kPlutoRefreshFast);
    EXPECT_NE(preview.flags & kPlutoPresentFlagInkPriority, 0u);
    EXPECT_NE(preview.pixels[18 * 64 + 18], kHueB);
  }

  pixels[63 * 64 + 63] = 0x0000;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 3000)));
  std::lock_guard<std::mutex> lock(g_color_capture.mutex);
  bool saw_raw_truth = false;
  for (const ColorCapture::Record &record : g_color_capture.records) {
    if ((record.flags & kPlutoPresentFlagPenTruth) != 0 &&
        record.refresh_class == kPlutoRefreshFull &&
        record.pixels[18 * 64 + 18] == kHueB) {
      saw_raw_truth = true;
    }
  }
  EXPECT_TRUE(saw_raw_truth);
}

TEST(FrameRendererTest, LumaOnlyBackendStillDetectsSameLumaAppHueChange) {
  reset_mono_capture();
  FrameRendererConfig config = mono_capture_config();
  config.start_presenter_thread = false;
  config.renderer_config.pen_contact_radius_px = 4;
  config.renderer_config.pen_hover_radius_px = 6;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  constexpr uint16_t kHueA = 0x023b;
  constexpr uint16_t kHueB = 0x88df;
  ASSERT_EQ(pluto::rgb565_luma8(kHueA), pluto::rgb565_luma8(kHueB));
  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  fill_rect(&pixels, PlutoRect{16, 16, 4, 4}, kHueA);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  reset_mono_capture();

  renderer.note_pen_render_hint(pen_hint_at(18, 18, true, 1));
  fill_rect(&pixels, PlutoRect{16, 16, 4, 4}, kHueB);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
  EXPECT_GT(renderer.last_damage_count(), 0u)
      << "raw RGB truth must notice hue changes even when output is luma";
  EXPECT_GT(renderer.pen_priority_regions(), 0u);
  EXPECT_EQ(renderer.chroma_marked_tiles(), 0u)
      << "a luma-only backend detects color change but owes Text, not Full";

  std::lock_guard<std::mutex> lock(g_mono_capture.mutex);
  ASSERT_TRUE(!g_mono_capture.flags_history.empty());
  EXPECT_EQ(g_mono_capture.class_history.front(), kPlutoRefreshFast);
  EXPECT_NE(g_mono_capture.flags_history.front() & kPlutoPresentFlagInkPriority,
            0u);
}

TEST(FrameRendererTest,
     ColorEraseToWhiteStillGetsFullTruthButNearbyGrayChangeStaysText) {
  {
    std::lock_guard<std::mutex> lock(g_color_capture.mutex);
    g_color_capture.records.clear();
  }
  FrameRendererConfig config{};
  config.width = 64;
  config.height = 64;
  config.format = kPlutoPixelFormatRgb565;
  config.start_presenter_thread = false;
  config.presenter_ops = color_capture_ops();
  config.presenter = reinterpret_cast<PlutoPresenter *>(&g_color_capture);
  config.renderer_config.pen_contact_radius_px = 4;
  config.renderer_config.pen_hover_radius_px = 6;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  fill_rect(&pixels, PlutoRect{16, 16, 4, 4}, 0xf800);
  // Static color in the bottom-right tile must not promote a later gray-only
  // change in that same tile.
  fill_rect(&pixels, PlutoRect{40, 40, 4, 4}, 0xf800);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  {
    std::lock_guard<std::mutex> lock(g_color_capture.mutex);
    g_color_capture.records.clear();
  }

  renderer.note_pen_render_hint(pen_hint_at(18, 18, true, 1));
  fill_rect(&pixels, PlutoRect{16, 16, 4, 4}, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
  pixels[0] ^= 0xffffu;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 3000)));
  {
    std::lock_guard<std::mutex> lock(g_color_capture.mutex);
    bool saw_white_full = false;
    for (const ColorCapture::Record &record : g_color_capture.records) {
      if ((record.flags & kPlutoPresentFlagPenTruth) != 0 &&
          record.refresh_class == kPlutoRefreshFull &&
          record.pixels[18 * 64 + 18] == 0xffffu) {
        saw_white_full = true;
      }
    }
    EXPECT_TRUE(saw_white_full);
    g_color_capture.records.clear();
  }

  renderer.note_pen_render_hint(pen_hint_at(48, 48, true, 2));
  pixels[48 * 64 + 48] = 0x0000;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 4000)));
  pixels[1] ^= 0xffffu;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 5000)));
  std::lock_guard<std::mutex> lock(g_color_capture.mutex);
  bool saw_gray_text = false;
  bool saw_gray_full = false;
  for (const ColorCapture::Record &record : g_color_capture.records) {
    if ((record.flags & kPlutoPresentFlagPenTruth) == 0 ||
        record.pixels[48 * 64 + 48] != 0x0000u) {
      continue;
    }
    saw_gray_text = saw_gray_text || record.refresh_class == kPlutoRefreshText;
    saw_gray_full = saw_gray_full || record.refresh_class == kPlutoRefreshFull;
  }
  EXPECT_TRUE(saw_gray_text);
  EXPECT_FALSE(saw_gray_full);
}

TEST(FrameRendererTest, DrawBackBeforeTruthUsesNewestAppPixels) {
  {
    std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
    g_ink_capture.records.clear();
  }
  FrameRenderer renderer(ink_capture_config());
  ASSERT_TRUE(renderer.valid());
  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  renderer.note_pen_render_hint(pen_hint_at(20, 20, true, 1));
  const PlutoRect patch{16, 16, 10, 10};
  fill_rect(&pixels, patch, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));
  renderer.note_pen_render_hint(pen_hint_at(21, 20, true, 2));
  fill_rect(&pixels, patch, 0xffff); // app draws back over its own pixels
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 3000)));
  pixels[63 * 64 + 63] = 0x0000;
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 4000)));
  std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
  ASSERT_GE(g_ink_capture.records.size(), 3u);
  bool saw_second_preview = false;
  bool saw_truth = false;
  uint16_t newest_truth_pixel = 0;
  for (const InkCapture::Record &record : g_ink_capture.records) {
    if ((record.flags & kPlutoPresentFlagInkPriority) != 0 &&
        record.pixels[20 * 64 + 20] == 0xffffu) {
      saw_second_preview = true;
    }
    if ((record.flags & kPlutoPresentFlagPenTruth) != 0 &&
        pluto::rect_intersects(record.rect, patch)) {
      saw_truth = true;
      newest_truth_pixel = record.pixels[20 * 64 + 20];
    }
  }
  EXPECT_TRUE(saw_second_preview);
  EXPECT_TRUE(saw_truth);
  EXPECT_EQ(newest_truth_pixel, 0xffffu)
      << "a stale trailing truth repainted pixels superseded by draw-back";
}

TEST(FrameRendererTest,
     BroadMultiTileBrushSplitsHotLaneAndEraseTruthUsesNewestPixels) {
  {
    std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
    g_ink_capture.records.clear();
  }
  FrameRenderer renderer(ink_capture_config());
  ASSERT_TRUE(renderer.valid());
  std::vector<uint16_t> pixels(64 * 64, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 1000)));
  {
    std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
    g_ink_capture.records.clear();
  }

  // One connected 56x32 app brush spans all four 32px renderer tiles and is
  // larger than the configured 25% pen hot-lane cap (1024 of 4096 px).
  // Only the nib corridor may receive InkPriority; exact residual rectangles
  // must remain ordinary app damage.
  const PlutoRect broad{4, 16, 56, 32};
  renderer.note_pen_render_hint(pen_hint_at(32, 32, true, 1));
  fill_rect(&pixels, broad, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 2000)));

  // Erase/draw back before the trailing truth can drain. The second preview
  // and every eventually dispatched truth must read the newest white app
  // pixels, never a retained black brush snapshot.
  renderer.note_pen_render_hint(pen_hint_at(33, 32, true, 2));
  fill_rect(&pixels, broad, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 64, 64, 3000)));
  for (uint64_t frame = 4; frame <= 12; ++frame) {
    const size_t index = static_cast<size_t>((frame & 1u) ? 0 : 63);
    pixels[index] ^= 0xffffu;
    ASSERT_TRUE(
        renderer.submit_frame(packet_for(pixels, 64, 64, frame * 1000u)));
  }

  std::lock_guard<std::mutex> lock(g_ink_capture.mutex);
  bool saw_capped_black_preview = false;
  bool saw_white_preview = false;
  bool saw_ordinary_residual = false;
  bool saw_truth = false;
  uint16_t newest_truth_pixel = 0;
  for (const InkCapture::Record &record : g_ink_capture.records) {
    const bool preview = (record.flags & kPlutoPresentFlagInkPriority) != 0;
    const bool truth = (record.flags & kPlutoPresentFlagPenTruth) != 0;
    bool overlaps_broad = false;
    uint64_t request_area = 0;
    for (const PlutoRect &rect : record.rects) {
      overlaps_broad = overlaps_broad || pluto::rect_intersects(rect, broad);
      request_area += static_cast<uint64_t>(pluto::rect_area(rect));
    }
    if (!overlaps_broad) {
      continue;
    }
    if (preview && record.pixels[32 * 64 + 32] == 0x0000u) {
      saw_capped_black_preview = true;
      // Presenter damage includes the Fast guard band, so it can exceed the
      // 1024px content cap; it must still be smaller than the 1792px brush.
      EXPECT_LT(request_area, static_cast<uint64_t>(pluto::rect_area(broad)));
    }
    if (preview && record.pixels[32 * 64 + 32] == 0xffffu) {
      saw_white_preview = true;
    }
    if (!preview && !truth) {
      saw_ordinary_residual = true;
    }
    if (truth) {
      saw_truth = true;
      newest_truth_pixel = record.pixels[32 * 64 + 32];
    }
  }
  EXPECT_TRUE(saw_capped_black_preview);
  EXPECT_TRUE(saw_white_preview);
  EXPECT_TRUE(saw_ordinary_residual);
  EXPECT_TRUE(saw_truth);
  EXPECT_EQ(newest_truth_pixel, 0xffffu);
}

// PLUTO_RECORD_FRAMES: the capture stream carries every submitted packet
// (update and idle) in the documented layout.
TEST(FrameRendererTest, FrameRecorderCapturesSubmittedPackets) {
  const std::filesystem::path path =
      std::filesystem::temp_directory_path() / "pluto-record-frames-test.bin";
  std::filesystem::remove(path);
  ::setenv("PLUTO_RECORD_FRAMES", path.string().c_str(), 1);

  {
    FrameRendererConfig config{};
    config.width = 8;
    config.height = 8;
    config.format = kPlutoPixelFormatRgb565;
    config.start_presenter_thread = false;
    FrameRenderer renderer(config);
    ASSERT_TRUE(renderer.valid());

    std::vector<uint16_t> pixels(8 * 8, 0x1234);
    ASSERT_TRUE(renderer.submit_frame(packet_for(pixels, 8, 8, 1000)));
    PlutoFramePacket idle = packet_for(pixels, 8, 8, 2000);
    idle.did_update = false;
    ASSERT_TRUE(renderer.submit_frame(idle));
    renderer.shutdown();
  }
  ::unsetenv("PLUTO_RECORD_FRAMES");

  std::ifstream in(path, std::ios::binary);
  ASSERT_TRUE(in.good());
  const auto read_u32 = [&in]() {
    uint32_t value = 0;
    in.read(reinterpret_cast<char *>(&value), sizeof(value));
    return value;
  };
  const auto read_u64 = [&in]() {
    uint64_t value = 0;
    in.read(reinterpret_cast<char *>(&value), sizeof(value));
    return value;
  };
  const auto verify_checksum = [&in](std::streampos frame_start,
                                     uint32_t frame_bytes, uint32_t checksum) {
    const std::streampos end = in.tellg();
    in.seekg(frame_start);
    std::vector<uint8_t> bytes(frame_bytes - sizeof(checksum));
    in.read(reinterpret_cast<char *>(bytes.data()),
            static_cast<std::streamsize>(bytes.size()));
    ASSERT_TRUE(in.good());
    EXPECT_EQ(pluto::frame_recording::crc32(bytes.data(), bytes.size()),
              checksum);
    in.seekg(end);
  };
  EXPECT_EQ(read_u32(), pluto::frame_recording::kFileMagic);

  // Frame 1: did_update with full payload.
  const std::streampos first_start = in.tellg();
  EXPECT_EQ(read_u32(), pluto::frame_recording::kFrameMagic);
  const uint32_t first_bytes = read_u32();
  EXPECT_EQ(first_bytes,
            pluto::frame_recording::kMinimumFrameBytes + 8u * 8u * 2u);
  EXPECT_EQ(read_u64(), 1000u);
  EXPECT_EQ(read_u32(), 8u);
  EXPECT_EQ(read_u32(), 8u);
  EXPECT_EQ(read_u32(), static_cast<uint32_t>(kPlutoPixelFormatRgb565));
  EXPECT_EQ(read_u32(), 1u); // did_update
  EXPECT_EQ(read_u32(), 0u); // paint_bounds_count
  ASSERT_EQ(read_u32(), 8u * 8u * 2u);
  std::vector<uint16_t> payload(8 * 8, 0);
  in.read(reinterpret_cast<char *>(payload.data()), 8 * 8 * 2);
  ASSERT_TRUE(in.good());
  for (const uint16_t px : payload) {
    ASSERT_EQ(px, 0x1234u);
  }
  const uint32_t first_checksum = read_u32();
  verify_checksum(first_start, first_bytes, first_checksum);

  // Frame 2: idle, header only.
  const std::streampos second_start = in.tellg();
  EXPECT_EQ(read_u32(), pluto::frame_recording::kFrameMagic);
  const uint32_t second_bytes = read_u32();
  EXPECT_EQ(second_bytes, pluto::frame_recording::kMinimumFrameBytes);
  EXPECT_EQ(read_u64(), 2000u);
  EXPECT_EQ(read_u32(), 8u);
  EXPECT_EQ(read_u32(), 8u);
  EXPECT_EQ(read_u32(), static_cast<uint32_t>(kPlutoPixelFormatRgb565));
  EXPECT_EQ(read_u32(), 0u); // did_update
  EXPECT_EQ(read_u32(), 0u); // paint_bounds_count
  EXPECT_EQ(read_u32(), 0u); // payload_bytes
  const uint32_t second_checksum = read_u32();
  verify_checksum(second_start, second_bytes, second_checksum);
  ASSERT_TRUE(in.good());
  in.get();
  EXPECT_TRUE(in.eof());
  std::filesystem::remove(path);
}

} // namespace

// ---- scroll fast path: residual damage straddling the band -----------------

namespace {

// 128x256 capture presenter for the scroll probes: mono, alignment 1,
// zero latency, full damage-rect recording.
struct ScrollCap {
  std::mutex mutex;
  struct Record {
    PlutoRefreshClass cls = kPlutoRefreshUi;
    uint32_t flags = 0;
    std::vector<PlutoRect> damage;
  };
  std::vector<Record> records;
};
ScrollCap g_scroll_capture;

const PlutoPresenterOps *scroll_capture_ops() {
  static PlutoPresenterOps ops = [] {
    PlutoPresenterOps o =
        pluto::test::current_test_presenter_ops("scroll-capture");
    o.info = [](PlutoPresenter *, PlutoDisplayInfo *out_info) {
      PlutoDisplayInfo info{};
      info.struct_size = sizeof(info);
      info.width = 128;
      info.height = 256;
      info.dpi = 264;
      info.preferred_format = kPlutoPixelFormatRgb565;
      info.is_color = false;
      info.wants_pre_dithered = true;
      info.backend_quantizes_color = false;
      info.rect_alignment = 1;
      for (int i = 0; i < 4; ++i) {
        info.nominal_latency_ms[i] = 0;
      }
      *out_info = info;
      return kPlutoStatusOk;
    };
    o.present = [](PlutoPresenter *, const PlutoPresentRequest *request) {
      std::lock_guard<std::mutex> lock(g_scroll_capture.mutex);
      ScrollCap::Record record;
      record.cls = request->refresh_class;
      record.flags = request->flags;
      for (size_t i = 0; i < request->damage_count; ++i) {
        record.damage.push_back(request->damage[i]);
      }
      g_scroll_capture.records.push_back(std::move(record));
      return kPlutoStatusOk;
    };
    o.ready = [](PlutoPresenter *, PlutoRefreshClass) { return true; };
    return o;
  }();
  return &ops;
}

// Rail-only (pure black/white) text-like rows: byte content is a pure
// function of the content line, so vertical translation is byte-exact
// through the position-keyed quantizer and the row-hash detector votes.
void paint_scroll_text_row(std::vector<uint16_t> *px, int32_t y, int32_t line) {
  uint16_t *row = px->data() + static_cast<size_t>(y) * 128;
  std::fill(row, row + 128, static_cast<uint16_t>(0xffff));
  uint32_t h = static_cast<uint32_t>(line) * 2654435761u;
  h ^= h >> 15;
  const int32_t start = 8 + static_cast<int32_t>(h % 48u);
  const int32_t width = 24 + static_cast<int32_t>((h >> 8) % 48u);
  const int32_t end = std::min<int32_t>(start + width, 128);
  std::fill(row + start, row + end, static_cast<uint16_t>(0x0000));
}

// The ticker rows redraw FRESH (non-translated) content every frame: a
// double-bar pattern no text row ever hashes equal to.
void paint_ticker_row(std::vector<uint16_t> *px, int32_t y, int32_t seed) {
  uint16_t *row = px->data() + static_cast<size_t>(y) * 128;
  std::fill(row, row + 128, static_cast<uint16_t>(0xffff));
  const int32_t a = 4 + ((seed * 7 + y) % 16);
  std::fill(row + a, row + a + 12, static_cast<uint16_t>(0x0000));
  std::fill(row + 96 + (seed % 8), row + 108 + (seed % 8),
            static_cast<uint16_t>(0x0000));
}

} // namespace

// Probe (scroll residual damage): a ticker repaints rows just ABOVE the
// scrolled body in the same frame as a verified MOVE; damage merging folds
// ticker + body into ONE rect that straddles the band edge. The ticker's
// out-of-band content must still be presented — dropping the whole rect
// because it touches the band would strand the ticker on stale glass
// forever (no ghost debt accrues on unsubmitted damage, so no settle would
// ever repaint it).
TEST(FrameRendererTest, ScrollResidualDamageOutsideBandStillPresents) {
  {
    std::lock_guard<std::mutex> lock(g_scroll_capture.mutex);
    g_scroll_capture.records.clear();
  }
  FrameRendererConfig config{};
  config.width = 128;
  config.height = 256;
  config.format = kPlutoPixelFormatRgb565;
  config.start_presenter_thread = false;
  config.presenter_ops = scroll_capture_ops();
  config.presenter = reinterpret_cast<PlutoPresenter *>(&g_scroll_capture);
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  const auto make_frame = [](int32_t text_offset, int32_t ticker_seed) {
    std::vector<uint16_t> px(static_cast<size_t>(128) * 256, 0xffff);
    for (int32_t y = 40; y < 64; ++y) {
      paint_ticker_row(&px, y, ticker_seed);
    }
    for (int32_t y = 64; y < 256; ++y) {
      paint_scroll_text_row(&px, y, y + text_offset);
    }
    return px;
  };

  std::vector<uint16_t> frame1 = make_frame(0, 1);
  ASSERT_TRUE(renderer.submit_frame(packet_for(frame1, 128, 256, 1000)));
  ASSERT_EQ(renderer.scroll_moves_detected(), 0u);

  // Only presents issued AFTER the scroll frame's damage count as coverage
  // (frame 1's first paint trivially covered everything).
  const size_t records_before_scroll = [] {
    std::lock_guard<std::mutex> lock(g_scroll_capture.mutex);
    return g_scroll_capture.records.size();
  }();

  // Frame 2: the text scrolls UP by 16 px while the ticker redraws fresh.
  std::vector<uint16_t> frame2 = make_frame(16, 2);
  ASSERT_TRUE(renderer.submit_frame(packet_for(frame2, 128, 256, 2000)));
  EXPECT_EQ(renderer.scroll_moves_detected(), 1u);

  // Drive a few more ticks (tiny corner pokes far from the ticker) so any
  // parked/declined retries drain.
  std::vector<uint16_t> poke = frame2;
  for (int i = 0; i < 6; ++i) {
    const uint16_t color = (i % 2 == 0) ? 0x0000 : 0xffff;
    for (int32_t y = 0; y < 8; ++y) {
      for (int32_t x = 120; x < 128; ++x) {
        poke[static_cast<size_t>(y) * 128 + x] = color;
      }
    }
    ASSERT_TRUE(
        renderer.submit_frame(packet_for(poke, 128, 256, 3000 + i * 1000)));
  }

  // A box inside the ticker's changed bar area must be covered by an
  // accepted present issued after the scroll frame's damage (exact
  // post-quantize rects never include the untouched white margins, so the
  // probe targets content that really changed).
  const PlutoRect ticker{8, 44, 8, 8};
  bool covered = false;
  {
    std::lock_guard<std::mutex> lock(g_scroll_capture.mutex);
    for (size_t r = records_before_scroll; r < g_scroll_capture.records.size();
         ++r) {
      const ScrollCap::Record &record = g_scroll_capture.records[r];
      for (const PlutoRect &rect : record.damage) {
        if (ticker.x >= rect.x && ticker.y >= rect.y &&
            ticker.x + ticker.width <= rect.x + rect.width &&
            ticker.y + ticker.height <= rect.y + rect.height) {
          covered = true;
        }
      }
    }
  }
  EXPECT_TRUE(covered)
      << "ticker damage merged across the band edge was dropped: its "
         "out-of-band rows never reached glass";
}

TEST(FrameRendererTest,
     PenDamageInsidePacedScrollBypassesBodySuppressionAndChasesTruth) {
  {
    std::lock_guard<std::mutex> lock(g_scroll_capture.mutex);
    g_scroll_capture.records.clear();
  }
  FrameRendererConfig config{};
  config.width = 128;
  config.height = 256;
  config.format = kPlutoPixelFormatRgb565;
  config.start_presenter_thread = false;
  config.presenter_ops = scroll_capture_ops();
  config.presenter = reinterpret_cast<PlutoPresenter *>(&g_scroll_capture);
  config.renderer_config.scroll_body_emit_px = 64;
  config.renderer_config.pen_hover_radius_px = 8;
  config.renderer_config.pen_contact_radius_px = 6;
  config.renderer_config.pen_max_preview_area_percent = 10;
  FrameRenderer renderer(config);
  ASSERT_TRUE(renderer.valid());

  const auto make_frame = [](int32_t text_offset) {
    std::vector<uint16_t> px(static_cast<size_t>(128) * 256, 0xffff);
    for (int32_t y = 64; y < 256; ++y) {
      paint_scroll_text_row(&px, y, y + text_offset);
    }
    return px;
  };
  const PlutoRect hover_indicator{60, 124, 8, 8};
  const auto paint_indicator = [&](std::vector<uint16_t> *pixels,
                                   uint16_t value) {
    for (int32_t y = hover_indicator.y;
         y < hover_indicator.y + hover_indicator.height; ++y) {
      for (int32_t x = hover_indicator.x;
           x < hover_indicator.x + hover_indicator.width; ++x) {
        (*pixels)[static_cast<size_t>(y) * 128 + x] = value;
      }
    }
  };

  std::vector<uint16_t> frame1 = make_frame(0);
  paint_indicator(&frame1, 0xffff);
  ASSERT_TRUE(renderer.submit_frame(packet_for(frame1, 128, 256, 1000)));
  const size_t records_before_scroll = [] {
    std::lock_guard<std::mutex> lock(g_scroll_capture.mutex);
    return g_scroll_capture.records.size();
  }();

  // A 16 px MOVE is below the 64 px body cadence, but the app also paints an
  // explicit hover indicator inside that otherwise-suppressed body.
  renderer.note_pen_render_hint(
      pen_hint_at(64, 128, /*contact=*/false, /*sequence=*/1));
  std::vector<uint16_t> frame2 = make_frame(16);
  paint_indicator(&frame2, 0x0000);
  ASSERT_TRUE(renderer.submit_frame(packet_for(frame2, 128, 256, 2000)));
  ASSERT_EQ(renderer.scroll_moves_detected(), 1u);

  bool saw_fast = false;
  {
    std::lock_guard<std::mutex> lock(g_scroll_capture.mutex);
    for (size_t i = records_before_scroll; i < g_scroll_capture.records.size();
         ++i) {
      const ScrollCap::Record &record = g_scroll_capture.records[i];
      if (record.cls != kPlutoRefreshFast ||
          (record.flags & kPlutoPresentFlagInkPriority) == 0) {
        continue;
      }
      for (const PlutoRect &rect : record.damage) {
        if (hover_indicator.x >= rect.x && hover_indicator.y >= rect.y &&
            hover_indicator.x + hover_indicator.width <= rect.x + rect.width &&
            hover_indicator.y + hover_indicator.height <=
                rect.y + rect.height) {
          saw_fast = true;
        }
      }
    }
  }
  EXPECT_TRUE(saw_fast)
      << "scroll-body pacing delayed pen-correlated app damage";

  // A following unrelated frame retires the zero-latency preview fence. The
  // already-queued truth must then run before ordinary damage.
  std::vector<uint16_t> frame3 = frame2;
  frame3[0] = 0x0000;
  ASSERT_TRUE(renderer.submit_frame(packet_for(frame3, 128, 256, 3000)));
  bool saw_truth = false;
  {
    std::lock_guard<std::mutex> lock(g_scroll_capture.mutex);
    for (size_t i = records_before_scroll; i < g_scroll_capture.records.size();
         ++i) {
      const ScrollCap::Record &record = g_scroll_capture.records[i];
      if ((record.flags & kPlutoPresentFlagPenTruth) == 0) {
        continue;
      }
      for (const PlutoRect &rect : record.damage) {
        if (hover_indicator.x >= rect.x && hover_indicator.y >= rect.y &&
            hover_indicator.x + hover_indicator.width <= rect.x + rect.width &&
            hover_indicator.y + hover_indicator.height <=
                rect.y + rect.height) {
          saw_truth = true;
        }
      }
    }
  }
  EXPECT_TRUE(saw_truth);
}
