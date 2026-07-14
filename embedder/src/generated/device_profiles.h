// GENERATED FILE. Edit config/device_profiles.json, then run
// dart tools/codegen/generate_device_profiles.dart.
#ifndef PLUTO_GENERATED_DEVICE_PROFILES_H_
#define PLUTO_GENERATED_DEVICE_PROFILES_H_

#include <array>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>

namespace pluto {

enum class DeviceTargetSlice { kLinuxArm, kLinuxArm64 };
enum class NativeDisplayDriverKind {
  kMxcfbEpdc,
  kLcdifTcon,
  kGallery3Drm,
};
enum class GeneratedBootConfirmationStrategy {
  kUbootEnv,
  kLpgprCounter,
};
enum class GeneratedBootFailureStrategy {
  kUbootEnvForceReboot,
  kUnverified,
};

struct GeneratedPanelProfile {
  int width;
  int height;
  int dpi;
  std::string_view signature;
  std::string_view source_pixel_format;
  bool color;
};

struct GeneratedInputDeviceProfile {
  std::string_view by_path;
  std::string_view name;
};

struct GeneratedDisplayContract {
  std::uint32_t scanout_width;
  std::uint32_t scanout_height;
  std::optional<std::uint32_t> virtual_width;
  std::optional<std::uint32_t> virtual_height;
  std::optional<std::uint32_t> stride_bytes;
  std::optional<std::uint64_t> mapping_bytes;
  std::uint32_t bits_per_pixel;
  std::optional<std::uint32_t> rotation;
  std::optional<std::uint32_t> buffer_slots;
  std::optional<std::uint32_t> slot_bytes;
  std::uint32_t damage_alignment_pixels;
  std::optional<std::uint64_t> phase_interval_nanoseconds;
};

struct GeneratedRecoveryContract {
  GeneratedBootConfirmationStrategy confirmation_strategy;
  GeneratedBootFailureStrategy failure_strategy;
  bool boot_default_enabled;
  std::string_view mmc_device;
  std::optional<std::array<std::uint32_t, 2>> root_partitions;
  std::optional<std::uint32_t> expected_boot_limit;
  std::string_view helper_path;
  std::string_view counter_directory;
};

struct GeneratedWaveformSourceProfile {
  std::string_view path;
  std::string_view sha256;
  std::string_view panel_signature;
};

struct GeneratedWaveformProfile {
  std::span<const std::string_view> discovery_paths;
  std::span<const GeneratedWaveformSourceProfile> accepted_sources;
};

struct GeneratedRuntimeProfile {
  bool native_session_enabled;
  std::string_view display_device;
  GeneratedDisplayContract display;
  GeneratedWaveformProfile waveform;
  std::optional<std::string_view> waveform_option_key;
  std::string_view presenter_options;
  GeneratedInputDeviceProfile pen;
  GeneratedInputDeviceProfile touch;
  GeneratedInputDeviceProfile power_key;
  std::string_view frontlight_brightness_path;
  std::string_view vpdd_timeout_path;
  std::string_view bezel_redraw_iio_path;
  std::string_view bezel_redraw_enable_path;
  GeneratedRecoveryContract recovery;
  std::string_view suspend_command;
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
  GeneratedRuntimeProfile runtime;
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

inline constexpr std::array<std::string_view, 1> kRm1WaveformDiscoveryPaths = {
    "/lib/firmware/imx/epdc/epdc_ES103CS1.fw",
};

inline constexpr std::array<GeneratedWaveformSourceProfile, 1> kRm1AcceptedWaveformSources = {{
    {
        .path = "/lib/firmware/imx/epdc/epdc_ES103CS1.fw",
        .sha256 = "185515bebf37d3e9d99ffa1f13a2804bbb2b64464fa6fc5067475fb6f65ff6b0",
        .panel_signature = "ES103CS1",
    },
}};

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

inline constexpr std::array<std::string_view, 2> kRm2WaveformDiscoveryPaths = {
    "/var/lib/uboot/320_R405_AFA011_ED103TC2C5_VB3300-KCD_TC.wbf",
    "/usr/share/remarkable/320_R467_AF4731_ED103TC2C6_VB3300-KCD_TC.wbf",
};

inline constexpr std::array<GeneratedWaveformSourceProfile, 1> kRm2AcceptedWaveformSources = {{
    {
        .path = "/var/lib/uboot/320_R405_AFA011_ED103TC2C5_VB3300-KCD_TC.wbf",
        .sha256 = "79783d751ba066af12c6ac5aca46279fe7c79d4ef834105bd46824f870f9c6f8",
        .panel_signature = "ED103TC2C5",
    },
}};

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

inline constexpr std::array<std::string_view, 1> kMoveWaveformDiscoveryPaths = {
    "/usr/share/remarkable/GAL3_AAB0AM_IC0801_AC073MC1F2_AD1004-GCA_TC.eink",
};

inline constexpr std::array<GeneratedWaveformSourceProfile, 1> kMoveAcceptedWaveformSources = {{
    {
        .path = "/usr/share/remarkable/GAL3_AAB0AM_IC0801_AC073MC1F2_AD1004-GCA_TC.eink",
        .sha256 = "80b8174773effceefbc16b54722cc0afd2187bd9a7c260a71bfbf92baeae8b67",
        .panel_signature = "AC073MC1F2",
    },
}};

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
                    .signature = "ES103CS1",
                    .source_pixel_format = "rgb565",
                    .color = false,
                },
            .runtime =
                {
                    .native_session_enabled = false,
                    .display_device = "/dev/fb0",
                    .display =
                        {
                            .scanout_width = 1404,
                            .scanout_height = 1872,
                            .virtual_width = 1408,
                            .virtual_height = 3840,
                            .stride_bytes = 2816,
                            .mapping_bytes = 10813440,
                            .bits_per_pixel = 16,
                            .rotation = 1,
                            .buffer_slots = std::nullopt,
                            .slot_bytes = std::nullopt,
                            .damage_alignment_pixels = 1,
                            .phase_interval_nanoseconds = std::nullopt,
                        },
                    .waveform =
                        {
                            .discovery_paths = kRm1WaveformDiscoveryPaths,
                            .accepted_sources = kRm1AcceptedWaveformSources,
                        },
                    .waveform_option_key = std::nullopt,
                    .presenter_options = "",
                    .pen =
                        {
                            .by_path = "/dev/input/by-path/platform-21a4000.i2c-event-mouse",
                            .name = "Wacom I2C Digitizer",
                        },
                    .touch =
                        {
                            .by_path = "/dev/input/by-path/platform-21a8000.i2c-event",
                            .name = "cyttsp5_mt",
                        },
                    .power_key =
                        {
                            .by_path = "/dev/input/by-path/platform-gpio-keys-event",
                            .name = "gpio-keys",
                        },
                    .frontlight_brightness_path = "",
                    .vpdd_timeout_path = "",
                    .bezel_redraw_iio_path = "",
                    .bezel_redraw_enable_path = "",
                    .recovery =
                        {
                            .confirmation_strategy = GeneratedBootConfirmationStrategy::kUbootEnv,
                            .failure_strategy = GeneratedBootFailureStrategy::kUbootEnvForceReboot,
                            .boot_default_enabled = true,
                            .mmc_device = "/dev/mmcblk1",
                            .root_partitions = std::array<std::uint32_t, 2>{2, 3},
                            .expected_boot_limit = 1,
                            .helper_path = "",
                            .counter_directory = "",
                        },
                    .suspend_command = "systemctl start --wait suspend.target",
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
                    .signature = "ED103TC2C5",
                    .source_pixel_format = "rgb565",
                    .color = false,
                },
            .runtime =
                {
                    .native_session_enabled = false,
                    .display_device = "/dev/fb0",
                    .display =
                        {
                            .scanout_width = 260,
                            .scanout_height = 1408,
                            .virtual_width = 260,
                            .virtual_height = 23936,
                            .stride_bytes = 1040,
                            .mapping_bytes = 33554432,
                            .bits_per_pixel = 32,
                            .rotation = 0,
                            .buffer_slots = 17,
                            .slot_bytes = 1464320,
                            .damage_alignment_pixels = 8,
                            .phase_interval_nanoseconds = 11763000,
                        },
                    .waveform =
                        {
                            .discovery_paths = kRm2WaveformDiscoveryPaths,
                            .accepted_sources = kRm2AcceptedWaveformSources,
                        },
                    .waveform_option_key = "wbf",
                    .presenter_options = "",
                    .pen =
                        {
                            .by_path = "/dev/input/by-path/platform-30a20000.i2c-event-mouse",
                            .name = "Wacom I2C Digitizer",
                        },
                    .touch =
                        {
                            .by_path = "/dev/input/by-path/platform-30a40000.i2c-event",
                            .name = "pt_mt",
                        },
                    .power_key =
                        {
                            .by_path = "/dev/input/by-path/platform-30370000.snvs:snvs-powerkey-event",
                            .name = "30370000.snvs:snvs-powerkey",
                        },
                    .frontlight_brightness_path = "",
                    .vpdd_timeout_path = "",
                    .bezel_redraw_iio_path = "",
                    .bezel_redraw_enable_path = "",
                    .recovery =
                        {
                            .confirmation_strategy = GeneratedBootConfirmationStrategy::kUbootEnv,
                            .failure_strategy = GeneratedBootFailureStrategy::kUbootEnvForceReboot,
                            .boot_default_enabled = true,
                            .mmc_device = "/dev/mmcblk2",
                            .root_partitions = std::array<std::uint32_t, 2>{2, 3},
                            .expected_boot_limit = 1,
                            .helper_path = "",
                            .counter_directory = "",
                        },
                    .suspend_command = "systemctl start --wait suspend.target",
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
                    .signature = "AC073MC1F2",
                    .source_pixel_format = "rgb565",
                    .color = true,
                },
            .runtime =
                {
                    .native_session_enabled = true,
                    .display_device = "/dev/dri/card0",
                    .display =
                        {
                            .scanout_width = 365,
                            .scanout_height = 1700,
                            .virtual_width = std::nullopt,
                            .virtual_height = std::nullopt,
                            .stride_bytes = std::nullopt,
                            .mapping_bytes = std::nullopt,
                            .bits_per_pixel = 16,
                            .rotation = std::nullopt,
                            .buffer_slots = 16,
                            .slot_bytes = 1241000,
                            .damage_alignment_pixels = 8,
                            .phase_interval_nanoseconds = 11764706,
                        },
                    .waveform =
                        {
                            .discovery_paths = kMoveWaveformDiscoveryPaths,
                            .accepted_sources = kMoveAcceptedWaveformSources,
                        },
                    .waveform_option_key = "eink",
                    .presenter_options = "exact_color=1,enable_rails=1,vcom=-0.62,du_mode=7,dither=1,settle_delay_ms=0,full_refresh_every=0",
                    .pen =
                        {
                            .by_path = "/dev/input/by-path/platform-44360000.spi-cs-0-event-mouse",
                            .name = "Elan marker input",
                        },
                    .touch =
                        {
                            .by_path = "/dev/input/by-path/platform-44360000.spi-cs-0-event",
                            .name = "Elan touch input",
                        },
                    .power_key =
                        {
                            .by_path = "/dev/input/by-path/platform-44440000.bbnsm:pwrkey-event",
                            .name = "44440000.bbnsm:pwrkey",
                        },
                    .frontlight_brightness_path = "/sys/class/backlight/rm_frontlight/brightness",
                    .vpdd_timeout_path = "/sys/bus/i2c/drivers/g2194-regulator/0-0048/vpdd_timeout_ms",
                    .bezel_redraw_iio_path = "/dev/iio:device3",
                    .bezel_redraw_enable_path = "/sys/bus/iio/devices/iio:device3/events/in_accel0_gesture_doubletap_en",
                    .recovery =
                        {
                            .confirmation_strategy = GeneratedBootConfirmationStrategy::kLpgprCounter,
                            .failure_strategy = GeneratedBootFailureStrategy::kUnverified,
                            .boot_default_enabled = false,
                            .mmc_device = "",
                            .root_partitions = std::nullopt,
                            .expected_boot_limit = std::nullopt,
                            .helper_path = "/usr/sbin/rm-reset-boot-count.sh",
                            .counter_directory = "/sys/devices/platform/lpgpr",
                        },
                    .suspend_command = "systemctl start --wait suspend.target",
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
