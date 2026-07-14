#include "presenter/swtcon/fast_rail_admit_kernels.h"

#if defined(__ARM_NEON) && defined(__aarch64__)

#include "presenter/swtcon/swtcon_waveform.h"

#include <arm_neon.h>

namespace pluto::swtcon {
namespace {

std::uint16_t movemask(uint8x16_t mask) {
  const uint8x16_t weights = {1, 2, 4, 8, 16, 32, 64, 128,
                              1, 2, 4, 8, 16, 32, 64, 128};
  const uint8x16_t bits = vandq_u8(mask, weights);
  return static_cast<std::uint16_t>(
      vaddv_u8(vget_low_u8(bits)) |
      (static_cast<std::uint16_t>(vaddv_u8(vget_high_u8(bits))) << 8));
}

} // namespace

bool fast_rail_levels_valid_neon(const std::uint8_t *levels, std::size_t stride,
                                 int width, int height) {
  if (levels == nullptr || width <= 0 || height <= 0 ||
      stride < static_cast<std::size_t>(width)) {
    return false;
  }
  const uint8x16_t mask5 = vdupq_n_u8(31u);
  const uint8x16_t black = vdupq_n_u8(kMode7FastBlackEndpoint);
  const uint8x16_t white = vdupq_n_u8(kMode7FastWhiteEndpoint);
  for (int y = 0; y < height; ++y) {
    const std::uint8_t *row = levels + static_cast<std::size_t>(y) * stride;
    int x = 0;
    for (; x + 16 <= width; x += 16) {
      const uint8x16_t target = vandq_u8(vld1q_u8(row + x), mask5);
      const uint8x16_t valid =
          vorrq_u8(vceqq_u8(target, black), vceqq_u8(target, white));
      if (vminvq_u8(valid) != 0xffu) {
        return false;
      }
    }
    for (; x < width; ++x) {
      const std::uint8_t target = static_cast<std::uint8_t>(row[x] & 31u);
      if (target != kMode7FastBlackEndpoint &&
          target != kMode7FastWhiteEndpoint) {
        return false;
      }
    }
  }
  return true;
}

FastRailStartRowResult
fast_rail_start_row_neon(const std::uint8_t *levels, std::uint8_t *prev,
                         std::uint8_t *next, std::uint8_t *final_levels,
                         std::uint8_t *fnum, std::uint8_t *waveform_drove,
                         int count) {
  FastRailStartRowResult result;
  const uint8x16_t mask5 = vdupq_n_u8(31u);
  const uint8x16_t black = vdupq_n_u8(kMode7FastBlackEndpoint);
  const uint8x16_t white = vdupq_n_u8(kMode7FastWhiteEndpoint);
  const uint8x16_t zero = vdupq_n_u8(0);
  int x = 0;
  for (; x + 16 <= count; x += 16) {
    const uint8x16_t target = vandq_u8(vld1q_u8(levels + x), mask5);
    const uint8x16_t old_prev = vld1q_u8(prev + x);
    const uint8x16_t started = vmvnq_u8(vceqq_u8(target, old_prev));
    const uint8x16_t opposite = vbslq_u8(vceqq_u8(target, black), white, black);
    const uint8x16_t rebased =
        vandq_u8(started, vmvnq_u8(vceqq_u8(old_prev, opposite)));

    vst1q_u8(final_levels + x, target);
    vst1q_u8(next + x, target);
    vst1q_u8(prev + x, vbslq_u8(rebased, opposite, old_prev));
    vst1q_u8(fnum + x, vbslq_u8(started, zero, vld1q_u8(fnum + x)));
    vst1q_u8(waveform_drove + x,
             vbslq_u8(started, zero, vld1q_u8(waveform_drove + x)));

    result.started |= static_cast<std::uint64_t>(movemask(started)) << x;
    result.rebased |= static_cast<std::uint64_t>(movemask(rebased)) << x;
  }
  if (x < count) {
    const FastRailStartRowResult tail = fast_rail_start_row_scalar(
        levels + x, prev + x, next + x, final_levels + x, fnum + x,
        waveform_drove + x, count - x);
    result.started |= tail.started << x;
    result.rebased |= tail.rebased << x;
  }
  return result;
}

} // namespace pluto::swtcon

#endif
