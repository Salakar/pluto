#include "presenter/native/mxcfb/mxcfb_device.h"

#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <vector>

#include <fcntl.h>
#include <gtest/gtest.h>
#include <sys/mman.h>

namespace {

using pluto::native::mxcfb::MxcfbDevice;
using pluto::native::mxcfb::MxcfbSyscalls;
namespace uapi = pluto::native::mxcfb::uapi;

constexpr std::uint32_t kRm1Width = 1404;
constexpr std::uint32_t kRm1Height = 1872;
constexpr std::uint32_t kRm1VirtualWidth = 1408;
constexpr std::uint32_t kRm1VirtualHeight = 3840;
constexpr std::uint32_t kRm1Stride = kRm1VirtualWidth * 2;
constexpr std::uint32_t kRm1MappingBytes = kRm1Stride * kRm1VirtualHeight;

const pluto::GeneratedDeviceProfile &rm1_profile() {
  return *pluto::generated_device_profile_by_id("rm1");
}

class FakeMxcfbSyscalls final : public MxcfbSyscalls {
public:
  FakeMxcfbSyscalls() : mapped_storage(kRm1MappingBytes) {
    std::memcpy(fixed.id, "mxc_epdc_fb", sizeof("mxc_epdc_fb"));
    fixed.smem_len = kRm1MappingBytes;
    fixed.type = uapi::kFramebufferTypePackedPixels;
    fixed.visual = uapi::kFramebufferVisualTrueColor;
    fixed.line_length = kRm1Stride;

    variable.xres = kRm1Width;
    variable.yres = kRm1Height;
    variable.xres_virtual = kRm1VirtualWidth;
    variable.yres_virtual = kRm1VirtualHeight;
    variable.bits_per_pixel = 16;
    variable.rotate = uapi::kFramebufferRotateClockwise;
    variable.red = {.offset = 11, .length = 5, .msb_right = 0};
    variable.green = {.offset = 5, .length = 6, .msb_right = 0};
    variable.blue = {.offset = 0, .length = 5, .msb_right = 0};
    variable.transp = {.offset = 0, .length = 0, .msb_right = 0};
  }

  int open(const char *path, int flags) override {
    calls.emplace_back("open");
    open_path = path;
    open_flags = flags;
    if (open_error != 0) {
      errno = open_error;
      return -1;
    }
    ++open_count;
    return framebuffer_fd;
  }

  int ioctl(int fd, unsigned long request, void *argument) override {
    calls.emplace_back("ioctl");
    last_ioctl_fd = fd;
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
    if (request == uapi::kSendUpdate) {
      sent_update = *static_cast<uapi::UpdateData *>(argument);
      ++send_count;
      return 0;
    }
    if (request == uapi::kWaitForUpdateComplete) {
      auto *completion = static_cast<uapi::UpdateMarkerData *>(argument);
      waited_marker = completion->update_marker;
      if (return_different_marker) {
        ++completion->update_marker;
      }
      completion->collision_test = wait_collision ? 1U : 0U;
      ++wait_count;
      return 0;
    }
    errno = ENOTTY;
    return -1;
  }

  void *mmap(void *address, std::size_t length, int protection, int flags,
             int fd, off_t offset) override {
    calls.emplace_back("mmap");
    mmap_address = address;
    mmap_length = length;
    mmap_protection = protection;
    mmap_flags = flags;
    mmap_fd = fd;
    mmap_offset = offset;
    if (mmap_error != 0) {
      errno = mmap_error;
      return MAP_FAILED;
    }
    ++mmap_count;
    return mapped_storage.data();
  }

  int munmap(void *address, std::size_t length) override {
    calls.emplace_back("munmap");
    munmap_address = address;
    munmap_length = length;
    ++munmap_count;
    return 0;
  }

  int close(int fd) override {
    calls.emplace_back("close");
    closed_fd = fd;
    ++close_count;
    return 0;
  }

  static constexpr int framebuffer_fd = 47;

  uapi::FramebufferFixedInfoArm32 fixed{};
  uapi::FramebufferVariableInfoArm32 variable{};
  std::vector<std::byte> mapped_storage;
  std::vector<std::string> calls;

  int open_error = 0;
  unsigned long failing_request = 0;
  int ioctl_error = EIO;
  int mmap_error = 0;
  bool wait_collision = false;
  bool return_different_marker = false;

