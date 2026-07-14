#ifndef PLUTO_PRESENTER_SWTCON_PHASE_EMIT_H_
#define PLUTO_PRESENTER_SWTCON_PHASE_EMIT_H_

#include "presenter/swtcon/pixel_engine.h"
#include "presenter/swtcon/swtcon_constants.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace pluto::swtcon {

// Emission body selection (`emission_mode`; the E13 WC-write bench is the
// calibration vehicle).
enum class EmissionMode : std::uint8_t {
  // Judge-mandated default: compose each dirty row in a ~480 B CACHED
  // staging buffer from the scaffold template, then stream it write-only
  // into the (WC dumb-buffer) target mapping. The target is NEVER read.
  kRowStage = 0,
  // copy_phase_to_buffer-style fallback: compose rows into a cached shadow
  // plane (read-modify-write is legal there — it is ordinary cached memory)
  // and copy the touched rows to the target at end_frame(). Kept available
  // behind the config; byte-equivalent to kRowStage by test.
  kShadowCopy = 1,
};

struct PhaseEmitterConfig {
  EmissionMode mode = EmissionMode::kRowStage;
  // Build slots (DRM dumb-buffer ring, incl. the permanent HOLD slot).
  std::size_t slot_count = kDrmBufferCount;
  // TEST/BENCH hook: force the scalar deposit_code loop even where the
  // NEON 4px/word packed deposit is available (byte-parity goldens and the
  // host bench A/B both drive it). Production leaves this off.
  bool force_scalar_deposit = false;
};

struct PhaseEmitterStats {
  std::uint64_t frames = 0;
  std::uint64_t rows_emitted = 0;    // rows rebuilt from the template
  std::uint64_t rows_reblanked = 0;  // stale rows returned to the template
  std::uint64_t rows_copied = 0;     // kShadowCopy target row copies
  std::uint64_t ops_deposited = 0;
};

// PhaseEmitter turns the PixelEngine's per-row emission requests into
// complete phase planes in DRM dumb-buffer format (RG16 365x1700 on the
// control scaffold).
//
// Invariants pinned here (mandatory decisions):
//   - Touched rows are FULLY rebuilt from the blank scaffold template: idle
//     lanes return to hold code 0, so stale codes cannot survive inside a
//     rewritten row.
//   - Per-slot dirty-row bitsets + reblank_stale_rows: rows written on a
//     slot's previous use and not written this use are re-blanked from the
//     template before the frame is published — stale-code re-drive is
//     impossible BY CONSTRUCTION (slot-reuse-after-clip-shrink golden).
//   - The target mapping is written write-only in kRowStage mode (WC-safe);
//     control scaffold words/bits are never altered by any emission.
//
// Coordinates: emit_row() receives ENGINE rows/columns (logical, 0-based).
// Logical row r lands on DRM row r + kFirstDataRow; logical column x lands
// in word kFirstDataWord + x/4, lane x%4 (swtcon_packer.cc lane math,
// inherited verbatim — see deposit_code() in phase_emit.cc).
//
// Thread ownership: engine-thread confined — configure(), frame calls and
// accessors all run on the engine thread; no internal locking.
// All buffers are pre-allocated at configure(); the frame path allocates
// nothing.
//
// Usage per built frame (engine advance):
//   begin_frame(slot, seq)  ->  engine.advance(&emitter)  ->  end_frame()
// Each slot target must be primed once with blank_slot() before its first
// begin_frame (cold start writes the full scaffold exactly once).
class PhaseEmitter final : public RowEmitter {
 public:
  PhaseEmitter() = default;
  PhaseEmitter(const PhaseEmitter&) = delete;
  PhaseEmitter& operator=(const PhaseEmitter&) = delete;

  bool configure(const PhaseEmitterConfig& config);
  bool configured() const { return configured_; }
  const PhaseEmitterConfig& config() const { return config_; }

  // Attaches a slot's output plane: `words` is the (typically mmap'd WC
  // dumb-buffer) base, `pitch_bytes` its row pitch (>= kDrmWidth * 2).
  // Host tests pass ordinary memory with a tight pitch.
  bool set_slot_target(std::size_t slot, std::uint16_t* words,
                       std::size_t pitch_bytes);

