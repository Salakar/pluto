#ifndef PLUTO_PRESENTER_SWTCON_SWTCON_WAVEFORM_H_
#define PLUTO_PRESENTER_SWTCON_SWTCON_WAVEFORM_H_

#include <array>
#include <cstdint>
#include <map>
#include <span>
#include <string>
#include <vector>

#include "pluto/presenter.h"
#include "presenter/swtcon/swtcon_constants.h"

namespace pluto::swtcon {

enum class SwtconUpdateMode {
  kFast,
  kUi,
  kText,
  kFull,
};

// Decoded `.eink` waveform (reference decoder
// analysis/swtcon/waveforms/decode_eink.py). Pipeline:
// XOR 0x08 -> 16-byte big-endian header -> LZ decompress (0xde0038) ->
// container header + two-level u24 offset table (0xddf630/0xddf550) ->
// per-(mode,temp) RLE record (0xddf740) -> N per-phase 32x32 drive matrices ->
// 3-bit hardware codes via codeLUT. The matrix axis is TRANSPOSED vs the
// runtime packed table: cell for transition src->dst is [dst*32 + src].
class WaveformTable final {
 public:
  bool parse(const std::vector<std::uint8_t>& file_bytes, std::string* error);
  void clear();

  bool valid() const { return valid_; }
  int mode_count() const { return nmode_; }
  int temp_count() const { return ntemp_; }
  const std::vector<std::uint8_t>& temp_thresholds() const {
    return thresholds_;
  }

  // Temperature bin = greatest per-record lower threshold <= the reading
  // (Xochitl 3.27 selector 0x9af630); clamps to the coldest/warmest bin.
  int temp_bin(float temperature_c) const;

  // Number of phase frames N for one (mode, temp bin); 0 when out of range.
  int phase_count(int mode, int temp_bin) const;

  // 1024-entry table of 3-bit drive codes for one phase, indexed by
  // dst5 * 32 + src5 (transposed axis). nullptr when out of range.
  const std::uint8_t* phase_table(int mode, int temp_bin, int phase) const;

  // Complete immutable phase-major record for one (mode, temp bin), laid out
  // as phase_count(mode, temp_bin) consecutive 1024-cell tables.  Each table
  // retains the decoder-native [dst * 32 + src] axis.  Empty when the record
  // is unavailable.  The view is invalidated by parse()/clear() and otherwise
  // remains valid for the lifetime of this table.
  std::span<const std::uint8_t> phase_record_codes(int mode,
                                                   int temp_bin) const;

  // Drive code for pixel transition src->dst (5-bit grays) at one phase:
  // codeLUT[(matrix[phase][dst*32 + src] >> 1) & 7].
  std::uint8_t code(int mode, int temp_bin, std::uint8_t src, std::uint8_t dst,
                    int phase) const;

 private:
  struct Record {
    // phase_count * kWaveformMatrixCells 3-bit codes (codeLUT already applied).
    std::vector<std::uint8_t> codes;
    int phase_count = 0;
  };

  const Record* record(int mode, int temp_bin) const;

  // Records deduped by container offset (mode 0 shares one INIT record
  // across every temp bin).
  std::vector<Record> records_;
  std::vector<std::size_t> record_index_;  // nmode_ * ntemp_ entries
  std::vector<std::uint8_t> thresholds_;   // per-record lower bounds, degC
  int nmode_ = 0;
  int ntemp_ = 0;
  bool valid_ = false;
};

// Stage-2 LZ decompressor (0xde0038), exposed for unit tests. 4-byte records
// {offset:u16 LE, count:u8, literal:u8}: copy `count` bytes from
// out[out_size - offset], then append the literal. Byte-exact vs
// decode_eink.py, including the trailing partial-record zero padding.
bool eink_lz_decompress(const std::uint8_t* payload, std::size_t size,
                        std::vector<std::uint8_t>* out, std::string* error);

// Variable-length phase-code sequence for one pixel transition, played once.
struct PhaseSequence {
  std::vector<std::uint8_t> values;
  bool from_waveform = false;
};

class WaveformFileReader {
 public:
  virtual ~WaveformFileReader() = default;
  virtual bool read_file(const std::string& path,
                         std::vector<std::uint8_t>* out,
                         std::string* error) const = 0;
};

class RealWaveformFileReader final : public WaveformFileReader {
 public:
  bool read_file(const std::string& path, std::vector<std::uint8_t>* out,
                 std::string* error) const override;
};

class SwtconWaveform final {
 public:
  struct Files {
    std::string eink_path;
    std::string ct33_std_path = "/usr/share/remarkable/ct33_std.bin";
    std::string ct33_best_path = "/usr/share/remarkable/ct33_best.bin";
    std::string ct33_pen_path = "/usr/share/remarkable/ct33_pen.bin";
    std::string ct33_fast_path = "/usr/share/remarkable/ct33_fast.bin";
  };

  bool load(const Files& files, const WaveformFileReader& reader,
            std::string* error);

  PhaseSequence lookup(SwtconUpdateMode mode, std::uint8_t src,
                       std::uint8_t dst, float temperature_c) const;

  const WaveformTable& table() const { return table_; }
  const std::vector<std::uint8_t>& eink_bytes() const { return eink_bytes_; }
  // ct33 blobs are the colour front-end — kept for the future colour
  // pipeline, never used for drive codes.
  const std::map<std::string, std::vector<std::uint8_t>>& ct33_bytes() const {
    return ct33_bytes_;
  }
  bool loaded() const { return loaded_; }

