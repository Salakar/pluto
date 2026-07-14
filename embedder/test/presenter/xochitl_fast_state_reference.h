#ifndef PLUTO_TEST_PRESENTER_XOCHITL_FAST_STATE_REFERENCE_H_
#define PLUTO_TEST_PRESENTER_XOCHITL_FAST_STATE_REFERENCE_H_

#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

// TEST/RESEARCH-ONLY scalar model of the installed Xochitl 3.27.1.0
// mode-7 source and continuation paths at 0x009af8a0 and 0x009b09e4.
// This model is linked only into the production-disconnected reference-test
// executable.  It is not a presenter implementation or a colour-capability
// gate.
namespace pluto::swtcon::xochitl_fast_reference {

struct InclusiveRect {
  std::int32_t left = 0;
  std::int32_t top = 0;
  std::int32_t right = -1;
  std::int32_t bottom = -1;
};

enum class MapError : std::uint8_t {
  kNone = 0,
  kInvalidGeometry,
  kBufferTooSmall,
  kInvalidTemperature,
};

struct Operation {
  std::int32_t panel_width = 0;
  std::int32_t panel_height = 0;
  InclusiveRect update{};

  // The non-null-source branch consumes raw[0] as update.{left,top} and uses
  // raw_stride only to reach the next operation-local row.  It classifies
  // raw&31==7 as the high/white Fast endpoint; every other value is the
  // low/dark endpoint.  Bit 7 is copied into A as the exact-white marker.
  std::span<const std::uint8_t> raw;
  std::size_t raw_stride = 0;

  // Stock's process-wide interleaved [A,B] plane.  A low five bits are the
  // currently represented physical state; B bits 15:2 are signed history and
  // bits 1:0 are the Fast continuation countdown.
  std::span<std::uint16_t> ab;
  std::size_t ab_stride = 0;  // pixels, not u16 elements
  std::size_t ab_storage_height = 0;

  float temperature_c = 25.0f;
};

struct Result {
  MapError error = MapError::kNone;
  InclusiveRect execution{};
  std::int32_t width = 0;
  std::int32_t height = 0;
  std::vector<std::uint16_t> transitions;
  bool needs_continuation = false;
  bool encountered_mid_state = false;

  explicit operator bool() const { return error == MapError::kNone; }
};

constexpr std::uint16_t transition(std::uint8_t source,
                                   std::uint8_t destination) {
  return static_cast<std::uint16_t>(
      (static_cast<std::uint16_t>(source & 31u) << 5) |
      static_cast<std::uint16_t>(destination & 31u));
}

// Exact non-null-source mode-7 step.  The operation width is rounded up to
// eight lanes and height to two rows, matching the stock SIMD/tail paths.
Result map_source(const Operation& operation);

// Exact ctx+0x00==nullptr continuation step.  raw/raw_stride are ignored, but
// the same rounded A/B/output execution geometry is used.
Result map_continuation(const Operation& operation);

}  // namespace pluto::swtcon::xochitl_fast_reference

#endif  // PLUTO_TEST_PRESENTER_XOCHITL_FAST_STATE_REFERENCE_H_
