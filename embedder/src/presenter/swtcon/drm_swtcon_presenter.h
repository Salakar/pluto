#ifndef PLUTO_PRESENTER_SWTCON_DRM_SWTCON_PRESENTER_H_
#define PLUTO_PRESENTER_SWTCON_DRM_SWTCON_PRESENTER_H_

#include "pluto/presenter.h"

#ifdef __cplusplus
extern "C" {
#endif

const PlutoPresenterOps *pluto_swtcon_presenter_ops(void);

// Presenter-internal drive counters (diagnostics + host tests). Counters
// reset on open(). APPEND-ONLY struct: callers pass struct_size and never
// see fields move.
typedef struct PlutoSwtconDebugStats {
  size_t struct_size;
  uint64_t updates_completed; // user frame_ids completed (once each)
  uint64_t gc16_updates;      // completed updates driven in a GC16-family
                              // (DC-balanced) waveform mode
  uint64_t full_updates;      // completed Full-class updates
  uint64_t settle_updates;    // always 0: the renderer's SettlePlanner
                              // owns settles; field kept — this struct
                              // is append-only
  // Appended at the per-pixel engine stage.
  uint64_t admissions;     // engine admissions (tile/band pieces)
  uint64_t absorbed;       // redundant-damage subscriptions (free)
  uint64_t parked;         // conflict parks (re-admit at the boundary)
  uint64_t retargets;      // early-cancel rail retargets (E2 path)
  uint64_t cancels;        // mid-sequence pixel truncations (E2 path)
  uint64_t neutral_frames; // scan HOLD flips (idle parking + misses)
  uint64_t double_scans;   // hw vblank gaps: a CONTENT plane latched
                           // for extra scans (recharged via summaries)
  uint64_t dc_saturations; // DC ledger cap clamps (pixel + rescan)
  uint64_t pauses;         // missed build deadlines while active
  uint64_t active_px_peak; // high-water busy-pixel count
  // Appended at the HOLD-gap exemption stage (device livelock fix).
  uint64_t hold_rescans; // vblank gaps after a HOLD latch: blank
                         // scaffold rescans, impulse-free, never
                         // recharged (jitter shows up here)
  // Appended when production mode-0 selection was removed.
  int32_t cold_clear_mode; // selected cold-rail waveform; never 0
  // Appended by the pen-priority path: scan-boundary replacements of a
  // fully covered in-flight Text/Full tile by newer Fast app pixels.
  uint64_t pen_cross_mode_preemptions;
  // Appended by the exact Xochitl mapped-color pipeline.
  uint64_t color_enabled;
  uint64_t mapped_admissions;
  uint64_t mapped_started;
  uint64_t mapped_queued;
  uint64_t mapped_terminals;
  uint64_t mapped_confirmed;
  uint64_t mapped_discarded;
  uint64_t mapped_invalidated;
  uint64_t mapped_poison_regions;
  uint64_t color_reconciles;
  uint64_t color_faults;
  uint64_t color_queue_peak;
  uint64_t color_preprocess_p50_us;
  uint64_t color_preprocess_p95_us;
  uint64_t color_preprocess_max_us;
  uint64_t color_fast_bypasses;
  uint64_t color_fast_bypass_wait_max_us;
  // Appended with the bounded Fast-only admission reserve. `truth` covers
  // every non-Fast immutable/mapped obligation; current counts sum to the
  // existing color obligation count.
  uint64_t color_fast_obligations;
  uint64_t color_truth_obligations;
  uint64_t color_fast_obligation_peak;
  uint64_t color_truth_obligation_peak;
  uint64_t color_fast_reserve_uses;
  uint64_t color_fast_reserve_declines;
  // Appended with the physical pen-focus metadata gate. These count metadata
  // updates only; focus cannot create damage or presenter pixels.
  uint64_t color_pen_focus_updates;
  uint64_t color_pen_focus_clears;
  uint64_t color_pen_focus_truth_deferrals;
  uint64_t color_pen_focus_disjoint_bypasses;
  uint64_t color_pen_focus_deferred_current;
  // Appended with exact same-tile PenTruth coalescing. Input rects and
  // covered lanes describe app-authored damage; grouped tiles are the exact
  // masked mapped operations actually enqueued.
  uint64_t color_pen_truth_input_rects;
  uint64_t color_pen_truth_grouped_tiles;
  uint64_t color_pen_truth_masked_lanes;
  uint64_t color_pen_truth_groups_per_request_max;
} PlutoSwtconDebugStats;

PlutoStatus
pluto_swtcon_presenter_debug_stats(PlutoPresenter *presenter,
                                   PlutoSwtconDebugStats *out_stats);

#ifdef __cplusplus
} // extern "C"
#endif

