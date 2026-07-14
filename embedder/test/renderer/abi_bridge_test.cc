// AbiPresentBridge contract tests: the dispatch-time conversion between the
// renderer's authoritative state (FrameLedger settled levels + the engine-true
// RGB565 mirror) and the presenter surface. These re-pin the presentation
// contracts previously pinned on the retired PresentPipeline:
//
//   * sub-Full and mono-Full content reaches the glass as settled 16-gray
//     (the ledger's levels, no dispatch re-quantization), PreDithered SET;
//   * color-panel Full with backend_quantizes_color passes RAW RGB from the
//     mirror with PreDithered UNSET (the qtfb/xochitl contract — the backend
//     maps RGB to the panel palette itself);
//   * color-panel Full without delegation lands on the Gallery-3 palette;
//   * every conversion is rect-local deterministic (partial == full + crop);
//   * an unsupported target format leaves the request untouched (the caller
//     decides whether to present raw bytes).

#include <gtest/gtest.h>

#include <cstdint>
#include <random>
#include <vector>

#include "renderer/abi_bridge.h"
#include "renderer/frame_ledger.h"
#include "renderer/gallery3.h"
#include "renderer/kernels.h"
#include "renderer/quantize.h"
#include "renderer/tile_pass.h"

namespace {

using pluto::AbiPresentBridge;
using pluto::AbiPresentBridgeConfig;
using pluto::FrameLedger;
using pluto::FrameLedgerConfig;
using pluto::Gallery3Palette;
using pluto::TilePass;

bool is_gray16_rgb565(uint16_t value) {
  for (int level = 0; level < 256; level += 17) {
    const uint8_t l = static_cast<uint8_t>(level);
    if (value == pluto::rgb888_to_rgb565(l, l, l)) {
      return true;
    }
  }
  return false;
}

bool is_gallery3_rgb565(uint16_t value) {
  const auto& entries = Gallery3Palette::entries_rgb565();
  for (uint16_t entry : entries) {
    if (value == entry) {
      return true;
    }
  }
  return false;
}

std::vector<uint16_t> make_colorful_rgb565(uint32_t width, uint32_t height,
                                           uint32_t seed) {
  std::mt19937 rng(seed);
  std::uniform_int_distribution<uint16_t> pixel_dist(0, 0xffff);
  std::vector<uint16_t> pixels(width * height);
  for (uint16_t& pixel : pixels) {
    pixel = pixel_dist(rng);
  }
  return pixels;
}

PlutoSurface mirror_surface(const std::vector<uint16_t>& src, uint32_t width,
                              uint32_t height) {
  return PlutoSurface{reinterpret_cast<const uint8_t*>(src.data()),
                        width * sizeof(uint16_t), static_cast<int32_t>(width),
                        static_cast<int32_t>(height),
                        kPlutoPixelFormatRgb565};
}

// Settles the ledger from the mirror the way the frame path does: one full
// tile pass.
void settle_ledger(const std::vector<uint16_t>& src, uint32_t width,
                   uint32_t height, FrameLedger* ledger) {
  FrameLedgerConfig config;
  config.width = width;
  config.height = height;
  config.tile_px = 16;
  ASSERT_TRUE(ledger->configure(config));
  TilePass pass;
  pass.run(mirror_surface(src, width, height), nullptr, 0, ledger);
}

PlutoPresentRequest make_request(const std::vector<uint16_t>& mirror,
                                   uint32_t width, uint32_t height,
                                   const PlutoRect* damage,
                                   PlutoRefreshClass cls) {
  PlutoPresentRequest request{};
  request.struct_size = sizeof(request);
  request.surface = mirror_surface(mirror, width, height);
  request.damage = damage;
  request.damage_count = 1;
  request.refresh_class = cls;
  request.flags = kPlutoPresentFlagNone;
  request.frame_id = 1;
  return request;
}

AbiPresentBridgeConfig bridge_config(uint32_t width, uint32_t height) {
  AbiPresentBridgeConfig config;
  config.width = width;
  config.height = height;
  config.source_format = kPlutoPixelFormatRgb565;
  config.target_format = kPlutoPixelFormatRgb565;
  return config;
}

}  // namespace

