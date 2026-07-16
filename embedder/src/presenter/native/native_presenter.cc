#include "presenter/native/native_presenter.h"

#include <cstring>
#include <memory>
#include <new>
#include <utility>

#include "engine/device_identity.h"
#include "presenter/native/gallery3_drm_backend.h"
#include "presenter/native/mxcfb/mxcfb_backend.h"
#include "presenter/native/native_display_backend.h"
#include "presenter/native/rm2/lcdif_tcon_backend.h"
#include "presenter/presenter_contract.h"

namespace pluto::native {
namespace {

PlutoPixelFormat profile_pixel_format(const GeneratedDeviceProfile &profile) {
  if (profile.panel.source_pixel_format == "rgb565") {
    return kPlutoPixelFormatRgb565;
  }
  if (profile.panel.source_pixel_format == "gray8") {
    return kPlutoPixelFormatGray8;
  }
  return kPlutoPixelFormatXrgb8888;
}

class PresenterOpsDisplayBackend final : public NativeDisplayBackend {
public:
  PresenterOpsDisplayBackend(const GeneratedDeviceProfile &profile,
                             const PlutoPresenterOps *ops)
      : profile_(profile), ops_(ops) {}

  ~PresenterOpsDisplayBackend() override { stop(); }

  std::string_view driver_name() const override { return ops_->name; }

  PlutoStatus probe(const GeneratedDeviceProfile &profile) override {
    if (&profile != &profile_ || !presenter_ops_are_current(ops_)) {
      return kPlutoStatusUnsupported;
    }
    return kPlutoStatusOk;
  }

  PlutoStatus start(const PlutoPresenterConfig &config) override {
    if (presenter_ != nullptr) {
      return kPlutoStatusInvalidArgument;
    }
    PlutoPresenterConfig backend_config = config;
    backend_config.backend_name = ops_->name;
    const PlutoStatus open_status = ops_->open(&backend_config, &presenter_);
    if (open_status != kPlutoStatusOk) {
      presenter_ = nullptr;
      observe(open_status);
      return open_status;
    }

    PlutoDisplayInfo display{};
    display.struct_size = sizeof(display);
    const PlutoStatus info_status = ops_->info(presenter_, &display);
    if (info_status != kPlutoStatusOk ||
        display.width != profile_.panel.width ||
        display.height != profile_.panel.height ||
        display.dpi != profile_.panel.dpi ||
        display.preferred_format != profile_pixel_format(profile_) ||
        display.is_color != profile_.panel.color) {
      stop();
      return info_status == kPlutoStatusOk ? kPlutoStatusUnsupported
                                           : info_status;
    }
    return kPlutoStatusOk;
  }

  PlutoStatus info(PlutoDisplayInfo *out_info) override {
    return call(ops_->info, out_info);
  }

  PlutoStatus submit(const PlutoPresentRequest *request) override {
    const PlutoStatus status = presenter_ != nullptr
                                   ? ops_->present(presenter_, request)
                                   : kPlutoStatusDeviceLost;
    observe(status);
    return status;
  }

  bool ready(PlutoRefreshClass refresh_class) override {
    if (presenter_ == nullptr) {
      return false;
    }
    const bool is_ready = ops_->ready(presenter_, refresh_class);
    if (!is_ready && health_.state == NativeBackendHealthState::kReady) {
      health_.state = NativeBackendHealthState::kBusy;
    } else if (is_ready) {
      health_.state = NativeBackendHealthState::kReady;
    }
    return is_ready;
  }

  PlutoStatus wait_idle(std::uint32_t timeout_ms) override {
    const PlutoStatus status = presenter_ != nullptr
                                   ? ops_->wait_idle(presenter_, timeout_ms)
                                   : kPlutoStatusDeviceLost;
    observe(status);
    return status;
  }

  PlutoStatus snapshot(PlutoSurface *out_surface) override {
    return call(ops_->snapshot, out_surface);
  }

  PlutoStatus set_pen_focus(const PlutoPenFocus *focus) override {
    return call(ops_->set_pen_focus, focus);
  }

  PlutoStatus stage_handoff(const PlutoHandoffPayload *payload,
                            std::uint32_t timeout_ms) override {
    if (presenter_ == nullptr) {
      return kPlutoStatusDeviceLost;
    }
    const PlutoStatus status =
        ops_->stage_handoff(presenter_, payload, timeout_ms);
    observe(status);
    return status;
  }

