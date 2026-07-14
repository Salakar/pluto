#include "sensors/iio.h"

#include <unistd.h>

#include <atomic>
#include <filesystem>
#include <fstream>
#include <string>

#include "gtest/gtest.h"

namespace {

namespace fs = std::filesystem;

struct TempDir {
  TempDir() {
    static std::atomic<int> counter{0};
    path = fs::temp_directory_path() /
           ("pluto_iio_" + std::to_string(::getpid()) + "_" +
            std::to_string(counter.fetch_add(1)));
    fs::create_directories(path);
  }
  ~TempDir() {
    std::error_code ec;
    fs::remove_all(path, ec);
  }
  void write(const char* leaf, const std::string& content) const {
    std::ofstream out(path / leaf, std::ios::binary | std::ios::trunc);
    out << content;
  }
  fs::path path;
};

TEST(Iio, ReadsAccelRawTimesScale) {
  TempDir dir;
  dir.write("in_accel_x_raw", "1000\n");
  dir.write("in_accel_y_raw", "-2000\n");
  dir.write("in_accel_z_raw", "16384\n");
  dir.write("in_accel_scale", "0.000598\n");

  const auto sample = pluto::read_iio_accel(dir.path.string());
  ASSERT_TRUE(sample.has_value());
  EXPECT_NEAR(sample->x, 0.598, 1e-9);
  EXPECT_NEAR(sample->y, -1.196, 1e-9);
  EXPECT_NEAR(sample->z, 9.797632, 1e-6);
}

TEST(Iio, MissingScaleFallsBackToRawCounts) {
  TempDir dir;
  dir.write("in_accel_x_raw", "5");
  dir.write("in_accel_y_raw", "6");
  dir.write("in_accel_z_raw", "7");

  const auto sample = pluto::read_iio_accel(dir.path.string());
  ASSERT_TRUE(sample.has_value());
  EXPECT_DOUBLE_EQ(sample->x, 5.0);
  EXPECT_DOUBLE_EQ(sample->z, 7.0);
}

TEST(Iio, MissingAxisIsAnError) {
  TempDir dir;
  dir.write("in_accel_x_raw", "5");
  EXPECT_FALSE(pluto::read_iio_accel(dir.path.string()).has_value());
}

TEST(Iio, OrientationClassifiesGravity) {
  using pluto::SensorOrientation;
  using pluto::orientation_from_accel;
  EXPECT_EQ(orientation_from_accel(0.0, -9.8, 0.5),
            SensorOrientation::kPortrait);
  EXPECT_EQ(orientation_from_accel(0.0, 9.8, 0.5),
            SensorOrientation::kPortraitUpsideDown);
  EXPECT_EQ(orientation_from_accel(9.8, 0.3, 0.5),
            SensorOrientation::kLandscapeLeft);
  EXPECT_EQ(orientation_from_accel(-9.8, 0.3, 0.5),
            SensorOrientation::kLandscapeRight);
  EXPECT_EQ(orientation_from_accel(0.2, 0.3, 9.8), SensorOrientation::kFlat);
  EXPECT_EQ(orientation_from_accel(0.0, 0.0, 0.0),
            SensorOrientation::kUnknown);
  EXPECT_STREQ(pluto::sensor_orientation_name(SensorOrientation::kPortrait),
               "portrait");
  EXPECT_STREQ(
      pluto::sensor_orientation_name(SensorOrientation::kLandscapeRight),
      "landscapeRight");
}

TEST(Iio, ParsesEventStruct) {
  uint8_t bytes[16] = {};
  // id = 0x0102030405060708 little-endian.
  for (int i = 0; i < 8; ++i) {
    bytes[i] = static_cast<uint8_t>(8 - i);
  }
  // timestamp = 1000000 ns.
  bytes[8] = 0x40;
  bytes[9] = 0x42;
  bytes[10] = 0x0f;

  const auto event = pluto::parse_iio_event(bytes, sizeof bytes);
  ASSERT_TRUE(event.has_value());
  EXPECT_EQ(event->id, 0x0102030405060708ull);
  EXPECT_EQ(event->timestamp_ns, 1000000);

  EXPECT_FALSE(pluto::parse_iio_event(bytes, 8).has_value());
  EXPECT_FALSE(pluto::parse_iio_event(nullptr, 16).has_value());
}

}  // namespace
