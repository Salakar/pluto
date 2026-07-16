#include "presenter/native/rm2/rm2_scan_encoder.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#include "wbf_synth.h"

namespace pluto::native::rm2 {
namespace {

std::uint32_t read_cell(const std::vector<std::byte> &slot, std::size_t row,
                        std::size_t cell) {
  std::uint32_t value = 0;
  std::memcpy(&value, slot.data() + row * kRm2ScanoutStrideBytes + cell * 4,
              sizeof(value));
  return value;
}

void write_cell(std::vector<std::byte> *slot, std::size_t row, std::size_t cell,
                std::uint32_t value) {
  std::memcpy(slot->data() + row * kRm2ScanoutStrideBytes + cell * 4, &value,
              sizeof(value));
}

void reference_encode_rm2_phase(
    std::vector<std::byte> *slot, const Rm2PanelRect &rect,
    const std::vector<std::uint8_t> &transition_keys,
    const std::vector<std::uint8_t> &phase_lut) {
  constexpr std::size_t kPreambleRows = 4;
  constexpr std::size_t kFirstPixelCell = 26;
  const std::size_t rows = rect.row_count();
  for (std::uint32_t column = rect.column_min; column <= rect.column_max;
       ++column) {
    const std::size_t target_base =
        static_cast<std::size_t>(column - rect.column_min) * rows;
    const std::size_t scan_line = kPreambleRows + column;
    for (std::uint32_t row = rect.row_min; row <= rect.row_max; row += 8U) {
      std::uint16_t packed = 0;
      for (std::uint32_t lane = 0; lane < 8; ++lane) {
        const std::size_t target_offset =
            target_base + row + lane - rect.row_min;
        const std::uint8_t drive = phase_lut[transition_keys[target_offset]];
        packed |= static_cast<std::uint16_t>(drive & 0x03U)
                  << ((7U - lane) * 2U);
      }
      const std::size_t cell = kFirstPixelCell + (row >> 3U);
      const std::uint32_t existing = read_cell(*slot, scan_line, cell);
      write_cell(slot, scan_line, cell, (existing & 0xffff0000U) | packed);
    }
  }
}

std::vector<std::uint8_t> expanded_phase(const WbfDecoder &waveform,
                                         std::uint32_t mode,
                                         std::uint32_t temperature,
                                         std::uint32_t phase,
                                         bool suppress_unchanged) {
  std::vector<std::uint8_t> result(16U * 16U);
  for (std::uint32_t new_level = 0; new_level < 16; ++new_level) {
    for (std::uint32_t old_level = 0; old_level < 16; ++old_level) {
      std::uint8_t code = 0;
      if (!waveform.drive_code(
              mode, temperature, static_cast<std::uint8_t>(old_level * 2U),
              static_cast<std::uint8_t>(new_level * 2U), phase, &code)) {
        return {};
      }
      result[new_level * 16U + old_level] =
          suppress_unchanged && new_level == old_level ? 0 : code;
    }
  }
  return result;
}

std::uint8_t arithmetic_rgb565_level(std::uint16_t pixel) {
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

TEST(Rm2ScanEncoder, BuildsExactControlRowsAndUniformDriveTemplate) {
  std::vector<std::byte> slot(kRm2SlotBytes);
  ASSERT_TRUE(fill_rm2_scan_slot(slot, 0xaaaaU));

  EXPECT_EQ(read_cell(slot, 0, 0), 0x00430000U);
  EXPECT_EQ(read_cell(slot, 0, 20), 0x00470000U);
  EXPECT_EQ(read_cell(slot, 0, 40), 0x00450000U);
  EXPECT_EQ(read_cell(slot, 1, 8), 0x00610000U);
  EXPECT_EQ(read_cell(slot, 1, 55), 0x00430000U);
  EXPECT_EQ(read_cell(slot, 3, 25), 0x00410000U);
  EXPECT_EQ(read_cell(slot, 3, 26), 0x0051aaaaU);
  EXPECT_EQ(read_cell(slot, 3, 55), 0x0053aaaaU);
  EXPECT_EQ(read_cell(slot, 1407, 259), 0x0051aaaaU);

  EXPECT_FALSE(rm2_scan_slot_is_safe_hold(slot));
  ASSERT_TRUE(fill_rm2_scan_slot(slot, 0));
  EXPECT_TRUE(rm2_scan_slot_is_safe_hold(slot));
  slot[4U * kRm2ScanoutStrideBytes + 26U * sizeof(std::uint32_t)] ^=
      std::byte{1};
  EXPECT_FALSE(rm2_scan_slot_is_safe_hold(slot));
}

TEST(Rm2ScanEncoder, PacksEightPixelCommandsAndPreservesControlHalf) {
  const test::SyntheticWbf fixture = test::make_synthetic_wbf();
  WbfDecoder waveform;
  std::string error;
  ASSERT_TRUE(waveform.open(fixture.bytes, fixture.expected, &error)) << error;

  std::vector<std::byte> slot(kRm2SlotBytes);
  ASSERT_TRUE(fill_rm2_scan_slot(slot, 0));
  const Rm2PanelRect rect{
      .row_min = 0,
      .row_max = 7,
      .column_min = 0,
      .column_max = 0,
  };
  const std::vector<std::uint8_t> transitions(8, 0);
  const std::vector<std::uint8_t> full_lut =
      expanded_phase(waveform, 1, 0, 0, false);
  const std::vector<std::uint8_t> partial_lut =
      expanded_phase(waveform, 1, 0, 0, true);

  ASSERT_TRUE(encode_rm2_phase(slot, rect, transitions, full_lut));
  EXPECT_EQ(read_cell(slot, 4, 26), 0x0051ffffU);
  ASSERT_TRUE(clear_rm2_phase_cells(slot, rect));
  EXPECT_EQ(read_cell(slot, 4, 26), 0x00510000U);

  ASSERT_TRUE(encode_rm2_phase(slot, rect, transitions, partial_lut));
  EXPECT_EQ(read_cell(slot, 4, 26), 0x00510000U);
}

TEST(Rm2ScanEncoder, PackedPhasePathsMatchScalarReferenceByteForByte) {
  std::uint32_t random = 0x8f41c2d7U;
  std::vector<std::uint8_t> phase_lut(256);
  for (std::uint8_t &drive : phase_lut) {
    random = random * 1664525U + 1013904223U;
    drive = static_cast<std::uint8_t>(random >> 24U);
  }

  {
    const Rm2PanelRect rect{
        .row_min = 0,
        .row_max = static_cast<std::uint16_t>(kRm2PanelHeight - 1U),
        .column_min = 0,
        .column_max = static_cast<std::uint16_t>(kRm2PanelWidth - 1U),
    };
    std::vector<std::uint8_t> transitions(kRm2PanelWidth * kRm2PanelHeight);
    for (std::uint8_t &transition : transitions) {
      random = random * 1664525U + 1013904223U;
      transition = static_cast<std::uint8_t>(random >> 24U);
    }
    std::vector<std::byte> expected(kRm2SlotBytes);
    std::vector<std::byte> actual(kRm2SlotBytes);
    ASSERT_TRUE(fill_rm2_scan_slot(expected, 0));
    ASSERT_TRUE(fill_rm2_scan_slot(actual, 0));
    reference_encode_rm2_phase(&expected, rect, transitions, phase_lut);
    ASSERT_TRUE(encode_rm2_phase(actual, rect, transitions, phase_lut));
    EXPECT_TRUE(std::equal(actual.begin(), actual.end(), expected.begin()));
  }

  {
    const Rm2PanelRect rect{
        .row_min = 0,
        .row_max = 7,
        .column_min = 0,
        .column_max = 255,
    };
    std::vector<std::uint8_t> transitions(rect.row_count() *
                                          rect.column_count());
    for (std::size_t transition = 0; transition < 256; ++transition) {
      std::fill_n(transitions.begin() + transition * 8U, 8U,
                  static_cast<std::uint8_t>(transition));
    }
    std::vector<std::byte> expected(kRm2SlotBytes);
    std::vector<std::byte> actual(kRm2SlotBytes);
    ASSERT_TRUE(fill_rm2_scan_slot(expected, 0));
    ASSERT_TRUE(fill_rm2_scan_slot(actual, 0));
    reference_encode_rm2_phase(&expected, rect, transitions, phase_lut);
    ASSERT_TRUE(encode_rm2_phase(actual, rect, transitions, phase_lut));
    EXPECT_TRUE(std::equal(actual.begin(), actual.end(), expected.begin()));
  }
}

TEST(Rm2ScanEncoder, BatchedNearFullAndSparseRegionsMatchScalarReference) {
  std::uint32_t random = 0x1423ab91U;
  std::vector<std::uint8_t> phase_lut(256);
  for (std::uint8_t &drive : phase_lut) {
    random = random * 1664525U + 1013904223U;
    drive = static_cast<std::uint8_t>(random >> 24U);
  }
  Rm2PhaseEncoder encoder;
  ASSERT_TRUE(encoder.ready());

  {
    const Rm2PanelRect rect{
        .row_min = 0,
        .row_max = static_cast<std::uint16_t>(kRm2PanelHeight - 1U),
        .column_min = 1,
        .column_max = static_cast<std::uint16_t>(kRm2PanelWidth - 1U),
    };
    std::vector<std::uint8_t> transitions(rect.row_count() *
                                          rect.column_count());
    for (std::uint8_t &transition : transitions) {
      random = random * 1664525U + 1013904223U;
      transition = static_cast<std::uint8_t>(random >> 24U);
    }
    std::vector<std::byte> expected(kRm2SlotBytes);
    std::vector<std::byte> actual(kRm2SlotBytes);
    ASSERT_TRUE(fill_rm2_scan_slot(expected, 0));
    ASSERT_TRUE(fill_rm2_scan_slot(actual, 0));
    reference_encode_rm2_phase(&expected, rect, transitions, phase_lut);
    ASSERT_TRUE(encoder.encode(actual, rect, transitions, phase_lut));
    EXPECT_TRUE(std::equal(actual.begin(), actual.end(), expected.begin()));
  }

  {
    std::array<Rm2PhaseRegion, 64> regions{};
    std::vector<std::uint8_t> transitions(regions.size() * 8U);
    for (std::size_t index = 0; index < regions.size(); ++index) {
      const std::uint16_t row =
          static_cast<std::uint16_t>((index * 24U) % (kRm2PanelHeight - 8U));
      regions[index] = {
          .rect =
              {
                  .row_min = row,
                  .row_max = static_cast<std::uint16_t>(row + 7U),
                  .column_min = static_cast<std::uint16_t>(index * 20U),
                  .column_max = static_cast<std::uint16_t>(index * 20U),
              },
          .transition_offset = index * 8U,
      };
      for (std::size_t lane = 0; lane < 8U; ++lane) {
        random = random * 1664525U + 1013904223U;
        transitions[index * 8U + lane] =
            static_cast<std::uint8_t>(random >> 24U);
      }
    }
    std::vector<std::byte> expected(kRm2SlotBytes);
    std::vector<std::byte> actual(kRm2SlotBytes);
    ASSERT_TRUE(fill_rm2_scan_slot(expected, 0));
    ASSERT_TRUE(fill_rm2_scan_slot(actual, 0));
    for (const Rm2PhaseRegion &region : regions) {
      reference_encode_rm2_phase(
          &expected, region.rect,
          std::vector<std::uint8_t>(
              transitions.begin() +
                  static_cast<std::ptrdiff_t>(region.transition_offset),
              transitions.begin() +
                  static_cast<std::ptrdiff_t>(region.transition_offset + 8U)),
          phase_lut);
    }
    ASSERT_TRUE(
        encoder.encode_regions(actual, regions, transitions, phase_lut));
    EXPECT_TRUE(std::equal(actual.begin(), actual.end(), expected.begin()));
  }
}

TEST(Rm2ScanEncoder, PersistentWorkerWakesAfterRepeatedIdleGaps) {
  const Rm2PanelRect rect{
      .row_min = 0,
      .row_max = static_cast<std::uint16_t>(kRm2PanelHeight - 1U),
      .column_min = 0,
      .column_max = 63,
  };
  std::vector<std::uint8_t> transitions(rect.row_count() * rect.column_count());
  std::vector<std::uint8_t> phase_lut(256);
  for (std::size_t index = 0; index < transitions.size(); ++index) {
    transitions[index] = static_cast<std::uint8_t>(index * 37U + 11U);
  }
  for (std::size_t index = 0; index < phase_lut.size(); ++index) {
    phase_lut[index] = static_cast<std::uint8_t>(index * 13U + 7U);
  }
  std::vector<std::byte> expected(kRm2SlotBytes);
  std::vector<std::byte> actual(kRm2SlotBytes);
  ASSERT_TRUE(fill_rm2_scan_slot(expected, 0));
  ASSERT_TRUE(fill_rm2_scan_slot(actual, 0));
  reference_encode_rm2_phase(&expected, rect, transitions, phase_lut);
  Rm2PhaseEncoder encoder;
  ASSERT_TRUE(encoder.ready());
  for (std::size_t wake = 0; wake < 4U; ++wake) {
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    ASSERT_TRUE(encoder.encode(actual, rect, transitions, phase_lut));
    EXPECT_TRUE(std::equal(actual.begin(), actual.end(), expected.begin()));
    ASSERT_TRUE(clear_rm2_phase_cells(actual, rect));
  }
}

TEST(Rm2ScanEncoder, PanBeginConfirmsWorkerEnteredBlockingOperation) {
  std::atomic<bool> callback_entered{false};
  Rm2PanWorker worker([&callback_entered](std::uint32_t slot,
                                          std::chrono::nanoseconds *duration) {
    callback_entered.store(true, std::memory_order_release);
    *duration = std::chrono::microseconds(1);
    return slot == 7U;
  });
  ASSERT_TRUE(worker.ready());

  ASSERT_TRUE(worker.begin(7U));
  EXPECT_TRUE(callback_entered.load(std::memory_order_acquire));
  Rm2PanResult result;
  ASSERT_TRUE(worker.finish(&result));
  EXPECT_TRUE(result.operation_ok);
  EXPECT_EQ(result.duration, std::chrono::microseconds(1));
}

TEST(Rm2ScanEncoder, RejectsMisalignedOrOutOfRangeWork) {
  const test::SyntheticWbf fixture = test::make_synthetic_wbf();
  WbfDecoder waveform;
  std::string error;
  ASSERT_TRUE(waveform.open(fixture.bytes, fixture.expected, &error));
  std::vector<std::byte> slot(kRm2SlotBytes);
  ASSERT_TRUE(fill_rm2_scan_slot(slot, 0));
  const std::vector<std::uint8_t> lut =
      expanded_phase(waveform, 1, 0, 0, false);
  std::vector<std::uint8_t> transitions(8, 0xffU);

  Rm2PanelRect rect{
      .row_min = 1, .row_max = 8, .column_min = 0, .column_max = 0};
  EXPECT_FALSE(encode_rm2_phase(slot, rect, transitions, lut));
  rect = {.row_min = 0, .row_max = 7, .column_min = 0, .column_max = 0};
  EXPECT_FALSE(
      encode_rm2_phase(slot, rect, std::span<const std::uint8_t>{}, lut));
  EXPECT_FALSE(encode_rm2_phase(slot, rect, transitions,
                                std::span<const std::uint8_t>{}));
}

TEST(Rm2ScanEncoder,
     Rgb565ArithmeticMatchesReferenceExhaustivelyAndPinnedHash) {
  std::size_t mismatches = 0;
  for (std::uint32_t pixel = 0; pixel <= 0xffffU; ++pixel) {
    mismatches += rgb565_to_rm2_level(static_cast<std::uint16_t>(pixel)) !=
                  arithmetic_rgb565_level(static_cast<std::uint16_t>(pixel));
  }
  EXPECT_EQ(mismatches, 0U);
  EXPECT_EQ(production_rgb565_checksum(), 0x851d793bf1575e13ULL);

  EXPECT_EQ(rgb565_to_rm2_level(0x0000U), 0U);
  EXPECT_EQ(rgb565_to_rm2_level(0xffffU), 15U);
  EXPECT_LT(rgb565_to_rm2_level(0x4208U), rgb565_to_rm2_level(0x8410U));
  EXPECT_LT(rgb565_to_rm2_level(0x8410U), rgb565_to_rm2_level(0xc618U));

  EXPECT_EQ(rm2_fast_level(0U), 0U);
  EXPECT_EQ(rm2_fast_level(7U), 0U);
  EXPECT_EQ(rm2_fast_level(8U), 15U);
  EXPECT_EQ(rm2_fast_level(15U), 15U);
}

} // namespace
} // namespace pluto::native::rm2
