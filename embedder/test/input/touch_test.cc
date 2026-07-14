#include "input/evdev.h"
#include "input/record.h"
#include "input/touch.h"
#include "input/transform.h"

#include <gtest/gtest.h>

#include <string>
#include <vector>

namespace pluto {

std::ostream& operator<<(std::ostream& out, SystemEdgeGesture gesture) {
  return out << static_cast<int>(gesture);
}

}  // namespace pluto

namespace {

std::string fixture_path(const char* name) {
  return std::string(PLUTO_INPUT_FIXTURE_DIR) + "/" + name;
}

std::vector<pluto::TouchTrackerOutput> run_touch_fixture(
    const char* fixture,
    pluto::TouchTracker* tracker) {
  pluto::ReplaySource source =
      pluto::ReplaySource::from_jsonl_file(fixture_path(fixture));
  std::vector<pluto::TouchTrackerOutput> outputs;
  while (true) {
    pluto::SourceResult batch = source.next_batch();
    if (batch.status == pluto::EvdevStatus::kAgain) {
      break;
    }
    pluto::TouchTrackerOutput out = tracker->consume_batch(batch.events);
    if (out.count > 0) {
      outputs.push_back(out);
    }
  }
  return outputs;
}

pluto::TouchTrackerOutput gesture_frame(
    pluto::Orientation orientation,
    pluto::TouchPhase phase,
    pluto::Point first_logical,
    pluto::Point second_logical,
    int64_t ts_us,
    uint8_t first_slot = 0,
    int64_t second_contact_delay_us = 1000) {
  pluto::TouchTrackerOutput output;
  const pluto::Point first = pluto::logical_to_panel(
      first_logical, 954.0f, 1696.0f, orientation);
  const pluto::Point second = pluto::logical_to_panel(
      second_logical, 954.0f, 1696.0f, orientation);
  output.count = 2;
  output.events[0] = pluto::TouchEvent{
      .ts_us = ts_us,
      .slot = first_slot,
      .phase = phase,
      .classification = pluto::TouchClassification::kFinger,
      .tracking_id = 10,
      .raw_x = static_cast<uint16_t>(first.x),
      .raw_y = static_cast<uint16_t>(first.y),
      .emit_to_flutter = true,
  };
  output.events[1] = pluto::TouchEvent{
      .ts_us = ts_us + second_contact_delay_us,
      .slot = static_cast<uint8_t>(first_slot + 1),
      .phase = phase,
      .classification = pluto::TouchClassification::kFinger,
      .tracking_id = 11,
      .raw_x = static_cast<uint16_t>(second.x),
      .raw_y = static_cast<uint16_t>(second.y),
      .emit_to_flutter = true,
  };
  return output;
}

}  // namespace

TEST(AppSwitcherGestureTest, RecognizesParallelPortraitBottomEdgeSwipe) {
  pluto::SystemEdgeGestureRecognizer gesture;
  const pluto::AffineTransform identity;
  EXPECT_EQ(gesture.consume(
      gesture_frame(pluto::Orientation::kDeg0, pluto::TouchPhase::kBegan,
                    {300.0f, 1660.0f}, {450.0f, 1660.0f}, 1000000),
      identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f, 254.0f),
      pluto::SystemEdgeGesture::kNone);
  EXPECT_EQ(gesture.consume(
      gesture_frame(pluto::Orientation::kDeg0, pluto::TouchPhase::kMoved,
                    {304.0f, 1555.0f}, {454.0f, 1550.0f}, 1150000),
      identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f, 254.0f),
      pluto::SystemEdgeGesture::kAppSwitcher);
}

TEST(AppSwitcherGestureTest, UsesRotatedLogicalBottomInLandscape) {
  pluto::SystemEdgeGestureRecognizer gesture;
  const pluto::AffineTransform identity;
  EXPECT_EQ(gesture.consume(
      gesture_frame(pluto::Orientation::kDeg90, pluto::TouchPhase::kBegan,
                    {650.0f, 930.0f}, {800.0f, 930.0f}, 2000000),
      identity, pluto::Orientation::kDeg90, 954.0f, 1696.0f, 254.0f),
      pluto::SystemEdgeGesture::kNone);
  EXPECT_EQ(gesture.consume(
      gesture_frame(pluto::Orientation::kDeg90, pluto::TouchPhase::kMoved,
                    {650.0f, 825.0f}, {800.0f, 820.0f}, 2150000),
      identity, pluto::Orientation::kDeg90, 954.0f, 1696.0f, 254.0f),
      pluto::SystemEdgeGesture::kAppSwitcher);
}

