#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PAYLOAD="$ROOT/build/pluto-payload"
FLUTTER_VERSION="$(tr -d '[:space:]' < "$ROOT/tools/pluto/pins/flutter.version")"
ENGINE_COMMIT="$(tr -d '[:space:]' < "$ROOT/tools/pluto/pins/engine.version")"
SDK="${PLUTO_SDK:-$HOME/.pluto/sdk/$FLUTTER_VERSION}"
DART="$SDK/bin/cache/dart-sdk/bin/dart"
CLI="$ROOT/tools/pluto/bin/pluto.dart"
PACKAGES="$ROOT/tools/pluto/.dart_tool/package_config.json"
EMBEDDER=""
CONTROL_CLIENT="$ROOT/embedder/build/device-arm64/pluto-controlctl"
DEVICE_PROFILES="$ROOT/tools/device/generated/device-profiles.sh"
ENGINE_ROOT="$ROOT/third_party/engine/$ENGINE_COMMIT"
TARGET_PLATFORM=linux-arm64
TARGET_GLIBC_CEILING=2.39
SNAPSHOT_ARCH=arm64
DRY_RUN=0
SELECTED_APPS=()
SELECTED_APP_COUNT=0

DEVICE_SCRIPTS=(
  pluto-session.sh
  pluto-boot-confirm.sh
  pluto-power-key-watch.sh
  pluto-boot-install.sh
  pluto-app-control.sh
  pluto-install-transaction.sh
  pluto-uninstall.sh
  pluto-xochitl-guard.sh
)

usage() {
  cat <<'EOF'
Usage: tools/build/assemble-device-payload.sh [options]

Assemble the release-AOT launcher and selected apps into the canonical
build/pluto-payload directory. No app is selected implicitly besides the
launcher; debug/JIT payloads are never copied.

Options:
  --app NAME       include one repo app; repeat for more apps
                   (counter, motion_lab, ink_lab, validation_lab, codex, or an
                   apps/... repo-relative directory)
  --examples       include counter, motion_lab, and ink_lab
  --standard       include every standard app: the examples, Validation Lab,
                   and Codex (the launcher is always included)
  --target-platform TARGET
                   build this low-level direct backend for linux-arm64
                   (default); model-specific routing belongs to the CLI
  --embedder PATH  use an alternate target-compatible pluto-embedder
  --dry-run        print the complete assembly plan without changing files
  -h, --help       show this help

Examples:
  melos run build:device-payload -- --standard
  melos run build:device-payload -- --app counter --app validation_lab
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

print_command() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
}

run() {
  print_command "$@"
  if ((DRY_RUN == 0)); then
    "$@"
  fi
}

run_in_directory() {
  local directory="$1"
  shift
  printf '+ cd %q &&' "$directory"
  printf ' %q' "$@"
  printf '\n'
  if ((DRY_RUN == 0)); then
    (
      cd "$directory"
      "$@"
    )
  fi
}

add_selected_app() {
  local selector="$1"
  local index
  [[ -n "$selector" ]] || die "--app requires a non-empty value"
  for ((index = 0; index < SELECTED_APP_COUNT; index += 1)); do
    [[ "${SELECTED_APPS[$index]}" == "$selector" ]] && return 0
  done
  SELECTED_APPS[$SELECTED_APP_COUNT]="$selector"
  SELECTED_APP_COUNT=$((SELECTED_APP_COUNT + 1))
}

