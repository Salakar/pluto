// CONTENT EVENTUAL-CONSISTENCY ORACLE (device bug hunt, 2026-07):
// the first on-device validation showed CRISP stale content persisting
// across scene switches — pixels whose newest submitted content was never
// driven. The engine equivalence proof covered uniform single-region
// admissions and the fuzz covered plane/scaffold integrity; NEITHER proved
// content convergence under overlapping/pending admissions. This suite
// pins the missing invariant:
//
//   After quiescence (engine idle, no pending pieces, all completions
//   fired), the engine's settled-glass truth plane (prev) must equal the
//   per-pixel NEWEST admitted content (levels-quantized), for EVERY pixel,
//   under ANY admission interleaving.
//
// Two layers:
//   * PixelEngine-level (deterministic, virtual clock = advance()):
//     adversarial admission streams shaped like the device workload —
//     scene-switch waves faster than waveform flight, rapid overlapping
//     partials, full-field band amortization racing tile damage, budget
//     deferral storms, and a 10k-admission seeded random torture.
//   * DrmSwtconPresenter-level (real threads, dry-run, C ABI ops): present
//     streams through the mailbox + large-admission lane with
//     FrameRenderer-shaped Again retries; glass observed via the
//     engine-thread-serviced debug_glass_for_testing seam.
//
// The root causes this suite pinned (fixed in pixel_engine.cc /
// drm_swtcon_presenter.cc):
//   1. Pending pieces (parked / band / budget-deferred) re-admitted with
//      STALE content after newer admissions covered their pixels — no
//      newest-wins supersession on the pending list.
//   2. drain_admissions() drained the whole mailbox BEFORE the large lane,
//      so an older full-field present could be admitted AFTER newer tile
//      presents, inverting the newest-wins order across lanes.

#include <gtest/gtest.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <random>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "pluto/presenter.h"
#include "presenter/swtcon/drm_swtcon_presenter.h"
#include "presenter/swtcon/pixel_engine.h"
#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_waveform.h"
#include "swtcon_eink_synth.h"

namespace {

using pluto::swtcon::AdmitOutcome;
using pluto::swtcon::AdmitRequest;
using pluto::swtcon::kAdmitFlagForceIdentity;
using pluto::swtcon::kAdmitFlagGuardNull;
using pluto::swtcon::kAdmitFlagPen;
using pluto::swtcon::kAdmitFlagSettle;
using pluto::swtcon::kLogicalHeight;
using pluto::swtcon::kLogicalStrideBytes;
using pluto::swtcon::kLogicalWidth;
using pluto::swtcon::kRgb565BytesPerPixel;
using pluto::swtcon::PixelEngine;
using pluto::swtcon::PixelEngineConfig;
using pluto::swtcon::rgb565_to_gray5;
using pluto::swtcon::WaveformTable;

// ---------------------------------------------------------------------------
// Engine-level oracle
// ---------------------------------------------------------------------------

// Synthetic 8-mode x 2-temp .eink through the REAL decoder (same shape as
// pixel_engine_test.cc): mode 2 = 4 phases in bin 0 / 3 in bin 1 (the
// Full/GC16 index), mode 7 = 2 phases (the Fast/Ui rail index), mode 1 =
// 1-phase hold (the Text index — bookkeeping-only on this table), others
// 1-phase hold.
std::vector<std::uint8_t> make_oracle_eink() {
  const int nmode = 8;
  const int ntemp = 2;
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
  std::vector<std::size_t> record_for(static_cast<std::size_t>(nmode) * ntemp,
                                      0);
  record_for[2 * ntemp + 0] = 1;
  record_for[2 * ntemp + 1] = 2;
  record_for[7 * ntemp + 0] = 3;
  record_for[7 * ntemp + 1] = 3;
  return swtcon_synth::wrap_eink(swtcon_synth::build_container(
      nmode, ntemp, {0, 20}, records, record_for));
}

// Deterministic position-dependent content: identical rects with different
// salts differ everywhere, so any stale re-drive is visible.
std::uint8_t level_at(int x, int y, std::uint32_t salt) {
  return static_cast<std::uint8_t>((static_cast<std::uint32_t>(x) * 7u +
                                    static_cast<std::uint32_t>(y) * 13u +
                                    salt * 5u + 1u) %
                                   31u);
}

// 192x192 surface (6x6 tiles of 32 px), budget small enough that a
// full-field admission band-splits and sustained damage budget-defers —
// the device workload's pending-piece machinery at miniature scale.
PixelEngineConfig oracle_config() {
  PixelEngineConfig config;
  config.width = 192;
  config.height = 192;
  config.stride = 192;
  config.tile_px = 32;
  config.max_active_px = 8192;
  config.full_flash_band_frames = 3;
  return config;
}

class EngineOracle {
 public:
  explicit EngineOracle(const PixelEngineConfig& config = oracle_config())
      : config_(config) {
    std::string error;
    const bool parsed = table_.parse(make_oracle_eink(), &error);
    EXPECT_TRUE(parsed) << error;
    EXPECT_TRUE(engine_.configure(&table_, config_));
    engine_.set_temperature(10.0f);  // bin 0: mode 2 has 4 phases
    engine_.set_completion_callback([this](std::uint64_t frame_id) {
      // Exactly-once completion audit: every admitted user frame_id must
      // complete exactly once (a double-fire or a stranded id is a bug).
      const bool erased = outstanding_.erase(frame_id) == 1;
      EXPECT_TRUE(erased) << "duplicate or unknown completion for frame "
                          << frame_id;
    });
    oracle_.assign(static_cast<std::size_t>(config_.stride) *
                       static_cast<std::size_t>(config_.height),
                   config_.initial_prev_level);
  }

