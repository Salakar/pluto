#ifndef PLUTO_PRESENTER_NATIVE_RM2_LCDIF_TCON_BACKEND_H_
#define PLUTO_PRESENTER_NATIVE_RM2_LCDIF_TCON_BACKEND_H_

#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>

#include "generated/device_profiles.h"
#include "pluto/glass_handoff.h"
#include "presenter/native/native_display_backend.h"
#include "presenter/native/rm2/mxs_lcdif_device.h"
#include "presenter/native/rm2/rm2_cpu_frequency_lease.h"
#include "presenter/native/rm2/rm2_waveform_program.h"

namespace pluto::native::rm2 {

using Rm2TemperatureReader =
    std::function<std::optional<int>(std::string *error)>;
using Rm2PanelPowerStateReader =
    std::function<Rm2PanelPowerState(std::string *error)>;

// Production is fixed to the shared private tmpfs bundle. Tests may provide
// an isolated path and clock, but the native presenter factory cannot.
struct Rm2HandoffOptions {
  std::string path = kGlassHandoffDefaultPath;
  bool allow_insecure_path_for_testing = false;
  GlassHandoffClock (*now_for_testing)() = nullptr;
  // Deterministic host-only scheduling probe. Production leaves this zero;
  // tests use it to prove encode work overlaps a blocking pan.
  std::chrono::nanoseconds phase_encode_delay_for_testing{};
  // Delays only delivery of an already completed pan result. The device-owned
  // completion timestamp must keep this host-only scheduler jitter out of the
  // physical cadence measurement.
  std::chrono::nanoseconds pan_completion_delivery_delay_for_testing{};
  // Production selects the exact RM2 policy0 paths only in Linux ARM builds.
  // Host tests may inject isolated regular-file fixtures through this field.
  std::optional<Rm2CpuFrequencyLeasePaths> cpu_frequency_paths_for_testing{};
  std::chrono::milliseconds cpu_frequency_debounce_for_testing{50};
  // Thermal backpressure is retried at most once per second in production;
  // this also bounds the one local startup retry after exhausted EAGAIN.
  // Tests may shorten (but not disable) the delay.
  std::chrono::milliseconds cpu_thermal_retry_delay_for_testing{1000};
  // FBIOBLANK(POWERDOWN) may return just before the SY7636A power-good bit
  // falls. Production polls for at most 250 ms at 2 ms intervals before
  // capturing the fail-closed fault baseline. Tests may shorten these bounds.
  std::chrono::milliseconds panel_powerdown_settle_timeout_for_testing{250};
  std::chrono::milliseconds panel_powerdown_poll_interval_for_testing{2};
};

// Exact union area used as the denominator for damage-amplification
// telemetry. Overlapping or duplicate framework rectangles count once.
std::uint64_t rm2_damage_union_area(std::span<const PlutoRect> rectangles);

class LcdifTconDisplayBackend final : public NativeDisplayBackend {
public:
  LcdifTconDisplayBackend(const GeneratedDeviceProfile &profile,
                          std::unique_ptr<MxsLcdifDevice> device = nullptr,
                          Rm2TemperatureReader temperature_reader = {},
                          Rm2PanelPowerStateReader power_state_reader = {},
                          Rm2HandoffOptions handoff = {});
  ~LcdifTconDisplayBackend() override;

  LcdifTconDisplayBackend(const LcdifTconDisplayBackend &) = delete;
  LcdifTconDisplayBackend &operator=(const LcdifTconDisplayBackend &) = delete;

  std::string_view driver_name() const override;
  PlutoStatus probe(const GeneratedDeviceProfile &profile) override;
  PlutoStatus start(const PlutoPresenterConfig &config) override;
  PlutoStatus info(PlutoDisplayInfo *out_info) override;
  PlutoStatus submit(const PlutoPresentRequest *request) override;
  bool ready(PlutoRefreshClass refresh_class) override;
  PlutoStatus wait_idle(std::uint32_t timeout_ms) override;
  PlutoStatus snapshot(PlutoSurface *out_surface) override;
  PlutoStatus set_pen_focus(const PlutoPenFocus *focus) override;
  PlutoStatus stage_handoff(const PlutoHandoffPayload *payload,
                            std::uint32_t timeout_ms) override;
  PlutoStatus get_handoff(PlutoHandoffPayload *out_payload) override;
  PlutoStatus confirm_handoff(bool accepted) override;
  PlutoStatus suspend(std::uint32_t timeout_ms) override;
  PlutoStatus resume() override;
  NativeBackendHealth health() const override;
  void stop() override;

private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace pluto::native::rm2

#endif // PLUTO_PRESENTER_NATIVE_RM2_LCDIF_TCON_BACKEND_H_
