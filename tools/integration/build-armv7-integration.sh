#!/usr/bin/env bash
set -euo pipefail

# Reconstruct the cooperative ARMv7 integration from exact upstream source,
# Pluto's reviewed patches, and immutable build-tool images. Nothing in this
# script contacts a tablet. Promotion is explicit and checksum-gated.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK="${PLUTO_INTEGRATION_LOCK_FILE:-$ROOT/tools/integration/sources.lock}"
readonly EXPECTED_LOCK_SHA256=3626e05c36af9eab6acde426527062522f85a11cbbb9fed4e51007038d54803f

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

die() {
  echo "error: $*" >&2
  exit 2
}

[[ -f "$LOCK" ]] || die "missing integration lockfile: $LOCK"
[[ "$(sha256_file "$LOCK")" = "$EXPECTED_LOCK_SHA256" ]] ||
  die "integration lockfile checksum mismatch"

# The lockfile has only literal KEY=value records and is itself authenticated
# above before evaluation.
# shellcheck source=sources.lock
source "$LOCK"
[[ "$SCHEMA" = 1 ]] || die "unsupported integration lock schema: $SCHEMA"

CACHE="$ROOT/.pluto-cache/integration"
SOURCE_CACHE=""
PREPARED=""
OUTPUT=""
PATCH_ROOT="$ROOT/tools/integration/patches"
XOVI_REPO=""
EXTENSIONS_REPO=""
QMLDIFF_REPO=""
APPLOAD_REPO=""
SDK_DIR=""
ACTION=build
OFFLINE=0
PROMOTE=0
REQUIRE_REFERENCE_HASHES=0

usage() {
  cat <<'EOF'
Usage: tools/integration/build-armv7-integration.sh [options]

Reconstruct XOVI, Qt Resource Rebuilder, AppLoad, and the QTFB shims used by
Pluto's cooperative linux-arm backend. Source commits, patches, toolchain
images, device profiles, and reference output hashes are locked in
tools/integration/sources.lock.

Options:
  --prepare-only         verify pins and patches, then materialize clean source
  --verify-inputs       verify the authenticated lockfile and patch checksums
  --verify-reference    verify the currently device-validated local artifacts
  --offline             forbid Git/curl network fetches
  --cache DIR           cache root (default: .pluto-cache/integration)
  --prepared DIR        prepared source tree (default: <cache>/prepared)
  --output DIR          rebuilt artifacts (default: <cache>/output)
  --patch-root DIR      patch directory (primarily for integrity testing)
  --xovi-repo DIR       local Git repository containing the locked XOVI commit
  --extensions-repo DIR local Git repository containing the locked extensions
  --qmldiff-repo DIR    local Git repository containing the locked qmldiff
  --appload-repo DIR    local Git repository containing both AppLoad bases
  --sdk-dir DIR         use an already extracted copy of the locked RM SDK
  --require-reference-hashes
                         fail unless rebuilt files equal validated SHA-256s
  --promote             checksum-gate and copy rebuilt files to assembler inputs
  -h, --help            show this help

The ordinary release workflow consumes validated artifacts through
`pluto provision`; this maintainer command exists to make their complete
corresponding source and rebuild procedure auditable. It never deploys.
EOF
}

