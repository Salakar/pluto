#ifndef PLUTO_PRESENTER_SWTCON_SCAN_LOOP_H_
#define PLUTO_PRESENTER_SWTCON_SCAN_LOOP_H_

#include "pluto/presenter.h"
#include "presenter/swtcon/drm_swtcon_device.h"
#include "presenter/swtcon/swtcon_constants.h"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <thread>
#include <vector>

namespace pluto::swtcon {

// Injectable monotonic clock (virtual clock, deterministic host tests).
// The production clock is SteadyScanClock; tests script both now_ns() and
// sleep_until_ns().
class ScanClock {
 public:
  virtual ~ScanClock() = default;
  virtual std::uint64_t now_ns() = 0;
  virtual void sleep_until_ns(std::uint64_t deadline_ns) = 0;
};

class SteadyScanClock final : public ScanClock {
 public:
  std::uint64_t now_ns() override;
  void sleep_until_ns(std::uint64_t deadline_ns) override;
};

// Scan-ready slot: seq-stamped single slot, engine producer -> scan
// consumer (SPSC), the 1-deep pipeline handshake. The engine publishes the
// built buffer for scan seq n; the scan takes each published seq at most
// once and falls back to HOLD when nothing newer is there. Seqs start at 1
// and only grow.
//
// pending() is the producer-side half of the 1-deep contract: while the
// latest publish has not been taken, the engine must NOT build again —
// overwriting an unscanned plane would advance fnum for phases the panel
// never saw (the tick that passed without a take was a pause).
// unacknowledged() is the completion-side half: it remains true after take()
// until the matching page-flip event proves that the plane reached the scan
// latch. Presenter wait_idle/rotation must fence this stronger state.
class ScanReadySlot final {
 public:
  // Engine thread. `buffer_index` must fit kDrmBufferCount (< 256).
  void publish(std::uint32_t buffer_index, std::uint64_t seq) {
    word_.store((seq << 8) | (buffer_index & 0xffu),
                std::memory_order_release);
  }

  // Engine thread: true while a published plane awaits its scan.
  bool pending() const {
    const std::uint64_t published = word_.load(std::memory_order_acquire) >> 8;
    return published != 0 &&
           published > last_taken_.load(std::memory_order_acquire);
  }

  // Presenter/producer threads: true while the newest published plane has
  // not received scan-latch acknowledgement. This deliberately remains true
  // after take(): taking frees the build slot, but is not optical completion.
  bool unacknowledged() const {
    const std::uint64_t published = word_.load(std::memory_order_acquire) >> 8;
    return published != 0 &&
           published > last_acknowledged_.load(std::memory_order_acquire);
  }

  // Scan thread: takes the published slot if its seq is newer than the
  // last take. Returns false (leave *out untouched) when parked/idle.
  bool take(std::uint32_t* buffer_index, std::uint64_t* seq) {
    const std::uint64_t word = word_.load(std::memory_order_acquire);
    const std::uint64_t published = word >> 8;
    if (published == 0 ||
        published <= last_taken_.load(std::memory_order_relaxed)) {
      return false;
    }
    last_taken_.store(published, std::memory_order_release);
    *buffer_index = static_cast<std::uint32_t>(word & 0xffu);
    *seq = published;
    return true;
  }

  // Scan thread: record the page-flip completion for an engine plane. Events
  // are consumed in submission order; tolerate a newer acknowledgement so a
  // mock or driver that coalesces older events cannot move the fence backward.
  void acknowledge(std::uint64_t seq) {
    if (seq > last_acknowledged_.load(std::memory_order_relaxed)) {
      last_acknowledged_.store(seq, std::memory_order_release);
    }
  }

  // Configure-time only, before producer/consumer threads start.
  void reset() {
    word_.store(0, std::memory_order_relaxed);
    last_taken_.store(0, std::memory_order_relaxed);
    last_acknowledged_.store(0, std::memory_order_relaxed);
  }

