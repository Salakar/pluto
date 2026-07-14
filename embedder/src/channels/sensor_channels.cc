#include "channels/sensor_channels.h"

#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <utility>
#include <vector>

#include "sensors/iio.h"

namespace pluto {
namespace {

namespace fs = std::filesystem;

std::string env_or(const char* name, const std::string& fallback) {
  const char* value = std::getenv(name);
  return value != nullptr && *value != '\0' ? std::string(value) : fallback;
}

int64_t now_us() {
  struct timespec mono {};
  clock_gettime(CLOCK_MONOTONIC, &mono);
  return static_cast<int64_t>(mono.tv_sec) * 1000000ll +
         mono.tv_nsec / 1000ll;
}

// Sleeps up to `total_ms`, waking early when `stop` is raised.
void interruptible_sleep(int32_t total_ms, const std::atomic<bool>& stop) {
  int32_t remaining = total_ms;
  while (remaining > 0 && !stop.load(std::memory_order_acquire)) {
    const int32_t slice = std::min<int32_t>(remaining, 20);
    timespec ts{slice / 1000, (slice % 1000) * 1000000};
    nanosleep(&ts, nullptr);
    remaining -= slice;
  }
}

// Arms every "*_en" toggle in an IIO events sysfs dir; best effort.
void enable_iio_events(const std::string& events_dir) {
  if (events_dir.empty()) {
    return;
  }
  std::error_code ec;
  fs::directory_iterator it(events_dir, ec);
  const fs::directory_iterator end;
  while (!ec && it != end) {
    const std::string name = it->path().filename().string();
    if (name.size() > 3 && name.rfind("_en") == name.size() - 3) {
      if (int fd = ::open(it->path().c_str(), O_WRONLY); fd >= 0) {
        (void)!::write(fd, "1\n", 2);
        ::close(fd);
      }
    }
    it.increment(ec);
  }
}

std::optional<int64_t> int_from_args(const StandardValue& args,
                                     const char* key) {
  const StandardValue::Map* map = args.map();
  if (map == nullptr) {
    return std::nullopt;
  }
  for (const auto& [k, v] : *map) {
    const std::string* name = k.string();
    if (name != nullptr && *name == key) {
      const int64_t* value = v.integer();
      if (value != nullptr) {
        return *value;
      }
    }
  }
  return std::nullopt;
}

bool path_exists(const std::string& path) {
  std::error_code ec;
  return !path.empty() && fs::exists(path, ec) && !ec;
}

StandardValue accel_event(int64_t ts_us, const AccelSample& sample) {
  return make_map({
      {"tUs", ts_us},
      {"x", sample.x},
      {"y", sample.y},
      {"z", sample.z},
  });
}

}  // namespace

SensorPaths sensor_paths_from_env() {
  SensorPaths paths;
  paths.accel_dir = env_or("PLUTO_IIO_ACCEL_DIR", paths.accel_dir);
  paths.tap_device = env_or("PLUTO_IIO_TAP_DEV", paths.tap_device);
  paths.tap_events_dir = env_or("PLUTO_IIO_TAP_EVENTS", paths.tap_events_dir);
  paths.double_tap_device =
      env_or("PLUTO_IIO_DOUBLETAP_DEV", paths.double_tap_device);
  paths.double_tap_events_dir =
      env_or("PLUTO_IIO_DOUBLETAP_EVENTS", paths.double_tap_events_dir);
  paths.orientation_device =
      env_or("PLUTO_IIO_ORIENT_DEV", paths.orientation_device);
  paths.orientation_events_dir =
      env_or("PLUTO_IIO_ORIENT_EVENTS", paths.orientation_events_dir);
  paths.plain_event_stream =
      std::getenv("PLUTO_IIO_EVENTS_PLAIN") != nullptr;
  const std::string period = env_or("PLUTO_ACCEL_PERIOD_MS", "");
  if (!period.empty()) {
    const long value = std::strtol(period.c_str(), nullptr, 10);
    if (value > 0) {
      paths.accel_period_ms = static_cast<int32_t>(value);
    }
  }
  return paths;
}

SensorService::SensorService(SensorPaths paths)
    : paths_(std::move(paths)),
      accelerometer_("pluto/sensors/accelerometer"),
      tap_("pluto/sensors/tap"),
      double_tap_("pluto/sensors/doubleTap"),
      orientation_("pluto/sensors/orientation") {
  accelerometer_.set_listen_handler(
      [this](const StandardValue& args) { start_accel(args); });
  accelerometer_.set_cancel_handler([this] { stop_worker(&accel_worker_); });
  tap_.set_listen_handler([this](const StandardValue&) {
    start_events(&tap_worker_, &tap_, paths_.tap_device, paths_.tap_events_dir,
                 false);
  });
  tap_.set_cancel_handler([this] { stop_worker(&tap_worker_); });
  double_tap_.set_listen_handler([this](const StandardValue&) {
    start_events(&double_tap_worker_, &double_tap_, paths_.double_tap_device,
                 paths_.double_tap_events_dir, false);
  });
  double_tap_.set_cancel_handler(
      [this] { stop_worker(&double_tap_worker_); });
  orientation_.set_listen_handler([this](const StandardValue&) {
    start_events(&orientation_worker_, &orientation_,
                 paths_.orientation_device, paths_.orientation_events_dir,
                 true);
  });
  orientation_.set_cancel_handler(
      [this] { stop_worker(&orientation_worker_); });
}

SensorService::~SensorService() {
  stop();
}

void SensorService::register_with(ChannelRegistry* registry) {
  registry->register_standard_method_channel(
      "pluto/sensors",
      [this](const MethodCall& call) { return handle_method(call); });
  accelerometer_.register_with(registry);
  tap_.register_with(registry);
  double_tap_.register_with(registry);
  orientation_.register_with(registry);
}

void SensorService::set_sender(const EventSender& sender) {
  accelerometer_.set_sender(sender);
  tap_.set_sender(sender);
  double_tap_.set_sender(sender);
  orientation_.set_sender(sender);
}

void SensorService::stop() {
  stop_worker(&accel_worker_);
  stop_worker(&tap_worker_);
  stop_worker(&double_tap_worker_);
  stop_worker(&orientation_worker_);
}

PlatformResponse SensorService::handle_method(const MethodCall& call) const {
  if (call.method == "capabilities") {
    return standard_success(make_map({
        {"accelerometer",
         path_exists((fs::path(paths_.accel_dir) / "in_accel_x_raw").string())},
        {"tap", path_exists(paths_.tap_device)},
        {"doubleTap", path_exists(paths_.double_tap_device)},
        {"orientation", path_exists(paths_.orientation_device)},
    }));
  }
  if (call.method == "accelerometerRead") {
    const std::optional<AccelSample> sample = read_iio_accel(paths_.accel_dir);
    if (!sample.has_value()) {
      return standard_error("unavailable", "Accelerometer sysfs is unreadable");
    }
    return standard_success(accel_event(now_us(), *sample));
  }
  if (call.method == "orientation") {
    return standard_success(current_orientation_event(now_us()));
  }
  return standard_unimplemented(call.method);
}

void SensorService::start_accel(const StandardValue& args) {
  stop_worker(&accel_worker_);
  int32_t period_ms = paths_.accel_period_ms;
  const std::optional<int64_t> requested = int_from_args(args, "periodMs");
  if (requested.has_value()) {
    period_ms = static_cast<int32_t>(std::clamp<int64_t>(*requested, 10, 2000));
  }
  accel_worker_.thread =
      std::thread(&SensorService::accel_loop, this, period_ms);
}

void SensorService::start_events(Worker* worker,
                                 EventStreamChannel* channel,
                                 std::string device,
                                 std::string events_dir,
                                 bool orientation_mode) {
  stop_worker(worker);
  worker->thread = std::thread(
      [this, worker, channel, device = std::move(device),
       events_dir = std::move(events_dir), orientation_mode] {
        event_loop(channel, device, events_dir, orientation_mode,
                   worker->stop);
      });
}

void SensorService::stop_worker(Worker* worker) {
  worker->stop.store(true, std::memory_order_release);
  if (worker->thread.joinable()) {
    worker->thread.join();
  }
  worker->thread = std::thread();
  worker->stop.store(false, std::memory_order_release);
}

void SensorService::accel_loop(int32_t period_ms) {
  const std::atomic<bool>& stop = accel_worker_.stop;
  while (!stop.load(std::memory_order_acquire)) {
    const std::optional<AccelSample> sample = read_iio_accel(paths_.accel_dir);
    if (!sample.has_value()) {
      accelerometer_.send_error("unavailable",
                                "Accelerometer sysfs is unreadable: " +
                                    paths_.accel_dir);
      return;
    }
    accelerometer_.send_event(accel_event(now_us(), *sample));
    interruptible_sleep(period_ms, stop);
  }
}

void SensorService::event_loop(EventStreamChannel* channel,
                               const std::string& device,
                               const std::string& events_dir,
                               bool orientation_mode,
                               const std::atomic<bool>& stop) {
  enable_iio_events(events_dir);

  int event_fd = -1;
  if (paths_.plain_event_stream) {
    event_fd = ::open(device.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK);
  } else {
    const int fd = ::open(device.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
      // IIO_GET_EVENT_FD_IOCTL = _IOR('i', 0x90, int)
      if (::ioctl(fd, _IOR('i', 0x90, int), &event_fd) < 0) {
        event_fd = -1;
      }
      ::close(fd);
    }
  }
  if (event_fd < 0) {
    channel->send_error("unavailable",
                        "IIO event device is unavailable: " + device);
    return;
  }

  if (orientation_mode) {
    channel->send_event(current_orientation_event(now_us()));
  }

  std::vector<uint8_t> pending;
  uint8_t buffer[kIioEventSize * 8];
  while (!stop.load(std::memory_order_acquire)) {
    pollfd pfd{event_fd, POLLIN, 0};
    const int pr = ::poll(&pfd, 1, 200);
    if (pr <= 0) {
      continue;
    }
    const ssize_t count = ::read(event_fd, buffer, sizeof buffer);
    if (count < 0) {
      if (errno == EAGAIN || errno == EINTR) {
        continue;
      }
      break;
    }
    if (count == 0) {
      // Plain-file mode: at EOF, wait for the file to grow.
      interruptible_sleep(25, stop);
      continue;
    }
    pending.insert(pending.end(), buffer, buffer + count);
    size_t offset = 0;
    while (pending.size() - offset >= kIioEventSize) {
      const std::optional<IioEvent> event =
          parse_iio_event(pending.data() + offset, kIioEventSize);
      offset += kIioEventSize;
      if (!event.has_value()) {
        continue;
      }
      const int64_t ts_us = event->timestamp_ns != 0
                                ? event->timestamp_ns / 1000
                                : now_us();
      if (orientation_mode) {
        StandardValue payload = current_orientation_event(ts_us);
        channel->send_event(payload);
      } else {
        channel->send_event(make_map({
            {"tUs", ts_us},
            {"iioEventId", static_cast<int64_t>(event->id)},
        }));
      }
    }
    pending.erase(pending.begin(),
                  pending.begin() + static_cast<ptrdiff_t>(offset));
  }
  ::close(event_fd);
}

StandardValue SensorService::current_orientation_event(int64_t ts_us) const {
  SensorOrientation orientation = SensorOrientation::kUnknown;
  const std::optional<AccelSample> sample = read_iio_accel(paths_.accel_dir);
  if (sample.has_value()) {
    orientation = orientation_from_accel(sample->x, sample->y, sample->z);
  }
  return make_map({
      {"tUs", ts_us},
      {"orientation", sensor_orientation_name(orientation)},
  });
}

}  // namespace pluto