TEST(AppSwitcherGestureTest, AcceptsRelaxedEdgePlacementAndMotion) {
  pluto::SystemEdgeGestureRecognizer gesture;
  const pluto::AffineTransform identity;
  EXPECT_EQ(gesture.consume(
      gesture_frame(pluto::Orientation::kDeg0, pluto::TouchPhase::kBegan,
                    {220.0f, 1450.0f}, {620.0f, 1450.0f}, 2200000, 0,
                    300000),
      identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f, 254.0f),
      pluto::SystemEdgeGesture::kNone);
  EXPECT_EQ(gesture.consume(
      gesture_frame(pluto::Orientation::kDeg0, pluto::TouchPhase::kMoved,
                    {365.0f, 1380.0f}, {780.0f, 1360.0f}, 2700000, 0,
                    300000),
      identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f, 254.0f),
      pluto::SystemEdgeGesture::kAppSwitcher);
}

TEST(SystemEdgeGestureTest, RecognizesTopHomeSwipeInBothOrientations) {
  const pluto::AffineTransform identity;
  pluto::SystemEdgeGestureRecognizer portrait;
  EXPECT_EQ(portrait.consume(
                gesture_frame(pluto::Orientation::kDeg0,
                              pluto::TouchPhase::kBegan, {300.0f, 24.0f},
                              {450.0f, 24.0f}, 2400000),
                identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f,
                254.0f),
            pluto::SystemEdgeGesture::kNone);
  EXPECT_EQ(portrait.consume(
                gesture_frame(pluto::Orientation::kDeg0,
                              pluto::TouchPhase::kMoved, {302.0f, 132.0f},
                              {452.0f, 136.0f}, 2550000),
                identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f,
                254.0f),
            pluto::SystemEdgeGesture::kHome);

  pluto::SystemEdgeGestureRecognizer landscape;
  EXPECT_EQ(landscape.consume(
                gesture_frame(pluto::Orientation::kDeg90,
                              pluto::TouchPhase::kBegan, {650.0f, 24.0f},
                              {800.0f, 24.0f}, 2700000),
                identity, pluto::Orientation::kDeg90, 954.0f, 1696.0f,
                254.0f),
            pluto::SystemEdgeGesture::kNone);
  EXPECT_EQ(landscape.consume(
                gesture_frame(pluto::Orientation::kDeg90,
                              pluto::TouchPhase::kMoved, {650.0f, 130.0f},
                              {800.0f, 134.0f}, 2850000),
                identity, pluto::Orientation::kDeg90, 954.0f, 1696.0f,
                254.0f),
            pluto::SystemEdgeGesture::kHome);
}

TEST(SystemEdgeGestureTest, AcceptsRelaxedTopHomePlacementAndUnevenMotion) {
  const pluto::AffineTransform identity;
  pluto::SystemEdgeGestureRecognizer gesture;
  EXPECT_EQ(gesture.consume(
                gesture_frame(pluto::Orientation::kDeg0,
                              pluto::TouchPhase::kBegan, {220.0f, 120.0f},
                              {620.0f, 120.0f}, 2800000, 0, 300000),
                identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f,
                254.0f),
            pluto::SystemEdgeGesture::kNone);
  EXPECT_EQ(gesture.consume(
                gesture_frame(pluto::Orientation::kDeg0,
                              pluto::TouchPhase::kMoved, {370.0f, 190.0f},
                              {780.0f, 275.0f}, 3300000, 0, 300000),
                identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f,
                254.0f),
            pluto::SystemEdgeGesture::kHome);
}

