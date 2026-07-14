#include "xochitl_fast_state_reference.h"

#include "xochitl_color_mapper_reference.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

#include <gtest/gtest.h>

namespace pluto::swtcon::xochitl_fast_reference {
namespace {

struct Fixture {
  explicit Fixture(int panel_width = 10, int panel_height = 4)
      : panel_width(panel_width),
        panel_height(panel_height),
        raw_stride(16),
        raw_rows(static_cast<std::size_t>(panel_height + 2)),
        ab_stride(static_cast<std::size_t>(panel_width + 8)),
        ab_rows(static_cast<std::size_t>(panel_height + 2)),
        raw(raw_stride * raw_rows, 0),
        ab(ab_stride * ab_rows * 2, 0) {}

  std::uint16_t& a(int x, int y) {
    return ab[2u * (static_cast<std::size_t>(y) * ab_stride + x)];
  }
  std::uint16_t& b(int x, int y) {
    return ab[2u * (static_cast<std::size_t>(y) * ab_stride + x) + 1u];
  }
  std::uint8_t& r(int x, int y) {
    return raw[static_cast<std::size_t>(y) * raw_stride + x];
  }
  Operation operation(InclusiveRect update, float temperature = 25.0f) {
    return {.panel_width = panel_width,
            .panel_height = panel_height,
            .update = update,
            .raw = raw,
            .raw_stride = raw_stride,
            .ab = ab,
            .ab_stride = ab_stride,
            .ab_storage_height = ab_rows,
            .temperature_c = temperature};
  }

