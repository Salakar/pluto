#include "presenter/native/rm2/mxs_lcdif_device.h"

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <limits>
#include <string>

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "presenter/native/rm2/rm2_scan_encoder.h"

namespace pluto::native::rm2 {
namespace {

constexpr std::string_view kExpectedFramebuffer = "/dev/fb0";
constexpr std::string_view kExpectedDriver = "mxs-lcdif";
constexpr std::uint32_t kExpectedPixclock = 28800;
constexpr std::uint32_t kExpectedFramebufferPhysicalBase = 0xa9d00000U;

class SystemMxsLcdifSyscalls final : public MxsLcdifSyscalls {
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

MxsLcdifSyscalls *system_syscalls() {
  static SystemMxsLcdifSyscalls syscalls;
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

std::string_view driver_name(const uapi::FramebufferFixedInfoArm32 &fixed) {
  const void *terminator = std::memchr(fixed.id, '\0', sizeof(fixed.id));
  const std::size_t length =
      terminator == nullptr
          ? sizeof(fixed.id)
          : static_cast<std::size_t>(static_cast<const char *>(terminator) -
                                     fixed.id);
  return std::string_view(fixed.id, length);
}

bool bitfield_is(const uapi::FramebufferBitfield &field, std::uint32_t offset,
                 std::uint32_t length) {
  return field.offset == offset && field.length == length &&
         field.msb_right == 0;
}

bool variable_mode_valid(const uapi::FramebufferVariableInfoArm32 &variable,
                         const GeneratedDisplayContract &display,
                         bool require_idle_offset) {
  if (!display.virtual_width || !display.virtual_height || !display.rotation ||
      !display.buffer_slots || !display.slot_bytes) {
    return false;
  }
  const std::uint32_t maximum_offset =
      (*display.buffer_slots - 1U) * display.scanout_height;
  return variable.xres == display.scanout_width &&
         variable.yres == display.scanout_height &&
         variable.xres_virtual == *display.virtual_width &&
         variable.yres_virtual == *display.virtual_height &&
         variable.xoffset == 0 && variable.yoffset <= maximum_offset &&
         variable.yoffset % display.scanout_height == 0 &&
         (!require_idle_offset || variable.yoffset == maximum_offset) &&
         variable.bits_per_pixel == display.bits_per_pixel &&
         variable.grayscale == 0 && bitfield_is(variable.red, 16, 8) &&
         bitfield_is(variable.green, 8, 8) &&
         bitfield_is(variable.blue, 0, 8) &&
         bitfield_is(variable.transp, 0, 0) && variable.nonstd == 0 &&
         variable.pixclock == kExpectedPixclock && variable.left_margin == 1 &&
         variable.right_margin == 1 && variable.upper_margin == 1 &&
         variable.lower_margin == 143 && variable.hsync_len == 1 &&
         variable.vsync_len == 1 && variable.sync == 0 && variable.vmode == 0 &&
         variable.rotate == *display.rotation;
}

bool fixed_mode_valid(const uapi::FramebufferFixedInfoArm32 &fixed,
                      const GeneratedDisplayContract &display) {
  return display.stride_bytes && display.mapping_bytes &&
         driver_name(fixed) == kExpectedDriver &&
         fixed.type == uapi::kFramebufferTypePackedPixels &&
         fixed.visual == uapi::kFramebufferVisualTrueColor &&
         fixed.smem_start == kExpectedFramebufferPhysicalBase &&
         fixed.xpanstep == 0 && fixed.ypanstep == 1 && fixed.ywrapstep == 1 &&
         fixed.line_length == *display.stride_bytes &&
         fixed.smem_len == *display.mapping_bytes;
}

} // namespace

MxsLcdifDevice::MxsLcdifDevice(MxsLcdifSyscalls *syscalls)
    : syscalls_(syscalls == nullptr ? system_syscalls() : syscalls) {}

MxsLcdifDevice::~MxsLcdifDevice() { close(); }

PlutoStatus MxsLcdifDevice::fail(PlutoStatus status, std::string message) {
  last_error_ = std::move(message);
  return status;
}

PlutoStatus MxsLcdifDevice::open(const GeneratedDeviceProfile &profile) {
  if (is_open()) {
    return fail(kPlutoStatusInvalidArgument,
                "RM2 LCDIF framebuffer is already open");
  }
  last_error_.clear();
  const GeneratedDisplayContract &display = profile.runtime.display;
  if (profile.id != "rm2" ||
      profile.display_driver != NativeDisplayDriverKind::kLcdifTcon ||
      profile.target_slice != DeviceTargetSlice::kLinuxArm ||
      profile.runtime.display_device != kExpectedFramebuffer ||
      profile.panel.width != static_cast<int>(kRm2PanelWidth) ||
      profile.panel.height != static_cast<int>(kRm2PanelHeight) ||
      profile.panel.source_pixel_format != "rgb565" || profile.panel.color ||
      display.scanout_width != kRm2ScanoutWidth ||
      display.scanout_height != kRm2ScanoutHeight ||
      display.virtual_width != kRm2ScanoutWidth ||
      display.virtual_height != kRm2ScanoutHeight * kRm2MappedSlots ||
      display.stride_bytes != kRm2ScanoutStrideBytes ||
      display.mapping_bytes != 32U * 1024U * 1024U ||
      display.bits_per_pixel != 32 || display.rotation != 0 ||
      display.buffer_slots != kRm2MappedSlots ||
      display.slot_bytes != kRm2SlotBytes ||
      display.damage_alignment_pixels != 8 ||
      !display.phase_interval_nanoseconds.has_value()) {
    return fail(kPlutoStatusUnsupported,
                "generated profile is not the accepted RM2 LCDIF contract");
  }

  fd_ = syscalls_->open(kExpectedFramebuffer.data(), O_RDWR | O_CLOEXEC);
  if (fd_ < 0) {
    const int error = errno;
    return fail(status_for_errno(error),
                errno_message("open(/dev/fb0)", error));
  }

  uapi::FramebufferFixedInfoArm32 fixed{};
  uapi::FramebufferVariableInfoArm32 variable{};
  if (syscalls_->ioctl(fd_, uapi::kGetFixedScreenInfo, &fixed) < 0 ||
      syscalls_->ioctl(fd_, uapi::kGetVariableScreenInfo, &variable) < 0) {
    const int error = errno;
    close();
    return fail(status_for_errno(error),
                errno_message("read RM2 framebuffer mode", error));
  }
  if (!fixed_mode_valid(fixed, display) ||
      !variable_mode_valid(variable, display, false)) {
    close();
    return fail(kPlutoStatusUnsupported,
                "live fb0 mode does not match the exact RM2 LCDIF profile");
  }

  const std::uint64_t required_slots =
      static_cast<std::uint64_t>(*display.slot_bytes) * *display.buffer_slots;
  if (required_slots > *display.mapping_bytes ||
      *display.slot_bytes != static_cast<std::uint64_t>(*display.stride_bytes) *
                                 display.scanout_height ||
      *display.mapping_bytes > std::numeric_limits<std::uint32_t>::max()) {
    close();
    return fail(kPlutoStatusUnsupported,
                "RM2 slot ring is inconsistent with the mapped allocation");
  }

  observed_fixed_ = fixed;
  observed_variable_ = variable;
  mapping_bytes_ = static_cast<std::size_t>(*display.mapping_bytes);
  slot_bytes_ = static_cast<std::size_t>(*display.slot_bytes);
  slot_count_ = *display.buffer_slots;
  display_ = display;
  return kPlutoStatusOk;
}

PlutoStatus MxsLcdifDevice::initialize() {
  if (!is_open()) {
    return fail(kPlutoStatusDeviceLost, "RM2 LCDIF framebuffer is not open");
  }
  if (initialized_) {
    return fail(kPlutoStatusInvalidArgument,
                "RM2 LCDIF framebuffer is already initialized");
  }

  PlutoStatus status = blank_powerdown();
  if (status != kPlutoStatusOk) {
    close();
    return status;
  }

  uapi::FramebufferVariableInfoArm32 requested = observed_variable_;
  requested.yoffset = (slot_count_ - 1U) * requested.yres;
  if (syscalls_->ioctl(fd_, uapi::kPutVariableScreenInfo, &requested) < 0) {
    const int error = errno;
    best_effort_unblank_before_close();
    close();
    status = status_for_errno(error);
    return fail(status == kPlutoStatusInvalidArgument ? kPlutoStatusUnsupported
                                                      : status,
                errno_message("FBIOPUT_VSCREENINFO", error));
  }

  uapi::FramebufferFixedInfoArm32 fixed{};
  uapi::FramebufferVariableInfoArm32 variable{};
  if (syscalls_->ioctl(fd_, uapi::kGetFixedScreenInfo, &fixed) < 0 ||
      syscalls_->ioctl(fd_, uapi::kGetVariableScreenInfo, &variable) < 0) {
    const int error = errno;
    best_effort_unblank_before_close();
    close();
    return fail(status_for_errno(error),
                errno_message("revalidate RM2 framebuffer mode", error));
  }
  if (!fixed_mode_valid(fixed, display_) ||
      !variable_mode_valid(variable, display_, true) ||
      fixed.smem_start != observed_fixed_.smem_start) {
    best_effort_unblank_before_close();
    close();
    return fail(kPlutoStatusUnsupported,
                "RM2 framebuffer contract changed during initialization");
  }

  mapping_ = syscalls_->mmap(nullptr, mapping_bytes_, PROT_READ | PROT_WRITE,
                             MAP_SHARED, fd_, 0);
  if (mapping_ == MAP_FAILED) {
    mapping_ = nullptr;
    const int error = errno;
    best_effort_unblank_before_close();
    close();
    return fail(status_for_errno(error), errno_message("mmap(fb0)", error));
  }
  observed_fixed_ = fixed;
  observed_variable_ = variable;
  initialized_ = true;
  blanked_ = true;
  last_error_.clear();
  return kPlutoStatusOk;
}

void MxsLcdifDevice::close() {
  if (fd_ >= 0 && initialized_) {
    (void)blank_powerdown();
  }
  if (mapping_ != nullptr) {
    syscalls_->munmap(mapping_, mapping_bytes_);
    mapping_ = nullptr;
  }
  if (fd_ >= 0) {
    syscalls_->close(fd_);
    fd_ = -1;
  }
  mapping_bytes_ = 0;
  slot_bytes_ = 0;
  slot_count_ = 0;
  display_ = {};
  observed_fixed_ = {};
  observed_variable_ = {};
  initialized_ = false;
  blanked_ = false;
}

std::span<std::byte> MxsLcdifDevice::slot(std::uint32_t index) {
  if (!initialized_ || mapping_ == nullptr || index >= slot_count_) {
    return {};
  }
  return {static_cast<std::byte *>(mapping_) +
              static_cast<std::size_t>(index) * slot_bytes_,
          slot_bytes_};
}

PlutoStatus MxsLcdifDevice::set_offset(std::uint32_t index) {
  if (!initialized_ || index >= slot_count_) {
    return fail(initialized_ ? kPlutoStatusInvalidArgument
                             : kPlutoStatusDeviceLost,
                "RM2 pan slot is unavailable");
  }
  observed_variable_.yoffset = index * observed_variable_.yres;
  return kPlutoStatusOk;
}

PlutoStatus MxsLcdifDevice::pan(std::uint32_t index,
                                std::chrono::nanoseconds *out_duration) {
  if (out_duration != nullptr) {
    *out_duration = std::chrono::nanoseconds::zero();
  }
  PlutoStatus status = set_offset(index);
  if (status != kPlutoStatusOk) {
    return status;
  }
  if (blanked_) {
    return fail(kPlutoStatusAgain,
                "RM2 FBIOPAN_DISPLAY is forbidden while blanked");
  }
  // Scan slots are ordinary mapped RAM, but the compiler/CPU must publish
  // every encoder store before the kernel is asked to latch this y-offset.
  std::atomic_thread_fence(std::memory_order_release);
  const auto begin = std::chrono::steady_clock::now();
  const int result =
      syscalls_->ioctl(fd_, uapi::kPanDisplay, &observed_variable_);
  const auto duration = std::chrono::steady_clock::now() - begin;
  if (out_duration != nullptr) {
    *out_duration =
        std::chrono::duration_cast<std::chrono::nanoseconds>(duration);
  }
  // The RM2 mxs-lcdif driver returns a positive scan-line count on success.
  // Only negative syscall results are failures.
  if (result < 0) {
    const int error = errno;
    return fail(status_for_errno(error),
                errno_message("FBIOPAN_DISPLAY", error));
  }
  last_error_.clear();
  return kPlutoStatusOk;
}

PlutoStatus MxsLcdifDevice::unblank(std::uint32_t index) {
  PlutoStatus status = set_offset(index);
  if (status != kPlutoStatusOk) {
    return status;
  }
  if (syscalls_->ioctl(fd_, uapi::kPutVariableScreenInfo, &observed_variable_) <
      0) {
    const int error = errno;
    return fail(status_for_errno(error),
                errno_message("FBIOPUT_VSCREENINFO before unblank", error));
  }
  int last_error = 0;
  for (int attempt = 0; attempt < 5; ++attempt) {
    if (syscalls_->ioctl(fd_, uapi::kBlank,
                         reinterpret_cast<void *>(uapi::kBlankUnblank)) >= 0) {
      blanked_ = false;
      last_error_.clear();
      return kPlutoStatusOk;
    }
    last_error = errno;
    if (last_error != EAGAIN && last_error != EBUSY) {
      break;
    }
  }
  return fail(status_for_errno(last_error),
              errno_message("FBIOBLANK(UNBLANK)", last_error));
}

PlutoStatus MxsLcdifDevice::blank_powerdown() {
  if (!is_open()) {
    return fail(kPlutoStatusDeviceLost, "RM2 LCDIF framebuffer is not open");
  }
  if (syscalls_->ioctl(fd_, uapi::kBlank,
                       reinterpret_cast<void *>(uapi::kBlankPowerdown)) < 0) {
    const int error = errno;
    return fail(status_for_errno(error),
                errno_message("FBIOBLANK(POWERDOWN)", error));
  }
  blanked_ = true;
  last_error_.clear();
  return kPlutoStatusOk;
}

void MxsLcdifDevice::best_effort_unblank_before_close() {
  if (fd_ >= 0 && blanked_) {
    (void)syscalls_->ioctl(fd_, uapi::kBlank,
                           reinterpret_cast<void *>(uapi::kBlankUnblank));
    blanked_ = false;
  }
}

} // namespace pluto::native::rm2
