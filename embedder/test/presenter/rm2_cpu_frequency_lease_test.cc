#include "presenter/native/rm2/rm2_cpu_frequency_lease.h"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>

#include <sys/stat.h>
#include <unistd.h>

#include <gtest/gtest.h>

namespace pluto::native::rm2 {
namespace {

class TemporaryPolicy final {
public:
  TemporaryPolicy() {
    std::string pattern =
        (std::filesystem::temp_directory_path() / "pluto-rm2-cpufreq-XXXXXX")
            .string();
    char *created = ::mkdtemp(pattern.data());
    if (created == nullptr) {
      return;
    }
    root_ = created;
    policy_ = root_ / "policy0";
    runtime_ = root_ / "run";
    std::filesystem::create_directories(policy_);
    std::filesystem::create_directories(runtime_);
    write("related_cpus", "0 1\n");
    write("scaling_min_freq", "792000\n");
    write("scaling_max_freq", "1200000\n");
    write("scaling_governor", "ondemand\n");
    write("thermal_type", "imx_thermal_zone\n");
    write("cpu_temperature", "33000\n");
  }

  ~TemporaryPolicy() {
    std::error_code error;
    std::filesystem::remove_all(root_, error);
  }

  bool valid() const { return !root_.empty(); }

  Rm2CpuFrequencyLeasePaths paths() const {
    return {
        .policy_path = policy_.string(),
        .receipt_path = (runtime_ / "rm2-cpufreq-burst").string(),
        .lock_path = (runtime_ / "rm2-cpufreq-burst.lock").string(),
        .cpu_thermal_type_path = (policy_ / "thermal_type").string(),
        .cpu_temperature_path = (policy_ / "cpu_temperature").string(),
        .owner_start_ticks_for_testing = 12345,
    };
  }

  void write(std::string_view name, std::string_view value) const {
    std::ofstream output(policy_ / name, std::ios::binary | std::ios::trunc);
    output.write(value.data(), static_cast<std::streamsize>(value.size()));
  }

  std::string read(std::string_view name) const {
    std::ifstream input(policy_ / name, std::ios::binary);
    return {std::istreambuf_iterator<char>(input),
            std::istreambuf_iterator<char>()};
  }

