#ifndef PLUTO_COMPOSITOR_SOFTWARE_COMPOSITOR_H_
#define PLUTO_COMPOSITOR_SOFTWARE_COMPOSITOR_H_

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "compositor/backing_store_pool.h"
#include "flutter/embedder.h"
#include "pluto/presenter.h"
#include "renderer/abi_bridge.h"
#include "renderer/auto_ghostbuster.h"
#include "renderer/classify_ladder.h"
#include "renderer/frame_ledger.h"
#include "renderer/guard_band.h"
#include "renderer/ledgers.h"
#include "renderer/pen_render_policy.h"
#include "renderer/region_scheduler.h"
#include "renderer/renderer_config.h"
#include "renderer/renderer_handoff.h"
#include "renderer/scroll_detect.h"
#include "renderer/settle_policy.h"
#include "renderer/tile_pass.h"

namespace pluto {

class HealthFilePublisher;

// Mirrors the stock reMarkable GhostControlMode vocabulary. Production
// BlinkNow/BlinkLater append the complete BleachNow rail policy to prevent
// residual yellowing. No operation selects the slow INIT/mode-0 waveform.
enum class GhostControlMode : uint8_t {
  kBlinkNow,
  kBlinkLater,
  kBleachNow,
  kFactoryReset,
};

struct PlutoFramePacket {
  const void *pixels = nullptr;
  size_t row_bytes = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  PlutoPixelFormat format = kPlutoPixelFormatRgb565;
  bool did_update = false;
  uint64_t presentation_time_ns = 0;
  const PlutoRect *paint_bounds = nullptr;
  size_t paint_bounds_count = 0;
};

// Bounded lock-free MPSC queue carrying presenter completions to the
// presenter-loop tick. Completion callbacks run on internal presenter threads
// and may only enqueue -- never block or re-enter (presenter.h:96-99) -- so
// this is the only structure they touch. Drained in arrival (ticket) order.
class CompletionQueue {
public:
  CompletionQueue();

  // Any thread. Returns false when full; the caller counts the drop.
  bool push(uint64_t frame_id);
  // Single consumer only (the presenter-loop tick, under FrameRenderer's
  // mutex). Returns false when empty.
  bool pop(uint64_t *out_frame_id);
  // TEST-ONLY observation. The dequeue side must be externally serialized with
  // pop(); FrameRenderer does so with its mutex.
  size_t size_approx_for_testing() const;

private:
  // Power of two and at least twice RegionScheduler's 512-request in-flight
  // ceiling. A PixelEngine scan boundary may publish every subscriber before
  // the renderer thread drains once; none may be lost to a smaller mailbox.
  static constexpr size_t k_capacity = 1024;
  struct Slot {
    std::atomic<uint64_t> sequence{0};
    uint64_t frame_id = 0;
  };
  std::array<Slot, k_capacity> slots_;
  std::atomic<uint64_t> enqueue_pos_{0};
  uint64_t dequeue_pos_ = 0;
};

struct FrameRendererConfig {
  using MonotonicNowForTesting = uint64_t (*)(void *context);

