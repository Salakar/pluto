#include "presenter/swtcon/pixel_engine.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ostream>
#include <random>
#include <span>
#include <string>
#include <vector>

#include "presenter/swtcon/dc_ledger.h"
#include "presenter/swtcon/lut_cache.h"
#include "presenter/swtcon/phase_emit.h"
#include "presenter/swtcon/swtcon_constants.h"
#include "presenter/swtcon/swtcon_waveform.h"
#include "presenter/swtcon/xochitl_history_state.h"
#include "swtcon_eink_synth.h"

namespace pluto::swtcon {

std::ostream& operator<<(std::ostream& stream, MappedAdmitStatus value) {
  return stream << static_cast<int>(value);
}
std::ostream& operator<<(std::ostream& stream, MappedEventKind value) {
  return stream << static_cast<int>(value);
}
std::ostream& operator<<(std::ostream& stream, MappedDiscardReason value) {
  return stream << static_cast<int>(value);
}
std::ostream& operator<<(std::ostream& stream, MappedFinalizeStatus value) {
  return stream << static_cast<int>(value);
}
std::ostream& operator<<(std::ostream& stream,
                         XochitlHistoryState::PrepareError value) {
  return stream << static_cast<int>(value);
}
std::ostream& operator<<(std::ostream& stream,
                         XochitlHistoryState::FinalizeStatus value) {
  return stream << static_cast<int>(value);
}

}  // namespace pluto::swtcon

namespace {

using pluto::swtcon::AdmitOutcome;
using pluto::swtcon::AdmitRequest;
using pluto::swtcon::ExactColorAView;
using pluto::swtcon::FastCoverage;
using pluto::swtcon::kAdmitFlagFastRailRebase;
using pluto::swtcon::kAdmitFlagForceIdentity;
using pluto::swtcon::kAdmitFlagGuardNull;
using pluto::swtcon::kAdmitFlagNoMappedInvalidation;
using pluto::swtcon::kAdmitFlagPen;
using pluto::swtcon::kAdmitFlagPenPreview;
using pluto::swtcon::kAdmitFlagQuality;
using pluto::swtcon::kAdmitFlagSettle;
using pluto::swtcon::kTileFlagStressPromoted;
using pluto::swtcon::MappedAdmitOutcome;
using pluto::swtcon::MappedAdmitRequest;
using pluto::swtcon::MappedAdmitStatus;
using pluto::swtcon::MappedDiscardReason;
using pluto::swtcon::MappedEvent;
using pluto::swtcon::MappedEventKind;
using pluto::swtcon::MappedFinalizeStatus;
using pluto::swtcon::MappedOperationToken;
using pluto::swtcon::PhaseEmitter;
using pluto::swtcon::PhaseEmitterConfig;
using pluto::swtcon::PixelEngine;
using pluto::swtcon::PixelEngineConfig;
using pluto::swtcon::PixelEngineHandoffState;
using pluto::swtcon::PixelOp;
using pluto::swtcon::RowEmitter;
using pluto::swtcon::WaveformTable;
using pluto::swtcon::XochitlHistoryState;

// Synthetic 8-mode x 2-temp .eink through the REAL decoder pipeline:
//   modes 0..1 and 3..6 -> shared 1-phase all-hold record
//   mode 2 (Full/GC16 index): bin 0 -> 4 phases (cell + p) % 7
//                             bin 1 -> 3 phases (cell*2 + p + 1) % 7
//   mode 7 (Fast/Ui rail index): 2 phases (cell*3 + p + 2) % 7, both bins
// Distinct per-bin mode-2 records make bin pinning observable.
std::vector<std::uint8_t> make_engine_eink() {
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

WaveformTable parse_engine_table() {
  WaveformTable table;
  std::string error;
  const bool ok = table.parse(make_engine_eink(), &error);
  EXPECT_TRUE(ok) << error;
  return table;
}

std::vector<std::uint8_t> make_safe_fast_eink() {
  constexpr int kModes = 8;
  constexpr int kBins = 9;
  constexpr int kPhases = 11;
  std::vector<std::uint8_t> hold(swtcon_synth::kCells, 0);
  std::vector<std::uint8_t> fast(
      static_cast<std::size_t>(kPhases) * swtcon_synth::kCells, 0);
  for (int phase = 0; phase < kPhases - 1; ++phase) {
    for (int src = 0; src < 32; ++src) {
      fast[static_cast<std::size_t>(phase) * swtcon_synth::kCells +
           pluto::swtcon::kMode7FastBlackEndpoint * 32 + src] = 6;
      fast[static_cast<std::size_t>(phase) * swtcon_synth::kCells +
           pluto::swtcon::kMode7FastWhiteEndpoint * 32 + src] = 1;
    }
  }
  const std::vector<std::vector<std::uint8_t>> records = {
      swtcon_synth::record_from_codes(hold),
      swtcon_synth::record_from_codes(fast)};
  std::vector<std::size_t> record_for(
      static_cast<std::size_t>(kModes * kBins), 0);
  for (int bin = 0; bin < kBins; ++bin) {
    record_for[static_cast<std::size_t>(7 * kBins + bin)] = 1;
  }
  return swtcon_synth::wrap_eink(swtcon_synth::build_container(
      kModes, kBins, {0, 5, 10, 15, 20, 25, 30, 35, 40}, records,
      record_for));
}

WaveformTable parse_safe_fast_table() {
  WaveformTable table;
  std::string error;
  const bool ok = table.parse(make_safe_fast_eink(), &error);
  EXPECT_TRUE(ok) << error;
  EXPECT_TRUE(pluto::swtcon::supports_mode7_fast_recovery(table));
  return table;
}

// 64x64 surface, 2x2 tiles of 32x32.
PixelEngineConfig small_config() {
  PixelEngineConfig config;
  config.width = 64;
  config.height = 64;
  config.stride = 64;
  config.tile_px = 32;
  return config;
}

struct CaptureEmitter final : RowEmitter {
  struct RowCapture {
    int row;
    std::vector<PixelOp> ops;
  };
  std::vector<RowCapture> rows;

  void emit_row(int row, const PixelOp* ops, std::size_t count) override {
    RowCapture capture;
    capture.row = row;
    capture.ops.assign(ops, ops + count);
    rows.push_back(std::move(capture));
  }
  void clear() { rows.clear(); }
  std::size_t total_ops() const {
    std::size_t total = 0;
    for (const RowCapture& capture : rows) {
      total += capture.ops.size();
    }
    return total;
  }
  int max_row() const {
    int max = -1;
    for (const RowCapture& capture : rows) {
      max = std::max(max, capture.row);
    }
    return max;
  }
  // Code of the op at (row, x); -1 when absent.
  int code_at(int row, int x) const {
    for (const RowCapture& capture : rows) {
      if (capture.row != row) {
        continue;
      }
      for (const PixelOp& op : capture.ops) {
        if (op.x == x) {
          return op.code;
        }
      }
    }
    return -1;
  }
};

std::vector<std::uint8_t> uniform_levels(const PlutoRect& rect,
                                         std::uint8_t value) {
  return std::vector<std::uint8_t>(static_cast<std::size_t>(rect.width) *
                                       static_cast<std::size_t>(rect.height),
                                   value);
}

AdmitRequest make_request(const PlutoRect& rect, int mode,
                          const std::vector<std::uint8_t>& levels,
                          std::uint64_t frame_id, std::uint32_t flags = 0) {
  AdmitRequest request;
  request.rect = rect;
  request.mode = mode;
  request.levels = levels.empty() ? nullptr : levels.data();
  request.frame_id = frame_id;
  request.flags = flags;
  return request;
}

std::uint8_t plane_at(const PixelEngine& engine, const std::uint8_t* plane,
                      int x, int y) {
  return plane[static_cast<std::size_t>(y) *
                   static_cast<std::size_t>(engine.plane_stride()) +
               static_cast<std::size_t>(x)];
}

std::vector<std::uint16_t> exact_history_for_engine(const PixelEngine &engine,
                                                    std::size_t history_stride,
                                                    std::size_t history_rows) {
  std::vector<std::uint16_t> history(history_stride * history_rows * 2u, 0);
  for (std::size_t y = 0; y < history_rows; ++y) {
    for (std::size_t x = 0; x < history_stride; ++x) {
      const std::size_t pixel = y * history_stride + x;
      const std::uint16_t marker = ((x + y) & 1u) != 0 ? 0x40u : 0x80u;
      std::uint8_t level = 30;
      if (y < static_cast<std::size_t>(engine.config().height) &&
          x < static_cast<std::size_t>(engine.config().stride)) {
        level = engine.prev_plane()[y * static_cast<std::size_t>(
                                            engine.plane_stride()) +
                                    x];
      }
      history[pixel * 2u] = static_cast<std::uint16_t>(marker | level);
      history[pixel * 2u + 1u] =
          static_cast<std::uint16_t>((pixel * 40503u + 17u) & 0xffffu);
    }
  }
  return history;
}

void expect_same_emission(const CaptureEmitter &first,
                          const CaptureEmitter &second) {
  ASSERT_EQ(first.rows.size(), second.rows.size());
  for (std::size_t row = 0; row < first.rows.size(); ++row) {
    ASSERT_EQ(first.rows[row].row, second.rows[row].row);
    ASSERT_EQ(first.rows[row].ops.size(), second.rows[row].ops.size());
    for (std::size_t op = 0; op < first.rows[row].ops.size(); ++op) {
      EXPECT_EQ(first.rows[row].ops[op].x, second.rows[row].ops[op].x);
      EXPECT_EQ(first.rows[row].ops[op].code, second.rows[row].ops[op].code);
      EXPECT_EQ(first.rows[row].ops[op].reserved,
                second.rows[row].ops[op].reserved);
    }
  }
}

bool contains(const std::vector<std::uint64_t>& ids, std::uint64_t id) {
  return std::find(ids.begin(), ids.end(), id) != ids.end();
}

struct Harness {
  WaveformTable table;
  PixelEngine engine;
  std::vector<std::uint64_t> completed;

  explicit Harness(const PixelEngineConfig& config = small_config())
      : table(parse_engine_table()) {
    EXPECT_TRUE(engine.configure(&table, config));
    engine.set_completion_callback(
        [this](std::uint64_t frame_id) { completed.push_back(frame_id); });
  }
};

struct SafeFastHarness {
  WaveformTable table;
  PixelEngine engine;
  std::vector<std::uint64_t> completed;

  explicit SafeFastHarness(const PixelEngineConfig& config = small_config())
      : table(parse_safe_fast_table()) {
    EXPECT_TRUE(engine.configure(&table, config));
    engine.set_completion_callback(
        [this](std::uint64_t frame_id) { completed.push_back(frame_id); });
  }
};

AdmitRequest make_safe_fast_request(
    const PlutoRect& rect, const std::vector<std::uint8_t>& levels,
    std::uint64_t frame_id, const std::shared_ptr<FastCoverage>& coverage) {
  AdmitRequest request = make_request(
      rect, 7, levels, frame_id,
      kAdmitFlagPenPreview | kAdmitFlagNoMappedInvalidation |
          kAdmitFlagFastRailRebase);
  request.fast_coverage = coverage;
  return request;
}

std::shared_ptr<const XochitlHistoryState::PreparedOperation>
prepare_fast_operation(XochitlHistoryState* history, const PlutoRect& rect,
                       std::uint8_t raw_value = 0) {
  const int width = (rect.width + 7) & ~7;
  const int height = (rect.height + 1) & ~1;
  const std::vector<std::uint8_t> raw(
      static_cast<std::size_t>(width) * static_cast<std::size_t>(height),
      raw_value);
  const auto prepared = history->prepare_fast_source(
      {rect.x, rect.y, rect.x + rect.width - 1,
       rect.y + rect.height - 1},
      raw, static_cast<std::size_t>(width), 25.0f);
  EXPECT_EQ(prepared.error, XochitlHistoryState::PrepareError::kNone);
  EXPECT_TRUE(prepared.operation != nullptr);
  return prepared.operation;
}

std::shared_ptr<const XochitlHistoryState::PreparedOperation>
prepare_legacy_operation(XochitlHistoryState* history, const PlutoRect& rect,
                         const std::vector<std::uint8_t>& raw,
                         std::span<const std::uint8_t> lane_mask = {}) {
  const int width = (rect.width + 7) & ~7;
  const int height = (rect.height + 1) & ~1;
  EXPECT_EQ(raw.size(), static_cast<std::size_t>(width * height));
  const std::array<std::int16_t, XochitlHistoryState::kTransitionCount> delta{};
  const auto prepared = history->prepare_legacy(
      XochitlHistoryState::Mode::kContent,
      {rect.x, rect.y, rect.x + rect.width - 1,
       rect.y + rect.height - 1},
      raw, static_cast<std::size_t>(width), delta, lane_mask);
  EXPECT_EQ(prepared.error, XochitlHistoryState::PrepareError::kNone);
  EXPECT_TRUE(prepared.operation != nullptr);
  return prepared.operation;
}

MappedAdmitRequest mapped_request(
    XochitlHistoryState* history,
    std::shared_ptr<const XochitlHistoryState::PreparedOperation> operation,
    std::uint64_t frame_id = 0, bool reconcile = false,
    std::uint64_t retry_cookie = 0,
    pluto::swtcon::MappedRecoveryToken recovery_token = 0) {
  MappedAdmitRequest request;
  request.operation = std::move(operation);
  request.history = history;
  request.frame_id = frame_id;
  request.retry_cookie = retry_cookie;
  request.reconcile_invalidated = reconcile;
  request.recovery_token = recovery_token;
  return request;
}

struct TeeEmitter final : RowEmitter {
  RowEmitter* a = nullptr;
  RowEmitter* b = nullptr;
  TeeEmitter(RowEmitter* first, RowEmitter* second) : a(first), b(second) {}
  void emit_row(int row, const PixelOp* ops, std::size_t count) override {
    a->emit_row(row, ops, count);
    b->emit_row(row, ops, count);
  }
};

TEST(PixelEngineTest, RejectsInvalidConfigurationAndRequests) {
  const WaveformTable table = parse_engine_table();
  PixelEngine engine;

  // Unconfigured engine rejects admissions.
  const PlutoRect rect{0, 0, 4, 4};
  const std::vector<std::uint8_t> levels = uniform_levels(rect, 0);
  EXPECT_FALSE(engine.admit(make_request(rect, 2, levels, 1)));

  PixelEngineConfig config = small_config();
  config.stride = 60;  // not a multiple of 8
  EXPECT_FALSE(engine.configure(&table, config));
  config = small_config();
  config.width = 70;  // wider than stride
  EXPECT_FALSE(engine.configure(&table, config));

  ASSERT_TRUE(engine.configure(&table, small_config()));
  // Null levels without the guard flag.
  EXPECT_FALSE(engine.admit(make_request(rect, 2, {}, 1)));
  // Fully off-surface rect.
  EXPECT_FALSE(engine.admit(make_request({100, 100, 4, 4}, 2, levels, 1)));
  // Unknown waveform mode.
  EXPECT_FALSE(engine.admit(make_request(rect, 42, levels, 1)));
}

TEST(PixelEngineHandoffTest,
     ExactColorRoundTripPreservesSettledDebtAndFutureTransitions) {
  const WaveformTable table = parse_engine_table();
  PixelEngineConfig config = small_config();
  config.width = 13;
  config.height = 7;
  config.stride = 16;
  config.tile_px = 5;
  config.dc.dc_pixel_cap = 8;

  PixelEngine source;
  PixelEngine restored;
  ASSERT_TRUE(source.configure(&table, config));
  ASSERT_TRUE(restored.configure(&table, config));

  std::vector<std::uint8_t> settled(static_cast<std::size_t>(config.width) *
                                    config.height);
  for (int y = 0; y < config.height; ++y) {
    for (int x = 0; x < config.width; ++x) {
      settled[static_cast<std::size_t>(y) * config.width + x] =
          static_cast<std::uint8_t>((x * 7 + y * 11) & 31);
    }
  }
  settled[0] = 7;
  settled[1] = 7; // equal visible level, distinct A flags/B below
  ASSERT_TRUE(source.seed_prev(settled.data(), config.width, config.height));
  source.set_temperature(40.0f);
  ASSERT_EQ(source.current_temp_bin(), 1);
  source.dc_ledger().charge(0, 1);
  source.dc_ledger().charge(6 * config.stride + 15, 6);
  source.dc_ledger().charge_truncation(5);
  source.dc_ledger().charge_double_scan(5, 3);
  source.dc_ledger().charge_rescan(5, -73);

  constexpr std::size_t kHistoryStride = 21;
  constexpr std::size_t kHistoryRows = 9;
  std::vector<std::uint16_t> history =
      exact_history_for_engine(source, kHistoryStride, kHistoryRows);
  for (int y = 0; y < config.height; ++y) {
    for (int x = config.width; x < config.stride; ++x) {
      const std::size_t pixel = static_cast<std::size_t>(y) * kHistoryStride +
                                static_cast<std::size_t>(x);
      history[pixel * 2u] = static_cast<std::uint16_t>(0x80u | 28u);
      history[pixel * 2u + 1u] = static_cast<std::uint16_t>(0x4000u + pixel);
    }
  }
  const ExactColorAView color{std::span<const std::uint16_t>(history),
                              kHistoryStride, kHistoryRows};
  EXPECT_EQ(history[0] & 31u, history[2] & 31u);
  EXPECT_NE(history[0] & ~31u, history[2] & ~31u);
  EXPECT_NE(history[1], history[3]);

  PixelEngineHandoffState expected;
  ASSERT_TRUE(source.export_handoff_state(color, &expected));
  EXPECT_TRUE(expected.settled_levels.empty());
  ASSERT_TRUE(restored.import_handoff_state(expected, color));
  EXPECT_EQ(restored.current_temp_bin(), 1);
  EXPECT_EQ(restored.frame(), 0u);
  EXPECT_EQ(restored.stats().admissions, 0u);

  PixelEngineHandoffState round_trip;
  ASSERT_TRUE(restored.export_handoff_state(color, &round_trip));
  EXPECT_TRUE(round_trip == expected);
  const std::size_t plane =
      static_cast<std::size_t>(config.stride) * config.height;
  EXPECT_TRUE(std::equal(source.prev_plane(), source.prev_plane() + plane,
                         restored.prev_plane()));
  EXPECT_TRUE(std::equal(source.next_plane(), source.next_plane() + plane,
                         restored.next_plane()));
  EXPECT_TRUE(std::equal(source.final_plane(), source.final_plane() + plane,
                         restored.final_plane()));
  for (int y = 0; y < config.height; ++y) {
    for (int x = config.width; x < config.stride; ++x) {
      const std::size_t engine_px =
          static_cast<std::size_t>(y) * config.stride +
          static_cast<std::size_t>(x);
      const std::size_t history_px =
          static_cast<std::size_t>(y) * kHistoryStride +
          static_cast<std::size_t>(x);
      EXPECT_EQ(restored.prev_plane()[engine_px], config.initial_prev_level);
      EXPECT_EQ(history[history_px * 2u],
                static_cast<std::uint16_t>(0x80u | 28u));
      EXPECT_EQ(history[history_px * 2u + 1u],
                static_cast<std::uint16_t>(0x4000u + history_px));
    }
  }

  const PlutoRect successor{2, 1, 8, 4};
  std::vector<std::uint8_t> next_levels(
      static_cast<std::size_t>(successor.width) * successor.height);
  for (std::size_t i = 0; i < next_levels.size(); ++i) {
    next_levels[i] = static_cast<std::uint8_t>((i * 13u + 3u) & 31u);
  }
  ASSERT_TRUE(source.admit(make_request(successor, 7, next_levels, 101)));
  ASSERT_TRUE(restored.admit(make_request(successor, 7, next_levels, 101)));
  while (!source.idle() || !restored.idle()) {
    ASSERT_EQ(source.idle(), restored.idle());
    CaptureEmitter source_emission;
    CaptureEmitter restored_emission;
    source.advance(&source_emission);
    restored.advance(&restored_emission);
    expect_same_emission(source_emission, restored_emission);
  }

  PixelEngineHandoffState source_after;
  PixelEngineHandoffState restored_after;
  ASSERT_TRUE(source.export_handoff_state(&source_after));
  ASSERT_TRUE(restored.export_handoff_state(&restored_after));
  EXPECT_TRUE(restored_after == source_after)
      << "restored DC/stress/rescan and sticky temperature must drive an "
         "identical successor";
}

TEST(PixelEngineHandoffTest,
     CorruptOrMismatchedStateFailsWithoutMutatingTarget) {
  const WaveformTable table = parse_engine_table();
  PixelEngineConfig config = small_config();
  config.width = 13;
  config.height = 7;
  config.stride = 16;
  config.tile_px = 5;
  config.dc.dc_pixel_cap = 8;

  PixelEngine source;
  PixelEngine target;
  ASSERT_TRUE(source.configure(&table, config));
  ASSERT_TRUE(target.configure(&table, config));
  const std::vector<std::uint8_t> source_levels(
      static_cast<std::size_t>(config.width) * config.height, 7);
  const std::vector<std::uint8_t> target_levels(
      static_cast<std::size_t>(config.width) * config.height, 23);
  ASSERT_TRUE(
      source.seed_prev(source_levels.data(), config.width, config.height));
  ASSERT_TRUE(
      target.seed_prev(target_levels.data(), config.width, config.height));
  source.set_temperature(40.0f);
  target.set_temperature(10.0f);
  source.dc_ledger().charge(0, 1);
  target.dc_ledger().charge(1, 6);

  PixelEngineHandoffState mono;
  PixelEngineHandoffState baseline;
  ASSERT_TRUE(source.export_handoff_state(&mono));
  ASSERT_TRUE(target.export_handoff_state(&baseline));
  const auto expect_unchanged = [&]() {
    PixelEngineHandoffState after;
    ASSERT_TRUE(target.export_handoff_state(&after));
    EXPECT_TRUE(after == baseline);
  };

  PixelEngineHandoffState corrupt = mono;
  ++corrupt.config.width;
  EXPECT_FALSE(target.import_handoff_state(corrupt));
  expect_unchanged();

  corrupt = mono;
  corrupt.temperature_bin = 2;
  EXPECT_FALSE(target.import_handoff_state(corrupt));
  expect_unchanged();

  corrupt = mono;
  corrupt.settled_levels[0] = 32;
  EXPECT_FALSE(target.import_handoff_state(corrupt));
  expect_unchanged();

  corrupt = mono;
  corrupt.dc.dc.pop_back();
  EXPECT_FALSE(target.import_handoff_state(corrupt));
  expect_unchanged();

  constexpr std::size_t kHistoryStride = 21;
  constexpr std::size_t kHistoryRows = 9;
  std::vector<std::uint16_t> history =
      exact_history_for_engine(source, kHistoryStride, kHistoryRows);
  ExactColorAView color{std::span<const std::uint16_t>(history), kHistoryStride,
                        kHistoryRows};
  PixelEngineHandoffState exact;
  ASSERT_TRUE(source.export_handoff_state(color, &exact));

  ExactColorAView partial{
      std::span<const std::uint16_t>(history).first(history.size() - 2u),
      kHistoryStride, kHistoryRows};
  EXPECT_FALSE(target.import_handoff_state(exact, partial));
  expect_unchanged();

  ExactColorAView too_narrow{std::span<const std::uint16_t>(history),
                             static_cast<std::size_t>(config.stride - 1),
                             kHistoryRows};
  EXPECT_FALSE(target.import_handoff_state(exact, too_narrow));
  expect_unchanged();

  history[0] |= 0x20u; // invalid Xochitl A bit, not a marker or low5
  EXPECT_FALSE(target.import_handoff_state(exact, color));
  expect_unchanged();
  history[0] &= static_cast<std::uint16_t>(~0x20u);

  EXPECT_FALSE(target.import_handoff_state(exact));
  EXPECT_FALSE(target.import_handoff_state(mono, color));
  expect_unchanged();

  PixelEngineHandoffState untouched = baseline;
  history[0] = static_cast<std::uint16_t>((history[0] & ~31u) | 8u);
  EXPECT_FALSE(source.export_handoff_state(color, &untouched));
  EXPECT_TRUE(untouched == baseline) << "failed export must not change output";

  const PlutoRect active{0, 0, 2, 2};
  const std::vector<std::uint8_t> active_levels = uniform_levels(active, 0);
  ASSERT_TRUE(target.admit(make_request(active, 7, active_levels, 9)));
  EXPECT_FALSE(target.import_handoff_state(mono));
  PixelEngineHandoffState busy_export = baseline;
  EXPECT_FALSE(target.export_handoff_state(&busy_export));
  EXPECT_TRUE(busy_export == baseline);
}

TEST(PixelEngineTest, AdmitDrivesRegionToCompletionAndPromotesPrev) {
  Harness h;
  h.engine.set_temperature(10.0f);  // bin 0: mode 2 has 4 phases
  ASSERT_EQ(h.engine.current_temp_bin(), 0);

  const PlutoRect rect{4, 4, 8, 8};
  const std::vector<std::uint8_t> levels = uniform_levels(rect, 0);
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(make_request(rect, 2, levels, 77), &outcome));
  EXPECT_TRUE(outcome.accepted);
  EXPECT_EQ(outcome.started_tiles, 1u);
  EXPECT_EQ(h.engine.total_active_px(), 64u);
  EXPECT_EQ(h.engine.active_row_min(), 4);
  EXPECT_EQ(h.engine.active_row_max(), 11);

  const int phase_count = h.table.phase_count(2, 0);
  ASSERT_EQ(phase_count, 4);
  CaptureEmitter emitter;
  for (int phase = 0; phase < phase_count; ++phase) {
    emitter.clear();
    EXPECT_EQ(h.completed.size(), 0u) << "phase=" << phase;
    h.engine.advance(&emitter);
    // 8 dirty rows, 8 ops each, every op the golden decoder code for the
    // white(30) -> black(0) transition at this phase.
    ASSERT_EQ(emitter.rows.size(), 8u) << "phase=" << phase;
    EXPECT_EQ(emitter.total_ops(), 64u);
    const int expected = h.table.code(2, 0, 30, 0, phase);
    EXPECT_EQ(emitter.code_at(4, 4), expected) << "phase=" << phase;
    EXPECT_EQ(emitter.code_at(11, 11), expected) << "phase=" << phase;
  }

  // Completion fired exactly once, with every pixel promoted.
  ASSERT_EQ(h.completed.size(), 1u);
  EXPECT_EQ(h.completed[0], 77u);
  EXPECT_TRUE(h.engine.idle());
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 4, 4), 0);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 11, 11), 0);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 3, 4), 30);
  EXPECT_EQ(plane_at(h.engine, h.engine.fnum_plane(), 4, 4),
            PixelEngine::kFnumIdle);

  // A further frame emits nothing and never re-fires the completion.
  emitter.clear();
  h.engine.advance(&emitter);
  EXPECT_EQ(emitter.rows.size(), 0u);
  EXPECT_EQ(h.completed.size(), 1u);
}

