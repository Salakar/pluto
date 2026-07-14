#ifndef PLUTO_CHANNELS_SENSOR_CHANNELS_H_
#define PLUTO_CHANNELS_SENSOR_CHANNELS_H_

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>

#include "channels/channel_registry.h"
#include "channels/event_channel.h"

namespace pluto {

// IIO endpoints backing the pluto/sensors channels. Every entry is
// overridable through an environment variable so host tests can point the
// service at temp files.
struct SensorPaths {
  // PLUTO_IIO_ACCEL_DIR: sysfs dir with in_accel_{x,y,z}_raw and
  // in_accel_scale (LIS2DW12).
  std::string accel_dir = "/sys/bus/iio/devices/iio:device1";
  // PLUTO_IIO_TAP_DEV / PLUTO_IIO_TAP_EVENTS: single-tap gesture device.
  std::string tap_device = "/dev/iio:device4";
  std::string tap_events_dir = "/sys/bus/iio/devices/iio:device4/events";
  // PLUTO_IIO_DOUBLETAP_DEV / PLUTO_IIO_DOUBLETAP_EVENTS.
  std::string double_tap_device = "/dev/iio:device3";
  std::string double_tap_events_dir =
      "/sys/bus/iio/devices/iio:device3/events";
  // PLUTO_IIO_ORIENT_DEV / PLUTO_IIO_ORIENT_EVENTS: portrait/landscape
  // transition events.
  std::string orientation_device = "/dev/iio:device6";
  std::string orientation_events_dir =
      "/sys/bus/iio/devices/iio:device6/events";
  // PLUTO_IIO_EVENTS_PLAIN: read iio_event_data structs straight from the
  // device path instead of the IIO_GET_EVENT_FD ioctl (host tests use FIFOs
  // or regular files).
  bool plain_event_stream = false;
  // PLUTO_ACCEL_PERIOD_MS: default accelerometer poll period.
  int32_t accel_period_ms = 50;
};

SensorPaths sensor_paths_from_env();

// Registers the pluto/sensors method channel plus the four event-stream
// channels (accelerometer, tap, doubleTap, orientation). Worker threads run
// only while a Dart listener is attached; events are pushed through the
// EventSender, which must be thread-safe.
class SensorService {
 public:
  explicit SensorService(SensorPaths paths);
  ~SensorService();

  SensorService(const SensorService&) = delete;
  SensorService& operator=(const SensorService&) = delete;

  void register_with(ChannelRegistry* registry);
  void set_sender(const EventSender& sender);

  // Joins every worker thread. Call before engine teardown.
  void stop();

 private:
  struct Worker {
    std::thread thread;
    std::atomic<bool> stop{false};
  };

  PlatformResponse handle_method(const MethodCall& call) const;

  void start_accel(const StandardValue& args);
  void start_events(Worker* worker,
                    EventStreamChannel* channel,
                    std::string device,
                    std::string events_dir,
                    bool orientation_mode);
  void stop_worker(Worker* worker);

  void accel_loop(int32_t period_ms);
  void event_loop(EventStreamChannel* channel,
                  const std::string& device,
                  const std::string& events_dir,
                  bool orientation_mode,
                  const std::atomic<bool>& stop);

  StandardValue current_orientation_event(int64_t ts_us) const;

  const SensorPaths paths_;
  EventStreamChannel accelerometer_;
  EventStreamChannel tap_;
  EventStreamChannel double_tap_;
  EventStreamChannel orientation_;
  Worker accel_worker_;
  Worker tap_worker_;
  Worker double_tap_worker_;
  Worker orientation_worker_;
};

}  // namespace pluto

#endif  // PLUTO_CHANNELS_SENSOR_CHANNELS_H_