TEST(AbiPresentBridgeTest, MonoPanelPresentsSettledGray16FromLedger) {
  constexpr uint32_t kW = 64;
  constexpr uint32_t kH = 48;
  const std::vector<uint16_t> mirror = make_colorful_rgb565(kW, kH, 0xc01);
  FrameLedger ledger;
  settle_ledger(mirror, kW, kH, &ledger);

  AbiPresentBridge bridge;
  bridge.configure(bridge_config(kW, kH));
  ASSERT_TRUE(bridge.valid());

  const PlutoRect damage{0, 0, kW, kH};
  // Sub-Full and mono-Full both take the levels path.
  for (const PlutoRefreshClass cls : {kPlutoRefreshUi, kPlutoRefreshFull}) {
    const PlutoPresentRequest out =
        bridge.prepare(make_request(mirror, kW, kH, &damage, cls), ledger);
    EXPECT_NE(out.surface.pixels,
              reinterpret_cast<const uint8_t*>(mirror.data()));
    EXPECT_TRUE((out.flags & kPlutoPresentFlagPreDithered) != 0);
    const auto* pixels = reinterpret_cast<const uint16_t*>(out.surface.pixels);
    for (uint32_t y = 0; y < kH; ++y) {
      for (uint32_t x = 0; x < kW; ++x) {
        const uint16_t px = pixels[y * kW + x];
        ASSERT_TRUE(is_gray16_rgb565(px)) << "x=" << x << " y=" << y;
        // Presented bytes are the settled levels — the exact bytes the diff
        // ran on — not a dispatch re-quantization.
        uint16_t expected = 0;
        pluto::levels_to_rgb565_span_scalar(
            ledger.l_cur() + static_cast<size_t>(y) * ledger.stride() + x, 1,
            &expected);
        ASSERT_EQ(px, expected) << "x=" << x << " y=" << y;
      }
    }
  }
}

// The qtfb contract: a delegated-color backend must receive raw RGB for the
// Full-class color settle, with PreDithered UNSET.
TEST(AbiPresentBridgeTest, ColorPanelFullDelegatedPassesRawColorThrough) {
  constexpr uint32_t kW = 32;
  constexpr uint32_t kH = 32;
  const std::vector<uint16_t> mirror = make_colorful_rgb565(kW, kH, 0xde1e);
  FrameLedger ledger;
  settle_ledger(mirror, kW, kH, &ledger);

  AbiPresentBridgeConfig config = bridge_config(kW, kH);
  config.panel_is_color = true;
  config.backend_quantizes_color = true;  // qtfb: xochitl quantizes downstream
  AbiPresentBridge bridge;
  bridge.configure(config);
  ASSERT_TRUE(bridge.valid());

  const PlutoRect damage{0, 0, kW, kH};
  const PlutoPresentRequest out = bridge.prepare(
      make_request(mirror, kW, kH, &damage, kPlutoRefreshFull), ledger);

  EXPECT_EQ(out.flags & kPlutoPresentFlagPreDithered, 0u);
  const auto* pixels = reinterpret_cast<const uint16_t*>(out.surface.pixels);
  for (uint32_t i = 0; i < kW * kH; ++i) {
    ASSERT_EQ(pixels[i], mirror[i]) << "i=" << i;
  }
}

TEST(AbiPresentBridgeTest, RotatesPixelsSurfaceAndDamageIntoPanelSpace) {
  constexpr uint32_t kW = 3;
  constexpr uint32_t kH = 2;
  const std::vector<uint16_t> mirror{1, 2, 3, 4, 5, 6};
  FrameLedger ledger;
  settle_ledger(mirror, kW, kH, &ledger);

  const struct {
    uint32_t rotation;
    uint32_t width;
    uint32_t height;
    std::vector<uint16_t> pixels;
  } cases[] = {
      {90, 2, 3, {4, 1, 5, 2, 6, 3}},
      {180, 3, 2, {6, 5, 4, 3, 2, 1}},
      {270, 2, 3, {3, 6, 2, 5, 1, 4}},
  };

  for (const auto& test : cases) {
    AbiPresentBridgeConfig config = bridge_config(kW, kH);
    config.rotation = test.rotation;
    config.panel_is_color = true;
    config.backend_quantizes_color = true;
    AbiPresentBridge bridge;
    bridge.configure(config);
    ASSERT_TRUE(bridge.valid());

    const PlutoRect damage{0, 0, kW, kH};
    const PlutoPresentRequest out = bridge.prepare(
        make_request(mirror, kW, kH, &damage, kPlutoRefreshFull), ledger);
    ASSERT_EQ(out.surface.width, static_cast<int32_t>(test.width));
    ASSERT_EQ(out.surface.height, static_cast<int32_t>(test.height));
    ASSERT_EQ(out.damage_count, 1u);
    EXPECT_EQ(out.damage[0].x, 0);
    EXPECT_EQ(out.damage[0].y, 0);
    EXPECT_EQ(out.damage[0].width, static_cast<int32_t>(test.width));
    EXPECT_EQ(out.damage[0].height, static_cast<int32_t>(test.height));
    const auto* pixels =
        reinterpret_cast<const uint16_t*>(out.surface.pixels);
    for (size_t i = 0; i < test.pixels.size(); ++i) {
      ASSERT_EQ(pixels[i], test.pixels[i])
          << "rotation=" << test.rotation << " i=" << i;
    }
  }
}

