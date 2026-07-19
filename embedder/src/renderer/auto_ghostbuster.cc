#include "renderer/auto_ghostbuster.h"

#include <algorithm>
#include <limits>
#include <utility>

#include "renderer/rect_utils.h"
#include "renderer/refresh_class.h"

namespace pluto {
namespace {

uint64_t saturating_add(uint64_t lhs, uint64_t rhs) {
  const uint64_t limit = std::numeric_limits<uint64_t>::max();
  return rhs > limit - lhs ? limit : lhs + rhs;
}

bool elapsed_at_least(uint64_t now_us, uint64_t since_us,
                      uint64_t interval_us) {
  return now_us >= since_us && now_us - since_us >= interval_us;
}

bool same_grid(const TileGrid &a, const TileGrid &b) {
  return a.width == b.width && a.height == b.height && a.tile_px == b.tile_px &&
         a.cols == b.cols && a.rows == b.rows;
}

bool same_config(const AutoGhostbusterConfig &a,
                 const AutoGhostbusterConfig &b) {
  return a.ghost_tile_threshold_q8 == b.ghost_tile_threshold_q8 &&
         a.yellow_tile_threshold_q8 == b.yellow_tile_threshold_q8 &&
         a.ghost_display_percent == b.ghost_display_percent &&
         a.yellow_display_percent == b.yellow_display_percent &&
         a.ghost_low_water_percent == b.ghost_low_water_percent &&
         a.yellow_low_water_percent == b.yellow_low_water_percent &&
         a.damage_quiescence_us == b.damage_quiescence_us &&
         a.input_release_grace_us == b.input_release_grace_us &&
         a.cooldown_us == b.cooldown_us &&
         a.scan_cadence_us == b.scan_cadence_us &&
         a.failure_retry_initial_us == b.failure_retry_initial_us &&
         a.failure_retry_max_us == b.failure_retry_max_us &&
         a.pigment_hygiene_supported == b.pigment_hygiene_supported;
}

bool valid_plane_state(const AutoGhostbusterPlaneState &plane,
                       const TileGrid &grid) {
  const size_t count = grid.tile_count();
  if (plane.debt.size() != count || plane.remainder.size() != count ||
      plane.qualified.size() != count) {
    return false;
  }
  uint64_t qualified_pixels = 0;
  for (size_t i = 0; i < count; ++i) {
    if (plane.qualified[i] > 1u) {
      return false;
    }
    const uint32_t tx = static_cast<uint32_t>(i % grid.cols);
    const uint32_t ty = static_cast<uint32_t>(i / grid.cols);
    const PlutoRect tile = grid.tile_rect(tx, ty);
    const uint64_t tile_area =
        static_cast<uint64_t>(tile.width) * static_cast<uint64_t>(tile.height);
    if (tile_area == 0 || plane.remainder[i] >= tile_area ||
        (plane.debt[i] == std::numeric_limits<uint16_t>::max() &&
         plane.remainder[i] != 0)) {
      return false;
    }
    if (plane.qualified[i] != 0) {
      qualified_pixels += tile_area;
    }
  }
  return qualified_pixels == plane.qualified_pixels;
}

} // namespace

bool AutoGhostbuster::configure(const TileGrid &grid,
                                const AutoGhostbusterConfig &config) {
  valid_ = false;
  if (grid.width <= 0 || grid.height <= 0 || grid.tile_px == 0 ||
      grid.cols == 0 || grid.rows == 0 || grid.tile_count() == 0 ||
      config.ghost_tile_threshold_q8 == 0 ||
      config.yellow_tile_threshold_q8 == 0 ||
      config.ghost_display_percent == 0 || config.ghost_display_percent > 100 ||
      config.yellow_display_percent == 0 ||
      config.yellow_display_percent > 100 ||
      config.ghost_low_water_percent >= config.ghost_display_percent ||
      config.yellow_low_water_percent >= config.yellow_display_percent ||
      config.scan_cadence_us == 0 || config.failure_retry_initial_us == 0 ||
      config.failure_retry_max_us < config.failure_retry_initial_us) {
    return false;
  }

  const uint64_t expected_cols =
      (static_cast<uint64_t>(grid.width) + grid.tile_px - 1u) / grid.tile_px;
  const uint64_t expected_rows =
      (static_cast<uint64_t>(grid.height) + grid.tile_px - 1u) / grid.tile_px;
  if (grid.cols != expected_cols || grid.rows != expected_rows) {
    return false;
  }

  // Keep the coverage*weight + carried-remainder arithmetic below within
  // uint64_t even for a caller-constructed TileGrid. Real renderer tiles are
  // 32x32, many orders of magnitude below this guard.
  const uint64_t max_tile_w =
      std::min<uint64_t>(grid.tile_px, static_cast<uint64_t>(grid.width));
  const uint64_t max_tile_h =
      std::min<uint64_t>(grid.tile_px, static_cast<uint64_t>(grid.height));
  const uint64_t max_tile_area = max_tile_w * max_tile_h;
  if (max_tile_area == 0 ||
      max_tile_area > std::numeric_limits<uint64_t>::max() /
                          std::numeric_limits<uint16_t>::max()) {
    return false;
  }

  grid_ = grid;
  config_ = config;
  display_pixels_ =
      static_cast<uint64_t>(grid.width) * static_cast<uint64_t>(grid.height);

  const size_t count = grid_.tile_count();
  const auto configure_plane = [count](LedgerPlane *plane) {
    plane->debt.assign(count, 0);
    plane->remainder.assign(count, 0);
    plane->qualified.assign(count, 0);
    plane->qualified_pixels = 0;
    plane->latched = false;
  };
  configure_plane(&ghost_);
  configure_plane(&yellow_);
  configure_plane(&active_ghost_);
  configure_plane(&active_yellow_);

  touch_active_ = false;
  pen_active_ = false;
  have_input_event_ = false;
  have_input_release_ = false;
  last_input_release_us_ = 0;
  last_input_event_us_ = 0;
  have_damage_ = false;
  last_damage_us_ = 0;
  next_scan_us_ = 0;
  cooldown_until_us_ = 0;
  retry_not_before_us_ = 0;
  consecutive_failures_ = 0;
  active_decision_ = AutoGhostbusterDecision::kNone;
  valid_ = true;
  return true;
}

bool AutoGhostbuster::coverage_reached(uint64_t qualified_pixels,
                                       uint64_t display_pixels,
                                       uint8_t percent) {
  // ceil(display_pixels * percent / 100), arranged to avoid overflowing the
  // multiplication for even a maximal int32_t-sized synthetic surface.
  const uint64_t whole = (display_pixels / 100u) * percent;
  const uint64_t remainder = display_pixels % 100u;
  const uint64_t fractional = (remainder * percent + 99u) / 100u;
  return qualified_pixels >= whole + fractional;
}

bool AutoGhostbuster::coverage_at_or_below(uint64_t qualified_pixels,
                                           uint64_t display_pixels,
                                           uint8_t percent) {
  // floor(display_pixels * percent / 100), likewise overflow-free. A
  // non-integral pixel boundary is not "at" the percentage until coverage
  // has fallen to the lower whole pixel.
  const uint64_t whole = (display_pixels / 100u) * percent;
  const uint64_t remainder = display_pixels % 100u;
  const uint64_t fractional = (remainder * percent) / 100u;
  return qualified_pixels <= whole + fractional;
}

void AutoGhostbuster::reset_plane(LedgerPlane *plane) {
  std::fill(plane->debt.begin(), plane->debt.end(), 0);
  std::fill(plane->remainder.begin(), plane->remainder.end(), 0);
  std::fill(plane->qualified.begin(), plane->qualified.end(), 0);
  plane->qualified_pixels = 0;
  plane->latched = false;
}

void AutoGhostbuster::accrue_rect(LedgerPlane *plane, const PlutoRect &rect,
                                  uint16_t threshold_q8,
                                  uint8_t display_percent, uint16_t weight_q8) {
  const PlutoRect clipped = rect_clip(rect, grid_.width, grid_.height);
  if (rect_is_empty(clipped)) {
    return;
  }

  grid_.for_each_tile(clipped, [&](uint32_t tx, uint32_t ty) {
    const PlutoRect tile = grid_.tile_rect(tx, ty);
    const uint64_t tile_area = static_cast<uint64_t>(rect_area(tile));
    const uint64_t covered =
        static_cast<uint64_t>(rect_intersection_area(clipped, tile));
    if (tile_area == 0 || covered == 0) {
      return;
    }

    const size_t index = grid_.index(tx, ty);
    uint16_t &debt = plane->debt[index];
    const bool was_qualified = plane->qualified[index] != 0;
    if (debt != std::numeric_limits<uint16_t>::max()) {
      const uint64_t numerator =
          static_cast<uint64_t>(weight_q8) * covered + plane->remainder[index];
      const uint64_t add = numerator / tile_area;
      const uint64_t next = static_cast<uint64_t>(debt) + add;
      if (next >= std::numeric_limits<uint16_t>::max()) {
        debt = std::numeric_limits<uint16_t>::max();
        plane->remainder[index] = 0;
      } else {
        debt = static_cast<uint16_t>(next);
        plane->remainder[index] = numerator % tile_area;
      }
    }

    if (!was_qualified && debt >= threshold_q8) {
      plane->qualified[index] = 1;
      plane->qualified_pixels += tile_area;
    }
  });

  if (!plane->latched && coverage_reached(plane->qualified_pixels,
                                          display_pixels_, display_percent)) {
    plane->latched = true;
  }
}

void AutoGhostbuster::clear_rect(LedgerPlane *plane, const PlutoRect &rect,
                                 uint16_t threshold_q8,
                                 uint8_t low_water_percent,
                                 bool allow_latch_cancel) {
  const PlutoRect clipped = rect_clip(rect, grid_.width, grid_.height);
  if (rect_is_empty(clipped)) {
    return;
  }
  grid_.for_each_tile(clipped, [&](uint32_t tx, uint32_t ty) {
    const size_t index = grid_.index(tx, ty);
    const PlutoRect tile = grid_.tile_rect(tx, ty);
    const uint64_t tile_area = static_cast<uint64_t>(rect_area(tile));
    const uint64_t covered =
        static_cast<uint64_t>(rect_intersection_area(clipped, tile));
    if (tile_area == 0 || covered == 0) {
      return;
    }
    const bool was_qualified = plane->qualified[index] != 0;
    if (covered >= tile_area) {
      plane->debt[index] = 0;
      plane->remainder[index] = 0;
    } else {
      // A quality edge repays only its share of this coarse tile estimate.
      // Keep the result in the same Q8+remainder representation. Dropping
      // the prior sub-Q8 carry is conservative by less than one Q8 unit and
      // avoids overflow for caller-constructed large synthetic grids.
      const uint64_t uncovered = tile_area - covered;
      const uint64_t remaining_numerator =
          static_cast<uint64_t>(plane->debt[index]) * uncovered;
      plane->debt[index] =
          static_cast<uint16_t>(remaining_numerator / tile_area);
      plane->remainder[index] = remaining_numerator % tile_area;
    }
    const uint16_t tile_low_water_q8 = threshold_q8 / 2u;
    if (was_qualified && plane->debt[index] <= tile_low_water_q8) {
      plane->qualified[index] = 0;
      plane->qualified_pixels = tile_area > plane->qualified_pixels
                                    ? 0
                                    : plane->qualified_pixels - tile_area;
    }
  });
  if (allow_latch_cancel && plane->latched &&
      coverage_at_or_below(plane->qualified_pixels, display_pixels_,
                           low_water_percent)) {
    plane->latched = false;
  }
}

void AutoGhostbuster::apply_present(LedgerPlane *ghost, LedgerPlane *yellow,
                                    const PlutoRect *rects, size_t count,
                                    PlutoRefreshClass refresh_class,
                                    bool allow_latch_cancel) {
  switch (refresh_class) {
  case kPlutoRefreshFast:
  case kPlutoRefreshUi: {
    const uint16_t weight =
        refresh_class == kPlutoRefreshFast ? kFastAccrualQ8 : kUiAccrualQ8;
    for (size_t i = 0; i < count; ++i) {
      accrue_rect(ghost, rects[i], config_.ghost_tile_threshold_q8,
                  config_.ghost_display_percent, weight);
      if (config_.pigment_hygiene_supported) {
        accrue_rect(yellow, rects[i], config_.yellow_tile_threshold_q8,
                    config_.yellow_display_percent, weight);
      }
    }
    return;
  }
  case kPlutoRefreshText:
    for (size_t i = 0; i < count; ++i) {
      clear_rect(ghost, rects[i], config_.ghost_tile_threshold_q8,
                 config_.ghost_low_water_percent, allow_latch_cancel);
    }
    return;
  case kPlutoRefreshFull:
    for (size_t i = 0; i < count; ++i) {
      clear_rect(ghost, rects[i], config_.ghost_tile_threshold_q8,
                 config_.ghost_low_water_percent, allow_latch_cancel);
      // A normal regional Full develops intended color but is not evidence
      // that optical pigment stress was bleached. On real Move glass those
      // partial GC16 jobs could themselves leave white areas gold/orange.
      // Only a successful Bleach/Both action repays the pigment plane.
    }
    return;
  }
}

void AutoGhostbuster::note_accepted_present(const PlutoRect *rects,
                                            size_t count,
                                            PlutoRefreshClass refresh_class,
                                            uint64_t now_us) {
  if (!valid_ || rects == nullptr || count == 0 ||
      !refresh_class_valid(refresh_class)) {
    return;
  }

  bool visible = false;
  for (size_t i = 0; i < count; ++i) {
    if (!rect_is_empty(rect_clip(rects[i], grid_.width, grid_.height))) {
      visible = true;
      break;
    }
  }
  if (!visible) {
    return;
  }

  if (!have_damage_ || now_us > last_damage_us_) {
    last_damage_us_ = now_us;
  }
  have_damage_ = true;
  const bool active = action_active();
  apply_present(&ghost_, &yellow_, rects, count, refresh_class,
                /*allow_latch_cancel=*/!active);
  if (active) {
    apply_present(&active_ghost_, &active_yellow_, rects, count, refresh_class,
                  /*allow_latch_cancel=*/true);
  }
}

void AutoGhostbuster::note_input_state(bool touch_active, bool pen_active,
                                       uint64_t now_us) {
  if (!valid_) {
    return;
  }
  const uint64_t event_us = std::max(now_us, last_input_event_us_);
  const bool was_active = touch_active_ || pen_active_;
  const bool is_active = touch_active || pen_active;
  if (touch_active_ != touch_active || pen_active_ != pen_active ||
      now_us > last_input_event_us_) {
    have_input_event_ = true;
  }
  touch_active_ = touch_active;
  pen_active_ = pen_active;
  last_input_event_us_ = event_us;
  if (was_active && !is_active) {
    have_input_release_ = true;
    last_input_release_us_ = event_us;
  }
}

AutoGhostbusterDecision AutoGhostbuster::pending_decision() const {
  const bool ghost = ghost_needed();
  const bool yellow = yellow_needed();
  if (ghost && yellow) {
    return AutoGhostbusterDecision::kBoth;
  }
  if (ghost) {
    return AutoGhostbusterDecision::kBlink;
  }
  if (yellow) {
    return AutoGhostbusterDecision::kBleach;
  }
  return AutoGhostbusterDecision::kNone;
}

AutoGhostbusterDecision
AutoGhostbuster::try_begin_action(uint64_t now_us,
                                  const AutoGhostbusterGateState &gate_state) {
  if (!valid_ || action_active() || now_us < next_scan_us_) {
    return AutoGhostbusterDecision::kNone;
  }
  next_scan_us_ = saturating_add(now_us, config_.scan_cadence_us);

  const AutoGhostbusterDecision decision = pending_decision();
  if (decision == AutoGhostbusterDecision::kNone || touch_active_ ||
      pen_active_ || !gate_state.scheduler_idle ||
      gate_state.presentation_suspended || !gate_state.maintenance_allowed ||
      now_us < cooldown_until_us_ || now_us < retry_not_before_us_ ||
      (have_damage_ && !elapsed_at_least(now_us, last_damage_us_,
                                         config_.damage_quiescence_us)) ||
      (have_input_event_ &&
       !elapsed_at_least(now_us, last_input_event_us_,
                         config_.input_release_grace_us))) {
    return AutoGhostbusterDecision::kNone;
  }

  reset_plane(&active_ghost_);
  reset_plane(&active_yellow_);
  active_decision_ = decision;
  return decision;
}

uint64_t AutoGhostbuster::failure_retry_delay_us() const {
  uint64_t delay = config_.failure_retry_initial_us;
  uint32_t doublings =
      consecutive_failures_ > 0 ? consecutive_failures_ - 1u : 0u;
  while (doublings != 0 && delay < config_.failure_retry_max_us) {
    delay = delay > config_.failure_retry_max_us / 2u
                ? config_.failure_retry_max_us
                : std::min(delay * 2u, config_.failure_retry_max_us);
    --doublings;
  }
  return delay;
}

void AutoGhostbuster::adopt_active_plane(LedgerPlane *destination,
                                         LedgerPlane *active) {
  destination->debt.swap(active->debt);
  destination->remainder.swap(active->remainder);
  destination->qualified.swap(active->qualified);
  std::swap(destination->qualified_pixels, active->qualified_pixels);
  std::swap(destination->latched, active->latched);
  // `active` now owns the old destination storage. Its scratch state is
  // deliberately reset lazily by the next try_begin_action, keeping
  // completion O(1).
}

bool AutoGhostbuster::complete_action(bool success, uint64_t now_us) {
  if (!valid_ || !action_active()) {
    return false;
  }

  const AutoGhostbusterDecision completed = active_decision_;
  if (success) {
    switch (completed) {
    case AutoGhostbusterDecision::kNone:
      break;
    case AutoGhostbusterDecision::kBlink:
      adopt_active_plane(&ghost_, &active_ghost_);
      break;
    case AutoGhostbusterDecision::kBleach:
    case AutoGhostbusterDecision::kBoth:
      adopt_active_plane(&ghost_, &active_ghost_);
      adopt_active_plane(&yellow_, &active_yellow_);
      break;
    }
    cooldown_until_us_ = saturating_add(now_us, config_.cooldown_us);
    retry_not_before_us_ = 0;
    consecutive_failures_ = 0;
  } else {
    if (consecutive_failures_ != std::numeric_limits<uint32_t>::max()) {
      ++consecutive_failures_;
    }
    retry_not_before_us_ = saturating_add(now_us, failure_retry_delay_us());
  }
  active_decision_ = AutoGhostbusterDecision::kNone;
  return true;
}

bool AutoGhostbuster::acknowledge_external_action(
    AutoGhostbusterDecision decision, uint64_t now_us) {
  if (!valid_ || action_active() ||
      decision == AutoGhostbusterDecision::kNone) {
    return false;
  }
  switch (decision) {
  case AutoGhostbusterDecision::kNone:
    return false;
  case AutoGhostbusterDecision::kBlink:
    reset_plane(&ghost_);
    break;
  case AutoGhostbusterDecision::kBleach:
  case AutoGhostbusterDecision::kBoth:
    reset_plane(&ghost_);
    reset_plane(&yellow_);
    break;
  }
  // A successful manual run proves the maintenance path healthy, but does
  // not consume or extend the automatic success cooldown.
  consecutive_failures_ = 0;
  retry_not_before_us_ = 0;
  next_scan_us_ = std::max(next_scan_us_, now_us);
  return true;
}

bool AutoGhostbuster::export_state(AutoGhostbusterState *out) const {
  if (!valid_ || action_active() || out == nullptr) {
    return false;
  }
  const auto export_plane = [](const LedgerPlane &source) {
    AutoGhostbusterPlaneState plane;
    plane.debt = source.debt;
    plane.remainder = source.remainder;
    plane.qualified = source.qualified;
    plane.qualified_pixels = source.qualified_pixels;
    plane.latched = source.latched;
    return plane;
  };

  AutoGhostbusterState state;
  state.grid = grid_;
  state.config = config_;
  state.display_pixels = display_pixels_;
  state.ghost = export_plane(ghost_);
  state.yellow = export_plane(yellow_);
  state.active_ghost = export_plane(active_ghost_);
  state.active_yellow = export_plane(active_yellow_);
  state.touch_active = touch_active_;
  state.pen_active = pen_active_;
  state.have_input_event = have_input_event_;
  state.have_input_release = have_input_release_;
  state.last_input_release_us = last_input_release_us_;
  state.last_input_event_us = last_input_event_us_;
  state.have_damage = have_damage_;
  state.last_damage_us = last_damage_us_;
  state.next_scan_us = next_scan_us_;
  state.cooldown_until_us = cooldown_until_us_;
  state.retry_not_before_us = retry_not_before_us_;
  state.consecutive_failures = consecutive_failures_;
  state.active_decision = active_decision_;
  *out = std::move(state);
  return true;
}

bool AutoGhostbuster::import_state(const AutoGhostbusterState &state) {
  if (!valid_ || action_active() ||
      state.active_decision != AutoGhostbusterDecision::kNone ||
      !same_grid(state.grid, grid_) || !same_config(state.config, config_) ||
      state.display_pixels != display_pixels_ ||
      !valid_plane_state(state.ghost, grid_) ||
      !valid_plane_state(state.yellow, grid_) ||
      !valid_plane_state(state.active_ghost, grid_) ||
      !valid_plane_state(state.active_yellow, grid_) ||
      (state.have_input_release && !state.have_input_event) ||
      (!state.have_input_event && state.last_input_event_us != 0) ||
      (!state.have_input_release && state.last_input_release_us != 0) ||
      (state.have_input_release &&
       state.last_input_release_us > state.last_input_event_us) ||
      (!state.have_damage && state.last_damage_us != 0)) {
    return false;
  }

  const auto import_plane = [](const AutoGhostbusterPlaneState &source,
                               LedgerPlane *destination) {
    std::copy(source.debt.begin(), source.debt.end(),
              destination->debt.begin());
    std::copy(source.remainder.begin(), source.remainder.end(),
              destination->remainder.begin());
    std::copy(source.qualified.begin(), source.qualified.end(),
              destination->qualified.begin());
    destination->qualified_pixels = source.qualified_pixels;
    destination->latched = source.latched;
  };
  import_plane(state.ghost, &ghost_);
  import_plane(state.yellow, &yellow_);
  import_plane(state.active_ghost, &active_ghost_);
  import_plane(state.active_yellow, &active_yellow_);
  touch_active_ = state.touch_active;
  pen_active_ = state.pen_active;
  have_input_event_ = state.have_input_event;
  have_input_release_ = state.have_input_release;
  last_input_release_us_ = state.last_input_release_us;
  last_input_event_us_ = state.last_input_event_us;
  have_damage_ = state.have_damage;
  last_damage_us_ = state.last_damage_us;
  next_scan_us_ = state.next_scan_us;
  cooldown_until_us_ = state.cooldown_until_us;
  retry_not_before_us_ = state.retry_not_before_us;
  consecutive_failures_ = state.consecutive_failures;
  active_decision_ = AutoGhostbusterDecision::kNone;
  return true;
}

} // namespace pluto
