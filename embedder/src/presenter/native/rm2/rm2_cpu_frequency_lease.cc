#include "presenter/native/rm2/rm2_cpu_frequency_lease.h"

#include <array>
#include <cerrno>
#include <charconv>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string_view>
#include <utility>

#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

namespace pluto::native::rm2 {
namespace {

constexpr std::uint64_t kRm2MinimumFrequencyKhz = 792'000;
constexpr std::uint64_t kRm2MaximumFrequencyKhz = 1'200'000;
constexpr unsigned kPolicySettleAttempts = 50;
constexpr long kPolicySettleDelayNanoseconds = 1'000'000;

void set_error(std::string *error, std::string_view message) noexcept {
  if (error != nullptr) {
    try {
      *error = message;
    } catch (...) {
      // Error reporting cannot compromise policy restoration.
    }
  }
}

bool read_file(const char *path, char *out, std::size_t capacity,
               std::size_t *out_size) {
  if (path == nullptr || out == nullptr || capacity < 2U ||
      out_size == nullptr) {
    return false;
  }
  const int fd = ::open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) {
    return false;
  }
  std::size_t size = 0;
  bool ok = true;
  while (size < capacity - 1U) {
    const ssize_t count = ::read(fd, out + size, capacity - 1U - size);
    if (count == 0) {
      break;
    }
    if (count < 0) {
      if (errno == EINTR) {
        continue;
      }
      ok = false;
      break;
    }
    size += static_cast<std::size_t>(count);
  }
  if (ok && size == capacity - 1U) {
    char extra = 0;
    ssize_t count = 0;
    do {
      count = ::read(fd, &extra, 1);
    } while (count < 0 && errno == EINTR);
    ok = count == 0;
  }
  ok = ::close(fd) == 0 && ok;
  out[size] = '\0';
  *out_size = size;
  return ok;
}

bool read_line(const std::string &path, char *out, std::size_t capacity) {
  std::size_t size = 0;
  if (!read_file(path.c_str(), out, capacity, &size) || size < 2U ||
      out[size - 1U] != '\n') {
    return false;
  }
  for (std::size_t index = 0; index + 1U < size; ++index) {
    if (out[index] == '\n' || out[index] == '\r' || out[index] == '\0') {
      return false;
    }
  }
  out[size - 1U] = '\0';
  return true;
}

bool parse_uint64(std::string_view value, std::uint64_t *out) {
  if (value.empty() || out == nullptr) {
    return false;
  }
  std::uint64_t parsed = 0;
  const auto result =
      std::from_chars(value.data(), value.data() + value.size(), parsed);
  if (result.ec != std::errc{} || result.ptr != value.data() + value.size()) {
    return false;
  }
  *out = parsed;
  return true;
}

bool safe_governor(std::string_view value) {
  if (value.empty() || value.size() >= 64U) {
    return false;
  }
  for (const char character : value) {
    const bool valid = (character >= 'a' && character <= 'z') ||
                       (character >= '0' && character <= '9') ||
                       character == '_' || character == '-';
    if (!valid) {
      return false;
    }
  }
  return true;
}

void wait_for_policy_settle() noexcept {
  timespec remaining{
      .tv_sec = 0,
      .tv_nsec = kPolicySettleDelayNanoseconds,
  };
  while (::nanosleep(&remaining, &remaining) != 0 && errno == EINTR) {
  }
}

bool write_all(int fd, const char *data, std::size_t size) {
  std::size_t written = 0;
  while (written < size) {
    const ssize_t count = ::write(fd, data + written, size - written);
    if (count < 0) {
      if (errno == EINTR) {
        continue;
      }
      return false;
    }
    if (count == 0) {
      return false;
    }
    written += static_cast<std::size_t>(count);
  }
  return true;
}

bool process_start_ticks(std::uint64_t *out_ticks) {
  std::array<char, 4096> stat{};
  std::size_t size = 0;
  if (!read_file("/proc/self/stat", stat.data(), stat.size(), &size) ||
      size == 0) {
    return false;
  }
  const char *right_parenthesis = nullptr;
  for (std::size_t index = size; index != 0; --index) {
    if (stat[index - 1U] == ')') {
      right_parenthesis = stat.data() + index - 1U;
      break;
    }
  }
  if (right_parenthesis == nullptr ||
      right_parenthesis + 2 >= stat.data() + size ||
      right_parenthesis[1] != ' ') {
    return false;
  }
  const char *cursor = right_parenthesis + 2;
  const char *end = stat.data() + size;
  for (unsigned field = 3; field <= 22; ++field) {
    while (cursor < end && *cursor == ' ') {
      ++cursor;
    }
    const char *token_end = cursor;
    while (token_end < end && *token_end != ' ' && *token_end != '\n') {
      ++token_end;
    }
    if (cursor == token_end) {
      return false;
    }
    if (field == 22) {
      return parse_uint64(std::string_view(cursor, static_cast<std::size_t>(
                                                       token_end - cursor)),
                          out_ticks);
    }
    cursor = token_end;
  }
  return false;
}

bool lock_file_valid(int fd) {
  struct stat metadata {};
  return ::fstat(fd, &metadata) == 0 && S_ISREG(metadata.st_mode) &&
         metadata.st_uid == ::geteuid() && metadata.st_nlink == 1 &&
         (metadata.st_mode & 0777U) == 0600U;
}

bool secure_runtime_directory(const std::string &path) {
  struct stat metadata {};
  return !path.empty() && ::lstat(path.c_str(), &metadata) == 0 &&
         S_ISDIR(metadata.st_mode) && metadata.st_uid == ::geteuid() &&
         (metadata.st_mode & 0022U) == 0;
}

} // namespace

