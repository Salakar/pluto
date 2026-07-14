// L0 deterministic phase-plane trace goldens: engine + emitter + ScanLoop
// over the DrmInterface mock seam, single-stepped on a virtual clock. Every
// atomic flip hashes the FULL flipped plane (all 365x1700 words — control
// scaffold included, so any scaffold corruption in any flipped plane fails
// the golden); the golden is the ordered flip trace ("H" = HOLD flip,
// "<slot>:<fnv64 hex>" = content).
//
// Scenarios: DU rect (ends parked on HOLD — judged-blank pinned
// structurally); full-screen GC16 (band-amortized, <=3-frame onset
// stagger); two disjoint concurrent regions in different modes;
// slot-reuse-after-clip-shrink (stale rows re-blanked on the slot's second
// use).
//
// REGEN: run with PLUTO_L0_REGEN=1 in the environment; each scenario
// prints its actual trace as a C++ initializer to stderr and skips the
// golden comparison (structural assertions still run). Paste the printed
// arrays over the kExpected* constants below. The traces are pure integer
// functions of the pinned synthetic .eink + engine config — no clocks, no
// threads, no platform variance.

#include "presenter/swtcon/drm_swtcon_device.h"
#include "presenter/swtcon/phase_emit.h"
#include "presenter/swtcon/pixel_engine.h"
#include "presenter/swtcon/scan_loop.h"
#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_waveform.h"

#include "swtcon_eink_synth.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace {

using pluto::swtcon::AdmitRequest;
using pluto::swtcon::DrmFlipEvent;
using pluto::swtcon::DrmSwtconDevice;
using pluto::swtcon::EmissionMode;
using pluto::swtcon::kActivePhaseSlots;
using pluto::swtcon::kDrmBufferCount;
using pluto::swtcon::kDrmHeight;
using pluto::swtcon::kDrmModePageFlipEventFlag;
using pluto::swtcon::kDrmPhaseBytes;
using pluto::swtcon::kDrmPhaseWords;
using pluto::swtcon::kDrmWidth;
using pluto::swtcon::kFirstDataRow;
using pluto::swtcon::kFirstDataWord;
using pluto::swtcon::kLogicalHeight;
using pluto::swtcon::kLogicalWidth;
using pluto::swtcon::PhaseEmitter;
using pluto::swtcon::PhaseEmitterConfig;
using pluto::swtcon::PixelEngine;
using pluto::swtcon::PixelEngineConfig;
using pluto::swtcon::ScanClock;
using pluto::swtcon::ScanLoop;
using pluto::swtcon::ScanLoopConfig;
using pluto::swtcon::WaveformTable;

// FNV-1a 64 over the FULL plane (every row, every word — control scaffold
// included: the golden pins the exact bytes the panel would scan).
std::uint64_t hash_plane(const std::uint8_t* plane_bytes,
                         std::size_t pitch_bytes) {
  std::uint64_t hash = 1469598103934665603ull;
  const auto mix = [&hash](std::uint8_t byte) {
    hash ^= byte;
    hash *= 1099511628211ull;
  };
  for (int row = 0; row < kDrmHeight; ++row) {
    const std::uint8_t* words =
        plane_bytes + static_cast<std::size_t>(row) * pitch_bytes;
    for (int i = 0; i < kDrmWidth * 2; ++i) {
      mix(words[i]);
    }
  }
  return hash;
}

std::string hex64(std::uint64_t value) {
  char buffer[17];
  std::snprintf(buffer, sizeof(buffer), "%016llx",
                static_cast<unsigned long long>(value));
  return std::string(buffer);
}

// Minimal DrmInterface fake: standard pipe, 16 dumb buffers, flip events;
// atomic_commit records the flipped fb + the full-plane hash of its bytes
// at flip time (the PhaseTraceRecorder role).
class TraceDrm final : public pluto::swtcon::DrmInterface {
 public:
  struct Flip {
    std::uint32_t fb_id = 0;
    std::uint64_t hash = 0;
  };

