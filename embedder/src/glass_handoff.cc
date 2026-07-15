#include "pluto/glass_handoff.h"

#include <dirent.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <bit>
#include <cerrno>
#include <climits>
#include <cstring>
#include <filesystem>
#include <limits>
#include <string_view>
#include <utility>

namespace pluto {
namespace {

constexpr std::size_t kBaseHeaderBytes = 192;
constexpr std::size_t kSectionEntryBytes = 32;
constexpr std::uint32_t kKnownFlags = kGlassHandoffFlagExactColor;
constexpr std::uint32_t kEndianMarker = 0x01020304u;
constexpr std::size_t kWireScratchBytes = 16u * 1024u;
constexpr std::size_t kIoChunkBytes = 64u * 1024u;
constexpr std::uint64_t kMaximumRendererPayloadBytes = 64ull << 20;
constexpr std::uint64_t kCrc64Polynomial = 0x42f0e1eba9ea3693ull;
constexpr std::size_t kHeaderChecksumOffset = 184;
constexpr unsigned kUniqueNameAttempts = 128;

std::atomic<std::uint64_t> g_unique_name_sequence{0};

using Crc64Tables = std::array<std::array<std::uint64_t, 256>, 8>;

constexpr Crc64Tables make_crc64_tables() {
  Crc64Tables tables{};
  for (std::size_t index = 0; index < tables[0].size(); ++index) {
    std::uint64_t crc = static_cast<std::uint64_t>(index) << 56u;
    for (int bit = 0; bit < 8; ++bit) {
      crc = (crc & (1ull << 63u)) != 0 ? (crc << 1u) ^ kCrc64Polynomial
                                       : crc << 1u;
    }
    tables[0][index] = crc;
  }
  for (std::size_t slice = 1; slice < tables.size(); ++slice) {
    for (std::size_t index = 0; index < tables[slice].size(); ++index) {
      const std::uint64_t previous = tables[slice - 1u][index];
      tables[slice][index] = (previous << 8u) ^ tables[0][previous >> 56u];
    }
  }
  return tables;
}

constexpr auto kCrc64Tables = make_crc64_tables();

std::uint64_t load_be64(const std::uint8_t *bytes) {
  std::uint64_t word = 0;
  std::memcpy(&word, bytes, sizeof(word));
  if constexpr (std::endian::native == std::endian::little) {
#if defined(__clang__) || defined(__GNUC__)
    return __builtin_bswap64(word);
#else
    return ((word & 0x00000000000000ffull) << 56u) |
           ((word & 0x000000000000ff00ull) << 40u) |
           ((word & 0x0000000000ff0000ull) << 24u) |
           ((word & 0x00000000ff000000ull) << 8u) |
           ((word & 0x000000ff00000000ull) >> 8u) |
           ((word & 0x0000ff0000000000ull) >> 24u) |
           ((word & 0x00ff000000000000ull) >> 40u) |
           ((word & 0xff00000000000000ull) >> 56u);
#endif
  }
  return word;
}

std::uint64_t crc64_advance_eight(std::uint64_t mixed) {
  return kCrc64Tables[7][(mixed >> 56u) & 0xffu] ^
         kCrc64Tables[6][(mixed >> 48u) & 0xffu] ^
         kCrc64Tables[5][(mixed >> 40u) & 0xffu] ^
         kCrc64Tables[4][(mixed >> 32u) & 0xffu] ^
         kCrc64Tables[3][(mixed >> 24u) & 0xffu] ^
         kCrc64Tables[2][(mixed >> 16u) & 0xffu] ^
         kCrc64Tables[1][(mixed >> 8u) & 0xffu] ^
         kCrc64Tables[0][mixed & 0xffu];
}

std::uint64_t crc64_update(std::span<const std::uint8_t> bytes,
                           std::uint64_t crc) {
  const std::uint8_t *cursor = bytes.data();
  std::size_t remaining = bytes.size();
  while (remaining >= 8u) {
    crc = crc64_advance_eight(crc ^ load_be64(cursor));
    cursor += 8u;
    remaining -= 8u;
  }
  while (remaining != 0u) {
    crc = kCrc64Tables[0][static_cast<std::uint8_t>((crc >> 56u) ^ *cursor++)] ^
          (crc << 8u);
    --remaining;
  }
  return crc;
}

struct SectionView {
  GlassHandoffSection type = GlassHandoffSection::kEngineLevels;
  std::uint64_t offset = 0;
  std::uint64_t size = 0;
  std::uint64_t checksum = 0;
};

struct WireHeader {
  GlassHandoffIdentity identity;
  GlassHandoffRendererInfo renderer;
  GlassHandoffClock written;
  std::int32_t engine_temperature_bin = 0;
  std::int32_t admission_temperature_bin = 0;
  std::uint32_t chain = 0;
  std::uint32_t section_count = 0;
  std::uint64_t total_bytes = 0;
  std::uint64_t payload_checksum = 0;
  std::uint64_t header_checksum = 0;
  std::uint32_t header_bytes = 0;
};

class ScopedFd {
public:
  explicit ScopedFd(int fd) : fd_(fd) {}
  ScopedFd(const ScopedFd &) = delete;
  ScopedFd &operator=(const ScopedFd &) = delete;
  ~ScopedFd() {
    if (fd_ >= 0) {
      (void)::close(fd_);
    }
  }

