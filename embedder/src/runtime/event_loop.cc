#include "runtime/event_loop.h"

#include <algorithm>
#include <chrono>
#include <cstring>

#if defined(__linux__)
#include <signal.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/signalfd.h>
#include <sys/timerfd.h>
#include <unistd.h>
#endif

namespace pluto {
namespace {

uint64_t steady_now_nanos() {
  using clock = std::chrono::steady_clock;
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             clock::now().time_since_epoch())
      .count();
}

}  // namespace

EventLoop::EventLoop() {
  loop_thread_ = std::this_thread::get_id();
  runner_.struct_size = sizeof(runner_);
  runner_.user_data = this;
  runner_.runs_task_on_current_thread_callback =
      &EventLoop::runs_task_on_current_thread;
  runner_.post_task_callback = &EventLoop::post_task_callback;
  runner_.identifier = 1;
  runner_.destruction_callback = nullptr;

  custom_runners_.struct_size = sizeof(custom_runners_);
  custom_runners_.platform_task_runner = &runner_;
  custom_runners_.render_task_runner = nullptr;
  custom_runners_.thread_priority_setter = nullptr;
  custom_runners_.ui_task_runner = nullptr;

#if defined(__linux__)
  epoll_fd_ = epoll_create1(EPOLL_CLOEXEC);
  event_fd_ = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
  timer_fd_ = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
  sigset_t mask;
  sigemptyset(&mask);
  sigaddset(&mask, SIGTERM);
  sigaddset(&mask, SIGINT);
  sigaddset(&mask, SIGHUP);
  sigaddset(&mask, SIGUSR1);
  sigaddset(&mask, SIGUSR2);
  pthread_sigmask(SIG_BLOCK, &mask, nullptr);
  signal_fd_ = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
  if (epoll_fd_ >= 0) {
    auto add_fd = [this](int fd, uint32_t tag) {
      if (fd < 0) {
        return;
      }
      epoll_event event{};
      event.events = EPOLLIN;
      event.data.u32 = tag;
      epoll_ctl(epoll_fd_, EPOLL_CTL_ADD, fd, &event);
    };
    add_fd(event_fd_, 1);
    add_fd(timer_fd_, 2);
    add_fd(signal_fd_, 3);
  }
#endif
}

EventLoop::~EventLoop() {
  stop();
#if defined(__linux__)
  if (signal_fd_ >= 0) {
    close(signal_fd_);
  }
  if (timer_fd_ >= 0) {
    close(timer_fd_);
  }
  if (event_fd_ >= 0) {
    close(event_fd_);
  }
  if (epoll_fd_ >= 0) {
    close(epoll_fd_);
  }
#endif
}

void EventLoop::set_engine(const FlutterEngineProcTable* procs,
                           FlutterEngine engine) {
  std::lock_guard<std::mutex> lock(mutex_);
  procs_ = procs;
  engine_ = engine;
}

void EventLoop::set_signal_handler(std::function<void(int)> handler) {
  std::lock_guard<std::mutex> lock(mutex_);
  signal_handler_ = std::move(handler);
}

void EventLoop::post_closure(std::function<void()> closure) {
  post_closure_at(now_nanos(), std::move(closure));
}

void EventLoop::post_closure_at(uint64_t target_time_nanos,
                                std::function<void()> closure) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    pending_.push_back(Pending{target_time_nanos, next_sequence_++, false, {},
                               std::move(closure)});
    arm_timer_locked();
  }
  wake();
}

void EventLoop::post_flutter_task(FlutterTask task, uint64_t target_time_nanos) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    pending_.push_back(
        Pending{target_time_nanos, next_sequence_++, true, task, {}});
    arm_timer_locked();
  }
  wake();
}

void EventLoop::run() {
  loop_thread_ = std::this_thread::get_id();
  while (true) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (stopping_) {
        break;
      }
    }
    run_due_tasks_for_test(now_nanos());

