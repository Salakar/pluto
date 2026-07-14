#ifndef PLUTO_PRESENTER_SWTCON_PIXEL_ENGINE_H_
#define PLUTO_PRESENTER_SWTCON_PIXEL_ENGINE_H_

#include <array>
#include <cstdint>
#include <functional>
#include <memory>
#include <span>
#include <utility>
#include <vector>

#include "pluto/presenter.h"
#include "presenter/swtcon/dc_ledger.h"
#include "presenter/swtcon/drive_pixel_op.h"
#include "presenter/swtcon/lut_cache.h"
#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_temperature.h"
#include "presenter/swtcon/swtcon_waveform.h"
#include "presenter/swtcon/xochitl_history_state.h"

namespace pluto::swtcon {

// One deposited drive op inside a row. Every active (fnum != IDLE) pixel
// of a row appears exactly once per scan frame, INCLUDING hold ops: the
// emitter rebuilds touched rows from the blank
// scaffold template, so hold deposits are no-ops on the wire but keep the
// row rebuild uniform and the DC accounting exhaustive.
using PixelOp = DrivePixelOp;

// Per-row emission sink. The PhaseEmitter (staging-buffer composition into
// the WC dumb-buffer mapping, next stage) implements this; host tests
// capture the ops directly. Ops arrive ordered by ascending x.
class RowEmitter {
public:
  virtual ~RowEmitter() = default;
  virtual void emit_row(int row, const PixelOp *ops, std::size_t count) = 0;
};

// Hygiene hook points: the A2/DU HygieneFsm plugs in here at the next
// stage (enter-via-white-flush / exit-via-GC16 re-render live in the FSM,
// not the engine core). Defaults are no-ops.
class TileHooks {
public:
  virtual ~TileHooks() = default;
  virtual void on_tile_start(std::uint32_t tile_index, int mode) {
    (void)tile_index;
    (void)mode;
  }
  virtual void on_tile_pass_end(std::uint32_t tile_index) { (void)tile_index; }
};

// Per-tile engine state (no edge_flags; stress lives in the DcLedger).
struct TileState {
  std::uint8_t mode = 0;            // waveform mode; tiles are mode-homogeneous
  std::uint8_t temp_bin = 0;        // pinned at admission, never mid-sequence
  std::uint8_t hygiene = 0;         // reserved for the HygieneFsm stage
  std::uint8_t flags = 0;           // TileFlags
  std::uint16_t active_px = 0;      // busy px; 0 => idle (O(1) collision)
  std::uint32_t admit_frame = 0;    // engine frame of last admission
  std::uint32_t complete_frame = 0; // predicted completion (stats/deferral)
  std::uint32_t update_index = 0xffffffffu; // owning update slot
};

enum TileFlags : std::uint8_t {
  kTileFlagSettle = 1u << 0,
  kTileFlagGuard = 1u << 1,
  kTileFlagPenPriority = 1u << 2,
  kTileFlagStressPromoted = 1u << 3,
};

enum AdmitFlags : std::uint32_t {
  // Legacy header-only PEN class: budget-exempt, always admitted.
  // Payload-carrying renderer previews use kAdmitFlagPenPreview and
  // receive the same admission priority.
  kAdmitFlagPen = 1u << 0,
  // SETTLE class: fires no user completion (counted in stats); force
  // identity only when settle_force_identity is on (E3 gate).
  kAdmitFlagSettle = 1u << 1,
  // Drive even where target == prev (identity transitions; their emitted
  // ops are DC-ledgered like any others).
  kAdmitFlagForceIdentity = 1u << 2,
  // Guard band: drive null transitions next := prev; `levels` is ignored
  // and may be null.
  kAdmitFlagGuardNull = 1u << 3,
  // Presenter-internal large-admission-lane marker: a header-only mailbox
  // record that preserves cross-lane admission ORDER (the drain pops one
  // large-lane entry when it meets the marker, so full-field flashes admit
  // in present() order relative to tile records — newest-wins depends on
  // it). Never legal at PixelEngine::admit(): the marker carries no levels
  // and no guard flag, so admit() rejects it by construction.
  kAdmitFlagLargeLane = 1u << 4,
  // Renderer-initiated quality settle (kPlutoPresentFlagSettle): normal
  // completion semantics (unlike kAdmitFlagSettle's sentinel), but eligible
  // for DC-stress balanced promotion — quality work that must never ride
  // live content admissions.
  kAdmitFlagQuality = 1u << 5,
  // Pen-correlated app-damage present (the ABI names it InkPriority):
  // payload-carrying, unlike kAdmitFlagPen's legacy header-only contract.
  // Updates on an in-flight SAME-rail-mode tile ride along via retarget
  // instead of parking behind the tile's waveform, avoiding dashed motion.
  // Like the legacy PEN class, previews are max_active_px budget-exempt.
  kAdmitFlagPenPreview = 1u << 6,
  // Sparkle ghost repair (header-only, levels ignored): drives only the
  // UNDER-white pixels (kSparkleMinLevel <= prev < kSparkleTargetLevel)
  // whose low-discrepancy spatial slot matches the admission's phase (flags
  // bits [kAdmitSparklePhaseShift..+3]) up to the white top-off level — a
  // scattered, per-pixel, flash-free ghost repair pass (vendor mode 8 is
  // the tuned top-off waveform on GAL3). One phase repairs ~1/16 of a
  // region; a full rotation tops off every white pixel. Busy tiles are
  // skipped (best-effort; the trickle retries on later rotations).
  kAdmitFlagSparkle = 1u << 7,
  // Modifies Sparkle: per-pixel white DEVELOP (color glass). Masked white
  // pixels (prev >= kSparkleMinLevel, INCLUDING developed 30/31) start a
  // GC16-family drive to kSparkleDevelopTargetLevel even when the level is
  // unchanged — the whole point is re-developing a nominally-white pixel
  // whose optical state has drifted (yellow cast). 8-bit phase mask keeps
  // the concurrent per-pixel inversions at paper-grain density.
  kAdmitFlagSparkleDevelop = 1u << 16,
  // Exact-colour pen Fast safety marker. Mapped truth is never preempted or
  // owner-invalidated by an ordinary AdmitRequest: conflicting mapped tile
  // claims park until scan confirmation, while disjoint ordinary mode-7
  // tiles retain the normal same-mode retarget path. The marker is required
  // only on payload-carrying mode-7 pen previews and lets the presenter pin
  // this production contract at its admission boundary.
  kAdmitFlagNoMappedInvalidation = 1u << 17,
  // Safe colour-Fast convergence. Required with NoMappedInvalidation:
  // arbitrary exact-colour A2 sources are not valid mode-7 sources, so an
  // idle changed/estimated lane is deliberately rebased to the opposite
  // certified endpoint (2 or 28) before the full rail crossing starts.
  kAdmitFlagFastRailRebase = 1u << 18,
};

// Sparkle phase rides in the admission flags' bits [8..15] (top-off
// rotations use 0..15, develop rotations the full 0..255).
inline constexpr std::uint32_t kAdmitSparklePhaseShift = 8;
inline constexpr std::uint32_t kAdmitSparklePhaseMask =
    0xffu << kAdmitSparklePhaseShift;
// Top-off (mode 8): only UNDER-white pixels (27..28: rail whites, ghosted
// near-whites) are topped off, and only upward to the maintenance slot.
// Levels at or above the target are never driven: mode 8 would pull a
// developed white (30/31) DOWN to its 4-phase endpoint, which dims it and
// reads warm yellow on Gallery-3 glass, and re-driving 29 each rotation is
// pure DC cost.
// Develop (GC16): the WHOLE white family (27..31) drives to true white 30
// — identity included; see kAdmitFlagSparkleDevelop.
inline constexpr std::uint8_t kSparkleMinLevel = 27;
inline constexpr std::uint8_t kSparkleTargetLevel = 29;
inline constexpr std::uint8_t kSparkleDevelopTargetLevel = 30;

// Completion-owned proof of the exact lanes that received at least one
// non-HOLD Fast drive for one admission. The engine marks this at emission
// time (including a late same-target subscriber inheriting a drive already
// emitted by the still-active waveform), never merely because target!=prev.
// Bits are row-major, LSB-first within each byte, with stride_bytes() bytes
// per rect row. The caller retains the shared object through completion.
class FastCoverage final {
 public:
  explicit FastCoverage(PlutoRect rect);

