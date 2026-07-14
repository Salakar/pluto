#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <vector>

#include "presenter/swtcon/xochitl_history_state.h"

namespace {

using Clock = std::chrono::steady_clock;
using State = pluto::swtcon::XochitlHistoryState;

double microseconds(Clock::duration duration) {
  return std::chrono::duration<double, std::micro>(duration).count();
}

bool run_fast_roi(State *state) {
  constexpr std::int32_t kWidth = 96;
  constexpr std::int32_t kHeight = 96;
  constexpr int kIterations = 500;
  std::vector<std::uint8_t> raw(static_cast<std::size_t>(kWidth) * kHeight);
  for (std::int32_t y = 0; y < kHeight; ++y) {
    for (std::int32_t x = 0; x < kWidth; ++x) {
      raw[static_cast<std::size_t>(y) * kWidth + x] =
          static_cast<std::uint8_t>((x + y) & 7);
    }
  }

  Clock::duration prepare_total{};
  Clock::duration commit_total{};
  std::size_t journal_bytes = 0;
  for (int warmup = 0; warmup < 5; ++warmup) {
    const auto prepared =
        state->prepare_fast_source({100, 300, 195, 395}, raw, kWidth, 25.0f);
    if (!prepared || state->commit(*prepared.operation) !=
                         State::FinalizeStatus::kCommitted) {
      return false;
    }
  }
  for (int iteration = 0; iteration < kIterations; ++iteration) {
    const auto prepare_begin = Clock::now();
    const auto prepared =
        state->prepare_fast_source({100, 300, 195, 395}, raw, kWidth, 25.0f);
    const auto prepare_end = Clock::now();
    if (!prepared) {
      return false;
    }
    journal_bytes = prepared.operation->journal_storage_bytes();
    const auto commit_begin = Clock::now();
    if (state->commit(*prepared.operation) !=
        State::FinalizeStatus::kCommitted) {
      return false;
    }
    const auto commit_end = Clock::now();
    prepare_total += prepare_end - prepare_begin;
    commit_total += commit_end - commit_begin;
  }

  std::cout << "history_bench kind=fast_roi96 lanes=" << kWidth * kHeight
            << " iterations=" << kIterations
            << " prepare_us_avg=" << microseconds(prepare_total) / kIterations
            << " commit_us_avg=" << microseconds(commit_total) / kIterations
            << " journal_owned_bytes=" << journal_bytes << '\n';
  return true;
}

bool run_full_legacy(State *state) {
  constexpr std::int32_t kExecutionWidth = 960;
  constexpr std::int32_t kHeight = State::kLogicalHeight;
  constexpr int kIterations = 10;
  std::vector<std::uint8_t> raw(static_cast<std::size_t>(kExecutionWidth) *
                                kHeight);
  for (std::int32_t y = 0; y < kHeight; ++y) {
    for (std::int32_t x = 0; x < kExecutionWidth; ++x) {
      raw[static_cast<std::size_t>(y) * kExecutionWidth + x] =
          static_cast<std::uint8_t>((x + y) & 7);
    }
  }
  std::vector<std::int16_t> delta(State::kTransitionCount, 0);

  const auto warmup = state->prepare_legacy(
      State::Mode::kFull,
      {0, 0, State::kLogicalWidth - 1, State::kLogicalHeight - 1}, raw,
      kExecutionWidth, delta);
  if (!warmup ||
      state->discard(*warmup.operation) != State::FinalizeStatus::kDiscarded) {
    return false;
  }

  Clock::duration prepare_total{};
  Clock::duration commit_total{};
  Clock::duration prepare_min = Clock::duration::max();
  Clock::duration prepare_max{};
  Clock::duration commit_min = Clock::duration::max();
  Clock::duration commit_max{};
  std::size_t lanes = 0;
  std::size_t journal_bytes = 0;
  for (int iteration = 0; iteration < kIterations; ++iteration) {
    const auto prepare_begin = Clock::now();
    const auto prepared = state->prepare_legacy(
        State::Mode::kFull,
        {0, 0, State::kLogicalWidth - 1, State::kLogicalHeight - 1}, raw,
        kExecutionWidth, delta);
    const auto prepare_end = Clock::now();
    if (!prepared) {
      return false;
    }
    const auto commit_begin = Clock::now();
    if (state->commit(*prepared.operation) !=
        State::FinalizeStatus::kCommitted) {
      return false;
    }
    const auto commit_end = Clock::now();
    const Clock::duration prepare_elapsed = prepare_end - prepare_begin;
    const Clock::duration commit_elapsed = commit_end - commit_begin;
    prepare_total += prepare_elapsed;
    commit_total += commit_elapsed;
    prepare_min = std::min(prepare_min, prepare_elapsed);
    prepare_max = std::max(prepare_max, prepare_elapsed);
    commit_min = std::min(commit_min, commit_elapsed);
    commit_max = std::max(commit_max, commit_elapsed);
    lanes = prepared.operation->lanes().size();
    journal_bytes = prepared.operation->journal_storage_bytes();
  }

  std::cout << "history_bench kind=legacy_full954x1696 lanes=" << lanes
            << " iterations=" << kIterations
            << " prepare_us_avg=" << microseconds(prepare_total) / kIterations
            << " prepare_us_min=" << microseconds(prepare_min)
            << " prepare_us_max=" << microseconds(prepare_max)
            << " commit_us_avg=" << microseconds(commit_total) / kIterations
            << " commit_us_min=" << microseconds(commit_min)
            << " commit_us_max=" << microseconds(commit_max)
            << " journal_owned_bytes=" << journal_bytes << '\n';
  return true;
}

} // namespace

int main() {
  std::cout << std::fixed << std::setprecision(2);
  State state;
  if (!state.initialize_cold_clear(0)) {
    return 2;
  }
  std::cout << "history_bench state_owned_plane_bytes="
            << state.owned_plane_storage_bytes()
            << " history_pixels=" << State::kStoragePixels << '\n';
  if (!run_fast_roi(&state)) {
    return 3;
  }
  // Fixture allocation and cold initialization remain outside full-op timing.
  if (!state.initialize_cold_clear(0)) {
    return 4;
  }
  return run_full_legacy(&state) ? 0 : 5;
}
