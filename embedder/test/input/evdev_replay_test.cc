#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "input/evdev.h"
#include "input/pen.h"
#include "input/record.h"

namespace {

std::string fixture_path(const char *name) {
  return std::string(PLUTO_INPUT_FIXTURE_DIR) + "/" + name;
}

std::vector<int> collect_pen_phases(const char *fixture) {
  pluto::ReplaySource source =
      pluto::ReplaySource::from_jsonl_file(fixture_path(fixture));
  pluto::PenTracker tracker;
  std::vector<int> phases;
  while (true) {
    pluto::SourceResult batch = source.next_batch();
    if (batch.status == pluto::EvdevStatus::kAgain) {
      break;
    }
    pluto::PenTrackerOutput out = tracker.consume_batch(batch.events);
    for (size_t i = 0; i < out.pointer_count; ++i) {
      phases.push_back(static_cast<int>(out.pointer_events[i].phase));
    }
  }
  return phases;
}

} // namespace

TEST(PlutoInputReplayTest, JsonlRoundTripsByteStableIntegers) {
  const std::vector<pluto::RawEvent> events =
      pluto::read_jsonl_events_file(fixture_path("record_round_trip.jsonl"));
  ASSERT_EQ(events.size(), 2u);
  EXPECT_EQ(events[0].ts_us, 42);
  EXPECT_EQ(events[0].type, pluto::kEvAbs);
  EXPECT_EQ(events[0].code, pluto::kAbsX);
  EXPECT_EQ(events[0].value, 1);

  const std::string encoded = pluto::write_jsonl_events(events);
  const std::vector<pluto::RawEvent> reparsed =
      pluto::parse_jsonl_events(encoded);
  ASSERT_EQ(reparsed.size(), events.size());
  EXPECT_EQ(reparsed[1].type, pluto::kEvSyn);
  EXPECT_EQ(reparsed[1].code, pluto::kSynReport);
}

TEST(PlutoInputReplayTest, ReplaySourceReturnsOneSynReportBatch) {
  pluto::ReplaySource source = pluto::ReplaySource::from_jsonl_file(
      fixture_path("pen_hover_pressure.jsonl"));

  pluto::SourceResult first = source.next_batch();
  EXPECT_EQ(static_cast<int>(first.status),
            static_cast<int>(pluto::EvdevStatus::kOk));
  ASSERT_EQ(first.events.size(), 5u);
  EXPECT_EQ(first.events.back().type, pluto::kEvSyn);
  EXPECT_EQ(first.events.back().code, pluto::kSynReport);

  pluto::SourceResult second = source.next_batch();
  EXPECT_EQ(static_cast<int>(second.status),
            static_cast<int>(pluto::EvdevStatus::kOk));
  ASSERT_EQ(second.events.size(), 3u);
}

namespace {

pluto::RawEvent abs_event(int64_t ts_us, uint16_t code, int32_t value) {
  return pluto::RawEvent{
      .ts_us = ts_us, .type = pluto::kEvAbs, .code = code, .value = value};
}

pluto::RawEvent syn_event(int64_t ts_us, uint16_t code) {
  return pluto::RawEvent{
      .ts_us = ts_us, .type = pluto::kEvSyn, .code = code, .value = 0};
}

} // namespace

// Regression: a single evdev read() carrying more than one SYN frame used to
// be truncated at the first SYN_REPORT, silently dropping every event already
// read after it (evdev.cc next_batch). All frames must be served, in order,
// one per take_frame call.
TEST(PlutoEvdevSynFrameBufferTest, MultiFrameReadDeliversEveryFrameInOrder) {
  pluto::SynFrameBuffer buffer;
  // One synthetic read: two full SYN frames plus the start of a third.
  const std::vector<pluto::RawEvent> read_events = {
      abs_event(100, pluto::kAbsX, 10),
      abs_event(100, pluto::kAbsY, 20),
      syn_event(100, pluto::kSynReport),
      abs_event(200, pluto::kAbsX, 11),
      abs_event(200, pluto::kAbsY, 21),
      abs_event(200, pluto::kAbsPressure, 900),
      syn_event(200, pluto::kSynReport),
      abs_event(300, pluto::kAbsX, 12),
  };
  for (const pluto::RawEvent &event : read_events) {
    buffer.push_event(event);
  }

  pluto::SynFrameBuffer::Frame first = buffer.take_frame();
  ASSERT_EQ(static_cast<int>(first.kind),
            static_cast<int>(pluto::SynFrameBuffer::FrameKind::kEvents));
  ASSERT_EQ(first.events.size(), 3u);
  EXPECT_EQ(first.events[0].value, 10);
  EXPECT_EQ(first.events[1].value, 20);
  EXPECT_EQ(first.events.back().code, pluto::kSynReport);

  // The frame the pre-fix code discarded.
  pluto::SynFrameBuffer::Frame second = buffer.take_frame();
  ASSERT_EQ(static_cast<int>(second.kind),
            static_cast<int>(pluto::SynFrameBuffer::FrameKind::kEvents));
  ASSERT_EQ(second.events.size(), 4u);
  EXPECT_EQ(second.events[0].value, 11);
  EXPECT_EQ(second.events[1].value, 21);
  EXPECT_EQ(second.events[2].value, 900);
  EXPECT_EQ(second.events.back().code, pluto::kSynReport);

  // The partial third frame is retained, not surfaced.
  pluto::SynFrameBuffer::Frame third = buffer.take_frame();
  EXPECT_EQ(static_cast<int>(third.kind),
            static_cast<int>(pluto::SynFrameBuffer::FrameKind::kNone));

  // A later read completing the frame must deliver it whole and untorn.
  buffer.push_event(abs_event(300, pluto::kAbsY, 22));
  buffer.push_event(syn_event(300, pluto::kSynReport));
  pluto::SynFrameBuffer::Frame completed = buffer.take_frame();
  ASSERT_EQ(static_cast<int>(completed.kind),
            static_cast<int>(pluto::SynFrameBuffer::FrameKind::kEvents));
  ASSERT_EQ(completed.events.size(), 3u);
  EXPECT_EQ(completed.events[0].value, 12);
  EXPECT_EQ(completed.events[1].value, 22);
  EXPECT_EQ(completed.events.back().code, pluto::kSynReport);
}