  PlutoRect rect() const { return rect_; }
  std::size_t stride_bytes() const { return stride_bytes_; }
  const std::vector<std::uint8_t>& bits() const { return bits_; }
  bool valid() const;
  bool empty() const { return driven_count_ == 0; }
  std::size_t driven_count() const { return driven_count_; }
  bool driven(std::int32_t x, std::int32_t y) const;
  std::uint32_t recovery_generation(std::int32_t x,
                                    std::int32_t y) const;
  // Diagnostics/provenance only. Scan commit authority is the admission's
  // terminal completion build sequence, whose trailing HOLD orders all prior
  // drive planes through the one-deep scan pipeline.
  std::uint64_t last_drive_engine_frame() const {
    return last_drive_engine_frame_;
  }

 private:
  friend class PixelEngine;
  void mark(std::int32_t x, std::int32_t y,
            std::uint64_t engine_frame,
            std::uint32_t recovery_generation);

  PlutoRect rect_{};
  std::size_t stride_bytes_ = 0;
  std::vector<std::uint8_t> bits_;
  std::vector<std::uint32_t> recovery_generations_;
  std::size_t driven_count_ = 0;
  std::uint64_t last_drive_engine_frame_ = 0;
};

// One admission: a class-homogeneous rect of 5-bit target levels. Rail
// targets are derived RENDERER-side at admission packaging (settled policy);
// the engine consumes final levels as given.
struct AdmitRequest {
  PlutoRect rect{};
  int mode = 2; // .eink mode index (Fast/Ui->7, Text->1, Full->2 for now)
  // Temperature record used to legalize this payload. >=0 pins the exact
  // waveform bin through mailbox delay/parking; -1 uses current_bin_ for
  // direct engine callers and legacy tests.
  int temp_bin = -1;
  // rect.height rows of rect.width 5-bit levels; row pitch levels_stride
  // bytes (0 = tightly packed rect.width). Ignored for kAdmitFlagGuardNull.
  const std::uint8_t *levels = nullptr;
  std::size_t levels_stride = 0;
  std::uint64_t frame_id = 0; // 0 = settle sentinel (no user completion)
  std::uint32_t flags = 0;
  // Required with kAdmitFlagNoMappedInvalidation. It is intentionally not
  // serialized through the MPSC mailbox; the engine-thread presenter binds
  // it to the drained request immediately before PixelEngine::admit().
  std::shared_ptr<FastCoverage> fast_coverage;
};

// Per-admission outcome, tile-granular (diagnostics + tests).
struct AdmitOutcome {
  bool accepted = false;
  bool budget_deferred = false; // whole piece parked on max_active_px
  std::uint32_t started_tiles = 0;
  std::uint32_t absorbed_tiles = 0;   // redundant damage, free
  std::uint32_t parked_tiles = 0;     // conflict, re-admits at boundary
  std::uint32_t retargeted_tiles = 0; // early-cancel path only
  std::uint32_t noop_tiles = 0;       // nothing to drive
  std::uint32_t deferred_bands = 0;   // full-field amortization remainder
  // A pen Fast admission crossed an exact mapped operation. Unstarted work
  // was safely discarded; once any mapped phase had been built, the A/B owner
  // was invalidated and the presenter must prepare a fresh truth reconcile.
  std::uint32_t mapped_conflicts = 0;
  bool mapped_reconcile_required = false;
  std::uint64_t mapped_recovery_token = 0;
};

using MappedOperationToken = std::uint64_t;
using MappedRecoveryToken = std::uint64_t;

struct MappedAdmitRequest {
  // Immutable whole-operation journal from XochitlHistoryState::prepare_*().
  std::shared_ptr<const XochitlHistoryState::PreparedOperation> operation;
  // Borrowed transactional owner. It must outlive the engine operation.
  XochitlHistoryState* history = nullptr;
  int temp_bin = -1;  // -1 uses the engine's current temperature bin
  std::uint64_t frame_id = 0;
  // Opaque presenter-owned raw/retry job key, returned on displacement.
  std::uint64_t retry_cookie = 0;
  // Presenter has explicitly reseeded A/B for an invalidated optical region;
  // this operation may replace poisoned tile ownership as it starts.
  bool reconcile_invalidated = false;
  MappedRecoveryToken recovery_token = 0;
};

enum class MappedAdmitStatus : std::uint8_t {
  kRejected,
  kStarted,
  kQueued,
  // An overlapping mapped operation has emitted at least one phase. Its
  // immutable successor cannot be rebased safely inside the engine.
  kConflictScanned,
  // The newer immutable journal covers only part of older unstarted work.
  // Rejecting the candidate preserves the older-only pixels for a reprepare.
  kConflictPartial,
  // Pixel-disjoint journals can still share the history owner's conservative
  // 8x2 regional version stamp and therefore cannot be serialized as-is.
  kConflictHistoryRegion,
};

struct MappedAdmitOutcome {
  MappedAdmitStatus status = MappedAdmitStatus::kRejected;
  MappedOperationToken token = 0;
  std::uint32_t superseded_unstarted = 0;

