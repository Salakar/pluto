#include "presenter/swtcon/mapped_sweep.h"

#include "presenter/swtcon/swtcon_constants.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <random>
#include <vector>

namespace {

using pluto::swtcon::MappedPixelOp;
using pluto::swtcon::MappedSweepArgs;
using pluto::swtcon::MappedSweepResult;
using pluto::swtcon::kLogicalHeight;
using pluto::swtcon::kPaddedSourceWidth;
using pluto::swtcon::kWaveformMatrixCells;

constexpr int kPhases = 86;
constexpr int kWarmups = 4;
constexpr int kSamples = 32;
constexpr double kScanBudgetUs = 11764.0;

struct Percentiles {
  double p50_us = 0;
  double p95_us = 0;
  double max_us = 0;
};

Percentiles percentiles(std::vector<double> samples) {
  std::sort(samples.begin(), samples.end());
  return Percentiles{samples[samples.size() / 2],
                     samples[(samples.size() * 95) / 100], samples.back()};
}

struct BenchState {
  std::vector<std::uint16_t> transitions;
  std::vector<std::uint8_t> fnum;
  std::vector<std::int8_t> dc;
  std::vector<std::uint8_t> terminal;
  std::vector<std::uint8_t> codes;
  std::array<std::int8_t, 8> impulse_map{0, 1, 2, 3, -1, -2, -3, -4};
  std::vector<MappedPixelOp> row_ops;
};

BenchState make_state() {
  const std::size_t pixels =
      static_cast<std::size_t>(kPaddedSourceWidth) * kLogicalHeight;
  BenchState state;
  state.transitions.resize(pixels);
  state.fnum.assign(pixels, 7);
  state.dc.assign(pixels, 0);
  state.terminal.assign(pixels, 0);
  state.codes.resize(static_cast<std::size_t>(kPhases) *
                     kWaveformMatrixCells);
  state.row_ops.resize(kPaddedSourceWidth);

  std::mt19937 rng(0x6d617070u);
  for (auto& word : state.transitions) {
    word = static_cast<std::uint16_t>(rng() & 1023u);
  }
  for (auto& code : state.codes) {
    code = static_cast<std::uint8_t>(rng() & 7u);
  }
  return state;
}

using SweepFn = MappedSweepResult (*)(const MappedSweepArgs&, MappedPixelOp*);

Percentiles run_bench(SweepFn sweep, std::uint64_t* checksum_out) {
  BenchState state = make_state();
  std::vector<double> samples;
  samples.reserve(kSamples);
  std::uint64_t checksum = 0;

  for (int iteration = 0; iteration < kWarmups + kSamples; ++iteration) {
    const auto start = std::chrono::steady_clock::now();
    for (int y = 0; y < kLogicalHeight; ++y) {
      const std::size_t offset =
          static_cast<std::size_t>(y) * kPaddedSourceWidth;
      const MappedSweepArgs args{
          state.transitions.data() + offset,
          state.fnum.data() + offset,
          state.dc.data() + offset,
          state.terminal.data() + offset,
          0,
          kPaddedSourceWidth,
          state.codes.data(),
          kPhases,
          state.impulse_map.data(),
          64};
      const MappedSweepResult result = sweep(args, state.row_ops.data());
      checksum += result.emitted + result.completed + result.saturations;
      checksum += static_cast<std::uint64_t>(
          static_cast<std::int64_t>(result.impulse) + 0x100000000ll);
      checksum += state.row_ops[result.emitted - 1].code;
    }
    const std::chrono::duration<double, std::micro> elapsed =
        std::chrono::steady_clock::now() - start;
    if (iteration >= kWarmups) {
      samples.push_back(elapsed.count());
    }
  }
  *checksum_out = checksum;
  return percentiles(std::move(samples));
}

void print_row(const char* name, const Percentiles& value) {
  std::printf("%-10s p50=%8.1f us  p95=%8.1f us  max=%8.1f us  "
              "p95/budget=%5.2fx\n",
              name, value.p50_us, value.p95_us, value.max_us,
              value.p95_us / kScanBudgetUs);
}

}  // namespace

int main() {
  std::uint64_t scalar_checksum = 0;
  std::uint64_t fast_checksum = 0;
  const Percentiles scalar =
      run_bench(pluto::swtcon::mapped_sweep_scalar, &scalar_checksum);
  const Percentiles fast =
      run_bench(pluto::swtcon::mapped_sweep, &fast_checksum);

  std::printf("mapped sweep: %dx%d dense lanes, %d-phase record, "
              "host-indicative target %.3f ms\n",
              kPaddedSourceWidth, kLogicalHeight, kPhases,
              kScanBudgetUs / 1000.0);
  print_row("scalar", scalar);
  print_row("dispatch", fast);
  std::printf("speedup=%5.2fx  checksums=%llu/%llu  gate=%s\n",
              scalar.p95_us / fast.p95_us,
              static_cast<unsigned long long>(scalar_checksum),
              static_cast<unsigned long long>(fast_checksum),
              fast.p95_us < kScanBudgetUs ? "PASS" : "FAIL");

  // This is a host guardrail, not a substitute for the device/A55 run.  It
  // intentionally fails when the host dispatch already misses one 85 Hz scan
  // period; such a build cannot plausibly meet the slower-core device gate.
  return fast.p95_us < kScanBudgetUs ? 0 : 2;
}
