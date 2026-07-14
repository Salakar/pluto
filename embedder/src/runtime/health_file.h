#ifndef PLUTO_RUNTIME_HEALTH_FILE_H_
#define PLUTO_RUNTIME_HEALTH_FILE_H_

#include <cstdint>
#include <string>

namespace pluto {

// Atomically publishes the supervisor-facing liveness record. The path is
// launch-nonce-specific, so the record deliberately carries only the process
// identity and renderer-loop progress needed by the supervisor.
class HealthFilePublisher {
public:
  explicit HealthFilePublisher(std::string path);

  HealthFilePublisher(const HealthFilePublisher &) = delete;
  HealthFilePublisher &operator=(const HealthFilePublisher &) = delete;

  // |monotonic_us| comes from the renderer's steady-clock health tick.
  // Sequence advances only after the atomic replacement succeeds.
  bool publish(uint64_t monotonic_us, int *error_code = nullptr);

  uint64_t sequence() const { return sequence_; }

private:
  std::string path_;
  uint64_t sequence_ = 0;
  uint64_t last_monotonic_ms_ = 0;
};

} // namespace pluto

#endif // PLUTO_RUNTIME_HEALTH_FILE_H_
