#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLUTTER_VERSION="$(tr -d '[:space:]' < "$ROOT/tools/pluto/pins/flutter.version")"
ENGINE_HASH="$(tr -d '[:space:]' < "$ROOT/tools/pluto/pins/engine.version")"
SDK="${PLUTO_SDK:-$HOME/.pluto/sdk/$FLUTTER_VERSION}"
IMAGE="${PLUTO_ENGINE_BUILDER_IMAGE:-pluto-flutter-engine-builder:aarch64}"
VOLUME="${PLUTO_ENGINE_BUILD_VOLUME:-pluto-flutter-engine-${ENGINE_HASH:0:12}}"
JOBS="${PLUTO_ENGINE_BUILD_JOBS:-12}"
RELEASE_TARGET_DIR="pluto_linux_release_arm64"
PROFILE_TARGET_DIR="pluto_linux_profile_arm64"

# These hashes are intentionally tied to Flutter 3.44.4 / engine a10d8ac. A
# pin update must review the upstream artifacts and replace them together.
PINNED_ENGINE_HASH="a10d8ac38de835021c8d2f920dbf50a920ccc030"
RELEASE_GTK_SHA256="810a50868ced8763cb9e3070bf02795165c23de663886519d9b12cb34a722f51"
RELEASE_GEN_SNAPSHOT_SHA256="d31a40644bba9bcd6885936b293bad40fd12e1432b3a5ca4e55f3a0ab0fa0866"
RELEASE_ENGINE_SHA256="93c5a21d58be76edf42d9746c32c8c076a76a552e667af7c953e3a14bc4c68a5"
PROFILE_GTK_SHA256="00f02518aa710f356a04b1654a5a9543119dc84d1bb4047ab4e0828cbbd3ddc7"
PROFILE_GEN_SNAPSHOT_SHA256="f11c7b43a0a8f9de42eab9452f6d0a6ce8e9ebbbb81c411463f653bfd4053f07"
PROFILE_ENGINE_SHA256="84bb5839469ec3f6de8132a57303d5f8e8749b0d456e309008fee60314679b3c"
DEBUG_ARTIFACTS_SHA256="32394fd03cd51798eb6ae67524ddafa3ff110508b4f2c0bffdb8bffa633559be"

die() {
  echo "error: $*" >&2
  exit 2
}

command -v docker >/dev/null 2>&1 || die "docker is required"
[[ -d "$SDK/.git" ]] || die "missing pinned Flutter SDK checkout: $SDK"
[[ -f "$SDK/bin/internal/engine.version" ]] || die "SDK has no engine.version: $SDK"

SDK_ENGINE_HASH="$(tr -d '[:space:]' < "$SDK/bin/internal/engine.version")"
[[ "$SDK_ENGINE_HASH" == "$ENGINE_HASH" ]] ||
  die "SDK engine $SDK_ENGINE_HASH does not match project pin $ENGINE_HASH"
[[ "$ENGINE_HASH" == "$PINNED_ENGINE_HASH" ]] ||
  die "artifact checksums have not been reviewed for engine $ENGINE_HASH"
git -C "$SDK" cat-file -e "$ENGINE_HASH^{commit}" 2>/dev/null ||
  die "SDK Git checkout does not contain engine commit $ENGINE_HASH"

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
export \
  DEBUG_ARTIFACTS_SHA256 \
  ENGINE_HASH \
  FLUTTER_VERSION \
  HOST_GID \
  HOST_UID \
  JOBS \
  PROFILE_ENGINE_SHA256 \
  PROFILE_GEN_SNAPSHOT_SHA256 \
  PROFILE_GTK_SHA256 \
  PROFILE_TARGET_DIR \
  RELEASE_ENGINE_SHA256 \
  RELEASE_GEN_SNAPSHOT_SHA256 \
  RELEASE_GTK_SHA256 \
  RELEASE_TARGET_DIR

echo "building AArch64 release/profile AOT embedders for Flutter $FLUTTER_VERSION ($ENGINE_HASH)"
docker build \
  --platform linux/arm64 \
  -f "$ROOT/tools/engine/Dockerfile.aarch64" \
  -t "$IMAGE" \
  "$ROOT/tools/engine"

docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME" >/dev/null

