#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN="${PLUTO_ARM_SDK_PIN:-$ROOT/tools/pluto/pins/arm-sdk.pin}"
FINGERPRINT="$ROOT/tools/build/fingerprint-arm-sdk.sh"
PIN_ONLY=0

die() {
  echo "error: $*" >&2
  exit 2
}

case "${1:-}" in
  "") ;;
  --pin-only) PIN_ONLY=1 ;;
  *) die "usage: verify-arm-sdk.sh [--pin-only]" ;;
esac

pin_value() {
  local key="$1"
  local values
  values="$(sed -n "s/^${key}=//p" "$PIN")"
  [[ -n "$values" && "$values" != *$'\n'* ]] ||
    die "ARM SDK pin must contain exactly one $key field: $PIN"
  printf '%s\n' "$values"
}

[[ -f "$PIN" ]] || die "missing ARM SDK pin: $PIN"
[[ -x "$FINGERPRINT" ]] || die "missing SDK fingerprint helper: $FINGERPRINT"
[[ "$(wc -l < "$PIN" | tr -d '[:space:]')" = 6 ]] ||
  die "ARM SDK pin must contain exactly six fields: $PIN"

schema="$(pin_value schema)"
name="$(pin_value name)"
expected_sha256="$(pin_value sha256)"
expected_gcc_version="$(pin_value gcc_version)"
expected_gcc_machine="$(pin_value gcc_machine)"
expected_regular_files="$(pin_value regular_files)"

[[ "$schema" = 1 ]] || die "unsupported ARM SDK pin schema: $schema"
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid ARM SDK pin name: $name"
[[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] ||
  die "invalid ARM SDK SHA-256 pin"
[[ "$expected_gcc_version" =~ ^[0-9]+([.][0-9]+)+$ ]] ||
  die "invalid ARM SDK GCC version pin"
[[ "$expected_gcc_machine" =~ ^[A-Za-z0-9._-]+$ ]] ||
  die "invalid ARM SDK GCC machine pin"
[[ "$expected_regular_files" =~ ^[1-9][0-9]*$ ]] ||
  die "invalid ARM SDK regular-file count pin"

if [[ "$PIN_ONLY" -eq 1 ]]; then
  printf 'ARM SDK pin: PASS name=%s sha256=%s gcc=%s machine=%s files=%s\n' \
    "$name" "$expected_sha256" "$expected_gcc_version" \
    "$expected_gcc_machine" "$expected_regular_files"
  exit 0
fi

metadata="$(bash "$FINGERPRINT")"
actual_sha256="$(printf '%s\n' "$metadata" | sed -n 's/^SDK_SHA256=//p')"
actual_gcc_version="$(printf '%s\n' "$metadata" | sed -n 's/^GCC_VERSION=//p')"
actual_gcc_machine="$(printf '%s\n' "$metadata" | sed -n 's/^GCC_MACHINE=//p')"
actual_regular_files="$(printf '%s\n' "$metadata" | sed -n 's/^SDK_REGULAR_FILES=//p')"

[[ "$actual_sha256" = "$expected_sha256" ]] ||
  die "ARM SDK content mismatch for $name (expected $expected_sha256, got ${actual_sha256:-missing})"
[[ "$actual_gcc_version" = "$expected_gcc_version" ]] ||
  die "ARM SDK GCC version mismatch (expected $expected_gcc_version, got ${actual_gcc_version:-missing})"
[[ "$actual_gcc_machine" = "$expected_gcc_machine" ]] ||
  die "ARM SDK GCC machine mismatch (expected $expected_gcc_machine, got ${actual_gcc_machine:-missing})"
[[ "$actual_regular_files" = "$expected_regular_files" ]] ||
  die "ARM SDK file-count mismatch (expected $expected_regular_files, got ${actual_regular_files:-missing})"

printf 'ARM SDK gate: PASS name=%s sha256=%s gcc=%s machine=%s files=%s\n' \
  "$name" "$actual_sha256" "$actual_gcc_version" "$actual_gcc_machine" \
  "$actual_regular_files"
