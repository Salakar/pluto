#include <gtest/gtest.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <iterator>
#include <random>
#include <span>
#include <vector>

#include "renderer/convert.h"
#include "renderer/quantize.h"
#include "renderer/rect_utils.h"
#include "renderer/frame_ledger.h"
#include "renderer/kernels.h"
#include "renderer/tile_pass.h"

namespace {

using pluto::DirtyTileRecord;
using pluto::FrameLedger;
using pluto::FrameLedgerConfig;
using pluto::TilePass;
using pluto::TileStats;

FrameLedgerConfig ledger_config(uint32_t width, uint32_t height,
                                uint32_t tile_px) {
  FrameLedgerConfig config;
  config.width = width;
  config.height = height;
  config.tile_px = tile_px;
  return config;
}

PlutoSurface surface_565(const std::vector<uint16_t>& pixels, int32_t width,
                           int32_t height) {
  PlutoSurface surface{};
  surface.pixels = reinterpret_cast<const uint8_t*>(pixels.data());
  surface.stride_bytes = static_cast<size_t>(width) * sizeof(uint16_t);
  surface.width = width;
  surface.height = height;
  surface.format = kPlutoPixelFormatRgb565;
  return surface;
}

void expect_tile_stats_equal(const FrameLedger& lhs,
                             const FrameLedger& rhs) {
  ASSERT_EQ(lhs.tile_count(), rhs.tile_count());
  for (uint32_t i = 0; i < lhs.tile_count(); ++i) {
    const TileStats& a = lhs.stats_at(i);
    const TileStats& b = rhs.stats_at(i);
    EXPECT_EQ(a.changed_px, b.changed_px) << "tile=" << i;
    EXPECT_EQ(a.sad_pre_dither, b.sad_pre_dither) << "tile=" << i;
    EXPECT_EQ(a.max_diff, b.max_diff) << "tile=" << i;
    EXPECT_EQ(a.level_hist_lo, b.level_hist_lo) << "tile=" << i;
    EXPECT_EQ(a.level_hist, b.level_hist) << "tile=" << i;
    EXPECT_EQ(a.chroma_frac, b.chroma_frac) << "tile=" << i;
    EXPECT_EQ(a.motion_class, b.motion_class) << "tile=" << i;
    EXPECT_EQ(a.changed_chroma, b.changed_chroma) << "tile=" << i;
    EXPECT_EQ(a.dirty.x, b.dirty.x) << "tile=" << i;
    EXPECT_EQ(a.dirty.y, b.dirty.y) << "tile=" << i;
    EXPECT_EQ(a.dirty.width, b.dirty.width) << "tile=" << i;
    EXPECT_EQ(a.dirty.height, b.dirty.height) << "tile=" << i;
    EXPECT_EQ(a.epoch, b.epoch) << "tile=" << i;
  }
}

void paint_rect(std::vector<uint16_t>* frame, int32_t frame_width,
                const PlutoRect& rect, uint16_t value) {
  for (int32_t y = rect.y; y < rect.y + rect.height; ++y) {
    for (int32_t x = rect.x; x < rect.x + rect.width; ++x) {
      (*frame)[static_cast<size_t>(y) * frame_width + x] = value;
    }
  }
}

constexpr uint16_t kWhite565 = 0xffff;
constexpr uint16_t kBlack565 = 0x0000;

}  // namespace

// Re-target of ConvertPropertyTest: the fused pass over any candidate
// sub-rect must produce bytes identical to the fused pass over the whole
// frame, cropped. Every kernel is position-keyed, so partial updates can
// never seam.
TEST(TilePassTest, RectLocalDeterminismMatchesFullFrameCrop) {
  constexpr int32_t kWidth = 96;
  constexpr int32_t kHeight = 80;
  constexpr uint32_t kTile = 16;
  std::mt19937 rng(0x51a7e);
  std::uniform_int_distribution<uint32_t> pixel_dist(0, 0xffff);
  std::uniform_int_distribution<int32_t> x_dist(0, kWidth - 1);
  std::uniform_int_distribution<int32_t> y_dist(0, kHeight - 1);

  for (int case_index = 0; case_index < 128; ++case_index) {
    std::vector<uint16_t> src(static_cast<size_t>(kWidth) * kHeight);
    for (uint16_t& pixel : src) {
      pixel = static_cast<uint16_t>(pixel_dist(rng));
    }
    const int32_t x = x_dist(rng);
    const int32_t y = y_dist(rng);
    std::uniform_int_distribution<int32_t> w_dist(1, kWidth - x);
    std::uniform_int_distribution<int32_t> h_dist(1, kHeight - y);
    const PlutoRect hint{x, y, w_dist(rng), h_dist(rng)};

    FrameLedger full_ledger(ledger_config(kWidth, kHeight, kTile));
    FrameLedger part_ledger(ledger_config(kWidth, kHeight, kTile));
    ASSERT_TRUE(full_ledger.valid());
    ASSERT_TRUE(part_ledger.valid());

    TilePass full_pass;
    TilePass part_pass;
    const PlutoSurface surface = surface_565(src, kWidth, kHeight);
    full_pass.run(surface, nullptr, 0, &full_ledger);
    part_pass.run(surface, &hint, 1, &part_ledger);

    // Candidate tile range of the hint.
    const int32_t tile = static_cast<int32_t>(kTile);
    const int32_t tx0 = hint.x / tile;
    const int32_t ty0 = hint.y / tile;
    const int32_t tx1 = (pluto::rect_right(hint) - 1) / tile;
    const int32_t ty1 = (pluto::rect_bottom(hint) - 1) / tile;

    // Bytes inside candidate tiles are identical to the full-frame pass;
    // everything else is still the sentinel.
    for (int32_t yy = 0; yy < kHeight; ++yy) {
      for (int32_t xx = 0; xx < kWidth; ++xx) {
        const size_t offset =
            static_cast<size_t>(yy) * full_ledger.stride() + xx;
        const bool in_candidate = xx / tile >= tx0 && xx / tile <= tx1 &&
                                  yy / tile >= ty0 && yy / tile <= ty1;
        if (in_candidate) {
          ASSERT_EQ(part_ledger.l_cur()[offset], full_ledger.l_cur()[offset])
              << "case=" << case_index << " x=" << xx << " y=" << yy;
        } else {
          ASSERT_EQ(part_ledger.l_cur()[offset], pluto::kInvalidLevel5)
              << "case=" << case_index << " x=" << xx << " y=" << yy;
        }
      }
    }

    // Dirty records for candidate tiles carry identical stats to the
    // full-frame pass.
    std::vector<const TileStats*> full_stats(full_ledger.tile_count(),
                                             nullptr);
    for (const DirtyTileRecord& record : full_pass.dirty_tiles()) {
      full_stats[record.tile_idx] = &record.stats;
    }
    for (const DirtyTileRecord& record : part_pass.dirty_tiles()) {
      const TileStats* expected = full_stats[record.tile_idx];
      ASSERT_TRUE(expected != nullptr)
          << "case=" << case_index << " tile=" << record.tile_idx;
      ASSERT_EQ(record.stats.changed_px, expected->changed_px);
      ASSERT_EQ(record.stats.sad_pre_dither, expected->sad_pre_dither);
      ASSERT_EQ(record.stats.max_diff, expected->max_diff);
      ASSERT_EQ(record.stats.level_hist, expected->level_hist);
      ASSERT_EQ(record.stats.level_hist_lo, expected->level_hist_lo);
      ASSERT_EQ(record.stats.chroma_frac, expected->chroma_frac);
      ASSERT_EQ(record.stats.changed_chroma, expected->changed_chroma);
      ASSERT_EQ(record.stats.dirty.x, expected->dirty.x);
      ASSERT_EQ(record.stats.dirty.y, expected->dirty.y);
      ASSERT_EQ(record.stats.dirty.width, expected->dirty.width);
      ASSERT_EQ(record.stats.dirty.height, expected->dirty.height);
    }
  }
}

