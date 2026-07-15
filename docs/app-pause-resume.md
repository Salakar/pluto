# App pause and resume

> **Pen-rendering correction (2026-07-11):** There is no native wet-ink plane
> or pen-up cleanup timer to preserve across lifecycle changes. Apps own all
> pen pixels; hover/contact render hints contain no damage and are discarded
> when input stops. See [Pen fast rendering](pen-fast-render.md).

Pluto release and profile apps resume from a warm in-memory process after an
app switch. Their Flutter engine, AOT Dart isolate, heap, navigation stack,
widget state, and open conversation state remain alive. Only the foreground
app owns the display, touchscreen, pen, bezel gesture, and presenter threads.

This is intentionally a warm process pool, not a disk or CRIU snapshot. Flutter
and the Dart VM do not expose a supported general-purpose live-heap snapshot,
and restoring kernel DRM/evdev state from a process checkpoint would be unsafe.
Warm suspension preserves more state, has less serialization overhead, and is
naturally cleared by a reboot.

## Handoff sequence

When a release/profile app requests `pluto/session.launch`, `home`, or
`sleepNow`, the following sequence runs:

1. The control marker is written for the session supervisor.
2. The embedder responds to the platform-channel call, then sends
   `AppLifecycleState.inactive` and `AppLifecycleState.paused` to Flutter.
3. Touch, pen-input/render-hint, and bezel-redraw workers stop and release their
   evdev/IIO handles. Pen trajectory state is discarded; there is no native ink
   plane or delayed pen-up work to carry across the pause.
4. The renderer fences outstanding panel work and stages its correlated
   RGB565, ledger, scheduler and debt state. The presenter freezes admissions,
   resolves the final DRM content scan latch, captures settled PixelEngine and
   Xochitl history state on the engine thread, then detaches and closes DRM.
   The stable Flutter compositor object remains alive.
5. The embedder atomically publishes `/run/pluto/hibernated/<pid>`.
6. Only after seeing that acknowledgement, the supervisor sends `SIGSTOP`.
   The stopped process consumes no CPU while retaining its private memory.
7. The supervisor starts or resumes the selected app after the panel is free.

For a warm resume, the supervisor sends `SIGCONT` and `SIGUSR2`. The embedder
reopens the presenter and provisionally loads the current glass handoff. The
compositor validates and imports the correlated renderer state, then confirms
the same candidate; only this joint confirmation permits the presenter to skip
the cold clear. The embedder then sends fresh display metrics, sends lifecycle
`inactive` → `resumed`, reacquires input, schedules a Flutter frame, and removes
its hibernated marker. The supervisor republishes that same PID as the
foreground embedder. A rejected or absent candidate follows the normal cold
clear without changing the warm-process lifecycle.

## Exact-color glass-state transaction

The glass handoff is not a Dart-heap or process snapshot. It is a short-lived,
schema-v2 display-state bundle at `/run/pluto/glass.handoff` that lets two
otherwise independent embedder processes agree on the physical starting point
for the next diff. Schema v2 is a clean break: the old monochrome plane-only
format has no compatibility reader and is conservatively rejected.

For the Paper Pro Move, the bundle contains:

- the complete 968×1698 Xochitl allocation as interleaved 16-bit A/B history,
  including guard pixels and history/flag differences whose visible low-5-bit
  levels happen to be equal;
- settled PixelEngine DC, stress and rescan debt plus engine/admission
  temperature bins. The visible engine baseline is proven against and rebuilt
  from Xochitl A, while Xochitl retains ownership of its padding and guards;
- the renderer's retained RGB565 frame and FrameLedger level/chroma mirrors,
  classification ladder, ghost/stress/chroma debt, settle planner,
  AutoGhostbuster, regional scheduler, scroll/input state and maintenance
  counters.

