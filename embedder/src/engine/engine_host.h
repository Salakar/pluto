#ifndef PLUTO_ENGINE_ENGINE_HOST_H_
#define PLUTO_ENGINE_ENGINE_HOST_H_

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <thread>
#include <vector>

#include "channels/channel_registry.h"
#include "channels/pen_channels.h"
#include "channels/sensor_channels.h"
#include "compositor/software_compositor.h"
#include "engine/device_identity.h"
#include "engine/engine_loader.h"
#include "input/ink_thread.h"
#include "input/touch.h"
#include "input/transform.h"
#include "runtime/direct_control_server.h"
#include "runtime/event_loop.h"
#include "runtime/lifecycle.h"
#include "runtime/vsync_pacer.h"

namespace pluto {

enum class EngineMode {
  kDebug,
  kProfile,
  kRelease,
};

// Exact Ink controls exposed through Flutter semantics. These labels are
// intentionally app-owned and action-specific: no coordinate or arbitrary
// semantics endpoint is exposed to the device protocol.
enum class DirectInkSemanticsTarget : std::uint8_t {
  kCanvasReady,
  kNewArtwork,
  kCreate,
};

struct DirectInkSemanticsNode {
  FlutterViewId view_id = 0;
  std::uint64_t node_id = 0;
  std::uint64_t generation = 0;
};

enum class DirectInkSemanticsWait : std::uint8_t {
  kFound,
  kTimedOut,
  kAmbiguous,
  kInactive,
};

// Thread-safe bridge between Flutter's platform-thread semantics callback and
// the root-local acceptance worker. Each action must come from a target seen
// after the caller's generation boundary, so stale gallery/editor nodes cannot
// satisfy a transition.
class DirectInkSemanticsState {
public:
  std::uint64_t begin();
  void end();
  void update(const FlutterSemanticsUpdate2 *update);
  std::uint64_t generation() const;
  DirectInkSemanticsWait
  wait_for_any(std::span<const DirectInkSemanticsTarget> targets,
               std::uint64_t after_generation,
               std::chrono::milliseconds timeout,
               DirectInkSemanticsTarget *matched, DirectInkSemanticsNode *node);

private:
  struct Slot {
    DirectInkSemanticsNode node;
    bool ambiguous = false;
  };

