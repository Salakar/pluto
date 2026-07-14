#include "pluto/glass_handoff.h"

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>
#include <string_view>
#include <sys/resource.h>
#include <unistd.h>
#include <vector>

#if defined(__APPLE__)
#include <mach/mach.h>
#endif

namespace {

using Clock = std::chrono::steady_clock;
using pluto::GlassHandoffBundle;
using pluto::GlassHandoffClock;
using pluto::GlassHandoffIdentity;
using pluto::GlassHandoffLease;
using pluto::GlassHandoffProfile;
using pluto::GlassHandoffReject;
using pluto::GlassHandoffRendererInfo;

constexpr std::uint32_t kWidth = 954;
constexpr std::uint32_t kHeight = 1696;
constexpr std::uint32_t kEngineStride = 960;
constexpr std::uint32_t kHistoryStride = 968;
constexpr std::uint32_t kHistoryRows = 1698;
constexpr std::uint32_t kTilePx = 32;
// Exact quiescent process-oracle payload after the transient FrameLedger row
// verification cache was removed from the wire contract.
constexpr std::size_t kRendererPayloadBytes = 5'293'826u;

std::size_t current_rss_bytes() {
#if defined(__APPLE__)
  mach_task_basic_info_data_t info{};
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS) {
    return static_cast<std::size_t>(info.resident_size);
  }
#elif defined(__linux__)
  std::ifstream statm("/proc/self/statm");
  std::size_t pages = 0;
  std::size_t resident = 0;
  if (statm >> pages >> resident) {
    return resident * static_cast<std::size_t>(::sysconf(_SC_PAGESIZE));
  }
#endif
  return 0;
}

std::size_t peak_rss_bytes() {
  rusage usage{};
  if (::getrusage(RUSAGE_SELF, &usage) != 0) {
    return 0;
  }
#if defined(__APPLE__)
  return static_cast<std::size_t>(usage.ru_maxrss);
#else
  return static_cast<std::size_t>(usage.ru_maxrss) * 1024u;
#endif
}

double milliseconds(Clock::duration duration) {
  return std::chrono::duration<double, std::milli>(duration).count();
}

double process_cpu_milliseconds() {
  rusage usage{};
  if (::getrusage(RUSAGE_SELF, &usage) != 0) {
    return 0.0;
  }
  const auto timeval_ms = [](const timeval &value) {
    return static_cast<double>(value.tv_sec) * 1000.0 +
           static_cast<double>(value.tv_usec) / 1000.0;
  };
  return timeval_ms(usage.ru_utime) + timeval_ms(usage.ru_stime);
}

double percentile(std::vector<double> samples, double fraction) {
  std::sort(samples.begin(), samples.end());
  const std::size_t index = static_cast<std::size_t>(
      fraction * static_cast<double>(samples.size() - 1u));
  return samples[index];
}