  // Primes a slot with the full blank scaffold (built once at configure()
  // from init_blank_phase_frame — the device-proven control template) and
  // clears its dirty-row state. Also the HOLD-slot content (buffer 15 stays
  // permanently blank).
  bool blank_slot(std::size_t slot);

  // Opens one build frame on `slot` for scan sequence `seq`. Fails when the
  // slot is unattached/unprimed or a frame is already open.
  bool begin_frame(std::size_t slot, std::uint64_t seq);

  // RowEmitter: one call per dirty row per scan frame from the engine
  // (ascending rows, ops ascending x, EVERY active pixel incl. code-0
  // holds). Composes template row + deposits in the staging buffer, then
  // streams the 480 B data window to the frame's slot.
  void emit_row(int row, const PixelOp* ops, std::size_t count) override;

  // Closes the frame: re-blanks the slot's stale rows (dirty on its
  // previous use, untouched this use), publishes shadow rows in
  // kShadowCopy mode, and records the slot's dirty set + seq. Returns the
  // number of re-blanked rows.
  std::size_t end_frame();

  // ---- observers (tests / presenter glue) -------------------------------

  const std::uint16_t* template_words() const { return template_.data(); }
  // Shadow plane of a slot (kShadowCopy mode only; tight kDrmWidth pitch) —
  // the presenter may hand this to DrmSwtconDevice::copy_phase_to_buffer.
  const std::uint16_t* shadow_words(std::size_t slot) const;
  // Dirty state of a LOGICAL row as of the slot's last completed frame.
  bool row_dirty(std::size_t slot, int row) const;
  std::uint64_t slot_seq(std::size_t slot) const;
  const PhaseEmitterStats& stats() const { return stats_; }

 private:
  // Per-slot emission state (BuildSlotState): dirty-row bitset over
  // the kDrmHeight (1700) DRM rows + last-emitted scan seq.
  struct BuildSlotState {
    std::uint16_t* target = nullptr;
    std::size_t pitch_words = 0;
    bool primed = false;
    std::uint64_t seq = 0;
    std::vector<std::uint64_t> dirty;  // kDrmHeight bits
  };

  std::uint16_t* target_row(BuildSlotState& slot, int drm_row) const {
    return slot.target + static_cast<std::size_t>(drm_row) * slot.pitch_words;
  }
  const std::uint16_t* template_row(int drm_row) const {
    return template_.data() + static_cast<std::size_t>(drm_row) * kDrmWidth;
  }
  void reblank_stale_rows(BuildSlotState& slot);
  // Destination data-window base for a DRM row (WC target in kRowStage,
  // cached shadow in kShadowCopy). Written write-only on the hot path.
  std::uint16_t* data_window_dest(BuildSlotState& slot, int drm_row);
  void write_data_window(BuildSlotState& slot, int drm_row,
                         const std::uint16_t* window);

  bool configured_ = false;
  PhaseEmitterConfig config_{};
  std::vector<std::uint16_t> template_;  // scaffold template, 1.24 MB
  std::vector<BuildSlotState> slots_;
  std::vector<std::vector<std::uint16_t>> shadows_;  // kShadowCopy only
  std::vector<std::uint64_t> new_dirty_;             // current-frame rows

  bool frame_open_ = false;
  std::size_t frame_slot_ = 0;
  std::uint64_t frame_seq_ = 0;

  // Row staging buffer: one 480 B data window, cached, reused.
  std::array<std::uint16_t, kDataWordCount> staging_{};

  // Row-invariant data-window template (perf): init_blank_phase_frame lays
  // the SAME 240 scaffold words into every data row's window (kDataValidBit
  // on all data words + kLeftEdgeControlBit on word kFirstDataWord), so the
  // per-row memcpy source is constant. Caching it in this 480 B L1-resident
  // array — instead of indexing a fresh, cold row of the 1.24 MB template_
  // every emit_row/reblank — removes the cold-template read traffic that
  // dominated the fused build path. Byte-identical to
  // template_row(drm_row) + kFirstDataWord for every data row (asserted at
  // configure()).
  std::array<std::uint16_t, kDataWordCount> data_template_{};

  PhaseEmitterStats stats_{};
};

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_PHASE_EMIT_H_