  PlutoStatus get_handoff(PlutoHandoffPayload *out_payload) override {
    return call(ops_->get_handoff, out_payload);
  }

  PlutoStatus confirm_handoff(bool accepted) override {
    if (presenter_ == nullptr) {
      return kPlutoStatusDeviceLost;
    }
    const PlutoStatus status = ops_->confirm_handoff(presenter_, accepted);
    observe(status);
    return status;
  }

  PlutoStatus suspend(std::uint32_t timeout_ms) override {
    return wait_idle(timeout_ms);
  }

  PlutoStatus resume() override {
    // The current direct session is process-per-resume. The supervisor starts
    // a fresh process so the backend reopens every device and revalidates the
    // profile instead of retaining descriptors across suspend.
    return kPlutoStatusUnsupported;
  }

  NativeBackendHealth health() const override { return health_; }

  void stop() override {
    if (presenter_ != nullptr) {
      ops_->close(presenter_);
    }
    presenter_ = nullptr;
  }

private:
  template <typename Argument>
  PlutoStatus call(PlutoStatus (*function)(PlutoPresenter *, Argument *),
                   Argument *argument) {
    const PlutoStatus status = presenter_ != nullptr
                                   ? function(presenter_, argument)
                                   : kPlutoStatusDeviceLost;
    observe(status);
    return status;
  }

  void observe(PlutoStatus status) {
    if (status == kPlutoStatusDeviceLost || status == kPlutoStatusInternal) {
      health_.state = NativeBackendHealthState::kDeviceLost;
      ++health_.hardware_faults;
    } else if (status == kPlutoStatusAgain || status == kPlutoStatusTimeout) {
      health_.state = NativeBackendHealthState::kBusy;
    } else if (status == kPlutoStatusOk) {
      health_.state = NativeBackendHealthState::kReady;
    }
  }

  const GeneratedDeviceProfile &profile_;
  const PlutoPresenterOps *ops_ = nullptr;
  PlutoPresenter *presenter_ = nullptr;
  NativeBackendHealth health_;
};

class NativePresenter final {
public:
  explicit NativePresenter(std::unique_ptr<NativeDisplayBackend> backend)
      : backend_(std::move(backend)) {}

