#ifndef PLUTO_RENDERER_QUANTIZE_H_
#define PLUTO_RENDERER_QUANTIZE_H_

#include <cstddef>
#include <cstdint>

namespace pluto {

uint16_t rgb888_to_rgb565(uint8_t r, uint8_t g, uint8_t b);
void rgb888_to_rgb565(const uint8_t* src_rgb,
                      size_t src_stride_bytes,
                      uint16_t* dst_rgb565,
                      size_t dst_stride_bytes,
                      uint32_t width,
                      uint32_t height);

uint8_t rgb565_luma8(uint16_t rgb565);
bool rgb565_has_chroma(uint16_t rgb565);
uint8_t quantize_gray4(uint8_t luma, uint8_t threshold);
uint8_t quantize_gray16(uint8_t luma, uint8_t threshold);
uint8_t quantize_mono(uint8_t luma, uint8_t threshold);

// Full-frame Floyd-Steinberg error diffusion: RGB565 -> 16-level gray8.
// Byte-identical fast twin of the reference formulation (per pixel, raster
// order: old = clamp(rgb565_luma8(src) + err / 16, 0, 255);
// dst = quantize_gray16(old, 127); scatter (old - dst) with the classic
// 7/16 right, 3/16 below-left, 5/16 below, 1/16 below-right weights).
// convert_rgb565_to_gray8_full_error_diffusion() delegates here.
void error_diffuse_rgb565_gray16_full(const uint16_t* src_rgb565,
                                      size_t src_stride_bytes,
                                      uint8_t* dst_gray8,
                                      size_t dst_stride_bytes,
                                      uint32_t width,
                                      uint32_t height);

}  // namespace pluto

#endif  // PLUTO_RENDERER_QUANTIZE_H_
