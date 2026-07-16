#include "renderer/classify_ladder.h"

#include <algorithm>
#include <bit>
#include <utility>

#include "renderer/rect_utils.h"

namespace pluto {
namespace {

bool same_config(const ClassifyLadderConfig &a, const ClassifyLadderConfig &b) {
  if (a.width != b.width || a.height != b.height || a.tile_px != b.tile_px ||
      a.motion_streak != b.motion_streak ||
      a.motion_tile_percent != b.motion_tile_percent ||
      a.motion_cooldown_epochs != b.motion_cooldown_epochs ||
      a.nas_enabled != b.nas_enabled || a.nas_tau_q8 != b.nas_tau_q8 ||
      a.nas_l != b.nas_l ||
      a.scenecut_coverage_percent != b.scenecut_coverage_percent ||
      a.scenecut_intensity_min != b.scenecut_intensity_min ||
      a.scenecut_ghost_bias_percent != b.scenecut_ghost_bias_percent ||
      a.scenecut_cooldown_epochs != b.scenecut_cooldown_epochs ||
      a.full_screen_area_percent != b.full_screen_area_percent ||
      a.dwell_hot_epochs != b.dwell_hot_epochs ||
      a.dwell_cold_epochs != b.dwell_cold_epochs ||
      a.text_area_percent != b.text_area_percent) {
    return false;
  }
  for (size_t i = 0; i < 3; ++i) {
    if (a.nas_k_q8[i] != b.nas_k_q8[i]) {
      return false;
    }
  }
  return true;
}

bool canonical_rect(const PlutoRect &rect, int32_t width, int32_t height,
                    bool allow_empty) {
  if (rect.width <= 0 || rect.height <= 0) {
    return allow_empty && rect.x == 0 && rect.y == 0 && rect.width == 0 &&
           rect.height == 0;
  }
  return rect.x >= 0 && rect.y >= 0 &&
         static_cast<int64_t>(rect.x) + rect.width <= width &&
         static_cast<int64_t>(rect.y) + rect.height <= height;
}

} // namespace

bool ClassifyLadder::configure(const ClassifyLadderConfig &config) {
  valid_ = false;
  config_ = config;
  epoch_ = 0;
  if (!grid_.configure(config.width, config.height, config.tile_px)) {
    history_.clear();
    return false;
  }
  history_.assign(grid_.tile_count(), ClassifyTileHistoryState{});
  dirty_idx_.assign(grid_.tile_count(), 0u);
  valid_ = true;
  return true;
}

void ClassifyLadder::begin_pass(uint32_t epoch, const DirtyTileRecord *records,
                                size_t count) {
  if (!valid_) {
    return;
  }
  epoch_ = epoch;
  if (records == nullptr) {
    return;
  }
  for (size_t i = 0; i < count; ++i) {
    const DirtyTileRecord &record = records[i];
    if (record.tile_idx >= history_.size()) {
      continue;
    }
    ClassifyTileHistoryState &h = history_[record.tile_idx];
    // Motion means the SAME pixels churn at pass cadence: consecutive
    // epochs AND overlapping dirty rects. Typing-style accretion (disjoint
    // glyph rects landing in one tile) resets the streak.
    if (h.last_epoch != 0 && epoch == h.last_epoch + 1 &&
        rect_intersects(record.dirty, h.last_dirty)) {
      ++h.streak;
    } else {
      h.streak = 1;
    }
    h.prev_epoch = h.last_epoch;
    h.last_epoch = epoch;
    h.last_dirty = record.dirty;
  }
}

LadderDecision ClassifyLadder::classify(const PlutoRect &region,
                                        const TileStats *stats,
                                        const GhostLedger *ghost) {
  if (!valid_ || stats == nullptr) {
    return LadderDecision{kPlutoRefreshUi, LadderRung::kDwell};
  }
  const PlutoRect clipped = rect_clip(region, grid_.width, grid_.height);
  if (rect_is_empty(clipped)) {
    return LadderDecision{kPlutoRefreshUi, LadderRung::kDwell};
  }

  // ---- aggregate this pass's TileStats under the region -----------------
  uint32_t dirty_tiles = 0;
  uint32_t motion_tiles = 0;
  uint32_t hot_tiles = 0;
  uint32_t cold_tiles = 0;
  uint32_t owed_tiles = 0;
  uint32_t recent_cut_tiles = 0;
  uint16_t hist = 0;
  uint8_t max_diff = 0;
  uint64_t changed = 0;
  uint64_t sad = 0;
  // Loop-invariant ghost gate hoisted out of the per-tile body.
  const bool use_ghost = ghost != nullptr && ghost->valid();
  uint32_t *dirty_idx = dirty_idx_.data();
  size_t ndirty = 0;
  // Direct tile walk (same iteration + clipping as grid_.for_each_tile) with
  // an incremental row base, so the per-tile linear index is one add rather
  // than a multiply.
  const uint32_t tile_px = grid_.tile_px;
  const uint32_t cols = grid_.cols;
  const uint32_t tx0 = static_cast<uint32_t>(clipped.x) / tile_px;
  const uint32_t ty0 = static_cast<uint32_t>(clipped.y) / tile_px;
  const uint32_t tx1 = static_cast<uint32_t>(rect_right(clipped) - 1) / tile_px;
  const uint32_t ty1 =
      static_cast<uint32_t>(rect_bottom(clipped) - 1) / tile_px;
  for (uint32_t ty = ty0; ty <= ty1; ++ty) {
    const size_t row_base = static_cast<size_t>(ty) * cols;
    for (uint32_t tx = tx0; tx <= tx1; ++tx) {
      const size_t idx = row_base + tx;
      const TileStats &s = stats[idx];
      if (s.epoch != epoch_ || !rect_intersects(s.dirty, clipped)) {
        continue; // not dirty this pass / dirt belongs to a sibling region
      }
      dirty_idx[ndirty++] = static_cast<uint32_t>(idx);
      hist = static_cast<uint16_t>(hist | s.level_hist);
      max_diff = std::max(max_diff, s.max_diff);
      changed += s.changed_px;
      sad += s.sad_pre_dither;
      const ClassifyTileHistoryState &h = history_[idx];
      if (h.streak >= config_.motion_streak || epoch_ <= h.fast_until) {
        ++motion_tiles;
      }
      if (h.prev_epoch == 0) {
        ++cold_tiles; // first damage ever: quiet forever before this
      } else {
        const uint32_t gap = epoch_ - h.prev_epoch;
        if (gap <= config_.dwell_hot_epochs) {
          ++hot_tiles;
        } else if (gap >= config_.dwell_cold_epochs) {
          ++cold_tiles;
        }
      }
      if (use_ghost && ghost->owed(tx, ty)) {
        ++owed_tiles;
      }
      if (h.scenecut_epoch != 0 &&
          epoch_ - h.scenecut_epoch <= config_.scenecut_cooldown_epochs) {
        ++recent_cut_tiles;
      }
    }
  }
  dirty_tiles = static_cast<uint32_t>(ndirty);
  if (dirty_tiles == 0) {
    return LadderDecision{kPlutoRefreshUi, LadderRung::kDwell};
  }

  const int64_t panel_area =
      static_cast<int64_t>(grid_.width) * static_cast<int64_t>(grid_.height);
  const int64_t area = rect_area(clipped);
  const bool motion =
      motion_tiles * 100u >= dirty_tiles * config_.motion_tile_percent;

  // ---- (iv) scenecut — evaluated first, gated off under motion ----------
  // Replaces the dispatch-time structural-full OVERRIDE (see header note).
  if (!motion) {
    // Ghost-debt bias: content that already owes quality settles flashes at
    // a lower coverage bar — the flash repays the debt for free.
    uint64_t threshold_pct = config_.scenecut_coverage_percent;
    const uint64_t bias = threshold_pct * config_.scenecut_ghost_bias_percent *
                          owed_tiles / (100u * dirty_tiles);
    threshold_pct -= std::min<uint64_t>(bias, threshold_pct);
    if (changed * 100u >= static_cast<uint64_t>(panel_area) * threshold_pct &&
        max_diff >= config_.scenecut_intensity_min) {
      // Scenecut-shaped change. Stamp the hysteresis window on the region's
      // dirty tiles FIRST (a suppressed repeat re-arms it, so sustained
      // half-cadence churn stays suppressed until it rests)...
      for (size_t i = 0; i < ndirty; ++i) {
        history_[dirty_idx[i]].scenecut_epoch = epoch_;
      }
      // ...then quality-repaint only a genuine cut: when most of the region
      // already cut within the cooldown, this is churn at a cadence the
      // motion streak cannot see (per-frame oscillation) — fall through to
      // the quality rungs and let the settle planner own the repaint.
      //
      // Text, NOT Full: the GC16 flash inverts the whole changed region to
      // a negative for several hundred ms — on screen-sized cuts (view
      // switches) that reads as aggressive black blocks. The non-flash GL16
      // waveform drives black<->white directly (real erase since the
      // level-lattice fix), the ghost ledger still tracks the residue, and
      // idle settles / the explicit ghost-clean Full repay deep quality.
      if (recent_cut_tiles * 2u < dirty_tiles) {
        return LadderDecision{kPlutoRefreshText, LadderRung::kScenecut};
      }
    }
  }

  // ---- (i) damage histogram ---------------------------------------------
  if ((hist & static_cast<uint16_t>(~kRailBwHistMask)) == 0) {
    // Pure black/white: the rail fast path is lossless on this content.
    return LadderDecision{kPlutoRefreshFast, LadderRung::kHistogram};
  }
  if (std::popcount(hist) <= 4) {
    return LadderDecision{kPlutoRefreshFast, LadderRung::kHistogram};
  }

  // ---- (ii) motion shortcut ----------------------------------------------
  if (motion) {
    // Arm stickiness so the class cannot flap while the animation continues
    // with occasional missed passes.
    const uint32_t horizon = epoch_ + config_.motion_cooldown_epochs;
    for (size_t i = 0; i < ndirty; ++i) {
      history_[dirty_idx[i]].fast_until = horizon;
    }
    return LadderDecision{kPlutoRefreshFast, LadderRung::kMotion};
  }

  // ---- (iii) NAS error-vs-JND (E7; default OFF) ---------------------------
  if (config_.nas_enabled && changed > 0) {
    // Masked-error test per mode, cheapest first: k[m] * err <= tau*(I + l).
    // I_avg stand-in: presence-weighted mean of the histogram buckets
    // (TileStats carries no mean luma; E7 refits the real curve).
    uint32_t level_sum = 0;
    uint32_t level_n = 0;
    for (uint32_t b = 0; b < 16; ++b) {
      if ((hist >> b) & 1u) {
        level_sum += b * 17u; // bucket -> ~8-bit luma
        ++level_n;
      }
    }
    const uint32_t i_avg = level_n != 0 ? level_sum / level_n : 255u;
    const uint64_t err_q8 = (sad << 8u) / changed; // avg error / changed px
    const uint64_t budget_q16 =
        (static_cast<uint64_t>(config_.nas_tau_q8) * (i_avg + config_.nas_l))
        << 8u;
    static constexpr PlutoRefreshClass kNasClasses[3] = {
        kPlutoRefreshFast, kPlutoRefreshUi, kPlutoRefreshText};
    for (size_t m = 0; m < 3; ++m) {
      if (config_.nas_k_q8[m] != UINT32_MAX &&
          static_cast<uint64_t>(config_.nas_k_q8[m]) * err_q8 <= budget_q16) {
        return LadderDecision{kNasClasses[m], LadderRung::kNas};
      }
    }
  }

  // ---- (v) dwell buckets (guardrail) --------------------------------------
  if (area * 100 > panel_area * config_.text_area_percent) {
    return LadderDecision{kPlutoRefreshText, LadderRung::kDwell};
  }
  if ((hot_tiles + cold_tiles) * 2u >= dirty_tiles) {
    // Hot: active accretion (typing) — quality keeps glyphs crisp.
    // Cold: long-quiet region taking a one-shot change — quality repaint.
    return LadderDecision{kPlutoRefreshText, LadderRung::kDwell};
  }
  return LadderDecision{kPlutoRefreshUi, LadderRung::kDwell};
}

bool ClassifyLadder::export_state(ClassifyLadderState *out) const {
  if (!valid_ || out == nullptr) {
    return false;
  }
  ClassifyLadderState state;
  state.config = config_;
  state.epoch = epoch_;
  state.history = history_;
  *out = std::move(state);
  return true;
}

bool ClassifyLadder::import_state(const ClassifyLadderState &state) {
  if (!valid_ || !same_config(state.config, config_) ||
      state.history.size() != history_.size()) {
    return false;
  }
  for (const ClassifyTileHistoryState &history : state.history) {
    if (history.last_epoch == 0) {
      if (history.prev_epoch != 0 || history.streak != 0 ||
          history.fast_until != 0 || history.scenecut_epoch != 0 ||
          history.last_dirty.x != 0 || history.last_dirty.y != 0 ||
          history.last_dirty.width != 0 || history.last_dirty.height != 0 ||
          !canonical_rect(history.last_dirty, config_.width, config_.height,
                          /*allow_empty=*/true)) {
        return false;
      }
      continue;
    }
    if (history.streak == 0 ||
        !canonical_rect(history.last_dirty, config_.width, config_.height,
                        /*allow_empty=*/false)) {
      return false;
    }
  }

  std::copy(state.history.begin(), state.history.end(), history_.begin());
  epoch_ = state.epoch;
  std::fill(dirty_idx_.begin(), dirty_idx_.end(), 0u);
  return true;
}

} // namespace pluto
