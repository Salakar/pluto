#include "renderer/auto_ghostbuster.h"

#include <gtest/gtest.h>

#include <cstdint>

namespace {

using pluto::AutoGhostbuster;
using pluto::AutoGhostbusterConfig;
using pluto::AutoGhostbusterDecision;
using pluto::AutoGhostbusterGateState;
using pluto::AutoGhostbusterState;
using pluto::TileGrid;

TileGrid make_grid(int32_t width, int32_t height, uint32_t tile_px) {
  TileGrid grid;
  const bool configured = grid.configure(width, height, tile_px);
  EXPECT_TRUE(configured);
  return grid;
}

AutoGhostbusterConfig immediate_config() {
  AutoGhostbusterConfig config;
  config.damage_quiescence_us = 0;
  config.input_release_grace_us = 0;
  config.scan_cadence_us = 1;
  return config;
}

AutoGhostbusterGateState idle_gate() {
  return AutoGhostbusterGateState{/*scheduler_idle=*/true,
                                  /*presentation_suspended=*/false,
                                  /*maintenance_allowed=*/true};
}

int decision_code(AutoGhostbusterDecision decision) {
  return static_cast<int>(decision);
}

void expect_decision(AutoGhostbusterDecision actual,
                     AutoGhostbusterDecision expected) {
  EXPECT_EQ(decision_code(actual), decision_code(expected));
}

void repeat_present(AutoGhostbuster *policy, const PlutoRect &rect,
                    PlutoRefreshClass refresh_class, int count,
                    uint64_t first_us = 0) {
  for (int i = 0; i < count; ++i) {
    policy->note_accepted_present(rect, refresh_class,
                                  first_us + static_cast<uint64_t>(i));
  }
}

} // namespace

