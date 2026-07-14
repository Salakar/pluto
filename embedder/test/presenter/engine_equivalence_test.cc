// THE EQUIVALENCE PROOF (the migration gate — the strongest scan-protocol
// guarantee available on host): for single uniform-region
// admissions, the new per-pixel engine + PhaseEmitter must produce, frame
// by frame, BYTE-IDENTICAL phase-plane sequences to the legacy
// SwtconPacker record-playback pipeline given the same waveform table,
// the same content, and the same 15-slot rotation. This proof gated the
// deletion of the old drive core from drm_swtcon_presenter.cc; the packer
// survives ONLY as the reference oracle in this test binary.
//
// Scenario map (mission scope: DU rect, GC16 full-screen, GC16 partial):
//   1. GC16 full-screen, ForceIdentity, identity-DRIVING table: every
//      pixel fnum=0, including identity flash
//      cells — engine codes must equal the packer's cell codes everywhere.
//   2. DU rect, transition-driven, identity-HOLD table: outside the rect
//      (and for unchanged pixels inside it) the packer emits the identity
//      cell = code 0, exactly matching the engine's undriven pixels — the
//      old presenter's regional-hold semantics reproduced byte-exactly.
//   3. GC16 partial rect on a 17-phase mode: wraps the 15-slot ring, so
//      slot reuse (re-blank + re-deposit) is part of the parity claim.

#include "presenter/swtcon/phase_emit.h"
#include "presenter/swtcon/pixel_engine.h"
#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_packer.h"
#include "presenter/swtcon/swtcon_waveform.h"

#include "swtcon_eink_synth.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace {

using pluto::swtcon::AdmitRequest;
using pluto::swtcon::EmissionMode;
using pluto::swtcon::kActivePhaseSlots;
using pluto::swtcon::kAdmitFlagForceIdentity;
using pluto::swtcon::kDrmPhaseWords;
using pluto::swtcon::kDrmWidth;
using pluto::swtcon::kLogicalFrameBytes;
using pluto::swtcon::kLogicalHeight;
using pluto::swtcon::kLogicalStrideBytes;
using pluto::swtcon::kLogicalWidth;
using pluto::swtcon::PhaseEmitter;
using pluto::swtcon::PhaseEmitterConfig;
using pluto::swtcon::PhaseLookup;
using pluto::swtcon::PixelEngine;
using pluto::swtcon::PixelEngineConfig;
using pluto::swtcon::rgb565_to_gray5;
using pluto::swtcon::SwtconPacker;
using pluto::swtcon::SwtconUpdateMode;
using pluto::swtcon::SwtconWaveform;

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

// cell = dst5 * 32 + src5 (decoder-native); identity cells are the 32
// multiples of 33.
bool identity_cell(int cell) { return cell % 33 == 0; }

std::vector<std::uint8_t> make_codes(int phases, int mul, int add,
                                     bool identity_hold) {
  std::vector<std::uint8_t> codes(
      static_cast<std::size_t>(phases) * swtcon_synth::kCells);
  for (int phase = 0; phase < phases; ++phase) {
    for (int cell = 0; cell < swtcon_synth::kCells; ++cell) {
      const std::uint8_t code =
          identity_hold && identity_cell(cell)
              ? 0
              : static_cast<std::uint8_t>((cell * mul + phase + add) % 7);
      codes[static_cast<std::size_t>(phase) * swtcon_synth::kCells +
            static_cast<std::size_t>(cell)] = code;
    }
  }
  return codes;
}

