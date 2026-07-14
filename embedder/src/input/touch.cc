#include "input/touch.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>

namespace pluto {
namespace {

uint16_t clamp_u16(int32_t value) {
  return static_cast<uint16_t>(std::clamp(value, 0, 0xffff));
}

uint8_t clamp_u8(int32_t value) {
  return static_cast<uint8_t>(std::clamp(value, 0, 0xff));
}

bool changed_contact_fields(const TouchSlot& a, const TouchSlot& b) {
  return a.raw_x != b.raw_x || a.raw_y != b.raw_y ||
         a.touch_major != b.touch_major || a.pressure != b.pressure ||
         a.distance != b.distance || a.tool_type != b.tool_type;
}

}  // namespace

TouchTracker::TouchTracker() {
  for (TouchSlot& slot : slots_) {
    slot.tracking_id = -1;
  }
  previous_ = slots_;
}

TouchTrackerOutput TouchTracker::consume(const RawEvent& event) {
  if (event.type == kEvAbs) {
    if (event.code == kAbsMtSlot) {
      current_slot_ = static_cast<uint8_t>(
          std::clamp(event.value, 0, static_cast<int32_t>(kTouchSlotCount - 1)));
      return TouchTrackerOutput{};
    }

    TouchSlot& slot = slots_[current_slot_];
    switch (event.code) {
      case kAbsMtTrackingId:
        slot.tracking_id = event.value;
        dirty_ = true;
        break;
      case kAbsMtPositionX:
        slot.raw_x = clamp_u16(event.value);
        dirty_ = true;
        break;
      case kAbsMtPositionY:
        slot.raw_y = clamp_u16(event.value);
        dirty_ = true;
        break;
      case kAbsMtTouchMajor:
        slot.touch_major = clamp_u8(event.value);
        dirty_ = true;
        break;
      case kAbsMtPressure:
        slot.pressure = clamp_u8(event.value);
        dirty_ = true;
        break;
      case kAbsMtDistance:
        slot.distance = clamp_u8(event.value);
        dirty_ = true;
        break;
      case kAbsMtToolType:
        slot.tool_type = clamp_u8(event.value);
        dirty_ = true;
        break;
      default:
        break;
    }
    return TouchTrackerOutput{};
  }

  if (event.type == kEvSyn && event.code == kSynDropped) {
    return cancel_all(event.ts_us);
  }

  if (event.type == kEvSyn && event.code == kSynReport) {
    return report(event.ts_us);
  }

  return TouchTrackerOutput{};
}

TouchTrackerOutput TouchTracker::consume_batch(const std::vector<RawEvent>& events) {
  TouchTrackerOutput out;
  for (const RawEvent& event : events) {
    TouchTrackerOutput next = consume(event);
    if (next.count > 0) {
      out = next;
    }
  }
  return out;
}

TouchTrackerOutput TouchTracker::cancel_all(int64_t ts_us) {
  TouchTrackerOutput out;
  for (uint8_t i = 0; i < kTouchSlotCount; ++i) {
    TouchSlot& slot = slots_[i];
    if (slot.tracking_id >= 0) {
      emit(&out, slot, i, TouchPhase::kCancelled, slot.flutter_active);
      out.events[out.count - 1].ts_us = ts_us;
      slot.flutter_active = false;
      slot.classification = TouchClassification::kPenSuppressed;
      slot.tracking_id = -1;
    }
  }
  previous_ = slots_;
  dirty_ = false;
  return out;
}

void TouchTracker::set_pen_in_range(bool in_range, int64_t ts_us) {
  if (pen_in_range_ && !in_range) {
    last_pen_range_exit_us_ = ts_us;
  }
  if (!pen_in_range_ && in_range) {
    dirty_ = true;
  }
  pen_in_range_ = in_range;
}

void TouchTracker::begin_folio_holdoff(int64_t ts_us) {
  holdoff_until_us_ = ts_us + kFolioHoldoffUs;
}

bool TouchTracker::pen_suppression_active(int64_t ts_us) const {
  return pen_in_range_ || (ts_us - last_pen_range_exit_us_) < kPenSuppressionLingerUs;
}

TouchClassification TouchTracker::classify_birth(const TouchSlot& slot,
                                                 int64_t ts_us) const {
  if (ts_us < holdoff_until_us_) {
    return TouchClassification::kHoldoffSuppressed;
  }
  if (pen_suppression_active(ts_us)) {
    return TouchClassification::kPenSuppressed;
  }
  if (slot.touch_major > kPalmTouchMajorThreshold) {
    return TouchClassification::kPalm;
  }
  return TouchClassification::kFinger;
}

void TouchTracker::emit(TouchTrackerOutput* out,
                        const TouchSlot& slot,
                        uint8_t slot_index,
                        TouchPhase phase,
                        bool emit_to_flutter) const {
  if (out->count >= out->events.size()) {
    return;
  }
  out->events[out->count++] = TouchEvent{
      .ts_us = 0,
      .slot = slot_index,
      .phase = phase,
      .classification = slot.classification,
      .tracking_id = slot.tracking_id,
      .raw_x = slot.raw_x,
      .raw_y = slot.raw_y,
      .touch_major = slot.touch_major,
      .pressure = slot.pressure,
      .distance = slot.distance,
      .emit_to_flutter = emit_to_flutter,
  };
}

TouchTrackerOutput TouchTracker::report(int64_t ts_us) {
  TouchTrackerOutput out;
  if (!dirty_) {
    return out;
  }

  for (uint8_t i = 0; i < kTouchSlotCount; ++i) {
    TouchSlot& current = slots_[i];
    const TouchSlot& previous = previous_[i];
    const bool was_live = previous.tracking_id >= 0;
    const bool is_live = current.tracking_id >= 0;

    if (!was_live && !is_live) {
      continue;
    }

    if (was_live && (!is_live || previous.tracking_id != current.tracking_id)) {
      TouchSlot ending = previous;
      emit(&out, ending, i,
           previous.flutter_active ? TouchPhase::kEnded : TouchPhase::kEnded,
           previous.flutter_active);
    }

    if (is_live && (!was_live || previous.tracking_id != current.tracking_id)) {
      current.classification = classify_birth(current, ts_us);
      current.flutter_active =
          current.classification == TouchClassification::kFinger;
      emit(&out, current, i, TouchPhase::kBegan, current.flutter_active);
      continue;
    }

    current.classification = previous.classification;
    current.flutter_active = previous.flutter_active;

    if (current.classification == TouchClassification::kFinger) {
      if (pen_suppression_active(ts_us)) {
        current.classification = TouchClassification::kPenSuppressed;
        current.flutter_active = false;
        emit(&out, current, i, TouchPhase::kCancelled, true);
      } else if (current.touch_major > kPalmTouchMajorThreshold) {
        current.classification = TouchClassification::kPalm;
        current.flutter_active = false;
        emit(&out, current, i, TouchPhase::kCancelled, true);
      } else if (changed_contact_fields(current, previous)) {
        emit(&out, current, i, TouchPhase::kMoved, true);
      }
    } else if (changed_contact_fields(current, previous)) {
      emit(&out, current, i, TouchPhase::kMoved, false);
    }
  }

  for (size_t i = 0; i < out.count; ++i) {
    out.events[i].ts_us = ts_us;
  }
  previous_ = slots_;
  dirty_ = false;
  return out;
}

void PenTouchArbiter::publish(bool in_range, int64_t ts_us) {
  if (in_range == published_in_range_) {
    return;
  }
  published_in_range_ = in_range;
  transition_ts_us_.store(ts_us, std::memory_order_relaxed);
  in_range_.store(in_range, std::memory_order_relaxed);
  generation_.fetch_add(1, std::memory_order_release);
}

TouchTrackerOutput PenTouchArbiter::sync(TouchTracker* tracker,
                                         int64_t now_us) {
  if (tracker == nullptr) {
    return TouchTrackerOutput{};
  }
  const uint64_t generation = generation_.load(std::memory_order_acquire);
  if (generation == observed_generation_) {
    return TouchTrackerOutput{};
  }
  const bool in_range = in_range_.load(std::memory_order_relaxed);
  const int64_t transition_ts =
      transition_ts_us_.load(std::memory_order_relaxed);

  // If the pen entered and exited entirely between touch polls, replay that
  // pulse locally. This cancels any active touch and arms the normal linger.
  if (!observed_in_range_ && !in_range &&
      generation - observed_generation_ > 1) {
    tracker->set_pen_in_range(true, transition_ts);
    tracker->set_pen_in_range(false, transition_ts);
  } else {
    tracker->set_pen_in_range(in_range, transition_ts);
  }
  observed_in_range_ = in_range;
  observed_generation_ = generation;
  return tracker->consume(RawEvent{.ts_us = std::max(now_us, transition_ts),
                                   .type = kEvSyn,
                                   .code = kSynReport,
                                   .value = 0});
}

SystemEdgeGesture SystemEdgeGestureRecognizer::consume(
    const TouchTrackerOutput& output,
    const AffineTransform& calibration,
    Orientation orientation,
    float panel_width,
    float panel_height,
    float dpi) {
  const Size logical = logical_size(panel_width, panel_height, orientation);
  const float pixels_per_cm = std::max(1.0f, dpi / 2.54f);
  // Finger placement at a bezel edge is imprecise, especially when entering
  // from outside the glass. Keep a generous capture band and accept a short,
  // visibly intentional inward motion. Exact two-finger arbitration plus the
  // palm and pen classifiers still protect ordinary app input.
  const float top_edge_depth = 1.4f * pixels_per_cm;
  const float bottom_edge_depth = 2.8f * pixels_per_cm;
  const float trigger_distance = 0.65f * pixels_per_cm;
  const float min_separation = 0.2f * pixels_per_cm;
  const float max_separation = 5.0f * pixels_per_cm;
  const float max_horizontal_drift = 1.8f * pixels_per_cm;
  const float max_parallel_delta = 1.2f * pixels_per_cm;
  constexpr int64_t kContactSyncWindowUs = 350000;
  constexpr int64_t kGestureTimeoutUs = 1500000;

  for (size_t i = 0; i < output.count; ++i) {
    const TouchEvent& event = output.events[i];
    if (event.slot >= contacts_.size()) {
      continue;
    }
    Contact& contact = contacts_[event.slot];
    // A live finger can be reclassified as palm- or pen-suppressed on the
    // cancellation sample. Always retire terminal phases, irrespective of
    // their final classification, or that slot would poison all later
    // two-finger gestures until process restart.
    if (event.phase == TouchPhase::kEnded ||
        event.phase == TouchPhase::kCancelled) {
      contact = Contact{};
      continue;
    }
    if (event.classification != TouchClassification::kFinger ||
        !event.emit_to_flutter) {
      continue;
    }
    const Point panel = calibration.apply(
        Point{static_cast<float>(event.raw_x),
              static_cast<float>(event.raw_y)});
    const Point point =
        panel_to_logical(panel, panel_width, panel_height, orientation);
    switch (event.phase) {
      case TouchPhase::kBegan:
        contact.live = true;
        contact.top_eligible = point.y <= top_edge_depth;
        contact.bottom_eligible =
            point.y >= logical.height - bottom_edge_depth;
        contact.began_us = event.ts_us;
        contact.start = point;
        contact.current = point;
        break;
      case TouchPhase::kMoved:
        if (contact.live) {
          contact.current = point;
        }
        break;
      case TouchPhase::kEnded:
      case TouchPhase::kCancelled:
        break;
    }
  }

  const Contact* first = nullptr;
  const Contact* second = nullptr;
  size_t live_contacts = 0;
  for (const Contact& contact : contacts_) {
    if (!contact.live) {
      continue;
    }
    ++live_contacts;
    if (first == nullptr) {
      first = &contact;
    } else if (second == nullptr) {
      second = &contact;
    }
  }
  if (live_contacts != 2 || first == nullptr || second == nullptr) {
    return SystemEdgeGesture::kNone;
  }
  if (std::llabs(first->began_us - second->began_us) >
      kContactSyncWindowUs) {
    return SystemEdgeGesture::kNone;
  }
  const int64_t latest_began = std::max(first->began_us, second->began_us);
  const int64_t latest_sample = output.count == 0
                                    ? latest_began
                                    : output.events[output.count - 1].ts_us;
  if (latest_sample - latest_began > kGestureTimeoutUs) {
    return SystemEdgeGesture::kNone;
  }
  const float separation = std::abs(first->start.x - second->start.x);
  if (separation < min_separation || separation > max_separation) {
    return SystemEdgeGesture::kNone;
  }
  const float first_horizontal = std::abs(first->current.x - first->start.x);
  const float second_horizontal =
      std::abs(second->current.x - second->start.x);
  if (first_horizontal > max_horizontal_drift ||
      second_horizontal > max_horizontal_drift) {
    return SystemEdgeGesture::kNone;
  }

  const auto matches_inward = [&](float first_inward, float second_inward) {
    return first_inward >= trigger_distance &&
           second_inward >= trigger_distance &&
           std::abs(first_inward - second_inward) <= max_parallel_delta;
  };
  SystemEdgeGesture gesture = SystemEdgeGesture::kNone;
  if (first->bottom_eligible && second->bottom_eligible &&
      matches_inward(first->start.y - first->current.y,
                     second->start.y - second->current.y)) {
    gesture = SystemEdgeGesture::kAppSwitcher;
  } else if (first->top_eligible && second->top_eligible &&
             matches_inward(first->current.y - first->start.y,
                            second->current.y - second->start.y)) {
    gesture = SystemEdgeGesture::kHome;
  }
  if (gesture == SystemEdgeGesture::kNone) {
    return gesture;
  }
  reset();
  return gesture;
}

void SystemEdgeGestureRecognizer::reset() {
  contacts_.fill(Contact{});
}

pluto_touch_ring_record make_touch_ring_record(const TouchEvent& event,
                                                 const AffineTransform& calibration,
                                                 Orientation orientation,
                                                 float panel_width,
                                                 float panel_height,
                                                 uint32_t seq) {
  const Point panel =
      calibration.apply(Point{.x = static_cast<float>(event.raw_x),
                              .y = static_cast<float>(event.raw_y)});
  const Point logical =
      panel_to_logical(panel, panel_width, panel_height, orientation);
  return pluto_touch_ring_record{
      .ts_us = static_cast<uint64_t>(event.ts_us),
      .seq = seq,
      .slot = event.slot,
      .phase = static_cast<uint8_t>(event.phase),
      .classification = static_cast<uint8_t>(event.classification),
      .touch_major = event.touch_major,
      .tracking_id = event.tracking_id < 0 ? static_cast<uint16_t>(0xffff)
                                           : static_cast<uint16_t>(event.tracking_id),
      .raw_x = event.raw_x,
      .raw_y = event.raw_y,
      .pressure = event.pressure,
      .distance = event.distance,
      .x_logical = logical.x,
      .y_logical = logical.y,
  };
}

}  // namespace pluto