  int open_card(const std::string&, std::string*) override { return 7; }
  void close_fd(int) override {}
  bool set_client_cap(int, std::uint64_t, std::uint64_t,
                      std::string*) override {
    return true;
  }
  bool get_cap(int, std::uint64_t, std::uint64_t* value,
               std::string*) override {
    *value = 1;
    return true;
  }
  bool get_resources(int, pluto::swtcon::DrmResources* out,
                     std::string*) override {
    out->crtcs = {20};
    out->connectors = {10};
    return true;
  }
  bool get_connector(int, std::uint32_t connector_id,
                     pluto::swtcon::DrmConnectorInfo* out,
                     std::string*) override {
    out->connector_id = connector_id;
    out->encoder_id = 30;
    out->connected = true;
    pluto::swtcon::DrmModeInfo mode{};
    mode.hdisplay = kDrmWidth;
    mode.vdisplay = kDrmHeight;
    out->modes = {mode};
    out->properties = {{55, "DPMS", 0}};
    out->encoders = {30};
    return true;
  }
  bool get_encoder(int, std::uint32_t encoder_id,
                   pluto::swtcon::DrmEncoderInfo* out,
                   std::string*) override {
    out->encoder_id = encoder_id;
    out->crtc_id = 20;
    out->possible_crtcs = 1;
    return true;
  }
  bool get_plane_ids(int, std::vector<std::uint32_t>* out,
                     std::string*) override {
    *out = {40};
    return true;
  }
  bool get_plane(int, std::uint32_t plane_id,
                 pluto::swtcon::DrmPlaneInfo* out, std::string*) override {
    out->plane_id = plane_id;
    out->possible_crtcs = 1;
    out->properties = {{60, "type", 1},   {61, "FB_ID", 0},  {62, "CRTC_ID", 0},
                       {63, "CRTC_X", 0}, {64, "CRTC_Y", 0}, {65, "CRTC_W", 0},
                       {66, "CRTC_H", 0}, {67, "SRC_X", 0},  {68, "SRC_Y", 0},
                       {69, "SRC_W", 0},  {70, "SRC_H", 0}};
    return true;
  }
  bool create_dumb(int, std::uint32_t, std::uint32_t, std::uint32_t,
                   pluto::swtcon::DrmDumbCreateResult* out,
                   std::string*) override {
    ++created_;
    out->handle = 1000 + created_;
    out->pitch = kDrmWidth * sizeof(std::uint16_t);
    out->size = kDrmPhaseBytes;
    return true;
  }
  bool add_fb(int, std::uint32_t, std::uint32_t, std::uint8_t, std::uint8_t,
              std::uint32_t, std::uint32_t handle, std::uint32_t* fb_id,
              std::string*) override {
    *fb_id = 2000 + created_;
    fb_to_handle_[*fb_id] = handle;
    return true;
  }
  bool map_dumb(int, std::uint32_t handle, std::uint64_t* offset,
                std::string*) override {
    *offset = handle;
    return true;
  }
  void* mmap_dumb(int, std::uint64_t offset, std::uint64_t size,
                  std::string*) override {
    std::vector<std::uint8_t>& map =
        maps_[static_cast<std::uint32_t>(offset)];
    map.assign(static_cast<std::size_t>(size), 0);
    return map.data();
  }
  void munmap_dumb(void*, std::uint64_t) override {}
  bool rm_fb(int, std::uint32_t, std::string*) override { return true; }
  bool destroy_dumb(int, std::uint32_t, std::string*) override { return true; }
  bool set_crtc(int, std::uint32_t, std::uint32_t, std::uint32_t,
                const pluto::swtcon::DrmModeInfo&, std::string*) override {
    return true;
  }
  bool blank_crtc(int, std::uint32_t, std::string*) override { return true; }
  bool set_connector_property(int, std::uint32_t, std::uint32_t, std::uint64_t,
                              std::string*) override {
    return true;
  }
  bool atomic_commit(int, const pluto::swtcon::DrmAtomicRequest& request,
                     std::string*) override {
    const auto fb_id = static_cast<std::uint32_t>(request.values.back());
    Flip flip;
    flip.fb_id = fb_id;
    const auto handle = fb_to_handle_.find(fb_id);
    if (handle != fb_to_handle_.end()) {
      const std::vector<std::uint8_t>& map = maps_[handle->second];
      flip.hash = hash_plane(map.data(), kDrmWidth * sizeof(std::uint16_t));
    }
    flips_.push_back(flip);
    if ((request.flags & kDrmModePageFlipEventFlag) != 0) {
      DrmFlipEvent event;
      event.user_data = request.user_data;
      event.sequence = ++sequence_;
      pending_events_.push_back(event);
    }
    return true;
  }
  bool read_flip_events(int, std::vector<DrmFlipEvent>* out,
                        std::string*) override {
    out->insert(out->end(), pending_events_.begin(), pending_events_.end());
    pending_events_.clear();
    return true;
  }

