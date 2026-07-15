# Pen-aware fast rendering without system-wide drawing

Date: 2026-07-11  
Status: pen ownership and acceleration are implemented, independently audited,
and source-frozen on the host. All non-socket host tests and the sanitizer
regressions pass; the permission-correct socket/Flutter run remains pending.
Attached-device deployment/optical acceptance is blocked by the USB interface
having no carrier/address. Literal arbitrary-color fidelity on direct SWTCON
remains behind installed-runtime source/selector/delta parity and the optical
Fast/Full state-bridge gates in the final section.

## Decision

Pen input and pen rendering are different responsibilities.

- **Apps own every visible pen-correlated pixel.** An app draws a stroke,
  eraser result, hover ring, cursor, selection, or nothing at all by handling
  Flutter pen events. The supervisor/embedder never stamps a native pen mark.
  This does not prohibit non-pen display-maintenance surfaces such as the
  serialized black/white cold-clear rails.
- **The system owns render acceleration.** It observes proximity, position,
  trajectory, contact, and the renderer's real post-quantize pixel changes.
  It may prioritize matching damage, show those current app pixels quickly in
  Fast grayscale, and immediately chase them with regional Text/Full quality.
- **A hint is not damage.** Hovering, touching, predicting, lifting, losing a
  device, or receiving 10,000 samples with no app frame change must produce
  zero new pixels and zero presents.

This replaces the former `WetInkPlane` design. That path stamped black pixels
for contact regardless of app behavior, so a pen could draw over every app,
turn a white eraser into black, put dots on controls, and temporarily lie
about colored/light brushes. Its source, bridge composite, pen-up timer, and
tests have been removed.

## Requirements pinned by this design

1. Pen events continue to reach the focused Flutter app. Ignoring them draws
   nothing.
2. `BTN_TOOL_PEN`/proximity activates readiness **before contact**.
3. Hover is a full participant in acceleration. Hover alone is invisible; an
   app-rendered hover indicator is accelerated like any other nearby diff.
4. Prediction prioritizes a region; it never predicts pixel values or stroke
   semantics.
5. Fast preview is derived only from the app's current pixels, whether the
   source is black, white, gray, colored, sparse, broad, or a redraw over
   recent content. The preview itself is intentionally chroma-free.
6. High-fidelity truth is queued immediately. There is no pen-up or
   quiescence delay.
7. Truth reads the newest ledger/framebuffer state at execution. New
   overlapping damage supersedes stale queued work.
8. Full-class color truth remains regional. “Full” selects fidelity; it does
   not authorize a whole-screen update for a small pen-correlated region.
9. Background settle/ghost maintenance cannot jump ahead of live preview or
   its truth chase.
10. Rotation, app switching, device loss, resync, sharp turns, and long input
    gaps cannot leave a stale predicted path active.

## Evidence that shaped the implementation

### Current Xochitl 3.27

Static analysis of the exact installed Xochitl shows:

- proximity (`updateInRange` / `penCloseChanged`) is distinct from contact;
- hover movement reaches Qt pointing-device dispatch;
- contact is checked against regions registered by visible
  `PenInputSurface`s, and “no input surface” takes a no-dispatch path;
- `FastGrayscale` is a framebuffer capability;
- six update-class regions use newest-class-wins overlap replacement; and
- fast-gray preprocessing uses three disjoint CPU stripes that reconverge
  before the subsequent core update call; this does not prove atomic optical
  behavior; and
- the ct33 front end tetrahedrally interpolates an RGB cube against a spatial
  threshold to produce a 3-bit colour state, not a direct 5-bit waveform
  target. Stock Content/UI then uses the active legacy mapper at `0x4814a0`
  to combine that plane with waveform delta and persistent A/B history. That
  mapper now has a production-disconnected static scalar model, plus a pinned
  proof of its one-/two-worker ranges and frozen-input barrier. Selector-16's
  scalar policy and backend-lifetime scratch are also closed. Pluto's
  production component deliberately barriers all coarse stripes before all
  classification stripes and all classification stripes before resolution,
  removing the stock large-update scheduling race rather than claiming that
  an uncaptured runtime interleaving has one canonical byte result. Installed
  source/selector/delta capture parity and optical scan ownership remain the
  direct-presenter capability gap;

### Broader low-latency e-paper facts

- Per-pixel waveform state and same-rail retargeting let new pixels start
  immediately instead of waiting for a complete previous waveform; open
  e-paper controller work demonstrates the same structure.
- Proximity-aware sample smoothing with adaptive future positions,
  validation, and correction is established e-ink stylus practice.
- Per-pixel active state with speculative activation is useful controller
  precedent, but generic Pluto cannot safely invent pixels because it does
  not know whether the app is drawing, erasing, recoloring, or moving a
  hover indicator.
- A 5-bit colour table may contain paired, optically equivalent states, and
  unchanged neighbours of a changed pixel may deliberately toggle between
  the pair to repair fringe-field blooming. This is a strong interpretation
  of the stock mapper's paired state values and neighbourhood work, not a
  substitute for bit-exact Xochitl runtime differentials.
- Prediction errors create visible overshoot and spring-back. Pluto
  therefore clamps prediction to one panel scan frame and uses it for
  scheduling geometry only.

## End-to-end architecture

```text
/dev/input pen SYN frame
        |
        +--> PenTracker --> Flutter pointer events --> focused app decides pixels
        |
        `--> PenRenderHint (hover/contact/trajectory only)
                    |
                    v  lock-free 32-entry history (oldest first,
                       later hints claim verified residual pixels)
