#include "presenter/swtcon/xochitl_delta_table.h"

#include "presenter/swtcon/swtcon_waveform.h"
#include "swtcon_eink_synth.h"
#include "xochitl_color_mapper_reference.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <span>
#include <sstream>
#include <string>
#include <vector>

namespace pluto::swtcon {
namespace {

constexpr std::size_t mapper_transition(std::uint8_t source,
                                        std::uint8_t drive) {
  return static_cast<std::size_t>(source) * 32u + drive;
}

constexpr std::size_t waveform_cell(std::size_t transition) {
  return (transition & 31u) * 32u + (transition >> 5);
}

bool all_zero(const XochitlDeltaTableResult &result) {
  return std::all_of(result.values.begin(), result.values.end(),
                     [](std::int16_t value) { return value == 0; });
}

std::vector<std::vector<std::uint8_t>>
reference_sequences(std::span<const std::uint8_t> phase_major_codes) {
  const std::size_t phases =
      phase_major_codes.size() / kXochitlDeltaTableEntries;
  std::vector<std::vector<std::uint8_t>> sequences(
      kXochitlDeltaTableEntries, std::vector<std::uint8_t>(phases));
  for (std::size_t transition = 0; transition < kXochitlDeltaTableEntries;
       ++transition) {
    const std::size_t cell = waveform_cell(transition);
    for (std::size_t phase = 0; phase < phases; ++phase) {
      sequences[transition][phase] =
          phase_major_codes[phase * kXochitlDeltaTableEntries + cell];
    }
  }
  return sequences;
}

std::vector<std::uint8_t> read_file(const std::string &path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    return {};
  }
  return std::vector<std::uint8_t>(std::istreambuf_iterator<char>(input),
                                   std::istreambuf_iterator<char>());
}

std::string fixture_path() {
#ifdef PLUTO_SWTCON_EINK_FIXTURE
  return PLUTO_SWTCON_EINK_FIXTURE;
#else
  return {};
#endif
}

std::string sha256(std::span<const std::uint8_t> input) {
  constexpr std::array<std::uint32_t, 64> k = {
      0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu,
      0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u,
      0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u,
      0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
      0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u,
      0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
      0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
      0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
      0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u,
      0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u, 0x1e376c08u,
      0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu,
      0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
      0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u};
  std::array<std::uint32_t, 8> state = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u,
                                        0xa54ff53au, 0x510e527fu, 0x9b05688cu,
                                        0x1f83d9abu, 0x5be0cd19u};

  std::vector<std::uint8_t> padded(input.begin(), input.end());
  const std::uint64_t bit_length =
      static_cast<std::uint64_t>(input.size()) * 8u;
  padded.push_back(0x80u);
  while ((padded.size() % 64u) != 56u) {
    padded.push_back(0u);
  }
  for (int shift = 56; shift >= 0; shift -= 8) {
    padded.push_back(static_cast<std::uint8_t>(bit_length >> shift));
  }

  for (std::size_t chunk = 0; chunk < padded.size(); chunk += 64u) {
    std::array<std::uint32_t, 64> words{};
    for (std::size_t i = 0; i < 16; ++i) {
      const std::size_t at = chunk + i * 4u;
      words[i] = (static_cast<std::uint32_t>(padded[at]) << 24) |
                 (static_cast<std::uint32_t>(padded[at + 1]) << 16) |
                 (static_cast<std::uint32_t>(padded[at + 2]) << 8) |
                 static_cast<std::uint32_t>(padded[at + 3]);
    }
    for (std::size_t i = 16; i < words.size(); ++i) {
      const std::uint32_t s0 = std::rotr(words[i - 15], 7) ^
                               std::rotr(words[i - 15], 18) ^
                               (words[i - 15] >> 3);
      const std::uint32_t s1 = std::rotr(words[i - 2], 17) ^
                               std::rotr(words[i - 2], 19) ^
                               (words[i - 2] >> 10);
      words[i] = words[i - 16] + s0 + words[i - 7] + s1;
    }

    std::uint32_t a = state[0];
    std::uint32_t b = state[1];
    std::uint32_t c = state[2];
    std::uint32_t d = state[3];
    std::uint32_t e = state[4];
    std::uint32_t f = state[5];
    std::uint32_t g = state[6];
    std::uint32_t h = state[7];
    for (std::size_t i = 0; i < words.size(); ++i) {
      const std::uint32_t sum1 =
          std::rotr(e, 6) ^ std::rotr(e, 11) ^ std::rotr(e, 25);
      const std::uint32_t choice = (e & f) ^ (~e & g);
      const std::uint32_t temp1 = h + sum1 + choice + k[i] + words[i];
      const std::uint32_t sum0 =
          std::rotr(a, 2) ^ std::rotr(a, 13) ^ std::rotr(a, 22);
      const std::uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
      const std::uint32_t temp2 = sum0 + majority;
      h = g;
      g = f;
      f = e;
      e = d + temp1;
      d = c;
      c = b;
      b = a;
      a = temp1 + temp2;
    }
    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
  }

  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (const std::uint32_t word : state) {
    output << std::setw(8) << word;
  }
  return output.str();
}