  uint32_t width = 954;
  uint32_t height = 1696;
  uint32_t rotation = 0;
  PlutoPixelFormat format = kPlutoPixelFormatRgb565;
  const PlutoPresenterOps *presenter_ops = nullptr;
  PlutoPresenter *presenter = nullptr;
  // Absolute path atomically published after the first successful
  // presenter present() return. Empty disables readiness publication.
  std::string ready_file_path;
  // Absolute launch-nonce-specific liveness path. When set, the renderer
  // requires real presenter completions and a presenter-loop health probe.
  std::string health_file_path;
  bool start_presenter_thread = true;
  // Production EngineHost publishes native-panel proximity metadata directly
  // before Flutter pointer delivery. When true, FrameRenderer keeps only its
  // logical scheduler reservation and never becomes a second backend
  // publisher; standalone renderer tests/default embedders retain fallback.
  bool presenter_pen_focus_from_host = false;
  // Runs the present bridge (settled levels / settled color -> presenter
  // surface) at dispatch. Disable only in tests that inspect raw engine
  // bytes at the presenter boundary: the bridge is bypassed and raw mirror
  // bytes pass through.
  bool enable_present_bridge = true;
  // Renderer constants (tile size, chroma floor).
  RendererConfig renderer_config = {};
  // Native automatic optical maintenance. The physical SWTCON Move backend
  // needs pigment hygiene even though it truthfully reports grayscale render
  // capability, so this capability is deliberately separate from is_color.
  bool enable_auto_ghostbuster = true;
  bool pigment_hygiene_supported = false;
  AutoGhostbusterConfig auto_ghostbuster_config = {};
  // Render-only pause hook. Called at the first optical rail and after the
  // retained-content restore completes; it must be non-blocking/thread-safe.
  std::function<void(bool)> set_flutter_rendering_paused;
  // Fatal presenter edge. Called at most once when present() reports
  // kPlutoStatusDeviceLost; it must be non-blocking/thread-safe because the
  // renderer mutex is held at this boundary. Production posts shutdown onto
  // the platform event loop so the supervisor can restart on the cold path.
  std::function<void()> on_presenter_device_lost;
  // Fatal atomic-publication edge for the supervisor liveness record.
  // Production posts shutdown onto the platform loop.
  std::function<void()> on_health_file_failure;
  // TEST-ONLY deterministic policy clock. Timeout/fence accounting always
  // keeps the real steady clock; this hook controls only timestamps consumed
  // by renderer classification, debt, quiescence, and scheduling decisions.
  MonotonicNowForTesting monotonic_now_for_testing = nullptr;
  void *monotonic_now_context_for_testing = nullptr;
};

// Renderer-owned screenshot sources. Logical preserves the latest complete
// Flutter surface in its native pixel format; post-dither exposes the settled
// level ledger as a tightly packed Gray8 surface.
enum class RendererSnapshotSurface : uint8_t {
  kLogical,
  kPostDither,
};

struct RendererSnapshot {
  std::vector<uint8_t> pixels;
  uint32_t width = 0;
  uint32_t height = 0;
  size_t stride_bytes = 0;
  PlutoPixelFormat format = kPlutoPixelFormatRgb565;
};

// Fixed-capacity lock-free handoff from the single pen-input publisher to the
// renderer consumer. Each publication is protected by a real versioned
// seqlock and every payload word is atomic, so a reader can never combine
// point N with state N+1 (and TSan sees no speculative data race). History is
// retained until matching app damage consumes it; this keeps queued Flutter
// pointer frames correlated even when hover outruns rasterization.
class PenRenderHintMailbox {
public:
  static constexpr size_t kCapacity = 32;

  struct Entry {
    PenRenderHintSnapshot hint{};
    uint64_t ticket = 0;
  };

  struct Batch {
    std::array<Entry, kCapacity> entries{};
    size_t count = 0;
    uint64_t epoch = 0;
  };

  PenRenderHintMailbox() = default;
  PenRenderHintMailbox(const PenRenderHintMailbox &) = delete;
  PenRenderHintMailbox &operator=(const PenRenderHintMailbox &) = delete;

  // Single high-rate publisher. clear(), snapshot(), and acknowledge() may
  // run concurrently from other threads and never take a lock.
  bool publish(const PenRenderHintSnapshot &hint);
  bool publish(const PenRenderHintSnapshot &hint, uint64_t generation);
  Batch snapshot() const;
  void acknowledge(uint64_t ticket, uint64_t epoch);
  void clear();
  void set_generation(uint64_t generation);
  uint64_t overwritten_unconsumed() const {
    return overwritten_unconsumed_.load(std::memory_order_relaxed);
  }

private:
  struct AtomicEntry {
    std::atomic<int64_t> timestamp_us{0};
    std::atomic<uint64_t> previous{0};
    std::atomic<uint64_t> current{0};
    std::atomic<uint64_t> predicted{0};
    std::atomic<uint64_t> sequence{0};
    std::atomic<uint64_t> flags{0};
    std::atomic<uint64_t> generation{0};
    std::atomic<uint64_t> epoch{0};
    std::atomic<uint64_t> ticket{0};
  };

