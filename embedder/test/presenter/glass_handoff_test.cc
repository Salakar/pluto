#include "pluto/glass_handoff.h"

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <span>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#include <gtest/gtest.h>

namespace pluto {
namespace {

static_assert(!std::is_copy_constructible_v<GlassHandoffLease>);
static_assert(!std::is_copy_assignable_v<GlassHandoffLease>);
static_assert(std::is_nothrow_move_constructible_v<GlassHandoffLease>);
static_assert(std::is_nothrow_move_assignable_v<GlassHandoffLease>);

constexpr std::size_t kWireHeaderBytesOffset = 8u;
constexpr std::size_t kWireSectionCountOffset = 24u;
constexpr std::size_t kWireTotalBytesOffset = 168u;
constexpr std::size_t kWirePayloadChecksumOffset = 176u;
constexpr std::size_t kWireHeaderChecksumOffset = 184u;
constexpr std::size_t kWireBaseHeaderBytes = 192u;
constexpr std::size_t kWireSectionEntryBytes = 32u;

std::uint32_t read_u32_le(std::span<const std::uint8_t> bytes,
                          std::size_t offset) {
  if (offset > bytes.size() || bytes.size() - offset < sizeof(std::uint32_t)) {
    return 0;
  }
  std::uint32_t value = 0;
  for (unsigned shift = 0; shift < 32; shift += 8) {
    value |= static_cast<std::uint32_t>(bytes[offset++]) << shift;
  }
  return value;
}

std::uint64_t read_u64_le(std::span<const std::uint8_t> bytes,
                          std::size_t offset) {
  if (offset > bytes.size() || bytes.size() - offset < sizeof(std::uint64_t)) {
    return 0;
  }
  std::uint64_t value = 0;
  for (unsigned shift = 0; shift < 64; shift += 8) {
    value |= static_cast<std::uint64_t>(bytes[offset++]) << shift;
  }
  return value;
}

void write_u32_le(std::span<std::uint8_t> bytes, std::size_t offset,
                  std::uint32_t value) {
  if (offset > bytes.size() || bytes.size() - offset < sizeof(value)) {
    return;
  }
  for (unsigned shift = 0; shift < 32; shift += 8) {
    bytes[offset++] = static_cast<std::uint8_t>(value >> shift);
  }
}

void write_u64_le(std::span<std::uint8_t> bytes, std::size_t offset,
                  std::uint64_t value) {
  if (offset > bytes.size() || bytes.size() - offset < sizeof(value)) {
    return;
  }
  for (unsigned shift = 0; shift < 64; shift += 8) {
    bytes[offset++] = static_cast<std::uint8_t>(value >> shift);
  }
}

bool refresh_header_checksum(std::vector<std::uint8_t> *wire) {
  if (wire == nullptr || wire->size() < kWireBaseHeaderBytes) {
    return false;
  }
  std::span<std::uint8_t> bytes(*wire);
  const std::uint32_t header_bytes = read_u32_le(bytes, kWireHeaderBytesOffset);
  if (header_bytes < kWireBaseHeaderBytes || header_bytes > bytes.size()) {
    return false;
  }
  write_u64_le(bytes, kWireHeaderChecksumOffset, 0);
  write_u64_le(bytes, kWireHeaderChecksumOffset,
               glass_handoff_crc64(bytes.first(header_bytes)));
  return true;
}

bool write_byte(int fd, std::uint8_t value) {
  while (true) {
    const ssize_t count = ::write(fd, &value, sizeof(value));
    if (count == static_cast<ssize_t>(sizeof(value))) {
      return true;
    }
    if (count < 0 && errno == EINTR) {
      continue;
    }
    return false;
  }
}

bool read_byte(int fd, std::uint8_t *value, int timeout_ms = 5000) {
  if (value == nullptr) {
    return false;
  }
  pollfd descriptor{.fd = fd, .events = POLLIN | POLLHUP, .revents = 0};
  int ready = 0;
  do {
    ready = ::poll(&descriptor, 1, timeout_ms);
  } while (ready < 0 && errno == EINTR);
  if (ready <= 0 || (descriptor.revents & (POLLIN | POLLHUP)) == 0) {
    return false;
  }
  while (true) {
    const ssize_t count = ::read(fd, value, sizeof(*value));
    if (count == static_cast<ssize_t>(sizeof(*value))) {
      return true;
    }
    if (count < 0 && errno == EINTR) {
      continue;
    }
    return false;
  }
}

class ChildGuard final {
public:
  explicit ChildGuard(pid_t pid) : pid_(pid) {}
  ChildGuard(const ChildGuard &) = delete;
  ChildGuard &operator=(const ChildGuard &) = delete;
  ~ChildGuard() {
    if (pid_ > 0) {
      (void)::kill(pid_, SIGKILL);
      int status = 0;
      while (::waitpid(pid_, &status, 0) < 0 && errno == EINTR) {
      }
    }
  }

  pid_t pid() const { return pid_; }
  bool wait(int *status) {
    if (pid_ <= 0 || status == nullptr) {
      return false;
    }
    pid_t waited = -1;
    do {
      waited = ::waitpid(pid_, status, 0);
    } while (waited < 0 && errno == EINTR);
    if (waited != pid_) {
      return false;
    }
    pid_ = -1;
    return true;
  }

private:
  pid_t pid_ = -1;
};

class TempBundlePath final {
public:
  explicit TempBundlePath(bool acquire = true) {
    std::array<char, 128> pattern{};
    const std::string base = std::filesystem::temp_directory_path().string() +
                             "/pluto-glass-handoff-XXXXXX";
    std::copy(base.begin(), base.end(), pattern.begin());
    char *directory = ::mkdtemp(pattern.data());
    if (directory != nullptr) {
      directory_ = directory;
      path_ = directory_ + "/glass.handoff";
      if (acquire) {
        (void)glass_handoff_acquire_lease(path_, &lease_);
      }
    }
  }

  ~TempBundlePath() {
    if (!path_.empty() && !lease_.valid()) {
      (void)glass_handoff_acquire_lease(path_, &lease_);
    }
    const bool owns_cleanup_lease = lease_.valid();
    if (owns_cleanup_lease) {
      (void)glass_handoff_discard(lease_, path_);
    }
    lease_ = {};
    if (!path_.empty() && owns_cleanup_lease) {
      // Production never unlinks the persistent lease inode. A test-private
      // directory can remove it only after releasing the proven sole lease.
      (void)::unlink((path_ + ".lease").c_str());
      (void)::rmdir(directory_.c_str());
    }
  }

