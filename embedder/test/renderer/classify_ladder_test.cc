// ClassifyLadder decision-matrix goldens: synthetic TileStats -> expected
// class, covering every rung, the no-flapping stickiness under alternating
// stats, and the two re-pinned structural-full behaviors (frame-0 flash
// shape, large-change flash) that moved here from the RegionScheduler.

#include <gtest/gtest.h>

#include <cstdint>
#include <vector>

#include "renderer/classify_ladder.h"
#include "renderer/ledgers.h"
#include "renderer/tile_pass.h"

namespace {

using pluto::ClassifyLadder;
using pluto::ClassifyLadderConfig;
using pluto::ClassifyLadderState;
using pluto::DirtyTileRecord;
using pluto::GhostLedger;
using pluto::LadderDecision;
using pluto::LadderRung;
using pluto::TileGrid;
using pluto::TileStats;

// A 256x256 / 32 px panel: 8x8 = 64 tiles.
constexpr int32_t kW = 256;
constexpr int32_t kH = 256;
constexpr uint32_t kTilePx = 32;
constexpr uint32_t kCols = 8;

// Histogram presence masks (bit i = level 2*i).
constexpr uint16_t kHistBw = 0x8001;   // {0, 30}
constexpr uint16_t kHistFour = 0x8181; // {0, 14, 16, 30}
constexpr uint16_t kHistRich = 0x8391; // 6 buckets (AA text)

ClassifyLadderConfig test_config() {
  ClassifyLadderConfig config;
  config.width = kW;
  config.height = kH;
  config.tile_px = kTilePx;
  return config;
}

// Test fixture state: a stats plane plus the record list for begin_pass.
struct Frame {
  std::vector<TileStats> stats{64, TileStats{}};
  std::vector<DirtyTileRecord> records;

  // Marks one tile dirty this epoch with the given stats shape.
  void dirty_tile(uint32_t tx, uint32_t ty, uint32_t epoch, uint16_t hist,
                  uint16_t changed_px, uint8_t max_diff,
                  const PlutoRect &dirty_rect, uint16_t sad = 0) {
    const uint32_t idx = ty * kCols + tx;
    TileStats s;
    s.changed_px = changed_px;
    s.sad_pre_dither = sad;
    s.max_diff = max_diff;
    s.level_hist = hist;
    s.dirty = dirty_rect;
    s.epoch = epoch;
    stats[idx] = s;
    records.push_back(DirtyTileRecord{idx, dirty_rect, s});
  }

  void dirty_full_tile(uint32_t tx, uint32_t ty, uint32_t epoch, uint16_t hist,
                       uint8_t max_diff = 255, uint16_t changed_px = 1024,
                       uint16_t sad = 0) {
    const PlutoRect rect{
        static_cast<int32_t>(tx * kTilePx), static_cast<int32_t>(ty * kTilePx),
        static_cast<int32_t>(kTilePx), static_cast<int32_t>(kTilePx)};
    dirty_tile(tx, ty, epoch, hist, changed_px, max_diff, rect, sad);
  }
};

PlutoRect tile_rect(uint32_t tx, uint32_t ty) {
  return PlutoRect{
      static_cast<int32_t>(tx * kTilePx), static_cast<int32_t>(ty * kTilePx),
      static_cast<int32_t>(kTilePx), static_cast<int32_t>(kTilePx)};
}

} // namespace

// (i) Pure black/white content is lossless under the rail fast path.
TEST(ClassifyLadderTest, PureBlackWhiteHistogramIsFast) {
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(test_config()));
  Frame f;
  f.dirty_tile(1, 1, 1, kHistBw, 40, 255, PlutoRect{40, 40, 8, 8});
  ladder.begin_pass(1, f.records.data(), f.records.size());
  const LadderDecision d =
      ladder.classify(PlutoRect{40, 40, 8, 8}, f.stats.data(), nullptr);
  EXPECT_EQ(d.cls, kPlutoRefreshFast);
  EXPECT_EQ(static_cast<int>(d.rung), static_cast<int>(LadderRung::kHistogram));
}

// (i) Up to four distinct level buckets still ride the fast path.
TEST(ClassifyLadderTest, FourLevelHistogramIsFast) {
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(test_config()));
  Frame f;
  f.dirty_tile(2, 2, 1, kHistFour, 60, 200, PlutoRect{70, 70, 10, 10});
  ladder.begin_pass(1, f.records.data(), f.records.size());
  const LadderDecision d =
      ladder.classify(PlutoRect{70, 70, 10, 10}, f.stats.data(), nullptr);
  EXPECT_EQ(d.cls, kPlutoRefreshFast);
  EXPECT_EQ(static_cast<int>(d.rung), static_cast<int>(LadderRung::kHistogram));
}