  std::array<AtomicEntry, kCapacity> entries_{};
  std::atomic<uint64_t> version_{0};
  std::atomic<uint64_t> published_ticket_{0};
  std::atomic<uint64_t> next_ticket_{0};
  std::atomic<uint64_t> consumed_ticket_{0};
  // Telemetry-only floor: clear/range/generation edges intentionally retire
  // old history without routing it through acknowledge(). Counting those
  // invalidated tickets as later capacity overwrites is a false loss signal.
  std::atomic<uint64_t> overwrite_accounting_floor_{0};
  std::atomic<uint64_t> clear_epoch_{0};
  std::atomic<uint64_t> expected_generation_{0};
  std::atomic<uint64_t> overwritten_unconsumed_{0};
  std::atomic<bool> publisher_in_range_{false};
  // Latest active position remains reusable after its history ticket is
  // acknowledged, so a stationary app-owned hover animation or multi-frame
  // stroke still receives the pen lane until a real range exit/clear.
  std::atomic<uint64_t> active_ticket_{0};
};

class FrameRenderer {
public:
  explicit FrameRenderer(const FrameRendererConfig &config);
  FrameRenderer(const FrameRenderer &) = delete;
  FrameRenderer &operator=(const FrameRenderer &) = delete;
  ~FrameRenderer();

  bool valid() const { return valid_; }
  bool submit_frame(const PlutoFramePacket &packet);
  // Records a valid Flutter compositor frame whose backing store was
  // unchanged. Production filters these before submit_frame(), but the
  // no-flash reveal gate still needs the post-arm frame boundary.
  void notify_idle_frame();
  // Rebuilds logical renderer state and the presenter-bound rotation stage
  // atomically when the device orientation changes.
  bool set_rotation(uint32_t rotation, uint32_t logical_width,
                    uint32_t logical_height);
  // Queues a full-screen quality replay of the current settled ledger. This
  // does not synthesize new Flutter content; it is used for explicit standby
  // settling and returns false before the first valid frame.
  bool request_full_refresh();
  // Stock-style ghost control without restarting Flutter. Public Blink
  // policies are followed by BleachNow: solid black/white rails are Fast and
  // the final retained-content restore is Full. INIT/mode 0 is diagnostic-only.
  bool request_ghost_control(GhostControlMode mode);
  // Convenience alias used by the bezel gesture.
  bool request_pixel_reset();
  // Input/supervisor gates for automatic maintenance. These are native-only
  // and lock-free on the high-rate input path; no app-facing control exists.
  void set_touch_active(bool active);
  void set_pen_active(bool active);
  // Lock-free high-rate hover/contact hint publication. A hint contains no
  // pixels and never schedules a present. Only a later verified Flutter
  // frame diff can consume it for pen-priority rendering.
  void note_pen_render_hint(const PenRenderHintSnapshot &hint);
  void note_pen_render_hint(const PenRenderHintSnapshot &hint,
                            uint64_t generation);
  // Lifecycle/geometry invalidation. Proximity exit intentionally does not
  // call this: its final hover ROI remains available for an app-owned cursor
  // erase frame, while the exit hint itself still produces no output.
  void clear_pen_render_hints();
  void set_pen_render_hint_generation(uint64_t generation);
  void set_auto_maintenance_allowed(bool allowed);
  // Temporarily holds presenter dispatch while Flutter continues rendering
  // into the ledger. Used when the warm launcher must replace its old Home
  // route with system UI without flashing that stale frame on glass.
  void set_presentation_suspended(bool suspended);
  // Arms release of a suspended presenter after the next accepted Flutter
  // frame. The caller must schedule that frame after routing system UI.
  bool arm_presentation_resume();
  // Failsafe reveal for a suspended system surface. Discards every hidden
  // queued region and presents one full request from the latest ledger.
  bool force_presentation_resume();
  bool presentation_suspended() const;
  // Copies one coherent renderer surface while the frame-path mutex is held.
  // Returns false, leaving |out| unchanged, until a complete Flutter frame
  // has established this renderer's retained content.
  bool snapshot(RendererSnapshotSurface surface, RendererSnapshot *out) const;
  // Writes a downsampled, orientation-correct BMP of the latest Flutter frame
  // for the launcher app switcher. The write is atomic and bounded by
  // max_long_edge_px so warm-app previews consume little /run memory.
  bool write_preview_bmp(const std::string &path,
                         uint32_t max_long_edge_px = 640);
  // Presenter completion entry point. Enqueue-only (presenter.h:96-99): safe
  // from any thread, including synchronously on the present() stack; the
  // completion is processed by the next presenter-loop tick in arrival order.
  void notify_present_complete(uint64_t frame_id);
  // TEST-ONLY: number of callbacks enqueued but not yet reconciled with the
  // current scheduler generation.
  size_t queued_present_completions_for_testing() const;
  // Quiesces panel-facing work without destroying the renderer object used by
  // Flutter's compositor. The caller may close the detached presenter after
  // this returns. Frames are rejected until attach_presenter() rebuilds the
  // scheduler against the newly opened panel owner.
  bool detach_presenter(uint32_t timeout_ms = 5000);
  bool attach_presenter(const PlutoPresenterOps *presenter_ops,
                        PlutoPresenter *presenter);
  void shutdown();