Rm2CpuFrequencyBurstLease::Rm2CpuFrequencyBurstLease(
    Rm2CpuFrequencyLeasePaths paths)
    : policy_path_(std::move(paths.policy_path)),
      receipt_path_(std::move(paths.receipt_path)),
      lock_path_(std::move(paths.lock_path)),
      cpu_thermal_type_path_(std::move(paths.cpu_thermal_type_path)),
      cpu_temperature_path_(std::move(paths.cpu_temperature_path)),
      owner_start_ticks_for_testing_(paths.owner_start_ticks_for_testing) {
  if (!policy_path_.empty()) {
    minimum_path_ = policy_path_ + "/scaling_min_freq";
    maximum_path_ = policy_path_ + "/scaling_max_freq";
    governor_path_ = policy_path_ + "/scaling_governor";
    related_cpus_path_ = policy_path_ + "/related_cpus";
  }
  const std::size_t separator = receipt_path_.rfind('/');
  if (separator != std::string::npos) {
    runtime_path_ = separator == 0 ? "/" : receipt_path_.substr(0, separator);
  }
}

Rm2CpuFrequencyBurstLease::~Rm2CpuFrequencyBurstLease() {
  std::string error;
  if (!release(&error)) {
    std::fprintf(stderr, "rm2 cpufreq: destructor restore failed: %s\n",
                 error.c_str());
  }
}

bool Rm2CpuFrequencyBurstLease::temperature_safe(int *out_millidegrees,
                                                 std::string *error) const {
  if (!enabled()) {
    if (out_millidegrees != nullptr) {
      *out_millidegrees = 0;
    }
    return true;
  }
  std::array<char, 64> type{};
  std::array<char, 64> temperature{};
  std::uint64_t millidegrees = 0;
  if (!read_line(cpu_thermal_type_path_, type.data(), type.size()) ||
      std::string_view(type.data()) != "imx_thermal_zone" ||
      !read_line(cpu_temperature_path_, temperature.data(),
                 temperature.size()) ||
      !parse_uint64(temperature.data(), &millidegrees) || millidegrees == 0 ||
      millidegrees >=
          static_cast<std::uint64_t>(kRm2CpuTemperatureCutoffMillidegrees)) {
    set_error(error, "RM2 CPU temperature unavailable or at/above 45 C cutoff");
    return false;
  }
  if (out_millidegrees != nullptr) {
    *out_millidegrees = static_cast<int>(millidegrees);
  }
  return true;
}

