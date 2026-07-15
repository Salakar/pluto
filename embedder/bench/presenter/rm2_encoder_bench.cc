// RM2 preparation hot-path A/B. This isolates the two table substitutions
// used by the production backend: exhaustive RGB565 -> gray4 codegen and
// open-time expansion of WBF even-state transitions. Host timings establish
// relative wins only; release acceptance still measures the ARMv7 tablet.

#include "presenter/native/rm2/rm2_scan_encoder.h"
#include "presenter/native/rm2/wbf_decoder.h"

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include <sys/resource.h>
#include <sys/utsname.h>
#include <unistd.h>

#include "wbf_synth.h"

namespace {

using pluto::native::rm2::encode_rm2_phase;
using pluto::native::rm2::fill_rm2_scan_slot;
using pluto::native::rm2::kRm2PanelHeight;
using pluto::native::rm2::kRm2PanelWidth;
using pluto::native::rm2::kRm2Rgb565LevelLut;
using pluto::native::rm2::kRm2Rgb565LevelLutFnv1a64;
using pluto::native::rm2::kRm2SlotBytes;
using pluto::native::rm2::rgb565_to_rm2_level;
using pluto::native::rm2::Rm2PanelRect;
using pluto::native::rm2::WbfDecoder;

constexpr std::size_t kPanelPixels = kRm2PanelWidth * kRm2PanelHeight;
constexpr std::size_t kWarmupIterations = 8;
constexpr std::size_t kMeasuredIterations = 100;
constexpr double kScanBudgetUs = 11763.0;
static_assert(kMeasuredIterations >= 40);

std::uint8_t arithmetic_level(std::uint16_t pixel) {
  const std::uint32_t red5 = (pixel >> 11U) & 0x1fU;
  const std::uint32_t green6 = (pixel >> 5U) & 0x3fU;
  const std::uint32_t blue5 = pixel & 0x1fU;
  const std::uint32_t red8 = (red5 << 3U) | (red5 >> 2U);
  const std::uint32_t green8 = (green6 << 2U) | (green6 >> 4U);
  const std::uint32_t blue8 = (blue5 << 3U) | (blue5 >> 2U);
  const std::uint32_t luma =
      (77U * red8 + 150U * green8 + 29U * blue8 + 128U) >> 8U;
  return static_cast<std::uint8_t>((luma * 15U + 127U) / 255U);
}

std::uint64_t lut_checksum() {
  std::uint64_t checksum = 0xcbf29ce484222325ULL;
  for (const std::uint8_t value : kRm2Rgb565LevelLut) {
    checksum ^= value;
    checksum *= 0x100000001b3ULL;
  }
  return checksum;
}

struct Timing {
  double min_us = 0;
  double p50_us = 0;
  double p95_us = 0;
  double p99_us = 0;
  double max_us = 0;
};

struct IterationResult {
  bool ok = false;
  std::uint64_t checksum = 0;
};

struct Measurement {
  Timing timing;
  std::size_t measured_failures = 0;
  std::size_t warmup_failures = 0;
  std::uint64_t checksum = 0;
};

double nearest_rank(const std::vector<double> &sorted, std::size_t percentile) {
  const std::size_t rank =
      std::max<std::size_t>(1, (sorted.size() * percentile + 99U) / 100U);
  return sorted[std::min(rank, sorted.size()) - 1U];
}

Timing summarize(std::vector<double> samples) {
  std::sort(samples.begin(), samples.end());
  return {
      .min_us = samples.front(),
      .p50_us = nearest_rank(samples, 50),
      .p95_us = nearest_rank(samples, 95),
      .p99_us = nearest_rank(samples, 99),
      .max_us = samples.back(),
  };
}

std::uint64_t mix_checksum(std::uint64_t aggregate, std::uint64_t value,
                           std::size_t iteration) {
  return aggregate ^ (value + 0x9e3779b97f4a7c15ULL + (aggregate << 6U) +
                      (aggregate >> 2U) + iteration);
}

template <typename Function> Measurement measure(Function function) {
  std::vector<double> samples;
  samples.reserve(kMeasuredIterations);
  std::size_t measured_failures = 0;
  std::size_t warmup_failures = 0;
  std::uint64_t checksum = 0;
  const std::size_t total = kWarmupIterations + kMeasuredIterations;
  for (std::size_t iteration = 0; iteration < total; ++iteration) {
    const auto begin = std::chrono::steady_clock::now();
    const IterationResult result = function(iteration);
    const auto end = std::chrono::steady_clock::now();
    if (iteration >= kWarmupIterations) {
      measured_failures += !result.ok;
      samples.push_back(
          std::chrono::duration<double, std::micro>(end - begin).count());
      checksum = mix_checksum(checksum, result.checksum, iteration);
    } else {
      warmup_failures += !result.ok;
    }
  }
  return {
      .timing = summarize(std::move(samples)),
      .measured_failures = measured_failures,
      .warmup_failures = warmup_failures,
      .checksum = checksum,
  };
}

std::string compiled_architecture() {
#if defined(__aarch64__)
  return "aarch64";
#elif defined(__arm__)
  return "arm";
#elif defined(__x86_64__)
  return "x86_64";
#elif defined(__i386__)
  return "x86";
#else
  return "unknown";
#endif
}

std::string build_mode() {
#if defined(NDEBUG)
  return "release";
#else
  return "debug";
#endif
}

std::string cpu_model() {
  std::ifstream input("/proc/cpuinfo");
  std::string line;
  while (std::getline(input, line)) {
    const bool model = line.starts_with("model name") ||
                       line.starts_with("Hardware") ||
                       line.starts_with("Processor");
    if (!model) {
      continue;
    }
    const std::size_t separator = line.find(':');
    if (separator == std::string::npos) {
      continue;
    }
    std::string value = line.substr(separator + 1U);
    const std::size_t first = value.find_first_not_of(" \t");
    return first == std::string::npos ? std::string{} : value.substr(first);
  }
  return {};
}

std::uint64_t maximum_rss_bytes() {
  struct rusage usage {};
  if (::getrusage(RUSAGE_SELF, &usage) != 0 || usage.ru_maxrss < 0) {
    return 0;
  }
#if defined(__APPLE__)
  return static_cast<std::uint64_t>(usage.ru_maxrss);
#else
  return static_cast<std::uint64_t>(usage.ru_maxrss) * 1024U;
#endif
}

void print_context() {
  struct utsname system {};
  const bool have_uname = ::uname(&system) == 0;
  const long online_cpus = ::sysconf(_SC_NPROCESSORS_ONLN);
  const long page_bytes = ::sysconf(_SC_PAGESIZE);
  std::printf("rm2_bench_context os=%s release=%s machine=%s compiled_arch=%s "
              "online_cpus=%ld page_bytes=%ld pointer_bits=%zu build=%s "
              "compiler=\"%s\"\n",
              have_uname ? system.sysname : "unknown",
              have_uname ? system.release : "unknown",
              have_uname ? system.machine : "unknown",
              compiled_architecture().c_str(), online_cpus, page_bytes,
              sizeof(void *) * 8U, build_mode().c_str(), __VERSION__);
  const std::string model = cpu_model();
  if (!model.empty()) {
    std::printf("rm2_bench_cpu model=\"%s\"\n", model.c_str());
  }
}

void print_measurement(std::string_view name, const Measurement &measurement) {
  const Timing &timing = measurement.timing;
  std::printf("rm2_bench name=%.*s measured=%zu warmup=%zu min_us=%.1f "
              "p50_us=%.1f p95_us=%.1f p99_us=%.1f max_us=%.1f failures=%zu "
              "warmup_failures=%zu checksum=0x%016llx\n",
              static_cast<int>(name.size()), name.data(), kMeasuredIterations,
              kWarmupIterations, timing.min_us, timing.p50_us, timing.p95_us,
              timing.p99_us, timing.max_us, measurement.measured_failures,
              measurement.warmup_failures,
              static_cast<unsigned long long>(measurement.checksum));
}

double ratio(double numerator, double denominator) {
  return denominator > 0 ? numerator / denominator : 0;
}

} // namespace

