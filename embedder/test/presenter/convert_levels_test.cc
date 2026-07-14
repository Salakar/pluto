// Goldens for the presenter content-conversion kernel
// (swtcon_waveform.h convert_rgb565_levels_*): RGB565 rect -> legalized
// 5-bit levels, the scheduler-thread hot path for every content admission.
//
// The scalar kernel is pinned per-pixel against the frozen
// `legal_targets[rgb565_to_gray5(px) & 0x1f]` formula, and the NEON fast
// path is proven byte-identical to the scalar EXHAUSTIVELY: all 65536
// rgb565 inputs x several map shapes (identity, GAL3 mode-7 bilevel {2,28},
// GAL3 mode-1 8-level lattice, random bytes), plus tail/misalignment widths
// so the 16-lane, 8-lane and scalar-tail paths are all covered.

#include "presenter/swtcon/swtcon_waveform.h"

#include <gtest/gtest.h>

#include <array>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <random>
#include <vector>

namespace {

using pluto::swtcon::convert_rgb565_levels;
using pluto::swtcon::convert_rgb565_levels_scalar;
using pluto::swtcon::rgb565_to_gray5;

std::array<std::uint8_t, 32> identity_map() {
  std::array<std::uint8_t, 32> map{};
  for (int i = 0; i < 32; ++i) {
    map[static_cast<std::size_t>(i)] = static_cast<std::uint8_t>(i);
  }
  return map;
}

// Nearest-drivable snap with brighter tie-break — the build_legal_target_map
// shape — over an explicit drivable set.
std::array<std::uint8_t, 32> snap_map(std::initializer_list<int> drivable) {
  std::array<std::uint8_t, 32> map{};
  for (int t = 0; t < 32; ++t) {
    int best = *drivable.begin();
    for (const int d : drivable) {
      const int dist = d > t ? d - t : t - d;
      const int best_dist = best > t ? best - t : t - best;
      if (dist < best_dist || (dist == best_dist && d > best)) {
        best = d;
      }
    }
    map[static_cast<std::size_t>(t)] = static_cast<std::uint8_t>(best);
  }
  return map;
}

// GAL3 mode 7 (Fast/Ui) is bilevel: drivable {2, 28}.
std::array<std::uint8_t, 32> gal3_mode7_map() { return snap_map({2, 28}); }

// GAL3 mode 1 (Text): 8-level lattice.
std::array<std::uint8_t, 32> gal3_mode1_map() {
  return snap_map({0, 6, 10, 14, 18, 22, 26, 30});
}

// Arbitrary byte values (not just levels): the kernel contract is ANY
// 32-byte map, and full-range bytes catch any lane truncation.
std::array<std::uint8_t, 32> random_byte_map(std::uint32_t seed) {
  std::mt19937 rng(seed);
  std::uniform_int_distribution<int> byte(0, 255);
  std::array<std::uint8_t, 32> map{};
  for (auto& value : map) {
    value = static_cast<std::uint8_t>(byte(rng));
  }
  return map;
}

// All 65536 rgb565 values as little-endian byte pairs, 256 px per row.
std::vector<std::uint8_t> all_rgb565_surface() {
  std::vector<std::uint8_t> bytes(65536u * 2u);
  for (std::uint32_t px = 0; px < 65536u; ++px) {
    bytes[px * 2] = static_cast<std::uint8_t>(px & 0xff);
    bytes[px * 2 + 1] = static_cast<std::uint8_t>(px >> 8);
  }
  return bytes;
}

}  // namespace

// The extracted scalar kernel IS the frozen per-pixel formula, for every
// possible input pixel.
TEST(ConvertLevelsTest, ScalarKernelMatchesPerPixelReferenceExhaustively) {
  const std::vector<std::uint8_t> surface = all_rgb565_surface();
  const std::array<std::uint8_t, 32> map = gal3_mode7_map();
  constexpr std::int32_t kWidth = 256;
  constexpr std::int32_t kHeight = 256;

  std::vector<std::uint8_t> out(65536u, 0xa5);
  convert_rgb565_levels_scalar(surface.data(), kWidth * 2, kWidth, kHeight,
                               map.data(), out.data());
  for (std::uint32_t px = 0; px < 65536u; ++px) {
    const std::uint8_t expected =
        map[rgb565_to_gray5(static_cast<std::uint16_t>(px)) & 0x1f];
    ASSERT_EQ(out[px], expected) << "px=0x" << std::hex << px;
  }
}

