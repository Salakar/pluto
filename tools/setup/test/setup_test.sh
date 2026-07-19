#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../setup.sh
source "$ROOT/tools/setup/setup.sh"

FLUTTER_VERSION="3.44.4"
ENGINE_VERSION="a10d8ac38de835021c8d2f920dbf50a920ccc030"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pluto-setup-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

expect_failure() {
  local label="$1"
  shift
  if ("$@") >/dev/null 2>&1; then
    printf 'FAIL: %s unexpectedly succeeded\n' "$label" >&2
    exit 1
  fi
}

DIGEST_FIXTURE="$TMP/generated-lut.h"
DIGEST_PIN="$TMP/generated-lut.sha256"
printf 'abc' > "$DIGEST_FIXTURE"
printf '%s\n' \
  'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' \
  > "$DIGEST_PIN"
validate_generated_digest "$DIGEST_FIXTURE" "$DIGEST_PIN" "test LUT"
printf '%064d\n' 0 > "$DIGEST_PIN"
expect_failure "wrong generated digest" \
  validate_generated_digest "$DIGEST_FIXTURE" "$DIGEST_PIN" "test LUT"
printf 'not-a-digest\n' > "$DIGEST_PIN"
expect_failure "malformed generated digest" \
  validate_generated_digest "$DIGEST_FIXTURE" "$DIGEST_PIN" "test LUT"

[[ "$(print_path_export /opt/pluto/bin /opt/pub-cache /opt/flutter)" == \
  'export PATH="/opt/pluto/bin:/opt/pub-cache/bin:/opt/flutter/bin:$PATH"' ]] || {
  printf 'FAIL: setup PATH export omitted Pluto, Melos, or Flutter\n' >&2
  exit 1
}

write_manifest() {
  local dir="$1"
  local target="${2:-linux-arm64}"

  {
    printf 'schema=1\n'
    printf 'flutter=%s\n' "$FLUTTER_VERSION"
    printf 'engine=%s\n' "$ENGINE_VERSION"
    printf 'target=%s\n' "$target"
    printf 'mode=release\n'
    printf 'engine_source=test fixture\n'
    printf 'gen_snapshot_source=test fixture\n'
    printf 'icu_source=test fixture\n'
    printf 'gn_args=test fixture\n'
    printf '\n'
    printf '%s  libflutter_engine.so\n' "$(sha256_file "$dir/libflutter_engine.so")"
    printf '%s  gen_snapshot\n' "$(sha256_file "$dir/gen_snapshot")"
    printf '%s  icudtl.dat\n' "$(sha256_file "$dir/icudtl.dat")"
    printf '%s  LICENSE.artifacts.md\n' \
      "$(sha256_file "$dir/LICENSE.artifacts.md")"
    printf '%s  LICENSE.embedder-archive.md\n' \
      "$(sha256_file "$dir/LICENSE.embedder-archive.md")"
    printf '%s  LICENSE.flutter_gtk.md\n' \
      "$(sha256_file "$dir/LICENSE.flutter_gtk.md")"
  } > "$dir/CHECKSUMS.txt"
}

SDK="$TMP/sdk"
mkdir -p "$SDK/bin/internal" "$SDK/bin/cache"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SDK/bin/flutter"
chmod +x "$SDK/bin/flutter"
printf '%s\n' "$ENGINE_VERSION" > "$SDK/bin/internal/engine.version"
printf '{"frameworkVersion":"%s"}\n' "$FLUTTER_VERSION" \
  > "$SDK/bin/cache/flutter.version.json"

validate_sdk "$SDK" "$FLUTTER_VERSION" "$ENGINE_VERSION"

printf '%s\n' "0000000000000000000000000000000000000000" \
  > "$SDK/bin/internal/engine.version"
expect_failure "wrong SDK engine pin" \
  validate_sdk "$SDK" "$FLUTTER_VERSION" "$ENGINE_VERSION"
printf '%s\n' "$ENGINE_VERSION" > "$SDK/bin/internal/engine.version"

fixture_dart_main() {
  local sdk_dir
  local output=""

  sdk_dir="$(cd "$(dirname "$0")/../../../.." && pwd)"
  case "${1:-}" in
    */tools/codegen/generate_*.dart)
      printf 'dart-codegen:%s\n' "$1" >> "$sdk_dir/bootstrap-order"
      ;;
    pub)
      [[ "${2:-}" == global && "${3:-}" == activate ]]
      mkdir -p "${PUB_CACHE:?}/bin"
      printf '#!/usr/bin/env bash\nexit 0\n' > "$PUB_CACHE/bin/melos"
      chmod +x "$PUB_CACHE/bin/melos"
      ;;
    compile)
      while (($#)); do
        if [[ "$1" == -o ]]; then
          output="$2"
          break
        fi
        shift
      done
      [[ -n "$output" ]]
      printf '#!/usr/bin/env bash\nexit 0\n' > "$output"
      ;;
    *)
      return 97
      ;;
  esac
}