  const std::string &path() const { return path_; }
  GlassHandoffLease &lease() { return lease_; }
  const GlassHandoffLease &lease() const { return lease_; }

private:
  std::string directory_;
  std::string path_;
  GlassHandoffLease lease_;
};

GlassHandoffBundle mono_bundle() {
  GlassHandoffBundle bundle;
  bundle.identity.flags = kGlassHandoffFlagNone;
  bundle.identity.profile = GlassHandoffProfile::kMonochrome;
  bundle.identity.width = 8;
  bundle.identity.height = 4;
  bundle.identity.pixel_format = 1; // kPlutoPixelFormatGray8
  bundle.identity.engine_stride = 8;
  bundle.identity.tile_px = 4;
  bundle.identity.waveform_hash = 0x1111222233334444ull;
  bundle.identity.waveform_bytes = 4096;
  bundle.identity.pipeline_hash = 0x5555666677778888ull;
  bundle.renderer.width = 8;
  bundle.renderer.height = 4;
  bundle.renderer.rotation = 0;
  bundle.renderer.pixel_format = 1;
  bundle.renderer.configuration_hash = 0x8899aabbccddeeffull;
  bundle.written = {.realtime_sec = 1'000'000,
                    .boottime_ns = 40'000'000'000ull,
                    .boot_id_hash = 0x12345678ull};
  bundle.chain = 3;
  bundle.core.engine_temperature_bin = 7;
  bundle.core.admission_temperature_bin = 6;
  bundle.core.engine_levels.resize(32);
  bundle.core.engine_dc.resize(32);
  for (std::size_t i = 0; i < 32; ++i) {
    bundle.core.engine_levels[i] = static_cast<std::uint8_t>(i & 31u);
    bundle.core.engine_dc[i] = static_cast<std::int8_t>(i - 16);
  }
  bundle.core.engine_stress = {11, 22};
  bundle.core.engine_rescan = {-31, 47};
  bundle.renderer_payload = {0x52, 0x45, 0x4e, 0x44, 0x32};
  return bundle;
}

GlassHandoffClock shortly_after(const GlassHandoffBundle &bundle) {
  GlassHandoffClock now = bundle.written;
  now.realtime_sec += 1;
  now.boottime_ns += 1'000'000'000ull;
  return now;
}

std::vector<std::uint8_t> read_file(const std::string &path) {
  const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    return {};
  }
  struct stat stat_buffer {};
  if (::fstat(fd, &stat_buffer) != 0 || stat_buffer.st_size < 0) {
    (void)::close(fd);
    return {};
  }
  std::vector<std::uint8_t> bytes(
      static_cast<std::size_t>(stat_buffer.st_size));
  std::size_t done = 0;
  while (done < bytes.size()) {
    const ssize_t count = ::read(fd, bytes.data() + done, bytes.size() - done);
    if (count <= 0) {
      bytes.clear();
      break;
    }
    done += static_cast<std::size_t>(count);
  }
  (void)::close(fd);
  return bytes;
}

bool write_file(const std::string &path,
                const std::vector<std::uint8_t> &bytes) {
  const int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                        S_IRUSR | S_IWUSR);
  if (fd < 0) {
    return false;
  }
  std::size_t done = 0;
  while (done < bytes.size()) {
    const ssize_t count = ::write(fd, bytes.data() + done, bytes.size() - done);
    if (count <= 0) {
      (void)::close(fd);
      return false;
    }
    done += static_cast<std::size_t>(count);
  }
  return ::close(fd) == 0;
}

bool set_file_age(const std::string &path, std::int64_t age_sec) {
  timespec now{};
  if (age_sec < 0 || ::clock_gettime(CLOCK_REALTIME, &now) != 0 ||
      now.tv_sec <= age_sec) {
    return false;
  }
  const timespec old = {.tv_sec = now.tv_sec - age_sec, .tv_nsec = now.tv_nsec};
  const std::array<timespec, 2> times = {old, old};
  return ::utimensat(AT_FDCWD, path.c_str(), times.data(), 0) == 0;
}

TEST(GlassHandoffTest, Crc64MatchesEcma182CheckValue) {
  constexpr std::array<std::uint8_t, 9> kCheck = {'1', '2', '3', '4', '5',
                                                  '6', '7', '8', '9'};
  EXPECT_EQ(glass_handoff_crc64(kCheck), 0x6c40df5f0b497347ull);
}

TEST(GlassHandoffTest, LeaseIsRequiredAndDiscardOfAbsentPairIsIdempotent) {
  TempBundlePath temporary;
  ASSERT_TRUE(temporary.lease().valid());
  EXPECT_TRUE(glass_handoff_discard(temporary.lease(), temporary.path()));

  GlassHandoffLease invalid;
  EXPECT_FALSE(glass_handoff_discard(invalid, temporary.path()));
  EXPECT_FALSE(glass_handoff_discard(temporary.lease(), ""));

  const std::string missing_parent =
      std::filesystem::temp_directory_path().string() +
      "/pluto-glass-handoff-no-parent-" + std::to_string(::getpid());
  (void)::rmdir(missing_parent.c_str());
  GlassHandoffLease missing;
  EXPECT_FALSE(
      glass_handoff_acquire_lease(missing_parent + "/glass.handoff", &missing));
}

TEST(GlassHandoffTest, LeaseIsMoveOnlyPathBoundAndInvalidCallsFailClosed) {
  TempBundlePath first(false);
  TempBundlePath second(false);
  ASSERT_TRUE(!first.path().empty());
  ASSERT_TRUE(!second.path().empty());
  GlassHandoffLease original;
  ASSERT_TRUE(glass_handoff_acquire_lease(first.path(), &original));
  GlassHandoffLease moved(std::move(original));
  EXPECT_FALSE(original.valid());
  ASSERT_TRUE(moved.valid());

  const GlassHandoffBundle source = mono_bundle();
  GlassHandoffLease invalid;
  EXPECT_FALSE(glass_handoff_save(invalid, first.path(), source));
  EXPECT_FALSE(glass_handoff_save(moved, second.path(), source));
  EXPECT_FALSE(std::filesystem::exists(first.path()));
  EXPECT_FALSE(std::filesystem::exists(second.path()));

  GlassHandoffBundle stale = source;
  EXPECT_EQ(static_cast<int>(glass_handoff_load(invalid, first.path(),
                                                source.identity,
                                                shortly_after(source), &stale)),
            static_cast<int>(GlassHandoffReject::kState));
  EXPECT_FALSE(stale.claim.valid);
  EXPECT_TRUE(stale.renderer_payload.empty());
  EXPECT_FALSE(glass_handoff_discard(invalid, first.path()));
  EXPECT_FALSE(glass_handoff_discard(moved, second.path()));
}

