#include <gtest/gtest.h>

#include <array>
#include <cstdint>
#include <random>
#include <vector>

#include "renderer/bluenoise_64.h"
#include "renderer/quantize.h"
#include "renderer/kernels.h"

namespace {

using pluto::SpanDiff;
using pluto::SpanSignificance;

}  // namespace

// The 16-level quantizer must select the exact level quantize_gray16 would
// for every (luma, threshold) pair; the legacy 8-bit output byte is the
// dequantized 5-bit level.
TEST(KernelsTest, Quantize16MatchesLegacyQuantizeGray16Everywhere) {
  for (int luma = 0; luma < 256; ++luma) {
    for (int thr = 0; thr < 256; ++thr) {
      const uint8_t luma8 = static_cast<uint8_t>(luma);
      const uint8_t thr8 = static_cast<uint8_t>(thr);
      uint8_t lvl5 = 0xaa;
      pluto::quantize16_span_scalar(&luma8, &thr8, 1, &lvl5);
      ASSERT_EQ(lvl5 % 2, 0) << "luma=" << luma << " thr=" << thr;
      ASSERT_TRUE(lvl5 <= pluto::kWhiteLevel5);
      ASSERT_EQ(static_cast<int>(pluto::level5_to_gray8(lvl5)),
                static_cast<int>(pluto::quantize_gray16(luma8, thr8)))
          << "luma=" << luma << " thr=" << thr;
    }
  }
}

TEST(KernelsTest, LumaFrom565MatchesLegacyForAllValues) {
  std::vector<uint16_t> src(65536);
  for (uint32_t v = 0; v < 65536; ++v) {
    src[v] = static_cast<uint16_t>(v);
  }
  std::vector<uint8_t> out(65536);
  pluto::luma_from_rgb565_span_scalar(src.data(), src.size(),
                                            out.data());
  for (uint32_t v = 0; v < 65536; ++v) {
    ASSERT_EQ(static_cast<int>(out[v]),
              static_cast<int>(pluto::rgb565_luma8(src[v])))
        << "rgb565=" << v;
  }
}

TEST(KernelsTest, ChromaMagFloorReproducesLegacyChromaPredicate) {
  std::vector<uint16_t> src(65536);
  for (uint32_t v = 0; v < 65536; ++v) {
    src[v] = static_cast<uint16_t>(v);
  }
  std::vector<uint8_t> mag(65536);
  pluto::chroma_mag_from_rgb565_span_scalar(src.data(), src.size(),
                                                  mag.data());
  for (uint32_t v = 0; v < 65536; ++v) {
    ASSERT_EQ(mag[v] > 12, pluto::rgb565_has_chroma(src[v]))
        << "rgb565=" << v;
  }
}

TEST(KernelsTest, ExpandTablesMatchLegacyChannelExpansion) {
  // rgb565_luma8 expands with rounding: c8 = (c * 255 + max/2) / max.
  for (uint32_t i = 0; i < 32; ++i) {
    EXPECT_EQ(static_cast<uint32_t>(pluto::k_expand5[i]),
              (i * 255u + 15u) / 31u);
  }
  for (uint32_t i = 0; i < 64; ++i) {
    EXPECT_EQ(static_cast<uint32_t>(pluto::k_expand6[i]),
              (i * 255u + 31u) / 63u);
  }
}

TEST(KernelsTest, Level5ToGray8MapsEvenLevelsToLegacyBytes) {
  for (uint32_t i = 0; i < 16; ++i) {
    EXPECT_EQ(static_cast<uint32_t>(
                  pluto::level5_to_gray8(static_cast<uint8_t>(2 * i))),
              17u * i);
  }
  // The invalid-level sentinel dequantizes as paper white.
  EXPECT_EQ(pluto::level5_to_gray8(pluto::kInvalidLevel5), 255);
  EXPECT_EQ(pluto::level5_to_gray8(pluto::kWhiteLevel5), 255);
}

TEST(KernelsTest, BluenoiseThresholdSpanMatchesMaskIncludingWrap) {
  uint8_t scratch[64];
  for (int32_t y = 0; y < 130; y += 11) {
    for (int32_t x0 = 0; x0 < 70; x0 += 7) {
      for (size_t n : {size_t{1}, size_t{13}, size_t{32}, size_t{64}}) {
        const uint8_t* thr =
            pluto::bluenoise_threshold_span(x0, y, n, scratch);
        for (size_t i = 0; i < n; ++i) {
          ASSERT_EQ(static_cast<int>(thr[i]),
                    static_cast<int>(pluto::blue_noise_64_at(
                        x0 + static_cast<int32_t>(i), y)))
              << "x0=" << x0 << " y=" << y << " n=" << n << " i=" << i;
        }
      }
    }
  }
}