// 8-mode x 1-temp synthetic .eink through the REAL decoder:
//   mode 2 (Full/GC16 index): full_phases, identity-driving or identity-hold
//   mode 7 (Fast/Ui index):   2 phases, identity-hold
//   other modes: 1-phase all-hold
std::vector<std::uint8_t> make_equivalence_eink(int full_phases,
                                                bool full_identity_hold) {
  const int nmode = 8;
  const int ntemp = 1;
  const std::vector<std::vector<std::uint8_t>> records = {
      swtcon_synth::record_from_codes(
          std::vector<std::uint8_t>(swtcon_synth::kCells, 0)),
      swtcon_synth::record_from_codes(
          make_codes(full_phases, 1, 0, full_identity_hold)),
      swtcon_synth::record_from_codes(
          make_codes(2, 3, 2, /*identity_hold=*/true)),
  };
  std::vector<std::size_t> record_for(static_cast<std::size_t>(nmode), 0);
  record_for[2] = 1;
  record_for[7] = 2;
  return swtcon_synth::wrap_eink(
      swtcon_synth::build_container(nmode, ntemp, {60}, records, record_for));
}

void load_waveform(SwtconWaveform* waveform,
                   const std::vector<std::uint8_t>& eink) {
  FakeWaveformReader reader;
  reader.files["equivalence.eink"] = eink;
  SwtconWaveform::Files files;
  files.eink_path = "equivalence.eink";
  files.ct33_std_path.clear();
  files.ct33_best_path.clear();
  files.ct33_pen_path.clear();
  files.ct33_fast_path.clear();
  std::string error;
  ASSERT_TRUE(waveform->load(files, reader, &error)) << error;
  ASSERT_TRUE(waveform->table().valid());
}

void store_rgb565(std::vector<std::uint8_t>* frame, int x, int y,
                  std::uint16_t value) {
  const std::size_t offset =
      static_cast<std::size_t>(y) * kLogicalStrideBytes +
      static_cast<std::size_t>(x) * 2;
  (*frame)[offset] = static_cast<std::uint8_t>(value & 0xffU);
  (*frame)[offset + 1] = static_cast<std::uint8_t>(value >> 8);
}

// Engine + emitter with the presenter's slot rotation (build k -> slot
// k % 15, the old SwtconFlipSequencer order) over host planes.
struct EngineHarness {
  PixelEngine engine;
  PhaseEmitter emitter;
  std::vector<std::vector<std::uint16_t>> slots;
  std::uint64_t builds = 0;

  explicit EngineHarness(const pluto::swtcon::WaveformTable* table) {
    PixelEngineConfig config;
    config.width = kLogicalWidth;
    config.height = kLogicalHeight;
    config.stride = pluto::swtcon::kPaddedSourceWidth;
    config.tile_px = 32;
    // The proof drives one uniform admission with no pacing interference:
    // budget above the panel, so a full-field admission is ONE piece
    // (banding is pinned separately by the L0 goldens).
    config.max_active_px =
        static_cast<std::uint32_t>(kLogicalWidth) * kLogicalHeight + 1;
    config.initial_prev_level = 30;  // matches an all-0xffff previous frame
                                     // on the renderer lattice (white = 30)
    EXPECT_TRUE(engine.configure(table, config));

    PhaseEmitterConfig emitter_config;
    emitter_config.mode = EmissionMode::kRowStage;
    emitter_config.slot_count = kActivePhaseSlots;
    EXPECT_TRUE(emitter.configure(emitter_config));
    slots.assign(kActivePhaseSlots,
                 std::vector<std::uint16_t>(kDrmPhaseWords, 0));
    for (std::size_t slot = 0; slot < kActivePhaseSlots; ++slot) {
      EXPECT_TRUE(
          emitter.set_slot_target(slot, slots[slot].data(), kTightPitchBytes));
      EXPECT_TRUE(emitter.blank_slot(slot));
    }
  }

  // One scan frame; returns the slot index that was built.
  std::size_t build() {
    const std::size_t slot = static_cast<std::size_t>(builds % kActivePhaseSlots);
    EXPECT_TRUE(emitter.begin_frame(slot, builds + 1));
    engine.advance(&emitter);
    emitter.end_frame();
    ++builds;
    return slot;
  }
};