while (($# > 0)); do
  case "$1" in
    --app)
      shift
      (($# > 0)) || die "--app requires a value"
      add_selected_app "$1"
      ;;
    --app=*) add_selected_app "${1#*=}" ;;
    --examples)
      add_selected_app counter
      add_selected_app motion_lab
      add_selected_app ink_lab
      ;;
    --standard)
      add_selected_app counter
      add_selected_app motion_lab
      add_selected_app ink_lab
      add_selected_app validation_lab
      add_selected_app codex
      ;;
    --embedder)
      shift
      (($# > 0)) || die "--embedder requires a value"
      EMBEDDER="$1"
      ;;
    --embedder=*) EMBEDDER="${1#*=}" ;;
    --target-platform)
      shift
      (($# > 0)) || die "--target-platform requires a value"
      TARGET_PLATFORM="$1"
      ;;
    --target-platform=*) TARGET_PLATFORM="${1#*=}" ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

case "$TARGET_PLATFORM" in
  linux-arm64)
    [[ -n "$EMBEDDER" ]] || \
      EMBEDDER="$ROOT/embedder/build/device-arm64/pluto-embedder"
    ;;
  linux-arm)
    die "linux-arm is not supported by this direct-backend assembler; the normal Pluto workflow must dispatch the cooperative backend"
    ;;
  *) die "unsupported target platform: $TARGET_PLATFORM" ;;
esac

resolve_app_directory() {
  local selector="${1%/}"
  local relative
  case "$selector" in
    counter | motion_lab | ink_lab) relative="apps/examples/$selector" ;;
    validation_lab) relative="apps/validation_lab" ;;
    apps/*) relative="$selector" ;;
    *..* | /* | */*) die "app must be a safe apps/... repo path: $selector" ;;
    *)
      if [[ -d "$ROOT/apps/$selector" ]]; then
        relative="apps/$selector"
      elif [[ -d "$ROOT/apps/examples/$selector" ]]; then
        relative="apps/examples/$selector"
      else
        die "unknown repo app: $selector"
      fi
      ;;
  esac
  [[ "$relative" != *..* ]] || die "app path cannot contain '..': $relative"
  [[ -f "$ROOT/$relative/pubspec.yaml" ]] ||
    die "app has no pubspec.yaml: $relative"
  [[ -f "$ROOT/$relative/pluto.yaml" ]] ||
    die "app has no pluto.yaml: $relative"
  printf '%s\n' "$ROOT/$relative"
}

manifest_app_id() {
  local manifest="$1"
  local app_id
  app_id="$(awk '$1 == "id:" {print $2; exit}' "$manifest")"
  [[ "$app_id" =~ ^[a-z0-9]+([._-][a-z0-9]+)+$ ]] ||
    die "invalid app id in $manifest: $app_id"
  printf '%s\n' "$app_id"
}

require_target_elf() {
  local elf="$1"
  local description
  [[ -s "$elf" ]] || die "missing ELF: $elf"
  description="$(file "$elf")"
  [[ "$description" == *"ELF 64-bit"* && "$description" == *"ARM aarch64"* ]] ||
    die "expected ELF64 AArch64 ELF: $description"
}

