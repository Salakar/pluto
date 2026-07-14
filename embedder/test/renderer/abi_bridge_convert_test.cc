// Goldens for the AbiPresentBridge levels->surface present conversion
// (abi_bridge.cc convert_rect_levels): the raster-thread hot path that turns
// the FrameLedger's settled 5-bit levels into presenter pixels for every
// damage rect of every present.
//
// The frozen per-pixel reference is the scalar span kernel
// (levels_to_rgb565_span_scalar / level5_to_gray8, renderer/kernels.h): the
// bridge's palette-lookup fast path must be byte-identical to converting each
// damage row with the scalar kernel — and must leave every byte OUTSIDE the
// damage rects untouched (0xff paper white after configure()). Coverage is
// exhaustive over the input alphabet and the vector shapes: every ledger byte
// value 0..255 (all 32 levels, the kInvalidLevel5 sentinel, and out-of-range
// garbage that must clamp like level 31), rect widths that exercise the
// 16-lane blocks, the overlapped tail vector and the sub-16 scalar fallback,
// odd x/y offsets (lane misalignment), and a padded ledger stride (954 -> 960)
// so row starts do not coincide with plane starts.

#include <gtest/gtest.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <random>
#include <vector>

#include "renderer/abi_bridge.h"
#include "renderer/frame_ledger.h"
#include "renderer/kernels.h"

