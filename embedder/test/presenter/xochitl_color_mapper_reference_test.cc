#include "xochitl_color_mapper_reference.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

#include <gtest/gtest.h>

namespace pluto::swtcon::xochitl_reference {
namespace {

constexpr std::array<std::uint8_t, 16> kMode2Palette = {
    2, 12, 4, 20, 8, 16, 24, 28, 15, 19, 2, 30, 32, 32, 32, 32};

struct Fixture {
  explicit Fixture(int width = 10, int height = 4)
      : width(width),
        height(height),
        raw_stride(16),
        raw_rows(static_cast<std::size_t>(height + 2)),
        ab_stride(static_cast<std::size_t>(width + 8)),
        ab_rows(static_cast<std::size_t>(height + 2)),
        raw(raw_stride * raw_rows, 0),
        ab(ab_stride * ab_rows * 2, 0),
        delta(1024, 0) {}

  std::uint16_t& a(int x, int y) {
    return ab[2 * (static_cast<std::size_t>(y) * ab_stride + x)];
  }
  std::uint16_t& b(int x, int y) {
    return ab[2 * (static_cast<std::size_t>(y) * ab_stride + x) + 1];
  }
  std::uint8_t& r(int x, int y) {
    return raw[static_cast<std::size_t>(y) * raw_stride + x];
  }
  Operation operation(InclusiveRect update) {
    return {.panel_width = width,
            .panel_height = height,
            .update = update,
            .raw = raw,
            .raw_stride = raw_stride,
            .ab = ab,
            .ab_stride = ab_stride,
            .ab_storage_height = ab_rows,
            .palette = kMode2Palette,
            .delta = delta};
  }

  int width;
  int height;
  std::size_t raw_stride;
  std::size_t raw_rows;
  std::size_t ab_stride;
  std::size_t ab_rows;
  std::vector<std::uint8_t> raw;
  std::vector<std::uint16_t> ab;
  std::vector<std::int16_t> delta;
};

std::vector<std::vector<std::uint8_t>> zero_delta_phases() {
  return std::vector<std::vector<std::uint8_t>>(1024,
                                                std::vector<std::uint8_t>{0});
}

TEST(XochitlColorMapperReference,
     DeltaBuilderPinsAllNineTemperatureRecordsAndTransitionOrientation) {
  constexpr std::array<std::int16_t, 9> kNegativeDriveExpected = {
      46, 42, 39, 38, 37, 38, 42, 44, 49};
  const auto negative_transition = mapper_transition(2, 28);
  const auto positive_transition = mapper_transition(28, 2);

  for (std::size_t bin = 0; bin < kNegativeDriveExpected.size(); ++bin) {
    auto phases = zero_delta_phases();
    phases[negative_transition] = {1};  // voltage -24
    phases[positive_transition] = {6};  // voltage +24
    const DeltaTableResult result = build_delta_table(phases, bin);

    ASSERT_TRUE(result);
    EXPECT_EQ(result.values[negative_transition], kNegativeDriveExpected[bin]);
    EXPECT_EQ(result.values[positive_transition], -kNegativeDriveExpected[bin]);
    EXPECT_EQ(result.values[mapper_transition(0, 0)], 0);
  }
}

TEST(XochitlColorMapperReference,
     DeltaBuilderPreservesPhaseOrderAndSeparateFmaProduct) {
  auto phases = zero_delta_phases();
  const auto transition = mapper_transition(3, 12);
  phases[transition] = {1, 1, 1, 1, 1};

  const DeltaTableResult bin0 = build_delta_table(phases, 0);
  const DeltaTableResult bin4 = build_delta_table(phases, 4);
  const DeltaTableResult bin8 = build_delta_table(phases, 8);

  ASSERT_TRUE(bin0);
  ASSERT_TRUE(bin4);
  ASSERT_TRUE(bin8);
  EXPECT_EQ(bin0.values[transition], 232);
  EXPECT_EQ(bin4.values[transition], 186);
  EXPECT_EQ(bin8.values[transition], 247);
}

TEST(XochitlColorMapperReference,
     DeltaBuilderRejectsCodeSevenAndMalformedRecordsWithoutPartialTable) {
  auto phases = zero_delta_phases();
  phases[17] = {1, 7, 6};
  DeltaTableResult result = build_delta_table(phases, 4);
  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(DeltaBuildError::kUnsupportedPhaseCode));
  EXPECT_EQ(result.failing_transition, 17u);
  EXPECT_TRUE(std::all_of(result.values.begin(), result.values.end(),
                          [](std::int16_t value) { return value == 0; }));

