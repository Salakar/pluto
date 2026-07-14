#include "presenter/swtcon/scan_loop.h"

#include "presenter/swtcon/drm_swtcon_device.h"
#include "presenter/swtcon/swtcon_constants.h"

#include <gtest/gtest.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using pluto::swtcon::DrmFlipEvent;
using pluto::swtcon::DrmSwtconDevice;
using pluto::swtcon::kDrmBufferCount;
using pluto::swtcon::kDrmHeight;
using pluto::swtcon::kDrmPhaseWords;
using pluto::swtcon::kDrmWidth;
using pluto::swtcon::kDrmModePageFlipEventFlag;
using pluto::swtcon::ScanClock;
using pluto::swtcon::ScanFeedback;
using pluto::swtcon::ScanLoop;
using pluto::swtcon::ScanLoopConfig;

// FakeDrm in the swtcon_drm_device_test.cc shape, extended with flip-event
// scripting: every event-requesting atomic commit queues a completion whose
// hardware vblank sequence advances by `next_sequence_step` (set to 2+ to
// inject a double scan).
class FakeDrm final : public pluto::swtcon::DrmInterface {
public:
  int open_card(const std::string &, std::string *) override { return 7; }
  void close_fd(int) override {}
  bool set_client_cap(int, std::uint64_t, std::uint64_t,
                      std::string *) override {
    return true;
  }
  bool get_cap(int, std::uint64_t capability, std::uint64_t *value,
               std::string *) override {
    *value = capability == 1 || capability == 0x12 ? 1 : 0;
    return true;
  }
  bool get_resources(int, pluto::swtcon::DrmResources *out,
                     std::string *) override {
    out->crtcs = {20};
    out->connectors = {10};
    return true;
  }
  bool get_connector(int, std::uint32_t connector_id,
                     pluto::swtcon::DrmConnectorInfo *out,
                     std::string *) override {
    out->connector_id = connector_id;
    out->encoder_id = 30;
    out->connected = true;
    pluto::swtcon::DrmModeInfo mode{};
    mode.hdisplay = kDrmWidth;
    mode.vdisplay = kDrmHeight;
    mode.htotal = htotal;
    mode.vtotal = vtotal;
    mode.clock = clock_khz;
    std::strncpy(mode.name, "swtcon-scan-test", sizeof(mode.name) - 1);
    out->modes = {mode};
    out->properties = {{55, "DPMS", 0}};
    out->encoders = {30};
    return true;
  }
  bool get_encoder(int, std::uint32_t encoder_id,
                   pluto::swtcon::DrmEncoderInfo *out,
                   std::string *) override {
    out->encoder_id = encoder_id;
    out->crtc_id = 20;
    out->possible_crtcs = 1;
    return true;
  }
  bool get_plane_ids(int, std::vector<std::uint32_t> *out,
                     std::string *) override {
    *out = {40};
    return true;
  }
  bool get_plane(int, std::uint32_t plane_id,
                 pluto::swtcon::DrmPlaneInfo *out, std::string *) override {
    out->plane_id = plane_id;
    out->possible_crtcs = 1;
    out->properties = {{60, "type", 1},   {61, "FB_ID", 0},  {62, "CRTC_ID", 0},
                       {63, "CRTC_X", 0}, {64, "CRTC_Y", 0}, {65, "CRTC_W", 0},
                       {66, "CRTC_H", 0}, {67, "SRC_X", 0},  {68, "SRC_Y", 0},
                       {69, "SRC_W", 0},  {70, "SRC_H", 0}};
    return true;
  }
  bool create_dumb(int, std::uint32_t, std::uint32_t, std::uint32_t,
                   pluto::swtcon::DrmDumbCreateResult *out,
                   std::string *) override {
    ++created;
    out->handle = 1000 + created;
    out->pitch = kDrmWidth * sizeof(std::uint16_t);
    out->size = pluto::swtcon::kDrmPhaseBytes;
    return true;
  }
  bool add_fb(int, std::uint32_t, std::uint32_t, std::uint8_t, std::uint8_t,
              std::uint32_t, std::uint32_t, std::uint32_t *fb_id,
              std::string *) override {
    *fb_id = 2000 + created;
    return true;
  }
  bool map_dumb(int, std::uint32_t handle, std::uint64_t *offset,
                std::string *) override {
    *offset = handle * 4096ULL;
    return true;
  }
  void *mmap_dumb(int, std::uint64_t, std::uint64_t size,
                  std::string *) override {
    maps.push_back(
        std::make_unique<std::uint8_t[]>(static_cast<std::size_t>(size)));
    return maps.back().get();
  }
  void munmap_dumb(void *, std::uint64_t) override {}
  bool rm_fb(int, std::uint32_t, std::string *) override { return true; }
  bool destroy_dumb(int, std::uint32_t, std::string *) override {
    return true;
  }
  bool set_crtc(int, std::uint32_t, std::uint32_t, std::uint32_t,
                const pluto::swtcon::DrmModeInfo &, std::string *) override {
    return true;
  }
  bool blank_crtc(int, std::uint32_t, std::string *) override { return true; }
  bool set_connector_property(int, std::uint32_t, std::uint32_t,
                              std::uint64_t, std::string *) override {
    return true;
  }
  bool atomic_commit(int, const pluto::swtcon::DrmAtomicRequest &request,
                     std::string *) override {
    std::lock_guard<std::mutex> lock(mutex);
    flipped_fb_ids.push_back(static_cast<std::uint32_t>(request.values.back()));
    if ((request.flags & kDrmModePageFlipEventFlag) != 0) {
      DrmFlipEvent event;
      event.user_data = request.user_data;
      next_sequence += next_sequence_step;
      event.sequence = next_sequence;
      pending_events.push_back(event);
    }
    return true;
  }
  bool read_flip_events(int, std::vector<DrmFlipEvent> *out,
                        std::string *) override {
    std::lock_guard<std::mutex> lock(mutex);
    if (!deliver_events) {
      return true;
    }
    out->insert(out->end(), pending_events.begin(), pending_events.end());
    pending_events.clear();
    return true;
  }

