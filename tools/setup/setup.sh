#!/usr/bin/env bash
set -euo pipefail

readonly FLUTTER_REPOSITORY="https://github.com/flutter/flutter.git"

fail() {
  printf 'setup: %s\n' "$*" >&2
  exit 1
}

read_pin() {
  local path="$1"
  local label="$2"
  local value

  [[ -f "$path" ]] || fail "missing $label pin: $path"
  value="$(tr -d '[:space:]' < "$path")"
  [[ -n "$value" ]] || fail "$label pin is empty: $path"
  printf '%s\n' "$value"
}

sha256_file() {
  local path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    LC_ALL=C shasum -a 256 "$path" | awk '{print $1}'
  else
    fail "SHA-256 validation needs sha256sum or shasum"
  fi
}

validate_generated_digest() {
  local artifact="$1"
  local digest_pin="$2"
  local label="$3"
  local expected
  local actual

  [[ -f "$artifact" ]] || fail "missing generated $label: $artifact"
  expected="$(read_pin "$digest_pin" "$label SHA-256")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail \
    "$label SHA-256 pin must be 64 lowercase hexadecimal characters"
  actual="$(sha256_file "$artifact")"
  [[ "$actual" == "$expected" ]] || fail \
    "$label SHA-256 mismatch (expected $expected, got $actual)"
}

