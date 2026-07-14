#ifndef PLUTO_RENDERER_KERNELS_H_
#define PLUTO_RENDERER_KERNELS_H_

#include <array>
#include <cstddef>
#include <cstdint>

// Span kernels for the fused tile pass.
//
// Contracts:
//   * The *_scalar functions are the bit-exact references. Their math is
//     inherited verbatim from the proven reference kernels (renderer/
//     quantize.cc, renderer/convert.cc, renderer/bluenoise_64.h) so the tile
//     pass produces the same quantized bytes those kernels would for the
//     same inputs.
//   * NEON (*_neon) variants exist for the hot kernels on aarch64 and are
//     golden-tested against the scalar references over random and structured
//     spans (test/renderer/kernels_test.cc). They must be byte-exact.
//   * The unsuffixed names dispatch to the fastest available implementation.
//   * Every kernel is a pure function of its inputs (plus absolute panel
//     coordinates where noted) — this is what makes the tile pass rect-local
//     deterministic: converting any rect is byte-identical to converting the
//     whole frame and cropping, so partial updates can never seam.

namespace pluto {

#if defined(__ARM_NEON) && defined(__aarch64__)
inline constexpr bool kNeonKernels = true;
#else
inline constexpr bool kNeonKernels = false;
#endif

// ---------------------------------------------------------------------------
// Level space
// ---------------------------------------------------------------------------
// L_cur and all quantizer outputs live in 5-bit level space (0..31), matching
// the engine planes. The 16-level blue-noise quantizer emits the even levels
// {0, 2, ..., 30}; 30 (0x1e) is paper white — the same byte the engine's prev
// plane holds after a cold clear.
inline constexpr uint8_t kWhiteLevel5 = 30;
// Sentinel for "no settled content". Never produced by any quantizer, so a
// freshly invalidated plane byte-diffs dirty against every real level.
inline constexpr uint8_t kInvalidLevel5 = 0xff;

// RGB565 channel expansion with rounding — identical to rgb565_luma8()
// (renderer/quantize.cc:34-36): c8 = (c * 255 + max/2) / max.
inline constexpr std::array<uint8_t, 32> k_expand5 = [] {
  std::array<uint8_t, 32> table{};
  for (uint32_t i = 0; i < 32; ++i) {
    table[i] = static_cast<uint8_t>((i * 255u + 15u) / 31u);
  }
  return table;
}();
inline constexpr std::array<uint8_t, 64> k_expand6 = [] {
  std::array<uint8_t, 64> table{};
  for (uint32_t i = 0; i < 64; ++i) {
    table[i] = static_cast<uint8_t>((i * 255u + 31u) / 63u);
  }
  return table;
}();

// 5-bit level -> 8-bit gray, rounding, clamped. For the even levels the
// 16-level quantizer emits this is exactly the legacy quantize_gray16 output
// byte: level5_to_gray8(2 * i) == 17 * i. Index 31 clamps to 255 so the
// kInvalidLevel5 sentinel dequantizes as paper white.
inline constexpr std::array<uint8_t, 32> k_level5_to_gray8 = [] {
  std::array<uint8_t, 32> table{};
  for (uint32_t i = 0; i < 32; ++i) {
    const uint32_t gray = (i * 255u + 15u) / 30u;
    table[i] = static_cast<uint8_t>(gray > 255u ? 255u : gray);
  }
  return table;
}();

inline uint8_t level5_to_gray8(uint8_t lvl5) {
  return k_level5_to_gray8[lvl5 < 31u ? lvl5 : 31u];
}

// ---------------------------------------------------------------------------
// Result structs
// ---------------------------------------------------------------------------

struct SpanDiff {
  uint32_t changed = 0;  // bytes where a != b
  int32_t first = -1;    // span-relative index of the first change (-1: none)
  int32_t last = -1;     // span-relative index of the last change
};

struct SpanSignificance {
  // Pre-dither significance (feeds TileStats): computed on the
  // continuous-tone luma vs the dequantized old level, so it survives even
  // when ordered dithering makes the post-quantize diff noisy.
  uint32_t sad = 0;      // sum |luma - level5_to_gray8(old)|
  uint8_t max_diff = 0;  // max |luma - level5_to_gray8(old)|
};

// ---------------------------------------------------------------------------
// Scalar references (always available; the bit-exactness contract)
// ---------------------------------------------------------------------------

// RGB565 -> luma. Calls the legacy rgb565_luma8() per pixel (verbatim math:
// rounded channel expansion + integer BT.601 (54,183,19)/256 + 128 bias).
void luma_from_rgb565_span_scalar(const uint16_t* src, size_t n, uint8_t* out);

// XRGB8888 (memory bytes [x, r, g, b] — the host_preview.cc layout) -> luma
// with the same BT.601 weights applied to the raw 8-bit channels.
void luma_from_xrgb8888_span_scalar(const uint8_t* src, size_t n, uint8_t* out);

// Chroma magnitude = max pairwise channel delta. RGB565 channels are expanded
// with plain shifts (<<3 / <<2) — identical to rgb565_has_chroma()
// (renderer/quantize.cc:40-49), so (mag > 12) == rgb565_has_chroma().
void chroma_mag_from_rgb565_span_scalar(const uint16_t* src, size_t n,
                                        uint8_t* out);
void chroma_mag_from_xrgb8888_span_scalar(const uint8_t* src, size_t n,
                                          uint8_t* out);

// Position-keyed 64x64 blue-noise thresholds (renderer/bluenoise_64.h),
// toroidal wrap: out[i] = blue_noise_64_at(x0 + i, y).
void fill_bluenoise_thresholds(int32_t x0, int32_t y, size_t n, uint8_t* out);

// Zero-copy variant: returns a pointer directly into the mask row when
// [x0, x0+n) does not wrap the 64-px mask period (always true for 32-px tile
// spans), otherwise fills `scratch` (>= n bytes) and returns it. x0, y >= 0.
const uint8_t* bluenoise_threshold_span(int32_t x0, int32_t y, size_t n,
                                        uint8_t* scratch);

// 16-level quantize + ordered dither -> 5-bit levels {0, 2, ..., 30}. The
// level-selection math is verbatim quantize_gray16() (renderer/quantize.cc:
// 63-72); only the output byte differs (level index * 2 instead of * 17).
void quantize16_span_scalar(const uint8_t* luma, const uint8_t* thresholds,
                            size_t n, uint8_t* out_lvl5);

// Post-quantize byte diff: changed count + span-relative first/last change.
SpanDiff diff_span_scalar(const uint8_t* a, const uint8_t* b, size_t n);

// Pre-dither significance vs the old level plane. Sentinel / out-of-range
// old bytes dequantize as white (255).
SpanSignificance significance_span_scalar(const uint8_t* luma,
                                          const uint8_t* old_lvl5, size_t n);

// 16-bucket level presence bits: bit i set when level (2 * i) appears.
// Inputs must be valid 5-bit levels (0..31).
uint16_t level_hist_bits_span_scalar(const uint8_t* lvl5, size_t n);

// Count of values strictly above `floor` (chroma-fraction numerator).
uint32_t count_above_span_scalar(const uint8_t* vals, uint8_t floor, size_t n);

// 5-bit levels -> gray8 / gray RGB565 expansion (the transitional bridge to
// presenters that still consume raster surfaces; deleted Stage 8).
void levels_to_gray8_span_scalar(const uint8_t* lvl5, size_t n, uint8_t* out);
void levels_to_rgb565_span_scalar(const uint8_t* lvl5, size_t n, uint16_t* out);

// Row hash for the scroll detector: 32-bit FNV-1a over the row's quantized
// level bytes.
// Choice rationale: the Stage-6 scroll detector majority-votes on whole-row
// hash equality across frames — no sliding window is ever taken, so a
// byte-serial chained hash suffices; FNV-1a is 2 ops/byte, order-sensitive,
// and chainable across spans by seeding with the previous state (pass the
// prior return value as `seed`). Not vectorized: it runs only over rows whose
// quantized bytes actually changed.
inline constexpr uint32_t kFnv1aSeed = 0x811c9dc5u;
uint32_t hash_row_fnv1a(const uint8_t* bytes, size_t n,
                        uint32_t seed = kFnv1aSeed);

// Batched row hash: hashes 8 independent rows (rows[0..7], each n bytes) in
// one interleaved pass. Each output is byte-for-byte identical to
// hash_row_fnv1a(rows[k], n) — the eight chains are the same FNV-1a, merely
// stepped together so the serial multiply-latency chain of one row is hidden
// behind the other seven (measured ~7x over the row-serial loop). Used to
// re-hash the dirty rows the scroll detector consumes, so the values it votes
// on are unchanged. Rows may alias arbitrary (non-contiguous) plane rows.
void hash_rows_fnv1a_x8(const uint8_t* const* rows, size_t n, uint32_t* out8);

// ---------------------------------------------------------------------------
// NEON implementations (aarch64; byte-exact vs the scalar references)
// ---------------------------------------------------------------------------

#if defined(__ARM_NEON) && defined(__aarch64__)
void luma_from_rgb565_span_neon(const uint16_t* src, size_t n, uint8_t* out);
void luma_from_xrgb8888_span_neon(const uint8_t* src, size_t n, uint8_t* out);
void chroma_mag_from_rgb565_span_neon(const uint16_t* src, size_t n,
                                      uint8_t* out);
void chroma_mag_from_xrgb8888_span_neon(const uint8_t* src, size_t n,
                                        uint8_t* out);
void quantize16_span_neon(const uint8_t* luma, const uint8_t* thresholds,
                          size_t n, uint8_t* out_lvl5);
SpanDiff diff_span_neon(const uint8_t* a, const uint8_t* b, size_t n);
SpanSignificance significance_span_neon(const uint8_t* luma,
                                        const uint8_t* old_lvl5, size_t n);
uint32_t count_above_span_neon(const uint8_t* vals, uint8_t floor, size_t n);
void levels_to_gray8_span_neon(const uint8_t* lvl5, size_t n, uint8_t* out);
void levels_to_rgb565_span_neon(const uint8_t* lvl5, size_t n, uint16_t* out);
#endif  // __ARM_NEON && __aarch64__

// ---------------------------------------------------------------------------
// Dispatchers (fastest available implementation)
// ---------------------------------------------------------------------------

inline void luma_from_rgb565_span(const uint16_t* src, size_t n, uint8_t* out) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  luma_from_rgb565_span_neon(src, n, out);
#else
  luma_from_rgb565_span_scalar(src, n, out);
#endif
}

