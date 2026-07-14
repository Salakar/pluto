#include "renderer/perception.h"

#include <cstdlib>

namespace pluto {

// Stub saliency: center-weighted (fovea bias), 256 at the panel center
// falling to 192 at the corners. Pen-proximity boosting arrives with the
// ink thread (pen-proximity > center > periphery).
uint32_t PerceptionConstants::saliency_q8(const PlutoRect& rect,
                                          int32_t panel_width,
                                          int32_t panel_height) const {
  if (panel_width <= 0 || panel_height <= 0) {
    return 256;
  }
  const int64_t cx = rect.x + rect.width / 2;
  const int64_t cy = rect.y + rect.height / 2;
  const int64_t dx = std::abs(cx - panel_width / 2);
  const int64_t dy = std::abs(cy - panel_height / 2);
  // Normalized L1 distance from center in Q8 (0 center .. 256 corner).
  const int64_t norm =
      (dx * 256) / (panel_width / 2 + 1) + (dy * 256) / (panel_height / 2 + 1);
  const int64_t clamped = norm > 512 ? 512 : norm;
  return static_cast<uint32_t>(256 - clamped / 8);  // 256 .. 192
}

}  // namespace pluto
