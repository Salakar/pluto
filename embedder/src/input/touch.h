#ifndef PLUTO_SRC_INPUT_TOUCH_H_
#define PLUTO_SRC_INPUT_TOUCH_H_

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

#include "input/evdev.h"
#include "input/transform.h"
#include "pluto/pen_ring.h"

namespace pluto {

constexpr size_t kTouchSlotCount = 10;
constexpr uint8_t kPalmTouchMajorThreshold = 60;
constexpr int64_t kPenSuppressionLingerUs = 300000;
constexpr int64_t kFolioHoldoffUs = 200000;

enum class TouchClassification : uint8_t {
  kFinger = kPlutoTouchRingClassificationFinger,
  kPalm = kPlutoTouchRingClassificationPalm,
  kPenSuppressed = kPlutoTouchRingClassificationPenSuppressed,
  kHoldoffSuppressed = kPlutoTouchRingClassificationHoldoffSuppressed,
};

enum class TouchPhase : uint8_t {
  kBegan = kPlutoTouchRingPhaseBegan,
  kMoved = kPlutoTouchRingPhaseMoved,
  kEnded = kPlutoTouchRingPhaseEnded,
  kCancelled = kPlutoTouchRingPhaseCancelled,
};

struct TouchSlot {
  int32_t tracking_id = -1;
  uint16_t raw_x = 0;
  uint16_t raw_y = 0;
  uint8_t touch_major = 0;
  uint8_t pressure = 0;
  uint8_t distance = 0;
  uint8_t tool_type = 0;
  TouchClassification classification = TouchClassification::kFinger;
  bool flutter_active = false;
};

struct TouchEvent {
  int64_t ts_us = 0;
  uint8_t slot = 0;
  TouchPhase phase = TouchPhase::kMoved;
  TouchClassification classification = TouchClassification::kFinger;
  int32_t tracking_id = -1;
  uint16_t raw_x = 0;
  uint16_t raw_y = 0;
  uint8_t touch_major = 0;
  uint8_t pressure = 0;
  uint8_t distance = 0;
  bool emit_to_flutter = false;
};

struct TouchTrackerOutput {
  std::array<TouchEvent, kTouchSlotCount * 2> events{};
  size_t count = 0;
};

class TouchTracker {
 public:
  TouchTracker();

  TouchTrackerOutput consume(const RawEvent& event);
  TouchTrackerOutput consume_batch(const std::vector<RawEvent>& events);
  TouchTrackerOutput cancel_all(int64_t ts_us);

  void set_pen_in_range(bool in_range, int64_t ts_us);
  void begin_folio_holdoff(int64_t ts_us);
  bool pen_suppression_active(int64_t ts_us) const;

  const TouchSlot& slot(size_t index) const { return slots_[index]; }

 private:
  TouchTrackerOutput report(int64_t ts_us);
  void emit(TouchTrackerOutput* out,
            const TouchSlot& slot,
            uint8_t slot_index,
            TouchPhase phase,
            bool emit_to_flutter) const;
  TouchClassification classify_birth(const TouchSlot& slot, int64_t ts_us) const;

  std::array<TouchSlot, kTouchSlotCount> slots_{};
  std::array<TouchSlot, kTouchSlotCount> previous_{};
  uint8_t current_slot_ = 0;
  bool dirty_ = false;
  bool pen_in_range_ = false;
  int64_t last_pen_range_exit_us_ = -kPenSuppressionLingerUs;
  int64_t holdoff_until_us_ = 0;
};

// Single-producer/single-consumer bridge between the pen and touch threads.
// The pen thread publishes only proximity transitions; the touch thread syncs
// them into its TouchTracker and receives any immediate Flutter cancellation.
// A generation counter preserves a fast enter+exit pair between touch polls,
// ensuring the post-pen linger is still armed instead of losing the pulse.
class PenTouchArbiter {
 public:
  void publish(bool in_range, int64_t ts_us);
  TouchTrackerOutput sync(TouchTracker* tracker, int64_t now_us);

 private:
  // publish() is called by the single ink thread only.
  bool published_in_range_ = false;
  std::atomic<bool> in_range_{false};
  std::atomic<int64_t> transition_ts_us_{0};
  std::atomic<uint64_t> generation_{0};
  // sync() is called by the single touch thread only.
  bool observed_in_range_ = false;
  uint64_t observed_generation_ = 0;
};

enum class SystemEdgeGesture : uint8_t {
  kNone,
  kAppSwitcher,
  kHome,
};

// Recognizes system-owned two-finger edge gestures before the current Flutter
// app can complete a competing action. The digitizer cannot report a
// contact while it is physically outside the glass, so "from outside" is
// represented by both first visible samples landing in an edge band.
// Coordinates are transformed into the app's current logical orientation;
// logical 0 is the physical top and logical +Y points toward the physical
// bottom in the app's current portrait/landscape orientation.
class SystemEdgeGestureRecognizer {
 public:
  SystemEdgeGesture consume(const TouchTrackerOutput& output,
                            const AffineTransform& calibration,
                            Orientation orientation,
                            float panel_width,
                            float panel_height,
                            float dpi);
  void reset();

 private:
  struct Contact {
    bool live = false;
    bool top_eligible = false;
    bool bottom_eligible = false;
    int64_t began_us = 0;
    Point start{};
    Point current{};
  };

  std::array<Contact, kTouchSlotCount> contacts_{};
};

pluto_touch_ring_record make_touch_ring_record(const TouchEvent& event,
                                                 const AffineTransform& calibration,
                                                 Orientation orientation,
                                                 float panel_width,
                                                 float panel_height,
                                                 uint32_t seq);

}  // namespace pluto

#endif  // PLUTO_SRC_INPUT_TOUCH_H_