// (v) Rich content on a never-damaged (cold) region takes Text quality.
TEST(ClassifyLadderTest, RichContentOnColdTilesIsTextDwell) {
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(test_config()));
  Frame f;
  f.dirty_tile(3, 3, 1, kHistRich, 50, 200, PlutoRect{100, 100, 10, 14});
  ladder.begin_pass(1, f.records.data(), f.records.size());
  const LadderDecision d =
      ladder.classify(PlutoRect{100, 100, 10, 14}, f.stats.data(), nullptr);
  EXPECT_EQ(d.cls, kPlutoRefreshText);
  EXPECT_EQ(static_cast<int>(d.rung), static_cast<int>(LadderRung::kDwell));
}

// (v) The hot bucket: typing-style accretion (immediately re-damaged tile,
// DISJOINT dirty rects so the motion rung stays quiet) keeps Text quality.
TEST(ClassifyLadderTest, TypingAccretionStaysTextNeverMotion) {
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(test_config()));
  Frame f;
  LadderDecision d{};
  // Six keystrokes into the same tile, disjoint glyph rects at pass cadence.
  for (uint32_t e = 1; e <= 6; ++e) {
    const PlutoRect glyph{static_cast<int32_t>(32 + 5 * e), 40, 4, 12};
    f = Frame{};
    f.dirty_tile(1, 1, e, kHistRich, 30, 200, glyph);
    ladder.begin_pass(e, f.records.data(), f.records.size());
    d = ladder.classify(glyph, f.stats.data(), nullptr);
    EXPECT_EQ(d.cls, kPlutoRefreshText) << "keystroke epoch " << e;
    EXPECT_EQ(static_cast<int>(d.rung), static_cast<int>(LadderRung::kDwell));
  }
}

// (v) The warm middle (re-damaged after a few quiet epochs) stays Ui.
TEST(ClassifyLadderTest, WarmRedamageIsUi) {
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(test_config()));
  Frame f1;
  f1.dirty_full_tile(4, 4, 1, kHistRich);
  ladder.begin_pass(1, f1.records.data(), f1.records.size());
  // Quiet epochs 2..4 (other regions churn), re-damage at epoch 5: gap 4 is
  // between dwell_hot (1) and dwell_cold (8).
  Frame f2;
  f2.dirty_full_tile(4, 4, 5, kHistRich, 200, 512);
  ladder.begin_pass(5, f2.records.data(), f2.records.size());
  const LadderDecision d =
      ladder.classify(tile_rect(4, 4), f2.stats.data(), nullptr);
  EXPECT_EQ(d.cls, kPlutoRefreshUi);
  EXPECT_EQ(static_cast<int>(d.rung), static_cast<int>(LadderRung::kDwell));
}

// (ii) Same pixels churning at pass cadence -> Fast under motion masking.
TEST(ClassifyLadderTest, OverlappingChurnAtCadenceIsMotionFast) {
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(test_config()));
  const PlutoRect box{64, 64, 24, 24}; // rich content, same rect
  LadderDecision d{};
  for (uint32_t e = 1; e <= 3; ++e) {
    Frame f;
    f.dirty_tile(2, 2, e, kHistRich, 300, 200, box, 900);
    ladder.begin_pass(e, f.records.data(), f.records.size());
    d = ladder.classify(box, f.stats.data(), nullptr);
  }
  // Streak reaches 3 on the third pass.
  EXPECT_EQ(d.cls, kPlutoRefreshFast);
  EXPECT_EQ(static_cast<int>(d.rung), static_cast<int>(LadderRung::kMotion));
}

// (ii) No flapping: once motion fires, damage alternating around the streak
// boundary stays Fast through the stickiness window instead of oscillating
// Fast -> Text -> Fast.
TEST(ClassifyLadderTest, MotionStickinessPreventsClassFlapping) {
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(test_config()));
  const PlutoRect box{64, 64, 24, 24};
  const auto churn = [&](uint32_t epoch) {
    Frame f;
    f.dirty_tile(2, 2, epoch, kHistRich, 300, 200, box, 900);
    ladder.begin_pass(epoch, f.records.data(), f.records.size());
    return ladder.classify(box, f.stats.data(), nullptr);
  };
  churn(1);
  churn(2);
  EXPECT_EQ(churn(3).cls, kPlutoRefreshFast); // streak fires
  // Epoch 4 idle (streak would reset); epoch 5 damage lands inside the
  // stickiness window -> still Fast, no flap.
  const LadderDecision d5 = churn(5);
  EXPECT_EQ(d5.cls, kPlutoRefreshFast);
  EXPECT_EQ(static_cast<int>(d5.rung), static_cast<int>(LadderRung::kMotion));
}

