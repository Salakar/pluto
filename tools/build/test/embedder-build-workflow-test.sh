#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOST_SCRIPT="$ROOT/tools/build/embedder-host.sh"
DEVICE_SCRIPT="$ROOT/tools/build/embedder-device.sh"
ARM_DEVICE_SCRIPT="$ROOT/tools/build/embedder-device-arm.sh"
PAYLOAD_SCRIPT="$ROOT/tools/build/assemble-device-payload.sh"
CONTROL_CLIENT_SOURCE="$ROOT/tools/device/pluto-controlctl.c"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pluto-controlctl-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local text="$1"
  local expected="$2"
  [[ "$text" == *"$expected"* ]] || fail "missing '$expected'"
}

bash -n \
  "$HOST_SCRIPT" \
  "$DEVICE_SCRIPT" \
  "$ARM_DEVICE_SCRIPT" \
  "$PAYLOAD_SCRIPT" \
  "$ROOT/tools/build/embedder-device-container.sh" \
  "$ROOT/tools/build/embedder-device-arm-container.sh" \
  "$ROOT/tools/build/verify-device-elf.sh"

[[ -f "$CONTROL_CLIENT_SOURCE" ]] || fail "generic control client source is missing"
if grep -q '^#define DEFAULT_SOCKET' "$CONTROL_CLIENT_SOURCE"; then
  fail "generic control client still has an implicit socket default"
fi
cc -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror \
  "$CONTROL_CLIENT_SOURCE" -o "$TMP/pluto-controlctl"
[[ "$("$TMP/pluto-controlctl" --help)" == \
  "usage: pluto-controlctl --socket PATH --request JSON" ]] ||
  fail "generic control client help is wrong"
set +e
CONTROL_WITHOUT_SOCKET="$("$TMP/pluto-controlctl" --request '{}' 2>&1)"
CONTROL_WITHOUT_SOCKET_STATUS=$?
set -e
[[ "$CONTROL_WITHOUT_SOCKET_STATUS" -eq 64 ]] ||
  fail "generic control client accepted a request without --socket"
assert_contains "$CONTROL_WITHOUT_SOCKET" \
  "usage: pluto-controlctl --socket PATH --request JSON"

HOST_DRY_RUN="$(bash "$HOST_SCRIPT" --dry-run)"
assert_contains "$HOST_DRY_RUN" "cmake --preset host-debug"
assert_contains "$HOST_DRY_RUN" "cmake --build --preset host-debug --parallel"
assert_contains "$HOST_DRY_RUN" "ctest --preset host-debug --output-on-failure"

HOST_RELEASE_DRY_RUN="$(bash "$HOST_SCRIPT" --dry-run --preset host-release --no-tests)"
assert_contains "$HOST_RELEASE_DRY_RUN" "cmake --preset host-release"
[[ "$HOST_RELEASE_DRY_RUN" != *"ctest"* ]] || fail "--no-tests still invoked CTest"

DEVICE_DRY_RUN="$(bash "$DEVICE_SCRIPT" --dry-run)"
assert_contains "$DEVICE_DRY_RUN" "docker build --platform linux/arm64"
assert_contains "$DEVICE_DRY_RUN" "Dockerfile.embedder-device"
assert_contains "$DEVICE_DRY_RUN" "docker run --rm --platform linux/arm64"
assert_contains "$DEVICE_DRY_RUN" "PLUTO_GLIBC_CEILING=2.39"
assert_contains "$DEVICE_DRY_RUN" "embedder-device-container.sh"
grep -q 'device-arm64/pluto-controlctl' \
  "$ROOT/tools/build/embedder-device-container.sh" ||
  fail "ARM64 screenshot control client is not built"

ARM_DEVICE_DRY_RUN="$(bash "$ARM_DEVICE_SCRIPT" --dry-run)"
assert_contains "$ARM_DEVICE_DRY_RUN" "docker build --platform linux/amd64"
assert_contains "$ARM_DEVICE_DRY_RUN" "Dockerfile.embedder-device"
assert_contains "$ARM_DEVICE_DRY_RUN" "docker run --rm --platform linux/amd64"
assert_contains "$ARM_DEVICE_DRY_RUN" "pluto-rm2-sdk-4.4.128-v2:/sdk:ro"
assert_contains "$ARM_DEVICE_DRY_RUN" "embedder-device-arm-container.sh"
assert_contains "$ARM_DEVICE_DRY_RUN" "embedder/build/device-arm/pluto-embedder 2.35 linux-arm"

ARM_DEVICE_DIR_DRY_RUN="$(
  bash "$ARM_DEVICE_SCRIPT" --dry-run --skip-image-build \
    --sdk-dir /tmp/pluto-remarkable-sdk-fixture
)"
assert_contains "$ARM_DEVICE_DIR_DRY_RUN" \
  "/tmp/pluto-remarkable-sdk-fixture:/sdk:ro"
