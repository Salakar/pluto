// InkThread tests: the dedicated evdev owner forwards the exact PenTracker
// stream and emits pure renderer hints for every coherent hover/contact SYN
// frame. It must never synthesize pixels, damage, or presentation work.

#include "input/ink_thread.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <string>
#include <type_traits>
#include <vector>

#include "input/evdev.h"
#include "input/pen.h"

namespace {

using pluto::EvdevStatus;
using pluto::EvdevControlRequest;
using pluto::EvdevSourceOpsForTesting;
using pluto::InkThread;
using pluto::InkThreadConfig;
using pluto::InkThreadHooks;
using pluto::Orientation;
using pluto::PenPointerEvent;
using pluto::PenRenderHint;
using pluto::PenTracker;
using pluto::PenTrackerOutput;
using pluto::RawEvent;
using pluto::ReplaySource;

static_assert(std::is_trivially_copyable_v<PenRenderHint>);

pluto::AffineTransform identity_transform() {
  return pluto::AffineTransform{1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f};
}

RawEvent abs_event(int64_t ts_us, uint16_t code, int32_t value) {
  return RawEvent{ts_us, pluto::kEvAbs, code, value};
}

RawEvent key_event(int64_t ts_us, uint16_t code, int32_t value) {
  return RawEvent{ts_us, pluto::kEvKey, code, value};
}

RawEvent syn_event(int64_t ts_us) {
  return RawEvent{ts_us, pluto::kEvSyn, pluto::kSynReport, 0};
}

std::vector<RawEvent> hover_sample(int64_t ts_us, int32_t x, int32_t y,
                                   bool first_in_range) {
  std::vector<RawEvent> events;
  if (first_in_range) {
    events.push_back(key_event(ts_us, pluto::kBtnToolPen, 1));
  }
  events.push_back(abs_event(ts_us, pluto::kAbsX, x));
  events.push_back(abs_event(ts_us, pluto::kAbsY, y));
  events.push_back(abs_event(ts_us, pluto::kAbsDistance, 8));
  events.push_back(syn_event(ts_us));
  return events;
}

std::vector<RawEvent> contact_sample(int64_t ts_us, int32_t x, int32_t y,
                                     int32_t pressure, bool first_in_range) {
  std::vector<RawEvent> events;
  if (first_in_range) {
    events.push_back(key_event(ts_us, pluto::kBtnToolPen, 1));
    events.push_back(key_event(ts_us, pluto::kBtnTouch, 1));
  }
  events.push_back(abs_event(ts_us, pluto::kAbsX, x));
  events.push_back(abs_event(ts_us, pluto::kAbsY, y));
  events.push_back(abs_event(ts_us, pluto::kAbsPressure, pressure));
  events.push_back(syn_event(ts_us));
  return events;
}

std::vector<RawEvent> contact_from_hover(int64_t ts_us, int32_t x, int32_t y,
                                         int32_t pressure) {
  return {key_event(ts_us, pluto::kBtnTouch, 1),
          abs_event(ts_us, pluto::kAbsX, x),
          abs_event(ts_us, pluto::kAbsY, y),
          abs_event(ts_us, pluto::kAbsPressure, pressure), syn_event(ts_us)};
}

std::vector<RawEvent> lift_to_hover(int64_t ts_us, int32_t x, int32_t y) {
  return {key_event(ts_us, pluto::kBtnTouch, 0),
          abs_event(ts_us, pluto::kAbsX, x),
          abs_event(ts_us, pluto::kAbsY, y),
          abs_event(ts_us, pluto::kAbsPressure, 0), syn_event(ts_us)};
}

std::vector<RawEvent> leave_range(int64_t ts_us) {
  return {key_event(ts_us, pluto::kBtnToolPen, 0), syn_event(ts_us)};
}

struct Capture {
  std::vector<PenTrackerOutput> tracker_outputs;
  std::vector<PenPointerEvent> pointer_events;
  std::vector<PenRenderHint> hints;
  std::vector<char> callback_order;
  size_t device_open_count = 0;
};

struct GrabFailureEvdev {
  bool fail_monotonic_clock = false;
  size_t open_calls = 0;
  size_t monotonic_clock_calls = 0;
  size_t grab_calls = 0;
  size_t close_calls = 0;
  bool clock_succeeded_before_grab = false;
  bool saw_unexpected_fd = false;

