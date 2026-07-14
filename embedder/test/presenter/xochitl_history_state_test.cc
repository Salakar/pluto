#include "presenter/swtcon/xochitl_history_state.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <barrier>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <ostream>
#include <span>
#include <thread>
#include <vector>

#include "xochitl_color_mapper_reference.h"
#include "xochitl_fast_state_reference.h"

namespace pluto::swtcon {

struct XochitlHistoryStateTestAccess {
  static XochitlHistoryState::PrepareResult prepare_legacy_with_stripes(
      XochitlHistoryState* state, XochitlHistoryState::Mode mode,
      XochitlHistoryState::InclusiveRect update,
      std::span<const std::uint8_t> raw, std::size_t raw_stride,
      std::span<const std::int16_t> delta, std::size_t stripes) {
    return state->prepare_legacy_with_stripes(mode, update, raw, raw_stride,
                                               delta, stripes);
  }
};

std::ostream &operator<<(std::ostream &stream,
                         const XochitlHistoryState::HistoryPixel &pixel) {
  return stream << "{a=" << pixel.a << ",b=" << pixel.b << "}";
}

std::ostream &operator<<(std::ostream &stream,
                         const XochitlHistoryState::LaneJournal &lane) {
  return stream << "{transition=" << lane.transition << ",a2=" << lane.a2
                << ",b2=" << lane.b2 << "}";
}

std::ostream &operator<<(std::ostream &stream,
                         const XochitlHistoryState::InclusiveRect &rect) {
  return stream << "{" << rect.left << "," << rect.top << "," << rect.right
                << "," << rect.bottom << "}";
}

std::ostream &operator<<(std::ostream &stream,
                         XochitlHistoryState::PrepareError error) {
  return stream << static_cast<int>(error);
}

std::ostream &operator<<(std::ostream &stream,
                         XochitlHistoryState::FinalizeStatus status) {
  return stream << static_cast<int>(status);
}

namespace {

using State = XochitlHistoryState;
using Pixel = State::HistoryPixel;
using Rect = State::InclusiveRect;

constexpr Rect kFixtureRect{64, 64, 64, 64};
constexpr std::array<std::uint8_t, 16> kNormalRaw = {0, 1, 2, 3, 4, 5, 6, 7,
                                                     7, 6, 5, 4, 3, 2, 1, 0};
constexpr std::array<std::uint16_t, 16> kLegacyAfterFastTransitions = {
    66, 76, 68, 84, 72, 80, 88, 924, 924, 88, 80, 72, 84, 68, 76, 66};
constexpr std::array<std::uint16_t, 16> kLegacyAfterContinuationTransitions = {
    66, 76, 68, 84, 72, 80, 88, 988, 988, 88, 80, 72, 84, 68, 76, 66};

std::size_t plane_index(std::int32_t x, std::int32_t y) {
  return static_cast<std::size_t>(y) * State::kStorageStride + x;
}

std::vector<std::uint16_t> interleaved(std::span<const Pixel> history) {
  std::vector<std::uint16_t> result(history.size() * 2u);
  for (std::size_t index = 0; index < history.size(); ++index) {
    result[index * 2u] = history[index].a;
    result[index * 2u + 1u] = history[index].b;
  }
  return result;
}

template <typename ReferenceResult>
void expect_journal_matches_reference(
    const State::PreparedOperation &prepared,
    const ReferenceResult &reference_result,
    std::span<const std::uint16_t> reference_ab) {
  ASSERT_EQ(prepared.lanes().size(), reference_result.transitions.size());
  ASSERT_EQ(prepared.transitions().size(), reference_result.transitions.size());
  ASSERT_EQ(prepared.lanes().size(),
            static_cast<std::size_t>(prepared.width()) * prepared.height());
  for (std::int32_t y = 0; y < prepared.height(); ++y) {
    for (std::int32_t x = 0; x < prepared.width(); ++x) {
      const std::size_t tight =
          static_cast<std::size_t>(y) * prepared.width() + x;
      const std::size_t panel = plane_index(prepared.execution().left + x,
                                            prepared.execution().top + y);
      const auto &lane = prepared.lanes()[tight];
      EXPECT_EQ(lane.transition, reference_result.transitions[tight]);
      EXPECT_EQ(prepared.transitions()[tight],
                reference_result.transitions[tight]);
      EXPECT_EQ(lane.a2, reference_ab[panel * 2u]);
      EXPECT_EQ(lane.b2, reference_ab[panel * 2u + 1u]);
    }
  }
}

void expect_transitions(const State::PreparedOperation &operation,
                        std::span<const std::uint16_t> expected) {
  ASSERT_EQ(operation.lanes().size(), expected.size());
  ASSERT_EQ(operation.transitions().size(), expected.size());
  for (std::size_t index = 0; index < expected.size(); ++index) {
    EXPECT_EQ(operation.lanes()[index].transition, expected[index]);
    EXPECT_EQ(operation.transitions()[index], expected[index]);
  }
}

TEST(XochitlHistoryState, ColdClearAndExactSeedCoverAllThreeWidthDomains) {
  State state;
  EXPECT_FALSE(state.valid());
  EXPECT_FALSE(state.pixel(0, 0).has_value());

  ASSERT_TRUE(state.initialize_cold_clear());
  for (const auto &[x, y] :
       std::array<std::pair<std::int32_t, std::int32_t>, 8>{
           std::pair{953, 1695}, // final logical pixel
           std::pair{954, 1695}, // packed-drive padding
           std::pair{959, 1695}, // final packed-drive column
           std::pair{960, 1695}, // persistent-history guard
           std::pair{967, 1695}, // final history column
           std::pair{953, 1696}, // first history guard row
           std::pair{960, 1697}, // final history row
           std::pair{0, 0}}) {
    ASSERT_TRUE(state.pixel(x, y).has_value());
    EXPECT_EQ(*state.pixel(x, y), (Pixel{30, 0}));
  }
  EXPECT_FALSE(state.pixel(968, 0).has_value());
  EXPECT_FALSE(state.pixel(0, 1698).has_value());

  std::vector<Pixel> seed(State::kStoragePixels, Pixel{2, 0x1234});
  seed[plane_index(954, 1696)] = {0x009e, 0x4567};
  seed[plane_index(960, 1697)] = {0x00dc, 0xffff};
  ASSERT_TRUE(state.seed_full_plane(seed));
  EXPECT_EQ(*state.pixel(954, 1696), seed[plane_index(954, 1696)]);
  EXPECT_EQ(*state.pixel(960, 1697), seed[plane_index(960, 1697)]);

  ASSERT_TRUE(!state.seed_full_plane(
      std::span<const Pixel>(seed).first(seed.size() - 1u)));
  EXPECT_FALSE(state.valid());
  EXPECT_TRUE(state.snapshot_full_plane().empty());

  ASSERT_TRUE(state.initialize_cold_clear(2));
  seed.assign(State::kStoragePixels, Pixel{2, 0});
  seed[plane_index(960, 1696)].a = 0x20; // A bit 5 is not a valid marker.
  ASSERT_TRUE(!state.seed_full_plane(seed));
  EXPECT_FALSE(state.valid());
  EXPECT_FALSE(state.pixel(960, 1696).has_value());

  EXPECT_FALSE(state.initialize_cold_clear(32));
  EXPECT_FALSE(state.valid());
}

TEST(XochitlHistoryState, RoundedOperationTouchesPackedAndHistoryGuardsOnly) {
  State state;
  ASSERT_TRUE(state.initialize_cold_clear(2));
  const std::array<std::uint8_t, 16> white = {7, 7, 7, 7, 7, 7, 7, 7,
                                              7, 7, 7, 7, 7, 7, 7, 7};

  const auto prepared =
      state.prepare_fast_source({953, 1695, 953, 1695}, white, 8, 25.0f);
  ASSERT_TRUE(prepared);
  EXPECT_EQ(prepared.operation->requested(), (Rect{953, 1695, 953, 1695}));
  EXPECT_EQ(prepared.operation->execution(), (Rect{953, 1695, 960, 1696}));
  EXPECT_EQ(prepared.operation->width(), 8);
  EXPECT_EQ(prepared.operation->height(), 2);
  EXPECT_EQ(prepared.operation->lanes().size(), 16u);
  EXPECT_EQ(*state.pixel(960, 1696), (Pixel{2, 0}));

  ASSERT_EQ(state.commit(*prepared.operation),
            State::FinalizeStatus::kCommitted);
  EXPECT_EQ(*state.pixel(953, 1695), (Pixel{28, 0x0903}));
  EXPECT_EQ(*state.pixel(954, 1695), (Pixel{28, 0x0903}));
  EXPECT_EQ(*state.pixel(960, 1696), (Pixel{28, 0x0903}));
  EXPECT_EQ(*state.pixel(967, 1697), (Pixel{2, 0}));

  EXPECT_EQ(state.prepare_fast_source({954, 0, 954, 0}, white, 8, 25.0f).error,
            State::PrepareError::kInvalidGeometry);
  EXPECT_EQ(state
                .prepare_fast_source({0, 0, 0, 0}, std::span(white).first(1), 8,
                                     25.0f)
                .error,
            State::PrepareError::kBufferTooSmall);
  EXPECT_FALSE(state.pixel(968, 0).has_value());
  EXPECT_FALSE(state.pixel(0, 1698).has_value());
}

TEST(XochitlHistoryState, LegacyPrepareIsFrozenAndDifferentiallyExact) {
  State state;
  ASSERT_TRUE(state.initialize_cold_clear(0));
  std::vector<std::int16_t> delta(State::kTransitionCount, 0);
  auto reference_ab = interleaved(state.snapshot_full_plane());
  const auto *palette = State::mode_palette(State::Mode::kContent);
  ASSERT_NE(palette, nullptr);
  xochitl_reference::Operation reference_operation = {
      .panel_width = State::kLogicalWidth,
      .panel_height = State::kLogicalHeight,
      .update = {64, 64, 64, 64},
      .raw = kNormalRaw,
      .raw_stride = 8,
      .ab = reference_ab,
      .ab_stride = State::kStorageStride,
      .ab_storage_height = State::kStorageRows,
      .palette = *palette,
      .delta = delta};
  const auto reference = xochitl_reference::map_operation(reference_operation);
  ASSERT_TRUE(reference);

  const auto prepared = state.prepare_legacy(
      State::Mode::kContent, kFixtureRect, kNormalRaw, 8, delta);
  ASSERT_TRUE(prepared);
  expect_journal_matches_reference(*prepared.operation, reference,
                                   reference_ab);
  EXPECT_EQ(*state.pixel(64, 64), (Pixel{0, 0}));
  ASSERT_EQ(state.commit(*prepared.operation),
            State::FinalizeStatus::kCommitted);
  for (std::int32_t y = 0; y < prepared.operation->height(); ++y) {
    for (std::int32_t x = 0; x < prepared.operation->width(); ++x) {
      const std::size_t panel = plane_index(64 + x, 64 + y);
      EXPECT_EQ(
          *state.pixel(64 + x, 64 + y),
          (Pixel{reference_ab[panel * 2u], reference_ab[panel * 2u + 1u]}));
    }
  }
}

TEST(XochitlHistoryState, LegacyDifferentialCorpusCoversEveryActivePalette) {
  constexpr Rect update{101, 101, 109, 103}; // rounds to unaligned 16x4
  constexpr std::int32_t execution_width = 16;
  constexpr std::int32_t execution_height = 4;
  constexpr std::size_t raw_stride = 20;
  std::vector<std::uint8_t> raw(raw_stride * execution_height, 0);
  std::vector<std::int16_t> delta(State::kTransitionCount, 0);
  for (std::size_t index = 0; index < delta.size(); ++index) {
    delta[index] = static_cast<std::int16_t>(
        static_cast<std::int32_t>((index * 17u) % 31u) - 15);
  }
  for (std::int32_t y = 0; y < execution_height; ++y) {
    for (std::int32_t x = 0; x < execution_width; ++x) {
      const std::uint32_t value =
          static_cast<std::uint32_t>((y * execution_width + x) * 73 + 19);
      raw[static_cast<std::size_t>(y) * raw_stride + x] =
          static_cast<std::uint8_t>((value % 12u) |
                                    ((value & 4u) != 0u ? 0x80u : 0u));
    }
  }

  for (const State::Mode mode : {State::Mode::kText, State::Mode::kContent,
                                 State::Mode::kUi, State::Mode::kFull}) {
    State state;
    std::vector<Pixel> seed(State::kStoragePixels, Pixel{2, 0});
    for (std::int32_t y = 0; y < execution_height; ++y) {
      for (std::int32_t x = 0; x < execution_width; ++x) {
        const std::uint32_t value = static_cast<std::uint32_t>(
            (y * execution_width + x) * 109 + static_cast<int>(mode));
        const std::uint16_t logical = static_cast<std::uint16_t>(value & 31u);
        const std::uint16_t markers =
            static_cast<std::uint16_t>(((value & 8u) != 0u ? 0x80u : 0u) |
                                       ((value & 16u) != 0u ? 0x40u : 0u));
        seed[plane_index(update.left + x, update.top + y)] = {
            static_cast<std::uint16_t>(logical | markers),
            static_cast<std::uint16_t>(value * 257u)};
      }
    }
    ASSERT_TRUE(state.seed_full_plane(seed));
    auto reference_ab = interleaved(seed);
    const auto *palette = State::mode_palette(mode);
    ASSERT_NE(palette, nullptr);
    xochitl_reference::Operation reference_operation = {
        .panel_width = State::kLogicalWidth,
        .panel_height = State::kLogicalHeight,
        .update = {update.left, update.top, update.right, update.bottom},
        .raw = raw,
        .raw_stride = raw_stride,
        .ab = reference_ab,
        .ab_stride = State::kStorageStride,
        .ab_storage_height = State::kStorageRows,
        .palette = *palette,
        .delta = delta};
    const auto reference =
        xochitl_reference::map_operation(reference_operation);
    ASSERT_TRUE(reference);
    const auto prepared =
        state.prepare_legacy(mode, update, raw, raw_stride, delta);
    ASSERT_TRUE(prepared);
    expect_journal_matches_reference(*prepared.operation, reference,
                                     reference_ab);
    ASSERT_EQ(state.discard(*prepared.operation),
              State::FinalizeStatus::kDiscarded);
  }
}

TEST(XochitlHistoryState,
     MaskedLegacyRandomizedHolesCannotAffectSelectedJournalOrCommit) {
  constexpr Rect update{64, 64, 79, 71};
  constexpr std::int32_t width = 16;
  constexpr std::int32_t height = 8;
  constexpr std::size_t lane_count = static_cast<std::size_t>(width) * height;

  for (const State::Mode mode : {State::Mode::kText, State::Mode::kFull}) {
    State state;
    std::uint32_t random = 0x8f3a5c17u ^ static_cast<std::uint32_t>(mode);
    const auto next_random = [&random] {
      random = random * 1664525u + 1013904223u;
      return random;
    };
    std::vector<Pixel> seed(State::kStoragePixels, Pixel{2, 0});
    for (std::int32_t y = 0; y < height; ++y) {
      for (std::int32_t x = 0; x < width; ++x) {
        const std::uint32_t value = next_random();
        seed[plane_index(update.left + x, update.top + y)] = {
            static_cast<std::uint16_t>((value & 31u) |
                                       ((value & 0x100u) != 0u ? 0x40u : 0u) |
                                       ((value & 0x200u) != 0u ? 0x80u : 0u)),
            static_cast<std::uint16_t>(value >> 16u)};
      }
    }
    ASSERT_TRUE(state.seed_full_plane(seed));

    std::vector<std::int16_t> delta(State::kTransitionCount);
    for (std::size_t index = 0; index < delta.size(); ++index) {
      delta[index] = static_cast<std::int16_t>(
          static_cast<std::int32_t>((index * 37u + 11u) % 61u) - 30);
    }

    for (std::size_t iteration = 0; iteration < 24u; ++iteration) {
      std::array<std::uint8_t, lane_count> mask{};
      std::array<std::uint8_t, lane_count> raw_a{};
      std::array<std::uint8_t, lane_count> raw_b{};
      for (std::size_t lane = 0; lane < lane_count; ++lane) {
        const bool selected = (next_random() % 5u) == 0u;
        mask[lane] = selected ? ((lane & 1u) == 0u ? 2u : 0xffu) : 0u;
        if (selected) {
          const std::uint8_t value = static_cast<std::uint8_t>(
              (next_random() % 12u) |
              ((next_random() & 1u) != 0u ? 0x80u : 0u));
          raw_a[lane] = value;
          raw_b[lane] = value;
        } else {
          // Include unsupported palette indices under holes. They must be
          // neither validated nor allowed to leak into a selected neighbour.
          raw_a[lane] = static_cast<std::uint8_t>(next_random());
          raw_b[lane] = static_cast<std::uint8_t>(~raw_a[lane]);
        }
      }
      mask[5] = 3u;
      mask[width + 6] = 0x80u;
      mask[lane_count - 1u] = 0u;
      raw_a[5] = static_cast<std::uint8_t>(next_random() % 12u);
      raw_a[width + 6] =
          static_cast<std::uint8_t>((next_random() % 12u) | 0x80u);
      raw_b[5] = raw_a[5];
      raw_b[width + 6] = raw_a[width + 6];

      std::array<Pixel, lane_count> before{};
      for (std::int32_t y = 0; y < height; ++y) {
        for (std::int32_t x = 0; x < width; ++x) {
          const std::size_t lane = static_cast<std::size_t>(y) * width + x;
          const auto pixel = state.pixel(update.left + x, update.top + y);
          ASSERT_TRUE(pixel.has_value());
          before[lane] = *pixel;
        }
      }

      const auto first =
          state.prepare_legacy(mode, update, raw_a, width, delta, mask);
      const auto changed_holes =
          state.prepare_legacy(mode, update, raw_b, width, delta, mask);
      ASSERT_TRUE(first);
      ASSERT_TRUE(changed_holes);
      ASSERT_TRUE(first.operation->masked());
      ASSERT_EQ(first.operation->lane_mask().size(), lane_count);
      ASSERT_EQ(changed_holes.operation->lane_mask().size(), lane_count);

      for (std::size_t lane = 0; lane < lane_count; ++lane) {
        const bool selected = mask[lane] != 0u;
        EXPECT_EQ(first.operation->lane_mask()[lane], selected ? 1u : 0u);
        EXPECT_EQ(changed_holes.operation->lane_mask()[lane],
                  selected ? 1u : 0u);
        if (selected) {
          EXPECT_EQ(first.operation->lanes()[lane],
                    changed_holes.operation->lanes()[lane]);
          EXPECT_EQ(first.operation->transitions()[lane],
                    changed_holes.operation->transitions()[lane]);
        } else {
          const std::uint8_t old_level =
              static_cast<std::uint8_t>(before[lane].a & 31u);
          EXPECT_EQ(first.operation->lanes()[lane],
                    (State::LaneJournal{
                        static_cast<std::uint16_t>(old_level * 32u + old_level),
                        before[lane].a, before[lane].b}));
        }
      }

      ASSERT_EQ(state.commit(*first.operation),
                State::FinalizeStatus::kCommitted);
      ASSERT_EQ(state.discard(*changed_holes.operation),
                State::FinalizeStatus::kDiscarded);
      for (std::int32_t y = 0; y < height; ++y) {
        for (std::int32_t x = 0; x < width; ++x) {
          const std::size_t lane = static_cast<std::size_t>(y) * width + x;
          const auto pixel = state.pixel(update.left + x, update.top + y);
          ASSERT_TRUE(pixel.has_value());
          if (mask[lane] == 0u) {
            EXPECT_EQ(*pixel, before[lane]);
          } else {
            EXPECT_EQ(pixel->a, first.operation->lanes()[lane].a2);
            EXPECT_EQ(pixel->b, first.operation->lanes()[lane].b2);
          }
        }
      }
    }
  }
}

TEST(XochitlHistoryState,
     LegacyMaskRejectsEmptyCoverageAndCanonicalizesDenseCoverage) {
  State state;
  ASSERT_TRUE(state.initialize_cold_clear(2));
  constexpr Rect update{32, 20, 39, 21};
  const std::array<std::uint8_t, 16> raw{};
  const std::array<std::int16_t, State::kTransitionCount> delta{};
  const std::array<std::uint8_t, 16> empty_mask{};

  EXPECT_EQ(
      state
          .prepare_legacy(State::Mode::kFull, update, raw, 8, delta, empty_mask)
          .error,
      State::PrepareError::kInvalidMask);
  EXPECT_EQ(state
                .prepare_legacy(State::Mode::kFull, update, raw, 8, delta,
                                std::span(empty_mask).first(15))
                .error,
            State::PrepareError::kInvalidMask);
  EXPECT_EQ(state.outstanding_count(), 0u);

  std::array<std::uint8_t, 16> dense_mask{};
  dense_mask.fill(0x80u);
  const auto masked = state.prepare_legacy(State::Mode::kFull, update, raw, 8,
                                           delta, dense_mask);
  const auto dense =
      state.prepare_legacy(State::Mode::kFull, update, raw, 8, delta);
  ASSERT_TRUE(masked);
  ASSERT_TRUE(dense);
  EXPECT_FALSE(masked.operation->masked());
  EXPECT_TRUE(masked.operation->lane_mask().empty());
  EXPECT_TRUE(std::equal(
      masked.operation->lanes().begin(), masked.operation->lanes().end(),
      dense.operation->lanes().begin(), dense.operation->lanes().end()));
  EXPECT_TRUE(std::equal(masked.operation->transitions().begin(),
                         masked.operation->transitions().end(),
                         dense.operation->transitions().begin(),
                         dense.operation->transitions().end()));
  EXPECT_EQ(state.discard(*masked.operation),
            State::FinalizeStatus::kDiscarded);
  EXPECT_EQ(state.discard(*dense.operation), State::FinalizeStatus::kDiscarded);
}

TEST(XochitlHistoryState,
     ForcedThreeStripeBoundaryMatchesIndependentReference) {
  constexpr Rect update{64, 64, 575, 575};
  constexpr std::int32_t width = 512;
  constexpr std::int32_t height = 512;
  State state;
  std::vector<Pixel> seed(State::kStoragePixels, Pixel{2, 0});
  std::vector<std::uint8_t> raw(static_cast<std::size_t>(width) * height);
  for (std::int32_t y = 0; y < height; ++y) {
    for (std::int32_t x = 0; x < width; ++x) {
      const std::uint32_t value = static_cast<std::uint32_t>(x) * 2246822519u ^
                                  static_cast<std::uint32_t>(y) * 3266489917u;
      raw[static_cast<std::size_t>(y) * width + x] = static_cast<std::uint8_t>(
          (value % 12u) | ((value & 0x100u) != 0u ? 0x80u : 0u));
      seed[plane_index(update.left + x, update.top + y)] = {
          static_cast<std::uint16_t>((value & 31u) |
                                     ((value & 0x200u) != 0u ? 0x40u : 0u) |
                                     ((value & 0x400u) != 0u ? 0x80u : 0u)),
          static_cast<std::uint16_t>(value >> 8u)};
    }
  }
  ASSERT_TRUE(state.seed_full_plane(seed));
  std::vector<std::int16_t> delta(State::kTransitionCount);
  for (std::size_t index = 0; index < delta.size(); ++index) {
    delta[index] = static_cast<std::int16_t>(
        static_cast<std::int32_t>((index * 29u) % 41u) - 20);
  }

  auto reference_ab = interleaved(seed);
  const auto *palette = State::mode_palette(State::Mode::kFull);
  ASSERT_NE(palette, nullptr);
  xochitl_reference::Operation reference_operation = {
      .panel_width = State::kLogicalWidth,
      .panel_height = State::kLogicalHeight,
      .update = {update.left, update.top, update.right, update.bottom},
      .raw = raw,
      .raw_stride = width,
      .ab = reference_ab,
      .ab_stride = State::kStorageStride,
      .ab_storage_height = State::kStorageRows,
      .palette = *palette,
      .delta = delta};
  const auto reference = xochitl_reference::map_operation(reference_operation);
  ASSERT_TRUE(reference);
  const auto prepared =
      XochitlHistoryStateTestAccess::prepare_legacy_with_stripes(
          &state, State::Mode::kFull, update, raw, width, delta, 3);
  ASSERT_TRUE(prepared);
  ASSERT_EQ(prepared.operation->lanes().size(), reference.transitions.size());
  ASSERT_EQ(prepared.operation->transitions().size(),
            reference.transitions.size());
  for (std::int32_t y = 0; y < height; ++y) {
    for (std::int32_t x = 0; x < width; ++x) {
      const std::size_t tight = static_cast<std::size_t>(y) * width + x;
      const std::size_t panel = plane_index(update.left + x, update.top + y);
      const auto lane = prepared.operation->lanes()[tight];
      if (lane.transition != reference.transitions[tight] ||
          prepared.operation->transitions()[tight] !=
              reference.transitions[tight] ||
          lane.a2 != reference_ab[panel * 2u] ||
          lane.b2 != reference_ab[panel * 2u + 1u]) {
        EXPECT_TRUE(false);
        return;
      }
    }
  }
  EXPECT_EQ(state.discard(*prepared.operation),
            State::FinalizeStatus::kDiscarded);
}

TEST(XochitlHistoryState,
     ForcedThreeStripeInvalidPaletteAtSeamFailsWithoutJournal) {
  constexpr Rect update{64, 64, 575, 575};
  constexpr std::int32_t width = 512;
  constexpr std::int32_t height = 512;
  constexpr std::int32_t seam_y = height / 3;
  State state;
  ASSERT_TRUE(state.initialize_cold_clear(2));
  const std::uint64_t generation = state.generation();
  std::vector<std::uint8_t> raw(static_cast<std::size_t>(width) * height, 0);
  // Mode Full rejects palette index 12. Placing it on the forced 0/1 seam
  // exercises the same row as stripe 0's lower halo and stripe 1's first
  // center row; neither worker may publish a partial journal.
  raw[static_cast<std::size_t>(seam_y) * width + width / 2] = 12;
  const std::array<std::int16_t, State::kTransitionCount> delta{};
  const auto prepared =
      XochitlHistoryStateTestAccess::prepare_legacy_with_stripes(
          &state, State::Mode::kFull, update, raw, width, delta, 3);
  EXPECT_EQ(prepared.error, State::PrepareError::kUnsupportedPaletteState);
  EXPECT_EQ(prepared.operation, nullptr);
  EXPECT_EQ(state.outstanding_count(), 0u);
  EXPECT_EQ(state.generation(), generation);
  const auto seam_pixel =
      state.pixel(update.left + width / 2, update.top + seam_y);
  ASSERT_TRUE(seam_pixel.has_value());
  EXPECT_EQ(*seam_pixel, (Pixel{2, 0}));
}

TEST(XochitlHistoryState, FastSourceAndContinuationMatchIndependentReference) {
  for (const float temperature : {25.0f, 38.0f}) {
    State state;
    std::vector<Pixel> seed(State::kStoragePixels, Pixel{2, 0});
    seed[plane_index(64, 64)] = {2, 0};
    seed[plane_index(65, 64)] = {28, 2};
    seed[plane_index(66, 64)] = {10, 0x0103};
    seed[plane_index(67, 64)] = {0x009e, 0x0402};
    ASSERT_TRUE(state.seed_full_plane(seed));
    const std::array<std::uint8_t, 16> raw = {7, 7, 0, 0x87, 0, 7, 0, 7,
                                              0, 7, 0, 7,    0, 7, 0, 7};
    auto reference_ab = interleaved(seed);
    xochitl_fast_reference::Operation reference_operation = {
        .panel_width = State::kLogicalWidth,
        .panel_height = State::kLogicalHeight,
        .update = {64, 64, 64, 64},
        .raw = raw,
        .raw_stride = 8,
        .ab = reference_ab,
        .ab_stride = State::kStorageStride,
        .ab_storage_height = State::kStorageRows,
        .temperature_c = temperature};
    const auto source_reference =
        xochitl_fast_reference::map_source(reference_operation);
    ASSERT_TRUE(source_reference);
    const auto source =
        state.prepare_fast_source(kFixtureRect, raw, 8, temperature);
    ASSERT_TRUE(source);
    expect_journal_matches_reference(*source.operation, source_reference,
                                     reference_ab);
    ASSERT_EQ(state.commit(*source.operation),
              State::FinalizeStatus::kCommitted);

    const auto continuation_reference =
        xochitl_fast_reference::map_continuation(reference_operation);
    ASSERT_TRUE(continuation_reference);
    const auto continuation =
        state.prepare_fast_continuation(kFixtureRect, temperature);
    ASSERT_TRUE(continuation);
    expect_journal_matches_reference(*continuation.operation,
                                     continuation_reference, reference_ab);
    ASSERT_EQ(state.commit(*continuation.operation),
              State::FinalizeStatus::kCommitted);
  }
}

TEST(XochitlHistoryState, RegionalVersionsAllowDisjointAndRejectOverlap) {
  State state;
  ASSERT_TRUE(state.initialize_cold_clear(2));
  const std::array<std::uint8_t, 16> white = {7, 7, 7, 7, 7, 7, 7, 7,
                                              7, 7, 7, 7, 7, 7, 7, 7};
  const auto first = state.prepare_fast_source({8, 8, 8, 8}, white, 8, 25.0f);
  const auto disjoint =
      state.prepare_fast_source({32, 8, 32, 8}, white, 8, 25.0f);
  const auto overlap =
      state.prepare_fast_source({12, 8, 12, 8}, white, 8, 25.0f);
  ASSERT_TRUE(first);
  ASSERT_TRUE(disjoint);
  ASSERT_TRUE(overlap);
  const std::uint64_t shared_generation = first.operation->base_generation();
  EXPECT_EQ(disjoint.operation->base_generation(), shared_generation);
  ASSERT_EQ(state.commit(*first.operation), State::FinalizeStatus::kCommitted);
  EXPECT_GT(state.generation(), shared_generation);
  ASSERT_EQ(state.commit(*disjoint.operation),
            State::FinalizeStatus::kCommitted)
      << "a disjoint 8x2 history tile must survive a sibling commit";
  EXPECT_EQ(state.commit(*overlap.operation),
            State::FinalizeStatus::kStaleRegion);
  EXPECT_EQ(state.discard(*overlap.operation),
            State::FinalizeStatus::kDiscarded);

  const auto discarded =
      state.prepare_fast_source({48, 8, 48, 8}, white, 8, 25.0f);
  ASSERT_TRUE(discarded);
  EXPECT_EQ(state.discard(*discarded.operation),
            State::FinalizeStatus::kDiscarded);
  EXPECT_EQ(state.commit(*discarded.operation),
            State::FinalizeStatus::kNotOutstanding);

  State other;
  ASSERT_TRUE(other.initialize_cold_clear(2));
  const auto foreign =
      state.prepare_fast_source({64, 8, 64, 8}, white, 8, 25.0f);
  ASSERT_TRUE(foreign);
  EXPECT_EQ(other.commit(*foreign.operation),
            State::FinalizeStatus::kForeignOperation);

  state.invalidate();
  EXPECT_FALSE(state.valid());
  EXPECT_EQ(state.commit(*foreign.operation),
            State::FinalizeStatus::kInvalidHistory);
  EXPECT_EQ(state.prepare_fast_continuation({64, 8, 64, 8}, 25.0f).error,
            State::PrepareError::kInvalidHistory);
}

TEST(XochitlHistoryState, ConcurrentDisjointJournalsCommitWithoutDataRaces) {
  State state;
  ASSERT_TRUE(state.initialize_cold_clear(2));
  const std::array<std::uint8_t, 16> white = {7, 7, 7, 7, 7, 7, 7, 7,
                                              7, 7, 7, 7, 7, 7, 7, 7};
  State::PrepareResult first;
  State::PrepareResult second;
  State::FinalizeStatus first_status = State::FinalizeStatus::kInvalidHistory;
  State::FinalizeStatus second_status = State::FinalizeStatus::kInvalidHistory;
  std::barrier prepared_barrier(3);
  std::thread first_thread([&] {
    first = state.prepare_fast_source({80, 40, 80, 40}, white, 8, 25.0f);
    prepared_barrier.arrive_and_wait();
    if (first) {
      first_status = state.commit(*first.operation);
    }
  });
  std::thread second_thread([&] {
    second = state.prepare_fast_source({160, 40, 160, 40}, white, 8, 25.0f);
    prepared_barrier.arrive_and_wait();
    if (second) {
      second_status = state.commit(*second.operation);
    }
  });
  prepared_barrier.arrive_and_wait();
  first_thread.join();
  second_thread.join();

  ASSERT_TRUE(first);
  ASSERT_TRUE(second);
  EXPECT_EQ(first_status, State::FinalizeStatus::kCommitted);
  EXPECT_EQ(second_status, State::FinalizeStatus::kCommitted);
  EXPECT_EQ(*state.pixel(80, 40), (Pixel{28, 0x0903}));
  EXPECT_EQ(*state.pixel(160, 40), (Pixel{28, 0x0903}));
}

TEST(XochitlHistoryState, OperationIdsAreUniqueAndNeverReusedOnFinalize) {
  State state;
  ASSERT_TRUE(state.initialize_cold_clear(2));
  const std::array<std::uint8_t, 16> white = {7, 7, 7, 7, 7, 7, 7, 7,
                                              7, 7, 7, 7, 7, 7, 7, 7};
  const auto discarded =
      state.prepare_fast_source({8, 80, 8, 80}, white, 8, 25.0f);
  const auto committed =
      state.prepare_fast_source({32, 80, 32, 80}, white, 8, 25.0f);
  ASSERT_TRUE(discarded);
  ASSERT_TRUE(committed);
  const std::uint64_t discarded_id = discarded.operation->operation_id();
  const std::uint64_t committed_id = committed.operation->operation_id();
  EXPECT_NE(discarded_id, committed_id);
  ASSERT_EQ(state.discard(*discarded.operation),
            State::FinalizeStatus::kDiscarded);
  ASSERT_EQ(state.commit(*committed.operation),
            State::FinalizeStatus::kCommitted);

  const auto next =
      state.prepare_fast_source({56, 80, 56, 80}, white, 8, 25.0f);
  ASSERT_TRUE(next);
  EXPECT_GT(next.operation->operation_id(), committed_id);
  EXPECT_NE(next.operation->operation_id(), discarded_id);
  ASSERT_EQ(state.discard(*next.operation), State::FinalizeStatus::kDiscarded);
  const auto after_discard =
      state.prepare_fast_source({80, 80, 80, 80}, white, 8, 25.0f);
  ASSERT_TRUE(after_discard);
  EXPECT_GT(after_discard.operation->operation_id(),
            next.operation->operation_id());
  ASSERT_EQ(state.discard(*after_discard.operation),
            State::FinalizeStatus::kDiscarded);
}

TEST(XochitlHistoryState, InstalledModePalettesAndSentinelsArePinned) {
  constexpr std::array<std::uint8_t, 16> mode1 = {
      0, 14, 6, 22, 10, 18, 26, 30, 15, 19, 0, 30, 32, 32, 32, 32};
  constexpr std::array<std::uint8_t, 16> mode2 = {
      2, 12, 4, 20, 8, 16, 24, 28, 15, 19, 2, 30, 32, 32, 32, 32};
  constexpr std::array<std::uint8_t, 16> mode5 = {
      2, 13, 5, 21, 9, 17, 25, 28, 15, 19, 0, 30, 32, 32, 32, 32};
  constexpr std::array<std::uint8_t, 16> mode6 = {
      2, 12, 4, 20, 8, 16, 24, 28, 15, 19, 2, 28, 32, 32, 32, 32};
  constexpr std::array<std::uint8_t, 16> mode7 = {
      2, 32, 32, 32, 32, 32, 32, 28, 32, 32, 32, 32, 32, 32, 32, 32};
  EXPECT_TRUE(*State::mode_palette(State::Mode::kText) == mode1);
  EXPECT_TRUE(*State::mode_palette(State::Mode::kContent) == mode2);
  EXPECT_TRUE(*State::mode_palette(State::Mode::kUi) == mode5);
  EXPECT_TRUE(*State::mode_palette(State::Mode::kFull) == mode6);
  EXPECT_TRUE(*State::mode_palette(State::Mode::kFast) == mode7);
  EXPECT_EQ(State::mode_palette(static_cast<State::Mode>(99)), nullptr);

  State state;
  ASSERT_TRUE(state.initialize_cold_clear(0));
  std::vector<std::int16_t> delta(State::kTransitionCount, 0);
  std::array<std::uint8_t, 16> raw{};
  raw.fill(12);
  EXPECT_EQ(
      state.prepare_legacy(State::Mode::kContent, kFixtureRect, raw, 8, delta)
          .error,
      State::PrepareError::kUnsupportedPaletteState);
  EXPECT_EQ(state.outstanding_count(), 0u);
  EXPECT_EQ(
      state.prepare_legacy(State::Mode::kFast, kFixtureRect, raw, 8, delta)
          .error,
      State::PrepareError::kInvalidMode);

  raw.fill(11);
  const auto content =
      state.prepare_legacy(State::Mode::kContent, kFixtureRect, raw, 8, delta);
  ASSERT_TRUE(content);
  EXPECT_EQ(content.operation->lanes()[0].a2, 30u);
  ASSERT_EQ(state.discard(*content.operation),
            State::FinalizeStatus::kDiscarded);
  const auto full =
      state.prepare_legacy(State::Mode::kFull, kFixtureRect, raw, 8, delta);
  ASSERT_TRUE(full);
  EXPECT_EQ(full.operation->lanes()[0].a2, 28u);
  ASSERT_EQ(state.discard(*full.operation), State::FinalizeStatus::kDiscarded);
}

// Pinned direct-runtime bridge manifest SHA-256 values:
// fast-legacy cold/hot:
//   a92bcb945caa56ebe688d32ef554402e32c708dfc8e57d2628c5fea50cbe2881
//   02fce9268761add5f22f5e24167a9fd68ce1ae5f4bc7cd3b4818cf8aa33c2691
// legacy-fast-legacy cold/hot:
//   bcfd2c6ab85f3301526d8fbdf1cc2daffcaa8d913aceb0a95403eea52730bfd9
//   2012223c62fac07677403690b9bab31b56dcf785208c2c58deaeb5009ef32fd8
// fast-continuation-legacy cold/hot:
//   0e9a2fbe863e398e767e99d1d1306ecf0a0b85ef92614909422bf2646afba1d0
//   ca743722ef101f4ef925d5e3a69b984b7a8a4bd1cc0b1a85abd1f3efbf7401d9
TEST(XochitlHistoryState, RuntimeBridgeV2FastLegacyColdAndHot) {
  std::vector<std::int16_t> delta(State::kTransitionCount, 0);
  for (const auto [temperature, source_b, final_b] :
       std::array<std::array<int, 3>, 2>{std::array{25, 0x0903, 0x0900},
                                         std::array{38, 0x0b02, 0x0b00}}) {
    State state;
    ASSERT_TRUE(state.initialize_cold_clear(0));
    const auto fast = state.prepare_fast_source(
        kFixtureRect, kNormalRaw, 8, static_cast<float>(temperature));
    ASSERT_TRUE(fast);
    EXPECT_EQ(fast.operation->lanes()[7].a2, 28u);
    EXPECT_EQ(fast.operation->lanes()[7].b2,
              static_cast<std::uint16_t>(source_b));
    ASSERT_EQ(state.commit(*fast.operation), State::FinalizeStatus::kCommitted);
    const auto legacy = state.prepare_legacy(
        State::Mode::kContent, kFixtureRect, kNormalRaw, 8, delta);
    ASSERT_TRUE(legacy);
    expect_transitions(*legacy.operation, kLegacyAfterFastTransitions);
    EXPECT_EQ(legacy.operation->lanes()[7].a2, 28u);
    EXPECT_EQ(legacy.operation->lanes()[7].b2,
              static_cast<std::uint16_t>(final_b));
    ASSERT_EQ(state.commit(*legacy.operation),
              State::FinalizeStatus::kCommitted);
  }
}

TEST(XochitlHistoryState, RuntimeBridgeV2LegacyFastLegacyColdAndHot) {
  std::vector<std::int16_t> delta(State::kTransitionCount, 0);
  for (const auto [temperature, reset_flags] :
       std::array<std::array<int, 2>, 2>{std::array{25, 3},
                                         std::array{38, 2}}) {
    State state;
    ASSERT_TRUE(state.initialize_cold_clear(0));
    const auto first = state.prepare_legacy(State::Mode::kContent, kFixtureRect,
                                            kNormalRaw, 8, delta);
    ASSERT_TRUE(first);
    ASSERT_EQ(state.commit(*first.operation),
              State::FinalizeStatus::kCommitted);
    const auto fast = state.prepare_fast_source(
        kFixtureRect, kNormalRaw, 8, static_cast<float>(temperature));
    ASSERT_TRUE(fast);
    EXPECT_EQ(fast.operation->lanes()[1].transition, 12u * 32u + 2u);
    EXPECT_EQ(fast.operation->lanes()[1].b2,
              static_cast<std::uint16_t>(reset_flags));
    ASSERT_EQ(state.commit(*fast.operation), State::FinalizeStatus::kCommitted);
    const auto final = state.prepare_legacy(State::Mode::kContent, kFixtureRect,
                                            kNormalRaw, 8, delta);
    ASSERT_TRUE(final);
    expect_transitions(*final.operation, kLegacyAfterFastTransitions);
    EXPECT_EQ(final.operation->lanes()[1].b2, 0u);
    ASSERT_EQ(state.commit(*final.operation),
              State::FinalizeStatus::kCommitted);
  }
}

TEST(XochitlHistoryState, RuntimeBridgeV2ContinuationLegacyColdAndHot) {
  std::vector<std::int16_t> delta(State::kTransitionCount, 0);
  constexpr std::array<std::uint16_t, 16> continuation_transitions = {
      91, 91, 91, 91, 91, 91, 91, 926, 926, 91, 91, 91, 91, 91, 91, 91};
  for (const auto [temperature, continuation_b, final_b] :
       std::array<std::array<int, 3>, 2>{std::array{25, 0x1202, 0x1200},
                                         std::array{38, 0x1601, 0x1600}}) {
    State state;
    ASSERT_TRUE(state.initialize_cold_clear(0));
    const auto fast = state.prepare_fast_source(
        kFixtureRect, kNormalRaw, 8, static_cast<float>(temperature));
    ASSERT_TRUE(fast);
    ASSERT_EQ(state.commit(*fast.operation), State::FinalizeStatus::kCommitted);
    const auto continuation = state.prepare_fast_continuation(
        kFixtureRect, static_cast<float>(temperature));
    ASSERT_TRUE(continuation);
    expect_transitions(*continuation.operation, continuation_transitions);
    EXPECT_EQ(continuation.operation->lanes()[7].a2, 30u);
    EXPECT_EQ(continuation.operation->lanes()[7].b2,
              static_cast<std::uint16_t>(continuation_b));
    ASSERT_EQ(state.commit(*continuation.operation),
              State::FinalizeStatus::kCommitted);
    const auto legacy = state.prepare_legacy(
        State::Mode::kContent, kFixtureRect, kNormalRaw, 8, delta);
    ASSERT_TRUE(legacy);
    expect_transitions(*legacy.operation, kLegacyAfterContinuationTransitions);
    EXPECT_EQ(legacy.operation->lanes()[7].a2, 28u);
    EXPECT_EQ(legacy.operation->lanes()[7].b2,
              static_cast<std::uint16_t>(final_b));
    ASSERT_EQ(state.commit(*legacy.operation),
              State::FinalizeStatus::kCommitted);
  }
}

TEST(XochitlHistoryState, InvalidInputsNeverCreateOrCommitAJournal) {
  State state;
  ASSERT_TRUE(state.initialize_cold_clear(2));
  const auto before = state.snapshot_full_plane();
  std::array<std::uint8_t, 16> raw{};
  std::vector<std::int16_t> short_delta(State::kTransitionCount - 1u, 0);
  EXPECT_EQ(state
                .prepare_legacy(State::Mode::kContent, kFixtureRect, raw, 8,
                                short_delta)
                .error,
            State::PrepareError::kBufferTooSmall);
  EXPECT_EQ(state
                .prepare_fast_source(kFixtureRect, raw, 8,
                                     std::numeric_limits<float>::quiet_NaN())
                .error,
            State::PrepareError::kInvalidTemperature);
  EXPECT_EQ(state
                .prepare_fast_continuation(
                    kFixtureRect, std::numeric_limits<float>::infinity())
                .error,
            State::PrepareError::kInvalidTemperature);
  EXPECT_EQ(state.outstanding_count(), 0u);
  EXPECT_TRUE(state.snapshot_full_plane() == before);
}

TEST(XochitlHistoryState,
     RegionalReseedPreservesOutsideReplicatesGuardsAndKillsOldJournals) {
  State state;
  ASSERT_TRUE(state.initialize_cold_clear(30));
  const State::InclusiveRect stale_rect{100, 100, 107, 101};
  const std::vector<std::uint8_t> stale_raw(16, 0);
  const auto stale = state.prepare_fast_source(stale_rect, stale_raw, 8, 25.0f);
  ASSERT_TRUE(stale);
  ASSERT_TRUE(state.admissible(*stale.operation));

  state.invalidate_preserving_committed_for_reseed();
  EXPECT_FALSE(state.valid());
  EXPECT_EQ(state.outstanding_count(), 0u);
  const std::array<std::uint8_t, 1> endpoint{7};
  ASSERT_TRUE(state.reseed_region_from_levels(
      {State::kLogicalWidth - 1, State::kLogicalHeight - 1,
       State::kLogicalWidth - 1, State::kLogicalHeight - 1},
      endpoint, 1));
  EXPECT_TRUE(state.valid());
  EXPECT_FALSE(state.admissible(*stale.operation));
  EXPECT_EQ(state.commit(*stale.operation),
            State::FinalizeStatus::kStaleGeneration);

  const auto outside = state.pixel(0, 0);
  const auto logical =
      state.pixel(State::kLogicalWidth - 1, State::kLogicalHeight - 1);
  const auto right_guard =
      state.pixel(State::kPackedDriveWidth, State::kLogicalHeight - 1);
  const auto bottom_guard =
      state.pixel(State::kLogicalWidth - 1, State::kLogicalHeight);
  ASSERT_TRUE(outside.has_value());
  ASSERT_TRUE(logical.has_value());
  ASSERT_TRUE(right_guard.has_value());
  ASSERT_TRUE(bottom_guard.has_value());
  EXPECT_EQ(*outside, (State::HistoryPixel{30, 0}));
  EXPECT_EQ(*logical, (State::HistoryPixel{7, 0}));
  EXPECT_EQ(*right_guard, (State::HistoryPixel{7, 0}));
  EXPECT_EQ(*bottom_guard, (State::HistoryPixel{7, 0}));
}

TEST(XochitlHistoryState,
     AdmissibleRejectsDiscardedAndRegionStaleOperationsBeforeDrive) {
  State state;
  ASSERT_TRUE(state.initialize_cold_clear());
  const std::vector<std::uint8_t> raw(16, 0);
  const auto discarded = state.prepare_fast_source({0, 0, 7, 1}, raw, 8, 25.0f);
  ASSERT_TRUE(discarded);
  EXPECT_TRUE(state.admissible(*discarded.operation));
  EXPECT_EQ(state.discard(*discarded.operation),
            State::FinalizeStatus::kDiscarded);
  EXPECT_FALSE(state.admissible(*discarded.operation));

  // Pixel-disjoint executions sharing the conservative x=8..15 history tile.
  const auto first = state.prepare_fast_source({1, 4, 1, 4}, raw, 8, 25.0f);
  const auto stale = state.prepare_fast_source({9, 4, 9, 4}, raw, 8, 25.0f);
  ASSERT_TRUE(first);
  ASSERT_TRUE(stale);
  EXPECT_TRUE(state.admissible(*first.operation));
  EXPECT_TRUE(state.admissible(*stale.operation));
  EXPECT_EQ(state.commit(*first.operation), State::FinalizeStatus::kCommitted);
  EXPECT_FALSE(state.admissible(*stale.operation));
  EXPECT_EQ(state.discard(*stale.operation), State::FinalizeStatus::kDiscarded);
}

TEST(XochitlHistoryState,
     FastRawRegionalReseedStalesOnlyOverlappingOutstandingJournals) {
  State state;
  ASSERT_TRUE(state.initialize_cold_clear(30));
  const State::InclusiveRect touched{0, 0, 7, 1};
  const State::InclusiveRect disjoint{16, 0, 23, 1};
  const std::vector<std::uint8_t> black(16, 0);
  const std::vector<std::uint8_t> white(16, 7);
  const auto overlapping = state.prepare_fast_source(touched, black, 8, 25.0f);
  const auto sibling = state.prepare_fast_source(disjoint, black, 8, 25.0f);
  ASSERT_TRUE(overlapping);
  ASSERT_TRUE(sibling);
  ASSERT_TRUE(state.admissible(*overlapping.operation));
  ASSERT_TRUE(state.admissible(*sibling.operation));
  const std::uint64_t seed_epoch_generation = state.generation();

  const std::array<std::uint8_t, 2> all_driven{0xff, 0xff};
  ASSERT_TRUE(state.reseed_fast_region_from_raw(touched, touched, white, 8,
                                                all_driven, 1));
  EXPECT_TRUE(state.valid());
  EXPECT_GT(state.generation(), seed_epoch_generation);
  EXPECT_FALSE(state.admissible(*overlapping.operation));
  EXPECT_TRUE(state.admissible(*sibling.operation));
  EXPECT_EQ(state.commit(*overlapping.operation),
            State::FinalizeStatus::kStaleRegion);
  EXPECT_EQ(state.commit(*sibling.operation),
            State::FinalizeStatus::kCommitted);
  EXPECT_EQ(state.discard(*overlapping.operation),
            State::FinalizeStatus::kDiscarded);
  EXPECT_EQ(state.outstanding_count(), 0u);

  const auto touched_pixel = state.pixel(0, 0);
  const auto sibling_pixel = state.pixel(16, 0);
  ASSERT_TRUE(touched_pixel.has_value());
  ASSERT_TRUE(sibling_pixel.has_value());
  EXPECT_EQ(*touched_pixel, (State::HistoryPixel{28, 0}));
  EXPECT_EQ(sibling_pixel->a & 31u, sibling.operation->lanes()[0].a2 & 31u);
}

TEST(XochitlHistoryState,
     FastRawRegionalReseedReplicatesBottomRightGuardsAndMarker) {
  State state;
  ASSERT_TRUE(state.initialize_cold_clear(30));
  // bit7 is the raw marker, bit6 must not leak into A, low5==7 is white.
  std::array<std::uint8_t, 16> marked_white{};
  marked_white[0] = 0xc7;
  const std::array<std::uint8_t, 2> driven_edge{0x01, 0x00};
  const State::InclusiveRect corner{
      State::kLogicalWidth - 1, State::kLogicalHeight - 1,
      State::kLogicalWidth - 1, State::kLogicalHeight - 1};
  const State::InclusiveRect execution{
      State::kLogicalWidth - 1, State::kLogicalHeight - 1,
      State::kPackedDriveWidth, State::kLogicalHeight};
  ASSERT_TRUE(state.reseed_fast_region_from_raw(corner, execution, marked_white,
                                                8, driven_edge, 1));

  constexpr State::HistoryPixel expected{0x80u | 28u, 0};
  const auto logical =
      state.pixel(State::kLogicalWidth - 1, State::kLogicalHeight - 1);
  const auto x960 =
      state.pixel(State::kPackedDriveWidth, State::kLogicalHeight - 1);
  const auto y1696 =
      state.pixel(State::kLogicalWidth - 1, State::kLogicalHeight);
  const auto guard_corner =
      state.pixel(State::kPackedDriveWidth, State::kLogicalHeight);
  ASSERT_TRUE(logical.has_value());
  ASSERT_TRUE(x960.has_value());
  ASSERT_TRUE(y1696.has_value());
  ASSERT_TRUE(guard_corner.has_value());
  EXPECT_EQ(*logical, expected);
  EXPECT_EQ(*x960, expected);
  EXPECT_EQ(*y1696, expected);
  EXPECT_EQ(*guard_corner, expected);
  EXPECT_EQ(logical->a & 0x40u, 0u);
  const auto untouched =
      state.pixel(State::kLogicalWidth - 2, State::kLogicalHeight - 1);
  ASSERT_TRUE(untouched.has_value());
  EXPECT_EQ(*untouched, (State::HistoryPixel{30, 0}));
}

TEST(XochitlHistoryState,
     InvalidFastRawRegionalReseedLeavesValidStateAndJournalsUntouched) {
  State state;
  ASSERT_TRUE(state.initialize_cold_clear(30));
  const std::vector<std::uint8_t> raw(16, 0);
  const auto sibling = state.prepare_fast_source({32, 8, 39, 9}, raw, 8, 25.0f);
  ASSERT_TRUE(sibling);
  const auto before = state.snapshot_full_plane();
  const std::uint64_t generation = state.generation();
  const std::size_t outstanding = state.outstanding_count();
  const std::array<std::uint8_t, 2> driven{0xff, 0xff};

  EXPECT_FALSE(state.reseed_fast_region_from_raw(
      {0, 0, 7, 1}, {0, 0, 7, 1}, std::span<const std::uint8_t>(raw.data(), 7),
      8, driven, 1));
  EXPECT_FALSE(state.reseed_fast_region_from_raw(
      {-1, 0, 0, 0}, {0, 0, 7, 1}, std::span<const std::uint8_t>(raw), 8,
      driven, 1));
  EXPECT_TRUE(state.valid());
  EXPECT_EQ(state.generation(), generation);
  EXPECT_EQ(state.outstanding_count(), outstanding);
  EXPECT_TRUE(state.admissible(*sibling.operation));
  EXPECT_TRUE(state.snapshot_full_plane() == before);
  EXPECT_EQ(state.discard(*sibling.operation),
            State::FinalizeStatus::kDiscarded);
}

TEST(XochitlHistoryState,
     MaskedFastReseedPreservesNoopLanesAndVisibleExecutionPadding) {
  State state;
  std::vector<State::HistoryPixel> seed(State::kStoragePixels,
                                        State::HistoryPixel{30, 123});
  ASSERT_TRUE(state.seed_full_plane(seed));
  // requested is x=1,w=1 but execution contains real neighbouring pixels.
  // Only x=1 was proven driven; x=0 and x=2 must not be edge-replicated.
  const State::InclusiveRect requested{1, 0, 1, 0};
  const State::InclusiveRect execution{1, 0, 8, 1};
  std::array<std::uint8_t, 16> raw{};
  raw[0] = 0;
  raw[1] = 0x87;
  const std::array<std::uint8_t, 2> driven{0x01, 0x00};
  ASSERT_TRUE(state.reseed_fast_region_from_raw(requested, execution, raw, 8,
                                                driven, 1));

  ASSERT_TRUE(state.pixel(0, 0).has_value());
  ASSERT_TRUE(state.pixel(1, 0).has_value());
  ASSERT_TRUE(state.pixel(2, 0).has_value());
  EXPECT_EQ(*state.pixel(0, 0), (State::HistoryPixel{30, 123}));
  EXPECT_EQ(*state.pixel(1, 0), (State::HistoryPixel{2, 0}));
  EXPECT_EQ(*state.pixel(2, 0), (State::HistoryPixel{30, 123}));
}

TEST(XochitlHistoryState, MaskedFastReseedAppliesNewestOverlappingRawLast) {
  State state;
  ASSERT_TRUE(state.initialize_cold_clear(30));
  const State::InclusiveRect lane{4, 4, 4, 4};
  const State::InclusiveRect execution{4, 4, 11, 5};
  const std::array<std::uint8_t, 2> driven{0x01, 0x00};
  std::array<std::uint8_t, 16> black{};
  std::array<std::uint8_t, 16> marked_white{};
  marked_white[0] = 0x87;
  ASSERT_TRUE(
      state.reseed_fast_region_from_raw(lane, execution, black, 8, driven, 1));
  ASSERT_TRUE(state.reseed_fast_region_from_raw(lane, execution, marked_white,
                                                8, driven, 1));
  const auto final = state.pixel(4, 4);
  ASSERT_TRUE(final.has_value());
  EXPECT_EQ(*final, (State::HistoryPixel{0x80u | 28u, 0}));
}

} // namespace
} // namespace pluto::swtcon
