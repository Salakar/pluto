// TEST-ONLY REFERENCE MODEL tests: swtcon_packer/swtcon_phase_generator
// have no production linkage since the per-pixel engine landed. These
// tests pin the reference oracle used by the equivalence proof
// (engine_equivalence_test.cc): the control scaffold, the word/lane
// encoding, and record-playback packing. Presenter behavior tests live in
// drm_swtcon_presenter_test.cc.
//
// Deleted with the old drive core (their packing-internals pins died with
// it; intents re-pinned as noted):
//   - RegisteredPresenterRunsDryRunFrameLifecycle / Gc16Lifecycle ->
//     re-pinned on the engine presenter (drm_swtcon_presenter_test.cc,
//     DryRunLifecycle*): the no-eink variant is gone — the engine drives
//     exclusively from a decoded .eink.
//   - PresenterNeverSelfSchedulesSettles -> re-pinned verbatim in intent
//     (drm_swtcon_presenter_test.cc).
//   - DuDrivePassParksScanOnBlankHoldFrame -> intent (scan always parks on
//     the blank HOLD plane) re-pinned structurally on ScanLoop/PhaseEmitter
//     (drm_swtcon_presenter_test.cc ScanParksOnBlankHold*, l0_trace_test.cc
//     judged-blank scenario); the DU flip-count internals died.
//   - DuFlipRingRestartsAtSlotZeroEachPass -> intent (deterministic slot
//     sequence) re-pinned as the build-slot rotation assertions in
//     drm_swtcon_presenter_test.cc and the L0 slot-reuse golden.

#include "presenter/swtcon/swtcon_packer.h"
#include "presenter/swtcon/swtcon_phase_generator.h"
#include "pluto/presenter.h"

#include "swtcon_eink_synth.h"

#include <gtest/gtest.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace {

using pluto::swtcon::kGrayStates;

