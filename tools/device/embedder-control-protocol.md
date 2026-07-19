# Pluto native embedder-control protocol

Each foreground native Pluto embedder publishes a private, root-local control
endpoint. The CLI uses it for screenshots, and the real-device acceptance
harness uses Ink's exact semantic controls to prove a real canvas is mounted
before sending one deterministic stylus stroke through Ink's ordinary Flutter
input and rendering path. It is an implementation detail behind the single
Pluto device workflow, not an app-facing API or a second lifecycle backend.

## Transport and trust boundary

- Socket: `/run/pluto/embedder-control.sock`.
- Transport: Unix `SOCK_SEQPACKET`; one UTF-8 JSON object per packet.
- Maximum request or response packet: 32,768 bytes.
- `/run/pluto` and `/run/pluto/screenshots`: owned by the embedder uid
  (`root` in the device runtime), mode `0700`.
- Socket: owned by the embedder uid, mode `0600`.
- The server rejects a peer unless Linux `SO_PEERCRED` reports the same uid as
  the embedder. Pluto runs the embedder and its device tooling as root, so
  ordinary apps cannot use this endpoint.
- A request receives exactly one response with the same `requestId`.
- Startup only removes an inactive socket with the expected owner and mode;
  shutdown only unlinks the exact socket inode created by that server.

The target-native `/home/root/pluto/bin/pluto-controlctl` client requires both
an explicit `--socket PATH` and `--request JSON`. It has no implicit socket or
device-specific action set.

## Exact envelope

Requests contain only a caller-generated `requestId`, an action, and that
action's exact fields:

```json
{"requestId":"host-nonce","action":"screenshot","appId":null,"surface":"logical"}
```

Success preserves the request id:

```json
{"requestId":"host-nonce","ok":true,"result":{}}
```

Failure has a stable code and safe diagnostic:

```json
{"requestId":"host-nonce","ok":false,"error":{"code":"bad-args","message":"control action requires appId"}}
```

The parser rejects unknown fields or actions, duplicate JSON keys,
embedded NULs, malformed or oversized packets, trailing data, and missing or
ill-typed required fields. `requestId` and non-null `appId` values are limited
to 128 printable ASCII bytes. There is no version negotiation, alternate
envelope, or extensibility reader.

## Actions

### `screenshot`

Required fields:

- `appId`: the exact foreground app id, or `null` to select the foreground
  embedder without naming it;
- `surface`: `logical` or `post-dither`.

Example:

```json
{"requestId":"shot-1","action":"screenshot","appId":"dev.pluto.ink","surface":"logical"}
```

The result contains `path`, `bytes`, lowercase `sha256`, `appId`, `pid`,
`surface`, `width`, `height`, `stride`, and `format`. The PNG is a root-owned,
mode-`0600`, non-symlink regular file directly under
`/run/pluto/screenshots/`; image bytes are not placed in the socket packet.
The CLI correlates the request, rechecks the foreground pid, validates the
artifact path and metadata, downloads and hashes the file, validates PNG
dimensions, then removes the temporary artifact.

### `draw-stroke`

This action exists only for real-device acceptance and follows a successful
`prepare-ink-canvas` request for the same foreground PID. It accepts exactly the
Ink application identity and no caller-supplied geometry:

```json
{"requestId":"stroke-1","action":"draw-stroke","appId":"dev.pluto.ink","expectedPid":4242}
```

`appId` must be the concrete string `dev.pluto.ink`; `null`, another app id,
and the screenshot-only `surface` field are rejected. `expectedPid` is
required, must be a positive integer, and must equal the receiving process and
the result PID. The request must reach the foreground embedder for that exact
app and PID. The embedder then sends a
deterministic, panel-relative 24-event stylus sequence through Flutter's
`SendPointerEvent` API: add, down, 20 moves forming a shallow central S-curve,
up, and remove. Ink therefore handles the same pointer, stroke pipeline,
rendering, and presentation path used by a physical pen. The action does not
write pixels behind Ink or provide a general remote drawing interface.

A successful response identifies the process and injected event count:

```json
{"requestId":"stroke-1","ok":true,"result":{"appId":"dev.pluto.ink","pid":4242,"eventCount":24}}
```

The server rejects results whose app identity does not match the request,
whose pid is invalid, or whose event count is outside the protocol's bounded
range. Typical action failures include `wrong-app`, `unsupported-app`,
`unavailable`, `invalid-geometry`, and `pointer-send-failed`.

