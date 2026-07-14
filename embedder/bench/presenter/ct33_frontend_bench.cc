#include "presenter/swtcon/ct33_frontend.h"

#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <span>
#include <string_view>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;
using pluto::swtcon::Ct33Frontend;

constexpr int kWidth = 960;
constexpr int kHeight = 1696;

struct Distribution {
  double cold_us = 0.0;
  double p50_us = 0.0;
  double p95_us = 0.0;
  std::uint64_t checksum = 0;
};

std::vector<std::uint8_t> read_file(const char* path) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) {
    return {};
  }
  return std::vector<std::uint8_t>(std::istreambuf_iterator<char>(stream),
                                   std::istreambuf_iterator<char>());
}

bool parse_positive(std::string_view text, int* out) {
  if (out == nullptr || text.empty()) {
    return false;
  }
  int value = 0;
  const auto parsed =
      std::from_chars(text.data(), text.data() + text.size(), value);
  if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size() ||
      value <= 0) {
    return false;
  }
  *out = value;
  return true;
}

std::uint64_t fnv1a64(std::span<const std::uint8_t> bytes) {
  std::uint64_t hash = 0xcbf29ce484222325ull;
  for (const std::uint8_t byte : bytes) {
    hash ^= byte;
    hash *= 0x100000001b3ull;
  }
  return hash;
}

void store(std::vector<std::uint8_t>* source, std::size_t index,
           std::uint16_t pixel) {
  (*source)[index * 2u] = static_cast<std::uint8_t>(pixel);
  (*source)[index * 2u + 1u] = static_cast<std::uint8_t>(pixel >> 8u);
}

std::vector<std::uint8_t> make_random_source() {
  const std::size_t pixels = static_cast<std::size_t>(kWidth) * kHeight;
  std::vector<std::uint8_t> source(pixels * 2u);
  std::uint32_t state = 0xc733beefu;
  for (std::size_t index = 0; index < pixels; ++index) {
    // Full-period deterministic integer stream; take the mixed high/low word
    // so this case defeats small recent-colour caches.
    state ^= state << 13u;
    state ^= state >> 17u;
    state ^= state << 5u;
    store(&source, index,
          static_cast<std::uint16_t>(state ^ (state >> 16u)));
  }
  return source;
}

std::vector<std::uint8_t> make_palette_source() {
  constexpr std::uint16_t palette[] = {0xf800u, 0x07e0u, 0x001fu, 0xffe0u};
  const std::size_t pixels = static_cast<std::size_t>(kWidth) * kHeight;
  std::vector<std::uint8_t> source(pixels * 2u);
  for (int y = 0; y < kHeight; ++y) {
    for (int x = 0; x < kWidth; ++x) {
      const std::size_t index = static_cast<std::size_t>(y) * kWidth + x;
      store(&source, index, palette[((x >> 5) + (y >> 5)) & 3]);
    }
  }
  return source;
}

bool make_scalar_reference(const Ct33Frontend& frontend,
                           std::span<const std::uint8_t> source,
                           const std::uint8_t* selector,
                           std::vector<std::uint8_t>* out) {
  if (source.size() != static_cast<std::size_t>(kWidth) * kHeight * 2u ||
      out == nullptr) {
    return false;
  }
  constexpr std::uint8_t luma_palette[] = {10u, 8u, 9u, 11u};
  out->resize(static_cast<std::size_t>(kWidth) * kHeight);
  for (int y = 0; y < kHeight; ++y) {
    for (int x = 0; x < kWidth; ++x) {
      const std::size_t index = static_cast<std::size_t>(y) * kWidth + x;
      const std::uint16_t pixel = static_cast<std::uint16_t>(
          source[index * 2u] |
          (static_cast<std::uint16_t>(source[index * 2u + 1u]) << 8u));
      const std::uint8_t r5 = static_cast<std::uint8_t>(pixel >> 11u);
      const std::uint8_t g6 = static_cast<std::uint8_t>((pixel >> 5u) & 63u);
      const std::uint8_t b5 = static_cast<std::uint8_t>(pixel & 31u);
      const std::uint8_t r =
          static_cast<std::uint8_t>((r5 << 3u) | (r5 >> 2u));
      const std::uint8_t g =
          static_cast<std::uint8_t>((g6 << 2u) | (g6 >> 4u));
      const std::uint8_t b =
          static_cast<std::uint8_t>((b5 << 3u) | (b5 >> 2u));
      std::array<std::uint16_t, Ct33Frontend::kThresholdSlots> thresholds{};
      if (!frontend.interpolate_rgb8(r, g, b, &thresholds)) {
        return false;
      }
      const std::uint16_t spatial = Ct33Frontend::spatial_threshold(x, y);
      std::uint8_t state = 0;
      for (const std::uint16_t threshold : thresholds) {
        state = static_cast<std::uint8_t>(
            state + (threshold <= spatial ? 1u : 0u));
      }
      const std::uint8_t select = selector == nullptr ? 0u : selector[index];
      if (select != 0u) {
        const std::uint32_t weighted = static_cast<std::uint32_t>(r) * 77u +
                                       static_cast<std::uint32_t>(g) * 150u +
                                       static_cast<std::uint32_t>(b) * 29u;
        const std::uint8_t luma = luma_palette[(weighted >> 14u) & 3u];
        state = static_cast<std::uint8_t>(
            (select & luma) | (static_cast<std::uint8_t>(~select) & state));
      }
      (*out)[index] = static_cast<std::uint8_t>(
          state | (pixel == 0xffffu ? 0x80u : 0u));
    }
  }
  return true;
}

