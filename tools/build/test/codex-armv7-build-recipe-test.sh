#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BUILD_SCRIPT="$ROOT/tools/build/build-codex-armv7.sh"
CONTAINER_SCRIPT="$ROOT/tools/build/codex-armv7/build-container.sh"
SDK_FINGERPRINT_SCRIPT="$ROOT/tools/build/codex-armv7/fingerprint-sdk.sh"
ASSEMBLER="$ROOT/tools/build/assemble-appload-arm-payload.sh"
RECIPE="$ROOT/tools/build/codex-armv7"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local text="$1"
  local expected="$2"
  [[ "$text" == *"$expected"* ]] || fail "missing '$expected'"
}

bash -n "$BUILD_SCRIPT" "$CONTAINER_SCRIPT" "$SDK_FINGERPRINT_SCRIPT" "$ASSEMBLER"

DRY_RUN="$(
  bash "$BUILD_SCRIPT" \
    --dry-run \
    --sdk-volume pluto-test-rm-sdk \
    --source-dir /tmp/pluto-test-openai-codex-source
)"
assert_contains "$DRY_RUN" 'https://github.com/openai/codex.git'
assert_contains "$DRY_RUN" 'rust-v0.144.1'
assert_contains "$DRY_RUN" '44918ea10c0f99151c6710411b4322c2f5c96bea'
assert_contains "$DRY_RUN" 'docker build --platform linux/amd64'
assert_contains "$DRY_RUN" 'PLUTO_CODEX_RECIPE_DIGEST='
assert_contains "$DRY_RUN" 'pluto-test-rm-sdk:/sdk:ro'
assert_contains "$DRY_RUN" 'runs/<input-key>/<automatic-utc-pid>'
assert_contains "$DRY_RUN" 'cargo +1.95.0'
assert_contains "$DRY_RUN" '<candidate>/output/codex 2.35 linux-arm'

grep -q '^FROM rust:1\.95-bookworm@sha256:6258907a' \
  "$RECIPE/Dockerfile" || fail "Rust builder base is not digest-pinned"
grep -q 'PLUTO_CODEX_RECIPE_DIGEST' "$RECIPE/Dockerfile" ||
  fail "builder image is not labeled with the recipe identity"
grep -q -- '--toolchain 1\.95\.0-x86_64-unknown-linux-gnu' \
  "$RECIPE/Dockerfile" || fail "Rust components do not use the explicit toolchain"
grep -q 'rustfmt' "$RECIPE/Dockerfile" || fail "pinned rustfmt component is missing"
if grep -Eq 'component add.*(rust-src|clippy)' "$RECIPE/Dockerfile"; then
  fail "unreviewed Rust components are installed"
fi
grep -qx 'cargo "+\$RUST_TOOLCHAIN" fetch --locked' "$CONTAINER_SCRIPT" ||
  fail "Cargo fetch is not lockfile-gated with the explicit toolchain"
grep -q 'cargo "+\$RUST_TOOLCHAIN" build' "$CONTAINER_SCRIPT" ||
  fail "release build does not use the explicit Rust toolchain"
grep -q -- '--offline' "$CONTAINER_SCRIPT" ||
  fail "release build may access unverified network inputs"
grep -q -- '--remap-path-prefix=/src=' "$CONTAINER_SCRIPT" ||
  fail "Rust source paths are not deterministically remapped"
grep -q 'SOURCE_DATE_EPOCH=1783635027' "$CONTAINER_SCRIPT" ||
  fail "source timestamp is not pinned"
grep -q 'NORMALIZED_LOCK_SHA256=3e158832328435688' "$CONTAINER_SCRIPT" ||
  fail "upstream release lock normalization is not digest-gated"
if grep -q 'generate-lockfile' "$CONTAINER_SCRIPT"; then
  fail "overlay preparation can re-resolve the upstream dependency graph"
fi
grep -q 'PAGABLE_ARCHIVE_SHA256=3658968938a4d1ea' "$CONTAINER_SCRIPT" ||
  fail "pagable crate archive is not digest-gated"
grep -q 'SECCOMPILER_ARCHIVE_SHA256=a4ae55de56877481' "$CONTAINER_SCRIPT" ||
  fail "seccompiler crate archive is not digest-gated"
grep -q 'PAGABLE_PATCHED_TREE_SHA256=' "$CONTAINER_SCRIPT" ||
  fail "patched pagable source tree is not digest-gated"
grep -q 'SECCOMPILER_PATCHED_TREE_SHA256=' "$CONTAINER_SCRIPT" ||
  fail "patched seccompiler source tree is not digest-gated"
grep -q -- '--fuzz=0 --no-backup-if-mismatch' "$CONTAINER_SCRIPT" ||
  fail "compatibility patches permit fuzzy or backup-producing application"
grep -q -- '--sort=name' "$SDK_FINGERPRINT_SCRIPT" ||
  fail "complete SDK content is not deterministically fingerprinted"
grep -q 'target-cpu=generic' "$CONTAINER_SCRIPT" ||
  fail "Codex build is not on the shared ARMv7 CPU baseline"
if grep -Eq -- '-mcpu=(cortex-a7|cortex-a9)' "$CONTAINER_SCRIPT"; then
  fail "Codex build is tuned for only one ARMv7 device"
fi
grep -q 'code mode is unavailable on 32-bit ARM' \
  "$RECIPE/patches/openai-codex-0.144.1-armv7.patch" ||
  fail "32-bit ARM Code Mode behavior is not explicit"
grep -q 'AUDIT_ARCH_ARM' \
  "$RECIPE/patches/seccompiler-0.5.0-armv7.patch" ||
  fail "ARM seccomp audit architecture patch is missing"
grep -q 'target_arch = "arm"' \
  "$RECIPE/patches/pagable-0.4.1-armv7.patch" ||
  fail "ARM pagable layout patch is missing"

build_sha="$(sed -n 's/^readonly CANONICAL_SHA256=//p' "$BUILD_SCRIPT")"
assembler_sha="$(sed -n 's/^readonly CODEX_SHA256=//p' "$ASSEMBLER")"
[[ -n "$build_sha" && "$build_sha" = "$assembler_sha" ]] ||
  fail "Codex canonical and payload SHA-256 pins differ"
grep -q '"path": "$DEVICE_CODEX_BIN"' "$ASSEMBLER" ||
  fail "payload metadata does not use the canonical Codex path"
if grep -q 'PAPER_CODEX_FAKE\|codexAcceptanceMode' "$ASSEMBLER"; then
  fail "release assembler still contains fake Codex acceptance wiring"
fi

git -C "$ROOT" check-ignore -q .pluto-cache/build/codex-armv7/output/codex ||
  fail "Codex release output is not ignored"
git -C "$ROOT" check-ignore -q \
  .pluto-cache/build/codex-armv7/runs/example/example/output/codex ||
  fail "isolated Codex candidate output is not ignored"

grep -q 'RUN_ROOT="\$BUILD_ROOT/runs/\$input_key/\$RUN_ID"' "$BUILD_SCRIPT" ||
  fail "run roots are not keyed by immutable inputs and a fresh run ID"
grep -q 'isolated run already exists' "$BUILD_SCRIPT" ||
  fail "the builder can reuse a prior target or output root"
if grep -q 'OUTPUT_DIR="\$BUILD_ROOT/output"' "$BUILD_SCRIPT"; then
  fail "candidate builder can overwrite the canonical output directory"
fi

echo "PASS: Codex ARMv7 reproducible build recipe contract"
