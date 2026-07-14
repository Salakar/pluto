// RegionScheduler behavior suite (Stage 2).
//
// The first four tests re-pin the Stage-0 behavior contracts verbatim in
// semantics (requeue-exactly-once, no-damage-loss-when-declined,
// fast-never-blocks-behind-nonoverlapping-inflight, synchronous-completion
// -honored) against the RegionScheduler API — they landed BEFORE the
// EinkScheduler suite was deleted. The rest pins the new Stage-2 policy:
// newest-wins supersession, value-aware absorption, EDF ordering, CBS
// non-starvation, mode-gated merging, and the eventual-consistency
// property under random damage/decline sequences.

#include "renderer/region_scheduler.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <random>
#include <vector>

#include "renderer/rect_utils.h"

namespace {

using pluto::RegionPresenterHooks;
using pluto::RegionScheduler;
using pluto::RegionSchedulerConfig;
using pluto::RegionSchedulerState;

RegionSchedulerConfig test_config() {
  RegionSchedulerConfig config;
  config.width = 128;
  config.height = 128;
  config.align_px = 8;
  config.merge_gap_px = 16;
  config.fence_margin = 1.0f;
  config.fence_timeout_ms = 1000;
  config.latency_model_us = {1000, 2000, 3000, 4000};
  config.class_deadline_us = {25000, 60000, 150000, 300000};
  return config;
}

// Scriptable presenter: per-call present() verdicts, per-class readiness,
// full damage recording, optional synchronous completion from present().
struct ScriptedPresenter {
  struct Call {
    PlutoRefreshClass cls = kPlutoRefreshUi;
    uint32_t flags = 0;
    bool accepted = false;
    uint64_t frame_id = 0;
    std::vector<PlutoRect> damage;
  };

  std::vector<bool> present_results; // per-call verdicts; exhausted => true
  bool ready_value = true;
  bool text_ready = true;
  RegionScheduler *complete_during_present = nullptr;
  std::vector<Call> calls;

  static bool ready(void *user_data, PlutoRefreshClass cls) {
    auto *self = static_cast<ScriptedPresenter *>(user_data);
    if (!self->ready_value) {
      return false;
    }
    return cls != kPlutoRefreshText || self->text_ready;
  }

  static bool present(void *user_data, const PlutoPresentRequest *request) {
    auto *self = static_cast<ScriptedPresenter *>(user_data);
    Call call;
    call.cls = request->refresh_class;
    call.flags = request->flags;
    call.frame_id = request->frame_id;
    call.accepted = self->calls.size() >= self->present_results.size() ||
                    self->present_results[self->calls.size()];
    for (size_t i = 0; i < request->damage_count; ++i) {
      call.damage.push_back(request->damage[i]);
    }
    const bool accepted = call.accepted;
    self->calls.push_back(std::move(call));
    if (accepted && self->complete_during_present != nullptr) {
      self->complete_during_present->notify_completion(request->frame_id);
    }
    return accepted;
  }

  size_t accepted_count() const {
    size_t count = 0;
    for (const Call &call : calls) {
      count += call.accepted ? 1 : 0;
    }
    return count;
  }
};

RegionScheduler
make_scheduler(ScriptedPresenter *presenter,
               const RegionSchedulerConfig &config = test_config()) {
  RegionPresenterHooks hooks;
  hooks.user_data = presenter;
  hooks.ready = &ScriptedPresenter::ready;
  hooks.present = &ScriptedPresenter::present;
  return RegionScheduler(config, hooks);
}

bool rect_contains(const PlutoRect &outer, const PlutoRect &inner) {
  return inner.x >= outer.x && inner.y >= outer.y &&
         pluto::rect_right(inner) <= pluto::rect_right(outer) &&
         pluto::rect_bottom(inner) <= pluto::rect_bottom(outer);
}

size_t accepted_presents_covering(const ScriptedPresenter &presenter,
                                  const PlutoRect &target) {
  size_t count = 0;
  for (const ScriptedPresenter::Call &call : presenter.calls) {
    if (!call.accepted) {
      continue;
    }
    for (const PlutoRect &rect : call.damage) {
      if (rect_contains(rect, target)) {
        ++count;
        break;
      }
    }
  }
  return count;
}

void submit_one(RegionScheduler *scheduler, const PlutoRect &rect,
                PlutoRefreshClass cls, uint64_t now_us) {
  scheduler->submit_damage(&rect, &cls, 1, now_us);
}

} // namespace

// ---- re-pinned Stage-0 contracts -------------------------------------------

TEST(RegionSchedulerBehaviorTest, RequeuesExactlyOnceWhenPresentRefuses) {
  ScriptedPresenter presenter;
  presenter.present_results = {false}; // refuse only the first attempt
  RegionScheduler scheduler = make_scheduler(&presenter);

  const PlutoRect rect{0, 0, 16, 16};
  submit_one(&scheduler, rect, kPlutoRefreshFast, 0);
  scheduler.tick(0);
  ASSERT_EQ(presenter.calls.size(), 1u);
  EXPECT_FALSE(presenter.calls[0].accepted);

  scheduler.tick(200);
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_TRUE(presenter.calls[1].accepted);
  EXPECT_EQ(presenter.calls[1].damage.size(), 1u);

  // Once accepted, nothing may be left over to dispatch a second time:
  // exactly ONE accepted present covers the region across the whole run.
  for (uint64_t now = 2000; now <= 20000; now += 1000) {
    scheduler.tick(now);
  }
  EXPECT_EQ(presenter.accepted_count(), 1u);
  EXPECT_EQ(accepted_presents_covering(presenter, rect), 1u);
}

TEST(RegionSchedulerBehaviorTest, NoDamageLossWhenSiblingClassParksInSameTick) {
  ScriptedPresenter presenter;
  presenter.text_ready = false;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect fast{0, 0, 16, 16};
  submit_one(&scheduler, fast, kPlutoRefreshFast, 0);
  scheduler.tick(0); // fast is inflight until completed
  ASSERT_EQ(presenter.calls.size(), 1u);

  const PlutoRect ui{0, 0, 32, 32};     // overlaps the inflight fast rect
  const PlutoRect text{96, 96, 16, 16}; // unrelated to anything inflight
  submit_one(&scheduler, ui, kPlutoRefreshUi, 100);
  submit_one(&scheduler, text, kPlutoRefreshText, 100);
  // In this one tick the ui rect parks behind the inflight fast while the
  // text presenter is not ready.
  scheduler.tick(100);

  presenter.text_ready = true;
  scheduler.notify_completion(presenter.calls[0].frame_id);
  for (uint64_t now = 1000; now <= 20000; now += 1000) {
    scheduler.tick(now);
  }
  EXPECT_GE(accepted_presents_covering(presenter, text), 1u)
      << "text damage was dropped";
  EXPECT_GE(accepted_presents_covering(presenter, ui), 1u)
      << "parked ui damage was dropped";
}

TEST(RegionSchedulerBehaviorTest, FastNeverBlocksBehindNonOverlappingInflight) {
  ScriptedPresenter presenter;
  RegionScheduler scheduler = make_scheduler(&presenter);

  const PlutoRect ui{0, 0, 16, 16};
  submit_one(&scheduler, ui, kPlutoRefreshUi, 0);
  scheduler.tick(0); // ui is inflight until t=2000
  ASSERT_EQ(presenter.calls.size(), 1u);

  const PlutoRect fast{96, 96, 16, 16}; // clear of the ui drive rect
  submit_one(&scheduler, fast, kPlutoRefreshFast, 10);
  scheduler.tick(10); // ui still inflight: fast must dispatch, not park
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshFast);
  EXPECT_TRUE(presenter.calls[1].accepted);

  scheduler.submit_pen_damage(PlutoRect{40, 96, 8, 8}, PlutoRect{},
                              kPlutoRefreshText, 20);
  scheduler.tick(20); // the pen path gets the same guarantee
  ASSERT_EQ(presenter.calls.size(), 3u);
  EXPECT_EQ(presenter.calls[2].cls, kPlutoRefreshFast);
  EXPECT_TRUE((presenter.calls[2].flags & kPlutoPresentFlagInkPriority) != 0u);
}

TEST(RegionSchedulerBehaviorTest,
     LogicalSplitDamageStaysUnrotatedForNinetyDegreeBridge) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  // A logical 128x64 surface presented through a 90-degree AbiPresentBridge.
  // The former scheduler rotation mapped the right-hand rect below y=96 and
  // clipped it completely against logical height=64.
  config.width = 128;
  config.height = 64;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect logical_damage[] = {PlutoRect{96, 40, 24, 16},
                                      PlutoRect{0, 0, 16, 8}};
  const PlutoRefreshClass classes[] = {kPlutoRefreshFast, kPlutoRefreshFast};
  scheduler.submit_damage(logical_damage, classes, 2, 100);
  scheduler.tick(100);

  ASSERT_EQ(presenter.calls.size(), 1u);
  ASSERT_EQ(presenter.calls[0].damage.size(), 2u);
  EXPECT_EQ(presenter.calls[0].damage[0].x, 96);
  EXPECT_EQ(presenter.calls[0].damage[0].y, 40);
  EXPECT_EQ(presenter.calls[0].damage[0].width, 24);
  EXPECT_EQ(presenter.calls[0].damage[0].height, 16);
  EXPECT_EQ(presenter.calls[0].damage[1].x, 0);
  EXPECT_EQ(presenter.calls[0].damage[1].y, 0);
  EXPECT_EQ(presenter.calls[0].damage[1].width, 16);
  EXPECT_EQ(presenter.calls[0].damage[1].height, 8);
}

TEST(RegionSchedulerBehaviorTest, SynchronousCompletionDuringPresentIsHonored) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true; // no synthetic ETA completion
  RegionScheduler scheduler = make_scheduler(&presenter, config);
  presenter.complete_during_present = &scheduler;

  const PlutoRect rect{0, 0, 16, 16};
  submit_one(&scheduler, rect, kPlutoRefreshUi, 0);
  scheduler.tick(0); // present() completes the frame before it returns
  ASSERT_EQ(presenter.calls.size(), 1u);

  // The completed frame must not linger inflight and park the follow-up
  // update until the 1s fence timeout.
  submit_one(&scheduler, rect, kPlutoRefreshUi, 100);
  scheduler.tick(100);
  ASSERT_EQ(presenter.calls.size(), 2u);
}

TEST(RegionSchedulerBehaviorTest, PixelResetStagesWaitForCompletion) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);
  const PlutoRect full{0, 0, 128, 128};

  ASSERT_TRUE(scheduler.submit_pixel_reset_stage(
      full, kPlutoPresentFlagPixelResetBlack, 100));
  ASSERT_EQ(presenter.calls.size(), 1u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshFast);
  EXPECT_TRUE((presenter.calls[0].flags & kPlutoPresentFlagPixelResetBlack) !=
              0u);

  EXPECT_FALSE(scheduler.submit_pixel_reset_stage(
      full, kPlutoPresentFlagPixelResetWhite, 200));
  EXPECT_EQ(presenter.calls.size(), 1u);

  // Real-completion reset stages must not age out through the scheduler's
  // ordinary 1s safety fence: the panel may still be driving that rail.
  scheduler.poll_completions(2'000'000);
  EXPECT_TRUE(scheduler.anything_inflight());
  EXPECT_FALSE(scheduler.submit_pixel_reset_stage(
      full, kPlutoPresentFlagPixelResetWhite, 2'000'001));

  scheduler.notify_completion(presenter.calls[0].frame_id);
  ASSERT_TRUE(scheduler.submit_pixel_reset_stage(
      full, kPlutoPresentFlagPixelResetWhite, 300));
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshFast);
  EXPECT_TRUE((presenter.calls[1].flags & kPlutoPresentFlagPixelResetWhite) !=
              0u);

  scheduler.notify_completion(presenter.calls[1].frame_id);
  ASSERT_TRUE(
      scheduler.submit_pixel_reset_stage(full, kPlutoPresentFlagNone, 400));
  ASSERT_EQ(presenter.calls.size(), 3u);
  EXPECT_EQ(presenter.calls[2].cls, kPlutoRefreshFast);
  EXPECT_EQ(presenter.calls[2].flags & (kPlutoPresentFlagPixelResetBlack |
                                        kPlutoPresentFlagPixelResetWhite),
            0u);

  // The fast restore deliberately has no public pixel-reset flag, but it is
  // still part of the serialized maintenance transaction and must likewise
  // wait for the presenter's real completion.
  scheduler.poll_completions(2'000'000);
  EXPECT_TRUE(scheduler.anything_inflight());
  EXPECT_FALSE(scheduler.submit_pixel_reset_stage(
      full, kPlutoPresentFlagPixelResetBlack, 2'000'001));
  scheduler.notify_completion(presenter.calls[2].frame_id);
  EXPECT_FALSE(scheduler.anything_inflight());
}

// ---- pen-aware app-damage priority lane -----------------------------------

