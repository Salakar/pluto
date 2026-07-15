#ifndef PLUTO_RENDERER_REGION_SCHEDULER_H_
#define PLUTO_RENDERER_REGION_SCHEDULER_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "pluto/presenter.h"
#include "renderer/ledgers.h"
#include "renderer/refresh_class.h"

namespace pluto {

// RegionScheduler replaces EinkScheduler. What changed, by design:
//
//   * Class bands: pen preview > pen truth > user classes ordered EDF by
//     deadline (enqueue + per-class deadline) > SETTLE under a CBS budget.
//     Preview is a Fast app-damage repaint with InkPriority retargeting; pen
//     truth is Text/Full app damage in a dedicated queue, never a synthetic
//     system ink overlay and never delayed by settle quiescence/CBS policy.
//   * Value-aware admission at REGION granularity: damage overlapping an
//     in-flight update is a conflict ONLY if its content is newer than what
//     the in-flight already presents (content-epoch check) — redundant
//     damage is absorbed for free instead of parking.
//   * Newest-content-wins supersession: back-to-back damage to the same
//     region collapses at enqueue into one update carrying the newest
//     content epoch and the OLDEST enqueue time (anti-starvation). Presents
//     always read the current ledger, so collapsing never loses content.
//   * Mode-gated merging: pending rects merge within their class queue only
//     (min-added-area heuristic at coalesce); classes never cross-merge.
//   * ONE monotonic timebase: every now_us the scheduler sees comes from the
//     caller's steady clock. The old scheduler mixed engine
//     presentation_time_ns with steady_clock; that class of bug is gone by
//     construction.
//   * Multi-inflight exact-region collision tracking. Regional PenTruth Full
//     may chase disjoint Fast work; ordinary Full and pixel reset remain
//     globally exclusive.
//
// The scheduler is presenter-agnostic: it talks only to the ready/present
// hooks (the AbiPresentBridge / PlutoPresenterOps seam) and the per-tile
// ledgers. Completions arrive via notify_completion, fed by FrameRenderer's
// enqueue-only CompletionQueue drain.
//
// Thread ownership: scheduler-thread confined — every method
// runs under FrameRenderer's presenter-loop mutex. No internal locking.
// Pre-allocated storage; no per-tick heap in steady state.
struct RegionSchedulerConfig {
  int32_t width = 954;
  int32_t height = 1696;
  uint32_t align_px = 8;
  // Clockwise logical-to-presenter transform. PixelEngine owns tiles in
  // presenter coordinates, so a logical 32-pixel grid is insufficient when
  // a non-32-aligned panel edge is reflected by 90/180/270 degree rotation.
  uint32_t presenter_rotation = 0;
  // PixelEngine arbitrates exact-colour work on this tile grid. Pen truth
  // must not start a mapped transaction in a tile that still carries a Fast
  // preview, even when the two logical damage rectangles are merely adjacent:
  // the presenter would otherwise park the next nib update behind that truth
  // waveform and the visible stroke becomes a row of dash islands.
  uint32_t pen_collision_tile_px = 32;
  // Exact-colour presenters claim whole PixelEngine tiles for mapped truth.
  // Mono/qtfb backends do not, and retain their existing overlap-safe chase.
  bool serialize_pen_truth_by_tile = false;
  uint32_t merge_gap_px = 16;
  std::array<uint8_t, k_refresh_class_count> max_rects = k_default_rect_caps;
  // EDF deadlines per class (us after enqueue). Fast stays the shortest so
  // interactivity wins ties; a starving Text head eventually beats fresh
  // Fast damage.
  std::array<uint32_t, k_refresh_class_count> class_deadline_us = {
      25000, 60000, 150000, 300000};
  // Synthetic completion model for presenters that do not report completion.
  std::array<uint32_t, k_refresh_class_count> latency_model_us = {
      260000, 450000, 450000, 1000000};
  float fence_margin = 1.25f;
  // Native presenters may block for up to five seconds in the kernel while
  // waiting for authoritative panel completion (the RM1 EPDC contract is the
  // slowest current case).  The scheduler must never declare that same update
  // lost before the backend's wait has had a chance to return.
  uint32_t fence_timeout_ms = 5500;
  // Structural Full promotion moved to the ClassifyLadder scenecut rung;
  // guard dilation moved to the GuardBandPackager. The scheduler
  // dispatches the rects it is given.
  // CBS budget for the settle class: percentage of dispatch slots settles
  // may take while interactive work is pending (free when idle).
  uint32_t cbs_settle_budget_pct = 30;
  // Debt-adaptive promotion (RendererConfig ghost_debt_promote_threshold /
  // ghost_promote_min_gap_ms): Fast/Ui damage over tiles averaging >= the
  // threshold promotes to Text when every touched tile has been quiet for
  // the gap. Inert without a GhostLedger (pure scheduling tests).
  uint16_t debt_promote_threshold = 2048;
  uint32_t debt_promote_min_gap_us = 250'000;
  // True only when the backend can actually honor Text as a non-flashing
  // class. qtfb exposes only ALL/PARTIAL, so ordinary background Text must
  // be treated as intrusive there; explicitly required repair is exempt.
  bool text_settle_nonintrusive = true;
  bool presenter_reports_completion = false;
  bool presenter_collision_safe = false;
  PlutoSurface surface = {};
};

struct RegionPresenterHooks {
  void *user_data = nullptr;
  bool (*ready)(void *user_data, PlutoRefreshClass refresh_class) = nullptr;
  bool (*present)(void *user_data,
                  const PlutoPresentRequest *request) = nullptr;
};

// Configuration identity excluding process-local pointers. Surface pixels are
// intentionally absent; only their geometry/format contract is persistent.
struct RegionSchedulerStateConfig {
  int32_t width = 0;
  int32_t height = 0;
  uint32_t align_px = 0;
  uint32_t presenter_rotation = 0;
  uint32_t pen_collision_tile_px = 0;
  bool serialize_pen_truth_by_tile = false;
  uint32_t merge_gap_px = 0;
  std::array<uint8_t, k_refresh_class_count> max_rects{};
  std::array<uint32_t, k_refresh_class_count> class_deadline_us{};
  std::array<uint32_t, k_refresh_class_count> latency_model_us{};
  float fence_margin = 0.0f;
  uint32_t fence_timeout_ms = 0;
  uint32_t cbs_settle_budget_pct = 0;
  uint16_t debt_promote_threshold = 0;
  uint32_t debt_promote_min_gap_us = 0;
  bool text_settle_nonintrusive = false;
  bool presenter_reports_completion = false;
  bool presenter_collision_safe = false;
  uint64_t surface_stride_bytes = 0;
  int32_t surface_width = 0;
  int32_t surface_height = 0;
  uint32_t surface_format = 0;
};

struct RegionSchedulerState {
  uint32_t version = 1;
  RegionSchedulerStateConfig config{};
  bool has_debt_grid = false;
  TileGrid debt_grid{};
  uint64_t next_frame_id = 1;
  uint64_t damage_epoch = 0;
  uint64_t cbs_total_slots = 0;
  uint64_t cbs_settle_slots = 0;
  std::vector<uint64_t> last_submit_us;
};

class RegionScheduler {
public:
  static constexpr uint32_t kStateVersion = 1;
  // Ledger pointers may be null (pure scheduling tests); when present the
  // scheduler accrues ghost/stress on rail-class dispatch and clears
  // ghost/stress (Text/Full) and chroma-pending (Full) on quality dispatch.
  RegionScheduler(const RegionSchedulerConfig &config,
                  RegionPresenterHooks presenter = {},
                  GhostLedger *ghost = nullptr, StressLedger *stress = nullptr,
                  ChromaPendingSet *chroma = nullptr);

