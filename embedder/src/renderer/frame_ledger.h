#ifndef PLUTO_RENDERER_FRAME_LEDGER_H_
#define PLUTO_RENDERER_FRAME_LEDGER_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "pluto/presenter.h"
#include "renderer/kernels.h"

namespace pluto {

// Geometry defaults are the panel constants: 954x1696 logical px, padded
// plane stride 960, 30x53 = 1590 tiles of 32x32. Any smaller/other geometry
// (host tests, future panels) gets a computed grid.
struct FrameLedgerConfig {
  uint32_t width = 954;
  uint32_t height = 1696;
  // Must be a multiple of 8 (chroma bitplane rows stay byte-aligned per
  // tile column) and at most FrameLedger::kMaxTilePx.
  uint32_t tile_px = 32;
};

// TileStats.motion_class values. Stage 1 always writes kMotionUnknown; the
// EPZS-lite classifier (Stage 6) refines lazily.
inline constexpr uint8_t kMotionUnknown = 0;
inline constexpr uint8_t kMotionStatic = 1;
inline constexpr uint8_t kMotionTranslating = 2;
inline constexpr uint8_t kMotionChaotic = 3;

// Per-tile significance record (32 B). Written only by the raster thread
// (TilePass); downstream consumers receive copies inside DirtyTileRecord via
// the damage mailbox.
struct TileStats {
  uint16_t changed_px = 0;     // post-quantize diff count
  uint16_t sad_pre_dither = 0; // saturating; significance on continuous tone
  uint8_t max_diff = 0;        // pre-dither max |delta luma|
  uint8_t level_hist_lo = 0;   // presence of rails {0,10,20,30} (DU/DU4 test)
  uint16_t level_hist = 0;     // 16-bucket presence bits (bit i: level 2*i)
  uint8_t chroma_frac = 0;     // /255 fraction of chroma pixels in the tile
  uint8_t motion_class = 0;    // kMotion*; STATIC/TRANSLATING/CHAOTIC later
  // True when at least one pixel counted by changed_px carried chroma either
  // before or after this pass. Unlike chroma_frac this is transition-local:
  // static color elsewhere in the tile cannot promote unrelated gray damage,
  // and erasing a colored pixel remains color-sensitive after its current
  // chroma bit has cleared. Unknown prior RGB is conservatively color-sensitive
  // because old pigment cannot be disproved. Occupies existing alignment
  // padding (ABI stays 32B).
  uint8_t changed_chroma = 0;
  PlutoRect dirty{0, 0, 0, 0}; // exact sub-tile dirty rect (absolute px)
  uint32_t epoch = 0;          // pass epoch of last post-quantize change
};
static_assert(sizeof(TileStats) == 32, "TileStats must stay 32 bytes");

// Pointer-free, fixed-width snapshot of every persistent FrameLedger plane.
// The containing handoff bundle owns serialization; this type deliberately
// exposes logical vectors instead of object bytes so padding and allocator
// state never become part of the cross-process contract.
struct FrameLedgerState {
  FrameLedgerConfig config{};
  uint64_t stride = 0;
  uint64_t chroma_stride = 0;
  uint32_t epoch = 0;
  uint32_t cur_hash = 0;
  std::vector<uint8_t> levels;
  std::vector<uint8_t> chroma_bits;
  std::array<std::vector<uint32_t>, 2> row_hash;
  std::vector<uint8_t> row_samples;
  std::vector<uint32_t> row_sample_epoch;
  std::vector<TileStats> stats;
};

// FrameLedger: the renderer-side authoritative quantized state.
//
//   * L_cur — settled-quality 5-bit levels, 16-level blue-noise dithered,
//     position-keyed. Rail (A2/DU) targets are NOT stored here; they are
//     derived at admission by a pure position-keyed threshold (Stage 4), so
//     the diff stays class-independent and GC16 settles restore true grays.
//   * chroma bitplane — 1 bpp "pixel carries chroma above the floor".
//   * row-hash ping-pong — whole-row FNV-1a hashes of L_cur for the Stage-6
//     scroll detector; begin_pass() flips and carries them forward.
//   * TileStats[tile_count] — per-tile significance, epoch-stamped.
//
// Threading (normative): single writer — the raster thread via TilePass.
// No internal locking; nothing else may touch the planes while a pass runs.
// Downstream threads consume the dirty-tile records the pass emits (payload
// copies), never these planes directly, until the zero-copy endgame.
class FrameLedger {
public:
  static constexpr uint32_t kMaxTilePx = 64;
  FrameLedger() = default;
  explicit FrameLedger(const FrameLedgerConfig &config) { configure(config); }

  // Allocates planes for the given geometry and invalidates them. Returns
  // false (and leaves the ledger invalid) for unusable geometry: zero
  // dimensions, tile_px == 0, tile_px > kMaxTilePx, or tile_px % 8 != 0.
  bool configure(const FrameLedgerConfig &config);
  bool valid() const { return valid_; }

