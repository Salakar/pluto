#ifndef PLUTO_PRESENTER_NATIVE_RM2_WBF_DECODER_H_
#define PLUTO_PRESENTER_NATIVE_RM2_WBF_DECODER_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "runtime/sha256.h"

namespace pluto::native::rm2 {

inline constexpr std::size_t kWbfGrayStates = 32;
inline constexpr std::size_t kWbfTransitions = kWbfGrayStates * kWbfGrayStates;
inline constexpr std::size_t kWbfPackedPhaseBytes = kWbfTransitions / 4;
inline constexpr std::size_t kMaxWbfFileBytes = 16u * 1024u * 1024u;

// Exact identity supplied by the generated device profile. Opening a WBF for
// drive use requires all three bindings: file digest, panel signature from the
// embedded XWI name, and the numeric FPL lot encoded in both header and name.
struct WbfExpectedIdentity {
  std::array<std::uint8_t, kSha256DigestBytes> sha256{};
  std::string panel_signature;
  std::uint16_t fpl_lot = 0;
};

// Validated metadata only. No compressed or decoded vendor waveform bytes are
// exposed here, which makes this safe input for the offline inspection/codegen
// tool.
struct WbfMetadata {
  std::array<std::uint8_t, kSha256DigestBytes> source_sha256{};
  std::uint32_t file_crc32 = 0;
  std::uint32_t file_size = 0;
  std::uint32_t serial = 0;
  std::uint16_t fpl_lot = 0;
  std::uint8_t mode_version = 0;
  std::uint8_t waveform_version = 0;
  std::uint8_t waveform_subversion = 0;
  std::uint8_t frame_rate_hz = 0;
  std::uint8_t mode_count = 0;
  std::uint8_t temperature_count = 0;
  std::string waveform_name;
  std::string panel_signature;
  std::vector<std::uint8_t> temperature_boundaries_celsius;
  // Row-major [mode * temperature_count + temperature].
  std::vector<std::uint16_t> phase_counts;
  std::size_t unique_record_count = 0;
  std::size_t decoded_packed_bytes = 0;
};

// Bounded, endian-explicit decoder for the 5-bit PVI WBF used by reMarkable 2.
// It validates every reachable mode/temperature record at open time and keeps
// deduplicated, phase-major packed 2-bit tables for O(1) drive lookup. WBF
// transition dimensions are independent of framebuffer geometry, mmap length,
// pan slots, and scanout pixel format; those belong to the presenter backend.
//
// This is intentionally a narrow RM2 module rather than refresh policy:
// mapping PlutoRefreshClass to vendor mode indices remains a separate,
// device-validated WaveformProgram concern.
class WbfDecoder final {
public:
  WbfDecoder() = default;

  // Structural inspection validates the complete file, including all RLE
  // records, but does not authorize it for a particular device profile.
  static bool inspect(std::span<const std::uint8_t> bytes,
                      WbfMetadata *out_metadata, std::string *error);

  // Opens only when the structurally valid file matches all expected identity
  // fields exactly. On failure the decoder is reset and cannot serve lookups.
  bool open(std::span<const std::uint8_t> bytes,
            const WbfExpectedIdentity &expected, std::string *error);
  void clear();

  bool valid() const { return valid_; }
  const WbfMetadata &metadata() const { return metadata_; }

  // Selects the greatest lower boundary not exceeding the reading, clamped to
  // the coldest/warmest bin. This mirrors the table's interval semantics while
  // keeping malformed/non-monotonic ladders out at parse time.
  bool select_temperature(int milli_celsius,
                          std::uint32_t *out_temperature) const;

  std::uint32_t phase_count(std::uint32_t mode,
                            std::uint32_t temperature) const;

  // Returns one 2-bit panel drive code for a 5-bit old->new state transition.
  // The WBF matrix axis is [new * 32 + old].
  bool drive_code(std::uint32_t mode, std::uint32_t temperature,
                  std::uint8_t old_level, std::uint8_t new_level,
                  std::uint32_t phase, std::uint8_t *out_code) const;

  // Complete phase-major packed table for future profile-gated codegen/LUT
  // specialization. Four consecutive transitions occupy one byte, least-
  // significant 2-bit lane first. The view remains valid until clear/open.
  std::span<const std::uint8_t> packed_record(std::uint32_t mode,
                                              std::uint32_t temperature) const;

private:
  struct Record {
    std::vector<std::uint8_t> packed;
    std::uint16_t phase_count = 0;
  };

  const Record *record(std::uint32_t mode, std::uint32_t temperature) const;

  WbfMetadata metadata_;
  std::vector<Record> records_;
  std::vector<std::size_t> record_index_;
  bool valid_ = false;
};

std::string
wbf_sha256_hex(const std::array<std::uint8_t, kSha256DigestBytes> &digest);

} // namespace pluto::native::rm2

#endif // PLUTO_PRESENTER_NATIVE_RM2_WBF_DECODER_H_