TEST(GlassHandoffTest, BarrierSynchronizedForksHaveExactlyOneLeaseOwner) {
  TempBundlePath temporary(false);
  ASSERT_TRUE(!temporary.path().empty());
  int ready_pipe[2] = {-1, -1};
  int go_pipe[2] = {-1, -1};
  int result_pipe[2] = {-1, -1};
  int release_pipe[2] = {-1, -1};
  ASSERT_EQ(::pipe(ready_pipe), 0);
  ASSERT_EQ(::pipe(go_pipe), 0);
  ASSERT_EQ(::pipe(result_pipe), 0);
  ASSERT_EQ(::pipe(release_pipe), 0);

  const auto run_child = [&] {
    (void)::close(ready_pipe[0]);
    (void)::close(go_pipe[1]);
    (void)::close(result_pipe[0]);
    (void)::close(release_pipe[1]);
    std::uint8_t token = 0;
    bool ok = write_byte(ready_pipe[1], 1u) && read_byte(go_pipe[0], &token);
    {
      GlassHandoffLease lease;
      const bool acquired =
          ok && glass_handoff_acquire_lease(temporary.path(), &lease);
      ok = ok && write_byte(result_pipe[1], acquired ? 1u : 0u) &&
           read_byte(release_pipe[0], &token);
    }
    _exit(ok ? 0 : 90);
  };

  const pid_t first_pid = ::fork();
  ASSERT_GE(first_pid, 0);
  if (first_pid == 0) {
    run_child();
  }
  ChildGuard first(first_pid);
  const pid_t second_pid = ::fork();
  ASSERT_GE(second_pid, 0);
  if (second_pid == 0) {
    run_child();
  }
  ChildGuard second(second_pid);

  (void)::close(ready_pipe[1]);
  (void)::close(go_pipe[0]);
  (void)::close(result_pipe[1]);
  (void)::close(release_pipe[0]);
  std::uint8_t token = 0;
  ASSERT_TRUE(read_byte(ready_pipe[0], &token));
  ASSERT_TRUE(read_byte(ready_pipe[0], &token));
  ASSERT_TRUE(write_byte(go_pipe[1], 1u));
  ASSERT_TRUE(write_byte(go_pipe[1], 1u));
  std::uint8_t first_result = 0;
  std::uint8_t second_result = 0;
  ASSERT_TRUE(read_byte(result_pipe[0], &first_result));
  ASSERT_TRUE(read_byte(result_pipe[0], &second_result));

  GlassHandoffLease blocked;
  const bool parent_acquired =
      glass_handoff_acquire_lease(temporary.path(), &blocked);
  blocked = {};
  ASSERT_TRUE(write_byte(release_pipe[1], 1u));
  ASSERT_TRUE(write_byte(release_pipe[1], 1u));
  (void)::close(ready_pipe[0]);
  (void)::close(go_pipe[1]);
  (void)::close(result_pipe[0]);
  (void)::close(release_pipe[1]);

  int first_status = 0;
  int second_status = 0;
  ASSERT_TRUE(first.wait(&first_status));
  ASSERT_TRUE(second.wait(&second_status));
  EXPECT_TRUE(WIFEXITED(first_status));
  EXPECT_EQ(WEXITSTATUS(first_status), 0);
  EXPECT_TRUE(WIFEXITED(second_status));
  EXPECT_EQ(WEXITSTATUS(second_status), 0);
  EXPECT_EQ(static_cast<unsigned>(first_result) + second_result, 1u);
  EXPECT_FALSE(parent_acquired);

  GlassHandoffLease after;
  EXPECT_TRUE(glass_handoff_acquire_lease(temporary.path(), &after));
}

TEST(GlassHandoffTest, InheritedLeaseCannotOperateOrReleaseParentOwnership) {
  TempBundlePath temporary;
  ASSERT_TRUE(temporary.lease().valid());
  const GlassHandoffBundle source = mono_bundle();
  int go_pipe[2] = {-1, -1};
  int result_pipe[2] = {-1, -1};
  ASSERT_EQ(::pipe(go_pipe), 0);
  ASSERT_EQ(::pipe(result_pipe), 0);

  const pid_t child_pid = ::fork();
  ASSERT_GE(child_pid, 0);
  if (child_pid == 0) {
    (void)::close(go_pipe[1]);
    (void)::close(result_pipe[0]);
    std::uint8_t token = 0;
    bool ok = read_byte(go_pipe[0], &token);
    std::uint8_t result = 0;
    if (!temporary.lease().valid()) {
      result |= 1u;
    }
    if (!glass_handoff_save(temporary.lease(), temporary.path(), source)) {
      result |= 2u;
    }
    // Closing the inherited duplicate must not explicitly LOCK_UN the shared
    // open-file description: the parent's ownership remains authoritative.
    temporary.lease() = {};
    GlassHandoffLease fresh;
    if (!glass_handoff_acquire_lease(temporary.path(), &fresh)) {
      result |= 4u;
    }
    ok = ok && write_byte(result_pipe[1], result);
    _exit(ok ? 0 : 93);
  }
  ChildGuard child(child_pid);
  (void)::close(go_pipe[0]);
  (void)::close(result_pipe[1]);
  ASSERT_TRUE(write_byte(go_pipe[1], 1u));
  std::uint8_t result = 0;
  ASSERT_TRUE(read_byte(result_pipe[0], &result));
  EXPECT_EQ(result, 7u);
  int status = 0;
  ASSERT_TRUE(child.wait(&status));
  ASSERT_TRUE(WIFEXITED(status));
  EXPECT_EQ(WEXITSTATUS(status), 0);
  (void)::close(go_pipe[1]);
  (void)::close(result_pipe[0]);

  ASSERT_TRUE(temporary.lease().valid());
  EXPECT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));
}

TEST(GlassHandoffTest, LeaseIsReleasedWhenOwnerIsKilled) {
  TempBundlePath temporary(false);
  ASSERT_TRUE(!temporary.path().empty());
  int ready_pipe[2] = {-1, -1};
  int go_pipe[2] = {-1, -1};
  int result_pipe[2] = {-1, -1};
  ASSERT_EQ(::pipe(ready_pipe), 0);
  ASSERT_EQ(::pipe(go_pipe), 0);
  ASSERT_EQ(::pipe(result_pipe), 0);

  const pid_t child_pid = ::fork();
  ASSERT_GE(child_pid, 0);
  if (child_pid == 0) {
    (void)::close(ready_pipe[0]);
    (void)::close(go_pipe[1]);
    (void)::close(result_pipe[0]);
    std::uint8_t token = 0;
    bool ok = write_byte(ready_pipe[1], 1u) && read_byte(go_pipe[0], &token);
    GlassHandoffLease lease;
    const bool acquired =
        ok && glass_handoff_acquire_lease(temporary.path(), &lease);
    ok = ok && write_byte(result_pipe[1], acquired ? 1u : 0u);
    if (!ok || !acquired) {
      _exit(91);
    }
    while (true) {
      (void)::pause();
    }
  }
  ChildGuard child(child_pid);
  (void)::close(ready_pipe[1]);
  (void)::close(go_pipe[0]);
  (void)::close(result_pipe[1]);
  std::uint8_t token = 0;
  ASSERT_TRUE(read_byte(ready_pipe[0], &token));
  ASSERT_TRUE(write_byte(go_pipe[1], 1u));
  ASSERT_TRUE(read_byte(result_pipe[0], &token));
  ASSERT_EQ(token, 1u);

  GlassHandoffLease blocked;
  EXPECT_FALSE(glass_handoff_acquire_lease(temporary.path(), &blocked));
  ASSERT_EQ(::kill(child.pid(), SIGKILL), 0);
  int status = 0;
  ASSERT_TRUE(child.wait(&status));
  ASSERT_TRUE(WIFSIGNALED(status));
  EXPECT_EQ(WTERMSIG(status), SIGKILL);
  (void)::close(ready_pipe[0]);
  (void)::close(go_pipe[1]);
  (void)::close(result_pipe[0]);

  GlassHandoffLease recovered;
  ASSERT_TRUE(glass_handoff_acquire_lease(temporary.path(), &recovered));
  EXPECT_TRUE(glass_handoff_save(recovered, temporary.path(), mono_bundle()));
}

