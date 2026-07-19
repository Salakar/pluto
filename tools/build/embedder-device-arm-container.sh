#!/usr/bin/env bash
set -euo pipefail

ROOT="${PLUTO_WORKSPACE:-/work}"
EMBEDDER_DIR="$ROOT/embedder"
SDK_ROOT="${PLUTO_RM_SDK_ROOT:-/sdk}"
JOBS="${PLUTO_BUILD_JOBS:-}"
CLEAN_FIRST="${PLUTO_DEVICE_CLEAN_FIRST:-0}"
SDK_ENV="$SDK_ROOT/environment-setup-cortexa7hf-neon-remarkable-linux-gnueabi"
SDK_COMPILER="$SDK_ROOT/sysroots/x86_64-codexsdk-linux/usr/bin/arm-remarkable-linux-gnueabi/arm-remarkable-linux-gnueabi-g++"
SDK_C_COMPILER="$SDK_ROOT/sysroots/x86_64-codexsdk-linux/usr/bin/arm-remarkable-linux-gnueabi/arm-remarkable-linux-gnueabi-gcc"
SDK_SYSROOT="$SDK_ROOT/sysroots/cortexa7hf-neon-remarkable-linux-gnueabi"

die() {
  echo "error: $*" >&2
  exit 2
}

[[ "$(uname -m)" == x86_64 ]] ||
  die "the official reMarkable SDK host tools require a linux/amd64 container (uname -m returned $(uname -m))"
[[ -f "$SDK_ENV" ]] ||
  die "reMarkable SDK environment is missing at $SDK_ENV"
[[ -x "$SDK_COMPILER" ]] ||
  die "reMarkable ARM C++ compiler is missing at $SDK_COMPILER"
[[ -x "$SDK_C_COMPILER" ]] ||
  die "reMarkable ARM C compiler is missing at $SDK_C_COMPILER"
[[ -d "$SDK_SYSROOT" ]] ||
  die "reMarkable ARM target sysroot is missing at $SDK_SYSROOT"
if [[ -n "$JOBS" && ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  die "PLUTO_BUILD_JOBS must be a positive integer"
fi
[[ "$CLEAN_FIRST" == 0 || "$CLEAN_FIRST" == 1 ]] ||
  die "PLUTO_DEVICE_CLEAN_FIRST must be 0 or 1"

# Do not source the SDK environment here. It injects -mcpu=cortex-a7 through
# CC/CXX, while the tracked CMake toolchain intentionally targets the common
# ARMv7-A/NEON/hard-float baseline shared by reMarkable 1 and 2.
unset CC CXX CPP CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

echo "builder: $(uname -m), $($SDK_COMPILER --version | head -n 1)"

cd "$EMBEDDER_DIR"
cmake --preset device-arm \
  -DPLUTO_RM_SDK_ROOT="$SDK_ROOT" \
  -DBUILD_TESTING=OFF \
  -DPLUTO_BUILD_TESTS=OFF

BUILD_COMMAND=(cmake --build --preset device-arm --target pluto-embedder --parallel)
if [[ -n "$JOBS" ]]; then
  BUILD_COMMAND+=("$JOBS")
fi
if [[ "$CLEAN_FIRST" == 1 ]]; then
  BUILD_COMMAND+=(--clean-first)
fi
"${BUILD_COMMAND[@]}"

# The control client deliberately has no display-backend dependency. Build it
# beside the embedder so the payload assembler can authenticate and install
# the exact ARMv7 helper expected by the unified CLI.
"$SDK_C_COMPILER" \
  --sysroot="$SDK_SYSROOT" \
  -march=armv7-a -mfpu=neon -mfloat-abi=hard \
  -O2 -DNDEBUG -std=c11 -Wall -Wextra -Werror \
  "$ROOT/tools/device/pluto-controlctl.c" \
  -Wl,-O1 -Wl,--hash-style=gnu -Wl,--as-needed \
  -o "$EMBEDDER_DIR/build/device-arm/pluto-controlctl"
