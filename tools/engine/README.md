# Flutter engine maintenance

Normal Pluto contributors do **not** build the Flutter engine. The exact
Flutter 3.44.4 AArch64 release/profile runtimes and AOT toolchains needed by
the pinned project are committed under `third_party/engine/<engine-hash>/`.
The setup script verifies those files, and the Pluto CLI consumes them
directly.

This directory is only for a Flutter pin update, recovery, or deliberate
engine configuration work.

## Rebuild the AArch64 AOT engines

Requirements:

- Docker with native or emulated `linux/arm64` support;
- the pinned Flutter SDK checkout (normally
  `~/.pluto/sdk/3.44.4`, or `PLUTO_SDK`);
- network access for the Flutter source dependencies and official artifacts.

Run:

```sh
tools/engine/build-aarch64-aot.sh
```

The script checks the SDK engine pin, syncs the exact engine commit in a
persistent Docker volume, applies the pinned DEPS workaround for the absent
AArch64 JDK package, and builds Flutter's plain embedder archives with the
official Linux AArch64 release/profile configurations plus
`--embedder-for-target`. Build products remain in the ignored
`.pluto-cache/` tree.

Useful overrides are:

```text
PLUTO_SDK
PLUTO_ENGINE_BUILDER_IMAGE
PLUTO_ENGINE_BUILD_VOLUME
PLUTO_ENGINE_BUILD_JOBS
```

The persistent volume avoids a complete engine checkout and rebuild on every
maintenance run. Use a new volume when deliberately changing engine source.

## Update the committed prebuilt payload

After a successful, reviewed rebuild:

```sh
tools/engine/promote-aarch64-aot.sh
```

Promotion refuses an unreviewed engine pin, validates every known checksum,
checks the built ABI header against the tracked embedder header, and copies
only the files needed by a clean clone. It intentionally does not commit the
large source checkout, Docker volume, downloaded archives, or duplicate
headers.

Each `gen_snapshot` comes from Google's revision- and mode-matched AArch64 GTK
archive. The commonly published debug `artifacts.zip` contains a snapshotter
with the profile-compatible `no-dedup_instructions` feature set; using that
tool for a product app creates an incompatible `app.so`. The CLI therefore
uses and verifies the committed mode-specific snapshotters.

## Configuration provenance

Each built runtime uses its matching `--runtime-mode=release|profile` plus:

```text
--target-os=linux
--linux-cpu=arm64
--prebuilt-dart-sdk
--no-lto
--no-rbe
--no-goma
--embedder-for-target
--disable-desktop-embeddings
--no-build-engine-artifacts
--no-build-glfw-shell
--no-build-embedder-examples
--no-enable-unittests
```

`--no-lto` matches Flutter's official Linux AArch64 AOT builders. The results
are plain embedder libraries with no GTK dependency. Exact sources, mode,
target, and hashes are recorded beside each committed payload in
`CHECKSUMS.txt`.
