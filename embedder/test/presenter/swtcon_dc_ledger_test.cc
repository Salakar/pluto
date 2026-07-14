#include "presenter/swtcon/dc_ledger.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <cstdlib>

namespace {

using pluto::swtcon::DcLedger;
using pluto::swtcon::DcLedgerConfig;
using pluto::swtcon::DcLedgerHandoffState;

constexpr int kWidth = 64;
constexpr int kHeight = 64;
constexpr int kStride = 64;

DcLedgerConfig small_config() {
  DcLedgerConfig config;
  config.dc_pixel_cap = 8;  // small cap makes saturation reachable in tests
  return config;
}

TEST(DcLedgerTest, ConfigureValidatesGeometry) {
  DcLedger ledger;
  EXPECT_FALSE(ledger.configure(0, kHeight, kStride, 32, DcLedgerConfig{}));
  EXPECT_FALSE(ledger.configure(kWidth, kHeight, 60, 32, DcLedgerConfig{}));
  EXPECT_FALSE(
      ledger.configure(kWidth, kHeight, kStride, 0, DcLedgerConfig{}));
  EXPECT_TRUE(
      ledger.configure(kWidth, kHeight, kStride, 32, DcLedgerConfig{}));
  EXPECT_TRUE(ledger.valid());
  EXPECT_EQ(ledger.tile_cols(), 2u);
  EXPECT_EQ(ledger.tile_rows(), 2u);
}

TEST(DcLedgerTest, HandoffRoundTripPreservesFullStrideAndTileDebt) {
  DcLedgerConfig config = small_config();
  DcLedger source;
  // Deliberately non-panel, non-tile-aligned geometry proves the state API is
  // geometry-derived rather than Move-sized.
  ASSERT_TRUE(source.configure(13, 7, 16, 5, config));
  source.charge(0, 1);
  source.charge(6 * 16 + 15, 6); // stride padding is behavior-bearing too
  source.charge_truncation(5);
  source.charge_double_scan(5, 3);
  source.charge_rescan(5, -73);

  DcLedgerHandoffState expected;
  ASSERT_TRUE(source.export_handoff_state(&expected));
  ASSERT_EQ(expected.dc.size(), 16u * 7u);
  ASSERT_EQ(expected.stress.size(), 6u);
  EXPECT_EQ(expected.dc[0], 1);
  EXPECT_EQ(expected.dc[6 * 16 + 15], -1);
  EXPECT_EQ(expected.stress[5],
            static_cast<std::uint16_t>(config.k_cancel + 3 * config.k_dscan));
  EXPECT_EQ(expected.rescan_dc[5], -73);

  DcLedger restored;
  ASSERT_TRUE(restored.configure(13, 7, 16, 5, config));
  restored.charge(3, 1);
  restored.charge_truncation(0);
  ASSERT_TRUE(restored.import_handoff_state(expected));
  EXPECT_EQ(restored.prev_estimated_count(), 0u);
  EXPECT_EQ(restored.saturations(), 0u);

  DcLedgerHandoffState actual;
  ASSERT_TRUE(restored.export_handoff_state(&actual));
  EXPECT_TRUE(actual == expected);
}

TEST(DcLedgerTest, HandoffRejectsCorruptionWithoutPartialMutation) {
  DcLedgerConfig config = small_config();
  DcLedger target;
  ASSERT_TRUE(target.configure(13, 7, 16, 5, config));
  target.charge(2, 1);
  target.charge_double_scan(1, 2);
  target.charge_rescan(1, 31);

  DcLedgerHandoffState baseline;
  ASSERT_TRUE(target.export_handoff_state(&baseline));
  const auto reject_unchanged = [&](DcLedgerHandoffState corrupt) {
    EXPECT_FALSE(target.import_handoff_state(corrupt));
    DcLedgerHandoffState after;
    ASSERT_TRUE(target.export_handoff_state(&after));
    EXPECT_TRUE(after == baseline);
  };

  DcLedgerHandoffState corrupt = baseline;
  corrupt.dc[0] = static_cast<std::int8_t>(config.dc_pixel_cap + 1);
  reject_unchanged(corrupt);

  corrupt = baseline;
  corrupt.rescan_dc[0] = config.dc_pixel_cap * 5 * 5 + 1;
  reject_unchanged(corrupt);

  corrupt = baseline;
  corrupt.stress.pop_back();
  reject_unchanged(corrupt);

  corrupt = baseline;
  ++corrupt.width;
  reject_unchanged(corrupt);

  corrupt = baseline;
  ++corrupt.config.k_pause;
  reject_unchanged(corrupt);

  target.mark_prev_estimated(2);
  EXPECT_FALSE(target.export_handoff_state(&corrupt));
  EXPECT_FALSE(target.import_handoff_state(baseline));
  EXPECT_TRUE(target.prev_estimated(2));
  EXPECT_EQ(target.dc(2), baseline.dc[2]);
}

TEST(DcLedgerTest, ChargeAppliesTheImpulseMap) {
  DcLedger ledger;
  ASSERT_TRUE(ledger.configure(kWidth, kHeight, kStride, 32, small_config()));

  // Protocol: 0 = hold, 1-3 push white (+1), 4-7 push black (-1).
  EXPECT_EQ(ledger.impulse(0), 0);
  for (std::uint8_t code = 1; code <= 3; ++code) {
    EXPECT_EQ(ledger.impulse(code), 1) << "code=" << int(code);
  }
  for (std::uint8_t code = 4; code <= 7; ++code) {
    EXPECT_EQ(ledger.impulse(code), -1) << "code=" << int(code);
  }

  ledger.charge(5, 1);
  ledger.charge(5, 2);
  ledger.charge(5, 0);  // hold: no change
  EXPECT_EQ(ledger.dc(5), 2);
  ledger.charge(5, 6);
  ledger.charge(5, 7);
  ledger.charge(5, 4);
  EXPECT_EQ(ledger.dc(5), -1);
  EXPECT_EQ(ledger.dc(6), 0);  // neighbours untouched
  EXPECT_EQ(ledger.saturations(), 0u);
}

TEST(DcLedgerTest, SaturatesAtPixelCapAndCountsEveryClamp) {
  DcLedger ledger;
  ASSERT_TRUE(ledger.configure(kWidth, kHeight, kStride, 32, small_config()));

  for (int i = 0; i < 8 + 5; ++i) {
    ledger.charge(0, 1);  // +1 each
  }
  EXPECT_EQ(ledger.dc(0), 8);
  EXPECT_EQ(ledger.saturations(), 5u);

  for (int i = 0; i < 16 + 3; ++i) {
    ledger.charge(0, 5);  // -1 each
  }
  EXPECT_EQ(ledger.dc(0), -8);
  EXPECT_EQ(ledger.saturations(), 8u);
}

TEST(DcLedgerTest, BalancedCompletionRenormalizesUnderTrustVendorBalance) {
  DcLedger ledger;
  ASSERT_TRUE(ledger.configure(kWidth, kHeight, kStride, 32, small_config()));

  ledger.charge(7, 1);
  ledger.charge(7, 1);
  ledger.mark_prev_estimated(7);
  ASSERT_EQ(ledger.dc(7), 2);
  ASSERT_TRUE(ledger.prev_estimated(7));

  // Non-balanced mode (7, fast rail): full-sequence completion trusts the
  // optical state again but does NOT reset the impulse debt.
  ledger.renormalize_on_completion(7, 7);
  EXPECT_EQ(ledger.dc(7), 2);
  EXPECT_FALSE(ledger.prev_estimated(7));

  // Balanced GC16-family completion resets the deviation to zero.
  EXPECT_TRUE(ledger.balanced_mode(2));
  EXPECT_TRUE(ledger.balanced_mode(5));
  EXPECT_TRUE(ledger.balanced_mode(6));
  EXPECT_FALSE(ledger.balanced_mode(7));
  ledger.renormalize_on_completion(7, 2);
  EXPECT_EQ(ledger.dc(7), 0);
}

TEST(DcLedgerTest, TrustVendorBalanceOffKeepsAccumulatedDebt) {
  DcLedgerConfig config = small_config();
  config.trust_vendor_balance = false;
  DcLedger ledger;
  ASSERT_TRUE(ledger.configure(kWidth, kHeight, kStride, 32, config));

  ledger.charge(3, 1);
  ledger.charge(3, 1);
  ledger.renormalize_on_completion(3, 2);  // balanced mode, trust off
  EXPECT_EQ(ledger.dc(3), 2);
}

TEST(DcLedgerTest, PrevEstimatedBitplaneIsPerPixel) {
  DcLedger ledger;
  ASSERT_TRUE(ledger.configure(kWidth, kHeight, kStride, 32, small_config()));

  // Adjacent bits in one byte stay independent.
  for (std::size_t px = 16; px < 24; px += 2) {
    ledger.mark_prev_estimated(px);
  }
  EXPECT_EQ(ledger.prev_estimated_count(), 4u);
  for (std::size_t px = 16; px < 24; ++px) {
    EXPECT_EQ(ledger.prev_estimated(px), (px % 2) == 0) << "px=" << px;
  }
  // Repeating either transition is idempotent: the aggregate tracks 0->1
  // and 1->0 bit transitions, not calls.
  ledger.mark_prev_estimated(18);
  EXPECT_EQ(ledger.prev_estimated_count(), 4u);
  ledger.clear_prev_estimated(18);
  EXPECT_EQ(ledger.prev_estimated_count(), 3u);
  ledger.clear_prev_estimated(18);
  EXPECT_EQ(ledger.prev_estimated_count(), 3u);
  EXPECT_FALSE(ledger.prev_estimated(18));
  EXPECT_TRUE(ledger.prev_estimated(16));
  EXPECT_TRUE(ledger.prev_estimated(20));

  ledger.clear_all_prev_estimated();
  EXPECT_EQ(ledger.prev_estimated_count(), 0u);
  for (std::size_t px = 16; px < 24; ++px) {
    EXPECT_FALSE(ledger.prev_estimated(px));
  }

  ledger.mark_prev_estimated(23);
  ASSERT_EQ(ledger.prev_estimated_count(), 1u);
  EXPECT_FALSE(ledger.configure(0, kHeight, kStride, 32, small_config()));
  EXPECT_EQ(ledger.prev_estimated_count(), 0u)
      << "a rejected reconfigure still invalidates the old bitplane";
  ASSERT_TRUE(ledger.configure(kWidth, kHeight, kStride, 32, small_config()));
  EXPECT_EQ(ledger.prev_estimated_count(), 0u)
      << "configure is a bitplane reset boundary";
}

TEST(DcLedgerTest, StressAccountingAndBalancedForceGate) {
  DcLedgerConfig config = small_config();
  config.k_cancel = 4;
  config.k_pause = 1;
  config.k_dscan = 2;
  config.dc_stress_force = 10;
  DcLedger ledger;
  ASSERT_TRUE(ledger.configure(kWidth, kHeight, kStride, 32, config));

  ledger.charge_truncation(1);
  ledger.charge_truncation(1);
  ledger.charge_pause(1);
  ledger.charge_double_scan(1);
  EXPECT_EQ(ledger.stress(1), 11);
  EXPECT_TRUE(ledger.forces_balanced(1));
  EXPECT_FALSE(ledger.forces_balanced(0));

  ledger.clear_stress(1);
  EXPECT_EQ(ledger.stress(1), 0);
  EXPECT_FALSE(ledger.forces_balanced(1));

  // Coalesced double-scan charge: linear in the extra-scan count, and a
  // huge count saturates instead of wrapping.
  ledger.charge_double_scan(2, 3);
  EXPECT_EQ(ledger.stress(2), 6);
  ledger.charge_double_scan(2, 1u << 20);
  EXPECT_EQ(ledger.stress(2), 0xffff);
}

// Aggregate rescan account (double-scan recharge without plane
// reads): per-tile signed impulse from the presenter's build-time
// summaries, saturating at the plane-level cap (dc_pixel_cap x tile
// area) with every clamp counted; a completed balanced pass
// (clear_stress) repays it.
TEST(DcLedgerTest, RescanAccountSaturatesAtTileCapAndRepaysWithStress) {
  DcLedger ledger;
  ASSERT_TRUE(ledger.configure(kWidth, kHeight, kStride, 32, small_config()));
  const std::int64_t cap = 8 * 32 * 32;  // dc_pixel_cap x tile area

  ledger.charge_rescan(1, 500);
  ledger.charge_rescan(1, -200);
  EXPECT_EQ(ledger.rescan_dc(1), 300);
  EXPECT_EQ(ledger.rescan_dc(0), 0);  // neighbours untouched
  EXPECT_EQ(ledger.saturations(), 0u);

  ledger.charge_rescan(1, cap);  // would exceed +cap: clamps, counted
  EXPECT_EQ(ledger.rescan_dc(1), cap);
  EXPECT_EQ(ledger.saturations(), 1u);
  ledger.charge_rescan(1, -3 * cap);
  EXPECT_EQ(ledger.rescan_dc(1), -cap);
  EXPECT_EQ(ledger.saturations(), 2u);

  // Balanced-pass repayment clears the rescan debt with the stress.
  ledger.charge_double_scan(1, 2);
  ledger.clear_stress(1);
  EXPECT_EQ(ledger.rescan_dc(1), 0);
  EXPECT_EQ(ledger.stress(1), 0);
}

// Renormalization property of the deviation model: repeated balanced
// full sequences keep |dc| bounded and reset it on every completion;
// the same op stream WITHOUT renormalization accumulates until the
// saturating cap, with every clamp counted.
TEST(DcLedgerTest, RenormalizationPropertyBoundsDebt) {
  DcLedger trusted;
  DcLedger untrusted;
  DcLedgerConfig config = small_config();
  ASSERT_TRUE(trusted.configure(kWidth, kHeight, kStride, 32, config));
  config.trust_vendor_balance = false;
  ASSERT_TRUE(untrusted.configure(kWidth, kHeight, kStride, 32, config));

  std::srand(1234);
  const std::size_t px = 42;
  for (int cycle = 0; cycle < 200; ++cycle) {
    // One "vendor sequence" with a mild net-positive imbalance (as a real
    // truncated/asymmetric drive would leave behind).
    for (int op = 0; op < 12; ++op) {
      const std::uint8_t code =
          (op < 7) ? static_cast<std::uint8_t>(1 + std::rand() % 3)
                   : static_cast<std::uint8_t>(4 + std::rand() % 4);
      trusted.charge(px, code);
      untrusted.charge(px, code);
      EXPECT_LE(static_cast<int>(trusted.dc(px)), 8);
      EXPECT_GE(static_cast<int>(trusted.dc(px)), -8);
    }
    trusted.renormalize_on_completion(px, 2);
    untrusted.renormalize_on_completion(px, 2);  // trust off: no reset
    EXPECT_EQ(trusted.dc(px), 0) << "cycle=" << cycle;
  }

  // The untrusted ledger accumulated the per-cycle imbalance (+2/cycle),
  // rode the +8 cap on every later cycle's white phase (clamping, counted),
  // and ends each cycle at cap-5; debt can never grow invisibly.
  EXPECT_EQ(static_cast<int>(untrusted.dc(px)), 3);
  EXPECT_GT(untrusted.saturations(), 300u);
  EXPECT_EQ(trusted.saturations(), 0u);
}

}  // namespace
