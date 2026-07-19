// RM1 warm-handoff optical-state A/B. This compares the exact renderer
// arithmetic against the generated RGB565 lookup used by stage/import. The
// target cross-builds with the ARMv7 release embedder so acceptance can run on
// the Cortex-A9 tablet rather than extrapolating from a host CPU.

#include "generated/rm1_rgb565_optical_lut.h"
#include "renderer/quantize.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

constexpr std::size_t kPanelPixels = 1404u * 1872u;
constexpr int kWarmupIterations = 4;
constexpr int kDefaultIterations = 40;

struct Timing final {
  double min_us = 0.0;
  double p50_us = 0.0;
  double p95_us = 0.0;
  double p99_us = 0.0;
  double max_us = 0.0;
};

std::uint8_t arithmetic_optical_level(std::uint16_t pixel) {
  const std::uint8_t gray8 =
      pluto::quantize_gray16(pluto::rgb565_luma8(pixel), 127);
  return static_cast<std::uint8_t>((gray8 / 17u) * 2u);
}

Timing timing(std::vector<double> samples) {
  std::sort(samples.begin(), samples.end());
  return {
      .min_us = samples.front(),
      .p50_us = samples[samples.size() / 2u],
      .p95_us = samples[((samples.size() - 1u) * 95u) / 100u],
      .p99_us = samples[((samples.size() - 1u) * 99u) / 100u],
      .max_us = samples.back(),
  };
}

template <typename Convert>
std::pair<double, std::uint64_t>
measure_once(const std::vector<std::uint16_t> &pixels,
             std::vector<std::uint8_t> *output, Convert convert) {
  std::uint64_t checksum = 0;
  const auto begin = Clock::now();
  for (std::size_t index = 0; index < pixels.size(); ++index) {
    const std::uint8_t level = convert(pixels[index]);
    (*output)[index] = level;
    checksum += level;
  }
  const auto end = Clock::now();
  return {
      std::chrono::duration<double, std::micro>(end - begin).count(),
      checksum,
  };
}

} // namespace

int main(int argc, char **argv) {
  int iterations = kDefaultIterations;
  if (argc == 2) {
    iterations = std::atoi(argv[1]);
  }
  if (argc > 2 || iterations < 30 || iterations > 500) {
    std::fprintf(stderr,
                 "usage: rm1_handoff_lut_bench [measured-iterations:30..500]"
                 "\n");
    return 2;
  }

  const auto &lut = pluto::native::mxcfb::kRm1Rgb565OpticalLevelLut;
  for (std::uint32_t pixel = 0; pixel <= 0xffffu; ++pixel) {
    const std::uint8_t expected =
        arithmetic_optical_level(static_cast<std::uint16_t>(pixel));
    if (lut[pixel] != expected) {
      std::fprintf(stderr,
                   "generated LUT drift at RGB565=%u actual=%u expected=%u\n",
                   pixel, static_cast<unsigned>(lut[pixel]),
                   static_cast<unsigned>(expected));
      return 1;
    }
  }

  std::vector<std::uint16_t> pixels(kPanelPixels);
  std::vector<std::uint8_t> output(kPanelPixels);
  std::uint32_t random = 0x91e10da5u;
  for (std::uint16_t &pixel : pixels) {
    random = random * 1664525u + 1013904223u;
    pixel = static_cast<std::uint16_t>(random >> 8u);
  }

  std::vector<double> arithmetic_samples;
  std::vector<double> lut_samples;
  arithmetic_samples.reserve(static_cast<std::size_t>(iterations));
  lut_samples.reserve(static_cast<std::size_t>(iterations));
  std::uint64_t arithmetic_checksum = 0;
  std::uint64_t lut_checksum = 0;
  for (int iteration = -kWarmupIterations; iteration < iterations;
       ++iteration) {
    const auto run_arithmetic = [&] {
      const auto sample =
          measure_once(pixels, &output, [](std::uint16_t pixel) {
            return arithmetic_optical_level(pixel);
          });
      if (iteration >= 0) {
        arithmetic_samples.push_back(sample.first);
        arithmetic_checksum +=
            sample.second + static_cast<std::uint64_t>(iteration);
      }
      return sample.second;
    };
    const auto run_lut = [&] {
      const auto sample =
          measure_once(pixels, &output, [](std::uint16_t pixel) {
            return pluto::native::mxcfb::kRm1Rgb565OpticalLevelLut[pixel];
          });
      if (iteration >= 0) {
        lut_samples.push_back(sample.first);
        lut_checksum += sample.second + static_cast<std::uint64_t>(iteration);
      }
      return sample.second;
    };

    std::uint64_t arithmetic_value = 0;
    std::uint64_t lut_value = 0;
    if ((iteration & 1) == 0) {
      arithmetic_value = run_arithmetic();
      lut_value = run_lut();
    } else {
      lut_value = run_lut();
      arithmetic_value = run_arithmetic();
    }
    if (arithmetic_value != lut_value) {
      std::fprintf(stderr, "baseline/candidate checksum mismatch\n");
      return 1;
    }
  }

  const Timing arithmetic = timing(std::move(arithmetic_samples));
  const Timing generated = timing(std::move(lut_samples));
  if (arithmetic_checksum != lut_checksum) {
    std::fprintf(stderr, "aggregate checksum mismatch\n");
    return 1;
  }
  std::printf("rm1_handoff_lut_bench pixels=%zu iterations=%d "
              "arithmetic_min_us=%.1f arithmetic_p50_us=%.1f "
              "arithmetic_p95_us=%.1f arithmetic_p99_us=%.1f "
              "arithmetic_max_us=%.1f lut_min_us=%.1f lut_p50_us=%.1f "
              "lut_p95_us=%.1f lut_p99_us=%.1f lut_max_us=%.1f "
              "p50_speedup=%.2fx p95_speedup=%.2fx p99_speedup=%.2fx "
              "checksum=%llu\n",
              pixels.size(), iterations, arithmetic.min_us, arithmetic.p50_us,
              arithmetic.p95_us, arithmetic.p99_us, arithmetic.max_us,
              generated.min_us, generated.p50_us, generated.p95_us,
              generated.p99_us, generated.max_us,
              arithmetic.p50_us / generated.p50_us,
              arithmetic.p95_us / generated.p95_us,
              arithmetic.p99_us / generated.p99_us,
              static_cast<unsigned long long>(arithmetic_checksum));
  return 0;
}
