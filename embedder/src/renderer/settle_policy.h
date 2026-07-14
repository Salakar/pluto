#ifndef PLUTO_RENDERER_SETTLE_POLICY_H_
#define PLUTO_RENDERER_SETTLE_POLICY_H_

#include <cstddef>
#include <cstdint>
#include <vector>

#include "pluto/presenter.h"
#include "renderer/ledgers.h"
#include "renderer/perception.h"

namespace pluto {

class RegionScheduler;

// SettlePlanner: the SINGLE settle authority. It replaced both the old
// scheduler's idle settle and the swtcon presenter's internal idle-settle +
// full_refresh_every counter — a presenter never self-schedules quality
// passes anymore.
//
// Policy:
//   * Quiescence: a tile becomes settle-eligible only after
//     quiesce_ms without damage; re-damage re-arms the window (ARC-style
//     scan resistance — a region under continuous animation never
//     flash-thrashes; it settles once, when it rests).
//   * Eligibility: ghost debt above the perception threshold, stub stress
//     above the force line, or chroma pending (color panels).
//   * Broad backlog: when more than settle_full_area_percent of the tiles is
//     eligible at once, achromatic ghost debt coalesces into one full-screen
//     Text repayment. Full remains exact and regional for real chroma only.
//   * LSM-batch clustering: eligible tiles cluster by proximity under a
//     max-added-area bound — never the everything-into-one-union flash the
//     old chroma path amplified.
//   * Ordering: clusters are emitted by debt x saliency, highest first.
//   * Class: clusters holding chroma-pending tiles settle as Full on color
//     panels ("color is a settled state"); everything else settles as Text
//     (GC16-family quality, no color development).
//
// Emission goes through RegionScheduler::submit_settle (SETTLE class, CBS
// budgeted there); one burst is in flight at a time. Force-identity settle
// semantics are an engine-stage concern: today's settles re-present the
// ledger content through the bridge, which on the current presenters
// repaints the region at settled quality.
//
// Thread ownership: scheduler-thread confined (FrameRenderer's mutex), same
// as the ledgers it reads.
struct SettlePlannerConfig {
  int32_t width = 954;
  int32_t height = 1696;
  uint32_t tile_px = 32;
  uint32_t align_px = 8;
  bool panel_is_color = false;
  // Vendor mode-8 under-white top-off. FrameRenderer disables this on a
  // physical pigment panel even when direct SWTCON reports monochrome
  // rendering capability: real Move glass showed gold/orange residue.
  bool enable_sparkle_topoff = true;
  PerceptionConstants perception{};
};

struct SettlePlannerForcedState {
  PlutoRect rect{0, 0, 0, 0};
  uint64_t ready_us = 0;
};

struct SettlePlannerState {
  uint32_t version = 1;
  SettlePlannerConfig config{};
  std::vector<uint64_t> last_damage_us;
  std::vector<SettlePlannerForcedState> forced;
  uint64_t emitted_settles = 0;
  uint64_t emitted_full_flashes = 0;
  uint64_t emitted_sparkles = 0;
  PlutoRect sparkle_rect{0, 0, 0, 0};
  uint32_t sparkle_phase = 16;
  uint64_t sparkle_next_us = 0;
};

class SettlePlanner {
public:
  static constexpr uint32_t kStateVersion = 1;
  SettlePlanner() = default;

  bool configure(const SettlePlannerConfig &config, GhostLedger *ghost,
                 StressLedger *stress, ChromaPendingSet *chroma);
  bool valid() const { return valid_; }

  // Frame-path notification: damage re-arms the quiescence window of every
  // touched tile (ARC scan resistance).
  void note_damage(const PlutoRect &rect, uint64_t now_us);

  // Scroll fast path: a detected MOVE arms one forced quality settle for
  // the whole scroll band. Every MOVE frame RE-ARMS the band's entry —
  // union rect, quiescence window pushed forward — so the settle fires
  // ~settle_quiesce after the motion rests, never mid-scroll. The entry
  // persists until retire_forced() reports quality coverage, surviving the
  // scheduler's cancel-on-redamage exactly like strokes.
  void arm_scroll_settle(const PlutoRect &band, uint64_t now_us);
  // A quality-class (Text/Full) present put true content on glass for
  // `covered`: forced candidates it fully covers are dropped.
  void retire_forced(const PlutoRect &covered);
  size_t forced_pending() const { return forced_.size(); }

