#include "renderer/region_scheduler.h"

#include <algorithm>
#include <limits>
#include <utility>

#include "renderer/rect_utils.h"

namespace pluto {
namespace {

size_t class_index(PlutoRefreshClass cls) { return refresh_class_index(cls); }

uint64_t scaled_latency_us(uint32_t base_us, float margin) {
  return static_cast<uint64_t>(static_cast<double>(base_us) * margin);
}

bool rect_covers(const PlutoRect &outer, const PlutoRect &inner) {
  return inner.x >= outer.x && inner.y >= outer.y &&
         rect_right(inner) <= rect_right(outer) &&
         rect_bottom(inner) <= rect_bottom(outer);
}

bool valid_rotation(uint32_t rotation) {
  return rotation == 0 || rotation == 90 || rotation == 180 || rotation == 270;
}

bool same_grid(const TileGrid &a, const TileGrid &b) {
  return a.width == b.width && a.height == b.height && a.tile_px == b.tile_px &&
         a.cols == b.cols && a.rows == b.rows;
}

RegionSchedulerStateConfig
persistent_config(const RegionSchedulerConfig &config) {
  RegionSchedulerStateConfig state;
  state.width = config.width;
  state.height = config.height;
  state.align_px = config.align_px;
  state.presenter_rotation = config.presenter_rotation;
  state.pen_collision_tile_px = config.pen_collision_tile_px;
  state.serialize_pen_truth_by_tile = config.serialize_pen_truth_by_tile;
  state.merge_gap_px = config.merge_gap_px;
  state.max_rects = config.max_rects;
  state.class_deadline_us = config.class_deadline_us;
  state.latency_model_us = config.latency_model_us;
  state.fence_margin = config.fence_margin;
  state.fence_timeout_ms = config.fence_timeout_ms;
  state.cbs_settle_budget_pct = config.cbs_settle_budget_pct;
  state.debt_promote_threshold = config.debt_promote_threshold;
  state.debt_promote_min_gap_us = config.debt_promote_min_gap_us;
  state.text_settle_nonintrusive = config.text_settle_nonintrusive;
  state.presenter_reports_completion = config.presenter_reports_completion;
  state.presenter_collision_safe = config.presenter_collision_safe;
  state.surface_stride_bytes = config.surface.stride_bytes;
  state.surface_width = config.surface.width;
  state.surface_height = config.surface.height;
  state.surface_format = static_cast<uint32_t>(config.surface.format);
  return state;
}

bool same_config(const RegionSchedulerStateConfig &a,
                 const RegionSchedulerStateConfig &b) {
  return a.width == b.width && a.height == b.height &&
         a.align_px == b.align_px &&
         a.presenter_rotation == b.presenter_rotation &&
         a.pen_collision_tile_px == b.pen_collision_tile_px &&
         a.serialize_pen_truth_by_tile == b.serialize_pen_truth_by_tile &&
         a.merge_gap_px == b.merge_gap_px && a.max_rects == b.max_rects &&
         a.class_deadline_us == b.class_deadline_us &&
         a.latency_model_us == b.latency_model_us &&
         a.fence_margin == b.fence_margin &&
         a.fence_timeout_ms == b.fence_timeout_ms &&
         a.cbs_settle_budget_pct == b.cbs_settle_budget_pct &&
         a.debt_promote_threshold == b.debt_promote_threshold &&
         a.debt_promote_min_gap_us == b.debt_promote_min_gap_us &&
         a.text_settle_nonintrusive == b.text_settle_nonintrusive &&
         a.presenter_reports_completion == b.presenter_reports_completion &&
         a.presenter_collision_safe == b.presenter_collision_safe &&
         a.surface_stride_bytes == b.surface_stride_bytes &&
         a.surface_width == b.surface_width &&
         a.surface_height == b.surface_height &&
         a.surface_format == b.surface_format;
}

// Phase-1 coalesce predicate. The original test was
//     rect_merge_waste(a,b) <= 0 || rect_gap_px(a,b) <= merge_gap
// but for NON-EMPTY rects `waste <= 0` implies `gap_px == 0`: any positive
// x-gap g forces the bounding box to be at least g*bbox_height wider than the
// two rects combined (symmetrically in y), so waste >= g*bbox_height > 0.
// Since merge_gap_px is unsigned (>= 0), `gap == 0` already satisfies the gap
// branch, making the waste term redundant. The whole predicate collapses to a
// single gap test — no union / area multiplies. (Verified: 0 counterexamples
// over 2e8 random non-empty pairs.) Phase-1 inputs are always non-empty:
// coalesce_queue only pushes non-empty aligned rects and every merge feeds
// rect_align_out(rect_union(non-empty, non-empty)).
bool rects_coalesce(const PlutoRect &a, const PlutoRect &b, int32_t gap) {
  return rect_gap_px(a, b) <= gap;
}

// Exact, disjoint rectangle difference. Top/bottom span the outer width;
// left/right cover only the overlap band. Both scheduler inputs are already
// clipped, and pen truth is aligned, so later presenter alignment cannot grow
// any piece back across the cut boundary.
size_t subtract_rect(const PlutoRect &outer, const PlutoRect &cut,
                     PlutoRect out[4]) {
  if (out == nullptr || rect_is_empty(outer)) {
    return 0;
  }
  const PlutoRect overlap = rect_intersection(outer, cut);
  if (rect_is_empty(overlap)) {
    out[0] = outer;
    return 1;
  }
  size_t count = 0;
  const auto push = [&](const PlutoRect &piece) {
    if (!rect_is_empty(piece)) {
      out[count++] = piece;
    }
  };
  push(PlutoRect{outer.x, outer.y, outer.width, overlap.y - outer.y});
  push(PlutoRect{outer.x, rect_bottom(overlap), outer.width,
                 rect_bottom(outer) - rect_bottom(overlap)});
  push(PlutoRect{outer.x, overlap.y, overlap.x - outer.x, overlap.height});
  push(PlutoRect{rect_right(overlap), overlap.y,
                 rect_right(outer) - rect_right(overlap), overlap.height});
  return count;
}

} // namespace

RegionScheduler::RegionScheduler(const RegionSchedulerConfig &config,
                                 RegionPresenterHooks presenter,
                                 GhostLedger *ghost, StressLedger *stress,
                                 ChromaPendingSet *chroma)
    : config_(config), presenter_(presenter), ghost_(ghost), stress_(stress),
      chroma_(chroma) {
  if (config_.width <= 0 || config_.height <= 0 || config_.align_px == 0 ||
      config_.pen_collision_tile_px == 0 ||
      config_.pen_collision_tile_px >
          static_cast<uint32_t>(std::numeric_limits<int32_t>::max()) ||
      !valid_rotation(config_.presenter_rotation)) {
    return;
  }
  const uint64_t pen_cell_cols =
      (static_cast<uint64_t>(config_.width) + k_pen_overload_cell_px - 1u) /
      k_pen_overload_cell_px;
  const uint64_t pen_cell_rows =
      (static_cast<uint64_t>(config_.height) + k_pen_overload_cell_px - 1u) /
      k_pen_overload_cell_px;
  if (pen_cell_cols * pen_cell_rows > k_max_pending_pen_truth) {
    return;
  }
  if (ghost_ != nullptr && ghost_->valid()) {
    last_submit_us_.assign(ghost_->grid().tile_count(), kNeverSubmitted);
  }
  valid_ = true;
}

void RegionScheduler::reserve_pen_focus(const PlutoRect &logical_focus,
                                        uint64_t expires_us) {
  if (!valid_ || !config_.serialize_pen_truth_by_tile || expires_us == 0) {
    clear_pen_focus();
    return;
  }
  pen_focus_rect_ = rect_clip(logical_focus, config_.width, config_.height);
  pen_focus_expires_us_ = rect_is_empty(pen_focus_rect_) ? 0 : expires_us;
}

void RegionScheduler::clear_pen_focus() {
  pen_focus_rect_ = {};
  pen_focus_expires_us_ = 0;
}

void RegionScheduler::expire_pen_focus(uint64_t now_us) {
  if (pen_focus_expires_us_ != UINT64_MAX && now_us >= pen_focus_expires_us_) {
    clear_pen_focus();
  }
}

bool RegionScheduler::discard_pending() {
  if (inflight_count_ != 0) {
    return false;
  }
  for (PendingQueue &queue : queues_) {
    queue.count = 0;
  }
  pen_truth_count_ = 0;
  pen_truth_cell_mode_ = false;
  pen_residual_count_ = 0;
  settle_count_ = 0;
  parked_count_ = 0;
  pen_preview_count_ = 0;
  pen_preview_cell_mode_ = false;
  return true;
}

bool RegionScheduler::discard_pending_maintenance_for_handoff() {
  if (inflight_count_ != 0 || user_work_pending()) {
    return false;
  }
  for (size_t i = 0; i < parked_count_; ++i) {
    if (!parked_[i].settle) {
      return false;
    }
  }
  settle_count_ = 0;
  parked_count_ = 0;
  return true;
}

// Newest-content-wins supersession: damage overlapping a
// pending same-class update folds into it — union rect, NEWEST content
// epoch, OLDEST enqueue time (merged updates inherit the oldest age so
// supersession can never starve a region). Presents read the live ledger,
// so folding is free: one pass presents the newest content.
void RegionScheduler::push_pending(PlutoRefreshClass cls, const PlutoRect &rect,
                                   uint64_t now_us, uint64_t epoch) {
  if (!refresh_class_valid(cls) || rect_is_empty(rect)) {
    return;
  }
  PendingQueue &q = queues_[class_index(cls)];
  for (size_t i = 0; i < q.count; ++i) {
    if (!rect_intersects(q.items[i].rect, rect)) {
      continue;
    }
    q.items[i].rect = rect_union(q.items[i].rect, rect);
    q.items[i].enqueue_us = std::min(q.items[i].enqueue_us, now_us);
    q.items[i].epoch = std::max(q.items[i].epoch, epoch);
    ++stat_superseded_;
    // The grown rect may now overlap other queued items: fold them in too.
    bool changed = true;
    while (changed) {
      changed = false;
      for (size_t j = 0; j < q.count; ++j) {
        if (j == i || !rect_intersects(q.items[i].rect, q.items[j].rect)) {
          continue;
        }
        q.items[i].rect = rect_union(q.items[i].rect, q.items[j].rect);
        q.items[i].enqueue_us =
            std::min(q.items[i].enqueue_us, q.items[j].enqueue_us);
        q.items[i].epoch = std::max(q.items[i].epoch, q.items[j].epoch);
        q.items[j] = q.items[q.count - 1];
        if (i == q.count - 1) {
          i = j; // the folded-into item moved into slot j
        }
        --q.count;
        changed = true;
        break;
      }
    }
    return;
  }
  if (q.count >= k_max_pending_per_class) {
    q.items[q.count - 1].rect = rect_union(q.items[q.count - 1].rect, rect);
    q.items[q.count - 1].enqueue_us =
        std::min(q.items[q.count - 1].enqueue_us, now_us);
    q.items[q.count - 1].epoch = std::max(q.items[q.count - 1].epoch, epoch);
    ++stat_superseded_;
    return;
  }
  q.items[q.count++] = PendingUpdate{rect, cls, now_us, epoch, false, false};
}

void RegionScheduler::add_pen_preview_cells(const PlutoRect &rect) {
  const int32_t cell = k_pen_overload_cell_px;
  const int32_t x0 = (rect.x / cell) * cell;
  const int32_t y0 = (rect.y / cell) * cell;
  for (int32_t y = y0; y < rect_bottom(rect); y += cell) {
    for (int32_t x = x0; x < rect_right(rect); x += cell) {
      const PlutoRect bounded =
          rect_clip(PlutoRect{x, y, cell, cell}, config_.width, config_.height);
      bool present = false;
      for (size_t i = 0; i < pen_preview_count_; ++i) {
        if (rect_covers(pen_preview_queue_[i].rect, bounded) &&
            rect_covers(bounded, pen_preview_queue_[i].rect)) {
          present = true;
          break;
        }
      }
      if (!present && pen_preview_count_ < k_max_pending_pen_preview) {
        pen_preview_queue_[pen_preview_count_++].rect = bounded;
      }
    }
  }
}

void RegionScheduler::collapse_pen_preview_to_cells() {
  const auto exact = pen_preview_queue_;
  const size_t exact_count = pen_preview_count_;
  pen_preview_count_ = 0;
  pen_preview_cell_mode_ = true;
  for (size_t i = 0; i < exact_count; ++i) {
    add_pen_preview_cells(exact[i].rect);
  }
}

void RegionScheduler::push_pen_preview(const PlutoRect &rect) {
  if (pen_preview_cell_mode_) {
    add_pen_preview_cells(rect);
    return;
  }
  for (size_t i = 0; i < pen_preview_count_; ++i) {
    if (rect_covers(pen_preview_queue_[i].rect, rect)) {
      return;
    }
  }
  size_t write = 0;
  size_t insert_at = pen_preview_count_;
  for (size_t read = 0; read < pen_preview_count_; ++read) {
    if (rect_covers(rect, pen_preview_queue_[read].rect)) {
      insert_at = std::min(insert_at, write);
      continue;
    }
    pen_preview_queue_[write++] = pen_preview_queue_[read];
  }
  if (insert_at == pen_preview_count_) {
    insert_at = write;
  }
  for (size_t i = write; i > insert_at; --i) {
    pen_preview_queue_[i] = pen_preview_queue_[i - 1];
  }
  pen_preview_queue_[insert_at].rect = rect;
  pen_preview_count_ = write + 1;
  if (pen_preview_count_ > k_max_exact_pen_segments) {
    collapse_pen_preview_to_cells();
  }
}

void RegionScheduler::add_pen_truth_cells(const PendingUpdate &pending) {
  const int32_t cell = k_pen_overload_cell_px;
  const int32_t x0 = (pending.rect.x / cell) * cell;
  const int32_t y0 = (pending.rect.y / cell) * cell;
  for (int32_t y = y0; y < rect_bottom(pending.rect); y += cell) {
    for (int32_t x = x0; x < rect_right(pending.rect); x += cell) {
      const PlutoRect bounded =
          rect_clip(PlutoRect{x, y, cell, cell}, config_.width, config_.height);
      size_t existing = pen_truth_count_;
      for (size_t i = 0; i < pen_truth_count_; ++i) {
        if (rect_covers(pen_truth_queue_[i].rect, bounded) &&
            rect_covers(bounded, pen_truth_queue_[i].rect)) {
          existing = i;
          break;
        }
      }
      if (existing == pen_truth_count_) {
        if (pen_truth_count_ < k_max_pending_pen_truth) {
          PendingUpdate cell_pending = pending;
          cell_pending.rect = bounded;
          pen_truth_queue_[pen_truth_count_++] = cell_pending;
        }
        continue;
      }
      PendingUpdate &cell_pending = pen_truth_queue_[existing];
      cell_pending.cls = promote_refresh_class(cell_pending.cls, pending.cls);
      cell_pending.enqueue_us =
          std::min(cell_pending.enqueue_us, pending.enqueue_us);
      cell_pending.epoch = std::max(cell_pending.epoch, pending.epoch);
      cell_pending.pen_preview_ready =
          cell_pending.pen_preview_ready || pending.pen_preview_ready;
    }
  }
}

void RegionScheduler::collapse_pen_truth_to_cells() {
  const auto exact = pen_truth_queue_;
  const size_t exact_count = pen_truth_count_;
  pen_truth_count_ = 0;
  pen_truth_cell_mode_ = true;
  for (size_t i = 0; i < exact_count; ++i) {
    add_pen_truth_cells(exact[i]);
  }
}

// Preserve the exact bounded geometry of a connected pen-truth component.
// Every segment shares the component's strongest still-owed quality, newest
// content epoch, and oldest age, but partial overlaps never become one bounding
// box. That lets an old, no-longer-conflicting trail segment chase the pen tip.
void RegionScheduler::propagate_pen_truth_component(size_t seed_index) {
  if (seed_index >= pen_truth_count_) {
    return;
  }
  // Component propagation only runs in exact mode (the 65th insertion
  // immediately collapses to bounded cells), so avoid clearing the much
  // larger overload-capacity array on every hot pen sample.
  std::array<bool, k_max_exact_pen_segments + 1> component = {};
  component[seed_index] = true;
  bool changed = true;
  while (changed) {
    changed = false;
    for (size_t i = 0; i < pen_truth_count_; ++i) {
      if (component[i]) {
        continue;
      }
      for (size_t j = 0; j < pen_truth_count_; ++j) {
        if (component[j] && rect_intersects(pen_truth_queue_[i].rect,
                                            pen_truth_queue_[j].rect)) {
          component[i] = true;
          changed = true;
          break;
        }
      }
    }
  }

  PlutoRefreshClass strongest = pen_truth_queue_[seed_index].cls;
  uint64_t newest_epoch = pen_truth_queue_[seed_index].epoch;
  uint64_t oldest_enqueue = pen_truth_queue_[seed_index].enqueue_us;
  for (size_t i = 0; i < pen_truth_count_; ++i) {
    if (!component[i]) {
      continue;
    }
    strongest = promote_refresh_class(strongest, pen_truth_queue_[i].cls);
    newest_epoch = std::max(newest_epoch, pen_truth_queue_[i].epoch);
    oldest_enqueue = std::min(oldest_enqueue, pen_truth_queue_[i].enqueue_us);
  }
  for (size_t i = 0; i < pen_truth_count_; ++i) {
    if (!component[i]) {
      continue;
    }
    pen_truth_queue_[i].cls = strongest;
    pen_truth_queue_[i].epoch = newest_epoch;
    pen_truth_queue_[i].enqueue_us = oldest_enqueue;
  }
}

// Pen truth has its own fixed queue: unlike maintenance SETTLE it may not be
// throttled, cancelled by policy, or demoted into the generic parked list.
// Exact/containment-redundant geometry coalesces. Partial overlap stays as
// bounded segments and only propagates quality/epoch/age across the component.
void RegionScheduler::push_pen_truth(PlutoRefreshClass cls,
                                     const PlutoRect &rect, uint64_t now_us,
                                     uint64_t epoch, bool pen_preview_ready) {
  if ((cls != kPlutoRefreshText && cls != kPlutoRefreshFull) ||
      rect_is_empty(rect)) {
    return;
  }

  PendingUpdate candidate{rect,  cls,   now_us,           epoch,
                          false, false, pen_preview_ready};
  if (pen_truth_cell_mode_) {
    add_pen_truth_cells(candidate);
    return;
  }
  // If an existing segment already covers this geometry, the candidate adds
  // no pixels. OR preserves an already-earned Full turn: a later contained
  // submission is read from the live surface by that quality pass.
  for (size_t i = 0; i < pen_truth_count_; ++i) {
    PendingUpdate &pending = pen_truth_queue_[i];
    if (!rect_covers(pending.rect, candidate.rect)) {
      continue;
    }
    pending.cls = promote_refresh_class(pending.cls, candidate.cls);
    pending.enqueue_us = std::min(pending.enqueue_us, candidate.enqueue_us);
    pending.epoch = std::max(pending.epoch, candidate.epoch);
    pending.pen_preview_ready =
        pending.pen_preview_ready || candidate.pen_preview_ready;
    propagate_pen_truth_component(i);
    ++stat_superseded_;
    return;
  }

  // Conversely, one larger candidate exactly supersedes every contained
  // segment. Keep the earliest queue position and any already-earned Full turn.
  size_t write = 0;
  size_t insert_at = pen_truth_count_;
  bool removed = false;
  for (size_t read = 0; read < pen_truth_count_; ++read) {
    const PendingUpdate &pending = pen_truth_queue_[read];
    if (rect_covers(candidate.rect, pending.rect)) {
      insert_at = std::min(insert_at, write);
      candidate.cls = promote_refresh_class(candidate.cls, pending.cls);
      candidate.enqueue_us = std::min(candidate.enqueue_us, pending.enqueue_us);
      candidate.epoch = std::max(candidate.epoch, pending.epoch);
      candidate.pen_preview_ready =
          candidate.pen_preview_ready || pending.pen_preview_ready;
      removed = true;
      continue;
    }
    pen_truth_queue_[write++] = pending;
  }
  if (removed) {
    for (size_t i = write; i > insert_at; --i) {
      pen_truth_queue_[i] = pen_truth_queue_[i - 1];
    }
    pen_truth_queue_[insert_at] = candidate;
    pen_truth_count_ = write + 1;
    propagate_pen_truth_component(insert_at);
    ++stat_superseded_;
    return;
  }

  if (pen_truth_count_ < k_max_pending_pen_truth) {
    const size_t inserted = pen_truth_count_++;
    pen_truth_queue_[inserted] = candidate;
    propagate_pen_truth_component(inserted);
    if (pen_truth_count_ > k_max_exact_pen_segments) {
      collapse_pen_truth_to_cells();
    }
    return;
  }
}

bool RegionScheduler::push_pen_residual(const PendingUpdate &pending) {
  PendingUpdate aligned = pending;
  aligned.rect =
      rect_align_out(pending.rect, static_cast<int32_t>(config_.align_px),
                     config_.width, config_.height);
  if (rect_is_empty(aligned.rect) ||
      pen_residual_count_ >= k_max_pending_pen_residual) {
    return false;
  }
  pen_residual_queue_[pen_residual_count_++] = aligned;
  return true;
}

void RegionScheduler::promote_pen_residual(
    const PendingUpdate &pending, PlutoRefreshClass minimum_truth_class,
    uint64_t truth_epoch) {
  PlutoRefreshClass cls =
      promote_refresh_class(pending.cls, minimum_truth_class);
  cls = promote_refresh_class(cls, kPlutoRefreshText);
  const PlutoRect aligned =
      rect_align_out(pending.rect, static_cast<int32_t>(config_.align_px),
                     config_.width, config_.height);
  push_pen_truth(cls, aligned, pending.enqueue_us, truth_epoch,
                 /*pen_preview_ready=*/true);
}

void RegionScheduler::promote_all_pending_to_full_truth(uint64_t enqueue_us,
                                                        uint64_t truth_epoch) {
  // Fixed-storage overload safety valve. A newest-surface full-screen truth is
  // expensive but preserves every pixel and quality obligation. Once queued,
  // all lower pending/parked/maintenance copies are redundant and must vanish;
  // retaining any of them could repaint below Full after this fallback.
  const PlutoRect full{0, 0, config_.width, config_.height};
  push_pen_truth(kPlutoRefreshFull, full, enqueue_us,
                 std::max(truth_epoch, damage_epoch_),
                 /*pen_preview_ready=*/true);
  for (PendingQueue &queue : queues_) {
    queue.count = 0;
  }
  pen_residual_count_ = 0;
  settle_count_ = 0;
  parked_count_ = 0;
}

bool RegionScheduler::reconcile_pen_residuals_with_truth(
    const PlutoRect &truth, PlutoRefreshClass truth_class, uint64_t truth_epoch,
    size_t residual_begin) {
  // Prefix entries were cut around every truth that was active when they
  // entered this lane. Rechecking that immutable, unrelated history for each
  // new generic rectangle made admission O(active_truth * all_residuals).
  // Only the tail at residual_begin and the pieces derived from it can still
  // intersect this truth snapshot. Swap-removal and all appended pieces stay
  // within that tail, so the exact prefix remains untouched.
  size_t i = residual_begin;
  while (i < pen_residual_count_) {
    const PendingUpdate pending = pen_residual_queue_[i];
    const PlutoRect overlap = rect_intersection(pending.rect, truth);
    if (rect_is_empty(overlap)) {
      ++i;
      continue;
    }
    pen_residual_queue_[i] = pen_residual_queue_[pen_residual_count_ - 1];
    --pen_residual_count_;

    PendingUpdate quality = pending;
    quality.rect = overlap;
    promote_pen_residual(quality, truth_class,
                         std::max(truth_epoch, pending.epoch));

    PlutoRect pieces[4] = {};
    const size_t count = subtract_rect(pending.rect, truth, pieces);
    if (pen_residual_count_ + count > k_max_pending_pen_residual) {
      promote_all_pending_to_full_truth(pending.enqueue_us,
                                        std::max(truth_epoch, pending.epoch));
      return false;
    }
    for (size_t p = 0; p < count; ++p) {
      PendingUpdate residual = pending;
      residual.rect = pieces[p];
      (void)push_pen_residual(residual);
    }
    ++stat_superseded_;
  }
  return true;
}

bool RegionScheduler::route_damage_around_active_pen_truth(
    const PendingUpdate &pending) {
  // Snapshot pending truth before adding follow-up intersections below.
  // Inflight entries are immutable during this scheduler-thread-confined
  // operation.
  std::array<PlutoRect, k_max_pending_pen_truth> truth_rects;
  std::array<PlutoRefreshClass, k_max_pending_pen_truth> truth_classes;
  const size_t truth_count = pen_truth_count_;
  for (size_t i = 0; i < truth_count; ++i) {
    truth_rects[i] = pen_truth_queue_[i].rect;
    truth_classes[i] = pen_truth_queue_[i].cls;
  }
  bool any = truth_count != 0;
  for (size_t i = 0; i < inflight_count_; ++i) {
    any = any || inflight_[i].pen_truth;
  }
  if (!any) {
    return false;
  }

  const size_t residual_begin = pen_residual_count_;
  if (!push_pen_residual(pending)) {
    promote_all_pending_to_full_truth(pending.enqueue_us, pending.epoch);
    return true;
  }

  // First reconcile against the immutable in-flight geometry, then against
  // the pending snapshot. Only the intersections become follow-up truth; a
  // tiny pen overlap therefore cannot turn a full-screen generic box into a
  // full-screen quality pass.
  for (size_t i = 0; i < inflight_count_; ++i) {
    const Inflight &inflight = inflight_[i];
    if (!inflight.pen_truth) {
      continue;
    }
    if (inflight.rect_count == 0) {
      if (!reconcile_pen_residuals_with_truth(inflight.rect, inflight.cls,
                                              pending.epoch, residual_begin)) {
        return true;
      }
      continue;
    }
    for (size_t r = 0; r < inflight.rect_count; ++r) {
      if (!reconcile_pen_residuals_with_truth(inflight.rects[r], inflight.cls,
                                              pending.epoch, residual_begin)) {
        return true;
      }
    }
  }
  for (size_t i = 0; i < truth_count; ++i) {
    if (!reconcile_pen_residuals_with_truth(truth_rects[i], truth_classes[i],
                                            pending.epoch, residual_begin)) {
      return true;
    }
  }
  return true;
}

void RegionScheduler::supersede_generic_with_pen_truth(
    const PlutoRect &truth, PlutoRefreshClass truth_class,
    uint64_t truth_epoch) {
  if (rect_is_empty(truth)) {
    return;
  }

  // Route one older generic item around the new truth. The overlap is already
  // owned by the current-surface truth pass. A stronger old obligation (Full
  // under Text truth) explicitly promotes that overlap instead of being
  // silently downgraded. Exact residual pieces retain the old class/age/epoch.
  const auto route = [&](const PendingUpdate &pending) {
    const PlutoRect overlap = rect_intersection(pending.rect, truth);
    if (rect_is_empty(overlap)) {
      if (!push_pen_residual(pending)) {
        promote_all_pending_to_full_truth(pending.enqueue_us, truth_epoch);
        return false;
      }
      return true;
    }
    if (static_cast<int>(pending.cls) > static_cast<int>(truth_class)) {
      PendingUpdate stronger = pending;
      stronger.rect = overlap;
      promote_pen_residual(stronger, truth_class, truth_epoch);
    }

    PlutoRect pieces[4] = {};
    const size_t count = subtract_rect(pending.rect, truth, pieces);
    if (pen_residual_count_ + count > k_max_pending_pen_residual) {
      // Hard overload invariant: never bbox/coalesce lower-class pieces across
      // the truth hole and never lose the remainder. A newest full-screen Full
      // truth safely subsumes every fixed queue when exact storage is
      // exhausted.
      promote_all_pending_to_full_truth(pending.enqueue_us, truth_epoch);
      return false;
    }
    for (size_t i = 0; i < count; ++i) {
      PendingUpdate residual = pending;
      residual.rect = pieces[i];
      (void)push_pen_residual(residual);
    }
    ++stat_superseded_;
    return true;
  };

  // Re-cut residuals left by earlier truths. Swap-removal is safe because the
  // newly appended pieces are disjoint from this cut and may simply be scanned
  // later in the same loop.
  size_t i = 0;
  while (i < pen_residual_count_) {
    const PendingUpdate pending = pen_residual_queue_[i];
    if (pending.epoch >= truth_epoch || !rect_intersects(pending.rect, truth)) {
      ++i;
      continue;
    }
    pen_residual_queue_[i] = pen_residual_queue_[pen_residual_count_ - 1];
    --pen_residual_count_;
    if (!route(pending)) {
      return;
    }
  }

  // Ordinary class queues are allowed to coalesce aggressively, so every
  // affected item leaves that storage entirely. Only its exact outside pieces
  // enter the non-coalescing residual lane.
  for (PendingQueue &queue : queues_) {
    i = 0;
    while (i < queue.count) {
      const PendingUpdate pending = queue.items[i];
      if (pending.epoch >= truth_epoch) {
        ++i;
        continue;
      }
      queue.items[i] = queue.items[queue.count - 1];
      --queue.count;
      if (!route(pending)) {
        return;
      }
    }
  }

  // Non-settle parked work has the same lower-lane risk once its blocker
  // completes. Move its exact outside pieces into the residual lane now;
  // conflicts_inflight will keep them waiting without re-coalescing them.
  i = 0;
  while (i < parked_count_) {
    const PendingUpdate pending = parked_[i];
    if (pending.settle || pending.epoch >= truth_epoch) {
      ++i;
      continue;
    }
    parked_[i] = parked_[parked_count_ - 1];
    --parked_count_;
    if (!route(pending)) {
      return;
    }
  }
}

bool RegionScheduler::ready_full_truth_pending() const {
  for (size_t i = 0; i < pen_truth_count_; ++i) {
    if (pen_truth_queue_[i].cls == kPlutoRefreshFull &&
        pen_truth_queue_[i].pen_preview_ready) {
      return true;
    }
  }
  return false;
}

void RegionScheduler::submit_damage(const PlutoRect *rects,
                                    const PlutoRefreshClass *classes,
                                    size_t count, uint64_t now_us) {
  if (!valid_ || rects == nullptr || classes == nullptr || count == 0) {
    return;
  }
  // Advance existing debt to the admission timestamp before adding this
  // frame's impulse. Relying on the later policy tick makes the result depend
  // on whether the idle renderer thread happened to tick first: without this
  // fence, a newly submitted impulse can be decayed over the entire idle gap
  // that preceded it. Besides being physically wrong, that ordering made an
  // imported warm process and an uninterrupted process accrue different debt
  // for the same timestamped content stream.
  if (ghost_ != nullptr) {
    ghost_->tick(now_us);
  }
  if (stress_ != nullptr) {
    stress_->tick(now_us);
  }
  ++damage_epoch_;
  for (size_t i = 0; i < count; ++i) {
    if (!refresh_class_valid(classes[i])) {
      continue;
    }
    // Scheduler geometry remains logical. AbiPresentBridge is the sole owner
    // of logical-to-panel rotation, so doing it here would double-rotate and
    // can clip valid damage on a non-square 90-degree surface.
    const PlutoRect logical_rect =
        rect_clip(rects[i], config_.width, config_.height);
    if (rect_is_empty(logical_rect)) {
      continue;
    }
    // Ghost/stress accrue HERE, on the exact post-quantize rects: the debt
    // (and with it the settle-eligibility latch) is a pure function of the
    // content stream. Accruing on dispatched drive rects would make the
    // owed set depend on timing-sensitive merge geometry — and the settled
    // picture with it. Quality-class repayment stays at dispatch (only what
    // actually reached glass clears debt).
    PlutoRefreshClass cls = classes[i];
    if (cls == kPlutoRefreshFast || cls == kPlutoRefreshUi) {
      // Debt-adaptive promotion (smart fast partials): a region that keeps
      // updating slower than the animation gap but faster than settle
      // quiescence re-arms the planner's window forever — its ghost would
      // never be repaid while the activity continues. Once the accumulated
      // debt crosses the promote line, THIS update dispatches as Text: same
      // pixels, quality drive, ledger cleared at dispatch, so the duty
      // cycle self-tunes per tile. Decided on pre-accrual debt; a promoted
      // update is quality-class and accrues nothing.
      if (debt_promotes(logical_rect, now_us)) {
        cls = kPlutoRefreshText;
        ++stat_debt_promoted_;
        // Do not turn inferred rail stress into ChromaPending. That set is
        // reserved for actual undeveloped color content; using it as an
        // optical-yellow proxy produced repeated regional Full blackouts and
        // warmer white glass on the Move. AutoGhostbuster independently
        // aggregates pigment exposure for a balanced global Bleach.
      } else {
        if (ghost_ != nullptr) {
          ghost_->accrue(logical_rect, cls);
        }
        if (stress_ != nullptr) {
          stress_->accrue(logical_rect, cls);
        }
      }
      stamp_submit(logical_rect, now_us);
    }
    const PendingUpdate pending{logical_rect,  cls,   now_us,
                                damage_epoch_, false, false};
    if (!route_damage_around_active_pen_truth(pending)) {
      push_pending(cls, logical_rect, now_us, damage_epoch_);
    }
    // Cancel-on-redamage (fast-then-settle): a queued settle whose
    // region just took new damage loses its slot; the SettlePlanner re-arms
    // after the region quiesces again (ARC scan resistance).
    size_t w = 0;
    for (size_t s = 0; s < settle_count_; ++s) {
      if (!rect_intersects(settle_queue_[s].rect, logical_rect)) {
        settle_queue_[w++] = settle_queue_[s];
      }
    }
    settle_count_ = w;
  }
}

void RegionScheduler::submit_pen_damage(const PlutoRect &preview_rect,
                                        const PlutoRect &truth_rect,
                                        PlutoRefreshClass truth_class,
                                        uint64_t now_us) {
  if (!valid_) {
    return;
  }
  const int32_t align = static_cast<int32_t>(config_.align_px);
  const PlutoRect preview =
      rect_align_out(preview_rect, align, config_.width, config_.height);
  const PlutoRect truth =
      rect_align_out(truth_rect, align, config_.width, config_.height);
  const bool has_preview = !rect_is_empty(preview);
  const bool has_truth =
      !rect_is_empty(truth) &&
      (truth_class == kPlutoRefreshText || truth_class == kPlutoRefreshFull);
  if (!has_preview && !has_truth) {
    return;
  }
  // As for generic damage, decay only debt that existed before this pen
  // event. The preview impulse starts at `now_us`, independent of background
  // tick scheduling.
  if (ghost_ != nullptr) {
    ghost_->tick(now_us);
  }
  if (stress_ != nullptr) {
    stress_->tick(now_us);
  }
  ++damage_epoch_;

  if (has_preview) {
    push_pen_preview(preview);

    // Preview is a real Fast repaint of app pixels, so charge precisely the
    // submitted damage. Truth repays that debt when its quality pass lands.
    if (ghost_ != nullptr) {
      ghost_->accrue(preview, kPlutoRefreshFast);
    }
    if (stress_ != nullptr) {
      stress_->accrue(preview, kPlutoRefreshFast);
    }
    stamp_submit(preview, now_us);
  }
  if (has_truth) {
    push_pen_truth(truth_class, truth, now_us, damage_epoch_,
                   /*pen_preview_ready=*/!has_preview);
    supersede_generic_with_pen_truth(truth, truth_class, damage_epoch_);
  }

  // Pen-driven app damage invalidates stale background repair just like a
  // generic frame submission. Pen truth itself is never stored here.
  size_t write = 0;
  for (size_t i = 0; i < settle_count_; ++i) {
    const bool preview_hit =
        has_preview && rect_intersects(settle_queue_[i].rect, preview);
    const bool truth_hit =
        has_truth && rect_intersects(settle_queue_[i].rect, truth);
    if (!preview_hit && !truth_hit) {
      settle_queue_[write++] = settle_queue_[i];
    }
  }
  settle_count_ = write;

  // A settle may already have moved behind an overlapping in-flight update.
  // Redamage cancels that parked maintenance copy too; otherwise it would
  // unpark after the pen truth and add an obsolete quality pass/flash.
  write = 0;
  for (size_t i = 0; i < parked_count_; ++i) {
    const bool preview_hit =
        has_preview && rect_intersects(parked_[i].rect, preview);
    const bool truth_hit = has_truth && rect_intersects(parked_[i].rect, truth);
    if (!parked_[i].settle || (!preview_hit && !truth_hit)) {
      parked_[write++] = parked_[i];
    }
  }
  parked_count_ = write;
}

void RegionScheduler::submit_settle(const PlutoRect &rect,
                                    PlutoRefreshClass cls, uint64_t now_us,
                                    bool required) {
  if (!valid_ || rect_is_empty(rect) ||
      (cls != kPlutoRefreshText && cls != kPlutoRefreshFull)) {
    return;
  }
  if (settle_count_ >= k_max_pending_settle) {
    return; // ledger debt persists; the planner re-emits later
  }
  const PlutoRect clipped = rect_clip(rect, config_.width, config_.height);
  if (rect_is_empty(clipped)) {
    return;
  }
  settle_queue_[settle_count_++] =
      PendingUpdate{clipped, cls, now_us, damage_epoch_, true, required};
}

bool RegionScheduler::notify_completion(uint64_t frame_id) {
  for (size_t i = 0; i < inflight_count_; ++i) {
    if (inflight_[i].frame_id == frame_id) {
      remove_inflight(i);
      return true;
    }
  }
  return false;
}

bool RegionScheduler::presenter_ready(PlutoRefreshClass cls) const {
  return presenter_.ready == nullptr ||
         presenter_.ready(presenter_.user_data, cls);
}

bool RegionScheduler::full_inflight() const {
  for (size_t i = 0; i < inflight_count_; ++i) {
    if (inflight_[i].cls == kPlutoRefreshFull && !inflight_[i].pen_truth) {
      return true;
    }
  }
  return false;
}

bool RegionScheduler::pixel_reset_inflight() const {
  for (size_t i = 0; i < inflight_count_; ++i) {
    if (inflight_[i].pixel_reset) {
      return true;
    }
  }
  return false;
}

// Value-aware admission at region granularity: an overlap
// with an in-flight update is a conflict ONLY if the pending content is
// newer than what the in-flight presents. An in-flight that fully covers
// the rect WITH ONE OF ITS PRESENTED DAMAGE RECTS (never the union — its
// interior was not repainted), carries a content epoch at least as new,
// and presents at >= the requested quality already shows exactly this
// content — the damage is redundant and absorbed for free.
bool RegionScheduler::absorbed_by_inflight(const PlutoRect &rect,
                                           PlutoRefreshClass cls,
                                           uint64_t epoch) const {
  for (size_t i = 0; i < inflight_count_; ++i) {
    const Inflight &inflight = inflight_[i];
    if (epoch > inflight.epoch ||
        static_cast<int>(inflight.cls) < static_cast<int>(cls)) {
      continue;
    }
    for (size_t r = 0; r < inflight.rect_count; ++r) {
      if (rect_covers(inflight.rects[r], rect)) {
        return true;
      }
    }
  }
  return false;
}

bool RegionScheduler::conflicts_inflight(const PlutoRect &rect) const {
  if (config_.presenter_collision_safe) {
    return false;
  }
  for (size_t i = 0; i < inflight_count_; ++i) {
    const Inflight &inflight = inflight_[i];
    if (inflight.rect_count != 0) {
      for (size_t r = 0; r < inflight.rect_count; ++r) {
        if (rect_intersects(rect, inflight.rects[r])) {
          return true;
        }
      }
    } else if (rect_intersects(rect, inflight.rect)) {
      return true; // conservative fallback for a non-pen oversized batch
    }
  }
  return false;
}

PlutoRect RegionScheduler::presenter_rect(const PlutoRect &logical) const {
  switch (config_.presenter_rotation) {
  case 90:
    return PlutoRect{config_.height - logical.y - logical.height, logical.x,
                     logical.height, logical.width};
  case 180:
    return PlutoRect{config_.width - logical.x - logical.width,
                     config_.height - logical.y - logical.height, logical.width,
                     logical.height};
  case 270:
    return PlutoRect{logical.y, config_.width - logical.x - logical.width,
                     logical.height, logical.width};
  default:
    return logical;
  }
}

PlutoRect RegionScheduler::logical_rect(const PlutoRect &presenter) const {
  switch (config_.presenter_rotation) {
  case 90:
    return PlutoRect{presenter.y,
                     config_.height - presenter.x - presenter.width,
                     presenter.height, presenter.width};
  case 180:
    return PlutoRect{config_.width - presenter.x - presenter.width,
                     config_.height - presenter.y - presenter.height,
                     presenter.width, presenter.height};
  case 270:
    return PlutoRect{config_.width - presenter.y - presenter.height,
                     presenter.x, presenter.height, presenter.width};
  default:
    return presenter;
  }
}

PlutoRect RegionScheduler::pen_focus_tile_bounds_presenter() const {
  if (rect_is_empty(pen_focus_rect_)) {
    return {};
  }
  const PlutoRect physical = presenter_rect(pen_focus_rect_);
  const int32_t tile = static_cast<int32_t>(config_.pen_collision_tile_px);
  const int32_t panel_width =
      config_.presenter_rotation == 90 || config_.presenter_rotation == 270
          ? config_.height
          : config_.width;
  const int32_t panel_height =
      config_.presenter_rotation == 90 || config_.presenter_rotation == 270
          ? config_.width
          : config_.height;
  const int32_t x0 = (physical.x / tile) * tile;
  const int32_t y0 = (physical.y / tile) * tile;
  const int32_t x1 = static_cast<int32_t>(std::min<int64_t>(
      panel_width,
      ((static_cast<int64_t>(rect_right(physical)) + tile - 1) / tile) * tile));
  const int32_t y1 = static_cast<int32_t>(std::min<int64_t>(
      panel_height,
      ((static_cast<int64_t>(rect_bottom(physical)) + tile - 1) / tile) *
          tile));
  return PlutoRect{x0, y0, x1 - x0, y1 - y0};
}

bool RegionScheduler::shares_pen_collision_tile(
    const PlutoRect &logical_left, const PlutoRect &logical_right) const {
  if (!config_.serialize_pen_truth_by_tile || rect_is_empty(logical_left) ||
      rect_is_empty(logical_right)) {
    return false;
  }
  const PlutoRect left = presenter_rect(logical_left);
  const PlutoRect right = presenter_rect(logical_right);
  const int32_t tile = static_cast<int32_t>(config_.pen_collision_tile_px);
  const int32_t lx0 = left.x / tile;
  const int32_t ly0 = left.y / tile;
  const int32_t lx1 = (rect_right(left) - 1) / tile;
  const int32_t ly1 = (rect_bottom(left) - 1) / tile;
  const int32_t rx0 = right.x / tile;
  const int32_t ry0 = right.y / tile;
  const int32_t rx1 = (rect_right(right) - 1) / tile;
  const int32_t ry1 = (rect_bottom(right) - 1) / tile;
  return lx0 <= rx1 && rx0 <= lx1 && ly0 <= ry1 && ry0 <= ly1;
}

bool RegionScheduler::pen_truth_batch_compatible(const PlutoRect &candidate,
                                                 const PlutoRect *batch,
                                                 size_t batch_count) const {
  if (batch == nullptr || batch_count == 0) {
    return true;
  }

  bool shares_tile = false;
  for (size_t i = 0; i < batch_count; ++i) {
    if (rect_intersects(candidate, batch[i]) ||
        shares_pen_collision_tile(candidate, batch[i])) {
      shares_tile = true;
      break;
    }
  }
  if (!shares_tile) {
    return true;
  }
  if (!config_.serialize_pen_truth_by_tile) {
    return false;
  }

  // Mirror the mapped presenter's 8x2 execution padding after the ABI bridge
  // has rotated logical damage into panel coordinates. A spanning operation
  // stays on the legacy dense path, and therefore may never be batched with
  // another operation that claims one of its tiles.
  const int32_t tile = static_cast<int32_t>(config_.pen_collision_tile_px);
  if (tile <= 0 || (tile & 7) != 0 || (tile & 1) != 0) {
    return false;
  }
  const auto contained_tile = [tile](const PlutoRect &rect, int32_t *out_tx,
                                     int32_t *out_ty) {
    if (rect_is_empty(rect)) {
      return false;
    }
    const int32_t execution_width = (rect.width + 7) & ~7;
    const int32_t execution_height = (rect.height + 1) & ~1;
    const int32_t tx = rect.x / tile;
    const int32_t ty = rect.y / tile;
    if ((rect.x + execution_width - 1) / tile != tx ||
        (rect.y + execution_height - 1) / tile != ty) {
      return false;
    }
    *out_tx = tx;
    *out_ty = ty;
    return true;
  };

  const PlutoRect physical_candidate = presenter_rect(candidate);
  int32_t group_tx = 0;
  int32_t group_ty = 0;
  if (!contained_tile(physical_candidate, &group_tx, &group_ty)) {
    return false;
  }
  PlutoRect group_union = physical_candidate;
  for (size_t i = 0; i < batch_count; ++i) {
    if (!rect_intersects(candidate, batch[i]) &&
        !shares_pen_collision_tile(candidate, batch[i])) {
      continue;
    }
    const PlutoRect physical = presenter_rect(batch[i]);
    int32_t tx = 0;
    int32_t ty = 0;
    if (!contained_tile(physical, &tx, &ty) || tx != group_tx ||
        ty != group_ty) {
      return false;
    }
    group_union = rect_union(group_union, physical);
  }

  int32_t union_tx = 0;
  int32_t union_ty = 0;
  return contained_tile(group_union, &union_tx, &union_ty) &&
         union_tx == group_tx && union_ty == group_ty;
}

bool RegionScheduler::conflicts_pen_focus_tile(const PlutoRect &rect) const {
  return !rect_is_empty(pen_focus_rect_) &&
         shares_pen_collision_tile(rect, pen_focus_rect_);
}

bool RegionScheduler::conflicts_pen_lane_tile(const PlutoRect &rect) const {
  if (!config_.serialize_pen_truth_by_tile || rect_is_empty(rect)) {
    return false;
  }
  if (conflicts_pen_focus_tile(rect)) {
    return true;
  }
  for (size_t i = 0; i < inflight_count_; ++i) {
    const Inflight &inflight = inflight_[i];
    if (!inflight.pen_preview && !inflight.pen_truth) {
      continue;
    }
    if (inflight.rect_count == 0) {
      if (shares_pen_collision_tile(rect, inflight.rect)) {
        return true;
      }
      continue;
    }
    for (size_t r = 0; r < inflight.rect_count; ++r) {
      if (shares_pen_collision_tile(rect, inflight.rects[r])) {
        return true;
      }
    }
  }
  return false;
}

bool RegionScheduler::conflicts_mapped_pen_tile(const PlutoRect &rect) const {
  if (!config_.serialize_pen_truth_by_tile || rect_is_empty(rect)) {
    return false;
  }
  if (conflicts_pen_lane_tile(rect)) {
    return true;
  }
  for (size_t i = 0; i < pen_preview_count_; ++i) {
    if (shares_pen_collision_tile(rect, pen_preview_queue_[i].rect)) {
      return true;
    }
  }
  for (size_t i = 0; i < pen_truth_count_; ++i) {
    if (shares_pen_collision_tile(rect, pen_truth_queue_[i].rect)) {
      return true;
    }
  }
  return false;
}

bool RegionScheduler::pen_truth_has_unblocked_candidate() const {
  for (size_t i = 0; i < pen_truth_count_; ++i) {
    // Only the explicit proximity reservation relaxes global strict priority.
    // Presenter refusal, preview readiness, and ordinary in-flight overlap
    // retain the established truth-before-generic contract.
    if (!conflicts_pen_focus_tile(pen_truth_queue_[i].rect)) {
      return true;
    }
  }
  return false;
}

void RegionScheduler::park_rect(PlutoRefreshClass cls, const PlutoRect &rect,
                                uint64_t now_us, uint64_t epoch, bool settle,
                                bool required) {
  ++stat_parked_;
  if (parked_count_ >= k_max_parked) {
    if (parked_count_ > 0) {
      PendingUpdate &last = parked_[parked_count_ - 1];
      last.rect = rect_union(last.rect, rect);
      last.cls = promote_refresh_class(last.cls, cls);
      last.epoch = std::max(last.epoch, epoch);
      last.settle = last.settle && settle;
      last.required = last.required && required;
    }
    return;
  }
  parked_[parked_count_++] =
      PendingUpdate{rect, cls, now_us, epoch, settle, required};
}

void RegionScheduler::unpark_all() {
  if (parked_count_ == 0) {
    return;
  }
  const size_t count = parked_count_;
  parked_count_ = 0;
  for (size_t i = 0; i < count; ++i) {
    const PendingUpdate &p = parked_[i];
    if (p.settle) {
      if (settle_count_ < k_max_pending_settle) {
        settle_queue_[settle_count_++] = p;
      }
      // else: dropped; ledger debt persists and the planner re-emits.
    } else {
      push_pending(p.cls, p.rect, p.enqueue_us, p.epoch);
    }
  }
}

void RegionScheduler::remove_inflight(size_t index) {
  inflight_[index] = inflight_[inflight_count_ - 1];
  --inflight_count_;
  unpark_all();
}

void RegionScheduler::complete_due(uint64_t now_us) {
  size_t i = 0;
  while (i < inflight_count_) {
    const bool serialized_real_reset =
        inflight_[i].pixel_reset && inflight_[i].real_completion;
    const bool timeout =
        !serialized_real_reset &&
        now_us >= inflight_[i].submit_us +
                      static_cast<uint64_t>(config_.fence_timeout_ms) * 1000u;
    const bool synthetic_due =
        !inflight_[i].real_completion && now_us >= inflight_[i].eta_us;
    if (timeout || synthetic_due) {
      if (timeout && inflight_[i].real_completion) {
        real_completion_overdue_ = true;
      }
      remove_inflight(i);
    } else {
      ++i;
    }
  }
}

// Min-added-area merge within one class (mode-gated by construction: each
// queue holds a single class, so merging can never cross refresh classes).
void RegionScheduler::merge_scratch_to_cap(size_t *count, size_t cap) {
  if (count == nullptr || *count <= 1) {
    return;
  }
  bool changed = true;
  while (changed) {
    changed = false;
    for (size_t i = 0; i < *count && !changed; ++i) {
      for (size_t j = i + 1; j < *count; ++j) {
        if (rects_coalesce(scratch_rects_[i], scratch_rects_[j],
                           static_cast<int32_t>(config_.merge_gap_px))) {
          scratch_rects_[i] =
              rect_align_out(rect_union(scratch_rects_[i], scratch_rects_[j]),
                             static_cast<int32_t>(config_.align_px),
                             config_.width, config_.height);
          scratch_rects_[j] = scratch_rects_[*count - 1];
          --(*count);
          changed = true;
          break;
        }
      }
    }
  }
  // Phase 2: min-added-area reduction to the cap. The selection is EXACTLY
  // the retired full-rescan's: merge the lexicographically-first pair (i, j),
  // i < j, attaining the minimum rect_merge_waste; write the aligned union to
  // i and swap the last rect into j. The O(rounds * n^2) full rescan is
  // replaced by per-row cached minima — row i caches the minimum (waste, j)
  // over j > i with the smallest such j — plus targeted invalidation: after a
  // merge only rows whose own rect changed (i == best_i / best_j), whose
  // cached partner changed (cached j in {best_i, best_j}) or moved (cached
  // j >= n) are rebuilt; every other row's cached pair is untouched by the
  // merge, so folding the two changed indices into its cache as a running
  // lexicographic (waste, j) minimum reproduces the ascending rescan's
  // tie-break exactly. Byte-identical reduction sequence (pinned by
  // RegionSchedulerTest.MergeToCapMatchesFullRescanReference); the win is
  // the scattered-damage storm, where reducing a full 256-rect queue to the
  // class cap was a multi-ms O(n^3) cliff.
  if (*count <= cap || *count <= 1) {
    return;
  }
  size_t n = *count;
  std::array<int64_t, k_max_pending_per_class> row_waste;
  std::array<uint16_t, k_max_pending_per_class> row_j;
  const auto recompute_row = [&](size_t i) {
    int64_t best = rect_merge_waste(scratch_rects_[i], scratch_rects_[i + 1]);
    size_t best_j = i + 1;
    for (size_t j = i + 2; j < n; ++j) {
      const int64_t waste =
          rect_merge_waste(scratch_rects_[i], scratch_rects_[j]);
      if (waste < best) {
        best = waste;
        best_j = j;
      }
    }
    row_waste[i] = best;
    row_j[i] = static_cast<uint16_t>(best_j);
  };
  for (size_t i = 0; i + 1 < n; ++i) {
    recompute_row(i);
  }
  while (n > cap && n > 1) {
    size_t best_i = 0;
    for (size_t i = 1; i + 1 < n; ++i) {
      if (row_waste[i] < row_waste[best_i]) {
        best_i = i;
      }
    }
    const size_t best_j = row_j[best_i];
    scratch_rects_[best_i] = rect_align_out(
        rect_union(scratch_rects_[best_i], scratch_rects_[best_j]),
        static_cast<int32_t>(config_.align_px), config_.width, config_.height);
    scratch_rects_[best_j] = scratch_rects_[n - 1];
    --n;
    if (n <= cap || n <= 1) {
      break;
    }
    for (size_t k = 0; k + 1 < n; ++k) {
      if (k == best_i || k == best_j || row_j[k] == best_i ||
          row_j[k] == best_j || row_j[k] >= n) {
        recompute_row(k);
        continue;
      }
      if (best_i > k) {
        const int64_t waste =
            rect_merge_waste(scratch_rects_[k], scratch_rects_[best_i]);
        if (waste < row_waste[k] ||
            (waste == row_waste[k] && best_i < row_j[k])) {
          row_waste[k] = waste;
          row_j[k] = static_cast<uint16_t>(best_i);
        }
      }
      if (best_j > k && best_j < n) {
        const int64_t waste =
            rect_merge_waste(scratch_rects_[k], scratch_rects_[best_j]);
        if (waste < row_waste[k] ||
            (waste == row_waste[k] && best_j < row_j[k])) {
          row_waste[k] = waste;
          row_j[k] = static_cast<uint16_t>(best_j);
        }
      }
    }
  }
  *count = n;
}

size_t RegionScheduler::coalesce_queue(PlutoRefreshClass cls,
                                       uint64_t *out_epoch) {
  // Guard dilation is the GuardBandPackager's job; the scheduler only
  // aligns to the presenter's rect grid.
  PendingQueue &q = queues_[class_index(cls)];
  size_t count = 0;
  uint64_t epoch = 0;
  for (size_t i = 0; i < q.count && count < k_max_pending_per_class; ++i) {
    const PlutoRect aligned =
        rect_align_out(q.items[i].rect, static_cast<int32_t>(config_.align_px),
                       config_.width, config_.height);
    if (!rect_is_empty(aligned)) {
      scratch_rects_[count] = aligned;
      epoch = std::max(epoch, q.items[i].epoch);
      ++count;
    }
  }
  q.count = 0;
  merge_scratch_to_cap(&count, config_.max_rects[class_index(cls)]);
  if (out_epoch != nullptr) {
    *out_epoch = epoch;
  }
  return count;
}

void RegionScheduler::accrue_ledgers(const PlutoRect &rect,
                                     PlutoRefreshClass cls) {
  switch (cls) {
  case kPlutoRefreshFast:
  case kPlutoRefreshUi:
    // Rail-class debt accrued at submit_damage (deterministic content
    // rects); the pen path accrues at submit_pen_damage. Nothing to do
    // here.
    break;
  case kPlutoRefreshText:
    // GC16-family quality pass: repays ghost/stress; chroma stays pending
    // (only a Full develops color on glass).
    if (ghost_ != nullptr) {
      ghost_->clear(rect);
    }
    if (stress_ != nullptr) {
      stress_->clear(rect);
    }
    break;
  case kPlutoRefreshFull:
    if (ghost_ != nullptr) {
      ghost_->clear(rect);
    }
    if (stress_ != nullptr) {
      stress_->clear(rect);
    }
    if (chroma_ != nullptr) {
      chroma_->clear(rect);
    }
    break;
  }
}

bool RegionScheduler::debt_promotes(const PlutoRect &rect,
                                    uint64_t now_us) const {
  if (ghost_ == nullptr || last_submit_us_.empty()) {
    return false;
  }
  // A promotion turns this update into a ~3x longer quality drive; never
  // hand one to a region with work already on glass.
  if (conflicts_inflight(rect)) {
    return false;
  }
  const TileGrid &grid = ghost_->grid();
  uint64_t debt_sum = 0;
  uint32_t tiles = 0;
  bool quiet = true;
  grid.for_each_tile(rect, [&](uint32_t tx, uint32_t ty) {
    const uint64_t last = last_submit_us_[grid.index(tx, ty)];
    // Rate gate: ANY tile updating faster than the gap marks the region as
    // animating — rail-class cadence wins, the settle planner repays at
    // rest. Never-touched tiles are quiet by definition (debt 0 anyway).
    if (last != kNeverSubmitted &&
        now_us < last + config_.debt_promote_min_gap_us) {
      quiet = false;
    }
    debt_sum += ghost_->debt(tx, ty);
    ++tiles;
  });
  return quiet && tiles != 0 &&
         debt_sum >=
             static_cast<uint64_t>(config_.debt_promote_threshold) * tiles;
}

void RegionScheduler::stamp_submit(const PlutoRect &rect, uint64_t now_us) {
  if (ghost_ == nullptr || last_submit_us_.empty()) {
    return;
  }
  const TileGrid &grid = ghost_->grid();
  grid.for_each_tile(rect, [&](uint32_t tx, uint32_t ty) {
    last_submit_us_[grid.index(tx, ty)] = now_us;
  });
}

RegionScheduler::DispatchResult
RegionScheduler::dispatch_batch(PlutoRefreshClass cls, const PlutoRect *rects,
                                size_t count, uint64_t now_us, uint32_t flags,
                                bool settle, bool pixel_reset, uint64_t epoch) {
  const bool regional_pen_full =
      cls == kPlutoRefreshFull && (flags & kPlutoPresentFlagPenTruth) != 0;
  const bool pen_lane =
      (flags & (kPlutoPresentFlagInkPriority | kPlutoPresentFlagPenTruth)) != 0;
  if (count == 0 || rects == nullptr || pixel_reset_inflight() ||
      (full_inflight() && !pen_lane)) {
    return DispatchResult::kDeclined;
  }
  if (cls == kPlutoRefreshFull && !regional_pen_full && inflight_count_ != 0) {
    return DispatchResult::kDeclined;
  }
  if (!presenter_ready(cls) || inflight_count_ >= k_max_inflight) {
    return DispatchResult::kDeclined;
  }

  // Value-aware region admission: absorb redundant rects, park genuine
  // conflicts. The batch epoch is conservative (max over merged items).
  // The pen-preview lane bypasses both gates: it is current app damage and is
  // never parked — the present ABI's legacy-named InkPriority bit maps to the
  // engine ride-along admission that arbitrates in-flight same-rail overlap,
  // and parking here would add a waveform of lag.
  // Sparkle passes bypass them too: the
  // engine skips busy tiles itself, and a parked sparkle would lose its
  // flags and re-present as plain content.
  const bool bypass_region_admission =
      (flags & (kPlutoPresentFlagInkPriority | kPlutoPresentFlagSparkle)) != 0;
  std::array<PlutoRect, k_max_pending_per_class> kept;
  size_t kept_count = 0;
  bool conflict = false;
  for (size_t i = 0; i < count; ++i) {
    if (!bypass_region_admission &&
        absorbed_by_inflight(rects[i], cls, epoch)) {
      ++stat_absorbed_;
      continue;
    }
    if (!bypass_region_admission && conflicts_inflight(rects[i])) {
      conflict = true;
    }
    kept[kept_count++] = rects[i];
  }
  if (kept_count == 0) {
    return DispatchResult::kAbsorbed;
  }
  if (conflict) {
    for (size_t i = 0; i < kept_count; ++i) {
      park_rect(cls, kept[i], now_us, epoch, settle,
                (flags & kPlutoPresentFlagRequiredSettle) != 0);
    }
    return DispatchResult::kParked;
  }

  PlutoRect union_rect = kept[0];
  for (size_t i = 1; i < kept_count; ++i) {
    union_rect = rect_union(union_rect, kept[i]);
  }

  const uint64_t frame_id = next_frame_id_++;
  PlutoPresentRequest request{};
  request.struct_size = sizeof(request);
  request.surface = config_.surface;
  request.damage = kept.data();
  request.damage_count = kept_count;
  request.refresh_class = cls;
  request.flags =
      flags | (settle ? static_cast<uint32_t>(kPlutoPresentFlagSettle) : 0u);
  request.frame_id = frame_id;

  // The Inflight entry must exist before present() runs so a presenter that
  // completes synchronously on the present stack can find its frame
  // (completion-race contract, re-pinned in region_scheduler_test.cc).
  Inflight inflight{};
  inflight.frame_id = frame_id;
  inflight.rect = union_rect;
  inflight.cls = cls;
  inflight.submit_us = now_us;
  inflight.eta_us =
      now_us + scaled_latency_us(config_.latency_model_us[class_index(cls)],
                                 config_.fence_margin);
  inflight.epoch = damage_epoch_;
  inflight.real_completion = config_.presenter_reports_completion;
  inflight.settle = settle;
  inflight.pixel_reset = pixel_reset;
  inflight.pen_preview = (flags & kPlutoPresentFlagInkPriority) != 0;
  inflight.pen_truth = (flags & kPlutoPresentFlagPenTruth) != 0;
  // The rects actually presented (absorption tests coverage against these,
  // never the union). Overflow leaves rect_count = 0: absorption then
  // never matches this entry — conservative, parking still sees the union.
  if (kept_count <= k_max_inflight_rects) {
    for (size_t i = 0; i < kept_count; ++i) {
      inflight.rects[i] = kept[i];
    }
    inflight.rect_count = kept_count;
  }
  inflight_[inflight_count_++] = inflight;

  if (presenter_.present != nullptr &&
      !presenter_.present(presenter_.user_data, &request)) {
    // Roll back by id: a synchronous completion during the refused present()
    // may already have removed (and swapped) the provisional entry. The
    // rects are NOT requeued here — that is the caller's job, exactly once.
    for (size_t i = 0; i < inflight_count_; ++i) {
      if (inflight_[i].frame_id == frame_id) {
        inflight_[i] = inflight_[inflight_count_ - 1];
        --inflight_count_;
        break;
      }
    }
    return DispatchResult::kDeclined;
  }

  ++cbs_total_slots_;
  if (settle) {
    ++cbs_settle_slots_;
    ++stat_settles_;
  } else {
    ++stat_dispatched_;
  }
  for (size_t i = 0; i < kept_count; ++i) {
    accrue_ledgers(kept[i], cls);
  }
  return DispatchResult::kDispatched;
}

bool RegionScheduler::submit_sparkle(const PlutoRect &rect, uint32_t phase,
                                     uint64_t now_us, bool develop) {
  if (!valid_ || rect_is_empty(rect) || pen_preview_count_ != 0 ||
      pen_truth_count_ != 0 || full_inflight()) {
    return false; // best-effort: a skipped pass retries next rotation
  }
  const uint32_t flags =
      static_cast<uint32_t>(kPlutoPresentFlagSparkle) |
      (develop ? static_cast<uint32_t>(kPlutoPresentFlagSparkleDevelop) : 0u) |
      ((phase & 0xffu) << kPlutoPresentSparklePhaseShift);
  return dispatch_batch(kPlutoRefreshFast, &rect, 1, now_us, flags,
                        /*settle=*/false,
                        /*pixel_reset=*/false,
                        /*epoch=*/0) == DispatchResult::kDispatched;
}

bool RegionScheduler::submit_pixel_reset_stage(const PlutoRect &rect,
                                               uint32_t flags, uint64_t now_us,
                                               PlutoRefreshClass cls) {
  constexpr uint32_t kRailFlags =
      kPlutoPresentFlagPixelResetBlack | kPlutoPresentFlagPixelResetWhite;
  constexpr uint32_t kAllowedFlags =
      kRailFlags | kPlutoPresentFlagPixelResetRestore;
  const bool rail = (flags & kRailFlags) != 0;
  const bool restore = (flags & kPlutoPresentFlagPixelResetRestore) != 0;
  if (!valid_ || rect_is_empty(rect) || inflight_count_ != 0 ||
      (flags & ~kAllowedFlags) != 0 || ((flags & kRailFlags) == kRailFlags) ||
      (rail && restore) || (rail && cls != kPlutoRefreshFast) ||
      (restore && cls != kPlutoRefreshFull) ||
      (!rail && !restore && cls != kPlutoRefreshFast)) {
    return false;
  }
  return dispatch_batch(cls, &rect, 1, now_us, flags,
                        /*settle=*/false,
                        /*pixel_reset=*/true,
                        /*epoch=*/UINT64_MAX) == DispatchResult::kDispatched;
}

void RegionScheduler::poll_completions(uint64_t now_us) {
  if (valid_) {
    complete_due(now_us);
  }
}

bool RegionScheduler::retire_pixel_reset_after_presenter_idle() {
  if (inflight_count_ == 0) {
    return true;
  }
  for (size_t i = 0; i < inflight_count_; ++i) {
    if (!inflight_[i].pixel_reset) {
      return false;
    }
  }
  inflight_count_ = 0;
  unpark_all();
  return true;
}

bool RegionScheduler::try_dispatch_pen_preview(uint64_t now_us) {
  if (pen_preview_count_ == 0 || pixel_reset_inflight()) {
    return false;
  }
  std::array<bool, k_max_pending_pen_preview> selected = {};
  size_t count = 0;
  for (size_t i = 0; i < pen_preview_count_; ++i) {
    bool overlaps_batch = false;
    for (size_t p = 0; p < count; ++p) {
      if (rect_intersects(pen_preview_queue_[i].rect, scratch_rects_[p])) {
        overlaps_batch = true;
        break;
      }
    }
    if (overlaps_batch) {
      continue;
    }
    selected[i] = true;
    scratch_rects_[count++] = pen_preview_queue_[i].rect;
    if (count == k_max_pen_present_rects) {
      break;
    }
  }
  if (count == 0) {
    return false;
  }
  // NO conflicts_inflight gate: serializing pen-priority app damage behind
  // its own in-flight Fast frame batches fresh preview pixels for a whole
  // waveform (~130 ms). The engine arbitrates overlap safely (the present
  // ABI's legacy-named InkPriority bit rides along in-flight same-mode tiles
  // via retarget), so the preview dispatches every tick.
  //
  // On decline this lane keeps sole ownership of the rect and retries on the
  // next tick. Preview is never absorbed because it is the freshest surface
  // content in the latency-critical pen neighborhood.
  if (dispatch_batch(kPlutoRefreshFast, scratch_rects_.data(), count, now_us,
                     kPlutoPresentFlagInkPriority,
                     /*settle=*/false,
                     /*pixel_reset=*/false,
                     /*epoch=*/UINT64_MAX) == DispatchResult::kDispatched) {
    // Record the preview-before-Full contract per bounded truth segment. Text
    // does not need the gate, but retaining this bit lets later color damage
    // promote its connected component without losing an already-earned turn.
    for (size_t i = 0; i < pen_truth_count_; ++i) {
      for (size_t p = 0; p < count; ++p) {
        if (rect_intersects(pen_truth_queue_[i].rect, scratch_rects_[p])) {
          pen_truth_queue_[i].pen_preview_ready = true;
          break;
        }
      }
    }
    size_t write = 0;
    for (size_t read = 0; read < pen_preview_count_; ++read) {
      if (!selected[read]) {
        pen_preview_queue_[write++] = pen_preview_queue_[read];
      }
    }
    pen_preview_count_ = write;
    if (pen_preview_count_ == 0) {
      pen_preview_cell_mode_ = false;
    }
    return true;
  }
  return false;
}

bool RegionScheduler::try_dispatch_pen_truth(uint64_t now_us) {
  if (pen_truth_count_ == 0 || pixel_reset_inflight()) {
    return false;
  }

  // Pen-truth Full is regional, unlike ordinary Full/pixel reset. Batch up to
  // 64 preview-ready, nonconflicting segments while unrelated Fast/quality
  // work continues elsewhere; exact in-flight geometry prevents gap-filled
  // bounding boxes from blocking a trailing segment.
  if (ready_full_truth_pending()) {
    std::array<bool, k_max_pending_pen_truth> selected = {};
    size_t selected_count = 0;
    uint64_t epoch = 0;
    for (size_t i = 0; i < pen_truth_count_; ++i) {
      const PendingUpdate &pending = pen_truth_queue_[i];
      if (pending.cls != kPlutoRefreshFull || !pending.pen_preview_ready) {
        continue;
      }
      const bool pen_tile_conflict = conflicts_pen_lane_tile(pending.rect);
      if (conflicts_inflight(pending.rect) || pen_tile_conflict) {
        stat_pen_truth_tile_holds_ += pen_tile_conflict ? 1u : 0u;
        stat_pen_focus_tile_holds_ +=
            pen_tile_conflict && conflicts_pen_focus_tile(pending.rect) ? 1u
                                                                        : 0u;
        continue;
      }
      if (!pen_truth_batch_compatible(pending.rect, scratch_rects_.data(),
                                      selected_count)) {
        continue;
      }
      selected[i] = true;
      scratch_rects_[selected_count++] = pending.rect;
      epoch = std::max(epoch, pending.epoch);
      if (selected_count == k_max_pen_present_rects) {
        break;
      }
    }
    if (selected_count != 0 && !presenter_ready(kPlutoRefreshFull)) {
      return false;
    }
    if (selected_count != 0) {
      const DispatchResult result =
          dispatch_batch(kPlutoRefreshFull, scratch_rects_.data(),
                         selected_count, now_us, kPlutoPresentFlagPenTruth,
                         /*settle=*/false,
                         /*pixel_reset=*/false, epoch);
      if (result != DispatchResult::kDispatched &&
          result != DispatchResult::kAbsorbed) {
        return false; // decline retains every selected segment in place
      }
      size_t write = 0;
      for (size_t read = 0; read < pen_truth_count_; ++read) {
        if (!selected[read]) {
          pen_truth_queue_[write++] = pen_truth_queue_[read];
        }
      }
      pen_truth_count_ = write;
      if (pen_truth_count_ == 0) {
        pen_truth_cell_mode_ = false;
      }
      return true;
    }
  }

  if (!presenter_ready(kPlutoRefreshText)) {
    return false;
  }
  // Scan FIFO for nonconflicting Text segments. On an exact mapped presenter,
  // one request may carry every exact rectangle that shares a physical tile:
  // the presenter combines their coverage into one masked transaction, so no
  // unchanged lane is driven and repeated same-tile waveforms disappear. A
  // busy tip still does not head-of-line-block an older trail segment.
  std::array<bool, k_max_pending_pen_truth> selected = {};
  size_t selected_count = 0;
  uint64_t epoch = 0;
  for (size_t index = 0; index < pen_truth_count_; ++index) {
    const PendingUpdate pending = pen_truth_queue_[index];
    if (pending.cls != kPlutoRefreshText ||
        (config_.serialize_pen_truth_by_tile && !pending.pen_preview_ready)) {
      continue;
    }
    const bool pen_tile_conflict = conflicts_pen_lane_tile(pending.rect);
    if (conflicts_inflight(pending.rect) || pen_tile_conflict) {
      stat_pen_truth_tile_holds_ += pen_tile_conflict ? 1u : 0u;
      stat_pen_focus_tile_holds_ +=
          pen_tile_conflict && conflicts_pen_focus_tile(pending.rect) ? 1u : 0u;
      continue;
    }
    if (!pen_truth_batch_compatible(pending.rect, scratch_rects_.data(),
                                    selected_count)) {
      continue;
    }
    selected[index] = true;
    scratch_rects_[selected_count++] = pending.rect;
    epoch = std::max(epoch, pending.epoch);
    if (!config_.serialize_pen_truth_by_tile ||
        selected_count == k_max_pen_present_rects) {
      break;
    }
  }
  if (selected_count == 0) {
    return false;
  }
  const DispatchResult result =
      dispatch_batch(kPlutoRefreshText, scratch_rects_.data(), selected_count,
                     now_us, kPlutoPresentFlagPenTruth,
                     /*settle=*/false,
                     /*pixel_reset=*/false, epoch);
  if (result != DispatchResult::kDispatched &&
      result != DispatchResult::kAbsorbed) {
    // kDeclined retains special ownership. kParked is unreachable because
    // the conflict gate and dispatch run on the same scheduler thread.
    return false;
  }
  size_t write = 0;
  for (size_t read = 0; read < pen_truth_count_; ++read) {
    if (!selected[read]) {
      pen_truth_queue_[write++] = pen_truth_queue_[read];
    }
  }
  pen_truth_count_ = write;
  if (pen_truth_count_ == 0) {
    pen_truth_cell_mode_ = false;
  }
  return true;
}

bool RegionScheduler::try_dispatch_pen_residual(uint64_t now_us) {
  if (pen_residual_count_ == 0 || full_inflight() ||
      inflight_count_ >= k_max_inflight) {
    return false;
  }

  // Exact residuals are still ordinary user work. Pick the earliest eligible
  // class deadline, but never coalesce its geometry: that would rebuild the
  // pen-truth hole this lane exists to preserve.
  size_t head = pen_residual_count_;
  uint64_t best_deadline = UINT64_MAX;
  for (size_t i = 0; i < pen_residual_count_; ++i) {
    const PendingUpdate &pending = pen_residual_queue_[i];
    const bool mapped_pen_conflict = (pending.cls == kPlutoRefreshText ||
                                      pending.cls == kPlutoRefreshFull) &&
                                     conflicts_mapped_pen_tile(pending.rect);
    if ((pending.cls == kPlutoRefreshFull && inflight_count_ != 0) ||
        !presenter_ready(pending.cls) || conflicts_inflight(pending.rect) ||
        mapped_pen_conflict) {
      stat_pen_focus_tile_holds_ +=
          mapped_pen_conflict && conflicts_pen_focus_tile(pending.rect) ? 1u
                                                                        : 0u;
      continue;
    }
    const uint64_t deadline =
        pending.enqueue_us +
        config_.class_deadline_us[class_index(pending.cls)];
    if (deadline < best_deadline) {
      best_deadline = deadline;
      head = i;
    }
  }
  if (head == pen_residual_count_) {
    return false;
  }

  const PlutoRefreshClass cls = pen_residual_queue_[head].cls;
  const size_t batch_cap =
      std::max<size_t>(1, config_.max_rects[class_index(cls)]);
  std::array<size_t, k_max_pen_present_rects> selected = {};
  size_t selected_count = 0;
  selected[selected_count++] = head;
  for (size_t i = 0; i < pen_residual_count_ && selected_count < batch_cap &&
                     selected_count < k_max_pen_present_rects;
       ++i) {
    if (i == head || pen_residual_queue_[i].cls != cls ||
        conflicts_inflight(pen_residual_queue_[i].rect) ||
        ((cls == kPlutoRefreshText || cls == kPlutoRefreshFull) &&
         conflicts_mapped_pen_tile(pen_residual_queue_[i].rect))) {
      continue;
    }
    bool overlaps_batch = false;
    for (size_t s = 0; s < selected_count; ++s) {
      if (rect_intersects(pen_residual_queue_[i].rect,
                          pen_residual_queue_[selected[s]].rect)) {
        overlaps_batch = true;
        break;
      }
    }
    if (!overlaps_batch) {
      selected[selected_count++] = i;
    }
  }
  std::sort(selected.begin(), selected.begin() + selected_count);
  uint64_t epoch = 0;
  for (size_t i = 0; i < selected_count; ++i) {
    const PendingUpdate &pending = pen_residual_queue_[selected[i]];
    scratch_rects_[i] = pending.rect;
    epoch = std::max(epoch, pending.epoch);
  }

  const DispatchResult result =
      dispatch_batch(cls, scratch_rects_.data(), selected_count, now_us,
                     kPlutoPresentFlagNone, /*settle=*/false,
                     /*pixel_reset=*/false, epoch);
  if (result == DispatchResult::kDeclined) {
    return false;
  }
  // kParked is unreachable: eligibility and dispatch admission run on this
  // same scheduler thread. Treat it as transferred ownership defensively.
  size_t write = 0;
  size_t selected_cursor = 0;
  for (size_t read = 0; read < pen_residual_count_; ++read) {
    if (selected_cursor < selected_count && read == selected[selected_cursor]) {
      ++selected_cursor;
      continue;
    }
    pen_residual_queue_[write++] = pen_residual_queue_[read];
  }
  pen_residual_count_ = write;
  return result == DispatchResult::kDispatched;
}

bool RegionScheduler::try_dispatch_class(PlutoRefreshClass cls,
                                         uint64_t now_us) {
  if (full_inflight()) {
    return false;
  }
  if (cls == kPlutoRefreshFull && inflight_count_ != 0) {
    return false;
  }
  if (!presenter_ready(cls)) {
    return false; // queue untouched; retried when the presenter is ready
  }
  PendingQueue &q = queues_[class_index(cls)];
  if (q.count == 0) {
    return false;
  }

  // Exact-colour Text/Full becomes a mapped journal which claims whole
  // presenter tiles. Keep focus/pending-pen tiles in the queue, but continue
  // with exact disjoint items so one stationary hover cannot freeze unrelated
  // renderer work. Avoid coalescing in this split path: a union of two safe
  // rects can cross the reserved physical tile between them.
  const bool mapped_quality =
      config_.serialize_pen_truth_by_tile &&
      (cls == kPlutoRefreshText || cls == kPlutoRefreshFull);
  if (mapped_quality) {
    // Cut one large mapped obligation in PRESENTER coordinates around the
    // active tile-aligned focus hole. The up-to-four outside pieces are then
    // inverse-rotated and sent in one request without logical re-alignment;
    // AbiPresentBridge maps them back to the same disjoint physical pieces.
    // This lets a full-screen Full update progress in parallel everywhere
    // unrelated instead of becoming four sequential long waveforms. Only the
    // exact overlap remains queued with its original Full/Text obligation.
    const PlutoRect physical_focus = pen_focus_tile_bounds_presenter();
    if (!rect_is_empty(physical_focus)) {
      for (size_t i = 0; i < q.count; ++i) {
        const PendingUpdate raw_pending = q.items[i];
        // A prior physical-space split leaves the exact held hole inverse-
        // rotated into logical coordinates. On a 954px reflected edge that
        // geometry is phase-shifted by 2/6px from the logical 8px grid. Do not
        // align it before recognizing it: alignment would grow fresh slivers
        // outside the same physical focus tiles and redispatch them forever.
        if (!rect_is_empty(raw_pending.rect) &&
            rect_covers(physical_focus, presenter_rect(raw_pending.rect))) {
          continue;
        }
        PendingUpdate pending = raw_pending;
        pending.rect =
            rect_align_out(pending.rect, static_cast<int32_t>(config_.align_px),
                           config_.width, config_.height);
        if (!conflicts_pen_focus_tile(pending.rect)) {
          continue;
        }
        const PlutoRect physical_pending = presenter_rect(pending.rect);
        const PlutoRect physical_overlap =
            rect_intersection(physical_pending, physical_focus);
        if (rect_is_empty(physical_overlap)) {
          continue;
        }
        PlutoRect physical_pieces[4]{};
        const size_t piece_count =
            subtract_rect(physical_pending, physical_focus, physical_pieces);
        if (piece_count == 0) {
          continue;
        }
        bool all_safe = true;
        for (size_t p = 0; p < piece_count; ++p) {
          scratch_rects_[p] = logical_rect(physical_pieces[p]);
          all_safe = all_safe && !conflicts_mapped_pen_tile(scratch_rects_[p]);
        }
        if (!all_safe) {
          continue;
        }
        const DispatchResult result =
            dispatch_batch(cls, scratch_rects_.data(), piece_count, now_us,
                           kPlutoPresentFlagNone, /*settle=*/false,
                           /*pixel_reset=*/false, pending.epoch);
        if (result == DispatchResult::kDeclined) {
          return false;
        }
        q.items[i] = pending;
        q.items[i].rect = logical_rect(physical_overlap);
        return result == DispatchResult::kDispatched;
      }
    }
    bool any_held = false;
    for (size_t i = 0; i < q.count; ++i) {
      const PlutoRect aligned = rect_align_out(
          q.items[i].rect, static_cast<int32_t>(config_.align_px),
          config_.width, config_.height);
      if (conflicts_mapped_pen_tile(aligned)) {
        any_held = true;
        stat_pen_focus_tile_holds_ +=
            conflicts_pen_focus_tile(aligned) ? 1u : 0u;
      }
    }
    if (any_held) {
      const size_t cap =
          std::max<size_t>(1, config_.max_rects[class_index(cls)]);
      std::array<size_t, k_max_pending_per_class> selected{};
      size_t selected_count = 0;
      uint64_t epoch = 0;
      for (size_t i = 0; i < q.count && selected_count < cap; ++i) {
        const PlutoRect aligned = rect_align_out(
            q.items[i].rect, static_cast<int32_t>(config_.align_px),
            config_.width, config_.height);
        if (rect_is_empty(aligned) || conflicts_mapped_pen_tile(aligned)) {
          continue;
        }
        selected[selected_count] = i;
        scratch_rects_[selected_count] = aligned;
        epoch = std::max(epoch, q.items[i].epoch);
        ++selected_count;
      }
      if (selected_count == 0) {
        return false;
      }
      const DispatchResult result =
          dispatch_batch(cls, scratch_rects_.data(), selected_count, now_us,
                         kPlutoPresentFlagNone, /*settle=*/false,
                         /*pixel_reset=*/false, epoch);
      if (result == DispatchResult::kDeclined) {
        return false;
      }
      size_t write = 0;
      size_t cursor = 0;
      for (size_t read = 0; read < q.count; ++read) {
        if (cursor < selected_count && read == selected[cursor]) {
          ++cursor;
          continue;
        }
        q.items[write++] = q.items[read];
      }
      q.count = write;
      return result == DispatchResult::kDispatched;
    }
  }
  uint64_t epoch = 0;
  const size_t count = coalesce_queue(cls, &epoch);
  if (count == 0) {
    return false;
  }
  const DispatchResult result = dispatch_batch(
      cls, scratch_rects_.data(), count, now_us, kPlutoPresentFlagNone,
      /*settle=*/false,
      /*pixel_reset=*/false, epoch);
  if (result == DispatchResult::kDeclined) {
    // Requeue exactly once, unconditionally: a declined batch is owned by
    // the caller; a parked batch lives in parked_; an absorbed batch is
    // already covered by in-flight content.
    for (size_t i = 0; i < count; ++i) {
      push_pending(cls, scratch_rects_[i], now_us, epoch);
    }
  }
  return result == DispatchResult::kDispatched;
}

// SETTLE class under a CBS budget: while interactive work is
// arriving, settles may take at most cbs_settle_budget_pct of the dispatch
// slots; when the panel is otherwise idle they run freely. One settle rect
// per tick paces the flashes.
bool RegionScheduler::try_dispatch_settle(uint64_t now_us,
                                          bool maintenance_allowed,
                                          bool intrusive_maintenance_allowed) {
  if (!maintenance_allowed || settle_count_ == 0 || full_inflight()) {
    return false;
  }
  if (user_work_pending()) {
    const uint64_t pct = config_.cbs_settle_budget_pct;
    if ((cbs_settle_slots_ + 1) * 100 > (cbs_total_slots_ + 1) * pct) {
      return false;
    }
  }
  size_t selected = settle_count_;
  for (size_t i = 0; i < settle_count_; ++i) {
    const PendingUpdate &candidate = settle_queue_[i];
    const bool safe_text =
        candidate.cls == kPlutoRefreshText &&
        (config_.text_settle_nonintrusive || candidate.required);
    if (!intrusive_maintenance_allowed && !safe_text) {
      continue;
    }
    if ((candidate.cls == kPlutoRefreshText ||
         candidate.cls == kPlutoRefreshFull) &&
        conflicts_mapped_pen_tile(candidate.rect)) {
      stat_pen_focus_tile_holds_ +=
          conflicts_pen_focus_tile(candidate.rect) ? 1u : 0u;
      continue;
    }
    selected = i;
    break;
  }
  if (selected == settle_count_) {
    return false;
  }
  const PendingUpdate head = settle_queue_[selected];
  const auto pop_selected = [this, selected] {
    for (size_t i = selected + 1; i < settle_count_; ++i) {
      settle_queue_[i - 1] = settle_queue_[i];
    }
    --settle_count_;
  };
  const DispatchResult result = dispatch_batch(
      head.cls, &head.rect, 1, now_us,
      head.required ? kPlutoPresentFlagRequiredSettle : kPlutoPresentFlagNone,
      /*settle=*/true,
      /*pixel_reset=*/false, head.epoch);
  switch (result) {
  case DispatchResult::kDispatched:
    pop_selected();
    return true;
  case DispatchResult::kAbsorbed:
  case DispatchResult::kParked:
    pop_selected(); // absorbed: covered; parked: owned by parked_ now
    return false;
  case DispatchResult::kDeclined:
    return false; // stays at head; retried next tick
  }
  return false;
}

uint64_t RegionScheduler::queue_earliest_deadline(PlutoRefreshClass cls) const {
  const PendingQueue &q = queues_[class_index(cls)];
  uint64_t best = UINT64_MAX;
  for (size_t i = 0; i < q.count; ++i) {
    const uint64_t deadline =
        q.items[i].enqueue_us + config_.class_deadline_us[class_index(cls)];
    best = std::min(best, deadline);
  }
  return best;
}

void RegionScheduler::tick(uint64_t now_us, bool maintenance_allowed,
                           bool intrusive_maintenance_allowed) {
  if (!valid_) {
    return;
  }
  expire_pen_focus(now_us);
  complete_due(now_us);
  if (pixel_reset_inflight()) {
    return;
  }
  // Pen APP DAMAGE first. A declined preview retains ownership and blocks
  // every lower lane. Drain exact 64-rect chunks in this same tick so multiple
  // app-owned hover/stroke routes never become a gap-filled bounding box or
  // wait an artificial scheduler period.
  while (pen_preview_count_ != 0 && !pixel_reset_inflight()) {
    const size_t before = pen_preview_count_;
    (void)try_dispatch_pen_preview(now_us);
    if (pen_preview_count_ == before) {
      return;
    }
  }
  // Once previews are accepted, dispatch as much bounded Text/regional-Full
  // truth as exact in-flight geometry permits. Remaining truth still blocks
  // generic EDF and maintenance from jumping the fidelity lane.
  while (pen_truth_count_ != 0 && !pixel_reset_inflight()) {
    const size_t before = pen_truth_count_;
    (void)try_dispatch_pen_truth(now_us);
    if (pen_truth_count_ == before) {
      break;
    }
  }
  // A presenter-ready truth candidate still owns strict priority. If every
  // remaining item is held only by an active physical pen tile or an
  // in-flight dependency, continue with exact disjoint residual/user work;
  // globally freezing the renderer for a stationary hover adds no safety.
  if (pen_truth_count_ != 0 && pen_truth_has_unblocked_candidate()) {
    return;
  }

  // Generic-only pieces cut around truth run next, still with their original
  // class/age/epoch but without ever visiting a bbox/coalescing queue. Drain
  // every currently eligible exact batch before ordinary EDF work.
  while (pen_residual_count_ != 0 && !full_inflight()) {
    const size_t before = pen_residual_count_;
    (void)try_dispatch_pen_residual(now_us);
    if (pen_residual_count_ == before) {
      break;
    }
  }

  // User classes, EDF by (enqueue + class deadline); each class attempted at
  // most once per tick.
  std::array<bool, k_refresh_class_count> attempted = {};
  while (!full_inflight()) {
    int best = -1;
    uint64_t best_deadline = UINT64_MAX;
    for (size_t c = 0; c < k_refresh_class_count; ++c) {
      if (attempted[c] || queues_[c].count == 0) {
        continue;
      }
      const uint64_t deadline =
          queue_earliest_deadline(static_cast<PlutoRefreshClass>(c));
      if (deadline < best_deadline) {
        best_deadline = deadline;
        best = static_cast<int>(c);
      }
    }
    if (best < 0) {
      break;
    }
    attempted[static_cast<size_t>(best)] = true;
    (void)try_dispatch_class(static_cast<PlutoRefreshClass>(best), now_us);
  }

  if (!full_inflight()) {
    (void)try_dispatch_settle(now_us, maintenance_allowed,
                              intrusive_maintenance_allowed);
  }
}

bool RegionScheduler::user_work_pending() const {
  if (pen_preview_count_ != 0 || pen_truth_count_ != 0 ||
      pen_residual_count_ != 0) {
    return true;
  }
  for (const PendingQueue &q : queues_) {
    if (q.count != 0) {
      return true;
    }
  }
  return false;
}

bool RegionScheduler::settle_work_pending() const {
  if (settle_count_ != 0) {
    return true;
  }
  for (size_t i = 0; i < inflight_count_; ++i) {
    if (inflight_[i].settle) {
      return true;
    }
  }
  for (size_t i = 0; i < parked_count_; ++i) {
    if (parked_[i].settle) {
      return true;
    }
  }
  return false;
}

bool RegionScheduler::idle() const {
  return !user_work_pending() && settle_count_ == 0 && inflight_count_ == 0 &&
         parked_count_ == 0;
}

bool RegionScheduler::export_state(RegionSchedulerState *out) const {
  if (!valid_ || out == nullptr || !idle() || !rect_is_empty(pen_focus_rect_) ||
      pen_focus_expires_us_ != 0) {
    return false;
  }
  RegionSchedulerState state;
  state.config = persistent_config(config_);
  state.has_debt_grid = !last_submit_us_.empty();
  if (state.has_debt_grid) {
    state.debt_grid = ghost_->grid();
  }
  state.next_frame_id = next_frame_id_;
  state.damage_epoch = damage_epoch_;
  state.cbs_total_slots = cbs_total_slots_;
  state.cbs_settle_slots = cbs_settle_slots_;
  state.last_submit_us = last_submit_us_;
  *out = std::move(state);
  return true;
}

bool RegionScheduler::import_state(const RegionSchedulerState &state) {
  const bool has_debt_grid = !last_submit_us_.empty();
  constexpr uint64_t kMaxCbsSlots =
      (static_cast<uint64_t>(std::numeric_limits<size_t>::max()) - 1u) / 100u;
  if (!valid_ || !idle() || !rect_is_empty(pen_focus_rect_) ||
      pen_focus_expires_us_ != 0 ||
      !same_config(state.config, persistent_config(config_)) ||
      state.has_debt_grid != has_debt_grid ||
      state.cbs_total_slots > kMaxCbsSlots ||
      state.cbs_settle_slots > state.cbs_total_slots ||
      state.last_submit_us.size() != last_submit_us_.size()) {
    return false;
  }
  if (has_debt_grid) {
    if (ghost_ == nullptr || !ghost_->valid() ||
        !same_grid(state.debt_grid, ghost_->grid())) {
      return false;
    }
  } else if (!state.last_submit_us.empty() ||
             !same_grid(state.debt_grid, TileGrid{})) {
    return false;
  }

  next_frame_id_ = state.next_frame_id;
  damage_epoch_ = state.damage_epoch;
  cbs_total_slots_ = static_cast<size_t>(state.cbs_total_slots);
  cbs_settle_slots_ = static_cast<size_t>(state.cbs_settle_slots);
  std::copy(state.last_submit_us.begin(), state.last_submit_us.end(),
            last_submit_us_.begin());
  return true;
}

} // namespace pluto
