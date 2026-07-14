#include "renderer/tile_pass.h"

#include <algorithm>
#include <cstring>

#include "renderer/bluenoise_64.h"
#include "renderer/kernels.h"
#include "renderer/rect_utils.h"

#if defined(__ARM_NEON) && defined(__aarch64__)
#include <arm_neon.h>
#endif

namespace pluto {
namespace {

size_t format_bytes_per_pixel(PlutoPixelFormat format) {
  switch (format) {
    case kPlutoPixelFormatRgb565:
      return 2;
    case kPlutoPixelFormatGray8:
      return 1;
    case kPlutoPixelFormatXrgb8888:
      return 4;
  }
  return 0;
}

bool format_supported(PlutoPixelFormat format) {
  return format_bytes_per_pixel(format) != 0;
}

void luma_span_for_format(PlutoPixelFormat format, const uint8_t* src,
                          size_t n, uint8_t* out) {
  switch (format) {
    case kPlutoPixelFormatRgb565:
      luma_from_rgb565_span(reinterpret_cast<const uint16_t*>(src), n, out);
      return;
    case kPlutoPixelFormatGray8:
      std::memcpy(out, src, n);
      return;
    case kPlutoPixelFormatXrgb8888:
      luma_from_xrgb8888_span(src, n, out);
      return;
  }
}

void chroma_span_for_format(PlutoPixelFormat format, const uint8_t* src,
                            size_t n, uint8_t* out) {
  switch (format) {
    case kPlutoPixelFormatRgb565:
      chroma_mag_from_rgb565_span(reinterpret_cast<const uint16_t*>(src), n,
                                  out);
      return;
    case kPlutoPixelFormatGray8:
      std::memset(out, 0, n);
      return;
    case kPlutoPixelFormatXrgb8888:
      chroma_mag_from_xrgb8888_span(src, n, out);
      return;
  }
}

// Fused RGB565 -> (luma, chroma-magnitude) for one tile-row span. The device
// format feeds both the luma-quantize/significance chain and the chroma
// bitplane; splitting the packed pixel once and driving both expansions from
// the shared r5/g6/b5 lanes halves the load/split traffic vs the two separate
// span kernels. Output bytes are identical to
// luma_from_rgb565_span + chroma_mag_from_rgb565_span (same tables, weights,
// and plain-shift chroma expansion), so the scalar references stay the spec.
void luma_chroma_from_rgb565(const uint16_t* src, size_t n, uint8_t* luma,
                             uint8_t* chroma) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  const uint8x16x2_t expand5{
      {vld1q_u8(k_expand5.data()), vld1q_u8(k_expand5.data() + 16)}};
  const uint8x16x4_t expand6{
      {vld1q_u8(k_expand6.data()), vld1q_u8(k_expand6.data() + 16),
       vld1q_u8(k_expand6.data() + 32), vld1q_u8(k_expand6.data() + 48)}};
  size_t i = 0;
  for (; i + 8 <= n; i += 8) {
    const uint16x8_t v = vld1q_u16(src + i);
    const uint8x8_t r5 = vmovn_u16(vshrq_n_u16(v, 11));
    const uint8x8_t g6 =
        vmovn_u16(vandq_u16(vshrq_n_u16(v, 5), vdupq_n_u16(0x3f)));
    const uint8x8_t b5 = vmovn_u16(vandq_u16(v, vdupq_n_u16(0x1f)));
    // Luma: rounded channel expansion (tables) + integer BT.601 (54,183,19)/256.
    const uint8x8_t rl = vqtbl2_u8(expand5, r5);
    const uint8x8_t gl = vqtbl4_u8(expand6, g6);
    const uint8x8_t bl = vqtbl2_u8(expand5, b5);
    uint16x8_t acc = vmull_u8(rl, vdup_n_u8(54));
    acc = vmlal_u8(acc, gl, vdup_n_u8(183));
    acc = vmlal_u8(acc, bl, vdup_n_u8(19));
    acc = vaddq_u16(acc, vdupq_n_u16(128));
    vst1_u8(luma + i, vshrn_n_u16(acc, 8));
    // Chroma: plain-shift expansion (<<3/<<2/<<3) + max pairwise |delta|.
    const uint8x8_t rc = vshl_n_u8(r5, 3);
    const uint8x8_t gc = vshl_n_u8(g6, 2);
    const uint8x8_t bc = vshl_n_u8(b5, 3);
    const uint8x8_t mag =
        vmax_u8(vmax_u8(vabd_u8(rc, gc), vabd_u8(rc, bc)), vabd_u8(gc, bc));
    vst1_u8(chroma + i, mag);
  }
  if (i < n) {
    luma_from_rgb565_span_scalar(src + i, n - i, luma + i);
    chroma_mag_from_rgb565_span_scalar(src + i, n - i, chroma + i);
  }
#else
  luma_from_rgb565_span(src, n, luma);
  chroma_mag_from_rgb565_span(src, n, chroma);
#endif
}

// Per-row result of the fused RGB565 Pass-A kernel: the post-quantize diff
// (changed count + span-relative first/last change) plus the chroma count,
// matching what the diff_span + count_above_span kernels return for the row.
// Pass-A accumulators for one dirty/candidate tile: the same quantities the
// per-kernel chain accumulates into process_tile's locals.
struct FusedTileStats {
  uint32_t changed = 0;
  uint32_t chroma_count = 0;
  bool changed_chroma = false;
  int32_t min_x = 0;
  int32_t max_x = 0;
  int32_t min_y = 0;
  int32_t max_y = 0;
};

#if defined(__ARM_NEON) && defined(__aarch64__)
// Per-row Pass-A -> Pass-B contract for the RGB565 NEON path. Rows Pass A
// proved BOTH uniform-level AND clean (quantized row is a single byte and it
// equals the OLD plane row everywhere) skip the lvl_tile store entirely;
// Pass B folds them to O(1): old[x] == lvl and luma[x] == luma for all x, so
//   sad_row      == w * |luma - level5_to_gray8(lvl)|
//   max_diff_row == |luma - level5_to_gray8(lvl)|
//   hist_row     == 1 << (lvl >> 1)
// are exact closed forms of the per-pixel sums, and the write-through is a
// no-op (the row is clean). All other rows keep kind 0 (lvl_tile stored).
struct RowMeta {
  uint8_t uniform_clean = 0;  // 1: lvl_tile row not stored; see above
  uint8_t lvl = 0;            // uniform quantized level byte (kind 1 only)
  uint8_t luma = 0;           // uniform luma byte (kind 1 only)
};

// u16-widened copy of the blue-noise mask (identical values), so the quantize
// loop loads its 8-lane threshold vector with one vld1q_u16 instead of
// vld1_u8 + vmovl_u8.
constexpr std::array<uint16_t, 4096> k_blue_noise_64_u16 = [] {
  std::array<uint16_t, 4096> t{};
  for (size_t i = 0; i < t.size(); ++i) {
    t[i] = k_blue_noise_64[i];
  }
  return t;
}();

// u16 twin of bluenoise_threshold_span (same indexing/wrap semantics):
// returns a pointer into the widened mask row when [x0, x0+n) does not wrap
// the 64-px period, otherwise fills `scratch`.
const uint16_t* bluenoise_threshold_span_u16(int32_t x0, int32_t y, size_t n,
                                             uint16_t* scratch) {
  const uint32_t row = (static_cast<uint32_t>(y) & 63u) * 64u;
  const uint32_t col = static_cast<uint32_t>(x0) & 63u;
  if (col + n <= 64u) {
    return &k_blue_noise_64_u16[row + col];
  }
  for (size_t i = 0; i < n; ++i) {
    scratch[i] = k_blue_noise_64_u16
        [row + ((col + static_cast<uint32_t>(i)) & 63u)];
  }
  return scratch;
}

// One-entry scalar cache for the uniform-row fast path, keyed by the packed
// pixel value; flat regions repeat the same value for many consecutive rows.
// All cached quantities use the frozen scalar reference math (proof notes at
// uniform_run32_rgb565).
struct UniformRowCache {
  uint32_t px = 0x10000u;  // sentinel: no u16 pixel matches
  uint8_t luma = 0;
  uint8_t lvl = 0;     // 2 * level (base, pre-bump)
  uint8_t rem = 0;     // scaled - level * 255 (0..254)
  bool bump = false;   // level < 15 && rem > 0: dither bump can fire
  bool above = false;  // chroma mag > floor
};

// Per-tile context + result for the uniform-run fast path, so the run helper
// call passes two pointers and the caller's register-resident accumulators
// (ts) are never address-taken by the hot row loop.
struct UniformRunCtx {
  const uint8_t* src_base;
  size_t src_stride;
  const uint8_t* previous_rgb565;
  size_t previous_rgb565_stride;
  bool compare_rgb565;
  uint8_t* l_cur;
  size_t stride;
  uint8_t* chroma_bits;
  size_t chroma_stride;
  uint8_t* lvl_tile;  // row stride 32 (kTileW == 32 path only)
  int32_t x0;
  int32_t y0;
  int32_t y1;
  uint8_t floor;
  uint8_t* dirty_rows;
  bool* row_dirty;
  RowMeta* row_meta;
  UniformRowCache cache;
};

struct UniformRunResult {
  int32_t next_y;      // first row NOT consumed (== y_begin: none consumed)
  uint32_t changed;    // sum over consumed rows
  uint32_t chroma_count;
  bool changed_chroma;
  int32_t min_x, max_x, min_y, max_y;  // same init/update laws as ts
};

// Uniform-ROW-RUN fast path for full-width 32-px tile rows: flat fills
// dominate real e-ink content (paper white, solid panels). Consumes
// consecutive rows whose 32 source pixels are all one value, starting at
// y_begin, stopping at the first non-uniform row or the tile end. For such
// rows the whole per-lane chain collapses to ONE scalar evaluation of the
// frozen reference math -- rgb565_luma8's rounded expand tables + BT.601
// (u32 arithmetic; max accumulator 65408, no overflow), quantize_gray16
// level selection verbatim, and rgb565_has_chroma's plain-shift chroma
// magnitude -- cached across rows keyed by the pixel value. Per lane:
//   * chroma bits: (mag > floor) is row-constant -> 4 identical bytes;
//     count += 32 * above (order-independent sum, same total).
//   * quantize: level and rem are row-constant. The bump (rem > thr &&
//     level < 15) cannot fire when rem == 0 (thresholds are unsigned) or
//     level == 15, making the quantized row one byte; otherwise it is
//     applied per lane against the mask row exactly like quantize16_span
//     (u8 compare: rem <= 254, thr <= 255).
//   * diff: vceq vs the OLD plane, reduced with the same mask-shaped
//     (32 + sum) mod 256 identity as the generic tile body.
// Rows that are also CLEAN (changed == 0) skip the lvl_tile store and are
// recorded in row_meta for Pass B's O(1) fold (old == lvl uniform, luma
// uniform -- closed-form significance/histogram).
//
// Structured as a RUN (not per-row) and noinline so (a) a fully flat tile
// costs ONE call whose loop keeps its accumulators in its own registers,
// and (b) the generic row body's register allocation and schedule are
// untouched -- textured rows pay only the caller's ~2-op src[0] == src[1]
// prefilter and, rarely, one bounced call.
__attribute__((noinline)) UniformRunResult uniform_run32_rgb565(
    UniformRunCtx& ctx, int32_t y_begin) {
  const int32_t x0 = ctx.x0;
  UniformRunResult run;
  run.changed = 0;
  run.chroma_count = 0;
  run.changed_chroma = false;
  run.min_x = x0 + 32;
  run.max_x = x0 - 1;
  run.min_y = ctx.y1;
  run.max_y = ctx.y0 - 1;
  const uint16_t* src = reinterpret_cast<const uint16_t*>(
      ctx.src_base + static_cast<size_t>(y_begin) * ctx.src_stride +
      static_cast<size_t>(x0) * 2u);
  const uint16_t* previous = ctx.previous_rgb565 == nullptr
                                 ? nullptr
                                 : reinterpret_cast<const uint16_t*>(
                                       ctx.previous_rgb565 +
                                       static_cast<size_t>(y_begin) *
                                           ctx.previous_rgb565_stride +
                                       static_cast<size_t>(x0) * 2u);
  const uint8_t* old =
      ctx.l_cur + static_cast<size_t>(y_begin) * ctx.stride + x0;
  uint8_t* chroma_at_x0 = ctx.chroma_bits +
                          static_cast<size_t>(y_begin) * ctx.chroma_stride +
                          (x0 >> 3);
  uint8_t* lvl_out =
      ctx.lvl_tile + static_cast<size_t>(y_begin - ctx.y0) * 32u;
  int32_t y = y_begin;
  for (; y < ctx.y1;
       ++y,
       src = reinterpret_cast<const uint16_t*>(
           reinterpret_cast<const uint8_t*>(src) + ctx.src_stride),
       previous = previous == nullptr
                      ? nullptr
                      : reinterpret_cast<const uint16_t*>(
                            reinterpret_cast<const uint8_t*>(previous) +
                            ctx.previous_rgb565_stride),
       old += ctx.stride, chroma_at_x0 += ctx.chroma_stride, lvl_out += 32) {
    if (y + 1 < ctx.y1) {
      // Same next-row pull as the generic body (see fused_pass_a comment).
      __builtin_prefetch(reinterpret_cast<const uint8_t*>(src) +
                         ctx.src_stride);
      __builtin_prefetch(old + ctx.stride);
    }
    const uint16x8_t v0 = vld1q_u16(src);
    const uint16x8_t v1 = vld1q_u16(src + 8);
    const uint16x8_t v2 = vld1q_u16(src + 16);
    const uint16x8_t v3 = vld1q_u16(src + 24);
    const uint16x8_t pivot = vdupq_laneq_u16(v0, 0);
    const uint16x8_t eqp =
        vandq_u16(vandq_u16(vceqq_u16(v0, pivot), vceqq_u16(v1, pivot)),
                  vandq_u16(vceqq_u16(v2, pivot), vceqq_u16(v3, pivot)));
    if (vminvq_u16(eqp) != 0xffffu) {
      break;  // row not uniform; the generic body takes over from here
    }
    const uint32_t px = src[0];
    if (px != ctx.cache.px) {
      ctx.cache.px = px;
      const uint32_t r5 = px >> 11;
      const uint32_t g6 = (px >> 5) & 0x3fu;
      const uint32_t b5 = px & 0x1fu;
      ctx.cache.luma = static_cast<uint8_t>(
          (54u * k_expand5[r5] + 183u * k_expand6[g6] + 19u * k_expand5[b5] +
           128u) >>
          8u);
      const uint32_t scaled = static_cast<uint32_t>(ctx.cache.luma) * 15u;
      const uint32_t level = scaled / 255u;
      const uint32_t rem = scaled - level * 255u;
      ctx.cache.lvl = static_cast<uint8_t>(level * 2u);
      ctx.cache.rem = static_cast<uint8_t>(rem);
      ctx.cache.bump = level < 15u && rem > 0u;
      const int32_t rc = static_cast<int32_t>(r5 << 3);
      const int32_t gc = static_cast<int32_t>(g6 << 2);
      const int32_t bc = static_cast<int32_t>(b5 << 3);
      const int32_t d0 = rc > gc ? rc - gc : gc - rc;
      const int32_t d1 = rc > bc ? rc - bc : bc - rc;
      const int32_t d2 = gc > bc ? gc - bc : bc - gc;
      ctx.cache.above =
          std::max({d0, d1, d2}) > static_cast<int32_t>(ctx.floor);
    }
    uint32_t old_chroma_bytes = 0;
    std::memcpy(&old_chroma_bytes, chroma_at_x0, 4);
    const uint32_t cbytes = ctx.cache.above ? 0xffffffffu : 0u;
    if (ctx.cache.above) {
      run.chroma_count += 32u;
    }
    uint32_t changed;
    if (!ctx.cache.bump) {
      const uint8x16_t lvlv = vdupq_n_u8(ctx.cache.lvl);
      uint8x16_t eq0 = vceqq_u8(lvlv, vld1q_u8(old));
      uint8x16_t eq1 = vceqq_u8(lvlv, vld1q_u8(old + 16));
      if (ctx.compare_rgb565) {
        if (previous == nullptr) {
          eq0 = vdupq_n_u8(0);
          eq1 = vdupq_n_u8(0);
        } else {
          const uint16x8_t peq0 = vceqq_u16(v0, vld1q_u16(previous));
          const uint16x8_t peq1 = vceqq_u16(v1, vld1q_u16(previous + 8));
          const uint16x8_t peq2 = vceqq_u16(v2, vld1q_u16(previous + 16));
          const uint16x8_t peq3 = vceqq_u16(v3, vld1q_u16(previous + 24));
          eq0 = vandq_u8(
              eq0, vuzp1q_u8(vreinterpretq_u8_u16(peq0),
                              vreinterpretq_u8_u16(peq1)));
          eq1 = vandq_u8(
              eq1, vuzp1q_u8(vreinterpretq_u8_u16(peq2),
                              vreinterpretq_u8_u16(peq3)));
        }
      }
      const uint8x16_t eq = vaddq_u8(eq0, eq1);
      changed = static_cast<uint8_t>(32u + vaddvq_u8(eq));
      if (changed == 0) {
        std::memcpy(chroma_at_x0, &cbytes, 4);
        ctx.row_meta[y - ctx.y0] = RowMeta{1, ctx.cache.lvl, ctx.cache.luma};
        continue;
      }
      vst1q_u8(lvl_out, lvlv);
      vst1q_u8(lvl_out + 16, lvlv);
    } else {
      // lvl = base + 2*(rem > thr): the vcgt mask is -1, << 1 makes it -2,
      // and subtracting adds 2 -- the reference bump with level < 15
      // guaranteed by cache.bump.
      uint8_t thr8_scratch[FrameLedger::kMaxTilePx];
      const uint8_t* thr8 = bluenoise_threshold_span(x0, y, 32u, thr8_scratch);
      const uint8x16_t remv = vdupq_n_u8(ctx.cache.rem);
      const uint8x16_t basev = vdupq_n_u8(ctx.cache.lvl);
      const uint8x16_t lvl0 =
          vsubq_u8(basev, vshlq_n_u8(vcgtq_u8(remv, vld1q_u8(thr8)), 1));
      const uint8x16_t lvl1 =
          vsubq_u8(basev, vshlq_n_u8(vcgtq_u8(remv, vld1q_u8(thr8 + 16)), 1));
      uint8x16_t eq0 = vceqq_u8(lvl0, vld1q_u8(old));
      uint8x16_t eq1 = vceqq_u8(lvl1, vld1q_u8(old + 16));
      if (ctx.compare_rgb565) {
        if (previous == nullptr) {
          eq0 = vdupq_n_u8(0);
          eq1 = vdupq_n_u8(0);
        } else {
          const uint16x8_t peq0 = vceqq_u16(v0, vld1q_u16(previous));
          const uint16x8_t peq1 = vceqq_u16(v1, vld1q_u16(previous + 8));
          const uint16x8_t peq2 = vceqq_u16(v2, vld1q_u16(previous + 16));
          const uint16x8_t peq3 = vceqq_u16(v3, vld1q_u16(previous + 24));
          eq0 = vandq_u8(
              eq0, vuzp1q_u8(vreinterpretq_u8_u16(peq0),
                              vreinterpretq_u8_u16(peq1)));
          eq1 = vandq_u8(
              eq1, vuzp1q_u8(vreinterpretq_u8_u16(peq2),
                              vreinterpretq_u8_u16(peq3)));
        }
      }
      const uint8x16_t eq = vaddq_u8(eq0, eq1);
      changed = static_cast<uint8_t>(32u + vaddvq_u8(eq));
      vst1q_u8(lvl_out, lvl0);
      vst1q_u8(lvl_out + 16, lvl1);
    }
    std::memcpy(chroma_at_x0, &cbytes, 4);
    if (changed != 0) {
      if (ctx.compare_rgb565 && previous == nullptr) {
        // The previous hue is unknowable (first frame / cross-process warm
        // handoff). Conservatively require color truth: an all-white current
        // frame may be erasing old pigment that a luma-only seed cannot name.
        run.changed_chroma = true;
      }
      // first/last (span-relative) via a bounded scan from both ends; the
      // diff above proved at least one change exists in [0, 32).
      int32_t f = 0;
      const auto pixel_changed = [&](int32_t x) {
        return lvl_out[x] != old[x] ||
               (ctx.compare_rgb565 &&
                (previous == nullptr || src[x] != previous[x]));
      };
      while (!pixel_changed(f)) {
        ++f;
      }
      int32_t l = 31;
      while (!pixel_changed(l)) {
        --l;
      }
      if (!run.changed_chroma) {
        for (int32_t x = f; x <= l; ++x) {
          if (!pixel_changed(x)) {
            continue;
          }
          const bool was_chroma =
              (old_chroma_bytes & (1u << static_cast<uint32_t>(x))) != 0;
          if (was_chroma || ctx.cache.above) {
            run.changed_chroma = true;
            break;
          }
        }
      }
      run.changed += changed;
      run.min_x = std::min(run.min_x, x0 + f);
      run.max_x = std::max(run.max_x, x0 + l);
      run.min_y = std::min(run.min_y, y);
      run.max_y = y;
      ctx.dirty_rows[static_cast<size_t>(y)] = 1;
      ctx.row_dirty[y - ctx.y0] = true;
    }
  }
  run.next_y = y;
  return run;
}

// Fused RGB565 Pass-A over a WHOLE candidate tile (all rows), 8 px/iter.
// Splits each packed pixel once and drives the entire chain from the shared
// r5/g6/b5 lanes:
//   luma (tables + BT.601)      -> quantize input (recomputed by Pass B for
//                                  dirty tiles; never stored here)
//   quantize16 + ordered dither -> lvl_tile   (settled levels)
//   chroma magnitude            -> (mag>floor) packed into chroma_bits + count
//   post-quantize diff (lvl vs OLD plane) -> changed + exact dirty bounds
// so the tile's source bytes are read ONCE instead of five times through five
// separate (partly cross-TU) kernel calls. Every lane op is either copied
// verbatim from the proven NEON kernels (luma_chroma_from_rgb565,
// quantize16_span_neon, write_chroma_row, count_above_span_neon,
// diff_span_neon) or an exact algebraic fold of one (proof notes inline), so
// outputs are byte-identical to that chain; the scalar references remain the
// spec.
//
// Structured tile-at-a-time (not row-at-a-time) so the mask tables load once
// per tile and the compiler optimizes the hot loop as a tight self-contained
// unit rather than bloating process_tile with register spills. x0 is a
// multiple of 8 (tile_px % 8 == 0), so the chroma byte is aligned and only the
// sub-8 tail can be partial.
// kTileW == 0 compiles the generic dynamic-width form; kTileW == 32
// specializes the ubiquitous full-interior 32-px tile (n16 == 2, no trailing
// groups), letting the compiler fix the trip counts and drop the tail code.
// Same instruction sequence per lane either way — bytes are identical.
//
// kTryUniform compiles in the uniform-run fast path (uniform_run32_rgb565;
// kTileW == 32 only). It is selected per TILE by sampling two rows in
// process_tile: a call inside the row loop forces every hoisted table vector
// and accumulator to spill/refill around it (AAPCS64 preserves no full NEON
// register), costing ~15% on textured rows even when never taken — so tiles
// that look textured run this call-free instantiation instead. Both
// instantiations produce byte-identical outputs; the choice only moves work.
template <int32_t kTileW, bool kTryUniform>
FusedTileStats fused_pass_a_tile_rgb565(
    const uint8_t* src_base, size_t src_stride, int32_t x0, int32_t y0,
    int32_t x1, int32_t y1, int32_t w_in, uint8_t* l_cur, size_t stride,
    uint8_t* chroma_bits, size_t chroma_stride, uint8_t* lvl_tile, size_t sw,
    uint8_t floor, uint8_t* dirty_rows, bool* row_dirty, RowMeta* row_meta,
    const uint8_t* previous_rgb565, size_t previous_rgb565_stride,
    bool compare_rgb565) {
  const int32_t w = kTileW != 0 ? kTileW : w_in;
  static constexpr uint8_t kBitWeights[16] = {1, 2, 4, 8, 16, 32, 64, 128,
                                              1, 2, 4, 8, 16, 32, 64, 128};
  const uint8x16_t weightsq = vld1q_u8(kBitWeights);
  const uint8x8_t weights = vget_low_u8(weightsq);
  const uint8x8_t vfloor = vdup_n_u8(floor);
  const uint8x16_t vfloorq = vdupq_n_u8(floor);
  const uint8x16x2_t expand5{
      {vld1q_u8(k_expand5.data()), vld1q_u8(k_expand5.data() + 16)}};
  const uint8x16x4_t expand6{
      {vld1q_u8(k_expand6.data()), vld1q_u8(k_expand6.data() + 16),
       vld1q_u8(k_expand6.data() + 32), vld1q_u8(k_expand6.data() + 48)}};
  uint16_t thr16_scratch[FrameLedger::kMaxTilePx];

  const int32_t nfull = w >> 3;          // 8-px groups (tail bookkeeping)
  const int32_t n16 = w >> 4;            // full 16-px groups
  const bool has8 = (w & 8) != 0;        // one trailing 8-px group
  const int32_t ti = nfull * 8;
  const int32_t rem_px = w - ti;

  FusedTileStats ts;
  ts.min_x = x1;
  ts.max_x = x0 - 1;
  ts.min_y = y1;
  ts.max_y = y0 - 1;

  // Tile-wide chroma-count accumulator: each row's mask-shaped per-lane
  // counts (<= n16 <= 4 per u8 lane) are folded in with one pairwise-add-
  // accumulate; u16 lanes bound by kMaxTilePx * 255, exact. Reduced once per
  // tile — same sum as the per-row vaddv + scalar add.
  uint16x8_t chromatile = vdupq_n_u16(0);

  // Uniform-run fast-path context (kTryUniform tiles only; see
  // uniform_run32_rgb565). Built once per tile; its cache lives across runs
  // so consecutive flat rows of one value evaluate the scalar chain once.
  [[maybe_unused]] UniformRunCtx run_ctx{
      src_base,
      src_stride,
      previous_rgb565,
      previous_rgb565_stride,
      compare_rgb565,
      l_cur,
      stride,
      chroma_bits,
      chroma_stride,
      lvl_tile,
      x0,
      y0,
      y1,
      floor,
      dirty_rows,
      row_dirty,
      row_meta,
      UniformRowCache{}};

  for (int32_t y = y0; y < y1; ++y) {
    const int32_t r = y - y0;
    uint8_t* lvl_out = lvl_tile + static_cast<size_t>(r) * sw;
    const uint16_t* src = reinterpret_cast<const uint16_t*>(
        src_base + static_cast<size_t>(y) * src_stride +
        static_cast<size_t>(x0) * 2u);
    const uint16_t* previous = previous_rgb565 == nullptr
                                   ? nullptr
                                   : reinterpret_cast<const uint16_t*>(
                                         previous_rgb565 +
                                         static_cast<size_t>(y) *
                                             previous_rgb565_stride +
                                         static_cast<size_t>(x0) * 2u);
    const uint8_t* old = l_cur + static_cast<size_t>(y) * stride + x0;
    uint8_t* chroma_at_x0 =
        chroma_bits + static_cast<size_t>(y) * chroma_stride + (x0 >> 3);
    uint8_t old_chroma_bytes[FrameLedger::kMaxTilePx / 8];
    std::memcpy(old_chroma_bytes, chroma_at_x0,
                static_cast<size_t>((w + 7) >> 3));
    if (y + 1 < y1) {
      // Pull the next tile row's source and old-plane lines while this row
      // computes; the 64-byte-per-row strided walk defeats simple stream
      // prefetchers (matters most on the in-order A55).
      __builtin_prefetch(src_base + static_cast<size_t>(y + 1) * src_stride +
                         static_cast<size_t>(x0) * 2u);
      __builtin_prefetch(old + stride);
    }

    if constexpr (kTileW == 32 && kTryUniform) {
      // Uniform-run fast path (see uniform_run32_rgb565). The scalar
      // src[0] == src[1] prefilter keeps the cost on textured rows
      // (gradient/noise/glyph) to ~2 ops — such rows almost never open with
      // a repeated pixel pair, so they never even call the noinline helper,
      // and a fully flat tile costs ONE call for all its rows. The merge
      // below is a no-op for an empty run (its accumulators start at the
      // same identities ts uses), so the bounce case costs only the merge.
      if (src[0] == src[1]) {
        const UniformRunResult run = uniform_run32_rgb565(run_ctx, y);
        ts.changed += run.changed;
        ts.chroma_count += run.chroma_count;
        ts.changed_chroma = ts.changed_chroma || run.changed_chroma;
        ts.min_x = std::min(ts.min_x, run.min_x);
        ts.max_x = std::max(ts.max_x, run.max_x);
        ts.min_y = std::min(ts.min_y, run.min_y);
        ts.max_y = std::max(ts.max_y, run.max_y);
        if (run.next_y > y) {
          if (run.next_y >= y1) {
            break;  // tile fully consumed
          }
          y = run.next_y - 1;  // for-increment lands on the non-uniform row
          continue;
        }
      }
    }

    const uint16_t* thr16row = bluenoise_threshold_span_u16(
        x0, y, static_cast<size_t>(w), thr16_scratch);
    // Per-lane accumulators kept mask-shaped so each group costs one vadd/
    // vsub, with a single reduction per row (a tile row is at most
    // kMaxTilePx/16 == 4 full 16-px groups, so no u8 lane can overflow):
    //   eqacc  += vceq(lvl, old): lane == (-eq_count) mod 256, so
    //             changed == (16*n16 + vaddv(eqacc)) mod 256 (changed <= 64).
    //   chromacnt -= (mag > floor) mask: lane == above_count (mask is -1).
    // Both identical to the per-group popcount/0-1-add forms. first/last are
    // recovered by a bounded scan only when the row changed.
    //
    // The main loop runs 16 px/iter (q-form ops): the channel split, table
    // expansions, chroma chain, diff, and the lvl store run once per 16 lanes
    // instead of twice per 8, and only the u16 quantize arithmetic doubles —
    // every lane op is the same math as the 8-lane form, so bytes are
    // identical. vshrn(v, 11) == r5 (u16 >> 11 <= 31), vshrn(v, 5) & 0x3f ==
    // g6, vmovn(v) & 0x1f == b5 — the narrowing shifts fold the mask ops of
    // the widened split.
    uint8x16_t eqaccq = vdupq_n_u8(0);
    uint8x16_t chromacntq = vdupq_n_u8(0);
    for (int32_t g = 0; g < n16; ++g) {
      const int32_t j = g * 16;
      const uint16x8_t v0 = vld1q_u16(src + j);
      const uint16x8_t v1 = vld1q_u16(src + j + 8);
      // Byte-deinterleave split: uzp2 == per-pixel (v >> 8), so
      // uzp2 >> 3 == v >> 11 == r5; uzp1 == (v & 0xff), so uzp1 & 0x1f == b5;
      // vshrn(v, 5) & 0x3f == g6 (bits 5..10). Same fields, fewer ops.
      const uint8x16_t lo8 =
          vuzp1q_u8(vreinterpretq_u8_u16(v0), vreinterpretq_u8_u16(v1));
      const uint8x16_t hi8 =
          vuzp2q_u8(vreinterpretq_u8_u16(v0), vreinterpretq_u8_u16(v1));
      const uint8x16_t r5q = vshrq_n_u8(hi8, 3);
      const uint8x16_t g6q = vandq_u8(
          vshrn_high_n_u16(vshrn_n_u16(v0, 5), v1, 5), vdupq_n_u8(0x3f));
      const uint8x16_t b5q = vandq_u8(lo8, vdupq_n_u8(0x1f));
      // Luma: rounded channel expansion + integer BT.601 (54,183,19)/256.
      const uint8x16_t rl = vqtbl2q_u8(expand5, r5q);
      const uint8x16_t gl = vqtbl4q_u8(expand6, g6q);
      const uint8x16_t bl = vqtbl2q_u8(expand5, b5q);
      uint16x8_t acc0 = vmull_u8(vget_low_u8(rl), vdup_n_u8(54));
      acc0 = vmlal_u8(acc0, vget_low_u8(gl), vdup_n_u8(183));
      acc0 = vmlal_u8(acc0, vget_low_u8(bl), vdup_n_u8(19));
      acc0 = vaddq_u16(acc0, vdupq_n_u16(128));
      uint16x8_t acc1 = vmull_high_u8(rl, vdupq_n_u8(54));
      acc1 = vmlal_high_u8(acc1, gl, vdupq_n_u8(183));
      acc1 = vmlal_high_u8(acc1, bl, vdupq_n_u8(19));
      acc1 = vaddq_u16(acc1, vdupq_n_u16(128));
      const uint8x16_t luma8q =
          vshrn_high_n_u16(vshrn_n_u16(acc0, 8), acc1, 8);
      // Quantize16 + ordered dither -> even 5-bit levels. Same math as
      // quantize16_span_neon with the bump folded to a saturate: level is in
      // [0, 15], so level + (rem > thr && level < 15) == min(level +
      // (rem > thr), 15) lane-for-lane (vcgt mask is -1; vsub adds 1).
      const uint16x8_t scaled0 = vmull_u8(vget_low_u8(luma8q), vdup_n_u8(15));
      const uint16x8_t scaled1 = vmull_high_u8(luma8q, vdupq_n_u8(15));
      uint16x8_t level0 = vshrq_n_u16(
          vaddq_u16(vaddq_u16(scaled0, vshrq_n_u16(scaled0, 8)),
                    vdupq_n_u16(1)),
          8);
      uint16x8_t level1 = vshrq_n_u16(
          vaddq_u16(vaddq_u16(scaled1, vshrq_n_u16(scaled1, 8)),
                    vdupq_n_u16(1)),
          8);
      const uint16x8_t rem0 = vmlsq_u16(scaled0, level0, vdupq_n_u16(255));
      const uint16x8_t rem1 = vmlsq_u16(scaled1, level1, vdupq_n_u16(255));
      level0 = vminq_u16(
          vsubq_u16(level0, vcgtq_u16(rem0, vld1q_u16(thr16row + j))),
          vdupq_n_u16(15));
      level1 = vminq_u16(
          vsubq_u16(level1, vcgtq_u16(rem1, vld1q_u16(thr16row + j + 8))),
          vdupq_n_u16(15));
      const uint8x16_t lvl8q = vmovn_high_u16(
          vmovn_u16(vshlq_n_u16(level0, 1)), vshlq_n_u16(level1, 1));
      vst1q_u8(lvl_out + j, lvl8q);
      // Chroma magnitude (plain-shift expansion) -> (mag>floor) bytes + count.
      const uint8x16_t rcq = vshlq_n_u8(r5q, 3);
      const uint8x16_t gcq = vshlq_n_u8(g6q, 2);
      const uint8x16_t bcq = vshlq_n_u8(b5q, 3);
      const uint8x16_t magq = vmaxq_u8(
          vmaxq_u8(vabdq_u8(rcq, gcq), vabdq_u8(rcq, bcq)), vabdq_u8(gcq, bcq));
      const uint8x16_t aboveq = vcgtq_u8(magq, vfloorq);
      // Byte pack: three pairwise adds fold the 16 weighted bits to
      // [byte0, byte1] in lanes 0/1 (disjoint weights, sums <= 255), then one
      // u16 lane store writes both chroma bytes — same bytes as the two
      // per-half vaddv reductions.
      const uint8x16_t wbits = vandq_u8(aboveq, weightsq);
      uint8x16_t pack = vpaddq_u8(wbits, wbits);
      pack = vpaddq_u8(pack, pack);
      pack = vpaddq_u8(pack, pack);
      vst1q_lane_u16(reinterpret_cast<uint16_t*>(chroma_at_x0 + 2 * g),
                     vreinterpretq_u16_u8(pack), 0);
      chromacntq = vsubq_u8(chromacntq, aboveq);
      // Post-quantize luma equality is ANDed with raw RGB565 equality when
      // an engine-true mirror is available. In compare mode with no mirror,
      // every candidate lane establishes color truth.
      uint8x16_t equal = vceqq_u8(lvl8q, vld1q_u8(old + j));
      if (compare_rgb565) {
        if (previous == nullptr) {
          equal = vdupq_n_u8(0);
        } else {
          const uint16x8_t raw0 = vceqq_u16(v0, vld1q_u16(previous + j));
          const uint16x8_t raw1 =
              vceqq_u16(v1, vld1q_u16(previous + j + 8));
          equal = vandq_u8(
              equal, vuzp1q_u8(vreinterpretq_u8_u16(raw0),
                                vreinterpretq_u8_u16(raw1)));
        }
      }
      eqaccq = vaddq_u8(eqaccq, equal);
    }
    uint32_t changed = static_cast<uint8_t>(
        static_cast<uint32_t>(16 * n16) + vaddvq_u8(eqaccq));
    chromatile = vpadalq_u8(chromatile, chromacntq);
    uint32_t chroma_count = 0;  // tail-only; the vector groups accumulate
                                // into chromatile.

    if (has8) {
      // Trailing full 8-px group (tile_px % 16 == 8): the original 8-lane
      // body, reduced straight to the row scalars (runs once per row).
      const int32_t j = n16 * 16;
      const uint16x8_t v = vld1q_u16(src + j);
      const uint8x8_t r5 = vmovn_u16(vshrq_n_u16(v, 11));
      const uint8x8_t g6 =
          vmovn_u16(vandq_u16(vshrq_n_u16(v, 5), vdupq_n_u16(0x3f)));
      const uint8x8_t b5 = vmovn_u16(vandq_u16(v, vdupq_n_u16(0x1f)));
      const uint8x8_t rl = vqtbl2_u8(expand5, r5);
      const uint8x8_t gl = vqtbl4_u8(expand6, g6);
      const uint8x8_t bl = vqtbl2_u8(expand5, b5);
      uint16x8_t acc = vmull_u8(rl, vdup_n_u8(54));
      acc = vmlal_u8(acc, gl, vdup_n_u8(183));
      acc = vmlal_u8(acc, bl, vdup_n_u8(19));
      acc = vaddq_u16(acc, vdupq_n_u16(128));
      const uint8x8_t luma8 = vshrn_n_u16(acc, 8);
      const uint16x8_t scaled = vmull_u8(luma8, vdup_n_u8(15));
      const uint16x8_t biased =
          vaddq_u16(vaddq_u16(scaled, vshrq_n_u16(scaled, 8)), vdupq_n_u16(1));
      uint16x8_t level = vshrq_n_u16(biased, 8);
      const uint16x8_t rem = vmlsq_u16(scaled, level, vdupq_n_u16(255));
      const uint16x8_t thr16 = vld1q_u16(thr16row + j);
      level = vminq_u16(vsubq_u16(level, vcgtq_u16(rem, thr16)),
                        vdupq_n_u16(15));
      const uint8x8_t lvl8 = vmovn_u16(vshlq_n_u16(level, 1));
      vst1_u8(lvl_out + j, lvl8);
      const uint8x8_t rc = vshl_n_u8(r5, 3);
      const uint8x8_t gc = vshl_n_u8(g6, 2);
      const uint8x8_t bc = vshl_n_u8(b5, 3);
      const uint8x8_t mag =
          vmax_u8(vmax_u8(vabd_u8(rc, gc), vabd_u8(rc, bc)), vabd_u8(gc, bc));
      const uint8x8_t above = vcgt_u8(mag, vfloor);
      chroma_at_x0[2 * n16] = vaddv_u8(vand_u8(above, weights));
      chroma_count += static_cast<uint32_t>(
          vaddv_u8(vand_u8(above, vdup_n_u8(1))));
      uint8x8_t equal = vceq_u8(lvl8, vld1_u8(old + j));
      if (compare_rgb565) {
        if (previous == nullptr) {
          equal = vdup_n_u8(0);
        } else {
          const uint16x8_t raw = vceqq_u16(v, vld1q_u16(previous + j));
          equal = vand_u8(equal, vmovn_u16(raw));
        }
      }
      changed += static_cast<uint8_t>(8u + vaddv_u8(equal));
    }

    if (rem_px != 0) {
      // Sub-8 tail (right-edge tiles only): route the exact scalar references,
      // then fold the partial chroma byte / count / diff the same way.
      uint8_t thr_scratch[FrameLedger::kMaxTilePx];
      const uint8_t* thr_tail = bluenoise_threshold_span(
          x0 + ti, y, static_cast<size_t>(rem_px), thr_scratch);
      uint8_t luma_tail[8];
      luma_from_rgb565_span_scalar(src + ti, static_cast<size_t>(rem_px),
                                   luma_tail);
      quantize16_span_scalar(luma_tail, thr_tail, static_cast<size_t>(rem_px),
                             lvl_out + ti);
      uint8_t mag_tail[8];
      chroma_mag_from_rgb565_span_scalar(src + ti, static_cast<size_t>(rem_px),
                                         mag_tail);
      uint8_t chroma_byte = 0;
      for (int32_t b = 0; b < rem_px; ++b) {
        if (mag_tail[b] > floor) {
          chroma_byte = static_cast<uint8_t>(chroma_byte | (1u << b));
          ++chroma_count;
        }
      }
      const uint8_t keep = static_cast<uint8_t>((1u << rem_px) - 1u);
      chroma_at_x0[nfull] =
          static_cast<uint8_t>((chroma_at_x0[nfull] & ~keep) | chroma_byte);
      for (int32_t b = 0; b < rem_px; ++b) {
        changed +=
            (lvl_out[ti + b] != old[ti + b] ||
             (compare_rgb565 &&
              (previous == nullptr ||
               src[ti + b] != previous[ti + b])))
                ? 1u
                : 0u;
      }
    }

    ts.chroma_count += chroma_count;
    if (changed != 0) {
      if (compare_rgb565 && previous == nullptr) {
        // See uniform_run32_rgb565: unknown old hue is color-sensitive even
        // when every current pixel is neutral.
        ts.changed_chroma = true;
      }
      // first/last (span-relative) via a bounded scan from both ends; the pass
      // above proved at least one change exists in [0, w).
      int32_t f = 0;
      const auto pixel_changed = [&](int32_t x) {
        return lvl_out[x] != old[x] ||
               (compare_rgb565 &&
                (previous == nullptr || src[x] != previous[x]));
      };
      while (!pixel_changed(f)) {
        ++f;
      }
      int32_t l = w - 1;
      while (!pixel_changed(l)) {
        --l;
      }
      if (!ts.changed_chroma) {
        for (int32_t x = f; x <= l; ++x) {
          if (!pixel_changed(x)) {
            continue;
          }
          const uint8_t mask =
              static_cast<uint8_t>(1u << static_cast<uint32_t>(x & 7));
          const bool was_chroma =
              (old_chroma_bytes[x >> 3] & mask) != 0;
          const bool is_chroma = (chroma_at_x0[x >> 3] & mask) != 0;
          if (was_chroma || is_chroma) {
            ts.changed_chroma = true;
            break;
          }
        }
      }
      ts.changed += changed;
      ts.min_x = std::min(ts.min_x, x0 + f);
      ts.max_x = std::max(ts.max_x, x0 + l);
      ts.min_y = std::min(ts.min_y, y);
      ts.max_y = y;
      dirty_rows[static_cast<size_t>(y)] = 1;
      row_dirty[r] = true;
    }
  }
  ts.chroma_count += vaddvq_u16(chromatile);
  return ts;
}

// Pass-B accumulators for one dirty tile: the same quantities the per-kernel
// chain (luma_span_for_format + significance_span + level_hist_bits_span)
// accumulates into process_tile's locals.
struct PassBStats {
  uint32_t sad = 0;
  uint8_t max_diff = 0;
  uint16_t hist = 0;
};

// Fused RGB565 Pass B over a dirty tile: ONE walk re-deriving luma from the
// (L1-warm) source rows and accumulating pre-dither significance vs the OLD
// plane, the level-presence histogram, and the dirty-row write-through —
// replacing the three separate span-kernel calls + memcpy per row. Byte
// identity:
//   * luma lanes are the verbatim fused split + expand-table + BT.601
//     sequence from fused_pass_a_tile_rgb565 (== luma_from_rgb565_span).
//   * significance matches significance_span_neon lane-for-lane (vminq
//     31-clamp, vqtbl2q dequant, vabdq); sad/max accumulate in exact integer
//     arithmetic (u16 row accumulator: <= 4 groups * 510 per lane per row,
//     flushed to u32 every row) and both folds are order-independent.
//   * the histogram OR (1 << (lvl >> 1) per byte) is order-independent and
//     bit-identical to level_hist_bits_span_scalar.
//   * write-through copies the same lvl_tile bytes to the same OLD-plane rows
//     AFTER that row's significance read, preserving the reference order.
// Rows Pass A marked uniform_clean have old[x] == lvl and a single luma byte
// (see RowMeta), so their per-pixel sums collapse to exact closed forms and
// their write-through is a no-op (the row is clean).
PassBStats fused_pass_b_rgb565(const uint8_t* src_base, size_t src_stride,
                               int32_t x0, int32_t y0, int32_t y1, int32_t w,
                               uint8_t* l_cur, size_t stride,
                               const uint8_t* lvl_tile, size_t sw,
                               const RowMeta* row_meta,
                               const bool* row_dirty) {
  const uint8x16x2_t expand5{
      {vld1q_u8(k_expand5.data()), vld1q_u8(k_expand5.data() + 16)}};
  const uint8x16x4_t expand6{
      {vld1q_u8(k_expand6.data()), vld1q_u8(k_expand6.data() + 16),
       vld1q_u8(k_expand6.data() + 32), vld1q_u8(k_expand6.data() + 48)}};
  const uint8x16x2_t dequant{{vld1q_u8(k_level5_to_gray8.data()),
                              vld1q_u8(k_level5_to_gray8.data() + 16)}};
  uint32x4_t sad4 = vdupq_n_u32(0);
  uint8x16_t maxv = vdupq_n_u8(0);
  uint16x8_t histacc = vdupq_n_u16(0);
  const int32_t n16 = w >> 4;
  const int32_t ti = n16 * 16;
  const int32_t rem_px = w - ti;
  PassBStats out;
  for (int32_t y = y0; y < y1; ++y) {
    const int32_t r = y - y0;
    if (row_meta[r].uniform_clean != 0) {
      const int32_t gray = level5_to_gray8(row_meta[r].lvl);
      const int32_t luma = row_meta[r].luma;
      const int32_t d = luma > gray ? luma - gray : gray - luma;
      out.sad += static_cast<uint32_t>(w) * static_cast<uint32_t>(d);
      out.max_diff = std::max(out.max_diff, static_cast<uint8_t>(d));
      out.hist =
          static_cast<uint16_t>(out.hist | (1u << (row_meta[r].lvl >> 1)));
      continue;
    }
    const uint16_t* src = reinterpret_cast<const uint16_t*>(
        src_base + static_cast<size_t>(y) * src_stride +
        static_cast<size_t>(x0) * 2u);
    const uint8_t* lvl_row = lvl_tile + static_cast<size_t>(r) * sw;
    uint8_t* dst = l_cur + static_cast<size_t>(y) * stride + x0;
    uint16x8_t rowsad = vdupq_n_u16(0);
    for (int32_t g = 0; g < n16; ++g) {
      const int32_t j = g * 16;
      const uint16x8_t v0 = vld1q_u16(src + j);
      const uint16x8_t v1 = vld1q_u16(src + j + 8);
      const uint8x16_t lo8 =
          vuzp1q_u8(vreinterpretq_u8_u16(v0), vreinterpretq_u8_u16(v1));
      const uint8x16_t hi8 =
          vuzp2q_u8(vreinterpretq_u8_u16(v0), vreinterpretq_u8_u16(v1));
      const uint8x16_t r5q = vshrq_n_u8(hi8, 3);
      const uint8x16_t g6q = vandq_u8(
          vshrn_high_n_u16(vshrn_n_u16(v0, 5), v1, 5), vdupq_n_u8(0x3f));
      const uint8x16_t b5q = vandq_u8(lo8, vdupq_n_u8(0x1f));
      const uint8x16_t rl = vqtbl2q_u8(expand5, r5q);
      const uint8x16_t gl = vqtbl4q_u8(expand6, g6q);
      const uint8x16_t bl = vqtbl2q_u8(expand5, b5q);
      uint16x8_t acc0 = vmull_u8(vget_low_u8(rl), vdup_n_u8(54));
      acc0 = vmlal_u8(acc0, vget_low_u8(gl), vdup_n_u8(183));
      acc0 = vmlal_u8(acc0, vget_low_u8(bl), vdup_n_u8(19));
      acc0 = vaddq_u16(acc0, vdupq_n_u16(128));
      uint16x8_t acc1 = vmull_high_u8(rl, vdupq_n_u8(54));
      acc1 = vmlal_high_u8(acc1, gl, vdupq_n_u8(183));
      acc1 = vmlal_high_u8(acc1, bl, vdupq_n_u8(19));
      acc1 = vaddq_u16(acc1, vdupq_n_u16(128));
      const uint8x16_t luma8q =
          vshrn_high_n_u16(vshrn_n_u16(acc0, 8), acc1, 8);
      const uint8x16_t oldv = vld1q_u8(dst + j);
      const uint8x16_t gray =
          vqtbl2q_u8(dequant, vminq_u8(oldv, vdupq_n_u8(31)));
      const uint8x16_t ad = vabdq_u8(luma8q, gray);
      maxv = vmaxq_u8(maxv, ad);
      rowsad = vpadalq_u8(rowsad, ad);
      const uint8x16_t lvl = vld1q_u8(lvl_row + j);
      const uint8x16_t idx = vshrq_n_u8(lvl, 1);
      histacc = vorrq_u16(
          histacc,
          vshlq_u16(vdupq_n_u16(1),
                    vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(idx)))));
      histacc = vorrq_u16(
          histacc,
          vshlq_u16(vdupq_n_u16(1),
                    vreinterpretq_s16_u16(vmovl_u8(vget_high_u8(idx)))));
    }
    sad4 = vpadalq_u16(sad4, rowsad);
    if (rem_px != 0) {
      // Sub-16 tail (ragged right-edge tiles): exact scalar references.
      uint8_t luma_tail[16];
      luma_from_rgb565_span_scalar(src + ti, static_cast<size_t>(rem_px),
                                   luma_tail);
      const SpanSignificance sig = significance_span_scalar(
          luma_tail, dst + ti, static_cast<size_t>(rem_px));
      out.sad += sig.sad;
      out.max_diff = std::max(out.max_diff, sig.max_diff);
      out.hist = static_cast<uint16_t>(
          out.hist |
          level_hist_bits_span_scalar(lvl_row + ti,
                                      static_cast<size_t>(rem_px)));
    }
    if (row_dirty[r]) {
      std::memcpy(dst, lvl_row, sw);
    }
  }
  out.sad += vaddvq_u32(sad4);
  out.max_diff = std::max(out.max_diff, vmaxvq_u8(maxv));
  uint16x4_t ho = vorr_u16(vget_low_u16(histacc), vget_high_u16(histacc));
  ho = vorr_u16(ho, vext_u16(ho, ho, 2));
  ho = vorr_u16(ho, vext_u16(ho, ho, 1));
  out.hist = static_cast<uint16_t>(out.hist | vget_lane_u16(ho, 0));
  return out;
}
#endif  // __ARM_NEON && __aarch64__