  size_t submitted_frames() const { return submitted_frames_; }
  size_t diffed_frames() const { return diffed_frames_; }
  size_t idle_frames() const { return idle_frames_; }
  size_t last_damage_count() const { return last_damage_count_; }
  size_t chroma_marked_tiles() const { return chroma_marked_tiles_; }
  size_t stale_geometry_frames() const { return stale_geometry_frames_; }
  size_t pen_priority_regions() const { return pen_priority_regions_; }
  uint64_t pen_priority_changed_pixels() const {
    return pen_priority_changed_pixels_;
  }
  uint64_t pen_priority_preview_pixels() const {
    return pen_priority_preview_pixels_;
  }
  uint64_t last_pen_hint_to_frame_us() const {
    return last_pen_hint_to_frame_us_;
  }
  uint64_t pen_hint_overwrites() const {
    return pen_hint_mailbox_.overwritten_unconsumed();
  }
  uint64_t pen_focus_wakes() const {
    return pen_focus_wakes_.load(std::memory_order_relaxed);
  }
  // Verified scroll MOVEs (row-hash detector) since construction.
  size_t scroll_moves_detected() const { return scroll_moves_; }
  size_t automatic_ghost_actions() const {
    return automatic_ghost_actions_.load(std::memory_order_acquire);
  }
  // TEST-ONLY: the supervisor's transient lifecycle gate is process-local and
  // must never be inherited from a glass handoff payload.
  bool auto_maintenance_allowed_for_testing() const {
    return auto_maintenance_allowed_.load(std::memory_order_acquire);
  }

private:
  static bool presenter_ready(void *user_data, PlutoRefreshClass cls);
  static bool presenter_present(void *user_data,
                                const PlutoPresentRequest *request);
  static void completion_callback(uint64_t frame_id, void *user_data);
  void notify_presenter_device_lost();