TEST(XochitlDeltaTableTest,
     MatchesIndependentReferenceAcrossAllNineTemperatureBins) {
  constexpr std::size_t kPhases = 7;
  std::vector<std::uint8_t> codes(kPhases * kXochitlDeltaTableEntries);
  for (std::size_t phase = 0; phase < kPhases; ++phase) {
    for (std::size_t cell = 0; cell < kXochitlDeltaTableEntries; ++cell) {
      codes[phase * kXochitlDeltaTableEntries + cell] =
          static_cast<std::uint8_t>((phase * 5u + cell * 3u) % 7u);
    }
  }
  const auto sequences = reference_sequences(codes);
  for (int bin = 0; bin < 9; ++bin) {
    const XochitlDeltaTableResult production =
        build_xochitl_delta_table(codes, bin);
    const xochitl_reference::DeltaTableResult reference =
        xochitl_reference::build_delta_table(sequences,
                                             static_cast<std::size_t>(bin));
    ASSERT_TRUE(production) << "bin=" << bin;
    ASSERT_TRUE(reference) << "bin=" << bin;
    for (std::size_t transition = 0; transition < kXochitlDeltaTableEntries;
         ++transition) {
      EXPECT_EQ(production.values[transition], reference.values[transition])
          << "bin=" << bin << " transition=" << transition;
    }
  }
}

TEST(XochitlDeltaTableTest,
     RejectsMalformedAndUnsupportedRecordsWithoutPartialOutput) {
  XochitlDeltaTableResult result = build_xochitl_delta_table({}, 4);
  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(XochitlDeltaError::kEmptyPhaseSequence));
  EXPECT_EQ(result.failing_transition, 0u);
  EXPECT_TRUE(all_zero(result));

  std::vector<std::uint8_t> malformed(kXochitlDeltaTableEntries - 1, 0);
  result = build_xochitl_delta_table(malformed, 4);
  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(XochitlDeltaError::kInvalidPhaseRecord));
  EXPECT_TRUE(all_zero(result));

  std::vector<std::uint8_t> too_many(1025u * kXochitlDeltaTableEntries, 0);
  result = build_xochitl_delta_table(too_many, 4);
  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(XochitlDeltaError::kInvalidPhaseRecord));
  EXPECT_TRUE(all_zero(result));

  std::vector<std::uint8_t> unsupported(3u * kXochitlDeltaTableEntries, 0);
  constexpr std::size_t bad_transition = mapper_transition(3, 17);
  unsupported[kXochitlDeltaTableEntries + waveform_cell(bad_transition)] = 7;
  result = build_xochitl_delta_table(unsupported, 4);
  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(XochitlDeltaError::kUnsupportedPhaseCode));
  EXPECT_EQ(result.failing_transition, bad_transition);
  EXPECT_TRUE(all_zero(result));

  result = build_xochitl_delta_table(unsupported, -1);
  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(XochitlDeltaError::kInvalidTemperatureBin));
  EXPECT_TRUE(all_zero(result));
  result = build_xochitl_delta_table(unsupported, 9);
  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(XochitlDeltaError::kInvalidTemperatureBin));
  EXPECT_TRUE(all_zero(result));
}