  PixelEngine& engine() { return engine_; }

  // Content admission; updates the oracle mirror on acceptance (newest
  // content wins per pixel, exactly the submitted stream's semantics).
  bool admit_content(const PlutoRect& rect, int mode, std::uint32_t salt,
                     std::uint64_t frame_id, std::uint32_t flags = 0) {
    std::vector<std::uint8_t> levels(static_cast<std::size_t>(rect.width) *
                                     static_cast<std::size_t>(rect.height));
    for (int y = 0; y < rect.height; ++y) {
      for (int x = 0; x < rect.width; ++x) {
        levels[static_cast<std::size_t>(y) * rect.width + x] =
            level_at(rect.x + x, rect.y + y, salt);
      }
    }
    AdmitRequest request;
    request.rect = rect;
    request.mode = mode;
    request.levels = levels.data();
    request.frame_id = frame_id;
    request.flags = flags;
    if (frame_id != 0) {
      outstanding_.insert(frame_id);
    }
    const bool accepted = engine_.admit(request);
    EXPECT_TRUE(accepted);
    if (!accepted) {
      outstanding_.erase(frame_id);
      return false;
    }
    apply_to_oracle(rect, levels);
    return true;
  }

  // SETTLE emulation (renderer SettlePlanner shape): sentinel frame_id 0,
  // content = the current newest submitted content (its own ledger view).
  void admit_settle(const PlutoRect& rect) {
    std::vector<std::uint8_t> levels(static_cast<std::size_t>(rect.width) *
                                     static_cast<std::size_t>(rect.height));
    for (int y = 0; y < rect.height; ++y) {
      for (int x = 0; x < rect.width; ++x) {
        levels[static_cast<std::size_t>(y) * rect.width + x] =
            oracle_[static_cast<std::size_t>(rect.y + y) * config_.stride +
                    static_cast<std::size_t>(rect.x + x)];
      }
    }
    AdmitRequest request;
    request.rect = rect;
    request.mode = 2;
    request.levels = levels.data();
    request.frame_id = 0;
    request.flags = kAdmitFlagSettle;
    EXPECT_TRUE(engine_.admit(request));
  }

  // Guard-band null admission: drives next := prev, never authors content.
  void admit_guard(const PlutoRect& rect, std::uint64_t frame_id) {
    AdmitRequest request;
    request.rect = rect;
    request.mode = 7;
    request.levels = nullptr;
    request.frame_id = frame_id;
    request.flags = kAdmitFlagGuardNull;
    if (frame_id != 0) {
      outstanding_.insert(frame_id);
    }
    EXPECT_TRUE(engine_.admit(request));
  }

  void advance(int frames) {
    for (int i = 0; i < frames; ++i) {
      engine_.advance(nullptr);
    }
  }