  static int open(void *user_data, const char *) {
    auto *self = static_cast<GrabFailureEvdev *>(user_data);
    ++self->open_calls;
    return 73; // inert synthetic descriptor; never passed to the kernel
  }

  static int control_ioctl(void *user_data, int fd,
                           EvdevControlRequest request, bool enabled) {
    auto *self = static_cast<GrabFailureEvdev *>(user_data);
    self->saw_unexpected_fd = self->saw_unexpected_fd || fd != 73;
    switch (request) {
    case EvdevControlRequest::kSetMonotonicClock:
      ++self->monotonic_clock_calls;
      return self->fail_monotonic_clock ? -1 : 0;
    case EvdevControlRequest::kGrab:
      ++self->grab_calls;
      self->clock_succeeded_before_grab =
          self->monotonic_clock_calls == 1 && enabled;
      return -1;
    }
    return -1;
  }

  static void close(void *user_data, int fd) {
    auto *self = static_cast<GrabFailureEvdev *>(user_data);
    self->saw_unexpected_fd = self->saw_unexpected_fd || fd != 73;
    ++self->close_calls;
  }

  EvdevSourceOpsForTesting ops() {
    return EvdevSourceOpsForTesting{
        .user_data = this,
        .open = &GrabFailureEvdev::open,
        .control_ioctl = &GrabFailureEvdev::control_ioctl,
        .close = &GrabFailureEvdev::close,
    };
  }
};

InkThreadHooks capture_hooks(Capture *capture) {
  InkThreadHooks hooks;
  hooks.on_device_open = [capture](const pluto::DeviceIdentity &,
                                   const pluto::AffineTransform &,
                                   Orientation) {
    ++capture->device_open_count;
  };
  hooks.on_tracker_output = [capture](const PenTrackerOutput &out) {
    capture->callback_order.push_back('T');
    capture->tracker_outputs.push_back(out);
    for (size_t i = 0; i < out.pointer_count; ++i) {
      capture->pointer_events.push_back(out.pointer_events[i]);
    }
  };
  hooks.on_render_hint = [capture](const PenRenderHint &hint) {
    capture->callback_order.push_back('H');
    capture->hints.push_back(hint);
  };
  return hooks;
}

InkThreadConfig hint_config() {
  InkThreadConfig config;
  config.panel_width = 256.0f;
  config.panel_height = 256.0f;
  config.scan_frame_us = 5000;
  config.predict_horizon_us = 5000;
  config.predict_max_px = 100;
  config.velocity_smoothing_tau_us = 0;
  config.trajectory_reset_gap_us = 50000;
  return config;
}

int phase(const PenPointerEvent &event) {
  return static_cast<int>(event.phase);
}

int tool(const PenRenderHint &hint) { return static_cast<int>(hint.tool); }

} // namespace

