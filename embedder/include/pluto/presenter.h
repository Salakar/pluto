#ifndef PLUTO_PRESENTER_H_
#define PLUTO_PRESENTER_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------- status ----------
typedef enum PlutoStatus {
  kPlutoStatusOk = 0,
  kPlutoStatusAgain = 1, // backpressure: caller should retry after ready()
  kPlutoStatusUnsupported = 2, // capability not offered by this backend
  kPlutoStatusInvalidArgument = 3,
  kPlutoStatusDeviceLost =
      4, // backend endpoint died (e.g. xochitl restarted)
  kPlutoStatusTimeout = 5,
  kPlutoStatusInternal = 6,
} PlutoStatus;

// ---------- geometry ----------
typedef struct PlutoRect {
  int32_t x; // surface coords, native portrait space (Move: 0..953)
  int32_t y; // (Move: 0..1695)
  int32_t width;
  int32_t height;
} PlutoRect;

// ---------- refresh classes (D4; upward promotion only) ----------
typedef enum PlutoRefreshClass {
  kPlutoRefreshFast =
      0,                 // DU/A2-class: mono, tiny rects, pen-local app damage
  kPlutoRefreshUi = 1, // GC16_FAST/GL16-class: chrome, mixed content
  kPlutoRefreshText = 2, // REAGL/GL16-class: settled regional quality
  kPlutoRefreshFull =
      3, // GC16-class: whole-region flash, ghost cleanup, color settle
} PlutoRefreshClass;

// ---------- pixel formats ----------
typedef enum PlutoPixelFormat {
  kPlutoPixelFormatRgb565 = 0,   // Move panel-native
  kPlutoPixelFormatGray8 = 1,    // mono devices / mono pipelines
  kPlutoPixelFormatXrgb8888 = 2, // host preview convenience
} PlutoPixelFormat;

typedef struct PlutoSurface {
  const uint8_t *pixels; // base pointer of the settled frame
  size_t stride_bytes;   // Move RGB565: 1908 (954*2), unless backend dictates
                         // otherwise
  int32_t width;
  int32_t height;
  PlutoPixelFormat format;
} PlutoSurface;

// ---------- present ----------
typedef enum PlutoPresentFlags {
  kPlutoPresentFlagNone = 0,
  // Pen-correlated app damage: bypass backend-internal batching; lowest
  // latency wins. Name and bit are retained for ABI compatibility.
  kPlutoPresentFlagInkPriority = 1 << 0,
  // Content already quantized/dithered for glass (renderer did it; D6).
  kPlutoPresentFlagPreDithered = 1 << 1,
  // Renderer-initiated quality settle (idle repayment). Completion
  // bookkeeping is unchanged; backends may use it to schedule quality work
  // (e.g. DC-stress balanced promotion) that must never ride live content.
  kPlutoPresentFlagSettle = 1 << 2,
  // Sparkle ghost repair: a scattered per-pixel white top-off pass (the
  // backend drives only near-white pixels whose low-discrepancy spatial
  // slot matches the pass phase, carried in bits [8..15]). Surface pixels
  // are ignored; damage rects select the repair region. Flash-free by
  // construction; backends without a top-off mode complete it as a no-op.
  kPlutoPresentFlagSparkle = 1 << 3,
  // Modifies Sparkle: per-pixel white DEVELOP pass (color glass). Each
  // masked white pixel runs its own GC16-family micro develop — the only
  // drive that truly resets displaced Gallery-3 pigments (yellow-cast
  // whites) — instead of the mode-8 top-off. Much sparser masks (8-bit
  // phase) keep the transient per-pixel inversion at paper-grain density.
  kPlutoPresentFlagSparkleDevelop = 1 << 4,
  // Explicit full-screen optical reset rails. The renderer bridge supplies
  // the named solid target; the scheduler completion-serializes strong Fast
  // black/white passes before one Full retained-content redraw.
  kPlutoPresentFlagPixelResetBlack = 1 << 5,
  kPlutoPresentFlagPixelResetWhite = 1 << 6,
  // Final balanced retained-content redraw after a Bleach/Both rail plan.
  // Unlike black/white rails, the bridge supplies normal content. The marker
  // keeps reset bookkeeping distinct from ordinary regional quality work.
  kPlutoPresentFlagPixelResetRestore = 1 << 7,
  // Required non-maintenance truth repaint. It remains a SETTLE for
  // scheduling/bookkeeping, but must not be silently stress-promoted into a
  // flashing regional waveform.
  kPlutoPresentFlagRequiredSettle = 1 << 16,
  // High-fidelity truth chase for real app-rendered pixels correlated with
  // pen hover/contact. With kPlutoRefreshFull, the damage rectangles MUST
  // remain regional: in particular qtfb sends UPDATE_PARTIAL rather than
  // escalating the class to UPDATE_ALL. Direct SWTCON already honors damage
  // geometry. This flag contains no synthetic ink and creates no damage by
  // itself; kPlutoPresentFlagInkPriority keeps its independent bit-0 ABI.
  kPlutoPresentFlagPenTruth = 1 << 17,
} PlutoPresentFlags;