// (iv) Scenecut: dense whole-panel change with real intensity -> ONE
// non-flash quality repaint (Text). Full/GC16 would invert the region to a
// negative for hundreds of ms — screen-sized cuts must not flash; the ghost
// ledger + settles own the deep-quality repayment.
TEST(ClassifyLadderTest, DenseLargeChangeTakesNonFlashScenecut) {
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(test_config()));
  Frame f;
  for (uint32_t ty = 0; ty < 8; ++ty) {
    for (uint32_t tx = 0; tx < 8; ++tx) {
      f.dirty_full_tile(tx, ty, 1, kHistBw);
    }
  }
  ladder.begin_pass(1, f.records.data(), f.records.size());
  const LadderDecision d =
      ladder.classify(PlutoRect{0, 0, kW, kH}, f.stats.data(), nullptr);
  EXPECT_EQ(d.cls, kPlutoRefreshText);
  EXPECT_EQ(static_cast<int>(d.rung), static_cast<int>(LadderRung::kScenecut));
}

// (iv) The intensity gate: a full-coverage change with near-zero pre-dither
// delta (the all-white first frame against the sentinel plane) does NOT
// flash — there is nothing visible to clean up.
TEST(ClassifyLadderTest, LowIntensityFullCoverageDoesNotScenecut) {
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(test_config()));
  Frame f;
  for (uint32_t ty = 0; ty < 8; ++ty) {
    for (uint32_t tx = 0; tx < 8; ++tx) {
      f.dirty_full_tile(tx, ty, 1, /*hist=*/0x8000u, /*max_diff=*/0);
    }
  }
  ladder.begin_pass(1, f.records.data(), f.records.size());
  const LadderDecision d =
      ladder.classify(PlutoRect{0, 0, kW, kH}, f.stats.data(), nullptr);
  EXPECT_NE(d.cls, kPlutoRefreshFull);
}

// (iv) Motion masks the scenecut: a full-screen rich-content animation
// churning at pass cadence stays Fast instead of flashing every frame.
TEST(ClassifyLadderTest, FullScreenChurnStaysFastNeverScenecuts) {
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(test_config()));
  LadderDecision d{};
  for (uint32_t e = 1; e <= 4; ++e) {
    Frame f;
    for (uint32_t ty = 0; ty < 8; ++ty) {
      for (uint32_t tx = 0; tx < 8; ++tx) {
        f.dirty_full_tile(tx, ty, e, kHistRich);
      }
    }
    ladder.begin_pass(e, f.records.data(), f.records.size());
    d = ladder.classify(PlutoRect{0, 0, kW, kH}, f.stats.data(), nullptr);
  }
  EXPECT_EQ(d.cls, kPlutoRefreshFast);
  EXPECT_EQ(static_cast<int>(d.rung), static_cast<int>(LadderRung::kMotion));
}

// (iv) Ghost-debt bias: coverage below the base threshold flashes anyway
// when the damaged tiles already owe quality settles.
TEST(ClassifyLadderTest, GhostDebtLowersScenecutThreshold) {
  ClassifyLadderConfig config = test_config();
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(config));

  // 16 of 64 tiles fully changed = 25% coverage (< 30% base threshold).
  const PlutoRect region{0, 0, 128, 128}; // 4x4 tiles
  const auto make_frame = [&](uint32_t epoch) {
    Frame f;
    for (uint32_t ty = 0; ty < 4; ++ty) {
      for (uint32_t tx = 0; tx < 4; ++tx) {
        f.dirty_full_tile(tx, ty, epoch, kHistBw);
      }
    }
    return f;
  };

  // Without debt: no scenecut (25% < 30%).
  {
    Frame f = make_frame(1);
    ladder.begin_pass(1, f.records.data(), f.records.size());
    const LadderDecision d = ladder.classify(region, f.stats.data(), nullptr);
    EXPECT_NE(static_cast<int>(d.rung),
              static_cast<int>(LadderRung::kScenecut));
  }
  // With every dirty tile owing ghost debt: threshold drops ~33% -> the
  // scenecut rung fires (non-flash Text quality repaint).
  {
    TileGrid grid;
    ASSERT_TRUE(grid.configure(kW, kH, kTilePx));
    GhostLedger ghost;
    ASSERT_TRUE(ghost.configure(grid, 1000, 96));
    ghost.accrue(region, kPlutoRefreshFast); // latches owed everywhere
    ClassifyLadder fresh;
    ASSERT_TRUE(fresh.configure(config));
    Frame f = make_frame(1);
    fresh.begin_pass(1, f.records.data(), f.records.size());
    const LadderDecision d = fresh.classify(region, f.stats.data(), &ghost);
    EXPECT_EQ(d.cls, kPlutoRefreshText);
    EXPECT_EQ(static_cast<int>(d.rung),
              static_cast<int>(LadderRung::kScenecut));
  }
}

