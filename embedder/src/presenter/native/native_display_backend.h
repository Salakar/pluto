#ifndef PLUTO_PRESENTER_NATIVE_NATIVE_DISPLAY_BACKEND_H_
#define PLUTO_PRESENTER_NATIVE_NATIVE_DISPLAY_BACKEND_H_

#include <cstdint>
#include <memory>
#include <string_view>

#include "generated/device_profiles.h"
#include "pluto/presenter.h"

namespace pluto::native {

// Coarse health is intentionally backend-neutral. Driver-specific counters
// belong in diagnostics, while the common supervisor only needs to know
// whether work may continue, is temporarily backpressured, or must fail over
// to the tested recovery path.
enum class NativeBackendHealthState {
  kReady,
  kBusy,
  kDeviceLost,
};

struct NativeBackendHealth {
  NativeBackendHealthState state = NativeBackendHealthState::kReady;
  std::uint32_t queue_depth = 0;
  std::uint64_t completed_jobs = 0;
  std::uint64_t hardware_faults = 0;
};

// Hardware boundary behind the single public `native` presenter. The common
// compositor, frame ledger, scheduler, screenshot source, and lifecycle stay
// above this contract. Implementations may use kernel-managed updates (MXCFB)
// or userspace phase generation (LCDIF/Gallery 3), but they expose the same
// completion and failure semantics here.
class NativeDisplayBackend {
public:
  virtual ~NativeDisplayBackend() = default;

  virtual std::string_view driver_name() const = 0;

  // probe() is read-only and must validate the selected immutable profile and
  // live display contract before start() performs the first display write.
  virtual PlutoStatus probe(const GeneratedDeviceProfile &profile) = 0;
  virtual PlutoStatus start(const PlutoPresenterConfig &config) = 0;

  virtual PlutoStatus info(PlutoDisplayInfo *out_info) = 0;
  // submit() does not return until the backend has durably consumed every
  // borrowed damage pixel. Completion is nevertheless reported only at the
  // real hardware completion point through the configured callback.
  virtual PlutoStatus submit(const PlutoPresentRequest *request) = 0;
  virtual bool ready(PlutoRefreshClass refresh_class) = 0;
  virtual PlutoStatus wait_idle(std::uint32_t timeout_ms) = 0;
  virtual PlutoStatus snapshot(PlutoSurface *out_surface) = 0;
  virtual PlutoStatus set_pen_focus(const PlutoPenFocus *focus) = 0;

  virtual PlutoStatus stage_handoff(const PlutoHandoffPayload *payload,
                                    std::uint32_t timeout_ms) = 0;
  virtual PlutoStatus get_handoff(PlutoHandoffPayload *out_payload) = 0;
  virtual PlutoStatus confirm_handoff(bool accepted) = 0;

  // suspend() drains work and establishes the backend's documented safe
  // state. resume() must reopen and revalidate rather than reuse stale device
  // descriptors. Process-per-session backends may implement resume by asking
  // the supervisor for a clean restart.
  virtual PlutoStatus suspend(std::uint32_t timeout_ms) = 0;
  virtual PlutoStatus resume() = 0;
  virtual NativeBackendHealth health() const = 0;
  virtual void stop() = 0;
};

// The implementation factory is deliberately the only handwritten switch on
// DisplayDriverKind. Phase 1 admits Gallery 3 only; RM1 and RM2 fail closed
// here until their native backends pass their device gates.
std::unique_ptr<NativeDisplayBackend>
make_native_display_backend(const GeneratedDeviceProfile &profile,
                            PlutoStatus *out_status);

bool native_display_backend_is_implemented(
    const GeneratedDeviceProfile &profile);

} // namespace pluto::native

#endif // PLUTO_PRESENTER_NATIVE_NATIVE_DISPLAY_BACKEND_H_