TEST(AbiPresentBridgeTest, RotatesPartialDamageExactly) {
  constexpr uint32_t kW = 3;
  constexpr uint32_t kH = 2;
  const std::vector<uint16_t> mirror{1, 2, 3, 4, 5, 6};
  FrameLedger ledger;
  settle_ledger(mirror, kW, kH, &ledger);

  AbiPresentBridgeConfig config = bridge_config(kW, kH);
  config.rotation = 90;
  config.panel_is_color = true;
  config.backend_quantizes_color = true;
  AbiPresentBridge bridge;
  bridge.configure(config);

  const PlutoRect damage{1, 0, 2, 1};
  const PlutoPresentRequest out = bridge.prepare(
      make_request(mirror, kW, kH, &damage, kPlutoRefreshFull), ledger);
  ASSERT_EQ(out.damage_count, 1u);
  EXPECT_EQ(out.damage[0].x, 1);
  EXPECT_EQ(out.damage[0].y, 1);
  EXPECT_EQ(out.damage[0].width, 1);
  EXPECT_EQ(out.damage[0].height, 2);
  const auto* pixels = reinterpret_cast<const uint16_t*>(out.surface.pixels);
  EXPECT_EQ(pixels[1 + 1 * 2], 2);
  EXPECT_EQ(pixels[1 + 2 * 2], 3);
}

TEST(AbiPresentBridgeTest, ColorPanelFullOwnQuantizerLandsOnGallery3Palette) {
  constexpr uint32_t kW = 32;
  constexpr uint32_t kH = 32;
  const std::vector<uint16_t> mirror = make_colorful_rgb565(kW, kH, 0x9a11);
  FrameLedger ledger;
  settle_ledger(mirror, kW, kH, &ledger);

  AbiPresentBridgeConfig config = bridge_config(kW, kH);
  config.panel_is_color = true;
  config.backend_quantizes_color = false;  // host preview / future GAL3 swtcon
  AbiPresentBridge bridge;
  bridge.configure(config);
  ASSERT_TRUE(bridge.valid());

  const PlutoRect damage{0, 0, kW, kH};
  const PlutoPresentRequest out = bridge.prepare(
      make_request(mirror, kW, kH, &damage, kPlutoRefreshFull), ledger);

  EXPECT_TRUE((out.flags & kPlutoPresentFlagPreDithered) != 0);
  const auto* pixels = reinterpret_cast<const uint16_t*>(out.surface.pixels);
  for (uint32_t i = 0; i < kW * kH; ++i) {
    ASSERT_TRUE(is_gallery3_rgb565(pixels[i])) << "i=" << i;
  }
}

// Color is a settled state, not feedback: sub-Full content on a color panel
// still reaches the glass chroma-free (settled 16-gray), flag set.
TEST(AbiPresentBridgeTest, ColorPanelSubFullStillCrushesToGray) {
  constexpr uint32_t kW = 32;
  constexpr uint32_t kH = 32;
  const std::vector<uint16_t> mirror = make_colorful_rgb565(kW, kH, 0x111a);
  FrameLedger ledger;
  settle_ledger(mirror, kW, kH, &ledger);

  AbiPresentBridgeConfig config = bridge_config(kW, kH);
  config.panel_is_color = true;
  config.backend_quantizes_color = true;
  AbiPresentBridge bridge;
  bridge.configure(config);
  ASSERT_TRUE(bridge.valid());

  const PlutoRect damage{0, 0, kW, kH};
  const PlutoPresentRequest out = bridge.prepare(
      make_request(mirror, kW, kH, &damage, kPlutoRefreshUi), ledger);

  EXPECT_TRUE((out.flags & kPlutoPresentFlagPreDithered) != 0);
  const auto* pixels = reinterpret_cast<const uint16_t*>(out.surface.pixels);
  for (uint32_t i = 0; i < kW * kH; ++i) {
    ASSERT_TRUE(is_gray16_rgb565(pixels[i])) << "i=" << i;
  }
}