  explicit operator bool() const {
    return status == MappedAdmitStatus::kStarted ||
           status == MappedAdmitStatus::kQueued;
  }
};

enum class MappedEventKind : std::uint8_t {
  // The terminal phase is in the frame currently being built. This is not an
  // optical commit; the tile lock stays owned until confirm_mapped().
  kTerminal,
  kConfirmed,
  kDiscarded,
  // Unstarted truth displaced by latency-critical Fast. Never completed; the
  // presenter must retain/reprepare the raw job named by retry_cookie.
  kDisplacedForFast,
  // Intentional latency preemption; regional A=Fast/B=0 reseed is legal.
  kInvalidatedForReseed,
  // Unknown/coalesced evidence or invariant failure; local recovery is not.
  kInvalidated,
};

enum class MappedDiscardReason : std::uint8_t {
  kNone,
  // Newer immutable mapped truth fully covered this unstarted operation; its
  // old obligation may retire under newest-wins completion semantics.
  kSupersededByNewer,
  // Regional MVCC changed after prepare but before first drive. No completion
  // fired; the presenter must retain raw truth and prepare a fresh journal.
  kStaleAfterMvccSeed,
  // Caller explicitly canceled an unscanned token; no retry is implied.
  kExplicitCancel,
};

struct MappedEvent {
  MappedEventKind kind = MappedEventKind::kTerminal;
  MappedOperationToken token = 0;
  std::uint64_t history_operation_id = 0;
  std::uint64_t frame_id = 0;
  std::uint64_t retry_cookie = 0;
  MappedRecoveryToken recovery_token = 0;
  XochitlHistoryState::InclusiveRect requested{};
  XochitlHistoryState::InclusiveRect execution{};
  bool scanned = false;
  bool reseed_required = false;
  MappedDiscardReason discard_reason = MappedDiscardReason::kNone;
};

struct MappedPoisonRegion {
  XochitlHistoryState* history = nullptr;
  XochitlHistoryState::InclusiveRect execution{};
  // False for unknown/coalesced scan evidence: only cold clear/reopen may
  // recover it; a local regional reseed must be rejected.
  bool regional_reseed_allowed = false;
  MappedRecoveryToken recovery_token = 0;
};

enum class MappedFinalizeStatus : std::uint8_t {
  kConfirmed,
  kDiscarded,
  kInvalidated,
  kUnknownToken,
  kNotTerminal,
  // Discard is legal only before the first mapped phase is built.
  kAlreadyScanned,
  kHistoryFailure,
};

struct PixelEngineStats {
  std::uint64_t admissions = 0;
  std::uint64_t tiles_started = 0;
  std::uint64_t tiles_absorbed = 0;
  std::uint64_t tiles_parked = 0;
  std::uint64_t tiles_retargeted = 0;
  std::uint64_t truncations = 0; // mid-sequence pixel retargets (E2 path)
  std::uint64_t stress_promotions = 0;
  std::uint64_t bands_deferred = 0;
  std::uint64_t budget_deferrals = 0;
  std::uint64_t parked_wakes = 0;
  std::uint64_t pauses = 0;
  std::uint64_t completions = 0;        // user frame_id completions
  std::uint64_t settle_completions = 0; // sentinel/settle, no user callback
  std::uint64_t ops_emitted = 0;
  // Newest-wins supersession over the pending list (no-damage-loss rule:
  // every dirty tile is presented OR superseded by newer covering content).
  // NOT drops: the superseding admission owns the pixels.
  std::uint64_t pieces_superseded = 0; // pending pieces fully covered
  std::uint64_t pieces_clipped = 0;    // pending pieces shrunk to remainder
  // A newer payload-carrying pen preview safely replaced every active pixel
  // in a conflicting tile at a scan boundary, including a Text/Full mode.
  std::uint64_t pen_cross_mode_preemptions = 0;
  std::uint64_t mapped_admissions = 0;
  std::uint64_t mapped_started = 0;
  std::uint64_t mapped_queued = 0;
  std::uint64_t mapped_unstarted_superseded = 0;
  std::uint64_t mapped_terminals = 0;
  std::uint64_t mapped_confirmed = 0;
  std::uint64_t mapped_discarded = 0;
  std::uint64_t mapped_invalidated = 0;
  std::uint64_t mapped_fast_conflicts = 0;
  // Safe pen Fast sub-pieces held by an already-claimed mapped tile. Kept
  // separate from generic tiles_parked so device traces directly expose the
  // dash-island failure mode.
  std::uint64_t mapped_fast_parks = 0;
  std::uint64_t fast_rail_rebases = 0;
};

// Constants of the per-pixel engine: every field carries the experiment
// tag that calibrates it.
struct PixelEngineConfig {
  // Plane geometry. Panel default 954x1696 padded to stride 960; arbitrary
  // geometry supported for host tests. stride must be >= width and a
  // multiple of 8 (byte-aligned prev_est bitplane rows).
  int width = kLogicalWidth;
  int height = kLogicalHeight;
  int stride = kPaddedSourceWidth;
  std::uint32_t tile_px = 32;

