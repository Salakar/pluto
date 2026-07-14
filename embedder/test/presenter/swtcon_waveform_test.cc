#include "presenter/swtcon/swtcon_waveform.h"

#include <gtest/gtest.h>

#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <string>
#include <vector>

#include "swtcon_eink_synth.h"

namespace {

using pluto::swtcon::kGrayStates;
using pluto::swtcon::kWaveformMatrixCells;
using pluto::swtcon::WaveformTable;

class FakeWaveformReader final : public pluto::swtcon::WaveformFileReader {
 public:
  bool read_file(const std::string& path, std::vector<std::uint8_t>* out,
                 std::string* error) const override {
    const auto found = files.find(path);
    if (found == files.end()) {
      if (error != nullptr) {
        *error = "missing file";
      }
      return false;
    }
    *out = found->second;
    return true;
  }

  std::map<std::string, std::vector<std::uint8_t>> files;
};

// Golden output of analysis/swtcon/waveforms/decode_eink.py for the panel
// file GAL3_AAB0AM_IC0801_AC073MC1F2_AD1004-GCA_TC.eink, mode 2 (GC16) at
// temp bin 4 (~25C). The C++ decoder must match byte-for-byte.
constexpr std::array<std::uint8_t, 86> kGoldenBlackToBright = {
    1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 2, 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
constexpr std::array<std::uint8_t, 86> kGoldenWhiteToBlack = {
    6, 6, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    6, 6, 6, 6, 6, 5, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
constexpr std::array<std::uint8_t, 86> kGoldenNoOpMid = {
    3, 2, 2, 0, 2, 2, 2, 2, 2, 2, 6, 4, 4, 4, 0, 4, 4, 4, 0, 4, 0, 4,
    0, 4, 0, 4, 0, 4, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3,
    4, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 1, 0};
constexpr std::array<int, 9> kGoldenPhaseCountsBin4 = {161, 31,  86, 39, 31,
                                                       53,  128, 11, 5};
constexpr std::array<int, 9> kGoldenMode2PhaseCounts = {166, 142, 117, 91, 86,
                                                        86,  86,  86,  86};

std::string fixture_path() {
#ifdef PLUTO_SWTCON_EINK_FIXTURE
  return PLUTO_SWTCON_EINK_FIXTURE;
#else
  return {};
#endif
}

std::vector<std::uint8_t> read_fixture_or_skip_marker(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    return {};
  }
  return std::vector<std::uint8_t>(std::istreambuf_iterator<char>(in),
                                   std::istreambuf_iterator<char>());
}

std::vector<std::uint8_t> mode7_recovery_codes(int phases = 11) {
  std::vector<std::uint8_t> codes(
      static_cast<std::size_t>(phases) * kWaveformMatrixCells, 0);
  for (int phase = 0; phase < std::min(phases, 10); ++phase) {
    for (int src = 0; src < kGrayStates; ++src) {
      codes[static_cast<std::size_t>(phase) * kWaveformMatrixCells +
            pluto::swtcon::kMode7FastBlackEndpoint * kGrayStates + src] = 6;
      codes[static_cast<std::size_t>(phase) * kWaveformMatrixCells +
            pluto::swtcon::kMode7FastWhiteEndpoint * kGrayStates + src] = 1;
    }
  }
  return codes;
}

std::vector<std::uint8_t> make_mode7_recovery_eink(
    int bins = 9, const std::vector<std::uint8_t>& special_codes = {},
    int special_bin = -1) {
  constexpr int kModes = 8;
  std::vector<std::uint8_t> hold(kWaveformMatrixCells, 0);
  std::vector<std::vector<std::uint8_t>> records{
      swtcon_synth::record_from_codes(hold),
      swtcon_synth::record_from_codes(mode7_recovery_codes())};
  if (!special_codes.empty()) {
    records.push_back(swtcon_synth::record_from_codes(special_codes));
  }
  std::vector<std::size_t> record_for(
      static_cast<std::size_t>(kModes * bins), 0);
  for (int bin = 0; bin < bins; ++bin) {
    record_for[static_cast<std::size_t>(7 * bins + bin)] =
        !special_codes.empty() && bin == special_bin ? 2u : 1u;
  }
  std::vector<std::uint8_t> thresholds(static_cast<std::size_t>(bins));
  for (int bin = 0; bin < bins; ++bin) {
    thresholds[static_cast<std::size_t>(bin)] =
        static_cast<std::uint8_t>(bin * 5);
  }
  return swtcon_synth::wrap_eink(swtcon_synth::build_container(
      kModes, bins, thresholds, records, record_for));
}

template <std::size_t N>
void expect_sequence_eq(const WaveformTable& table, int mode, int bin,
                        std::uint8_t src, std::uint8_t dst,
                        const std::array<std::uint8_t, N>& golden) {
  ASSERT_EQ(table.phase_count(mode, bin), static_cast<int>(N));
  for (std::size_t phase = 0; phase < N; ++phase) {
    EXPECT_EQ(table.code(mode, bin, src, dst, static_cast<int>(phase)),
              golden[phase])
        << "mode=" << mode << " bin=" << bin << " src=" << int{src}
        << " dst=" << int{dst} << " phase=" << phase;
  }
}

}  // namespace

TEST(SwtconWaveformTest, LzDecompressorHandlesBackReferences) {
  // {0,0,0,'A'} {0,0,0,'B'} then copy 3 bytes from offset 2 (overlapping,
  // reads a byte appended by the same record) + literal 'C'.
  const std::vector<std::uint8_t> payload = {0, 0,   0, 'A', 0, 0,
                                             0, 'B', 2, 0,   3, 'C'};
  std::vector<std::uint8_t> out;
  std::string error;
  ASSERT_TRUE(pluto::swtcon::eink_lz_decompress(payload.data(),
                                                  payload.size(), &out, &error))
      << error;
  EXPECT_EQ(std::string(out.begin(), out.end()), "ABABAC");
}

TEST(SwtconWaveformTest, LzDecompressorPadsTrailingPartialRecord) {
  // decode_eink.py zero-pads fields past the payload end and still emits the
  // record's literal; a trailing partial record must behave identically.
  const std::vector<std::uint8_t> payload = {0, 0, 0, 'X', 0};
  std::vector<std::uint8_t> out;
  std::string error;
  ASSERT_TRUE(pluto::swtcon::eink_lz_decompress(payload.data(),
                                                  payload.size(), &out, &error))
      << error;
  ASSERT_EQ(out.size(), 2u);
  EXPECT_EQ(out[0], 'X');
  EXPECT_EQ(out[1], 0u);
}

TEST(SwtconWaveformTest, LzDecompressorRejectsBadBackReference) {
  const std::vector<std::uint8_t> payload = {9, 0, 1,
                                             'A'};  // offset 9, empty out
  std::vector<std::uint8_t> out;
  std::string error;
  EXPECT_FALSE(pluto::swtcon::eink_lz_decompress(
      payload.data(), payload.size(), &out, &error));
}

TEST(SwtconWaveformTest, ParsesSyntheticEinkThroughFullPipeline) {
  // 2 modes x 2 temps exercising RLE pairs, escape literal runs, and a
  // record shared between both of mode 0's temp bins.
  std::vector<std::uint8_t> shared_codes(kWaveformMatrixCells);
  for (int cell = 0; cell < kWaveformMatrixCells; ++cell) {
    shared_codes[static_cast<std::size_t>(cell)] =
        static_cast<std::uint8_t>(cell % 2 == 0 ? 5 : 4);
  }
  // Mode 1 temp 0: RLE pairs only. (0x21, run 255) twice alternates the
  // mapped nibbles of 0x21 -> drive 0x08/0x0a -> codes 5,4 for 1024 cells.
  const std::vector<std::uint8_t> rle_pairs_record = {0x21, 0xff, 0x21, 0xff,
                                                      0xff};
  // Mode 1 temp 1: two phases, phase 0 all-hold, phase 1 alternating 1,3
  // (literal bytes 0xdc -> nibbles 12,13 -> drives 0x02,0x04 -> codes 1,3).
  std::vector<std::uint8_t> two_phase_record = {0x00, 0xff, 0x00, 0xff, 0xfc};
  for (int i = 0; i < 512; ++i) {
    two_phase_record.push_back(0xdc);
  }
  two_phase_record.push_back(0xfc);
  two_phase_record.push_back(0xff);

  const std::vector<std::vector<std::uint8_t>> records = {
      swtcon_synth::record_from_codes(shared_codes),
      rle_pairs_record,
      two_phase_record,
  };
  const std::vector<std::size_t> record_for = {0, 0, 1, 2};
  const std::vector<std::uint8_t> file = swtcon_synth::wrap_eink(
      swtcon_synth::build_container(2, 2, {10, 30}, records, record_for));

  WaveformTable table;
  std::string error;
  ASSERT_TRUE(table.parse(file, &error)) << error;
  EXPECT_TRUE(table.valid());
  EXPECT_EQ(table.mode_count(), 2);
  EXPECT_EQ(table.temp_count(), 2);
  EXPECT_EQ(table.temp_bin(5.0f), 0);
  EXPECT_EQ(table.temp_bin(10.0f), 0);
  EXPECT_EQ(table.temp_bin(15.0f), 0);
  EXPECT_EQ(table.temp_bin(30.0f), 1);
  EXPECT_EQ(table.temp_bin(99.0f), 1);  // clamps to the warmest bin
  EXPECT_EQ(table.temp_bin(-std::numeric_limits<float>::infinity()), 0);
  EXPECT_EQ(table.temp_bin(std::numeric_limits<float>::quiet_NaN()), 0);
  EXPECT_EQ(table.temp_bin(std::numeric_limits<float>::infinity()), 1);

  // Mode 0 shares one record across both temp bins (offset dedup).
  ASSERT_EQ(table.phase_count(0, 0), 1);
  EXPECT_EQ(static_cast<const void*>(table.phase_table(0, 0, 0)),
            static_cast<const void*>(table.phase_table(0, 1, 0)));
  // Transposed cell indexing: code(src,dst) reads cell dst*32+src.
  EXPECT_EQ(table.code(0, 0, /*src=*/2, /*dst=*/1, 0),
            shared_codes[1 * kGrayStates + 2]);
  EXPECT_EQ(table.code(0, 0, /*src=*/1, /*dst=*/2, 0),
            shared_codes[2 * kGrayStates + 1]);

  ASSERT_EQ(table.phase_count(1, 0), 1);
  for (int cell = 0; cell < kWaveformMatrixCells; ++cell) {
    const std::uint8_t expected = cell % 2 == 0 ? 5 : 4;
    ASSERT_EQ(table.phase_table(1, 0, 0)[cell], expected) << "cell=" << cell;
  }

  ASSERT_EQ(table.phase_count(1, 1), 2);
  for (int cell = 0; cell < kWaveformMatrixCells; ++cell) {
    ASSERT_EQ(table.phase_table(1, 1, 0)[cell], 0) << "cell=" << cell;
    const std::uint8_t expected = cell % 2 == 0 ? 1 : 3;
    ASSERT_EQ(table.phase_table(1, 1, 1)[cell], expected) << "cell=" << cell;
  }

  // Out-of-range lookups are safe.
  EXPECT_EQ(table.phase_count(2, 0), 0);
  EXPECT_TRUE(table.phase_table(1, 1, 2) == nullptr);
  EXPECT_EQ(table.code(1, 1, 0, 0, 99), 0u);
}

TEST(SwtconWaveformTest, RejectsCorruptEink) {
  WaveformTable table;
  std::string error;
  EXPECT_FALSE(table.parse({1, 2, 3}, &error));  // shorter than the header
  EXPECT_FALSE(table.valid());

  std::vector<std::uint8_t> bad_header =
      swtcon_synth::make_synthetic_eink(/*phases=*/1);
  bad_header[9] ^= 0xff;  // corrupt the type tag (post-XOR)
  EXPECT_FALSE(table.parse(bad_header, &error));

  std::vector<std::uint8_t> bad_length =
      swtcon_synth::make_synthetic_eink(/*phases=*/1);
  bad_length.push_back(0);  // payload length no longer matches the file size
  EXPECT_FALSE(table.parse(bad_length, &error));
}

TEST(SwtconWaveformTest, ExactMode7FastRecoverySignatureIsFailClosed) {
  WaveformTable table;
  std::string error;
  ASSERT_TRUE(table.parse(make_mode7_recovery_eink(), &error)) << error;
  EXPECT_TRUE(pluto::swtcon::supports_mode7_fast_recovery(table));

  WaveformTable wrong_bin_count;
  ASSERT_TRUE(wrong_bin_count.parse(make_mode7_recovery_eink(8), &error))
      << error;
  EXPECT_FALSE(
      pluto::swtcon::supports_mode7_fast_recovery(wrong_bin_count));

  auto wrong_sequence = mode7_recovery_codes();
  wrong_sequence[static_cast<std::size_t>(4) * kWaveformMatrixCells +
                 pluto::swtcon::kMode7FastWhiteEndpoint * kGrayStates +
                 pluto::swtcon::kMode7FastBlackEndpoint] = 3;
  WaveformTable changed_code;
  ASSERT_TRUE(changed_code.parse(
      make_mode7_recovery_eink(9, wrong_sequence, 4), &error)) << error;
  EXPECT_FALSE(pluto::swtcon::supports_mode7_fast_recovery(changed_code));

  auto extra_endpoint = mode7_recovery_codes();
  extra_endpoint[15 * kGrayStates + 0] = 1;
  extra_endpoint[15 * kGrayStates + 30] = 1;
  WaveformTable changed_lattice;
  ASSERT_TRUE(changed_lattice.parse(
      make_mode7_recovery_eink(9, extra_endpoint, 2), &error)) << error;
  EXPECT_FALSE(
      pluto::swtcon::supports_mode7_fast_recovery(changed_lattice));

  auto logical_rail = mode7_recovery_codes();
  logical_rail[30 * kGrayStates +
               pluto::swtcon::kMode7FastBlackEndpoint] = 1;
  WaveformTable changed_terminal;
  ASSERT_TRUE(changed_terminal.parse(
      make_mode7_recovery_eink(9, logical_rail, 7), &error)) << error;
  EXPECT_FALSE(
      pluto::swtcon::supports_mode7_fast_recovery(changed_terminal));

  WaveformTable changed_length;
  ASSERT_TRUE(changed_length.parse(
      make_mode7_recovery_eink(9, mode7_recovery_codes(10), 0), &error))
      << error;
  EXPECT_FALSE(
      pluto::swtcon::supports_mode7_fast_recovery(changed_length));
}

TEST(SwtconWaveformTest, LoadsEinkAndOptionalCt33Blobs) {
  FakeWaveformReader reader;
  reader.files["wf.eink"] = swtcon_synth::make_synthetic_eink();
  reader.files["std.bin"] = {4};
  reader.files["fast.bin"] = {7};

  pluto::swtcon::SwtconWaveform::Files files;
  files.eink_path = "wf.eink";
  files.ct33_std_path = "std.bin";
  files.ct33_best_path = "missing-best.bin";  // optional: skipped, not fatal
  files.ct33_pen_path = "missing-pen.bin";
  files.ct33_fast_path = "fast.bin";

  pluto::swtcon::SwtconWaveform waveform;
  std::string error;
  ASSERT_TRUE(waveform.load(files, reader, &error)) << error;
  EXPECT_TRUE(waveform.loaded());
  EXPECT_TRUE(waveform.table().valid());
  EXPECT_EQ(waveform.ct33_bytes().size(), static_cast<std::size_t>(2));
  EXPECT_EQ(waveform.ct33_bytes().at("fast")[0], 7u);
}

TEST(SwtconWaveformTest, LoadFailsWhenEinkIsCorrupt) {
  FakeWaveformReader reader;
  reader.files["wf.eink"] = {1, 2, 3};

  pluto::swtcon::SwtconWaveform::Files files;
  files.eink_path = "wf.eink";
  files.ct33_std_path.clear();
  files.ct33_best_path.clear();
  files.ct33_pen_path.clear();
  files.ct33_fast_path.clear();

  pluto::swtcon::SwtconWaveform waveform;
  std::string error;
  EXPECT_FALSE(waveform.load(files, reader, &error));
  EXPECT_FALSE(waveform.table().valid());
}

TEST(SwtconWaveformTest, LookupUsesDecodedTableAndModeMap) {
  FakeWaveformReader reader;
  reader.files["wf.eink"] = swtcon_synth::make_synthetic_eink(/*phases=*/3);

  pluto::swtcon::SwtconWaveform::Files files;
  files.eink_path = "wf.eink";
  files.ct33_std_path.clear();
  files.ct33_best_path.clear();
  files.ct33_pen_path.clear();
  files.ct33_fast_path.clear();

  pluto::swtcon::SwtconWaveform waveform;
  std::string error;
  ASSERT_TRUE(waveform.load(files, reader, &error)) << error;

  // Full maps to .eink mode 2; 25C lands in synthetic temp bin 1.
  EXPECT_EQ(pluto::swtcon::waveform_mode_index(
                pluto::swtcon::SwtconUpdateMode::kFull),
            2);
  const pluto::swtcon::PhaseSequence sequence = waveform.lookup(
      pluto::swtcon::SwtconUpdateMode::kFull, /*src=*/3, /*dst=*/12, 25.0f);
  EXPECT_TRUE(sequence.from_waveform);
  ASSERT_EQ(sequence.values.size(), 3u);
  const int cell = 12 * kGrayStates + 3;  // transposed dst*32+src
  for (int phase = 0; phase < 3; ++phase) {
    EXPECT_EQ(sequence.values[static_cast<std::size_t>(phase)],
              swtcon_synth::synthetic_mode2_code(cell, phase))
        << "phase=" << phase;
  }
}

TEST(SwtconWaveformTest, LookupWithoutTableIsEmpty) {
  pluto::swtcon::SwtconWaveform waveform;
  const pluto::swtcon::PhaseSequence sequence =
      waveform.lookup(pluto::swtcon::SwtconUpdateMode::kFull, 0, 30, 25.0f);
  EXPECT_FALSE(sequence.from_waveform);
  EXPECT_TRUE(sequence.values.empty());

  pluto::swtcon::PhaseLookup lookup{};
  EXPECT_EQ(lookup.phase_count(), 0);
  lookup.use_fixed_phase_value = true;
  lookup.fixed_phase_value = 5;
  EXPECT_EQ(lookup.phase_count(), pluto::swtcon::kActivePhaseSlots);
  const pluto::swtcon::PhaseSequence fixed = lookup.phase_values(0, 31);
  ASSERT_EQ(fixed.values.size(),
            static_cast<std::size_t>(pluto::swtcon::kActivePhaseSlots));
  EXPECT_EQ(fixed.values[0], 5u);
}

// Golden decode of the real panel file — must match decode_eink.py exactly.
TEST(SwtconWaveformTest, DecodesRealPanelEinkGolden) {
  const std::string path = fixture_path();
  const std::vector<std::uint8_t> bytes = read_fixture_or_skip_marker(path);
  if (bytes.empty()) {
    const std::string message =
        "panel .eink golden fixture missing: " + path +
        " — the golden decode DID NOT RUN. The fixture is gitignored "
        "(analysis/ is excluded); obtain it from a reMarkable Paper Pro Move "
        "(xochitl loads it from /usr/share/remarkable/, e.g. `scp "
        "root@10.11.99.1:/usr/share/remarkable/"
        "GAL3_AAB0AM_IC0801_AC073MC1F2_AD1004-GCA_TC.eink "
        "analysis/swtcon/waveforms/`) or copy analysis/swtcon/waveforms/ from "
        "a teammate's checkout.";
#ifdef GTEST_SKIP
    GTEST_SKIP() << message;
#else
    // The gtest compatibility shim has no skip support; emit the gtest-style
    // marker so the missing fixture can never read as a clean PASS.
    std::cerr << "[  SKIPPED ] SwtconWaveformTest.DecodesRealPanelEinkGolden: "
              << message << "\n";
    return;
#endif
  }

  WaveformTable table;
  std::string error;
  ASSERT_TRUE(table.parse(bytes, &error)) << error;
  EXPECT_EQ(table.mode_count(), 9);
  EXPECT_EQ(table.temp_count(), 9);
  EXPECT_TRUE(pluto::swtcon::supports_mode7_fast_recovery(table));
  const std::array<std::uint8_t, 9> expected_thresholds = {0,  7,  13, 18, 22,
                                                           28, 33, 38, 43};
  ASSERT_EQ(table.temp_thresholds().size(), expected_thresholds.size());
  for (std::size_t i = 0; i < expected_thresholds.size(); ++i) {
    EXPECT_EQ(table.temp_thresholds()[i], expected_thresholds[i])
        << "threshold i=" << i;
  }
  ASSERT_EQ(table.temp_bin(25.0f), 4);

  for (int mode = 0; mode < 9; ++mode) {
    EXPECT_EQ(table.phase_count(mode, 4),
              kGoldenPhaseCountsBin4[static_cast<std::size_t>(mode)])
        << "mode=" << mode;
  }
  for (int bin = 0; bin < 9; ++bin) {
    EXPECT_EQ(table.phase_count(2, bin),
              kGoldenMode2PhaseCounts[static_cast<std::size_t>(bin)])
        << "bin=" << bin;
  }
  EXPECT_EQ(table.phase_count(6, 0), 238);  // longest record (cold mode 6)
  // Mode 0 is the temp-independent INIT record: one shared expansion.
  EXPECT_EQ(static_cast<const void*>(table.phase_table(0, 0, 0)),
            static_cast<const void*>(table.phase_table(0, 8, 0)));

  // The effective black->white drive (slot 31 is a rail; real white ~30),
  // white->black, and the mid-grey no-op agitation.
  expect_sequence_eq(table, 2, 4, 0, 30, kGoldenBlackToBright);
  expect_sequence_eq(table, 2, 4, 31, 0, kGoldenWhiteToBlack);
  expect_sequence_eq(table, 2, 4, 15, 15, kGoldenNoOpMid);

  // SwtconWaveform::lookup end-to-end: Full at 25C = mode 2, bin 4.
  FakeWaveformReader reader;
  reader.files["panel.eink"] = bytes;
  pluto::swtcon::SwtconWaveform::Files files;
  files.eink_path = "panel.eink";
  files.ct33_std_path.clear();
  files.ct33_best_path.clear();
  files.ct33_pen_path.clear();
  files.ct33_fast_path.clear();
  pluto::swtcon::SwtconWaveform waveform;
  ASSERT_TRUE(waveform.load(files, reader, &error)) << error;
  const pluto::swtcon::PhaseSequence sequence =
      waveform.lookup(pluto::swtcon::SwtconUpdateMode::kFull, 0, 30, 25.0f);
  ASSERT_EQ(sequence.values.size(), kGoldenBlackToBright.size());
  for (std::size_t phase = 0; phase < kGoldenBlackToBright.size(); ++phase) {
    EXPECT_EQ(sequence.values[phase], kGoldenBlackToBright[phase])
        << "phase=" << phase;
  }
}

// ---- content-target legalization -----------------------------------------

namespace {

// Sparse table shaped like a real panel file: mode 1 drives only dst 0
// (darken, code 6) and dst 30 (lighten, code 1) from every src; everything
// else — including the rail slot 31 and all odd levels — holds. Mode 0 is a
// drive-everything INIT record; mode 2 mirrors mode 1.
std::vector<std::uint8_t> make_sparse_bilevel_eink() {
  constexpr int kPhases = 2;
  std::vector<std::uint8_t> init_codes(
      static_cast<std::size_t>(kPhases) * kWaveformMatrixCells, 1);
  std::vector<std::uint8_t> sparse_codes(
      static_cast<std::size_t>(kPhases) * kWaveformMatrixCells, 0);
  for (int phase = 0; phase < kPhases; ++phase) {
    for (int src = 0; src < kGrayStates; ++src) {
      sparse_codes[static_cast<std::size_t>(phase) * kWaveformMatrixCells +
                   0 * kGrayStates + src] = 6;  // -> black
      sparse_codes[static_cast<std::size_t>(phase) * kWaveformMatrixCells +
                   30 * kGrayStates + src] = 1;  // -> white (30, not 31)
    }
  }
  const std::vector<std::vector<std::uint8_t>> records = {
      swtcon_synth::record_from_codes(init_codes),
      swtcon_synth::record_from_codes(sparse_codes)};
  // 3 modes x 1 temp bin: INIT, sparse, sparse.
  return swtcon_synth::wrap_eink(
      swtcon_synth::build_container(3, 1, {60}, records, {0, 1, 1}));
}

}  // namespace

TEST(SwtconWaveformTest, LegalTargetMapSnapsToDrivableTargets) {
  WaveformTable table;
  std::string error;
  ASSERT_TRUE(table.parse(make_sparse_bilevel_eink(), &error)) << error;

  const std::array<std::uint8_t, 32> map =
      pluto::swtcon::build_legal_target_map(table, 1, 0);
  // Drivable set is {0, 30}: white content must target 30, never the
  // undriven rail slot 31; everything snaps to the nearest drivable target
  // (ties break brighter).
  EXPECT_EQ(map[31], 30);
  EXPECT_EQ(map[30], 30);
  EXPECT_EQ(map[29], 30);
  EXPECT_EQ(map[16], 30);  // midpoint tie -> brighter
  EXPECT_EQ(map[15], 30);
  EXPECT_EQ(map[14], 0);
  EXPECT_EQ(map[1], 0);
  EXPECT_EQ(map[0], 0);

  // INIT (mode 0) drives everything: identity.
  const std::array<std::uint8_t, 32> init_map =
      pluto::swtcon::build_legal_target_map(table, 0, 0);
  for (int t = 0; t < 32; ++t) {
    EXPECT_EQ(init_map[t], t) << "t=" << t;
  }
}

TEST(SwtconWaveformTest, LegalTargetMapIdentityOnHoldOnlyAndInvalidTables) {
  // Synthetic 3-mode table: modes 0/1 are hold-only -> identity fallback.
  WaveformTable table;
  std::string error;
  ASSERT_TRUE(
      table.parse(swtcon_synth::make_synthetic_eink(/*phases=*/3), &error))
      << error;
  const std::array<std::uint8_t, 32> hold_map =
      pluto::swtcon::build_legal_target_map(table, 1, 0);
  for (int t = 0; t < 32; ++t) {
    EXPECT_EQ(hold_map[t], t) << "t=" << t;
  }
  // Invalid/out-of-range (mode, bin): identity.
  WaveformTable empty;
  const std::array<std::uint8_t, 32> empty_map =
      pluto::swtcon::build_legal_target_map(empty, 1, 0);
  for (int t = 0; t < 32; ++t) {
    EXPECT_EQ(empty_map[t], t) << "t=" << t;
  }
}

TEST(SwtconWaveformTest, LegalTargetMapRealGal3) {
  const std::string path = fixture_path();
  const std::vector<std::uint8_t> bytes = read_fixture_or_skip_marker(path);
  if (bytes.empty()) {
#ifdef GTEST_SKIP
    GTEST_SKIP() << "panel .eink golden fixture missing: " << path;
#else
    std::cerr << "[  SKIPPED ] SwtconWaveformTest.LegalTargetMapRealGal3: "
              << "panel .eink golden fixture missing: " << path << "\n";
    return;
#endif
  }
  WaveformTable table;
  std::string error;
  ASSERT_TRUE(table.parse(bytes, &error)) << error;
  const int bin = table.temp_bin(25.0f);

  // Mode 7 (Fast/Ui) on GAL3 is bilevel: drivable targets are {2, 28}.
  const std::array<std::uint8_t, 32> fast =
      pluto::swtcon::build_legal_target_map(table, 7, bin);
  EXPECT_EQ(fast[0], 2);    // black content -> drivable dark rail
  EXPECT_EQ(fast[30], 28);  // white content -> drivable bright rail
  EXPECT_EQ(fast[31], 28);

  // Mode 1 (Text): 8-level lattice {0,6,10,14,18,22,26,30}; the rail slot 31
  // and undriven 28 snap to 30 (brighter on tie).
  const std::array<std::uint8_t, 32> text =
      pluto::swtcon::build_legal_target_map(table, 1, bin);
  EXPECT_EQ(text[0], 0);
  EXPECT_EQ(text[30], 30);
  EXPECT_EQ(text[31], 30);
  EXPECT_EQ(text[28], 30);
  for (const int lattice : {0, 6, 10, 14, 18, 22, 26, 30}) {
    EXPECT_EQ(text[static_cast<std::size_t>(lattice)], lattice)
        << "lattice=" << lattice;
  }

  // Mode 2 (Full/GC16): white must never target the rail slot 31.
  const std::array<std::uint8_t, 32> full =
      pluto::swtcon::build_legal_target_map(table, 2, bin);
  EXPECT_EQ(full[0], 0);
  EXPECT_EQ(full[30], 30);
  EXPECT_EQ(full[31], 30);
}
