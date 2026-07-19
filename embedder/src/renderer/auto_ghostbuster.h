#ifndef PLUTO_RENDERER_AUTO_GHOSTBUSTER_H_
#define PLUTO_RENDERER_AUTO_GHOSTBUSTER_H_

#include <cstddef>
#include <cstdint>
#include <vector>

#include "pluto/presenter.h"
#include "renderer/ledgers.h"

namespace pluto {

// Automatic full-screen optical-maintenance action. The numeric values also
// pin the distinct internal rail plans: one Blink cycle, two Bleach cycles,
// or their three-cycle composition. `kBoth` lets the caller pause the app once
// when both kinds of debt are due.
enum class AutoGhostbusterDecision : uint8_t {
  kNone = 0,
  kBlink = 1,
  kBleach = 2,
  kBoth = 3,
};

struct AutoGhostbusterConfig {
  // Per-tile, non-decaying Q8 debt thresholds. Fast adds 3.0 and Ui adds
  // 2.0 for a complete tile; partial damage is charged by covered pixels.
  uint16_t ghost_tile_threshold_q8 = 6144;
  uint16_t yellow_tile_threshold_q8 = 12288;

  // A reason latches once threshold-reaching tiles cover this percentage of
  // the display's real pixel area. Edge tiles count only their clipped area.
  uint8_t ghost_display_percent = 55;
  uint8_t yellow_display_percent = 35;
  // Accepted quality work may cancel a pending reason only after qualified
  // coverage falls to/below this low-water mark. This hysteresis survives
  // minor settling during input deferral.
  uint8_t ghost_low_water_percent = 35;
  uint8_t yellow_low_water_percent = 20;

  uint64_t damage_quiescence_us = 300'000;
  uint64_t input_release_grace_us = 500'000;
  uint64_t cooldown_us = 600'000'000;
  uint64_t scan_cadence_us = 100'000;
  uint64_t failure_retry_initial_us = 5'000'000;
  uint64_t failure_retry_max_us = 120'000'000;

  // False on panels/backends for which BleachNow pigment hygiene is not a
  // supported operation. No content/chroma heuristic substitutes for it.
  bool pigment_hygiene_supported = false;
};

// Cheap supervisor state sampled when the policy is polled. Input is tracked
// separately so a release transition can arm the grace period exactly once.
struct AutoGhostbusterGateState {
  bool scheduler_idle = false;
  bool presentation_suspended = false;
  // False during Home, app switching, hibernate, or any other supervisor
  // state where an otherwise-idle panel must not be seized for maintenance.
  bool maintenance_allowed = true;
};

struct AutoGhostbusterPlaneState {
  std::vector<uint16_t> debt;
  std::vector<uint64_t> remainder;
  std::vector<uint8_t> qualified;
  uint64_t qualified_pixels = 0;
  bool latched = false;
};

struct AutoGhostbusterState {
  TileGrid grid{};
  AutoGhostbusterConfig config{};
  uint64_t display_pixels = 0;
  AutoGhostbusterPlaneState ghost;
  AutoGhostbusterPlaneState yellow;
  AutoGhostbusterPlaneState active_ghost;
  AutoGhostbusterPlaneState active_yellow;
  bool touch_active = false;
  bool pen_active = false;
  bool have_input_event = false;
  bool have_input_release = false;
  uint64_t last_input_release_us = 0;
  uint64_t last_input_event_us = 0;
  bool have_damage = false;
  uint64_t last_damage_us = 0;
  uint64_t next_scan_us = 0;
  uint64_t cooldown_until_us = 0;
  uint64_t retry_not_before_us = 0;
  uint32_t consecutive_failures = 0;
  AutoGhostbusterDecision active_decision = AutoGhostbusterDecision::kNone;
};

// Native, scheduler-thread-confined policy for opportunistic ghost hygiene.
//
// The hot path is proportional only to tiles touched by an accepted present;
// eligibility uses incrementally-maintained pixel totals, not a whole-grid
// scan. There is no decay, wall clock forgiveness, content-color signal, or
// allocation after configure(). Screen-level reasons latch at the instant the
// configured coverage is reached. Input alone cannot forgive it; accepted
// quality work must cross the configured low-water boundary.
//
// `note_accepted_present` must be called only after the presenter accepts an
// ordinary content/settle request. The request's damage rectangles are the
// ABI-guaranteed disjoint rectangles. Do not feed the Blink/Bleach rail and
// retained-content stages back into this method: those stages are the
// repayment operation itself, not fresh app damage.
class AutoGhostbuster final {
public:
  static constexpr uint16_t kFastAccrualQ8 = 3 * 256;
  static constexpr uint16_t kUiAccrualQ8 = 2 * 256;

  static constexpr uint32_t rail_cycles_for(AutoGhostbusterDecision decision) {
    return static_cast<uint32_t>(decision);
  }

  bool configure(const TileGrid &grid,
                 const AutoGhostbusterConfig &config = {});
  bool valid() const { return valid_; }

  void note_accepted_present(const PlutoRect *rects, size_t count,
                             PlutoRefreshClass refresh_class, uint64_t now_us);
  void note_accepted_present(const PlutoRect &rect,
                             PlutoRefreshClass refresh_class, uint64_t now_us) {
    note_accepted_present(&rect, 1, refresh_class, now_us);
  }

  // `now_us` shares the renderer/scheduler monotonic timebase. A grace period
  // is armed only on the combined active -> inactive edge; repeatedly
  // reporting an idle input state does not create maintenance work or extend
  // the grace period.
  void note_input_state(bool touch_active, bool pen_active, uint64_t now_us);