 private:
  std::atomic<std::uint64_t> word_{0};  // seq << 8 | slot; 0 = never built
  // Written by the scan thread only; read by the engine's pending() gate.
  std::atomic<std::uint64_t> last_taken_{0};
  // Written by the scan thread only; read by presenter completion fences.
  std::atomic<std::uint64_t> last_acknowledged_{0};
};

struct ScanLoopConfig {
  // `scan_period_ns`: 0 = derive from the ENUMERATED DRM mode
  // (htotal * vtotal / clock, ~85.01 Hz); fallback round(1e9/85) when the
  // mode carries no timings. Stage-3 device timing check calibrates.
  std::uint64_t scan_period_ns = 0;
  // The permanent always-blank HOLD slot (buffer 15). The scan parks here
  // between updates and on missed deadlines; it is impulse-free by
  // construction and the only legal rails-down target. configure() primes it
  // with the blank scaffold.
  std::size_t hold_slot = kDrmBufferCount - 1;
  // Page-flip completion consumption + double-scan detection. Off only for
  // dry-run shells; flips then go without an event request.
  bool consume_flip_events = true;
  // Thread plan: the scan thread runs SCHED_FIFO 80 on the device. < 0 = no
  // elevation (host tests / plain threads). Applied best-effort in run();
  // failures are silent (unprivileged hosts).
  int sched_fifo_priority = -1;
  // Affinity plan: scan + engine (FIFO) pinned to core 1; Flutter raster/UI
  // stay SCHED_OTHER on core 0. < 0 = no pinning. Best-effort (Linux
  // sched_setaffinity; silent on EPERM / non-Linux hosts).
  int cpu_affinity = -1;
};

struct ScanLoopStats {
  std::uint64_t ticks = 0;
  std::uint64_t flips = 0;       // engine-built planes scanned
  std::uint64_t hold_flips = 0;  // parked/neutral frames
  std::uint64_t pauses = 0;      // HOLD while the engine was active
  std::uint64_t double_scans = 0;  // CONTENT planes latched for extra scans
  // Extra scans of the HOLD scaffold: impulse-free by construction (pinned
  // by the L0 goldens) — counted here, but NEVER reported through
  // on_double_scan and never recharged. Scheduling jitter alone produces
  // vblank-sequence gaps at scan rate; recharging blank rescans starved
  // the engine into a livelock on device.
  std::uint64_t hold_rescans = 0;
  std::uint64_t deadline_overruns = 0;  // thread overslept a full period
  std::uint64_t flip_failures = 0;
};

// Ordered completion feedback, emitted once for every completed or
// fail-closed/coalesced flip identity after event-gap / double-scan
// classification. `latched_engine_seq == 0` denotes the HOLD scaffold.
// `latched_scan_known` distinguishes a confirmed event/blocking latch from an
// identity that is ordered only because a cookie was skipped or unknown. A
// content plane's extra-scan count cannot be known at its own latch: the
// following flip event supplies the sequence gap.
// `previous_flip_valid` exposes the prior flip unconditionally. When
// `previous_scan_count_known` is true, `previous_extra_scans` is its final
// classified count (including zero). `previous_content_resolved` additionally
// says that known prior was content rather than HOLD. A non-monotonic event
// therefore still names the affected prior content, but leaves both known /
// resolved flags false so consumers can invalidate it instead of hanging.
struct ScanFeedback {
  std::uint32_t latched_buffer_index = 0;
  std::uint64_t latched_engine_seq = 0;
  bool latched_scan_known = false;

  bool previous_flip_valid = false;
  bool previous_scan_count_known = false;
  bool previous_content_resolved = false;
  std::uint32_t previous_buffer_index = 0;
  std::uint64_t previous_engine_seq = 0;
  std::uint32_t previous_extra_scans = 0;
};

// ScanLoop: the scan thread. Absolute-deadline loop at the enumerated-mode
// period; FB_ID-only atomic flips via the DrmSwtconDevice/DrmInterface seam;
// page-flip completion consumption; HOLD-slot parking; double-scan
// detection; scan-tick publication; missed-deadline (engine did not publish)
// => HOLD flip + pause notification, fnum never advances on a pause (the
// engine never built).
//
// Threading: production runs tick() on a dedicated thread (start()/stop();
// SCHED_FIFO elevation is presenter wiring). Tests drive tick() single-step
// with the DrmInterface mock + an injected clock — the loop body itself
// takes no locks. Callbacks fire on the scan thread. ScanReadySlot::publish
// is the only cross-thread entry point.
class ScanLoop final {
 public:
  using TickFn = std::function<void(std::uint64_t scan_seq)>;
  using PauseFn = std::function<void()>;
  // Rescanned plane: buffer index + the engine seq it carried (0 = HOLD) +
  // how many extra scans were detected. The engine re-charges the exact
  // impulse of that plane into the DC ledger (HOLD is impulse-free).
  using DoubleScanFn = std::function<void(
      std::uint32_t buffer_index, std::uint64_t engine_seq,
      std::uint32_t extra_scans)>;
  using LatchFn = std::function<void(std::uint64_t engine_seq)>;
  using FeedbackFn = std::function<void(const ScanFeedback& feedback)>;
  using EngineActiveFn = std::function<bool()>;

  ScanLoop() = default;
  ~ScanLoop();
  ScanLoop(const ScanLoop&) = delete;
  ScanLoop& operator=(const ScanLoop&) = delete;

  // `device` must be open (mode enumerated, buffers mapped) and `clock`
  // non-null; both are borrowed and must outlive the loop. Derives the
  // scan period and primes the HOLD slot with the blank scaffold.
  bool configure(DrmSwtconDevice* device, ScanClock* clock,
                 const ScanLoopConfig& config);
  bool configured() const { return configured_; }
  std::uint64_t period_ns() const { return period_ns_; }