  phases = zero_delta_phases();
  phases[23].clear();
  result = build_delta_table(phases, 4);
  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(DeltaBuildError::kEmptyPhaseSequence));
  EXPECT_EQ(result.failing_transition, 23u);

  phases = zero_delta_phases();
  EXPECT_EQ(
      static_cast<int>(build_delta_table(phases, 9).error),
      static_cast<int>(DeltaBuildError::kInvalidTemperatureBin));
  EXPECT_EQ(
      static_cast<int>(build_delta_table(
                           std::span<const std::vector<std::uint8_t>>(phases)
                               .first(1023),
                           4)
                           .error),
      static_cast<int>(DeltaBuildError::kInvalidTransitionCount));

  phases = zero_delta_phases();
  phases[31] = std::vector<std::uint8_t>(1024, 1);
  result = build_delta_table(phases, 0);
  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(DeltaBuildError::kOutOfRange));
  EXPECT_EQ(result.failing_transition, 31u);
  EXPECT_TRUE(std::all_of(result.values.begin(), result.values.end(),
                          [](std::int16_t value) { return value == 0; }));
}

TEST(XochitlColorMapperReference, NormalFixtureMapsZeroToLogicalTwentyEight) {
  Fixture f;
  std::fill(f.raw.begin(), f.raw.end(), 7);  // mode-2 palette[7] = 28
  f.delta[mapper_transition(0, 28)] = 3;

  const Result result = map_operation(f.operation({1, 1, 1, 1}));

  ASSERT_TRUE(result);
  ASSERT_EQ(result.transitions.size(), 16u);
  EXPECT_EQ(result.width, 8);
  EXPECT_EQ(result.height, 2);
  EXPECT_EQ(result.transitions[0], mapper_transition(0, 28));
  EXPECT_EQ(f.a(1, 1), 28u);
  EXPECT_EQ(f.b(1, 1), 12u);
}

TEST(XochitlColorMapperReference,
     Force27FixtureDrivesAuxiliaryStateButCommitsLogicalMappedState) {
  Fixture f;
  for (int y = 0; y < f.height; ++y) {
    for (int x = 0; x < f.width; ++x) {
      f.a(x, y) = 2;
    }
  }
  f.b(1, 1) = 3;  // low flags survive only the force27 path
  const auto transition = mapper_transition(2, 27);
  f.delta[transition] = -2;

  const Result result = map_operation(f.operation({1, 1, 1, 1}));

  ASSERT_TRUE(result);
  ASSERT_EQ(result.transitions.size(), 16u);
  EXPECT_EQ(result.transitions[0], transition);
  EXPECT_EQ(f.a(1, 1), 2u);       // logical palette state, never auxiliary 27
  EXPECT_EQ(f.b(1, 1), 0xfffbu);  // (-2 << 2) plus retained flags 3
}

TEST(XochitlColorMapperReference,
     Pair31FixtureUsesWhitePartnerWithoutSettingContinuationMarker) {
  Fixture f;
  std::fill(f.raw.begin(), f.raw.end(), 7);
  for (int y = 0; y < f.height; ++y) {
    for (int x = 0; x < f.width; ++x) {
      f.a(x, y) = 28;
    }
  }
  f.a(2, 1) = 2;            // old high cross is 4, not 5
  f.a(1, 1) = 0x80u | 28u;  // old exact-white continuity marker
  f.r(0, 0) = 0x80u | 7u;   // local first lane, mapped state 28
  f.b(1, 1) = 0x13;         // ASR2 = 4; pair31 does not retain low flags
  const auto transition = mapper_transition(28, 31);
  f.delta[transition] = 5;

  const Result result = map_operation(f.operation({1, 1, 1, 1}));

  ASSERT_TRUE(result);
  ASSERT_EQ(result.transitions.size(), 16u);
  EXPECT_EQ(result.transitions[0], transition);
  EXPECT_EQ(f.a(1, 1), 0x9cu);  // mapped 28 | raw bit7; pair31 suppresses bit6
  EXPECT_EQ(f.b(1, 1), 0x24u);  // (4 + 5) << 2, low flags cleared
}

TEST(XochitlColorMapperReference,
     SetBit6UsesNewHighCrossAndRawMarkerEvenFromLowSource) {
  Fixture f;
  std::fill(f.raw.begin(), f.raw.end(), 7);  // every mapped state is high 28
  for (int y = 0; y < f.height; ++y) {
    for (int x = 0; x < f.width; ++x) {
      f.a(x, y) = 2;  // old source is low and never equals mapped state 28
    }
  }
  f.r(0, 0) = 0x80u | 7u;

  const Result result = map_operation(f.operation({1, 1, 1, 1}));

  ASSERT_TRUE(result);
  ASSERT_EQ(result.transitions.size(), 16u);
  EXPECT_EQ(result.transitions[0], mapper_transition(2, 28));
  EXPECT_EQ(f.a(1, 1), 0xdcu);  // mapped 28 | raw bit7 | newly set bit6
  EXPECT_EQ(f.b(1, 1), 0u);
}

