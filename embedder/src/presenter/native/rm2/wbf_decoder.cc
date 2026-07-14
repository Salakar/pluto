#include "presenter/native/rm2/wbf_decoder.h"

#include <algorithm>
#include <array>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <map>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace pluto::native::rm2 {
namespace {

constexpr std::size_t kFileCrcOffset = 0x00;
constexpr std::size_t kFileSizeOffset = 0x04;
constexpr std::size_t kSerialOffset = 0x08;
constexpr std::size_t kFplLotOffset = 0x0e;
constexpr std::size_t kModeVersionOffset = 0x10;
constexpr std::size_t kWaveformVersionOffset = 0x11;
constexpr std::size_t kWaveformSubversionOffset = 0x12;
constexpr std::size_t kWaveformTypeOffset = 0x13;
constexpr std::size_t kFrameRateOffset = 0x18;
constexpr std::size_t kXwiOffset = 0x1c;
constexpr std::size_t kHeaderChecksum1Offset = 0x1f;
constexpr std::size_t kModeTableOffset = 0x20;
constexpr std::size_t kLutFlagsOffset = 0x24;
constexpr std::size_t kMaxModeIndexOffset = 0x25;
constexpr std::size_t kMaxTemperatureIndexOffset = 0x26;
constexpr std::size_t kEndByteOffset = 0x28;
constexpr std::size_t kToggleByteOffset = 0x29;
constexpr std::size_t kHeaderChecksum2Offset = 0x2f;
constexpr std::size_t kTemperatureTableOffset = 0x30;

constexpr std::uint8_t kSupportedModeVersion = 0x19;
constexpr std::uint8_t kSupportedWaveformType = 0x51;
constexpr std::uint8_t kSupportedLutFlags = 0x04;
constexpr std::uint8_t kEndByte = 0xff;
constexpr std::uint8_t kToggleByte = 0xfc;
constexpr std::size_t kMaxModes = 16;
constexpr std::size_t kMaxTemperatures = 32;
constexpr std::size_t kMaxPhases = 512;
constexpr std::size_t kMaxDecodedPackedBytes = 64u * 1024u * 1024u;

struct Range {
  std::size_t begin = 0;
  std::size_t end = 0;
};

struct ParsedRecord {
  std::vector<std::uint8_t> packed;
  std::uint16_t phase_count = 0;
};

struct ParseResult {
  WbfMetadata metadata;
  std::vector<ParsedRecord> records;
  std::vector<std::size_t> record_index;
};

void set_error(std::string *error, std::string message) {
  if (error != nullptr) {
    *error = std::move(message);
  }
}

bool checked_range(std::size_t offset, std::size_t length, std::size_t size) {
  return offset <= size && length <= size - offset;
}

bool overlaps(const Range &left, const Range &right) {
  return left.begin < right.end && right.begin < left.end;
}

std::uint16_t read_u16le(std::span<const std::uint8_t> bytes,
                         std::size_t offset) {
  return static_cast<std::uint16_t>(bytes[offset]) |
         static_cast<std::uint16_t>(bytes[offset + 1]) << 8u;
}

std::uint32_t read_u24le(std::span<const std::uint8_t> bytes,
                         std::size_t offset) {
  return static_cast<std::uint32_t>(bytes[offset]) |
         static_cast<std::uint32_t>(bytes[offset + 1]) << 8u |
         static_cast<std::uint32_t>(bytes[offset + 2]) << 16u;
}

std::uint32_t read_u32le(std::span<const std::uint8_t> bytes,
                         std::size_t offset) {
  return static_cast<std::uint32_t>(bytes[offset]) |
         static_cast<std::uint32_t>(bytes[offset + 1]) << 8u |
         static_cast<std::uint32_t>(bytes[offset + 2]) << 16u |
         static_cast<std::uint32_t>(bytes[offset + 3]) << 24u;
}

std::uint8_t additive_checksum(std::span<const std::uint8_t> bytes) {
  std::uint8_t sum = 0;
  for (const std::uint8_t value : bytes) {
    sum = static_cast<std::uint8_t>(sum + value);
  }
  return sum;
}

std::uint32_t file_crc32(std::span<const std::uint8_t> bytes) {
  std::uint32_t crc = 0xffffffffu;
  for (std::size_t index = 0; index < bytes.size(); ++index) {
    // The WBF specification calculates over the entire file with its stored
    // CRC field treated as zero.
    const std::uint8_t value = index < 4 ? 0 : bytes[index];
    crc ^= value;
    for (int bit = 0; bit < 8; ++bit) {
      const std::uint32_t mask = 0u - (crc & 1u);
      crc = (crc >> 1u) ^ (0xedb88320u & mask);
    }
  }
  return crc ^ 0xffffffffu;
}

bool read_checked_pointer(std::span<const std::uint8_t> bytes,
                          std::size_t pointer_offset, std::size_t *out_target,
                          std::string *error) {
  if (!checked_range(pointer_offset, 4, bytes.size())) {
    set_error(error, "WBF pointer entry is truncated");
    return false;
  }
  const std::uint8_t expected = additive_checksum(
      bytes.subspan(pointer_offset, static_cast<std::size_t>(3)));
  if (bytes[pointer_offset + 3] != expected) {
    set_error(error, "WBF pointer checksum mismatch");
    return false;
  }
  const std::size_t target = read_u24le(bytes, pointer_offset);
  if (target >= bytes.size()) {
    set_error(error, "WBF pointer target is outside the file");
    return false;
  }
  *out_target = target;
  return true;
}

bool valid_name_byte(std::uint8_t value) {
  return (value >= 'A' && value <= 'Z') || (value >= 'a' && value <= 'z') ||
         (value >= '0' && value <= '9') || value == '_' || value == '-';
}

bool parse_embedded_identity(std::span<const std::uint8_t> bytes,
                             std::size_t xwi_offset, std::uint16_t fpl_lot,
                             std::string *out_name, std::string *out_panel,
                             Range *out_range, std::string *error) {
  if (!checked_range(xwi_offset, 2, bytes.size())) {
    set_error(error, "WBF XWI name header is truncated");
    return false;
  }
  const std::size_t name_size = bytes[xwi_offset];
  if (name_size == 0 || name_size > 127 ||
      !checked_range(xwi_offset + 1, name_size + 1, bytes.size())) {
    set_error(error, "WBF XWI name length is invalid");
    return false;
  }
  if (bytes[xwi_offset + 1 + name_size] != '/') {
    set_error(error, "WBF XWI name delimiter is missing");
    return false;
  }
  for (const std::uint8_t value : bytes.subspan(xwi_offset + 1, name_size)) {
    if (!valid_name_byte(value)) {
      set_error(error, "WBF XWI name contains an unsupported byte");
      return false;
    }
  }

  const std::string name(
      reinterpret_cast<const char *>(bytes.data() + xwi_offset + 1), name_size);
  std::string panel;
  bool found_lot = false;
  std::size_t token_begin = 0;
  while (token_begin <= name.size()) {
    const std::size_t token_end = name.find('_', token_begin);
    const std::size_t end =
        token_end == std::string::npos ? name.size() : token_end;
    const std::string_view token(name.data() + token_begin, end - token_begin);
    if (token.size() > 1 && token.front() == 'R') {
      unsigned int parsed = 0;
      const auto result = std::from_chars(token.data() + 1,
                                          token.data() + token.size(), parsed);
      if (result.ec == std::errc() &&
          result.ptr == token.data() + token.size()) {
        if (parsed > std::numeric_limits<std::uint16_t>::max() ||
            parsed != fpl_lot) {
          set_error(error, "WBF XWI FPL lot does not match the header");
          return false;
        }
        found_lot = true;
      }
    }
    if (token.size() > 2 && token.starts_with("ED")) {
      if (!panel.empty()) {
        set_error(error, "WBF XWI name contains multiple panel signatures");
        return false;
      }
      panel.assign(token);
    }
    if (token_end == std::string::npos) {
      break;
    }
    token_begin = token_end + 1;
  }
  if (!found_lot || panel.empty()) {
    set_error(error, "WBF XWI name lacks a bound FPL lot or panel signature");
    return false;
  }

  *out_name = name;
  *out_panel = panel;
  *out_range = Range{xwi_offset, xwi_offset + 1 + name_size + 1};
  return true;
}

bool decode_record(std::span<const std::uint8_t> bytes,
                   std::size_t record_offset, std::size_t record_limit,
                   ParsedRecord *out, std::string *error) {
  out->packed.clear();
  out->phase_count = 0;
  if (record_offset >= record_limit || record_limit > bytes.size()) {
    set_error(error, "WBF RLE record bounds are invalid");
    return false;
  }
  std::size_t cursor = record_offset;
  bool repeated = true;
  for (;;) {
    if (cursor >= record_limit) {
      set_error(error,
                "WBF RLE record reaches another record or file end before "
                "its END marker");
      return false;
    }
    const std::uint8_t token = bytes[cursor++];
    if (token == kEndByte) {
      break;
    }
    if (token == kToggleByte) {
      repeated = !repeated;
      if (cursor >= record_limit) {
        set_error(error,
                  "WBF RLE record reaches another record or file end after "
                  "a state toggle");
        return false;
      }
      continue;
    }

    std::size_t copies = 1;
    if (repeated) {
      if (cursor >= record_limit) {
        set_error(error,
                  "WBF RLE run reaches another record or file end before "
                  "its repeat count");
        return false;
      }
      copies += bytes[cursor++];
    }
    const std::size_t maximum = kMaxPhases * kWbfPackedPhaseBytes;
    if (copies > maximum - out->packed.size()) {
      set_error(error, "WBF RLE record exceeds the phase limit");
      return false;
    }
    out->packed.insert(out->packed.end(), copies, token);
  }

  if (out->packed.empty() || out->packed.size() % kWbfPackedPhaseBytes != 0) {
    set_error(error, "WBF RLE record is not a whole number of 5-bit phases");
    return false;
  }
  const std::size_t phases = out->packed.size() / kWbfPackedPhaseBytes;
  if (phases > std::numeric_limits<std::uint16_t>::max()) {
    set_error(error, "WBF phase count cannot be represented");
    return false;
  }
  out->phase_count = static_cast<std::uint16_t>(phases);
  return true;
}

bool parse_wbf(std::span<const std::uint8_t> bytes, ParseResult *out,
               std::string *error) {
  *out = ParseResult{};
  if (bytes.size() < kTemperatureTableOffset + 2) {
    set_error(error, "WBF file is shorter than its header");
    return false;
  }
  if (bytes.size() > kMaxWbfFileBytes) {
    set_error(error, "WBF file exceeds the bounded input limit");
    return false;
  }
  if (read_u32le(bytes, kFileSizeOffset) != bytes.size()) {
    set_error(error, "WBF file length field does not match the input");
    return false;
  }
  const std::uint32_t stored_crc = read_u32le(bytes, kFileCrcOffset);
  if (file_crc32(bytes) != stored_crc) {
    set_error(error, "WBF CRC32 mismatch");
    return false;
  }
  if (additive_checksum(bytes.subspan(0x08, 0x17)) !=
      bytes[kHeaderChecksum1Offset]) {
    set_error(error, "WBF header checksum CS1 mismatch");
    return false;
  }
  if (additive_checksum(bytes.subspan(0x20, 0x0f)) !=
      bytes[kHeaderChecksum2Offset]) {
    set_error(error, "WBF header checksum CS2 mismatch");
    return false;
  }
  if (bytes[kWaveformTypeOffset] != kSupportedWaveformType) {
    set_error(error, "WBF waveform type is not the supported AF format");
    return false;
  }
  if (bytes[kModeVersionOffset] != kSupportedModeVersion) {
    set_error(error, "WBF mode version is unsupported");
    return false;
  }
  if (bytes[kLutFlagsOffset] != kSupportedLutFlags) {
    set_error(error, "WBF LUT layout is not the supported 5-bit format");
    return false;
  }
  if (bytes[kEndByteOffset] != kEndByte ||
      bytes[kToggleByteOffset] != kToggleByte) {
    set_error(error, "WBF RLE marker bytes are unsupported");
    return false;
  }

  const std::size_t mode_count =
      static_cast<std::size_t>(bytes[kMaxModeIndexOffset]) + 1;
  const std::size_t temperature_count =
      static_cast<std::size_t>(bytes[kMaxTemperatureIndexOffset]) + 1;
  if (mode_count == 0 || mode_count > kMaxModes) {
    set_error(error, "WBF mode count is outside the supported bound");
    return false;
  }
  if (temperature_count == 0 || temperature_count > kMaxTemperatures) {
    set_error(error, "WBF temperature count is outside the supported bound");
    return false;
  }

  const std::size_t boundary_count = temperature_count + 1;
  const std::size_t temperature_checksum_offset =
      kTemperatureTableOffset + boundary_count;
  if (!checked_range(kTemperatureTableOffset, boundary_count + 1,
                     bytes.size())) {
    set_error(error, "WBF temperature table is truncated");
    return false;
  }
  const auto boundaries =
      bytes.subspan(kTemperatureTableOffset, boundary_count);
  if (additive_checksum(boundaries) != bytes[temperature_checksum_offset]) {
    set_error(error, "WBF temperature table checksum mismatch");
    return false;
  }
  for (std::size_t index = 1; index < boundaries.size(); ++index) {
    if (boundaries[index] <= boundaries[index - 1]) {
      set_error(error,
                "WBF temperature boundaries are not strictly increasing");
      return false;
    }
  }

  const std::uint16_t fpl_lot = read_u16le(bytes, kFplLotOffset);
  const std::size_t xwi_offset = read_u24le(bytes, kXwiOffset);
  const std::size_t fixed_header_end = temperature_checksum_offset + 1;
  if (xwi_offset < fixed_header_end) {
    set_error(error, "WBF XWI name overlaps the header");
    return false;
  }
  std::string waveform_name;
  std::string panel_signature;
  Range xwi_range;
  if (!parse_embedded_identity(bytes, xwi_offset, fpl_lot, &waveform_name,
                               &panel_signature, &xwi_range, error)) {
    return false;
  }

  const std::size_t mode_table_offset = read_u24le(bytes, kModeTableOffset);
  const std::size_t mode_table_bytes = mode_count * 4;
  if (mode_table_offset < fixed_header_end ||
      !checked_range(mode_table_offset, mode_table_bytes, bytes.size())) {
    set_error(error, "WBF mode table is outside the file");
    return false;
  }
  const Range mode_range{mode_table_offset,
                         mode_table_offset + mode_table_bytes};
  if (overlaps(xwi_range, mode_range)) {
    set_error(error, "WBF XWI name overlaps the mode table");
    return false;
  }

  std::vector<std::size_t> record_offsets(mode_count * temperature_count);
  std::vector<Range> temperature_ranges;
  std::map<std::size_t, Range> unique_temperature_ranges;
  std::size_t metadata_end =
      std::max({fixed_header_end, xwi_range.end, mode_range.end});
  for (std::size_t mode = 0; mode < mode_count; ++mode) {
    std::size_t temperature_table_offset = 0;
    if (!read_checked_pointer(bytes, mode_table_offset + mode * 4,
                              &temperature_table_offset, error)) {
      return false;
    }
    const std::size_t table_bytes = temperature_count * 4;
    if (!checked_range(temperature_table_offset, table_bytes, bytes.size())) {
      set_error(error, "WBF mode temperature table is truncated");
      return false;
    }
    const Range table_range{temperature_table_offset,
                            temperature_table_offset + table_bytes};
    if (table_range.begin < fixed_header_end ||
        overlaps(table_range, xwi_range) || overlaps(table_range, mode_range)) {
      set_error(error, "WBF mode temperature table overlaps metadata");
      return false;
    }
    const auto inserted =
        unique_temperature_ranges.emplace(table_range.begin, table_range);
    if (!inserted.second && inserted.first->second.end != table_range.end) {
      set_error(error, "WBF mode temperature tables overlap inconsistently");
      return false;
    }
    for (const Range &existing : temperature_ranges) {
      if (existing.begin != table_range.begin &&
          overlaps(existing, table_range)) {
        set_error(error, "WBF mode temperature tables overlap");
        return false;
      }
    }
    temperature_ranges.push_back(table_range);
    metadata_end = std::max(metadata_end, table_range.end);

    for (std::size_t temperature = 0; temperature < temperature_count;
         ++temperature) {
      std::size_t record_offset = 0;
      if (!read_checked_pointer(bytes,
                                temperature_table_offset + temperature * 4,
                                &record_offset, error)) {
        return false;
      }
      record_offsets[mode * temperature_count + temperature] = record_offset;
    }
  }

  std::map<std::size_t, std::size_t> record_by_offset;
  for (const std::size_t record_offset : record_offsets) {
    if (record_offset < metadata_end) {
      set_error(error, "WBF RLE record points into metadata");
      return false;
    }
    record_by_offset.try_emplace(record_offset, 0);
  }

  // Decode in physical order and bound each stream by the next referenced
  // stream. Besides rejecting overlaps immediately, this makes total encoded
  // input scanning linear in the file size even for adversarial pointers.
  for (auto current = record_by_offset.begin();
       current != record_by_offset.end(); ++current) {
    auto next = current;
    ++next;
    const std::size_t record_limit =
        next == record_by_offset.end() ? bytes.size() : next->first;
    ParsedRecord record;
    if (!decode_record(bytes, current->first, record_limit, &record, error)) {
      return false;
    }
    if (record.packed.size() >
        kMaxDecodedPackedBytes - out->metadata.decoded_packed_bytes) {
      set_error(error, "WBF decoded records exceed the aggregate size limit");
      return false;
    }
    out->metadata.decoded_packed_bytes += record.packed.size();
    current->second = out->records.size();
    out->records.push_back(std::move(record));
  }

  out->record_index.resize(record_offsets.size());
  out->metadata.phase_counts.resize(record_offsets.size());
  for (std::size_t index = 0; index < record_offsets.size(); ++index) {
    const std::size_t record_id = record_by_offset.at(record_offsets[index]);
    out->record_index[index] = record_id;
    out->metadata.phase_counts[index] = out->records[record_id].phase_count;
  }

  out->metadata.source_sha256 = sha256(bytes);
  out->metadata.file_crc32 = stored_crc;
  out->metadata.file_size = static_cast<std::uint32_t>(bytes.size());
  out->metadata.serial = read_u32le(bytes, kSerialOffset);
  out->metadata.fpl_lot = fpl_lot;
  out->metadata.mode_version = bytes[kModeVersionOffset];
  out->metadata.waveform_version = bytes[kWaveformVersionOffset];
  out->metadata.waveform_subversion = bytes[kWaveformSubversionOffset];
  out->metadata.frame_rate_hz = bytes[kFrameRateOffset];
  out->metadata.mode_count = static_cast<std::uint8_t>(mode_count);
  out->metadata.temperature_count =
      static_cast<std::uint8_t>(temperature_count);
  out->metadata.waveform_name = std::move(waveform_name);
  out->metadata.panel_signature = std::move(panel_signature);
  out->metadata.temperature_boundaries_celsius.assign(boundaries.begin(),
                                                      boundaries.end());
  out->metadata.unique_record_count = out->records.size();
  return true;
}

bool is_zero_digest(
    const std::array<std::uint8_t, kSha256DigestBytes> &digest) {
  return std::all_of(digest.begin(), digest.end(),
                     [](std::uint8_t value) { return value == 0; });
}

} // namespace

