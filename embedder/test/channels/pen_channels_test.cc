#include "channels/pen_channels.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "gtest/gtest.h"
#include "input/evdev.h"
#include "input/ink_thread.h"

namespace pluto {

// Private test peer for pausing a posted task after it has validated the owner
// and while it holds the shared lifetime gate. Production has no hook setter.
class PenServiceTestPeer {
 public:
  static void set_before_owner_use(PenService* service,
                                   std::function<void()> hook) {
    const auto lifetime = service->platform_lifetime_;
    std::lock_guard<std::mutex> lock(lifetime->mutex);
    lifetime->before_owner_use_for_testing = std::move(hook);
  }
};

}  // namespace pluto

namespace {

using pluto::PenTracker;
using pluto::PenTrackerOutput;
using pluto::RawEvent;
using pluto::StandardValue;

const StandardValue* map_value(const StandardValue& value, const char* key) {
  const StandardValue::Map* map = value.map();
  if (map == nullptr) {
    return nullptr;
  }
  for (const auto& [k, v] : *map) {
    const std::string* name = k.string();
    if (name != nullptr && *name == key) {
      return &v;
    }
  }
  return nullptr;
}

std::string event_name(const StandardValue& value) {
  const StandardValue* event = map_value(value, "event");
  return event != nullptr && event->string() != nullptr ? *event->string()
                                                        : std::string();
}

// Feeds one evdev frame (events + SYN_REPORT) and returns wire maps.
std::vector<StandardValue> frame(PenTracker* tracker,
                                 std::vector<RawEvent> events,
                                 int64_t ts_us,
                                 uint32_t* seq,
                                 int32_t* buttons) {
  const pluto::AffineTransform calib = pluto::default_digitizer_to_panel(
      954.0f, 1696.0f, 0, 20966, 0, 15725);
  events.push_back(RawEvent{ts_us, pluto::kEvSyn, pluto::kSynReport, 0});
  std::vector<StandardValue> wire;
  for (const RawEvent& event : events) {
    const PenTrackerOutput out = tracker->consume(event);
    std::vector<StandardValue> maps = pluto::pen_wire_events(
        out, calib, pluto::Orientation::kDeg0, 954.0f, 1696.0f, seq,
        buttons);
    wire.insert(wire.end(), maps.begin(), maps.end());
  }
  return wire;
}

TEST(PenWire, StrokeLifecycleProducesPackageEvents) {
  PenTracker tracker;
  uint32_t seq = 0;
  int32_t buttons = 0;

  // Pen enters range hovering.
  std::vector<StandardValue> wire =
      frame(&tracker,
            {RawEvent{1000, pluto::kEvKey, pluto::kBtnToolPen, 1},
             RawEvent{1000, pluto::kEvAbs, pluto::kAbsX, 10483},
             RawEvent{1000, pluto::kEvAbs, pluto::kAbsY, 7862},
             RawEvent{1000, pluto::kEvAbs, pluto::kAbsDistance, 40}},
            1000, &seq, &buttons);
  ASSERT_EQ(wire.size(), 1u);
  EXPECT_EQ(event_name(wire[0]), "enter");

  // Hover move.
  wire = frame(&tracker,
               {RawEvent{1500, pluto::kEvAbs, pluto::kAbsX, 10490}},
               1500, &seq, &buttons);
  ASSERT_EQ(wire.size(), 1u);
  EXPECT_EQ(event_name(wire[0]), "hover");

  // Tip contact with pressure.
  wire = frame(&tracker,
               {RawEvent{2000, pluto::kEvKey, pluto::kBtnTouch, 1},
                RawEvent{2000, pluto::kEvAbs, pluto::kAbsPressure, 2048},
                RawEvent{2000, pluto::kEvAbs, pluto::kAbsTiltX, 1500},
                RawEvent{2000, pluto::kEvAbs, pluto::kAbsTiltY, -500}},
               2000, &seq, &buttons);
  ASSERT_EQ(wire.size(), 1u);
  EXPECT_EQ(event_name(wire[0]), "down");
  EXPECT_EQ(*map_value(wire[0], "pressureRaw")->integer(), 2048);
  EXPECT_EQ(*map_value(wire[0], "tiltXRaw")->integer(), 1500);
  EXPECT_EQ(*map_value(wire[0], "tiltYRaw")->integer(), -500);
  EXPECT_EQ(*map_value(wire[0], "tool")->integer(), 1);
  EXPECT_EQ(*map_value(wire[0], "tUs")->integer(), 2000);
  // Mid-panel raw coordinates land mid-panel in logical space.
  const double x = *std::get_if<double>(&map_value(wire[0], "xPx")->storage());
  const double y = *std::get_if<double>(&map_value(wire[0], "yPx")->storage());
  EXPECT_NEAR(x, 954.0 / 2, 2.0);
  EXPECT_NEAR(y, 1696.0 / 2, 2.0);

  // Move while touching.
  wire = frame(&tracker,
               {RawEvent{3000, pluto::kEvAbs, pluto::kAbsX, 12000}},
               3000, &seq, &buttons);
  ASSERT_EQ(wire.size(), 1u);
  EXPECT_EQ(event_name(wire[0]), "move");

  // Lift and leave range.
  wire = frame(&tracker,
               {RawEvent{4000, pluto::kEvKey, pluto::kBtnTouch, 0},
                RawEvent{4000, pluto::kEvAbs, pluto::kAbsPressure, 0}},
               4000, &seq, &buttons);
  ASSERT_EQ(wire.size(), 1u);
  EXPECT_EQ(event_name(wire[0]), "up");

  wire = frame(&tracker,
               {RawEvent{5000, pluto::kEvKey, pluto::kBtnToolPen, 0}},
               5000, &seq, &buttons);
  ASSERT_EQ(wire.size(), 1u);
  EXPECT_EQ(event_name(wire[0]), "leave");
}

TEST(PenWire, EraserToolAndButtonsAreReported) {
  PenTracker tracker;
  uint32_t seq = 0;
  int32_t buttons = 0;

  std::vector<StandardValue> wire =
      frame(&tracker,
            {RawEvent{1000, pluto::kEvKey, pluto::kBtnToolRubber, 1},
             RawEvent{1000, pluto::kEvAbs, pluto::kAbsX, 100},
             RawEvent{1000, pluto::kEvAbs, pluto::kAbsY, 100}},
            1000, &seq, &buttons);
  ASSERT_GE(wire.size(), 1u);
  EXPECT_EQ(*map_value(wire[0], "tool")->integer(), 2);

  // Barrel button press produces a trailing buttons event.
  wire = frame(&tracker,
               {RawEvent{2000, pluto::kEvKey, pluto::kBtnStylus, 1}},
               2000, &seq, &buttons);
  ASSERT_GE(wire.size(), 2u);
  const StandardValue& last = wire.back();
  EXPECT_EQ(event_name(last), "buttons");
  EXPECT_EQ(*map_value(last, "buttons")->integer(), 1);
  EXPECT_EQ(*map_value(last, "previousButtons")->integer(), 0);
  EXPECT_EQ(buttons, 1);
}

TEST(PenService, MethodChannelReportsStateAndCapabilities) {
  pluto::PenService service;
  pluto::ChannelRegistry registry;
  service.register_with(&registry);

  // Push one contact frame through the service.
  PenTracker tracker;
  const pluto::AffineTransform calib = pluto::default_digitizer_to_panel(
      954.0f, 1696.0f, 0, 20966, 0, 15725);
  for (const RawEvent& event :
       {RawEvent{1000, pluto::kEvKey, pluto::kBtnToolPen, 1},
        RawEvent{1000, pluto::kEvKey, pluto::kBtnTouch, 1},
        RawEvent{1000, pluto::kEvAbs, pluto::kAbsPressure, 900},
        RawEvent{1000, pluto::kEvSyn, pluto::kSynReport, 0}}) {
    service.handle_tracker_output(tracker.consume(event), calib,
                                  pluto::Orientation::kDeg0, 954.0f,
                                  1696.0f);
  }
  EXPECT_EQ(service.serialized_batch_count(), 0u)
      << "currentState must update without constructing event wire maps";
  pluto::PenAxisRanges ranges;
  ranges.raw_pressure_max = 4095;
  service.set_axis_ranges(ranges);

  auto invoke = [&registry](const std::string& method) {
    const std::vector<uint8_t> payload =
        pluto::StandardMethodCodec::encode_method_call(
            pluto::MethodCall{method, {}});
    FlutterPlatformMessage message{};
    message.struct_size = sizeof(message);
    message.channel = "pluto/pen";
    message.message = payload.data();
    message.message_size = payload.size();
    message.response_handle =
        reinterpret_cast<const FlutterPlatformMessageResponseHandle*>(1);
    std::vector<uint8_t> response;
    registry.handle_message(message,
                            [&response](const pluto::PlatformResponse& data) {
                              response = data;
                            });
    StandardValue value;
    if (!response.empty() && response[0] == 0) {
      value = pluto::StandardMethodCodec::decode_success_envelope(
                  response.data(), response.size())
                  .value_or(StandardValue());
    }
    return value;
  };

  const StandardValue state = invoke("pen.currentState");
  ASSERT_NE(map_value(state, "isInContact"), nullptr);
  EXPECT_TRUE(*map_value(state, "isInContact")->boolean());
  EXPECT_TRUE(*map_value(state, "isInProximity")->boolean());
  EXPECT_EQ(*map_value(state, "tool")->integer(), 1);

  const StandardValue caps = invoke("pen.capabilities");
  const StandardValue* axes = map_value(caps, "axes");
  ASSERT_NE(axes, nullptr);
  EXPECT_EQ(*map_value(*axes, "rawPressureMax")->integer(), 4095);
  ASSERT_NE(map_value(caps, "estimatedSampleRateHz"), nullptr);
}

TEST(PenService, EventWireMapsAreBuiltOnlyWhileAListenerIsAttached) {
  pluto::PenService service;
  pluto::ChannelRegistry registry;
  service.register_with(&registry);
  std::vector<std::vector<uint8_t>> sent;
  service.set_sender([&sent](const std::string& channel,
                            const std::vector<uint8_t>& message) {
    EXPECT_EQ(channel, "pluto/pen/events");
    sent.push_back(message);
  });

  PenTracker tracker;
  const pluto::AffineTransform calib = pluto::default_digitizer_to_panel(
      954.0f, 1696.0f, 0, 20966, 0, 15725);
  auto feed = [&](const std::vector<RawEvent>& events) {
    for (const RawEvent& event : events) {
      const PenTrackerOutput output = tracker.consume(event);
      if (output.has_sample || output.pointer_count != 0) {
        service.handle_tracker_output(output, calib,
                                      pluto::Orientation::kDeg0, 954.0f,
                                      1696.0f);
      }
    }
  };

  feed({RawEvent{1000, pluto::kEvKey, pluto::kBtnToolPen, 1},
        RawEvent{1000, pluto::kEvAbs, pluto::kAbsX, 100},
        RawEvent{1000, pluto::kEvAbs, pluto::kAbsY, 200},
        RawEvent{1000, pluto::kEvSyn, pluto::kSynReport, 0}});
  EXPECT_EQ(service.serialized_batch_count(), 0u);
  EXPECT_TRUE(sent.empty());

  const std::vector<uint8_t> listen =
      pluto::StandardMethodCodec::encode_method_call(
          pluto::MethodCall{"listen", {}});
  FlutterPlatformMessage message{};
  message.struct_size = sizeof(message);
  message.channel = "pluto/pen/events";
  message.message = listen.data();
  message.message_size = listen.size();
  registry.handle_message(message, [](const pluto::PlatformResponse&) {});
  EXPECT_TRUE(service.events_active());

  feed({RawEvent{2000, pluto::kEvAbs, pluto::kAbsX, 150},
        RawEvent{2000, pluto::kEvSyn, pluto::kSynReport, 0}});
  service.drain_observer_events();
  EXPECT_EQ(service.serialized_batch_count(), 1u);
  ASSERT_EQ(sent.size(), 1u);
  const auto envelope = pluto::StandardMethodCodec::decode_success_envelope(
      sent[0].data(), sent[0].size());
  ASSERT_TRUE(envelope.has_value());
  EXPECT_EQ(event_name(*envelope), "hover");
}

TEST(PenService, SlowObserverNeverBlocksInkHintsAndDeliveryStaysOrdered) {
  using namespace std::chrono_literals;

  pluto::PenService service;
  pluto::ChannelRegistry registry;
  service.register_with(&registry);

  std::mutex platform_mutex;
  std::condition_variable platform_cv;
  std::deque<std::function<void()>> platform_tasks;
  bool platform_stop = false;
  std::thread platform_thread([&] {
    for (;;) {
      std::function<void()> task;
      {
        std::unique_lock<std::mutex> lock(platform_mutex);
        platform_cv.wait(lock, [&] {
          return platform_stop || !platform_tasks.empty();
        });
        if (platform_tasks.empty()) {
          if (platform_stop) {
            return;
          }
          continue;
        }
        task = std::move(platform_tasks.front());
        platform_tasks.pop_front();
      }
      task();
    }
  });
  const std::thread::id expected_platform_thread = platform_thread.get_id();
  service.set_platform_task_poster([&](std::function<void()> task) {
    {
      std::lock_guard<std::mutex> lock(platform_mutex);
      platform_tasks.push_back(std::move(task));
    }
    platform_cv.notify_one();
  });

  std::mutex sender_mutex;
  std::condition_variable sender_cv;
  bool sender_entered = false;
  bool release_sender = false;
  std::thread::id sender_thread;
  std::vector<StandardValue> delivered;
  service.set_sender([&](const std::string& channel,
                         const std::vector<uint8_t>& message) {
    EXPECT_EQ(channel, "pluto/pen/events");
    {
      std::unique_lock<std::mutex> lock(sender_mutex);
      sender_thread = std::this_thread::get_id();
      sender_entered = true;
      sender_cv.notify_all();
      sender_cv.wait(lock, [&] { return release_sender; });
    }
    const auto envelope =
        pluto::StandardMethodCodec::decode_success_envelope(message.data(),
                                                               message.size());
    if (envelope.has_value()) {
      std::lock_guard<std::mutex> lock(sender_mutex);
      delivered.push_back(*envelope);
    }
  });

  const std::vector<uint8_t> listen =
      pluto::StandardMethodCodec::encode_method_call(
          pluto::MethodCall{"listen", {}});
  FlutterPlatformMessage listen_message{};
  listen_message.struct_size = sizeof(listen_message);
  listen_message.channel = "pluto/pen/events";
  listen_message.message = listen.data();
  listen_message.message_size = listen.size();
  registry.handle_message(listen_message,
                          [](const pluto::PlatformResponse&) {});
  EXPECT_TRUE(service.events_active());

  constexpr size_t sample_count = 24;
  constexpr int64_t first_ts_us = 1000;
  constexpr int64_t sample_period_us = 5000;
  std::vector<RawEvent> buffered_frames;
  for (size_t i = 0; i < sample_count; ++i) {
    const int64_t ts_us =
        first_ts_us + static_cast<int64_t>(i) * sample_period_us;
    if (i == 0) {
      buffered_frames.push_back(
          RawEvent{ts_us, pluto::kEvKey, pluto::kBtnToolPen, 1});
    }
    if (i == 8) {
      buffered_frames.push_back(
          RawEvent{ts_us, pluto::kEvKey, pluto::kBtnStylus, 1});
    } else if (i == 16) {
      buffered_frames.push_back(
          RawEvent{ts_us, pluto::kEvKey, pluto::kBtnStylus, 0});
    }
    buffered_frames.push_back(RawEvent{
        ts_us, pluto::kEvAbs, pluto::kAbsX, static_cast<int32_t>(10 + i)});
    buffered_frames.push_back(
        RawEvent{ts_us, pluto::kEvAbs, pluto::kAbsY, 40});
    buffered_frames.push_back(
        RawEvent{ts_us, pluto::kEvSyn, pluto::kSynReport, 0});
  }

  const pluto::AffineTransform identity{
      .a = 1.0f,
      .b = 0.0f,
      .c = 0.0f,
      .d = 0.0f,
      .e = 1.0f,
      .f = 0.0f,
  };
  std::atomic<size_t> hint_count{0};
  pluto::InkThreadHooks hooks;
  hooks.on_render_hint = [&](const pluto::PenRenderHint&) {
    hint_count.fetch_add(1, std::memory_order_release);
  };
  hooks.on_tracker_output = [&](const PenTrackerOutput& output) {
    service.handle_tracker_output(output, identity,
                                  pluto::Orientation::kDeg0, 256.0f, 256.0f);
  };
  pluto::InkThreadConfig ink_config;
  ink_config.panel_width = 256.0f;
  ink_config.panel_height = 256.0f;
  pluto::InkThread ink(ink_config, std::move(hooks));
  ink.begin_session(identity, pluto::Orientation::kDeg0, 4095);

  std::mutex producer_mutex;
  std::condition_variable producer_cv;
  bool producer_done = false;
  std::thread producer([&] {
    ink.process_batch(buffered_frames);
    {
      std::lock_guard<std::mutex> lock(producer_mutex);
      producer_done = true;
    }
    producer_cv.notify_all();
  });

  bool observer_actually_blocked = false;
  {
    std::unique_lock<std::mutex> lock(sender_mutex);
    observer_actually_blocked =
        sender_cv.wait_for(lock, 1s, [&] { return sender_entered; });
  }
  bool input_finished_while_observer_blocked = false;
  {
    std::unique_lock<std::mutex> lock(producer_mutex);
    input_finished_while_observer_blocked =
        producer_cv.wait_for(lock, 250ms, [&] { return producer_done; });
  }

  // Always release and join before asserting, so a regression fails cleanly
  // instead of stranding the observer or producer test threads.
  {
    std::lock_guard<std::mutex> lock(sender_mutex);
    release_sender = true;
  }
  sender_cv.notify_all();
  producer.join();
  service.drain_observer_events();
  {
    std::lock_guard<std::mutex> lock(platform_mutex);
    platform_stop = true;
  }
  platform_cv.notify_all();
  platform_thread.join();

  EXPECT_TRUE(observer_actually_blocked);
  EXPECT_TRUE(input_finished_while_observer_blocked);
  EXPECT_EQ(sender_thread, expected_platform_thread);
  EXPECT_EQ(hint_count.load(std::memory_order_acquire), sample_count);
  EXPECT_EQ(service.serialized_batch_count(), sample_count);

  ASSERT_EQ(delivered.size(), sample_count + 2u);
  std::vector<int64_t> pointer_timestamps;
  size_t button_event_count = 0;
  for (size_t i = 0; i < delivered.size(); ++i) {
    ASSERT_NE(map_value(delivered[i], "seq"), nullptr);
    EXPECT_EQ(*map_value(delivered[i], "seq")->integer(),
              static_cast<int64_t>(i));
    if (event_name(delivered[i]) == "buttons") {
      ASSERT_NE(map_value(delivered[i], "previousButtons"), nullptr);
      const int64_t expected_previous = button_event_count == 0 ? 0 : 1;
      const int64_t expected_current = button_event_count == 0 ? 1 : 0;
      EXPECT_EQ(*map_value(delivered[i], "previousButtons")->integer(),
                expected_previous);
      EXPECT_EQ(*map_value(delivered[i], "buttons")->integer(),
                expected_current);
      ++button_event_count;
    } else {
      pointer_timestamps.push_back(
          *map_value(delivered[i], "tUs")->integer());
    }
  }
  EXPECT_EQ(button_event_count, 2u);
  ASSERT_EQ(pointer_timestamps.size(), sample_count);
  for (size_t i = 0; i < pointer_timestamps.size(); ++i) {
    EXPECT_EQ(pointer_timestamps[i],
              first_ts_us + static_cast<int64_t>(i) * sample_period_us);
  }
}

TEST(PenService, DestructionWaitsForPreemptedPostedTaskAndLateCopyIsSafe) {
  using namespace std::chrono_literals;

  std::mutex posted_mutex;
  std::condition_variable posted_cv;
  std::function<void()> posted_task;
  std::atomic<size_t> send_count{0};

  auto service = std::make_unique<pluto::PenService>();
  pluto::ChannelRegistry registry;
  service->register_with(&registry);
  service->set_sender([&](const std::string&,
                          const std::vector<uint8_t>&) {
    send_count.fetch_add(1, std::memory_order_release);
  });
  service->set_platform_task_poster([&](std::function<void()> task) {
    {
      std::lock_guard<std::mutex> lock(posted_mutex);
      posted_task = std::move(task);
    }
    posted_cv.notify_all();
  });

  const std::vector<uint8_t> listen =
      pluto::StandardMethodCodec::encode_method_call(
          pluto::MethodCall{"listen", {}});
  FlutterPlatformMessage listen_message{};
  listen_message.struct_size = sizeof(listen_message);
  listen_message.channel = "pluto/pen/events";
  listen_message.message = listen.data();
  listen_message.message_size = listen.size();
  registry.handle_message(listen_message,
                          [](const pluto::PlatformResponse&) {});

  PenTracker tracker;
  const pluto::AffineTransform identity{
      .a = 1.0f,
      .b = 0.0f,
      .c = 0.0f,
      .d = 0.0f,
      .e = 1.0f,
      .f = 0.0f,
  };
  for (const RawEvent& event :
       {RawEvent{1000, pluto::kEvKey, pluto::kBtnToolPen, 1},
        RawEvent{1000, pluto::kEvAbs, pluto::kAbsX, 24},
        RawEvent{1000, pluto::kEvAbs, pluto::kAbsY, 32},
        RawEvent{1000, pluto::kEvSyn, pluto::kSynReport, 0}}) {
    const PenTrackerOutput output = tracker.consume(event);
    if (output.has_sample || output.pointer_count != 0) {
      service->handle_tracker_output(output, identity,
                                     pluto::Orientation::kDeg0, 256.0f,
                                     256.0f);
    }
  }

  {
    std::unique_lock<std::mutex> lock(posted_mutex);
    ASSERT_TRUE(posted_cv.wait_for(lock, 1s,
                                   [&] { return static_cast<bool>(posted_task); }));
  }
  // A copied EventLoop closure deliberately survives service destruction.
  // Its shared gate, not a captured PenService address, is its only state.
  std::function<void()> late_task = posted_task;

  std::mutex gate_hook_mutex;
  std::condition_variable gate_hook_cv;
  bool gate_hook_entered = false;
  bool release_gate_hook = false;
  pluto::PenServiceTestPeer::set_before_owner_use(service.get(), [&] {
    std::unique_lock<std::mutex> lock(gate_hook_mutex);
    gate_hook_entered = true;
    gate_hook_cv.notify_all();
    gate_hook_cv.wait(lock, [&] { return release_gate_hook; });
  });

  std::thread platform_thread([task = std::move(posted_task)]() mutable {
    task();
  });
  bool observed_gate_hook = false;
  {
    std::unique_lock<std::mutex> lock(gate_hook_mutex);
    observed_gate_hook =
        gate_hook_cv.wait_for(lock, 1s, [&] { return gate_hook_entered; });
  }

  std::mutex destruction_mutex;
  std::condition_variable destruction_cv;
  bool destruction_started = false;
  bool destruction_finished = false;
  std::thread destroyer(
      [owned = std::move(service), &destruction_mutex, &destruction_cv,
       &destruction_started, &destruction_finished]() mutable {
        {
          std::lock_guard<std::mutex> lock(destruction_mutex);
          destruction_started = true;
        }
        destruction_cv.notify_all();
        owned.reset();
        {
          std::lock_guard<std::mutex> lock(destruction_mutex);
          destruction_finished = true;
        }
        destruction_cv.notify_all();
      });
  bool observed_destruction_start = false;
  bool destruction_finished_while_gate_held = false;
  {
    std::unique_lock<std::mutex> lock(destruction_mutex);
    observed_destruction_start = destruction_cv.wait_for(
        lock, 1s, [&] { return destruction_started; });
    if (observed_gate_hook && observed_destruction_start) {
      destruction_finished_while_gate_held = destruction_cv.wait_for(
          lock, 50ms, [&] { return destruction_finished; });
    }
  }

  // No fatal assertion is allowed after either thread starts: always release
  // the injected pause and join both threads before reporting expectations.
  {
    std::lock_guard<std::mutex> lock(gate_hook_mutex);
    release_gate_hook = true;
  }
  gate_hook_cv.notify_all();
  platform_thread.join();
  destroyer.join();
  EXPECT_TRUE(observed_gate_hook);
  EXPECT_TRUE(observed_destruction_start);
  EXPECT_TRUE(!destruction_finished_while_gate_held)
      << "destruction must wait while a posted task owns the lifetime gate";
  EXPECT_EQ(send_count.load(std::memory_order_acquire), 1u);

  // This closure was queued before destruction but runs afterwards. It must
  // find a null owner and return without a raw-this read or another send.
  late_task();
  EXPECT_EQ(send_count.load(std::memory_order_acquire), 1u);
}

}  // namespace