Flutter frame --> TilePass exact dirty bounds/counts + changed_chroma
                    |
                    v
            intersect with swept pen ROI
             /                       \
    no intersection              real app damage
         |                         /          \
 normal scheduler       Fast gray preview   Text/Full truth
                              |                  |
                              `---- priority ---'
                                      |
                         presenter reads latest ledger pixels
```

There is no input-to-present edge. The only edge into presentation starts at
verified renderer damage.

## 1. Input: proximity, smoothing, and bounded prediction

`InkThread` remains the `poll(2)`/`EVIOCGRAB` owner and emits the same exact
per-SYN `PenTrackerOutput` used by Flutter, the pen ring, and the pen service.
Its second output is a trivially-copyable `PenRenderHint` containing only:

- event timestamp in the shared `CLOCK_MONOTONIC` domain;
- previous/current/predicted calibrated panel points;
- time-aware smoothed velocity;
- tool, transition, in-range, contact, prediction-valid, and device-loss
  state.

It has no framebuffer pointer, color, brush width, damage rectangle, refresh
class, or present callback.

`EvdevSource` requires `EVIOCSCLOCKID(CLOCK_MONOTONIC)` to succeed before it
publishes any event. It fails closed if the kernel rejects that request; mixing
default realtime stamps with renderer monotonic time could otherwise retain a
terminal hover ROI indefinitely. The successful device-open line records both
`exclusive=EVIOCGRAB` and `clock=monotonic`.

Velocity uses a first-order time-aware filter:

```text
alpha = dt / (tau + dt)
v = v_previous + alpha * (v_instantaneous - v_previous)
```

Defaults:

| Input constant | Default | Reason |
|---|---:|---|
| scan frame | 11,764 us | 85 Hz upper prediction boundary |
| prediction horizon | 11,764 us | at most one scan frame |
| maximum predicted displacement | 16 px | contains a bad extrapolation |
| velocity smoothing tau | 8,000 us | useful within a few digitizer samples |
| trajectory reset gap | 50,000 us | never bridge a stalled stream |
| input thread priority | `SCHED_FIFO` 20, best effort | short deterministic decode/handoff; normal scheduling fallback |

A sharp reversal (non-positive direction dot product), resync, tool change,
long gap, proximity exit, or device loss resets extrapolation. Prediction is
radially and panel-boundary clamped.

`PLUTO_PEN_PREDICT=0` disables extrapolation; a positive numeric value sets
the requested horizon, still clamped to one scan frame.
`PLUTO_PEN_RT_PRIORITY=0..99` controls the best-effort Linux real-time
priority (`0` disables it).

After acquiring `EVIOCGRAB`, the input thread drains only the queue that
predates ownership, then snapshots the digitizer's coherent current state
with `EVIOCGKEY` plus `EVIOCGABS`. `BTN_TOOL_PEN`/`BTN_TOOL_RUBBER`, contact,
and the current `ABS_X`/`ABS_Y` are processed as a resync boundary. This is
essential on a warm app switch: Linux need not replay a tool-entry edge when
the nib was already hovering, so the new app receives a fresh `Add` at the
current position without waiting for the pen to leave and return. The
snapshot fails closed unless key state and both absolute coordinates are
available; stale queued samples are never spliced onto the new session.

The pointer batch handed to Flutter now uses a fixed six-event array instead
of allocating a vector on every high-rate sample. For each coherent `SYN`
report, `InkThread` invokes the render-hint callback before the tracker output
that feeds Flutter and optional channels. `EngineHost` can therefore clear
ordinary pacing debt, publish the ROI, and gate maintenance before the app
sees that same hover/contact sample.

## 2. Pre-contact and hover readiness

The first in-range sample immediately:

- publishes the current ROI seed;
- prevents intrusive maintenance while the pen is near;
- starts trajectory history before the nib touches;
- leaves all fixed-capacity scheduler/policy state ready; and
- continues delivering hover events to the app.

It also switches sustained Flutter vsync grants to exactly one 85 Hz panel
scan, `11.764 ms`. Entry clears any ordinary frame-cap debt and expedites an
already-queued vsync baton. Leaving range clears the pen cadence debt and
restores the configured/mode cadence immediately; the first request in the
restored regime is not charged for the preceding hover interval.

It deliberately does **not** wake the display with an empty update. When an
app draws a hover indicator, that Flutter frame's actual changed pixels meet
an already-warm hint and enter the same priority route as contact damage.

The last in-range position remains a sticky *scheduling* position after its
ordinary history ticket is acknowledged. This lets a stationary app-owned
hover ring, pulse, tooltip, or brush outline accelerate each successive local
Flutter redraw even when the digitizer has no reason to emit another motion
sample. The sticky copy has ticket zero, so it cannot fabricate or consume
input history, and it is cleared on range exit, lifecycle clear, or geometry
generation change. An initial out-of-range kernel snapshot is discarded
rather than misread as a terminal erase ROI. As everywhere else in this
design, no matching framebuffer damage means no present.

Hover uses a slightly wider default correlation radius (48 px) than contact
(36 px). This catches an app's ring/brush outline around the physical nib
without broadening the contact fast path unnecessarily.

## 3. Coordinate and lifecycle correctness