TEST(RegionSchedulerPenDamageTest, PreviewDispatchesBeforeTruth) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect damage{24, 24, 16, 16};
  scheduler.submit_pen_damage(damage, damage, kPlutoRefreshText, 100);
  scheduler.tick(100);

  ASSERT_EQ(presenter.calls.size(), 1u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshFast);
  EXPECT_NE(presenter.calls[0].flags & kPlutoPresentFlagInkPriority, 0u);

  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.tick(101);
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshText);
  EXPECT_EQ(presenter.calls[1].flags & kPlutoPresentFlagSettle, 0u)
      << "pen truth is app damage, not maintenance";
  EXPECT_NE(presenter.calls[1].flags & kPlutoPresentFlagPenTruth, 0u);
}

TEST(RegionSchedulerPenDamageTest,
     SynchronousPreviewCompletionDispatchesTruthImmediately) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);
  presenter.complete_during_present = &scheduler;

  const PlutoRect damage{8, 8, 16, 16};
  scheduler.submit_pen_damage(damage, damage, kPlutoRefreshText, 100);
  scheduler.tick(100, /*maintenance_allowed=*/false,
                 /*intrusive_maintenance_allowed=*/false);

  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshFast);
  EXPECT_NE(presenter.calls[0].flags & kPlutoPresentFlagInkPriority, 0u);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshText);
  EXPECT_EQ(presenter.calls[1].flags & kPlutoPresentFlagSettle, 0u);
  EXPECT_NE(presenter.calls[1].flags & kPlutoPresentFlagPenTruth, 0u);
}

TEST(RegionSchedulerPenDamageTest,
     TruthOnlyDamageDispatchesOnFirstTickOutsideMaintenancePolicy) {
  ScriptedPresenter presenter;
  RegionScheduler scheduler = make_scheduler(&presenter);

  const PlutoRect truth{40, 40, 16, 16};
  scheduler.submit_pen_damage(PlutoRect{}, truth, kPlutoRefreshText, 500);
  scheduler.tick(500, /*maintenance_allowed=*/false,
                 /*intrusive_maintenance_allowed=*/false);

  ASSERT_EQ(presenter.calls.size(), 1u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshText);
  EXPECT_EQ(presenter.calls[0].flags &
                (kPlutoPresentFlagSettle | kPlutoPresentFlagRequiredSettle),
            0u);
  EXPECT_NE(presenter.calls[0].flags & kPlutoPresentFlagPenTruth, 0u);
  EXPECT_TRUE(rect_contains(presenter.calls[0].damage[0], truth));
}

TEST(RegionSchedulerPenDamageTest, FullTruthWaitsOnlyForCompletion) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect damage{32, 32, 24, 24};
  scheduler.submit_pen_damage(damage, damage, kPlutoRefreshFull, 100);
  scheduler.tick(100, /*maintenance_allowed=*/false,
                 /*intrusive_maintenance_allowed=*/false);
  ASSERT_EQ(presenter.calls.size(), 1u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshFast);

  // No quiescence/CBS deadline can release Full while the preview waveform
  // is live, and disabling maintenance does not hold this app-damage truth.
  scheduler.tick(200, /*maintenance_allowed=*/false,
                 /*intrusive_maintenance_allowed=*/false);
  EXPECT_EQ(presenter.calls.size(), 1u);

  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.tick(200, /*maintenance_allowed=*/false,
                 /*intrusive_maintenance_allowed=*/false);
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshFull);
  EXPECT_EQ(presenter.calls[1].flags & kPlutoPresentFlagSettle, 0u);
  EXPECT_NE(presenter.calls[1].flags & kPlutoPresentFlagPenTruth, 0u);
}

TEST(RegionSchedulerPenDamageTest,
     BridgingColorPromotesComponentWithoutBoundingBoxUnion) {
  ScriptedPresenter presenter;
  presenter.ready_value = false;
  RegionSchedulerConfig config = test_config();
  config.presenter_collision_safe = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  scheduler.submit_pen_damage(PlutoRect{}, PlutoRect{0, 0, 16, 16},
                              kPlutoRefreshText, 100);
  scheduler.submit_pen_damage(PlutoRect{}, PlutoRect{24, 0, 16, 16},
                              kPlutoRefreshText, 101);
  // The newest color region bridges both older Text segments. All three owe
  // Full, but their bounded geometry must survive instead of becoming the
  // 40x16 connected-component bounding box.
  scheduler.submit_pen_damage(PlutoRect{}, PlutoRect{8, 0, 24, 16},
                              kPlutoRefreshFull, 102);

  presenter.ready_value = true;
  scheduler.tick(102);
  ASSERT_EQ(presenter.calls.size(), 2u);
  size_t damage_count = 0;
  for (const ScriptedPresenter::Call &call : presenter.calls) {
    EXPECT_EQ(call.cls, kPlutoRefreshFull);
    damage_count += call.damage.size();
    for (size_t i = 0; i < call.damage.size(); ++i) {
      for (size_t j = i + 1; j < call.damage.size(); ++j) {
        EXPECT_FALSE(pluto::rect_intersects(call.damage[i], call.damage[j]));
      }
    }
  }
  EXPECT_EQ(damage_count, 3u);
  EXPECT_EQ(accepted_presents_covering(presenter, PlutoRect{0, 0, 16, 16}), 1u);
  EXPECT_EQ(accepted_presents_covering(presenter, PlutoRect{24, 0, 16, 16}),
            1u);
  for (const ScriptedPresenter::Call &call : presenter.calls) {
    for (const PlutoRect &rect : call.damage) {
      EXPECT_FALSE(rect_contains(rect, PlutoRect{0, 0, 40, 16}));
    }
  }
}

TEST(RegionSchedulerPenDamageTest,
     MoreThan64StalledDiagonalSegmentsFallBackToBoundedCells) {
  ScriptedPresenter presenter;
  presenter.ready_value = false;
  RegionSchedulerConfig config = test_config();
  config.width = 1024;
  config.height = 1024;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  constexpr size_t kSegments = 96;
  for (size_t i = 0; i < kSegments; ++i) {
    const int32_t offset = static_cast<int32_t>(i) * 8;
    scheduler.submit_pen_damage(PlutoRect{}, PlutoRect{offset, offset, 16, 16},
                                kPlutoRefreshText,
                                100 + static_cast<uint64_t>(i));
  }

  presenter.ready_value = true;
  presenter.complete_during_present = &scheduler;
  scheduler.tick(200);
  ASSERT_GT(presenter.calls.size(), 8u);
  for (const ScriptedPresenter::Call &call : presenter.calls) {
    ASSERT_EQ(call.damage.size(), 1u);
    EXPECT_EQ(call.cls, kPlutoRefreshText);
    EXPECT_LE(call.damage[0].width, 64);
    EXPECT_LE(call.damage[0].height, 64);
    EXPECT_LT(pluto::rect_area(call.damage[0]),
              pluto::rect_area(PlutoRect{0, 0, 776, 776}));
  }
}

TEST(RegionSchedulerPenDamageTest,
     ContainedDrawBackCoalescesWithoutLosingOldestTruthTurn) {
  ScriptedPresenter presenter;
  presenter.ready_value = false;
  RegionScheduler scheduler = make_scheduler(&presenter);

  const PlutoRect outer{24, 24, 32, 32};
  const PlutoRect inner{32, 32, 8, 8};
  scheduler.submit_pen_damage(PlutoRect{}, outer, kPlutoRefreshText, 100);
  scheduler.submit_pen_damage(PlutoRect{}, inner, kPlutoRefreshText, 101);
  scheduler.submit_pen_damage(PlutoRect{}, outer, kPlutoRefreshText, 102);
  EXPECT_EQ(scheduler.superseded_updates(), 2u);

  presenter.ready_value = true;
  scheduler.tick(102);
  ASSERT_EQ(presenter.calls.size(), 1u);
  ASSERT_EQ(presenter.calls[0].damage.size(), 1u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshText);
  EXPECT_TRUE(rect_contains(presenter.calls[0].damage[0], outer));
}

TEST(RegionSchedulerPenDamageTest,
     MovingTextTruthChasesTrailWhileNewestPreviewIsInflight) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect first{0, 48, 16, 16};
  const PlutoRect second{8, 48, 16, 16};
  const PlutoRect newest{40, 48, 16, 16};
  scheduler.submit_pen_damage(first, first, kPlutoRefreshText, 100);
  scheduler.tick(100);
  scheduler.submit_pen_damage(second, second, kPlutoRefreshText, 101);
  scheduler.tick(101);
  ASSERT_EQ(presenter.calls.size(), 2u);

  // The earlier preview waveforms have completed, but the newest preview is
  // still live in the next presenter tile. The oldest bounded truth must
  // chase now; a transitive bbox union would intersect and stall the trail.
  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.notify_completion(presenter.calls[1].frame_id);
  scheduler.submit_pen_damage(newest, newest, kPlutoRefreshText, 102);
  scheduler.tick(102);

  ASSERT_EQ(presenter.calls.size(), 4u);
  EXPECT_EQ(presenter.calls[2].cls, kPlutoRefreshFast);
  EXPECT_NE(presenter.calls[2].flags & kPlutoPresentFlagInkPriority, 0u);
  EXPECT_EQ(presenter.calls[3].cls, kPlutoRefreshText);
  EXPECT_NE(presenter.calls[3].flags & kPlutoPresentFlagPenTruth, 0u);
  ASSERT_EQ(presenter.calls[3].damage.size(), 1u);
  EXPECT_TRUE(rect_contains(presenter.calls[3].damage[0], first));
  EXPECT_FALSE(rect_contains(presenter.calls[3].damage[0], newest));
  EXPECT_TRUE(scheduler.user_work_pending());
}

TEST(RegionSchedulerPenDamageTest,
     TruthWaitsWhenDisjointPreviewSharesPresenterTile) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  config.pen_collision_tile_px = 32;
  config.serialize_pen_truth_by_tile = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect first{0, 48, 8, 8};
  const PlutoRect next{24, 48, 8, 8};
  scheduler.submit_pen_damage(first, first, kPlutoRefreshText, 100);
  scheduler.tick(100);
  ASSERT_EQ(presenter.calls.size(), 1u);
  scheduler.notify_completion(presenter.calls[0].frame_id);

  // Logical rectangles do not overlap, but both occupy the presenter's
  // 32-pixel arbitration tile. Starting mapped Text now would claim that tile
  // and park the moving Fast nib behind a long truth waveform.
  scheduler.submit_pen_damage(next, next, kPlutoRefreshText, 101);
  scheduler.tick(101);
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_NE(presenter.calls[1].flags & kPlutoPresentFlagInkPriority, 0u);
  EXPECT_GE(scheduler.pen_truth_tile_holds(), 1u);

  scheduler.notify_completion(presenter.calls[1].frame_id);
  scheduler.tick(102);
  ASSERT_GT(presenter.calls.size(), 2u);
  for (size_t i = 2; i < presenter.calls.size(); ++i) {
    EXPECT_NE(presenter.calls[i].flags & kPlutoPresentFlagPenTruth, 0u);
  }
}

TEST(RegionSchedulerPenDamageTest,
     DisjointTruthSharingPresenterTileShipsInOneMaskedFrame) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  config.pen_collision_tile_px = 32;
  config.serialize_pen_truth_by_tile = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect left{0, 48, 8, 8};
  const PlutoRect right{24, 48, 8, 8};
  scheduler.submit_pen_damage(PlutoRect{}, left, kPlutoRefreshText, 100);
  scheduler.submit_pen_damage(PlutoRect{}, right, kPlutoRefreshText, 101);
  scheduler.tick(101);
  ASSERT_EQ(presenter.calls.size(), 1u);
  ASSERT_EQ(presenter.calls[0].damage.size(), 2u);
  EXPECT_NE(presenter.calls[0].flags & kPlutoPresentFlagPenTruth, 0u);
  EXPECT_EQ(presenter.calls[0].damage[0].x, left.x);
  EXPECT_EQ(presenter.calls[0].damage[0].y, left.y);
  EXPECT_EQ(presenter.calls[0].damage[0].width, left.width);
  EXPECT_EQ(presenter.calls[0].damage[0].height, left.height);
  EXPECT_EQ(presenter.calls[0].damage[1].x, right.x);
  EXPECT_EQ(presenter.calls[0].damage[1].y, right.y);
  EXPECT_EQ(presenter.calls[0].damage[1].width, right.width);
  EXPECT_EQ(presenter.calls[0].damage[1].height, right.height);

  scheduler.tick(102);
  EXPECT_EQ(presenter.calls.size(), 1u)
      << "a second mapped truth operation claimed the same engine tile";
  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.tick(103);
  EXPECT_EQ(presenter.calls.size(), 1u);
}

TEST(RegionSchedulerPenDamageTest,
     FullTruthBatchKeepsExactSameTileRectsInOneMaskedFrame) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  config.pen_collision_tile_px = 32;
  config.serialize_pen_truth_by_tile = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect same_tile_a{0, 48, 8, 8};
  const PlutoRect same_tile_b{24, 48, 8, 8};
  const PlutoRect disjoint_tile{40, 48, 8, 8};
  scheduler.submit_pen_damage(PlutoRect{}, same_tile_a, kPlutoRefreshFull, 100);
  scheduler.submit_pen_damage(PlutoRect{}, same_tile_b, kPlutoRefreshFull, 101);
  scheduler.submit_pen_damage(PlutoRect{}, disjoint_tile, kPlutoRefreshFull,
                              102);
  scheduler.tick(102);
  ASSERT_EQ(presenter.calls.size(), 1u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshFull);
  ASSERT_EQ(presenter.calls[0].damage.size(), 3u);
  EXPECT_TRUE(rect_contains(presenter.calls[0].damage[0], same_tile_a));
  EXPECT_TRUE(rect_contains(presenter.calls[0].damage[1], same_tile_b));
  EXPECT_TRUE(rect_contains(presenter.calls[0].damage[2], disjoint_tile));

  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.tick(103);
  EXPECT_EQ(presenter.calls.size(), 1u);
}

