#ifndef PLUTO_PRESENTER_NATIVE_RM2_RM2_FBDEV_UAPI_H_
#define PLUTO_PRESENTER_NATIVE_RM2_RM2_FBDEV_UAPI_H_

#include <cstddef>
#include <cstdint>

namespace pluto::native::rm2::uapi {

// Linux fbdev ABI pinned to the 32-bit ARM userspace used by reMarkable 2.
// These are declarations of the public syscall contract only; no kernel
// implementation is copied into Pluto.
struct FramebufferBitfield {
  std::uint32_t offset;
  std::uint32_t length;
  std::uint32_t msb_right;
};

struct FramebufferVariableInfoArm32 {
  std::uint32_t xres;
  std::uint32_t yres;
  std::uint32_t xres_virtual;
  std::uint32_t yres_virtual;
  std::uint32_t xoffset;
  std::uint32_t yoffset;
  std::uint32_t bits_per_pixel;
  std::uint32_t grayscale;
  FramebufferBitfield red;
  FramebufferBitfield green;
  FramebufferBitfield blue;
  FramebufferBitfield transp;
  std::uint32_t nonstd;
  std::uint32_t activate;
  std::uint32_t height;
  std::uint32_t width;
  std::uint32_t accel_flags;
  std::uint32_t pixclock;
  std::uint32_t left_margin;
  std::uint32_t right_margin;
  std::uint32_t upper_margin;
  std::uint32_t lower_margin;
  std::uint32_t hsync_len;
  std::uint32_t vsync_len;
  std::uint32_t sync;
  std::uint32_t vmode;
  std::uint32_t rotate;
  std::uint32_t colorspace;
  std::uint32_t reserved[4];
};

struct FramebufferFixedInfoArm32 {
  char id[16];
  std::uint32_t smem_start;
  std::uint32_t smem_len;
  std::uint32_t type;
  std::uint32_t type_aux;
  std::uint32_t visual;
  std::uint16_t xpanstep;
  std::uint16_t ypanstep;
  std::uint16_t ywrapstep;
  std::uint32_t line_length;
  std::uint32_t mmio_start;
  std::uint32_t mmio_len;
  std::uint32_t accel;
  std::uint16_t capabilities;
  std::uint16_t reserved[2];
};

inline constexpr unsigned long kGetVariableScreenInfo = 0x4600UL;
inline constexpr unsigned long kPutVariableScreenInfo = 0x4601UL;
inline constexpr unsigned long kGetFixedScreenInfo = 0x4602UL;
inline constexpr unsigned long kPanDisplay = 0x4606UL;
inline constexpr unsigned long kBlank = 0x4611UL;

inline constexpr std::uint32_t kFramebufferTypePackedPixels = 0;
inline constexpr std::uint32_t kFramebufferVisualTrueColor = 2;
inline constexpr std::uintptr_t kBlankUnblank = 0;
inline constexpr std::uintptr_t kBlankPowerdown = 4;

static_assert(sizeof(FramebufferBitfield) == 12);
static_assert(sizeof(FramebufferVariableInfoArm32) == 160);
static_assert(offsetof(FramebufferVariableInfoArm32, bits_per_pixel) == 24);
static_assert(offsetof(FramebufferVariableInfoArm32, red) == 32);
static_assert(offsetof(FramebufferVariableInfoArm32, rotate) == 136);
static_assert(sizeof(FramebufferFixedInfoArm32) == 68);
static_assert(offsetof(FramebufferFixedInfoArm32, smem_len) == 20);
static_assert(offsetof(FramebufferFixedInfoArm32, line_length) == 44);

} // namespace pluto::native::rm2::uapi

#endif // PLUTO_PRESENTER_NATIVE_RM2_RM2_FBDEV_UAPI_H_
