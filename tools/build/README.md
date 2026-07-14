# Pluto builds

App authors use one build command on every supported tablet:

```sh
DEVICE=root@10.11.99.1  # or the tablet's USB/Wi-Fi SSH endpoint
pluto build package --device "$DEVICE" --release
```

The probe behind `--device` selects the native target. The resulting `.plap`
records that target, and install refuses to relabel or run it on incompatible
hardware. Release automation may pass `--target-platform linux-arm64` or
`--target-platform linux-arm` as an explicit offline override; ordinary users
do not choose a display or lifecycle backend.

This directory contains the lower-level maintainer builds that prepare those
target artifacts. Their differences stay below the public CLI boundary.

## Host embedder

```sh
melos run build:embedder:host
bash tools/build/embedder-host.sh --preset host-release
```

The default command configures `host-debug`, builds it, and runs CTest. It
requires CMake 3.27 or newer, Ninja, and a C/C++ compiler. The wrapper also
accepts `--no-tests`, `--clean-first`, and `--dry-run`.

## Device embedders

Pluto currently emits two native targets from the same embedder source:

| Target | Build command | Output | Release ABI gate |
| --- | --- | --- | --- |
| `linux-arm64` | `melos run build:embedder:device` | `embedder/build/device-arm64/pluto-embedder` | ELF64 AArch64; GLIBC ≤ 2.39 |
| `linux-arm` | `bash tools/build/embedder-device-arm.sh` | `embedder/build/device-arm/pluto-embedder` | ELF32 ARM EABI5 hard-float; GLIBC ≤ 2.35, GLIBCXX ≤ 3.4.29, CXXABI ≤ 1.3.13 |

Both device builds also emit the backend-neutral `pluto-controlctl` beside the
embedder. The ARMv7 build uses the official reMarkable SDK selected by
`PLUTO_RM_SDK_VOLUME` or `PLUTO_RM_SDK_DIR`. Both builds run in pinned local
containers on non-native hosts. `PLUTO_BUILD_JOBS` controls build parallelism.

Mutable binaries remain in the ignored CMake build tree. The committed Flutter
engine payloads under `third_party/engine/<engine-hash>/` are separate and do
not need rebuilding for ordinary embedder or app work.

The cooperative integration is independently source-reproducible. Its exact
XOVI, QRR, qmldiff, and AppLoad commits; reviewed patches; GPL license; immutable
toolchain-image digests; and accepted output hashes live under
[`tools/integration/`](../integration/README.md). Verify that supply chain
without network access before assembling a release:

```sh
bash tools/integration/build-armv7-integration.sh --verify-inputs
bash tools/integration/build-armv7-integration.sh --verify-reference
```

A maintainer clean rebuild uses the same recipe without a mode flag. Rebuilt
files stay isolated until `--promote` passes the device-accepted SHA-256 gate.

## Release payloads

Release maintainers prepare both target payloads; `pluto provision` probes the
tablet and selects the matching one automatically.

```sh
# linux-arm64 release runtime and selected applications
melos run build:device-payload -- --standard

# linux-arm release runtime, Home, Ink, and real Paper Codex
bash tools/build/assemble-appload-arm-payload.sh
```

The target staging roots are:

```text
build/pluto-payload/
build/pluto-appload-arm/home/root/pluto-arm/
```

They are implementation artifacts, not two installation workflows. With both
present, the same command provisions any tested device:

```sh
pluto provision --device "$DEVICE"
pluto provision --device "$DEVICE" --status
```

Each assembler verifies the pinned SDK and engine checksums, exact native ABI,
release metadata, application manifests, and product `app.so`. A
`kernel_blob.bin`, debug engine, mixed target, unpinned integration binary, or
fake Codex payload fails assembly. The ARMv7 payload carries the pinned real
Codex CLI and firmware-profiled integration inputs; authentication remains
user-owned and is never built into the artifact.

Every final app layout contains at least:

```text
build-metadata.json
manifest.json
bundle/lib/app.so
bundle/icudtl.dat
bundle/flutter_assets/
```

## Verification

The side-effect-free build contracts are:

```sh
bash tools/build/test/embedder-build-workflow-test.sh
bash tools/build/test/assemble-appload-arm-payload-test.sh
bash tools/integration/test/build-armv7-integration-test.sh
```

Run the native CTest suite through `melos run build:embedder:host`, then run
`./ci/check.sh` before handing off a release. Real compatibility additionally
requires the normal CLI commands, logs, screenshots, measured responsiveness,
and camera-visible Home, Ink, and authenticated Codex behavior on each device
and firmware listed in
[`docs/device-compatibility.md`](../../docs/device-compatibility.md).