validate_engine_artifacts() {
  local artifact_dir="$1"
  local flutter_version="$2"
  local engine_version="$3"
  local expected_mode="${4:-release}"
  local expected_target="${5:-linux-arm64}"
  local manifest="$artifact_dir/CHECKSUMS.txt"
  local required
  local path
  local line
  local checksum
  local filename
  local actual
  local seen_names=""
  local manifest_schema=""
  local manifest_flutter=""
  local manifest_engine=""
  local manifest_target=""
  local manifest_mode=""
  local seen_lib=0
  local seen_snapshot=0
  local seen_icu=0
  local seen_artifacts_license=0
  local seen_license=0
  local seen_gtk_license=0
  local record_count=0

  [[ -d "$artifact_dir" ]] || fail \
    "committed $expected_target $expected_mode artifacts are missing: $artifact_dir"

  for required in \
    libflutter_engine.so \
    gen_snapshot \
    icudtl.dat \
    LICENSE.artifacts.md \
    LICENSE.embedder-archive.md \
    LICENSE.flutter_gtk.md \
    CHECKSUMS.txt; do
    path="$artifact_dir/$required"
    [[ -s "$path" ]] || fail "$expected_mode artifact is missing or empty: $path"
  done
  [[ -x "$artifact_dir/gen_snapshot" ]] || fail \
    "$expected_mode gen_snapshot is not executable: $artifact_dir/gen_snapshot"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^([[:xdigit:]]{64})[[:space:]]+\*?(.+)$ ]]; then
      checksum="${BASH_REMATCH[1]}"
      filename="${BASH_REMATCH[2]}"

      [[ "$filename" != */* && "$filename" != "." && "$filename" != ".." ]] || \
        fail "CHECKSUMS.txt contains a non-basename path: $filename"
      case $'\n'"$seen_names"$'\n' in
        *$'\n'"$filename"$'\n'*)
          fail "CHECKSUMS.txt contains a duplicate record: $filename"
          ;;
      esac
      [[ -f "$artifact_dir/$filename" ]] || fail \
        "CHECKSUMS.txt lists a missing file: $filename"

      actual="$(sha256_file "$artifact_dir/$filename")"
      checksum="$(printf '%s' "$checksum" | tr '[:upper:]' '[:lower:]')"
      [[ "$actual" == "$checksum" ]] || fail \
        "SHA-256 mismatch for $artifact_dir/$filename (expected $checksum, got $actual)"

      seen_names="${seen_names}${seen_names:+$'\n'}$filename"
      record_count=$((record_count + 1))
      case "$filename" in
        libflutter_engine.so) seen_lib=1 ;;
        gen_snapshot) seen_snapshot=1 ;;
        icudtl.dat) seen_icu=1 ;;
        LICENSE.artifacts.md) seen_artifacts_license=1 ;;
        LICENSE.embedder-archive.md) seen_license=1 ;;
        LICENSE.flutter_gtk.md) seen_gtk_license=1 ;;
      esac
      continue
    fi

    case "$line" in
      schema=*)
        [[ -z "$manifest_schema" ]] || fail "duplicate schema in CHECKSUMS.txt"
        manifest_schema="${line#schema=}"
        ;;
      flutter=*)
        [[ -z "$manifest_flutter" ]] || fail "duplicate flutter in CHECKSUMS.txt"
        manifest_flutter="${line#flutter=}"
        ;;
      engine=*)
        [[ -z "$manifest_engine" ]] || fail "duplicate engine in CHECKSUMS.txt"
        manifest_engine="${line#engine=}"
        ;;
      target=*)
        [[ -z "$manifest_target" ]] || fail "duplicate target in CHECKSUMS.txt"
        manifest_target="${line#target=}"
        ;;
      mode=*)
        [[ -z "$manifest_mode" ]] || fail "duplicate mode in CHECKSUMS.txt"
        manifest_mode="${line#mode=}"
        ;;
      engine_source=*|gen_snapshot_source=*|icu_source=*|gn_args=*)
        # Informational provenance fields are preserved but not interpreted here.
        ;;
      *)
        fail "unrecognised CHECKSUMS.txt line: $line"
        ;;
    esac
  done < "$manifest"

  [[ "$manifest_schema" == "1" ]] || fail \
    "artifact schema must be 1 (got ${manifest_schema:-missing})"
  [[ "$manifest_flutter" == "$flutter_version" ]] || fail \
    "artifact Flutter pin must be $flutter_version (got ${manifest_flutter:-missing})"
  [[ "$manifest_engine" == "$engine_version" ]] || fail \
    "artifact engine pin must be $engine_version (got ${manifest_engine:-missing})"
  [[ "$manifest_target" == "$expected_target" ]] || fail \
    "artifact target must be $expected_target (got ${manifest_target:-missing})"
  [[ "$manifest_mode" == "$expected_mode" ]] || fail \
    "artifact mode must be $expected_mode (got ${manifest_mode:-missing})"
  [[ "$record_count" -gt 0 ]] || fail "CHECKSUMS.txt has no SHA-256 records"
  [[ "$seen_lib" -eq 1 ]] || fail "CHECKSUMS.txt does not cover libflutter_engine.so"
  [[ "$seen_snapshot" -eq 1 ]] || fail "CHECKSUMS.txt does not cover gen_snapshot"
  [[ "$seen_icu" -eq 1 ]] || fail "CHECKSUMS.txt does not cover icudtl.dat"
  [[ "$seen_artifacts_license" -eq 1 ]] || fail \
    "CHECKSUMS.txt does not cover LICENSE.artifacts.md"
  [[ "$seen_license" -eq 1 ]] || fail \
    "CHECKSUMS.txt does not cover LICENSE.embedder-archive.md"
  [[ "$seen_gtk_license" -eq 1 ]] || fail \
    "CHECKSUMS.txt does not cover LICENSE.flutter_gtk.md"
}

detect_sdk_version() {
  local sdk_dir="$1"
  local detected=""
  local cached_version_file="$sdk_dir/bin/cache/flutter.version.json"

  if [[ -d "$sdk_dir/.git" ]] && command -v git >/dev/null 2>&1; then
    detected="$(git -C "$sdk_dir" describe --tags --exact-match HEAD 2>/dev/null || true)"
  fi
  if [[ -z "$detected" && -f "$cached_version_file" ]]; then
    detected="$(sed -n \
      's/.*"frameworkVersion":[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$cached_version_file" | head -n 1)"
  fi

  printf '%s\n' "$detected"
}

validate_sdk() {
  local sdk_dir="$1"
  local flutter_version="$2"
  local engine_version="$3"
  local actual_engine
  local actual_flutter

  [[ -d "$sdk_dir" ]] || fail "Flutter SDK directory does not exist: $sdk_dir"
  [[ -x "$sdk_dir/bin/flutter" ]] || fail \
    "Flutter executable is missing: $sdk_dir/bin/flutter"
  [[ -f "$sdk_dir/bin/internal/engine.version" ]] || fail \
    "Flutter engine pin is missing: $sdk_dir/bin/internal/engine.version"

  actual_engine="$(tr -d '[:space:]' < "$sdk_dir/bin/internal/engine.version")"
  [[ "$actual_engine" == "$engine_version" ]] || fail \
    "Flutter SDK engine is $actual_engine; this checkout requires $engine_version"

  actual_flutter="$(detect_sdk_version "$sdk_dir")"
  [[ -n "$actual_flutter" ]] || fail \
    "cannot establish Flutter SDK version at $sdk_dir (expected tag/cache version $flutter_version)"
  [[ "$actual_flutter" == "$flutter_version" ]] || fail \
    "Flutter SDK version is $actual_flutter; this checkout requires $flutter_version"
}

acquire_sdk() {
  local sdk_dir="$1"
  local flutter_version="$2"
  local repository="${3:-$FLUTTER_REPOSITORY}"
  local parent
  local staging

  command -v git >/dev/null 2>&1 || fail \
    "git is required to install the pinned Flutter SDK"
  [[ ! -e "$sdk_dir" ]] || fail \
    "refusing to replace existing path while installing Flutter: $sdk_dir"

  parent="$(dirname "$sdk_dir")"
  mkdir -p "$parent"
  staging="$(mktemp -d "$parent/.flutter-$flutter_version.XXXXXX")"

  printf 'Installing Flutter %s in %s\n' "$flutter_version" "$sdk_dir"
  if ! git clone --depth 1 --single-branch --branch "$flutter_version" \
    "$repository" "$staging/sdk"; then
    rm -rf "$staging"
    fail "could not clone Flutter tag $flutter_version"
  fi
  if [[ -e "$sdk_dir" ]]; then
    rm -rf "$staging"
    fail "Flutter SDK target appeared during installation: $sdk_dir"
  fi
  mv "$staging/sdk" "$sdk_dir"
  rmdir "$staging"
}

validate_initialized_flutter() {
  local version_json="$1"
  local flutter_version="$2"
  local engine_version="$3"
  local actual_flutter
  local actual_engine

  actual_flutter="$(printf '%s\n' "$version_json" | sed -n \
    's/.*"frameworkVersion":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  actual_engine="$(printf '%s\n' "$version_json" | sed -n \
    's/.*"engineRevision":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  [[ "$actual_flutter" == "$flutter_version" ]] || fail \
    "initialized Flutter reports ${actual_flutter:-unknown}; expected $flutter_version"
  [[ "$actual_engine" == "$engine_version" ]] || fail \
    "initialized Flutter reports engine ${actual_engine:-unknown}; expected $engine_version"
}

print_path_export() {
  local pluto_bin_dir="$1"
  local pub_cache="$2"
  local sdk_dir="$3"

  printf 'export PATH="%s:%s/bin:%s/bin:$PATH"\n' \
    "$pluto_bin_dir" "$pub_cache" "$sdk_dir"
}

usage() {
  cat <<'EOF'
Usage: tools/setup/setup.sh [--verify]

Without arguments, validate the committed AArch64 release/profile and ARMv7
release AOT runtimes plus the authoritative ARM compiler-SDK pin; install the
pinned Flutter SDK when absent, then bootstrap Dart/Flutter dependencies.

  --verify  Validate existing SDK and committed artifacts without downloads.

Set PLUTO_SDK to use or install the pinned SDK at a non-default path. Set
PLUTO_BIN_DIR to install the native `pluto` executable elsewhere.
EOF
}

main() {
  local root
  local flutter_version
  local engine_version
  local sdk_dir
  local release_artifact_dir
  local profile_artifact_dir
  local arm_release_artifact_dir
  local arm_sdk_pin
  local pub_cache
  local pluto_bin_dir
  local pluto_executable
  local flutter_version_json
  local verify_only=0

  [[ "$#" -le 1 ]] || fail "expected at most one argument"
  case "${1:-}" in
    "") ;;
    --verify) verify_only=1 ;;
    -h|--help) usage; return 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac

  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  flutter_version="$(read_pin "$root/tools/pluto/pins/flutter.version" "Flutter")"
  engine_version="$(read_pin "$root/tools/pluto/pins/engine.version" "engine")"
  sdk_dir="${PLUTO_SDK:-$HOME/.pluto/sdk/$flutter_version}"
  release_artifact_dir="$root/third_party/engine/$engine_version/linux-arm64-release"
  profile_artifact_dir="$root/third_party/engine/$engine_version/linux-arm64-profile"
  arm_release_artifact_dir="$root/third_party/engine/$engine_version/linux-arm-release"
  arm_sdk_pin="$root/tools/pluto/pins/arm-sdk.pin"

  printf 'Validating committed release runtime: %s\n' "$release_artifact_dir"
  validate_engine_artifacts \
    "$release_artifact_dir" "$flutter_version" "$engine_version" release
  printf 'Validating committed profile runtime: %s\n' "$profile_artifact_dir"
  validate_engine_artifacts \
    "$profile_artifact_dir" "$flutter_version" "$engine_version" profile
  printf 'Validating committed ARMv7 release runtime: %s\n' \
    "$arm_release_artifact_dir"
  validate_engine_artifacts \
    "$arm_release_artifact_dir" "$flutter_version" "$engine_version" \
    release linux-arm
  printf 'Validating authoritative ARM compiler SDK pin: %s\n' "$arm_sdk_pin"
  PLUTO_ARM_SDK_PIN="$arm_sdk_pin" \
    bash "$root/tools/build/verify-arm-sdk.sh" --pin-only
  if [[ ! -e "$sdk_dir" ]]; then
    [[ "$verify_only" -eq 0 ]] || fail \
      "pinned Flutter SDK is absent: $sdk_dir (run setup without --verify to install it)"
    acquire_sdk "$sdk_dir" "$flutter_version"
  fi
  validate_sdk "$sdk_dir" "$flutter_version" "$engine_version"
  sdk_dir="$(cd "$sdk_dir" && pwd)"

  printf 'Validating generated device profiles\n'
  env HOME="${TMPDIR:-/tmp}" DART_DISABLE_ANALYTICS=1 \
    "$sdk_dir/bin/cache/dart-sdk/bin/dart" \
    "$root/tools/codegen/generate_device_profiles.dart" --check
  printf 'Validating generated RM1 RGB565 optical LUT\n'
  env HOME="${TMPDIR:-/tmp}" DART_DISABLE_ANALYTICS=1 \
    "$sdk_dir/bin/cache/dart-sdk/bin/dart" \
    "$root/tools/codegen/generate_rm1_rgb565_optical_lut.dart" --check
  validate_generated_digest \
    "$root/embedder/src/generated/rm1_rgb565_optical_lut.h" \
    "$root/tools/codegen/rm1_rgb565_optical_lut.sha256" \
    "RM1 RGB565 optical LUT"

  if [[ "$verify_only" -eq 1 ]]; then
    printf 'Setup verified: Flutter %s, engine %s, pinned ARM SDK, linux-arm64 and linux-arm AOT artifacts.\n' \
      "$flutter_version" "$engine_version"
    return 0
  fi

  export PATH="$sdk_dir/bin:$sdk_dir/bin/cache/dart-sdk/bin:$PATH"
  pub_cache="${PUB_CACHE:-$HOME/.pub-cache}"
  export PATH="$pub_cache/bin:$PATH"

  printf 'Initializing Flutter SDK: %s\n' "$sdk_dir"
  flutter_version_json="$("$sdk_dir/bin/flutter" --version --machine)"
  validate_initialized_flutter "$flutter_version_json" "$flutter_version" "$engine_version"
  [[ -x "$sdk_dir/bin/cache/dart-sdk/bin/dart" ]] || fail \
    "Flutter did not install its pinned Dart SDK"

  "$sdk_dir/bin/cache/dart-sdk/bin/dart" pub global activate melos '^7.0.0'
  [[ -x "$pub_cache/bin/melos" ]] || fail \
    "melos activation did not create $pub_cache/bin/melos"

  (
    cd "$root"
    "$pub_cache/bin/melos" bootstrap
  )
  (
    cd "$root/tools/pluto"
    "$sdk_dir/bin/flutter" pub get
  )
  pluto_bin_dir="${PLUTO_BIN_DIR:-$HOME/.pluto/bin}"
  pluto_executable="$pluto_bin_dir/pluto"
  mkdir -p "$pluto_bin_dir"
  rm -f "$pluto_executable.tmp"
  if ! (
    cd "$root/tools/pluto"
    "$sdk_dir/bin/cache/dart-sdk/bin/dart" compile exe \
      bin/pluto.dart \
      -o "$pluto_executable.tmp"
  ); then
    rm -f "$pluto_executable.tmp"
    fail "could not compile the Pluto CLI"
  fi
  chmod 0755 "$pluto_executable.tmp"
  mv "$pluto_executable.tmp" "$pluto_executable"

  printf '\nSetup complete. Add Pluto, Melos, and the pinned Flutter SDK to your shell PATH:\n'
  print_path_export "$pluto_bin_dir" "$pub_cache" "$sdk_dir"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