// Levels for the engine: rgb565_to_gray5 of the next frame inside `rect`,
// tight rect.width pitch — exactly the presenter's conversion.
std::vector<std::uint8_t> levels_of(const std::vector<std::uint8_t>& frame,
                                    const PlutoRect& rect) {
  std::vector<std::uint8_t> levels(static_cast<std::size_t>(rect.width) *
                                   static_cast<std::size_t>(rect.height));
  for (int y = 0; y < rect.height; ++y) {
    for (int x = 0; x < rect.width; ++x) {
      const std::size_t offset =
          static_cast<std::size_t>(rect.y + y) * kLogicalStrideBytes +
          static_cast<std::size_t>(rect.x + x) * 2;
      const std::uint16_t px = static_cast<std::uint16_t>(
          frame[offset] | (static_cast<std::uint16_t>(frame[offset + 1]) << 8));
      levels[static_cast<std::size_t>(y) * rect.width + x] =
          rgb565_to_gray5(px);
    }
  }
  return levels;
}

// Reference: legacy full-frame record playback.
std::vector<std::uint16_t> pack_reference(const SwtconWaveform& waveform,
                                          SwtconUpdateMode mode,
                                          const std::vector<std::uint8_t>& prev,
                                          const std::vector<std::uint8_t>& next,
                                          int expect_phases) {
  pluto::swtcon::SourceFrame source;
  source.previous_pixels = prev.data();
  source.next_pixels = next.data();
  source.previous_stride_bytes = kLogicalStrideBytes;
  source.next_stride_bytes = kLogicalStrideBytes;
  PhaseLookup lookup;
  lookup.waveform = &waveform;
  lookup.mode = mode;
  lookup.temperature_c = 25.0f;
  std::vector<std::uint16_t> packed;
  SwtconPacker packer;
  std::string error;
  EXPECT_TRUE(packer.pack(source, lookup, &packed, &error)) << error;
  EXPECT_EQ(packed.size(),
            static_cast<std::size_t>(expect_phases) * kDrmPhaseWords);
  return packed;
}

// Frame-by-frame proof body: admit one region, then compare every built
// plane against the packer's plane for the same phase, byte for byte, on
// the shared slot rotation. Afterwards the engine must be idle and a
// further build must emit nothing.
void prove_equivalence(EngineHarness* harness,
                       const std::vector<std::uint16_t>& packed,
                       int phases) {
  std::size_t last_slot = 0;
  for (int phase = 0; phase < phases; ++phase) {
    const std::size_t slot = harness->build();
    ASSERT_EQ(std::memcmp(
                  harness->slots[slot].data(),
                  packed.data() + static_cast<std::size_t>(phase) *
                                      kDrmPhaseWords,
                  kDrmPhaseWords * sizeof(std::uint16_t)),
              0)
        << "phase " << phase << " (slot " << slot
        << ") diverges from SwtconPacker record playback";
    last_slot = slot;
  }
  (void)last_slot;
  EXPECT_TRUE(harness->engine.idle());
  // Post-completion build: nothing driven, nothing emitted (the presenter
  // would not publish; the scan parks on HOLD).
  const std::uint64_t rows_before = harness->emitter.stats().rows_emitted;
  harness->build();
  EXPECT_EQ(harness->emitter.stats().rows_emitted, rows_before);
}

}  // namespace

// Scenario 1 — GC16 full-screen, every pixel fnum=0 (ForceIdentity), on an
// identity-DRIVING table.
TEST(EngineEquivalenceTest, Gc16FullScreenMatchesPackerByteForByte) {
  constexpr int kPhases = 4;
  SwtconWaveform waveform;
  load_waveform(&waveform, make_equivalence_eink(kPhases,
                                                 /*full_identity_hold=*/false));

  std::vector<std::uint8_t> prev(kLogicalFrameBytes);
  std::vector<std::uint8_t> next(kLogicalFrameBytes);
  const std::uint16_t palette[4] = {0x0000, 0x7bef, 0x8410, 0xffff};
  for (int y = 0; y < kLogicalHeight; ++y) {
    for (int x = 0; x < kLogicalWidth; ++x) {
      store_rgb565(&prev, x, y, 0xffff);
      store_rgb565(&next, x, y, palette[(x * 7 + y * 3) % 4]);
    }
  }
  const std::vector<std::uint16_t> packed =
      pack_reference(waveform, SwtconUpdateMode::kFull, prev, next, kPhases);

  EngineHarness harness(&waveform.table());
  const PlutoRect rect{0, 0, kLogicalWidth, kLogicalHeight};
  const std::vector<std::uint8_t> levels = levels_of(next, rect);
  AdmitRequest request;
  request.rect = rect;
  request.mode = 2;
  request.levels = levels.data();
  request.frame_id = 1;
  request.flags = kAdmitFlagForceIdentity;
  ASSERT_TRUE(harness.engine.admit(request));
  ASSERT_EQ(harness.engine.total_active_px(),
            static_cast<std::uint32_t>(kLogicalWidth) * kLogicalHeight);

  prove_equivalence(&harness, packed, kPhases);
}

