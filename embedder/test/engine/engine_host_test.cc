#include "engine/engine_host.h"
#include "engine/pen_pointer_timestamp.h"

#include <unistd.h>

#include <filesystem>
#include <fstream>
#include <string>
#include <utility>

#include "gtest/gtest.h"

namespace {

class TempBundle {
 public:
  explicit TempBundle(const char* suffix)
      : path_(std::filesystem::temp_directory_path() /
              ("pluto-engine-host-" + std::to_string(::getpid()) + "-" +
               suffix)) {
    std::filesystem::remove_all(path_);
    std::filesystem::create_directories(path_ / "flutter_assets");
  }

  ~TempBundle() { std::filesystem::remove_all(path_); }

  const std::filesystem::path& path() const { return path_; }

  void touch(const std::filesystem::path& relative_path) {
    std::filesystem::create_directories((path_ / relative_path).parent_path());
    std::ofstream(path_ / relative_path).put('\0');
  }

 private:
  std::filesystem::path path_;
};

pluto::EngineHost make_host(const std::filesystem::path& bundle) {
  pluto::EngineHostConfig config;
  config.bundle_path = bundle.string();
  config.engine_path = "/definitely/missing/libflutter_engine.so";
  return pluto::EngineHost(std::move(config));
}

TEST(EngineHostConfig, DefaultsToReleaseAot) {
  const pluto::EngineHostConfig config;
  EXPECT_EQ(static_cast<int>(config.mode),
            static_cast<int>(pluto::EngineMode::kRelease));
  EXPECT_TRUE(config.ready_file_path.empty());
  EXPECT_TRUE(config.health_file_path.empty());
  EXPECT_FALSE(config.dpr_explicitly_set);
}

TEST(EngineHostGeometry, AdoptsLegacyPresenterBeforeWindowMetrics) {
  pluto::EngineHostConfig config;
  PlutoDisplayInfo info{};
  info.struct_size = sizeof(info);
  info.width = 1404;
  info.height = 1872;
  info.dpi = 226;
  std::string error;

  ASSERT_TRUE(pluto::apply_presenter_display_info(info, &config, &error))
      << error;
  EXPECT_EQ(config.panel_width, 1404);
  EXPECT_EQ(config.panel_height, 1872);
  EXPECT_EQ(config.dpi, 226);
  EXPECT_NEAR(config.dpr, 226.0 / 160.0, 1e-12);

  const FlutterWindowMetricsEvent metrics =
      pluto::window_metrics_for_config(config);
  EXPECT_EQ(metrics.width, static_cast<size_t>(1404));
  EXPECT_EQ(metrics.height, static_cast<size_t>(1872));
  EXPECT_NEAR(metrics.pixel_ratio, 226.0 / 160.0, 1e-12);
}

TEST(EngineHostGeometry, WindowMetricsFollowRotationAfterAdoption) {
  pluto::EngineHostConfig config;
  config.rotation = 90;
  PlutoDisplayInfo info{};
  info.struct_size = sizeof(info);
  info.width = 1404;
  info.height = 1872;
  info.dpi = 226;

  ASSERT_TRUE(pluto::apply_presenter_display_info(info, &config, nullptr));
  const FlutterWindowMetricsEvent metrics =
      pluto::window_metrics_for_config(config);
  EXPECT_EQ(metrics.width, static_cast<size_t>(1872));
  EXPECT_EQ(metrics.height, static_cast<size_t>(1404));
  EXPECT_NEAR(metrics.pixel_ratio, 226.0 / 160.0, 1e-12);
}

TEST(EngineHostGeometry, PreservesExplicitDprOverride) {
  pluto::EngineHostConfig config;
  config.dpr = 1.25;
  config.dpr_explicitly_set = true;
  PlutoDisplayInfo info{};
  info.struct_size = sizeof(info);
  info.width = 1404;
  info.height = 1872;
  info.dpi = 226;

  ASSERT_TRUE(pluto::apply_presenter_display_info(info, &config, nullptr));
  EXPECT_NEAR(config.dpr, 1.25, 1e-12);
}

TEST(EngineHostGeometry, InvalidPresenterGeometryFailsWithoutMutation) {
  pluto::EngineHostConfig config;
  const int32_t original_width = config.panel_width;
  const int32_t original_height = config.panel_height;
  const int32_t original_dpi = config.dpi;
  const double original_dpr = config.dpr;
  PlutoDisplayInfo info{};
  info.struct_size = sizeof(info);
  info.width = 0;
  info.height = 1872;
  info.dpi = 226;
  std::string error;

  EXPECT_FALSE(pluto::apply_presenter_display_info(info, &config, &error));
  EXPECT_NE(error.find("invalid display geometry"), std::string::npos);
  EXPECT_EQ(config.panel_width, original_width);
  EXPECT_EQ(config.panel_height, original_height);
  EXPECT_EQ(config.dpi, original_dpi);
  EXPECT_NEAR(config.dpr, original_dpr, 1e-12);
}

TEST(EngineHostPenInput, PreservesEachKernelMonotonicTimestamp) {
  // Buffered SYN frames may be dispatched together much later. Their original
  // spacing must survive so Flutter/Dart velocity filters see the digitizer's
  // sample cadence rather than near-identical dispatch times.
  constexpr int64_t first_sample_us = 12'345'000;
  constexpr int64_t second_sample_us = 12'349'250;

  EXPECT_EQ(pluto::flutter_pen_pointer_timestamp_us(first_sample_us),
            static_cast<size_t>(first_sample_us));
  EXPECT_EQ(pluto::flutter_pen_pointer_timestamp_us(second_sample_us),
            static_cast<size_t>(second_sample_us));
  EXPECT_EQ(pluto::flutter_pen_pointer_timestamp_us(second_sample_us) -
                pluto::flutter_pen_pointer_timestamp_us(first_sample_us),
            4250u);
}

TEST(EngineHostPenInput, InvalidNegativeTimestampDoesNotWrap) {
  EXPECT_EQ(pluto::flutter_pen_pointer_timestamp_us(-1), 0u);
  EXPECT_EQ(pluto::flutter_pen_pointer_timestamp_us(0), 0u);
}

TEST(EngineHostConfig, RejectsRelativeReadyFileBeforeStartup) {
  pluto::EngineHostConfig config;
  config.ready_file_path = "relative/ready";
  pluto::EngineHost host(std::move(config));
  std::string error;

  EXPECT_FALSE(host.initialize(&error));
  EXPECT_EQ(error,
            "startup configuration failed: --ready-file must be an absolute "
            "path");
}

TEST(EngineHostConfig, RejectsRelativeHealthFileBeforeStartup) {
  pluto::EngineHostConfig config;
  config.health_file_path = "relative/health";
  pluto::EngineHost host(std::move(config));
  std::string error;

  EXPECT_FALSE(host.initialize(&error));
  EXPECT_EQ(error,
            "startup configuration failed: --health-file must be an absolute "
            "path");
}

TEST(EngineHostPaths, PrefersCanonicalAotElf) {
  TempBundle bundle("canonical");
  bundle.touch("lib/app.so");
  bundle.touch("app.so");
  auto host = make_host(bundle.path());
  std::string error;

  EXPECT_FALSE(host.initialize(&error));
  EXPECT_EQ(host.config().aot_elf_path,
            (bundle.path() / "lib/app.so").string());
}

TEST(EngineHostPaths, AcceptsLegacyAotElfWhenCanonicalIsAbsent) {
  TempBundle bundle("legacy");
  bundle.touch("app.so");
  auto host = make_host(bundle.path());
  std::string error;

  EXPECT_FALSE(host.initialize(&error));
  EXPECT_EQ(host.config().aot_elf_path, (bundle.path() / "app.so").string());
}

TEST(EngineHostPaths, MissingAotElfDefaultsToCanonicalLayout) {
  TempBundle bundle("missing");
  auto host = make_host(bundle.path());
  std::string error;

  EXPECT_FALSE(host.initialize(&error));
  EXPECT_EQ(host.config().aot_elf_path,
            (bundle.path() / "lib/app.so").string());
}

}  // namespace
