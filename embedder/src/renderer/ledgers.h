#ifndef PLUTO_RENDERER_LEDGERS_H_
#define PLUTO_RENDERER_LEDGERS_H_

#include <cstddef>
#include <cstdint>
#include <vector>

#include "pluto/presenter.h"

namespace pluto {

// Shared tile-grid geometry for the per-tile ledgers.
// The grid matches the FrameLedger tile grid (default 32 px -> 30x53 = 1590
// tiles on the panel); host tests use smaller surfaces.
//
// Thread ownership: all ledgers are scheduler-thread confined
// (FrameRenderer's presenter-loop mutex today). No internal locking.
struct TileGrid {
  int32_t width = 0;
  int32_t height = 0;
  uint32_t tile_px = 32;
  uint32_t cols = 0;
  uint32_t rows = 0;

  bool configure(int32_t w, int32_t h, uint32_t tile);
  size_t tile_count() const { return static_cast<size_t>(cols) * rows; }
  size_t index(uint32_t tx, uint32_t ty) const {
    return static_cast<size_t>(ty) * cols + tx;
  }
  PlutoRect tile_rect(uint32_t tx, uint32_t ty) const;

  // Iterates the tiles intersecting `rect` (clipped to the surface).
  template <typename Fn>
  void for_each_tile(const PlutoRect &rect, Fn &&fn) const;
};

struct GhostLedgerState {
  TileGrid grid{};
  uint32_t tau_ms = 0;
  uint16_t owed_threshold = 0;
  uint64_t last_decay_us = 0;
  bool clock_started = false;
  uint64_t active_lo = 0;
  uint64_t active_hi = 0;
  std::vector<uint16_t> debt;
  std::vector<uint8_t> owed;
};

struct StressLedgerState {
  TileGrid grid{};
  uint64_t last_decay_us = 0;
  bool clock_started = false;
  uint64_t active_lo = 0;
  uint64_t active_hi = 0;
  std::vector<uint16_t> stress;
};

struct ChromaPendingState {
  TileGrid grid{};
  uint64_t pending_count = 0;
  std::vector<uint8_t> pending;
};

// GhostLedger: per-tile decaying ghost-debt impulse J.
//
//   J <- J * e^(-dt/tau)   table-driven, applied on tick()
//   J += w(class) * covered_px_fraction * 256 on admission (Q8 units; the
//       region-level approximation of w(mode)*changed_px until the scheduler
//       consumes TileStats directly)
//   J := 0 on a GC16/Full-class clear (Text/Full admissions)
//
// Decay is exact-in-aggregate: tick() consumes elapsed time in 1/32
// half-life quanta through a 2^(-i/32) Q15 table, carrying the remainder so
// arbitrarily small tick cadences do not under-decay.
//
// Settle ELIGIBILITY is latched at accrual time (`owed`): the moment a
// tile's debt crosses `owed_threshold` it owes a quality pass until a
// Text/Full-class clear repays it — decay affects only the ORDERING weight,
// never whether repayment happens. (Reading eligibility off the decayed
// value would make the settle candidate set wall-clock sensitive: borderline
// tiles would flip with tick phase, and the settled picture with them.)
class GhostLedger {
public:
  // Q8 accrual weights w(mode) per refresh class; rail classes weigh heavier.
  static constexpr uint16_t kWeightFastQ8 = 3 * 256;
  static constexpr uint16_t kWeightUiQ8 = 2 * 256;

  bool configure(const TileGrid &grid, uint32_t tau_ms,
                 uint16_t owed_threshold);
  bool valid() const { return valid_; }

  // Applies exponential decay for the time elapsed since the last tick.
  void tick(uint64_t now_us);

  // Accrues w(cls) * coverage into every tile the rect touches. Text/Full
  // do not accrue -- callers route those through clear().
  void accrue(const PlutoRect &rect, PlutoRefreshClass cls);

  // GC16/Full-class clear: zeroes debt and the owed latch under the rect.
  void clear(const PlutoRect &rect);

  // Scroll MOVE: translates debt + owed latches for the band's tiles by
  // tile_dy tile rows — the debt follows the content it was accrued
  // against. Tiles whose source falls outside the band (the disocclusion
  // side) reset to zero: fresh content owes nothing yet.
  // Callers accumulate sub-tile pixel deltas and translate whole tiles.
  void translate_rows(const PlutoRect &band, int32_t tile_dy);

  uint16_t debt(uint32_t tx, uint32_t ty) const {
    return debt_[grid_.index(tx, ty)];
  }
  bool owed(uint32_t tx, uint32_t ty) const {
    return owed_[grid_.index(tx, ty)] != 0;
  }
  const TileGrid &grid() const { return grid_; }

