#include "presenter/native/rm2/wbf_decoder.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <span>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "wbf_synth.h"

namespace pluto::native::rm2 {
namespace {

using test::make_synthetic_wbf;
using test::SyntheticWbf;

void expect_inspection_failure(const std::vector<std::uint8_t> &bytes,
                               const std::string &message_fragment) {
  WbfMetadata metadata;
  std::string error;
  EXPECT_FALSE(WbfDecoder::inspect(bytes, &metadata, &error));
  EXPECT_TRUE(error.find(message_fragment) != std::string::npos)
      << "expected '" << message_fragment << "' in '" << error << "'";
}

TEST(WbfDecoderTest, OpensGeneratedFixtureAndServesBoundedDriveLookups) {
  const SyntheticWbf fixture = make_synthetic_wbf();
  WbfMetadata inspected;
  std::string error;
  ASSERT_TRUE(WbfDecoder::inspect(fixture.bytes, &inspected, &error)) << error;
  EXPECT_EQ(inspected.file_size, fixture.bytes.size());
  EXPECT_EQ(inspected.serial, 0x01020304u);
  EXPECT_EQ(inspected.fpl_lot, 123u);
  EXPECT_EQ(inspected.mode_version, 0x19u);
  EXPECT_EQ(inspected.waveform_version, 1u);
  EXPECT_EQ(inspected.waveform_subversion, 2u);
  EXPECT_EQ(inspected.frame_rate_hz, 85u);
  EXPECT_EQ(inspected.mode_count, 2u);
  EXPECT_EQ(inspected.temperature_count, 2u);
  EXPECT_EQ(inspected.panel_signature, "EDTESTPANEL");
  EXPECT_TRUE(inspected.temperature_boundaries_celsius ==
              (std::vector<std::uint8_t>{0, 25, 50}));
  EXPECT_TRUE(inspected.phase_counts ==
              (std::vector<std::uint16_t>{1, 1, 1, 2}));
  EXPECT_EQ(inspected.unique_record_count, 4u);
  EXPECT_EQ(inspected.decoded_packed_bytes,
            static_cast<std::size_t>(5 * kWbfPackedPhaseBytes));
  EXPECT_EQ(wbf_sha256_hex(inspected.source_sha256), sha256_hex(fixture.bytes));

  WbfDecoder decoder;
  ASSERT_TRUE(decoder.open(fixture.bytes, fixture.expected, &error)) << error;
  EXPECT_TRUE(decoder.valid());
  EXPECT_EQ(decoder.phase_count(0, 0), 1u);
  EXPECT_EQ(decoder.phase_count(1, 1), 2u);
  EXPECT_EQ(decoder.phase_count(2, 0), 0u);
  EXPECT_EQ(decoder.packed_record(1, 1).size(), 2u * kWbfPackedPhaseBytes);

  std::uint32_t temperature = 99;
  ASSERT_TRUE(decoder.select_temperature(-5000, &temperature));
  EXPECT_EQ(temperature, 0u);
  ASSERT_TRUE(decoder.select_temperature(24999, &temperature));
  EXPECT_EQ(temperature, 0u);
  ASSERT_TRUE(decoder.select_temperature(25000, &temperature));
  EXPECT_EQ(temperature, 1u);
  ASSERT_TRUE(decoder.select_temperature(100000, &temperature));
  EXPECT_EQ(temperature, 1u);

  std::uint8_t code = 0;
  ASSERT_TRUE(decoder.drive_code(1, 0, 0, 0, 0, &code));
  EXPECT_EQ(code, 3u);
  ASSERT_TRUE(decoder.drive_code(1, 0, 1, 0, 0, &code));
  EXPECT_EQ(code, 2u);
  ASSERT_TRUE(decoder.drive_code(1, 0, 2, 0, 0, &code));
  EXPECT_EQ(code, 1u);
  ASSERT_TRUE(decoder.drive_code(1, 0, 3, 0, 0, &code));
  EXPECT_EQ(code, 0u);
  EXPECT_FALSE(decoder.drive_code(1, 0, 32, 0, 0, &code));
  EXPECT_FALSE(decoder.drive_code(1, 0, 0, 32, 0, &code));
  EXPECT_FALSE(decoder.drive_code(1, 0, 0, 0, 1, &code));
}

TEST(WbfDecoderTest, RejectsIncompleteOrMismatchedDeviceIdentity) {
  const SyntheticWbf fixture = make_synthetic_wbf();
  WbfDecoder decoder;
  std::string error;

  WbfExpectedIdentity missing;
  EXPECT_FALSE(decoder.open(fixture.bytes, missing, &error));
  EXPECT_TRUE(error.find("incomplete") != std::string::npos);

  WbfExpectedIdentity wrong = fixture.expected;
  wrong.sha256[0] ^= 1;
  EXPECT_FALSE(decoder.open(fixture.bytes, wrong, &error));
  EXPECT_TRUE(error.find("SHA-256") != std::string::npos);

  wrong = fixture.expected;
  wrong.panel_signature = "EDOTHER";
  EXPECT_FALSE(decoder.open(fixture.bytes, wrong, &error));
  EXPECT_TRUE(error.find("panel signature") != std::string::npos);

  wrong = fixture.expected;
  wrong.fpl_lot = 124;
  EXPECT_FALSE(decoder.open(fixture.bytes, wrong, &error));
  EXPECT_TRUE(error.find("FPL lot") != std::string::npos);
  EXPECT_FALSE(decoder.valid());
}

TEST(WbfDecoderTest, RejectsEveryIntegrityAndPointerLayerFailClosed) {
  const SyntheticWbf fixture = make_synthetic_wbf();

  auto bytes = fixture.bytes;
  bytes.back() ^= 1;
  expect_inspection_failure(bytes, "CRC32");

  bytes = fixture.bytes;
  bytes[0x08] ^= 1;
  test::refresh_crc(&bytes);
  expect_inspection_failure(bytes, "CS1");

  bytes = fixture.bytes;
  bytes[0x2a] ^= 1;
  test::refresh_crc(&bytes);
  expect_inspection_failure(bytes, "CS2");

  bytes = fixture.bytes;
  bytes[0x31] ^= 1;
  test::refresh_crc(&bytes);
  expect_inspection_failure(bytes, "temperature table checksum");

  bytes = fixture.bytes;
  bytes[fixture.mode_table_offset + 3] ^= 1;
  test::refresh_crc(&bytes);
  expect_inspection_failure(bytes, "pointer checksum");

  bytes = fixture.bytes;
  test::write_pointer(&bytes, fixture.mode_table_offset, bytes.size());
  test::refresh_crc(&bytes);
  expect_inspection_failure(bytes, "pointer target");

  bytes = fixture.bytes;
  test::write_pointer(&bytes, fixture.temperature_table_offsets[1] + 4,
                      fixture.mode_table_offset);
  test::refresh_crc(&bytes);
  expect_inspection_failure(bytes, "points into metadata");

  bytes = fixture.bytes;
  test::write_pointer(&bytes, fixture.temperature_table_offsets[1] + 4,
                      fixture.record_offsets[2] + 1);
  test::refresh_crc(&bytes);
  expect_inspection_failure(bytes, "another record");
}

TEST(WbfDecoderTest, RejectsUnsupportedHeaderIdentityAndMalformedRle) {
  const SyntheticWbf fixture = make_synthetic_wbf();
  auto bytes = fixture.bytes;

  bytes[0x10] = 0x18;
  test::refresh_header_checksums(&bytes);
  test::refresh_crc(&bytes);
  expect_inspection_failure(bytes, "mode version");

  bytes = fixture.bytes;
  bytes[0x24] = 0;
  test::refresh_header_checksums(&bytes);
  test::refresh_crc(&bytes);
  expect_inspection_failure(bytes, "5-bit");

  bytes = fixture.bytes;
  bytes[0x31] = 0;
  test::refresh_temperature_checksum(&bytes);
  test::refresh_crc(&bytes);
  expect_inspection_failure(bytes, "strictly increasing");

  bytes = fixture.bytes;
  const auto name_begin = bytes.begin() + fixture.xwi_offset + 1;
  const std::array<std::uint8_t, 4> lot_pattern = {'R', '1', '2', '3'};
  const auto lot = std::search(name_begin, bytes.end(), lot_pattern.begin(),
                               lot_pattern.end());
  ASSERT_TRUE(lot != bytes.end());
  *(lot + 3) = '4';
  test::refresh_crc(&bytes);
  expect_inspection_failure(bytes, "FPL lot");

  bytes = fixture.bytes;
  bytes.back() = 0;
  test::refresh_crc(&bytes);
  expect_inspection_failure(bytes, "RLE");

  bytes = fixture.bytes;
  bytes[fixture.record_offsets.back() + 3] = 0xfe;
  test::refresh_crc(&bytes);
  expect_inspection_failure(bytes, "whole number");
}

TEST(WbfDecoderTest, TruncationMutationAndDeterministicNoiseNeverEscapeBounds) {
  const SyntheticWbf fixture = make_synthetic_wbf();
  for (std::size_t size = 0; size < fixture.bytes.size(); ++size) {
    const std::span<const std::uint8_t> truncated(fixture.bytes.data(), size);
    WbfMetadata metadata;
    std::string error;
    EXPECT_FALSE(WbfDecoder::inspect(truncated, &metadata, &error));
  }

  for (std::size_t index = 0; index < fixture.bytes.size(); ++index) {
    auto mutated = fixture.bytes;
    mutated[index] ^= 1;
    WbfMetadata metadata;
    std::string error;
    EXPECT_FALSE(WbfDecoder::inspect(mutated, &metadata, &error));
  }

  std::uint32_t state = 0x91e10da5u;
  for (std::size_t size = 0; size <= 1024; size += 7) {
    std::vector<std::uint8_t> noise(size);
    for (std::uint8_t &value : noise) {
      state ^= state << 13u;
      state ^= state >> 17u;
      state ^= state << 5u;
      value = static_cast<std::uint8_t>(state);
    }
    WbfMetadata metadata;
    std::string error;
    EXPECT_FALSE(WbfDecoder::inspect(noise, &metadata, &error));
  }
}

#if defined(PLUTO_RM2_WBF_FIXTURE)
TEST(WbfDecoderTest, ValidatesIgnoredExactActiveRm2ArtifactWhenPresent) {
  std::ifstream input(PLUTO_RM2_WBF_FIXTURE, std::ios::binary);
  if (!input) {
    return;
  }
  const std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(input)),
                                        std::istreambuf_iterator<char>());
  WbfMetadata metadata;
  std::string error;
  ASSERT_TRUE(WbfDecoder::inspect(bytes, &metadata, &error)) << error;
  EXPECT_EQ(wbf_sha256_hex(metadata.source_sha256),
            "79783d751ba066af12c6ac5aca46279fe7c79d4ef834105bd46824f870f9c6f8");
  EXPECT_EQ(metadata.file_size, 285735u);
  EXPECT_EQ(metadata.fpl_lot, 405u);
  EXPECT_EQ(metadata.panel_signature, "ED103TC2C5");
  EXPECT_EQ(metadata.mode_version, 0x19u);
  EXPECT_EQ(metadata.mode_count, 8u);
  EXPECT_EQ(metadata.temperature_count, 14u);
  EXPECT_EQ(metadata.temperature_boundaries_celsius.size(), 15u);
  EXPECT_EQ(metadata.phase_counts.size(), 8u * 14u);
  EXPECT_TRUE(std::all_of(metadata.phase_counts.begin(),
                          metadata.phase_counts.end(),
                          [](std::uint16_t phases) { return phases > 0; }));

  WbfExpectedIdentity expected;
  expected.sha256 = metadata.source_sha256;
  expected.panel_signature = "ED103TC2C5";
  expected.fpl_lot = 405;
  WbfDecoder decoder;
  ASSERT_TRUE(decoder.open(bytes, expected, &error)) << error;
}
#endif

} // namespace
} // namespace pluto::native::rm2
