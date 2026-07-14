#include "input/evdev.h"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <stdexcept>
#include <utility>

#include "input/record.h"

#if defined(__linux__)
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#endif

namespace pluto {
namespace {

#if defined(__linux__)
RawEvent raw_syn_report(int64_t ts_us) {
  return RawEvent{
      .ts_us = ts_us, .type = kEvSyn, .code = kSynReport, .value = 0};
}

int64_t event_ts_us(const input_event &event) {
  return static_cast<int64_t>(event.time.tv_sec) * 1000000ll +
         static_cast<int64_t>(event.time.tv_usec);
}

bool test_bit(const unsigned long *bits, int bit) {
  constexpr int kWordBits = static_cast<int>(sizeof(unsigned long) * 8);
  return (bits[bit / kWordBits] & (1ul << (bit % kWordBits))) != 0;
}
#endif

} // namespace

ReplaySource::ReplaySource(std::vector<RawEvent> events)
    : events_(std::move(events)) {}

ReplaySource ReplaySource::from_jsonl_file(const std::string &path) {
  return ReplaySource(read_jsonl_events_file(path));
}

SourceResult ReplaySource::next_batch() {
  if (cursor_ >= events_.size()) {
    return SourceResult{.status = EvdevStatus::kAgain, .events = {}};
  }
  SourceResult result;
  result.status = EvdevStatus::kOk;
  while (cursor_ < events_.size()) {
    const RawEvent event = events_[cursor_++];
    result.events.push_back(event);
    if (event.type == kEvSyn && event.code == kSynDropped) {
      result.status = EvdevStatus::kResynced;
    }
    if (event.type == kEvSyn && event.code == kSynReport) {
      break;
    }
  }
  return result;
}

void ReplaySource::reset() { cursor_ = 0; }

SynFrameBuffer::SynFrameBuffer() {
  buffered_.reserve(64);
  pending_.reserve(64);
}

void SynFrameBuffer::push_event(const RawEvent &event) {
  if (cursor_ > 0) {
    buffered_.erase(buffered_.begin(),
                    buffered_.begin() + static_cast<ptrdiff_t>(cursor_));
    cursor_ = 0;
  }
  buffered_.push_back(event);
}

SynFrameBuffer::Frame SynFrameBuffer::take_frame() {
  Frame frame;
  frame.kind = take_frame_into(&frame.events, &frame.resync_ts_us);
  return frame;
}

SynFrameBuffer::FrameKind
SynFrameBuffer::take_frame_into(std::vector<RawEvent> *events,
                                int64_t *resync_ts_us) {
  if (events == nullptr) {
    return FrameKind::kNone;
  }
  events->clear();
  if (resync_ts_us != nullptr) {
    *resync_ts_us = 0;
  }
  while (cursor_ < buffered_.size()) {
    const RawEvent raw = buffered_[cursor_++];
    if (raw.type == kEvSyn && raw.code == kSynDropped) {
      pending_.clear();
      dropping_until_syn_ = true;
      continue;
    }
    if (dropping_until_syn_) {
      if (raw.type == kEvSyn && raw.code == kSynReport) {
        dropping_until_syn_ = false;
        ++resync_count_;
        if (resync_ts_us != nullptr) {
          *resync_ts_us = raw.ts_us;
        }
        return FrameKind::kResync;
      }
      continue;
    }
    pending_.push_back(raw);
    if (raw.type == kEvSyn && raw.code == kSynReport) {
      events->assign(pending_.begin(), pending_.end());
      pending_.clear();
      return FrameKind::kEvents;
    }
  }
  buffered_.clear();
  cursor_ = 0;
  return FrameKind::kNone;
}

void SynFrameBuffer::clear() {
  buffered_.clear();
  cursor_ = 0;
  pending_.clear();
  dropping_until_syn_ = false;
}

EvdevSource::~EvdevSource() { close(); }

EvdevStatus EvdevSource::open_by_path(const std::string &path) {
  close();
  if (test_ops_ != nullptr) {
    if (test_ops_->open == nullptr || test_ops_->control_ioctl == nullptr ||
        test_ops_->close == nullptr) {
      return EvdevStatus::kUnsupported;
    }
    fd_ = test_ops_->open(test_ops_->user_data, path.c_str());
  } else {
#if defined(__linux__)
    fd_ = ::open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
#else
    (void)path;
    return EvdevStatus::kUnsupported;
#endif
  }
  if (fd_ < 0) {
    return errno == ENODEV ? EvdevStatus::kDeviceLost : EvdevStatus::kAgain;
  }

  // Renderer terminal-ROI expiry and prediction compare event timestamps with
  // CLOCK_MONOTONIC. Continuing after a rejected clock request would mix
  // realtime evdev stamps with that domain and could retain a hover ROI
  // indefinitely after range exit. Fail closed instead of guessing.
  if (control_ioctl(EvdevControlRequest::kSetMonotonicClock,
                    /*enabled=*/true) != 0) {
    close();
    return EvdevStatus::kUnsupported;
  }

  identity_ = DeviceIdentity{};
  identity_.path = path;

  // A fake control device is sufficient for ownership-boundary tests. Real
  // identity ioctls remain on the unchanged production path below.
  if (test_ops_ != nullptr) {
    return EvdevStatus::kOk;
  }

#if defined(__linux__)
  char name[256] = {};
  if (::ioctl(fd_, EVIOCGNAME(sizeof(name)), name) >= 0) {
    identity_.name = name;
  }

  input_id id = {};
  if (::ioctl(fd_, EVIOCGID, &id) >= 0) {
    identity_.bustype = id.bustype;
    identity_.vendor = id.vendor;
    identity_.product = id.product;
  }

  constexpr uint16_t kAxes[] = {
      kAbsX,           kAbsY,           kAbsPressure,   kAbsDistance,
      kAbsTiltX,       kAbsTiltY,       kAbsMtSlot,     kAbsMtTouchMajor,
      kAbsMtPositionX, kAbsMtPositionY, kAbsMtToolType, kAbsMtTrackingId,
      kAbsMtPressure,  kAbsMtDistance,
  };
  for (const uint16_t axis : kAxes) {
    input_absinfo info = {};
    if (::ioctl(fd_, EVIOCGABS(axis), &info) >= 0) {
      identity_.axes.push_back(
          std::make_pair(axis, AxisInfo{.minimum = info.minimum,
                                        .maximum = info.maximum,
                                        .value = info.value}));
    }
  }
  return EvdevStatus::kOk;
#else
  return EvdevStatus::kUnsupported;
#endif
}

SourceResult EvdevSource::next_batch() {
  SourceResult result;
  result.status = next_batch_into(&result.events);
  return result;
}

EvdevStatus EvdevSource::next_batch_into(std::vector<RawEvent> *out_events) {
#if defined(__linux__)
  if (out_events == nullptr) {
    return EvdevStatus::kInvalidData;
  }
  out_events->clear();
  if (fd_ < 0) {
    return EvdevStatus::kDeviceLost;
  }

  input_event events[64];
  while (true) {
    // Serve frames retained from a previous read() before touching the fd:
    // one read can carry several SYN frames and next_batch returns exactly
    // one frame per call.
    int64_t resync_ts_us = 0;
    const SynFrameBuffer::FrameKind frame_kind =
        frames_.take_frame_into(out_events, &resync_ts_us);
    if (frame_kind == SynFrameBuffer::FrameKind::kEvents) {
      return EvdevStatus::kOk;
    }
    if (frame_kind == SynFrameBuffer::FrameKind::kResync) {
      return synthesize_resync_snapshot(resync_ts_us, out_events);
    }

    const ssize_t bytes = ::read(fd_, events, sizeof(events));
    if (bytes < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        return EvdevStatus::kAgain;
      }
      if (errno == ENODEV || errno == EBADF) {
        close();
        return EvdevStatus::kDeviceLost;
      }
      return EvdevStatus::kInvalidData;
    }
    if (bytes == 0) {
      close();
      return EvdevStatus::kDeviceLost;
    }
    if (bytes % static_cast<ssize_t>(sizeof(input_event)) != 0) {
      return EvdevStatus::kInvalidData;
    }

    const size_t count = static_cast<size_t>(bytes) / sizeof(input_event);
    for (size_t i = 0; i < count; ++i) {
      frames_.push_event(RawEvent{
          .ts_us = event_ts_us(events[i]),
          .type = events[i].type,
          .code = events[i].code,
          .value = events[i].value,
      });
    }
  }
#else
  (void)out_events;
  return EvdevStatus::kUnsupported;
#endif
}

