// RM1 settled-frame ownership A/B. This benchmark deliberately uses anonymous
// CPU memory with the exact RM1 visible and framebuffer strides. It never opens
// /dev/fb0, so it is safe to run while stock Xochitl owns the panel.

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string_view>
#include <utility>
#include <vector>

#include <sys/resource.h>
#include <unistd.h>

namespace {

using Clock = std::chrono::steady_clock;

constexpr std::size_t kWidth = 1404;
constexpr std::size_t kHeight = 1872;
constexpr std::size_t kBytesPerPixel = 2;
constexpr std::size_t kTightStride = kWidth * kBytesPerPixel;
constexpr std::size_t kFramebufferStride = 1408 * kBytesPerPixel;
constexpr std::size_t kFrameBytes = kTightStride * kHeight;
constexpr std::size_t kFramebufferBytes = kFramebufferStride * kHeight;
constexpr int kWarmupIterations = 5;
constexpr int kDefaultIterations = 40;

struct Rect final {
  std::size_t x;
  std::size_t y;
  std::size_t width;
  std::size_t height;
};

struct Case final {
  std::string_view name;
  std::vector<Rect> damage;
};

enum class Mode {
  kDuplicateMirror,
  kSafeJournal,
  kUnsafeSingleCeiling,
};

struct Timing final {
  double min_us;
  double p50_us;
  double p95_us;
  double p99_us;
  double max_us;
};

struct Journal final {
  std::unique_ptr<std::uint8_t[]> bytes;
  std::size_t size = 0;
  bool full_frame = false;
};

std::size_t current_rss_kib() {
  FILE *file = std::fopen("/proc/self/statm", "r");
  if (file == nullptr) {
    return 0;
  }
  unsigned long ignored_pages = 0;
  unsigned long resident_pages = 0;
  const int fields =
      std::fscanf(file, "%lu %lu", &ignored_pages, &resident_pages);
  std::fclose(file);
  if (fields != 2) {
    return 0;
  }
  const long page_bytes = ::sysconf(_SC_PAGESIZE);
  if (page_bytes <= 0) {
    return 0;
  }
  return static_cast<std::size_t>(resident_pages) *
         static_cast<std::size_t>(page_bytes) / 1024u;
}

std::size_t maximum_rss_kib() {
  rusage usage{};
  if (::getrusage(RUSAGE_SELF, &usage) != 0) {
    return 0;
  }
#if defined(__APPLE__)
  return static_cast<std::size_t>(usage.ru_maxrss) / 1024u;
#else
  return static_cast<std::size_t>(usage.ru_maxrss);
#endif
}

Timing summarize(std::vector<double> samples) {
  std::sort(samples.begin(), samples.end());
  return {
      .min_us = samples.front(),
      .p50_us = samples[samples.size() / 2u],
      .p95_us = samples[((samples.size() - 1u) * 95u) / 100u],
      .p99_us = samples[((samples.size() - 1u) * 99u) / 100u],
      .max_us = samples.back(),
  };
}

std::vector<Case> benchmark_cases() {
  std::vector<Rect> sparse;
  sparse.reserve(16);
  for (std::size_t index = 0; index < 16; ++index) {
    sparse.push_back({
        .x = (index * 83u) % (kWidth - 32u),
        .y = (index * 109u) % (kHeight - 32u),
        .width = 32,
        .height = 32,
    });
  }
  return {
      {.name = "full", .damage = {{0, 0, kWidth, kHeight}}},
      {.name = "medium",
       .damage = {{(kWidth - 702u) / 2u, (kHeight - 936u) / 2u, 702, 936}}},
      {.name = "sparse16x32", .damage = std::move(sparse)},
  };
}

std::size_t damage_bytes(const std::vector<Rect> &damage) {
  std::size_t total = 0;
  for (const Rect &rect : damage) {
    total += rect.width * rect.height * kBytesPerPixel;
  }
  return total;
}

void copy_app_to_framebuffer(const std::vector<std::uint8_t> &app,
                             std::vector<std::uint8_t> *framebuffer,
                             const std::vector<Rect> &damage) {
  for (const Rect &rect : damage) {
    const std::size_t row_bytes = rect.width * kBytesPerPixel;
    for (std::size_t row = 0; row < rect.height; ++row) {
      const std::size_t source =
          (rect.y + row) * kTightStride + rect.x * kBytesPerPixel;
      const std::size_t destination =
          (rect.y + row) * kFramebufferStride + rect.x * kBytesPerPixel;
      std::memcpy(framebuffer->data() + destination, app.data() + source,
                  row_bytes);
    }
  }
}

void copy_app_to_mirror(const std::vector<std::uint8_t> &app,
                        std::vector<std::uint8_t> *mirror,
                        const std::vector<Rect> &damage) {
  for (const Rect &rect : damage) {
    const std::size_t row_bytes = rect.width * kBytesPerPixel;
    for (std::size_t row = 0; row < rect.height; ++row) {
      const std::size_t offset =
          (rect.y + row) * kTightStride + rect.x * kBytesPerPixel;
      std::memcpy(mirror->data() + offset, app.data() + offset, row_bytes);
    }
  }
}

Journal journal_then_copy(const std::vector<std::uint8_t> &app,
                          std::vector<std::uint8_t> *framebuffer,
                          const std::vector<Rect> &damage) {
  const std::size_t requested_bytes = damage_bytes(damage);
  Journal journal{
      .bytes = std::unique_ptr<std::uint8_t[]>(
          new std::uint8_t[std::min(requested_bytes, kFrameBytes)]),
      .size = std::min(requested_bytes, kFrameBytes),
      .full_frame = requested_bytes > kFrameBytes,
  };

  if (journal.full_frame) {
    for (std::size_t row = 0; row < kHeight; ++row) {
      std::memcpy(journal.bytes.get() + row * kTightStride,
                  framebuffer->data() + row * kFramebufferStride, kTightStride);
    }
    copy_app_to_framebuffer(app, framebuffer, damage);
    return journal;
  }

  std::size_t journal_offset = 0;
  for (const Rect &rect : damage) {
    const std::size_t row_bytes = rect.width * kBytesPerPixel;
    for (std::size_t row = 0; row < rect.height; ++row) {
      const std::size_t app_offset =
          (rect.y + row) * kTightStride + rect.x * kBytesPerPixel;
      const std::size_t framebuffer_offset =
          (rect.y + row) * kFramebufferStride + rect.x * kBytesPerPixel;
      std::memcpy(journal.bytes.get() + journal_offset,
                  framebuffer->data() + framebuffer_offset, row_bytes);
      std::memcpy(framebuffer->data() + framebuffer_offset,
                  app.data() + app_offset, row_bytes);
      journal_offset += row_bytes;
    }
  }
  return journal;
}

std::uint64_t sampled_checksum(const std::uint8_t *bytes, std::size_t size) {
  std::uint64_t checksum = size;
  constexpr std::size_t kSampleStride = 4093;
  for (std::size_t offset = 0; offset < size; offset += kSampleStride) {
    checksum = checksum * 131u + bytes[offset];
  }
  if (size != 0) {
    checksum = checksum * 131u + bytes[size - 1u];
  }
  return checksum;
}

const char *mode_name(Mode mode) {
  switch (mode) {
  case Mode::kDuplicateMirror:
    return "duplicate_mirror";
  case Mode::kSafeJournal:
    return "safe_journal";
  case Mode::kUnsafeSingleCeiling:
    return "unsafe_single_ceiling";
  }
  return "invalid";
}

bool parse_mode(std::string_view value, Mode *out) {
  if (value == "duplicate") {
    *out = Mode::kDuplicateMirror;
    return true;
  }
  if (value == "journal") {
    *out = Mode::kSafeJournal;
    return true;
  }
  if (value == "single") {
    *out = Mode::kUnsafeSingleCeiling;
    return true;
  }
  return false;
}

} // namespace

