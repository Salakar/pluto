#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tools/device/generated/device-profiles.sh"

fail() {
  printf 'device-profiles_test: %s\n' "$*" >&2
  exit 1
}

assert_profile() {
  expected=$1
  shift
  unset PLUTO_PROFILE_ID || true
  pluto_profile_detect "$@" || fail "expected $expected to match"
  [ "$PLUTO_PROFILE_ID" = "$expected" ] ||
    fail "expected $expected, got ${PLUTO_PROFILE_ID:-unset}"
}

assert_rejected() {
  unset PLUTO_PROFILE_ID || true
  if pluto_profile_detect "$@"; then
    fail "unsafe identity matched ${PLUTO_PROFILE_ID:-unset}"
  fi
}

assert_profile rm1 \
  'reMarkable 1.0' 'reMarkable 1.n' \
  'remarkable,zero-gravitas fsl,imx6sl' armv7l
assert_profile rm2 \
  'reMarkable 2.0' 'reMarkable 2.n' \
  'fsl,imx7d-sdb fsl,imx7d' armv7l
assert_profile move \
  'reMarkable Chiappa' 'reMarkable Chiappa' 'fsl,imx93' aarch64

assert_rejected 'reMarkable 1.0' '' '' armv7l
assert_rejected '' '' 'fsl,imx7d-sdb' armv7l
assert_rejected 'reMarkable Chiappa' '' 'fsl,imx93' armv7l
assert_rejected \
  'reMarkable 1.0 reMarkable 2.0' '' \
  'remarkable,zero-gravitas fsl,imx7d-sdb' armv7l

printf 'device-profiles_test: ok\n'