bool WbfDecoder::inspect(std::span<const std::uint8_t> bytes,
                         WbfMetadata *out_metadata, std::string *error) {
  if (out_metadata == nullptr) {
    set_error(error, "WBF inspection metadata output is null");
    return false;
  }
  ParseResult parsed;
  if (!parse_wbf(bytes, &parsed, error)) {
    *out_metadata = WbfMetadata{};
    return false;
  }
  *out_metadata = std::move(parsed.metadata);
  return true;
}

bool WbfDecoder::open(std::span<const std::uint8_t> bytes,
                      const WbfExpectedIdentity &expected, std::string *error) {
  clear();
  if (expected.panel_signature.empty() || expected.fpl_lot == 0 ||
      is_zero_digest(expected.sha256)) {
    set_error(error, "WBF expected identity is incomplete");
    return false;
  }

  ParseResult parsed;
  if (!parse_wbf(bytes, &parsed, error)) {
    return false;
  }
  if (parsed.metadata.source_sha256 != expected.sha256) {
    set_error(error, "WBF SHA-256 does not match the device profile");
    return false;
  }
  if (parsed.metadata.panel_signature != expected.panel_signature) {
    set_error(error, "WBF panel signature does not match the device profile");
    return false;
  }
  if (parsed.metadata.fpl_lot != expected.fpl_lot) {
    set_error(error, "WBF FPL lot does not match the device profile");
    return false;
  }

  metadata_ = std::move(parsed.metadata);
  record_index_ = std::move(parsed.record_index);
  records_.reserve(parsed.records.size());
  for (ParsedRecord &source : parsed.records) {
    records_.push_back(Record{std::move(source.packed), source.phase_count});
  }
  valid_ = true;
  return true;
}

