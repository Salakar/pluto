#include "channels/sensor_channels.h"

#include <unistd.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#include "gtest/gtest.h"

namespace {

namespace fs = std::filesystem;

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

// Collects events pushed through the EventSender; sensor worker threads are
// the producers, the test thread waits on the condition variable.
struct SensorHarness {
  SensorHarness() {
    static std::atomic<int> counter{0};
    root = fs::temp_directory_path() /
           ("pluto_sensor_channels_" + std::to_string(::getpid()) + "_" +
            std::to_string(counter.fetch_add(1)));
    fs::create_directories(root / "accel");
    paths.accel_dir = (root / "accel").string();
    paths.tap_device = (root / "tap_events.bin").string();
    paths.tap_events_dir.clear();
    paths.double_tap_device = (root / "double_tap_events.bin").string();
    paths.double_tap_events_dir.clear();
    paths.orientation_device = (root / "orient_events.bin").string();
    paths.orientation_events_dir.clear();
    paths.plain_event_stream = true;
    paths.accel_period_ms = 10;
  }

  ~SensorHarness() {
    service.reset();
    std::error_code ec;
    fs::remove_all(root, ec);
  }

  void write(const fs::path& path, const std::string& content) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out << content;
  }

  void write_accel(const char* x, const char* y, const char* z,
                   const char* scale) {
    write(root / "accel" / "in_accel_x_raw", x);
    write(root / "accel" / "in_accel_y_raw", y);
    write(root / "accel" / "in_accel_z_raw", z);
    write(root / "accel" / "in_accel_scale", scale);
  }

  void write_iio_events(const fs::path& path, int count) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    for (int i = 0; i < count; ++i) {
      uint8_t record[16] = {};
      record[0] = static_cast<uint8_t>(i + 1);   // id
      record[8] = static_cast<uint8_t>(i + 1);   // timestamp ns
      out.write(reinterpret_cast<const char*>(record), sizeof record);
    }
  }

  void start() {
    service = std::make_unique<pluto::SensorService>(paths);
    service->register_with(&registry);
    service->set_sender([this](const std::string& channel,
                               const std::vector<uint8_t>& message) {
      std::optional<pluto::StandardValue> value;
      if (!message.empty() && message[0] == 0) {
        value = pluto::StandardMethodCodec::decode_success_envelope(
            message.data(), message.size());
      }
      std::lock_guard<std::mutex> lock(mutex);
      events.emplace_back(channel,
                          value.value_or(pluto::StandardValue()),
                          !message.empty() && message[0] == 1);
      condition.notify_all();
    });
  }

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
    if (response.empty() || response[0] != 0) {
      return {response.empty() ? 255 : response[0], {}};
    }
    std::optional<pluto::StandardValue> value =
        pluto::StandardMethodCodec::decode_success_envelope(
            response.data(), response.size());
    return {response[0], value.value_or(pluto::StandardValue())};
  }

  // Waits until at least `count` events arrived on `channel`.
  bool wait_for_events(const std::string& channel, size_t count) {
    std::unique_lock<std::mutex> lock(mutex);
    return condition.wait_for(lock, std::chrono::seconds(5), [&] {
      size_t seen = 0;
      for (const auto& [name, value, is_error] : events) {
        if (name == channel) {
          ++seen;
        }
      }
      return seen >= count;
    });
  }

  std::vector<pluto::StandardValue> events_for(const std::string& channel) {
    std::lock_guard<std::mutex> lock(mutex);
    std::vector<pluto::StandardValue> result;
    for (const auto& [name, value, is_error] : events) {
      if (name == channel && !is_error) {
        result.push_back(value);
      }
    }
    return result;
  }

  fs::path root;
  pluto::SensorPaths paths;
  pluto::ChannelRegistry registry;
  std::unique_ptr<pluto::SensorService> service;
  std::mutex mutex;
  std::condition_variable condition;
  std::vector<std::tuple<std::string, pluto::StandardValue, bool>> events;
};

TEST(SensorChannels, CapabilitiesReflectAvailablePaths) {
  SensorHarness harness;
  harness.write_accel("0", "0", "16384", "0.000598");
  harness.write_iio_events(harness.paths.double_tap_device, 0);
  harness.start();

  const auto [status, value] = harness.invoke("pluto/sensors", "capabilities");
  EXPECT_EQ(status, 0);
  const pluto::StandardValue* accel = map_value(value, "accelerometer");
  ASSERT_NE(accel, nullptr);
  EXPECT_TRUE(accel->boolean() != nullptr && *accel->boolean());
  const pluto::StandardValue* double_tap = map_value(value, "doubleTap");
  ASSERT_NE(double_tap, nullptr);
  EXPECT_TRUE(double_tap->boolean() != nullptr && *double_tap->boolean());
  const pluto::StandardValue* tap = map_value(value, "tap");
  ASSERT_NE(tap, nullptr);
  EXPECT_TRUE(tap->boolean() != nullptr && !*tap->boolean());
}