while (($# > 0)); do
  case "$1" in
    --prepare-only) ACTION=prepare ;;
    --verify-inputs) ACTION=verify-inputs ;;
    --verify-reference) ACTION=verify-reference ;;
    --offline) OFFLINE=1 ;;
    --promote) PROMOTE=1; REQUIRE_REFERENCE_HASHES=1 ;;
    --require-reference-hashes) REQUIRE_REFERENCE_HASHES=1 ;;
    --cache)
      shift
      (($# > 0)) || die "--cache requires a value"
      CACHE="$1"
      ;;
    --cache=*) CACHE="${1#*=}" ;;
    --prepared)
      shift
      (($# > 0)) || die "--prepared requires a value"
      PREPARED="$1"
      ;;
    --prepared=*) PREPARED="${1#*=}" ;;
    --output)
      shift
      (($# > 0)) || die "--output requires a value"
      OUTPUT="$1"
      ;;
    --output=*) OUTPUT="${1#*=}" ;;
    --patch-root)
      shift
      (($# > 0)) || die "--patch-root requires a value"
      PATCH_ROOT="$1"
      ;;
    --patch-root=*) PATCH_ROOT="${1#*=}" ;;
    --xovi-repo)
      shift
      (($# > 0)) || die "--xovi-repo requires a value"
      XOVI_REPO="$1"
      ;;
    --xovi-repo=*) XOVI_REPO="${1#*=}" ;;
    --extensions-repo)
      shift
      (($# > 0)) || die "--extensions-repo requires a value"
      EXTENSIONS_REPO="$1"
      ;;
    --extensions-repo=*) EXTENSIONS_REPO="${1#*=}" ;;
    --qmldiff-repo)
      shift
      (($# > 0)) || die "--qmldiff-repo requires a value"
      QMLDIFF_REPO="$1"
      ;;
    --qmldiff-repo=*) QMLDIFF_REPO="${1#*=}" ;;
    --appload-repo)
      shift
      (($# > 0)) || die "--appload-repo requires a value"
      APPLOAD_REPO="$1"
      ;;
    --appload-repo=*) APPLOAD_REPO="${1#*=}" ;;
    --sdk-dir)
      shift
      (($# > 0)) || die "--sdk-dir requires a value"
      SDK_DIR="$1"
      ;;
    --sdk-dir=*) SDK_DIR="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

SOURCE_CACHE="$CACHE/sources"
PREPARED="${PREPARED:-$CACHE/prepared}"
OUTPUT="${OUTPUT:-$CACHE/output}"

verify_file_hash() {
  local path="$1"
  local expected="$2"
  local label="$3"
  [[ -f "$path" ]] || die "missing $label: $path"
  local actual
  actual="$(sha256_file "$path")"
  [[ "$actual" = "$expected" ]] ||
    die "$label checksum mismatch: expected $expected, got $actual"
}

verify_patches() {
  verify_file_hash \
    "$PATCH_ROOT/appload-3.27-pluto.patch" \
    "$APPLOAD_327_PATCH_SHA256" \
    "AppLoad 3.27 Pluto patch"
  verify_file_hash \
    "$PATCH_ROOT/appload-3.28-performance.patch" \
    "$APPLOAD_328_PERFORMANCE_PATCH_SHA256" \
    "AppLoad 3.28 performance patch"
  verify_file_hash \
    "$PATCH_ROOT/appload-3.28-pluto.patch" \
    "$APPLOAD_328_PLUTO_PATCH_SHA256" \
    "AppLoad 3.28 Pluto patch"
}

verify_reference_elf() {
  local path="$1"
  local label="$2"
  echo "ABI-checking $label: $path"
  bash "$ROOT/tools/build/verify-device-elf.sh" "$path" 2.35 linux-arm
}

verify_reference_artifacts() {
  verify_file_hash \
    "$ROOT/.pluto-cache/xovi/arm32-v19/xovi/xovi.so" \
    "$REFERENCE_XOVI_SHA256" "validated XOVI runtime"
  verify_file_hash \
    "$ROOT/.pluto-cache/xovi/arm32-v19/xovi/extensions.d/qt-resource-rebuilder.so" \
    "$REFERENCE_QRR_SHA256" "validated Qt Resource Rebuilder"
  verify_file_hash \
    "$ROOT/.pluto-cache/xovi/appload-arm32-v0.5.3/shims/qtfb-shim-32bit.so" \
    "$REFERENCE_QTFB_SHIM_32_SHA256" "validated 32-bit QTFB shim"
  verify_file_hash \
    "$ROOT/.pluto-cache/xovi/appload-arm32-v0.5.3/shims/qtfb-shim.so" \
    "$REFERENCE_QTFB_SHIM_SHA256" "validated QTFB shim"
  verify_file_hash \
    "$ROOT/.pluto-cache/build/appload-pluto-control-3.27-arm32/appload.so" \
    "$REFERENCE_APPLOAD_327_SHA256" "validated AppLoad 3.27 extension"
  verify_file_hash \
    "$ROOT/.pluto-cache/build/appload-pluto-control-arm32/appload.so" \
    "$REFERENCE_APPLOAD_328_SHA256" "validated AppLoad 3.28 extension"
  verify_file_hash \
    "$ROOT/embedder/build/device-arm/pluto-apploadctl" \
    "$REFERENCE_CONTROL_CLIENT_SHA256" "validated AppLoad control client"
  verify_reference_elf \
    "$ROOT/.pluto-cache/xovi/arm32-v19/xovi/xovi.so" \
    "device-validated XOVI runtime"
  verify_reference_elf \
    "$ROOT/.pluto-cache/xovi/arm32-v19/xovi/extensions.d/qt-resource-rebuilder.so" \
    "device-validated Qt Resource Rebuilder"
  verify_reference_elf \
    "$ROOT/.pluto-cache/xovi/appload-arm32-v0.5.3/shims/qtfb-shim-32bit.so" \
    "device-validated 32-bit QTFB shim"
  verify_reference_elf \
    "$ROOT/.pluto-cache/xovi/appload-arm32-v0.5.3/shims/qtfb-shim.so" \
    "device-validated QTFB shim"
  verify_reference_elf \
    "$ROOT/.pluto-cache/build/appload-pluto-control-3.27-arm32/appload.so" \
    "device-validated AppLoad 3.27 extension"
  verify_reference_elf \
    "$ROOT/.pluto-cache/build/appload-pluto-control-arm32/appload.so" \
    "device-validated AppLoad 3.28 extension"
  verify_reference_elf \
    "$ROOT/embedder/build/device-arm/pluto-apploadctl" \
    "device-validated AppLoad control client"
  echo "Verified checksums and ARMv7 ABI for cooperative integration artifacts."
}

verify_patches
if [[ "$ACTION" = verify-inputs ]]; then
  echo "Verified locked cooperative integration inputs."
  exit 0
fi
if [[ "$ACTION" = verify-reference ]]; then
  verify_reference_artifacts
  exit 0
fi

repo_has_commit() {
  local repo="$1"
  local commit="$2"
  git -C "$repo" cat-file -e "$commit^{commit}" >/dev/null 2>&1
}

ensure_bare_repo() {
  local name="$1"
  local url="$2"
  local commit="$3"
  local repo="$SOURCE_CACHE/$name.git"

  if [[ ! -d "$repo" ]]; then
    ((OFFLINE == 0)) || die "offline source cache is missing $name"
    install -d "$SOURCE_CACHE"
    git init --bare "$repo" >/dev/null
  fi
  if ! repo_has_commit "$repo" "$commit"; then
    ((OFFLINE == 0)) || die "offline source cache lacks $name commit $commit"
    git -C "$repo" fetch --no-tags --depth 1 "$url" "$commit"
  fi
  repo_has_commit "$repo" "$commit" ||
    die "$name source does not contain locked commit $commit"
  printf '%s\n' "$repo"
}

select_repo() {
  local supplied="$1"
  local name="$2"
  local url="$3"
  local commit="$4"
  if [[ -n "$supplied" ]]; then
    [[ -d "$supplied" ]] || die "missing local $name repository: $supplied"
    repo_has_commit "$supplied" "$commit" ||
      die "local $name repository lacks locked commit $commit"
    printf '%s\n' "$supplied"
  else
    ensure_bare_repo "$name" "$url" "$commit"
  fi
}

archive_commit() {
  local repo="$1"
  local commit="$2"
  local destination="$3"
  install -d "$destination"
  git -C "$repo" archive --format=tar "$commit" | tar -xf - -C "$destination"
}

XOVI_SELECTED="$(select_repo "$XOVI_REPO" xovi "$XOVI_URL" "$XOVI_COMMIT")"
EXTENSIONS_SELECTED="$(select_repo \
  "$EXTENSIONS_REPO" rm-xovi-extensions \
  "$EXTENSIONS_URL" "$EXTENSIONS_COMMIT")"
QMLDIFF_SELECTED="$(select_repo \
  "$QMLDIFF_REPO" qmldiff "$QMLDIFF_URL" "$QMLDIFF_COMMIT")"
APPLOAD_SELECTED="$(select_repo \
  "$APPLOAD_REPO" rm-appload "$APPLOAD_URL" "$APPLOAD_327_COMMIT")"
repo_has_commit "$APPLOAD_SELECTED" "$APPLOAD_328_BASE_COMMIT" || {
  if [[ -n "$APPLOAD_REPO" || $OFFLINE -eq 1 ]]; then
    die "AppLoad repository lacks locked 3.28 base $APPLOAD_328_BASE_COMMIT"
  fi
  git -C "$APPLOAD_SELECTED" fetch --no-tags --depth 1 \
    "$APPLOAD_URL" "$APPLOAD_328_BASE_COMMIT"
}
repo_has_commit "$APPLOAD_SELECTED" "$APPLOAD_328_BASE_COMMIT" ||
  die "AppLoad source does not contain locked 3.28 base"

PREPARED_NEXT="$PREPARED.pluto-new-$$"
case "$PREPARED_NEXT" in
  "$CACHE"/*|"$ROOT/.pluto-cache"/*|/tmp/*|/private/tmp/*) ;;
  *) die "refusing to replace unsafe prepared path: $PREPARED_NEXT" ;;
esac
rm -rf "$PREPARED_NEXT"
install -d "$PREPARED_NEXT"
archive_commit "$XOVI_SELECTED" "$XOVI_COMMIT" "$PREPARED_NEXT/xovi"
archive_commit \
  "$EXTENSIONS_SELECTED" "$EXTENSIONS_COMMIT" "$PREPARED_NEXT/extensions"
rm -rf "$PREPARED_NEXT/extensions/qt-resource-rebuilder/qmldiff"
archive_commit \
  "$QMLDIFF_SELECTED" "$QMLDIFF_COMMIT" \
  "$PREPARED_NEXT/extensions/qt-resource-rebuilder/qmldiff"
archive_commit \
  "$APPLOAD_SELECTED" "$APPLOAD_327_COMMIT" "$PREPARED_NEXT/appload-3.27"
archive_commit \
  "$APPLOAD_SELECTED" "$APPLOAD_328_BASE_COMMIT" "$PREPARED_NEXT/appload-3.28"

for license in \
  "$PREPARED_NEXT/xovi/LICENSE" \
  "$PREPARED_NEXT/extensions/LICENSE" \
  "$PREPARED_NEXT/extensions/qt-resource-rebuilder/qmldiff/LICENSE" \
  "$PREPARED_NEXT/appload-3.27/LICENSE" \
  "$PREPARED_NEXT/appload-3.28/LICENSE"; do
  verify_file_hash "$license" "$LICENSE_SHA256" "GPL-3.0 source license"
done

git -C "$PREPARED_NEXT/appload-3.27" apply --check \
  "$PATCH_ROOT/appload-3.27-pluto.patch"
git -C "$PREPARED_NEXT/appload-3.27" apply \
  "$PATCH_ROOT/appload-3.27-pluto.patch"
git -C "$PREPARED_NEXT/appload-3.28" apply --check \
  "$PATCH_ROOT/appload-3.28-performance.patch"
git -C "$PREPARED_NEXT/appload-3.28" apply \
  "$PATCH_ROOT/appload-3.28-performance.patch"
git -C "$PREPARED_NEXT/appload-3.28" apply --check \
  "$PATCH_ROOT/appload-3.28-pluto.patch"
git -C "$PREPARED_NEXT/appload-3.28" apply \
  "$PATCH_ROOT/appload-3.28-pluto.patch"

for source in "$PREPARED_NEXT/appload-3.27" "$PREPARED_NEXT/appload-3.28"; do
  [[ -f "$source/src/PlutoControlServer.cpp" ]] ||
    die "patched source lacks PlutoControlServer.cpp: $source"
  LC_ALL=C grep -F 'PlutoControlServer.cpp' "$source/appload.pro" >/dev/null ||
    die "patched AppLoad project does not compile the control server: $source"
done

cat > "$PREPARED_NEXT/PREPARED-SOURCES.txt" <<EOF
schema=1
license=$LICENSE_SPDX
xovi=$XOVI_URL@$XOVI_COMMIT
extensions=$EXTENSIONS_URL@$EXTENSIONS_COMMIT
qmldiff=$QMLDIFF_URL@$QMLDIFF_COMMIT
appload-3.27=$APPLOAD_URL@$APPLOAD_327_COMMIT+appload-3.27-pluto.patch@$APPLOAD_327_PATCH_SHA256
appload-3.28=$APPLOAD_URL@$APPLOAD_328_BASE_COMMIT+appload-3.28-performance.patch@$APPLOAD_328_PERFORMANCE_PATCH_SHA256+appload-3.28-pluto.patch@$APPLOAD_328_PLUTO_PATCH_SHA256
builder=$BUILDER_IMAGE
rm-sdk=$RM_SDK_URL@$RM_SDK_SHA256
rust=$RUST_TOOLCHAIN
EOF

install -d "$(dirname "$PREPARED")"
if [[ -e "$PREPARED" ]]; then
  case "$PREPARED" in
    "$CACHE"/*|"$ROOT/.pluto-cache"/*|/tmp/*|/private/tmp/*) rm -rf "$PREPARED" ;;
    *) die "refusing to replace unsafe prepared path: $PREPARED" ;;
  esac
fi
mv "$PREPARED_NEXT" "$PREPARED"
echo "Prepared locked integration source at $PREPARED"

if [[ "$ACTION" = prepare ]]; then
  exit 0
fi

command -v docker >/dev/null 2>&1 || die "Docker is required for ARMv7 builds"

verify_sdk() {
  local sdk="$1"
  local version="$sdk/version-cortexa7hf-neon-remarkable-linux-gnueabi"
  local compiler="$sdk/sysroots/x86_64-codexsdk-linux/usr/bin/arm-remarkable-linux-gnueabi/arm-remarkable-linux-gnueabi-gcc"
  [[ -f "$sdk/environment-setup-cortexa7hf-neon-remarkable-linux-gnueabi" ]] ||
    die "RM SDK environment is missing: $sdk"
  [[ -x "$compiler" ]] || die "RM SDK compiler is missing: $compiler"
  [[ -f "$version" ]] || die "RM SDK version record is missing: $version"
  grep -F "Distro Version: $RM_SDK_DISTRO_VERSION" "$version" >/dev/null ||
    die "RM SDK distro version does not match the lock"
  grep -F "Metadata Revision: $RM_SDK_METADATA_REVISION" "$version" >/dev/null ||
    die "RM SDK metadata revision does not match the lock"
  grep -F "Timestamp: $RM_SDK_TIMESTAMP" "$version" >/dev/null ||
    die "RM SDK timestamp does not match the lock"
}

if [[ -n "$SDK_DIR" ]]; then
  SDK_ROOT="$(cd "$SDK_DIR" && pwd)"
  verify_sdk "$SDK_ROOT"
else
  SDK_INSTALLER="$CACHE/downloads/${RM_SDK_URL##*/}"
  if [[ ! -f "$SDK_INSTALLER" ]]; then
    ((OFFLINE == 0)) || die "offline cache is missing $SDK_INSTALLER"
    install -d "$(dirname "$SDK_INSTALLER")"
    curl --proto '=https' --tlsv1.2 -fsSL "$RM_SDK_URL" -o "$SDK_INSTALLER"
  fi
  verify_file_hash "$SDK_INSTALLER" "$RM_SDK_SHA256" "official RM SDK installer"
  SDK_ROOT="$CACHE/rm-sdk-$RM_SDK_DISTRO_VERSION"
  if [[ ! -f "$SDK_ROOT/environment-setup-cortexa7hf-neon-remarkable-linux-gnueabi" ]]; then
    SDK_NEXT="$SDK_ROOT.pluto-new-$$"
    rm -rf "$SDK_NEXT"
    install -d "$SDK_NEXT"
    docker run --rm --platform linux/amd64 \
      -v "$SDK_INSTALLER:/bootstrap/sdk-installer:ro" \
      -v "$SDK_NEXT:/usr/local/oe-sdk-hardcoded-buildpath" \
      "$BUILDER_IMAGE" sh /bootstrap/sdk-installer -y \
        -d /usr/local/oe-sdk-hardcoded-buildpath
    mv "$SDK_NEXT" "$SDK_ROOT"
  fi
  verify_sdk "$SDK_ROOT"
