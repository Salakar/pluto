#include "channels/service_channels.h"

#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "channels/standard_codec.h"
#include "channels/wpa_supplicant_client.h"
#include "gtest/gtest.h"

namespace {

namespace fs = std::filesystem;

std::string read_file_or_empty(const fs::path& path) {
  std::ifstream in(path, std::ios::binary);
  std::ostringstream buffer;
  buffer << in.rdbuf();
  return buffer.str();
}

void write_file(const fs::path& path, const std::string& content) {
  fs::create_directories(path.parent_path());
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  out << content;
}

FlutterPlatformMessage message_for(const char* channel,
                                   const std::vector<uint8_t>& payload) {
  FlutterPlatformMessage message{};
  message.struct_size = sizeof(message);
  message.channel = channel;
  message.message = payload.empty() ? nullptr : payload.data();
  message.message_size = payload.size();
  message.response_handle =
      reinterpret_cast<const FlutterPlatformMessageResponseHandle*>(1);
  return message;
}

pluto::StandardValue args_map(
    std::initializer_list<std::pair<pluto::StandardValue,
                                    pluto::StandardValue>> entries) {
  return pluto::make_map(entries);
}

const pluto::StandardValue* map_value(const pluto::StandardValue& value,
                                        const char* key) {
  const pluto::StandardValue::Map* map = value.map();
  if (map == nullptr) {
    return nullptr;
  }
  for (const auto& [k, v] : *map) {
    const std::string* name = k.string();
    if (name != nullptr && *name == key) {
      return &v;
    }
  }
  return nullptr;
}

class FakeWpaSupplicant {
 public:
  explicit FakeWpaSupplicant(const fs::path& control_directory) {
    fs::create_directories(control_directory);
    socket_path_ = control_directory / "wlan0";
    fd_ = ::socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd_ < 0) {
      throw std::runtime_error("Unable to create fake wpa_supplicant socket");
    }
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    const std::string path = socket_path_.string();
    if (path.size() >= sizeof(address.sun_path)) {
      ::close(fd_);
      throw std::runtime_error("Fake wpa_supplicant socket path is too long");
    }
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
#if defined(__APPLE__)
    address.sun_len = static_cast<unsigned char>(
        offsetof(sockaddr_un, sun_path) + path.size() + 1);
#endif
    ::unlink(path.c_str());
    if (::bind(fd_, reinterpret_cast<const sockaddr*>(&address),
               static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) +
                                      path.size() + 1)) != 0) {
      const std::string reason = std::strerror(errno);
      ::close(fd_);
      throw std::runtime_error("Unable to bind fake wpa_supplicant socket: " +
                               reason + " (" + path + ")");
    }
    thread_ = std::thread([this] { serve(); });
  }

  ~FakeWpaSupplicant() {
    running_.store(false);
    if (thread_.joinable()) {
      thread_.join();
    }
    if (fd_ >= 0) {
      ::close(fd_);
    }
    ::unlink(socket_path_.c_str());
    std::error_code ec;
    fs::remove(socket_path_.parent_path(), ec);
  }

  FakeWpaSupplicant(const FakeWpaSupplicant&) = delete;
  FakeWpaSupplicant& operator=(const FakeWpaSupplicant&) = delete;

  std::vector<std::string> commands() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return commands_;
  }

  void fail_command(std::string command) {
    std::lock_guard<std::mutex> lock(mutex_);
    failed_command_ = std::move(command);
  }

 private:
  std::string response_for(const std::string& command) {
    std::lock_guard<std::mutex> lock(mutex_);
    commands_.push_back(command);
    if (!failed_command_.empty() && command.rfind(failed_command_, 0) == 0) {
      return "FAIL\n";
    }
    if (command == "PING") {
      return "PONG\n";
    }
    if (command == "STATUS") {
      return "bssid=02:00:00:00:00:01\n"
             "ssid=HomeNet\n"
             "id=0\n"
             "wpa_state=COMPLETED\n"
             "ip_address=192.168.1.44\n";
    }
    if (command == "SIGNAL_POLL") {
      return "RSSI=-59\nLINKSPEED=72\n";
    }
    if (command == "SCAN") {
      // An already-running scan is still a successful scan trigger.
      return "FAIL-BUSY\n";
    }
    if (command == "SCAN_RESULTS") {
      return "bssid / frequency / signal level / flags / ssid\n"
             "02:00:00:00:00:01\t2412\t-59\t[WPA2-PSK-CCMP][ESS]\tHomeNet\n"
             "02:00:00:00:00:02\t2437\t-81\t[WPA2-PSK-CCMP][ESS]\tHomeNet\n"
             "02:00:00:00:00:03\t5180\t-75\t[ESS]\tCoffee\\x3aGuest\n";
    }
    if (command == "LIST_NETWORKS") {
      return "network id / ssid / bssid / flags\n"
             "0\tHomeNet\tany\t[CURRENT]\n";
    }
    if (command == "ADD_NETWORK") {
      return "1\n";
    }
    if (command == "LARGE") {
      return std::string(1536, 'x');
    }
    if (command == "GET_NETWORK 0 key_mgmt") {
      return "WPA-PSK\n";
    }
    if (command.rfind("SET_NETWORK ", 0) == 0 ||
        command.rfind("SELECT_NETWORK ", 0) == 0 ||
        command.rfind("ENABLE_NETWORK ", 0) == 0 ||
        command.rfind("REMOVE_NETWORK ", 0) == 0 || command == "SAVE_CONFIG" ||
        command == "RECONFIGURE" || command == "DISCONNECT") {
      return "OK\n";
    }
    return "FAIL\n";
  }

  void serve() {
    while (running_.load()) {
      pollfd descriptor{};
      descriptor.fd = fd_;
      descriptor.events = POLLIN;
      const int result = ::poll(&descriptor, 1, 20);
      if (result <= 0 || (descriptor.revents & POLLIN) == 0) {
        continue;
      }
      char buffer[8192];
      sockaddr_un peer{};
      socklen_t peer_length = sizeof(peer);
      const ssize_t received =
          ::recvfrom(fd_, buffer, sizeof(buffer), 0,
                     reinterpret_cast<sockaddr*>(&peer), &peer_length);
      if (received < 0) {
        continue;
      }
      const std::string response =
          response_for(std::string(buffer, static_cast<size_t>(received)));
      ::sendto(fd_, response.data(), response.size(), 0,
               reinterpret_cast<const sockaddr*>(&peer), peer_length);
    }
  }

  fs::path socket_path_;
  int fd_ = -1;
  std::atomic<bool> running_{true};
  std::thread thread_;
  mutable std::mutex mutex_;
  std::vector<std::string> commands_;
  std::string failed_command_;
};

