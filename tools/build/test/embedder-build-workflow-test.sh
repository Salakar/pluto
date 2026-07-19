#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOST_SCRIPT="$ROOT/tools/build/embedder-host.sh"
DEVICE_SCRIPT="$ROOT/tools/build/embedder-device.sh"
ARM_DEVICE_SCRIPT="$ROOT/tools/build/embedder-device-arm.sh"
ARM_SDK_FINGERPRINT="$ROOT/tools/build/fingerprint-arm-sdk.sh"
ARM_SDK_VERIFY="$ROOT/tools/build/verify-arm-sdk.sh"
ARM_SDK_PIN="$ROOT/tools/pluto/pins/arm-sdk.pin"
RELEASE_SCRIPT="$ROOT/tools/build/assemble-device-release.sh"
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
  "$ARM_SDK_FINGERPRINT" \
  "$ARM_SDK_VERIFY" \
  "$RELEASE_SCRIPT" \
  "$PAYLOAD_SCRIPT" \
  "$ROOT/tools/build/embedder-device-container.sh" \
  "$ROOT/tools/build/embedder-device-arm-container.sh" \
  "$ROOT/tools/build/verify-device-elf.sh"

grep -q 'reject_host_metadata "$layout"' "$PAYLOAD_SCRIPT" ||
  fail "release layouts are not checked for host metadata"
grep -q 'reject_host_metadata "$PAYLOAD"' "$PAYLOAD_SCRIPT" ||
  fail "the assembled payload is not checked for host metadata"
grep -q 'PLUTO_ELF_ALLOW_NO_GLIBC=1' "$PAYLOAD_SCRIPT" ||
  fail "self-contained AOT app snapshots do not use the scoped no-GLIBC gate"
[[ "$(grep -c 'PLUTO_ELF_ALLOW_NO_GLIBC=1' "$PAYLOAD_SCRIPT")" -eq 1 ]] ||
  fail "no-GLIBC allowance escaped the single app snapshot verification path"
if PLUTO_ELF_ALLOW_NO_GLIBC=invalid \
  bash "$ROOT/tools/build/verify-device-elf.sh" \
    "$ROOT/third_party/engine/$(tr -d '[:space:]' < "$ROOT/tools/pluto/pins/engine.version")/linux-arm-release/libflutter_engine.so" \
    2.35 linux-arm >/dev/null 2>&1; then
  fail "ELF verifier accepted an invalid no-GLIBC policy"
fi
for forbidden_metadata in '.DS_Store' '.AppleDouble' '._*'; do
  grep -Fq -- "$forbidden_metadata" "$PAYLOAD_SCRIPT" ||
    fail "payload metadata gate is missing $forbidden_metadata"
done

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
assert_contains "$ARM_DEVICE_DRY_RUN" "bash tools/build/verify-arm-sdk.sh"
assert_contains "$ARM_DEVICE_DRY_RUN" "$ROOT:/work:ro"
assert_contains "$ARM_DEVICE_DRY_RUN" "--user"
PLUTO_ARM_SDK_PIN="$ARM_SDK_PIN" bash "$ARM_SDK_VERIFY" --pin-only >/dev/null
cp "$ARM_SDK_PIN" "$TMP/arm-sdk.pin"
sed 's/^regular_files=.*/regular_files=0/' "$TMP/arm-sdk.pin" > \
  "$TMP/arm-sdk.invalid"
if PLUTO_ARM_SDK_PIN="$TMP/arm-sdk.invalid" \
  bash "$ARM_SDK_VERIFY" --pin-only >/dev/null 2>&1; then
  fail "ARM SDK gate accepted a malformed authoritative pin"
fi

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

ARM64_SLICE="$TMP/release/targets/linux-arm64"
ARM_SLICE="$TMP/release/targets/linux-arm"
PAYLOAD_DRY_RUN="$(
  bash "$PAYLOAD_SCRIPT" --dry-run --output "$ARM64_SLICE" \
    --app counter --app motion_lab
)"
assert_contains "$PAYLOAD_DRY_RUN" "setup.sh --verify"
assert_contains "$PAYLOAD_DRY_RUN" "build app --release"
assert_contains "$PAYLOAD_DRY_RUN" "$ARM64_SLICE/launcher"
assert_contains "$PAYLOAD_DRY_RUN" \
  "$ARM64_SLICE/apps/dev.pluto.examples.counter"
