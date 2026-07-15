# Pluto native embedder-control protocol

Each foreground native Pluto embedder publishes a private, root-local control
endpoint. The CLI uses it for screenshots, and the real-device acceptance
harness uses it to send one deterministic stylus stroke through Ink's ordinary
Flutter input and rendering path. It is an implementation detail behind the
single Pluto device workflow, not an app-facing API or a second lifecycle
backend.

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

## Schema 1 envelope

Requests contain `schema`, a caller-generated `requestId`, an action, and that
action's fields:

```json
{"schema":1,"requestId":"host-nonce","action":"screenshot","appId":null,"surface":"logical"}
```

Success preserves the request id:

```json
{"schema":1,"requestId":"host-nonce","ok":true,"result":{}}
```

Failure has a stable code and safe diagnostic:

```json
{"schema":1,"requestId":"host-nonce","ok":false,"error":{"code":"bad-args","message":"control action requires appId"}}
```

The parser rejects unsupported schemas or actions, duplicate JSON keys,
embedded NULs, malformed or oversized packets, trailing data, and missing or
ill-typed required fields. `requestId` and non-null `appId` values are limited
to 128 printable ASCII bytes. Unknown fields are ignored for schema-1
extensibility.

## Actions

### `screenshot`

Required fields:

- `appId`: the exact foreground app id, or `null` to select the foreground
  embedder without naming it;
- `surface`: `logical` or `post-dither`.

Example:

```json
{"schema":1,"requestId":"shot-1","action":"screenshot","appId":"dev.pluto.ink","surface":"logical"}
```

The result contains `path`, `bytes`, lowercase `sha256`, `appId`, `pid`,
`surface`, `width`, `height`, `stride`, and `format`. The PNG is a root-owned,
mode-`0600`, non-symlink regular file directly under
`/run/pluto/screenshots/`; image bytes are not placed in the socket packet.
The CLI correlates the request, rechecks the foreground pid, validates the
artifact path and metadata, downloads and hashes the file, validates PNG
dimensions, then removes the temporary artifact.

### `draw-stroke`

This action exists only for real-device acceptance. It accepts exactly the Ink
application identity and no caller-supplied geometry:

```json
{"schema":1,"requestId":"stroke-1","action":"draw-stroke","appId":"dev.pluto.ink"}
```

`appId` must be the concrete string `dev.pluto.ink`; `null`, another app id,
and the screenshot-only `surface` field are rejected. The request must reach
the foreground embedder for that exact app. The embedder then sends a
deterministic, panel-relative 24-event stylus sequence through Flutter's
`SendPointerEvent` API: add, down, 20 moves forming a shallow central S-curve,
up, and remove. Ink therefore handles the same pointer, stroke pipeline,
rendering, and presentation path used by a physical pen. The action does not
write pixels behind Ink or provide a general remote drawing interface.

A successful response identifies the process and injected event count:

```json
{"schema":1,"requestId":"stroke-1","ok":true,"result":{"appId":"dev.pluto.ink","pid":4242,"eventCount":24}}
```

The server rejects results whose app identity does not match the request,
whose pid is invalid, or whose event count is outside the protocol's bounded
range. Typical action failures include `wrong-app`, `unsupported-app`,
`unavailable`, `invalid-geometry`, and `pointer-send-failed`.

For an acceptance run, invoke the installed target-native client as root:

```sh
/home/root/pluto/bin/pluto-controlctl \
  --socket /run/pluto/embedder-control.sock \
  --request '{"schema":1,"requestId":"stroke-1","action":"draw-stroke","appId":"dev.pluto.ink"}'
```

Success confirms dispatch, not visible correctness. Acceptance still requires
a fresh camera frame showing that the stroke reached Ink and rendered on the
panel.
