#include "presenter/swtcon/phase_emit.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <cstring>
#include <map>
#include <random>
#include <set>
#include <string>
#include <vector>

#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_packer.h"
#include "presenter/swtcon/swtcon_waveform.h"
#include "swtcon_eink_synth.h"

namespace {

using pluto::swtcon::EmissionMode;
using pluto::swtcon::kDataWordCount;
using pluto::swtcon::kDrmHeight;
using pluto::swtcon::kDrmPhaseWords;
using pluto::swtcon::kDrmWidth;
using pluto::swtcon::kFirstDataRow;
using pluto::swtcon::kFirstDataWord;
using pluto::swtcon::kLastDataWord;
using pluto::swtcon::kLogicalHeight;
using pluto::swtcon::kLogicalWidth;
using pluto::swtcon::PhaseEmitter;
using pluto::swtcon::PhaseEmitterConfig;
using pluto::swtcon::PixelOp;

constexpr std::size_t kTightPitchBytes =
    static_cast<std::size_t>(kDrmWidth) * sizeof(std::uint16_t);

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

std::vector<std::uint16_t> make_template() {
  std::vector<std::uint16_t> frame(kDrmPhaseWords, 0);
  pluto::swtcon::init_blank_phase_frame(frame.data());
  return frame;
}

// A configured emitter with `slots` tight-pitch host targets, all primed.
struct EmitterHarness {
  PhaseEmitter emitter;
  std::vector<std::vector<std::uint16_t>> targets;