  void configure(uint32_t width, uint32_t height, PlutoPixelFormat format);
  bool components_valid() const;
  size_t merge_damage();
  // The Stage-6 classification path: ScrollDetector -> ClassifyLadder ->
  // whole-screen scenecut promotion, filling submit_rects_/submit_classes_
  // from the merged damage_rects_.
  void classify_damage(uint64_t now_us);
  void route_pen_damage(uint64_t now_us);
  void mark_chroma_tiles();
  bool has_chroma_sensitive_rgb565_change(const PlutoFramePacket &packet) const;
  void copy_rect_from_packet(const PlutoFramePacket &packet,
                             const PlutoRect &rect);
  void open_frame_recorder();
  void record_frame(const PlutoFramePacket &packet);
  void run_presenter_loop();
  void tick_locked(uint64_t now_us);
  bool poll_presenter_health_locked(uint64_t now_us, bool *presenter_idle);
  void maybe_publish_health_locked(uint64_t now_us, bool presenter_idle);
  void sync_pen_focus_locked(uint64_t now_us);
  void publish_presenter_pen_focus_locked(const PlutoRect &logical_focus,
                                          bool contact, uint64_t sequence);
  bool clear_presenter_pen_focus_locked(bool force = false);
  bool begin_pixel_reset_locked(GhostControlMode mode, uint32_t cycles,
                                uint64_t not_before_us,
                                AutoGhostbusterDecision automatic_decision);
  bool begin_auto_ghost_control_locked(AutoGhostbusterDecision decision,
                                       uint64_t now_us);
  bool advance_pixel_reset_locked(uint64_t now_us);
  void set_pixel_reset_render_hold_locked(bool held);
  void finish_pixel_reset_locked(bool success, uint64_t now_us);
  bool maintenance_allowed_locked() const;
  bool intrusive_maintenance_allowed_locked(uint64_t now_us) const;
  void set_input_active(uint8_t bit, bool active);
  void maybe_resume_presentation_locked();
  bool reveal_suspended_presentation_locked();
  void drain_completions_locked();
  // Called only on the scheduler/presenter call path after present() returns
  // kPlutoStatusOk. Presenter completion callbacks never call this.
  void mark_ready_after_present_locked();
  // After successful quality coverage, retires persistent forced scroll
  // settles. Pen truth is dispatched directly by RegionScheduler and never
  // enters this delayed maintenance path.
  void retire_forced_settles_locked(const PlutoPresentRequest &request);
  bool export_handoff_state_locked(RendererHandoffState *out) const;
  bool import_handoff_state_locked(const RendererHandoffState &state);
  void restore_handoff_state_locked(const RendererHandoffState &state);
  void try_admit_handoff_locked();
  void try_stage_handoff_locked(uint64_t deadline_us);
  uint64_t decision_now_us() const;

