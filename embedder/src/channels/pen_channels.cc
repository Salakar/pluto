#include "channels/pen_channels.h"

#include <pthread.h>
#include <sched.h>

#include <utility>

namespace pluto {
namespace {

const char* wire_event_name(PointerPhase phase) {
  switch (phase) {
    case PointerPhase::kAdd:
      return "enter";
    case PointerPhase::kRemove:
      return "leave";
    case PointerPhase::kHover:
      return "hover";
    case PointerPhase::kDown:
      return "down";
    case PointerPhase::kMove:
      return "move";
    case PointerPhase::kUp:
    case PointerPhase::kCancel:
      return "up";
  }
  return "hover";
}

int64_t wire_tool(PenTool tool) {
  return tool == PenTool::kEraser ? 2 : 1;
}

int32_t buttons_bits(bool stylus, bool stylus2) {
  return (stylus ? 1 : 0) | (stylus2 ? 2 : 0);
}

StandardValue sample_map(const PenSample& sample,
                         const pluto_pen_ring_record& record,
                         const char* event_name,
                         int32_t buttons) {
  return make_map({
      {"event", event_name},
      {"tUs", sample.ts_us},
      {"seq", static_cast<int64_t>(record.seq)},
      {"xPx", static_cast<double>(record.x_logical)},
      {"yPx", static_cast<double>(record.y_logical)},
      {"rawX", static_cast<int64_t>(sample.raw_x)},
      {"rawY", static_cast<int64_t>(sample.raw_y)},
      {"pressureRaw", static_cast<int64_t>(sample.raw_pressure)},
      {"distanceRaw", static_cast<int64_t>(sample.raw_distance)},
      {"tiltXRaw", static_cast<int64_t>(sample.tilt_x_cdeg)},
      {"tiltYRaw", static_cast<int64_t>(sample.tilt_y_cdeg)},
      {"tool", wire_tool(sample.tool)},
      {"buttons", static_cast<int64_t>(buttons)},
  });
}

}  // namespace

std::vector<StandardValue> pen_wire_events(const PenTrackerOutput& output,
                                           const AffineTransform& calibration,
                                           Orientation orientation,
                                           float panel_width,
                                           float panel_height,
                                           uint32_t* seq,
                                           int32_t* last_buttons) {
  std::vector<StandardValue> events;
  for (size_t i = 0; i < output.pointer_count; ++i) {
    const PenPointerEvent& pointer = output.pointer_events[i];
    PenSample sample = output.sample;
    sample.ts_us = pointer.ts_us;
    if (pointer.tool != PenTool::kNone) {
      sample.tool = pointer.tool;
    }
    sample.raw_x = pointer.raw_x;
    sample.raw_y = pointer.raw_y;
    sample.raw_pressure = pointer.raw_pressure;
    sample.btn_stylus = pointer.btn_stylus;
    sample.btn_stylus2 = pointer.btn_stylus2;
    const pluto_pen_ring_record record = make_pen_ring_record(
        sample, calibration, orientation, panel_width, panel_height, (*seq)++);
    events.push_back(sample_map(
        sample, record, wire_event_name(pointer.phase),
        buttons_bits(pointer.btn_stylus, pointer.btn_stylus2)));
  }
  if (output.has_sample) {
    const int32_t buttons = buttons_bits(output.sample.btn_stylus,
                                         output.sample.btn_stylus2);
    if (buttons != *last_buttons) {
      const pluto_pen_ring_record record =
          make_pen_ring_record(output.sample, calibration, orientation,
                               panel_width, panel_height, (*seq)++);
      StandardValue::Map map = *sample_map(output.sample, record, "buttons",
                                           buttons)
                                    .map();
      map.emplace_back("previousButtons",
                       static_cast<int64_t>(*last_buttons));
      events.push_back(StandardValue(std::move(map)));
      *last_buttons = buttons;
    }
  }
  return events;
}

PenService::PenService() : events_("pluto/pen/events") {
  platform_lifetime_->owner = this;
  observer_thread_ = std::thread(&PenService::observer_loop, this);
}

PenService::~PenService() {
  // Close the callback-visible owner before touching service storage. A task
  // that already acquired the gate finishes first; a queued or later task sees
  // null without ever dereferencing this object.
  {
    std::lock_guard<std::mutex> lock(platform_lifetime_->mutex);
    platform_lifetime_->owner = nullptr;
    platform_lifetime_->before_owner_use_for_testing = {};
  }
  {
    std::lock_guard<std::mutex> lock(observer_mutex_);
    observer_stopping_ = true;
  }
  observer_cv_.notify_one();
  if (observer_thread_.joinable()) {
    observer_thread_.join();
  }
  // Observer shutdown may have queued one last envelope after the callback
  // gate closed. Destruction runs on Flutter's platform thread in EngineHost,
  // so preserve the former terminal-event drain before storage disappears.
  drain_platform_events();
}

void PenService::register_with(ChannelRegistry* registry) {
  registry->register_standard_method_channel(
      "pluto/pen",
      [this](const MethodCall& call) { return handle_method(call); });
  events_.register_with(registry);
}

void PenService::set_sender(const EventSender& sender) {
  events_.set_sender(sender);
}

void PenService::set_platform_task_poster(PlatformTaskPoster poster) {
  PlatformTaskPoster post;
  {
    std::lock_guard<std::mutex> lock(platform_mutex_);
    platform_task_poster_ = std::move(poster);
    if (!platform_queue_.empty() && !platform_task_scheduled_ &&
        platform_task_poster_) {
      platform_task_scheduled_ = true;
      post = platform_task_poster_;
    }
  }
  if (post) {
    post_platform_drain(post);
  }
}

void PenService::set_axis_ranges(const PenAxisRanges& ranges) {
  std::lock_guard<std::mutex> lock(state_mutex_);
  ranges_ = ranges;
}

void PenService::set_sample_rate_estimate(double hz) {
  std::lock_guard<std::mutex> lock(state_mutex_);
  sample_rate_hz_ = hz;
}

uint64_t PenService::serialized_batch_count() const {
  return serialized_batch_count_.load(std::memory_order_acquire);
}

void PenService::drain_observer_events() {
  {
    std::unique_lock<std::mutex> lock(observer_mutex_);
    observer_drained_cv_.wait(lock, [this] {
      return observer_queue_.empty() && !observer_busy_;
    });
  }
  // EngineHost calls this from Flutter's platform thread after InkThread has
  // joined, so terminal Cancel/Remove envelopes can be delivered immediately
  // even when the EventLoop task posted for them has not run yet.
  drain_platform_events();
}

void PenService::handle_tracker_output(const PenTrackerOutput& output,
                                       const AffineTransform& calibration,
                                       Orientation orientation,
                                       float panel_width,
                                       float panel_height) {
  // Preserve the former EventChannel linearization point: listener state is
  // sampled before this batch mutates currentState. A listen that races later
  // begins with the next physical sample, never this pre-listen one.
  const uint64_t listener_token = events_.listener_token();
  int32_t current_buttons = observer_buttons_.load(std::memory_order_relaxed);
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    if (output.has_sample) {
      in_range_ = output.sample.in_range;
      contact_ = output.sample.contact;
      if (output.sample.tool != PenTool::kNone) {
        tool_ = output.sample.tool;
      }
      buttons_ = buttons_bits(output.sample.btn_stylus,
                              output.sample.btn_stylus2);
      current_buttons = buttons_;
    }
  }