assert_contains "$PAYLOAD_DRY_RUN" \
  "$ARM64_SLICE/apps/dev.pluto.examples.motion_lab"
assert_contains "$PAYLOAD_DRY_RUN" "engine/release/libflutter_engine.so"
assert_contains "$PAYLOAD_DRY_RUN" "engine/profile/libflutter_engine.so"
assert_contains "$PAYLOAD_DRY_RUN" \
  "$ARM64_SLICE/bin/pluto-controlctl"
assert_contains "$PAYLOAD_DRY_RUN" \
  "$ARM64_SLICE/share/device-profiles.sh"
assert_contains "$PAYLOAD_DRY_RUN" \
  "$ARM64_SLICE/pluto-boot-confirm.sh"
assert_contains "$PAYLOAD_DRY_RUN" \
  "$ARM64_SLICE/pluto-boot-install.sh"
assert_contains "$PAYLOAD_DRY_RUN" \
  "$ARM64_SLICE/pluto-session-once.sh"
[[ "$PAYLOAD_DRY_RUN" != *"pluto-rm2-cpufreq-restore.sh"* ]] ||
  fail "ARM64 slice still carries the RM2-only CPU-frequency restorer"
[[ "$PAYLOAD_DRY_RUN" != *"apps/codex"* ]] || fail "Codex was selected implicitly"
[[ "$PAYLOAD_DRY_RUN" != *"kernel_blob.bin"* ]] || fail "dry run copied a JIT kernel"
EXPECTED_NEXT="Internal release slice complete: $ARM64_SLICE"
[[ "$(printf '%s\n' "$PAYLOAD_DRY_RUN" | tail -1)" == "$EXPECTED_NEXT" ]] ||
  fail "private slice dry run did not end with its exact output"

EXAMPLES_DRY_RUN="$(
  bash "$PAYLOAD_SCRIPT" --dry-run --output "$ARM64_SLICE" --examples
)"
assert_contains "$EXAMPLES_DRY_RUN" "dev.pluto.examples.counter"
assert_contains "$EXAMPLES_DRY_RUN" "dev.pluto.examples.motion_lab"
assert_contains "$EXAMPLES_DRY_RUN" "dev.pluto.examples.ink_lab"
[[ "$EXAMPLES_DRY_RUN" != *"apps/codex"* ]] || fail "--examples included Codex"

STANDARD_DRY_RUN="$(
  bash "$PAYLOAD_SCRIPT" --dry-run --output "$ARM64_SLICE" --standard
)"
assert_contains "$STANDARD_DRY_RUN" "dev.pluto.examples.counter"
assert_contains "$STANDARD_DRY_RUN" "dev.pluto.examples.motion_lab"
assert_contains "$STANDARD_DRY_RUN" "dev.pluto.examples.ink_lab"
assert_contains "$STANDARD_DRY_RUN" "dev.pluto.validation_lab"
assert_contains "$STANDARD_DRY_RUN" "/apps/dev.pluto.ink"
assert_contains "$STANDARD_DRY_RUN" "dev.pluto.codex"
[[ "$STANDARD_DRY_RUN" != *"kernel_blob.bin"* ]] ||
  fail "--standard dry run copied a JIT kernel"

ARM_PAYLOAD_DRY_RUN="$(
  bash "$PAYLOAD_SCRIPT" --dry-run --target-platform linux-arm \
    --output "$ARM_SLICE" --app counter
)"
assert_contains "$ARM_PAYLOAD_DRY_RUN" \
  "embedder/build/device-arm/pluto-embedder 2.35 linux-arm"
assert_contains "$ARM_PAYLOAD_DRY_RUN" \
  "$ARM_SLICE/pluto-session.sh"
assert_contains "$ARM_PAYLOAD_DRY_RUN" \
  "$ARM_SLICE/pluto-rm2-cpufreq-restore.sh"
assert_contains "$ARM_PAYLOAD_DRY_RUN" \
  "$ARM_SLICE/apps/dev.pluto.examples.counter"