TEST(SystemEdgeGestureTest, TopHomeSwipeMustBeginAtPhysicalEdge) {
  const pluto::AffineTransform identity;
  pluto::SystemEdgeGestureRecognizer gesture;
  EXPECT_EQ(gesture.consume(
                gesture_frame(pluto::Orientation::kDeg0,
                              pluto::TouchPhase::kBegan, {300.0f, 180.0f},
                              {450.0f, 180.0f}, 3900000),
                identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f,
                254.0f),
            pluto::SystemEdgeGesture::kNone);
  EXPECT_EQ(gesture.consume(
                gesture_frame(pluto::Orientation::kDeg0,
                              pluto::TouchPhase::kMoved, {300.0f, 300.0f},
                              {450.0f, 300.0f}, 4050000),
                identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f,
                254.0f),
            pluto::SystemEdgeGesture::kNone);
}

TEST(AppSwitcherGestureTest, RejectsMiddleScreenAndWidelySeparatedContacts) {
  pluto::SystemEdgeGestureRecognizer middle;
  const pluto::AffineTransform identity;
  EXPECT_EQ(middle.consume(
      gesture_frame(pluto::Orientation::kDeg0, pluto::TouchPhase::kBegan,
                    {300.0f, 900.0f}, {450.0f, 900.0f}, 3000000),
      identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f, 254.0f),
      pluto::SystemEdgeGesture::kNone);
  EXPECT_EQ(middle.consume(
      gesture_frame(pluto::Orientation::kDeg0, pluto::TouchPhase::kMoved,
                    {300.0f, 780.0f}, {450.0f, 780.0f}, 3150000),
      identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f, 254.0f),
      pluto::SystemEdgeGesture::kNone);

  pluto::SystemEdgeGestureRecognizer wide;
  EXPECT_EQ(wide.consume(
      gesture_frame(pluto::Orientation::kDeg0, pluto::TouchPhase::kBegan,
                    {100.0f, 1660.0f}, {700.0f, 1660.0f}, 4000000),
      identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f, 254.0f),
      pluto::SystemEdgeGesture::kNone);
  EXPECT_EQ(wide.consume(
      gesture_frame(pluto::Orientation::kDeg0, pluto::TouchPhase::kMoved,
                    {100.0f, 1540.0f}, {700.0f, 1540.0f}, 4150000),
      identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f, 254.0f),
      pluto::SystemEdgeGesture::kNone);
}

TEST(AppSwitcherGestureTest, PalmReclassificationDoesNotPoisonLaterSlots) {
  pluto::SystemEdgeGestureRecognizer gesture;
  const pluto::AffineTransform identity;
  EXPECT_EQ(gesture.consume(
      gesture_frame(pluto::Orientation::kDeg0, pluto::TouchPhase::kBegan,
                    {300.0f, 1660.0f}, {450.0f, 1660.0f}, 5000000),
      identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f, 254.0f),
      pluto::SystemEdgeGesture::kNone);

  pluto::TouchTrackerOutput terminal;
  terminal.count = 2;
  terminal.events[0] = pluto::TouchEvent{
      .ts_us = 5050000,
      .slot = 0,
      .phase = pluto::TouchPhase::kCancelled,
      .classification = pluto::TouchClassification::kPalm,
      .tracking_id = 10,
      .emit_to_flutter = true,
  };
  terminal.events[1] = pluto::TouchEvent{
      .ts_us = 5051000,
      .slot = 1,
      .phase = pluto::TouchPhase::kEnded,
      .classification = pluto::TouchClassification::kFinger,
      .tracking_id = 11,
      .emit_to_flutter = true,
  };
  EXPECT_EQ(gesture.consume(terminal, identity, pluto::Orientation::kDeg0,
                            954.0f, 1696.0f, 254.0f),
            pluto::SystemEdgeGesture::kNone);

  EXPECT_EQ(gesture.consume(
      gesture_frame(pluto::Orientation::kDeg0, pluto::TouchPhase::kBegan,
                    {300.0f, 1660.0f}, {450.0f, 1660.0f}, 5200000, 2),
      identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f, 254.0f),
      pluto::SystemEdgeGesture::kNone);
  EXPECT_EQ(gesture.consume(
      gesture_frame(pluto::Orientation::kDeg0, pluto::TouchPhase::kMoved,
                    {300.0f, 1550.0f}, {450.0f, 1550.0f}, 5350000, 2),
      identity, pluto::Orientation::kDeg0, 954.0f, 1696.0f, 254.0f),
      pluto::SystemEdgeGesture::kAppSwitcher);
}