// Packs (mag > floor) bits into the chroma bitplane row. x0 is tile-aligned
// (multiple of 8 by the ledger's tile_px % 8 == 0 guarantee), so only the
// tail byte can be partial; its unrelated bits are preserved.
void write_chroma_row(uint8_t* bits_row, int32_t x0, const uint8_t* mag,
                      int32_t w, uint8_t floor) {
  uint8_t* p = bits_row + (x0 >> 3);
  const int32_t full_bytes = w >> 3;
#if defined(__ARM_NEON) && defined(__aarch64__)
  // Each output byte packs (mag[i*8+bit] > floor) LSB-first. Compare 8 lanes,
  // AND with per-lane bit weights {1,2,...,128}, horizontal-add to the byte —
  // bit-identical to the scalar inner loop, no per-bit branch.
  static constexpr uint8_t kBitWeights[8] = {1, 2, 4, 8, 16, 32, 64, 128};
  const uint8x8_t weights = vld1_u8(kBitWeights);
  const uint8x8_t vfloor = vdup_n_u8(floor);
  for (int32_t i = 0; i < full_bytes; ++i) {
    const uint8x8_t cmp = vcgt_u8(vld1_u8(mag + i * 8), vfloor);
    p[i] = vaddv_u8(vand_u8(cmp, weights));
  }
#else
  for (int32_t i = 0; i < full_bytes; ++i) {
    uint8_t byte = 0;
    for (int32_t bit = 0; bit < 8; ++bit) {
      byte = static_cast<uint8_t>(
          byte | ((mag[i * 8 + bit] > floor ? 1u : 0u) << bit));
    }
    p[i] = byte;
  }
#endif
  const int32_t rem = w & 7;
  if (rem != 0) {
    uint8_t byte = 0;
    for (int32_t bit = 0; bit < rem; ++bit) {
      byte = static_cast<uint8_t>(
          byte | ((mag[full_bytes * 8 + bit] > floor ? 1u : 0u) << bit));
    }
    const uint8_t mask = static_cast<uint8_t>((1u << rem) - 1u);
    p[full_bytes] = static_cast<uint8_t>((p[full_bytes] & ~mask) | byte);
  }
}

}  // namespace

