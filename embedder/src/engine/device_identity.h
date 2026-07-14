#ifndef PLUTO_ENGINE_DEVICE_IDENTITY_H_
#define PLUTO_ENGINE_DEVICE_IDENTITY_H_

#include <string>
#include <string_view>

namespace pluto {

// Stable wire identity exposed by pluto/device. Unknown hardware deliberately
// stays unknown instead of inheriting the embedder's historical Move defaults.
struct RemarkableDeviceIdentity {
  std::string model = "unknown";
  std::string codename;
};

// Injectable paths keep immutable-hardware probing deterministic in tests.
struct RemarkableDeviceIdentityPaths {
  std::string soc_machine = "/sys/devices/soc0/machine";
  std::string device_tree_model = "/proc/device-tree/model";
  std::string device_tree_compatible = "/proc/device-tree/compatible";
};

// Classifies the concatenated contents of immutable SoC/device-tree identity
// files. The mutable hostname is intentionally never accepted as evidence.
RemarkableDeviceIdentity classify_remarkable_device_identity(
    std::string_view hardware_identity);

RemarkableDeviceIdentity probe_remarkable_device_identity(
    const RemarkableDeviceIdentityPaths& paths = {});

}  // namespace pluto

#endif  // PLUTO_ENGINE_DEVICE_IDENTITY_H_