TEST(RegionSchedulerPenDamageTest,
     SamePhysicalTileTruthBatchesAfterEveryPresenterRotation) {
  struct Fixture {
    uint32_t rotation;
    int32_t width;
    int32_t height;
    PlutoRect first;
    PlutoRect next;
  };
  constexpr std::array<Fixture, 4> fixtures{{
      {0, 954, 128, {0, 48, 8, 8}, {24, 48, 8, 8}},
      {90, 128, 954, {48, 32, 8, 8}, {48, 40, 8, 8}},
      {180, 954, 128, {32, 48, 8, 8}, {40, 48, 8, 8}},
      {270, 954, 128, {32, 48, 8, 8}, {40, 48, 8, 8}},
  }};
  for (const Fixture &fixture : fixtures) {
    ScriptedPresenter presenter;
    RegionSchedulerConfig config = test_config();
    config.width = fixture.width;
    config.height = fixture.height;
    config.presenter_rotation = fixture.rotation;
    config.presenter_reports_completion = true;
    config.pen_collision_tile_px = 32;
    config.serialize_pen_truth_by_tile = true;
    RegionScheduler scheduler = make_scheduler(&presenter, config);

    scheduler.submit_pen_damage(PlutoRect{}, fixture.first, kPlutoRefreshText,
                                100);
    scheduler.submit_pen_damage(PlutoRect{}, fixture.next, kPlutoRefreshText,
                                101);
    scheduler.tick(101);
    ASSERT_EQ(presenter.calls.size(), 1u) << fixture.rotation;
    EXPECT_EQ(presenter.calls[0].damage.size(), 2u) << fixture.rotation;
    scheduler.notify_completion(presenter.calls[0].frame_id);
    scheduler.tick(102);
    EXPECT_EQ(presenter.calls.size(), 1u) << fixture.rotation;
  }
}

TEST(RegionSchedulerPenDamageTest,
     RotatedMapperPaddingCrossingTileBoundaryStaysSerialized) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.width = 128;
  config.height = 954;
  config.presenter_rotation = 90;
  config.presenter_reports_completion = true;
  config.pen_collision_tile_px = 32;
  config.serialize_pen_truth_by_tile = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  // At 90 degrees these become panel x=922..929 and x=914..921. Their
  // exact pixels share tile 28, but the first mapper execution rounds through
  // x=929 and therefore claims tile 29 too; the presenter cannot mask-union
  // the pair without splitting legacy mapper context.
  const PlutoRect crossing{48, 24, 8, 8};
  const PlutoRect contained{48, 32, 8, 8};
  scheduler.submit_pen_damage(PlutoRect{}, crossing, kPlutoRefreshText, 100);
  scheduler.submit_pen_damage(PlutoRect{}, contained, kPlutoRefreshText, 101);
  scheduler.tick(101);
  ASSERT_EQ(presenter.calls.size(), 1u);
  ASSERT_EQ(presenter.calls[0].damage.size(), 1u);
  EXPECT_TRUE(rect_contains(presenter.calls[0].damage[0], crossing));

  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.tick(102);
  ASSERT_EQ(presenter.calls.size(), 2u);
  ASSERT_EQ(presenter.calls[1].damage.size(), 1u);
  EXPECT_TRUE(rect_contains(presenter.calls[1].damage[0], contained));
}

TEST(RegionSchedulerPenDamageTest,
     SixteenExactTruthCellsDrainInOnePresenterFrame) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  config.pen_collision_tile_px = 32;
  config.serialize_pen_truth_by_tile = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  uint64_t now = 100;
  for (int32_t y = 0; y < 32; y += 8) {
    for (int32_t x = 0; x < 32; x += 8) {
      scheduler.submit_pen_damage(PlutoRect{}, PlutoRect{x, y, 8, 8},
                                  kPlutoRefreshText, now++);
    }
  }
  scheduler.tick(now);
  ASSERT_EQ(presenter.calls.size(), 1u);
  EXPECT_EQ(presenter.calls[0].damage.size(), 16u);
  EXPECT_NE(presenter.calls[0].flags & kPlutoPresentFlagPenTruth, 0u);

  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.tick(now + 1);
  EXPECT_EQ(presenter.calls.size(), 1u);
  EXPECT_FALSE(scheduler.user_work_pending());
}

TEST(RegionSchedulerPenDamageTest,
     SpanningTextTruthKeepsSameTileNeighbourSerialized) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  config.pen_collision_tile_px = 32;
  config.serialize_pen_truth_by_tile = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect spanning{16, 48, 24, 8};
  const PlutoRect contained{0, 56, 8, 8};
  scheduler.submit_pen_damage(PlutoRect{}, spanning, kPlutoRefreshText, 100);
  scheduler.submit_pen_damage(PlutoRect{}, contained, kPlutoRefreshText, 101);
  scheduler.tick(101);
  ASSERT_EQ(presenter.calls.size(), 1u);
  ASSERT_EQ(presenter.calls[0].damage.size(), 1u);
  EXPECT_TRUE(rect_contains(presenter.calls[0].damage[0], spanning));

  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.tick(102);
  ASSERT_EQ(presenter.calls.size(), 2u);
  ASSERT_EQ(presenter.calls[1].damage.size(), 1u);
  EXPECT_TRUE(rect_contains(presenter.calls[1].damage[0], contained));
}

TEST(RegionSchedulerPenDamageTest,
     SpanningFullTruthKeepsSameTileNeighbourSerialized) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  config.pen_collision_tile_px = 32;
  config.serialize_pen_truth_by_tile = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect spanning{16, 48, 24, 8};
  const PlutoRect contained{0, 56, 8, 8};
  scheduler.submit_pen_damage(PlutoRect{}, spanning, kPlutoRefreshFull, 100);
  scheduler.submit_pen_damage(PlutoRect{}, contained, kPlutoRefreshFull, 101);
  scheduler.tick(101);
  ASSERT_EQ(presenter.calls.size(), 1u);
  ASSERT_EQ(presenter.calls[0].damage.size(), 1u);
  EXPECT_TRUE(rect_contains(presenter.calls[0].damage[0], spanning));

  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.tick(102);
  ASSERT_EQ(presenter.calls.size(), 2u);
  ASSERT_EQ(presenter.calls[1].damage.size(), 1u);
  EXPECT_TRUE(rect_contains(presenter.calls[1].damage[0], contained));
}

TEST(RegionSchedulerPenDamageTest,
     CollisionTilesAreComparedAfterEveryPresenterRotation) {
  struct Fixture {
    uint32_t rotation;
    int32_t width;
    int32_t height;
    PlutoRect first;
    PlutoRect next;
  };
  constexpr std::array<Fixture, 3> fixtures{{
      {90, 128, 954, {48, 24, 8, 8}, {48, 32, 8, 8}},
      {180, 954, 128, {24, 48, 8, 8}, {32, 48, 8, 8}},
      {270, 954, 128, {24, 48, 8, 8}, {32, 48, 8, 8}},
  }};
  for (const Fixture &fixture : fixtures) {
    ScriptedPresenter presenter;
    RegionSchedulerConfig config = test_config();
    config.width = fixture.width;
    config.height = fixture.height;
    config.presenter_rotation = fixture.rotation;
    config.presenter_reports_completion = true;
    config.pen_collision_tile_px = 32;
    config.serialize_pen_truth_by_tile = true;
    RegionScheduler scheduler = make_scheduler(&presenter, config);

    scheduler.submit_pen_damage(fixture.first, PlutoRect{}, kPlutoRefreshText,
                                100);
    scheduler.tick(100);
    ASSERT_EQ(presenter.calls.size(), 1u) << fixture.rotation;
    scheduler.submit_pen_damage(PlutoRect{}, fixture.next, kPlutoRefreshText,
                                101);
    scheduler.tick(101);
    EXPECT_EQ(presenter.calls.size(), 1u)
        << "logical neighbours share one reflected physical tile at rotation "
        << fixture.rotation;
  }
}

TEST(RegionSchedulerPenDamageTest,
     ActiveHoverReservationClosesCompletionToNextPreviewRace) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  config.pen_collision_tile_px = 32;
  config.serialize_pen_truth_by_tile = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);
  scheduler.reserve_pen_focus(PlutoRect{0, 32, 32, 32}, UINT64_MAX);

  const PlutoRect first{0, 48, 8, 8};
  const PlutoRect next{16, 48, 8, 8};
  scheduler.submit_pen_damage(first, first, kPlutoRefreshText, 100);
  scheduler.tick(100);
  ASSERT_EQ(presenter.calls.size(), 1u);
  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.tick(101);
  EXPECT_EQ(presenter.calls.size(), 1u)
      << "completion-only tick started mapped truth under stationary hover";

  scheduler.submit_pen_damage(next, next, kPlutoRefreshText, 102);
  scheduler.tick(102);
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_NE(presenter.calls[1].flags & kPlutoPresentFlagInkPriority, 0u);
  scheduler.notify_completion(presenter.calls[1].frame_id);
  scheduler.tick(103);
  EXPECT_EQ(presenter.calls.size(), 2u);
  EXPECT_GT(scheduler.pen_focus_tile_holds(), 0u);

  scheduler.clear_pen_focus();
  scheduler.tick(104);
  ASSERT_EQ(presenter.calls.size(), 3u);
  EXPECT_NE(presenter.calls[2].flags & kPlutoPresentFlagPenTruth, 0u);
}

TEST(RegionSchedulerPenDamageTest,
     FiniteTerminalFocusLeaseReleasesAtItsExactDeadline) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  config.serialize_pen_truth_by_tile = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);
  scheduler.reserve_pen_focus(PlutoRect{0, 0, 16, 16}, 200);
  scheduler.submit_pen_damage(PlutoRect{}, PlutoRect{0, 0, 8, 8},
                              kPlutoRefreshText, 100);
  scheduler.tick(199);
  EXPECT_TRUE(presenter.calls.empty());
  scheduler.tick(200);
  ASSERT_EQ(presenter.calls.size(), 1u);
  EXPECT_NE(presenter.calls[0].flags & kPlutoPresentFlagPenTruth, 0u);
}

TEST(RegionSchedulerPenDamageTest,
     TileHeldTruthDoesNotFreezeUnrelatedExactUserWork) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  config.serialize_pen_truth_by_tile = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);
  scheduler.reserve_pen_focus(PlutoRect{0, 32, 32, 32}, UINT64_MAX);

  const PlutoRect pen{0, 48, 8, 8};
  const PlutoRect unrelated{96, 96, 8, 8};
  scheduler.submit_pen_damage(pen, pen, kPlutoRefreshText, 100);
  scheduler.tick(100);
  ASSERT_EQ(presenter.calls.size(), 1u);
  const PlutoRefreshClass unrelated_class = kPlutoRefreshText;
  scheduler.submit_damage(&unrelated, &unrelated_class, 1, 101);
  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.tick(101);

  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshText);
  EXPECT_EQ(presenter.calls[1].flags & kPlutoPresentFlagPenTruth, 0u);
  ASSERT_EQ(presenter.calls[1].damage.size(), 1u);
  EXPECT_TRUE(rect_contains(presenter.calls[1].damage[0], unrelated));
  EXPECT_TRUE(scheduler.user_work_pending());
}

TEST(RegionSchedulerPenDamageTest,
     FullScreenMappedWorkCutsOnePhysicalFocusHoleAndBatchesRemainder) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  config.serialize_pen_truth_by_tile = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);
  const PlutoRect focus{40, 40, 8, 8};
  const PlutoRect focus_tile{32, 32, 32, 32};
  scheduler.reserve_pen_focus(focus, UINT64_MAX);
  const PlutoRect full{0, 0, 128, 128};
  submit_one(&scheduler, full, kPlutoRefreshFull, 100);
  scheduler.tick(100);

  ASSERT_EQ(presenter.calls.size(), 1u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshFull);
  ASSERT_EQ(presenter.calls[0].damage.size(), 4u);
  int64_t outside_area = 0;
  for (const PlutoRect &rect : presenter.calls[0].damage) {
    EXPECT_FALSE(pluto::rect_intersects(rect, focus_tile));
    outside_area += pluto::rect_area(rect);
  }
  EXPECT_EQ(outside_area,
            pluto::rect_area(full) - pluto::rect_area(focus_tile));
  EXPECT_TRUE(scheduler.user_work_pending());

  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.clear_pen_focus();
  scheduler.tick(101);
  ASSERT_EQ(presenter.calls.size(), 2u);
  ASSERT_EQ(presenter.calls[1].damage.size(), 1u);
  EXPECT_TRUE(rect_contains(presenter.calls[1].damage[0], focus_tile));
}