  // -- geometry --------------------------------------------------------
  uint32_t width() const { return width_; }
  uint32_t height() const { return height_; }
  uint32_t tile_px() const { return tile_px_; }
  // L_cur row stride in bytes: tile_cols * tile_px (954 -> 960 at 32 px —
  // the padded plane stride).
  size_t stride() const { return stride_; }
  uint32_t tile_cols() const { return tile_cols_; }
  uint32_t tile_rows() const { return tile_rows_; }
  uint32_t tile_count() const { return tile_cols_ * tile_rows_; }
  uint32_t tile_index(uint32_t tile_x, uint32_t tile_y) const {
    return tile_y * tile_cols_ + tile_x;
  }

  // -- planes ----------------------------------------------------------
  uint8_t *l_cur() { return l_cur_.data(); }
  const uint8_t *l_cur() const { return l_cur_.data(); }
  size_t l_cur_size() const { return l_cur_.size(); }

  // Chroma bitplane, LSB-first within each byte: pixel x maps to
  // byte x / 8, bit x % 8 of its row.
  uint8_t *chroma_bits() { return chroma_bits_.data(); }
  const uint8_t *chroma_bits() const { return chroma_bits_.data(); }
  size_t chroma_stride() const { return chroma_stride_; }
  bool chroma_at(uint32_t x, uint32_t y) const {
    return ((chroma_bits_[y * chroma_stride_ + (x >> 3u)] >> (x & 7u)) & 1u) !=
           0u;
  }

  // Row hashes (ping-pong). "cur" is the buffer TilePass writes during the
  // active pass; "prev" holds the previous pass's hashes. Hashes are valid
  // only for rows written since configure()/invalidate() (0 = never hashed).
  uint32_t *row_hash_cur() { return row_hash_[cur_hash_].data(); }
  const uint32_t *row_hash_cur() const { return row_hash_[cur_hash_].data(); }
  const uint32_t *row_hash_prev() const {
    return row_hash_[cur_hash_ ^ 1u].data();
  }

  // -- scroll-verify row samples ---------------------------------------
  // TilePass snapshots every kRowSamplePeriod-th logical row's PRE-pass
  // bytes (candidate tile rows only) before overwriting them, so the
  // scroll detector can memcmp-verify a row-hash vote against true
  // previous-pass pixels without retaining a second full plane. A sample
  // is valid only for the pass that stamped it.
  static constexpr uint32_t kRowSamplePeriod = 8;
  // TilePass only: the slot backing row y (y % kRowSamplePeriod == 0);
  // stamp it with mark_row_sample() after copying width() bytes into it.
  uint8_t *row_sample_slot(uint32_t y) {
    return row_samples_.data() + (y / kRowSamplePeriod) * stride_;
  }
  void mark_row_sample(uint32_t y) {
    row_sample_epoch_[y / kRowSamplePeriod] = epoch_;
  }
  // Previous-pass bytes of row y (width() bytes), or nullptr when y is not
  // a sample row or was not snapshotted during the CURRENT pass.
  const uint8_t *row_sample(uint32_t y) const {
    if (y >= height_ || (y % kRowSamplePeriod) != 0 ||
        row_sample_epoch_[y / kRowSamplePeriod] != epoch_ || epoch_ == 0) {
      return nullptr;
    }
    return row_samples_.data() + (y / kRowSamplePeriod) * stride_;
  }

  // -- tile stats ------------------------------------------------------
  TileStats *stats() { return stats_.data(); }
  const TileStats *stats() const { return stats_.data(); }
  const TileStats &stats_at(uint32_t tile_idx) const {
    return stats_[tile_idx];
  }

  // -- lifecycle -------------------------------------------------------
  // Fills L_cur with the kInvalidLevel5 sentinel and clears chroma bits,
  // row hashes, and tile stats: the next pass reports exact content damage
  // everywhere it looks. The epoch counter is NOT reset (stays monotonic
  // for consumers holding older records).
  void invalidate();

  // Overwrites the settled plane only (e.g. kWhiteLevel5 after the engine's
  // cold clear completes); chroma/stats/hashes are left untouched.
  void fill_levels(uint8_t lvl5);

  uint32_t epoch() const { return epoch_; }

  // TilePass only, once per pass: advances the epoch and flips the row-hash
  // ping-pong, carrying the previous hashes forward so untouched rows keep
  // valid values. Returns the new epoch.
  uint32_t begin_pass();

  // Exports/imports a complete settled renderer mirror. Import is
  // transactional: geometry, vector lengths, levels, epochs, stats and
  // rectangles are validated before any live plane is replaced.
  bool export_state(FrameLedgerState *out) const;
  bool import_state(const FrameLedgerState &state);

private:
  bool valid_ = false;
  uint32_t width_ = 0;
  uint32_t height_ = 0;
  uint32_t tile_px_ = 0;
  uint32_t tile_cols_ = 0;
  uint32_t tile_rows_ = 0;
  size_t stride_ = 0;
  size_t chroma_stride_ = 0;
  uint32_t epoch_ = 0;
  uint32_t cur_hash_ = 0;
  std::vector<uint8_t> l_cur_;
  std::vector<uint8_t> chroma_bits_;
  std::vector<uint32_t> row_hash_[2];
  std::vector<uint8_t> row_samples_;
  std::vector<uint32_t> row_sample_epoch_;
  std::vector<TileStats> stats_;
};

} // namespace pluto

#endif // PLUTO_RENDERER_FRAME_LEDGER_H_
