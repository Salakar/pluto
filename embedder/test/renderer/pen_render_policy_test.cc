#include <gtest/gtest.h>

#include <array>

#include "renderer/pen_render_policy.h"
#include "renderer/rect_utils.h"

namespace {

pluto::PenRenderPolicy policy() {
  pluto::PenRenderPolicy result;
  pluto::PenRenderPolicyConfig config;
  config.width = 400;
  config.height = 600;
  config.tile_px = 32;
  config.hover_radius_px = 24;
  config.contact_radius_px = 16;
  config.changed_pixel_area_scale = 4;
  config.max_preview_area_percent = 20;
  EXPECT_TRUE(result.configure(config));
  return result;
}

pluto::DirtyTileRecord dirty(uint32_t index, PlutoRect rect,
                               uint16_t changed,
                               bool changed_chroma = false,
                               bool current_chroma = false) {
  pluto::DirtyTileRecord record;
  record.tile_idx = index;
  record.dirty = rect;
  record.stats.dirty = rect;
  record.stats.changed_px = changed;
  record.stats.changed_chroma = changed_chroma ? 1 : 0;
  record.stats.chroma_frac = current_chroma ? 255 : 0;
  record.stats.epoch = 1;
  return record;
}

pluto::PenRenderHintSnapshot hover_at(int32_t x, int32_t y) {
  pluto::PenRenderHintSnapshot hint;
  hint.in_range = true;
  hint.previous_x = x - 4;
  hint.previous_y = y;
  hint.current_x = x;
  hint.current_y = y;
  hint.predicted_x = x + 8;
  hint.predicted_y = y;
  hint.sequence = 1;
  return hint;
}

} // namespace

TEST(PenRenderPolicyTest, HoverAloneProducesNoRouteWithoutAppDamage) {
  const auto p = policy();
  const auto hint = hover_at(100, 100);
  EXPECT_TRUE(pluto::rect_intersects(p.focus_rect(hint),
                                       PlutoRect{100, 100, 1, 1}));
  const auto route =
      p.route_region(PlutoRect{80, 80, 64, 64}, hint, nullptr, 0, true);
  EXPECT_FALSE(route.associated);
}

TEST(PenRenderPolicyTest, DistantAppDamageIsNeverPenAssociated) {
  const auto p = policy();
  const auto hint = hover_at(100, 100);
  const std::array records{dirty(165, PlutoRect{300, 400, 20, 20}, 200)};
  const auto route = p.route_region(PlutoRect{300, 400, 20, 20}, hint,
                                    records.data(), records.size(), false);
  EXPECT_FALSE(route.associated);
}

TEST(PenRenderPolicyTest, HoverIndicatorDrawAndEraseAreAssociated) {
  const auto p = policy();
  const auto hint = hover_at(100, 100);
  const std::array records{dirty(28, PlutoRect{78, 78, 44, 44}, 80)};
  const auto route = p.route_region(PlutoRect{78, 78, 44, 44}, hint,
                                    records.data(), records.size(), false);
  ASSERT_TRUE(route.associated);
  EXPECT_EQ(route.truth_class, kPlutoRefreshText);
  EXPECT_TRUE(
      pluto::rect_intersects(route.preview, PlutoRect{100, 100, 1, 1}));
}

TEST(PenRenderPolicyTest, ChromaAppPixelsChaseWithFullOnColorGlass) {
  const auto p = policy();
  auto hint = hover_at(160, 200);
  hint.contact = true;
  const std::array records{
      dirty(69, PlutoRect{140, 180, 48, 48}, 900, true, true)};
  const auto route = p.route_region(PlutoRect{140, 180, 48, 48}, hint,
                                    records.data(), records.size(), true);
  ASSERT_TRUE(route.associated);
  EXPECT_EQ(route.truth_class, kPlutoRefreshFull);
}

TEST(PenRenderPolicyTest, LargeCoincidentFrameClipsFastRegionByChangedPixels) {
  auto p = policy();
  const auto hint = hover_at(100, 100);
  const std::array records{dirty(28, PlutoRect{80, 80, 32, 32}, 32),
                           dirty(29, PlutoRect{0, 0, 400, 600}, 32)};
  const PlutoRect full{0, 0, 400, 600};
  const auto route =
      p.route_region(full, hint, records.data(), records.size(), false);
  ASSERT_TRUE(route.associated);
  EXPECT_LT(pluto::rect_area(route.preview), pluto::rect_area(full));
  EXPECT_TRUE(
      pluto::rect_intersects(route.preview, PlutoRect{100, 100, 1, 1}));
}