  bool valid() const { return valid_; }

  // Frame-path damage (post-quantize logical rects + classifier classes).
  // Rotation belongs exclusively to AbiPresentBridge; scheduler geometry
  // always stays in the retained surface's logical coordinate space.
  void submit_damage(const PlutoRect *rects, const PlutoRefreshClass *classes,
                     size_t count, uint64_t now_us);

  // Pen-aware APP-DAMAGE path. Both rects describe pixels the running app has
  // already changed in the shared surface; the scheduler never draws ink.
  // `preview_rect` is sent first as Fast + InkPriority so same-rail updates
  // can retarget in flight. `truth_rect` is the corresponding current-surface
  // repaint at Text or Full quality and stays in a fixed priority queue until
  // it can follow. Either rect may be empty (hover and contact use the same
  // path). Back-to-back truth keeps bounded spatial segments: exact or
  // containment-redundant geometry coalesces, while partial overlaps retain
  // their shape and share the strongest quality/newest content epoch.
  void submit_pen_damage(const PlutoRect &preview_rect,
                         const PlutoRect &truth_rect,
                         PlutoRefreshClass truth_class, uint64_t now_us);

  // Scheduling-only proximity reservation. `logical_focus` is derived from
  // the real pen/hover trajectory and never creates pixels or a present. The
  // reservation prevents mapped Text/Full work from claiming the physical
  // PixelEngine tiles between successive Flutter frames. UINT64_MAX keeps an
  // active in-range reservation; a finite expiry provides the short terminal
  // lease needed for an app-rendered hover erase after range exit.
  void reserve_pen_focus(const PlutoRect &logical_focus, uint64_t expires_us);
  void clear_pen_focus();