  explicit EmitterHarness(EmissionMode mode, std::size_t slots = 1) {
    PhaseEmitterConfig config;
    config.mode = mode;
    config.slot_count = slots;
    EXPECT_TRUE(emitter.configure(config));
    targets.resize(slots);
    for (std::size_t i = 0; i < slots; ++i) {
      targets[i].assign(kDrmPhaseWords, 0xffff);  // poison: prime must clear
      EXPECT_TRUE(
          emitter.set_slot_target(i, targets[i].data(), kTightPitchBytes));
      EXPECT_TRUE(emitter.blank_slot(i));
    }
  }
};

// Word-exact parity with the legacy packer (migration gate shape,
// re-targeted at deposit_code): identical full-frame content packed by
// SwtconPacker and emitted through PhaseEmitter must be byte-identical,
// phase plane by phase plane. The packer's own word-exact tests are the
// golden reference for the scaffold + lane encoding.
TEST(PhaseEmitterTest, WordExactParityWithSwtconPacker) {
  constexpr int kPhases = 3;
  pluto::swtcon::SwtconWaveform waveform;
  load_synthetic_waveform(&waveform, kPhases);

  // Non-trivial src/dst gray fields from RGB565 patterns.
  const std::uint16_t palette[3] = {0x0000, 0x7bef, 0xffff};
  std::vector<std::uint8_t> previous(pluto::swtcon::kLogicalFrameBytes);
  std::vector<std::uint8_t> next(pluto::swtcon::kLogicalFrameBytes);
  for (int y = 0; y < kLogicalHeight; ++y) {
    for (int x = 0; x < kLogicalWidth; ++x) {
      const std::uint16_t prev_value = palette[(x * 13 + y * 7) % 3];
      const std::uint16_t next_value = palette[(x + y) % 3];
      const std::size_t offset =
          static_cast<std::size_t>(y) * pluto::swtcon::kLogicalStrideBytes +
          static_cast<std::size_t>(x) * 2;
      previous[offset] = static_cast<std::uint8_t>(prev_value & 0xff);
      previous[offset + 1] = static_cast<std::uint8_t>(prev_value >> 8);
      next[offset] = static_cast<std::uint8_t>(next_value & 0xff);
      next[offset + 1] = static_cast<std::uint8_t>(next_value >> 8);
    }
  }

  pluto::swtcon::SourceFrame source;
  source.previous_pixels = previous.data();
  source.next_pixels = next.data();
  source.previous_stride_bytes = pluto::swtcon::kLogicalStrideBytes;
  source.next_stride_bytes = pluto::swtcon::kLogicalStrideBytes;

  pluto::swtcon::PhaseLookup lookup;
  lookup.waveform = &waveform;
  lookup.mode = pluto::swtcon::SwtconUpdateMode::kFull;  // .eink mode 2
  lookup.temperature_c = 25.0f;

  std::vector<std::uint16_t> packed;
  pluto::swtcon::SwtconPacker packer;
  std::string error;
  ASSERT_TRUE(packer.pack(source, lookup, &packed, &error)) << error;
  ASSERT_EQ(packed.size(), static_cast<std::size_t>(kPhases) * kDrmPhaseWords);

  const int bin = waveform.table().temp_bin(25.0f);
  EmitterHarness harness(EmissionMode::kRowStage, kPhases);
  std::vector<PixelOp> ops(static_cast<std::size_t>(kLogicalWidth));
  for (int phase = 0; phase < kPhases; ++phase) {
    const std::uint8_t* table = waveform.table().phase_table(2, bin, phase);
    ASSERT_TRUE(table != nullptr);
    ASSERT_TRUE(
        harness.emitter.begin_frame(static_cast<std::size_t>(phase),
                                    static_cast<std::uint64_t>(phase) + 1));
    for (int y = 0; y < kLogicalHeight; ++y) {
      for (int x = 0; x < kLogicalWidth; ++x) {
        const std::size_t offset =
            static_cast<std::size_t>(y) * pluto::swtcon::kLogicalStrideBytes +
            static_cast<std::size_t>(x) * 2;
        const auto load = [](const std::uint8_t* at) {
          return static_cast<std::uint16_t>(
              at[0] | (static_cast<std::uint16_t>(at[1]) << 8));
        };
        const std::uint8_t src =
            pluto::swtcon::rgb565_to_gray5(load(previous.data() + offset));
        const std::uint8_t dst =
            pluto::swtcon::rgb565_to_gray5(load(next.data() + offset));
        ops[static_cast<std::size_t>(x)] = {
            static_cast<std::uint16_t>(x),
            table[static_cast<std::size_t>(dst) * 32 + src]};
      }
      harness.emitter.emit_row(y, ops.data(), ops.size());
    }
    harness.emitter.end_frame();
    EXPECT_EQ(
        std::memcmp(
            harness.targets[static_cast<std::size_t>(phase)].data(),
            packed.data() + static_cast<std::size_t>(phase) * kDrmPhaseWords,
            kDrmPhaseWords * sizeof(std::uint16_t)),
        0)
        << "phase " << phase << " diverges from SwtconPacker::pack";
  }
}

// Scaffold preservation property (control words/rows are never altered
// by ANY emission sequence): 200 fuzzed random emission patterns, then
// every control bit/word is byte-compared against the template.
TEST(PhaseEmitterTest, FuzzedEmissionsNeverTouchTheControlScaffold) {
  EmitterHarness harness(EmissionMode::kRowStage, 1);
  const std::vector<std::uint16_t> expected_template = make_template();
  std::mt19937 rng(0x5eed);

  for (int frame = 0; frame < 200; ++frame) {
    ASSERT_TRUE(
        harness.emitter.begin_frame(0, static_cast<std::uint64_t>(frame) + 1));
    const int row_count = static_cast<int>(rng() % 9);
    std::set<int> rows;
    while (static_cast<int>(rows.size()) < row_count) {
      rows.insert(static_cast<int>(rng() % kLogicalHeight));
    }
    std::vector<PixelOp> ops;
    for (const int row : rows) {
      ops.clear();
      const int op_count = static_cast<int>(rng() % 65);
      std::set<int> columns;
      while (static_cast<int>(columns.size()) < op_count) {
        columns.insert(static_cast<int>(rng() % kLogicalWidth));
      }
      for (const int x : columns) {  // ascending, engine contract
        ops.push_back({static_cast<std::uint16_t>(x),
                       static_cast<std::uint8_t>(rng() % 8)});
      }
      harness.emitter.emit_row(row, ops.data(), ops.size());
    }
    harness.emitter.end_frame();

    // Scaffold invariant sweep (plain scan; assert only on violation so
    // the 200x620k-word fuzz stays fast).
    int bad_row = -1;
    int bad_word = -1;
    for (int y = 0; y < kDrmHeight && bad_row < 0; ++y) {
      const std::uint16_t* got =
          harness.targets[0].data() + static_cast<std::size_t>(y) * kDrmWidth;
      const std::uint16_t* want =
          expected_template.data() + static_cast<std::size_t>(y) * kDrmWidth;
      const bool data_row =
          y >= kFirstDataRow && y < pluto::swtcon::kTrailingControlRow;
      for (int word = 0; word < kDrmWidth; ++word) {
        const bool data_word = word >= kFirstDataWord && word <= kLastDataWord;
        // Pixel lanes of data words may differ; control bits[15:12] may
        // not; everything else must be byte-equal to the template.
        const bool ok = (data_row && data_word)
                            ? (got[word] & 0xf000) == (want[word] & 0xf000)
                            : got[word] == want[word];
        if (!ok) {
          bad_row = y;
          bad_word = word;
          break;
        }
      }
    }
    ASSERT_EQ(bad_row, -1) << "frame=" << frame << " row=" << bad_row
                           << " word=" << bad_word;
  }
}

// Slot-reuse-after-clip-shrink golden (mandatory decision): a slot's
// second use after the active clip shrank must re-blank every row its
// previous use wrote — stale-code re-drive impossible by construction.
TEST(PhaseEmitterTest, SlotReuseAfterClipShrinkReblanksStaleRows) {
  EmitterHarness harness(EmissionMode::kRowStage, 1);
  const std::vector<std::uint16_t> expected_template = make_template();

  const auto emit_rows = [&](int first_row, int last_row, std::uint8_t code,
                             std::uint64_t seq) {
    ASSERT_TRUE(harness.emitter.begin_frame(0, seq));
    for (int row = first_row; row <= last_row; ++row) {
      PixelOp ops[3] = {{100, code}, {101, code}, {900, code}};
      harness.emitter.emit_row(row, ops, 3);
    }
  };

  // First use: wide clip, push-black codes on rows 10..40.
  emit_rows(10, 40, /*code=*/6, /*seq=*/1);
  EXPECT_EQ(harness.emitter.end_frame(), 0u);
  EXPECT_TRUE(harness.emitter.row_dirty(0, 40));

  // Second use (ring wrapped back to the slot): the clip shrank to 10..20.
  emit_rows(10, 20, /*code=*/3, /*seq=*/2);
  EXPECT_EQ(harness.emitter.end_frame(), 20u);  // rows 21..40 re-blanked

  EXPECT_TRUE(harness.emitter.row_dirty(0, 15));
  EXPECT_FALSE(harness.emitter.row_dirty(0, 25));
  EXPECT_EQ(harness.emitter.slot_seq(0), 2u);

  // Golden sweep: the whole plane equals the blank template except the
  // data windows of rows 10..20 (which carry this frame's deposits).
  for (int y = 0; y < kDrmHeight; ++y) {
    const std::uint16_t* got =
        harness.targets[0].data() + static_cast<std::size_t>(y) * kDrmWidth;
    const std::uint16_t* want =
        expected_template.data() + static_cast<std::size_t>(y) * kDrmWidth;
    const int logical = y - kFirstDataRow;
    if (logical >= 10 && logical <= 20) {
      // Deposited rows: control bits intact, lanes for x=100,101,900 = 3.
      ASSERT_EQ(got[kFirstDataWord + 100 / 4] & 0xf000,
                want[kFirstDataWord + 100 / 4] & 0xf000);
      const std::uint16_t word = got[kFirstDataWord + 100 / 4];
      ASSERT_EQ((word >> (9 - 3 * (100 % 4))) & 0x7, 3) << "row " << y;
      ASSERT_EQ((word >> (9 - 3 * (101 % 4))) & 0x7, 3) << "row " << y;
      continue;
    }
    ASSERT_EQ(std::memcmp(got, want, kTightPitchBytes), 0)
        << "stale codes survived on DRM row " << y;
  }
}

// The kShadowCopy fallback (copy_phase_to_buffer shape) must publish
// byte-identical planes to the default write-only row staging.
TEST(PhaseEmitterTest, StagingAndCopyModesEmitIdenticalBytes) {
  EmitterHarness stage(EmissionMode::kRowStage, 2);
  EmitterHarness copy(EmissionMode::kShadowCopy, 2);
  EXPECT_TRUE(stage.emitter.shadow_words(0) == nullptr);
  ASSERT_TRUE(copy.emitter.shadow_words(0) != nullptr);

  std::mt19937 rng(0xd1ce);
  for (int frame = 0; frame < 60; ++frame) {
    const std::size_t slot = static_cast<std::size_t>(frame) % 2;
    const std::uint64_t seq = static_cast<std::uint64_t>(frame) + 1;
    ASSERT_TRUE(stage.emitter.begin_frame(slot, seq));
    ASSERT_TRUE(copy.emitter.begin_frame(slot, seq));

    const int row_count = static_cast<int>(rng() % 6);
    std::set<int> rows;
    while (static_cast<int>(rows.size()) < row_count) {
      rows.insert(static_cast<int>(rng() % kLogicalHeight));
    }
    std::vector<PixelOp> ops;
    for (const int row : rows) {
      ops.clear();
      std::set<int> columns;
      const int op_count = 1 + static_cast<int>(rng() % 32);
      while (static_cast<int>(columns.size()) < op_count) {
        columns.insert(static_cast<int>(rng() % kLogicalWidth));
      }
      for (const int x : columns) {
        ops.push_back({static_cast<std::uint16_t>(x),
                       static_cast<std::uint8_t>(rng() % 8)});
      }
      stage.emitter.emit_row(row, ops.data(), ops.size());
      copy.emitter.emit_row(row, ops.data(), ops.size());
    }
    stage.emitter.end_frame();
    copy.emitter.end_frame();

    ASSERT_EQ(std::memcmp(stage.targets[slot].data(), copy.targets[slot].data(),
                          kDrmPhaseWords * sizeof(std::uint16_t)),
              0)
        << "modes diverged at frame " << frame;
  }
}

// blank_slot must produce exactly init_blank_phase_frame bytes (the HOLD
// slot's permanent content), honoring a padded target pitch.
TEST(PhaseEmitterTest, BlankSlotWritesTheScaffoldHonoringPitch) {
  const std::size_t pitch_words = static_cast<std::size_t>(kDrmWidth) + 5;
  std::vector<std::uint16_t> target(pitch_words * kDrmHeight, 0xffff);

  PhaseEmitter emitter;
  PhaseEmitterConfig config;
  config.slot_count = 1;
  ASSERT_TRUE(emitter.configure(config));
  ASSERT_TRUE(emitter.set_slot_target(0, target.data(),
                                      pitch_words * sizeof(std::uint16_t)));
  ASSERT_TRUE(emitter.blank_slot(0));

  const std::vector<std::uint16_t> expected_template = make_template();
  for (int y = 0; y < kDrmHeight; ++y) {
    ASSERT_EQ(
        std::memcmp(
            target.data() + static_cast<std::size_t>(y) * pitch_words,
            expected_template.data() + static_cast<std::size_t>(y) * kDrmWidth,
            kTightPitchBytes),
        0)
        << "row " << y;
    // Padding words beyond the plane row stay untouched.
    for (std::size_t pad = kDrmWidth; pad < pitch_words; ++pad) {
      ASSERT_EQ(target[static_cast<std::size_t>(y) * pitch_words + pad],
                0xffff);
    }
  }

  // A deposit lands at the pitched row offset.
  ASSERT_TRUE(emitter.begin_frame(0, 1));
  PixelOp op{0, 5};
  emitter.emit_row(0, &op, 1);
  emitter.end_frame();
  const std::uint16_t word =
      target[static_cast<std::size_t>(kFirstDataRow) * pitch_words +
             kFirstDataWord];
  EXPECT_EQ((word >> 9) & 0x7, 5);
  EXPECT_EQ(
      word & 0xf000,
      expected_template[static_cast<std::size_t>(kFirstDataRow) * kDrmWidth +
                        kFirstDataWord] &
          0xf000);
}

// Engine-driven slot-lifecycle fuzz (the stale-code panel-safety
// invariant, end to end): thousands of scan frames of random
// admissions (small rects, band-amortized fulls, guard-null, settles,
// force-identity), random pauses and random temp-bin flips through the
// REAL PixelEngine -> PhaseEmitter path on the presenter's 15-slot
// rotation. After EVERY built frame, the built plane must satisfy, row by
// row: rows the engine did not emit this frame are byte-identical to the
// blank scaffold template (a reused slot's stale rows re-blanked — codes
// from an older frame can never scan again), and emitted rows keep all
// control bits/words intact. This is the fuzzed generalization of the
// deterministic slot-reuse golden above and of the L0 trace scenarios.
TEST(PhaseEmitterTest, EngineDrivenSlotLifecycleFuzzKeepsStaleRowsBlank) {
  using pluto::swtcon::AdmitRequest;
  using pluto::swtcon::kActivePhaseSlots;
  using pluto::swtcon::kAdmitFlagForceIdentity;
  using pluto::swtcon::kAdmitFlagGuardNull;
  using pluto::swtcon::kAdmitFlagSettle;
  using pluto::swtcon::PixelEngine;
  using pluto::swtcon::PixelEngineConfig;
  using pluto::swtcon::WaveformTable;

  // Two-bin synthetic .eink through the real decoder (the
  // pixel_engine_test container shape): mode 2 = 4 phases in bin 0 /
  // 3 phases in bin 1 (bin flips change the record), mode 7 = 2 phases.
  const auto make_codes = [](int phases, int mul, int add) {
    std::vector<std::uint8_t> codes(static_cast<std::size_t>(phases) *
                                    swtcon_synth::kCells);
    for (int phase = 0; phase < phases; ++phase) {
      for (int cell = 0; cell < swtcon_synth::kCells; ++cell) {
        codes[static_cast<std::size_t>(phase) * swtcon_synth::kCells +
              static_cast<std::size_t>(cell)] =
            static_cast<std::uint8_t>((cell * mul + phase + add) % 7);
      }
    }
    return codes;
  };
  const std::vector<std::vector<std::uint8_t>> records = {
      swtcon_synth::record_from_codes(
          std::vector<std::uint8_t>(swtcon_synth::kCells, 0)),
      swtcon_synth::record_from_codes(make_codes(4, 1, 0)),
      swtcon_synth::record_from_codes(make_codes(3, 2, 1)),
      swtcon_synth::record_from_codes(make_codes(2, 3, 2)),
  };
  std::vector<std::size_t> record_for(16, 0);
  record_for[2 * 2 + 0] = 1;
  record_for[2 * 2 + 1] = 2;
  record_for[7 * 2 + 0] = 3;
  record_for[7 * 2 + 1] = 3;
  WaveformTable table;
  std::string error;
  ASSERT_TRUE(table.parse(swtcon_synth::wrap_eink(swtcon_synth::build_container(
                              8, 2, {0, 20}, records, record_for)),
                          &error))
      << error;

  PixelEngineConfig config;
  config.width = kLogicalWidth;
  config.height = kLogicalHeight;
  config.stride = pluto::swtcon::kPaddedSourceWidth;
  config.tile_px = 32;
  config.max_active_px = 200000;  // small enough to hit band + budget paths
  config.full_flash_band_frames = 3;
  PixelEngine engine;
  ASSERT_TRUE(engine.configure(&table, config));
  engine.set_temperature(10.0f);

  EmitterHarness harness(EmissionMode::kRowStage, kActivePhaseSlots);
  const std::vector<std::uint16_t> expected_template = make_template();

  // Forwards engine rows into the emitter while recording which logical
  // rows this frame touched (the per-frame blankness oracle).
  struct ForwardingEmitter final : pluto::swtcon::RowEmitter {
    PhaseEmitter* inner = nullptr;
    std::vector<int> rows;
    void emit_row(int row, const PixelOp* ops, std::size_t count) override {
      rows.push_back(row);
      inner->emit_row(row, ops, count);
    }
  };
  ForwardingEmitter forward;
  forward.inner = &harness.emitter;

  std::mt19937 rng(0xfa57);
  std::vector<std::uint8_t> levels;
  std::vector<std::uint8_t> emitted_drm_row(
      static_cast<std::size_t>(kDrmHeight), 0);
  std::uint64_t builds = 0;
  std::uint64_t frames_with_content = 0;
  constexpr int kFuzzFrames = 10000;

  for (int frame = 0; frame < kFuzzFrames; ++frame) {
    // Random admissions; always feed an idle engine so slots keep cycling.
    const int admissions =
        engine.idle() ? 1
                      : (rng() % 4 == 0 ? 1 + static_cast<int>(rng() % 2) : 0);
    for (int i = 0; i < admissions; ++i) {
      AdmitRequest request;
      const std::uint32_t dice = rng() % 100;
      if (rng() % 500 == 0) {
        // Full-field flash: exercises band amortization + budget deferral
        // (kept rare — each one sweeps ~1.6 Mpx for a dozen frames).
        request.rect = {0, 0, kLogicalWidth, kLogicalHeight};
      } else {
        const int w = 1 + static_cast<int>(rng() % 128);
        const int h = 1 + static_cast<int>(rng() % 128);
        request.rect = {
            static_cast<std::int32_t>(
                rng() % static_cast<std::uint32_t>(kLogicalWidth - w)),
            static_cast<std::int32_t>(
                rng() % static_cast<std::uint32_t>(kLogicalHeight - h)),
            w, h};
      }
      request.mode = (rng() % 3 == 0) ? 7 : 2;
      request.frame_id = static_cast<std::uint64_t>(frame) + 1;
      if (dice >= 90) {
        request.flags = kAdmitFlagGuardNull;  // header-only null drive
      } else {
        if (dice >= 80) {
          request.flags = kAdmitFlagSettle;
          request.frame_id = 0;  // settle sentinel
        } else if (dice >= 75) {
          request.flags = kAdmitFlagForceIdentity;
        }
        levels.resize(static_cast<std::size_t>(request.rect.width) *
                      static_cast<std::size_t>(request.rect.height));
        for (std::uint8_t& level : levels) {
          level = static_cast<std::uint8_t>(rng() % 32);
        }
        request.levels = levels.data();
      }
      ASSERT_TRUE(engine.admit(request));
    }

    if (rng() % 10 == 0) {
      engine.pause();  // missed deadline: no build, no fnum motion
    }
    if (rng() % 50 == 0) {
      engine.set_temperature(rng() % 2 == 0 ? 10.0f : 40.0f);  // bin flip
    }

    if (engine.idle() && engine.parked_count() == 0) {
      continue;  // presenter semantics: no build while idle
    }
    const std::size_t slot =
        static_cast<std::size_t>(builds % kActivePhaseSlots);
    forward.rows.clear();
    ASSERT_TRUE(harness.emitter.begin_frame(slot, builds + 1));
    engine.advance(&forward);
    harness.emitter.end_frame();
    ++builds;
    if (!forward.rows.empty()) {
      ++frames_with_content;
    }

    // THE invariant sweep: non-emitted rows == blank template, emitted
    // rows preserve every control word/bit (assert only on violation so
    // the 10k x 620k-word fuzz stays fast).
    std::fill(emitted_drm_row.begin(), emitted_drm_row.end(), 0);
    for (const int row : forward.rows) {
      emitted_drm_row[static_cast<std::size_t>(row + kFirstDataRow)] = 1;
    }
    const std::uint16_t* plane = harness.targets[slot].data();
    int bad_row = -1;
    for (int y = 0; y < kDrmHeight; ++y) {
      const std::uint16_t* got =
          plane + static_cast<std::size_t>(y) * kDrmWidth;
      const std::uint16_t* want =
          expected_template.data() + static_cast<std::size_t>(y) * kDrmWidth;
      if (emitted_drm_row[static_cast<std::size_t>(y)] == 0) {
        if (std::memcmp(got, want, kTightPitchBytes) != 0) {
          bad_row = y;
          break;
        }
        continue;
      }
      if (std::memcmp(got, want,
                      static_cast<std::size_t>(kFirstDataWord) *
                          sizeof(std::uint16_t)) != 0 ||
          std::memcmp(got + kLastDataWord + 1, want + kLastDataWord + 1,
                      static_cast<std::size_t>(kDrmWidth - kLastDataWord - 1) *
                          sizeof(std::uint16_t)) != 0) {
        bad_row = y;
        break;
      }
      for (int word = kFirstDataWord; word <= kLastDataWord; ++word) {
        if (((got[word] ^ want[word]) & 0xf000) != 0) {
          bad_row = y;
          break;
        }
      }
      if (bad_row >= 0) {
        break;
      }
    }
    ASSERT_EQ(bad_row, -1) << "frame=" << frame << " slot=" << slot
                           << " drm_row=" << bad_row
                           << ": stale/corrupt bytes in a built plane";
  }

  // The fuzz must actually have exercised the interesting machinery.
  EXPECT_GT(frames_with_content, 1000u);
  EXPECT_GT(engine.stats().tiles_started, 1000u);
  EXPECT_GT(engine.stats().bands_deferred, 0u);
  EXPECT_GT(engine.stats().pauses, 0u);
  EXPECT_GT(engine.stats().tiles_parked, 0u);
  EXPECT_GT(harness.emitter.stats().rows_reblanked, 0u);
}

TEST(PhaseEmitterTest, RejectsInvalidConfigurationAndSequencing) {
  PhaseEmitter emitter;
  PhaseEmitterConfig config;
  config.slot_count = 0;
  EXPECT_FALSE(emitter.configure(config));

  config.slot_count = 2;
  ASSERT_TRUE(emitter.configure(config));
  std::vector<std::uint16_t> target(kDrmPhaseWords, 0);

  // Bad pitch / slot index / null target.
  EXPECT_FALSE(emitter.set_slot_target(0, target.data(), kDrmWidth));  // < row
  EXPECT_FALSE(emitter.set_slot_target(5, target.data(), kTightPitchBytes));
  EXPECT_FALSE(emitter.set_slot_target(0, nullptr, kTightPitchBytes));

  // begin_frame before attach/prime fails.
  EXPECT_FALSE(emitter.begin_frame(0, 1));
  ASSERT_TRUE(emitter.set_slot_target(0, target.data(), kTightPitchBytes));
  EXPECT_FALSE(emitter.begin_frame(0, 1));  // attached but never primed
  ASSERT_TRUE(emitter.blank_slot(0));
  ASSERT_TRUE(emitter.begin_frame(0, 1));
  EXPECT_FALSE(emitter.begin_frame(0, 2));  // one frame open at a time
  EXPECT_FALSE(emitter.blank_slot(0));      // no re-prime mid-frame
  emitter.end_frame();
  EXPECT_EQ(emitter.end_frame(), 0u);  // idempotent when closed
}

}  // namespace