fi

RUSTUP_INIT="$CACHE/downloads/rustup-init-$RUSTUP_VERSION-x86_64"
if [[ ! -f "$RUSTUP_INIT" ]]; then
  ((OFFLINE == 0)) || die "offline cache is missing $RUSTUP_INIT"
  install -d "$(dirname "$RUSTUP_INIT")"
  curl --proto '=https' --tlsv1.2 -fsSL \
    "https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/x86_64-unknown-linux-gnu/rustup-init" \
    -o "$RUSTUP_INIT"
fi
verify_file_hash "$RUSTUP_INIT" "$RUSTUP_INIT_SHA256" "rustup-init"
chmod 0755 "$RUSTUP_INIT"

BUILD_WORK="$CACHE/build-work"
OUTPUT_NEXT="$OUTPUT.pluto-new-$$"
rm -rf "$BUILD_WORK"
rm -rf "$OUTPUT_NEXT"
install -d \
  "$BUILD_WORK/qrr" "$BUILD_WORK/appload" "$OUTPUT_NEXT/raw" \
  "$CACHE/cargo" "$CACHE/rustup"

docker run --rm --platform linux/amd64 \
  -e "RUST_TOOLCHAIN=$RUST_TOOLCHAIN" \
  -e SOURCE_DATE_EPOCH=1779560831 \
  -v "$PREPARED:/src:ro" \
  -v "$BUILD_WORK/qrr:/work" \
  -v "$OUTPUT_NEXT/raw:/out" \
  -v "$RUSTUP_INIT:/bootstrap/rustup-init:ro" \
  -v "$CACHE/cargo:/cargo" \
  -v "$CACHE/rustup:/rustup" \
  -v "$SDK_ROOT:/usr/local/oe-sdk-hardcoded-buildpath:ro" \
  "$BUILDER_IMAGE" bash -lc '
    set -euo pipefail
    cp -a /src/xovi /work/xovi
    cp -a /src/extensions /work/extensions
    export HOME=/work/home CARGO_HOME=/cargo RUSTUP_HOME=/rustup
    install -d "$HOME" "$CARGO_HOME" "$RUSTUP_HOME"
    /bootstrap/rustup-init -y --no-modify-path --profile minimal \
      --default-toolchain "$RUST_TOOLCHAIN"
    export PATH="$CARGO_HOME/bin:$PATH"
    rustup target add --toolchain "$RUST_TOOLCHAIN" \
      armv7-unknown-linux-gnueabihf
    . /usr/local/oe-sdk-hardcoded-buildpath/environment-setup-*
    export PATH="$CARGO_HOME/bin:$PATH"
    export XOVI_REPO=/work/xovi
    printf "#!/bin/sh\nexec %s \"\$@\"\n" "$CC" > /work/arm-linker
    chmod 0755 /work/arm-linker
    export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABIHF_LINKER=/work/arm-linker
    cmake -S /work/xovi -B /work/xovi-build -DCMAKE_BUILD_TYPE=Release
    cmake --build /work/xovi-build --parallel
    make -C /work/extensions/qt-resource-rebuilder clean
    make -C /work/extensions/qt-resource-rebuilder -j"$(nproc)"
    cp /work/xovi-build/xovi.so /out/xovi.so
    cp /work/extensions/qt-resource-rebuilder/qt-resource-rebuilder.so \
      /out/qt-resource-rebuilder.so
  '

