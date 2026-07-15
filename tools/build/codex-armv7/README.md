# Building Codex for ARMv7

`tools/build/build-codex-armv7.sh` builds Pluto's real Codex CLI for the common
ARMv7 target shared by reMarkable 1 and 2. It checks out only the pinned
official OpenAI source, applies the reviewed patch set in this directory,
cross-builds with the official reMarkable SDK, and verifies the device ABI.

The build is intentionally candidate-only. It never overwrites the current
device-tested canonical binary or changes its pin. Promotion is a separate,
reviewed step after two fresh isolated builds produce an identical full-file
SHA-256.

Prerequisites are Docker with `linux/amd64` support, Git, and the same official
SDK input used by `embedder-device-arm.sh`. With the standard SDK volume:

```sh
bash tools/build/build-codex-armv7.sh
```

For an extracted SDK or an already-built container image:

```sh
bash tools/build/build-codex-armv7.sh \
  --sdk-dir /path/to/remarkable-sdk \
  --skip-image-build
```

The first build downloads the official Codex source and Cargo dependencies and
can take around twenty minutes. Each invocation creates a new source checkout,
Cargo home, target tree, and output root under an input key derived from the
recipe, immutable builder image ID, and complete SDK content fingerprint. A run
ID can be supplied when comparing clean builds:

```sh
bash tools/build/build-codex-armv7.sh --run-id repro-a
bash tools/build/build-codex-armv7.sh \
  --run-id repro-b \
  --skip-image-build \
  --expect-sha256 <repro-a-sha256>
```

The second command fails unless its full binary matches the first candidate.
All mutable state remains under `.pluto-cache/build/codex-armv7/`. Nothing is
installed on a tablet and no Codex authentication is read or copied.

Candidate outputs are written to:

```text
.pluto-cache/build/codex-armv7/runs/<input-key>/<run-id>/output/codex
```

The run also records `input-manifest.txt` and `output/build-metadata.json` with
the exact source, image, SDK, patched-lock, compatibility-overlay, and output
identities. The build uses explicit `cargo +1.95.0` commands, installs only the
required ARM target and rustfmt component, excludes `rust-src`, normalizes time
and locale inputs, remaps build paths, and permits no network after the
lockfile-gated fetch.

After a reviewed promotion, pass the canonical path to the one public release
entry point, `assemble-device-release.sh --codex-bin ...`. Its private ARM
slice worker independently repeats the ABI and canonical SHA gates before the
unified provision workflow can contact a device.

The normal Codex CLI, `exec --json`, authentication, API transport, and tools
are real. Only optional V8-backed Code Mode is unavailable on 32-bit ARM; an
attempt to use it returns a clear unsupported error. See `PROVENANCE.md` for
the exact source, toolchain, patches, artifact identity, license handling, and
device proof.