TEST(RegionSchedulerPenDamageTest,
     RotatedExactFocusHoleDoesNotRedispatchAlignmentSlivers) {
  struct Fixture {
    uint32_t rotation;
    int32_t width;
    int32_t height;
  };
  constexpr std::array<Fixture, 2> fixtures{{
      {90, 128, 954},
      {180, 954, 128},
  }};
  for (const Fixture &fixture : fixtures) {
    ScriptedPresenter presenter;
    RegionSchedulerConfig config = test_config();
    config.width = fixture.width;
    config.height = fixture.height;
    config.presenter_rotation = fixture.rotation;
    config.presenter_reports_completion = true;
    config.pen_collision_tile_px = 32;
    config.serialize_pen_truth_by_tile = true;
    RegionScheduler scheduler = make_scheduler(&presenter, config);
    scheduler.reserve_pen_focus(PlutoRect{40, 40, 8, 8}, UINT64_MAX);
    const PlutoRect full{0, 0, fixture.width, fixture.height};
    submit_one(&scheduler, full, kPlutoRefreshFull, 100);
    scheduler.tick(100);
    ASSERT_EQ(presenter.calls.size(), 1u) << fixture.rotation;
    ASSERT_GT(presenter.calls[0].damage.size(), 1u) << fixture.rotation;

    scheduler.notify_completion(presenter.calls[0].frame_id);
    scheduler.tick(101);
    scheduler.tick(102);
    scheduler.tick(103);
    EXPECT_EQ(presenter.calls.size(), 1u)
        << "inverse-rotated focus hole shed alignment slivers at rotation "
        << fixture.rotation;
    EXPECT_TRUE(scheduler.user_work_pending());

    scheduler.clear_pen_focus();
    scheduler.tick(104);
    ASSERT_EQ(presenter.calls.size(), 2u) << fixture.rotation;
    EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshFull);
    ASSERT_EQ(presenter.calls[1].damage.size(), 1u);
  }
}

TEST(RegionSchedulerPenDamageTest,
     MultipleRoutesBeforeOneTickStayExactAndLeaveGapDispatchable) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect first{0, 0, 16, 16};
  const PlutoRect second{96, 96, 16, 16};
  const PlutoRect gap{48, 48, 16, 16};
  scheduler.submit_pen_damage(first, first, kPlutoRefreshText, 100);
  scheduler.submit_pen_damage(second, second, kPlutoRefreshText, 100);
  scheduler.tick(100);
  ASSERT_EQ(presenter.calls.size(), 1u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshFast);
  ASSERT_EQ(presenter.calls[0].damage.size(), 2u);
  EXPECT_TRUE(rect_contains(presenter.calls[0].damage[0], first));
  EXPECT_TRUE(rect_contains(presenter.calls[0].damage[1], second));
  for (const PlutoRect &rect : presenter.calls[0].damage) {
    EXPECT_FALSE(rect_contains(rect, PlutoRect{0, 0, 112, 112}));
  }

  scheduler.submit_pen_damage(PlutoRect{}, gap, kPlutoRefreshText, 101);
  scheduler.tick(101);
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshText);
  ASSERT_EQ(presenter.calls[1].damage.size(), 1u);
  EXPECT_TRUE(rect_contains(presenter.calls[1].damage[0], gap));
}

TEST(RegionSchedulerPenDamageTest,
     PartiallyOverlappingSegmentsAreDisjointWithinEveryPresenterBatch) {
  ScriptedPresenter presenter;
  presenter.ready_value = false;
  RegionSchedulerConfig config = test_config();
  config.presenter_collision_safe = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect first{0, 0, 24, 24};
  const PlutoRect overlap{16, 0, 24, 24};
  const PlutoRect distant{80, 0, 16, 16};
  scheduler.submit_pen_damage(first, first, kPlutoRefreshFull, 100);
  scheduler.submit_pen_damage(overlap, overlap, kPlutoRefreshFull, 101);
  scheduler.submit_pen_damage(distant, distant, kPlutoRefreshFull, 102);

  presenter.ready_value = true;
  scheduler.tick(102);
  ASSERT_GE(presenter.calls.size(), 4u);
  bool saw_multi_rect_preview = false;
  bool saw_multi_rect_truth = false;
  for (const ScriptedPresenter::Call &call : presenter.calls) {
    for (size_t i = 0; i < call.damage.size(); ++i) {
      for (size_t j = i + 1; j < call.damage.size(); ++j) {
        EXPECT_FALSE(pluto::rect_intersects(call.damage[i], call.damage[j]))
            << "one present request violated the ABI disjoint-rect contract";
      }
    }
    if (call.damage.size() > 1 && call.cls == kPlutoRefreshFast) {
      saw_multi_rect_preview = true;
    }
    if (call.damage.size() > 1 && call.cls == kPlutoRefreshFull) {
      saw_multi_rect_truth = true;
    }
  }
  EXPECT_TRUE(saw_multi_rect_preview);
  EXPECT_TRUE(saw_multi_rect_truth);
}

TEST(RegionSchedulerPenDamageTest,
     OverlapSupersedingPresenterChasesTruthInThePreviewTick) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = false;
  config.presenter_collision_safe = true;
  config.latency_model_us[kPlutoRefreshFast] = 1'000'000;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect pen{16, 16, 24, 24};
  scheduler.submit_pen_damage(pen, pen, kPlutoRefreshFull, 100);
  scheduler.tick(100);

  // qtfb has no optical completion callback, but Xochitl accepts overlapping
  // regional updates with newest-content supersession. The one-second nominal
  // fence therefore remains bookkeeping and cannot delay the Full truth.
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshFast);
  EXPECT_NE(presenter.calls[0].flags & kPlutoPresentFlagInkPriority, 0u);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshFull);
  EXPECT_NE(presenter.calls[1].flags & kPlutoPresentFlagPenTruth, 0u);
  EXPECT_EQ(presenter.calls[0].damage.size(), 1u);
  EXPECT_EQ(presenter.calls[1].damage.size(), 1u);
}

TEST(RegionSchedulerPenDamageTest,
     SustainedRegionalFullKeepsPreviewsFlowingAndTruthChasing) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect first{0, 80, 16, 16};
  const PlutoRect second{8, 80, 16, 16};
  const PlutoRect third{16, 80, 16, 16};
  const PlutoRect fourth{32, 80, 16, 16};
  scheduler.submit_pen_damage(first, first, kPlutoRefreshFull, 100);
  scheduler.tick(100);
  ASSERT_EQ(presenter.calls.size(), 1u);

  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.submit_pen_damage(second, second, kPlutoRefreshFull, 101);
  scheduler.tick(101);
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshFast);

  scheduler.notify_completion(presenter.calls[1].frame_id);
  scheduler.submit_pen_damage(third, third, kPlutoRefreshFull, 102);
  scheduler.tick(102);
  ASSERT_EQ(presenter.calls.size(), 4u);
  EXPECT_EQ(presenter.calls[2].cls, kPlutoRefreshFast);
  EXPECT_EQ(presenter.calls[3].cls, kPlutoRefreshFull);
  EXPECT_NE(presenter.calls[3].flags & kPlutoPresentFlagPenTruth, 0u);
  ASSERT_EQ(presenter.calls[3].damage.size(), 1u);
  EXPECT_TRUE(rect_contains(presenter.calls[3].damage[0], first));

  // Leave both the newest preview and regional Full on glass. A disjoint
  // fourth preview still admits immediately; ordinary Full exclusivity must
  // not be accidentally applied to this PenTruth request.
  scheduler.submit_pen_damage(fourth, fourth, kPlutoRefreshFull, 103);
  scheduler.tick(103);
  ASSERT_EQ(presenter.calls.size(), 5u);
  EXPECT_EQ(presenter.calls[4].cls, kPlutoRefreshFast);
  EXPECT_NE(presenter.calls[4].flags & kPlutoPresentFlagInkPriority, 0u);
}

TEST(RegionSchedulerPenDamageTest,
     OrdinaryFullDoesNotBlockDisjointPreviewOrTruth) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  config.presenter_collision_safe = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect ordinary{0, 0, 16, 16};
  const PlutoRect preview{96, 96, 16, 16};
  submit_one(&scheduler, ordinary, kPlutoRefreshFull, 100);
  scheduler.tick(100);
  ASSERT_EQ(presenter.calls.size(), 1u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshFull);
  EXPECT_EQ(presenter.calls[0].flags & kPlutoPresentFlagPenTruth, 0u);

  scheduler.submit_pen_damage(preview, preview, kPlutoRefreshText, 101);
  scheduler.tick(101);
  ASSERT_EQ(presenter.calls.size(), 3u);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshFast);
  EXPECT_NE(presenter.calls[1].flags & kPlutoPresentFlagInkPriority, 0u);
  EXPECT_EQ(presenter.calls[2].cls, kPlutoRefreshText);
  EXPECT_NE(presenter.calls[2].flags & kPlutoPresentFlagPenTruth, 0u);
  EXPECT_TRUE(scheduler.anything_inflight())
      << "the ordinary Full was not completed to make pen latency pass";
}

TEST(RegionSchedulerPenDamageTest, PixelResetAnyClassStillBlocksPenLanes) {
  for (const bool full_restore : {false, true}) {
    ScriptedPresenter presenter;
    RegionSchedulerConfig config = test_config();
    config.presenter_reports_completion = true;
    config.presenter_collision_safe = true;
    RegionScheduler scheduler = make_scheduler(&presenter, config);

    const PlutoRefreshClass reset_class =
        full_restore ? kPlutoRefreshFull : kPlutoRefreshFast;
    const uint32_t reset_flags =
        full_restore ? static_cast<uint32_t>(kPlutoPresentFlagPixelResetRestore)
                     : static_cast<uint32_t>(kPlutoPresentFlagPixelResetBlack);
    ASSERT_TRUE(scheduler.submit_pixel_reset_stage(
        PlutoRect{0, 0, 128, 128}, reset_flags, 100, reset_class));
    ASSERT_EQ(presenter.calls.size(), 1u);

    const PlutoRect pen{96, 96, 16, 16};
    scheduler.submit_pen_damage(pen, pen, kPlutoRefreshText, 101);
    scheduler.tick(101);
    EXPECT_EQ(presenter.calls.size(), 1u)
        << "pixel reset class=" << static_cast<int>(reset_class)
        << " leaked pen work before optical completion";

    scheduler.notify_completion(presenter.calls[0].frame_id);
    scheduler.tick(102);
    ASSERT_EQ(presenter.calls.size(), 3u);
    EXPECT_NE(presenter.calls[1].flags & kPlutoPresentFlagInkPriority, 0u);
    EXPECT_NE(presenter.calls[2].flags & kPlutoPresentFlagPenTruth, 0u);
  }
}

TEST(RegionSchedulerPenDamageTest,
     BlockedTruthPreventsUnrelatedUserWorkJumpingPriorityLane) {
  ScriptedPresenter presenter;
  presenter.text_ready = false;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect pen{0, 0, 16, 16};
  const PlutoRect unrelated{96, 96, 16, 16};
  scheduler.submit_pen_damage(pen, pen, kPlutoRefreshText, 100);
  submit_one(&scheduler, unrelated, kPlutoRefreshFast, 100);
  scheduler.tick(100);
  ASSERT_EQ(presenter.calls.size(), 1u);
  EXPECT_NE(presenter.calls[0].flags & kPlutoPresentFlagInkPriority, 0u);

  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.tick(101);
  EXPECT_EQ(presenter.calls.size(), 1u)
      << "generic damage jumped a presenter-blocked truth head";

  presenter.text_ready = true;
  scheduler.tick(102);
  ASSERT_EQ(presenter.calls.size(), 3u);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshText);
  EXPECT_EQ(presenter.calls[2].cls, kPlutoRefreshFast);
  EXPECT_TRUE(rect_contains(presenter.calls[2].damage[0], unrelated));
}

TEST(RegionSchedulerPenDamageTest,
     DeclinedTruthRetainsSpecialOwnershipAndRetriesBeforeGenericWork) {
  ScriptedPresenter presenter;
  presenter.present_results = {true, false, true, true};
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);
  presenter.complete_during_present = &scheduler;

  const PlutoRect pen{8, 8, 16, 16};
  const PlutoRect unrelated{96, 96, 16, 16};
  scheduler.submit_pen_damage(pen, pen, kPlutoRefreshText, 10);
  submit_one(&scheduler, unrelated, kPlutoRefreshUi, 10);
  scheduler.tick(10);

  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_TRUE(presenter.calls[0].accepted);
  EXPECT_NE(presenter.calls[0].flags & kPlutoPresentFlagInkPriority, 0u);
  EXPECT_FALSE(presenter.calls[1].accepted);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshText);

  scheduler.tick(11);
  ASSERT_EQ(presenter.calls.size(), 4u);
  EXPECT_TRUE(presenter.calls[2].accepted);
  EXPECT_EQ(presenter.calls[2].cls, kPlutoRefreshText);
  EXPECT_TRUE(presenter.calls[3].accepted);
  EXPECT_EQ(presenter.calls[3].cls, kPlutoRefreshUi);
}