  mutable std::mutex mutex_;
  std::condition_variable changed_;
  std::array<Slot, 3> slots_{};
  std::uint64_t generation_ = 0;
  bool active_ = false;
};

using DirectInkSemanticsToggle = std::function<bool(bool)>;
using DirectInkSemanticsTap =
    std::function<bool(const DirectInkSemanticsNode &)>;

// Drives only Ink's exact new-artwork/create semantic actions and does not
// return success until the editor's Back-to-gallery control proves a real
// canvas is mounted. An already-open editor succeeds without an action.
bool prepare_direct_ink_canvas_from_semantics(
    DirectInkSemanticsState *state, const DirectInkSemanticsToggle &toggle,
    const DirectInkSemanticsTap &tap, std::chrono::milliseconds timeout,
    std::size_t *action_count, DirectControlFailure *failure);

struct DirectInkPresentationProof {
  std::uint64_t surface_generation = 0;
  std::uint64_t frame_id = 0;
};

// Native presentation proof used by the bounded Ink acceptance flow. It must
// open an optical transaction before the semantic route changes, establish a
// post-semantics Flutter frame fence, and then complete one exact
// retained-surface Full presenter frame. Cancellation releases any queued
// route work when semantics cannot reach the canvas.
struct DirectInkPresentationTracker {
  std::function<bool()> begin;
  std::function<void()> cancel;
  std::function<bool(std::chrono::milliseconds, DirectInkPresentationProof *)>
      prove;
};

// Couples the exact Ink semantics flow to a native presenter receipt. The
// proof is mandatory even for an already-mounted editor (actionCount == 0).
bool prepare_direct_ink_canvas_with_presentation_receipt(
    DirectInkSemanticsState *state, const DirectInkSemanticsToggle &toggle,
    const DirectInkSemanticsTap &tap,
    const DirectInkPresentationTracker &presentation,
    std::chrono::milliseconds semantics_timeout,
    std::chrono::milliseconds presentation_timeout, std::size_t *action_count,
    DirectInkPresentationProof *proof, DirectControlFailure *failure);

struct EngineHostConfig {
  // Product AOT is the safe default. JIT is reserved for callers that
  // explicitly opt in to debug mode (normally for the hot-reload loop).
  EngineMode mode = EngineMode::kRelease;
  std::string engine_path;
  std::string bundle_path;
  std::string assets_path;
  std::string icu_data_path;
  std::string aot_elf_path;
  // Optional first-present readiness marker. The CLI and initialize() both
  // require an absolute path; FrameRenderer publishes it atomically after
  // the first presenter acceptance.
  std::string ready_file_path;
  // Optional native renderer liveness record. The supervisor supplies a
  // launch-nonce-specific absolute path and requires progress from the real
  // presenter health loop after a completed frame.
  std::string health_file_path;
  std::string presenter_name = "null";
  std::string presenter_options;
  PlutoPixelFormat pixel_format = kPlutoPixelFormatRgb565;
  int32_t panel_width = 954;
  int32_t panel_height = 1696;
  int32_t dpi = 264;
  double dpr = 1.65;
  // Set only by an explicit caller override. Otherwise the presenter DPI is
  // authoritative and DPR is derived using Flutter's 160-DPI baseline.
  bool dpr_explicitly_set = false;
  int32_t rotation = 0;
  // Auto mode samples the accelerometer once before renderer setup. Runtime
  // posture changes never restart the app: repeated presenter initialization
  // is visibly destructive on e-ink. Bit 0/1/2/3 allow 0/90/180/270 degrees
  // respectively (derived from the app manifest).
  bool auto_rotate = false;
  uint8_t allowed_rotation_mask = 0x1;
  std::string vm_service_host = "0.0.0.0";
  int32_t vm_service_port = 38383;
  bool insecure_vm_service = false;
  bool enable_vsync_pacer = true;
  // E-ink frame-rate cap (ms per frame). Flutter free-running at 60fps burns
  // ~1.4 of the 2 A55 cores in JIT and starves the panel engine; the panel
  // realistically shows content far slower, so we pace Flutter here. Default
  // 24ms (~42fps): with early-cancel retargeting the panel absorbs the
  // extra sustained frames, and the on-device A/B (session 5, release AOT)
  // measured +20% embedder CPU during active interaction (12.6% -> 15.1%
  // of one core) with flat thermals — cheap for visibly smoother motion
  // sampling. Env PLUTO_FRAME_MS overrides (0 = uncapped).
  int32_t frame_interval_ms = 24;
  bool run_event_loop = true;
  int32_t run_duration_ms = 0;
  bool synthetic_tap = false;
  double synthetic_tap_x = 0.0;
  double synthetic_tap_y = 0.0;
  int32_t synthetic_tap_delay_ms = 1000;
  std::vector<std::string> dart_entrypoint_args;
  // Full multitouch input: read the evdev touchscreen and inject Flutter
  // pointer events (one device per slot; drag, palm rejection via
  // TouchTracker).
  bool enable_touch = false;
  std::string touch_device_path;
  // High-precision pen input: read the marker evdev device, stream wire
  // events on pluto/pen/events, and inject Flutter stylus pointer events.
  bool enable_pen = false;
  std::string pen_device_path;
  // LIS2DW12 bezel double-tap -> BlinkNow followed by BleachNow: strong Fast
  // black/white rails, then a balanced Full retained-content restore. The app
  // and Dart isolate stay foreground throughout.
  bool enable_bezel_redraw = false;
  std::string bezel_redraw_iio_path;    // e.g. /dev/iio:device3
  std::string bezel_redraw_enable_path; // the doubletap_en sysfs
  std::string run_dir = "/run/pluto";
  // Stable process identity supplied by the supervisor. Used for switcher
  // routing and preview filenames; never accepted from an app method call.
  std::string app_id;
  // Keep the Flutter engine and Dart heap resident across app switches. The
  // supervisor freezes the process only after the hibernated marker proves
  // display/input ownership has been released.
  bool enable_hibernation = false;
};

class EngineHost {
public:
  explicit EngineHost(EngineHostConfig config);
  EngineHost(const EngineHost &) = delete;
  EngineHost &operator=(const EngineHost &) = delete;
  ~EngineHost();

