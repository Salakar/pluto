#ifndef PLUTO_RENDERER_RENDERER_HANDOFF_H_
#define PLUTO_RENDERER_RENDERER_HANDOFF_H_

#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

#include "pluto/presenter.h"
#include "renderer/auto_ghostbuster.h"
#include "renderer/classify_ladder.h"
#include "renderer/frame_ledger.h"
#include "renderer/ledgers.h"
#include "renderer/region_scheduler.h"
#include "renderer/renderer_config.h"
#include "renderer/settle_policy.h"

namespace pluto {

// Pointer-free renderer half of the coordinated glass handoff. The on-disk
// representation is defined by renderer_handoff.cc and is always explicit
// little-endian; these in-memory state objects are never memcpy-serialized.
struct RendererHandoffState {
  static constexpr uint32_t kVersion = 1;

  uint32_t version = kVersion;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t rotation = 0;
  PlutoPixelFormat pixel_format = kPlutoPixelFormatRgb565;
  PlutoPixelFormat presenter_format = kPlutoPixelFormatRgb565;
  uint64_t retained_stride = 0;
  RendererConfig renderer_config{};
  bool start_presenter_thread = true;
  bool presenter_pen_focus_from_host = false;
  bool enable_present_bridge = true;
  bool display_info_available = true;
  bool present_bridge_active = true;
  bool mirror_enabled = true;
  bool enable_auto_ghostbuster = true;
  bool pigment_hygiene_supported = false;
  bool panel_is_color = false;
  bool backend_quantizes_color = false;
  bool presenter_controls_refresh_class = false;

  // Exact source-format mirror currently settled on glass. In particular,
  // RGB565 hue is retained even when two colors quantize to the same luma.
  std::vector<uint8_t> retained_frame;

  // Persistent scroll policy state. Counters are included so diagnostics do
  // not jump backwards across a warm process switch.
  uint32_t scroll_pending_px = 0;
  int32_t scroll_ledger_shift_px = 0;
  uint64_t scroll_moves = 0;
  uint8_t active_input_mask = 0;
  uint64_t last_input_change_us = 0;
  uint64_t automatic_ghost_actions = 0;

  FrameLedgerState frame_ledger;
  ClassifyLadderState classify_ladder;
  GhostLedgerState ghost_ledger;
  StressLedgerState stress_ledger;
  ChromaPendingState chroma_pending;
  SettlePlannerState settle_planner;
  AutoGhostbusterState auto_ghostbuster;
  RegionSchedulerState region_scheduler;
};

enum class RendererHandoffReject : uint8_t {
  kNone = 0,
  kArgument,
  kTooLarge,
  kTruncated,
  kMagic,
  kVersion,
  kHeader,
  kChecksum,
  kConfiguration,
  kGeometry,
  kFormat,
  kState,
  kTrailingData,
};

const char *renderer_handoff_reject_name(RendererHandoffReject reject);

// Stable configuration identity. Dynamic debt/history/mirror contents do not
// contribute; every setting that can affect a subsequent renderer decision
// does. A presenter carries this value beside the opaque renderer bytes.
uint64_t renderer_handoff_configuration_hash(const RendererHandoffState &state);

// Validates the complete correlated state with the owning components' import
// invariants, then emits/reads the canonical little-endian payload. Decode is
// all-or-nothing: `out` is untouched on failure.
bool renderer_handoff_encode(const RendererHandoffState &state,
                             std::vector<uint8_t> *out,
                             RendererHandoffReject *reject = nullptr);
bool renderer_handoff_decode(std::span<const uint8_t> bytes,
                             uint64_t expected_configuration_hash,
                             RendererHandoffState *out,
                             RendererHandoffReject *reject = nullptr);

// Read-only validation used before live component imports. This deliberately
// constructs scratch renderer components, proving every individual import
// succeeds without partially mutating the live renderer transaction.
bool renderer_handoff_validate(const RendererHandoffState &state);

} // namespace pluto

#endif // PLUTO_RENDERER_RENDERER_HANDOFF_H_