TEST(GlassHandoffTest, LeaseExcludesReplacementBeforeAndAfterFirstClaim) {
  TempBundlePath temporary(false);
  ASSERT_TRUE(!temporary.path().empty());
  const GlassHandoffBundle source = mono_bundle();
  {
    GlassHandoffLease seed;
    ASSERT_TRUE(glass_handoff_acquire_lease(temporary.path(), &seed));
    ASSERT_TRUE(glass_handoff_save(seed, temporary.path(), source));
  }

  int loaded_pipe[2] = {-1, -1};
  int claim_pipe[2] = {-1, -1};
  int result_pipe[2] = {-1, -1};
  int release_pipe[2] = {-1, -1};
  ASSERT_EQ(::pipe(loaded_pipe), 0);
  ASSERT_EQ(::pipe(claim_pipe), 0);
  ASSERT_EQ(::pipe(result_pipe), 0);
  ASSERT_EQ(::pipe(release_pipe), 0);

  const pid_t child_pid = ::fork();
  ASSERT_GE(child_pid, 0);
  if (child_pid == 0) {
    (void)::close(loaded_pipe[0]);
    (void)::close(claim_pipe[1]);
    (void)::close(result_pipe[0]);
    (void)::close(release_pipe[1]);
    GlassHandoffLease incoming;
    GlassHandoffBundle loaded;
    const bool acquired =
        glass_handoff_acquire_lease(temporary.path(), &incoming);
    const bool loaded_ok =
        acquired && glass_handoff_load(incoming, temporary.path(),
                                       source.identity, shortly_after(source),
                                       &loaded) == GlassHandoffReject::kNone;
    bool ok = write_byte(loaded_pipe[1], loaded_ok ? 1u : 0u);
    std::uint8_t token = 0;
    ok = ok && read_byte(claim_pipe[0], &token);
    const bool claimed =
        loaded_ok &&
        glass_handoff_claim(incoming, temporary.path(), loaded.claim);
    ok = ok && write_byte(result_pipe[1], claimed ? 1u : 0u) &&
         read_byte(release_pipe[0], &token);
    _exit(ok && claimed ? 0 : 92);
  }
  ChildGuard child(child_pid);
  (void)::close(loaded_pipe[1]);
  (void)::close(claim_pipe[0]);
  (void)::close(result_pipe[1]);
  (void)::close(release_pipe[0]);

  std::uint8_t token = 0;
  ASSERT_TRUE(read_byte(loaded_pipe[0], &token));
  ASSERT_EQ(token, 1u);
  GlassHandoffLease blocked_before;
  EXPECT_FALSE(glass_handoff_acquire_lease(temporary.path(), &blocked_before));
  GlassHandoffLease invalid;
  GlassHandoffBundle replacement = source;
  replacement.renderer_payload.back() ^= 0x80u;
  EXPECT_FALSE(glass_handoff_save(invalid, temporary.path(), replacement));
  EXPECT_TRUE(std::filesystem::exists(temporary.path()));

  ASSERT_TRUE(write_byte(claim_pipe[1], 1u));
  ASSERT_TRUE(read_byte(result_pipe[0], &token));
  ASSERT_EQ(token, 1u);
  EXPECT_FALSE(std::filesystem::exists(temporary.path()));
  GlassHandoffLease blocked_after;
  EXPECT_FALSE(glass_handoff_acquire_lease(temporary.path(), &blocked_after));

  ASSERT_TRUE(write_byte(release_pipe[1], 1u));
  int status = 0;
  ASSERT_TRUE(child.wait(&status));
  ASSERT_TRUE(WIFEXITED(status));
  EXPECT_EQ(WEXITSTATUS(status), 0);
  (void)::close(loaded_pipe[0]);
  (void)::close(claim_pipe[1]);
  (void)::close(result_pipe[0]);
  (void)::close(release_pipe[1]);

  GlassHandoffLease next_owner;
  ASSERT_TRUE(glass_handoff_acquire_lease(temporary.path(), &next_owner));
  EXPECT_TRUE(glass_handoff_save(next_owner, temporary.path(), replacement));
}

TEST(GlassHandoffTest, RoundTripPreservesAllStateAndAtomicFileContract) {
  TempBundlePath temporary;
  const GlassHandoffBundle source = mono_bundle();
  ASSERT_TRUE(!temporary.path().empty());
  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  EXPECT_FALSE(std::filesystem::exists(temporary.path() + ".tmp"));

  struct stat stat_buffer {};
  ASSERT_EQ(::stat(temporary.path().c_str(), &stat_buffer), 0);
  EXPECT_EQ(stat_buffer.st_mode & 0777, 0600);

  GlassHandoffBundle loaded;
  EXPECT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kNone));
  EXPECT_TRUE(loaded.identity == source.identity);
  EXPECT_TRUE(loaded.renderer == source.renderer);
  EXPECT_EQ(loaded.chain, source.chain);
  EXPECT_EQ(loaded.core.engine_temperature_bin,
            source.core.engine_temperature_bin);
  EXPECT_EQ(loaded.core.admission_temperature_bin,
            source.core.admission_temperature_bin);
  EXPECT_TRUE(loaded.core.engine_levels == source.core.engine_levels);
  EXPECT_TRUE(loaded.core.engine_dc == source.core.engine_dc);
  EXPECT_TRUE(loaded.core.engine_stress == source.core.engine_stress);
  EXPECT_TRUE(loaded.core.engine_rescan == source.core.engine_rescan);
  EXPECT_TRUE(loaded.renderer_payload == source.renderer_payload);
  EXPECT_TRUE(loaded.presenter_payload.empty());
  EXPECT_TRUE(loaded.claim.valid);
  EXPECT_TRUE(
      glass_handoff_claim(temporary.lease(), temporary.path(), loaded.claim));
  EXPECT_FALSE(std::filesystem::exists(temporary.path()));
}

