#ifndef PLUTO_RENDERER_RECT_UTILS_H_
#define PLUTO_RENDERER_RECT_UTILS_H_

#include <algorithm>
#include <cstdint>

#include "pluto/presenter.h"

namespace pluto {

inline bool rect_is_empty(const PlutoRect& r) {
  return r.width <= 0 || r.height <= 0;
}

inline int32_t rect_right(const PlutoRect& r) {
  return r.x + r.width;
}

inline int32_t rect_bottom(const PlutoRect& r) {
  return r.y + r.height;
}

inline int64_t rect_area(const PlutoRect& r) {
  if (rect_is_empty(r)) {
    return 0;
  }
  return static_cast<int64_t>(r.width) * static_cast<int64_t>(r.height);
}

inline PlutoRect rect_union(const PlutoRect& a, const PlutoRect& b) {
  if (rect_is_empty(a)) {
    return b;
  }
  if (rect_is_empty(b)) {
    return a;
  }
  const int32_t x0 = std::min(a.x, b.x);
  const int32_t y0 = std::min(a.y, b.y);
  const int32_t x1 = std::max(rect_right(a), rect_right(b));
  const int32_t y1 = std::max(rect_bottom(a), rect_bottom(b));
  return PlutoRect{x0, y0, x1 - x0, y1 - y0};
}

inline bool rect_intersects(const PlutoRect& a, const PlutoRect& b) {
  return !rect_is_empty(a) && !rect_is_empty(b) && a.x < rect_right(b) &&
         b.x < rect_right(a) && a.y < rect_bottom(b) && b.y < rect_bottom(a);
}

inline PlutoRect rect_intersection(const PlutoRect& a,
                                     const PlutoRect& b) {
  const int32_t x0 = std::max(a.x, b.x);
  const int32_t y0 = std::max(a.y, b.y);
  const int32_t x1 = std::min(rect_right(a), rect_right(b));
  const int32_t y1 = std::min(rect_bottom(a), rect_bottom(b));
  if (x1 <= x0 || y1 <= y0) {
    return PlutoRect{0, 0, 0, 0};
  }
  return PlutoRect{x0, y0, x1 - x0, y1 - y0};
}

inline int64_t rect_intersection_area(const PlutoRect& a,
                                      const PlutoRect& b) {
  return rect_area(rect_intersection(a, b));
}

inline PlutoRect rect_clip(const PlutoRect& r,
                             int32_t width,
                             int32_t height) {
  const int32_t x0 = std::clamp(r.x, int32_t{0}, width);
  const int32_t y0 = std::clamp(r.y, int32_t{0}, height);
  const int32_t x1 = std::clamp(rect_right(r), int32_t{0}, width);
  const int32_t y1 = std::clamp(rect_bottom(r), int32_t{0}, height);
  if (x1 <= x0 || y1 <= y0) {
    return PlutoRect{0, 0, 0, 0};
  }
  return PlutoRect{x0, y0, x1 - x0, y1 - y0};
}

inline int32_t floor_to_multiple(int32_t value, int32_t quantum) {
  if (quantum <= 1) {
    return value;
  }
  return (value / quantum) * quantum;
}

inline int32_t ceil_to_multiple(int32_t value, int32_t quantum) {
  if (quantum <= 1) {
    return value;
  }
  return ((value + quantum - 1) / quantum) * quantum;
}

inline PlutoRect rect_align_out(const PlutoRect& r,
                                  int32_t align_px,
                                  int32_t width,
                                  int32_t height) {
  if (rect_is_empty(r)) {
    return PlutoRect{0, 0, 0, 0};
  }
  const int32_t x0 = floor_to_multiple(r.x, align_px);
  const int32_t y0 = floor_to_multiple(r.y, align_px);
  const int32_t x1 = ceil_to_multiple(rect_right(r), align_px);
  const int32_t y1 = ceil_to_multiple(rect_bottom(r), align_px);
  return rect_clip(PlutoRect{x0, y0, x1 - x0, y1 - y0}, width, height);
}

inline int32_t rect_gap_px(const PlutoRect& a, const PlutoRect& b) {
  if (rect_intersects(a, b)) {
    return 0;
  }
  const int32_t dx = std::max({a.x - rect_right(b), b.x - rect_right(a), 0});
  const int32_t dy = std::max({a.y - rect_bottom(b), b.y - rect_bottom(a), 0});
  return std::max(dx, dy);
}

inline int64_t rect_merge_waste(const PlutoRect& a, const PlutoRect& b) {
  return rect_area(rect_union(a, b)) - rect_area(a) - rect_area(b);
}

inline bool rect_edge_aligned_or_clipped(const PlutoRect& r,
                                         int32_t align_px,
                                         int32_t width,
                                         int32_t height) {
  if (rect_is_empty(r) || align_px <= 1) {
    return true;
  }
  const bool x_aligned = (r.x % align_px) == 0;
  const bool y_aligned = (r.y % align_px) == 0;
  const bool right_ok = (rect_right(r) % align_px) == 0 || rect_right(r) == width;
  const bool bottom_ok =
      (rect_bottom(r) % align_px) == 0 || rect_bottom(r) == height;
  return x_aligned && y_aligned && right_ok && bottom_ok;
}

}  // namespace pluto

#endif  // PLUTO_RENDERER_RECT_UTILS_H_