  int get() const { return fd_; }
  bool close_checked() {
    if (fd_ < 0) {
      return true;
    }
    const int fd = std::exchange(fd_, -1);
    return ::close(fd) == 0;
  }

private:
  int fd_ = -1;
};

bool private_regular_file(const struct stat &status) {
  return S_ISREG(status.st_mode) && status.st_nlink == 1 &&
         status.st_uid == ::geteuid() &&
         (status.st_mode & 07777) == (S_IRUSR | S_IWUSR);
}

std::pair<std::int64_t, std::int64_t> modified_time(const struct stat &status) {
#if defined(__APPLE__)
  return {static_cast<std::int64_t>(status.st_mtimespec.tv_sec),
          static_cast<std::int64_t>(status.st_mtimespec.tv_nsec)};
#else
  return {static_cast<std::int64_t>(status.st_mtim.tv_sec),
          static_cast<std::int64_t>(status.st_mtim.tv_nsec)};
#endif
}

bool same_loaded_inode(const struct stat &before, const struct stat &after) {
  return private_regular_file(after) && after.st_size >= 0 &&
         before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
         before.st_size == after.st_size &&
         modified_time(before) == modified_time(after);
}

GlassHandoffClaim make_claim(const struct stat &status,
                             std::uint64_t header_checksum) {
  const auto modified = modified_time(status);
  GlassHandoffClaim claim;
  claim.valid = true;
  claim.device = static_cast<std::uint64_t>(status.st_dev);
  claim.inode = static_cast<std::uint64_t>(status.st_ino);
  claim.file_bytes = static_cast<std::uint64_t>(status.st_size);
  claim.header_checksum = header_checksum;
  claim.modified_sec = modified.first;
  claim.modified_nsec = modified.second;
  return claim;
}

bool stat_matches_claim(const struct stat &status,
                        const GlassHandoffClaim &claim) {
  const auto modified = modified_time(status);
  return claim.valid && private_regular_file(status) && status.st_size >= 0 &&
         static_cast<std::uint64_t>(status.st_dev) == claim.device &&
         static_cast<std::uint64_t>(status.st_ino) == claim.inode &&
         static_cast<std::uint64_t>(status.st_size) == claim.file_bytes &&
         modified.first == claim.modified_sec &&
         modified.second == claim.modified_nsec;
}

int create_unique_private_file(const std::string &path, std::string_view tag,
                               int access_flags, std::string *created_path) {
  if (created_path == nullptr) {
    errno = EINVAL;
    return -1;
  }
  created_path->clear();
  for (unsigned attempt = 0; attempt < kUniqueNameAttempts; ++attempt) {
    const std::uint64_t sequence =
        g_unique_name_sequence.fetch_add(1, std::memory_order_relaxed) + 1u;
    std::string candidate = path;
    candidate.push_back('.');
    candidate.append(tag);
    candidate.push_back('.');
    candidate.append(std::to_string(static_cast<long long>(::getpid())));
    candidate.push_back('.');
    candidate.append(std::to_string(sequence));
    const int fd =
        ::open(candidate.c_str(),
               access_flags | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
               S_IRUSR | S_IWUSR);
    if (fd < 0) {
      if (errno == EEXIST) {
        continue;
      }
      return -1;
    }
    struct stat status {};
    if (::fchmod(fd, S_IRUSR | S_IWUSR) != 0 || ::fstat(fd, &status) != 0 ||
        !private_regular_file(status) || status.st_size != 0) {
      const int saved = errno == 0 ? EPERM : errno;
      (void)::close(fd);
      (void)::unlink(candidate.c_str());
      errno = saved;
      return -1;
    }
    *created_path = std::move(candidate);
    return fd;
  }
  errno = EEXIST;
  return -1;
}

bool checked_add(std::uint64_t a, std::uint64_t b, std::uint64_t *out) {
  if (out == nullptr || b > std::numeric_limits<std::uint64_t>::max() - a) {
    return false;
  }
  *out = a + b;
  return true;
}

bool checked_mul(std::uint64_t a, std::uint64_t b, std::uint64_t *out) {
  if (out == nullptr ||
      (a != 0 && b > std::numeric_limits<std::uint64_t>::max() / a)) {
    return false;
  }
  *out = a * b;
  return true;
}

void put_u32(std::span<std::uint8_t> bytes, std::size_t *cursor,
             std::uint32_t value) {
  for (unsigned shift = 0; shift < 32; shift += 8) {
    bytes[(*cursor)++] = static_cast<std::uint8_t>(value >> shift);
  }
}

void put_i32(std::span<std::uint8_t> bytes, std::size_t *cursor,
             std::int32_t value) {
  put_u32(bytes, cursor, static_cast<std::uint32_t>(value));
}

void put_u64(std::span<std::uint8_t> bytes, std::size_t *cursor,
             std::uint64_t value) {
  for (unsigned shift = 0; shift < 64; shift += 8) {
    bytes[(*cursor)++] = static_cast<std::uint8_t>(value >> shift);
  }
}

bool get_u32(std::span<const std::uint8_t> bytes, std::size_t *cursor,
             std::uint32_t *value) {
  if (cursor == nullptr || value == nullptr || *cursor > bytes.size() ||
      bytes.size() - *cursor < 4) {
    return false;
  }
  std::uint32_t result = 0;
  for (unsigned shift = 0; shift < 32; shift += 8) {
    result |= static_cast<std::uint32_t>(bytes[(*cursor)++]) << shift;
  }
  *value = result;
  return true;
}

bool get_i32(std::span<const std::uint8_t> bytes, std::size_t *cursor,
             std::int32_t *value) {
  std::uint32_t raw = 0;
  if (!get_u32(bytes, cursor, &raw)) {
    return false;
  }
  *value = static_cast<std::int32_t>(raw);
  return true;
}

bool get_u64(std::span<const std::uint8_t> bytes, std::size_t *cursor,
             std::uint64_t *value) {
  if (cursor == nullptr || value == nullptr || *cursor > bytes.size() ||
      bytes.size() - *cursor < 8) {
    return false;
  }
  std::uint64_t result = 0;
  for (unsigned shift = 0; shift < 64; shift += 8) {
    result |= static_cast<std::uint64_t>(bytes[(*cursor)++]) << shift;
  }
  *value = result;
  return true;
}

std::vector<std::uint8_t> encode_header(const WireHeader &header,
                                        std::span<const SectionView> sections,
                                        bool include_header_checksum) {
  std::vector<std::uint8_t> bytes(header.header_bytes, 0);
  std::size_t cursor = 0;
  put_u32(bytes, &cursor, kGlassHandoffMagic);
  put_u32(bytes, &cursor, kGlassHandoffVersion);
  put_u32(bytes, &cursor, header.header_bytes);
  put_u32(bytes, &cursor, kEndianMarker);
  put_u32(bytes, &cursor, header.identity.flags);
  put_u32(bytes, &cursor, static_cast<std::uint32_t>(header.identity.profile));
  put_u32(bytes, &cursor, header.section_count);
  put_u32(bytes, &cursor, header.chain);
  put_u32(bytes, &cursor, header.identity.width);
  put_u32(bytes, &cursor, header.identity.height);
  put_u32(bytes, &cursor, header.identity.pixel_format);
  put_u32(bytes, &cursor, header.identity.engine_stride);
  put_u32(bytes, &cursor, header.identity.tile_px);
  const std::uint32_t tile_cols =
      (header.identity.width + header.identity.tile_px - 1u) /
      header.identity.tile_px;
  const std::uint32_t tile_rows =
      (header.identity.height + header.identity.tile_px - 1u) /
      header.identity.tile_px;
  put_u32(bytes, &cursor, tile_cols);
  put_u32(bytes, &cursor, tile_rows);
  put_u32(bytes, &cursor, header.identity.history_stride);
  put_u32(bytes, &cursor, header.identity.history_rows);
  put_u32(bytes, &cursor, header.identity.history_pixel_bytes);
  put_i32(bytes, &cursor, header.engine_temperature_bin);
  put_i32(bytes, &cursor, header.admission_temperature_bin);
  put_u32(bytes, &cursor, header.renderer.width);
  put_u32(bytes, &cursor, header.renderer.height);
  put_u32(bytes, &cursor, header.renderer.rotation);
  put_u32(bytes, &cursor, header.renderer.pixel_format);
  put_u64(bytes, &cursor,
          static_cast<std::uint64_t>(header.written.realtime_sec));
  put_u64(bytes, &cursor, header.written.boottime_ns);
  put_u64(bytes, &cursor, header.written.boot_id_hash);
  put_u64(bytes, &cursor, header.identity.waveform_hash);
  put_u64(bytes, &cursor, header.identity.waveform_bytes);
  put_u64(bytes, &cursor, header.identity.ct33_hash);
  put_u64(bytes, &cursor, header.identity.ct33_bytes);
  put_u64(bytes, &cursor, header.identity.pipeline_hash);
  put_u64(bytes, &cursor, header.renderer.configuration_hash);
  put_u64(bytes, &cursor, header.total_bytes);
  put_u64(bytes, &cursor, header.payload_checksum);
  put_u64(bytes, &cursor,
          include_header_checksum ? header.header_checksum : 0u);
  // The base header has reserved zero bytes through kBaseHeaderBytes.
  cursor = kBaseHeaderBytes;
  for (const SectionView &section : sections) {
    put_u32(bytes, &cursor, static_cast<std::uint32_t>(section.type));
    put_u32(bytes, &cursor, 0); // section flags, none in schema 2
    put_u64(bytes, &cursor, section.offset);
    put_u64(bytes, &cursor, section.size);
    put_u64(bytes, &cursor, section.checksum);
  }
  return bytes;
}

enum class ReadStatus : std::uint8_t { kOk, kPartial, kIo, kChecksum };

ReadStatus pread_exact(int fd, std::span<std::uint8_t> out,
                       std::uint64_t offset) {
  std::size_t done = 0;
  while (done < out.size()) {
    if (offset + done >
        static_cast<std::uint64_t>(std::numeric_limits<off_t>::max())) {
      return ReadStatus::kIo;
    }
    const ssize_t count =
        ::pread(fd, out.data() + done, static_cast<size_t>(out.size() - done),
                static_cast<off_t>(offset + done));
    if (count > 0) {
      done += static_cast<std::size_t>(count);
      continue;
    }
    if (count == 0) {
      return ReadStatus::kPartial;
    }
    if (count < 0 && errno == EINTR) {
      continue;
    }
    return ReadStatus::kIo;
  }
  return ReadStatus::kOk;
}

bool claim_header_matches(int fd, const GlassHandoffClaim &claim) {
  if (!claim.valid || claim.file_bytes < kBaseHeaderBytes) {
    return false;
  }
  std::array<std::uint8_t, kBaseHeaderBytes> base{};
  if (pread_exact(fd, base, 0) != ReadStatus::kOk) {
    return false;
  }
  std::span<const std::uint8_t> bytes(base);
  std::size_t cursor = 0;
  std::uint32_t magic = 0;
  std::uint32_t version = 0;
  std::uint32_t header_bytes = 0;
  std::uint32_t endian = 0;
  if (!get_u32(bytes, &cursor, &magic) || !get_u32(bytes, &cursor, &version) ||
      !get_u32(bytes, &cursor, &header_bytes) ||
      !get_u32(bytes, &cursor, &endian) || magic != kGlassHandoffMagic ||
      version != kGlassHandoffVersion || endian != kEndianMarker ||
      header_bytes < kBaseHeaderBytes || header_bytes > claim.file_bytes ||
      header_bytes > kBaseHeaderBytes + 16u * kSectionEntryBytes ||
      (header_bytes - kBaseHeaderBytes) % kSectionEntryBytes != 0) {
    return false;
  }
  std::vector<std::uint8_t> header(header_bytes);
  std::memcpy(header.data(), base.data(), base.size());
  if (header.size() > base.size() &&
      pread_exact(fd, std::span<std::uint8_t>(header).subspan(base.size()),
                  base.size()) != ReadStatus::kOk) {
    return false;
  }
  cursor = kHeaderChecksumOffset;
  std::uint64_t encoded_checksum = 0;
  if (!get_u64(header, &cursor, &encoded_checksum) ||
      encoded_checksum != claim.header_checksum) {
    return false;
  }
  std::memset(header.data() + kHeaderChecksumOffset, 0, sizeof(std::uint64_t));
  return glass_handoff_crc64(header) == encoded_checksum;
}

bool write_exact(int fd, std::span<const std::uint8_t> bytes) {
  std::size_t done = 0;
  while (done < bytes.size()) {
    const ssize_t count = ::write(fd, bytes.data() + done,
                                  static_cast<size_t>(bytes.size() - done));
    if (count > 0) {
      done += static_cast<std::size_t>(count);
      continue;
    }
    if (count < 0 && errno == EINTR) {
      continue;
    }
    return false;
  }
  return true;
}

bool pwrite_exact(int fd, std::span<const std::uint8_t> bytes,
                  std::uint64_t offset) {
  std::size_t done = 0;
  while (done < bytes.size()) {
    if (offset + done >
        static_cast<std::uint64_t>(std::numeric_limits<off_t>::max())) {
      errno = EOVERFLOW;
      return false;
    }
    const ssize_t count = ::pwrite(fd, bytes.data() + done,
                                   static_cast<size_t>(bytes.size() - done),
                                   static_cast<off_t>(offset + done));
    if (count > 0) {
      done += static_cast<std::size_t>(count);
      continue;
    }
    if (count < 0 && errno == EINTR) {
      continue;
    }
    return false;
  }
  return true;
}

enum class PayloadEncoding : std::uint8_t { kBytes, kU16, kI32 };

struct PayloadView {
  GlassHandoffSection type = GlassHandoffSection::kEngineLevels;
  PayloadEncoding encoding = PayloadEncoding::kBytes;
  const void *data = nullptr;
  std::size_t element_count = 0;

