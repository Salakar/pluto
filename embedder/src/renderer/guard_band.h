#ifndef PLUTO_RENDERER_GUARD_BAND_H_
#define PLUTO_RENDERER_GUARD_BAND_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "pluto/presenter.h"

namespace pluto {

// GuardBandPackager: the single guard authority. Replaced the
// RegionScheduler's +4/+8 px drive-rect dilation (deleted with this
// packager — single-renderer policy).
//
//   * Every content rect gains a guard_px null-transition fringe (1 vs
//     2 px), clipped at the panel edges. Guard rects are marked GUARD-NULL:
//     a consumer that can express null transitions drives them next := prev
//     (the pixel engine's kAdmitFlagGuardNull admissions + the mailbox's
//     header-only records exist for exactly this). The ABI present path
//     cannot express a null band, so today the fringe geometry ships with
//     the package only — the engine's tile-aligned admission already
//     no-ops unchanged fringe pixels, and the direct guard-null admission
//     lane is the same later optimization as the PEN header-only lane.
//   * Text-class damage aggregates into WORD BOXES: small nearby glyph
//     rects cluster, the cluster box snaps OUT to the 8 px rect_alignment
//     grid, and the guard ring wraps the snapped box — repeated keystrokes
//     on a line reuse identical edge geometry (top/bottom edges and every
//     grid column line are shared across updates), so the driven fringe is
//     deterministic instead of wandering per glyph.
//   * flag_map (US11568827) stays unimplemented pending legal review: the
//     config key exists, configure() rejects ON with a warning and runs
//     with the map off.
//
// Thread ownership: raster-thread confined (FrameRenderer submit path).
// Pre-allocated storage; no per-frame heap in steady state.
struct GuardBandConfig {
  int32_t width = 954;
  int32_t height = 1696;
  uint32_t guard_px = 1;           // fringe width (1 vs 2)
  uint32_t word_box_align_px = 8;  // the rect_alignment grid
  uint32_t word_box_gap_px = 16;   // cluster distance for glyph rects
  int32_t word_box_max_px = 64;    // larger rects never cluster
  bool flag_map_enabled = false;   // pending legal review; rejected ON
};

struct GuardRect {
  PlutoRect rect{0, 0, 0, 0};
  // Always true: guard fringes are null-transition bands (engine-side
  // kAdmitFlagGuardNull), never content. Kept explicit so the packaging
  // contract is visible at the consumer.
  bool guard_null = true;
};

// One packaged update: the content rect the scheduler presents plus its
// guard-null fringe (top/bottom/left/right, empty sides omitted).
struct GuardedRegion {
  PlutoRect content{0, 0, 0, 0};
  PlutoRefreshClass cls = kPlutoRefreshUi;
  std::array<GuardRect, 4> guard{};
  size_t guard_count = 0;
  bool word_box = false;  // content is a snapped Text word box
};

class GuardBandPackager {
 public:
  bool configure(const GuardBandConfig& config);
  bool valid() const { return valid_; }
  const GuardBandConfig& config() const { return config_; }

  // Packages one pass's classified damage set. Text-class rects cluster
  // into word boxes; every region gains its guard fringe. Returns the
  // packaged region count (== regions().size()).
  size_t package(const PlutoRect* rects, const PlutoRefreshClass* classes,
                 size_t count);

  const std::vector<GuardedRegion>& regions() const { return regions_; }

 private:
  void emit_region(const PlutoRect& content, PlutoRefreshClass cls,
                   bool word_box);

  GuardBandConfig config_{};
  bool valid_ = false;
  std::vector<GuardedRegion> regions_;
  std::vector<PlutoRect> cluster_rects_;  // Text clustering scratch
};

}  // namespace pluto

#endif  // PLUTO_RENDERER_GUARD_BAND_H_