 private:
  std::vector<std::uint8_t> eink_bytes_;
  std::map<std::string, std::vector<std::uint8_t>> ct33_bytes_;
  WaveformTable table_;
  bool loaded_ = false;
};

struct PhaseLookup {
  const SwtconWaveform* waveform = nullptr;
  SwtconUpdateMode mode = SwtconUpdateMode::kUi;
  float temperature_c = 25.0f;
  bool use_fixed_phase_value = false;
  std::uint8_t fixed_phase_value = 0;

  // N phase frames this lookup drives: the decoded table's N for
  // (mode, temp bin), or kActivePhaseSlots for the fixed-value diagnostic
  // path; 0 when no decoded table is available.
  int phase_count() const;
  // Decoded 1024-entry code table for one phase (index dst5*32+src5);
  // nullptr for the fixed-value path or when no table is loaded.
  const std::uint8_t* phase_table(int phase) const;
  PhaseSequence phase_values(std::uint8_t src, std::uint8_t dst) const;
};

SwtconUpdateMode update_mode_from_refresh_class(
    PlutoRefreshClass refresh_class);

// 5-bit luma gray on the RENDERER's lattice (denominator 30): 0=black ..
// 30=paper white. Slot 31 is the waveform rail and is never produced —
// real tables carry no drive codes into dst=31, so targeting it makes
// black->white erases optically inert. Lives with the decoder (not the
// legacy packer): it defines the engine's level space for every
// RGB565 -> gray5 conversion in the presenter.
std::uint8_t rgb565_to_gray5(std::uint16_t rgb565);

// Rect content conversion: RGB565 (little-endian byte pairs, `src` at the
// rect's first pixel, `src_stride_bytes` surface pitch) -> legalized 5-bit
// levels, `out` tightly pitched at `width`. Per pixel this is EXACTLY
// `legal_targets[rgb565_to_gray5(px) & 0x1f]` — the scheduler-thread hot
// path for every content admission (up to full-panel 954x1696 = 1.6 Mpx on
// the large lane).
//
// Contracts (mirrors sweep_kernels.h):
//   * convert_rgb565_levels_scalar is the bit-exact reference.
//   * convert_rgb565_levels_neon (aarch64) must be byte-identical vs the
//     scalar for EVERY rgb565 input x ANY 32-byte map — exhaustively
//     golden-tested in test/presenter/convert_levels_test.cc (all 65536
//     inputs x identity/sparse/random maps, plus tail widths).
//   * The unsuffixed convert_rgb565_levels dispatches to the fastest
//     available implementation.
void convert_rgb565_levels_scalar(const std::uint8_t* src,
                                  std::size_t src_stride_bytes,
                                  std::int32_t width, std::int32_t height,
                                  const std::uint8_t* legal_targets,
                                  std::uint8_t* out);

#if defined(__ARM_NEON) && defined(__aarch64__)
void convert_rgb565_levels_neon(const std::uint8_t* src,
                                std::size_t src_stride_bytes,
                                std::int32_t width, std::int32_t height,
                                const std::uint8_t* legal_targets,
                                std::uint8_t* out);
#endif

inline void convert_rgb565_levels(const std::uint8_t* src,
                                  std::size_t src_stride_bytes,
                                  std::int32_t width, std::int32_t height,
                                  const std::uint8_t* legal_targets,
                                  std::uint8_t* out) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  convert_rgb565_levels_neon(src, src_stride_bytes, width, height,
                             legal_targets, out);
#else
  convert_rgb565_levels_scalar(src, src_stride_bytes, width, height,
                               legal_targets, out);
#endif
}

// True when (mode, temp_bin) carries at least one nonzero drive code for the
// src -> dst transition (all-hold sequences are optically inert).
bool transition_driven(const WaveformTable& table, int mode, int temp_bin,
                       std::uint8_t src, std::uint8_t dst);

// Per-(mode, temp-bin) content-target legalization: maps each 5-bit level to
// the nearest level the mode can actually DRIVE from both rails (black src 0
// and white src 30, with +-2 rail slack counting as reachable without a
// drive). Real tables are sparse — GAL3 mode 7 is bilevel {2, 28}, mode 1 an
// 8-level lattice — and an unsupported target silently holds, leaving stale
// content on glass while prev latches the never-driven level. Hold-only
// (synthetic) tables legalize to identity.
std::array<std::uint8_t, 32> build_legal_target_map(const WaveformTable& table,
                                                    int mode, int temp_bin);

inline constexpr std::uint8_t kMode7FastBlackEndpoint = 2;
inline constexpr std::uint8_t kMode7FastWhiteEndpoint = 28;

// Fail-closed signature gate for the installed Gallery-3 Fast recovery
// waveform. Every one of the nine temperature bins must expose exactly the
// bilevel {2,28} target lattice and N=11 rail crossings: 2->28 is ten code-1
// drives then HOLD, 28->2 is ten code-6 drives then HOLD. Logical rails 0/30
// must not masquerade as terminal recovery endpoints.
bool supports_mode7_fast_recovery(const WaveformTable& table);

// .eink mode index for a refresh class. Mode identities are classified by
// drive signature: 0=INIT/clear, 2/5/6=flashing GC16-family, 1/3/4=non-flash
// GL16-family, 7/8=fast partial. Full -> mode 2 is the presenter's proven
// target. Fast/UI both use mode 7 for now: on-device renderer traces showed
// mode 8's 4-phase shortcut under-driving normal UI, leaving old content
// visually stuck between quality passes.
int waveform_mode_index(SwtconUpdateMode mode);

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_SWTCON_WAVEFORM_H_