  // Virtual-clock quiesce: pump until the engine is idle with nothing
  // parked. A cap failure means a stranded piece (also a bug).
  void pump_quiesce() {
    for (int i = 0; i < 20000; ++i) {
      if (engine_.idle() && engine_.parked_count() == 0) {
        return;
      }
      engine_.advance(nullptr);
    }
    ASSERT_TRUE(engine_.idle() && engine_.parked_count() == 0)
        << "engine did not quiesce: active_px=" << engine_.total_active_px()
        << " parked=" << engine_.parked_count();
  }

  // THE ORACLE: at quiescence, prev (settled glass truth) must equal the
  // newest submitted content everywhere; next/final must agree (idle
  // invariant).
  void verify(const char* label) {
    const std::uint8_t* prev = engine_.prev_plane();
    const std::uint8_t* next = engine_.next_plane();
    const std::uint8_t* final_plane = engine_.final_plane();
    std::size_t mismatches = 0;
    std::ostringstream detail;
    for (int y = 0; y < config_.height; ++y) {
      for (int x = 0; x < config_.width; ++x) {
        const std::size_t px = static_cast<std::size_t>(y) * config_.stride +
                               static_cast<std::size_t>(x);
        if (prev[px] != oracle_[px] || next[px] != oracle_[px] ||
            final_plane[px] != oracle_[px]) {
          if (mismatches < 5) {
            detail << "\n  pixel (" << x << "," << y
                   << ") glass=" << static_cast<int>(prev[px])
                   << " next=" << static_cast<int>(next[px])
                   << " final=" << static_cast<int>(final_plane[px])
                   << " newest-submitted=" << static_cast<int>(oracle_[px]);
          }
          ++mismatches;
        }
      }
    }
    EXPECT_EQ(mismatches, 0u)
        << label << ": " << mismatches << " stale/lost pixels" << detail.str();
  }

  void verify_all_completed(const char* label) {
    EXPECT_TRUE(outstanding_.empty())
        << label << ": " << outstanding_.size()
        << " admissions never completed (first="
        << (outstanding_.empty() ? 0 : *outstanding_.begin()) << ")";
  }

 private:
  void apply_to_oracle(const PlutoRect& rect,
                       const std::vector<std::uint8_t>& levels) {
    for (int y = 0; y < rect.height; ++y) {
      for (int x = 0; x < rect.width; ++x) {
        oracle_[static_cast<std::size_t>(rect.y + y) * config_.stride +
                static_cast<std::size_t>(rect.x + x)] =
            levels[static_cast<std::size_t>(y) * rect.width + x];
      }
    }
  }