namespace {

using pluto::AbiPresentBridge;
using pluto::AbiPresentBridgeConfig;
using pluto::FrameLedger;
using pluto::FrameLedgerConfig;

FrameLedgerConfig ledger_config(uint32_t width, uint32_t height,
                                uint32_t tile_px) {
  FrameLedgerConfig config;
  config.width = width;
  config.height = height;
  config.tile_px = tile_px;
  return config;
}

// Ledger fills. Direct l_cur() writes (not a tile pass): the conversion
// contract is over ANY plane byte, including the sentinel and garbage.
void fill_all_bytes(FrameLedger* ledger) {
  uint8_t* plane = ledger->l_cur();
  for (size_t i = 0; i < ledger->l_cur_size(); ++i) {
    plane[i] = static_cast<uint8_t>(i * 131u);  // odd stride: all 256 values
  }
}

void fill_all_levels_phased(FrameLedger* ledger) {
  uint8_t* plane = ledger->l_cur();
  const size_t stride = ledger->stride();
  for (uint32_t y = 0; y < ledger->height(); ++y) {
    for (size_t x = 0; x < stride; ++x) {
      plane[y * stride + x] = static_cast<uint8_t>((x + y) & 31u);
    }
  }
}

void fill_random_bytes(FrameLedger* ledger, uint32_t seed) {
  std::mt19937 rng(seed);
  std::uniform_int_distribution<int> byte(0, 255);
  uint8_t* plane = ledger->l_cur();
  for (size_t i = 0; i < ledger->l_cur_size(); ++i) {
    plane[i] = static_cast<uint8_t>(byte(rng));
  }
}

PlutoPresentRequest levels_request(const PlutoRect* damage,
                                     size_t damage_count) {
  PlutoPresentRequest request{};
  request.struct_size = sizeof(request);
  request.damage = damage;
  request.damage_count = damage_count;
  request.refresh_class = kPlutoRefreshUi;  // mono levels path
  request.flags = kPlutoPresentFlagNone;
  request.frame_id = 1;
  return request;
}

PlutoRect clip_rect(const PlutoRect& rect, uint32_t width,
                      uint32_t height) {
  const int32_t x0 = rect.x < 0 ? 0 : rect.x;
  const int32_t y0 = rect.y < 0 ? 0 : rect.y;
  const int32_t x1 = std::min<int32_t>(rect.x + rect.width,
                                       static_cast<int32_t>(width));
  const int32_t y1 = std::min<int32_t>(rect.y + rect.height,
                                       static_cast<int32_t>(height));
  if (x1 <= x0 || y1 <= y0) {
    return PlutoRect{0, 0, 0, 0};
  }
  return PlutoRect{x0, y0, x1 - x0, y1 - y0};
}

// Applies the frozen scalar reference for one damage rect into `expected`
// (RGB565 target). Rows are converted with levels_to_rgb565_span_scalar,
// exactly as the pre-palette bridge did.
void reference_convert_rgb565(const FrameLedger& ledger,
                              const PlutoRect& rect,
                              std::vector<uint8_t>* expected,
                              size_t target_stride) {
  for (int32_t y = 0; y < rect.height; ++y) {
    const size_t abs_y = static_cast<size_t>(rect.y + y);
    pluto::levels_to_rgb565_span_scalar(
        ledger.l_cur() + abs_y * ledger.stride() +
            static_cast<size_t>(rect.x),
        static_cast<size_t>(rect.width),
        reinterpret_cast<uint16_t*>(expected->data() +
                                    abs_y * target_stride) +
            rect.x);
  }
}

void reference_convert_gray8(const FrameLedger& ledger, const PlutoRect& rect,
                             std::vector<uint8_t>* expected,
                             size_t target_stride) {
  for (int32_t y = 0; y < rect.height; ++y) {
    const size_t abs_y = static_cast<size_t>(rect.y + y);
    for (int32_t x = 0; x < rect.width; ++x) {
      const uint8_t lvl5 =
          ledger.l_cur()[abs_y * ledger.stride() +
                         static_cast<size_t>(rect.x + x)];
      (*expected)[abs_y * target_stride + static_cast<size_t>(rect.x + x)] =
          pluto::level5_to_gray8(lvl5);
    }
  }
}

// Converts `rect` through a fresh bridge and byte-compares the WHOLE present
// buffer against the scalar-reference expectation (touched bytes match the
// reference; untouched bytes stay 0xff paper white).
void expect_rect_matches_reference(const FrameLedger& ledger,
                                   PlutoPixelFormat target_format,
                                   const PlutoRect& rect) {
  AbiPresentBridgeConfig config;
  config.width = ledger.width();
  config.height = ledger.height();
  config.target_format = target_format;
  AbiPresentBridge bridge;
  bridge.configure(config);
  ASSERT_TRUE(bridge.valid());

  const PlutoPresentRequest out =
      bridge.prepare(levels_request(&rect, 1), ledger);
  ASSERT_EQ(out.surface.pixels, bridge.present_data());

  const size_t target_stride = bridge.present_stride();
  std::vector<uint8_t> expected(target_stride * ledger.height(), 0xff);
  const PlutoRect clipped = clip_rect(rect, ledger.width(), ledger.height());
  if (clipped.width > 0) {
    if (target_format == kPlutoPixelFormatRgb565) {
      reference_convert_rgb565(ledger, clipped, &expected, target_stride);
    } else {
      reference_convert_gray8(ledger, clipped, &expected, target_stride);
    }
  }
  ASSERT_EQ(std::memcmp(bridge.present_data(), expected.data(),
                        expected.size()),
            0)
      << "target=" << target_format << " rect{" << rect.x << "," << rect.y
      << "," << rect.width << "," << rect.height << "}";
}

// Width sweep: scalar fallback (< 16), exact blocks, blocks + overlapped
// tail, and single-block spans at every misalignment the tail can take.
const int32_t kWidths[] = {1,  2,  3,  5,  7,  8,  9,  15, 16, 17,
                           23, 24, 31, 32, 33, 47, 48, 63, 64, 127};

}  // namespace

// Panel-strided geometry (954 px, stride 960): every byte value, full-panel
// width plus the width/offset sweep against the scalar reference.
TEST(AbiBridgeConvertGolden, Rgb565MatchesScalarOnPaddedPanelStride) {
  FrameLedger ledger;
  ASSERT_TRUE(ledger.configure(ledger_config(954, 64, 32)));
  fill_all_bytes(&ledger);

  // Full-surface rect: 59 full 16-lane blocks + a 10-px overlapped tail per
  // row, row starts offset from the plane by the 6-byte stride padding.
  expect_rect_matches_reference(ledger, kPlutoPixelFormatRgb565,
                                PlutoRect{0, 0, 954, 64});
  // Width/offset sweep at odd x/y so lanes never start plane-aligned.
  for (const int32_t w : kWidths) {
    expect_rect_matches_reference(ledger, kPlutoPixelFormatRgb565,
                                  PlutoRect{0, 3, w, 7});
    expect_rect_matches_reference(ledger, kPlutoPixelFormatRgb565,
                                  PlutoRect{1, 9, w, 5});
    expect_rect_matches_reference(ledger, kPlutoPixelFormatRgb565,
                                  PlutoRect{17, 31, w, 3});
    expect_rect_matches_reference(ledger, kPlutoPixelFormatRgb565,
                                  PlutoRect{954 - w - 1, 60, w, 4});
  }
  // Right-edge rects: the overlapped tail's last vector ends exactly at the
  // row's damage boundary — nothing right of the rect may be written.
  for (const int32_t w : kWidths) {
    expect_rect_matches_reference(ledger, kPlutoPixelFormatRgb565,
                                  PlutoRect{954 - w, 0, w, 64});
  }
}

