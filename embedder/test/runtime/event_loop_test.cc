#include "runtime/event_loop.h"

#include <pthread.h>
#include <signal.h>

#include <atomic>
#include <chrono>
#include <thread>

#include "gtest/gtest.h"

namespace {

TEST(EventLoopTest, RoutesSighupToTheRuntimeSignalHandler) {
  pluto::EventLoop loop;
  std::atomic<int> received{0};
  std::atomic<int> send_result{-1};
  loop.set_signal_handler([&](int signal) {
    received.store(signal, std::memory_order_release);
    loop.stop();
  });

  const pthread_t event_loop_thread = pthread_self();
  std::thread sender([&] {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
    send_result.store(pthread_kill(event_loop_thread, SIGHUP),
                      std::memory_order_release);
    for (int attempt = 0;
         attempt < 100 && received.load(std::memory_order_acquire) == 0;
         ++attempt) {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    loop.stop();
  });
  loop.run();
  sender.join();

  EXPECT_EQ(send_result.load(std::memory_order_acquire), 0);
  EXPECT_EQ(received.load(std::memory_order_acquire), SIGHUP);
}

} // namespace