TEST(RegionSchedulerPenDamageTest,
     NewTruthCutsQueuedFastAndUiWithoutRecoalescingTheHole) {
  ScriptedPresenter presenter;
  presenter.ready_value = false;
  RegionSchedulerConfig config = test_config();
  config.presenter_collision_safe = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect truth{32, 32, 32, 32};
  const PlutoRect fast_box{16, 32, 32, 32};
  const PlutoRect ui_box{48, 32, 32, 32};
  const PlutoRect queued[] = {fast_box, ui_box};
  const PlutoRefreshClass classes[] = {kPlutoRefreshFast, kPlutoRefreshUi};
  scheduler.submit_damage(queued, classes, 2, 90);
  scheduler.tick(90);
  ASSERT_TRUE(presenter.calls.empty());

  scheduler.submit_pen_damage(truth, truth, kPlutoRefreshText, 100);
  presenter.ready_value = true;
  scheduler.tick(100);

  size_t truth_call = presenter.calls.size();
  for (size_t i = 0; i < presenter.calls.size(); ++i) {
    if ((presenter.calls[i].flags & kPlutoPresentFlagPenTruth) != 0u) {
      truth_call = i;
      break;
    }
  }
  ASSERT_TRUE(truth_call < presenter.calls.size());
  bool saw_fast_left = false;
  bool saw_ui_right = false;
  const PlutoRect fast_left{16, 32, 16, 32};
  const PlutoRect ui_right{64, 32, 16, 32};
  for (size_t i = truth_call + 1; i < presenter.calls.size(); ++i) {
    const ScriptedPresenter::Call &call = presenter.calls[i];
    if (!call.accepted || (call.flags & (kPlutoPresentFlagPenTruth |
                                         kPlutoPresentFlagInkPriority)) != 0u) {
      continue;
    }
    for (const PlutoRect &rect : call.damage) {
      EXPECT_FALSE(pluto::rect_intersects(rect, truth))
          << "lower-class generic damage rebuilt the pen-truth hole";
      saw_fast_left |=
          call.cls == kPlutoRefreshFast && rect_contains(rect, fast_left);
      saw_ui_right |=
          call.cls == kPlutoRefreshUi && rect_contains(rect, ui_right);
    }
  }
  EXPECT_TRUE(saw_fast_left) << "Fast remainder outside truth was lost";
  EXPECT_TRUE(saw_ui_right) << "Ui remainder outside truth was lost";
}

TEST(RegionSchedulerPenDamageTest,
     DisjointQueuedFastRectsCannotMergeBackAcrossTruthGap) {
  ScriptedPresenter presenter;
  presenter.ready_value = false;
  RegionSchedulerConfig config = test_config();
  config.presenter_collision_safe = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect left{0, 0, 24, 32};
  const PlutoRect right{40, 0, 24, 32};
  const PlutoRect truth{24, 0, 16, 32};
  const PlutoRect queued[] = {left, right};
  const PlutoRefreshClass classes[] = {kPlutoRefreshFast, kPlutoRefreshFast};
  scheduler.submit_damage(queued, classes, 2, 10);
  scheduler.submit_pen_damage(PlutoRect{}, truth, kPlutoRefreshText, 11);

  presenter.ready_value = true;
  scheduler.tick(11);
  ASSERT_GE(presenter.calls.size(), 2u);
  ASSERT_NE(presenter.calls[0].flags & kPlutoPresentFlagPenTruth, 0u);
  bool saw_left = false;
  bool saw_right = false;
  for (size_t i = 1; i < presenter.calls.size(); ++i) {
    const ScriptedPresenter::Call &call = presenter.calls[i];
    if (call.cls != kPlutoRefreshFast) {
      continue;
    }
    for (const PlutoRect &rect : call.damage) {
      EXPECT_FALSE(pluto::rect_intersects(rect, truth))
          << "gap coalescing rebuilt a Fast bbox across pen truth";
      saw_left |= rect_contains(rect, left);
      saw_right |= rect_contains(rect, right);
    }
  }
  EXPECT_TRUE(saw_left);
  EXPECT_TRUE(saw_right);
}

TEST(RegionSchedulerPenDamageTest,
     ReverseTemporalTruthExpansionRecutsOlderExactWork) {
  ScriptedPresenter presenter;
  presenter.ready_value = false;
  RegionSchedulerConfig config = test_config();
  config.presenter_collision_safe = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect old_fast{64, 0, 32, 32};
  const PlutoRect first_truth{0, 0, 32, 32};
  const PlutoRect newer_generic{16, 0, 64, 32};
  submit_one(&scheduler, old_fast, kPlutoRefreshFast, 10);
  scheduler.submit_pen_damage(PlutoRect{}, first_truth, kPlutoRefreshText, 11);
  submit_one(&scheduler, newer_generic, kPlutoRefreshFast, 12);

  presenter.ready_value = true;
  scheduler.tick(12);
  std::vector<PlutoRect> truth_rects;
  size_t last_truth_call = 0;
  for (size_t i = 0; i < presenter.calls.size(); ++i) {
    if ((presenter.calls[i].flags & kPlutoPresentFlagPenTruth) == 0u) {
      continue;
    }
    last_truth_call = i;
    truth_rects.insert(truth_rects.end(), presenter.calls[i].damage.begin(),
                       presenter.calls[i].damage.end());
  }
  ASSERT_TRUE(!truth_rects.empty());
  bool saw_old_outside = false;
  for (size_t i = last_truth_call + 1; i < presenter.calls.size(); ++i) {
    const ScriptedPresenter::Call &call = presenter.calls[i];
    if (call.cls != kPlutoRefreshFast) {
      continue;
    }
    for (const PlutoRect &rect : call.damage) {
      for (const PlutoRect &truth_rect : truth_rects) {
        EXPECT_FALSE(pluto::rect_intersects(rect, truth_rect))
            << "older Fast work survived under reverse-created pen truth";
      }
      saw_old_outside |= rect_contains(rect, PlutoRect{80, 0, 16, 32});
    }
  }
  EXPECT_TRUE(saw_old_outside) << "outside remainder was dropped";
}

TEST(RegionSchedulerPenDamageTest,
     NewTruthCutsAlreadyParkedGenericWithoutLosingItsRemainder) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect blocker{0, 0, 96, 64};
  submit_one(&scheduler, blocker, kPlutoRefreshFast, 0);
  scheduler.tick(0);
  ASSERT_EQ(presenter.calls.size(), 1u);

  const PlutoRect parked_ui{16, 16, 64, 32};
  submit_one(&scheduler, parked_ui, kPlutoRefreshUi, 1);
  scheduler.tick(1);
  ASSERT_EQ(presenter.calls.size(), 1u);
  ASSERT_EQ(scheduler.parked_updates(), 1u);

  const PlutoRect truth{32, 16, 32, 32};
  scheduler.submit_pen_damage(truth, truth, kPlutoRefreshText, 2);
  scheduler.tick(2);
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_NE(presenter.calls[1].flags & kPlutoPresentFlagInkPriority, 0u);

  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.notify_completion(presenter.calls[1].frame_id);
  scheduler.tick(3);
  ASSERT_GE(presenter.calls.size(), 4u);
  ASSERT_NE(presenter.calls[2].flags & kPlutoPresentFlagPenTruth, 0u);
  EXPECT_EQ(presenter.calls[2].cls, kPlutoRefreshText);

  const PlutoRect left{16, 16, 16, 32};
  const PlutoRect right{64, 16, 16, 32};
  bool saw_left = false;
  bool saw_right = false;
  for (size_t i = 3; i < presenter.calls.size(); ++i) {
    const ScriptedPresenter::Call &call = presenter.calls[i];
    if (call.cls != kPlutoRefreshUi) {
      continue;
    }
    for (const PlutoRect &rect : call.damage) {
      EXPECT_FALSE(pluto::rect_intersects(rect, truth));
      saw_left |= rect_contains(rect, left);
      saw_right |= rect_contains(rect, right);
    }
  }
  EXPECT_TRUE(saw_left);
  EXPECT_TRUE(saw_right);
}

TEST(RegionSchedulerPenDamageTest,
     TextTruthPreservesOlderFullQualityInsideAndOutsideTheCut) {
  ScriptedPresenter presenter;
  presenter.ready_value = false;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  config.presenter_collision_safe = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);
  presenter.complete_during_present = &scheduler;

  const PlutoRect full_box{16, 16, 64, 64};
  const PlutoRect truth{32, 32, 32, 32};
  submit_one(&scheduler, full_box, kPlutoRefreshFull, 10);
  scheduler.submit_pen_damage(PlutoRect{}, truth, kPlutoRefreshText, 11);

  presenter.ready_value = true;
  scheduler.tick(11);
  ASSERT_TRUE(!presenter.calls.empty());
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshFull);
  EXPECT_NE(presenter.calls[0].flags & kPlutoPresentFlagPenTruth, 0u);
  EXPECT_TRUE(rect_contains(presenter.calls[0].damage[0], truth));
  for (const ScriptedPresenter::Call &call : presenter.calls) {
    EXPECT_EQ(call.cls, kPlutoRefreshFull)
        << "older Full obligation was downgraded by Text pen truth";
  }
  EXPECT_GE(accepted_presents_covering(presenter, PlutoRect{16, 16, 64, 16}),
            1u)
      << "Full-quality remainder outside truth was lost";
}

TEST(RegionSchedulerPenDamageTest,
     GenericDamageDuringPendingAndInflightTruthStaysInTruthLane) {
  ScriptedPresenter presenter;
  presenter.ready_value = false;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  config.presenter_collision_safe = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect truth{32, 32, 16, 16};
  scheduler.submit_pen_damage(PlutoRect{}, truth, kPlutoRefreshText, 10);
  submit_one(&scheduler, PlutoRect{24, 32, 24, 16}, kPlutoRefreshFast, 11);

  presenter.ready_value = true;
  scheduler.tick(11);
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_NE(presenter.calls[0].flags & kPlutoPresentFlagPenTruth, 0u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshText);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshFast);
  for (const PlutoRect &rect : presenter.calls[1].damage) {
    EXPECT_FALSE(pluto::rect_intersects(rect, truth));
  }

  // The first truth is deliberately still in flight. New overlapping app
  // content must create another truth pass, never a trailing Fast repaint.
  submit_one(&scheduler, PlutoRect{32, 32, 24, 16}, kPlutoRefreshFast, 12);
  scheduler.tick(12);
  ASSERT_EQ(presenter.calls.size(), 4u);
  size_t truth_calls = 0;
  for (const ScriptedPresenter::Call &call : presenter.calls) {
    if ((call.flags & kPlutoPresentFlagPenTruth) != 0u) {
      ++truth_calls;
      EXPECT_EQ(call.cls, kPlutoRefreshText);
      continue;
    }
    for (const PlutoRect &rect : call.damage) {
      EXPECT_FALSE(pluto::rect_intersects(rect, truth));
    }
  }
  EXPECT_EQ(truth_calls, 2u);
}

TEST(RegionSchedulerPenDamageTest,
     DeepResidualPrefixSurvivesLocalTailReconciliation) {
  ScriptedPresenter presenter;
  presenter.ready_value = false;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  config.presenter_collision_safe = true;
  config.max_rects[kPlutoRefreshFast] = 64;
  RegionScheduler scheduler = make_scheduler(&presenter, config);
  presenter.complete_during_present = &scheduler;

  const PlutoRect truth{0, 0, 16, 16};
  scheduler.submit_pen_damage(PlutoRect{}, truth, kPlutoRefreshText, 10);

  // These entries form the already-reconciled prefix. They are deliberately
  // disjoint from truth and from each other so every exact pixel obligation
  // can be checked after one newer, crossing rectangle is routed.
  std::array<PlutoRect, 96> prefix{};
  for (size_t i = 0; i < prefix.size(); ++i) {
    const int32_t col = static_cast<int32_t>(i % 12u);
    const int32_t row = static_cast<int32_t>(i / 12u);
    prefix[i] = PlutoRect{32 + col * 8, 32 + row * 8, 8, 8};
    submit_one(&scheduler, prefix[i], kPlutoRefreshFast,
               11 + static_cast<uint64_t>(i));
  }

  const PlutoRect crossing{8, 0, 24, 16};
  submit_one(&scheduler, crossing, kPlutoRefreshFast, 200);

  presenter.ready_value = true;
  scheduler.tick(200);
  ASSERT_TRUE(!presenter.calls.empty());

  bool saw_truth = false;
  bool saw_crossing_outside = false;
  const PlutoRect crossing_outside{16, 0, 16, 16};
  for (const ScriptedPresenter::Call &call : presenter.calls) {
    if ((call.flags & kPlutoPresentFlagPenTruth) != 0u) {
      saw_truth = true;
      EXPECT_EQ(call.cls, kPlutoRefreshText);
      continue;
    }
    for (const PlutoRect &rect : call.damage) {
      EXPECT_FALSE(pluto::rect_intersects(rect, truth));
      saw_crossing_outside |= rect_contains(rect, crossing_outside);
    }
  }
  EXPECT_TRUE(saw_truth);
  EXPECT_TRUE(saw_crossing_outside);
  for (const PlutoRect &rect : prefix) {
    EXPECT_EQ(accepted_presents_covering(presenter, rect), 1u)
        << "an older exact residual was lost or duplicated";
  }
}