An outgoing renderer may stage this state only when its scheduler, completion
queue, pixel-reset/maintenance work and input focus are idle. The presenter then
requires empty admission lanes and journals, no outstanding Xochitl work,
mapped terminal fences or Safe Fast reconciliation, no pending engine estimate,
completion, pause, drop or color fault, and a resolved final DRM scan latch.
Admissions are frozen before the engine-thread snapshot. After its worker and
scan threads join, `close()` audits every mutable owner again and publishes
only if the same quiescent facts still hold.

The file is explicitly encoded little-endian rather than dumping C++ objects.
The writer creates a same-directory `0600` temporary file, writes and `fsync`s
it, atomically renames it, and synchronizes the parent directory. An incomplete
or unsafe close attempts to remove both final and temporary names and verifies
their absence. The loader requires exact file layout/EOF and section sizes;
valid header, section and payload CRC-64; the same boot and at most 60 seconds
of age; a chain below the eight-handoff limit; and exact geometry, RGB565
format, profile, waveform, ct33, pipeline and renderer-configuration identities.

A move-only, PID-bound namespace lease serializes display owners independently
of the bundle name. The presenter takes a nonblocking exclusive lock on the
persistent private `glass.handoff.lease` inode before it opens or programs DRM,
revalidates that inode before every load/save/claim/discard, and holds it until
after the final bundle decision and DRM close. The lease inode is never
unlinked in production, so it cannot split into two independently locked
generations. Process death releases the kernel lock automatically; a contender
returns before `open_card` or `set_crtc`. This also prevents an old closer from
discarding a successor's state or a new saver from publishing behind a claimed
generation.

`XochitlHistoryState` and `PixelEngine` import is provisional until the
compositor validates the renderer payload against scratch component state and
imports `FrameLedger` plus every renderer mirror as one transaction. Rejection
restores the cold engine/renderer baseline and runs the existing cold clear. A
successful pair is committed together, then the bundle is durably unlinked
before the first content admission. If that invalidation cannot be proved, the
presenter refuses to admit pixels rather than risk publishing glass state that
a later process could mistake as current. This preserves atomic-write,
first-admission unlink and crash safety: a crash before first admission leaves
an accurate candidate, while a crash after glass diverges leaves no candidate.

Exact color is positively routed, never inferred from approximate geometry.
Production enables profile `XG3M` only when logical 954×1696 RGB565, engine
stride 960/tile 32, 968×1698 history, `/sys/devices/soc0/machine` equal to
`reMarkable Chiappa`, and `/sys/devices/soc0/soc_id` equal to `i.MX93` all
match. Supporting another panel requires adding another complete profile row
with its own identity; an unrelated device cannot fall through to the Move
layout. Serialization and memory/CPU measurements are recorded in the
[renderer optimisation log](optimise.md).

The protocol also covers the physical power button. A completed press shorter
than two seconds follows the standby path: the watcher asks the foreground app
to quiesce with `SIGUSR1`, and the warm pool stays stopped while the standby
screen owns the panel and while Linux suspends. After wake, the launcher is
normally resumed rather than reconstructed. Holding the key continuously for
two seconds takes the separate full-screen power-menu path described below.

## Power menu and shutdown

The power-key watcher owns the short-press/long-press split. A fresh
`KEY_POWER` down edge starts a two-second one-shot timer; kernel autorepeat
events are ignored. If the matching release arrives first, the watcher cancels
the timer and performs the existing standby transaction, including the exact
frontlight snapshot. If the timer wins while the key is still down, it publishes
`/run/pluto/power-menu` and does not create either standby marker. The race is
resolved atomically, so one physical press can request only one path.

The supervisor hibernates the foreground release/profile app, records its id in
`/run/pluto/power-menu-active`, and starts or resumes the launcher as a temporary
full-screen system host. The same native presentation gate used by the switcher
prevents a retained Home frame from flashing before Flutter has routed the
power screen. This works above Home, an app, or another temporary system surface.

The screen deliberately has two confirmations with different jobs:

- the physical key must remain held for two seconds to open the menu;
- the on-screen **Hold to turn off** control must remain held for three seconds
  to request shutdown. Releasing it early clears its segmented progress.

