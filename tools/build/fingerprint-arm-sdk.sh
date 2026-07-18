#!/usr/bin/env bash
set -euo pipefail

readonly SDK_ROOT="${PLUTO_RM_SDK_ROOT:-/sdk}"
readonly SDK_HOST="$SDK_ROOT/sysroots/x86_64-codexsdk-linux"
readonly SDK_SYSROOT="$SDK_ROOT/sysroots/cortexa7hf-neon-remarkable-linux-gnueabi"
readonly CROSS_ROOT="$SDK_HOST/usr/bin/arm-remarkable-linux-gnueabi/arm-remarkable-linux-gnueabi"

die() {
  echo "error: $*" >&2
  exit 2
}

[[ -x "$CROSS_ROOT-gcc" && -x "$CROSS_ROOT-strip" ]] ||
  die "the official reMarkable ARM toolchain is missing under $SDK_ROOT"
[[ -d "$SDK_SYSROOT/usr/include" && -d "$SDK_SYSROOT/usr/lib" ]] ||
  die "the official reMarkable target sysroot is incomplete"

gcc_version="$("$CROSS_ROOT-gcc" -dumpfullversion -dumpversion)"
gcc_machine="$("$CROSS_ROOT-gcc" -dumpmachine)"

# Hash the complete read-only SDK tree while normalizing archive metadata.
# File contents, modes, names, and symlink targets remain part of the digest;
# host ownership and timestamps do not. This must run with GNU tar, which is
# supplied by the pinned device build containers.
sdk_sha256="$({
  tar \
    --sort=name \
    --mtime=@0 \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --format=gnu \
    --create \
    --file=- \
    --directory="$SDK_ROOT" \
    .
} | sha256sum | awk '{print $1}')"

printf 'SDK_SHA256=%s\n' "$sdk_sha256"
printf 'GCC_VERSION=%s\n' "$gcc_version"
printf 'GCC_MACHINE=%s\n' "$gcc_machine"
printf 'SDK_REGULAR_FILES=%s\n' \
  "$(find "$SDK_ROOT" -type f | wc -l | tr -d '[:space:]')"