TEST(GlassHandoffTest,
     PresenterPayloadRoundTripsAfterRendererAndPreservesClaimContract) {
  TempBundlePath temporary;
  GlassHandoffBundle source = mono_bundle();
  source.presenter_payload = {0x50, 0x52, 0x45, 0x53, 0x00, 0xff};
  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));

  const std::vector<std::uint8_t> wire = read_file(temporary.path());
  const std::span<const std::uint8_t> bytes(wire);
  constexpr std::uint32_t kMonoSectionCountWithPresenter = 6u;
  constexpr std::size_t kRendererDirectory =
      kWireBaseHeaderBytes + 4u * kWireSectionEntryBytes;
  constexpr std::size_t kPresenterDirectory =
      kWireBaseHeaderBytes + 5u * kWireSectionEntryBytes;
  constexpr std::size_t kExpectedHeaderBytes =
      kWireBaseHeaderBytes +
      kMonoSectionCountWithPresenter * kWireSectionEntryBytes;
  ASSERT_GE(wire.size(), kExpectedHeaderBytes);
  EXPECT_EQ(read_u32_le(bytes, kWireSectionCountOffset),
            kMonoSectionCountWithPresenter);
  EXPECT_EQ(read_u32_le(bytes, kWireHeaderBytesOffset), kExpectedHeaderBytes);
  EXPECT_EQ(read_u64_le(bytes, kWireTotalBytesOffset), wire.size());
  EXPECT_EQ(read_u64_le(bytes, kWirePayloadChecksumOffset),
            glass_handoff_crc64(bytes.subspan(kExpectedHeaderBytes)));
  EXPECT_EQ(read_u32_le(bytes, kRendererDirectory),
            static_cast<std::uint32_t>(GlassHandoffSection::kRenderer));
  EXPECT_EQ(read_u32_le(bytes, kPresenterDirectory),
            static_cast<std::uint32_t>(GlassHandoffSection::kPresenter));

  const std::uint64_t renderer_offset =
      read_u64_le(bytes, kRendererDirectory + 8u);
  const std::uint64_t renderer_size =
      read_u64_le(bytes, kRendererDirectory + 16u);
  const std::uint64_t presenter_offset =
      read_u64_le(bytes, kPresenterDirectory + 8u);
  const std::uint64_t presenter_size =
      read_u64_le(bytes, kPresenterDirectory + 16u);
  EXPECT_EQ(renderer_offset + renderer_size, presenter_offset);
  EXPECT_EQ(presenter_size, source.presenter_payload.size());
  EXPECT_EQ(presenter_offset + presenter_size, wire.size());
  ASSERT_TRUE(presenter_offset <= wire.size());
  ASSERT_TRUE(presenter_size <= wire.size() - presenter_offset);
  const auto presenter_bytes =
      bytes.subspan(static_cast<std::size_t>(presenter_offset),
                    static_cast<std::size_t>(presenter_size));
  EXPECT_TRUE(std::equal(presenter_bytes.begin(), presenter_bytes.end(),
                         source.presenter_payload.begin()));
  EXPECT_EQ(read_u64_le(bytes, kPresenterDirectory + 24u),
            glass_handoff_crc64(presenter_bytes));

  std::vector<std::uint8_t> header(wire.begin(),
                                   wire.begin() + kExpectedHeaderBytes);
  const std::uint64_t encoded_header_checksum =
      read_u64_le(header, kWireHeaderChecksumOffset);
  write_u64_le(header, kWireHeaderChecksumOffset, 0);
  EXPECT_EQ(glass_handoff_crc64(header), encoded_header_checksum);

  GlassHandoffBundle loaded;
  ASSERT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kNone));
  EXPECT_TRUE(loaded.presenter_payload == source.presenter_payload);
  ASSERT_TRUE(loaded.claim.valid);
  EXPECT_TRUE(
      glass_handoff_claim(temporary.lease(), temporary.path(), loaded.claim));
  EXPECT_FALSE(std::filesystem::exists(temporary.path()));
}

TEST(GlassHandoffTest,
     PresenterPayloadRejectsTrailingCorruptAndMalformedLayouts) {
  TempBundlePath temporary;
  GlassHandoffBundle source = mono_bundle();
  source.presenter_payload = {0x10, 0x20, 0x30, 0x40};
  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  const std::vector<std::uint8_t> good = read_file(temporary.path());
  const std::uint32_t header_bytes = read_u32_le(good, kWireHeaderBytesOffset);
  ASSERT_GE(header_bytes, kWireBaseHeaderBytes + kWireSectionEntryBytes);
  ASSERT_TRUE(header_bytes <= good.size());
  const std::size_t presenter_directory = header_bytes - kWireSectionEntryBytes;
  ASSERT_EQ(read_u32_le(good, presenter_directory),
            static_cast<std::uint32_t>(GlassHandoffSection::kPresenter));

  const auto expect_reject = [&](const std::vector<std::uint8_t> &wire,
                                 GlassHandoffReject expected) {
    ASSERT_TRUE(write_file(temporary.path(), wire));
    GlassHandoffBundle loaded;
    EXPECT_EQ(static_cast<int>(glass_handoff_load(
                  temporary.lease(), temporary.path(), source.identity,
                  shortly_after(source), &loaded)),
              static_cast<int>(expected));
  };

  std::vector<std::uint8_t> trailing = good;
  trailing.push_back(0xaa);
  expect_reject(trailing, GlassHandoffReject::kLayout);

  std::vector<std::uint8_t> corrupt = good;
  corrupt.back() ^= 0x80u;
  expect_reject(corrupt, GlassHandoffReject::kChecksum);

  std::vector<std::uint8_t> payload_checksum_mismatch = good;
  write_u64_le(
      payload_checksum_mismatch, kWirePayloadChecksumOffset,
      read_u64_le(payload_checksum_mismatch, kWirePayloadChecksumOffset) ^ 1u);
  ASSERT_TRUE(refresh_header_checksum(&payload_checksum_mismatch));
  expect_reject(payload_checksum_mismatch, GlassHandoffReject::kChecksum);

  std::vector<std::uint8_t> duplicate_renderer = good;
  write_u32_le(duplicate_renderer, presenter_directory,
               static_cast<std::uint32_t>(GlassHandoffSection::kRenderer));
  expect_reject(duplicate_renderer, GlassHandoffReject::kLayout);

  std::vector<std::uint8_t> zero_sized = good;
  write_u64_le(zero_sized, presenter_directory + 16u, 0);
  expect_reject(zero_sized, GlassHandoffReject::kLayout);

  std::vector<std::uint8_t> unknown_type = good;
  write_u32_le(unknown_type, presenter_directory,
               static_cast<std::uint32_t>(GlassHandoffSection::kPresenter) +
                   1u);
  expect_reject(unknown_type, GlassHandoffReject::kLayout);
}

