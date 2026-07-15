#include "pluto/presenter.h"

#include <cstring>

#include "engine/device_identity.h"
#include "generated/device_profiles.h"
#include "presenter/host_preview.h"
#include "presenter/native/native_display_backend.h"
#include "presenter/native/native_presenter.h"

extern "C" {

const PlutoPresenterOps *pluto_presenter_by_name(const char *name) {
  if (name == nullptr) {
    return pluto_presenter_probe();
  }
  if (std::strcmp(name, "native") == 0) {
    return pluto_native_presenter_ops();
  }
  if (std::strcmp(name, "host-headless") == 0 ||
      std::strcmp(name, "host-png") == 0 ||
      std::strcmp(name, "host-preview") == 0) {
    return pluto_host_preview_presenter_ops();
  }
  if (std::strcmp(name, "null") == 0) {
    return pluto_null_presenter_ops();
  }
  return nullptr;
}

const PlutoPresenterOps *pluto_presenter_probe(void) {
  const pluto::RemarkableDeviceIdentity identity =
      pluto::probe_remarkable_device_identity();
  const pluto::GeneratedDeviceProfile *profile =
      pluto::generated_device_profile_by_id(identity.profile_id);
  if (profile != nullptr &&
      pluto::native::native_display_backend_is_implemented(*profile)) {
    return pluto_native_presenter_ops();
  }
  return pluto_host_preview_presenter_ops();
}

} // extern "C"