EvdevStatus EvdevSource::grab(bool enabled) {
  if (fd_ < 0) {
    return EvdevStatus::kDeviceLost;
  }
  return control_ioctl(EvdevControlRequest::kGrab, enabled) == 0
             ? EvdevStatus::kOk
             : EvdevStatus::kDeviceLost;
}

EvdevStatus EvdevSource::discard_pending_events() {
#if defined(__linux__)
  if (fd_ < 0) {
    return EvdevStatus::kDeviceLost;
  }
  input_event events[64];
  for (;;) {
    const ssize_t bytes = ::read(fd_, events, sizeof(events));
    if (bytes < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        frames_.clear();
        return EvdevStatus::kOk;
      }
      if (errno == ENODEV || errno == EBADF) {
        close();
        return EvdevStatus::kDeviceLost;
      }
      return EvdevStatus::kInvalidData;
    }
    if (bytes == 0) {
      close();
      return EvdevStatus::kDeviceLost;
    }
    if (bytes % static_cast<ssize_t>(sizeof(input_event)) != 0) {
      return EvdevStatus::kInvalidData;
    }
  }
#else
  return EvdevStatus::kUnsupported;
#endif
}

EvdevStatus
EvdevSource::snapshot_current_state(int64_t ts_us,
                                    std::vector<RawEvent> *events) {
  return synthesize_resync_snapshot(ts_us, events,
                                    /*require_key_state=*/true);
}