TEST(InkThreadTest, EveryCoherentHoverAndContactSampleEmitsOnePureHint) {
  Capture capture;
  InkThread ink(hint_config(), capture_hooks(&capture));
  ink.begin_session(identity_transform(), Orientation::kDeg0, 4095);

  ink.process_batch(hover_sample(1000, 10, 20, /*first_in_range=*/true));
  ink.process_batch(hover_sample(6000, 14, 20, /*first_in_range=*/false));
  ink.process_batch(contact_from_hover(11000, 18, 20, 1200));
  ink.process_batch(lift_to_hover(16000, 20, 20));
  ink.process_batch(leave_range(21000));
  // A clean SYN with no changed state is not a coherent tracker sample.
  ink.process_batch({syn_event(26000)});

  ASSERT_EQ(capture.hints.size(), 5u);
  ASSERT_EQ(capture.callback_order.size(), 10u);
  for (size_t i = 0; i < capture.callback_order.size(); i += 2) {
    EXPECT_EQ(capture.callback_order[i], 'H') << "sample " << i / 2;
    EXPECT_EQ(capture.callback_order[i + 1], 'T') << "sample " << i / 2;
  }
  const PenRenderHint &first_hover = capture.hints[0];
  EXPECT_EQ(first_hover.ts_us, 1000);
  EXPECT_NEAR(first_hover.current.x, 10.0, 0.001);
  EXPECT_NEAR(first_hover.current.y, 20.0, 0.001);
  EXPECT_FALSE(first_hover.contact);
  EXPECT_TRUE(first_hover.in_range);
  EXPECT_EQ(tool(first_hover), static_cast<int>(pluto::PenTool::kTip));
  EXPECT_TRUE((first_hover.transition & pluto::kPenTransitionAdded) != 0);
  EXPECT_FALSE(first_hover.has_previous);
  EXPECT_FALSE(first_hover.prediction_valid);
  EXPECT_NEAR(first_hover.predicted.x, first_hover.current.x, 0.001);

  const PenRenderHint &moving_hover = capture.hints[1];
  EXPECT_FALSE(moving_hover.contact);
  EXPECT_TRUE(moving_hover.has_previous);
  EXPECT_EQ(moving_hover.previous_ts_us, 1000);
  EXPECT_NEAR(moving_hover.previous.x, 10.0, 0.001);
  EXPECT_TRUE(moving_hover.prediction_valid);

  const PenRenderHint &down = capture.hints[2];
  EXPECT_TRUE(down.in_range);
  EXPECT_TRUE(down.contact);
  EXPECT_TRUE((down.transition & pluto::kPenTransitionDown) != 0);
  EXPECT_TRUE(down.has_previous)
      << "hover trajectory must remain useful at first contact";

  const PenRenderHint &lifted_hover = capture.hints[3];
  EXPECT_TRUE(lifted_hover.in_range);
  EXPECT_FALSE(lifted_hover.contact);
  EXPECT_TRUE((lifted_hover.transition & pluto::kPenTransitionUp) != 0);

  const PenRenderHint &removed = capture.hints[4];
  EXPECT_FALSE(removed.in_range);
  EXPECT_FALSE(removed.contact);
  EXPECT_TRUE((removed.transition & pluto::kPenTransitionRemoved) != 0);
  EXPECT_FALSE(removed.prediction_valid);

  ASSERT_EQ(capture.pointer_events.size(), 5u);
  EXPECT_EQ(phase(capture.pointer_events[0]),
            static_cast<int>(pluto::PointerPhase::kAdd));
  EXPECT_EQ(phase(capture.pointer_events[1]),
            static_cast<int>(pluto::PointerPhase::kHover));
  EXPECT_EQ(phase(capture.pointer_events[2]),
            static_cast<int>(pluto::PointerPhase::kDown));
  EXPECT_EQ(phase(capture.pointer_events[3]),
            static_cast<int>(pluto::PointerPhase::kUp));
  EXPECT_EQ(phase(capture.pointer_events[4]),
            static_cast<int>(pluto::PointerPhase::kRemove));
}

TEST(InkThreadTest, BufferedSynFramesKeepTheirKernelSampleSpacing) {
  Capture capture;
  InkThread ink(hint_config(), capture_hooks(&capture));
  ink.begin_session(identity_transform(), Orientation::kDeg0, 4095);

  constexpr int64_t first_sample_us = 12'345'000;
  constexpr int64_t second_sample_us = 12'349'250;
  std::vector<RawEvent> buffered =
      hover_sample(first_sample_us, 10, 20, /*first_in_range=*/true);
  const std::vector<RawEvent> second =
      hover_sample(second_sample_us, 14, 20, /*first_in_range=*/false);
  buffered.insert(buffered.end(), second.begin(), second.end());

  // One evdev read may contain both complete SYN frames. InkThread must still
  // forward both reports with their original timestamps, not their common
  // drain/dispatch time.
  ink.process_batch(buffered);

  ASSERT_EQ(capture.pointer_events.size(), 2u);
  EXPECT_EQ(capture.pointer_events[0].ts_us, first_sample_us);
  EXPECT_EQ(capture.pointer_events[1].ts_us, second_sample_us);
  EXPECT_EQ(capture.pointer_events[1].ts_us - capture.pointer_events[0].ts_us,
            4250);
}