void WbfDecoder::clear() {
  metadata_ = WbfMetadata{};
  records_.clear();
  record_index_.clear();
  valid_ = false;
}

bool WbfDecoder::select_temperature(int milli_celsius,
                                    std::uint32_t *out_temperature) const {
  if (!valid_ || out_temperature == nullptr ||
      metadata_.temperature_count == 0 ||
      metadata_.temperature_boundaries_celsius.size() !=
          static_cast<std::size_t>(metadata_.temperature_count) + 1) {
    return false;
  }
  std::uint32_t selected = 0;
  for (std::uint32_t index = 1; index < metadata_.temperature_count; ++index) {
    const int boundary_milli =
        static_cast<int>(metadata_.temperature_boundaries_celsius[index]) *
        1000;
    if (milli_celsius >= boundary_milli) {
      selected = index;
    } else {
      break;
    }
  }
  *out_temperature = selected;
  return true;
}

const WbfDecoder::Record *WbfDecoder::record(std::uint32_t mode,
                                             std::uint32_t temperature) const {
  if (!valid_ || mode >= metadata_.mode_count ||
      temperature >= metadata_.temperature_count) {
    return nullptr;
  }
  const std::size_t index =
      static_cast<std::size_t>(mode) * metadata_.temperature_count +
      temperature;
  if (index >= record_index_.size() ||
      record_index_[index] >= records_.size()) {
    return nullptr;
  }
  return &records_[record_index_[index]];
}