inline void luma_from_xrgb8888_span(const uint8_t* src, size_t n,
                                    uint8_t* out) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  luma_from_xrgb8888_span_neon(src, n, out);
#else
  luma_from_xrgb8888_span_scalar(src, n, out);
#endif
}

inline void chroma_mag_from_rgb565_span(const uint16_t* src, size_t n,
                                        uint8_t* out) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  chroma_mag_from_rgb565_span_neon(src, n, out);
#else
  chroma_mag_from_rgb565_span_scalar(src, n, out);
#endif
}

inline void chroma_mag_from_xrgb8888_span(const uint8_t* src, size_t n,
                                          uint8_t* out) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  chroma_mag_from_xrgb8888_span_neon(src, n, out);
#else
  chroma_mag_from_xrgb8888_span_scalar(src, n, out);
#endif
}

inline void quantize16_span(const uint8_t* luma, const uint8_t* thresholds,
                            size_t n, uint8_t* out_lvl5) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  quantize16_span_neon(luma, thresholds, n, out_lvl5);
#else
  quantize16_span_scalar(luma, thresholds, n, out_lvl5);
#endif
}

inline SpanDiff diff_span(const uint8_t* a, const uint8_t* b, size_t n) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  return diff_span_neon(a, b, n);
#else
  return diff_span_scalar(a, b, n);