GlassHandoffBundle make_bundle() {
  GlassHandoffBundle bundle;
  bundle.identity.flags = pluto::kGlassHandoffFlagExactColor;
  bundle.identity.profile = GlassHandoffProfile::kXochitlGallery3Move;
  bundle.identity.width = kWidth;
  bundle.identity.height = kHeight;
  bundle.identity.pixel_format = 0; // kPlutoPixelFormatRgb565
  bundle.identity.engine_stride = kEngineStride;
  bundle.identity.tile_px = kTilePx;
  bundle.identity.history_stride = kHistoryStride;
  bundle.identity.history_rows = kHistoryRows;
  bundle.identity.history_pixel_bytes = 4;
  bundle.identity.waveform_hash = 0x80e4'08a2'0ac5'd05bull;
  bundle.identity.waveform_bytes = 8'388'608;
  bundle.identity.ct33_hash = 0x9dc4'01cc'166f'879dull;
  bundle.identity.ct33_bytes = 196'608;
  bundle.identity.pipeline_hash = 0xf35d'ca67'395f'397bull;
  bundle.renderer =
      GlassHandoffRendererInfo{kWidth, kHeight, 0, 0, 0x0ca4'621c'0241'7d3full};
  bundle.written = GlassHandoffClock{1'750'000'000, 20'000'000'000ull,
                                     0xc713'c713'c713'c713ull};
  bundle.chain = 3;
  bundle.core.engine_temperature_bin = 21;
  bundle.core.admission_temperature_bin = 20;

  const std::size_t plane = static_cast<std::size_t>(kEngineStride) * kHeight;
  const std::size_t tiles =
      static_cast<std::size_t>((kWidth + kTilePx - 1u) / kTilePx) *
      ((kHeight + kTilePx - 1u) / kTilePx);
  const std::size_t history_pixels =
      static_cast<std::size_t>(kHistoryStride) * kHistoryRows;
  bundle.core.engine_dc.resize(plane);
  bundle.core.engine_stress.resize(tiles);
  bundle.core.engine_rescan.resize(tiles);
  bundle.core.xochitl_history_ab.resize(history_pixels * 2u);
  bundle.renderer_payload.resize(kRendererPayloadBytes);

  for (std::size_t i = 0; i < plane; ++i) {
    bundle.core.engine_dc[i] =
        static_cast<std::int8_t>(static_cast<int>(i % 15u) - 7);
  }
  for (std::size_t i = 0; i < tiles; ++i) {
    bundle.core.engine_stress[i] = static_cast<std::uint16_t>(i * 17u);
    bundle.core.engine_rescan[i] =
        static_cast<std::int32_t>(static_cast<int>(i % 9u) - 4);
  }
  for (std::size_t i = 0; i < history_pixels; ++i) {
    // Equal visible levels periodically carry deliberately different flags
    // and B history, matching the exact-color regression case.
    const std::uint16_t level = static_cast<std::uint16_t>(i & 31u);
    bundle.core.xochitl_history_ab[i * 2u] = static_cast<std::uint16_t>(
        level | ((i & 1u) != 0u ? 0x8200u : 0x4000u));
    bundle.core.xochitl_history_ab[i * 2u + 1u] =
        static_cast<std::uint16_t>((i * 40503u) ^ (i >> 5u));
  }
  std::uint32_t random = 0x4753'4d32u;
  for (std::uint8_t &byte : bundle.renderer_payload) {
    random ^= random << 13u;
    random ^= random >> 17u;
    random ^= random << 5u;
    byte = static_cast<std::uint8_t>(random);
  }
  return bundle;
}

bool same_probe(const GlassHandoffBundle &left,
                const GlassHandoffBundle &right) {
  return left.identity == right.identity && left.renderer == right.renderer &&
         left.chain == right.chain &&
         left.core.engine_dc == right.core.engine_dc &&
         left.core.engine_stress == right.core.engine_stress &&
         left.core.engine_rescan == right.core.engine_rescan &&
         left.core.xochitl_history_ab == right.core.xochitl_history_ab &&
         left.renderer_payload == right.renderer_payload;
}

} // namespace

int main(int argc, char **argv) {
  int iterations = 7;
  if (argc >= 2) {
    iterations = std::atoi(argv[1]);
  }
  if (argc > 3 || iterations < 1 || iterations > 100) {
    std::cerr << "usage: glass_handoff_bench [iterations:1..100] [directory]\n";
    return 2;
  }

  const std::string directory = argc == 3 ? argv[2] : "/tmp";
  const std::string path = directory + "/pluto-glass-handoff-bench-" +
                           std::to_string(::getpid()) + ".bin";
  GlassHandoffLease lease;
  if (!pluto::glass_handoff_acquire_lease(path, &lease)) {
    std::cerr << "lease acquisition failed\n";
    return 3;
  }
  (void)pluto::glass_handoff_discard(lease, path);
  const std::size_t rss_start = current_rss_bytes();
  GlassHandoffBundle source = make_bundle();
  const std::size_t rss_bundle = current_rss_bytes();
  std::vector<double> save_ms;
  std::vector<double> load_ms;
  std::vector<double> save_cpu_ms;
  std::vector<double> load_cpu_ms;
  std::size_t rss_first_save_peak = 0;
  std::size_t rss_first_handoff_peak = 0;
  std::size_t rss_max_current_after_handoff = 0;
  save_ms.reserve(static_cast<std::size_t>(iterations));
  load_ms.reserve(static_cast<std::size_t>(iterations));
  save_cpu_ms.reserve(static_cast<std::size_t>(iterations));
  load_cpu_ms.reserve(static_cast<std::size_t>(iterations));

  for (int i = 0; i < iterations; ++i) {
    const double save_cpu_start = process_cpu_milliseconds();
    const auto save_start = Clock::now();
    if (!pluto::glass_handoff_save(lease, path, source)) {
      std::cerr << "save failed\n";
      (void)pluto::glass_handoff_discard(lease, path);
      return 4;
    }
    save_ms.push_back(milliseconds(Clock::now() - save_start));
    save_cpu_ms.push_back(process_cpu_milliseconds() - save_cpu_start);
    if (i == 0) {
      rss_first_save_peak = peak_rss_bytes();
    }

    GlassHandoffBundle loaded;
    const double load_cpu_start = process_cpu_milliseconds();
    const auto load_start = Clock::now();
    const GlassHandoffReject reject = pluto::glass_handoff_load(
        lease, path, source.identity,
        GlassHandoffClock{source.written.realtime_sec,
                          source.written.boottime_ns + 1'000'000ull,
                          source.written.boot_id_hash},
        &loaded);
    load_ms.push_back(milliseconds(Clock::now() - load_start));
    load_cpu_ms.push_back(process_cpu_milliseconds() - load_cpu_start);
    if (reject != GlassHandoffReject::kNone || !same_probe(source, loaded)) {
      std::cerr << "load failed reject="
                << pluto::glass_handoff_reject_name(reject) << '\n';
      (void)pluto::glass_handoff_discard(lease, path);
      return 5;
    }
    if (i == 0) {
      rss_first_handoff_peak = peak_rss_bytes();
    }
    rss_max_current_after_handoff =
        std::max(rss_max_current_after_handoff, current_rss_bytes());
  }

  const std::size_t rss_end = current_rss_bytes();
  std::ifstream stream(path, std::ios::binary | std::ios::ate);
  const std::size_t file_bytes =
      stream ? static_cast<std::size_t>(stream.tellg()) : 0;
  (void)pluto::glass_handoff_discard(lease, path);
  lease = GlassHandoffLease{};
  (void)::unlink((path + ".lease").c_str());
  std::cout << std::fixed << std::setprecision(3)
            << "glass_handoff_bench profile=xg3m iterations=" << iterations
            << " directory=" << directory << " file_bytes=" << file_bytes
            << " history_bytes="
            << source.core.xochitl_history_ab.size() * sizeof(std::uint16_t)
            << " renderer_bytes=" << source.renderer_payload.size()
            << " save_p50_ms=" << percentile(save_ms, 0.50)
            << " save_p95_ms=" << percentile(save_ms, 0.95)
            << " save_cpu_p50_ms=" << percentile(save_cpu_ms, 0.50)
            << " save_cpu_p95_ms=" << percentile(save_cpu_ms, 0.95)
            << " load_p50_ms=" << percentile(load_ms, 0.50)
            << " load_p95_ms=" << percentile(load_ms, 0.95)
            << " load_cpu_p50_ms=" << percentile(load_cpu_ms, 0.50)
            << " load_cpu_p95_ms=" << percentile(load_cpu_ms, 0.95)
            << " rss_start_bytes=" << rss_start
            << " rss_bundle_bytes=" << rss_bundle
            << " rss_first_save_peak_bytes=" << rss_first_save_peak
            << " rss_save_peak_over_bundle_bytes="
            << (rss_first_save_peak > rss_bundle
                    ? rss_first_save_peak - rss_bundle
                    : 0u)
            << " rss_first_handoff_peak_bytes=" << rss_first_handoff_peak
            << " rss_load_peak_over_bundle_bytes="
            << (rss_first_handoff_peak > rss_bundle
                    ? rss_first_handoff_peak - rss_bundle
                    : 0u)
            << " rss_max_current_after_handoff_bytes="
            << rss_max_current_after_handoff << " rss_end_bytes=" << rss_end
            << " rss_all_iterations_peak_bytes=" << peak_rss_bytes() << '\n';
  return 0;
}