// Registers the service channels against temp directories and tears them
// down on destruction. Plain struct: the gtest compatibility shim used on
// hosts without GoogleTest only supports TEST, not TEST_F.
struct ServiceHarness {
  ServiceHarness() {
    static std::atomic<int> counter{0};
    root = fs::temp_directory_path() /
           ("pluto_service_channels_" + std::to_string(::getpid()) + "_" +
            std::to_string(counter.fetch_add(1)));
    fs::create_directories(root);
    paths.run_dir = (root / "run").string();
    paths.apps_dir = (root / "apps").string();
    paths.data_dir = (root / "data").string();
    paths.config_dir = (root / "config").string();
    paths.backlight_dir = (root / "backlight").string();
    paths.vpdd_length_file = (root / "vpdd_length").string();
    paths.power_supply_dir = (root / "power_supply").string();
    paths.wpa_control_dir = (root / "missing-wpa-control").string();
    paths.wifi_settings_file = (root / "csl.conf").string();
    paths.systemctl = (root / "missing-systemctl").string();
    paths.network_class_dir = (root / "network").string();
    write_file(paths.vpdd_length_file, "30000\n");
    write_file(paths.wifi_settings_file, "wifi = on\n");

    pluto::ChannelContext context;
    context.presenter_name = "swtcon";
    context.request_shutdown = [this] { ++shutdown_requests; };
    context.system_ui_ready = [this] {
      ++system_ui_ready_requests;
      return true;
    };
    registry.set_context(std::move(context));
    pluto::register_service_channels(&registry, paths);
  }

  void install_fake_wpa_supplicant() {
    static std::atomic<int> counter{0};
    paths.wpa_control_dir =
        (fs::path("/tmp") /
         ("pluto_test_wpa_" + std::to_string(::getpid()) + "_" +
          std::to_string(counter.fetch_add(1))))
            .string();
    paths.systemctl = (root / "systemctl").string();
    write_file(paths.wifi_settings_file,
               "telemetry = off\n# preserve this comment\nwifi = on\n");
    write_file(paths.systemctl,
               "#!/bin/sh\n"
               "printf '%s\\n' \"$*\" >> '" +
                   (root / "systemctl.log").string() +
                   "'\n"
                   "exit 0\n");
    ::chmod(paths.systemctl.c_str(), 0755);
    fake_wpa = std::make_unique<FakeWpaSupplicant>(paths.wpa_control_dir);

    // Re-register after changing the copied path configuration.
    pluto::register_service_channels(&registry, paths);
  }

  void enable_hibernation() {
    pluto::ChannelContext context;
    context.presenter_name = "swtcon";
    context.request_shutdown = [this] { ++shutdown_requests; };
    context.request_hibernate = [this] { ++hibernate_requests; };
    registry.set_context(std::move(context));
  }

  ~ServiceHarness() {
    fake_wpa.reset();
    std::error_code ec;
    fs::remove_all(root, ec);
  }

  // Sends a standard method call and returns the envelope status byte
  // (0 success, 1 error) plus the decoded success value (null for errors:
  // error envelopes hold three concatenated values, not one).
  std::pair<uint8_t, pluto::StandardValue> invoke(
      const char* channel, const std::string& method,
      pluto::StandardValue arguments = {}) {
    const std::vector<uint8_t> payload =
        pluto::StandardMethodCodec::encode_method_call(
            pluto::MethodCall{method, std::move(arguments)});
    FlutterPlatformMessage message = message_for(channel, payload);
    std::vector<uint8_t> response;
    registry.handle_message(
        message,
        [&response](const pluto::PlatformResponse& data) { response = data; });
    if (response.empty()) {
      return {255, {}};
    }
    if (response[0] != 0) {
      return {response[0], {}};
    }
    std::optional<pluto::StandardValue> value =
        pluto::StandardMethodCodec::decode_success_envelope(
            response.data(), response.size());
    return {response[0], value.value_or(pluto::StandardValue())};
  }

  fs::path root;
  pluto::ServicePaths paths;
  pluto::ChannelRegistry registry;
  std::unique_ptr<FakeWpaSupplicant> fake_wpa;
  int shutdown_requests = 0;
  int hibernate_requests = 0;
  int system_ui_ready_requests = 0;
};

TEST(ServiceChannels, LaunchWritesControlFileAndRequestsShutdown) {
  ServiceHarness harness;
  const auto [status, value] =
      harness.invoke("pluto/session", "launch",
                     args_map({{"appId", "dev.example.counter"}}));

  EXPECT_EQ(status, 0);
  const pluto::StandardValue* ok = map_value(value, "ok");
  ASSERT_NE(ok, nullptr);
  EXPECT_TRUE(ok->boolean() != nullptr && *ok->boolean());
  EXPECT_EQ(read_file_or_empty(fs::path(harness.paths.run_dir) / "launch"),
            "dev.example.counter");
  EXPECT_EQ(harness.shutdown_requests, 1);
}

