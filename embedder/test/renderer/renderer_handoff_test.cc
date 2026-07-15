#include <algorithm>
#include <cstdint>
#include <span>
#include <vector>

#include "renderer/renderer_handoff.h"
#include "gtest/gtest.h"

namespace {

using pluto::AutoGhostbuster;
using pluto::AutoGhostbusterConfig;
using pluto::ChromaPendingSet;
using pluto::ClassifyLadder;
using pluto::ClassifyLadderConfig;
using pluto::FrameLedger;
using pluto::FrameLedgerConfig;
using pluto::GhostLedger;
using pluto::RegionScheduler;
using pluto::RegionSchedulerConfig;
using pluto::RendererHandoffReject;
using pluto::RendererHandoffState;
using pluto::SettlePlanner;
using pluto::SettlePlannerConfig;
using pluto::StressLedger;
using pluto::TileGrid;

uint64_t crc64_reference(std::span<const uint8_t> bytes) {
  constexpr uint64_t kPolynomial = 0x42f0e1eba9ea3693ULL;
  uint64_t crc = 0;
  for (uint8_t byte : bytes) {
    crc ^= static_cast<uint64_t>(byte) << 56u;
    for (int bit = 0; bit < 8; ++bit) {
      crc = (crc & (uint64_t{1} << 63u)) != 0 ? (crc << 1u) ^ kPolynomial
                                              : crc << 1u;
    }
  }
  return crc;
}

uint64_t read_u64_le(std::span<const uint8_t> bytes, size_t offset) {
  uint64_t value = 0;
  for (unsigned shift = 0; shift < 64; shift += 8) {
    value |= static_cast<uint64_t>(bytes[offset++]) << shift;
  }
  return value;
}

bool make_state(RendererHandoffState *out_state,
                uint16_t first_color = 0xf800u) {
  constexpr uint32_t kWidth = 32;
  constexpr uint32_t kHeight = 24;
  constexpr uint32_t kTile = 8;

  if (out_state == nullptr) {
    return false;
  }
  RendererHandoffState &state = *out_state;
  state = RendererHandoffState{};
  state.width = kWidth;
  state.height = kHeight;
  state.rotation = 0;
  state.pixel_format = kPlutoPixelFormatRgb565;
  state.presenter_format = kPlutoPixelFormatRgb565;
  state.retained_stride = kWidth * sizeof(uint16_t);
  state.renderer_config.tile_px = kTile;
  state.enable_present_bridge = true;
  state.enable_auto_ghostbuster = true;
  state.pigment_hygiene_supported = true;
  state.panel_is_color = true;
  state.backend_quantizes_color = true;
  state.presenter_controls_refresh_class = true;
  state.retained_frame.assign(state.retained_stride * kHeight, 0xffu);
  state.retained_frame[0] = static_cast<uint8_t>(first_color);
  state.retained_frame[1] = static_cast<uint8_t>(first_color >> 8u);
  state.retained_frame[2] = 0xe0;
  state.retained_frame[3] = 0x07;
  state.scroll_pending_px = 7;
  state.scroll_ledger_shift_px = -3;
  state.scroll_moves = 11;
  state.last_input_change_us = 123456;
  state.automatic_ghost_actions = 4;

  FrameLedger frame(FrameLedgerConfig{kWidth, kHeight, kTile});
  frame.fill_levels(10);
  frame.l_cur()[0] = 12;
  frame.chroma_bits()[0] = 0x03;
  (void)frame.begin_pass();
  const bool frame_exported = frame.export_state(&state.frame_ledger);
  EXPECT_TRUE(frame_exported);
  if (!frame_exported) {
    return false;
  }
  state.frame_ledger.row_hash[0][0] = 0x10203040u;
  state.frame_ledger.stats[0].changed_px = 2;
  state.frame_ledger.stats[0].changed_chroma = 1;
  state.frame_ledger.stats[0].dirty = PlutoRect{0, 0, 2, 1};
  state.frame_ledger.stats[0].epoch = state.frame_ledger.epoch;

  ClassifyLadderConfig ladder_config;
  ladder_config.width = kWidth;
  ladder_config.height = kHeight;
  ladder_config.tile_px = kTile;
  ClassifyLadder ladder;
  const bool ladder_configured = ladder.configure(ladder_config);
  EXPECT_TRUE(ladder_configured);
  if (!ladder_configured) {
    return false;
  }
  const bool ladder_exported = ladder.export_state(&state.classify_ladder);
  EXPECT_TRUE(ladder_exported);
  if (!ladder_exported) {
    return false;
  }
  state.classify_ladder.epoch = state.frame_ledger.epoch;
  state.classify_ladder.history[0].last_epoch = 1;
  state.classify_ladder.history[0].streak = 1;
  state.classify_ladder.history[0].last_dirty = PlutoRect{0, 0, 2, 1};

  TileGrid grid;
  const bool grid_configured = grid.configure(kWidth, kHeight, kTile);
  EXPECT_TRUE(grid_configured);
  if (!grid_configured) {
    return false;
  }
  GhostLedger ghost;
  StressLedger stress;
  ChromaPendingSet chroma;
  const bool ghost_configured =
      ghost.configure(grid, state.renderer_config.ghost_tau_ms,
                      state.renderer_config.ghost_debt_settle_threshold);
  EXPECT_TRUE(ghost_configured);
  if (!ghost_configured) {
    return false;
  }
  const bool stress_configured = stress.configure(grid);
  EXPECT_TRUE(stress_configured);
  if (!stress_configured) {
    return false;
  }
  const bool chroma_configured = chroma.configure(grid);
  EXPECT_TRUE(chroma_configured);
  if (!chroma_configured) {
    return false;
  }
  ghost.tick(1000);
  ghost.accrue(PlutoRect{0, 0, 8, 8}, kPlutoRefreshFast);
  stress.tick(1000);
  stress.accrue(PlutoRect{8, 0, 8, 8}, kPlutoRefreshFast);
  chroma.mark(PlutoRect{0, 8, 8, 8});
  const bool ghost_exported = ghost.export_state(&state.ghost_ledger);
  EXPECT_TRUE(ghost_exported);
  if (!ghost_exported) {
    return false;
  }
  const bool stress_exported = stress.export_state(&state.stress_ledger);
  EXPECT_TRUE(stress_exported);
  if (!stress_exported) {
    return false;
  }
  const bool chroma_exported = chroma.export_state(&state.chroma_pending);
  EXPECT_TRUE(chroma_exported);
  if (!chroma_exported) {
    return false;
  }

  SettlePlannerConfig planner_config;
  planner_config.width = kWidth;
  planner_config.height = kHeight;
  planner_config.tile_px = kTile;
  planner_config.align_px = 8;
  planner_config.panel_is_color = true;
  planner_config.enable_sparkle_topoff = false;
  planner_config.perception = pluto::PerceptionConstants(state.renderer_config);
  SettlePlanner planner;
  const bool planner_configured =
      planner.configure(planner_config, &ghost, &stress, &chroma);
  EXPECT_TRUE(planner_configured);
  if (!planner_configured) {
    return false;
  }
  planner.note_damage(PlutoRect{0, 0, 8, 8}, 2000);
  planner.arm_scroll_settle(PlutoRect{0, 0, 32, 8}, 2000);
  const bool planner_exported = planner.export_state(&state.settle_planner);
  EXPECT_TRUE(planner_exported);
  if (!planner_exported) {
    return false;
  }

  AutoGhostbusterConfig auto_config;
  auto_config.pigment_hygiene_supported = true;
  AutoGhostbuster ghostbuster;
  const bool ghostbuster_configured = ghostbuster.configure(grid, auto_config);
  EXPECT_TRUE(ghostbuster_configured);
  if (!ghostbuster_configured) {
    return false;
  }
  ghostbuster.note_accepted_present(PlutoRect{0, 0, 8, 8}, kPlutoRefreshFast,
                                    3000);
  const bool ghostbuster_exported =
      ghostbuster.export_state(&state.auto_ghostbuster);
  EXPECT_TRUE(ghostbuster_exported);
  if (!ghostbuster_exported) {
    return false;
  }

  RegionSchedulerConfig scheduler_config;
  scheduler_config.width = kWidth;
  scheduler_config.height = kHeight;
  scheduler_config.align_px = 8;
  scheduler_config.presenter_rotation = 0;
  scheduler_config.pen_collision_tile_px = kTile;
  scheduler_config.presenter_reports_completion = true;
  scheduler_config.presenter_collision_safe = true;
  scheduler_config.surface = PlutoSurface{
      state.retained_frame.data(), static_cast<size_t>(state.retained_stride),
      kWidth, kHeight, kPlutoPixelFormatRgb565};
  RegionScheduler scheduler(scheduler_config, {}, &ghost, &stress, &chroma);
  const bool scheduler_valid = scheduler.valid();
  EXPECT_TRUE(scheduler_valid);
  if (!scheduler_valid) {
    return false;
  }
  const bool scheduler_exported =
      scheduler.export_state(&state.region_scheduler);
  EXPECT_TRUE(scheduler_exported);
  return scheduler_exported;
}

TEST(RendererHandoffTest, ExactColorChromaAndDebtRoundTrip) {
  RendererHandoffState source;
  ASSERT_TRUE(make_state(&source));
  ASSERT_TRUE(pluto::renderer_handoff_validate(source));
  std::vector<uint8_t> encoded;
  RendererHandoffReject reject = RendererHandoffReject::kArgument;
  ASSERT_TRUE(pluto::renderer_handoff_encode(source, &encoded, &reject));
  EXPECT_EQ(static_cast<int>(reject),
            static_cast<int>(RendererHandoffReject::kNone));

  RendererHandoffState decoded;
  ASSERT_TRUE(pluto::renderer_handoff_decode(
      encoded, pluto::renderer_handoff_configuration_hash(source), &decoded,
      &reject));
  EXPECT_TRUE(decoded.retained_frame == source.retained_frame);
  EXPECT_TRUE(decoded.frame_ledger.levels == source.frame_ledger.levels);
  EXPECT_TRUE(decoded.frame_ledger.chroma_bits ==
              source.frame_ledger.chroma_bits);
  EXPECT_EQ(decoded.classify_ladder.history[0].last_dirty.width, 2);
  EXPECT_TRUE(decoded.ghost_ledger.debt == source.ghost_ledger.debt);
  EXPECT_TRUE(decoded.ghost_ledger.owed == source.ghost_ledger.owed);
  EXPECT_TRUE(decoded.stress_ledger.stress == source.stress_ledger.stress);
  EXPECT_TRUE(decoded.chroma_pending.pending == source.chroma_pending.pending);
  EXPECT_EQ(decoded.settle_planner.forced.size(), 1u);
  EXPECT_TRUE(decoded.auto_ghostbuster.ghost.debt ==
              source.auto_ghostbuster.ghost.debt);
  EXPECT_TRUE(decoded.region_scheduler.last_submit_us ==
              source.region_scheduler.last_submit_us);
  EXPECT_EQ(decoded.scroll_ledger_shift_px, -3);
}

TEST(RendererHandoffTest, TransientScrollVerificationScratchIsCanonicalized) {
  RendererHandoffState with_scratch;
  ASSERT_TRUE(make_state(&with_scratch));
  RendererHandoffState clean = with_scratch;
  std::fill(with_scratch.frame_ledger.row_samples.begin(),
            with_scratch.frame_ledger.row_samples.end(), 0x1eu);
  std::fill(with_scratch.frame_ledger.row_sample_epoch.begin(),
            with_scratch.frame_ledger.row_sample_epoch.end(),
            with_scratch.frame_ledger.epoch);

  std::vector<uint8_t> scratch_bytes;
  std::vector<uint8_t> clean_bytes;
  ASSERT_TRUE(pluto::renderer_handoff_encode(with_scratch, &scratch_bytes));
  ASSERT_TRUE(pluto::renderer_handoff_encode(clean, &clean_bytes));
  EXPECT_TRUE(scratch_bytes == clean_bytes)
      << "completed-pass row verification cache must not make two otherwise "
         "identical handoffs differ";

  RendererHandoffState decoded;
  ASSERT_TRUE(pluto::renderer_handoff_decode(
      scratch_bytes, pluto::renderer_handoff_configuration_hash(with_scratch),
      &decoded));
  EXPECT_EQ(decoded.frame_ledger.row_samples.size(),
            with_scratch.frame_ledger.row_samples.size());
  EXPECT_EQ(decoded.frame_ledger.row_sample_epoch.size(),
            with_scratch.frame_ledger.row_sample_epoch.size());
  EXPECT_TRUE(std::all_of(decoded.frame_ledger.row_samples.begin(),
                          decoded.frame_ledger.row_samples.end(),
                          [](uint8_t value) { return value == 0u; }));
  EXPECT_TRUE(std::all_of(decoded.frame_ledger.row_sample_epoch.begin(),
                          decoded.frame_ledger.row_sample_epoch.end(),
                          [](uint32_t value) { return value == 0u; }));
}

TEST(RendererHandoffTest, EqualVisibleLevelsRetainDifferentExactRgb) {
  RendererHandoffState red;
  RendererHandoffState blue;
  ASSERT_TRUE(make_state(&red, 0xf800u));
  ASSERT_TRUE(make_state(&blue, 0x001fu));
  ASSERT_TRUE(red.frame_ledger.levels == blue.frame_ledger.levels);
  ASSERT_EQ(pluto::renderer_handoff_configuration_hash(red),
            pluto::renderer_handoff_configuration_hash(blue));
  ASSERT_TRUE(red.retained_frame != blue.retained_frame);

  std::vector<uint8_t> red_bytes;
  std::vector<uint8_t> blue_bytes;
  ASSERT_TRUE(pluto::renderer_handoff_encode(red, &red_bytes));
  ASSERT_TRUE(pluto::renderer_handoff_encode(blue, &blue_bytes));
  EXPECT_TRUE(red_bytes != blue_bytes);
  RendererHandoffState decoded;
  ASSERT_TRUE(pluto::renderer_handoff_decode(
      blue_bytes, pluto::renderer_handoff_configuration_hash(blue), &decoded));
  EXPECT_EQ(decoded.retained_frame[0], 0x1fu);
  EXPECT_EQ(decoded.retained_frame[1], 0x00u);
}

TEST(RendererHandoffTest, WireChecksumsMatchBitwiseCrc64EcmaReference) {
  RendererHandoffState source;
  ASSERT_TRUE(make_state(&source));
  std::vector<uint8_t> encoded;
  ASSERT_TRUE(pluto::renderer_handoff_encode(source, &encoded));
  ASSERT_GE(encoded.size(), 72u);
  EXPECT_EQ(read_u64_le(encoded, 56),
            crc64_reference(std::span<const uint8_t>(encoded).subspan(72)));
  EXPECT_EQ(read_u64_le(encoded, 64),
            crc64_reference(std::span<const uint8_t>(encoded).first(64)));
}

TEST(RendererHandoffTest, CorruptionPartialAndConfigurationMismatchFailClosed) {
  RendererHandoffState source;
  ASSERT_TRUE(make_state(&source));
  std::vector<uint8_t> encoded;
  ASSERT_TRUE(pluto::renderer_handoff_encode(source, &encoded));

  RendererHandoffState untouched;
  ASSERT_TRUE(make_state(&untouched, 0x07e0u));
  const std::vector<uint8_t> before = untouched.retained_frame;
  RendererHandoffReject reject = RendererHandoffReject::kNone;
  std::vector<uint8_t> corrupt = encoded;
  corrupt.back() ^= 0x80u;
  EXPECT_FALSE(pluto::renderer_handoff_decode(
      corrupt, pluto::renderer_handoff_configuration_hash(source), &untouched,
      &reject));
  EXPECT_EQ(static_cast<int>(reject),
            static_cast<int>(RendererHandoffReject::kChecksum));
  EXPECT_TRUE(untouched.retained_frame == before);

  EXPECT_FALSE(pluto::renderer_handoff_decode(
      std::span<const uint8_t>(encoded.data(), encoded.size() - 3),
      pluto::renderer_handoff_configuration_hash(source), &untouched, &reject));
  EXPECT_TRUE(reject == RendererHandoffReject::kHeader ||
              reject == RendererHandoffReject::kTruncated);

  EXPECT_FALSE(pluto::renderer_handoff_decode(
      encoded, pluto::renderer_handoff_configuration_hash(source) ^ 1u,
      &untouched, &reject));
  EXPECT_EQ(static_cast<int>(reject),
            static_cast<int>(RendererHandoffReject::kConfiguration));
}

TEST(RendererHandoffTest, ConfigurationFingerprintCoversFutureDecisions) {
  RendererHandoffState source;
  ASSERT_TRUE(make_state(&source));
  const uint64_t baseline = pluto::renderer_handoff_configuration_hash(source);
  source.renderer_config.chroma_floor++;
  EXPECT_NE(pluto::renderer_handoff_configuration_hash(source), baseline);
  ASSERT_TRUE(make_state(&source));
  source.region_scheduler.config.latency_model_us[0]++;
  EXPECT_NE(pluto::renderer_handoff_configuration_hash(source), baseline);
  ASSERT_TRUE(make_state(&source));
  source.auto_ghostbuster.config.yellow_tile_threshold_q8++;
  EXPECT_NE(pluto::renderer_handoff_configuration_hash(source), baseline);
  ASSERT_TRUE(make_state(&source));
  source.start_presenter_thread = false;
  EXPECT_NE(pluto::renderer_handoff_configuration_hash(source), baseline);
  ASSERT_TRUE(make_state(&source));
  source.presenter_pen_focus_from_host = true;
  EXPECT_NE(pluto::renderer_handoff_configuration_hash(source), baseline);
  ASSERT_TRUE(make_state(&source));
  source.present_bridge_active = false;
  source.mirror_enabled = true;
  EXPECT_NE(pluto::renderer_handoff_configuration_hash(source), baseline);
}

TEST(RendererHandoffTest, InvalidLogicalLevelAndDebtStateAreRejected) {
  RendererHandoffState invalid;
  ASSERT_TRUE(make_state(&invalid));
  invalid.frame_ledger.levels[0] = 0xff;
  EXPECT_FALSE(pluto::renderer_handoff_validate(invalid));
  EXPECT_FALSE(pluto::renderer_handoff_encode(invalid, nullptr));

  ASSERT_TRUE(make_state(&invalid));
  invalid.chroma_pending.pending[0] = 2;
  EXPECT_FALSE(pluto::renderer_handoff_validate(invalid));

  ASSERT_TRUE(make_state(&invalid));
  invalid.auto_ghostbuster.active_decision =
      pluto::AutoGhostbusterDecision::kBlink;
  EXPECT_FALSE(pluto::renderer_handoff_validate(invalid));
}

} // namespace
