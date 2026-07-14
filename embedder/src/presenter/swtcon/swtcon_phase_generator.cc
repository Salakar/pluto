#include "presenter/swtcon/swtcon_phase_generator.h"

#include <algorithm>
#include <cstring>

namespace pluto::swtcon {
namespace {

void set_error(std::string* error, const std::string& message) {
  if (error != nullptr) {
    *error = message;
  }
}

}  // namespace

std::size_t SwtconFlipSequencer::next() {
  const std::size_t current = next_index_;
  next_index_ = (next_index_ + 1U) % kActivePhaseSlots;
  return current;
}

void SwtconFlipSequencer::reset() {
  next_index_ = 0;
}

SwtconPhaseGenerator::SwtconPhaseGenerator(const SwtconWaveform* waveform)
    : waveform_(waveform) {
  reset_previous();
}

bool SwtconPhaseGenerator::generate(
    const PlutoSurface& next_surface,
    const PlutoRect* damage,
    std::size_t damage_count,
    PlutoRefreshClass refresh_class,
    float temperature_c,
    std::vector<std::uint16_t>* packed_out,
    int* phase_count_out,
    std::string* error) {
  if (packed_out == nullptr || phase_count_out == nullptr) {
    set_error(error, "null SWTCON phase output");
    return false;
  }
  if (!validate_surface(next_surface, error)) {
    return false;
  }
  if (damage == nullptr || damage_count == 0) {
    set_error(error, "SWTCON phase generation requires damage");
    return false;
  }
  for (std::size_t i = 0; i < damage_count; ++i) {
    if (!rect_valid(damage[i])) {
      set_error(error, "invalid SWTCON damage rectangle");
      return false;
    }
  }

  const SwtconUpdateMode mode = update_mode_from_refresh_class(refresh_class);
  SourceFrame frame{};
  frame.previous_pixels = previous_frame_.data();
  frame.next_pixels = next_surface.pixels;
  frame.previous_stride_bytes = kLogicalStrideBytes;
  frame.next_stride_bytes = next_surface.stride_bytes;
  frame.width = kLogicalWidth;
  frame.height = kLogicalHeight;
  frame.format = kPlutoPixelFormatRgb565;

  PhaseLookup lookup{};
  lookup.waveform = waveform_;
  lookup.mode = mode;
  lookup.temperature_c = temperature_c;

  if (!packer_.pack(frame, lookup, packed_out, error)) {
    return false;
  }
  *phase_count_out = static_cast<int>(packed_out->size() / kDrmPhaseWords);

  copy_damage_to_previous(next_surface, damage, damage_count);
  return true;
}

void SwtconPhaseGenerator::reset_previous(std::uint16_t rgb565) {
  previous_frame_.assign(kLogicalFrameBytes, 0);
  for (std::size_t i = 0; i < kLogicalFrameBytes; i += 2) {
    previous_frame_[i] = static_cast<std::uint8_t>(rgb565 & 0xffU);
    previous_frame_[i + 1] = static_cast<std::uint8_t>(rgb565 >> 8);
  }
}

bool SwtconPhaseGenerator::rect_valid(const PlutoRect& rect) {
  return rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0 &&
         rect.x <= kLogicalWidth && rect.y <= kLogicalHeight &&
         rect.width <= kLogicalWidth - rect.x &&
         rect.height <= kLogicalHeight - rect.y;
}

bool SwtconPhaseGenerator::validate_surface(const PlutoSurface& surface,
                                            std::string* error) const {
  if (surface.pixels == nullptr || surface.width != kLogicalWidth ||
      surface.height != kLogicalHeight ||
      surface.format != kPlutoPixelFormatRgb565 ||
      surface.stride_bytes < kLogicalStrideBytes) {
    set_error(error, "invalid SWTCON source surface");
    return false;
  }
  return true;
}

void SwtconPhaseGenerator::copy_damage_to_previous(
    const PlutoSurface& surface,
    const PlutoRect* damage,
    std::size_t damage_count) {
  for (std::size_t i = 0; i < damage_count; ++i) {
    const PlutoRect& rect = damage[i];
    const std::size_t row_bytes =
        static_cast<std::size_t>(rect.width) * kRgb565BytesPerPixel;
    for (int y = 0; y < rect.height; ++y) {
      const std::size_t src_offset =
          static_cast<std::size_t>(rect.y + y) * surface.stride_bytes +
          static_cast<std::size_t>(rect.x) * kRgb565BytesPerPixel;
      const std::size_t dst_offset =
          static_cast<std::size_t>(rect.y + y) * kLogicalStrideBytes +
          static_cast<std::size_t>(rect.x) * kRgb565BytesPerPixel;
      std::memcpy(previous_frame_.data() + dst_offset,
                  surface.pixels + src_offset, row_bytes);
    }
  }
}

}  // namespace pluto::swtcon
