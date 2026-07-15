#ifndef PLUTO_PRESENTER_NATIVE_RM2_LCDIF_TCON_BACKEND_H_
#define PLUTO_PRESENTER_NATIVE_RM2_LCDIF_TCON_BACKEND_H_

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "generated/device_profiles.h"
#include "presenter/native/native_display_backend.h"
#include "presenter/native/rm2/mxs_lcdif_device.h"

namespace pluto::native::rm2 {

using Rm2TemperatureReader =
    std::function<std::optional<int>(std::string *error)>;
using Rm2PowerReadyReader = std::function<bool(std::string *error)>;

class LcdifTconDisplayBackend final : public NativeDisplayBackend {
public:
  LcdifTconDisplayBackend(const GeneratedDeviceProfile &profile,
                          std::unique_ptr<MxsLcdifDevice> device = nullptr,
                          Rm2TemperatureReader temperature_reader = {},
                          Rm2PowerReadyReader power_ready_reader = {});
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
