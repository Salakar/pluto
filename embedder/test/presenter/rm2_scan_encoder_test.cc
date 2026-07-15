#include "presenter/native/rm2/rm2_scan_encoder.h"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
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

TEST(Rm2ScanEncoder, GeneratedRgb565LutHasPinnedEndpointsAndGrayOrdering) {
  EXPECT_EQ(rgb565_to_rm2_level(0x0000U), 0U);
  EXPECT_EQ(rgb565_to_rm2_level(0xffffU), 15U);
  EXPECT_LT(rgb565_to_rm2_level(0x4208U), rgb565_to_rm2_level(0x8410U));
  EXPECT_LT(rgb565_to_rm2_level(0x8410U), rgb565_to_rm2_level(0xc618U));
}

} // namespace
} // namespace pluto::native::rm2
