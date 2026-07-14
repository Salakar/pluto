#include "xochitl_fast_state_reference.h"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace pluto::swtcon::xochitl_fast_reference {
namespace {

struct Geometry {
  MapError error = MapError::kNone;
  InclusiveRect execution{};
  std::int32_t width = 0;
  std::int32_t height = 0;
};

struct Thermal {
  std::int32_t amplitude = 0;
  std::int32_t threshold = 0;
  std::uint16_t reset_flags = 0;
};

Geometry validate_geometry(const Operation& operation, bool needs_raw) {
  const auto& r = operation.update;
  if (operation.panel_width <= 0 || operation.panel_height <= 0 ||
      r.left < 0 || r.top < 0 || r.right < r.left || r.bottom < r.top ||
      r.right >= operation.panel_width ||
      r.bottom >= operation.panel_height) {
    return {.error = MapError::kInvalidGeometry};
  }

  const std::int64_t logical_width =
      static_cast<std::int64_t>(r.right) - r.left + 1;
  const std::int64_t logical_height =
      static_cast<std::int64_t>(r.bottom) - r.top + 1;
  const std::int64_t width = (logical_width + 7) & ~std::int64_t{7};
  const std::int64_t height = (logical_height + 1) & ~std::int64_t{1};
  const std::int64_t right = static_cast<std::int64_t>(r.left) + width - 1;
  const std::int64_t bottom = static_cast<std::int64_t>(r.top) + height - 1;
  if (width > std::numeric_limits<std::int32_t>::max() ||
      height > std::numeric_limits<std::int32_t>::max() ||
      right > std::numeric_limits<std::int32_t>::max() ||
      bottom > std::numeric_limits<std::int32_t>::max() ||
      operation.ab_stride >
          static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max()) ||
      operation.ab_storage_height >
          static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max()) ||
      static_cast<std::int64_t>(r.left) + width >
          static_cast<std::int64_t>(operation.ab_stride) ||
      static_cast<std::int64_t>(r.top) + height >
          static_cast<std::int64_t>(operation.ab_storage_height)) {
    return {.error = MapError::kInvalidGeometry};
  }

  if (operation.ab_stride != 0 &&
      operation.ab_storage_height >
          std::numeric_limits<std::size_t>::max() / operation.ab_stride) {
    return {.error = MapError::kBufferTooSmall};
  }
  const std::size_t ab_pixels =
      operation.ab_stride * operation.ab_storage_height;
  if (ab_pixels > std::numeric_limits<std::size_t>::max() / 2u ||
      operation.ab.size() < ab_pixels * 2u) {
    return {.error = MapError::kBufferTooSmall};
  }

  if (needs_raw) {
    if (operation.raw_stride < static_cast<std::size_t>(width) ||
        static_cast<std::size_t>(height - 1) >
            (std::numeric_limits<std::size_t>::max() -
             static_cast<std::size_t>(width)) /
                operation.raw_stride) {
      return {.error = MapError::kBufferTooSmall};
    }
    const std::size_t raw_required =
        static_cast<std::size_t>(height - 1) * operation.raw_stride +
        static_cast<std::size_t>(width);
    if (operation.raw.size() < raw_required) {
      return {.error = MapError::kBufferTooSmall};
    }
  }

  return {.execution = {r.left, r.top, static_cast<std::int32_t>(right),
                         static_cast<std::int32_t>(bottom)},
          .width = static_cast<std::int32_t>(width),
          .height = static_cast<std::int32_t>(height)};
}

bool thermal_for(float temperature_c, Thermal* thermal) {
  if (!std::isfinite(temperature_c)) {
    return false;
  }
  // FCVTZS followed by `cmp w0,37` is equivalent to >= 38 for every finite
  // input.  Expressing the boundary directly also avoids an out-of-range C++
  // float-to-int conversion for diagnostic fuzz inputs.
  const bool hot = temperature_c >= 38.0f;
  *thermal = hot ? Thermal{704, 2016, 2} : Thermal{576, 3456, 3};
  return true;
}

std::int32_t arithmetic_shift_right_2(std::int16_t value) {
  const std::int32_t widened = value;
  return widened >= 0 ? widened / 4 : -(((-widened) + 3) / 4);
}

std::int32_t decay_toward_zero_step(std::int32_t history) {
  if (history < 0) {
    return history + 16;
  }
  if (history > 0) {
    return history - 16;
  }
  return 0;
}

std::uint16_t encode_history(std::int32_t history, std::uint16_t flags) {
  return static_cast<std::uint16_t>(
      ((static_cast<std::uint16_t>(history) << 2) & 0xfffcu) |
      (flags & 3u));
}