  std::uint32_t last_flipped_fb() {
    std::lock_guard<std::mutex> lock(mutex);
    return flipped_fb_ids.empty() ? 0 : flipped_fb_ids.back();
  }
  std::size_t flip_count() {
    std::lock_guard<std::mutex> lock(mutex);
    return flipped_fb_ids.size();
  }

  // Mode timings surfaced through get_connector (defaults: no timings ->
  // the ScanLoop falls back to round(1e9/85)).
  std::uint16_t htotal = 0;
  std::uint16_t vtotal = 0;
  std::uint32_t clock_khz = 0;

  int created = 0;
  std::vector<std::unique_ptr<std::uint8_t[]>> maps;
  std::mutex mutex;
  std::vector<std::uint32_t> flipped_fb_ids;
  std::vector<DrmFlipEvent> pending_events;
  std::uint32_t next_sequence = 100;
  std::uint32_t next_sequence_step = 1;
  bool deliver_events = true;
};

// Scripted virtual clock: sleep_until_ns records the requested absolute
// deadline and jumps time there (thread-safe for the threaded cadence
// test).
class FakeClock final : public ScanClock {
 public:
  std::uint64_t now_ns() override {
    std::lock_guard<std::mutex> lock(mutex_);
    return now_;
  }
  void sleep_until_ns(std::uint64_t deadline_ns) override {
    std::lock_guard<std::mutex> lock(mutex_);
    deadlines_.push_back(deadline_ns);
    if (deadline_ns > now_) {
      now_ = deadline_ns;
    }
  }
  void set_now(std::uint64_t now) {
    std::lock_guard<std::mutex> lock(mutex_);
    now_ = now;
  }
  std::vector<std::uint64_t> deadlines() {
    std::lock_guard<std::mutex> lock(mutex_);
    return deadlines_;
  }

 private:
  std::mutex mutex_;
  std::uint64_t now_ = 0;
  std::vector<std::uint64_t> deadlines_;
};

struct Harness {
  FakeDrm* drm = nullptr;  // borrowed from device
  std::unique_ptr<DrmSwtconDevice> device;
  FakeClock clock;
  ScanLoop loop;

  explicit Harness(std::uint16_t htotal = 0, std::uint16_t vtotal = 0,
                   std::uint32_t clock_khz = 0) {
    auto fake = std::make_unique<FakeDrm>();
    fake->htotal = htotal;
    fake->vtotal = vtotal;
    fake->clock_khz = clock_khz;
    drm = fake.get();
    device = std::make_unique<DrmSwtconDevice>(std::move(fake));
    EXPECT_EQ(device->open(DrmSwtconDevice::Config{}), kPlutoStatusOk);
  }

  bool configure(const ScanLoopConfig& config = ScanLoopConfig{}) {
    return loop.configure(device.get(), &clock, config);
  }

  // FakeDrm fb ids are 2001..2016 in buffer order.
  std::uint32_t fb_of(std::size_t buffer_index) const {
    return device->buffers()[buffer_index].fb_id;
  }
};

TEST(ScanLoopTest, DerivesPeriodFromEnumeratedModeWithFallback) {
  // 85.01 Hz-shaped timings: 400 x 1730 @ 58827 kHz.
  Harness with_mode(400, 1730, 58827);
  ASSERT_TRUE(with_mode.configure());
  const std::uint64_t pixels = 400ull * 1730ull;
  const std::uint64_t expected = (pixels * 1000000ull + 58827 / 2) / 58827;
  EXPECT_EQ(with_mode.loop.period_ns(), expected);
  // ~85 Hz sanity: between 11.5 ms and 12.0 ms.
  EXPECT_GT(with_mode.loop.period_ns(), 11500000ull);
  EXPECT_LT(with_mode.loop.period_ns(), 12000000ull);

  // No timings in the enumerated mode: round(1e9 / 85).
  Harness fallback;
  ASSERT_TRUE(fallback.configure());
  EXPECT_EQ(fallback.loop.period_ns(), 11764706ull);

  // Explicit config wins.
  ScanLoopConfig config;
  config.scan_period_ns = 5000000;
  Harness pinned;
  ASSERT_TRUE(pinned.configure(config));
  EXPECT_EQ(pinned.loop.period_ns(), 5000000ull);
}

