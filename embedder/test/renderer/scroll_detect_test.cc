// ScrollDetector suite (Stage 6): exact translation recovery (both
// directions, sub-band), the distinctive-row filter against repeating
// content, memcmp-verify rejection of fabricated hash votes, and the
// small-band gate.

#include <gtest/gtest.h>

#include <cstdint>
#include <cstring>
#include <vector>

#include "renderer/frame_ledger.h"
#include "renderer/rect_utils.h"
#include "renderer/scroll_detect.h"
#include "renderer/tile_pass.h"

namespace {

using pluto::FrameLedger;
using pluto::FrameLedgerConfig;
using pluto::ScrollDetectConfig;
using pluto::ScrollDetector;
using pluto::ScrollMove;
using pluto::TilePass;

constexpr int32_t kW = 256;
constexpr int32_t kH = 512;
constexpr PlutoRect kBand{0, 64, kW, 384};  // sub-band of the surface

ScrollDetectConfig test_config() {
  ScrollDetectConfig config;
  config.width = kW;
  config.height = kH;
  config.min_band_rows = 64;
  config.min_band_area_px = static_cast<int64_t>(kW) * 64;
  config.max_dy = 64;
  config.min_votes = 24;
  config.majority_percent = 60;
  config.verify_rows = 3;
  return config;
}

FrameLedgerConfig ledger_config() {
  FrameLedgerConfig config;
  config.width = kW;
  config.height = kH;
  config.tile_px = 32;
  return config;
}

uint32_t row_seed(int32_t line) {
  uint32_t v = static_cast<uint32_t>(line) * 2654435761u;
  v ^= v >> 15;
  return v;
}

// Rail-only (black on white) ragged text rows: byte content is a pure
// function of the content line index, so translation is byte-exact after
// the position-keyed quantizer.
void paint_row(std::vector<uint8_t>* gray, int32_t y, int32_t line) {
  uint8_t* row = gray->data() + static_cast<size_t>(y) * kW;
  std::memset(row, 0xff, kW);
  const uint32_t h = row_seed(line);
  const int32_t start = 16 + static_cast<int32_t>(h % 64u);
  const int32_t width = 64 + static_cast<int32_t>((h >> 8) % 128u);
  const int32_t end = std::min<int32_t>(start + width, kW);
  std::memset(row + start, 0x00, static_cast<size_t>(end - start));
}

// Paints the full surface: static black header outside the band, ragged
// content rows at `offset` inside the band.
std::vector<uint8_t> make_frame(int32_t offset) {
  std::vector<uint8_t> gray(static_cast<size_t>(kW) * kH, 0xff);
  for (int32_t y = 0; y < 32; ++y) {
    std::memset(gray.data() + static_cast<size_t>(y) * kW, 0x00, kW);
  }
  for (int32_t y = kBand.y; y < pluto::rect_bottom(kBand); ++y) {
    paint_row(&gray, y, y + offset);
  }
  return gray;
}

PlutoSurface surface_for(const std::vector<uint8_t>& gray) {
  return PlutoSurface{gray.data(), static_cast<size_t>(kW), kW, kH,
                        kPlutoPixelFormatGray8};
}

}  // namespace

TEST(ScrollDetectorTest, FindsExactUpTranslationWithStripAtBottom) {
  FrameLedger ledger(ledger_config());
  ASSERT_TRUE(ledger.valid());
  TilePass pass;
  ScrollDetector detector;
  ASSERT_TRUE(detector.configure(test_config()));

  const std::vector<uint8_t> frame_a = make_frame(0);
  ASSERT_GT(pass.run(surface_for(frame_a), nullptr, 0, &ledger), 0u);

  // Content moves UP by 24 px: new[y] = old[y + 24] -> dy = -24.
  const std::vector<uint8_t> frame_b = make_frame(24);
  ASSERT_GT(pass.run(surface_for(frame_b), &kBand, 1, &ledger), 0u);

  ScrollMove move{};
  ASSERT_TRUE(detector.detect(ledger, pass.dirty_bounds(), &move));
  EXPECT_EQ(move.dy, -24);
  EXPECT_EQ(detector.detected_moves(), 1u);
  // Body: matched rows [band.y, band.bottom - 24).
  EXPECT_EQ(move.body.y, kBand.y);
  EXPECT_EQ(pluto::rect_bottom(move.body), pluto::rect_bottom(kBand) - 24);
  // Revealed strip: the bottom 24 rows of the band.
  EXPECT_EQ(move.strip.y, pluto::rect_bottom(kBand) - 24);
  EXPECT_EQ(move.strip.height, 24);
  EXPECT_TRUE(pluto::rect_intersects(move.band, kBand));
}