TEST(ServiceChannels, LaunchRejectsUnsafeAppIds) {
  ServiceHarness harness;
  const auto [status, value] = harness.invoke("pluto/session", "launch",
                                              args_map({{"appId", "../evil"}}));

  EXPECT_EQ(status, 1);
  EXPECT_FALSE(fs::exists(fs::path(harness.paths.run_dir) / "launch"));
  EXPECT_EQ(harness.shutdown_requests, 0);
}

TEST(ServiceChannels, ForceStopPublishesBackgroundRequestWithoutHandoff) {
  ServiceHarness harness;
  const auto [status, value] =
      harness.invoke("pluto/session", "forceStop",
                     args_map({{"appId", "dev.example.counter"}}));

  EXPECT_EQ(status, 0);
  const pluto::StandardValue* ok = map_value(value, "ok");
  ASSERT_NE(ok, nullptr);
  EXPECT_TRUE(ok->boolean() != nullptr && *ok->boolean());
  EXPECT_EQ(read_file_or_empty(fs::path(harness.paths.run_dir) / "force-stop"),
            "dev.example.counter\n");
  EXPECT_EQ(harness.hibernate_requests, 0);
  EXPECT_EQ(harness.shutdown_requests, 0);
}

TEST(ServiceChannels, ForceStopRejectsLauncherAndUnsafeIds) {
  ServiceHarness harness;
  EXPECT_EQ(harness
                .invoke("pluto/session", "forceStop",
                        args_map({{"appId", "dev.pluto.launcher"}}))
                .first,
            1);
  EXPECT_EQ(harness
                .invoke("pluto/session", "forceStop",
                        args_map({{"appId", "../bad"}}))
                .first,
            1);
  EXPECT_FALSE(fs::exists(fs::path(harness.paths.run_dir) / "force-stop"));
}

TEST(ServiceChannels, WarmHandoffsHibernateButStockStillShutsDown) {
  ServiceHarness harness;
  harness.enable_hibernation();
  write_file(fs::path(harness.paths.backlight_dir) / "brightness", "913\n");

  EXPECT_EQ(harness
                .invoke("pluto/session", "launch",
                        args_map({{"appId", "dev.example.counter"}}))
                .first,
            0);
  EXPECT_EQ(harness.invoke("pluto/session", "home").first, 0);
  EXPECT_EQ(harness.invoke("pluto/session", "sleepNow").first, 0);
  EXPECT_EQ(harness.hibernate_requests, 3);
  EXPECT_EQ(harness.shutdown_requests, 0);

  EXPECT_EQ(harness.invoke("pluto/session", "exitToStock").first, 0);
  EXPECT_EQ(harness.hibernate_requests, 3);
  EXPECT_EQ(harness.shutdown_requests, 1);
}

TEST(ServiceChannels, SwitcherInfoPreservesSupervisorRecencyOrder) {
  ServiceHarness harness;
  write_file(fs::path(harness.paths.run_dir) / "switcher-active",
             "dev.pluto.codex\n"
             "dev.pluto.launcher\n"
             "dev.pluto.validation_lab\n");

  const auto [status, value] =
      harness.invoke("pluto/session", "switcherInfo");
  EXPECT_EQ(status, 0);
  const pluto::StandardValue* active = map_value(value, "active");
  const pluto::StandardValue* origin = map_value(value, "originAppId");
  const pluto::StandardValue* apps = map_value(value, "apps");
  ASSERT_NE(active, nullptr);
  ASSERT_NE(origin, nullptr);
  ASSERT_NE(apps, nullptr);
  EXPECT_TRUE(active->boolean() != nullptr && *active->boolean());
  ASSERT_NE(origin->string(), nullptr);
  EXPECT_EQ(*origin->string(), "dev.pluto.codex");
  ASSERT_NE(apps->list(), nullptr);
  ASSERT_EQ(apps->list()->size(), 1u);
  const pluto::StandardValue* first_id =
      map_value((*apps->list())[0], "appId");
  ASSERT_NE(first_id, nullptr);
  EXPECT_EQ(*first_id->string(), "dev.pluto.validation_lab");
}

TEST(ServiceChannels, SystemUiReadyReleasesNativePresentationGate) {
  ServiceHarness harness;
  EXPECT_EQ(harness.invoke("pluto/session", "systemUiReady").first, 0);
  EXPECT_EQ(harness.system_ui_ready_requests, 1);
}

TEST(ServiceChannels, PowerMenuInfoReturnsSupervisorOrigin) {
  ServiceHarness harness;
  write_file(fs::path(harness.paths.run_dir) / "power-menu-active",
             "dev.example.paper\n");

  const auto [status, value] =
      harness.invoke("pluto/session", "powerMenuInfo");
  EXPECT_EQ(status, 0);
  const pluto::StandardValue* active = map_value(value, "active");
  const pluto::StandardValue* origin = map_value(value, "originAppId");
  ASSERT_NE(active, nullptr);
  ASSERT_NE(origin, nullptr);
  EXPECT_TRUE(active->boolean() != nullptr && *active->boolean());
  ASSERT_NE(origin->string(), nullptr);
  EXPECT_EQ(*origin->string(), "dev.example.paper");
}

