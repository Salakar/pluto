#ifndef PLUTO_TEST_PRESENTER_WBF_SYNTH_H_
#define PLUTO_TEST_PRESENTER_WBF_SYNTH_H_

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "presenter/native/rm2/wbf_decoder.h"
#include "runtime/sha256.h"

namespace pluto::native::rm2::test {

struct SyntheticWbf {
  std::vector<std::uint8_t> bytes;
  WbfExpectedIdentity expected;
  std::size_t xwi_offset = 0;
  std::size_t mode_table_offset = 0;
  std::vector<std::size_t> temperature_table_offsets;
  std::vector<std::size_t> record_offsets;
};

inline void write_u16le(std::vector<std::uint8_t> *bytes, std::size_t offset,
                        std::uint16_t value) {
  (*bytes)[offset] = static_cast<std::uint8_t>(value);
  (*bytes)[offset + 1] = static_cast<std::uint8_t>(value >> 8u);
}

inline void write_u24le(std::vector<std::uint8_t> *bytes, std::size_t offset,
                        std::uint32_t value) {
  (*bytes)[offset] = static_cast<std::uint8_t>(value);
  (*bytes)[offset + 1] = static_cast<std::uint8_t>(value >> 8u);
  (*bytes)[offset + 2] = static_cast<std::uint8_t>(value >> 16u);
}

inline void write_u32le(std::vector<std::uint8_t> *bytes, std::size_t offset,
                        std::uint32_t value) {
  (*bytes)[offset] = static_cast<std::uint8_t>(value);
  (*bytes)[offset + 1] = static_cast<std::uint8_t>(value >> 8u);
  (*bytes)[offset + 2] = static_cast<std::uint8_t>(value >> 16u);
  (*bytes)[offset + 3] = static_cast<std::uint8_t>(value >> 24u);
}

inline std::uint8_t sum_bytes(const std::vector<std::uint8_t> &bytes,
                              std::size_t offset, std::size_t count) {
  std::uint8_t sum = 0;
  for (std::size_t index = 0; index < count; ++index) {
    sum = static_cast<std::uint8_t>(sum + bytes[offset + index]);
  }
  return sum;
}

inline std::uint32_t
crc32_with_zero_header(const std::vector<std::uint8_t> &bytes) {
  std::uint32_t crc = 0xffffffffu;
  for (std::size_t index = 0; index < bytes.size(); ++index) {
    crc ^= index < 4 ? 0 : bytes[index];
    for (int bit = 0; bit < 8; ++bit) {
      crc = (crc >> 1u) ^
            ((crc & 1u) == 0 ? 0u : static_cast<std::uint32_t>(0xedb88320u));
    }
  }
  return crc ^ 0xffffffffu;
}

inline void refresh_header_checksums(std::vector<std::uint8_t> *bytes) {
  (*bytes)[0x1f] = sum_bytes(*bytes, 0x08, 0x17);
  (*bytes)[0x2f] = sum_bytes(*bytes, 0x20, 0x0f);
}

inline void refresh_temperature_checksum(std::vector<std::uint8_t> *bytes) {
  const std::size_t temperature_count =
      static_cast<std::size_t>((*bytes)[0x26]) + 1;
  const std::size_t boundary_count = temperature_count + 1;
  (*bytes)[0x30 + boundary_count] = sum_bytes(*bytes, 0x30, boundary_count);
}

inline void refresh_crc(std::vector<std::uint8_t> *bytes) {
  write_u32le(bytes, 0, 0);
  write_u32le(bytes, 0, crc32_with_zero_header(*bytes));
}

inline void refresh_all_checksums(std::vector<std::uint8_t> *bytes) {
  write_u32le(bytes, 4, static_cast<std::uint32_t>(bytes->size()));
  refresh_header_checksums(bytes);
  refresh_temperature_checksum(bytes);
  refresh_crc(bytes);
}

inline void write_pointer(std::vector<std::uint8_t> *bytes, std::size_t offset,
                          std::size_t target) {
  write_u24le(bytes, offset, static_cast<std::uint32_t>(target));
  (*bytes)[offset + 3] = sum_bytes(*bytes, offset, 3);
}

inline std::size_t align4(std::size_t value) {
  return (value + 3u) & ~std::size_t{3};
}

// Generates a complete WBF from semantic fields and tiny RLE programs. It is
// intentionally unrelated to any vendor byte stream.
inline SyntheticWbf make_synthetic_wbf() {
  constexpr std::uint16_t kLot = 123;
  const std::string name = "320_R123_TEST_EDTESTPANEL_VB0000-TC";
  SyntheticWbf result;
  result.xwi_offset = 0x40;
  result.mode_table_offset = align4(result.xwi_offset + 1 + name.size() + 1);
  result.temperature_table_offsets = {
      result.mode_table_offset + 8,
      result.mode_table_offset + 16,
  };
  const std::size_t records_begin = result.mode_table_offset + 24;

  const std::vector<std::vector<std::uint8_t>> records = {
      {0x00, 0xff, 0xff},
      {0xe4, 0xff, 0xff},
      [&]() {
        std::vector<std::uint8_t> literal = {0xfc};
        literal.insert(literal.end(), kWbfPackedPhaseBytes, 0x1b);
        literal.push_back(0xff);
        return literal;
      }(),
      {0x1b, 0xff, 0xe4, 0xff, 0xff},
  };

  std::size_t cursor = records_begin;
  for (const auto &record : records) {
    result.record_offsets.push_back(cursor);
    cursor += record.size();
  }
  result.bytes.assign(cursor, 0);

  write_u32le(&result.bytes, 8, 0x01020304u);
  result.bytes[0x0c] = 0x11;
  write_u16le(&result.bytes, 0x0e, kLot);
  result.bytes[0x10] = 0x19;
  result.bytes[0x11] = 0x01;
  result.bytes[0x12] = 0x02;
  result.bytes[0x13] = 0x51;
  result.bytes[0x14] = 0x01;
  result.bytes[0x17] = 0x85;
  result.bytes[0x18] = 0x55;
  write_u24le(&result.bytes, 0x1c,
              static_cast<std::uint32_t>(result.xwi_offset));
  write_u24le(&result.bytes, 0x20,
              static_cast<std::uint32_t>(result.mode_table_offset));
  result.bytes[0x23] = 0x01;
  result.bytes[0x24] = 0x04;
  result.bytes[0x25] = 0x01;
  result.bytes[0x26] = 0x01;
  result.bytes[0x28] = 0xff;
  result.bytes[0x29] = 0xfc;
  result.bytes[0x30] = 0;
  result.bytes[0x31] = 25;
  result.bytes[0x32] = 50;

  result.bytes[result.xwi_offset] = static_cast<std::uint8_t>(name.size());
  std::copy(name.begin(), name.end(),
            result.bytes.begin() + result.xwi_offset + 1);
  result.bytes[result.xwi_offset + 1 + name.size()] = '/';

  for (std::size_t mode = 0; mode < 2; ++mode) {
    write_pointer(&result.bytes, result.mode_table_offset + mode * 4,
                  result.temperature_table_offsets[mode]);
    for (std::size_t temperature = 0; temperature < 2; ++temperature) {
      write_pointer(&result.bytes,
                    result.temperature_table_offsets[mode] + temperature * 4,
                    result.record_offsets[mode * 2 + temperature]);
    }
  }
  for (std::size_t index = 0; index < records.size(); ++index) {
    std::copy(records[index].begin(), records[index].end(),
              result.bytes.begin() + result.record_offsets[index]);
  }

  refresh_all_checksums(&result.bytes);
  result.expected.sha256 = sha256(result.bytes);
  result.expected.panel_signature = "EDTESTPANEL";
  result.expected.fpl_lot = kLot;
  return result;
}

// Generates the minimum seven-mode shape required by Rm2WaveformProgram.
// Every mode intentionally points at the same four-phase semantic record; the
// fixture exists to exercise presenter policy and scheduling without relying
// on, copying, or deriving bytes from a vendor waveform.
inline SyntheticWbf make_synthetic_rm2_program_wbf() {
  constexpr std::uint16_t kLot = 124;
  constexpr std::size_t kModes = 7;
  const std::string name = "320_R124_TEST_EDSYNTHRM2_VB0000-TC";
  SyntheticWbf result;
  result.xwi_offset = 0x40;
  result.mode_table_offset = align4(result.xwi_offset + 1 + name.size() + 1);
  result.temperature_table_offsets.resize(kModes);
  const std::size_t temperature_tables_begin =
      result.mode_table_offset + kModes * 4U;
  for (std::size_t mode = 0; mode < kModes; ++mode) {
    result.temperature_table_offsets[mode] =
        temperature_tables_begin + mode * 4U;
  }
  const std::size_t init_record_offset = temperature_tables_begin + kModes * 4U;
  const std::vector<std::uint8_t> init_record = {0x00, 0xff, 0xff};
  const std::size_t dynamic_record_offset =
      init_record_offset + init_record.size();
  result.record_offsets = {init_record_offset, dynamic_record_offset};
  const std::vector<std::uint8_t> dynamic_record = {
      0x1b, 0xff, 0xe4, 0xff, 0x39, 0xff, 0x93, 0xff, 0xff,
  };
  result.bytes.assign(dynamic_record_offset + dynamic_record.size(), 0);

  write_u32le(&result.bytes, 8, 0x01020304u);
  result.bytes[0x0c] = 0x11;
  write_u16le(&result.bytes, 0x0e, kLot);
  result.bytes[0x10] = 0x19;
  result.bytes[0x11] = 0x01;
  result.bytes[0x12] = 0x02;
  result.bytes[0x13] = 0x51;
  result.bytes[0x14] = 0x01;
  result.bytes[0x17] = 0x85;
  result.bytes[0x18] = 0x55;
  write_u24le(&result.bytes, 0x1c,
              static_cast<std::uint32_t>(result.xwi_offset));
  write_u24le(&result.bytes, 0x20,
              static_cast<std::uint32_t>(result.mode_table_offset));
  result.bytes[0x23] = 0x01;
  result.bytes[0x24] = 0x04;
  result.bytes[0x25] = static_cast<std::uint8_t>(kModes - 1U);
  result.bytes[0x26] = 0;
  result.bytes[0x28] = 0xff;
  result.bytes[0x29] = 0xfc;
  result.bytes[0x30] = 0;
  result.bytes[0x31] = 50;

  result.bytes[result.xwi_offset] = static_cast<std::uint8_t>(name.size());
  std::copy(name.begin(), name.end(),
            result.bytes.begin() + result.xwi_offset + 1);
  result.bytes[result.xwi_offset + 1 + name.size()] = '/';

  for (std::size_t mode = 0; mode < kModes; ++mode) {
    write_pointer(&result.bytes, result.mode_table_offset + mode * 4U,
                  result.temperature_table_offsets[mode]);
    write_pointer(&result.bytes, result.temperature_table_offsets[mode],
                  mode == 0 ? init_record_offset : dynamic_record_offset);
  }
  std::copy(init_record.begin(), init_record.end(),
            result.bytes.begin() + init_record_offset);
  std::copy(dynamic_record.begin(), dynamic_record.end(),
            result.bytes.begin() + dynamic_record_offset);
  refresh_all_checksums(&result.bytes);
  result.expected.sha256 = sha256(result.bytes);
  result.expected.panel_signature = "EDSYNTHRM2";
  result.expected.fpl_lot = kLot;
  return result;
}

} // namespace pluto::native::rm2::test

#endif // PLUTO_TEST_PRESENTER_WBF_SYNTH_H_
