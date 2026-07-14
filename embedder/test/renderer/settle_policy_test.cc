// SettlePlanner suite (Stage 2): the single
// settle authority. Pins quiescence + ARC re-arm (no settle-thrash under
// continuous animation), debt-driven ordering, chroma-pending -> Full on
// color panels, the whole-screen flash budget, LSM clustering bounds (no
// union flash across distant regions), and the old behavioral contracts
// (exactly one settle burst after partial-then-idle; Full arms no settle).

#include <gtest/gtest.h>

#include <cstdint>
#include <memory>
#include <vector>

#include "renderer/ledgers.h"
#include "renderer/perception.h"
#include "renderer/rect_utils.h"
#include "renderer/region_scheduler.h"
#include "renderer/renderer_config.h"
#include "renderer/settle_policy.h"

namespace {

using pluto::ChromaPendingSet;
using pluto::GhostLedger;
using pluto::PerceptionConstants;
using pluto::RegionPresenterHooks;
using pluto::RegionScheduler;
using pluto::RegionSchedulerConfig;
using pluto::RendererConfig;
using pluto::SettlePlanner;
using pluto::SettlePlannerConfig;
using pluto::SettlePlannerState;
using pluto::StressLedger;
using pluto::TileGrid;

struct RecordingPresenter {
  struct Call {
    PlutoRefreshClass cls = kPlutoRefreshUi;
    uint32_t flags = 0;
    std::vector<PlutoRect> damage;
    bool sparkle() const { return (flags & kPlutoPresentFlagSparkle) != 0; }
    uint32_t sparkle_phase() const {
      return (flags & kPlutoPresentSparklePhaseMask) >>
             kPlutoPresentSparklePhaseShift;
    }
  };
  std::vector<Call> calls;

  size_t non_sparkle_count() const {
    size_t count = 0;
    for (const Call &call : calls) {
      count += call.sparkle() ? 0u : 1u;
    }
    return count;
  }
  size_t sparkle_count() const { return calls.size() - non_sparkle_count(); }

  static bool ready(void *, PlutoRefreshClass) { return true; }
  static bool present(void *user_data, const PlutoPresentRequest *request) {
    auto *self = static_cast<RecordingPresenter *>(user_data);
    Call call;
    call.cls = request->refresh_class;
    call.flags = request->flags;
    for (size_t i = 0; i < request->damage_count; ++i) {
      call.damage.push_back(request->damage[i]);
    }
    self->calls.push_back(std::move(call));
    return true;
  }
};

// A 128x128 / 32 px-tile pipeline on a virtual clock: ledgers + planner +
// scheduler + always-accepting presenter with synthetic completions.
struct Harness {
  explicit Harness(bool panel_is_color = false,
                   RendererConfig renderer_config = RendererConfig{}) {
    TileGrid grid;
    grid.configure(128, 128, 32);
    ghost.configure(grid, renderer_config.ghost_tau_ms,
                    renderer_config.ghost_debt_settle_threshold);
    stress.configure(grid);
    chroma.configure(grid);

    SettlePlannerConfig planner_config;
    planner_config.width = 128;
    planner_config.height = 128;
    planner_config.tile_px = 32;
    planner_config.align_px = 8;
    planner_config.panel_is_color = panel_is_color;
    planner_config.perception = PerceptionConstants(renderer_config);
    planner.configure(planner_config, &ghost, &stress, &chroma);

    RegionSchedulerConfig scheduler_config;
    scheduler_config.width = 128;
    scheduler_config.height = 128;
    scheduler_config.fence_margin = 1.0f;
    scheduler_config.latency_model_us = {1000, 2000, 3000, 4000};
    RegionPresenterHooks hooks;
    hooks.user_data = &presenter;
    hooks.ready = &RecordingPresenter::ready;
    hooks.present = &RecordingPresenter::present;
    scheduler = std::make_unique<RegionScheduler>(scheduler_config, hooks,
                                                  &ghost, &stress, &chroma);
  }

