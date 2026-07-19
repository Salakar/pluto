#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_VERSION="$(tr -d '[:space:]' < "$ROOT/tools/pluto/pins/flutter.version")"
SDK="${PLUTO_SDK:-$HOME/.pluto/sdk/$FLUTTER_VERSION}"
DART="$SDK/bin/cache/dart-sdk/bin/dart"
CLI="$ROOT/tools/pluto/bin/pluto.dart"
PACKAGES="$ROOT/tools/pluto/.dart_tool/package_config.json"
APP="$ROOT/apps/examples/counter"
OUTPUT="$APP/build/pluto/aot-smoke"

die() {
  echo "aot-smoke: $*" >&2
  exit 2
}

[[ -x "$DART" ]] || die "missing pinned Dart SDK; run tools/setup/setup.sh"
[[ -f "$PACKAGES" ]] || die "CLI dependencies are missing; run tools/setup/setup.sh"
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
if [[ "$HOST_OS" != Linux ||
      ( "$HOST_ARCH" != aarch64 && "$HOST_ARCH" != arm64 ) ]]; then
  command -v docker >/dev/null 2>&1 ||
    die "Docker is required on non-Linux/AArch64 hosts"
fi

PLUTO_SDK="$SDK" "$ROOT/tools/setup/setup.sh" --verify >/dev/null

run_pluto() {
  (
    cd "$APP"
    "$DART" --packages="$PACKAGES" "$CLI" --flutter-sdk="$SDK" "$@"
  )
}

verify_layout() {
  local mode="$1"
  local layout="$OUTPUT/$mode"
  local app_elf="$layout/bundle/lib/app.so"

  [[ -s "$app_elf" ]] || die "$mode did not produce bundle/lib/app.so"
  [[ ! -e "$layout/bundle/flutter_assets/kernel_blob.bin" ]] ||
    die "$mode AOT layout contains kernel_blob.bin"
  [[ ! -e "$layout/bundle/flutter_assets/.last_build_id" ]] ||
    die "$mode AOT layout contains Flutter build-only metadata"
  file "$app_elf" | grep -q "ARM aarch64" ||
    die "$mode app.so is not AArch64"

  if [[ "$mode" == release ]]; then
    strings "$app_elf" |
      grep -E "product .* dedup_instructions .* arm64 linux" >/dev/null ||
      die "release app.so is not a product/deduplicated snapshot"
  else
    strings "$app_elf" |
      grep -E "release .* no-dedup_instructions .* arm64 linux" >/dev/null ||
      die "profile app.so does not have the profile snapshot feature set"
  fi

  run_pluto build package \
    "--$mode" \
    --no-live \
    --from-layout="$layout" \
    --compression=none \
    --output="$OUTPUT/counter-$mode.plap" >/dev/null
  LC_ALL=C tar -xOf "$OUTPUT/counter-$mode.plap" \
    targets/linux-arm64/build-metadata.json |
    grep "\"buildMode\": \"$mode\"" >/dev/null ||
    die "$mode package metadata is incorrect"
}

rm -rf "$OUTPUT"
run_pluto build app --release --output="$OUTPUT/release"
run_pluto build app --profile --output="$OUTPUT/profile"
verify_layout release
verify_layout profile

echo "AOT smoke passed: release and profile are pin-verified AArch64 app ELFs"
