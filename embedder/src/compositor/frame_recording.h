#ifndef PLUTO_SRC_COMPOSITOR_FRAME_RECORDING_H_
#define PLUTO_SRC_COMPOSITOR_FRAME_RECORDING_H_

#include <cstddef>
#include <cstdint>

namespace pluto::frame_recording {

constexpr std::uint32_t kFileMagic = 0x52464c50u;  // "PLFR"
constexpr std::uint32_t kFrameMagic = 0x304d5246u; // "FRM0"
constexpr std::uint32_t kMinimumFrameBytes = 44u;
constexpr std::uint32_t kMaximumFrameBytes = 128u * 1024u * 1024u;
constexpr std::uint32_t kCrc32Initial = 0xffffffffu;

inline std::uint32_t crc32_update(std::uint32_t state, const void *data,
                                  std::size_t size) {
  const auto *bytes = static_cast<const std::uint8_t *>(data);
  for (std::size_t i = 0; i < size; ++i) {
    state ^= bytes[i];
    for (int bit = 0; bit < 8; ++bit) {
      const std::uint32_t mask = 0u - (state & 1u);
      state = (state >> 1u) ^ (0xedb88320u & mask);
    }
  }
  return state;
}

constexpr std::uint32_t crc32_finish(std::uint32_t state) {
  return state ^ 0xffffffffu;
}

inline std::uint32_t crc32(const void *data, std::size_t size) {
  return crc32_finish(crc32_update(kCrc32Initial, data, size));
}

} // namespace pluto::frame_recording

#endif // PLUTO_SRC_COMPOSITOR_FRAME_RECORDING_H_
