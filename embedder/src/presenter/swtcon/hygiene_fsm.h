#ifndef PLUTO_PRESENTER_SWTCON_HYGIENE_FSM_H_
#define PLUTO_PRESENTER_SWTCON_HYGIENE_FSM_H_

#include <cstddef>
#include <cstdint>
#include <vector>

namespace pluto::swtcon {

// Per-tile A2/DU legality state:
//   GRAY_CLEAN -> RAIL_ENTER -> RAIL_ACTIVE -> RAIL_EXIT_WHITE ->
//   RAIL_EXIT_RERENDER -> GRAY_CLEAN
enum class HygieneState : std::uint8_t {
  kGrayClean = 0,        // gray content on glass; GC16-family passes legal
  kRailEnter = 1,        // DU drive-to-white enter flush in flight
  kRailActive = 2,       // rail (A2/DU) admissions free; pass budget counts
  kRailExitWhite = 3,    // A2 -> white exit flush in flight
  kRailExitRerender = 4, // GC16 re-render (final = L_cur) in flight
};

// What the caller must drive NOW for a requested admission on a tile.
enum class HygieneAction : std::uint8_t {
  // The request is legal as-is: drive it in its own mode.
  kAdmit = 0,
  // RAIL_ENTER: entering A2/DU from gray content prepends a DU
  // drive-to-white flush. Drive the flush; when its pass ends the tile is
  // RAIL_ACTIVE and the original rail request re-admits as kAdmit.
  kWhiteFlushFirst = 1,
  // RAIL_EXIT: drive A2 -> white, then (after that pass ends) a GC16
  // re-render with final = L_cur — the re-render carries the requested
  // gray content when the exit was demand-driven. Also the forced-exit
  // path at rail_pass_max.
  kExitFlushFirst = 2,
  // A transitional pass (enter flush / exit flush / re-render) is in
  // flight on this tile: the request waits for the pass boundary (the
  // engine parks it; re-admission re-consults the FSM).
  kDefer = 3,
};

struct HygieneFsmConfig {
  // `rail_pass_max` (E2 + camera GhostScore calibrate): forced exit
  // after this many completed rail passes even without a settle trigger.
  std::uint16_t rail_pass_max = 16;
};

struct HygieneFsmStats {
  std::uint64_t rail_enters = 0;
  std::uint64_t rail_exits = 0;         // exits begun (incl. forced)
  std::uint64_t forced_exits = 0;       // rail_pass_max exits
  std::uint64_t deferrals = 0;
};

// HygieneFsm: per-tile A2/DU legality. The FSM owns MODE legality only —
// collision/busy arbitration stays in the PixelEngine. Model-checked by
// exhaustive small-state enumeration.
//
// Caller contract (the presenter glue wires this to admissions):
//   - Before admitting content on a tile, call on_admit(tile, rail) with
//     rail = "the request's waveform mode is in rail_mode_mask" and drive
//     what the returned action says (see HygieneAction).
//   - After every completed drive pass on the tile (the engine's
//     on_tile_pass_end hook), call on_pass_end(tile).
//   - The scheduler's settle authority may force an exit without a new
//     admission via begin_exit(tile) when exit_required(tile).
//
// Thread ownership: engine-thread confined; no locking; per-tile
// state pre-allocated at configure().
class HygieneFsm final {
 public:
  HygieneFsm() = default;
  HygieneFsm(const HygieneFsm&) = delete;
  HygieneFsm& operator=(const HygieneFsm&) = delete;

  bool configure(std::size_t tile_count, const HygieneFsmConfig& config);
  bool configured() const { return configured_; }
  const HygieneFsmConfig& config() const { return config_; }
  std::size_t tile_count() const { return tiles_.size(); }

  // Admission legality for one tile. `rail_request` = the requested mode
  // is A2/DU-family. May transition the tile (see HygieneAction).
  HygieneAction on_admit(std::size_t tile, bool rail_request);

  // A drive pass on the tile completed (waveform boundary, all pixels
  // idle). Advances transitional states; counts rail passes in
  // RAIL_ACTIVE. A pass_end in GRAY_CLEAN is a legal no-op (gray passes
  // don't change hygiene state).
  void on_pass_end(std::size_t tile);

  // True when the tile's rail budget is exhausted (RAIL_ACTIVE with
  // rail_passes >= rail_pass_max): the caller must schedule the exit
  // sequence even without a new admission (forced exit).
  bool exit_required(std::size_t tile) const;

  // Scheduler-initiated exit (forced exit / settle): legal only in
  // RAIL_ACTIVE. Transitions to RAIL_EXIT_WHITE; the caller drives the
  // white flush, then the GC16 re-render, with on_pass_end after each.
  bool begin_exit(std::size_t tile);

  HygieneState state(std::size_t tile) const { return tiles_[tile].state; }
  std::uint16_t rail_passes(std::size_t tile) const {
    return tiles_[tile].rail_passes;
  }
  const HygieneFsmStats& stats() const { return stats_; }

 private:
  struct TileHygiene {
    HygieneState state = HygieneState::kGrayClean;
    std::uint16_t rail_passes = 0;
  };

  void enter_exit_white(TileHygiene& tile, bool forced);

  bool configured_ = false;
  HygieneFsmConfig config_{};
  std::vector<TileHygiene> tiles_;
  HygieneFsmStats stats_{};
};

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_HYGIENE_FSM_H_
