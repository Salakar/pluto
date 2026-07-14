// VsyncPacer pacing rule (token bucket): isolated frames fire immediately;
// a sustained stream is granted exactly one frame per interval, anchored to
// the previous grant. The old rule charged EVERY request a full
// `now + interval` wait — a flat 33 ms of dead time on the first frame of
// every pen stroke, tap, and animation start at the default device cap.

#include <gtest/gtest.h>

#include <algorithm>
#include <cstdint>
#include <thread>
#include <vector>

#include "runtime/vsync_pacer.h"

namespace {

constexpr uint64_t kInterval = 33'000'000;  // 33 ms device default

struct VsyncGrant {
  intptr_t baton = 0;
  uint64_t start = 0;
  uint64_t target = 0;
};

std::vector<VsyncGrant> g_grants;
uint64_t g_now_ns = 0;

uint64_t fake_current_time() { return g_now_ns; }

FlutterEngineResult capture_vsync(FlutterEngine, intptr_t baton,
                                  uint64_t start, uint64_t target) {
  g_grants.push_back(VsyncGrant{baton, start, target});
  return kSuccess;
}

FlutterEngineProcTable capture_procs() {
  FlutterEngineProcTable procs{};
  procs.struct_size = sizeof(procs);
  procs.OnVsync = &capture_vsync;
  return procs;
}

FlutterEngineProcTable capture_procs_with_clock() {
  FlutterEngineProcTable procs = capture_procs();
  procs.GetCurrentTime = &fake_current_time;
  return procs;
}

}  // namespace

TEST(VsyncPacerTest, FirstRequestFiresImmediately) {
  EXPECT_EQ(pluto::VsyncPacer::next_target_ns(1'000'000, 0, kInterval),
            1'000'000u);
}

TEST(VsyncPacerTest, IsolatedRequestAfterIdleFiresImmediately) {
  // Previous grant long past: no pacing debt to pay.
  const uint64_t last = 10 * kInterval;
  const uint64_t start = last + kInterval + 1;
  EXPECT_EQ(pluto::VsyncPacer::next_target_ns(start, last, kInterval),
            start);
}

TEST(VsyncPacerTest, SustainedStreamPacesAtExactlyOneFramePerInterval) {
  // Requests arriving immediately after each grant (saturated animation):
  // grants land on an exact interval grid with no drift — the same cap
  // rate as before, minus the raster-time drift of the old now+interval.
  uint64_t last = 0;
  uint64_t now = 5'000'000;
  for (int frame = 0; frame < 10; ++frame) {
    const uint64_t target =
        pluto::VsyncPacer::next_target_ns(now, last, kInterval);
    if (last != 0) {
      EXPECT_EQ(target, last + kInterval) << "frame " << frame;
    }
    last = target;
    now = target + 1'000'000;  // next request 1 ms after the grant
  }
}

TEST(VsyncPacerTest, UncappedIntervalAlwaysImmediate) {
  EXPECT_EQ(pluto::VsyncPacer::next_target_ns(42, 40, 0), 42u);
}

TEST(VsyncPacerTest, SubRateStreamNeverWaits) {
  // Frames arriving slower than the cap (e.g. pen samples driving ~20 fps
  // redraws under a 30 fps cap) each fire immediately.
  uint64_t last = 0;
  uint64_t now = 1'000'000;
  for (int frame = 0; frame < 5; ++frame) {
    const uint64_t target =
        pluto::VsyncPacer::next_target_ns(now, last, kInterval);
    EXPECT_EQ(target, now) << "frame " << frame;
    last = target;
    now += kInterval + 5'000'000;  // 38 ms cadence: below the cap
  }
}

TEST(VsyncPacerTest, HoverBeforeFirstRequestUsesOneScanFrameTargetImmediately) {
  g_grants.clear();
  g_now_ns = 1'000'000'000;
  pluto::EventLoop loop;
  pluto::VsyncPacer pacer(&loop);
  FlutterEngineProcTable procs = capture_procs_with_clock();
  loop.set_engine(&procs, reinterpret_cast<FlutterEngine>(0x1));
  pacer.set_engine(&procs, reinterpret_cast<FlutterEngine>(0x1));
  pacer.set_interval_ns(24'000'000);

  pacer.set_pen_proximity(true);
  EXPECT_TRUE(pacer.pen_proximity());
  pacer.request(101);
  loop.run_due_tasks_for_test(g_now_ns);

  ASSERT_EQ(g_grants.size(), 1u);
  EXPECT_EQ(g_grants[0].baton, 101);
  EXPECT_EQ(g_grants[0].start, g_now_ns);
  EXPECT_EQ(g_grants[0].target - g_grants[0].start,
            pluto::VsyncPacer::kPenFrameIntervalNs);
}

