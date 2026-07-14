#include "presenter/swtcon/fast_rail_admit_kernels.h"

#include "presenter/swtcon/swtcon_waveform.h"

namespace pluto::swtcon {

bool fast_rail_levels_valid_scalar(const std::uint8_t *levels,
                                   std::size_t stride, int width, int height) {
  if (levels == nullptr || width <= 0 || height <= 0 ||
      stride < static_cast<std::size_t>(width)) {
    return false;
  }
  for (int y = 0; y < height; ++y) {
    const std::uint8_t *row = levels + static_cast<std::size_t>(y) * stride;
    for (int x = 0; x < width; ++x) {
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
fast_rail_start_row_scalar(const std::uint8_t *levels, std::uint8_t *prev,
                           std::uint8_t *next, std::uint8_t *final_levels,
                           std::uint8_t *fnum, std::uint8_t *waveform_drove,
                           int count) {
  FastRailStartRowResult result;
  for (int x = 0; x < count; ++x) {
    const std::uint8_t target = static_cast<std::uint8_t>(levels[x] & 31u);
    final_levels[x] = target;
    next[x] = target;
    if (target == prev[x]) {
      continue;
    }
    const std::uint64_t bit = std::uint64_t{1} << x;
    result.started |= bit;
    const std::uint8_t opposite = target == kMode7FastBlackEndpoint
                                      ? kMode7FastWhiteEndpoint
                                      : kMode7FastBlackEndpoint;
    if (prev[x] != opposite) {
      prev[x] = opposite;
      result.rebased |= bit;
    }
    waveform_drove[x] = 0;
    fnum[x] = 0;
  }
  return result;
}

} // namespace pluto::swtcon