  bool initialize(std::string *error);
  bool run(std::string *error);
  void request_shutdown();
  void request_hibernate();
  void request_app_switcher();
  void request_home();
  bool hibernate();
  bool resume();
  void shutdown();
  bool send_window_metrics();

  const EngineHostConfig &config() const { return config_; }
  ChannelRegistry &channels() { return channels_; }
  EventLoop &event_loop() { return event_loop_; }

private:
  static bool legacy_surface_present(void *user_data, const void *allocation,
                                     size_t row_bytes, size_t height);
  static void platform_message_callback(const FlutterPlatformMessage *message,
                                        void *user_data);
  static void vsync_callback(void *user_data, intptr_t baton);
  static void log_message_callback(const char *tag, const char *message,
                                   void *user_data);
  static void pre_engine_restart_callback(void *user_data);
  static void update_semantics_callback(const FlutterSemanticsUpdate2 *update,
                                        void *user_data);
  static void presenter_completion_callback(uint64_t frame_id, void *user_data);

  void resolve_paths();
  bool send_display_update();
  bool send_default_locale();
  bool send_synthetic_tap(double x, double y);
  bool transition_lifecycle(LifecycleState state);
  // Thread-safe once the engine is initialized (fire-and-forget message to
  // the Dart side of `channel`).
  bool send_channel_message(const std::string &channel,
                            const std::vector<uint8_t> &message);
  void install_channel_senders();
  void start_foreground_services();
  void stop_foreground_services();
  bool
  capture_direct_screenshot(DirectScreenshotSurface surface,
                            const std::optional<std::string> &requested_app_id,
                            DirectScreenshotCapture *capture,
                            DirectControlFailure *failure);
  bool send_direct_switcher_preview_tap(const std::string &requested_app_id,
                                        DirectPointerResult *result,
                                        DirectControlFailure *failure);
  bool send_direct_ink_stroke(const std::string &requested_app_id,
                              std::int64_t expected_pid,
                              DirectPointerResult *result,
                              DirectControlFailure *failure);
  bool send_direct_prepare_ink_canvas(const std::string &requested_app_id,
                                      std::int64_t expected_pid,
                                      DirectInkCanvasResult *result,
                                      DirectControlFailure *failure);
  bool schedule_frame_on_platform_thread(
      std::chrono::steady_clock::time_point deadline,
      std::uint64_t *pre_schedule_surface_generation);
  bool prove_direct_ink_presentation(std::chrono::milliseconds timeout,
                                     std::uint64_t proof_token,
                                     DirectInkPresentationProof *proof);
  std::string hibernate_marker_path() const;
  bool publish_hibernate_marker() const;
  bool publish_control_file(const std::string &leaf,
                            const std::string &content) const;
  void touch_input_loop();
  void start_ink_thread();
  // Ink-thread context: forwards one tracker output to Flutter (stylus
  // device 500, phase sequencing, CLOCK_MONOTONIC us), the pen ring and the
  // pen service — the pen dispatch contract, unchanged from the retired
  // pen_input_loop.
  void dispatch_pen_output(const PenTrackerOutput &output);
  void bezel_redraw_loop();
  bool open_presenter(std::string *error);
  bool setup_renderer(std::string *error);
  bool assemble_project_args(std::string *error);
  bool check_mode_payload(std::string *error);
  void rebuild_channel_context();
  bool rotation_allowed(int32_t rotation) const;
  void select_initial_auto_rotation();
  bool apply_rotation(int32_t rotation);
  bool reveal_system_ui();
  bool should_defer_system_ui() const;
  void arm_system_ui_watchdog();

