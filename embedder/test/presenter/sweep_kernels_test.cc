// Scalar-vs-NEON goldens for the fused advance+emit+ledger sweep
// (sweep_kernels.{h,cc}) and the PhaseEmitter packed deposit — the engine
// extension of the test/renderer/kernels_test.cc golden pattern: random
// states, whole-plane parity including dc/fnum/prev/next/prev_est and the
// emitted ops. On non-NEON hosts the NEON suites compile out (the
// dispatchers alias the scalar references and there is nothing to compare).

#include "presenter/swtcon/sweep_kernels.h"

#include "presenter/swtcon/phase_emit.h"
#include "presenter/swtcon/swtcon_constants.h"

#include <gtest/gtest.h>

#include <array>
#include <cstdint>
#include <random>
#include <vector>

#if defined(__ARM_NEON) && defined(__aarch64__)

namespace {

using pluto::swtcon::kDrmPhaseWords;
using pluto::swtcon::kDrmWidth;
using pluto::swtcon::kWaveformMatrixCells;
using pluto::swtcon::PhaseEmitter;
using pluto::swtcon::PhaseEmitterConfig;
using pluto::swtcon::PixelEngine;
using pluto::swtcon::PixelOp;
using pluto::swtcon::SweepArgs;
using pluto::swtcon::SweepResult;
using pluto::swtcon::sweep_segment_neon;
using pluto::swtcon::sweep_segment_scalar;

struct SweepState {
  std::vector<std::uint8_t> prev;
  std::vector<std::uint8_t> next;
  std::vector<std::uint8_t> final_lv;
  std::vector<std::uint8_t> fnum;
  std::vector<std::int8_t> dc;
  std::vector<std::uint8_t> drove;
  std::vector<std::uint8_t> prev_est;
  std::vector<std::uint8_t> codes;
  std::array<std::int8_t, 8> impulse_map{};
  std::size_t px0 = 0;
  int x0 = 0;
  int count = 0;
  int phase_count = 0;
  std::int8_t dc_cap = 0;
  bool renorm_dc = false;