  const std::vector<Flip>& flips() const { return flips_; }

 private:
  int created_ = 0;
  std::map<std::uint32_t, std::uint32_t> fb_to_handle_;
  std::map<std::uint32_t, std::vector<std::uint8_t>> maps_;
  std::vector<Flip> flips_;
  std::vector<DrmFlipEvent> pending_events_;
  std::uint32_t sequence_ = 100;
};

class NullClock final : public ScanClock {
 public:
  std::uint64_t now_ns() override { return 0; }
  void sleep_until_ns(std::uint64_t) override {}
};

// Pinned L0 synthetic .eink (8 modes x 1 temp bin) through the REAL
// decoder — all identity-hold so undriven regions stay blank:
//   mode 2: 6 phases, code = (cell*2 + p + 1) % 7
//   mode 5: 20 phases, code = (cell + p) % 7   (slot-ring wrap scenario)
//   mode 7: 2 phases,  code = (cell*3 + p + 2) % 7
//   others: 1-phase all-hold
std::vector<std::uint8_t> make_l0_eink() {
  const auto make_codes = [](int phases, int mul, int add) {
    std::vector<std::uint8_t> codes(
        static_cast<std::size_t>(phases) * swtcon_synth::kCells);
    for (int phase = 0; phase < phases; ++phase) {
      for (int cell = 0; cell < swtcon_synth::kCells; ++cell) {
        codes[static_cast<std::size_t>(phase) * swtcon_synth::kCells +
              static_cast<std::size_t>(cell)] =
            cell % 33 == 0
                ? 0
                : static_cast<std::uint8_t>((cell * mul + phase + add) % 7);
      }
    }
    return codes;
  };
  const std::vector<std::vector<std::uint8_t>> records = {
      swtcon_synth::record_from_codes(
          std::vector<std::uint8_t>(swtcon_synth::kCells, 0)),
      swtcon_synth::record_from_codes(make_codes(6, 2, 1)),
      swtcon_synth::record_from_codes(make_codes(20, 1, 0)),
      swtcon_synth::record_from_codes(make_codes(2, 3, 2)),
  };
  std::vector<std::size_t> record_for(8, 0);
  record_for[2] = 1;
  record_for[5] = 2;
  record_for[7] = 3;
  return swtcon_synth::wrap_eink(
      swtcon_synth::build_container(8, 1, {60}, records, record_for));
}

// The scan-facing harness: engine + emitter over the device's mmap'd dumb
// buffers, ScanLoop::tick() single-stepped, presenter build semantics
// mirrored exactly (one build per tick; publish only when rows were
// emitted; slot rotation 0..14).
struct L0Harness {
  TraceDrm* drm = nullptr;
  std::unique_ptr<DrmSwtconDevice> device;
  NullClock clock;
  ScanLoop loop;
  WaveformTable table;
  PixelEngine engine;
  PhaseEmitter emitter;
  std::size_t build_slot = 0;
  std::uint64_t build_seq = 0;

  L0Harness() {
    auto fake = std::make_unique<TraceDrm>();
    drm = fake.get();
    device = std::make_unique<DrmSwtconDevice>(std::move(fake));
    EXPECT_EQ(device->open(DrmSwtconDevice::Config{}), kPlutoStatusOk);

    std::string error;
    EXPECT_TRUE(table.parse(make_l0_eink(), &error)) << error;

    // Engine constants pinned EXPLICITLY (goldens must not drift with
    // default re-tuning).
    PixelEngineConfig config;
    config.width = kLogicalWidth;
    config.height = kLogicalHeight;
    config.stride = pluto::swtcon::kPaddedSourceWidth;
    config.tile_px = 32;
    config.max_active_px = 400000;
    config.full_flash_band_frames = 3;
    config.initial_prev_level = 0x1e;  // post-cold-clear white
    EXPECT_TRUE(engine.configure(&table, config));

    PhaseEmitterConfig emitter_config;
    emitter_config.mode = EmissionMode::kRowStage;
    emitter_config.slot_count = kDrmBufferCount;
    EXPECT_TRUE(emitter.configure(emitter_config));
    for (std::size_t slot = 0; slot < kActivePhaseSlots; ++slot) {
      const pluto::swtcon::DrmMappedBuffer& buffer =
          device->buffers()[slot];
      EXPECT_TRUE(emitter.set_slot_target(
          slot, static_cast<std::uint16_t*>(buffer.map), buffer.pitch));
      EXPECT_TRUE(emitter.blank_slot(slot));
    }

    EXPECT_TRUE(loop.configure(device.get(), &clock, ScanLoopConfig{}));
  }

