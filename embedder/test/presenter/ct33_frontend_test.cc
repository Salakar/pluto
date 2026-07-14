#include "presenter/swtcon/ct33_frontend.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <random>
#include <span>
#include <string>
#include <thread>
#include <vector>

namespace pluto::swtcon {
namespace {

std::vector<std::uint8_t> read_fixture() {
  std::ifstream in(PLUTO_CT33_FIXTURE, std::ios::binary);
  if (!in) {
    return {};
  }
  return std::vector<std::uint8_t>(std::istreambuf_iterator<char>(in),
                                   std::istreambuf_iterator<char>());
}

// Semantically valid synthetic cube. Away from the mandatory rail endpoint
// cells, slot s is linear in node coordinates: r + g + b + 20*s. That makes
// hand-computed tetrahedral interpolation goldens possible.
std::vector<std::uint8_t> make_linear_cube() {
  std::vector<std::uint8_t> blob(Ct33Frontend::kBlobBytes);
  for (int r = 0; r < Ct33Frontend::kCubeEdge; ++r) {
    for (int g = 0; g < Ct33Frontend::kCubeEdge; ++g) {
      for (int b = 0; b < Ct33Frontend::kCubeEdge; ++b) {
        const std::size_t cell =
            (static_cast<std::size_t>(r) * Ct33Frontend::kCubeEdge + g) *
                Ct33Frontend::kCubeEdge +
            b;
        for (int slot = 0; slot < Ct33Frontend::kThresholdSlots - 1;
             ++slot) {
          blob[cell * Ct33Frontend::kThresholdSlots + slot] =
              static_cast<std::uint8_t>(r + g + b + slot * 20);
        }
        blob[cell * Ct33Frontend::kThresholdSlots + 7] = 255u;
      }
    }
  }
  std::fill_n(blob.begin(), Ct33Frontend::kThresholdSlots, 255u);
  const std::size_t white =
      (Ct33Frontend::kCubeCells - 1u) * Ct33Frontend::kThresholdSlots;
  std::fill_n(blob.begin() + static_cast<std::ptrdiff_t>(white), 7, 0u);
  blob[white + 7u] = 255u;
  return blob;
}

std::vector<std::uint8_t> make_constant_cube() {
  std::vector<std::uint8_t> blob(Ct33Frontend::kBlobBytes);
  for (std::size_t cell = 0; cell < Ct33Frontend::kCubeCells; ++cell) {
    for (int slot = 0; slot < 7; ++slot) {
      blob[cell * Ct33Frontend::kThresholdSlots + slot] =
          static_cast<std::uint8_t>(slot);
    }
    blob[cell * Ct33Frontend::kThresholdSlots + 7] = 255u;
  }
  std::fill_n(blob.begin(), Ct33Frontend::kThresholdSlots, 255u);
  const std::size_t white =
      (Ct33Frontend::kCubeCells - 1u) * Ct33Frontend::kThresholdSlots;
  std::fill_n(blob.begin() + static_cast<std::ptrdiff_t>(white), 7, 0u);
  blob[white + 7u] = 255u;
  return blob;
}

std::array<std::uint16_t, Ct33Frontend::kThresholdSlots>
reference_interpolate(std::span<const std::uint8_t> blob, std::uint8_t r,
                      std::uint8_t g, std::uint8_t b) {
  struct Axis {
    int base;
    int fraction;
    int step;
  };
  const auto axis = [](std::uint8_t channel, int step) {
    return channel == 255u
               ? Axis{31, 8, step}
               : Axis{channel >> 3, channel & 7, step};
  };
  std::array<Axis, 3> axes{
      {axis(r, 1089), axis(g, 33), axis(b, 1)}};
  std::stable_sort(axes.begin(), axes.end(), [](const Axis& a, const Axis& b) {
    return a.fraction > b.fraction;
  });

  const int ri = r == 255u ? 31 : r >> 3;
  const int gi = g == 255u ? 31 : g >> 3;
  const int bi = b == 255u ? 31 : b >> 3;
  std::array<std::size_t, 4> cells{};
  cells[0] = static_cast<std::size_t>((ri * 33 + gi) * 33 + bi);
  for (int i = 0; i < 3; ++i) {
    cells[static_cast<std::size_t>(i + 1)] =
        cells[static_cast<std::size_t>(i)] +
        static_cast<std::size_t>(axes[static_cast<std::size_t>(i)].step);
  }
  const std::array<int, 4> weights{{
      8 - axes[0].fraction,
      axes[0].fraction - axes[1].fraction,
      axes[1].fraction - axes[2].fraction,
      axes[2].fraction,
  }};

  std::array<std::uint16_t, Ct33Frontend::kThresholdSlots> out{};
  for (int slot = 0; slot < Ct33Frontend::kThresholdSlots; ++slot) {
    int value = 0;
    for (int corner = 0; corner < 4; ++corner) {
      value += blob[cells[static_cast<std::size_t>(corner)] *
                        Ct33Frontend::kThresholdSlots +
                    static_cast<std::size_t>(slot)] *
               weights[static_cast<std::size_t>(corner)];
    }
    out[static_cast<std::size_t>(slot)] =
        static_cast<std::uint16_t>(value);
  }
  return out;
}

std::uint8_t reference_quantize(std::span<const std::uint8_t> blob,
                                std::uint8_t r, std::uint8_t g,
                                std::uint8_t b, std::int32_t x,
                                std::int32_t y) {
  const auto thresholds = reference_interpolate(blob, r, g, b);
  const std::uint16_t spatial = Ct33Frontend::spatial_threshold(x, y);
  return static_cast<std::uint8_t>(std::count_if(
      thresholds.begin(), thresholds.end(),
      [spatial](std::uint16_t value) { return value <= spatial; }));
}

std::uint8_t reference_outer(std::span<const std::uint8_t> blob,
                             std::uint8_t r, std::uint8_t g, std::uint8_t b,
                             std::int32_t x, std::int32_t y,
                             std::uint8_t select) {
  std::uint8_t encoded = reference_quantize(blob, r, g, b, x, y);
  if (select != 0u) {
    constexpr std::uint8_t palette[] = {10u, 8u, 9u, 11u};
    const std::uint32_t weighted = static_cast<std::uint32_t>(r) * 77u +
                                   static_cast<std::uint32_t>(g) * 150u +
                                   static_cast<std::uint32_t>(b) * 29u;
    const std::uint8_t luma = palette[(weighted >> 14u) & 3u];
    encoded = static_cast<std::uint8_t>(
        (select & luma) | (static_cast<std::uint8_t>(~select) & encoded));
  }
  if (r == 255u && g == 255u && b == 255u) {
    encoded = static_cast<std::uint8_t>(encoded | 0x80u);
  }
  return encoded;
}

std::uint64_t fnv1a64(std::span<const std::uint8_t> bytes) {
  std::uint64_t hash = 0xcbf29ce484222325ull;
  for (const std::uint8_t byte : bytes) {
    hash ^= byte;
    hash *= 0x100000001b3ull;
  }
  return hash;
}

TEST(Ct33FrontendTest, StrictValidationRejectsEveryClosedInvariant) {
  std::string error;
  EXPECT_FALSE(Ct33Frontend::validate_blob({}, &error));
  EXPECT_FALSE(error.empty());

  std::vector<std::uint8_t> blob = make_linear_cube();
  EXPECT_TRUE(Ct33Frontend::validate_blob(blob, &error));
  EXPECT_TRUE(error.empty());

  std::vector<std::uint8_t> short_blob(blob.begin(), blob.end() - 1);
  EXPECT_FALSE(Ct33Frontend::validate_blob(short_blob, &error));

  const std::size_t middle = (Ct33Frontend::kCubeCells / 2u) * 8u;
  std::vector<std::uint8_t> malformed = blob;
  malformed[middle + 2u] = 200u;
  malformed[middle + 3u] = 100u;
  EXPECT_FALSE(Ct33Frontend::validate_blob(malformed, &error));

  malformed = blob;
  malformed[middle + 7u] = 254u;
  EXPECT_FALSE(Ct33Frontend::validate_blob(malformed, &error));

  malformed = blob;
  malformed[0] = 254u;  // still sorted, but no longer the black rail cell
  EXPECT_FALSE(Ct33Frontend::validate_blob(malformed, &error));

  malformed = blob;
  const std::size_t white =
      (Ct33Frontend::kCubeCells - 1u) * Ct33Frontend::kThresholdSlots;
  std::fill_n(malformed.begin() + static_cast<std::ptrdiff_t>(white), 7, 1u);
  EXPECT_FALSE(Ct33Frontend::validate_blob(malformed, &error));
}

TEST(Ct33FrontendTest, ConfigureOwnsBlobAndFailedReconfigureClearsState) {
  std::vector<std::uint8_t> blob = make_linear_cube();
  Ct33Frontend frontend;
  std::string error;
  ASSERT_TRUE(frontend.configure(blob, &error));
  EXPECT_TRUE(frontend.valid());
  EXPECT_EQ(frontend.owned_bytes(),
            Ct33Frontend::kBlobBytes +
                Ct33Frontend::kRgb565Values *
                    Ct33Frontend::kThresholdSlots * sizeof(std::uint16_t) +
                Ct33Frontend::kRgb565Values * sizeof(std::uint8_t));

  std::array<std::uint16_t, 8> before{};
  ASSERT_TRUE(frontend.interpolate_rgb8(84, 82, 81, &before));
  std::fill(blob.begin(), blob.end(), 0u);
  std::array<std::uint16_t, 8> after{};
  ASSERT_TRUE(frontend.interpolate_rgb8(84, 82, 81, &after));
  EXPECT_TRUE(before == after);

  ASSERT_TRUE(!frontend.configure(std::span<const std::uint8_t>{}, &error));
  EXPECT_FALSE(frontend.valid());
  EXPECT_EQ(frontend.owned_bytes(), 0u);
  EXPECT_FALSE(frontend.interpolate_rgb8(0, 0, 0, &after));
  EXPECT_EQ(frontend.quantize_rgb8(255, 255, 255, 0, 0), 0u);
}

TEST(Ct33FrontendTest, TetrahedralWeightsAnd255EndpointAreExact) {
  const std::vector<std::uint8_t> blob = make_linear_cube();
  Ct33Frontend frontend;
  ASSERT_TRUE(frontend.configure(blob, nullptr));

  // Base node (10,10,10), fractions R=4,G=2,B=1. Corner weights are
  // {4,2,1,1}; for slot s the exact result is 8*(30+20*s)+7.
  std::array<std::uint16_t, 8> got{};
  ASSERT_TRUE(frontend.interpolate_rgb8(84, 82, 81, &got));
  const std::array<std::uint16_t, 8> expected{{
      247u, 407u, 567u, 727u, 887u, 1047u, 1207u, 2040u,
  }};
  EXPECT_TRUE(got == expected);

  // 255 is not base=31,fraction=7: Xochitl special-cases fraction=8.
  ASSERT_TRUE(frontend.interpolate_rgb8(255, 80, 81, &got));
  EXPECT_EQ(got[0], 417u);  // 8*(31+10+10) + (8+0+1)
  EXPECT_EQ(got[7], 2040u);
}

TEST(Ct33FrontendTest, SpatialFieldAndInclusiveComparisonAreExact) {
  EXPECT_EQ(Ct33Frontend::spatial_threshold(0, 0), 0u);
  EXPECT_EQ(Ct33Frontend::spatial_threshold(1, 0), 1466u);
  EXPECT_EQ(Ct33Frontend::spatial_threshold(31, 31), 2039u);
  EXPECT_EQ(Ct33Frontend::spatial_threshold(63, 63), 808u);
  EXPECT_EQ(Ct33Frontend::spatial_threshold(64, 64), 0u);
  EXPECT_EQ(Ct33Frontend::spatial_threshold(-1, -1), 808u);

  const std::vector<std::uint8_t> blob = make_constant_cube();
  Ct33Frontend frontend;
  ASSERT_TRUE(frontend.configure(blob, nullptr));
  // Mid-cube interpolants are exactly {0,8,16,24,32,40,48,2040}.
  // Threshold 32 includes equality; threshold 31 does not.
  EXPECT_EQ(frontend.quantize_rgb8(80, 80, 80, 56, 33), 5u);
  EXPECT_EQ(frontend.quantize_rgb8(80, 80, 80, 19, 14), 4u);
}

TEST(Ct33FrontendTest, OuterBytePlaneLumaSelectorAndWhiteMarkerAreExact) {
  const std::vector<std::uint8_t> blob = make_constant_cube();
  Ct33Frontend frontend;
  ASSERT_TRUE(frontend.configure(blob, nullptr));

  // Full selector chooses Xochitl's four-entry palette after the exact
  // 77R+150G+29B truncating luma reduction.
  EXPECT_EQ(frontend.encode_rgb8(0, 0, 0, 0, 0, 0xffu), 10u);
  EXPECT_EQ(frontend.encode_rgb8(64, 64, 64, 0, 0, 0xffu), 8u);
  EXPECT_EQ(frontend.encode_rgb8(128, 128, 128, 0, 0, 0xffu), 9u);
  EXPECT_EQ(frontend.encode_rgb8(192, 192, 192, 0, 0, 0xffu), 11u);
  EXPECT_EQ(frontend.encode_rgb8(255, 255, 255, 0, 0, 0xffu), 0x8bu);

  // The selector is bitwise BSL, not merely boolean. Here ct33 state 5 and
  // luma palette value 8 combine to 13 when only bit 3 is selected.
  EXPECT_EQ(frontend.quantize_rgb8(80, 80, 80, 56, 33), 5u);
  EXPECT_EQ(frontend.encode_rgb8(80, 80, 80, 56, 33, 0u), 5u);
  EXPECT_EQ(frontend.encode_rgb8(80, 80, 80, 56, 33, 0x08u), 13u);

  // White marker applies after either source is selected.
  EXPECT_EQ(frontend.quantize_rgb8(255, 255, 255, 0, 0), 7u);
  EXPECT_EQ(frontend.encode_rgb8(255, 255, 255, 0, 0), 0x87u);
}

TEST(Ct33FrontendTest, SpatialFieldFullGoldenHashAndDistribution) {
  std::vector<std::uint8_t> little_endian;
  little_endian.reserve(64u * 64u * 2u);
  std::array<int, 2040> counts{};
  for (int y = 0; y < 64; ++y) {
    for (int x = 0; x < 64; ++x) {
      const std::uint16_t value = Ct33Frontend::spatial_threshold(x, y);
      ASSERT_TRUE(value < counts.size());
      ++counts[value];
      little_endian.push_back(static_cast<std::uint8_t>(value));
      little_endian.push_back(static_cast<std::uint8_t>(value >> 8));
    }
  }
  EXPECT_EQ(fnv1a64(little_endian), 0x33027595a5d6e812ull);
  int triples = 0;
  for (const int count : counts) {
    EXPECT_TRUE(count == 2 || count == 3);
    triples += count == 3 ? 1 : 0;
  }
  EXPECT_EQ(triples, 16);
}

TEST(Ct33FrontendTest, RealBlobGoldenVectorsAndRegionHash) {
  const std::vector<std::uint8_t> blob = read_fixture();
  if (blob.empty()) {
#ifdef GTEST_SKIP
    GTEST_SKIP() << "ct33 fixture absent: " << PLUTO_CT33_FIXTURE;
#else
    return;
#endif
  }
  ASSERT_EQ(blob.size(), Ct33Frontend::kBlobBytes);
  EXPECT_EQ(fnv1a64(blob), 0x1034af11620e90eeull);
  Ct33Frontend frontend;
  std::string error;
  ASSERT_TRUE(frontend.configure(blob, &error)) << error;

  struct Golden {
    std::uint8_t r;
    std::uint8_t g;
    std::uint8_t b;
    int x;
    int y;
    std::array<std::uint16_t, 8> interpolants;
    std::uint8_t state;
  };
  const std::array<Golden, 7> goldens{{
      {0, 0, 0, 0, 0, {2040, 2040, 2040, 2040, 2040, 2040, 2040, 2040}, 0},
      {255, 255, 255, 0, 0, {0, 0, 0, 0, 0, 0, 0, 2040}, 7},
      {255, 0, 0, 1, 0, {0, 0, 2040, 2040, 2040, 2040, 2040, 2040}, 2},
      {0, 255, 0, 2, 0, {0, 0, 0, 0, 2040, 2040, 2040, 2040}, 4},
      {0, 0, 255, 3, 0, {0, 2040, 2040, 2040, 2040, 2040, 2040, 2040}, 1},
      {127, 91, 203, 17, 29, {314, 1522, 1628, 2040, 2040, 2040, 2040, 2040}, 1},
      {247, 248, 255, 64, 64, {0, 0, 0, 4, 4, 11, 11, 2040}, 3},
  }};
  for (const Golden& golden : goldens) {
    std::array<std::uint16_t, 8> got{};
    ASSERT_TRUE(frontend.interpolate_rgb8(golden.r, golden.g, golden.b, &got));
    EXPECT_TRUE(got == golden.interpolants);
    EXPECT_EQ(frontend.quantize_rgb8(golden.r, golden.g, golden.b, golden.x,
                                     golden.y),
              golden.state);
  }

  constexpr int kWidth = 16;
  constexpr int kHeight = 16;
  std::vector<std::uint8_t> rgb(kWidth * kHeight * 3u);
  for (int y = 0; y < kHeight; ++y) {
    for (int x = 0; x < kWidth; ++x) {
      const std::size_t offset =
          (static_cast<std::size_t>(y) * kWidth + x) * 3u;
      rgb[offset] = static_cast<std::uint8_t>(17 * x + 13 * y);
      rgb[offset + 1u] = static_cast<std::uint8_t>(3 * x + 29 * y + 7);
      rgb[offset + 2u] = static_cast<std::uint8_t>(31 * x + 5 * y + 11);
    }
  }
  std::vector<std::uint8_t> states(kWidth * kHeight);
  ASSERT_TRUE(frontend.convert_rgb888(rgb.data(), kWidth * 3u, 53, 61,
                                      kWidth, kHeight, states.data(), kWidth));
  EXPECT_EQ(fnv1a64(states), 0x92345bfebabab57cull);
  EXPECT_EQ(std::count(states.begin(), states.end(), 0u), 45);
  EXPECT_EQ(std::count(states.begin(), states.end(), 7u), 6);
}

TEST(Ct33FrontendTest, RandomParityAgainstIndependentScalarReference) {
  const std::vector<std::uint8_t> blob = make_linear_cube();
  Ct33Frontend frontend;
  ASSERT_TRUE(frontend.configure(blob, nullptr));
  std::mt19937 rng(0xc733f00du);
  std::uniform_int_distribution<int> byte(0, 255);
  std::uniform_int_distribution<int> coord(-4096, 4096);
  for (int i = 0; i < 10000; ++i) {
    const std::uint8_t r = static_cast<std::uint8_t>(byte(rng));
    const std::uint8_t g = static_cast<std::uint8_t>(byte(rng));
    const std::uint8_t b = static_cast<std::uint8_t>(byte(rng));
    const int x = coord(rng);
    const int y = coord(rng);
    std::array<std::uint16_t, 8> got{};
    ASSERT_TRUE(frontend.interpolate_rgb8(r, g, b, &got));
    EXPECT_TRUE(got == reference_interpolate(blob, r, g, b));
    EXPECT_EQ(frontend.quantize_rgb8(r, g, b, x, y),
              reference_quantize(blob, r, g, b, x, y));
  }
}

TEST(Ct33FrontendTest, ExhaustiveRgb565MatchesReplicatedRgb888) {
  const std::vector<std::uint8_t> blob = make_linear_cube();
  Ct33Frontend frontend;
  ASSERT_TRUE(frontend.configure(blob, nullptr));
  constexpr int kWidth = 256;
  constexpr int kHeight = 256;
  std::vector<std::uint8_t> rgb565(Ct33Frontend::kRgb565Values * 2u);
  std::vector<std::uint8_t> rgb888(Ct33Frontend::kRgb565Values * 3u);
  std::vector<std::uint8_t> independent(Ct33Frontend::kRgb565Values);
  for (std::uint32_t value = 0; value < Ct33Frontend::kRgb565Values; ++value) {
    rgb565[value * 2u] = static_cast<std::uint8_t>(value);
    rgb565[value * 2u + 1u] = static_cast<std::uint8_t>(value >> 8);
    const std::uint8_t r5 = static_cast<std::uint8_t>((value >> 11) & 31u);
    const std::uint8_t g6 = static_cast<std::uint8_t>((value >> 5) & 63u);
    const std::uint8_t b5 = static_cast<std::uint8_t>(value & 31u);
    rgb888[value * 3u] = static_cast<std::uint8_t>((r5 << 3) | (r5 >> 2));
    rgb888[value * 3u + 1u] =
        static_cast<std::uint8_t>((g6 << 2) | (g6 >> 4));
    rgb888[value * 3u + 2u] =
        static_cast<std::uint8_t>((b5 << 3) | (b5 >> 2));
    const int x = 13 + static_cast<int>(value & 255u);
    const int y = 27 + static_cast<int>(value >> 8u);
    independent[value] = reference_outer(
        blob, rgb888[value * 3u], rgb888[value * 3u + 1u],
        rgb888[value * 3u + 2u], x, y, 0u);
  }
  std::vector<std::uint8_t> from565(Ct33Frontend::kRgb565Values);
  std::vector<std::uint8_t> from888(Ct33Frontend::kRgb565Values);
  ASSERT_TRUE(frontend.convert_rgb565_le(rgb565.data(), kWidth * 2u, 13, 27,
                                         kWidth, kHeight, from565.data(),
                                         kWidth));
  ASSERT_TRUE(frontend.convert_rgb888(rgb888.data(), kWidth * 3u, 13, 27,
                                      kWidth, kHeight, from888.data(),
                                      kWidth));
  EXPECT_TRUE(from565 == from888);
  EXPECT_TRUE(from565 == independent);
}

TEST(Ct33FrontendTest,
     ExhaustiveRgb565SelectorShortcutsMatchIndependentOuterEncoding) {
  const std::vector<std::uint8_t> blob = make_linear_cube();
  Ct33Frontend frontend;
  ASSERT_TRUE(frontend.configure(blob, nullptr));
  constexpr int kWidth = 256;
  constexpr int kHeight = 256;
  constexpr int kOriginX = 13;
  constexpr int kOriginY = 27;
  std::vector<std::uint8_t> rgb565(Ct33Frontend::kRgb565Values * 2u);
  std::vector<std::uint8_t> selector(Ct33Frontend::kRgb565Values);
  std::vector<std::uint8_t> expected(Ct33Frontend::kRgb565Values);
  for (std::uint32_t value = 0; value < Ct33Frontend::kRgb565Values; ++value) {
    rgb565[value * 2u] = static_cast<std::uint8_t>(value);
    rgb565[value * 2u + 1u] = static_cast<std::uint8_t>(value >> 8);
    selector[value] = static_cast<std::uint8_t>(value);
    const std::uint8_t r5 = static_cast<std::uint8_t>((value >> 11) & 31u);
    const std::uint8_t g6 = static_cast<std::uint8_t>((value >> 5) & 63u);
    const std::uint8_t b5 = static_cast<std::uint8_t>(value & 31u);
    const std::uint8_t r =
        static_cast<std::uint8_t>((r5 << 3) | (r5 >> 2));
    const std::uint8_t g =
        static_cast<std::uint8_t>((g6 << 2) | (g6 >> 4));
    const std::uint8_t b =
        static_cast<std::uint8_t>((b5 << 3) | (b5 >> 2));
    const int x = static_cast<int>(value & 255u);
    const int y = static_cast<int>(value >> 8u);
    expected[value] = reference_outer(blob, r, g, b, kOriginX + x,
                                      kOriginY + y, selector[value]);
  }

  std::vector<std::uint8_t> actual(Ct33Frontend::kRgb565Values);
  ASSERT_TRUE(frontend.convert_rgb565_le(
      rgb565.data(), kWidth * 2u, kOriginX, kOriginY, kWidth, kHeight,
      actual.data(), kWidth, selector.data(), kWidth));
  EXPECT_TRUE(actual == expected);
  EXPECT_EQ(fnv1a64(actual), 17160323568974698956ull);
}

TEST(Ct33FrontendTest, ConfiguredFrontendSupportsConcurrentReaders) {
  const std::vector<std::uint8_t> blob = make_linear_cube();
  Ct33Frontend frontend;
  ASSERT_TRUE(frontend.configure(blob, nullptr));
  constexpr int kWidth = 64;
  constexpr int kHeight = 64;
  std::vector<std::uint8_t> source(kWidth * kHeight * 2u);
  for (std::size_t i = 0; i < source.size() / 2u; ++i) {
    const std::uint16_t pixel =
        static_cast<std::uint16_t>((i * 40503u + 17u) & 0xffffu);
    source[i * 2u] = static_cast<std::uint8_t>(pixel);
    source[i * 2u + 1u] = static_cast<std::uint8_t>(pixel >> 8);
  }
  std::vector<std::uint8_t> expected(kWidth * kHeight);
  ASSERT_TRUE(frontend.convert_rgb565_le(source.data(), kWidth * 2u, 29, 37,
                                         kWidth, kHeight, expected.data(),
                                         kWidth));
  const std::uint64_t expected_hash = fnv1a64(expected);

  std::array<std::uint64_t, 4> hashes{};
  std::array<std::thread, 4> workers;
  for (std::size_t worker = 0; worker < workers.size(); ++worker) {
    workers[worker] = std::thread([&, worker] {
      std::vector<std::uint8_t> output(kWidth * kHeight);
      std::uint64_t hash = 0;
      for (int iteration = 0; iteration < 32; ++iteration) {
        if (!frontend.convert_rgb565_le(
                source.data(), kWidth * 2u, 29, 37, kWidth, kHeight,
                output.data(), kWidth)) {
          hash = 1u;
          break;
        }
        hash ^= fnv1a64(output);
      }
      hashes[worker] = hash;
    });
  }
  for (std::thread& worker : workers) {
    worker.join();
  }
  // Thirty-two identical hashes XOR to zero; also pin the single-reader
  // result so an all-zero bug cannot satisfy the concurrency assertion.
  EXPECT_NE(expected_hash, 0u);
  for (const std::uint64_t hash : hashes) {
    EXPECT_EQ(hash, 0u);
  }
}

TEST(Ct33FrontendTest, RegionContractsAndStridesAreStrict) {
  const std::vector<std::uint8_t> blob = make_linear_cube();
  Ct33Frontend frontend;
  ASSERT_TRUE(frontend.configure(blob, nullptr));
  std::array<std::uint8_t, 32> src{};
  std::array<std::uint8_t, 32> out{};
  out.fill(0xeeu);

  EXPECT_TRUE(frontend.convert_rgb888(nullptr, 0, 0, 0, 0, 4, nullptr, 0));
  EXPECT_FALSE(frontend.convert_rgb888(src.data(), 8, 0, 0, 3, 1,
                                       out.data(), 3));
  EXPECT_FALSE(frontend.convert_rgb888(src.data(), 9, -1, 0, 3, 1,
                                       out.data(), 3));
  EXPECT_FALSE(frontend.convert_rgb565_le(nullptr, 6, 0, 0, 3, 1,
                                          out.data(), 3));
  EXPECT_FALSE(frontend.convert_rgb565_le(src.data(), 5, 0, 0, 3, 1,
                                          out.data(), 3));
  EXPECT_FALSE(frontend.convert_rgb565_le(src.data(), 6, 0, 0, 3, 1,
                                          out.data(), 3, nullptr, 3));
  EXPECT_FALSE(frontend.convert_rgb565_le(src.data(), 6, 0, 0, 3, 1,
                                          out.data(), 3, src.data(), 2));

  // Two rows with both input and output padding; only the 3x2 payload moves.
  src.fill(0xffu);
  ASSERT_TRUE(frontend.convert_rgb565_le(src.data(), 8, 63, 63, 3, 2,
                                         out.data(), 5));
  EXPECT_NE(out[0], 0xeeu);
  EXPECT_NE(out[1], 0xeeu);
  EXPECT_NE(out[2], 0xeeu);
  EXPECT_EQ(out[3], 0xeeu);
  EXPECT_EQ(out[4], 0xeeu);
  EXPECT_NE(out[5], 0xeeu);
  EXPECT_NE(out[6], 0xeeu);
  EXPECT_NE(out[7], 0xeeu);
  EXPECT_EQ(out[8], 0xeeu);
  EXPECT_EQ(out[9], 0xeeu);

  // 0xffff expands to exact RGB white: no selector -> ct33 state 7 plus
  // marker; full selector -> luma state 11 plus marker.
  EXPECT_EQ(out[0], 0x87u);
  std::array<std::uint8_t, 3> selector{{0xffu, 0xffu, 0xffu}};
  ASSERT_TRUE(frontend.convert_rgb565_le(src.data(), 8, 0, 0, 3, 1,
                                         out.data(), 5, selector.data(), 3));
  EXPECT_EQ(out[0], 0x8bu);
  EXPECT_EQ(out[1], 0x8bu);
  EXPECT_EQ(out[2], 0x8bu);
}

}  // namespace
}  // namespace pluto::swtcon
