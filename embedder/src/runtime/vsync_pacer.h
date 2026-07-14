#ifndef PLUTO_RUNTIME_VSYNC_PACER_H_
#define PLUTO_RUNTIME_VSYNC_PACER_H_

#include <cstdint>
#include <mutex>
#include <vector>

#include "flutter/embedder.h"
#include "runtime/event_loop.h"

namespace pluto {

enum class VsyncPacerMode {
  kIdle,
  kInteractive,
  kAnimating,
  kThrottled,
};

class VsyncPacer {
 public:
  // One 85 Hz panel scan. Proximity (hover as well as contact) temporarily
  // replaces the normal e-ink frame cap with this latency-first cadence.
  static constexpr uint64_t kPenFrameIntervalNs = 11'764'000;

  explicit VsyncPacer(EventLoop* loop);

  void set_engine(const FlutterEngineProcTable* procs, FlutterEngine engine);
  void set_enabled(bool enabled);
  void set_mode(VsyncPacerMode mode);
  // Hard frame-rate cap for e-ink: grant Flutter at most one frame per
  // `ns` (0 = fall back to the mode intervals). Rendering faster than the
  // panel can display just burns CPU on the 2xA55, so we pace Flutter to
  // the panel's realistic content rate. Env PLUTO_FRAME_MS tunes it.
  void set_interval_ns(uint64_t ns);
  // Entered from the pen hint callback before Flutter pointer delivery.
  // Entry clears pacing debt and expedites an already-queued baton; exit
  // restores the configured/mode cadence. Thread-safe.
  void set_pen_proximity(bool in_range);
  bool pen_proximity() const;
  // Holds Flutter's next vsync baton without changing app lifecycle or
  // stopping the Dart isolate. While held, Flutter cannot begin another
  // raster frame; release grants exactly one fresh vsync so rendering resumes
  // without a burst of stale frame callbacks. Thread-safe.
  void set_rendering_paused(bool paused);
  bool rendering_paused() const;
  void request(intptr_t baton);
  // Stops scheduling new batons. Requests racing engine deinitialization are
  // retained for a final platform-thread drain instead of being posted onto
  // an EventLoop that is about to stop.
  void begin_shutdown();
  void flush();
  // Final post-Deinitialize drain and atomic engine disconnect. Flutter has
  // quiesced its callback threads when this returns in EngineHost's sequence.
  void finish_shutdown();

  // Pure pacing rule (unit-tested): token bucket. An ISOLATED request —
  // one arriving >= interval after the previous grant — fires immediately,
  // so stroke starts, taps and animation kick-offs pay ZERO pacing
  // latency; a SUSTAINED stream is granted exactly one frame per interval,
  // anchored to the previous grant so the cadence never drifts. (The old
  // rule charged EVERY frame a full `now + interval` wait — a flat 33 ms
  // of dead time on the first frame of every interaction at the default
  // cap.) last_target == 0 means no grant has been made yet.
  static uint64_t next_target_ns(uint64_t start, uint64_t last_target,
                                 uint64_t interval);

 private:
  struct PendingVsync {
    uint64_t token = 0;
    intptr_t baton = 0;
    uint64_t frame_start_ns = 0;
    uint64_t frame_target_ns = 0;
  };

  uint64_t interval_nanos_locked() const;
  void schedule(uint64_t token, uint64_t target_ns);
  void deliver(uint64_t token);

  EventLoop* loop_ = nullptr;
  const FlutterEngineProcTable* procs_ = nullptr;
  FlutterEngine engine_ = nullptr;
  mutable std::mutex mutex_;
  bool enabled_ = true;
  bool accepting_requests_ = true;
  bool rendering_paused_ = false;
  bool pen_proximity_ = false;
  VsyncPacerMode mode_ = VsyncPacerMode::kIdle;
  uint64_t interval_override_ns_ = 0;
  uint64_t last_target_ns_ = 0;
  uint64_t next_token_ = 1;
  // Flutter requires every baton to be returned before engine shutdown. The
  // normal engine issues one at a time, but keep all defensively so pause,
  // resume, and shutdown never leak a caller's baton.
  std::vector<PendingVsync> pending_vsyncs_;
};

}  // namespace pluto

#endif  // PLUTO_RUNTIME_VSYNC_PACER_H_
