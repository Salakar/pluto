#include "renderer/gallery3.h"

#include <algorithm>

namespace pluto {
namespace {

using gallery3_detail::k_entries;
using gallery3_detail::k_entries_565;
using gallery3_detail::Rgb888;

// Nearest-entry distance in a luma/chroma-separated space. Chroma error is
// weighted far above luma error so desaturated inputs snap to black/white
// mixes instead of whichever chromatic pigment happens to sit at their
// lightness (a plain weighted-RGB metric sends mid-grays to green).
constexpr int k_weight_luma = 2;
constexpr int k_weight_chroma = 9;

int luma_of(int r, int g, int b) {
  return (30 * r + 59 * g + 11 * b + 50) / 100;
}

uint64_t luma_chroma_distance(const Rgb888& a, int r, int g, int b) {
  const int luma_a = luma_of(a.r, a.g, a.b);
  const int luma_b = luma_of(r, g, b);
  const int64_t d_luma = luma_a - luma_b;
  // Chroma = the color's offset from its own gray axis point.
  const int64_t d_cr = (a.r - luma_a) - (r - luma_b);
  const int64_t d_cg = (a.g - luma_a) - (g - luma_b);
  const int64_t d_cb = (a.b - luma_a) - (b - luma_b);
  return static_cast<uint64_t>(
      k_weight_luma * d_luma * d_luma +
      k_weight_chroma * (d_cr * d_cr + d_cg * d_cg + d_cb * d_cb));
}

uint8_t brute_force_nearest(uint8_t r, uint8_t g, uint8_t b) {
  uint8_t best = 0;
  uint64_t best_distance = luma_chroma_distance(k_entries[0], r, g, b);
  for (size_t i = 1; i < k_entries.size(); ++i) {
    const uint64_t distance = luma_chroma_distance(k_entries[i], r, g, b);
    if (distance < best_distance) {
      best_distance = distance;
      best = static_cast<uint8_t>(i);
    }
  }
  return best;
}

}  // namespace

Gallery3Palette::Gallery3Palette() {
  for (uint32_t r = 0; r < k_lattice; ++r) {
    for (uint32_t g = 0; g < k_lattice; ++g) {
      for (uint32_t b = 0; b < k_lattice; ++b) {
        const uint8_t r8 = static_cast<uint8_t>((r * 255u) / 16u);
        const uint8_t g8 = static_cast<uint8_t>((g * 255u) / 16u);
        const uint8_t b8 = static_cast<uint8_t>((b * 255u) / 16u);
        lut_[(r * k_lattice + g) * k_lattice + b] =
            brute_force_nearest(r8, g8, b8);
      }
    }
  }
  for (size_t i = 0; i < lut_.size(); ++i) {
    lut565_[i] = k_entries_565[lut_[i]];
  }
}

const Gallery3Palette& Gallery3Palette::instance() {
  static const Gallery3Palette palette;
  return palette;
}

uint8_t Gallery3Palette::nearest_index(uint8_t r, uint8_t g, uint8_t b) const {
  return brute_force_nearest(r, g, b);
}

const std::array<uint16_t, Gallery3Palette::k_entry_count>&
Gallery3Palette::entries_rgb565() {
  return k_entries_565;
}

}  // namespace pluto