fixture_flutter_main() {
  local sdk_dir
  local dart
  local flutter_version
  local engine_version

  sdk_dir="$(cd "$(dirname "$0")/.." && pwd)"
  case "${1:-}" in
    --version)
      [[ "${2:-}" == --machine ]]
      printf 'flutter-init\n' >> "$sdk_dir/bootstrap-order"
      dart="$sdk_dir/bin/cache/dart-sdk/bin/dart"
      mkdir -p "$(dirname "$dart")"
      {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        declare -f fixture_dart_main
        printf 'fixture_dart_main "$@"\n'
      } > "$dart"
      chmod +x "$dart"
      flutter_version="$(tr -d '[:space:]' \
        < "$sdk_dir/test-fixtures/flutter.version")"
      engine_version="$(tr -d '[:space:]' \
        < "$sdk_dir/bin/internal/engine.version")"
      printf \
        '{"frameworkVersion":"%s","engineRevision":"%s"}\n' \
        "$flutter_version" "$engine_version"
      ;;
    pub)
      [[ "${2:-}" == get ]]
      ;;
    *)
      return 96
      ;;
  esac
}

SDK_SOURCE="$TMP/flutter-source"
mkdir -p "$SDK_SOURCE/bin/internal" "$SDK_SOURCE/test-fixtures"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  declare -f fixture_dart_main
  declare -f fixture_flutter_main
  printf 'fixture_flutter_main "$@"\n'
} > "$SDK_SOURCE/bin/flutter"
chmod +x "$SDK_SOURCE/bin/flutter"
printf '%s\n' "$ENGINE_VERSION" > "$SDK_SOURCE/bin/internal/engine.version"
printf '%s\n' "$FLUTTER_VERSION" \
  > "$SDK_SOURCE/test-fixtures/flutter.version"
git -C "$SDK_SOURCE" init -q
git -C "$SDK_SOURCE" config user.email setup-test@pluto.invalid
git -C "$SDK_SOURCE" config user.name "Pluto setup test"
git -C "$SDK_SOURCE" add bin test-fixtures
git -C "$SDK_SOURCE" commit -qm "test Flutter SDK"
git -C "$SDK_SOURCE" tag "$FLUTTER_VERSION"

ACQUIRED_SDK="$TMP/acquired-sdk"
acquire_sdk "$ACQUIRED_SDK" "$FLUTTER_VERSION" "$SDK_SOURCE" >/dev/null 2>&1
validate_sdk "$ACQUIRED_SDK" "$FLUTTER_VERSION" "$ENGINE_VERSION"
[[ ! -e "$ACQUIRED_SDK/bin/cache/dart-sdk/bin/dart" ]] || {
  printf 'FAIL: acquired SDK fixture was not cold\n' >&2
  exit 1
}
expect_failure "verify accepted an uninitialized SDK" \
  require_cached_dart_sdk "$ACQUIRED_SDK"
VERIFY_OUTPUT="$TMP/uninitialized-verify.out"
if (PLUTO_SDK="$ACQUIRED_SDK" main --verify) \
  > "$VERIFY_OUTPUT" 2>&1; then
  printf 'FAIL: setup --verify initialized or accepted a cold SDK\n' >&2
  exit 1
fi
grep -q 'pinned Flutter SDK is not initialized: missing' "$VERIFY_OUTPUT" || {
  printf 'FAIL: setup --verify did not explain the missing cached Dart SDK\n' >&2
  exit 1
}
[[ ! -e "$ACQUIRED_SDK/bootstrap-order" ]] || {
  printf 'FAIL: offline SDK verification invoked Flutter\n' >&2
  exit 1
}
initialize_flutter_sdk \
  "$ACQUIRED_SDK" "$FLUTTER_VERSION" "$ENGINE_VERSION" >/dev/null
[[ -x "$ACQUIRED_SDK/bin/cache/dart-sdk/bin/dart" ]] || {
  printf 'FAIL: Flutter initialization did not materialize cached Dart\n' >&2
  exit 1
}
[[ "$(sed -n '1p' "$ACQUIRED_SDK/bootstrap-order")" == flutter-init ]] || {
  printf 'FAIL: cached Dart appeared before Flutter initialization\n' >&2
  exit 1
}

COLD_SDK="$TMP/cold-main-sdk"
COLD_HOME="$TMP/cold-home"
COLD_PUB_CACHE="$TMP/cold-pub-cache"
COLD_BIN="$TMP/cold-bin"
COLD_GIT_CONFIG="$TMP/cold-gitconfig"
COLD_MAIN_OUTPUT="$TMP/cold-main.out"
mkdir -p "$COLD_HOME"
GIT_CONFIG_GLOBAL="$COLD_GIT_CONFIG" git config --global \
  "url.file://$SDK_SOURCE.insteadOf" "$FLUTTER_REPOSITORY"
