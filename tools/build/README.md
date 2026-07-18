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

Both native outputs come from the same source and carry the same supervisor,
installer, control client, and device-profile table. Target selection changes
only the compiler/ABI, committed Flutter engine slice, and profile-selected
panel implementation.

## Universal device release

Release maintainers use one public command. It builds both native embedders and
the standard release-AOT application set supported by each target:

```sh
bash tools/build/assemble-device-release.sh
```

The result is one ignored release set:

```text
build/pluto-release/
  release-manifest.json
  targets/linux-arm/
  targets/linux-arm64/
```

The architecture-specific compiler and slice assemblers are private workers.
The manifest freezes one clean Git revision, the Flutter/engine/toolchain pins,
and the deterministic SHA-256 file set for each slice. Each slice is self-contained
for deployable payload files; checkout pins and committed engine checksum
metadata remain the local trust anchors. Provisioning never fills a missing
payload from checkout source, a committed engine directory, or an embedder
build tree. The frozen source revision is also installed as
`/home/root/pluto/share/release-revision` for exact-device acceptance.
The unpublished release manifest and each app's `build-metadata.json` have one
exact current shape with no schema/format discriminator or compatibility path;
all object fields and nested records are validated exactly.

The same command provisions any tested device:

```sh
pluto provision --device "$DEVICE"
pluto provision --device "$DEVICE" --status
```

The selected profile's recovery policy is internal. If persistent boot default
is not yet enabled, normal provisioning starts the same Pluto supervisor in a
runtime-only systemd unit for the current boot and restores stock on stop,
failure, or reboot. There is no separate install or app flow.

The release assembler verifies the pinned SDK and engine checksums, exact
native ABI, release metadata, application manifests, declared app targets, and
product `app.so`. A `kernel_blob.bin`, debug engine, mixed target, or app slice
outside its declared targets fails assembly. The shared standard set is Home,
Counter, Motion Lab, Ink Lab, Validation Lab, and Ink. Paper Codex declares
`linux-arm64` only because upstream Codex has no native ARMv7 release; the
`linux-arm` slice omits it and rejects explicit selection. Pluto does not build,
patch, pin, package, or provision a custom ARMv7 Codex CLI.

Published app packages use the same model: one manifest and every
app-declared exact target slice in one `.plap`:

```sh
pluto build package --published --release
```

Device-aware development builds remain single-slice. Install probes the tablet
and selects its slice; a missing or contradictory slice fails before writes.

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
bash tools/build/test/native-cutover-residue-test.sh
```

Run the native CTest suite through `melos run build:embedder:host`, then run
`./ci/check.sh` before handing off a release. Real compatibility additionally
requires the normal CLI commands, logs, screenshots, measured responsiveness,
and camera-visible Home, switching, the supported app set, and deterministic
Ink behavior on each device and firmware listed in
[`docs/device-compatibility.md`](../../docs/device-compatibility.md).