Raw calibrated panel points are converted to the renderer's current logical
orientation in `EngineHost` at publication time. The same live atomic
orientation is used for Flutter pointer events, the pen service, and the
ring—removing the previous stale orientation snapshot after rotation.

Lift remains in range and therefore remains eligible for hover UI. Removal,
device loss, renderer reconfiguration, and lifecycle deactivation clear the
mailbox's active state immediately. No synthetic cleanup pixels are needed
because no synthetic pixels exist. Range exit retains only the terminal hover
ROI for at most `250 ms`, so an app frame that erases its hover cursor just
after removal can still use the fast lane. The terminal hint itself schedules
nothing, and stale terminal ROIs cannot capture later unrelated damage.

A normal input-thread stop is also a session boundary: before releasing
`EVIOCGRAB`, it synthesizes the required Flutter `Cancel`/`Remove` sequence and
the terminal renderer hint. The next session then performs the current-state
snapshot above. This prevents an old app retaining a live hover cursor or
pointer while a new app inherits a pen that never physically left proximity.

At the input-library seam, `InkThread` has no renderer dependency and its
render-hint callback is optional. `EngineHost::start_ink_thread` can therefore
continue pointer delivery while conditionally dropping hints if its renderer
pointer is absent. This is defensive lifecycle decoupling, not a supported
rendererless host boot: the current `EngineHost::initialize` still requires
`setup_renderer` to succeed before Flutter starts.

## 4. Correlating the pen with real app pixels

After `TilePass` quantizes and diffs the Flutter frame, `PenRenderPolicy`
receives:

- up to 32 unconsumed hover/contact hints, processed oldest first;
- exact dirty bounds per tile;
- exact changed-pixel counts;
- the `changed_chroma` transition bit for each dirty tile;
- the classifier's regions; and
- panel geometry/capabilities.

The bounded history matters when input outruns Flutter rasterization: a frame
produced from point A can still correlate after the digitizer has already
published point B. For one connected frame containing several queued samples,
A claims its verified hot corridor, that truth rectangle is subtracted, and B
may claim only residual verified pixels near the newer tip. The bounded
in-place worklist can grow by at most three rectangles per hint (97 total).
A later hint that contributes no residual pixels is not prefix-acknowledged,
so it remains available for its later Flutter frame. A versioned atomic
snapshot prevents mixed points, states, epochs, or rotation generations.

The focus ROI is the swept bounding corridor across previous, current, and
one-frame-predicted points. A route is legal only if at least one actual dirty
record intersects both the app region and that ROI. This two-sided test
prevents unrelated animation elsewhere on screen from acquiring pen priority.

Scroll-body pacing normally omits intermediate translated body damage. Before
that omission becomes final, the renderer retains only the exact body pieces
not already covered by the disocclusion strip as pen-only candidates. A
matching hover/contact hint may route their real changed pixels; an unmatched
piece remains suppressed and therefore cannot disable whole-body scroll
pacing. This keeps app-owned cursors/strokes responsive inside a moving canvas
without turning the moving canvas itself into a giant pen update.

The policy does not assume a nib size. Within the hard cap, large brushes and
broad erasers expand according to observed changed pixels and the swept focus
corridor:

```text
hard_cap      = panel_area * pen_max_preview_area_percent / 100
changed_budget = min(hard_cap, component_changed_pixels * 8)
area_budget    = max(min(hard_cap, focus_area), changed_budget)
preview_area  <= area_budget <= hard_cap
```

The defaults are an 8x changed-pixel scale and a final 20% panel-area cap.
Because the focus corridor is also a lower budget input, the resulting window
may legitimately exceed `component_changed_pixels * 8`; it can never exceed
the 20% final cap. If a coincident region is larger, exact rectangle
subtraction sends only the hot window through the pen lane while the residual
remains normal app damage. This prevents a full-screen animation under the pen
from becoming one giant Fast update.

The component is not every dirty tile in a broad classifier rectangle. The
policy chooses the dirty record closest to the current or predicted nib, then
walks only its 8-neighbour tile-connected changed component. Bounds and
changed-pixel counts come from exact post-quantize dirty records. Consequently
a disconnected animation or static color near a gray nib change cannot inflate
the area budget or promote fidelity.

Truth class follows transitions in that nib-rooted component, not unrelated
pixels in the surrounding classifier rectangle. `changed_chroma` is true when
either the old or new value of an actually changed RGB565 pixel is chromatic;
it is deliberately not the whole-current-tile `chroma_frac`. This catches
same-luma hue changes and color-to-white erases while ignoring static nearby
color. If the prior RGB hue is unknowable, a color-capable backend
conservatively owes Full truth.

- achromatic or monochrome: regional `Text`;
- chromatic on color glass: regional `Full`.

The native presenter reports panel color capability from the selected profile.
On monochrome glass, chroma-sensitive RGB565 changes still count as damage and
chase their luma as Text. On color glass they chase regional Full truth through
the profile-selected native color pipeline.

## 5. Fast preview and immediate fidelity chase

`RegionScheduler::submit_pen_damage` receives paired preview/truth geometry.
Both are aligned once and stored in fixed-capacity/preallocated state.

Dispatch order is:

1. pen Fast preview;
2. pen Text/Full truth;
3. ordinary user EDF classes;
4. budgeted background maintenance.