  void damage(const PlutoRect &rect, PlutoRefreshClass cls, uint64_t now_us) {
    planner.note_damage(rect, now_us);
    scheduler->submit_damage(&rect, &cls, 1, now_us);
    tick(now_us);
  }

  void tick(uint64_t now_us, bool maintenance_allowed = true,
            bool intrusive_maintenance_allowed = true) {
    planner.tick(now_us, scheduler.get(), maintenance_allowed,
                 intrusive_maintenance_allowed);
    scheduler->tick(now_us, maintenance_allowed, intrusive_maintenance_allowed);
  }

  // Runs the virtual clock forward in 50 ms ticks.
  void run_until(uint64_t from_us, uint64_t to_us) {
    for (uint64_t now = from_us; now <= to_us; now += 50000) {
      tick(now);
    }
  }

  void run_until_gated(uint64_t from_us, uint64_t to_us,
                       bool intrusive_maintenance_allowed) {
    for (uint64_t now = from_us; now <= to_us; now += 50000) {
      tick(now, /*maintenance_allowed=*/true, intrusive_maintenance_allowed);
    }
  }

  GhostLedger ghost;
  StressLedger stress;
  ChromaPendingSet chroma;
  SettlePlanner planner;
  RecordingPresenter presenter;
  std::unique_ptr<RegionScheduler> scheduler;
};

bool covers(const PlutoRect &outer, const PlutoRect &inner) {
  return inner.x >= outer.x && inner.y >= outer.y &&
         pluto::rect_right(inner) <= pluto::rect_right(outer) &&
         pluto::rect_bottom(inner) <= pluto::rect_bottom(outer);
}

} // namespace

// Re-pin of the old settle contract: one partial update then idle yields
// exactly ONE settle burst, at quality class, covering the partial region —
// and it never repeats while the region stays clean. The settle is followed
// by the flash-free sparkle rotation (scattered white top-off passes) over
// the settled region: exactly 16 phases, then quiet forever.
TEST(SettlePlannerTest, ExactlyOneSettleBurstAfterPartialThenIdle) {
  Harness h;
  const PlutoRect rect{8, 8, 16, 16};
  h.damage(rect, kPlutoRefreshFast, 0);
  ASSERT_EQ(h.presenter.calls.size(), 1u); // the fast pass itself

  h.run_until(50000, 2'000'000);
  EXPECT_EQ(h.scheduler->dispatched_settles(), 1u);
  ASSERT_GE(h.presenter.calls.size(), 2u);
  EXPECT_EQ(h.presenter.non_sparkle_count(), 2u);
  EXPECT_EQ(h.presenter.calls[1].cls, kPlutoRefreshText);
  ASSERT_EQ(h.presenter.calls[1].damage.size(), 1u);
  EXPECT_TRUE(covers(h.presenter.calls[1].damage[0], rect));

  // Long after: still exactly one settle (debt was cleared by the settle),
  // and the sparkle rotation ran its 16 phases over the settled region,
  // in order, then stopped.
  h.run_until(2'050'000, 20'000'000);
  EXPECT_EQ(h.scheduler->dispatched_settles(), 1u);
  EXPECT_EQ(h.presenter.non_sparkle_count(), 2u);
  EXPECT_EQ(h.presenter.sparkle_count(), 16u);
  uint32_t expected_phase = 0;
  for (const RecordingPresenter::Call &call : h.presenter.calls) {
    if (!call.sparkle()) {
      continue;
    }
    EXPECT_EQ(call.sparkle_phase(), expected_phase++);
    ASSERT_EQ(call.damage.size(), 1u);
    EXPECT_TRUE(covers(call.damage[0], rect));
  }
}