// The quantized plane must be bit-exact with the reference Ui/blue-noise
// convert path: level5_to_gray8(L_cur) == convert_rgb565_to_gray8_rect output
// for the same frame. This pins "reuse the existing kernels' math VERBATIM".
TEST(TilePassTest, QuantizedPlaneBitExactVsLegacyConvertPath) {
  constexpr int32_t kWidth = 954;  // panel width: exercises the padded stride
  constexpr int32_t kHeight = 48;
  std::mt19937 rng(0xd17e);
  std::uniform_int_distribution<uint32_t> pixel_dist(0, 0xffff);
  std::vector<uint16_t> src(static_cast<size_t>(kWidth) * kHeight);
  for (uint16_t& pixel : src) {
    pixel = static_cast<uint16_t>(pixel_dist(rng));
  }

  std::vector<uint8_t> reference(static_cast<size_t>(kWidth) * kHeight, 0);
  pluto::ConvertConfig reference_config;
  reference_config.width = kWidth;
  reference_config.height = kHeight;
  reference_config.refresh_class = kPlutoRefreshUi;
  reference_config.kernel = pluto::DitherKernel::kBlueNoise64;
  pluto::convert_rgb565_to_gray8_rect(
      src.data(), static_cast<size_t>(kWidth) * sizeof(uint16_t),
      reference.data(), static_cast<size_t>(kWidth),
      PlutoRect{0, 0, kWidth, kHeight}, reference_config);

  FrameLedger ledger(ledger_config(kWidth, kHeight, 32));
  ASSERT_TRUE(ledger.valid());
  EXPECT_EQ(ledger.stride(), size_t{960});
  TilePass pass;
  pass.run(surface_565(src, kWidth, kHeight), nullptr, 0, &ledger);

  for (int32_t y = 0; y < kHeight; ++y) {
    for (int32_t x = 0; x < kWidth; ++x) {
      const uint8_t lvl5 =
          ledger.l_cur()[static_cast<size_t>(y) * ledger.stride() + x];
      ASSERT_EQ(static_cast<int>(pluto::level5_to_gray8(lvl5)),
                static_cast<int>(reference[static_cast<size_t>(y) * kWidth + x]))
          << "x=" << x << " y=" << y;
    }
  }
}

// Diff-after-quantize: a sub-quantum RGB change (distinct RGB565 bytes, same
// luma) quantizes to identical levels and must produce ZERO dirty tiles —
// the phantom-damage class of wasted drives vanishes.
TEST(TilePassTest, PhantomDamageSubQuantumRgbChangeYieldsZeroDirtyTiles) {
  // Find two distinct RGB565 values with identical legacy luma.
  int first_for_luma[256];
  for (int& entry : first_for_luma) {
    entry = -1;
  }
  uint16_t color_a = 0;
  uint16_t color_b = 0;
  bool found = false;
  for (uint32_t v = 0; v < 65536 && !found; ++v) {
    const uint8_t luma = pluto::rgb565_luma8(static_cast<uint16_t>(v));
    if (first_for_luma[luma] < 0) {
      first_for_luma[luma] = static_cast<int>(v);
    } else {
      color_a = static_cast<uint16_t>(first_for_luma[luma]);
      color_b = static_cast<uint16_t>(v);
      found = true;
    }
  }
  ASSERT_TRUE(found);
  ASSERT_NE(color_a, color_b);
  ASSERT_EQ(pluto::rgb565_luma8(color_a), pluto::rgb565_luma8(color_b));

  constexpr int32_t kSize = 64;
  FrameLedger ledger(ledger_config(kSize, kSize, 32));
  ASSERT_TRUE(ledger.valid());
  TilePass pass;

  std::vector<uint16_t> frame(static_cast<size_t>(kSize) * kSize, color_a);
  EXPECT_GT(pass.run(surface_565(frame, kSize, kSize), nullptr, 0, &ledger),
            size_t{0});

  std::vector<uint8_t> settled(ledger.l_cur(),
                               ledger.l_cur() + ledger.l_cur_size());

  std::fill(frame.begin(), frame.end(), color_b);
  const PlutoRect full{0, 0, kSize, kSize};
  EXPECT_EQ(pass.run(surface_565(frame, kSize, kSize), &full, 1, &ledger),
            size_t{0});
  EXPECT_TRUE(pass.dirty_tiles().empty());
  EXPECT_TRUE(pluto::rect_is_empty(pass.dirty_bounds()));
  // The settled plane is untouched.
  EXPECT_EQ(std::memcmp(settled.data(), ledger.l_cur(), settled.size()), 0);
}

TEST(TilePassTest, ColorAwareDiffFindsSameLumaRgb565HueChangeExactly) {
  int first_chromatic_for_luma[256];
  for (int& entry : first_chromatic_for_luma) {
    entry = -1;
  }
  uint16_t color_a = 0;
  uint16_t color_b = 0;
  bool found = false;
  for (uint32_t value = 0; value < 65536 && !found; ++value) {
    const uint16_t color = static_cast<uint16_t>(value);
    if (!pluto::rgb565_has_chroma(color)) {
      continue;
    }
    const uint8_t luma = pluto::rgb565_luma8(color);
    if (first_chromatic_for_luma[luma] < 0) {
      first_chromatic_for_luma[luma] = static_cast<int>(value);
    } else {
      color_a = static_cast<uint16_t>(first_chromatic_for_luma[luma]);
      color_b = color;
      found = true;
    }
  }
  ASSERT_TRUE(found);
  ASSERT_NE(color_a, color_b);
  ASSERT_EQ(pluto::rgb565_luma8(color_a), pluto::rgb565_luma8(color_b));
  ASSERT_TRUE(pluto::rgb565_has_chroma(color_a));
  ASSERT_TRUE(pluto::rgb565_has_chroma(color_b));

  constexpr int32_t kSize = 32;
  FrameLedger ledger(ledger_config(kSize, kSize, 32));
  ASSERT_TRUE(ledger.valid());
  TilePass pass;
  std::vector<uint16_t> frame(static_cast<size_t>(kSize) * kSize, color_a);
  ASSERT_EQ(pass.run(surface_565(frame, kSize, kSize), nullptr, 0, &ledger,
                     nullptr, 0, true),
            1u);

  const std::vector<uint16_t> previous = frame;
  constexpr int32_t kX = 11;
  constexpr int32_t kY = 13;
  frame[static_cast<size_t>(kY) * kSize + kX] = color_b;
  const PlutoRect hint{kX, kY, 1, 1};
  ASSERT_EQ(pass.run(surface_565(frame, kSize, kSize), &hint, 1, &ledger,
                     reinterpret_cast<const uint8_t*>(previous.data()),
                     static_cast<size_t>(kSize) * sizeof(uint16_t), true),
            1u);
  const DirtyTileRecord& record = pass.dirty_tiles()[0];
  EXPECT_EQ(record.stats.changed_px, 1u);
  EXPECT_EQ(record.stats.changed_chroma, 1u);
  EXPECT_EQ(record.dirty.x, kX);
  EXPECT_EQ(record.dirty.y, kY);
  EXPECT_EQ(record.dirty.width, 1);
  EXPECT_EQ(record.dirty.height, 1);
}