// Scenario 2 — DU rect, transition-driven, identity-HOLD table: undriven
// pixels (outside the rect, unchanged inside it) equal the packer's
// identity cells byte-for-byte.
TEST(EngineEquivalenceTest, DuRectMatchesPackerByteForByte) {
  constexpr int kPhases = 2;  // mode 7 record
  SwtconWaveform waveform;
  load_waveform(&waveform, make_equivalence_eink(3,
                                                 /*full_identity_hold=*/true));

  const PlutoRect rect{72, 200, 130, 90};
  std::vector<std::uint8_t> prev(kLogicalFrameBytes);
  std::vector<std::uint8_t> next(kLogicalFrameBytes);
  for (int y = 0; y < kLogicalHeight; ++y) {
    for (int x = 0; x < kLogicalWidth; ++x) {
      store_rgb565(&prev, x, y, 0xffff);
      std::uint16_t value = 0xffff;
      if (x >= rect.x && x < rect.x + rect.width && y >= rect.y &&
          y < rect.y + rect.height) {
        // Mostly black with white speckles: unchanged pixels inside the
        // rect exercise the identity-hold path.
        value = ((x + y) % 5 == 0) ? 0xffff : 0x0000;
      }
      store_rgb565(&next, x, y, value);
    }
  }
  const std::vector<std::uint16_t> packed =
      pack_reference(waveform, SwtconUpdateMode::kFast, prev, next, kPhases);

  EngineHarness harness(&waveform.table());
  const std::vector<std::uint8_t> levels = levels_of(next, rect);
  AdmitRequest request;
  request.rect = rect;
  request.mode = 7;
  request.levels = levels.data();
  request.frame_id = 1;
  ASSERT_TRUE(harness.engine.admit(request));

  prove_equivalence(&harness, packed, kPhases);
}

// Scenario 3 — GC16 partial rect on a 17-phase mode: the waveform outlives
// the 15-slot ring, so parity covers slot reuse (stale-row re-blank + new
// deposits) exactly as the scan would replay it.
TEST(EngineEquivalenceTest, Gc16PartialRectWrapsSlotRingByteForByte) {
  constexpr int kPhases = 17;
  SwtconWaveform waveform;
  load_waveform(&waveform, make_equivalence_eink(kPhases,
                                                 /*full_identity_hold=*/true));

  const PlutoRect rect{96, 512, 240, 128};
  std::vector<std::uint8_t> prev(kLogicalFrameBytes);
  std::vector<std::uint8_t> next(kLogicalFrameBytes);
  const std::uint16_t palette[3] = {0x0000, 0x8410, 0x7bef};
  for (int y = 0; y < kLogicalHeight; ++y) {
    for (int x = 0; x < kLogicalWidth; ++x) {
      store_rgb565(&prev, x, y, 0xffff);
      std::uint16_t value = 0xffff;
      if (x >= rect.x && x < rect.x + rect.width && y >= rect.y &&
          y < rect.y + rect.height) {
        value = palette[(x * 3 + y) % 3];
      }
      store_rgb565(&next, x, y, value);
    }
  }
  const std::vector<std::uint16_t> packed =
      pack_reference(waveform, SwtconUpdateMode::kFull, prev, next, kPhases);

  EngineHarness harness(&waveform.table());
  const std::vector<std::uint8_t> levels = levels_of(next, rect);
  AdmitRequest request;
  request.rect = rect;
  request.mode = 2;
  request.levels = levels.data();
  request.frame_id = 1;
  ASSERT_TRUE(harness.engine.admit(request));

  prove_equivalence(&harness, packed, kPhases);
}

