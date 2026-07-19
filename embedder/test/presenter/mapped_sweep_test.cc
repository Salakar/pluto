#include "presenter/swtcon/mapped_sweep.h"

#include "presenter/swtcon/swtcon_constants.h"

#include <gtest/gtest.h>

#include <array>
#include <cstdint>
#include <cstring>
#include <random>
#include <vector>

namespace {

using pluto::swtcon::MappedPixelOp;
using pluto::swtcon::MappedSweepArgs;
using pluto::swtcon::MappedSweepResult;
using pluto::swtcon::kMappedSweepIdle;
using pluto::swtcon::kWaveformMatrixCells;
using pluto::swtcon::mapped_sweep_scalar;

constexpr std::uint16_t transition(std::uint8_t source,
                                   std::uint8_t drive) {
  return static_cast<std::uint16_t>((source << 5) | drive);
}

constexpr std::size_t record_cell(std::uint8_t source,
                                  std::uint8_t drive) {
  return (static_cast<std::size_t>(drive) << 5) | source;
}

struct State {
  std::vector<std::uint16_t> transitions;
  std::vector<std::uint8_t> fnum;
  std::vector<std::int8_t> dc;
  std::vector<std::uint8_t> terminal;
  std::vector<std::uint8_t> codes;
  std::array<std::int8_t, 8> impulse_map{};
  int phase_count = 0;
  int x0 = 0;

