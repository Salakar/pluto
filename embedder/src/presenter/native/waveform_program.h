#ifndef PLUTO_PRESENTER_NATIVE_WAVEFORM_PROGRAM_H_
#define PLUTO_PRESENTER_NATIVE_WAVEFORM_PROGRAM_H_

#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>

#include "pluto/presenter.h"

namespace pluto::native {

struct WaveformTransition {
  std::uint32_t program_id = 0;
  std::uint32_t phase_count = 0;
  std::uint8_t settled_level = 0;
};

// Format-neutral lookup boundary shared by userspace-TCON implementations.
// Gallery 3 .eink and RM2 .wbf decoders remain separate; neither format leaks
// into the common scheduler or scan loop.
class WaveformProgram {
public:
  virtual ~WaveformProgram() = default;

  virtual std::string_view format_name() const = 0;
  virtual std::span<const std::uint8_t> source_sha256() const = 0;
  virtual PlutoStatus select_temperature(int milli_celsius,
                                         std::uint32_t *out_bin) const = 0;
  virtual PlutoStatus lookup(PlutoRefreshClass refresh_class,
                             std::uint32_t temperature_bin,
                             std::uint8_t old_level, std::uint8_t new_level,
                             WaveformTransition *out_transition) const = 0;
  virtual PlutoStatus emit_phase(const WaveformTransition &transition,
                                 std::uint32_t phase,
                                 std::uint8_t *out_drive_code) const = 0;
};

} // namespace pluto::native

#endif // PLUTO_PRESENTER_NATIVE_WAVEFORM_PROGRAM_H_
