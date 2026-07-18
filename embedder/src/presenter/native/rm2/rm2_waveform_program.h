#ifndef PLUTO_PRESENTER_NATIVE_RM2_RM2_WAVEFORM_PROGRAM_H_
#define PLUTO_PRESENTER_NATIVE_RM2_RM2_WAVEFORM_PROGRAM_H_

#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "generated/device_profiles.h"
#include "pluto/presenter.h"
#include "presenter/native/rm2/wbf_decoder.h"

namespace pluto::native::rm2 {

struct Rm2WaveformSelection {
  std::uint32_t mode = 0;
  std::uint32_t temperature = 0;
  std::uint32_t phase_count = 0;
  // Phase-major 16x16 gray4 transition tables. The full table preserves
  // diagonal WBF transitions; the partial table replaces every diagonal
  // transition with HOLD. Both views remain valid until clear()/open().
  std::span<const std::uint8_t> drive_lut;
  std::span<const std::uint8_t> partial_drive_lut;
};

// The vendor MFD exposes the live SY7636A power-good bit separately from its
// fault-event latch. The latter records a historical event until the PMIC EN
// pin is retoggled, so a non-empty latched_fault_event is diagnostic evidence,
// not proof that rails which are currently power-good are unsafe.
struct Rm2PanelPowerState {
  bool attributes_readable = false;
  bool power_good = false;
  std::string latched_fault_event;

  Rm2PanelPowerState() = default;
  // Keeps injected host readers terse while still distinguishing their live
  // power result from a production sysfs-read failure.
  Rm2PanelPowerState(bool current_power_good)
      : attributes_readable(true), power_good(current_power_good) {}
  Rm2PanelPowerState(bool readable, bool current_power_good,
                     std::string fault_event)
      : attributes_readable(readable), power_good(current_power_good),
        latched_fault_event(std::move(fault_event)) {}

  bool ready() const { return attributes_readable && power_good; }
};

class Rm2WaveformProgram final {
public:
  bool open(const GeneratedDeviceProfile &profile, std::string_view path,
            std::string *error);
  void clear();

  bool valid() const { return decoder_.valid(); }
  const WbfDecoder &decoder() const { return decoder_; }

  // The first and final boundaries in the accepted WBF define a
  // lower-inclusive, upper-exclusive operating envelope. Values outside it
  // must not be silently clamped to an endpoint record.
  bool temperature_supported(int milli_celsius) const;

  bool select(PlutoRefreshClass refresh_class, int milli_celsius,
              Rm2WaveformSelection *out_selection) const;
  bool init_pan_codes(int milli_celsius,
                      std::vector<std::uint8_t> *out_codes) const;

private:
  struct ExpandedRecord {
    std::vector<std::uint8_t> drive_lut;
    std::vector<std::uint8_t> partial_drive_lut;
    std::uint16_t phase_count = 0;
  };

  bool build_expanded_records(std::string *error);
  const ExpandedRecord *expanded_record(std::uint32_t mode,
                                        std::uint32_t temperature) const;

  WbfDecoder decoder_;
  std::vector<ExpandedRecord> expanded_records_;
};

// Reads only the explicitly named SY7636A panel sensor. It never falls back
// to an arbitrary SoC hwmon node.
std::optional<int> read_rm2_panel_temperature_millidegrees(std::string *error);

// Finds exactly one SY7636A I2C parent by address and driver identity, then
// returns the live power-good value and the independent historical fault-event
// latch. Missing, ambiguous, or unreadable attributes return an unavailable
// state and an exact error.
Rm2PanelPowerState read_rm2_panel_power_state(
    std::string *error,
    std::string_view i2c_devices_root = "/sys/bus/i2c/devices");

} // namespace pluto::native::rm2

#endif // PLUTO_PRESENTER_NATIVE_RM2_RM2_WAVEFORM_PROGRAM_H_