// THE headline capability: two disjoint regions in different modes advance
// concurrently, each pixel on its own phase clock.
TEST(PixelEngineTest, ConcurrentRegionsInDifferentModesAdvanceIndependently) {
  Harness h;
  h.engine.set_temperature(10.0f);  // bin 0: mode 2 N=4, mode 7 N=2

  const PlutoRect rect_a{0, 0, 8, 8};
  const std::vector<std::uint8_t> levels_a = uniform_levels(rect_a, 0);
  ASSERT_TRUE(h.engine.admit(make_request(rect_a, 2, levels_a, 1)));
  h.engine.advance(nullptr);  // A plays phase 0

  const PlutoRect rect_b{32, 32, 8, 8};
  const std::vector<std::uint8_t> levels_b = uniform_levels(rect_b, 0);
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(make_request(rect_b, 7, levels_b, 2), &outcome));
  EXPECT_EQ(outcome.started_tiles, 1u);

  // Same frame, different modes, different phases: A at phase 1, B at 0.
  CaptureEmitter emitter;
  h.engine.advance(&emitter);
  EXPECT_EQ(emitter.code_at(0, 0), h.table.code(2, 0, 30, 0, 1));
  EXPECT_EQ(emitter.code_at(32, 32), h.table.code(7, 0, 30, 0, 0));
  EXPECT_EQ(emitter.rows.size(), 16u);

  // B (2 phases) completes first, A (4 phases) after.
  h.engine.advance(nullptr);
  ASSERT_EQ(h.completed.size(), 1u);
  EXPECT_EQ(h.completed[0], 2u);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 32, 32), 0);
  h.engine.advance(nullptr);
  ASSERT_EQ(h.completed.size(), 2u);
  EXPECT_EQ(h.completed[1], 1u);
  EXPECT_TRUE(h.engine.idle());
}

TEST(PixelEngineTest, AbsorbsRedundantDamageWithoutRestartingTheWaveform) {
  Harness h;
  h.engine.set_temperature(10.0f);

  const PlutoRect rect{0, 0, 8, 8};
  const std::vector<std::uint8_t> levels = uniform_levels(rect, 0);
  ASSERT_TRUE(h.engine.admit(make_request(rect, 2, levels, 1)));
  h.engine.advance(nullptr);  // phase 0 played

  // Identical targets while in flight: absorbed, free, no fnum reset.
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(make_request(rect, 2, levels, 2), &outcome));
  EXPECT_EQ(outcome.absorbed_tiles, 1u);
  EXPECT_EQ(outcome.started_tiles, 0u);
  EXPECT_EQ(plane_at(h.engine, h.engine.fnum_plane(), 0, 0), 1);

  // Next frame continues at phase 1 (a restart would replay phase 0).
  CaptureEmitter emitter;
  h.engine.advance(&emitter);
  EXPECT_EQ(emitter.code_at(0, 0), h.table.code(2, 0, 30, 0, 1));

  // Both frame_ids complete together at the shared waveform boundary.
  h.engine.advance(nullptr);
  h.engine.advance(nullptr);
  ASSERT_EQ(h.completed.size(), 2u);
  EXPECT_TRUE(contains(h.completed, 1));
  EXPECT_TRUE(contains(h.completed, 2));
  EXPECT_EQ(h.engine.stats().tiles_absorbed, 1u);
}

TEST(PixelEngineTest, ConflictParksAndReadmitsTheFrameAfterTheBoundary) {
  Harness h;
  h.engine.set_temperature(10.0f);  // mode 2 N=4

  const PlutoRect rect{0, 0, 8, 8};
  const std::vector<std::uint8_t> black = uniform_levels(rect, 0);
  const std::vector<std::uint8_t> gray = uniform_levels(rect, 15);
  ASSERT_TRUE(h.engine.admit(make_request(rect, 2, black, 1)));
  h.engine.advance(nullptr);  // phase 0

  // Different target on the busy tile: parks (early cancel off), never
  // queue-jumps mid-waveform.
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(make_request(rect, 2, gray, 2), &outcome));
  EXPECT_EQ(outcome.parked_tiles, 1u);
  EXPECT_EQ(outcome.started_tiles, 0u);
  EXPECT_EQ(h.engine.parked_count(), 1u);

  // The first waveform runs its full course to black.
  h.engine.advance(nullptr);
  h.engine.advance(nullptr);
  h.engine.advance(nullptr);
  ASSERT_EQ(h.completed.size(), 1u);
  EXPECT_EQ(h.completed[0], 1u);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 0, 0), 0);
  EXPECT_EQ(h.engine.stats().truncations, 0u);

  // The parked piece wakes the FRAME AFTER completion and re-admits.
  CaptureEmitter emitter;
  h.engine.advance(&emitter);
  EXPECT_EQ(h.engine.parked_count(), 0u);
  EXPECT_EQ(h.engine.stats().parked_wakes, 1u);
  EXPECT_EQ(emitter.code_at(0, 0), h.table.code(2, 0, 0, 15, 0));
  for (int i = 0; i < 3; ++i) {
    h.engine.advance(nullptr);
  }
  ASSERT_EQ(h.completed.size(), 2u);
  EXPECT_EQ(h.completed[1], 2u);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 0, 0), 15);
}

TEST(PixelEngineTest, OverlapStartsIdleTilesAndParksOnlyTheConflictRect) {
  Harness h;
  h.engine.set_temperature(10.0f);

  const PlutoRect rect_a{0, 0, 8, 8};
  const std::vector<std::uint8_t> black = uniform_levels(rect_a, 0);
  ASSERT_TRUE(h.engine.admit(make_request(rect_a, 2, black, 1)));

  // B spans both top tiles; only the tile blocked by A parks.
  const PlutoRect rect_b{0, 0, 40, 8};
  const std::vector<std::uint8_t> gray = uniform_levels(rect_b, 15);
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(make_request(rect_b, 2, gray, 2), &outcome));
  EXPECT_EQ(outcome.started_tiles, 1u);
  EXPECT_EQ(outcome.parked_tiles, 1u);

  for (int i = 0; i < 8; ++i) {
    h.engine.advance(nullptr);
  }
  ASSERT_EQ(h.completed.size(), 2u);
  EXPECT_TRUE(contains(h.completed, 1));
  EXPECT_TRUE(contains(h.completed, 2));
  // The whole of B (both tiles, including pixels A drove to black first)
  // settled at B's target.
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 0, 0), 15);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 20, 4), 15);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 39, 7), 15);
  EXPECT_TRUE(h.engine.idle());
}

TEST(PixelEngineTest, ActiveClipShrinksAsRegionsComplete) {
  Harness h;
  h.engine.set_temperature(10.0f);  // mode 2 N=4, mode 7 N=2

  const PlutoRect rect_a{0, 0, 8, 8};
  const PlutoRect rect_b{32, 32, 8, 8};
  const std::vector<std::uint8_t> black_a = uniform_levels(rect_a, 0);
  const std::vector<std::uint8_t> black_b = uniform_levels(rect_b, 0);
  ASSERT_TRUE(h.engine.admit(make_request(rect_a, 2, black_a, 1)));
  ASSERT_TRUE(h.engine.admit(make_request(rect_b, 7, black_b, 2)));
  EXPECT_EQ(h.engine.active_row_min(), 0);
  EXPECT_EQ(h.engine.active_row_max(), 39);
  EXPECT_EQ(h.engine.active_px_in_row(32), 8);

  h.engine.advance(nullptr);
  h.engine.advance(nullptr);  // B (2 phases) completes here
  EXPECT_EQ(h.engine.active_row_max(), 7);
  EXPECT_EQ(h.engine.active_px_in_row(32), 0);
  EXPECT_EQ(h.engine.active_px_in_row(4), 8);

  // Emission after the shrink touches only the remaining rows (row-skip).
  CaptureEmitter emitter;
  h.engine.advance(&emitter);
  EXPECT_EQ(emitter.max_row(), 7);
  h.engine.advance(nullptr);
  EXPECT_TRUE(h.engine.idle());
  EXPECT_EQ(h.engine.active_row_max(), -1);
}