  EngineHostConfig config_;
  RemarkableDeviceIdentity device_identity_;
  EngineLibrary engine_library_;
  FlutterEngine engine_ = nullptr;
  FlutterEngineAOTData aot_data_ = nullptr;
  const PlutoPresenterOps *presenter_ops_ = nullptr;
  PlutoPresenter *presenter_ = nullptr;
  PlutoDisplayInfo presenter_display_info_{};
  bool presenter_display_info_valid_ = false;
  std::unique_ptr<FrameRenderer> frame_renderer_;
  std::unique_ptr<SoftwareCompositor> compositor_;
  FlutterCompositor flutter_compositor_{};
  FlutterRendererConfig renderer_config_{};
  FlutterProjectArgs project_args_{};
  std::vector<std::string> engine_argv_storage_;
  std::vector<const char *> engine_argv_;
  std::vector<const char *> dart_entrypoint_argv_;
  ChannelRegistry channels_;
  EventLoop event_loop_;
  std::unique_ptr<DirectControlServer> direct_control_server_;
  DirectInkSemanticsState direct_ink_semantics_;
  VsyncPacer vsync_pacer_;
  LifecycleStateMachine lifecycle_;
  bool initialized_ = false;
  bool running_ = false;
  bool hibernated_ = false;
  std::thread touch_thread_;
  std::atomic<bool> touch_stop_{false};
  // Read by the evdev thread so the physical bottom edge follows live
  // portrait/landscape changes without restarting the Flutter isolate.
  std::atomic<int32_t> input_rotation_{0};
  PenTouchArbiter pen_touch_arbiter_;
  SystemEdgeGestureRecognizer system_edge_gesture_;
  std::atomic<bool> system_handoff_requested_{false};
  std::atomic<uint64_t> system_ui_gate_generation_{0};
  // The input thread owns the pen device, forwards pointer events, and emits
  // renderer trajectory hints without drawing. The pen_* members below are
  // ink-thread-confined dispatch state (written by the on_device_open hook
  // before any tracker output arrives, then only the ink thread reads
  // them).
  std::unique_ptr<InkThread> ink_thread_;
  AffineTransform pen_calib_{};
  double pen_pressure_max_ = 4095.0;
  uint32_t pen_ring_seq_ = 0;
  uint64_t pen_render_hint_seq_ = 0;
  // Even values are stable input/render coordinate generations; odd values
  // gate hint publication while a live rotation rebuilds presenter geometry.
  std::atomic<uint64_t> pen_render_hint_generation_{0};
  uint64_t pen_rate_samples_ = 0;
  int64_t pen_rate_window_start_us_ = 0;
  std::thread bezel_redraw_thread_;
  std::atomic<bool> bezel_redraw_stop_{false};
  std::unique_ptr<SensorService> sensor_service_;
  std::unique_ptr<PenService> pen_service_;
};

const char *engine_mode_name(EngineMode mode);

// Validates and adopts the presenter's physical geometry before renderer and
// Flutter initialization. On failure config is left unchanged.
bool apply_presenter_display_info(const PlutoDisplayInfo &info,
                                  EngineHostConfig *config, std::string *error);

// Shared by production delivery and focused geometry regression tests.
FlutterWindowMetricsEvent
window_metrics_for_config(const EngineHostConfig &config);

inline constexpr std::size_t kDirectInkStrokeEventCount = 24;
inline constexpr std::size_t kDirectTouchTapEventCount = 4;

// Builds the normal add/down/up/remove touch sequence used by the synthetic
// host option and the switcher acceptance control.
bool build_direct_touch_tap_events(
    double x, double y, std::size_t started_us,
    std::array<FlutterPointerEvent, kDirectTouchTapEventCount> *events);

// Builds the deterministic stylus packet used by the root-local acceptance
// control. Keeping geometry and phase sequencing pure makes the real pointer
// path independently testable without a Flutter engine.
bool build_direct_ink_stroke_events(
    std::int32_t width, std::int32_t height, std::size_t started_us,
    std::array<FlutterPointerEvent, kDirectInkStrokeEventCount> *events);

// Reads the first selectable app from the supervisor-owned switcher state.
// The acceptance control uses this as an authorization gate before injecting a
// center tap. Symlinks, non-regular/unowned/multiply-linked files, malformed
// ids, a missing target, and a same-as-origin target all fail closed.
std::optional<std::string>
read_direct_switcher_target(const std::string &run_dir);

} // namespace pluto

#endif // PLUTO_ENGINE_ENGINE_HOST_H_
