# Pluto AppLoad control protocol

The cooperative Pluto runtime uses a private local control channel inside the
stock display process. This is an implementation detail behind the ordinary
`pluto provision`, `install`, `run`, `logs`, `screenshot`, and `uninstall`
commands. It is not a second user workflow.

## Transport and trust boundary

- Server socket: `/run/pluto/appload-control.sock`.
- Transport: Unix `SOCK_SEQPACKET`; one UTF-8 JSON object per packet.
- Maximum request or response packet: 32,768 bytes.
- Runtime directory: owner `root:root`, mode `0700`.
- Socket: owner `root:root`, mode `0600`.
- The server must reject a peer unless Linux `SO_PEERCRED` reports uid `0`.
- The server unlinks a stale socket before bind and unlinks its own socket on
  orderly shutdown.
- A request receives exactly one response with the same `requestId`; the
  server then closes that client connection.

The mode and peer-credential checks are both required. They ensure an app
running through AppLoad cannot launch or replace another app merely because it
can guess the socket path.

`/home/root/xovi/bin/pluto-apploadctl` is the matching small client. It accepts
`--socket PATH --request JSON`, sends one packet, prints the response object,
and exits nonzero on transport/protocol failure. The Pluto runtime may carry a
second identical copy at `/home/root/pluto/bin/pluto-apploadctl`.

## Envelope

Requests have this shape:

```json
{"schema":1,"requestId":"host-nonce","action":"ping"}
```

Successful responses have this shape:

```json
{"schema":1,"requestId":"host-nonce","ok":true,"result":{}}
```

Failures have a stable machine-readable code and a safe diagnostic:

```json
{"schema":1,"requestId":"host-nonce","ok":false,"error":{"code":"not-found","message":"application is not installed"}}
```

Unknown fields are ignored. Unknown schemas, actions, duplicate JSON keys,
embedded NULs, malformed UTF-8, oversized packets, and missing required fields
are rejected. `requestId` and app ids are limited to printable ASCII and 128
bytes. App ids use Pluto's reverse-DNS validation and never become paths until
matched against a parsed Pluto-managed manifest.

## Actions

The server implements these schema-1 actions:

| Action | Required request fields | Result fields / behavior |
| --- | --- | --- |
| `ping` | none | `protocol: 1`, `serverVersion`; no state change |
| `reload` | none | Atomically rebuild the AppLoad application list; `entryCount` |
| `launch` | `appId`, `entryId`, `replace` | Verify `entryId` is a Pluto-managed manifest for exactly `appId`, create and maximize its QTFB window, and return `pid` and `entryId`. With `replace: true`, close other Pluto windows only after the new process starts. |
| `stop` | `appId` | Terminate only the tracked process/window for that Pluto app; `stopped` is false when it was not running. |
| `stopAll` | `scope: "pluto"` | Stop only entries whose parsed manifest has `pluto.managed: true`; return `stopped`. |
| `setDefault` | `appId` (string or null) | Persist or clear the verified release app launched when the cooperative session becomes ready; return `defaultApp`. |
| `status` | none | Return `defaultApp` and tracked `apps` records (`appId`, `entryId`, `pid`, `running`, `visible`). |
| `screenshot` | `appId` (string or null), `surface` | Snapshot the selected/foreground Pluto QTFB image as PNG and return `path`, `bytes`, and lowercase `sha256`. |

AppLoad external manifests created by Pluto include:

```json
"pluto":{"schema":1,"managed":true,"appId":"dev.example.app"}
```

The server must use that parsed identity rather than trusting `entryId` text.
It tracks the `QProcess` and QTFB key per app so `stop`, `status`, and
`screenshot` never use broad `pkill` matching.

Screenshot files are created under `/run/pluto/screenshots/`, mode `0600`, and
owned by root. `path` must be a regular non-symlink file directly below that
directory. The CLI verifies the prefix, byte count, and SHA-256 before deleting
the temporary file. PNG bytes are not returned in the socket packet because a
full panel image can exceed the socket buffer.

## Launcher marker bridge

Pluto Home already publishes supervisor requests as atomic files. The
cooperative server consumes the same interface so Home behaves identically:

- `/run/pluto/launch`: one validated app id; equivalent to `launch` with
  `replace: true`.
- `/run/pluto/home`: empty marker; launch `dev.pluto.launcher` with
  `replace: true`.
- `/run/pluto/stock`: empty marker; equivalent to `stopAll`.

The server watches the directory (not an individual inode), opens markers with
`O_NOFOLLOW`, requires root ownership and no group/world write bits, consumes
them by atomic rename, and writes a correlated success/failure acknowledgement
under `/run/pluto/acks/`. A failed request must not close the currently visible
window. On startup it removes only stale Pluto marker/ack files, then applies a
verified default app if configured.