TEST(PixelEngineTest, FullFieldAdmissionIsBandAmortized) {
  PixelEngineConfig config = small_config();
  config.max_active_px = 1024;  // one tile row's worth
  Harness h(config);
  // Default bin 1: mode 2 N=3.
  ASSERT_EQ(h.engine.current_temp_bin(), 1);

  const PlutoRect rect{0, 0, 64, 64};  // 4096 px > max_active_px
  const std::vector<std::uint8_t> levels = uniform_levels(rect, 0);
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(make_request(rect, 2, levels, 9), &outcome));
  // 64 rows split on the tile grid: band 0 = rows 0..31 now, one deferred
  // band = rows 32..63 the next frame (<= full_flash_band_frames stagger).
  EXPECT_EQ(outcome.deferred_bands, 1u);
  EXPECT_EQ(h.engine.total_active_px(), 2048u);

  CaptureEmitter emitter;
  h.engine.advance(&emitter);
  EXPECT_EQ(emitter.max_row(), 31);  // one frame never sweeps the field

  emitter.clear();
  h.engine.advance(&emitter);
  EXPECT_EQ(emitter.max_row(), 63);  // second band admitted one frame later
  EXPECT_EQ(emitter.code_at(0, 0), h.table.code(2, 1, 30, 0, 1));
  EXPECT_EQ(emitter.code_at(32, 0), h.table.code(2, 1, 30, 0, 0));

  h.engine.advance(nullptr);          // band 0 completes (N=3)
  EXPECT_EQ(h.completed.size(), 0u);  // ...but the update is not done yet
  h.engine.advance(nullptr);          // band 1 completes
  ASSERT_EQ(h.completed.size(), 1u);
  EXPECT_EQ(h.completed[0], 9u);
  EXPECT_TRUE(h.engine.idle());
  for (int y = 0; y < 64; y += 21) {
    EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 13, y), 0) << "y=" << y;
  }
}

// Bring-up sweep bound (device livelock fix): a full-field FORCE-IDENTITY
// admission (the cold-clear shape — every pixel activates regardless of
// target vs prev) must never activate more than the banding bound at once.
// The 1-frame onset stagger alone cannot bound it: every band runs a whole
// waveform, so staggered bands overlap into a full-field sweep (device
// active_px_peak = the entire panel, feeding missed build deadlines).
// Force-identity bands additionally wait for busy-pixel headroom, so the
// concurrent sweep stays at one band here (bands == budget exactly).
TEST(PixelEngineTest, FullFieldForceIdentityNeverActivatesMoreThanOneBand) {
  PixelEngineConfig config;
  config.width = 64;
  config.height = 96;
  config.stride = 64;
  config.tile_px = 8;
  config.max_active_px = 2048;  // 6144 px field -> 3 bands of 2048
  Harness h(config);            // bin 1: mode 2 N=3

  const PlutoRect rect{0, 0, 64, 96};
  // Identity content (target == prev): ONLY force-identity activates it.
  const std::vector<std::uint8_t> levels =
      uniform_levels(rect, config.initial_prev_level);
  AdmitOutcome outcome;
  ASSERT_TRUE(
      h.engine.admit(make_request(rect, 2, levels, 0,
                                  kAdmitFlagSettle | kAdmitFlagForceIdentity),
                     &outcome));
  EXPECT_EQ(outcome.deferred_bands, 2u);
  EXPECT_EQ(h.engine.total_active_px(), 2048u);  // band 0 only

  // The banding bound: at every frame the sweep is at most one band, and
  // in particular never the whole field.
  std::uint32_t peak = h.engine.total_active_px();
  int advances = 0;
  while (!h.engine.idle() || h.engine.parked_count() > 0) {
    ASSERT_TRUE(advances < 30) << "cold-clear shape failed to complete";
    h.engine.advance(nullptr);
    ++advances;
    peak = std::max(peak, h.engine.total_active_px());
  }
  EXPECT_EQ(peak, 2048u);  // == max_active_px + 0: bands gate on headroom
  EXPECT_LT(peak, 6144u);  // never the whole field at once
  EXPECT_EQ(h.engine.stats().settle_completions, 1u);
  EXPECT_EQ(h.completed.size(), 0u);  // settle sentinel: no user completion

  // Contrast pin: the SAME field as plain content keeps the pure 1-frame
  // onset stagger (E10) — bands overlap and the peak exceeds one
  // band. This is the pre-existing behavior for user flashes.
  Harness user(config);
  const std::vector<std::uint8_t> black = uniform_levels(rect, 0);
  ASSERT_TRUE(user.engine.admit(make_request(rect, 2, black, 1)));
  std::uint32_t user_peak = user.engine.total_active_px();
  for (int i = 0;
       i < 30 && (!user.engine.idle() || user.engine.parked_count() > 0); ++i) {
    user.engine.advance(nullptr);
    user_peak = std::max(user_peak, user.engine.total_active_px());
  }
  EXPECT_GT(user_peak, 2048u);
  EXPECT_TRUE(user.engine.idle());
}

TEST(PixelEngineTest, BudgetDefersNonPenAdmissionsUntilPixelsRecover) {
  PixelEngineConfig config = small_config();
  config.max_active_px = 100;
  Harness h(config);  // bin 1: mode 2 N=3

  const PlutoRect rect_a{0, 0, 10, 10};  // exactly the budget
  const std::vector<std::uint8_t> black_a = uniform_levels(rect_a, 0);
  ASSERT_TRUE(h.engine.admit(make_request(rect_a, 2, black_a, 1)));
  EXPECT_EQ(h.engine.total_active_px(), 100u);

  // Non-PEN work defers while the budget is exhausted...
  const PlutoRect rect_b{32, 32, 4, 4};
  const std::vector<std::uint8_t> black_b = uniform_levels(rect_b, 0);
  AdmitOutcome outcome_b;
  ASSERT_TRUE(h.engine.admit(make_request(rect_b, 2, black_b, 2), &outcome_b));
  EXPECT_TRUE(outcome_b.budget_deferred);
  EXPECT_EQ(outcome_b.started_tiles, 0u);

  // ...but the production payload-carrying pen preview is budget-exempt:
  // always admitted, even while ordinary work is saturated.
  const PlutoRect rect_c{40, 40, 4, 4};
  const std::vector<std::uint8_t> black_c = uniform_levels(rect_c, 0);
  AdmitOutcome outcome_c;
  ASSERT_TRUE(h.engine.admit(
      make_request(rect_c, 7, black_c, 3, kAdmitFlagPenPreview), &outcome_c));
  EXPECT_EQ(outcome_c.started_tiles, 1u);
  EXPECT_FALSE(outcome_c.budget_deferred);

  for (int i = 0; i < 8; ++i) {
    h.engine.advance(nullptr);
  }
  ASSERT_EQ(h.completed.size(), 3u);
  EXPECT_TRUE(contains(h.completed, 2));
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 33, 33), 0);
  EXPECT_EQ(h.engine.stats().budget_deferrals, 1u);
}

TEST(PixelEngineTest, PauseChargesStressAndAdvancesNoFnum) {
  Harness h;
  h.engine.set_temperature(10.0f);  // mode 2 N=4

  const PlutoRect rect{0, 0, 4, 4};
  const std::vector<std::uint8_t> levels = uniform_levels(rect, 0);
  ASSERT_TRUE(h.engine.admit(make_request(rect, 2, levels, 1)));
  h.engine.advance(nullptr);
  ASSERT_EQ(plane_at(h.engine, h.engine.fnum_plane(), 0, 0), 1);
  const std::uint64_t frame_before = h.engine.frame();

  // A missed deadline is a waveform time-stretch: nothing advances and the
  // engine frame does not tick. Pauses are COUNTED but charge NO stress —
  // the scanned plane is the impulse-free HOLD scaffold, and pauses are
  // routine under load (charging them promoted every transition's tiles
  // into flashing GC16 settles).
  h.engine.pause();
  h.engine.pause();
  EXPECT_EQ(plane_at(h.engine, h.engine.fnum_plane(), 0, 0), 1);
  EXPECT_EQ(h.engine.frame(), frame_before);
  EXPECT_EQ(h.engine.stats().pauses, 2u);
  EXPECT_EQ(h.engine.dc_ledger().stress(0), 0);
  EXPECT_EQ(h.engine.dc_ledger().stress(1), 0);  // idle tiles uncharged
  EXPECT_EQ(h.completed.size(), 0u);

  // The sequence still takes exactly N emitting frames in total.
  CaptureEmitter emitter;
  h.engine.advance(&emitter);
  EXPECT_EQ(emitter.code_at(0, 0), h.table.code(2, 0, 30, 0, 1));
  h.engine.advance(nullptr);
  h.engine.advance(nullptr);
  ASSERT_EQ(h.completed.size(), 1u);
}

TEST(PixelEngineTest, DcLedgerChargesEveryOpAndRenormalizesBalancedModes) {
  Harness h;
  h.engine.set_temperature(10.0f);
  const std::size_t px_a = 0;  // (0,0)

  // Balanced mode 2: charged during flight, reset to zero at completion
  // (trust_vendor_balance deviation model).
  const PlutoRect rect_a{0, 0, 4, 4};
  const std::vector<std::uint8_t> black = uniform_levels(rect_a, 0);
  ASSERT_TRUE(h.engine.admit(make_request(rect_a, 2, black, 1)));
  h.engine.advance(nullptr);
  const int impulse_phase0 =
      h.engine.dc_ledger().impulse(h.table.code(2, 0, 30, 0, 0));
  EXPECT_EQ(static_cast<int>(h.engine.dc_ledger().dc(px_a)), impulse_phase0);
  for (int i = 0; i < 3; ++i) {
    h.engine.advance(nullptr);
  }
  EXPECT_EQ(h.engine.dc_ledger().dc(px_a), 0);
  EXPECT_FALSE(h.engine.dc_ledger().prev_estimated(px_a));

  // Rail mode 7 is NOT balanced: the net impulse of the full sequence
  // stays on the ledger after completion.
  const PlutoRect rect_b{32, 32, 4, 4};
  const std::vector<std::uint8_t> black_b = uniform_levels(rect_b, 0);
  ASSERT_TRUE(h.engine.admit(make_request(rect_b, 7, black_b, 2)));
  h.engine.advance(nullptr);
  h.engine.advance(nullptr);
  int expected = 0;
  for (int phase = 0; phase < h.table.phase_count(7, 0); ++phase) {
    expected += h.engine.dc_ledger().impulse(h.table.code(7, 0, 30, 0, phase));
  }
  const std::size_t px_b =
      32u * static_cast<std::size_t>(h.engine.plane_stride()) + 32u;
  EXPECT_EQ(static_cast<int>(h.engine.dc_ledger().dc(px_b)), expected);
  EXPECT_NE(expected, 0);
}

// Property: repeated balanced GC16 cycles with random content
// keep |dc| bounded and renormalize to zero on every completed sequence.
TEST(PixelEngineTest, RepeatedBalancedCyclesKeepDcBounded) {
  PixelEngineConfig config = small_config();
  config.dc.dc_pixel_cap = 16;
  Harness h(config);
  h.engine.set_temperature(10.0f);

  std::srand(4321);
  const PlutoRect rect{0, 0, 16, 16};
  const int stride = h.engine.plane_stride();
  const std::int8_t cap = h.engine.config().dc.dc_pixel_cap;
  for (int cycle = 0; cycle < 24; ++cycle) {
    std::vector<std::uint8_t> levels(static_cast<std::size_t>(rect.width) *
                                     static_cast<std::size_t>(rect.height));
    for (std::uint8_t& level : levels) {
      level = static_cast<std::uint8_t>(std::rand() % 32);
    }
    ASSERT_TRUE(h.engine.admit(
        make_request(rect, 2, levels, static_cast<std::uint64_t>(cycle + 1))));
    while (!h.engine.idle()) {
      h.engine.advance(nullptr);
      for (int y = 0; y < rect.height; ++y) {
        for (int x = 0; x < rect.width; ++x) {
          const int dc = h.engine.dc_ledger().dc(
              static_cast<std::size_t>(y) * static_cast<std::size_t>(stride) +
              static_cast<std::size_t>(x));
          EXPECT_LE(dc, static_cast<int>(cap));
          EXPECT_GE(dc, -static_cast<int>(cap));
        }
      }
    }
    // Balanced completion renormalized every driven pixel.
    for (int y = 0; y < rect.height; ++y) {
      for (int x = 0; x < rect.width; ++x) {
        ASSERT_EQ(h.engine.dc_ledger().dc(static_cast<std::size_t>(y) *
                                              static_cast<std::size_t>(stride) +
                                          static_cast<std::size_t>(x)),
                  0)
            << "cycle=" << cycle << " x=" << x << " y=" << y;
      }
    }
  }
  ASSERT_EQ(h.completed.size(), 24u);
}

TEST(PixelEngineTest, GuardNullAdmissionDrivesLedgeredIdentityTransitions) {
  Harness h;
  h.engine.set_temperature(10.0f);

  // Guard band: null transitions next := prev, no levels payload. The
  // emitted identity ops are real drive and are DC-ledgered.
  AdmitRequest request;
  request.rect = {0, 0, 4, 4};
  request.mode = 2;
  request.frame_id = 5;
  request.flags = kAdmitFlagGuardNull;
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(request, &outcome));
  EXPECT_EQ(outcome.started_tiles, 1u);
  EXPECT_EQ(h.engine.total_active_px(), 16u);

  CaptureEmitter emitter;
  h.engine.advance(&emitter);
  const int identity_code = h.table.code(2, 0, 30, 30, 0);
  EXPECT_EQ(emitter.code_at(0, 0), identity_code);
  EXPECT_EQ(
      static_cast<int>(h.engine.dc_ledger().dc(0)),
      h.engine.dc_ledger().impulse(static_cast<std::uint8_t>(identity_code)));

  for (int i = 0; i < 3; ++i) {
    h.engine.advance(nullptr);
  }
  ASSERT_EQ(h.completed.size(), 1u);
  EXPECT_EQ(h.completed[0], 5u);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 0, 0), 30);
}

TEST(PixelEngineTest, SettleSentinelFiresNoUserCompletion) {
  Harness h;
  h.engine.set_temperature(10.0f);

  const PlutoRect rect{0, 0, 4, 4};
  const std::vector<std::uint8_t> black = uniform_levels(rect, 0);
  ASSERT_TRUE(
      h.engine.admit(make_request(rect, 2, black, 0, kAdmitFlagSettle)));
  for (int i = 0; i < 4; ++i) {
    h.engine.advance(nullptr);
  }
  EXPECT_EQ(h.completed.size(), 0u);  // no user completion
  EXPECT_EQ(h.engine.stats().settle_completions, 1u);
  EXPECT_EQ(h.engine.stats().completions, 0u);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 0, 0), 0);
}

TEST(PixelEngineTest, SettleForceIdentityIsGatedOffByDefault) {
  // Default (E3 gate off): a settle whose targets equal the glass state
  // drives nothing and completes instantly.
  Harness off;
  off.engine.set_temperature(10.0f);
  const PlutoRect rect{0, 0, 4, 4};
  const std::vector<std::uint8_t> white = uniform_levels(rect, 30);
  AdmitOutcome outcome;
  ASSERT_TRUE(off.engine.admit(
      make_request(rect, 2, white, 0, kAdmitFlagSettle), &outcome));
  EXPECT_EQ(outcome.started_tiles, 0u);
  EXPECT_EQ(outcome.noop_tiles, 1u);
  EXPECT_TRUE(off.engine.idle());
  EXPECT_EQ(off.engine.stats().settle_completions, 1u);

  // E3 flip: identity transitions become real drive.
  PixelEngineConfig config = small_config();
  config.settle_force_identity = true;
  Harness on(config);
  on.engine.set_temperature(10.0f);
  ASSERT_TRUE(on.engine.admit(make_request(rect, 2, white, 0, kAdmitFlagSettle),
                              &outcome));
  EXPECT_EQ(outcome.started_tiles, 1u);
  EXPECT_EQ(on.engine.total_active_px(), 16u);
  for (int i = 0; i < 4; ++i) {
    on.engine.advance(nullptr);
  }
  EXPECT_TRUE(on.engine.idle());
  EXPECT_EQ(on.engine.stats().settle_completions, 1u);
}

TEST(PixelEngineTest, EarlyCancelOffRailRetargetWaitsForTheBoundary) {
  PixelEngineConfig off_config = small_config();
  off_config.early_cancel_enabled = false;  // explicit: default is ON (E2)
  Harness h(off_config);
  h.engine.set_temperature(10.0f);  // mode 7 N=2

  const PlutoRect rect{0, 0, 4, 4};
  const std::vector<std::uint8_t> black = uniform_levels(rect, 0);
  const std::vector<std::uint8_t> white = uniform_levels(rect, 30);
  ASSERT_TRUE(h.engine.admit(make_request(rect, 7, black, 1)));
  h.engine.advance(nullptr);

  // Rail-on-rail retarget with the gate OFF: parks, never truncates.
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(make_request(rect, 7, white, 2), &outcome));
  EXPECT_EQ(outcome.retargeted_tiles, 0u);
  EXPECT_EQ(outcome.parked_tiles, 1u);

  h.engine.advance(nullptr);  // first waveform reaches its boundary
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 0, 0), 0);
  EXPECT_EQ(h.engine.stats().truncations, 0u);
  EXPECT_FALSE(h.engine.dc_ledger().prev_estimated(0));

  h.engine.advance(nullptr);  // parked retarget admits, drives 0 -> 30
  h.engine.advance(nullptr);
  ASSERT_EQ(h.completed.size(), 2u);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 0, 0), 30);
}

