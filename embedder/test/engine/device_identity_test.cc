#include "engine/device_identity.h"

#include <unistd.h>

#include <atomic>
#include <filesystem>
#include <fstream>
#include <string>

#include "generated/device_profiles.h"
#include "gtest/gtest.h"

namespace {

namespace fs = std::filesystem;

class TempIdentityTree {
public:
  TempIdentityTree() {
    static std::atomic<int> counter{0};
    root_ = fs::temp_directory_path() /
            ("pluto-device-identity-" + std::to_string(::getpid()) + "-" +
             std::to_string(counter.fetch_add(1)));
    fs::create_directories(root_);
  }

  ~TempIdentityTree() {
    std::error_code error;
    fs::remove_all(root_, error);
  }

  fs::path path(const char *name) const { return root_ / name; }

  void write(const char *name, const std::string &value) {
    std::ofstream output(path(name), std::ios::binary | std::ios::trunc);
    output.write(value.data(), static_cast<std::streamsize>(value.size()));
  }

private:
  fs::path root_;
};

TEST(DeviceIdentity, AcceptsEveryGeneratedConjunctiveIdentityFixture) {
  for (const pluto::GeneratedDeviceIdentityFixture &fixture :
       pluto::kGeneratedAcceptedDeviceIdentityFixtures) {
    const pluto::RemarkableDeviceIdentity identity =
        pluto::classify_remarkable_device_identity({
            .machine = std::string(fixture.machine),
            .device_tree_model = std::string(fixture.device_tree_model),
            .device_tree_compatible =
                std::string(fixture.device_tree_compatible),
            .architecture = std::string(fixture.architecture),
        });
    ASSERT_EQ(identity.profile_id, fixture.profile_id);
    const pluto::GeneratedDeviceProfile *profile =
        pluto::generated_device_profile_by_id(fixture.profile_id);
    ASSERT_NE(profile, nullptr);
    EXPECT_EQ(identity.model, profile->wire_model);
    EXPECT_EQ(identity.codename, profile->codename);
  }
}

TEST(DeviceIdentity, RejectsEveryGeneratedIncompleteOrConflictingFixture) {
  for (const pluto::GeneratedDeviceIdentityFixture &fixture :
       pluto::kGeneratedRejectedDeviceIdentityFixtures) {
    const pluto::RemarkableDeviceIdentity identity =
        pluto::classify_remarkable_device_identity({
            .machine = std::string(fixture.machine),
            .device_tree_model = std::string(fixture.device_tree_model),
            .device_tree_compatible =
                std::string(fixture.device_tree_compatible),
            .architecture = std::string(fixture.architecture),
        });
    EXPECT_TRUE(identity.profile_id.empty());
    EXPECT_EQ(identity.model, "unknown");
    EXPECT_TRUE(identity.codename.empty());
  }
}

TEST(DeviceIdentity, ProbeCombinesAllImmutableSourcesAndHandlesNulData) {
  TempIdentityTree tree;
  tree.write("machine", "reMarkable 2.0\n");
  tree.write("model", "reMarkable 2.n\n");
  std::string compatible = "fsl,imx7d-sdb";
  compatible.push_back('\0');
  compatible.append("fsl,imx7d");
  tree.write("compatible", compatible);

  const pluto::RemarkableDeviceIdentity identity =
      pluto::probe_remarkable_device_identity({
          .soc_machine = tree.path("machine").string(),
          .device_tree_model = tree.path("model").string(),
          .device_tree_compatible = tree.path("compatible").string(),
          .architecture_override = "armv7l",
      });

  EXPECT_EQ(identity.profile_id, "rm2");
  EXPECT_EQ(identity.model, "remarkable2");
  EXPECT_EQ(identity.codename, "zero-sugar");
}

TEST(DeviceIdentity, MissingIdentityFilesFailClosed) {
  TempIdentityTree tree;
  const pluto::RemarkableDeviceIdentity identity =
      pluto::probe_remarkable_device_identity({
          .soc_machine = tree.path("missing-machine").string(),
          .device_tree_model = tree.path("missing-model").string(),
          .device_tree_compatible = tree.path("missing-compatible").string(),
          .architecture_override = "armv7l",
      });

  EXPECT_TRUE(identity.profile_id.empty());
  EXPECT_EQ(identity.model, "unknown");
  EXPECT_TRUE(identity.codename.empty());
}

} // namespace
