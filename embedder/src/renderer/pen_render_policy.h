#ifndef PLUTO_RENDERER_PEN_RENDER_POLICY_H_
#define PLUTO_RENDERER_PEN_RENDER_POLICY_H_

#include <cstddef>
#include <cstdint>
#include <vector>

#include "pluto/presenter.h"
#include "renderer/tile_pass.h"

namespace pluto {

// A scheduling hint only. The input stack may publish this for hover or
// contact, but it never carries pixels and must never cause a present by
// itself. Coordinates are in the logical surface space consumed by
// FrameRenderer.
struct PenRenderHintSnapshot {
  int64_t timestamp_us = 0;
  bool in_range = false;
  bool contact = false;
  int32_t previous_x = 0;
  int32_t previous_y = 0;
  int32_t current_x = 0;
  int32_t current_y = 0;
  int32_t predicted_x = 0;
  int32_t predicted_y = 0;
  uint64_t sequence = 0;
};

struct PenRenderPolicyConfig {
  int32_t width = 954;
  int32_t height = 1696;
  // Must match the FrameLedger geometry. It lets the policy follow only the
  // tile-connected app damage component rooted at the nib instead of charging
  // unrelated changes elsewhere in the classifier region.
  uint32_t tile_px = 32;
  // Hover gets a wider corridor so app-owned cursors/brush outlines at the
  // nib edge are caught before contact. Contact stays tighter to keep the
  // lowest-latency drive small.
  uint32_t hover_radius_px = 48;
  uint32_t contact_radius_px = 36;
  // Actual changed pixels determine how far a large app-rendered brush may
  // expand the fast region. This scales the changed-pixel budget. The swept
  // focus corridor is association-only and never adds unchanged output area;
  // final geometry stays inside the verified connected dirty-record bounds.
  uint32_t changed_pixel_area_scale = 8;
  // A coincident full-screen animation must not become one giant pen update.
  // Large regions are split: the corridor gets pen priority and the rest
  // remains normal app damage.
  uint32_t max_preview_area_percent = 20;
};

struct PenRenderRoute {
  bool associated = false;
  PlutoRect preview{}; // app pixels shown immediately as Fast grayscale
  PlutoRect truth{};   // same app pixels chased immediately at fidelity
  PlutoRefreshClass truth_class = kPlutoRefreshText;
  uint64_t changed_pixels = 0;
  uint32_t dirty_tiles = 0;
  bool carries_chroma = false;
};

// Shared pure geometry used by both the renderer's logical scheduler hint and
// EngineHost's pre-Flutter native-panel presenter reservation. It only
// computes a clipped corridor; it owns no pixels and cannot schedule output.
PlutoRect pen_focus_rect_for_points(int32_t previous_x, int32_t previous_y,
                                      int32_t current_x, int32_t current_y,
                                      int32_t predicted_x,
                                      int32_t predicted_y, bool in_range,
                                      bool contact, int32_t width,
                                      int32_t height, uint32_t hover_radius_px,
                                      uint32_t contact_radius_px);

// Correlates recent pen motion with the renderer's verified post-quantize
// damage. It does not own input state, pixels, or queues. A route can only be
// produced when at least one DirtyTileRecord intersects both the app damage
// region and the swept hover/contact corridor. Once associated, routing may
// follow that record's connected dirty-tile component beyond the focus so a
// coalesced app-rendered stroke stays continuous.
class PenRenderPolicy {
public:
  bool configure(const PenRenderPolicyConfig &config);
  bool valid() const { return valid_; }

  PlutoRect focus_rect(const PenRenderHintSnapshot &hint) const;

  PenRenderRoute route_region(const PlutoRect &region,
                              const PenRenderHintSnapshot &hint,
                              const DirtyTileRecord *records,
                              size_t record_count, bool panel_is_color) const;

  // Exact rectangle subtraction used when a very large app region is split
  // into a pen-priority corridor and ordinary residual damage. Returns up to
  // four non-overlapping rectangles covering outer - cut.
  static size_t subtract_rect(const PlutoRect &outer, const PlutoRect &cut,
                              PlutoRect out[4]);

private:
  PenRenderPolicyConfig config_{};
  uint32_t tile_cols_ = 0;
  uint32_t tile_rows_ = 0;
  // Sized once at configure(). route_region() is allocation-free; the policy
  // is renderer-thread confined, so const routing may reuse mutable scratch.
  mutable std::vector<int32_t> record_for_tile_;
  mutable std::vector<uint8_t> selected_record_;
  mutable std::vector<uint32_t> component_queue_;
  bool valid_ = false;
};

} // namespace pluto

#endif // PLUTO_RENDERER_PEN_RENDER_POLICY_H_