TEST(PixelEngineTest, EarlyCancelOnRailRetargetTruncatesInPlace) {
  PixelEngineConfig config = small_config();
  config.early_cancel_enabled = true;  // E2-gated, host-forced here
  Harness h(config);
  h.engine.set_temperature(10.0f);  // mode 7 N=2

  const PlutoRect rect{0, 0, 4, 4};
  const std::vector<std::uint8_t> black = uniform_levels(rect, 0);
  const std::vector<std::uint8_t> white = uniform_levels(rect, 30);
  ASSERT_TRUE(h.engine.admit(make_request(rect, 7, black, 1)));
  h.engine.advance(nullptr);
  ASSERT_EQ(plane_at(h.engine, h.engine.fnum_plane(), 0, 0), 1);

  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(make_request(rect, 7, white, 2), &outcome));
  EXPECT_EQ(outcome.retargeted_tiles, 1u);
  EXPECT_EQ(outcome.parked_tiles, 0u);
  // Truncation semantics: prev estimated as the rail the prefix pushed
  // toward, prev_est set, fnum restarted, tile stress charged.
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 0, 0), 0);
  EXPECT_TRUE(h.engine.dc_ledger().prev_estimated(0));
  EXPECT_EQ(plane_at(h.engine, h.engine.fnum_plane(), 0, 0), 0);
  EXPECT_EQ(plane_at(h.engine, h.engine.next_plane(), 0, 0), 30);
  EXPECT_EQ(h.engine.stats().truncations, 1u);
  EXPECT_EQ(h.engine.dc_ledger().stress(0), h.engine.config().dc.k_cancel);

  h.engine.advance(nullptr);
  h.engine.advance(nullptr);
  ASSERT_EQ(h.completed.size(), 2u);
  EXPECT_TRUE(contains(h.completed, 1));
  EXPECT_TRUE(contains(h.completed, 2));
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 0, 0), 30);
  // The completed full sequence restored trust in the optical state.
  EXPECT_FALSE(h.engine.dc_ledger().prev_estimated(0));
}

TEST(PixelEngineTest,
     RegionalQualityDoesNotStressPromoteAndGlobalBalancedPassRepays) {
  PixelEngineConfig config = small_config();
  config.early_cancel_enabled = true;
  config.dc.dc_stress_force = 7;  // two k_cancel=4 truncations trip it
  Harness h(config);              // bin 1: mode 2 N=3, mode 7 N=2

  const PlutoRect rect{0, 0, 4, 4};
  const std::vector<std::uint8_t> black = uniform_levels(rect, 0);
  const std::vector<std::uint8_t> white = uniform_levels(rect, 30);

  ASSERT_TRUE(h.engine.admit(make_request(rect, 7, black, 1)));
  h.engine.advance(nullptr);
  ASSERT_TRUE(h.engine.admit(make_request(rect, 7, white, 2)));  // trunc 1
  h.engine.advance(nullptr);
  ASSERT_TRUE(h.engine.admit(make_request(rect, 7, black, 3)));  // trunc 2
  EXPECT_EQ(h.engine.dc_ledger().stress(0), 8);
  h.engine.advance(nullptr);
  h.engine.advance(nullptr);  // rail sequence completes; stress remains
  ASSERT_TRUE(h.engine.idle());
  EXPECT_TRUE(h.engine.dc_ledger().forces_balanced(0));

  // A LIVE content update on the stressed tile is NOT promoted — promoting
  // live admissions flashed a mosaic of GC16 black squares across every
  // view switch. The stress persists, awaiting a settle.
  AdmitOutcome live_outcome;
  ASSERT_TRUE(h.engine.admit(make_request(rect, 7, white, 4), &live_outcome));
  EXPECT_EQ(live_outcome.started_tiles, 1u);
  EXPECT_EQ(static_cast<int>(h.engine.tile(0, 0).mode), 7);
  EXPECT_EQ(h.engine.tile(0, 0).flags & kTileFlagStressPromoted, 0);
  EXPECT_EQ(h.engine.stats().stress_promotions, 0u);
  for (int i = 0; i < 3; ++i) {
    h.engine.advance(nullptr);
  }
  ASSERT_TRUE(h.engine.idle());
  EXPECT_TRUE(h.engine.dc_ledger().forces_balanced(0));  // still owed

  // A regional QUALITY settle remains in its requested non-flashing mode.
  // Real Move evidence showed tile-local balanced promotion as destructive
  // black/gold mosaics, so stress stays owed for global maintenance.
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(make_request(rect, 7, black, 5, kAdmitFlagQuality),
                             &outcome));
  EXPECT_EQ(outcome.started_tiles, 1u);
  EXPECT_EQ(static_cast<int>(h.engine.tile(0, 0).mode), 7);
  EXPECT_EQ(h.engine.tile(0, 0).flags & kTileFlagStressPromoted, 0);
  EXPECT_EQ(h.engine.stats().stress_promotions, 0u);

  for (int i = 0; i < 3; ++i) {
    h.engine.advance(nullptr);
  }
  ASSERT_TRUE(h.engine.idle());
  EXPECT_TRUE(h.engine.dc_ledger().forces_balanced(0));

  // The serialized Bleach/Both restore is one global mode-2 content pass.
  // A genuine balanced completion repays stress without regional mosaics or
  // bookkeeping-only forgiveness; production does not force identity, which
  // would serialize a full field into visibly staggered bands.
  ASSERT_TRUE(h.engine.admit(make_request(rect, 2, white, 6)));
  for (int i = 0; i < 4; ++i) {
    h.engine.advance(nullptr);
  }
  ASSERT_TRUE(h.engine.idle());
  EXPECT_EQ(h.engine.dc_ledger().stress(0), 0);
  EXPECT_FALSE(h.engine.dc_ledger().forces_balanced(0));
}

TEST(PixelEngineTest, BinChangeMidSequencePinsActiveTilesToTheirBin) {
  Harness h;
  h.engine.set_temperature(10.0f);
  ASSERT_EQ(h.engine.current_temp_bin(), 0);

  const PlutoRect rect_a{0, 0, 8, 8};
  const std::vector<std::uint8_t> black_a = uniform_levels(rect_a, 0);
  ASSERT_TRUE(h.engine.admit(make_request(rect_a, 2, black_a, 1)));
  h.engine.advance(nullptr);
  EXPECT_EQ(h.engine.lut_cache().pin_refcount(2, 0), 1);

  // The bin moves mid-sequence; the active tile keeps its pinned bin.
  h.engine.set_temperature(40.0f);
  ASSERT_EQ(h.engine.current_temp_bin(), 1);
  const PlutoRect rect_b{32, 32, 8, 8};
  const std::vector<std::uint8_t> black_b = uniform_levels(rect_b, 0);
  ASSERT_TRUE(h.engine.admit(make_request(rect_b, 2, black_b, 2)));
  EXPECT_EQ(static_cast<int>(h.engine.tile(0, 0).temp_bin), 0);
  EXPECT_EQ(static_cast<int>(h.engine.tile(1, 1).temp_bin), 1);
  EXPECT_TRUE(h.engine.lut_cache().resident(2, 0));
  EXPECT_TRUE(h.engine.lut_cache().resident(2, 1));
  EXPECT_EQ(h.engine.lut_cache().pin_refcount(2, 1), 1);

  // Same frame: tile A gathers from the bin-0 record (phase 1), tile B
  // from the DIFFERENT bin-1 record (phase 0).
  CaptureEmitter emitter;
  h.engine.advance(&emitter);
  EXPECT_EQ(emitter.code_at(0, 0), h.table.code(2, 0, 30, 0, 1));
  EXPECT_EQ(emitter.code_at(32, 32), h.table.code(2, 1, 30, 0, 0));
  EXPECT_NE(h.table.code(2, 0, 30, 0, 1), h.table.code(2, 1, 30, 0, 1));

  // Run both to completion: A takes 4 phases (bin 0), B takes 3 (bin 1).
  h.engine.advance(nullptr);
  h.engine.advance(nullptr);
  h.engine.advance(nullptr);
  ASSERT_TRUE(h.engine.idle());
  ASSERT_EQ(h.completed.size(), 2u);
  EXPECT_EQ(h.engine.lut_cache().pin_refcount(2, 0), 0);
  EXPECT_EQ(h.engine.lut_cache().pin_refcount(2, 1), 0);
}

TEST(PixelEngineTest, ExplicitAdmissionBinSurvivesCurrentTemperatureChange) {
  Harness h;
  h.engine.set_temperature(10.0f);
  ASSERT_EQ(h.engine.current_temp_bin(), 0);

  const PlutoRect rect{32, 32, 8, 8};
  const std::vector<std::uint8_t> black = uniform_levels(rect, 0);
  AdmitRequest request = make_request(rect, 2, black, 91);
  request.temp_bin = 1;
  ASSERT_TRUE(h.engine.admit(request));
  EXPECT_EQ(static_cast<int>(h.engine.tile(1, 1).temp_bin), 1);
  EXPECT_EQ(h.engine.lut_cache().pin_refcount(2, 1), 1);
  EXPECT_EQ(h.engine.current_temp_bin(), 0);

  for (int i = 0; i < 3; ++i) {
    h.engine.advance(nullptr);
  }
  EXPECT_TRUE(h.engine.idle());
}

TEST(PixelEngineTest, MultiTileUpdateFiresOneCompletionWhenAllTilesFinish) {
  Harness h;
  h.engine.set_temperature(10.0f);

  const PlutoRect rect{0, 0, 64, 64};  // all four tiles
  const std::vector<std::uint8_t> black = uniform_levels(rect, 0);
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(make_request(rect, 2, black, 11), &outcome));
  EXPECT_EQ(outcome.started_tiles, 4u);

  for (int i = 0; i < 4; ++i) {
    EXPECT_EQ(h.completed.size(), 0u);
    h.engine.advance(nullptr);
  }
  ASSERT_EQ(h.completed.size(), 1u);
  EXPECT_EQ(h.completed[0], 11u);
}

TEST(PixelEngineTest, NothingToDriveCompletesInstantly) {
  Harness h;
  h.engine.set_temperature(10.0f);

  const PlutoRect rect{8, 8, 8, 8};
  const std::vector<std::uint8_t> white = uniform_levels(rect, 30);
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(make_request(rect, 2, white, 21), &outcome));
  EXPECT_EQ(outcome.started_tiles, 0u);
  EXPECT_EQ(outcome.noop_tiles, 1u);
  EXPECT_TRUE(h.engine.idle());
  ASSERT_EQ(h.completed.size(), 1u);
  EXPECT_EQ(h.completed[0], 21u);
}

// Engine-level scalar-vs-NEON parity golden (the sweep-kernel extension of
// the renderer kernels golden pattern): two engines — one forced onto the
// scalar reference sweep, one on the default dispatch — driven through an
// identical random workload (multi-mode admissions, overlaps, guard nulls,
// force-identity, early-cancel retargets, pauses) must stay byte-identical
// across every plane, the DC ledger, the emitted rows, and the impulse
// summary sink. On non-NEON hosts both engines run the scalar reference and
// the test pins determinism.
TEST(PixelEngineTest, SweepDispatchMatchesScalarReferenceGolden) {
  const WaveformTable table = parse_engine_table();

  PixelEngineConfig scalar_config = small_config();
  // 90x64 on a 96 stride: two full tile columns + one 26-px partial column
  // (the panel's own right-edge shape), 2 tile rows.
  scalar_config.width = 90;
  scalar_config.stride = 96;
  scalar_config.height = 64;
  scalar_config.force_scalar_sweep = true;
  scalar_config.early_cancel_enabled = true;  // mixed-fnum tiles
  PixelEngineConfig neon_config = scalar_config;
  neon_config.force_scalar_sweep = false;

  PixelEngine scalar_engine;
  PixelEngine neon_engine;
  ASSERT_TRUE(scalar_engine.configure(&table, scalar_config));
  ASSERT_TRUE(neon_engine.configure(&table, neon_config));

  const std::size_t tiles =
      static_cast<std::size_t>(scalar_engine.tile_cols()) *
      scalar_engine.tile_rows();
  std::vector<std::int32_t> scalar_impulse(tiles, 0);
  std::vector<std::uint8_t> scalar_drive(tiles, 0);
  std::vector<std::int32_t> neon_impulse(tiles, 0);
  std::vector<std::uint8_t> neon_drive(tiles, 0);
  scalar_engine.set_impulse_sink(scalar_impulse.data(), scalar_drive.data());
  neon_engine.set_impulse_sink(neon_impulse.data(), neon_drive.data());

  std::mt19937 rng(0xabcd1234);
  const auto rand_int = [&rng](int lo, int hi) {
    return lo + static_cast<int>(rng() % static_cast<unsigned>(hi - lo + 1));
  };

  for (int frame = 0; frame < 120; ++frame) {
    // 0-2 admissions per frame: random rects, modes 2 (multi-phase) and 7
    // (rail), random flags.
    const int admissions = rand_int(0, 2);
    for (int a = 0; a < admissions; ++a) {
      PlutoRect rect;
      rect.x = rand_int(0, 82);
      rect.y = rand_int(0, 56);
      rect.width = rand_int(1, 90 - rect.x);
      rect.height = rand_int(1, 64 - rect.y);
      std::vector<std::uint8_t> levels(static_cast<std::size_t>(rect.width) *
                                       static_cast<std::size_t>(rect.height));
      for (auto& level : levels) {
        level = static_cast<std::uint8_t>(rng() % 32);
      }
      const int mode = (rng() % 3 == 0) ? 7 : 2;
      std::uint32_t flags = 0;
      const int flavor = rand_int(0, 9);
      if (flavor == 0) {
        flags = kAdmitFlagGuardNull;
      } else if (flavor == 1) {
        flags = kAdmitFlagForceIdentity;
      } else if (flavor == 2) {
        flags = kAdmitFlagSettle;
      }
      AdmitRequest request =
          make_request(rect, mode, levels,
                       static_cast<std::uint64_t>(frame * 8 + a + 1), flags);
      if ((flags & kAdmitFlagGuardNull) != 0) {
        request.levels = nullptr;
      }
      ASSERT_EQ(scalar_engine.admit(request), neon_engine.admit(request));
    }
    if (rng() % 8 == 0) {
      scalar_engine.pause();
      neon_engine.pause();
    }

    CaptureEmitter scalar_rows;
    CaptureEmitter neon_rows;
    scalar_engine.advance(&scalar_rows);
    neon_engine.advance(&neon_rows);

    ASSERT_EQ(scalar_rows.rows.size(), neon_rows.rows.size())
        << "frame " << frame;
    for (std::size_t r = 0; r < scalar_rows.rows.size(); ++r) {
      ASSERT_EQ(scalar_rows.rows[r].row, neon_rows.rows[r].row)
          << "frame " << frame;
      ASSERT_EQ(scalar_rows.rows[r].ops.size(), neon_rows.rows[r].ops.size())
          << "frame " << frame << " row " << scalar_rows.rows[r].row;
      for (std::size_t o = 0; o < scalar_rows.rows[r].ops.size(); ++o) {
        ASSERT_EQ(scalar_rows.rows[r].ops[o].x, neon_rows.rows[r].ops[o].x);
        ASSERT_EQ(scalar_rows.rows[r].ops[o].code,
                  neon_rows.rows[r].ops[o].code);
      }
    }

    const std::size_t plane = static_cast<std::size_t>(scalar_config.stride) *
                              static_cast<std::size_t>(scalar_config.height);
    ASSERT_EQ(0, std::memcmp(scalar_engine.prev_plane(),
                             neon_engine.prev_plane(), plane))
        << "frame " << frame;
    ASSERT_EQ(0, std::memcmp(scalar_engine.next_plane(),
                             neon_engine.next_plane(), plane))
        << "frame " << frame;
    ASSERT_EQ(0, std::memcmp(scalar_engine.final_plane(),
                             neon_engine.final_plane(), plane))
        << "frame " << frame;
    ASSERT_EQ(0, std::memcmp(scalar_engine.fnum_plane(),
                             neon_engine.fnum_plane(), plane))
        << "frame " << frame;
    for (std::size_t px = 0; px < plane; ++px) {
      ASSERT_EQ(scalar_engine.dc_ledger().dc(px),
                neon_engine.dc_ledger().dc(px))
          << "frame " << frame << " px " << px;
      ASSERT_EQ(scalar_engine.dc_ledger().prev_estimated(px),
                neon_engine.dc_ledger().prev_estimated(px))
          << "frame " << frame << " px " << px;
    }
    ASSERT_EQ(scalar_engine.dc_ledger().saturations(),
              neon_engine.dc_ledger().saturations())
        << "frame " << frame;
    ASSERT_EQ(scalar_engine.dc_ledger().prev_estimated_count(),
              neon_engine.dc_ledger().prev_estimated_count())
        << "frame " << frame;
    ASSERT_TRUE(scalar_impulse == neon_impulse) << "frame " << frame;
    ASSERT_TRUE(scalar_drive == neon_drive) << "frame " << frame;
    ASSERT_EQ(scalar_engine.total_active_px(), neon_engine.total_active_px())
        << "frame " << frame;
    ASSERT_EQ(scalar_engine.stats().ops_emitted,
              neon_engine.stats().ops_emitted)
        << "frame " << frame;
    ASSERT_EQ(scalar_engine.stats().completions,
              neon_engine.stats().completions)
        << "frame " << frame;
  }
}

}  // namespace