verify_release_layout() {
  local layout="$1"
  local expected_id="$2"
  local metadata="$layout/build-metadata.json"
  local manifest="$layout/manifest.json"
  local app_elf="$layout/bundle/lib/app.so"
  local kernel

  [[ -s "$metadata" ]] || die "release layout has no build-metadata.json: $layout"
  [[ -s "$manifest" ]] || die "release layout has no manifest.json: $layout"
  [[ -d "$layout/bundle/flutter_assets" ]] ||
    die "release layout has no bundle/flutter_assets: $layout"
  [[ -s "$layout/bundle/icudtl.dat" ]] ||
    die "release layout has no bundle/icudtl.dat: $layout"
  require_target_elf "$app_elf"

  grep -Eq '"buildMode"[[:space:]]*:[[:space:]]*"release"' "$metadata" ||
    die "layout metadata is not release: $metadata"
  grep -Eq '"engineFlavor"[[:space:]]*:[[:space:]]*"release"' "$metadata" ||
    die "layout metadata does not require the release engine: $metadata"
  grep -Eq "\"target\"[[:space:]]*:[[:space:]]*\"$TARGET_PLATFORM\"" "$metadata" ||
    die "layout metadata target is not $TARGET_PLATFORM: $metadata"
  grep -Eq "\"flutterVersion\"[[:space:]]*:[[:space:]]*\"$FLUTTER_VERSION\"" "$metadata" ||
    die "layout metadata does not match Flutter $FLUTTER_VERSION: $metadata"
  grep -Eq "\"engineCommit\"[[:space:]]*:[[:space:]]*\"$ENGINE_COMMIT\"" "$metadata" ||
    die "layout metadata does not match engine $ENGINE_COMMIT: $metadata"
  grep -Eq '"runtime"[[:space:]]*:[[:space:]]*\{[[:space:]]*"type"[[:space:]]*:[[:space:]]*"flutter-aot"' "$manifest" ||
    die "manifest runtime is not flutter-aot: $manifest"
  grep -Eq "\"id\"[[:space:]]*:[[:space:]]*\"$expected_id\"" "$manifest" ||
    die "manifest id does not match $expected_id: $manifest"
  strings "$app_elf" |
    grep -E "product .* dedup_instructions .* $SNAPSHOT_ARCH linux" >/dev/null ||
    die "app.so is not a release/product AOT snapshot: $app_elf"

  kernel="$(find "$layout" -type f -name kernel_blob.bin -print -quit)"
  [[ -z "$kernel" ]] || die "release payload contains forbidden JIT kernel: $kernel"
  [[ ! -e "$layout/bundle/flutter_assets/.last_build_id" ]] ||
    die "release payload contains Flutter build-only metadata: $layout"
}

build_release_layout() {
  local project="$1"
  local destination="$2"
  local app_id="$3"
  run_in_directory "$project" \
    "$DART" --packages="$PACKAGES" "$CLI" \
    --flutter-sdk="$SDK" build app --release \
    --target-platform="$TARGET_PLATFORM" --output="$destination"
  if ((DRY_RUN == 0)); then
    verify_release_layout "$destination" "$app_id"
  fi
}

RELEASE_ENGINE="$ENGINE_ROOT/$TARGET_PLATFORM-release/libflutter_engine.so"
PROFILE_ENGINE="$ENGINE_ROOT/$TARGET_PLATFORM-profile/libflutter_engine.so"
LAUNCHER_PROJECT="$ROOT/apps/launcher"
LAUNCHER_ID="$(manifest_app_id "$LAUNCHER_PROJECT/pluto.yaml")"
[[ "$LAUNCHER_ID" == dev.pluto.launcher ]] ||
  die "launcher manifest id must be dev.pluto.launcher, found $LAUNCHER_ID"

APP_PROJECTS=()
APP_IDS=()
APP_COUNT=0
for ((selection_index = 0; selection_index < SELECTED_APP_COUNT; selection_index += 1)); do
  selector="${SELECTED_APPS[$selection_index]}"
  project="$(resolve_app_directory "$selector")"
  app_id="$(manifest_app_id "$project/pluto.yaml")"
  [[ "$app_id" != "$LAUNCHER_ID" ]] ||
    die "the launcher is always included; do not select it with --app"
  for ((existing_index = 0; existing_index < APP_COUNT; existing_index += 1)); do
    [[ "${APP_IDS[$existing_index]}" != "$app_id" ]] ||
      die "duplicate app id selected: $app_id"
  done
  APP_PROJECTS[$APP_COUNT]="$project"
  APP_IDS[$APP_COUNT]="$app_id"
  APP_COUNT=$((APP_COUNT + 1))
done

if ((DRY_RUN == 0)); then
  for tool in file find grep install strings; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
  done
  [[ -x "$DART" ]] || die "missing pinned Dart SDK; run tools/setup/setup.sh"
  [[ -f "$PACKAGES" ]] || die "CLI dependencies are missing; run tools/setup/setup.sh"
  [[ -f "$CLI" ]] || die "missing Pluto CLI source: $CLI"
  [[ -s "$EMBEDDER" ]] ||
    die "missing device embedder; run melos run build:embedder:device"
  [[ -s "$CONTROL_CLIENT" ]] ||
    die "missing device control client; run melos run build:embedder:device"
  [[ -s "$DEVICE_PROFILES" ]] ||
    die "missing generated device profiles: $DEVICE_PROFILES"
