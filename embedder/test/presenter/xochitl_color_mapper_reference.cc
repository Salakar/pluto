#include "xochitl_color_mapper_reference.h"

#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <utility>
#include <vector>

namespace pluto::swtcon::xochitl_reference {
namespace {

constexpr std::array<std::pair<int, int>, 5> kVonNeumann = {
    std::pair{0, 0}, std::pair{0, -1}, std::pair{0, 1},
    std::pair{-1, 0}, std::pair{1, 0}};

// Xochitl 3.27.1.0 read-only material used by 0x009ae520.  Hexadecimal
// literals preserve the installed ELF's binary64 payloads exactly.
constexpr std::array<double, 9> kDecay = {
    0x1.68f9b27b4b9e0p+5, 0x1.958843fa51b54p+5,
    0x1.b2ad5776faafbp+5, 0x1.c0b817d245a02p+5,
    0x1.cb850cc221669p+5, 0x1.bf94e596a7609p+5,
    0x1.9504c0fda45c5p+5, 0x1.5a6b3b3fefefep+5,
    0x1.2b1158867271fp+5};
constexpr std::array<double, 9> kCoefficientNumerator = {
    0x1.42eb8ea5b2954p-5, 0x1.c59293158433bp-5,
    0x1.4070d5c0756e8p-4, 0x1.bfe7e25449b98p-4,
    0x1.31b02cafb19b0p-3, 0x1.99d3446b299e7p-3,
    0x1.185f24c484c06p-2, 0x1.91d53b108fd71p-2,
    0x1.1521a64d1d32bp-1};
constexpr std::array<double, 9> kGain = {
    0x1.6fe78493eccc6p+13, 0x1.083f3876ae831p+13,
    0x1.77e04b634cb26p+12, 0x1.0d7f77b68aa7ep+12,
    0x1.8b841ca1f9a4ap+11, 0x1.267d057aeeb77p+11,
    0x1.ab728c9cdd18ap+10, 0x1.09affeeadfdadp+10,
    0x1.7996a9d6cb5dcp+9};
constexpr std::array<double, 7> kVoltage = {0.0,  -24.0, -12.0, -6.0,
                                             6.0, 12.0,  24.0};
constexpr double kFrameRate = 85.0;
static_assert(sizeof(double) == sizeof(std::uint64_t));
static_assert(std::numeric_limits<double>::is_iec559);

double rounded_product(double lhs, double rhs) {
  // A bit-cast materialization makes the binary64 rounding point observable,
  // preventing contraction with the following std::fma.
  const auto bits = std::bit_cast<std::uint64_t>(lhs * rhs);
  return std::bit_cast<double>(bits);
}

double rounded_quotient(double numerator, double denominator) {
  const auto bits =
      std::bit_cast<std::uint64_t>(numerator / denominator);
  return std::bit_cast<double>(bits);
}

bool valid_plane_size(std::size_t size, std::size_t stride,
                      std::int32_t width, std::int32_t height,
                      std::size_t elements_per_pixel) {
  if (width <= 0 || height <= 0 || stride < static_cast<std::size_t>(width)) {
    return false;
  }
  const std::size_t rows = static_cast<std::size_t>(height - 1);
  if (stride != 0 && rows >
                         (std::numeric_limits<std::size_t>::max() -
                          static_cast<std::size_t>(width)) /
                             stride) {
    return false;
  }
  const std::size_t pixels = rows * stride + static_cast<std::size_t>(width);
  if (pixels > std::numeric_limits<std::size_t>::max() / elements_per_pixel) {
    return false;
  }
  return size >= pixels * elements_per_pixel;
}

std::int32_t arithmetic_shift_right_2(std::int16_t value) {
  const std::int32_t widened = value;
  if (widened >= 0) {
    return widened / 4;
  }
  // Match AArch64 ASR (round toward negative infinity), independent of the
  // host compiler's signed-right-shift convention.
  return -(((-widened) + 3) / 4);
}

}  // namespace

DeltaTableResult build_delta_table(
    std::span<const std::vector<std::uint8_t>> phase_codes,
    std::size_t temperature_bin) {
  DeltaTableResult result;
  if (temperature_bin >= kDecay.size()) {
    result.error = DeltaBuildError::kInvalidTemperatureBin;
    return result;
  }
  if (phase_codes.size() != result.values.size()) {
    result.error = DeltaBuildError::kInvalidTransitionCount;
    return result;
  }

  // Validate the complete record before calculating any entry.  Code 7 would
  // index past Xochitl's seven-value voltage table into unrelated rodata; no
  // installed waveform uses it, so a reconstruction must fail closed.
  for (std::size_t transition = 0; transition < phase_codes.size();
       ++transition) {
    if (phase_codes[transition].empty()) {
      result.error = DeltaBuildError::kEmptyPhaseSequence;
      result.failing_transition = transition;
      return result;
    }
    for (const std::uint8_t code : phase_codes[transition]) {
      if (code >= kVoltage.size()) {
        result.error = DeltaBuildError::kUnsupportedPhaseCode;
        result.failing_transition = transition;
        return result;
      }
    }
  }

  const double decay = kDecay[temperature_bin];
  const double coefficient = rounded_quotient(
      rounded_quotient(kCoefficientNumerator[temperature_bin], kFrameRate),
      decay);
  const double negative_gain = -kGain[temperature_bin];

  for (std::size_t transition = 0; transition < phase_codes.size();
       ++transition) {
    const auto& phases = phase_codes[transition];
    const std::size_t last = phases.size() - 1;
    double accumulator = 0.0;
    for (std::size_t phase = 0; phase < phases.size(); ++phase) {
      const double age_frames = static_cast<double>(last - phase);
      const double age_seconds = rounded_quotient(age_frames, kFrameRate);
      const double exponent =
          rounded_quotient(-age_seconds, decay);
      const double weight = std::exp(exponent);
      const double scaled_impulse =
          rounded_product(coefficient, kVoltage[phases[phase]]);
      accumulator = std::fma(scaled_impulse, weight, accumulator);
    }

    const double tail_seconds =
        rounded_quotient(static_cast<double>(last), kFrameRate);
    const double tail =
        std::exp(rounded_quotient(tail_seconds, decay));
    accumulator = rounded_product(accumulator, tail);
    accumulator = rounded_product(accumulator, negative_gain);
    accumulator = rounded_product(accumulator, 16.0);
    if (!std::isfinite(accumulator)) {
      result.values.fill(0);
      result.error = DeltaBuildError::kNonFiniteResult;
      result.failing_transition = transition;
      return result;
    }
    const double rounded = std::round(accumulator);  // FCVTAS tie direction
    if (rounded < std::numeric_limits<std::int16_t>::min() ||
        rounded > std::numeric_limits<std::int16_t>::max()) {
      result.values.fill(0);
      result.error = DeltaBuildError::kOutOfRange;
      result.failing_transition = transition;
      return result;
    }
    result.values[transition] = static_cast<std::int16_t>(rounded);
  }
  return result;
}

Result map_operation(const Operation& operation) {
  Result result;
  const auto& r = operation.update;
  if (operation.panel_width <= 0 || operation.panel_height <= 0 ||
      r.left < 0 || r.top < 0 || r.right < r.left || r.bottom < r.top ||
      r.right >= operation.panel_width || r.bottom >= operation.panel_height) {
    result.error = MapError::kInvalidGeometry;
    return result;
  }

  const std::int64_t logical_width =
      static_cast<std::int64_t>(r.right) - r.left + 1;
  const std::int64_t logical_height =
      static_cast<std::int64_t>(r.bottom) - r.top + 1;
  const std::int64_t execution_width = (logical_width + 7) & ~std::int64_t{7};
  const std::int64_t execution_height = (logical_height + 1) & ~std::int64_t{1};
  const std::int64_t execution_right =
      static_cast<std::int64_t>(r.left) + execution_width - 1;
  const std::int64_t execution_bottom =
      static_cast<std::int64_t>(r.top) + execution_height - 1;
  if (execution_width > std::numeric_limits<std::int32_t>::max() ||
      execution_height > std::numeric_limits<std::int32_t>::max() ||
      execution_right > std::numeric_limits<std::int32_t>::max() ||
      execution_bottom > std::numeric_limits<std::int32_t>::max() ||
      operation.ab_stride >
          static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max()) ||
      operation.ab_storage_height >
          static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max()) ||
      static_cast<std::int64_t>(r.left) + execution_width >
          static_cast<std::int64_t>(operation.ab_stride) ||
      static_cast<std::int64_t>(r.top) + execution_height >
          static_cast<std::int64_t>(operation.ab_storage_height)) {
    result.error = MapError::kInvalidGeometry;
    return result;
  }
  result.width = static_cast<std::int32_t>(execution_width);
  result.height = static_cast<std::int32_t>(execution_height);
  result.execution = {r.left, r.top,
                      static_cast<std::int32_t>(execution_right),
                      static_cast<std::int32_t>(execution_bottom)};

  if (!valid_plane_size(operation.raw.size(), operation.raw_stride,
                        result.width, result.height, 1) ||
      !valid_plane_size(operation.ab.size(), operation.ab_stride,
                        static_cast<std::int32_t>(operation.ab_stride),
                        static_cast<std::int32_t>(operation.ab_storage_height),
                        2) ||
      operation.delta.size() != 1024 || operation.palette.empty()) {
    result.error = MapError::kBufferTooSmall;
    return result;
  }

  const std::size_t output_pixels =
      static_cast<std::size_t>(result.width) * result.height;

  // Freeze the complete vector-padded operation before doing lane work.  The
  // active SIMD mapper processes two rows and eight columns at a time; this
  // explicit snapshot prevents iteration order, stripe count, or an adjacent
  // commit from feeding back into the same direct-call operation.
  std::vector<std::uint8_t> raw_snapshot(output_pixels);
  std::vector<std::uint16_t> a_snapshot(raw_snapshot.size());
  std::vector<std::uint16_t> b_snapshot(raw_snapshot.size());
  for (std::int32_t y = 0; y < result.height; ++y) {
    for (std::int32_t x = 0; x < result.width; ++x) {
      const std::size_t tight =
          static_cast<std::size_t>(y) * result.width + x;
      raw_snapshot[tight] = operation.raw[static_cast<std::size_t>(y) *
                                              operation.raw_stride +
                                          x];
      const std::size_t ab_index =
          2 * (static_cast<std::size_t>(r.top + y) * operation.ab_stride +
               r.left + x);
      a_snapshot[tight] = operation.ab[ab_index];
      b_snapshot[tight] = operation.ab[ab_index + 1];
    }
  }

  const auto in_domain = [&](std::int32_t x, std::int32_t y) {
    return x >= 0 && y >= 0 && x < result.width && y < result.height;
  };
  const auto tight_index = [&](std::int32_t x, std::int32_t y) {
    return static_cast<std::size_t>(y) * result.width + x;
  };
  const auto mapped_state = [&](std::int32_t x, std::int32_t y,
                                std::uint8_t* mapped) {
    const std::uint8_t index = raw_snapshot[tight_index(x, y)] & 31u;
    if (index >= operation.palette.size()) {
      return false;
    }
    const std::uint8_t value = operation.palette[index];
    if (value > 31u) {
      return false;
    }
    *mapped = value;
    return true;
  };

  // Validate every palette read in the rounded lane domain before allocating
  // commit records.  A sentinel in a padded lane can therefore never leave a
  // partially advanced A/B plane.
  for (std::int32_t y = 0; y < result.height; ++y) {
    for (std::int32_t x = 0; x < result.width; ++x) {
      std::uint8_t ignored = 0;
      if (!mapped_state(x, y, &ignored)) {
        result.error = MapError::kUnsupportedPaletteState;
        return result;
      }
    }
  }

  struct Commit {
    std::size_t ab_index;
    std::uint16_t a;
    std::uint16_t b;
  };
  std::vector<Commit> commits;
  commits.reserve(output_pixels);
  result.transitions.reserve(output_pixels);

  for (std::int32_t y = 0; y < result.height; ++y) {
    for (std::int32_t x = 0; x < result.width; ++x) {
      const std::size_t center = tight_index(x, y);
      const std::uint16_t old_a = a_snapshot[center];
      const std::uint16_t old_b = b_snapshot[center];
      const std::uint8_t source = static_cast<std::uint8_t>(old_a & 31u);
      const std::uint8_t raw = raw_snapshot[center];
      std::uint8_t mapped = 0;
      // Already validated above; keep the check local so the reference stays
      // fail-closed if its validation window is ever changed.
      if (!mapped_state(x, y, &mapped)) {
        result.error = MapError::kUnsupportedPaletteState;
        result.transitions.clear();
        return result;
      }

      int equal_moore = 0;
      for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
          const std::int32_t nx = x + dx;
          const std::int32_t ny = y + dy;
          if (!in_domain(nx, ny)) {
            ++equal_moore;  // direct-call lane-domain halo contributes true
            continue;
          }
          std::uint8_t neighbour_mapped = 0;
          if (!mapped_state(nx, ny, &neighbour_mapped)) {
            result.error = MapError::kUnsupportedPaletteState;
            result.transitions.clear();
            return result;
          }
          const std::uint8_t neighbour_source = static_cast<std::uint8_t>(
              a_snapshot[tight_index(nx, ny)] & 31u);
          equal_moore += neighbour_source == neighbour_mapped ? 1 : 0;
        }
      }

      int old_high_cross = 0;
      int new_high_cross = 0;
      for (const auto& [dx, dy] : kVonNeumann) {
        const std::int32_t nx = x + dx;
        const std::int32_t ny = y + dy;
        if (!in_domain(nx, ny)) {
          ++old_high_cross;
          ++new_high_cross;  // lane-domain halo contributes high/true
          continue;
        }
        const std::size_t neighbour = tight_index(nx, ny);
        old_high_cross += (a_snapshot[neighbour] & 31u) > 27u ? 1 : 0;
        std::uint8_t neighbour_mapped = 0;
        if (!mapped_state(nx, ny, &neighbour_mapped)) {
          result.error = MapError::kUnsupportedPaletteState;
          result.transitions.clear();
          return result;
        }
        new_high_cross += neighbour_mapped > 27u ? 1 : 0;
      }

      const bool white_continuity = (old_a & 0x80u) != 0 &&
                                    (raw & 0x80u) != 0 && source > 27u;
      const bool pair31 = white_continuity && new_high_cross == 5 &&
                          old_high_cross <= 4;
      const bool force27 =
          (equal_moore == 9 || white_continuity) && !pair31;
      const std::uint8_t drive = pair31 ? 31u : force27 ? 27u : mapped;
      const std::uint16_t transition = mapper_transition(source, drive);

      const bool carry_bit6 =
          (old_a & 0x40u) != 0 && source > 27u && mapped > 27u;
      // The setup contribution is independent of the old logical source.
      // Both auxiliary-drive branches suppress it: force27 preserves B's low
      // flags and pair31 selects the white partner, but neither establishes
      // A bit 6.  The separate carry path still requires an old high state.
      const bool set_bit6 = new_high_cross == 5 && !pair31 && !force27 &&
                            (raw & 0x80u) != 0 && mapped > 27u;
      const std::uint16_t next_a = static_cast<std::uint16_t>(
          (mapped & 31u) | (raw & 0x80u) |
          ((carry_bit6 || set_bit6) ? 0x40u : 0u));

      const std::int32_t history =
          arithmetic_shift_right_2(static_cast<std::int16_t>(old_b));
      const std::uint16_t history_sum = static_cast<std::uint16_t>(
          static_cast<std::uint16_t>(history) +
          static_cast<std::uint16_t>(operation.delta[transition]));
      const std::uint16_t next_b = static_cast<std::uint16_t>(
          ((history_sum << 2) & 0xfffcu) |
          (force27 ? (old_b & 3u) : 0u));

      const std::size_t ab_index =
          2 * (static_cast<std::size_t>(r.top + y) * operation.ab_stride +
               r.left + x);
      commits.push_back({ab_index, next_a, next_b});
      result.transitions.push_back(transition);
    }
  }

  for (const auto& commit : commits) {
    operation.ab[commit.ab_index] = commit.a;
    operation.ab[commit.ab_index + 1] = commit.b;
  }
  return result;
}

}  // namespace pluto::swtcon::xochitl_reference
