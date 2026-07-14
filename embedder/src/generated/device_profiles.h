// GENERATED FILE. Edit config/device_profiles.json, then run
// dart tools/codegen/generate_device_profiles.dart.
#ifndef PLUTO_GENERATED_DEVICE_PROFILES_H_
#define PLUTO_GENERATED_DEVICE_PROFILES_H_

#include <array>
#include <span>
#include <string_view>

namespace pluto {

enum class DeviceTargetSlice { kLinuxArm, kLinuxArm64 };
enum class NativeDisplayDriverKind {
  kMxcfbEpdc,
  kLcdifTcon,
  kGallery3Drm,
};

struct GeneratedPanelProfile {
  int width;
  int height;
  int dpi;
  std::string_view source_pixel_format;
  bool color;
};

struct GeneratedDeviceProfile {
  std::string_view id;
  std::string_view wire_model;
  std::string_view codename;
  std::string_view marketing_name;
  std::string_view tested_os;
  DeviceTargetSlice target_slice;
  NativeDisplayDriverKind display_driver;
  GeneratedPanelProfile panel;
  std::span<const std::string_view> architectures;
  std::span<const std::string_view> board_tokens;
  std::span<const std::string_view> compatible_tokens;
  std::span<const std::string_view> build_modes;
  std::span<const std::string_view> capabilities;
};

struct GeneratedDeviceIdentityFixture {
  std::string_view profile_id;
  std::string_view machine;
  std::string_view device_tree_model;
  std::string_view device_tree_compatible;
  std::string_view architecture;
};

inline constexpr std::array<std::string_view, 1> kRm1Architectures = {
    "armv7l",
};

inline constexpr std::array<std::string_view, 3> kRm1BoardTokens = {
    "remarkable 1.0",
    "remarkable 1.n",
    "zero-gravitas",
};

inline constexpr std::array<std::string_view, 2> kRm1CompatibleTokens = {
    "remarkable,zero-gravitas",
    "fsl,imx6sl",
};

inline constexpr std::array<std::string_view, 1> kRm1BuildModes = {
    "release",
};

inline constexpr std::array<std::string_view, 4> kRm1Capabilities = {
    "pen",
    "touch",
    "refresh-control",
    "real-completion",
};

inline constexpr std::array<std::string_view, 1> kRm2Architectures = {
    "armv7l",
};

inline constexpr std::array<std::string_view, 3> kRm2BoardTokens = {
    "remarkable 2.0",
    "remarkable 2.n",
    "zero-sugar",
};

inline constexpr std::array<std::string_view, 1> kRm2CompatibleTokens = {
    "fsl,imx7d-sdb",
};

inline constexpr std::array<std::string_view, 1> kRm2BuildModes = {
    "release",
};

inline constexpr std::array<std::string_view, 4> kRm2Capabilities = {
    "pen",
    "touch",
    "refresh-control",
    "real-completion",
};

inline constexpr std::array<std::string_view, 1> kMoveArchitectures = {
    "aarch64",
};

inline constexpr std::array<std::string_view, 1> kMoveBoardTokens = {
    "chiappa",
};

inline constexpr std::array<std::string_view, 1> kMoveCompatibleTokens = {
    "fsl,imx93",
};

inline constexpr std::array<std::string_view, 3> kMoveBuildModes = {
    "release",
    "profile",
    "debug",
};

inline constexpr std::array<std::string_view, 9> kMoveCapabilities = {
    "pen",
    "touch",
    "frontlight",
    "refresh-control",
    "real-completion",
    "color-quantization",
    "overlap-supersession",
    "exact-color-handoff",
    "hot-reload",
};

inline constexpr std::array<GeneratedDeviceProfile, 3>
    kGeneratedDeviceProfiles = {{
        {
            .id = "rm1",
            .wire_model = "remarkable1",
            .codename = "zero-gravitas",
            .marketing_name = "reMarkable 1",
            .tested_os = "3.27.3.0",
            .target_slice = DeviceTargetSlice::kLinuxArm,
            .display_driver = NativeDisplayDriverKind::kMxcfbEpdc,
            .panel =
                {
                    .width = 1404,
                    .height = 1872,
                    .dpi = 226,
                    .source_pixel_format = "rgb565",
                    .color = false,
                },
            .architectures = kRm1Architectures,
            .board_tokens = kRm1BoardTokens,
            .compatible_tokens = kRm1CompatibleTokens,
            .build_modes = kRm1BuildModes,
            .capabilities = kRm1Capabilities,
        },
        {
            .id = "rm2",
            .wire_model = "remarkable2",
            .codename = "zero-sugar",
            .marketing_name = "reMarkable 2",
            .tested_os = "3.28.0.162",
            .target_slice = DeviceTargetSlice::kLinuxArm,
            .display_driver = NativeDisplayDriverKind::kLcdifTcon,
            .panel =
                {
                    .width = 1404,
                    .height = 1872,
                    .dpi = 226,
                    .source_pixel_format = "rgb565",
                    .color = false,
                },
            .architectures = kRm2Architectures,
            .board_tokens = kRm2BoardTokens,
            .compatible_tokens = kRm2CompatibleTokens,
            .build_modes = kRm2BuildModes,
            .capabilities = kRm2Capabilities,
        },
        {
            .id = "move",
            .wire_model = "paperProMove",
            .codename = "chiappa",
            .marketing_name = "reMarkable Paper Pro Move",
            .tested_os = "3.28.0.162",
            .target_slice = DeviceTargetSlice::kLinuxArm64,
            .display_driver = NativeDisplayDriverKind::kGallery3Drm,
            .panel =
                {
                    .width = 954,
                    .height = 1696,
                    .dpi = 264,
                    .source_pixel_format = "rgb565",
                    .color = true,
                },
            .architectures = kMoveArchitectures,
            .board_tokens = kMoveBoardTokens,
            .compatible_tokens = kMoveCompatibleTokens,
            .build_modes = kMoveBuildModes,
            .capabilities = kMoveCapabilities,
        },
    }};

inline constexpr const GeneratedDeviceProfile *
generated_device_profile_by_id(std::string_view id) {
  for (const GeneratedDeviceProfile &profile : kGeneratedDeviceProfiles) {
    if (profile.id == id) {
      return &profile;
    }
  }
  return nullptr;
}

inline constexpr std::array<GeneratedDeviceIdentityFixture, 10>
    kGeneratedAcceptedDeviceIdentityFixtures = {{
        {
            .profile_id = "rm1",
            .machine = "remarkable 1.0",
            .device_tree_model = "",
            .device_tree_compatible = "remarkable,zero-gravitas",
            .architecture = "armv7l",
        },
        {
            .profile_id = "rm1",
            .machine = "",
            .device_tree_model = "remarkable 1.0",
            .device_tree_compatible = "fsl,imx6sl",
            .architecture = "armv7l",
        },
        {
            .profile_id = "rm1",
            .machine = "remarkable 1.n",
            .device_tree_model = "",
            .device_tree_compatible = "remarkable,zero-gravitas",
            .architecture = "armv7l",
        },
        {
            .profile_id = "rm1",
            .machine = "",
            .device_tree_model = "remarkable 1.n",
            .device_tree_compatible = "fsl,imx6sl",
            .architecture = "armv7l",
        },
        {
            .profile_id = "rm1",
            .machine = "zero-gravitas",
            .device_tree_model = "",
            .device_tree_compatible = "remarkable,zero-gravitas",
            .architecture = "armv7l",
        },
        {
            .profile_id = "rm1",
            .machine = "",
            .device_tree_model = "zero-gravitas",
            .device_tree_compatible = "fsl,imx6sl",
            .architecture = "armv7l",
        },
        {
            .profile_id = "rm2",
            .machine = "remarkable 2.0",
            .device_tree_model = "",
            .device_tree_compatible = "fsl,imx7d-sdb",
            .architecture = "armv7l",
        },
        {
            .profile_id = "rm2",
            .machine = "",
            .device_tree_model = "remarkable 2.n",
            .device_tree_compatible = "fsl,imx7d-sdb",
            .architecture = "armv7l",
        },
        {
            .profile_id = "rm2",
            .machine = "zero-sugar",
            .device_tree_model = "",
            .device_tree_compatible = "fsl,imx7d-sdb",
            .architecture = "armv7l",
        },
        {
            .profile_id = "move",
            .machine = "",
            .device_tree_model = "chiappa",
            .device_tree_compatible = "fsl,imx93",
            .architecture = "aarch64",
        },
    }};

inline constexpr std::array<GeneratedDeviceIdentityFixture, 12>
    kGeneratedRejectedDeviceIdentityFixtures = {{
        {
            .profile_id = "",
            .machine = "",
            .device_tree_model = "",
            .device_tree_compatible = "",
            .architecture = "",
        },
        {
            .profile_id = "",
            .machine = "unrecognized tablet",
            .device_tree_model = "",
            .device_tree_compatible = "vendor,unknown",
            .architecture = "armv7l",
        },
        {
            .profile_id = "",
            .machine = "remarkable 1.0",
            .device_tree_model = "",
            .device_tree_compatible = "",
            .architecture = "armv7l",
        },
        {
            .profile_id = "",
            .machine = "",
            .device_tree_model = "",
            .device_tree_compatible = "remarkable,zero-gravitas",
            .architecture = "armv7l",
        },
        {
            .profile_id = "",
            .machine = "remarkable 1.0",
            .device_tree_model = "",
            .device_tree_compatible = "remarkable,zero-gravitas",
            .architecture = "wrong-architecture",
        },
        {
            .profile_id = "",
            .machine = "remarkable 2.0",
            .device_tree_model = "",
            .device_tree_compatible = "",
            .architecture = "armv7l",
        },
        {
            .profile_id = "",
            .machine = "",
            .device_tree_model = "",
            .device_tree_compatible = "fsl,imx7d-sdb",
            .architecture = "armv7l",
        },
        {
            .profile_id = "",
            .machine = "remarkable 2.0",
            .device_tree_model = "",
            .device_tree_compatible = "fsl,imx7d-sdb",
            .architecture = "wrong-architecture",
        },
        {
            .profile_id = "",
            .machine = "chiappa",
            .device_tree_model = "",
            .device_tree_compatible = "",
            .architecture = "aarch64",
        },
        {
            .profile_id = "",
            .machine = "",
            .device_tree_model = "",
            .device_tree_compatible = "fsl,imx93",
            .architecture = "aarch64",
        },
        {
            .profile_id = "",
            .machine = "chiappa",
            .device_tree_model = "",
            .device_tree_compatible = "fsl,imx93",
            .architecture = "wrong-architecture",
        },
        {
            .profile_id = "",
            .machine = "remarkable 1.0 remarkable 2.0",
            .device_tree_model = "",
            .device_tree_compatible = "remarkable,zero-gravitas fsl,imx7d-sdb",
            .architecture = "armv7l",
        },
    }};

} // namespace pluto

#endif // PLUTO_GENERATED_DEVICE_PROFILES_H_
