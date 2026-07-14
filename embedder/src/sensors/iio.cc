#include "sensors/iio.h"

#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace pluto {
namespace {

std::optional<std::string> read_trimmed(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    return std::nullopt;
  }
  std::ostringstream buffer;
  buffer << in.rdbuf();
  if (in.bad()) {
    return std::nullopt;
  }
  std::string text = buffer.str();
  size_t begin = 0;
  size_t end = text.size();
  while (begin < end && std::isspace(static_cast<unsigned char>(text[begin]))) {
    ++begin;
  }
  while (end > begin &&
         std::isspace(static_cast<unsigned char>(text[end - 1]))) {
    --end;
  }
  return text.substr(begin, end - begin);
}

std::optional<double> read_double(const std::string& path) {
  const std::optional<std::string> text = read_trimmed(path);
  if (!text.has_value() || text->empty()) {
    return std::nullopt;
  }
  char* end = nullptr;
  const double value = std::strtod(text->c_str(), &end);
  if (end == text->c_str()) {
    return std::nullopt;
  }
  return value;
}

std::string leaf(const std::string& dir, const char* name) {
  return (std::filesystem::path(dir) / name).string();
}

}  // namespace

std::optional<AccelSample> read_iio_accel(const std::string& sysfs_dir) {
  const std::optional<double> x = read_double(leaf(sysfs_dir, "in_accel_x_raw"));
  const std::optional<double> y = read_double(leaf(sysfs_dir, "in_accel_y_raw"));
  const std::optional<double> z = read_double(leaf(sysfs_dir, "in_accel_z_raw"));
  if (!x.has_value() || !y.has_value() || !z.has_value()) {
    return std::nullopt;
  }
  const double scale =
      read_double(leaf(sysfs_dir, "in_accel_scale")).value_or(1.0);
  return AccelSample{*x * scale, *y * scale, *z * scale};
}

const char* sensor_orientation_name(SensorOrientation orientation) {
  switch (orientation) {
    case SensorOrientation::kPortrait:
      return "portrait";
    case SensorOrientation::kPortraitUpsideDown:
      return "portraitUpsideDown";
    case SensorOrientation::kLandscapeLeft:
      return "landscapeLeft";
    case SensorOrientation::kLandscapeRight:
      return "landscapeRight";
    case SensorOrientation::kFlat:
      return "flat";
    case SensorOrientation::kUnknown:
      break;
  }
  return "unknown";
}

SensorOrientation orientation_from_accel(double x, double y, double z) {
  const double ax = std::fabs(x);
  const double ay = std::fabs(y);
  const double az = std::fabs(z);
  const double magnitude = std::sqrt(x * x + y * y + z * z);
  if (magnitude < 1e-6) {
    return SensorOrientation::kUnknown;
  }
  // Screen-normal gravity dominates: the device is lying flat.
  if (az > ax * 1.2 && az > ay * 1.2) {
    return SensorOrientation::kFlat;
  }
  if (ax >= ay) {
    return x > 0 ? SensorOrientation::kLandscapeLeft
                 : SensorOrientation::kLandscapeRight;
  }
  // The Move's LIS2DW12 is mounted with sensor -Y toward the panel's top
  // edge. Real upright-device samples are therefore strongly negative Y;
  // treating +Y as portrait starts every auto-rotated app upside down.
  return y < 0 ? SensorOrientation::kPortrait
               : SensorOrientation::kPortraitUpsideDown;
}

std::optional<IioEvent> parse_iio_event(const uint8_t* data, size_t size) {
  if (data == nullptr || size < kIioEventSize) {
    return std::nullopt;
  }
  IioEvent event;
  uint64_t id = 0;
  uint64_t ts = 0;
  for (size_t i = 0; i < 8; ++i) {
    id |= static_cast<uint64_t>(data[i]) << (8 * i);
    ts |= static_cast<uint64_t>(data[8 + i]) << (8 * i);
  }
  event.id = id;
  std::memcpy(&event.timestamp_ns, &ts, sizeof(ts));
  return event;
}

}  // namespace pluto
