#include "presenter/swtcon/hygiene_fsm.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <set>
#include <vector>

namespace {

using pluto::swtcon::HygieneAction;
using pluto::swtcon::HygieneFsm;
using pluto::swtcon::HygieneFsmConfig;
using pluto::swtcon::HygieneState;

HygieneFsmConfig config_with_max(std::uint16_t rail_pass_max) {
  HygieneFsmConfig config;
  config.rail_pass_max = rail_pass_max;
  return config;
}

// The gtest shim streams compared values (no enum printers), so enum
// comparisons go through EXPECT_TRUE/ASSERT_TRUE.

// ---- targeted behavior pins ----------------------------------------------

TEST(HygieneFsmTest, RailOverGrayPrependsWhiteFlush) {
  HygieneFsm fsm;
  ASSERT_TRUE(fsm.configure(4, config_with_max(16)));

  // RAIL_ENTER: A2 over gray content requires the DU white flush.
  EXPECT_TRUE(fsm.on_admit(0, /*rail_request=*/true) ==
              HygieneAction::kWhiteFlushFirst);
  EXPECT_TRUE(fsm.state(0) == HygieneState::kRailEnter);
  fsm.on_pass_end(0);  // flush landed
  EXPECT_TRUE(fsm.state(0) == HygieneState::kRailActive);

  // Rail admissions are now free; passes count at boundaries.
  EXPECT_TRUE(fsm.on_admit(0, true) == HygieneAction::kAdmit);
  fsm.on_pass_end(0);
  EXPECT_EQ(fsm.rail_passes(0), 1);
  EXPECT_TRUE(fsm.on_admit(0, true) == HygieneAction::kAdmit);
  fsm.on_pass_end(0);
  EXPECT_EQ(fsm.rail_passes(0), 2);
  EXPECT_EQ(fsm.stats().rail_enters, 1u);

  // Other tiles are independent.
  EXPECT_TRUE(fsm.state(1) == HygieneState::kGrayClean);
  EXPECT_TRUE(fsm.on_admit(1, /*rail_request=*/false) ==
              HygieneAction::kAdmit);
  EXPECT_TRUE(fsm.state(1) == HygieneState::kGrayClean);
}

TEST(HygieneFsmTest, GrayOverRailExitsViaWhiteThenRerender) {
  HygieneFsm fsm;
  ASSERT_TRUE(fsm.configure(1, config_with_max(16)));
  EXPECT_TRUE(fsm.on_admit(0, true) == HygieneAction::kWhiteFlushFirst);
  fsm.on_pass_end(0);
  EXPECT_TRUE(fsm.on_admit(0, true) == HygieneAction::kAdmit);
  fsm.on_pass_end(0);

  // RAIL_EXIT: white first, then the GC16 re-render.
  EXPECT_TRUE(fsm.on_admit(0, /*rail_request=*/false) ==
              HygieneAction::kExitFlushFirst);
  EXPECT_TRUE(fsm.state(0) == HygieneState::kRailExitWhite);
  // Anything arriving mid-flush waits for the boundary.
  EXPECT_TRUE(fsm.on_admit(0, false) == HygieneAction::kDefer);
  EXPECT_TRUE(fsm.on_admit(0, true) == HygieneAction::kDefer);
  fsm.on_pass_end(0);  // white landed
  EXPECT_TRUE(fsm.state(0) == HygieneState::kRailExitRerender);
  EXPECT_TRUE(fsm.on_admit(0, true) == HygieneAction::kDefer);
  EXPECT_TRUE(fsm.on_admit(0, false) == HygieneAction::kAdmit);  // re-render
  fsm.on_pass_end(0);  // re-render landed
  EXPECT_TRUE(fsm.state(0) == HygieneState::kGrayClean);
  EXPECT_EQ(fsm.rail_passes(0), 0);
  EXPECT_EQ(fsm.stats().rail_exits, 1u);
  EXPECT_EQ(fsm.stats().forced_exits, 0u);
}

TEST(HygieneFsmTest, RailPassMaxForcesExitEvenForRailRequests) {
  HygieneFsm fsm;
  ASSERT_TRUE(fsm.configure(1, config_with_max(2)));
  EXPECT_TRUE(fsm.on_admit(0, true) == HygieneAction::kWhiteFlushFirst);
  fsm.on_pass_end(0);
  for (int pass = 0; pass < 2; ++pass) {
    EXPECT_FALSE(fsm.exit_required(0));
    EXPECT_TRUE(fsm.on_admit(0, true) == HygieneAction::kAdmit);
    fsm.on_pass_end(0);
  }
  // Budget spent: even without a settle trigger the tile must exit.
  EXPECT_TRUE(fsm.exit_required(0));
  EXPECT_TRUE(fsm.on_admit(0, true) == HygieneAction::kExitFlushFirst);
  EXPECT_TRUE(fsm.state(0) == HygieneState::kRailExitWhite);
  EXPECT_EQ(fsm.stats().forced_exits, 1u);
  fsm.on_pass_end(0);  // white landed
  fsm.on_pass_end(0);  // re-render landed
  EXPECT_TRUE(fsm.state(0) == HygieneState::kGrayClean);
  EXPECT_EQ(fsm.rail_passes(0), 0);
}

TEST(HygieneFsmTest, SchedulerInitiatedExitOnlyLegalWhileRailActive) {
  HygieneFsm fsm;
  ASSERT_TRUE(fsm.configure(1, config_with_max(4)));
  EXPECT_FALSE(fsm.begin_exit(0));  // gray tile: nothing to exit
  EXPECT_TRUE(fsm.on_admit(0, true) == HygieneAction::kWhiteFlushFirst);
  EXPECT_FALSE(fsm.begin_exit(0));  // enter flush in flight
  fsm.on_pass_end(0);
  EXPECT_TRUE(fsm.begin_exit(0));  // settle authority forces the exit
  EXPECT_TRUE(fsm.state(0) == HygieneState::kRailExitWhite);
  EXPECT_FALSE(fsm.begin_exit(0));
}

TEST(HygieneFsmTest, RejectsEmptyConfiguration) {
  HygieneFsm fsm;
  EXPECT_FALSE(fsm.configure(0, config_with_max(4)));
  EXPECT_FALSE(fsm.configured());
}

// ---- model check (A2 legality) --------------------------------------------
//
// Exhaustive small-state enumeration: from every reachable configuration
// (state, rail_passes) apply every event, simulate the caller contract,
// and assert that no sequence can emit an illegal drive:
//   R1: a rail CONTENT pass runs only in RAIL_ACTIVE under budget;
//   R2: a gray pass runs only in GRAY_CLEAN or RAIL_EXIT_RERENDER;
//   R3: rail_passes never exceeds rail_pass_max;
//   R4: every transition lands in a defined state and the reachable set is
//       exactly the five states (with their legal pass counts).
TEST(HygieneFsmTest, ModelCheckExhaustiveStateEventEnumeration) {
  constexpr std::uint16_t kMax = 3;

  struct Config {
    HygieneState state;
    std::uint16_t passes;
    bool operator<(const Config& other) const {
      return state != other.state ? state < other.state
                                  : passes < other.passes;
    }
  };
  enum class Event { kAdmitGray, kAdmitRail, kPassEnd, kBeginExit };
  const Event kEvents[] = {Event::kAdmitGray, Event::kAdmitRail,
                           Event::kPassEnd, Event::kBeginExit};

  // Each reachable config is regenerated by replaying its BFS event path
  // from GRAY_CLEAN, so the enumeration only ever exercises legal
  // sequences of the public API.
  struct Node {
    Config config;
    std::vector<Event> path;
  };

  const auto apply_event = [](HygieneFsm* fsm, Event event) {
    switch (event) {
      case Event::kAdmitGray:
        return fsm->on_admit(0, false);
      case Event::kAdmitRail:
        return fsm->on_admit(0, true);
      case Event::kPassEnd:
        fsm->on_pass_end(0);
        return HygieneAction::kDefer;  // no admission action
      case Event::kBeginExit:
        (void)fsm->begin_exit(0);
        return HygieneAction::kDefer;
    }
    return HygieneAction::kDefer;
  };

  std::set<Config> visited;
  std::vector<Node> queue;
  queue.push_back({{HygieneState::kGrayClean, 0}, {}});
  visited.insert(queue.front().config);
  std::size_t transitions_checked = 0;

  for (std::size_t head = 0; head < queue.size(); ++head) {
    const Node node = queue[head];
    for (const Event event : kEvents) {
      HygieneFsm fsm;
      ASSERT_TRUE(fsm.configure(1, config_with_max(kMax)));
      for (const Event step : node.path) {
        (void)apply_event(&fsm, step);
      }
      ASSERT_TRUE(fsm.state(0) == node.config.state);
      ASSERT_EQ(fsm.rail_passes(0), node.config.passes);

      const HygieneState before = fsm.state(0);
      const HygieneAction action = apply_event(&fsm, event);
      const bool emitted_rail_content =
          event == Event::kAdmitRail && action == HygieneAction::kAdmit;
      const bool emitted_gray =
          event == Event::kAdmitGray && action == HygieneAction::kAdmit;
      ++transitions_checked;

      // R1: rail content only in RAIL_ACTIVE with budget headroom. (The
      // enter/exit white flushes are commanded via kWhiteFlushFirst /
      // kExitFlushFirst, never as a plain rail kAdmit.)
      if (emitted_rail_content) {
        ASSERT_TRUE(before == HygieneState::kRailActive);
        ASSERT_TRUE(node.config.passes < kMax);
      }
      // R2: gray passes only on clean tiles or as the exit re-render.
      if (emitted_gray) {
        ASSERT_TRUE(before == HygieneState::kGrayClean ||
                    before == HygieneState::kRailExitRerender);
      }
      // Flush-first actions land in the matching flush state.
      if (action == HygieneAction::kWhiteFlushFirst) {
        ASSERT_TRUE(fsm.state(0) == HygieneState::kRailEnter);
      }
      if (action == HygieneAction::kExitFlushFirst) {
        ASSERT_TRUE(fsm.state(0) == HygieneState::kRailExitWhite);
      }
      // R3: budget bound holds after every event.
      ASSERT_TRUE(fsm.rail_passes(0) <= kMax);
      // R4: the landing state is one of the five states.
      const HygieneState after = fsm.state(0);
      ASSERT_TRUE(after == HygieneState::kGrayClean ||
                  after == HygieneState::kRailEnter ||
                  after == HygieneState::kRailActive ||
                  after == HygieneState::kRailExitWhite ||
                  after == HygieneState::kRailExitRerender);

      const Config landed{after, fsm.rail_passes(0)};
      if (visited.insert(landed).second) {
        std::vector<Event> path = node.path;
        path.push_back(event);
        queue.push_back({landed, path});
      }
    }
  }

  // The reachable set is exactly: GRAY_CLEAN(0), RAIL_ENTER(0),
  // RAIL_ACTIVE(0..kMax), RAIL_EXIT_WHITE(0..kMax),
  // RAIL_EXIT_RERENDER(0..kMax) — pass counts freeze during exits.
  std::set<Config> expected;
  expected.insert({HygieneState::kGrayClean, 0});
  expected.insert({HygieneState::kRailEnter, 0});
  for (std::uint16_t passes = 0; passes <= kMax; ++passes) {
    expected.insert({HygieneState::kRailActive, passes});
    expected.insert({HygieneState::kRailExitWhite, passes});
    expected.insert({HygieneState::kRailExitRerender, passes});
  }
  EXPECT_EQ(visited.size(), expected.size());
  for (const Config& config : expected) {
    EXPECT_EQ(visited.count(config), 1u)
        << "state=" << static_cast<int>(config.state)
        << " passes=" << config.passes;
  }
  // Every reachable config saw all four events.
  EXPECT_EQ(transitions_checked, visited.size() * 4);
}

}  // namespace
