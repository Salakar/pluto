#ifndef PLUTO_SRC_INPUT_EVDEV_H_
#define PLUTO_SRC_INPUT_EVDEV_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace pluto {

constexpr uint16_t kEvSyn = 0x00;
constexpr uint16_t kEvKey = 0x01;
constexpr uint16_t kEvAbs = 0x03;
constexpr uint16_t kEvMsc = 0x04;

constexpr uint16_t kSynReport = 0x00;
constexpr uint16_t kSynDropped = 0x03;

constexpr uint16_t kAbsX = 0x00;
constexpr uint16_t kAbsY = 0x01;
constexpr uint16_t kAbsPressure = 0x18;
constexpr uint16_t kAbsDistance = 0x19;
constexpr uint16_t kAbsTiltX = 0x1a;
constexpr uint16_t kAbsTiltY = 0x1b;
constexpr uint16_t kAbsMtSlot = 0x2f;
constexpr uint16_t kAbsMtTouchMajor = 0x30;
constexpr uint16_t kAbsMtPositionX = 0x35;
constexpr uint16_t kAbsMtPositionY = 0x36;
constexpr uint16_t kAbsMtToolType = 0x37;
constexpr uint16_t kAbsMtTrackingId = 0x39;
constexpr uint16_t kAbsMtPressure = 0x3a;
constexpr uint16_t kAbsMtDistance = 0x3b;

constexpr uint16_t kBtnToolPen = 0x140;
constexpr uint16_t kBtnToolRubber = 0x141;
constexpr uint16_t kBtnTouch = 0x14a;
constexpr uint16_t kBtnStylus = 0x14b;
constexpr uint16_t kBtnStylus2 = 0x14c;

constexpr const char *kDefaultPenByPath =
    "/dev/input/by-path/platform-44360000.spi-cs-0-event-mouse";
constexpr const char *kDefaultTouchByPath =
    "/dev/input/by-path/platform-44360000.spi-cs-0-event";

struct RawEvent {
  int64_t ts_us = 0;
  uint16_t type = 0;
  uint16_t code = 0;
  int32_t value = 0;
};

struct AxisInfo {
  int32_t minimum = 0;
  int32_t maximum = 0;
  int32_t value = 0;
};

struct DeviceIdentity {
  std::string path;
  std::string name;
  uint16_t bustype = 0;
  uint16_t vendor = 0;
  uint16_t product = 0;
  std::vector<std::pair<uint16_t, AxisInfo>> axes;
};

enum class EvdevStatus {
  kOk,
  kAgain,
  kDeviceLost,
  kResynced,
  kUnsupported,
  kInvalidData,
};

struct SourceResult {
  EvdevStatus status = EvdevStatus::kAgain;
  std::vector<RawEvent> events;
};

class SampleSource {
public:
  virtual ~SampleSource() = default;
  virtual SourceResult next_batch() = 0;
};

// Splits raw evdev reads into SYN_REPORT-delimited frames. One read(2) can
// carry several frames; events past the first frame boundary are retained
// and served by later take_frame() calls instead of being discarded.
// SYN_DROPPED opens a kernel-resync window: the partial frame is discarded,
// events are skipped until the closing SYN_REPORT, which is surfaced as a
// kResync frame so the caller can snapshot device state.
class SynFrameBuffer {
public:
  enum class FrameKind { kNone, kEvents, kResync };

  struct Frame {
    FrameKind kind = FrameKind::kNone;
    int64_t resync_ts_us = 0;
    std::vector<RawEvent> events;
  };

  SynFrameBuffer();

  void push_event(const RawEvent &event);
  // Returns at most one complete frame per call; kNone when every buffered
  // event has been consumed and the next frame is still partial.
  Frame take_frame();
  // Allocation-free production seam: copies the next coherent frame into a
  // caller-owned vector whose capacity is retained across SYN frames.
  FrameKind take_frame_into(std::vector<RawEvent> *events,
                            int64_t *resync_ts_us);
  void clear();
  // Number of completed SYN_DROPPED recovery boundaries observed during this
  // buffer's lifetime. clear() discards queued data but intentionally retains
  // this diagnostic counter so device-close cleanup cannot erase evidence.
  uint64_t resync_count() const { return resync_count_; }

private:
  std::vector<RawEvent> buffered_;
  size_t cursor_ = 0;
  std::vector<RawEvent> pending_;
  bool dropping_until_syn_ = false;
  uint64_t resync_count_ = 0;
};

class ReplaySource final : public SampleSource {
public:
  explicit ReplaySource(std::vector<RawEvent> events);
  static ReplaySource from_jsonl_file(const std::string &path);

  SourceResult next_batch() override;
  void reset();

private:
  std::vector<RawEvent> events_;
  size_t cursor_ = 0;
};

// Narrow control-operation seam used by deterministic host tests. Production
// leaves this null and uses open(2), EVIOCSCLOCKID, EVIOCGRAB, and close(2)
// directly. Keeping the seam to open/control/close lets a test reach the
// exclusive-grab failure boundary without pretending a regular file is an
// evdev device (a regular file actually fails earlier at EVIOCSCLOCKID).
enum class EvdevControlRequest {
  kSetMonotonicClock,
  kGrab,
};

struct EvdevSourceOpsForTesting {
  void *user_data = nullptr;
  int (*open)(void *user_data, const char *path) = nullptr;
  int (*control_ioctl)(void *user_data, int fd,
                       EvdevControlRequest request, bool enabled) = nullptr;
  void (*close)(void *user_data, int fd) = nullptr;
};

class EvdevSource final : public SampleSource {
public:
  explicit EvdevSource(const EvdevSourceOpsForTesting *test_ops = nullptr)
      : test_ops_(test_ops) {}
  ~EvdevSource();

  EvdevSource(const EvdevSource &) = delete;
  EvdevSource &operator=(const EvdevSource &) = delete;

  EvdevStatus open_by_path(const std::string &path);
  SourceResult next_batch() override;
  // Pen-thread hot path. Unlike the ownership-returning SampleSource API, this
  // reuses caller storage and allocates nothing for normal <=64-event frames.
  EvdevStatus next_batch_into(std::vector<RawEvent> *events);
  EvdevStatus grab(bool enabled);
  // Open-session handoff: discard events queued between open and exclusive
  // grab, then take one coherent ioctl snapshot so a pen already hovering or
  // touching is visible without waiting for Linux to repeat a key edge.
  EvdevStatus discard_pending_events();
  EvdevStatus snapshot_current_state(int64_t ts_us,
                                     std::vector<RawEvent> *events);
  void close();

  const DeviceIdentity &identity() const { return identity_; }
  uint64_t resync_count() const { return frames_.resync_count(); }
  // The O_NONBLOCK device fd for poll(2)-driven waits (-1 when closed).
  int fd() const { return fd_; }

private:
  int fd_ = -1;
  SynFrameBuffer frames_;
  DeviceIdentity identity_;
  const EvdevSourceOpsForTesting *test_ops_ = nullptr;

  EvdevStatus synthesize_resync_snapshot(int64_t ts_us,
                                         std::vector<RawEvent> *events,
                                         bool require_key_state = false);
  int control_ioctl(EvdevControlRequest request, bool enabled);
};

} // namespace pluto

#endif // PLUTO_SRC_INPUT_EVDEV_H_