bool run_case(std::span<const std::uint8_t> blob,
              std::span<const std::uint8_t> source,
              const std::uint8_t* selector,
              std::span<const std::uint8_t> expected, int samples,
              Distribution* distribution) {
  if (distribution == nullptr || expected.empty()) {
    return false;
  }
  // A fresh frontend per case makes `cold_us` a genuine first conversion,
  // while configure itself remains outside the timed conversion contract.
  Ct33Frontend frontend;
  if (!frontend.configure(blob, nullptr)) {
    return false;
  }
  std::vector<std::uint8_t> out(expected.size());
  std::vector<double> timings;
  timings.reserve(static_cast<std::size_t>(samples) + 1u);
  for (int sample = -1; sample < samples; ++sample) {
    const auto begin = Clock::now();
    const bool ok = frontend.convert_rgb565_le(
        source.data(), static_cast<std::size_t>(kWidth) * 2u, 0, 0, kWidth,
        kHeight, out.data(), kWidth, selector,
        selector == nullptr ? 0u : static_cast<std::size_t>(kWidth));
    const auto end = Clock::now();
    if (!ok) {
      return false;
    }
    timings.push_back(
        std::chrono::duration<double, std::micro>(end - begin).count());
  }
  if (!std::equal(out.begin(), out.end(), expected.begin(), expected.end())) {
    return false;
  }
  const double cold = timings.front();
  timings.erase(timings.begin());
  std::sort(timings.begin(), timings.end());
  const auto percentile = [&](double p) {
    return timings[static_cast<std::size_t>(
        std::ceil(p * static_cast<double>(timings.size() - 1u)))];
  };
  *distribution =
      {cold, percentile(0.50), percentile(0.95), fnv1a64(out)};
  return true;
}

void print_case(const char* name, const Distribution& value) {
  std::printf("%-22s cold %9.1f us  warm-p50 %9.1f us  warm-p95 %9.1f us  "
              "checksum %016llx\n",
              name, value.cold_us, value.p50_us, value.p95_us,
              static_cast<unsigned long long>(value.checksum));
}

}  // namespace

int main(int argc, char** argv) {
  int samples = 25;
  if (argc < 2 || argc > 3 ||
      (argc == 3 && !parse_positive(argv[2], &samples))) {
    std::fprintf(stderr, "usage: %s CT33_BIN [SAMPLES]\n", argv[0]);
    return 2;
  }
  const std::vector<std::uint8_t> blob = read_file(argv[1]);
  Ct33Frontend reference_frontend;
  if (!reference_frontend.configure(blob, nullptr)) {
    std::fprintf(stderr, "invalid ct33 blob: %s\n", argv[1]);
    return 2;
  }

  const std::vector<std::uint8_t> random = make_random_source();
  const std::vector<std::uint8_t> palette = make_palette_source();
  const std::size_t pixels = static_cast<std::size_t>(kWidth) * kHeight;
  std::vector<std::uint8_t> selector_zero(pixels, 0u);
  std::vector<std::uint8_t> selector_full(pixels, 0xffu);
  std::vector<std::uint8_t> selector_mixed(pixels);
  for (std::size_t index = 0; index < pixels; ++index) {
    selector_mixed[index] = (index & 3u) == 0u ? 0xffu : 0u;
  }
  std::vector<std::uint8_t> random_plain_reference;
  std::vector<std::uint8_t> random_mixed_reference;
  std::vector<std::uint8_t> random_full_reference;
  std::vector<std::uint8_t> palette_plain_reference;
  if (!make_scalar_reference(reference_frontend, random, nullptr,
                             &random_plain_reference) ||
      !make_scalar_reference(reference_frontend, random, selector_mixed.data(),
                             &random_mixed_reference) ||
      !make_scalar_reference(reference_frontend, random, selector_full.data(),
                             &random_full_reference) ||
      !make_scalar_reference(reference_frontend, palette, nullptr,
                             &palette_plain_reference)) {
    std::fprintf(stderr, "failed to build independent scalar reference\n");
    return 1;
  }

  std::printf("ct33 RGB565 full-panel benchmark: %dx%d, samples=%d\n", kWidth,
              kHeight, samples);
  struct BenchCase {
    const char* name;
    const std::vector<std::uint8_t>* source;
    const std::uint8_t* selector;
    const std::vector<std::uint8_t>* expected;
  };
  const BenchCase cases[] = {
      {"random/no-selector", &random, nullptr, &random_plain_reference},
      {"random/selector-zero", &random, selector_zero.data(),
       &random_plain_reference},
      {"random/selector-mixed", &random, selector_mixed.data(),
       &random_mixed_reference},
      {"random/selector-full", &random, selector_full.data(),
       &random_full_reference},
      {"palette/no-selector", &palette, nullptr, &palette_plain_reference},
      {"palette/selector-zero", &palette, selector_zero.data(),
       &palette_plain_reference},
  };
  for (const BenchCase& bench_case : cases) {
    Distribution result;
    if (!run_case(blob, *bench_case.source, bench_case.selector,
                  *bench_case.expected, samples, &result)) {
      std::fprintf(stderr, "benchmark/parity failure: %s\n", bench_case.name);
      return 1;
    }
    print_case(bench_case.name, result);
  }
  return 0;
}
