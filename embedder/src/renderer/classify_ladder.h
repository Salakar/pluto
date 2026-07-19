#ifndef PLUTO_RENDERER_CLASSIFY_LADDER_H_
#define PLUTO_RENDERER_CLASSIFY_LADDER_H_

#include <cstddef>
#include <cstdint>
#include <vector>

#include "pluto/presenter.h"
#include "renderer/ledgers.h"
#include "renderer/tile_pass.h"

namespace pluto {

// ClassifyLadder: decides the refresh class of every merged damage region.
// Replaced RefreshClassifier (classify.{h,cc}, deleted with this ladder —
// single-renderer policy).
//
// The ladder consumes TileStats ONLY (plus its own per-tile epoch history
// built from the same records): no pixel reads, ever. Rungs, cheapest
// evidence first, with one deliberate reorder against the rung numbering:
//
//   (iv) scenecut runs FIRST (gated off under motion) because it replaces
//        the old scheduler-side structural-full heuristic, which OVERRODE
//        already-classified queues at dispatch. Its two load-bearing
//        behaviors are preserved and pinned by the replay baselines:
//        frame-0 full flash (the invalidated ledger reports 100% changed
//        coverage) and the large-change flash. Motion-masked churn (full
//        screen animation) never scenecuts — that matches the old code,
//        where structural promotion required quality-class queues.
//   (i)  damage histogram: pure B/W content (level_hist == rails {0,30})
//        is lossless under the rail fast path -> Fast(DU-class); <= 4
//        distinct level buckets -> Fast; anything richer falls through to
//        the quality rungs.
//   (ii) motion shortcut: a region whose tiles are re-damaged at pass
//        cadence WITH overlapping dirty rects (same pixels churning, not
//        typing-style accretion) -> Fast under motion masking. Firing arms
//        a per-tile stickiness window so classes do not flap when damage
//        alternates around the streak boundary.
//  (iii) NAS error-vs-JND check (E7): structure in place behind
//        nas_enabled (default OFF); the conservative default constants
//        (k = infinity) skip every mode until the device refit.
//   (v)  dwell buckets from tile epochs (guardrail): hot (immediately
//        re-damaged accretion, e.g. typing) and cold (long-quiet region,
//        one-shot change) buckets take Text quality; the warm middle
//        (recently active, likely to churn again) stays Ui. The old
//        classifier's ">70% of panel -> Text" big-repaint rule is
//        preserved here.
//
// Output is the ABI PlutoRefreshClass; upward-only promotion inside a
// present is the scheduler's contract and unchanged.
//
// Thread ownership: raster-thread confined (FrameRenderer's submit path,
// under its mutex). Pre-allocated per-tile history; no per-frame heap.
struct ClassifyLadderConfig {
  int32_t width = 954;
  int32_t height = 1696;
  uint32_t tile_px = 32;

  // (ii) motion shortcut.
  uint32_t motion_streak = 3;          // consecutive overlapping passes
  uint32_t motion_tile_percent = 60;   // region tiles that must be moving
  uint32_t motion_cooldown_epochs = 2; // stickiness (no-flapping)

  // (iii) NAS (E7-tagged; constants await the device refit).
  bool nas_enabled = false;
  // Q8 per-mode masking constants, cheapest mode first (Fast, Ui, Text).
  // UINT32_MAX = the mode never passes the JND test (conservative).
  uint32_t nas_k_q8[3] = {UINT32_MAX, UINT32_MAX, UINT32_MAX};
  uint32_t nas_tau_q8 = 256; // JND budget scale (E7 placeholder)
  uint32_t nas_l = 16;       // Weber dark-lift term (E7 placeholder)

