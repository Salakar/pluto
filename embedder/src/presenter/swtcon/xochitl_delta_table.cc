#include "presenter/swtcon/xochitl_delta_table.h"

#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_waveform.h"

#include <array>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace pluto::swtcon {
namespace {

// Xochitl 3.27.1.0 read-only material consumed by 0x009ae520. Hexadecimal
// literals preserve the installed ELF's binary64 payloads exactly.
constexpr std::array<double, 9> kDecay = {
    0x1.68f9b27b4b9e0p+5, 0x1.958843fa51b54p+5, 0x1.b2ad5776faafbp+5,
    0x1.c0b817d245a02p+5, 0x1.cb850cc221669p+5, 0x1.bf94e596a7609p+5,
    0x1.9504c0fda45c5p+5, 0x1.5a6b3b3fefefep+5, 0x1.2b1158867271fp+5};
constexpr std::array<double, 9> kCoefficientNumerator = {
    0x1.42eb8ea5b2954p-5, 0x1.c59293158433bp-5, 0x1.4070d5c0756e8p-4,
    0x1.bfe7e25449b98p-4, 0x1.31b02cafb19b0p-3, 0x1.99d3446b299e7p-3,
    0x1.185f24c484c06p-2, 0x1.91d53b108fd71p-2, 0x1.1521a64d1d32bp-1};
constexpr std::array<double, 9> kGain = {
    0x1.6fe78493eccc6p+13, 0x1.083f3876ae831p+13, 0x1.77e04b634cb26p+12,
    0x1.0d7f77b68aa7ep+12, 0x1.8b841ca1f9a4ap+11, 0x1.267d057aeeb77p+11,
    0x1.ab728c9cdd18ap+10, 0x1.09affeeadfdadp+10, 0x1.7996a9d6cb5dcp+9};
constexpr std::array<double, 7> kVoltage = {0.0, -24.0, -12.0, -6.0,
                                            6.0, 12.0,  24.0};
constexpr double kFrameRate = 85.0;
constexpr std::size_t kMaximumPhaseCount = 1024;

static_assert(kWaveformMatrixCells ==
              static_cast<int>(kXochitlDeltaTableEntries));
static_assert(sizeof(double) == sizeof(std::uint64_t));
static_assert(std::numeric_limits<double>::is_iec559);

double rounded_product(double lhs, double rhs) {
  // Materializing the binary64 bits makes this rounding point observable and
  // prevents contraction with the following std::fma.
  return std::bit_cast<double>(std::bit_cast<std::uint64_t>(lhs * rhs));
}

double rounded_quotient(double numerator, double denominator) {
  return std::bit_cast<double>(
      std::bit_cast<std::uint64_t>(numerator / denominator));
}

XochitlDeltaTableResult
fail(XochitlDeltaError error,
     std::size_t transition = XochitlDeltaTableResult::kNoTransition) {
  XochitlDeltaTableResult result;
  result.error = error;
  result.failing_transition = transition;
  return result;
}

std::size_t waveform_offset(std::size_t mapper_transition) {
  const std::size_t source = mapper_transition >> 5;
  const std::size_t drive = mapper_transition & 31u;
  return drive * 32u + source;
}

} // namespace

