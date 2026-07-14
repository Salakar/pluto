#include "presenter/swtcon/fast_rail_admit_kernels.h"

#include "presenter/swtcon/swtcon_waveform.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <cstdint>
#include <random>
#include <vector>

namespace {

using pluto::swtcon::fast_rail_levels_valid;
using pluto::swtcon::fast_rail_levels_valid_scalar;
using pluto::swtcon::fast_rail_start_row;
using pluto::swtcon::fast_rail_start_row_scalar;
using pluto::swtcon::FastRailStartRowResult;
using pluto::swtcon::kMode7FastBlackEndpoint;
using pluto::swtcon::kMode7FastWhiteEndpoint;

TEST(FastRailAdmitKernelsTest,
     ValidationMatchesScalarForEveryPaddedWidthAndInvalidLane) {
  std::mt19937 rng(0xfa57ad17u);
  for (int width = 1; width <= 64; ++width) {
    constexpr int kHeight = 5;
    const std::size_t stride = static_cast<std::size_t>(width) + 17u;
    std::vector<std::uint8_t> levels(stride * kHeight, 0xa5u);
    for (int y = 0; y < kHeight; ++y) {
      for (int x = 0; x < width; ++x) {
        const std::uint8_t endpoint = ((x + y) & 1) == 0
                                          ? kMode7FastBlackEndpoint
                                          : kMode7FastWhiteEndpoint;
        levels[static_cast<std::size_t>(y) * stride + x] =
            static_cast<std::uint8_t>(endpoint | (rng() & 0xe0u));
      }
    }
    ASSERT_TRUE(
        fast_rail_levels_valid_scalar(levels.data(), stride, width, kHeight));
    ASSERT_TRUE(fast_rail_levels_valid(levels.data(), stride, width, kHeight));
    for (int y = 0; y < kHeight; ++y) {
      for (int x = 0; x < width; ++x) {
        std::uint8_t &lane = levels[static_cast<std::size_t>(y) * stride + x];
        const std::uint8_t saved = lane;
        lane = static_cast<std::uint8_t>((saved & 0xe0u) | 3u);
        EXPECT_FALSE(fast_rail_levels_valid_scalar(levels.data(), stride, width,
                                                   kHeight));
        EXPECT_FALSE(
            fast_rail_levels_valid(levels.data(), stride, width, kHeight));
        lane = saved;
      }
    }
    for (int y = 0; y < kHeight; ++y) {
      for (std::size_t x = static_cast<std::size_t>(width); x < stride; ++x) {
        EXPECT_EQ(levels[static_cast<std::size_t>(y) * stride + x], 0xa5u)
            << "padding y=" << y << " x=" << x;
      }
    }
  }
}

struct RowState {
  std::vector<std::uint8_t> levels;
  std::vector<std::uint8_t> prev;
  std::vector<std::uint8_t> next;
  std::vector<std::uint8_t> final_levels;
  std::vector<std::uint8_t> fnum;
  std::vector<std::uint8_t> drove;
};

FastRailStartRowResult run_scalar(RowState *state, int offset, int count) {
  return fast_rail_start_row_scalar(
      state->levels.data() + offset, state->prev.data() + offset,
      state->next.data() + offset, state->final_levels.data() + offset,
      state->fnum.data() + offset, state->drove.data() + offset, count);
}

FastRailStartRowResult run_dispatch(RowState *state, int offset, int count) {
  return fast_rail_start_row(
      state->levels.data() + offset, state->prev.data() + offset,
      state->next.data() + offset, state->final_levels.data() + offset,
      state->fnum.data() + offset, state->drove.data() + offset, count);
}

TEST(FastRailAdmitKernelsTest,
     StartRowMatchesScalarForTailsRandomStateAndCanaries) {
  constexpr int kOffset = 11;
  constexpr int kCanary = 19;
  std::mt19937 rng(0x51a7fa57u);
  for (int count = 1; count <= 64; ++count) {
    for (int iteration = 0; iteration < 128; ++iteration) {
      const std::size_t size =
          static_cast<std::size_t>(kOffset + count + kCanary);
      RowState reference;
      reference.levels.resize(size, 0xa5u);
      reference.prev.resize(size, 0xa5u);
      reference.next.resize(size, 0xa5u);
      reference.final_levels.resize(size, 0xa5u);
      reference.fnum.resize(size, 0xa5u);
      reference.drove.resize(size, 0xa5u);
      for (int x = 0; x < count; ++x) {
        const std::size_t lane = static_cast<std::size_t>(kOffset + x);
        const std::uint8_t endpoint = (rng() & 1u) == 0
                                          ? kMode7FastBlackEndpoint
                                          : kMode7FastWhiteEndpoint;
        reference.levels[lane] =
            static_cast<std::uint8_t>(endpoint | (rng() & 0xe0u));
        reference.prev[lane] = static_cast<std::uint8_t>(rng() & 31u);
        reference.next[lane] = static_cast<std::uint8_t>(rng());
        reference.final_levels[lane] = static_cast<std::uint8_t>(rng());
        reference.fnum[lane] = static_cast<std::uint8_t>(rng());
        reference.drove[lane] = static_cast<std::uint8_t>(rng());
      }
      RowState actual = reference;
      const FastRailStartRowResult expected =
          run_scalar(&reference, kOffset, count);
      const FastRailStartRowResult observed =
          run_dispatch(&actual, kOffset, count);
      EXPECT_EQ(observed.started, expected.started);
      EXPECT_EQ(observed.rebased, expected.rebased);
      EXPECT_EQ(observed.rebased & ~observed.started, 0u);
      EXPECT_TRUE(actual.levels == reference.levels);
      EXPECT_TRUE(actual.prev == reference.prev);
      EXPECT_TRUE(actual.next == reference.next);
      EXPECT_TRUE(actual.final_levels == reference.final_levels);
      EXPECT_TRUE(actual.fnum == reference.fnum);
      EXPECT_TRUE(actual.drove == reference.drove);
    }
  }
}

TEST(FastRailAdmitKernelsTest, ExhaustivePrevAndBothEndpointsAreExact) {
  constexpr int kCount = 64;
  RowState reference;
  reference.levels.resize(kCount);
  reference.prev.resize(kCount);
  reference.next.assign(kCount, 0x91u);
  reference.final_levels.assign(kCount, 0x92u);
  reference.fnum.assign(kCount, 0xffu);
  reference.drove.assign(kCount, 1u);
  for (int prev = 0; prev < 32; ++prev) {
    reference.prev[static_cast<std::size_t>(prev)] =
        static_cast<std::uint8_t>(prev);
    reference.prev[static_cast<std::size_t>(prev + 32)] =
        static_cast<std::uint8_t>(prev);
    reference.levels[static_cast<std::size_t>(prev)] = kMode7FastBlackEndpoint;
    reference.levels[static_cast<std::size_t>(prev + 32)] =
        kMode7FastWhiteEndpoint;
  }
  RowState actual = reference;
  const FastRailStartRowResult expected = run_scalar(&reference, 0, kCount);
  const FastRailStartRowResult observed = run_dispatch(&actual, 0, kCount);
  EXPECT_EQ(observed.started, expected.started);
  EXPECT_EQ(observed.rebased, expected.rebased);
  EXPECT_TRUE(actual.prev == reference.prev);
  EXPECT_TRUE(actual.next == reference.next);
  EXPECT_TRUE(actual.final_levels == reference.final_levels);
  EXPECT_TRUE(actual.fnum == reference.fnum);
  EXPECT_TRUE(actual.drove == reference.drove);
}

} // namespace
