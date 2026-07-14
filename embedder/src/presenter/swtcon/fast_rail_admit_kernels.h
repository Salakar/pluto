#ifndef PLUTO_PRESENTER_SWTCON_FAST_RAIL_ADMIT_KERNELS_H_
#define PLUTO_PRESENTER_SWTCON_FAST_RAIL_ADMIT_KERNELS_H_

#include <cstddef>
#include <cstdint>

namespace pluto::swtcon {

// Exact admission helpers for mode-7 safe Fast. Targets are legal when their
// low five bits are one of the certified endpoints; high bits are ignored,
// matching PixelEngine::admit's historical validation.
bool fast_rail_levels_valid_scalar(const std::uint8_t *levels,
                                   std::size_t stride, int width, int height);

#if defined(__ARM_NEON) && defined(__aarch64__)
bool fast_rail_levels_valid_neon(const std::uint8_t *levels, std::size_t stride,
                                 int width, int height);
#endif

inline bool fast_rail_levels_valid(const std::uint8_t *levels,
                                   std::size_t stride, int width, int height) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  return fast_rail_levels_valid_neon(levels, stride, width, height);
#else
  return fast_rail_levels_valid_scalar(levels, stride, width, height);
#endif
}

// Result masks are relative to the row's first lane. The helper is used only
// for an inactive tile with no estimated prev lanes at entry. It performs the
// exact per-lane state mutation formerly in start_tile; the caller owns DC
// estimate bookkeeping for the usually-empty rebase mask.
struct FastRailStartRowResult {
  std::uint64_t started = 0;
  std::uint64_t rebased = 0;
};

FastRailStartRowResult
fast_rail_start_row_scalar(const std::uint8_t *levels, std::uint8_t *prev,
                           std::uint8_t *next, std::uint8_t *final_levels,
                           std::uint8_t *fnum, std::uint8_t *waveform_drove,
                           int count);

#if defined(__ARM_NEON) && defined(__aarch64__)
FastRailStartRowResult
fast_rail_start_row_neon(const std::uint8_t *levels, std::uint8_t *prev,
                         std::uint8_t *next, std::uint8_t *final_levels,
                         std::uint8_t *fnum, std::uint8_t *waveform_drove,
                         int count);
#endif

inline FastRailStartRowResult
fast_rail_start_row(const std::uint8_t *levels, std::uint8_t *prev,
                    std::uint8_t *next, std::uint8_t *final_levels,
                    std::uint8_t *fnum, std::uint8_t *waveform_drove,
                    int count) {
#if defined(__ARM_NEON) && defined(__aarch64__)
  return fast_rail_start_row_neon(levels, prev, next, final_levels, fnum,
                                  waveform_drove, count);
#else
  return fast_rail_start_row_scalar(levels, prev, next, final_levels, fnum,
                                    waveform_drove, count);
#endif
}

} // namespace pluto::swtcon

#endif // PLUTO_PRESENTER_SWTCON_FAST_RAIL_ADMIT_KERNELS_H_
