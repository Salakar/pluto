#include "runtime/vsync_pacer.h"

#include <algorithm>
#include <limits>

namespace pluto {
namespace {

constexpr uint64_t kDefaultVsyncIntervalNs = 16'666'667;

uint64_t effective_interval(uint64_t interval) {
  return interval == 0 ? kDefaultVsyncIntervalNs : interval;
}

uint64_t frame_target_after(uint64_t start, uint64_t interval) {
  return start > std::numeric_limits<uint64_t>::max() - interval
             ? std::numeric_limits<uint64_t>::max()
             : start + interval;
}

}  // namespace

VsyncPacer::VsyncPacer(EventLoop* loop) : loop_(loop) {}

void VsyncPacer::set_engine(const FlutterEngineProcTable* procs,
                            FlutterEngine engine) {
  std::lock_guard<std::mutex> lock(mutex_);
  procs_ = procs;
  engine_ = engine;
  accepting_requests_ = procs != nullptr && engine != nullptr;
}

void VsyncPacer::set_enabled(bool enabled) {
  std::lock_guard<std::mutex> lock(mutex_);
  enabled_ = enabled;
}

void VsyncPacer::set_mode(VsyncPacerMode mode) {
  std::lock_guard<std::mutex> lock(mutex_);
  mode_ = mode;
}

void VsyncPacer::set_interval_ns(uint64_t ns) {
  std::lock_guard<std::mutex> lock(mutex_);
  interval_override_ns_ = ns;
}

void VsyncPacer::set_pen_proximity(bool in_range) {
  std::vector<uint64_t> expedite_tokens;
  uint64_t now = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (pen_proximity_ == in_range) {
      return;
    }
    pen_proximity_ = in_range;
    // Neither an old 24 ms debt on entry nor an old 11.764 ms debt on exit
    // may delay the first frame in the new interaction regime.
    last_target_ns_ = 0;
    if (!in_range || !enabled_ || rendering_paused_ ||
        !accepting_requests_ || pending_vsyncs_.empty() || loop_ == nullptr) {
      return;
    }

    // A baton can already be waiting at the ordinary e-ink cap when hover is
    // detected. Re-post the same token at now; its old closure later becomes
    // a harmless no-op after the expedited closure removes the token.
    now = loop_->now_nanos();
    last_target_ns_ = now;
    expedite_tokens.reserve(pending_vsyncs_.size());
    for (PendingVsync& pending : pending_vsyncs_) {
      pending.frame_start_ns = now;
      pending.frame_target_ns =
          frame_target_after(now, kPenFrameIntervalNs);
      expedite_tokens.push_back(pending.token);
    }
  }
  for (const uint64_t token : expedite_tokens) {
    schedule(token, now);
  }
}

bool VsyncPacer::pen_proximity() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return pen_proximity_;
}

void VsyncPacer::set_rendering_paused(bool paused) {
  std::vector<uint64_t> resume_tokens;
  uint64_t now = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (rendering_paused_ == paused) {
      return;
    }
    rendering_paused_ = paused;
    if (paused) {
      return;
    }
    // A maintenance sequence is much longer than the normal pacing interval.
    // Resume from a clean cadence. Flutter normally has one baton outstanding;
    // if a caller supplied more, preserve and return every one as required by
    // the embedder contract instead of silently coalescing them.
    last_target_ns_ = 0;
    if (!pending_vsyncs_.empty() && loop_ != nullptr) {
      now = loop_->now_nanos();
      const uint64_t interval =
          effective_interval(interval_nanos_locked());
      resume_tokens.reserve(pending_vsyncs_.size());
      for (PendingVsync& pending : pending_vsyncs_) {
        pending.frame_start_ns = now;
        pending.frame_target_ns = frame_target_after(now, interval);
        resume_tokens.push_back(pending.token);
      }
      if (pen_proximity_) {
        last_target_ns_ = now;
      }
    }
  }
  for (const uint64_t token : resume_tokens) {
    schedule(token, now);
  }
}

bool VsyncPacer::rendering_paused() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return rendering_paused_;
}

uint64_t VsyncPacer::interval_nanos_locked() const {
  if (!enabled_) {
    return 0;
  }
  if (pen_proximity_) {
    return kPenFrameIntervalNs;
  }
  // A hard cap (from config/env) wins over the mode intervals: it throttles
  // Flutter's frame production to the panel's realistic rate regardless of
  // the (currently unused) animation-mode heuristic.
  if (interval_override_ns_ != 0) {
    return interval_override_ns_;
  }
  if (mode_ == VsyncPacerMode::kIdle) {
    return 0;
  }
  switch (mode_) {
    case VsyncPacerMode::kInteractive:
      return 23529412ull;
    case VsyncPacerMode::kAnimating:
      return 33333333ull;
    case VsyncPacerMode::kThrottled:
      return 66666666ull;
    case VsyncPacerMode::kIdle:
      return 0;
  }
  return 0;
}

