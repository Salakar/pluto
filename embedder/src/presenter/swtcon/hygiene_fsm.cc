#include "presenter/swtcon/hygiene_fsm.h"

#include <cassert>

namespace pluto::swtcon {

bool HygieneFsm::configure(std::size_t tile_count,
                           const HygieneFsmConfig& config) {
  if (tile_count == 0) {
    return false;
  }
  config_ = config;
  tiles_.assign(tile_count, TileHygiene{});
  stats_ = HygieneFsmStats{};
  configured_ = true;
  return true;
}

HygieneAction HygieneFsm::on_admit(std::size_t tile, bool rail_request) {
  assert(configured_ && tile < tiles_.size());
  TileHygiene& state = tiles_[tile];
  switch (state.state) {
    case HygieneState::kGrayClean:
      if (!rail_request) {
        return HygieneAction::kAdmit;  // gray on gray: always legal
      }
      // RAIL_ENTER: rail content over gray must be preceded by a DU
      // drive-to-white flush — never deposit A2 codes on arbitrary grays.
      state.state = HygieneState::kRailEnter;
      ++stats_.rail_enters;
      return HygieneAction::kWhiteFlushFirst;

    case HygieneState::kRailActive:
      if (rail_request) {
        if (state.rail_passes >= config_.rail_pass_max) {
          // Forced exit: the rail budget is spent; the tile must pass
          // through white + GC16 re-render before more rail content.
          enter_exit_white(state, /*forced=*/true);
          return HygieneAction::kExitFlushFirst;
        }
        return HygieneAction::kAdmit;  // rail admissions free
      }
      // Gray content on a railed tile: RAIL_EXIT (white, then GC16
      // re-render carrying the requested content).
      enter_exit_white(state, /*forced=*/false);
      return HygieneAction::kExitFlushFirst;

    case HygieneState::kRailExitRerender:
      if (!rail_request) {
        return HygieneAction::kAdmit;  // the GC16 re-render itself
      }
      ++stats_.deferrals;
      return HygieneAction::kDefer;  // finish the exit first

    case HygieneState::kRailEnter:
    case HygieneState::kRailExitWhite:
      // A transitional flush is in flight; everything waits for the pass
      // boundary (the engine parks the piece; re-admission re-consults).
      ++stats_.deferrals;
      return HygieneAction::kDefer;
  }
  assert(false && "unreachable hygiene state");
  return HygieneAction::kDefer;
}

void HygieneFsm::on_pass_end(std::size_t tile) {
  assert(configured_ && tile < tiles_.size());
  TileHygiene& state = tiles_[tile];
  switch (state.state) {
    case HygieneState::kGrayClean:
      break;  // gray pass completed: no hygiene change
    case HygieneState::kRailEnter:
      // Enter flush landed: the tile is white; rail budget starts fresh.
      state.state = HygieneState::kRailActive;
      state.rail_passes = 0;
      break;
    case HygieneState::kRailActive:
      // One rail content pass completed. Saturating: the budget gate in
      // on_admit()/exit_required() fires at rail_pass_max.
      if (state.rail_passes < config_.rail_pass_max) {
        ++state.rail_passes;
      }
      break;
    case HygieneState::kRailExitWhite:
      // Exit flush landed: the GC16 re-render is next (priority-bumped
      // settle in the scheduler).
      state.state = HygieneState::kRailExitRerender;
      break;
    case HygieneState::kRailExitRerender:
      // Re-render landed: gray truth restored.
      state.state = HygieneState::kGrayClean;
      state.rail_passes = 0;
      break;
  }
}

bool HygieneFsm::exit_required(std::size_t tile) const {
  assert(configured_ && tile < tiles_.size());
  const TileHygiene& state = tiles_[tile];
  return state.state == HygieneState::kRailActive &&
         state.rail_passes >= config_.rail_pass_max;
}

bool HygieneFsm::begin_exit(std::size_t tile) {
  assert(configured_ && tile < tiles_.size());
  TileHygiene& state = tiles_[tile];
  if (state.state != HygieneState::kRailActive) {
    return false;
  }
  enter_exit_white(state, exit_required(tile));
  return true;
}

void HygieneFsm::enter_exit_white(TileHygiene& tile, bool forced) {
  tile.state = HygieneState::kRailExitWhite;
  ++stats_.rail_exits;
  if (forced) {
    ++stats_.forced_exits;
  }
}

}  // namespace pluto::swtcon