docker run --rm --platform linux/arm64 \
  -e DEBUG_ARTIFACTS_SHA256 \
  -e ENGINE_HASH \
  -e FLUTTER_VERSION \
  -e HOST_GID \
  -e HOST_UID \
  -e JOBS \
  -e PROFILE_ENGINE_SHA256 \
  -e PROFILE_GEN_SNAPSHOT_SHA256 \
  -e PROFILE_GTK_SHA256 \
  -e PROFILE_TARGET_DIR \
  -e RELEASE_ENGINE_SHA256 \
  -e RELEASE_GEN_SNAPSHOT_SHA256 \
  -e RELEASE_GTK_SHA256 \
  -e RELEASE_TARGET_DIR \
  -v "$VOLUME:/build" \
  -v "$SDK:/sdk:ro" \
  -v "$ROOT:/repo" \
  "$IMAGE" \
  bash -lc '
set -euo pipefail

export PATH="/build/depot_tools:$PATH"
export GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1

if [[ ! -d /build/depot_tools/.git ]]; then
  git clone --depth 1 \
    https://chromium.googlesource.com/chromium/tools/depot_tools.git \
    /build/depot_tools
fi
gclient metrics --opt-out >/dev/null 2>&1 || true

if [[ ! -d /build/flutter/.git ]]; then
  git clone --shared /sdk /build/flutter
fi
git config --global --add safe.directory /build/flutter
git -C /build/flutter checkout --detach "$ENGINE_HASH"
git -C /build/flutter diff --quiet "$ENGINE_HASH" -- engine || {
  echo "engine source cache has local modifications; use a new PLUTO_ENGINE_BUILD_VOLUME" >&2
  exit 2
}

cd /build/flutter
cp engine/scripts/standard.gclient .gclient
sed -i "/    # \"custom_vars\": {/,/    # },/c\\    \"custom_vars\": {\\n      \"download_android_deps\": False,\\n      \"download_jdk\": False,\\n      \"download_fuchsia_deps\": False,\\n      \"setup_githooks\": False,\\n      \"use_rbe\": False,\\n    }," .gclient

# The pinned DEPS unconditionally requests flutter/java/openjdk/linux-arm64,
# a package that does not exist. Java is used only by source-formatting tools,
# not by this engine target, so make the already-defined download_jdk switch
# apply to that dependency in the isolated cache checkout.
if ! grep -A4 "Always download the JDK" DEPS | grep -q "condition.*download_jdk"; then
  sed -i "/Always download the JDK since java is required/a\\     \"condition\": \"download_jdk\"," DEPS
fi

gclient sync --no-history -D

download_checked() {
  local url="$1"
  local destination="$2"
  local expected="$3"
  local actual=""
  if [[ -f "$destination" ]]; then
    actual="$(sha256sum "$destination" | cut -d" " -f1)"
  fi
  if [[ "$actual" != "$expected" ]]; then
    curl -fL --retry 3 -o "$destination.part" "$url"
    actual="$(sha256sum "$destination.part" | cut -d" " -f1)"
    [[ "$actual" == "$expected" ]] || {
      echo "checksum mismatch for $url: expected $expected, got $actual" >&2
      exit 2
    }
    mv "$destination.part" "$destination"
  fi
}

CACHE="/repo/.pluto-cache/engine/$ENGINE_HASH"
DEBUG_ZIP="$CACHE/artifacts.zip"
install -d "$CACHE"
download_checked \
  "https://storage.googleapis.com/flutter_infra_release/flutter/$ENGINE_HASH/linux-arm64/artifacts.zip" \
  "$DEBUG_ZIP" \
  "$DEBUG_ARTIFACTS_SHA256"