docker run --rm --platform linux/amd64 \
  -e SOURCE_DATE_EPOCH=1784037367 \
  -v "$PREPARED:/src:ro" \
  -v "$BUILD_WORK/appload:/work" \
  -v "$OUTPUT_NEXT/raw:/out" \
  -v "$SDK_ROOT:/usr/local/oe-sdk-hardcoded-buildpath:ro" \
  "$BUILDER_IMAGE" bash -lc '
    set -euo pipefail
    cp -a /src/xovi /work/xovi
    cp -a /src/appload-3.27 /work/appload-3.27
    cp -a /src/appload-3.28 /work/appload-3.28
    . /usr/local/oe-sdk-hardcoded-buildpath/environment-setup-*
    rcc_dir="$(dirname "$(find /usr/local/oe-sdk-hardcoded-buildpath -type f -name rcc -print -quit)")"
    export PATH="$rcc_dir:$PATH"
    export XOVI_REPO=/work/xovi
    (cd /work/appload-3.27/xovi && bash make.sh)
    (cd /work/appload-3.28/xovi && bash make.sh)
    cmake -S /work/appload-3.27/shim -B /work/shim-build \
      -DCMAKE_BUILD_TYPE=Release
    cmake --build /work/shim-build --parallel
    "$STRIP" --strip-unneeded /work/appload-3.27/xovi/appload.so
    "$STRIP" --strip-unneeded /work/appload-3.28/xovi/appload.so
    cp /work/appload-3.27/xovi/appload.so /out/appload-3.27.so
    cp /work/appload-3.28/xovi/appload.so /out/appload-3.28.so
    cp /work/shim-build/qtfb-shim-32bit.so /out/qtfb-shim-32bit.so
    cp /work/shim-build/qtfb-shim.so /out/qtfb-shim.so
  '