TEST(ScrollDetectorTest, FindsExactDownTranslationWithStripAtTop) {
  FrameLedger ledger(ledger_config());
  ASSERT_TRUE(ledger.valid());
  TilePass pass;
  ScrollDetector detector;
  ASSERT_TRUE(detector.configure(test_config()));

  const std::vector<uint8_t> frame_a = make_frame(100);
  ASSERT_GT(pass.run(surface_for(frame_a), nullptr, 0, &ledger), 0u);

  // Content moves DOWN by 16 px: new[y] = old[y - 16] -> dy = +16.
  const std::vector<uint8_t> frame_b = make_frame(84);
  ASSERT_GT(pass.run(surface_for(frame_b), &kBand, 1, &ledger), 0u);

  ScrollMove move{};
  ASSERT_TRUE(detector.detect(ledger, pass.dirty_bounds(), &move));
  EXPECT_EQ(move.dy, 16);
  // Revealed strip: the top 16 rows of the band.
  EXPECT_EQ(move.strip.y, kBand.y);
  EXPECT_EQ(move.strip.height, 16);
  EXPECT_EQ(move.body.y, kBand.y + 16);
}

// Repeating content (stripes with a short period) is offset-ambiguous: the
// distinctive-row filter must reject the vote entirely.
TEST(ScrollDetectorTest, RepeatingContentIsRejectedByDistinctiveFilter) {
  FrameLedger ledger(ledger_config());
  ASSERT_TRUE(ledger.valid());
  TilePass pass;
  ScrollDetector detector;
  ASSERT_TRUE(detector.configure(test_config()));

  const auto striped_frame = [&](int32_t offset) {
    std::vector<uint8_t> gray(static_cast<size_t>(kW) * kH, 0xff);
    for (int32_t y = kBand.y; y < pluto::rect_bottom(kBand); ++y) {
      paint_row(&gray, y, (y + offset) % 16);  // period-16 stripes
    }
    return gray;
  };
  const std::vector<uint8_t> frame_a = striped_frame(0);
  ASSERT_GT(pass.run(surface_for(frame_a), nullptr, 0, &ledger), 0u);
  const std::vector<uint8_t> frame_b = striped_frame(4);
  ASSERT_GT(pass.run(surface_for(frame_b), &kBand, 1, &ledger), 0u);

  ScrollMove move{};
  EXPECT_FALSE(detector.detect(ledger, pass.dirty_bounds(), &move));
  EXPECT_EQ(detector.detected_moves(), 0u);
}