The preview sets the ABI-stable `InkPriority` bit (the old name now means only
“pen-correlated app damage”). Native userspace-TCON drivers map it to
pen-preview retargeting: new pixels start immediately. In a same-rail,
same-mode tile, the overlapping subrectangle can retarget while unrelated
active pixels continue under the identical pinned waveform. Across modes, the
preview can preempt at a scan boundary only when its subrectangle covers every
active pixel in that tile; otherwise that conflict parks until the waveform
boundary. Kernel-driven profiles preserve the same ordering at their native
update boundary. These guards avoid dashed motion without truncating unrelated
optical work.

The truth queue is separate from settle/CBS work. It has:

- no pen-up condition;
- no quiescence timer;
- no maintenance gate;
- no artificial deadline; and
- no conversion snapshot.

It waits only for real presenter readiness or optical conflicts the selected
native driver cannot safely supersede. Every supported device path reports
real per-request completion; profiles that prove overlap supersession may chase
regional truth in the same scheduler tick. A presenter decline retains
priority ownership and retries before generic work.

The userspace-TCON idle fence includes callback delivery, internal cold clear,
and the final scan latch—not only PixelEngine completion. Taking a
`ScanReadySlot` frees
the one-deep producer, but the slot remains unacknowledged until the matching
page-flip event proves that exact phase reached the scan latch. Rotation drains
delivered callbacks before rebuilding geometry, and detach drains them against
the old scheduler before attach may reuse frame IDs. Active-reset detach also
finishes the balanced restore, dispatches any newest-ledger Fast follow-up,
and separately fences it. A backend without `wait_idle` can advance only from
real callbacks; a sleep is never optical proof. A late
completion can therefore never retire work from the next renderer generation.

## 6. Newest pixels always win

Present requests carry regions/generations, not copied stroke pixels.
`AbiPresentBridge::prepare` reads the live `FrameLedger` (or the current RGB565
mirror for settled color) at dispatch. Therefore a delayed truth job naturally
sees pixels from a newer Flutter frame.

The pen queues preserve exact bounded segments. Exact duplicates and
containment-redundant geometry coalesce; partial overlaps remain separate.
Every segment in an overlap-connected truth component shares its strongest
still-owed quality (`Text` to `Full`), newest content epoch, and oldest enqueue
time, without becoming a gap-filled component bounding box. New app damage
also cancels overlapping queued or already-parked background repair. This
handles:

- drawing back over a just-drawn area;
- erasing a previewed dark region to white;
- changing the brush/color before older truth lands;
- moving/erasing a hover indicator; and
- repeated overlap while the Fast waveform is still active.

No stale “dry stroke” snapshot can repaint old content.

Supersession crosses scheduler lanes rather than applying only inside the pen
queue. Newly owed pen truth subtracts its rectangle from older ordinary
queued, parked, and exact-residual work; stronger older `Full` quality is
promoted into the truth component instead of being downgraded. Conversely,
ordinary damage submitted while pen truth is pending or in flight is split:
the intersection becomes newest-epoch follow-up truth and the exact outside
pieces remain ordinary work with their original class and age. A fixed 1,024
entry non-coalescing residual lane preserves gaps instead of reconstructing a
bounding box. If that hard bound is exhausted, the fail-safe is newest-epoch
full-screen `Full` truth—not silently dropping or replaying stale pixels.

Pen preview and truth may pass an unrelated ordinary `Full` request. They may
not pass a Fast or Full *pixel-reset* operation, because that operation changes
the presenter's physical source-state basis and is therefore hard-exclusive.

Exact mode retains up to 64 preview and truth segments. The 65th distinct
segment collapses the queue to deduplicated, panel-clipped `64 x 64` cells,
which bounds overload without constructing a stroke-sized rectangle. A present
request contains at most 64 rects; preview and eligible truth chunks continue
draining in the same scheduler tick when the presenter accepts them.

## 7. Presenter fidelity semantics

Every supported device exposes one native presenter contract. Hardware
differences are capability and profile data, not separate product flows:

| Capability | Native contract |
|---|---|
| color output | selected from the panel profile; monochrome profiles develop luma, color profiles preserve exact color truth |
| distinct Fast/Text/Full control | required and mapped to profile-pinned legal programs |
| per-request completion | real kernel marker or final userspace scan-latch acknowledgement |
| optical/latch idle fence | `wait_idle()` includes callback delivery, cold clear, and the backend's physical completion point |
| regional PenTruth Full | preserves exact damage instead of promoting to a whole-screen update |
| overlapping-update supersession | enabled only when the native driver explicitly proves it |

Fast preview uses current renderer luma and the selected profile's legal short
waveform. Text/Full truth follows immediately at the strongest class owed by
the changed component. The present job carries immutable generation, damage,
class, and content intent, so newest-content convergence never depends on a
mutable shared framebuffer or a connection-global mode switch.

Userspace-waveform admissions also pin one exact hysteretic temperature record. The
producer legalizes RGB565 levels with that record, carries `temp_bin` through
the lock-free mailbox or large lane, and PixelEngine pins the same LUT for the
whole optical sequence. Same-mode in-place retargeting additionally requires
the same bin; a covered pen preview crossing a threshold safely preempts and
restarts, otherwise it parks. Presenter startup synchronously samples the EPD
thermistor before cold clear, and both black/white cold-clear stages share that
initial bin.

The statically closed direct-colour prerequisite is implemented separately as
`Ct33Frontend`: exact 33-cube tetrahedral interpolation, the recovered `64 x
64` threshold field, the luma-selector/white-marker wrapper, exhaustive
RGB565 parity, and allocation-free conversion after configuration. It is
deliberately not connected to presentation. Its byte plane is an input to the
stock A/B history mapper, not a waveform target; enabling it alone would turn
an exact first stage into an invented and unsafe final stage.