TEST(GlassHandoffTest, PresenterPayloadBoundFailsClosedOnSaveAndLoad) {
  TempBundlePath temporary;
  GlassHandoffBundle source = mono_bundle();
  source.presenter_payload.assign(
      static_cast<std::size_t>(kGlassHandoffMaxPresenterPayloadBytes + 1u),
      0x5au);
  EXPECT_FALSE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  EXPECT_FALSE(std::filesystem::exists(temporary.path()));

  source.presenter_payload.resize(
      static_cast<std::size_t>(kGlassHandoffMaxPresenterPayloadBytes));
  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  std::vector<std::uint8_t> wire = read_file(temporary.path());
  const std::uint32_t header_bytes = read_u32_le(wire, kWireHeaderBytesOffset);
  ASSERT_GE(header_bytes, kWireBaseHeaderBytes + kWireSectionEntryBytes);
  ASSERT_TRUE(header_bytes <= wire.size());
  const std::size_t presenter_directory = header_bytes - kWireSectionEntryBytes;
  ASSERT_EQ(read_u32_le(wire, presenter_directory),
            static_cast<std::uint32_t>(GlassHandoffSection::kPresenter));
  const std::uint64_t presenter_offset =
      read_u64_le(wire, presenter_directory + 8u);
  ASSERT_EQ(read_u64_le(wire, presenter_directory + 16u),
            kGlassHandoffMaxPresenterPayloadBytes);
  ASSERT_EQ(presenter_offset + kGlassHandoffMaxPresenterPayloadBytes,
            wire.size());

  wire.push_back(0xa5u);
  const std::uint64_t oversized_payload_bytes =
      kGlassHandoffMaxPresenterPayloadBytes + 1u;
  write_u64_le(wire, presenter_directory + 16u, oversized_payload_bytes);
  const std::span<const std::uint8_t> bytes(wire);
  const auto presenter_bytes =
      bytes.subspan(static_cast<std::size_t>(presenter_offset),
                    static_cast<std::size_t>(oversized_payload_bytes));
  write_u64_le(wire, presenter_directory + 24u,
               glass_handoff_crc64(presenter_bytes));
  write_u64_le(wire, kWireTotalBytesOffset, wire.size());
  write_u64_le(wire, kWirePayloadChecksumOffset,
               glass_handoff_crc64(
                   std::span<const std::uint8_t>(wire).subspan(header_bytes)));
  ASSERT_TRUE(refresh_header_checksum(&wire));
  ASSERT_TRUE(write_file(temporary.path(), wire));

  GlassHandoffBundle loaded;
  EXPECT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kTooLarge));
  EXPECT_TRUE(loaded.presenter_payload.empty());
}

TEST(GlassHandoffTest, RejectsZeroClockProofsAndRequiresPositiveFallback) {
  TempBundlePath temporary;
  GlassHandoffBundle source = mono_bundle();

  source.written = {};
  EXPECT_FALSE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  source.written.boottime_ns = 1'000'000'000ull;
  EXPECT_FALSE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  source.written = {
      .realtime_sec = 100, .boottime_ns = 0, .boot_id_hash = 0x55};
  EXPECT_FALSE(glass_handoff_save(temporary.lease(), temporary.path(), source));

  // A positive boot identity and boottime are a complete proof even when
  // CLOCK_REALTIME is unavailable.
  source.written = {
      .realtime_sec = 0, .boottime_ns = 2'000'000'000ull, .boot_id_hash = 0x55};
  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  GlassHandoffBundle loaded;
  GlassHandoffClock same_boot = source.written;
  same_boot.boottime_ns += 1'000'000'000ull;
  EXPECT_EQ(
      static_cast<int>(glass_handoff_load(temporary.lease(), temporary.path(),
                                          source.identity, same_boot, &loaded)),
      static_cast<int>(GlassHandoffReject::kNone));

  // Matching nonzero boot IDs never turn zero boottime into age zero.
  same_boot.boottime_ns = 0;
  EXPECT_EQ(
      static_cast<int>(glass_handoff_load(temporary.lease(), temporary.path(),
                                          source.identity, same_boot, &loaded)),
      static_cast<int>(GlassHandoffReject::kAge));

  // If either boot ID is unavailable, fallback requires strictly positive
  // realtime on both sides; zero is not a valid Unix-epoch age proof.
  EXPECT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                GlassHandoffClock{}, &loaded)),
            static_cast<int>(GlassHandoffReject::kAge));

  source.written = {.realtime_sec = 100, .boottime_ns = 0, .boot_id_hash = 0};
  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  const GlassHandoffClock realtime_now = {
      .realtime_sec = 101, .boottime_ns = 0, .boot_id_hash = 0};
  EXPECT_EQ(static_cast<int>(
                glass_handoff_load(temporary.lease(), temporary.path(),
                                   source.identity, realtime_now, &loaded)),
            static_cast<int>(GlassHandoffReject::kNone));
}

TEST(GlassHandoffTest, ExactCandidateCanBeClaimedOnlyOnce) {
  TempBundlePath temporary;
  const GlassHandoffBundle source = mono_bundle();
  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));

  GlassHandoffBundle first;
  GlassHandoffBundle second;
  ASSERT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                shortly_after(source), &first)),
            static_cast<int>(GlassHandoffReject::kNone));
  ASSERT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                shortly_after(source), &second)),
            static_cast<int>(GlassHandoffReject::kNone));
  ASSERT_TRUE(first.claim.valid);
  ASSERT_TRUE(second.claim.valid);

  EXPECT_TRUE(
      glass_handoff_claim(temporary.lease(), temporary.path(), first.claim));
  EXPECT_FALSE(
      glass_handoff_claim(temporary.lease(), temporary.path(), second.claim));
  EXPECT_FALSE(std::filesystem::exists(temporary.path()));
}

TEST(GlassHandoffTest, ClaimRejectsAndConsumesReplacementCandidate) {
  TempBundlePath temporary;
  const GlassHandoffBundle source = mono_bundle();
  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  GlassHandoffBundle loaded;
  ASSERT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kNone));

  GlassHandoffBundle replacement = source;
  replacement.renderer_payload.back() ^= 0x80u;
  ASSERT_TRUE(
      glass_handoff_save(temporary.lease(), temporary.path(), replacement));
  EXPECT_FALSE(
      glass_handoff_claim(temporary.lease(), temporary.path(), loaded.claim));
  EXPECT_FALSE(std::filesystem::exists(temporary.path()));
}

TEST(GlassHandoffTest, ClaimRejectsAndConsumesPartialOrCorruptCandidate) {
  TempBundlePath temporary;
  const GlassHandoffBundle source = mono_bundle();
  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  GlassHandoffBundle loaded;
  ASSERT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kNone));
  const std::vector<std::uint8_t> good = read_file(temporary.path());
  ASSERT_GT(good.size(), 192u);

  const std::vector<std::uint8_t> partial(good.begin(), good.begin() + 80);
  ASSERT_TRUE(write_file(temporary.path(), partial));
  EXPECT_FALSE(
      glass_handoff_claim(temporary.lease(), temporary.path(), loaded.claim));
  EXPECT_FALSE(std::filesystem::exists(temporary.path()));

  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  ASSERT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kNone));
  std::vector<std::uint8_t> corrupt = read_file(temporary.path());
  ASSERT_GT(corrupt.size(), 192u);
  corrupt[40] ^= 0x40u;
  ASSERT_TRUE(write_file(temporary.path(), corrupt));
  EXPECT_FALSE(
      glass_handoff_claim(temporary.lease(), temporary.path(), loaded.claim));
  EXPECT_FALSE(std::filesystem::exists(temporary.path()));
}