void EvdevSource::close() {
  if (fd_ >= 0) {
    if (test_ops_ != nullptr) {
      test_ops_->close(test_ops_->user_data, fd_);
    } else {
#if defined(__linux__)
      ::close(fd_);
#endif
    }
    fd_ = -1;
  }
  frames_.clear();
}

int EvdevSource::control_ioctl(EvdevControlRequest request, bool enabled) {
  if (test_ops_ != nullptr) {
    return test_ops_->control_ioctl(test_ops_->user_data, fd_, request,
                                    enabled);
  }
#if defined(__linux__)
  switch (request) {
  case EvdevControlRequest::kSetMonotonicClock: {
    int clock_id = CLOCK_MONOTONIC;
    return ::ioctl(fd_, EVIOCSCLOCKID, &clock_id);
  }
  case EvdevControlRequest::kGrab: {
    const int flag = enabled ? 1 : 0;
    return ::ioctl(fd_, EVIOCGRAB, flag);
  }
  }
#else
  (void)request;
  (void)enabled;
#endif
  return -1;
}

EvdevStatus
EvdevSource::synthesize_resync_snapshot(int64_t ts_us,
                                        std::vector<RawEvent> *events,
                                        bool require_key_state) {
#if defined(__linux__)
  if (events == nullptr) {
    return EvdevStatus::kInvalidData;
  }
  events->clear();

  bool has_mt_slots = false;
  int mt_slot_count = 10;
  for (const auto &axis : identity_.axes) {
    if (axis.first == kAbsMtSlot) {
      has_mt_slots = true;
      mt_slot_count = std::clamp(axis.second.maximum + 1, 1, 64);
      break;
    }
  }

  if (has_mt_slots && !require_key_state) {
    constexpr uint16_t kMtCodes[] = {
        kAbsMtTrackingId, kAbsMtPositionX, kAbsMtPositionY, kAbsMtTouchMajor,
        kAbsMtPressure,   kAbsMtDistance,  kAbsMtToolType,
    };
    int values[65] = {};
    for (int slot = 0; slot < mt_slot_count; ++slot) {
      events->push_back(RawEvent{
          .ts_us = ts_us,
          .type = kEvAbs,
          .code = kAbsMtSlot,
          .value = slot,
      });
      for (const uint16_t code : kMtCodes) {
        std::memset(values, 0, sizeof(values));
        values[0] = code;
        if (::ioctl(fd_, EVIOCGMTSLOTS(sizeof(values)), values) >= 0) {
          events->push_back(RawEvent{
              .ts_us = ts_us,
              .type = kEvAbs,
              .code = code,
              .value = values[slot + 1],
          });
        }
      }
    }
    events->push_back(raw_syn_report(ts_us));
    return EvdevStatus::kResynced;
  }

  unsigned long key_bits[(KEY_MAX + sizeof(unsigned long) * 8) /
                         (sizeof(unsigned long) * 8)] = {};
  const int key_status = ::ioctl(fd_, EVIOCGKEY(sizeof(key_bits)), key_bits);
  if (key_status < 0 && require_key_state) {
    return EvdevStatus::kUnsupported;
  }
  if (key_status >= 0) {
    constexpr uint16_t kKeys[] = {
        kBtnToolPen, kBtnToolRubber, kBtnTouch, kBtnStylus, kBtnStylus2,
    };
    for (const uint16_t key : kKeys) {
      events->push_back(RawEvent{
          .ts_us = ts_us,
          .type = kEvKey,
          .code = key,
          .value = test_bit(key_bits, key) ? 1 : 0,
      });
    }
  }

  constexpr uint16_t kAxes[] = {
      kAbsX,           kAbsY,           kAbsPressure,   kAbsDistance,
      kAbsTiltX,       kAbsTiltY,       kAbsMtSlot,     kAbsMtTouchMajor,
      kAbsMtPositionX, kAbsMtPositionY, kAbsMtToolType, kAbsMtTrackingId,
      kAbsMtPressure,  kAbsMtDistance,
  };
  bool captured_x = false;
  bool captured_y = false;
  for (const uint16_t axis : kAxes) {
    input_absinfo info = {};
    if (::ioctl(fd_, EVIOCGABS(axis), &info) >= 0) {
      captured_x = captured_x || axis == kAbsX;
      captured_y = captured_y || axis == kAbsY;
      events->push_back(RawEvent{
          .ts_us = ts_us,
          .type = kEvAbs,
          .code = axis,
          .value = info.value,
      });
    }
  }
  if (require_key_state && (!captured_x || !captured_y)) {
    events->clear();
    return EvdevStatus::kUnsupported;
  }
  events->push_back(raw_syn_report(ts_us));
  return EvdevStatus::kResynced;
#else
  (void)ts_us;
  (void)events;
  (void)require_key_state;
  return EvdevStatus::kUnsupported;
#endif
}

} // namespace pluto