  // Admission pacing in PIXELS (`max_active_px`; E13 sizes it from the
  // device bandwidth bench): non-PEN admissions defer while the busy-pixel
  // count is at or above this.
  std::uint32_t max_active_px = 400000;

  // Full-field flash amortization (`full_flash_band_frames`; E10 measures
  // the band-stagger artifact): regions above max_active_px admit in at
  // most this many top-to-bottom row-band slices on consecutive scan
  // frames, so one frame never sweeps the whole panel.
  std::uint32_t full_flash_band_frames = 3;

  // Early cancellation / rail retarget (`early_cancel_enabled`): DEFAULT ON
  // (E2 flipped 2026-07-10). When off, a colliding retarget parks and
  // re-admits the frame after the blocker's waveform boundary — which
  // capped ANIMATION cadence at one update per waveform (~85/11 ≈ 7.7 fps
  // per tile in mode 7) and was the perceived animation lag. When on,
  // rail-mode same-mode tiles retarget in place (the exact path the
  // pen-priority ride-along fix proved on device): truncated pixels get
  // prev estimated (the rail the prefix pushed toward), prev_est set, and
  // k_cancel tile stress charged. Non-rail (GL16/GC16) collisions still
  // park.
  bool early_cancel_enabled = true;

  // Rail (binary A2/DU-family) modes for the early-cancel legality check
  // (rail modes ONLY). Mode 7 is the proven Fast/Ui index; mode 8 its
  // 4-phase shortcut (E1 refines the identity map).
  std::uint16_t rail_mode_mask = (1u << 7) | (1u << 8);

  // Mode used when tile stress forces the next update into balanced
  // quality ("DC stress"; GC16 = the proven Full index 2). E2.
  std::uint8_t stress_balanced_mode = 2;
  // Lab-only legacy policy. Real Move observation showed tile-local mode-2
  // promotion as black-square mosaics with gold/orange residue. Production
  // now retains stress until the balanced full-screen Bleach restore.
  bool promote_regional_stress = false;

  // SETTLE force-identity-transition semantics (`settle_force_identity`;
  // E3 is the flip gate): DEFAULT OFF — until E3 runs, ghost repayment
  // only works on railed content.
  bool settle_force_identity = false;

  // Glass state after the cold clear: 5-bit white 0x1E. The presenter
  // runs the cold clear itself; the engine planes start here.
  std::uint8_t initial_prev_level = 0x1e;

  // Sticky temp-bin hysteresis for set_temperature() (E5), degC.
  float temp_hysteresis_c = TemperatureBinSelector::kDefaultHysteresisCelsius;

  // TEST/BENCH hook: force the bit-exact scalar reference sweep even where
  // the NEON fused sweep is available (scalar/NEON parity goldens and the
  // host bench A/B both drive it). Production leaves this off.
  bool force_scalar_sweep = false;

  DcLedgerConfig dc{};

  friend bool operator==(const PixelEngineConfig &,
                         const PixelEngineConfig &) = default;
};

// Zero-copy exact-color source. Values are interleaved host words
// [A0,B0,A1,B1,...], with `history_stride` pixels per row. PixelEngine derives
// each visible settled level from A low5; A marker bits, packed execution
// guards [engine width, engine stride), and the complete B history remain
// owned by XochitlHistoryState/the handoff bundle. PixelEngine padding is
// independently pinned to config.initial_prev_level.
struct ExactColorAView {
  std::span<const std::uint16_t> interleaved_ab;
  std::size_t history_stride = 0;
  std::size_t history_rows = 0;
};

// Behavior-bearing quiescent engine state. Monochrome snapshots carry the
// full stride x height settled plane. Exact-color snapshots leave that vector
// empty and derive it from the ExactColorAView supplied to export/import,
// avoiding a redundant ~1.6 MiB bundle section and projection scratch.
struct PixelEngineHandoffState {
  PixelEngineConfig config{};
  int temperature_bin = -1;
  std::vector<std::uint8_t> settled_levels;
  DcLedgerHandoffState dc;