TEST(ServiceChannels, StatusInfoReturnsOriginAndPreview) {
  ServiceHarness harness;
  write_file(fs::path(harness.paths.run_dir) / "status-active",
             "dev.example.paper\n");

  const auto [status, value] =
      harness.invoke("pluto/session", "statusInfo");
  EXPECT_EQ(status, 0);
  const pluto::StandardValue* active = map_value(value, "active");
  const pluto::StandardValue* origin = map_value(value, "originAppId");
  const pluto::StandardValue* preview = map_value(value, "previewPath");
  ASSERT_NE(active, nullptr);
  ASSERT_NE(origin, nullptr);
  ASSERT_NE(preview, nullptr);
  EXPECT_TRUE(active->boolean() != nullptr && *active->boolean());
  EXPECT_EQ(*origin->string(), "dev.example.paper");
  EXPECT_EQ(*preview->string(),
            (fs::path(harness.paths.run_dir) / "previews" /
             "dev.example.paper.bmp")
                .string());
}

TEST(ServiceChannels, HomeAndExitToStockTouchControlFiles) {
  ServiceHarness harness;
  EXPECT_EQ(harness.invoke("pluto/session", "home").first, 0);
  EXPECT_EQ(harness.invoke("pluto/session", "exitToStock").first, 0);

  EXPECT_TRUE(fs::exists(fs::path(harness.paths.run_dir) / "home"));
  EXPECT_TRUE(fs::exists(fs::path(harness.paths.run_dir) / "stock"));
  EXPECT_EQ(harness.shutdown_requests, 2);
}

TEST(ServiceChannels, PowerOffPublishesSupervisorRequestAndHibernates) {
  ServiceHarness harness;
  harness.enable_hibernation();
  harness.paths.app_id = "dev.pluto.launcher";
  write_file(fs::path(harness.paths.run_dir) / "power-menu-active",
             "dev.example.paper\n");
  pluto::register_service_channels(&harness.registry, harness.paths);

  const auto [status, value] = harness.invoke("pluto/session", "powerOff");
  EXPECT_EQ(status, 0);
  const pluto::StandardValue* ok = map_value(value, "ok");
  ASSERT_NE(ok, nullptr);
  EXPECT_TRUE(ok->boolean() != nullptr && *ok->boolean());
  EXPECT_EQ(read_file_or_empty(fs::path(harness.paths.run_dir) / "poweroff"),
            "ui\n");
  EXPECT_EQ(harness.hibernate_requests, 1);
  EXPECT_EQ(harness.shutdown_requests, 0);
}

TEST(ServiceChannels, PowerOffRejectsCallsOutsideActivePowerMenu) {
  ServiceHarness harness;
  harness.enable_hibernation();

  EXPECT_EQ(harness.invoke("pluto/session", "powerOff").first, 1);
  EXPECT_FALSE(fs::exists(fs::path(harness.paths.run_dir) / "poweroff"));
  EXPECT_EQ(harness.hibernate_requests, 0);
  EXPECT_EQ(harness.shutdown_requests, 0);
}

TEST(ServiceChannels, CancelLaunchRemovesControlFile) {
  ServiceHarness harness;
  harness.invoke("pluto/session", "launch",
                 args_map({{"appId", "dev.example.counter"}}));
  ASSERT_TRUE(fs::exists(fs::path(harness.paths.run_dir) / "launch"));

  EXPECT_EQ(harness
                .invoke("pluto/session", "cancelLaunch",
                        args_map({{"appId", "dev.example.counter"}}))
                .first,
            0);
  EXPECT_FALSE(fs::exists(fs::path(harness.paths.run_dir) / "launch"));
}

TEST(ServiceChannels, SleepNowRequestsStandbyAndShutdown) {
  ServiceHarness harness;
  write_file(fs::path(harness.paths.backlight_dir) / "brightness", "913\n");
  const auto [status, value] = harness.invoke("pluto/session", "sleepNow");

  EXPECT_EQ(status, 0);
  const pluto::StandardValue* ok = map_value(value, "ok");
  ASSERT_NE(ok, nullptr);
  EXPECT_TRUE(ok->boolean() != nullptr && *ok->boolean());
  EXPECT_EQ(read_file_or_empty(fs::path(harness.paths.run_dir) / "standby"),
            "launcher\n");
  EXPECT_EQ(read_file_or_empty(fs::path(harness.paths.run_dir) /
                               "standby-frontlight"),
            "913\n");
  EXPECT_EQ(harness.shutdown_requests, 1);
}

TEST(ServiceChannels, SleepNowRefusesToSuspendWithoutFrontlightSnapshot) {
  ServiceHarness harness;
  const auto [status, value] = harness.invoke("pluto/session", "sleepNow");

  (void)value;
  EXPECT_EQ(status, 1);
  EXPECT_FALSE(fs::exists(fs::path(harness.paths.run_dir) / "standby"));
  EXPECT_FALSE(
      fs::exists(fs::path(harness.paths.run_dir) / "standby-frontlight"));
  EXPECT_EQ(harness.shutdown_requests, 0);
}

TEST(ServiceChannels, SuspendNowWritesControlFileAndRequestsShutdown) {
  ServiceHarness harness;
  const auto [status, value] = harness.invoke("pluto/session", "suspendNow");

  EXPECT_EQ(status, 0);
  const pluto::StandardValue* ok = map_value(value, "ok");
  ASSERT_NE(ok, nullptr);
  EXPECT_TRUE(ok->boolean() != nullptr && *ok->boolean());
  EXPECT_EQ(read_file_or_empty(fs::path(harness.paths.run_dir) / "suspend"),
            "system\n");
  EXPECT_EQ(read_file_or_empty(harness.paths.vpdd_length_file), "0\n");
  EXPECT_EQ(harness.shutdown_requests, 1);
}

TEST(ServiceChannels, SuspendNowWriteFailureDoesNotRequestShutdown) {
  ServiceHarness harness;
  write_file(harness.paths.run_dir, "not a directory");

  EXPECT_EQ(harness.invoke("pluto/session", "suspendNow").first, 1);
  EXPECT_EQ(read_file_or_empty(harness.paths.vpdd_length_file), "30000\n");
  EXPECT_EQ(harness.shutdown_requests, 0);
}