// Cadence: the production thread flips at ABSOLUTE mode-period deadlines
// (zero drift) on the injected clock.
TEST(ScanLoopTest, ThreadedLoopRunsAtAbsoluteModePeriodDeadlines) {
  Harness harness(400, 1730, 58827);
  ASSERT_TRUE(harness.configure());
  const std::uint64_t period = harness.loop.period_ns();
  harness.clock.set_now(1000);

  ASSERT_TRUE(harness.loop.start());
  while (harness.loop.stats().ticks < 6) {
    std::this_thread::yield();
  }
  harness.loop.stop();

  const std::vector<std::uint64_t> deadlines = harness.clock.deadlines();
  ASSERT_GE(deadlines.size(), 5u);
  for (std::size_t i = 0; i < 5; ++i) {
    // deadline_k = start + (k+1) * period, exactly: absolute deadlines
    // accumulate from the initial now, never from wake time.
    EXPECT_EQ(deadlines[i], 1000 + (i + 1) * period) << "tick " << i;
  }
  EXPECT_EQ(harness.loop.stats().flip_failures, 0u);
}

// Missed deadline: nothing published for this tick => HOLD flip;
// with the engine active it is a pause — notify so the engine charges
// k_pause stress and does NOT advance fnum.
TEST(ScanLoopTest, MissedBuildFlipsHoldAndNotifiesPause) {
  Harness harness;
  ASSERT_TRUE(harness.configure());
  std::uint64_t pause_calls = 0;
  bool engine_active = true;
  harness.loop.set_on_pause([&pause_calls] { ++pause_calls; });
  harness.loop.set_engine_active([&engine_active] { return engine_active; });
  std::vector<std::uint64_t> tick_seqs;
  harness.loop.set_on_tick(
      [&tick_seqs](std::uint64_t seq) { tick_seqs.push_back(seq); });

  // Tick with no ready slot: HOLD (buffer 15) + pause.
  ASSERT_TRUE(harness.loop.tick());
  EXPECT_EQ(harness.drm->last_flipped_fb(),
            harness.fb_of(kDrmBufferCount - 1));
  EXPECT_EQ(harness.loop.stats().pauses, 1u);
  EXPECT_EQ(pause_calls, 1u);

  // Engine publishes frame 1 on buffer 3: scanned, no pause. pending() is
  // the engine's 1-deep build gate: true until the scan takes the plane
  // (building again before that would overwrite an unscanned plane).
  harness.loop.ready_slot().publish(3, 1);
  EXPECT_TRUE(harness.loop.ready_slot().pending());
  ASSERT_TRUE(harness.loop.tick());
  EXPECT_FALSE(harness.loop.ready_slot().pending());
  EXPECT_EQ(harness.drm->last_flipped_fb(), harness.fb_of(3));
  EXPECT_EQ(harness.loop.stats().flips, 1u);
  EXPECT_EQ(harness.loop.stats().pauses, 1u);
  EXPECT_EQ(pause_calls, 1u);

  // Same seq again = stale: HOLD again, another pause.
  ASSERT_TRUE(harness.loop.tick());
  EXPECT_EQ(harness.drm->last_flipped_fb(),
            harness.fb_of(kDrmBufferCount - 1));
  EXPECT_EQ(harness.loop.stats().pauses, 2u);

  // Idle engine: parking on HOLD is free (no pause).
  engine_active = false;
  ASSERT_TRUE(harness.loop.tick());
  EXPECT_EQ(harness.loop.stats().pauses, 2u);
  EXPECT_EQ(pause_calls, 2u);

  // Scan-tick publication: monotonically increasing seq per tick.
  ASSERT_EQ(tick_seqs.size(), 4u);
  for (std::size_t i = 0; i < tick_seqs.size(); ++i) {
    EXPECT_EQ(tick_seqs[i], i + 1);
  }
}

// Taking a ScanReadySlot only frees the producer's 1-deep build gate. Optical
// completion requires the matching DRM page-flip event; withhold that event to
// pin the distinction deterministically.
TEST(ScanLoopTest, ReadySlotRemainsUnacknowledgedUntilFlipEvent) {
  Harness harness;
  ASSERT_TRUE(harness.configure());
  std::vector<std::uint64_t> latched;
  harness.loop.set_on_latched(
      [&latched](std::uint64_t seq) { latched.push_back(seq); });

  harness.drm->deliver_events = false;
  harness.loop.ready_slot().publish(3, 1);
  EXPECT_TRUE(harness.loop.ready_slot().pending());
  EXPECT_TRUE(harness.loop.ready_slot().unacknowledged());

  ASSERT_TRUE(harness.loop.tick());
  EXPECT_FALSE(harness.loop.ready_slot().pending())
      << "scan take must free the producer build gate";
  EXPECT_TRUE(harness.loop.ready_slot().unacknowledged())
      << "take/commit without a flip event is not a glass latch";
  EXPECT_TRUE(latched.empty());

  harness.drm->deliver_events = true;
  ASSERT_TRUE(harness.loop.tick());  // drains the held content event
  EXPECT_FALSE(harness.loop.ready_slot().unacknowledged());
  ASSERT_EQ(latched.size(), 1u);
  EXPECT_EQ(latched[0], 1u);
}