  friend bool operator==(const PixelEngineHandoffState &,
                         const PixelEngineHandoffState &) = default;
};

// PixelEngine: per-pixel waveform state machines over SoA planes
// (prev/next/final/fnum), advanced one phase per 85 Hz scan frame.
// Concurrent regional updates of any count; admission every frame with
// value-aware collision handling (absorb / park / retarget); DC-balance
// accounting on every emitted op; full-field band amortization; per-row
// active counts + global clip with row-skip.
//
// Thread ownership: engine-thread confined — admit(), advance(),
// pause() and every accessor run on one thread; no internal locking. The
// CORE stage is single-step tickable and thread-free by construction:
// advance() is one scan frame, pause() is one missed deadline. All planes
// are pre-allocated at configure(); the advance loop allocates nothing.
class PixelEngine final {
public:
  static constexpr std::uint8_t kFnumIdle = 0xff;
  static constexpr std::uint32_t kNoUpdate = 0xffffffffu;

  using CompletionFn = std::function<void(std::uint64_t frame_id)>;
  using MappedEventFn = std::function<void(const MappedEvent& event)>;

  PixelEngine() = default;
  PixelEngine(const PixelEngine &) = delete;
  PixelEngine &operator=(const PixelEngine &) = delete;

  // `waveform` (the decoded .eink) must outlive the engine. Planes are
  // initialized to config.initial_prev_level everywhere (idle). Returns
  // false on invalid geometry or a missing waveform table.
  bool configure(const WaveformTable *waveform,
                 const PixelEngineConfig &config);
  bool configured() const { return configured_; }
  const PixelEngineConfig &config() const { return config_; }

  // Warm glass handoff seed: overwrite the prev/next/final planes with a
  // tight width x height 5-bit plane (the OUTGOING embedder's settled glass
  // state) so the incoming session can skip the cold rail clear — an app
  // switch then renders as an ordinary diff against real glass. Legal only
  // while the engine is fully idle
  // (before any admission); values are masked to 5 bits. Returns false on
  // geometry mismatch or a non-idle engine. A successful trusted seed also
  // clears every prev_est bit and its exact aggregate count.
  bool seed_prev(const std::uint8_t *levels, int width, int height);

  // Atomic quiescent snapshot/restore. Export first requires handoff_safe(),
  // then independently proves every full-stride prev/next/final value is the
  // same settled 5-bit level, every fnum is idle, and all ordinary-drive and
  // Fast-rebase proof planes are zero. Exact color additionally proves visible
  // levels against Xochitl A and engine-only padding against
  // config.initial_prev_level. Import validates the entire state and optional
  // exact-color view before mutating any live plane, then resets all
  // process-local transient queues/counters/tokens.
  bool export_handoff_state(PixelEngineHandoffState *out) const;
  bool export_handoff_state(const ExactColorAView &exact_color,
                            PixelEngineHandoffState *out) const;
  bool import_handoff_state(const PixelEngineHandoffState &state);
  bool import_handoff_state(const PixelEngineHandoffState &state,
                            const ExactColorAView &exact_color);

  // Temp-bin selection: every lookup goes through the sticky
  // TemperatureBinSelector; the selected bin applies to NEW admissions
  // only — active tiles keep their pinned TileState::temp_bin for their
  // whole sequence.
  void set_temperature(float celsius);
  int current_temp_bin() const { return current_bin_; }

  void set_completion_callback(CompletionFn fn);
  void set_mapped_event_callback(MappedEventFn fn) {
    mapped_event_fn_ = std::move(fn);
  }
  void set_tile_hooks(TileHooks *hooks) { hooks_ = hooks; } // borrowed

  // Impulse-summary sink (double-scan recharge source), folded into
  // the advance sweep so the build path needs no second pass over the
  // emitted ops: while set (both non-null, tile_count entries each, caller
  // owned/zeroed per build slot), advance() adds each tile's signed
  // per-frame drive impulse (sum of impulse_map[code] over non-hold ops)
  // to `impulse` and flags `drive` for tiles that emitted any non-hold op.
  // Accumulates only when advance() runs with a non-null emitter — exactly
  // the frames whose ops reach a build slot. Borrowed; engine thread only.
  void set_impulse_sink(std::int32_t *impulse, std::uint8_t *drive) {
    sink_impulse_ = impulse;
    sink_drive_ = drive;
  }

  // Admission arbitration for one update, tile-granular:
  //   idle tile            -> start (only differing pixels drive)
  //   equal targets        -> absorb (redundant damage is free)
  //   rail+rail, E2 gate on-> retarget in place (same mode only)
  //   otherwise            -> park shrunk to the conflict tile; re-admitted
  //                           the frame after the blocker completes
  // Regions above max_active_px band-split (<= full_flash_band_frames
  // onset stagger); non-PEN admissions defer while the busy-pixel budget
  // is exhausted. FORCE-IDENTITY bands (diagnostics / forced settles)
  // additionally wait for busy-pixel headroom before starting, bounding
  // the per-frame sweep to max_active_px + one band during bring-up (the
  // device livelock fix — a full-field force-identity admission must
  // never activate the whole panel at once). Returns false only for
  // invalid/rejected requests (bad rect, missing levels, unknown waveform
  // mode).
  bool admit(const AdmitRequest &request, AdmitOutcome *outcome = nullptr);

  // Exact mapped admission. All execution lanes, including identity and the
  // mapper's padded right edge, remain active through the waveform. Tile
  // ownership outlives the terminal build until scan evidence calls confirm.
  bool admit_mapped(const MappedAdmitRequest& request,
                    MappedAdmitOutcome* outcome = nullptr);