[[ "$ARM_DEVICE_DIR_DRY_RUN" != *"pluto-rm2-sdk-4.4.128-v2:/sdk:ro"* ]] ||
  fail "--sdk-dir still mounted the default SDK volume"

grep -q '"name": "device-arm"' "$ROOT/embedder/CMakePresets.json" ||
  fail "device-arm CMake preset is missing"
grep -q -- '-march=armv7-a -mfpu=neon -mfloat-abi=hard' \
  "$ROOT/embedder/toolchain/arm-linux-gnueabi.cmake" ||
  fail "device-arm toolchain does not use the common ARMv7-A hard-float baseline"
if grep -Eq -- '-mcpu=(cortex-a7|cortex-a9)' \
  "$ROOT/embedder/toolchain/arm-linux-gnueabi.cmake"; then
  fail "device-arm toolchain is tuned for only one reMarkable CPU"
fi

PAYLOAD_DRY_RUN="$(bash "$PAYLOAD_SCRIPT" --dry-run --app counter --app motion_lab)"
assert_contains "$PAYLOAD_DRY_RUN" "setup.sh --verify"
assert_contains "$PAYLOAD_DRY_RUN" "build app --release"
assert_contains "$PAYLOAD_DRY_RUN" "build/pluto-payload/linux-arm64/launcher"
assert_contains "$PAYLOAD_DRY_RUN" \
  "build/pluto-payload/linux-arm64/apps/dev.pluto.examples.counter"
assert_contains "$PAYLOAD_DRY_RUN" \
  "build/pluto-payload/linux-arm64/apps/dev.pluto.examples.motion_lab"
assert_contains "$PAYLOAD_DRY_RUN" "engine/release/libflutter_engine.so"
assert_contains "$PAYLOAD_DRY_RUN" "engine/profile/libflutter_engine.so"
assert_contains "$PAYLOAD_DRY_RUN" \
  "build/pluto-payload/linux-arm64/bin/pluto-controlctl"
assert_contains "$PAYLOAD_DRY_RUN" \
  "build/pluto-payload/linux-arm64/share/device-profiles.sh"
assert_contains "$PAYLOAD_DRY_RUN" \
  "build/pluto-payload/linux-arm64/pluto-boot-confirm.sh"
assert_contains "$PAYLOAD_DRY_RUN" \
  "build/pluto-payload/linux-arm64/pluto-boot-install.sh"
for retired_script in \
  pluto-boot-hook.sh \
  pluto-bootloop-check.sh \
  pluto-deadman.sh \
  pluto-fingerprint-check.sh \
  pluto-xochitl-guard.sh; do
  [[ "$PAYLOAD_DRY_RUN" != *"$retired_script"* ]] ||
    fail "native payload still carries retired $retired_script"
done
[[ "$PAYLOAD_DRY_RUN" != *"apps/codex"* ]] || fail "Codex was selected implicitly"
[[ "$PAYLOAD_DRY_RUN" != *"kernel_blob.bin"* ]] || fail "dry run copied a JIT kernel"
EXPECTED_NEXT="Native-runtime handoff: pluto provision --payload-dir $ROOT/build/pluto-payload/linux-arm64"
[[ "$(printf '%s\n' "$PAYLOAD_DRY_RUN" | tail -1)" == "$EXPECTED_NEXT" ]] ||
  fail "payload dry run did not end with the exact provision command"

EXAMPLES_DRY_RUN="$(bash "$PAYLOAD_SCRIPT" --dry-run --examples)"
assert_contains "$EXAMPLES_DRY_RUN" "dev.pluto.examples.counter"
assert_contains "$EXAMPLES_DRY_RUN" "dev.pluto.examples.motion_lab"
assert_contains "$EXAMPLES_DRY_RUN" "dev.pluto.examples.ink_lab"
[[ "$EXAMPLES_DRY_RUN" != *"apps/codex"* ]] || fail "--examples included Codex"

STANDARD_DRY_RUN="$(bash "$PAYLOAD_SCRIPT" --dry-run --standard)"
assert_contains "$STANDARD_DRY_RUN" "dev.pluto.examples.counter"
assert_contains "$STANDARD_DRY_RUN" "dev.pluto.examples.motion_lab"
assert_contains "$STANDARD_DRY_RUN" "dev.pluto.examples.ink_lab"
assert_contains "$STANDARD_DRY_RUN" "dev.pluto.validation_lab"
assert_contains "$STANDARD_DRY_RUN" "/apps/dev.pluto.ink"
assert_contains "$STANDARD_DRY_RUN" "dev.pluto.codex"
[[ "$STANDARD_DRY_RUN" != *"kernel_blob.bin"* ]] ||
  fail "--standard dry run copied a JIT kernel"