TEST(InkThreadTest, PredictionHonorsHorizonScanFrameAndDistanceClamps) {
  // Requested horizon below the scan frame: 4 px / 4 ms = 1000 px/s,
  // projected 4 ms -> exactly 4 px.
  {
    Capture capture;
    InkThreadConfig config = hint_config();
    config.scan_frame_us = 10000;
    config.predict_horizon_us = 4000;
    InkThread ink(config, capture_hooks(&capture));
    ink.begin_session(identity_transform(), Orientation::kDeg0, 4095);
    ink.process_batch(hover_sample(1000, 10, 40, true));
    ink.process_batch(hover_sample(5000, 14, 40, false));
    ASSERT_EQ(capture.hints.size(), 2u);
    EXPECT_TRUE(capture.hints.back().prediction_valid);
    EXPECT_NEAR(capture.hints.back().predicted.x, 18.0, 0.001);
  }

  // A caller cannot request prediction beyond one scan frame: 2 px / 5 ms,
  // projected over the 10 ms scan cap -> 4 px (not the requested 20 px).
  {
    Capture capture;
    InkThreadConfig config = hint_config();
    config.scan_frame_us = 10000;
    config.predict_horizon_us = 50000;
    InkThread ink(config, capture_hooks(&capture));
    ink.begin_session(identity_transform(), Orientation::kDeg0, 4095);
    ink.process_batch(hover_sample(1000, 10, 40, true));
    ink.process_batch(hover_sample(6000, 12, 40, false));
    ASSERT_EQ(capture.hints.size(), 2u);
    EXPECT_NEAR(capture.hints.back().predicted.x, 16.0, 0.001);
  }

  // Very fast input reaches only the radial max-displacement clamp.
  {
    Capture capture;
    InkThreadConfig config = hint_config();
    config.scan_frame_us = 10000;
    config.predict_horizon_us = 10000;
    config.predict_max_px = 8;
    InkThread ink(config, capture_hooks(&capture));
    ink.begin_session(identity_transform(), Orientation::kDeg0, 4095);
    ink.process_batch(hover_sample(1000, 20, 40, true));
    ink.process_batch(hover_sample(2000, 60, 40, false));
    ASSERT_EQ(capture.hints.size(), 2u);
    EXPECT_NEAR(capture.hints.back().predicted.x, 68.0, 0.001);
    EXPECT_NEAR(capture.hints.back().predicted.y, 40.0, 0.001);
  }

  // Prediction itself cannot leave panel coordinates.
  {
    Capture capture;
    InkThreadConfig config = hint_config();
    config.panel_width = 64.0f;
    InkThread ink(config, capture_hooks(&capture));
    ink.begin_session(identity_transform(), Orientation::kDeg0, 4095);
    ink.process_batch(hover_sample(1000, 55, 40, true));
    ink.process_batch(hover_sample(6000, 62, 40, false));
    ASSERT_EQ(capture.hints.size(), 2u);
    EXPECT_TRUE(capture.hints.back().prediction_valid);
    EXPECT_NEAR(capture.hints.back().predicted.x, 63.0, 0.001);
  }
}

TEST(InkThreadTest, VelocitySmoothingIsTimeAwareAndImmediatelyUseful) {
  Capture capture;
  InkThreadConfig config = hint_config();
  config.velocity_smoothing_tau_us = 5000;
  InkThread ink(config, capture_hooks(&capture));
  ink.begin_session(identity_transform(), Orientation::kDeg0, 4095);

  ink.process_batch(hover_sample(1000, 10, 40, true));
  // First measured velocity seeds immediately: 10 px / 5 ms = 2000 px/s.
  ink.process_batch(hover_sample(6000, 20, 40, false));
  // 20 px / 5 ms = 4000 px/s; alpha=5/(5+5)=1/2 -> 3000.
  ink.process_batch(hover_sample(11000, 40, 40, false));
  // 40 px / 10 ms = 4000 px/s; alpha=10/(5+10)=2/3 -> 3666.67.
  ink.process_batch(hover_sample(21000, 80, 40, false));

  ASSERT_EQ(capture.hints.size(), 4u);
  EXPECT_NEAR(capture.hints[1].smoothed_velocity_px_per_s.x, 2000.0, 0.01);
  EXPECT_NEAR(capture.hints[1].predicted.x, 30.0, 0.01);
  EXPECT_NEAR(capture.hints[2].smoothed_velocity_px_per_s.x, 3000.0, 0.01);
  EXPECT_NEAR(capture.hints[2].predicted.x, 55.0, 0.01);
  EXPECT_NEAR(capture.hints[3].smoothed_velocity_px_per_s.x, 3666.667, 0.02);
  EXPECT_NEAR(capture.hints[3].predicted.x, 98.333, 0.02);
}