  // Confirm only after ScanFeedback proves the frame carrying kTerminal
  // reached the scan latch. This commits A/B first, then atomically promotes
  // the operation's A2 low5 into prev/next/final and releases its tile locks.
  MappedFinalizeStatus confirm_mapped(MappedOperationToken token);
  // Safe cancellation for queued or activated-but-never-built work.
  MappedFinalizeStatus discard_mapped(MappedOperationToken token);
  // Fail closed after unknown/coalesced scan evidence or a scanned collision.
  // XochitlHistoryState invalidation is owner-wide, so every operation from
  // the same owner is unlocked and reported kInvalidated.
  MappedFinalizeStatus invalidate_mapped(MappedOperationToken token);
  // Positive-latch hook for safe Fast rebase. `confirmed_bits` is an
  // LSB-first coverage-local filter (normally the same newest-wins mask sent
  // to history reseed). Only lanes both driven by `coverage` and selected by
  // the filter may retire their pending rebase estimate; newer/unconfirmed
  // lanes remain handoff-unsafe.
  bool confirm_safe_fast_latched(
      const FastCoverage& coverage,
      std::span<const std::uint8_t> confirmed_bits,
      std::size_t confirmed_stride_bytes);
  // Presenter calls this only after ScanFeedback proves the emergency Fast
  // terminal build associated with `token` reached the latch.
  bool confirm_fast_recovery_latched(MappedRecoveryToken token);
  // Cold-clear/external reconcile completion hook. The caller has reseeded
  // `history` to match exact engine/glass truth; no in-flight mapped/legacy
  // work or estimated prev may remain.
  bool resolve_mapped_invalidation_after_reseed(
      XochitlHistoryState* history,
      XochitlHistoryState::InclusiveRect reseeded_update,
      MappedRecoveryToken recovery_token);

  // One scan frame: re-attempts deferred bands / parked pieces /
  // budget-deferred admissions, then advances every active pixel by one
  // phase, emitting per-row ops (ascending row, ascending x) into
  // `emitter` (nullptr = drop ops; state still advances). Waveform
  // boundaries promote next -> prev, renormalize the DC ledger, link
  // queued retargets (final != next), shrink the active clip, and fire
  // completions exactly once per admission.
  void advance(RowEmitter *emitter);

  // Missed deadline (pause semantics, E10): the scan flips the HOLD
  // slot; the engine emitted nothing, so NO fnum advances, no ops are
  // charged, and k_pause stress is charged to every active tile. A pause
  // is a waveform time-stretch, not a frame.
  void pause();

  // ---- observers (test/A-B hooks; engine thread only) -------------------

  std::uint64_t frame() const { return frame_; }
  std::uint32_t total_active_px() const { return total_active_px_; }
  std::uint32_t mapped_active_px() const { return mapped_active_px_; }
  std::size_t mapped_pending_count() const { return mapped_operations_.size(); }
  std::size_t mapped_queued_count() const;
  std::size_t mapped_runtime_lane_storage_bytes() const;
  std::size_t mapped_guard_storage_bytes() const;
  std::size_t mapped_runtime_pool_count() const {
    return mapped_runtime_pool_.size();
  }
  std::size_t mapped_runtime_pool_lane_capacity_bytes() const;
  bool mapped_busy() const { return !mapped_operations_.empty(); }
  bool mapped_reconcile_required() const { return mapped_history_invalid_; }
  const std::vector<MappedPoisonRegion>& mapped_poison_regions() const {
    return mapped_poison_regions_;
  }
  bool idle() const {
    return total_active_px_ == 0 && mapped_operations_.empty() &&
           !mapped_history_invalid_;
  }
  bool handoff_safe() const {
    return idle() && pending_pieces_.empty() &&
           dc_.prev_estimated_count() == 0;
  }

  // A/B parity hook: the settled-glass truth plane.
  const std::uint8_t *prev_plane() const { return prev_.data(); }
  const std::uint8_t *next_plane() const { return next_.data(); }
  const std::uint8_t *final_plane() const { return final_.data(); }
  const std::uint8_t *fnum_plane() const { return fnum_.data(); }
  int plane_stride() const { return config_.stride; }

  std::uint32_t tile_cols() const { return tile_cols_; }
  std::uint32_t tile_rows() const { return tile_rows_; }
  const TileState &tile(std::uint32_t tx, std::uint32_t ty) const {
    return tiles_[static_cast<std::size_t>(ty) * tile_cols_ + tx];
  }

  // Active clip (row-skip): [min, max] inclusive; min > max when idle.
  int active_row_min() const { return clip_min_row_; }
  int active_row_max() const { return clip_max_row_; }
  std::uint16_t active_px_in_row(int row) const { return row_active_[row]; }

  std::size_t parked_count() const { return pending_pieces_.size(); }

  DcLedger &dc_ledger() { return dc_; }
  const DcLedger &dc_ledger() const { return dc_; }
  LutCache &lut_cache() { return *lut_cache_; }
  const LutCache &lut_cache() const { return *lut_cache_; }
  const PixelEngineStats &stats() const { return stats_; }

private:
  struct Update {
    static constexpr std::size_t kInlineLevelCapacity = 32u * 32u;
    std::uint64_t frame_id = 0;
    std::uint32_t flags = 0;
    int mode = 2;
    int temp_bin = 0;
    std::uint32_t pending = 0; // outstanding obligations (tiles + pieces)
    MappedRecoveryToken recovery_token = 0;
    std::shared_ptr<FastCoverage> fast_coverage;
    std::uint32_t fast_recovery_generation = 0;
    bool live = false;
    // Payload geometry: `rect` is the ORIGINAL admission rect; retained
    // level rows (tight rect.width pitch) exist only once a piece parks or
    // defers past the synchronous admit() call.
    PlutoRect rect{};
    // Retained tight payload for work that must outlive admit(). Direct SWTCON
    // normally submits one <=32x32 tile piece, so keep that payload inline;
    // only the uncommon whole-rect/large-lane park uses overflow storage.
    std::array<std::uint8_t, kInlineLevelCapacity> inline_levels{};
    std::vector<std::uint8_t> overflow_levels;
    std::size_t retained_size = 0;
    const std::uint8_t *borrow = nullptr; // valid during admit() only
    std::size_t borrow_stride = 0;