  bool busy() const { return !engine.idle() || engine.parked_count() > 0; }

  // One scan frame: flip (published plane or HOLD), then build n+1.
  void step() {
    ASSERT_TRUE(loop.tick());
    if (!busy()) {
      return;
    }
    const std::uint64_t rows_before = emitter.stats().rows_emitted;
    ASSERT_TRUE(emitter.begin_frame(build_slot, build_seq + 1));
    engine.advance(&emitter);
    emitter.end_frame();
    if (emitter.stats().rows_emitted == rows_before) {
      return;  // nothing driven: not published, slot not consumed
    }
    ++build_seq;
    loop.ready_slot().publish(static_cast<std::uint32_t>(build_slot),
                              build_seq);
    build_slot = (build_slot + 1) % kActivePhaseSlots;
  }

  void admit_uniform(const PlutoRect& rect, int mode, std::uint8_t level,
                     std::vector<std::uint8_t>* storage) {
    storage->assign(static_cast<std::size_t>(rect.width) *
                        static_cast<std::size_t>(rect.height),
                    level);
    AdmitRequest request;
    request.rect = rect;
    request.mode = mode;
    request.levels = storage->data();
    request.frame_id = 1;
    ASSERT_TRUE(engine.admit(request));
  }

  std::vector<std::string> trace() const {
    std::vector<std::string> out;
    for (const TraceDrm::Flip& flip : drm->flips()) {
      if (flip.fb_id == 2000u + kDrmBufferCount) {
        out.push_back("H");
      } else {
        out.push_back(std::to_string(flip.fb_id - 2001) + ":" +
                      hex64(flip.hash));
      }
    }
    return out;
  }

  const std::uint16_t* plane_row(std::size_t buffer_index,
                                 int logical_row) const {
    const pluto::swtcon::DrmMappedBuffer& buffer =
        device->buffers()[buffer_index];
    return reinterpret_cast<const std::uint16_t*>(
        static_cast<const std::uint8_t*>(buffer.map) +
        static_cast<std::size_t>(logical_row + kFirstDataRow) * buffer.pitch);
  }

  int code_at(std::size_t buffer_index, int x, int logical_row) const {
    const std::uint16_t word =
        plane_row(buffer_index, logical_row)[kFirstDataWord + x / 4];
    return (word >> (9 - 3 * (x % 4))) & 0x7;
  }

  bool row_blank(std::size_t buffer_index, int logical_row) const {
    static std::vector<std::uint16_t> blank;
    if (blank.empty()) {
      blank.assign(kDrmPhaseWords, 0);
      pluto::swtcon::init_blank_phase_frame(blank.data());
    }
    return std::memcmp(plane_row(buffer_index, logical_row),
                       blank.data() +
                           static_cast<std::size_t>(logical_row +
                                                    kFirstDataRow) *
                               kDrmWidth,
                       static_cast<std::size_t>(kDrmWidth) *
                           sizeof(std::uint16_t)) == 0;
  }
};

bool regen_mode() { return std::getenv("PLUTO_L0_REGEN") != nullptr; }

void check_trace(const char* name, const std::vector<std::string>& actual,
                 const std::vector<std::string>& expected) {
  if (regen_mode()) {
    std::fprintf(stderr, "const std::vector<std::string> %s = {\n", name);
    for (const std::string& entry : actual) {
      std::fprintf(stderr, "    \"%s\",\n", entry.c_str());
    }
    std::fprintf(stderr, "};\n");
    return;
  }
  ASSERT_EQ(actual.size(), expected.size()) << name;
  for (std::size_t i = 0; i < expected.size(); ++i) {
    EXPECT_EQ(actual[i], expected[i]) << name << " flip " << i;
  }
}

// ---- goldens (regenerate with PLUTO_L0_REGEN=1; see file header) -------

const std::vector<std::string> kExpectedDuRect = {
    "H",
    "0:20a3058015589323",
    "1:384ae96c427d80a3",
    "H",
    "H",
    "H",
};

