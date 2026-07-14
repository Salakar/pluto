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

SDK_SOURCE="$TMP/flutter-source"
mkdir -p "$SDK_SOURCE/bin/internal"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SDK_SOURCE/bin/flutter"
chmod +x "$SDK_SOURCE/bin/flutter"
printf '%s\n' "$ENGINE_VERSION" > "$SDK_SOURCE/bin/internal/engine.version"
git -C "$SDK_SOURCE" init -q
git -C "$SDK_SOURCE" config user.email setup-test@pluto.invalid
git -C "$SDK_SOURCE" config user.name "Pluto setup test"
git -C "$SDK_SOURCE" add bin
git -C "$SDK_SOURCE" commit -qm "test Flutter SDK"
git -C "$SDK_SOURCE" tag "$FLUTTER_VERSION"

ACQUIRED_SDK="$TMP/acquired-sdk"
acquire_sdk "$ACQUIRED_SDK" "$FLUTTER_VERSION" "$SDK_SOURCE" >/dev/null 2>&1
validate_sdk "$ACQUIRED_SDK" "$FLUTTER_VERSION" "$ENGINE_VERSION"

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

printf 'setup validation tests passed\n'