  std::string open_path;
  int open_flags = 0;
  int open_count = 0;
  int last_ioctl_fd = -1;
  int send_count = 0;
  int wait_count = 0;
  uapi::UpdateData sent_update{};
  std::uint32_t waited_marker = 0;
  void *mmap_address = nullptr;
  std::size_t mmap_length = 0;
  int mmap_protection = 0;
  int mmap_flags = 0;
  int mmap_fd = -1;
  off_t mmap_offset = -1;
  int mmap_count = 0;
  void *munmap_address = nullptr;
  std::size_t munmap_length = 0;
  int munmap_count = 0;
  int closed_fd = -1;
  int close_count = 0;
};

uapi::UpdateData valid_update(std::uint32_t marker = 73) {
  return {
      .update_region = {.top = 20, .left = 10, .width = 30, .height = 40},
      .waveform_mode = uapi::kWaveformModeAuto,
      .update_mode = uapi::kUpdateModePartial,
      .update_marker = marker,
      .temperature = uapi::kTemperatureUseAmbient,
      .flags = 0,
      .dither_mode = 0,
      .quantization_bits = 0,
      .alternate_buffer = {},
  };
}

} // namespace

TEST(MxcfbUapi, PinsArm32StructureAndIoctlNumbers) {
  EXPECT_EQ(sizeof(uapi::FramebufferFixedInfoArm32), 68U);
  EXPECT_EQ(sizeof(uapi::FramebufferVariableInfoArm32), 160U);
  EXPECT_EQ(sizeof(uapi::UpdateData), 72U);
  EXPECT_EQ(sizeof(uapi::UpdateMarkerData), 8U);
  EXPECT_EQ(uapi::kSendUpdate, 0x4048462eUL);
  EXPECT_EQ(uapi::kWaitForUpdateComplete, 0xc008462fUL);
}

TEST(MxcfbDevice, OpensValidatesAndMapsTheWholeFramebufferCloexec) {
  FakeMxcfbSyscalls fake;
  MxcfbDevice device(&fake);

  ASSERT_EQ(device.open(rm1_profile()), kPlutoStatusOk);
  EXPECT_TRUE(device.is_open());
  EXPECT_EQ(fake.open_path, "/dev/fb0");
  EXPECT_NE(fake.open_flags & O_CLOEXEC, 0);
  EXPECT_NE(fake.open_flags & O_RDWR, 0);
  EXPECT_EQ(fake.last_ioctl_fd, FakeMxcfbSyscalls::framebuffer_fd);
  EXPECT_EQ(fake.mmap_length, kRm1MappingBytes);
  EXPECT_NE(fake.mmap_protection & PROT_READ, 0);
  EXPECT_NE(fake.mmap_protection & PROT_WRITE, 0);
  EXPECT_NE(fake.mmap_flags & MAP_SHARED, 0);
  EXPECT_EQ(fake.mmap_offset, 0);
  EXPECT_EQ(device.framebuffer().data(), fake.mapped_storage.data());
  EXPECT_EQ(device.framebuffer().size(), kRm1MappingBytes);
  EXPECT_EQ(device.framebuffer_info().width, kRm1Width);
  EXPECT_EQ(device.framebuffer_info().height, kRm1Height);
  EXPECT_EQ(device.framebuffer_info().virtual_width, kRm1VirtualWidth);
  EXPECT_EQ(device.framebuffer_info().virtual_height, kRm1VirtualHeight);
  EXPECT_EQ(device.framebuffer_info().stride_bytes, kRm1Stride);
}

TEST(MxcfbDevice, RejectsAProfileForAnotherDisplayDriverBeforeOpen) {
  FakeMxcfbSyscalls fake;
  MxcfbDevice device(&fake);
  const auto *move = pluto::generated_device_profile_by_id("move");
  ASSERT_NE(move, nullptr);

  EXPECT_EQ(device.open(*move), kPlutoStatusUnsupported);
  EXPECT_EQ(fake.open_count, 0);
  EXPECT_FALSE(device.is_open());
}

TEST(MxcfbDevice, RejectsIncompleteGeneratedDisplayContractBeforeOpen) {
  FakeMxcfbSyscalls fake;
  pluto::GeneratedDeviceProfile incomplete = rm1_profile();
  incomplete.runtime.display.virtual_width = std::nullopt;
  MxcfbDevice device(&fake);

  EXPECT_EQ(device.open(incomplete), kPlutoStatusUnsupported);
  EXPECT_EQ(fake.open_count, 0);
  EXPECT_FALSE(device.is_open());
}

TEST(MxcfbDevice, ReportsMissingFramebufferAsDeviceLost) {
  FakeMxcfbSyscalls fake;
  fake.open_error = ENOENT;
  MxcfbDevice device(&fake);

  EXPECT_EQ(device.open(rm1_profile()), kPlutoStatusDeviceLost);
  EXPECT_EQ(fake.close_count, 0);
  EXPECT_FALSE(device.is_open());
}

