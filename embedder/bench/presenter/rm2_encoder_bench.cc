// RM2 preparation hot-path evidence. This measures the retained arithmetic
// RGB565 conversion, open-time expansion of WBF even-state transitions, and
// exact scan-cell packing. Host timings establish relative wins only; release
// acceptance measures the ARMv7 tablet.

#include "presenter/native/rm2/rm2_cpu_frequency_lease.h"
#include "presenter/native/rm2/rm2_scan_encoder.h"
#include "presenter/native/rm2/rm2_waveform_program.h"
#include "presenter/native/rm2/wbf_decoder.h"
#include "runtime/sha256.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <new>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include <fcntl.h>
#include <limits.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#if defined(__linux__)
#include <pthread.h>
#include <sched.h>
#endif

#include "wbf_synth.h"

namespace {
std::atomic<std::uint64_t> g_allocation_count{0};
}

void *operator new(std::size_t size) {
  g_allocation_count.fetch_add(1, std::memory_order_relaxed);
  if (void *allocation = std::malloc(size == 0 ? 1 : size)) {
    return allocation;
  }
  throw std::bad_alloc();
}

void *operator new[](std::size_t size) { return ::operator new(size); }
void *operator new(std::size_t size, const std::nothrow_t &) noexcept {
  g_allocation_count.fetch_add(1, std::memory_order_relaxed);
  return std::malloc(size == 0 ? 1 : size);
}
void *operator new[](std::size_t size, const std::nothrow_t &tag) noexcept {
  return ::operator new(size, tag);
}
void *operator new(std::size_t size, std::align_val_t alignment) {
  g_allocation_count.fetch_add(1, std::memory_order_relaxed);
  void *allocation = nullptr;
  const std::size_t bytes = size == 0 ? 1 : size;
  if (::posix_memalign(&allocation, static_cast<std::size_t>(alignment),
                       bytes) == 0) {
    return allocation;
  }
  throw std::bad_alloc();
}
void *operator new[](std::size_t size, std::align_val_t alignment) {
  return ::operator new(size, alignment);
}
void *operator new(std::size_t size, std::align_val_t alignment,
                   const std::nothrow_t &) noexcept {
  g_allocation_count.fetch_add(1, std::memory_order_relaxed);
  void *allocation = nullptr;
  return ::posix_memalign(&allocation, static_cast<std::size_t>(alignment),
                          size == 0 ? 1 : size) == 0
             ? allocation
             : nullptr;
}
void *operator new[](std::size_t size, std::align_val_t alignment,
                     const std::nothrow_t &tag) noexcept {
  return ::operator new(size, alignment, tag);
}
void operator delete(void *allocation) noexcept { std::free(allocation); }
void operator delete[](void *allocation) noexcept { std::free(allocation); }
void operator delete(void *allocation, const std::nothrow_t &) noexcept {
  std::free(allocation);
}
void operator delete[](void *allocation, const std::nothrow_t &) noexcept {
  std::free(allocation);
}
void operator delete(void *allocation, std::align_val_t) noexcept {
  std::free(allocation);
}
void operator delete[](void *allocation, std::align_val_t) noexcept {
  std::free(allocation);
}
void operator delete(void *allocation, std::align_val_t,
                     const std::nothrow_t &) noexcept {
  std::free(allocation);
}
void operator delete[](void *allocation, std::align_val_t,
                       const std::nothrow_t &) noexcept {
  std::free(allocation);
}
void operator delete(void *allocation, std::size_t, std::align_val_t) noexcept {
  std::free(allocation);
}
void operator delete[](void *allocation, std::size_t,
                       std::align_val_t) noexcept {
  std::free(allocation);
}
void operator delete(void *allocation, std::size_t) noexcept {
  std::free(allocation);
}
void operator delete[](void *allocation, std::size_t) noexcept {
  std::free(allocation);
}

