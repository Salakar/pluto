#include "presenter/swtcon/swtcon_waveform.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <fstream>
#include <iterator>
#include <utility>

#if defined(__ARM_NEON) && defined(__aarch64__)
#include <arm_neon.h>
#endif

namespace pluto::swtcon {
namespace {

// Constants pulled byte-exact from xochitl .rodata.
// codeLUT @ 0x141bd58: drive byte -> 3-bit hardware code, idx = (b>>1)&7.
constexpr std::array<std::uint8_t, 8> kCodeLut = {0, 1, 3, 2, 5, 4, 6, 7};
// nibble field map @ 0x1556c8d: on-disk nibble -> drive byte.
constexpr std::array<std::uint8_t, 16> kFieldMap = {
    0x00, 0x08, 0x0a, 0x0c, 0, 0, 0, 0, 0, 0, 0, 0, 0x02, 0x04, 0x06, 0x00};

constexpr std::size_t kEinkHeaderBytes = 16;
constexpr std::size_t kContainerHeaderBytes = 48;
constexpr std::size_t kDecompressLimit = std::size_t{1} << 20;  // 0xde0038 cap
constexpr std::size_t kRecordLimit = std::size_t{1} << 20;

void set_error(std::string* error, const std::string& message) {
  if (error != nullptr) {
    *error = message;
  }
}

std::uint32_t read_u24le(const std::vector<std::uint8_t>& data,
                         std::size_t offset) {
  return static_cast<std::uint32_t>(data[offset]) |
         (static_cast<std::uint32_t>(data[offset + 1]) << 8) |
         (static_cast<std::uint32_t>(data[offset + 2]) << 16);
}

std::uint32_t read_u32be(const std::vector<std::uint8_t>& data,
                         std::size_t offset) {
  return (static_cast<std::uint32_t>(data[offset]) << 24) |
         (static_cast<std::uint32_t>(data[offset + 1]) << 16) |
         (static_cast<std::uint32_t>(data[offset + 2]) << 8) |
         static_cast<std::uint32_t>(data[offset + 3]);
}

// RLE expander (0xddf740, elem=4 path): emits the 3-bit codes directly
// (drive byte -> codeLUT) instead of the intermediate drive bytes; the drive
// bytes are only ever consumed through the codeLUT.
bool expand_record(const std::vector<std::uint8_t>& de, std::size_t pos,
                   std::uint8_t end_byte, std::uint8_t esc_byte,
                   std::vector<std::uint8_t>* out, std::string* error) {
  out->clear();
  const std::size_t size = de.size();
  const auto emit = [out](std::uint8_t nibble) {
    const std::uint8_t drive = kFieldMap[nibble & 0x0f];
    out->push_back(kCodeLut[(drive >> 1) & 7]);
  };
  std::size_t p = pos;
  for (;;) {
    if (p >= size) {
      set_error(error, ".eink RLE record runs off the container");
      return false;
    }
    const std::uint8_t d = de[p];
    if (d == end_byte) {  // end of record (data position only)
      break;
    }
    if (d == esc_byte) {  // literal run until the next escape byte
      ++p;
      for (;;) {
        if (p >= size) {
          set_error(error, ".eink RLE literal run unterminated");
          return false;
        }
        const std::uint8_t literal = de[p++];
        if (literal == esc_byte) {
          break;
        }
        emit(literal & 0x0f);
        emit(literal >> 4);
      }
      continue;
    }
    if (p + 1 >= size) {
      set_error(error, ".eink RLE pair truncated");
      return false;
    }
    const std::uint8_t run = de[p + 1];
    p += 2;
    for (int i = 0; i <= run; ++i) {  // 2*(run+1) alternating nibbles
      emit(d & 0x0f);
      emit(d >> 4);
    }
    if (out->size() > kRecordLimit) {
      set_error(error, ".eink RLE record exceeds size limit");
      return false;
    }
  }
  if (out->empty() || (out->size() % kWaveformMatrixCells) != 0) {
    set_error(error, ".eink record is not a whole number of phases");
    return false;
  }
  return true;
}

}  // namespace

bool eink_lz_decompress(const std::uint8_t* payload, std::size_t size,
                        std::vector<std::uint8_t>* out, std::string* error) {
  if (payload == nullptr || out == nullptr) {
    set_error(error, "null LZ decompress buffer");
    return false;
  }
  out->clear();
  for (std::size_t i = 0; i < size; i += 4) {
    // Mirrors decode_eink.py: fields past the end read as zero.
    const std::uint8_t b0 = payload[i];
    const std::uint8_t b1 = i + 1 < size ? payload[i + 1] : 0;
    const std::uint8_t count = i + 2 < size ? payload[i + 2] : 0;
    const std::uint8_t literal = i + 3 < size ? payload[i + 3] : 0;
    const std::size_t offset =
        static_cast<std::size_t>(b0) | (static_cast<std::size_t>(b1) << 8);
    if (count > 0 && (offset == 0 || offset > out->size())) {
      set_error(error, ".eink LZ back-reference outside output");
      return false;
    }
    std::size_t src = out->size() - offset;
    for (int c = 0; c < count; ++c) {
      if (out->size() >= kDecompressLimit) {
        set_error(error, ".eink LZ decompress overflow");
        return false;
      }
      out->push_back((*out)[src]);
      ++src;
    }
    if (out->size() < kDecompressLimit) {
      out->push_back(literal);
    }
  }
  return true;
}

void WaveformTable::clear() {
  records_.clear();
  record_index_.clear();
  thresholds_.clear();
  nmode_ = 0;
  ntemp_ = 0;
  valid_ = false;
}

bool WaveformTable::parse(const std::vector<std::uint8_t>& file_bytes,
                          std::string* error) {
  clear();
  if (file_bytes.size() < kEinkHeaderBytes) {
    set_error(error, ".eink file shorter than its header");
    return false;
  }

  // Stage 1: deobfuscate (XOR 0x08, 0xddfa58) + big-endian header.
  std::vector<std::uint8_t> plain(file_bytes.size());
  for (std::size_t i = 0; i < file_bytes.size(); ++i) {
    plain[i] = static_cast<std::uint8_t>(file_bytes[i] ^ 0x08);
  }
  const std::uint32_t payload_len = read_u32be(plain, 0);
  const std::uint32_t version = read_u32be(plain, 4);
  const std::uint8_t type_tag = plain[9];
  if (version != 1 || type_tag != 2 ||
      payload_len != plain.size() - kEinkHeaderBytes) {
    set_error(error, ".eink header mismatch (version/type/payload length)");
    return false;
  }

  // Stage 2: LZ decompress the payload into the container buffer.
  std::vector<std::uint8_t> de;
  if (!eink_lz_decompress(plain.data() + kEinkHeaderBytes, payload_len, &de,
                          error)) {
    return false;
  }

  // Stage 3: container header (0xddf630) + two-level offset table (0xddf550).
  if (de.size() < kContainerHeaderBytes) {
    set_error(error, ".eink container shorter than its header");
    return false;
  }
  const std::uint32_t off0 = read_u24le(de, 32);
  const std::uint8_t flags = de[36];
  const int nmode = de[37] + 1;
  const int ntemp = de[38] + 1;
  const std::uint8_t end_byte = de[40];
  const std::uint8_t esc_byte = de[41];
  // Gallery-3 layout: elem=4 (two nibbles/byte), row=1024 bytes/phase. A
  // different panel would need the other 0xddf854 field paths.
  if ((flags & 3) != 1 || ((flags >> 2) & 3) != 1) {
    set_error(error, ".eink container flags are not the Gallery-3 layout");
    return false;
  }
  if (de.size() < kContainerHeaderBytes + static_cast<std::size_t>(ntemp)) {
    set_error(error, ".eink container temp ladder truncated");
    return false;
  }
  thresholds_.assign(de.begin() + kContainerHeaderBytes,
                     de.begin() + kContainerHeaderBytes + ntemp);

  // Stage 4: expand every (mode,temp) record, deduped by container offset.
  std::map<std::uint32_t, std::size_t> record_by_offset;
  record_index_.assign(static_cast<std::size_t>(nmode) * ntemp, 0);
  for (int mode = 0; mode < nmode; ++mode) {
    const std::size_t level0 = off0 + static_cast<std::size_t>(mode) * 4;
    if (level0 + 3 > de.size()) {
      set_error(error, ".eink level-0 offset table truncated");
      return false;
    }
    const std::uint32_t level1 = read_u24le(de, level0);
    for (int temp = 0; temp < ntemp; ++temp) {
      const std::size_t entry = level1 + static_cast<std::size_t>(temp) * 4;
      if (entry + 3 > de.size()) {
        set_error(error, ".eink level-1 offset table truncated");
        return false;
      }
      const std::uint32_t record_offset = read_u24le(de, entry);
      auto found = record_by_offset.find(record_offset);
      if (found == record_by_offset.end()) {
        Record record;
        if (!expand_record(de, record_offset, end_byte, esc_byte, &record.codes,
                           error)) {
          return false;
        }
        record.phase_count =
            static_cast<int>(record.codes.size() / kWaveformMatrixCells);
        records_.push_back(std::move(record));
        found =
            record_by_offset.emplace(record_offset, records_.size() - 1).first;
      }
      record_index_[static_cast<std::size_t>(mode) * ntemp + temp] =
          found->second;
    }
  }

  nmode_ = nmode;
  ntemp_ = ntemp;
  valid_ = true;
  return true;
}

int WaveformTable::temp_bin(float temperature_c) const {
  if (!valid_ || ntemp_ <= 0) {
    return 0;
  }
  int bin = 0;
  // Preserve Xochitl's ordered-FP behavior: NaN and -inf select record 0;
  // +inf advances to the last record.
  for (int i = 1; i < ntemp_; ++i) {
    if (temperature_c >=
        static_cast<float>(thresholds_[static_cast<std::size_t>(i)])) {
      bin = i;
    } else {
      break;
    }
  }
  return bin;
}

const WaveformTable::Record* WaveformTable::record(int mode,
                                                   int temp_bin) const {
  if (!valid_ || mode < 0 || mode >= nmode_ || temp_bin < 0 ||
      temp_bin >= ntemp_) {
    return nullptr;
  }
  return &records_[record_index_[static_cast<std::size_t>(mode) * ntemp_ +
                                 temp_bin]];
}

int WaveformTable::phase_count(int mode, int temp_bin) const {
  const Record* found = record(mode, temp_bin);
  return found != nullptr ? found->phase_count : 0;
}

const std::uint8_t* WaveformTable::phase_table(int mode, int temp_bin,
                                               int phase) const {
  const Record* found = record(mode, temp_bin);
  if (found == nullptr || phase < 0 || phase >= found->phase_count) {
    return nullptr;
  }
  return found->codes.data() +
         static_cast<std::size_t>(phase) * kWaveformMatrixCells;
}

std::span<const std::uint8_t> WaveformTable::phase_record_codes(
    int mode, int temp_bin) const {
  const Record* found = record(mode, temp_bin);
  if (found == nullptr) {
    return {};
  }
  return found->codes;
}

std::uint8_t WaveformTable::code(int mode, int temp_bin, std::uint8_t src,
                                 std::uint8_t dst, int phase) const {
  const std::uint8_t* table = phase_table(mode, temp_bin, phase);
  if (table == nullptr) {
    return 0;
  }
  return table[static_cast<std::size_t>(dst & 0x1f) * kGrayStates +
               (src & 0x1f)];
}

bool RealWaveformFileReader::read_file(const std::string& path,
                                       std::vector<std::uint8_t>* out,
                                       std::string* error) const {
  if (out == nullptr) {
    set_error(error, "null waveform output");
    return false;
  }
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    set_error(error, "unable to open waveform file: " + path);
    return false;
  }
  out->assign(std::istreambuf_iterator<char>(in),
              std::istreambuf_iterator<char>());
  if (out->empty()) {
    set_error(error, "waveform file is empty: " + path);
    return false;
  }
  return true;
}