assert_contains "$ARM_PAYLOAD_DRY_RUN" \
  "Internal release slice complete: $ARM_SLICE"
[[ "$ARM_PAYLOAD_DRY_RUN" != *"engine/profile/libflutter_engine.so"* ]] ||
  fail "release-only linux-arm payload included the profile engine"
ARM_STANDARD_DRY_RUN="$(
  bash "$PAYLOAD_SCRIPT" --dry-run --target-platform linux-arm \
    --output "$ARM_SLICE" --standard
)"
assert_contains "$ARM_STANDARD_DRY_RUN" \
  "dev.pluto.examples.counter"
assert_contains "$ARM_STANDARD_DRY_RUN" \
  "dev.pluto.examples.motion_lab"
assert_contains "$ARM_STANDARD_DRY_RUN" \
  "dev.pluto.examples.ink_lab"
assert_contains "$ARM_STANDARD_DRY_RUN" \
  "dev.pluto.validation_lab"
assert_contains "$ARM_STANDARD_DRY_RUN" \
  "$ARM_SLICE/apps/dev.pluto.ink"
[[ "$ARM_STANDARD_DRY_RUN" != *"dev.pluto.codex"* ]] ||
  fail "linux-arm standard payload included unsupported Paper Codex"
[[ "$ARM_STANDARD_DRY_RUN" != *"/bin/codex"* ]] ||
  fail "linux-arm standard payload included a custom Codex CLI"
if bash "$PAYLOAD_SCRIPT" --dry-run --target-platform linux-arm \
  --output "$ARM_SLICE" --app codex >/dev/null 2>&1; then
  fail "linux-arm accepted an explicitly selected unsupported Paper Codex"
fi
ARM64_STANDARD_IDS="$(printf '%s\n' "$STANDARD_DRY_RUN" |
  sed -n 's|.*/targets/linux-arm64/apps/\(dev\.[^ /]*\).*|\1|p' |
  LC_ALL=C sort -u)"
ARM_STANDARD_IDS="$(printf '%s\n' "$ARM_STANDARD_DRY_RUN" |
  sed -n 's|.*/targets/linux-arm/apps/\(dev\.[^ /]*\).*|\1|p' |
  LC_ALL=C sort -u)"
[[ -n "$ARM64_STANDARD_IDS" && -n "$ARM_STANDARD_IDS" ]] ||
  fail "--standard did not select applications for both targets"
[[ "$(comm -23 \
  <(printf '%s\n' "$ARM64_STANDARD_IDS") \
  <(printf '%s\n' "$ARM_STANDARD_IDS"))" == "dev.pluto.codex" ]] ||
  fail "Paper Codex must be the only standard-app capability difference"
[[ -z "$(comm -13 \
  <(printf '%s\n' "$ARM64_STANDARD_IDS") \
  <(printf '%s\n' "$ARM_STANDARD_IDS"))" ]] ||
  fail "linux-arm selected an app unavailable on linux-arm64"

RELEASE_FIXTURE="$TMP/release-fixture"
install -d \
  "$RELEASE_FIXTURE/tools/build" \
  "$RELEASE_FIXTURE/tools/pluto/pins" \
  "$RELEASE_FIXTURE/tools/pluto/tool"
RELEASE_FIXTURE="$(cd "$RELEASE_FIXTURE" && pwd)"
RELEASE_FIXTURE_SCRIPT="$RELEASE_FIXTURE/tools/build/assemble-device-release.sh"
MISSING_RELEASE_SDK="$RELEASE_FIXTURE/missing-sdk"
install -m 0755 "$RELEASE_SCRIPT" "$RELEASE_FIXTURE_SCRIPT"
install -m 0755 "$PAYLOAD_SCRIPT" \
  "$RELEASE_FIXTURE/tools/build/assemble-device-payload.sh"
install -m 0644 "$ROOT/tools/pluto/pins/flutter.version" \
  "$RELEASE_FIXTURE/tools/pluto/pins/flutter.version"
install -m 0644 "$ROOT/tools/pluto/tool/write_release_manifest.dart" \
  "$RELEASE_FIXTURE/tools/pluto/tool/write_release_manifest.dart"
