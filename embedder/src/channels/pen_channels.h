#ifndef PLUTO_CHANNELS_PEN_CHANNELS_H_
#define PLUTO_CHANNELS_PEN_CHANNELS_H_

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "channels/channel_registry.h"
#include "channels/event_channel.h"
#include "input/pen.h"
#include "input/transform.h"

namespace pluto {

// Digitizer axis maxima reported through pen.capabilities. Values come from
// the evdev axis info once the pen device is open; the defaults are safe
// fallbacks.
struct PenAxisRanges {
  int32_t raw_x_max = 20966;
  int32_t raw_y_max = 15725;
  int32_t raw_pressure_max = 4095;
  int32_t raw_distance_max = 255;
  int32_t raw_tilt_max_cdeg = 9000;
};

// Converts one PenTracker output batch into pluto/pen/events wire maps
// (the pluto_pen package payload: tUs/xPx/yPx/rawX/rawY/pressureRaw/
// distanceRaw/tiltXRaw/tiltYRaw/tool/buttons/event). `last_buttons` carries
// button state across batches; a change appends a trailing
// {'event':'buttons'} map with previousButtons.
std::vector<StandardValue> pen_wire_events(const PenTrackerOutput& output,
                                           const AffineTransform& calibration,
                                           Orientation orientation,
                                           float panel_width,
                                           float panel_height,
                                           uint32_t* seq,
                                           int32_t* last_buttons);

// Registers the pluto/pen method channel (pen.currentState,
// pen.capabilities) and the pluto/pen/events stream. State is fed by the
// pen input thread; the channel handlers run on the platform thread.
class PenService {
 public:
  using PlatformTaskPoster =
      std::function<void(std::function<void()> platform_task)>;

  PenService();
  ~PenService();

  PenService(const PenService&) = delete;
  PenService& operator=(const PenService&) = delete;

  void register_with(ChannelRegistry* registry);
  void set_sender(const EventSender& sender);
  // Production supplies EventLoop::post_closure here. Wire maps and envelopes
  // are prepared on the observer worker; only the final EventSender call is
  // posted back to Flutter's required platform thread.
  void set_platform_task_poster(PlatformTaskPoster poster);

  bool events_active() const { return events_.has_listener(); }
  // Diagnostic/test counter: batches for which StandardValue wire payloads
  // were actually constructed. It stays at zero while no Dart listener is
  // attached, even though currentState continues to track every sample.
  uint64_t serialized_batch_count() const;
  // Waits until every observer batch accepted before this call has completed
  // serialization and EventChannel delivery. EngineHost calls this after the
  // ink reader stops and before hibernating or tearing down Flutter.
  void drain_observer_events();

  // Called from the pen input thread once the device is open.
  void set_axis_ranges(const PenAxisRanges& ranges);
  void set_sample_rate_estimate(double hz);

  // Streams one tracker batch and refreshes the currentState snapshot.
  void handle_tracker_output(const PenTrackerOutput& output,
                             const AffineTransform& calibration,
                             Orientation orientation,
                             float panel_width,
                             float panel_height);

 private:
  // Shared independently of PenService so an EventLoop closure may outlive the
  // service without retaining or dereferencing its address. A posted task must
  // hold this mutex for the complete owner call; destruction takes the same
  // gate before clearing owner, which closes the check-to-use lifetime race.
  struct PlatformLifetimeGate {
    std::mutex mutex;
    PenService* owner = nullptr;
    // Deterministic concurrency seam used only by PenServiceTestPeer. Keeping
    // it in the shared gate lets the regression pause after owner validation
    // while the lifetime lock is held, without touching PenService storage.
    std::function<void()> before_owner_use_for_testing;
  };

  friend class PenServiceTestPeer;

  struct PendingObserverBatch {
    PenTrackerOutput output;
    AffineTransform calibration;
    Orientation orientation = Orientation::kDeg0;
    float panel_width = 0.0f;
    float panel_height = 0.0f;
    uint64_t listener_token = 0;
    int32_t previous_buttons = 0;
  };

  struct PendingPlatformEvent {
    uint64_t listener_token = 0;
    std::vector<uint8_t> envelope;
  };

  PlatformResponse handle_method(const MethodCall& call) const;
  void observer_loop();
  void deliver_observer_batch(const PendingObserverBatch& batch);
  void queue_platform_event(uint64_t listener_token,
                            std::vector<uint8_t> envelope);
  void post_platform_drain(const PlatformTaskPoster& post);
  void drain_platform_events();

  EventStreamChannel events_;
  mutable std::mutex state_mutex_;
  bool in_range_ = false;
  bool contact_ = false;
  PenTool tool_ = PenTool::kNone;
  int32_t buttons_ = 0;
  PenAxisRanges ranges_;
  double sample_rate_hz_ = 0.0;

  // The SCHED_FIFO input thread performs only the small current-state update
  // above plus an ordered value-copy enqueue below. Map construction, codec
  // encoding and FlutterEngineSendPlatformMessage all run on this ordinary
  // SCHED_OTHER worker. The queue is intentionally lossless and unbounded:
  // backpressure may consume memory, but it must never punch gaps in a stroke.
  std::mutex observer_mutex_;
  std::condition_variable observer_cv_;
  std::condition_variable observer_drained_cv_;
  std::deque<PendingObserverBatch> observer_queue_;
  std::thread observer_thread_;
  bool observer_stopping_ = false;
  bool observer_busy_ = false;
  std::atomic<int32_t> observer_buttons_{0};
  std::atomic<uint64_t> serialized_batch_count_{0};

  // Observer-thread confined wire state.
  uint32_t seq_ = 0;
  int32_t wire_buttons_ = 0;
  uint64_t wire_listener_token_ = 0;

  // Envelopes cross from the normal-priority encoder worker back to Flutter's
  // platform thread. A single scheduled task drains this FIFO; lifecycle drain
  // calls the same function directly while already on the platform thread.
  std::mutex platform_mutex_;
  std::mutex platform_drain_mutex_;
  std::deque<PendingPlatformEvent> platform_queue_;
  PlatformTaskPoster platform_task_poster_;
  bool platform_task_scheduled_ = false;
  std::shared_ptr<PlatformLifetimeGate> platform_lifetime_ =
      std::make_shared<PlatformLifetimeGate>();
};

}  // namespace pluto

#endif  // PLUTO_CHANNELS_PEN_CHANNELS_H_