bool SwtconWaveform::load(const Files& files, const WaveformFileReader& reader,
                          std::string* error) {
  loaded_ = false;
  eink_bytes_.clear();
  ct33_bytes_.clear();
  table_.clear();

  if (!files.eink_path.empty() &&
      !reader.read_file(files.eink_path, &eink_bytes_, error)) {
    return false;
  }
  if (!eink_bytes_.empty() && !table_.parse(eink_bytes_, error)) {
    return false;
  }

  const std::array<std::pair<const char*, const std::string*>, 4> ct33_files{{
      {"std", &files.ct33_std_path},
      {"best", &files.ct33_best_path},
      {"pen", &files.ct33_pen_path},
      {"fast", &files.ct33_fast_path},
  }};
  for (const auto& entry : ct33_files) {
    if (entry.second == nullptr || entry.second->empty()) {
      continue;
    }
    // ct33 blobs are optional: they feed the future colour front-end, never
    // the drive path, so a missing file must not block the drive table.
    std::vector<std::uint8_t> bytes;
    std::string ct33_error;
    if (reader.read_file(*entry.second, &bytes, &ct33_error)) {
      ct33_bytes_.emplace(entry.first, std::move(bytes));
    }
  }
  loaded_ = !eink_bytes_.empty() || !ct33_bytes_.empty();
  if (!loaded_) {
    set_error(error, "no waveform files configured");
    return false;
  }
  return true;
}