  // Test hook: decay factor in Q15 for an elapsed time (half-life math).
  static uint32_t decay_factor_q15(uint64_t elapsed_us, uint32_t tau_ms);

  bool export_state(GhostLedgerState *out) const;
  bool import_state(const GhostLedgerState &state);

private:
  bool valid_ = false;
  TileGrid grid_{};
  uint32_t tau_ms_ = 1000;
  uint16_t owed_threshold_ = 224;
  uint64_t last_decay_us_ = 0;
  bool clock_started_ = false;
  // Half-open flat-index range that bounds every nonzero debt tile: decay
  // walks only [active_lo_, active_hi_) instead of the whole plane. accrue /
  // translate_rows widen it; tick() tightens it to the surviving nonzeros.
  // Empty range is represented by active_lo_ >= active_hi_.
  size_t active_lo_ = 0;
  size_t active_hi_ = 0;
  std::vector<uint16_t> debt_;
  std::vector<uint8_t> owed_;
};

// StressLedger: per-tile mirror of the engine's DC stress. Stage-2 STUB:
// accrues small increments on rail-class admissions; the engine wires real
// cancel/truncation/pause charges at Stage 4. Decays slowly (fixed tau = 4s)
// so a stressed tile eventually forgives if it is never railed again.
class StressLedger {
public:
  static constexpr uint16_t kFastDelta = 3;
  static constexpr uint16_t kUiDelta = 1;

  bool configure(const TileGrid &grid);
  bool valid() const { return valid_; }

  void tick(uint64_t now_us);
  void accrue(const PlutoRect &rect, PlutoRefreshClass cls);
  // Balanced-quality pass (Text/Full) resets the stub stress.
  void clear(const PlutoRect &rect);

  uint16_t stress(uint32_t tx, uint32_t ty) const {
    return stress_[grid_.index(tx, ty)];
  }

  bool export_state(StressLedgerState *out) const;
  bool import_state(const StressLedgerState &state);

private:
  static constexpr uint32_t kStressTauMs = 4000;

  bool valid_ = false;
  TileGrid grid_{};
  uint64_t last_decay_us_ = 0;
  bool clock_started_ = false;
  // Nonzero-stress bound; see GhostLedger for the invariant.
  size_t active_lo_ = 0;
  size_t active_hi_ = 0;
  std::vector<uint16_t> stress_;
};

// ChromaPendingSet: tiles whose chroma content reached glass through a
// sub-Full class (gray-crushed) and is waiting for a Full-class settle to
// develop ("color is a settled state").
// Set by the frame path when chroma-bearing damage dispatches sub-Full;
// cleared by any Full-class admission covering the tile.
class ChromaPendingSet {
public:
  bool configure(const TileGrid &grid);
  bool valid() const { return valid_; }

  void mark(const PlutoRect &rect);
  void clear(const PlutoRect &rect);
  bool pending(uint32_t tx, uint32_t ty) const {
    return pending_[grid_.index(tx, ty)] != 0;
  }
  bool any() const { return pending_count_ != 0; }
  size_t pending_count() const { return pending_count_; }
  const TileGrid &grid() const { return grid_; }

  bool export_state(ChromaPendingState *out) const;
  bool import_state(const ChromaPendingState &state);

private:
  bool valid_ = false;
  TileGrid grid_{};
  size_t pending_count_ = 0;
  std::vector<uint8_t> pending_;
};

// ---- inline template ------------------------------------------------------

template <typename Fn>
void TileGrid::for_each_tile(const PlutoRect &rect, Fn &&fn) const {
  const int32_t x0 = rect.x < 0 ? 0 : rect.x;
  const int32_t y0 = rect.y < 0 ? 0 : rect.y;
  const int32_t x1 =
      (rect.x + rect.width) > width ? width : (rect.x + rect.width);
  const int32_t y1 =
      (rect.y + rect.height) > height ? height : (rect.y + rect.height);
  if (x1 <= x0 || y1 <= y0) {
    return;
  }
  const uint32_t tx0 = static_cast<uint32_t>(x0) / tile_px;
  const uint32_t ty0 = static_cast<uint32_t>(y0) / tile_px;
  const uint32_t tx1 = static_cast<uint32_t>(x1 - 1) / tile_px;
  const uint32_t ty1 = static_cast<uint32_t>(y1 - 1) / tile_px;
  for (uint32_t ty = ty0; ty <= ty1; ++ty) {
    for (uint32_t tx = tx0; tx <= tx1; ++tx) {
      fn(tx, ty);
    }
  }
}

} // namespace pluto

#endif // PLUTO_RENDERER_LEDGERS_H_