A second prerequisite is now implemented as the standalone, test-only
`xochitl_color_mapper_reference_test` target. It pins the active legacy
mapper's normal, auxiliary-27, white-partner-31, bit-6, halo, A/B-history,
frozen snapshot, and transition-axis behavior. It also reconstructs the nine
temperature records' delta builder with the installed binary64 constants,
separate multiply-then-FMA order, and fail-closed phase code 7. It is
intentionally absent from `pluto_embedder_core`. For the checked panel
waveform, its complete mode-2/bin-4 table is byte-exact to the independent
offline fingerprint (2048-byte SHA-256
`67cd71ab2481606a72a302cd069a29167aab0d703ea22283d6b746475f447492`).
Executed direct-call
goldens now match normal, `force27`, `pair31`, and low-source bit-6 setup, but
the selected stock delta, selector producer, and mode-7 sequences remain
admission gates. The stock worker threshold, partition, and input visibility
are closed statically in the pinned scheduler/mapper: two workers begin at
inclusive height 30, use even non-last stripes, snapshot both split halos
before a start barrier, and cannot see sibling commits.

The Move-engine selector prerequisite is now a hardened,
presentation-disconnected production component, `XochitlSelector16`. It
accepts a complete `954x1696` RGB565 or portable little-endian `0xAARRGGBB`
surface with checked geometry,
stride, extent, and unaligned loads; rounds the requested operation to the
stock 16-pixel execution grid; and fills columns `954..959` by explicit white
or logical-edge replication. Its `240x424` coarse plane and `960x1696`
transient/final plane persist until backend reset, including the stock
outside-operation halo. Small operations are byte-exact to the independent
single-worker transcription. Large operations keep the three stock stripes
but run **all coarse -> all classify -> all resolve**, with barriers, so the
same source and retained state always produce the same mask. The returned mask
is an immutable compact snapshot of the rounded operation; a later build
cannot mutate bytes already handed to a consumer. This code is linked into
the core for admission work but is not connected to presentation, so it does
not itself authorize direct colour.

Those dimensions belong to the positively identified Move panel profile inside
the engine. They are not a Flutter application viewport, and another device
cannot route into this component merely by reporting similar geometry.

The dedicated `xochitl_selector16_test` differentially covers the exact small
route and deterministic staged large route, lifetime halo retention/reset,
the height-30 empty first stripe, fixed four-pixel borders, right/bottom guard
geometry, both padding policies, RGB565/ARGB equivalence, immutable results,
invalid buffers, and concurrent callers. Debug, Release, ASan+UBSan, and TSan
all pass this target.

The executed disposable oracle adds an integration constraint: the mapper's
ct33 pointer is operation-local, while A/B coordinates are absolute, and each
direct call rounds width to eight lanes and height to two rows. A nominal 1x1
call consumes and commits 8x2 lanes; right/bottom excess lands in the stock A/B
guard area. Any future colour admission must therefore freeze the complete
rounded source/state domain and schedule/union that exact execution extent. It
must not map only the nominal dirty rectangle, let two worker snapshots see
different generations, or mistake a synthetic full-plane oracle allocation
for the stock source-origin contract.

Pen truth sets `kPlutoPresentFlagPenTruth` (`1 << 17`):

- every native driver preserves the exact PenTruth damage rectangles;
- ordinary unflagged `Full` retains the backend's normal quality behavior.

For a color app change, preview is chroma-free Fast gray, then regional Full
truth passes the latest raw RGB565 to the backend with `PreDithered` unset.
Color profiles develop that exact truth; monochrome profiles develop the
corresponding luma preview/Text truth. White erases remain white; no path can
force them black.

## 8. Removed legacy machinery

The following no longer exist in the production or test build:

- `WetInkPlane` source/header/test;
- native nib stamping and provisional black prediction;
- input-to-renderer `submit_ink` callbacks;
- bridge-time black composition and owner suppression;
- pending stroke chains;
- pen-up forced settles;
- `pen_settle_quiesce_ms`; and
- the input library's renderer dependency.

The supervisor may still launch apps with `--pen`; that means “deliver pen
input and publish render hints,” not “draw globally.”

## Verification matrix