// All 32 levels at every lane position (phased diagonally), plus random
// garbage bytes: the clamp path (index > 31 -> 31) must match the scalar
// kernel's level5_to_gray8 clamp everywhere.
TEST(AbiBridgeConvertGolden, Rgb565MatchesScalarOnAllLevelsAndGarbage) {
  FrameLedger ledger;
  ASSERT_TRUE(ledger.configure(ledger_config(200, 48, 8)));
  fill_all_levels_phased(&ledger);
  for (const int32_t w : kWidths) {
    expect_rect_matches_reference(ledger, kPlutoPixelFormatRgb565,
                                  PlutoRect{0, 0, w, 48});
    expect_rect_matches_reference(ledger, kPlutoPixelFormatRgb565,
                                  PlutoRect{13, 5, w, 17});
  }
  fill_random_bytes(&ledger, 0xb51d6e);
  for (const int32_t w : kWidths) {
    expect_rect_matches_reference(ledger, kPlutoPixelFormatRgb565,
                                  PlutoRect{7, 1, w, 46});
  }
  // Sentinel plane: a freshly invalidated ledger is all kInvalidLevel5.
  ledger.invalidate();
  expect_rect_matches_reference(ledger, kPlutoPixelFormatRgb565,
                                PlutoRect{0, 0, 200, 48});
}

// Multi-rect requests convert independently; overlapping rects rewrite
// identical bytes (the conversion is a pure function of the ledger byte).
TEST(AbiBridgeConvertGolden, Rgb565MultiRectMatchesScalar) {
  FrameLedger ledger;
  ASSERT_TRUE(ledger.configure(ledger_config(954, 64, 32)));
  fill_random_bytes(&ledger, 0x9a7e5);

  const PlutoRect rects[] = {
      {0, 0, 100, 10}, {50, 5, 300, 20}, {900, 40, 54, 24}, {33, 33, 17, 1}};
  AbiPresentBridgeConfig config;
  config.width = ledger.width();
  config.height = ledger.height();
  AbiPresentBridge bridge;
  bridge.configure(config);
  ASSERT_TRUE(bridge.valid());
  (void)bridge.prepare(levels_request(rects, 4), ledger);

  const size_t target_stride = bridge.present_stride();
  std::vector<uint8_t> expected(target_stride * ledger.height(), 0xff);
  for (const PlutoRect& rect : rects) {
    reference_convert_rgb565(ledger, rect, &expected, target_stride);
  }
  ASSERT_EQ(
      std::memcmp(bridge.present_data(), expected.data(), expected.size()), 0);
}

// Gray8 target: the same rect sweep against the per-pixel level5_to_gray8
// reference (this path shares convert_rect_levels' row walk).
TEST(AbiBridgeConvertGolden, Gray8MatchesScalarAcrossWidthsAndOffsets) {
  FrameLedger ledger;
  ASSERT_TRUE(ledger.configure(ledger_config(954, 32, 32)));
  fill_all_bytes(&ledger);
  expect_rect_matches_reference(ledger, kPlutoPixelFormatGray8,
                                PlutoRect{0, 0, 954, 32});
  for (const int32_t w : kWidths) {
    expect_rect_matches_reference(ledger, kPlutoPixelFormatGray8,
                                  PlutoRect{5, 11, w, 13});
  }
}