bool TilePass::admit_exact_rgb565_baseline(const FrameLedger &ledger,
                                           std::span<const uint8_t> rgb565,
                                           size_t stride) {
  if (!ledger.valid()) {
    return false;
  }
  const size_t expected_stride =
      static_cast<size_t>(ledger.width()) * sizeof(uint16_t);
  if (stride != expected_stride ||
      (ledger.height() != 0 && stride > SIZE_MAX / ledger.height()) ||
      rgb565.size() != stride * static_cast<size_t>(ledger.height())) {
    return false;
  }
  retained_reject_ledger_ = &ledger;
  retained_reject_epoch_ = ledger.epoch();
  retained_reject_ready_ = true;
  retained_source_ready_ = false;
  return true;
}

void TilePass::invalidate_exact_rgb565_baseline() {
  retained_reject_ledger_ = nullptr;
  retained_reject_epoch_ = 0;
  retained_reject_ready_ = false;
  retained_source_ready_ = false;
}

size_t TilePass::run(const PlutoSurface& src,
                     const PlutoRect* damage_hints,
                     size_t hint_count,
                     FrameLedger* ledger,
                     const uint8_t* previous_rgb565,
                     size_t previous_rgb565_stride,
                     bool compare_rgb565) {
  records_.clear();
  processed_tile_count_ = 0;
  dirty_bounds_ = PlutoRect{0, 0, 0, 0};
  if (ledger == nullptr || !ledger->valid() || src.pixels == nullptr ||
      !format_supported(src.format)) {
    return 0;
  }
  const int32_t width =
      std::min<int32_t>(src.width, static_cast<int32_t>(ledger->width()));
  const int32_t height =
      std::min<int32_t>(src.height, static_cast<int32_t>(ledger->height()));
  if (width <= 0 || height <= 0) {
    return 0;
  }
  compare_rgb565 =
      compare_rgb565 && src.format == kPlutoPixelFormatRgb565;
  if (!compare_rgb565) {
    previous_rgb565 = nullptr;
    previous_rgb565_stride = 0;
  } else if (previous_rgb565_stride < static_cast<size_t>(width) * 2u) {
    previous_rgb565 = nullptr;
  }

  ensure_capacity(*ledger);
  const bool can_retain_source =
      src.format == kPlutoPixelFormatRgb565 &&
      width == static_cast<int32_t>(ledger->width()) &&
      height == static_cast<int32_t>(ledger->height());
  const size_t retained_source_stride =
      static_cast<size_t>(ledger->width()) * sizeof(uint16_t);
  const size_t retained_source_bytes =
      retained_source_stride * static_cast<size_t>(ledger->height());
  if (!can_retain_source) {
    retained_source_ready_ = false;
  }
  if (!compare_rgb565 && can_retain_source &&
      retained_source_rgb565_.size() != retained_source_bytes) {
    retained_source_rgb565_.resize(retained_source_bytes);
    retained_reject_ready_ = false;
    retained_source_ready_ = false;
  }
  // Direct-color callers already maintain the exact engine-true mirror used
  // below. Do not duplicate their per-tile mirror writes; if a caller later
  // drops out of direct-color mode, one ordinary pass safely re-seeds this
  // fallback before it can reject anything.
  if (compare_rgb565) {
    retained_source_ready_ = false;
  }
  if (retained_reject_ledger_ != ledger ||
      retained_reject_epoch_ != ledger->epoch()) {
    // TilePass can be reused with another or externally reset ledger. Raw
    // equality is not a proof until one full pass has rebuilt every derived
    // plane for this exact ledger epoch chain.
    retained_reject_ready_ = false;
    retained_source_ready_ = false;
    retained_reject_ledger_ = ledger;
  }
  std::fill(candidate_tiles_.begin(), candidate_tiles_.end(), uint8_t{0});
  std::fill(dirty_rows_.begin(), dirty_rows_.end(), uint8_t{0});
  mark_candidates(damage_hints, hint_count, width, height, *ledger);

  size_t candidate_count = 0;
  for (const uint8_t candidate : candidate_tiles_) {
    candidate_count += candidate != 0 ? 1u : 0u;
  }
  const bool full_surface_candidates =
      width == static_cast<int32_t>(ledger->width()) &&
      height == static_cast<int32_t>(ledger->height()) &&
      candidate_count == candidate_tiles_.size();

  const uint32_t epoch = ledger->begin_pass();
  const uint32_t tile_cols = ledger->tile_cols();
  const uint32_t tile_rows = ledger->tile_rows();

  // Scroll-verify snapshots (secondary-hash discipline): before ANY tile
  // writes, copy the PRE-pass bytes of every sampled row a candidate tile
  // row may overwrite. The scroll detector memcmp-verifies its row-hash
  // vote against these true previous-pass pixels.
  {
    const int32_t tile_px = static_cast<int32_t>(ledger->tile_px());
    const uint8_t* l_cur = ledger->l_cur();
    const size_t stride = ledger->stride();
    for (uint32_t ty = 0; ty < tile_rows; ++ty) {
      const uint8_t* row = &candidate_tiles_[ty * tile_cols];
      bool any = false;
      for (uint32_t tx = 0; tx < tile_cols && !any; ++tx) {
        any = row[tx] != 0;
      }
      if (!any) {
        continue;
      }
      const int32_t ry0 = static_cast<int32_t>(ty) * tile_px;
      const int32_t ry1 = std::min(ry0 + tile_px, height);
      const int32_t period =
          static_cast<int32_t>(FrameLedger::kRowSamplePeriod);
      for (int32_t y = ceil_to_multiple(ry0, period); y < ry1; y += period) {
        std::memcpy(ledger->row_sample_slot(static_cast<uint32_t>(y)),
                    l_cur + static_cast<size_t>(y) * stride, ledger->width());
        ledger->mark_row_sample(static_cast<uint32_t>(y));
      }
    }
  }

  // A retained RGB565 mirror gives an exact, collision-free way to narrow a
  // severely over-reported Flutter frame before the fused tile kernels. Do it
  // only for broad candidate sets. The first tier is one target-optimized
  // memcmp per full logical row, which cheaply rejects almost every row on a
  // small pen update. Only rows proved changed enter the second tier: exact
  // tile-column memcmps mark the tile spans containing raw differences. This
  // avoids turning a 24x3 segment into a 954x32 fused traversal without
  // reviving the expensive all-rows/per-tile comparison that this path
  // replaced. Localized paint bounds should enter the fused path directly.
  // Snapshots above intentionally retain the ordinary pass's scroll-
  // verification side effects before candidates are narrowed.
  //
  // A byte-identical tile span cannot change luma, chroma, dithered level,
  // hashes, or raw color truth under the same renderer configuration. The
  // existing post-quantize/raw-color diff remains final authority inside
  // every retained tile. Both comparisons cover logical RGB565 bytes only;
  // independently padded source/mirror rows are intentionally supported.
  const uint8_t* exact_previous = nullptr;
  size_t exact_previous_stride = 0;
  if (compare_rgb565 && previous_rgb565 != nullptr) {
    exact_previous = previous_rgb565;
    exact_previous_stride = previous_rgb565_stride;
  } else if (!compare_rgb565 && can_retain_source && retained_source_ready_ &&
             retained_source_rgb565_.size() == retained_source_bytes) {
    exact_previous = retained_source_rgb565_.data();
    exact_previous_stride = retained_source_stride;
  }
  if (retained_reject_ready_ && exact_previous != nullptr) {
    const size_t broad_threshold = std::max<size_t>(
        static_cast<size_t>(tile_cols) * 4u,
        (candidate_tiles_.size() + 1u) / 2u);
    if (candidate_count >= broad_threshold) {
      std::fill(raw_changed_tile_rows_.begin(),
                raw_changed_tile_rows_.end(), uint8_t{0});
      std::fill(raw_changed_tiles_.begin(), raw_changed_tiles_.end(),
                uint8_t{0});
      const size_t logical_row_bytes = static_cast<size_t>(width) * 2u;
      const int32_t tile_px = static_cast<int32_t>(ledger->tile_px());
      for (int32_t y = 0; y < height; ++y) {
        const uint8_t* current =
            src.pixels + static_cast<size_t>(y) * src.stride_bytes;
        const uint8_t* previous =
            exact_previous + static_cast<size_t>(y) * exact_previous_stride;
        if (std::memcmp(current, previous, logical_row_bytes) == 0) {
          continue;
        }
        const uint32_t ty = static_cast<uint32_t>(y / tile_px);
        raw_changed_tile_rows_[ty] = 1;
        const size_t tile_row_offset = static_cast<size_t>(ty) * tile_cols;
        for (uint32_t tx = 0; tx < tile_cols; ++tx) {
          const size_t tile_idx = tile_row_offset + tx;
          if (candidate_tiles_[tile_idx] == 0 ||
              raw_changed_tiles_[tile_idx] != 0) {
            continue;
          }
          const int32_t x0 = static_cast<int32_t>(tx) * tile_px;
          if (x0 >= width) {
            break;
          }
          const size_t tile_row_bytes = static_cast<size_t>(
              std::min(tile_px, width - x0)) * 2u;
          const size_t byte_offset = static_cast<size_t>(x0) * 2u;
          if (std::memcmp(current + byte_offset, previous + byte_offset,
                          tile_row_bytes) != 0) {
            raw_changed_tiles_[tile_idx] = 1;
          }
        }
      }
      for (uint32_t ty = 0; ty < tile_rows; ++ty) {
        if (raw_changed_tile_rows_[ty] == 0) {
          std::fill_n(candidate_tiles_.begin() +
                          static_cast<std::ptrdiff_t>(ty * tile_cols),
                      tile_cols, uint8_t{0});
          continue;
        }
        const size_t tile_row_offset = static_cast<size_t>(ty) * tile_cols;
        for (uint32_t tx = 0; tx < tile_cols; ++tx) {
          const size_t tile_idx = tile_row_offset + tx;
          candidate_tiles_[tile_idx] = static_cast<uint8_t>(
              candidate_tiles_[tile_idx] & raw_changed_tiles_[tile_idx]);
        }
      }
    }
  }

  for (uint32_t tile_y = 0; tile_y < tile_rows; ++tile_y) {
    const uint8_t* row = &candidate_tiles_[tile_y * tile_cols];
    for (uint32_t tile_x = 0; tile_x < tile_cols; ++tile_x) {
      if (row[tile_x] != 0) {
        ++processed_tile_count_;
        process_tile(src, tile_x, tile_y, width, height, epoch, ledger,
                     previous_rgb565, previous_rgb565_stride,
                     compare_rgb565);
      }
    }
  }

  // Advance the exact source baseline only over tiles whose derived planes
  // were just verified. Raw-equal tiles rejected above already match it;
  // unnominated tiles intentionally retain their old bytes so a later broad
  // pass can only over-process, never skip an unverified change.
  if (!compare_rgb565 && can_retain_source &&
      retained_source_rgb565_.size() == retained_source_bytes) {
    if (full_surface_candidates &&
        processed_tile_count_ == candidate_tiles_.size()) {
      // Cold/rebaseline pass: one logical-row copy avoids tens of thousands
      // of tiny tile-row memcpys. Padding remains deliberately excluded.
      for (int32_t y = 0; y < height; ++y) {
        std::memcpy(retained_source_rgb565_.data() +
                        static_cast<size_t>(y) * retained_source_stride,
                    src.pixels + static_cast<size_t>(y) * src.stride_bytes,
                    retained_source_stride);
      }
    } else {
      const int32_t tile_px = static_cast<int32_t>(ledger->tile_px());
      for (uint32_t tile_y = 0; tile_y < tile_rows; ++tile_y) {
        const int32_t y0 = static_cast<int32_t>(tile_y) * tile_px;
        const int32_t y1 = std::min(y0 + tile_px, height);
        const size_t tile_row_offset = static_cast<size_t>(tile_y) * tile_cols;
        for (uint32_t tile_x = 0; tile_x < tile_cols; ++tile_x) {
          if (candidate_tiles_[tile_row_offset + tile_x] == 0) {
            continue;
          }
          const int32_t x0 = static_cast<int32_t>(tile_x) * tile_px;
          const int32_t x1 = std::min(x0 + tile_px, width);
          const size_t byte_offset = static_cast<size_t>(x0) * 2u;
          const size_t byte_count = static_cast<size_t>(x1 - x0) * 2u;
          for (int32_t y = y0; y < y1; ++y) {
            std::memcpy(retained_source_rgb565_.data() +
                            static_cast<size_t>(y) * retained_source_stride +
                            byte_offset,
                        src.pixels +
                            static_cast<size_t>(y) * src.stride_bytes +
                            byte_offset,
                        byte_count);
          }
        }
      }
    }
  }

  // Re-hash the full logical row of every row whose quantized bytes changed,
  // so hashes stay whole-row comparable for the scroll detector.
  // Untouched rows keep the values begin_pass() carried forward. Dirty rows
  // are hashed eight at a time (hash_rows_fnv1a_x8) to hide FNV-1a's serial
  // multiply latency; the per-row values are identical to hash_row_fnv1a.
  uint32_t* hashes = ledger->row_hash_cur();
  const uint8_t* l_cur = ledger->l_cur();
  const size_t stride = ledger->stride();
  const size_t row_bytes = ledger->width();
  const uint8_t* batch_rows[8];
  int32_t batch_y[8];
  int32_t nb = 0;
  for (int32_t y = 0; y < height; ++y) {
    if (dirty_rows_[static_cast<size_t>(y)] == 0) {
      continue;
    }
    batch_rows[nb] = l_cur + static_cast<size_t>(y) * stride;
    batch_y[nb] = y;
    if (++nb == 8) {
      uint32_t out8[8];
      hash_rows_fnv1a_x8(batch_rows, row_bytes, out8);
      for (int32_t k = 0; k < 8; ++k) {
        hashes[batch_y[k]] = out8[k];
      }
      nb = 0;
    }
  }
  for (int32_t k = 0; k < nb; ++k) {
    hashes[batch_y[k]] = hash_row_fnv1a(batch_rows[k], row_bytes);
  }
  if (full_surface_candidates) {
    retained_reject_ready_ = true;
    retained_source_ready_ =
        can_retain_source && !compare_rgb565 &&
        retained_source_rgb565_.size() == retained_source_bytes;
  }
  retained_reject_ledger_ = ledger;
  retained_reject_epoch_ = ledger->epoch();
  return records_.size();
}