| Contract | Proof |
|---|---|
| hints alone never render | `FrameRendererTest.PenHintAloneNeverPresentsOrChangesContent` publishes 100 hover/contact hints after a frame; present count and pixels remain unchanged |
| app ignoring pen draws nothing | `InkThreadTest.EveryCoherentHoverAndContactSampleEmitsOnePureHint` proves the hint callback precedes, but does not replace, exact pointer output; the compositor has no input-triggered damage API |
| app-owned hover indicator stays non-inking | Ink Lab's `stylus hover is app-owned and clears on canvas exit` widget test moves a stylus in/out of its `MouseRegion`, observes the app painter's hover state, and asserts the stroke count remains zero |
| proximity and hover pacing are ready first | `VsyncPacerTest.HoverBeforeFirstRequestUsesOneScanFrameTargetImmediately`, `HoverExpeditesBatonQueuedAtOrdinaryFrameCap`, `SustainedHoverUsesExactOneScanCadence`, and `LeavingRangeRestoresConfiguredCadenceWithNoOldDebt` |
| exclusive ownership fails closed | `InkThreadTest.ExclusiveGrabFailurePublishesNoDeviceOrPointerHooks` injects successful monotonic-clock setup followed by a failed `EVIOCGRAB`, then proves the descriptor closes and no device-open, hint, tracker, or Flutter pointer hook fires |
| timestamp-domain setup fails closed | `InkThreadTest.MonotonicClockFailurePublishesNoDeviceOrPointerHooks` fails `EVIOCSCLOCKID`, proves `EVIOCGRAB` is never attempted, closes the descriptor, and publishes no input or render callback |
| warm app switch retains current proximity without retaining the old pointer | `InkThreadTest.WarmSessionSwitchRemovesOldHoverAndRehydratesCurrentProximity` covers terminal `Remove`, resync `Add`, current position, and cleared prediction; `EvdevSource` requires current key state plus `ABS_X`/`ABS_Y` after draining the pre-grab queue |
| stationary app hover animations remain accelerated | `PenRenderHintMailboxTest.InitialNoPenSnapshotIsNotTerminalButActivePositionIsSticky` and `FrameRendererTest.OneHoverHintAcceleratesTwoLocalAppFramesButNoPenSnapshotDoesNot` distinguish a sticky in-range scheduling position from a fresh no-pen snapshot and prove two app frames from one hover sample |
| queued/coalesced hover frames retain correlation | `FrameRendererTest.QueuedFastHoverFramesCorrelateWithBoundedHistory`, `CoalescedStrokePrioritizesNewestMatchingTip`, `OverlappingFutureHintSurvivesOlderRasterFrame`, and `PenRenderHintMailboxTest.ConcurrentSnapshotsNeverMixGenerations` |
| hover draw, removal erase, and expiry | `PenRenderPolicyTest.HoverIndicatorDrawAndEraseAreAssociated`, `FrameRendererTest.TerminalHoverEraseUsesRetainedRoiButExitDrawsNothing`, and `StaleTerminalHoverRoiCannotCaptureLaterAppDamage` |
| distant/disconnected animation stays normal | `PenRenderPolicyTest.DistantAppDamageIsNeverPenAssociated` and `DisconnectedColorDamageDoesNotInflateNibComponent` |
| erasing never becomes black | `FrameRendererTest.AppRenderedEraseNearHoverIsFastThenTruthAndNeverBlack` |
| a broad multi-tile brush cannot seize the panel | `FrameRendererTest.BroadMultiTileBrushSplitsHotLaneAndEraseTruthUsesNewestPixels` verifies a smaller capped Fast window, ordinary residual damage, white erase preview, and latest-white truth across four tiles |
| scroll pacing cannot hide nearby pen damage | `FrameRendererTest.PenDamageInsidePacedScrollBypassesBodySuppressionAndChasesTruth` keeps the body below its emission cadence while an app-owned hover indicator inside it still receives Fast preview and queued truth; unmatched body pixels remain paced |
| draw-back uses newest pixels without a bbox union | `FrameRendererTest.DrawBackBeforeTruthUsesNewestAppPixels`, `RegionSchedulerPenDamageTest.ContainedDrawBackCoalescesWithoutLosingOldestTruthTurn`, and `BridgingColorPromotesComponentWithoutBoundingBoxUnion` |
| same-luma recolor and color erase are not lost | `FrameRendererTest.SameLumaHueChangeIsDamageAndChasesLatestRegionalRawColor`, `LumaOnlyBackendStillDetectsSameLumaAppHueChange`, and `ColorEraseToWhiteStillGetsFullTruthButNearbyGrayChangeStaysText` |
| color is gray-fast then raw regional truth on a color-capable backend | `FrameRendererTest.ColorAppDamagePreviewsGrayThenChasesRegionalRawColor`; section 7 records the monochrome/color profile split |
| Full pen truth stays regional | `Gallery3DrmPresenterTest.PenTruthFullPreservesRegionalRequest` and `MxcfbBackend.PenTruthFullPreservesExactRegionalDamage` |
| preview precedes immediate truth | `RegionSchedulerPenDamageTest.PreviewDispatchesBeforeTruth`, `SynchronousPreviewCompletionDispatchesTruthImmediately`, `OverlapSupersedingPresenterChasesTruthInThePreviewTick`, plus blocked/decline/maintenance-order cases |
| pen truth supersedes ordinary queued, parked, and later damage without filling gaps | `RegionSchedulerPenDamageTest.NewTruthCutsQueuedFastAndUiWithoutRecoalescingTheHole`, `DisjointQueuedFastRectsCannotMergeBackAcrossTruthGap`, `ReverseTemporalTruthExpansionRecutsOlderExactWork`, `NewTruthCutsAlreadyParkedGenericWithoutLosingItsRemainder`, `TextTruthPreservesOlderFullQualityInsideAndOutsideTheCut`, and `GenericDamageDuringPendingAndInflightTruthStaysInTruthLane` |
| cross-lane overload is bounded and conservative | `RegionSchedulerPenDamageTest.DeepResidualPrefixSurvivesLocalTailReconciliation` protects existing exact work while only a new tail is cut; `ExactResidualCapPromotesOverflowInsteadOfDroppingOrBoundingFast` proves the emergency newest `Full` truth path |
| ordinary Full does not add pen latency, but reset remains exclusive | `RegionSchedulerPenDamageTest.OrdinaryFullDoesNotBlockDisjointPreviewOrTruth` and `PixelResetAnyClassStillBlocksPenLanes` |
| exact geometry stays bounded under overload | `RegionSchedulerPenDamageTest.MultipleRoutesBeforeOneTickStayExactAndLeaveGapDispatchable` and `MoreThan64StalledDiagonalSegmentsFallBackToBoundedCells` |
| every presenter batch has disjoint rects | `RegionSchedulerPenDamageTest.PartiallyOverlappingSegmentsAreDisjointWithinEveryPresenterBatch` covers overlapping Fast and regional-Full segments while preserving the presenter ABI contract |
| PixelEngine does not create an unsafe collision shortcut | `PixelEngineTest.PenPreviewRidesAlongInFlightSameModeTileInsteadOfParking`, `PenPreviewNeverRetargetsThroughDifferentTemperatureLut`, `PenPreviewPreemptsCoveredInFlightTruthAtScanBoundary`, and `PenPreviewDoesNotPreemptUncoveredActiveTruthPixels` |
| temperature packaging and cold start use one exact record | `AdmissionMailboxTest.RoundTripsHeaderAndPayload`, `PixelEngineTest.ExplicitAdmissionBinSurvivesCurrentTemperatureChange`, `TemperatureBinSelectorTest.*`, and `SwtconTemperatureTest.StartSamplesPanelSynchronouslyBeforeReturning` |
| sustained subscribers have bounded bookkeeping | `RegionSchedulerPenDamageTest.MoreThan256ContinuousPreviewsDoNotHitInflightCapacity`, `PixelEngineTest.FiveHundredTwelvePenSubscribersCompleteWithoutACliff`, and `CompletionQueue.DrainsInArrivalOrder` (513 completions) |
| prediction/resync resets safely | `InkThreadTest.ReversalLongGapAndResyncResetStaleExtrapolation`, `KernelResyncSnapshotCannotExtrapolateAcrossDroppedSamples`, device-loss and session-reset tests |
| rotation cannot resurrect stale coordinates/geometry | `PenRenderHintMailboxTest.RotationGenerationRejectsLateOldHint`, `FrameRendererTest.RotationRequiresPresenterIdleBeforeGeometryRebuild`, and `LateOldGeometryFrameCannotUndoRotation` |
| completion delivery cannot cross a renderer generation | `DrmSwtconPresenterTest.WaitIdleIncludesCompletionCallbackDelivery` blocks the callback and proves zero-timeout idle remains false; `NullAndThrowingCompletionCallbacksCannotStrandIdle` covers both cleanup edges; `FrameRendererTest.RotationAndDetachDrainCompletionBeforeFrameIdReuse` proves delivered old IDs are drained before rotation/detach rebuilds reuse frame ID 1 |
| final phase and cold clear cannot be mistaken for idle | `ScanLoopTest.ReadySlotRemainsUnacknowledgedUntilFlipEvent`, `DrmSwtconPresenterTest.WaitIdleFencesFinalReadySlotUntilLatchAcknowledgement`, and `WaitIdleIncludesColdClearThroughItsFinalLatch` distinguish producer take, engine completion, callback delivery, and the actual DRM latch |
| active-reset detach cannot lose newest app truth | `FrameRendererTest.ActiveResetDetachFencesNewestLedgerFollowupBeforeGenerationReset`, `ActiveResetDetachBackpressureHonorsAbsoluteDeadline`, and `ActiveResetDetachWithoutWaitIdleCannotRetireAnUnfinishedRail` cover the follow-up generation, ready=false with idle presenter, and a backend without an optical fence |
| hover/contact event parity | `InkThreadTest.EveryCoherentHoverAndContactSampleEmitsOnePureHint` and replay-vs-bare-tracker test |