TEST(AbiPresentBridgeTest, Gray8TargetExpandsSettledLevels) {
  constexpr uint32_t kW = 40;
  constexpr uint32_t kH = 24;
  const std::vector<uint16_t> mirror = make_colorful_rgb565(kW, kH, 0x83a7);
  FrameLedger ledger;
  settle_ledger(mirror, kW, kH, &ledger);

  AbiPresentBridgeConfig config = bridge_config(kW, kH);
  config.target_format = kPlutoPixelFormatGray8;
  AbiPresentBridge bridge;
  bridge.configure(config);
  ASSERT_TRUE(bridge.valid());

  const PlutoRect damage{0, 0, kW, kH};
  const PlutoPresentRequest out = bridge.prepare(
      make_request(mirror, kW, kH, &damage, kPlutoRefreshText), ledger);

  EXPECT_EQ(out.surface.format, kPlutoPixelFormatGray8);
  EXPECT_TRUE((out.flags & kPlutoPresentFlagPreDithered) != 0);
  for (uint32_t y = 0; y < kH; ++y) {
    for (uint32_t x = 0; x < kW; ++x) {
      const uint8_t lvl5 =
          ledger.l_cur()[static_cast<size_t>(y) * ledger.stride() + x];
      ASSERT_EQ(out.surface.pixels[y * kW + x], pluto::level5_to_gray8(lvl5))
          << "x=" << x << " y=" << y;
    }
  }
}

// Rect-local determinism at the bridge: converting any rect is byte-identical
// to converting the whole frame and cropping, on both the levels path and the
// Gallery-3 color path — partial updates can never seam.
TEST(AbiPresentBridgeTest, PartialRectMatchesFullFrameConversion) {
  constexpr uint32_t kW = 64;
  constexpr uint32_t kH = 64;
  const std::vector<uint16_t> mirror = make_colorful_rgb565(kW, kH, 0x10ca1);
  FrameLedger ledger;
  settle_ledger(mirror, kW, kH, &ledger);

  for (const bool color_path : {false, true}) {
    AbiPresentBridgeConfig config = bridge_config(kW, kH);
    config.panel_is_color = color_path;
    const PlutoRefreshClass cls =
        color_path ? kPlutoRefreshFull : kPlutoRefreshUi;

    AbiPresentBridge full_bridge;
    full_bridge.configure(config);
    const PlutoRect full_rect{0, 0, kW, kH};
    const PlutoPresentRequest full_out = full_bridge.prepare(
        make_request(mirror, kW, kH, &full_rect, cls), ledger);
    const auto* full_pixels =
        reinterpret_cast<const uint16_t*>(full_out.surface.pixels);

    AbiPresentBridge partial_bridge;
    partial_bridge.configure(config);
    const PlutoRect rect{17, 9, 31, 42};
    const PlutoPresentRequest partial_out = partial_bridge.prepare(
        make_request(mirror, kW, kH, &rect, cls), ledger);
    const auto* partial_pixels =
        reinterpret_cast<const uint16_t*>(partial_out.surface.pixels);

    for (int32_t y = rect.y; y < rect.y + rect.height; ++y) {
      for (int32_t x = rect.x; x < rect.x + rect.width; ++x) {
        ASSERT_EQ(partial_pixels[y * kW + x], full_pixels[y * kW + x])
            << "color=" << color_path << " x=" << x << " y=" << y;
      }
    }
  }
}

// An unsupported target format leaves the bridge invalid and requests pass
// through untouched — the caller's raw-bytes fallback contract.
TEST(AbiPresentBridgeTest, UnsupportedTargetFormatPassesRequestThrough) {
  constexpr uint32_t kW = 16;
  constexpr uint32_t kH = 16;
  const std::vector<uint16_t> mirror = make_colorful_rgb565(kW, kH, 0xfeed);
  FrameLedger ledger;
  settle_ledger(mirror, kW, kH, &ledger);

  AbiPresentBridgeConfig config = bridge_config(kW, kH);
  config.target_format = kPlutoPixelFormatXrgb8888;
  AbiPresentBridge bridge;
  bridge.configure(config);
  EXPECT_FALSE(bridge.valid());

  const PlutoRect damage{0, 0, kW, kH};
  const PlutoPresentRequest in =
      make_request(mirror, kW, kH, &damage, kPlutoRefreshUi);
  const PlutoPresentRequest out = bridge.prepare(in, ledger);
  EXPECT_EQ(out.surface.pixels, in.surface.pixels);
  EXPECT_EQ(out.flags, in.flags);
}