TEST(AutoGhostbusterTest, DefaultsAndAccrualWeightsArePinned) {
  const AutoGhostbusterConfig config;
  EXPECT_EQ(AutoGhostbuster::kFastAccrualQ8, 768u);
  EXPECT_EQ(AutoGhostbuster::kUiAccrualQ8, 512u);
  EXPECT_EQ(config.ghost_tile_threshold_q8, 6144u);
  EXPECT_EQ(config.yellow_tile_threshold_q8, 12288u);
  EXPECT_EQ(static_cast<int>(config.ghost_display_percent), 55);
  EXPECT_EQ(static_cast<int>(config.yellow_display_percent), 35);
  EXPECT_EQ(static_cast<int>(config.ghost_low_water_percent), 35);
  EXPECT_EQ(static_cast<int>(config.yellow_low_water_percent), 20);
  EXPECT_EQ(config.damage_quiescence_us, 300'000u);
  EXPECT_EQ(config.input_release_grace_us, 500'000u);
  EXPECT_EQ(config.cooldown_us, 600'000'000u);
  EXPECT_EQ(config.scan_cadence_us, 100'000u);
  EXPECT_EQ(config.failure_retry_initial_us, 5'000'000u);
  EXPECT_EQ(config.failure_retry_max_us, 120'000'000u);
  EXPECT_FALSE(config.pigment_hygiene_supported);
  EXPECT_EQ(AutoGhostbuster::rail_cycles_for(AutoGhostbusterDecision::kNone),
            0u);
  EXPECT_EQ(AutoGhostbuster::rail_cycles_for(AutoGhostbusterDecision::kBlink),
            1u);
  EXPECT_EQ(AutoGhostbuster::rail_cycles_for(AutoGhostbusterDecision::kBleach),
            2u);
  EXPECT_EQ(AutoGhostbuster::rail_cycles_for(AutoGhostbusterDecision::kBoth),
            3u);
  EXPECT_TRUE(AutoGhostbusterGateState{}.maintenance_allowed);
}

TEST(AutoGhostbusterTest, TileThresholdsCompareBelowExactAndAbove) {
  const TileGrid grid = make_grid(10, 10, 10);
  const PlutoRect full{0, 0, 10, 10};
  AutoGhostbusterConfig config = immediate_config();
  config.pigment_hygiene_supported = true;

  AutoGhostbuster ui_weight;
  ASSERT_TRUE(ui_weight.configure(grid, config));
  ui_weight.note_accepted_present(full, kPlutoRefreshUi, 0);
  EXPECT_EQ(ui_weight.ghost_debt(0, 0), 512u);
  repeat_present(&ui_weight, full, kPlutoRefreshUi, 11, 1);
  EXPECT_EQ(ui_weight.ghost_debt(0, 0), 6144u);
  EXPECT_TRUE(ui_weight.ghost_needed());

  AutoGhostbuster below;
  ASSERT_TRUE(below.configure(grid, config));
  repeat_present(&below, full, kPlutoRefreshFast, 7);
  EXPECT_EQ(below.ghost_debt(0, 0), 5376u);
  EXPECT_FALSE(below.ghost_needed());

  AutoGhostbuster exact;
  ASSERT_TRUE(exact.configure(grid, config));
  repeat_present(&exact, full, kPlutoRefreshFast, 8);
  EXPECT_EQ(exact.ghost_debt(0, 0), 6144u);
  EXPECT_TRUE(exact.ghost_needed());

  AutoGhostbuster above;
  ASSERT_TRUE(above.configure(grid, config));
  repeat_present(&above, full, kPlutoRefreshFast, 9);
  EXPECT_EQ(above.ghost_debt(0, 0), 6912u);
  EXPECT_TRUE(above.ghost_needed());

  // Yellow/pigment uses the same accepted-present signal but its own higher
  // threshold. Eight Fast passes are below; sixteen are exactly 12288 Q8.
  EXPECT_FALSE(exact.yellow_needed());
  repeat_present(&exact, full, kPlutoRefreshFast, 8, 8);
  EXPECT_EQ(exact.yellow_debt(0, 0), 12288u);
  EXPECT_TRUE(exact.yellow_needed());
}

TEST(AutoGhostbusterTest, DisplayCoverageComparesBelowExactAndAbove) {
  const TileGrid grid = make_grid(100, 1, 1); // one pixel per tile
  AutoGhostbusterConfig config = immediate_config();
  config.pigment_hygiene_supported = true;
  const auto build_ghost = [&](int covered_pixels) {
    AutoGhostbuster policy;
    EXPECT_TRUE(policy.configure(grid, config));
    repeat_present(&policy, PlutoRect{0, 0, covered_pixels, 1},
                   kPlutoRefreshFast, 8);
    return policy;
  };
  AutoGhostbuster ghost_below = build_ghost(54);
  AutoGhostbuster ghost_exact = build_ghost(55);
  AutoGhostbuster ghost_above = build_ghost(56);
  EXPECT_FALSE(ghost_below.ghost_needed());
  EXPECT_TRUE(ghost_exact.ghost_needed());
  EXPECT_TRUE(ghost_above.ghost_needed());
  EXPECT_EQ(ghost_exact.ghost_qualified_pixels(), 55u);

  const auto build_yellow = [&](int covered_pixels) {
    AutoGhostbuster policy;
    EXPECT_TRUE(policy.configure(grid, config));
    repeat_present(&policy, PlutoRect{0, 0, covered_pixels, 1},
                   kPlutoRefreshFast, 16);
    return policy;
  };
  AutoGhostbuster yellow_below = build_yellow(34);
  AutoGhostbuster yellow_exact = build_yellow(35);
  AutoGhostbuster yellow_above = build_yellow(36);
  EXPECT_FALSE(yellow_below.yellow_needed());
  EXPECT_TRUE(yellow_exact.yellow_needed());
  EXPECT_TRUE(yellow_above.yellow_needed());
  EXPECT_EQ(yellow_exact.yellow_qualified_pixels(), 35u);
}

TEST(AutoGhostbusterTest, SelectsBlinkBleachAndBothAndRepaysCorrectly) {
  const TileGrid grid = make_grid(100, 1, 1);
  AutoGhostbusterConfig config = immediate_config();
  config.pigment_hygiene_supported = true;

  // Eight Fast passes over 60% reach ghost but not yellow: Blink. Its success
  // must leave the still-subthreshold yellow ledger intact.
  AutoGhostbuster blink;
  ASSERT_TRUE(blink.configure(grid, config));
  repeat_present(&blink, PlutoRect{0, 0, 60, 1}, kPlutoRefreshFast, 8);
  expect_decision(blink.try_begin_action(8, idle_gate()),
                  AutoGhostbusterDecision::kBlink);
  ASSERT_TRUE(blink.complete_action(true, 9));
  EXPECT_FALSE(blink.ghost_needed());
  EXPECT_EQ(blink.ghost_debt(0, 0), 0u);
  EXPECT_EQ(blink.yellow_debt(0, 0), 6144u);

  // Sixteen passes over 40% reach the 35% yellow requirement but not the 55%
  // ghost coverage requirement: Bleach. Bleach repays both physical debts.
  AutoGhostbuster bleach;
  ASSERT_TRUE(bleach.configure(grid, config));
  repeat_present(&bleach, PlutoRect{0, 0, 40, 1}, kPlutoRefreshFast, 16);
  EXPECT_FALSE(bleach.ghost_needed());
  EXPECT_TRUE(bleach.yellow_needed());
  expect_decision(bleach.try_begin_action(16, idle_gate()),
                  AutoGhostbusterDecision::kBleach);
  ASSERT_TRUE(bleach.complete_action(true, 17));
  EXPECT_FALSE(bleach.ghost_needed());
  EXPECT_FALSE(bleach.yellow_needed());
  EXPECT_EQ(bleach.ghost_debt(0, 0), 0u);
  EXPECT_EQ(bleach.yellow_debt(0, 0), 0u);

  AutoGhostbuster both;
  ASSERT_TRUE(both.configure(grid, config));
  repeat_present(&both, PlutoRect{0, 0, 60, 1}, kPlutoRefreshFast, 16);
  expect_decision(both.try_begin_action(16, idle_gate()),
                  AutoGhostbusterDecision::kBoth);
  ASSERT_TRUE(both.complete_action(true, 17));
  EXPECT_FALSE(both.ghost_needed());
  EXPECT_FALSE(both.yellow_needed());
}

TEST(AutoGhostbusterTest, PigmentHygieneCanBeDisabledWithoutColorSignals) {
  AutoGhostbusterConfig config = immediate_config();
  config.pigment_hygiene_supported = false;
  AutoGhostbuster policy;
  ASSERT_TRUE(policy.configure(make_grid(10, 10, 10), config));
  repeat_present(&policy, PlutoRect{0, 0, 10, 10}, kPlutoRefreshFast, 16);
  EXPECT_EQ(policy.yellow_debt(0, 0), 0u);
  EXPECT_FALSE(policy.yellow_needed());
  expect_decision(policy.try_begin_action(16, idle_gate()),
                  AutoGhostbusterDecision::kBlink);
}

TEST(AutoGhostbusterTest, ActiveTouchAndPenAndReleaseGraceGateARealDebt) {
  AutoGhostbusterConfig config;
  config.scan_cadence_us = 1;
  AutoGhostbuster policy;
  ASSERT_TRUE(policy.configure(make_grid(10, 10, 10), config));
  repeat_present(&policy, PlutoRect{0, 0, 10, 10}, kPlutoRefreshFast, 8);
  ASSERT_TRUE(policy.ghost_needed());

  policy.note_input_state(/*touch_active=*/true, /*pen_active=*/true, 100'000);
  expect_decision(policy.try_begin_action(300'000, idle_gate()),
                  AutoGhostbusterDecision::kNone);
  // Releasing touch alone is not a combined input release while pen remains.
  policy.note_input_state(/*touch_active=*/false, /*pen_active=*/true, 400'000);
  expect_decision(policy.try_begin_action(500'000, idle_gate()),
                  AutoGhostbusterDecision::kNone);
  policy.note_input_state(/*touch_active=*/false, /*pen_active=*/false,
                          500'000);
  expect_decision(policy.try_begin_action(999'999, idle_gate()),
                  AutoGhostbusterDecision::kNone);
  expect_decision(policy.try_begin_action(1'000'000, idle_gate()),
                  AutoGhostbusterDecision::kBlink);
}

TEST(AutoGhostbusterTest, BusySuspendedAndScanCadenceGateStart) {
  AutoGhostbuster policy;
  ASSERT_TRUE(policy.configure(make_grid(10, 10, 10)));
  repeat_present(&policy, PlutoRect{0, 0, 10, 10}, kPlutoRefreshFast, 8);

  expect_decision(
      policy.try_begin_action(
          300'000, AutoGhostbusterGateState{/*scheduler_idle=*/false,
                                            /*presentation_suspended=*/false}),
      AutoGhostbusterDecision::kNone);
  // This is inside the default 100 ms scan interval, even though the
  // scheduler state has become suitable.
  expect_decision(policy.try_begin_action(350'000, idle_gate()),
                  AutoGhostbusterDecision::kNone);
  expect_decision(
      policy.try_begin_action(
          400'000, AutoGhostbusterGateState{/*scheduler_idle=*/true,
                                            /*presentation_suspended=*/true,
                                            /*maintenance_allowed=*/true}),
      AutoGhostbusterDecision::kNone);
  expect_decision(
      policy.try_begin_action(
          500'000, AutoGhostbusterGateState{/*scheduler_idle=*/true,
                                            /*presentation_suspended=*/false,
                                            /*maintenance_allowed=*/false}),
      AutoGhostbusterDecision::kNone);
  expect_decision(policy.try_begin_action(600'000, idle_gate()),
                  AutoGhostbusterDecision::kBlink);
}

TEST(AutoGhostbusterTest, InputReleaseAloneNeverCreatesAnAction) {
  AutoGhostbuster policy;
  ASSERT_TRUE(policy.configure(make_grid(10, 10, 10)));
  policy.note_input_state(true, false, 10);
  policy.note_input_state(false, false, 20);
  expect_decision(policy.try_begin_action(600'000, idle_gate()),
                  AutoGhostbusterDecision::kNone);
  EXPECT_FALSE(policy.ghost_needed());
  EXPECT_FALSE(policy.yellow_needed());
}

TEST(AutoGhostbusterTest, RawTimestampPreservesGraceForUnsampledShortTap) {
  AutoGhostbusterConfig config = immediate_config();
  config.input_release_grace_us = 500;
  AutoGhostbuster policy;
  ASSERT_TRUE(policy.configure(make_grid(10, 10, 10), config));
  repeat_present(&policy, PlutoRect{0, 0, 10, 10}, kPlutoRefreshFast, 8);
  ASSERT_TRUE(policy.ghost_needed());

  // The renderer saw down+up between policy polls, so current state is idle;
  // only the newer raw edge timestamp reveals the interaction.
  policy.note_input_state(false, false, 1'000);
  expect_decision(policy.try_begin_action(1'499, idle_gate()),
                  AutoGhostbusterDecision::kNone);
  expect_decision(policy.try_begin_action(1'500, idle_gate()),
                  AutoGhostbusterDecision::kBlink);
}

TEST(AutoGhostbusterTest, SuccessfulActionArmsCooldownFromCompletion) {
  AutoGhostbusterConfig config = immediate_config();
  config.pigment_hygiene_supported = false;
  AutoGhostbuster policy;
  ASSERT_TRUE(policy.configure(make_grid(100, 1, 1), config));
  const PlutoRect damage{0, 0, 60, 1};
  repeat_present(&policy, damage, kPlutoRefreshFast, 8);
  expect_decision(policy.try_begin_action(8, idle_gate()),
                  AutoGhostbusterDecision::kBlink);
  ASSERT_TRUE(policy.complete_action(true, 100));
  EXPECT_EQ(policy.cooldown_until_us(), 600'000'100u);

  repeat_present(&policy, damage, kPlutoRefreshFast, 8, 200);
  ASSERT_TRUE(policy.ghost_needed());
  expect_decision(policy.try_begin_action(600'000'099, idle_gate()),
                  AutoGhostbusterDecision::kNone);
  expect_decision(policy.try_begin_action(600'000'100, idle_gate()),
                  AutoGhostbusterDecision::kBlink);
}

TEST(AutoGhostbusterTest, EdgeTilesUseTheirActualPixelArea) {
  AutoGhostbusterConfig config = immediate_config();
  config.ghost_display_percent = 3;
  config.ghost_low_water_percent = 1;
  AutoGhostbuster policy;
  // The right edge tile is 1x32 = 32 px, not a nominal 32x32 tile. Thirty-two
  // is exactly ceil(1056 * 3%), and a complete pass over it still adds the
  // complete per-tile weight.
  ASSERT_TRUE(policy.configure(make_grid(33, 32, 32), config));
  const PlutoRect edge{32, 0, 1, 32};
  repeat_present(&policy, edge, kPlutoRefreshFast, 8);
  EXPECT_EQ(policy.display_pixels(), 1056u);
  EXPECT_EQ(policy.ghost_debt(1, 0), 6144u);
  EXPECT_EQ(policy.ghost_qualified_pixels(), 32u);
  EXPECT_TRUE(policy.ghost_needed());
}

TEST(AutoGhostbusterTest, OrdinaryQualityNeverForgivesPigmentDebt) {
  AutoGhostbusterConfig config = immediate_config();
  config.ghost_tile_threshold_q8 = 768;
  config.yellow_tile_threshold_q8 = 768;
  config.ghost_display_percent = 100;
  config.yellow_display_percent = 100;
  config.pigment_hygiene_supported = true;
  AutoGhostbuster policy;
  ASSERT_TRUE(policy.configure(make_grid(10, 10, 10), config));
  const PlutoRect full{0, 0, 10, 10};

  policy.note_accepted_present(full, kPlutoRefreshFast, 0);
  ASSERT_TRUE(policy.ghost_needed());
  ASSERT_TRUE(policy.yellow_needed());
  policy.note_accepted_present(full, kPlutoRefreshText, 1);
  EXPECT_EQ(policy.ghost_debt(0, 0), 0u);
  EXPECT_EQ(policy.yellow_debt(0, 0), 768u);
  // Text repays ghost only. With this one-tile surface it also crosses the
  // 35% low-water boundary and cancels the not-yet-started ghost reason.
  EXPECT_FALSE(policy.ghost_needed());
  EXPECT_TRUE(policy.yellow_needed());

  policy.note_accepted_present(full, kPlutoRefreshFull, 2);
  EXPECT_EQ(policy.ghost_debt(0, 0), 0u);
  EXPECT_EQ(policy.yellow_debt(0, 0), 768u);
  EXPECT_FALSE(policy.ghost_needed());
  EXPECT_TRUE(policy.yellow_needed());
}

TEST(AutoGhostbusterTest, TinyQualityEdgeCannotForgiveWholeTile) {
  AutoGhostbusterConfig config = immediate_config();
  config.ghost_tile_threshold_q8 = 768;
  config.ghost_display_percent = 100;
  config.ghost_low_water_percent = 0;
  AutoGhostbuster policy;
  ASSERT_TRUE(policy.configure(make_grid(10, 10, 10), config));

  policy.note_accepted_present(PlutoRect{0, 0, 10, 10}, kPlutoRefreshFast, 0);
  ASSERT_TRUE(policy.ghost_needed());
  policy.note_accepted_present(PlutoRect{0, 0, 1, 10}, kPlutoRefreshText, 1);
  EXPECT_GT(policy.ghost_debt(0, 0), 768u / 2u);
  EXPECT_EQ(policy.ghost_qualified_pixels(), 100u);
  EXPECT_TRUE(policy.ghost_needed());

  policy.note_accepted_present(PlutoRect{1, 0, 9, 10}, kPlutoRefreshText, 2);
  EXPECT_LE(policy.ghost_debt(0, 0), 768u / 2u);
  EXPECT_EQ(policy.ghost_qualified_pixels(), 0u);
  EXPECT_FALSE(policy.ghost_needed());
}

TEST(AutoGhostbusterTest, QualityRepaymentCancelsOnlyAtLowWater) {
  const TileGrid grid = make_grid(100, 1, 1);
  AutoGhostbusterConfig config = immediate_config();

  AutoGhostbuster ghost;
  ASSERT_TRUE(ghost.configure(grid, config));
  repeat_present(&ghost, PlutoRect{0, 0, 60, 1}, kPlutoRefreshFast, 8);
  ASSERT_TRUE(ghost.ghost_needed());
  ghost.note_accepted_present(PlutoRect{0, 0, 24, 1}, kPlutoRefreshText, 20);
  EXPECT_EQ(ghost.ghost_qualified_pixels(), 36u);
  EXPECT_TRUE(ghost.ghost_needed()); // still above 35% low-water

  // Input transitions alone neither forgive debt nor unlatch the reason.
  ghost.note_input_state(true, false, 21);
  ghost.note_input_state(false, false, 22);
  EXPECT_TRUE(ghost.ghost_needed());
  ghost.note_accepted_present(PlutoRect{24, 0, 1, 1}, kPlutoRefreshText, 23);
  EXPECT_EQ(ghost.ghost_qualified_pixels(), 35u);
  EXPECT_FALSE(ghost.ghost_needed()); // exact low-water is inclusive
}

TEST(AutoGhostbusterTest, ManualAcknowledgementRepaysWithoutAutoCooldown) {
  AutoGhostbusterConfig config = immediate_config();
  config.pigment_hygiene_supported = true;
  AutoGhostbuster policy;
  ASSERT_TRUE(policy.configure(make_grid(100, 1, 1), config));
  repeat_present(&policy, PlutoRect{0, 0, 60, 1}, kPlutoRefreshFast, 16);
  ASSERT_TRUE(policy.ghost_needed());
  ASSERT_TRUE(policy.yellow_needed());

  expect_decision(policy.try_begin_action(16, idle_gate()),
                  AutoGhostbusterDecision::kBoth);
  EXPECT_FALSE(
      policy.acknowledge_external_action(AutoGhostbusterDecision::kBoth, 17));
  ASSERT_TRUE(policy.complete_action(false, 18));
  EXPECT_EQ(policy.consecutive_failures(), 1u);

  ASSERT_TRUE(
      policy.acknowledge_external_action(AutoGhostbusterDecision::kBlink, 19));
  EXPECT_FALSE(policy.ghost_needed());
  EXPECT_EQ(policy.ghost_debt(0, 0), 0u);
  EXPECT_TRUE(policy.yellow_needed());
  EXPECT_EQ(policy.yellow_debt(0, 0), 12288u);
  EXPECT_EQ(policy.cooldown_until_us(), 0u);
  EXPECT_EQ(policy.consecutive_failures(), 0u);
  EXPECT_EQ(policy.retry_not_before_us(), 0u);

  ASSERT_TRUE(
      policy.acknowledge_external_action(AutoGhostbusterDecision::kBleach, 20));
  EXPECT_FALSE(policy.yellow_needed());
  EXPECT_EQ(policy.yellow_debt(0, 0), 0u);
  EXPECT_EQ(policy.cooldown_until_us(), 0u);
}

TEST(AutoGhostbusterTest, FreshReasonDuringActiveRunSurvivesCompletion) {
  AutoGhostbusterConfig config = immediate_config();
  config.cooldown_us = 0;
  config.pigment_hygiene_supported = false;
  AutoGhostbuster policy;
  ASSERT_TRUE(policy.configure(make_grid(100, 1, 1), config));
  const PlutoRect damage{0, 0, 60, 1};

  repeat_present(&policy, damage, kPlutoRefreshFast, 8);
  expect_decision(policy.try_begin_action(8, idle_gate()),
                  AutoGhostbusterDecision::kBlink);
  ASSERT_TRUE(policy.action_active());

  // This second complete threshold is accepted after begin. Completion must
  // acknowledge the old reason while adopting this fresh active-run ledger.
  repeat_present(&policy, damage, kPlutoRefreshFast, 8, 9);
  ASSERT_TRUE(policy.complete_action(true, 17));
  EXPECT_TRUE(policy.ghost_needed());
  EXPECT_EQ(policy.ghost_debt(0, 0), 6144u);
  expect_decision(policy.try_begin_action(18, idle_gate()),
                  AutoGhostbusterDecision::kBlink);
}

TEST(AutoGhostbusterTest, FailedActionAcknowledgesNothingAndDebtDoesNotDecay) {
  AutoGhostbusterConfig config = immediate_config();
  AutoGhostbuster policy;
  ASSERT_TRUE(policy.configure(make_grid(10, 10, 10), config));
  const PlutoRect full{0, 0, 10, 10};
  repeat_present(&policy, full, kPlutoRefreshFast, 8);
  expect_decision(policy.try_begin_action(8, idle_gate()),
                  AutoGhostbusterDecision::kBlink);
  ASSERT_TRUE(policy.complete_action(false, 10));
  EXPECT_TRUE(policy.ghost_needed());
  EXPECT_EQ(policy.ghost_debt(0, 0), 6144u);
  EXPECT_EQ(policy.cooldown_until_us(), 0u);
  EXPECT_EQ(policy.consecutive_failures(), 1u);
  EXPECT_EQ(policy.retry_not_before_us(), 5'000'010u);

  expect_decision(policy.try_begin_action(5'000'009, idle_gate()),
                  AutoGhostbusterDecision::kNone);
  expect_decision(policy.try_begin_action(5'000'010, idle_gate()),
                  AutoGhostbusterDecision::kBlink);
  ASSERT_TRUE(policy.complete_action(false, 5'000'020));
  EXPECT_EQ(policy.consecutive_failures(), 2u);
  EXPECT_EQ(policy.retry_not_before_us(), 15'000'020u);

  // Polling hours later changes neither non-decaying ledger.
  expect_decision(policy.try_begin_action(3'600'000'000, idle_gate()),
                  AutoGhostbusterDecision::kBlink);
  EXPECT_EQ(policy.ghost_debt(0, 0), 6144u);
  ASSERT_TRUE(policy.complete_action(true, 3'600'000'001));
  EXPECT_EQ(policy.consecutive_failures(), 0u);
  EXPECT_EQ(policy.retry_not_before_us(), 0u);
}

TEST(AutoGhostbusterTest, FailureRetryBackoffIsExponentialAndCapped) {
  AutoGhostbuster policy;
  ASSERT_TRUE(policy.configure(make_grid(10, 10, 10), immediate_config()));
  repeat_present(&policy, PlutoRect{0, 0, 10, 10}, kPlutoRefreshFast, 8);
  expect_decision(policy.try_begin_action(8, idle_gate()),
                  AutoGhostbusterDecision::kBlink);

  const uint64_t expected_delays[] = {5'000'000,  10'000'000, 20'000'000,
                                      40'000'000, 80'000'000, 120'000'000,
                                      120'000'000};
  uint64_t failure_us = 100;
  for (size_t i = 0; i < sizeof(expected_delays) / sizeof(expected_delays[0]);
       ++i) {
    ASSERT_TRUE(policy.complete_action(false, failure_us));
    const uint64_t retry_us = failure_us + expected_delays[i];
    EXPECT_EQ(policy.retry_not_before_us(), retry_us);
    EXPECT_EQ(policy.consecutive_failures(), static_cast<uint32_t>(i + 1));
    if (i + 1 < sizeof(expected_delays) / sizeof(expected_delays[0])) {
      expect_decision(policy.try_begin_action(retry_us, idle_gate()),
                      AutoGhostbusterDecision::kBlink);
      failure_us = retry_us + 1;
    }
  }
}

TEST(AutoGhostbusterTest,
     PersistentDebtAndGateStateRoundTripsOnlyBetweenInactivePolicies) {
  const TileGrid grid = make_grid(20, 10, 10);
  AutoGhostbusterConfig config = immediate_config();
  config.pigment_hygiene_supported = true;
  AutoGhostbuster source;
  ASSERT_TRUE(source.configure(grid, config));
  repeat_present(&source, PlutoRect{0, 0, 20, 10}, kPlutoRefreshFast, 16, 100);
  source.note_input_state(true, false, 1'000);
  source.note_input_state(false, false, 1'100);
  expect_decision(source.try_begin_action(2'000, idle_gate()),
                  AutoGhostbusterDecision::kBoth);

  AutoGhostbusterState unavailable;
  EXPECT_FALSE(source.export_state(&unavailable));
  ASSERT_TRUE(source.complete_action(false, 2'100));

  AutoGhostbusterState expected;
  ASSERT_TRUE(source.export_state(&expected));
  AutoGhostbuster destination;
  ASSERT_TRUE(destination.configure(grid, config));
  ASSERT_TRUE(destination.import_state(expected));
  AutoGhostbusterState actual;
  ASSERT_TRUE(destination.export_state(&actual));
  EXPECT_TRUE(actual.ghost.debt == expected.ghost.debt);
  EXPECT_TRUE(actual.yellow.debt == expected.yellow.debt);
  EXPECT_TRUE(actual.ghost.qualified == expected.ghost.qualified);
  EXPECT_EQ(actual.ghost.qualified_pixels, expected.ghost.qualified_pixels);
  EXPECT_EQ(actual.last_input_release_us, 1'100u);
  EXPECT_EQ(actual.last_input_event_us, 1'100u);
  EXPECT_EQ(actual.last_damage_us, expected.last_damage_us);
  EXPECT_EQ(actual.next_scan_us, expected.next_scan_us);
  EXPECT_EQ(actual.retry_not_before_us, expected.retry_not_before_us);
  EXPECT_EQ(actual.consecutive_failures, 1u);

  AutoGhostbusterState corrupt = expected;
  corrupt.ghost.qualified[0] = 2;
  EXPECT_FALSE(destination.import_state(corrupt));
  corrupt = expected;
  corrupt.yellow.remainder.pop_back();
  EXPECT_FALSE(destination.import_state(corrupt));
  corrupt = expected;
  ++corrupt.config.ghost_tile_threshold_q8;
  EXPECT_FALSE(destination.import_state(corrupt));
  ASSERT_TRUE(destination.export_state(&actual));
  EXPECT_TRUE(actual.ghost.debt == expected.ghost.debt)
      << "failed import mutated persistent debt";

  AutoGhostbuster active_destination;
  ASSERT_TRUE(active_destination.configure(grid, config));
  repeat_present(&active_destination, PlutoRect{0, 0, 20, 10},
                 kPlutoRefreshFast, 16);
  expect_decision(active_destination.try_begin_action(100, idle_gate()),
                  AutoGhostbusterDecision::kBoth);
  EXPECT_FALSE(active_destination.import_state(expected));

  // Successful adoption swaps active-run storage. Its now-inactive scratch
  // metadata must stay correlated with those swapped vectors so a subsequent
  // handoff is still self-consistent.
  ASSERT_TRUE(
      source.try_begin_action(expected.retry_not_before_us, idle_gate()) !=
      AutoGhostbusterDecision::kNone);
  ASSERT_TRUE(source.complete_action(true, expected.retry_not_before_us + 1));
  AutoGhostbusterState after_success;
  ASSERT_TRUE(source.export_state(&after_success));
  AutoGhostbuster after_success_destination;
  ASSERT_TRUE(after_success_destination.configure(grid, config));
  EXPECT_TRUE(after_success_destination.import_state(after_success));
}