TEST(VsyncPacerTest, HoverExpeditesBatonQueuedAtOrdinaryFrameCap) {
  g_grants.clear();
  g_now_ns = 2'000'000'000;
  pluto::EventLoop loop;
  pluto::VsyncPacer pacer(&loop);
  FlutterEngineProcTable procs = capture_procs_with_clock();
  loop.set_engine(&procs, reinterpret_cast<FlutterEngine>(0x1));
  pacer.set_engine(&procs, reinterpret_cast<FlutterEngine>(0x1));
  pacer.set_interval_ns(24'000'000);

  pacer.request(201);
  loop.run_due_tasks_for_test(g_now_ns);
  g_now_ns += 1'000'000;
  pacer.request(202);
  EXPECT_EQ(loop.run_due_tasks_for_test(g_now_ns), 0u)
      << "second ordinary frame should still be paying pacing debt";

  pacer.set_pen_proximity(true);
  loop.run_due_tasks_for_test(g_now_ns);
  ASSERT_EQ(g_grants.size(), 2u);
  EXPECT_EQ(g_grants[1].baton, 202);
  EXPECT_EQ(g_grants[1].start, g_now_ns);
  EXPECT_EQ(g_grants[1].target - g_grants[1].start,
            pluto::VsyncPacer::kPenFrameIntervalNs);
  g_now_ns += 1'000'000;
  pacer.request(203);
  EXPECT_EQ(loop.run_due_tasks_for_test(g_now_ns), 0u)
      << "the expedited grant must anchor sustained one-scan cadence";
  loop.run_due_tasks_for_test(UINT64_MAX);  // includes stale ordinary closure
  ASSERT_EQ(g_grants.size(), 3u);
  EXPECT_EQ(g_grants[2].start - g_grants[1].start,
            pluto::VsyncPacer::kPenFrameIntervalNs);
}

TEST(VsyncPacerTest, SustainedHoverUsesExactOneScanCadence) {
  g_grants.clear();
  g_now_ns = 3'000'000'000;
  pluto::EventLoop loop;
  pluto::VsyncPacer pacer(&loop);
  FlutterEngineProcTable procs = capture_procs_with_clock();
  loop.set_engine(&procs, reinterpret_cast<FlutterEngine>(0x1));
  pacer.set_engine(&procs, reinterpret_cast<FlutterEngine>(0x1));
  pacer.set_interval_ns(24'000'000);
  pacer.set_pen_proximity(true);

  pacer.request(301);
  loop.run_due_tasks_for_test(g_now_ns);
  ASSERT_EQ(g_grants.size(), 1u);
  const uint64_t first_start = g_grants.front().start;
  g_now_ns += 1'000'000;
  pacer.request(302);
  EXPECT_EQ(loop.run_due_tasks_for_test(g_now_ns), 0u);
  g_now_ns = first_start + pluto::VsyncPacer::kPenFrameIntervalNs;
  loop.run_due_tasks_for_test(g_now_ns);

  ASSERT_EQ(g_grants.size(), 2u);
  EXPECT_EQ(g_grants[1].start - g_grants[0].start,
            pluto::VsyncPacer::kPenFrameIntervalNs);
  EXPECT_EQ(g_grants[1].target - g_grants[1].start,
            pluto::VsyncPacer::kPenFrameIntervalNs);
}

TEST(VsyncPacerTest, LeavingRangeRestoresConfiguredCadenceWithNoOldDebt) {
  g_grants.clear();
  g_now_ns = 4'000'000'000;
  pluto::EventLoop loop;
  pluto::VsyncPacer pacer(&loop);
  FlutterEngineProcTable procs = capture_procs_with_clock();
  loop.set_engine(&procs, reinterpret_cast<FlutterEngine>(0x1));
  pacer.set_engine(&procs, reinterpret_cast<FlutterEngine>(0x1));
  constexpr uint64_t kConfigured = 24'000'000;
  pacer.set_interval_ns(kConfigured);
  pacer.set_pen_proximity(true);
  pacer.request(401);
  loop.run_due_tasks_for_test(g_now_ns);

  pacer.set_pen_proximity(false);
  EXPECT_FALSE(pacer.pen_proximity());
  g_now_ns += 1'000'000;
  pacer.request(402);
  loop.run_due_tasks_for_test(g_now_ns);
  ASSERT_EQ(g_grants.size(), 2u);
  EXPECT_EQ(g_grants[1].start, g_now_ns)
      << "exit must not carry proximity pacing debt";
  EXPECT_EQ(g_grants[1].target - g_grants[1].start, kConfigured);

  g_now_ns += 1'000'000;
  pacer.request(403);
  EXPECT_EQ(loop.run_due_tasks_for_test(g_now_ns), 0u);
  g_now_ns = g_grants[1].start + kConfigured;
  loop.run_due_tasks_for_test(g_now_ns);
  ASSERT_EQ(g_grants.size(), 3u);
  EXPECT_EQ(g_grants[2].start - g_grants[1].start, kConfigured);
}

TEST(VsyncPacerTest, RenderingPauseDefersOneBatonUntilResume) {
  g_grants.clear();
  pluto::EventLoop loop;
  pluto::VsyncPacer pacer(&loop);
  FlutterEngineProcTable procs = capture_procs();
  pacer.set_engine(&procs, reinterpret_cast<FlutterEngine>(0x1));

  pacer.set_rendering_paused(true);
  pacer.request(41);
  EXPECT_TRUE(pacer.rendering_paused());
  EXPECT_EQ(loop.run_due_tasks_for_test(UINT64_MAX), 0u);
  EXPECT_TRUE(g_grants.empty());

  pacer.set_rendering_paused(false);
  EXPECT_EQ(loop.run_due_tasks_for_test(UINT64_MAX), 1u);
  ASSERT_EQ(g_grants.size(), 1u);
  EXPECT_EQ(g_grants[0].baton, 41);
  EXPECT_LT(g_grants[0].start, g_grants[0].target);
}