install -d \
  "$OUTPUT_NEXT/xovi/extensions.d" \
  "$OUTPUT_NEXT/xovi/scripts/debug" \
  "$OUTPUT_NEXT/xovi/services/xochitl.service" \
  "$OUTPUT_NEXT/shims" \
  "$OUTPUT_NEXT/appload-3.27" \
  "$OUTPUT_NEXT/appload-3.28"
install -m 0644 "$OUTPUT_NEXT/raw/xovi.so" "$OUTPUT_NEXT/xovi/xovi.so"
install -m 0644 \
  "$OUTPUT_NEXT/raw/qt-resource-rebuilder.so" \
  "$OUTPUT_NEXT/xovi/extensions.d/qt-resource-rebuilder.so"
for script in start stock debug rebuild_hashtable; do
  install -m 0755 \
    "$PREPARED/extensions/xovi-setup/$script" "$OUTPUT_NEXT/xovi/$script"
done
install -m 0755 \
  "$PREPARED/extensions/xovi-setup/scripts/debug/qt-resource-rebuilder.sh" \
  "$OUTPUT_NEXT/xovi/scripts/debug/qt-resource-rebuilder.sh"
install -m 0644 \
  "$PREPARED/extensions/xovi-setup/services/xochitl.service/qt-resource-rebuilder.conf" \
  "$OUTPUT_NEXT/xovi/services/xochitl.service/qt-resource-rebuilder.conf"