  std::string receipt() const {
    std::ifstream input(paths().receipt_path, std::ios::binary);
    return {std::istreambuf_iterator<char>(input),
            std::istreambuf_iterator<char>()};
  }

private:
  std::filesystem::path root_;
  std::filesystem::path policy_;
  std::filesystem::path runtime_;
};

TEST(Rm2CpuFrequencyBurstLease, DisabledLeaseIsAnAllocationFreeNoOp) {
  Rm2CpuFrequencyBurstLease lease;
  EXPECT_FALSE(lease.enabled());
  EXPECT_TRUE(lease.acquire() == Rm2CpuFrequencyAcquireOutcome::kAcquired);
  EXPECT_FALSE(lease.active());
  EXPECT_TRUE(lease.release());
}

TEST(Rm2CpuFrequencyBurstLease,
     PublishesStrictOwnerReceiptRaisesAndRestoresExactPolicy) {
  TemporaryPolicy fixture;
  ASSERT_TRUE(fixture.valid());
  const auto paths = fixture.paths();
  Rm2CpuFrequencyBurstLease lease(paths);

  std::string error;
  ASSERT_TRUE(lease.acquire(&error) == Rm2CpuFrequencyAcquireOutcome::kAcquired)
      << error;
  EXPECT_TRUE(lease.active());
  EXPECT_EQ(fixture.read("scaling_min_freq"), "1200000\n");
  const std::string receipt = fixture.receipt();
  EXPECT_TRUE(
      receipt.starts_with("policy=" + paths.policy_path + "\nowner_pid="));
  EXPECT_NE(receipt.find("\nowner_start_ticks="), std::string::npos);
  EXPECT_TRUE(
      receipt.ends_with("\noriginal_min_khz=792000\noriginal_max_khz=1200000\n"
                        "original_governor=ondemand\n"));

  ASSERT_TRUE(lease.release(&error)) << error;
  EXPECT_FALSE(lease.active());
  EXPECT_EQ(fixture.read("scaling_min_freq"), "792000\n");
  EXPECT_EQ(fixture.read("scaling_max_freq"), "1200000\n");
  EXPECT_EQ(fixture.read("scaling_governor"), "ondemand\n");
  EXPECT_FALSE(std::filesystem::exists(paths.receipt_path));
}

TEST(Rm2CpuFrequencyBurstLease, SerializesOwnersAndRefusesExistingReceipt) {
  TemporaryPolicy fixture;
  ASSERT_TRUE(fixture.valid());
  const auto paths = fixture.paths();
  Rm2CpuFrequencyBurstLease first(paths);
  Rm2CpuFrequencyBurstLease second(paths);
  ASSERT_TRUE(first.acquire() == Rm2CpuFrequencyAcquireOutcome::kAcquired);
  EXPECT_TRUE(second.acquire() == Rm2CpuFrequencyAcquireOutcome::kFault);
  ASSERT_TRUE(first.release());
  ASSERT_TRUE(second.acquire() == Rm2CpuFrequencyAcquireOutcome::kAcquired);
  ASSERT_TRUE(second.release());

  {
    std::ofstream receipt(paths.receipt_path,
                          std::ios::binary | std::ios::trunc);
    receipt << "unowned\n";
  }
  Rm2CpuFrequencyBurstLease blocked(paths);
  EXPECT_TRUE(blocked.acquire() == Rm2CpuFrequencyAcquireOutcome::kFault);
  EXPECT_EQ(fixture.read("scaling_min_freq"), "792000\n");
}

TEST(Rm2CpuFrequencyBurstLease,
     PolicyMutationKeepsReceiptAndCanRetryExactRestore) {
  TemporaryPolicy fixture;
  ASSERT_TRUE(fixture.valid());
  const auto paths = fixture.paths();
  Rm2CpuFrequencyBurstLease lease(paths);
  ASSERT_TRUE(lease.acquire() == Rm2CpuFrequencyAcquireOutcome::kAcquired);

  fixture.write("scaling_governor", "performance\n");
  EXPECT_FALSE(lease.release());
  EXPECT_TRUE(lease.active());
  EXPECT_TRUE(std::filesystem::exists(paths.receipt_path));
  EXPECT_EQ(fixture.read("scaling_min_freq"), "792000\n");

  fixture.write("scaling_governor", "ondemand\n");
  EXPECT_TRUE(lease.release());
  EXPECT_FALSE(std::filesystem::exists(paths.receipt_path));
}

TEST(Rm2CpuFrequencyBurstLease,
     ReleaseWaitsForTransientPolicyReadbackToSettle) {
  TemporaryPolicy fixture;
  ASSERT_TRUE(fixture.valid());
  const auto paths = fixture.paths();
  Rm2CpuFrequencyBurstLease lease(paths);
  ASSERT_TRUE(lease.acquire() == Rm2CpuFrequencyAcquireOutcome::kAcquired);

  fixture.write("scaling_governor", "performance\n");
  std::thread settle([&fixture] {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
    fixture.write("scaling_governor", "ondemand\n");
  });
  const bool released = lease.release();
  settle.join();

  EXPECT_TRUE(released);
  EXPECT_FALSE(lease.active());
  EXPECT_EQ(fixture.read("scaling_min_freq"), "792000\n");
  EXPECT_FALSE(std::filesystem::exists(paths.receipt_path));
}

TEST(Rm2CpuFrequencyBurstLease, RejectsNonRm2PolicyIdentityBeforeReceipt) {
  TemporaryPolicy fixture;
  ASSERT_TRUE(fixture.valid());
  const auto paths = fixture.paths();
  fixture.write("scaling_max_freq", "996000\n");
  Rm2CpuFrequencyBurstLease lease(paths);
  EXPECT_TRUE(lease.acquire() == Rm2CpuFrequencyAcquireOutcome::kFault);
  EXPECT_FALSE(std::filesystem::exists(paths.receipt_path));
  EXPECT_EQ(fixture.read("scaling_min_freq"), "792000\n");
}

TEST(Rm2CpuFrequencyBurstLease, RejectsWritableReceiptDirectory) {
  TemporaryPolicy fixture;
  ASSERT_TRUE(fixture.valid());
  const auto paths = fixture.paths();
  ASSERT_EQ(
      ::chmod(std::filesystem::path(paths.receipt_path).parent_path().c_str(),
              0777),
      0);
  Rm2CpuFrequencyBurstLease lease(paths);
  EXPECT_TRUE(lease.acquire() == Rm2CpuFrequencyAcquireOutcome::kFault);
  EXPECT_FALSE(std::filesystem::exists(paths.receipt_path));
  EXPECT_EQ(fixture.read("scaling_min_freq"), "792000\n");
}

TEST(Rm2CpuFrequencyBurstLease, HoldsAt45CAndRestoresAnActiveBurst) {
  TemporaryPolicy fixture;
  ASSERT_TRUE(fixture.valid());
  const auto paths = fixture.paths();
  Rm2CpuFrequencyBurstLease lease(paths);
  ASSERT_TRUE(lease.acquire() == Rm2CpuFrequencyAcquireOutcome::kAcquired);
  ASSERT_TRUE(lease.active());
  fixture.write("cpu_temperature", "45000\n");
  std::string error;
  EXPECT_TRUE(lease.acquire(&error) ==
              Rm2CpuFrequencyAcquireOutcome::kThermalHold);
  EXPECT_NE(error.find("45000 mC"), std::string::npos);
  EXPECT_FALSE(lease.active());
  EXPECT_EQ(fixture.read("scaling_min_freq"), "792000\n");
  EXPECT_FALSE(std::filesystem::exists(paths.receipt_path));
}

TEST(Rm2CpuFrequencyBurstLease, UnavailableTemperatureRemainsAFault) {
  TemporaryPolicy fixture;
  ASSERT_TRUE(fixture.valid());
  const auto paths = fixture.paths();
  fixture.write("cpu_temperature", "unavailable\n");
  Rm2CpuFrequencyBurstLease lease(paths);

  std::string error;
  EXPECT_TRUE(lease.acquire(&error) == Rm2CpuFrequencyAcquireOutcome::kFault);
  EXPECT_NE(error.find("unavailable or malformed"), std::string::npos);
  EXPECT_FALSE(lease.active());
  EXPECT_EQ(fixture.read("scaling_min_freq"), "792000\n");
  EXPECT_FALSE(std::filesystem::exists(paths.receipt_path));
}

TEST(Rm2CpuFrequencyBurstLease, DestructorRestoresAnOwnedBurst) {
  TemporaryPolicy fixture;
  ASSERT_TRUE(fixture.valid());
  const auto paths = fixture.paths();
  {
    Rm2CpuFrequencyBurstLease lease(paths);
    ASSERT_TRUE(lease.acquire() == Rm2CpuFrequencyAcquireOutcome::kAcquired);
    ASSERT_TRUE(lease.active());
  }
  EXPECT_EQ(fixture.read("scaling_min_freq"), "792000\n");
  EXPECT_FALSE(std::filesystem::exists(paths.receipt_path));
}

} // namespace
} // namespace pluto::native::rm2