TEST(ServiceChannels, SuspendNowRequiresReadableVpddLength) {
  ServiceHarness harness;
  fs::remove(harness.paths.vpdd_length_file);

  EXPECT_EQ(harness.invoke("pluto/session", "suspendNow").first, 1);
  EXPECT_FALSE(fs::exists(fs::path(harness.paths.run_dir) / "suspend"));
  EXPECT_EQ(harness.shutdown_requests, 0);
}

TEST(ServiceChannels, InfoReportsBackendFromPresenter) {
  ServiceHarness harness;
  const auto [status, value] = harness.invoke("pluto/session", "info");

  EXPECT_EQ(status, 0);
  const pluto::StandardValue* backend = map_value(value, "backendMode");
  ASSERT_NE(backend, nullptr);
  ASSERT_NE(backend->string(), nullptr);
  EXPECT_EQ(*backend->string(), "ownSwtcon");
}

TEST(ServiceChannels, FrontlightGetReadsSysfs) {
  ServiceHarness harness;
  write_file(fs::path(harness.paths.backlight_dir) / "brightness", "1600\n");
  write_file(fs::path(harness.paths.backlight_dir) / "max_brightness",
             "2047\n");

  const auto [status, value] =
      harness.invoke("pluto/settings", "frontlightGet");

  EXPECT_EQ(status, 0);
  const pluto::StandardValue* raw = map_value(value, "raw");
  const pluto::StandardValue* max = map_value(value, "max");
  ASSERT_NE(raw, nullptr);
  ASSERT_NE(max, nullptr);
  EXPECT_EQ(*raw->integer(), 1600);
  EXPECT_EQ(*max->integer(), 2047);
}

TEST(ServiceChannels, FrontlightSetClampsToRange) {
  ServiceHarness harness;
  write_file(fs::path(harness.paths.backlight_dir) / "brightness", "0\n");
  write_file(fs::path(harness.paths.backlight_dir) / "max_brightness",
             "2047\n");

  EXPECT_EQ(harness
                .invoke("pluto/settings", "frontlightSet",
                        args_map({{"raw", static_cast<int64_t>(99999)}}))
                .first,
            0);
  EXPECT_EQ(
      read_file_or_empty(fs::path(harness.paths.backlight_dir) / "brightness"),
      "2047");

  EXPECT_EQ(harness
                .invoke("pluto/settings", "frontlightSet",
                        args_map({{"raw", static_cast<int64_t>(-5)}}))
                .first,
            0);
  EXPECT_EQ(
      read_file_or_empty(fs::path(harness.paths.backlight_dir) / "brightness"),
      "0");
}

TEST(ServiceChannels, FrontlightGetIsUnavailableWithoutSysfs) {
  ServiceHarness harness;
  EXPECT_EQ(harness.invoke("pluto/settings", "frontlightGet").first, 1);
}

TEST(ServiceChannels, WifiFailsGracefullyWithoutSupplicant) {
  ServiceHarness harness;
  EXPECT_EQ(harness.invoke("pluto/settings", "wifiStatus").first, 1);
  EXPECT_EQ(harness.invoke("pluto/settings", "wifiScan").first, 1);
  EXPECT_EQ(harness.invoke("pluto/settings", "wifiScanResults").first, 1);
  EXPECT_EQ(harness
                .invoke("pluto/settings", "wifiConnect",
                        args_map({{"ssid", "HomeNet"}, {"psk", "hunter22"}}))
                .first,
            1);
}

TEST(ServiceChannels, WifiReportsFirmwareDisabledStateWithoutSupplicant) {
  ServiceHarness harness;
  write_file(harness.paths.wifi_settings_file,
             "telemetry = on\nwifi = off\n");

  const auto [status_code, status] =
      harness.invoke("pluto/settings", "wifiStatus");
  ASSERT_EQ(status_code, 0);
  EXPECT_EQ(*map_value(status, "status")->string(), "disabled");
}

TEST(ServiceChannels, WifiUsesSupplicantForStatusScanAndControls) {
  ServiceHarness harness;
  harness.install_fake_wpa_supplicant();

  const auto [status_code, status] =
      harness.invoke("pluto/settings", "wifiStatus");
  ASSERT_EQ(status_code, 0);
  EXPECT_EQ(*map_value(status, "status")->string(), "connected");
  EXPECT_EQ(*map_value(status, "ssid")->string(), "HomeNet");
  EXPECT_EQ(*map_value(status, "ipAddress")->string(), "192.168.1.44");

  EXPECT_EQ(harness.invoke("pluto/settings", "wifiScan").first, 0);
  const auto [scan_code, scan] =
      harness.invoke("pluto/settings", "wifiScanResults");
  ASSERT_EQ(scan_code, 0);
  const pluto::StandardValue::List* networks = scan.list();
  ASSERT_NE(networks, nullptr);
  ASSERT_EQ(networks->size(), 2u);
  EXPECT_EQ(*map_value((*networks)[0], "ssid")->string(), "HomeNet");
  EXPECT_EQ(std::get<double>(map_value((*networks)[0], "signal")->storage()),
            0.82);
  EXPECT_TRUE(*map_value((*networks)[0], "isKnown")->boolean());
  EXPECT_TRUE(*map_value((*networks)[0], "isActive")->boolean());
  EXPECT_EQ(*map_value((*networks)[1], "ssid")->string(), "Coffee:Guest");

  EXPECT_EQ(harness
                .invoke("pluto/settings", "wifiConnect",
                        args_map({{"ssid", "HomeNet"},
                                  {"psk", "correct \"horse\" staple"}}))
                .first,
            0);
  EXPECT_EQ(harness
                .invoke("pluto/settings", "wifiForget",
                        args_map({{"ssid", "HomeNet"}}))
                .first,
            0);
  EXPECT_EQ(harness
                .invoke("pluto/settings", "wifiSetEnabled",
                        args_map({{"enabled", false}}))
                .first,
            0);
  EXPECT_EQ(harness
                .invoke("pluto/settings", "wifiSetEnabled",
                        args_map({{"enabled", true}}))
                .first,
            0);

  std::ostringstream commands;
  for (const std::string& command : harness.fake_wpa->commands()) {
    commands << command << '\n';
  }
  EXPECT_NE(commands.str().find("SET_NETWORK 0 ssid 486f6d654e6574"),
            std::string::npos);
  EXPECT_NE(commands.str().find(
                "SET_NETWORK 0 psk \"correct \\\"horse\\\" staple\""),
            std::string::npos);
  EXPECT_NE(commands.str().find("SELECT_NETWORK 0"), std::string::npos);
  EXPECT_NE(commands.str().find("ENABLE_NETWORK all"), std::string::npos);
  EXPECT_NE(commands.str().find("REMOVE_NETWORK 0"), std::string::npos);
  EXPECT_NE(commands.str().find("SAVE_CONFIG"), std::string::npos);
  EXPECT_EQ(read_file_or_empty(harness.root / "systemctl.log"),
            "stop wpa_supplicant.service\nstart wpa_supplicant.service\n");
  EXPECT_EQ(read_file_or_empty(harness.paths.wifi_settings_file),
            "telemetry = off\n# preserve this comment\nwifi = on\n");
}