// Sparkle pass phase rides in PlutoPresentRequest.flags bits 8..15
// (top-off rotations use 0..15; develop rotations the full 0..255).
#define kPlutoPresentSparklePhaseShift 8u
#define kPlutoPresentSparklePhaseMask (0xffu << 8u)

typedef struct PlutoPresentRequest {
  size_t struct_size;
  PlutoSurface surface;
  const PlutoRect *damage; // >= 1 rect; disjoint; class-homogeneous
  size_t damage_count;
  PlutoRefreshClass refresh_class;
  uint32_t flags;    // PlutoPresentFlags
  uint64_t frame_id; // embedder-assigned, monotonically increasing
} PlutoPresentRequest;

// ---------- capabilities / info ----------
typedef struct PlutoDisplayInfo {
  size_t struct_size;
  int32_t width;  // native portrait logical px (Move: 954)
  int32_t height; // (Move: 1696)
  int32_t dpi;    // (Move: 264)
  PlutoPixelFormat preferred_format;
  bool is_color;                // Gallery-3 CMYW => true on Move/Pro
  bool controls_refresh_class;  // backend can honor classes distinctly
  bool reports_completion;      // frame_id completion callbacks are real
  bool wants_pre_dithered;      // backend performs no quantization (D6)
  int32_t rect_alignment;       // e-ink backends: 8 (px); host: 1
  int32_t max_inflight_updates; // 0 = unknown/unbounded
  // Reference completion latencies (ms) per class for scheduler pacing until
  // measured; backends fill from the research table or live measurement.
  int32_t nominal_latency_ms[4];
  // Backend (or its downstream compositor, e.g. xochitl under qtfb) maps RGB
  // content to the panel palette itself; the renderer then passes settled
  // color through instead of palette-crushing it (doc 03 section 7.4).
  // Appended (not inserted) so struct_size versioning stays meaningful.
  bool backend_quantizes_color;
  // Backend/downstream compositor accepts overlapping regional updates with
  // newest-content supersession. This lets immediate pen truth follow a Fast
  // preview without waiting on a synthetic completion fence (qtfb/Xochitl).
  bool supports_overlap_supersession;
} PlutoDisplayInfo;

// Completion: fired when the *device* is done developing frame_id's update
// (not when the copy finished). Called on an internal presenter thread; the
// callee must only enqueue (lock-free) -- never block.
typedef void (*PlutoPresentCompleteCallback)(uint64_t frame_id,
                                               void *user_data);

typedef struct PlutoPresenter PlutoPresenter; // opaque, backend-owned

typedef struct PlutoPresenterConfig {
  size_t struct_size;
  const char *backend_name; // "qtfb" | "native" | "host-window" |
                            // "host-headless" | "null" | NULL = auto-probe
  const char
      *options; // backend-specific key=value CSV (documented per backend)
  PlutoPresentCompleteCallback on_complete; // may be NULL
  void *user_data;
} PlutoPresenterConfig;

// ---------- optional physical pen focus metadata ----------
// This is scheduling metadata only. It cannot create pixels, damage, or a
// present request. `rect` is in native presenter coordinates and is ignored
// when kPlutoPenFocusInRange is absent. Contact implies in-range.
typedef enum PlutoPenFocusFlags {
  kPlutoPenFocusNone = 0,
  kPlutoPenFocusInRange = 1u << 0,
  kPlutoPenFocusContact = 1u << 1,
} PlutoPenFocusFlags;

typedef struct PlutoPenFocus {
  size_t struct_size;
  PlutoRect rect;
  uint32_t flags;    // PlutoPenFocusFlags; 0 clears focus
  uint64_t sequence; // publisher order/provenance; not a drawing id
} PlutoPenFocus;