// Sparkle rotation cancels on re-damage (ARC): repair work over content
// that just changed would be destroyed; the next settle re-arms it.
TEST(SettlePlannerTest, SparkleRotationCancelsOnRedamage) {
  Harness h;
  const PlutoRect rect{8, 8, 16, 16};
  h.damage(rect, kPlutoRefreshFast, 0);
  h.run_until(50000, 2'000'000); // settle + first sparkle passes
  const size_t sparkles_before = h.presenter.sparkle_count();
  EXPECT_GT(sparkles_before, 0u);
  EXPECT_LT(sparkles_before, 16u);

  // Re-damage the region: the rotation stops (only a fresh settle re-arms).
  h.damage(rect, kPlutoRefreshFull, 2'100'000); // Full: no settle armed
  const size_t after_damage = h.presenter.sparkle_count();
  h.run_until(2'150'000, 12'000'000);
  EXPECT_EQ(h.presenter.sparkle_count(), after_damage);
}

// Full-class damage repays its own debt at dispatch: no settle ever fires.
TEST(SettlePlannerTest, FullClassDamageArmsNoSettle) {
  Harness h;
  h.damage(PlutoRect{0, 0, 128, 128}, kPlutoRefreshFull, 0);
  h.run_until(50000, 5'000'000);
  EXPECT_EQ(h.scheduler->dispatched_settles(), 0u);
  EXPECT_EQ(h.presenter.calls.size(), 1u);
}

// ARC scan resistance: a region under continuous animation gets NO settle
// while it animates — one settle burst fires only after it rests.
TEST(SettlePlannerTest, NoSettleThrashUnderContinuousAnimation) {
  Harness h;
  const PlutoRect rect{0, 0, 64, 64};
  uint64_t now = 0;
  for (int frame = 0; frame < 50; ++frame) {
    h.damage(rect, kPlutoRefreshFast, now);
    now += 20000; // 20 ms cadence, well inside the 300 ms quiesce window
  }
  EXPECT_EQ(h.scheduler->dispatched_settles(), 0u)
      << "settle fired mid-animation";

  h.run_until(now, now + 2'000'000);
  EXPECT_GE(h.scheduler->dispatched_settles(), 1u);
  // And it fired exactly once: debt cleared, region at rest.
  const size_t settles = h.scheduler->dispatched_settles();
  h.run_until(now + 2'050'000, now + 6'000'000);
  EXPECT_EQ(h.scheduler->dispatched_settles(), settles);
}

// Debt-driven selection: the heavily-railed region settles before the
// lightly-touched one (debt x saliency ordering).
TEST(SettlePlannerTest, HighestDebtClusterSettlesFirst) {
  Harness h;

  const PlutoRect heavy{0, 0, 32, 32};
  const PlutoRect light{96, 96, 32, 32};
  uint64_t now = 0;
  for (int i = 0; i < 5; ++i) {
    h.damage(heavy, kPlutoRefreshFast, now);
    now += 20000;
  }
  h.damage(light, kPlutoRefreshUi, now);

  h.run_until(now + 50000, now + 2'000'000);
  ASSERT_GE(h.scheduler->dispatched_settles(), 2u);
  // Find the settle presents (Text class here) in dispatch order.
  std::vector<const RecordingPresenter::Call *> settles;
  for (const RecordingPresenter::Call &call : h.presenter.calls) {
    if (call.cls == kPlutoRefreshText) {
      settles.push_back(&call);
    }
  }
  ASSERT_GE(settles.size(), 2u);
  EXPECT_TRUE(covers(settles[0]->damage[0], PlutoRect{0, 0, 32, 32}))
      << "highest-debt cluster did not settle first";
  EXPECT_TRUE(covers(settles[1]->damage[0], light));
}

