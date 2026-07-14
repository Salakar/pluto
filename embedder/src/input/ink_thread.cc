#include "input/ink_thread.h"

#include <poll.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <utility>

#if defined(__linux__)
#include <pthread.h>
#include <sched.h>
#endif

namespace pluto {
namespace {

constexpr float kMotionEpsilonPx = 0.25f;
constexpr float kMotionEpsilonSq = kMotionEpsilonPx * kMotionEpsilonPx;
constexpr float kUsPerSecond = 1000000.0f;

int64_t now_monotonic_us() {
  struct timespec mono {};
  clock_gettime(CLOCK_MONOTONIC, &mono);
  return static_cast<int64_t>(mono.tv_sec) * 1000000ll + mono.tv_nsec / 1000ll;
}

float clamp_axis(float value, float extent) {
  if (!std::isfinite(value)) {
    return 0.0f;
  }
  const float max_value =
      std::isfinite(extent) && extent > 1.0f ? extent - 1.0f : 0.0f;
  return std::clamp(value, 0.0f, max_value);
}

void configure_input_thread_priority(int requested_priority) {
#if defined(__linux__)
  (void)pthread_setname_np(pthread_self(), "pluto-pen");
  if (requested_priority <= 0) {
    return;
  }
  sched_param param{};
  param.sched_priority =
      std::clamp(requested_priority, sched_get_priority_min(SCHED_FIFO),
                 sched_get_priority_max(SCHED_FIFO));
  const int error = pthread_setschedparam(pthread_self(), SCHED_FIFO, &param);
  if (error == 0) {
    std::cerr << "ink: input thread SCHED_FIFO priority="
              << param.sched_priority << "\n";
  } else {
    std::cerr << "ink: SCHED_FIFO unavailable (" << std::strerror(error)
              << "); continuing with normal scheduling\n";
  }
#else
  (void)requested_priority;
#endif
}

} // namespace

InkThread::InkThread(const InkThreadConfig &config, InkThreadHooks hooks)
    : config_(config), hooks_(std::move(hooks)) {}

InkThread::~InkThread() { stop(); }

bool InkThread::start(std::string *error) {
  if (thread_.joinable()) {
    return true;
  }
  if (::pipe(wake_pipe_) != 0) {
    if (error != nullptr) {
      *error = "ink: cannot create wake pipe";
    }
    return false;
  }
  stop_.store(false, std::memory_order_release);
  thread_ = std::thread(&InkThread::run, this);
  return true;
}

void InkThread::stop() {
  stop_.store(true, std::memory_order_release);
  if (wake_pipe_[1] >= 0) {
    const char byte = 1;
    (void)!::write(wake_pipe_[1], &byte, 1);
  }
  if (thread_.joinable()) {
    thread_.join();
  }
  for (int &fd : wake_pipe_) {
    if (fd >= 0) {
      ::close(fd);
      fd = -1;
    }
  }
}

void InkThread::run() {
  const std::string path = config_.device_path.empty()
                               ? std::string(kDefaultPenByPath)
                               : config_.device_path;
  EvdevSource source(config_.evdev_ops_for_testing);
  if (source.open_by_path(path) != EvdevStatus::kOk) {
    std::cerr << "ink: unable to open " << path << "\n";
    return;
  }
  // Read exclusively so pen events never also reach the stock stack
  // (EVIOCGRAB — the same contract the engine_host pen loop held).
  // Failing open here would deliver the same physical samples to both
  // Pluto and the stock stack, recreating system-wide/native pen handling.
  // Treat exclusive ownership as a hard precondition and publish no hooks.
  if (source.grab(true) != EvdevStatus::kOk) {
    std::cerr << "ink: EVIOCGRAB failed for " << path
              << "; pen input disabled (exclusive ownership required)\n";
    source.close();
    return;
  }
  configure_input_thread_priority(config_.realtime_priority);

  int32_t xmin = 0, xmax = 0, ymin = 0, ymax = 0;
  int32_t pressure_max = 0;
  for (const auto &[code, info] : source.identity().axes) {
    if (code == kAbsX) {
      xmin = info.minimum;
      xmax = info.maximum;
    } else if (code == kAbsY) {
      ymin = info.minimum;
      ymax = info.maximum;
    } else if (code == kAbsPressure && info.maximum > 0) {
      pressure_max = info.maximum;
    }
  }
  if (xmax <= xmin) {
    xmin = 0;
    xmax = kPenRawXMaxFallback;
  }
  if (ymax <= ymin) {
    ymin = 0;
    ymax = kPenRawYMaxFallback;
  }
  if (pressure_max <= 0) {
    pressure_max = kPenRawPressureMaxFallback;
  }
  const AffineTransform calib = default_digitizer_to_panel(
      config_.panel_width, config_.panel_height, xmin, xmax, ymin, ymax);
  const uint32_t horizon_us =
      std::min(config_.predict_horizon_us, config_.scan_frame_us);
  std::cerr << "ink: " << source.identity().name << " on " << path << " x["
            << xmin << "," << xmax << "] y[" << ymin << "," << ymax
            << "] pressure<=" << pressure_max
            << " exclusive=EVIOCGRAB clock=monotonic render-hints="
            << (config_.predictor_enabled ? "predict" : "current")
            << " horizon_us=" << horizon_us << "\n";
  if (hooks_.on_device_open) {
    hooks_.on_device_open(source.identity(), calib, config_.orientation);
  }
  begin_session(calib, config_.orientation, pressure_max);
  std::vector<RawEvent> source_events;
  source_events.reserve(64);

  // evdev does not replay BTN_TOOL_PEN/BTN_TOUCH when a new app session opens.
  // Drop only the pre-snapshot queue, then seed PenTracker from the kernel's
  // coherent current key/axis state. A pen already hovering therefore emits
  // Add at its current position before we wait for a new physical transition.
  const EvdevStatus drain_status = source.discard_pending_events();
  if (drain_status == EvdevStatus::kDeviceLost) {
    handle_device_lost(now_monotonic_us());
    source.close();
    return;
  }
  if (drain_status != EvdevStatus::kOk) {
    std::cerr << "ink: unable to drain initial evdev state; pen disabled\n";
    handle_device_lost(now_monotonic_us());
    source.grab(false);
    source.close();
    return;
  }
  const EvdevStatus snapshot_status =
      source.snapshot_current_state(now_monotonic_us(), &source_events);
  if (snapshot_status != EvdevStatus::kResynced) {
    std::cerr << "ink: unable to snapshot initial evdev state; pen disabled\n";
    handle_device_lost(now_monotonic_us());
    source.grab(false);
    source.close();
    return;
  }
  process_batch(source_events, /*source_resynced=*/true);
  bool terminal_emitted = false;

  while (!stop_.load(std::memory_order_acquire)) {
    // Drain everything buffered before sleeping: one wake can carry many
    // SYN frames and next_batch serves exactly one per call.
    bool lost = false;
    for (;;) {
      const EvdevStatus status = source.next_batch_into(&source_events);
      if (status == EvdevStatus::kDeviceLost) {
        lost = true;
        break;
      }
      if (source_events.empty()) {
        break;
      }
      process_batch(source_events, status == EvdevStatus::kResynced);
    }
    if (lost) {
      handle_device_lost(now_monotonic_us());
      terminal_emitted = true;
      break;
    }
    // poll(2)-driven wait (no sleep-polling): the device fd for samples,
    // the wake pipe for stop().
    pollfd fds[2] = {{source.fd(), POLLIN, 0}, {wake_pipe_[0], POLLIN, 0}};
    if (::poll(fds, 2, -1) < 0) {
      continue; // EINTR
    }
    if ((fds[1].revents & POLLIN) != 0) {
      break;
    }
  }
  if (!terminal_emitted) {
    // Normal app switch/hibernate is still a device-session boundary for
    // Flutter. Cancel/Remove the old app before releasing EVIOCGRAB so it
    // cannot retain a hover cursor or active pointer into the next session.
    handle_device_lost(now_monotonic_us());
  }
  const uint64_t resyncs = source.resync_count();
  if (resyncs != 0) {
    // Keep stream I/O off the real-time sample path. A session-end summary is
    // enough to establish whether camera-visible stroke gaps coincided with
    // kernel queue overflow, and the counter survives EvdevSource::close().
    std::cerr << "ink: evdev_resyncs=" << resyncs << "\n";
  }
  source.grab(false);
  source.close();
}

void InkThread::begin_session(const AffineTransform &calibration,
                              Orientation orientation,
                              int32_t raw_pressure_max) {
  // These remain on the session seam because the device-open hook and host
  // pen service consume them; trajectory generation itself needs calibration.
  (void)orientation;
  (void)raw_pressure_max;
  calib_ = calibration;
  tracker_ = PenTracker();
  reset_trajectory();
}

// Per-event consume: unlike consume_batch this keeps every SYN frame, so no
// digitizer sample is dropped (the engine_host dispatch contract).
void InkThread::process_batch(const std::vector<RawEvent> &events,
                              bool source_resynced) {
  if (source_resynced) {
    // EvdevSource has replaced the corrupt interval with a coherent ioctl
    // snapshot, so do not feed SYN_DROPPED (which would discard that state).
    // Mark the snapshot's report and break prediction continuity explicitly.
    tracker_.mark_resynced();
    reset_trajectory();
  }
  for (const RawEvent &event : events) {
    const PenTrackerOutput out = tracker_.consume(event);
    // Publish the native renderer/pacer hint before any potentially expensive
    // Flutter pointer injection or optional channel serialization. The exact
    // PenTrackerOutput is still forwarded once, unchanged, for every SYN.
    if (out.has_sample) {
      emit_render_hint(out.sample);
    }
    if ((out.has_sample || out.pointer_count > 0) && hooks_.on_tracker_output) {
      hooks_.on_tracker_output(out);
    }
  }
}

void InkThread::handle_device_lost(int64_t ts_us) {
  const PenTrackerOutput out = tracker_.synthesize_device_lost(ts_us);
  // synthesize_device_lost always returns a coherent terminal sample.
  if (out.has_sample) {
    emit_render_hint(out.sample);
  }
  if ((out.has_sample || out.pointer_count > 0) && hooks_.on_tracker_output) {
    hooks_.on_tracker_output(out);
  }
}

Point InkThread::clamp_to_panel(Point point) const {
  return Point{.x = clamp_axis(point.x, config_.panel_width),
               .y = clamp_axis(point.y, config_.panel_height)};
}

void InkThread::reset_trajectory() { trajectory_ = TrajectoryState{}; }

void InkThread::emit_render_hint(const PenSample &sample) {
  const Point current = clamp_to_panel(
      calib_.apply(Point{.x = static_cast<float>(sample.raw_x),
                         .y = static_cast<float>(sample.raw_y)}));
  PenRenderHint hint{
      .ts_us = sample.ts_us,
      .previous_ts_us = sample.ts_us,
      .current = current,
      .previous = current,
      .smoothed_velocity_px_per_s = Point{},
      .predicted = current,
      .tool = sample.tool,
      .transition = sample.transition,
      .has_previous = false,
      .prediction_valid = false,
      .in_range = sample.in_range,
      .contact = sample.contact,
      .device_lost = sample.device_lost,
  };

  const bool forced_reset = sample.device_lost || !sample.in_range ||
                            (sample.transition & kPenTransitionResync) != 0;
  const int64_t dt_us = sample.ts_us - trajectory_.ts_us;
  const bool continuous =
      trajectory_.has_point && !forced_reset &&
      trajectory_.tool == sample.tool && dt_us > 0 &&
      static_cast<uint64_t>(dt_us) <= config_.trajectory_reset_gap_us;

  bool next_has_velocity = false;
  Point next_velocity{};
  if (continuous) {
    hint.has_previous = true;
    hint.previous_ts_us = trajectory_.ts_us;
    hint.previous = trajectory_.point;

    const float dx = current.x - trajectory_.point.x;
    const float dy = current.y - trajectory_.point.y;
    const float distance_sq = dx * dx + dy * dy;
    if (distance_sq > kMotionEpsilonSq) {
      const float seconds = static_cast<float>(dt_us) / kUsPerSecond;
      const Point instantaneous{
          .x = dx / seconds,
          .y = dy / seconds,
      };

      // A >=90-degree turn is an innovation, not a velocity sample to blend
      // with the old direction. Keep the real previous segment available to
      // the renderer, but suppress extrapolation for this sample so a sharp
      // turn cannot leave stale work ahead of the pen.
      const float direction_dot =
          instantaneous.x * trajectory_.velocity_px_per_s.x +
          instantaneous.y * trajectory_.velocity_px_per_s.y;
      const bool reversal = trajectory_.has_velocity && direction_dot <= 0.0f;
      if (trajectory_.has_velocity && !reversal) {
        const float dt = static_cast<float>(dt_us);
        const float tau = static_cast<float>(config_.velocity_smoothing_tau_us);
        const float alpha = tau > 0.0f ? dt / (tau + dt) : 1.0f;
        next_velocity = Point{
            .x = trajectory_.velocity_px_per_s.x +
                 alpha * (instantaneous.x - trajectory_.velocity_px_per_s.x),
            .y = trajectory_.velocity_px_per_s.y +
                 alpha * (instantaneous.y - trajectory_.velocity_px_per_s.y),
        };
      } else {
        // Seed a fresh direction immediately; the next coherent sample may
        // extrapolate it without waiting through an artificial timeout.
        next_velocity = instantaneous;
      }
      next_has_velocity = true;
      hint.smoothed_velocity_px_per_s = next_velocity;

      if (config_.predictor_enabled && !reversal) {
        const uint32_t horizon_us =
            std::min(config_.predict_horizon_us, config_.scan_frame_us);
        const float horizon_s = static_cast<float>(horizon_us) / kUsPerSecond;
        float ahead_x = next_velocity.x * horizon_s;
        float ahead_y = next_velocity.y * horizon_s;
        const float ahead_sq = ahead_x * ahead_x + ahead_y * ahead_y;
        const float max_px = static_cast<float>(config_.predict_max_px);
        const float max_sq = max_px * max_px;
        if (max_px > 0.0f && ahead_sq > max_sq) {
          const float scale = max_px / std::sqrt(ahead_sq);
          ahead_x *= scale;
          ahead_y *= scale;
        }
        if (max_px > 0.0f && horizon_us > 0 &&
            ahead_x * ahead_x + ahead_y * ahead_y > kMotionEpsilonSq) {
          hint.predicted = clamp_to_panel(
              Point{.x = current.x + ahead_x, .y = current.y + ahead_y});
          const float visible_dx = hint.predicted.x - current.x;
          const float visible_dy = hint.predicted.y - current.y;
          hint.prediction_valid =
              visible_dx * visible_dx + visible_dy * visible_dy >
              kMotionEpsilonSq;
          if (!hint.prediction_valid) {
            hint.predicted = current;
          }
        }
      }
    }
  }

  if (hooks_.on_render_hint) {
    hooks_.on_render_hint(hint);
  }

  // Resync, long gaps, tool swaps, range exit, device loss, and non-monotonic
  // timestamps all seed or clear history instead of carrying stale velocity.
  if (sample.in_range && !sample.device_lost) {
    trajectory_.point = current;
    trajectory_.velocity_px_per_s = next_velocity;
    trajectory_.ts_us = sample.ts_us;
    trajectory_.tool = sample.tool;
    trajectory_.has_point = true;
    trajectory_.has_velocity = continuous && next_has_velocity;
  } else {
    reset_trajectory();
  }
}

} // namespace pluto
