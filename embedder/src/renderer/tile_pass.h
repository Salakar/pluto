#ifndef PLUTO_RENDERER_TILE_PASS_H_
#define PLUTO_RENDERER_TILE_PASS_H_

#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

#include "pluto/presenter.h"
#include "renderer/frame_ledger.h"
#include "renderer/renderer_config.h"

namespace pluto {

// One dirty tile out of a pass: exact post-quantize damage plus the stats
// snapshot taken at that epoch. This is the record shape the damage mailbox
// carries to the scheduler thread (the payload snapshot itself is added when
// the mailbox lands in a later stage).
struct DirtyTileRecord {
  uint32_t tile_idx = 0;
  PlutoRect dirty{0, 0, 0, 0};  // absolute px, exact post-quantize
  TileStats stats{};
};

// TilePass: the fused consume -> quantize -> dither -> diff -> stats
// traversal over damaged 32x32 tiles. Runs on the raster thread inside
// submit_frame; single traversal, write-through into the FrameLedger's
// L_cur.
//
// Contracts:
//   * Trust-but-verify: damage hints (Flutter paint bounds) only nominate
//     candidate tiles; the post-quantize byte diff is truth. Over-reported
//     hints cost cycles, never correctness. No hints (null/0) means "verify
//     the whole surface" — the cheap idle gate (did_update) is the caller's.
//   * Diff-after-quantize: a sub-quantum RGB change quantizes to identical
//     levels and produces ZERO dirty tiles (phantom damage vanishes).
//   * Rect-local determinism: every kernel is a pure function of (pixel
//     value, absolute panel coordinates), so processing any candidate set
//     yields bytes identical to processing the full frame and cropping.
//   * Significance (sad/max_diff) is computed on PRE-dither continuous-tone
//     luma vs the dequantized old plane; the diff runs AFTER quantization.
//
// Supported source formats: RGB565 (device), XRGB8888 (host preview,
// memory bytes [x, r, g, b]), Gray8 (luma pass-through, zero chroma).
//
// Hot-path allocation: none. Scratch (candidate/raw-change bitmaps, dirty-row
// bitmap, records storage) is grown only when the ledger geometry changes;
// run() reuses it thereafter.
class TilePass {
 public:
  TilePass() = default;
  explicit TilePass(const RendererConfig& config) : config_(config) {}

  void set_config(const RendererConfig& config) {
    config_ = config;
    // Derived chroma/dither state may change even when the retained RGB bytes
    // do not. One complete traversal must establish the new configuration
    // before raw equality can reject candidates again.
    retained_reject_ready_ = false;
  }
  const RendererConfig& config() const { return config_; }

  // Admits an imported, correlated RGB565 mirror as exact proof for the
  // current ledger epoch. The caller retains ownership of the mirror and
  // must still pass it to run(); TilePass stores no pointer or pixel copy.
  // Exact logical stride/size are required so padded or truncated handoff
  // payloads cannot enable broad-candidate rejection.
  bool admit_exact_rgb565_baseline(const FrameLedger &ledger,
                                   std::span<const uint8_t> rgb565,
                                   size_t stride);

  // Conservatively drops every retained-source proof. Use when a correlated
  // import is rolled back or any other operation makes the ledger/mirror
  // relationship uncertain.
  void invalidate_exact_rgb565_baseline();

  // Runs one fused pass of `src` against `ledger`. Returns the number of
  // dirty tiles found (== dirty_tiles().size()). Processing is clipped to
  // the intersection of the surface and ledger geometries. Returns 0 without
  // touching the ledger for invalid inputs (null pixels, invalid ledger,
  // unsupported format). When `compare_rgb565` is true, RGB565 source pixels
  // are also compared with the previous engine-true mirror: raw color changes
  // remain damage even when their quantized luma is identical. A null/invalid
  // previous mirror in that mode means its color is unknown, so every candidate
  // RGB565 pixel establishes color truth and any resulting record is marked
  // color-sensitive (the conservative first-frame/handoff contract). A
  // non-null previous mirror is the exact engine-true content corresponding
  // to the current ledger; broad candidates may therefore be narrowed to the
  // exact tile rows AND tile columns containing raw changes without changing
  // ledger output.
  size_t run(const PlutoSurface& src,
             const PlutoRect* damage_hints,
             size_t hint_count,
             FrameLedger* ledger,
             const uint8_t* previous_rgb565 = nullptr,
             size_t previous_rgb565_stride = 0,
             bool compare_rgb565 = false);

  // Records from the most recent run(), tile-row-major; valid until the
  // next run() call.
  const std::vector<DirtyTileRecord>& dirty_tiles() const { return records_; }

  // Number of candidate tiles actually submitted to the fused kernels by the
  // most recent run(). This is diagnostic rather than damage truth (clean
  // candidates produce no DirtyTileRecord), and pins retained-mirror
  // narrowing in tests/benchmarks without timing-dependent assertions.
  size_t processed_tile_count() const { return processed_tile_count_; }

  // Union of the exact dirty rects of the most recent run() (empty when no
  // tile changed).
  PlutoRect dirty_bounds() const { return dirty_bounds_; }

 private:
  void ensure_capacity(const FrameLedger& ledger);
  void mark_candidates(const PlutoRect* hints,
                       size_t hint_count,
                       int32_t width,
                       int32_t height,
                       const FrameLedger& ledger);
  void process_tile(const PlutoSurface& src,
                    uint32_t tile_x,
                    uint32_t tile_y,
                    int32_t width,
                    int32_t height,
                    uint32_t epoch,
                    FrameLedger* ledger,
                    const uint8_t* previous_rgb565,
                    size_t previous_rgb565_stride,
                    bool compare_rgb565);

  RendererConfig config_{};
  const FrameLedger* retained_reject_ledger_ = nullptr;
  uint32_t retained_reject_epoch_ = 0;
  bool retained_reject_ready_ = false;
  bool retained_source_ready_ = false;
  size_t processed_tile_count_ = 0;
  std::vector<DirtyTileRecord> records_;
  std::vector<uint8_t> candidate_tiles_;
  std::vector<uint8_t> raw_changed_tiles_;
  std::vector<uint8_t> raw_changed_tile_rows_;
  // Exact logical-row RGB565 baseline for callers that do not already own a
  // retained engine-color mirror. It is only a collision-free broad-candidate
  // rejection aid: every byte-different tile still runs the ordinary fused
  // kernels, which remain the sole damage/chroma/stat authority.
  std::vector<uint8_t> retained_source_rgb565_;
  std::vector<uint8_t> dirty_rows_;
  PlutoRect dirty_bounds_{0, 0, 0, 0};
};

}  // namespace pluto

#endif  // PLUTO_RENDERER_TILE_PASS_H_