TEST(MxcfbDevice, RejectsWrongFramebufferDriverAndClosesDescriptor) {
  FakeMxcfbSyscalls fake;
  std::memset(fake.fixed.id, 0, sizeof(fake.fixed.id));
  std::memcpy(fake.fixed.id, "mxs-lcdif", sizeof("mxs-lcdif"));
  MxcfbDevice device(&fake);

  EXPECT_EQ(device.open(rm1_profile()), kPlutoStatusUnsupported);
  EXPECT_EQ(fake.close_count, 1);
  EXPECT_EQ(fake.mmap_count, 0);
  EXPECT_FALSE(device.is_open());
}

TEST(MxcfbDevice, RejectsWrongGeometry) {
  FakeMxcfbSyscalls fake;
  fake.variable.xres = kRm1Width - 1;
  MxcfbDevice device(&fake);

  EXPECT_EQ(device.open(rm1_profile()), kPlutoStatusUnsupported);
  EXPECT_EQ(fake.close_count, 1);
  EXPECT_EQ(fake.mmap_count, 0);
}

TEST(MxcfbDevice, RejectsWrongVirtualGeometry) {
  FakeMxcfbSyscalls fake;
  fake.variable.yres_virtual = kRm1VirtualHeight + 1;
  fake.fixed.smem_len = fake.fixed.line_length * fake.variable.yres_virtual;
  MxcfbDevice device(&fake);

  EXPECT_EQ(device.open(rm1_profile()), kPlutoStatusUnsupported);
  EXPECT_EQ(fake.close_count, 1);
  EXPECT_EQ(fake.mmap_count, 0);
}

TEST(MxcfbDevice, RejectsWrongStride) {
  FakeMxcfbSyscalls fake;
  fake.fixed.line_length -= 2;
  MxcfbDevice device(&fake);

  EXPECT_EQ(device.open(rm1_profile()), kPlutoStatusUnsupported);
  EXPECT_EQ(fake.close_count, 1);
  EXPECT_EQ(fake.mmap_count, 0);
}

TEST(MxcfbDevice, RejectsLargerThanPinnedFramebufferAllocation) {
  FakeMxcfbSyscalls fake;
  ++fake.fixed.smem_len;
  MxcfbDevice device(&fake);

  EXPECT_EQ(device.open(rm1_profile()), kPlutoStatusUnsupported);
  EXPECT_EQ(fake.close_count, 1);
  EXPECT_EQ(fake.mmap_count, 0);
}

TEST(MxcfbDevice, RejectsWrongRotation) {
  FakeMxcfbSyscalls fake;
  fake.variable.rotate = 0;
  MxcfbDevice device(&fake);

  EXPECT_EQ(device.open(rm1_profile()), kPlutoStatusUnsupported);
  EXPECT_EQ(fake.close_count, 1);
  EXPECT_EQ(fake.mmap_count, 0);
}

TEST(MxcfbDevice, ClosesDescriptorWhenFramebufferMappingFails) {
  FakeMxcfbSyscalls fake;
  fake.mmap_error = ENOMEM;
  MxcfbDevice device(&fake);

  EXPECT_EQ(device.open(rm1_profile()), kPlutoStatusInternal);
  EXPECT_EQ(fake.close_count, 1);
  EXPECT_EQ(fake.munmap_count, 0);
  EXPECT_FALSE(device.is_open());
  EXPECT_FALSE(device.last_error().empty());
}

TEST(MxcfbDevice, ClosesDescriptorWhenFixedInfoReadFails) {
  FakeMxcfbSyscalls fake;
  fake.failing_request = uapi::kGetFixedScreenInfo;
  fake.ioctl_error = ENODEV;
  MxcfbDevice device(&fake);

  EXPECT_EQ(device.open(rm1_profile()), kPlutoStatusDeviceLost);
  EXPECT_EQ(fake.close_count, 1);
  EXPECT_EQ(fake.mmap_count, 0);
}

TEST(MxcfbDevice, ClosesDescriptorWhenVariableInfoReadFails) {
  FakeMxcfbSyscalls fake;
  fake.failing_request = uapi::kGetVariableScreenInfo;
  fake.ioctl_error = EIO;
  MxcfbDevice device(&fake);

  EXPECT_EQ(device.open(rm1_profile()), kPlutoStatusDeviceLost);
  EXPECT_EQ(fake.close_count, 1);
  EXPECT_EQ(fake.mmap_count, 0);
}

