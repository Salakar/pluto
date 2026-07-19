#ifndef PLUTO_PRESENTER_SWTCON_XOCHITL_PARALLEL_H_
#define PLUTO_PRESENTER_SWTCON_XOCHITL_PARALLEL_H_

#include <algorithm>
#include <array>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <system_error>
#include <thread>
#include <type_traits>
#include <utility>

#if defined(__linux__)
#include <pthread.h>
#include <sched.h>
#include <unistd.h>
#endif

namespace pluto::swtcon::xochitl_parallel {

// The Move has two online Cortex-A55 CPUs. Keep the maximum at three for
// larger hosts while never creating more compute participants than the
// logical CPUs reported by the runtime. A zero result means "unknown", for
// which serial execution is the only conservative choice.
inline constexpr std::size_t kMaxComputeStripes = 3;
inline constexpr std::size_t kParallelWorkItemThreshold = 512u * 512u;

constexpr std::size_t
compute_stripes_for_logical_cpus(unsigned int logical_cpus) noexcept {
  return logical_cpus == 0
             ? 1u
             : std::min<std::size_t>(kMaxComputeStripes, logical_cpus);
}

inline std::size_t available_compute_stripes() noexcept {
  static const std::size_t stripes =
      compute_stripes_for_logical_cpus(std::thread::hardware_concurrency());
  return stripes;
}

constexpr std::size_t
compute_stripes_for_work_items(std::size_t work_items,
                               unsigned int logical_cpus) noexcept {
  return work_items < kParallelWorkItemThreshold
             ? 1u
             : compute_stripes_for_logical_cpus(logical_cpus);
}

inline std::size_t
available_compute_stripes_for_work_items(std::size_t work_items) noexcept {
  return work_items < kParallelWorkItemThreshold
             ? 1u
             : available_compute_stripes();
}

struct ThreadLauncher final {
  template <typename Work>
  void operator()(std::thread *thread, Work &&work) const {
    *thread = std::thread(std::forward<Work>(work));
  }
};

// std::thread inherits both policy and affinity from its creator on Linux.
// Color/history splitting is invoked by swtcon-engine after that thread has
// become SCHED_FIFO and CPU1-only. An inherited equal-priority FIFO child may
// not run until its parent blocks, so child-side setup is too late: configure
// the native handle from the parent while the child is held behind its start
// gate. The caller deliberately retains its engine policy and affinity.
inline bool configure_compute_worker_thread(
    std::thread::native_handle_type worker) noexcept {
#if defined(__linux__)
  sched_param normal{};
  if (pthread_setschedparam(worker, SCHED_OTHER, &normal) != 0) {
    return false;
  }

  const long online_cpus = sysconf(_SC_NPROCESSORS_ONLN);
  if (online_cpus <= 0) {
    return false;
  }
  cpu_set_t cpus;
  CPU_ZERO(&cpus);
  const int caller_cpu = sched_getcpu();
  const long representable_cpus =
      std::min<long>(online_cpus, static_cast<long>(CPU_SETSIZE));
  for (long cpu = 0; cpu < representable_cpus; ++cpu) {
    // Keep the compute helper off the caller's currently-running core when
    // another CPU exists. This is deterministic on Move's two A55s (engine
    // CPU1, helper CPU0) and prevents Linux initially colocating both halves
    // of a phase build before load balancing reacts.
    if (representable_cpus == 1 || cpu != caller_cpu) {
      CPU_SET(static_cast<int>(cpu), &cpus);
    }
  }
  if (pthread_setaffinity_np(worker, sizeof(cpus), &cpus) != 0) {
    return false;
  }
#else
  (void)worker;
#endif
  return true;
}

// Phase construction differs from admission-time color preprocessing: its
// helper is in the 85 Hz deadline chain. Match an RT caller one priority step
// lower (engine 60 -> helper 59), retain SCHED_OTHER for ordinary callers,
// and keep the helper off the caller's current CPU. The worker runs only one
// bounded row-band stripe and sleeps between frames.
inline bool
configure_phase_worker_thread(std::thread::native_handle_type worker) noexcept {
#if defined(__linux__)
  int caller_policy = SCHED_OTHER;
  sched_param caller_param{};
  if (pthread_getschedparam(pthread_self(), &caller_policy, &caller_param) !=
      0) {
    return false;
  }
  sched_param worker_param{};
  int worker_policy = SCHED_OTHER;
  if (caller_policy == SCHED_FIFO || caller_policy == SCHED_RR) {
    worker_policy = caller_policy;
    worker_param.sched_priority = std::max(1, caller_param.sched_priority - 1);
  }
  if (pthread_setschedparam(worker, worker_policy, &worker_param) != 0) {
    return false;
  }

  const long online_cpus = sysconf(_SC_NPROCESSORS_ONLN);
  if (online_cpus <= 0) {
    return false;
  }
  const int caller_cpu = sched_getcpu();
  cpu_set_t cpus;
  CPU_ZERO(&cpus);
  const long representable_cpus =
      std::min<long>(online_cpus, static_cast<long>(CPU_SETSIZE));
  for (long cpu = 0; cpu < representable_cpus; ++cpu) {
    if (representable_cpus == 1 || cpu != caller_cpu) {
      CPU_SET(static_cast<int>(cpu), &cpus);
    }
  }
  if (pthread_setaffinity_np(worker, sizeof(cpus), &cpus) != 0) {
    return false;
  }
#else
  (void)worker;
#endif
  return true;
}

// One persistent compute helper for an owner-thread + helper pair. The caller
// lends a stack-resident work object through a no-allocation type-erased
// trampoline, executes stripe 1 itself, then waits until stripe 0 completes.
// It is intentionally a pair rather than a general pool: Move has exactly two
// A55s, and the phase path needs one wake/join rendezvous, not worker churn.
class PersistentComputePair final {
public:
  PersistentComputePair() = default;
  ~PersistentComputePair() { stop(); }
  PersistentComputePair(const PersistentComputePair &) = delete;
  PersistentComputePair &operator=(const PersistentComputePair &) = delete;