int main(int argc, char **argv) {
  Mode mode = Mode::kDuplicateMirror;
  int iterations = kDefaultIterations;
  if (argc >= 2 && !parse_mode(argv[1], &mode)) {
    std::fprintf(stderr, "unknown mode: %s\n", argv[1]);
    return 2;
  }
  if (argc >= 3) {
    iterations = std::atoi(argv[2]);
  }
  if (argc > 3 || iterations < 30 || iterations > 500) {
    std::fprintf(stderr, "usage: rm1_framebuffer_copy_bench "
                         "[duplicate|journal|single] [iterations:30..500]\n");
    return 2;
  }

  std::vector<std::uint8_t> app(kFrameBytes);
  std::vector<std::uint8_t> framebuffer(kFramebufferBytes);
  std::vector<std::uint8_t> mirror;
  std::uint32_t random = 0x614f3b29u;
  for (std::uint8_t &value : app) {
    random = random * 1664525u + 1013904223u;
    value = static_cast<std::uint8_t>(random >> 24u);
  }
  for (std::uint8_t &value : framebuffer) {
    random = random * 1664525u + 1013904223u;
    value = static_cast<std::uint8_t>(random >> 24u);
  }
  if (mode == Mode::kDuplicateMirror) {
    mirror.assign(kFrameBytes, 0xffu);
  }

  const std::size_t rss_before_kib = current_rss_kib();
  const std::vector<Case> cases = benchmark_cases();
  std::uint64_t aggregate_checksum = 0;
  for (const Case &bench_case : cases) {
    std::vector<double> samples;
    samples.reserve(static_cast<std::size_t>(iterations));
    std::uint64_t case_checksum = 0;
    for (int iteration = -kWarmupIterations; iteration < iterations;
         ++iteration) {
      const std::size_t mutation =
          (static_cast<std::size_t>(iteration + kWarmupIterations + 1) *
           65537u) %
          app.size();
      app[mutation] ^= static_cast<std::uint8_t>(iteration + 0xa5);

      Journal journal;
      const auto begin = Clock::now();
      switch (mode) {
      case Mode::kDuplicateMirror:
        copy_app_to_framebuffer(app, &framebuffer, bench_case.damage);
        copy_app_to_mirror(app, &mirror, bench_case.damage);
        break;
      case Mode::kSafeJournal:
        journal = journal_then_copy(app, &framebuffer, bench_case.damage);
        break;
      case Mode::kUnsafeSingleCeiling:
        copy_app_to_framebuffer(app, &framebuffer, bench_case.damage);
        break;
      }
      const auto end = Clock::now();

      std::uint64_t checksum =
          sampled_checksum(framebuffer.data(), framebuffer.size());
      if (mode == Mode::kDuplicateMirror) {
        checksum ^= sampled_checksum(mirror.data(), mirror.size());
      } else if (mode == Mode::kSafeJournal) {
        checksum ^= sampled_checksum(journal.bytes.get(), journal.size);
      }
      if (iteration >= 0) {
        samples.push_back(
            std::chrono::duration<double, std::micro>(end - begin).count());
        case_checksum += checksum + static_cast<std::uint64_t>(iteration);
      }
    }

    const Timing result = summarize(std::move(samples));
    aggregate_checksum ^= case_checksum;
    std::printf("rm1_framebuffer_copy_bench mode=%s case=%.*s "
                "damage_rects=%zu damage_bytes=%zu iterations=%d warmup=%d "
                "min_us=%.1f p50_us=%.1f p95_us=%.1f p99_us=%.1f "
                "max_us=%.1f checksum=%llu\n",
                mode_name(mode), static_cast<int>(bench_case.name.size()),
                bench_case.name.data(), bench_case.damage.size(),
                damage_bytes(bench_case.damage), iterations, kWarmupIterations,
                result.min_us, result.p50_us, result.p95_us, result.p99_us,
                result.max_us, static_cast<unsigned long long>(case_checksum));
  }

  std::printf("rm1_framebuffer_copy_memory mode=%s tight_frame_bytes=%zu "
              "visible_framebuffer_bytes=%zu persistent_mirror_bytes=%zu "
              "max_journal_bytes=%zu rss_before_kib=%zu rss_after_kib=%zu "
              "maxrss_kib=%zu aggregate_checksum=%llu\n",
              mode_name(mode), kFrameBytes, kFramebufferBytes, mirror.size(),
              mode == Mode::kSafeJournal ? kFrameBytes : 0u, rss_before_kib,
              current_rss_kib(), maximum_rss_kib(),
              static_cast<unsigned long long>(aggregate_checksum));
  return 0;
}