namespace {

using pluto::native::rm2::fill_rm2_scan_slot;
using pluto::native::rm2::kRm2ActiveSlots;
using pluto::native::rm2::kRm2IdleSlot;
using pluto::native::rm2::kRm2PanelHeight;
using pluto::native::rm2::kRm2PanelWidth;
using pluto::native::rm2::kRm2SlotBytes;
using pluto::native::rm2::rgb565_to_rm2_level;
using pluto::native::rm2::Rm2CpuFrequencyBurstLease;
using pluto::native::rm2::Rm2CpuFrequencyLeasePaths;
using pluto::native::rm2::Rm2PanelRect;
using pluto::native::rm2::Rm2PanResult;
using pluto::native::rm2::Rm2PanWorker;
using pluto::native::rm2::Rm2PhaseEncoder;
using pluto::native::rm2::Rm2PhaseRegion;
using pluto::native::rm2::Rm2WaveformProgram;
using pluto::native::rm2::Rm2WaveformSelection;
using pluto::native::rm2::WbfDecoder;

constexpr std::size_t kPanelPixels = kRm2PanelWidth * kRm2PanelHeight;
constexpr std::size_t kWarmupIterations = 8;
constexpr std::size_t kMeasuredIterations = 100;
constexpr double kScanBudgetUs = 11763.0;
constexpr auto kPhaseInterval = std::chrono::microseconds(11'763);
static_assert(kMeasuredIterations >= 40);

std::uint8_t reference_rgb565_level(std::uint16_t pixel) {
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

std::uint64_t production_rgb565_checksum() {
  std::uint64_t checksum = 0xcbf29ce484222325ULL;
  for (std::uint32_t pixel = 0; pixel <= 0xffffU; ++pixel) {
    const std::uint8_t value =
        rgb565_to_rm2_level(static_cast<std::uint16_t>(pixel));
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

Timing summarize_or_zero(std::vector<double> samples) {
  return samples.empty() ? Timing{} : summarize(std::move(samples));
}

std::uint64_t mix_checksum(std::uint64_t aggregate, std::uint64_t value,
                           std::size_t iteration) {
  return aggregate ^ (value + 0x9e3779b97f4a7c15ULL + (aggregate << 6U) +
                      (aggregate >> 2U) + iteration);
}

template <typename Function>
Measurement measure(Function function,
                    std::chrono::nanoseconds minimum_iteration_period =
                        std::chrono::nanoseconds::zero()) {
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
    if (minimum_iteration_period > std::chrono::nanoseconds::zero()) {
      std::this_thread::sleep_until(begin + minimum_iteration_period);
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

std::uint64_t resident_set_bytes() {
#if defined(__linux__)
  std::ifstream input("/proc/self/statm");
  std::uint64_t total_pages = 0;
  std::uint64_t resident_pages = 0;
  if (!(input >> total_pages >> resident_pages)) {
    return 0;
  }
  (void)total_pages;
  const long page_bytes = ::sysconf(_SC_PAGESIZE);
  return page_bytes > 0
             ? resident_pages * static_cast<std::uint64_t>(page_bytes)
             : 0;
#else
  return maximum_rss_bytes();
#endif
}

std::uint64_t cpu_time_us() {
  struct rusage usage {};
  if (::getrusage(RUSAGE_SELF, &usage) != 0) {
    return 0;
  }
  const auto timeval_us = [](const timeval &value) {
    return static_cast<std::uint64_t>(value.tv_sec) * 1'000'000ULL +
           static_cast<std::uint64_t>(value.tv_usec);
  };
  return timeval_us(usage.ru_utime) + timeval_us(usage.ru_stime);
}

struct UsageSnapshot {
  std::uint64_t cpu_nanoseconds = 0;
  std::uint64_t minor_faults = 0;
  std::uint64_t major_faults = 0;
  std::uint64_t voluntary_switches = 0;
  std::uint64_t involuntary_switches = 0;
};

UsageSnapshot usage_snapshot() {
  struct rusage usage {};
  if (::getrusage(RUSAGE_SELF, &usage) != 0) {
    return {};
  }
  const auto timeval_ns = [](const timeval &value) {
    return static_cast<std::uint64_t>(value.tv_sec) * 1'000'000'000ULL +
           static_cast<std::uint64_t>(value.tv_usec) * 1'000ULL;
  };
  return {
      .cpu_nanoseconds =
          timeval_ns(usage.ru_utime) + timeval_ns(usage.ru_stime),
      .minor_faults = static_cast<std::uint64_t>(usage.ru_minflt),
      .major_faults = static_cast<std::uint64_t>(usage.ru_majflt),
      .voluntary_switches = static_cast<std::uint64_t>(usage.ru_nvcsw),
      .involuntary_switches = static_cast<std::uint64_t>(usage.ru_nivcsw),
  };
}

std::uint64_t caller_cpu_nanoseconds() {
#if defined(__linux__) || defined(__APPLE__)
  timespec value{};
  if (::clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) != 0) {
    return 0;
  }
  return static_cast<std::uint64_t>(value.tv_sec) * 1'000'000'000ULL +
         static_cast<std::uint64_t>(value.tv_nsec);
#else
  return 0;
#endif
}

struct MemorySnapshot {
  std::uint64_t vm_size_bytes = 0;
  std::uint64_t vm_rss_bytes = 0;
  std::uint64_t vm_hwm_bytes = 0;
  std::uint64_t rss_anon_bytes = 0;
  std::uint64_t rss_file_bytes = 0;
  std::uint64_t rss_shmem_bytes = 0;
  std::uint64_t pss_bytes = 0;
  std::uint64_t anonymous_bytes = 0;
  std::uint64_t private_clean_bytes = 0;
  std::uint64_t private_dirty_bytes = 0;
  std::uint64_t shared_clean_bytes = 0;
  std::uint64_t shared_dirty_bytes = 0;
  bool status_available = false;
  bool smaps_rollup_available = false;
};

[[maybe_unused]] void assign_kilobyte_field(MemorySnapshot *snapshot,
                                            const char *key,
                                            std::uint64_t value_bytes,
                                            bool rollup) {
  if (snapshot == nullptr) {
    return;
  }
  if (!rollup) {
    if (std::strcmp(key, "VmSize") == 0) {
      snapshot->vm_size_bytes = value_bytes;
    } else if (std::strcmp(key, "VmRSS") == 0) {
      snapshot->vm_rss_bytes = value_bytes;
    } else if (std::strcmp(key, "VmHWM") == 0) {
      snapshot->vm_hwm_bytes = value_bytes;
    } else if (std::strcmp(key, "RssAnon") == 0) {
      snapshot->rss_anon_bytes = value_bytes;
    } else if (std::strcmp(key, "RssFile") == 0) {
      snapshot->rss_file_bytes = value_bytes;
    } else if (std::strcmp(key, "RssShmem") == 0) {
      snapshot->rss_shmem_bytes = value_bytes;
    }
    return;
  }
  if (std::strcmp(key, "Pss") == 0) {
    snapshot->pss_bytes = value_bytes;
  } else if (std::strcmp(key, "Anonymous") == 0) {
    snapshot->anonymous_bytes = value_bytes;
  } else if (std::strcmp(key, "Private_Clean") == 0) {
    snapshot->private_clean_bytes = value_bytes;
  } else if (std::strcmp(key, "Private_Dirty") == 0) {
    snapshot->private_dirty_bytes = value_bytes;
  } else if (std::strcmp(key, "Shared_Clean") == 0) {
    snapshot->shared_clean_bytes = value_bytes;
  } else if (std::strcmp(key, "Shared_Dirty") == 0) {
    snapshot->shared_dirty_bytes = value_bytes;
  }
}

bool read_memory_file(const char *path, bool rollup, MemorySnapshot *snapshot) {
#if defined(__linux__)
  const int input = ::open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (input < 0) {
    return false;
  }
  std::array<char, 16U * 1024U> contents{};
  std::size_t size = 0;
  while (size + 1U < contents.size()) {
    const ssize_t count =
        ::read(input, contents.data() + size, contents.size() - 1U - size);
    if (count < 0) {
      (void)::close(input);
      return false;
    }
    if (count == 0) {
      break;
    }
    size += static_cast<std::size_t>(count);
  }
  const bool complete = size + 1U < contents.size();
  const bool close_ok = ::close(input) == 0;
  contents[size] = '\0';
  char *line = contents.data();
  while (line < contents.data() + size) {
    char *line_end = static_cast<char *>(
        std::memchr(line, '\n', contents.data() + size - line));
    if (line_end == nullptr) {
      line_end = contents.data() + size;
    }
    const char saved = *line_end;
    *line_end = '\0';
    std::array<char, 64> key{};
    unsigned long long value_kb = 0;
    if (std::sscanf(line, "%63[^:]: %llu kB", key.data(), &value_kb) == 2) {
      assign_kilobyte_field(snapshot, key.data(),
                            static_cast<std::uint64_t>(value_kb) * 1024ULL,
                            rollup);
    }
    *line_end = saved;
    line = line_end + (line_end < contents.data() + size ? 1U : 0U);
  }
  return complete && close_ok;
#else
  (void)path;
  (void)rollup;
  (void)snapshot;
  return false;
#endif
}

MemorySnapshot memory_snapshot() {
  MemorySnapshot snapshot;
  snapshot.status_available =
      read_memory_file("/proc/self/status", false, &snapshot);
  snapshot.smaps_rollup_available =
      read_memory_file("/proc/self/smaps_rollup", true, &snapshot);
  if (!snapshot.status_available) {
    snapshot.vm_rss_bytes = resident_set_bytes();
    snapshot.vm_hwm_bytes = maximum_rss_bytes();
  }
  return snapshot;
}

struct FdSnapshot {
  std::size_t open_count = 0;
  std::size_t display_count = 0;
  bool available = false;
};

[[maybe_unused]] bool display_device_target(std::string_view target) {
  return target.starts_with("/dev/fb") || target.starts_with("/dev/dri/") ||
         target == "/dev/mem" || target.starts_with("/dev/disp");
}

FdSnapshot fd_snapshot() {
  FdSnapshot snapshot;
#if defined(__linux__)
  struct LinuxDirent64 {
    std::uint64_t inode;
    std::int64_t offset;
    unsigned short record_size;
    unsigned char type;
    char name[1];
  };
  const int directory =
      ::open("/proc/self/fd", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (directory < 0) {
    return snapshot;
  }
  snapshot.available = true;
  std::array<char, 4096> entries{};
  for (;;) {
    const long count =
        ::syscall(SYS_getdents64, directory, entries.data(), entries.size());
    if (count <= 0) {
      snapshot.available = count == 0;
      break;
    }
    long offset = 0;
    while (offset < count) {
      const auto *entry = reinterpret_cast<const LinuxDirent64 *>(
          entries.data() + static_cast<std::size_t>(offset));
      if (entry->record_size == 0 || offset + entry->record_size > count) {
        snapshot.available = false;
        offset = count;
        continue;
      }
      if (entry->name[0] >= '0' && entry->name[0] <= '9') {
        ++snapshot.open_count;
        std::array<char, 64> path{};
        const int path_size = std::snprintf(path.data(), path.size(),
                                            "/proc/self/fd/%s", entry->name);
        if (path_size > 0 &&
            static_cast<std::size_t>(path_size) < path.size()) {
          std::array<char, PATH_MAX + 1> target{};
          const ssize_t target_size =
              ::readlink(path.data(), target.data(), target.size() - 1U);
          if (target_size > 0) {
            target[static_cast<std::size_t>(target_size)] = '\0';
            snapshot.display_count += display_device_target(target.data());
          }
        }
      }
      offset += entry->record_size;
    }
  }
  (void)::close(directory);
#endif
  return snapshot;
}

std::uint64_t nonnegative_delta(std::uint64_t after, std::uint64_t before) {
  return after >= before ? after - before : 0;
}

void reference_encode_region(std::span<std::byte> slot,
                             const Rm2PanelRect &rect,
                             std::span<const std::uint8_t> transitions,
                             std::span<const std::uint8_t> phase_lut) {
  constexpr std::size_t kPreambleRows = 4;
  constexpr std::size_t kFirstPixelCell = 26;
  const std::size_t rows = rect.row_count();
  for (std::size_t local_column = 0; local_column < rect.column_count();
       ++local_column) {
    const std::size_t source_base = local_column * rows;
    const std::size_t scan_line =
        kPreambleRows + rect.column_min + local_column;
    for (std::size_t local_row = 0; local_row < rows; local_row += 8U) {
      std::uint16_t packed = 0;
      for (std::size_t lane = 0; lane < 8U; ++lane) {
        packed |=
            static_cast<std::uint16_t>(
                phase_lut[transitions[source_base + local_row + lane]] & 3U)
            << ((7U - lane) * 2U);
      }
      const std::size_t offset =
          scan_line * pluto::native::rm2::kRm2ScanoutStrideBytes +
          (kFirstPixelCell + (rect.row_min + local_row) / 8U) *
              sizeof(std::uint32_t);
      std::uint32_t cell = 0;
      std::memcpy(&cell, slot.data() + offset, sizeof(cell));
      cell = (cell & 0xffff0000U) | packed;
      std::memcpy(slot.data() + offset, &cell, sizeof(cell));
    }
  }
}

void reference_encode_full(std::span<std::byte> slot,
                           std::span<const std::uint8_t> transitions,
                           std::span<const std::uint8_t> phase_lut) {
  const Rm2PanelRect full_panel{
      .row_min = 0,
      .row_max = static_cast<std::uint16_t>(kRm2PanelHeight - 1U),
      .column_min = 0,
      .column_max = static_cast<std::uint16_t>(kRm2PanelWidth - 1U),
  };
  reference_encode_region(slot, full_panel, transitions, phase_lut);
}

std::optional<std::size_t> parse_phase_soak(int argc, char **argv) {
  if (argc == 1) {
    return std::nullopt;
  }
  constexpr std::string_view kPrefix = "--phase-soak=";
  const std::string_view argument(argv[1]);
  if (argc != 2 || !argument.starts_with(kPrefix)) {
    return 0;
  }
  const std::string_view digits = argument.substr(kPrefix.size());
  std::size_t value = 0;
  for (const char digit : digits) {
    if (digit < '0' || digit > '9' ||
        value > (1'000'000U - static_cast<std::size_t>(digit - '0')) / 10U) {
      return 0;
    }
    value = value * 10U + static_cast<std::size_t>(digit - '0');
  }
  return value == 0 ? std::optional<std::size_t>{0}
                    : std::optional<std::size_t>{value};
}

std::optional<std::size_t> parse_positive_count(std::string_view argument,
                                                std::string_view prefix,
                                                std::size_t maximum) {
  if (!argument.starts_with(prefix)) {
    return std::nullopt;
  }
  const std::string_view digits = argument.substr(prefix.size());
  std::size_t value = 0;
  for (const char digit : digits) {
    if (digit < '0' || digit > '9' ||
        value > (maximum - static_cast<std::size_t>(digit - '0')) / 10U) {
      return 0;
    }
    value = value * 10U + static_cast<std::size_t>(digit - '0');
  }
  return value == 0 ? std::optional<std::size_t>{0}
                    : std::optional<std::size_t>{value};
}

Rm2CpuFrequencyLeasePaths production_frequency_paths() {
  return {
      .policy_path = pluto::native::rm2::kRm2CpuPolicyPath,
      .receipt_path = pluto::native::rm2::kRm2CpuReceiptPath,
      .lock_path = pluto::native::rm2::kRm2CpuLockPath,
      .cpu_thermal_type_path = pluto::native::rm2::kRm2CpuThermalTypePath,
      .cpu_temperature_path = pluto::native::rm2::kRm2CpuTemperaturePath,
  };
}

[[maybe_unused]] bool print_frequency_receipt_identity() {
#if defined(__linux__)
  FILE *input = std::fopen(pluto::native::rm2::kRm2CpuReceiptPath, "rb");
  if (input == nullptr) {
    std::printf("rm2_phase_pipeline_receipt valid=0 path=%s reason=open\n",
                pluto::native::rm2::kRm2CpuReceiptPath);
    return false;
  }
  std::array<char, 513> receipt{};
  const std::size_t size =
      std::fread(receipt.data(), 1, receipt.size() - 1U, input);
  const bool read_ok = !std::ferror(input) && std::feof(input) != 0;
  const bool close_ok = std::fclose(input) == 0;
  receipt[size] = '\0';

  std::array<char, 160> policy{};
  std::array<char, 64> governor{};
  long owner_pid = 0;
  unsigned long long owner_start_ticks = 0;
  unsigned long long original_minimum = 0;
  unsigned long long original_maximum = 0;
  const int fields =
      std::sscanf(receipt.data(),
                  "policy=%159[^\n]\nowner_pid=%ld\nowner_start_ticks=%llu\n"
                  "original_min_khz=%llu\noriginal_max_khz=%llu\n"
                  "original_governor=%63[^\n]\n",
                  policy.data(), &owner_pid, &owner_start_ticks,
                  &original_minimum, &original_maximum, governor.data());
  const bool valid =
      read_ok && close_ok && size != 0 && size < receipt.size() - 1U &&
      receipt[size - 1U] == '\n' && fields == 6 &&
      std::strcmp(policy.data(), pluto::native::rm2::kRm2CpuPolicyPath) == 0 &&
      owner_pid == static_cast<long>(::getpid());
  const std::string digest = pluto::sha256_hex(std::span<const std::uint8_t>(
      reinterpret_cast<const std::uint8_t *>(receipt.data()), size));
  std::printf("rm2_phase_pipeline_receipt valid=%u path=%s bytes=%zu sha256=%s "
              "policy=%s owner_pid=%ld owner_start_ticks=%llu "
              "original_min_khz=%llu original_max_khz=%llu "
              "original_governor=%s\n",
              valid ? 1U : 0U, pluto::native::rm2::kRm2CpuReceiptPath, size,
              digest.c_str(), policy.data(), owner_pid, owner_start_ticks,
              original_minimum, original_maximum, governor.data());
  return valid;
#else
  return true;
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

void configure_benchmark_thread() {
#if defined(__linux__) && defined(__arm__)
  sched_param policy{};
  policy.sched_priority = 60;
  const int policy_error =
      pthread_setschedparam(pthread_self(), SCHED_FIFO, &policy);
  cpu_set_t affinity;
  CPU_ZERO(&affinity);
  CPU_SET(0, &affinity);
  const int affinity_error =
      pthread_setaffinity_np(pthread_self(), sizeof(affinity), &affinity);
  std::printf("rm2_bench_thread policy=SCHED_FIFO priority=60 cpu=0 "
              "policy_error=%d affinity_error=%d\n",
              policy_error, affinity_error);
#else
  std::printf("rm2_bench_thread policy=host-default priority=0 cpu=any "
              "policy_error=0 affinity_error=0\n");
#endif
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

int run_frequency_lease_probe(std::size_t iterations) {
  Rm2CpuFrequencyBurstLease lease(production_frequency_paths());
  std::vector<double> acquire_samples;
  std::vector<double> release_samples;
  acquire_samples.reserve(iterations);
  release_samples.reserve(iterations);
  std::string error;
  const std::uint64_t rss_before = resident_set_bytes();
  const std::uint64_t allocations_before =
      g_allocation_count.load(std::memory_order_relaxed);
  for (std::size_t iteration = 0; iteration < iterations; ++iteration) {
    const auto acquire_begin = std::chrono::steady_clock::now();
    if (!lease.acquire(&error)) {
      std::fprintf(stderr,
                   "RM2 production frequency lease acquire failed at %zu: "
                   "%s\n",
                   iteration, error.c_str());
      return 1;
    }
    const auto acquire_end = std::chrono::steady_clock::now();
    acquire_samples.push_back(
        std::chrono::duration<double, std::micro>(acquire_end - acquire_begin)
            .count());

    const auto release_begin = std::chrono::steady_clock::now();
    if (!lease.release(&error)) {
      std::fprintf(stderr,
                   "RM2 production frequency lease restore failed at %zu: "
                   "%s\n",
                   iteration, error.c_str());
      return 1;
    }
    const auto release_end = std::chrono::steady_clock::now();
    release_samples.push_back(
        std::chrono::duration<double, std::micro>(release_end - release_begin)
            .count());
  }
  const std::uint64_t allocations_after =
      g_allocation_count.load(std::memory_order_relaxed);
  const std::uint64_t rss_after = resident_set_bytes();
  const Timing acquire = summarize(std::move(acquire_samples));
  const Timing release = summarize(std::move(release_samples));
  std::printf(
      "rm2_frequency_lease_probe iterations=%zu "
      "acquire_min_us=%.1f acquire_p50_us=%.1f acquire_p95_us=%.1f "
      "acquire_p99_us=%.1f acquire_max_us=%.1f release_min_us=%.1f "
      "release_p50_us=%.1f release_p95_us=%.1f release_p99_us=%.1f "
      "release_max_us=%.1f allocation_delta=%llu rss_delta_bytes=%lld "
      "receipt=%s policy=%s\n",
      iterations, acquire.min_us, acquire.p50_us, acquire.p95_us,
      acquire.p99_us, acquire.max_us, release.min_us, release.p50_us,
      release.p95_us, release.p99_us, release.max_us,
      static_cast<unsigned long long>(allocations_after - allocations_before),
      static_cast<long long>(static_cast<std::int64_t>(rss_after) -
                             static_cast<std::int64_t>(rss_before)),
      pluto::native::rm2::kRm2CpuReceiptPath,
      pluto::native::rm2::kRm2CpuPolicyPath);
  return allocations_before == allocations_after ? 0 : 1;
}

int run_frequency_lease_hold(std::size_t milliseconds) {
  Rm2CpuFrequencyBurstLease lease(production_frequency_paths());
  std::string error;
  const auto acquire_begin = std::chrono::steady_clock::now();
  if (!lease.acquire(&error)) {
    std::fprintf(stderr, "RM2 production frequency lease acquire failed: %s\n",
                 error.c_str());
    return 1;
  }
  const auto acquire_end = std::chrono::steady_clock::now();
  std::printf(
      "rm2_frequency_lease_hold ready=1 pid=%ld hold_ms=%zu acquire_us=%.1f "
      "receipt=%s policy=%s\n",
      static_cast<long>(::getpid()), milliseconds,
      std::chrono::duration<double, std::micro>(acquire_end - acquire_begin)
          .count(),
      pluto::native::rm2::kRm2CpuReceiptPath,
      pluto::native::rm2::kRm2CpuPolicyPath);
  std::fflush(stdout);
  std::this_thread::sleep_for(std::chrono::milliseconds(milliseconds));
  const auto release_begin = std::chrono::steady_clock::now();
  if (!lease.release(&error)) {
    std::fprintf(stderr, "RM2 production frequency lease restore failed: %s\n",
                 error.c_str());
    return 1;
  }
  const auto release_end = std::chrono::steady_clock::now();
  std::printf(
      "rm2_frequency_lease_hold restored=1 release_us=%.1f\n",
      std::chrono::duration<double, std::micro>(release_end - release_begin)
          .count());
  return 0;
}

int run_real_wbf_open(std::string_view path) {
  const auto *generated = pluto::generated_device_profile_by_id("rm2");
  if (generated == nullptr ||
      generated->runtime.waveform.accepted_sources.size() != 1U) {
    return 1;
  }
  const std::uint64_t rss_before = resident_set_bytes();
  const std::uint64_t allocations_before =
      g_allocation_count.load(std::memory_order_relaxed);
  const std::uint64_t cpu_before = cpu_time_us();
  const auto wall_before = std::chrono::steady_clock::now();
  Rm2WaveformProgram program;
  std::string error;
  const bool opened = program.open(*generated, path, &error);
  const auto wall_after = std::chrono::steady_clock::now();
  const std::uint64_t cpu_after = cpu_time_us();
  const std::uint64_t allocations_after =
      g_allocation_count.load(std::memory_order_relaxed);
  const std::uint64_t rss_after = resident_set_bytes();
  if (!opened) {
    std::fprintf(stderr, "real WBF open failed: %s\n", error.c_str());
    return 1;
  }

  const auto &metadata = program.decoder().metadata();
  std::size_t expanded_bytes = 0;
  constexpr std::array<PlutoRefreshClass, 3> kUniqueRefreshModes{
      kPlutoRefreshText, kPlutoRefreshUi, kPlutoRefreshFast};
  for (std::size_t temperature = 0; temperature < metadata.temperature_count;
       ++temperature) {
    const int milli_celsius =
        static_cast<int>(metadata.temperature_boundaries_celsius[temperature]) *
        1000;
    for (const PlutoRefreshClass refresh_class : kUniqueRefreshModes) {
      Rm2WaveformSelection selection;
      if (!program.select(refresh_class, milli_celsius, &selection)) {
        return 1;
      }
      expanded_bytes +=
          selection.drive_lut.size() + selection.partial_drive_lut.size();
    }
  }
  const std::uint64_t wall_us = static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::microseconds>(wall_after -
                                                            wall_before)
          .count());
  std::printf(
      "rm2_real_wbf sha256=%s file_bytes=%u panel=%s fpl_lot=%u "
      "modes=%u temperatures=%u unique_records=%zu decoded_packed_bytes=%zu "
      "expanded_bytes=%zu open_wall_us=%llu open_cpu_us=%llu "
      "allocation_delta=%llu rss_delta_bytes=%lld\n",
      pluto::native::rm2::wbf_sha256_hex(metadata.source_sha256).c_str(),
      metadata.file_size, metadata.panel_signature.c_str(), metadata.fpl_lot,
      metadata.mode_count, metadata.temperature_count,
      metadata.unique_record_count, metadata.decoded_packed_bytes,
      expanded_bytes, static_cast<unsigned long long>(wall_us),
      static_cast<unsigned long long>(cpu_after - cpu_before),
      static_cast<unsigned long long>(allocations_after - allocations_before),
      static_cast<long long>(static_cast<std::int64_t>(rss_after) -
                             static_cast<std::int64_t>(rss_before)));
  return pluto::native::rm2::wbf_sha256_hex(metadata.source_sha256) ==
                 "79783d751ba066af12c6ac5aca46279fe7c79d4ef834105bd46824f870f9c"
                 "6f8"
             ? 0
             : 1;
}

class MappedPhaseSlots final {
public:
  MappedPhaseSlots() : bytes_(kRm2ActiveSlots * kRm2SlotBytes) {
    mapping_ = ::mmap(nullptr, bytes_, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mapping_ == MAP_FAILED) {
      mapping_ = nullptr;
    }
  }

  ~MappedPhaseSlots() {
    if (mapping_ != nullptr) {
      (void)::munmap(mapping_, bytes_);
    }
  }

  bool valid() const { return mapping_ != nullptr; }
  std::span<std::byte> slot(std::size_t index) {
    if (!valid() || index >= kRm2ActiveSlots) {
      return {};
    }
    return {static_cast<std::byte *>(mapping_) + index * kRm2SlotBytes,
            kRm2SlotBytes};
  }

private:
  void *mapping_ = nullptr;
  std::size_t bytes_ = 0;
};

enum class PhaseSoakMode {
  kCombined,
  kCorrectnessOnly,
  kProductionOnly,
};

int run_phase_soak(std::size_t jobs, std::span<const std::uint8_t> transitions,
                   std::span<const std::uint8_t> expanded,
                   Rm2CpuFrequencyBurstLease *frequency_guard,
                   PhaseSoakMode mode) {
  constexpr std::size_t kIdleWakeTests = 8;
  constexpr double kEncodeP99BudgetUs = 8234.0;
  constexpr auto kCadenceDeadline = kPhaseInterval + kPhaseInterval / 20;
  const auto setup_begin = std::chrono::steady_clock::now();
  const Rm2PanelRect full_panel{
      .row_min = 0,
      .row_max = static_cast<std::uint16_t>(kRm2PanelHeight - 1U),
      .column_min = 0,
      .column_max = static_cast<std::uint16_t>(kRm2PanelWidth - 1U),
  };

  std::array<std::vector<std::uint8_t>, 2> transition_patterns;
  transition_patterns[0].assign(transitions.begin(), transitions.end());
  transition_patterns[1].resize(transitions.size());
  for (std::size_t index = 0; index < transitions.size(); ++index) {
    transition_patterns[1][index] = static_cast<std::uint8_t>(
        transitions[index] ^ static_cast<std::uint8_t>(0xa5U + index * 17U));
  }
  std::array<std::vector<std::uint8_t>, 2> phase_patterns;
  phase_patterns[0].assign(expanded.begin(), expanded.end());
  phase_patterns[1].resize(expanded.size());
  for (std::size_t index = 0; index < expanded.size(); ++index) {
    phase_patterns[1][index] = static_cast<std::uint8_t>(
        (expanded[expanded.size() - 1U - index] + index + 1U) & 0x03U);
  }
  std::array<std::vector<std::byte>, 2> expected_slots{
      std::vector<std::byte>(kRm2SlotBytes),
      std::vector<std::byte>(kRm2SlotBytes),
  };
  for (std::size_t pattern = 0; pattern < expected_slots.size(); ++pattern) {
    if (!fill_rm2_scan_slot(expected_slots[pattern], 0)) {
      return 1;
    }
    reference_encode_full(expected_slots[pattern], transition_patterns[pattern],
                          phase_patterns[pattern]);
  }
  const auto slot_sha256 = [](std::span<const std::byte> bytes) {
    return pluto::sha256_hex(std::span<const std::uint8_t>(
        reinterpret_cast<const std::uint8_t *>(bytes.data()), bytes.size()));
  };
  const std::array<std::string, 2> reference_sha256{
      slot_sha256(expected_slots[0]),
      slot_sha256(expected_slots[1]),
  };
  const auto reference_setup_end = std::chrono::steady_clock::now();

  MappedPhaseSlots slots;
  if (!slots.valid()) {
    std::fprintf(stderr, "RM2 anonymous mmap slot ring failed\n");
    return 1;
  }
  for (std::size_t slot = 0; slot < kRm2ActiveSlots; ++slot) {
    if (!fill_rm2_scan_slot(slots.slot(slot), 0)) {
      return 1;
    }
  }
  const auto slot_setup_end = std::chrono::steady_clock::now();

  Rm2PhaseEncoder phase_encoder;
  std::array<std::atomic<std::uint64_t>, kRm2ActiveSlots> generations{};
  std::atomic<std::uint64_t> latched_slot_mutations{0};
  Rm2PanWorker pan_worker(
      [&](std::uint32_t slot, std::chrono::nanoseconds *out_duration) {
        const std::uint64_t generation_before =
            slot < kRm2ActiveSlots
                ? generations[slot].load(std::memory_order_acquire)
                : 0;
        const auto begin = std::chrono::steady_clock::now();
        std::this_thread::sleep_until(begin + kPhaseInterval);
        const auto end = std::chrono::steady_clock::now();
        *out_duration =
            std::chrono::duration_cast<std::chrono::nanoseconds>(end - begin);
        if (slot < kRm2ActiveSlots &&
            generations[slot].load(std::memory_order_acquire) !=
                generation_before) {
          latched_slot_mutations.fetch_add(1, std::memory_order_relaxed);
        }
        return slot <= kRm2IdleSlot;
      });
  if (!phase_encoder.ready() || !pan_worker.ready()) {
    std::fprintf(stderr,
                 "RM2 phase or blocking-pan worker did not acquire policy\n");
    return 1;
  }
  const auto worker_setup_end = std::chrono::steady_clock::now();

  const auto pattern_for_phase = [](std::size_t phase) {
    return (phase ^ (phase / kRm2ActiveSlots)) & 1U;
  };
  const auto reserve_and_prefault = [](std::vector<double> *samples,
                                       std::size_t capacity) {
    samples->reserve(capacity);
    samples->resize(capacity, 0.0);
    constexpr std::size_t kDoublesPerPage = 4096U / sizeof(double);
    for (std::size_t index = 0; index < capacity; index += kDoublesPerPage) {
      (*samples)[index] = static_cast<double>(index + 1U);
    }
    samples->clear();
  };

  std::vector<double> wake_encode_samples;
  std::vector<double> correctness_encode_samples;
  std::vector<double> oracle_samples;
  std::vector<double> encode_samples;
  std::vector<double> pan_begin_samples;
  std::vector<double> cadence_samples;
  std::vector<double> pan_samples;
  reserve_and_prefault(&wake_encode_samples, kIdleWakeTests);
  reserve_and_prefault(&correctness_encode_samples, jobs);
  reserve_and_prefault(&oracle_samples, jobs);
  reserve_and_prefault(&encode_samples, jobs);
  reserve_and_prefault(&pan_begin_samples, jobs);
  reserve_and_prefault(&cadence_samples, jobs);
  reserve_and_prefault(&pan_samples, jobs);

  std::size_t wake_failures = 0;
  for (std::size_t wake = 0; wake < kIdleWakeTests; ++wake) {
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    const std::size_t pattern = wake & 1U;
    const auto encode_begin = std::chrono::steady_clock::now();
    const bool encoded = phase_encoder.encode(slots.slot(0), full_panel,
                                              transition_patterns[pattern],
                                              phase_patterns[pattern]);
    const auto encode_end = std::chrono::steady_clock::now();
    wake_encode_samples.push_back(
        std::chrono::duration<double, std::micro>(encode_end - encode_begin)
            .count());
    wake_failures += !encoded;
    wake_failures +=
        std::memcmp(slots.slot(0).data(), expected_slots[pattern].data(),
                    kRm2SlotBytes) != 0;
  }
  for (std::size_t slot = 0; slot < kRm2ActiveSlots; ++slot) {
    if (!fill_rm2_scan_slot(slots.slot(slot), 0)) {
      return 1;
    }
  }

  // Byte parity is a distinct pass: its 1.46 MiB oracle is never enclosed by
  // the production resource interval below. This preserves an every-phase
  // independent reference while keeping CPU attribution honest.
  std::size_t reference_failures = 0;
  std::size_t correctness_encode_failures = 0;
  std::size_t correctness_thermal_checks = 0;
  std::size_t correctness_thermal_failures = 0;
  int correctness_maximum_cpu_temperature = 0;
  std::string correctness_thermal_error;
  std::uint64_t oracle_caller_cpu_ns = 0;
  const MemorySnapshot correctness_memory_before = memory_snapshot();
  const FdSnapshot correctness_fds_before = fd_snapshot();
  const std::uint64_t correctness_allocations_before =
      g_allocation_count.load(std::memory_order_relaxed);
  const UsageSnapshot correctness_usage_before = usage_snapshot();
  const std::uint64_t correctness_caller_before = caller_cpu_nanoseconds();
  const auto correctness_worker_before = phase_encoder.worker_cpu_time();
  const auto correctness_wall_before = std::chrono::steady_clock::now();
  for (std::size_t phase = 0;
       mode != PhaseSoakMode::kProductionOnly && phase < jobs; ++phase) {
    const std::size_t slot_index = phase % kRm2ActiveSlots;
    const std::size_t pattern = pattern_for_phase(phase);
    const auto encode_begin = std::chrono::steady_clock::now();
    const bool encoded = phase_encoder.encode(
        slots.slot(slot_index), full_panel, transition_patterns[pattern],
        phase_patterns[pattern]);
    const auto encode_end = std::chrono::steady_clock::now();
    correctness_encode_samples.push_back(
        std::chrono::duration<double, std::micro>(encode_end - encode_begin)
            .count());
    correctness_encode_failures += !encoded;

    const std::uint64_t oracle_cpu_before = caller_cpu_nanoseconds();
    const auto oracle_begin = std::chrono::steady_clock::now();
    const bool matches =
        std::memcmp(slots.slot(slot_index).data(),
                    expected_slots[pattern].data(), kRm2SlotBytes) == 0;
    const auto oracle_end = std::chrono::steady_clock::now();
    const std::uint64_t oracle_cpu_after = caller_cpu_nanoseconds();
    oracle_samples.push_back(
        std::chrono::duration<double, std::micro>(oracle_end - oracle_begin)
            .count());
    oracle_caller_cpu_ns +=
        nonnegative_delta(oracle_cpu_after, oracle_cpu_before);
    reference_failures += !matches;
    if (frequency_guard != nullptr &&
        ((phase + 1U) % 128U == 0 || phase + 1U == jobs)) {
      int temperature = 0;
      ++correctness_thermal_checks;
      if (!frequency_guard->temperature_safe(&temperature,
                                             &correctness_thermal_error)) {
        ++correctness_thermal_failures;
        break;
      }
      correctness_maximum_cpu_temperature =
          std::max(correctness_maximum_cpu_temperature, temperature);
    }
  }
  const auto correctness_wall_after = std::chrono::steady_clock::now();
  const auto correctness_worker_after = phase_encoder.worker_cpu_time();
  const std::uint64_t correctness_caller_after = caller_cpu_nanoseconds();
  const UsageSnapshot correctness_usage_after = usage_snapshot();
  const std::uint64_t correctness_allocations_after =
      g_allocation_count.load(std::memory_order_relaxed);
  const FdSnapshot correctness_fds_after = fd_snapshot();
  const MemorySnapshot correctness_memory_after = memory_snapshot();
  const std::size_t correctness_completed_phases =
      correctness_encode_samples.size();

  if (mode == PhaseSoakMode::kCorrectnessOnly) {
    const Timing wake_timing =
        summarize_or_zero(std::move(wake_encode_samples));
    const Timing encode_timing =
        summarize_or_zero(std::move(correctness_encode_samples));
    const Timing oracle_timing = summarize_or_zero(std::move(oracle_samples));
    const std::uint64_t correctness_wall_us = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            correctness_wall_after - correctness_wall_before)
            .count());
    const std::uint64_t process_cpu_ns =
        nonnegative_delta(correctness_usage_after.cpu_nanoseconds,
                          correctness_usage_before.cpu_nanoseconds);
    const std::uint64_t caller_cpu_ns =
        nonnegative_delta(correctness_caller_after, correctness_caller_before);
    const std::uint64_t worker_cpu_ns = nonnegative_delta(
        static_cast<std::uint64_t>(correctness_worker_after.count()),
        static_cast<std::uint64_t>(correctness_worker_before.count()));
    const std::int64_t rss_delta =
        static_cast<std::int64_t>(correctness_memory_after.vm_rss_bytes) -
        static_cast<std::int64_t>(correctness_memory_before.vm_rss_bytes);
    const std::int64_t pss_delta =
        static_cast<std::int64_t>(correctness_memory_after.pss_bytes) -
        static_cast<std::int64_t>(correctness_memory_before.pss_bytes);
    std::printf(
        "rm2_phase_correctness_soak requested_phases=%zu "
        "completed_phases=%zu idle_wake_tests=%zu wake_failures=%zu "
        "wake_encode_p99_us=%.1f encode_p50_us=%.1f encode_p95_us=%.1f "
        "encode_p99_us=%.1f encode_max_us=%.1f oracle_p50_us=%.1f "
        "oracle_p99_us=%.1f oracle_max_us=%.1f encode_failures=%zu "
        "reference_failures=%zu thermal_checks=%zu thermal_failures=%zu "
        "thermal_error=\"%s\" max_cpu_temperature_millidegrees=%d\n",
        jobs, correctness_completed_phases, kIdleWakeTests, wake_failures,
        wake_timing.p99_us, encode_timing.p50_us, encode_timing.p95_us,
        encode_timing.p99_us, encode_timing.max_us, oracle_timing.p50_us,
        oracle_timing.p99_us, oracle_timing.max_us, correctness_encode_failures,
        reference_failures, correctness_thermal_checks,
        correctness_thermal_failures, correctness_thermal_error.c_str(),
        correctness_maximum_cpu_temperature);
    std::printf("rm2_phase_correctness_reference pattern0_sha256=%s "
                "pattern1_sha256=%s verification=full-slot-memcmp-every-phase "
                "oracle_caller_cpu_us=%.1f\n",
                reference_sha256[0].c_str(), reference_sha256[1].c_str(),
                static_cast<double>(oracle_caller_cpu_ns) / 1000.0);
    std::printf(
        "rm2_phase_correctness_resources process_cpu_us=%.1f "
        "caller_cpu_us=%.1f phase_worker_cpu_us=%.1f wall_us=%llu "
        "allocations_before=%llu allocations_after=%llu "
        "allocation_delta=%llu rss_before_bytes=%llu rss_after_bytes=%llu "
        "rss_delta_bytes=%lld vm_hwm_before_bytes=%llu "
        "vm_hwm_after_bytes=%llu pss_before_bytes=%llu "
        "pss_after_bytes=%llu pss_delta_bytes=%lld fd_before=%zu "
        "fd_after=%zu display_fds_before=%zu display_fds_after=%zu\n",
        static_cast<double>(process_cpu_ns) / 1000.0,
        static_cast<double>(caller_cpu_ns) / 1000.0,
        static_cast<double>(worker_cpu_ns) / 1000.0,
        static_cast<unsigned long long>(correctness_wall_us),
        static_cast<unsigned long long>(correctness_allocations_before),
        static_cast<unsigned long long>(correctness_allocations_after),
        static_cast<unsigned long long>(correctness_allocations_after -
                                        correctness_allocations_before),
        static_cast<unsigned long long>(correctness_memory_before.vm_rss_bytes),
        static_cast<unsigned long long>(correctness_memory_after.vm_rss_bytes),
        static_cast<long long>(rss_delta),
        static_cast<unsigned long long>(correctness_memory_before.vm_hwm_bytes),
        static_cast<unsigned long long>(correctness_memory_after.vm_hwm_bytes),
        static_cast<unsigned long long>(correctness_memory_before.pss_bytes),
        static_cast<unsigned long long>(correctness_memory_after.pss_bytes),
        static_cast<long long>(pss_delta), correctness_fds_before.open_count,
        correctness_fds_after.open_count, correctness_fds_before.display_count,
        correctness_fds_after.display_count);
    return correctness_completed_phases == jobs && wake_failures == 0 &&
                   correctness_encode_failures == 0 &&
                   reference_failures == 0 &&
                   correctness_thermal_failures == 0 &&
                   correctness_allocations_before ==
                       correctness_allocations_after &&
                   correctness_memory_before.vm_rss_bytes ==
                       correctness_memory_after.vm_rss_bytes &&
                   correctness_fds_before.display_count == 0 &&
                   correctness_fds_after.display_count == 0
               ? 0
               : 1;
  }

  for (std::size_t slot = 0; slot < kRm2ActiveSlots; ++slot) {
    if (!fill_rm2_scan_slot(slots.slot(slot), 0)) {
      return 1;
    }
  }
  // Let the helper settle before taking the production baseline. In the
  // legacy build this also guarantees its bounded post-job spin has ended.
  std::this_thread::sleep_for(std::chrono::milliseconds(30));

  Rm2PanResult anchor_result;
  if (!pan_worker.begin(kRm2IdleSlot) || !pan_worker.finish(&anchor_result) ||
      !anchor_result.operation_ok) {
    return 1;
  }

  std::size_t encode_failures = 0;
  std::size_t encode_budget_exceedances = 0;
  std::size_t deadline_misses = 0;
  std::size_t cadence_misses = 0;
  std::size_t underflows = 0;
  std::size_t pan_failures = 0;
  std::size_t thermal_checks = 0;
  std::size_t thermal_failures = 0;
  int maximum_cpu_temperature = 0;
  std::string thermal_error;

  const auto encode_phase = [&](std::size_t phase) {
    const std::size_t slot_index = phase % kRm2ActiveSlots;
    const std::size_t pattern = pattern_for_phase(phase);
    const auto begin = std::chrono::steady_clock::now();
    const bool encoded = phase_encoder.encode(
        slots.slot(slot_index), full_panel, transition_patterns[pattern],
        phase_patterns[pattern]);
    const auto end = std::chrono::steady_clock::now();
    const double elapsed_us =
        std::chrono::duration<double, std::micro>(end - begin).count();
    encode_samples.push_back(elapsed_us);
    encode_failures += !encoded;
    encode_budget_exceedances += elapsed_us > kEncodeP99BudgetUs;
    underflows += end - begin > kPhaseInterval;
    generations[slot_index].fetch_add(1, std::memory_order_release);
  };
  const auto begin_pan = [&](std::uint32_t slot) {
    const auto begin = std::chrono::steady_clock::now();
    const bool accepted = pan_worker.begin(slot);
    const auto end = std::chrono::steady_clock::now();
    pan_begin_samples.push_back(
        std::chrono::duration<double, std::micro>(end - begin).count());
    return accepted;
  };

  const MemorySnapshot memory_before = memory_snapshot();
  const FdSnapshot fds_before = fd_snapshot();
  const std::uint64_t allocations_before =
      g_allocation_count.load(std::memory_order_relaxed);
  const UsageSnapshot usage_before = usage_snapshot();
  const std::uint64_t caller_cpu_before = caller_cpu_nanoseconds();
  const auto phase_worker_cpu_before = phase_encoder.worker_cpu_time();
  const auto pan_worker_cpu_before = pan_worker.worker_cpu_time();
  const auto wall_before = std::chrono::steady_clock::now();
  encode_phase(0);
  auto pan_begin = std::chrono::steady_clock::now();
  if (!begin_pan(0)) {
    return 1;
  }
  for (std::size_t phase = 0; phase < jobs; ++phase) {
    if (phase + 1U < jobs) {
      encode_phase(phase + 1U);
    }
    Rm2PanResult result;
    if (!pan_worker.finish(&result) || !result.operation_ok) {
      ++pan_failures;
      break;
    }
    const auto boundary = std::chrono::steady_clock::now();
    const auto cadence = boundary - pan_begin;
    cadence_samples.push_back(
        std::chrono::duration<double, std::micro>(cadence).count());
    pan_samples.push_back(
        std::chrono::duration<double, std::micro>(result.duration).count());
    const bool pan_missed = result.duration > kCadenceDeadline;
    const bool cadence_missed = cadence > kCadenceDeadline;
    deadline_misses += pan_missed || cadence_missed;
    cadence_misses += cadence_missed;
    underflows += pan_missed || cadence > kPhaseInterval * 2;
    if (frequency_guard != nullptr &&
        ((phase + 1U) % 128U == 0 || phase + 1U == jobs)) {
      int temperature = 0;
      ++thermal_checks;
      if (!frequency_guard->temperature_safe(&temperature, &thermal_error)) {
        ++thermal_failures;
        break;
      }
      maximum_cpu_temperature = std::max(maximum_cpu_temperature, temperature);
    }
    if (phase + 1U < jobs) {
      pan_begin = std::chrono::steady_clock::now();
      if (!begin_pan(
              static_cast<std::uint32_t>((phase + 1U) % kRm2ActiveSlots))) {
        ++pan_failures;
        break;
      }
    }
  }
  const auto wall_after = std::chrono::steady_clock::now();
  const auto pan_worker_cpu_after = pan_worker.worker_cpu_time();
  const auto phase_worker_cpu_after = phase_encoder.worker_cpu_time();
  const std::uint64_t caller_cpu_after = caller_cpu_nanoseconds();
  const UsageSnapshot usage_after = usage_snapshot();
  const std::uint64_t allocations_after =
      g_allocation_count.load(std::memory_order_relaxed);
  const FdSnapshot fds_after = fd_snapshot();
  const MemorySnapshot memory_after = memory_snapshot();

  Rm2PanResult idle_result;
  if (!pan_worker.begin(kRm2IdleSlot) || !pan_worker.finish(&idle_result) ||
      !idle_result.operation_ok) {
    ++pan_failures;
  }

  const auto final_verify_begin = std::chrono::steady_clock::now();
  std::size_t post_production_reference_failures = 0;
  const std::size_t encoded_phases = encode_samples.size();
  const std::size_t completed_phases = cadence_samples.size();
  const std::size_t used_slots = std::min(encoded_phases, kRm2ActiveSlots);
  for (std::size_t slot = 0; slot < used_slots; ++slot) {
    const std::size_t last_phase =
        slot +
        ((encoded_phases - 1U - slot) / kRm2ActiveSlots) * kRm2ActiveSlots;
    const std::size_t pattern = pattern_for_phase(last_phase);
    post_production_reference_failures +=
        std::memcmp(slots.slot(slot).data(), expected_slots[pattern].data(),
                    kRm2SlotBytes) != 0;
  }
  const auto final_verify_end = std::chrono::steady_clock::now();

  const Timing wake_encode_timing =
      summarize_or_zero(std::move(wake_encode_samples));
  const Timing correctness_encode_timing =
      summarize_or_zero(std::move(correctness_encode_samples));
  const Timing oracle_timing = summarize_or_zero(std::move(oracle_samples));
  const Timing encode_timing = summarize_or_zero(std::move(encode_samples));
  const Timing pan_begin_timing =
      summarize_or_zero(std::move(pan_begin_samples));
  const Timing cadence_timing = summarize_or_zero(std::move(cadence_samples));
  const Timing pan_timing = summarize_or_zero(std::move(pan_samples));
  const double serial_p99_us = encode_timing.p99_us + pan_timing.p99_us;
  const std::uint64_t wall_us = static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::microseconds>(wall_after -
                                                            wall_before)
          .count());
  const std::uint64_t process_cpu_ns = nonnegative_delta(
      usage_after.cpu_nanoseconds, usage_before.cpu_nanoseconds);
  const std::uint64_t caller_cpu_ns =
      nonnegative_delta(caller_cpu_after, caller_cpu_before);
  const std::uint64_t phase_worker_cpu_ns = nonnegative_delta(
      static_cast<std::uint64_t>(phase_worker_cpu_after.count()),
      static_cast<std::uint64_t>(phase_worker_cpu_before.count()));
  const std::uint64_t pan_worker_cpu_ns = nonnegative_delta(
      static_cast<std::uint64_t>(pan_worker_cpu_after.count()),
      static_cast<std::uint64_t>(pan_worker_cpu_before.count()));
  const std::uint64_t attributed_cpu_ns =
      caller_cpu_ns + phase_worker_cpu_ns + pan_worker_cpu_ns;
  const std::uint64_t unattributed_cpu_ns =
      nonnegative_delta(process_cpu_ns, attributed_cpu_ns);
  const std::int64_t rss_delta =
      static_cast<std::int64_t>(memory_after.vm_rss_bytes) -
      static_cast<std::int64_t>(memory_before.vm_rss_bytes);
  const std::int64_t pss_delta =
      static_cast<std::int64_t>(memory_after.pss_bytes) -
      static_cast<std::int64_t>(memory_before.pss_bytes);
  const std::uint64_t correctness_wall_us = static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::microseconds>(
          correctness_wall_after - correctness_wall_before)
          .count());
  const std::uint64_t correctness_process_cpu_ns =
      nonnegative_delta(correctness_usage_after.cpu_nanoseconds,
                        correctness_usage_before.cpu_nanoseconds);
  const std::uint64_t correctness_caller_cpu_ns =
      nonnegative_delta(correctness_caller_after, correctness_caller_before);
  const std::uint64_t correctness_worker_cpu_ns = nonnegative_delta(
      static_cast<std::uint64_t>(correctness_worker_after.count()),
      static_cast<std::uint64_t>(correctness_worker_before.count()));
  const double per_phase_divisor = static_cast<double>(completed_phases);
  const double process_cpu_per_phase_us =
      completed_phases == 0
          ? 0.0
          : static_cast<double>(process_cpu_ns) / per_phase_divisor / 1000.0;
  const double caller_cpu_per_phase_us =
      completed_phases == 0
          ? 0.0
          : static_cast<double>(caller_cpu_ns) / per_phase_divisor / 1000.0;
  const double phase_worker_cpu_per_phase_us =
      completed_phases == 0 ? 0.0
                            : static_cast<double>(phase_worker_cpu_ns) /
                                  per_phase_divisor / 1000.0;
  const double pan_worker_cpu_per_phase_us =
      completed_phases == 0
          ? 0.0
          : static_cast<double>(pan_worker_cpu_ns) / per_phase_divisor / 1000.0;
  const auto setup_us = [](auto begin, auto end) {
    return std::chrono::duration<double, std::micro>(end - begin).count();
  };
  const char *const phase_mode =
      mode == PhaseSoakMode::kProductionOnly ? "production-only" : "combined";
  std::printf("rm2_phase_pipeline_soak mode=%s requested_phases=%zu "
              "encoded_phases=%zu completed_phases=%zu patterns=2 "
              "mmap_slots=%zu "
              "idle_wake_tests=%zu wake_failures=%zu p99_budget_us=%.1f "
              "encode_min_us=%.1f encode_p50_us=%.1f encode_p95_us=%.1f "
              "encode_p99_us=%.1f encode_max_us=%.1f pan_begin_p99_us=%.1f "
              "pan_begin_max_us=%.1f pan_p99_us=%.1f "
              "cadence_p50_us=%.1f cadence_p95_us=%.1f cadence_p99_us=%.1f "
              "cadence_max_us=%.1f serial_p99_us=%.1f encode_failures=%zu "
              "reference_failures=%zu encode_budget_exceedances=%zu "
              "pan_failures=%zu deadline_misses=%zu cadence_misses=%zu "
              "underflows=%zu latched_slot_mutations=%llu thermal_checks=%zu "
              "thermal_failures=%zu thermal_error=\"%s\" "
              "max_cpu_temperature_millidegrees=%d "
              "post_production_reference_failures=%zu\n",
              phase_mode, jobs, encoded_phases, completed_phases,
              kRm2ActiveSlots, kIdleWakeTests, wake_failures,
              kEncodeP99BudgetUs, encode_timing.min_us, encode_timing.p50_us,
              encode_timing.p95_us, encode_timing.p99_us, encode_timing.max_us,
              pan_begin_timing.p99_us, pan_begin_timing.max_us,
              pan_timing.p99_us, cadence_timing.p50_us, cadence_timing.p95_us,
              cadence_timing.p99_us, cadence_timing.max_us, serial_p99_us,
              encode_failures, reference_failures, encode_budget_exceedances,
              pan_failures, deadline_misses, cadence_misses, underflows,
              static_cast<unsigned long long>(
                  latched_slot_mutations.load(std::memory_order_relaxed)),
              thermal_checks, thermal_failures, thermal_error.c_str(),
              maximum_cpu_temperature, post_production_reference_failures);
  std::printf("rm2_phase_pipeline_stages reference_setup_us=%.1f "
              "slot_setup_us=%.1f worker_setup_us=%.1f wake_encode_p50_us=%.1f "
              "wake_encode_p99_us=%.1f correctness_encode_p50_us=%.1f "
              "correctness_encode_p99_us=%.1f oracle_memcmp_p50_us=%.1f "
              "oracle_memcmp_p99_us=%.1f oracle_memcmp_max_us=%.1f "
              "final_verify_us=%.1f\n",
              setup_us(setup_begin, reference_setup_end),
              setup_us(reference_setup_end, slot_setup_end),
              setup_us(slot_setup_end, worker_setup_end),
              wake_encode_timing.p50_us, wake_encode_timing.p99_us,
              correctness_encode_timing.p50_us,
              correctness_encode_timing.p99_us, oracle_timing.p50_us,
              oracle_timing.p99_us, oracle_timing.max_us,
              setup_us(final_verify_begin, final_verify_end));
  std::printf("rm2_phase_pipeline_reference pattern0_sha256=%s "
              "pattern1_sha256=%s "
              "verification=separate-full-slot-memcmp-every-phase-plus-"
              "post-production-last-generation correctness_phases=%zu "
              "correctness_encode_failures=%zu reference_failures=%zu "
              "correctness_wall_us=%llu correctness_process_cpu_us=%.1f "
              "correctness_caller_cpu_us=%.1f "
              "correctness_phase_worker_cpu_us=%.1f "
              "oracle_caller_cpu_us=%.1f\n",
              reference_sha256[0].c_str(), reference_sha256[1].c_str(),
              correctness_completed_phases, correctness_encode_failures,
              reference_failures,
              static_cast<unsigned long long>(correctness_wall_us),
              static_cast<double>(correctness_process_cpu_ns) / 1000.0,
              static_cast<double>(correctness_caller_cpu_ns) / 1000.0,
              static_cast<double>(correctness_worker_cpu_ns) / 1000.0,
              static_cast<double>(oracle_caller_cpu_ns) / 1000.0);
  std::printf(
      "rm2_phase_pipeline_cpu scope=production-no-oracle "
      "process_cpu_us=%.1f caller_cpu_us=%.1f phase_worker_cpu_us=%.1f "
      "pan_worker_cpu_us=%.1f unattributed_cpu_us=%.1f "
      "process_cpu_per_phase_us=%.1f caller_cpu_per_phase_us=%.1f "
      "phase_worker_cpu_per_phase_us=%.1f "
      "pan_worker_cpu_per_phase_us=%.1f wall_us=%llu cpu_per_wall=%.3f\n",
      static_cast<double>(process_cpu_ns) / 1000.0,
      static_cast<double>(caller_cpu_ns) / 1000.0,
      static_cast<double>(phase_worker_cpu_ns) / 1000.0,
      static_cast<double>(pan_worker_cpu_ns) / 1000.0,
      static_cast<double>(unattributed_cpu_ns) / 1000.0,
      process_cpu_per_phase_us, caller_cpu_per_phase_us,
      phase_worker_cpu_per_phase_us, pan_worker_cpu_per_phase_us,
      static_cast<unsigned long long>(wall_us),
      wall_us == 0 ? 0.0
                   : static_cast<double>(process_cpu_ns) /
                         (static_cast<double>(wall_us) * 1000.0));
  std::printf(
      "rm2_phase_pipeline_resources scope=production-no-oracle "
      "allocations_before=%llu "
      "allocations_after=%llu allocation_delta=%llu "
      "vm_size_before_bytes=%llu vm_size_after_bytes=%llu "
      "rss_before_bytes=%llu rss_after_bytes=%llu rss_delta_bytes=%lld "
      "vm_hwm_before_bytes=%llu vm_hwm_after_bytes=%llu "
      "rss_anon_before_bytes=%llu rss_anon_after_bytes=%llu "
      "rss_file_before_bytes=%llu rss_file_after_bytes=%llu "
      "pss_before_bytes=%llu pss_after_bytes=%llu pss_delta_bytes=%lld "
      "anonymous_before_bytes=%llu anonymous_after_bytes=%llu "
      "private_dirty_before_bytes=%llu private_dirty_after_bytes=%llu "
      "status_available=%u smaps_rollup_available=%u\n",
      static_cast<unsigned long long>(allocations_before),
      static_cast<unsigned long long>(allocations_after),
      static_cast<unsigned long long>(allocations_after - allocations_before),
      static_cast<unsigned long long>(memory_before.vm_size_bytes),
      static_cast<unsigned long long>(memory_after.vm_size_bytes),
      static_cast<unsigned long long>(memory_before.vm_rss_bytes),
      static_cast<unsigned long long>(memory_after.vm_rss_bytes),
      static_cast<long long>(rss_delta),
      static_cast<unsigned long long>(memory_before.vm_hwm_bytes),
      static_cast<unsigned long long>(memory_after.vm_hwm_bytes),
      static_cast<unsigned long long>(memory_before.rss_anon_bytes),
      static_cast<unsigned long long>(memory_after.rss_anon_bytes),
      static_cast<unsigned long long>(memory_before.rss_file_bytes),
      static_cast<unsigned long long>(memory_after.rss_file_bytes),
      static_cast<unsigned long long>(memory_before.pss_bytes),
      static_cast<unsigned long long>(memory_after.pss_bytes),
      static_cast<long long>(pss_delta),
      static_cast<unsigned long long>(memory_before.anonymous_bytes),
      static_cast<unsigned long long>(memory_after.anonymous_bytes),
      static_cast<unsigned long long>(memory_before.private_dirty_bytes),
      static_cast<unsigned long long>(memory_after.private_dirty_bytes),
      memory_before.status_available && memory_after.status_available ? 1U : 0U,
      memory_before.smaps_rollup_available &&
              memory_after.smaps_rollup_available
          ? 1U
          : 0U);
  std::printf(
      "rm2_phase_pipeline_kernel scope=production-no-oracle "
      "minor_faults=%llu major_faults=%llu voluntary_switches=%llu "
      "involuntary_switches=%llu fd_before=%zu fd_after=%zu "
      "display_fds_before=%zu display_fds_after=%zu fd_audit_available=%u\n",
      static_cast<unsigned long long>(nonnegative_delta(
          usage_after.minor_faults, usage_before.minor_faults)),
      static_cast<unsigned long long>(nonnegative_delta(
          usage_after.major_faults, usage_before.major_faults)),
      static_cast<unsigned long long>(nonnegative_delta(
          usage_after.voluntary_switches, usage_before.voluntary_switches)),
      static_cast<unsigned long long>(nonnegative_delta(
          usage_after.involuntary_switches, usage_before.involuntary_switches)),
      fds_before.open_count, fds_after.open_count, fds_before.display_count,
      fds_after.display_count,
      fds_before.available && fds_after.available ? 1U : 0U);
  std::printf(
      "rm2_phase_pipeline_buffers mmap_slot_ring_bytes=%zu "
      "mmap_slot_bytes=%zu expected_oracle_heap_bytes=%zu "
      "transition_pattern_heap_bytes=%zu phase_pattern_heap_bytes=%zu "
      "sample_heap_requested_bytes=%zu smaps_anonymous_after_bytes=%llu\n",
      kRm2ActiveSlots * kRm2SlotBytes, kRm2SlotBytes,
      expected_slots.size() * kRm2SlotBytes,
      transition_patterns.size() * transitions.size(),
      phase_patterns.size() * expanded.size(), jobs * 6U * sizeof(double),
      static_cast<unsigned long long>(memory_after.anonymous_bytes));
  const double cadence_budget_us =
      std::chrono::duration<double, std::micro>(kCadenceDeadline).count();
  const bool correctness_ok =
      mode == PhaseSoakMode::kProductionOnly ||
      (correctness_completed_phases == jobs &&
       correctness_encode_failures == 0 && reference_failures == 0 &&
       correctness_thermal_failures == 0);
  return jobs != 0 && correctness_ok && encoded_phases == jobs &&
                 completed_phases == jobs &&
                 encode_timing.p99_us <= kEncodeP99BudgetUs &&
                 cadence_timing.p99_us <= cadence_budget_us &&
                 serial_p99_us > cadence_budget_us && wake_failures == 0 &&
                 encode_failures == 0 && reference_failures == 0 &&
                 pan_failures == 0 && deadline_misses == 0 &&
                 cadence_misses == 0 && underflows == 0 &&
                 thermal_failures == 0 && correctness_encode_failures == 0 &&
                 post_production_reference_failures == 0 &&
                 latched_slot_mutations.load(std::memory_order_relaxed) == 0 &&
                 allocations_before == allocations_after &&
                 memory_after.vm_rss_bytes == memory_before.vm_rss_bytes &&
                 fds_before.display_count == 0 && fds_after.display_count == 0
             ? 0
             : 1;
}

int run_guarded_phase_soak(std::size_t jobs,
                           std::span<const std::uint8_t> transitions,
                           std::span<const std::uint8_t> expanded,
                           PhaseSoakMode mode) {
#if defined(__linux__) && defined(__arm__)
  Rm2CpuFrequencyBurstLease lease(production_frequency_paths());
  std::string error;
  const auto acquire_begin = std::chrono::steady_clock::now();
  if (!lease.acquire(&error)) {
    std::fprintf(stderr,
                 "RM2 phase soak frequency guard acquire failed before phase "
                 "0: %s\n",
                 error.c_str());
    return 1;
  }
  const auto acquire_end = std::chrono::steady_clock::now();
  std::printf(
      "rm2_phase_pipeline_guard acquired=1 acquire_us=%.1f receipt=%s "
      "policy=%s\n",
      std::chrono::duration<double, std::micro>(acquire_end - acquire_begin)
          .count(),
      pluto::native::rm2::kRm2CpuReceiptPath,
      pluto::native::rm2::kRm2CpuPolicyPath);
  const bool receipt_identity_ok = print_frequency_receipt_identity();
  const int soak_status =
      receipt_identity_ok
          ? run_phase_soak(jobs, transitions, expanded, &lease, mode)
          : 1;
  const auto release_begin = std::chrono::steady_clock::now();
  const bool released = lease.release(&error);
  const auto release_end = std::chrono::steady_clock::now();
  std::printf(
      "rm2_phase_pipeline_guard restored=%u release_us=%.1f\n",
      released ? 1U : 0U,
      std::chrono::duration<double, std::micro>(release_end - release_begin)
          .count());
  if (!released) {
    std::fprintf(stderr, "RM2 phase soak frequency guard restore failed: %s\n",
                 error.c_str());
  }
  return soak_status == 0 && released ? 0 : 1;
#else
  std::printf("rm2_phase_pipeline_guard acquired=0 reason=non-arm-host\n");
  return run_phase_soak(jobs, transitions, expanded, nullptr, mode);
#endif
}

} // namespace

int main(int argc, char **argv) {
  constexpr std::string_view kRealWbfPrefix = "--real-wbf=";
  if (argc == 2 && std::string_view(argv[1]).starts_with(kRealWbfPrefix)) {
    print_context();
    configure_benchmark_thread();
    return run_real_wbf_open(
        std::string_view(argv[1]).substr(kRealWbfPrefix.size()));
  }
  constexpr std::string_view kFrequencyProbePrefix = "--frequency-lease-probe=";
  constexpr std::string_view kFrequencyHoldPrefix = "--frequency-lease-hold=";
  if (argc == 2 &&
      std::string_view(argv[1]).starts_with(kFrequencyProbePrefix)) {
    const auto iterations = parse_positive_count(
        argv[1], kFrequencyProbePrefix, static_cast<std::size_t>(10'000));
    if (!iterations.has_value() || *iterations == 0) {
      std::fprintf(stderr, "invalid RM2 frequency lease probe count\n");
      return 2;
    }
    print_context();
    return run_frequency_lease_probe(*iterations);
  }
  if (argc == 2 &&
      std::string_view(argv[1]).starts_with(kFrequencyHoldPrefix)) {
    const auto milliseconds = parse_positive_count(
        argv[1], kFrequencyHoldPrefix, static_cast<std::size_t>(600'000));
    if (!milliseconds.has_value() || *milliseconds == 0) {
      std::fprintf(stderr, "invalid RM2 frequency lease hold duration\n");
      return 2;
    }
    print_context();
    return run_frequency_lease_hold(*milliseconds);
  }
  constexpr std::string_view kCorrectnessSoakPrefix =
      "--phase-correctness-soak=";
  constexpr std::string_view kProductionSoakPrefix = "--phase-production-soak=";
  std::optional<std::size_t> phase_soak;
  PhaseSoakMode phase_soak_mode = PhaseSoakMode::kCombined;
  if (argc == 2 &&
      std::string_view(argv[1]).starts_with(kCorrectnessSoakPrefix)) {
    phase_soak = parse_positive_count(argv[1], kCorrectnessSoakPrefix,
                                      static_cast<std::size_t>(1'000'000));
    phase_soak_mode = PhaseSoakMode::kCorrectnessOnly;
  } else if (argc == 2 &&
             std::string_view(argv[1]).starts_with(kProductionSoakPrefix)) {
    phase_soak = parse_positive_count(argv[1], kProductionSoakPrefix,
                                      static_cast<std::size_t>(1'000'000));
    phase_soak_mode = PhaseSoakMode::kProductionOnly;
  } else {
    phase_soak = parse_phase_soak(argc, argv);
  }
  if (argc != 1 && (!phase_soak.has_value() || *phase_soak == 0)) {
    std::fprintf(stderr,
                 "usage: rm2_encoder_bench "
                 "[--phase-soak=N|--phase-correctness-soak=N|"
                 "--phase-production-soak=N|--real-wbf=PATH|"
                 "--frequency-lease-probe=N|--frequency-lease-hold=MS]\n");
    return 2;
  }
  print_context();
  configure_benchmark_thread();

  std::size_t lut_mismatches = 0;
  std::uint32_t first_lut_mismatch = 0;
  for (std::uint32_t pixel = 0; pixel <= 0xffffU; ++pixel) {
    if (reference_rgb565_level(static_cast<std::uint16_t>(pixel)) !=
        rgb565_to_rm2_level(static_cast<std::uint16_t>(pixel))) {
      if (lut_mismatches == 0) {
        first_lut_mismatch = pixel;
      }
      ++lut_mismatches;
    }
  }
  constexpr std::uint64_t kExpectedRgb565Checksum = 0x851d793bf1575e13ULL;
  const std::uint64_t actual_rgb565_checksum = production_rgb565_checksum();
  const bool rgb565_hash_matches =
      actual_rgb565_checksum == kExpectedRgb565Checksum;
  std::printf("rm2_rgb565 entries=65536 mismatches=%zu first_mismatch=%u "
              "checksum=0x%016llx expected=0x%016llx hash_match=%u "
              "implementation=arithmetic\n",
              lut_mismatches, first_lut_mismatch,
              static_cast<unsigned long long>(actual_rgb565_checksum),
              static_cast<unsigned long long>(kExpectedRgb565Checksum),
              rgb565_hash_matches ? 1U : 0U);
  if (lut_mismatches != 0 || !rgb565_hash_matches) {
    return 1;
  }

  std::vector<std::uint16_t> pixels(kPanelPixels);
  std::vector<std::uint8_t> output(kPanelPixels);
  std::uint32_t random = 0x52f6a19dU;
  for (std::uint16_t &pixel : pixels) {
    random = random * 1664525U + 1013904223U;
    pixel = static_cast<std::uint16_t>(random >> 8U);
  }

  Measurement rgb565_production;
  if (!phase_soak.has_value()) {
    rgb565_production = measure([&](std::size_t) {
      std::uint64_t checksum = 0;
      for (std::size_t index = 0; index < pixels.size(); ++index) {
        const std::uint8_t level = rgb565_to_rm2_level(pixels[index]);
        output[index] = level;
        checksum += level;
      }
      return IterationResult{.ok = true, .checksum = checksum};
    });
  }

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

  if (phase_soak.has_value()) {
    return run_guarded_phase_soak(*phase_soak, transitions, expanded,
                                  phase_soak_mode);
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
  Rm2PhaseEncoder phase_encoder;
  if (!phase_encoder.ready() ||
      !phase_encoder.encode(slot, full_panel, transitions, expanded)) {
    return 1;
  }
  std::vector<std::byte> full_reference(kRm2SlotBytes);
  if (!fill_rm2_scan_slot(full_reference, 0)) {
    return 1;
  }
  reference_encode_full(full_reference, transitions, expanded);
  const bool full_reference_match =
      std::memcmp(slot.data(), full_reference.data(), kRm2SlotBytes) == 0;
  const Measurement packed = measure(
      [&](std::size_t iteration) {
        if (!phase_encoder.encode(slot, full_panel, transitions, expanded)) {
          return IterationResult{.ok = false, .checksum = 0};
        }
        std::uint64_t checksum = 0;
        for (std::size_t sample = 0; sample < 32; ++sample) {
          const std::size_t index =
              (iteration * 1315423911ULL + sample * 2654435761ULL) %
              slot.size();
          checksum =
              checksum * 257U + std::to_integer<std::uint8_t>(slot[index]);
        }
        return IterationResult{.ok = true, .checksum = checksum};
      },
      kPhaseInterval);

  const Rm2PanelRect near_full_rect{
      .row_min = 0,
      .row_max = static_cast<std::uint16_t>(kRm2PanelHeight - 1U),
      .column_min = 1,
      .column_max = static_cast<std::uint16_t>(kRm2PanelWidth - 1U),
  };
  const std::span<const std::uint8_t> near_full_transitions(
      transitions.data() + kRm2PanelHeight,
      transitions.size() - kRm2PanelHeight);
  std::vector<std::byte> near_full_slot(kRm2SlotBytes);
  if (!fill_rm2_scan_slot(near_full_slot, 0)) {
    return 1;
  }
  std::vector<std::byte> near_full_reference(kRm2SlotBytes);
  if (!fill_rm2_scan_slot(near_full_reference, 0) ||
      !phase_encoder.encode(near_full_slot, near_full_rect,
                            near_full_transitions, expanded)) {
    return 1;
  }
  reference_encode_region(near_full_reference, near_full_rect,
                          near_full_transitions, expanded);
  const bool near_full_reference_match =
      std::memcmp(near_full_slot.data(), near_full_reference.data(),
                  kRm2SlotBytes) == 0;
  const Measurement near_full = measure(
      [&](std::size_t iteration) {
        if (!phase_encoder.encode(near_full_slot, near_full_rect,
                                  near_full_transitions, expanded)) {
          return IterationResult{.ok = false, .checksum = 0};
        }
        const std::size_t index =
            (iteration * 2654435761ULL) % near_full_slot.size();
        return IterationResult{
            .ok = true,
            .checksum = std::to_integer<std::uint8_t>(near_full_slot[index]),
        };
      },
      kPhaseInterval);

  std::array<Rm2PhaseRegion, 64> sparse_regions{};
  std::vector<std::uint8_t> sparse_transitions(sparse_regions.size() * 8U);
  for (std::size_t index = 0; index < sparse_regions.size(); ++index) {
    const std::uint16_t row =
        static_cast<std::uint16_t>((index * 24U) % (kRm2PanelHeight - 8U));
    sparse_regions[index] = {
        .rect =
            {
                .row_min = row,
                .row_max = static_cast<std::uint16_t>(row + 7U),
                .column_min = static_cast<std::uint16_t>(index * 20U),
                .column_max = static_cast<std::uint16_t>(index * 20U),
            },
        .transition_offset = index * 8U,
    };
    std::copy_n(transitions.data() + index * 4096U, 8U,
                sparse_transitions.data() + index * 8U);
  }
  std::vector<std::byte> sparse_slot(kRm2SlotBytes);
  if (!fill_rm2_scan_slot(sparse_slot, 0)) {
    return 1;
  }
  std::vector<std::byte> sparse_reference(kRm2SlotBytes);
  if (!fill_rm2_scan_slot(sparse_reference, 0) ||
      !phase_encoder.encode_regions(sparse_slot, sparse_regions,
                                    sparse_transitions, expanded)) {
    return 1;
  }
  for (const Rm2PhaseRegion &region : sparse_regions) {
    const std::size_t pixels =
        region.rect.row_count() * region.rect.column_count();
    reference_encode_region(sparse_reference, region.rect,
                            std::span<const std::uint8_t>(sparse_transitions)
                                .subspan(region.transition_offset, pixels),
                            expanded);
  }
  const bool sparse_reference_match =
      std::memcmp(sparse_slot.data(), sparse_reference.data(), kRm2SlotBytes) ==
      0;
  const Measurement sparse = measure(
      [&](std::size_t iteration) {
        if (!phase_encoder.encode_regions(sparse_slot, sparse_regions,
                                          sparse_transitions, expanded)) {
          return IterationResult{.ok = false, .checksum = 0};
        }
        const std::size_t index =
            (iteration * 2246822519ULL) % sparse_slot.size();
        return IterationResult{
            .ok = true,
            .checksum = std::to_integer<std::uint8_t>(sparse_slot[index]),
        };
      },
      kPhaseInterval);

  print_measurement("rgb565_arithmetic_production", rgb565_production);
  print_measurement("wbf_transition_decoder", decoded);
  print_measurement("wbf_transition_expanded_lut", preexpanded);
  print_measurement("full_panel_phase_encode", packed);
  print_measurement("near_full_phase_encode", near_full);
  print_measurement("sparse_64_region_phase_encode", sparse);
  std::printf("rm2_phase_reference full_match=%u near_full_match=%u "
              "sparse_match=%u verification=full-slot-memcmp\n",
              full_reference_match, near_full_reference_match,
              sparse_reference_match);
  std::printf("rm2_phase_timing schedule=production-paced interval_us=%.1f\n",
              kScanBudgetUs);
  std::printf("rm2_bench_compare baseline=wbf_transition_decoder "
              "candidate=wbf_transition_expanded_lut p50_speedup=%.2f "
              "p95_speedup=%.2f\n",
              ratio(decoded.timing.p50_us, preexpanded.timing.p50_us),
              ratio(decoded.timing.p95_us, preexpanded.timing.p95_us));
  std::printf("rm2_scan_budget budget_us=%.1f full_p95_headroom=%.2f "
              "full_p99_headroom=%.2f near_full_p99_us=%.1f "
              "sparse_64_p99_us=%.1f\n",
              kScanBudgetUs, ratio(kScanBudgetUs, packed.timing.p95_us),
              ratio(kScanBudgetUs, packed.timing.p99_us),
              near_full.timing.p99_us, sparse.timing.p99_us);

  const std::size_t tracked_buffer_bytes =
      pixels.size() * sizeof(pixels.front()) +
      output.size() * sizeof(output.front()) +
      transitions.size() * sizeof(transitions.front()) +
      expanded.size() * sizeof(expanded.front()) +
      slot.size() * sizeof(slot.front()) +
      full_reference.size() * sizeof(full_reference.front()) +
      near_full_slot.size() * sizeof(near_full_slot.front()) +
      near_full_reference.size() * sizeof(near_full_reference.front()) +
      sparse_transitions.size() * sizeof(sparse_transitions.front()) +
      sparse_slot.size() * sizeof(sparse_slot.front()) +
      sparse_reference.size() * sizeof(sparse_reference.front());
  std::printf("rm2_bench_memory panel_pixels=%zu tracked_buffer_bytes=%zu "
              "rgb565_lut_bytes=0 max_rss_bytes=%llu\n",
              kPanelPixels, tracked_buffer_bytes,
              static_cast<unsigned long long>(maximum_rss_bytes()));

  const std::size_t failures =
      rgb565_production.measured_failures + rgb565_production.warmup_failures +
      decoded.measured_failures + decoded.warmup_failures +
      preexpanded.measured_failures + preexpanded.warmup_failures +
      packed.measured_failures + packed.warmup_failures +
      near_full.measured_failures + near_full.warmup_failures +
      sparse.measured_failures + sparse.warmup_failures;
  std::printf("rm2_bench_summary measured_per_case=%zu total_failures=%zu\n",
              kMeasuredIterations, failures);
  return failures == 0 && full_reference_match && near_full_reference_match &&
                 sparse_reference_match && packed.timing.p99_us <= 8234.0 &&
                 near_full.timing.p99_us <= 8234.0 &&
                 sparse.timing.p99_us <= 8234.0
             ? 0
             : 1;
}