TEST(PlutoTouchTrackerTest, LargeTouchMajorCancelsFingerAsPalm) {
  pluto::TouchTracker tracker;
  const std::vector<pluto::TouchTrackerOutput> outputs =
      run_touch_fixture("touch_palm_while_writing.jsonl", &tracker);
  ASSERT_EQ(outputs.size(), 4u);
  ASSERT_EQ(outputs[0].count, 1u);
  EXPECT_EQ(static_cast<int>(outputs[0].events[0].phase),
            static_cast<int>(pluto::TouchPhase::kBegan));
  EXPECT_TRUE(outputs[0].events[0].emit_to_flutter);
  EXPECT_EQ(static_cast<int>(outputs[2].events[0].phase),
            static_cast<int>(pluto::TouchPhase::kCancelled));
  EXPECT_EQ(static_cast<int>(outputs[2].events[0].classification),
            static_cast<int>(pluto::TouchClassification::kPalm));
  EXPECT_TRUE(outputs[2].events[0].emit_to_flutter);
  EXPECT_FALSE(outputs[3].events[0].emit_to_flutter);
}

TEST(PlutoTouchTrackerTest, PenProximitySuppressesBirthAndLinger) {
  pluto::TouchTracker tracker;
  tracker.set_pen_in_range(true, 0);
  const std::vector<pluto::RawEvent> events =
      pluto::read_jsonl_events_file(fixture_path("touch_palm_while_writing.jsonl"));
  std::vector<pluto::RawEvent> first_batch;
  for (const pluto::RawEvent& event : events) {
    first_batch.push_back(event);
    if (event.type == pluto::kEvSyn && event.code == pluto::kSynReport) {
      break;
    }
  }
  pluto::TouchTrackerOutput suppressed = tracker.consume_batch(first_batch);
  ASSERT_EQ(suppressed.count, 1u);
  EXPECT_EQ(static_cast<int>(suppressed.events[0].classification),
            static_cast<int>(pluto::TouchClassification::kPenSuppressed));
  EXPECT_FALSE(suppressed.events[0].emit_to_flutter);

  tracker.set_pen_in_range(false, 1000);
  pluto::TouchTracker after_linger;
  after_linger.set_pen_in_range(true, 0);
  after_linger.set_pen_in_range(false, 100000);
  const std::vector<pluto::TouchTrackerOutput> outputs =
      run_touch_fixture("touch_two_finger_after_linger.jsonl", &after_linger);
  ASSERT_EQ(outputs.size(), 2u);
  ASSERT_EQ(outputs[0].count, 2u);
  EXPECT_EQ(static_cast<int>(outputs[0].events[0].classification),
            static_cast<int>(pluto::TouchClassification::kFinger));
  EXPECT_TRUE(outputs[0].events[0].emit_to_flutter);
  EXPECT_TRUE(outputs[0].events[1].emit_to_flutter);
}

TEST(PlutoTouchTrackerTest, ExistingFingerCancelsWhenPenEntersRange) {
  pluto::TouchTracker tracker;
  const std::vector<pluto::RawEvent> events =
      pluto::read_jsonl_events_file(fixture_path("touch_palm_while_writing.jsonl"));
  std::vector<pluto::RawEvent> first_batch;
  for (const pluto::RawEvent& event : events) {
    first_batch.push_back(event);
    if (event.type == pluto::kEvSyn && event.code == pluto::kSynReport) {
      break;
    }
  }
  pluto::TouchTrackerOutput began = tracker.consume_batch(first_batch);
  ASSERT_EQ(began.count, 1u);
  ASSERT_TRUE(began.events[0].emit_to_flutter);

  tracker.set_pen_in_range(true, 1050);
  pluto::TouchTrackerOutput canceled =
      tracker.consume(pluto::RawEvent{.ts_us = 1050,
                                        .type = pluto::kEvSyn,
                                        .code = pluto::kSynReport,
                                        .value = 0});
  ASSERT_EQ(canceled.count, 1u);
  EXPECT_EQ(static_cast<int>(canceled.events[0].phase),
            static_cast<int>(pluto::TouchPhase::kCancelled));
  EXPECT_EQ(static_cast<int>(canceled.events[0].classification),
            static_cast<int>(pluto::TouchClassification::kPenSuppressed));
}