PhaseSequence SwtconWaveform::lookup(SwtconUpdateMode mode, std::uint8_t src,
                                     std::uint8_t dst,
                                     float temperature_c) const {
  PhaseSequence sequence{};
  if (!table_.valid()) {
    return sequence;
  }
  const int mode_index = waveform_mode_index(mode);
  const int bin = table_.temp_bin(temperature_c);
  const int phases = table_.phase_count(mode_index, bin);
  sequence.values.resize(static_cast<std::size_t>(phases));
  for (int phase = 0; phase < phases; ++phase) {
    sequence.values[static_cast<std::size_t>(phase)] =
        table_.code(mode_index, bin, src, dst, phase);
  }
  sequence.from_waveform = true;
  return sequence;
}

int PhaseLookup::phase_count() const {
  if (use_fixed_phase_value) {
    return kActivePhaseSlots;
  }
  if (waveform == nullptr || !waveform->table().valid()) {
    return 0;
  }
  const WaveformTable& table = waveform->table();
  return table.phase_count(waveform_mode_index(mode),
                           table.temp_bin(temperature_c));
}

const std::uint8_t* PhaseLookup::phase_table(int phase) const {
  if (use_fixed_phase_value || waveform == nullptr ||
      !waveform->table().valid()) {
    return nullptr;
  }
  const WaveformTable& table = waveform->table();
  return table.phase_table(waveform_mode_index(mode),
                           table.temp_bin(temperature_c), phase);
}