install -m 0644 \
  "$OUTPUT_NEXT/raw/qtfb-shim-32bit.so" "$OUTPUT_NEXT/shims/qtfb-shim-32bit.so"
install -m 0644 \
  "$OUTPUT_NEXT/raw/qtfb-shim.so" "$OUTPUT_NEXT/shims/qtfb-shim.so"
install -m 0644 \
  "$OUTPUT_NEXT/raw/appload-3.27.so" "$OUTPUT_NEXT/appload-3.27/appload.so"
install -m 0644 \
  "$OUTPUT_NEXT/raw/appload-3.28.so" "$OUTPUT_NEXT/appload-3.28/appload.so"
rm -rf "$OUTPUT_NEXT/raw"
cp "$PREPARED/PREPARED-SOURCES.txt" "$OUTPUT_NEXT/BUILD-PROVENANCE.txt"

for elf in \
  "$OUTPUT_NEXT/xovi/xovi.so" \
  "$OUTPUT_NEXT/xovi/extensions.d/qt-resource-rebuilder.so" \
  "$OUTPUT_NEXT/shims/qtfb-shim-32bit.so" \
  "$OUTPUT_NEXT/shims/qtfb-shim.so" \
  "$OUTPUT_NEXT/appload-3.27/appload.so" \
  "$OUTPUT_NEXT/appload-3.28/appload.so"; do
  bash "$ROOT/tools/build/verify-device-elf.sh" "$elf" 2.35 linux-arm
