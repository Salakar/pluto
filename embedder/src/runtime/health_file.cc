#include "runtime/health_file.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <limits>
#include <utility>
#include <vector>

namespace pluto {
namespace {

bool write_all(int fd, const char *data, size_t size, int *error_code) {
  size_t written = 0;
  while (written < size) {
    const ssize_t count = ::write(fd, data + written, size - written);
    if (count > 0) {
      written += static_cast<size_t>(count);
      continue;
    }
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (error_code != nullptr) {
      *error_code = count == 0 ? EIO : errno;
    }
    return false;
  }
  return true;
}

bool atomic_replace(const std::string &path, const char *data, size_t size,
                    int *error_code) {
  std::string temporary = path + ".tmp.XXXXXX";
  std::vector<char> mutable_path(temporary.begin(), temporary.end());
  mutable_path.push_back('\0');

  const int fd = ::mkstemp(mutable_path.data());
  if (fd < 0) {
    if (error_code != nullptr) {
      *error_code = errno;
    }
    return false;
  }

  int saved_errno = 0;
  if (::fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
    saved_errno = errno;
  }
  // mkstemp already requests 0600. Pin it explicitly so an unusual platform
  // implementation or inherited mode cannot broaden the liveness record.
  if (saved_errno == 0 && ::fchmod(fd, S_IRUSR | S_IWUSR) != 0) {
    saved_errno = errno;
  }
  if (saved_errno == 0 && !write_all(fd, data, size, &saved_errno)) {
    // write_all supplied the failure.
  }
  if (saved_errno == 0 && ::fsync(fd) != 0) {
    saved_errno = errno;
  }
  if (::close(fd) != 0 && saved_errno == 0) {
    saved_errno = errno;
  }
  if (saved_errno == 0 && ::rename(mutable_path.data(), path.c_str()) != 0) {
    saved_errno = errno;
  }
  if (saved_errno != 0) {
    (void)::unlink(mutable_path.data());
    if (error_code != nullptr) {
      *error_code = saved_errno;
    }
    return false;
  }
  return true;
}

} // namespace

HealthFilePublisher::HealthFilePublisher(std::string path)
    : path_(std::move(path)) {}

bool HealthFilePublisher::publish(uint64_t monotonic_us, int *error_code) {
  if (error_code != nullptr) {
    *error_code = 0;
  }
  if (path_.empty()) {
    if (error_code != nullptr) {
      *error_code = EINVAL;
    }
    return false;
  }
  if (sequence_ == std::numeric_limits<uint64_t>::max()) {
    if (error_code != nullptr) {
      *error_code = EOVERFLOW;
    }
    return false;
  }

  const uint64_t next_sequence = sequence_ + 1;
  const uint64_t monotonic_ms =
      std::max(last_monotonic_ms_, monotonic_us / 1000u);
  char record[128];
  const int length = std::snprintf(
      record, sizeof(record), "pid=%ld seq=%" PRIu64 " mono_ms=%" PRIu64 "\n",
      static_cast<long>(::getpid()), next_sequence, monotonic_ms);
  if (length < 0 || static_cast<size_t>(length) >= sizeof(record)) {
    if (error_code != nullptr) {
      *error_code = EOVERFLOW;
    }
    return false;
  }
  if (!atomic_replace(path_, record, static_cast<size_t>(length), error_code)) {
    return false;
  }
  sequence_ = next_sequence;
  last_monotonic_ms_ = monotonic_ms;
  return true;
}

} // namespace pluto