// (iii) NAS structure: enabled with permissive constants, the cheapest mode
// whose masked error passes the JND budget wins.
TEST(ClassifyLadderTest, NasRungChoosesCheapestPassingMode) {
  ClassifyLadderConfig config = test_config();
  config.nas_enabled = true;
  // Fast never passes; Ui passes anything (k = 0).
  config.nas_k_q8[0] = UINT32_MAX;
  config.nas_k_q8[1] = 0;
  config.nas_k_q8[2] = 0;
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(config));
  Frame f;
  f.dirty_full_tile(5, 5, 1, kHistRich, 200, 400, /*sad=*/800);
  ladder.begin_pass(1, f.records.data(), f.records.size());
  const LadderDecision d =
      ladder.classify(tile_rect(5, 5), f.stats.data(), nullptr);
  EXPECT_EQ(d.cls, kPlutoRefreshUi);
  EXPECT_EQ(static_cast<int>(d.rung), static_cast<int>(LadderRung::kNas));
}

// (iii) The default constants are conservative: nas_enabled with untouched
// k's changes nothing (structure in place, constants await tuning).
TEST(ClassifyLadderTest, NasDefaultConstantsNeverFire) {
  ClassifyLadderConfig config = test_config();
  config.nas_enabled = true;
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(config));
  Frame f;
  f.dirty_full_tile(5, 5, 1, kHistRich, 200, 400, /*sad=*/800);
  ladder.begin_pass(1, f.records.data(), f.records.size());
  const LadderDecision d =
      ladder.classify(tile_rect(5, 5), f.stats.data(), nullptr);
  EXPECT_NE(static_cast<int>(d.rung), static_cast<int>(LadderRung::kNas));
}

// (v) Preserved big-repaint rule: sparse rich damage across >70% of the
// panel takes Text quality (coverage too thin for a scenecut).
TEST(ClassifyLadderTest, LargeAreaSparseDamageIsText) {
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(test_config()));
  Frame f;
  for (uint32_t ty = 0; ty < 8; ++ty) {
    for (uint32_t tx = 0; tx < 8; ++tx) {
      // A few changed px per tile: 64 tiles * 64 px = 6% coverage.
      f.dirty_tile(tx, ty, 1, kHistRich, 64, 200,
                   PlutoRect{static_cast<int32_t>(tx * kTilePx),
                             static_cast<int32_t>(ty * kTilePx), 8, 8});
    }
  }
  ladder.begin_pass(1, f.records.data(), f.records.size());
  // Warm history so the dwell buckets do not decide: tiles damaged at
  // epoch 1, classify at epoch 4 (gap 3: warm) -> the area rule must fire.
  Frame f2;
  for (uint32_t ty = 0; ty < 8; ++ty) {
    for (uint32_t tx = 0; tx < 8; ++tx) {
      f2.dirty_tile(tx, ty, 4, kHistRich, 64, 200,
                    PlutoRect{static_cast<int32_t>(tx * kTilePx),
                              static_cast<int32_t>(ty * kTilePx), 8, 8});
    }
  }
  ladder.begin_pass(4, f2.records.data(), f2.records.size());
  const LadderDecision d =
      ladder.classify(PlutoRect{0, 0, kW, kH}, f2.stats.data(), nullptr);
  EXPECT_EQ(d.cls, kPlutoRefreshText);
  EXPECT_EQ(static_cast<int>(d.rung), static_cast<int>(LadderRung::kDwell));
}

// Stale stats never classify: a region whose tiles were dirty only in an
// older epoch is not this pass's damage.
TEST(ClassifyLadderTest, StaleEpochTilesAreIgnored) {
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(test_config()));
  Frame f;
  f.dirty_full_tile(1, 1, 1, kHistBw);
  ladder.begin_pass(1, f.records.data(), f.records.size());
  // Advance to epoch 2 with no damage records.
  ladder.begin_pass(2, nullptr, 0);
  const LadderDecision d =
      ladder.classify(tile_rect(1, 1), f.stats.data(), nullptr);
  EXPECT_EQ(d.cls, kPlutoRefreshUi); // default: nothing dirty this pass
}