  PixelEngineConfig config_;
  WaveformTable table_;
  PixelEngine engine_;
  std::vector<std::uint8_t> oracle_;
  std::multiset<std::uint64_t> outstanding_;
};

// The distilled device bug: tile T busy with A; B parks behind it; A
// completes; C (newest) admits directly onto the now-idle tile BEFORE B's
// parked piece wakes. B must NOT re-admit its stale content over C.
TEST(ContentConsistencyEngineTest, StaleParkedPieceMustNotClobberNewerContent) {
  EngineOracle o;
  const PlutoRect tile{0, 0, 32, 32};
  o.admit_content(tile, 2, /*salt=*/1, /*frame_id=*/1);  // A: 4-phase flight
  o.advance(1);
  o.admit_content(tile, 2, /*salt=*/2, /*frame_id=*/2);  // B parks behind A
  o.advance(3);  // A completes; B's piece wakes only on the NEXT advance
  o.admit_content(tile, 2, /*salt=*/3, /*frame_id=*/3);  // C starts (newest)
  o.pump_quiesce();
  o.verify("stale-parked-piece");
  o.verify_all_completed("stale-parked-piece");
}

// Full-field band amortization racing new tile damage: bands 1..n-1 are
// pending pieces; content admitted into their area before they wake must
// win (the deferred band keeps only the uncovered remainder).
TEST(ContentConsistencyEngineTest, DeferredBandsMustNotResurrectOldContent) {
  EngineOracle o;
  const PlutoRect full{0, 0, 192, 192};
  o.admit_content(full, 2, /*salt=*/1, /*frame_id=*/1);  // 3 bands
  o.advance(1);
  // New content inside the LAST band's area before that band admits. PEN
  // (budget-exempt) so it starts immediately instead of budget-deferring
  // behind the flash — the pen-during-scene-switch device shape.
  o.admit_content({32, 160, 64, 32}, 7, /*salt=*/9, /*frame_id=*/2,
                  kAdmitFlagPen);
  o.pump_quiesce();
  o.verify("deferred-bands");
  o.verify_all_completed("deferred-bands");
}

// Scene-switch waves at cadences faster than waveform flight: full-screen
// A, then B, then C one scan frame apart (mode 2 needs 4 frames per
// pixel), mixed with a rail-mode wave. Exactly the validation_lab shape.
TEST(ContentConsistencyEngineTest, SceneSwitchWavesConverge) {
  EngineOracle o;
  const PlutoRect full{0, 0, 192, 192};
  std::uint64_t frame_id = 1;
  for (int round = 0; round < 4; ++round) {
    o.admit_content(full, 2, /*salt=*/10u + round, frame_id++);
    o.advance(1);
    // Banner-like animated rects on top of the in-flight scene switch.
    o.admit_content({16, 16, 96, 32}, 7, /*salt=*/100u + round, frame_id++);
    o.admit_content({64, 96, 96, 48}, 2, /*salt=*/200u + round, frame_id++);
    o.advance(1);
  }
  o.pump_quiesce();
  o.verify("scene-switch-waves");
  o.verify_all_completed("scene-switch-waves");
}

// Rapid overlapping partial damage: alternating content on overlapping
// rects, mixed modes, sub-flight cadence.
TEST(ContentConsistencyEngineTest, RapidOverlappingPartialsConverge) {
  EngineOracle o;
  std::uint64_t frame_id = 1;
  for (int i = 0; i < 60; ++i) {
    const PlutoRect rect{16 + (i % 4) * 24, 16 + (i % 3) * 20, 64, 64};
    o.admit_content(rect, (i % 2) != 0 ? 7 : 2,
                    /*salt=*/static_cast<std::uint32_t>(i), frame_id++);
    if ((i % 2) != 0) {
      o.advance(1);
    }
  }
  o.pump_quiesce();
  o.verify("rapid-overlap");
  o.verify_all_completed("rapid-overlap");
}

// Budget-deferral storm: a full-field flash holds the busy-pixel budget
// while small updates keep arriving (they defer as whole pieces); newer
// content over the same rects must win regardless of wake order.
TEST(ContentConsistencyEngineTest, BudgetDeferralStormConverges) {
  EngineOracle o;
  const PlutoRect full{0, 0, 192, 192};
  std::uint64_t frame_id = 1;
  o.admit_content(full, 2, /*salt=*/1, frame_id++);
  for (int i = 0; i < 12; ++i) {
    const PlutoRect rect{(i % 3) * 48, ((i / 3) % 2) * 64 + 8, 80, 56};
    o.admit_content(rect, (i % 2) != 0 ? 7 : 2,
                    /*salt=*/50u + static_cast<std::uint32_t>(i), frame_id++);
    if (i % 3 == 0) {
      o.advance(1);
    }
  }
  o.pump_quiesce();
  o.verify("budget-storm");
  o.verify_all_completed("budget-storm");
}

TEST(ContentConsistencyEngineTest,
     GuardNullCannotRollbackInFlightNewerContent) {
  EngineOracle o;
  const PlutoRect rect{0, 0, 16, 16};
  // Reduced from the Linux/libstdc++ random stream: a same-mode identity guard
  // arrives between the two phases of newer rail content. It must wait for the
  // content boundary, not early-cancel back toward the older glass state.
  o.admit_content(rect, 7, /*salt=*/1, /*frame_id=*/1);
  o.advance(1);
  o.admit_guard(rect, /*frame_id=*/2);
  EXPECT_EQ(o.engine().parked_count(), 1u);
  o.pump_quiesce();
  o.verify("guard-null-inflight");
  o.verify_all_completed("guard-null-inflight");
}

// Seeded random torture: 10k admissions of random rects/modes/contents/
// cadences (bands, parks, budget deferrals, settles, guards, PEN),
// quiesce-verify checkpoints throughout. Any eventual-consistency drop in
// the admission arbitration shows up here.
TEST(ContentConsistencyEngineTest, RandomTortureConverges) {
  EngineOracle o;
  std::mt19937 rng(0xC0FFEEu);
  std::uniform_int_distribution<int> coord(0, 191);
  std::uniform_int_distribution<int> span(8, 128);
  std::uniform_int_distribution<int> mode_pick(0, 9);
  std::uniform_int_distribution<int> cadence(0, 9);
  std::uniform_int_distribution<int> kind(0, 99);
  std::uint64_t frame_id = 1;
  constexpr int kAdmissions = 10000;
  for (int i = 0; i < kAdmissions; ++i) {
    PlutoRect rect;
    rect.x = coord(rng);
    rect.y = coord(rng);
    rect.width = std::min(span(rng), 192 - rect.x);
    rect.height = std::min(span(rng), 192 - rect.y);
    if (rect.width <= 0 || rect.height <= 0) {
      continue;
    }
    const int mode_roll = mode_pick(rng);
    const int mode = mode_roll < 4 ? 2 : (mode_roll < 8 ? 7 : 1);
    const int k = kind(rng);
    if (k < 84) {
      o.admit_content(rect, mode, /*salt=*/static_cast<std::uint32_t>(i),
                      frame_id++);
    } else if (k < 90) {
      // PEN: budget-exempt content.
      o.admit_content(rect, 7, /*salt=*/static_cast<std::uint32_t>(i),
                      frame_id++, kAdmitFlagPen);
    } else if (k < 94) {
      // Force-identity content (scene-switch quality flash shape).
      o.admit_content(rect, 2, /*salt=*/static_cast<std::uint32_t>(i),
                      frame_id++, kAdmitFlagForceIdentity);
    } else if (k < 97) {
      o.admit_settle(rect);
    } else {
      o.admit_guard(rect, frame_id++);
    }
    const int c = cadence(rng);
    if (c < 5) {
      o.advance(1);
    } else if (c < 7) {
      o.advance(3);
    }  // else: back-to-back admission, no scan frame between
    if (i % 1000 == 999) {
      o.pump_quiesce();
      o.verify("random-torture checkpoint");
    }
  }
  o.pump_quiesce();
  o.verify("random-torture final");
  o.verify_all_completed("random-torture");
  // Every pending piece must be accounted for: none dropped.
  EXPECT_EQ(o.engine().parked_count(), 0u);
}

// ---------------------------------------------------------------------------
// Presenter-level oracle (real DrmSwtconPresenter through the C ABI ops,
// dry-run engine thread, mailbox + large-admission lane)
// ---------------------------------------------------------------------------

std::string write_synth_eink(const char* tag) {
  static int counter = 0;
  const std::string path = "/tmp/pluto_content_consistency_" +
                           std::to_string(::getpid()) + "_" + tag + "_" +
                           std::to_string(++counter) + ".eink";
  const std::vector<std::uint8_t> file =
      swtcon_synth::make_synthetic_eink(/*phases=*/3);
  std::ofstream out(path, std::ios::binary);
  EXPECT_TRUE(out.good());
  out.write(reinterpret_cast<const char*>(file.data()),
            static_cast<std::streamsize>(file.size()));
  return path;
}

class PresenterOracle {
 public:
  PresenterOracle() {
    eink_path_ = write_synth_eink("oracle");
    options_ = "dry_run=1,flip_interval_ms=0,stats_log_s=0,eink=" + eink_path_;
    ops_ = pluto_presenter_by_name("swtcon");
    EXPECT_TRUE(ops_ != nullptr);
    PlutoPresenterConfig config{};
    config.struct_size = sizeof(config);
    config.backend_name = "swtcon";
    config.options = options_.c_str();
    config.on_complete = [](std::uint64_t, void* user_data) {
      static_cast<PresenterOracle*>(user_data)->completions_.fetch_add(
          1, std::memory_order_acq_rel);
    };
    config.user_data = this;
    open_status_ = ops_->open(&config, &presenter_);
    frame_.assign(
        static_cast<std::size_t>(kLogicalHeight) * kLogicalStrideBytes, 0xff);
    // Cold clear leaves the glass at the engine's initial level (white).
    mirror_.assign(static_cast<std::size_t>(kLogicalHeight) * kLogicalWidth,
                   0x1e);
  }