// Fabricated hash votes (a unanimous majority claiming dy = -24) must fail
// the sampled memcmp against the true previous-pass row bytes: a hash
// collision can never move ghost state or suppress body damage.
TEST(ScrollDetectorTest, HashVotesWithoutMatchingBytesAreRejected) {
  FrameLedger ledger(ledger_config());
  ASSERT_TRUE(ledger.valid());
  ScrollDetector detector;
  ASSERT_TRUE(detector.configure(test_config()));

  const int32_t y0 = kBand.y;
  const int32_t y1 = pluto::rect_bottom(kBand);

  // Pass 1: "previous" hashes.
  ledger.begin_pass();
  for (int32_t y = y0; y < y1; ++y) {
    ledger.row_hash_cur()[y] = 0x1000u + static_cast<uint32_t>(y);
  }
  // Pass 2: hashes claim new[y] == old[y + 24] (dy = -24) for every row.
  ledger.begin_pass();
  for (int32_t y = y0; y < y1; ++y) {
    const int32_t src = y + 24;
    ledger.row_hash_cur()[y] =
        src < y1 ? 0x1000u + static_cast<uint32_t>(src)
                 : 0x2000u + static_cast<uint32_t>(y);  // fresh strip rows
  }
  // Row samples: previous bytes were pattern A...
  for (int32_t y = y0; y < y1; ++y) {
    if (y % static_cast<int32_t>(FrameLedger::kRowSamplePeriod) == 0) {
      std::memset(ledger.row_sample_slot(static_cast<uint32_t>(y)),
                  static_cast<int>(y & 0x1f), ledger.width());
      ledger.mark_row_sample(static_cast<uint32_t>(y));
    }
  }
  // ...but the current plane does NOT hold A translated by -24.
  for (int32_t y = y0; y < y1; ++y) {
    std::memset(ledger.l_cur() + static_cast<size_t>(y) * ledger.stride(),
                0x07, ledger.width());
  }
  ScrollMove move{};
  EXPECT_FALSE(detector.detect(ledger, kBand, &move));

  // Positive control: with byte-true translated content the same hash
  // pattern verifies.
  for (int32_t y = y0; y < y1; ++y) {
    const int32_t src = y + 24;
    std::memset(ledger.l_cur() + static_cast<size_t>(y) * ledger.stride(),
                src < y1 ? static_cast<int>(src & 0x1f) : 0x07,
                ledger.width());
  }
  ASSERT_TRUE(detector.detect(ledger, kBand, &move));
  EXPECT_EQ(move.dy, -24);
}

TEST(ScrollDetectorTest, SmallBandsSkipTheVote) {
  FrameLedger ledger(ledger_config());
  ASSERT_TRUE(ledger.valid());
  ScrollDetector detector;
  ASSERT_TRUE(detector.configure(test_config()));
  ScrollMove move{};
  EXPECT_FALSE(
      detector.detect(ledger, PlutoRect{0, 0, kW, 32}, &move));
  EXPECT_FALSE(detector.detect(ledger, PlutoRect{0, 0, 64, 80}, &move));
}

// The degenerate repeating-list case (probe): EVERY row in the band is
// byte-identical (uniform list separators/backgrounds). All hashes repeat,
// so the distinctive-row filter leaves zero voters — a wholesale content
// swap of identical rows must never claim a MOVE at any offset.
TEST(ScrollDetectorTest, AllIdenticalRowsNeverVote) {
  FrameLedger ledger(ledger_config());
  ASSERT_TRUE(ledger.valid());
  TilePass pass;
  ScrollDetector detector;
  ASSERT_TRUE(detector.configure(test_config()));

  const auto uniform_frame = [&](int32_t line) {
    std::vector<uint8_t> gray(static_cast<size_t>(kW) * kH, 0xff);
    for (int32_t y = kBand.y; y < pluto::rect_bottom(kBand); ++y) {
      paint_row(&gray, y, line);  // SAME content on every band row
    }
    return gray;
  };
  const std::vector<uint8_t> frame_a = uniform_frame(5);
  ASSERT_GT(pass.run(surface_for(frame_a), nullptr, 0, &ledger), 0u);
  // Every row changes to a different (still uniform) pattern: full-band
  // damage, hashes ambiguous on both sides of the vote. (Lines 5 and 11
  // are verified distinct under paint_row's seed hash; 3 vs 9 collide.)
  const std::vector<uint8_t> frame_b = uniform_frame(11);
  ASSERT_GT(pass.run(surface_for(frame_b), &kBand, 1, &ledger), 0u);

  ScrollMove move{};
  EXPECT_FALSE(detector.detect(ledger, pass.dirty_bounds(), &move));
  EXPECT_EQ(detector.detected_moves(), 0u);
}