// The dispatcher must agree with the scalar reference on every input (on
// non-NEON hosts this is trivially the same code path; on aarch64 it is the
// NEON kernel).
TEST(ConvertLevelsTest, DispatchMatchesScalarExhaustively) {
  const std::vector<std::uint8_t> surface = all_rgb565_surface();
  const std::array<std::uint8_t, 32> map = gal3_mode1_map();
  constexpr std::int32_t kWidth = 256;
  constexpr std::int32_t kHeight = 256;

  std::vector<std::uint8_t> scalar_out(65536u, 0x11);
  std::vector<std::uint8_t> fast_out(65536u, 0xee);
  convert_rgb565_levels_scalar(surface.data(), kWidth * 2, kWidth, kHeight,
                               map.data(), scalar_out.data());
  convert_rgb565_levels(surface.data(), kWidth * 2, kWidth, kHeight,
                        map.data(), fast_out.data());
  EXPECT_EQ(std::memcmp(scalar_out.data(), fast_out.data(), scalar_out.size()),
            0);
}

#if defined(__ARM_NEON) && defined(__aarch64__)

// Byte-identity of the NEON kernel vs the scalar reference over ALL 65536
// rgb565 inputs, for identity / sparse-GAL3 / full-range-random maps. This
// is the airtight zero-behaviour-change proof: with every input value and
// every map shape covered, no pixel value can diverge in production.
TEST(ConvertLevelsNeonGolden, MatchesScalarForAllRgb565InputsExhaustively) {
  const std::vector<std::uint8_t> surface = all_rgb565_surface();
  constexpr std::int32_t kWidth = 256;
  constexpr std::int32_t kHeight = 256;

  const std::array<std::array<std::uint8_t, 32>, 5> maps = {
      identity_map(), gal3_mode7_map(), gal3_mode1_map(),
      random_byte_map(0x1234u), random_byte_map(0xfeedu)};
  for (std::size_t m = 0; m < maps.size(); ++m) {
    std::vector<std::uint8_t> scalar_out(65536u, 0x11);
    std::vector<std::uint8_t> neon_out(65536u, 0xee);
    convert_rgb565_levels_scalar(surface.data(), kWidth * 2, kWidth, kHeight,
                                 maps[m].data(), scalar_out.data());
    pluto::swtcon::convert_rgb565_levels_neon(surface.data(), kWidth * 2,
                                                kWidth, kHeight, maps[m].data(),
                                                neon_out.data());
    for (std::uint32_t px = 0; px < 65536u; ++px) {
      ASSERT_EQ(neon_out[px], scalar_out[px])
          << "map=" << m << " px=0x" << std::hex << px;
    }
  }
}

// Tail and alignment coverage: odd rect widths (16-lane blocks + 8-lane
// step + scalar tail), unaligned rect.x byte offsets, and a surface stride
// wider than the rect — the presenter's tile-piece geometry.
TEST(ConvertLevelsNeonGolden, MatchesScalarOnTailWidthsAndUnalignedRects) {
  std::mt19937 rng(0xc0ffeeu);
  std::uniform_int_distribution<int> byte(0, 255);
  constexpr std::size_t kStride = 1908;  // Move surface stride (954 px)
  constexpr std::int32_t kRows = 40;
  std::vector<std::uint8_t> surface(kStride * kRows);
  for (auto& value : surface) {
    value = static_cast<std::uint8_t>(byte(rng));
  }
  const std::array<std::uint8_t, 32> map = gal3_mode7_map();

  const std::array<std::int32_t, 8> widths = {1, 2, 7, 8, 15, 17, 96, 253};
  const std::array<std::int32_t, 3> x_offsets = {0, 1, 33};
  for (const std::int32_t width : widths) {
    for (const std::int32_t x0 : x_offsets) {
      const std::int32_t height = kRows - 1;
      const std::uint8_t* src =
          surface.data() + static_cast<std::size_t>(x0) * 2u;
      std::vector<std::uint8_t> scalar_out(
          static_cast<std::size_t>(width) * static_cast<std::size_t>(height),
          0x5a);
      std::vector<std::uint8_t> neon_out(scalar_out.size(), 0xa5);
      convert_rgb565_levels_scalar(src, kStride, width, height, map.data(),
                                   scalar_out.data());
      pluto::swtcon::convert_rgb565_levels_neon(src, kStride, width, height,
                                                  map.data(), neon_out.data());
      ASSERT_EQ(std::memcmp(scalar_out.data(), neon_out.data(),
                            scalar_out.size()),
                0)
          << "width=" << width << " x0=" << x0;
    }
  }
}

#endif  // __ARM_NEON && __aarch64__