TEST(InkThreadTest, ReversalLongGapAndResyncResetStaleExtrapolation) {
  Capture capture;
  InkThreadConfig config = hint_config();
  config.trajectory_reset_gap_us = 30000;
  InkThread ink(config, capture_hooks(&capture));
  ink.begin_session(identity_transform(), Orientation::kDeg0, 4095);

  ink.process_batch(hover_sample(1000, 20, 40, true));
  ink.process_batch(hover_sample(6000, 30, 40, false));
  ASSERT_TRUE(capture.hints.back().prediction_valid);
  EXPECT_GT(capture.hints.back().predicted.x, 30.0f);

  // Immediate reversal publishes the real previous segment and the fresh
  // leftward velocity, but no stale rightward predicted point.
  ink.process_batch(hover_sample(11000, 20, 40, false));
  ASSERT_EQ(capture.hints.size(), 3u);
  EXPECT_TRUE(capture.hints.back().has_previous);
  EXPECT_LT(capture.hints.back().smoothed_velocity_px_per_s.x, 0.0f);
  EXPECT_FALSE(capture.hints.back().prediction_valid);
  EXPECT_NEAR(capture.hints.back().predicted.x, 20.0, 0.001);

  // One further sample in the new direction extrapolates immediately.
  ink.process_batch(hover_sample(16000, 10, 40, false));
  EXPECT_TRUE(capture.hints.back().prediction_valid);
  EXPECT_NEAR(capture.hints.back().predicted.x, 0.0, 0.001);

  // A long input gap must not connect to or extrapolate old motion.
  ink.process_batch(hover_sample(100000, 5, 40, false));
  EXPECT_FALSE(capture.hints.back().has_previous);
  EXPECT_FALSE(capture.hints.back().prediction_valid);
  EXPECT_NEAR(capture.hints.back().predicted.x, 5.0, 0.001);
  ink.process_batch(hover_sample(105000, 6, 40, false));
  EXPECT_TRUE(capture.hints.back().prediction_valid);

  // SYN_DROPPED consumes through the next report, then marks the following
  // coherent sample as resynced. It seeds a new trajectory without guessing
  // across the unknown interval.
  ink.process_batch({RawEvent{106000, pluto::kEvSyn, pluto::kSynDropped, 0},
                     syn_event(107000)});
  const size_t before_resync = capture.hints.size();
  ink.process_batch(hover_sample(110000, 8, 40, false));
  ASSERT_EQ(capture.hints.size(), before_resync + 1);
  EXPECT_TRUE(
      (capture.hints.back().transition & pluto::kPenTransitionResync) != 0);
  EXPECT_FALSE(capture.hints.back().has_previous);
  EXPECT_FALSE(capture.hints.back().prediction_valid);
  ink.process_batch(hover_sample(115000, 10, 40, false));
  EXPECT_TRUE(capture.hints.back().prediction_valid);
}

TEST(InkThreadTest, KernelResyncSnapshotCannotExtrapolateAcrossDroppedSamples) {
  Capture capture;
  InkThread ink(hint_config(), capture_hooks(&capture));
  ink.begin_session(identity_transform(), Orientation::kDeg0, 4095);

  ink.process_batch(hover_sample(1000, 20, 40, true));
  ink.process_batch(hover_sample(6000, 30, 40, false));
  ASSERT_TRUE(capture.hints.back().prediction_valid);

  // This is the shape EvdevSource returns after SYN_DROPPED: reconstructed
  // key/axis state plus SYN_REPORT, with status kResynced and no raw dropped
  // marker. The snapshot must be kept, marked, and used only as a new seed.
  ink.process_batch(hover_sample(7000, 60, 40, false), true);
  ASSERT_EQ(capture.hints.size(), 3u);
  const PenRenderHint &resynced = capture.hints.back();
  EXPECT_TRUE((resynced.transition & pluto::kPenTransitionResync) != 0);
  EXPECT_FALSE(resynced.has_previous);
  EXPECT_FALSE(resynced.prediction_valid);
  EXPECT_NEAR(resynced.current.x, 60.0, 0.001);
  EXPECT_NEAR(resynced.predicted.x, 60.0, 0.001);
}

