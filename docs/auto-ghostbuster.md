# Automatic Ghostbuster

> **Pen-rendering correction (2026-07-11):** Pen fidelity work now means a
> fast preview and immediate truth presentation of verified app-rendered diffs.
> There is no provisional native black overlay and no pen-up timer. This is
> separate from optional ghost maintenance. See
> [Pen fast rendering](pen-fast-render.md).

Date: 2026-07-11

## Decision

Pluto now runs rare, native-only full-screen ghost maintenance when accepted
panel drive history says a large part of the glass needs it. The controller is
inside the embedder's `FrameRenderer`, where it can see real presenter work,
input state, frame quiescence, scheduler load, and foreground lifecycle. It
does not add a Dart API, app hint, route annotation, or application opt-in.

This is a safety layer above the existing regional ghost ledger and idle
settle planner. Regional Text/Full settles remain the cheap first response.
Automatic Blink/Bleach is reserved for broad, repeatedly driven debt that the
normal local policy did not already repay.

The controller detects **drive exposure**, not optical pixels. There is no
camera or reflectance sensor in this loop, and framebuffer RGB cannot reveal a
yellow cast on the physical glass. “Yellowing” below therefore means a
conservative, non-decaying **pigment-hygiene debt proxy** built from accepted
Fast/UI rail work. Intended yellow application content and
`ChromaPendingSet` are explicitly not used as yellowing evidence.

## Why this matches the useful part of Xochitl

The relevant recovered Xochitl 3.27 stock behavior is:

- every recovered semantic `viewChange(...)` value merely arms `BlinkLater`;
- the next real framebuffer update consumes that pending bit, expands it to
  full-screen coverage, and coalesces the cleanup with useful work;
- Gallery 3 separately performs a very rare hard safety cleanse every 300
  `retailRefresh()` calls;
- immediate Blink/FactoryReset block Xochitl's Qt caller until framebuffer
  work drains;
- no recovered `IGhostBuster` method automatically selects `BleachNow`.

Pluto keeps the same “latch now, execute at the next convenient native
boundary” shape without reproducing Xochitl's QML hints. Accepted drive debt
finds broad change-blindness automatically, while input/frame/scheduler gates
choose the convenient boundary. Automatic Bleach is a new Pluto policy,
not a claim about stock Xochitl.

## Signals and thresholds

The policy owns two preallocated Q8 debt planes on the renderer's existing
32 px tile grid. On the 954 x 1696 Move this is about 1,590 tiles.

Only an ordinary presenter request that was actually accepted contributes:

| Accepted class | Ghost debt | Pigment debt |
|---|---:|---:|
| Fast | `768 * covered_fraction` | `768 * covered_fraction` |
| UI | `512 * covered_fraction` | `512 * covered_fraction` |
| Text | proportionally repays covered ghost debt | unchanged |
| Full | proportionally repays covered ghost debt | unchanged |

Pixel-reset rails, their retained-content restore, and sparkle maintenance are
excluded so cleanup cannot charge itself and loop. Partial-tile arithmetic
carries fractional remainders instead of rounding repeated tiny updates down
to zero. Coverage uses the real clipped pixel area of edge tiles. A qualified
tile also has a half-threshold low-water latch, so a one-pixel Text/Full edge
cannot forgive an otherwise unrepaired 32 px tile.

The initial conservative production thresholds are:

| Reason | Per-tile high threshold | Required display area | Low-water cancellation |
|---|---:|---:|---:|
| Ghost / Blink | 6,144 Q8 | 55% | 35% |
| Pigment / Bleach | 12,288 Q8 | 35% | 20% |

6,144 Q8 is eight full-tile Fast passes or twelve UI passes. 12,288 Q8 is
sixteen Fast passes or twenty-four UI passes. These are intentionally much
higher than the ordinary settle thresholds: a broad two-frame view change
must not cause a disruptive global reset when a normal quality settle can
repair it.

Crossing both the per-tile and display-area high thresholds latches a reason.
Time and input changes cannot forgive it. Accepted Text/Full quality work can
cancel a pending ghost reason only after qualified coverage falls through the
lower hysteresis threshold. Ordinary Full is deliberately not accepted as
proof that a gold/orange pigment cast was bleached: only a completed
Bleach/Both plan repays pigment debt.

Pigment debt and automatic global maintenance are enabled only when the native
panel profile reports distinct waveform-class control and real device
completion. A presenter without both capabilities fails closed for global
actions. Partial-work input gates and the unsupported-Sparkle no-op defense
remain active; host/null preview paths also fail closed.

## Partial-area maintenance policy

Real-panel feedback rejected the previous “many tiny partial repairs” policy:
white regions visibly blacked out and often returned more gold/orange than
before. The presenter ABI carries rectangular damage, not the 1/256 per-pixel
mask required by a sparse color-develop sweep. Treating that mask as an
ordinary rectangle would refresh far more pixels than intended.

Production now follows these rules:

- presenters accept unsupported Sparkle/Develop requests as no-ops, as required
  by the contract;