TEST(XochitlColorMapperReference,
     WhiteContinuityWithoutNewPartnerForces27AndCarriesBit6) {
  Fixture f;
  std::fill(f.raw.begin(), f.raw.end(), 7);
  for (int y = 0; y < f.height; ++y) {
    for (int x = 0; x < f.width; ++x) {
      f.a(x, y) = 28;
    }
  }
  f.a(2, 2) = 2;  // diagonal breaks same9, not the von-Neumann cross
  f.a(1, 1) = 0xc0u | 28u;
  f.r(0, 0) = 0x80u | 7u;
  f.b(1, 1) = 2;

  const Result result = map_operation(f.operation({1, 1, 1, 1}));

  ASSERT_TRUE(result);
  ASSERT_EQ(result.transitions.size(), 16u);
  EXPECT_EQ(result.transitions[0], mapper_transition(28, 27));
  EXPECT_EQ(f.a(1, 1), 0xdcu);  // logical 28, raw bit7, carried bit6
  EXPECT_EQ(f.b(1, 1), 2u);     // force27 alone retains the low flags
}

TEST(XochitlColorMapperReference,
     LaneDomainHaloContributesEqualAndHighWithoutOutOfBoundsReads) {
  Fixture f(1, 1);
  for (int y = 0; y < 2; ++y) {
    for (int x = 0; x < 8; ++x) {
      f.a(x, y) = 2;
    }
  }
  f.b(0, 0) = 2;
  const auto transition = mapper_transition(2, 27);

  const Result result = map_operation(f.operation({0, 0, 0, 0}));

  ASSERT_TRUE(result);
  ASSERT_EQ(result.transitions.size(), 16u);
  EXPECT_EQ(result.transitions[0], transition);
  EXPECT_EQ(f.a(0, 0), 2u);
  EXPECT_EQ(f.b(0, 0), 2u);  // force27 retains the low two history flags
}

TEST(XochitlColorMapperReference,
     OneByOneRequestConsumesAndCommitsEightByTwoLocalLanes) {
  Fixture f;
  for (int x = 0; x < 8; ++x) {
    f.r(x, 0) = static_cast<std::uint8_t>(x);
    f.r(x, 1) = static_cast<std::uint8_t>(7 - x);
  }

  const Result result = map_operation(f.operation({1, 1, 1, 1}));

  ASSERT_TRUE(result);
  ASSERT_EQ(result.transitions.size(), 16u);
  EXPECT_EQ(result.execution.left, 1);
  EXPECT_EQ(result.execution.top, 1);
  EXPECT_EQ(result.execution.right, 8);
  EXPECT_EQ(result.execution.bottom, 2);
  const std::array<std::uint16_t, 8> forward = {2, 12, 4, 20,
                                                8, 16, 24, 28};
  const std::array<std::uint16_t, 8> reverse = {28, 24, 16, 8,
                                                20, 4, 12, 2};
  for (int x = 0; x < 8; ++x) {
    EXPECT_EQ(result.transitions[x], forward[x]);
    EXPECT_EQ(result.transitions[8 + x], reverse[x]);
    EXPECT_EQ(f.a(1 + x, 1), forward[x]);
    EXPECT_EQ(f.a(1 + x, 2), reverse[x]);
  }
  EXPECT_EQ(f.a(0, 1), 0u);
  EXPECT_EQ(f.b(0, 1), 0u);
}

TEST(XochitlColorMapperReference,
     AdjacentLanesObserveOneFrozenOperationSnapshot) {
  Fixture f;
  for (int y = 0; y < f.height; ++y) {
    for (int x = 0; x < f.width; ++x) {
      f.a(x, y) = 2;
    }
  }
  f.a(1, 1) = 0;  // first lane will commit 2; second must still see old 0

  const Result result = map_operation(f.operation({1, 1, 2, 1}));

  ASSERT_TRUE(result);
  ASSERT_EQ(result.transitions.size(), 16u);
  EXPECT_EQ(result.transitions[0], mapper_transition(0, 2));
  EXPECT_EQ(result.transitions[1], mapper_transition(2, 2));
  EXPECT_EQ(f.a(1, 1), 2u);
  EXPECT_EQ(f.a(2, 1), 2u);
}

