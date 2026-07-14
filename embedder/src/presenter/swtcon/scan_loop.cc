#include "presenter/swtcon/scan_loop.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstring>

#include <pthread.h>
#include <sched.h>

namespace pluto::swtcon {
namespace {

// scan_period_ns fallback: round(1e9 / 85).
constexpr std::uint64_t kFallbackScanPeriodNs = 11764706;

// Period from the ENUMERATED mode (mandatory decision — never a
// hardcoded 1e9/85 when timings exist): clock is kHz, so
// period_ns = htotal * vtotal * 1e6 / clock, rounded to nearest.
std::uint64_t period_from_mode(const DrmModeInfo& mode) {
  if (mode.clock == 0 || mode.htotal == 0 || mode.vtotal == 0) {
    return kFallbackScanPeriodNs;
  }
  const std::uint64_t pixels = static_cast<std::uint64_t>(mode.htotal) *
                               static_cast<std::uint64_t>(mode.vtotal);
  return (pixels * 1000000ull + mode.clock / 2) / mode.clock;
}

}  // namespace

std::uint64_t SteadyScanClock::now_ns() {
  return static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(
          std::chrono::steady_clock::now().time_since_epoch())
          .count());
}

void SteadyScanClock::sleep_until_ns(std::uint64_t deadline_ns) {
  const std::chrono::steady_clock::time_point deadline{
      std::chrono::nanoseconds(deadline_ns)};
  std::this_thread::sleep_until(deadline);
}

ScanLoop::~ScanLoop() { stop(); }

bool ScanLoop::configure(DrmSwtconDevice* device, ScanClock* clock,
                         const ScanLoopConfig& config) {
  if (device == nullptr || clock == nullptr || !device->is_open() ||
      config.hold_slot >= device->buffers().size()) {
    return false;
  }
  config_ = config;
  device_ = device;
  clock_ = clock;
  period_ns_ = config.scan_period_ns != 0 ? config.scan_period_ns
                                          : period_from_mode(device->mode());

  // Prime the HOLD slot with the blank scaffold: always-blank by
  // construction (impulse-free neutral frame, the DU-no-hold fix,
  // and the only legal rails-down parking target).
  std::vector<std::uint16_t> blank(kDrmPhaseWords, 0);
  init_blank_phase_frame(blank.data());
  if (device_->copy_phase_to_buffer(config_.hold_slot, blank.data()) !=
      kPlutoStatusOk) {
    return false;
  }

  pending_flips_.clear();
  pending_flips_.reserve(kDrmBufferCount);
  event_scratch_.reserve(kDrmBufferCount);
  ready_slot_.reset();
  last_completed_ = PendingFlip{};
  last_event_sequence_ = 0;
  have_event_sequence_ = false;
  last_completed_event_anchored_ = false;
  min_latch_gap_ = 0;
  configured_ = true;
  return true;
}

bool ScanLoop::tick() {
  if (!configured_) {
    return false;
  }
  ticks_.fetch_add(1, std::memory_order_relaxed);

  // B = scan_ready.take_if_newer else HOLD.
  std::uint32_t buffer_index = static_cast<std::uint32_t>(config_.hold_slot);
  std::uint64_t engine_seq = 0;
  const bool hold = !ready_slot_.take(&buffer_index, &engine_seq);

  PlutoStatus status;
  std::uint64_t cookie = 0;
  if (config_.consume_flip_events) {
    cookie = ++next_flip_cookie_;
    status = device_->atomic_flip_event(buffer_index, cookie);
  } else {
    status = device_->atomic_flip(buffer_index);
  }
  if (status != kPlutoStatusOk) {
    flip_failures_.fetch_add(1, std::memory_order_relaxed);
    return false;
  }
  if (config_.consume_flip_events) {
    PendingFlip pending;
    pending.user_data = cookie;
    pending.buffer_index = buffer_index;
    pending.engine_seq = hold ? 0 : engine_seq;
    pending.valid = true;
    pending_flips_.push_back(pending);
  } else {
    // Event-less mode is restricted to dry-run/test shells. The successful
    // blocking commit is the strongest available acknowledgement there, and
    // the next blocking flip resolves the preceding content plane with zero
    // extra scans (there is no event sequence from which to infer rescans).
    PendingFlip completed;
    completed.buffer_index = buffer_index;
    completed.engine_seq = hold ? 0 : engine_seq;
    completed.valid = true;
    complete_flip(completed, CompletionEvidence::kBlocking, 0);
  }

  if (hold) {
    hold_flips_.fetch_add(1, std::memory_order_relaxed);
    // pause semantics (E10): HOLD while the engine has in-flight work
    // is a missed deadline — an impulse-free time-stretch. The engine
    // charges k_pause stress and does NOT advance fnum (it never built).
    if (engine_active_ && engine_active_()) {
      pauses_.fetch_add(1, std::memory_order_relaxed);
      if (on_pause_) {
        on_pause_();
      }
    }
  } else {
    flips_.fetch_add(1, std::memory_order_relaxed);
  }

  if (config_.consume_flip_events) {
    drain_events();
  }

  const std::uint64_t seq =
      scan_seq_.fetch_add(1, std::memory_order_relaxed) + 1;
  if (on_tick_) {
    on_tick_(seq);
  }
  return true;
}

