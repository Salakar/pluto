#ifndef PLUTO_PRESENTER_SWTCON_SWTCON_CONSTANTS_H_
#define PLUTO_PRESENTER_SWTCON_SWTCON_CONSTANTS_H_

#include <cstddef>
#include <cstdint>

namespace pluto::swtcon {

inline constexpr int kLogicalWidth = 954;
inline constexpr int kLogicalHeight = 1696;
inline constexpr int kPaddedSourceWidth = 960;
inline constexpr int kPanelDpi = 264;

inline constexpr int kDrmWidth = 365;
inline constexpr int kDrmHeight = 1700;
inline constexpr int kDrmDepth = 16;
inline constexpr int kDrmBitsPerPixel = 16;
inline constexpr int kDrmBufferCount = 16;
// DU-path ring depth (proven on device). The GC16 path instead plays
// the waveform's variable N phase frames once through the kDrmBufferCount
// dumb-buffer ring.
inline constexpr int kActivePhaseSlots = 15;
// Decoded .eink geometry: 32 five-bit gray states, so each
// phase is a 32x32 transition matrix (0=black .. 31=white; slot 31 is a rail,
// real white lands ~slot 30).
inline constexpr int kGrayStates = 32;
inline constexpr int kWaveformMatrixCells = kGrayStates * kGrayStates;
inline constexpr int kFirstDataRow = 3;
inline constexpr int kTrailingControlRow = kDrmHeight - 1;
inline constexpr int kFirstDataWord = 47;
inline constexpr int kDataWordCount = 240;
inline constexpr int kLastDataWord = kFirstDataWord + kDataWordCount - 1;
inline constexpr int kPackedSourceWidth = kDataWordCount * 4;

inline constexpr std::size_t kRgb565BytesPerPixel = 2;
inline constexpr std::size_t kLogicalStrideBytes =
    static_cast<std::size_t>(kLogicalWidth) * kRgb565BytesPerPixel;
inline constexpr std::size_t kLogicalFrameBytes =
    kLogicalStrideBytes * static_cast<std::size_t>(kLogicalHeight);
inline constexpr std::size_t kDrmPhaseWords =
    static_cast<std::size_t>(kDrmWidth) * static_cast<std::size_t>(kDrmHeight);
inline constexpr std::size_t kDrmPhaseBytes =
    kDrmPhaseWords * sizeof(std::uint16_t);
inline constexpr std::size_t kPackedPhaseWords =
    kDrmPhaseWords * static_cast<std::size_t>(kActivePhaseSlots);
inline constexpr std::size_t kPackedPhaseBytes =
    kPackedPhaseWords * sizeof(std::uint16_t);

inline constexpr std::uint16_t kFrameSyncBit = 0x2000;
inline constexpr std::uint16_t kDataValidBit = 0x1000;
inline constexpr std::uint16_t kGateControlBit = 0x8000;
inline constexpr std::uint16_t kLeftEdgeControlBit = 0x4000;

inline void or_word_range(std::uint16_t* row,
                          int first_word,
                          int last_word,
                          std::uint16_t bits) {
  for (int word = first_word; word <= last_word; ++word) {
    row[word] = static_cast<std::uint16_t>(row[word] | bits);
  }
}

inline void init_blank_phase_frame(std::uint16_t* frame) {
  if (frame == nullptr) {
    return;
  }

  for (std::size_t i = 0; i < kDrmPhaseWords; ++i) {
    frame[i] = 0;
  }

  std::uint16_t* row0 = frame;
  or_word_range(row0, 1, kDrmWidth - 1, kFrameSyncBit);
  or_word_range(row0, 23, 319, kDataValidBit);

  for (int y = 1; y < kDrmHeight; ++y) {
    std::uint16_t* row =
        frame + static_cast<std::size_t>(y) * kDrmWidth;
    or_word_range(row, 1, 18, kGateControlBit);
    or_word_range(row, 23, 319, kDataValidBit);

    if (y >= kFirstDataRow) {
      row[kFirstDataWord] = static_cast<std::uint16_t>(
          row[kFirstDataWord] | kLeftEdgeControlBit);
    }
  }
}

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_SWTCON_CONSTANTS_H_