- color develop sparkle is disabled, and mode-8 top-off is disabled on the
  physical pigment panel; sparse SWTCON development remains laboratory work
  until camera-validated behind a real capability bit;
- inferred rail/deep debt never becomes `ChromaPending` and never promotes a
  regional Text settle into flashing Full;
- regional ghost-only debt uses non-flashing Text, including a broad backlog;
- regional Full is reserved for actual undeveloped chromatic app content;
- native presenters do not stress-promote Text tiles into a deeper waveform.
  DC/pigment hygiene waits for the rare serialized global Bleach restore;
- speculative regional black/white “partial bleach” was rejected: sharp rail
  boundaries add bloom/DC risk.

Intrusive regional maintenance (ordinary Full and any future sparkle) is held
while touch or pen proximity is active and for the same 500 ms release grace.
Already queued maintenance remains owed. The presenter boundary rechecks the
atomic input state, so an edge racing the scheduler cannot start a black-square
job. Pen-priority truth is different: it presents verified app pixels and may
complete during hover without waiting for a pen-up timer. It is required
content delivery, not optional ghost maintenance. If a native profile cannot
promise non-flashing Text semantics, every other background settle is treated
as intrusive.

## Action selection

Automatic actions use an internal rail plan so the cheap and combined cases
remain distinct without changing the public `GhostControlMode` API:

| Pending reasons | Automatic plan | Full-screen stages |
|---|---|---:|
| Ghost only | Blink | Fast black, Fast white, Fast retained content (3) |
| Pigment only | Bleach | two Fast black/white cycles, Full retained content (5) |
| Both | Blink + Bleach | three Fast black/white cycles, one Full retained-content restore (7) |

Pluto submits every solid rail as Fast and never requests mode 0/INIT. The
profile-selected native driver maps Fast to its pinned short rail program. A
Bleach/Both restore is Full so the panel gets one genuinely balanced content
pass instead of many regional deep-waveform mosaics. It does not force
identity, which would serialize the field into visible horizontal bands. When
both reasons are due there is one operation and one final restore.

The public/manual API remains unchanged: user-visible `BlinkNow` and
`BlinkLater` retain the empirically proven composed Blink-plus-Bleach behavior
documented in `app-pause-resume.md`. A successful manual run acknowledges the
matching automatic debt so it is not immediately repeated.

## When it may start

A latched action starts only when all gates are true:

1. no raw touch contact is live, including palm- or pen-suppressed contacts;
2. the pen is out of digitizer range, not merely lifted from contact;
3. at least 500 ms has elapsed since the combined touch/pen active-to-idle
   edge;
4. at least 300 ms has elapsed since the latest accepted visible panel work;
5. the region scheduler is fully idle: no user, pen, settle, parked, or
   in-flight work;
6. presentation is not suspended for a no-flash system-UI handoff;
7. the native supervisor still marks this process foreground and maintenance
   eligible;
8. no reset is active, no failure backoff is active, and the success cooldown
   has expired.

The local settle planner and scheduler run first at that idle boundary. An
accepted cheap Text repayment can lower/cancel ghost debt; global Blink is the
fallback only if broad debt remains and the scheduler is still empty. On a
capable native presenter this makes global Blink intentionally uncommon; local
Text usually cancels the reason first.

Touch-up or pen-out only removes a gate. It never creates debt or schedules an
action, so ordinary gesture endings do nothing unless a broad need was already
present. Continuous animation continually moves the accepted-work timestamp
and keeps the scheduler busy; cleanup waits for the first natural rest rather
than cutting into a 24 ms animation interval.

Home, app-switcher, hibernate, and shutdown requests close the supervisor gate
immediately, before their asynchronous handoff work. Resume reopens it only
after the presenter, input services, lifecycle, and first scheduled repaint
are live. Independently, reset eligibility stays closed until an updated
post-attach Flutter packet has reconciled this app's retained content with the
possibly different warm-app glass handoff. A separately suspended system
surface remains protected by its presentation gate.

If input races an automatic rail, the final presenter-boundary check refuses
the next black stage. Once black was already accepted, white and retained
content are safety recovery and must finish even if input begins; remaining
optional cycles are cancelled and the debt stays owed for a later retry.

## Flutter render hold

Once current panel work has drained and immediately before the first black
rail, `FrameRenderer` asks `VsyncPacer` to hold Flutter rendering. The pacer
retains future vsync batons instead of calling `FlutterEngineOnVsync`, so no new
Flutter raster frame starts during the optical sequence.

This is deliberately narrower than process suspension or an app lifecycle
pause:

- Dart timers, event handling, platform tasks, and the warm isolate remain
  alive;
- touch/pen input state continues to be observed;
- the presenter and scan threads keep running, so the rails can finish;
- no app sees an artificial paused/resumed lifecycle transition.

After retained content completes, the hold releases with fresh timestamps and
a real next-vsync target (never a zero-budget `start == target`). Every queued
baton is returned. Shutdown first stops accepting scheduled grants, drains,
deinitializes Flutter, then performs a second atomic drain/disconnect for a
callback that raced the first swap. Flutter content already rasterizing when
the hold began may finish into the retained ledger, but ordinary glass updates
cannot interleave and the final restore uses the newest retained truth.