TEST(GlassHandoffTest, RejectsPartialTrailingReorderedAndCorruptFiles) {
  TempBundlePath temporary;
  const GlassHandoffBundle source = mono_bundle();
  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  const std::vector<std::uint8_t> good = read_file(temporary.path());
  ASSERT_GT(good.size(), 256u);

  std::vector<std::uint8_t> partial(good.begin(), good.begin() + 80);
  ASSERT_TRUE(write_file(temporary.path(), partial));
  GlassHandoffBundle loaded;
  EXPECT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kPartial));

  std::vector<std::uint8_t> trailing = good;
  trailing.push_back(0xaa);
  ASSERT_TRUE(write_file(temporary.path(), trailing));
  EXPECT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kLayout));

  std::vector<std::uint8_t> reordered = good;
  // Base header is 192 bytes; swap only the first two directory type words.
  for (std::size_t i = 0; i < 4; ++i) {
    std::swap(reordered[192 + i], reordered[224 + i]);
  }
  ASSERT_TRUE(write_file(temporary.path(), reordered));
  EXPECT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kLayout));

  std::vector<std::uint8_t> corrupt = good;
  corrupt.back() ^= 0x80;
  ASSERT_TRUE(write_file(temporary.path(), corrupt));
  EXPECT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kChecksum));
}

TEST(GlassHandoffTest, RejectsStaleBootAndConfigurationMismatches) {
  TempBundlePath temporary;
  const GlassHandoffBundle source = mono_bundle();
  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  GlassHandoffBundle loaded;

  GlassHandoffClock stale = shortly_after(source);
  stale.boottime_ns +=
      static_cast<std::uint64_t>(kGlassHandoffMaxAgeSec) * 1'000'000'000ull;
  EXPECT_EQ(
      static_cast<int>(glass_handoff_load(temporary.lease(), temporary.path(),
                                          source.identity, stale, &loaded)),
      static_cast<int>(GlassHandoffReject::kAge));

  GlassHandoffClock other_boot = shortly_after(source);
  other_boot.boot_id_hash ^= 1;
  EXPECT_EQ(static_cast<int>(
                glass_handoff_load(temporary.lease(), temporary.path(),
                                   source.identity, other_boot, &loaded)),
            static_cast<int>(GlassHandoffReject::kAge));

  GlassHandoffIdentity mismatch = source.identity;
  mismatch.pipeline_hash ^= 1;
  EXPECT_EQ(static_cast<int>(
                glass_handoff_load(temporary.lease(), temporary.path(),
                                   mismatch, shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kPipeline));
  mismatch = source.identity;
  mismatch.waveform_hash ^= 1;
  EXPECT_EQ(static_cast<int>(
                glass_handoff_load(temporary.lease(), temporary.path(),
                                   mismatch, shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kWaveform));
  mismatch = source.identity;
  mismatch.pixel_format = 0;
  EXPECT_EQ(static_cast<int>(
                glass_handoff_load(temporary.lease(), temporary.path(),
                                   mismatch, shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kPixelFormat));
  mismatch = source.identity;
  mismatch.width = 16;
  mismatch.engine_stride = 16;
  EXPECT_EQ(static_cast<int>(
                glass_handoff_load(temporary.lease(), temporary.path(),
                                   mismatch, shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kGeometry));
}

TEST(GlassHandoffTest, ExactMoveProfilePreservesFullHistoryWords) {
  TempBundlePath temporary;
  GlassHandoffBundle source;
  source.identity.flags = kGlassHandoffFlagExactColor;
  source.identity.profile = GlassHandoffProfile::kXochitlGallery3Move;
  source.identity.width = 954;
  source.identity.height = 1696;
  source.identity.pixel_format = 0; // kPlutoPixelFormatRgb565
  source.identity.engine_stride = 960;
  source.identity.tile_px = 32;
  source.identity.history_stride = 968;
  source.identity.history_rows = 1698;
  source.identity.history_pixel_bytes = 4;
  source.identity.waveform_hash = 0x1234;
  source.identity.waveform_bytes = 8192;
  source.identity.ct33_hash = 0x5678;
  source.identity.ct33_bytes = 4096;
  source.identity.pipeline_hash = 0x9abc;
  source.renderer = {.width = 954,
                     .height = 1696,
                     .rotation = 0,
                     .pixel_format = 0,
                     .configuration_hash = 0xdef0};
  source.written = {.realtime_sec = 20'000,
                    .boottime_ns = 3'000'000'000ull,
                    .boot_id_hash = 0x42};
  const std::size_t plane = 960u * 1696u;
  const std::size_t tiles = ((954u + 31u) / 32u) * ((1696u + 31u) / 32u);
  source.core.engine_dc.assign(plane, 0);
  source.core.engine_stress.assign(tiles, 0);
  source.core.engine_rescan.assign(tiles, 0);
  source.core.xochitl_history_ab.assign(968u * 1698u * 2u, 0);
  // Equal visible A level (17) but distinct flags and B development history.
  source.core.xochitl_history_ab[0] = 17u | 0x40u;
  source.core.xochitl_history_ab[1] = 0x0123u;
  source.core.xochitl_history_ab[2] = 17u | 0x80u;
  source.core.xochitl_history_ab[3] = 0xfedcu;
  source.renderer_payload = {1, 2, 3, 4};

  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  const std::vector<std::uint8_t> wire = read_file(temporary.path());
  // Color has no level plane, so history is the fourth directory entry.
  constexpr std::size_t kHistoryDirectory = 192u + 3u * 32u;
  ASSERT_GT(wire.size(), kHistoryDirectory + 32u);
  EXPECT_EQ(wire[kHistoryDirectory], 5u);
  std::uint64_t history_offset = 0;
  for (unsigned shift = 0; shift < 64; shift += 8) {
    history_offset |=
        static_cast<std::uint64_t>(wire[kHistoryDirectory + 8u + shift / 8u])
        << shift;
  }
  ASSERT_GT(wire.size(), static_cast<std::size_t>(history_offset + 7u));
  // Explicit little-endian {A0,B0,A1,B1}; never a native struct dump.
  EXPECT_EQ(wire[history_offset], 0x51u);
  EXPECT_EQ(wire[history_offset + 1u], 0x00u);
  EXPECT_EQ(wire[history_offset + 2u], 0x23u);
  EXPECT_EQ(wire[history_offset + 3u], 0x01u);
  EXPECT_EQ(wire[history_offset + 4u], 0x91u);
  EXPECT_EQ(wire[history_offset + 5u], 0x00u);
  EXPECT_EQ(wire[history_offset + 6u], 0xdcu);
  EXPECT_EQ(wire[history_offset + 7u], 0xfeu);
  GlassHandoffBundle loaded;
  ASSERT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kNone));
  EXPECT_EQ(loaded.core.xochitl_history_ab[0], 17u | 0x40u);
  EXPECT_EQ(loaded.core.xochitl_history_ab[1], 0x0123u);
  EXPECT_EQ(loaded.core.xochitl_history_ab[2], 17u | 0x80u);
  EXPECT_EQ(loaded.core.xochitl_history_ab[3], 0xfedcu);

  GlassHandoffIdentity mismatched_ct33 = source.identity;
  mismatched_ct33.ct33_hash ^= 1u;
  EXPECT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), mismatched_ct33,
                shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kCt33));
  mismatched_ct33 = source.identity;
  ++mismatched_ct33.ct33_bytes;
  EXPECT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), mismatched_ct33,
                shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kCt33));

  GlassHandoffBundle wrong_profile = source;
  wrong_profile.identity.width = 960;
  EXPECT_FALSE(
      glass_handoff_save(temporary.lease(), temporary.path(), wrong_profile));
}