TEST(KernelsTest, DiffSpanCountsAndBounds) {
  const uint8_t a[8] = {1, 2, 3, 4, 5, 6, 7, 8};
  const uint8_t b[8] = {1, 9, 3, 4, 5, 9, 9, 8};
  const SpanDiff diff = pluto::diff_span_scalar(a, b, 8);
  EXPECT_EQ(diff.changed, 3u);
  EXPECT_EQ(diff.first, 1);
  EXPECT_EQ(diff.last, 6);

  const SpanDiff none = pluto::diff_span_scalar(a, a, 8);
  EXPECT_EQ(none.changed, 0u);
  EXPECT_EQ(none.first, -1);
  EXPECT_EQ(none.last, -1);
}

TEST(KernelsTest, SignificanceDequantizesOldLevelsAndClampsSentinel) {
  const uint8_t luma[4] = {200, 255, 0, 100};
  const uint8_t old_lvl5[4] = {pluto::kInvalidLevel5,  // white 255
                               pluto::kWhiteLevel5,    // white 255
                               0,                            // black 0
                               17};                          // odd level
  const SpanSignificance sig =
      pluto::significance_span_scalar(luma, old_lvl5, 4);
  const int gray17 = pluto::level5_to_gray8(17);
  const uint32_t expected_sad =
      55u + 0u + 0u + static_cast<uint32_t>(gray17 > 100 ? gray17 - 100
                                                         : 100 - gray17);
  EXPECT_EQ(sig.sad, expected_sad);
  EXPECT_EQ(static_cast<int>(sig.max_diff), 55);
}

TEST(KernelsTest, LevelHistBitsMarkPresence) {
  const uint8_t lvl5[5] = {0, 30, 30, 10, 2};
  const uint16_t bits = pluto::level_hist_bits_span_scalar(lvl5, 5);
  EXPECT_EQ(bits, static_cast<uint16_t>((1u << 0) | (1u << 15) | (1u << 5) |
                                        (1u << 1)));
}

TEST(KernelsTest, RowHashIsOrderSensitiveAndChainable) {
  const uint8_t ab[2] = {'a', 'b'};
  const uint8_t ba[2] = {'b', 'a'};
  EXPECT_NE(pluto::hash_row_fnv1a(ab, 2),
            pluto::hash_row_fnv1a(ba, 2));
  // Chaining across spans by seeding with the prior state equals the
  // one-shot hash of the concatenation.
  const uint32_t chained = pluto::hash_row_fnv1a(
      ab + 1, 1, pluto::hash_row_fnv1a(ab, 1));
  EXPECT_EQ(chained, pluto::hash_row_fnv1a(ab, 2));
}

TEST(KernelsTest, LevelsToRgb565ExpandsGrayLegacyCompatible) {
  uint8_t lvl5[17];
  for (uint32_t i = 0; i < 16; ++i) {
    lvl5[i] = static_cast<uint8_t>(2 * i);
  }
  lvl5[16] = pluto::kInvalidLevel5;
  uint16_t out[17];
  pluto::levels_to_rgb565_span_scalar(lvl5, 17, out);
  for (uint32_t i = 0; i < 16; ++i) {
    const uint8_t gray = static_cast<uint8_t>(17u * i);
    ASSERT_EQ(out[i], pluto::rgb888_to_rgb565(gray, gray, gray)) << "i=" << i;
  }
  EXPECT_EQ(out[16], pluto::rgb888_to_rgb565(255, 255, 255));

  uint8_t gray_out[17];
  pluto::levels_to_gray8_span_scalar(lvl5, 17, gray_out);
  for (uint32_t i = 0; i < 16; ++i) {
    ASSERT_EQ(static_cast<uint32_t>(gray_out[i]), 17u * i) << "i=" << i;
  }
}