  int panel_width;
  int panel_height;
  std::size_t raw_stride;
  std::size_t raw_rows;
  std::size_t ab_stride;
  std::size_t ab_rows;
  std::vector<std::uint8_t> raw;
  std::vector<std::uint16_t> ab;
};

TEST(XochitlFastStateReference,
     ColdLowToWhiteInitializesThreeStepContinuationAndPhysicalState) {
  Fixture f;
  f.a(1, 1) = 2;
  f.r(0, 0) = 7;

  const Result result = map_source(f.operation({1, 1, 1, 1}, 37.9f));

  ASSERT_TRUE(result);
  ASSERT_EQ(result.transitions.size(), 16u);
  EXPECT_EQ(result.transitions[0], transition(2, 28));
  EXPECT_EQ(f.a(1, 1), 28u);
  EXPECT_EQ(f.b(1, 1), 0x0903u);  // q=+576, flags=3
  EXPECT_TRUE(result.needs_continuation);
}

TEST(XochitlFastStateReference,
     HotSameHighEndpointUsesPartnerThirtyAndDecrementsCountdown) {
  Fixture f;
  f.a(1, 1) = 28;
  f.b(1, 1) = 2;
  f.r(0, 0) = 0x87;

  const Result result = map_source(f.operation({1, 1, 1, 1}, 38.0f));

  ASSERT_TRUE(result);
  EXPECT_EQ(result.transitions[0], transition(28, 30));
  EXPECT_EQ(f.a(1, 1), 0x009eu);  // raw marker | physical state 30
  EXPECT_EQ(f.b(1, 1), 0x0b01u);  // q=+704, flags 2->1
}

TEST(XochitlFastStateReference,
     SameEndpointWithoutCountdownDecaysHistoryBySixteenWithoutClamp) {
  Fixture f;
  f.a(1, 1) = 2;
  f.b(1, 1) = static_cast<std::uint16_t>(100u << 2);
  f.r(0, 0) = 0;

  const Result result = map_source(f.operation({1, 1, 1, 1}));

  ASSERT_TRUE(result);
  EXPECT_EQ(result.transitions[0], transition(2, 2));
  EXPECT_EQ(f.a(1, 1), 2u);
  EXPECT_EQ(f.b(1, 1), static_cast<std::uint16_t>(84u << 2));
  EXPECT_FALSE(result.needs_continuation);
}

TEST(XochitlFastStateReference,
     IntermediateSourceStateForcesCountdownResetEvenWithinLowGroup) {
  Fixture f;
  f.a(1, 1) = 10;

  const Result result = map_source(f.operation({1, 1, 1, 1}));

  ASSERT_TRUE(result);
  EXPECT_EQ(result.transitions[0], transition(10, 2));
  EXPECT_EQ(f.a(1, 1), 2u);
  EXPECT_EQ(f.b(1, 1), 3u);
  EXPECT_TRUE(result.encountered_mid_state);
  EXPECT_TRUE(result.needs_continuation);
}

TEST(XochitlFastStateReference,
     OnePixelRequestConsumesAndCommitsEightByTwoOperationLocalLanes) {
  Fixture f;
  for (int y = 0; y < 2; ++y) {
    for (int x = 0; x < 8; ++x) {
      f.a(1 + x, 1 + y) = 2;
      f.r(x, y) = static_cast<std::uint8_t>((x + y) & 1 ? 7 : 0);
    }
  }

  const Result result = map_source(f.operation({1, 1, 1, 1}));

  ASSERT_TRUE(result);
  EXPECT_EQ(result.execution.left, 1);
  EXPECT_EQ(result.execution.top, 1);
  EXPECT_EQ(result.execution.right, 8);
  EXPECT_EQ(result.execution.bottom, 2);
  ASSERT_EQ(result.transitions.size(), 16u);
  for (int y = 0; y < 2; ++y) {
    for (int x = 0; x < 8; ++x) {
      const bool white = ((x + y) & 1) != 0;
      EXPECT_EQ(f.a(1 + x, 1 + y), white ? 28u : 2u);
    }
  }
}

TEST(XochitlFastStateReference,
     SourceThenContinuationAdvancesExactColdHighSequence) {
  Fixture f;
  for (int y = 0; y < 2; ++y) {
    for (int x = 0; x < 8; ++x) {
      f.a(1 + x, 1 + y) = 2;
      f.r(x, y) = 7;
    }
  }
  ASSERT_TRUE(map_source(f.operation({1, 1, 1, 1})));
  EXPECT_EQ(f.a(1, 1), 28u);
  EXPECT_EQ(f.b(1, 1), 0x0903u);

  Result continuation = map_continuation(f.operation({1, 1, 1, 1}));
  ASSERT_TRUE(continuation);
  EXPECT_EQ(continuation.transitions[0], transition(28, 30));
  EXPECT_EQ(f.a(1, 1), 30u);
  EXPECT_EQ(f.b(1, 1), 0x1202u);  // q=1152, flags=2

  continuation = map_continuation(f.operation({1, 1, 1, 1}));
  ASSERT_TRUE(continuation);
  EXPECT_EQ(f.b(1, 1), 0x1b01u);  // q=1728, flags=1
  continuation = map_continuation(f.operation({1, 1, 1, 1}));
  ASSERT_TRUE(continuation);
  EXPECT_EQ(f.b(1, 1), 0x2400u);  // q=2304, flags=0
  EXPECT_FALSE(continuation.needs_continuation);
}

TEST(XochitlFastStateReference,
     ZeroFlagContinuationUsesAuxiliaryTwentySevenAndPreservesAState) {
  Fixture f;
  f.a(1, 1) = 0x80u | 30u;
  f.b(1, 1) = static_cast<std::uint16_t>(100u << 2);

  const Result result = map_continuation(f.operation({1, 1, 1, 1}));

  ASSERT_TRUE(result);
  EXPECT_EQ(result.transitions[0], transition(30, 27));
  EXPECT_EQ(f.a(1, 1), 0x80u | 30u);
  EXPECT_EQ(f.b(1, 1), static_cast<std::uint16_t>(84u << 2));
}

TEST(XochitlFastStateReference,
     FastPhysicalStateBecomesTheFollowingColourMappersSource) {
  Fixture f;
  for (int y = 0; y < 2; ++y) {
    for (int x = 0; x < 8; ++x) {
      f.a(1 + x, 1 + y) = 2;
      f.r(x, y) = 7;
    }
  }
  ASSERT_TRUE(map_source(f.operation({1, 1, 1, 1})));
  ASSERT_EQ(f.a(1, 1), 28u);

  constexpr std::array<std::uint8_t, 16> palette = {
      2, 12, 4, 20, 8, 16, 24, 28, 15, 19, 2, 30, 32, 32, 32, 32};
  std::vector<std::uint8_t> colour_raw(f.raw.size(), 6);  // mapped 24
  std::vector<std::int16_t> delta(1024, 0);
  xochitl_reference::Operation colour = {
      .panel_width = f.panel_width,
      .panel_height = f.panel_height,
      .update = {1, 1, 1, 1},
      .raw = colour_raw,
      .raw_stride = f.raw_stride,
      .ab = f.ab,
      .ab_stride = f.ab_stride,
      .ab_storage_height = f.ab_rows,
      .palette = palette,
      .delta = delta};

  const xochitl_reference::Result truth =
      xochitl_reference::map_operation(colour);

  ASSERT_TRUE(truth);
  ASSERT_EQ(truth.transitions.size(), 16u);
  EXPECT_EQ(truth.transitions[0], xochitl_reference::mapper_transition(28, 24));
  EXPECT_EQ(f.a(1, 1), 24u);
}

TEST(XochitlFastStateReference, InvalidGeometryBuffersAndTemperatureFailClosed) {
  Fixture f;
  const auto before = f.ab;
  EXPECT_EQ(static_cast<int>(map_source(f.operation({-1, 0, 0, 0})).error),
            static_cast<int>(MapError::kInvalidGeometry));
  EXPECT_TRUE(f.ab == before);

  Operation short_raw = f.operation({0, 0, 0, 0});
  short_raw.raw = short_raw.raw.first(1);
  EXPECT_EQ(static_cast<int>(map_source(short_raw).error),
            static_cast<int>(MapError::kBufferTooSmall));
  EXPECT_TRUE(f.ab == before);

  Operation nan_temperature = f.operation({0, 0, 0, 0});
  nan_temperature.temperature_c =
      std::numeric_limits<float>::quiet_NaN();
  EXPECT_EQ(static_cast<int>(map_source(nan_temperature).error),
            static_cast<int>(MapError::kInvalidTemperature));
  EXPECT_TRUE(f.ab == before);
}

}  // namespace
}  // namespace pluto::swtcon::xochitl_fast_reference