// Dashed-motion regression: a pen-priority app-damage admission landing on an
// in-flight SAME-rail-mode tile rides along via retarget instead of parking
// behind the tile's waveform. The gate stays rail-only/same-mode and must hold
// even with early_cancel forced OFF (pen-priority content is
// retarget-eligible).
TEST(PixelEngineTest,
     PenPreviewRidesAlongInFlightSameModeTileInsteadOfParking) {
  PixelEngineConfig off_config = small_config();
  off_config.early_cancel_enabled = false;  // preview must not depend on E2
  Harness h(off_config);
  h.engine.set_temperature(10.0f);  // mode 7 N=2

  const PlutoRect seg1{0, 0, 4, 4};
  const std::vector<std::uint8_t> black1 = uniform_levels(seg1, 0);
  ASSERT_TRUE(h.engine.admit(
      make_request(seg1, 7, black1, 1, pluto::swtcon::kAdmitFlagPenPreview)));
  h.engine.advance(nullptr);  // stroke segment 1 mid-waveform

  // Segment 2 extends the app damage across the same tile (new pixels differ
  // from the tile's in-flight targets): rides along — the fresh pixels
  // start immediately, no park, no truncation (segment-1 pixels keep their
  // unchanged target).
  const PlutoRect seg2{0, 0, 8, 4};
  const std::vector<std::uint8_t> black2 = uniform_levels(seg2, 0);
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(
      make_request(seg2, 7, black2, 2, pluto::swtcon::kAdmitFlagPenPreview),
      &outcome));
  EXPECT_EQ(outcome.retargeted_tiles, 1u);
  EXPECT_EQ(outcome.parked_tiles, 0u);
  EXPECT_EQ(h.engine.parked_count(), 0u);
  EXPECT_EQ(h.engine.stats().truncations, 0u);

  h.engine.advance(nullptr);
  h.engine.advance(nullptr);
  ASSERT_EQ(h.completed.size(), 2u);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 0, 0), 0);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 7, 0), 0);

  // A NON-ink admission with a differing target on a busy tile still parks
  // (unchanged semantics; early_cancel stays off).
  const PlutoRect rect{0, 0, 4, 4};
  const std::vector<std::uint8_t> white = uniform_levels(rect, 30);
  ASSERT_TRUE(h.engine.admit(make_request(rect, 7, white, 3)));
  h.engine.advance(nullptr);  // white drive mid-waveform
  const std::vector<std::uint8_t> black3 = uniform_levels(rect, 0);
  AdmitOutcome plain;
  ASSERT_TRUE(h.engine.admit(make_request(rect, 7, black3, 4), &plain));
  EXPECT_EQ(plain.retargeted_tiles, 0u);
  EXPECT_EQ(plain.parked_tiles, 1u);
}

TEST(PixelEngineTest, PenPreviewNeverRetargetsThroughDifferentTemperatureLut) {
  PixelEngineConfig config = small_config();
  config.early_cancel_enabled = false;
  Harness h(config);

  const PlutoRect first{0, 0, 4, 4};
  const std::vector<std::uint8_t> black_first = uniform_levels(first, 0);
  AdmitRequest cold =
      make_request(first, 7, black_first, 1, kAdmitFlagPenPreview);
  cold.temp_bin = 0;
  ASSERT_TRUE(h.engine.admit(cold));
  h.engine.advance(nullptr);
  ASSERT_EQ(static_cast<int>(h.engine.tile(0, 0).temp_bin), 0);

  const PlutoRect covered{0, 0, 8, 4};
  const std::vector<std::uint8_t> black_covered = uniform_levels(covered, 0);
  AdmitRequest warm =
      make_request(covered, 7, black_covered, 2, kAdmitFlagPenPreview);
  warm.temp_bin = 1;
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(warm, &outcome));
  EXPECT_EQ(outcome.retargeted_tiles, 1u);
  EXPECT_EQ(outcome.parked_tiles, 0u);
  EXPECT_EQ(static_cast<int>(h.engine.tile(0, 0).temp_bin), 1)
      << "covered preview must restart under its explicitly packaged LUT";
}

TEST(PixelEngineTest, FiveHundredTwelvePenSubscribersCompleteWithoutACliff) {
  Harness h;
  h.engine.set_temperature(10.0f);  // mode 7 has two phases
  const PlutoRect rect{0, 0, 8, 8};
  const std::vector<std::uint8_t> black = uniform_levels(rect, 0);

  // One update starts the tile; the rest are value-identical subscribers.
  // This is RegionScheduler's full in-flight request ceiling and used to grow
  // both the Update vector (after 64) and the per-tile subscriber vector on
  // the FIFO engine thread.
  for (std::uint64_t frame_id = 1; frame_id <= 512; ++frame_id) {
    ASSERT_TRUE(h.engine.admit(
        make_request(rect, 7, black, frame_id, kAdmitFlagPenPreview)));
  }
  EXPECT_EQ(h.engine.parked_count(), 0u);

  for (int frame = 0; frame < 4 && !h.engine.idle(); ++frame) {
    h.engine.advance(nullptr);
  }
  EXPECT_TRUE(h.engine.idle());
  EXPECT_EQ(h.completed.size(), 512u);
  EXPECT_EQ(h.engine.stats().completions, 512u);
  EXPECT_TRUE(contains(h.completed, 1));
  EXPECT_TRUE(contains(h.completed, 512));
}

TEST(PixelEngineTest, PenPreviewPreemptsCoveredInFlightTruthAtScanBoundary) {
  PixelEngineConfig config = small_config();
  config.early_cancel_enabled = false;
  Harness h(config);  // mode 2 truth has three phases; mode 7 preview has two

  const PlutoRect stroke{4, 4, 8, 4};
  const std::vector<std::uint8_t> black = uniform_levels(stroke, 0);
  ASSERT_TRUE(h.engine.admit(make_request(stroke, 2, black, 1)));
  h.engine.advance(nullptr);  // quality truth is now physically in flight
  ASSERT_GT(h.engine.total_active_px(), 0u);

  const std::vector<std::uint8_t> white = uniform_levels(stroke, 31);
  AdmitOutcome draw_back;
  ASSERT_TRUE(h.engine.admit(
      make_request(stroke, 7, white, 2, kAdmitFlagPenPreview), &draw_back));
  EXPECT_FALSE(draw_back.budget_deferred);
  EXPECT_EQ(draw_back.parked_tiles, 0u);
  EXPECT_EQ(draw_back.started_tiles, 1u);
  EXPECT_EQ(draw_back.retargeted_tiles, 1u);
  EXPECT_EQ(h.engine.parked_count(), 0u);
  EXPECT_EQ(h.engine.stats().pen_cross_mode_preemptions, 1u);
  EXPECT_EQ(h.engine.dc_ledger().prev_estimated_count(),
            static_cast<std::size_t>(stroke.width * stroke.height));

  for (int i = 0; i < 5 && !h.engine.idle(); ++i) {
    h.engine.advance(nullptr);
  }
  EXPECT_TRUE(h.engine.idle());
  EXPECT_TRUE(contains(h.completed, 1));  // older truth was superseded
  EXPECT_TRUE(contains(h.completed, 2));
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 6, 6), 31);
  EXPECT_EQ(h.engine.dc_ledger().prev_estimated_count(), 0u);
}

// Adversarial warm-handoff shape: a cross-mode pen preview interrupts an
// in-flight quality pass and estimates every active prev at that pass's target
// rail. The replacement changes only one pixel; that pixel runs a completing
// waveform, while all same-target pixels remain estimated with no waveform to
// clear them. The engine eventually becomes idle with a non-zero estimate
// count. A trusted external seed must reset both bitplane and aggregate.
TEST(PixelEngineTest,
     IdleAfterSparsePenPreemptionStillReportsEstimatedGlassPixels) {
  PixelEngineConfig config = small_config();
  config.early_cancel_enabled = false;
  Harness h(config);

  const PlutoRect stroke{4, 4, 8, 4};
  const std::vector<std::uint8_t> black = uniform_levels(stroke, 0);
  ASSERT_TRUE(h.engine.admit(make_request(stroke, 2, black, 1)));
  h.engine.advance(nullptr);
  ASSERT_TRUE(!h.engine.idle());

  std::vector<std::uint8_t> sparse_draw_back = black;
  sparse_draw_back[0] = 31;
  AdmitOutcome preview;
  ASSERT_TRUE(h.engine.admit(
      make_request(stroke, 7, sparse_draw_back, 2, kAdmitFlagPenPreview),
      &preview));
  EXPECT_EQ(preview.retargeted_tiles, 1u);
  EXPECT_EQ(preview.started_tiles, 1u);
  EXPECT_EQ(preview.noop_tiles, 0u);
  EXPECT_FALSE(h.engine.idle());
  EXPECT_EQ(h.engine.dc_ledger().prev_estimated_count(),
            static_cast<std::size_t>(stroke.width * stroke.height));
  while (!h.engine.idle()) {
    h.engine.advance(nullptr);
  }
  EXPECT_TRUE(h.engine.idle());
  EXPECT_EQ(h.engine.parked_count(), 0u);
  EXPECT_EQ(h.engine.dc_ledger().prev_estimated_count(),
            static_cast<std::size_t>(stroke.width * stroke.height - 1));
  for (int y = stroke.y; y < stroke.y + stroke.height; ++y) {
    for (int x = stroke.x; x < stroke.x + stroke.width; ++x) {
      const std::size_t px =
          static_cast<std::size_t>(y) * h.engine.plane_stride() +
          static_cast<std::size_t>(x);
      EXPECT_EQ(h.engine.dc_ledger().prev_estimated(px),
                x != stroke.x || y != stroke.y);
    }
  }

  const std::vector<std::uint8_t> trusted_seed(
      static_cast<std::size_t>(h.engine.config().width) *
          h.engine.config().height,
      30u);
  ASSERT_TRUE(h.engine.seed_prev(trusted_seed.data(), h.engine.config().width,
                                 h.engine.config().height));
  EXPECT_EQ(h.engine.dc_ledger().prev_estimated_count(), 0u);
  for (int y = stroke.y; y < stroke.y + stroke.height; ++y) {
    for (int x = stroke.x; x < stroke.x + stroke.width; ++x) {
      const std::size_t px =
          static_cast<std::size_t>(y) * h.engine.plane_stride() +
          static_cast<std::size_t>(x);
      EXPECT_FALSE(h.engine.dc_ledger().prev_estimated(px));
    }
  }
}

TEST(PixelEngineMappedTest,
     TerminalBuildRetainsTruthAndLocksUntilCorrectTokenIsConfirmed) {
  Harness h;
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear());
  const PlutoRect rect{4, 4, 3, 3};
  const auto operation = prepare_fast_operation(&history, rect, 0);
  const std::uint8_t expected =
      static_cast<std::uint8_t>(operation->lanes()[0].a2 & 31u);
  std::vector<MappedEvent> events;
  h.engine.set_mapped_event_callback(
      [&](const MappedEvent& event) { events.push_back(event); });

  MappedAdmitOutcome admitted;
  ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, operation, 91),
                                    &admitted));
  ASSERT_EQ(admitted.status, MappedAdmitStatus::kStarted);
  ASSERT_NE(admitted.token, 0u);
  EXPECT_FALSE(h.engine.idle());
  EXPECT_FALSE(h.engine.handoff_safe());
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), rect.x, rect.y), 30);
  EXPECT_EQ(plane_at(h.engine, h.engine.next_plane(), rect.x, rect.y),
            expected);

  h.engine.advance(nullptr);
  EXPECT_EQ(events.size(), 0u);
  h.engine.advance(nullptr);
  ASSERT_EQ(events.size(), 1u);
  EXPECT_EQ(events[0].kind, MappedEventKind::kTerminal);
  EXPECT_EQ(events[0].token, admitted.token);
  EXPECT_EQ(h.engine.mapped_active_px(), 0u);
  EXPECT_EQ(h.engine.mapped_pending_count(), 1u);
  EXPECT_FALSE(h.engine.idle());
  // A terminal BUILD is not a scan latch and must not promote prev.
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), rect.x, rect.y), 30);
  EXPECT_EQ(h.engine.confirm_mapped(admitted.token + 1),
            MappedFinalizeStatus::kUnknownToken);
  EXPECT_EQ(h.engine.confirm_mapped(admitted.token),
            MappedFinalizeStatus::kConfirmed);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), rect.x, rect.y),
            expected);
  EXPECT_TRUE(h.engine.idle());
  EXPECT_TRUE(h.engine.handoff_safe());
  EXPECT_TRUE(contains(h.completed, 91));
  EXPECT_EQ(h.engine.confirm_mapped(admitted.token),
            MappedFinalizeStatus::kUnknownToken);
  const auto committed = history.pixel(rect.x, rect.y);
  ASSERT_TRUE(committed.has_value());
  EXPECT_EQ(committed->a & 31u, expected);
}

TEST(PixelEngineMappedTest,
     DiscardIsPreScanOnlyAndDiscardedJournalCannotBeReadmitted) {
  Harness h;
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear());
  const auto operation =
      prepare_fast_operation(&history, PlutoRect{0, 0, 8, 2}, 0);
  MappedAdmitOutcome admitted;
  ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, operation),
                                    &admitted));
  EXPECT_EQ(h.engine.discard_mapped(admitted.token),
            MappedFinalizeStatus::kDiscarded);
  EXPECT_EQ(history.outstanding_count(), 0u);
  EXPECT_FALSE(h.engine.admit_mapped(mapped_request(&history, operation)));

  const auto scanned =
      prepare_fast_operation(&history, PlutoRect{16, 0, 8, 2}, 0);
  ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, scanned),
                                    &admitted));
  h.engine.advance(nullptr);
  EXPECT_EQ(h.engine.discard_mapped(admitted.token),
            MappedFinalizeStatus::kAlreadyScanned);
}

TEST(PixelEngineMappedTest, ForeignHistoryOwnerIsRejectedBeforeAnyDrive) {
  Harness h;
  XochitlHistoryState owner;
  XochitlHistoryState foreign;
  ASSERT_TRUE(owner.initialize_cold_clear());
  ASSERT_TRUE(foreign.initialize_cold_clear());
  const auto operation =
      prepare_fast_operation(&owner, PlutoRect{0, 0, 8, 2}, 0);
  EXPECT_FALSE(h.engine.admit_mapped(mapped_request(&foreign, operation)));
  EXPECT_EQ(h.engine.mapped_pending_count(), 0u);
  EXPECT_EQ(owner.outstanding_count(), 1u);
  EXPECT_EQ(owner.discard(*operation),
            XochitlHistoryState::FinalizeStatus::kDiscarded);
}

TEST(PixelEngineMappedTest,
     FullCoverageSupersedesUnstartedButPartialCoverageRejectsCandidate) {
  {
    Harness h;
    XochitlHistoryState history;
    ASSERT_TRUE(history.initialize_cold_clear());
    const auto old =
        prepare_fast_operation(&history, PlutoRect{4, 0, 4, 2}, 0);
    const auto newest =
        prepare_fast_operation(&history, PlutoRect{0, 0, 16, 2}, 7);
    MappedAdmitOutcome old_outcome;
    ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, old, 1),
                                      &old_outcome));
    MappedAdmitOutcome newest_outcome;
    ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, newest, 2),
                                      &newest_outcome));
    EXPECT_EQ(newest_outcome.status, MappedAdmitStatus::kStarted);
    EXPECT_EQ(newest_outcome.superseded_unstarted, 1u);
    EXPECT_EQ(h.engine.confirm_mapped(old_outcome.token),
              MappedFinalizeStatus::kUnknownToken);
  }
  {
    Harness h;
    XochitlHistoryState history;
    ASSERT_TRUE(history.initialize_cold_clear());
    const auto old =
        prepare_fast_operation(&history, PlutoRect{0, 0, 8, 2}, 0);
    const auto partial =
        prepare_fast_operation(&history, PlutoRect{4, 0, 8, 2}, 7);
    MappedAdmitOutcome old_outcome;
    ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, old, 1),
                                      &old_outcome));
    MappedAdmitOutcome partial_outcome;
    EXPECT_FALSE(h.engine.admit_mapped(
        mapped_request(&history, partial, 2), &partial_outcome));
    EXPECT_EQ(partial_outcome.status, MappedAdmitStatus::kConflictPartial);
    EXPECT_EQ(h.engine.mapped_pending_count(), 1u);
    EXPECT_EQ(h.engine.stats().mapped_unstarted_superseded, 0u);
    EXPECT_FALSE(contains(h.completed, 1));
    EXPECT_FALSE(contains(h.completed, 2));
  }
}