const std::vector<std::string> kExpectedGc16Full = {
    "H",
    "0:6db424e54254ff23",
    "1:cc75b9d52dc32723",
    "2:443470e425cf36a3",
    "3:54802ce1182e5da3",
    "4:aa7888fbc34072a3",
    "5:eb8b7e64ab1a42a3",
    "6:2c454e933aadd6a3",
    "7:7bb06716513b06a3",
    "H",
    "H",
    "H",
};

const std::vector<std::string> kExpectedTwoRegions = {
    "H",
    "0:5b4998c1d90d32a3",
    "1:6c460afec47e46a3",
    "2:d0ca9ea63b0422a3",
    "3:e8271feb99b44ea3",
    "4:ef2ba3df71d166a3",
    "5:733e24ec83e322a3",
    "H",
    "H",
};

const std::vector<std::string> kExpectedSlotReuse = {
    "H",
    "0:c1d4ec9f96c60ea3",
    "1:38f9e5108c1a16a3",
    "2:cdc75e25a0a6b6a3",
    "3:60c160cc74b336a3",
    "4:e7ba6b2762d476a3",
    "5:9febcabb217a36a3",
    "6:77fed41352eef6a3",
    "7:cfefbd29413f36a3",
    "8:4f404fa173fc76a3",
    "9:cdc75e25a0a6b6a3",
    "10:60c160cc74b336a3",
    "11:e7ba6b2762d476a3",
    "12:9febcabb217a36a3",
    "13:77fed41352eef6a3",
    "14:cfefbd29413f36a3",
    "0:4f404fa173fc76a3",
    "1:cdc75e25a0a6b6a3",
    "2:60c160cc74b336a3",
    "3:e7ba6b2762d476a3",
    "4:9febcabb217a36a3",
    "H",
    "H",
};

}  // namespace

// DU rect: 2-phase mode-7 sequence, then parked on HOLD forever
// (judged-blank: nothing publishes once idle; the HOLD plane is the blank
// scaffold byte-exactly).
TEST(L0TraceTest, DuRectEndsParkedOnHold) {
  L0Harness harness;
  std::vector<std::uint8_t> levels;
  harness.admit_uniform(PlutoRect{40, 64, 80, 48}, 7, 0, &levels);
  for (int i = 0; i < 6; ++i) {
    harness.step();
  }

  // Structural: phase-0 codes at (40,64) — prev 0x1e -> next 0 — must be
  // the decoder's cell exactly; outside the rect stays scaffold-blank.
  const std::uint8_t* phase0 = harness.table.phase_table(7, 0, 0);
  ASSERT_TRUE(phase0 != nullptr);
  EXPECT_EQ(harness.code_at(0, 40, 64),
            static_cast<int>(phase0[(0u << 5) | 0x1e]));
  EXPECT_TRUE(harness.row_blank(0, 63));   // above the rect
  EXPECT_TRUE(harness.row_blank(0, 112));  // below the rect

  // The HOLD slot's bytes are the blank scaffold (always-blank by
  // construction, the only legal park target).
  std::vector<std::uint16_t> blank(kDrmPhaseWords, 0);
  pluto::swtcon::init_blank_phase_frame(blank.data());
  const pluto::swtcon::DrmMappedBuffer& hold =
      harness.device->buffers()[kDrmBufferCount - 1];
  EXPECT_EQ(std::memcmp(hold.map, blank.data(), kDrmPhaseBytes), 0);

  check_trace("kExpectedDuRect", harness.trace(), kExpectedDuRect);
}

// Full-screen GC16: the 1.6 Mpx admission is band-amortized into 3
// tile-snapped row bands with a 1-frame onset stagger — no single frame
// sweeps the whole panel.
TEST(L0TraceTest, Gc16FullScreenIsBandAmortized) {
  L0Harness harness;
  std::vector<std::uint8_t> levels;
  harness.admit_uniform(PlutoRect{0, 0, kLogicalWidth, kLogicalHeight}, 2,
                        0, &levels);
  // Band 0 admits synchronously; bands 2 and 3 wake on the next two engine
  // frames. 6-phase mode: band completions at builds 6, 7, 8.
  for (int i = 0; i < 12; ++i) {
    harness.step();
  }

  // Structural band stagger (splits tile-snapped at rows 544 and 1120):
  // the first content plane drives band 0 only; the second adds band 1;
  // the third adds band 2.
  EXPECT_FALSE(harness.row_blank(0, 100));
  EXPECT_TRUE(harness.row_blank(0, 600));
  EXPECT_TRUE(harness.row_blank(0, 1200));
  EXPECT_FALSE(harness.row_blank(1, 600));
  EXPECT_TRUE(harness.row_blank(1, 1200));
  EXPECT_FALSE(harness.row_blank(2, 1200));

  check_trace("kExpectedGc16Full", harness.trace(), kExpectedGc16Full);
}