TEST(TilePassTest,
     RetainedMirrorRejectMatchesFullTraversalWithIndependentRowPadding) {
  constexpr int32_t kWidth = 77;
  constexpr int32_t kHeight = 69;
  constexpr uint32_t kTile = 16;
  constexpr size_t kSourceStride = 176;
  constexpr size_t kPreviousStride = 192;
  std::vector<uint8_t> source(kSourceStride * kHeight, 0xa5);
  std::vector<uint8_t> previous(kPreviousStride * kHeight, 0x5a);
  for (int32_t y = 0; y < kHeight; ++y) {
    for (int32_t x = 0; x < kWidth; ++x) {
      const uint16_t pixel = pluto::rgb888_to_rgb565(
          static_cast<uint8_t>((x * 17 + y * 3) & 0xff),
          static_cast<uint8_t>((x * 5 + y * 19) & 0xff),
          static_cast<uint8_t>((x * 11 + y * 7) & 0xff));
      std::memcpy(source.data() + static_cast<size_t>(y) * kSourceStride +
                      static_cast<size_t>(x) * sizeof(pixel),
                  &pixel, sizeof(pixel));
      std::memcpy(previous.data() + static_cast<size_t>(y) * kPreviousStride +
                      static_cast<size_t>(x) * sizeof(pixel),
                  &pixel, sizeof(pixel));
    }
  }
  // Logical pixels match exactly, while every row's padding deliberately
  // differs. The retained-mirror proof must compare logical tile bytes only.
  PlutoSurface surface{};
  surface.pixels = source.data();
  surface.stride_bytes = kSourceStride;
  surface.width = kWidth;
  surface.height = kHeight;
  surface.format = kPlutoPixelFormatRgb565;

  FrameLedger rejected(ledger_config(kWidth, kHeight, kTile));
  FrameLedger traversed(ledger_config(kWidth, kHeight, kTile));
  ASSERT_TRUE(rejected.valid());
  ASSERT_TRUE(traversed.valid());
  TilePass rejected_pass;
  TilePass traversed_pass;
  ASSERT_EQ(rejected_pass.run(surface, nullptr, 0, &rejected), size_t{25});
  ASSERT_EQ(traversed_pass.run(surface, nullptr, 0, &traversed), size_t{25});

  EXPECT_EQ(rejected_pass.run(surface, nullptr, 0, &rejected, previous.data(),
                              kPreviousStride, /*compare_rgb565=*/true),
            size_t{0});
  EXPECT_EQ(rejected_pass.processed_tile_count(), size_t{0});
  // Invalidating derived configuration disables both external and internal
  // rejection for one pass. Since the pixels and config are unchanged, it is
  // the byte-exact full-traversal reference for every ledger side effect.
  traversed_pass.set_config(traversed_pass.config());
  EXPECT_EQ(traversed_pass.run(surface, nullptr, 0, &traversed), size_t{0});
  EXPECT_EQ(traversed_pass.processed_tile_count(), size_t{25});
  EXPECT_TRUE(rejected_pass.dirty_tiles().empty());
  EXPECT_TRUE(traversed_pass.dirty_tiles().empty());
  EXPECT_TRUE(pluto::rect_is_empty(rejected_pass.dirty_bounds()));
  EXPECT_TRUE(pluto::rect_is_empty(traversed_pass.dirty_bounds()));
  EXPECT_EQ(rejected.epoch(), traversed.epoch());
  EXPECT_EQ(std::memcmp(rejected.l_cur(), traversed.l_cur(),
                        rejected.l_cur_size()),
            0);
  EXPECT_EQ(std::memcmp(rejected.chroma_bits(), traversed.chroma_bits(),
                        rejected.chroma_stride() * kHeight),
            0);
  EXPECT_EQ(std::memcmp(rejected.row_hash_cur(), traversed.row_hash_cur(),
                        sizeof(uint32_t) * kHeight),
            0);
  EXPECT_EQ(std::memcmp(rejected.row_hash_prev(), traversed.row_hash_prev(),
                        sizeof(uint32_t) * kHeight),
            0);
  expect_tile_stats_equal(rejected, traversed);
  for (uint32_t y = 0; y < static_cast<uint32_t>(kHeight);
       y += FrameLedger::kRowSamplePeriod) {
    ASSERT_NE(rejected.row_sample(y), nullptr);
    ASSERT_NE(traversed.row_sample(y), nullptr);
    EXPECT_EQ(std::memcmp(rejected.row_sample(y), traversed.row_sample(y),
                          kWidth),
              0)
        << "y=" << y;
  }
}

TEST(TilePassTest, ImportedExactRgb565BaselineNarrowsFirstBroadReconciliation) {
  constexpr int32_t kWidth = 159;
  constexpr int32_t kHeight = 160;
  constexpr uint32_t kTile = 32;
  const size_t stride = static_cast<size_t>(kWidth) * sizeof(uint16_t);
  std::vector<uint16_t> baseline(static_cast<size_t>(kWidth) * kHeight);
  for (int32_t y = 0; y < kHeight; ++y) {
    for (int32_t x = 0; x < kWidth; ++x) {
      baseline[static_cast<size_t>(y) * kWidth + x] =
          static_cast<uint16_t>((x * 977u + y * 37u) & 0xffffu);
    }
  }

  FrameLedger source(ledger_config(kWidth, kHeight, kTile));
  TilePass source_pass;
  ASSERT_EQ(source_pass.run(surface_565(baseline, kWidth, kHeight), nullptr, 0,
                            &source),
            size_t{25});
  pluto::FrameLedgerState imported_state;
  ASSERT_TRUE(source.export_state(&imported_state));

  FrameLedger warm(ledger_config(kWidth, kHeight, kTile));
  FrameLedger localized(ledger_config(kWidth, kHeight, kTile));
  ASSERT_TRUE(warm.import_state(imported_state));
  ASSERT_TRUE(localized.import_state(imported_state));
  TilePass warm_pass;
  TilePass localized_pass;
  const std::span<const uint8_t> retained(
      reinterpret_cast<const uint8_t *>(baseline.data()),
      baseline.size() * sizeof(uint16_t));
  ASSERT_TRUE(warm_pass.admit_exact_rgb565_baseline(warm, retained, stride));

  std::vector<uint16_t> changed = baseline;
  constexpr int32_t kY = 65;
  constexpr int32_t kX0 = 17;
  constexpr int32_t kX1 = kWidth - 1;
  changed[static_cast<size_t>(kY) * kWidth + kX0] = kWhite565;
  changed[static_cast<size_t>(kY) * kWidth + kX1] = kBlack565;
  const PlutoSurface changed_surface = surface_565(changed, kWidth, kHeight);
  const uint8_t *previous = reinterpret_cast<const uint8_t *>(baseline.data());

  ASSERT_EQ(warm_pass.run(changed_surface, nullptr, 0, &warm, previous, stride,
                          /*compare_rgb565=*/true),
            size_t{2});
  EXPECT_EQ(warm_pass.processed_tile_count(), size_t{2});
  const PlutoRect exact[] = {{kX0, kY, 1, 1}, {kX1, kY, 1, 1}};
  ASSERT_EQ(localized_pass.run(changed_surface, exact, std::size(exact),
                               &localized, previous, stride,
                               /*compare_rgb565=*/true),
            size_t{2});
  EXPECT_EQ(localized_pass.processed_tile_count(), size_t{2});

  ASSERT_EQ(warm_pass.dirty_tiles().size(),
            localized_pass.dirty_tiles().size());
  for (size_t i = 0; i < warm_pass.dirty_tiles().size(); ++i) {
    const DirtyTileRecord &lhs = warm_pass.dirty_tiles()[i];
    const DirtyTileRecord &rhs = localized_pass.dirty_tiles()[i];
    EXPECT_EQ(lhs.tile_idx, rhs.tile_idx);
    EXPECT_EQ(lhs.dirty.x, rhs.dirty.x);
    EXPECT_EQ(lhs.dirty.y, rhs.dirty.y);
    EXPECT_EQ(lhs.dirty.width, rhs.dirty.width);
    EXPECT_EQ(lhs.dirty.height, rhs.dirty.height);
    EXPECT_EQ(lhs.stats.changed_px, rhs.stats.changed_px);
    EXPECT_EQ(lhs.stats.changed_chroma, rhs.stats.changed_chroma);
    EXPECT_EQ(lhs.stats.sad_pre_dither, rhs.stats.sad_pre_dither);
    EXPECT_EQ(lhs.stats.max_diff, rhs.stats.max_diff);
  }
  EXPECT_EQ(std::memcmp(warm.l_cur(), localized.l_cur(), warm.l_cur_size()), 0);
  EXPECT_EQ(std::memcmp(warm.chroma_bits(), localized.chroma_bits(),
                        warm.chroma_stride() * kHeight),
            0);
  EXPECT_EQ(std::memcmp(warm.row_hash_cur(), localized.row_hash_cur(),
                        sizeof(uint32_t) * kHeight),
            0);
  EXPECT_EQ(std::memcmp(warm.row_hash_prev(), localized.row_hash_prev(),
                        sizeof(uint32_t) * kHeight),
            0);
  expect_tile_stats_equal(warm, localized);
}

TEST(TilePassTest,
     ExactRgb565BaselineRejectsBadShapeAndInvalidatesConservatively) {
  constexpr int32_t kWidth = 128;
  constexpr int32_t kHeight = 96;
  constexpr uint32_t kTile = 32;
  const size_t stride = static_cast<size_t>(kWidth) * sizeof(uint16_t);
  std::vector<uint16_t> baseline(static_cast<size_t>(kWidth) * kHeight,
                                 0xf800u);
  const std::span<const uint8_t> retained(
      reinterpret_cast<const uint8_t *>(baseline.data()),
      baseline.size() * sizeof(uint16_t));

  FrameLedger ledger(ledger_config(kWidth, kHeight, kTile));
  TilePass source_pass;
  ASSERT_EQ(source_pass.run(surface_565(baseline, kWidth, kHeight), nullptr, 0,
                            &ledger),
            size_t{12});

  TilePass malformed_pass;
  EXPECT_FALSE(malformed_pass.admit_exact_rgb565_baseline(
      ledger, retained.first(retained.size() - 1), stride));
  EXPECT_FALSE(malformed_pass.admit_exact_rgb565_baseline(
      ledger, retained, stride + sizeof(uint16_t)));
  FrameLedger invalid;
  EXPECT_FALSE(
      malformed_pass.admit_exact_rgb565_baseline(invalid, retained, stride));
  EXPECT_EQ(malformed_pass.run(surface_565(baseline, kWidth, kHeight), nullptr,
                               0, &ledger, retained.data(), stride,
                               /*compare_rgb565=*/true),
            size_t{0});
  EXPECT_EQ(malformed_pass.processed_tile_count(), size_t{12});

  TilePass rolled_back_pass;
  ASSERT_TRUE(
      rolled_back_pass.admit_exact_rgb565_baseline(ledger, retained, stride));
  rolled_back_pass.invalidate_exact_rgb565_baseline();
  EXPECT_EQ(rolled_back_pass.run(surface_565(baseline, kWidth, kHeight),
                                 nullptr, 0, &ledger, retained.data(), stride,
                                 /*compare_rgb565=*/true),
            size_t{0});
  EXPECT_EQ(rolled_back_pass.processed_tile_count(), size_t{12});
}

