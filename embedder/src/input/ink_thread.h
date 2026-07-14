#ifndef PLUTO_SRC_INPUT_INK_THREAD_H_
#define PLUTO_SRC_INPUT_INK_THREAD_H_

#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>

#include "input/evdev.h"
#include "input/pen.h"
#include "input/transform.h"

namespace pluto {

// Digitizer fallbacks when the device reports no usable axis ranges (the
// Move marker digitizer values; mirrors channels' PenAxisRanges defaults).
inline constexpr int32_t kPenRawXMaxFallback = 20966;
inline constexpr int32_t kPenRawYMaxFallback = 15725;
inline constexpr int32_t kPenRawPressureMaxFallback = 4095;

struct InkThreadConfig {
  // Empty -> kDefaultPenByPath.
  std::string device_path;
  float panel_width = 954.0f;
  float panel_height = 1696.0f;
  Orientation orientation = Orientation::kDeg0;

  // Cheap trajectory predictor used only to describe where renderer work is
  // likely to be needed. It never draws, damages, or presents pixels.
  bool predictor_enabled = true;
  // Prediction may never reach beyond one panel scan frame, even if the
  // requested horizon is larger.
  uint32_t scan_frame_us = 11764;      // 85 Hz panel scan
  uint32_t predict_horizon_us = 11764; // clamped to scan_frame_us
  uint32_t predict_max_px = 16;        // radial displacement clamp
  // Time-aware first-order velocity filter. alpha = dt / (tau + dt), so it
  // has stable behavior when digitizer scan intervals vary.
  uint32_t velocity_smoothing_tau_us = 8000;
  // Do not extrapolate across a stalled/dropped input stream.
  uint32_t trajectory_reset_gap_us = 50000;
  // Best-effort Linux SCHED_FIFO priority for the short poll/decode/handoff
  // loop. Zero disables real-time scheduling; failure is non-fatal.
  int realtime_priority = 20;

  // Deterministic host-test seam for the evdev ownership boundary. Production
  // must leave this null so EvdevSource uses the real kernel syscalls.
  const EvdevSourceOpsForTesting *evdev_ops_for_testing = nullptr;
};

// A renderer scheduling hint for one coherent evdev SYN frame. Coordinates
// are calibrated, clamped panel pixels. `previous` is meaningful only when
// has_previous is true. `predicted` always contains a safe panel point; when
// prediction_valid is false it equals current. Velocity is the time-aware
// smoothed trajectory in panel pixels/second.
//
// This is deliberately a plain, trivially-copyable value so a host may put it
// on a lock-free/SPSC handoff. It contains no framebuffer pointer, damage
// rectangle, update class, or presentation command: apps remain the sole
// source of rendered content and the renderer derives work from real pixels.
struct PenRenderHint {
  int64_t ts_us = 0;
  int64_t previous_ts_us = 0;
  Point current{};
  Point previous{};
  Point smoothed_velocity_px_per_s{};
  Point predicted{};
  PenTool tool = PenTool::kNone;
  uint8_t transition = 0;
  bool has_previous = false;
  bool prediction_valid = false;
  bool in_range = false;
  bool contact = false;
  bool device_lost = false;
};

static_assert(std::is_trivially_copyable_v<PenRenderHint>);

// Host-side callbacks. Every hook runs ON THE INK THREAD; the host owns any
// cross-thread handoff and engine pointer-event injection.
struct InkThreadHooks {
  // Fires once right after the device opens (before any sample), with the
  // evdev identity and the digitizer->panel calibration the thread derived.
  std::function<void(const DeviceIdentity &identity,
                     const AffineTransform &calibration,
                     Orientation orientation)>
      on_device_open;
  // Exact per-SYN PenTracker output. The host forwards this to Flutter, the
  // pen ring, and the pen service unchanged. For coherent samples the render
  // hint callback below always completes first.
  std::function<void(const PenTrackerOutput &output)> on_tracker_output;
  // Fires first for every coherent PenTracker sample, including proximity
  // hover, contact, lift/removal, resync, and synthesized device loss.
  std::function<void(const PenRenderHint &hint)> on_render_hint;
};

// Owns the pen evdev device on a dedicated poll(2)-driven, EVIOCGRAB'd thread.
// It is strictly an event + render-hint producer: it does not synthesize app
// ink and has no damage/present path. Pointer events reach Flutter through
// on_tracker_output with the same per-event SYN-frame consumption as before.
//
// Thread ownership: start()/stop() from the owning thread; every hook and the
// session API run on the ink thread. The session API is also the deterministic
// test seam and uses sample timestamps rather than the wall clock.
class InkThread {
public:
  InkThread(const InkThreadConfig &config, InkThreadHooks hooks);
  InkThread(const InkThread &) = delete;
  InkThread &operator=(const InkThread &) = delete;
  ~InkThread();

  // Spawns the device thread. Fails (false + *error) when the wake pipe
  // cannot be created; a missing/unopenable device is reported by the thread.
  bool start(std::string *error);
  // Signals the wake pipe and joins. An opened session publishes one terminal
  // device-loss sample (Cancel/Remove as needed) before releasing EVIOCGRAB,
  // so a warm app switch cannot retain the old app's pointer/hover state.
  // Idempotent.
  void stop();

  // -- session API (ink thread; public as the test seam) ------------------
  // orientation/raw_pressure_max remain part of the identity/calibration
  // seam consumed by hosts, although trajectory hints need only calibration.
  void begin_session(const AffineTransform &calibration,
                     Orientation orientation, int32_t raw_pressure_max);
  // `source_resynced` is true for EvdevSource's ioctl-reconstructed snapshot
  // after SYN_DROPPED. The snapshot remains real state, but it must terminate
  // trajectory continuity across the missing kernel samples.
  void process_batch(const std::vector<RawEvent> &events,
                     bool source_resynced = false);
  void handle_device_lost(int64_t ts_us);

private:
  struct TrajectoryState {
    Point point{};
    Point velocity_px_per_s{};
    int64_t ts_us = 0;
    PenTool tool = PenTool::kNone;
    bool has_point = false;
    bool has_velocity = false;
  };

  void run();
  void emit_render_hint(const PenSample &sample);
  Point clamp_to_panel(Point point) const;
  void reset_trajectory();

  InkThreadConfig config_;
  InkThreadHooks hooks_;

  std::thread thread_;
  std::atomic<bool> stop_{false};
  int wake_pipe_[2] = {-1, -1};

  // Ink-thread state (session).
  PenTracker tracker_;
  AffineTransform calib_{};
  TrajectoryState trajectory_{};
};

} // namespace pluto

#endif // PLUTO_SRC_INPUT_INK_THREAD_H_
