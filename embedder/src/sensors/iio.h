#ifndef PLUTO_SENSORS_IIO_H_
#define PLUTO_SENSORS_IIO_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>

namespace pluto {

// One accelerometer reading in m/s^2 (raw counts scaled by in_accel_scale).
struct AccelSample {
  double x = 0.0;
  double y = 0.0;
  double z = 0.0;
};

// Reads in_accel_{x,y,z}_raw and in_accel_scale from an IIO sysfs device
// directory. Returns nullopt when any axis is unreadable. A missing scale
// file falls back to 1.0 (values stay in raw counts).
std::optional<AccelSample> read_iio_accel(const std::string& sysfs_dir);

// Coarse device posture derived from the gravity vector.
enum class SensorOrientation {
  kUnknown,
  kPortrait,
  kPortraitUpsideDown,
  kLandscapeLeft,
  kLandscapeRight,
  kFlat,
};

const char* sensor_orientation_name(SensorOrientation orientation);

// Classifies the gravity vector (any consistent unit). Assumes the
// Move accelerometer mounting: -y points toward the panel top edge, +x toward
// the panel right edge, and z out of the screen. The portrait sign is verified
// from a live upright Move sample; the classifier is unit-independent.
SensorOrientation orientation_from_accel(double x, double y, double z);

// struct iio_event_data from the kernel event fd: 8-byte id, 8-byte
// monotonic timestamp in nanoseconds, little-endian.
struct IioEvent {
  uint64_t id = 0;
  int64_t timestamp_ns = 0;
};

constexpr size_t kIioEventSize = 16;

std::optional<IioEvent> parse_iio_event(const uint8_t* data, size_t size);

}  // namespace pluto

#endif  // PLUTO_SENSORS_IIO_H_
