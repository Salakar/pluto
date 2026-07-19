#include "renderer/settle_policy.h"

#include <algorithm>
#include <limits>
#include <utility>

#include "renderer/rect_utils.h"
#include "renderer/region_scheduler.h"

namespace pluto {
namespace {

bool same_perception(const PerceptionConstants &a,
                     const PerceptionConstants &b) {
  return a.ghost_debt_settle_threshold() == b.ghost_debt_settle_threshold() &&
         a.stress_settle_threshold() == b.stress_settle_threshold() &&
         a.quiesce_ms() == b.quiesce_ms() &&
         a.ghost_tau_ms() == b.ghost_tau_ms() &&
         a.settle_full_area_percent() == b.settle_full_area_percent() &&
         a.settle_max_rects() == b.settle_max_rects() &&
         a.settle_cluster_gap_px() == b.settle_cluster_gap_px() &&
         a.settle_cluster_max_waste_px() == b.settle_cluster_max_waste_px() &&
         a.cbs_settle_budget_pct() == b.cbs_settle_budget_pct();
}

bool same_config(const SettlePlannerConfig &a, const SettlePlannerConfig &b) {
  return a.width == b.width && a.height == b.height && a.tile_px == b.tile_px &&
         a.align_px == b.align_px && a.panel_is_color == b.panel_is_color &&
         a.enable_sparkle_topoff == b.enable_sparkle_topoff &&
         same_perception(a.perception, b.perception);
}

bool rect_within_surface(const PlutoRect &rect, int32_t width, int32_t height,
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

bool SettlePlanner::configure(const SettlePlannerConfig &config,
                              GhostLedger *ghost, StressLedger *stress,
                              ChromaPendingSet *chroma) {
  valid_ = false;
  config_ = config;
  ghost_ = ghost;
  stress_ = stress;
  chroma_ = chroma;
  if (!grid_.configure(config.width, config.height, config.tile_px)) {
    return false;
  }
  last_damage_us_.assign(grid_.tile_count(), kNeverDamaged);
  clusters_.clear();
  clusters_.reserve(grid_.tile_count());
  eligible_tiles_.clear();
  eligible_tiles_.reserve(grid_.tile_count());
  stack_probe_.clear();
  stack_probe_.reserve(grid_.tile_count());
  forced_.clear();
  forced_.reserve(kMaxForced);
  emitted_settles_ = 0;
  emitted_full_flashes_ = 0;
  emitted_sparkles_ = 0;
  sparkle_rect_ = {};
  sparkle_phase_ = kSparklePhases;
  sparkle_next_us_ = 0;
  valid_ = true;
  return true;
}

void SettlePlanner::arm_scroll_settle(const PlutoRect &band, uint64_t now_us) {
  if (!valid_) {
    return;
  }
  const PlutoRect clipped = rect_clip(band, config_.width, config_.height);
  if (rect_is_empty(clipped)) {
    return;
  }
  const uint64_t ready_us =
      now_us + static_cast<uint64_t>(config_.perception.quiesce_ms()) * 1000u;
  // Re-arm an existing scroll entry: the band grows with the gesture and
  // its quiescence window is pushed forward every MOVE frame.
  for (ForcedSettle &forced : forced_) {
    if (rect_intersects(forced.rect, clipped)) {
      forced.rect = rect_union(forced.rect, clipped);
      forced.ready_us = ready_us;
      return;
    }
  }
  if (forced_.size() >= kMaxForced) {
    ForcedSettle &last = forced_.back();
    last.rect = rect_union(last.rect, clipped);
    last.ready_us = std::max(last.ready_us, ready_us);
    return;
  }
  forced_.push_back(ForcedSettle{clipped, ready_us});
}

void SettlePlanner::retire_forced(const PlutoRect &covered) {
  if (!valid_ || rect_is_empty(covered)) {
    return;
  }
  size_t w = 0;
  for (size_t i = 0; i < forced_.size(); ++i) {
    const PlutoRect &r = forced_[i].rect;
    const bool inside = r.x >= covered.x && r.y >= covered.y &&
                        rect_right(r) <= rect_right(covered) &&
                        rect_bottom(r) <= rect_bottom(covered);
    if (!inside) {
      forced_[w++] = forced_[i];
    }
  }
  forced_.resize(w);
}

size_t SettlePlanner::emit_forced(uint64_t now_us, RegionScheduler *scheduler) {
  const size_t burst_cap = config_.perception.settle_max_rects();
  size_t emitted = 0;
  PlutoRect emitted_union{0, 0, 0, 0};
  for (const ForcedSettle &forced : forced_) {
    if (emitted >= burst_cap) {
      break;
    }
    if (now_us < forced.ready_us) {
      continue;
    }
    // Text class repays the scroll band at GC16-family quality without a
    // color flash. The entry stays in
    // forced_ — retire_forced() drops it once a quality present actually
    // covered it on glass (re-emission handles cancel-on-redamage).
    scheduler->submit_settle(forced.rect, kPlutoRefreshText, now_us,
                             /*required=*/true);
    ++emitted_settles_;
    ++emitted;
    emitted_union = rect_is_empty(emitted_union)
                        ? forced.rect
                        : rect_union(emitted_union, forced.rect);
  }
  // Forced scroll settles get the same flash-free polish as ledger bursts:
  // scroll bodies are exactly the rail-heavy partials that leave
  // residual ghost after their Text repayment.
  if (!rect_is_empty(emitted_union)) {
    arm_sparkle(emitted_union, now_us);
  }
  return emitted;
}

void SettlePlanner::note_damage(const PlutoRect &rect, uint64_t now_us) {
  if (!valid_) {
    return;
  }
  grid_.for_each_tile(rect, [&](uint32_t tx, uint32_t ty) {
    last_damage_us_[grid_.index(tx, ty)] = now_us;
  });
  // Cancel an in-progress sparkle rotation over re-damaged content (ARC):
  // the repair work would be destroyed; the next settle burst re-arms it.
  if (sparkle_phase_ < kSparklePhases && rect_intersects(sparkle_rect_, rect)) {
    sparkle_phase_ = kSparklePhases;
  }
}

bool SettlePlanner::tile_eligible(uint32_t tx, uint32_t ty,
                                  uint64_t now_us) const {
  const size_t idx = grid_.index(tx, ty);
  const uint64_t last = last_damage_us_[idx];
  if (last == kNeverDamaged) {
    return false; // never damaged: nothing to repay
  }
  // Quiescence gate (ARC scan resistance): recently re-damaged tiles wait a
  // full window rather than flash-thrash.
  const uint64_t quiesce_us =
      static_cast<uint64_t>(config_.perception.quiesce_ms()) * 1000u;
  if (now_us < last + quiesce_us) {
    return false;
  }
  if (chroma_ != nullptr && config_.panel_is_color &&
      chroma_->pending(tx, ty)) {
    return true;
  }
  // Ghost eligibility is the accrual-time latch (GhostLedger::owed): the
  // decayed magnitude below only orders clusters, so the candidate SET is a
  // pure function of the dispatch history, not of tick phase.
  if (ghost_ != nullptr && ghost_->owed(tx, ty)) {
    return true;
  }
  if (stress_ != nullptr &&
      stress_->stress(tx, ty) >= config_.perception.stress_settle_threshold()) {
    return true;
  }
  return false;
}

// LSM-batch clustering with EXACT coverage: eligible tiles fold into
// maximal horizontal runs, and vertically adjacent runs with identical
// x-extent stack into one rect. Every emitted rect covers eligible tiles
// only — the max-added-area bound is ZERO by construction. That property is
// load-bearing twice over: it makes the union-flash amplification of the
// old chroma path structurally impossible, and it makes the cumulative
// settled coverage a pure function of the owed/chroma tile sets — however
// quiescence timing partitions the tiles into bursts, the covered area is
// identical, so the settled picture cannot depend on tick phase. Bounded
// nonzero fill-in (perception.settle_cluster_*) can only return once every
// present path is byte-idempotent on unchanged content.
void SettlePlanner::build_clusters() {
  clusters_.clear();
  // Fold the pre-collected eligible tiles (row-major order) into maximal
  // horizontal runs — identical to scanning the grid, but touching only the
  // eligible tiles rather than the whole plane.
  for (const uint32_t packed : eligible_tiles_) {
    const uint32_t tx = packed & 0xffffu;
    const uint32_t ty = packed >> 16;
    const PlutoRect tile = grid_.tile_rect(tx, ty);
    uint64_t debt = ghost_ != nullptr ? ghost_->debt(tx, ty) : 0;
    if (stress_ != nullptr) {
      debt += stress_->stress(tx, ty);
    }
    const bool tile_chroma = chroma_ != nullptr && config_.panel_is_color &&
                             chroma_->pending(tx, ty);
    if (tile_chroma) {
      // Undeveloped color outranks equal gray ghost debt.
      debt += 512;
    }
    // Extend the current horizontal run when contiguous.
    if (!clusters_.empty()) {
      Cluster &last = clusters_.back();
      if (last.rect.y == tile.y && rect_right(last.rect) == tile.x &&
          last.rect.height == tile.height) {
        last.rect.width += tile.width;
        last.debt += debt;
        ++last.tiles;
        last.chroma = last.chroma || tile_chroma;
        continue;
      }
    }
    Cluster c;
    c.rect = tile;
    c.debt = debt;
    c.chroma = tile_chroma;
    clusters_.push_back(c);
  }
  // Stack vertically adjacent runs with identical x-extent (still exact).
  //
  // Two runs stack only when they share (x, width) AND one's bottom edge meets
  // the other's top. The O(n^2) pairwise scan below is a no-op whenever no
  // such adjacency exists — the common case for dithered/scattered eligibility
  // (horizontal runs never line up vertically). Detect that in O(n log n) via
  // a sorted (x, width, y) probe and skip the merge entirely; the resulting
  // clusters_ is then byte-identical to the untouched input. When any
  // adjacency IS present we fall back to the exact original merge loop, which
  // correctly handles cascades that new adjacencies create.
  bool maybe_stack = clusters_.size() > 1;
  if (maybe_stack && config_.width < 0x10000 && config_.height < 0x10000 &&
      clusters_.size() <= 0xffffu) {
    maybe_stack = false;
    stack_probe_.clear();
    for (size_t i = 0; i < clusters_.size(); ++i) {
      const PlutoRect &r = clusters_[i].rect;
      stack_probe_.push_back((static_cast<uint64_t>(r.x) << 48) |
                             (static_cast<uint64_t>(r.width) << 32) |
                             (static_cast<uint64_t>(r.y) << 16) |
                             static_cast<uint64_t>(i));
    }
    std::sort(stack_probe_.begin(), stack_probe_.end());
    for (size_t k = 1; k < stack_probe_.size(); ++k) {
      // Consecutive entries share (x, width) when their top 32 bits match.
      if ((stack_probe_[k - 1] >> 32) != (stack_probe_[k] >> 32)) {
        continue;
      }
      const size_t upper = stack_probe_[k - 1] & 0xffffu; // smaller y
      const size_t lower = stack_probe_[k] & 0xffffu;
      if (rect_bottom(clusters_[upper].rect) == clusters_[lower].rect.y) {
        maybe_stack = true;
        break;
      }
    }
  }
  if (maybe_stack) {
    bool changed = true;
    while (changed) {
      changed = false;
      for (size_t i = 0; i < clusters_.size() && !changed; ++i) {
        for (size_t j = i + 1; j < clusters_.size(); ++j) {
          const PlutoRect &a = clusters_[i].rect;
          const PlutoRect &b = clusters_[j].rect;
          if (a.x != b.x || a.width != b.width ||
              (rect_bottom(a) != b.y && rect_bottom(b) != a.y)) {
            continue;
          }
          clusters_[i].rect = rect_union(a, b);
          clusters_[i].debt += clusters_[j].debt;
          clusters_[i].tiles += clusters_[j].tiles;
          clusters_[i].chroma = clusters_[i].chroma || clusters_[j].chroma;
          clusters_[j] = clusters_.back();
          clusters_.pop_back();
          changed = true;
          break;
        }
      }
    }
  }
  // Debt x saliency ordering: highest first.
  for (Cluster &c : clusters_) {
    c.score = c.debt * config_.perception.saliency_q8(c.rect, config_.width,
                                                      config_.height);
  }
  std::sort(
      clusters_.begin(), clusters_.end(),
      [](const Cluster &a, const Cluster &b) { return a.score > b.score; });
}

void SettlePlanner::tick(uint64_t now_us, RegionScheduler *scheduler,
                         bool maintenance_allowed,
                         bool intrusive_maintenance_allowed) {
  if (!valid_) {
    return;
  }
  if (ghost_ != nullptr) {
    ghost_->tick(now_us);
  }
  if (stress_ != nullptr) {
    stress_->tick(now_us);
  }
  if (scheduler == nullptr || !scheduler->valid()) {
    return;
  }
  // Lifecycle is an execution gate, not a debt signal. Keep every
  // ledger/candidate intact while the process is handing off or suspended.
  if (!maintenance_allowed) {
    return;
  }
  // One settle burst at a time: wait until the previous burst fully drained
  // (its dispatches cleared the ledgers, so eligibility below is accurate).
  if (scheduler->settle_work_pending()) {
    return;
  }

  // Forced stroke settles first (pen fast path): the user is looking at wet
  // ink that owes a true-content repaint; ghost-debt housekeeping waits.
  if (emit_forced(now_us, scheduler) != 0) {
    return;
  }

  // Broad-backlog budget: panel-wide achromatic debt becomes ONE full-screen
  // Text repayment instead of a train of regional jobs. Real chroma remains
  // exact and regional. One row-major eligibility scan feeds both this
  // decision and the clusterer — build_clusters consumes eligible_tiles_
  // instead of re-scanning the whole plane.
  eligible_tiles_.clear();
  for (uint32_t ty = 0; ty < grid_.rows; ++ty) {
    for (uint32_t tx = 0; tx < grid_.cols; ++tx) {
      if (tile_eligible(tx, ty, now_us)) {
        eligible_tiles_.push_back((ty << 16) | tx);
      }
    }
  }
  const size_t eligible = eligible_tiles_.size();
  if (eligible == 0) {
    // Sparkle trickle, LAST: quality repayment always outranks maintenance
    // polish — a pass fires only on a tick with no forced work and no
    // eligible backlog, so the settle train is completely independent of
    // sparkle pacing (replay determinism relies on this). Best-effort:
    // declined passes retry on the next interval.
    if (intrusive_maintenance_allowed && !config_.panel_is_color &&
        sparkle_phase_ < kSparklePhases && now_us >= sparkle_next_us_) {
      // Mono glass: 16-phase mode-8 top-off; new damage over the region
      // cancels the rotation (ARC), the next settle re-arms it.
      if (scheduler->submit_sparkle(sparkle_rect_, sparkle_phase_, now_us)) {
        ++sparkle_phase_;
        ++emitted_sparkles_;
      }
      sparkle_next_us_ = now_us + kSparkleIntervalUs;
    }
    return;
  }
  bool has_non_chroma_eligible = false;
  for (const uint32_t packed : eligible_tiles_) {
    const uint32_t tx = packed & 0xffffu;
    const uint32_t ty = packed >> 16;
    if (chroma_ == nullptr || !config_.panel_is_color ||
        !chroma_->pending(tx, ty)) {
      has_non_chroma_eligible = true;
      break;
    }
  }
  if (has_non_chroma_eligible &&
      eligible * 100 >
          grid_.tile_count() * config_.perception.settle_full_area_percent()) {
    // A broad GHOST backlog coalesces to one non-flashing Text repayment on
    // every panel. Never let one chroma tile promote the whole field to a
    // Full blackout. Chroma survives Text and is developed by exact regional
    // clusters on a later idle tick.
    const PlutoRefreshClass full_field_cls = kPlutoRefreshText;
    scheduler->submit_settle(PlutoRect{0, 0, config_.width, config_.height},
                             full_field_cls, now_us);
    ++emitted_settles_;
    if (full_field_cls == kPlutoRefreshFull) {
      ++emitted_full_flashes_;
    }
    arm_sparkle(PlutoRect{0, 0, config_.width, config_.height}, now_us);
    return;
  }

  build_clusters();
  const size_t burst =
      std::min<size_t>(clusters_.size(), config_.perception.settle_max_rects());
  PlutoRect settled_union{0, 0, 0, 0};
  for (size_t i = 0; i < burst; ++i) {
    const Cluster &c = clusters_[i];
    const PlutoRect rect =
        rect_align_out(c.rect, static_cast<int32_t>(config_.align_px),
                       config_.width, config_.height);
    if (rect_is_empty(rect)) {
      continue;
    }
    // Full is reserved for actual undeveloped chromatic content. The former
    // deep-ghost-debt promotion flashed achromatic 32 px regions through
    // GC16 and, on real Move glass, often left whites warmer than before.
    // Ghost-only regional debt is repaid by non-flashing Text; broad pigment
    // stress is handled once by AutoGhostbuster's global Bleach policy.
    const PlutoRefreshClass cls = c.chroma && config_.panel_is_color
                                      ? kPlutoRefreshFull
                                      : kPlutoRefreshText;
    if (cls == kPlutoRefreshFull && !intrusive_maintenance_allowed) {
      continue; // chroma debt remains latched for post-input execution
    }
    scheduler->submit_settle(rect, cls, now_us);
    if (cls == kPlutoRefreshFull) {
      ++emitted_full_flashes_;
    }
    ++emitted_settles_;
    settled_union =
        rect_is_empty(settled_union) ? rect : rect_union(settled_union, rect);
  }
  if (!rect_is_empty(settled_union)) {
    arm_sparkle(settled_union, now_us);
  }
}

void SettlePlanner::arm_sparkle(const PlutoRect &rect, uint64_t now_us) {
  if (!config_.enable_sparkle_topoff) {
    return;
  }
  // Re-arm mid-rotation grows the rect instead of dropping the old region's
  // remaining passes: the repair only touches white-family pixels and skips
  // busy tiles, so over-coverage is safe and reads uniform.
  if (config_.panel_is_color) {
    // Do not replace this with a masked GC16 identity sweep without new
    // optical evidence. The previous version was cheap in CPU terms but was
    // visibly destructive on the panel.
    return;
  }
  sparkle_rect_ =
      sparkle_phase_ < kSparklePhases ? rect_union(sparkle_rect_, rect) : rect;
  sparkle_phase_ = 0;
  // First pass only after the settle burst itself has fully drained AND a
  // fresh interval elapsed (tick() also gates on settle_work_pending()).
  sparkle_next_us_ = now_us + kSparkleIntervalUs;
}

bool SettlePlanner::export_state(SettlePlannerState *out) const {
  if (!valid_ || out == nullptr) {
    return false;
  }
  SettlePlannerState state;
  state.config = config_;
  state.last_damage_us = last_damage_us_;
  state.forced.reserve(forced_.size());
  for (const ForcedSettle &forced : forced_) {
    state.forced.push_back(
        SettlePlannerForcedState{forced.rect, forced.ready_us});
  }
  state.emitted_settles = emitted_settles_;
  state.emitted_full_flashes = emitted_full_flashes_;
  state.emitted_sparkles = emitted_sparkles_;
  state.sparkle_rect = sparkle_rect_;
  state.sparkle_phase = sparkle_phase_;
  state.sparkle_next_us = sparkle_next_us_;
  *out = std::move(state);
  return true;
}

bool SettlePlanner::import_state(const SettlePlannerState &state) {
  if (!valid_ || !same_config(state.config, config_) ||
      state.last_damage_us.size() != last_damage_us_.size() ||
      state.forced.size() > kMaxForced ||
      state.emitted_settles > std::numeric_limits<size_t>::max() ||
      state.emitted_full_flashes > std::numeric_limits<size_t>::max() ||
      state.emitted_sparkles > std::numeric_limits<size_t>::max() ||
      state.emitted_full_flashes > state.emitted_settles ||
      state.sparkle_phase > kSparklePhases ||
      !rect_within_surface(state.sparkle_rect, config_.width, config_.height,
                           /*allow_empty=*/true) ||
      (state.sparkle_phase < kSparklePhases &&
       (config_.panel_is_color || !config_.enable_sparkle_topoff ||
        rect_is_empty(state.sparkle_rect)))) {
    return false;
  }

  for (const SettlePlannerForcedState &entry : state.forced) {
    if (!rect_within_surface(entry.rect, config_.width, config_.height,
                             /*allow_empty=*/false)) {
      return false;
    }
  }

  // Scratch vectors describe only a transient tick and are intentionally not
  // persistent. Clear them as the correlated policy state is adopted.
  std::copy(state.last_damage_us.begin(), state.last_damage_us.end(),
            last_damage_us_.begin());
  // Preserve configure()'s kMaxForced reservation: handoff must not re-enable
  // allocation in the scheduler hot path.
  forced_.clear();
  for (const SettlePlannerForcedState &entry : state.forced) {
    forced_.push_back(ForcedSettle{entry.rect, entry.ready_us});
  }
  clusters_.clear();
  eligible_tiles_.clear();
  stack_probe_.clear();
  emitted_settles_ = static_cast<size_t>(state.emitted_settles);
  emitted_full_flashes_ = static_cast<size_t>(state.emitted_full_flashes);
  emitted_sparkles_ = static_cast<size_t>(state.emitted_sparkles);
  sparkle_rect_ = state.sparkle_rect;
  sparkle_phase_ = state.sparkle_phase;
  sparkle_next_us_ = state.sparkle_next_us;
  return true;
}

} // namespace pluto
