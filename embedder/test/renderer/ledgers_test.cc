// Ledger units: ghost decay half-life math, accrual weights and coverage
// scaling, quality-class clears, stub stress, and the chroma-pending
// lifecycle.

#include <gtest/gtest.h>

#include <cstdint>

#include "renderer/ledgers.h"

namespace {

using pluto::ChromaPendingSet;
using pluto::ChromaPendingState;
using pluto::GhostLedger;
using pluto::GhostLedgerState;
using pluto::StressLedger;
using pluto::StressLedgerState;
using pluto::TileGrid;

TileGrid grid_128() {
  TileGrid grid;
  grid.configure(128, 128, 32);
  return grid;
}

} // namespace

TEST(TileGridTest, GeometryAndIteration) {
  TileGrid grid = grid_128();
  EXPECT_EQ(grid.cols, 4u);
  EXPECT_EQ(grid.rows, 4u);
  EXPECT_EQ(grid.tile_count(), 16u);

  int visited = 0;
  grid.for_each_tile(PlutoRect{30, 30, 4, 4}, [&](uint32_t tx, uint32_t ty) {
    ++visited;
    EXPECT_LE(tx, 1u);
    EXPECT_LE(ty, 1u);
  });
  EXPECT_EQ(visited, 4); // straddles the 32 px corner: 4 tiles

  // Out-of-surface damage clips instead of walking out of the grid.
  visited = 0;
  grid.for_each_tile(PlutoRect{120, 120, 64, 64},
                     [&](uint32_t, uint32_t) { ++visited; });
  EXPECT_EQ(visited, 1);
}

TEST(GhostLedgerTest, HalfLifeDecayMath) {
  // tau = 1000 ms => half-life = tau * ln2 = 693 ms. One half-life decays
  // to 1/2, two to 1/4 (within table quantization).
  const uint64_t half_life_us = 693147;
  const uint32_t one = GhostLedger::decay_factor_q15(half_life_us, 1000);
  EXPECT_NEAR(static_cast<double>(one) / 32768.0, 0.5, 0.01);
  const uint32_t two = GhostLedger::decay_factor_q15(2 * half_life_us, 1000);
  EXPECT_NEAR(static_cast<double>(two) / 32768.0, 0.25, 0.01);

  GhostLedger ledger;
  ASSERT_TRUE(ledger.configure(grid_128(), 1000, 224));
  ledger.tick(0); // starts the decay clock
  ledger.accrue(PlutoRect{0, 0, 32, 32}, kPlutoRefreshFast);
  const uint16_t initial = ledger.debt(0, 0);
  EXPECT_EQ(initial, GhostLedger::kWeightFastQ8);

  ledger.tick(half_life_us);
  const double after_one = ledger.debt(0, 0);
  EXPECT_NEAR(after_one / initial, 0.5, 0.02);

  // Decay accumulates across many small ticks exactly like one big tick
  // (the remainder-carry property).
  GhostLedger stepped;
  ASSERT_TRUE(stepped.configure(grid_128(), 1000, 224));
  stepped.tick(0);
  stepped.accrue(PlutoRect{0, 0, 32, 32}, kPlutoRefreshFast);
  for (uint64_t t = 1000; t <= half_life_us; t += 1000) {
    stepped.tick(t);
  }
  EXPECT_NEAR(static_cast<double>(stepped.debt(0, 0)) / initial, 0.5, 0.03);
}