TEST(TilePassTest,
     InternalRgb565BaselineMatchesFullTraversalForPaddedEdge96DrawBack) {
  constexpr int32_t kWidth = 159;
  constexpr int32_t kHeight = 160;
  constexpr uint32_t kTile = 32;
  constexpr size_t kStride = kWidth * sizeof(uint16_t) + 22;
  constexpr PlutoRect kEdgeRect{63, 64, 96, 96};
  std::vector<uint8_t> source(kStride * kHeight, 0xa5);
  for (int32_t y = 0; y < kHeight; ++y) {
    for (int32_t x = 0; x < kWidth; ++x) {
      const uint16_t pixel = static_cast<uint16_t>(
          ((x * 1297u) ^ (y * 977u) ^ ((x + y) * 31u)) & 0xffffu);
      std::memcpy(source.data() + static_cast<size_t>(y) * kStride +
                      static_cast<size_t>(x) * sizeof(pixel),
                  &pixel, sizeof(pixel));
    }
  }
  const std::vector<uint8_t> original = source;
  PlutoSurface surface{};
  surface.pixels = source.data();
  surface.stride_bytes = kStride;
  surface.width = kWidth;
  surface.height = kHeight;
  surface.format = kPlutoPixelFormatRgb565;

  FrameLedger narrowed(ledger_config(kWidth, kHeight, kTile));
  FrameLedger traversed(ledger_config(kWidth, kHeight, kTile));
  TilePass narrowed_pass;
  TilePass traversed_pass;
  ASSERT_EQ(narrowed_pass.run(surface, nullptr, 0, &narrowed), size_t{25});
  ASSERT_EQ(traversed_pass.run(surface, nullptr, 0, &traversed), size_t{25});

  const auto compare_outputs = [&] {
    ASSERT_EQ(narrowed_pass.dirty_tiles().size(),
              traversed_pass.dirty_tiles().size());
    for (size_t i = 0; i < narrowed_pass.dirty_tiles().size(); ++i) {
      const DirtyTileRecord& a = narrowed_pass.dirty_tiles()[i];
      const DirtyTileRecord& b = traversed_pass.dirty_tiles()[i];
      EXPECT_EQ(a.tile_idx, b.tile_idx);
      EXPECT_EQ(a.dirty.x, b.dirty.x);
      EXPECT_EQ(a.dirty.y, b.dirty.y);
      EXPECT_EQ(a.dirty.width, b.dirty.width);
      EXPECT_EQ(a.dirty.height, b.dirty.height);
    }
    EXPECT_EQ(std::memcmp(narrowed.l_cur(), traversed.l_cur(),
                          narrowed.l_cur_size()),
              0);
    EXPECT_EQ(std::memcmp(narrowed.chroma_bits(), traversed.chroma_bits(),
                          narrowed.chroma_stride() * kHeight),
              0);
    EXPECT_EQ(std::memcmp(narrowed.row_hash_cur(), traversed.row_hash_cur(),
                          sizeof(uint32_t) * kHeight),
              0);
    EXPECT_EQ(std::memcmp(narrowed.row_hash_prev(),
                          traversed.row_hash_prev(),
                          sizeof(uint32_t) * kHeight),
              0);
    expect_tile_stats_equal(narrowed, traversed);
  };

  for (int32_t y = kEdgeRect.y; y < kEdgeRect.y + kEdgeRect.height; ++y) {
    for (int32_t x = kEdgeRect.x; x < kEdgeRect.x + kEdgeRect.width; ++x) {
      const uint16_t white = kWhite565;
      std::memcpy(source.data() + static_cast<size_t>(y) * kStride +
                      static_cast<size_t>(x) * sizeof(white),
                  &white, sizeof(white));
    }
  }
  ASSERT_EQ(narrowed_pass.run(surface, nullptr, 0, &narrowed), size_t{12});
  EXPECT_EQ(narrowed_pass.processed_tile_count(), size_t{12});
  traversed_pass.set_config(traversed_pass.config());
  ASSERT_EQ(traversed_pass.run(surface, nullptr, 0, &traversed), size_t{12});
  EXPECT_EQ(traversed_pass.processed_tile_count(), size_t{25});
  compare_outputs();

  source = original;
  surface.pixels = source.data();
  ASSERT_EQ(narrowed_pass.run(surface, nullptr, 0, &narrowed), size_t{12});
  EXPECT_EQ(narrowed_pass.processed_tile_count(), size_t{12});
  traversed_pass.set_config(traversed_pass.config());
  ASSERT_EQ(traversed_pass.run(surface, nullptr, 0, &traversed), size_t{12});
  EXPECT_EQ(traversed_pass.processed_tile_count(), size_t{25});
  compare_outputs();

  for (int32_t y = 0; y < kHeight; ++y) {
    EXPECT_EQ(std::memcmp(source.data() + static_cast<size_t>(y) * kStride +
                              kWidth * sizeof(uint16_t),
                          original.data() + static_cast<size_t>(y) * kStride +
                              kWidth * sizeof(uint16_t),
                          kStride - kWidth * sizeof(uint16_t)),
              0)
        << "padding y=" << y;
  }
}

TEST(TilePassTest,
     InternalRgb565BaselineNarrowsThinStrokeAndContainedDrawBackExactly) {
  constexpr int32_t kWidth = 127;
  constexpr int32_t kHeight = 97;
  constexpr uint32_t kTile = 32;
  constexpr PlutoRect kStroke{30, 31, 66, 3};
  std::vector<uint16_t> source(static_cast<size_t>(kWidth) * kHeight,
                               kWhite565);
  FrameLedger narrowed(ledger_config(kWidth, kHeight, kTile));
  FrameLedger traversed(ledger_config(kWidth, kHeight, kTile));
  TilePass narrowed_pass;
  TilePass traversed_pass;
  ASSERT_EQ(narrowed_pass.run(surface_565(source, kWidth, kHeight), nullptr, 0,
                              &narrowed),
            size_t{16});
  ASSERT_EQ(traversed_pass.run(surface_565(source, kWidth, kHeight), nullptr,
                               0, &traversed),
            size_t{16});

  paint_rect(&source, kWidth, kStroke, kBlack565);
  ASSERT_EQ(narrowed_pass.run(surface_565(source, kWidth, kHeight), nullptr, 0,
                              &narrowed),
            size_t{6});
  EXPECT_EQ(narrowed_pass.processed_tile_count(), size_t{6});
  traversed_pass.set_config(traversed_pass.config());
  ASSERT_EQ(traversed_pass.run(surface_565(source, kWidth, kHeight), nullptr,
                               0, &traversed),
            size_t{6});
  EXPECT_EQ(traversed_pass.processed_tile_count(), size_t{16});
  EXPECT_EQ(std::memcmp(narrowed.l_cur(), traversed.l_cur(),
                        narrowed.l_cur_size()),
            0);
  EXPECT_EQ(std::memcmp(narrowed.chroma_bits(), traversed.chroma_bits(),
                        narrowed.chroma_stride() * kHeight),
            0);
  expect_tile_stats_equal(narrowed, traversed);

  paint_rect(&source, kWidth, kStroke, kWhite565);
  ASSERT_EQ(narrowed_pass.run(surface_565(source, kWidth, kHeight), nullptr, 0,
                              &narrowed),
            size_t{6});
  EXPECT_EQ(narrowed_pass.processed_tile_count(), size_t{6});
  traversed_pass.set_config(traversed_pass.config());
  ASSERT_EQ(traversed_pass.run(surface_565(source, kWidth, kHeight), nullptr,
                               0, &traversed),
            size_t{6});
  EXPECT_EQ(std::memcmp(narrowed.l_cur(), traversed.l_cur(),
                        narrowed.l_cur_size()),
            0);
  EXPECT_EQ(std::memcmp(narrowed.chroma_bits(), traversed.chroma_bits(),
                        narrowed.chroma_stride() * kHeight),
            0);
  expect_tile_stats_equal(narrowed, traversed);
}