bool Rm2CpuFrequencyBurstLease::read_policy(std::uint64_t *out_minimum,
                                            std::uint64_t *out_maximum,
                                            char *out_governor,
                                            std::size_t governor_capacity,
                                            std::string *error) const {
  std::array<char, 64> minimum{};
  std::array<char, 64> maximum{};
  std::array<char, 64> related{};
  if (!read_line(minimum_path_, minimum.data(), minimum.size()) ||
      !read_line(maximum_path_, maximum.data(), maximum.size()) ||
      !read_line(governor_path_, out_governor, governor_capacity) ||
      !read_line(related_cpus_path_, related.data(), related.size())) {
    set_error(error, "cannot read exact policy0 contract");
    return false;
  }
  std::uint64_t minimum_khz = 0;
  std::uint64_t maximum_khz = 0;
  if (!parse_uint64(minimum.data(), &minimum_khz) ||
      !parse_uint64(maximum.data(), &maximum_khz) ||
      minimum_khz < kRm2MinimumFrequencyKhz ||
      minimum_khz > kRm2MaximumFrequencyKhz ||
      maximum_khz != kRm2MaximumFrequencyKhz ||
      std::string_view(related.data()) != "0 1" ||
      !safe_governor(out_governor)) {
    set_error(error, "policy0 identity or range mismatch");
    return false;
  }
  *out_minimum = minimum_khz;
  *out_maximum = maximum_khz;
  return true;
}

bool Rm2CpuFrequencyBurstLease::wait_for_policy(
    std::uint64_t expected_minimum, std::uint64_t expected_maximum,
    const char *expected_governor) const noexcept {
  for (unsigned attempt = 0; attempt < kPolicySettleAttempts; ++attempt) {
    std::uint64_t observed_minimum = 0;
    std::uint64_t observed_maximum = 0;
    std::array<char, 64> observed_governor{};
    if (read_policy(&observed_minimum, &observed_maximum,
                    observed_governor.data(), observed_governor.size(),
                    nullptr) &&
        observed_minimum == expected_minimum &&
        observed_maximum == expected_maximum &&
        std::strcmp(observed_governor.data(), expected_governor) == 0) {
      return true;
    }
    if (attempt + 1U != kPolicySettleAttempts) {
      wait_for_policy_settle();
    }
  }
  return false;
}

bool Rm2CpuFrequencyBurstLease::write_minimum(std::uint64_t frequency_khz,
                                              std::string *error) const {
  std::array<char, 32> value{};
  const int size =
      std::snprintf(value.data(), value.size(), "%llu\n",
                    static_cast<unsigned long long>(frequency_khz));
  if (size <= 0 || static_cast<std::size_t>(size) >= value.size()) {
    set_error(error, "minimum frequency formatting failed");
    return false;
  }
  const int fd =
      ::open(minimum_path_.c_str(), O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0 || !write_all(fd, value.data(), static_cast<std::size_t>(size))) {
    if (fd >= 0) {
      (void)::close(fd);
    }
    set_error(error, "minimum frequency write failed");
    return false;
  }
  // Sysfs attributes ignore file length, while host-test policy fixtures are
  // ordinary files. Best-effort truncation keeps both representations exact;
  // EINVAL from sysfs is expected and harmless after a complete write.
  (void)::ftruncate(fd, size);
  if (::close(fd) != 0) {
    set_error(error, "minimum frequency close failed");
    return false;
  }
  return true;
}

bool Rm2CpuFrequencyBurstLease::publish_receipt(std::string *error) {
  const int size = std::snprintf(
      receipt_, sizeof(receipt_),
      "policy=%s\nowner_pid=%ld\nowner_start_ticks=%llu\n"
      "original_min_khz=%llu\noriginal_max_khz=%llu\n"
      "original_governor=%s\n",
      policy_path_.c_str(), static_cast<long>(::getpid()),
      static_cast<unsigned long long>(owner_start_ticks_),
      static_cast<unsigned long long>(original_minimum_khz_),
      static_cast<unsigned long long>(original_maximum_khz_),
      original_governor_);
  if (size <= 0 || static_cast<std::size_t>(size) >= sizeof(receipt_)) {
    set_error(error, "receipt formatting failed");
    return false;
  }
  receipt_size_ = static_cast<std::size_t>(size);

  struct stat existing {};
  if (::lstat(receipt_path_.c_str(), &existing) == 0 || errno != ENOENT) {
    set_error(error, "receipt already exists or cannot be inspected");
    return false;
  }

  std::array<char, 4096> temporary{};
  const int temporary_size =
      std::snprintf(temporary.data(), temporary.size(), "%s.tmp.%ld.%llu",
                    receipt_path_.c_str(), static_cast<long>(::getpid()),
                    static_cast<unsigned long long>(owner_start_ticks_));
  if (temporary_size <= 0 ||
      static_cast<std::size_t>(temporary_size) >= temporary.size()) {
    set_error(error, "temporary receipt path is too long");
    return false;
  }
  const int fd =
      ::open(temporary.data(),
             O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0 || !lock_file_valid(fd) ||
      !write_all(fd, receipt_, receipt_size_) || ::fsync(fd) != 0 ||
      ::close(fd) != 0) {
    if (fd >= 0) {
      (void)::close(fd);
    }
    (void)::unlink(temporary.data());
    set_error(error, "temporary receipt publication failed");
    return false;
  }
  if (::link(temporary.data(), receipt_path_.c_str()) != 0) {
    (void)::unlink(temporary.data());
    set_error(error, "atomic receipt link failed");
    return false;
  }
  (void)::unlink(temporary.data());
  return true;
}

