#ifndef PLUTO_PRESENTER_NATIVE_MXCFB_MXCFB_UAPI_H_
#define PLUTO_PRESENTER_NATIVE_MXCFB_MXCFB_UAPI_H_

#include <cstddef>
#include <cstdint>

namespace pluto::native::mxcfb::uapi {

// Declarative userspace ABI subset pinned to reMarkable's official kernel at
// d54fe67bf86e918468b936f97a2ec39f4f87a3d9:
// https://github.com/reMarkable/linux/blob/d54fe67bf86e918468b936f97a2ec39f4f87a3d9/include/uapi/linux/mxcfb.h
// https://github.com/reMarkable/linux/blob/d54fe67bf86e918468b936f97a2ec39f4f87a3d9/include/uapi/linux/fb.h
//
// This is an independently named description of the binary syscall contract,
// not copied kernel implementation code. The explicit-width fields and
// assertions below deliberately pin the 32-bit ARM ABI used by reMarkable 1.

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

struct UpdateRegion {
  std::uint32_t top;
  std::uint32_t left;
  std::uint32_t width;
  std::uint32_t height;
};

struct AlternateBufferData {
  std::uint32_t physical_address;
  std::uint32_t width;
  std::uint32_t height;
  UpdateRegion update_region;
};

struct UpdateData {
  UpdateRegion update_region;
  std::uint32_t waveform_mode;
  std::uint32_t update_mode;
  std::uint32_t update_marker;
  std::int32_t temperature;
  std::uint32_t flags;
  std::int32_t dither_mode;
  std::int32_t quantization_bits;
  AlternateBufferData alternate_buffer;
};

struct UpdateMarkerData {
  std::uint32_t update_marker;
  std::uint32_t collision_test;
};

inline constexpr std::uint32_t kFramebufferTypePackedPixels = 0;
inline constexpr std::uint32_t kFramebufferVisualTrueColor = 2;
inline constexpr std::uint32_t kFramebufferRotateClockwise = 1;

inline constexpr std::uint32_t kUpdateModePartial = 0;
inline constexpr std::uint32_t kUpdateModeFull = 1;
inline constexpr std::uint32_t kWaveformModeAuto = 257;
inline constexpr std::int32_t kTemperatureUseAmbient = 0x1000;

// Linux framebuffer retained its original fixed-number GET ioctls rather
// than encoding the pointed-to structure size in the request number.
inline constexpr unsigned long kGetVariableScreenInfo = 0x4600UL;
inline constexpr unsigned long kPutVariableScreenInfo = 0x4601UL;
inline constexpr unsigned long kGetFixedScreenInfo = 0x4602UL;

constexpr std::uint32_t linux_ioctl_request(std::uint32_t direction,
                                            std::uint32_t type,
                                            std::uint32_t number,
                                            std::uint32_t size) {
  return (direction << 30U) | (size << 16U) | (type << 8U) | number;
}

inline constexpr unsigned long kSendUpdate = linux_ioctl_request(
    1U, static_cast<std::uint32_t>('F'), 0x2eU, sizeof(UpdateData));
inline constexpr unsigned long kWaitForUpdateComplete = linux_ioctl_request(
    3U, static_cast<std::uint32_t>('F'), 0x2fU, sizeof(UpdateMarkerData));

static_assert(sizeof(FramebufferBitfield) == 12);
static_assert(sizeof(FramebufferVariableInfoArm32) == 160);
static_assert(offsetof(FramebufferVariableInfoArm32, xres_virtual) == 8);
static_assert(offsetof(FramebufferVariableInfoArm32, bits_per_pixel) == 24);
static_assert(offsetof(FramebufferVariableInfoArm32, red) == 32);
static_assert(offsetof(FramebufferVariableInfoArm32, rotate) == 136);
static_assert(offsetof(FramebufferVariableInfoArm32, reserved) == 144);

static_assert(sizeof(FramebufferFixedInfoArm32) == 68);
static_assert(offsetof(FramebufferFixedInfoArm32, smem_start) == 16);
static_assert(offsetof(FramebufferFixedInfoArm32, smem_len) == 20);
static_assert(offsetof(FramebufferFixedInfoArm32, visual) == 32);
static_assert(offsetof(FramebufferFixedInfoArm32, line_length) == 44);
static_assert(offsetof(FramebufferFixedInfoArm32, capabilities) == 60);

static_assert(sizeof(UpdateRegion) == 16);
static_assert(sizeof(AlternateBufferData) == 28);
static_assert(offsetof(AlternateBufferData, update_region) == 12);
static_assert(sizeof(UpdateData) == 72);
static_assert(offsetof(UpdateData, waveform_mode) == 16);
static_assert(offsetof(UpdateData, update_marker) == 24);
static_assert(offsetof(UpdateData, alternate_buffer) == 44);
static_assert(sizeof(UpdateMarkerData) == 8);

static_assert(kSendUpdate == 0x4048462eUL);
static_assert(kWaitForUpdateComplete == 0xc008462fUL);

} // namespace pluto::native::mxcfb::uapi

#endif // PLUTO_PRESENTER_NATIVE_MXCFB_MXCFB_UAPI_H_
