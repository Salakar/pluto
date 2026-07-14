#ifndef PLUTO_TEST_PRESENTER_SWTCON_EINK_SYNTH_H_
#define PLUTO_TEST_PRESENTER_SWTCON_EINK_SYNTH_H_

// Builds synthetic `.eink` waveform files in the REAL on-disk format:
// XOR-0x08 obfuscation, 16-byte big-endian header, LZ payload, container
// header + two-level u24 offset tables, per-record RLE streams. Used to
// exercise the full decoder pipeline without shipping a panel file.

#include <algorithm>
#include <cassert>
#include <cstdint>
#include <vector>

#include "presenter/swtcon/swtcon_constants.h"

namespace swtcon_synth {

inline constexpr int kCells = pluto::swtcon::kWaveformMatrixCells;

// Inverse of FIELDMAP∘codeLUT: 3-bit code -> on-disk nibble. Code 7 has no
// nibble preimage (drive byte 0x0e never appears in the field map).
inline std::uint8_t nibble_for_code(std::uint8_t code) {
  switch (code & 0x7) {
    case 0:
      return 0;
    case 5:
      return 1;
    case 4:
      return 2;
    case 6:
      return 3;
    case 1:
      return 12;
    case 3:
      return 13;
    case 2:
      return 14;
  }
  assert(false && "code 7 is not encodable");
  return 0;
}

// One record's RLE stream from explicit per-cell codes (length must be a
// multiple of 1024 = phases * 32x32 cells): a single ESC literal run.
inline std::vector<std::uint8_t> record_from_codes(
    const std::vector<std::uint8_t>& codes) {
  assert(codes.size() % 2 == 0);
  std::vector<std::uint8_t> rle;
  rle.push_back(0xfc);
  for (std::size_t i = 0; i < codes.size(); i += 2) {
    const std::uint8_t low = nibble_for_code(codes[i]);
    const std::uint8_t high = nibble_for_code(codes[i + 1]);
    rle.push_back(static_cast<std::uint8_t>(low | (high << 4)));
  }
  rle.push_back(0xfc);
  rle.push_back(0xff);
  return rle;
}

// Container: 48-byte header + temp ladder, level-0/level-1 u24 offset
// tables, then the RLE records. record_for[mode * ntemp + temp] selects a
// record index (repeats exercise the shared-record/INIT layout).
inline std::vector<std::uint8_t> build_container(
    int nmode, int ntemp, const std::vector<std::uint8_t>& thresholds,
    const std::vector<std::vector<std::uint8_t>>& records,
    const std::vector<std::size_t>& record_for) {
  assert(static_cast<int>(thresholds.size()) == ntemp);
  assert(static_cast<int>(record_for.size()) == nmode * ntemp);

  const std::size_t off0 = 64;  // level-0 table location (u24 @ byte 32)
  const std::size_t level1_base = off0 + static_cast<std::size_t>(nmode) * 4;
  const std::size_t records_base =
      level1_base + static_cast<std::size_t>(nmode) * ntemp * 4;

  std::vector<std::size_t> record_offsets;
  std::size_t cursor = records_base;
  for (const auto& record : records) {
    record_offsets.push_back(cursor);
    cursor += record.size();
  }

  std::vector<std::uint8_t> de(cursor, 0);
  const auto put_u24 = [&de](std::size_t at, std::size_t value) {
    de[at] = static_cast<std::uint8_t>(value & 0xff);
    de[at + 1] = static_cast<std::uint8_t>((value >> 8) & 0xff);
    de[at + 2] = static_cast<std::uint8_t>((value >> 16) & 0xff);
  };
  put_u24(32, off0);
  de[36] = 0x05;  // elem=4 nibbles/byte, row=1024 bytes/phase (Gallery-3)
  de[37] = static_cast<std::uint8_t>(nmode - 1);
  de[38] = static_cast<std::uint8_t>(ntemp - 1);
  de[40] = 0xff;  // END
  de[41] = 0xfc;  // ESC
  for (int t = 0; t < ntemp; ++t) {
    de[48 + static_cast<std::size_t>(t)] =
        thresholds[static_cast<std::size_t>(t)];
  }
  for (int mode = 0; mode < nmode; ++mode) {
    const std::size_t level1 =
        level1_base + static_cast<std::size_t>(mode) * ntemp * 4;
    put_u24(off0 + static_cast<std::size_t>(mode) * 4, level1);
    for (int temp = 0; temp < ntemp; ++temp) {
      put_u24(level1 + static_cast<std::size_t>(temp) * 4,
              record_offsets[record_for[static_cast<std::size_t>(mode) * ntemp +
                                        temp]]);
    }
  }
  for (std::size_t i = 0; i < records.size(); ++i) {
    std::copy(records[i].begin(), records[i].end(),
              de.begin() + static_cast<std::ptrdiff_t>(record_offsets[i]));
  }
  return de;
}

// Wraps a container into a complete .eink file: LZ pure-literal records
// (offset=0, count=0), big-endian header, XOR 0x08.
inline std::vector<std::uint8_t> wrap_eink(
    const std::vector<std::uint8_t>& container) {
  std::vector<std::uint8_t> payload;
  payload.reserve(container.size() * 4);
  for (std::uint8_t byte : container) {
    payload.push_back(0);
    payload.push_back(0);
    payload.push_back(0);
    payload.push_back(byte);
  }
  std::vector<std::uint8_t> file(16, 0);
  const std::size_t len = payload.size();
  file[0] = static_cast<std::uint8_t>((len >> 24) & 0xff);
  file[1] = static_cast<std::uint8_t>((len >> 16) & 0xff);
  file[2] = static_cast<std::uint8_t>((len >> 8) & 0xff);
  file[3] = static_cast<std::uint8_t>(len & 0xff);
  file[7] = 1;  // version (big-endian u32 @ 4)
  file[9] = 2;  // type tag
  file.insert(file.end(), payload.begin(), payload.end());
  for (std::uint8_t& byte : file) {
    byte = static_cast<std::uint8_t>(byte ^ 0x08);
  }
  return file;
}

// Ready-made 3-mode x 2-temp waveform. Mode 2 (the presenter's Full/GC16
// mode index) has `phases` phases with code(cell, phase) = (cell + phase) % 7
// — fully predictable for packer/presenter tests. Modes 0 and 1 share one
// single-phase all-hold record across both temp bins (dedup coverage).
inline std::vector<std::uint8_t> make_synthetic_eink(int phases = 3) {
  const int nmode = 3;
  const int ntemp = 2;
  std::vector<std::uint8_t> hold(kCells, 0);
  std::vector<std::uint8_t> mode2_codes(static_cast<std::size_t>(phases) *
                                        kCells);
  for (int phase = 0; phase < phases; ++phase) {
    for (int cell = 0; cell < kCells; ++cell) {
      mode2_codes[static_cast<std::size_t>(phase) * kCells + cell] =
          static_cast<std::uint8_t>((cell + phase) % 7);
    }
  }
  const std::vector<std::vector<std::uint8_t>> records = {
      record_from_codes(hold), record_from_codes(mode2_codes)};
  // modes 0/1 -> record 0 (all temps); mode 2 -> record 1 (all temps)
  const std::vector<std::size_t> record_for = {0, 0, 0, 0, 1, 1};
  return wrap_eink(build_container(nmode, ntemp, {0, 20}, records, record_for));
}

inline std::uint8_t synthetic_mode2_code(int cell, int phase) {
  return static_cast<std::uint8_t>((cell + phase) % 7);
}

}  // namespace swtcon_synth

#endif  // PLUTO_TEST_PRESENTER_SWTCON_EINK_SYNTH_H_