bool Rm2CpuFrequencyBurstLease::receipt_unchanged() const noexcept {
  std::array<char, sizeof(receipt_)> observed{};
  std::size_t size = 0;
  return read_file(receipt_path_.c_str(), observed.data(), observed.size(),
                   &size) &&
         size == receipt_size_ &&
         std::memcmp(observed.data(), receipt_, receipt_size_) == 0;
}

void Rm2CpuFrequencyBurstLease::close_lock() noexcept {
  if (lock_fd_ >= 0) {
    (void)::flock(lock_fd_, LOCK_UN);
    (void)::close(lock_fd_);
    lock_fd_ = -1;
  }
}

bool Rm2CpuFrequencyBurstLease::acquire(std::string *error) {
  if (!enabled()) {
    return true;
  }
  if (!temperature_safe(nullptr, error)) {
    if (active_) {
      (void)release(nullptr);
    }
    return false;
  }
  if (active_) {
    return true;
  }
  if (receipt_path_.empty() || lock_path_.empty() ||
      cpu_thermal_type_path_.empty() || cpu_temperature_path_.empty() ||
      !secure_runtime_directory(runtime_path_)) {
    set_error(error, "enabled lease has incomplete or insecure paths");
    return false;
  }
  lock_fd_ = ::open(lock_path_.c_str(),
                    O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (lock_fd_ < 0 || !lock_file_valid(lock_fd_) ||
      ::flock(lock_fd_, LOCK_EX | LOCK_NB) != 0) {
    close_lock();
    set_error(error, "cannot acquire exact cpufreq lease lock");
    return false;
  }
  owner_start_ticks_ = owner_start_ticks_for_testing_;
  if ((owner_start_ticks_ == 0 && !process_start_ticks(&owner_start_ticks_)) ||
      !read_policy(&original_minimum_khz_, &original_maximum_khz_,
                   original_governor_, sizeof(original_governor_), error) ||
      !publish_receipt(error)) {
    close_lock();
    return false;
  }
  active_ = true;
  if (!write_minimum(original_maximum_khz_, error)) {
    (void)release(nullptr);
    return false;
  }
  bool verified = wait_for_policy(original_maximum_khz_, original_maximum_khz_,
                                  original_governor_);
  if (!verified) {
    set_error(error, "cpufreq policy did not settle at the exact ceiling");
  } else if (!temperature_safe(nullptr, error)) {
    verified = false;
  }
  if (!verified) {
    (void)release(nullptr);
    return false;
  }
  return true;
}

bool Rm2CpuFrequencyBurstLease::release(std::string *error) noexcept {
  if (!active_) {
    close_lock();
    return true;
  }
  bool ok = receipt_unchanged();
  if (!ok) {
    set_error(error, "owned receipt changed before restore");
  }
  if (!write_minimum(original_minimum_khz_, ok ? error : nullptr)) {
    ok = false;
  }
  if (!wait_for_policy(original_minimum_khz_, original_maximum_khz_,
                       original_governor_)) {
    ok = false;
    set_error(error, "cpufreq policy did not restore exactly");
  }
  if (ok && ::unlink(receipt_path_.c_str()) != 0) {
    ok = false;
    set_error(error, "restored receipt removal failed");
  }
  if (ok) {
    active_ = false;
    receipt_size_ = 0;
    close_lock();
  }
  return ok;
}

} // namespace pluto::native::rm2