PhaseSequence PhaseLookup::phase_values(std::uint8_t src,
                                        std::uint8_t dst) const {
  if (use_fixed_phase_value) {
    PhaseSequence sequence{};
    sequence.values.assign(kActivePhaseSlots,
                           static_cast<std::uint8_t>(fixed_phase_value & 0x7U));
    return sequence;
  }
  if (waveform != nullptr) {
    return waveform->lookup(mode, src, dst, temperature_c);
  }
  return PhaseSequence{};
}

SwtconUpdateMode update_mode_from_refresh_class(
    PlutoRefreshClass refresh_class) {
  switch (refresh_class) {
    case kPlutoRefreshFast:
      return SwtconUpdateMode::kFast;
    case kPlutoRefreshUi:
      return SwtconUpdateMode::kUi;
    case kPlutoRefreshText:
      return SwtconUpdateMode::kText;
    case kPlutoRefreshFull:
      return SwtconUpdateMode::kFull;
  }
  return SwtconUpdateMode::kUi;
}

int waveform_mode_index(SwtconUpdateMode mode) {
  switch (mode) {
    case SwtconUpdateMode::kFast:
      return 7;  // stronger fast/partial mode; mode 8 under-drives UI on rM.
    case SwtconUpdateMode::kUi:
      return 7;  // fast/partial (N=11)
    case SwtconUpdateMode::kText:
      return 1;  // non-flash GL16-family
    case SwtconUpdateMode::kFull:
      return 2;  // first flashing GC16-family mode after INIT
  }
  return 2;
}