TEST(ServiceChannels, WifiRejectsBadPassphraseBeforeChangingSupplicant) {
  ServiceHarness harness;
  harness.install_fake_wpa_supplicant();
  const size_t before = harness.fake_wpa->commands().size();

  EXPECT_EQ(harness
                .invoke("pluto/settings", "wifiConnect",
                        args_map({{"ssid", "HomeNet"}, {"psk", "short"}}))
                .first,
            1);
  EXPECT_EQ(harness.fake_wpa->commands().size(), before);
}

TEST(ServiceChannels, WifiSupportsCanonicalPackageProtocol) {
  ServiceHarness harness;
  harness.install_fake_wpa_supplicant();

  const auto [enabled_code, enabled] =
      harness.invoke("pluto/settings", "wifi.isEnabled");
  ASSERT_EQ(enabled_code, 0);
  EXPECT_TRUE(*enabled.boolean());

  const auto [active_code, active] =
      harness.invoke("pluto/settings", "wifi.active");
  ASSERT_EQ(active_code, 0);
  EXPECT_EQ(*map_value(active, "ssid")->string(), "HomeNet");

  const auto [scan_code, scan] = harness.invoke(
      "pluto/settings", "wifi.scan",
      args_map({{"timeoutMs", static_cast<int64_t>(0)}}));
  ASSERT_EQ(scan_code, 0);
  ASSERT_NE(scan.list(), nullptr);
  EXPECT_EQ(scan.list()->size(), 2u);

  const auto [connect_code, connection] = harness.invoke(
      "pluto/settings", "wifi.connect",
      args_map({{"ssid", "HomeNet"},
                {"passphrase", "canonical-password"},
                {"timeoutMs", static_cast<int64_t>(0)}}));
  ASSERT_EQ(connect_code, 0);
  EXPECT_EQ(*map_value(connection, "ipAddress")->string(), "192.168.1.44");

  const auto [known_code, known] =
      harness.invoke("pluto/settings", "wifi.known");
  ASSERT_EQ(known_code, 0);
  ASSERT_NE(known.list(), nullptr);
  ASSERT_EQ(known.list()->size(), 1u);
  EXPECT_EQ(*map_value((*known.list())[0], "security")->string(), "wpaPsk");
  EXPECT_EQ(harness.invoke("pluto/settings", "wifi.disconnect").first, 0);
}

TEST(ServiceChannels, WifiRollsBackExistingProfileWhenCredentialsFail) {
  ServiceHarness harness;
  harness.install_fake_wpa_supplicant();
  harness.fake_wpa->fail_command("SET_NETWORK 0 psk");

  EXPECT_EQ(harness
                .invoke("pluto/settings", "wifiConnect",
                        args_map({{"ssid", "HomeNet"},
                                  {"psk", "bad-password"}}))
                .first,
            1);
  const std::vector<std::string> commands = harness.fake_wpa->commands();
  EXPECT_TRUE(std::find(commands.begin(), commands.end(), "RECONFIGURE") !=
              commands.end());
}

TEST(ServiceChannels, SupplicantClientReceivesLargeDatagram) {
  ServiceHarness harness;
  harness.install_fake_wpa_supplicant();
  const std::optional<std::string> response =
      pluto::WpaSupplicantClient(harness.paths.wpa_control_dir, "wlan0")
          .request("LARGE", std::chrono::milliseconds(200));
  ASSERT_TRUE(response.has_value());
  EXPECT_EQ(response->size(), 1536u);
}

