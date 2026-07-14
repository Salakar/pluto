# OpenAI Codex CLI 0.144.1 — Pluto ARMv7 release provenance

This release input is a real build of the official OpenAI Codex CLI. It does
not contain Pluto's scripted test bridge and is never launched with
`PAPER_CODEX_FAKE` in a release payload.

## Upstream identity

- Repository: <https://github.com/openai/codex>
- Official tag: `rust-v0.144.1`
- Commit: `44918ea10c0f99151c6710411b4322c2f5c96bea`
- Workspace version: `0.144.1`
- Upstream license: Apache License 2.0; the upstream `LICENSE` and `NOTICE`
  files are copied beside every built artifact.

The build script refuses a checkout whose origin or commit differs from these
values.

## Toolchain and target

- Rust: `1.95.0`, from the pinned `rust:1.95-bookworm` image manifest
  `sha256:6258907abe69656e41cd992e0b705cdcfabcbbe3db374f92ed2d47121282d4a1`.
- Rust invocation: explicit `cargo +1.95.0`, `rustc +1.95.0`, and
  `rustfmt +1.95.0`; installed components are the host compiler and standard
  library, ARMv7 standard library, Cargo, and rustfmt. `rust-src` and Clippy are
  rejected so the upstream toolchain file cannot silently change source-span
  paths or compiler inputs.
- Cross SDK: official reMarkable SDK volume
  `pluto-rm2-sdk-4.4.128-v2`; GCC `11.5.0` and its
  `cortexa7hf-neon-remarkable-linux-gnueabi` sysroot.
- Rust target: `armv7-unknown-linux-gnueabihf`.
- CPU/ABI baseline: generic ARMv7-A, NEON, EABI5 hard-float. No
  model-specific Cortex-A7 or Cortex-A9 tuning is enabled.
- Release command: `cargo +1.95.0 build --locked --offline --release --target
  armv7-unknown-linux-gnueabihf --package codex-cli --bin codex`.
- Packaging: official SDK `strip --strip-debug --strip-unneeded`.

## Hermetic build identity

Every invocation uses a new run root containing an independent source
checkout, Cargo home, target tree, and output directory. Runs are grouped by an
input key derived from:

- the source commit, source epoch, toolchain release, container recipe, and
  complete compatibility patch contents;
- the immutable linux/amd64 builder image ID and its checked recipe label;
- a normalized content digest of the complete mounted reMarkable SDK.

The upstream lock is verified before fetching. The release tag's manifests use
`0.144.1` while 132 committed workspace lock entries retain the development
placeholder `0.0.0`; the recipe performs only that reviewed normalization and
digest-gates the complete result before a complete-graph `cargo fetch
--locked`. The fetch deliberately has no target filter so all host, build, and
target archives needed by the later offline compilation are present. The two
selected `.crate` archives are verified against their Cargo.lock SHA-256
values, extracted directly, patched with zero fuzz and no backup files, and
checked against expected patched-tree digests. The recipe retains every
upstream dependency selection and removes only the registry source/checksum
fields for those two local overlays; the complete resulting lockfile must
match its pinned SHA-256 before compilation. It never re-resolves the graph,
which also preserves already-locked upstream releases that were later yanked.

The release environment fixes locale, timezone, source epoch, umask, job
count, and incremental-compilation state. Rust and native compiler paths are
remapped from the stable container mount points, and the linker emits a
content-derived SHA-1 build ID. Candidate metadata records all of these input
identities beside the binary.

## Minimal compatibility patch set

1. `openai-codex-0.144.1-armv7.patch`
   - keeps the real Codex CLI, auth, Responses API, tools, sandbox selection,
     and JSON event stream intact;
   - excludes `rusty_v8` only on 32-bit ARM because upstream does not publish
     that target archive, and returns an explicit unsupported error if the
     optional Code Mode feature is requested;
   - makes Linux syscall-number types portable to 32-bit libc and selects the
     ARM seccomp architecture.
2. `pagable-0.4.1-armv7.patch`
   - corrects a compile-time layout assertion for ARMv7's 4-byte `AtomicU64`
     alignment while preserving the existing 64-bit and wasm32 assertions.
3. `seccompiler-0.5.0-armv7.patch`
   - adds the Linux little-endian `AUDIT_ARCH_ARM` value and `TargetArch::arm`.

The two patched crates are extracted from the exact Cargo.lock-selected crate
archives into the ignored build checkout. Their upstream license files remain
in those source trees.

## Current device-tested canonical artifact

- Relative path: `.pluto-cache/build/codex-armv7/output/codex`
- Size: `211318972` bytes
- SHA-256: `df8b6673f48b10356a7cee64b405c14435401a083f5e04ee147f0bd7b6760bdf`
- Build ID: `f6f44a2ba9a80d00584aa4e5cff8efb5f889ab9f`
- ELF: 32-bit little-endian PIE, `EM_ARM`, EABI5 hard-float
- Maximum imported glibc version: `GLIBC_2.34` (release ceiling `2.35`)
- No GLIBCXX or CXXABI imports
- Runtime libraries: `liblzma.so.5`, `libssl.so.3`, `libcrypto.so.3`,
  `libgcc_s.so.1`, `libm.so.6`, `libc.so.6`, `ld-linux-armhf.so.3`

The candidate builder does not overwrite this artifact or change its pin. It
always enforces the ABI ceiling and optionally accepts `--expect-sha256` to
require byte-for-byte equality with another clean candidate. Canonical
promotion happens only after two isolated candidates match and the result is
reviewed for device deployment.

## Device proof

The exact accepted SHA ran on both tested ARMv7 devices. Each reported
`codex-cli 0.144.1`, rendered `codex exec --help`, and started
`codex exec --json` with an isolated empty Codex home. The unauthenticated run
emitted `thread.started`, `turn.started`, structured error events, and
`turn.failed` after the expected HTTP 401; it did not crash or read any user
credential. Sanitized evidence is kept in the ignored `.pluto-cache/evidence/`
directory.