uint64_t VsyncPacer::next_target_ns(uint64_t start, uint64_t last_target,
                                    uint64_t interval) {
  if (interval == 0 || last_target == 0 || start >= last_target + interval) {
    return start;  // isolated frame (or uncapped): no pacing debt to pay
  }
  return last_target + interval;  // sustained: exactly one frame per interval
}

void VsyncPacer::request(intptr_t baton) {
  if (loop_ == nullptr) {
    return;
  }
  const uint64_t start = loop_->now_nanos();
  uint64_t target = start;
  uint64_t frame_interval = kDefaultVsyncIntervalNs;
  uint64_t token = 0;
  bool paused = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!accepting_requests_) {
      // The engine may race one last internal vsync callback with
      // Deinitialize. Keep it for finish_shutdown() on the platform thread;
      // never post new work onto the stopping EventLoop.
      token = next_token_++;
      pending_vsyncs_.push_back(PendingVsync{
          token, baton, start,
          frame_target_after(start, kDefaultVsyncIntervalNs)});
      return;
    }
    paused = rendering_paused_;
    if (!paused) {
      const uint64_t pacing_interval = interval_nanos_locked();
      target = next_target_ns(start, last_target_ns_, pacing_interval);
      last_target_ns_ = target;
      frame_interval = effective_interval(pacing_interval);
    } else {
      frame_interval = effective_interval(interval_nanos_locked());
    }
    token = next_token_++;
    pending_vsyncs_.push_back(PendingVsync{
        token, baton, target, frame_target_after(target, frame_interval)});
  }
  if (!paused) {
    schedule(token, target);
  }
}

void VsyncPacer::begin_shutdown() {
  std::lock_guard<std::mutex> lock(mutex_);
  accepting_requests_ = false;
  rendering_paused_ = false;
}

void VsyncPacer::schedule(uint64_t token, uint64_t target) {
  loop_->post_closure_at(target, [this, token] { deliver(token); });
}

void VsyncPacer::deliver(uint64_t token) {
  PendingVsync pending;
  const FlutterEngineProcTable* procs = nullptr;
  FlutterEngine engine = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (rendering_paused_) {
      return;
    }
    const auto it = std::find_if(
        pending_vsyncs_.begin(), pending_vsyncs_.end(),
        [token](const PendingVsync& item) { return item.token == token; });
    if (it == pending_vsyncs_.end()) {
      return;  // already force-returned by flush() or another resume closure
    }
    pending = *it;
    pending_vsyncs_.erase(it);
    procs = procs_;
    engine = engine_;
  }
  if (procs != nullptr && procs->OnVsync != nullptr && engine != nullptr) {
    procs->OnVsync(engine, pending.baton, pending.frame_start_ns,
                   pending.frame_target_ns);
  }
}

void VsyncPacer::flush() {
  std::vector<PendingVsync> pending;
  const FlutterEngineProcTable* procs = nullptr;
  FlutterEngine engine = nullptr;
  uint64_t interval = kDefaultVsyncIntervalNs;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    last_target_ns_ = 0;
    rendering_paused_ = false;
    pending.swap(pending_vsyncs_);
    procs = procs_;
    engine = engine_;
    interval = effective_interval(interval_nanos_locked());
  }
  // EngineHost calls flush on Flutter's platform thread immediately before
  // shutdown. Return every outstanding baton there; already-posted closures
  // subsequently find no matching token and become harmless no-ops.
  if (procs == nullptr || procs->OnVsync == nullptr || engine == nullptr) {
    return;
  }
  uint64_t now = loop_ != nullptr ? loop_->now_nanos() : 0;
  for (const PendingVsync& item : pending) {
    procs->OnVsync(engine, item.baton, now,
                   frame_target_after(now, interval));
    ++now;
  }
}

void VsyncPacer::finish_shutdown() {
  std::vector<PendingVsync> pending;
  const FlutterEngineProcTable* procs = nullptr;
  FlutterEngine engine = nullptr;
  uint64_t interval = kDefaultVsyncIntervalNs;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    accepting_requests_ = false;
    rendering_paused_ = false;
    last_target_ns_ = 0;
    pending.swap(pending_vsyncs_);
    procs = procs_;
    engine = engine_;
    interval = effective_interval(interval_nanos_locked());
    procs_ = nullptr;
    engine_ = nullptr;
  }
  if (procs == nullptr || procs->OnVsync == nullptr || engine == nullptr) {
    return;
  }
  uint64_t now = loop_ != nullptr ? loop_->now_nanos() : 0;
  for (const PendingVsync& item : pending) {
    procs->OnVsync(engine, item.baton, now,
                   frame_target_after(now, interval));
    ++now;
  }
}

}  // namespace pluto
