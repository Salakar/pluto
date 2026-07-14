#include "renderer/convert.h"

#include <array>
#include <cstdint>

#include "renderer/bluenoise_64.h"
#include "renderer/kernels.h"
#include "renderer/quantize.h"
#include "renderer/rect_utils.h"

#if defined(__ARM_NEON) && defined(__aarch64__)
#include <arm_neon.h>
#endif

namespace pluto {
namespace {

constexpr uint8_t k_bayer4[16] = {
    0,  8,  2, 10,
    12, 4, 14, 6,
    3, 11, 1,  9,
    15, 7, 13, 5,
};

uint8_t bayer4_at(int32_t x, int32_t y) {
  return static_cast<uint8_t>(k_bayer4[(y & 3) * 4 + (x & 3)] * 16 + 8);
}

// --- Quantize mode / threshold source ------------------------------------
// The whole per-pixel decision tree in convert_luma_pixel_gray() +
// threshold_for() is loop-invariant, so it is resolved once per rect. These
// two enums capture the exact same branch outcomes; the NEON path below and
// the scalar reference share them.
#if defined(__ARM_NEON) && defined(__aarch64__)

enum class QMode { kMono, kGray4, kGray16 };
enum class ThrKind { kConst127, kBayer, kBlueNoise };

struct ConvertPlan {
  QMode qmode;
  ThrKind tkind;
};

ConvertPlan plan_for(const ConvertConfig& config) {
  if (config.refresh_class == kPlutoRefreshFast) {
    if (config.force_mono_fast || config.keep_antialias_for_fast ||
        config.kernel == DitherKernel::kNone) {
      return {QMode::kMono, ThrKind::kConst127};
    }
    return {QMode::kGray4, ThrKind::kBayer};
  }
  switch (config.kernel) {
    case DitherKernel::kNone:
      return {QMode::kGray16, ThrKind::kConst127};
    case DitherKernel::kBayer4:
      return {QMode::kGray16, ThrKind::kBayer};
    case DitherKernel::kBlueNoise64:
    case DitherKernel::kFloydSteinberg:
      return {QMode::kGray16, ThrKind::kBlueNoise};
  }
  return {QMode::kGray16, ThrKind::kBlueNoise};
}

// Column-doubled blue-noise threshold BIAS: row q holds, twice over, the
// per-column quantizer bias w = 254 - min(mask, 254) for mask row q (see
// quantize_levels*_w below), pre-widened to u16. Doubling the columns makes
// the 8/16 biases for absolute columns [c, c+16) with c = (x0 + i) & 63
// CONSECUTIVE entries starting at column c — one unaligned L1 load per
// vector group replaces the per-row threshold-buffer fill entirely (the
// wrap (x0+i+j) & 63 for j < 16 never leaves the 128-entry doubled row:
// c <= 63, c + 15 <= 78 < 128).
constexpr std::array<std::array<uint16_t, 128>, 64> k_bn_w_doubled = [] {
  std::array<std::array<uint16_t, 128>, 64> t{};
  for (int y = 0; y < 64; ++y) {
    for (int x = 0; x < 64; ++x) {
      const int thr = k_blue_noise_64[y * 64 + x];
      t[y][x] = static_cast<uint16_t>(254 - (thr < 254 ? thr : 254));
      t[y][x + 64] = t[y][x];
    }
  }
  return t;
}();

// RGB565 -> luma8, 8 lanes, byte-exact vs rgb565_luma8 (same tables/weights as
// luma_from_rgb565_span_neon, which kernels_test pins for all 65536 inputs).
inline uint8x8_t luma8_from_rgb565(uint16x8_t v, const uint8x16x2_t& expand5,
                                   const uint8x16x4_t& expand6) {
  const uint8x8_t r5 = vmovn_u16(vshrq_n_u16(v, 11));
  const uint8x8_t g6 = vmovn_u16(vandq_u16(vshrq_n_u16(v, 5), vdupq_n_u16(0x3f)));
  const uint8x8_t b5 = vmovn_u16(vandq_u16(v, vdupq_n_u16(0x1f)));
  const uint8x8_t r = vqtbl2_u8(expand5, r5);
  const uint8x8_t g = vqtbl4_u8(expand6, g6);
  const uint8x8_t b = vqtbl2_u8(expand5, b5);
  uint16x8_t acc = vmull_u8(r, vdup_n_u8(54));
  acc = vmlal_u8(acc, g, vdup_n_u8(183));
  acc = vmlal_u8(acc, b, vdup_n_u8(19));
  acc = vaddq_u16(acc, vdupq_n_u16(128));
  return vshrn_n_u16(acc, 8);
}

// 8-lane level selection shared by gray4/gray16: the reference level pick
// PLUS its threshold bump collapse into a single biased division,
//   quantize_grayN(luma, thr) == Scale * ((x + (x >> 8) + 1) >> 8)
//   with x = luma * LevelsM1 + w,  w = 254 - min(thr, 254),
// proven byte-exact against quantize_gray4/quantize_gray16 for ALL 65536
// (luma, thr) pairs per level count (the min() clamp covers thr == 255,
// where the bump can never fire; at rem == 0 the +254-thr term cannot reach
// 255, so the never-bump-at-top guard is inherent). w arrives pre-widened:
// a dup'd 127 for const-127, a per-phase register row for Bayer (byte
// period 4 keeps it row-invariant), one unaligned load from the doubled
// mask-bias table for blue noise. LevelsM1 is 15 (gray16) or 3 (gray4);
// Scale is the output multiplier (17 / 85, both == (level*255 +
// levels_m1/2) / levels_m1), applied after narrowing (level*Scale <= 255).
template <int LevelsM1, int Scale>
inline uint8x8_t quantize_levels8_w(uint8x8_t luma, uint16x8_t w) {
  uint16x8_t x = vaddq_u16(vmull_u8(luma, vdup_n_u8(LevelsM1)), w);
  x = vaddq_u16(vsraq_n_u16(x, x, 8), vdupq_n_u16(1));
  return vmul_u8(vshrn_n_u16(x, 8), vdup_n_u8(Scale));
}

// 16-lane twins of luma8_from_rgb565 / quantize_levels8: identical per-lane
// math (the q-form table lookups and widening-multiply halves are the same
// ops), so bytes match the 8-lane forms exactly. The split uses the byte
// deinterleave: uzp2 == per-pixel (v >> 8) so uzp2 >> 3 == r5; uzp1 == (v &
// 0xff) so uzp1 & 0x1f == b5; vshrn(v, 5) & 0x3f == g6.
inline uint8x16_t luma16_from_rgb565(uint16x8_t v0, uint16x8_t v1,
                                     const uint8x16x2_t& expand5,
                                     const uint8x16x4_t& expand6) {
  const uint8x16_t hi8 =
      vuzp2q_u8(vreinterpretq_u8_u16(v0), vreinterpretq_u8_u16(v1));
  const uint8x16_t lo8 =
      vuzp1q_u8(vreinterpretq_u8_u16(v0), vreinterpretq_u8_u16(v1));
  const uint8x16_t r5q = vshrq_n_u8(hi8, 3);
  const uint8x16_t g6q =
      vandq_u8(vshrn_high_n_u16(vshrn_n_u16(v0, 5), v1, 5), vdupq_n_u8(0x3f));
  const uint8x16_t b5q = vandq_u8(lo8, vdupq_n_u8(0x1f));
  const uint8x16_t r = vqtbl2q_u8(expand5, r5q);
  const uint8x16_t g = vqtbl4q_u8(expand6, g6q);
  const uint8x16_t b = vqtbl2q_u8(expand5, b5q);
  uint16x8_t acc0 = vmull_u8(vget_low_u8(r), vdup_n_u8(54));
  acc0 = vmlal_u8(acc0, vget_low_u8(g), vdup_n_u8(183));
  acc0 = vmlal_u8(acc0, vget_low_u8(b), vdup_n_u8(19));
  acc0 = vaddq_u16(acc0, vdupq_n_u16(128));
  uint16x8_t acc1 = vmull_high_u8(r, vdupq_n_u8(54));
  acc1 = vmlal_high_u8(acc1, g, vdupq_n_u8(183));
  acc1 = vmlal_high_u8(acc1, b, vdupq_n_u8(19));
  acc1 = vaddq_u16(acc1, vdupq_n_u16(128));
  return vshrn_high_n_u16(vshrn_n_u16(acc0, 8), acc1, 8);
}

template <int LevelsM1, int Scale>
inline uint8x16_t quantize_levels16_w(uint8x16_t luma, uint16x8_t w0,
                                      uint16x8_t w1) {
  uint16x8_t x0 =
      vaddq_u16(vmull_u8(vget_low_u8(luma), vdup_n_u8(LevelsM1)), w0);
  uint16x8_t x1 = vaddq_u16(vmull_high_u8(luma, vdupq_n_u8(LevelsM1)), w1);
  x0 = vaddq_u16(vsraq_n_u16(x0, x0, 8), vdupq_n_u16(1));
  x1 = vaddq_u16(vsraq_n_u16(x1, x1, 8), vdupq_n_u16(1));
  return vmulq_u8(vshrn_high_n_u16(vshrn_n_u16(x0, 8), x1, 8),
                  vdupq_n_u8(Scale));
}

uint8_t convert_pixel(uint16_t rgb565, int32_t absolute_x, int32_t absolute_y,
                      const ConvertConfig& config);

// Whole-rect vectorised conversion, one instantiation per reachable
// (QMode, ThrKind) pair — the per-group mode switch of the old per-row
// kernel becomes compile-time, and the channel-expansion tables load once
// per rect instead of once per row. Thresholds never touch a staging
// buffer: they enter as the pre-widened quantizer bias w = 254 -
// min(thr, 254) (see quantize_levels*_w), register-resident for const-127
// and Bayer (the Bayer byte pattern has period 4, so one block IS the row,
// phase-selected by y & 3 — and the 8/16 px steps keep (x0 + i) & 3 ==
// x0 & 3), and unaligned L1 loads from the column-doubled mask-bias table
// for blue noise. The biases correspond position-for-position to the
// reference threshold_for()/bayer4_at()/blue_noise_64_at() thresholds by
// construction. Tail pixels (< 8) run the scalar reference path.
template <QMode Mode, ThrKind Kind>
void convert_rect_neon(const uint16_t* src_rgb565, size_t src_stride_bytes,
                       uint8_t* dst_gray8, size_t dst_stride_bytes,
                       const PlutoRect& clipped,
                       const ConvertConfig& config) {
  const uint8x16x2_t expand5{
      {vld1q_u8(k_expand5.data()), vld1q_u8(k_expand5.data() + 16)}};
  const uint8x16x4_t expand6{
      {vld1q_u8(k_expand6.data()), vld1q_u8(k_expand6.data() + 16),
       vld1q_u8(k_expand6.data() + 32), vld1q_u8(k_expand6.data() + 48)}};
  const int32_t x0 = clipped.x;
  const int32_t n = clipped.width;
  // Per-phase Bayer bias rows (w = 254 - thr; Bayer thresholds top out at
  // 248, so the min() clamp is vacuous). The byte pattern has period 4, so
  // lanes 8..15 repeat lanes 0..7 and the 8-px step reuses w0.
  uint16x8_t bayer_w0[4];
  uint16x8_t bayer_w1[4];
  if constexpr (Kind == ThrKind::kBayer) {
    for (int32_t p = 0; p < 4; ++p) {
      uint16_t wrow[16];
      for (int32_t m = 0; m < 16; ++m) {
        wrow[m] = static_cast<uint16_t>(
            254 - (k_bayer4[(p & 3) * 4 + ((x0 + m) & 3)] * 16 + 8));
      }
      bayer_w0[p] = vld1q_u16(wrow);
      bayer_w1[p] = vld1q_u16(wrow + 8);
    }
  }
  for (int32_t y = 0; y < clipped.height; ++y) {
    const int32_t absolute_y = clipped.y + y;
    const auto* src_row =
        reinterpret_cast<const uint16_t*>(
            reinterpret_cast<const uint8_t*>(src_rgb565) +
            static_cast<size_t>(absolute_y) * src_stride_bytes) +
        x0;
    uint8_t* dst_row = dst_gray8 + static_cast<size_t>(y) * dst_stride_bytes;
    uint16x8_t w0 = vdupq_n_u16(254 - 127);
    uint16x8_t w1 = w0;
    const uint16_t* bnw_row = nullptr;
    if constexpr (Kind == ThrKind::kBayer) {
      w0 = bayer_w0[absolute_y & 3];
      w1 = bayer_w1[absolute_y & 3];
    } else if constexpr (Kind == ThrKind::kBlueNoise) {
      bnw_row = k_bn_w_doubled[absolute_y & 63].data();
    }
    int32_t i = 0;
    for (; i + 16 <= n; i += 16) {
      const uint8x16_t luma = luma16_from_rgb565(
          vld1q_u16(src_row + i), vld1q_u16(src_row + i + 8), expand5,
          expand6);
      uint8x16_t out;
      if constexpr (Mode == QMode::kMono) {
        out = vcgtq_u8(luma, vdupq_n_u8(127));  // 255 / 0
      } else {
        if constexpr (Kind == ThrKind::kBlueNoise) {
          const uint32_t c =
              (static_cast<uint32_t>(x0) + static_cast<uint32_t>(i)) & 63u;
          w0 = vld1q_u16(bnw_row + c);
          w1 = vld1q_u16(bnw_row + c + 8);
        }
        out = Mode == QMode::kGray4 ? quantize_levels16_w<3, 85>(luma, w0, w1)
                                    : quantize_levels16_w<15, 17>(luma, w0, w1);
      }
      vst1q_u8(dst_row + i, out);
    }
    for (; i + 8 <= n; i += 8) {
      const uint8x8_t luma =
          luma8_from_rgb565(vld1q_u16(src_row + i), expand5, expand6);
      uint8x8_t out;
      if constexpr (Mode == QMode::kMono) {
        out = vcgt_u8(luma, vdup_n_u8(127));  // 255 / 0
      } else {
        if constexpr (Kind == ThrKind::kBlueNoise) {
          const uint32_t c =
              (static_cast<uint32_t>(x0) + static_cast<uint32_t>(i)) & 63u;
          w0 = vld1q_u16(bnw_row + c);
        }
        out = Mode == QMode::kGray4 ? quantize_levels8_w<3, 85>(luma, w0)
                                    : quantize_levels8_w<15, 17>(luma, w0);
      }
      vst1_u8(dst_row + i, out);
    }
    // Scalar tail (< 8 px) through the reference path — bit-exact by
    // construction and never on the hot span for full-width rects.
    for (; i < n; ++i) {
      dst_row[i] = convert_pixel(src_row[i], x0 + i, absolute_y, config);
    }
  }
}

#endif  // __ARM_NEON && __aarch64__

uint8_t threshold_for(const ConvertConfig& config, int32_t x, int32_t y) {
  switch (config.kernel) {
    case DitherKernel::kNone:
      return 127;
    case DitherKernel::kBayer4:
      return bayer4_at(x, y);
    case DitherKernel::kBlueNoise64:
    case DitherKernel::kFloydSteinberg:
      return blue_noise_64_at(x, y);
  }
  return 127;
}

uint8_t convert_pixel(uint16_t rgb565,
                      int32_t absolute_x,
                      int32_t absolute_y,
                      const ConvertConfig& config) {
  return convert_luma_pixel_gray(rgb565_luma8(rgb565), absolute_x, absolute_y,
                                 config);
}

}  // namespace

uint8_t convert_luma_pixel_gray(uint8_t luma,
                                int32_t absolute_x,
                                int32_t absolute_y,
                                const ConvertConfig& config) {
  if (config.refresh_class == kPlutoRefreshFast) {
    if (config.force_mono_fast || config.keep_antialias_for_fast ||
        config.kernel == DitherKernel::kNone) {
      return quantize_mono(luma, 127);
    }
    return quantize_gray4(luma, bayer4_at(absolute_x, absolute_y));
  }
  return quantize_gray16(luma, threshold_for(config, absolute_x, absolute_y));
}

void convert_rgb565_to_gray8_rect(const uint16_t* src_rgb565,
                                  size_t src_stride_bytes,
                                  uint8_t* dst_gray8,
                                  size_t dst_stride_bytes,
                                  const PlutoRect& rect,
                                  const ConvertConfig& config) {
  if (src_rgb565 == nullptr || dst_gray8 == nullptr || rect_is_empty(rect)) {
    return;
  }
  const PlutoRect clipped = rect_clip(
      rect, static_cast<int32_t>(config.width), static_cast<int32_t>(config.height));
  if (rect_is_empty(clipped)) {
    return;
  }
  if (config.kernel == DitherKernel::kFloydSteinberg &&
      clipped.x == 0 && clipped.y == 0 &&
      clipped.width == static_cast<int32_t>(config.width) &&
      clipped.height == static_cast<int32_t>(config.height) &&
      config.refresh_class == kPlutoRefreshFull) {
    convert_rgb565_to_gray8_full_error_diffusion(
        src_rgb565, src_stride_bytes, dst_gray8, dst_stride_bytes, config.width,
        config.height);
    return;
  }

#if defined(__ARM_NEON) && defined(__aarch64__)
  // Compile-time dispatch over the reachable (QMode, ThrKind) pairs: mono
  // ignores thresholds (fixed 127 inside quantize_mono) and plan_for only
  // ever pairs gray4 with Bayer.
  const ConvertPlan plan = plan_for(config);
  if (plan.qmode == QMode::kMono) {
    convert_rect_neon<QMode::kMono, ThrKind::kConst127>(
        src_rgb565, src_stride_bytes, dst_gray8, dst_stride_bytes, clipped,
        config);
  } else if (plan.qmode == QMode::kGray4) {
    convert_rect_neon<QMode::kGray4, ThrKind::kBayer>(
        src_rgb565, src_stride_bytes, dst_gray8, dst_stride_bytes, clipped,
        config);
  } else if (plan.tkind == ThrKind::kConst127) {
    convert_rect_neon<QMode::kGray16, ThrKind::kConst127>(
        src_rgb565, src_stride_bytes, dst_gray8, dst_stride_bytes, clipped,
        config);
  } else if (plan.tkind == ThrKind::kBayer) {
    convert_rect_neon<QMode::kGray16, ThrKind::kBayer>(
        src_rgb565, src_stride_bytes, dst_gray8, dst_stride_bytes, clipped,
        config);
  } else {
    convert_rect_neon<QMode::kGray16, ThrKind::kBlueNoise>(
        src_rgb565, src_stride_bytes, dst_gray8, dst_stride_bytes, clipped,
        config);
  }
#else
  for (int32_t y = 0; y < clipped.height; ++y) {
    const int32_t absolute_y = clipped.y + y;
    const auto* src_row = reinterpret_cast<const uint16_t*>(
        reinterpret_cast<const uint8_t*>(src_rgb565) +
        static_cast<size_t>(absolute_y) * src_stride_bytes);
    uint8_t* dst_row = dst_gray8 + static_cast<size_t>(y) * dst_stride_bytes;
    for (int32_t x = 0; x < clipped.width; ++x) {
      const int32_t absolute_x = clipped.x + x;
      dst_row[x] =
          convert_pixel(src_row[absolute_x], absolute_x, absolute_y, config);
    }
  }
#endif
}

void convert_rgb565_to_gray8_full_error_diffusion(const uint16_t* src_rgb565,
                                                  size_t src_stride_bytes,
                                                  uint8_t* dst_gray8,
                                                  size_t dst_stride_bytes,
                                                  uint32_t width,
                                                  uint32_t height) {
  // Byte-identical fast kernel (renderer/quantize.cc): per pixel, raster
  // order, old = clamp(rgb565_luma8(src) + err / 16, 0, 255) quantized by
  // quantize_gray16(old, 127), error scattered 7/16 right, 3/16 below-left,
  // 5/16 below, 1/16 below-right.
  error_diffuse_rgb565_gray16_full(src_rgb565, src_stride_bytes, dst_gray8,
                                   dst_stride_bytes, width, height);
}

void convert_rgb888_to_rgb565_rect(const uint8_t* src_rgb,
                                   size_t src_stride_bytes,
                                   uint16_t* dst_rgb565,
                                   size_t dst_stride_bytes,
                                   const PlutoRect& rect) {
  if (src_rgb == nullptr || dst_rgb565 == nullptr || rect_is_empty(rect)) {
    return;
  }
  for (int32_t y = 0; y < rect.height; ++y) {
    const uint8_t* src_row =
        src_rgb + static_cast<size_t>(rect.y + y) * src_stride_bytes +
        static_cast<size_t>(rect.x) * 3u;
    auto* dst_row = reinterpret_cast<uint16_t*>(
        reinterpret_cast<uint8_t*>(dst_rgb565) +
        static_cast<size_t>(rect.y + y) * dst_stride_bytes);
    for (int32_t x = 0; x < rect.width; ++x) {
      dst_row[rect.x + x] =
          rgb888_to_rgb565(src_row[x * 3 + 0], src_row[x * 3 + 1],
                           src_row[x * 3 + 2]);
    }
  }
}

}  // namespace pluto
