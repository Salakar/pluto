#ifndef PLUTO_PRESENTER_NATIVE_MXCFB_MXCFB_BACKEND_H_
#define PLUTO_PRESENTER_NATIVE_MXCFB_MXCFB_BACKEND_H_

#include <cstdint>
#include <memory>
#include <string_view>

#include "generated/device_profiles.h"
#include "presenter/native/mxcfb/mxcfb_device.h"
#include "presenter/native/native_display_backend.h"

namespace pluto::native::mxcfb {

// Conservative first native backend for the reMarkable 1 kernel EPDC path.
// It deliberately admits one request at a time: the mapped framebuffer is the
// kernel update source, so overlapping writers would otherwise be able to
// mutate pixels before the EPDC has consumed the preceding request.
class MxcfbDisplayBackend final : public NativeDisplayBackend {
public:
  MxcfbDisplayBackend(const GeneratedDeviceProfile &profile,
                      std::unique_ptr<MxcfbDevice> device = nullptr,
                      std::uint32_t first_marker = 0);
  ~MxcfbDisplayBackend() override;

  MxcfbDisplayBackend(const MxcfbDisplayBackend &) = delete;
  MxcfbDisplayBackend &operator=(const MxcfbDisplayBackend &) = delete;
  MxcfbDisplayBackend(MxcfbDisplayBackend &&) = delete;
  MxcfbDisplayBackend &operator=(MxcfbDisplayBackend &&) = delete;

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

} // namespace pluto::native::mxcfb

#endif // PLUTO_PRESENTER_NATIVE_MXCFB_MXCFB_BACKEND_H_