  SweepArgs args() {
    SweepArgs out;
    out.prev = prev.data();
    out.next = next.data();
    out.final_lv = final_lv.data();
    out.fnum = fnum.data();
    out.dc = dc.data();
    out.drove = drove.data();
    out.prev_est = prev_est.data();
    out.px0 = px0;
    out.x0 = x0;
    out.count = count;
    out.codes = codes.data();
    out.phase_count = phase_count;
    out.impulse_map = impulse_map.data();
    out.dc_cap = dc_cap;
    out.renorm_dc = renorm_dc;
    return out;
  }
};

std::size_t bit_count(const std::vector<std::uint8_t>& bytes) {
  std::size_t count = 0;
  for (const std::uint8_t byte : bytes) {
    count += static_cast<std::size_t>(__builtin_popcount(byte));
  }
  return count;
}

// Random engine state for one segment. Structures exercised:
//   0: dense mid-sequence (all active, shared fnum away from the boundary)
//   1: dense boundary frame (all lanes at phase_count - 1; random restarts)
//   2: sparse actives with mixed fnums (early-cancel shape) + idles
//   3: fully idle
SweepState make_state(std::mt19937* rng, int structure) {
  std::uniform_int_distribution<int> level(0, 31);
  std::uniform_int_distribution<int> byte(0, 255);
  std::uniform_int_distribution<int> code(0, 7);
  std::uniform_int_distribution<int> imp(-3, 3);

  SweepState s;
  s.count = 1 + static_cast<int>((*rng)() % 40);
  s.phase_count = 1 + static_cast<int>((*rng)() % 6);
  if (structure == 1 && (*rng)() % 2 == 0) {
    s.phase_count = 1;  // instant-boundary sequences
  }
  s.dc_cap = static_cast<std::int8_t>(1 + (*rng)() % 127);
  s.renorm_dc = ((*rng)() % 2) == 0;
  s.px0 = static_cast<std::size_t>((*rng)() % 64);
  s.x0 = static_cast<int>((*rng)() % 512);

  const std::size_t n = static_cast<std::size_t>(s.count);
  s.prev.resize(n);
  s.next.resize(n);
  s.final_lv.resize(n);
  s.fnum.resize(n);
  s.dc.resize(n);
  s.drove.resize(n);
  s.prev_est.assign((s.px0 + n) / 8 + 2, 0);
  for (auto& b : s.prev_est) {
    b = static_cast<std::uint8_t>(byte(*rng));
  }
  s.codes.resize(static_cast<std::size_t>(s.phase_count) *
                 kWaveformMatrixCells);
  for (auto& c : s.codes) {
    c = static_cast<std::uint8_t>(code(*rng));
  }
  for (auto& m : s.impulse_map) {
    m = static_cast<std::int8_t>(imp(*rng));
  }
  if ((*rng)() % 2 == 0) {
    s.impulse_map[0] = 0;  // the production hold-is-impulse-free shape
  }

  const int shared_fnum = static_cast<int>(
      (*rng)() % static_cast<unsigned>(s.phase_count));
  std::uniform_int_distribution<int> anyf(0, s.phase_count - 1);
  for (std::size_t i = 0; i < n; ++i) {
    s.prev[i] = static_cast<std::uint8_t>(level(*rng));
    s.next[i] = static_cast<std::uint8_t>(level(*rng));
    // final == next most of the time; a differing final exercises the
    // boundary retarget-link (restart) path.
    s.final_lv[i] = ((*rng)() % 4 == 0)
                        ? static_cast<std::uint8_t>(level(*rng))
                        : s.next[i];
    // dc within +-cap: the engine charge/renormalize invariant the kernels
    // are specified against.
    s.dc[i] = static_cast<std::int8_t>(
        static_cast<int>((*rng)() % (2u * s.dc_cap + 1)) - s.dc_cap);
    s.drove[i] = static_cast<std::uint8_t>((*rng)() & 1u);
    switch (structure) {
      case 0:
        s.fnum[i] = static_cast<std::uint8_t>(shared_fnum);
        break;
      case 1:
        s.fnum[i] = static_cast<std::uint8_t>(s.phase_count - 1);
        break;
      case 2:
        s.fnum[i] = ((*rng)() % 3 == 0)
                        ? PixelEngine::kFnumIdle
                        : static_cast<std::uint8_t>(anyf(*rng));
        break;
      default:
        s.fnum[i] = PixelEngine::kFnumIdle;
        break;
    }
  }
  return s;
}

TEST(SweepKernelsNeonGolden, MatchesScalarOnRandomStates) {
  std::mt19937 rng(0xf00dcafe);
  for (int iteration = 0; iteration < 400; ++iteration) {
    const int structure = iteration % 4;
    SweepState scalar_state = make_state(&rng, structure);
    SweepState neon_state = scalar_state;
    const std::size_t prev_estimated_before = bit_count(scalar_state.prev_est);

    std::vector<PixelOp> scalar_ops(64, PixelOp{0xffff, 0xff});
    std::vector<PixelOp> neon_ops(64, PixelOp{0xffff, 0xff});
    const SweepResult scalar_result =
        sweep_segment_scalar(scalar_state.args(), scalar_ops.data());
    const SweepResult neon_result =
        sweep_segment_neon(neon_state.args(), neon_ops.data());

    ASSERT_EQ(scalar_result.emitted, neon_result.emitted)
        << "iteration " << iteration;
    ASSERT_EQ(scalar_result.completed, neon_result.completed)
        << "iteration " << iteration;
    ASSERT_EQ(scalar_result.saturations, neon_result.saturations)
        << "iteration " << iteration;
    ASSERT_EQ(scalar_result.prev_estimated_cleared,
              neon_result.prev_estimated_cleared)
        << "iteration " << iteration;
    ASSERT_EQ(scalar_result.prev_estimated_cleared,
              prev_estimated_before - bit_count(scalar_state.prev_est))
        << "iteration " << iteration;
    ASSERT_EQ(scalar_result.impulse, neon_result.impulse)
        << "iteration " << iteration;
    ASSERT_EQ(scalar_result.drove, neon_result.drove)
        << "iteration " << iteration;
    for (std::uint32_t i = 0; i < scalar_result.emitted; ++i) {
      ASSERT_EQ(scalar_ops[i].x, neon_ops[i].x)
          << "iteration " << iteration << " op " << i;
      ASSERT_EQ(scalar_ops[i].code, neon_ops[i].code)
          << "iteration " << iteration << " op " << i;
    }
    ASSERT_TRUE(scalar_state.prev == neon_state.prev)
        << "iteration " << iteration;
    ASSERT_TRUE(scalar_state.next == neon_state.next)
        << "iteration " << iteration;
    ASSERT_TRUE(scalar_state.final_lv == neon_state.final_lv)
        << "iteration " << iteration;
    ASSERT_TRUE(scalar_state.fnum == neon_state.fnum)
        << "iteration " << iteration;
    ASSERT_TRUE(scalar_state.dc == neon_state.dc)
        << "iteration " << iteration;
    ASSERT_TRUE(scalar_state.drove == neon_state.drove)
        << "iteration " << iteration;
    ASSERT_TRUE(scalar_state.prev_est == neon_state.prev_est)
        << "iteration " << iteration;
  }
}

// Independent semantic pin for the fused drive-evidence plane: it must equal
// the old post-sweep fold over emitted ops, including preservation of prior
// evidence and exclusion of raw codes whose low three bits are hold.
TEST(SweepKernelsNeonGolden, FusedDriveEvidenceMatchesEmittedOpFold) {
  std::mt19937 rng(0xd21e5eed);
  for (int iteration = 0; iteration < 240; ++iteration) {
    SweepState state = make_state(&rng, iteration % 4);
    const std::vector<std::uint8_t> before = state.drove;
    std::vector<PixelOp> ops(64, PixelOp{0xffff, 0xff});
    const SweepResult result = sweep_segment_neon(state.args(), ops.data());

    std::vector<std::uint8_t> expected = before;
    for (std::uint32_t i = 0; i < result.emitted; ++i) {
      const int local_x = static_cast<int>(ops[i].x) - state.x0;
      ASSERT_TRUE(local_x >= 0 && local_x < state.count)
          << "iteration " << iteration << " op " << i;
      if ((ops[i].code & 0x7u) != 0) {
        expected[static_cast<std::size_t>(local_x)] = 1;
      }
    }
    ASSERT_TRUE(state.drove == expected) << "iteration " << iteration;
  }
}

// High-phase-count tables (cold temperature bins run up to ~244 phases on
// device): phase_count > 64 exceeds the u16 gather-index fast path's exact
// range, so the NEON sweep must take its u32 index build — this golden pins
// that path, which the 1..6-phase cases above no longer reach.
TEST(SweepKernelsNeonGolden, MatchesScalarOnHighPhaseCountTables) {
  std::mt19937 rng(0xc01db175);
  std::uniform_int_distribution<int> code(0, 7);
  for (int iteration = 0; iteration < 80; ++iteration) {
    const int structure = iteration % 4;
    SweepState scalar_state = make_state(&rng, structure);
    // Rewrite the state onto a cold-bin-sized table: pc in [65, 255].
    scalar_state.phase_count = 65 + static_cast<int>(rng() % 191);
    scalar_state.codes.resize(
        static_cast<std::size_t>(scalar_state.phase_count) *
        kWaveformMatrixCells);
    for (auto& c : scalar_state.codes) {
      c = static_cast<std::uint8_t>(code(rng));
    }
    std::uniform_int_distribution<int> anyf(0, scalar_state.phase_count - 1);
    for (auto& f : scalar_state.fnum) {
      if (f == PixelEngine::kFnumIdle) {
        continue;
      }
      f = structure == 1
              ? static_cast<std::uint8_t>(scalar_state.phase_count - 1)
              : static_cast<std::uint8_t>(anyf(rng));
    }
    SweepState neon_state = scalar_state;
    const std::size_t prev_estimated_before = bit_count(scalar_state.prev_est);

    std::vector<PixelOp> scalar_ops(64, PixelOp{0xffff, 0xff});
    std::vector<PixelOp> neon_ops(64, PixelOp{0xffff, 0xff});
    const SweepResult scalar_result =
        sweep_segment_scalar(scalar_state.args(), scalar_ops.data());
    const SweepResult neon_result =
        sweep_segment_neon(neon_state.args(), neon_ops.data());

    ASSERT_EQ(scalar_result.emitted, neon_result.emitted)
        << "iteration " << iteration;
    ASSERT_EQ(scalar_result.completed, neon_result.completed)
        << "iteration " << iteration;
    ASSERT_EQ(scalar_result.saturations, neon_result.saturations)
        << "iteration " << iteration;
    ASSERT_EQ(scalar_result.prev_estimated_cleared,
              neon_result.prev_estimated_cleared)
        << "iteration " << iteration;
    ASSERT_EQ(scalar_result.prev_estimated_cleared,
              prev_estimated_before - bit_count(scalar_state.prev_est))
        << "iteration " << iteration;
    ASSERT_EQ(scalar_result.impulse, neon_result.impulse)
        << "iteration " << iteration;
    ASSERT_EQ(scalar_result.drove, neon_result.drove)
        << "iteration " << iteration;
    for (std::uint32_t i = 0; i < scalar_result.emitted; ++i) {
      ASSERT_EQ(scalar_ops[i].x, neon_ops[i].x)
          << "iteration " << iteration << " op " << i;
      ASSERT_EQ(scalar_ops[i].code, neon_ops[i].code)
          << "iteration " << iteration << " op " << i;
    }
    ASSERT_TRUE(scalar_state.prev == neon_state.prev)
        << "iteration " << iteration;
    ASSERT_TRUE(scalar_state.next == neon_state.next)
        << "iteration " << iteration;
    ASSERT_TRUE(scalar_state.final_lv == neon_state.final_lv)
        << "iteration " << iteration;
    ASSERT_TRUE(scalar_state.fnum == neon_state.fnum)
        << "iteration " << iteration;
    ASSERT_TRUE(scalar_state.dc == neon_state.dc)
        << "iteration " << iteration;
    ASSERT_TRUE(scalar_state.drove == neon_state.drove)
        << "iteration " << iteration;
    ASSERT_TRUE(scalar_state.prev_est == neon_state.prev_est)
        << "iteration " << iteration;
  }
}

// PhaseEmitter deposit parity: the NEON 4px/word packed deposit must
// produce byte-identical planes vs the scalar lane-RMW reference over
// dense, sparse, and offset op rows.
TEST(SweepKernelsNeonGolden, PackedDepositMatchesScalarPlanes) {
  std::mt19937 rng(0xdeadf00d);
  std::uniform_int_distribution<int> raw_code(0, 255);

  for (int iteration = 0; iteration < 60; ++iteration) {
    PhaseEmitter scalar_emitter;
    PhaseEmitter neon_emitter;
    PhaseEmitterConfig scalar_config;
    scalar_config.slot_count = 1;
    scalar_config.force_scalar_deposit = true;
    PhaseEmitterConfig neon_config = scalar_config;
    neon_config.force_scalar_deposit = false;
    ASSERT_TRUE(scalar_emitter.configure(scalar_config));
    ASSERT_TRUE(neon_emitter.configure(neon_config));

    std::vector<std::uint16_t> scalar_words(kDrmPhaseWords, 0);
    std::vector<std::uint16_t> neon_words(kDrmPhaseWords, 0);
    ASSERT_TRUE(scalar_emitter.set_slot_target(
        0, scalar_words.data(), kDrmWidth * sizeof(std::uint16_t)));
    ASSERT_TRUE(neon_emitter.set_slot_target(
        0, neon_words.data(), kDrmWidth * sizeof(std::uint16_t)));
    ASSERT_TRUE(scalar_emitter.blank_slot(0));
    ASSERT_TRUE(neon_emitter.blank_slot(0));
    ASSERT_TRUE(scalar_emitter.begin_frame(0, 1));
    ASSERT_TRUE(neon_emitter.begin_frame(0, 1));

    for (int row = 0; row < 24; ++row) {
      // Ascending unique x (the engine emission contract): random column
      // subset with a density sweep — dense rows hit the packed path,
      // sparse/offset rows the scalar fallback inside the NEON body.
      const int keep_percent = (row * 37 + iteration * 13) % 101;
      std::vector<PixelOp> ops;
      for (int x = 0; x < pluto::swtcon::kLogicalWidth; ++x) {
        if (static_cast<int>(rng() % 100) < keep_percent) {
          ops.push_back(PixelOp{static_cast<std::uint16_t>(x),
                                static_cast<std::uint8_t>(raw_code(rng))});
        }
      }
      if (ops.empty()) {
        continue;
      }
      scalar_emitter.emit_row(row, ops.data(), ops.size());
      neon_emitter.emit_row(row, ops.data(), ops.size());
    }
    scalar_emitter.end_frame();
    neon_emitter.end_frame();
    ASSERT_TRUE(scalar_words == neon_words) << "iteration " << iteration;
  }
}

}  // namespace

#endif  // __ARM_NEON && __aarch64__