**Keep using Pluto** resumes the recorded origin app through the normal warm
launch path. A confirmed shutdown first paints and settles the static
`Good night` frame, then the launcher publishes `/run/pluto/poweroff` and
releases the presenter. Only after the launcher and all retained apps are off
the panel does the supervisor invoke `systemctl poweroff`. The final frame is
therefore intentional on bistable glass even after power is gone.

A short press while the power menu is visible still enters the unchanged
standby transaction. The initiating long press cannot accidentally do this:
the newly started watcher sees its repeats/release without a new down edge and
therefore never arms standby.

## Running-app switcher

The switcher is a system gesture owned by the native embedder and routed by the
session supervisor, so individual Flutter apps cannot accidentally shadow it.
Place two fingers next to each other in the bottom 2.8 cm of the glass and move
both inward by roughly 0.65 cm. The contacts may begin up to 350 ms apart, need
only move approximately together, and may be between 0.2 cm and 5 cm apart.
The bottom edge is resolved
from the app's live orientation: it is the short physical edge in portrait and
the corresponding rotated edge in landscape. Pen and palm-classified contacts
are ignored.

On recognition the embedder cancels the app's Flutter touch sequence, publishes
`/run/pluto/switcher`, captures a bounded BMP of the last submitted frame, and
performs the normal safe hibernation sequence. The supervisor snapshots its
warm-process recency list before it wakes the launcher. It writes that immutable
activation to `/run/pluto/switcher-active` as:

```text
<origin app id>
<most recently used background app id>
<next background app id>
...
```

The origin is excluded from the preview carousel. The first card is therefore
the last app used before the current one, which makes a repeated edge swipe and
tap a fast two-app toggle. The launcher itself is excluded at the supervisor,
native channel, and Dart model boundaries; it is the system host, never a
switchable application. Swipe horizontally to browse and tap the centered
screenshot to select. Passive centered dots are the only chrome. A selection
uses the ordinary release/profile launch control, so the supervisor resumes the
existing AOT PID rather than starting a new isolate.

Swipe the centered preview upward to close that background app. The launcher
publishes `pluto/session.forceStop`; the supervisor terminates the selected
process (continuing it first if it is stopped), removes its warm-pool and
hibernation records, deletes its retained preview, and removes its card without
tearing down the launcher host. The current/origin app is never offered as a
card, so it cannot be dismissed from underneath the switcher.

The gesture always opens the switcher, including from Home and when the
foreground app is the only running app. If no switchable background apps
remain, the launcher stays on a centered `No apps running.` empty state instead
of immediately returning Home or relaunching the origin.

Previews live under `/run/pluto/previews/<app-id>.bmp`. They are real retained
frames from the authoritative settled renderer ledger, downsampled to a maximum
640-pixel long edge and written with atomic rename. They are display-only—not a
process checkpoint—and disappear with
`/run` at reboot. The launcher deliberately does not overwrite its normal app
preview while it is hosting the switcher. If the switcher host crashes or exits
without a selection, the supervisor clears the activation and resumes the
origin instead of stranding it.

The launcher's presenter is gated during both warm resume and a cold system-UI
start: Flutter routes and decodes the screenshot first, then explicitly arms
native release on a newly scheduled frame. Updated and unchanged Flutter frames
both cross this gate. Native discards every hidden queued region and reveals one
full current-ledger frame, so the retained Home frame can never flash between
the outgoing app and the switcher. A two-second native watchdog forces the
latest full frame if decoding or the platform handshake fails, preventing a
stuck panel. Standby while a system overlay is visible publishes a reset marker;
the launcher restores Home behind the same gate after wake.

The UI uses snap paging rather than continuous tween animation. Each decoded
page change requests a quality full refresh, which keeps the e-ink interaction
responsive while preventing an old preview from remaining ghosted beneath the
new one.

## Top-edge Home gesture