// Luma -> level tone curve: round(30 * (luma/255)^1.8), the ink-darkening
// gamma for e-paper. Flutter composites in gamma-encoded sRGB, and mapping
// that value LINEARLY onto the reflectance lattice rendered anti-aliased
// glyph edges ~1.5 stops too light — text drawn crisp by the bilevel rail
// preview (mode 7 legalizes mid-grays toward black) then visibly faded and
// thinned when the quality pass re-presented the true grays on device.
// Exponent 1.8 rather than the full sRGB 2.2/2.4: with only 8 GL16
// lattice steps below white, the steeper curve crushes all shadow
// detail into level 0. Endpoints are exact by construction: 0 -> 0,
// 255 -> 30 (paper white; slot 31 stays the never-produced waveform rail —
// see build_legal_target_map on why dst=31 is optically inert).
//
// Domain note: this curve lives at the PRESENTER conversion because on the
// swtcon device path the mirror is engine-true (raw app pixels reach the
// presenter, so this IS content ingest, and re-presents of unchanged bytes
// stay idempotent by construction). Surfaces that carry pre-quantized
// lattice grays (mono/bridge-quantized paths) get the same deterministic
// mapping; the old linear lattice round-trip identity no longer holds.
inline constexpr std::array<std::uint8_t, 256> k_gray5_tone = {
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    0,  0,  0,  0,  0,  0,  0,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,
    1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  2,  2,  2,  2,  2,  2,  2,  2,
    2,  2,  2,  2,  2,  2,  2,  2,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,  3,
    3,  3,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  4,  5,  5,  5,  5,  5,  5,
    5,  5,  5,  5,  5,  6,  6,  6,  6,  6,  6,  6,  6,  6,  6,  7,  7,  7,  7,
    7,  7,  7,  7,  7,  8,  8,  8,  8,  8,  8,  8,  8,  9,  9,  9,  9,  9,  9,
    9,  9,  10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 12, 12,
    12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14,
    15, 15, 15, 15, 15, 15, 16, 16, 16, 16, 16, 16, 17, 17, 17, 17, 17, 17, 17,
    18, 18, 18, 18, 18, 19, 19, 19, 19, 19, 19, 20, 20, 20, 20, 20, 20, 21, 21,
    21, 21, 21, 22, 22, 22, 22, 22, 22, 23, 23, 23, 23, 23, 24, 24, 24, 24, 24,
    25, 25, 25, 25, 25, 26, 26, 26, 26, 26, 26, 27, 27, 27, 27, 28, 28, 28, 28,
    28, 29, 29, 29, 29, 29, 30, 30, 30,
};

std::uint8_t rgb565_to_gray5(std::uint16_t rgb565) {
  const int r5 = (rgb565 >> 11) & 0x1f;
  const int g6 = (rgb565 >> 5) & 0x3f;
  const int b5 = rgb565 & 0x1f;
  const int r8 = (r5 << 3) | (r5 >> 2);
  const int g8 = (g6 << 2) | (g6 >> 4);
  const int b8 = (b5 << 3) | (b5 >> 2);
  const int luma = (r8 * 30 + g8 * 59 + b8 * 11 + 50) / 100;
  // Denominator 30, NOT 31: the renderer's 5-bit lattice puts paper white at
  // level 30 (kernels.h level5_to_gray8, (i*255+15)/30) and slot 31 is the
  // waveform rail — real tables carry NO drive codes into dst=31 (GAL3: the
  // ->31 column is hold in every mode), so quantizing white to 31 makes
  // every black->white erase optically inert and then latches prev=31,
  // silencing all later white drives.
  return k_gray5_tone[luma & 0xff];
}

void convert_rgb565_levels_scalar(const std::uint8_t* src,
                                  std::size_t src_stride_bytes,
                                  std::int32_t width, std::int32_t height,
                                  const std::uint8_t* legal_targets,
                                  std::uint8_t* out) {
  for (std::int32_t y = 0; y < height; ++y) {
    const std::uint8_t* row =
        src + static_cast<std::size_t>(y) * src_stride_bytes;
    std::uint8_t* dst =
        out + static_cast<std::size_t>(y) * static_cast<std::size_t>(width);
    for (std::int32_t x = 0; x < width; ++x) {
      const std::uint16_t px = static_cast<std::uint16_t>(
          row[x * 2] | (static_cast<std::uint16_t>(row[x * 2 + 1]) << 8));
      dst[x] = legal_targets[rgb565_to_gray5(px) & 0x1f];
    }
  }
}

