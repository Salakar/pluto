#include "presenter/swtcon/swtcon_rails.h"

#include <gtest/gtest.h>

#include <string>
#include <vector>

namespace {

class FakeRailsFs final : public pluto::swtcon::RailsFs {
 public:
  bool write_file(const std::string& path,
                  const std::string& value,
                  std::string*) override {
    writes.push_back({path, value});
    return true;
  }

  std::vector<pluto::swtcon::RailWrite> writes;
};

}  // namespace

TEST(SwtconRailsTest, DisabledByDefaultDoesNotWrite) {
  FakeRailsFs fs;
  std::vector<pluto::swtcon::RailWrite> dry_run_log;
  pluto::swtcon::SwtconRails::Config config;
  config.dry_run_log = &dry_run_log;

  EXPECT_EQ(pluto::swtcon::SwtconRails::apply(config, &fs, nullptr),
            kPlutoStatusOk);
  EXPECT_EQ(fs.writes.size(), static_cast<std::size_t>(0));
  EXPECT_EQ(dry_run_log.size(), static_cast<std::size_t>(0));
}

TEST(SwtconRailsTest, DryRunReportsKnownRailWritesWithoutTouchingFs) {
  FakeRailsFs fs;
  std::vector<pluto::swtcon::RailWrite> dry_run_log;
  pluto::swtcon::SwtconRails::Config config;
  config.enable = true;
  config.dry_run = true;
  config.panel_base = "/panel";
  config.regulator_base = "/reg";
  config.dry_run_log = &dry_run_log;

  EXPECT_EQ(pluto::swtcon::SwtconRails::apply(config, &fs, nullptr),
            kPlutoStatusOk);
  EXPECT_EQ(fs.writes.size(), static_cast<std::size_t>(0));
  ASSERT_EQ(dry_run_log.size(), static_cast<std::size_t>(8));
  EXPECT_EQ(dry_run_log[0].path, std::string("/panel/vpos1"));
  EXPECT_EQ(dry_run_log[0].value, std::string("6.0"));
  EXPECT_EQ(dry_run_log[5].path, std::string("/panel/vneg3"));
  EXPECT_EQ(dry_run_log[5].value, std::string("-6.0"));
  EXPECT_EQ(dry_run_log[6].path, std::string("/reg/vpdd_length"));
  EXPECT_EQ(dry_run_log[6].value, std::string("30000"));
  EXPECT_EQ(dry_run_log[7].path, std::string("/reg/enable_nowait"));
  EXPECT_EQ(dry_run_log[7].value, std::string("1"));
}