  // Polls at most once per scan cadence. On success this atomically begins
  // the returned action and snapshots a fresh pair of active-run ledgers.
  // Calls while an action is active return kNone.
  AutoGhostbusterDecision
  try_begin_action(uint64_t now_us, const AutoGhostbusterGateState &gate_state);

  // Ends the active action. A successful Blink repays ghost debt only;
  // successful Bleach and Both repay ghost and yellow debt. Fresh debt that
  // arrived after try_begin_action is retained, including a reason that was
  // reached and then normally settled while the action was in flight.
  // Failed actions acknowledge nothing and do not arm the cooldown.
  bool complete_action(bool success, uint64_t now_us);

  // A successful manual maintenance run can repay pending automatic debt
  // without consuming the automatic cooldown allowance. Rejected while an
  // automatic action is active, whose active-run scratch ledgers must instead
  // be reconciled by complete_action().
  bool acknowledge_external_action(AutoGhostbusterDecision decision,
                                   uint64_t now_us);

  bool action_active() const {
    return active_decision_ != AutoGhostbusterDecision::kNone;
  }
  AutoGhostbusterDecision active_decision() const { return active_decision_; }

  bool ghost_needed() const { return ghost_.latched; }
  bool yellow_needed() const {
    return config_.pigment_hygiene_supported && yellow_.latched;
  }
  uint16_t ghost_debt(uint32_t tx, uint32_t ty) const {
    return ghost_.debt[grid_.index(tx, ty)];
  }
  uint16_t yellow_debt(uint32_t tx, uint32_t ty) const {
    return yellow_.debt[grid_.index(tx, ty)];
  }
  uint64_t ghost_qualified_pixels() const { return ghost_.qualified_pixels; }
  uint64_t yellow_qualified_pixels() const { return yellow_.qualified_pixels; }
  uint64_t display_pixels() const { return display_pixels_; }
  uint64_t cooldown_until_us() const { return cooldown_until_us_; }
  uint64_t retry_not_before_us() const { return retry_not_before_us_; }
  uint32_t consecutive_failures() const { return consecutive_failures_; }
  uint64_t next_scan_us() const { return next_scan_us_; }
  const TileGrid &grid() const { return grid_; }

  // An optical action owns reconciliation scratch that cannot be handed off.
  // Both operations therefore fail while either side has an action active.
  bool export_state(AutoGhostbusterState *out) const;
  bool import_state(const AutoGhostbusterState &state);

private:
  struct LedgerPlane {
    std::vector<uint16_t> debt;
    // Fractional Q8 numerator carried per tile. This prevents repeated tiny
    // accepted regions from being rounded down to zero forever.
    std::vector<uint64_t> remainder;
    // Per-tile high/low hysteresis. A tile qualifies at threshold and stays
    // qualified until proportional quality repayment reaches half-threshold,
    // so a one-pixel Text edge cannot forgive an otherwise dirty tile.
    std::vector<uint8_t> qualified;
    uint64_t qualified_pixels = 0;
    bool latched = false;
  };

  static bool coverage_reached(uint64_t qualified_pixels,
                               uint64_t display_pixels, uint8_t percent);
  static bool coverage_at_or_below(uint64_t qualified_pixels,
                                   uint64_t display_pixels, uint8_t percent);
  void reset_plane(LedgerPlane *plane);
  void accrue_rect(LedgerPlane *plane, const PlutoRect &rect,
                   uint16_t threshold_q8, uint8_t display_percent,
                   uint16_t weight_q8);
  void clear_rect(LedgerPlane *plane, const PlutoRect &rect,
                  uint16_t threshold_q8, uint8_t low_water_percent,
                  bool allow_latch_cancel);
  void apply_present(LedgerPlane *ghost, LedgerPlane *yellow,
                     const PlutoRect *rects, size_t count,
                     PlutoRefreshClass refresh_class, bool allow_latch_cancel);
  void adopt_active_plane(LedgerPlane *destination, LedgerPlane *active);
  AutoGhostbusterDecision pending_decision() const;
  uint64_t failure_retry_delay_us() const;

  bool valid_ = false;
  TileGrid grid_{};
  AutoGhostbusterConfig config_{};
  uint64_t display_pixels_ = 0;

  LedgerPlane ghost_{};
  LedgerPlane yellow_{};
  // Contributions accepted after the current action began. On success these
  // replace whichever main ledgers that optical action repays; on failure the
  // main ledgers already contain the same contributions and remain untouched.
  LedgerPlane active_ghost_{};
  LedgerPlane active_yellow_{};

  bool touch_active_ = false;
  bool pen_active_ = false;
  // True after either a sampled state edge or a newer raw input-edge
  // timestamp. The latter preserves release grace for a short tap that went
  // down and up entirely between two 100 ms policy polls.
  bool have_input_event_ = false;
  bool have_input_release_ = false;
  uint64_t last_input_release_us_ = 0;
  uint64_t last_input_event_us_ = 0;

  bool have_damage_ = false;
  uint64_t last_damage_us_ = 0;
  uint64_t next_scan_us_ = 0;
  uint64_t cooldown_until_us_ = 0;
  uint64_t retry_not_before_us_ = 0;
  uint32_t consecutive_failures_ = 0;
  AutoGhostbusterDecision active_decision_ = AutoGhostbusterDecision::kNone;
};

} // namespace pluto

#endif // PLUTO_RENDERER_AUTO_GHOSTBUSTER_H_
