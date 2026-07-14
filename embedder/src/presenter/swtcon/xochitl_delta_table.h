#ifndef PLUTO_PRESENTER_SWTCON_XOCHITL_DELTA_TABLE_H_
#define PLUTO_PRESENTER_SWTCON_XOCHITL_DELTA_TABLE_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace pluto::swtcon {

class WaveformTable;

inline constexpr std::size_t kXochitlDeltaTableEntries = 32u * 32u;

// Fail-closed result from the pinned Xochitl 3.27.1.0 history-delta builder.
// `values` is all zero unless error == kNone.  `failing_transition` uses the
// mapper's source*32+drive orientation and is npos when no single transition
// caused the failure.
enum class XochitlDeltaError : std::uint8_t {
  kNone = 0,
  kInvalidWaveformTable,
  kInvalidMode,
  kInvalidTemperatureBin,
  kInvalidPhaseRecord,
  kEmptyPhaseSequence,
  kUnsupportedPhaseCode,
  kNonFiniteResult,
  kOutOfRange,
};

struct XochitlDeltaTableResult {
  static constexpr std::size_t kNoTransition = static_cast<std::size_t>(-1);

  XochitlDeltaError error = XochitlDeltaError::kNone;
  std::size_t failing_transition = kNoTransition;
  std::array<std::int16_t, kXochitlDeltaTableEntries> values{};

  explicit operator bool() const { return error == XochitlDeltaError::kNone; }
};

// Low-level record surface used by the WaveformTable overload and focused
// tests. `phase_major_codes` is decoder-native:
//
//   [phase][drive_destination * 32 + source]
//
// Its size must be a non-zero whole number of 1024-cell phase tables.  Only
// installed drive codes 0..6 are accepted; code 7 fails before any output is
// exposed.  `temperature_bin` selects one of the exact nine installed
// binary64 parameter records.
XochitlDeltaTableResult
build_xochitl_delta_table(std::span<const std::uint8_t> phase_major_codes,
                          int temperature_bin);

// Builds directly from one decoded waveform record.  This overload validates
// the WaveformTable, mode, temperature bin, and phase record before delegating
// to the exact builder above.
XochitlDeltaTableResult build_xochitl_delta_table(const WaveformTable &waveform,
                                                  int mode,
                                                  int temperature_bin);

} // namespace pluto::swtcon

#endif // PLUTO_PRESENTER_SWTCON_XOCHITL_DELTA_TABLE_H_