For an acceptance run, invoke the installed target-native client as root:

```sh
/home/root/pluto/bin/pluto-controlctl \
  --socket /run/pluto/embedder-control.sock \
  --request '{"requestId":"stroke-1","action":"draw-stroke","appId":"dev.pluto.ink","expectedPid":4242}'
```

Success confirms dispatch, not visible correctness. Acceptance still requires
a changed post-dither screenshot relative to the prepared empty canvas and a
fresh camera frame showing that the stroke reached Ink and rendered on the
panel. The response PID must equal the foreground PID captured before both
actions.

### `prepare-ink-canvas`

This bounded acceptance action makes the real Ink canvas a precondition for a
stroke. It is not a coordinate injector and has no caller-selected UI target:

```json
{"requestId":"prepare-1","action":"prepare-ink-canvas","appId":"dev.pluto.ink","expectedPid":4242}
```

`expectedPid` is required, must be a positive integer, and must equal both the
foreground embedder PID and the receiving process's own PID. The receiving
embedder must also be configured for exactly `dev.pluto.ink`. For this bounded
operation it enables Flutter semantics and follows only exact, tappable
app-owned labels:

- an existing `Back to gallery` action proves the editor is already mounted;
- otherwise exact `new artwork`, followed by exact `create`, opens a new
  canvas; or
- an already-open create chooser requires only the exact `create` action.

Each transition must publish a fresh semantics generation. Missing, stale,
duplicate, near-match, or non-tappable labels fail closed, as does any timeout
or foreground/PID change. Success is returned only after a fresh semantic tree
exposes the editor's exact tappable `Back to gallery` action:

```json
{"requestId":"prepare-1","ok":true,"result":{"appId":"dev.pluto.ink","pid":4242,"processStartTicks":91827,"canvasReady":true,"actionCount":2,"surfaceGeneration":381,"proofFrameId":947}}
```

`actionCount` is exactly 0, 1, or 2. Before invoking either semantic action, the
embedder opens an optical transaction. Flutter continues to build and raster
the gallery, chooser, and editor routes into the retained surface, but
never-dispatched intermediate requests cannot cross into the presenter while
that transaction is active. After the final canvas-ready semantics generation,
the embedder schedules and observes two sequential Flutter frames on the
platform thread; the first may close a frame that was already in flight, while
the second is therefore a fresh post-semantics raster fence. It then waits for
any update that had already crossed the irreversible presenter boundary,
discards every superseded request still queued in the scheduler, and dispatches
one dedicated full-screen `Full` refresh from the newest retained surface. The
discarded requests cannot lose pixels because the dedicated refresh reads the
current retained surface and covers the whole panel. If the semantic
transaction fails before proof dispatch, cancellation releases queued work to
the ordinary scheduler.

`surfaceGeneration` identifies the final retained Flutter surface and
`proofFrameId` is captured before the presenter call; success requires the real
completion callback for that exact frame ID. Stale, future, unrelated,
out-of-order, and late pre-action completions cannot satisfy the proof, while a
synchronous exact completion is safe. The same nonzero proof is mandatory when
the editor was already mounted (`actionCount: 0`). `processStartTicks` binds it
to the same Linux process lifetime as `pid`. Any bounded fence, quiescence, or
exact-completion failure returns `presentation-timeout` instead of stale
evidence.

The acceptance harness rechecks the same foreground PID, captures the empty
canvas's post-dither framebuffer, injects the stroke, checks the response PID
again, and requires a material decoded-pixel change inside the deterministic
stroke corridor before optical review.

### `tap-switcher-preview`

This acceptance-only action selects the currently centered running-app card
through the real Flutter switcher UI:

```json
{"requestId":"switch-1","action":"tap-switcher-preview","appId":"dev.pluto.launcher"}
```

The foreground process must be Pluto Home and the supervisor-owned
`switcher-active` record must contain both an origin and at least one distinct
selectable app. The embedder sends the normal four-event touch sequence at the
center of the live logical viewport. The switcher card's `GestureDetector`,
method channel, and supervisor launch request therefore perform the selection;
the control does not write the launch marker itself. The response reports the
launcher process identity and `eventCount: 4`.

The action is intentionally not a generic coordinate injector. It refuses a
Home screen, an empty switcher, a non-launcher foreground process, screenshot
fields, or a null app id. As with the Ink action, final acceptance requires a
fresh camera frame of the selected app rather than treating dispatch as visual
proof.
