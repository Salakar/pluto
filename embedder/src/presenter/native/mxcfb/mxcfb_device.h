#ifndef PLUTO_PRESENTER_NATIVE_MXCFB_MXCFB_DEVICE_H_
#define PLUTO_PRESENTER_NATIVE_MXCFB_MXCFB_DEVICE_H_

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>

#include <sys/types.h>

#include "generated/device_profiles.h"
#include "pluto/presenter.h"
#include "presenter/native/mxcfb/mxcfb_uapi.h"

namespace pluto::native::mxcfb {

// Injectable syscall boundary. Tests own their implementation; production
// uses the process-wide system implementation when nullptr is passed to the
// MxcfbDevice constructor.
class MxcfbSyscalls {
public:
  virtual ~MxcfbSyscalls() = default;

  virtual int open(const char *path, int flags) = 0;
  virtual int ioctl(int fd, unsigned long request, void *argument) = 0;
  virtual void *mmap(void *address, std::size_t length, int protection,
                     int flags, int fd, off_t offset) = 0;
  virtual int munmap(void *address, std::size_t length) = 0;
  virtual int close(int fd) = 0;
};

struct MxcfbFramebufferInfo {
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t virtual_width = 0;
  std::uint32_t virtual_height = 0;
  std::uint32_t stride_bytes = 0;
  std::size_t mapped_bytes = 0;
};

// Thin ownership and validation boundary around the RM1 kernel EPDC driver.
// The kernel retains waveform selection, collision handling, LUT assignment,
// and marker completion; higher layers own pixels and update policy.
class MxcfbDevice final {
public:
  explicit MxcfbDevice(MxcfbSyscalls *syscalls = nullptr);
  ~MxcfbDevice();

  MxcfbDevice(const MxcfbDevice &) = delete;
  MxcfbDevice &operator=(const MxcfbDevice &) = delete;
  MxcfbDevice(MxcfbDevice &&) = delete;
  MxcfbDevice &operator=(MxcfbDevice &&) = delete;

  PlutoStatus open(const GeneratedDeviceProfile &profile);
  // Reasserts the already validated stock mode at the first write boundary,
  // then proves the kernel kept the exact framebuffer contract. open() stays
  // observational so NativeDisplayBackend::probe() performs no display write.
  PlutoStatus initialize();
  void close();

  bool is_open() const { return fd_ >= 0; }
  bool is_initialized() const { return initialized_; }
  const MxcfbFramebufferInfo &framebuffer_info() const { return info_; }
  std::span<std::byte> framebuffer();
  std::string_view last_error() const { return last_error_; }

  PlutoStatus send_update(uapi::UpdateData *update);
  PlutoStatus wait_for_update_complete(std::uint32_t marker,
                                       bool *out_collision);

private:
  PlutoStatus fail(PlutoStatus status, std::string message);

  MxcfbSyscalls *syscalls_;
  int fd_ = -1;
  void *mapping_ = nullptr;
  MxcfbFramebufferInfo info_{};
  uapi::FramebufferFixedInfoArm32 fixed_info_{};
  uapi::FramebufferVariableInfoArm32 variable_info_{};
  bool initialized_ = false;
  std::string last_error_;
};

} // namespace pluto::native::mxcfb

#endif // PLUTO_PRESENTER_NATIVE_MXCFB_MXCFB_DEVICE_H_