done

if ((REQUIRE_REFERENCE_HASHES == 1)); then
  verify_file_hash "$OUTPUT_NEXT/xovi/xovi.so" \
    "$REFERENCE_XOVI_SHA256" "rebuilt XOVI runtime"
  verify_file_hash "$OUTPUT_NEXT/xovi/extensions.d/qt-resource-rebuilder.so" \
    "$REFERENCE_QRR_SHA256" "rebuilt Qt Resource Rebuilder"
  verify_file_hash "$OUTPUT_NEXT/shims/qtfb-shim-32bit.so" \
    "$REFERENCE_QTFB_SHIM_32_SHA256" "rebuilt 32-bit QTFB shim"
  verify_file_hash "$OUTPUT_NEXT/shims/qtfb-shim.so" \
    "$REFERENCE_QTFB_SHIM_SHA256" "rebuilt QTFB shim"
  verify_file_hash "$OUTPUT_NEXT/appload-3.27/appload.so" \
    "$REFERENCE_APPLOAD_327_SHA256" "rebuilt AppLoad 3.27 extension"
  verify_file_hash "$OUTPUT_NEXT/appload-3.28/appload.so" \
    "$REFERENCE_APPLOAD_328_SHA256" "rebuilt AppLoad 3.28 extension"
fi