  // SettlePlanner feed (the only producer of SETTLE-class work). cls is the
  // presentation class of the maintenance pass (Text or Full).
  void submit_settle(const PlutoRect &rect, PlutoRefreshClass cls,
                     uint64_t now_us, bool required = false);

  // Sparkle ghost-repair pass (SettlePlanner trickle): best-effort direct
  // dispatch of one scattered white repair pass over `rect`. Top-off form
  // (develop=false, phase 0..15): mode-8 lift of under-white pixels.
  // Develop form (develop=true, phase 0..255, color glass): per-pixel GC16
  // micro develops of the white family — the only drive that resets
  // displaced Gallery-3 pigments (yellow-cast whites). Declined silently
  // when the presenter is busy or pen damage is pending — a skipped pass
  // just retries on a later rotation. Returns dispatched.
  bool submit_sparkle(const PlutoRect &rect, uint32_t phase, uint64_t now_us,
                      bool develop = false);

  // Direct, never-absorbed admission used by the serialized pixel reset.
  // Black/white flags select solid Fast rails; an unflagged Fast restore is
  // used by automatic Blink, while PixelResetRestore selects the balanced
  // Full restore used by Bleach/Both. The caller retries only after completion.
  bool submit_pixel_reset_stage(const PlutoRect &rect, uint32_t flags,
                                uint64_t now_us,
                                PlutoRefreshClass cls = kPlutoRefreshFast);

  // Completion entry (drained from FrameRenderer's CompletionQueue).
  // Returns true only when |frame_id| retires a currently accepted present.
  bool notify_completion(uint64_t frame_id);

  // Retires timeout/synthetic fences without dispatching queued work. A pixel
  // reset uses this while ordinary damage is intentionally held behind it.
  void poll_completions(uint64_t now_us);

  // Retires only serialized reset bookkeeping after the caller has proved
  // the presenter itself idle (e.g. wait_idle()==Ok). This recovers a lost
  // completion callback without letting the ordinary 3s fence advance an
  // optical rail early.
  bool retire_pixel_reset_after_presenter_idle();

  // Pen preview/truth and generic user classes always run. Lifecycle can hold
  // every background item; touch/pen only holds intrusive maintenance Full.
  void tick(uint64_t now_us, bool maintenance_allowed = true,
            bool intrusive_maintenance_allowed = true);

  // Drops queued, never-dispatched work while preserving the live content
  // ledgers. Valid only with no in-flight presenter request. The launcher
  // no-flash gate uses this to replace all hidden stale-route damage with one
  // full request for the final system-UI ledger.
  bool discard_pending();

  // Drops only queued, never-dispatched maintenance after user truth and all
  // presenter fences have drained. Ghost/stress/chroma and SettlePlanner
  // state remain authoritative and are serialized by the warm handoff, so a
  // successor can re-emit the unpaid work. Any queued user work, in-flight
  // request, or parked user item makes this fail closed.
  bool discard_pending_maintenance_for_handoff();

