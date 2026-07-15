#include "presenter/native/rm2/mxs_lcdif_device.h"

#include <cerrno>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include <fcntl.h>
#include <gtest/gtest.h>
#include <sys/mman.h>

#include "presenter/native/rm2/rm2_scan_encoder.h"

namespace pluto::native::rm2 {
namespace {

const GeneratedDeviceProfile &rm2_profile() {
  return *generated_device_profile_by_id("rm2");
}

class FakeLcdifSyscalls final : public MxsLcdifSyscalls {
public:
  FakeLcdifSyscalls() : storage(32U * 1024U * 1024U) {
    std::memcpy(fixed.id, "mxs-lcdif", sizeof("mxs-lcdif"));
    fixed.smem_start = 0xa9d00000U;
    fixed.smem_len = static_cast<std::uint32_t>(storage.size());
    fixed.type = uapi::kFramebufferTypePackedPixels;
    fixed.visual = uapi::kFramebufferVisualTrueColor;
    fixed.ypanstep = 1;
    fixed.ywrapstep = 1;
    fixed.line_length = kRm2ScanoutStrideBytes;

    variable.xres = kRm2ScanoutWidth;
    variable.yres = kRm2ScanoutHeight;
    variable.xres_virtual = kRm2ScanoutWidth;
    variable.yres_virtual = kRm2ScanoutHeight * kRm2MappedSlots;
    variable.yoffset = 14 * kRm2ScanoutHeight;
    variable.bits_per_pixel = 32;
    variable.red = {.offset = 16, .length = 8, .msb_right = 0};
    variable.green = {.offset = 8, .length = 8, .msb_right = 0};
    variable.blue = {.offset = 0, .length = 8, .msb_right = 0};
    variable.pixclock = 28800;
    variable.left_margin = 1;
    variable.right_margin = 1;
    variable.upper_margin = 1;
    variable.lower_margin = 143;
    variable.hsync_len = 1;
    variable.vsync_len = 1;
  }

  int open(const char *path, int flags) override {
    open_path = path;
    open_flags = flags;
    ++open_count;
    if (open_error != 0) {
      errno = open_error;
      return -1;
    }
    return 71;
  }

  int ioctl(int, unsigned long request, void *argument) override {
    requests.push_back(request);
    if (request == failing_request) {
      errno = ioctl_error;
      return -1;
    }
    if (request == uapi::kGetFixedScreenInfo) {
      std::memcpy(argument, &fixed, sizeof(fixed));
      return 0;
    }
    if (request == uapi::kGetVariableScreenInfo) {
      std::memcpy(argument, &variable, sizeof(variable));
      return 0;
    }
    if (request == uapi::kPutVariableScreenInfo) {
      variable = *static_cast<uapi::FramebufferVariableInfoArm32 *>(argument);
      ++put_count;
      if (drift_after_put) {
        ++variable.pixclock;
      }
      return 0;
    }
    if (request == uapi::kBlank) {
      blank_values.push_back(reinterpret_cast<std::uintptr_t>(argument));
      return 0;
    }
    if (request == uapi::kPanDisplay) {
      panned_offsets.push_back(
          static_cast<uapi::FramebufferVariableInfoArm32 *>(argument)->yoffset);
      return pan_result;
    }
    errno = ENOTTY;
    return -1;
  }

  void *mmap(void *, std::size_t length, int protection, int flags, int,
             off_t offset) override {
    mmap_length = length;
    mmap_protection = protection;
    mmap_flags = flags;
    mmap_offset = offset;
    if (mmap_error != 0) {
      errno = mmap_error;
      return MAP_FAILED;
    }
    return storage.data();
  }

  int munmap(void *, std::size_t length) override {
    munmap_length = length;
    ++munmap_count;
    return 0;
  }
  int close(int) override {
    ++close_count;
    return 0;
  }