class FakeWaveformReader final : public pluto::swtcon::WaveformFileReader {
 public:
  bool read_file(const std::string& path,
                 std::vector<std::uint8_t>* out,
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

void fill_rgb565(std::vector<std::uint8_t>* frame, std::uint16_t value) {
  for (std::size_t i = 0; i < frame->size(); i += 2) {
    (*frame)[i] = static_cast<std::uint8_t>(value & 0xffU);
    (*frame)[i + 1] = static_cast<std::uint8_t>(value >> 8);
  }
}

void store_rgb565(std::vector<std::uint8_t>* frame,
                  int x,
                  int y,
                  std::uint16_t value) {
  const std::size_t offset =
      static_cast<std::size_t>(y) * pluto::swtcon::kLogicalStrideBytes +
      static_cast<std::size_t>(x) * pluto::swtcon::kRgb565BytesPerPixel;
  (*frame)[offset] = static_cast<std::uint8_t>(value & 0xffU);
  (*frame)[offset + 1] = static_cast<std::uint8_t>(value >> 8);
}

pluto::swtcon::SourceFrame make_source_frame(
    const std::vector<std::uint8_t>& previous,
    const std::vector<std::uint8_t>& next) {
  pluto::swtcon::SourceFrame source;
  source.previous_pixels = previous.data();
  source.next_pixels = next.data();
  source.previous_stride_bytes = pluto::swtcon::kLogicalStrideBytes;
  source.next_stride_bytes = pluto::swtcon::kLogicalStrideBytes;
  source.width = pluto::swtcon::kLogicalWidth;
  source.height = pluto::swtcon::kLogicalHeight;
  source.format = kPlutoPixelFormatRgb565;
  return source;
}

std::size_t packed_word_index(int x, int y) {
  return static_cast<std::size_t>(y + pluto::swtcon::kFirstDataRow) *
             pluto::swtcon::kDrmWidth +
         pluto::swtcon::kFirstDataWord + static_cast<std::size_t>(x / 4);
}

std::uint16_t packed_word(const std::vector<std::uint16_t>& packed,
                          int phase,
                          std::size_t word_index) {
  return packed[static_cast<std::size_t>(phase) *
                    pluto::swtcon::kDrmPhaseWords +
                word_index];
}

std::uint16_t expected_blank_word(int row, int word) {
  using namespace pluto::swtcon;
  std::uint16_t expected = 0;
  if (row == 0) {
    if (word >= 1 && word <= kDrmWidth - 1) {
      expected = static_cast<std::uint16_t>(expected | kFrameSyncBit);
    }
    if (word >= 23 && word <= 319) {
      expected = static_cast<std::uint16_t>(expected | kDataValidBit);
    }
    return expected;
  }
  if (word >= 1 && word <= 18) {
    expected = static_cast<std::uint16_t>(expected | kGateControlBit);
  }
  if (word >= 23 && word <= 319) {
    expected = static_cast<std::uint16_t>(expected | kDataValidBit);
  }
  if (row >= kFirstDataRow && word == kFirstDataWord) {
    expected = static_cast<std::uint16_t>(expected | kLeftEdgeControlBit);
  }
  return expected;
}

std::uint16_t lane_bits(std::uint8_t code, int x) {
  return static_cast<std::uint16_t>((code & 0x7U) << (9 - 3 * (x % 4)));
}

// Loads the shared synthetic waveform (3 modes x 2 temps; mode 2 = the Full
// mapping with code(cell, phase) = (cell + phase) % 7, N phases).
void load_synthetic_waveform(pluto::swtcon::SwtconWaveform* waveform,
                             int phases) {
  FakeWaveformReader reader;
  reader.files["synthetic.eink"] = swtcon_synth::make_synthetic_eink(phases);

  pluto::swtcon::SwtconWaveform::Files files;
  files.eink_path = "synthetic.eink";
  files.ct33_std_path.clear();
  files.ct33_best_path.clear();
  files.ct33_pen_path.clear();
  files.ct33_fast_path.clear();

  std::string error;
  ASSERT_TRUE(waveform->load(files, reader, &error)) << error;
  ASSERT_TRUE(waveform->table().valid());
}

}  // namespace

TEST(SwtconPackerTest, BlankPhaseFrameMatchesControlWindows) {
  std::vector<std::uint16_t> frame(pluto::swtcon::kDrmPhaseWords, 0xffff);
  pluto::swtcon::init_blank_phase_frame(frame.data());

  for (int row = 0; row < pluto::swtcon::kDrmHeight; ++row) {
    for (int word = 0; word < pluto::swtcon::kDrmWidth; ++word) {
      EXPECT_EQ(frame[static_cast<std::size_t>(row) *
                          pluto::swtcon::kDrmWidth +
                      static_cast<std::size_t>(word)],
                expected_blank_word(row, word))
          << "row=" << row << " word=" << word;
    }
  }
}

TEST(SwtconPackerTest, Rgb565ToGray5FollowsInkToneCurve) {
  // Renderer lattice (denominator 30): white = 30, never the undriven rail
  // slot 31. The luma -> level step applies the ink-darkening tone curve
  // round(30 * (luma/255)^1.8): Flutter composites in gamma-encoded sRGB,
  // and mapping that value LINEARLY onto the reflectance lattice rendered
  // anti-aliased glyph edges ~1.5 stops too light — crisp bilevel preview,
  // then visible fade+thin when the quality pass re-presented true grays.
  // Endpoints stay exact; sRGB mid gray darkens to print weight; the curve
  // is monotonic.
  EXPECT_EQ(pluto::swtcon::rgb565_to_gray5(0x0000), 0u);   // black
  EXPECT_EQ(pluto::swtcon::rgb565_to_gray5(0xffff), 30u);  // paper white
  EXPECT_EQ(pluto::swtcon::rgb565_to_gray5(0x8410), 9u);   // sRGB mid gray
  int prev_level = 0;
  for (int gray = 0; gray <= 255; ++gray) {
    const int r5 = gray >> 3;
    const int g6 = gray >> 2;
    const int b5 = gray >> 3;
    const std::uint16_t px =
        static_cast<std::uint16_t>((r5 << 11) | (g6 << 5) | b5);
    // Recover the exact luma the converter computes for this pixel, then
    // pin the tone formula on it.
    const int r8 = (r5 << 3) | (r5 >> 2);
    const int g8 = (g6 << 2) | (g6 >> 4);
    const int b8 = (b5 << 3) | (b5 >> 2);
    const int luma = (r8 * 30 + g8 * 59 + b8 * 11 + 50) / 100;
    const int expected =
        static_cast<int>(std::lround(30.0 * std::pow(luma / 255.0, 1.8)));
    const int level = pluto::swtcon::rgb565_to_gray5(px);
    EXPECT_EQ(level, expected) << "gray=" << gray;
    EXPECT_GE(level, prev_level)
        << "tone curve must be monotonic, gray=" << gray;
    prev_level = level;
  }
}

TEST(SwtconPackerTest, PackFailsWithoutDecodedWaveform) {
  std::vector<std::uint8_t> previous(pluto::swtcon::kLogicalFrameBytes);
  std::vector<std::uint8_t> next(pluto::swtcon::kLogicalFrameBytes);
  fill_rgb565(&previous, 0x0000);
  fill_rgb565(&next, 0xffff);

  pluto::swtcon::PhaseLookup lookup;  // no waveform, no fixed value
  std::vector<std::uint16_t> packed;
  pluto::swtcon::SwtconPacker packer;
  std::string error;
  EXPECT_FALSE(packer.pack(make_source_frame(previous, next), lookup, &packed,
                           &error));
  EXPECT_FALSE(error.empty());
}

TEST(SwtconPackerTest, FixedPhaseValuePacksDiagnosticRing) {
  std::vector<std::uint8_t> previous(pluto::swtcon::kLogicalFrameBytes);
  std::vector<std::uint8_t> next(pluto::swtcon::kLogicalFrameBytes);
  fill_rgb565(&previous, 0x0000);
  fill_rgb565(&next, 0x0000);

  pluto::swtcon::PhaseLookup lookup;
  lookup.use_fixed_phase_value = true;
  lookup.fixed_phase_value = 5;

  std::vector<std::uint16_t> packed;
  pluto::swtcon::SwtconPacker packer;
  ASSERT_TRUE(packer.pack(make_source_frame(previous, next), lookup, &packed,
                          nullptr));
  ASSERT_EQ(packed.size(),
            static_cast<std::size_t>(pluto::swtcon::kActivePhaseSlots) *
                pluto::swtcon::kDrmPhaseWords);

  // Every visible pixel lane carries code 5 on top of the control scaffold;
  // pad lanes (x >= 954) stay 0.
  const std::uint16_t all_lanes = static_cast<std::uint16_t>(
      lane_bits(5, 0) | lane_bits(5, 1) | lane_bits(5, 2) | lane_bits(5, 3));
  for (int phase = 0; phase < pluto::swtcon::kActivePhaseSlots; ++phase) {
    EXPECT_EQ(packed_word(packed, phase, packed_word_index(0, 0)),
              static_cast<std::uint16_t>(
                  expected_blank_word(pluto::swtcon::kFirstDataRow,
                                      pluto::swtcon::kFirstDataWord) |
                  all_lanes))
        << "phase=" << phase;
    EXPECT_EQ(packed_word(packed, phase, packed_word_index(956, 0)),
              expected_blank_word(pluto::swtcon::kFirstDataRow,
                                  pluto::swtcon::kFirstDataWord + 956 / 4))
        << "phase=" << phase;
  }
}

TEST(SwtconPackerTest, PacksSinglePixelTransitionIntoExactWordLane) {
  pluto::swtcon::SwtconWaveform waveform;
  load_synthetic_waveform(&waveform, /*phases=*/3);

  std::vector<std::uint8_t> previous(pluto::swtcon::kLogicalFrameBytes);
  std::vector<std::uint8_t> next(pluto::swtcon::kLogicalFrameBytes);
  fill_rgb565(&previous, 0x0000);
  fill_rgb565(&next, 0x0000);
  store_rgb565(&next, 5, 7, 0xffff);

  pluto::swtcon::PhaseLookup lookup;
  lookup.waveform = &waveform;
  lookup.mode = pluto::swtcon::SwtconUpdateMode::kFull;  // .eink mode 2
  lookup.temperature_c = 25.0f;

  std::vector<std::uint16_t> packed;
  pluto::swtcon::SwtconPacker packer;
  std::string error;
  ASSERT_TRUE(packer.pack(make_source_frame(previous, next), lookup, &packed,
                          &error))
      << error;
  ASSERT_EQ(packed.size(),
            static_cast<std::size_t>(3) * pluto::swtcon::kDrmPhaseWords);

  // Transposed cell index: black->white pixel = dst 30 (renderer lattice
  // white), src 0 -> 30*32+0; untouched black background = cell 0.
  const int cell_hit = 30 * kGrayStates + 0;
  const int cell_bg = 0;
  const std::size_t hit = packed_word_index(5, 7);
  for (int phase = 0; phase < 3; ++phase) {
    const std::uint8_t hit_code =
        swtcon_synth::synthetic_mode2_code(cell_hit, phase);
    const std::uint8_t bg_code =
        swtcon_synth::synthetic_mode2_code(cell_bg, phase);
    // Word covering x=4..7 in row 7: lane 1 is the white pixel, the other
    // lanes carry the background transition. Control bits are preserved.
    const std::uint16_t expected_hit = static_cast<std::uint16_t>(
        expected_blank_word(7 + pluto::swtcon::kFirstDataRow,
                            pluto::swtcon::kFirstDataWord + 5 / 4) |
        lane_bits(bg_code, 4) | lane_bits(hit_code, 5) | lane_bits(bg_code, 6) |
        lane_bits(bg_code, 7));
    EXPECT_EQ(packed_word(packed, phase, hit), expected_hit)
        << "phase=" << phase;
    // Row-control word (word 23) keeps its data-valid bit only.
    const std::size_t row_control =
        static_cast<std::size_t>(7 + pluto::swtcon::kFirstDataRow) *
            pluto::swtcon::kDrmWidth +
        23;
    EXPECT_EQ(packed_word(packed, phase, row_control),
              pluto::swtcon::kDataValidBit)
        << "phase=" << phase;
  }
}

TEST(SwtconPackerTest, RoundTripsSyntheticWaveformAcrossAllPhases) {
  pluto::swtcon::SwtconWaveform waveform;
  load_synthetic_waveform(&waveform, /*phases=*/3);

  std::vector<std::uint8_t> previous(pluto::swtcon::kLogicalFrameBytes);
  std::vector<std::uint8_t> next(pluto::swtcon::kLogicalFrameBytes);
  fill_rgb565(&previous, 0x0000);
  fill_rgb565(&next, 0x0000);
  for (int y = 0; y < 3; ++y) {
    for (int x = 0; x < 16; ++x) {
      if (((x + y) % 2) != 0) {
        store_rgb565(&next, x, y, 0xffff);
      }
    }
  }

  pluto::swtcon::PhaseLookup lookup;
  lookup.waveform = &waveform;
  lookup.mode = pluto::swtcon::SwtconUpdateMode::kFull;
  lookup.temperature_c = 25.0f;

  std::vector<std::uint16_t> packed;
  pluto::swtcon::SwtconPacker packer;
  std::string error;
  ASSERT_TRUE(packer.pack(make_source_frame(previous, next), lookup, &packed,
                          &error))
      << error;

  for (int phase = 0; phase < 3; ++phase) {
    for (int y = 0; y < 3; ++y) {
      for (int x = 0; x < 16; ++x) {
        const int dst = ((x + y) % 2) != 0 ? 30 : 0;
        const int cell = dst * kGrayStates + 0;  // src is black everywhere
        const std::uint16_t word =
            packed_word(packed, phase, packed_word_index(x, y));
        const auto unpacked = static_cast<std::uint8_t>(
            (word >> (9 - 3 * (x % 4))) & 0x7U);
        EXPECT_EQ(unpacked, swtcon_synth::synthetic_mode2_code(cell, phase))
            << "phase=" << phase << " x=" << x << " y=" << y;
      }
    }
  }
}

TEST(SwtconPackerTest, PhaseGeneratorPacksVariableCount) {
  pluto::swtcon::SwtconWaveform waveform;
  load_synthetic_waveform(&waveform, /*phases=*/4);

  pluto::swtcon::SwtconPhaseGenerator generator(&waveform);
  generator.reset_previous(0x0000U);

  std::vector<std::uint8_t> next(pluto::swtcon::kLogicalFrameBytes);
  fill_rgb565(&next, 0xffff);
  PlutoSurface surface{};
  surface.pixels = next.data();
  surface.stride_bytes = pluto::swtcon::kLogicalStrideBytes;
  surface.width = pluto::swtcon::kLogicalWidth;
  surface.height = pluto::swtcon::kLogicalHeight;
  surface.format = kPlutoPixelFormatRgb565;
  const PlutoRect damage{0,
                           0,
                           pluto::swtcon::kLogicalWidth,
                           pluto::swtcon::kLogicalHeight};

  std::vector<std::uint16_t> packed;
  int phase_count = 0;
  std::string error;
  ASSERT_TRUE(generator.generate(surface, &damage, 1, kPlutoRefreshFull,
                                 25.0f, &packed, &phase_count, &error))
      << error;
  EXPECT_EQ(phase_count, 4);
  EXPECT_EQ(packed.size(),
            static_cast<std::size_t>(4) * pluto::swtcon::kDrmPhaseWords);
}

TEST(SwtconPackerTest, FlipSequencerUsesFifteenActiveSlotsModuloRing) {
  pluto::swtcon::SwtconFlipSequencer sequencer;
  for (std::size_t i = 0; i < pluto::swtcon::kActivePhaseSlots; ++i) {
    EXPECT_EQ(sequencer.next(), i);
  }
  EXPECT_EQ(sequencer.next(), static_cast<std::size_t>(0));
  EXPECT_EQ(sequencer.next(), static_cast<std::size_t>(1));
  sequencer.reset();
  EXPECT_EQ(sequencer.next(), static_cast<std::size_t>(0));
}