// Two disjoint concurrent regions in different modes: the fast region's
// 2-phase sequence and the GC16 region's 6-phase sequence interleave in
// the same planes, each pixel advancing its own fnum — impossible under
// the record-playback core.
TEST(L0TraceTest, TwoConcurrentRegionsInterleaveCorrectly) {
  L0Harness harness;
  std::vector<std::uint8_t> levels_a;
  std::vector<std::uint8_t> levels_b;
  harness.admit_uniform(PlutoRect{64, 96, 64, 64}, 7, 0, &levels_a);
  harness.admit_uniform(PlutoRect{400, 800, 96, 64}, 2, 10, &levels_b);
  for (int i = 0; i < 9; ++i) {
    harness.step();
  }

  const std::uint8_t* mode7 = harness.table.phase_table(7, 0, 0);
  const std::uint8_t* mode7_p1 = harness.table.phase_table(7, 0, 1);
  ASSERT_TRUE(mode7 != nullptr);
  ASSERT_TRUE(mode7_p1 != nullptr);
  // Region A pixel (64,96): prev 0x1e -> next 0; phases 0..1 in planes
  // built 1..2 (slots 0..1); gone (hold) from plane 3 on.
  EXPECT_EQ(harness.code_at(0, 64, 96),
            static_cast<int>(mode7[(0u << 5) | 0x1e]));
  EXPECT_EQ(harness.code_at(1, 64, 96),
            static_cast<int>(mode7_p1[(0u << 5) | 0x1e]));
  EXPECT_EQ(harness.code_at(2, 64, 96), 0);
  // Region B pixel (400,800): prev 0x1e -> next 10; all 6 phases present.
  for (int phase = 0; phase < 6; ++phase) {
    const std::uint8_t* mode2 = harness.table.phase_table(2, 0, phase);
    ASSERT_TRUE(mode2 != nullptr);
    EXPECT_EQ(harness.code_at(static_cast<std::size_t>(phase), 400, 800),
              static_cast<int>(mode2[(10u << 5) | 0x1e]))
        << "phase " << phase;
  }

  check_trace("kExpectedTwoRegions", harness.trace(), kExpectedTwoRegions);
}

// Slot reuse after clip shrink: a 20-phase region keeps building past the
// 15-slot ring while a short region completes early; when slot 0 is reused
// its stale rows (the completed region) must be re-blanked — stale-code
// re-drive impossible by construction.
TEST(L0TraceTest, SlotReuseAfterClipShrinkReblanksCompletedRegion) {
  L0Harness harness;
  std::vector<std::uint8_t> levels_tall;
  std::vector<std::uint8_t> levels_short;
  harness.admit_uniform(PlutoRect{100, 0, 64, 512}, 5, 0, &levels_tall);
  harness.admit_uniform(PlutoRect{200, 704, 64, 64}, 7, 0, &levels_short);
  // Builds 1..20 drive the tall region; the short one completes at build
  // 2. Build 16 reuses slot 0 (dirty rows 0..511 AND 704..767 from build
  // 1) with the clip shrunk to rows 0..511.
  for (int i = 0; i < 17; ++i) {
    harness.step();
  }
  // Slot 0 now carries build 16: tall-region rows redeposited, the
  // completed short-region rows re-blanked to the scaffold.
  EXPECT_FALSE(harness.row_blank(0, 100));
  EXPECT_TRUE(harness.row_blank(0, 704));
  EXPECT_TRUE(harness.row_blank(0, 750));
  const std::uint8_t* phase15 = harness.table.phase_table(5, 0, 15);
  ASSERT_TRUE(phase15 != nullptr);
  EXPECT_EQ(harness.code_at(0, 100, 100),
            static_cast<int>(phase15[(0u << 5) | 0x1e]));

  for (int i = 0; i < 6; ++i) {
    harness.step();
  }
  check_trace("kExpectedSlotReuse", harness.trace(), kExpectedSlotReuse);
}
