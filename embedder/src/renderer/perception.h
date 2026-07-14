#ifndef PLUTO_RENDERER_PERCEPTION_H_
#define PLUTO_RENDERER_PERCEPTION_H_

#include <cstdint>

#include "pluto/presenter.h"
#include "renderer/renderer_config.h"

namespace pluto {

// PerceptionConstants (Stage-2 stub).
//
// The single place scheduler/settle policy reads perceptual thresholds from.
// Today every accessor is a straight view over RendererConfig; the value of
// the indirection is the seam: when the ambient light sensor and panel
// temperature curves land (`ghost_ambient_scale`), the curves go HERE and
// every consumer picks them up without signature churn. Real
// ambient/temperature adaptivity is a later stage (Stage 7); until then the
// constants are static config.
//
// Thread ownership: read-only after construction; safe from any thread.
class PerceptionConstants {
 public:
  PerceptionConstants() = default;
  explicit PerceptionConstants(const RendererConfig& config)
      : config_(config) {}

  // Ghost debt (Q8 impulse units) above which a quiesced tile is worth a
  // quality settle. Ambient-scaled later (dim room tolerates more ghost).
  uint16_t ghost_debt_settle_threshold() const {
    return config_.ghost_debt_settle_threshold;
  }

  // Stub stress force line (engine wires real DC stress at Stage 4).
  uint16_t stress_settle_threshold() const {
    return config_.stress_settle_threshold;
  }

  // Quiescence window before settle eligibility (fixation-time shaped).
  uint32_t quiesce_ms() const { return config_.settle_quiesce_ms; }

  // Ghost ledger decay time constant.
  uint32_t ghost_tau_ms() const { return config_.ghost_tau_ms; }

  // Flash budget hooks: how much of the panel may be settle-eligible before
  // one whole-screen flash beats many regional ones, and how many settle
  // rects a single burst may emit.
  uint32_t settle_full_area_percent() const {
    return config_.settle_full_area_percent;
  }
  // Per-tile average cluster debt above which the settle promotes to
  // Full-class (pigment-displacement repair on color glass; deep gray
  // ghost on mono).
  uint32_t settle_max_rects() const { return config_.settle_max_rects; }

  // LSM-batch clustering bounds (proximity + max added empty area).
  uint32_t settle_cluster_gap_px() const {
    return config_.settle_cluster_gap_px;
  }
  uint32_t settle_cluster_max_waste_px() const {
    return config_.settle_cluster_max_waste_px;
  }

  // CBS budget for the settle class while interactive work is live.
  uint32_t cbs_settle_budget_pct() const {
    return config_.cbs_settle_budget_pct;
  }

  // Saliency weight for settle ordering (debt x saliency).
  // Stub: mild center weighting; pen proximity arrives with the ink thread.
  // Returns Q8 (256 = 1.0).
  uint32_t saliency_q8(const PlutoRect& rect, int32_t panel_width,
                       int32_t panel_height) const;

 private:
  RendererConfig config_{};
};

}  // namespace pluto

#endif  // PLUTO_RENDERER_PERCEPTION_H_
