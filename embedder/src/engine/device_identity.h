#ifndef PLUTO_ENGINE_DEVICE_IDENTITY_H_
#define PLUTO_ENGINE_DEVICE_IDENTITY_H_

#include <string>
#include <string_view>

namespace pluto {

// Stable wire identity exposed by pluto/device. Unknown hardware deliberately
// stays unknown instead of inheriting the embedder's historical Move defaults.
struct RemarkableDeviceIdentity {
  std::string profile_id;
  std::string model = "unknown";
  std::string codename;
};

// Identity evidence stays separated so matching can require an architecture,
// a board identity, and a compatible identity instead of accepting one token
// from a concatenated bag of strings.
struct RemarkableDeviceIdentityEvidence {
  std::string machine;
  std::string device_tree_model;
  std::string device_tree_compatible;
  std::string architecture;
};

// Injectable paths keep immutable-hardware probing deterministic in tests.
struct RemarkableDeviceIdentityPaths {
  std::string soc_machine = "/sys/devices/soc0/machine";
  std::string device_tree_model = "/proc/device-tree/model";
  std::string device_tree_compatible = "/proc/device-tree/compatible";
  std::string architecture_override;
};

// Classifies immutable SoC/device-tree/architecture evidence. Every accepted
// profile must match all generated evidence groups and conflicts fail closed.
RemarkableDeviceIdentity classify_remarkable_device_identity(
    const RemarkableDeviceIdentityEvidence &evidence);

RemarkableDeviceIdentity probe_remarkable_device_identity(
    const RemarkableDeviceIdentityPaths &paths = {});

} // namespace pluto

#endif // PLUTO_ENGINE_DEVICE_IDENTITY_H_