TEST(PixelEngineMappedTest,
     SameTileDisjointRegionsSerializeButSharedHistoryStampReprepares) {
  {
    Harness h;
    XochitlHistoryState history;
    ASSERT_TRUE(history.initialize_cold_clear());
    const auto left =
        prepare_fast_operation(&history, PlutoRect{0, 0, 1, 1}, 0);
    const auto right =
        prepare_fast_operation(&history, PlutoRect{16, 0, 1, 1}, 7);
    MappedAdmitOutcome a;
    MappedAdmitOutcome b;
    ASSERT_TRUE(
        h.engine.admit_mapped(mapped_request(&history, left), &a));
    ASSERT_TRUE(
        h.engine.admit_mapped(mapped_request(&history, right), &b));
    EXPECT_EQ(a.status, MappedAdmitStatus::kStarted);
    EXPECT_EQ(b.status, MappedAdmitStatus::kQueued);
    EXPECT_EQ(h.engine.stats().mapped_unstarted_superseded, 0u);
    h.engine.advance(nullptr);
    h.engine.advance(nullptr);
    ASSERT_EQ(h.engine.confirm_mapped(a.token),
              MappedFinalizeStatus::kConfirmed);
    EXPECT_EQ(h.engine.mapped_active_px(), 16u);
    h.engine.advance(nullptr);
    h.engine.advance(nullptr);
    EXPECT_EQ(h.engine.confirm_mapped(b.token),
              MappedFinalizeStatus::kConfirmed);
  }
  {
    Harness h;
    XochitlHistoryState history;
    ASSERT_TRUE(history.initialize_cold_clear());
    // Pixel-disjoint execution [1..8] and [9..16], but both touch history's
    // conservative x=8..15 version tile.
    const auto aop =
        prepare_fast_operation(&history, PlutoRect{1, 0, 1, 1}, 0);
    const auto bop =
        prepare_fast_operation(&history, PlutoRect{9, 0, 1, 1}, 7);
    ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, aop)));
    MappedAdmitOutcome b;
    EXPECT_FALSE(
        h.engine.admit_mapped(mapped_request(&history, bop), &b));
    EXPECT_EQ(b.status, MappedAdmitStatus::kConflictHistoryRegion);
    EXPECT_EQ(h.engine.mapped_pending_count(), 1u);
  }
}

TEST(PixelEngineMappedTest, IdentityTransitionsRemainActiveAndEmitEveryLane) {
  Harness h;
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear());
  const PlutoRect rect{0, 0, 8, 2};
  std::vector<std::uint8_t> raw(16, 0);
  raw[3] = 11;  // mode-2 palette logical 30 amid non-white neighbours
  const auto operation = prepare_legacy_operation(&history, rect, raw);
  std::size_t identity = operation->lanes().size();
  for (std::size_t i = 0; i < operation->lanes().size(); ++i) {
    const std::uint16_t transition = operation->lanes()[i].transition;
    if (((transition >> 5) & 31u) == (transition & 31u)) {
      identity = i;
      break;
    }
  }
  ASSERT_NE(identity, operation->lanes().size());
  ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, operation)));
  CaptureEmitter emitter;
  h.engine.advance(&emitter);
  EXPECT_EQ(emitter.total_ops(), 16u);
  const int identity_x = static_cast<int>(identity % 8u);
  const int identity_y = static_cast<int>(identity / 8u);
  EXPECT_NE(emitter.code_at(identity_y, identity_x), -1);
}

TEST(PixelEngineMappedTest, SparseMaskEmitsAndCommitsOnlySelectedLanes) {
  Harness h;
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear(10));
  const PlutoRect tile{0, 0, 32, 32};
  std::vector<std::uint8_t> raw(32u * 32u, 3u);
  std::vector<std::uint8_t> mask(raw.size(), 0u);
  const std::array<std::pair<int, int>, 3> selected = {
      std::pair{1, 1}, std::pair{7, 3}, std::pair{20, 20}};
  for (const auto& [x, y] : selected) {
    mask[static_cast<std::size_t>(y) * 32u + x] = 1u;
  }
  const auto hole_before = history.pixel(2, 1);
  ASSERT_TRUE(hole_before.has_value());
  const auto operation =
      prepare_legacy_operation(&history, tile, raw, mask);
  ASSERT_TRUE(operation->masked());
  EXPECT_EQ(std::count(operation->lane_mask().begin(),
                       operation->lane_mask().end(), 1u),
            3);

  MappedAdmitOutcome admitted;
  ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, operation, 71),
                                    &admitted));
  EXPECT_EQ(h.engine.mapped_active_px(), 3u);
  CaptureEmitter emitter;
  for (int phase = 0; phase < 4; ++phase) {
    h.engine.advance(&emitter);
  }
  EXPECT_GT(emitter.total_ops(), 0u);
  for (const CaptureEmitter::RowCapture& row : emitter.rows) {
    for (const PixelOp& op : row.ops) {
      EXPECT_TRUE(std::find(selected.begin(), selected.end(),
                            std::pair<int, int>{static_cast<int>(op.x),
                                                row.row}) != selected.end())
          << "unexpected mapped op at " << op.x << ',' << row.row;
    }
  }
  for (const auto& [x, y] : selected) {
    EXPECT_NE(emitter.code_at(y, x), -1);
  }
  EXPECT_EQ(h.engine.mapped_active_px(), 0u);
  EXPECT_EQ(h.engine.confirm_mapped(admitted.token),
            MappedFinalizeStatus::kConfirmed);
  const auto hole_after = history.pixel(2, 1);
  ASSERT_TRUE(hole_after.has_value());
  EXPECT_EQ(hole_after->a, hole_before->a);
  EXPECT_EQ(hole_after->b, hole_before->b);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 2, 1), 30u);
  for (const auto& [x, y] : selected) {
    const auto committed = history.pixel(x, y);
    ASSERT_TRUE(committed.has_value());
    EXPECT_TRUE(committed->a != hole_before->a ||
                committed->b != hole_before->b);
  }
  EXPECT_TRUE(contains(h.completed, 71));
}

TEST(PixelEngineMappedTest,
     SparseCandidateCannotSupersedeDifferentLaneInSameExecution) {
  Harness h;
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear(10));
  const PlutoRect tile{0, 0, 32, 32};
  const std::vector<std::uint8_t> raw(32u * 32u, 3u);
  std::vector<std::uint8_t> old_mask(raw.size(), 0u);
  std::vector<std::uint8_t> newest_mask(raw.size(), 0u);
  old_mask[1u * 32u + 1u] = 1u;
  newest_mask[1u * 32u + 2u] = 1u;
  const auto old =
      prepare_legacy_operation(&history, tile, raw, old_mask);
  const auto newest =
      prepare_legacy_operation(&history, tile, raw, newest_mask);

  MappedAdmitOutcome old_outcome;
  ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, old, 1),
                                    &old_outcome));
  MappedAdmitOutcome newest_outcome;
  EXPECT_FALSE(h.engine.admit_mapped(mapped_request(&history, newest, 2),
                                     &newest_outcome));
  EXPECT_EQ(newest_outcome.status, MappedAdmitStatus::kConflictPartial);
  EXPECT_EQ(h.engine.mapped_pending_count(), 1u);
  EXPECT_EQ(h.engine.stats().mapped_unstarted_superseded, 0u);
  EXPECT_EQ(history.outstanding_count(), 1u);
}

TEST(PixelEngineSafeFastTest,
     RailRebaseDrivesArbitrarySourcesThroughCertifiedCrossingsAndFencesLatch) {
  SafeFastHarness h;
  const PlutoRect rect{0, 0, 6, 1};
  std::vector<std::uint8_t> seed(
      static_cast<std::size_t>(h.engine.config().width) *
          h.engine.config().height,
      2);
  const std::array<std::uint8_t, 6> sources{11, 11, 27, 27, 30, 30};
  const std::array<std::uint8_t, 6> targets{2, 28, 2, 28, 2, 28};
  for (std::size_t i = 0; i < sources.size(); ++i) {
    seed[i] = sources[i];
  }
  ASSERT_TRUE(h.engine.seed_prev(seed.data(), h.engine.config().width,
                                 h.engine.config().height));
  const std::vector<std::uint8_t> levels(targets.begin(), targets.end());
  auto coverage = std::make_shared<FastCoverage>(rect);
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(
      make_safe_fast_request(rect, levels, 700, coverage), &outcome));
  EXPECT_EQ(outcome.started_tiles, 1u);
  EXPECT_EQ(coverage->driven_count(), 0u);
  for (std::size_t i = 0; i < targets.size(); ++i) {
    const std::uint8_t opposite =
        targets[i] == pluto::swtcon::kMode7FastBlackEndpoint
            ? pluto::swtcon::kMode7FastWhiteEndpoint
            : pluto::swtcon::kMode7FastBlackEndpoint;
    EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), static_cast<int>(i), 0),
              opposite);
  }

  CaptureEmitter emitter;
  for (int phase = 0; phase < 11; ++phase) {
    emitter.clear();
    h.engine.advance(&emitter);
    EXPECT_EQ(emitter.total_ops(), targets.size());
    for (std::size_t i = 0; i < targets.size(); ++i) {
      const int expected =
          phase == 10 ? 0 : targets[i] == 2 ? 6 : 1;
      EXPECT_EQ(emitter.code_at(0, static_cast<int>(i)), expected)
          << "phase=" << phase << " lane=" << i;
    }
    if (phase < 10) {
      EXPECT_TRUE(coverage->empty());
    }
  }
  EXPECT_EQ(coverage->driven_count(), targets.size());
  EXPECT_TRUE(contains(h.completed, 700));
  EXPECT_EQ(h.engine.dc_ledger().prev_estimated_count(), targets.size());
  EXPECT_FALSE(h.engine.handoff_safe());

  const std::array<std::uint8_t, 1> first_half{0x07};
  ASSERT_TRUE(
      h.engine.confirm_safe_fast_latched(*coverage, first_half, 1));
  EXPECT_EQ(h.engine.dc_ledger().prev_estimated_count(), 3u);
  const std::array<std::uint8_t, 1> second_half{0x38};
  ASSERT_TRUE(
      h.engine.confirm_safe_fast_latched(*coverage, second_half, 1));
  EXPECT_EQ(h.engine.dc_ledger().prev_estimated_count(), 0u);
  EXPECT_TRUE(h.engine.handoff_safe());
}

TEST(PixelEngineSafeFastTest,
     ExactEndpointNoopStaysEmptyButEstimatedSameEndpointRebases) {
  SafeFastHarness h;
  const PlutoRect rect{0, 0, 1, 1};
  std::vector<std::uint8_t> seed(
      static_cast<std::size_t>(h.engine.config().width) *
          h.engine.config().height,
      2);
  ASSERT_TRUE(h.engine.seed_prev(seed.data(), h.engine.config().width,
                                 h.engine.config().height));
  const std::vector<std::uint8_t> black{2};
  auto noop = std::make_shared<FastCoverage>(rect);
  AdmitOutcome noop_outcome;
  ASSERT_TRUE(h.engine.admit(
      make_safe_fast_request(rect, black, 701, noop), &noop_outcome));
  EXPECT_EQ(noop_outcome.noop_tiles, 1u);
  EXPECT_TRUE(noop->empty());
  EXPECT_TRUE(contains(h.completed, 701));

  h.engine.dc_ledger().mark_prev_estimated(0);
  auto recovery = std::make_shared<FastCoverage>(rect);
  AdmitOutcome recovery_outcome;
  ASSERT_TRUE(h.engine.admit(
      make_safe_fast_request(rect, black, 702, recovery), &recovery_outcome));
  EXPECT_EQ(recovery_outcome.started_tiles, 1u);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 0, 0), 28);
  for (int phase = 0; phase < 11; ++phase) {
    h.engine.advance(nullptr);
  }
  EXPECT_TRUE(recovery->driven(0, 0));
  EXPECT_TRUE(h.engine.dc_ledger().prev_estimated(0));
  ASSERT_TRUE(h.engine.confirm_safe_fast_latched(
      *recovery, recovery->bits(), recovery->stride_bytes()));
  EXPECT_FALSE(h.engine.dc_ledger().prev_estimated(0));
}

TEST(PixelEngineSafeFastTest,
     ActiveTileFreshIdleLaneRebasesAndLateSubscriberInheritsDrive) {
  SafeFastHarness h;
  std::vector<std::uint8_t> seed(
      static_cast<std::size_t>(h.engine.config().width) *
          h.engine.config().height,
      2);
  seed[1] = 11;
  ASSERT_TRUE(h.engine.seed_prev(seed.data(), h.engine.config().width,
                                 h.engine.config().height));
  auto first = std::make_shared<FastCoverage>(PlutoRect{0, 0, 1, 1});
  const std::vector<std::uint8_t> white{28};
  ASSERT_TRUE(h.engine.admit(make_safe_fast_request(
      {0, 0, 1, 1}, white, 703, first)));

  auto fresh = std::make_shared<FastCoverage>(PlutoRect{1, 0, 1, 1});
  const std::vector<std::uint8_t> black{2};
  AdmitOutcome fresh_outcome;
  ASSERT_TRUE(h.engine.admit(make_safe_fast_request(
      {1, 0, 1, 1}, black, 704, fresh), &fresh_outcome));
  EXPECT_EQ(fresh_outcome.retargeted_tiles, 1u);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 1, 0), 28);

  for (int phase = 0; phase < 10; ++phase) {
    h.engine.advance(nullptr);
  }
  auto late = std::make_shared<FastCoverage>(PlutoRect{0, 0, 1, 1});
  AdmitOutcome late_outcome;
  ASSERT_TRUE(h.engine.admit(make_safe_fast_request(
      {0, 0, 1, 1}, white, 705, late), &late_outcome));
  EXPECT_EQ(late_outcome.absorbed_tiles, 1u);
  EXPECT_TRUE(late->empty());

  CaptureEmitter terminal;
  h.engine.advance(&terminal);
  EXPECT_EQ(terminal.code_at(0, 0), 0);
  EXPECT_EQ(terminal.code_at(0, 1), 0);
  EXPECT_TRUE(first->driven(0, 0));
  EXPECT_TRUE(fresh->driven(1, 0));
  EXPECT_TRUE(late->driven(0, 0));
}

TEST(PixelEngineSafeFastTest,
     OlderLatchNeverClearsNewerSameOrOppositeRecoveryGeneration) {
  for (const std::uint8_t newer_target : {std::uint8_t{28},
                                          std::uint8_t{2}}) {
    SafeFastHarness h;
    const PlutoRect rect{0, 0, 1, 1};
    std::vector<std::uint8_t> seed(
        static_cast<std::size_t>(h.engine.config().width) *
            h.engine.config().height,
        11);
    ASSERT_TRUE(h.engine.seed_prev(seed.data(), h.engine.config().width,
                                   h.engine.config().height));
    const std::vector<std::uint8_t> first_target{28};
    auto first = std::make_shared<FastCoverage>(rect);
    ASSERT_TRUE(h.engine.admit(
        make_safe_fast_request(rect, first_target, 710, first)));
    for (int phase = 0; phase < 11; ++phase) {
      h.engine.advance(nullptr);
    }
    ASSERT_TRUE(first->driven(0, 0));
    ASSERT_NE(first->recovery_generation(0, 0), 0u);
    EXPECT_TRUE(h.engine.dc_ledger().prev_estimated(0));

    const std::vector<std::uint8_t> second_target{newer_target};
    auto second = std::make_shared<FastCoverage>(rect);
    ASSERT_TRUE(h.engine.admit(
        make_safe_fast_request(rect, second_target, 711, second)));
    // Positive feedback for the older terminal is valid, but generation
    // ownership has moved to the newer active recovery. It must neither fail
    // nor clear that newer optical fence.
    ASSERT_TRUE(h.engine.confirm_safe_fast_latched(
        *first, first->bits(), first->stride_bytes()));
    EXPECT_TRUE(h.engine.dc_ledger().prev_estimated(0));

    for (int phase = 0; phase < 11; ++phase) {
      h.engine.advance(nullptr);
    }
    ASSERT_TRUE(second->driven(0, 0));
    EXPECT_NE(second->recovery_generation(0, 0),
              first->recovery_generation(0, 0));
    ASSERT_TRUE(h.engine.confirm_safe_fast_latched(
        *first, first->bits(), first->stride_bytes()));
    EXPECT_TRUE(h.engine.dc_ledger().prev_estimated(0));
    ASSERT_TRUE(h.engine.confirm_safe_fast_latched(
        *second, second->bits(), second->stride_bytes()));
    EXPECT_FALSE(h.engine.dc_ledger().prev_estimated(0));
  }
}

TEST(PixelEngineSafeFastTest,
     MappedClaimsParkSafeFastWithoutInvalidationOrDiscard) {
  SafeFastHarness h;
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear());
  const PlutoRect rect{0, 0, 8, 2};
  const auto operation = prepare_fast_operation(&history, rect, 0);
  std::vector<MappedEvent> events;
  h.engine.set_mapped_event_callback(
      [&](const MappedEvent& event) { events.push_back(event); });
  MappedAdmitOutcome mapped;
  ASSERT_TRUE(h.engine.admit_mapped(
      mapped_request(&history, operation, 706), &mapped));

  auto coverage = std::make_shared<FastCoverage>(rect);
  const std::vector<std::uint8_t> black(
      static_cast<std::size_t>(rect.width * rect.height), 2);
  AdmitOutcome fast;
  ASSERT_TRUE(h.engine.admit(
      make_safe_fast_request(rect, black, 707, coverage), &fast));
  EXPECT_EQ(fast.parked_tiles, 1u);
  EXPECT_EQ(fast.mapped_recovery_token, 0u);
  EXPECT_FALSE(fast.mapped_reconcile_required);
  EXPECT_TRUE(history.valid());
  EXPECT_TRUE(history.admissible(*operation));
  EXPECT_EQ(h.engine.mapped_pending_count(), 1u);
  EXPECT_TRUE(events.empty());
  EXPECT_TRUE(coverage->empty());
}

