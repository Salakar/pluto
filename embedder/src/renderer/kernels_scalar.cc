#include "renderer/kernels.h"

#include <algorithm>
#include <cstdlib>

#include "renderer/bluenoise_64.h"
#include "renderer/quantize.h"

namespace pluto {

void luma_from_rgb565_span_scalar(const uint16_t* src, size_t n,
                                  uint8_t* out) {
  for (size_t i = 0; i < n; ++i) {
    // Verbatim reference math (renderer/quantize.cc rgb565_luma8) so the
    // quantized plane is bit-exact with the reference convert path.
    out[i] = rgb565_luma8(src[i]);
  }
}

void luma_from_xrgb8888_span_scalar(const uint8_t* src, size_t n,
                                    uint8_t* out) {
  for (size_t i = 0; i < n; ++i) {
    const uint8_t* p = src + i * 4u;  // [x, r, g, b] (host_preview.cc layout)
    out[i] = static_cast<uint8_t>(
        (54u * p[1] + 183u * p[2] + 19u * p[3] + 128u) >> 8u);
  }
}

void chroma_mag_from_rgb565_span_scalar(const uint16_t* src, size_t n,
                                        uint8_t* out) {
  for (size_t i = 0; i < n; ++i) {
    // Same plain-shift expansion as rgb565_has_chroma (renderer/quantize.cc)
    // so (mag > chroma_floor=12) reproduces the legacy predicate exactly.
    const uint16_t rgb565 = src[i];
    const int r = static_cast<int>(((rgb565 >> 11) & 0x1f) << 3);
    const int g = static_cast<int>(((rgb565 >> 5) & 0x3f) << 2);
    const int b = static_cast<int>((rgb565 & 0x1f) << 3);
    const int max_delta =
        std::max({std::abs(r - g), std::abs(r - b), std::abs(g - b)});
    out[i] = static_cast<uint8_t>(max_delta);
  }
}

void chroma_mag_from_xrgb8888_span_scalar(const uint8_t* src, size_t n,
                                          uint8_t* out) {
  for (size_t i = 0; i < n; ++i) {
    const uint8_t* p = src + i * 4u;
    const int r = p[1];
    const int g = p[2];
    const int b = p[3];
    const int max_delta =
        std::max({std::abs(r - g), std::abs(r - b), std::abs(g - b)});
    out[i] = static_cast<uint8_t>(max_delta);
  }
}

void fill_bluenoise_thresholds(int32_t x0, int32_t y, size_t n, uint8_t* out) {
  for (size_t i = 0; i < n; ++i) {
    out[i] = blue_noise_64_at(x0 + static_cast<int32_t>(i), y);
  }
}

const uint8_t* bluenoise_threshold_span(int32_t x0, int32_t y, size_t n,
                                        uint8_t* scratch) {
  const uint32_t col = static_cast<uint32_t>(x0) & 63u;
  if (col + n <= 64u) {
    return &k_blue_noise_64[(static_cast<uint32_t>(y) & 63u) * 64u + col];
  }
  fill_bluenoise_thresholds(x0, y, n, scratch);
  return scratch;
}

void quantize16_span_scalar(const uint8_t* luma, const uint8_t* thresholds,
                            size_t n, uint8_t* out_lvl5) {
  constexpr uint32_t k_levels_minus_one = 15;
  for (size_t i = 0; i < n; ++i) {
    // Level selection verbatim from quantize_gray16 (renderer/quantize.cc);
    // only the output byte differs: 5-bit level (index * 2) instead of the
    // legacy 8-bit gray (index * 17).
    const uint32_t scaled = static_cast<uint32_t>(luma[i]) * k_levels_minus_one;
    uint32_t level = scaled / 255u;
    const uint32_t rem = scaled - level * 255u;
    if (rem > thresholds[i] && level < k_levels_minus_one) {
      ++level;
    }
    out_lvl5[i] = static_cast<uint8_t>(level * 2u);
  }
}

SpanDiff diff_span_scalar(const uint8_t* a, const uint8_t* b, size_t n) {
  SpanDiff out;
  for (size_t i = 0; i < n; ++i) {
    if (a[i] != b[i]) {
      ++out.changed;
      if (out.first < 0) {
        out.first = static_cast<int32_t>(i);
      }
      out.last = static_cast<int32_t>(i);
    }
  }
  return out;
}

SpanSignificance significance_span_scalar(const uint8_t* luma,
                                          const uint8_t* old_lvl5, size_t n) {
  SpanSignificance out;
  for (size_t i = 0; i < n; ++i) {
    const int gray = level5_to_gray8(old_lvl5[i]);
    const int diff = std::abs(static_cast<int>(luma[i]) - gray);
    out.sad += static_cast<uint32_t>(diff);
    out.max_diff = std::max(out.max_diff, static_cast<uint8_t>(diff));
  }
  return out;
}

uint16_t level_hist_bits_span_scalar(const uint8_t* lvl5, size_t n) {
  uint16_t bits = 0;
  for (size_t i = 0; i < n; ++i) {
    bits = static_cast<uint16_t>(bits | (1u << (lvl5[i] >> 1u)));
  }
  return bits;
}

uint32_t count_above_span_scalar(const uint8_t* vals, uint8_t floor,
                                 size_t n) {
  uint32_t count = 0;
  for (size_t i = 0; i < n; ++i) {
    if (vals[i] > floor) {
      ++count;
    }
  }
  return count;
}

void levels_to_gray8_span_scalar(const uint8_t* lvl5, size_t n, uint8_t* out) {
  for (size_t i = 0; i < n; ++i) {
    out[i] = level5_to_gray8(lvl5[i]);
  }
}

void levels_to_rgb565_span_scalar(const uint8_t* lvl5, size_t n,
                                  uint16_t* out) {
  for (size_t i = 0; i < n; ++i) {
    const uint8_t gray = level5_to_gray8(lvl5[i]);
    out[i] = rgb888_to_rgb565(gray, gray, gray);
  }
}

uint32_t hash_row_fnv1a(const uint8_t* bytes, size_t n, uint32_t seed) {
  uint32_t hash = seed;
  for (size_t i = 0; i < n; ++i) {
    hash ^= bytes[i];
    hash *= 0x01000193u;
  }
  return hash;
}

void hash_rows_fnv1a_x8(const uint8_t* const* rows, size_t n, uint32_t* out8) {
  // Eight independent FNV-1a chains stepped in lockstep. Each column touches
  // all eight rows before advancing, so the eight independent multiplies fill
  // the multiplier pipeline while any single chain's ~4-cycle latency drains.
  constexpr uint32_t kPrime = 0x01000193u;
  const uint8_t* r0 = rows[0];
  const uint8_t* r1 = rows[1];
  const uint8_t* r2 = rows[2];
  const uint8_t* r3 = rows[3];
  const uint8_t* r4 = rows[4];
  const uint8_t* r5 = rows[5];
  const uint8_t* r6 = rows[6];
  const uint8_t* r7 = rows[7];
  uint32_t h0 = kFnv1aSeed, h1 = kFnv1aSeed, h2 = kFnv1aSeed, h3 = kFnv1aSeed;
  uint32_t h4 = kFnv1aSeed, h5 = kFnv1aSeed, h6 = kFnv1aSeed, h7 = kFnv1aSeed;
  for (size_t i = 0; i < n; ++i) {
    h0 = (h0 ^ r0[i]) * kPrime;
    h1 = (h1 ^ r1[i]) * kPrime;
    h2 = (h2 ^ r2[i]) * kPrime;
    h3 = (h3 ^ r3[i]) * kPrime;
    h4 = (h4 ^ r4[i]) * kPrime;
    h5 = (h5 ^ r5[i]) * kPrime;
    h6 = (h6 ^ r6[i]) * kPrime;
    h7 = (h7 ^ r7[i]) * kPrime;
  }
  out8[0] = h0;
  out8[1] = h1;
  out8[2] = h2;
  out8[3] = h3;
  out8[4] = h4;
  out8[5] = h5;
  out8[6] = h6;
  out8[7] = h7;
}

}  // namespace pluto