TEST(PenRenderPolicyTest, OnePixelColorDrawAndEraseBothChaseWithFull) {
  const auto p = policy();
  const auto hint = hover_at(100, 100);
  const PlutoRect pixel{100, 100, 1, 1};
  for (const bool current_chroma : {true, false}) {
    const std::array records{
        dirty(42, pixel, 1, true, current_chroma)};
    const auto route =
        p.route_region(pixel, hint, records.data(), records.size(), true);
    ASSERT_TRUE(route.associated);
    EXPECT_TRUE(route.carries_chroma);
    EXPECT_EQ(route.truth_class, kPlutoRefreshFull);
  }
}

TEST(PenRenderPolicyTest, GrayDamageBesideStaticColorStaysText) {
  const auto p = policy();
  const auto hint = hover_at(100, 100);
  // Current whole-tile chroma may be non-zero because unrelated red content
  // is static beside the gray change. Only changed-pixel old|new chroma routes.
  const std::array records{
      dirty(42, PlutoRect{100, 100, 1, 1}, 1, false, true)};
  const auto route = p.route_region(PlutoRect{64, 64, 96, 96}, hint,
                                    records.data(), records.size(), true);
  ASSERT_TRUE(route.associated);
  EXPECT_FALSE(route.carries_chroma);
  EXPECT_EQ(route.truth_class, kPlutoRefreshText);
}

TEST(PenRenderPolicyTest, DisconnectedColorDamageDoesNotInflateNibComponent) {
  const auto p = policy();
  auto hint = hover_at(100, 100);
  hint.previous_x = 0; // deliberately widens the swept focus over both records
  const std::array records{
      dirty(42, PlutoRect{100, 100, 4, 4}, 8, false, false),
      dirty(39, PlutoRect{0, 100, 4, 4}, 512, true, true)};
  const auto route = p.route_region(PlutoRect{0, 64, 160, 96}, hint,
                                    records.data(), records.size(), true);
  ASSERT_TRUE(route.associated);
  EXPECT_EQ(route.dirty_tiles, 1u);
  EXPECT_EQ(route.changed_pixels, 8u);
  EXPECT_FALSE(route.carries_chroma);
  EXPECT_EQ(route.truth_class, kPlutoRefreshText);
}

TEST(PenRenderPolicyTest, OversizedSweptFocusStillObeysGeometricHardCap) {
  const auto p = policy();
  auto hint = hover_at(399, 599);
  hint.previous_x = 0;
  hint.previous_y = 0;
  hint.current_x = 399;
  hint.current_y = 599;
  hint.predicted_x = 399;
  hint.predicted_y = 599;
  const std::array records{
      dirty(246, PlutoRect{384, 576, 16, 24}, 128)};
  const PlutoRect full{0, 0, 400, 600};
  const auto route =
      p.route_region(full, hint, records.data(), records.size(), false);
  ASSERT_TRUE(route.associated);
  constexpr int64_t kHardCap = 400 * 600 * 20 / 100;
  EXPECT_LE(pluto::rect_area(route.preview), kHardCap);
  EXPECT_TRUE(
      pluto::rect_intersects(route.preview, records[0].dirty));
}

TEST(PenRenderPolicyTest,
     LongThinConnectedStrokeRoutesBeyondFocusWithoutBackgroundInflation) {
  const auto p = policy();
  constexpr int32_t kTileRow = 6;
  constexpr int32_t kTileColumns = 13;
  std::array<pluto::DirtyTileRecord, 10> records{};
  PlutoRect verified_bounds{};
  uint64_t changed_pixels = 0;
  for (int32_t i = 0; i < static_cast<int32_t>(records.size()); ++i) {
    const int32_t tile_x = i + 1;
    const PlutoRect segment{tile_x * 32 + 2, 198, 28, 3};
    records[static_cast<size_t>(i)] =
        dirty(kTileRow * kTileColumns + tile_x, segment, 84);
    verified_bounds = pluto::rect_union(verified_bounds, segment);
    changed_pixels += 84;
  }

  auto hint = hover_at(342, 199);
  hint.contact = true;
  hint.previous_x = 336;
  hint.predicted_x = 350;
  const auto route = p.route_region(verified_bounds, hint, records.data(),
                                    records.size(), false);

  ASSERT_TRUE(route.associated);
  EXPECT_EQ(route.preview.x, verified_bounds.x);
  EXPECT_EQ(route.preview.y, verified_bounds.y);
  EXPECT_EQ(route.preview.width, verified_bounds.width);
  EXPECT_EQ(route.preview.height, verified_bounds.height);
  EXPECT_EQ(route.truth.x, route.preview.x);
  EXPECT_EQ(route.truth.y, route.preview.y);
  EXPECT_EQ(route.truth.width, route.preview.width);
  EXPECT_EQ(route.truth.height, route.preview.height);
  EXPECT_EQ(route.dirty_tiles, records.size());
  EXPECT_EQ(route.changed_pixels, changed_pixels);
  for (const auto &record : records) {
    EXPECT_TRUE(pluto::rect_intersects(route.preview, record.dirty));
  }
  EXPECT_LT(pluto::rect_area(route.preview),
            pluto::rect_area(p.focus_rect(hint)))
      << "a thin verified stroke must not inherit the broad focus box";
}