// Optical pigment stress must not be inferred as content chroma. Even deep
// achromatic debt stays Text; broad pigment exposure is handled by the
// serialized global Bleach policy instead of regional Full blackouts.
TEST(SettlePlannerTest, DeepAchromaticDebtStaysText) {
  Harness h(/*panel_is_color=*/true);

  const PlutoRect deep{0, 0, 32, 32};
  uint64_t now = 0;
  // Hammer one tile with Fast passes until average debt clears the
  // promotion line (default 288 = three full-coverage Fast passes).
  for (int i = 0; i < 8; ++i) {
    h.damage(deep, kPlutoRefreshFast, now);
    now += 20000;
  }
  h.run_until(now + 50000, now + 2'000'000);

  bool deep_text = false;
  for (const RecordingPresenter::Call &call : h.presenter.calls) {
    if (call.cls == kPlutoRefreshText && covers(call.damage[0], deep)) {
      deep_text = true;
    }
    EXPECT_NE(call.cls, kPlutoRefreshFull);
  }
  EXPECT_TRUE(deep_text) << "deep achromatic debt never settled as Text";
}

TEST(SettlePlannerTest, ShallowDebtClusterStaysTextClass) {
  Harness h(/*panel_is_color=*/true);

  const PlutoRect shallow{96, 96, 32, 32};
  h.damage(shallow, kPlutoRefreshUi, 0);
  h.run_until(50000, 2'000'000);

  bool shallow_text = false;
  for (const RecordingPresenter::Call &call : h.presenter.calls) {
    if (covers(call.damage[0], shallow)) {
      if (call.cls == kPlutoRefreshText) {
        shallow_text = true;
      }
      EXPECT_NE(call.cls, kPlutoRefreshFull) << "shallow debt must not flash";
    }
  }
  EXPECT_TRUE(shallow_text) << "shallow-debt cluster never settled as Text";
}

// Chroma-pending lifecycle on color panels: sub-Full chroma damage settles
// as a Full-class pass that clears the pending set; nothing re-settles.
TEST(SettlePlannerTest, ChromaPendingSettlesAsFullAndClears) {
  Harness h(/*panel_is_color=*/true);
  const PlutoRect rect{0, 0, 32, 32};
  h.chroma.mark(rect); // the frame path marks on sub-Full chroma damage
  h.damage(rect, kPlutoRefreshUi, 0);
  ASSERT_TRUE(h.chroma.any());

  h.run_until(50000, 2'000'000);
  ASSERT_GE(h.scheduler->dispatched_settles(), 1u);
  bool saw_full_settle = false;
  for (const RecordingPresenter::Call &call : h.presenter.calls) {
    if (call.cls == kPlutoRefreshFull && covers(call.damage[0], rect)) {
      saw_full_settle = true;
    }
  }
  EXPECT_TRUE(saw_full_settle) << "chroma-pending tile did not settle as Full";
  EXPECT_FALSE(h.chroma.any()) << "Full settle did not clear chroma-pending";

  const size_t settles = h.scheduler->dispatched_settles();
  h.run_until(2'050'000, 6'000'000);
  EXPECT_EQ(h.scheduler->dispatched_settles(), settles);
}

// On a mono pipeline the same chroma marks are inert: no Full promotion.
TEST(SettlePlannerTest, ChromaIgnoredOnMonoPanels) {
  Harness h(/*panel_is_color=*/false);
  const PlutoRect rect{0, 0, 32, 32};
  h.chroma.mark(rect);
  h.damage(rect, kPlutoRefreshUi, 0);
  h.run_until(50000, 2'000'000);
  for (const RecordingPresenter::Call &call : h.presenter.calls) {
    EXPECT_NE(call.cls, kPlutoRefreshFull);
  }
}

// Whole-field coalescing: when most of the panel owes a settle, ONE
// whole-screen settle replaces the per-cluster train. On gray glass it is
// Text class — Full's GC16 flash inverts the screen to a negative for ~1 s
// after every large transition; the quality repayment does not need it.
TEST(SettlePlannerTest, LargeBacklogSettlesAsOneFullScreenTextOnGray) {
  Harness h;
  h.damage(PlutoRect{0, 0, 128, 80}, kPlutoRefreshFast, 0); // 12/16 tiles
  h.run_until(50000, 2'000'000);
  ASSERT_EQ(h.scheduler->dispatched_settles(), 1u);
  EXPECT_EQ(h.planner.emitted_full_flashes(), 0u);
  bool saw_full_screen = false;
  for (const RecordingPresenter::Call &call : h.presenter.calls) {
    if (call.cls == kPlutoRefreshText &&
        covers(call.damage[0], PlutoRect{0, 0, 128, 128})) {
      saw_full_screen = true;
    }
    EXPECT_NE(call.cls, kPlutoRefreshFull) << "gray panel must not flash";
  }
  EXPECT_TRUE(saw_full_screen);
}

