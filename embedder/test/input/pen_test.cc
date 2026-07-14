#include "input/evdev.h"
#include "input/pen.h"
#include "input/transform.h"

#include <gtest/gtest.h>

#include <cmath>
#include <string>
#include <vector>

namespace {

std::string fixture_path(const char* name) {
  return std::string(PLUTO_INPUT_FIXTURE_DIR) + "/" + name;
}

void expect_near(float actual, float expected, float epsilon) {
  EXPECT_TRUE(std::fabs(actual - expected) <= epsilon)
      << "actual=" << actual << " expected=" << expected;
}

std::vector<pluto::PenTrackerOutput> run_pen_fixture(const char* fixture) {
  pluto::ReplaySource source =
      pluto::ReplaySource::from_jsonl_file(fixture_path(fixture));
  pluto::PenTracker tracker;
  std::vector<pluto::PenTrackerOutput> outputs;
  while (true) {
    pluto::SourceResult batch = source.next_batch();
    if (batch.status == pluto::EvdevStatus::kAgain) {
      break;
    }
    pluto::PenTrackerOutput out = tracker.consume_batch(batch.events);
    if (out.has_sample || out.pointer_count > 0) {
      outputs.push_back(out);
    }
  }
  return outputs;
}

}  // namespace

TEST(PlutoPenTrackerTest, HoverContactPressureTiltAndLiftSequence) {
  const std::vector<pluto::PenTrackerOutput> outputs =
      run_pen_fixture("pen_hover_pressure.jsonl");
  ASSERT_EQ(outputs.size(), 6u);

  ASSERT_EQ(outputs[0].pointer_count, 1u);
  EXPECT_EQ(static_cast<int>(outputs[0].pointer_events[0].phase),
            static_cast<int>(pluto::PointerPhase::kAdd));
  EXPECT_EQ(static_cast<int>(outputs[0].sample.tool),
            static_cast<int>(pluto::PenTool::kTip));

  EXPECT_EQ(static_cast<int>(outputs[1].pointer_events[0].phase),
            static_cast<int>(pluto::PointerPhase::kHover));
  EXPECT_EQ(static_cast<int>(outputs[2].pointer_events[0].phase),
            static_cast<int>(pluto::PointerPhase::kDown));
  EXPECT_EQ(static_cast<int>(outputs[3].pointer_events[0].phase),
            static_cast<int>(pluto::PointerPhase::kMove));
  EXPECT_EQ(outputs[3].sample.raw_pressure, 1024u);
  EXPECT_EQ(outputs[3].sample.tilt_x_cdeg, 100);
  EXPECT_EQ(outputs[3].sample.tilt_y_cdeg, -200);
  EXPECT_EQ(static_cast<int>(outputs[4].pointer_events[0].phase),
            static_cast<int>(pluto::PointerPhase::kUp));
  EXPECT_EQ(static_cast<int>(outputs[5].pointer_events[0].phase),
            static_cast<int>(pluto::PointerPhase::kRemove));

  const pluto::AffineTransform calibration =
      pluto::default_digitizer_to_panel(pluto::kMovePanelWidth,
                                          pluto::kMovePanelHeight, 0, 6760, 0,
                                          11960);
  const pluto_pen_ring_record record = pluto::make_pen_ring_record(
      outputs[3].sample, calibration, pluto::Orientation::kDeg0,
      pluto::kMovePanelWidth, pluto::kMovePanelHeight, 7);
  EXPECT_EQ(record.seq, 7u);
  EXPECT_EQ(record.raw_x, 3500u);
  EXPECT_EQ(record.raw_pressure, 1024u);
  EXPECT_TRUE((record.flags & kPlutoPenRingFlagContact) != 0);
  expect_near(record.x_logical, 3500.0f * 954.0f / 6760.0f, 0.01f);
  expect_near(record.y_logical, 6000.0f * 1696.0f / 11960.0f, 0.01f);
}

TEST(PlutoPenTrackerTest, EraserAndBarrelButtonsReachRingFlags) {
  const std::vector<pluto::PenTrackerOutput> outputs =
      run_pen_fixture("pen_eraser_barrel.jsonl");
  ASSERT_EQ(outputs.size(), 6u);
  EXPECT_EQ(static_cast<int>(outputs[0].sample.tool),
            static_cast<int>(pluto::PenTool::kEraser));
  EXPECT_TRUE(outputs[1].sample.btn_stylus);
  EXPECT_TRUE(outputs[1].sample.btn_stylus2);
  EXPECT_EQ(static_cast<int>(outputs[2].pointer_events[0].phase),
            static_cast<int>(pluto::PointerPhase::kDown));

  const pluto::AffineTransform calibration =
      pluto::default_digitizer_to_panel(pluto::kMovePanelWidth,
                                          pluto::kMovePanelHeight, 0, 6760, 0,
                                          11960);
  const pluto_pen_ring_record record = pluto::make_pen_ring_record(
      outputs[2].sample, calibration, pluto::Orientation::kDeg90,
      pluto::kMovePanelWidth, pluto::kMovePanelHeight, 3);
  EXPECT_TRUE((record.flags & kPlutoPenRingFlagEraser) != 0);
  EXPECT_TRUE((record.flags & kPlutoPenRingFlagButtonStylus) != 0);
  EXPECT_TRUE((record.flags & kPlutoPenRingFlagButtonStylus2) != 0);
  EXPECT_EQ(record.orientation_tag, 90u);
}

TEST(PlutoPenTrackerTest, SynDroppedSnapshotMarksResyncAndKeepsLegalPhases) {
  const std::vector<pluto::PenTrackerOutput> outputs =
      run_pen_fixture("syn_dropped_injected.jsonl");
  ASSERT_EQ(outputs.size(), 2u);
  EXPECT_EQ(static_cast<int>(outputs[0].pointer_events[0].phase),
            static_cast<int>(pluto::PointerPhase::kAdd));
  EXPECT_TRUE((outputs[1].sample.transition & pluto::kPenTransitionResync) != 0);
  EXPECT_TRUE((outputs[1].sample.transition & pluto::kPenTransitionDown) != 0);
  ASSERT_EQ(outputs[1].pointer_count, 1u);
  EXPECT_EQ(static_cast<int>(outputs[1].pointer_events[0].phase),
            static_cast<int>(pluto::PointerPhase::kDown));
}