if [[ -e "$OUTPUT" ]]; then
  case "$OUTPUT" in
    "$CACHE"/*|"$ROOT/.pluto-cache"/*|/tmp/*|/private/tmp/*) rm -rf "$OUTPUT" ;;
    *) die "refusing to replace unsafe output path: $OUTPUT" ;;
  esac
fi
mv "$OUTPUT_NEXT" "$OUTPUT"
echo "Built locked cooperative integration at $OUTPUT"

if ((PROMOTE == 1)); then
  install -d \
    "$ROOT/.pluto-cache/xovi/arm32-v19" \
    "$ROOT/.pluto-cache/xovi/appload-arm32-v0.5.3/shims" \
    "$ROOT/.pluto-cache/build/appload-pluto-control-3.27-arm32" \
    "$ROOT/.pluto-cache/build/appload-pluto-control-arm32"
  rm -rf "$ROOT/.pluto-cache/xovi/arm32-v19/xovi"
  cp -R "$OUTPUT/xovi" "$ROOT/.pluto-cache/xovi/arm32-v19/xovi"
  install -m 0644 "$OUTPUT/shims/qtfb-shim-32bit.so" \
    "$ROOT/.pluto-cache/xovi/appload-arm32-v0.5.3/shims/qtfb-shim-32bit.so"
  install -m 0644 "$OUTPUT/shims/qtfb-shim.so" \
    "$ROOT/.pluto-cache/xovi/appload-arm32-v0.5.3/shims/qtfb-shim.so"
  install -m 0644 "$OUTPUT/appload-3.27/appload.so" \
    "$ROOT/.pluto-cache/build/appload-pluto-control-3.27-arm32/appload.so"
  install -m 0644 "$OUTPUT/appload-3.28/appload.so" \
    "$ROOT/.pluto-cache/build/appload-pluto-control-arm32/appload.so"
  echo "Promoted checksum-matched integration artifacts for payload assembly."
fi