The native host gate builds debug and release, runs renderer replay, renderer,
input, embedder-core, native-driver, presenter, and glass-handoff suites, and
repeats the concurrency-sensitive paths under ASan+UBSan and TSan. A restricted
sandbox may deny the fake `wpa_supplicant` Unix-socket fixtures; that limitation
must be reported and rerun in a permission-correct environment rather than
counted as a product failure or a pass. The process-unique replay work directory
is also exercised by running debug and release replays concurrently.

## Performance loop

Pen-policy and scheduler hot storage is fixed or reserved during
configuration, and the input/source buffers are reused across SYN reports.
The microbenchmarks keep fixture creation outside timed loops and assert their
routes before measuring.

The table below is the final seven-run `host-release` result. Each host cell is
the median of the seven reported per-run p50 or p99 batch means. Device cells
remain pending until the USB device returns.

| Bench | Host p50 | Host p99 | Device p50 | Device p99 | Budget |
|---|---:|---:|---:|---:|---:|
| hint-only policy early exit (zero dirty records) | 0.002 us | 0.003 us | pending | pending | <= 1 us device p99 |
| hover association, 16 dirty records | 0.361 us | 0.403 us | pending | pending | <= 5 us device p99 |
| contact association, 16 dirty records | 0.360 us | 0.409 us | pending | pending | <= 5 us device p99 |
| preview + Text truth submit/tick | 0.128 us | 0.151 us | pending | pending | <= 20 us device p99 |
| 351 active truth cells + 768 unrelated exact residuals | 1.250 us | 1.625 us | pending | pending | <= 20 us device p99 |

