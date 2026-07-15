# AGENTS.md — Pluto engineering playbook

This is the fast path for an agent (or a new human) to become productive in the
Pluto repository. It covers the toolchain, the device workflow, tests,
benchmarks, deployment (AOT vs. JIT), hot reload, and the `pluto` CLI. Read
[`README.md`](README.md) for the elevator pitch and
[`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md) for the guided first run;
this file is the reference you keep open while working.

## What Pluto is

Pluto runs Flutter apps on supported reMarkable e-ink tablets through one
discovery-driven product and CLI. Hardware-specific display and lifecycle
backends are selected internally:

- a custom **software-rendering Flutter embedder** (`embedder/`, C++), with an
  e-ink renderer and presenters that drive the panel's waveform controller;
- the **`pluto` CLI** (`tools/pluto/`, Dart) for device discovery,
  provisioning, build, install, logs, screenshots, and hot reload;
- a Flutter **Home/launcher** (`apps/launcher/`) that is the common entry point
  for Pluto applications;
- **`pluto_*` Dart packages** (`packages/`) exposing device, settings, pen,
  touch, sensors, manifest, provision, and UI APIs;
- **example and product apps** (`apps/`): counter, motion_lab, ink_lab,
  validation_lab, ink (drawing), codex (terminal).

Apps ship as release AOT by default. JIT exists only behind explicit `--debug`
flags for hot reload and can never become the boot default.

## Repository map

| Path | What lives there |
| --- | --- |
| `embedder/` | Native embedder, renderer, compositor, profile-selected panel drivers, host preview, CMake presets, C++ tests + benches |
| `tools/pluto/` | The `pluto` CLI (standalone Dart package, resolves outside the workspace) |
| `tools/setup/` | `setup.sh` bootstrap; `camera/` panel-capture helper |
| `tools/build/` | Host and ARM device builds; target payload assemblers |
| `tools/device/` | On-device backends, installer/uninstaller, power/standby, safety harness, diagnostics, shell-contract tests |
| `tools/engine/` | Flutter engine rebuild + promotion (pin maintainers only) |
| `packages/pluto_*` | Dart API packages |
| `apps/` | Launcher, examples, ink, codex, validation_lab |
| `third_party/engine/<hash>/` | Pinned, checksummed Flutter engine payloads (committed on purpose) |
| `docs/` | Getting started, AOT runtime, lifecycle, rendering, icon style, optimisation log, camera |
| `ci/check.sh` | The complete quality gate |

## Toolchain and environment

Everything is pinned. The Flutter SDK and the device engine are exact versions;
do not use a system `flutter`.

- **Flutter**: `3.44.4` (Dart `3.12.x`) — `tools/pluto/pins/flutter.version`.
- **Engine**: `a10d8ac38de835021c8d2f920dbf50a920ccc030` —
  `tools/pluto/pins/engine.version`.

Bootstrap once:

```bash
./tools/setup/setup.sh
```

This validates the committed AOT runtimes, installs the pinned SDK under
`~/.pluto/sdk/3.44.4` if absent, activates Melos, bootstraps the pub workspace,
resolves the CLI package, and compiles `~/.pluto/bin/pluto`. Then put the three
tools on your PATH (setup prints this line):

```bash
export PATH="${PLUTO_BIN_DIR:-$HOME/.pluto/bin}:${PUB_CACHE:-$HOME/.pub-cache}/bin:${PLUTO_SDK:-$HOME/.pluto/sdk/3.44.4}/bin:$PATH"
```

Key environment variables: `PLUTO_SDK` (SDK location), `PLUTO_BIN_DIR` (CLI
install dir), `PLUTO_ROOT` (on-device runtime root, default `/home/root/pluto`).

`./tools/setup/setup.sh --verify` re-checks an installation and all committed
artifacts offline without changing anything.

**Docker** is required on macOS and x64 Linux for the committed AOT snapshot
tools and cross-builds of device-native components. Native AArch64 Linux hosts
can execute the AArch64 snapshotter directly; target-specific native builds
still use their pinned toolchains.

## The Flutter engine — when to rebuild (usually never)

The plain-embedder `libflutter_engine.so` payloads, matching `gen_snapshot`
tools, and ICU data are **committed** under
`third_party/engine/<engine-hash>/` with checksum manifests. The repository
contains AArch64 release/profile and ARMv7 release artifacts. A normal clone
never builds or downloads an engine; `setup.sh` and the CLI verify the pinned
payloads before use.

Rebuild the engine only when you are **changing the Flutter pin** or recovering
the committed artifacts. It is a pin-maintainer task, not part of app or
embedder development:

```bash
tools/engine/build-aarch64-aot.sh     # Docker linux/arm64; builds plain embedder archives
tools/engine/promote-aarch64-aot.sh   # checksum-gated copy into third_party/engine/<hash>/
```

Build products stay in the ignored `.pluto-cache/`. Promotion refuses an
unreviewed pin, re-validates checksums, and checks the built ABI header against
the tracked embedder header. See `tools/engine/README.md`.

Note the distinction: rebuilding the **embedder** (`embedder/`, our C++) is
routine and does *not* touch the Flutter engine — see the build section below.

## Connecting to a reMarkable device

Read the tested model/firmware matrix in
[`docs/device-compatibility.md`](docs/device-compatibility.md) before changing
a device. The public workflow never asks the user to choose a backend:
`pluto devices --probe` reads immutable hardware identity, and provision,
install, run, logs, screenshot, restore, and uninstall dispatch internally.

- **SSH**: `root@10.11.99.1` (the usual single-device USB endpoint), a
  device-specific USB link-local address, or the device's Wi-Fi IP. Enable
  Developer Mode / USB SSH on the tablet, then install your key
  (`ssh-copy-id root@10.11.99.1`). All tooling assumes key auth and connects
  non-interactively.
- **Discovery / health**:

  ```bash
  pluto devices --probe       # model, firmware, provisioned state
  pluto doctor --probe-usb    # host + device environment checks
  ```

- **BusyBox userland**: GNU flag forms differ — use `head -n 20`, not
  `head -20`. There is no on-device compiler, package manager, `strace`, or
  `gdb`. The tooling never needs one.
- **e-ink is bistable**: a crashed UI freezes the last image on glass;
  restarting the display service repaints it.

### Device safety (read before touching the display service)

- `xochitl.service` has `StartLimitBurst=4` / `StartLimitIntervalSec=600`:
  more than four (re)starts in ten minutes trips `OnFailure` and can reboot the
  device. Run `systemctl reset-failed xochitl.service` before any restart, keep
  ≥3 minutes between stop/start cycles, and batch experiments.
- Provisioning is **transactional and reversible**. Every supported device
  uses the native boot-first runtime with a profile-selected panel driver,
  bounded recovery, and a verified stock fallback.
- Never leave the tablet UI-less. Recover through the common commands:
  `pluto provision --restore-remarkable` (keep runtime, stock boots) or
  `pluto provision --uninstall` (full removal). The on-device layout,
  boot-first mechanism, standby/suspend, and recovery are documented in
  `tools/device/README.md`.
- Never bypass the CLI's device-target check or manually install a different
  target's payload. The native runtime owns the display service; provisioning
  refuses mixed-target content and validates boot recovery before activation.

## Running tests

The complete gate (run before sending any change):

```bash
./ci/check.sh
```

It requires the setup-managed SDK and never falls back to a system Flutter. It
runs the shell-contract tests, `dart format --set-exit-if-changed`, analysis,
all package/app/CLI tests, and the launcher goldens.

Targeted runs via Melos (from repo root):

```bash
melos run format            # Dart + native (clang-format) formatting check
melos run analyze           # dart analyze --fatal-infos, workspace + CLI
melos run test              # every package + app + the CLI
melos run goldens           # launcher screen goldens (deterministic)
melos run goldens:update    # regenerate them after an intentional UI change
```

Native (C++) embedder tests use CTest through the build wrapper:

```bash
melos run build:embedder:host              # configure host-debug, build, run CTest
bash tools/build/embedder-host.sh --preset host-release
```

Device shell contracts live in `tools/device/test/*_test.sh` (boot install,
session, standby, warm resume, switcher, power key). They run host-side with
no device attached and are part of `ci/check.sh`.

Golden notes: launcher goldens are in `apps/launcher/test_goldens/`, Ink in
`apps/ink/test_goldens/`, Codex in `apps/codex/test_goldens/`. Regenerate with
the pinned SDK (`flutter test --update-goldens <file>`) and commit the PNGs.
Golden and unit tests assert exact visible label strings — update both when you
rename a label. Run only one `flutter test` at a time (concurrent runs race on
flutter_tools' temp dir).

## Benchmarks

Benches are host CMake targets. An Apple-Silicon host is materially faster than
the tested tablets, so relative speedups may transfer but absolute numbers do
not. Build the release preset and run the binaries:

```bash
cd embedder
cmake --preset host-release
cmake --build --preset host-release
./build/host-release/pluto_renderer_bench      # tile pass, dither, scheduler
./build/host-release/pluto_presenter_bench     # NEON vs scalar sweep/deposit kernels
./build/host-release/ct33_frontend_bench       # colour front-end
```

Budgets are in `embedder/bench/renderer/budgets.yaml` (device p99 targets). The
renderer optimisation history and method are in
[`docs/optimise.md`](docs/optimise.md). For device numbers, cross-build (below)
and run the bench binary on the tablet, pinning to a core with `taskset` when
available; take medians over several runs.

## Building and deploying apps: AOT vs. JIT

Pluto has three build modes. **Release AOT is the default everywhere**; profile
and debug must be explicit at every package/install/run boundary. The
`linux-arm64` target supports all three modes. `linux-arm` currently supports
release AOT only.

| Mode | Engine | Snapshot | Hot reload | VM service | Can boot / Home-launch |
| --- | --- | --- | --- | --- | --- |
| release | product | product `app.so` | no | no | yes (the only boot-default mode) |
| profile | non-product | AOT `app.so` | no | yes (profiling) | no |
| debug | JIT | `kernel_blob.bin` | yes | yes | no |

Release and profile layouts contain `bundle/lib/app.so` and can never contain a
`kernel_blob.bin`. Every layout carries `build-metadata.json` (exact mode,
engine flavor, target, Flutter + engine pins); packaging and provisioning
validate it and refuse mode relabeling. See
[`docs/aot-runtime.md`](docs/aot-runtime.md).

### Responsive application surfaces

Pluto applications follow normal Flutter layout rules on every supported
tablet. Keep `display.scale: auto` (the manifest default), consume the live
window constraints and `MediaQuery` metrics, and let widgets reflow for the
presenter-reported surface and device pixel ratio. Do not select an app layout
from a model name or require one panel's width, height, or aspect ratio.

Numbers such as 954 x 1696 may remain as authored design coordinates,
deterministic golden-test fixtures, document presets, or explicitly scoped
Move-engine measurements. They are never the required Flutter viewport. New
app and launcher changes need responsive tests at every tested viewport family
and real-panel verification where layout or input behavior changes.

### Build the embedder (routine; not the Flutter engine)

```bash
melos run build:embedder:host      # host binary + CTest
melos run build:embedder:device    # AArch64 release embedder
bash tools/build/embedder-device-arm.sh  # ARMv7 release embedder + control client
```

Each device build fails unless its ELF class, machine, hard-float flags, and
system-library ceiling match the target. Outputs live in the ignored
`embedder/build/<preset>/`. See `tools/build/README.md` and
`docs/device-compatibility.md`.

### Assemble release payloads

Release maintainers prepare each native target with the same assembler, while
users never choose a backend during provisioning. Outputs live under
`build/pluto-payload/<target>` and must contain the same release application
identities and pass their target gates.

```bash
melos run build:embedder:device
bash tools/build/assemble-device-payload.sh --target-platform linux-arm64 --standard
bash tools/build/embedder-device-arm.sh
bash tools/build/assemble-device-payload.sh --target-platform linux-arm --standard
```

The ARMv7 assembler packages a pinned, target-native Codex CLI. It rejects
fake acceptance modes, a missing or tampered binary, the wrong version, and an
ABI mismatch. Authentication is user-owned and never embedded in the payload.

Payload assembly gates every app as product AOT and verifies the matching
engine against committed checksums. A bare bundle, mixed targets, or debug
content in a normal release payload is rejected.

### Provision the platform

After both default payloads are prepared, the public command is identical for
every supported tablet:

```bash
DEVICE=root@10.11.99.1
pluto devices --device "$DEVICE" --probe
pluto provision --device "$DEVICE"
pluto provision --device "$DEVICE" --status
```

`pluto provision` chooses the matching preassembled payload after probing the
device. An explicit `--payload-dir` is target-checked and cannot override
hardware identity. `--no-boot-default`, `--restore-remarkable`, and
`--uninstall` also dispatch through the selected safe implementation.

### Install and run a single app (release AOT)

```bash
cd apps/examples/counter
pluto build package --device "$DEVICE" --release
pluto install --device "$DEVICE" --release --force build/pluto/app.plap
pluto run --device "$DEVICE" --release dev.pluto.examples.counter
```

The package builder probes `--device` and selects the matching target. Offline
release automation may use `--target-platform linux-arm64` or `linux-arm` as an
advanced override; a value that contradicts `--device` is rejected.
Install/run/logs/screenshot/uninstall select their backend internally.
`pluto install --launch` starts an AOT app immediately, and `--set-default`
makes it the preferred Pluto app.

### Real-device hardware smoke

```bash
pluto run --device "$DEVICE" --release dev.pluto.launcher
pluto logs --device "$DEVICE"
pluto screenshot --device "$DEVICE" -o shot.png
```

Run Home, Ink, and real Codex through the CLI; require fresh presentation
evidence, exact release/AOT process identity, camera-visible panel behavior,
responsive layout at the presenter-reported viewport, and responsiveness
measurements. The existing
`tools/device/test/release-aot-hardware-smoke.sh` is additional coverage for
the native supervisor, not the whole all-device compatibility gate.

## Local development flow with hot reload

JIT is opt-in and one-shot. Only explicit `--debug` commands allow it, and a
debug app can never become the boot default.

The `linux-arm` target is release-only. Unsupported devices reject debug
content before installation; this capability difference does not change the
normal release workflow.

```bash
cd apps/examples/counter
pluto build package --device "$DEVICE" --debug
pluto install --device "$DEVICE" --debug --force build/pluto/app.plap
pluto run --device "$DEVICE" --debug dev.pluto.examples.counter
```

`pluto run --debug` forwards the Dart VM service and prints a
`flutter attach --debug-url=...` line for your IDE. To reattach to something
already running:

```bash
pluto attach --device "$DEVICE"                            # foreground app
pluto attach --forward-ssh --app dev.pluto.examples.counter
```

Provisioning a debug-capable target with a debug engine requires explicit
`pluto provision --debug`; ordinary provisioning refuses debug payloads. The
debug-capable backend keeps JIT launches explicit and one-shot (see
[`docs/app-pause-resume.md`](docs/app-pause-resume.md)).

## Inspecting the running device

```bash
pluto screenshot --device "$DEVICE" -o shot.png
pluto logs --device "$DEVICE"
pluto logs --device "$DEVICE" --app dev.pluto.examples.counter --since 10m
pluto provision --device "$DEVICE" --status
```

App, time-window, system, and JSON log filters dispatch across backends. Live
`logs --follow` is not implemented by the current SSH transport and fails
explicitly. Screenshot app/surface selections are forwarded to the selected
backend.

For real-glass verification (refresh behavior, ghosting, legibility), point a
camera at the panel. Configure the numbered rig once, then use cropped captures
through `tools/setup/camera/capture.sh`; see
[`tools/setup/camera/README.md`](tools/setup/camera/README.md) and
[`docs/real-device-camera.md`](docs/real-device-camera.md).

## The `pluto` CLI at a glance

| Command | Purpose |
| --- | --- |
| `devices` | List reachable devices (`--probe` for model/firmware/state) |
| `doctor` | Host + optional device health (`--probe-usb`) |
| `build app\|bundle\|package` | AOT app / debug bundle / installable `.plap` (release default) |
| `install` | Install a target-checked `.plap` through the selected backend (release default) |
| `provision` | Install the matching Pluto runtime (`--status`, `--no-boot-default`, `--restore-remarkable`, `--uninstall`) |
| `run` | Launch an installed app through the selected lifecycle backend |
| `attach` | Attach hot reload to a running debug app |
| `logs` | Read filtered Pluto + device log snapshots (`--follow` not yet available) |
| `screenshot` | Capture the current surface as PNG |
| `uninstall` | Remove an app, or `--system` for the whole platform |
| `cleanup` | Remove stale device artifacts (dry-run by default; `--apply`) |

Run `pluto help <command>` for full flags.

## Conventions

- Dart: follow [`DART_GUIDELINES.md`](DART_GUIDELINES.md). Public APIs need doc
  comments and typed signatures.
- Release-only invariant: nothing outside explicit `--debug` flows may put a
  JIT kernel, debug engine, or VM service on the device.
- C ABI changes must bump `PLUTO_ABI_VERSION`.
- Keep device payloads under their managed `/home/root/` roots; always go
  through `pluto provision` and the backend's transactional safety paths.
- Keep mutable build output out of the repo; the pin-keyed `third_party/engine/`
  payloads are the deliberate exception and stay committed.
- Every behavior change gets a test; bug fixes get a regression test. When you
  rename a visible label, update the golden and unit tests that assert it.

## Where to read more

- [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md) — guided first run.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — workflow, gates, rules.
- [`docs/aot-runtime.md`](docs/aot-runtime.md) — AOT/JIT runtime and pins.
- [`docs/app-pause-resume.md`](docs/app-pause-resume.md) — lifecycle, warm
  resume, the app switcher, and bezel/redraw behavior.
- [`docs/pen-fast-render.md`](docs/pen-fast-render.md) — pen-latency rendering.
- [`docs/auto-ghostbuster.md`](docs/auto-ghostbuster.md) — automatic ghost
  maintenance.
- [`docs/icon-design-style.md`](docs/icon-design-style.md) — app-icon language.
- `tools/build/README.md`, `tools/device/README.md`, `tools/engine/README.md` —
  build, device runtime, and engine-maintenance contracts.
