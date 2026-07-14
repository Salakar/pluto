#!/usr/bin/env bash
set -euo pipefail

ROOT="${PLUTO_WORKSPACE:-/work}"
EMBEDDER_DIR="$ROOT/embedder"
GLIBC_CEILING="${PLUTO_GLIBC_CEILING:-2.39}"
JOBS="${PLUTO_BUILD_JOBS:-}"
CLEAN_FIRST="${PLUTO_DEVICE_CLEAN_FIRST:-0}"

die() {
  echo "error: $*" >&2
  exit 2
}

version_lte() {
  local candidate="$1"
  local ceiling="$2"
  [[ "$(printf '%s\n%s\n' "$candidate" "$ceiling" | LC_ALL=C sort -V | tail -1)" == "$ceiling" ]]
}

[[ "$(uname -m)" == "aarch64" ]] ||
  die "builder must run as linux/arm64 (uname -m returned $(uname -m))"
[[ "$GLIBC_CEILING" =~ ^[0-9]+\.[0-9]+$ ]] ||
  die "invalid GLIBC ceiling: $GLIBC_CEILING"
if [[ -n "$JOBS" && ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  die "PLUTO_BUILD_JOBS must be a positive integer"
fi
[[ "$CLEAN_FIRST" == 0 || "$CLEAN_FIRST" == 1 ]] ||
  die "PLUTO_DEVICE_CLEAN_FIRST must be 0 or 1"

CONTAINER_GLIBC="$(getconf GNU_LIBC_VERSION | awk '{print $2}')"
version_lte "$CONTAINER_GLIBC" "$GLIBC_CEILING" ||
  die "container GLIBC $CONTAINER_GLIBC exceeds device ceiling $GLIBC_CEILING"
echo "builder: aarch64, glibc $CONTAINER_GLIBC"

cd "$EMBEDDER_DIR"
cmake --preset device-arm64 \
  -DBUILD_TESTING=OFF \
  -DPLUTO_BUILD_TESTS=OFF

BUILD_COMMAND=(cmake --build --preset device-arm64 --target pluto-embedder --parallel)
if [[ -n "$JOBS" ]]; then
  BUILD_COMMAND+=("$JOBS")
fi
if [[ "$CLEAN_FIRST" == 1 ]]; then
  BUILD_COMMAND+=(--clean-first)
fi
"${BUILD_COMMAND[@]}"

cc -std=c11 -O2 -Wall -Wextra -Wpedantic \
  "$ROOT/tools/device/pluto-controlctl.c" \
  -o "$EMBEDDER_DIR/build/device-arm64/pluto-controlctl"

bash "$ROOT/tools/build/verify-device-elf.sh" \
  "$EMBEDDER_DIR/build/device-arm64/pluto-embedder" \
  "$GLIBC_CEILING"
bash "$ROOT/tools/build/verify-device-elf.sh" \
  "$EMBEDDER_DIR/build/device-arm64/pluto-controlctl" \
  "$GLIBC_CEILING" linux-arm64
