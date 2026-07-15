#include "presenter/native/rm2/rm2_scan_encoder.h"

#include <algorithm>
#include <cstring>

namespace pluto::native::rm2 {
namespace {

constexpr std::size_t kCellsPerLine = kRm2ScanoutStrideBytes / 4;
constexpr std::size_t kPreambleRows = 4;
constexpr std::size_t kFirstPixelCell = 26;

bool rect_valid(const Rm2PanelRect &rect) {
  return rect.row_min <= rect.row_max && rect.column_min <= rect.column_max &&
         rect.row_max < kRm2PanelHeight && rect.column_max < kRm2PanelWidth &&
         (rect.row_min & 7U) == 0 && (rect.row_max & 7U) == 7U;
}

std::uint32_t read_u32(std::span<const std::byte> bytes, std::size_t offset) {
  std::uint32_t value = 0;
  std::memcpy(&value, bytes.data() + offset, sizeof(value));
  return value;
}

void write_u32(std::span<std::byte> bytes, std::size_t offset,
               std::uint32_t value) {
  std::memcpy(bytes.data() + offset, &value, sizeof(value));
}

std::uint32_t preamble_cell(std::size_t cell) {
  std::uint32_t value = 0x00430000U;
  if (cell >= 20 && cell < 143) {
    value |= 0x00040000U;
  }
  if (cell >= 40 && cell < 103) {
    value &= ~0x00020000U;
  }
  return value;
}

std::uint32_t regular_cell(std::size_t cell, bool content,
                           std::uint16_t drive_pattern) {
  std::uint32_t value = 0x00410000U;
  if (cell >= 8 && cell < 19) {
    value |= 0x00200000U;
  }
  if (cell >= 55 && cell < 255) {
    value |= 0x00020000U;
  }
  if (content && cell >= 26) {
    value |= 0x00100000U | drive_pattern;
  }
  return value;
}

void fill_regular_line(std::span<std::byte> slot, std::size_t row, bool content,
                       std::uint16_t drive_pattern) {
  const std::size_t base = row * kRm2ScanoutStrideBytes;
  for (std::size_t cell = 0; cell < kCellsPerLine; ++cell) {
    write_u32(slot, base + cell * sizeof(std::uint32_t),
              regular_cell(cell, content, drive_pattern));
  }
}

} // namespace

bool fill_rm2_scan_slot(std::span<std::byte> slot,
                        std::uint16_t drive_pattern) {
  if (slot.size() != kRm2SlotBytes) {
    return false;
  }

  for (std::size_t cell = 0; cell < kCellsPerLine; ++cell) {
    write_u32(slot, cell * sizeof(std::uint32_t), preamble_cell(cell));
  }
  fill_regular_line(slot, 1, false, 0);
  fill_regular_line(slot, 2, false, 0);
  for (std::size_t row = 3; row < kRm2ScanoutHeight; ++row) {
    fill_regular_line(slot, row, true, drive_pattern);
  }
  return true;
}

bool rm2_scan_slot_is_safe_hold(std::span<const std::byte> slot) {
  if (slot.size() != kRm2SlotBytes) {
    return false;
  }
  for (std::size_t row = 0; row < kRm2ScanoutHeight; ++row) {
    const bool preamble = row == 0;
    const bool content = row >= 3;
    const std::size_t base = row * kRm2ScanoutStrideBytes;
    for (std::size_t cell = 0; cell < kCellsPerLine; ++cell) {
      const std::uint32_t expected =
          preamble ? preamble_cell(cell) : regular_cell(cell, content, 0);
      if (read_u32(slot, base + cell * sizeof(std::uint32_t)) != expected) {
        return false;
      }
    }
  }
  return true;
}

bool encode_rm2_phase(std::span<std::byte> slot, const Rm2PanelRect &rect,
                      std::span<const std::uint8_t> transition_keys,
                      std::span<const std::uint8_t> phase_lut) {
  if (slot.size() != kRm2SlotBytes || !rect_valid(rect) ||
      transition_keys.size() != rect.row_count() * rect.column_count() ||
      phase_lut.size() != 16U * 16U) {
    return false;
  }

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
      const std::size_t offset =
          scan_line * kRm2ScanoutStrideBytes + cell * sizeof(std::uint32_t);
      const std::uint32_t existing = read_u32(slot, offset);
      write_u32(slot, offset, (existing & 0xffff0000U) | packed);
    }
  }
  return true;
}

bool clear_rm2_phase_cells(std::span<std::byte> slot,
                           const Rm2PanelRect &rect) {
  if (slot.size() != kRm2SlotBytes || !rect_valid(rect)) {
    return false;
  }
  for (std::uint32_t column = rect.column_min; column <= rect.column_max;
       ++column) {
    const std::size_t scan_line = kPreambleRows + column;
    for (std::uint32_t row = rect.row_min; row <= rect.row_max; row += 8U) {
      const std::size_t cell = kFirstPixelCell + (row >> 3U);
      const std::size_t offset =
          scan_line * kRm2ScanoutStrideBytes + cell * sizeof(std::uint32_t);
      const std::uint32_t existing = read_u32(slot, offset);
      write_u32(slot, offset, existing & 0xffff0000U);
    }
  }
  return true;
}

} // namespace pluto::native::rm2