// ---------- coordinated warm-display handoff ----------
//
// A handoff is deliberately split into outgoing staging and incoming
// confirmation. The presenter owns the atomic tmpfs bundle and its
// PixelEngine/Xochitl sections; FrameRenderer owns this opaque renderer
// payload. An incoming presenter may parse/seed its core early, but it must
// not skip cold clear until confirm_handoff(true) proves the renderer has
// validated and seeded the same candidate.
typedef struct PlutoHandoffPayload {
  size_t struct_size;
  const uint8_t *bytes;
  size_t byte_count;
  int32_t width;
  int32_t height;
  uint32_t rotation;
  PlutoPixelFormat pixel_format;
  uint64_t configuration_hash;
} PlutoHandoffPayload;

typedef struct PlutoPresenterOps {
  size_t struct_size;
  const char *name;

  PlutoStatus (*open)(const PlutoPresenterConfig *config,
                        PlutoPresenter **out_presenter);
  void (*close)(PlutoPresenter *presenter);

  PlutoStatus (*info)(PlutoPresenter *presenter,
                        PlutoDisplayInfo *out_info);

  // Snapshot semantics: the presenter has consumed the damage rects' pixels
  // by the time present() returns (copy or equivalent). The caller may then
  // mutate the surface freely. Returns kPlutoStatusAgain under backpressure.
  PlutoStatus (*present)(PlutoPresenter *presenter,
                           const PlutoPresentRequest *request);

  // Non-blocking: is the backend able to accept a present of this class now?
  bool (*ready)(PlutoPresenter *presenter, PlutoRefreshClass refresh_class);

  // Block (with timeout) until all previously presented frames completed.
  // A zero timeout is a non-blocking health/idle sample and must still report
  // kPlutoStatusDeviceLost immediately. Used for fault polling, flashing
  // updates (fencing), and shutdown.
  PlutoStatus (*wait_idle)(PlutoPresenter *presenter, uint32_t timeout_ms);

  // Screenshot path for the CLI (DP-O8): synchronously copy the last settled
  // full frame into caller-provided storage described by out_surface
  // (pixels/stride pre-set by caller). Optional: may be NULL.
  PlutoStatus (*snapshot)(PlutoPresenter *presenter,
                            PlutoSurface *out_surface);

  // Optional append-only hook. Publishes physical hover/contact focus so a
  // backend may defer expensive UNSTARTED work intersecting the nib region.
  // Already-started work remains authoritative and unpreemptible. A focus
  // with flags=0 clears the reservation. This hook never draws anything.
  PlutoStatus (*set_pen_focus)(PlutoPresenter *presenter,
                                 const PlutoPenFocus *focus);

  // Outgoing: called only after the renderer scheduler and completion queue
  // are idle. The backend copies `payload`, completes its deeper optical
  // barrier (including final scan-count feedback), and stages one complete
  // bundle for close(). Unsupported backends leave this null.
  PlutoStatus (*stage_handoff)(PlutoPresenter *presenter,
                               const PlutoHandoffPayload *payload,
                               uint32_t timeout_ms);

  // Incoming: exposes the renderer section of a fully validated candidate.
  // `bytes` remains presenter-owned and valid until confirm_handoff() or
  // close(). kPlutoStatusAgain means no compatible candidate was admitted.
  PlutoStatus (*get_handoff)(PlutoPresenter *presenter,
                             PlutoHandoffPayload *out_payload);

  // Incoming transactional decision. `accepted=false` discards all warm
  // state and runs the ordinary cold-clear path. `accepted=true` releases
  // the cold-clear gate only when the presenter core and renderer payload
  // belong to the same candidate.
  PlutoStatus (*confirm_handoff)(PlutoPresenter *presenter, bool accepted);
} PlutoPresenterOps;

// Registry (static; D9).
const PlutoPresenterOps *pluto_presenter_by_name(const char *name);
// Auto-probe ladder for on-device use: temporary qtfb development route,
// followed by an immutable-profile-gated native backend. Host builds use the
// host preview. The final native cut removes qtfb entirely.
const PlutoPresenterOps *pluto_presenter_probe(void);

#ifdef __cplusplus
} // extern "C"
#endif
#endif // PLUTO_PRESENTER_H_
