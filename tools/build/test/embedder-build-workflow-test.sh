#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOST_SCRIPT="$ROOT/tools/build/embedder-host.sh"
DEVICE_SCRIPT="$ROOT/tools/build/embedder-device.sh"
ARM_DEVICE_SCRIPT="$ROOT/tools/build/embedder-device-arm.sh"
PAYLOAD_SCRIPT="$ROOT/tools/build/assemble-device-payload.sh"

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
grep -q 'device-arm64/pluto-apploadctl' \
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
assert_contains "$PAYLOAD_DRY_RUN" "build/pluto-payload/launcher"
assert_contains "$PAYLOAD_DRY_RUN" "build/pluto-payload/apps/dev.pluto.examples.counter"
assert_contains "$PAYLOAD_DRY_RUN" "build/pluto-payload/apps/dev.pluto.examples.motion_lab"
assert_contains "$PAYLOAD_DRY_RUN" "engine/release/libflutter_engine.so"
assert_contains "$PAYLOAD_DRY_RUN" "engine/profile/libflutter_engine.so"
assert_contains "$PAYLOAD_DRY_RUN" "build/pluto-payload/bin/pluto-apploadctl"
[[ "$PAYLOAD_DRY_RUN" != *"apps/codex"* ]] || fail "Codex was selected implicitly"
[[ "$PAYLOAD_DRY_RUN" != *"kernel_blob.bin"* ]] || fail "dry run copied a JIT kernel"
EXPECTED_NEXT="Direct-backend handoff: pluto provision --payload-dir $ROOT/build/pluto-payload"
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
assert_contains "$STANDARD_DRY_RUN" "dev.pluto.codex"
[[ "$STANDARD_DRY_RUN" != *"kernel_blob.bin"* ]] ||
  fail "--standard dry run copied a JIT kernel"

if ARM_PAYLOAD_REFUSAL="$(
  bash "$PAYLOAD_SCRIPT" --dry-run --target-platform linux-arm --app counter 2>&1
)"; then
  fail "direct-backend payload assembler accepted linux-arm"
fi
assert_contains "$ARM_PAYLOAD_REFUSAL" "normal Pluto workflow"
assert_contains "$ARM_PAYLOAD_REFUSAL" "cooperative backend"
[[ "$ARM_PAYLOAD_REFUSAL" != *"pluto-session.sh"* ]] ||
  fail "refused linux-arm payload included Move supervisor scripts"
[[ "$ARM_PAYLOAD_REFUSAL" != *"pluto provision"* ]] ||
  fail "refused linux-arm payload printed a boot-first handoff"

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
git -C "$ROOT" check-ignore -q build/pluto-payload/pluto-embedder ||
  fail "assembled payload is not ignored"

echo "PASS: embedder build workflow dry-run contract"
