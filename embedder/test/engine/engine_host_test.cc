#include "engine/engine_host.h"
#include "engine/pen_pointer_timestamp.h"

#include <unistd.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <initializer_list>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "gtest/gtest.h"

namespace {

class TempBundle {
public:
  explicit TempBundle(const char *suffix)
      : path_(std::filesystem::temp_directory_path() /
              ("pluto-engine-host-" + std::to_string(::getpid()) + "-" +
               suffix)) {
    std::filesystem::remove_all(path_);
    std::filesystem::create_directories(path_ / "flutter_assets");
  }

  ~TempBundle() { std::filesystem::remove_all(path_); }

  const std::filesystem::path &path() const { return path_; }

  void touch(const std::filesystem::path &relative_path) {
    std::filesystem::create_directories((path_ / relative_path).parent_path());
    std::ofstream(path_ / relative_path).put('\0');
  }

private:
  std::filesystem::path path_;
};

pluto::EngineHost make_host(const std::filesystem::path &bundle) {
  pluto::EngineHostConfig config;
  config.bundle_path = bundle.string();
  config.engine_path = "/definitely/missing/libflutter_engine.so";
  return pluto::EngineHost(std::move(config));
}

struct SemanticsSpec {
  std::int32_t id;
  std::string label;
  bool tappable = true;
};

void publish_semantics(pluto::DirectInkSemanticsState *state,
                       std::initializer_list<SemanticsSpec> specs,
                       FlutterViewId view_id = 0) {
  std::vector<SemanticsSpec> stable(specs);
  std::vector<FlutterSemanticsNode2> nodes(stable.size());
  std::vector<FlutterSemanticsNode2 *> node_ptrs;
  node_ptrs.reserve(nodes.size());
  for (std::size_t index = 0; index < stable.size(); ++index) {
    nodes[index].struct_size = sizeof(FlutterSemanticsNode2);
    nodes[index].id = stable[index].id;
    nodes[index].label = stable[index].label.c_str();
    nodes[index].actions = stable[index].tappable
                               ? kFlutterSemanticsActionTap
                               : static_cast<FlutterSemanticsAction>(0);
    node_ptrs.push_back(&nodes[index]);
  }
  FlutterSemanticsUpdate2 update{};
  update.struct_size = sizeof(update);
  update.node_count = node_ptrs.size();
  update.nodes = node_ptrs.empty() ? nullptr : node_ptrs.data();
  update.view_id = view_id;
  state->update(&update);
}

TEST(EngineHostConfig, DefaultsToReleaseAot) {
  const pluto::EngineHostConfig config;
  EXPECT_EQ(static_cast<int>(config.mode),
            static_cast<int>(pluto::EngineMode::kRelease));
  EXPECT_TRUE(config.ready_file_path.empty());
  EXPECT_TRUE(config.health_file_path.empty());
  EXPECT_FALSE(config.dpr_explicitly_set);
}

TEST(EngineHostGeometry, AdoptsPresenterBeforeWindowMetrics) {
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

TEST(EngineHostGeometry, RejectsNonCurrentDisplayInfoLayouts) {
  pluto::EngineHostConfig config;
  PlutoDisplayInfo info{};
  info.width = 1404;
  info.height = 1872;
  info.dpi = 226;
  std::string error;

  info.struct_size = sizeof(info) - 1u;
  EXPECT_FALSE(pluto::apply_presenter_display_info(info, &config, &error));
  EXPECT_NE(error.find("non-current display info layout"), std::string::npos);
  info.struct_size = sizeof(info) + 1u;
  EXPECT_FALSE(pluto::apply_presenter_display_info(info, &config, &error));
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

TEST(DirectInkSemanticsState, AcceptsOnlyExactTappableInkControls) {
  using enum pluto::DirectInkSemanticsTarget;
  pluto::DirectInkSemanticsState state;

  publish_semantics(&state, {{1, "new artwork"}});
  const std::uint64_t boundary = state.begin();
  publish_semantics(&state, {{2, "new artwork", false},
                             {3, "new artwork copy"},
                             {4, "Create"},
                             {5, "Back to gallery later"}});
  constexpr std::array targets{kCanvasReady, kCreate, kNewArtwork};
  pluto::DirectInkSemanticsTarget matched{};
  pluto::DirectInkSemanticsNode node;
  EXPECT_EQ(static_cast<int>(state.wait_for_any(targets, boundary,
                                                std::chrono::milliseconds(1),
                                                &matched, &node)),
            static_cast<int>(pluto::DirectInkSemanticsWait::kTimedOut));

  publish_semantics(&state, {{12, "new artwork"}}, 77);
  EXPECT_EQ(static_cast<int>(state.wait_for_any(targets, boundary,
                                                std::chrono::milliseconds(1),
                                                &matched, &node)),
            static_cast<int>(pluto::DirectInkSemanticsWait::kFound));
  EXPECT_EQ(static_cast<int>(matched), static_cast<int>(kNewArtwork));
  EXPECT_EQ(node.node_id, 12u);
  EXPECT_EQ(node.view_id, 77);
  EXPECT_GT(node.generation, boundary);
  state.end();
}

TEST(DirectInkSemanticsState, GenerationBoundaryRejectsStaleControls) {
  using enum pluto::DirectInkSemanticsTarget;
  pluto::DirectInkSemanticsState state;
  state.begin();
  publish_semantics(&state, {{20, "create"}});
  const std::uint64_t boundary = state.generation();
  constexpr std::array target{kCreate};
  pluto::DirectInkSemanticsTarget matched{};
  pluto::DirectInkSemanticsNode node;
  EXPECT_EQ(static_cast<int>(state.wait_for_any(target, boundary,
                                                std::chrono::milliseconds(1),
                                                &matched, &node)),
            static_cast<int>(pluto::DirectInkSemanticsWait::kTimedOut));
  publish_semantics(&state, {{21, "unrelated"}});
  EXPECT_EQ(static_cast<int>(state.wait_for_any(target, boundary,
                                                std::chrono::milliseconds(1),
                                                &matched, &node)),
            static_cast<int>(pluto::DirectInkSemanticsWait::kTimedOut));
  publish_semantics(&state, {{22, "create"}});
  EXPECT_EQ(static_cast<int>(state.wait_for_any(target, boundary,
                                                std::chrono::milliseconds(1),
                                                &matched, &node)),
            static_cast<int>(pluto::DirectInkSemanticsWait::kFound));
  EXPECT_EQ(node.node_id, 22u);
  state.end();
  EXPECT_EQ(static_cast<int>(state.wait_for_any(
                target, 0, std::chrono::milliseconds(1), &matched, &node)),
            static_cast<int>(pluto::DirectInkSemanticsWait::kInactive));
}

TEST(DirectInkSemanticsState, DuplicateExactActionFailsClosed) {
  using enum pluto::DirectInkSemanticsTarget;
  pluto::DirectInkSemanticsState state;
  const std::uint64_t boundary = state.begin();
  publish_semantics(&state, {{30, "new artwork"}, {31, "new artwork"}});
  constexpr std::array target{kNewArtwork};
  pluto::DirectInkSemanticsTarget matched{};
  pluto::DirectInkSemanticsNode node;
  EXPECT_EQ(static_cast<int>(state.wait_for_any(target, boundary,
                                                std::chrono::milliseconds(1),
                                                &matched, &node)),
            static_cast<int>(pluto::DirectInkSemanticsWait::kAmbiguous));
  state.end();
}

TEST(DirectInkSemanticsState, PlatformThreadUpdateWakesControlWaiter) {
  using enum pluto::DirectInkSemanticsTarget;
  pluto::DirectInkSemanticsState state;
  const std::uint64_t boundary = state.begin();
  constexpr std::array target{kCanvasReady};
  std::thread platform_thread(
      [&state] { publish_semantics(&state, {{35, "Back to gallery"}}, 5); });
  pluto::DirectInkSemanticsTarget matched{};
  pluto::DirectInkSemanticsNode node;
  const pluto::DirectInkSemanticsWait wait = state.wait_for_any(
      target, boundary, std::chrono::milliseconds(50), &matched, &node);
  platform_thread.join();
  EXPECT_EQ(static_cast<int>(wait),
            static_cast<int>(pluto::DirectInkSemanticsWait::kFound));
  EXPECT_EQ(node.node_id, 35u);
  EXPECT_EQ(node.view_id, 5);
  state.end();
}

TEST(DirectInkCanvasPreparation,
     CreatesThroughExactControlsAndConfirmsMountedEditor) {
  pluto::DirectInkSemanticsState state;
  std::vector<bool> toggles;
  std::vector<std::uint64_t> taps;
  const pluto::DirectInkSemanticsToggle toggle = [&](bool enabled) {
    toggles.push_back(enabled);
    if (enabled) {
      publish_semantics(&state, {{40, "new artwork"}}, 9);
    }
    return true;
  };
  const pluto::DirectInkSemanticsTap tap =
      [&](const pluto::DirectInkSemanticsNode &node) {
        taps.push_back(node.node_id);
        if (node.node_id == 40) {
          publish_semantics(&state, {{41, "new artwork"}, {42, "create"}}, 9);
          return true;
        }
        if (node.node_id == 42) {
          publish_semantics(&state, {{43, "Back to gallery"}}, 9);
          return true;
        }
        return false;
      };
  std::size_t action_count = 99;
  pluto::DirectControlFailure failure;

  ASSERT_TRUE(pluto::prepare_direct_ink_canvas_from_semantics(
      &state, toggle, tap, std::chrono::milliseconds(50), &action_count,
      &failure));
  EXPECT_EQ(action_count, 2u);
  EXPECT_TRUE(taps == (std::vector<std::uint64_t>{40, 42}));
  EXPECT_TRUE(toggles == (std::vector<bool>{true, false}));
  EXPECT_TRUE(failure.code.empty());
}

TEST(DirectInkCanvasPreparation, AlreadyMountedEditorNeedsNoAction) {
  pluto::DirectInkSemanticsState state;
  int taps = 0;
  int disables = 0;
  const pluto::DirectInkSemanticsToggle toggle = [&](bool enabled) {
    if (enabled) {
      publish_semantics(&state, {{50, "Back to gallery"}});
    } else {
      ++disables;
    }
    return true;
  };
  const pluto::DirectInkSemanticsTap tap =
      [&](const pluto::DirectInkSemanticsNode &) {
        ++taps;
        return true;
      };
  std::size_t action_count = 99;
  pluto::DirectControlFailure failure;

  ASSERT_TRUE(pluto::prepare_direct_ink_canvas_from_semantics(
      &state, toggle, tap, std::chrono::milliseconds(50), &action_count,
      &failure));
  EXPECT_EQ(action_count, 0u);
  EXPECT_EQ(taps, 0);
  EXPECT_EQ(disables, 1);
}

TEST(DirectInkCanvasPreparation, ResumesAnAlreadyOpenChooser) {
  pluto::DirectInkSemanticsState state;
  const pluto::DirectInkSemanticsToggle toggle = [&](bool enabled) {
    if (enabled) {
      publish_semantics(&state, {{60, "new artwork"}, {61, "create"}});
    }
    return true;
  };
  const pluto::DirectInkSemanticsTap tap =
      [&](const pluto::DirectInkSemanticsNode &node) {
        if (node.node_id != 61) {
          return false;
        }
        publish_semantics(&state, {{62, "Back to gallery"}});
        return true;
      };
  std::size_t action_count = 99;
  pluto::DirectControlFailure failure;

  ASSERT_TRUE(pluto::prepare_direct_ink_canvas_from_semantics(
      &state, toggle, tap, std::chrono::milliseconds(50), &action_count,
      &failure));
  EXPECT_EQ(action_count, 1u);
}

TEST(DirectInkCanvasPreparation, MissingOrRejectedTransitionFailsClosed) {
  pluto::DirectInkSemanticsState state;
  int disables = 0;
  const pluto::DirectInkSemanticsToggle missing = [&](bool enabled) {
    if (enabled) {
      publish_semantics(&state, {{70, "new artwork", false}});
    } else {
      ++disables;
    }
    return true;
  };
  const pluto::DirectInkSemanticsTap unused =
      [](const pluto::DirectInkSemanticsNode &) { return true; };
  std::size_t action_count = 99;
  pluto::DirectControlFailure failure;

  EXPECT_FALSE(pluto::prepare_direct_ink_canvas_from_semantics(
      &state, missing, unused, std::chrono::milliseconds(2), &action_count,
      &failure));
  EXPECT_EQ(failure.code, "ink-ui-timeout");
  EXPECT_EQ(action_count, 0u);
  EXPECT_EQ(disables, 1);

  const pluto::DirectInkSemanticsToggle available = [&](bool enabled) {
    if (enabled) {
      publish_semantics(&state, {{71, "new artwork"}});
    }
    return true;
  };
  const pluto::DirectInkSemanticsTap rejected =
      [](const pluto::DirectInkSemanticsNode &) { return false; };
  failure = {};
  EXPECT_FALSE(pluto::prepare_direct_ink_canvas_from_semantics(
      &state, available, rejected, std::chrono::milliseconds(20), &action_count,
      &failure));
  EXPECT_EQ(failure.code, "semantics-action-failed");
  EXPECT_EQ(action_count, 0u);
}

TEST(DirectInkCanvasPresentationReceipt,
     ActionWithoutExactFullPresenterProofFailsWithExactTimeout) {
  pluto::DirectInkSemanticsState state;
  const pluto::DirectInkSemanticsToggle toggle = [&](bool enabled) {
    if (enabled) {
      publish_semantics(&state, {{80, "create"}});
    }
    return true;
  };
  const pluto::DirectInkSemanticsTap tap =
      [&](const pluto::DirectInkSemanticsNode &node) {
        EXPECT_EQ(node.node_id, 80u);
        publish_semantics(&state, {{81, "Back to gallery"}});
        return true;
      };
  int proofs = 0;
  const pluto::DirectInkPresentationTracker presentation{
      .prove =
          [&](std::chrono::milliseconds timeout,
              pluto::DirectInkPresentationProof *proof) {
            ++proofs;
            EXPECT_EQ(timeout, std::chrono::milliseconds(19));
            *proof = {};
            return false;
          },
  };
  std::size_t action_count = 99;
  pluto::DirectInkPresentationProof proof{UINT64_MAX, UINT64_MAX};
  pluto::DirectControlFailure failure;

  EXPECT_FALSE(pluto::prepare_direct_ink_canvas_with_presentation_receipt(
      &state, toggle, tap, presentation, std::chrono::milliseconds(50),
      std::chrono::milliseconds(19), &action_count, &proof, &failure));
  EXPECT_EQ(action_count, 1u);
  EXPECT_EQ(proof.surface_generation, 0u);
  EXPECT_EQ(proof.frame_id, 0u);
  EXPECT_EQ(proofs, 1);
  EXPECT_EQ(failure.code, "presentation-timeout");
  EXPECT_EQ(failure.message,
            "Ink canvas did not complete its exact Full panel proof");
}

TEST(DirectInkCanvasPresentationReceipt,
     MountedEditorStillRequiresFreshExactFullPresenterProof) {
  pluto::DirectInkSemanticsState state;
  const pluto::DirectInkSemanticsToggle toggle = [&](bool enabled) {
    if (enabled) {
      publish_semantics(&state, {{90, "Back to gallery"}});
    }
    return true;
  };
  int proofs = 0;
  const pluto::DirectInkPresentationTracker presentation{
      .prove =
          [&](std::chrono::milliseconds timeout,
              pluto::DirectInkPresentationProof *proof) {
            ++proofs;
            EXPECT_EQ(timeout, std::chrono::milliseconds(19));
            *proof = {.surface_generation = 73, .frame_id = 811};
            return true;
          },
  };
  std::size_t action_count = 99;
  pluto::DirectInkPresentationProof proof;
  pluto::DirectControlFailure failure;

  ASSERT_TRUE(pluto::prepare_direct_ink_canvas_with_presentation_receipt(
      &state, toggle,
      [](const pluto::DirectInkSemanticsNode &) { return true; }, presentation,
      std::chrono::milliseconds(50), std::chrono::milliseconds(19),
      &action_count, &proof, &failure));
  EXPECT_EQ(action_count, 0u);
  EXPECT_EQ(proof.surface_generation, 73u);
  EXPECT_EQ(proof.frame_id, 811u);
  EXPECT_EQ(proofs, 1);
  EXPECT_TRUE(failure.code.empty());
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

TEST(EngineHostPenInput,
     ProgrammaticInkStrokeIsACompleteResponsiveStylusSequence) {
  for (const auto &[width, height] :
       std::array<std::pair<std::int32_t, std::int32_t>, 2>{
           std::pair{1404, 1872}, std::pair{954, 1696}}) {
    std::array<FlutterPointerEvent, pluto::kDirectInkStrokeEventCount> events{};
    ASSERT_TRUE(
        pluto::build_direct_ink_stroke_events(width, height, 1000, &events));

    EXPECT_EQ(events.front().phase, kAdd);
    EXPECT_EQ(events[1].phase, kDown);
    EXPECT_EQ(events[events.size() - 2].phase, kUp);
    EXPECT_EQ(events.back().phase, kRemove);
    for (std::size_t index = 2; index + 2 < events.size(); ++index) {
      EXPECT_EQ(events[index].phase, kMove);
    }
    for (std::size_t index = 0; index < events.size(); ++index) {
      EXPECT_EQ(events[index].struct_size, sizeof(FlutterPointerEvent));
      EXPECT_EQ(events[index].device_kind, kFlutterPointerDeviceKindStylus);
      EXPECT_EQ(events[index].device, 900);
      EXPECT_EQ(events[index].timestamp, 1000u + index * 4000u);
      EXPECT_GE(events[index].x, 0.0);
      EXPECT_LT(events[index].x, width);
      EXPECT_GE(events[index].y, 0.0);
      EXPECT_LT(events[index].y, height);
    }
    EXPECT_LT(events[1].x, events[events.size() - 2].x);
    EXPECT_GT(events[1].y, events[events.size() - 2].y);
  }
  std::array<FlutterPointerEvent, pluto::kDirectInkStrokeEventCount> events{};
  EXPECT_FALSE(pluto::build_direct_ink_stroke_events(0, 1872, 1000, &events));
  EXPECT_FALSE(
      pluto::build_direct_ink_stroke_events(1404, 1872, 1000, nullptr));
}

TEST(EngineHostTouchInput,
     ProgrammaticSwitcherTapUsesPhysicalCenterOnEveryViewport) {
  for (const auto &[width, height] :
       std::array<std::pair<std::int32_t, std::int32_t>, 2>{
           std::pair{1404, 1872}, std::pair{954, 1696}}) {
    std::array<FlutterPointerEvent, pluto::kDirectTouchTapEventCount> events{};
    ASSERT_TRUE(pluto::build_direct_touch_tap_events(
        static_cast<double>(width) * 0.5, static_cast<double>(height) * 0.5,
        2000, &events));
    EXPECT_EQ(events[0].phase, kAdd);
    EXPECT_EQ(events[1].phase, kDown);
    EXPECT_EQ(events[2].phase, kUp);
    EXPECT_EQ(events[3].phase, kRemove);
    EXPECT_EQ(events[0].timestamp, 2000u);
    EXPECT_EQ(events[1].timestamp, 3000u);
    EXPECT_EQ(events[2].timestamp, 34000u);
    EXPECT_EQ(events[3].timestamp, 35000u);
    for (const FlutterPointerEvent &event : events) {
      EXPECT_EQ(event.struct_size, sizeof(FlutterPointerEvent));
      EXPECT_EQ(event.device_kind, kFlutterPointerDeviceKindTouch);
      EXPECT_EQ(event.device, 1);
      EXPECT_EQ(event.x, static_cast<double>(width) * 0.5);
      EXPECT_EQ(event.y, static_cast<double>(height) * 0.5);
    }
  }
  std::array<FlutterPointerEvent, pluto::kDirectTouchTapEventCount> events{};
  EXPECT_FALSE(pluto::build_direct_touch_tap_events(-1.0, 1.0, 0, &events));
  EXPECT_FALSE(pluto::build_direct_touch_tap_events(1.0, 1.0, 0, nullptr));
}

TEST(EngineHostTouchInput,
     SwitcherTapAuthorizationRequiresOwnedRegularDistinctTarget) {
  TempBundle state_dir("switcher-state");
  const std::filesystem::path state = state_dir.path() / "switcher-active";
  const auto write_state = [&](const std::string &contents) {
    std::ofstream output(state, std::ios::trunc);
    output << contents;
  };

  write_state("dev.pluto.ink\ndev.pluto.codex\ndev.example.counter\n");
  const std::optional<std::string> valid =
      pluto::read_direct_switcher_target(state_dir.path().string());
  ASSERT_TRUE(valid.has_value());
  EXPECT_EQ(*valid, "dev.pluto.codex");

  write_state("dev.pluto.ink\n");
  EXPECT_FALSE(pluto::read_direct_switcher_target(state_dir.path().string())
                   .has_value());
  write_state("dev.pluto.ink\ndev.pluto.ink\n");
  EXPECT_FALSE(pluto::read_direct_switcher_target(state_dir.path().string())
                   .has_value());
  write_state("dev.pluto.ink\n../unsafe\n");
  EXPECT_FALSE(pluto::read_direct_switcher_target(state_dir.path().string())
                   .has_value());

  std::filesystem::remove(state);
  const std::filesystem::path target = state_dir.path() / "real-state";
  std::ofstream(target) << "dev.pluto.ink\ndev.pluto.codex\n";
  std::filesystem::create_symlink(target, state);
  EXPECT_FALSE(pluto::read_direct_switcher_target(state_dir.path().string())
                   .has_value());
  std::filesystem::remove(state);
  std::filesystem::create_hard_link(target, state);
  EXPECT_FALSE(pluto::read_direct_switcher_target(state_dir.path().string())
                   .has_value());
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

TEST(EngineHostConfig, RequiresExplicitEnginePath) {
  pluto::EngineHostConfig config;
  config.icu_data_path = "/explicit/icudtl.dat";
  pluto::EngineHost host(std::move(config));
  std::string error;

  EXPECT_FALSE(host.initialize(&error));
  EXPECT_EQ(error, "startup configuration failed: --engine is required");
}

TEST(EngineHostConfig, RequiresExplicitIcuDataPath) {
  pluto::EngineHostConfig config;
  config.engine_path = "/explicit/libflutter_engine.so";
  pluto::EngineHost host(std::move(config));
  std::string error;

  EXPECT_FALSE(host.initialize(&error));
  EXPECT_EQ(error, "startup configuration failed: --icu-data is required");
}

TEST(EngineHostPaths, UsesCanonicalAotElf) {
  TempBundle bundle("canonical");
  bundle.touch("lib/app.so");
  auto host = make_host(bundle.path());
  std::string error;

  EXPECT_FALSE(host.initialize(&error));
  EXPECT_EQ(host.config().aot_elf_path,
            (bundle.path() / "lib/app.so").string());
}

TEST(EngineHostPaths, MissingAotElfDefaultsToCanonicalLayout) {
  TempBundle bundle("missing");
  auto host = make_host(bundle.path());
  std::string error;

  EXPECT_FALSE(host.initialize(&error));
  EXPECT_EQ(host.config().aot_elf_path,
            (bundle.path() / "lib/app.so").string());
}

} // namespace