ARM_PAYLOAD_DRY_RUN="$(
  bash "$PAYLOAD_SCRIPT" --dry-run --target-platform linux-arm --app counter
)"
assert_contains "$ARM_PAYLOAD_DRY_RUN" \
  "embedder/build/device-arm/pluto-embedder 2.35 linux-arm"
assert_contains "$ARM_PAYLOAD_DRY_RUN" \
  "build/pluto-payload/linux-arm/pluto-session.sh"
assert_contains "$ARM_PAYLOAD_DRY_RUN" \
  "build/pluto-payload/linux-arm/apps/dev.pluto.examples.counter"
assert_contains "$ARM_PAYLOAD_DRY_RUN" \
  "Native-runtime handoff: pluto provision --payload-dir $ROOT/build/pluto-payload/linux-arm"
[[ "$ARM_PAYLOAD_DRY_RUN" != *"engine/profile/libflutter_engine.so"* ]] ||
  fail "release-only linux-arm payload included the profile engine"
[[ "$ARM_PAYLOAD_DRY_RUN" != *"cooperative"* ]] ||
  fail "native linux-arm payload still names the cooperative backend"

ARM_STANDARD_DRY_RUN="$(
  bash "$PAYLOAD_SCRIPT" --dry-run --target-platform linux-arm --standard
)"
assert_contains "$ARM_STANDARD_DRY_RUN" \
  ".pluto-cache/build/codex-armv7/output/codex 2.35 linux-arm"
assert_contains "$ARM_STANDARD_DRY_RUN" \
  "build/pluto-payload/linux-arm/bin/codex"
ARM64_STANDARD_IDS="$(printf '%s\n' "$STANDARD_DRY_RUN" |
  sed -n 's|.*build/pluto-payload/linux-arm64/apps/\(dev\.[^ /]*\).*|\1|p' |
  LC_ALL=C sort -u)"
ARM_STANDARD_IDS="$(printf '%s\n' "$ARM_STANDARD_DRY_RUN" |
  sed -n 's|.*build/pluto-payload/linux-arm/apps/\(dev\.[^ /]*\).*|\1|p' |
  LC_ALL=C sort -u)"
[[ -n "$ARM64_STANDARD_IDS" && "$ARM64_STANDARD_IDS" = "$ARM_STANDARD_IDS" ]] ||
  fail "--standard selects different application identities by target"

ENGINE_HASH="$(tr -d '[:space:]' < "$ROOT/tools/pluto/pins/engine.version")"
ARM_ENGINE="$ROOT/third_party/engine/$ENGINE_HASH/linux-arm-release/libflutter_engine.so"
ARM_VERIFY="$(bash "$ROOT/tools/build/verify-device-elf.sh" "$ARM_ENGINE" 2.35 linux-arm)"
assert_contains "$ARM_VERIFY" "ELF32 EM_ARM EABI5 hard-float"
assert_contains "$ARM_VERIFY" "GLIBC_2.18 <= GLIBC_2.35"
assert_contains "$ARM_VERIFY" "GLIBCXX gate: PASS (no versioned imports)"
assert_contains "$ARM_VERIFY" "CXXABI gate: PASS (no versioned imports)"
if bash "$ROOT/tools/build/verify-device-elf.sh" \
  "$ARM_ENGINE" 2.39 linux-arm64 >/dev/null 2>&1; then
  fail "linux-arm engine passed the linux-arm64 ELF gate"
fi

grep -q '^FROM ubuntu:24\.04$' "$ROOT/tools/build/Dockerfile.embedder-device" ||
  fail "device builder is not pinned to Ubuntu 24.04"
grep -q 'bash tools/build/embedder-host\.sh' "$ROOT/pubspec.yaml" ||
  fail "root host build command is not wired"
grep -q 'bash tools/build/embedder-device\.sh' "$ROOT/pubspec.yaml" ||
  fail "root device build command is not wired"
grep -q 'bash tools/build/assemble-device-payload\.sh' "$ROOT/pubspec.yaml" ||
  fail "root device payload command is not wired"
git -C "$ROOT" check-ignore -q embedder/build/device-arm64/pluto-embedder ||
  fail "device binary is not ignored"
git -C "$ROOT" check-ignore -q embedder/build/device-arm/pluto-embedder ||
  fail "ARMv7 device binary is not ignored"
git -C "$ROOT" check-ignore -q build/pluto-payload/linux-arm64/pluto-embedder ||
  fail "assembled payload is not ignored"

echo "PASS: embedder build workflow dry-run contract"
