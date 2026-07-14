// GuardBandPackager suite: guard fringe geometry (exact, clipped at panel
// edges, marked guard-null), word-box aggregation for Text-class damage
// (deterministic 8 px snapping, edge reuse across keystrokes), and the
// flag-map legal-review rejection.

#include <gtest/gtest.h>

#include <cstdint>

#include "renderer/guard_band.h"
#include "renderer/rect_utils.h"

namespace {

using pluto::GuardBandConfig;
using pluto::GuardBandPackager;
using pluto::GuardedRegion;

GuardBandConfig test_config() {
  GuardBandConfig config;
  config.width = 256;
  config.height = 256;
  config.guard_px = 1;
  config.word_box_align_px = 8;
  config.word_box_gap_px = 16;
  config.word_box_max_px = 64;
  return config;
}

bool rect_equals(const PlutoRect& a, const PlutoRect& b) {
  return a.x == b.x && a.y == b.y && a.width == b.width &&
         a.height == b.height;
}

int64_t guard_area(const GuardedRegion& region) {
  int64_t area = 0;
  for (size_t i = 0; i < region.guard_count; ++i) {
    area += pluto::rect_area(region.guard[i].rect);
  }
  return area;
}

}  // namespace

// An interior rect gets the exact four-sided fringe: content + guard ==
// the 1 px dilation, no overlap, every guard rect marked guard-null.
TEST(GuardBandTest, InteriorFringeGeometryExact) {
  GuardBandPackager packager;
  ASSERT_TRUE(packager.configure(test_config()));
  const PlutoRect rect{40, 40, 16, 8};
  const PlutoRefreshClass cls = kPlutoRefreshUi;
  ASSERT_EQ(packager.package(&rect, &cls, 1), 1u);

  const GuardedRegion& region = packager.regions()[0];
  EXPECT_TRUE(rect_equals(region.content, rect));
  ASSERT_EQ(region.guard_count, 4u);
  const PlutoRect dilated{39, 39, 18, 10};
  int64_t area = 0;
  for (size_t i = 0; i < region.guard_count; ++i) {
    const PlutoRect& g = region.guard[i].rect;
    EXPECT_TRUE(region.guard[i].guard_null);  // ALWAYS null-transition bands
    EXPECT_FALSE(pluto::rect_intersects(g, region.content));
    // Contained in the dilation.
    EXPECT_GE(g.x, dilated.x);
    EXPECT_GE(g.y, dilated.y);
    EXPECT_LE(pluto::rect_right(g), pluto::rect_right(dilated));
    EXPECT_LE(pluto::rect_bottom(g), pluto::rect_bottom(dilated));
    area += pluto::rect_area(g);
  }
  EXPECT_EQ(area + pluto::rect_area(rect), pluto::rect_area(dilated));
}

// Dilation clips at the panel edges: a corner rect keeps only the sides
// that exist.
TEST(GuardBandTest, DilationClippedAtPanelEdges) {
  GuardBandPackager packager;
  ASSERT_TRUE(packager.configure(test_config()));
  const PlutoRect corner{0, 0, 8, 8};
  const PlutoRefreshClass cls = kPlutoRefreshFast;
  ASSERT_EQ(packager.package(&corner, &cls, 1), 1u);
  const GuardedRegion& region = packager.regions()[0];
  ASSERT_EQ(region.guard_count, 2u);  // bottom + right only
  const int64_t expected =
      pluto::rect_area(PlutoRect{0, 0, 9, 9}) - pluto::rect_area(corner);
  EXPECT_EQ(guard_area(region), expected);

  const PlutoRect far_corner{248, 248, 8, 8};
  ASSERT_EQ(packager.package(&far_corner, &cls, 1), 1u);
  const GuardedRegion& far_region = packager.regions()[0];
  ASSERT_EQ(far_region.guard_count, 2u);  // top + left only
  for (size_t i = 0; i < far_region.guard_count; ++i) {
    EXPECT_LE(pluto::rect_right(far_region.guard[i].rect), 256);
    EXPECT_LE(pluto::rect_bottom(far_region.guard[i].rect), 256);
  }
}

// Text-class glyph rects cluster into ONE word box snapped OUT to the 8 px
// grid; repeated packaging is deterministic and a grown word reuses the
// previous box's top/bottom/left edges.
TEST(GuardBandTest, WordBoxSnappingDeterministicAndEdgeReusing) {
  GuardBandPackager packager;
  ASSERT_TRUE(packager.configure(test_config()));

  const PlutoRect glyphs[2] = {PlutoRect{41, 9, 6, 6},
                                 PlutoRect{49, 9, 6, 6}};
  const PlutoRefreshClass classes[2] = {kPlutoRefreshText,
                                          kPlutoRefreshText};
  ASSERT_EQ(packager.package(glyphs, classes, 2), 1u);
  const PlutoRect box = packager.regions()[0].content;
  EXPECT_TRUE(rect_equals(box, PlutoRect{40, 8, 16, 8}));
  EXPECT_TRUE(packager.regions()[0].word_box);

  // Deterministic: identical input -> identical output.
  ASSERT_EQ(packager.package(glyphs, classes, 2), 1u);
  EXPECT_TRUE(rect_equals(packager.regions()[0].content, box));

  // Next keystroke grows the word: same top/bottom/left edges, the right
  // edge advances by one 8 px grid step.
  const PlutoRect grown[3] = {glyphs[0], glyphs[1],
                                PlutoRect{57, 9, 6, 6}};
  const PlutoRefreshClass grown_classes[3] = {
      kPlutoRefreshText, kPlutoRefreshText, kPlutoRefreshText};
  ASSERT_EQ(packager.package(grown, grown_classes, 3), 1u);
  const PlutoRect grown_box = packager.regions()[0].content;
  EXPECT_EQ(grown_box.x, box.x);
  EXPECT_EQ(grown_box.y, box.y);
  EXPECT_EQ(grown_box.height, box.height);
  EXPECT_EQ(pluto::rect_right(grown_box), pluto::rect_right(box) + 8);
}