TEST(TilePassTest, InternalRgb565BaselineCannotCrossAFormatChange) {
  constexpr int32_t kSize = 64;
  FrameLedger ledger(ledger_config(kSize, kSize, 32));
  TilePass pass;
  std::vector<uint16_t> black(static_cast<size_t>(kSize) * kSize,
                              kBlack565);
  ASSERT_EQ(pass.run(surface_565(black, kSize, kSize), nullptr, 0, &ledger),
            size_t{4});

  std::vector<uint8_t> white_xrgb(static_cast<size_t>(kSize) * kSize * 4u,
                                  0xffu);
  PlutoSurface xrgb{};
  xrgb.pixels = white_xrgb.data();
  xrgb.stride_bytes = static_cast<size_t>(kSize) * 4u;
  xrgb.width = kSize;
  xrgb.height = kSize;
  xrgb.format = kPlutoPixelFormatXrgb8888;
  ASSERT_EQ(pass.run(xrgb, nullptr, 0, &ledger), size_t{4});

  // The raw RGB565 bytes equal the old internal baseline, but the intervening
  // XRGB pass changed every derived level. A safe fallback must re-traverse.
  ASSERT_EQ(pass.run(surface_565(black, kSize, kSize), nullptr, 0, &ledger),
            size_t{4});
  EXPECT_EQ(pass.processed_tile_count(), size_t{4});
}

TEST(TilePassTest,
     RetainedMirrorRejectDoesNotHideLateSameLumaChromaChange) {
  int first_chromatic_for_luma[256];
  for (int& entry : first_chromatic_for_luma) {
    entry = -1;
  }
  uint16_t color_a = 0;
  uint16_t color_b = 0;
  bool found = false;
  for (uint32_t value = 0; value < 65536 && !found; ++value) {
    const uint16_t color = static_cast<uint16_t>(value);
    if (!pluto::rgb565_has_chroma(color)) {
      continue;
    }
    const uint8_t luma = pluto::rgb565_luma8(color);
    if (first_chromatic_for_luma[luma] < 0) {
      first_chromatic_for_luma[luma] = static_cast<int>(value);
    } else {
      color_a = static_cast<uint16_t>(first_chromatic_for_luma[luma]);
      color_b = color;
      found = true;
    }
  }
  ASSERT_TRUE(found);
  ASSERT_NE(color_a, color_b);
  ASSERT_EQ(pluto::rgb565_luma8(color_a),
            pluto::rgb565_luma8(color_b));

  constexpr int32_t kSize = 64;
  constexpr int32_t kX = kSize - 1;
  constexpr int32_t kY = kSize - 1;
  FrameLedger ledger(ledger_config(kSize, kSize, 32));
  ASSERT_TRUE(ledger.valid());
  TilePass pass;
  std::vector<uint16_t> frame(static_cast<size_t>(kSize) * kSize, color_a);
  ASSERT_EQ(pass.run(surface_565(frame, kSize, kSize), nullptr, 0, &ledger),
            4u);
  const std::vector<uint16_t> previous = frame;
  frame[static_cast<size_t>(kY) * kSize + kX] = color_b;

  // The mismatch is the final pixel of the final candidate tile: the fast
  // comparison must consume every earlier equal row/tile, then fall through
  // to the existing raw-color-aware path and retain the one-pixel truth.
  ASSERT_EQ(pass.run(surface_565(frame, kSize, kSize), nullptr, 0, &ledger,
                     reinterpret_cast<const uint8_t*>(previous.data()),
                     static_cast<size_t>(kSize) * sizeof(uint16_t), true),
            1u);
  ASSERT_EQ(pass.dirty_tiles().size(), size_t{1});
  const DirtyTileRecord& record = pass.dirty_tiles()[0];
  EXPECT_EQ(record.tile_idx, 3u);
  EXPECT_EQ(record.stats.changed_px, 1u);
  EXPECT_EQ(record.stats.changed_chroma, 1u);
  EXPECT_EQ(record.dirty.x, kX);
  EXPECT_EQ(record.dirty.y, kY);
  EXPECT_EQ(record.dirty.width, 1);
  EXPECT_EQ(record.dirty.height, 1);
}

TEST(TilePassTest,
     BroadRetainedMirrorRowAndColumnNarrowingMatchesExactReferences) {
  constexpr int32_t kWidth = 159;
  constexpr int32_t kHeight = 160;
  constexpr uint32_t kTile = 32;
  constexpr size_t kSourceStride = kWidth * sizeof(uint16_t) + 16;
  constexpr size_t kPreviousStride = kWidth * sizeof(uint16_t) + 32;
  std::vector<uint8_t> source(kSourceStride * kHeight, 0xa5);
  std::vector<uint8_t> previous(kPreviousStride * kHeight, 0x5a);

  uint16_t same_luma_a = 0;
  uint16_t same_luma_b = 0;
  int first_chromatic_for_luma[256];
  std::fill_n(first_chromatic_for_luma, 256, -1);
  for (uint32_t value = 0; value < 65536 && same_luma_b == 0; ++value) {
    const uint16_t color = static_cast<uint16_t>(value);
    if (!pluto::rgb565_has_chroma(color)) {
      continue;
    }
    const uint8_t luma = pluto::rgb565_luma8(color);
    if (first_chromatic_for_luma[luma] < 0) {
      first_chromatic_for_luma[luma] = static_cast<int>(value);
    } else if (first_chromatic_for_luma[luma] != static_cast<int>(value)) {
      same_luma_a =
          static_cast<uint16_t>(first_chromatic_for_luma[luma]);
      same_luma_b = color;
    }
  }
  ASSERT_NE(same_luma_b, 0);
  ASSERT_EQ(pluto::rgb565_luma8(same_luma_a),
            pluto::rgb565_luma8(same_luma_b));

  for (int32_t y = 0; y < kHeight; ++y) {
    for (int32_t x = 0; x < kWidth; ++x) {
      uint16_t pixel = static_cast<uint16_t>((x * 977 + y * 37) & 0xffff);
      if ((x == 17 && y == 65)) {
        pixel = kBlack565;
      } else if (x == kWidth - 1 && y == 65) {
        pixel = same_luma_a;
      }
      std::memcpy(source.data() + static_cast<size_t>(y) * kSourceStride +
                      static_cast<size_t>(x) * sizeof(pixel),
                  &pixel, sizeof(pixel));
      std::memcpy(previous.data() +
                      static_cast<size_t>(y) * kPreviousStride +
                      static_cast<size_t>(x) * sizeof(pixel),
                  &pixel, sizeof(pixel));
    }
  }
  PlutoSurface surface{};
  surface.pixels = source.data();
  surface.stride_bytes = kSourceStride;
  surface.width = kWidth;
  surface.height = kHeight;
  surface.format = kPlutoPixelFormatRgb565;

  FrameLedger broad(ledger_config(kWidth, kHeight, kTile));
  FrameLedger localized(ledger_config(kWidth, kHeight, kTile));
  FrameLedger traversed(ledger_config(kWidth, kHeight, kTile));
  TilePass broad_pass;
  TilePass localized_pass;
  TilePass traversed_pass;
  ASSERT_EQ(broad_pass.run(surface, nullptr, 0, &broad), size_t{25});
  ASSERT_EQ(localized_pass.run(surface, nullptr, 0, &localized), size_t{25});
  ASSERT_EQ(traversed_pass.run(surface, nullptr, 0, &traversed), size_t{25});
  EXPECT_EQ(broad_pass.processed_tile_count(), size_t{25});

  const uint16_t white = kWhite565;
  std::memcpy(source.data() + static_cast<size_t>(65) * kSourceStride +
                  static_cast<size_t>(17) * sizeof(white),
              &white, sizeof(white));
  std::memcpy(source.data() + static_cast<size_t>(65) * kSourceStride +
                  static_cast<size_t>(kWidth - 1) * sizeof(same_luma_b),
              &same_luma_b, sizeof(same_luma_b));

  ASSERT_EQ(broad_pass.run(surface, nullptr, 0, &broad, previous.data(),
                           kPreviousStride, /*compare_rgb565=*/true),
            size_t{2});
  EXPECT_EQ(broad_pass.processed_tile_count(), size_t{2});
  const PlutoRect changed_tile_rows[] = {
      {0, 64, kWidth, 32},
  };
  ASSERT_EQ(localized_pass.run(surface, changed_tile_rows, 1, &localized,
                               previous.data(), kPreviousStride,
                               /*compare_rgb565=*/true),
            size_t{2});
  EXPECT_EQ(localized_pass.processed_tile_count(), size_t{5});
  // Re-setting even the same config deliberately invalidates raw rejection,
  // producing a full-traversal reference with identical pixels and mirror.
  traversed_pass.set_config(traversed_pass.config());
  ASSERT_EQ(traversed_pass.run(surface, nullptr, 0, &traversed,
                               previous.data(), kPreviousStride,
                               /*compare_rgb565=*/true),
            size_t{2});
  EXPECT_EQ(traversed_pass.processed_tile_count(), size_t{25});

  ASSERT_EQ(broad_pass.dirty_tiles().size(),
            localized_pass.dirty_tiles().size());
  for (size_t i = 0; i < broad_pass.dirty_tiles().size(); ++i) {
    const DirtyTileRecord& lhs = broad_pass.dirty_tiles()[i];
    const DirtyTileRecord& rhs = localized_pass.dirty_tiles()[i];
    EXPECT_EQ(lhs.tile_idx, rhs.tile_idx);
    EXPECT_EQ(lhs.dirty.x, rhs.dirty.x);
    EXPECT_EQ(lhs.dirty.y, rhs.dirty.y);
    EXPECT_EQ(lhs.dirty.width, rhs.dirty.width);
    EXPECT_EQ(lhs.dirty.height, rhs.dirty.height);
    EXPECT_EQ(lhs.stats.changed_px, rhs.stats.changed_px);
    EXPECT_EQ(lhs.stats.sad_pre_dither, rhs.stats.sad_pre_dither);
    EXPECT_EQ(lhs.stats.max_diff, rhs.stats.max_diff);
    EXPECT_EQ(lhs.stats.level_hist, rhs.stats.level_hist);
    EXPECT_EQ(lhs.stats.chroma_frac, rhs.stats.chroma_frac);
    EXPECT_EQ(lhs.stats.changed_chroma, rhs.stats.changed_chroma);
    EXPECT_EQ(lhs.stats.epoch, rhs.stats.epoch);
  }
  EXPECT_EQ(std::memcmp(broad.l_cur(), localized.l_cur(), broad.l_cur_size()),
            0);
  EXPECT_EQ(std::memcmp(broad.chroma_bits(), localized.chroma_bits(),
                        broad.chroma_stride() * kHeight),
            0);
  EXPECT_EQ(std::memcmp(broad.row_hash_cur(), localized.row_hash_cur(),
                        sizeof(uint32_t) * kHeight),
            0);
  expect_tile_stats_equal(broad, localized);
  EXPECT_EQ(std::memcmp(broad.l_cur(), traversed.l_cur(), broad.l_cur_size()),
            0);
  EXPECT_EQ(std::memcmp(broad.chroma_bits(), traversed.chroma_bits(),
                        broad.chroma_stride() * kHeight),
            0);
  EXPECT_EQ(std::memcmp(broad.row_hash_cur(), traversed.row_hash_cur(),
                        sizeof(uint32_t) * kHeight),
            0);
  EXPECT_EQ(std::memcmp(broad.row_hash_prev(), traversed.row_hash_prev(),
                        sizeof(uint32_t) * kHeight),
            0);
  expect_tile_stats_equal(broad, traversed);
  for (uint32_t y = 0; y < static_cast<uint32_t>(kHeight);
       y += FrameLedger::kRowSamplePeriod) {
    ASSERT_NE(broad.row_sample(y), nullptr) << "y=" << y;
    ASSERT_NE(traversed.row_sample(y), nullptr) << "y=" << y;
    EXPECT_EQ(std::memcmp(broad.row_sample(y), traversed.row_sample(y), kWidth),
              0)
        << "y=" << y;
  }
}