TEST(RegionSchedulerPenDamageTest,
     ExactResidualCapPromotesOverflowInsteadOfDroppingOrBoundingFast) {
  ScriptedPresenter presenter;
  presenter.ready_value = false;
  RegionSchedulerConfig config = test_config();
  config.width = 2048;
  config.height = 2048;
  config.presenter_collision_safe = true;
  config.max_rects[kPlutoRefreshFast] = 64;
  RegionScheduler scheduler = make_scheduler(&presenter, config);
  ASSERT_TRUE(scheduler.valid());

  const PlutoRect truth{0, 0, 8, 8};
  scheduler.submit_pen_damage(PlutoRect{}, truth, kPlutoRefreshText, 0);
  // Fill the fixed exact lane with disjoint work while truth is pending.
  for (int i = 0; i < 1024; ++i) {
    const PlutoRect residual{16 + (i % 32) * 16, 16 + (i / 32) * 16, 8, 8};
    submit_one(&scheduler, residual, kPlutoRefreshFast,
               1 + static_cast<uint64_t>(i));
  }
  const PlutoRect overflow{1024, 1024, 16, 16};
  submit_one(&scheduler, overflow, kPlutoRefreshFull, 2000);

  presenter.ready_value = true;
  scheduler.tick(2000);
  ASSERT_TRUE(!presenter.calls.empty());
  bool saw_full_truth = false;
  for (const ScriptedPresenter::Call &call : presenter.calls) {
    for (const PlutoRect &rect : call.damage) {
      if (!rect_contains(rect, overflow)) {
        continue;
      }
      EXPECT_NE(call.flags & kPlutoPresentFlagPenTruth, 0u)
          << "overflow returned through an ordinary lower lane";
      EXPECT_EQ(call.cls, kPlutoRefreshFull);
      saw_full_truth = true;
    }
  }
  EXPECT_TRUE(saw_full_truth) << "overflow app damage was dropped";
}

TEST(RegionSchedulerPenDamageTest,
     RedamageCancelsOverlappingMaintenanceAlreadyParkedOnGlass) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect damage{16, 16, 24, 24};
  submit_one(&scheduler, damage, kPlutoRefreshFast, 0);
  scheduler.tick(0);
  ASSERT_EQ(presenter.calls.size(), 1u);

  scheduler.submit_settle(damage, kPlutoRefreshText, 1);
  scheduler.tick(1); // overlaps the live Fast request, so maintenance parks
  ASSERT_EQ(presenter.calls.size(), 1u);
  ASSERT_TRUE(scheduler.settle_work_pending());

  scheduler.submit_pen_damage(damage, damage, kPlutoRefreshText, 2);
  EXPECT_FALSE(scheduler.settle_work_pending())
      << "stale parked maintenance survived newer pen app damage";
  scheduler.tick(2);
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_NE(presenter.calls[1].flags & kPlutoPresentFlagInkPriority, 0u);

  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.notify_completion(presenter.calls[1].frame_id);
  scheduler.tick(3);
  ASSERT_EQ(presenter.calls.size(), 3u);
  EXPECT_EQ(presenter.calls[2].cls, kPlutoRefreshText);

  scheduler.notify_completion(presenter.calls[2].frame_id);
  scheduler.tick(4);
  EXPECT_EQ(presenter.calls.size(), 3u)
      << "cancelled maintenance was reintroduced after truth completion";
}

TEST(RegionSchedulerPenDamageTest,
     MoreThan256ContinuousPreviewsDoNotHitInflightCapacity) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  constexpr int kSamples = 300;
  for (int sample = 0; sample < kSamples; ++sample) {
    const PlutoRect preview{8 + (sample % 8) * 4, 48, 16, 16};
    scheduler.submit_pen_damage(preview, PlutoRect{}, kPlutoRefreshText,
                                100 + static_cast<uint64_t>(sample));
    scheduler.tick(100 + static_cast<uint64_t>(sample));
    ASSERT_EQ(presenter.calls.size(), static_cast<size_t>(sample + 1));
    EXPECT_EQ(presenter.calls.back().cls, kPlutoRefreshFast);
    EXPECT_NE(presenter.calls.back().flags & kPlutoPresentFlagInkPriority, 0u);
  }
  EXPECT_EQ(presenter.accepted_count(), static_cast<size_t>(kSamples));
}

// ---- Stage-2 policy ---------------------------------------------------------

// Newest-content-wins supersession: back-to-back damage to the same region
// collapses at enqueue into one update. Presents read the live ledger, so
// one pass shows the newest content — this is the mechanism that kills the
// scroll Full-storm.
TEST(RegionSchedulerTest, NewestWinsSupersessionCollapsesRapidRedamage) {
  ScriptedPresenter presenter;
  presenter.ready_value = false; // hold everything queued
  RegionScheduler scheduler = make_scheduler(&presenter);

  const PlutoRect body{0, 16, 128, 112};
  for (uint64_t now = 0; now < 10; ++now) {
    submit_one(&scheduler, body, kPlutoRefreshFast, now);
    scheduler.tick(now);
  }
  EXPECT_EQ(presenter.calls.size(), 0u);
  EXPECT_EQ(scheduler.superseded_updates(), 9u);

  presenter.ready_value = true;
  scheduler.tick(20);
  // One present covers all ten damage submissions.
  ASSERT_EQ(presenter.calls.size(), 1u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshFast);
  EXPECT_EQ(accepted_presents_covering(presenter, body), 1u);

  // Nothing left behind.
  for (uint64_t now = 2000; now <= 10000; now += 1000) {
    scheduler.tick(now);
  }
  EXPECT_EQ(presenter.calls.size(), 1u);
}

// Merged supersession inherits the OLDEST enqueue time (anti-starvation):
// the EDF deadline of a continuously re-damaged region keeps aging, so it
// eventually beats fresher work instead of being pushed back forever.
TEST(RegionSchedulerTest, SupersededUpdateInheritsOldestAgeForEdf) {
  ScriptedPresenter presenter;
  presenter.ready_value = false;
  RegionSchedulerConfig config = test_config();
  // Identical deadlines: ordering is decided purely by enqueue age.
  config.class_deadline_us = {50000, 50000, 50000, 50000};
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect old_region{0, 0, 16, 16};     // fast, enqueued first
  const PlutoRect fresh_region{96, 96, 16, 16}; // ui, enqueued later
  submit_one(&scheduler, old_region, kPlutoRefreshFast, 0);
  submit_one(&scheduler, fresh_region, kPlutoRefreshUi, 1000);
  // Re-damage the old region: it merges and must KEEP its t=0 age.
  submit_one(&scheduler, old_region, kPlutoRefreshFast, 2000);

  presenter.ready_value = true;
  scheduler.tick(3000);
  ASSERT_GE(presenter.calls.size(), 2u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshFast);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshUi);
}

// EDF ordering across class queues: a starving lower-priority class with an
// earlier absolute deadline dispatches before fresher fast damage.
TEST(RegionSchedulerTest, EdfDispatchesEarlierDeadlineFirst) {
  ScriptedPresenter presenter;
  presenter.ready_value = false;
  RegionSchedulerConfig config = test_config();
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  // text enqueued at t=0: deadline 150000. fast at t=140000: deadline 165000.
  submit_one(&scheduler, PlutoRect{0, 0, 16, 16}, kPlutoRefreshText, 0);
  submit_one(&scheduler, PlutoRect{96, 96, 16, 16}, kPlutoRefreshFast, 140000);
  presenter.ready_value = true;
  scheduler.tick(140000);
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshText);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshFast);

  // And the tie-break the other way: contemporaneous damage dispatches the
  // short-deadline class first.
  presenter.calls.clear();
  scheduler.notify_completion(1);
  scheduler.notify_completion(2);
  for (uint64_t now = 300000; now <= 320000; now += 10000) {
    scheduler.tick(now); // drain synthetic completions
  }
  submit_one(&scheduler, PlutoRect{0, 64, 16, 16}, kPlutoRefreshText, 400000);
  submit_one(&scheduler, PlutoRect{96, 0, 16, 16}, kPlutoRefreshFast, 400000);
  scheduler.tick(400000);
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshFast);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshText);
}

// Mode-gated merging: nearby damage in the SAME class merges into one rect
// (min-added-area), while the same geometry split across two classes must
// never cross-merge — each class presents its own rect.
TEST(RegionSchedulerTest, MergesWithinClassNeverAcrossClasses) {
  {
    ScriptedPresenter presenter;
    RegionScheduler scheduler = make_scheduler(&presenter);
    const PlutoRect left{0, 0, 16, 16};
    const PlutoRect right{24, 0, 16, 16}; // 8 px gap <= merge_gap
    const PlutoRect rects[] = {left, right};
    const PlutoRefreshClass classes[] = {kPlutoRefreshFast, kPlutoRefreshFast};
    scheduler.submit_damage(rects, classes, 2, 0);
    scheduler.tick(0);
    ASSERT_EQ(presenter.calls.size(), 1u);
    EXPECT_EQ(presenter.calls[0].damage.size(), 1u); // merged
  }
  {
    ScriptedPresenter presenter;
    RegionSchedulerConfig config = test_config();
    config.presenter_collision_safe = true; // isolate merging from parking
    RegionScheduler scheduler = make_scheduler(&presenter, config);
    const PlutoRect left{0, 0, 16, 16};
    const PlutoRect right{24, 0, 16, 16};
    const PlutoRect rects[] = {left, right};
    const PlutoRefreshClass classes[] = {kPlutoRefreshFast, kPlutoRefreshUi};
    scheduler.submit_damage(rects, classes, 2, 0);
    scheduler.tick(0);
    ASSERT_EQ(presenter.calls.size(), 2u);
    EXPECT_NE(presenter.calls[0].cls, presenter.calls[1].cls);
    for (const ScriptedPresenter::Call &call : presenter.calls) {
      EXPECT_EQ(call.damage.size(), 1u);
    }
  }
}

// Value-aware admission: damage whose content an in-flight update already
// presents (covered, same content epoch, >= quality) is absorbed for free
// instead of parking; newer content over the same region still conflicts.
TEST(RegionSchedulerTest, RedundantDamageAbsorbsNewContentParks) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true;
  // Force the ui batch (big rect) to dispatch before the fast batch (sub
  // rect) so the fast rect meets a covering in-flight of the same epoch.
  config.class_deadline_us = {60000, 25000, 150000, 300000};
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  const PlutoRect big{0, 0, 64, 64};
  const PlutoRect sub{16, 16, 16, 16};
  const PlutoRect rects[] = {big, sub};
  const PlutoRefreshClass classes[] = {kPlutoRefreshUi, kPlutoRefreshFast};
  scheduler.submit_damage(rects, classes, 2, 0);
  scheduler.tick(0);
  // Only the ui present went out; the fast sub-rect was absorbed into it.
  ASSERT_EQ(presenter.calls.size(), 1u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshUi);
  EXPECT_EQ(scheduler.absorbed_updates(), 1u);
  EXPECT_EQ(scheduler.parked_updates(), 0u);

  // NEW content over the same region while still inflight: genuine conflict,
  // must park (newer epoch), then present after completion.
  submit_one(&scheduler, sub, kPlutoRefreshFast, 100);
  scheduler.tick(100);
  EXPECT_EQ(presenter.calls.size(), 1u);
  EXPECT_EQ(scheduler.parked_updates(), 1u);
  scheduler.notify_completion(presenter.calls[0].frame_id);
  scheduler.tick(200);
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshFast);
}

// CBS non-starvation: a deep settle backlog never delays a PEN admission
// beyond its tick — the pen dispatches first every single tick.
TEST(RegionSchedulerTest, SettleBacklogNeverStarvesPen) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_collision_safe = true; // maximum settle pressure
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  // Deep settle backlog (distinct rects: identical ones would absorb into
  // each other's in-flight for free), disjoint from the pen lane.
  for (int i = 0; i < 8; ++i) {
    scheduler.submit_settle(PlutoRect{0, 8 * i, 128, 8}, kPlutoRefreshText, 0);
  }
  uint64_t now = 0;
  for (int tick = 0; tick < 8; ++tick) {
    now += 1000;
    scheduler.submit_pen_damage(PlutoRect{8 * tick, 96, 8, 8}, PlutoRect{},
                                kPlutoRefreshText, now);
    const size_t calls_before = presenter.calls.size();
    scheduler.tick(now);
    // The pen present is the FIRST call of every tick.
    ASSERT_GT(presenter.calls.size(), calls_before);
    EXPECT_TRUE((presenter.calls[calls_before].flags &
                 kPlutoPresentFlagInkPriority) != 0u)
        << "tick " << tick << ": settle dispatched before pen";
  }
  // With the pen resting, the settle backlog drains under its budget.
  for (uint64_t rest = now + 10000; rest < now + 200000; rest += 1000) {
    scheduler.tick(rest);
  }
  EXPECT_EQ(scheduler.dispatched_settles(), 8u);
}