TEST(GhostLedgerTest, AccrualWeightsCoverageAndClear) {
  GhostLedger ledger;
  ASSERT_TRUE(ledger.configure(grid_128(), 1000, 224));
  ledger.tick(0);

  // Full-tile fast pass: weight 3 in Q8. Full-tile ui pass: weight 2.
  ledger.accrue(PlutoRect{0, 0, 32, 32}, kPlutoRefreshFast);
  ledger.accrue(PlutoRect{32, 0, 32, 32}, kPlutoRefreshUi);
  EXPECT_EQ(ledger.debt(0, 0), GhostLedger::kWeightFastQ8);
  EXPECT_EQ(ledger.debt(1, 0), GhostLedger::kWeightUiQ8);

  // Quarter coverage accrues a quarter of the weight.
  ledger.accrue(PlutoRect{64, 0, 16, 16}, kPlutoRefreshFast);
  EXPECT_EQ(ledger.debt(2, 0), GhostLedger::kWeightFastQ8 / 4);

  // Quality classes never accrue.
  ledger.accrue(PlutoRect{96, 0, 32, 32}, kPlutoRefreshText);
  ledger.accrue(PlutoRect{96, 32, 32, 32}, kPlutoRefreshFull);
  EXPECT_EQ(ledger.debt(3, 0), 0u);
  EXPECT_EQ(ledger.debt(3, 1), 0u);

  // GC16/Full-class clear zeroes exactly the covered tiles.
  ledger.clear(PlutoRect{0, 0, 32, 32});
  EXPECT_EQ(ledger.debt(0, 0), 0u);
  EXPECT_EQ(ledger.debt(1, 0), GhostLedger::kWeightUiQ8);

  // Repeated rail passes stack until saturation, never wrap.
  for (int i = 0; i < 200; ++i) {
    ledger.accrue(PlutoRect{0, 32, 32, 32}, kPlutoRefreshFast);
  }
  EXPECT_EQ(ledger.debt(0, 1), 0xffffu);
}

// The settle-eligibility latch: crossing the threshold at accrual time owes
// a quality pass until a Text/Full clear repays it — decay lowers the
// ordering weight but can never silently forgive the debt (a wall-clock-
// phase-dependent candidate set would make the settled picture racy).
TEST(GhostLedgerTest, OwedLatchSurvivesDecayUntilCleared) {
  GhostLedger ledger;
  ASSERT_TRUE(ledger.configure(grid_128(), 1000, 224));
  ledger.tick(0);

  ledger.accrue(PlutoRect{0, 0, 32, 32}, kPlutoRefreshFast); // 768 >= 224
  EXPECT_TRUE(ledger.owed(0, 0));
  // Sub-threshold accrual does not latch.
  ledger.accrue(PlutoRect{32, 0, 8, 8}, kPlutoRefreshFast); // 48 < 224
  EXPECT_FALSE(ledger.owed(1, 0));

  // Ten half-lives: debt is gone, the latch is not.
  ledger.tick(7'000'000);
  EXPECT_EQ(ledger.debt(0, 0), 0u);
  EXPECT_TRUE(ledger.owed(0, 0));

  // Only a quality clear repays.
  ledger.clear(PlutoRect{0, 0, 32, 32});
  EXPECT_FALSE(ledger.owed(0, 0));

  // Repeated sub-threshold accruals accumulate across passes and latch once
  // the running debt crosses the line.
  ledger.tick(7'050'000);
  for (int i = 0; i < 5; ++i) {
    ledger.accrue(PlutoRect{32, 0, 8, 8}, kPlutoRefreshFast);
  }
  EXPECT_TRUE(ledger.owed(1, 0));
}

TEST(StressLedgerTest, StubAccrualClearAndDecay) {
  StressLedger ledger;
  ASSERT_TRUE(ledger.configure(grid_128()));
  ledger.tick(0);

  for (int i = 0; i < 10; ++i) {
    ledger.accrue(PlutoRect{0, 0, 32, 32}, kPlutoRefreshFast);
    ledger.accrue(PlutoRect{32, 0, 32, 32}, kPlutoRefreshUi);
  }
  EXPECT_EQ(ledger.stress(0, 0), 10u * StressLedger::kFastDelta);
  EXPECT_EQ(ledger.stress(1, 0), 10u * StressLedger::kUiDelta);

  // Quality pass resets.
  ledger.clear(PlutoRect{0, 0, 32, 32});
  EXPECT_EQ(ledger.stress(0, 0), 0u);

  // Slow decay forgives an un-railed tile eventually.
  ledger.tick(60'000'000); // 60 s
  EXPECT_EQ(ledger.stress(1, 0), 0u);
}

TEST(ChromaPendingTest, MarkClearLifecycle) {
  ChromaPendingSet chroma;
  ASSERT_TRUE(chroma.configure(grid_128()));
  EXPECT_FALSE(chroma.any());

  chroma.mark(PlutoRect{10, 10, 50, 20}); // tiles (0,0) and (1,0)
  EXPECT_TRUE(chroma.any());
  EXPECT_TRUE(chroma.pending(0, 0));
  EXPECT_TRUE(chroma.pending(1, 0));
  EXPECT_FALSE(chroma.pending(2, 0));
  EXPECT_EQ(chroma.pending_count(), 2u);

  // Double-mark is idempotent.
  chroma.mark(PlutoRect{10, 10, 50, 20});
  EXPECT_EQ(chroma.pending_count(), 2u);

  // A Full-class clear over part of the set clears only that part.
  chroma.clear(PlutoRect{0, 0, 32, 32});
  EXPECT_FALSE(chroma.pending(0, 0));
  EXPECT_TRUE(chroma.pending(1, 0));
  EXPECT_EQ(chroma.pending_count(), 1u);

  chroma.clear(PlutoRect{0, 0, 128, 128});
  EXPECT_FALSE(chroma.any());
}