  // Keep the baseline current even without a listener, but do not allocate or
  // wake the observer worker in that common case. `exchange` also captures the
  // exact pre-batch button state used when a new listener's first batch starts.
  const int32_t previous_buttons =
      observer_buttons_.exchange(current_buttons, std::memory_order_acq_rel);
  if (listener_token == 0) {
    return;
  }

  {
    std::lock_guard<std::mutex> lock(observer_mutex_);
    if (observer_stopping_) {
      return;
    }
    observer_queue_.push_back(PendingObserverBatch{
        .output = output,
        .calibration = calibration,
        .orientation = orientation,
        .panel_width = panel_width,
        .panel_height = panel_height,
        .listener_token = listener_token,
        .previous_buttons = previous_buttons,
    });
  }
  observer_cv_.notify_one();
}

void PenService::observer_loop() {
#if defined(__linux__)
  (void)pthread_setname_np(pthread_self(), "pen-observer");
  sched_param normal{};
  (void)pthread_setschedparam(pthread_self(), SCHED_OTHER, &normal);
#endif
  for (;;) {
    PendingObserverBatch batch;
    {
      std::unique_lock<std::mutex> lock(observer_mutex_);
      observer_cv_.wait(lock, [this] {
        return observer_stopping_ || !observer_queue_.empty();
      });
      if (observer_queue_.empty()) {
        if (observer_stopping_) {
          observer_drained_cv_.notify_all();
          return;
        }
        continue;
      }
      batch = std::move(observer_queue_.front());
      observer_queue_.pop_front();
      observer_busy_ = true;
    }

    deliver_observer_batch(batch);

    {
      std::lock_guard<std::mutex> lock(observer_mutex_);
      observer_busy_ = false;
      if (observer_queue_.empty()) {
        observer_drained_cv_.notify_all();
      }
    }
  }
}

