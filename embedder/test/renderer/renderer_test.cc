#include <gtest/gtest.h>

#include <array>
#include <cstdint>
#include <random>
#include <vector>

#include "renderer/bluenoise_64.h"
#include "renderer/convert.h"
#include "renderer/gallery3.h"
#include "renderer/quantize.h"
#include "renderer/rect_utils.h"

// Stage-2 note: the EinkScheduler and its trace-string
// goldens died with the RegionScheduler cutover. The behavioral contracts
// (requeue-exactly-once, no-damage-loss, fast-never-blocks, synchronous
// completion, stress/chroma settle policy) live on in
// region_scheduler_test.cc and settle_policy_test.cc, re-pinned against the
// new components before the old suite was deleted.
//
// Stage-6 note: RefreshClassifier (classify.{h,cc}) died with the
// ClassifyLadder cutover. Its load-bearing product behaviors are re-pinned
// in classify_ladder_test.cc (class taxonomy, motion -> Fast, big-repaint
// quality, frame-0 / large-change Full via the scenecut rung) and the
// replay-harness baselines (tools/renderer_replay.cc assertions).

namespace {

using pluto::ConvertConfig;
using pluto::DitherKernel;

}  // namespace

TEST(QuantizeTest, ConvertsRgb888ToRgb565AndLuma) {
  const uint16_t red = pluto::rgb888_to_rgb565(255, 0, 0);
  const uint16_t green = pluto::rgb888_to_rgb565(0, 255, 0);
  const uint16_t blue = pluto::rgb888_to_rgb565(0, 0, 255);
  EXPECT_GT(pluto::rgb565_luma8(green), pluto::rgb565_luma8(red));
  EXPECT_GT(pluto::rgb565_luma8(red), pluto::rgb565_luma8(blue));
  EXPECT_TRUE(pluto::rgb565_has_chroma(red));
  EXPECT_FALSE(
      pluto::rgb565_has_chroma(pluto::rgb888_to_rgb565(128, 128, 128)));
}

void expect_rect_local_property(PlutoRefreshClass cls, DitherKernel kernel) {
  constexpr int kWidth = 73;
  constexpr int kHeight = 59;
  std::mt19937 rng(0x51a7e);
  std::uniform_int_distribution<uint16_t> pixel_dist(0, 0xffff);
  std::uniform_int_distribution<int> x_dist(0, kWidth - 1);
  std::uniform_int_distribution<int> y_dist(0, kHeight - 1);

  for (int case_index = 0; case_index < 512; ++case_index) {
    std::vector<uint16_t> src(kWidth * kHeight);
    for (uint16_t& pixel : src) {
      pixel = pixel_dist(rng);
    }

    const int x = x_dist(rng);
    const int y = y_dist(rng);
    std::uniform_int_distribution<int> w_dist(1, kWidth - x);
    std::uniform_int_distribution<int> h_dist(1, kHeight - y);
    const PlutoRect rect{x, y, w_dist(rng), h_dist(rng)};

    std::vector<uint8_t> full(kWidth * kHeight);
    std::vector<uint8_t> partial(rect.width * rect.height);
    ConvertConfig config;
    config.width = kWidth;
    config.height = kHeight;
    config.refresh_class = cls;
    config.kernel = kernel;

    pluto::convert_rgb565_to_gray8_rect(
        src.data(), kWidth * sizeof(uint16_t), full.data(), kWidth,
        PlutoRect{0, 0, kWidth, kHeight}, config);
    pluto::convert_rgb565_to_gray8_rect(src.data(), kWidth * sizeof(uint16_t),
                                          partial.data(), rect.width, rect,
                                          config);

    for (int yy = 0; yy < rect.height; ++yy) {
      for (int xx = 0; xx < rect.width; ++xx) {
        ASSERT_EQ(partial[yy * rect.width + xx],
                  full[(rect.y + yy) * kWidth + rect.x + xx])
            << "case=" << case_index << " x=" << xx << " y=" << yy;
      }
    }
  }
}

TEST(ConvertPropertyTest, RectLocalSafeBlueNoiseDither) {
  expect_rect_local_property(kPlutoRefreshUi, DitherKernel::kBlueNoise64);
}

TEST(ConvertPropertyTest, RectLocalSafeBayerFastDither) {
  expect_rect_local_property(kPlutoRefreshFast, DitherKernel::kBayer4);
}

// Pen-path note: the dormant InkOverlay and native WetInkPlane were removed
// (Stage 5). Its behavioral invariants — the composite-black
// rule and the stamp bbox/chain math — are re-pinned in
// app-owned pixel routing tests against the live renderer.

namespace {

using pluto::Gallery3Palette;

bool is_gallery3_rgb565(uint16_t value) {
  const auto& entries = Gallery3Palette::entries_rgb565();
  for (uint16_t entry : entries) {
    if (value == entry) {
      return true;
    }
  }
  return false;
}

}  // namespace