#if defined(__ARM_NEON) && defined(__aarch64__)
namespace {

// rgb565_to_gray5's /100 division is replaced by a multiply-high-shift twin
// that is EXACT over the scalar's full numerator range (proven exhaustively
// offline, and pinned end-to-end for all 65536 rgb565 inputs by
// ConvertLevelsNeonGolden.*Exhaustive*). vqdmulh computes
// sat((2*a*b) >> 16); the product stays < 2^31 so it never saturates, and
// a truncating shift of a nonnegative value is floor, so:
//   floor(n / 100) == vqdmulh(n, 20972) >> 6   for n <= 25550 (luma
//                     numerator max 255*30 + 255*59 + 255*11 + 50)
// The luma -> level step is the k_gray5_tone table (nonlinear; no
// arithmetic twin exists), looked up in four vqtbl4q segments below.

// num / 100 for 8 u16 numerator lanes (each <= 25550) -> luma <= 255.
inline uint16x8_t luma_from_num_u16(uint16x8_t num) {
  const int16x8_t q = vqdmulhq_n_s16(vreinterpretq_s16_u16(num), 20972);
  return vshrq_n_u16(vreinterpretq_u16_s16(q), 6);
}

// k_gray5_tone as four 64-byte vqtbl4q chunks. For each lane exactly ONE
// chunk sees an in-range index: the wrapped (luma - 64k) subtraction leaves
// every non-owning chunk's index >= 64, where vqtbl4q yields 0, so the ORs
// are carry-free (a true value of 0 comes out 0 from all four).
struct ToneTable {
  uint8x16x4_t seg[4];
};

inline ToneTable load_tone_table() {
  ToneTable t;
  for (int k = 0; k < 4; ++k) {
    const std::uint8_t* base = k_gray5_tone.data() + k * 64;
    t.seg[k] = uint8x16x4_t{{vld1q_u8(base), vld1q_u8(base + 16),
                             vld1q_u8(base + 32), vld1q_u8(base + 48)}};
  }
  return t;
}

inline uint8x16_t tone_levels_u8x16(const ToneTable& t, uint8x16_t luma) {
  uint8x16_t acc = vqtbl4q_u8(t.seg[0], luma);
  acc = vorrq_u8(acc, vqtbl4q_u8(t.seg[1], vsubq_u8(luma, vdupq_n_u8(64))));
  acc = vorrq_u8(acc, vqtbl4q_u8(t.seg[2], vsubq_u8(luma, vdupq_n_u8(128))));
  acc = vorrq_u8(acc, vqtbl4q_u8(t.seg[3], vsubq_u8(luma, vdupq_n_u8(192))));
  return acc;
}

inline uint8x8_t tone_levels_u8x8(const ToneTable& t, uint8x8_t luma) {
  uint8x8_t acc = vqtbl4_u8(t.seg[0], luma);
  acc = vorr_u8(acc, vqtbl4_u8(t.seg[1], vsub_u8(luma, vdup_n_u8(64))));
  acc = vorr_u8(acc, vqtbl4_u8(t.seg[2], vsub_u8(luma, vdup_n_u8(128))));
  acc = vorr_u8(acc, vqtbl4_u8(t.seg[3], vsub_u8(luma, vdup_n_u8(192))));
  return acc;
}

// 8 lanes of rgb565 -> LUMA (pre-tone) from u16 pixel lanes, bit-exact per
// lane vs the scalar's luma stage (the sub-16px remainder path).
inline uint16x8_t luma_lanes_u16(uint16x8_t px) {
  const uint16x8_t r5 = vshrq_n_u16(px, 11);
  const uint16x8_t g6 = vandq_u16(vshrq_n_u16(px, 5), vdupq_n_u16(0x3f));
  const uint16x8_t b5 = vandq_u16(px, vdupq_n_u16(0x1f));
  // 565 -> 888 replication; the OR is carry-free (low shifted-in bits are
  // zero and the >> term fits inside them), so vsra (shift-right-accumulate)
  // fuses it: r8 = (r5<<3)+(r5>>2), g8 = (g6<<2)+(g6>>4), b8 likewise.
  const uint16x8_t r8 = vsraq_n_u16(vshlq_n_u16(r5, 3), r5, 2);
  const uint16x8_t g8 = vsraq_n_u16(vshlq_n_u16(g6, 2), g6, 4);
  const uint16x8_t b8 = vsraq_n_u16(vshlq_n_u16(b5, 3), b5, 2);
  uint16x8_t num = vmlaq_n_u16(vdupq_n_u16(50), r8, 30);
  num = vmlaq_n_u16(num, g8, 59);
  num = vmlaq_n_u16(num, b8, 11);
  return luma_from_num_u16(num);
}

}  // namespace