void PenService::deliver_observer_batch(const PendingObserverBatch& batch) {
  if (batch.listener_token == 0 ||
      events_.listener_token() != batch.listener_token) {
    return;
  }
  if (wire_listener_token_ != batch.listener_token) {
    wire_listener_token_ = batch.listener_token;
    wire_buttons_ = batch.previous_buttons;
  }

  const std::vector<StandardValue> events = pen_wire_events(
      batch.output, batch.calibration, batch.orientation, batch.panel_width,
      batch.panel_height, &seq_, &wire_buttons_);
  serialized_batch_count_.fetch_add(1, std::memory_order_release);
  for (const StandardValue& event : events) {
    queue_platform_event(
        batch.listener_token,
        StandardMethodCodec::encode_success_envelope(event));
  }
}

void PenService::queue_platform_event(uint64_t listener_token,
                                      std::vector<uint8_t> envelope) {
  PlatformTaskPoster post;
  {
    std::lock_guard<std::mutex> lock(platform_mutex_);
    platform_queue_.push_back(PendingPlatformEvent{
        .listener_token = listener_token,
        .envelope = std::move(envelope),
    });
    if (!platform_task_scheduled_ && platform_task_poster_) {
      platform_task_scheduled_ = true;
      post = platform_task_poster_;
    }
  }
  if (post) {
    post_platform_drain(post);
  }
}

void PenService::post_platform_drain(const PlatformTaskPoster& post) {
  const std::shared_ptr<PlatformLifetimeGate> lifetime = platform_lifetime_;
  post([lifetime] {
    std::lock_guard<std::mutex> lock(lifetime->mutex);
    PenService* const owner = lifetime->owner;
    if (owner == nullptr) {
      return;
    }
    if (lifetime->before_owner_use_for_testing) {
      lifetime->before_owner_use_for_testing();
    }
    // The owner remains valid until this gate is released: destruction cannot
    // clear it or return while the posted task is inside this call.
    owner->drain_platform_events();
  });
}

void PenService::drain_platform_events() {
  std::lock_guard<std::mutex> drain_lock(platform_drain_mutex_);
  for (;;) {
    PendingPlatformEvent pending;
    {
      std::lock_guard<std::mutex> lock(platform_mutex_);
      if (platform_queue_.empty()) {
        platform_task_scheduled_ = false;
        return;
      }
      pending = std::move(platform_queue_.front());
      platform_queue_.pop_front();
    }
    events_.send_encoded_event_for_listener(
        pending.listener_token, std::move(pending.envelope));
  }
}

PlatformResponse PenService::handle_method(const MethodCall& call) const {
  if (call.method == "pen.currentState") {
    bool in_range = false;
    bool contact = false;
    PenTool tool = PenTool::kNone;
    int32_t buttons = 0;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      in_range = in_range_;
      contact = contact_;
      tool = tool_;
      buttons = buttons_;
    }
    return standard_success(make_map({
        {"isInProximity", in_range},
        {"isInContact", contact},
        {"tool", wire_tool(tool)},
        {"buttons", static_cast<int64_t>(buttons)},
    }));
  }
  if (call.method == "pen.capabilities") {
    PenAxisRanges ranges;
    double sample_rate_hz = 0.0;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      ranges = ranges_;
      sample_rate_hz = sample_rate_hz_;
    }
    return standard_success(make_map({
        {"axes", make_map({
                     {"rawXMax", static_cast<int64_t>(ranges.raw_x_max)},
                     {"rawYMax", static_cast<int64_t>(ranges.raw_y_max)},
                     {"rawPressureMax",
                      static_cast<int64_t>(ranges.raw_pressure_max)},
                     {"rawDistanceMax",
                      static_cast<int64_t>(ranges.raw_distance_max)},
                     {"rawTiltMaxCentiDegrees",
                      static_cast<int64_t>(ranges.raw_tilt_max_cdeg)},
                 })},
        {"estimatedSampleRateHz", sample_rate_hz},
    }));
  }
  return standard_unimplemented(call.method);
}

}  // namespace pluto