template <typename LaneMapper>
Result map_impl(const Operation& operation, bool needs_raw,
                LaneMapper&& map_lane) {
  const Geometry geometry = validate_geometry(operation, needs_raw);
  Result result{.error = geometry.error,
                .execution = geometry.execution,
                .width = geometry.width,
                .height = geometry.height};
  if (geometry.error != MapError::kNone) {
    return result;
  }

  Thermal thermal;
  if (!thermal_for(operation.temperature_c, &thermal)) {
    result.error = MapError::kInvalidTemperature;
    return result;
  }

  const std::size_t pixels = static_cast<std::size_t>(geometry.width) *
                             static_cast<std::size_t>(geometry.height);
  result.transitions.reserve(pixels);
  for (std::int32_t y = 0; y < geometry.height; ++y) {
    for (std::int32_t x = 0; x < geometry.width; ++x) {
      const std::size_t ab_index =
          2u * (static_cast<std::size_t>(operation.update.top + y) *
                    operation.ab_stride +
                static_cast<std::size_t>(operation.update.left + x));
      const std::uint16_t old_a = operation.ab[ab_index];
      const std::uint16_t old_b = operation.ab[ab_index + 1];
      const std::uint8_t raw =
          needs_raw ? operation.raw[static_cast<std::size_t>(y) *
                                        operation.raw_stride +
                                    static_cast<std::size_t>(x)]
                    : 0;
      const auto lane = map_lane(old_a, old_b, raw, thermal);
      operation.ab[ab_index] = lane.a;
      operation.ab[ab_index + 1] = lane.b;
      result.transitions.push_back(lane.transition);
      result.needs_continuation |= (lane.b & 3u) != 0;
      result.encountered_mid_state |= lane.mid_state;
    }
  }
  return result;
}

struct Lane {
  std::uint16_t a = 0;
  std::uint16_t b = 0;
  std::uint16_t transition = 0;
  bool mid_state = false;
};

}  // namespace

Result map_source(const Operation& operation) {
  return map_impl(
      operation, true,
      [](std::uint16_t old_a, std::uint16_t old_b, std::uint8_t raw,
         const Thermal& thermal) {
        const std::uint8_t source = static_cast<std::uint8_t>(old_a & 31u);
        const std::int32_t history =
            arithmetic_shift_right_2(static_cast<std::int16_t>(old_b));
        const std::uint16_t flags = old_b & 3u;
        const bool white = (raw & 31u) == 7u;
        const bool old_high = source > 27u;
        const bool mismatch = old_high != white;
        const bool mid_state = source > 2u && source <= 27u;
        const std::int32_t trial =
            history + (white ? thermal.amplitude : -thermal.amplitude);
        const bool hit = flags != 0u && std::abs(trial) <= thermal.threshold;
        const bool partner_hit = !mismatch && hit;
        const std::uint8_t destination =
            white ? (partner_hit ? 30u : 28u)
                  : (partner_hit ? 0u : 2u);
        const std::int32_t history2 =
            (mismatch || hit) ? trial : decay_toward_zero_step(history);
        const std::uint16_t flags2 =
            (mismatch || mid_state)
                ? thermal.reset_flags
                : static_cast<std::uint16_t>(flags - (partner_hit ? 1u : 0u));
        return Lane{.a = static_cast<std::uint16_t>((raw & 0x80u) |
                                                    destination),
                    .b = encode_history(history2, flags2),
                    .transition = transition(source, destination),
                    .mid_state = mid_state};
      });
}

Result map_continuation(const Operation& operation) {
  return map_impl(
      operation, false,
      [](std::uint16_t old_a, std::uint16_t old_b, std::uint8_t,
         const Thermal& thermal) {
        const std::uint8_t source = static_cast<std::uint8_t>(old_a & 31u);
        const std::int32_t history =
            arithmetic_shift_right_2(static_cast<std::int16_t>(old_b));
        const std::uint16_t flags = old_b & 3u;
        const bool high = source > 27u;
        const std::int32_t trial =
            history + (high ? thermal.amplitude : -thermal.amplitude);
        const bool hit = flags != 0u && std::abs(trial) <= thermal.threshold;
        const std::int32_t history2 =
            hit ? trial : decay_toward_zero_step(history);
        const std::uint16_t flags2 =
            static_cast<std::uint16_t>(flags - (hit ? 1u : 0u));
        const std::uint8_t destination =
            flags == 0u ? source
                        : high ? (hit ? 30u : 28u) : (hit ? 0u : 2u);
        const std::uint8_t drive = flags == 0u ? 27u : destination;
        return Lane{.a = static_cast<std::uint16_t>((old_a & 0x80u) |
                                                    destination),
                    .b = encode_history(history2, flags2),
                    .transition = transition(source, drive),
                    .mid_state = source > 2u && source <= 27u};
      });
}

}  // namespace pluto::swtcon::xochitl_fast_reference