TEST(RegionSchedulerTest,
     InputGateSkipsIntrusiveFullButDispatchesExplicitlyRequiredTextRepair) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.text_settle_nonintrusive = false; // qtfb-style capability
  RegionPresenterHooks hooks;
  hooks.user_data = &presenter;
  hooks.ready = &ScriptedPresenter::ready;
  hooks.present = &ScriptedPresenter::present;
  RegionScheduler scheduler(config, hooks);
  presenter.complete_during_present = &scheduler;

  scheduler.submit_settle(PlutoRect{0, 0, 32, 32}, kPlutoRefreshFull, 0);
  scheduler.submit_settle(PlutoRect{64, 64, 16, 16}, kPlutoRefreshText, 0,
                          /*required=*/true);

  scheduler.tick(0, /*maintenance_allowed=*/true,
                 /*intrusive_maintenance_allowed=*/false);
  ASSERT_EQ(presenter.calls.size(), 1u);
  EXPECT_EQ(presenter.calls[0].cls, kPlutoRefreshText);
  EXPECT_NE(presenter.calls[0].flags & kPlutoPresentFlagRequiredSettle, 0u);
  EXPECT_NE(presenter.calls[0].flags & kPlutoPresentFlagSettle, 0u);

  scheduler.tick(1, /*maintenance_allowed=*/true,
                 /*intrusive_maintenance_allowed=*/false);
  EXPECT_EQ(presenter.calls.size(), 1u) << "Full must remain held by input";

  scheduler.tick(2, /*maintenance_allowed=*/true,
                 /*intrusive_maintenance_allowed=*/true);
  ASSERT_EQ(presenter.calls.size(), 2u);
  EXPECT_EQ(presenter.calls[1].cls, kPlutoRefreshFull);
}

// Eventual consistency: random damage / decline / completion
// sequences on a virtual clock — every damaged tile is eventually covered
// by an accepted present issued at-or-after its last damage.
TEST(RegionSchedulerPropertyTest, EveryDamagedTileEventuallyPresented) {
  for (uint32_t seed = 1; seed <= 5; ++seed) {
    ScriptedPresenter presenter;
    RegionSchedulerConfig config = test_config();
    RegionScheduler scheduler = make_scheduler(&presenter, config);
    std::mt19937 rng(seed);
    std::uniform_int_distribution<int> coord(0, 112);
    std::uniform_int_distribution<int> size(1, 16);
    std::uniform_int_distribution<int> cls_dist(0, 3);
    std::uniform_int_distribution<int> decline(0, 3);

    // Per-tile (8 px grid) last-damage submission index; presents are
    // stamped with the damage index current when they were issued, so
    // coverage counts only when a present AT-OR-AFTER the damage covers the
    // tile (presents read the live ledger, so that present carried the
    // damaged content).
    constexpr int kTiles = 16;
    std::array<std::array<int, kTiles>, kTiles> last_damage{};
    for (auto &row : last_damage) {
      row.fill(-1);
    }
    int damage_seq = 0;
    std::vector<int> call_stamp;
    const auto stamp_new_calls = [&] {
      while (call_stamp.size() < presenter.calls.size()) {
        call_stamp.push_back(damage_seq);
      }
    };

    uint64_t now = 0;
    for (int step = 0; step < 200; ++step) {
      now += 500;
      // Random decline pattern: ~25% of presents refused.
      presenter.present_results.push_back(decline(rng) != 0);
      if (step % 2 == 0) {
        const PlutoRect rect{coord(rng), coord(rng), size(rng), size(rng)};
        const auto cls = static_cast<PlutoRefreshClass>(cls_dist(rng));
        submit_one(&scheduler, rect, cls, now);
        ++damage_seq;
        for (int ty = rect.y / 8; ty <= (rect.y + rect.height - 1) / 8; ++ty) {
          for (int tx = rect.x / 8; tx <= (rect.x + rect.width - 1) / 8; ++tx) {
            last_damage[ty][tx] = damage_seq;
          }
        }
      }
      scheduler.tick(now);
      stamp_new_calls();
    }
    // Drain: accept everything from here on, run the clock out.
    presenter.present_results.assign(presenter.calls.size(), true);
    for (int step = 0; step < 400 && !scheduler.idle(); ++step) {
      now += 2000;
      scheduler.tick(now);
      stamp_new_calls();
    }
    EXPECT_TRUE(scheduler.idle()) << "seed " << seed;
    stamp_new_calls();

    // Coverage check: every damaged tile must be covered by an ACCEPTED
    // present issued at-or-after its last damage.
    std::array<std::array<int, kTiles>, kTiles> covered_at{};
    for (auto &row : covered_at) {
      row.fill(-1);
    }
    for (size_t c = 0; c < presenter.calls.size(); ++c) {
      const ScriptedPresenter::Call &call = presenter.calls[c];
      if (!call.accepted) {
        continue;
      }
      for (const PlutoRect &rect : call.damage) {
        const PlutoRect clipped = pluto::rect_clip(rect, 128, 128);
        if (pluto::rect_is_empty(clipped)) {
          continue;
        }
        for (int ty = clipped.y / 8;
             ty <= (clipped.y + clipped.height - 1) / 8 && ty < kTiles; ++ty) {
          for (int tx = clipped.x / 8;
               tx <= (clipped.x + clipped.width - 1) / 8 && tx < kTiles; ++tx) {
            covered_at[ty][tx] = std::max(covered_at[ty][tx], call_stamp[c]);
          }
        }
      }
    }
    for (int ty = 0; ty < kTiles; ++ty) {
      for (int tx = 0; tx < kTiles; ++tx) {
        if (last_damage[ty][tx] >= 0) {
          EXPECT_GE(covered_at[ty][tx], last_damage[ty][tx])
              << "seed " << seed << " tile (" << tx << "," << ty
              << ") damaged but never presented afterwards";
        }
      }
    }
  }
}

// Stage-6 note: structural Full promotion moved out of the scheduler into
// the ClassifyLadder scenecut rung; the frame-0 and
// large-change flash behaviors are re-pinned in classify_ladder_test.cc and
// the replay-harness baselines. The scheduler dispatches what it is given.

// Probe: a quality (GC16-class) settle IN FLIGHT elsewhere — dispatched,
// completion outstanding — must never park pen preview on a disjoint region.
// Every preview is admitted and dispatched on its own tick while the settle
// stays open.
TEST(RegionSchedulerTest,
     PenPreviewDispatchesEveryTickWhileSettleInFlightElsewhere) {
  ScriptedPresenter presenter;
  RegionSchedulerConfig config = test_config();
  config.presenter_reports_completion = true; // completions never synthesized
  RegionScheduler scheduler = make_scheduler(&presenter, config);

  // A Text-class settle occupies the top band and stays in flight (its
  // completion never arrives during the probe).
  scheduler.submit_settle(PlutoRect{0, 0, 128, 32}, kPlutoRefreshText, 0);
  scheduler.tick(0);
  ASSERT_EQ(presenter.calls.size(), 1u);
  ASSERT_EQ(presenter.calls[0].cls, kPlutoRefreshText);
  const uint64_t settle_frame = presenter.calls[0].frame_id;

  // Pen strokes land in the bottom band, disjoint from the settle.
  uint64_t now = 0;
  for (int tick = 1; tick <= 6; ++tick) {
    now += 1000;
    scheduler.submit_pen_damage(PlutoRect{8 * tick, 96, 8, 8}, PlutoRect{},
                                kPlutoRefreshText, now);
    const size_t calls_before = presenter.calls.size();
    scheduler.tick(now);
    ASSERT_EQ(presenter.calls.size(), calls_before + 1)
        << "tick " << tick << ": preview parked behind in-flight settle";
    const ScriptedPresenter::Call &call = presenter.calls.back();
    EXPECT_TRUE((call.flags & kPlutoPresentFlagInkPriority) != 0u);
    EXPECT_EQ(call.cls, kPlutoRefreshFast);
  }
  // The settle is still in flight the whole time.
  scheduler.notify_completion(settle_frame);
}

// merge_scratch_to_cap equivalence: the incremental cached-row min-waste
// reduction must reproduce the retired full-rescan reference EXACTLY —
// same merge sequence, same tie-breaks, same final rect list in the same
// order. The reference below is the frozen algorithm verbatim: phase 1
// merges any pair within merge_gap (restart scan after every merge); phase 2
// repeatedly merges the lexicographically-first pair (i, j) attaining the
// minimum rect_merge_waste, writing the aligned union to i and swapping the
// last rect into j. Randomized storms of pairwise non-intersecting rects
// (so enqueue order is deterministic: no supersession folding) across cap
// depths pin the dispatched damage arrays byte-for-byte.
namespace {

std::vector<PlutoRect> reference_coalesce(std::vector<PlutoRect> rects,
                                          const RegionSchedulerConfig &config,
                                          size_t cap) {
  const int32_t align = static_cast<int32_t>(config.align_px);
  const int32_t gap = static_cast<int32_t>(config.merge_gap_px);
  std::vector<PlutoRect> out;
  for (const PlutoRect &rect : rects) {
    const PlutoRect aligned =
        pluto::rect_align_out(rect, align, config.width, config.height);
    if (!pluto::rect_is_empty(aligned)) {
      out.push_back(aligned);
    }
  }
  if (out.size() <= 1) {
    return out;
  }
  // Phase 1 (frozen): gap-driven coalesce with restart-on-merge.
  bool changed = true;
  while (changed) {
    changed = false;
    for (size_t i = 0; i < out.size() && !changed; ++i) {
      for (size_t j = i + 1; j < out.size(); ++j) {
        if (pluto::rect_gap_px(out[i], out[j]) <= gap) {
          out[i] = pluto::rect_align_out(pluto::rect_union(out[i], out[j]),
                                         align, config.width, config.height);
          out[j] = out.back();
          out.pop_back();
          changed = true;
          break;
        }
      }
    }
  }
  // Phase 2 (frozen): full-rescan min-waste reduction to the cap.
  while (out.size() > cap && out.size() > 1) {
    size_t best_i = 0;
    size_t best_j = 1;
    int64_t best_waste = pluto::rect_merge_waste(out[0], out[1]);
    for (size_t i = 0; i < out.size(); ++i) {
      for (size_t j = i + 1; j < out.size(); ++j) {
        const int64_t waste = pluto::rect_merge_waste(out[i], out[j]);
        if (waste < best_waste) {
          best_waste = waste;
          best_i = i;
          best_j = j;
        }
      }
    }
    out[best_i] =
        pluto::rect_align_out(pluto::rect_union(out[best_i], out[best_j]),
                              align, config.width, config.height);
    out[best_j] = out.back();
    out.pop_back();
  }
  return out;
}

} // namespace

TEST(RegionSchedulerTest, MergeToCapMatchesFullRescanReference) {
  std::mt19937 rng(0x5ca1ab1e);
  const size_t storm_sizes[] = {2,  3,  5,  8,  13, 21,  34,  55,
                                89, 96, 64, 32, 16, 128, 200, 256};
  const uint8_t caps[] = {1, 2, 4, 6, 13};
  int case_index = 0;
  for (const size_t storm : storm_sizes) {
    const uint8_t cap = caps[case_index++ % (sizeof(caps) / sizeof(caps[0]))];
    RegionSchedulerConfig config = test_config();
    config.width = 954;
    config.height = 1696;
    config.max_rects = {cap, cap, cap, cap};

    // Pairwise non-intersecting storm rects (push_pending then appends in
    // submission order — the reference sees the identical queue). Mixed
    // spacing: some clusters land within merge_gap (phase-1 coverage), the
    // rest scatter (phase-2 depth).
    std::uniform_int_distribution<int32_t> x_dist(0, config.width - 33);
    std::uniform_int_distribution<int32_t> y_dist(0, config.height - 33);
    std::uniform_int_distribution<int32_t> size_dist(1, 32);
    std::vector<PlutoRect> rects;
    int attempts = 0;
    while (rects.size() < storm && attempts < 200000) {
      ++attempts;
      const PlutoRect candidate{x_dist(rng), y_dist(rng), size_dist(rng),
                                size_dist(rng)};
      bool overlaps = false;
      for (const PlutoRect &existing : rects) {
        if (pluto::rect_intersects(existing, candidate)) {
          overlaps = true;
          break;
        }
      }
      if (!overlaps) {
        rects.push_back(candidate);
      }
    }
    ASSERT_GE(rects.size(), 2u);

    ScriptedPresenter presenter;
    RegionScheduler scheduler = make_scheduler(&presenter, config);
    std::vector<PlutoRefreshClass> classes(rects.size(), kPlutoRefreshUi);
    scheduler.submit_damage(rects.data(), classes.data(), rects.size(), 0);
    scheduler.tick(0);

    ASSERT_EQ(presenter.calls.size(), 1u) << "storm=" << rects.size();
    const std::vector<PlutoRect> &dispatched = presenter.calls[0].damage;
    const std::vector<PlutoRect> expected =
        reference_coalesce(rects, config, cap);
    ASSERT_EQ(dispatched.size(), expected.size()) << "storm=" << rects.size();
    for (size_t i = 0; i < expected.size(); ++i) {
      EXPECT_EQ(dispatched[i].x, expected[i].x)
          << "storm=" << rects.size() << " rect " << i;
      EXPECT_EQ(dispatched[i].y, expected[i].y)
          << "storm=" << rects.size() << " rect " << i;
      EXPECT_EQ(dispatched[i].width, expected[i].width)
          << "storm=" << rects.size() << " rect " << i;
      EXPECT_EQ(dispatched[i].height, expected[i].height)
          << "storm=" << rects.size() << " rect " << i;
    }
  }
}

// ---- debt-adaptive promotion (smart fast partials) --------------------------