  // -- introspection (SettlePlanner + tests) ----------------------------
  bool user_work_pending() const; // pen or generic user damage queued
  bool anything_inflight() const { return inflight_count_ != 0; }
  // Sticky evidence that a presenter promising real completions missed the
  // common fence deadline. A timeout must never count as presenter progress.
  bool real_completion_overdue() const { return real_completion_overdue_; }
  bool settle_work_pending() const; // settle queued or in flight
  bool idle() const;

  // Only idle schedulers with no pen-focus reservation can cross a process
  // boundary. Queues, fences and focus ownership are intentionally excluded.
  bool export_state(RegionSchedulerState *out) const;
  bool import_state(const RegionSchedulerState &state);

  // -- stats -------------------------------------------------------------
  size_t dispatched_updates() const { return stat_dispatched_; }
  size_t dispatched_settles() const { return stat_settles_; }
  size_t absorbed_updates() const { return stat_absorbed_; }
  size_t superseded_updates() const { return stat_superseded_; }
  size_t parked_updates() const { return stat_parked_; }
  size_t debt_promoted_updates() const { return stat_debt_promoted_; }
  size_t pen_truth_tile_holds() const { return stat_pen_truth_tile_holds_; }
  size_t pen_focus_tile_holds() const { return stat_pen_focus_tile_holds_; }
  // Benchmark/test guard: proves an adversarial fixture actually retained a
  // deep exact residual lane instead of being silently coalesced away.
  size_t pending_pen_residuals_for_testing() const {
    return pen_residual_count_;
  }

private:
  static constexpr size_t k_max_pending_per_class = 256;
  static constexpr size_t k_max_exact_pen_segments = 64;
  static constexpr size_t k_max_pending_pen_preview = 1024;
  static constexpr size_t k_max_pending_pen_truth = 1024;
  // Generic work cut around newer pen truth must never return to the ordinary
  // class queues: their gap/coalesce policy can rebuild a bounding box across
  // the truth hole. Keep the exact pieces in a fixed lane instead. On pressure
  // the affected pieces are promoted into the truth lane at equal-or-stronger
  // quality; uncovered app damage is never dropped or lower-class bboxed.
  static constexpr size_t k_max_pending_pen_residual = 1024;
  static constexpr int32_t k_pen_overload_cell_px = 64;
  static constexpr size_t k_max_pen_present_rects = 64;
  static constexpr size_t k_max_pending_settle = 64;
  static constexpr size_t k_max_parked = 256;
  // A real-completion pen preview may remain subscribed until its retargeted
  // tile reaches a waveform boundary. Keep enough fixed bookkeeping for a
  // sustained stream instead of introducing a 32-frame admission cliff.
  static constexpr size_t k_max_inflight = 512;

  struct PendingUpdate {
    PlutoRect rect = {};
    PlutoRefreshClass cls = kPlutoRefreshUi;
    uint64_t enqueue_us = 0;
    uint64_t epoch = 0; // content epoch (newest damage folded in)
    bool settle = false;
    bool required = false;
    // Pen truth only: this segment has had its corresponding Fast preview
    // accepted and is eligible for a regional Full chase when nonconflicting.
    bool pen_preview_ready = false;
  };

  struct PendingQueue {
    std::array<PendingUpdate, k_max_pending_per_class> items = {};
    size_t count = 0;
  };

  struct PendingPenPreview {
    PlutoRect rect = {};
  };

  // Damage rects actually presented by one in-flight update. Absorption
  // must test coverage against THESE — the union rect below is only a
  // conservative overlap bound for parking. (Absorbing into the union's
  // interior silently dropped damage no presented rect ever covered; the
  // no-damage-loss property test pins the fix.)
  static constexpr size_t k_max_inflight_rects = k_max_pen_present_rects;

  struct Inflight {
    uint64_t frame_id = 0;
    PlutoRect rect = {}; // union of rects[] (conflict/park bound)
    PlutoRefreshClass cls = kPlutoRefreshUi;
    uint64_t submit_us = 0;
    uint64_t eta_us = 0;
    uint64_t epoch = 0; // content epoch presented (global epoch at dispatch)
    bool real_completion = false;
    bool settle = false;
    bool pixel_reset = false;
    bool pen_preview = false;
    bool pen_truth = false;
    std::array<PlutoRect, k_max_inflight_rects> rects = {};
    // 0 when the batch overflowed the array: absorption then never matches
    // (conservative — parking still uses the union).
    size_t rect_count = 0;
  };