XochitlDeltaTableResult
build_xochitl_delta_table(std::span<const std::uint8_t> phase_major_codes,
                          int temperature_bin) {
  if (temperature_bin < 0 ||
      temperature_bin >= static_cast<int>(kDecay.size())) {
    return fail(XochitlDeltaError::kInvalidTemperatureBin);
  }
  if (phase_major_codes.empty()) {
    return fail(XochitlDeltaError::kEmptyPhaseSequence, 0);
  }
  if ((phase_major_codes.size() % kXochitlDeltaTableEntries) != 0) {
    return fail(XochitlDeltaError::kInvalidPhaseRecord);
  }
  const std::size_t phase_count =
      phase_major_codes.size() / kXochitlDeltaTableEntries;
  if (phase_count == 0 || phase_count > kMaximumPhaseCount) {
    return fail(XochitlDeltaError::kInvalidPhaseRecord);
  }

  // Validate every transition before calculating any value.  The installed
  // voltage table has seven entries; code 7 would read unrelated rodata in
  // the stock function and is therefore never tolerated here.
  for (std::size_t transition = 0; transition < kXochitlDeltaTableEntries;
       ++transition) {
    const std::size_t cell = waveform_offset(transition);
    for (std::size_t phase = 0; phase < phase_count; ++phase) {
      const std::uint8_t code =
          phase_major_codes[phase * kXochitlDeltaTableEntries + cell];
      if (code >= kVoltage.size()) {
        return fail(XochitlDeltaError::kUnsupportedPhaseCode, transition);
      }
    }
  }

  XochitlDeltaTableResult result;
  const std::size_t bin = static_cast<std::size_t>(temperature_bin);
  const double decay = kDecay[bin];
  const double coefficient = rounded_quotient(
      rounded_quotient(kCoefficientNumerator[bin], kFrameRate), decay);
  const double negative_gain = -kGain[bin];

  for (std::size_t transition = 0; transition < kXochitlDeltaTableEntries;
       ++transition) {
    const std::size_t cell = waveform_offset(transition);
    const std::size_t last = phase_count - 1;
    double accumulator = 0.0;
    for (std::size_t phase = 0; phase < phase_count; ++phase) {
      const double age_frames = static_cast<double>(last - phase);
      const double age_seconds = rounded_quotient(age_frames, kFrameRate);
      const double exponent = rounded_quotient(-age_seconds, decay);
      const double weight = std::exp(exponent);
      const std::uint8_t code =
          phase_major_codes[phase * kXochitlDeltaTableEntries + cell];
      const double scaled_impulse =
          rounded_product(coefficient, kVoltage[code]);
      accumulator = std::fma(scaled_impulse, weight, accumulator);
    }

    const double tail_seconds =
        rounded_quotient(static_cast<double>(last), kFrameRate);
    const double tail = std::exp(rounded_quotient(tail_seconds, decay));
    accumulator = rounded_product(accumulator, tail);
    accumulator = rounded_product(accumulator, negative_gain);
    accumulator = rounded_product(accumulator, 16.0);
    if (!std::isfinite(accumulator)) {
      result.values.fill(0);
      result.error = XochitlDeltaError::kNonFiniteResult;
      result.failing_transition = transition;
      return result;
    }
    const double rounded = std::round(accumulator); // FCVTAS: ties away
    if (rounded < std::numeric_limits<std::int16_t>::min() ||
        rounded > std::numeric_limits<std::int16_t>::max()) {
      result.values.fill(0);
      result.error = XochitlDeltaError::kOutOfRange;
      result.failing_transition = transition;
      return result;
    }
    result.values[transition] = static_cast<std::int16_t>(rounded);
  }
  return result;
}

XochitlDeltaTableResult build_xochitl_delta_table(const WaveformTable &waveform,
                                                  int mode,
                                                  int temperature_bin) {
  if (!waveform.valid()) {
    return fail(XochitlDeltaError::kInvalidWaveformTable);
  }
  if (mode < 0 || mode >= waveform.mode_count()) {
    return fail(XochitlDeltaError::kInvalidMode);
  }
  if (temperature_bin < 0 ||
      temperature_bin >= static_cast<int>(kDecay.size()) ||
      temperature_bin >= waveform.temp_count()) {
    return fail(XochitlDeltaError::kInvalidTemperatureBin);
  }
  const std::span<const std::uint8_t> record =
      waveform.phase_record_codes(mode, temperature_bin);
  if (record.empty()) {
    return fail(XochitlDeltaError::kEmptyPhaseSequence, 0);
  }
  return build_xochitl_delta_table(record, temperature_bin);
}

} // namespace pluto::swtcon
