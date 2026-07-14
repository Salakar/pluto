#ifndef PLUTO_PRESENTER_SWTCON_SWTCON_PHASE_GENERATOR_H_
#define PLUTO_PRESENTER_SWTCON_SWTCON_PHASE_GENERATOR_H_

#include "pluto/presenter.h"
#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_packer.h"
#include "presenter/swtcon/swtcon_waveform.h"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace pluto::swtcon {

class SwtconFlipSequencer final {
 public:
  std::size_t next();
  void reset();

 private:
  std::size_t next_index_ = 0;
};

class SwtconPhaseGenerator final {
 public:
  explicit SwtconPhaseGenerator(const SwtconWaveform* waveform = nullptr);

  // Packs the transitions from the tracked previous frame to next_surface
  // into N contiguous RG16 phase frames (N = the decoded waveform's phase
  // count for the class/temperature; packed_out is resized to
  // N * kDrmPhaseWords and phase_count_out receives N).
  bool generate(const PlutoSurface& next_surface,
                const PlutoRect* damage,
                std::size_t damage_count,
                PlutoRefreshClass refresh_class,
                float temperature_c,
                std::vector<std::uint16_t>* packed_out,
                int* phase_count_out,
                std::string* error);

  const std::vector<std::uint8_t>& previous_frame() const {
    return previous_frame_;
  }
  void reset_previous(std::uint16_t rgb565 = 0xffffU);

 private:
  static bool rect_valid(const PlutoRect& rect);
  bool validate_surface(const PlutoSurface& surface, std::string* error) const;
  void copy_damage_to_previous(const PlutoSurface& surface,
                               const PlutoRect* damage,
                               std::size_t damage_count);

  const SwtconWaveform* waveform_ = nullptr;
  SwtconPacker packer_;
  std::vector<std::uint8_t> previous_frame_;
};

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_SWTCON_PHASE_GENERATOR_H_