TEST(VsyncPacerTest, PauseAfterSchedulingSuppressesGrantUntilResume) {
  g_grants.clear();
  pluto::EventLoop loop;
  pluto::VsyncPacer pacer(&loop);
  FlutterEngineProcTable procs = capture_procs();
  pacer.set_engine(&procs, reinterpret_cast<FlutterEngine>(0x1));

  pacer.request(7);
  pacer.set_rendering_paused(true);
  EXPECT_EQ(loop.run_due_tasks_for_test(UINT64_MAX), 1u);
  EXPECT_TRUE(g_grants.empty());

  pacer.set_rendering_paused(false);
  EXPECT_EQ(loop.run_due_tasks_for_test(UINT64_MAX), 1u);
  ASSERT_EQ(g_grants.size(), 1u);
  EXPECT_EQ(g_grants[0].baton, 7);
}

TEST(VsyncPacerTest, GrantReportsNextVsyncAsFrameTarget) {
  g_grants.clear();
  pluto::EventLoop loop;
  pluto::VsyncPacer pacer(&loop);
  FlutterEngineProcTable procs = capture_procs();
  pacer.set_engine(&procs, reinterpret_cast<FlutterEngine>(0x1));
  pacer.set_interval_ns(kInterval);

  pacer.request(8);
  loop.run_due_tasks_for_test(UINT64_MAX);
  ASSERT_EQ(g_grants.size(), 1u);
  EXPECT_EQ(g_grants[0].target - g_grants[0].start, kInterval);
}

TEST(VsyncPacerTest, RequestsWhilePausedAreAllReturnedOnResume) {
  g_grants.clear();
  pluto::EventLoop loop;
  pluto::VsyncPacer pacer(&loop);
  FlutterEngineProcTable procs = capture_procs();
  pacer.set_engine(&procs, reinterpret_cast<FlutterEngine>(0x1));

  pacer.set_rendering_paused(true);
  pacer.request(11);
  pacer.request(12);
  pacer.request(13);
  pacer.set_rendering_paused(false);
  loop.run_due_tasks_for_test(UINT64_MAX);

  ASSERT_EQ(g_grants.size(), 3u);
  EXPECT_EQ(g_grants[0].baton, 11);
  EXPECT_EQ(g_grants[1].baton, 12);
  EXPECT_EQ(g_grants[2].baton, 13);
}

TEST(VsyncPacerTest, FlushReturnsHeldAndAlreadyScheduledBatons) {
  g_grants.clear();
  pluto::EventLoop loop;
  pluto::VsyncPacer pacer(&loop);
  FlutterEngineProcTable procs = capture_procs();
  pacer.set_engine(&procs, reinterpret_cast<FlutterEngine>(0x1));

  pacer.request(20);
  pacer.set_rendering_paused(true);
  pacer.request(21);
  pacer.flush();
  ASSERT_EQ(g_grants.size(), 2u);
  EXPECT_EQ(g_grants[0].baton, 20);
  EXPECT_EQ(g_grants[1].baton, 21);
  pacer.set_rendering_paused(false);
  loop.run_due_tasks_for_test(UINT64_MAX);
  EXPECT_EQ(g_grants.size(), 2u);
}

TEST(VsyncPacerTest, ShutdownDrainCannotLoseConcurrentRequests) {
  g_grants.clear();
  pluto::EventLoop loop;
  pluto::VsyncPacer pacer(&loop);
  FlutterEngineProcTable procs = capture_procs();
  pacer.set_engine(&procs, reinterpret_cast<FlutterEngine>(0x1));
  pacer.begin_shutdown();

  constexpr intptr_t kCount = 256;
  std::thread requester([&] {
    for (intptr_t baton = 1; baton <= kCount; ++baton) {
      pacer.request(baton);
    }
  });
  // Race multiple platform-thread swaps with the internal callback source.
  for (int i = 0; i < 16; ++i) {
    pacer.flush();
  }
  requester.join();
  pacer.finish_shutdown();

  ASSERT_EQ(g_grants.size(), static_cast<size_t>(kCount));
  std::vector<intptr_t> batons;
  batons.reserve(g_grants.size());
  for (const VsyncGrant& grant : g_grants) {
    batons.push_back(grant.baton);
  }
  std::sort(batons.begin(), batons.end());
  for (intptr_t expected = 1; expected <= kCount; ++expected) {
    EXPECT_EQ(batons[static_cast<size_t>(expected - 1)], expected);
  }

  pacer.request(999);  // callback source is expected quiesced after finish
  EXPECT_EQ(g_grants.size(), static_cast<size_t>(kCount));
  EXPECT_EQ(loop.run_due_tasks_for_test(UINT64_MAX), 0u);
}
