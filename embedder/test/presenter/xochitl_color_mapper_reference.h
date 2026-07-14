#ifndef PLUTO_TEST_PRESENTER_XOCHITL_COLOR_MAPPER_REFERENCE_H_
#define PLUTO_TEST_PRESENTER_XOCHITL_COLOR_MAPPER_REFERENCE_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

// TEST/RESEARCH-ONLY exact scalar model of the installed Xochitl 3.27.1.0
// legacy colour-state mapper at 0x004814a0.  This file is linked only into a
// dedicated test executable.  It deliberately has no production linkage:
// runtime-oracle parity, selector provenance, the mode-7 state bridge, and
// optical calibration remain release gates.
namespace pluto::swtcon::xochitl_reference {

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
  kUnsupportedPaletteState,
};

enum class DeltaBuildError : std::uint8_t {
  kNone = 0,
  kInvalidTemperatureBin,
  kInvalidTransitionCount,
  kEmptyPhaseSequence,
  kUnsupportedPhaseCode,
  kNonFiniteResult,
  kOutOfRange,
};

struct DeltaTableResult {
  DeltaBuildError error = DeltaBuildError::kNone;
  std::size_t failing_transition = static_cast<std::size_t>(-1);
  std::array<std::int16_t, 1024> values{};

  explicit operator bool() const { return error == DeltaBuildError::kNone; }
};

struct Operation {
  std::int32_t panel_width = 0;
  std::int32_t panel_height = 0;
  InclusiveRect update{};

  // Operation-local ct33/luma byte plane.  0x004814a0 treats raw[0] as the
  // first lane of update.{left,top}; absolute panel coordinates affect A/B,
  // not this source pointer.  Rows/lanes must cover the mapper's vector-padded
  // execution extent (width rounded up to 8, height rounded up to 2).  The
  // mapper consumes raw & 31 as a palette index and raw bit 7 as the
  // exact-white marker.
  std::span<const std::uint8_t> raw;
  std::size_t raw_stride = 0;  // bytes / operation-local row

  // Full persistent plane, interleaved [A0,B0,A1,B1,...].  ab_stride is in
  // pixels, not u16 elements.  The stock allocation uses stride 968 for a
  // 960x1696 active panel.
  std::span<std::uint16_t> ab;
  std::size_t ab_stride = 0;
  std::size_t ab_storage_height = 0;

  // Active stock palettes contain 16 bytes.  Entries 0..31 are logical
  // states; 32 is a sentinel and must fail closed in this legacy model.
  std::span<const std::uint8_t> palette;

  // Selected waveform/temperature record's signed history delta.  This table
  // is indexed in mapper orientation: source*32 + drive destination.
  std::span<const std::int16_t> delta;
};

struct Result {
  MapError error = MapError::kNone;
  InclusiveRect execution{};
  std::int32_t width = 0;
  std::int32_t height = 0;
  // Tight, row-major transition words for the vector-padded execution extent
  // (source*32 + drive).  The stock output descriptor's extra eight columns
  // and any final zero row are transport allocation, not included here.
  std::vector<std::uint16_t> transitions;

  explicit operator bool() const { return error == MapError::kNone; }
};

constexpr std::uint16_t mapper_transition(std::uint8_t source,
                                          std::uint8_t drive_destination) {
  return static_cast<std::uint16_t>(
      (static_cast<std::uint16_t>(source & 31u) << 5) |
      static_cast<std::uint16_t>(drive_destination & 31u));
}

// Pluto's decoded WaveformTable stores a phase matrix transposed relative
// to Xochitl's emitted transition word: [destination*32 + source].
constexpr std::size_t waveform_phase_offset(std::uint16_t transition) {
  const std::size_t source = (transition >> 5) & 31u;
  const std::size_t destination = transition & 31u;
  return destination * 32u + source;
}

// Reconstructs the selected record's mapper-oriented int16 delta table from
// 1024 decoded phase-code sequences and one of Xochitl's nine temperature
// records.  Valid phase codes are 0..6.  The installed panel waveforms never
// contain code 7; this reference rejects it before producing any table state.
// The implementation preserves 0x009ae520's binary64 operation order,
// including a rounded coefficient*voltage multiply before std::fma.
DeltaTableResult build_delta_table(
    std::span<const std::vector<std::uint8_t>> phase_codes,
    std::size_t temperature_bin);

// Maps one direct-call operation from a frozen operation-local raw/A/B
// snapshot, including Xochitl's 8x2 vector rounding, then commits every A/B
// result together.  Any validation/palette failure leaves A/B untouched.
Result map_operation(const Operation& operation);

}  // namespace pluto::swtcon::xochitl_reference

#endif  // PLUTO_TEST_PRESENTER_XOCHITL_COLOR_MAPPER_REFERENCE_H_