  // Batch ownership on failure: kParked batches move to parked_ until a
  // completion unparks them; kDeclined batches stay with the caller, which
  // requeues exactly once; kAbsorbed batches are already covered by an
  // in-flight update and are dropped for free.
  enum class DispatchResult { kDispatched, kParked, kDeclined, kAbsorbed };

  void push_pending(PlutoRefreshClass cls, const PlutoRect &rect,
                    uint64_t now_us, uint64_t epoch);
  void push_pen_truth(PlutoRefreshClass cls, const PlutoRect &rect,
                      uint64_t now_us, uint64_t epoch, bool pen_preview_ready);
  bool push_pen_residual(const PendingUpdate &pending);
  void promote_pen_residual(const PendingUpdate &pending,
                            PlutoRefreshClass minimum_truth_class,
                            uint64_t truth_epoch);
  void supersede_generic_with_pen_truth(const PlutoRect &truth,
                                        PlutoRefreshClass truth_class,
                                        uint64_t truth_epoch);
  bool route_damage_around_active_pen_truth(const PendingUpdate &pending);
  bool reconcile_pen_residuals_with_truth(const PlutoRect &truth,
                                          PlutoRefreshClass truth_class,
                                          uint64_t truth_epoch,
                                          size_t residual_begin);
  void promote_all_pending_to_full_truth(uint64_t enqueue_us,
                                         uint64_t truth_epoch);
  void push_pen_preview(const PlutoRect &rect);
  void add_pen_preview_cells(const PlutoRect &rect);
  void collapse_pen_preview_to_cells();
  void add_pen_truth_cells(const PendingUpdate &pending);
  void collapse_pen_truth_to_cells();
  void propagate_pen_truth_component(size_t seed_index);
  bool ready_full_truth_pending() const;
  bool presenter_ready(PlutoRefreshClass cls) const;
  // `epoch` is the batch's content epoch for the value-aware absorption
  // test (UINT64_MAX marks never-absorbable content, i.e. a pen preview).
  DispatchResult dispatch_batch(PlutoRefreshClass cls, const PlutoRect *rects,
                                size_t count, uint64_t now_us, uint32_t flags,
                                bool settle, bool pixel_reset, uint64_t epoch);
  bool try_dispatch_pen_preview(uint64_t now_us);
  bool try_dispatch_pen_truth(uint64_t now_us);
  bool try_dispatch_pen_residual(uint64_t now_us);
  bool try_dispatch_class(PlutoRefreshClass cls, uint64_t now_us);
  bool try_dispatch_settle(uint64_t now_us, bool maintenance_allowed,
                           bool intrusive_maintenance_allowed);
  void complete_due(uint64_t now_us);
  void remove_inflight(size_t index);
  bool full_inflight() const;
  bool pixel_reset_inflight() const;
  // Value-aware region admission: kept when genuinely conflicting, absorbed
  // when an in-flight update already presents this content at >= quality.
  bool absorbed_by_inflight(const PlutoRect &rect, PlutoRefreshClass cls,
                            uint64_t epoch) const;
  bool conflicts_inflight(const PlutoRect &rect) const;
  PlutoRect presenter_rect(const PlutoRect &logical) const;
  PlutoRect logical_rect(const PlutoRect &presenter) const;
  PlutoRect pen_focus_tile_bounds_presenter() const;
  bool shares_pen_collision_tile(const PlutoRect &left,
                                 const PlutoRect &right) const;
  // True when `candidate` may share a presenter request with `batch` without
  // creating two dense mapped operations that claim one PixelEngine tile.
  // Same-tile overlap is allowed only when the presenter's exact sparse-mask
  // path can combine the whole collision group into one operation.
  bool pen_truth_batch_compatible(const PlutoRect &candidate,
                                  const PlutoRect *batch,
                                  size_t batch_count) const;
  bool conflicts_pen_focus_tile(const PlutoRect &rect) const;
  bool conflicts_pen_lane_tile(const PlutoRect &rect) const;
  bool conflicts_mapped_pen_tile(const PlutoRect &rect) const;
  bool pen_truth_has_unblocked_candidate() const;
  void expire_pen_focus(uint64_t now_us);
  void park_rect(PlutoRefreshClass cls, const PlutoRect &rect, uint64_t now_us,
                 uint64_t epoch, bool settle, bool required);
  void unpark_all();
  size_t coalesce_queue(PlutoRefreshClass cls, uint64_t *out_epoch);
  void merge_scratch_to_cap(size_t *count, size_t cap);
  void accrue_ledgers(const PlutoRect &rect, PlutoRefreshClass cls);
  uint64_t queue_earliest_deadline(PlutoRefreshClass cls) const;
  // Debt-adaptive promotion test (smart fast partials): true when every
  // tile under `rect` has been submit-quiet for the min gap, the tiles'
  // average ghost debt reaches the promote threshold, and nothing in
  // flight overlaps (a promotion may not stall an active region).
  bool debt_promotes(const PlutoRect &rect, uint64_t now_us) const;
  void stamp_submit(const PlutoRect &rect, uint64_t now_us);

