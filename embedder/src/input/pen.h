#ifndef PLUTO_SRC_INPUT_PEN_H_
#define PLUTO_SRC_INPUT_PEN_H_

#include <array>
#include <cstdint>
#include <optional>

#include "input/evdev.h"
#include "input/transform.h"
#include "pluto/pen_ring.h"

namespace pluto {

enum class PenTool : uint8_t {
  kNone = 0,
  kTip = 1,
  kEraser = 2,
};

enum PenTransition : uint8_t {
  kPenTransitionAdded = 1u << 0,
  kPenTransitionRemoved = 1u << 1,
  kPenTransitionDown = 1u << 2,
  kPenTransitionUp = 1u << 3,
  kPenTransitionCanceled = 1u << 4,
  kPenTransitionResync = 1u << 5,
};

enum class PointerPhase : uint8_t {
  kAdd,
  kRemove,
  kHover,
  kDown,
  kMove,
  kUp,
  kCancel,
};

struct PenSample {
  int64_t ts_us = 0;
  PenTool tool = PenTool::kNone;
  bool in_range = false;
  bool contact = false;
  bool btn_stylus = false;
  bool btn_stylus2 = false;
  uint16_t raw_x = 0;
  uint16_t raw_y = 0;
  uint16_t raw_pressure = 0;
  uint16_t raw_distance = 0;
  int16_t tilt_x_cdeg = 0;
  int16_t tilt_y_cdeg = 0;
  uint8_t transition = 0;
  bool device_lost = false;
};

struct PenPointerEvent {
  int64_t ts_us = 0;
  PointerPhase phase = PointerPhase::kHover;
  PenTool tool = PenTool::kNone;
  bool btn_stylus = false;
  bool btn_stylus2 = false;
  uint16_t raw_x = 0;
  uint16_t raw_y = 0;
  uint16_t raw_pressure = 0;
};

struct PenTrackerOutput {
  bool has_sample = false;
  PenSample sample;
  std::array<PenPointerEvent, 6> pointer_events{};
  size_t pointer_count = 0;
};

class PenTracker {
public:
  PenTracker() = default;

  PenTrackerOutput consume(const RawEvent &event);
  PenTrackerOutput consume_batch(const std::vector<RawEvent> &events);
  // Marks a kernel-synthesized state snapshot after SYN_DROPPED. EvdevSource
  // has already discarded the corrupt interval, so the snapshot values must
  // be consumed normally while its coherent report carries the resync edge.
  void mark_resynced();
  PenTrackerOutput synthesize_device_lost(int64_t ts_us);

  bool in_range() const { return in_range_; }
  bool contact() const { return contact_; }
  PenTool tool() const { return tool_; }

private:
  PenTrackerOutput report(int64_t ts_us);
  void add_pointer(PenTrackerOutput *out, PointerPhase phase, PenTool tool,
                   int64_t ts_us) const;

  PenTool pending_tool() const;

  bool key_pen_ = false;
  bool key_rubber_ = false;
  bool key_touch_ = false;
  bool key_stylus_ = false;
  bool key_stylus2_ = false;
  uint16_t raw_x_ = 0;
  uint16_t raw_y_ = 0;
  uint16_t raw_pressure_ = 0;
  uint16_t raw_distance_ = 0;
  int16_t tilt_x_cdeg_ = 0;
  int16_t tilt_y_cdeg_ = 0;

  PenTool tool_ = PenTool::kNone;
  bool in_range_ = false;
  bool contact_ = false;
  bool dirty_ = false;
  bool dropping_until_syn_ = false;
  bool resync_next_sample_ = false;
};

pluto_pen_ring_record make_pen_ring_record(const PenSample &sample,
                                             const AffineTransform &calibration,
                                             Orientation orientation,
                                             float panel_width,
                                             float panel_height, uint32_t seq);

} // namespace pluto

#endif // PLUTO_SRC_INPUT_PEN_H_