  FrameRendererConfig config_;
  bool valid_ = false;
  uint32_t width_ = 0;
  uint32_t height_ = 0;
  size_t stride_ = 0;
  PlutoPixelFormat format_ = kPlutoPixelFormatRgb565;
  // Engine-true RGB565 mirror for the settled-color paths and the raw
  // pass-through (transitional; deleted when presenters consume ledger
  // planes directly).
  std::vector<uint8_t> retained_frame_;
  // The Stage-6 classification stack: row-hash scroll detection, the
  // TileStats-only classify ladder (RefreshClassifier died with it), and
  // the guard-band/word-box packager feeding the scheduler.
  ClassifyLadder ladder_;
  PenRenderPolicy pen_render_policy_;
  ScrollDetector scroll_detect_;
  GuardBandPackager guard_band_;
  // The Stage-2 policy stack: per-tile ledgers shared by the scheduler
  // (accrual/clear on dispatch) and the settle planner (candidate
  // selection); the RegionScheduler dispatches PEN > user preview/truth >
  // user EDF > CBS-budgeted settles; SettlePlanner is the single background
  // settle authority. All scheduler-thread confined (this mutex).
  GhostLedger ghost_ledger_;
  StressLedger stress_ledger_;
  ChromaPendingSet chroma_pending_;
  AutoGhostbuster auto_ghostbuster_;
  SettlePlanner settle_planner_;
  std::unique_ptr<RegionScheduler> scheduler_;
  std::unique_ptr<HealthFilePublisher> health_file_;
  // The renderer core: fused tile pass writing through into the frame
  // ledger, presented via the ABI bridge.
  FrameLedger ledger_;
  TilePass tile_pass_;
  AbiPresentBridge bridge_;
  // Pre-allocated frame-path scratch (no per-frame heap in steady state):
  // merged post-quantize damage, then the classified set the guard packager
  // consumes, then the packaged rects the scheduler is fed.
  std::vector<PlutoRect> damage_rects_;
  std::vector<PlutoRect> submit_rects_;
  std::vector<PlutoRefreshClass> submit_classes_;
  std::vector<PlutoRect> packaged_rects_;
  std::vector<PlutoRefreshClass> packaged_classes_;
  // Real post-quantize damage omitted by an interaction classifier (currently
  // scroll-body pacing). It is eligible only for pen association: an
  // unmatched candidate remains suppressed and cannot defeat normal pacing.
  std::vector<PlutoRect> pen_only_damage_rects_;
  std::vector<PlutoRect> pen_preview_rects_;
  std::vector<PlutoRect> pen_truth_rects_;
  std::vector<PlutoRefreshClass> pen_truth_classes_;
  // Scroll fast-path state: body presents are paced by accumulated
  // translation (motion masking); ghost translation accumulates sub-tile
  // pixel deltas until a whole tile row can shift.
  uint32_t scroll_pending_px_ = 0;
  int32_t scroll_ledger_shift_px_ = 0;
  size_t scroll_moves_ = 0;
  // Whole-screen scenecut promotion bar (ladder full_screen_area_percent).
  uint32_t scenecut_full_screen_percent_ = 45;
  // Whether the engine-true mirror (retained_frame_) is maintained. RGB565
  // stays live even for a luma-only presenter so same-luma hue changes remain
  // real renderer damage; color-capable backends additionally consume it.
  bool mirror_enabled_ = false;
  // Display-info snapshot (valid when a presenter reported info()).
  bool display_info_available_ = false;
  bool panel_is_color_ = false;
  bool backend_quantizes_color_ = false;
  bool presenter_controls_refresh_class_ = false;
  PlutoPixelFormat presenter_format_ = kPlutoPixelFormatRgb565;
  // PLUTO_RECORD_FRAMES sink (null when recording is off).
  std::FILE *record_file_ = nullptr;
  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::thread thread_;
  bool stop_ = false;
  // Atomic so completion callbacks can request a wake without taking mutex_.
  std::atomic<bool> wake_{false};
  std::atomic<bool> presenter_device_lost_notified_{false};
  uint64_t next_presenter_health_poll_us_ = 0;
  uint64_t next_health_publish_us_ = 0;
  uint64_t presenter_completion_count_ = 0;
  uint64_t health_published_completion_count_ = 0;
  bool presenter_supports_health_contract_ = false;
  bool health_file_failed_ = false;
  CompletionQueue completion_queue_;
  std::atomic<size_t> dropped_completions_{0};
  static constexpr uint8_t kTouchInputBit = 1u << 0;
  static constexpr uint8_t kPenInputBit = 1u << 1;
  std::atomic<uint8_t> active_input_mask_{0};
  std::atomic<uint64_t> last_input_change_us_{0};
  PenRenderHintMailbox pen_hint_mailbox_;
  std::atomic<bool> pen_focus_clear_requested_{false};
  std::atomic<uint64_t> pen_focus_wake_signature_{UINT64_MAX};
  std::atomic<uint64_t> pen_focus_wakes_{0};
  uint64_t last_pen_focus_hint_sequence_ = 0;
  uint64_t pen_focus_expires_us_ = 0;
  bool presenter_pen_focus_active_ = false;
  bool presenter_pen_focus_contact_ = false;
  PlutoRect presenter_pen_focus_rect_{};
  uint64_t presenter_pen_focus_sequence_ = 0;
  bool presenter_focus_clear_fault_ = false;
  std::atomic<bool> auto_maintenance_allowed_{true};
  size_t submitted_frames_ = 0;
  size_t stale_geometry_frames_ = 0;
  // Once an explicit rotation establishes logical geometry, a raster callback
  // that began under the old metrics may arrive late. Such packets are
  // acknowledged but never allowed to reconfigure the new bridge/scheduler.
  bool logical_geometry_locked_ = false;
  size_t diffed_frames_ = 0;
  size_t idle_frames_ = 0;
  size_t last_damage_count_ = 0;
  size_t chroma_marked_tiles_ = 0;
  size_t pen_priority_regions_ = 0;
  uint64_t pen_priority_changed_pixels_ = 0;
  uint64_t pen_priority_preview_pixels_ = 0;
  uint64_t last_pen_hint_to_frame_us_ = 0;
  // Reclosed by every configure/attach; opened only by an updated Flutter
  // packet so a warm reset cannot restore another app's handoff seed.
  bool retained_content_ready_ = false;
  // True only between a successful cross-process handoff admission and this
  // app's first accepted full-surface reconciliation. It authorizes exact
  // old-RGB/chroma comparison, but never pixel reset or app-owned refresh.
  bool seeded_physical_baseline_valid_ = false;
  bool ready_marker_attempted_ = false;
  bool trace_enabled_ = false;
  bool presentation_suspended_ = false;
  bool presentation_resume_requested_ = false;
  size_t resume_after_submitted_frames_ = 0;
  enum class PixelResetPhase : uint8_t {
    kIdle,
    kPending,
    kBlack,
    kWhite,
    kRestore,
    kAbortRestore,
  };
  PixelResetPhase pixel_reset_phase_ = PixelResetPhase::kIdle;
  GhostControlMode pixel_reset_mode_ = GhostControlMode::kBlinkNow;
  AutoGhostbusterDecision pixel_reset_auto_decision_ =
      AutoGhostbusterDecision::kNone;
  bool pixel_reset_render_hold_ = false;
  bool pixel_reset_interrupted_ = false;
  size_t pixel_reset_restore_generation_ = 0;
  uint32_t pixel_reset_cycles_remaining_ = 0;
  uint64_t pixel_reset_not_before_us_ = 0;
  uint64_t pixel_reset_started_us_ = 0;
  uint64_t pixel_reset_deadline_us_ = 0;
  uint64_t pixel_reset_abort_deadline_us_ = 0;
  std::atomic<size_t> automatic_ghost_actions_{0};
  bool shutdown_complete_ = false;
};

class SoftwareCompositor {
public:
  SoftwareCompositor(PlutoPixelFormat format, FrameRenderer *renderer);