// A broad ghost-only backlog stays one Text repayment even on color glass.
// Actual ChromaPending tiles are handled exactly on a later pass.
TEST(SettlePlannerTest, LargeGhostBacklogStaysTextOnColor) {
  Harness h(/*panel_is_color=*/true);
  h.damage(PlutoRect{0, 0, 128, 80}, kPlutoRefreshFast, 0); // 12/16 tiles
  h.run_until(50000, 2'000'000);
  ASSERT_EQ(h.scheduler->dispatched_settles(), 1u);
  EXPECT_EQ(h.planner.emitted_full_flashes(), 0u);
  bool saw_full_screen = false;
  for (const RecordingPresenter::Call &call : h.presenter.calls) {
    if (call.cls == kPlutoRefreshText &&
        covers(call.damage[0], PlutoRect{0, 0, 128, 128})) {
      saw_full_screen = true;
    }
    EXPECT_NE(call.cls, kPlutoRefreshFull);
  }
  EXPECT_TRUE(saw_full_screen);
}

// LSM clustering bound: distant small regions settle as SEPARATE rects —
// never the everything-into-one-union flash of the old chroma path.
TEST(SettlePlannerTest, DistantRegionsNeverUnionFlash) {
  Harness h;

  const PlutoRect top_left{0, 0, 24, 24};
  const PlutoRect bottom_right{104, 104, 24, 24};
  h.damage(top_left, kPlutoRefreshFast, 0);
  h.damage(bottom_right, kPlutoRefreshFast, 1000);

  h.run_until(50000, 2'000'000);
  EXPECT_EQ(h.scheduler->dispatched_settles(), 2u);
  for (const RecordingPresenter::Call &call : h.presenter.calls) {
    if (call.cls != kPlutoRefreshText) {
      continue;
    }
    // No single settle rect may span both corners.
    EXPECT_FALSE(covers(call.damage[0], top_left) &&
                 covers(call.damage[0], bottom_right))
        << "union flash across distant regions";
  }
}

// Color develop sparkle is disabled: qtfb cannot carry its sparse mask and
// turned every nominal 1/256 pass into a full rectangular PARTIAL update.
TEST(SettlePlannerTest, ColorSettleNeverArmsDevelopSweep) {
  Harness h(/*panel_is_color=*/true);
  const PlutoRect rect{8, 8, 16, 16};
  h.damage(rect, kPlutoRefreshUi, 0);
  h.run_until(50000, 3'000'000);

  EXPECT_EQ(h.presenter.sparkle_count(), 0u);
  h.damage(rect, kPlutoRefreshUi, 3'100'000);
  h.run_until(3'150'000, 6'000'000);
  EXPECT_EQ(h.presenter.sparkle_count(), 0u);
}

TEST(SettlePlannerTest, ChromaFullWaitsForInputButDebtStaysLatched) {
  Harness h(/*panel_is_color=*/true);
  const PlutoRect rect{0, 0, 32, 32};
  h.chroma.mark(rect);
  h.damage(rect, kPlutoRefreshUi, 0);

  h.run_until_gated(50'000, 1'000'000,
                    /*intrusive_maintenance_allowed=*/false);
  EXPECT_TRUE(h.chroma.any());
  for (const RecordingPresenter::Call &call : h.presenter.calls) {
    EXPECT_NE(call.cls, kPlutoRefreshFull);
  }

  h.tick(1'050'000, /*maintenance_allowed=*/true,
         /*intrusive_maintenance_allowed=*/true);
  bool saw_full = false;
  for (const RecordingPresenter::Call &call : h.presenter.calls) {
    saw_full = saw_full || call.cls == kPlutoRefreshFull;
  }
  EXPECT_TRUE(saw_full);
}

