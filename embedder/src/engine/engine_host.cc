#include "engine/engine_host.h"

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <iostream>
#include <limits>
#include <vector>

#include "engine/pen_pointer_timestamp.h"
#include "input/evdev.h"
#include "input/pen.h"
#include "input/pen_ring.h"
#include "input/touch.h"
#include "input/transform.h"
#include "presenter/host_preview.h"
#include "presenter/png_encoder.h"
#include "sensors/iio.h"

namespace pluto {
namespace {

std::string join_path(const std::string &base, const char *leaf) {
  return (std::filesystem::path(base) / leaf).string();
}

bool file_exists(const std::string &path) {
  return !path.empty() && std::filesystem::exists(path);
}

bool presenter_has_pen_focus_hook(const PlutoPresenterOps *ops) {
  constexpr size_t kRequiredOpsSize =
      offsetof(PlutoPresenterOps, set_pen_focus) +
      sizeof(PlutoPresenterOps::set_pen_focus);
  return ops != nullptr && ops->struct_size >= kRequiredOpsSize &&
         ops->set_pen_focus != nullptr;
}

void trace_startup(const char *message) {
  if (std::getenv("PLUTO_TRACE_STARTUP") != nullptr) {
    std::cerr << "startup: " << message << "\n";
  }
}

size_t logical_width(const EngineHostConfig &config) {
  return config.rotation == 90 || config.rotation == 270 ? config.panel_height
                                                         : config.panel_width;
}

size_t logical_height(const EngineHostConfig &config) {
  return config.rotation == 90 || config.rotation == 270 ? config.panel_width
                                                         : config.panel_height;
}

int32_t degrees_for_sensor_orientation(SensorOrientation orientation) {
  switch (orientation) {
  case SensorOrientation::kPortrait:
    return 0;
  case SensorOrientation::kLandscapeLeft:
    return 90;
  case SensorOrientation::kPortraitUpsideDown:
    return 180;
  case SensorOrientation::kLandscapeRight:
    return 270;
  case SensorOrientation::kFlat:
  case SensorOrientation::kUnknown:
    return -1;
  }
  return -1;
}

} // namespace

const char *engine_mode_name(EngineMode mode) {
  switch (mode) {
  case EngineMode::kDebug:
    return "debug";
  case EngineMode::kProfile:
    return "profile";
  case EngineMode::kRelease:
    return "release";
  }
  return "debug";
}

bool apply_presenter_display_info(const PlutoDisplayInfo &info,
                                  EngineHostConfig *config,
                                  std::string *error) {
  if (config == nullptr) {
    if (error != nullptr) {
      *error = "presenter display info has no destination config";
    }
    return false;
  }
  if (info.width <= 0 || info.height <= 0 || info.dpi <= 0) {
    if (error != nullptr) {
      *error = "presenter reported invalid display geometry " +
               std::to_string(info.width) + "x" + std::to_string(info.height) +
               " at " + std::to_string(info.dpi) + " dpi";
    }
    return false;
  }

  const double adopted_dpr = config->dpr_explicitly_set
                                 ? config->dpr
                                 : static_cast<double>(info.dpi) / 160.0;
  if (!std::isfinite(adopted_dpr) || adopted_dpr <= 0.0) {
    if (error != nullptr) {
      *error = "presenter display geometry resolved to an invalid DPR";
    }
    return false;
  }

  config->panel_width = info.width;
  config->panel_height = info.height;
  config->dpi = info.dpi;
  config->dpr = adopted_dpr;
  return true;
}

FlutterWindowMetricsEvent
window_metrics_for_config(const EngineHostConfig &config) {
  FlutterWindowMetricsEvent metrics{};
  metrics.struct_size = sizeof(metrics);
  metrics.width = logical_width(config);
  metrics.height = logical_height(config);
  metrics.pixel_ratio = config.dpr;
  metrics.display_id = 0;
  metrics.view_id = 0;
  return metrics;
}

EngineHost::EngineHost(EngineHostConfig config)
    : config_(std::move(config)),
      device_identity_(probe_remarkable_device_identity()),
      vsync_pacer_(&event_loop_) {
  register_system_channels(&channels_);
  register_pluto_channels(&channels_);
  sensor_service_ = std::make_unique<SensorService>(sensor_paths_from_env());
  sensor_service_->register_with(&channels_);
  pen_service_ = std::make_unique<PenService>();
  pen_service_->register_with(&channels_);
  pen_service_->set_platform_task_poster([this](std::function<void()> task) {
    event_loop_.post_closure(std::move(task));
  });
  event_loop_.set_signal_handler([this](int signal) {
    if (signal == SIGHUP) {
      const bool accepted =
          frame_renderer_ != nullptr && frame_renderer_->request_pixel_reset();
      std::cerr << "ghost-control: SIGHUP -> BlinkNow "
                << (accepted ? "accepted" : "unavailable") << "\n";
    } else if (signal == SIGUSR1) {
      hibernate();
    } else if (signal == SIGUSR2) {
      resume();
    }
  });
  rebuild_channel_context();
}

EngineHost::~EngineHost() { shutdown(); }

void EngineHost::resolve_paths() {
  if (config_.app_id.empty()) {
    const char *app_id = std::getenv("PLUTO_APP_ID");
    config_.app_id = app_id != nullptr && *app_id != '\0' ? app_id : "default";
  }
  if (config_.assets_path.empty() && !config_.bundle_path.empty()) {
    config_.assets_path = join_path(config_.bundle_path, "flutter_assets");
  }
  if (config_.aot_elf_path.empty() && !config_.bundle_path.empty()) {
    const std::string canonical_aot =
        join_path(config_.bundle_path, "lib/app.so");
    const std::string legacy_aot = join_path(config_.bundle_path, "app.so");
    // New packages always use bundle/lib/app.so. Keep reading the former
    // bundle/app.so layout so already-installed bundles remain launchable,
    // but prefer the canonical file when both happen to be present.
    config_.aot_elf_path =
        file_exists(canonical_aot) || !file_exists(legacy_aot) ? canonical_aot
                                                               : legacy_aot;
  }
  if (config_.engine_path.empty()) {
    config_.engine_path = "third_party/engine/linux-arm64/libflutter_engine.so";
  }
  if (config_.icu_data_path.empty()) {
    config_.icu_data_path = "third_party/engine/linux-arm64/icudtl.dat";
  }
}

bool EngineHost::initialize(std::string *error) {
  resolve_paths();
  if (!config_.ready_file_path.empty() &&
      !std::filesystem::path(config_.ready_file_path).is_absolute()) {
    if (error != nullptr) {
      *error = "startup configuration failed: --ready-file must be an "
               "absolute path";
    }
    return false;
  }
  if (!config_.health_file_path.empty() &&
      !std::filesystem::path(config_.health_file_path).is_absolute()) {
    if (error != nullptr) {
      *error = "startup configuration failed: --health-file must be an "
               "absolute path";
    }
    return false;
  }
  setenv("MALLOC_ARENA_MAX", "2", 0);

  trace_startup("load engine");
  if (!engine_library_.load(config_.engine_path, error)) {
    return false;
  }
  trace_startup("check mode payload");
  if (!check_mode_payload(error)) {
    return false;
  }
  trace_startup("open presenter");
  if (!open_presenter(error)) {
    return false;
  }
  select_initial_auto_rotation();
  input_rotation_.store(config_.rotation, std::memory_order_release);
  trace_startup("setup renderer");
  if (!setup_renderer(error)) {
    return false;
  }
  const bool defer_initial_system_ui = should_defer_system_ui();
  if (frame_renderer_ != nullptr) {
    frame_renderer_->set_presentation_suspended(defer_initial_system_ui);
  }
  if (defer_initial_system_ui) {
    std::cerr << "system-ui: holding cold launcher presentation until routed\n";
  }
  trace_startup("assemble project args");
  if (!assemble_project_args(error)) {
    return false;
  }

  trace_startup("FlutterEngineInitialize");
  const FlutterEngineResult init_result = engine_library_.procs().Initialize(
      FLUTTER_ENGINE_VERSION, &renderer_config_, &project_args_, this,
      &engine_);
  if (init_result != kSuccess) {
    if (error != nullptr) {
      *error = "FlutterEngineInitialize failed at startup step 7 with result " +
               std::to_string(static_cast<int>(init_result));
    }
    return false;
  }
  trace_startup("FlutterEngineInitialize ok");
  event_loop_.set_engine(&engine_library_.procs(), engine_);
  vsync_pacer_.set_engine(&engine_library_.procs(), engine_);
  vsync_pacer_.set_enabled(config_.enable_vsync_pacer);
  // E-ink frame-rate cap: pace Flutter to the panel's realistic rate so JIT
  // raster/UI stop burning cores on frames the panel never displays.
  int frame_ms = config_.frame_interval_ms;
  if (const char *env = std::getenv("PLUTO_FRAME_MS")) {
    char *end = nullptr;
    const long v = std::strtol(env, &end, 10);
    if (end != env && v >= 0 && v <= 1000) {
      frame_ms = static_cast<int>(v);
    }
  }
  vsync_pacer_.set_interval_ns(static_cast<uint64_t>(frame_ms) * 1000000ull);
  std::fprintf(stderr, "vsync: Flutter frame cap = %d ms (%s)\n", frame_ms,
               frame_ms > 0 ? "throttled" : "uncapped");
  install_channel_senders();

  initialized_ = true;
  trace_startup("initialize complete");
  return true;
}

bool EngineHost::run(std::string *error) {
  if (!initialized_) {
    if (error != nullptr) {
      *error = "EngineHost::run called before initialize";
    }
    return false;
  }
  trace_startup("FlutterEngineRunInitialized");
  const FlutterEngineResult result =
      engine_library_.procs().RunInitialized(engine_);
  if (result != kSuccess) {
    if (error != nullptr) {
      *error =
          "FlutterEngineRunInitialized failed at startup step 9 with result " +
          std::to_string(static_cast<int>(result));
    }
    return false;
  }
  trace_startup("FlutterEngineRunInitialized ok");
  trace_startup("NotifyDisplayUpdate");
  if (!send_display_update()) {
    if (error != nullptr) {
      *error = "FlutterEngineNotifyDisplayUpdate failed after run";
    }
    return false;
  }
  trace_startup("SendWindowMetricsEvent");
  if (!send_window_metrics()) {
    if (error != nullptr) {
      *error = "FlutterEngineSendWindowMetricsEvent failed after run";
    }
    return false;
  }
  trace_startup("UpdateLocales");
  if (!send_default_locale()) {
    if (error != nullptr) {
      *error = "FlutterEngineUpdateLocales failed after run";
    }
    return false;
  }
  running_ = true;
  transition_lifecycle(LifecycleState::kResumed);
  if (frame_renderer_ != nullptr && frame_renderer_->presentation_suspended()) {
    arm_system_ui_watchdog();
  }
  std::cout << "PLUTO_EMBEDDER version=0.1.0 engine=unknown mode="
            << engine_mode_name(config_.mode)
            << " presenter=" << config_.presenter_name << " aot="
            << (engine_library_.procs().RunsAOTCompiledDartCode() ? "true"
                                                                  : "false")
            << " format="
            << (config_.pixel_format == kPlutoPixelFormatGray8      ? "gray8"
                : config_.pixel_format == kPlutoPixelFormatXrgb8888 ? "xrgb8888"
                                                                    : "rgb565")
            << " panel=" << config_.panel_width << "x" << config_.panel_height
            << " rotation=" << config_.rotation << " dpr=" << config_.dpr
            << "\n";
  if (config_.run_event_loop) {
    if (config_.synthetic_tap) {
      const int32_t tap_delay_ms = config_.synthetic_tap_delay_ms < 0
                                       ? 0
                                       : config_.synthetic_tap_delay_ms;
      event_loop_.post_closure_at(event_loop_.now_nanos() +
                                      static_cast<uint64_t>(tap_delay_ms) *
                                          1000000ull,
                                  [this] {
                                    send_synthetic_tap(config_.synthetic_tap_x,
                                                       config_.synthetic_tap_y);
                                  });
    }
    if (config_.run_duration_ms > 0) {
      event_loop_.post_closure_at(
          event_loop_.now_nanos() +
              static_cast<uint64_t>(config_.run_duration_ms) * 1000000ull,
          [this] { request_shutdown(); });
    }
    start_foreground_services();
    trace_startup("event loop enter");
    event_loop_.run();
    trace_startup("event loop exit");
  }
  return true;
}

bool EngineHost::send_display_update() {
  if (engine_ == nullptr || !engine_library_.loaded()) {
    return false;
  }
  FlutterEngineDisplay display{};
  display.struct_size = sizeof(display);
  display.display_id = 0;
  display.single_display = true;
  display.refresh_rate = 85.0;
  display.width = static_cast<size_t>(config_.panel_width);
  display.height = static_cast<size_t>(config_.panel_height);
  display.device_pixel_ratio = config_.dpr;
  return engine_library_.procs().NotifyDisplayUpdate(
             engine_, kFlutterEngineDisplaysUpdateTypeStartup, &display, 1) ==
         kSuccess;
}

bool EngineHost::send_default_locale() {
  if (engine_ == nullptr || !engine_library_.loaded()) {
    return false;
  }
  FlutterLocale locale{};
  locale.struct_size = sizeof(locale);
  locale.language_code = "en";
  locale.country_code = "US";
  const FlutterLocale *locales[] = {&locale};
  return engine_library_.procs().UpdateLocales(engine_, locales, 1) == kSuccess;
}

bool EngineHost::send_synthetic_tap(double x, double y) {
  if (engine_ == nullptr || !engine_library_.loaded()) {
    return false;
  }
  const size_t now_us = static_cast<size_t>(event_loop_.now_nanos() / 1000ull);
  FlutterPointerEvent events[4]{};
  auto fill = [&](size_t index, FlutterPointerPhase phase, size_t delta_us) {
    events[index].struct_size = sizeof(FlutterPointerEvent);
    events[index].phase = phase;
    events[index].timestamp = now_us + delta_us;
    events[index].x = x;
    events[index].y = y;
    events[index].device = 1;
    events[index].signal_kind = kFlutterPointerSignalKindNone;
    events[index].device_kind = kFlutterPointerDeviceKindTouch;
    events[index].view_id = 0;
    events[index].pressure = phase == kDown || phase == kMove ? 1.0 : 0.0;
    events[index].pressure_min = 0.0;
    events[index].pressure_max = 1.0;
  };
  fill(0, kAdd, 0);
  fill(1, kDown, 1000);
  fill(2, kUp, 32000);
  fill(3, kRemove, 33000);
  return engine_library_.procs().SendPointerEvent(engine_, events, 4) ==
         kSuccess;
}

bool EngineHost::transition_lifecycle(LifecycleState state) {
  if (!lifecycle_.transition_to(state)) {
    return false;
  }
  const std::string_view value = lifecycle_.channel_value();
  return send_channel_message("flutter/lifecycle",
                              std::vector<uint8_t>(value.begin(), value.end()));
}

bool EngineHost::send_channel_message(const std::string &channel,
                                      const std::vector<uint8_t> &message) {
  if (engine_ == nullptr || !engine_library_.loaded()) {
    return false;
  }
  FlutterPlatformMessage platform_message{};
  platform_message.struct_size = sizeof(platform_message);
  platform_message.channel = channel.c_str();
  platform_message.message = message.empty() ? nullptr : message.data();
  platform_message.message_size = message.size();
  platform_message.response_handle = nullptr;
  return engine_library_.procs().SendPlatformMessage(
             engine_, &platform_message) == kSuccess;
}

void EngineHost::install_channel_senders() {
  const EventSender sender = [this](const std::string &channel,
                                    const std::vector<uint8_t> &message) {
    send_channel_message(channel, message);
  };
  sensor_service_->set_sender(sender);
  pen_service_->set_sender(sender);
}

bool EngineHost::capture_direct_screenshot(
    DirectScreenshotSurface surface,
    const std::optional<std::string> &requested_app_id,
    DirectScreenshotCapture *capture, DirectControlFailure *failure) {
  const auto fail = [failure](const char *code, const std::string &message) {
    if (failure != nullptr) {
      failure->code = code;
      failure->message = message;
    }
    return false;
  };
  if (capture == nullptr || frame_renderer_ == nullptr) {
    return fail("screenshot-unavailable", "renderer is unavailable");
  }
  if (requested_app_id.has_value() && *requested_app_id != config_.app_id) {
    return fail("app-not-foreground",
                "requested app is not the foreground renderer");
  }

  const RendererSnapshotSurface renderer_surface =
      surface == DirectScreenshotSurface::kLogical
          ? RendererSnapshotSurface::kLogical
          : RendererSnapshotSurface::kPostDither;
  RendererSnapshot snapshot;
  if (!frame_renderer_->snapshot(renderer_surface, &snapshot)) {
    return fail("screenshot-unavailable",
                "no complete renderer frame is available yet");
  }
  if (snapshot.width >
          static_cast<uint32_t>(std::numeric_limits<int32_t>::max()) ||
      snapshot.height >
          static_cast<uint32_t>(std::numeric_limits<int32_t>::max())) {
    return fail("invalid-surface", "renderer dimensions exceed PNG limits");
  }

  DirectScreenshotCapture next;
  next.width = static_cast<int32_t>(snapshot.width);
  next.height = static_cast<int32_t>(snapshot.height);
  next.stride = snapshot.stride_bytes;
  next.format = snapshot.format;
  next.app_id = config_.app_id;
  next.pid = static_cast<int64_t>(::getpid());
  next.surface = surface;
  std::string png_error;
  try {
    if (!encode_png(snapshot.pixels.data(), next.width, next.height,
                    next.stride, next.format, &next.png, &png_error)) {
      return fail("png-encode-failed", png_error);
    }
  } catch (const std::exception &error) {
    return fail("png-encode-failed", error.what());
  }
  *capture = std::move(next);
  return true;
}

bool build_direct_ink_stroke_events(
    std::int32_t width, std::int32_t height, std::size_t started_us,
    std::array<FlutterPointerEvent, kDirectInkStrokeEventCount> *events) {
  if (events == nullptr || width <= 0 || height <= 0) {
    return false;
  }
  constexpr std::size_t kMoveCount = kDirectInkStrokeEventCount - 4;
  *events = {};
  const double panel_width = static_cast<double>(width);
  const double panel_height = static_cast<double>(height);
  const double start_x = panel_width * 0.30;
  const double start_y = panel_height * 0.56;
  const double end_x = panel_width * 0.70;
  const double end_y = panel_height * 0.46;

  const auto fill = [&](std::size_t index, FlutterPointerPhase phase, double x,
                        double y, double pressure) {
    FlutterPointerEvent &event = (*events)[index];
    event.struct_size = sizeof(FlutterPointerEvent);
    event.phase = phase;
    event.timestamp = started_us + index * 4000u;
    event.x = x;
    event.y = y;
    event.device = 900;
    event.signal_kind = kFlutterPointerSignalKindNone;
    event.device_kind = kFlutterPointerDeviceKindStylus;
    event.view_id = 0;
    event.pressure = pressure;
    event.pressure_min = 0.0;
    event.pressure_max = 1.0;
  };

  fill(0, kAdd, start_x, start_y, 0.0);
  fill(1, kDown, start_x, start_y, 0.55);
  for (std::size_t index = 0; index < kMoveCount; ++index) {
    const double t = static_cast<double>(index + 1) / kMoveCount;
    // A shallow S-curve is unmistakably a drawn stroke in camera evidence
    // while remaining inside Ink's responsive central canvas on every panel.
    const double bend = (t - 0.5) * (t - 0.5) * (t < 0.5 ? -1.0 : 1.0);
    fill(index + 2, kMove, start_x + (end_x - start_x) * t,
         start_y + (end_y - start_y) * t + panel_height * 0.12 * bend, 0.55);
  }
  fill(kDirectInkStrokeEventCount - 2, kUp, end_x, end_y, 0.0);
  fill(kDirectInkStrokeEventCount - 1, kRemove, end_x, end_y, 0.0);
  return true;
}

bool EngineHost::send_direct_ink_stroke(const std::string &requested_app_id,
                                        DirectStrokeResult *result,
                                        DirectControlFailure *failure) {
  const auto fail = [failure](const char *code, const char *message) {
    if (failure != nullptr) {
      failure->code = code;
      failure->message = message;
    }
    return false;
  };
  if (result == nullptr || failure == nullptr) {
    return false;
  }
  if (requested_app_id != config_.app_id) {
    return fail("wrong-app", "requested app is not the foreground embedder");
  }
  if (config_.app_id != "dev.pluto.ink") {
    return fail("unsupported-app", "draw-stroke is restricted to Pluto Ink");
  }
  if (engine_ == nullptr || !engine_library_.loaded()) {
    return fail("unavailable", "Flutter engine is unavailable");
  }

  std::array<FlutterPointerEvent, kDirectInkStrokeEventCount> events{};
  struct timespec monotonic {};
  if (::clock_gettime(CLOCK_MONOTONIC, &monotonic) != 0) {
    return fail("clock-failed", "could not timestamp programmatic stroke");
  }
  const std::int64_t monotonic_us =
      static_cast<std::int64_t>(monotonic.tv_sec) * 1000000ll +
      static_cast<std::int64_t>(monotonic.tv_nsec / 1000);
  const std::size_t started_us = flutter_pen_pointer_timestamp_us(monotonic_us);
  if (!build_direct_ink_stroke_events(config_.panel_width, config_.panel_height,
                                      started_us, &events)) {
    return fail("invalid-geometry", "panel geometry cannot host an Ink stroke");
  }

  if (engine_library_.procs().SendPointerEvent(engine_, events.data(),
                                               events.size()) != kSuccess) {
    return fail("pointer-send-failed",
                "Flutter rejected the programmatic Ink stroke");
  }
  *result = DirectStrokeResult{
      .app_id = config_.app_id,
      .pid = static_cast<std::int64_t>(::getpid()),
      .event_count = events.size(),
  };
  return true;
}

void EngineHost::start_foreground_services() {
  if (config_.presenter_name == "native") {
    if (direct_control_server_ == nullptr) {
      DirectControlServerConfig control;
      control.run_dir = config_.run_dir;
      control.screenshot =
          [this](DirectScreenshotSurface surface,
                 const std::optional<std::string> &requested_app_id,
                 DirectScreenshotCapture *capture,
                 DirectControlFailure *failure) {
            return capture_direct_screenshot(surface, requested_app_id, capture,
                                             failure);
          };
      control.draw_stroke = [this](const std::string &requested_app_id,
                                   DirectStrokeResult *result,
                                   DirectControlFailure *failure) {
        return send_direct_ink_stroke(requested_app_id, result, failure);
      };
      direct_control_server_ =
          std::make_unique<DirectControlServer>(std::move(control));
    }
    std::string error;
    if (!direct_control_server_->start(&error)) {
      std::cerr << "direct-control: " << error << "\n";
    }
  }
  if (config_.enable_touch && !touch_thread_.joinable()) {
    touch_stop_.store(false, std::memory_order_release);
    touch_thread_ = std::thread(&EngineHost::touch_input_loop, this);
  }
  if (config_.enable_pen && ink_thread_ == nullptr) {
    start_ink_thread();
  }
  if (config_.enable_bezel_redraw && !bezel_redraw_thread_.joinable()) {
    bezel_redraw_stop_.store(false, std::memory_order_release);
    bezel_redraw_thread_ = std::thread(&EngineHost::bezel_redraw_loop, this);
  }
}

void EngineHost::stop_foreground_services() {
  if (direct_control_server_ != nullptr) {
    direct_control_server_->stop();
  }
  touch_stop_.store(true, std::memory_order_release);
  if (touch_thread_.joinable()) {
    touch_thread_.join();
  }
  if (ink_thread_) {
    ink_thread_->stop();
    ink_thread_.reset();
  }
  if (pen_service_) {
    // InkThread::stop emits the terminal Cancel/Remove sample. Flush the
    // ordinary-priority observer worker before publishing a hibernate marker
    // or tearing down Flutter so that event cannot leak into the next session.
    pen_service_->drain_observer_events();
  }
  vsync_pacer_.set_pen_proximity(false);
  if (frame_renderer_ != nullptr) {
    frame_renderer_->set_touch_active(false);
    frame_renderer_->set_pen_active(false);
    frame_renderer_->clear_pen_render_hints();
  }
  bezel_redraw_stop_.store(true, std::memory_order_release);
  if (bezel_redraw_thread_.joinable()) {
    bezel_redraw_thread_.join();
  }
}

std::string EngineHost::hibernate_marker_path() const {
  return (std::filesystem::path(config_.run_dir) / "hibernated" /
          std::to_string(::getpid()))
      .string();
}

bool EngineHost::publish_hibernate_marker() const {
  const std::filesystem::path marker(hibernate_marker_path());
  std::error_code ec;
  std::filesystem::create_directories(marker.parent_path(), ec);
  if (ec) {
    return false;
  }
  const std::string temporary = marker.string() + ".tmp";
  const int fd = ::open(temporary.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    return false;
  }
  const char value[] = "paused\n";
  const bool wrote = ::write(fd, value, sizeof(value) - 1) ==
                     static_cast<ssize_t>(sizeof(value) - 1);
  const bool closed = ::close(fd) == 0;
  if (!wrote || !closed || ::rename(temporary.c_str(), marker.c_str()) != 0) {
    ::unlink(temporary.c_str());
    return false;
  }
  return true;
}

bool EngineHost::publish_control_file(const std::string &leaf,
                                      const std::string &content) const {
  const std::filesystem::path target =
      std::filesystem::path(config_.run_dir) / leaf;
  std::error_code ec;
  std::filesystem::create_directories(target.parent_path(), ec);
  if (ec) {
    return false;
  }
  const std::string temporary =
      target.string() + ".tmp." + std::to_string(::getpid());
  const int fd = ::open(temporary.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    return false;
  }
  const bool wrote = ::write(fd, content.data(), content.size()) ==
                     static_cast<ssize_t>(content.size());
  const bool closed = ::close(fd) == 0;
  if (!wrote || !closed || ::rename(temporary.c_str(), target.c_str()) != 0) {
    ::unlink(temporary.c_str());
    return false;
  }
  return true;
}

void EngineHost::touch_input_loop() {
  // The loop can be restarted after hibernation. Never carry partial edge
  // contacts from the previous foreground lifetime into the resumed app.
  system_edge_gesture_.reset();
  const std::string path = config_.touch_device_path.empty()
                               ? std::string(kDefaultTouchByPath)
                               : config_.touch_device_path;
  EvdevSource source;
  if (source.open_by_path(path) != EvdevStatus::kOk) {
    std::cerr << "touch: unable to open " << path << "\n";
    return;
  }
  // Read exclusively so the events do not also reach the stock stack.
  source.grab(true);

  int32_t xmin = 0, xmax = 0, ymin = 0, ymax = 0;
  for (const auto &[code, info] : source.identity().axes) {
    if (code == kAbsMtPositionX || code == kAbsX) {
      xmin = info.minimum;
      xmax = info.maximum;
    } else if (code == kAbsMtPositionY || code == kAbsY) {
      ymin = info.minimum;
      ymax = info.maximum;
    }
  }
  if (xmax <= xmin) {
    xmin = 0;
    xmax = 20966;
  }
  if (ymax <= ymin) {
    ymin = 0;
    ymax = 15725;
  }
  const AffineTransform calib = default_digitizer_to_panel(
      static_cast<float>(config_.panel_width),
      static_cast<float>(config_.panel_height), xmin, xmax, ymin, ymax);
  auto current_orientation = [this] {
    const int32_t rotation = input_rotation_.load(std::memory_order_acquire);
    return static_cast<Orientation>((rotation % 360 + 360) % 360);
  };
  Orientation gesture_orientation = current_orientation();
  std::cerr << "touch: " << source.identity().name << " on " << path << " x["
            << xmin << "," << xmax << "] y[" << ymin << "," << ymax
            << "] -> full multitouch\n";

  TouchTracker tracker;
  bool published_touch_active = false;
  auto publish_touch_state = [&] {
    bool active = false;
    for (size_t slot = 0; slot < kTouchSlotCount; ++slot) {
      if (tracker.slot(slot).tracking_id >= 0) {
        active = true;
        break;
      }
    }
    // Publish raw contact state, not only Flutter-visible fingers: a palm or
    // pen-suppressed contact still means this is a bad moment to flash glass.
    if (frame_renderer_ != nullptr && active != published_touch_active) {
      frame_renderer_->set_touch_active(active);
    }
    published_touch_active = active;
  };
  uint32_t seq = 0;
  auto now_monotonic_us = [] {
    struct timespec mono {};
    clock_gettime(CLOCK_MONOTONIC, &mono);
    return static_cast<int64_t>(mono.tv_sec) * 1000000ll +
           mono.tv_nsec / 1000ll;
  };
  auto dispatch_touch = [&](const TouchTrackerOutput &out) {
    if (out.count == 0) {
      return;
    }
    std::vector<FlutterPointerEvent> evs;
    evs.reserve(out.count * 2);
    const size_t now_us = static_cast<size_t>(now_monotonic_us());
    for (size_t i = 0; i < out.count; ++i) {
      const TouchEvent &te = out.events[i];
      if (!te.emit_to_flutter) {
        continue;
      }
      const pluto_touch_ring_record rec = make_touch_ring_record(
          te, calib, current_orientation(),
          static_cast<float>(config_.panel_width),
          static_cast<float>(config_.panel_height), seq++);
      const double x = rec.x_logical;
      const double y = rec.y_logical;
      const int32_t device = 100 + te.slot; // one Flutter device per finger
      auto push = [&](FlutterPointerPhase phase, double pressure) {
        FlutterPointerEvent e{};
        e.struct_size = sizeof(FlutterPointerEvent);
        e.phase = phase;
        e.timestamp = now_us;
        e.x = x;
        e.y = y;
        e.device = device;
        e.signal_kind = kFlutterPointerSignalKindNone;
        e.device_kind = kFlutterPointerDeviceKindTouch;
        e.view_id = 0;
        e.pressure = pressure;
        e.pressure_min = 0.0;
        e.pressure_max = 1.0;
        evs.push_back(e);
      };
      switch (te.phase) {
      case TouchPhase::kBegan:
        push(kAdd, 0.0);
        push(kDown, 1.0);
        break;
      case TouchPhase::kMoved:
        push(kMove, 1.0);
        break;
      case TouchPhase::kEnded:
        push(kUp, 0.0);
        push(kRemove, 0.0);
        break;
      case TouchPhase::kCancelled:
        push(kCancel, 0.0);
        push(kRemove, 0.0);
        break;
      }
    }
    if (!evs.empty() && engine_ != nullptr && engine_library_.loaded()) {
      engine_library_.procs().SendPointerEvent(engine_, evs.data(), evs.size());
    }
  };

  while (!touch_stop_.load(std::memory_order_acquire)) {
    // Pen proximity is produced by a separate evdev thread. Sync before and
    // after reading touch so a hover transition cancels an existing finger
    // immediately and suppresses a palm born in the same polling window.
    dispatch_touch(pen_touch_arbiter_.sync(&tracker, now_monotonic_us()));
    publish_touch_state();
    SourceResult r = source.next_batch();
    if (r.status == EvdevStatus::kDeviceLost) {
      break;
    }
    dispatch_touch(pen_touch_arbiter_.sync(&tracker, now_monotonic_us()));
    publish_touch_state();
    if (r.events.empty()) {
      timespec ts{0, 3 * 1000 * 1000}; // 3ms poll -> low-latency, no busy spin
      nanosleep(&ts, nullptr);
      continue;
    }
    const TouchTrackerOutput touch = tracker.consume_batch(r.events);
    publish_touch_state();
    const Orientation orientation = current_orientation();
    if (orientation != gesture_orientation) {
      system_edge_gesture_.reset();
      gesture_orientation = orientation;
    }
    const SystemEdgeGesture system_gesture =
        config_.enable_hibernation
            ? system_edge_gesture_.consume(
                  touch, calib, orientation,
                  static_cast<float>(config_.panel_width),
                  static_cast<float>(config_.panel_height),
                  static_cast<float>(config_.dpi))
            : SystemEdgeGesture::kNone;
    if (system_gesture != SystemEdgeGesture::kNone) {
      // Down/move samples may already have reached Flutter; cancel them before
      // handing control to the system so no app control can fire on the
      // eventual finger-up.
      dispatch_touch(tracker.cancel_all(now_monotonic_us()));
      publish_touch_state();
      if (system_gesture == SystemEdgeGesture::kAppSwitcher) {
        request_app_switcher();
      } else {
        request_home();
      }
      continue;
    }
    dispatch_touch(touch);
  }
  if (frame_renderer_ != nullptr) {
    frame_renderer_->set_touch_active(false);
  }
  source.grab(false);
  source.close();
}

// Pen input + render hints: InkThread owns the device (poll-driven and
// EVIOCGRAB'd), forwards pointer events to the app, and publishes a cheap
// hover/contact trajectory hint. It never creates pixels or damage. The
// renderer may use the hint only when a later Flutter frame contains verified
// post-quantize changes near that trajectory.
void EngineHost::start_ink_thread() {
  if (frame_renderer_ == nullptr || !frame_renderer_->valid()) {
    // Pointer delivery belongs to the app-input path and must not depend on
    // renderer availability. Only the optional scheduling hints are dropped.
    std::cerr << "ink: no frame renderer; pen render hints disabled\n";
  }
  InkThreadConfig ink_config;
  ink_config.device_path = config_.pen_device_path;
  ink_config.panel_width = static_cast<float>(config_.panel_width);
  ink_config.panel_height = static_cast<float>(config_.panel_height);
  ink_config.orientation =
      static_cast<Orientation>((config_.rotation % 360 + 360) % 360);
  // Predictor override (E-tagged, Stage-5 L2 camera calibrates): "0"/"off"
  // disables, a number replaces the horizon (µs).
  if (const char *predict = std::getenv("PLUTO_PEN_PREDICT");
      predict != nullptr && predict[0] != '\0') {
    const std::string value(predict);
    if (value == "0" || value == "off" || value == "false") {
      ink_config.predictor_enabled = false;
    } else {
      const long horizon = std::strtol(predict, nullptr, 10);
      if (horizon > 0) {
        ink_config.predict_horizon_us = static_cast<uint32_t>(horizon);
      }
    }
  }
  if (const char *priority = std::getenv("PLUTO_PEN_RT_PRIORITY");
      priority != nullptr && priority[0] != '\0') {
    const long parsed = std::strtol(priority, nullptr, 10);
    if (parsed >= 0 && parsed <= 99) {
      ink_config.realtime_priority = static_cast<int>(parsed);
    }
  }

  InkThreadHooks hooks;
  hooks.on_device_open = [this](const DeviceIdentity &identity,
                                const AffineTransform &calibration,
                                Orientation orientation) {
    (void)orientation;
    PenAxisRanges ranges;
    for (const auto &[code, info] : identity.axes) {
      if (code == kAbsX && info.maximum > info.minimum) {
        ranges.raw_x_max = info.maximum;
      } else if (code == kAbsY && info.maximum > info.minimum) {
        ranges.raw_y_max = info.maximum;
      } else if (code == kAbsPressure && info.maximum > 0) {
        ranges.raw_pressure_max = info.maximum;
      } else if (code == kAbsDistance && info.maximum > 0) {
        ranges.raw_distance_max = info.maximum;
      } else if (code == kAbsTiltX && info.maximum > 0) {
        ranges.raw_tilt_max_cdeg = info.maximum;
      }
    }
    pen_service_->set_axis_ranges(ranges);
    pen_calib_ = calibration;
    pen_pressure_max_ =
        ranges.raw_pressure_max > 0 ? ranges.raw_pressure_max : 4095.0;
  };
  hooks.on_tracker_output = [this](const PenTrackerOutput &output) {
    dispatch_pen_output(output);
  };
  hooks.on_render_hint = [this](const PenRenderHint &input) {
    const bool in_range = input.in_range && !input.device_lost;
    const uint64_t sequence = ++pen_render_hint_seq_;
    // Native-panel proximity reaches the presenter before any logical
    // transform, Flutter pointer dispatch, raster scheduling, or unrelated
    // renderer present(). InkThread is joined before presenter detach/close
    // and is started only after attach, so this pointer has a lifecycle fence.
    // The hook carries metadata only: it cannot create pixels or damage.
    if (presenter_has_pen_focus_hook(presenter_ops_) && presenter_ != nullptr) {
      const Point previous =
          input.has_previous ? input.previous : input.current;
      const Point predicted =
          input.prediction_valid ? input.predicted : input.current;
      const RendererConfig renderer_defaults{};
      const PlutoRect focus = pen_focus_rect_for_points(
          static_cast<int32_t>(std::lround(previous.x)),
          static_cast<int32_t>(std::lround(previous.y)),
          static_cast<int32_t>(std::lround(input.current.x)),
          static_cast<int32_t>(std::lround(input.current.y)),
          static_cast<int32_t>(std::lround(predicted.x)),
          static_cast<int32_t>(std::lround(predicted.y)), in_range,
          input.contact && in_range, config_.panel_width, config_.panel_height,
          renderer_defaults.pen_hover_radius_px,
          renderer_defaults.pen_contact_radius_px);
      const PlutoPenFocus presenter_focus{
          sizeof(PlutoPenFocus), focus,
          in_range ? static_cast<uint32_t>(kPlutoPenFocusInRange) |
                         (input.contact
                              ? static_cast<uint32_t>(kPlutoPenFocusContact)
                              : 0u)
                   : static_cast<uint32_t>(kPlutoPenFocusNone),
          sequence};
      (void)presenter_ops_->set_pen_focus(presenter_, &presenter_focus);
    }
    // InkThread guarantees this hook precedes tracker/channel/Flutter work for
    // the same SYN. Hover therefore resets pacing debt before the app sees the
    // pointer, not one callback (or one serialized EventChannel batch) later.
    vsync_pacer_.set_pen_proximity(in_range);
    if (frame_renderer_ != nullptr) {
      frame_renderer_->set_pen_active(in_range);
    }
    const uint64_t generation =
        pen_render_hint_generation_.load(std::memory_order_acquire);
    if ((generation & 1u) != 0) {
      return; // live rotation: never publish old-coordinate corridors
    }
    if (frame_renderer_ == nullptr) {
      return;
    }
    const int32_t rotation = input_rotation_.load(std::memory_order_acquire);
    const Orientation orientation =
        static_cast<Orientation>((rotation % 360 + 360) % 360);
    const float panel_w = static_cast<float>(config_.panel_width);
    const float panel_h = static_cast<float>(config_.panel_height);
    const Size logical = logical_size(panel_w, panel_h, orientation);
    const auto to_logical = [&](Point panel) {
      const Point point =
          panel_to_logical(panel, panel_w, panel_h, orientation);
      return Point{
          .x = std::clamp(point.x, 0.0f, std::max(0.0f, logical.width - 1)),
          .y = std::clamp(point.y, 0.0f, std::max(0.0f, logical.height - 1)),
      };
    };
    const Point previous =
        to_logical(input.has_previous ? input.previous : input.current);
    const Point current = to_logical(input.current);
    const Point predicted =
        to_logical(input.prediction_valid ? input.predicted : input.current);
    PenRenderHintSnapshot hint;
    hint.timestamp_us = input.ts_us;
    hint.in_range = in_range;
    hint.contact = input.contact && hint.in_range;
    hint.previous_x = static_cast<int32_t>(std::lround(previous.x));
    hint.previous_y = static_cast<int32_t>(std::lround(previous.y));
    hint.current_x = static_cast<int32_t>(std::lround(current.x));
    hint.current_y = static_cast<int32_t>(std::lround(current.y));
    hint.predicted_x = static_cast<int32_t>(std::lround(predicted.x));
    hint.predicted_y = static_cast<int32_t>(std::lround(predicted.y));
    hint.sequence = sequence;
    if (generation ==
        pen_render_hint_generation_.load(std::memory_order_acquire)) {
      frame_renderer_->note_pen_render_hint(hint, generation);
    }
  };

  ink_thread_ = std::make_unique<InkThread>(ink_config, std::move(hooks));
  std::string ink_error;
  if (!ink_thread_->start(&ink_error)) {
    std::cerr << "ink: " << ink_error << "\n";
    ink_thread_.reset();
  }
}

void EngineHost::dispatch_pen_output(const PenTrackerOutput &out) {
  if (out.pointer_count == 0 && !out.has_sample) {
    return;
  }
  if (out.has_sample) {
    // Publish hover as well as contact. Palm rejection must start when the pen
    // enters digitizer range, before the nib reaches the glass.
    pen_touch_arbiter_.publish(out.sample.in_range, out.sample.ts_us);
  }
  const float panel_w = static_cast<float>(config_.panel_width);
  const float panel_h = static_cast<float>(config_.panel_height);
  const int32_t rotation = input_rotation_.load(std::memory_order_acquire);
  const Orientation orientation =
      static_cast<Orientation>((rotation % 360 + 360) % 360);

  auto now_monotonic_us = [] {
    struct timespec mono {};
    clock_gettime(CLOCK_MONOTONIC, &mono);
    return static_cast<int64_t>(mono.tv_sec) * 1000000ll +
           mono.tv_nsec / 1000ll;
  };

  std::array<FlutterPointerEvent, 6> evs{};
  size_t event_count = 0;
  for (size_t i = 0; i < out.pointer_count; ++i) {
    const PenPointerEvent &pe = out.pointer_events[i];
    const Point panel = pen_calib_.apply(
        Point{static_cast<float>(pe.raw_x), static_cast<float>(pe.raw_y)});
    const Point logical =
        panel_to_logical(panel, panel_w, panel_h, orientation);
    FlutterPointerEvent e{};
    e.struct_size = sizeof(FlutterPointerEvent);
    switch (pe.phase) {
    case PointerPhase::kAdd:
      e.phase = kAdd;
      break;
    case PointerPhase::kRemove:
      e.phase = kRemove;
      break;
    case PointerPhase::kHover:
      e.phase = kHover;
      break;
    case PointerPhase::kDown:
      e.phase = kDown;
      break;
    case PointerPhase::kMove:
      e.phase = kMove;
      break;
    case PointerPhase::kUp:
      e.phase = kUp;
      break;
    case PointerPhase::kCancel:
      e.phase = kCancel;
      break;
    }
    e.timestamp = flutter_pen_pointer_timestamp_us(pe.ts_us);
    e.x = logical.x;
    e.y = logical.y;
    e.device = 500; // single stylus device, distinct from touch slots
    e.signal_kind = kFlutterPointerSignalKindNone;
    e.device_kind = kFlutterPointerDeviceKindStylus;
    e.view_id = 0;
    e.pressure = pe.raw_pressure / pen_pressure_max_;
    e.pressure_min = 0.0;
    e.pressure_max = 1.0;
    evs[event_count++] = e;
  }
  if (event_count != 0 && engine_ != nullptr && engine_library_.loaded()) {
    engine_library_.procs().SendPointerEvent(engine_, evs.data(), event_count);
  }

  // Diagnostics and the optional Dart EventChannel are deliberately behind
  // Flutter pointer injection. PenService performs only a small state update
  // and lossless value-copy enqueue here; map/codec construction and platform
  // envelope construction run on its ordinary-priority observer worker, then
  // the final Flutter send is posted to the platform loop.
  if (out.has_sample) {
    global_pen_ring_storage().push(
        make_pen_ring_record(out.sample, pen_calib_, orientation, panel_w,
                             panel_h, pen_ring_seq_++));
    const int64_t now = now_monotonic_us();
    if (pen_rate_window_start_us_ == 0) {
      pen_rate_window_start_us_ = now;
    }
    ++pen_rate_samples_;
    const int64_t elapsed = now - pen_rate_window_start_us_;
    if (elapsed >= 1000000) {
      pen_service_->set_sample_rate_estimate(
          static_cast<double>(pen_rate_samples_) * 1e6 /
          static_cast<double>(elapsed));
      pen_rate_samples_ = 0;
      pen_rate_window_start_us_ = now;
    }
  }
  pen_service_->handle_tracker_output(out, pen_calib_, orientation, panel_w,
                                      panel_h);
}

void EngineHost::bezel_redraw_loop() {
  const std::string enable_path =
      config_.bezel_redraw_enable_path.empty()
          ? std::string("/sys/bus/iio/devices/iio:device3/events/"
                        "in_accel0_gesture_doubletap_en")
          : config_.bezel_redraw_enable_path;
  const std::string dev_path = config_.bezel_redraw_iio_path.empty()
                                   ? std::string("/dev/iio:device3")
                                   : config_.bezel_redraw_iio_path;
  bool event_enabled = false;
  if (int f = ::open(enable_path.c_str(), O_WRONLY); f >= 0) {
    event_enabled = ::write(f, "1\n", 2) == 2;
    event_enabled = ::close(f) == 0 && event_enabled;
  }
  if (!event_enabled) {
    std::cerr << "bezel-redraw: cannot enable double-tap event at "
              << enable_path << "\n";
    return;
  }
  const int fd = ::open(dev_path.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    std::cerr << "bezel-redraw: cannot open " << dev_path << "\n";
    return;
  }
  int event_fd = -1;
  // IIO_GET_EVENT_FD_IOCTL = _IOR('i', 0x90, int)
  if (::ioctl(fd, _IOR('i', 0x90, int), &event_fd) < 0 || event_fd < 0) {
    std::cerr << "bezel-redraw: IIO_GET_EVENT_FD failed on " << dev_path
              << "\n";
    ::close(fd);
    return;
  }
  ::close(fd);
  std::cerr << "bezel-redraw: double-tap pixel reset armed (" << dev_path
            << ")\n";
  struct IioEvent {
    std::uint64_t id;
    std::int64_t timestamp;
  };
  int64_t last_refresh_us = 0;
  while (!bezel_redraw_stop_.load(std::memory_order_acquire)) {
    pollfd pfd{event_fd, POLLIN, 0};
    const int pr = ::poll(&pfd, 1, 300);
    if (pr <= 0) {
      continue;
    }
    IioEvent ev{};
    if (::read(event_fd, &ev, sizeof(ev)) != static_cast<ssize_t>(sizeof(ev))) {
      continue;
    }
    struct timespec mono {};
    clock_gettime(CLOCK_MONOTONIC, &mono);
    const int64_t now_us =
        static_cast<int64_t>(mono.tv_sec) * 1000000ll + mono.tv_nsec / 1000ll;
    if (now_us - last_refresh_us < 750000) {
      continue;
    }
    last_refresh_us = now_us;
    const bool accepted =
        frame_renderer_ != nullptr && frame_renderer_->request_pixel_reset();
    std::cerr << "bezel-redraw: double-tap -> blink/bleach/content pixel reset "
              << (accepted ? "accepted" : "unavailable") << "\n";
  }
  ::close(event_fd);
}

void EngineHost::request_shutdown() {
  if (frame_renderer_ != nullptr) {
    frame_renderer_->set_auto_maintenance_allowed(false);
  }
  event_loop_.stop();
}

void EngineHost::request_hibernate() {
  if (!config_.enable_hibernation) {
    request_shutdown();
    return;
  }
  if (frame_renderer_ != nullptr) {
    frame_renderer_->set_auto_maintenance_allowed(false);
  }
  // Complete the current platform-channel response before quiescing the
  // presenter and input threads.
  event_loop_.post_closure([this] { hibernate(); });
}

void EngineHost::request_app_switcher() {
  if (!config_.enable_hibernation ||
      system_handoff_requested_.exchange(true, std::memory_order_acq_rel)) {
    return;
  }
  if (frame_renderer_ != nullptr) {
    frame_renderer_->set_auto_maintenance_allowed(false);
  }
  event_loop_.post_closure([this] {
    std::cerr << "switcher: two-finger bottom-edge gesture accepted\n";
    // Publish only after the presenter is safely detached and the hibernated
    // marker exists.  The supervisor treats this control file as authority to
    // stop or cold-kill the foreground process; publishing first could let a
    // reset-recovery timeout strand black/white glass.
    if (!hibernate()) {
      std::cerr << "switcher: handoff cancelled; optical recovery is still "
                   "active\n";
      system_handoff_requested_.store(false, std::memory_order_release);
      return;
    }
    if (!publish_control_file("switcher", config_.app_id + "\n")) {
      std::cerr << "switcher: could not publish supervisor request\n";
      // We deliberately hibernated before making the request visible. Resume
      // immediately when publication fails so the foreground is not left
      // inert without a supervisor transition to consume it.
      (void)resume();
      return;
    }
  });
}

void EngineHost::request_home() {
  if (!config_.enable_hibernation ||
      system_handoff_requested_.exchange(true, std::memory_order_acq_rel)) {
    return;
  }
  if (frame_renderer_ != nullptr) {
    frame_renderer_->set_auto_maintenance_allowed(false);
  }
  event_loop_.post_closure([this] {
    std::cerr << "home: two-finger top-edge gesture accepted\n";
    // As with switcher, a visible control file authorizes the supervisor to
    // take this process off-panel. Do not expose it until optical ownership
    // has been released successfully.
    if (!hibernate()) {
      std::cerr << "home: handoff cancelled; optical recovery is still "
                   "active\n";
      system_handoff_requested_.store(false, std::memory_order_release);
      return;
    }
    if (!publish_control_file("home", "")) {
      std::cerr << "home: could not publish supervisor request\n";
      (void)resume();
      return;
    }
  });
}

bool EngineHost::hibernate() {
  if (!config_.enable_hibernation || hibernated_ || !running_) {
    return hibernated_;
  }
  if (frame_renderer_ != nullptr) {
    frame_renderer_->set_auto_maintenance_allowed(false);
  }
  system_ui_gate_generation_.fetch_add(1, std::memory_order_acq_rel);
  transition_lifecycle(LifecycleState::kInactive);
  transition_lifecycle(LifecycleState::kPaused);
  stop_foreground_services();
  vsync_pacer_.set_enabled(false);

  // Keep a compact, real preview for the running-app switcher. Do not replace
  // the launcher's normal preview with the switcher UI while it is acting as
  // the temporary switcher host.
  const bool launcher_is_system_host =
      config_.app_id == "dev.pluto.launcher" &&
      (std::filesystem::exists(std::filesystem::path(config_.run_dir) /
                               "switcher-active") ||
       std::filesystem::exists(std::filesystem::path(config_.run_dir) /
                               "status-active") ||
       std::filesystem::exists(std::filesystem::path(config_.run_dir) /
                               "power-menu-active"));
  if (!launcher_is_system_host && frame_renderer_ != nullptr) {
    const std::filesystem::path preview =
        std::filesystem::path(config_.run_dir) / "previews" /
        (config_.app_id + ".bmp");
    if (!frame_renderer_->write_preview_bmp(preview.string())) {
      std::cerr << "switcher: preview unavailable for " << config_.app_id
                << "\n";
    }
  }

  if (frame_renderer_ != nullptr && !frame_renderer_->detach_presenter()) {
    std::cerr << "hibernate: optical recovery incomplete; keeping presenter "
                 "attached\n";
    transition_lifecycle(LifecycleState::kInactive);
    transition_lifecycle(LifecycleState::kResumed);
    vsync_pacer_.set_enabled(config_.enable_vsync_pacer);
    start_foreground_services();
    frame_renderer_->set_auto_maintenance_allowed(true);
    return false;
  }
  if (presenter_ops_ != nullptr && presenter_ops_->close != nullptr &&
      presenter_ != nullptr) {
    presenter_ops_->close(presenter_);
  }
  presenter_ = nullptr;
  presenter_ops_ = nullptr;
  rebuild_channel_context();
  hibernated_ = true;
  if (!publish_hibernate_marker()) {
    std::cerr << "hibernate: could not publish " << hibernate_marker_path()
              << "; shutting down instead\n";
    request_shutdown();
    return false;
  }
  std::cerr << "hibernate: native resources released; awaiting resume\n";
  return true;
}

bool EngineHost::resume() {
  if (!config_.enable_hibernation || !hibernated_ || !running_) {
    return !hibernated_;
  }
  std::string error;
  if (!open_presenter(&error)) {
    std::cerr << "resume: " << error << "\n";
    request_shutdown();
    return false;
  }
  const bool defer_system_ui = should_defer_system_ui();
  if (frame_renderer_ != nullptr) {
    frame_renderer_->set_presentation_suspended(defer_system_ui);
  }
  if (defer_system_ui) {
    std::cerr << "system-ui: holding warm launcher presentation until routed\n";
  }
  if (frame_renderer_ == nullptr ||
      !frame_renderer_->attach_presenter(presenter_ops_, presenter_)) {
    std::cerr << "resume: renderer could not attach reopened presenter\n";
    if (presenter_ops_ != nullptr && presenter_ops_->close != nullptr &&
        presenter_ != nullptr) {
      presenter_ops_->close(presenter_);
    }
    presenter_ = nullptr;
    presenter_ops_ = nullptr;
    request_shutdown();
    return false;
  }
  rebuild_channel_context();
  send_display_update();
  send_window_metrics();
  transition_lifecycle(LifecycleState::kInactive);
  transition_lifecycle(LifecycleState::kResumed);
  vsync_pacer_.set_enabled(config_.enable_vsync_pacer);
  start_foreground_services();
  hibernated_ = false;
  system_handoff_requested_.store(false, std::memory_order_release);
  if (engine_ != nullptr && engine_library_.loaded()) {
    engine_library_.procs().ScheduleFrame(engine_);
  }
  if (frame_renderer_ != nullptr) {
    frame_renderer_->set_auto_maintenance_allowed(true);
  }
  // Marker removal is the supervisor acknowledgement. Publish it only after
  // every foreground resource is live and a repaint has been requested.
  std::error_code ec;
  std::filesystem::remove(hibernate_marker_path(), ec);
  if (defer_system_ui) {
    arm_system_ui_watchdog();
  }
  std::cerr << "hibernate: resumed existing Dart isolate\n";
  return true;
}

bool EngineHost::rotation_allowed(int32_t rotation) const {
  switch ((rotation % 360 + 360) % 360) {
  case 0:
    return (config_.allowed_rotation_mask & 0x1) != 0;
  case 90:
    return (config_.allowed_rotation_mask & 0x2) != 0;
  case 180:
    return (config_.allowed_rotation_mask & 0x4) != 0;
  case 270:
    return (config_.allowed_rotation_mask & 0x8) != 0;
  }
  return false;
}

void EngineHost::select_initial_auto_rotation() {
  if (!config_.auto_rotate) {
    return;
  }
  const SensorPaths paths = sensor_paths_from_env();
  const std::optional<AccelSample> sample = read_iio_accel(paths.accel_dir);
  if (!sample.has_value()) {
    std::cerr << "rotation: accelerometer unavailable; using manifest default "
              << config_.rotation << "\n";
    return;
  }
  const int32_t sensed = degrees_for_sensor_orientation(
      orientation_from_accel(sample->x, sample->y, sample->z));
  std::cerr << "rotation: accelerometer x=" << sample->x << " y=" << sample->y
            << " z=" << sample->z << " -> " << sensed << " degrees\n";
  if (sensed >= 0 && rotation_allowed(sensed)) {
    config_.rotation = sensed;
  }
}

bool EngineHost::apply_rotation(int32_t rotation) {
  rotation = (rotation % 360 + 360) % 360;
  if (!rotation_allowed(rotation) || rotation == config_.rotation) {
    return rotation == config_.rotation;
  }
  const uint64_t blocked_generation =
      pen_render_hint_generation_.fetch_add(1, std::memory_order_acq_rel) + 1;
  if (frame_renderer_ != nullptr) {
    frame_renderer_->set_pen_render_hint_generation(blocked_generation);
  }
  const int32_t previous_rotation = config_.rotation;
  config_.rotation = rotation;
  if (frame_renderer_ != nullptr &&
      !frame_renderer_->set_rotation(static_cast<uint32_t>(rotation),
                                     logical_width(config_),
                                     logical_height(config_))) {
    config_.rotation = previous_rotation;
    const uint64_t restored_generation =
        pen_render_hint_generation_.fetch_add(1, std::memory_order_acq_rel) + 1;
    frame_renderer_->set_pen_render_hint_generation(restored_generation);
    return false;
  }
  // Publish the new input transform before opening the matching even hint
  // generation. A callback that started before the gate either observes odd
  // and drops, or carries the old generation and is filtered by the mailbox.
  input_rotation_.store(rotation, std::memory_order_release);
  const uint64_t stable_generation =
      pen_render_hint_generation_.fetch_add(1, std::memory_order_acq_rel) + 1;
  if (frame_renderer_ != nullptr) {
    frame_renderer_->set_pen_render_hint_generation(stable_generation);
  }
  rebuild_channel_context();
  send_window_metrics();
  if (engine_ != nullptr && engine_library_.loaded()) {
    engine_library_.procs().ScheduleFrame(engine_);
  }
  return true;
}

void EngineHost::shutdown() {
  // Input and sensor threads send platform messages; they must be gone
  // before the engine is torn down.
  stop_foreground_services();
  if (sensor_service_) {
    sensor_service_->stop();
  }
  if (frame_renderer_) {
    frame_renderer_->set_auto_maintenance_allowed(false);
    // FrameRenderer::shutdown owns the full optical recovery window and
    // detaches only after retained content has been restored.
    frame_renderer_->shutdown();
  }
  if (engine_ != nullptr && engine_library_.loaded()) {
    vsync_pacer_.begin_shutdown();
    vsync_pacer_.flush();
    if (initialized_) {
      engine_library_.procs().Deinitialize(engine_);
    }
    // Deinitialize quiesces Flutter's internal vsync callback source. Drain
    // anything that raced the first swap, then disconnect atomically before
    // the engine object is destroyed.
    vsync_pacer_.finish_shutdown();
    engine_library_.procs().Shutdown(engine_);
    engine_ = nullptr;
  }
  if (aot_data_ != nullptr && engine_library_.loaded()) {
    engine_library_.procs().CollectAOTData(aot_data_);
    aot_data_ = nullptr;
  }
  if (presenter_ops_ != nullptr && presenter_ops_->close != nullptr &&
      presenter_ != nullptr) {
    presenter_ops_->close(presenter_);
  }
  presenter_ = nullptr;
  presenter_ops_ = nullptr;
  compositor_.reset();
  frame_renderer_.reset();
  engine_library_.unload();
  initialized_ = false;
  running_ = false;
  std::error_code ec;
  std::filesystem::remove(hibernate_marker_path(), ec);
  hibernated_ = false;
}

bool EngineHost::send_window_metrics() {
  if (engine_ == nullptr || !engine_library_.loaded()) {
    return false;
  }
  const FlutterWindowMetricsEvent metrics = window_metrics_for_config(config_);
  return engine_library_.procs().SendWindowMetricsEvent(engine_, &metrics) ==
         kSuccess;
}

bool EngineHost::legacy_surface_present(void *, const void *, size_t, size_t) {
  return true;
}

void EngineHost::platform_message_callback(
    const FlutterPlatformMessage *message, void *user_data) {
  auto *self = static_cast<EngineHost *>(user_data);
  if (self == nullptr || message == nullptr) {
    return;
  }
  self->channels_.handle_message(
      *message, [self, handle = message->response_handle](
                    const PlatformResponse &response) {
        if (handle == nullptr || self->engine_ == nullptr ||
            !self->engine_library_.loaded()) {
          return;
        }
        const uint8_t *data = response.empty() ? nullptr : response.data();
        self->engine_library_.procs().SendPlatformMessageResponse(
            self->engine_, handle, data, response.size());
      });
}

void EngineHost::vsync_callback(void *user_data, intptr_t baton) {
  auto *self = static_cast<EngineHost *>(user_data);
  if (self != nullptr) {
    self->vsync_pacer_.request(baton);
  }
}

void EngineHost::log_message_callback(const char *tag, const char *message,
                                      void *) {
  std::cerr << (tag == nullptr ? "flutter" : tag) << ": "
            << (message == nullptr ? "" : message) << "\n";
}

void EngineHost::pre_engine_restart_callback(void *user_data) {
  auto *self = static_cast<EngineHost *>(user_data);
  if (self != nullptr) {
    self->lifecycle_ = LifecycleStateMachine();
  }
}

void EngineHost::presenter_completion_callback(uint64_t frame_id,
                                               void *user_data) {
  auto *self = static_cast<EngineHost *>(user_data);
  if (self != nullptr && self->frame_renderer_ != nullptr) {
    // Presenter-thread context (presenter.h:96-99): may only enqueue.
    // notify_present_complete is enqueue-only; the presenter-loop tick
    // drains completions in arrival order.
    self->frame_renderer_->notify_present_complete(frame_id);
  }
}

bool EngineHost::open_presenter(std::string *error) {
  presenter_ops_ = pluto_presenter_by_name(config_.presenter_name.c_str());
  if (presenter_ops_ == nullptr) {
    if (error != nullptr) {
      *error =
          "startup step 4 failed: unknown presenter " + config_.presenter_name;
    }
    return false;
  }
  PlutoPresenterConfig presenter_config{};
  presenter_config.struct_size = sizeof(presenter_config);
  presenter_config.backend_name = config_.presenter_name.c_str();
  presenter_config.options = config_.presenter_options.c_str();
  presenter_config.on_complete = &EngineHost::presenter_completion_callback;
  presenter_config.user_data = this;
  const PlutoStatus status =
      presenter_ops_->open(&presenter_config, &presenter_);
  if (status != kPlutoStatusOk) {
    if (error != nullptr) {
      *error = "startup step 4 failed: presenter open returned " +
               std::to_string(static_cast<int>(status));
    }
    return false;
  }
  presenter_display_info_valid_ = false;
  if (presenter_ops_->info != nullptr) {
    PlutoDisplayInfo info{};
    info.struct_size = sizeof(info);
    const PlutoStatus info_status = presenter_ops_->info(presenter_, &info);
    std::string geometry_error;
    if (info_status != kPlutoStatusOk ||
        !apply_presenter_display_info(info, &config_, &geometry_error)) {
      if (presenter_ops_->close != nullptr) {
        presenter_ops_->close(presenter_);
      }
      presenter_ = nullptr;
      presenter_ops_ = nullptr;
      if (error != nullptr) {
        *error = info_status != kPlutoStatusOk
                     ? "startup step 4 failed: presenter info returned " +
                           std::to_string(static_cast<int>(info_status))
                     : "startup step 4 failed: " + geometry_error;
      }
      return false;
    }
    presenter_display_info_ = info;
    presenter_display_info_valid_ = true;
  }
  rebuild_channel_context();
  return true;
}

bool EngineHost::setup_renderer(std::string *error) {
  FrameRendererConfig renderer_config{};
  renderer_config.width = logical_width(config_);
  renderer_config.height = logical_height(config_);
  renderer_config.rotation = static_cast<uint32_t>(config_.rotation);
  renderer_config.format = config_.pixel_format;
  renderer_config.presenter_ops = presenter_ops_;
  renderer_config.presenter = presenter_;
  renderer_config.ready_file_path = config_.ready_file_path;
  renderer_config.health_file_path = config_.health_file_path;
  renderer_config.start_presenter_thread = true;
  renderer_config.presenter_pen_focus_from_host =
      presenter_has_pen_focus_hook(presenter_ops_);
  // Automatic optical hygiene requires both waveform-class control and real
  // device completion. Select it from behavior instead of a model or backend
  // name so every native driver follows the same scheduler path.
  renderer_config.pigment_hygiene_supported =
      presenter_display_info_valid_ &&
      presenter_display_info_.controls_refresh_class &&
      presenter_display_info_.reports_completion;
  renderer_config.enable_auto_ghostbuster =
      renderer_config.pigment_hygiene_supported;
  renderer_config.set_flutter_rendering_paused = [this](bool paused) {
    vsync_pacer_.set_rendering_paused(paused);
  };
  renderer_config.on_presenter_device_lost = [this] {
    // present() runs under the renderer mutex. Keep this edge enqueue-only;
    // shutdown executes on the platform loop after the presenter stack has
    // unwound, allowing the supervisor to relaunch through cold clear.
    event_loop_.post_closure([this] {
      std::cerr << "presenter: device lost; stopping for cold supervisor "
                   "restart\n";
      request_shutdown();
    });
  };
  renderer_config.on_health_file_failure = [this] {
    // The record is the supervisor's proof that this exact renderer process
    // and presenter loop are advancing. Stop rather than running unmonitored;
    // the supervisor's independent stale deadline remains the final backstop.
    event_loop_.post_closure([this] {
      std::cerr << "renderer: health publication failed; stopping\n";
      request_shutdown();
    });
  };
  frame_renderer_ = std::make_unique<FrameRenderer>(renderer_config);
  if (!frame_renderer_->valid()) {
    if (error != nullptr) {
      *error = "startup step 5 failed: renderer initialization failed";
    }
    return false;
  }
  compositor_ = std::make_unique<SoftwareCompositor>(config_.pixel_format,
                                                     frame_renderer_.get());
  flutter_compositor_ = compositor_->flutter_compositor();
  return true;
}

bool EngineHost::assemble_project_args(std::string *error) {
  if (config_.assets_path.empty() || config_.icu_data_path.empty()) {
    if (error != nullptr) {
      *error = "startup step 7 failed: assets and ICU paths are required";
    }
    return false;
  }

  engine_argv_storage_.clear();
  engine_argv_storage_.push_back("pluto-embedder");
  if (config_.mode == EngineMode::kDebug) {
    engine_argv_storage_.push_back("--vm-service-port=" +
                                   std::to_string(config_.vm_service_port));
    engine_argv_storage_.push_back("--vm-service-host=" +
                                   config_.vm_service_host);
    if (config_.insecure_vm_service) {
      engine_argv_storage_.push_back("--disable-service-auth-codes");
    }
  }
  engine_argv_.clear();
  for (const std::string &arg : engine_argv_storage_) {
    engine_argv_.push_back(arg.c_str());
  }

  dart_entrypoint_argv_.clear();
  for (const std::string &arg : config_.dart_entrypoint_args) {
    dart_entrypoint_argv_.push_back(arg.c_str());
  }

  renderer_config_ = {};
  renderer_config_.type = kSoftware;
  renderer_config_.software.struct_size = sizeof(FlutterSoftwareRendererConfig);
  renderer_config_.software.surface_present_callback = &legacy_surface_present;

  project_args_ = {};
  project_args_.struct_size = sizeof(project_args_);
  project_args_.assets_path = config_.assets_path.c_str();
  project_args_.icu_data_path = config_.icu_data_path.c_str();
  project_args_.command_line_argc = static_cast<int>(engine_argv_.size());
  project_args_.command_line_argv = engine_argv_.data();
  project_args_.platform_message_callback = &platform_message_callback;
  project_args_.custom_task_runners = event_loop_.custom_task_runners();
  project_args_.compositor = &flutter_compositor_;
  project_args_.vsync_callback =
      config_.enable_vsync_pacer ? &vsync_callback : nullptr;
  project_args_.log_message_callback = &log_message_callback;
  project_args_.log_tag = "pluto";
  project_args_.shutdown_dart_vm_when_done = true;
  project_args_.dart_entrypoint_argc =
      static_cast<int>(dart_entrypoint_argv_.size());
  project_args_.dart_entrypoint_argv = dart_entrypoint_argv_.data();
  project_args_.dart_old_gen_heap_size =
      config_.mode == EngineMode::kDebug ? 256 : 128;
  project_args_.on_pre_engine_restart_callback = &pre_engine_restart_callback;

  if (config_.mode != EngineMode::kDebug) {
    FlutterEngineAOTDataSource source{};
    source.type = kFlutterEngineAOTDataSourceTypeElfPath;
    source.elf_path = config_.aot_elf_path.c_str();
    const FlutterEngineResult result =
        engine_library_.procs().CreateAOTData(&source, &aot_data_);
    if (result != kSuccess) {
      if (error != nullptr) {
        *error = "startup step 7 failed: CreateAOTData failed for " +
                 config_.aot_elf_path;
      }
      return false;
    }
    project_args_.aot_data = aot_data_;
  }
  return true;
}

bool EngineHost::check_mode_payload(std::string *error) {
  const bool engine_is_aot =
      engine_library_.procs().RunsAOTCompiledDartCode != nullptr &&
      engine_library_.procs().RunsAOTCompiledDartCode();
  if (config_.mode == EngineMode::kDebug) {
    if (engine_is_aot) {
      if (error != nullptr) {
        *error = "startup step 3 failed: --debug requires a JIT engine; "
                 "use the matching debug engine for hot reload";
      }
      return false;
    }
    if (!config_.assets_path.empty() &&
        !file_exists(join_path(config_.assets_path, "kernel_blob.bin"))) {
      if (error != nullptr) {
        *error = "startup step 3 failed: --debug requires JIT kernel " +
                 join_path(config_.assets_path, "kernel_blob.bin");
      }
      return false;
    }
    return true;
  }
  if (!engine_is_aot) {
    if (error != nullptr) {
      *error = "startup step 3 failed: --" +
               std::string(engine_mode_name(config_.mode)) +
               " requires an AOT engine; use the matching " +
               engine_mode_name(config_.mode) +
               " engine, or pass --debug explicitly for JIT/hot reload";
    }
    return false;
  }
  if (!file_exists(config_.aot_elf_path)) {
    if (error != nullptr) {
      *error = "startup step 3 failed: AOT app ELF missing: " +
               config_.aot_elf_path +
               " (canonical bundle layout is lib/app.so; override with "
               "--aot-elf=<path> only for a custom layout)";
    }
    return false;
  }
  return true;
}

void EngineHost::rebuild_channel_context() {
  ChannelContext context{};
  context.device_model = device_identity_.model;
  context.device_codename = device_identity_.codename;
  context.panel_width = config_.panel_width;
  context.panel_height = config_.panel_height;
  context.dpi = config_.dpi;
  context.is_color = true;
  if (presenter_display_info_valid_) {
    context.is_color = presenter_display_info_.is_color;
  }
  context.rotation = config_.rotation;
  context.pixel_format =
      config_.pixel_format == kPlutoPixelFormatGray8 ? "gray8" : "rgb565";
  context.presenter_name = config_.presenter_name;
  context.request_shutdown = [this] { request_shutdown(); };
  if (config_.enable_hibernation) {
    context.request_hibernate = [this] { request_hibernate(); };
  }
  context.request_full_refresh = [this] {
    return frame_renderer_ != nullptr &&
           frame_renderer_->request_full_refresh();
  };
  context.request_ghost_control = [this](const std::string &mode) {
    if (frame_renderer_ == nullptr) {
      return false;
    }
    GhostControlMode control = GhostControlMode::kBlinkNow;
    if (mode == "blinkLater") {
      control = GhostControlMode::kBlinkLater;
    } else if (mode == "bleachNow") {
      control = GhostControlMode::kBleachNow;
    } else if (mode == "factoryReset") {
      control = GhostControlMode::kFactoryReset;
    }
    return frame_renderer_->request_ghost_control(control);
  };
  context.system_ui_ready = [this] { return reveal_system_ui(); };
  context.set_rotation = [this](int32_t rotation) { apply_rotation(rotation); };
  channels_.set_context(std::move(context));
}

bool EngineHost::reveal_system_ui() {
  if (frame_renderer_ == nullptr) {
    return false;
  }
  std::error_code ec;
  std::filesystem::remove(
      std::filesystem::path(config_.run_dir) / "system-ui-reset", ec);
  if (frame_renderer_->arm_presentation_resume()) {
    std::cerr << "system-ui: routed frame ready; revealing on next frame\n";
    if (engine_ != nullptr && engine_library_.loaded()) {
      engine_library_.procs().ScheduleFrame(engine_);
    }
    return true;
  }
  return frame_renderer_->request_full_refresh();
}

bool EngineHost::should_defer_system_ui() const {
  if (config_.app_id != "dev.pluto.launcher") {
    return false;
  }
  const std::filesystem::path run_dir(config_.run_dir);
  return std::filesystem::exists(run_dir / "switcher-active") ||
         std::filesystem::exists(run_dir / "status-active") ||
         std::filesystem::exists(run_dir / "power-menu-active") ||
         (config_.enable_hibernation &&
          std::filesystem::exists(run_dir / "system-ui-reset"));
}

void EngineHost::arm_system_ui_watchdog() {
  const uint64_t generation =
      system_ui_gate_generation_.fetch_add(1, std::memory_order_acq_rel) + 1;
  event_loop_.post_closure_at(
      event_loop_.now_nanos() + 2000000000ull, [this, generation] {
        if (system_ui_gate_generation_.load(std::memory_order_acquire) !=
                generation ||
            hibernated_ || !running_ || frame_renderer_ == nullptr) {
          return;
        }
        if (frame_renderer_->force_presentation_resume()) {
          std::cerr << "system-ui: reveal watchdog forced current full frame\n";
        }
      });
}

} // namespace pluto