// Regression for the stale-content bug: black -> white erase must EMIT
// nonzero drive codes on a sparse (real-panel-shaped) table whose white
// drive lives at dst 30 — and targeting the rail slot 31 is optically
// inert (all-hold), which is why content must never be quantized to 31.
// The engine's prev/glass oracle cannot see this (prev promotes either
// way); only the emitted planes can.
TEST(EngineEquivalenceTest, EraseToWhiteEmitsDriveCodesOnSparseTable) {
  constexpr int kPhases = 2;
  // Mode 1 drives only dst 0 (code 6) and dst 30 (code 1); dst 31 holds.
  std::vector<std::uint8_t> init_codes(
      static_cast<std::size_t>(kPhases) * swtcon_synth::kCells, 1);
  std::vector<std::uint8_t> sparse_codes(
      static_cast<std::size_t>(kPhases) * swtcon_synth::kCells, 0);
  for (int phase = 0; phase < kPhases; ++phase) {
    for (int src = 0; src < 32; ++src) {
      sparse_codes[static_cast<std::size_t>(phase) * swtcon_synth::kCells +
                   0 * 32 + src] = 6;
      sparse_codes[static_cast<std::size_t>(phase) * swtcon_synth::kCells +
                   30 * 32 + src] = 1;
    }
  }
  SwtconWaveform waveform;
  load_waveform(&waveform,
                swtcon_synth::wrap_eink(swtcon_synth::build_container(
                    3, 1, {60},
                    {swtcon_synth::record_from_codes(init_codes),
                     swtcon_synth::record_from_codes(sparse_codes)},
                    {0, 1, 1})));

  const PlutoRect tile{0, 0, 32, 32};
  const std::vector<std::uint8_t> black(32 * 32, 0);
  const std::vector<std::uint8_t> white_lattice(32 * 32, 30);
  const std::vector<std::uint8_t> white_rail(32 * 32, 31);

  const auto drive = [&](EngineHarness* harness,
                         const std::vector<std::uint8_t>& levels,
                         std::uint64_t frame_id) {
    AdmitRequest request;
    request.rect = tile;
    request.mode = 1;
    request.levels = levels.data();
    request.frame_id = frame_id;
    ASSERT_TRUE(harness->engine.admit(request));
    // A slot's pre-build content is its blanked scaffold; if every emitted
    // code is hold, the emitted rows equal the blank rows and the slot
    // does not change.
    for (int phase = 0; phase < kPhases; ++phase) {
      const std::size_t slot =
          static_cast<std::size_t>(harness->builds % kActivePhaseSlots);
      const std::vector<std::uint16_t> before = harness->slots[slot];
      harness->build();
      const bool changed = harness->slots[slot] != before;
      if (levels[0] == 31) {
        EXPECT_FALSE(changed)
            << "dst=31 must be all-hold on this table (phase " << phase << ")";
      } else {
        EXPECT_TRUE(changed)
            << "drive to level " << static_cast<int>(levels[0])
            << " emitted no codes (phase " << phase << ")";
      }
    }
    EXPECT_TRUE(harness->engine.idle());
  };

  // Renderer-lattice white (30): develop black, then the erase MUST drive.
  EngineHarness lattice_harness(&waveform.table());
  drive(&lattice_harness, black, 1);
  drive(&lattice_harness, white_lattice, 2);

  // Rail white (31, the pre-fix quantization): develop black, then the
  // "erase" emits nothing — the exact stale-content failure.
  EngineHarness rail_harness(&waveform.table());
  drive(&rail_harness, black, 1);
  drive(&rail_harness, white_rail, 2);
}