void TilePass::ensure_capacity(const FrameLedger& ledger) {
  const size_t tiles = ledger.tile_count();
  if (candidate_tiles_.size() != tiles) {
    candidate_tiles_.assign(tiles, 0);
    records_.reserve(tiles);
  }
  if (raw_changed_tiles_.size() != tiles) {
    raw_changed_tiles_.assign(tiles, 0);
  }
  if (raw_changed_tile_rows_.size() != ledger.tile_rows()) {
    raw_changed_tile_rows_.assign(ledger.tile_rows(), 0);
  }
  if (dirty_rows_.size() != ledger.height()) {
    dirty_rows_.assign(ledger.height(), 0);
  }
}

void TilePass::mark_candidates(const PlutoRect* hints,
                               size_t hint_count,
                               int32_t width,
                               int32_t height,
                               const FrameLedger& ledger) {
  const int32_t tile_px = static_cast<int32_t>(ledger.tile_px());
  const uint32_t tile_cols = ledger.tile_cols();
  const PlutoRect surface{0, 0, width, height};
  if (hints == nullptr || hint_count == 0) {
    // No hints: verify the whole surface (over-reporting is safe; the
    // byte-diff is truth).
    hints = &surface;
    hint_count = 1;
  }
  for (size_t i = 0; i < hint_count; ++i) {
    const PlutoRect rect = rect_clip(hints[i], width, height);
    if (rect_is_empty(rect)) {
      continue;
    }
    const uint32_t tx0 = static_cast<uint32_t>(rect.x / tile_px);
    const uint32_t ty0 = static_cast<uint32_t>(rect.y / tile_px);
    const uint32_t tx1 = static_cast<uint32_t>((rect_right(rect) - 1) / tile_px);
    const uint32_t ty1 =
        static_cast<uint32_t>((rect_bottom(rect) - 1) / tile_px);
    for (uint32_t ty = ty0; ty <= ty1; ++ty) {
      std::fill_n(&candidate_tiles_[ty * tile_cols + tx0], tx1 - tx0 + 1,
                  uint8_t{1});
    }
  }
}