  NativeDisplayBackend *backend() { return backend_.get(); }

private:
  std::unique_ptr<NativeDisplayBackend> backend_;
};

NativePresenter *as_native(PlutoPresenter *presenter) {
  return reinterpret_cast<NativePresenter *>(presenter);
}

PlutoStatus native_open(const PlutoPresenterConfig *config,
                        PlutoPresenter **out_presenter) {
  if (config == nullptr || out_presenter == nullptr ||
      config->struct_size != sizeof(PlutoPresenterConfig) ||
      (config->backend_name != nullptr &&
       std::strcmp(config->backend_name, "native") != 0)) {
    return kPlutoStatusInvalidArgument;
  }
  *out_presenter = nullptr;

  const RemarkableDeviceIdentity identity = probe_remarkable_device_identity();
  const GeneratedDeviceProfile *profile =
      generated_device_profile_by_id(identity.profile_id);
  if (profile == nullptr) {
    return kPlutoStatusUnsupported;
  }

  PlutoStatus factory_status = kPlutoStatusUnsupported;
  std::unique_ptr<NativeDisplayBackend> backend =
      make_native_display_backend(*profile, &factory_status);
  if (backend == nullptr) {
    return factory_status;
  }
  const PlutoStatus probe_status = backend->probe(*profile);
  if (probe_status != kPlutoStatusOk) {
    return probe_status;
  }
  const PlutoStatus start_status = backend->start(*config);
  if (start_status != kPlutoStatusOk) {
    return start_status;
  }

  auto presenter = std::make_unique<NativePresenter>(std::move(backend));
  *out_presenter = reinterpret_cast<PlutoPresenter *>(presenter.release());
  return kPlutoStatusOk;
}

void native_close(PlutoPresenter *presenter) { delete as_native(presenter); }

PlutoStatus native_info(PlutoPresenter *presenter, PlutoDisplayInfo *out_info) {
  return presenter != nullptr ? as_native(presenter)->backend()->info(out_info)
                              : kPlutoStatusInvalidArgument;
}

PlutoStatus native_present(PlutoPresenter *presenter,
                           const PlutoPresentRequest *request) {
  return presenter != nullptr ? as_native(presenter)->backend()->submit(request)
                              : kPlutoStatusInvalidArgument;
}

bool native_ready(PlutoPresenter *presenter, PlutoRefreshClass refresh_class) {
  return presenter != nullptr &&
         as_native(presenter)->backend()->ready(refresh_class);
}

PlutoStatus native_wait_idle(PlutoPresenter *presenter,
                             std::uint32_t timeout_ms) {
  return presenter != nullptr
             ? as_native(presenter)->backend()->wait_idle(timeout_ms)
             : kPlutoStatusInvalidArgument;
}

PlutoStatus native_snapshot(PlutoPresenter *presenter,
                            PlutoSurface *out_surface) {
  return presenter != nullptr
             ? as_native(presenter)->backend()->snapshot(out_surface)
             : kPlutoStatusInvalidArgument;
}

PlutoStatus native_set_pen_focus(PlutoPresenter *presenter,
                                 const PlutoPenFocus *focus) {
  return presenter != nullptr
             ? as_native(presenter)->backend()->set_pen_focus(focus)
             : kPlutoStatusInvalidArgument;
}

PlutoStatus native_stage_handoff(PlutoPresenter *presenter,
                                 const PlutoHandoffPayload *payload,
                                 std::uint32_t timeout_ms) {
  return presenter != nullptr ? as_native(presenter)->backend()->stage_handoff(
                                    payload, timeout_ms)
                              : kPlutoStatusInvalidArgument;
}

PlutoStatus native_get_handoff(PlutoPresenter *presenter,
                               PlutoHandoffPayload *out_payload) {
  return presenter != nullptr
             ? as_native(presenter)->backend()->get_handoff(out_payload)
             : kPlutoStatusInvalidArgument;
}

PlutoStatus native_confirm_handoff(PlutoPresenter *presenter, bool accepted) {
  return presenter != nullptr
             ? as_native(presenter)->backend()->confirm_handoff(accepted)
             : kPlutoStatusInvalidArgument;
}

const PlutoPresenterOps kNativeOps{
    sizeof(PlutoPresenterOps),
    "native",
    native_open,
    native_close,
    native_info,
    native_present,
    native_ready,
    native_wait_idle,
    native_snapshot,
    native_set_pen_focus,
    native_stage_handoff,
    native_get_handoff,
    native_confirm_handoff,
};

} // namespace

bool native_display_backend_is_implemented(
    const GeneratedDeviceProfile &profile) {
  if (!profile.runtime.native_session_enabled) {
    return false;
  }
  return profile.display_driver == NativeDisplayDriverKind::kGallery3Drm ||
         profile.display_driver == NativeDisplayDriverKind::kMxcfbEpdc ||
         profile.display_driver == NativeDisplayDriverKind::kLcdifTcon;
}

std::unique_ptr<NativeDisplayBackend>
make_native_display_backend(const GeneratedDeviceProfile &profile,
                            PlutoStatus *out_status) {
  if (out_status != nullptr) {
    *out_status = kPlutoStatusUnsupported;
  }
  if (!native_display_backend_is_implemented(profile)) {
    return nullptr;
  }
  switch (profile.display_driver) {
  case NativeDisplayDriverKind::kGallery3Drm:
    if (out_status != nullptr) {
      *out_status = kPlutoStatusOk;
    }
    return std::make_unique<PresenterOpsDisplayBackend>(
        profile, pluto_gallery3_drm_presenter_ops());
  case NativeDisplayDriverKind::kMxcfbEpdc:
    if (out_status != nullptr) {
      *out_status = kPlutoStatusOk;
    }
    return std::make_unique<mxcfb::MxcfbDisplayBackend>(profile);
  case NativeDisplayDriverKind::kLcdifTcon:
    if (out_status != nullptr) {
      *out_status = kPlutoStatusOk;
    }
    return std::make_unique<rm2::LcdifTconDisplayBackend>(profile);
  }
  return nullptr;
}

} // namespace pluto::native

extern "C" {

const PlutoPresenterOps *pluto_native_presenter_ops(void) {
  return &pluto::native::kNativeOps;
}

} // extern "C"