// ---------------------------------------------------------------------------
// NEON golden tests: every vector kernel must be byte-exact vs its scalar
// reference over random and structured spans (random lengths and offsets so
// both the vector body and the scalar tails are exercised). On non-NEON
// hosts the dispatchers alias the scalar references and there is nothing to
// compare, so the body compiles away.
// ---------------------------------------------------------------------------

#if defined(__ARM_NEON) && defined(__aarch64__)
namespace {

struct KernelFuzzInputs {
  std::vector<uint16_t> rgb565;
  std::vector<uint8_t> xrgb;
  std::vector<uint8_t> luma;
  std::vector<uint8_t> thresholds;
  std::vector<uint8_t> levels;  // valid 5-bit levels + occasional sentinel
  std::vector<uint8_t> old_plane;
  std::vector<uint8_t> bytes_a;
  std::vector<uint8_t> bytes_b;
};

KernelFuzzInputs make_inputs(std::mt19937* rng, size_t n, int structure) {
  std::uniform_int_distribution<uint32_t> u16(0, 0xffff);
  std::uniform_int_distribution<uint32_t> u8(0, 0xff);
  std::uniform_int_distribution<uint32_t> lvl(0, 15);
  KernelFuzzInputs in;
  in.rgb565.resize(n);
  in.xrgb.resize(n * 4);
  in.luma.resize(n);
  in.thresholds.resize(n);
  in.levels.resize(n);
  in.old_plane.resize(n);
  in.bytes_a.resize(n);
  in.bytes_b.resize(n);
  for (size_t i = 0; i < n; ++i) {
    switch (structure) {
      case 0:  // random
        in.rgb565[i] = static_cast<uint16_t>(u16(*rng));
        in.luma[i] = static_cast<uint8_t>(u8(*rng));
        break;
      case 1:  // constant white
        in.rgb565[i] = 0xffff;
        in.luma[i] = 255;
        break;
      case 2:  // ramp
        in.rgb565[i] = static_cast<uint16_t>((i * 257u) & 0xffffu);
        in.luma[i] = static_cast<uint8_t>(i & 0xffu);
        break;
      default:  // alternating rails
        in.rgb565[i] = (i & 1u) ? 0xffff : 0x0000;
        in.luma[i] = (i & 1u) ? 255 : 0;
        break;
    }
    in.xrgb[i * 4 + 0] = static_cast<uint8_t>(u8(*rng));
    in.xrgb[i * 4 + 1] = static_cast<uint8_t>(u8(*rng));
    in.xrgb[i * 4 + 2] = static_cast<uint8_t>(u8(*rng));
    in.xrgb[i * 4 + 3] = static_cast<uint8_t>(u8(*rng));
    in.thresholds[i] = static_cast<uint8_t>(u8(*rng));
    in.levels[i] = (u8(*rng) < 8) ? pluto::kInvalidLevel5
                                  : static_cast<uint8_t>(2u * lvl(*rng));
    in.old_plane[i] = (u8(*rng) < 8) ? pluto::kInvalidLevel5
                                     : static_cast<uint8_t>(2u * lvl(*rng));
    in.bytes_a[i] = static_cast<uint8_t>(u8(*rng));
    // bytes_b mostly equals bytes_a so diff spans are sparse.
    in.bytes_b[i] = (u8(*rng) < 32) ? static_cast<uint8_t>(u8(*rng))
                                    : in.bytes_a[i];
  }
  return in;
}

}  // namespace