TEST(XochitlColorMapperReference,
     SentinelInPaddedLaneFailsClosedWithoutAnyHistoryCommit) {
  Fixture f;
  f.r(7, 0) = 12;  // mode-2 palette[12] is unsupported sentinel 32
  const auto before = f.ab;

  const Result result = map_operation(f.operation({1, 1, 1, 1}));

  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(MapError::kUnsupportedPaletteState));
  EXPECT_TRUE(result.transitions.empty());
  EXPECT_TRUE(f.ab == before);
}

TEST(XochitlColorMapperReference, NegativeHistoryUsesAArch64ArithmeticShift) {
  Fixture f;
  f.a(2, 1) = 0;  // next local lane mismatch avoids force27 at center
  f.a(1, 1) = 2;
  f.b(1, 1) = 0xffffu;  // int16 -1; ASR2 remains -1, not zero

  const Result result = map_operation(f.operation({1, 1, 1, 1}));

  ASSERT_TRUE(result);
  ASSERT_EQ(result.transitions.size(), 16u);
  EXPECT_EQ(result.transitions[0], mapper_transition(2, 2));
  EXPECT_EQ(f.b(1, 1), 0xfffcu);
}

TEST(XochitlColorMapperReference,
     MapperTransitionAndWaveformPhaseAxesAreIntentionallyTransposed) {
  constexpr auto transition = mapper_transition(3, 12);
  static_assert(transition == 3 * 32 + 12);
  static_assert(waveform_phase_offset(transition) == 12 * 32 + 3);
  EXPECT_EQ(transition, 108u);
  EXPECT_EQ(waveform_phase_offset(transition), 387u);
  EXPECT_NE(static_cast<std::size_t>(transition),
            waveform_phase_offset(transition));
}

TEST(XochitlColorMapperReference, InvalidGeometryAndShortBuffersFailClosed) {
  Fixture f;
  const auto before = f.ab;
  Operation bad_rect = f.operation({-1, 0, 0, 0});
  EXPECT_EQ(static_cast<int>(map_operation(bad_rect).error),
            static_cast<int>(MapError::kInvalidGeometry));
  EXPECT_TRUE(f.ab == before);

  Operation short_raw = f.operation({0, 0, 0, 0});
  short_raw.raw = short_raw.raw.first(1);
  EXPECT_EQ(static_cast<int>(map_operation(short_raw).error),
            static_cast<int>(MapError::kBufferTooSmall));
  EXPECT_TRUE(f.ab == before);
}

TEST(XochitlColorMapperReference,
     IndependentRawAndAbStridesNeverTouchGuardColumns) {
  constexpr int kWidth = 2;
  constexpr int kHeight = 2;
  constexpr std::size_t kRawStride = 8;
  constexpr std::size_t kAbStride = 10;
  constexpr std::size_t kAbRows = 3;
  std::vector<std::uint8_t> raw(kRawStride * 2, 0);
  std::vector<std::uint16_t> ab(kAbStride * kAbRows * 2, 0xbeefu);
  std::vector<std::int16_t> delta(1024, 0);
  for (int y = 0; y < 2; ++y) {
    for (int x = 0; x < 8; ++x) {
      const std::size_t i =
          2 * (static_cast<std::size_t>(y) * kAbStride + x);
      ab[i] = 2;
      ab[i + 1] = 0;
    }
  }
  const Operation operation = {.panel_width = kWidth,
                               .panel_height = kHeight,
                               .update = {0, 0, 0, 0},
                               .raw = raw,
                               .raw_stride = kRawStride,
                               .ab = ab,
                               .ab_stride = kAbStride,
                               .ab_storage_height = kAbRows,
                               .palette = kMode2Palette,
                               .delta = delta};

  const Result result = map_operation(operation);

  ASSERT_TRUE(result);
  ASSERT_EQ(result.transitions.size(), 16u);
  EXPECT_EQ(result.transitions[0], mapper_transition(2, 27));
  for (int y = 0; y < 2; ++y) {
    for (std::size_t x = 8; x < kAbStride; ++x) {
      const std::size_t i = 2 * (static_cast<std::size_t>(y) * kAbStride + x);
      EXPECT_EQ(ab[i], 0xbeefu);
      EXPECT_EQ(ab[i + 1], 0xbeefu);
    }
  }
  for (std::size_t x = 0; x < kAbStride; ++x) {
    const std::size_t i = 2 * (2 * kAbStride + x);
    EXPECT_EQ(ab[i], 0xbeefu);
    EXPECT_EQ(ab[i + 1], 0xbeefu);
  }
}

}  // namespace
}  // namespace pluto::swtcon::xochitl_reference