TEST(PenTouchArbiterTest, PublishedHoverSuppressesTouchBirth) {
  pluto::TouchTracker tracker;
  pluto::PenTouchArbiter arbiter;
  arbiter.publish(true, 900);
  EXPECT_EQ(arbiter.sync(&tracker, 900).count, 0u);

  const std::vector<pluto::RawEvent> events =
      pluto::read_jsonl_events_file(
          fixture_path("touch_palm_while_writing.jsonl"));
  std::vector<pluto::RawEvent> first_batch;
  for (const pluto::RawEvent& event : events) {
    first_batch.push_back(event);
    if (event.type == pluto::kEvSyn && event.code == pluto::kSynReport) {
      break;
    }
  }
  const pluto::TouchTrackerOutput suppressed =
      tracker.consume_batch(first_batch);
  ASSERT_EQ(suppressed.count, 1u);
  EXPECT_EQ(static_cast<int>(suppressed.events[0].classification),
            static_cast<int>(pluto::TouchClassification::kPenSuppressed));
  EXPECT_FALSE(suppressed.events[0].emit_to_flutter);
}

TEST(PenTouchArbiterTest, FastHoverPulseCancelsAndArmsLinger) {
  pluto::TouchTracker tracker;
  const std::vector<pluto::RawEvent> events =
      pluto::read_jsonl_events_file(
          fixture_path("touch_palm_while_writing.jsonl"));
  std::vector<pluto::RawEvent> first_batch;
  for (const pluto::RawEvent& event : events) {
    first_batch.push_back(event);
    if (event.type == pluto::kEvSyn && event.code == pluto::kSynReport) {
      break;
    }
  }
  ASSERT_TRUE(tracker.consume_batch(first_batch).events[0].emit_to_flutter);

  pluto::PenTouchArbiter arbiter;
  arbiter.publish(true, 1050);
  arbiter.publish(false, 1060);
  const pluto::TouchTrackerOutput canceled = arbiter.sync(&tracker, 1070);
  ASSERT_EQ(canceled.count, 1u);
  EXPECT_EQ(static_cast<int>(canceled.events[0].phase),
            static_cast<int>(pluto::TouchPhase::kCancelled));
  EXPECT_EQ(static_cast<int>(canceled.events[0].classification),
            static_cast<int>(pluto::TouchClassification::kPenSuppressed));
  EXPECT_TRUE(tracker.pen_suppression_active(1070));
}

TEST(PlutoTouchTrackerTest, TwoFingerFixturePassesThroughForFlutterGestures) {
  pluto::TouchTracker tracker;
  const std::vector<pluto::TouchTrackerOutput> outputs =
      run_touch_fixture("touch_two_finger_after_linger.jsonl", &tracker);
  ASSERT_EQ(outputs.size(), 2u);
  ASSERT_EQ(outputs[0].count, 2u);
  EXPECT_EQ(static_cast<int>(outputs[0].events[0].phase),
            static_cast<int>(pluto::TouchPhase::kBegan));
  EXPECT_EQ(static_cast<int>(outputs[0].events[1].phase),
            static_cast<int>(pluto::TouchPhase::kBegan));
  EXPECT_TRUE(outputs[0].events[0].emit_to_flutter);
  EXPECT_TRUE(outputs[0].events[1].emit_to_flutter);
  ASSERT_EQ(outputs[1].count, 2u);
  EXPECT_EQ(static_cast<int>(outputs[1].events[0].phase),
            static_cast<int>(pluto::TouchPhase::kEnded));
  EXPECT_EQ(static_cast<int>(outputs[1].events[1].phase),
            static_cast<int>(pluto::TouchPhase::kEnded));
}
