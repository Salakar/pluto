#ifndef PLUTO_RENDERER_CONVERT_H_
#define PLUTO_RENDERER_CONVERT_H_

#include <cstddef>
#include <cstdint>

#include "pluto/presenter.h"

namespace pluto {

enum class DitherKernel {
  kNone,
  kBayer4,
  kBlueNoise64,
  kFloydSteinberg,
};

struct ConvertConfig {
  uint32_t width = 954;
  uint32_t height = 1696;
  PlutoRefreshClass refresh_class = kPlutoRefreshUi;
  DitherKernel kernel = DitherKernel::kBlueNoise64;
  bool keep_antialias_for_fast = false;
  bool force_mono_fast = false;
};

// Per-pixel tone transform for the gray pipeline: applies the config's
// refresh-class policy (4-gray progressive fast, 16-gray otherwise) with the
// rect-local dither kernel indexed by absolute panel coordinates. Pen input is
// NOT composited here: it never synthesizes renderer pixels; apps own every
// pen-correlated pixel passed to AbiPresentBridge.
uint8_t convert_luma_pixel_gray(uint8_t luma,
                                int32_t absolute_x,
                                int32_t absolute_y,
                                const ConvertConfig& config);

void convert_rgb565_to_gray8_rect(const uint16_t* src_rgb565,
                                  size_t src_stride_bytes,
                                  uint8_t* dst_gray8,
                                  size_t dst_stride_bytes,
                                  const PlutoRect& rect,
                                  const ConvertConfig& config);

void convert_rgb565_to_gray8_full_error_diffusion(const uint16_t* src_rgb565,
                                                  size_t src_stride_bytes,
                                                  uint8_t* dst_gray8,
                                                  size_t dst_stride_bytes,
                                                  uint32_t width,
                                                  uint32_t height);

void convert_rgb888_to_rgb565_rect(const uint8_t* src_rgb,
                                   size_t src_stride_bytes,
                                   uint16_t* dst_rgb565,
                                   size_t dst_stride_bytes,
                                   const PlutoRect& rect);

}  // namespace pluto

#endif  // PLUTO_RENDERER_CONVERT_H_