TEST(GlassHandoffTest, FailedReplacementKeepsTheLastAtomicFinal) {
  TempBundlePath temporary;
  const GlassHandoffBundle source = mono_bundle();
  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));

  GlassHandoffBundle incomplete = source;
  incomplete.renderer_payload.clear();
  EXPECT_FALSE(
      glass_handoff_save(temporary.lease(), temporary.path(), incomplete));
  EXPECT_FALSE(std::filesystem::exists(temporary.path() + ".tmp"));

  GlassHandoffBundle loaded;
  EXPECT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kNone));
  EXPECT_TRUE(loaded.renderer_payload == source.renderer_payload);

  ASSERT_TRUE(write_file(temporary.path() + ".tmp", {1, 2, 3}));
  EXPECT_TRUE(glass_handoff_discard(temporary.lease(), temporary.path()));
  EXPECT_FALSE(std::filesystem::exists(temporary.path()));
  EXPECT_FALSE(std::filesystem::exists(temporary.path() + ".tmp"));
}

TEST(GlassHandoffTest, UniqueWriterNeverTruncatesTheCanonicalLegacyTemp) {
  TempBundlePath temporary;
  const GlassHandoffBundle source = mono_bundle();
  const std::vector<std::uint8_t> sentinel = {0xde, 0xad, 0xbe, 0xef};
  ASSERT_TRUE(write_file(temporary.path() + ".tmp", sentinel));

  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  EXPECT_TRUE(read_file(temporary.path() + ".tmp") == sentinel);

  GlassHandoffBundle loaded;
  EXPECT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), source.identity,
                shortly_after(source), &loaded)),
            static_cast<int>(GlassHandoffReject::kNone));
  EXPECT_TRUE(glass_handoff_discard(temporary.lease(), temporary.path()));
  EXPECT_FALSE(std::filesystem::exists(temporary.path()));
  EXPECT_FALSE(std::filesystem::exists(temporary.path() + ".tmp"));
}

TEST(GlassHandoffTest, ReclaimsOnlyOldPrivateWriterAndClaimFiles) {
  TempBundlePath temporary;
  const GlassHandoffBundle source = mono_bundle();
  const std::string stale = temporary.path() + ".tmp.2468.1";
  const std::string recent = temporary.path() + ".tmp.2468.2";
  const std::string foreign_name = temporary.path() + ".tmp.worker.3";
  const std::string foreign_mode = temporary.path() + ".tmp.2468.4";
  const std::string stale_claim = temporary.path() + ".claim.2468.5";
  const std::string recent_claim = temporary.path() + ".claim.2468.6";
  const std::string malformed_claim = temporary.path() + ".claim.worker.7";
  const std::string foreign_claim_mode = temporary.path() + ".claim.2468.8";
  ASSERT_TRUE(write_file(stale, {1, 2, 3}));
  ASSERT_TRUE(write_file(recent, {4, 5, 6}));
  ASSERT_TRUE(write_file(foreign_name, {7, 8, 9}));
  ASSERT_TRUE(write_file(foreign_mode, {10, 11, 12}));
  ASSERT_TRUE(write_file(stale_claim, {13, 14, 15}));
  ASSERT_TRUE(write_file(recent_claim, {16, 17, 18}));
  ASSERT_TRUE(write_file(malformed_claim, {19, 20, 21}));
  ASSERT_TRUE(write_file(foreign_claim_mode, {22, 23, 24}));
  ASSERT_EQ(::chmod(foreign_mode.c_str(), 0644), 0);
  ASSERT_EQ(::chmod(foreign_claim_mode.c_str(), 0644), 0);
  ASSERT_TRUE(set_file_age(stale, kGlassHandoffMaxAgeSec + 2));
  ASSERT_TRUE(set_file_age(foreign_name, kGlassHandoffMaxAgeSec + 2));
  ASSERT_TRUE(set_file_age(foreign_mode, kGlassHandoffMaxAgeSec + 2));
  ASSERT_TRUE(set_file_age(stale_claim, kGlassHandoffMaxAgeSec + 2));
  ASSERT_TRUE(set_file_age(malformed_claim, kGlassHandoffMaxAgeSec + 2));
  ASSERT_TRUE(set_file_age(foreign_claim_mode, kGlassHandoffMaxAgeSec + 2));

  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), source));
  EXPECT_FALSE(std::filesystem::exists(stale));
  EXPECT_FALSE(std::filesystem::exists(stale_claim));
  EXPECT_TRUE(std::filesystem::exists(recent));
  EXPECT_TRUE(std::filesystem::exists(foreign_name));
  EXPECT_TRUE(std::filesystem::exists(foreign_mode));
  EXPECT_TRUE(std::filesystem::exists(recent_claim));
  EXPECT_TRUE(std::filesystem::exists(malformed_claim));
  EXPECT_TRUE(std::filesystem::exists(foreign_claim_mode));

  (void)::unlink(recent.c_str());
  (void)::unlink(foreign_name.c_str());
  (void)::unlink(foreign_mode.c_str());
  (void)::unlink(recent_claim.c_str());
  (void)::unlink(malformed_claim.c_str());
  (void)::unlink(foreign_claim_mode.c_str());
}

TEST(GlassHandoffTest, LastAdmissibleChainLoadsButCannotBeRestaged) {
  TempBundlePath temporary;
  GlassHandoffBundle last = mono_bundle();
  last.chain = kGlassHandoffMaxChain - 1u;
  ASSERT_TRUE(glass_handoff_save(temporary.lease(), temporary.path(), last));

  GlassHandoffBundle loaded;
  ASSERT_EQ(static_cast<int>(glass_handoff_load(temporary.lease(),
                                                temporary.path(), last.identity,
                                                shortly_after(last), &loaded)),
            static_cast<int>(GlassHandoffReject::kNone));
  EXPECT_EQ(loaded.chain, kGlassHandoffMaxChain - 1u);

  // The incoming process may consume chain 7 exactly once, but incrementing
  // it for another warm owner would publish forbidden chain 8. Refusal must
  // leave the prior atomic final intact so the caller can explicitly unlink
  // it and take the conservative cold path.
  loaded.chain += 1u;
  EXPECT_FALSE(glass_handoff_save(temporary.lease(), temporary.path(), loaded));
  GlassHandoffBundle still_last;
  ASSERT_EQ(static_cast<int>(glass_handoff_load(
                temporary.lease(), temporary.path(), last.identity,
                shortly_after(last), &still_last)),
            static_cast<int>(GlassHandoffReject::kNone));
  EXPECT_EQ(still_last.chain, kGlassHandoffMaxChain - 1u);
}

} // namespace
} // namespace pluto