void ScanLoop::drain_events() {
  event_scratch_.clear();
  if (!device_->drain_flip_events(&event_scratch_)) {
    return;
  }
  for (const DrmFlipEvent& event : event_scratch_) {
    // Match the completion to the oldest pending flip (events complete in
    // submission order. A driver/mock may coalesce older cookies: expose
    // every skipped flip in order, but mark its classification unresolved.
    const auto match = std::find_if(
        pending_flips_.begin(), pending_flips_.end(),
        [&event](const PendingFlip& pending) {
          return pending.user_data == event.user_data;
        });
    if (match == pending_flips_.end()) {
      // An unknown/newer cookie cannot prove which pending plane reached the
      // latch, but silently dropping the journal identities would leave a
      // fail-closed history consumer waiting forever. Surface every pending
      // identity in submission order as unconfirmed/coalesced feedback. The
      // legacy latch callback and ready-slot acknowledgement deliberately do
      // not fire: there is still no positive latch evidence for any one plane.
      for (const PendingFlip& pending : pending_flips_) {
        complete_flip(pending, CompletionEvidence::kCoalesced, 0);
      }
      pending_flips_.clear();
      continue;
    }
    for (auto skipped = pending_flips_.begin(); skipped != match; ++skipped) {
      complete_flip(*skipped, CompletionEvidence::kCoalesced, 0);
    }
    const PendingFlip completed = *match;
    pending_flips_.erase(pending_flips_.begin(), match + 1);
    complete_flip(completed, CompletionEvidence::kEvent, event.sequence);
  }
}

void ScanLoop::complete_flip(const PendingFlip& completed,
                             CompletionEvidence evidence,
                             std::uint32_t event_sequence) {
  assert(completed.valid);

  // Preserve the established callback semantics: the current content latch
  // is acknowledged and reported before classifying the previous plane.
  if (completed.engine_seq != 0 &&
      evidence != CompletionEvidence::kCoalesced) {
    ready_slot_.acknowledge(completed.engine_seq);
    if (on_latched_) {
      on_latched_(completed.engine_seq);
    }
  }

  ScanFeedback feedback;
  feedback.latched_buffer_index = completed.buffer_index;
  feedback.latched_engine_seq = completed.engine_seq;
  feedback.latched_scan_known = evidence != CompletionEvidence::kCoalesced;

  bool previous_resolved = false;
  std::uint32_t extra = 0;
  if (last_completed_.valid) {
    feedback.previous_flip_valid = true;
    feedback.previous_buffer_index = last_completed_.buffer_index;
    feedback.previous_engine_seq = last_completed_.engine_seq;
    if (evidence == CompletionEvidence::kBlocking) {
      // Blocking event-less commits are used only by dry-run/test shells.
      previous_resolved = true;
    } else if (evidence == CompletionEvidence::kEvent &&
               last_completed_event_anchored_ && have_event_sequence_ &&
               event_sequence > last_event_sequence_) {
      const std::uint32_t gap = event_sequence - last_event_sequence_;
      if (min_latch_gap_ == 0 || gap < min_latch_gap_) {
        min_latch_gap_ = gap;
      }
      extra = gap - min_latch_gap_;
      previous_resolved = true;
    }
  }

  // Double-scan detection (mandatory decision): the hardware vblank
  // count jumping by MORE THAN THE learned steady cadence means the
  // PREVIOUSLY latched plane was scanned again. HOLD rescans are counted but
  // remain impulse-free and never fire the legacy recharge callback.
  if (previous_resolved && extra > 0) {
    if (last_completed_.engine_seq == 0) {
      hold_rescans_.fetch_add(extra, std::memory_order_relaxed);
    } else {
      double_scans_.fetch_add(extra, std::memory_order_relaxed);
      if (on_double_scan_) {
        on_double_scan_(last_completed_.buffer_index,
                        last_completed_.engine_seq, extra);
      }
    }
  }

  if (previous_resolved) {
    feedback.previous_scan_count_known = true;
    feedback.previous_extra_scans = extra;
    feedback.previous_content_resolved = last_completed_.engine_seq != 0;
  }
  // New feedback is deliberately last: consumers observe the current latch
  // only after all legacy classification callbacks for this completion.
  if (on_feedback_) {
    on_feedback_(feedback);
  }

  if (evidence == CompletionEvidence::kEvent) {
    last_event_sequence_ = event_sequence;
    have_event_sequence_ = true;
  }
  last_completed_ = completed;
  last_completed_event_anchored_ =
      evidence == CompletionEvidence::kEvent;
}