TEST(SensorChannels, AccelerometerStreamsScaledReadings) {
  SensorHarness harness;
  harness.write_accel("1000", "-1000", "16384", "0.000598");
  harness.start();

  EXPECT_EQ(harness
                .invoke("pluto/sensors/accelerometer", "listen",
                        pluto::make_map({{"periodMs", int64_t{10}}}))
                .first,
            0);
  ASSERT_TRUE(harness.wait_for_events("pluto/sensors/accelerometer", 2));
  EXPECT_EQ(harness.invoke("pluto/sensors/accelerometer", "cancel").first, 0);

  const auto events = harness.events_for("pluto/sensors/accelerometer");
  ASSERT_GE(events.size(), 2u);
  const pluto::StandardValue* x = map_value(events[0], "x");
  ASSERT_NE(x, nullptr);
  const double* xv = std::get_if<double>(&x->storage());
  ASSERT_NE(xv, nullptr);
  EXPECT_NEAR(*xv, 0.598, 1e-9);
  ASSERT_NE(map_value(events[0], "tUs"), nullptr);
  ASSERT_NE(map_value(events[0], "z"), nullptr);
}

TEST(SensorChannels, DoubleTapStreamsIioEvents) {
  SensorHarness harness;
  harness.write_accel("0", "16384", "0", "0.000598");
  harness.write_iio_events(harness.paths.double_tap_device, 2);
  harness.start();

  EXPECT_EQ(harness.invoke("pluto/sensors/doubleTap", "listen").first, 0);
  ASSERT_TRUE(harness.wait_for_events("pluto/sensors/doubleTap", 2));
  EXPECT_EQ(harness.invoke("pluto/sensors/doubleTap", "cancel").first, 0);

  const auto events = harness.events_for("pluto/sensors/doubleTap");
  ASSERT_GE(events.size(), 2u);
  EXPECT_NE(map_value(events[0], "tUs"), nullptr);
  const pluto::StandardValue* id = map_value(events[0], "iioEventId");
  ASSERT_NE(id, nullptr);
  EXPECT_EQ(*id->integer(), 1);
}

TEST(SensorChannels, OrientationEmitsInitialStateAndPerEvent) {
  SensorHarness harness;
  harness.write_accel("0", "-16384", "0", "0.000598");  // Move portrait
  harness.write_iio_events(harness.paths.orientation_device, 1);
  harness.start();

  EXPECT_EQ(harness.invoke("pluto/sensors/orientation", "listen").first, 0);
  // Initial snapshot plus one IIO transition event.
  ASSERT_TRUE(harness.wait_for_events("pluto/sensors/orientation", 2));
  EXPECT_EQ(harness.invoke("pluto/sensors/orientation", "cancel").first, 0);

  const auto events = harness.events_for("pluto/sensors/orientation");
  ASSERT_GE(events.size(), 2u);
  const pluto::StandardValue* orientation =
      map_value(events[0], "orientation");
  ASSERT_NE(orientation, nullptr);
  ASSERT_NE(orientation->string(), nullptr);
  EXPECT_EQ(*orientation->string(), "portrait");
}

TEST(SensorChannels, MissingAccelerometerSurfacesStreamError) {
  SensorHarness harness;
  harness.start();

  EXPECT_EQ(harness.invoke("pluto/sensors/accelerometer", "listen").first, 0);
  std::unique_lock<std::mutex> lock(harness.mutex);
  ASSERT_TRUE(harness.condition.wait_for(lock, std::chrono::seconds(5), [&] {
    for (const auto& [name, value, is_error] : harness.events) {
      if (name == "pluto/sensors/accelerometer" && is_error) {
        return true;
      }
    }
    return false;
  }));
}

TEST(SensorChannels, OneShotReadsWork) {
  SensorHarness harness;
  harness.write_accel("0", "16384", "0", "0.000598");
  harness.start();

  const auto [status, value] =
      harness.invoke("pluto/sensors", "orientation");
  EXPECT_EQ(status, 0);
  const pluto::StandardValue* orientation = map_value(value, "orientation");
  ASSERT_NE(orientation, nullptr);
  EXPECT_EQ(*orientation->string(), "portraitUpsideDown");

  const auto [accel_status, accel] =
      harness.invoke("pluto/sensors", "accelerometerRead");
  EXPECT_EQ(accel_status, 0);
  EXPECT_NE(map_value(accel, "y"), nullptr);
}

}  // namespace