TEST(MxcfbDevice, SendsUpdateAndWaitsForTheSameRealMarker) {
  FakeMxcfbSyscalls fake;
  fake.wait_collision = true;
  MxcfbDevice device(&fake);
  ASSERT_EQ(device.open(rm1_profile()), kPlutoStatusOk);
  uapi::UpdateData update = valid_update(991);

  EXPECT_EQ(device.send_update(&update), kPlutoStatusOk);
  EXPECT_EQ(fake.send_count, 1);
  EXPECT_EQ(fake.sent_update.update_marker, 991U);
  EXPECT_EQ(fake.sent_update.update_region.left, 10U);
  EXPECT_EQ(fake.sent_update.update_region.top, 20U);
  EXPECT_EQ(fake.sent_update.update_region.width, 30U);
  EXPECT_EQ(fake.sent_update.update_region.height, 40U);

  bool collision = false;
  EXPECT_EQ(device.wait_for_update_complete(991, &collision), kPlutoStatusOk);
  EXPECT_EQ(fake.wait_count, 1);
  EXPECT_EQ(fake.waited_marker, 991U);
  EXPECT_TRUE(collision);
}

TEST(MxcfbDevice, MapsKernelMarkerTimeoutAndClearsCollisionOutput) {
  FakeMxcfbSyscalls fake;
  MxcfbDevice device(&fake);
  ASSERT_EQ(device.open(rm1_profile()), kPlutoStatusOk);
  fake.failing_request = uapi::kWaitForUpdateComplete;
  fake.ioctl_error = ETIMEDOUT;
  bool collision = true;

  EXPECT_EQ(device.wait_for_update_complete(42, &collision),
            kPlutoStatusTimeout);
  EXPECT_FALSE(collision);
  EXPECT_FALSE(device.last_error().empty());
}

TEST(MxcfbDevice, MapsSendBackpressureAndWaitDeviceLoss) {
  FakeMxcfbSyscalls fake;
  MxcfbDevice device(&fake);
  ASSERT_EQ(device.open(rm1_profile()), kPlutoStatusOk);
  uapi::UpdateData update = valid_update();
  fake.failing_request = uapi::kSendUpdate;
  fake.ioctl_error = EBUSY;

  EXPECT_EQ(device.send_update(&update), kPlutoStatusAgain);

  fake.failing_request = uapi::kWaitForUpdateComplete;
  fake.ioctl_error = EIO;
  EXPECT_EQ(device.wait_for_update_complete(update.update_marker, nullptr),
            kPlutoStatusDeviceLost);
}

TEST(MxcfbDevice, RejectsInvalidUpdateBeforeCallingKernel) {
  FakeMxcfbSyscalls fake;
  MxcfbDevice device(&fake);
  ASSERT_EQ(device.open(rm1_profile()), kPlutoStatusOk);
  uapi::UpdateData update = valid_update();
  update.update_region.left = kRm1Width - 5;
  update.update_region.width = 10;

  EXPECT_EQ(device.send_update(&update), kPlutoStatusInvalidArgument);
  EXPECT_EQ(fake.send_count, 0);
  EXPECT_EQ(device.wait_for_update_complete(0, nullptr),
            kPlutoStatusInvalidArgument);
}

TEST(MxcfbDevice, RejectsCompletionForADifferentMarker) {
  FakeMxcfbSyscalls fake;
  fake.return_different_marker = true;
  MxcfbDevice device(&fake);
  ASSERT_EQ(device.open(rm1_profile()), kPlutoStatusOk);

  EXPECT_EQ(device.wait_for_update_complete(7, nullptr),
            kPlutoStatusDeviceLost);
}

TEST(MxcfbDevice, DestructorUnmapsBeforeClosing) {
  FakeMxcfbSyscalls fake;
  {
    MxcfbDevice device(&fake);
    ASSERT_EQ(device.open(rm1_profile()), kPlutoStatusOk);
  }

  EXPECT_EQ(fake.munmap_count, 1);
  EXPECT_EQ(fake.munmap_address, fake.mapped_storage.data());
  EXPECT_EQ(fake.munmap_length, kRm1MappingBytes);
  EXPECT_EQ(fake.close_count, 1);
  EXPECT_EQ(fake.closed_fd, FakeMxcfbSyscalls::framebuffer_fd);
  ASSERT_GE(fake.calls.size(), 2U);
  EXPECT_EQ(fake.calls[fake.calls.size() - 2], "munmap");
  EXPECT_EQ(fake.calls[fake.calls.size() - 1], "close");
}