#endif
}

inline SpanSignificance significance_span(const uint8_t* luma,
                                          const uint8_t* old_lvl5, size_t n) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  return significance_span_neon(luma, old_lvl5, n);
#else
  return significance_span_scalar(luma, old_lvl5, n);
#endif
}

// Presence-bit histogram stays scalar: 32-96 bytes per tile row, and the
// vector variable-shift formulation measured no better at these span lengths.
inline uint16_t level_hist_bits_span(const uint8_t* lvl5, size_t n) {
  return level_hist_bits_span_scalar(lvl5, n);
}

inline uint32_t count_above_span(const uint8_t* vals, uint8_t floor,
                                 size_t n) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  return count_above_span_neon(vals, floor, n);
#else
  return count_above_span_scalar(vals, floor, n);
#endif
}

inline void levels_to_gray8_span(const uint8_t* lvl5, size_t n, uint8_t* out) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  levels_to_gray8_span_neon(lvl5, n, out);
#else
  levels_to_gray8_span_scalar(lvl5, n, out);
#endif
}

inline void levels_to_rgb565_span(const uint8_t* lvl5, size_t n,
                                  uint16_t* out) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  levels_to_rgb565_span_neon(lvl5, n, out);
#else
  levels_to_rgb565_span_scalar(lvl5, n, out);
#endif
}

}  // namespace pluto

#endif  // PLUTO_RENDERER_KERNELS_H_