TEST(InkThreadTest, DeviceLossEmitsTerminalHintAndClearsTrajectory) {
  Capture capture;
  InkThread ink(hint_config(), capture_hooks(&capture));
  ink.begin_session(identity_transform(), Orientation::kDeg0, 4095);

  ink.process_batch(contact_sample(1000, 30, 30, 500, true));
  ink.process_batch(contact_sample(6000, 40, 30, 500, false));
  capture.pointer_events.clear();
  ink.handle_device_lost(11000);

  ASSERT_EQ(capture.hints.size(), 3u);
  ASSERT_GE(capture.callback_order.size(), 2u);
  EXPECT_EQ(capture.callback_order[capture.callback_order.size() - 2], 'H');
  EXPECT_EQ(capture.callback_order.back(), 'T');
  const PenRenderHint &lost = capture.hints.back();
  EXPECT_TRUE(lost.device_lost);
  EXPECT_FALSE(lost.in_range);
  EXPECT_FALSE(lost.contact);
  EXPECT_FALSE(lost.has_previous);
  EXPECT_FALSE(lost.prediction_valid);
  EXPECT_TRUE((lost.transition & pluto::kPenTransitionCanceled) != 0);
  EXPECT_TRUE((lost.transition & pluto::kPenTransitionRemoved) != 0);
  ASSERT_EQ(capture.pointer_events.size(), 2u);
  EXPECT_EQ(phase(capture.pointer_events[0]),
            static_cast<int>(pluto::PointerPhase::kCancel));
  EXPECT_EQ(phase(capture.pointer_events[1]),
            static_cast<int>(pluto::PointerPhase::kRemove));

  // Reacquisition begins fresh rather than inheriting pre-loss velocity.
  ink.process_batch(contact_sample(16000, 50, 30, 500, true));
  ASSERT_EQ(capture.hints.size(), 4u);
  EXPECT_FALSE(capture.hints.back().has_previous);
  EXPECT_FALSE(capture.hints.back().prediction_valid);
}

TEST(InkThreadTest,
     WarmSessionSwitchRemovesOldHoverAndRehydratesCurrentProximity) {
  Capture capture;
  InkThread ink(hint_config(), capture_hooks(&capture));
  ink.begin_session(identity_transform(), Orientation::kDeg0, 4095);

  ink.process_batch(hover_sample(1000, 30, 40, true));
  ASSERT_EQ(capture.pointer_events.size(), 1u);
  EXPECT_EQ(phase(capture.pointer_events.back()),
            static_cast<int>(pluto::PointerPhase::kAdd));

  // Normal stop uses the same terminal operation before releasing EVIOCGRAB.
  ink.handle_device_lost(2000);
  ASSERT_EQ(capture.pointer_events.size(), 2u);
  EXPECT_EQ(phase(capture.pointer_events.back()),
            static_cast<int>(pluto::PointerPhase::kRemove));
  EXPECT_TRUE(capture.hints.back().device_lost);
  EXPECT_FALSE(capture.hints.back().in_range);

  // Shape of EvdevSource::snapshot_current_state after the next exclusive
  // open: current BTN_TOOL_PEN + axes + SYN, marked as a resync boundary.
  // Linux need not repeat a tool edge while the nib remains in proximity.
  ink.begin_session(identity_transform(), Orientation::kDeg0, 4095);
  ink.process_batch(hover_sample(3000, 34, 42, true),
                    /*source_resynced=*/true);

  ASSERT_EQ(capture.pointer_events.size(), 3u);
  EXPECT_EQ(phase(capture.pointer_events.back()),
            static_cast<int>(pluto::PointerPhase::kAdd));
  const PenRenderHint &rehydrated = capture.hints.back();
  EXPECT_TRUE(rehydrated.in_range);
  EXPECT_FALSE(rehydrated.contact);
  EXPECT_FALSE(rehydrated.device_lost);
  EXPECT_TRUE((rehydrated.transition & pluto::kPenTransitionAdded) != 0);
  EXPECT_TRUE((rehydrated.transition & pluto::kPenTransitionResync) != 0);
  EXPECT_FALSE(rehydrated.has_previous);
  EXPECT_FALSE(rehydrated.prediction_valid);
  EXPECT_NEAR(rehydrated.current.x, 34.0, 0.001);
  EXPECT_NEAR(rehydrated.current.y, 42.0, 0.001);
}