TEST(LedgerPersistentStateTest, RoundTripsAndRejectsCorruptionBeforeMutation) {
  const TileGrid grid = grid_128();

  GhostLedger ghost_source;
  ASSERT_TRUE(ghost_source.configure(grid, 1234, 300));
  ghost_source.tick(10'000);
  ghost_source.accrue(PlutoRect{0, 0, 64, 32}, kPlutoRefreshFast);
  ghost_source.tick(50'000);
  GhostLedgerState ghost_state;
  ASSERT_TRUE(ghost_source.export_state(&ghost_state));
  GhostLedger ghost_destination;
  ASSERT_TRUE(ghost_destination.configure(grid, 1234, 300));
  ASSERT_TRUE(ghost_destination.import_state(ghost_state));
  GhostLedgerState ghost_actual;
  ASSERT_TRUE(ghost_destination.export_state(&ghost_actual));
  EXPECT_TRUE(ghost_actual.debt == ghost_state.debt);
  EXPECT_TRUE(ghost_actual.owed == ghost_state.owed);
  EXPECT_EQ(ghost_actual.last_decay_us, ghost_state.last_decay_us);
  GhostLedgerState ghost_corrupt = ghost_state;
  ghost_corrupt.owed[0] = 2;
  EXPECT_FALSE(ghost_destination.import_state(ghost_corrupt));
  ghost_corrupt = ghost_state;
  ghost_corrupt.debt.pop_back();
  EXPECT_FALSE(ghost_destination.import_state(ghost_corrupt));
  ASSERT_TRUE(ghost_destination.export_state(&ghost_actual));
  EXPECT_TRUE(ghost_actual.debt == ghost_state.debt);

  StressLedger stress_source;
  ASSERT_TRUE(stress_source.configure(grid));
  stress_source.tick(5'000);
  stress_source.accrue(PlutoRect{32, 32, 64, 32}, kPlutoRefreshUi);
  StressLedgerState stress_state;
  ASSERT_TRUE(stress_source.export_state(&stress_state));
  StressLedger stress_destination;
  ASSERT_TRUE(stress_destination.configure(grid));
  ASSERT_TRUE(stress_destination.import_state(stress_state));
  StressLedgerState stress_actual;
  ASSERT_TRUE(stress_destination.export_state(&stress_actual));
  EXPECT_TRUE(stress_actual.stress == stress_state.stress);
  StressLedgerState stress_corrupt = stress_state;
  stress_corrupt.grid.cols += 1;
  EXPECT_FALSE(stress_destination.import_state(stress_corrupt));
  ASSERT_TRUE(stress_destination.export_state(&stress_actual));
  EXPECT_TRUE(stress_actual.stress == stress_state.stress);

  ChromaPendingSet chroma_source;
  ASSERT_TRUE(chroma_source.configure(grid));
  chroma_source.mark(PlutoRect{16, 16, 80, 48});
  ChromaPendingState chroma_state;
  ASSERT_TRUE(chroma_source.export_state(&chroma_state));
  ChromaPendingSet chroma_destination;
  ASSERT_TRUE(chroma_destination.configure(grid));
  ASSERT_TRUE(chroma_destination.import_state(chroma_state));
  EXPECT_EQ(chroma_destination.pending_count(), chroma_source.pending_count());
  ChromaPendingState chroma_corrupt = chroma_state;
  ++chroma_corrupt.pending_count;
  EXPECT_FALSE(chroma_destination.import_state(chroma_corrupt));
  chroma_corrupt = chroma_state;
  chroma_corrupt.pending[0] = 9;
  EXPECT_FALSE(chroma_destination.import_state(chroma_corrupt));
  EXPECT_EQ(chroma_destination.pending_count(), chroma_source.pending_count());
}
