#include "engine/device_identity.h"

#include <unistd.h>

#include <atomic>
#include <filesystem>
#include <fstream>
#include <string>

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

  fs::path path(const char* name) const { return root_ / name; }

  void write(const char* name, const std::string& value) {
    std::ofstream output(path(name), std::ios::binary | std::ios::trunc);
    output.write(value.data(), static_cast<std::streamsize>(value.size()));
  }

 private:
  fs::path root_;
};

TEST(DeviceIdentity, MapsKnownImmutableHardwareNamesToWireModels) {
  struct Fixture {
    const char* identity;
    const char* model;
    const char* codename;
  };
  const Fixture fixtures[] = {
      {"reMarkable 1.0", "remarkable1", "zero-gravitas"},
      {"fsl,imx6sl", "remarkable1", "zero-gravitas"},
      {"reMarkable 2.0", "remarkable2", "zero-sugar"},
      {"imx93-chiappa", "paperProMove", "chiappa"},
      {"imx8mm-ferrari", "paperPro", "ferrari"},
      {"reMarkable,tatsu", "paperPure", "tatsu"},
  };

  for (const Fixture& fixture : fixtures) {
    const pluto::RemarkableDeviceIdentity identity =
        pluto::classify_remarkable_device_identity(fixture.identity);
    EXPECT_EQ(identity.model, fixture.model) << fixture.identity;
    EXPECT_EQ(identity.codename, fixture.codename) << fixture.identity;
  }
}

TEST(DeviceIdentity, UnknownHardwareFailsClosed) {
  const pluto::RemarkableDeviceIdentity identity =
      pluto::classify_remarkable_device_identity("unrecognized tablet");
  EXPECT_EQ(identity.model, "unknown");
  EXPECT_TRUE(identity.codename.empty());
}

TEST(DeviceIdentity, ConflictingImmutableEvidenceFailsClosed) {
  const pluto::RemarkableDeviceIdentity identity =
      pluto::classify_remarkable_device_identity(
          "imx93-chiappa remarkable 2.0");
  EXPECT_EQ(identity.model, "unknown");
  EXPECT_TRUE(identity.codename.empty());
}

TEST(DeviceIdentity, ProbeCombinesAllImmutableSourcesAndHandlesNulData) {
  TempIdentityTree tree;
  tree.write("machine", "generic i.MX7 board\n");
  tree.write("model", "reMarkable tablet\n");
  std::string compatible = "fsl,imx7d-sdb";
  compatible.push_back('\0');
  compatible.append("fsl,imx7d");
  tree.write("compatible", compatible);

  const pluto::RemarkableDeviceIdentity identity =
      pluto::probe_remarkable_device_identity({
          .soc_machine = tree.path("machine").string(),
          .device_tree_model = tree.path("model").string(),
          .device_tree_compatible = tree.path("compatible").string(),
      });

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
      });

  EXPECT_EQ(identity.model, "unknown");
  EXPECT_TRUE(identity.codename.empty());
}

}  // namespace
