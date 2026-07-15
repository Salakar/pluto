#ifndef PLUTO_PRESENTER_SWTCON_SWTCON_PACKER_H_
#define PLUTO_PRESENTER_SWTCON_SWTCON_PACKER_H_

#include "pluto/presenter.h"
#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_waveform.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace pluto::swtcon {

struct SourceFrame {
  const std::uint8_t* previous_pixels = nullptr;
  const std::uint8_t* next_pixels = nullptr;
  std::size_t previous_stride_bytes = 0;
  std::size_t next_stride_bytes = 0;
  int width = kLogicalWidth;
  int height = kLogicalHeight;
  PlutoPixelFormat format = kPlutoPixelFormatRgb565;
};

// TEST-ONLY REFERENCE MODEL since the per-pixel engine landed: the
// record-at-a-time packer survives solely as the equivalence-proof oracle
// (engine+emitter output must be byte-identical to record playback for
// uniform admissions) and for the word-exact encoding pins.
// It is compiled only into the native presenter tests, not into
// pluto_embedder_core.
class SwtconPacker final {
 public:
  // Packs the frame's per-pixel src->dst transitions into
  // N = lookup.phase_count() contiguous kDrmPhaseWords RG16 phase frames
  // (rg16_out is resized), each on the control scaffold, meant to be played
  // once. Fails when the lookup has no phases (no decoded waveform).
  bool pack(const SourceFrame& source,
            const PhaseLookup& lookup,
            std::vector<std::uint16_t>* rg16_out,
            std::string* error = nullptr) const;
};

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_SWTCON_PACKER_H_