  bool start() noexcept {
    if (worker_.joinable()) {
      return true;
    }
    try {
      worker_ = std::thread([this] { worker_loop(); });
      return true;
    } catch (const std::system_error &) {
      return false;
    }
  }

  bool available() const noexcept { return worker_.joinable(); }

  template <typename Work> bool run(Work &work) {
    using WorkType = std::remove_cvref_t<Work>;
    if (!worker_.joinable()) {
      return false;
    }
    if (!configured_) {
      if (!configure_phase_worker_thread(worker_.native_handle())) {
        return false;
      }
      configured_ = true;
    }
    {
      std::lock_guard lock(mutex_);
      if (stop_) {
        return false;
      }
      context_ = &work;
      invoke_ = [](void *context, std::size_t stripe) {
        (*static_cast<WorkType *>(context))(stripe);
      };
      done_ = false;
      ++epoch_;
    }
    cv_.notify_one();
    work(1);
    std::unique_lock lock(mutex_);
    done_cv_.wait(lock, [this] { return done_ || stop_; });
    context_ = nullptr;
    invoke_ = nullptr;
    return done_ && !stop_;
  }

private:
  using Invoke = void (*)(void *, std::size_t);

  void stop() noexcept {
    if (!worker_.joinable()) {
      return;
    }
    {
      std::lock_guard lock(mutex_);
      stop_ = true;
    }
    cv_.notify_one();
    worker_.join();
  }

  void worker_loop() {
    std::uint64_t observed_epoch = 0;
    while (true) {
      Invoke invoke = nullptr;
      void *context = nullptr;
      {
        std::unique_lock lock(mutex_);
        cv_.wait(lock, [this, observed_epoch] {
          return stop_ || epoch_ != observed_epoch;
        });
        if (stop_) {
          return;
        }
        observed_epoch = epoch_;
        invoke = invoke_;
        context = context_;
      }
      invoke(context, 0);
      {
        std::lock_guard lock(mutex_);
        done_ = true;
      }
      done_cv_.notify_one();
    }
  }