  uapi::FramebufferFixedInfoArm32 fixed{};
  uapi::FramebufferVariableInfoArm32 variable{};
  std::vector<std::byte> storage;
  std::vector<unsigned long> requests;
  std::vector<std::uintptr_t> blank_values;
  std::vector<std::uint32_t> panned_offsets;
  int open_error = 0;
  unsigned long failing_request = 0;
  int ioctl_error = EIO;
  int mmap_error = 0;
  int pan_result = 49;
  bool drift_after_put = false;
  std::string open_path;
  int open_flags = 0;
  int open_count = 0;
  int put_count = 0;
  std::size_t mmap_length = 0;
  int mmap_protection = 0;
  int mmap_flags = 0;
  off_t mmap_offset = -1;
  std::size_t munmap_length = 0;
  int munmap_count = 0;
  int close_count = 0;
};

TEST(MxsLcdifDevice, ProbeIsReadOnlyAndInitializationPinsTheIdleSlot) {
  FakeLcdifSyscalls fake;
  MxsLcdifDevice device(&fake);

  ASSERT_EQ(device.open(rm2_profile()), kPlutoStatusOk);
  EXPECT_EQ(fake.put_count, 0);
  EXPECT_TRUE(fake.blank_values.empty());
  EXPECT_EQ(fake.open_path, "/dev/fb0");
  EXPECT_NE(fake.open_flags & O_RDWR, 0);
  EXPECT_NE(fake.open_flags & O_CLOEXEC, 0);

  ASSERT_EQ(device.initialize(), kPlutoStatusOk);
  EXPECT_TRUE(device.is_initialized());
  EXPECT_TRUE(device.is_blanked());
  ASSERT_TRUE(!fake.blank_values.empty());
  EXPECT_EQ(fake.blank_values.front(), uapi::kBlankPowerdown);
  EXPECT_EQ(fake.put_count, 1);
  EXPECT_EQ(fake.variable.yoffset, kRm2IdleSlot * kRm2ScanoutHeight);
  EXPECT_EQ(fake.mmap_length, 32U * 1024U * 1024U);
  EXPECT_NE(fake.mmap_protection & PROT_READ, 0);
  EXPECT_NE(fake.mmap_protection & PROT_WRITE, 0);
  EXPECT_NE(fake.mmap_flags & MAP_SHARED, 0);
  EXPECT_EQ(device.slot(0).size(), kRm2SlotBytes);
  EXPECT_EQ(device.slot(kRm2IdleSlot).size(), kRm2SlotBytes);
  EXPECT_TRUE(device.slot(kRm2MappedSlots).empty());
}

TEST(MxsLcdifDevice, RequiresUnblankAndAcceptsPositivePanCompletion) {
  FakeLcdifSyscalls fake;
  MxsLcdifDevice device(&fake);
  ASSERT_EQ(device.open(rm2_profile()), kPlutoStatusOk);
  ASSERT_EQ(device.initialize(), kPlutoStatusOk);

  EXPECT_EQ(device.pan(3), kPlutoStatusAgain);
  ASSERT_EQ(device.unblank(3), kPlutoStatusOk);
  EXPECT_FALSE(device.is_blanked());
  ASSERT_EQ(device.pan(4), kPlutoStatusOk);
  ASSERT_TRUE(!fake.panned_offsets.empty());
  EXPECT_EQ(fake.panned_offsets.back(), 4U * kRm2ScanoutHeight);
}

TEST(MxsLcdifDevice, RejectsWrongDriverGeometryAndPostPutDrift) {
  FakeLcdifSyscalls wrong_driver;
  std::memset(wrong_driver.fixed.id, 0, sizeof(wrong_driver.fixed.id));
  std::memcpy(wrong_driver.fixed.id, "mxc_epdc_fb", sizeof("mxc_epdc_fb"));
  MxsLcdifDevice driver_device(&wrong_driver);
  EXPECT_EQ(driver_device.open(rm2_profile()), kPlutoStatusUnsupported);
  EXPECT_EQ(wrong_driver.close_count, 1);

  FakeLcdifSyscalls wrong_geometry;
  --wrong_geometry.variable.yres_virtual;
  MxsLcdifDevice geometry_device(&wrong_geometry);
  EXPECT_EQ(geometry_device.open(rm2_profile()), kPlutoStatusUnsupported);

  FakeLcdifSyscalls drift;
  MxsLcdifDevice drift_device(&drift);
  ASSERT_EQ(drift_device.open(rm2_profile()), kPlutoStatusOk);
  drift.drift_after_put = true;
  EXPECT_EQ(drift_device.initialize(), kPlutoStatusUnsupported);
  EXPECT_FALSE(drift_device.is_open());
  ASSERT_TRUE(!drift.blank_values.empty());
  EXPECT_EQ(drift.blank_values.front(), uapi::kBlankPowerdown);
  EXPECT_EQ(drift.blank_values.back(), uapi::kBlankPowerdown);
}

TEST(MxsLcdifDevice, MapsIoctlAndMmapFailuresFailClosed) {
  FakeLcdifSyscalls missing;
  missing.open_error = ENOENT;
  MxsLcdifDevice missing_device(&missing);
  EXPECT_EQ(missing_device.open(rm2_profile()), kPlutoStatusDeviceLost);

  FakeLcdifSyscalls mapping;
  MxsLcdifDevice mapping_device(&mapping);
  ASSERT_EQ(mapping_device.open(rm2_profile()), kPlutoStatusOk);
  mapping.mmap_error = ENOMEM;
  EXPECT_EQ(mapping_device.initialize(), kPlutoStatusInternal);
  EXPECT_FALSE(mapping_device.is_open());
}

} // namespace
} // namespace pluto::native::rm2