The matching top-edge gesture uses the same native arbitration and warm
handoff. Place two adjacent fingers in the top 1.4 cm and move both inward by
roughly 0.65 cm. The top edge follows the app's live orientation, so landscape
uses the correctly rotated physical edge rather than assuming portrait panel
coordinates.

On recognition the embedder publishes the ordinary Home control and safely
hibernates the foreground app. The supervisor opens the launcher's normal Home
route directly. It does not create a temporary status-shade host or show a
system overlay, and returning to the app later resumes its warm AOT process.

## Bezel double-tap redraw

The accelerometer's bezel double-tap no longer writes the Home marker and never
switches, restarts, or hibernates an app. Each foreground release/profile app
and the launcher keep one persistent event reader. A recognized double-tap
starts an aggressive full-screen pixel reset, with a 750 ms debounce against
duplicate hardware events.

The renderer waits for current panel work, discards superseded queued damage,
then drives one full-screen Fast black/white BlinkNow cycle. Because a lone
blink left visible yellowing on the Move, production BlinkNow immediately
continues through the complete two-cycle BleachNow policy before a balanced
Full redraw of the newest retained application frame. Each native panel driver
maps the Fast rails and final Full restore through its profile-pinned waveform
contract and reports real completion before the next stage begins.
The rail bands overlap after a one-frame onset stagger; they do not crawl down
the display one budget-sized third at a time.

New Flutter vsync grants are held from the first black rail until retained
content completes. A frame already rasterizing when the hold begins may still
finish into the retained ledger, but ordinary panel partials cannot interleave.
The app, isolate, navigation, timers, and warm-process state remain intact.

The native renderer and `pluto_ui` expose the stock-compatible ghost-control
names `blinkNow`, `blinkLater`, `bleachNow`, and `factoryReset` on
`pluto/refresh`. BlinkNow and BlinkLater both mean one blink cycle followed
by the complete two-cycle bleach policy; BlinkLater merely defers that sequence
until later renderer activity. Standalone BleachNow uses two Fast rail cycles;
FactoryReset uses five. None of these operations uses mode 0/INIT.

For deterministic device diagnostics, sending `SIGHUP` to the foreground
embedder requests the exact same `blinkNow` renderer path as a recognized
bezel double-tap. This does not bypass the scheduler or presenter, so its
`pixel-reset` log timings measure the production blink/bleach/content sequence;
it only bypasses the accelerometer event. `SIGUSR1` and `SIGUSR2` remain
reserved for hibernate and resume.

## Pool and fallback policy

`PLUTO_MAX_WARM_APPS` controls the total resident release/profile processes,
including the foreground process. The default is `4`: launcher plus the three
most recently used apps. The supervisor tracks recency under
`/run/pluto/warm-apps` and cleanly terminates the least-recent process when the
limit is exceeded. Set it to `1` for foreground-only operation, or `0` to
disable warm caching entirely.

Warm processes remain release/profile AOT processes. Debug/JIT and hot-reload
launches are deliberately cold and one-shot so a development VM service never
gets frozen behind the tool. The standby screen is also one-shot.

The supervisor has bounded acknowledgement waits:

- `PLUTO_HIBERNATE_WAIT_TICKS` (default `240` × 50 ms = 12 s)
- `PLUTO_RESUME_WAIT_TICKS` (default `120` × 50 ms)
- foreground exit/replacement waits remain `120` × 50 ms

If native quiesce, presenter reopen, or acknowledgement fails, the supervisor
terminates that process, removes its pool entry, and cold-starts the app. A
crashed warm process is handled the same way. Exiting to stock drains every
warm process. Restarting the supervisor also drains an unadoptable old pool;
rebooting clears all processes and `/run` state by definition.

## Install and uninstall invalidation

Every CLI replacement path invalidates the warm process before changing its
files. This applies to direct app installs, provisioning, packaged `.plap`
installs with `--force`, and uninstall. The transaction order is:

