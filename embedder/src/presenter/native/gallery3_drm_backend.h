#ifndef PLUTO_PRESENTER_NATIVE_GALLERY3_DRM_BACKEND_H_
#define PLUTO_PRESENTER_NATIVE_GALLERY3_DRM_BACKEND_H_

#include "pluto/presenter.h"

#ifdef __cplusplus
extern "C" {
#endif

// Internal hardware backend used only by the immutable-profile native
// factory. It is intentionally not registered as a user-selectable presenter.
const PlutoPresenterOps *pluto_gallery3_drm_presenter_ops(void);

// Gallery 3 drive counters for diagnostics and host tests. Callers and the
// presenter must use this exact in-tree layout.
typedef struct PlutoGallery3DrmDebugStats {
  size_t struct_size;
  uint64_t updates_completed;
  uint64_t gc16_updates;
  uint64_t full_updates;
  uint64_t settle_updates;
  uint64_t admissions;
  uint64_t absorbed;
  uint64_t parked;
  uint64_t retargets;
  uint64_t cancels;
  uint64_t neutral_frames;
  uint64_t double_scans;
  uint64_t dc_saturations;
  uint64_t pauses;
  uint64_t active_px_peak;
  uint64_t hold_rescans;
  int32_t cold_clear_mode;
  uint64_t pen_cross_mode_preemptions;
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
  uint64_t color_fast_obligations;
  uint64_t color_truth_obligations;
  uint64_t color_fast_obligation_peak;
  uint64_t color_truth_obligation_peak;
  uint64_t color_fast_reserve_uses;
  uint64_t color_fast_reserve_declines;
  uint64_t color_pen_focus_updates;
  uint64_t color_pen_focus_clears;
  uint64_t color_pen_focus_truth_deferrals;
  uint64_t color_pen_focus_disjoint_bypasses;
  uint64_t color_pen_focus_deferred_current;
  uint64_t color_pen_truth_input_rects;
  uint64_t color_pen_truth_grouped_tiles;
  uint64_t color_pen_truth_masked_lanes;
  uint64_t color_pen_truth_groups_per_request_max;
} PlutoGallery3DrmDebugStats;

PlutoStatus pluto_gallery3_drm_presenter_debug_stats(
    PlutoPresenter *presenter, PlutoGallery3DrmDebugStats *out_stats);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // PLUTO_PRESENTER_NATIVE_GALLERY3_DRM_BACKEND_H_