  std::uint64_t byte_size() const {
    switch (encoding) {
    case PayloadEncoding::kBytes:
      return element_count;
    case PayloadEncoding::kU16:
      return static_cast<std::uint64_t>(element_count) * 2u;
    case PayloadEncoding::kI32:
      return static_cast<std::uint64_t>(element_count) * 4u;
    }
    return 0;
  }
};

void update_crc_pair(std::span<const std::uint8_t> bytes,
                     std::uint64_t *section_crc, std::uint64_t *payload_crc) {
  std::uint64_t section = *section_crc;
  std::uint64_t payload = *payload_crc;
  const std::uint8_t *cursor = bytes.data();
  std::size_t remaining = bytes.size();
  while (remaining >= 8u) {
    const std::uint64_t word = load_be64(cursor);
    section = crc64_advance_eight(section ^ word);
    payload = crc64_advance_eight(payload ^ word);
    cursor += 8u;
    remaining -= 8u;
  }
  while (remaining != 0u) {
    const std::uint8_t byte = *cursor++;
    section =
        kCrc64Tables[0][static_cast<std::uint8_t>((section >> 56u) ^ byte)] ^
        (section << 8u);
    payload =
        kCrc64Tables[0][static_cast<std::uint8_t>((payload >> 56u) ^ byte)] ^
        (payload << 8u);
    --remaining;
  }
  *section_crc = section;
  *payload_crc = payload;
}

GlassHandoffReject reject_for_read(ReadStatus status) {
  switch (status) {
  case ReadStatus::kOk:
    return GlassHandoffReject::kNone;
  case ReadStatus::kPartial:
    return GlassHandoffReject::kPartial;
  case ReadStatus::kIo:
    return GlassHandoffReject::kIo;
  case ReadStatus::kChecksum:
    return GlassHandoffReject::kChecksum;
  }
  return GlassHandoffReject::kIo;
}

ReadStatus read_byte_section(int fd, const SectionView &section,
                             std::span<std::uint8_t> destination,
                             std::uint64_t *payload_crc) {
  if (destination.size() != section.size || payload_crc == nullptr) {
    return ReadStatus::kIo;
  }
  std::size_t consumed = 0;
  std::uint64_t section_crc = 0;
  while (consumed < destination.size()) {
    const std::size_t count =
        std::min(destination.size() - consumed, kIoChunkBytes);
    const std::span<std::uint8_t> chunk = destination.subspan(consumed, count);
    const ReadStatus read = pread_exact(fd, chunk, section.offset + consumed);
    if (read != ReadStatus::kOk) {
      return read;
    }
    // Hash while the just-read cache lines are still hot. This avoids a
    // second full DRAM pass over multi-megabyte history/renderer sections on
    // Chiappa's Cortex-A55 cores.
    update_crc_pair(chunk, &section_crc, payload_crc);
    consumed += count;
  }
  return section_crc == section.checksum ? ReadStatus::kOk
                                         : ReadStatus::kChecksum;
}

bool write_byte_payload(int fd, std::span<const std::uint8_t> bytes,
                        std::uint64_t *section_crc,
                        std::uint64_t *payload_crc) {
  std::size_t consumed = 0;
  while (consumed < bytes.size()) {
    const std::size_t count = std::min(bytes.size() - consumed, kIoChunkBytes);
    const std::span<const std::uint8_t> chunk = bytes.subspan(consumed, count);
    // Keep the source cache-hot for the immediately following kernel copy.
    update_crc_pair(chunk, section_crc, payload_crc);
    if (!write_exact(fd, chunk)) {
      return false;
    }
    consumed += count;
  }
  return true;
}

ReadStatus read_u16_section(int fd, const SectionView &section,
                            std::vector<std::uint16_t> *destination,
                            std::uint64_t *payload_crc) {
  if (destination == nullptr || payload_crc == nullptr ||
      (section.size & 1u) != 0 ||
      section.size / 2u > std::numeric_limits<std::size_t>::max()) {
    return ReadStatus::kIo;
  }
  destination->resize(static_cast<std::size_t>(section.size / 2u));
  if constexpr (std::endian::native == std::endian::little) {
    return read_byte_section(
        fd, section,
        std::span<std::uint8_t>(
            reinterpret_cast<std::uint8_t *>(destination->data()),
            static_cast<std::size_t>(section.size)),
        payload_crc);
  }

  std::array<std::uint8_t, kWireScratchBytes> scratch{};
  std::size_t consumed = 0;
  std::uint64_t section_crc = 0;
  while (consumed < destination->size()) {
    const std::size_t count =
        std::min(destination->size() - consumed, scratch.size() / 2u);
    const std::size_t byte_count = count * 2u;
    const ReadStatus read =
        pread_exact(fd, std::span<std::uint8_t>(scratch.data(), byte_count),
                    section.offset + consumed * 2u);
    if (read != ReadStatus::kOk) {
      return read;
    }
    const std::span<const std::uint8_t> bytes(scratch.data(), byte_count);
    update_crc_pair(bytes, &section_crc, payload_crc);
    for (std::size_t i = 0; i < count; ++i) {
      (*destination)[consumed + i] =
          static_cast<std::uint16_t>(scratch[i * 2u]) |
          static_cast<std::uint16_t>(scratch[i * 2u + 1u] << 8u);
    }
    consumed += count;
  }
  return section_crc == section.checksum ? ReadStatus::kOk
                                         : ReadStatus::kChecksum;
}

ReadStatus read_i32_section(int fd, const SectionView &section,
                            std::vector<std::int32_t> *destination,
                            std::uint64_t *payload_crc) {
  if (destination == nullptr || payload_crc == nullptr ||
      (section.size & 3u) != 0 ||
      section.size / 4u > std::numeric_limits<std::size_t>::max()) {
    return ReadStatus::kIo;
  }
  destination->resize(static_cast<std::size_t>(section.size / 4u));
  if constexpr (std::endian::native == std::endian::little) {
    return read_byte_section(
        fd, section,
        std::span<std::uint8_t>(
            reinterpret_cast<std::uint8_t *>(destination->data()),
            static_cast<std::size_t>(section.size)),
        payload_crc);
  }

  std::array<std::uint8_t, kWireScratchBytes> scratch{};
  std::size_t consumed = 0;
  std::uint64_t section_crc = 0;
  while (consumed < destination->size()) {
    const std::size_t count =
        std::min(destination->size() - consumed, scratch.size() / 4u);
    const std::size_t byte_count = count * 4u;
    const ReadStatus read =
        pread_exact(fd, std::span<std::uint8_t>(scratch.data(), byte_count),
                    section.offset + consumed * 4u);
    if (read != ReadStatus::kOk) {
      return read;
    }
    const std::span<const std::uint8_t> bytes(scratch.data(), byte_count);
    update_crc_pair(bytes, &section_crc, payload_crc);
    for (std::size_t i = 0; i < count; ++i) {
      const std::size_t cursor = i * 4u;
      const std::uint32_t value =
          static_cast<std::uint32_t>(scratch[cursor]) |
          (static_cast<std::uint32_t>(scratch[cursor + 1u]) << 8u) |
          (static_cast<std::uint32_t>(scratch[cursor + 2u]) << 16u) |
          (static_cast<std::uint32_t>(scratch[cursor + 3u]) << 24u);
      (*destination)[consumed + i] = static_cast<std::int32_t>(value);
    }
    consumed += count;
  }
  return section_crc == section.checksum ? ReadStatus::kOk
                                         : ReadStatus::kChecksum;
}

bool write_payload(int fd, const PayloadView &payload,
                   std::uint64_t *section_crc, std::uint64_t *payload_crc) {
  if (payload.data == nullptr || payload.element_count == 0 ||
      section_crc == nullptr || payload_crc == nullptr) {
    return false;
  }
  if (payload.encoding == PayloadEncoding::kBytes) {
    const auto bytes = std::span<const std::uint8_t>(
        static_cast<const std::uint8_t *>(payload.data), payload.element_count);
    return write_byte_payload(fd, bytes, section_crc, payload_crc);
  }

  if constexpr (std::endian::native == std::endian::little) {
    const std::size_t element_bytes =
        payload.encoding == PayloadEncoding::kU16 ? 2u : 4u;
    const auto bytes = std::span<const std::uint8_t>(
        static_cast<const std::uint8_t *>(payload.data),
        payload.element_count * element_bytes);
    return write_byte_payload(fd, bytes, section_crc, payload_crc);
  }

  std::array<std::uint8_t, kWireScratchBytes> scratch{};
  std::size_t consumed = 0;
  while (consumed < payload.element_count) {
    const std::size_t element_bytes =
        payload.encoding == PayloadEncoding::kU16 ? 2u : 4u;
    const std::size_t count = std::min(payload.element_count - consumed,
                                       scratch.size() / element_bytes);
    std::size_t cursor = 0;
    if (payload.encoding == PayloadEncoding::kU16) {
      const auto *values = static_cast<const std::uint16_t *>(payload.data);
      for (std::size_t i = 0; i < count; ++i) {
        const std::uint16_t value = values[consumed + i];
        scratch[cursor++] = static_cast<std::uint8_t>(value);
        scratch[cursor++] = static_cast<std::uint8_t>(value >> 8u);
      }
    } else {
      const auto *values = static_cast<const std::int32_t *>(payload.data);
      for (std::size_t i = 0; i < count; ++i) {
        const std::uint32_t value =
            static_cast<std::uint32_t>(values[consumed + i]);
        for (unsigned shift = 0; shift < 32; shift += 8) {
          scratch[cursor++] = static_cast<std::uint8_t>(value >> shift);
        }
      }
    }
    const std::span<const std::uint8_t> bytes(scratch.data(), cursor);
    update_crc_pair(bytes, section_crc, payload_crc);
    if (!write_exact(fd, bytes)) {
      return false;
    }
    consumed += count;
  }
  return true;
}

const SectionView *find_section(std::span<const SectionView> sections,
                                GlassHandoffSection type) {
  for (const SectionView &section : sections) {
    if (section.type == type) {
      return &section;
    }
  }
  return nullptr;
}

bool sync_parent_directory(const std::string &path) {
  const std::filesystem::path parent =
      std::filesystem::path(path).parent_path().empty()
          ? std::filesystem::path(".")
          : std::filesystem::path(path).parent_path();
#ifdef O_DIRECTORY
  const int fd = ::open(parent.c_str(), O_RDONLY | O_CLOEXEC | O_DIRECTORY);
#else
  const int fd = ::open(parent.c_str(), O_RDONLY | O_CLOEXEC);
#endif
  if (fd < 0) {
    return false;
  }
  const bool ok = ::fsync(fd) == 0 || errno == EINVAL || errno == ENOTSUP;
  const int saved = errno;
  (void)::close(fd);
  errno = saved;
  return ok;
}

bool decimal_name_component(std::string_view component) {
  if (component.empty() || component.front() == '0') {
    return false;
  }
  std::uint64_t value = 0;
  for (const char character : component) {
    if (character < '0' || character > '9') {
      return false;
    }
    const std::uint64_t digit = static_cast<unsigned>(character - '0');
    if (value > (std::numeric_limits<std::uint64_t>::max() - digit) / 10u) {
      return false;
    }
    value = value * 10u + digit;
  }
  return value != 0;
}

bool unique_private_name(std::string_view name, std::string_view basename,
                         std::string_view tag) {
  std::string prefix(basename);
  prefix.push_back('.');
  prefix.append(tag);
  prefix.push_back('.');
  if (!name.starts_with(prefix)) {
    return false;
  }
  const std::string_view suffix = name.substr(prefix.size());
  const std::size_t separator = suffix.find('.');
  return separator != std::string_view::npos &&
         suffix.find('.', separator + 1u) == std::string_view::npos &&
         decimal_name_component(suffix.substr(0, separator)) &&
         decimal_name_component(suffix.substr(separator + 1u));
}

bool stale_temporary(const struct stat &status, const timespec &now) {
  if (!private_regular_file(status) || status.st_size < 0 || now.tv_sec <= 0) {
    return false;
  }
  const auto modified = modified_time(status);
  if (modified.first <= 0 || modified.second < 0 ||
      modified.second >= 1'000'000'000 || now.tv_sec < modified.first) {
    return false;
  }
  const std::int64_t age_sec =
      static_cast<std::int64_t>(now.tv_sec) - modified.first;
  return age_sec > kGlassHandoffMaxAgeSec ||
         (age_sec == kGlassHandoffMaxAgeSec &&
          static_cast<std::int64_t>(now.tv_nsec) > modified.second);
}

void reclaim_stale_private_files(const std::string &path) {
  const std::filesystem::path final_path(path);
  const std::filesystem::path parent = final_path.parent_path().empty()
                                           ? std::filesystem::path(".")
                                           : final_path.parent_path();
  const std::string basename = final_path.filename().string();
  if (basename.empty()) {
    return;
  }
#ifdef O_DIRECTORY
  const int raw_directory =
      ::open(parent.c_str(), O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW);
#else
  const int raw_directory =
      ::open(parent.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
#endif
  if (raw_directory < 0) {
    return;
  }
  DIR *directory = ::fdopendir(raw_directory);
  if (directory == nullptr) {
    (void)::close(raw_directory);
    return;
  }
  timespec now{};
  if (::clock_gettime(CLOCK_REALTIME, &now) != 0) {
    (void)::closedir(directory);
    return;
  }

  bool removed = false;
  while (dirent *entry = ::readdir(directory)) {
    const std::string_view name(entry->d_name);
    if (!unique_private_name(name, basename, "tmp") &&
        !unique_private_name(name, basename, "claim")) {
      continue;
    }
    struct stat status {};
    if (::fstatat(raw_directory, entry->d_name, &status, AT_SYMLINK_NOFOLLOW) !=
            0 ||
        !stale_temporary(status, now)) {
      continue;
    }
    // Private names are O_EXCL and never reused. Once a matching inode has
    // remained untouched past the admission age, unlinking it is safe. An old
    // writer that still holds its fd subsequently fails its name-based rename;
    // an abandoned claim is already absent from the shared final name.
    removed = ::unlinkat(raw_directory, entry->d_name, 0) == 0 || removed;
  }
  if (removed) {
    (void)::fsync(raw_directory);
  }
  (void)::closedir(directory);
}

bool validate_identity_shape(const GlassHandoffIdentity &identity) {
  if ((identity.flags & ~kKnownFlags) != 0 || identity.width == 0 ||
      identity.height == 0 || identity.engine_stride < identity.width ||
      (identity.engine_stride % 8u) != 0 || identity.tile_px == 0) {
    return false;
  }
  const bool color = (identity.flags & kGlassHandoffFlagExactColor) != 0;
  if (color) {
    // This profile is intentionally exact, not a family resemblance test.
    // A future color panel must add a distinct profile with its own fixed
    // geometry so it can never consume the Move's Xochitl storage layout.
    return identity.profile == GlassHandoffProfile::kXochitlGallery3Move &&
           identity.width == 954u && identity.height == 1696u &&
           identity.pixel_format == 0u && // kPlutoPixelFormatRgb565
           identity.engine_stride == 960u && identity.tile_px == 32u &&
           identity.history_stride == 968u && identity.history_rows == 1698u &&
           identity.history_pixel_bytes == 4u && identity.ct33_bytes != 0;
  }
  return identity.profile == GlassHandoffProfile::kMonochrome &&
         identity.history_stride == 0 && identity.history_rows == 0 &&
         identity.history_pixel_bytes == 0 && identity.ct33_bytes == 0;
}

bool has_usable_written_clock(const GlassHandoffClock &clock) {
  if (clock.boot_id_hash != 0) {
    return clock.boottime_ns != 0;
  }
  return clock.realtime_sec > 0;
}

bool validate_core_sizes(const GlassHandoffBundle &bundle) {
  const GlassHandoffIdentity &id = bundle.identity;
  if (!validate_identity_shape(id) || bundle.renderer.width == 0 ||
      bundle.renderer.height == 0 || bundle.renderer_payload.empty() ||
      bundle.presenter_payload.size() > kGlassHandoffMaxPresenterPayloadBytes) {
    return false;
  }
  std::uint64_t plane = 0;
  if (!checked_mul(id.engine_stride, id.height, &plane)) {
    return false;
  }
  const std::uint64_t tile_cols =
      (static_cast<std::uint64_t>(id.width) + id.tile_px - 1u) / id.tile_px;
  const std::uint64_t tile_rows =
      (static_cast<std::uint64_t>(id.height) + id.tile_px - 1u) / id.tile_px;
  std::uint64_t tiles = 0;
  if (!checked_mul(tile_cols, tile_rows, &tiles) ||
      bundle.core.engine_dc.size() != plane ||
      bundle.core.engine_stress.size() != tiles ||
      bundle.core.engine_rescan.size() != tiles) {
    return false;
  }
  const bool color = (id.flags & kGlassHandoffFlagExactColor) != 0;
  if (!color) {
    return bundle.core.engine_levels.size() == plane &&
           bundle.core.xochitl_history_ab.empty();
  }
  std::uint64_t history_pixels = 0;
  return bundle.core.engine_levels.empty() &&
         checked_mul(id.history_stride, id.history_rows, &history_pixels) &&
         history_pixels <= std::numeric_limits<std::uint64_t>::max() / 2u &&
         bundle.core.xochitl_history_ab.size() == history_pixels * 2u;
}

} // namespace

GlassHandoffLease::~GlassHandoffLease() { reset(); }

GlassHandoffLease::GlassHandoffLease(GlassHandoffLease &&other) noexcept
    : fd_(std::exchange(other.fd_, -1)),
      owner_pid_(std::exchange(other.owner_pid_, 0)),
      path_(std::move(other.path_)) {
  other.path_.clear();
}

GlassHandoffLease &
GlassHandoffLease::operator=(GlassHandoffLease &&other) noexcept {
  if (this != &other) {
    reset();
    fd_ = std::exchange(other.fd_, -1);
    owner_pid_ = std::exchange(other.owner_pid_, 0);
    path_ = std::move(other.path_);
    other.path_.clear();
  }
  return *this;
}

void GlassHandoffLease::reset() noexcept {
  // flock locks follow the open file description across fork. Close only:
  // explicitly unlocking an inherited child descriptor would also unlock its
  // still-running parent.
  if (fd_ >= 0) {
    (void)::close(fd_);
  }
  fd_ = -1;
  owner_pid_ = 0;
  path_.clear();
}

bool GlassHandoffLease::valid() const {
  return fd_ >= 0 && owner_pid_ == static_cast<std::int64_t>(::getpid()) &&
         !path_.empty();
}

bool GlassHandoffLease::valid_for_path(const std::string &path) const {
  if (!valid() || path != path_) {
    return false;
  }

  // Reassert the nonblocking lock and prove that the descriptor still names
  // the persistent path. The second fstat closes replacement/change races
  // around lstat without trusting path lookup alone.
  if (::flock(fd_, LOCK_EX | LOCK_NB) != 0) {
    return false;
  }
  struct stat before {};
  struct stat named {};
  struct stat after {};
  const std::string lease_path = path + ".lease";
  return ::fstat(fd_, &before) == 0 && private_regular_file(before) &&
         ::lstat(lease_path.c_str(), &named) == 0 &&
         private_regular_file(named) && ::fstat(fd_, &after) == 0 &&
         private_regular_file(after) && before.st_dev == named.st_dev &&
         before.st_ino == named.st_ino && before.st_dev == after.st_dev &&
         before.st_ino == after.st_ino;
}

bool glass_handoff_acquire_lease(const std::string &path,
                                 GlassHandoffLease *out) {
  if (path.empty() || out == nullptr || out->valid()) {
    return false;
  }

  const std::string lease_path = path + ".lease";
  bool created = false;
  int fd =
      ::open(lease_path.c_str(),
             O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
             S_IRUSR | S_IWUSR);
  if (fd >= 0) {
    created = true;
  } else if (errno == EEXIST) {
    fd = ::open(lease_path.c_str(),
                O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  }
  if (fd < 0) {
    return false;
  }

  struct stat status {};
  const bool private_inode =
      (!created || ::fchmod(fd, S_IRUSR | S_IWUSR) == 0) &&
      ::fstat(fd, &status) == 0 && private_regular_file(status);
  if (!private_inode || ::flock(fd, LOCK_EX | LOCK_NB) != 0) {
    (void)::close(fd);
    return false;
  }

  GlassHandoffLease acquired;
  acquired.fd_ = fd;
  acquired.owner_pid_ = static_cast<std::int64_t>(::getpid());
  acquired.path_ = path;
  if (!acquired.valid_for_path(path)) {
    return false;
  }
  *out = std::move(acquired);
  return true;
}

const char *glass_handoff_reject_name(GlassHandoffReject reject) {
  switch (reject) {
  case GlassHandoffReject::kNone:
    return "none";
  case GlassHandoffReject::kMissing:
    return "missing";
  case GlassHandoffReject::kIo:
    return "io";
  case GlassHandoffReject::kPartial:
    return "partial";
  case GlassHandoffReject::kMagic:
    return "magic";
  case GlassHandoffReject::kVersion:
    return "version";
  case GlassHandoffReject::kLayout:
    return "layout";
  case GlassHandoffReject::kTooLarge:
    return "too_large";
  case GlassHandoffReject::kChecksum:
    return "checksum";
  case GlassHandoffReject::kAge:
    return "age";
  case GlassHandoffReject::kChain:
    return "chain";
  case GlassHandoffReject::kGeometry:
    return "geometry";
  case GlassHandoffReject::kPixelFormat:
    return "pixel_format";
  case GlassHandoffReject::kProfile:
    return "profile";
  case GlassHandoffReject::kWaveform:
    return "waveform";
  case GlassHandoffReject::kCt33:
    return "ct33";
  case GlassHandoffReject::kPipeline:
    return "pipeline";
  case GlassHandoffReject::kState:
    return "state";
  }
  return "unknown";
}

std::uint64_t glass_handoff_crc64(std::span<const std::uint8_t> bytes,
                                  std::uint64_t seed) {
  // ECMA-182 normal form, polynomial 0x42f0e1eba9ea3693.
  return crc64_update(bytes, seed);
}

GlassHandoffClock glass_handoff_now() {
  GlassHandoffClock result;
  timespec realtime{};
  if (::clock_gettime(CLOCK_REALTIME, &realtime) == 0) {
    result.realtime_sec = realtime.tv_sec;
  }
#if defined(CLOCK_BOOTTIME)
  timespec boottime{};
  if (::clock_gettime(CLOCK_BOOTTIME, &boottime) == 0) {
    result.boottime_ns =
        static_cast<std::uint64_t>(boottime.tv_sec) * 1'000'000'000ull +
        static_cast<std::uint64_t>(boottime.tv_nsec);
  }
#endif
  const int fd = ::open("/proc/sys/kernel/random/boot_id",
                        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd >= 0) {
    std::array<std::uint8_t, 128> bytes{};
    const ssize_t count = ::read(fd, bytes.data(), bytes.size());
    (void)::close(fd);
    if (count > 0) {
      result.boot_id_hash = glass_handoff_crc64(std::span<const std::uint8_t>(
          bytes.data(), static_cast<std::size_t>(count)));
    }
  }
  return result;
}

GlassHandoffReject glass_handoff_load(const GlassHandoffLease &lease,
                                      const std::string &path,
                                      const GlassHandoffIdentity &expected,
                                      const GlassHandoffClock &now,
                                      GlassHandoffBundle *out) {
  if (out == nullptr) {
    return GlassHandoffReject::kState;
  }
  *out = {};
  if (path.empty() || !lease.valid_for_path(path) ||
      !validate_identity_shape(expected)) {
    return GlassHandoffReject::kState;
  }
  const int raw_fd =
      ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  if (raw_fd < 0) {
    return errno == ENOENT ? GlassHandoffReject::kMissing
                           : GlassHandoffReject::kIo;
  }
  ScopedFd file(raw_fd);
  struct stat stat_buffer {};
  if (::fstat(file.get(), &stat_buffer) != 0 || stat_buffer.st_size < 0 ||
      !private_regular_file(stat_buffer)) {
    return GlassHandoffReject::kIo;
  }
  const std::uint64_t file_bytes =
      static_cast<std::uint64_t>(stat_buffer.st_size);
  if (file_bytes < kBaseHeaderBytes) {
    return GlassHandoffReject::kPartial;
  }
  if (file_bytes > kGlassHandoffMaxBytes ||
      file_bytes > std::numeric_limits<std::size_t>::max()) {
    return GlassHandoffReject::kTooLarge;
  }
  std::array<std::uint8_t, kBaseHeaderBytes> base_header{};
  const ReadStatus base_read = pread_exact(file.get(), base_header, 0);
  if (base_read != ReadStatus::kOk) {
    return reject_for_read(base_read);
  }
  std::span<const std::uint8_t> all(base_header);
  std::size_t cursor = 0;
  std::uint32_t magic = 0;
  std::uint32_t version = 0;
  std::uint32_t endian = 0;
  WireHeader header;
  std::uint32_t profile = 0;
  std::uint32_t tile_cols = 0;
  std::uint32_t tile_rows = 0;
  std::uint64_t realtime = 0;
  if (!get_u32(all, &cursor, &magic) || !get_u32(all, &cursor, &version) ||
      !get_u32(all, &cursor, &header.header_bytes) ||
      !get_u32(all, &cursor, &endian)) {
    return GlassHandoffReject::kPartial;
  }
  if (magic != kGlassHandoffMagic) {
    return GlassHandoffReject::kMagic;
  }
  if (version != kGlassHandoffVersion || endian != kEndianMarker) {
    return GlassHandoffReject::kVersion;
  }
  if (header.header_bytes < kBaseHeaderBytes ||
      header.header_bytes > kBaseHeaderBytes + 16u * kSectionEntryBytes ||
      header.header_bytes > file_bytes ||
      (header.header_bytes - kBaseHeaderBytes) % kSectionEntryBytes != 0) {
    return GlassHandoffReject::kLayout;
  }
  // Only the bounded directory is retained. Payload sections are read once,
  // directly into their final vectors after all metadata compatibility checks
  // pass, avoiding a second whole-bundle allocation.
  std::vector<std::uint8_t> header_storage(header.header_bytes);
  std::memcpy(header_storage.data(), base_header.data(), base_header.size());
  if (header_storage.size() > base_header.size()) {
    const ReadStatus directory_read = pread_exact(
        file.get(),
        std::span<std::uint8_t>(header_storage).subspan(base_header.size()),
        base_header.size());
    if (directory_read != ReadStatus::kOk) {
      return reject_for_read(directory_read);
    }
  }
  all = header_storage;
  if (!get_u32(all, &cursor, &header.identity.flags) ||
      !get_u32(all, &cursor, &profile) ||
      !get_u32(all, &cursor, &header.section_count) ||
      !get_u32(all, &cursor, &header.chain) ||
      !get_u32(all, &cursor, &header.identity.width) ||
      !get_u32(all, &cursor, &header.identity.height) ||
      !get_u32(all, &cursor, &header.identity.pixel_format) ||
      !get_u32(all, &cursor, &header.identity.engine_stride) ||
      !get_u32(all, &cursor, &header.identity.tile_px) ||
      !get_u32(all, &cursor, &tile_cols) ||
      !get_u32(all, &cursor, &tile_rows) ||
      !get_u32(all, &cursor, &header.identity.history_stride) ||
      !get_u32(all, &cursor, &header.identity.history_rows) ||
      !get_u32(all, &cursor, &header.identity.history_pixel_bytes) ||
      !get_i32(all, &cursor, &header.engine_temperature_bin) ||
      !get_i32(all, &cursor, &header.admission_temperature_bin) ||
      !get_u32(all, &cursor, &header.renderer.width) ||
      !get_u32(all, &cursor, &header.renderer.height) ||
      !get_u32(all, &cursor, &header.renderer.rotation) ||
      !get_u32(all, &cursor, &header.renderer.pixel_format) ||
      !get_u64(all, &cursor, &realtime) ||
      !get_u64(all, &cursor, &header.written.boottime_ns) ||
      !get_u64(all, &cursor, &header.written.boot_id_hash) ||
      !get_u64(all, &cursor, &header.identity.waveform_hash) ||
      !get_u64(all, &cursor, &header.identity.waveform_bytes) ||
      !get_u64(all, &cursor, &header.identity.ct33_hash) ||
      !get_u64(all, &cursor, &header.identity.ct33_bytes) ||
      !get_u64(all, &cursor, &header.identity.pipeline_hash) ||
      !get_u64(all, &cursor, &header.renderer.configuration_hash) ||
      !get_u64(all, &cursor, &header.total_bytes) ||
      !get_u64(all, &cursor, &header.payload_checksum) ||
      !get_u64(all, &cursor, &header.header_checksum)) {
    return GlassHandoffReject::kPartial;
  }
  header.identity.profile = static_cast<GlassHandoffProfile>(profile);
  header.written.realtime_sec = static_cast<std::int64_t>(realtime);
  const std::uint32_t encoded_section_count = static_cast<std::uint32_t>(
      (header.header_bytes - kBaseHeaderBytes) / kSectionEntryBytes);
  if (header.section_count != encoded_section_count ||
      header.section_count == 0 || header.section_count > 16 ||
      header.total_bytes != file_bytes ||
      !validate_identity_shape(header.identity)) {
    return GlassHandoffReject::kLayout;
  }
  const std::uint32_t expected_tile_cols =
      (header.identity.width + header.identity.tile_px - 1u) /
      header.identity.tile_px;
  const std::uint32_t expected_tile_rows =
      (header.identity.height + header.identity.tile_px - 1u) /
      header.identity.tile_px;
  if (tile_cols != expected_tile_cols || tile_rows != expected_tile_rows) {
    return GlassHandoffReject::kLayout;
  }

  std::vector<SectionView> sections;
  sections.reserve(header.section_count);
  cursor = kBaseHeaderBytes;
  std::uint64_t expected_offset = header.header_bytes;
  std::uint32_t previous_type = 0;
  for (std::uint32_t i = 0; i < header.section_count; ++i) {
    std::uint32_t raw_type = 0;
    std::uint32_t section_flags = 0;
    SectionView section;
    if (!get_u32(all, &cursor, &raw_type) ||
        !get_u32(all, &cursor, &section_flags) ||
        !get_u64(all, &cursor, &section.offset) ||
        !get_u64(all, &cursor, &section.size) ||
        !get_u64(all, &cursor, &section.checksum) || section_flags != 0 ||
        raw_type <
            static_cast<std::uint32_t>(GlassHandoffSection::kEngineLevels) ||
        raw_type >
            static_cast<std::uint32_t>(GlassHandoffSection::kPresenter) ||
        raw_type <= previous_type || section.offset != expected_offset ||
        section.size == 0 ||
        !checked_add(section.offset, section.size, &expected_offset) ||
        expected_offset > file_bytes) {
      return GlassHandoffReject::kLayout;
    }
    section.type = static_cast<GlassHandoffSection>(raw_type);
    previous_type = raw_type;
    sections.push_back(section);
  }
  if (expected_offset != file_bytes) {
    return GlassHandoffReject::kLayout;
  }

  WireHeader checksum_header = header;
  checksum_header.header_checksum = 0;
  std::vector<std::uint8_t> encoded_header =
      encode_header(checksum_header, sections, false);
  if (glass_handoff_crc64(encoded_header) != header.header_checksum) {
    return GlassHandoffReject::kChecksum;
  }

  if (header.chain >= kGlassHandoffMaxChain) {
    return GlassHandoffReject::kChain;
  }
  bool age_valid = false;
  const bool both_boot_ids =
      now.boot_id_hash != 0 && header.written.boot_id_hash != 0;
  if (both_boot_ids) {
    // A bundle from another boot is stale even if wall time happens to be
    // close (or was adjusted backwards). Never fall back to realtime after
    // a positive boot-identity mismatch.
    if (now.boot_id_hash == header.written.boot_id_hash &&
        now.boottime_ns != 0 && header.written.boottime_ns != 0 &&
        now.boottime_ns >= header.written.boottime_ns) {
      const std::uint64_t age_ns = now.boottime_ns - header.written.boottime_ns;
      age_valid = age_ns <= static_cast<std::uint64_t>(kGlassHandoffMaxAgeSec) *
                                1'000'000'000ull;
    }
  } else if (header.written.realtime_sec > 0 && now.realtime_sec > 0 &&
             now.realtime_sec >= header.written.realtime_sec) {
    age_valid = now.realtime_sec - header.written.realtime_sec <=
                kGlassHandoffMaxAgeSec;
  }
  if (!age_valid) {
    return GlassHandoffReject::kAge;
  }

  if (header.identity.profile != expected.profile) {
    return GlassHandoffReject::kProfile;
  }
  if (header.identity.width != expected.width ||
      header.identity.height != expected.height ||
      header.identity.engine_stride != expected.engine_stride ||
      header.identity.tile_px != expected.tile_px ||
      header.identity.history_stride != expected.history_stride ||
      header.identity.history_rows != expected.history_rows ||
      header.identity.history_pixel_bytes != expected.history_pixel_bytes ||
      header.identity.flags != expected.flags) {
    return GlassHandoffReject::kGeometry;
  }
  if (header.identity.pixel_format != expected.pixel_format) {
    return GlassHandoffReject::kPixelFormat;
  }
  if (header.identity.waveform_hash != expected.waveform_hash ||
      header.identity.waveform_bytes != expected.waveform_bytes) {
    return GlassHandoffReject::kWaveform;
  }
  if (header.identity.ct33_hash != expected.ct33_hash ||
      header.identity.ct33_bytes != expected.ct33_bytes) {
    return GlassHandoffReject::kCt33;
  }
  if (header.identity.pipeline_hash != expected.pipeline_hash) {
    return GlassHandoffReject::kPipeline;
  }

  const std::uint64_t plane =
      static_cast<std::uint64_t>(header.identity.engine_stride) *
      header.identity.height;
  const std::uint64_t tiles = static_cast<std::uint64_t>(tile_cols) * tile_rows;
  const SectionView *levels =
      find_section(sections, GlassHandoffSection::kEngineLevels);
  const SectionView *dc =
      find_section(sections, GlassHandoffSection::kEngineDc);
  const SectionView *stress =
      find_section(sections, GlassHandoffSection::kEngineStress);
  const SectionView *rescan =
      find_section(sections, GlassHandoffSection::kEngineRescan);
  const SectionView *history =
      find_section(sections, GlassHandoffSection::kXochitlHistory);
  const SectionView *renderer =
      find_section(sections, GlassHandoffSection::kRenderer);
  const SectionView *presenter =
      find_section(sections, GlassHandoffSection::kPresenter);
  const bool color = (header.identity.flags & kGlassHandoffFlagExactColor) != 0;
  std::uint64_t history_bytes = 0;
  if (!checked_mul(header.identity.history_stride, header.identity.history_rows,
                   &history_bytes) ||
      !checked_mul(history_bytes, 4u, &history_bytes) || dc == nullptr ||
      stress == nullptr || rescan == nullptr || renderer == nullptr ||
      dc->size != plane || stress->size != tiles * 2u ||
      rescan->size != tiles * 4u ||
      (color && (levels != nullptr || history == nullptr ||
                 history->size != history_bytes)) ||
      (!color &&
       (levels == nullptr || levels->size != plane || history != nullptr))) {
    return GlassHandoffReject::kLayout;
  }
  if (renderer->size > kMaximumRendererPayloadBytes ||
      (presenter != nullptr &&
       presenter->size > kGlassHandoffMaxPresenterPayloadBytes)) {
    return GlassHandoffReject::kTooLarge;
  }

  GlassHandoffBundle loaded;
  loaded.identity = header.identity;
  loaded.renderer = header.renderer;
  loaded.written = header.written;
  loaded.chain = header.chain;
  loaded.core.engine_temperature_bin = header.engine_temperature_bin;
  loaded.core.admission_temperature_bin = header.admission_temperature_bin;
  std::uint64_t payload_checksum = 0;
  ReadStatus read_status = ReadStatus::kOk;
  if (levels != nullptr) {
    loaded.core.engine_levels.resize(static_cast<std::size_t>(levels->size));
    read_status = read_byte_section(
        file.get(), *levels, loaded.core.engine_levels, &payload_checksum);
    if (read_status != ReadStatus::kOk) {
      return reject_for_read(read_status);
    }
  }
  loaded.core.engine_dc.resize(static_cast<std::size_t>(dc->size));
  read_status = read_byte_section(
      file.get(), *dc,
      std::span<std::uint8_t>(
          reinterpret_cast<std::uint8_t *>(loaded.core.engine_dc.data()),
          loaded.core.engine_dc.size()),
      &payload_checksum);
  if (read_status != ReadStatus::kOk) {
    return reject_for_read(read_status);
  }
  read_status = read_u16_section(file.get(), *stress,
                                 &loaded.core.engine_stress, &payload_checksum);
  if (read_status != ReadStatus::kOk) {
    return reject_for_read(read_status);
  }
  read_status = read_i32_section(file.get(), *rescan,
                                 &loaded.core.engine_rescan, &payload_checksum);
  if (read_status != ReadStatus::kOk) {
    return reject_for_read(read_status);
  }
  if (history != nullptr) {
    read_status =
        read_u16_section(file.get(), *history, &loaded.core.xochitl_history_ab,
                         &payload_checksum);
    if (read_status != ReadStatus::kOk) {
      return reject_for_read(read_status);
    }
  }
  loaded.renderer_payload.resize(static_cast<std::size_t>(renderer->size));
  read_status = read_byte_section(file.get(), *renderer,
                                  loaded.renderer_payload, &payload_checksum);
  if (read_status != ReadStatus::kOk) {
    return reject_for_read(read_status);
  }
  if (presenter != nullptr) {
    loaded.presenter_payload.resize(static_cast<std::size_t>(presenter->size));
    read_status = read_byte_section(
        file.get(), *presenter, loaded.presenter_payload, &payload_checksum);
    if (read_status != ReadStatus::kOk) {
      return reject_for_read(read_status);
    }
  }
  if (payload_checksum != header.payload_checksum) {
    return GlassHandoffReject::kChecksum;
  }
  if (!validate_core_sizes(loaded)) {
    return GlassHandoffReject::kState;
  }
  // Re-stat the opened inode after all positional reads. Concurrent truncation
  // or append therefore cannot turn an initially plausible prefix into an
  // admitted snapshot, even though writers normally publish by rename.
  struct stat final_stat {};
  if (::fstat(file.get(), &final_stat) != 0 || final_stat.st_size < 0) {
    return GlassHandoffReject::kIo;
  }
  if (!same_loaded_inode(stat_buffer, final_stat) ||
      static_cast<std::uint64_t>(final_stat.st_size) != file_bytes) {
    return GlassHandoffReject::kPartial;
  }
  loaded.claim = make_claim(final_stat, header.header_checksum);
  if (!file.close_checked()) {
    return GlassHandoffReject::kIo;
  }
  if (!lease.valid_for_path(path)) {
    return GlassHandoffReject::kState;
  }
  *out = std::move(loaded);
  return GlassHandoffReject::kNone;
}

bool glass_handoff_save(const GlassHandoffLease &lease, const std::string &path,
                        const GlassHandoffBundle &bundle) {
  if (path.empty() || !lease.valid_for_path(path) ||
      bundle.chain >= kGlassHandoffMaxChain ||
      !has_usable_written_clock(bundle.written) ||
      !validate_core_sizes(bundle)) {
    return false;
  }
  if (bundle.renderer_payload.size() > kMaximumRendererPayloadBytes ||
      bundle.presenter_payload.size() > kGlassHandoffMaxPresenterPayloadBytes) {
    return false;
  }
  reclaim_stale_private_files(path);

  std::vector<PayloadView> payloads;
  payloads.reserve(7);
  if (!bundle.core.engine_levels.empty()) {
    payloads.push_back(
        {GlassHandoffSection::kEngineLevels, PayloadEncoding::kBytes,
         bundle.core.engine_levels.data(), bundle.core.engine_levels.size()});
  }
  payloads.push_back({GlassHandoffSection::kEngineDc, PayloadEncoding::kBytes,
                      bundle.core.engine_dc.data(),
                      bundle.core.engine_dc.size()});
  payloads.push_back({GlassHandoffSection::kEngineStress, PayloadEncoding::kU16,
                      bundle.core.engine_stress.data(),
                      bundle.core.engine_stress.size()});
  payloads.push_back({GlassHandoffSection::kEngineRescan, PayloadEncoding::kI32,
                      bundle.core.engine_rescan.data(),
                      bundle.core.engine_rescan.size()});
  if (!bundle.core.xochitl_history_ab.empty()) {
    payloads.push_back({GlassHandoffSection::kXochitlHistory,
                        PayloadEncoding::kU16,
                        bundle.core.xochitl_history_ab.data(),
                        bundle.core.xochitl_history_ab.size()});
  }
  payloads.push_back({GlassHandoffSection::kRenderer, PayloadEncoding::kBytes,
                      bundle.renderer_payload.data(),
                      bundle.renderer_payload.size()});
  if (!bundle.presenter_payload.empty()) {
    payloads.push_back(
        {GlassHandoffSection::kPresenter, PayloadEncoding::kBytes,
         bundle.presenter_payload.data(), bundle.presenter_payload.size()});
  }

  WireHeader header;
  header.identity = bundle.identity;
  header.renderer = bundle.renderer;
  header.written = bundle.written;
  header.engine_temperature_bin = bundle.core.engine_temperature_bin;
  header.admission_temperature_bin = bundle.core.admission_temperature_bin;
  header.chain = bundle.chain;
  header.section_count = static_cast<std::uint32_t>(payloads.size());
  header.header_bytes = static_cast<std::uint32_t>(
      kBaseHeaderBytes + payloads.size() * kSectionEntryBytes);
  std::vector<SectionView> sections;
  sections.reserve(payloads.size());
  std::uint64_t offset = header.header_bytes;
  for (const PayloadView &payload : payloads) {
    const std::uint64_t payload_bytes = payload.byte_size();
    if (payload.data == nullptr || payload_bytes == 0) {
      return false;
    }
    SectionView section;
    section.type = payload.type;
    section.offset = offset;
    section.size = payload_bytes;
    if (!checked_add(offset, section.size, &offset) ||
        offset > kGlassHandoffMaxBytes) {
      return false;
    }
    sections.push_back(section);
  }
  header.total_bytes = offset;

  std::string temporary;
  const int fd = create_unique_private_file(path, "tmp", O_WRONLY, &temporary);
  if (fd < 0) {
    return false;
  }
  // Reserve the canonical header before streaming the payload. Checksums are
  // filled with a positional rewrite only after every payload byte has been
  // encoded and written; the temporary inode is never visible as `path`.
  std::vector<std::uint8_t> encoded_header =
      encode_header(header, sections, false);
  bool ok = write_exact(fd, encoded_header);
  for (std::size_t index = 0; ok && index < payloads.size(); ++index) {
    ok = write_payload(fd, payloads[index], &sections[index].checksum,
                       &header.payload_checksum);
  }
  if (ok) {
    encoded_header = encode_header(header, sections, false);
    header.header_checksum = glass_handoff_crc64(encoded_header);
    encoded_header = encode_header(header, sections, true);
    ok = pwrite_exact(fd, encoded_header, 0);
  }
  if (ok) {
    struct stat status {};
    ok = ::fstat(fd, &status) == 0 && private_regular_file(status) &&
         status.st_size >= 0 &&
         static_cast<std::uint64_t>(status.st_size) == header.total_bytes;
  }
  ok = ok && ::fsync(fd) == 0;
  const int close_status = ::close(fd);
  ok = ok && close_status == 0;
  if (!ok) {
    (void)::unlink(temporary.c_str());
    return false;
  }
  if (!lease.valid_for_path(path) ||
      ::rename(temporary.c_str(), path.c_str()) != 0) {
    (void)::unlink(temporary.c_str());
    return false;
  }
  if (!sync_parent_directory(path)) {
    // Rename already published a complete file. Conservative callers may
    // still choose to discard it; report failure so they do not trust a
    // durability guarantee the filesystem did not provide.
    return false;
  }
  return true;
}

bool glass_handoff_claim(const GlassHandoffLease &lease,
                         const std::string &path,
                         const GlassHandoffClaim &claim) {
  if (path.empty() || !lease.valid_for_path(path) || !claim.valid ||
      claim.file_bytes < kBaseHeaderBytes ||
      claim.file_bytes > kGlassHandoffMaxBytes) {
    return false;
  }

  // Reserve a destination that no competing consumer can have selected. The
  // following rename is the linearization point: one claimant moves the
  // shared name, and every later claimant observes ENOENT or a newer inode.
  std::string private_path;
  const int marker_fd =
      create_unique_private_file(path, "claim", O_WRONLY, &private_path);
  if (marker_fd < 0) {
    return false;
  }
  if (::close(marker_fd) != 0) {
    (void)::unlink(private_path.c_str());
    return false;
  }
  if (!lease.valid_for_path(path) ||
      ::rename(path.c_str(), private_path.c_str()) != 0) {
    (void)::unlink(private_path.c_str());
    return false;
  }

  bool exact_candidate = false;
  const int raw_fd = ::open(private_path.c_str(),
                            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  if (raw_fd >= 0) {
    ScopedFd file(raw_fd);
    struct stat before {};
    struct stat after {};
    exact_candidate = ::fstat(file.get(), &before) == 0 &&
                      stat_matches_claim(before, claim) &&
                      claim_header_matches(file.get(), claim) &&
                      ::fstat(file.get(), &after) == 0 &&
                      same_loaded_inode(before, after) &&
                      stat_matches_claim(after, claim) && file.close_checked();
  }

  // Invalid candidates are consumed too. Once a process has attempted first
  // admission, no partial/replaced file may remain available to seed a later
  // process. The lifetime lease excludes canonical republication here; the
  // final lease proof makes any broken/replaced lease fail the admission.
  const bool lease_still_valid = lease.valid_for_path(path);
  const bool removed = ::unlink(private_path.c_str()) == 0;
  const bool sync_ok = sync_parent_directory(path);
  return exact_candidate && lease_still_valid && removed && sync_ok;
}

bool glass_handoff_discard(const GlassHandoffLease &lease,
                           const std::string &path) {
  if (path.empty() || !lease.valid_for_path(path)) {
    return false;
  }
  reclaim_stale_private_files(path);
  enum class Presence : std::uint8_t { kAbsent, kPresent, kUnknown };
  const auto presence = [](const std::string &candidate) {
    struct stat status {};
    if (::lstat(candidate.c_str(), &status) == 0) {
      return Presence::kPresent;
    }
    return errno == ENOENT ? Presence::kAbsent : Presence::kUnknown;
  };
  const std::string temporary = path + ".tmp";
  const Presence final_before = presence(path);
  const Presence temporary_before = presence(temporary);
  if (!lease.valid_for_path(path)) {
    return false;
  }
  (void)::unlink(path.c_str());
  (void)::unlink(temporary.c_str());
  // Attempt the durability fence unconditionally. If no directory entry ever
  // existed there is no unlink to persist, so a missing parent is still a safe
  // and useful idempotent success for host backends.
  const bool sync_ok = sync_parent_directory(path);
  const bool both_were_absent = final_before == Presence::kAbsent &&
                                temporary_before == Presence::kAbsent;
  return presence(path) == Presence::kAbsent &&
         presence(temporary) == Presence::kAbsent &&
         (both_were_absent || sync_ok);
}

} // namespace pluto