void convert_rgb565_levels_neon(const std::uint8_t* src,
                                std::size_t src_stride_bytes,
                                std::int32_t width, std::int32_t height,
                                const std::uint8_t* legal_targets,
                                std::uint8_t* out) {
  // The 32-byte legal map fits exactly in two NEON registers: the legalize
  // step is one vqtbl2q per 16 pixels. Levels max out at 30 (the scalar's
  // &0x1f is a no-op), so every index is in range.
  const uint8x16x2_t map = {vld1q_u8(legal_targets),
                            vld1q_u8(legal_targets + 16)};
  const ToneTable tone = load_tone_table();
  const uint8x16_t w_r = vdupq_n_u8(30);
  const uint8x16_t w_g = vdupq_n_u8(59);
  const uint8x16_t w_b = vdupq_n_u8(11);
  const uint16x8_t bias50 = vdupq_n_u16(50);
  for (std::int32_t y = 0; y < height; ++y) {
    const std::uint8_t* row =
        src + static_cast<std::size_t>(y) * src_stride_bytes;
    std::uint8_t* dst =
        out + static_cast<std::size_t>(y) * static_cast<std::size_t>(width);
    std::int32_t x = 0;
    for (; x + 16 <= width; x += 16) {
      // Deinterleaved load: val[0] = low bytes, val[1] = high bytes of the
      // 16 little-endian RGB565 pixels — extraction AND 565->888 replication
      // run fused on all 16 lanes per instruction in the u8 domain, using
      // u8 shift truncation to discard neighbour-channel bits (each step
      // exhaustively proven equal to the scalar's r8/g8/b8 for all pixels):
      //   r8 = (hi & 0xf8) + (hi >> 5)               ; = r5<<3 | r5>>2
      //   u  = (hi << 3) + (lo >> 5)  ; u[5:0] = g6
      //   v  = u << 2                 ; = g6<<2 (garbage bits shifted out)
      //   g8 = v + (v >> 6)                          ; = g6<<2 | g6>>4
      //   t  = lo << 3                ; = b5<<3
      //   b8 = t + (t >> 5)                          ; = b5<<3 | b5>>2
      const uint8x16x2_t px = vld2q_u8(row + x * 2);
      const uint8x16_t lo = px.val[0];
      const uint8x16_t hi = px.val[1];
      const uint8x16_t r5 = vshrq_n_u8(hi, 3);
      const uint8x16_t g6 =
          vandq_u8(vsraq_n_u8(vshlq_n_u8(hi, 3), lo, 5), vdupq_n_u8(0x3f));
      const uint8x16_t b5 = vandq_u8(lo, vdupq_n_u8(0x1f));
      const uint8x16_t r8 = vsraq_n_u8(vshlq_n_u8(r5, 3), r5, 2);
      const uint8x16_t g8 = vsraq_n_u8(vshlq_n_u8(g6, 2), g6, 4);
      const uint8x16_t b8 = vsraq_n_u8(vshlq_n_u8(b5, 3), b5, 2);
      // Widening weighted sum: num = 50 + r8*30 + g8*59 + b8*11 (<= 25550).
      uint16x8_t num_lo = vmlal_u8(bias50, vget_low_u8(r8), vget_low_u8(w_r));
      num_lo = vmlal_u8(num_lo, vget_low_u8(g8), vget_low_u8(w_g));
      num_lo = vmlal_u8(num_lo, vget_low_u8(b8), vget_low_u8(w_b));
      uint16x8_t num_hi = vmlal_high_u8(bias50, r8, w_r);
      num_hi = vmlal_high_u8(num_hi, g8, w_g);
      num_hi = vmlal_high_u8(num_hi, b8, w_b);
      const uint8x16_t luma = vcombine_u8(vmovn_u16(luma_from_num_u16(num_lo)),
                                          vmovn_u16(luma_from_num_u16(num_hi)));
      const uint8x16_t levels = tone_levels_u8x16(tone, luma);
      vst1q_u8(dst + x, vqtbl2q_u8(map, levels));
    }
    if (x + 8 <= width) {
      // vld1q_u8 + reinterpret = little-endian u16 lanes, exactly the
      // scalar's row[2x] | row[2x+1]<<8 (no alignment requirement).
      const uint16x8_t px0 = vreinterpretq_u16_u8(vld1q_u8(row + x * 2));
      const uint8x8_t levels =
          tone_levels_u8x8(tone, vmovn_u16(luma_lanes_u16(px0)));
      vst1_u8(dst + x, vqtbl2_u8(map, levels));
      x += 8;
    }
    for (; x < width; ++x) {
      const std::uint16_t px = static_cast<std::uint16_t>(
          row[x * 2] | (static_cast<std::uint16_t>(row[x * 2 + 1]) << 8));
      dst[x] = legal_targets[rgb565_to_gray5(px) & 0x1f];
    }
  }
}
#endif  // __ARM_NEON && __aarch64__