TEST(PixelEngineMappedTest,
     MvccStaleQueuedDiscardCarriesRetryReasonAndNoCompletion) {
  SafeFastHarness h;
  const PlutoRect rect{0, 0, 8, 2};
  const std::vector<std::uint8_t> legacy_levels(16, 0);
  ASSERT_TRUE(h.engine.admit(make_request(rect, 2, legacy_levels, 708)));

  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear());
  const auto operation = prepare_fast_operation(&history, rect, 0);
  std::vector<MappedEvent> events;
  h.engine.set_mapped_event_callback(
      [&](const MappedEvent& event) { events.push_back(event); });
  MappedAdmitOutcome admitted;
  ASSERT_TRUE(h.engine.admit_mapped(
      mapped_request(&history, operation, 709, false, 991), &admitted));
  ASSERT_EQ(admitted.status, MappedAdmitStatus::kQueued);

  const std::array<std::uint8_t, 16> raw{};
  const std::array<std::uint8_t, 2> driven{0xff, 0xff};
  ASSERT_TRUE(history.reseed_fast_region_from_raw(
      {0, 0, 7, 1}, {0, 0, 7, 1}, raw, 8, driven, 1));
  h.engine.advance(nullptr);
  ASSERT_TRUE(!events.empty());
  const MappedEvent& stale = events.back();
  EXPECT_EQ(stale.kind, MappedEventKind::kDiscarded);
  EXPECT_EQ(stale.discard_reason,
            MappedDiscardReason::kStaleAfterMvccSeed);
  EXPECT_EQ(stale.retry_cookie, 991u);
  EXPECT_EQ(stale.frame_id, 709u);
  EXPECT_FALSE(contains(h.completed, 709));
}

// Retired emergency owner-wide preemption scenarios. Generic PenPreview has
// no route to this unsafe policy; production Fast parks on mapped claims and
// uses masked MVCC reseed after a separately proven latch.
#if 0
TEST(PixelEngineMappedTest,
     ScannedMappedCollisionLetsPenFastRunAndRequiresRegionalReseed) {
  Harness h;
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear());
  const PlutoRect rect{0, 0, 8, 2};
  const auto operation = prepare_fast_operation(&history, rect, 0);
  std::vector<MappedEvent> events;
  h.engine.set_mapped_event_callback(
      [&](const MappedEvent& event) { events.push_back(event); });
  MappedAdmitOutcome mapped;
  ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, operation),
                                    &mapped));
  h.engine.advance(nullptr);  // a mapped prefix has been built

  const std::vector<std::uint8_t> fast = uniform_levels(rect, 28);
  AdmitOutcome fast_outcome;
  ASSERT_TRUE(h.engine.admit(
      make_request(rect, 7, fast, 72, kAdmitFlagPenPreview), &fast_outcome));
  EXPECT_TRUE(fast_outcome.mapped_reconcile_required);
  ASSERT_NE(fast_outcome.mapped_recovery_token, 0u);
  EXPECT_EQ(fast_outcome.mapped_conflicts, 1u);
  EXPECT_EQ(fast_outcome.parked_tiles, 0u);
  EXPECT_EQ(h.engine.mapped_pending_count(), 0u);
  EXPECT_TRUE(h.engine.mapped_reconcile_required());
  ASSERT_EQ(h.engine.mapped_poison_regions().size(), 1u);
  EXPECT_TRUE(h.engine.mapped_poison_regions()[0].regional_reseed_allowed);
  ASSERT_TRUE(!events.empty());
  EXPECT_EQ(events.back().kind, MappedEventKind::kInvalidatedForReseed);
  // Emergency source is a conservative mapped terminal-drive approximation,
  // explicitly estimated until the covering Fast terminal scan and reseed.
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 0, 0),
            operation->lanes()[0].transition & 31u);
  EXPECT_TRUE(h.engine.dc_ledger().prev_estimated(0));
  EXPECT_FALSE(history.valid());

  h.engine.advance(nullptr);
  h.engine.advance(nullptr);
  ASSERT_TRUE(contains(h.completed, 72));
  ASSERT_TRUE(h.engine.confirm_fast_recovery_latched(
      fast_outcome.mapped_recovery_token));
  std::vector<std::uint8_t> endpoint(16, 28);
  ASSERT_TRUE(history.reseed_region_from_levels(
      {0, 0, 7, 1}, endpoint, 8));
  ASSERT_TRUE(h.engine.resolve_mapped_invalidation_after_reseed(
      &history, {0, 0, 7, 1}, fast_outcome.mapped_recovery_token));
  EXPECT_EQ(h.engine.mapped_poison_regions().size(), 0u);
  // The invalidation remains handoff-unsafe until freshly prepared mapped
  // truth commits, even though regional history is now valid.
  EXPECT_TRUE(h.engine.mapped_reconcile_required());
  const auto truth = prepare_fast_operation(&history, rect, 7);
  MappedAdmitRequest truth_request = mapped_request(
      &history, truth, 73, true, 0, fast_outcome.mapped_recovery_token);
  MappedAdmitOutcome truth_outcome;
  ASSERT_TRUE(h.engine.admit_mapped(truth_request, &truth_outcome));
  h.engine.advance(nullptr);
  h.engine.advance(nullptr);
  ASSERT_EQ(h.engine.confirm_mapped(truth_outcome.token),
            MappedFinalizeStatus::kConfirmed);
  EXPECT_FALSE(h.engine.mapped_reconcile_required());
  EXPECT_TRUE(h.engine.idle());
}

TEST(PixelEngineMappedTest,
     PenFastDetectsRoundedExecutionHaloBeforeFirstMappedPhase) {
  Harness h;
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear());
  const auto operation =
      prepare_fast_operation(&history, PlutoRect{0, 0, 1, 1}, 0);
  ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, operation)));
  const PlutoRect halo{7, 0, 1, 1};  // outside requested, inside exec 0..7
  const std::vector<std::uint8_t> levels = uniform_levels(halo, 2);
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(
      make_request(halo, 7, levels, 80, kAdmitFlagPenPreview), &outcome));
  EXPECT_EQ(outcome.mapped_conflicts, 1u);
  EXPECT_TRUE(outcome.mapped_reconcile_required);
  EXPECT_NE(outcome.mapped_recovery_token, 0u);
  EXPECT_EQ(outcome.parked_tiles, 0u);
  EXPECT_EQ(h.engine.mapped_pending_count(), 0u);
  EXPECT_FALSE(history.valid());
  EXPECT_EQ(h.engine.mapped_poison_regions().size(), 1u);
}

TEST(PixelEngineMappedTest, SafePenFastParkCounterIsMappedSpecific) {
  Harness h;
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear());
  const PlutoRect truth_rect{0, 0, 8, 2};
  const auto operation = prepare_fast_operation(&history, truth_rect, 0);
  ASSERT_TRUE(h.engine.admit_mapped(
      mapped_request(&history, operation, 901, false, 0x901u)));

  const std::vector<std::uint8_t> levels = uniform_levels(truth_rect, 28);
  AdmitOutcome outcome;
  AdmitRequest request =
      make_request(truth_rect, 7, levels, 902, kAdmitFlagPenPreview);
  request.flags |= kAdmitFlagNoMappedInvalidation |
                   kAdmitFlagFastRailRebase;
  FastCoverage coverage;
  ASSERT_TRUE(coverage.configure(truth_rect));
  request.fast_coverage = &coverage;
  ASSERT_TRUE(h.engine.admit(request, &outcome));
  EXPECT_GT(outcome.parked_tiles, 0u);
  EXPECT_EQ(h.engine.stats().mapped_fast_parks, outcome.parked_tiles);

  const PlutoRect disjoint{32, 0, 8, 2};
  const std::vector<std::uint8_t> disjoint_levels =
      uniform_levels(disjoint, 28);
  AdmitOutcome disjoint_outcome;
  AdmitRequest disjoint_request = make_request(
      disjoint, 7, disjoint_levels, 903, kAdmitFlagPenPreview);
  disjoint_request.flags |= kAdmitFlagNoMappedInvalidation |
                            kAdmitFlagFastRailRebase;
  FastCoverage disjoint_coverage;
  ASSERT_TRUE(disjoint_coverage.configure(disjoint));
  disjoint_request.fast_coverage = &disjoint_coverage;
  ASSERT_TRUE(h.engine.admit(disjoint_request, &disjoint_outcome));
  EXPECT_EQ(disjoint_outcome.parked_tiles, 0u);
  EXPECT_EQ(h.engine.stats().mapped_fast_parks, outcome.parked_tiles);
}

TEST(PixelEngineMappedTest,
     PartialFastDisplacementReturnsRetryIdentityAndNeverCompletesTruth) {
  Harness h;
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear());
  const PlutoRect truth_rect{0, 0, 16, 2};
  const auto operation = prepare_fast_operation(&history, truth_rect, 0);
  std::vector<MappedEvent> events;
  h.engine.set_mapped_event_callback(
      [&](const MappedEvent& event) { events.push_back(event); });
  ASSERT_TRUE(h.engine.admit_mapped(
      mapped_request(&history, operation, 501, false, 0xabcdu)));
  const PlutoRect fast_rect{0, 0, 8, 2};
  const std::vector<std::uint8_t> levels = uniform_levels(fast_rect, 28);
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(make_request(fast_rect, 7, levels, 502,
                                          kAdmitFlagPenPreview),
                             &outcome));
  ASSERT_EQ(events.size(), 1u);
  const MappedEvent& displaced = events[0];
  EXPECT_EQ(displaced.kind, MappedEventKind::kDisplacedForFast);
  EXPECT_EQ(displaced.frame_id, 501u);
  EXPECT_EQ(displaced.retry_cookie, 0xabcdu);
  EXPECT_EQ(displaced.recovery_token, outcome.mapped_recovery_token);
  EXPECT_EQ(displaced.requested.left, 0);
  EXPECT_EQ(displaced.requested.right, 15);
  EXPECT_EQ(displaced.execution.right, 15);
  EXPECT_FALSE(displaced.scanned);
  EXPECT_TRUE(displaced.reseed_required);
  EXPECT_FALSE(contains(h.completed, 501));
  EXPECT_FALSE(h.engine.confirm_fast_recovery_latched(
      outcome.mapped_recovery_token + 1));
  EXPECT_FALSE(h.engine.confirm_fast_recovery_latched(
      outcome.mapped_recovery_token));
  h.engine.advance(nullptr);
  h.engine.advance(nullptr);
  EXPECT_FALSE(contains(h.completed, 501));
  EXPECT_TRUE(contains(h.completed, 502));

  // A missing event callback changes no safety/completion semantics.
  Harness no_callback;
  XochitlHistoryState second_history;
  ASSERT_TRUE(second_history.initialize_cold_clear());
  const auto second =
      prepare_fast_operation(&second_history, truth_rect, 0);
  ASSERT_TRUE(no_callback.engine.admit_mapped(
      mapped_request(&second_history, second, 601, false, 0xdef0u)));
  AdmitOutcome second_outcome;
  ASSERT_TRUE(no_callback.engine.admit(
      make_request(fast_rect, 7, levels, 602, kAdmitFlagPenPreview),
      &second_outcome));
  EXPECT_NE(second_outcome.mapped_recovery_token, 0u);
  EXPECT_FALSE(contains(no_callback.completed, 601));
}

TEST(PixelEngineMappedTest,
     PartialEmergencyFastCannotResolveUntilWholePoisonExecutionIsKnown) {
  Harness h;
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear());
  const PlutoRect truth_rect{0, 0, 16, 2};
  const auto operation = prepare_fast_operation(&history, truth_rect, 0);
  ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, operation)));
  h.engine.advance(nullptr);

  const PlutoRect small_fast{0, 0, 8, 2};
  const std::vector<std::uint8_t> small_levels =
      uniform_levels(small_fast, 28);
  AdmitOutcome small_outcome;
  ASSERT_TRUE(h.engine.admit(make_request(small_fast, 7, small_levels, 1,
                                          kAdmitFlagPenPreview),
                             &small_outcome));
  ASSERT_NE(small_outcome.mapped_recovery_token, 0u);
  h.engine.advance(nullptr);
  h.engine.advance(nullptr);
  ASSERT_TRUE(h.engine.confirm_fast_recovery_latched(
      small_outcome.mapped_recovery_token));
  const std::vector<std::uint8_t> small_endpoint(16, 28);
  ASSERT_TRUE(history.reseed_region_from_levels(
      {0, 0, 7, 1}, small_endpoint, 8));
  EXPECT_FALSE(h.engine.resolve_mapped_invalidation_after_reseed(
      &history, {0, 0, 7, 1}, small_outcome.mapped_recovery_token));
  ASSERT_EQ(h.engine.mapped_poison_regions().size(), 2u);
  int poison_right = -1;
  for (const auto& poison : h.engine.mapped_poison_regions()) {
    poison_right = std::max(poison_right, poison.execution.right);
  }
  EXPECT_EQ(poison_right, 15);

  // The recoverable event's execution is the bounded expansion corridor.
  // Drive every poisoned lane to a known Fast endpoint before reseeding A/B.
  const std::vector<std::uint8_t> expanded_levels =
      uniform_levels(truth_rect, 28);
  AdmitOutcome expanded_outcome;
  ASSERT_TRUE(h.engine.admit(make_request(truth_rect, 7, expanded_levels, 2,
                                          kAdmitFlagPenPreview),
                             &expanded_outcome));
  EXPECT_EQ(expanded_outcome.mapped_recovery_token,
            small_outcome.mapped_recovery_token);
  h.engine.advance(nullptr);
  h.engine.advance(nullptr);
  ASSERT_TRUE(h.engine.confirm_fast_recovery_latched(
      expanded_outcome.mapped_recovery_token));
  const std::vector<std::uint8_t> expanded_endpoint(32, 28);
  ASSERT_TRUE(history.reseed_region_from_levels(
      {0, 0, 15, 1}, expanded_endpoint, 16));
  EXPECT_TRUE(h.engine.resolve_mapped_invalidation_after_reseed(
      &history, {0, 0, 15, 1}, small_outcome.mapped_recovery_token));
  EXPECT_EQ(h.engine.mapped_poison_regions().size(), 0u);
}

TEST(PixelEngineMappedTest,
     EmergencyFastEstimateUsesAuxiliaryDrive27And31AsWaveformSource) {
  {
    Harness h;
    XochitlHistoryState history;
    ASSERT_TRUE(history.initialize_cold_clear());
    const PlutoRect rect{0, 0, 8, 2};
    const std::vector<std::uint8_t> raw(16, 11);  // equal9 => force27
    const auto operation = prepare_legacy_operation(&history, rect, raw);
    ASSERT_EQ(operation->lanes()[0].transition & 31u, 27u);
    ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, operation)));
    h.engine.advance(nullptr);
    const std::vector<std::uint8_t> fast = uniform_levels(rect, 2);
    ASSERT_TRUE(h.engine.admit(make_request(rect, 7, fast, 1,
                                            kAdmitFlagPenPreview)));
    EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 0, 0), 27u);
    EXPECT_TRUE(h.engine.dc_ledger().prev_estimated(0));
  }
  {
    Harness h;
    XochitlHistoryState history;
    std::vector<XochitlHistoryState::HistoryPixel> seed(
        XochitlHistoryState::kStoragePixels,
        XochitlHistoryState::HistoryPixel{0x9eu, 0});
    const PlutoRect rect{8, 8, 8, 2};
    // Center local(3,0) has one low old cross neighbour, while every new raw
    // lane is marked high-white: white-continuity pair31.
    seed[static_cast<std::size_t>(rect.y) *
             XochitlHistoryState::kStorageStride +
         static_cast<std::size_t>(rect.x + 2)] = {0x82u, 0};
    ASSERT_TRUE(history.seed_full_plane(seed));
    const std::vector<std::uint8_t> raw(16, 0x8b);
    const auto operation = prepare_legacy_operation(&history, rect, raw);
    std::size_t pair31 = operation->lanes().size();
    for (std::size_t i = 0; i < operation->lanes().size(); ++i) {
      if ((operation->lanes()[i].transition & 31u) == 31u) {
        pair31 = i;
        break;
      }
    }
    ASSERT_NE(pair31, operation->lanes().size());
    ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, operation)));
    h.engine.advance(nullptr);
    const std::vector<std::uint8_t> fast = uniform_levels(rect, 2);
    ASSERT_TRUE(h.engine.admit(make_request(rect, 7, fast, 2,
                                            kAdmitFlagPenPreview)));
    const int x = rect.x + static_cast<int>(pair31 % 8u);
    const int y = rect.y + static_cast<int>(pair31 / 8u);
    EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), x, y), 31u);
    const std::size_t px = static_cast<std::size_t>(y) *
                               h.engine.plane_stride() +
                           static_cast<std::size_t>(x);
    EXPECT_TRUE(h.engine.dc_ledger().prev_estimated(px));
  }
}
#endif