  ~PresenterOracle() {
    if (presenter_ != nullptr) {
      ops_->close(presenter_);
    }
    std::remove(eink_path_.c_str());
  }

  PlutoStatus open_status() const { return open_status_; }
  int completions() const {
    return completions_.load(std::memory_order_acquire);
  }
  int presented() const { return presented_; }

  // Position-dependent RGB565 gray so stale content is visible per-pixel.
  void paint(const PlutoRect& rect, std::uint32_t salt) {
    for (int y = 0; y < rect.height; ++y) {
      for (int x = 0; x < rect.width; ++x) {
        const std::uint8_t g = static_cast<std::uint8_t>(
            (static_cast<std::uint32_t>(rect.x + x) * 3u +
             static_cast<std::uint32_t>(rect.y + y) * 11u + salt * 17u) &
            0xffu);
        const std::uint16_t px = static_cast<std::uint16_t>(
            ((g >> 3) << 11) | ((g >> 2) << 5) | (g >> 3));
        const std::size_t at =
            static_cast<std::size_t>(rect.y + y) * kLogicalStrideBytes +
            static_cast<std::size_t>(rect.x + x) * kRgb565BytesPerPixel;
        frame_[at] = static_cast<std::uint8_t>(px & 0xffu);
        frame_[at + 1] = static_cast<std::uint8_t>(px >> 8);
      }
    }
  }