TEST(InkThreadTest, BeginSessionResetsTrajectoryAndUsesNewCalibration) {
  Capture capture;
  InkThread ink(hint_config(), capture_hooks(&capture));
  ink.begin_session(identity_transform(), Orientation::kDeg0, 4095);
  ink.process_batch(hover_sample(1000, 10, 20, true));
  ink.process_batch(hover_sample(6000, 20, 20, false));
  ASSERT_TRUE(capture.hints.back().prediction_valid);

  const pluto::AffineTransform transformed{
      .a = 2.0f,
      .b = 0.0f,
      .c = 3.0f,
      .d = 0.0f,
      .e = 3.0f,
      .f = 4.0f,
  };
  ink.begin_session(transformed, Orientation::kDeg90, 2047);
  ink.process_batch(hover_sample(11000, 10, 20, true));

  ASSERT_EQ(capture.hints.size(), 3u);
  const PenRenderHint &fresh = capture.hints.back();
  EXPECT_NEAR(fresh.current.x, 23.0, 0.001);
  EXPECT_NEAR(fresh.current.y, 64.0, 0.001);
  EXPECT_FALSE(fresh.has_previous);
  EXPECT_FALSE(fresh.prediction_valid);
}

TEST(InkThreadTest, FixtureReplayMatchesBareTrackerPerSyn) {
  const std::string fixture =
      std::string(PLUTO_INPUT_FIXTURE_DIR) + "/pen_hover_pressure.jsonl";

  std::vector<PenTrackerOutput> expected;
  {
    ReplaySource source = ReplaySource::from_jsonl_file(fixture);
    PenTracker tracker;
    while (true) {
      pluto::SourceResult batch = source.next_batch();
      if (batch.status == EvdevStatus::kAgain) {
        break;
      }
      for (const RawEvent &event : batch.events) {
        const PenTrackerOutput out = tracker.consume(event);
        if (out.has_sample || out.pointer_count > 0) {
          expected.push_back(out);
        }
      }
    }
  }
  ASSERT_TRUE(!expected.empty());

  Capture capture;
  InkThread ink(hint_config(), capture_hooks(&capture));
  ink.begin_session(identity_transform(), Orientation::kDeg0, 4095);
  ReplaySource source = ReplaySource::from_jsonl_file(fixture);
  while (true) {
    pluto::SourceResult batch = source.next_batch();
    if (batch.status == EvdevStatus::kAgain) {
      break;
    }
    ink.process_batch(batch.events);
  }

  ASSERT_EQ(capture.tracker_outputs.size(), expected.size());
  size_t sample_count = 0;
  for (size_t i = 0; i < expected.size(); ++i) {
    const PenTrackerOutput &want = expected[i];
    const PenTrackerOutput &got = capture.tracker_outputs[i];
    EXPECT_EQ(got.has_sample, want.has_sample) << "output " << i;
    EXPECT_EQ(got.pointer_count, want.pointer_count) << "output " << i;
    if (want.has_sample) {
      ++sample_count;
      EXPECT_EQ(got.sample.ts_us, want.sample.ts_us) << "output " << i;
      EXPECT_EQ(static_cast<int>(got.sample.tool),
                static_cast<int>(want.sample.tool))
          << "output " << i;
      EXPECT_EQ(got.sample.in_range, want.sample.in_range) << "output " << i;
      EXPECT_EQ(got.sample.contact, want.sample.contact) << "output " << i;
      EXPECT_EQ(got.sample.raw_x, want.sample.raw_x) << "output " << i;
      EXPECT_EQ(got.sample.raw_y, want.sample.raw_y) << "output " << i;
      EXPECT_EQ(got.sample.raw_pressure, want.sample.raw_pressure)
          << "output " << i;
      EXPECT_EQ(got.sample.transition, want.sample.transition)
          << "output " << i;
    }
    for (size_t j = 0; j < want.pointer_count; ++j) {
      EXPECT_EQ(static_cast<int>(got.pointer_events[j].phase),
                static_cast<int>(want.pointer_events[j].phase))
          << "output " << i << " pointer " << j;
      EXPECT_EQ(got.pointer_events[j].ts_us, want.pointer_events[j].ts_us)
          << "output " << i << " pointer " << j;
      EXPECT_EQ(got.pointer_events[j].raw_x, want.pointer_events[j].raw_x)
          << "output " << i << " pointer " << j;
      EXPECT_EQ(got.pointer_events[j].raw_y, want.pointer_events[j].raw_y)
          << "output " << i << " pointer " << j;
    }
  }
  EXPECT_EQ(capture.hints.size(), sample_count)
      << "every forwarded coherent sample must have exactly one hint";
}

