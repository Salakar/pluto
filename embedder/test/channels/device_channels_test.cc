#include <unistd.h>

#include <atomic>
#include <filesystem>
#include <fstream>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "channels/service_channels.h"
#include "channels/standard_codec.h"
#include "gtest/gtest.h"

namespace {

namespace fs = std::filesystem;

FlutterPlatformMessage message_for(const char *channel,
                                   const std::vector<uint8_t> &payload) {
  FlutterPlatformMessage message{};
  message.struct_size = sizeof(message);
  message.channel = channel;
  message.message = payload.empty() ? nullptr : payload.data();
  message.message_size = payload.size();
  message.response_handle =
      reinterpret_cast<const FlutterPlatformMessageResponseHandle *>(1);
  return message;
}

const pluto::StandardValue *map_value(const pluto::StandardValue &value,
                                      const char *key) {
  const pluto::StandardValue::Map *map = value.map();
  if (map == nullptr) {
    return nullptr;
  }
  for (const auto &[k, v] : *map) {
    const std::string *name = k.string();
    if (name != nullptr && *name == key) {
      return &v;
    }
  }
  return nullptr;
}

void write_file(const fs::path &path, const std::string &content) {
  fs::create_directories(path.parent_path());
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  out << content;
}

struct DeviceHarness {
  explicit DeviceHarness(std::string model = "paperProMove",
                         std::string codename = "chiappa",
                         int32_t panel_width = 954, int32_t panel_height = 1696,
                         int32_t dpi = 264, bool is_color = true) {
    static std::atomic<int> counter{0};
    root = fs::temp_directory_path() /
           ("pluto_device_channels_" + std::to_string(::getpid()) + "_" +
            std::to_string(counter.fetch_add(1)));
    fs::create_directories(root);
    paths.run_dir = (root / "run").string();
    paths.apps_dir = (root / "apps").string();
    paths.data_dir = (root / "data").string();
    paths.config_dir = (root / "config").string();
    paths.power_supply_dir = (root / "power_supply").string();
    paths.wpa_control_dir = (root / "missing-wpa-control").string();
    paths.wifi_settings_file = (root / "csl.conf").string();
    paths.systemctl = (root / "missing-systemctl").string();
    paths.network_class_dir = (root / "network").string();
    paths.os_release_file = (root / "os-release").string();
    paths.serial_command = "echo RM-TEST-1234";
    paths.app_id = "dev.example.sensorlab";

    pluto::ChannelContext context;
    context.device_model = std::move(model);
    context.device_codename = std::move(codename);
    context.panel_width = panel_width;
    context.panel_height = panel_height;
    context.dpi = dpi;
    context.is_color = is_color;
    context.pixel_format = "rgb565";
    context.frontlight_brightness_path =
        (root / "backlight" / "brightness").string();
    context.vpdd_length_path = (root / "vpdd_length").string();
    registry.set_context(std::move(context));
    pluto::register_service_channels(&registry, paths);
  }

  ~DeviceHarness() {
    std::error_code ec;
    fs::remove_all(root, ec);
  }

  std::pair<uint8_t, pluto::StandardValue>
  invoke(const char *channel, const std::string &method,
         pluto::StandardValue arguments = {}) {
    const std::vector<uint8_t> payload =
        pluto::StandardMethodCodec::encode_method_call(
            pluto::MethodCall{method, std::move(arguments)});
    FlutterPlatformMessage message = message_for(channel, payload);
    std::vector<uint8_t> response;
    registry.handle_message(
        message,
        [&response](const pluto::PlatformResponse &data) { response = data; });
    if (response.empty()) {
      return {255, {}};
    }
    if (response[0] != 0) {
      return {response[0], {}};
    }
    std::optional<pluto::StandardValue> value =
        pluto::StandardMethodCodec::decode_success_envelope(response.data(),
                                                            response.size());
    return {response[0], value.value_or(pluto::StandardValue())};
  }