TEST(ScanLoopTest, FeedbackUsesFollowingHoldToResolveContentLatch) {
  Harness harness;
  ASSERT_TRUE(harness.configure());
  std::vector<ScanFeedback> feedback;
  harness.loop.set_on_feedback(
      [&feedback](const ScanFeedback& value) { feedback.push_back(value); });

  harness.loop.ready_slot().publish(4, 17);
  ASSERT_TRUE(harness.loop.tick());
  ASSERT_EQ(feedback.size(), 1u);
  EXPECT_EQ(feedback[0].latched_buffer_index, 4u);
  EXPECT_EQ(feedback[0].latched_engine_seq, 17u);
  EXPECT_TRUE(feedback[0].latched_scan_known);
  EXPECT_FALSE(feedback[0].previous_flip_valid);
  EXPECT_FALSE(feedback[0].previous_scan_count_known);
  EXPECT_FALSE(feedback[0].previous_content_resolved);

  // The following HOLD completion is still observable even though the legacy
  // latch callback excludes HOLD. It resolves content seq 17 with zero extra
  // scans after the cadence gap has been classified.
  ASSERT_TRUE(harness.loop.tick());
  ASSERT_EQ(feedback.size(), 2u);
  EXPECT_EQ(feedback[1].latched_buffer_index,
            static_cast<std::uint32_t>(kDrmBufferCount - 1));
  EXPECT_EQ(feedback[1].latched_engine_seq, 0u);
  EXPECT_TRUE(feedback[1].latched_scan_known);
  EXPECT_TRUE(feedback[1].previous_flip_valid);
  EXPECT_TRUE(feedback[1].previous_scan_count_known);
  EXPECT_TRUE(feedback[1].previous_content_resolved);
  EXPECT_EQ(feedback[1].previous_buffer_index, 4u);
  EXPECT_EQ(feedback[1].previous_engine_seq, 17u);
  EXPECT_EQ(feedback[1].previous_extra_scans, 0u);

  // A preceding HOLD is never presented as a content resolution.
  ASSERT_TRUE(harness.loop.tick());
  ASSERT_EQ(feedback.size(), 3u);
  EXPECT_TRUE(feedback[2].previous_flip_valid);
  EXPECT_TRUE(feedback[2].previous_scan_count_known);
  EXPECT_EQ(feedback[2].previous_engine_seq, 0u);
  EXPECT_FALSE(feedback[2].previous_content_resolved);
}

TEST(ScanLoopTest, NonMonotonicEventNamesUnresolvedPriorContent) {
  Harness harness;
  ASSERT_TRUE(harness.configure());
  std::vector<ScanFeedback> feedback;
  harness.loop.set_on_feedback(
      [&feedback](const ScanFeedback& value) { feedback.push_back(value); });

  harness.loop.ready_slot().publish(2, 50);
  ASSERT_TRUE(harness.loop.tick());
  // Equal DRM sequence: the next content latch is real, but the previous
  // plane's extra-scan count cannot be classified. Its identity must remain
  // visible so a consumer can fail closed instead of waiting forever.
  harness.drm->next_sequence_step = 0;
  harness.loop.ready_slot().publish(3, 51);
  ASSERT_TRUE(harness.loop.tick());

  ASSERT_EQ(feedback.size(), 2u);
  EXPECT_EQ(feedback[1].latched_engine_seq, 51u);
  EXPECT_TRUE(feedback[1].latched_scan_known);
  EXPECT_TRUE(feedback[1].previous_flip_valid);
  EXPECT_EQ(feedback[1].previous_buffer_index, 2u);
  EXPECT_EQ(feedback[1].previous_engine_seq, 50u);
  EXPECT_FALSE(feedback[1].previous_scan_count_known);
  EXPECT_FALSE(feedback[1].previous_content_resolved);
  EXPECT_EQ(feedback[1].previous_extra_scans, 0u);
}