TEST(TilePassTest, RetainedMirrorRejectRebaselinesAfterConfigChange) {
  constexpr int32_t kSize = 128;
  pluto::RendererConfig high_floor;
  high_floor.chroma_floor = 255;
  pluto::RendererConfig low_floor = high_floor;
  low_floor.chroma_floor = 0;

  FrameLedger ledger(ledger_config(kSize, kSize, 32));
  ASSERT_TRUE(ledger.valid());
  TilePass pass(high_floor);
  std::vector<uint16_t> frame(static_cast<size_t>(kSize) * kSize, 0xf800u);
  const PlutoSurface surface = surface_565(frame, kSize, kSize);
  ASSERT_EQ(pass.run(surface, nullptr, 0, &ledger), size_t{16});
  EXPECT_FALSE(ledger.chroma_at(0, 0));

  pass.set_config(low_floor);
  ASSERT_EQ(pass.run(surface, nullptr, 0, &ledger,
                     reinterpret_cast<const uint8_t*>(frame.data()),
                     static_cast<size_t>(kSize) * sizeof(uint16_t),
                     /*compare_rgb565=*/true),
            size_t{0});
  EXPECT_EQ(pass.processed_tile_count(), size_t{16});
  EXPECT_TRUE(ledger.chroma_at(0, 0));
}

TEST(TilePassTest, RetainedMirrorRejectRebaselinesAfterLedgerSwap) {
  constexpr int32_t kSize = 128;
  constexpr uint32_t kTile = 32;
  std::vector<uint16_t> frame(static_cast<size_t>(kSize) * kSize, 0xf800u);
  const PlutoSurface surface = surface_565(frame, kSize, kSize);
  const uint8_t* previous = reinterpret_cast<const uint8_t*>(frame.data());
  const size_t previous_stride = static_cast<size_t>(kSize) * sizeof(uint16_t);

  FrameLedger first(ledger_config(kSize, kSize, kTile));
  FrameLedger replacement(ledger_config(kSize, kSize, kTile));
  ASSERT_TRUE(first.valid());
  ASSERT_TRUE(replacement.valid());
  TilePass pass;
  ASSERT_EQ(pass.run(surface, nullptr, 0, &first), size_t{16});

  // The exact retained mirror describes the pixels, but not the replacement
  // ledger's still-invalid derived planes. A ledger identity change must
  // force one complete rebaseline before raw equality may reject again.
  ASSERT_EQ(pass.run(surface, nullptr, 0, &replacement, previous,
                     previous_stride, /*compare_rgb565=*/true),
            size_t{16});
  EXPECT_EQ(pass.processed_tile_count(), size_t{16});
  EXPECT_NE(replacement.l_cur()[0], pluto::kInvalidLevel5);
  EXPECT_TRUE(replacement.chroma_at(0, 0));

  // Once the replacement is established, an identical broad frame rejects
  // every tile while preserving its planes.
  ASSERT_EQ(pass.run(surface, nullptr, 0, &replacement, previous,
                     previous_stride, /*compare_rgb565=*/true),
            size_t{0});
  EXPECT_EQ(pass.processed_tile_count(), size_t{0});
  EXPECT_NE(replacement.l_cur()[0], pluto::kInvalidLevel5);
  EXPECT_TRUE(replacement.chroma_at(0, 0));
}

TEST(TilePassTest, ChangedChromaTracksOnePixelColorDrawAndErase) {
  constexpr int32_t kSize = 32;
  constexpr int32_t kX = 9;
  constexpr int32_t kY = 17;
  const uint16_t red = pluto::rgb888_to_rgb565(255, 0, 0);
  FrameLedger ledger(ledger_config(kSize, kSize, 32));
  ASSERT_TRUE(ledger.valid());
  TilePass pass;
  std::vector<uint16_t> frame(static_cast<size_t>(kSize) * kSize, kWhite565);
  ASSERT_EQ(pass.run(surface_565(frame, kSize, kSize), nullptr, 0, &ledger,
                     nullptr, 0, true),
            1u);

  std::vector<uint16_t> previous = frame;
  frame[static_cast<size_t>(kY) * kSize + kX] = red;
  const PlutoRect hint{kX, kY, 1, 1};
  ASSERT_EQ(pass.run(surface_565(frame, kSize, kSize), &hint, 1, &ledger,
                     reinterpret_cast<const uint8_t*>(previous.data()),
                     static_cast<size_t>(kSize) * sizeof(uint16_t), true),
            1u);
  {
    const DirtyTileRecord& record = pass.dirty_tiles()[0];
    EXPECT_EQ(record.stats.changed_px, 1u);
    EXPECT_EQ(record.stats.changed_chroma, 1u);
    // Whole-current-tile density intentionally stays independent: one of
    // 1024 chromatic pixels rounds to zero, but the transition still is color.
    EXPECT_EQ(record.stats.chroma_frac, 0u);
    EXPECT_EQ(record.dirty.x, kX);
    EXPECT_EQ(record.dirty.y, kY);
    EXPECT_EQ(record.dirty.width, 1);
    EXPECT_EQ(record.dirty.height, 1);
  }

  previous = frame;
  frame[static_cast<size_t>(kY) * kSize + kX] = kWhite565;
  ASSERT_EQ(pass.run(surface_565(frame, kSize, kSize), &hint, 1, &ledger,
                     reinterpret_cast<const uint8_t*>(previous.data()),
                     static_cast<size_t>(kSize) * sizeof(uint16_t), true),
            1u);
  const DirtyTileRecord& erased = pass.dirty_tiles()[0];
  EXPECT_EQ(erased.stats.changed_px, 1u);
  EXPECT_EQ(erased.stats.changed_chroma, 1u);
  EXPECT_EQ(erased.stats.chroma_frac, 0u);
  EXPECT_EQ(erased.dirty.x, kX);
  EXPECT_EQ(erased.dirty.y, kY);
  EXPECT_EQ(erased.dirty.width, 1);
  EXPECT_EQ(erased.dirty.height, 1);
}