  fs::path root;
  pluto::ServicePaths paths;
  pluto::ChannelRegistry registry;
};

TEST(DeviceChannels, CoreCapabilitiesIncludeColorPanel) {
  DeviceHarness harness;
  const auto [status, value] = harness.invoke("pluto/core", "capabilities");
  EXPECT_EQ(status, 0);
  const pluto::StandardValue::List *list = value.list();
  ASSERT_NE(list, nullptr);
  bool has_color = false;
  bool has_frontlight = false;
  for (const pluto::StandardValue &entry : *list) {
    if (entry.string() != nullptr && *entry.string() == "colorPanel") {
      has_color = true;
    }
    if (entry.string() != nullptr && *entry.string() == "frontlight") {
      has_frontlight = true;
    }
  }
  EXPECT_TRUE(has_color);
  EXPECT_TRUE(has_frontlight);
}

TEST(DeviceChannels, DeviceInfoMatchesPackageContract) {
  DeviceHarness harness;
  write_file(harness.paths.os_release_file,
             "ID=remarkable\nBUILD_ID=\"3.22.0.99\"\nVERSION_ID=\"3.22\"\n");
  const auto [status, value] = harness.invoke("pluto/device", "deviceInfo");

  EXPECT_EQ(status, 0);
  EXPECT_EQ(*map_value(value, "model")->string(), "paperProMove");
  EXPECT_EQ(*map_value(value, "codename")->string(), "chiappa");
  EXPECT_EQ(*map_value(value, "firmwareBuild")->string(), "3.22.0.99");
  EXPECT_EQ(*map_value(value, "osVersion")->string(), "3.22");
  EXPECT_EQ(*map_value(value, "serialNumber")->string(), "RM-TEST-1234");
  const pluto::StandardValue *panel = map_value(value, "panel");
  ASSERT_NE(panel, nullptr);
  EXPECT_EQ(*map_value(*panel, "width")->integer(), 954);
  EXPECT_EQ(*map_value(*panel, "height")->integer(), 1696);
  EXPECT_EQ(*map_value(*panel, "dpi")->integer(), 264);
  EXPECT_EQ(*map_value(*panel, "pixelFormat")->string(), "rgb565");
  EXPECT_EQ(*map_value(*panel, "colorMode")->string(), "gallery3");
}

TEST(DeviceChannels, DeviceInfoUsesContextIdentityForEveryProfile) {
  struct Fixture {
    const char *model;
    const char *codename;
    int32_t width;
    int32_t height;
    int32_t dpi;
    bool is_color;
  };
  const Fixture fixtures[] = {
      {"remarkable1", "zero-gravitas", 1404, 1872, 226, false},
      {"remarkable2", "zero-sugar", 1404, 1872, 226, false},
      {"paperProMove", "chiappa", 954, 1696, 264, true},
  };

  for (const Fixture &fixture : fixtures) {
    DeviceHarness harness(fixture.model, fixture.codename, fixture.width,
                          fixture.height, fixture.dpi, fixture.is_color);
    const auto [device_status, device_value] =
        harness.invoke("pluto/device", "deviceInfo");
    ASSERT_EQ(device_status, 0) << fixture.model;
    EXPECT_EQ(*map_value(device_value, "model")->string(), fixture.model);
    EXPECT_EQ(*map_value(device_value, "codename")->string(), fixture.codename);
    const pluto::StandardValue *panel = map_value(device_value, "panel");
    ASSERT_NE(panel, nullptr);
    EXPECT_EQ(*map_value(*panel, "width")->integer(), fixture.width);
    EXPECT_EQ(*map_value(*panel, "height")->integer(), fixture.height);
    EXPECT_EQ(*map_value(*panel, "dpi")->integer(), fixture.dpi);
    EXPECT_EQ(*map_value(*panel, "colorMode")->string(),
              fixture.is_color ? "gallery3" : "monochrome");
  }
}

TEST(DeviceChannels, DeviceInfoRejectsUnsupportedIdentity) {
  DeviceHarness harness("unknown", "", 800, 600, 160, false);
  EXPECT_EQ(harness.invoke("pluto/device", "deviceInfo").first, 1);
  EXPECT_EQ(harness.invoke("pluto/device", "capabilities").first, 1);
}

TEST(DeviceChannels, DeviceCapabilitiesAreAList) {
  DeviceHarness harness;
  const auto [status, value] = harness.invoke("pluto/device", "capabilities");
  EXPECT_EQ(status, 0);
  ASSERT_NE(value.list(), nullptr);
  EXPECT_FALSE(value.list()->empty());
}

TEST(DeviceChannels, RejectsMethodsOutsideExactDevicePackageContract) {
  DeviceHarness harness;
  EXPECT_EQ(harness.invoke("pluto/device", "unsupportedMethod").first, 1);
}

TEST(DeviceChannels, PathsCreatesScopedAppDirectories) {
  DeviceHarness harness;
  const auto [status, value] = harness.invoke("pluto/paths", "getPaths");

  EXPECT_EQ(status, 0);
  EXPECT_EQ(*map_value(value, "appId")->string(), "dev.example.sensorlab");
  const std::string documents = *map_value(value, "documents")->string();
  const std::string cache = *map_value(value, "cache")->string();
  const std::string support = *map_value(value, "support")->string();
  EXPECT_TRUE(fs::is_directory(documents));
  EXPECT_TRUE(fs::is_directory(cache));
  EXPECT_TRUE(fs::is_directory(support));
  const fs::path expected_root =
      fs::path(harness.paths.data_dir) / "dev.example.sensorlab";
  EXPECT_EQ(fs::path(documents), expected_root / "documents");
}

} // namespace