TEST(KernelsNeonGolden, AllKernelsMatchScalarOnRandomAndStructuredSpans) {
  std::mt19937 rng(0xbeefcafe);
  std::uniform_int_distribution<size_t> len_dist(1, 96);
  for (int iteration = 0; iteration < 512; ++iteration) {
    const size_t n = (iteration % 17 == 0) ? 1024 : len_dist(rng);
    const int structure = iteration % 4;
    const KernelFuzzInputs in = make_inputs(&rng, n, structure);

    std::vector<uint8_t> scalar_u8(n);
    std::vector<uint8_t> neon_u8(n);

    pluto::luma_from_rgb565_span_scalar(in.rgb565.data(), n,
                                              scalar_u8.data());
    pluto::luma_from_rgb565_span_neon(in.rgb565.data(), n,
                                            neon_u8.data());
    for (size_t i = 0; i < n; ++i) {
      ASSERT_EQ(scalar_u8[i], neon_u8[i])
          << "luma565 iter=" << iteration << " i=" << i;
    }

    pluto::luma_from_xrgb8888_span_scalar(in.xrgb.data(), n,
                                                scalar_u8.data());
    pluto::luma_from_xrgb8888_span_neon(in.xrgb.data(), n,
                                              neon_u8.data());
    for (size_t i = 0; i < n; ++i) {
      ASSERT_EQ(scalar_u8[i], neon_u8[i])
          << "luma8888 iter=" << iteration << " i=" << i;
    }

    pluto::chroma_mag_from_rgb565_span_scalar(in.rgb565.data(), n,
                                                    scalar_u8.data());
    pluto::chroma_mag_from_rgb565_span_neon(in.rgb565.data(), n,
                                                  neon_u8.data());
    for (size_t i = 0; i < n; ++i) {
      ASSERT_EQ(scalar_u8[i], neon_u8[i])
          << "chroma565 iter=" << iteration << " i=" << i;
    }

    pluto::chroma_mag_from_xrgb8888_span_scalar(in.xrgb.data(), n,
                                                      scalar_u8.data());
    pluto::chroma_mag_from_xrgb8888_span_neon(in.xrgb.data(), n,
                                                    neon_u8.data());
    for (size_t i = 0; i < n; ++i) {
      ASSERT_EQ(scalar_u8[i], neon_u8[i])
          << "chroma8888 iter=" << iteration << " i=" << i;
    }

    pluto::quantize16_span_scalar(in.luma.data(), in.thresholds.data(),
                                        n, scalar_u8.data());
    pluto::quantize16_span_neon(in.luma.data(), in.thresholds.data(), n,
                                      neon_u8.data());
    for (size_t i = 0; i < n; ++i) {
      ASSERT_EQ(scalar_u8[i], neon_u8[i])
          << "quantize16 iter=" << iteration << " i=" << i
          << " luma=" << static_cast<int>(in.luma[i])
          << " thr=" << static_cast<int>(in.thresholds[i]);
    }

    const SpanDiff diff_scalar =
        pluto::diff_span_scalar(in.bytes_a.data(), in.bytes_b.data(), n);
    const SpanDiff diff_neon =
        pluto::diff_span_neon(in.bytes_a.data(), in.bytes_b.data(), n);
    ASSERT_EQ(diff_scalar.changed, diff_neon.changed) << "iter=" << iteration;
    ASSERT_EQ(diff_scalar.first, diff_neon.first) << "iter=" << iteration;
    ASSERT_EQ(diff_scalar.last, diff_neon.last) << "iter=" << iteration;

    const SpanSignificance sig_scalar = pluto::significance_span_scalar(
        in.luma.data(), in.old_plane.data(), n);
    const SpanSignificance sig_neon = pluto::significance_span_neon(
        in.luma.data(), in.old_plane.data(), n);
    ASSERT_EQ(sig_scalar.sad, sig_neon.sad) << "iter=" << iteration;
    ASSERT_EQ(sig_scalar.max_diff, sig_neon.max_diff) << "iter=" << iteration;

    for (uint8_t floor : {uint8_t{0}, uint8_t{12}, uint8_t{200}}) {
      ASSERT_EQ(
          pluto::count_above_span_scalar(in.bytes_a.data(), floor, n),
          pluto::count_above_span_neon(in.bytes_a.data(), floor, n))
          << "iter=" << iteration << " floor=" << static_cast<int>(floor);
    }

    pluto::levels_to_gray8_span_scalar(in.levels.data(), n,
                                             scalar_u8.data());
    pluto::levels_to_gray8_span_neon(in.levels.data(), n,
                                           neon_u8.data());
    for (size_t i = 0; i < n; ++i) {
      ASSERT_EQ(scalar_u8[i], neon_u8[i])
          << "levels_to_gray8 iter=" << iteration << " i=" << i;
    }

    std::vector<uint16_t> scalar_u16(n);
    std::vector<uint16_t> neon_u16(n);
    pluto::levels_to_rgb565_span_scalar(in.levels.data(), n,
                                              scalar_u16.data());
    pluto::levels_to_rgb565_span_neon(in.levels.data(), n,
                                            neon_u16.data());
    for (size_t i = 0; i < n; ++i) {
      ASSERT_EQ(scalar_u16[i], neon_u16[i])
          << "levels_to_rgb565 iter=" << iteration << " i=" << i;
    }
  }
}
#endif  // __ARM_NEON && __aarch64__