TEST(InkThreadTest, StartStopWithMissingDeviceIsCleanAndIdempotent) {
  Capture capture;
  InkThreadConfig config = hint_config();
  config.device_path = "/nonexistent/pluto-test-pen";
  InkThread ink(config, capture_hooks(&capture));
  std::string error;
  ASSERT_TRUE(ink.start(&error)) << error;
  ink.stop();
  ink.stop();
  EXPECT_TRUE(capture.hints.empty());
  EXPECT_TRUE(capture.tracker_outputs.empty());
  EXPECT_EQ(capture.device_open_count, 0u);
}

TEST(InkThreadTest, ExclusiveGrabFailurePublishesNoDeviceOrPointerHooks) {
  GrabFailureEvdev fake;
  EvdevSourceOpsForTesting ops = fake.ops();
  Capture capture;
  InkThreadConfig config = hint_config();
  config.device_path = "/synthetic/pluto-pen-grab-failure";
  config.evdev_ops_for_testing = &ops;
  InkThread ink(config, capture_hooks(&capture));
  std::string error;
  ASSERT_TRUE(ink.start(&error)) << error;
  ink.stop();

  EXPECT_EQ(fake.open_calls, 1u);
  EXPECT_EQ(fake.monotonic_clock_calls, 1u);
  EXPECT_EQ(fake.grab_calls, 1u);
  EXPECT_EQ(fake.close_calls, 1u);
  EXPECT_TRUE(fake.clock_succeeded_before_grab);
  EXPECT_FALSE(fake.saw_unexpected_fd);
  EXPECT_EQ(capture.device_open_count, 0u);
  EXPECT_TRUE(capture.hints.empty());
  EXPECT_TRUE(capture.tracker_outputs.empty());
  EXPECT_TRUE(capture.pointer_events.empty());
}

TEST(InkThreadTest,
     MonotonicClockFailurePublishesNoDeviceOrPointerHooks) {
  GrabFailureEvdev fake;
  fake.fail_monotonic_clock = true;
  EvdevSourceOpsForTesting ops = fake.ops();
  Capture capture;
  InkThreadConfig config = hint_config();
  config.device_path = "/synthetic/pluto-pen-clock-failure";
  config.evdev_ops_for_testing = &ops;
  InkThread ink(config, capture_hooks(&capture));
  std::string error;
  ASSERT_TRUE(ink.start(&error)) << error;
  ink.stop();

  EXPECT_EQ(fake.open_calls, 1u);
  EXPECT_EQ(fake.monotonic_clock_calls, 1u);
  EXPECT_EQ(fake.grab_calls, 0u);
  EXPECT_EQ(fake.close_calls, 1u);
  EXPECT_FALSE(fake.saw_unexpected_fd);
  EXPECT_EQ(capture.device_open_count, 0u);
  EXPECT_TRUE(capture.hints.empty());
  EXPECT_TRUE(capture.tracker_outputs.empty());
  EXPECT_TRUE(capture.pointer_events.empty());
}
