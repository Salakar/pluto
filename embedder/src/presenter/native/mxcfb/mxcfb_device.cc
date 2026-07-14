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

bool bitfield_equal(const uapi::FramebufferBitfield &left,
                    const uapi::FramebufferBitfield &right) {
  return left.offset == right.offset && left.length == right.length &&
         left.msb_right == right.msb_right;
}

bool fixed_contract_equal(const uapi::FramebufferFixedInfoArm32 &left,
                          const uapi::FramebufferFixedInfoArm32 &right) {
  return driver_name(left) == driver_name(right) &&
         left.smem_start == right.smem_start &&
         left.smem_len == right.smem_len && left.type == right.type &&
         left.type_aux == right.type_aux && left.visual == right.visual &&
         left.xpanstep == right.xpanstep && left.ypanstep == right.ypanstep &&
         left.ywrapstep == right.ywrapstep &&
         left.line_length == right.line_length &&
         left.mmio_start == right.mmio_start &&
         left.mmio_len == right.mmio_len && left.accel == right.accel &&
         left.capabilities == right.capabilities &&
         left.reserved[0] == right.reserved[0] &&
         left.reserved[1] == right.reserved[1];
}

bool variable_contract_equal(const uapi::FramebufferVariableInfoArm32 &left,
                             const uapi::FramebufferVariableInfoArm32 &right) {
  return left.xres == right.xres && left.yres == right.yres &&
         left.xres_virtual == right.xres_virtual &&
         left.yres_virtual == right.yres_virtual &&
         left.xoffset == right.xoffset && left.yoffset == right.yoffset &&
         left.bits_per_pixel == right.bits_per_pixel &&
         left.grayscale == right.grayscale &&
         bitfield_equal(left.red, right.red) &&
         bitfield_equal(left.green, right.green) &&
         bitfield_equal(left.blue, right.blue) &&
         bitfield_equal(left.transp, right.transp) &&
         left.nonstd == right.nonstd && left.activate == right.activate &&
         left.height == right.height && left.width == right.width &&
         left.accel_flags == right.accel_flags &&
         left.pixclock == right.pixclock &&
         left.left_margin == right.left_margin &&
         left.right_margin == right.right_margin &&
         left.upper_margin == right.upper_margin &&
         left.lower_margin == right.lower_margin &&
         left.hsync_len == right.hsync_len &&
         left.vsync_len == right.vsync_len && left.sync == right.sync &&
         left.vmode == right.vmode && left.rotate == right.rotate &&
         left.colorspace == right.colorspace &&
         left.reserved[0] == right.reserved[0] &&
         left.reserved[1] == right.reserved[1] &&
         left.reserved[2] == right.reserved[2] &&
         left.reserved[3] == right.reserved[3];
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
      !display.stride_bytes.has_value() || !display.mapping_bytes.has_value() ||
      !display.rotation.has_value() || display.bits_per_pixel != 16 ||
      display.buffer_slots.has_value() || display.slot_bytes.has_value() ||
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
      fixed.visual != uapi::kFramebufferVisualTrueColor ||
      fixed.xpanstep != 1 || fixed.ypanstep != 1 || fixed.ywrapstep != 0) {
    close();
    return fail(kPlutoStatusUnsupported,
                "fb0 does not expose the pinned RM1 packed-pixel contract");
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
      *display.mapping_bytes != exact_allocation ||
      fixed.smem_len != *display.mapping_bytes) {
    close();
    return fail(kPlutoStatusUnsupported,
                "fb0 stride or framebuffer allocation is inconsistent");
  }

  info_ = {
      .width = variable.xres,
      .height = variable.yres,
      .virtual_width = variable.xres_virtual,
      .virtual_height = variable.yres_virtual,
      .stride_bytes = fixed.line_length,
      .mapped_bytes = fixed.smem_len,
  };
  fixed_info_ = fixed;
  variable_info_ = variable;
  return kPlutoStatusOk;
}

PlutoStatus MxcfbDevice::initialize() {
  if (!is_open()) {
    return fail(kPlutoStatusDeviceLost, "MXCFB framebuffer is not open");
  }
  if (initialized_) {
    return fail(kPlutoStatusInvalidArgument,
                "MXCFB framebuffer is already initialized");
  }

  uapi::FramebufferVariableInfoArm32 requested = variable_info_;
  if (syscalls_->ioctl(fd_, uapi::kPutVariableScreenInfo, &requested) < 0) {
    const int error = errno;
    close();
    const PlutoStatus status = status_for_errno(error);
    return fail(status == kPlutoStatusInvalidArgument ? kPlutoStatusUnsupported
                                                      : status,
                errno_message("FBIOPUT_VSCREENINFO", error));
  }

  uapi::FramebufferFixedInfoArm32 fixed{};
  uapi::FramebufferVariableInfoArm32 variable{};
  if (syscalls_->ioctl(fd_, uapi::kGetFixedScreenInfo, &fixed) < 0 ||
      syscalls_->ioctl(fd_, uapi::kGetVariableScreenInfo, &variable) < 0) {
    const int error = errno;
    close();
    return fail(status_for_errno(error),
                errno_message("revalidate RM1 framebuffer mode", error));
  }
  if (!fixed_contract_equal(fixed_info_, fixed) ||
      !variable_contract_equal(variable_info_, variable)) {
    close();
    return fail(kPlutoStatusUnsupported,
                "RM1 framebuffer contract changed after mode initialization");
  }

  mapping_ = syscalls_->mmap(nullptr, fixed.smem_len, PROT_READ | PROT_WRITE,
                             MAP_SHARED, fd_, 0);
  if (mapping_ == MAP_FAILED) {
    mapping_ = nullptr;
    const int error = errno;
    close();
    return fail(status_for_errno(error), errno_message("mmap(fb0)", error));
  }

  fixed_info_ = fixed;
  variable_info_ = variable;
  initialized_ = true;
  last_error_.clear();
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
  fixed_info_ = {};
  variable_info_ = {};
  initialized_ = false;
}

std::span<std::byte> MxcfbDevice::framebuffer() {
  if (mapping_ == nullptr) {
    return {};
  }
  return {static_cast<std::byte *>(mapping_), info_.mapped_bytes};
}

PlutoStatus MxcfbDevice::send_update(uapi::UpdateData *update) {
  if (!is_open() || !initialized_) {
    return fail(kPlutoStatusDeviceLost, "MXCFB framebuffer is not initialized");
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
  if (!is_open() || !initialized_) {
    return fail(kPlutoStatusDeviceLost, "MXCFB framebuffer is not initialized");
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