TEST(PixelEngineMappedTest,
     HardInvalidationKeepsPoisonAndNeverWakesOrdinaryOverlap) {
  Harness h;
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear());
  const PlutoRect rect{0, 0, 8, 2};
  const auto operation = prepare_fast_operation(&history, rect, 0);
  std::vector<MappedEvent> events;
  h.engine.set_mapped_event_callback(
      [&](const MappedEvent& event) { events.push_back(event); });
  MappedAdmitOutcome mapped;
  ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, operation),
                                    &mapped));
  h.engine.advance(nullptr);
  const std::vector<std::uint8_t> ordinary = uniform_levels(rect, 10);
  AdmitOutcome ordinary_outcome;
  ASSERT_TRUE(h.engine.admit(make_request(rect, 2, ordinary, 99),
                             &ordinary_outcome));
  EXPECT_EQ(ordinary_outcome.parked_tiles, 1u);
  ASSERT_EQ(h.engine.invalidate_mapped(mapped.token),
            MappedFinalizeStatus::kInvalidated);
  ASSERT_TRUE(!events.empty());
  EXPECT_EQ(events.back().kind, MappedEventKind::kInvalidated);
  ASSERT_EQ(h.engine.mapped_poison_regions().size(), 1u);
  EXPECT_FALSE(
      h.engine.mapped_poison_regions()[0].regional_reseed_allowed);
  EXPECT_FALSE(h.engine.idle());
  EXPECT_FALSE(h.engine.handoff_safe());
  for (int i = 0; i < 4; ++i) {
    h.engine.advance(nullptr);
  }
  EXPECT_EQ(h.engine.parked_count(), 1u);
  EXPECT_FALSE(contains(h.completed, 99));
  // Even making history valid cannot turn unknown scan evidence into a local
  // regional recovery; only cold clear/reopen is legal.
  const std::vector<std::uint8_t> seed(16, 30);
  ASSERT_TRUE(history.reseed_region_from_levels({0, 0, 7, 1}, seed, 8));
  EXPECT_FALSE(h.engine.resolve_mapped_invalidation_after_reseed(
      &history, {0, 0, 7, 1}, 0));
}

#if 0
TEST(PixelEngineMappedTest,
     ExternalJournalLossDuringFastConflictInvalidatesAllWithoutIndexUaf) {
  Harness h;
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear());
  const auto a =
      prepare_fast_operation(&history, PlutoRect{0, 0, 8, 2}, 0);
  const auto b =
      prepare_fast_operation(&history, PlutoRect{40, 0, 8, 2}, 0);
  ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, a)));
  ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, b)));
  history.invalidate();  // both engine-held journals are no longer outstanding
  const PlutoRect fast_rect{0, 0, 8, 2};
  const std::vector<std::uint8_t> fast = uniform_levels(fast_rect, 2);
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(make_request(fast_rect, 7, fast, 1,
                                          kAdmitFlagPenPreview),
                             &outcome));
  EXPECT_EQ(h.engine.mapped_pending_count(), 0u);
  EXPECT_TRUE(h.engine.mapped_reconcile_required());
  EXPECT_EQ(outcome.parked_tiles, 0u);
}
#endif

TEST(PixelEngineMappedTest,
     RejectedPartialCandidateRecyclesWithoutLaneAllocation) {
  Harness h;
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear());
  const auto active =
      prepare_fast_operation(&history, PlutoRect{0, 0, 32, 2}, 0);
  MappedAdmitOutcome active_outcome;
  ASSERT_TRUE(h.engine.admit_mapped(
      mapped_request(&history, active), &active_outcome));
  ASSERT_EQ(active_outcome.status, MappedAdmitStatus::kStarted);
  ASSERT_EQ(h.engine.mapped_runtime_pool_count(), 0u);

  for (int attempt = 0; attempt < 2; ++attempt) {
    const auto partial =
        prepare_fast_operation(&history, PlutoRect{16, 0, 32, 2}, 7);
    MappedAdmitOutcome rejected;
    EXPECT_FALSE(
        h.engine.admit_mapped(mapped_request(&history, partial), &rejected));
    EXPECT_EQ(rejected.status, MappedAdmitStatus::kConflictPartial);
    // The candidate passed validation and acquired a runtime, but conflict
    // arbitration rejected it before any full-lane vector was allocated. The
    // RAII lease must return that empty runtime on every attempt.
    EXPECT_EQ(h.engine.mapped_runtime_pool_count(), 1u);
    EXPECT_EQ(h.engine.mapped_runtime_pool_lane_capacity_bytes(), 0u);
    EXPECT_EQ(h.engine.mapped_pending_count(), 1u);
  }
  EXPECT_EQ(h.engine.discard_mapped(active_outcome.token),
            MappedFinalizeStatus::kDiscarded);
  EXPECT_EQ(h.engine.mapped_runtime_pool_count(), 1u);
}

TEST(PixelEngineMappedTest,
     NearFullSingleGuardColumnUsesCompactExactLedger) {
  Harness h;
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear());
  const PlutoRect near_full{1, 0, h.engine.config().width - 1,
                              h.engine.config().height};
  const auto operation = prepare_fast_operation(&history, near_full, 0);
  ASSERT_EQ(operation->execution().right, h.engine.config().stride);
  ASSERT_EQ(operation->execution().bottom, h.engine.config().height - 1);
  const std::size_t execution_lanes = operation->lanes().size();
  const std::size_t guard_lanes =
      static_cast<std::size_t>(h.engine.config().height);
  ASSERT_EQ(execution_lanes,
            static_cast<std::size_t>(h.engine.config().width) *
                h.engine.config().height);

  MappedAdmitOutcome admitted;
  ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, operation),
                                    &admitted));
  EXPECT_EQ(h.engine.mapped_guard_storage_bytes(), guard_lanes);
  EXPECT_EQ(h.engine.mapped_runtime_lane_storage_bytes(), guard_lanes);
  EXPECT_LT(h.engine.mapped_guard_storage_bytes(), execution_lanes);

  CaptureEmitter capture;
  for (int frame = 0; frame < 2; ++frame) {
    h.engine.advance(&capture);
  }
  EXPECT_EQ(capture.max_row(), h.engine.config().height - 1);
  for (const auto& row : capture.rows) {
    for (const PixelOp& op : row.ops) {
      EXPECT_TRUE(op.x < h.engine.config().stride);
    }
  }
  EXPECT_EQ(h.engine.mapped_active_px(), 0u);
  EXPECT_EQ(h.engine.confirm_mapped(admitted.token),
            MappedFinalizeStatus::kConfirmed);
  ASSERT_TRUE(history.pixel(h.engine.config().stride, 0).has_value());
  EXPECT_EQ(history.pixel(h.engine.config().stride, 0)->a,
            operation->lanes()[h.engine.config().width - 1].a2);
}

TEST(PixelEngineMappedTest,
     BottomRightRoundedGuardsNeverEmitPastWireOrTouchControlRow) {
  PixelEngineConfig config;
  config.width = pluto::swtcon::kLogicalWidth;
  config.height = pluto::swtcon::kLogicalHeight;
  config.stride = pluto::swtcon::kPaddedSourceWidth;
  Harness h(config);
  XochitlHistoryState history;
  ASSERT_TRUE(history.initialize_cold_clear());
  const PlutoRect corner{pluto::swtcon::kLogicalWidth - 1,
                           pluto::swtcon::kLogicalHeight - 1, 1, 1};
  const auto operation = prepare_fast_operation(&history, corner, 0);
  ASSERT_EQ(operation->execution().right, 960);
  ASSERT_EQ(operation->execution().bottom, 1696);
  MappedAdmitOutcome admitted;
  ASSERT_TRUE(h.engine.admit_mapped(mapped_request(&history, operation),
                                    &admitted));

  PhaseEmitter phase;
  PhaseEmitterConfig phase_config;
  phase_config.slot_count = 1;
  ASSERT_TRUE(phase.configure(phase_config));
  std::vector<std::uint16_t> words(pluto::swtcon::kDrmPhaseWords);
  ASSERT_TRUE(phase.set_slot_target(0, words.data(),
                                    pluto::swtcon::kDrmWidth *
                                        sizeof(std::uint16_t)));
  ASSERT_TRUE(phase.blank_slot(0));
  const std::vector<std::uint16_t> control_before(
      words.begin() + static_cast<std::ptrdiff_t>(
                          pluto::swtcon::kTrailingControlRow *
                          pluto::swtcon::kDrmWidth),
      words.end());
  CaptureEmitter capture;
  TeeEmitter tee{&phase, &capture};
  for (int frame = 0; frame < 2; ++frame) {
    ASSERT_TRUE(phase.begin_frame(0, static_cast<std::uint64_t>(frame + 1)));
    h.engine.advance(&tee);
    phase.end_frame();
  }
  EXPECT_EQ(capture.max_row(), pluto::swtcon::kLogicalHeight - 1);
  for (const auto& row : capture.rows) {
    for (const PixelOp& op : row.ops) {
      EXPECT_TRUE(op.x < pluto::swtcon::kPaddedSourceWidth);
    }
  }
  const std::vector<std::uint16_t> control_after(
      words.begin() + static_cast<std::ptrdiff_t>(
                          pluto::swtcon::kTrailingControlRow *
                          pluto::swtcon::kDrmWidth),
      words.end());
  EXPECT_TRUE(control_before == control_after);
  EXPECT_EQ(h.engine.mapped_active_px(), 0u);
  EXPECT_EQ(h.engine.confirm_mapped(admitted.token),
            MappedFinalizeStatus::kConfirmed);
}

TEST(PixelEngineTest, PenPreviewDoesNotPreemptUncoveredActiveTruthPixels) {
  PixelEngineConfig config = small_config();
  config.early_cancel_enabled = false;
  Harness h(config);

  const PlutoRect truth{4, 4, 16, 4};
  const std::vector<std::uint8_t> black = uniform_levels(truth, 0);
  ASSERT_TRUE(h.engine.admit(make_request(truth, 2, black, 1)));
  h.engine.advance(nullptr);

  const PlutoRect partial{4, 4, 4, 4};
  const std::vector<std::uint8_t> white = uniform_levels(partial, 31);
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(
      make_request(partial, 7, white, 2, kAdmitFlagPenPreview), &outcome));
  EXPECT_EQ(outcome.parked_tiles, 1u);
  EXPECT_EQ(h.engine.stats().pen_cross_mode_preemptions, 0u);
}

// Sparkle top-off admission: header-only (levels null), only the near-white
// pixels whose R2 slot matches the pass phase start, targeting the white
// maintenance level; already-topped-off pixels and busy tiles are skipped.
TEST(PixelEngineTest, SparkleStartsOnlyMaskedNearWhitePixels) {
  Harness h;
  h.engine.set_temperature(10.0f);  // mode 2 N=4 (drive-everything table)

  // Left half black; columns 16..23 rail-white (28, under the top-off
  // level); columns 24..31 stay at the developed white (30). Sparkle may
  // lift ONLY the 28s — pulling a developed white down to the 4-phase
  // top-off endpoint dims it (warm-yellow cast on Gallery-3 glass).
  const PlutoRect left{0, 0, 16, 32};
  const std::vector<std::uint8_t> black = uniform_levels(left, 0);
  ASSERT_TRUE(h.engine.admit(make_request(left, 2, black, 1)));
  for (int i = 0; i < 4; ++i) {
    h.engine.advance(nullptr);
  }
  ASSERT_TRUE(h.engine.idle());
  const PlutoRect rail{16, 0, 8, 32};
  const std::vector<std::uint8_t> under_white = uniform_levels(rail, 28);
  ASSERT_TRUE(h.engine.admit(make_request(rail, 2, under_white, 2)));
  for (int i = 0; i < 4; ++i) {
    h.engine.advance(nullptr);
  }
  ASSERT_TRUE(h.engine.idle());

  // Sparkle phase 3 over the whole tile: only under-white pixels whose R2
  // slot == 3 may start, and every started pixel targets the top-off level.
  const std::uint32_t phase = 3;
  AdmitRequest sparkle;
  sparkle.rect = {0, 0, 32, 32};
  sparkle.mode = 2;
  sparkle.levels = nullptr;
  sparkle.frame_id = 3;
  sparkle.flags = pluto::swtcon::kAdmitFlagSparkle |
                  (phase << pluto::swtcon::kAdmitSparklePhaseShift);
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(sparkle, &outcome));
  EXPECT_EQ(outcome.started_tiles, 1u);

  std::uint32_t expected = 0;
  for (int y = 0; y < 32; ++y) {
    for (int x = 16; x < 24; ++x) {  // under-white band only
      const std::uint32_t slot =
          (static_cast<std::uint32_t>(x) * 3242174889u +
           static_cast<std::uint32_t>(y) * 2447445413u) >>
          28;
      expected += slot == phase ? 1u : 0u;
    }
  }
  ASSERT_GT(expected, 0u);
  EXPECT_EQ(h.engine.total_active_px(), expected);

  for (int i = 0; i < 4; ++i) {
    h.engine.advance(nullptr);
  }
  ASSERT_TRUE(h.engine.idle());
  ASSERT_EQ(h.completed.size(), 3u);
  // A masked under-white pixel landed on the top-off level; black pixels
  // and DEVELOPED whites (30) are untouched — masked or not.
  bool found_topped = false;
  for (int y = 0; y < 32 && !found_topped; ++y) {
    for (int x = 16; x < 24 && !found_topped; ++x) {
      const std::uint32_t slot =
          (static_cast<std::uint32_t>(x) * 3242174889u +
           static_cast<std::uint32_t>(y) * 2447445413u) >>
          28;
      if (slot == phase) {
        EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), x, y),
                  pluto::swtcon::kSparkleTargetLevel);
        found_topped = true;
      }
    }
  }
  EXPECT_TRUE(found_topped);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 0, 0), 0);
  bool checked_developed_white = false;
  for (int y = 0; y < 32 && !checked_developed_white; ++y) {
    for (int x = 24; x < 32 && !checked_developed_white; ++x) {
      const std::uint32_t slot =
          (static_cast<std::uint32_t>(x) * 3242174889u +
           static_cast<std::uint32_t>(y) * 2447445413u) >>
          28;
      if (slot == phase) {
        EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), x, y), 30u)
            << "sparkle must never pull a developed white down";
        checked_developed_white = true;
      }
    }
  }
  EXPECT_TRUE(checked_developed_white);

  // The same phase again: those pixels already sit at the top-off level —
  // nothing restarts (revisit-safe).
  AdmitOutcome again;
  ASSERT_TRUE(h.engine.admit(sparkle, &again));
  EXPECT_EQ(again.started_tiles, 0u);
  EXPECT_EQ(again.noop_tiles, 1u);
  EXPECT_EQ(h.engine.total_active_px(), 0u);
}

// Develop-variant sparkle (color glass): masked WHITE-family pixels —
// including pixels already at developed white 30 — start a GC16 drive to
// true white. The identity restart is the whole point: the yellow cast
// lives in pixels whose ledger level is already white, and only a develop
// resets the pigment stack. Black pixels never start, masked or not, and
// the same phase re-develops the same pixels on demand.
TEST(PixelEngineTest, DevelopSparkleRedevelopsMaskedWhites) {
  Harness h;
  h.engine.set_temperature(10.0f);  // mode 2 N=4 (drive-everything table)

  // Left half black; right half stays at the developed white (30).
  const PlutoRect left{0, 0, 16, 32};
  const std::vector<std::uint8_t> black = uniform_levels(left, 0);
  ASSERT_TRUE(h.engine.admit(make_request(left, 2, black, 1)));
  for (int i = 0; i < 4; ++i) {
    h.engine.advance(nullptr);
  }
  ASSERT_TRUE(h.engine.idle());

  // Pick the 8-bit R2 slot of the first white pixel as the pass phase so
  // the masked set is guaranteed non-empty.
  auto slot8 = [](int x, int y) {
    return (static_cast<std::uint32_t>(x) * 3242174889u +
            static_cast<std::uint32_t>(y) * 2447445413u) >>
           24;
  };
  const std::uint32_t phase = slot8(16, 0);
  std::uint32_t expected = 0;
  for (int y = 0; y < 32; ++y) {
    for (int x = 16; x < 32; ++x) {
      expected += slot8(x, y) == phase ? 1u : 0u;
    }
  }
  ASSERT_GT(expected, 0u);

  AdmitRequest develop;
  develop.rect = {0, 0, 32, 32};
  develop.mode = 2;
  develop.levels = nullptr;
  develop.frame_id = 2;
  develop.flags = pluto::swtcon::kAdmitFlagSparkle |
                  pluto::swtcon::kAdmitFlagSparkleDevelop |
                  (phase << pluto::swtcon::kAdmitSparklePhaseShift);
  AdmitOutcome outcome;
  ASSERT_TRUE(h.engine.admit(develop, &outcome));
  EXPECT_EQ(outcome.started_tiles, 1u);
  EXPECT_EQ(h.engine.total_active_px(), expected);

  for (int i = 0; i < 4; ++i) {
    h.engine.advance(nullptr);
  }
  ASSERT_TRUE(h.engine.idle());
  // Developed pixels land back on TRUE white; black pixels untouched.
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 16, 0),
            pluto::swtcon::kSparkleDevelopTargetLevel);
  EXPECT_EQ(plane_at(h.engine, h.engine.prev_plane(), 0, 0), 0);

  // The same phase again RE-develops the same whites (identity restart —
  // unlike the top-off, which is revisit-safe by design).
  AdmitOutcome again;
  ASSERT_TRUE(h.engine.admit(develop, &again));
  EXPECT_EQ(again.started_tiles, 1u);
  EXPECT_EQ(h.engine.total_active_px(), expected);
}