  // present() with FrameRenderer-shaped Again handling: the batch stays
  // owned by the caller and is retried unchanged (requeue-exactly-once
  // semantics collapse to a retry loop for a single-producer test).
  void present(PlutoRefreshClass cls, const PlutoRect* damage,
               std::size_t damage_count) {
    PlutoPresentRequest request{};
    request.struct_size = sizeof(request);
    request.surface.pixels = frame_.data();
    request.surface.stride_bytes = kLogicalStrideBytes;
    request.surface.width = kLogicalWidth;
    request.surface.height = kLogicalHeight;
    request.surface.format = kPlutoPixelFormatRgb565;
    request.damage = damage;
    request.damage_count = damage_count;
    request.refresh_class = cls;
    request.frame_id = next_frame_id_++;
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(30);
    PlutoStatus status = kPlutoStatusAgain;
    while (std::chrono::steady_clock::now() < deadline) {
      status = ops_->present(presenter_, &request);
      if (status != kPlutoStatusAgain) {
        break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ASSERT_EQ(status, kPlutoStatusOk);
    ++presented_;
    // Mirror: the newest submitted content per pixel, levels-quantized
    // exactly like the presenter's conversion.
    for (std::size_t i = 0; i < damage_count; ++i) {
      const PlutoRect& rect = damage[i];
      for (int y = 0; y < rect.height; ++y) {
        for (int x = 0; x < rect.width; ++x) {
          const std::size_t at =
              static_cast<std::size_t>(rect.y + y) * kLogicalStrideBytes +
              static_cast<std::size_t>(rect.x + x) * kRgb565BytesPerPixel;
          const std::uint16_t px = static_cast<std::uint16_t>(
              frame_[at] | (static_cast<std::uint16_t>(frame_[at + 1]) << 8));
          mirror_[static_cast<std::size_t>(rect.y + y) * kLogicalWidth +
                  static_cast<std::size_t>(rect.x + x)] = rgb565_to_gray5(px);
        }
      }
    }
  }

  void verify(const char* label) {
    ASSERT_EQ(ops_->wait_idle(presenter_, 60000), kPlutoStatusOk);
    std::vector<std::uint8_t> glass;
    int width = 0;
    int height = 0;
    int stride = 0;
    ASSERT_TRUE(pluto::swtcon::debug_glass_for_testing(
        presenter_, &glass, &width, &height, &stride));
    ASSERT_EQ(width, kLogicalWidth);
    ASSERT_EQ(height, kLogicalHeight);
    std::size_t mismatches = 0;
    std::ostringstream detail;
    for (int y = 0; y < height; ++y) {
      for (int x = 0; x < width; ++x) {
        const std::uint8_t got = glass[static_cast<std::size_t>(y) * stride +
                                       static_cast<std::size_t>(x)];
        const std::uint8_t want =
            mirror_[static_cast<std::size_t>(y) * kLogicalWidth +
                    static_cast<std::size_t>(x)];
        if (got != want) {
          if (mismatches < 5) {
            detail << "\n  pixel (" << x << "," << y
                   << ") glass=" << static_cast<int>(got)
                   << " newest-submitted=" << static_cast<int>(want);
          }
          ++mismatches;
        }
      }
    }
    EXPECT_EQ(mismatches, 0u) << label << ": " << mismatches
                              << " stale/lost pixels on glass" << detail.str();
  }

 private:
  const PlutoPresenterOps* ops_ = nullptr;
  PlutoPresenter* presenter_ = nullptr;
  PlutoStatus open_status_ = kPlutoStatusInternal;
  std::string eink_path_;
  std::string options_;
  std::vector<std::uint8_t> frame_;   // RGB565 producer surface
  std::vector<std::uint8_t> mirror_;  // newest submitted 5-bit content
  std::uint64_t next_frame_id_ = 1;
  int presented_ = 0;
  std::atomic<int> completions_{0};
};

// validation_lab shape through the REAL presenter: full-screen scene
// switches (large-admission lane, band-amortized) immediately followed by
// banner animation presents (mailbox tile lane) on top, scene after scene
// with no settling between. The glass must end at the newest content.
TEST(ContentConsistencyPresenterTest, SceneSwitchWavesConverge) {
  PresenterOracle p;
  ASSERT_EQ(p.open_status(), kPlutoStatusOk);
  const PlutoRect full{0, 0, kLogicalWidth, kLogicalHeight};
  const PlutoRect banner_a{64, 128, 512, 96};
  const PlutoRect banner_b{200, 900, 448, 128};
  std::uint32_t salt = 1;
  for (int scene = 0; scene < 3; ++scene) {
    p.paint(full, salt++);
    p.present(kPlutoRefreshFull, &full, 1);  // scene switch: large lane
    for (int frame = 0; frame < 4; ++frame) {  // immediate banner animation
      p.paint(banner_a, salt++);
      p.present(kPlutoRefreshUi, &banner_a, 1);
      p.paint(banner_b, salt++);
      p.present(kPlutoRefreshFast, &banner_b, 1);
    }
  }
  p.verify("presenter-scene-waves");
  EXPECT_EQ(p.completions(), p.presented());
}

// Seeded random present torture through the C ABI: random rects/classes/
// contents/cadences including full-field (large-lane) presents overlapping
// tile presents. Also the TSan target for the mailbox/lane/engine seams.
TEST(ContentConsistencyPresenterTest, RandomPresentTortureConverges) {
  PresenterOracle p;
  ASSERT_EQ(p.open_status(), kPlutoStatusOk);
  std::mt19937 rng(0xF00DFACEu);
  std::uniform_int_distribution<int> x_pick(0, kLogicalWidth - 9);
  std::uniform_int_distribution<int> y_pick(0, kLogicalHeight - 9);
  std::uniform_int_distribution<int> w_pick(8, 512);
  std::uniform_int_distribution<int> h_pick(8, 384);
  std::uniform_int_distribution<int> class_pick(0, 3);
  std::uniform_int_distribution<int> kind(0, 99);
  std::uniform_int_distribution<int> pause(0, 9);
  const PlutoRefreshClass classes[4] = {
      kPlutoRefreshFast, kPlutoRefreshUi, kPlutoRefreshText,
      kPlutoRefreshFull};
  const PlutoRect full{0, 0, kLogicalWidth, kLogicalHeight};
  std::uint32_t salt = 1;
  constexpr int kPresents = 300;
  for (int i = 0; i < kPresents; ++i) {
    if (kind(rng) < 8) {
      // Full-field scene switch: the large-admission lane.
      p.paint(full, salt++);
      p.present(kPlutoRefreshFull, &full, 1);
    } else {
      PlutoRect rects[2];
      const std::size_t count = kind(rng) < 30 ? 2 : 1;
      for (std::size_t r = 0; r < count; ++r) {
        rects[r].x = x_pick(rng);
        rects[r].y = y_pick(rng);
        rects[r].width = std::min(w_pick(rng), kLogicalWidth - rects[r].x);
        rects[r].height = std::min(h_pick(rng), kLogicalHeight - rects[r].y);
        p.paint(rects[r], salt++);
      }
      p.present(classes[class_pick(rng)], rects, count);
    }
    if (pause(rng) == 0) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  }
  p.verify("presenter-random-torture");
  EXPECT_EQ(p.completions(), p.presented());
}

}  // namespace