build_mode() {
  local mode="$1"
  local target_dir="$2"
  local gtk_sha256="$3"
  local gen_snapshot_sha256="$4"
  local engine_sha256="$5"
  local source_root="/build/flutter/engine/src"
  local output="$source_root/out/$target_dir"
  local destination="$CACHE/linux-arm64-$mode"
  local built_zip="$output/zip_archives/linux-arm64/linux-arm64-embedder.zip"
  local gtk_zip="$destination/linux-arm64-$mode-flutter-gtk.zip"

  cd "$source_root"
  ./flutter/tools/gn \
    --target-dir="$target_dir" \
    --runtime-mode="$mode" \
    --target-os=linux \
    --linux-cpu=arm64 \
    --prebuilt-dart-sdk \
    --no-lto \
    --no-rbe \
    --no-goma \
    --embedder-for-target \
    --disable-desktop-embeddings \
    --no-build-engine-artifacts \
    --no-build-glfw-shell \
    --no-build-embedder-examples \
    --no-enable-unittests

  ninja -C "out/$target_dir" -j "$JOBS" \
    flutter/shell/platform/embedder:embedder-archive

  install -d "$destination"
  install -m 0755 "$output/libflutter_engine.so" "$destination/libflutter_engine.so"
  install -m 0644 "$output/flutter_embedder.h" "$destination/flutter_embedder.h"
  install -m 0644 "$built_zip" "$destination/linux-arm64-$mode-embedder.zip"

  download_checked \
    "https://storage.googleapis.com/flutter_infra_release/flutter/$ENGINE_HASH/linux-arm64-$mode/linux-arm64-flutter-gtk.zip" \
    "$gtk_zip" \
    "$gtk_sha256"

  # Google publishes mode-specific GTK archives but no profile/release plain
  # embedder archive. Use their exact snapshotter with the source-built plain
  # embedder. ICU data is mode-independent and revision-matched.
  unzip -j -o "$gtk_zip" gen_snapshot LICENSE.flutter_gtk.md -d "$destination" >/dev/null
  unzip -j -o "$DEBUG_ZIP" icudtl.dat LICENSE.artifacts.md -d "$destination" >/dev/null
  unzip -j -o "$built_zip" LICENSE.embedder-archive.md -d "$destination" >/dev/null
  chmod 0755 "$destination/gen_snapshot"

  local actual_gen_snapshot
  local actual_engine
  actual_gen_snapshot="$(sha256sum "$destination/gen_snapshot" | cut -d" " -f1)"
  actual_engine="$(sha256sum "$destination/libflutter_engine.so" | cut -d" " -f1)"
  [[ "$actual_gen_snapshot" == "$gen_snapshot_sha256" ]] || {
    echo "unexpected $mode gen_snapshot checksum: $actual_gen_snapshot" >&2
    exit 2
  }
  [[ "$actual_engine" == "$engine_sha256" ]] || {
    echo "unexpected $mode engine checksum: $actual_engine" >&2
    exit 2
  }

  file "$destination/libflutter_engine.so" "$destination/gen_snapshot"
  readelf -Ws "$destination/libflutter_engine.so" |
    grep "FlutterEngineGetProcAddresses" >/dev/null
  readelf -Ws "$destination/libflutter_engine.so" |
    grep "FlutterEngineRunsAOTCompiledDartCode" >/dev/null

  {
    echo "engine=$ENGINE_HASH"
    echo "flutter=$FLUTTER_VERSION"
    echo "mode=$mode"
    echo "gn=official-linux-arm64-$mode+embedder-for-target,no-lto"
    sha256sum \
      "$destination/libflutter_engine.so" \
      "$destination/flutter_embedder.h" \
      "$destination/gen_snapshot" \
      "$destination/icudtl.dat" \
      "$destination/LICENSE.artifacts.md" \
      "$destination/LICENSE.embedder-archive.md" \
      "$destination/LICENSE.flutter_gtk.md" \
      "$destination/linux-arm64-$mode-embedder.zip" \
      "$destination/linux-arm64-$mode-flutter-gtk.zip"
  } > "$destination/BUILD-MANIFEST.txt"

  echo "$mode artifacts: $destination"
  sed -n "1,13p" "$destination/BUILD-MANIFEST.txt"
}

build_mode \
  release "$RELEASE_TARGET_DIR" "$RELEASE_GTK_SHA256" \
  "$RELEASE_GEN_SNAPSHOT_SHA256" "$RELEASE_ENGINE_SHA256"
build_mode \
  profile "$PROFILE_TARGET_DIR" "$PROFILE_GTK_SHA256" \
  "$PROFILE_GEN_SNAPSHOT_SHA256" "$PROFILE_ENGINE_SHA256"

chown -R "$HOST_UID:$HOST_GID" "$CACHE" 2>/dev/null || true
'

echo "done: $ROOT/.pluto-cache/engine/$ENGINE_HASH/linux-arm64-{release,profile}"
echo "to update the committed clone-ready artifacts, run:"
echo "  tools/engine/promote-aarch64-aot.sh"