## Failure and rate limits

The rail state machine waits for real native presenter completion between every
black, white, and restore stage. It has two safety bounds:

- after 15 seconds, a stuck action attempts a retained-content recovery;
- after a further 5 seconds, Flutter raster is released so Dart/UI work may
  continue into the retained ledger, but panel presentation remains serialized
  until retained content actually completes.

Rotation is refused while a rail transaction owns the panel. Hibernate and
warm detach fail closed and keep the presenter attached if recovery has not
completed. Normal shutdown gives the state machine the full recovery window
plus margin before closing the presenter. A physically lost/non-responsive
device, an external `SIGKILL`, or expiry of that final shutdown fence is an
unrecoverable exception; software cannot guarantee a restore after panel
ownership has been forcibly removed.

A failed automatic action keeps its debt and retries with exponential backoff:
5, 10, 20, 40, 80, then at most 120 seconds. A successful action starts a
ten-minute cooldown, limiting a live renderer to at most six automatic runs per
hour. The exact retained frame and automatic policy state survive
same-geometry, same-process presenter detach/attach. A fresh other-app glass
handoff may replace the renderer ledger, so the first updated packet performs
a full reconciliation before action eligibility opens. It is not yet a
cross-process persistent panel ledger. A cold process/supervisor restart—or a
renderer geometry rebuild for rotation—resets automatic debt and cooldown
state; this limitation is intentionally documented rather than claiming a
device-global rate cap. Manual requests are not rate-limited, but successful
manual maintenance repays pending automatic debt.

Blink success repays ghost debt only. Bleach and the combined plan repay both
planes. Debt accepted after an automatic action begins is tracked in separate
preallocated scratch planes and survives completion, so a new reason cannot be
lost behind an in-progress run.

## Cost

Steady-state overhead is bounded and allocation-free after renderer setup:

- accepted work touches only the tiles already covered by its damage rects;
- qualified pixel totals are maintained incrementally, so the 100 ms policy
  poll does not scan the whole panel;
- input publication is two atomic state bits plus one timestamp and occurs on
  state edges, not on every 100+ Hz pen sample;
- policy work runs under the renderer's existing scheduler mutex and adds no
  thread, timer, polling file, IPC, or app callback.

The debt, fractional-remainder, and qualification planes use roughly a few
tens of kilobytes at Move geometry.

## Code and verification

Primary implementation:

- `embedder/src/renderer/auto_ghostbuster.{h,cc}`: pure policy, ledgers,
  thresholds, hysteresis, gates, cooldown, and failure backoff;
- `embedder/src/compositor/software_compositor.{h,cc}`: accepted-present feed,
  automatic selection, 1/2/3-cycle rail plans, serialized restore, and
  timeout recovery;
- `embedder/src/engine/engine_host.cc`: raw touch/pen proximity and foreground
  supervisor gates;
- `embedder/src/runtime/vsync_pacer.{h,cc}`: render-only hold and lossless baton
  release;
- `embedder/src/renderer/{settle_policy,region_scheduler}.*` and
  `embedder/src/presenter/{native,swtcon}`: intrusive partial gating, required
  pen-truth provenance, unsupported-operation defense, and prevention of
  regional deep-waveform stress promotion.

Coverage includes pure policy tests for every action, exact thresholds,
pixel-area accounting, input/busy/suspension gates, low-water cancellation,
cooldown, failure backoff, external/manual repayment, and debt arriving during
an active run. FrameRenderer tests exercise distinct Blink/Bleach/Both stage
counts, Fast-vs-Full restore selection, touch deferral, and teardown recovery.
Regional tests cover a gated mixed Full/required-Text queue, chroma deferral,
and sparkle pause. Vsync tests cover a held request, correct target timestamps,
multiple baton preservation, concurrent shutdown callbacks, and final drain.

Host verification is necessary but not the final optical acceptance criterion.
The 2026-07-11 ARM64 build was deployed to the Move as SHA-256
`77ffac44396ab1b3dd9c934a461302c5cfa3aaf2fe772745435e6d9196d015f3`;
the guarded supervisor restart came back as release AOT on direct SWTCON. One
deterministic SIGHUP run exercised the current
composed path: raster hold, three Fast black/white cycles, balanced Full
content restore, raster resume, and the same live PID. It completed in 5,710 ms
with all 1,617,984 pixels active and zero parked, dropped, clipped, or
superseded admissions.

That proves the deployed sequencing and completion path, not the residual
color of the physical glass. The attempted Mac-camera still did not frame the
tablet and is not evidence. The earlier 2.12 s traces used an all-Fast retained
restore; the new Full restore and partial suppression still need a properly
framed real-panel before/after capture. Before lowering thresholds, score
ghost/yellow residuals across repeated broad Fast/UI transitions. Code-level
dispatch labels alone cannot prove the optical outcome.
