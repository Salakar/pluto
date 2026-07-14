#ifndef PLUTO_RENDERER_RENDERER_CONFIG_H_
#define PLUTO_RENDERER_RENDERER_CONFIG_H_

#include <cstdint>

namespace pluto {

// Constants of the renderer's fused tile pass. Fields are added here as
// the stage that consumes them lands — engine/scheduler constants
// (max_active_px, ghost_tau_ms, ...) arrive with Stages 2+, not before.
struct RendererConfig {
  // Tile edge in px. Panel grid: 954x1696 -> 30x53 = 1590 tiles of 32x32.
  // Must be a multiple of 8 (byte-aligned chroma bitplane rows) and at most
  // FrameLedger::kMaxTilePx; host tests use smaller surfaces + tiles.
  uint32_t tile_px = 32;

  // Chroma magnitude floor: a pixel whose max pairwise RGB channel
  // delta exceeds this carries chroma. 12 mirrors the proven
  // rgb565_has_chroma() "> 12" predicate (renderer/quantize.cc).
  uint8_t chroma_floor = 12;

  // Dither mask for the 16-level quantizer. Currently the position-keyed
  // 64x64 blue-noise mask only (renderer/bluenoise_64.h); the enum leaves
  // room for later masks without an ABI change.
  enum class DitherMask : uint8_t {
    kBlueNoise64 = 0,
  };
  DitherMask dither_mask = DitherMask::kBlueNoise64;

  // -- Stage 2: scheduler / ledger / settle constants ---------------------
  // Consumed through PerceptionConstants (renderer/perception.h): the named
  // accessors are the seam where ambient/temperature curves land later.

  // Quiescence window before a region becomes settle-eligible; re-damage
  // re-arms it (ARC-style scan resistance).
  uint32_t settle_quiesce_ms = 300;
  // Pen-aware APP-DAMAGE scheduling. Hover and contact publish only a
  // trajectory hint; verified post-quantize pixels inside this corridor get
  // a Fast grayscale preview followed immediately by Text/Full truth.
  uint32_t pen_hover_radius_px = 48;
  uint32_t pen_contact_radius_px = 36;
  uint32_t pen_changed_pixel_area_scale = 8;
  uint32_t pen_max_preview_area_percent = 20;
  // Ghost-ledger decay time constant (J <- J * e^(-dt/tau)).
  uint32_t ghost_tau_ms = 1000;
  // Ghost debt (Q8 impulse units: 256 = one half-coverage Fast pass or ~one
  // half-coverage Ui pass) at-or-above which a tile LATCHES as owing a
  // quality settle (GhostLedger::owed). 96 means a Fast pass touching 1/8
  // of a tile already latches; smaller touches accumulate across passes.
  uint16_t ghost_debt_settle_threshold = 96;
  // Tile stress (stub accrual until the engine wires real cancel/truncation
  // charges) above which a settle is forced regardless of ghost debt.
  uint16_t stress_settle_threshold = 24;
  // Debt-adaptive class promotion for partial updates: a Fast/Ui update
  // whose tiles average at least this debt (same Q8 scale) dispatches as
  // Text instead — the pixels were changing anyway, so the region repays
  // its ghost inside the content update with no extra pass and no flash.
  // Guarded by ghost_promote_min_gap_ms: only regions updating SLOWER than
  // the gap promote (sustained animation keeps rail-class cadence; the
  // settle planner repays it at rest). Default = ~3 full-coverage Fast
  // passes unsettled — the "getting bad" line for sub-quiescence activity
  // (e.g. typing) that re-arms the settle window forever and would
  // otherwise never be repaired while it continues.
  uint16_t ghost_debt_promote_threshold = 2048;
  uint32_t ghost_promote_min_gap_ms = 250;
  // Broad-backlog budget: above this eligible-tile percentage, achromatic
  // debt becomes one full-screen Text repayment. Real chroma still uses exact
  // regional Full clusters.
  uint32_t settle_full_area_percent = 40;
  // Settle emission cap per burst (clusters, not tiles).
  uint32_t settle_max_rects = 4;
  // LSM-batch clustering bounds. Stage 2 clusters with EXACT coverage
  // (zero added area: settled coverage must stay a pure function of the
  // owed/chroma tile sets while Full-class presents are not byte-idempotent
  // on unchanged content -- see SettlePlanner::build_clusters). These knobs
  // are reserved for re-enabling bounded fill-in later; they never permit
  // the everything-into-one-union flash.
  uint32_t settle_cluster_gap_px = 64;
  uint32_t settle_cluster_max_waste_px = 0;
  // CBS budget for the settle class: fraction of dispatch slots background
  // settles may consume while interactive work is arriving (they run freely
  // when the panel is otherwise idle).
  uint32_t cbs_settle_budget_pct = 30;

  // -- Stage 6: classify ladder / scroll detect / guard bands --------------

  // Guard-band dilation in px (1 vs 2 still to be decided on-device). The
  // GuardBandPackager is the single guard authority — the scheduler's old
  // +4/+8 drive-rect dilation died with it.
  uint32_t guard_px = 1;
  // Edge flag map (US11568827) — pending legal review. The key exists so
  // option plumbing stays stable; GuardBandPackager rejects ON with a
  // warning and runs with the map off.
  bool flag_map_enabled = false;
  // NAS error-vs-JND ladder rung: structure in place, constants await
  // the device refit. OFF skips the rung entirely.
  bool nas_enabled = false;
  // Scroll detector: minimum damaged-band height worth a row-hash vote
  // (the area gate scales with it: band area must exceed
  // scroll_min_band_rows * panel width) and the dy search window.
  uint32_t scroll_min_band_rows = 64;
  uint32_t scroll_max_dy = 128;
  // Motion-masked MOVE body pacing: the translated body presents as ONE
  // Fast pass per this many accumulated px of translation (roughly one rail
  // waveform per drive at reading-scroll speeds); the armed post-scroll
  // settle repaints the final body when the motion rests.
  uint32_t scroll_body_emit_px = 32;
};

}  // namespace pluto

#endif  // PLUTO_RENDERER_RENDERER_CONFIG_H_