fi

# Setup verification is the authoritative pin/checksum gate for both committed
# engine flavors. It is read-only and avoids duplicating that manifest parser.
run env PLUTO_SDK="$SDK" "$ROOT/tools/setup/setup.sh" --verify

run bash "$ROOT/tools/build/verify-device-elf.sh" \
  "$EMBEDDER" "$TARGET_GLIBC_CEILING" "$TARGET_PLATFORM"
run bash "$ROOT/tools/build/verify-device-elf.sh" \
  "$CONTROL_CLIENT" "$TARGET_GLIBC_CEILING" "$TARGET_PLATFORM"
run bash "$ROOT/tools/build/verify-device-elf.sh" \
  "$RELEASE_ENGINE" "$TARGET_GLIBC_CEILING" "$TARGET_PLATFORM"
run bash "$ROOT/tools/build/verify-device-elf.sh" \
  "$PROFILE_ENGINE" "$TARGET_GLIBC_CEILING" "$TARGET_PLATFORM"

run rm -rf "$PAYLOAD"
PAYLOAD_DIRECTORIES=(
  "$PAYLOAD"
  "$PAYLOAD/bin"
  "$PAYLOAD/engine/release"
  "$PAYLOAD/engine/profile"
  "$PAYLOAD/apps"
  "$PAYLOAD/share"
)
run install -d "${PAYLOAD_DIRECTORIES[@]}"
run install -m 0755 "$EMBEDDER" "$PAYLOAD/pluto-embedder"
run install -m 0755 "$CONTROL_CLIENT" "$PAYLOAD/bin/pluto-controlctl"
run install -m 0644 "$DEVICE_PROFILES" \
  "$PAYLOAD/share/device-profiles.sh"
run install -m 0644 "$RELEASE_ENGINE" \
  "$PAYLOAD/engine/release/libflutter_engine.so"
run install -m 0644 "$PROFILE_ENGINE" \
  "$PAYLOAD/engine/profile/libflutter_engine.so"

for script in "${DEVICE_SCRIPTS[@]}"; do
  source_script="$ROOT/tools/device/$script"
  if ((DRY_RUN == 0)); then
    [[ -f "$source_script" ]] || die "missing device script: $source_script"
  fi
  run install -m 0755 "$source_script" "$PAYLOAD/$script"
done

build_release_layout "$LAUNCHER_PROJECT" "$PAYLOAD/launcher" "$LAUNCHER_ID"
for ((index = 0; index < APP_COUNT; index += 1)); do
  build_release_layout \
    "${APP_PROJECTS[$index]}" \
    "$PAYLOAD/apps/${APP_IDS[$index]}" \
    "${APP_IDS[$index]}"
done

if ((DRY_RUN == 0)); then
  forbidden_kernel="$(find "$PAYLOAD" -type f -name kernel_blob.bin -print -quit)"
  [[ -z "$forbidden_kernel" ]] ||
    die "assembled payload contains forbidden JIT kernel: $forbidden_kernel"
  [[ ! -d "$PAYLOAD/engine/debug" ]] ||
    die "assembled release payload unexpectedly contains a debug engine"
  echo "Assembled release payload: $PAYLOAD"
  if ((APP_COUNT > 0)); then
    echo "Target: $TARGET_PLATFORM; apps: launcher ${APP_IDS[*]}"
  else
    echo "Target: $TARGET_PLATFORM; apps: launcher"
  fi
fi

echo "Direct-backend handoff: pluto provision --payload-dir $PAYLOAD"
