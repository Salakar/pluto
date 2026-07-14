#ifndef PLUTO_RUNTIME_EVENT_LOOP_H_
#define PLUTO_RUNTIME_EVENT_LOOP_H_

#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

#include "flutter/embedder.h"

namespace pluto {

class EventLoop {
 public:
  EventLoop();
  EventLoop(const EventLoop&) = delete;
  EventLoop& operator=(const EventLoop&) = delete;
  ~EventLoop();

  void set_engine(const FlutterEngineProcTable* procs, FlutterEngine engine);
  void set_signal_handler(std::function<void(int)> handler);
  FlutterTaskRunnerDescription* platform_task_runner() { return &runner_; }
  FlutterCustomTaskRunners* custom_task_runners() { return &custom_runners_; }

  void post_closure(std::function<void()> closure);
  void post_closure_at(uint64_t target_time_nanos,
                       std::function<void()> closure);
  void post_flutter_task(FlutterTask task, uint64_t target_time_nanos);

  void run();
  void stop();
  size_t run_due_tasks_for_test(uint64_t now_nanos);
  bool runs_on_loop_thread() const;

  uint64_t now_nanos() const;

 private:
  struct Pending {
    uint64_t target_time_nanos = 0;
    uint64_t sequence = 0;
    bool is_flutter_task = false;
    FlutterTask flutter_task{};
    std::function<void()> closure;
  };

  static bool runs_task_on_current_thread(void* user_data);
  static void post_task_callback(FlutterTask task,
                                 uint64_t target_time_nanos,
                                 void* user_data);

  void wake();
  void arm_timer_locked();
  bool pop_due_locked(uint64_t now_nanos, Pending* out);
  uint64_t next_target_locked() const;

  const FlutterEngineProcTable* procs_ = nullptr;
  FlutterEngine engine_ = nullptr;
  FlutterTaskRunnerDescription runner_{};
  FlutterCustomTaskRunners custom_runners_{};
  std::thread::id loop_thread_;
  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::vector<Pending> pending_;
  bool stopping_ = false;
  std::function<void(int)> signal_handler_;
  uint64_t next_sequence_ = 1;

#if defined(__linux__)
  int epoll_fd_ = -1;
  int event_fd_ = -1;
  int timer_fd_ = -1;
  int signal_fd_ = -1;
#endif
};

}  // namespace pluto

#endif  // PLUTO_RUNTIME_EVENT_LOOP_H_