    const std::uint8_t *retained_data() const {
      return retained_size > kInlineLevelCapacity ? overflow_levels.data()
                                                  : inline_levels.data();
    }
    std::uint8_t *retain(std::size_t size) {
      retained_size = size;
      if (size > kInlineLevelCapacity) {
        overflow_levels.resize(size);
        return overflow_levels.data();
      }
      return inline_levels.data();
    }
    void clear_retained() {
      retained_size = 0;
      overflow_levels.clear();
    }
  };

  enum class PieceKind : std::uint8_t {
    kBand,   // full-field amortization slice; ready at admit_at_frame
    kParked, // conflict; ready when blocker tile idles
    kBudget, // non-PEN over max_active_px; ready when budget recovers
  };

  struct PendingPiece {
    PieceKind kind = PieceKind::kParked;
    std::uint32_t update_index = 0;
    PlutoRect rect{};
    std::uint32_t blocker_tile = 0;
    std::uint64_t admit_at_frame = 0;
  };

  enum class MappedState : std::uint8_t {
    kQueued,
    kActive,
    kAwaitingConfirm,
  };

  struct MappedRuntime {
    MappedOperationToken token = 0;
    std::uint64_t frame_id = 0;
    std::uint64_t retry_cookie = 0;
    MappedRecoveryToken recovery_token = 0;
    int mode = 0;
    int temp_bin = 0;
    const std::uint8_t* codes = nullptr;  // borrowed from WaveformTable
    int phase_count = 0;
    XochitlHistoryState* history = nullptr;
    std::shared_ptr<const XochitlHistoryState::PreparedOperation> operation;
    MappedState state = MappedState::kQueued;
    bool ever_emitted = false;
    bool reconcile_invalidated = false;
    std::uint32_t active_lanes = 0;
    std::vector<std::uint8_t> fnum;
    // Safe ledger backing for mapper guard lanes outside the 960x1696 wire
    // plane. Visible lanes use DcLedger; guards advance in lockstep here.
    std::vector<std::int8_t> guard_dc;
    std::vector<std::uint32_t> tile_indices;
  };

  bool rail_mode(int mode) const {
    return mode >= 0 && mode < 16 &&
           ((config_.rail_mode_mask >> mode) & 1u) != 0;
  }
  std::size_t tile_index_at(int x, int y) const {
    return (static_cast<std::size_t>(y) / config_.tile_px) * tile_cols_ +
           (static_cast<std::size_t>(x) / config_.tile_px);
  }
  const std::uint8_t *update_level_row(const Update &update, int y) const;
  std::uint8_t target_level(const Update &update, int x, int y,
                            std::size_t px) const;
  bool force_identity(const Update &update) const;
  void retain_payload(Update &update);

  // Piece processing (admission arbitration). `first_admission` is
  // true only inside the synchronous admit() call (band splitting and
  // budget deferral happen once, there).
  void process_piece(std::uint32_t update_index, const PlutoRect &rect,
                     bool allow_split, AdmitOutcome *outcome);
  void start_tile(std::uint32_t tile_index, std::uint32_t update_index,
                  const PlutoRect &sub, AdmitOutcome *outcome);
  bool targets_equal(const Update &update, const PlutoRect &sub) const;
  void retarget_tile(std::uint32_t tile_index, std::uint32_t update_index,
                     const PlutoRect &sub, AdmitOutcome *outcome);
  bool pen_preview_covers_active_tile(std::uint32_t tile_index,
                                      const PlutoRect &sub) const;
  void preempt_tile_for_pen_preview(std::uint32_t tile_index);
  void subscribe(std::uint32_t tile_index, std::uint32_t update_index);
  void finalize_tile(std::uint32_t tile_index);
  void process_pending_pieces();
  void supersede_pending(const PlutoRect &cut);
  void grow_clip(const PlutoRect &sub);
  void shrink_clip();
  std::uint32_t alloc_update(const AdmitRequest &request);
  void release_update(std::uint32_t update_index);
  void flush_completions();
  bool mapped_operations_overlap(const MappedRuntime& a,
                                 const MappedRuntime& b) const;
  bool mapped_history_regions_overlap(const MappedRuntime& a,
                                      const MappedRuntime& b) const;
  bool mapped_operation_intersects(const MappedRuntime& operation,
                                   const PlutoRect& rect) const;
  bool mapped_tile_claimed(std::uint32_t tile_index) const;
  bool mapped_can_start(const MappedRuntime& operation) const;
  void activate_mapped(MappedRuntime& operation);
  void activate_mapped_queue();
  void recompute_mapped_clip();
  MappedRuntime* find_mapped(MappedOperationToken token);
  const MappedRuntime* find_mapped(MappedOperationToken token) const;
  std::size_t find_mapped_index(MappedOperationToken token) const;
  std::unique_ptr<MappedRuntime> acquire_mapped_runtime();
  void recycle_mapped_runtime(
      std::unique_ptr<MappedRuntime> operation) noexcept;
  void reset_mapped_intent(const MappedRuntime& operation);
  void release_mapped_locks(const MappedRuntime& operation);
  void erase_mapped(std::size_t index, MappedEventKind event_kind,
                    bool user_completion, bool reset_intent = true,
                    MappedDiscardReason discard_reason =
                        MappedDiscardReason::kNone);
  bool discard_mapped_at(std::size_t index, bool superseded);
  void invalidate_mapped_owner(XochitlHistoryState* history,
                               bool preserve_for_regional_reseed = false);
  void invalidate_mapped_owner_for_fast(
      XochitlHistoryState* history, const PlutoRect& fast_rect,
      MappedRecoveryToken recovery_token,
      const std::vector<MappedOperationToken>& displaced_tokens);
  void estimate_mapped_prev(const MappedRuntime& operation);
  void clear_invalidated_history_if_resolved(XochitlHistoryState* history);
  void rebuild_mapped_poison_tiles();
  bool mapped_reconcile_covers_tile_poison(
      const MappedRuntime& operation, std::uint32_t tile_index) const;
  MappedRecoveryToken resolve_fast_mapped_conflicts(
      const PlutoRect& rect, AdmitOutcome* outcome);
  void emit_mapped_event(
      MappedEventKind kind, const MappedRuntime& operation,
      MappedDiscardReason discard_reason = MappedDiscardReason::kNone);
  bool export_handoff_state_impl(const ExactColorAView *exact_color,
                                 PixelEngineHandoffState *out) const;
  bool import_handoff_state_impl(const PixelEngineHandoffState &state,
                                 const ExactColorAView *exact_color);
  bool quiescent_handoff_invariants_hold() const;
  void reset_handoff_transients(std::vector<std::uint32_t> reset_free_updates);

