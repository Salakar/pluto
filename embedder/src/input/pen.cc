#include "input/pen.h"

#include <algorithm>
#include <cmath>

namespace pluto {
namespace {

uint16_t clamp_u16(int32_t value) {
  return static_cast<uint16_t>(std::clamp(value, 0, 0xffff));
}

int16_t clamp_i16(int32_t value) {
  return static_cast<int16_t>(std::clamp(value, static_cast<int32_t>(INT16_MIN),
                                         static_cast<int32_t>(INT16_MAX)));
}

} // namespace

PenTrackerOutput PenTracker::consume(const RawEvent &event) {
  if (event.type == kEvSyn && event.code == kSynDropped) {
    dropping_until_syn_ = true;
    dirty_ = false;
    return PenTrackerOutput{};
  }

  if (dropping_until_syn_) {
    if (event.type == kEvSyn && event.code == kSynReport) {
      dropping_until_syn_ = false;
      resync_next_sample_ = true;
    }
    return PenTrackerOutput{};
  }

  if (event.type == kEvAbs) {
    switch (event.code) {
    case kAbsX:
      raw_x_ = clamp_u16(event.value);
      dirty_ = true;
      break;
    case kAbsY:
      raw_y_ = clamp_u16(event.value);
      dirty_ = true;
      break;
    case kAbsPressure:
      raw_pressure_ = clamp_u16(event.value);
      dirty_ = true;
      break;
    case kAbsDistance:
      raw_distance_ = clamp_u16(event.value);
      dirty_ = true;
      break;
    case kAbsTiltX:
      tilt_x_cdeg_ = clamp_i16(event.value);
      dirty_ = true;
      break;
    case kAbsTiltY:
      tilt_y_cdeg_ = clamp_i16(event.value);
      dirty_ = true;
      break;
    default:
      break;
    }
    return PenTrackerOutput{};
  }

  if (event.type == kEvKey) {
    const bool pressed = event.value != 0;
    switch (event.code) {
    case kBtnToolPen:
      key_pen_ = pressed;
      dirty_ = true;
      break;
    case kBtnToolRubber:
      key_rubber_ = pressed;
      dirty_ = true;
      break;
    case kBtnTouch:
      key_touch_ = pressed;
      dirty_ = true;
      break;
    case kBtnStylus:
      key_stylus_ = pressed;
      dirty_ = true;
      break;
    case kBtnStylus2:
      key_stylus2_ = pressed;
      dirty_ = true;
      break;
    default:
      break;
    }
    return PenTrackerOutput{};
  }

  if (event.type == kEvSyn && event.code == kSynReport) {
    return report(event.ts_us);
  }

  return PenTrackerOutput{};
}

PenTrackerOutput
PenTracker::consume_batch(const std::vector<RawEvent> &events) {
  PenTrackerOutput out;
  for (const RawEvent &event : events) {
    PenTrackerOutput next = consume(event);
    if (next.has_sample || next.pointer_count > 0) {
      out = next;
    }
  }
  return out;
}

void PenTracker::mark_resynced() {
  dropping_until_syn_ = false;
  resync_next_sample_ = true;
}

PenTrackerOutput PenTracker::synthesize_device_lost(int64_t ts_us) {
  PenTrackerOutput out;
  if (contact_) {
    add_pointer(&out, PointerPhase::kCancel, tool_, ts_us);
    out.sample.transition |= kPenTransitionCanceled;
  }
  if (in_range_) {
    add_pointer(&out, PointerPhase::kRemove, tool_, ts_us);
    out.sample.transition |= kPenTransitionRemoved;
  }
  out.has_sample = true;
  out.sample.ts_us = ts_us;
  out.sample.tool = tool_;
  out.sample.in_range = false;
  out.sample.contact = false;
  out.sample.raw_x = raw_x_;
  out.sample.raw_y = raw_y_;
  out.sample.raw_pressure = raw_pressure_;
  out.sample.raw_distance = raw_distance_;
  out.sample.tilt_x_cdeg = tilt_x_cdeg_;
  out.sample.tilt_y_cdeg = tilt_y_cdeg_;
  out.sample.device_lost = true;

  tool_ = PenTool::kNone;
  in_range_ = false;
  contact_ = false;
  key_pen_ = false;
  key_rubber_ = false;
  key_touch_ = false;
  key_stylus_ = false;
  key_stylus2_ = false;
  return out;
}

PenTool PenTracker::pending_tool() const {
  if (key_rubber_) {
    return PenTool::kEraser;
  }
  if (key_pen_) {
    return PenTool::kTip;
  }
  if (key_touch_) {
    return tool_ == PenTool::kNone ? PenTool::kTip : tool_;
  }
  return PenTool::kNone;
}

void PenTracker::add_pointer(PenTrackerOutput *out, PointerPhase phase,
                             PenTool tool, int64_t ts_us) const {
  if (out->pointer_count >= out->pointer_events.size()) {
    return;
  }
  out->pointer_events[out->pointer_count++] = PenPointerEvent{
      .ts_us = ts_us,
      .phase = phase,
      .tool = tool,
      .btn_stylus = key_stylus_,
      .btn_stylus2 = key_stylus2_,
      .raw_x = raw_x_,
      .raw_y = raw_y_,
      .raw_pressure = raw_pressure_,
  };
}

PenTrackerOutput PenTracker::report(int64_t ts_us) {
  PenTrackerOutput out;
  if (!dirty_ && !resync_next_sample_) {
    return out;
  }

  const PenTool next_tool = pending_tool();
  const bool next_contact = key_touch_;
  const bool next_in_range = next_tool != PenTool::kNone || next_contact;
  const PenTool effective_next_tool =
      next_tool == PenTool::kNone && next_contact ? PenTool::kTip : next_tool;

  out.has_sample = true;
  out.sample = PenSample{
      .ts_us = ts_us,
      .tool = effective_next_tool,
      .in_range = next_in_range,
      .contact = next_contact,
      .btn_stylus = key_stylus_,
      .btn_stylus2 = key_stylus2_,
      .raw_x = raw_x_,
      .raw_y = raw_y_,
      .raw_pressure = raw_pressure_,
      .raw_distance = raw_distance_,
      .tilt_x_cdeg = tilt_x_cdeg_,
      .tilt_y_cdeg = tilt_y_cdeg_,
      .transition = 0,
      .device_lost = false,
  };

  const bool tool_changed =
      in_range_ && next_in_range && tool_ != effective_next_tool;

  if (tool_changed) {
    if (contact_) {
      add_pointer(&out, PointerPhase::kCancel, tool_, ts_us);
      out.sample.transition |= kPenTransitionCanceled;
    }
    add_pointer(&out, PointerPhase::kRemove, tool_, ts_us);
    out.sample.transition |= kPenTransitionRemoved;
    add_pointer(&out, PointerPhase::kAdd, effective_next_tool, ts_us);
    out.sample.transition |= kPenTransitionAdded;
    if (next_contact) {
      add_pointer(&out, PointerPhase::kDown, effective_next_tool, ts_us);
      out.sample.transition |= kPenTransitionDown;
    }
  } else if (!in_range_ && next_in_range) {
    add_pointer(&out, PointerPhase::kAdd, effective_next_tool, ts_us);
    out.sample.transition |= kPenTransitionAdded;
    if (next_contact) {
      add_pointer(&out, PointerPhase::kDown, effective_next_tool, ts_us);
      out.sample.transition |= kPenTransitionDown;
    }
  } else if (in_range_ && !next_in_range) {
    if (contact_) {
      add_pointer(&out, PointerPhase::kUp, tool_, ts_us);
      out.sample.transition |= kPenTransitionUp;
    }
    add_pointer(&out, PointerPhase::kRemove, tool_, ts_us);
    out.sample.transition |= kPenTransitionRemoved;
  } else if (in_range_ && next_in_range) {
    if (!contact_ && next_contact) {
      add_pointer(&out, PointerPhase::kDown, effective_next_tool, ts_us);
      out.sample.transition |= kPenTransitionDown;
    } else if (contact_ && !next_contact) {
      add_pointer(&out, PointerPhase::kUp, effective_next_tool, ts_us);
      out.sample.transition |= kPenTransitionUp;
    } else if (next_contact) {
      add_pointer(&out, PointerPhase::kMove, effective_next_tool, ts_us);
    } else {
      add_pointer(&out, PointerPhase::kHover, effective_next_tool, ts_us);
    }
  }

  if (resync_next_sample_) {
    out.sample.transition |= kPenTransitionResync;
    resync_next_sample_ = false;
  }

  tool_ = effective_next_tool;
  in_range_ = next_in_range;
  contact_ = next_contact;
  dirty_ = false;
  return out;
}

pluto_pen_ring_record make_pen_ring_record(const PenSample &sample,
                                             const AffineTransform &calibration,
                                             Orientation orientation,
                                             float panel_width,
                                             float panel_height, uint32_t seq) {
  const Point panel =
      calibration.apply(Point{.x = static_cast<float>(sample.raw_x),
                              .y = static_cast<float>(sample.raw_y)});
  const Point logical =
      panel_to_logical(panel, panel_width, panel_height, orientation);
  uint16_t flags = kPlutoPenRingFlagOrientationValid;
  if (sample.contact) {
    flags |= kPlutoPenRingFlagContact;
  }
  if (sample.in_range) {
    flags |= kPlutoPenRingFlagInRange;
  }
  if (sample.tool == PenTool::kEraser) {
    flags |= kPlutoPenRingFlagEraser;
  }
  if (sample.btn_stylus) {
    flags |= kPlutoPenRingFlagButtonStylus;
  }
  if (sample.btn_stylus2) {
    flags |= kPlutoPenRingFlagButtonStylus2;
  }
  if ((sample.transition & kPenTransitionResync) != 0) {
    flags |= kPlutoPenRingFlagResync;
  }
  if (sample.device_lost) {
    flags |= kPlutoPenRingFlagDeviceLost;
  }

  return pluto_pen_ring_record{
      .ts_us = static_cast<uint64_t>(sample.ts_us),
      .seq = seq,
      .flags = flags,
      .raw_x = sample.raw_x,
      .raw_y = sample.raw_y,
      .raw_pressure = sample.raw_pressure,
      .raw_distance = sample.raw_distance,
      .tilt_x_cdeg = sample.tilt_x_cdeg,
      .tilt_y_cdeg = sample.tilt_y_cdeg,
      .orientation_tag = orientation_degrees(orientation),
      .x_logical = logical.x,
      .y_logical = logical.y,
      .reserved = 0,
  };
}

} // namespace pluto