TEST(XochitlDeltaTableTest, RejectsOutOfRangeResultWithoutPartialOutput) {
  std::vector<std::uint8_t> codes(1024u * kXochitlDeltaTableEntries, 0);
  constexpr std::size_t bad_transition = mapper_transition(0, 31);
  const std::size_t cell = waveform_cell(bad_transition);
  for (std::size_t phase = 0; phase < 1024u; ++phase) {
    codes[phase * kXochitlDeltaTableEntries + cell] = 1;
  }
  const XochitlDeltaTableResult result = build_xochitl_delta_table(codes, 0);
  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(XochitlDeltaError::kOutOfRange));
  EXPECT_EQ(result.failing_transition, bad_transition);
  EXPECT_TRUE(all_zero(result));
}

TEST(XochitlDeltaTableTest, WaveformOverloadValidatesEverySelection) {
  WaveformTable invalid;
  XochitlDeltaTableResult result = build_xochitl_delta_table(invalid, 0, 0);
  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(XochitlDeltaError::kInvalidWaveformTable));
  EXPECT_TRUE(all_zero(result));

  WaveformTable table;
  std::string error;
  ASSERT_TRUE(table.parse(swtcon_synth::make_synthetic_eink(5), &error))
      << error;
  result = build_xochitl_delta_table(table, -1, 0);
  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(XochitlDeltaError::kInvalidMode));
  result = build_xochitl_delta_table(table, table.mode_count(), 0);
  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(XochitlDeltaError::kInvalidMode));
  result = build_xochitl_delta_table(table, 2, -1);
  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(XochitlDeltaError::kInvalidTemperatureBin));
  result = build_xochitl_delta_table(table, 2, table.temp_count());
  EXPECT_EQ(static_cast<int>(result.error),
            static_cast<int>(XochitlDeltaError::kInvalidTemperatureBin));

  result = build_xochitl_delta_table(table, 2, 1);
  ASSERT_TRUE(result);
  const auto reference = xochitl_reference::build_delta_table(
      reference_sequences(table.phase_record_codes(2, 1)), 1);
  ASSERT_TRUE(reference);
  for (std::size_t transition = 0; transition < kXochitlDeltaTableEntries;
       ++transition) {
    EXPECT_EQ(result.values[transition], reference.values[transition]);
  }
}

TEST(XochitlDeltaTableTest, PinsInstalledMode2Bin4ByteHash) {
  const std::vector<std::uint8_t> bytes = read_file(fixture_path());
  if (bytes.empty()) {
    // The fixture is checked into the full repository but may be absent from
    // deliberately stripped source packages.
    return;
  }
  WaveformTable table;
  std::string error;
  ASSERT_TRUE(table.parse(bytes, &error)) << error;
  ASSERT_EQ(table.phase_count(2, 4), 86);

  const XochitlDeltaTableResult production =
      build_xochitl_delta_table(table, 2, 4);
  ASSERT_TRUE(production);
  const auto reference = xochitl_reference::build_delta_table(
      reference_sequences(table.phase_record_codes(2, 4)), 4);
  ASSERT_TRUE(reference);

  std::vector<std::uint8_t> little_endian;
  little_endian.reserve(kXochitlDeltaTableEntries * 2u);
  for (std::size_t transition = 0; transition < kXochitlDeltaTableEntries;
       ++transition) {
    EXPECT_EQ(production.values[transition], reference.values[transition]);
    const std::uint16_t value =
        static_cast<std::uint16_t>(production.values[transition]);
    little_endian.push_back(static_cast<std::uint8_t>(value));
    little_endian.push_back(static_cast<std::uint8_t>(value >> 8));
  }
  EXPECT_EQ(sha256(little_endian),
            std::string("67cd71ab2481606a72a302cd069a29167"
                        "aab0d703ea22283d6b746475f447492"));
}

} // namespace
} // namespace pluto::swtcon