bool transition_driven(const WaveformTable& table, int mode, int temp_bin,
                       std::uint8_t src, std::uint8_t dst) {
  const int phases = table.phase_count(mode, temp_bin);
  for (int phase = 0; phase < phases; ++phase) {
    if (table.code(mode, temp_bin, src, dst, phase) != 0) {
      return true;
    }
  }
  return false;
}

std::array<std::uint8_t, 32> build_legal_target_map(const WaveformTable& table,
                                                    int mode, int temp_bin) {
  std::array<std::uint8_t, 32> map{};
  for (int t = 0; t < 32; ++t) {
    map[t] = static_cast<std::uint8_t>(t);
  }
  if (!table.valid() || table.phase_count(mode, temp_bin) <= 0) {
    return map;
  }
  // Drivable targets: reachable from BOTH rails. A target within kRailSlack
  // of a rail counts as reachable from that rail without a drive (holding
  // there is optically correct). Real tables are sparse: GAL3 mode 7 only
  // drives {2, 28} (bilevel fast), mode 1 an 8-level lattice {0,6,..,26,30};
  // a target outside the drivable set (the rail slot 31, odd levels in
  // mode 1/2) silently holds and desyncs prev from glass.
  constexpr int kRailSlack = 2;
  std::uint8_t drivable[32];
  int drivable_count = 0;
  for (int t = 0; t < 32; ++t) {
    const bool from_black =
        t <= kRailSlack || transition_driven(table, mode, temp_bin, 0,
                                             static_cast<std::uint8_t>(t));
    const bool from_white =
        t >= 30 - kRailSlack || transition_driven(table, mode, temp_bin, 30,
                                                  static_cast<std::uint8_t>(t));
    if (from_black && from_white) {
      drivable[drivable_count++] = static_cast<std::uint8_t>(t);
    }
  }
  if (drivable_count == 0) {
    return map;  // hold-only table (synthetic/degenerate): leave levels as-is
  }
  for (int t = 0; t < 32; ++t) {
    int best = drivable[0];
    for (int i = 1; i < drivable_count; ++i) {
      const int d = drivable[i];
      const int dist = d > t ? d - t : t - d;
      const int best_dist = best > t ? best - t : t - best;
      // Ties break toward the brighter target (erase bias: residual ink is
      // the failure mode that accumulates).
      if (dist < best_dist || (dist == best_dist && d > best)) {
        best = d;
      }
    }
    map[t] = static_cast<std::uint8_t>(best);
  }
  return map;
}

bool supports_mode7_fast_recovery(const WaveformTable& table) {
  constexpr int kMode = 7;
  constexpr int kBins = 9;
  constexpr int kPhases = 11;
  if (!table.valid() || table.mode_count() <= kMode ||
      table.temp_count() != kBins) {
    return false;
  }
  for (int bin = 0; bin < kBins; ++bin) {
    if (table.phase_count(kMode, bin) != kPhases) {
      return false;
    }
    const auto legal = build_legal_target_map(table, kMode, bin);
    bool saw_black = false;
    bool saw_white = false;
    for (const std::uint8_t endpoint : legal) {
      if (endpoint == kMode7FastBlackEndpoint) {
        saw_black = true;
      } else if (endpoint == kMode7FastWhiteEndpoint) {
        saw_white = true;
      } else {
        return false;
      }
    }
    if (!saw_black || !saw_white) {
      return false;
    }
    for (int phase = 0; phase < kPhases; ++phase) {
      const std::uint8_t black_to_white = table.code(
          kMode, bin, kMode7FastBlackEndpoint, kMode7FastWhiteEndpoint, phase);
      const std::uint8_t white_to_black = table.code(
          kMode, bin, kMode7FastWhiteEndpoint, kMode7FastBlackEndpoint, phase);
      if (black_to_white != (phase < kPhases - 1 ? 1u : 0u) ||
          white_to_black != (phase < kPhases - 1 ? 6u : 0u) ||
          table.code(kMode, bin, kMode7FastBlackEndpoint, 30, phase) != 0u ||
          table.code(kMode, bin, kMode7FastWhiteEndpoint, 0, phase) != 0u) {
        return false;
      }
    }
  }
  return true;
}

}  // namespace pluto::swtcon