// (iv) Scenecut hysteresis (probe: alternating tiny/huge damage). A large
// intense change flashes ONCE; when the same region keeps producing
// scenecut-shaped damage every other pass (big redraw alternating with a
// tiny churn rect — half-cadence animation, so the motion streak never
// builds), the repeats are churn, not cuts: they must NOT oscillate the
// class into a Full flash on every huge frame.
TEST(ClassifyLadderTest, AlternatingTinyHugeDamageDoesNotFlashPerFrame) {
  ClassifyLadder ladder;
  ASSERT_TRUE(ladder.configure(test_config()));

  // Huge: 5 of 8 tile rows = 62.5% coverage, real intensity (scenecut
  // shape). Tiny: one sub-rect churning inside tile (2,2) every pass.
  const PlutoRect huge{0, 0, kW, 160};
  const PlutoRect tiny{68, 68, 8, 8};
  size_t scenecut_count = 0;
  std::vector<PlutoRefreshClass> huge_classes;
  for (uint32_t e = 1; e <= 12; ++e) {
    Frame f;
    if (e % 2 == 1) {
      for (uint32_t ty = 0; ty < 5; ++ty) {
        for (uint32_t tx = 0; tx < 8; ++tx) {
          f.dirty_full_tile(tx, ty, e, kHistRich, /*max_diff=*/200);
        }
      }
    } else {
      f.dirty_tile(2, 2, e, kHistRich, 40, 200, tiny);
    }
    ladder.begin_pass(e, f.records.data(), f.records.size());
    const PlutoRect region = (e % 2 == 1) ? huge : tiny;
    const LadderDecision d = ladder.classify(region, f.stats.data(), nullptr);
    if (d.rung == LadderRung::kScenecut) {
      ++scenecut_count;
    }
    if (e % 2 == 1) {
      huge_classes.push_back(d.cls);
    }
  }
  // The first huge frame may take the scenecut rung (a genuine cut); every
  // repeat within the cooldown is churn and must not.
  EXPECT_LE(scenecut_count, 1u) << "per-frame scenecut oscillation (thrash)";
  // And the huge frames settle on ONE stable non-flash class after frame 1.
  for (size_t i = 2; i < huge_classes.size(); ++i) {
    EXPECT_EQ(huge_classes[i], huge_classes[1]) << "huge frame " << i;
  }
}

TEST(ClassifyLadderTest,
     PersistentTileHistoryRoundTripsWithoutResettableScratch) {
  ClassifyLadder source;
  ASSERT_TRUE(source.configure(test_config()));
  const PlutoRect box{64, 64, 24, 24};
  for (uint32_t epoch = 1; epoch <= 3; ++epoch) {
    Frame frame;
    frame.dirty_tile(2, 2, epoch, kHistRich, 300, 200, box, 900);
    source.begin_pass(epoch, frame.records.data(), frame.records.size());
    (void)source.classify(box, frame.stats.data(), nullptr);
  }

  ClassifyLadderState state;
  ASSERT_TRUE(source.export_state(&state));
  const size_t tile = 2u * kCols + 2u;
  state.history[tile].scenecut_epoch = 2;
  ClassifyLadder destination;
  ASSERT_TRUE(destination.configure(test_config()));
  ASSERT_TRUE(destination.import_state(state));

  ClassifyLadderState actual;
  ASSERT_TRUE(destination.export_state(&actual));
  EXPECT_EQ(actual.epoch, 3u);
  ASSERT_EQ(actual.history.size(), state.history.size());
  EXPECT_EQ(actual.history[tile].last_epoch, 3u);
  EXPECT_EQ(actual.history[tile].prev_epoch, 2u);
  EXPECT_EQ(actual.history[tile].streak, 3u);
  EXPECT_EQ(actual.history[tile].fast_until, 5u);
  EXPECT_EQ(actual.history[tile].scenecut_epoch, 2u);
  EXPECT_EQ(actual.history[tile].last_dirty.x, box.x);

  ClassifyLadderState corrupt = state;
  corrupt.history.pop_back();
  EXPECT_FALSE(destination.import_state(corrupt));
  corrupt = state;
  ++corrupt.config.motion_streak;
  EXPECT_FALSE(destination.import_state(corrupt));
  corrupt = state;
  corrupt.history[tile].last_dirty.x = -1;
  EXPECT_FALSE(destination.import_state(corrupt));
  ASSERT_TRUE(destination.export_state(&actual));
  EXPECT_EQ(actual.history[tile].last_epoch, 3u);
  EXPECT_EQ(actual.history[tile].scenecut_epoch, 2u);
}
