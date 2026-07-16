#ifndef PLUTO_PRESENTER_NATIVE_RM2_CPU_FREQUENCY_LEASE_H_
#define PLUTO_PRESENTER_NATIVE_RM2_CPU_FREQUENCY_LEASE_H_

#include <cstddef>
#include <cstdint>
#include <string>

namespace pluto::native::rm2 {

inline constexpr char kRm2CpuPolicyPath[] =
    "/sys/devices/system/cpu/cpufreq/policy0";
inline constexpr char kRm2CpuReceiptPath[] = "/run/pluto/rm2-cpufreq-burst";
inline constexpr char kRm2CpuLockPath[] = "/run/pluto/rm2-cpufreq-burst.lock";
inline constexpr char kRm2CpuThermalTypePath[] =
    "/sys/devices/virtual/thermal/thermal_zone2/type";
inline constexpr char kRm2CpuTemperaturePath[] =
    "/sys/devices/virtual/thermal/thermal_zone2/temp";
inline constexpr int kRm2CpuTemperatureCutoffMillidegrees = 45'000;

struct Rm2CpuFrequencyLeasePaths {
  std::string policy_path;
  std::string receipt_path;
  std::string lock_path;
  std::string cpu_thermal_type_path;
  std::string cpu_temperature_path;
  // Host tests have no Linux /proc. Production always leaves this zero and
  // reads the exact owner start ticks from /proc/self/stat.
  std::uint64_t owner_start_ticks_for_testing = 0;
};

enum class Rm2CpuFrequencyAcquireOutcome : std::uint8_t {
  kAcquired,
  // The thermal identity and temperature were both valid, but the measured
  // CPU temperature was at or above the fixed cutoff. Callers may retry later.
  kThermalHold,
  // Sensor identity/readability, policy, ownership, receipt, or restore fault.
  // Callers must fail closed rather than treating this as thermal backpressure.
  kFault,
};

// Owns the shared RM2 CPU-frequency floor for a short waveform burst. The
// receipt is published before the floor changes and remains present until the
// original policy is restored and verified. The device supervisor consumes
// the same receipt contract after an unclean process exit.
class Rm2CpuFrequencyBurstLease final {
public:
  explicit Rm2CpuFrequencyBurstLease(Rm2CpuFrequencyLeasePaths paths = {});
  ~Rm2CpuFrequencyBurstLease();

  Rm2CpuFrequencyBurstLease(const Rm2CpuFrequencyBurstLease &) = delete;
  Rm2CpuFrequencyBurstLease &
  operator=(const Rm2CpuFrequencyBurstLease &) = delete;

  bool enabled() const noexcept { return !policy_path_.empty(); }
  bool active() const noexcept { return active_; }

  bool temperature_safe(int *out_millidegrees = nullptr,
                        std::string *error = nullptr) const;
  Rm2CpuFrequencyAcquireOutcome acquire(std::string *error = nullptr);
  bool release(std::string *error = nullptr) noexcept;

private:
  enum class TemperatureState : std::uint8_t {
    kSafe,
    kAtOrAboveCutoff,
    kUnavailable,
  };

  TemperatureState read_temperature(int *out_millidegrees,
                                    std::string *error) const;
  bool read_policy(std::uint64_t *out_minimum, std::uint64_t *out_maximum,
                   char *out_governor, std::size_t governor_capacity,
                   std::string *error) const;
  bool wait_for_policy(std::uint64_t expected_minimum,
                       std::uint64_t expected_maximum,
                       const char *expected_governor) const noexcept;
  bool write_minimum(std::uint64_t frequency_khz, std::string *error) const;
  bool publish_receipt(std::string *error);
  bool receipt_unchanged() const noexcept;
  void close_lock() noexcept;

  std::string policy_path_;
  std::string minimum_path_;
  std::string maximum_path_;
  std::string governor_path_;
  std::string related_cpus_path_;
  std::string receipt_path_;
  std::string lock_path_;
  std::string runtime_path_;
  std::string cpu_thermal_type_path_;
  std::string cpu_temperature_path_;
  int lock_fd_ = -1;
  std::uint64_t owner_start_ticks_ = 0;
  std::uint64_t original_minimum_khz_ = 0;
  std::uint64_t original_maximum_khz_ = 0;
  char original_governor_[64]{};
  char receipt_[512]{};
  std::size_t receipt_size_ = 0;
  std::uint64_t owner_start_ticks_for_testing_ = 0;
  bool active_ = false;
};

} // namespace pluto::native::rm2

#endif // PLUTO_PRESENTER_NATIVE_RM2_CPU_FREQUENCY_LEASE_H_