  // Decays the ledgers and, when a quiesced backlog exists and no settle
  // burst is outstanding, emits the next burst through the scheduler.
  // `maintenance_allowed` is the supervisor/lifecycle gate.
  // `intrusive_maintenance_allowed` additionally carries touch/pen and
  // release grace. Non-flashing Text repayment (especially the pen-truth
  // settle) may continue during proximity; Full and sparkle wait.
  void tick(uint64_t now_us, RegionScheduler *scheduler,
            bool maintenance_allowed = true,
            bool intrusive_maintenance_allowed = true);

  size_t emitted_settles() const { return emitted_settles_; }
  size_t emitted_full_flashes() const { return emitted_full_flashes_; }
  size_t emitted_sparkles() const { return emitted_sparkles_; }

  bool export_state(SettlePlannerState *out) const;
  bool import_state(const SettlePlannerState &state);

private:
  struct Cluster {
    PlutoRect rect{0, 0, 0, 0};
    uint64_t debt = 0;   // summed tile debt (Q8) + stress + chroma bonus
    uint32_t tiles = 1;  // member tiles (average debt = debt / tiles)
    bool chroma = false; // holds >= 1 chroma-pending tile
    uint64_t score = 0;  // debt x saliency ordering key
  };

  struct ForcedSettle {
    PlutoRect rect{0, 0, 0, 0};
    uint64_t ready_us = 0;
  };

  bool tile_eligible(uint32_t tx, uint32_t ty, uint64_t now_us) const;
  // Builds clusters from the already-collected eligible_tiles_ list (row-major
  // order). Callers must populate eligible_tiles_ first (tick's single scan).
  void build_clusters();
  // Emits ready forced scroll rects; returns how many were submitted.
  size_t emit_forced(uint64_t now_us, RegionScheduler *scheduler);

  static constexpr uint64_t kNeverDamaged = UINT64_MAX;
  static constexpr size_t kMaxForced = 256;

  bool valid_ = false;
  SettlePlannerConfig config_{};
  TileGrid grid_{};
  GhostLedger *ghost_ = nullptr;
  StressLedger *stress_ = nullptr;
  ChromaPendingSet *chroma_ = nullptr;
  // Per-tile last-damage timestamp (us, caller's monotonic clock);
  // kNeverDamaged = never damaged (no debt, never a candidate).
  std::vector<uint64_t> last_damage_us_;
  std::vector<Cluster> clusters_; // pre-reserved scratch
  // Eligible tiles for the current tick in row-major order, packed as
  // (ty << 16) | tx. Populated by tick's single eligibility scan and consumed
  // by build_clusters (avoids a second full-grid scan). Pre-reserved.
  std::vector<uint32_t> eligible_tiles_;
  // Scratch for the vertical-stack adjacency probe (packed sort keys); lets
  // build_clusters skip the O(n^2) stack merge when no clusters can stack.
  std::vector<uint64_t> stack_probe_;
  // Forced scroll-settle candidates; bounded, overflow unions into the last
  // entry (coverage preserved).
  std::vector<ForcedSettle> forced_;
  size_t emitted_settles_ = 0;
  size_t emitted_full_flashes_ = 0;
  size_t emitted_sparkles_ = 0;

  // Sparkle ghost-repair trickle (flash-free): after ANY settle burst —
  // ledger-driven, whole-field, or forced scroll — a rotation of
  // scattered white repair passes over the settled region (one per
  // interval; the backend masks white pixels per pass via an R2
  // low-discrepancy slot). Re-arming mid-rotation unions the rect.
  //
  // Mono glass: 16-phase mode-8 top-off (lifts under-whites), cancelled on
  // re-damage (ARC). phase == kSparklePhases = idle.
  //
  // Color glass deliberately does not run the former per-pixel GC16 DEVELOP
  // sweep. Real Move observation showed its nominally sparse admissions as
  // repeated black squares that left white glass gold/orange. Pigment repair
  // is now aggregated by AutoGhostbuster and paid with one balanced global
  // Bleach only after broad coverage reaches its threshold. Required Full
  // updates for actual chromatic content remain separate.
  static constexpr uint32_t kSparklePhases = 16;
  static constexpr uint64_t kSparkleIntervalUs = 500'000;
  void arm_sparkle(const PlutoRect &rect, uint64_t now_us);
  PlutoRect sparkle_rect_{0, 0, 0, 0};
  uint32_t sparkle_phase_ = kSparklePhases;
  uint64_t sparkle_next_us_ = 0;
};

} // namespace pluto

#endif // PLUTO_RENDERER_SETTLE_POLICY_H_
