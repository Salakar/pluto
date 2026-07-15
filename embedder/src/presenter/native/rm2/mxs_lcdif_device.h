#ifndef PLUTO_PRESENTER_NATIVE_RM2_MXS_LCDIF_DEVICE_H_
#define PLUTO_PRESENTER_NATIVE_RM2_MXS_LCDIF_DEVICE_H_

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>

#include <sys/types.h>

#include "generated/device_profiles.h"
#include "pluto/presenter.h"
#include "presenter/native/rm2/rm2_fbdev_uapi.h"

namespace pluto::native::rm2 {

class MxsLcdifSyscalls {
public:
  virtual ~MxsLcdifSyscalls() = default;

  virtual int open(const char *path, int flags) = 0;
  virtual int ioctl(int fd, unsigned long request, void *argument) = 0;
  virtual void *mmap(void *address, std::size_t length, int protection,
                     int flags, int fd, off_t offset) = 0;
  virtual int munmap(void *address, std::size_t length) = 0;
  virtual int close(int fd) = 0;
};

class MxsLcdifDevice final {
public:
  explicit MxsLcdifDevice(MxsLcdifSyscalls *syscalls = nullptr);
  ~MxsLcdifDevice();

  MxsLcdifDevice(const MxsLcdifDevice &) = delete;
  MxsLcdifDevice &operator=(const MxsLcdifDevice &) = delete;

  // Read-only. Exact mode reassertion, blanking, and mmap happen only in
  // initialize(), after the WBF and temperature preflight has succeeded.
  PlutoStatus open(const GeneratedDeviceProfile &profile);
  PlutoStatus initialize();
  void close();

  bool is_open() const { return fd_ >= 0; }
  bool is_initialized() const { return initialized_; }
  bool is_blanked() const { return blanked_; }
  std::string_view last_error() const { return last_error_; }

  std::span<std::byte> slot(std::uint32_t index);
  PlutoStatus pan(std::uint32_t index,
                  std::chrono::nanoseconds *out_duration = nullptr);
  PlutoStatus unblank(std::uint32_t index);
  PlutoStatus blank_powerdown();

private:
  PlutoStatus fail(PlutoStatus status, std::string message);
  PlutoStatus set_offset(std::uint32_t index);
  void best_effort_unblank_before_close();

  MxsLcdifSyscalls *syscalls_;
  int fd_ = -1;
  void *mapping_ = nullptr;
  std::size_t mapping_bytes_ = 0;
  std::size_t slot_bytes_ = 0;
  std::uint32_t slot_count_ = 0;
  GeneratedDisplayContract display_{};
  uapi::FramebufferFixedInfoArm32 observed_fixed_{};
  uapi::FramebufferVariableInfoArm32 observed_variable_{};
  bool initialized_ = false;
  bool blanked_ = false;
  std::string last_error_;
};

} // namespace pluto::native::rm2

#endif // PLUTO_PRESENTER_NATIVE_RM2_MXS_LCDIF_DEVICE_H_