int main() {
  print_context();

  std::size_t lut_mismatches = 0;
  std::uint32_t first_lut_mismatch = 0;
  for (std::uint32_t pixel = 0; pixel <= 0xffffU; ++pixel) {
    if (arithmetic_level(static_cast<std::uint16_t>(pixel)) !=
        rgb565_to_rm2_level(static_cast<std::uint16_t>(pixel))) {
      if (lut_mismatches == 0) {
        first_lut_mismatch = pixel;
      }
      ++lut_mismatches;
    }
  }
  const std::uint64_t actual_lut_checksum = lut_checksum();
  const bool lut_hash_matches =
      actual_lut_checksum == kRm2Rgb565LevelLutFnv1a64;
  std::printf("rm2_lut entries=%zu mismatches=%zu first_mismatch=%u "
              "checksum=0x%016llx expected=0x%016llx hash_match=%u\n",
              kRm2Rgb565LevelLut.size(), lut_mismatches, first_lut_mismatch,
              static_cast<unsigned long long>(actual_lut_checksum),
              static_cast<unsigned long long>(kRm2Rgb565LevelLutFnv1a64),
              lut_hash_matches ? 1U : 0U);
  if (lut_mismatches != 0 || !lut_hash_matches) {
    return 1;
  }

  std::vector<std::uint16_t> pixels(kPanelPixels);
  std::vector<std::uint8_t> output(kPanelPixels);
  std::uint32_t random = 0x52f6a19dU;
  for (std::uint16_t &pixel : pixels) {
    random = random * 1664525U + 1013904223U;
    pixel = static_cast<std::uint16_t>(random >> 8U);
  }

  const Measurement arithmetic = measure([&](std::size_t) {
    std::uint64_t checksum = 0;
    for (std::size_t index = 0; index < pixels.size(); ++index) {
      const std::uint8_t level = arithmetic_level(pixels[index]);
      output[index] = level;
      checksum += level;
    }
    return IterationResult{.ok = true, .checksum = checksum};
  });
  const Measurement generated = measure([&](std::size_t) {
    std::uint64_t checksum = 0;
    for (std::size_t index = 0; index < pixels.size(); ++index) {
      const std::uint8_t level = rgb565_to_rm2_level(pixels[index]);
      output[index] = level;
      checksum += level;
    }
    return IterationResult{.ok = true, .checksum = checksum};
  });

  const auto fixture = pluto::native::rm2::test::make_synthetic_wbf();
  WbfDecoder waveform;
  std::string error;
  if (!waveform.open(fixture.bytes, fixture.expected, &error)) {
    std::fprintf(stderr, "synthetic WBF open failed: %s\n", error.c_str());
    return 1;
  }
  std::vector<std::uint8_t> transitions(kPanelPixels);
  for (std::uint8_t &transition : transitions) {
    random = random * 1664525U + 1013904223U;
    transition = static_cast<std::uint8_t>(random);
  }
  std::vector<std::uint8_t> expanded(16U * 16U);
  for (std::uint32_t next = 0; next < 16; ++next) {
    for (std::uint32_t previous = 0; previous < 16; ++previous) {
      if (!waveform.drive_code(1, 0, static_cast<std::uint8_t>(previous * 2U),
                               static_cast<std::uint8_t>(next * 2U), 0,
                               &expanded[next * 16U + previous])) {
        return 1;
      }
    }
  }

  const Measurement decoded = measure([&](std::size_t) {
    std::uint64_t checksum = 0;
    for (const std::uint8_t transition : transitions) {
      std::uint8_t code = 0;
      if (!waveform.drive_code(
              1, 0, static_cast<std::uint8_t>((transition & 0x0fU) * 2U),
              static_cast<std::uint8_t>((transition >> 4U) * 2U), 0, &code)) {
        return IterationResult{.ok = false, .checksum = checksum};
      }
      checksum += code;
    }
    return IterationResult{.ok = true, .checksum = checksum};
  });
  const Measurement preexpanded = measure([&](std::size_t) {
    std::uint64_t checksum = 0;
    for (const std::uint8_t transition : transitions) {
      checksum += expanded[transition];
    }
    return IterationResult{.ok = true, .checksum = checksum};
  });

  std::vector<std::byte> slot(kRm2SlotBytes);
  if (!fill_rm2_scan_slot(slot, 0)) {
    return 1;
  }
  const Rm2PanelRect full_panel{
      .row_min = 0,
      .row_max = static_cast<std::uint16_t>(kRm2PanelHeight - 1U),
      .column_min = 0,
      .column_max = static_cast<std::uint16_t>(kRm2PanelWidth - 1U),
  };
  if (!encode_rm2_phase(slot, full_panel, transitions, expanded)) {
    return 1;
  }
  const Measurement packed = measure([&](std::size_t iteration) {
    if (!encode_rm2_phase(slot, full_panel, transitions, expanded)) {
      return IterationResult{.ok = false, .checksum = 0};
    }
    std::uint64_t checksum = 0;
    for (std::size_t sample = 0; sample < 32; ++sample) {
      const std::size_t index =
          (iteration * 1315423911ULL + sample * 2654435761ULL) % slot.size();
      checksum = checksum * 257U + std::to_integer<std::uint8_t>(slot[index]);
    }
    return IterationResult{.ok = true, .checksum = checksum};
  });

  print_measurement("rgb565_arithmetic", arithmetic);
  print_measurement("rgb565_generated_lut", generated);
  print_measurement("wbf_transition_decoder", decoded);
  print_measurement("wbf_transition_expanded_lut", preexpanded);
  print_measurement("full_panel_phase_encode", packed);
  std::printf("rm2_bench_compare baseline=rgb565_arithmetic "
              "candidate=rgb565_generated_lut p50_speedup=%.2f "
              "p95_speedup=%.2f\n",
              ratio(arithmetic.timing.p50_us, generated.timing.p50_us),
              ratio(arithmetic.timing.p95_us, generated.timing.p95_us));
  std::printf("rm2_bench_compare baseline=wbf_transition_decoder "
              "candidate=wbf_transition_expanded_lut p50_speedup=%.2f "
              "p95_speedup=%.2f\n",
              ratio(decoded.timing.p50_us, preexpanded.timing.p50_us),
              ratio(decoded.timing.p95_us, preexpanded.timing.p95_us));
  std::printf("rm2_scan_budget budget_us=%.1f p95_headroom=%.2f "
              "p99_headroom=%.2f\n",
              kScanBudgetUs, ratio(kScanBudgetUs, packed.timing.p95_us),
              ratio(kScanBudgetUs, packed.timing.p99_us));

  const std::size_t tracked_buffer_bytes =
      pixels.size() * sizeof(pixels.front()) +
      output.size() * sizeof(output.front()) +
      transitions.size() * sizeof(transitions.front()) +
      expanded.size() * sizeof(expanded.front()) +
      slot.size() * sizeof(slot.front());
  std::printf("rm2_bench_memory panel_pixels=%zu tracked_buffer_bytes=%zu "
              "static_lut_bytes=%zu max_rss_bytes=%llu\n",
              kPanelPixels, tracked_buffer_bytes, kRm2Rgb565LevelLut.size(),
              static_cast<unsigned long long>(maximum_rss_bytes()));

  const std::size_t failures =
      arithmetic.measured_failures + arithmetic.warmup_failures +
      generated.measured_failures + generated.warmup_failures +
      decoded.measured_failures + decoded.warmup_failures +
      preexpanded.measured_failures + preexpanded.warmup_failures +
      packed.measured_failures + packed.warmup_failures;
  std::printf("rm2_bench_summary measured_per_case=%zu total_failures=%zu\n",
              kMeasuredIterations, failures);
  return failures == 0 ? 0 : 1;
}