  bool configured_ = false;
  PixelEngineConfig config_{};
  const WaveformTable *waveform_ = nullptr;
  bool mode7_fast_recovery_supported_ = false;
  std::unique_ptr<LutCache> lut_cache_;
  DcLedger dc_;
  TemperatureBinSelector bin_selector_;
  int current_bin_ = 0;

  // SoA planes, stride-padded, pre-allocated at configure().
  std::vector<std::uint8_t> prev_;
  std::vector<std::uint8_t> next_;
  std::vector<std::uint8_t> final_;
  std::vector<std::uint8_t> fnum_;
  // Per-pixel proof for the currently active ordinary waveform. Retained
  // through terminal so a same-target subscriber arriving after the last
  // non-HOLD phase but before completion can inherit exact coverage.
  std::vector<std::uint8_t> waveform_drove_;
  std::vector<std::uint32_t> fast_rebase_pending_generation_;
  std::uint32_t next_fast_recovery_generation_ = 1;

  std::uint32_t tile_cols_ = 0;
  std::uint32_t tile_rows_ = 0;
  std::vector<TileState> tiles_;
  std::vector<std::vector<std::uint32_t>> tile_subscribers_;

  std::vector<std::uint16_t> row_active_; // per-row active px counts
  int clip_min_row_ = 0;
  int clip_max_row_ = -1;
  std::uint32_t total_active_px_ = 0;

  std::vector<Update> updates_;
  std::vector<std::uint32_t> free_updates_;
  std::vector<PendingPiece> pending_pieces_;
  std::vector<PendingPiece> pieces_scratch_;
  std::vector<PendingPiece> supersede_scratch_;

  std::vector<std::unique_ptr<MappedRuntime>> mapped_operations_;
  // Retain one lane-state allocation across sequential full-panel updates.
  // Mapped journals remain owned by PreparedOperation and are released before
  // pooling, so this caches only scratch capacity, never optical intent.
  std::vector<std::unique_ptr<MappedRuntime>> mapped_runtime_pool_;
  std::vector<MappedOperationToken> mapped_tile_owner_;
  std::vector<MappedRuntime*> mapped_tile_runtime_;  // pointees are stable
  std::vector<XochitlHistoryState*> mapped_poisoned_owner_;
  std::vector<XochitlHistoryState*> invalidated_histories_;
  std::vector<XochitlHistoryState*> reseeded_histories_;
  std::vector<MappedPoisonRegion> mapped_poison_regions_;
  std::size_t mapped_poisoned_count_ = 0;
  bool mapped_history_invalid_ = false;
  std::vector<std::uint16_t> mapped_row_active_;
  std::uint32_t mapped_active_px_ = 0;
  int mapped_clip_min_row_ = 0;
  int mapped_clip_max_row_ = -1;
  MappedOperationToken next_mapped_token_ = 1;
  MappedRecoveryToken next_recovery_token_ = 1;
  std::vector<MappedRecoveryToken> active_recoveries_;
  std::vector<MappedRecoveryToken> terminal_recoveries_;
  std::vector<MappedRecoveryToken> latched_recoveries_;

  std::uint64_t frame_ = 0;
  PixelEngineStats stats_{};
  TileHooks *hooks_ = nullptr;
  CompletionFn completion_fn_;
  MappedEventFn mapped_event_fn_;
  std::int32_t *sink_impulse_ = nullptr; // borrowed (impulse summary)
  std::uint8_t *sink_drive_ = nullptr;

  // Pre-allocated advance-loop scratch (no per-frame heap): sized to one
  // full row at configure(); the sweep kernels append through raw cursors.
  std::vector<PixelOp> row_ops_;
  // MappedSweep's terminal marks are per-call scratch: PixelEngine consumes
  // only the returned completion count, never the individual bytes. Reuse one
  // row-wide plane instead of allocating one byte per mapped lane.
  std::vector<std::uint8_t> mapped_terminal_scratch_;
  std::vector<std::uint32_t> completed_tiles_;
  // Per-tile-row-band sweep invariants (advance() hot loop): the pinned
  // LUT record and renorm flag of each tile column, cached once per band
  // instead of per (row, tile) segment. Sized tile_cols_ at configure().
  std::vector<const LutRecord *> band_records_;
  std::vector<std::uint8_t> band_renorm_;
};

} // namespace pluto::swtcon

#endif // PLUTO_PRESENTER_SWTCON_PIXEL_ENGINE_H_