TEST(ScanLoopTest, FeedbackRunsAfterLatchAndDoubleScanButBeforeTick) {
  Harness harness;
  ASSERT_TRUE(harness.configure());
  std::vector<std::string> calls;
  harness.loop.set_on_latched([&calls](std::uint64_t seq) {
    calls.push_back("latch:" + std::to_string(seq));
  });
  harness.loop.set_on_double_scan(
      [&calls](std::uint32_t, std::uint64_t seq, std::uint32_t extra) {
        calls.push_back("double:" + std::to_string(seq) + "+" +
                        std::to_string(extra));
      });
  harness.loop.set_on_feedback([&calls](const ScanFeedback& feedback) {
    std::string value =
        "feedback:" + std::to_string(feedback.latched_engine_seq) + ":";
    if (feedback.previous_content_resolved) {
      value += std::to_string(feedback.previous_engine_seq) + "+" +
               std::to_string(feedback.previous_extra_scans);
    } else {
      value += "-";
    }
    calls.push_back(std::move(value));
  });
  harness.loop.set_on_tick([&calls](std::uint64_t seq) {
    calls.push_back("tick:" + std::to_string(seq));
  });

  harness.loop.ready_slot().publish(1, 1);
  ASSERT_TRUE(harness.loop.tick());
  harness.loop.ready_slot().publish(2, 2);
  ASSERT_TRUE(harness.loop.tick());  // establishes steady gap 1
  harness.drm->next_sequence_step = 2;
  harness.loop.ready_slot().publish(3, 3);
  ASSERT_TRUE(harness.loop.tick());  // resolves seq 2 with one extra scan

  const std::vector<std::string> expected = {
      "latch:1",      "feedback:1:-",   "tick:1",
      "latch:2",      "feedback:2:1+0", "tick:2",
      "latch:3",      "double:2+1",     "feedback:3:2+1",
      "tick:3",
  };
  ASSERT_EQ(calls.size(), expected.size());
  for (std::size_t i = 0; i < expected.size(); ++i) {
    EXPECT_EQ(calls[i], expected[i]) << "callback index " << i;
  }
}

TEST(ScanLoopTest, CoalescedEventsPreserveEngineSeqAcrossSlotReuse) {
  Harness harness;
  ASSERT_TRUE(harness.configure());
  std::vector<std::uint64_t> latched;
  std::vector<ScanFeedback> feedback;
  harness.loop.set_on_latched(
      [&latched](std::uint64_t seq) { latched.push_back(seq); });
  harness.loop.set_on_feedback(
      [&feedback](const ScanFeedback& value) { feedback.push_back(value); });

  // Hold three completions in the DRM mock. Buffer 5 is deliberately reused
  // with a newer engine seq after its first plane has been taken but before
  // either page-flip event is acknowledged.
  harness.drm->deliver_events = false;
  harness.loop.ready_slot().publish(5, 100);
  ASSERT_TRUE(harness.loop.tick());
  harness.loop.ready_slot().publish(5, 101);
  ASSERT_TRUE(harness.loop.tick());
  harness.loop.ready_slot().publish(6, 102);
  ASSERT_TRUE(harness.loop.tick());
  EXPECT_TRUE(latched.empty());
  EXPECT_TRUE(feedback.empty());

  // This HOLD queues a fourth event and one drain returns the coalesced batch.
  harness.drm->deliver_events = true;
  ASSERT_TRUE(harness.loop.tick());
  ASSERT_EQ(latched.size(), 3u);
  EXPECT_EQ(latched[0], 100u);
  EXPECT_EQ(latched[1], 101u);
  EXPECT_EQ(latched[2], 102u);
  ASSERT_EQ(feedback.size(), 4u);
  EXPECT_EQ(feedback[0].latched_buffer_index, 5u);
  EXPECT_EQ(feedback[0].latched_engine_seq, 100u);
  EXPECT_TRUE(feedback[0].latched_scan_known);
  EXPECT_FALSE(feedback[0].previous_flip_valid);
  EXPECT_FALSE(feedback[0].previous_content_resolved);
  EXPECT_EQ(feedback[1].latched_buffer_index, 5u);
  EXPECT_EQ(feedback[1].latched_engine_seq, 101u);
  EXPECT_TRUE(feedback[1].latched_scan_known);
  EXPECT_TRUE(feedback[1].previous_scan_count_known);
  EXPECT_TRUE(feedback[1].previous_content_resolved);
  EXPECT_EQ(feedback[1].previous_engine_seq, 100u);
  EXPECT_EQ(feedback[2].latched_buffer_index, 6u);
  EXPECT_EQ(feedback[2].latched_engine_seq, 102u);
  EXPECT_TRUE(feedback[2].latched_scan_known);
  EXPECT_TRUE(feedback[2].previous_scan_count_known);
  EXPECT_TRUE(feedback[2].previous_content_resolved);
  EXPECT_EQ(feedback[2].previous_engine_seq, 101u);
  EXPECT_EQ(feedback[3].latched_engine_seq, 0u);
  EXPECT_TRUE(feedback[3].latched_scan_known);
  EXPECT_TRUE(feedback[3].previous_scan_count_known);
  EXPECT_TRUE(feedback[3].previous_content_resolved);
  EXPECT_EQ(feedback[3].previous_engine_seq, 102u);
  EXPECT_FALSE(harness.loop.ready_slot().unacknowledged());
}

