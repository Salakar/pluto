#ifndef PLUTO_RENDERER_GALLERY3_H_
#define PLUTO_RENDERER_GALLERY3_H_

#include <array>
#include <cstddef>
#include <cstdint>

#include "renderer/bluenoise_64.h"

namespace pluto {

// Interim Gallery-3 (CMYW) palette quantizer (doc 03 section 7.4).
//
// The Move/Pro panel holds four pigments per pixel (cyan, magenta, yellow,
// white); every stable per-pixel state is a pigment stack, and "20,000
// colors" marketing is spatial dithering across those states. Until the
// GAL3_*.eink waveform reverse-engineering pins the true achievable state
// set, this ships the conservative interim palette of the four primaries
// plus their stacked dither mixes
// (white, black, cyan, magenta, yellow, red, green, blue).
//
// Mapping is ordered palette dithering: the input color is offset by the
// blue-noise threshold at its absolute panel coordinates, then snapped to the
// nearest palette entry through a precomputed 17^3 lattice LUT. Output
// depends only on (pixel value, absolute coordinates), so the mapping is
// rect-local-safe by construction (doc 03 section 7.2).

namespace gallery3_detail {

// Dither offset range around the input color before palette lookup. Wide
// enough that blue-noise mixes adjacent primaries into intermediate shades.
constexpr int k_dither_spread = 128;

// Near-neutral inputs skip the palette LUT and render as full-range
// black/white spatial dithering — the only way an 8-entry palette with no
// intermediate grays can show a smooth gray ramp.
constexpr int k_neutral_max_channel_delta = 32;

struct Rgb888 {
  uint8_t r;
  uint8_t g;
  uint8_t b;
};

// Conservative pigment-state palette. Values approximate the muted Gallery-3
// pigment appearance for host preview; they are placeholders until the GAL3
// waveform reverse-engineering provides measured primaries (OPEN P1 R-Q5).
inline constexpr std::array<Rgb888, 8> k_entries = {{
    {0, 0, 0},        // black (all pigments stacked)
    {255, 255, 255},  // white
    {0, 200, 220},    // cyan
    {200, 0, 130},    // magenta
    {235, 200, 0},    // yellow
    {210, 40, 40},    // red   (magenta + yellow)
    {50, 160, 70},    // green (cyan + yellow)
    {40, 70, 180},    // blue  (cyan + magenta)
}};

// Compile-time RGB888->RGB565 (identical bit math to quantize.cc
// rgb888_to_rgb565), so the palette-entry table is a constexpr with static
// storage — no function-local magic-static guard is taken on the per-pixel
// hot path that returns an entry.
constexpr uint16_t to_rgb565(uint8_t r, uint8_t g, uint8_t b) {
  return static_cast<uint16_t>(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

inline constexpr std::array<uint16_t, 8> k_entries_565 = [] {
  std::array<uint16_t, 8> out{};
  for (size_t i = 0; i < out.size(); ++i) {
    out[i] = to_rgb565(k_entries[i].r, k_entries[i].g, k_entries[i].b);
  }
  return out;
}();

// Fused clamp + lattice-quantize table for the chromatic dither path.
// The dithered channel value is base(0..255) + offset, where the shared
// offset = ((noise-127) * k_dither_spread) >> 8 spans [-64, 64] for
// noise in [0, 255], so base+offset spans [-64, 319]. Indexing by
// (base+offset+64) yields lattice_coord(clamp(base+offset, 0, 255)) with no
// per-pixel clamp or /255, byte-identical to the reference arithmetic.
constexpr int k_latclamp_bias = 64;
inline constexpr std::array<uint8_t, 384> k_latclamp = [] {
  std::array<uint8_t, 384> t{};
  for (int i = 0; i < 384; ++i) {
    const int v = i - k_latclamp_bias;
    const int c = v < 0 ? 0 : (v > 255 ? 255 : v);
    t[i] = static_cast<uint8_t>((c * 16 + 127) / 255);
  }
  return t;
}();

// All per-pixel tables fused into ONE block so the compiler materializes a
// single base address (one adrp+add) and reaches every table with an
// immediate offset — instead of one adrp/add pair per table plus a GOT load
// for the inline-constexpr blue-noise mask. Every entry is a pure
// precomputation of the reference arithmetic (proof notes inline), so the
// per-pixel result is byte-identical.
//   lat289 / lat17: k_latclamp pre-scaled by the lattice strides, so the 3-D
//   LUT index (rc * 17 + gc) * 17 + bc == rc * 289 + gc * 17 + bc is a sum of
//   three table loads with no per-pixel multiplies (max 4624 / 272 -> u16).
//   lat: k_latclamp verbatim (b channel).
//   noise_off: per mask position, the FULL chromatic dither offset
//     ((noise - 127) * k_dither_spread >> 8) + k_latclamp_bias, range [0, 128].
//   neutral_thresh: per mask position, the white/black decision threshold on
//     the undivided luma numerator a = 100 * luma + rem (rem in [0, 99]):
//     white <=> luma == 255 (fixed point) OR luma > noise
//            <=> a >= 25500 OR a >= 100 * (noise + 1)   [a <= 25550]
//            <=> a >= min(25500, 100 * noise + 100).
//   a_r/a_g/a_b: per raw 5/6-bit channel field, the luma_of() numerator terms
//   30 * r8 + 50 / 59 * g8 / 11 * b8 for the bit-replicated channel bytes
//   (max sum 25550, u16).
//   neutral_bits: is_near_neutral() of the bit-replicated channel bytes,
//   precomputed for every rgb565 value (bit (v & 7) of byte (v >> 3)).
struct Gallery3HotTables {
  std::array<uint16_t, 384> lat289;
  std::array<uint16_t, 384> lat17;
  std::array<uint8_t, 384> lat;
  std::array<uint16_t, 32> a_r;
  std::array<uint16_t, 64> a_g;
  std::array<uint16_t, 32> a_b;
  std::array<uint8_t, 4096> noise_off;
  std::array<uint16_t, 4096> neutral_thresh;
};
inline constexpr Gallery3HotTables k_hot = [] {
  Gallery3HotTables t{};
  for (int i = 0; i < 384; ++i) {
    t.lat289[i] = static_cast<uint16_t>(k_latclamp[i] * 289);
    t.lat17[i] = static_cast<uint16_t>(k_latclamp[i] * 17);
    t.lat[i] = k_latclamp[i];
  }
  for (int r5 = 0; r5 < 32; ++r5) {
    t.a_r[r5] = static_cast<uint16_t>(30 * ((r5 << 3) | (r5 >> 2)) + 50);
    t.a_b[r5] = static_cast<uint16_t>(11 * ((r5 << 3) | (r5 >> 2)));
  }
  for (int g6 = 0; g6 < 64; ++g6) {
    t.a_g[g6] = static_cast<uint16_t>(59 * ((g6 << 2) | (g6 >> 4)));
  }
  for (int i = 0; i < 4096; ++i) {
    const int noise = k_blue_noise_64[i];
    t.noise_off[i] = static_cast<uint8_t>(
        (((noise - 127) * k_dither_spread) >> 8) + k_latclamp_bias);
    const int thresh = 100 * noise + 100;
    t.neutral_thresh[i] =
        static_cast<uint16_t>(thresh < 25500 ? thresh : 25500);
  }
  return t;
}();

// Separate constexpr object (its own constant-evaluation step budget — the
// 65536-value loop blows the per-expression limit if fused into k_hot).
// Manual max/min keeps the step count per value tiny; the predicate is
// exactly is_near_neutral() of the bit-replicated channel bytes.
inline constexpr std::array<uint8_t, 8192> k_neutral_bits = [] {
  std::array<uint8_t, 8192> bits{};
  for (uint32_t v = 0; v < 65536; ++v) {
    const int r5 = static_cast<int>((v >> 11) & 0x1f);
    const int g6 = static_cast<int>((v >> 5) & 0x3f);
    const int b5 = static_cast<int>(v & 0x1f);
    const int r8 = (r5 << 3) | (r5 >> 2);
    const int g8 = (g6 << 2) | (g6 >> 4);
    const int b8 = (b5 << 3) | (b5 >> 2);
    int mx = r8 > g8 ? r8 : g8;
    mx = b8 > mx ? b8 : mx;
    int mn = r8 < g8 ? r8 : g8;
    mn = b8 < mn ? b8 : mn;
    if (mx - mn <= k_neutral_max_channel_delta) {
      bits[v >> 3] = static_cast<uint8_t>(bits[v >> 3] | (1u << (v & 7u)));
    }
  }
  return bits;
}();

}  // namespace gallery3_detail

class Gallery3Palette {
 public:
  static constexpr size_t k_entry_count = 8;

  Gallery3Palette();

  // Shared immutable instance (LUT built once).
  static const Gallery3Palette& instance();

  // Maps one RGB565 pixel to the nearest dithered palette entry, as RGB565.
  // Defined inline: every production caller (abi_bridge color path, tile
  // paths, benches) loops it per pixel, so the call/ret plus the blocked
  // hoisting of the (absolute_y & 63) * 64 mask-row term were pure overhead.
  // The body and tables are byte-for-byte the same arithmetic as the
  // out-of-line Round-2 version (proof notes on the tables above).
  uint16_t map_rgb565(uint16_t rgb565,
                      int32_t absolute_x,
                      int32_t absolute_y) const {
    namespace det = gallery3_detail;
    const uint32_t pos = (static_cast<uint32_t>(absolute_y) & 63u) * 64u +
                         (static_cast<uint32_t>(absolute_x) & 63u);
    const uint32_t v = rgb565;
    if ((det::k_neutral_bits[v >> 3] >> (v & 7u)) & 1u) {
      // Grays render as black/white spatial mixes across the full range; the
      // blue-noise threshold is the classic full-spread ordered dither.
      // Pure white is a FIXED POINT: `luma > noise` alone drops black specks
      // into 255-luma content wherever the mask holds 255, so a Full-class
      // pass over paper-white would pepper it — and the settled picture would
      // depend on which exact rects each policy flashed. Pure black already
      // holds (0 > noise is never true). Both rules are folded into
      // neutral_thresh (see the table proof above): white <=> the undivided
      // luma numerator a >= min(25500, 100 * noise + 100).
      const uint32_t a =
          static_cast<uint32_t>(det::k_hot.a_r[(v >> 11) & 0x1f]) +
          static_cast<uint32_t>(det::k_hot.a_g[(v >> 5) & 0x3f]) +
          static_cast<uint32_t>(det::k_hot.a_b[v & 0x1f]);
      return a >= det::k_hot.neutral_thresh[pos] ? det::k_entries_565[1]
                                                 : det::k_entries_565[0];
    }
    // Ordered palette dithering: one shared luminance-axis offset keeps hue
    // stable while blue noise mixes neighboring entries spatially. The fused
    // k_latclamp tables absorb the clamp, the lattice quantisation, AND the
    // (rc * 17 + gc) * 17 + bc index arithmetic; lut565_ folds the palette
    // entry lookup; noise_off carries the precomputed dither offset — the
    // pixel is the channel expansions, four table loads, and three adds.
    const int r5 = static_cast<int>((v >> 11) & 0x1f);
    const int g6 = static_cast<int>((v >> 5) & 0x3f);
    const int b5 = static_cast<int>(v & 0x1f);
    const uint32_t r8 = static_cast<uint32_t>((r5 << 3) | (r5 >> 2));
    const uint32_t g8 = static_cast<uint32_t>((g6 << 2) | (g6 >> 4));
    const uint32_t b8 = static_cast<uint32_t>((b5 << 3) | (b5 >> 2));
    const uint32_t offset = det::k_hot.noise_off[pos];
    const uint32_t idx =
        static_cast<uint32_t>(det::k_hot.lat289[r8 + offset]) +
        static_cast<uint32_t>(det::k_hot.lat17[g8 + offset]) +
        static_cast<uint32_t>(det::k_hot.lat[b8 + offset]);
    return lut565_[idx];
  }

  // Nearest palette entry for an exact color (no dither offset).
  uint8_t nearest_index(uint8_t r, uint8_t g, uint8_t b) const;

  // Palette entries encoded as RGB565, for presenters and tests.
  static const std::array<uint16_t, k_entry_count>& entries_rgb565();

 private:
  static constexpr uint32_t k_lattice = 17;

  // lut_ pre-composed through entries_rgb565(): lut565_[i] ==
  // entries_rgb565()[lut_[i]]. Collapses the hot path's two dependent loads
  // (index -> entry) into one; 9.8 KB, L1/L2 resident. First member so the
  // per-pixel load addresses straight off `this` with a small immediate
  // offset (idx * 2 stays under the ldrh immediate range).
  std::array<uint16_t, k_lattice * k_lattice * k_lattice> lut565_{};
  std::array<uint8_t, k_lattice * k_lattice * k_lattice> lut_{};
};

}  // namespace pluto

#endif  // PLUTO_RENDERER_GALLERY3_H_