1. Upload and validate the complete staged app.
2. Ask `pluto-app-control.sh stop <app-id>` to terminate the registered warm
   PID, a matching foreground PID, and any additional Linux processes whose
   environment identifies the same app. A matching foreground app is first
   handed safely to Home so the supervisor cannot restart the old bundle in
   the promotion window. A stopped process receives `SIGCONT` after `SIGTERM`
   so it can exit, followed by bounded `SIGKILL` fallback.
3. Remove warm, hibernation, and preview records.
4. Atomically rename the old install aside and promote the validated stage.

Validation therefore cannot take a working app down, while no old process can
hold the binary or later resume stale code after promotion. The next launch is
a cold AOT start from the newly installed bundle. The launcher is excluded from
the generic app-stop helper because it is the supervisor's active system host;
launcher updates remain part of the controlled provision/restart flow.

An ordinary release/profile `pluto run` request is different from install or
replacement: the CLI writes the launch request and leaves ownership of the
outgoing process to the supervisor's hibernate transaction. It must not send a
speculative `TERM`/`KILL`, because that can race the hibernation acknowledgement
and silently turn a warm app into a cold restart. Explicit debug/JIT launches
remain deliberately destructive and one-shot.

## App contract

Most Flutter apps need no special code. Ordinary in-memory state now survives
switches, and Flutter lifecycle listeners receive real pause/resume events.
Apps should still follow these rules:

- Persist durable user data. Warm resume is convenience, not crash or reboot
  recovery.
- Pause app-owned polling, audio, networking, or long computations from a
  lifecycle observer when receiving `paused`; resume them on `resumed`.
- Do not assume timers advance while backgrounded. The OS process is stopped.
- Revalidate external resources on resume. File descriptors owned by app Dart
  code are retained, but the peer, network, or mounted data may have changed.
- Keep app orientation policy in `pluto.yaml`; native display metrics are
  resent after presenter reacquisition.

## Operations and verification

Useful device state:

```sh
cat /run/pluto/embedder.pid
ls -l /run/pluto/warm-apps /run/pluto/hibernated
for pid_file in /run/pluto/warm-apps/*.pid; do
  pid=$(cat "$pid_file")
  echo "${pid_file##*/}: pid=$pid"
  sed -n '/^State:/p;/^VmRSS:/p' "/proc/$pid/status"
  tr '\0' ' ' < "/proc/$pid/cmdline"
  echo
done
```

Trace the display-state transaction and first visible latch with:

```sh
grep -E 'warm handoff|cold_clear=|first_visible_latch' \
  /home/root/pluto/logs/current.log | tail -n 30
```

A successful hop reports an outgoing `warm handoff staged` and `saved`, then an
incoming `candidate validated`, `accepted; cold_clear=skip`, `consumed`, and
`first_visible_latch warm=1`. The latch line reports both open-to-latch and
first-admission-to-latch microseconds. A rejection should name its reason and
report `cold_clear=start`. Do not use continued existence of
`/run/pluto/glass.handoff` as a success test: first content admission is
required to remove it durably.

The final path was deployed to a Paper Pro Move as embedder SHA-256
`32078a56fbe04e4a65f773a47f1ea462a83e641fdb78a3d9c76b0453df051b52`.
A clean launcher → Counter → switcher → Counter → Home → Codex → Home run
retained the same launcher, Counter and Codex PIDs (`587699`, `588725`, and
`589487`), produced six `hibernated`/`resumed` pairs, accepted handoff chains
0 through 5, and logged no cold clear during the sequence. All six first
visible latches reported `warm=1`; open-to-latch ranged from 0.646 to 1.273 s
with a 0.824 s median. The same binary's fresh cold boot measured 4.779 s, a
3.955 s (82.75%, 5.80×) median reduction. First-admission-to-latch had a 0.076 s
median. Native regressions separately pin the eight-admission chain limit and
the mandatory conservative clear after it.