TEST(PenRenderPolicyTest,
     CurvedSparseStrokeCoverageAndAreaScaleFollowChangedPixels) {
  const auto p = policy();
  constexpr int32_t kTileColumns = 13;
  constexpr std::array<std::array<int32_t, 2>, 10> kCurve{{
      {{2, 2}}, {{3, 2}}, {{4, 2}}, {{5, 2}}, {{5, 3}},
      {{5, 4}}, {{4, 4}}, {{3, 4}}, {{2, 4}}, {{2, 3}},
  }};
  const auto make_curve = [&](uint16_t changed) {
    std::array<pluto::DirtyTileRecord, kCurve.size()> records{};
    for (size_t i = 0; i < kCurve.size(); ++i) {
      const int32_t tx = kCurve[i][0];
      const int32_t ty = kCurve[i][1];
      records[i] = dirty(ty * kTileColumns + tx,
                         PlutoRect{tx * 32 + 14, ty * 32 + 14, 4, 4},
                         changed);
    }
    return records;
  };
  const auto sparse = make_curve(1);
  const auto dense = make_curve(16);
  PlutoRect verified_bounds{};
  for (const auto &record : sparse) {
    verified_bounds = pluto::rect_union(verified_bounds, record.dirty);
  }

  auto route_at = [&](const auto &records, size_t index) {
    const PlutoRect &point = records[index].dirty;
    auto hint = hover_at(point.x + point.width / 2,
                         point.y + point.height / 2);
    hint.contact = true;
    return p.route_region(verified_bounds, hint, records.data(), records.size(),
                          false);
  };

  const auto sparse_tip = route_at(sparse, 0);
  const auto dense_tip = route_at(dense, 0);
  ASSERT_TRUE(sparse_tip.associated);
  ASSERT_TRUE(dense_tip.associated);
  constexpr int64_t kSparseBudget = kCurve.size() * 1 * 4;
  constexpr int64_t kDenseBudget = kCurve.size() * 16 * 4;
  EXPECT_LE(pluto::rect_area(sparse_tip.preview), kSparseBudget);
  EXPECT_LE(pluto::rect_area(dense_tip.preview), kDenseBudget);
  EXPECT_GT(pluto::rect_area(dense_tip.preview),
            pluto::rect_area(sparse_tip.preview));
  EXPECT_LT(pluto::rect_area(sparse_tip.preview),
            pluto::rect_area(p.focus_rect(hover_at(
                sparse[0].dirty.x + 2, sparse[0].dirty.y + 2))));

  for (size_t i = 0; i < sparse.size(); ++i) {
    const auto route = route_at(sparse, i);
    ASSERT_TRUE(route.associated) << "curve record " << i;
    EXPECT_TRUE(pluto::rect_intersects(route.preview, sparse[i].dirty))
        << "curve record " << i;
    EXPECT_GE(route.preview.x, verified_bounds.x);
    EXPECT_GE(route.preview.y, verified_bounds.y);
    EXPECT_LE(pluto::rect_right(route.preview),
              pluto::rect_right(verified_bounds));
    EXPECT_LE(pluto::rect_bottom(route.preview),
              pluto::rect_bottom(verified_bounds));
    EXPECT_LE(pluto::rect_area(route.preview), kSparseBudget);
  }
}

TEST(PenRenderPolicyTest, SubtractionPreservesEveryNonHotPixelExactlyOnce) {
  const PlutoRect outer{0, 0, 100, 80};
  const PlutoRect cut{20, 10, 30, 40};
  PlutoRect pieces[4]{};
  const size_t count =
      pluto::PenRenderPolicy::subtract_rect(outer, cut, pieces);
  ASSERT_EQ(count, 4u);
  int64_t area = pluto::rect_area(cut);
  for (size_t i = 0; i < count; ++i) {
    EXPECT_FALSE(pluto::rect_intersects(pieces[i], cut));
    area += pluto::rect_area(pieces[i]);
    for (size_t j = i + 1; j < count; ++j) {
      EXPECT_FALSE(pluto::rect_intersects(pieces[i], pieces[j]));
    }
  }
  EXPECT_EQ(area, pluto::rect_area(outer));
}
