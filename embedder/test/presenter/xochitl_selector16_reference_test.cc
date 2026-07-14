#include "xochitl_selector16_reference.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>

#include <gtest/gtest.h>

namespace pluto::swtcon::xochitl_selector16_reference {
namespace {

struct Frame {
  explicit Frame(std::uint32_t fill = 0xff808080u)
      : argb(static_cast<std::size_t>(kPanelWidth) * kPanelHeight, fill) {}

  std::uint32_t &at(int x, int y) {
    return argb[static_cast<std::size_t>(y) * kPanelWidth + x];
  }

  std::vector<std::uint32_t> argb;
};

void expect_ok(StageError error) {
  EXPECT_EQ(static_cast<int>(error), static_cast<int>(StageError::kNone));
}

TEST(XochitlSelector16Reference,
     RoutingThresholdAndRoundedWorkerStripesMatchStock) {
  const WorkerPlan height_29 = make_worker_plan({33, 0, 34, 28});
  ASSERT_EQ(height_29.divisor, 1u);
  ASSERT_EQ(height_29.stripes.size(), 1u);
  EXPECT_EQ(height_29.stripes[0].left, 32);
  EXPECT_EQ(height_29.stripes[0].right, 47);
  EXPECT_EQ(height_29.stripes[0].top, 0);
  EXPECT_EQ(height_29.stripes[0].bottom, 31);

  const WorkerPlan height_30 = make_worker_plan({0, 0, 15, 29});
  ASSERT_EQ(height_30.divisor, 3u);
  ASSERT_EQ(height_30.stripes.size(), 3u);
  EXPECT_TRUE(height_30.stripes[0].empty());
  EXPECT_EQ(height_30.stripes[1].top, 0);
  EXPECT_EQ(height_30.stripes[1].bottom, 15);
  EXPECT_EQ(height_30.stripes[2].top, 16);
  EXPECT_EQ(height_30.stripes[2].bottom, 31);

  const WorkerPlan offset_height_30 = make_worker_plan({0, 15, 15, 44});
  ASSERT_EQ(offset_height_30.stripes.size(), 3u);
  EXPECT_EQ(offset_height_30.stripes[0].top, 0);
  EXPECT_EQ(offset_height_30.stripes[0].bottom, 15);
  EXPECT_EQ(offset_height_30.stripes[1].top, 16);
  EXPECT_EQ(offset_height_30.stripes[1].bottom, 31);
  EXPECT_EQ(offset_height_30.stripes[2].top, 32);
  EXPECT_EQ(offset_height_30.stripes[2].bottom, 47);
}

TEST(XochitlSelector16Reference,
     PersistentScratchDimensionsAndInitialBytesAreExact) {
  Scratch scratch;
  EXPECT_EQ(scratch.coarse.size(), 101760u);    // 240 * 424, calloc 0x18d80
  EXPECT_EQ(scratch.selector.size(), 1628160u); // 960 * 1696, 0x18d800
  EXPECT_TRUE(std::all_of(scratch.coarse.begin(), scratch.coarse.end(),
                          [](std::uint8_t value) { return value == 0u; }));
  EXPECT_TRUE(std::all_of(scratch.selector.begin(), scratch.selector.end(),
                          [](std::uint8_t value) { return value == 0u; }));
}

TEST(XochitlSelector16Reference, CoarseFlagsUseRgbGrayExtremesAndIgnoreAlpha) {
  Frame frame;
  Scratch scratch;
  scratch.coarse_at(0, 0) = 3;

  frame.at(4, 4) = 0x00f0f0f0u; // alpha ignored, >=240 => bit 0
  frame.at(5, 4) = 0x000f0f0fu; // alpha ignored, <=15 => bit 1
  frame.at(6, 4) = 0x00fffefdu; // non-gray => neither bit
  frame.at(8, 8) = 0x00ffffffu;
  frame.at(9, 8) = 0x00000000u;
  frame.at(12, 12) = 0x00efefefu; // 239 => neither
  frame.at(13, 12) = 0x00101010u; // 16 => neither

  expect_ok(run_coarse_stage(frame.argb, {0, 0, 15, 15}, &scratch));

  EXPECT_EQ(scratch.coarse_at(0, 0), 0u); // stage clears its covered cells
  EXPECT_EQ(scratch.coarse_at(1, 1), 3u);
  EXPECT_EQ(scratch.coarse_at(2, 2), 3u);
  EXPECT_EQ(scratch.coarse_at(3, 3), 0u);
}

TEST(XochitlSelector16Reference,
     InteriorTransientClassesMatchOpaqueSpecialAndNeighborhoodRules) {
  Frame frame;
  Scratch scratch;
  frame.at(4, 4) = 0xffffffffu;
  frame.at(5, 4) = 0xff000000u;
  frame.at(6, 4) = 0xff010203u;
  frame.at(7, 4) = 0xff808080u;
  frame.at(8, 4) = 0x00ffffffu; // not exact opaque white
  frame.at(12, 12) = 0xff808080u;
  scratch.coarse_at(3, 3) = 3;

  expect_ok(run_classify_stage(frame.argb, {0, 0, 15, 15}, &scratch));

  EXPECT_EQ(scratch.selector_at(4, 4), 1u);
  EXPECT_EQ(scratch.selector_at(5, 4), 2u);
  EXPECT_EQ(scratch.selector_at(6, 4), 4u);
  EXPECT_EQ(scratch.selector_at(7, 4), 3u);
  EXPECT_EQ(scratch.selector_at(8, 4), 3u);
  EXPECT_EQ(scratch.selector_at(12, 12), 0u);
}

TEST(XochitlSelector16Reference,
     ResolveBlockDefaultHasExactClassThreeThresholdAndClassFourVeto) {
  Frame frame;
  Scratch scratch;
  const Stripe block{0, 0, 15, 15};

  for (int x = 0; x < 15; ++x) {
    scratch.selector_at(x, 0) = 3;
  }
  expect_ok(run_resolve_stage(frame.argb, block, &scratch));
  EXPECT_EQ(scratch.selector_at(8, 8), 0xffu);

  std::fill(scratch.selector.begin(), scratch.selector.end(), 0u);
  for (int x = 0; x < 16; ++x) {
    scratch.selector_at(x, 0) = 3;
  }
  expect_ok(run_resolve_stage(frame.argb, block, &scratch));
  EXPECT_EQ(scratch.selector_at(8, 8), 0x00u);

  std::fill(scratch.selector.begin(), scratch.selector.end(), 0u);
  scratch.selector_at(4, 4) = 4;
  expect_ok(run_resolve_stage(frame.argb, block, &scratch));
  EXPECT_EQ(scratch.selector_at(8, 8), 0x00u);
}

TEST(XochitlSelector16Reference,
     ExactBlackWhiteRunsOverrideDefaultAcrossPanelAndBlockBoundaries) {
  Frame frame;
  Scratch scratch;
  const Stripe two_blocks{0, 0, 31, 15};
  scratch.selector_at(4, 4) = 4;  // force block 0 default to 0
  scratch.selector_at(20, 4) = 4; // force block 1 default to 0

  frame.at(0, 0) = 0xff000000u;
  frame.at(1, 0) = 0xffffffffu;
  frame.at(15, 0) = 0xff000000u;
  frame.at(16, 0) = 0xffffffffu;
  frame.at(20, 0) = 0xff000000u;

  expect_ok(run_resolve_stage(frame.argb, two_blocks, &scratch));

  EXPECT_EQ(scratch.selector_at(0, 0), 0xffu);  // x==0 special case
  EXPECT_EQ(scratch.selector_at(1, 0), 0xffu);  // previous is also special
  EXPECT_EQ(scratch.selector_at(15, 0), 0x00u); // singleton special
  EXPECT_EQ(scratch.selector_at(16, 0), 0xffu); // crosses 16px block edge
  EXPECT_EQ(scratch.selector_at(20, 0), 0x00u); // singleton special
}

TEST(XochitlSelector16Reference,
     ClassificationSkipsFixedFourPixelPanelBorderThenResolveFinalizesIt) {
  Frame frame;
  Scratch scratch;
  const Stripe top_left{0, 0, 15, 15};
  scratch.selector_at(0, 8) = 0xa5u;
  scratch.selector_at(8, 0) = 0xa5u;

  expect_ok(run_coarse_stage(frame.argb, top_left, &scratch));
  expect_ok(run_classify_stage(frame.argb, top_left, &scratch));
  EXPECT_EQ(scratch.selector_at(0, 8), 0xa5u);
  EXPECT_EQ(scratch.selector_at(8, 0), 0xa5u);
  EXPECT_EQ(scratch.selector_at(4, 4), 3u);
  EXPECT_EQ(scratch.selector_at(15, 15), 3u);

  expect_ok(run_resolve_stage(frame.argb, top_left, &scratch));
  EXPECT_EQ(scratch.selector_at(0, 8), 0x00u);
  EXPECT_EQ(scratch.selector_at(8, 0), 0x00u);

  const Stripe bottom_right{944, 1680, 959, 1695};
  scratch.selector_at(956, 1688) = 0xa5u;
  scratch.selector_at(952, 1692) = 0xa5u;
  expect_ok(run_coarse_stage(frame.argb, bottom_right, &scratch));
  expect_ok(run_classify_stage(frame.argb, bottom_right, &scratch));
  EXPECT_EQ(scratch.selector_at(956, 1688), 0xa5u);
  EXPECT_EQ(scratch.selector_at(952, 1692), 0xa5u);
  EXPECT_EQ(scratch.selector_at(955, 1691), 3u);
  expect_ok(run_resolve_stage(frame.argb, bottom_right, &scratch));
  EXPECT_EQ(scratch.selector_at(956, 1688), 0x00u);
  EXPECT_EQ(scratch.selector_at(952, 1692), 0x00u);
}

TEST(XochitlSelector16Reference,
     LegalThreeWorkerSchedulesCanObserveDifferentLiveCoarseHaloState) {
  Frame frame;
  for (int y = 0; y < 12; ++y) {
    for (int x = 0; x < kPanelWidth; ++x) {
      frame.at(x, y) = 0xff000000u;
    }
  }
  const WorkerPlan plan = make_worker_plan({0, 0, 959, 47});
  ASSERT_EQ(plan.divisor, 3u);
  ASSERT_EQ(plan.stripes.size(), 3u);
  ASSERT_TRUE(!plan.stripes[0].empty());
  ASSERT_TRUE(!plan.stripes[1].empty());

  Scratch retained_halo;
  Scratch refreshed_halo;
  for (int x = 0; x < kCoarseWidth; ++x) {
    retained_halo.coarse_at(x, 4) = 1u;
    refreshed_halo.coarse_at(x, 4) = 1u;
  }

  // Legal schedule A: worker 0 reaches classify/resolve before worker 1 has
  // refreshed its first coarse row.  The retained row supplies white bit 0,
  // while worker 0's black rows supply bit 1.
  expect_ok(run_coarse_stage(frame.argb, plan.stripes[0], &retained_halo));
  expect_ok(run_classify_stage(frame.argb, plan.stripes[0], &retained_halo));
  expect_ok(run_resolve_stage(frame.argb, plan.stripes[0], &retained_halo));

  // Legal schedule B: worker 1 completes its coarse stage first.  Its current
  // mid-gray pixels clear the same halo row before worker 0 classifies.
  expect_ok(run_coarse_stage(frame.argb, plan.stripes[0], &refreshed_halo));
  expect_ok(run_coarse_stage(frame.argb, plan.stripes[1], &refreshed_halo));
  expect_ok(run_classify_stage(frame.argb, plan.stripes[0], &refreshed_halo));
  expect_ok(run_resolve_stage(frame.argb, plan.stripes[0], &refreshed_halo));

  EXPECT_EQ(retained_halo.selector_at(16, 12), 0xffu);
  EXPECT_EQ(refreshed_halo.selector_at(16, 12), 0x00u);
}

TEST(XochitlSelector16Reference, InvalidInputsFailClosed) {
  Frame frame;
  Scratch scratch;
  EXPECT_EQ(
      static_cast<int>(run_worker(frame.argb, {-1, 0, 0, 0}, 0, 1, &scratch)),
      static_cast<int>(StageError::kInvalidGeometry));
  EXPECT_EQ(
      static_cast<int>(run_worker(frame.argb, {0, 0, 0, 0}, 1, 1, &scratch)),
      static_cast<int>(StageError::kInvalidWorker));
  EXPECT_EQ(static_cast<int>(
                run_worker(std::span<const std::uint32_t>(frame.argb.data(), 1),
                           {0, 0, 0, 0}, 0, 1, &scratch)),
            static_cast<int>(StageError::kArgbTooSmall));
}

} // namespace
} // namespace pluto::swtcon::xochitl_selector16_reference