TEST(ScanLoopTest, SkippedCoalescedCookieFailsClosedInOrder) {
  Harness harness;
  ASSERT_TRUE(harness.configure());
  std::vector<std::uint64_t> latched;
  std::vector<ScanFeedback> feedback;
  harness.loop.set_on_latched(
      [&latched](std::uint64_t seq) { latched.push_back(seq); });
  harness.loop.set_on_feedback(
      [&feedback](const ScanFeedback& value) { feedback.push_back(value); });

  harness.drm->deliver_events = false;
  harness.loop.ready_slot().publish(1, 200);
  ASSERT_TRUE(harness.loop.tick());
  harness.loop.ready_slot().publish(2, 201);
  ASSERT_TRUE(harness.loop.tick());
  {
    std::lock_guard<std::mutex> lock(harness.drm->mutex);
    ASSERT_EQ(harness.drm->pending_events.size(), 2u);
    // Simulate DRM coalescing away the older cookie while retaining the newer
    // completion. The newer completion proves ordering, but cannot recover an
    // exact sequence gap for the skipped plane.
    harness.drm->pending_events.erase(harness.drm->pending_events.begin());
  }
  harness.drm->deliver_events = true;
  ASSERT_TRUE(harness.loop.tick());  // also queues the following HOLD event

  ASSERT_EQ(latched.size(), 1u);
  EXPECT_EQ(latched[0], 201u);  // preserve the legacy callback contract
  ASSERT_EQ(feedback.size(), 3u);

  // The skipped content plane is still surfaced as the first ordered latch.
  EXPECT_EQ(feedback[0].latched_buffer_index, 1u);
  EXPECT_EQ(feedback[0].latched_engine_seq, 200u);
  EXPECT_FALSE(feedback[0].latched_scan_known);
  EXPECT_FALSE(feedback[0].previous_flip_valid);

  // The matching newer event names seq 200 as its prior, but cannot claim an
  // extra-scan count. A history consumer can now invalidate seq 200.
  EXPECT_EQ(feedback[1].latched_buffer_index, 2u);
  EXPECT_EQ(feedback[1].latched_engine_seq, 201u);
  EXPECT_TRUE(feedback[1].latched_scan_known);
  EXPECT_TRUE(feedback[1].previous_flip_valid);
  EXPECT_EQ(feedback[1].previous_buffer_index, 1u);
  EXPECT_EQ(feedback[1].previous_engine_seq, 200u);
  EXPECT_FALSE(feedback[1].previous_scan_count_known);
  EXPECT_FALSE(feedback[1].previous_content_resolved);

  // The following real HOLD event has an anchored gap and resolves seq 201.
  EXPECT_EQ(feedback[2].latched_engine_seq, 0u);
  EXPECT_TRUE(feedback[2].latched_scan_known);
  EXPECT_TRUE(feedback[2].previous_scan_count_known);
  EXPECT_TRUE(feedback[2].previous_content_resolved);
  EXPECT_EQ(feedback[2].previous_engine_seq, 201u);
  EXPECT_EQ(feedback[2].previous_extra_scans, 0u);
  EXPECT_FALSE(harness.loop.ready_slot().unacknowledged());
}

TEST(ScanLoopTest, EventlessBlockingFlipsEmitOrderedZeroExtraFeedback) {
  Harness harness;
  ScanLoopConfig config;
  config.consume_flip_events = false;
  ASSERT_TRUE(harness.configure(config));

  std::vector<std::string> calls;
  int double_scans = 0;
  harness.loop.set_on_latched([&calls](std::uint64_t seq) {
    calls.push_back("latch:" + std::to_string(seq));
  });
  harness.loop.set_on_double_scan(
      [&double_scans](std::uint32_t, std::uint64_t, std::uint32_t) {
        ++double_scans;
      });
  harness.loop.set_on_feedback([&calls](const ScanFeedback& feedback) {
    EXPECT_TRUE(feedback.latched_scan_known);
    std::string value =
        "feedback:" + std::to_string(feedback.latched_engine_seq) + ":";
    value += feedback.previous_content_resolved
                 ? std::to_string(feedback.previous_engine_seq) + "+" +
                       std::to_string(feedback.previous_extra_scans)
                 : "-";
    calls.push_back(std::move(value));
  });
  harness.loop.set_on_tick([&calls](std::uint64_t seq) {
    calls.push_back("tick:" + std::to_string(seq));
  });

  harness.loop.ready_slot().publish(2, 7);
  ASSERT_TRUE(harness.loop.tick());
  EXPECT_FALSE(harness.loop.ready_slot().unacknowledged());
  ASSERT_TRUE(harness.loop.tick());  // blocking HOLD resolves seq 7

  const std::vector<std::string> expected = {
      "latch:7", "feedback:7:-", "tick:1", "feedback:0:7+0", "tick:2"};
  ASSERT_EQ(calls.size(), expected.size());
  for (std::size_t i = 0; i < expected.size(); ++i) {
    EXPECT_EQ(calls[i], expected[i]) << "callback index " << i;
  }
  EXPECT_EQ(double_scans, 0);
}

