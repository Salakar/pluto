// NEON (aarch64) implementations of the renderer span kernels. Byte-exact
// vs the scalar references in kernels_scalar.cc — pinned by the golden tests
// in test/renderer/kernels_test.cc over random and structured spans.
//
// The Apple Silicon host and the device A55s are both aarch64, so these
// kernels compile, run, and are golden-tested on the host CI as well as in
// the device-arm64 Release build (E13 bench vehicle).

#include "renderer/kernels.h"

#if defined(__ARM_NEON) && defined(__aarch64__)

#include <arm_neon.h>

#include <algorithm>
#include <cstdlib>

namespace pluto {
namespace {

inline uint8x16x2_t load_expand5_table() {
  return uint8x16x2_t{{vld1q_u8(k_expand5.data()), vld1q_u8(k_expand5.data() + 16)}};
}

inline uint8x16x4_t load_expand6_table() {
  return uint8x16x4_t{{vld1q_u8(k_expand6.data()), vld1q_u8(k_expand6.data() + 16),
                       vld1q_u8(k_expand6.data() + 32),
                       vld1q_u8(k_expand6.data() + 48)}};
}

inline uint8x16x2_t load_dequant_table() {
  return uint8x16x2_t{{vld1q_u8(k_level5_to_gray8.data()),
                       vld1q_u8(k_level5_to_gray8.data() + 16)}};
}

struct Rgb565Lanes {
  uint8x8_t r5;
  uint8x8_t g6;
  uint8x8_t b5;
};

inline Rgb565Lanes split_rgb565(uint16x8_t v) {
  Rgb565Lanes lanes;
  lanes.r5 = vmovn_u16(vshrq_n_u16(v, 11));
  lanes.g6 = vmovn_u16(vandq_u16(vshrq_n_u16(v, 5), vdupq_n_u16(0x3f)));
  lanes.b5 = vmovn_u16(vandq_u16(v, vdupq_n_u16(0x1f)));
  return lanes;
}

// Integer BT.601 weighted sum — identical bias/shift to rgb565_luma8.
inline uint8x8_t luma_from_channels(uint8x8_t r, uint8x8_t g, uint8x8_t b) {
  uint16x8_t acc = vmull_u8(r, vdup_n_u8(54));
  acc = vmlal_u8(acc, g, vdup_n_u8(183));
  acc = vmlal_u8(acc, b, vdup_n_u8(19));
  acc = vaddq_u16(acc, vdupq_n_u16(128));
  return vshrn_n_u16(acc, 8);
}

inline uint8x8_t max_pairwise_delta(uint8x8_t r, uint8x8_t g, uint8x8_t b) {
  return vmax_u8(vmax_u8(vabd_u8(r, g), vabd_u8(r, b)), vabd_u8(g, b));
}

}  // namespace

void luma_from_rgb565_span_neon(const uint16_t* src, size_t n, uint8_t* out) {
  const uint8x16x2_t expand5 = load_expand5_table();
  const uint8x16x4_t expand6 = load_expand6_table();
  size_t i = 0;
  for (; i + 8 <= n; i += 8) {
    const Rgb565Lanes lanes = split_rgb565(vld1q_u16(src + i));
    const uint8x8_t r = vqtbl2_u8(expand5, lanes.r5);
    const uint8x8_t g = vqtbl4_u8(expand6, lanes.g6);
    const uint8x8_t b = vqtbl2_u8(expand5, lanes.b5);
    vst1_u8(out + i, luma_from_channels(r, g, b));
  }
  if (i < n) {
    luma_from_rgb565_span_scalar(src + i, n - i, out + i);
  }
}

void luma_from_xrgb8888_span_neon(const uint8_t* src, size_t n, uint8_t* out) {
  size_t i = 0;
  for (; i + 8 <= n; i += 8) {
    // Deinterleave [x, r, g, b] bytes: val[1..3] = r, g, b planes.
    const uint8x8x4_t px = vld4_u8(src + i * 4u);
    vst1_u8(out + i, luma_from_channels(px.val[1], px.val[2], px.val[3]));
  }
  if (i < n) {
    luma_from_xrgb8888_span_scalar(src + i * 4u, n - i, out + i);
  }
}

void chroma_mag_from_rgb565_span_neon(const uint16_t* src, size_t n,
                                      uint8_t* out) {
  size_t i = 0;
  for (; i + 8 <= n; i += 8) {
    const Rgb565Lanes lanes = split_rgb565(vld1q_u16(src + i));
    // Plain-shift expansion, matching rgb565_has_chroma.
    const uint8x8_t r = vshl_n_u8(lanes.r5, 3);
    const uint8x8_t g = vshl_n_u8(lanes.g6, 2);
    const uint8x8_t b = vshl_n_u8(lanes.b5, 3);
    vst1_u8(out + i, max_pairwise_delta(r, g, b));
  }
  if (i < n) {
    chroma_mag_from_rgb565_span_scalar(src + i, n - i, out + i);
  }
}

void chroma_mag_from_xrgb8888_span_neon(const uint8_t* src, size_t n,
                                        uint8_t* out) {
  size_t i = 0;
  for (; i + 8 <= n; i += 8) {
    const uint8x8x4_t px = vld4_u8(src + i * 4u);
    vst1_u8(out + i, max_pairwise_delta(px.val[1], px.val[2], px.val[3]));
  }
  if (i < n) {
    chroma_mag_from_xrgb8888_span_scalar(src + i * 4u, n - i, out + i);
  }
}

void quantize16_span_neon(const uint8_t* luma, const uint8_t* thresholds,
                          size_t n, uint8_t* out_lvl5) {
  size_t i = 0;
  for (; i + 8 <= n; i += 8) {
    const uint16x8_t scaled = vmull_u8(vld1_u8(luma + i), vdup_n_u8(15));
    // Exact floor(scaled / 255) for scaled <= 3825:
    // (scaled + 1 + (scaled >> 8)) >> 8.
    const uint16x8_t biased = vaddq_u16(
        vaddq_u16(scaled, vshrq_n_u16(scaled, 8)), vdupq_n_u16(1));
    uint16x8_t level = vshrq_n_u16(biased, 8);
    const uint16x8_t rem = vmlsq_u16(scaled, level, vdupq_n_u16(255));
    const uint16x8_t thr = vmovl_u8(vld1_u8(thresholds + i));
    // (rem > thr && level < 15) lanes are 0xffff == -1; subtracting adds 1.
    const uint16x8_t bump =
        vandq_u16(vcgtq_u16(rem, thr), vcltq_u16(level, vdupq_n_u16(15)));
    level = vsubq_u16(level, bump);
    vst1_u8(out_lvl5 + i, vmovn_u16(vshlq_n_u16(level, 1)));
  }
  if (i < n) {
    quantize16_span_scalar(luma + i, thresholds + i, n - i, out_lvl5 + i);
  }
}

SpanDiff diff_span_neon(const uint8_t* a, const uint8_t* b, size_t n) {
  SpanDiff out;
  uint32_t changed = 0;
  size_t i = 0;
  for (; i + 16 <= n; i += 16) {
    const uint8x16_t neq =
        vmvnq_u8(vceqq_u8(vld1q_u8(a + i), vld1q_u8(b + i)));
    changed += vaddvq_u8(vandq_u8(neq, vdupq_n_u8(1)));
  }
  for (; i < n; ++i) {
    changed += (a[i] != b[i]) ? 1u : 0u;
  }
  out.changed = changed;
  if (changed != 0) {
    // Bounded scalar scans from both ends; the vector pass established that
    // at least one change exists.
    size_t first = 0;
    while (a[first] == b[first]) {
      ++first;
    }
    size_t last = n - 1;
    while (a[last] == b[last]) {
      --last;
    }
    out.first = static_cast<int32_t>(first);
    out.last = static_cast<int32_t>(last);
  }
  return out;
}

SpanSignificance significance_span_neon(const uint8_t* luma,
                                        const uint8_t* old_lvl5, size_t n) {
  const uint8x16x2_t dequant = load_dequant_table();
  uint32x4_t sad4 = vdupq_n_u32(0);
  uint8x16_t maxv = vdupq_n_u8(0);
  size_t i = 0;
  const size_t vec_end = n & ~static_cast<size_t>(15);
  while (i < vec_end) {
    // u16 lanes gain at most 510 per 16-byte block; flushing to u32 every 64
    // blocks keeps them far from the 65535 lane cap.
    const size_t block_end =
        std::min(vec_end, i + static_cast<size_t>(16 * 64));
    uint16x8_t acc16 = vdupq_n_u16(0);
    for (; i < block_end; i += 16) {
      // Clamp so sentinel/out-of-range levels dequantize as white (index 31).
      const uint8x16_t old =
          vminq_u8(vld1q_u8(old_lvl5 + i), vdupq_n_u8(31));
      const uint8x16_t gray = vqtbl2q_u8(dequant, old);
      const uint8x16_t ad = vabdq_u8(vld1q_u8(luma + i), gray);
      maxv = vmaxq_u8(maxv, ad);
      acc16 = vpadalq_u8(acc16, ad);
    }
    sad4 = vpadalq_u16(sad4, acc16);
  }
  SpanSignificance out;
  out.sad = vaddvq_u32(sad4);
  out.max_diff = vmaxvq_u8(maxv);
  for (; i < n; ++i) {
    const int gray = level5_to_gray8(old_lvl5[i]);
    const int diff = std::abs(static_cast<int>(luma[i]) - gray);
    out.sad += static_cast<uint32_t>(diff);
    out.max_diff = std::max(out.max_diff, static_cast<uint8_t>(diff));
  }
  return out;
}

uint32_t count_above_span_neon(const uint8_t* vals, uint8_t floor, size_t n) {
  uint32_t count = 0;
  size_t i = 0;
  for (; i + 16 <= n; i += 16) {
    const uint8x16_t above = vcgtq_u8(vld1q_u8(vals + i), vdupq_n_u8(floor));
    count += vaddvq_u8(vandq_u8(above, vdupq_n_u8(1)));
  }
  for (; i < n; ++i) {
    count += (vals[i] > floor) ? 1u : 0u;
  }
  return count;
}

void levels_to_gray8_span_neon(const uint8_t* lvl5, size_t n, uint8_t* out) {
  const uint8x16x2_t dequant = load_dequant_table();
  size_t i = 0;
  for (; i + 16 <= n; i += 16) {
    const uint8x16_t idx = vminq_u8(vld1q_u8(lvl5 + i), vdupq_n_u8(31));
    vst1q_u8(out + i, vqtbl2q_u8(dequant, idx));
  }
  if (i < n) {
    levels_to_gray8_span_scalar(lvl5 + i, n - i, out + i);
  }
}

void levels_to_rgb565_span_neon(const uint8_t* lvl5, size_t n, uint16_t* out) {
  const uint8x16x2_t dequant = load_dequant_table();
  size_t i = 0;
  for (; i + 8 <= n; i += 8) {
    const uint8x8_t idx = vmin_u8(vld1_u8(lvl5 + i), vdup_n_u8(31));
    const uint8x8_t gray8 = vqtbl2_u8(dequant, idx);
    const uint16x8_t gray = vmovl_u8(gray8);
    // rgb888_to_rgb565(g, g, g): ((g>>3)<<11) | ((g>>2)<<5) | (g>>3).
    const uint16x8_t r5 = vshrq_n_u16(gray, 3);
    const uint16x8_t g6 = vshrq_n_u16(gray, 2);
    const uint16x8_t packed = vorrq_u16(
        vorrq_u16(vshlq_n_u16(r5, 11), vshlq_n_u16(g6, 5)), r5);
    vst1q_u16(out + i, packed);
  }
  if (i < n) {
    levels_to_rgb565_span_scalar(lvl5 + i, n - i, out + i);
  }
}

}  // namespace pluto

#else  // !(__ARM_NEON && __aarch64__)

// Non-NEON build: the dispatchers in kernels.h resolve to the scalar
// references; this translation unit intentionally contributes nothing.
namespace pluto {}

#endif  // __ARM_NEON && __aarch64__
