#include "renderer/guard_band.h"

#include <algorithm>
#include <cstdio>

#include "renderer/rect_utils.h"

namespace pluto {

bool GuardBandPackager::configure(const GuardBandConfig& config) {
  valid_ = false;
  config_ = config;
  if (config.width <= 0 || config.height <= 0 ||
      config.word_box_align_px == 0) {
    return false;
  }
  if (config_.flag_map_enabled) {
    // US11568827 flag map: config key reserved, implementation gated on the
    // legal review. Loud rejection, never a silent ignore.
    std::fprintf(stderr,
                 "pluto: guard_band: flag_map_enabled=1 rejected (pending "
                 "legal review); running with the flag map off\n");
    config_.flag_map_enabled = false;
  }
  regions_.clear();
  regions_.reserve(64);
  cluster_rects_.clear();
  cluster_rects_.reserve(64);
  valid_ = true;
  return true;
}

// Guard fringe of `content`: the dilation band, clipped at the panel edges
// (top / bottom strips span the dilated width; left / right columns span the
// content height). Marked guard-null.
void GuardBandPackager::emit_region(const PlutoRect& content,
                                    PlutoRefreshClass cls, bool word_box) {
  const PlutoRect clipped =
      rect_clip(content, config_.width, config_.height);
  if (rect_is_empty(clipped)) {
    return;
  }
  GuardedRegion region;
  region.content = clipped;
  region.cls = cls;
  region.word_box = word_box;
  const int32_t g = static_cast<int32_t>(config_.guard_px);
  if (g > 0) {
    const PlutoRect dilated = rect_clip(
        PlutoRect{clipped.x - g, clipped.y - g, clipped.width + 2 * g,
                    clipped.height + 2 * g},
        config_.width, config_.height);
    const PlutoRect sides[4] = {
        // top
        PlutoRect{dilated.x, dilated.y, dilated.width,
                    clipped.y - dilated.y},
        // bottom
        PlutoRect{dilated.x, rect_bottom(clipped), dilated.width,
                    rect_bottom(dilated) - rect_bottom(clipped)},
        // left
        PlutoRect{dilated.x, clipped.y, clipped.x - dilated.x,
                    clipped.height},
        // right
        PlutoRect{rect_right(clipped), clipped.y,
                    rect_right(dilated) - rect_right(clipped),
                    clipped.height},
    };
    for (const PlutoRect& side : sides) {
      if (!rect_is_empty(side)) {
        region.guard[region.guard_count++] = GuardRect{side, true};
      }
    }
  }
  regions_.push_back(region);
}

size_t GuardBandPackager::package(const PlutoRect* rects,
                                  const PlutoRefreshClass* classes,
                                  size_t count) {
  regions_.clear();
  if (!valid_ || rects == nullptr || classes == nullptr) {
    return 0;
  }

  // Non-Text classes pass through with their exact content rects.
  for (size_t i = 0; i < count; ++i) {
    if (classes[i] != kPlutoRefreshText && !rect_is_empty(rects[i])) {
      emit_region(rects[i], classes[i], /*word_box=*/false);
    }
  }

  // Text class: word-box aggregation. Word-sized rects cluster by
  // proximity; oversized rects form their own cluster. Every cluster box
  // snaps OUT to the alignment grid so repeated keystrokes reuse edges.
  cluster_rects_.clear();
  for (size_t i = 0; i < count; ++i) {
    if (classes[i] == kPlutoRefreshText && !rect_is_empty(rects[i])) {
      cluster_rects_.push_back(rects[i]);
    }
  }
  const auto clusterable = [this](const PlutoRect& r) {
    return r.width <= config_.word_box_max_px &&
           r.height <= config_.word_box_max_px;
  };
  bool changed = !cluster_rects_.empty();
  while (changed) {
    changed = false;
    for (size_t a = 0; a < cluster_rects_.size() && !changed; ++a) {
      if (!clusterable(cluster_rects_[a])) {
        continue;
      }
      for (size_t b = a + 1; b < cluster_rects_.size(); ++b) {
        if (!clusterable(cluster_rects_[b])) {
          continue;
        }
        if (rect_gap_px(cluster_rects_[a], cluster_rects_[b]) <=
            static_cast<int32_t>(config_.word_box_gap_px)) {
          cluster_rects_[a] =
              rect_union(cluster_rects_[a], cluster_rects_[b]);
          cluster_rects_[b] = cluster_rects_.back();
          cluster_rects_.pop_back();
          changed = true;
          break;
        }
      }
    }
  }
  for (const PlutoRect& cluster : cluster_rects_) {
    const PlutoRect box = rect_align_out(
        cluster, static_cast<int32_t>(config_.word_box_align_px),
        config_.width, config_.height);
    emit_region(box, kPlutoRefreshText, /*word_box=*/true);
  }
  return regions_.size();
}

}  // namespace pluto