TEST(ScanLoopTest, UnknownCookieSurfacesPendingContentAndHoldFailClosed) {
  Harness harness;
  ASSERT_TRUE(harness.configure());
  std::vector<std::uint64_t> latched;
  std::vector<ScanFeedback> feedback;
  harness.loop.set_on_latched(
      [&latched](std::uint64_t seq) { latched.push_back(seq); });
  harness.loop.set_on_feedback(
      [&feedback](const ScanFeedback& value) { feedback.push_back(value); });

  // Hold a content completion and its following HOLD. Replace only the first
  // returned cookie with an unknown value. The subsequent tick queues one more
  // HOLD before draining, so the unknown event must invalidate/surface all
  // three pending identities in their submission order.
  harness.drm->deliver_events = false;
  harness.loop.ready_slot().publish(7, 300);
  ASSERT_TRUE(harness.loop.tick());
  ASSERT_TRUE(harness.loop.tick());
  {
    std::lock_guard<std::mutex> lock(harness.drm->mutex);
    ASSERT_EQ(harness.drm->pending_events.size(), 2u);
    harness.drm->pending_events[0].user_data = 0xdeadbeefULL;
  }
  harness.drm->deliver_events = true;
  ASSERT_TRUE(harness.loop.tick());

  // Preserve the legacy positive-evidence contract: an unknown cookie fires
  // neither on_latched nor the ready-slot acknowledgement.
  EXPECT_TRUE(latched.empty());
  EXPECT_TRUE(harness.loop.ready_slot().unacknowledged());
  ASSERT_EQ(feedback.size(), 3u);

  EXPECT_EQ(feedback[0].latched_buffer_index, 7u);
  EXPECT_EQ(feedback[0].latched_engine_seq, 300u);
  EXPECT_FALSE(feedback[0].latched_scan_known);
  EXPECT_FALSE(feedback[0].previous_flip_valid);

  EXPECT_EQ(feedback[1].latched_buffer_index,
            static_cast<std::uint32_t>(kDrmBufferCount - 1));
  EXPECT_EQ(feedback[1].latched_engine_seq, 0u);
  EXPECT_FALSE(feedback[1].latched_scan_known);
  EXPECT_TRUE(feedback[1].previous_flip_valid);
  EXPECT_EQ(feedback[1].previous_engine_seq, 300u);
  EXPECT_FALSE(feedback[1].previous_scan_count_known);
  EXPECT_FALSE(feedback[1].previous_content_resolved);

  EXPECT_EQ(feedback[2].latched_buffer_index,
            static_cast<std::uint32_t>(kDrmBufferCount - 1));
  EXPECT_EQ(feedback[2].latched_engine_seq, 0u);
  EXPECT_FALSE(feedback[2].latched_scan_known);
  EXPECT_TRUE(feedback[2].previous_flip_valid);
  EXPECT_EQ(feedback[2].previous_engine_seq, 0u);
  EXPECT_FALSE(feedback[2].previous_scan_count_known);
  EXPECT_FALSE(feedback[2].previous_content_resolved);
}

// Double-scan injection: a vblank-sequence gap between consecutive flip
// completions means the PREVIOUS plane was latched for an extra scan; the
// callback carries that plane so the engine can re-charge its exact
// impulse.
TEST(ScanLoopTest, DoubleScanInjectionFiresCallbackWithRescannedPlane) {
  Harness harness;
  ASSERT_TRUE(harness.configure());
  struct DoubleScan {
    std::uint32_t buffer_index;
    std::uint64_t engine_seq;
    std::uint32_t extra;
  };
  std::vector<DoubleScan> double_scans;
  harness.loop.set_on_double_scan(
      [&double_scans](std::uint32_t buffer_index, std::uint64_t engine_seq,
                      std::uint32_t extra) {
        double_scans.push_back({buffer_index, engine_seq, extra});
      });

  // Flip 0 establishes the event sequence; flip 1 observes the steady
  // gap (1) — the learned cadence baseline.
  harness.loop.ready_slot().publish(1, 1);
  ASSERT_TRUE(harness.loop.tick());
  harness.loop.ready_slot().publish(2, 2);
  ASSERT_TRUE(harness.loop.tick());
  EXPECT_EQ(double_scans.size(), 0u);

  // The next flip latches TWO vblanks later (gap above the learned
  // cadence): buffer 2's plane got rescanned.
  harness.drm->next_sequence_step = 2;
  harness.loop.ready_slot().publish(3, 3);
  ASSERT_TRUE(harness.loop.tick());
  ASSERT_EQ(double_scans.size(), 1u);
  EXPECT_EQ(double_scans[0].buffer_index, 2u);
  EXPECT_EQ(double_scans[0].engine_seq, 2u);
  EXPECT_EQ(double_scans[0].extra, 1u);
  EXPECT_EQ(harness.loop.stats().double_scans, 1u);

  // Back to consecutive latches: no further reports.
  harness.drm->next_sequence_step = 1;
  harness.loop.ready_slot().publish(4, 4);
  ASSERT_TRUE(harness.loop.tick());
  EXPECT_EQ(double_scans.size(), 1u);
}