  // (iv) scenecut (replaces RegionScheduler structural full).
  uint32_t scenecut_coverage_percent = 30;   // changed_px vs panel area
  uint8_t scenecut_intensity_min = 48;       // pre-dither max |delta luma|
  uint32_t scenecut_ghost_bias_percent = 33; // owed debt lowers the bar
  // Scenecut hysteresis (x264 min-GOP analog; E8-family perceptual
  // constant): a region whose tiles produced ANOTHER scenecut-shaped
  // change within this many epochs of the last one is churning, not
  // cutting — big redraws at half pass cadence never build the motion
  // streak, so without this window they would Full-flash on every
  // damage frame. Suppressed repeats re-arm the window (sustained churn
  // stays suppressed until it rests) and fall through to the quality
  // rungs; the settle planner owns the eventual quality repaint.
  uint32_t scenecut_cooldown_epochs = 4;
  // Preserved whole-screen promotion: when the frame's scenecut regions
  // cover at least this much of the panel, FrameRenderer flashes the whole
  // screen instead of the union (old structural_full_screen_area_percent).
  uint32_t full_screen_area_percent = 45;

  // (v) dwell buckets.
  uint32_t dwell_hot_epochs = 1;   // gap <= : active accretion -> Text
  uint32_t dwell_cold_epochs = 8;  // gap >= : long-quiet one-shot -> Text
  uint32_t text_area_percent = 70; // preserved big-repaint quality rule
};

// Which rung decided (diagnostics + decision-matrix goldens).
enum class LadderRung : uint8_t {
  kHistogram = 0, // (i)
  kMotion = 1,    // (ii)
  kNas = 2,       // (iii)
  kScenecut = 3,  // (iv)
  kDwell = 4,     // (v)
};

struct LadderDecision {
  PlutoRefreshClass cls = kPlutoRefreshUi;
  LadderRung rung = LadderRung::kDwell;
};

struct ClassifyTileHistoryState {
  uint32_t last_epoch = 0;
  uint32_t prev_epoch = 0;
  uint32_t streak = 0;
  uint32_t fast_until = 0;
  uint32_t scenecut_epoch = 0;
  PlutoRect last_dirty{0, 0, 0, 0};
};

struct ClassifyLadderState {
  ClassifyLadderConfig config{};
  uint32_t epoch = 0;
  std::vector<ClassifyTileHistoryState> history;
};

class ClassifyLadder {
public:
  // level_hist bits of the pure-B/W rails: level 0 (bit 0) + level 30
  // (bit 15).
  static constexpr uint16_t kRailBwHistMask = 0x8001u;

  bool configure(const ClassifyLadderConfig &config);
  bool valid() const { return valid_; }

  // Once per pass, BEFORE that pass's classify() calls: ingests the dirty
  // tile records (they carry the TileStats snapshots) into the per-tile
  // epoch history that feeds the motion + dwell rungs.
  void begin_pass(uint32_t epoch, const DirtyTileRecord *records, size_t count);

  // Classifies one merged damage region against the stats of ITS dirty
  // tiles this pass. `stats` is the ledger's tile-row-major TileStats
  // array; `ghost` may be null (scenecut ghost-debt bias disabled). Not
  // const: a firing motion rung arms the stickiness window.
  LadderDecision classify(const PlutoRect &region, const TileStats *stats,
                          const GhostLedger *ghost);

  // Only persistent per-tile decision history crosses a process boundary;
  // dirty_idx_ is resettable aggregation scratch and is never serialized.
  bool export_state(ClassifyLadderState *out) const;
  bool import_state(const ClassifyLadderState &state);

private:
  ClassifyLadderConfig config_{};
  TileGrid grid_{};
  bool valid_ = false;
  uint32_t epoch_ = 0;
  std::vector<ClassifyTileHistoryState> history_;
  // Scratch (pre-sized to tile_count): the dirty tile indices found during a
  // classify() aggregation, reused by the scenecut/motion stamp passes so they
  // need not re-scan and re-filter the whole region.
  std::vector<uint32_t> dirty_idx_;
};

} // namespace pluto

#endif // PLUTO_RENDERER_CLASSIFY_LADDER_H_
