#include "presenter/native/mxcfb/mxcfb_device.h"

#include <cerrno>
#include <cstring>
#include <limits>
#include <string>

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

namespace pluto::native::mxcfb {
namespace {

constexpr std::string_view kExpectedDriver = "mxc_epdc_fb";
constexpr std::string_view kExpectedFramebuffer = "/dev/fb0";
constexpr std::string_view kExpectedPixelFormat = "rgb565";
constexpr std::uint32_t kExpectedBytesPerPixel = 2;

class SystemMxcfbSyscalls final : public MxcfbSyscalls {
public:
  int open(const char *path, int flags) override { return ::open(path, flags); }

  int ioctl(int fd, unsigned long request, void *argument) override {
    return ::ioctl(fd, request, argument);
  }

  void *mmap(void *address, std::size_t length, int protection, int flags,
             int fd, off_t offset) override {
    return ::mmap(address, length, protection, flags, fd, offset);
  }

  int munmap(void *address, std::size_t length) override {
    return ::munmap(address, length);
  }

  int close(int fd) override { return ::close(fd); }
};

MxcfbSyscalls *system_syscalls() {
  static SystemMxcfbSyscalls syscalls;
  return &syscalls;
}

std::string errno_message(std::string_view operation, int error) {
  std::string result(operation);
  result.append(": ");
  result.append(std::strerror(error));
  return result;
}

PlutoStatus status_for_errno(int error) {
  switch (error) {
  case EAGAIN:
  case EBUSY:
    return kPlutoStatusAgain;
  case ETIMEDOUT:
    return kPlutoStatusTimeout;
  case EINVAL:
    return kPlutoStatusInvalidArgument;
  case EBADF:
  case EIO:
  case ENODEV:
  case ENOENT:
  case ENXIO:
    return kPlutoStatusDeviceLost;
  default:
    return kPlutoStatusInternal;
  }
}

bool field_is(const uapi::FramebufferBitfield &field, std::uint32_t offset,
              std::uint32_t length) {
  return field.offset == offset && field.length == length &&
         field.msb_right == 0;
}

std::string_view driver_name(const uapi::FramebufferFixedInfoArm32 &fixed) {
  const void *terminator = std::memchr(fixed.id, '\0', sizeof(fixed.id));
  const auto length =
      terminator == nullptr
          ? sizeof(fixed.id)
          : static_cast<std::size_t>(static_cast<const char *>(terminator) -
                                     fixed.id);
  return std::string_view(fixed.id, length);
}

} // namespace

MxcfbDevice::MxcfbDevice(MxcfbSyscalls *syscalls)
    : syscalls_(syscalls == nullptr ? system_syscalls() : syscalls) {}

MxcfbDevice::~MxcfbDevice() { close(); }

PlutoStatus MxcfbDevice::fail(PlutoStatus status, std::string message) {
  last_error_ = std::move(message);
  return status;
}

PlutoStatus MxcfbDevice::open(const GeneratedDeviceProfile &profile) {
  if (is_open()) {
    return fail(kPlutoStatusInvalidArgument,
                "MXCFB framebuffer is already open");
  }
  last_error_.clear();

  const GeneratedDisplayContract &display = profile.runtime.display;
  if (profile.display_driver != NativeDisplayDriverKind::kMxcfbEpdc ||
      profile.target_slice != DeviceTargetSlice::kLinuxArm ||
      profile.runtime.display_device != kExpectedFramebuffer ||
      profile.panel.source_pixel_format != kExpectedPixelFormat ||
      profile.panel.color || profile.panel.width <= 0 ||
      profile.panel.height <= 0 ||
      display.scanout_width !=
          static_cast<std::uint32_t>(profile.panel.width) ||
      display.scanout_height !=
          static_cast<std::uint32_t>(profile.panel.height) ||
      !display.virtual_width.has_value() ||
      !display.virtual_height.has_value() ||
      !display.stride_bytes.has_value() || !display.rotation.has_value() ||
      display.bits_per_pixel != 16 || display.buffer_slots.has_value() ||
      display.slot_bytes.has_value() ||
      display.phase_interval_nanoseconds.has_value() ||
      display.damage_alignment_pixels == 0) {
    return fail(kPlutoStatusUnsupported,
                "generated profile is not the RM1 MXCFB contract");
  }

  fd_ = syscalls_->open(kExpectedFramebuffer.data(), O_RDWR | O_CLOEXEC);
  if (fd_ < 0) {
    const int error = errno;
    return fail(status_for_errno(error),
                errno_message("open(/dev/fb0)", error));
  }

  uapi::FramebufferFixedInfoArm32 fixed{};
  if (syscalls_->ioctl(fd_, uapi::kGetFixedScreenInfo, &fixed) < 0) {
    const int error = errno;
    close();
    return fail(status_for_errno(error),
                errno_message("FBIOGET_FSCREENINFO", error));
  }

  uapi::FramebufferVariableInfoArm32 variable{};
  if (syscalls_->ioctl(fd_, uapi::kGetVariableScreenInfo, &variable) < 0) {
    const int error = errno;
    close();
    return fail(status_for_errno(error),
                errno_message("FBIOGET_VSCREENINFO", error));
  }

  if (driver_name(fixed) != kExpectedDriver) {
    close();
    return fail(kPlutoStatusUnsupported,
                "fb0 is not backed by the RM1 mxc_epdc_fb driver");
  }
  if (fixed.type != uapi::kFramebufferTypePackedPixels ||
      fixed.visual != uapi::kFramebufferVisualTrueColor) {
    close();
    return fail(kPlutoStatusUnsupported,
                "fb0 does not expose packed true-color pixels");
  }

  if (variable.xres != display.scanout_width ||
      variable.yres != display.scanout_height ||
      variable.xres_virtual != *display.virtual_width ||
      variable.yres_virtual != *display.virtual_height ||
      variable.xoffset != 0 || variable.yoffset != 0) {
    close();
    return fail(kPlutoStatusUnsupported,
                "fb0 geometry does not match the generated RM1 profile");
  }
  if (variable.rotate != *display.rotation) {
    close();
    return fail(kPlutoStatusUnsupported,
                "fb0 rotation is not the pinned RM1 clockwise layout");
  }
  if (variable.bits_per_pixel != display.bits_per_pixel ||
      variable.grayscale != 0 || !field_is(variable.red, 11, 5) ||
      !field_is(variable.green, 5, 6) || !field_is(variable.blue, 0, 5) ||
      !field_is(variable.transp, 0, 0)) {
    close();
    return fail(kPlutoStatusUnsupported,
                "fb0 pixel layout is not the pinned RM1 RGB565 layout");
  }

  const std::uint64_t packed_stride =
      static_cast<std::uint64_t>(*display.virtual_width) *
      kExpectedBytesPerPixel;
  const std::uint64_t exact_allocation =
      static_cast<std::uint64_t>(*display.stride_bytes) *
      *display.virtual_height;
  if (packed_stride > std::numeric_limits<std::uint32_t>::max() ||
      *display.stride_bytes != packed_stride ||
      fixed.line_length != *display.stride_bytes ||
      exact_allocation > std::numeric_limits<std::uint32_t>::max() ||
      fixed.smem_len != exact_allocation) {
    close();
    return fail(kPlutoStatusUnsupported,
                "fb0 stride or framebuffer allocation is inconsistent");
  }

  mapping_ = syscalls_->mmap(nullptr, fixed.smem_len, PROT_READ | PROT_WRITE,
                             MAP_SHARED, fd_, 0);
  if (mapping_ == MAP_FAILED) {
    mapping_ = nullptr;
    const int error = errno;
    close();
    return fail(status_for_errno(error), errno_message("mmap(fb0)", error));
  }

  info_ = {
      .width = variable.xres,
      .height = variable.yres,
      .virtual_width = variable.xres_virtual,
      .virtual_height = variable.yres_virtual,
      .stride_bytes = fixed.line_length,
      .mapped_bytes = fixed.smem_len,
  };
  return kPlutoStatusOk;
}

void MxcfbDevice::close() {
  if (mapping_ != nullptr) {
    syscalls_->munmap(mapping_, info_.mapped_bytes);
    mapping_ = nullptr;
  }
  if (fd_ >= 0) {
    syscalls_->close(fd_);
    fd_ = -1;
  }
  info_ = {};
}

std::span<std::byte> MxcfbDevice::framebuffer() {
  if (mapping_ == nullptr) {
    return {};
  }
  return {static_cast<std::byte *>(mapping_), info_.mapped_bytes};
}

PlutoStatus MxcfbDevice::send_update(uapi::UpdateData *update) {
  if (!is_open()) {
    return fail(kPlutoStatusDeviceLost, "MXCFB framebuffer is not open");
  }
  if (update == nullptr || update->update_marker == 0 ||
      update->update_region.width == 0 || update->update_region.height == 0 ||
      update->update_region.left > info_.width ||
      update->update_region.top > info_.height ||
      update->update_region.width > info_.width - update->update_region.left ||
      update->update_region.height > info_.height - update->update_region.top ||
      (update->update_mode != uapi::kUpdateModePartial &&
       update->update_mode != uapi::kUpdateModeFull)) {
    return fail(kPlutoStatusInvalidArgument, "invalid MXCFB update request");
  }

  if (syscalls_->ioctl(fd_, uapi::kSendUpdate, update) < 0) {
    const int error = errno;
    return fail(status_for_errno(error),
                errno_message("MXCFB_SEND_UPDATE", error));
  }
  last_error_.clear();
  return kPlutoStatusOk;
}

PlutoStatus MxcfbDevice::wait_for_update_complete(std::uint32_t marker,
                                                  bool *out_collision) {
  if (out_collision != nullptr) {
    *out_collision = false;
  }
  if (!is_open()) {
    return fail(kPlutoStatusDeviceLost, "MXCFB framebuffer is not open");
  }
  if (marker == 0) {
    return fail(kPlutoStatusInvalidArgument,
                "MXCFB update marker zero is invalid");
  }

  uapi::UpdateMarkerData completion{
      .update_marker = marker,
      .collision_test = 0,
  };
  if (syscalls_->ioctl(fd_, uapi::kWaitForUpdateComplete, &completion) < 0) {
    const int error = errno;
    return fail(status_for_errno(error),
                errno_message("MXCFB_WAIT_FOR_UPDATE_COMPLETE", error));
  }
  if (completion.update_marker != marker) {
    return fail(kPlutoStatusDeviceLost,
                "MXCFB completion returned a different marker");
  }
  if (out_collision != nullptr) {
    *out_collision = completion.collision_test != 0;
  }
  last_error_.clear();
  return kPlutoStatusOk;
}

} // namespace pluto::native::mxcfb