TEST(TilePassTest, UnknownPriorConservativelyTreatsWhiteAsColorSensitive) {
  constexpr int32_t kSize = 32;
  FrameLedger ledger(ledger_config(kSize, kSize, 32));
  ASSERT_TRUE(ledger.valid());
  // Model a warm handoff that can seed settled luma but cannot recover the
  // outgoing app's RGB hue. White may therefore be erasing old color pigment.
  ledger.fill_levels(pluto::kWhiteLevel5);
  TilePass pass;
  std::vector<uint16_t> frame(static_cast<size_t>(kSize) * kSize, kWhite565);
  ASSERT_EQ(pass.run(surface_565(frame, kSize, kSize), nullptr, 0, &ledger,
                     nullptr, 0, true),
            1u);
  const DirtyTileRecord& record = pass.dirty_tiles()[0];
  EXPECT_EQ(record.stats.changed_px, kSize * kSize);
  EXPECT_EQ(record.stats.chroma_frac, 0u);
  EXPECT_EQ(record.stats.changed_chroma, 1u);
}

TEST(TilePassTest, GrayDamageBesideStaticColorIsNotChangedChroma) {
  constexpr int32_t kSize = 32;
  const uint16_t red = pluto::rgb888_to_rgb565(255, 0, 0);
  FrameLedger ledger(ledger_config(kSize, kSize, 32));
  ASSERT_TRUE(ledger.valid());
  TilePass pass;
  std::vector<uint16_t> frame(static_cast<size_t>(kSize) * kSize, kWhite565);
  paint_rect(&frame, kSize, PlutoRect{2, 2, 8, 8}, red);
  ASSERT_EQ(pass.run(surface_565(frame, kSize, kSize), nullptr, 0, &ledger,
                     nullptr, 0, true),
            1u);

  const std::vector<uint16_t> previous = frame;
  constexpr int32_t kX = 24;
  constexpr int32_t kY = 24;
  frame[static_cast<size_t>(kY) * kSize + kX] = kBlack565;
  const PlutoRect hint{kX, kY, 1, 1};
  ASSERT_EQ(pass.run(surface_565(frame, kSize, kSize), &hint, 1, &ledger,
                     reinterpret_cast<const uint8_t*>(previous.data()),
                     static_cast<size_t>(kSize) * sizeof(uint16_t), true),
            1u);
  const DirtyTileRecord& record = pass.dirty_tiles()[0];
  EXPECT_EQ(record.stats.changed_px, 1u);
  EXPECT_EQ(record.stats.changed_chroma, 0u);
  EXPECT_GT(record.stats.chroma_frac, 0u);
  EXPECT_EQ(record.dirty.x, kX);
  EXPECT_EQ(record.dirty.y, kY);
  EXPECT_EQ(record.dirty.width, 1);
  EXPECT_EQ(record.dirty.height, 1);
}

// Tile-stats golden on a synthetic pattern: exact post-quantize rects,
// counts, pre-dither significance, histogram presence bits, epochs.
TEST(TilePassTest, StatsGoldenBlackSquaresOnWhite) {
  constexpr int32_t kSize = 64;
  FrameLedger ledger(ledger_config(kSize, kSize, 32));
  ASSERT_TRUE(ledger.valid());
  ledger.fill_levels(pluto::kWhiteLevel5);  // settled white baseline
  TilePass pass;

  // Pass 1: one 10x10 black square inside tile (0,0).
  std::vector<uint16_t> frame(static_cast<size_t>(kSize) * kSize, kWhite565);
  paint_rect(&frame, kSize, PlutoRect{5, 5, 10, 10}, kBlack565);
  ASSERT_EQ(pass.run(surface_565(frame, kSize, kSize), nullptr, 0, &ledger),
            size_t{1});
  {
    const DirtyTileRecord& record = pass.dirty_tiles()[0];
    EXPECT_EQ(record.tile_idx, 0u);
    EXPECT_EQ(record.dirty.x, 5);
    EXPECT_EQ(record.dirty.y, 5);
    EXPECT_EQ(record.dirty.width, 10);
    EXPECT_EQ(record.dirty.height, 10);
    EXPECT_EQ(record.stats.changed_px, 100);
    EXPECT_EQ(record.stats.sad_pre_dither, 100 * 255);
    EXPECT_EQ(static_cast<int>(record.stats.max_diff), 255);
    // Black (level 0) and white (level 30) present.
    EXPECT_EQ(record.stats.level_hist,
              static_cast<uint16_t>((1u << 0) | (1u << 15)));
    // Rails {0, 10, 20, 30} presence bits: 0 and 30.
    EXPECT_EQ(static_cast<int>(record.stats.level_hist_lo), 0b1001);
    EXPECT_EQ(static_cast<int>(record.stats.chroma_frac), 0);
    EXPECT_EQ(record.stats.epoch, 1u);
    const PlutoRect bounds = pass.dirty_bounds();
    EXPECT_EQ(bounds.x, 5);
    EXPECT_EQ(bounds.y, 5);
    EXPECT_EQ(bounds.width, 10);
    EXPECT_EQ(bounds.height, 10);
  }

  // Pass 2: keep square 1, add a 10x10 square crossing all four tiles at
  // (28,28). Over-reported full-frame hint; exact rects come out.
  paint_rect(&frame, kSize, PlutoRect{28, 28, 10, 10}, kBlack565);
  ASSERT_EQ(pass.run(surface_565(frame, kSize, kSize), nullptr, 0, &ledger),
            size_t{4});
  const struct {
    uint32_t tile_idx;
    PlutoRect dirty;
    uint16_t changed;
  } expected[4] = {
      {0, {28, 28, 4, 4}, 16},
      {1, {32, 28, 6, 4}, 24},
      {2, {28, 32, 4, 6}, 24},
      {3, {32, 32, 6, 6}, 36},
  };
  for (int i = 0; i < 4; ++i) {
    const DirtyTileRecord& record = pass.dirty_tiles()[i];
    ASSERT_EQ(record.tile_idx, expected[i].tile_idx) << "i=" << i;
    ASSERT_EQ(record.dirty.x, expected[i].dirty.x) << "i=" << i;
    ASSERT_EQ(record.dirty.y, expected[i].dirty.y) << "i=" << i;
    ASSERT_EQ(record.dirty.width, expected[i].dirty.width) << "i=" << i;
    ASSERT_EQ(record.dirty.height, expected[i].dirty.height) << "i=" << i;
    ASSERT_EQ(record.stats.changed_px, expected[i].changed) << "i=" << i;
    ASSERT_EQ(record.stats.sad_pre_dither,
              static_cast<uint16_t>(expected[i].changed * 255u))
        << "i=" << i;
    ASSERT_EQ(record.stats.epoch, 2u) << "i=" << i;
  }
  // Ledger stats mirror the records.
  EXPECT_EQ(ledger.stats_at(3).changed_px, 36);
  EXPECT_EQ(ledger.stats_at(3).epoch, 2u);
  const PlutoRect bounds = pass.dirty_bounds();
  EXPECT_EQ(bounds.x, 28);
  EXPECT_EQ(bounds.y, 28);
  EXPECT_EQ(bounds.width, 10);
  EXPECT_EQ(bounds.height, 10);
}