TEST(ServiceChannels, UsbStatusUsesNetworkCarrierNotChargerPower) {
  ServiceHarness harness;
  harness.install_fake_wpa_supplicant();
  write_file(fs::path(harness.paths.network_class_dir) / "usb0" / "carrier",
             "0\n");
  write_file(fs::path(harness.paths.network_class_dir) / "usb0" / "operstate",
             "down\n");
  write_file(fs::path(harness.paths.network_class_dir) / "usb1" / "carrier",
             "1\n");
  write_file(fs::path(harness.paths.network_class_dir) / "usb1" / "operstate",
             "unknown\n");
  const fs::path battery =
      fs::path(harness.paths.power_supply_dir) / "battery";
  write_file(battery / "type", "Battery\n");
  write_file(battery / "capacity", "73\n");
  write_file(battery / "status", "Discharging\n");
  const fs::path charger =
      fs::path(harness.paths.power_supply_dir) / "charger";
  write_file(charger / "type", "USB\n");
  write_file(charger / "online", "0\n");
  const fs::path nfc_marker =
      fs::path(harness.paths.power_supply_dir) / "nfc-marker-battery";
  write_file(nfc_marker / "type", "Wireless\n");
  write_file(nfc_marker / "capacity", "0\n");
  const fs::path elants_marker =
      fs::path(harness.paths.power_supply_dir) / "elants-marker-battery";
  write_file(elants_marker / "type", "Wireless\n");
  write_file(elants_marker / "capacity", "81\n");

  const auto [battery_code, battery_value] =
      harness.invoke("pluto/settings", "batteryGet");
  ASSERT_EQ(battery_code, 0);
  EXPECT_FALSE(*map_value(battery_value, "isUsbPowerPresent")->boolean());
  EXPECT_TRUE(*map_value(battery_value, "isUsbNetworkConnected")->boolean());
  EXPECT_EQ(*map_value(battery_value, "markerLevelPercent")->integer(), 81);

  const auto [network_code, network] =
      harness.invoke("pluto/settings", "networkInfo");
  ASSERT_EQ(network_code, 0);
  EXPECT_TRUE(*map_value(network, "usbConnected")->boolean());
  EXPECT_EQ(*map_value(network, "usbInterface")->string(), "usb1");
  EXPECT_EQ(*map_value(network, "usbIp")->string(), "10.11.99.1");

  // Wall/charger power alone must not advertise a USB data link.
  write_file(fs::path(harness.paths.network_class_dir) / "usb1" / "carrier",
             "0\n");
  write_file(fs::path(harness.paths.network_class_dir) / "usb1" / "operstate",
             "up\n");
  write_file(charger / "online", "1\n");
  const pluto::StandardValue power_only =
      harness.invoke("pluto/settings", "batteryGet").second;
  EXPECT_TRUE(*map_value(power_only, "isUsbPowerPresent")->boolean());
  EXPECT_FALSE(*map_value(power_only, "isUsbNetworkConnected")->boolean());
  const pluto::StandardValue disconnected_network =
      harness.invoke("pluto/settings", "networkInfo").second;
  EXPECT_FALSE(*map_value(disconnected_network, "usbConnected")->boolean());
}

TEST(ServiceChannels, ZeroPercentMarkerBatteryRemainsPresent) {
  ServiceHarness harness;
  const fs::path battery =
      fs::path(harness.paths.power_supply_dir) / "battery";
  write_file(battery / "type", "Battery\n");
  write_file(battery / "capacity", "73\n");
  write_file(battery / "status", "Discharging\n");
  const fs::path marker =
      fs::path(harness.paths.power_supply_dir) / "nfc-marker-battery";
  write_file(marker / "type", "Wireless\n");
  write_file(marker / "capacity", "0\n");

  const auto [battery_code, battery_value] =
      harness.invoke("pluto/settings", "batteryGet");

  ASSERT_EQ(battery_code, 0);
  ASSERT_NE(map_value(battery_value, "markerLevelPercent"), nullptr);
  EXPECT_EQ(*map_value(battery_value, "markerLevelPercent")->integer(), 0);
}

TEST(ServiceChannels, PinRoundTrips) {
  ServiceHarness harness;
  const pluto::StandardValue unset =
      harness.invoke("pluto/settings", "pinIsSet").second;
  ASSERT_NE(unset.boolean(), nullptr);
  EXPECT_FALSE(*unset.boolean());

  EXPECT_EQ(harness
                .invoke("pluto/settings", "pinSet",
                        args_map({{"digits", "1234"}}))
                .first,
            0);
  EXPECT_TRUE(*harness.invoke("pluto/settings", "pinIsSet").second.boolean());

  EXPECT_EQ(harness
                .invoke("pluto/settings", "pinSet",
                        args_map({{"digits", "12ab"}}))
                .first,
            1);

  EXPECT_EQ(harness.invoke("pluto/settings", "pinRemove").first, 0);
  EXPECT_FALSE(
      *harness.invoke("pluto/settings", "pinIsSet").second.boolean());
}

TEST(ServiceChannels, StandbySetPersistsMilliseconds) {
  ServiceHarness harness;
  EXPECT_EQ(harness
                .invoke("pluto/settings", "standbySet",
                        args_map({{"ms", static_cast<int64_t>(600000)}}))
                .first,
            0);
  EXPECT_EQ(
      read_file_or_empty(fs::path(harness.paths.config_dir) / "standby_ms"),
      "600000");
}

TEST(ServiceChannels, RotationDefaultsToAutoAndRoundTrips) {
  ServiceHarness harness;
  const auto [default_status, default_value] =
      harness.invoke("pluto/settings", "rotationGet");
  ASSERT_EQ(default_status, 0);
  ASSERT_NE(default_value.string(), nullptr);
  EXPECT_EQ(*default_value.string(), "auto");

  EXPECT_EQ(harness
                .invoke("pluto/settings", "rotationSet",
                        args_map({{"value", "landscape"}}))
                .first,
            0);
  EXPECT_EQ(read_file_or_empty(fs::path(harness.paths.config_dir) / "rotation"),
            "landscape\n");
  const pluto::StandardValue stored =
      harness.invoke("pluto/settings", "rotationGet").second;
  ASSERT_NE(stored.string(), nullptr);
  EXPECT_EQ(*stored.string(), "landscape");

  EXPECT_EQ(harness
                .invoke("pluto/settings", "rotationSet",
                        args_map({{"value", "sideways"}}))
                .first,
            1);
  write_file(fs::path(harness.paths.config_dir) / "rotation", "corrupt\n");
  const pluto::StandardValue recovered =
      harness.invoke("pluto/settings", "rotationGet").second;
  ASSERT_NE(recovered.string(), nullptr);
  EXPECT_EQ(*recovered.string(), "auto");
}