#if defined(__linux__)
    if (epoll_fd_ >= 0) {
      epoll_event events[4];
      const int count = epoll_wait(epoll_fd_, events, 4, 50);
      for (int i = 0; i < count; ++i) {
        if (events[i].data.u32 == 1 && event_fd_ >= 0) {
          uint64_t value = 0;
          read(event_fd_, &value, sizeof(value));
        } else if (events[i].data.u32 == 2 && timer_fd_ >= 0) {
          uint64_t expirations = 0;
          read(timer_fd_, &expirations, sizeof(expirations));
        } else if (events[i].data.u32 == 3 && signal_fd_ >= 0) {
          signalfd_siginfo info{};
          if (read(signal_fd_, &info, sizeof(info)) != sizeof(info)) {
            continue;
          }
          if (info.ssi_signo == SIGTERM || info.ssi_signo == SIGINT) {
            stop();
          } else {
            std::function<void(int)> handler;
            {
              std::lock_guard<std::mutex> lock(mutex_);
              handler = signal_handler_;
            }
            if (handler) {
              handler(static_cast<int>(info.ssi_signo));
            }
          }
        }
      }
      continue;
    }
#endif
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait_for(lock, std::chrono::milliseconds(50));
  }
}

void EventLoop::stop() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  wake();
}

size_t EventLoop::run_due_tasks_for_test(uint64_t now_nanos_value) {
  size_t ran = 0;
  while (true) {
    Pending pending;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!pop_due_locked(now_nanos_value, &pending)) {
        arm_timer_locked();
        break;
      }
    }
    if (pending.is_flutter_task) {
      const FlutterEngineProcTable* procs = nullptr;
      FlutterEngine engine = nullptr;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        procs = procs_;
        engine = engine_;
      }
      if (procs != nullptr && procs->RunTask != nullptr && engine != nullptr) {
        procs->RunTask(engine, &pending.flutter_task);
      }
    } else if (pending.closure) {
      pending.closure();
    }
    ++ran;
  }
  return ran;
}

bool EventLoop::runs_on_loop_thread() const {
  return std::this_thread::get_id() == loop_thread_;
}

uint64_t EventLoop::now_nanos() const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (procs_ != nullptr && procs_->GetCurrentTime != nullptr) {
    return procs_->GetCurrentTime();
  }
  return steady_now_nanos();
}

bool EventLoop::runs_task_on_current_thread(void* user_data) {
  auto* self = static_cast<EventLoop*>(user_data);
  return self != nullptr && self->runs_on_loop_thread();
}

void EventLoop::post_task_callback(FlutterTask task,
                                   uint64_t target_time_nanos,
                                   void* user_data) {
  auto* self = static_cast<EventLoop*>(user_data);
  if (self != nullptr) {
    self->post_flutter_task(task, target_time_nanos);
  }
}

void EventLoop::wake() {
#if defined(__linux__)
  if (event_fd_ >= 0) {
    uint64_t value = 1;
    write(event_fd_, &value, sizeof(value));
  }
#endif
  cv_.notify_all();
}

void EventLoop::arm_timer_locked() {
#if defined(__linux__)
  if (timer_fd_ < 0) {
    return;
  }
  itimerspec spec{};
  const uint64_t target = next_target_locked();
  if (target != 0) {
    const uint64_t now = procs_ != nullptr && procs_->GetCurrentTime != nullptr
                             ? procs_->GetCurrentTime()
                             : steady_now_nanos();
    const uint64_t delta = target > now ? target - now : 1;
    spec.it_value.tv_sec = static_cast<time_t>(delta / 1000000000ull);
    spec.it_value.tv_nsec = static_cast<long>(delta % 1000000000ull);
  }
  timerfd_settime(timer_fd_, 0, &spec, nullptr);
#endif
}

bool EventLoop::pop_due_locked(uint64_t now_nanos_value, Pending* out) {
  auto it = std::min_element(
      pending_.begin(), pending_.end(), [](const Pending& a, const Pending& b) {
        if (a.target_time_nanos != b.target_time_nanos) {
          return a.target_time_nanos < b.target_time_nanos;
        }
        return a.sequence < b.sequence;
      });
  if (it == pending_.end() || it->target_time_nanos > now_nanos_value) {
    return false;
  }
  *out = std::move(*it);
  pending_.erase(it);
  return true;
}

uint64_t EventLoop::next_target_locked() const {
  if (pending_.empty()) {
    return 0;
  }
  return std::min_element(
             pending_.begin(), pending_.end(),
             [](const Pending& a, const Pending& b) {
               return a.target_time_nanos < b.target_time_nanos;
             })
      ->target_time_nanos;
}

}  // namespace pluto
