#ifndef PLUTO_PRESENTER_NATIVE_SCANOUT_TRANSPORT_H_
#define PLUTO_PRESENTER_NATIVE_SCANOUT_TRANSPORT_H_

#include <cstddef>
#include <cstdint>
#include <span>

#include "pluto/presenter.h"

namespace pluto::native {

struct ScanoutSlot {
  std::uint32_t index = 0;
  std::span<std::uint8_t> bytes;
  std::size_t stride_bytes = 0;
};

// Device-neutral slot ownership and latch contract for userspace-TCON paths.
// Implementations own DRM versus fbdev pan details and must never return a
// writable slot that is still in flight on hardware.
class ScanoutTransport {
public:
  virtual ~ScanoutTransport() = default;

  virtual PlutoStatus start() = 0;
  virtual PlutoStatus acquire(ScanoutSlot *out_slot) = 0;
  virtual PlutoStatus latch(const ScanoutSlot &slot,
                            std::uint64_t phase_sequence) = 0;
  virtual PlutoStatus wait_latched(std::uint64_t phase_sequence,
                                   std::uint32_t timeout_ms) = 0;
  virtual PlutoStatus arm_safe_hold(std::uint32_t timeout_ms) = 0;
  virtual PlutoStatus suspend(std::uint32_t timeout_ms) = 0;
  virtual PlutoStatus resume() = 0;
  virtual void stop() = 0;
};

} // namespace pluto::native

#endif // PLUTO_PRESENTER_NATIVE_SCANOUT_TRANSPORT_H_