  RegionSchedulerConfig config_;
  RegionPresenterHooks presenter_;
  GhostLedger *ghost_ = nullptr;
  StressLedger *stress_ = nullptr;
  ChromaPendingSet *chroma_ = nullptr;
  bool valid_ = false;
  std::array<PendingQueue, k_refresh_class_count> queues_ = {};
  // Pen truth is deliberately not a SETTLE item: it is app damage and must
  // remain ahead of generic work even while blocked by an active waveform.
  std::array<PendingUpdate, k_max_pending_pen_truth> pen_truth_queue_ = {};
  size_t pen_truth_count_ = 0;
  bool pen_truth_cell_mode_ = false;
  // Exact generic-only remainder left after subtracting newer pen truth.
  // Items retain their original class, age and content epoch and bypass all
  // rectangle coalescing, so a lower-class present can never refill the hole.
  std::array<PendingUpdate, k_max_pending_pen_residual> pen_residual_queue_ =
      {};
  size_t pen_residual_count_ = 0;
  std::array<PendingUpdate, k_max_pending_settle> settle_queue_ = {};
  size_t settle_count_ = 0;
  std::array<PendingUpdate, k_max_parked> parked_ = {};
  size_t parked_count_ = 0;
  std::array<Inflight, k_max_inflight> inflight_ = {};
  size_t inflight_count_ = 0;
  bool real_completion_overdue_ = false;
  std::array<PlutoRect, k_max_pending_per_class> scratch_rects_ = {};
  std::array<PendingPenPreview, k_max_pending_pen_preview> pen_preview_queue_ =
      {};
  size_t pen_preview_count_ = 0;
  bool pen_preview_cell_mode_ = false;
  uint64_t next_frame_id_ = 1;
  // Content epoch: bumped once per generic or pen-damage submission; presents
  // always carry the current epoch (they read the live ledger).
  uint64_t damage_epoch_ = 0;
  // CBS accounting: dispatch slots consumed by settles vs everything.
  size_t cbs_total_slots_ = 0;
  size_t cbs_settle_slots_ = 0;
  size_t stat_dispatched_ = 0;
  size_t stat_settles_ = 0;
  size_t stat_absorbed_ = 0;
  size_t stat_superseded_ = 0;
  size_t stat_parked_ = 0;
  size_t stat_debt_promoted_ = 0;
  size_t stat_pen_truth_tile_holds_ = 0;
  size_t stat_pen_focus_tile_holds_ = 0;
  PlutoRect pen_focus_rect_ = {};
  uint64_t pen_focus_expires_us_ = 0;
  // Per-tile last submit_damage timestamp (ghost grid indexing); the rate
  // gate for debt promotion. kNeverSubmitted = never touched.
  static constexpr uint64_t kNeverSubmitted = UINT64_MAX;
  std::vector<uint64_t> last_submit_us_;
};

} // namespace pluto

#endif // PLUTO_RENDERER_REGION_SCHEDULER_H_