// Distant Text rects stay separate word boxes; non-Text classes never
// cluster and keep their exact content rects.
TEST(GuardBandTest, ClusteringRespectsGapAndClass) {
  GuardBandPackager packager;
  ASSERT_TRUE(packager.configure(test_config()));

  const PlutoRect rects[3] = {PlutoRect{8, 8, 6, 6},
                                PlutoRect{200, 200, 6, 6},
                                PlutoRect{16, 8, 6, 6}};
  const PlutoRefreshClass classes[3] = {
      kPlutoRefreshText, kPlutoRefreshText, kPlutoRefreshUi};
  ASSERT_EQ(packager.package(rects, classes, 3), 3u);
  // Ui rect passes through exactly (regions emit non-Text first).
  EXPECT_TRUE(rect_equals(packager.regions()[0].content, rects[2]));
  EXPECT_FALSE(packager.regions()[0].word_box);
  // The two Text rects are too far apart to cluster: two word boxes.
  size_t word_boxes = 0;
  for (const GuardedRegion& region : packager.regions()) {
    word_boxes += region.word_box ? 1u : 0u;
  }
  EXPECT_EQ(word_boxes, 2u);
}

// Oversized Text rects never merge into word boxes with glyphs.
TEST(GuardBandTest, OversizedTextRectsDoNotCluster) {
  GuardBandPackager packager;
  ASSERT_TRUE(packager.configure(test_config()));
  const PlutoRect rects[2] = {PlutoRect{8, 8, 200, 100},
                                PlutoRect{20, 120, 6, 6}};
  const PlutoRefreshClass classes[2] = {kPlutoRefreshText,
                                          kPlutoRefreshText};
  ASSERT_EQ(packager.package(rects, classes, 2), 2u);
}

// flag_map stays unimplemented pending legal review: configure() rejects ON
// with a warning and runs with the map off.
TEST(GuardBandTest, FlagMapRejectedPendingLegalReview) {
  GuardBandConfig config = test_config();
  config.flag_map_enabled = true;
  GuardBandPackager packager;
  ASSERT_TRUE(packager.configure(config));
  EXPECT_FALSE(packager.config().flag_map_enabled);
}

// Word-box stability probe: the same word retyped (identical glyph damage,
// any arrival order) packages into BYTE-identical guarded regions —
// content box, class, word-box flag and every guard fringe rect — so the
// driven fringe geometry never wanders across repetitions.
TEST(GuardBandTest, RetypedWordReusesByteIdenticalGuardedRegions) {
  GuardBandPackager packager;
  ASSERT_TRUE(packager.configure(test_config()));

  const PlutoRect glyphs[3] = {PlutoRect{41, 9, 6, 6},
                                 PlutoRect{49, 9, 6, 6},
                                 PlutoRect{57, 9, 6, 6}};
  const PlutoRefreshClass classes[3] = {
      kPlutoRefreshText, kPlutoRefreshText, kPlutoRefreshText};
  ASSERT_EQ(packager.package(glyphs, classes, 3), 1u);
  const GuardedRegion first = packager.regions()[0];
  ASSERT_TRUE(first.word_box);

  const auto expect_identical = [&](const GuardedRegion& region,
                                    const char* what) {
    EXPECT_TRUE(rect_equals(region.content, first.content)) << what;
    EXPECT_EQ(region.cls, first.cls) << what;
    EXPECT_EQ(region.word_box, first.word_box) << what;
    ASSERT_EQ(region.guard_count, first.guard_count) << what;
    for (size_t g = 0; g < first.guard_count; ++g) {
      EXPECT_TRUE(rect_equals(region.guard[g].rect, first.guard[g].rect))
          << what << " guard " << g;
      EXPECT_EQ(region.guard[g].guard_null, first.guard[g].guard_null) << what;
    }
  };

  // Retype the word twice: identical output both times.
  for (int rep = 0; rep < 2; ++rep) {
    ASSERT_EQ(packager.package(glyphs, classes, 3), 1u);
    expect_identical(packager.regions()[0], "retype");
  }
  // Glyph arrival order must not matter either.
  const PlutoRect permuted[3] = {glyphs[2], glyphs[0], glyphs[1]};
  ASSERT_EQ(packager.package(permuted, classes, 3), 1u);
  expect_identical(packager.regions()[0], "permuted order");
}