if ! GIT_ALLOW_PROTOCOL=file \
  GIT_CONFIG_GLOBAL="$COLD_GIT_CONFIG" \
  HOME="$COLD_HOME" \
  PLUTO_SDK="$COLD_SDK" \
  PUB_CACHE="$COLD_PUB_CACHE" \
  PLUTO_BIN_DIR="$COLD_BIN" \
    bash -c 'source "$1"; main' _ "$ROOT/tools/setup/setup.sh" \
      > "$COLD_MAIN_OUTPUT" 2>&1; then
  sed -n '1,240p' "$COLD_MAIN_OUTPUT" >&2
  fail "cold main setup fixture failed"
fi
[[ -x "$COLD_SDK/bin/cache/dart-sdk/bin/dart" ]] || {
  printf 'FAIL: cold main setup did not initialize Dart\n' >&2
  exit 1
}
[[ -x "$COLD_BIN/pluto" ]] || {
  printf 'FAIL: cold main setup did not compile the Pluto CLI\n' >&2
  exit 1
}
[[ "$(sed -n '1p' "$COLD_SDK/bootstrap-order")" == flutter-init ]] || {
  printf 'FAIL: cold main setup ran Dart before Flutter initialization\n' >&2
  exit 1
}
[[ "$(sed -n '2p' "$COLD_SDK/bootstrap-order")" == \
  dart-codegen:*/tools/codegen/generate_device_profiles.dart ]] || {
  printf 'FAIL: cold main setup did not run generated checks after initialization\n' >&2
  exit 1
}

ARTIFACTS="$TMP/artifacts"
mkdir -p "$ARTIFACTS"
printf 'test release engine\n' > "$ARTIFACTS/libflutter_engine.so"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ARTIFACTS/gen_snapshot"
chmod +x "$ARTIFACTS/gen_snapshot"
printf 'test ICU data\n' > "$ARTIFACTS/icudtl.dat"
printf 'test artifacts license\n' > "$ARTIFACTS/LICENSE.artifacts.md"
printf 'test license\n' > "$ARTIFACTS/LICENSE.embedder-archive.md"
printf 'test GTK license\n' > "$ARTIFACTS/LICENSE.flutter_gtk.md"
write_manifest "$ARTIFACTS"

validate_engine_artifacts "$ARTIFACTS" "$FLUTTER_VERSION" "$ENGINE_VERSION"
expect_failure "wrong artifact target" \
  validate_engine_artifacts \
    "$ARTIFACTS" "$FLUTTER_VERSION" "$ENGINE_VERSION" release linux-arm

printf 'corrupt\n' >> "$ARTIFACTS/icudtl.dat"
expect_failure "corrupt committed artifact" \
  validate_engine_artifacts "$ARTIFACTS" "$FLUTTER_VERSION" "$ENGINE_VERSION"
printf 'test ICU data\n' > "$ARTIFACTS/icudtl.dat"
write_manifest "$ARTIFACTS"

chmod -x "$ARTIFACTS/gen_snapshot"
expect_failure "non-executable gen_snapshot" \
  validate_engine_artifacts "$ARTIFACTS" "$FLUTTER_VERSION" "$ENGINE_VERSION"
chmod +x "$ARTIFACTS/gen_snapshot"

sed 's/^mode=release$/mode=debug/' "$ARTIFACTS/CHECKSUMS.txt" \
  > "$ARTIFACTS/CHECKSUMS.invalid"
mv "$ARTIFACTS/CHECKSUMS.invalid" "$ARTIFACTS/CHECKSUMS.txt"
expect_failure "wrong artifact runtime mode" \
  validate_engine_artifacts "$ARTIFACTS" "$FLUTTER_VERSION" "$ENGINE_VERSION"

# The fixture tests parser failures; this call protects the real committed
# runtime payload from partial updates or accidental binary changes in CI.
validate_engine_artifacts \
  "$ROOT/third_party/engine/$ENGINE_VERSION/linux-arm64-release" \
  "$FLUTTER_VERSION" \
  "$ENGINE_VERSION" \
  release
validate_engine_artifacts \
  "$ROOT/third_party/engine/$ENGINE_VERSION/linux-arm64-profile" \
  "$FLUTTER_VERSION" \
  "$ENGINE_VERSION" \
  profile
validate_engine_artifacts \
  "$ROOT/third_party/engine/$ENGINE_VERSION/linux-arm-release" \
  "$FLUTTER_VERSION" \
  "$ENGINE_VERSION" \
  release \
  linux-arm

PLUTO_ARM_SDK_PIN="$ROOT/tools/pluto/pins/arm-sdk.pin" \
  bash "$ROOT/tools/build/verify-arm-sdk.sh" --pin-only >/dev/null
cp "$ROOT/tools/pluto/pins/arm-sdk.pin" "$TMP/arm-sdk.pin"
sed 's/^sha256=.*/sha256=xyz/' "$TMP/arm-sdk.pin" > "$TMP/arm-sdk.invalid"
expect_failure "malformed ARM SDK content pin" \
  env PLUTO_ARM_SDK_PIN="$TMP/arm-sdk.invalid" \
  bash "$ROOT/tools/build/verify-arm-sdk.sh" --pin-only

printf 'setup validation tests passed\n'