The synchronized camera capture, contact sheet, and process logs are under
`analysis/warm-color-handoff/final-32078a56/`. At 10 fps, the older cold-switch
baseline had 12 frames with mean-luma difference above 20 and seven above 30;
the final accepted sequence had two above 20 and two above 30. Both are the
single expected dark Codex → light Home content transition (maximum 42.049),
not a repeated black/white rail cycle. Low camera quality makes the bound logs
and scan-latch evidence essential, but the video confirms that the repeated
cold-clear phases are absent while intended color waveform phases and
dark-surface changes remain.

Trigger and time the production pixel-reset path without relying on physical
gesture recognition:

```sh
kill -HUP "$(cat /run/pluto/embedder.pid)"
grep -E 'ghost-control:|pixel-reset:' /home/root/pluto/logs/current.log \
  | tail -n 8
```

The signal must report `BlinkNow accepted`, followed by the blink completion,
bleach follow-up cycles, and content completion. On the deployed exact-color
binary the production sequence completed in 8.882 s, restored the launcher,
and kept PID `587699` alive. Its separate synchronized capture and contact
sheet are `post-deploy-ghost-control.mp4` and
`post-deploy-ghost-control-contact-sheet.jpg` in the acceptance directory
above. The intentional maintenance rails remain uniform; they are not
app-switch cold clears.

The initial one-cycle BlinkNow baseline measured 829 ms on the Move but left
visible yellowing, which is why it is no longer the production policy. That run
did prove the fast full-field mechanism: the presenter reported
`active_px_peak=1617984`, exactly `954 * 1696`, with zero parked, dropped,
clipped, or superseded admissions. The composed blink-plus-bleach timing must
be assessed as a separate maintenance operation from app-switch latency. Human
observation remains the authority for yellowing and physical-glass uniformity.

The earlier all-Fast-restore composition was deployed and exercised on
2026-07-11. A deterministic SIGHUP run completed in 2,130 ms; two subsequent
physical bezel double-taps completed in 2,131 ms and 2,120 ms. Each log showed
the blink-to-bleach transition, both bleach cycles, and retained-content
completion. Presenter statistics reached all 1,617,984 logical pixels
concurrently with zero parked, dropped, clipped, or superseded admissions.
Those timings do not characterize the current balanced Full restore; its
8.882 s deployed measurement is recorded above. Yellow-cast acceptance is
still determined by observing the physical panel.

A background warm process should have a hibernated marker and process state
`T` (stopped). The foreground PID should have no hibernated marker. Only the
foreground process should hold the input and DRM devices.

On the final acceptance run, stopped Codex and Counter processes consumed zero
CPU jiffies over five seconds and held 120,772 KiB and 114,256 KiB RSS. The
active launcher held 254,868–254,912 KiB and advanced 12 CPU jiffies during the
sample; the complete pool held 489,896–489,940 KiB (about 478.5 MiB). The
device still had 1,403,700 KiB available of 2,008,664 KiB. This is the
performance/RAM trade-off behind Move's generated total-resident limit of four.
The same lifecycle uses a profile-owned limit of two on RM1 and four on RM2;
production has no environment override. The smaller RM1 pool preserves one
foreground and one warm process while bounding the tablet's substantially
tighter memory envelope. Tests alone may exercise other limits through a
guarded seam without changing production profile data or handoff correctness.

The deterministic host regression is:

```sh
sh tools/device/test/pluto-session-warm-resume_test.sh
sh tools/device/test/pluto-session-switcher_test.sh
```

They prove same-PID launcher resume, one process start per app, resident
background retention, recency order, preview publication, release
`--hibernate` wiring, switcher selection, and pool cleanup on stock exit. Native
unit tests separately cover portrait/landscape gesture geometry and BMP
encoding. The existing standby and debug-authorization tests cover their
special paths.

For a manual device acceptance test, open Paper Codex, enter text without
sending it, open another app, then use the two-finger bottom-edge gesture. Paper
Codex should be the first preview. Tap it and confirm that the draft,
scroll/navigation state, and PID are unchanged. Repeat once in landscape with a
rotation-capable app to confirm the rotated physical bottom edge. Reboot and
repeat: the PID and non-durable draft may be new, as intended.
