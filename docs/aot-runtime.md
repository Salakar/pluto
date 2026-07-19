# ARM AOT runtime

Pluto uses ahead-of-time compiled Dart for normal device applications. Release
AOT is the portable production contract across supported hardware: no JIT
kernel, no VM service, and no development-only engine.

Hardware discovery chooses the device integration, while artifact metadata
keeps architecture and build mode explicit. These are complementary safety
boundaries: the user sees one device workflow, and the runtime still refuses a
mislabeled or incompatible binary.

## Pinned runtime

| Component | Pinned value |
| --- | --- |
| Flutter | 3.44.4 |
| Engine | `a10d8ac38de835021c8d2f920dbf50a920ccc030` |
| Dart | 3.12.2 |
| 64-bit ARM target | `linux-arm64` |
| 32-bit ARM target | `linux-arm` (ELF32 ARM EABI5 hard-float) |

The pin-keyed payload under `third_party/engine/<engine-hash>/` contains:

- source-built plain release/profile AArch64 embedder libraries;
- a source-built plain ARMv7 release embedder library;
- mode- and target-matched `gen_snapshot` tools;
- revision-matched ICU data and source-artifact licenses;
- authoritative metadata and SHA-256 manifests.

These artifacts are committed so a normal clone never compiles Flutter. Setup
verifies every payload, and the Pluto CLI repeats the pin, mode, target, and
checksum checks before building or installing AOT content.

## Release workflow

Every `.plap` contains one target. The normal build workflow probes the device
and selects that target:

```bash
pluto build package --device "$DEVICE" --release
```

Offline release automation can explicitly pass `--target-platform linux-arm64`
or `--target-platform linux-arm`. The option is an advanced override; when
combined with `--device`, a contradictory value is rejected.

`linux-arm` currently supports release only. `linux-arm64` also supports
profile AOT and explicit debug/JIT development:

```bash
pluto build package --device "$DEVICE" --profile
pluto build package --device "$DEVICE" --debug
```

After artifact production, the public device commands are identical. They
probe the device and dispatch through the selected backend:

```bash
pluto provision --device "$DEVICE"
pluto install --device "$DEVICE" --release --force build/pluto/app.plap
pluto run --device "$DEVICE" --release <app-id>
pluto logs --device "$DEVICE"
pluto screenshot --device "$DEVICE" -o shot.png
pluto uninstall --device "$DEVICE" <app-id>
```

An architecture or mode mismatch is rejected before device files change.
Installing a package never converts it, changes its metadata, or selects a
different integration manually.

On macOS and x64 Linux, AOT builds use Docker to execute the committed
Linux/AArch64-host snapshotter. A native AArch64 Linux host can execute it
directly. For `linux-arm`, the host tool emits an ARM product snapshot; the
result is still an ELF32 ARM hard-float image. This does not build Flutter or
download engine artifacts.

## Build-mode capability table

| Mode | Engine | Snapshot | `linux-arm64` | `linux-arm` | Boot/default eligible |
| --- | --- | --- | --- | --- | --- |
| release | product | product `app.so` | yes | yes | yes |
| profile | non-product | AOT `app.so` | yes | no | no |
| debug | JIT | `kernel_blob.bin` | yes, explicit only | no | no |

Release is the default for build, package, install, and run. `--profile` or
`--debug` must be explicit at every boundary. `pluto build bundle` additionally
requires `--debug` because it exists only for the hot-reload path.

Debug/JIT is a capability of one runtime target, not a different product
workflow. Unsupported devices reject it and continue to use the same release
provision/install/run commands.

## Layout and identity contract

Release and profile layouts contain `bundle/lib/app.so` and cannot contain
`kernel_blob.bin`. Each layout carries the sole current, unversioned
`build-metadata.json` object with exactly five fields:

- exact build mode and engine flavor;
- target (`linux-arm64` or `linux-arm`);
- Flutter version and engine pin.

The sibling canonical `manifest.json` carries application identity; validation
binds its engine requirement and runtime kind to those five metadata fields.

There is no schema or format discriminator and no compatibility parser. Missing,
extra, wrongly typed, or contradictory fields fail at the build, package, read,
and provision boundaries; Pluto never aliases or migrates an older shape.

Packages retain this object inside each target slice and bind its exact bytes in
`INTEGRITY.json`; installation preserves it beside the generated `install.json`
receipt. Packaging and provisioning validate all three layers and refuse mode
relabelling. A complete layout contains `build-metadata.json`, `manifest.json`,
and `bundle/`; a bare bundle is rejected because release and profile both use
the same `app.so` filename.

The default Home payload must always be release AOT. Debug engines and apps are
accepted only through explicit development flags, and a debug app can never be
the boot/default application.

## Snapshot modes

Release compilation uses `flutter_patched_sdk_product` and the product
snapshotter. Target feature markers include:

```text
product ... dedup_instructions ... arm64 linux
product ... dedup_instructions ... arm linux
```

Profile compilation uses the non-product `flutter_patched_sdk` with
`dart.vm.profile=true`:

```text
release ... no-dedup_instructions ... arm64 linux
```

Pairing an app with the wrong target or engine/tool mode is rejected. ARMv7 is
also checked for ELF32 `EM_ARM`, EABI5, hard-float flags, and the shared ABI
ceiling documented in [Device compatibility](device-compatibility.md).

## Historical device measurement

The following figures preserve the provenance of an earlier AArch64
release-vs-debug experiment. They were measured on the attached reMarkable
Paper Pro Move on 2026-07-09. The test ran the same counter bundle through the
same `pluto-embedder` and `host-headless` presenter, with the display session left
untouched. All test files lived under `/tmp`; no service, boot setting, or
installed engine changed.

| Measurement | Release AOT | Debug JIT |
| --- | ---: | ---: |
| First rendered frame | 380 ms | 4,050 ms |
| User CPU in equal 10 s run | 0.48 s | 4.83 s |
| System CPU in equal 10 s run | 0.20 s | 0.49 s |
| Reported CPU share | 6% | 52% |
| Peak RSS | 290,208 KiB | 646,336 KiB |

Release AOT reached first frame about 10.7 times sooner, used about one tenth
of the user CPU, and reduced peak RSS by about 55%. Both modes produced the
same first-frame SHA-256
`595ec2c5001d42878e98ce015fe43d28651961c71ab73bf94f12743e23d0b9d6`;
their post-tap frames also matched and differed from the first frame. Profile
AOT independently passed `aot=true`, rendered two distinct frames, processed
the same synthetic tap, and exposed its profiling VM service.

These numbers are measurement provenance for that unit, not a performance
claim for every supported tablet. Each new device acceptance run needs its own
real-hardware timings and camera evidence.

## Engine maintenance

Normal contributors should not rebuild Flutter. For an AArch64 pin change or
artifact recovery, use the checksum-gated pipeline in
`tools/engine/README.md`:

```bash
tools/engine/build-aarch64-aot.sh
tools/engine/promote-aarch64-aot.sh
```

The committed `linux-arm-release` directory follows the same pin, metadata,
checksum, and license contract. There is no arbitrary engine fallback: restore
or reproducibly rebuild the exact target artifact.

The optional AArch64 integration smoke rebuilds the counter in release and
profile modes and validates ELF features, bundle layout, and package metadata:

```bash
ci/aot-smoke.sh
```
