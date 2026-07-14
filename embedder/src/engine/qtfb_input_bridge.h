#ifndef PLUTO_ENGINE_QTFB_INPUT_BRIDGE_H_
#define PLUTO_ENGINE_QTFB_INPUT_BRIDGE_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>
#include <unordered_map>

#include "flutter/embedder.h"
#include "presenter/qtfb/qtfb_proto.h"

namespace pluto {

// The cooperative AppLoad path already owns the tablet's evdev devices in
// Xochitl. Pluto must never fall back to opening (and EVIOCGRAB'ing) those
// devices when qtfb was selected but its AppLoad key is missing.
enum class QtfbInputPolicy {
  kUseEvdev,
  kDisabled,
  kCooperative,
  kRejectMissingKey,
};

QtfbInputPolicy qtfb_input_policy(std::string_view presenter_name,
                                  const char* qtfb_key, bool touch_enabled,
                                  bool pen_enabled);

struct QtfbPointerBatch {
  // A packet normally emits at most two events. This larger fixed capacity
  // lets shutdown cancel every bounded source without allocating in the
  // latency-sensitive input thread.
  static constexpr std::size_t kMaxEvents = (32 + 4) * 2;
  // pointer_event() fully initializes every published slot. Leaving the
  // cancellation-only capacity untouched avoids a large memset per pen move.
  std::array<FlutterPointerEvent, kMaxEvents> events;
  std::size_t event_count = 0;
  bool touch_active = false;
  bool pen_active = false;
};

// Stateful conversion from AppLoad's compact input messages to Flutter's
// pointer lifecycle. Each active source id retains a stable, collision-free
// Flutter device id through its complete press/update/release lifecycle.
class QtfbInputTranslator final {
 public:
  QtfbInputTranslator(bool touch_enabled, bool pen_enabled);

  QtfbPointerBatch consume(const qtfb::UserInputContents& input,
                           std::size_t timestamp_us);
  QtfbPointerBatch cancel_all(std::size_t timestamp_us);

 private:
  struct Contact {
    int32_t flutter_device = 0;
    double x = 0.0;
    double y = 0.0;
    double pressure = 0.0;
  };

  int32_t touch_device_for(int source_device);
  int32_t pen_device_for(int source_device);
  static FlutterPointerEvent pointer_event(FlutterPointerPhase phase,
                                           std::size_t timestamp_us,
                                           const Contact& contact,
                                           FlutterPointerDeviceKind kind,
                                           double pressure);
  static void append_terminal_events(QtfbPointerBatch* batch,
                                     std::size_t timestamp_us,
                                     const Contact& contact,
                                     FlutterPointerDeviceKind kind,
                                     FlutterPointerPhase first_phase);
  static void append_event(QtfbPointerBatch* batch,
                           const FlutterPointerEvent& event);
  void finish(QtfbPointerBatch* batch) const;

  bool touch_enabled_ = false;
  bool pen_enabled_ = false;
  std::unordered_map<int, Contact> active_touches_;
  std::unordered_map<int, Contact> active_pens_;
};

// An owned key-event description. flutter_event() borrows character storage
// from this object for the duration of FlutterEngineSendKeyEvent.
struct QtfbKeyEvent {
  FlutterKeyEventType type;
  double timestamp;
  std::uint64_t physical;
  std::uint64_t logical;
  std::array<char, 5> character;
  bool has_character;
  bool synthesized;
  FlutterKeyEventDeviceType device_type;

  FlutterKeyEvent flutter_event() const;
};

struct QtfbKeyBatch {
  // The accepted qtfb key space is bounded (ASCII, nine AppLoad virtual keys,
  // three modifiers, and three tablet buttons). This also leaves room for a
  // future layout extension without allocating in the input thread.
  static constexpr std::size_t kMaxEvents = 128;
  // Deliberately not value-initialized: consume() sees far more pointer than
  // key packets, and append_key_event initializes every field it publishes.
  // This avoids clearing the entire fixed cancellation capacity per packet.
  std::array<QtfbKeyEvent, kMaxEvents> events;
  std::size_t event_count = 0;
};

// Converts AppLoad tablet-button and virtual-keyboard packets into Flutter's
// regular down/repeat/up event model. Releases retain the physical/logical
// identity chosen at press time and shutdown synthesizes every missing up.
class QtfbKeyTranslator final {
 public:
  QtfbKeyBatch consume(const qtfb::UserInputContents& input,
                       std::size_t timestamp_us);
  QtfbKeyBatch cancel_all(std::size_t timestamp_us);

 private:
  struct PressedKey {
    std::uint64_t physical = 0;
    std::uint64_t logical = 0;
    FlutterKeyEventDeviceType device_type = kFlutterKeyEventDeviceTypeKeyboard;
  };

  std::unordered_map<std::uint64_t, PressedKey> pressed_;
};

}  // namespace pluto

#endif  // PLUTO_ENGINE_QTFB_INPUT_BRIDGE_H_
