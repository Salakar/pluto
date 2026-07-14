#!/usr/bin/env bash
set -euo pipefail

ROOT="${PLUTO_WORKSPACE:-/work}"
SDK_ROOT="${PLUTO_RM_SDK_ROOT:-/sdk}"
SOURCE_DIR="$ROOT/tools/device/diagnostics/framebuffer-observer"
OUTPUT_DIR="${PLUTO_FB_OBSERVER_OUTPUT_DIR:-$ROOT/.pluto-cache/diagnostics/framebuffer-observer/arm}"
COMPILER="$SDK_ROOT/sysroots/x86_64-codexsdk-linux/usr/bin/arm-remarkable-linux-gnueabi/arm-remarkable-linux-gnueabi-gcc"
SYSROOT="$SDK_ROOT/sysroots/cortexa7hf-neon-remarkable-linux-gnueabi"

die() {
  echo "error: $*" >&2
  exit 2
}

[[ "$(uname -m)" == x86_64 ]] ||
  die "the official reMarkable SDK tools require linux/amd64"
[[ -x "$COMPILER" ]] || die "missing ARM compiler: $COMPILER"
[[ -d "$SYSROOT" ]] || die "missing ARM sysroot: $SYSROOT"

mkdir -p "$OUTPUT_DIR"
unset CC CXX CPP CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

"$COMPILER" \
  --sysroot="$SYSROOT" \
  -march=armv7-a -mfpu=neon -mfloat-abi=hard \
  -O2 -DNDEBUG -DPLUTO_FB_OBSERVER_ARM_TARGET \
  -std=gnu11 -fPIC -fvisibility=hidden \
  -Wall -Wextra -Werror \
  -I"$SOURCE_DIR/include" -I"$SOURCE_DIR/src" \
  "$SOURCE_DIR/src/fb_observer_core.c" \
  "$SOURCE_DIR/src/fb_observer_preload.c" \
  -shared -ldl -pthread \
  -Wl,-z,relro -Wl,-z,now -Wl,-z,defs \
  -Wl,-O1 -Wl,--hash-style=gnu -Wl,--as-needed \
  -Wl,-soname,libpluto-fb-observer.so \
  -o "$OUTPUT_DIR/libpluto-fb-observer.so"

echo "built: $OUTPUT_DIR/libpluto-fb-observer.so"
