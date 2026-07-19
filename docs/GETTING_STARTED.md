# Getting started with Pluto

This walkthrough takes you from a clean clone to Pluto applications running on
a supported reMarkable tablet. The short version lives in the
[README](../README.md); this guide fills in setup, the release workflow,
inspection, and recovery.

The device workflow is model-neutral. Pluto identifies the connected hardware
and selects its display, lifecycle, and release target internally. You do not
choose or install a device backend by hand.

## What you need

- **Host:** macOS or Linux. Docker must be installed and running on macOS and
  x64 Linux for device cross-builds and AOT snapshot generation.
- **Device:** a [tested reMarkable tablet](device-compatibility.md) with SSH
  enabled, connected over USB or reachable over Wi-Fi. Install your SSH key so
  Pluto can connect non-interactively.
- **Disk:** about 2 GB for the pinned Flutter SDK under `~/.pluto/sdk/`.

The Flutter engine artifacts are committed under `third_party/engine/` with
checksums. Normal setup does not compile or download a Flutter engine.

## 1. Bootstrap the host

```bash
./tools/setup/setup.sh
```

Setup validates the committed runtimes, installs the pinned Flutter SDK
(currently 3.44.4), bootstraps the workspace, and compiles
`~/.pluto/bin/pluto`. Run the `export PATH=...` line it prints and add it to
your shell profile:

```bash
export PATH="${PLUTO_BIN_DIR:-$HOME/.pluto/bin}:${PUB_CACHE:-$HOME/.pub-cache}/bin:${PLUTO_SDK:-$HOME/.pluto/sdk/3.44.4}/bin:$PATH"
```

Verify the host installation at any time without changing it:

```bash
./tools/setup/setup.sh --verify
pluto doctor
```

## 2. Discover the tablet

Set the SSH endpoint once. `root@10.11.99.1` is the usual endpoint when one
tablet is attached; use the device-specific endpoint when several are
connected.

```bash
DEVICE=root@10.11.99.1
pluto devices --device "$DEVICE" --probe
```

Discovery reads immutable hardware identity and reports the model, firmware,
native target, build modes, common capabilities, and provisioning state.
Unsupported hardware fails closed before a write. Do not infer support from
SSH connectivity alone.

## 3. Provision Pluto

With the repository's universal release prepared, the normal command is the
same for every supported tablet:

```bash
pluto provision --device "$DEVICE"
pluto provision --device "$DEVICE" --status
```

`pluto provision` probes first, integrity-checks
`build/pluto-release/release-manifest.json`, selects its matching slice, and
verifies every deployable file plus engine and application metadata before the
transaction. Checkout pins and committed engine checksum metadata remain the
local trust anchors; the slice cannot borrow missing deployable files from the
checkout. An explicit `--payload-dir` names another complete release-set root
and cannot override hardware identity.
The matched profile's boot-default recovery gate is applied automatically. If
the gate is closed, provision activates Pluto through the common supervisor for
the current boot only, so `pluto run` works immediately while stock remains the
next-boot default.

If you are building Pluto itself from source, run
`melos run build:device-release` first. It prepares both supported slices from
one clean revision. Internal target compilers remain release-maintainer
mechanics, not a second device workflow.

Useful variants are also model-neutral:

```bash
pluto provision --device "$DEVICE" --no-boot-default
pluto provision --device "$DEVICE" --restore-remarkable
pluto provision --device "$DEVICE" --uninstall
```

`--no-boot-default` installs Pluto without making Home the preferred entry
point. `--restore-remarkable` returns to the stock experience while retaining
the Pluto runtime. `--uninstall` removes Pluto and restores stock behavior.
The command chooses the safe implementation for the connected hardware.

## 4. Install and run a release app

Every Pluto app is a normal Flutter app plus a `pluto.yaml` manifest containing
its id, name, version, icon, and display preferences. Start from
`apps/examples/counter` when creating one.

Keep `display.scale: auto` (also the default when the field is absent). Pluto
then supplies Flutter with the presenter's native surface dimensions and device
pixel ratio on each supported tablet. Numeric scale values are rejected.

Use the same device endpoint for the whole workflow. The build command probes
immutable hardware identity and selects the matching native target:

```bash
cd apps/examples/counter
pluto build package --device "$DEVICE" --release
pluto install --device "$DEVICE" --release --force build/pluto/app.plap
pluto run --device "$DEVICE" --release dev.pluto.examples.counter
```

Release AOT is the default, so `--release` may be omitted. `--launch` starts an
AOT app immediately after installation; `--set-default` makes it the preferred
Pluto app for that device's lifecycle integration.

Each `.plap` records one target. `--device` makes build choose it automatically;
the low-level `--target-platform` option remains an advanced CI/release
override and is rejected if it contradicts the connected device. Install never
converts or relabels an artifact and refuses a mismatch before writing files.

## 5. Inspect the result

The same commands inspect every supported runtime:

```bash
pluto logs --device "$DEVICE"
pluto logs --device "$DEVICE" --app dev.pluto.examples.counter --since 10m
pluto screenshot --device "$DEVICE" -o shot.png
pluto provision --device "$DEVICE" --status
```

Log snapshots support app, time-window, system, and JSON filters. Live
`--follow` is not available through the current SSH transport and fails
explicitly instead of silently returning a snapshot.

`pluto screenshot` captures the foreground renderer's live dimensions and
pixel format; `--surface post-dither` selects its settled grayscale ledger.
Neither mode assumes a device resolution. For refresh behavior, ghosting, pen
latency, and physical legibility, also verify the panel through a camera; a
successful process launch or software-pixel capture is not sufficient
real-glass evidence. See [Real-device camera verification](real-device-camera.md).

## 6. Remove an app or Pluto

```bash
pluto uninstall --device "$DEVICE" dev.pluto.examples.counter
pluto uninstall --device "$DEVICE" --system
```

Use `--purge-data` when removing an app to delete its data, or
`--keep-app-data` with `--system` to preserve application data. System removal
stops Pluto applications, removes the managed runtime and integration, and
returns the tablet to stock behavior through the hardware-appropriate recovery
path.

## Debug and hot reload

Debug/JIT is an explicit development capability and can never be a release or
boot default. It is currently available only for the `linux-arm64` runtime
target; `linux-arm` is release AOT only. This is a target capability, not a
different install/run/logs workflow.

Where the connected target supports it:

```bash
cd apps/examples/counter
pluto build package --device "$DEVICE" --debug
pluto install --device "$DEVICE" --debug --force build/pluto/app.plap
pluto run --device "$DEVICE" --debug dev.pluto.examples.counter
```

`pluto run --debug` forwards the Dart VM service and prints a
`flutter attach --debug-url=...` command. Unsupported targets reject debug
content before installation and tell you to use a release package.

## Troubleshooting

- **Start with `pluto doctor` and `pluto devices --probe`.** They distinguish a
  host setup problem, SSH problem, unsupported model, firmware mismatch, and
  incomplete runtime.
- **SSH asks for a password:** install the tablet's SSH key for the endpoint
  you are using. Pluto assumes non-interactive authentication.
- **Device shell is BusyBox:** GNU flag forms differ (`head -n 20`, not
  `head -20`), and there is no on-device compiler or package manager.
- **Docker is not running:** source builds of device payloads need the pinned
  container toolchains on macOS and x64 Linux.
- **Payload target mismatch:** do not rename metadata or force the install.
  Rebuild with `pluto build package --device "$DEVICE"` and omit any
  contradictory advanced target override.
- **Provisioning or launch fails:** use `pluto logs`, capture the physical
  panel, and then run `pluto provision --restore-remarkable` if you need to
  return to stock while keeping Pluto installed.

## Where to go next

- [Device compatibility](device-compatibility.md) — tested firmware, current
  acceptance status, internal backend selection, ABI ceilings, and recovery.
- [Contributing](../CONTRIBUTING.md) — development workflow and quality gates.
- [Engineering playbook](../AGENTS.md) — source builds, tests, benchmarks,
  payload assembly, and device safety.
- [AOT runtime](aot-runtime.md) — pins, targets, build modes, and artifact
  validation.
- [Pen fast render](pen-fast-render.md) — the pen-latency rendering design.