TEST(TilePassTest, ChromaBitplaneAndFractionTrackContent) {
  constexpr int32_t kSize = 32;
  FrameLedger ledger(ledger_config(kSize, kSize, 32));
  ASSERT_TRUE(ledger.valid());
  TilePass pass;

  const uint16_t red = pluto::rgb888_to_rgb565(255, 0, 0);
  std::vector<uint16_t> frame(static_cast<size_t>(kSize) * kSize, red);
  ASSERT_EQ(pass.run(surface_565(frame, kSize, kSize), nullptr, 0, &ledger),
            size_t{1});
  EXPECT_EQ(static_cast<int>(pass.dirty_tiles()[0].stats.chroma_frac), 255);
  EXPECT_EQ(pass.dirty_tiles()[0].stats.changed_chroma, 1u);
  EXPECT_TRUE(ledger.chroma_at(0, 0));
  EXPECT_TRUE(ledger.chroma_at(31, 31));

  std::fill(frame.begin(), frame.end(), kWhite565);
  ASSERT_EQ(pass.run(surface_565(frame, kSize, kSize), nullptr, 0, &ledger),
            size_t{1});
  EXPECT_EQ(static_cast<int>(pass.dirty_tiles()[0].stats.chroma_frac), 0);
  EXPECT_EQ(pass.dirty_tiles()[0].stats.changed_chroma, 1u);
  EXPECT_FALSE(ledger.chroma_at(0, 0));
  EXPECT_FALSE(ledger.chroma_at(31, 31));
}

// Row-hash sanity: hashes are whole-row functions of the quantized plane, so
// content translated by dy rows re-appears as the previous pass's hashes
// shifted by dy — the signal the scroll detector votes on.
TEST(TilePassTest, RowHashesTrackVerticalTranslation) {
  constexpr int32_t kSize = 64;
  constexpr int32_t kShift = 8;
  auto pattern = [](int32_t row, int32_t x) -> uint16_t {
    return ((x * 7 + row * 13) % 23) < 11 ? kBlack565 : kWhite565;
  };

  FrameLedger ledger(ledger_config(kSize, kSize, 32));
  ASSERT_TRUE(ledger.valid());
  TilePass pass;

  std::vector<uint16_t> frame(static_cast<size_t>(kSize) * kSize);
  for (int32_t y = 0; y < kSize; ++y) {
    for (int32_t x = 0; x < kSize; ++x) {
      frame[static_cast<size_t>(y) * kSize + x] = pattern(y, x);
    }
  }
  pass.run(surface_565(frame, kSize, kSize), nullptr, 0, &ledger);
  std::vector<uint32_t> pass1_hashes(ledger.row_hash_cur(),
                                     ledger.row_hash_cur() + kSize);

  // Scroll down by kShift rows; fresh content at the top.
  for (int32_t y = kSize - 1; y >= kShift; --y) {
    for (int32_t x = 0; x < kSize; ++x) {
      frame[static_cast<size_t>(y) * kSize + x] = pattern(y - kShift, x);
    }
  }
  for (int32_t y = 0; y < kShift; ++y) {
    for (int32_t x = 0; x < kSize; ++x) {
      frame[static_cast<size_t>(y) * kSize + x] = pattern(300 + y, x);
    }
  }
  pass.run(surface_565(frame, kSize, kSize), nullptr, 0, &ledger);

  for (int32_t y = kShift; y < kSize; ++y) {
    ASSERT_EQ(ledger.row_hash_cur()[y], pass1_hashes[y - kShift]) << "y=" << y;
    // Ping-pong: the previous buffer still holds pass 1's hash for this row.
    ASSERT_EQ(ledger.row_hash_prev()[y], pass1_hashes[y]) << "y=" << y;
  }
}

TEST(TilePassTest, HintsClipAndUnhintedTilesStayUntouched) {
  constexpr int32_t kSize = 64;
  FrameLedger ledger(ledger_config(kSize, kSize, 32));
  ASSERT_TRUE(ledger.valid());
  TilePass pass;

  std::vector<uint16_t> frame(static_cast<size_t>(kSize) * kSize, kBlack565);
  // Hint overflows the surface; clips to tile (1,1) only.
  const PlutoRect hint{40, 40, 100, 100};
  ASSERT_EQ(pass.run(surface_565(frame, kSize, kSize), &hint, 1, &ledger),
            size_t{1});
  EXPECT_EQ(pass.dirty_tiles()[0].tile_idx, 3u);
  // Unhinted tiles keep the sentinel.
  EXPECT_EQ(ledger.l_cur()[0], pluto::kInvalidLevel5);
  EXPECT_EQ(ledger.l_cur()[static_cast<size_t>(33) * ledger.stride() + 2],
            pluto::kInvalidLevel5);

  // A hint entirely outside the surface verifies nothing.
  const PlutoRect outside{100, 100, 10, 10};
  EXPECT_EQ(pass.run(surface_565(frame, kSize, kSize), &outside, 1, &ledger),
            size_t{0});
}

TEST(TilePassTest, InvalidInputsReturnZeroDirtyTiles) {
  FrameLedger ledger(ledger_config(32, 32, 32));
  ASSERT_TRUE(ledger.valid());
  TilePass pass;

  PlutoSurface surface{};
  surface.format = kPlutoPixelFormatRgb565;
  surface.width = 32;
  surface.height = 32;
  surface.stride_bytes = 64;
  surface.pixels = nullptr;
  EXPECT_EQ(pass.run(surface, nullptr, 0, &ledger), size_t{0});

  std::vector<uint16_t> frame(32 * 32, kWhite565);
  FrameLedger invalid_ledger;
  EXPECT_EQ(pass.run(surface_565(frame, 32, 32), nullptr, 0, &invalid_ledger),
            size_t{0});
  EXPECT_EQ(pass.run(surface_565(frame, 0, 0), nullptr, 0, &ledger),
            size_t{0});
}

// XRGB8888 ([x, r, g, b] bytes) and Gray8 sources quantize through the same
// position-keyed kernels; a gray ramp lands byte-identical to the RGB565
// path's quantized plane for the same luma.
TEST(TilePassTest, Xrgb8888AndGray8SourcesQuantizeLikeLuma) {
  constexpr int32_t kSize = 16;
  auto value_at = [](int32_t x, int32_t y) -> uint8_t {
    return static_cast<uint8_t>((y * kSize + x) & 0xff);
  };

  std::vector<uint8_t> xrgb(static_cast<size_t>(kSize) * kSize * 4);
  std::vector<uint8_t> gray(static_cast<size_t>(kSize) * kSize);
  for (int32_t y = 0; y < kSize; ++y) {
    for (int32_t x = 0; x < kSize; ++x) {
      const uint8_t v = value_at(x, y);
      const size_t i = static_cast<size_t>(y) * kSize + x;
      xrgb[i * 4 + 0] = 0;
      xrgb[i * 4 + 1] = v;
      xrgb[i * 4 + 2] = v;
      xrgb[i * 4 + 3] = v;
      gray[i] = v;
    }
  }

  PlutoSurface xrgb_surface{};
  xrgb_surface.pixels = xrgb.data();
  xrgb_surface.stride_bytes = static_cast<size_t>(kSize) * 4;
  xrgb_surface.width = kSize;
  xrgb_surface.height = kSize;
  xrgb_surface.format = kPlutoPixelFormatXrgb8888;

  PlutoSurface gray_surface{};
  gray_surface.pixels = gray.data();
  gray_surface.stride_bytes = static_cast<size_t>(kSize);
  gray_surface.width = kSize;
  gray_surface.height = kSize;
  gray_surface.format = kPlutoPixelFormatGray8;

  FrameLedger xrgb_ledger(ledger_config(kSize, kSize, 8));
  FrameLedger gray_ledger(ledger_config(kSize, kSize, 8));
  TilePass pass;
  pass.run(xrgb_surface, nullptr, 0, &xrgb_ledger);
  pass.run(gray_surface, nullptr, 0, &gray_ledger);

  // r == g == b, so XRGB luma equals the raw gray value: identical planes.
  EXPECT_EQ(std::memcmp(xrgb_ledger.l_cur(), gray_ledger.l_cur(),
                        xrgb_ledger.l_cur_size()),
            0);
  // And the plane matches the scalar reference kernel chain per pixel.
  for (int32_t y = 0; y < kSize; ++y) {
    for (int32_t x = 0; x < kSize; ++x) {
      const uint8_t luma = value_at(x, y);
      uint8_t thr = 0;
      pluto::fill_bluenoise_thresholds(x, y, 1, &thr);
      uint8_t expected = 0;
      pluto::quantize16_span_scalar(&luma, &thr, 1, &expected);
      ASSERT_EQ(
          gray_ledger.l_cur()[static_cast<size_t>(y) * gray_ledger.stride() +
                              x],
          expected)
          << "x=" << x << " y=" << y;
    }
  }
  // Gray sources carry no chroma.
  EXPECT_FALSE(gray_ledger.chroma_at(3, 3));
}
