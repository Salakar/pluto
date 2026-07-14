#include "renderer/pen_render_policy.h"

#include <algorithm>
#include <cmath>
#include <limits>

#include "renderer/rect_utils.h"

namespace pluto {
namespace {

int64_t distance_squared_to_rect(int32_t x, int32_t y,
                                 const PlutoRect &rect) {
  const int32_t nearest_x =
      std::clamp(x, rect.x, std::max(rect.x, rect_right(rect) - 1));
  const int32_t nearest_y =
      std::clamp(y, rect.y, std::max(rect.y, rect_bottom(rect) - 1));
  const int64_t dx = static_cast<int64_t>(x) - nearest_x;
  const int64_t dy = static_cast<int64_t>(y) - nearest_y;
  return dx * dx + dy * dy;
}

// Returns a rectangle inside `container` and with area <= `area_budget`.
// It expands a small desired rect or crops an oversized one around the nib;
// therefore the percentage cap remains geometric even after a stale/large
// swept focus or an oversized classifier region reaches this policy.
PlutoRect fit_window_to_area(const PlutoRect &desired,
                               const PlutoRect &container,
                               uint64_t area_budget, int32_t anchor_x,
                               int32_t anchor_y) {
  const PlutoRect target = rect_intersection(desired, container);
  if (rect_is_empty(target) || rect_is_empty(container) || area_budget == 0) {
    return PlutoRect{};
  }
  const uint64_t container_area =
      static_cast<uint64_t>(rect_area(container));
  area_budget = std::min(area_budget, container_area);
  const uint64_t target_area = static_cast<uint64_t>(rect_area(target));
  const double scale =
      std::sqrt(static_cast<double>(area_budget) / target_area);
  int32_t width = std::clamp<int64_t>(
      static_cast<int64_t>(std::floor(target.width * scale)), 1,
      container.width);
  int32_t height = std::clamp<int64_t>(
      static_cast<int64_t>(std::floor(target.height * scale)), 1,
      container.height);

  if (static_cast<uint64_t>(width) * height > area_budget) {
    if (width >= height) {
      width = static_cast<int32_t>(
          std::max<uint64_t>(1, area_budget / static_cast<uint64_t>(height)));
    } else {
      height = static_cast<int32_t>(
          std::max<uint64_t>(1, area_budget / static_cast<uint64_t>(width)));
    }
  }
  // Spend spare area along either axis after panel-edge clamping. This keeps
  // long horizontal/vertical trajectories useful without ever exceeding the
  // integer area cap.
  width = std::min<int32_t>(
      container.width,
      static_cast<int32_t>(area_budget / static_cast<uint64_t>(height)));
  height = std::min<int32_t>(
      container.height,
      static_cast<int32_t>(area_budget / static_cast<uint64_t>(width)));

  anchor_x = std::clamp(anchor_x, target.x, rect_right(target) - 1);
  anchor_y = std::clamp(anchor_y, target.y, rect_bottom(target) - 1);
  int32_t x = std::clamp(anchor_x - width / 2, container.x,
                         rect_right(container) - width);
  int32_t y = std::clamp(anchor_y - height / 2, container.y,
                         rect_bottom(container) - height);
  if (width < target.width) {
    x = std::clamp(x, target.x, rect_right(target) - width);
  } else {
    x = std::clamp(x, rect_right(target) - width, target.x);
  }
  if (height < target.height) {
    y = std::clamp(y, target.y, rect_bottom(target) - height);
  } else {
    y = std::clamp(y, rect_bottom(target) - height, target.y);
  }
  return PlutoRect{x, y, width, height};
}

} // namespace

bool PenRenderPolicy::configure(const PenRenderPolicyConfig &config) {
  valid_ = false;
  if (config.width <= 0 || config.height <= 0 ||
      config.tile_px == 0 ||
      config.changed_pixel_area_scale == 0 ||
      config.max_preview_area_percent == 0 ||
      config.max_preview_area_percent > 100) {
    return false;
  }
  config_ = config;
  tile_cols_ =
      (static_cast<uint32_t>(config.width) + config.tile_px - 1) /
      config.tile_px;
  tile_rows_ =
      (static_cast<uint32_t>(config.height) + config.tile_px - 1) /
      config.tile_px;
  const uint64_t tile_count64 =
      static_cast<uint64_t>(tile_cols_) * tile_rows_;
  if (tile_count64 == 0 ||
      tile_count64 > std::numeric_limits<uint32_t>::max() ||
      tile_count64 > std::numeric_limits<size_t>::max()) {
    tile_cols_ = 0;
    tile_rows_ = 0;
    return false;
  }
  const size_t tile_count = static_cast<size_t>(tile_count64);
  record_for_tile_.assign(tile_count, -1);
  selected_record_.assign(tile_count, 0);
  component_queue_.resize(tile_count);
  valid_ = true;
  return true;
}

PlutoRect pen_focus_rect_for_points(
    int32_t previous_x, int32_t previous_y, int32_t current_x,
    int32_t current_y, int32_t predicted_x, int32_t predicted_y,
    bool in_range, bool contact, int32_t width, int32_t height,
    uint32_t hover_radius_px, uint32_t contact_radius_px) {
  if (!in_range || width <= 0 || height <= 0) {
    return PlutoRect{};
  }
  const int32_t base = static_cast<int32_t>(
      contact ? contact_radius_px : hover_radius_px);
  const double lead =
      std::hypot(static_cast<double>(predicted_x - current_x),
                 static_cast<double>(predicted_y - current_y));
  // A fast pen gets a slightly wider leading corridor. Prediction is only a
  // scheduling hint, so a wrong direction cannot create a visible artifact.
  const int32_t dynamic =
      std::min<int32_t>(base, static_cast<int32_t>(std::lround(lead * 0.5)));
  const int32_t radius = base + dynamic;
  const int32_t x0 =
      std::min({previous_x, current_x, predicted_x}) - radius;
  const int32_t y0 =
      std::min({previous_y, current_y, predicted_y}) - radius;
  const int32_t x1 =
      std::max({previous_x, current_x, predicted_x}) + radius + 1;
  const int32_t y1 =
      std::max({previous_y, current_y, predicted_y}) + radius + 1;
  return rect_clip(PlutoRect{x0, y0, x1 - x0, y1 - y0}, width, height);
}

PlutoRect
PenRenderPolicy::focus_rect(const PenRenderHintSnapshot &hint) const {
  if (!valid_) {
    return PlutoRect{};
  }
  return pen_focus_rect_for_points(
      hint.previous_x, hint.previous_y, hint.current_x, hint.current_y,
      hint.predicted_x, hint.predicted_y, hint.in_range, hint.contact,
      config_.width, config_.height, config_.hover_radius_px,
      config_.contact_radius_px);
}

PenRenderRoute PenRenderPolicy::route_region(const PlutoRect &region,
                                             const PenRenderHintSnapshot &hint,
                                             const DirtyTileRecord *records,
                                             size_t record_count,
                                             bool panel_is_color) const {
  PenRenderRoute route;
  if (!valid_ || records == nullptr || record_count == 0) {
    return route;
  }
  const PlutoRect clipped = rect_clip(region, config_.width, config_.height);
  const PlutoRect focus = focus_rect(hint);
  if (rect_is_empty(clipped) || rect_is_empty(focus) ||
      !rect_intersects(clipped, focus)) {
    return route;
  }
  if (record_count > selected_record_.size()) {
    return PenRenderRoute{};
  }

  const uint64_t panel_area =
      static_cast<uint64_t>(config_.width) * config_.height;
  const uint64_t hard_cap = std::max<uint64_t>(
      1, panel_area * config_.max_preview_area_percent / 100u);
  const PlutoRect focus_in_region = rect_intersection(focus, clipped);
  const int32_t search_anchor_x =
      hint.current_x + (hint.predicted_x - hint.current_x) / 2;
  const int32_t search_anchor_y =
      hint.current_y + (hint.predicted_y - hint.current_y) / 2;

  std::fill(record_for_tile_.begin(), record_for_tile_.end(), -1);
  std::fill_n(selected_record_.begin(), record_count, uint8_t{0});
  size_t seed_record = record_count;
  int64_t seed_distance = std::numeric_limits<int64_t>::max();
  for (size_t i = 0; i < record_count; ++i) {
    const DirtyTileRecord &record = records[i];
    if (!rect_intersects(record.dirty, clipped)) {
      continue;
    }
    if (record.tile_idx < record_for_tile_.size()) {
      record_for_tile_[record.tile_idx] = static_cast<int32_t>(i);
    }
    if (!rect_intersects(record.dirty, focus_in_region)) {
      continue;
    }
    const int64_t distance = std::min(
        distance_squared_to_rect(hint.current_x, hint.current_y, record.dirty),
        distance_squared_to_rect(hint.predicted_x, hint.predicted_y,
                                 record.dirty));
    if (distance < seed_distance) {
      seed_distance = distance;
      seed_record = i;
    }
  }
  if (seed_record == record_count) {
    return PenRenderRoute{};
  }

  // Follow the one 8-neighbour tile component rooted closest to the current
  // or predicted nib. The focus is an association gate, not output geometry:
  // once a verified dirty component touches the pen corridor, follow that
  // component through the complete app-damage region. This lets a Flutter
  // frame which coalesced several pen samples expose the continuous rendered
  // stroke instead of one isolated focus-sized island. A disconnected
  // animation elsewhere still cannot inflate the brush budget or force color
  // fidelity.
  size_t queue_head = 0;
  size_t queue_tail = 0;
  selected_record_[seed_record] = 1;
  component_queue_[queue_tail++] = static_cast<uint32_t>(seed_record);
  while (queue_head < queue_tail) {
    const uint32_t record_index = component_queue_[queue_head++];
    const uint32_t tile_idx = records[record_index].tile_idx;
    if (tile_idx >= record_for_tile_.size()) {
      continue;
    }
    const int32_t tx = static_cast<int32_t>(tile_idx % tile_cols_);
    const int32_t ty = static_cast<int32_t>(tile_idx / tile_cols_);
    for (int32_t dy = -1; dy <= 1; ++dy) {
      const int32_t ny = ty + dy;
      if (ny < 0 || ny >= static_cast<int32_t>(tile_rows_)) {
        continue;
      }
      for (int32_t dx = -1; dx <= 1; ++dx) {
        const int32_t nx = tx + dx;
        if ((dx == 0 && dy == 0) || nx < 0 ||
            nx >= static_cast<int32_t>(tile_cols_)) {
          continue;
        }
        const uint32_t neighbour_tile =
            static_cast<uint32_t>(ny) * tile_cols_ +
            static_cast<uint32_t>(nx);
        const int32_t neighbour_record = record_for_tile_[neighbour_tile];
        if (neighbour_record < 0 || selected_record_[neighbour_record] != 0) {
          continue;
        }
        selected_record_[neighbour_record] = 1;
        component_queue_[queue_tail++] =
            static_cast<uint32_t>(neighbour_record);
      }
    }
  }

  uint64_t component_changed_pixels = 0;
  PlutoRect component_bounds{};
  for (size_t i = 0; i < record_count; ++i) {
    if (selected_record_[i] == 0) {
      continue;
    }
    component_changed_pixels += records[i].stats.changed_px;
    component_bounds = rect_union(
        component_bounds,
        rect_intersection(records[i].dirty, clipped));
  }
  if (component_changed_pixels == 0 || rect_is_empty(component_bounds)) {
    return PenRenderRoute{};
  }

  const uint64_t changed_budget =
      component_changed_pixels >
              hard_cap / config_.changed_pixel_area_scale
          ? hard_cap
          : std::min<uint64_t>(
                hard_cap,
                component_changed_pixels * config_.changed_pixel_area_scale);
  // The broad hover/contact focus proved association only. Do not present its
  // unchanged background: output area scales exclusively with verified
  // changed pixels and is constrained to the connected dirty-record bounds.
  // Clamp the directional anchor into the seed record so an aggressively
  // predicted point can never crop the route into an empty part of a curved
  // component's bounding box.
  const PlutoRect seed_bounds =
      rect_intersection(records[seed_record].dirty, clipped);
  const int32_t output_anchor_x =
      std::clamp(search_anchor_x, seed_bounds.x, rect_right(seed_bounds) - 1);
  const int32_t output_anchor_y =
      std::clamp(search_anchor_y, seed_bounds.y, rect_bottom(seed_bounds) - 1);
  const PlutoRect hot = fit_window_to_area(
      component_bounds, component_bounds, changed_budget, output_anchor_x,
      output_anchor_y);
  if (rect_is_empty(hot)) {
    return PenRenderRoute{};
  }

  bool routed_record = false;
  for (size_t i = 0; i < record_count; ++i) {
    if (selected_record_[i] == 0 ||
        !rect_intersects(records[i].dirty, hot)) {
      continue;
    }
    routed_record = true;
    ++route.dirty_tiles;
    route.changed_pixels += records[i].stats.changed_px;
    route.carries_chroma =
        route.carries_chroma || records[i].stats.changed_chroma != 0;
  }
  if (!routed_record) {
    return PenRenderRoute{};
  }
  route.associated = true;
  route.preview = hot;
  route.truth = hot;
  route.truth_class = panel_is_color && route.carries_chroma
                          ? kPlutoRefreshFull
                          : kPlutoRefreshText;
  return route;
}

size_t PenRenderPolicy::subtract_rect(const PlutoRect &outer,
                                      const PlutoRect &cut,
                                      PlutoRect out[4]) {
  if (out == nullptr || rect_is_empty(outer)) {
    return 0;
  }
  const PlutoRect overlap = rect_intersection(outer, cut);
  if (rect_is_empty(overlap)) {
    out[0] = outer;
    return 1;
  }
  size_t count = 0;
  auto push = [&](const PlutoRect &rect) {
    if (!rect_is_empty(rect)) {
      out[count++] = rect;
    }
  };
  // Top and bottom span the full outer width. Left/right cover only the
  // overlap's vertical band, so the pieces are disjoint and exact.
  push(PlutoRect{outer.x, outer.y, outer.width, overlap.y - outer.y});
  push(PlutoRect{outer.x, rect_bottom(overlap), outer.width,
                   rect_bottom(outer) - rect_bottom(overlap)});
  push(PlutoRect{outer.x, overlap.y, overlap.x - outer.x, overlap.height});
  push(PlutoRect{rect_right(overlap), overlap.y,
                   rect_right(outer) - rect_right(overlap), overlap.height});
  return count;
}

} // namespace pluto
