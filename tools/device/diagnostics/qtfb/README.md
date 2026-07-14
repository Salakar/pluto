# Archived QTFB display diagnostic (reMarkable Paper Pro Move)

> **Historical maintainer artifact.** This procedure predates Pluto's unified,
> device-aware provisioning flow. Do not use it to install XOVI/AppLoad, select
> a backend, or establish current compatibility on a supported tablet. Use
> `pluto devices --probe`, `pluto provision`, `pluto run`, and
> `pluto screenshot` for current work.

This isolated diagnostic is not part of the release AOT build, package, or
provisioning path. It preserves the original Stage-0 check that asked whether
pixels could reach the e-ink glass through the qtfb-cooperative path on one
Paper Pro Move firmware. It used no Flutter engine and displayed a moving square
only to isolate that historical display path. Its result is provenance, not a
current product workflow or a compatibility claim for another device.

## What it does
A small C program (`src/qtfb-probe.c`) that, once launched by AppLoad:
1. reads `QTFB_KEY` from the environment (AppLoad sets it because the manifest
   has `"qtfb": true`);
2. connects to the qtfb server at `/tmp/qtfb.sock` (`SOCK_SEQPACKET`), sends
   `MESSAGE_CUSTOM_INITIALIZE {key, FBFMT_RMPP_RGB565, 954, 1696}`, and `mmap`s
   the returned shared framebuffer `/qtfb_<key>`;
3. paints an 8×8 RGB565 checkerboard + one `UPDATE_ALL`;
4. animates a 128×128 black square, sending a `UPDATE_PARTIAL` for the changed
   bounding box each ~300 ms, logging `CLOCK_MONOTONIC` timestamps to stderr
   (for camera latency correlation).

Protocol vendored in `src/qtfb_proto.h` from `asivery/qtfb` `common.h`.
Default struct packing is mandatory — it must match the qtfb server's layout.

## Build (aarch64, glibc ≤ 2.39)
```
./build.sh
```
Compiles **natively inside the `ubuntu:24.04` linux/arm64 image** (glibc 2.39 =
device), producing `build/aarch64/qtfb-probe`, and asserts the binary's max
required GLIBC symbol version is ≤ 2.39.

## Archived maintainer deploy recipe (do not use for provisioning)

The original disposable lab procedure required XOVI and AppLoad from
`tools/device/provision-xovi.sh`. It bypasses the current CLI's hardware,
firmware, target, transaction, and rollback gates. Retain these commands only to
explain how the recorded Stage-0 result was produced; do not run them on a
current acceptance or user device.

```
DIR=/home/root/xovi/exthome/appload/pluto-qtfbprobe
ssh root@10.11.99.1 "mkdir -p $DIR"
scp app/external.manifest.json app/icon.png root@10.11.99.1:$DIR/
scp build/aarch64/qtfb-probe root@10.11.99.1:$DIR/
ssh root@10.11.99.1 "chmod +x $DIR/qtfb-probe"
```
The historical procedure then opened the AppLoad menu and launched
"Pluto qtfb Diagnostic".
`external.manifest.json` uses `"qtfb": true` (AppLoad allocates the framebuffer
and passes `QTFB_KEY`) and `"aspectRatio": "move"` (rMPPM screen).

## Historical Stage-0 checklist
- **`QTFB_KEY` delivery:** confirmed by design (`qtfb:true` external app) but
  unverified on this firmware.
- **`CUSTOM_INITIALIZE` at 954×1696 RGB565** is honored (vs a fixed/scaled
  surface). Log line `server shmKey=… shmSize=…` reports the truth; if
  `shmSize != 954*1696*2` the row stride differs and `stride_px` must be
  recomputed.
- **Damage semantics:** whether `UPDATE_PARTIAL` produces a *regional* panel
  update (no full flash) — the core H4 hypothesis. Verify on camera.
- **blit→glass latency** per the stderr timestamps vs camera video (H5).
- **AppLoad displays the framebuffer** in its own window for external qtfb apps
  (per `resources/qml/window.qml`: `FBController{ framebufferID: qtfbKey }`); no
  custom QML frontend needed.
