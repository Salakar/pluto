#ifndef PLUTO_ENGINE_PEN_POINTER_TIMESTAMP_H_
#define PLUTO_ENGINE_PEN_POINTER_TIMESTAMP_H_

#include <cstddef>
#include <cstdint>

namespace pluto {

// FlutterPointerEvent requires microseconds in the same monotonic clock domain
// as FlutterEngineGetCurrentTime. Pen evdev is configured with
// EVIOCSCLOCKID(CLOCK_MONOTONIC), so retain the kernel sample time instead of
// replacing buffered samples with their later dispatch time. The zero clamp is
// only a defensive guard for synthetic/invalid test input; real evdev times are
// non-negative.
constexpr std::size_t flutter_pen_pointer_timestamp_us(
    std::int64_t kernel_monotonic_us) {
  return kernel_monotonic_us > 0
             ? static_cast<std::size_t>(kernel_monotonic_us)
             : std::size_t{0};
}

}  // namespace pluto

#endif  // PLUTO_ENGINE_PEN_POINTER_TIMESTAMP_H_