void TilePass::process_tile(const PlutoSurface& src,
                            uint32_t tile_x,
                            uint32_t tile_y,
                            int32_t width,
                            int32_t height,
                            uint32_t epoch,
                            FrameLedger* ledger,
                            const uint8_t* previous_rgb565,
                            size_t previous_rgb565_stride,
                            bool compare_rgb565) {
  const int32_t tile_px = static_cast<int32_t>(ledger->tile_px());
  const int32_t x0 = static_cast<int32_t>(tile_x) * tile_px;
  const int32_t y0 = static_cast<int32_t>(tile_y) * tile_px;
  const int32_t x1 = std::min(x0 + tile_px, width);
  const int32_t y1 = std::min(y0 + tile_px, height);
  if (x0 >= x1 || y0 >= y1) {
    return;
  }
  const int32_t w = x1 - x0;

  uint8_t chroma[FrameLedger::kMaxTilePx];
  uint8_t thr_scratch[FrameLedger::kMaxTilePx];
  // Per-tile stores. Significance is a pure function of continuous-tone luma
  // vs the OLD settled plane, and the level histogram of the quantized levels;
  // both feed ONLY the emitted TileStats, which exist for dirty tiles. So the
  // pass runs diff-first (Pass A, every candidate row) and defers significance
  // + histogram + the write-through to dirty tiles (Pass B). A clean candidate
  // tile — the common case when the whole surface is verified against small
  // real damage — never pays for them. Luma is NOT staged: Pass B recomputes
  // it from the (still L1-warm) source rows of the dirty tile, which spares
  // every clean tile one store per pixel. All luma kernels are byte-exact
  // implementations of the same pure function of the pixel (golden-pinned),
  // so the recomputed bytes are identical to the staged ones. Chroma bits and
  // stats are byte-identical to the single-pass form (accumulations are
  // order-independent; the diff and its bounds are unchanged; the
  // write-through is deferred but reads/writes the same OLD plane because
  // Pass A does not memcpy).
  uint8_t luma_row[FrameLedger::kMaxTilePx];
  uint8_t lvl_tile[FrameLedger::kMaxTilePx * FrameLedger::kMaxTilePx];
  bool row_dirty[FrameLedger::kMaxTilePx] = {};
#if defined(__ARM_NEON) && defined(__aarch64__)
  RowMeta row_meta[FrameLedger::kMaxTilePx] = {};
#endif

  const size_t bpp = format_bytes_per_pixel(src.format);
  const uint8_t* src_base = src.pixels;
  uint8_t* l_cur = ledger->l_cur();
  const size_t stride = ledger->stride();
  uint8_t* chroma_bits = ledger->chroma_bits();
  const size_t chroma_stride = ledger->chroma_stride();
  const size_t sw = static_cast<size_t>(w);

  uint32_t changed = 0;
  uint32_t sad = 0;
  uint8_t max_diff = 0;
  uint16_t hist = 0;
  uint32_t chroma_count = 0;
  bool changed_chroma = false;
  int32_t min_x = x1;
  int32_t max_x = x0 - 1;
  int32_t min_y = y1;
  int32_t max_y = y0 - 1;

  // Pass A: extract, dither/quantize, write chroma, and post-quantize diff.
#if defined(__ARM_NEON) && defined(__aarch64__)
  if (src.format == kPlutoPixelFormatRgb565) {
    // One fused traversal of the whole tile: extract, quantize/dither, chroma
    // bits+count, and the post-quantize diff — source read once, not five
    // times, with the mask tables hoisted to a single load per tile. The
    // 32-px-wide specialization covers every interior tile of the default
    // grid; ragged right-edge tiles take the dynamic form.
    FusedTileStats ts;
    if (w == 32) {
      // Pick the fast-path instantiation only when the tile plausibly has
      // uniform rows: sample the first and middle rows' opening pixel pairs
      // (the same ~2-op prefilter the row loop uses). Flat and mixed tiles
      // hit it; textured tiles run the pristine call-free loop. Both
      // instantiations are byte-identical — the sample only routes work.
      const uint16_t* row_a = reinterpret_cast<const uint16_t*>(
          src_base + static_cast<size_t>(y0) * src.stride_bytes +
          static_cast<size_t>(x0) * 2u);
      const uint16_t* row_b = reinterpret_cast<const uint16_t*>(
          src_base + static_cast<size_t>(y0 + ((y1 - y0) >> 1)) *
                         src.stride_bytes +
          static_cast<size_t>(x0) * 2u);
      const bool try_uniform = row_a[0] == row_a[1] || row_b[0] == row_b[1];
      ts = try_uniform
               ? fused_pass_a_tile_rgb565<32, true>(
                     src_base, src.stride_bytes, x0, y0, x1, y1, w, l_cur,
                     stride, chroma_bits, chroma_stride, lvl_tile, sw,
                     config_.chroma_floor, dirty_rows_.data(), row_dirty,
                     row_meta, previous_rgb565, previous_rgb565_stride,
                     compare_rgb565)
               : fused_pass_a_tile_rgb565<32, false>(
                     src_base, src.stride_bytes, x0, y0, x1, y1, w, l_cur,
                     stride, chroma_bits, chroma_stride, lvl_tile, sw,
                     config_.chroma_floor, dirty_rows_.data(), row_dirty,
                     row_meta, previous_rgb565, previous_rgb565_stride,
                     compare_rgb565);
    } else {
      ts = fused_pass_a_tile_rgb565<0, false>(
          src_base, src.stride_bytes, x0, y0, x1, y1, w, l_cur, stride,
          chroma_bits, chroma_stride, lvl_tile, sw, config_.chroma_floor,
          dirty_rows_.data(), row_dirty, row_meta, previous_rgb565,
          previous_rgb565_stride, compare_rgb565);
    }
    changed = ts.changed;
    chroma_count = ts.chroma_count;
    changed_chroma = ts.changed_chroma;
    min_x = ts.min_x;
    max_x = ts.max_x;
    min_y = ts.min_y;
    max_y = ts.max_y;
  } else
#endif
  for (int32_t y = y0; y < y1; ++y) {
    const int32_t r = y - y0;
    uint8_t* luma = luma_row;
    uint8_t* lvl = lvl_tile + static_cast<size_t>(r) * sw;
    const uint8_t* src_row = src_base +
                             static_cast<size_t>(y) * src.stride_bytes +
                             static_cast<size_t>(x0) * bpp;
    const uint8_t* thr = bluenoise_threshold_span(x0, y, sw, thr_scratch);
    // OLD plane bytes for this row's tile span; must survive for Pass B.
    const uint8_t* dst = l_cur + static_cast<size_t>(y) * stride + x0;
    const uint8_t* previous_row =
        previous_rgb565 == nullptr
            ? nullptr
            : previous_rgb565 +
                  static_cast<size_t>(y) * previous_rgb565_stride +
                  static_cast<size_t>(x0) * 2u;
    const uint8_t* old_chroma_row =
        chroma_bits + static_cast<size_t>(y) * chroma_stride + (x0 >> 3);
    uint8_t old_chroma_bytes[FrameLedger::kMaxTilePx / 8];
    std::memcpy(old_chroma_bytes, old_chroma_row,
                static_cast<size_t>((w + 7) >> 3));
    if (src.format == kPlutoPixelFormatRgb565) {
      luma_chroma_from_rgb565(reinterpret_cast<const uint16_t*>(src_row), sw,
                              luma, chroma);
    } else {
      luma_span_for_format(src.format, src_row, sw, luma);
      chroma_span_for_format(src.format, src_row, sw, chroma);
    }
    chroma_count += count_above_span(chroma, config_.chroma_floor, sw);

    quantize16_span(luma, thr, sw, lvl);

    // Post-quantize byte diff vs the OLD plane is the damage truth. No
    // write-through here — the old bytes must survive for Pass B's
    // significance.
    SpanDiff diff{};
    if (compare_rgb565) {
      diff.first = w;
      diff.last = -1;
      const uint16_t* rgb = reinterpret_cast<const uint16_t*>(src_row);
      const uint16_t* previous =
          reinterpret_cast<const uint16_t*>(previous_row);
      for (int32_t x = 0; x < w; ++x) {
        const bool raw_changed =
            previous == nullptr || rgb[x] != previous[x];
        if (lvl[x] == dst[x] && !raw_changed) {
          continue;
        }
        ++diff.changed;
        diff.first = std::min(diff.first, x);
        diff.last = x;
      }
    } else {
      diff = diff_span(lvl, dst, sw);
    }
    if (diff.changed != 0) {
      if (compare_rgb565 && previous_row == nullptr) {
        changed_chroma = true;
      }
      if (!changed_chroma) {
        const uint16_t* rgb = reinterpret_cast<const uint16_t*>(src_row);
        const uint16_t* previous =
            reinterpret_cast<const uint16_t*>(previous_row);
        for (int32_t x = diff.first; x <= diff.last; ++x) {
          const bool raw_changed =
              compare_rgb565 &&
              (previous == nullptr || rgb[x] != previous[x]);
          if (lvl[x] == dst[x] && !raw_changed) {
            continue;
          }
          const uint8_t mask =
              static_cast<uint8_t>(1u << static_cast<uint32_t>(x & 7));
          const bool was_chroma =
              (old_chroma_bytes[x >> 3] & mask) != 0;
          if (was_chroma || chroma[x] > config_.chroma_floor) {
            changed_chroma = true;
            break;
          }
        }
      }
      changed += diff.changed;
      min_x = std::min(min_x, x0 + diff.first);
      max_x = std::max(max_x, x0 + diff.last);
      min_y = std::min(min_y, y);
      max_y = y;
      dirty_rows_[static_cast<size_t>(y)] = 1;
      row_dirty[r] = true;
    }
    write_chroma_row(chroma_bits + static_cast<size_t>(y) * chroma_stride, x0,
                     chroma, w, config_.chroma_floor);
  }

  if (changed == 0) {
    return;
  }

  // Pass B (dirty tile only): pre-dither significance vs the still-old plane,
  // level histogram, then the write-through. Luma is recomputed from the
  // source rows (byte-identical: every luma kernel implements the same pure
  // function of the pixel), which keeps Pass A store-free for it.
#if defined(__ARM_NEON) && defined(__aarch64__)
  if (src.format == kPlutoPixelFormatRgb565) {
    // Fused single-walk Pass B (see fused_pass_b_rgb565); rows Pass A proved
    // uniform+clean fold to O(1) via row_meta.
    const PassBStats pb =
        fused_pass_b_rgb565(src_base, src.stride_bytes, x0, y0, y1, w, l_cur,
                            stride, lvl_tile, sw, row_meta, row_dirty);
    sad = pb.sad;
    max_diff = pb.max_diff;
    hist = pb.hist;
  } else
#endif
  for (int32_t y = y0; y < y1; ++y) {
    const int32_t r = y - y0;
    const uint8_t* lvl = lvl_tile + static_cast<size_t>(r) * sw;
    const uint8_t* src_row = src_base +
                             static_cast<size_t>(y) * src.stride_bytes +
                             static_cast<size_t>(x0) * bpp;
    uint8_t* dst = l_cur + static_cast<size_t>(y) * stride + x0;
    luma_span_for_format(src.format, src_row, sw, luma_row);
    const SpanSignificance sig = significance_span(luma_row, dst, sw);
    sad += sig.sad;
    max_diff = std::max(max_diff, sig.max_diff);
    hist |= level_hist_bits_span(lvl, sw);
    if (row_dirty[r]) {
      std::memcpy(dst, lvl, sw);
    }
  }

  TileStats stats;
  stats.changed_px = static_cast<uint16_t>(changed);
  stats.sad_pre_dither =
      static_cast<uint16_t>(std::min<uint32_t>(sad, 0xffffu));
  stats.max_diff = max_diff;
  stats.level_hist = hist;
  // Rails {0, 10, 20, 30} live at level-index bits {0, 5, 10, 15}.
  stats.level_hist_lo = static_cast<uint8_t>(
      (hist & 1u) | (((hist >> 5u) & 1u) << 1u) | (((hist >> 10u) & 1u) << 2u) |
      (((hist >> 15u) & 1u) << 3u));
  const uint32_t area = static_cast<uint32_t>(w) * static_cast<uint32_t>(y1 - y0);
  stats.chroma_frac =
      static_cast<uint8_t>((chroma_count * 255u + area / 2u) / area);
  stats.motion_class = kMotionUnknown;
  stats.changed_chroma = changed_chroma ? 1u : 0u;
  stats.dirty = PlutoRect{min_x, min_y, max_x - min_x + 1, max_y - min_y + 1};
  stats.epoch = epoch;

  const uint32_t tile_idx = ledger->tile_index(tile_x, tile_y);
  ledger->stats()[tile_idx] = stats;
  records_.push_back(DirtyTileRecord{tile_idx, stats.dirty, stats});
  dirty_bounds_ = rect_union(dirty_bounds_, stats.dirty);
}

}  // namespace pluto