  MappedSweepArgs args() {
    return MappedSweepArgs{
        transitions.data(), fnum.data(), dc.data(), terminal.data(),
        x0, static_cast<int>(transitions.size()), codes.data(), phase_count,
        impulse_map.data(), 10};
  }
};

#if defined(__ARM_NEON) && defined(__aarch64__)
void expect_result_eq(const MappedSweepResult& expected,
                      const MappedSweepResult& actual, int iteration) {
  EXPECT_EQ(expected.emitted, actual.emitted) << "iteration " << iteration;
  EXPECT_EQ(expected.completed, actual.completed) << "iteration " << iteration;
  EXPECT_EQ(expected.saturations, actual.saturations)
      << "iteration " << iteration;
  EXPECT_EQ(expected.impulse, actual.impulse) << "iteration " << iteration;
  EXPECT_EQ(expected.drove, actual.drove) << "iteration " << iteration;
}
#endif

TEST(MappedSweepScalar, TransposesMapperWordAndNeverMutatesIt) {
  State state;
  state.transitions = {transition(7, 3), transition(9, 9)};
  const std::vector<std::uint16_t> immutable = state.transitions;
  state.fnum = {0, 0};
  state.dc = {0, 0};
  state.terminal = {0xff, 0xff};
  state.phase_count = 2;
  state.x0 = 41;
  state.codes.assign(2 * kWaveformMatrixCells, 0);
  state.codes[record_cell(7, 3)] = 1;
  state.codes[record_cell(9, 9)] = 2;
  state.codes[kWaveformMatrixCells + record_cell(7, 3)] = 5;
  state.codes[kWaveformMatrixCells + record_cell(9, 9)] = 6;
  state.impulse_map = {2, 1, 2, 3, -1, -2, -3, -4};

  std::array<MappedPixelOp, 2> ops{};
  MappedSweepResult result = mapped_sweep_scalar(state.args(), ops.data());
  EXPECT_EQ(result.emitted, 2u);
  EXPECT_EQ(result.completed, 0u);
  EXPECT_EQ(result.impulse, 3);
  EXPECT_TRUE(result.drove);
  EXPECT_EQ(ops[0].x, 41);
  EXPECT_EQ(ops[0].code, 1);
  EXPECT_EQ(ops[0].reserved, 0);
  EXPECT_EQ(ops[1].x, 42);
  EXPECT_EQ(ops[1].code, 2);
  EXPECT_EQ(ops[1].reserved, 0);
  EXPECT_TRUE(state.transitions == immutable);
  EXPECT_TRUE(state.fnum == std::vector<std::uint8_t>({1, 1}));
  EXPECT_TRUE(state.dc == std::vector<std::int8_t>({1, 2}));
  EXPECT_TRUE(state.terminal == std::vector<std::uint8_t>({0, 0}));

  result = mapped_sweep_scalar(state.args(), ops.data());
  EXPECT_EQ(result.emitted, 2u);
  EXPECT_EQ(result.completed, 2u);
  EXPECT_EQ(result.impulse, -5);
  EXPECT_TRUE(result.drove);
  EXPECT_EQ(ops[0].code, 5);
  EXPECT_EQ(ops[1].code, 6);
  EXPECT_TRUE(state.transitions == immutable);
  EXPECT_TRUE(state.fnum ==
              std::vector<std::uint8_t>({kMappedSweepIdle,
                                         kMappedSweepIdle}));
  EXPECT_TRUE(state.dc == std::vector<std::int8_t>({-1, -1}));
  EXPECT_TRUE(state.terminal == std::vector<std::uint8_t>({1, 1}));
}

TEST(MappedSweepScalar, IdentityHoldStillEmitsChargesAndTerminates) {
  State state;
  state.transitions = {transition(12, 12)};
  state.fnum = {0};
  state.dc = {9};
  state.terminal = {0xff};
  state.phase_count = 1;
  state.codes.assign(kWaveformMatrixCells, 7);
  state.codes[record_cell(12, 12)] = 0;
  state.impulse_map = {3, 1, 2, 3, -1, -2, -3, -4};

  MappedPixelOp op{0xffff, 0xff, 0xff};
  const MappedSweepResult result = mapped_sweep_scalar(state.args(), &op);
  EXPECT_EQ(result.emitted, 1u);
  EXPECT_EQ(result.completed, 1u);
  EXPECT_EQ(result.saturations, 1u);
  EXPECT_EQ(result.impulse, 0);
  EXPECT_FALSE(result.drove);
  EXPECT_EQ(op.code, 0);
  EXPECT_EQ(op.reserved, 0);
  EXPECT_EQ(state.dc[0], 10);
  EXPECT_EQ(state.fnum[0], kMappedSweepIdle);
  EXPECT_EQ(state.terminal[0], 1);
}

TEST(MappedSweepScalar, CountsBothDcClampDirectionsExactly) {
  State state;
  state.transitions = {transition(1, 2), transition(3, 4), transition(5, 6)};
  state.fnum = {0, 0, 0};
  state.dc = {9, -9, 0};
  state.terminal = {8, 8, 8};
  state.phase_count = 2;
  state.codes.assign(2 * kWaveformMatrixCells, 0);
  state.codes[record_cell(1, 2)] = 1;
  state.codes[record_cell(3, 4)] = 4;
  state.codes[record_cell(5, 6)] = 2;
  state.impulse_map = {0, 3, 2, 1, -3, -2, -1, 0};

  std::array<MappedPixelOp, 3> ops{};
  const MappedSweepResult result = mapped_sweep_scalar(state.args(), ops.data());
  EXPECT_EQ(result.emitted, 3u);
  EXPECT_EQ(result.completed, 0u);
  EXPECT_EQ(result.saturations, 2u);
  EXPECT_EQ(result.impulse, 2);
  EXPECT_TRUE(result.drove);
  EXPECT_TRUE(state.dc == std::vector<std::int8_t>({10, -10, 2}));
  EXPECT_TRUE(state.terminal == std::vector<std::uint8_t>({0, 0, 0}));
}

TEST(MappedSweepScalar, IdleLanesOnlyClearStaleTerminalMarks) {
  State state;
  state.transitions = {transition(1, 31), transition(31, 1)};
  const std::vector<std::uint16_t> transitions_before = state.transitions;
  state.fnum = {kMappedSweepIdle, kMappedSweepIdle};
  state.dc = {4, -4};
  state.terminal = {1, 1};
  state.phase_count = 3;
  state.codes.assign(3 * kWaveformMatrixCells, 7);
  state.impulse_map = {1, 1, 1, 1, 1, 1, 1, 1};

  std::array<MappedPixelOp, 2> ops{
      MappedPixelOp{0xffff, 0xff, 0xff},
      MappedPixelOp{0xffff, 0xff, 0xff}};
  const MappedSweepResult result = mapped_sweep_scalar(state.args(), ops.data());
  EXPECT_EQ(result.emitted, 0u);
  EXPECT_EQ(result.completed, 0u);
  EXPECT_EQ(result.saturations, 0u);
  EXPECT_EQ(result.impulse, 0);
  EXPECT_FALSE(result.drove);
  EXPECT_TRUE(state.transitions == transitions_before);
  EXPECT_TRUE(state.fnum ==
              std::vector<std::uint8_t>({kMappedSweepIdle,
                                         kMappedSweepIdle}));
  EXPECT_TRUE(state.dc == std::vector<std::int8_t>({4, -4}));
  EXPECT_TRUE(state.terminal == std::vector<std::uint8_t>({0, 0}));
  EXPECT_EQ(ops[0].reserved, 0xff);
}

#if defined(__ARM_NEON) && defined(__aarch64__)
using pluto::swtcon::mapped_sweep_neon;

TEST(MappedSweepNeon, ByteIdenticalToScalarAcrossRandomStates) {
  std::mt19937 rng(0x6d617070u);
  constexpr std::array<int, 7> kPhaseCounts = {1, 5, 63, 64, 65, 187, 255};
  constexpr std::array<int, 12> kCounts = {
      1, 7, 15, 16, 17, 31, 32, 33, 127, 511, 954, 960};

  for (int iteration = 0; iteration < 350; ++iteration) {
    State scalar;
    scalar.phase_count =
        kPhaseCounts[static_cast<std::size_t>(iteration) % kPhaseCounts.size()];
    const int count =
        kCounts[static_cast<std::size_t>(iteration) % kCounts.size()];
    scalar.x0 = static_cast<int>(rng() % (65536u - count));
    scalar.transitions.resize(static_cast<std::size_t>(count));
    scalar.fnum.resize(static_cast<std::size_t>(count));
    scalar.dc.resize(static_cast<std::size_t>(count));
    scalar.terminal.resize(static_cast<std::size_t>(count));
    scalar.codes.resize(static_cast<std::size_t>(scalar.phase_count) *
                        kWaveformMatrixCells);
    for (auto& value : scalar.transitions) {
      value = static_cast<std::uint16_t>(rng() & 1023u);
    }
    for (auto& value : scalar.fnum) {
      value = (rng() % 5 == 0)
                  ? kMappedSweepIdle
                  : static_cast<std::uint8_t>(rng() % scalar.phase_count);
    }
    for (auto& value : scalar.dc) {
      // Include diagnostic pre-states outside +-cap. Scalar charge is a
      // strict no-op for idle/zero-impulse lanes; NEON must not silently
      // normalize those bytes while vectorizing neighboring active lanes.
      value = static_cast<std::int8_t>(rng() & 0xffu);
    }
    for (auto& value : scalar.terminal) {
      value = static_cast<std::uint8_t>(rng() & 0xffu);
    }
    for (auto& value : scalar.codes) {
      value = static_cast<std::uint8_t>(rng() & 0xffu);
    }
    for (auto& value : scalar.impulse_map) {
      value = static_cast<std::int8_t>(static_cast<int>(rng() % 9) - 4);
    }

    State neon = scalar;
    const std::vector<std::uint16_t> immutable = scalar.transitions;
    std::vector<MappedPixelOp> scalar_ops(
        static_cast<std::size_t>(count), MappedPixelOp{0xffff, 0xff, 0xff});
    std::vector<MappedPixelOp> neon_ops = scalar_ops;
    const MappedSweepResult scalar_result =
        mapped_sweep_scalar(scalar.args(), scalar_ops.data());
    const MappedSweepResult neon_result =
        mapped_sweep_neon(neon.args(), neon_ops.data());

    expect_result_eq(scalar_result, neon_result, iteration);
    ASSERT_TRUE(scalar.transitions == immutable) << "iteration " << iteration;
    ASSERT_TRUE(neon.transitions == immutable) << "iteration " << iteration;
    ASSERT_TRUE(scalar.fnum == neon.fnum) << "iteration " << iteration;
    ASSERT_TRUE(scalar.dc == neon.dc) << "iteration " << iteration;
    ASSERT_TRUE(scalar.terminal == neon.terminal) << "iteration " << iteration;
    ASSERT_EQ(std::memcmp(scalar_ops.data(), neon_ops.data(),
                          scalar_result.emitted * sizeof(MappedPixelOp)),
              0)
        << "iteration " << iteration;
  }
}
#else
TEST(MappedSweepDispatch, UsesScalarContractOnNonNeonHosts) {
  State state;
  state.transitions = {transition(2, 3)};
  state.fnum = {0};
  state.dc = {0};
  state.terminal = {9};
  state.phase_count = 1;
  state.codes.assign(kWaveformMatrixCells, 0);
  state.codes[record_cell(2, 3)] = 6;
  state.impulse_map = {0, 1, 2, 3, -1, -2, -3, -4};
  MappedPixelOp op{};
  const MappedSweepResult result =
      pluto::swtcon::mapped_sweep(state.args(), &op);
  EXPECT_EQ(result.emitted, 1u);
  EXPECT_EQ(op.code, 6);
  EXPECT_EQ(state.terminal[0], 1);
}

TEST(MappedSweepUniformPhase, MatchesPerLaneCursorMidSequenceAndTerminal) {
  constexpr int kCount = 954;
  constexpr int kPhaseCount = 128;
  for (const int phase : {37, kPhaseCount - 1}) {
    State reference;
    reference.phase_count = kPhaseCount;
    reference.x0 = 3;
    reference.transitions.resize(kCount);
    reference.fnum.assign(kCount, static_cast<std::uint8_t>(phase));
    reference.dc.resize(kCount);
    reference.terminal.assign(kCount, 0xa5u);
    reference.codes.resize(static_cast<std::size_t>(kPhaseCount) *
                           kWaveformMatrixCells);
    reference.impulse_map = {0, -1, 1, -2, 2, -3, 3, 0};
    for (int lane = 0; lane < kCount; ++lane) {
      reference.transitions[static_cast<std::size_t>(lane)] =
          static_cast<std::uint16_t>((lane * 29 + 17) & 1023);
      reference.dc[static_cast<std::size_t>(lane)] =
          static_cast<std::int8_t>((lane % 17) - 8);
    }
    for (std::size_t index = 0; index < reference.codes.size(); ++index) {
      reference.codes[index] = static_cast<std::uint8_t>((index * 13 + 5) & 7u);
    }

    State uniform = reference;
    std::vector<MappedPixelOp> reference_ops(kCount);
    std::vector<MappedPixelOp> uniform_ops(kCount);
    const MappedSweepResult expected =
        mapped_sweep_scalar(reference.args(), reference_ops.data());
    MappedSweepArgs uniform_args = uniform.args();
    uniform_args.fnum = nullptr;
    uniform_args.uniform_phase = phase;
    const MappedSweepResult actual =
        mapped_sweep(uniform_args, uniform_ops.data());

    EXPECT_EQ(actual.emitted, expected.emitted);
    EXPECT_EQ(actual.completed, expected.completed);
    EXPECT_EQ(actual.saturations, expected.saturations);
    EXPECT_EQ(actual.impulse, expected.impulse);
    EXPECT_EQ(actual.drove, expected.drove);
    EXPECT_TRUE(uniform.dc == reference.dc);
    EXPECT_TRUE(uniform.terminal == reference.terminal);
    EXPECT_EQ(std::memcmp(reference_ops.data(), uniform_ops.data(),
                          expected.emitted * sizeof(MappedPixelOp)),
              0);
  }
}
#endif

}  // namespace
