#include "presenter/swtcon/swtcon_packer.h"

#include <algorithm>
#include <array>
#include <cstring>

namespace pluto::swtcon {
namespace {

void set_error(std::string* error, const std::string& message) {
  if (error != nullptr) {
    *error = message;
  }
}

std::uint16_t load_rgb565(const std::uint8_t* row, int x) {
  const auto offset = static_cast<std::size_t>(x) * sizeof(std::uint16_t);
  return static_cast<std::uint16_t>(row[offset] |
                                   (static_cast<std::uint16_t>(row[offset + 1])
                                    << 8));
}

// Proven from packer 0xa565c0: the pixel field is 3-bit, 4 pixels per
// 16-bit word in bits[11:0]; the leftmost pixel of the group of 4 occupies
// bits[11:9] (shift = 9 - 3*lane), the rightmost bits[2:0]. Control bits live
// in bits[15:12] with ZERO overlap, so a lane write must never touch them.
constexpr int kPhaseCodeBits = 3;
constexpr std::uint16_t kPhaseCodeMask = 0x7;

int lane_shift(int lane) { return 9 - kPhaseCodeBits * lane; }

std::uint16_t lane_mask(int lane) {
  return static_cast<std::uint16_t>(kPhaseCodeMask << lane_shift(lane));
}

void store_phase_code(std::uint16_t* frame,
                      std::size_t word_index,
                      int lane,
                      std::uint8_t phase_value) {
  const int shift = lane_shift(lane);
  const std::uint16_t mask = lane_mask(lane);
  // Clear only this lane's 3 pixel bits, then OR the 3-bit drive code. The
  // control bits set by init_blank_phase_frame (0x1000/0x2000/0x4000/0x8000)
  // are untouched — clobbering them freezes the panel's frame-sync/gate scan
  // (the raw-fill failure), so they must survive every data-word write.
  frame[word_index] = static_cast<std::uint16_t>(
      (frame[word_index] & ~mask) |
      (static_cast<std::uint16_t>(phase_value & kPhaseCodeMask) << shift));
}

}  // namespace

bool SwtconPacker::pack(const SourceFrame& source,
                        const PhaseLookup& lookup,
                        std::vector<std::uint16_t>* rg16_out,
                        std::string* error) const {
  if (source.previous_pixels == nullptr || source.next_pixels == nullptr ||
      rg16_out == nullptr) {
    set_error(error, "null SWTCON packer buffer");
    return false;
  }
  if (source.format != kPlutoPixelFormatRgb565 ||
      source.width < kLogicalWidth || source.height < kLogicalHeight ||
      source.previous_stride_bytes <
          static_cast<std::size_t>(kLogicalWidth) * sizeof(std::uint16_t) ||
      source.next_stride_bytes <
          static_cast<std::size_t>(kLogicalWidth) * sizeof(std::uint16_t)) {
    set_error(error, "invalid SWTCON packer source frame");
    return false;
  }

  const int phase_count = lookup.phase_count();
  if (phase_count <= 0) {
    set_error(error, "SWTCON lookup has no phases (no decoded waveform)");
    return false;
  }

  // One 1024-entry code table per phase (index dst5*32+src5), either decoded
  // from the .eink or a constant table for the fixed-value diagnostic path.
  std::array<std::uint8_t, kWaveformMatrixCells> fixed_table{};
  std::vector<const std::uint8_t*> phase_tables(
      static_cast<std::size_t>(phase_count));
  if (lookup.use_fixed_phase_value) {
    fixed_table.fill(
        static_cast<std::uint8_t>(lookup.fixed_phase_value & kPhaseCodeMask));
    std::fill(phase_tables.begin(), phase_tables.end(), fixed_table.data());
  } else {
    for (int phase = 0; phase < phase_count; ++phase) {
      const std::uint8_t* table = lookup.phase_table(phase);
      if (table == nullptr) {
        set_error(error, "SWTCON waveform phase table missing");
        return false;
      }
      phase_tables[static_cast<std::size_t>(phase)] = table;
    }
  }

  rg16_out->assign(
      static_cast<std::size_t>(phase_count) * kDrmPhaseWords, 0);
  for (int phase = 0; phase < phase_count; ++phase) {
    init_blank_phase_frame(rg16_out->data() +
                           static_cast<std::size_t>(phase) * kDrmPhaseWords);
  }

  for (int y = 0; y < kLogicalHeight; ++y) {
    const std::uint8_t* previous_row =
        source.previous_pixels +
        static_cast<std::size_t>(y) * source.previous_stride_bytes;
    const std::uint8_t* next_row =
        source.next_pixels +
        static_cast<std::size_t>(y) * source.next_stride_bytes;

    for (int x = 0; x < kLogicalWidth; ++x) {
      const std::uint8_t src = rgb565_to_gray5(load_rgb565(previous_row, x));
      const std::uint8_t dst = rgb565_to_gray5(load_rgb565(next_row, x));
      // Transition axis is transposed in the decoded matrices.
      const std::size_t cell =
          static_cast<std::size_t>(dst) * kGrayStates + src;
      const std::size_t word_index =
          static_cast<std::size_t>(y + kFirstDataRow) * kDrmWidth +
          kFirstDataWord + static_cast<std::size_t>(x / 4);
      const int lane = x % 4;

      for (int phase = 0; phase < phase_count; ++phase) {
        std::uint16_t* frame =
            rg16_out->data() + static_cast<std::size_t>(phase) * kDrmPhaseWords;
        store_phase_code(frame, word_index, lane,
                         phase_tables[static_cast<std::size_t>(phase)][cell]);
      }
    }

    for (int x = kLogicalWidth; x < kPackedSourceWidth; ++x) {
      const std::size_t word_index =
          static_cast<std::size_t>(y + kFirstDataRow) * kDrmWidth +
          kFirstDataWord + static_cast<std::size_t>(x / 4);
      const int lane = x % 4;
      for (int phase = 0; phase < phase_count; ++phase) {
        std::uint16_t* frame =
            rg16_out->data() + static_cast<std::size_t>(phase) * kDrmPhaseWords;
        store_phase_code(frame, word_index, lane, 0);
      }
    }
  }
  return true;
}

}  // namespace pluto::swtcon