// HOLD-gap exemption (device livelock fix): the vblank sequence free-runs
// at the hardware rate while flips ride software deadlines, so latches
// ROUTINELY gap by >= 2 from scheduling jitter alone. A gap after a HOLD
// latch means the BLANK SCAFFOLD was rescanned — zero ops by construction
// (the L0 goldens pin HOLD-slot blankness) — so it needs no
// recharge: counted in hold_rescans, NO on_double_scan, nothing queued.
// Only content-plane rescans (engine_seq != 0) report and recharge.
TEST(ScanLoopTest, HoldRescanGapsAreCountedButNeverReported) {
  Harness harness;
  ASSERT_TRUE(harness.configure());
  int callbacks = 0;
  std::uint32_t last_buffer = 0;
  std::vector<ScanFeedback> feedback;
  harness.loop.set_on_double_scan(
      [&callbacks, &last_buffer](std::uint32_t buffer_index, std::uint64_t,
                                 std::uint32_t) {
        ++callbacks;
        last_buffer = buffer_index;
      });
  harness.loop.set_on_feedback(
      [&feedback](const ScanFeedback& value) { feedback.push_back(value); });

  // Latch 1: HOLD (nothing published) — establishes the event sequence.
  ASSERT_TRUE(harness.loop.tick());
  // Latch 2 observes the steady gap (1) — the learned cadence baseline.
  ASSERT_TRUE(harness.loop.tick());
  // Latch 3 arrives two vblanks later: the rescanned plane is the HOLD
  // scaffold. Counted, never reported.
  harness.drm->next_sequence_step = 2;
  ASSERT_TRUE(harness.loop.tick());
  EXPECT_EQ(callbacks, 0);
  EXPECT_EQ(harness.loop.stats().hold_rescans, 1u);
  EXPECT_EQ(harness.loop.stats().double_scans, 0u);

  // Content plane latches next (the gap before it still belongs to the
  // HOLD scaffold)...
  harness.loop.ready_slot().publish(2, 1);
  ASSERT_TRUE(harness.loop.tick());
  EXPECT_EQ(callbacks, 0);
  EXPECT_EQ(harness.loop.stats().hold_rescans, 2u);
  EXPECT_EQ(harness.loop.stats().double_scans, 0u);

  // ...and the NEXT gap is a real content rescan: reported for recharge.
  ASSERT_TRUE(harness.loop.tick());
  EXPECT_EQ(callbacks, 1);
  EXPECT_EQ(last_buffer, 2u);
  EXPECT_EQ(harness.loop.stats().double_scans, 1u);
  EXPECT_EQ(harness.loop.stats().hold_rescans, 2u);
  ASSERT_EQ(feedback.size(), 5u);
  for (std::size_t i = 0; i < 4; ++i) {
    EXPECT_FALSE(feedback[i].previous_content_resolved) << "feedback " << i;
  }
  EXPECT_FALSE(feedback[0].previous_flip_valid);
  for (std::size_t i = 1; i < 5; ++i) {
    EXPECT_TRUE(feedback[i].previous_flip_valid) << "feedback " << i;
    EXPECT_TRUE(feedback[i].previous_scan_count_known) << "feedback " << i;
  }
  EXPECT_TRUE(feedback[4].previous_content_resolved);
  EXPECT_EQ(feedback[4].previous_engine_seq, 1u);
  EXPECT_EQ(feedback[4].previous_extra_scans, 1u);
}

// Park sequence: after the last published frame the scan parks on HOLD —
// and the HOLD slot's plane is the blank scaffold, byte-exact
// (always-blank by construction, primed at configure()).
TEST(ScanLoopTest, ParksOnHoldSlotWhoseBytesAreTheBlankTemplate) {
  Harness harness;
  ASSERT_TRUE(harness.configure());

  // One real frame, then idle.
  harness.loop.ready_slot().publish(1, 1);
  ASSERT_TRUE(harness.loop.tick());
  for (int i = 0; i < 3; ++i) {
    ASSERT_TRUE(harness.loop.tick());
  }
  EXPECT_EQ(harness.drm->last_flipped_fb(),
            harness.fb_of(kDrmBufferCount - 1));
  EXPECT_EQ(harness.loop.stats().hold_flips, 3u);
  EXPECT_EQ(harness.loop.stats().pauses, 0u);  // no engine_active hook: idle

  // Buffer 15's mapped bytes == init_blank_phase_frame output.
  std::vector<std::uint16_t> expected(kDrmPhaseWords, 0);
  pluto::swtcon::init_blank_phase_frame(expected.data());
  const auto& hold = harness.device->buffers()[kDrmBufferCount - 1];
  ASSERT_TRUE(hold.map != nullptr);
  EXPECT_EQ(std::memcmp(hold.map, expected.data(),
                        kDrmPhaseWords * sizeof(std::uint16_t)),
            0);
}

TEST(ScanLoopTest, RejectsInvalidConfiguration) {
  Harness harness;
  FakeClock clock;
  ScanLoop loop;
  EXPECT_FALSE(loop.configure(nullptr, &clock, ScanLoopConfig{}));
  EXPECT_FALSE(loop.configure(harness.device.get(), nullptr,
                              ScanLoopConfig{}));
  ScanLoopConfig bad;
  bad.hold_slot = kDrmBufferCount;  // out of range
  EXPECT_FALSE(loop.configure(harness.device.get(), &clock, bad));
  EXPECT_FALSE(loop.tick());  // unconfigured
}

}  // namespace