#ifdef __cplusplus
#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace pluto::swtcon {

class DrmInterface;

// Presenter-internal Fast-latch mask primitive. OR the source coverage into
// destination coordinates, clipping to the exact rect intersection. Rows are
// LSB-first bit masks with independently padded byte strides. This is exposed
// here so the production reconciliation primitive has a direct unit/benchmark
// seam; callers must provide complete stride*height storage.
bool or_fast_coverage_overlap(PlutoRect source_rect,
                              std::span<const std::uint8_t> source_bits,
                              std::size_t source_stride,
                              PlutoRect destination_rect,
                              std::span<std::uint8_t> destination_bits,
                              std::size_t destination_stride);

// TEST-ONLY seam: the next non-dry-run open() consumes this interface in
// place of make_real_drm_interface(), so host tests can observe the DRM
// flip stream through the DrmInterface mock (drm_swtcon_device.h).
void set_drm_interface_for_testing(std::unique_ptr<DrmInterface> drm);

// TEST-ONLY seam for the positive exact-color device route. This exercises
// the same fixed-profile matcher used by production after reading immutable
// kernel identity. Every geometry field and both identity strings must match
// a complete profile row; sharing only the Move's visible dimensions is not
// sufficient.
bool color_handoff_profile_matches_for_testing(
    int width, int height, int engine_stride, std::uint32_t tile_px,
    int history_stride, int history_rows, std::string_view machine,
    std::string_view soc);

// TEST-ONLY seam for the production handoff namespace gate. This calls the
// real canonical-path, ownership, permissions, and tmpfs check; it does not
// substitute a host-friendly filesystem predicate.
bool production_handoff_path_is_secure_tmpfs_for_testing(
    const std::string &path);

// TEST-ONLY seam (content-consistency oracle): snapshot of the engine's
// settled-glass truth plane (PixelEngine prev plane, 5-bit levels,
// engine-stride rows). The copy is serviced ON the engine thread — the
// call blocks until the engine wakes and fulfills it — so it is safe
// against the engine-confined planes. Returns false when the presenter is
// closed or closing.
bool debug_glass_for_testing(PlutoPresenter *presenter,
                             std::vector<std::uint8_t> *out_levels,
                             int *out_width, int *out_height, int *out_stride);

// TEST-ONLY seam (double-scan recharge oracle): per-tile snapshot of the
// DC ledger's aggregate rescan account and stress accumulator, row-major
// over the tile grid (`out_tile_cols` columns). Serviced ON the engine
// thread like debug_glass_for_testing — the ledger is engine-confined.
// Returns false when the presenter is closed or closing.
bool debug_dc_for_testing(PlutoPresenter *presenter,
                          std::vector<std::int32_t> *out_rescan,
                          std::vector<std::uint16_t> *out_stress,
                          std::uint32_t *out_tile_cols);

// TEST-ONLY exact-color history oracle. Returns the committed Xochitl A/B
// words after the engine-thread latch fence has completed.
bool debug_color_history_for_testing(PlutoPresenter *presenter, int x, int y,
                                     std::uint16_t *out_a,
                                     std::uint16_t *out_b);

} // namespace pluto::swtcon
#endif // __cplusplus

#endif // PLUTO_PRESENTER_SWTCON_DRM_SWTCON_PRESENTER_H_