bool ScanLoop::start() {
  if (!configured_ || running_.load(std::memory_order_acquire)) {
    return false;
  }
  stop_requested_.store(false, std::memory_order_release);
  running_.store(true, std::memory_order_release);
  thread_ = std::thread(&ScanLoop::run, this);
  return true;
}

void ScanLoop::stop() {
  stop_requested_.store(true, std::memory_order_release);
  if (thread_.joinable()) {
    thread_.join();
  }
  running_.store(false, std::memory_order_release);
}

void ScanLoop::run() {
#if defined(__APPLE__)
  (void)pthread_setname_np("swtcon-scan");
#elif defined(__linux__)
  (void)pthread_setname_np(pthread_self(), "swtcon-scan");
#endif
#if defined(SCHED_FIFO)
  if (config_.sched_fifo_priority >= 0) {
    sched_param param{};
    param.sched_priority = config_.sched_fifo_priority;
    (void)pthread_setschedparam(pthread_self(), SCHED_FIFO, &param);
  }
#endif
#if defined(__linux__)
  // affinity plan (best-effort; degrades gracefully on EPERM).
  if (config_.cpu_affinity >= 0) {
    cpu_set_t cpus;
    CPU_ZERO(&cpus);
    CPU_SET(config_.cpu_affinity, &cpus);
    (void)sched_setaffinity(0, sizeof(cpus), &cpus);
  }
#endif
  // Absolute deadlines: zero drift. A tick that overruns a FULL
  // period resynchronizes instead of bursting catch-up flips — each
  // overrun is counted (the panel saw a longer hold, not a faster scan).
  std::uint64_t deadline = clock_->now_ns() + period_ns_;
  while (!stop_requested_.load(std::memory_order_acquire)) {
    if (!tick()) {
      break;  // device lost
    }
    clock_->sleep_until_ns(deadline);
    deadline += period_ns_;
    const std::uint64_t now = clock_->now_ns();
    if (now > deadline) {
      deadline_overruns_.fetch_add(1, std::memory_order_relaxed);
      deadline = now + period_ns_;
    }
  }
  running_.store(false, std::memory_order_release);
}

ScanLoopStats ScanLoop::stats() const {
  ScanLoopStats out;
  out.ticks = ticks_.load(std::memory_order_relaxed);
  out.flips = flips_.load(std::memory_order_relaxed);
  out.hold_flips = hold_flips_.load(std::memory_order_relaxed);
  out.pauses = pauses_.load(std::memory_order_relaxed);
  out.double_scans = double_scans_.load(std::memory_order_relaxed);
  out.hold_rescans = hold_rescans_.load(std::memory_order_relaxed);
  out.deadline_overruns = deadline_overruns_.load(std::memory_order_relaxed);
  out.flip_failures = flip_failures_.load(std::memory_order_relaxed);
  return out;
}

}  // namespace pluto::swtcon