  FlutterCompositor flutter_compositor();
  BackingStorePool &pool() { return pool_; }
  const BackingStorePool &pool() const { return pool_; }

  bool create_backing_store(const FlutterBackingStoreConfig *config,
                            FlutterBackingStore *backing_store_out);
  bool collect_backing_store(const FlutterBackingStore *backing_store);
  bool present_view(const FlutterPresentViewInfo *info);

  size_t present_count() const { return present_count_; }
  size_t idle_short_circuit_count() const { return idle_short_circuit_count_; }

private:
  static bool create_callback(const FlutterBackingStoreConfig *config,
                              FlutterBackingStore *backing_store_out,
                              void *user_data);
  static bool collect_callback(const FlutterBackingStore *backing_store,
                               void *user_data);
  static bool present_view_callback(const FlutterPresentViewInfo *info);

  BackingStorePool pool_;
  FrameRenderer *renderer_ = nullptr;
  // Flutter raster-thread confined and reserved once: paint bounds must not
  // allocate on every pen-driven frame.
  std::vector<PlutoRect> paint_bounds_scratch_;
  size_t present_count_ = 0;
  size_t idle_short_circuit_count_ = 0;
};

} // namespace pluto

#endif // PLUTO_COMPOSITOR_SOFTWARE_COMPOSITOR_H_