TEST(BlueNoiseTest, HistogramIsUniform) {
  std::array<int, 256> histogram{};
  for (uint8_t value : pluto::k_blue_noise_64) {
    ++histogram[value];
  }
  for (int count : histogram) {
    EXPECT_EQ(count, 16);
  }
}

TEST(Gallery3Test, ExactEntriesMapToThemselves) {
  const Gallery3Palette& palette = Gallery3Palette::instance();
  EXPECT_EQ(palette.nearest_index(0, 0, 0), 0);
  EXPECT_EQ(palette.nearest_index(255, 255, 255), 1);
  EXPECT_EQ(palette.nearest_index(0, 200, 220), 2);
  EXPECT_EQ(palette.nearest_index(200, 0, 130), 3);
  EXPECT_EQ(palette.nearest_index(235, 200, 0), 4);
  EXPECT_EQ(palette.nearest_index(210, 40, 40), 5);
  EXPECT_EQ(palette.nearest_index(50, 160, 70), 6);
  EXPECT_EQ(palette.nearest_index(40, 70, 180), 7);
}

TEST(Gallery3Test, MapAlwaysLandsOnPaletteEntries) {
  const Gallery3Palette& palette = Gallery3Palette::instance();
  std::mt19937 rng(0xda17e);
  std::uniform_int_distribution<uint16_t> pixel_dist(0, 0xffff);
  for (int i = 0; i < 20000; ++i) {
    const uint16_t pixel = pixel_dist(rng);
    const int32_t x = static_cast<int32_t>(rng() % 954);
    const int32_t y = static_cast<int32_t>(rng() % 1696);
    const uint16_t mapped = palette.map_rgb565(pixel, x, y);
    ASSERT_TRUE(is_gallery3_rgb565(mapped))
        << "pixel=" << pixel << " x=" << x << " y=" << y
        << " mapped=" << mapped;
  }
}

TEST(Gallery3Test, NeutralGraysDitherToBlackAndWhiteOnly) {
  const Gallery3Palette& palette = Gallery3Palette::instance();
  const uint16_t black = Gallery3Palette::entries_rgb565()[0];
  const uint16_t white = Gallery3Palette::entries_rgb565()[1];
  for (const int gray : {32, 64, 128, 192, 224}) {
    int white_count = 0;
    const uint16_t pixel = pluto::rgb888_to_rgb565(
        static_cast<uint8_t>(gray), static_cast<uint8_t>(gray),
        static_cast<uint8_t>(gray));
    for (int32_t y = 0; y < 64; ++y) {
      for (int32_t x = 0; x < 64; ++x) {
        const uint16_t mapped = palette.map_rgb565(pixel, x, y);
        // Desaturated content must never pick up a chromatic pigment.
        ASSERT_TRUE(mapped == black || mapped == white)
            << "gray=" << gray << " x=" << x << " y=" << y;
        white_count += mapped == white ? 1 : 0;
      }
    }
    // The white fraction tracks the gray level (full-range ordered dither).
    const double fraction = static_cast<double>(white_count) / 4096.0;
    const double expected = static_cast<double>(gray) / 255.0;
    EXPECT_NEAR(fraction, expected, 0.08) << "gray=" << gray;
  }
}

TEST(Gallery3Test, PureWhiteAndBlackAreFixedPointsEverywhere) {
  // A Full-class pass over unchanged paper-white (or solid black) must be
  // byte-idempotent: no pepper specks at any dither-mask position. This is
  // what keeps the settled picture independent of WHICH rects a policy
  // chooses to flash.
  const Gallery3Palette& palette = Gallery3Palette::instance();
  const uint16_t black = Gallery3Palette::entries_rgb565()[0];
  const uint16_t white = Gallery3Palette::entries_rgb565()[1];
  for (int32_t y = 0; y < 64; ++y) {
    for (int32_t x = 0; x < 64; ++x) {
      ASSERT_EQ(palette.map_rgb565(0xffff, x, y), white)
          << "x=" << x << " y=" << y;
      ASSERT_EQ(palette.map_rgb565(0x0000, x, y), black)
          << "x=" << x << " y=" << y;
    }
  }
}

TEST(Gallery3Test, SaturatedPrimariesKeepTheirHue) {
  const Gallery3Palette& palette = Gallery3Palette::instance();
  const auto& entries = Gallery3Palette::entries_rgb565();
  // Pure saturated inputs must map to their own palette entry everywhere.
  const uint16_t red = pluto::rgb888_to_rgb565(210, 40, 40);
  const uint16_t cyan = pluto::rgb888_to_rgb565(0, 200, 220);
  for (int32_t y = 0; y < 64; y += 7) {
    for (int32_t x = 0; x < 64; x += 7) {
      EXPECT_EQ(palette.map_rgb565(red, x, y), entries[5]);
      EXPECT_EQ(palette.map_rgb565(cyan, x, y), entries[2]);
    }
  }
}
