#include "ffi/dart_dl.h"

#include <atomic>
#include <chrono>

#include "dart/dart_api_dl.h"
#include "pluto/pen_ring.h"

namespace {

std::atomic<int64_t> g_wakeup_port{0};

void ring_wakeup(void*) {
  const int64_t port = g_wakeup_port.load(std::memory_order_acquire);
  if (port == 0 || Dart_PostCObject_DL == nullptr) {
    return;
  }
  Dart_CObject message{};
  message.type = Dart_CObject_kInt32;
  message.value.as_int32 = 1;
  Dart_PostCObject_DL(port, &message);
}

}  // namespace

extern "C" {

intptr_t pluto_dart_initialize_api_dl(void* data) {
  return Dart_InitializeApiDL(data);
}

void pluto_pen_ring_set_wakeup_port(int64_t dart_native_port) {
  g_wakeup_port.store(dart_native_port, std::memory_order_release);
  pluto_ring_set_wakeup(&ring_wakeup, nullptr);
}

int64_t pluto_engine_time_us(void) {
  using clock = std::chrono::steady_clock;
  return std::chrono::duration_cast<std::chrono::microseconds>(
             clock::now().time_since_epoch())
      .count();
}

}  // extern "C"