TEST(PlutoEvdevSynFrameBufferTest, EventsAfterResyncBoundaryAreRetained) {
  pluto::SynFrameBuffer buffer;
  // Partial frame, kernel overflow, stale tail, resync SYN, then a fresh
  // frame that used to be discarded along with the truncated read.
  buffer.push_event(abs_event(100, pluto::kAbsX, 10));
  buffer.push_event(syn_event(150, pluto::kSynDropped));
  buffer.push_event(abs_event(150, pluto::kAbsX, 99));
  buffer.push_event(syn_event(160, pluto::kSynReport));
  buffer.push_event(abs_event(200, pluto::kAbsX, 12));
  buffer.push_event(syn_event(200, pluto::kSynReport));

  pluto::SynFrameBuffer::Frame resync = buffer.take_frame();
  ASSERT_EQ(static_cast<int>(resync.kind),
            static_cast<int>(pluto::SynFrameBuffer::FrameKind::kResync));
  EXPECT_EQ(resync.resync_ts_us, 160);
  EXPECT_TRUE(resync.events.empty());
  EXPECT_EQ(buffer.resync_count(), 1u);

  pluto::SynFrameBuffer::Frame fresh = buffer.take_frame();
  ASSERT_EQ(static_cast<int>(fresh.kind),
            static_cast<int>(pluto::SynFrameBuffer::FrameKind::kEvents));
  ASSERT_EQ(fresh.events.size(), 2u);
  EXPECT_EQ(fresh.events[0].value, 12);
  EXPECT_EQ(fresh.events.back().code, pluto::kSynReport);
  EXPECT_EQ(buffer.resync_count(), 1u);
}

TEST(PlutoEvdevSynFrameBufferTest,
     ResyncTelemetrySurvivesQueueCleanupAndCountsRecoveries) {
  pluto::SynFrameBuffer buffer;
  buffer.push_event(syn_event(100, pluto::kSynDropped));
  buffer.push_event(syn_event(110, pluto::kSynReport));
  EXPECT_EQ(static_cast<int>(buffer.take_frame().kind),
            static_cast<int>(pluto::SynFrameBuffer::FrameKind::kResync));
  EXPECT_EQ(buffer.resync_count(), 1u);

  buffer.clear();
  EXPECT_EQ(buffer.resync_count(), 1u);
  buffer.push_event(syn_event(200, pluto::kSynDropped));
  buffer.push_event(syn_event(210, pluto::kSynReport));
  EXPECT_EQ(static_cast<int>(buffer.take_frame().kind),
            static_cast<int>(pluto::SynFrameBuffer::FrameKind::kResync));
  EXPECT_EQ(buffer.resync_count(), 2u);
}

TEST(PlutoEvdevSynFrameBufferTest, CallerOwnedBatchReusesCapacityAcrossSyns) {
  pluto::SynFrameBuffer buffer;
  std::vector<pluto::RawEvent> batch;
  batch.reserve(64);
  const size_t reserved = batch.capacity();

  for (int frame = 0; frame < 100; ++frame) {
    buffer.push_event(abs_event(frame * 100, pluto::kAbsX, frame));
    buffer.push_event(syn_event(frame * 100, pluto::kSynReport));
    int64_t resync_ts_us = -1;
    EXPECT_EQ(static_cast<int>(buffer.take_frame_into(&batch, &resync_ts_us)),
              static_cast<int>(pluto::SynFrameBuffer::FrameKind::kEvents));
    ASSERT_EQ(batch.size(), 2u);
    EXPECT_EQ(batch[0].value, frame);
    EXPECT_EQ(batch.capacity(), reserved);
  }
}

TEST(PlutoInputReplayTest, TrackerOutputIsDeterministicAcrossReplays) {
  const std::vector<int> first = collect_pen_phases("pen_hover_pressure.jsonl");
  const std::vector<int> second =
      collect_pen_phases("pen_hover_pressure.jsonl");
  ASSERT_EQ(first.size(), second.size());
  for (size_t i = 0; i < first.size(); ++i) {
    EXPECT_EQ(first[i], second[i]);
  }
}