TEST(RegionSchedulerBehaviorTest,
     AccrualDecaysOnlyPreexistingDebtIndependentOfIdleTickOrdering) {
  pluto::TileGrid grid;
  ASSERT_TRUE(grid.configure(128, 128, 32));
  pluto::GhostLedger ticked_ghost;
  pluto::GhostLedger unticked_ghost;
  pluto::StressLedger ticked_stress;
  pluto::StressLedger unticked_stress;
  ASSERT_TRUE(ticked_ghost.configure(grid, 1000, 0xffffu));
  ASSERT_TRUE(unticked_ghost.configure(grid, 1000, 0xffffu));
  ASSERT_TRUE(ticked_stress.configure(grid));
  ASSERT_TRUE(unticked_stress.configure(grid));

  RegionSchedulerConfig config = test_config();
  config.debt_promote_threshold = 0xffffu;
  RegionScheduler ticked(config, {}, &ticked_ghost, &ticked_stress);
  RegionScheduler unticked(config, {}, &unticked_ghost, &unticked_stress);
  ASSERT_TRUE(ticked.valid());
  ASSERT_TRUE(unticked.valid());

  const PlutoRect rect{0, 0, 32, 32};
  submit_one(&ticked, rect, kPlutoRefreshFast, 1'000);
  submit_one(&unticked, rect, kPlutoRefreshFast, 1'000);

  // Model the renderer worker winning the race in one process but a new
  // frame winning it in the other. Both content streams are timestamped
  // identically, so the old impulse must decay to the same value and the new
  // impulse must begin at `now_us` in both cases.
  constexpr std::uint64_t kNowUs = 501'000;
  ticked_ghost.tick(kNowUs);
  ticked_stress.tick(kNowUs);
  submit_one(&ticked, rect, kPlutoRefreshFast, kNowUs);
  submit_one(&unticked, rect, kPlutoRefreshFast, kNowUs);

  pluto::GhostLedgerState ticked_ghost_state;
  pluto::GhostLedgerState unticked_ghost_state;
  pluto::StressLedgerState ticked_stress_state;
  pluto::StressLedgerState unticked_stress_state;
  ASSERT_TRUE(ticked_ghost.export_state(&ticked_ghost_state));
  ASSERT_TRUE(unticked_ghost.export_state(&unticked_ghost_state));
  ASSERT_TRUE(ticked_stress.export_state(&ticked_stress_state));
  ASSERT_TRUE(unticked_stress.export_state(&unticked_stress_state));
  EXPECT_TRUE(ticked_ghost_state.debt == unticked_ghost_state.debt);
  EXPECT_EQ(ticked_ghost_state.last_decay_us,
            unticked_ghost_state.last_decay_us);
  EXPECT_TRUE(ticked_stress_state.stress == unticked_stress_state.stress);
  EXPECT_EQ(ticked_stress_state.last_decay_us,
            unticked_stress_state.last_decay_us);
}

// A region updating slower than the promote gap but faster than settle
// quiescence re-arms the planner's window forever — without promotion its
// ghost would never be repaid while the activity continues. Once the tiles'
// average debt crosses the promote line, the NEXT quiet update dispatches as
// Text (same pixels, quality drive), the dispatch clears the ledger, and the
// duty cycle starts over.
TEST(RegionSchedulerBehaviorTest, DebtPromotesQuietPartialToText) {
  pluto::TileGrid grid;
  ASSERT_TRUE(grid.configure(128, 128, 32));
  pluto::GhostLedger ghost;
  ASSERT_TRUE(ghost.configure(grid, 1000, 96));

  ScriptedPresenter presenter;
  RegionPresenterHooks hooks;
  hooks.user_data = &presenter;
  hooks.ready = &ScriptedPresenter::ready;
  hooks.present = &ScriptedPresenter::present;
  RegionScheduler scheduler(test_config(), hooks, &ghost);
  presenter.complete_during_present = &scheduler;

  const PlutoRect rect{0, 0, 32, 32}; // exactly one ledger tile

  // Animation cadence (50 ms << 250 ms gap): debt piles up well past the
  // threshold but the rate gate keeps every dispatch rail-class.
  for (uint64_t now = 0; now <= 200000; now += 50000) {
    submit_one(&scheduler, rect, kPlutoRefreshFast, now);
    scheduler.tick(now);
  }
  for (const ScriptedPresenter::Call &call : presenter.calls) {
    EXPECT_EQ(call.cls, kPlutoRefreshFast);
  }
  EXPECT_EQ(scheduler.debt_promoted_updates(), 0u);

  // Quiet gap (300 ms) with deep debt: promoted to Text.
  submit_one(&scheduler, rect, kPlutoRefreshFast, 500000);
  scheduler.tick(500000);
  EXPECT_EQ(scheduler.debt_promoted_updates(), 1u);
  ASSERT_TRUE(!presenter.calls.empty());
  EXPECT_EQ(presenter.calls.back().cls, kPlutoRefreshText);

  // The quality dispatch cleared the ledger: the next quiet update has no
  // debt to repay and stays Fast.
  submit_one(&scheduler, rect, kPlutoRefreshFast, 900000);
  scheduler.tick(900000);
  EXPECT_EQ(scheduler.debt_promoted_updates(), 1u);
  EXPECT_EQ(presenter.calls.back().cls, kPlutoRefreshFast);
}

// Optical rail stress is not content chroma. Inferring ChromaPending from a
// debt promotion caused achromatic tiles to receive regional Full blackouts;
// the global pigment ledger now owns that separate obligation.
TEST(RegionSchedulerBehaviorTest, ColorPromotionDoesNotInventChroma) {
  pluto::TileGrid grid;
  ASSERT_TRUE(grid.configure(128, 128, 32));
  pluto::GhostLedger ghost;
  ASSERT_TRUE(ghost.configure(grid, 1000, 96));
  pluto::ChromaPendingSet chroma;
  ASSERT_TRUE(chroma.configure(grid));

  ScriptedPresenter presenter;
  RegionPresenterHooks hooks;
  hooks.user_data = &presenter;
  hooks.ready = &ScriptedPresenter::ready;
  hooks.present = &ScriptedPresenter::present;
  RegionSchedulerConfig config = test_config();
  RegionScheduler scheduler(config, hooks, &ghost, nullptr, &chroma);
  presenter.complete_during_present = &scheduler;

  const PlutoRect rect{0, 0, 32, 32};
  for (uint64_t now = 0; now <= 200000; now += 50000) {
    submit_one(&scheduler, rect, kPlutoRefreshFast, now);
    scheduler.tick(now);
  }
  EXPECT_FALSE(chroma.any()); // rail passes alone never mark

  submit_one(&scheduler, rect, kPlutoRefreshFast, 500000);
  scheduler.tick(500000);
  ASSERT_EQ(scheduler.debt_promoted_updates(), 1u);
  EXPECT_FALSE(chroma.pending(0, 0));
}

// A promotion turns the update into a ~3x longer quality drive; a region
// with work already on glass must never take one mid-flight.
TEST(RegionSchedulerBehaviorTest, DebtPromotionSkipsInflightConflict) {
  pluto::TileGrid grid;
  ASSERT_TRUE(grid.configure(128, 128, 32));
  pluto::GhostLedger ghost;
  ASSERT_TRUE(ghost.configure(grid, 1000, 96));

  ScriptedPresenter presenter; // NO synchronous completion
  RegionPresenterHooks hooks;
  hooks.user_data = &presenter;
  hooks.ready = &ScriptedPresenter::ready;
  hooks.present = &ScriptedPresenter::present;
  RegionSchedulerConfig config = test_config();
  // This case pins the in-flight safety gate, not the default threshold.
  // Keep the post-decay debt unambiguously above the line at the final quiet
  // submission now that admission correctly advances old debt first.
  config.debt_promote_threshold = 1024;
  RegionScheduler scheduler(config, hooks, &ghost);

  // Prime deep debt through the pen-preview lane (three app-damage passes),
  // leaving the dispatched preview update in flight.
  const PlutoRect rect{0, 0, 32, 32};
  scheduler.submit_pen_damage(rect, PlutoRect{}, kPlutoRefreshText, 0);
  scheduler.tick(0);
  scheduler.submit_pen_damage(rect, PlutoRect{}, kPlutoRefreshText, 100);
  scheduler.submit_pen_damage(rect, PlutoRect{}, kPlutoRefreshText, 200);
  ASSERT_TRUE(scheduler.anything_inflight());

  // Quiet gap + deep debt, but the region is busy on glass: no promotion.
  submit_one(&scheduler, rect, kPlutoRefreshFast, 400000);
  EXPECT_EQ(scheduler.debt_promoted_updates(), 0u);

  // Once the glass drains and the region is quiet again, the debt promotes.
  scheduler.tick(400000); // drains preview #1; sends pending preview batch
  scheduler.tick(450000); // drains preview batch; sends parked generic Fast
  scheduler.tick(500000); // drains the Fast update; glass idle
  ASSERT_TRUE(!scheduler.anything_inflight());
  submit_one(&scheduler, rect, kPlutoRefreshFast, 800000);
  scheduler.tick(800000);
  EXPECT_EQ(scheduler.debt_promoted_updates(), 1u);
  EXPECT_EQ(presenter.calls.back().cls, kPlutoRefreshText);
}

TEST(RegionSchedulerBehaviorTest,
     IdlePersistentBehaviorStateRoundTripsAndRejectsBusyOrMismatchedState) {
  pluto::TileGrid grid;
  ASSERT_TRUE(grid.configure(128, 128, 32));
  pluto::GhostLedger source_ghost;
  pluto::GhostLedger destination_ghost;
  ASSERT_TRUE(source_ghost.configure(grid, 1000, 224));
  ASSERT_TRUE(destination_ghost.configure(grid, 1000, 224));
  RegionSchedulerConfig config = test_config();
  config.serialize_pen_truth_by_tile = true;

  RegionScheduler source(config, {}, &source_ghost);
  ASSERT_TRUE(source.valid());
  submit_one(&source, PlutoRect{0, 0, 32, 32}, kPlutoRefreshFast, 123'000);
  ASSERT_TRUE(source.discard_pending());
  ASSERT_TRUE(source.idle());

  RegionSchedulerState state;
  ASSERT_TRUE(source.export_state(&state));
  state.next_frame_id = 41;
  state.cbs_total_slots = 17;
  state.cbs_settle_slots = 4;

  RegionScheduler destination(config, {}, &destination_ghost);
  ASSERT_TRUE(destination.import_state(state));
  RegionSchedulerState actual;
  ASSERT_TRUE(destination.export_state(&actual));
  EXPECT_EQ(actual.next_frame_id, 41u);
  EXPECT_EQ(actual.damage_epoch, 1u);
  EXPECT_EQ(actual.cbs_total_slots, 17u);
  EXPECT_EQ(actual.cbs_settle_slots, 4u);
  EXPECT_TRUE(actual.last_submit_us == state.last_submit_us);
  ASSERT_EQ(actual.last_submit_us.size(), grid.tile_count());
  EXPECT_EQ(actual.last_submit_us[0], 123'000u);

  RegionSchedulerState corrupt = state;
  corrupt.last_submit_us.pop_back();
  EXPECT_FALSE(destination.import_state(corrupt));
  corrupt = state;
  corrupt.config.debt_promote_min_gap_us += 1;
  EXPECT_FALSE(destination.import_state(corrupt));
  corrupt = state;
  corrupt.cbs_settle_slots = corrupt.cbs_total_slots + 1;
  EXPECT_FALSE(destination.import_state(corrupt));
  ASSERT_TRUE(destination.export_state(&actual));
  EXPECT_TRUE(actual.last_submit_us == state.last_submit_us);
  EXPECT_EQ(actual.cbs_total_slots, 17u);

  destination.reserve_pen_focus(PlutoRect{0, 0, 32, 32}, UINT64_MAX);
  EXPECT_FALSE(destination.export_state(&actual));
  EXPECT_FALSE(destination.import_state(state));
  destination.clear_pen_focus();
  submit_one(&destination, PlutoRect{64, 64, 16, 16}, kPlutoRefreshUi, 200'000);
  EXPECT_FALSE(destination.export_state(&actual));
}

TEST(RegionSchedulerBehaviorTest,
     HandoffDropsOnlyNeverDispatchedMaintenanceAndNeverUserTruth) {
  ScriptedPresenter presenter;
  presenter.ready_value = false;
  RegionScheduler scheduler = make_scheduler(&presenter);
  ASSERT_TRUE(scheduler.valid());

  const PlutoRect maintenance{0, 0, 32, 32};
  scheduler.submit_settle(maintenance, kPlutoRefreshText, 1000);
  ASSERT_TRUE(scheduler.settle_work_pending());
  ASSERT_TRUE(!scheduler.idle());
  EXPECT_TRUE(scheduler.discard_pending_maintenance_for_handoff());
  EXPECT_TRUE(scheduler.idle());

  const PlutoRect user{64, 64, 32, 32};
  scheduler.submit_damage(
      &user, std::array<PlutoRefreshClass, 1>{kPlutoRefreshUi}.data(), 1, 2000);
  scheduler.submit_settle(maintenance, kPlutoRefreshText, 2000);
  ASSERT_TRUE(scheduler.user_work_pending());
  EXPECT_FALSE(scheduler.discard_pending_maintenance_for_handoff());
  EXPECT_TRUE(scheduler.user_work_pending())
      << "handoff maintenance cleanup must never discard app-owned pixels";
  EXPECT_TRUE(scheduler.settle_work_pending());
}
