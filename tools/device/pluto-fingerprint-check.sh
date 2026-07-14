#!/bin/sh
# Firmware/xochitl fingerprint gate. Runs before Pluto launches anything.
set -eu

ROOT="${PLUTO_ROOT:-/home/root/pluto}"
STATE="$ROOT/state"
JOURNAL="$ROOT/provision.json"
REASON="$STATE/safe-mode-reason"

mkdir -p "$STATE"

write_reason() {
  printf '%s\n' "$1" > "$REASON.tmp"
  mv "$REASON.tmp" "$REASON"
}

json_string() {
  key="$1"
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$JOURNAL" | head -n 1
}

if [ ! -f "$JOURNAL" ]; then
  write_reason "provision-journal-missing"
  exit 1
fi

EXPECTED_OS="$(json_string osBuild)"
EXPECTED_XOCHITL="$(json_string xochitlSha256)"
if [ -z "$EXPECTED_OS" ] || [ -z "$EXPECTED_XOCHITL" ]; then
  write_reason "provision-fingerprint-missing"
  exit 1
fi

CURRENT_OS="$(head -n 1 /etc/version 2>/dev/null | tr -d '\r')"
if [ ! -x /usr/bin/xochitl ]; then
  write_reason "xochitl-missing"
  exit 1
fi
CURRENT_XOCHITL="$(sha256sum /usr/bin/xochitl | awk '{ print $1 }')"

if [ "$CURRENT_OS" != "$EXPECTED_OS" ]; then
  write_reason "os-build-changed: $EXPECTED_OS -> $CURRENT_OS"
  exit 1
fi
if [ "$CURRENT_XOCHITL" != "$EXPECTED_XOCHITL" ]; then
  write_reason "xochitl-sha256-changed"
  exit 1
fi
