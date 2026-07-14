#include "pluto/presenter.h"

#include <cstdlib>
#include <cstring>

#include "presenter/host_preview.h"
#include "presenter/qtfb/qtfb_presenter.h"
#include "presenter/swtcon/drm_swtcon_presenter.h"

extern "C" {

const PlutoPresenterOps* pluto_presenter_by_name(const char* name) {
  if (name == nullptr) {
    return pluto_presenter_probe();
  }
  if (std::strcmp(name, "qtfb") == 0) {
    return pluto_qtfb_presenter_ops();
  }
  if (std::strcmp(name, "swtcon") == 0) {
    return pluto_swtcon_presenter_ops();
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

const PlutoPresenterOps* pluto_presenter_probe(void) {
  const char* key = std::getenv("QTFB_KEY");
  if (key != nullptr && *key != '\0') {
    return pluto_qtfb_presenter_ops();
  }
  const char* swtcon = std::getenv("PLUTO_SWTCON_AUTO");
  if (swtcon != nullptr && std::strcmp(swtcon, "1") == 0) {
    return pluto_swtcon_presenter_ops();
  }
  return pluto_host_preview_presenter_ops();
}

}  // extern "C"