std::uint32_t WbfDecoder::phase_count(std::uint32_t mode,
                                      std::uint32_t temperature) const {
  const Record *found = record(mode, temperature);
  return found == nullptr ? 0 : found->phase_count;
}

bool WbfDecoder::drive_code(std::uint32_t mode, std::uint32_t temperature,
                            std::uint8_t old_level, std::uint8_t new_level,
                            std::uint32_t phase, std::uint8_t *out_code) const {
  const Record *found = record(mode, temperature);
  if (found == nullptr || out_code == nullptr || old_level >= kWbfGrayStates ||
      new_level >= kWbfGrayStates || phase >= found->phase_count) {
    return false;
  }
  const std::size_t transition =
      static_cast<std::size_t>(new_level) * kWbfGrayStates + old_level;
  const std::size_t packed_index =
      static_cast<std::size_t>(phase) * kWbfPackedPhaseBytes + transition / 4;
  const unsigned shift = static_cast<unsigned>((transition % 4) * 2);
  *out_code =
      static_cast<std::uint8_t>((found->packed[packed_index] >> shift) & 0x03u);
  return true;
}

std::span<const std::uint8_t>
WbfDecoder::packed_record(std::uint32_t mode, std::uint32_t temperature) const {
  const Record *found = record(mode, temperature);
  return found == nullptr ? std::span<const std::uint8_t>{}
                          : std::span<const std::uint8_t>(found->packed);
}

std::string
wbf_sha256_hex(const std::array<std::uint8_t, kSha256DigestBytes> &digest) {
  constexpr char kHex[] = "0123456789abcdef";
  std::string result(digest.size() * 2, '0');
  for (std::size_t index = 0; index < digest.size(); ++index) {
    result[index * 2] = kHex[digest[index] >> 4u];
    result[index * 2 + 1] = kHex[digest[index] & 0x0fu];
  }
  return result;
}

} // namespace pluto::native::rm2