  std::thread worker_;
  std::mutex mutex_;
  std::condition_variable cv_;
  std::condition_variable done_cv_;
  void *context_ = nullptr;
  Invoke invoke_ = nullptr;
  std::uint64_t epoch_ = 0;
  bool done_ = false;
  bool stop_ = false;
  bool configured_ = false;
};

struct WorkerThreadConfigurator final {
  bool operator()(std::thread::native_handle_type worker,
                  std::size_t) const noexcept {
    return configure_compute_worker_thread(worker);
  }
};

struct WorkerStartGate final {
  std::mutex mutex;
  bool may_run = false;
};

// Runs [0, stripe_count) with the caller as one compute participant. Workers
// own the first stripes and the caller owns the final stripe. If creation of a
// worker fails, already-started workers retain their disjoint stripes while
// the caller completes every unstarted stripe before joining them.
//
// Launcher and configurator are injectable so creation and policy failures can
// be tested deterministically without exhausting resources or changing the
// test runner's own scheduling policy.
template <typename Work, typename Launcher, typename Configurator>
void run_compute_stripes(std::size_t stripe_count, Work &&work,
                         Launcher &&launcher, Configurator &&configurator) {
  stripe_count =
      std::clamp<std::size_t>(stripe_count, 1u, kMaxComputeStripes);
  std::array<std::thread, kMaxComputeStripes - 1u> workers;
  std::array<WorkerStartGate, kMaxComputeStripes - 1u> start_gates;
  std::array<bool, kMaxComputeStripes - 1u> worker_completed{};
  std::size_t launched = 0;
  for (; launched + 1u < stripe_count; ++launched) {
    WorkerStartGate &gate = start_gates[launched];
    // Holding this lock before pthread_create guarantees an inherited FIFO
    // child blocks before it can touch output. The parent can therefore lower
    // its native handle and widen affinity without first yielding CPU1.
    std::unique_lock gate_lock(gate.mutex);
    try {
      launcher(&workers[launched], [&, stripe = launched] {
        bool may_run = false;
        {
          std::lock_guard start_lock(start_gates[stripe].mutex);
          may_run = start_gates[stripe].may_run;
        }
        if (may_run) {
          work(stripe);
          worker_completed[stripe] = true;
        }
      });
    } catch (const std::system_error &) {
      if (workers[launched].joinable()) {
        gate.may_run = false;
        gate_lock.unlock();
        workers[launched].join();
      }
      break;
    }
    bool configured = false;
    try {
      configured =
          configurator(workers[launched].native_handle(), launched);
    } catch (...) {
      // Configuration is a throughput optimization. The gated worker exits
      // untouched and its stripe takes the exact caller fallback below.
    }
    gate.may_run = configured;
    gate_lock.unlock();
  }

  try {
    for (std::size_t stripe = launched; stripe < stripe_count; ++stripe) {
      work(stripe);
    }
  } catch (...) {
    for (std::size_t index = 0; index < launched; ++index) {
      workers[index].join();
    }
    throw;
  }
  for (std::size_t index = 0; index < launched; ++index) {
    workers[index].join();
  }
  // A worker that could not be moved out of inherited realtime policy or CPU1
  // affinity never passed its start gate. Complete that disjoint stripe
  // exactly once on the caller instead.
  for (std::size_t index = 0; index < launched; ++index) {
    if (!worker_completed[index]) {
      work(index);
    }
  }
}

template <typename Work, typename Launcher>
void run_compute_stripes(std::size_t stripe_count, Work &&work,
                         Launcher &&launcher) {
  run_compute_stripes(stripe_count, std::forward<Work>(work),
                      std::forward<Launcher>(launcher),
                      WorkerThreadConfigurator{});
}

template <typename Work>
void run_compute_stripes(std::size_t stripe_count, Work &&work) {
  run_compute_stripes(stripe_count, std::forward<Work>(work),
                      ThreadLauncher{});
}

} // namespace pluto::swtcon::xochitl_parallel

#endif // PLUTO_PRESENTER_SWTCON_XOCHITL_PARALLEL_H_
