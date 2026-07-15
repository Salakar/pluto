# Contributing to Pluto

Thanks for helping bring Flutter to paper. This document covers the
development setup, the quality gates every change must pass, and the
project rules that keep the device safe and the tree reproducible.

## Setup

Bootstrap from a clean clone:

```bash
./tools/setup/setup.sh
```

The script locates the pinned Flutter SDK from `tools/pluto/pins/`
(installing it under `~/.pluto/sdk/` when absent), activates Melos,
bootstraps the pub workspace, resolves the standalone `tools/pluto` CLI
package, and compiles the CLI to `~/.pluto/bin/pluto`. Run the `export
PATH=...` line it prints. New to the project? Read
[`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md) first.

All checks run against this exact SDK — never a system Flutter
installation.

## Everyday commands

- `melos run format` — check Dart and native formatting.
- `melos run analyze` — strict Dart analysis for the workspace and CLI.
- `melos run test` — package, app, and CLI tests.
- `melos run goldens` — verify the deterministic launcher screen fixtures.
- `melos run goldens:update` — regenerate them after an intentional UI
  change (see below).
- `melos run build:embedder:host` — build and CTest the native host
  embedder.
- `melos run build:embedder:device` — build the AArch64 release embedder
  in the checked-in Ubuntu container toolchain (needs Docker).
- `bash tools/build/embedder-device-arm.sh` — build the ARMv7 release embedder
  and control client with the pinned reMarkable toolchain (needs Docker on
  non-native hosts).
- `melos run build:device-release` — build both native target slices and the
  same standard release-AOT app set, then freeze them under one integrity-
  checked release manifest. Target workers are private; users always provision
  through the same device-aware `pluto provision` command.
- `./ci/check.sh` — the complete Dart, shell-contract, and golden quality
  gate. Run it before sending a change.

Native changes must also pass the relevant `build:embedder:*` command;
the native CI workflow runs device builds separately. Changes to shared
embedder code must pass both the AArch64 and ARMv7 device builds.

## Testing expectations

- Every behavior change comes with a test. Bug fixes come with a
  regression test that fails before the fix.
- **Goldens and responsive layout**: launcher screens are pixel-locked in
  `apps/launcher/test_goldens/` (plus `packages/pluto_ui/test/goldens`), with
  app-specific fixtures under `apps/ink/test_goldens/` and
  `apps/codex/test_goldens/`. If you intentionally change UI, regenerate the
  relevant fixtures with the pinned SDK and commit the PNGs with your change.
  Golden dimensions are deterministic reference fixtures, not runtime viewport
  requirements. Layout changes also need widget coverage at every tested
  viewport family, using live Flutter constraints rather than model names or
  fixed panel dimensions. Golden and unit tests assert exact label strings —
  when renaming a visible label, update both test files.
- **Shell contracts**: the device supervisor and installer scripts in
  `tools/device/` are covered by the `tools/device/test/*_test.sh`
  harnesses; changes to boot, standby, session, or install behavior need
  a matching contract test.
- **Embedder**: C++ changes need CTest coverage
  (`melos run build:embedder:host` runs the suite).

## Project rules

- Follow [`DART_GUIDELINES.md`](DART_GUIDELINES.md) for all Dart code.
  Public Dart APIs need doc comments and typed signatures.
- Keep mutable build output out of the repository. The pin-keyed release
  and profile engine payloads under `third_party/engine/` are
  intentional, checksummed clone dependencies and must remain committed.
- Release-only invariant: default builds, installs, and provisioning are
  product AOT. Nothing outside explicit `--debug` flows may introduce a
  JIT kernel, a debug engine, or a VM service on the device.
- C ABI changes must bump `PLUTO_ABI_VERSION`.
- Keep device payloads under their managed `/home/root/` roots. Device writes
  must go through the public `pluto provision`, `pluto install`,
  `pluto provision --restore-remarkable`, and
  `pluto provision --uninstall` commands so discovery can select the target and
  its transactional safety path. Do not install a second display owner,
  unmanaged service override, or another target's payload by hand. A tablet
  must never be left without a working UI.
- Coordinate device display-service changes in `agents_wip.txt`.

## Sending a change

1. `./ci/check.sh` passes.
2. Native touched? The relevant `build:embedder:*` command passes too.
3. Goldens regenerated and committed if UI changed intentionally.
4. Docs updated when behavior, flags, or layout contracts change
   (`README.md`, `docs/GETTING_STARTED.md`, `tools/*/README.md`).

Keep commits focused; describe device-visible effects in the message.