git -C "$RELEASE_FIXTURE" init -q
git -C "$RELEASE_FIXTURE" config user.name "Pluto Test"
git -C "$RELEASE_FIXTURE" config user.email "pluto-test@example.invalid"
git -C "$RELEASE_FIXTURE" add tools
git -C "$RELEASE_FIXTURE" -c commit.gpgsign=false commit -qm "fixture"
[[ ! -e "$MISSING_RELEASE_SDK" ]] ||
  fail "release dry-run fixture unexpectedly contains a Flutter SDK"
[[ ! -e "$RELEASE_FIXTURE/tools/pluto/.dart_tool/package_config.json" ]] ||
  fail "release dry-run fixture unexpectedly contains CLI dependencies"
RELEASE_DRY_RUN="$(
  PLUTO_SDK="$MISSING_RELEASE_SDK" \
    bash "$RELEASE_FIXTURE_SCRIPT" --dry-run
)"
assert_contains "$RELEASE_DRY_RUN" "embedder-device.sh --dry-run"
assert_contains "$RELEASE_DRY_RUN" "embedder-device-arm.sh --dry-run"
assert_contains "$RELEASE_DRY_RUN" "--target-platform linux-arm64"
assert_contains "$RELEASE_DRY_RUN" "--target-platform linux-arm"
assert_contains "$RELEASE_DRY_RUN" "--standard"
assert_contains "$RELEASE_DRY_RUN" "targets/linux-arm64"
assert_contains "$RELEASE_DRY_RUN" "targets/linux-arm"
assert_contains "$RELEASE_DRY_RUN" "write_release_manifest.dart"
assert_contains "$RELEASE_DRY_RUN" "write-release-revision"
assert_contains "$RELEASE_DRY_RUN" "--git-revision"
assert_contains "$RELEASE_DRY_RUN" \
  "$MISSING_RELEASE_SDK/bin/cache/dart-sdk/bin/dart"
assert_contains "$RELEASE_DRY_RUN" \
  "$RELEASE_FIXTURE/tools/pluto/.dart_tool/package_config.json"
if bash "$RELEASE_SCRIPT" --dry-run --codex-bin /tmp/codex >/dev/null 2>&1; then
  fail "universal release still accepts an alternate Codex binary"
fi
EXPECTED_RELEASE_NEXT="Universal release handoff: pluto provision --payload-dir $RELEASE_FIXTURE/build/pluto-release"
[[ "$(printf '%s\n' "$RELEASE_DRY_RUN" | tail -1)" == "$EXPECTED_RELEASE_NEXT" ]] ||
  fail "universal release dry run did not end with the common provision command"
grep -q 'diff --quiet' "$RELEASE_SCRIPT" ||
  fail "universal release does not require one clean tracked revision"
grep -q 'status --porcelain --untracked-files=normal' "$RELEASE_SCRIPT" ||
  fail "universal release can omit untracked source from its frozen revision"
[[ "$(grep -c 'require_clean_revision' "$RELEASE_SCRIPT")" -ge 4 ]] ||
  fail "universal release does not recheck source before manifest and promotion"
grep -q 'write_release_manifest.dart' "$RELEASE_SCRIPT" ||
  fail "universal release does not freeze its per-file hash manifest"

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

grep -q '^FROM ubuntu:24\.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90$' \
  "$ROOT/tools/build/Dockerfile.embedder-device" ||
  fail "device builder base image is not digest-pinned"
grep -q 'bash tools/build/embedder-host\.sh' "$ROOT/pubspec.yaml" ||
  fail "root host build command is not wired"
grep -q 'bash tools/build/embedder-device\.sh' "$ROOT/pubspec.yaml" ||
  fail "root device build command is not wired"
grep -q 'bash tools/build/assemble-device-release\.sh' "$ROOT/pubspec.yaml" ||
  fail "root universal release command is not wired"
git -C "$ROOT" check-ignore -q embedder/build/device-arm64/pluto-embedder ||
  fail "device binary is not ignored"
git -C "$ROOT" check-ignore -q embedder/build/device-arm/pluto-embedder ||
  fail "ARMv7 device binary is not ignored"
git -C "$ROOT" check-ignore -q build/pluto-release/targets/linux-arm64/pluto-embedder ||
  fail "assembled universal release is not ignored"

echo "PASS: embedder build workflow dry-run contract"