The adversarial scheduler row initially measured 320.166/365.875 us p50/p99
when each new truth re-cut all residual history. Reconciling only the newly
appended tail preserves the exact same pieces and improves this case by about
256x/225x. No delay, coalescing shortcut, or dropped geometry produced the
gain. The fixture now asserts that its 768 prefilled plus 128 timed
submissions leave exactly 896 residual entries.

Seven-run presenter medians keep every NEON stage below one 11,764 us scan
period: fused full-field is 1672.1/1844.9 us p50/p95 and full-panel conversion
is 328.9/346.5 us. The exact RGB565 ct33 front end is 1755.5/1821.0 us
full-panel and 9.8/10.6 us for 96x96; masked variants are 2614.1/2704.2 us and
14.2/16.0 us. These are CPU times, not optical latency, and ct33 remains gated
from presentation by installed-runtime end-to-end parity and Fast-bridge
optical ownership.

Selector-16 also has a fixture-free `--selector-only` release benchmark. Its
timed interval includes regional ARGB expansion, lifetime-scratch updates,
classification/resolution, and allocation of the immutable returned mask; it
excludes object/thread and source-fixture construction. Seven host runs give
these medians:

| Selector operation | ARGB p50/p95 | RGB565 p50/p95 |
|---|---:|---:|
| full `954x1696` panel | 1658.7 / 2159.2 us | 2420.6 / 2496.4 us |
| pen-sized `96x96` region | 18.7 / 19.4 us | 25.0 / 25.7 us |

The first staged implementation woke the coordinator between every stage and
measured 39.9/43.5 us ARGB and 47.9/51.5 us RGB565 for `96x96`. Persistent
workers now receive one operation, rendezvous internally at both barriers,
and small regions keep the identical three-stripe stage order serially when
that is faster. This improves the pen-sized p50/p95 by about 2.1x/2.2x for
ARGB and 1.9x/2.0x for RGB565 without delaying, coalescing, or dropping any
pixel work. Full-panel selector CPU time remains far below one 11,764 us scan
period. These figures are still CPU timings, not optical latency.

The sub-microsecond policy figures emitted by the benchmark are per-operation
batch means, not end-to-end pen latency. In particular, “hint-only” measures
the policy's zero-record early return; it does not include evdev, Flutter
rasterization, presentation, or the optical waveform. End-to-end conclusions
must use device traces and visible panel evidence.

Budgets live in `embedder/bench/renderer/budgets.yaml`; commands and the
complete renderer benchmark log live in [`optimise.md`](optimise.md).

When `PLUTO_RENDERER_TRACE=1`, a routed frame logs region count, exact
per-frame and cumulative changed-pixel counts, hover/contact state, and both
oldest- and newest-correlated evdev-hint-to-frame latency. The oldest value
exposes a coalesced-frame tail while the newest value measures the current
tip; neither is silently overwritten by the other. This splits app/raster
delay from scheduler CPU cost and optical completion.

## Attached-device deployment and acceptance

This section remains pending. It must be filled from the final device run and
is not satisfied by host logic alone.

### Native capability gate

The production session launches only `--presenter=native`. The selected panel
profile must prove controlled Fast preview, exact regional Text/Full truth,
real completion at its kernel-marker or final scan-latch boundary, erase and
draw-back correctness, and no system-owned pen pixels. Monochrome RM1/RM2
acceptance covers luma truth; Move acceptance additionally covers exact color
truth through its profile-pinned native color pipeline. Static analysis,
reference models, and host tests are prerequisites, but none substitutes for
camera-visible glass evidence on the exact device.

### Build and deployment

Build the exact release commit through the universal assembler for both target
slices, then provision each tablet through the same public CLI. The target,
engine pin, release-AOT metadata, native ELF ABI, generated device profile, and
payload hashes must be verified before the device is mutated. Record the local
payload digest and installed file hashes for each run; never deploy an older
cached tree merely because it once passed a different device.

### Device benchmark

Run the target-native release benchmarks seven separate times on RM1, RM2, and
Move. Pin to a core with `taskset` when available, retain every raw row, and
report medians using the same method as the host evidence. Host or container
timings are not substitutes for exact-device values.

### Visible acceptance

Camera/log validation on every supported device must cover:

1. pen hover/contact over a non-drawing app: no marks;
2. app-rendered hover indicator: fast local draw and erase;
3. app-rendered stroke/erase: Fast preview followed by newest Text/Full truth;
4. Home opens, at least two apps switch in both directions, and warm state is
   preserved without stale or black synthetic residue;
5. the root-local acceptance control sends its deterministic stroke to Ink and
   a fresh camera frame shows that Ink rendered it;
6. screenshots, process identity, release-AOT metadata, and presenter health
   match the foreground app; and
7. `exclusive=EVIOCGRAB clock=monotonic` in the pen-open log, proving both
   exclusive ownership and the timestamp domain used by terminal-ROI expiry.

## Deliberate non-goals and future work

- The generic path will not accept brush/color/nib hints to synthesize pixels.
  An app-specific front buffer would require explicit opt-in and app-owned
  content semantics.
- The renderer does not force a present on proximity. That would waste power
  and create optical work with no changed pixels.
- Prediction does not extend past one scan frame until optical tests show a
  clear benefit without visible correction artifacts.
- Beam racing/mid-scan row injection remains future work. It touches panel
  timing and requires a photodiode/high-speed-camera proof, not inference.
- Optical pen-to-first-change should ultimately be measured with a
  synchronized pen-contact trigger and a high-speed camera on the panel.