  ScanReadySlot& ready_slot() { return ready_slot_; }

  // Scan-tick publication: wakes the engine to build frame n+1.
  void set_on_tick(TickFn fn) { on_tick_ = std::move(fn); }
  // Missed deadline: the engine charges k_pause stress; fnum does NOT
  // advance (PixelEngine::pause()).
  void set_on_pause(PauseFn fn) { on_pause_ = std::move(fn); }
  void set_on_double_scan(DoubleScanFn fn) {
    on_double_scan_ = std::move(fn);
  }
  // Content plane reached the DRM scan latch. Used to wake presenter
  // completion fences; HOLD latches do not fire it.
  void set_on_latched(LatchFn fn) { on_latched_ = std::move(fn); }
  // Every completed content/HOLD flip, plus every pending identity invalidated
  // by a skipped/unknown cookie, after the existing latch callback and any
  // double-scan callback. Unlike on_latched(), HOLD and fail-closed identities
  // fire this hook; inspect latched_scan_known before treating one as latched.
  void set_on_feedback(FeedbackFn fn) { on_feedback_ = std::move(fn); }
  // Whether the engine has in-flight work: gates pause accounting when the
  // scan parks on HOLD. Unset = treat as idle (parking is free).
  void set_engine_active(EngineActiveFn fn) {
    engine_active_ = std::move(fn);
  }

  // One scan frame, single-step (tests) or from the thread loop: take the
  // ready slot else HOLD; blocking atomic flip; drain completion events;
  // detect double scans; publish the tick. Returns false on flip failure
  // (device lost).
  bool tick();

  // Production thread at absolute deadlines (zero drift): tick();
  // sleep_until(deadline); deadline += period.
  bool start();
  void stop();
  bool running() const { return running_.load(std::memory_order_acquire); }

  std::uint64_t scan_seq() const {
    return scan_seq_.load(std::memory_order_relaxed);
  }
  ScanLoopStats stats() const;

 private:
  struct PendingFlip {
    std::uint64_t user_data = 0;    // flip cookie (monotonic)
    std::uint32_t buffer_index = 0;
    std::uint64_t engine_seq = 0;   // 0 = HOLD/neutral frame
    bool valid = false;
  };

  enum class CompletionEvidence : std::uint8_t {
    kEvent,
    kBlocking,
    kCoalesced,
  };

  void run();
  void drain_events();
  void complete_flip(const PendingFlip& completed,
                     CompletionEvidence evidence,
                     std::uint32_t event_sequence);

  bool configured_ = false;
  ScanLoopConfig config_{};
  DrmSwtconDevice* device_ = nullptr;  // borrowed
  ScanClock* clock_ = nullptr;         // borrowed
  std::uint64_t period_ns_ = 0;

  ScanReadySlot ready_slot_;
  TickFn on_tick_;
  PauseFn on_pause_;
  DoubleScanFn on_double_scan_;
  LatchFn on_latched_;
  FeedbackFn on_feedback_;
  EngineActiveFn engine_active_;

  // Scan-thread state (single-threaded by ownership).
  std::uint64_t next_flip_cookie_ = 0;
  std::vector<PendingFlip> pending_flips_;  // in submission order
  PendingFlip last_completed_{};
  std::uint32_t last_event_sequence_ = 0;
  bool have_event_sequence_ = false;
  // False when a newer DRM event coalesced this completion's own event. The
  // flip identity remains ordered, but no later gap can be attributed to it.
  bool last_completed_event_anchored_ = false;
  // Steady latch-to-latch cadence, learned as the minimum observed gap
  // (0 = not yet observed). Hardware may step the sequence by >1 per scan
  // period by construction; only gaps ABOVE this baseline are rescans.
  std::uint32_t min_latch_gap_ = 0;
  std::vector<DrmFlipEvent> event_scratch_;

  std::atomic<std::uint64_t> scan_seq_{0};
  std::atomic<std::uint64_t> ticks_{0};
  std::atomic<std::uint64_t> flips_{0};
  std::atomic<std::uint64_t> hold_flips_{0};
  std::atomic<std::uint64_t> pauses_{0};
  std::atomic<std::uint64_t> double_scans_{0};
  std::atomic<std::uint64_t> hold_rescans_{0};
  std::atomic<std::uint64_t> deadline_overruns_{0};
  std::atomic<std::uint64_t> flip_failures_{0};

  std::thread thread_;
  std::atomic<bool> running_{false};
  std::atomic<bool> stop_requested_{false};
};

}  // namespace pluto::swtcon

#endif  // PLUTO_PRESENTER_SWTCON_SCAN_LOOP_H_