TEST(SettlePlannerTest, SparkleRotationPausesAcrossInputGate) {
  Harness h;
  const PlutoRect rect{8, 8, 16, 16};
  h.damage(rect, kPlutoRefreshFast, 0);
  h.run_until(50'000, 600'000); // Text settle emits and arms sparkle
  const size_t before = h.presenter.sparkle_count();

  h.run_until_gated(650'000, 2'000'000,
                    /*intrusive_maintenance_allowed=*/false);
  EXPECT_EQ(h.presenter.sparkle_count(), before);
  h.tick(2'050'000, /*maintenance_allowed=*/true,
         /*intrusive_maintenance_allowed=*/true);
  EXPECT_GT(h.presenter.sparkle_count(), before);
}

TEST(SettlePlannerTest, PersistentPolicyStateRoundTripsAndFailsClosed) {
  TileGrid grid;
  ASSERT_TRUE(grid.configure(128, 128, 32));
  GhostLedger ghost;
  StressLedger stress;
  ChromaPendingSet chroma;
  ASSERT_TRUE(ghost.configure(grid, 1000, 224));
  ASSERT_TRUE(stress.configure(grid));
  ASSERT_TRUE(chroma.configure(grid));

  SettlePlannerConfig config;
  config.width = 128;
  config.height = 128;
  config.tile_px = 32;
  config.align_px = 8;
  SettlePlanner source;
  ASSERT_TRUE(source.configure(config, &ghost, &stress, &chroma));
  source.note_damage(PlutoRect{0, 0, 32, 64}, 123'000);
  source.arm_scroll_settle(PlutoRect{32, 32, 64, 32}, 200'000);

  SettlePlannerState state;
  ASSERT_TRUE(source.export_state(&state));
  state.emitted_settles = 9;
  state.emitted_full_flashes = 2;
  state.emitted_sparkles = 7;
  state.sparkle_rect = PlutoRect{8, 8, 64, 64};
  state.sparkle_phase = 5;
  state.sparkle_next_us = 900'000;

  SettlePlanner destination;
  ASSERT_TRUE(destination.configure(config, &ghost, &stress, &chroma));
  ASSERT_TRUE(destination.import_state(state));
  SettlePlannerState actual;
  ASSERT_TRUE(destination.export_state(&actual));
  EXPECT_TRUE(actual.last_damage_us == state.last_damage_us);
  ASSERT_EQ(actual.forced.size(), 1u);
  EXPECT_EQ(actual.forced[0].rect.x, 32);
  EXPECT_EQ(actual.forced[0].ready_us, state.forced[0].ready_us);
  EXPECT_EQ(actual.emitted_settles, 9u);
  EXPECT_EQ(actual.emitted_full_flashes, 2u);
  EXPECT_EQ(actual.emitted_sparkles, 7u);
  EXPECT_EQ(actual.sparkle_phase, 5u);
  EXPECT_EQ(actual.sparkle_next_us, 900'000u);

  SettlePlannerState corrupt = state;
  corrupt.last_damage_us.pop_back();
  EXPECT_FALSE(destination.import_state(corrupt));
  corrupt = state;
  corrupt.forced[0].rect.x = -1;
  EXPECT_FALSE(destination.import_state(corrupt));
  corrupt = state;
  corrupt.config.align_px = 16;
  EXPECT_FALSE(destination.import_state(corrupt));
  ASSERT_TRUE(destination.export_state(&actual));
  EXPECT_TRUE(actual.last_damage_us == state.last_damage_us);
  EXPECT_EQ(actual.sparkle_phase, 5u);
}
