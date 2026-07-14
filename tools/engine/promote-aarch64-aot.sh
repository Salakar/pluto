#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLUTTER_VERSION="$(tr -d '[:space:]' < "$ROOT/tools/pluto/pins/flutter.version")"
ENGINE_HASH="$(tr -d '[:space:]' < "$ROOT/tools/pluto/pins/engine.version")"

PINNED_ENGINE_HASH="a10d8ac38de835021c8d2f920dbf50a920ccc030"
RELEASE_ENGINE_SHA256="93c5a21d58be76edf42d9746c32c8c076a76a552e667af7c953e3a14bc4c68a5"
RELEASE_GEN_SNAPSHOT_SHA256="d31a40644bba9bcd6885936b293bad40fd12e1432b3a5ca4e55f3a0ab0fa0866"
PROFILE_ENGINE_SHA256="84bb5839469ec3f6de8132a57303d5f8e8749b0d456e309008fee60314679b3c"
PROFILE_GEN_SNAPSHOT_SHA256="f11c7b43a0a8f9de42eab9452f6d0a6ce8e9ebbbb81c411463f653bfd4053f07"
ICU_SHA256="998367809a821d595928089c197b3f7959f0420f81f79d4d0daee53378492ed5"
ARTIFACTS_LICENSE_SHA256="d34a56164ede2c0ee793e6fe6d20e2b53fc5295e304d1ce636ef8c31a54e634b"
EMBEDDER_LICENSE_SHA256="432e8f190ea0edb09db8dde057532848d848159b98bac649db353c102fb70e23"
GTK_LICENSE_SHA256="c60421766d08e9bb85083be921a0e298d0a367d71bc1ad89f41b2b27da367da7"

die() {
  echo "error: $*" >&2
  exit 2
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    LC_ALL=C shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify_file() {
  local path="$1"
  local expected="$2"
  [[ -f "$path" ]] || die "missing build artifact: $path"
  local actual
  actual="$(sha256_file "$path")"
  [[ "$actual" == "$expected" ]] ||
    die "checksum mismatch for $path: expected $expected, got $actual"
}

[[ "$ENGINE_HASH" == "$PINNED_ENGINE_HASH" ]] ||
  die "prebuilt checksums have not been reviewed for engine $ENGINE_HASH"

promote_mode() {
  local mode="$1"
  local engine_sha256="$2"
  local gen_snapshot_sha256="$3"
  local source="$ROOT/.pluto-cache/engine/$ENGINE_HASH/linux-arm64-$mode"
  local destination="$ROOT/third_party/engine/$ENGINE_HASH/linux-arm64-$mode"

  verify_file "$source/libflutter_engine.so" "$engine_sha256"
  verify_file "$source/gen_snapshot" "$gen_snapshot_sha256"
  verify_file "$source/icudtl.dat" "$ICU_SHA256"
  verify_file "$source/LICENSE.artifacts.md" "$ARTIFACTS_LICENSE_SHA256"
  verify_file "$source/LICENSE.embedder-archive.md" "$EMBEDDER_LICENSE_SHA256"
  verify_file "$source/LICENSE.flutter_gtk.md" "$GTK_LICENSE_SHA256"
  cmp -s \
    "$source/flutter_embedder.h" \
    "$ROOT/embedder/third_party/flutter/embedder.h" ||
    die "built $mode flutter_embedder.h differs from the tracked embedder ABI header"

  install -d "$destination"
  install -m 0755 "$source/libflutter_engine.so" "$destination/libflutter_engine.so"
  install -m 0755 "$source/gen_snapshot" "$destination/gen_snapshot"
  install -m 0644 "$source/icudtl.dat" "$destination/icudtl.dat"
  install -m 0644 "$source/LICENSE.artifacts.md" "$destination/LICENSE.artifacts.md"
  install -m 0644 \
    "$source/LICENSE.embedder-archive.md" \
    "$destination/LICENSE.embedder-archive.md"
  install -m 0644 "$source/LICENSE.flutter_gtk.md" "$destination/LICENSE.flutter_gtk.md"

  cat > "$destination/CHECKSUMS.txt" <<EOF
schema=1
flutter=$FLUTTER_VERSION
engine=$ENGINE_HASH
target=linux-arm64
mode=$mode
engine_source=https://github.com/flutter/flutter/tree/$ENGINE_HASH/engine
gen_snapshot_source=https://storage.googleapis.com/flutter_infra_release/flutter/$ENGINE_HASH/linux-arm64-$mode/linux-arm64-flutter-gtk.zip
icu_source=https://storage.googleapis.com/flutter_infra_release/flutter/$ENGINE_HASH/linux-arm64/artifacts.zip
gn_args=--runtime-mode=$mode --target-os=linux --linux-cpu=arm64 --prebuilt-dart-sdk --no-lto --no-rbe --no-goma --embedder-for-target --disable-desktop-embeddings --no-build-engine-artifacts --no-build-glfw-shell --no-build-embedder-examples --no-enable-unittests

$ARTIFACTS_LICENSE_SHA256  LICENSE.artifacts.md
$EMBEDDER_LICENSE_SHA256  LICENSE.embedder-archive.md
$GTK_LICENSE_SHA256  LICENSE.flutter_gtk.md
$gen_snapshot_sha256  gen_snapshot
$ICU_SHA256  icudtl.dat
$engine_sha256  libflutter_engine.so
EOF

  echo "updated committed AArch64 $mode artifacts:"
  echo "  $destination"
}

promote_mode release "$RELEASE_ENGINE_SHA256" "$RELEASE_GEN_SNAPSHOT_SHA256"
promote_mode profile "$PROFILE_ENGINE_SHA256" "$PROFILE_GEN_SNAPSHOT_SHA256"
echo "review and commit both mode payloads and CHECKSUMS.txt files together"