TEST(ServiceChannels, AppsListReadsManifestsAndPinnedState) {
  ServiceHarness harness;
  write_file(fs::path(harness.paths.apps_dir) / "dev.example.counter" /
                 "manifest.json",
             "{\"id\":\"dev.example.counter\"}");
  write_file(fs::path(harness.paths.apps_dir) / "dev.example.broken" /
                 "bundle" / "kernel_blob.bin",
             "x");
  write_file(fs::path(harness.paths.config_dir) / "pinned",
             "dev.example.counter\n");

  const auto [status, value] = harness.invoke("pluto/apps", "list");

  EXPECT_EQ(status, 0);
  const pluto::StandardValue::List* apps = value.list();
  ASSERT_NE(apps, nullptr);
  ASSERT_EQ(apps->size(), 2u);

  const pluto::StandardValue& broken = (*apps)[0];
  EXPECT_EQ(*map_value(broken, "id")->string(), "dev.example.broken");
  EXPECT_TRUE(map_value(broken, "manifest")->is_null());
  EXPECT_FALSE(map_value(broken, "error")->is_null());
  EXPECT_FALSE(*map_value(broken, "isPinned")->boolean());

  const pluto::StandardValue& counter = (*apps)[1];
  EXPECT_EQ(*map_value(counter, "id")->string(), "dev.example.counter");
  EXPECT_EQ(*map_value(counter, "manifest")->string(),
            "{\"id\":\"dev.example.counter\"}");
  EXPECT_TRUE(map_value(counter, "error")->is_null());
  EXPECT_TRUE(*map_value(counter, "isPinned")->boolean());
  EXPECT_GT(*map_value(counter, "sizeBytes")->integer(), 0);
}

TEST(ServiceChannels, UninstallRemovesAppAndPinnedEntry) {
  ServiceHarness harness;
  write_file(fs::path(harness.paths.apps_dir) / "dev.example.counter" /
                 "manifest.json",
             "{}");
  write_file(fs::path(harness.paths.data_dir) / "dev.example.counter" /
                 "state.json",
             "{}");
  write_file(fs::path(harness.paths.config_dir) / "pinned",
             "dev.example.counter\n");

  EXPECT_EQ(harness
                .invoke("pluto/apps", "uninstall",
                        args_map({{"appId", "dev.example.counter"},
                                  {"deleteData", true}}))
                .first,
            0);

  EXPECT_FALSE(
      fs::exists(fs::path(harness.paths.apps_dir) / "dev.example.counter"));
  EXPECT_FALSE(
      fs::exists(fs::path(harness.paths.data_dir) / "dev.example.counter"));
  EXPECT_EQ(
      read_file_or_empty(fs::path(harness.paths.config_dir) / "pinned"), "");
}

TEST(ServiceChannels, UninstallRejectsPathTraversal) {
  ServiceHarness harness;
  EXPECT_EQ(harness
                .invoke("pluto/apps", "uninstall",
                        args_map({{"appId", "../../etc"}}))
                .first,
            1);
}

TEST(ServiceChannels, SetPinnedPersistsAcrossList) {
  ServiceHarness harness;
  write_file(fs::path(harness.paths.apps_dir) / "dev.example.counter" /
                 "manifest.json",
             "{}");

  EXPECT_EQ(harness
                .invoke("pluto/apps", "setPinned",
                        args_map({{"appId", "dev.example.counter"},
                                  {"isPinned", true}}))
                .first,
            0);
  const auto [status, value] = harness.invoke("pluto/apps", "list");
  ASSERT_EQ(status, 0);
  const pluto::StandardValue::List* apps = value.list();
  ASSERT_NE(apps, nullptr);
  ASSERT_EQ(apps->size(), 1u);
  EXPECT_TRUE(*map_value((*apps)[0], "isPinned")->boolean());

  EXPECT_EQ(harness
                .invoke("pluto/apps", "setPinned",
                        args_map({{"appId", "dev.example.counter"},
                                  {"isPinned", false}}))
                .first,
            0);
  const auto [status2, value2] = harness.invoke("pluto/apps", "list");
  ASSERT_EQ(status2, 0);
  const pluto::StandardValue::List* apps2 = value2.list();
  ASSERT_NE(apps2, nullptr);
  EXPECT_FALSE(*map_value((*apps2)[0], "isPinned")->boolean());
}

TEST(ServiceChannels, ClearAppDataRemovesDataDirOnly) {
  ServiceHarness harness;
  write_file(fs::path(harness.paths.apps_dir) / "dev.example.counter" /
                 "manifest.json",
             "{}");
  write_file(fs::path(harness.paths.data_dir) / "dev.example.counter" /
                 "state.json",
             "{}");

  EXPECT_EQ(harness
                .invoke("pluto/apps", "clearAppData",
                        args_map({{"appId", "dev.example.counter"}}))
                .first,
            0);

  EXPECT_FALSE(
      fs::exists(fs::path(harness.paths.data_dir) / "dev.example.counter"));
  EXPECT_TRUE(
      fs::exists(fs::path(harness.paths.apps_dir) / "dev.example.counter"));
}

TEST(ServiceChannels, UnknownMethodsReturnTypedErrors) {
  ServiceHarness harness;
  EXPECT_EQ(harness.invoke("pluto/session", "nope").first, 1);
  EXPECT_EQ(harness.invoke("pluto/settings", "nope").first, 1);
  EXPECT_EQ(harness.invoke("pluto/apps", "nope").first, 1);
}

}  // namespace
