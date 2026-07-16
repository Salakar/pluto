#include "renderer/ledgers.h"

#include <algorithm>
#include <utility>

#include "renderer/rect_utils.h"

namespace pluto {
namespace {

// 2^(-i/32) in Q15 for i = 0..32 (i == 32 is exactly one half-life).
// Table-driven decay: elapsed time decomposes into (shift, frac) 1/32
// half-life quanta; the multiply below applies 2^(-shift) * table[frac].
constexpr uint32_t k_pow2_frac_q15[33] = {
    32768, 32066, 31379, 30706, 30048, 29405, 28774, 28158, 27554,
    26964, 26386, 25821, 25268, 24726, 24196, 23678, 23170, 22674,
    22188, 21713, 21247, 20792, 20347, 19911, 19484, 19066, 18658,
    18258, 17867, 17484, 17109, 16743, 16384};

bool same_grid(const TileGrid &a, const TileGrid &b) {
  return a.width == b.width && a.height == b.height && a.tile_px == b.tile_px &&
         a.cols == b.cols && a.rows == b.rows;
}

bool valid_active_window(const std::vector<uint16_t> &values, uint64_t lo,
                         uint64_t hi) {
  const uint64_t size = values.size();
  if (lo > size || hi > size) {
    return false;
  }
  if (lo >= hi) {
    return std::none_of(values.begin(), values.end(),
                        [](uint16_t value) { return value != 0; });
  }
  for (uint64_t i = 0; i < size; ++i) {
    if ((i < lo || i >= hi) && values[static_cast<size_t>(i)] != 0) {
      return false;
    }
  }
  return true;
}

// Applies exponential decay over the nonzero-bounded window [*lo, *hi) of
// `values`, consuming elapsed time in 1/32 half-life quanta and returning the
// amount of time (us) actually consumed so callers can carry the remainder (no
// under-decay at fast tick rates). Every value outside the window is already
// zero (caller invariant), so skipping it is byte-identical to scanning the
// whole vector; [*lo, *hi) is tightened to the surviving nonzeros on the way
// out, and an empty window is returned as *lo == values->size(), *hi == 0.
uint64_t apply_decay(std::vector<uint16_t> *values, uint64_t elapsed_us,
                     uint32_t tau_ms, size_t *lo, size_t *hi) {
  if (tau_ms == 0) {
    return elapsed_us;
  }
  // Half-life = tau * ln 2 (in us). 693147/1000000 = ln 2.
  const uint64_t half_life_us =
      (static_cast<uint64_t>(tau_ms) * 1000ull * 693147ull) / 1000000ull;
  if (half_life_us == 0) {
    return elapsed_us;
  }
  const uint64_t quanta = (elapsed_us * 32ull) / half_life_us;
  if (quanta == 0) {
    return 0; // too little time: carry it into the next tick
  }
  const size_t begin = *lo;
  const size_t end = *hi < values->size() ? *hi : values->size();
  const uint64_t shift = quanta / 32ull;
  const uint32_t frac = static_cast<uint32_t>(quanta % 32ull);
  if (shift >= 16) {
    for (size_t i = begin; i < end; ++i) {
      (*values)[i] = 0;
    }
    *lo = values->size();
    *hi = 0; // window now empty
  } else {
    const uint32_t factor_q15 = k_pow2_frac_q15[frac] >> shift;
    uint16_t *data = values->data();
    size_t new_lo = 0;
    size_t new_hi = 0;
    bool any = false;
    for (size_t i = begin; i < end; ++i) {
      uint16_t v = data[i];
      if (v != 0) {
        v = static_cast<uint16_t>((static_cast<uint32_t>(v) * factor_q15) >>
                                  15u);
        data[i] = v;
        if (v != 0) {
          if (!any) {
            new_lo = i;
            any = true;
          }
          new_hi = i + 1;
        }
      }
    }
    if (any) {
      *lo = new_lo;
      *hi = new_hi;
    } else {
      *lo = values->size();
      *hi = 0;
    }
  }
  return (quanta * half_life_us) / 32ull;
}

} // namespace

bool TileGrid::configure(int32_t w, int32_t h, uint32_t tile) {
  if (w <= 0 || h <= 0 || tile == 0) {
    return false;
  }
  width = w;
  height = h;
  tile_px = tile;
  cols = (static_cast<uint32_t>(w) + tile - 1) / tile;
  rows = (static_cast<uint32_t>(h) + tile - 1) / tile;
  return true;
}

PlutoRect TileGrid::tile_rect(uint32_t tx, uint32_t ty) const {
  const int32_t x = static_cast<int32_t>(tx * tile_px);
  const int32_t y = static_cast<int32_t>(ty * tile_px);
  const int32_t w = std::min<int32_t>(static_cast<int32_t>(tile_px), width - x);
  const int32_t h =
      std::min<int32_t>(static_cast<int32_t>(tile_px), height - y);
  return PlutoRect{x, y, w, h};
}

// ---- GhostLedger -----------------------------------------------------------

bool GhostLedger::configure(const TileGrid &grid, uint32_t tau_ms,
                            uint16_t owed_threshold) {
  valid_ = false;
  if (grid.tile_count() == 0 || tau_ms == 0) {
    return false;
  }
  grid_ = grid;
  tau_ms_ = tau_ms;
  owed_threshold_ = owed_threshold;
  last_decay_us_ = 0;
  clock_started_ = false;
  active_lo_ = grid_.tile_count(); // empty nonzero window
  active_hi_ = 0;
  debt_.assign(grid_.tile_count(), 0);
  owed_.assign(grid_.tile_count(), 0);
  valid_ = true;
  return true;
}

uint32_t GhostLedger::decay_factor_q15(uint64_t elapsed_us, uint32_t tau_ms) {
  std::vector<uint16_t> probe(1, 32768u >> 1u); // headroom for Q15 math
  size_t lo = 0;
  size_t hi = 1;
  apply_decay(&probe, elapsed_us, tau_ms, &lo, &hi);
  return static_cast<uint32_t>(probe[0]) << 1u;
}

void GhostLedger::tick(uint64_t now_us) {
  if (!valid_) {
    return;
  }
  if (!clock_started_) {
    clock_started_ = true;
    last_decay_us_ = now_us;
    return;
  }
  if (now_us <= last_decay_us_) {
    return;
  }
  const uint64_t consumed = apply_decay(&debt_, now_us - last_decay_us_,
                                        tau_ms_, &active_lo_, &active_hi_);
  last_decay_us_ += consumed;
}

void GhostLedger::accrue(const PlutoRect &rect, PlutoRefreshClass cls) {
  if (!valid_) {
    return;
  }
  uint32_t weight_q8 = 0;
  switch (cls) {
  case kPlutoRefreshFast:
    weight_q8 = kWeightFastQ8;
    break;
  case kPlutoRefreshUi:
    weight_q8 = kWeightUiQ8;
    break;
  case kPlutoRefreshText:
  case kPlutoRefreshFull:
    return; // quality classes clear, never accrue (callers use clear())
  }
  const PlutoRect clipped = rect_clip(rect, grid_.width, grid_.height);
  if (rect_is_empty(clipped)) {
    return;
  }
  const int64_t tile_area = static_cast<int64_t>(grid_.tile_px) * grid_.tile_px;
  grid_.for_each_tile(clipped, [&](uint32_t tx, uint32_t ty) {
    const PlutoRect tile = grid_.tile_rect(tx, ty);
    // Region-level changed_px approximation: covered pixels in this tile.
    const int64_t covered = rect_intersection_area(clipped, tile);
    const uint32_t add =
        static_cast<uint32_t>((weight_q8 * covered) / tile_area);
    const size_t idx = grid_.index(tx, ty);
    uint16_t &j = debt_[idx];
    const uint32_t next = static_cast<uint32_t>(j) + add;
    j = static_cast<uint16_t>(next > 0xffffu ? 0xffffu : next);
    if (j != 0) {
      if (idx < active_lo_)
        active_lo_ = idx;
      if (idx + 1 > active_hi_)
        active_hi_ = idx + 1;
    }
    if (j >= owed_threshold_) {
      owed_[idx] = 1; // latched: repaid only by a Text/Full clear
    }
  });
}

void GhostLedger::clear(const PlutoRect &rect) {
  if (!valid_) {
    return;
  }
  grid_.for_each_tile(rect, [&](uint32_t tx, uint32_t ty) {
    debt_[grid_.index(tx, ty)] = 0;
    owed_[grid_.index(tx, ty)] = 0;
  });
}

void GhostLedger::translate_rows(const PlutoRect &band, int32_t tile_dy) {
  if (!valid_ || tile_dy == 0) {
    return;
  }
  const PlutoRect clipped = rect_clip(band, grid_.width, grid_.height);
  if (rect_is_empty(clipped)) {
    return;
  }
  const uint32_t tx0 = static_cast<uint32_t>(clipped.x) / grid_.tile_px;
  const uint32_t ty0 = static_cast<uint32_t>(clipped.y) / grid_.tile_px;
  const uint32_t tx1 =
      static_cast<uint32_t>(rect_right(clipped) - 1) / grid_.tile_px;
  const uint32_t ty1 =
      static_cast<uint32_t>(rect_bottom(clipped) - 1) / grid_.tile_px;
  const int32_t band_ty0 = static_cast<int32_t>(ty0);
  const int32_t band_ty1 = static_cast<int32_t>(ty1);
  // Translation can move debt into tiles outside the current nonzero window;
  // widen it to the band's full flat-index span so decay never skips them.
  const size_t band_first = grid_.index(tx0, ty0);
  const size_t band_last = grid_.index(tx1, ty1);
  if (band_first < active_lo_)
    active_lo_ = band_first;
  if (band_last + 1 > active_hi_)
    active_hi_ = band_last + 1;
  for (uint32_t tx = tx0; tx <= tx1; ++tx) {
    if (tile_dy > 0) {
      // Content moved down: walk bottom-up so sources are read pre-move.
      for (int32_t ty = band_ty1; ty >= band_ty0; --ty) {
        const int32_t src = ty - tile_dy;
        const size_t dst_idx = grid_.index(tx, static_cast<uint32_t>(ty));
        if (src >= band_ty0) {
          const size_t src_idx = grid_.index(tx, static_cast<uint32_t>(src));
          debt_[dst_idx] = debt_[src_idx];
          owed_[dst_idx] = owed_[src_idx];
        } else {
          // Vacated by the translation: fresh (disocclusion) content.
          debt_[dst_idx] = 0;
          owed_[dst_idx] = 0;
        }
      }
    } else {
      // Content moved up: walk top-down.
      for (int32_t ty = band_ty0; ty <= band_ty1; ++ty) {
        const int32_t src = ty - tile_dy;
        const size_t dst_idx = grid_.index(tx, static_cast<uint32_t>(ty));
        if (src <= band_ty1) {
          const size_t src_idx = grid_.index(tx, static_cast<uint32_t>(src));
          debt_[dst_idx] = debt_[src_idx];
          owed_[dst_idx] = owed_[src_idx];
        } else {
          debt_[dst_idx] = 0;
          owed_[dst_idx] = 0;
        }
      }
    }
  }
}

bool GhostLedger::export_state(GhostLedgerState *out) const {
  if (!valid_ || out == nullptr) {
    return false;
  }
  GhostLedgerState state;
  state.grid = grid_;
  state.tau_ms = tau_ms_;
  state.owed_threshold = owed_threshold_;
  state.last_decay_us = last_decay_us_;
  state.clock_started = clock_started_;
  state.active_lo = active_lo_;
  state.active_hi = active_hi_;
  state.debt = debt_;
  state.owed = owed_;
  *out = std::move(state);
  return true;
}

bool GhostLedger::import_state(const GhostLedgerState &state) {
  if (!valid_ || !same_grid(state.grid, grid_) || state.tau_ms != tau_ms_ ||
      state.owed_threshold != owed_threshold_ ||
      state.debt.size() != debt_.size() || state.owed.size() != owed_.size() ||
      (!state.clock_started && state.last_decay_us != 0) ||
      !valid_active_window(state.debt, state.active_lo, state.active_hi) ||
      std::any_of(state.owed.begin(), state.owed.end(),
                  [](uint8_t value) { return value > 1u; })) {
    return false;
  }
  last_decay_us_ = state.last_decay_us;
  clock_started_ = state.clock_started;
  active_lo_ = static_cast<size_t>(state.active_lo);
  active_hi_ = static_cast<size_t>(state.active_hi);
  std::copy(state.debt.begin(), state.debt.end(), debt_.begin());
  std::copy(state.owed.begin(), state.owed.end(), owed_.begin());
  return true;
}

// ---- StressLedger ----------------------------------------------------------

bool StressLedger::configure(const TileGrid &grid) {
  valid_ = false;
  if (grid.tile_count() == 0) {
    return false;
  }
  grid_ = grid;
  last_decay_us_ = 0;
  clock_started_ = false;
  active_lo_ = grid_.tile_count(); // empty nonzero window
  active_hi_ = 0;
  stress_.assign(grid_.tile_count(), 0);
  valid_ = true;
  return true;
}

void StressLedger::tick(uint64_t now_us) {
  if (!valid_) {
    return;
  }
  if (!clock_started_) {
    clock_started_ = true;
    last_decay_us_ = now_us;
    return;
  }
  if (now_us <= last_decay_us_) {
    return;
  }
  const uint64_t consumed = apply_decay(&stress_, now_us - last_decay_us_,
                                        kStressTauMs, &active_lo_, &active_hi_);
  last_decay_us_ += consumed;
}

void StressLedger::accrue(const PlutoRect &rect, PlutoRefreshClass cls) {
  if (!valid_) {
    return;
  }
  uint16_t delta = 0;
  switch (cls) {
  case kPlutoRefreshFast:
    delta = kFastDelta;
    break;
  case kPlutoRefreshUi:
    delta = kUiDelta;
    break;
  case kPlutoRefreshText:
  case kPlutoRefreshFull:
    return;
  }
  grid_.for_each_tile(rect, [&](uint32_t tx, uint32_t ty) {
    const size_t idx = grid_.index(tx, ty);
    uint16_t &s = stress_[idx];
    const uint32_t next = static_cast<uint32_t>(s) + delta;
    s = static_cast<uint16_t>(next > 0xffffu ? 0xffffu : next);
    if (s != 0) {
      if (idx < active_lo_)
        active_lo_ = idx;
      if (idx + 1 > active_hi_)
        active_hi_ = idx + 1;
    }
  });
}

void StressLedger::clear(const PlutoRect &rect) {
  if (!valid_) {
    return;
  }
  grid_.for_each_tile(rect, [&](uint32_t tx, uint32_t ty) {
    stress_[grid_.index(tx, ty)] = 0;
  });
}

bool StressLedger::export_state(StressLedgerState *out) const {
  if (!valid_ || out == nullptr) {
    return false;
  }
  StressLedgerState state;
  state.grid = grid_;
  state.last_decay_us = last_decay_us_;
  state.clock_started = clock_started_;
  state.active_lo = active_lo_;
  state.active_hi = active_hi_;
  state.stress = stress_;
  *out = std::move(state);
  return true;
}

bool StressLedger::import_state(const StressLedgerState &state) {
  if (!valid_ || !same_grid(state.grid, grid_) ||
      state.stress.size() != stress_.size() ||
      (!state.clock_started && state.last_decay_us != 0) ||
      !valid_active_window(state.stress, state.active_lo, state.active_hi)) {
    return false;
  }
  last_decay_us_ = state.last_decay_us;
  clock_started_ = state.clock_started;
  active_lo_ = static_cast<size_t>(state.active_lo);
  active_hi_ = static_cast<size_t>(state.active_hi);
  std::copy(state.stress.begin(), state.stress.end(), stress_.begin());
  return true;
}

// ---- ChromaPendingSet ------------------------------------------------------

bool ChromaPendingSet::configure(const TileGrid &grid) {
  valid_ = false;
  if (grid.tile_count() == 0) {
    return false;
  }
  grid_ = grid;
  pending_count_ = 0;
  pending_.assign(grid_.tile_count(), 0);
  valid_ = true;
  return true;
}

void ChromaPendingSet::mark(const PlutoRect &rect) {
  if (!valid_) {
    return;
  }
  grid_.for_each_tile(rect, [&](uint32_t tx, uint32_t ty) {
    uint8_t &bit = pending_[grid_.index(tx, ty)];
    if (bit == 0) {
      bit = 1;
      ++pending_count_;
    }
  });
}

void ChromaPendingSet::clear(const PlutoRect &rect) {
  if (!valid_) {
    return;
  }
  grid_.for_each_tile(rect, [&](uint32_t tx, uint32_t ty) {
    uint8_t &bit = pending_[grid_.index(tx, ty)];
    if (bit != 0) {
      bit = 0;
      --pending_count_;
    }
  });
}

bool ChromaPendingSet::export_state(ChromaPendingState *out) const {
  if (!valid_ || out == nullptr) {
    return false;
  }
  ChromaPendingState state;
  state.grid = grid_;
  state.pending_count = pending_count_;
  state.pending = pending_;
  *out = std::move(state);
  return true;
}

bool ChromaPendingSet::import_state(const ChromaPendingState &state) {
  if (!valid_ || !same_grid(state.grid, grid_) ||
      state.pending.size() != pending_.size() ||
      std::any_of(state.pending.begin(), state.pending.end(),
                  [](uint8_t value) { return value > 1u; })) {
    return false;
  }
  const uint64_t count = static_cast<uint64_t>(std::count(
      state.pending.begin(), state.pending.end(), static_cast<uint8_t>(1)));
  if (state.pending_count != count) {
    return false;
  }
  pending_count_ = static_cast<size_t>(count);
  std::copy(state.pending.begin(), state.pending.end(), pending_.begin());
  return true;
}

} // namespace pluto
