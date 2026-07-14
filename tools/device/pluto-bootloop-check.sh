#!/bin/sh
# Crash-loop breaker for automatic launcher starts.
set -eu

ROOT="${PLUTO_ROOT:-/home/root/pluto}"
STATE="$ROOT/state"
LEDGER="$STATE/launcher-launches.log"
WINDOW_SECONDS="${PLUTO_BOOTLOOP_WINDOW_SECONDS:-300}"
LIMIT="${PLUTO_BOOTLOOP_LIMIT:-2}"
LABEL="${1:-launcher}"

mkdir -p "$STATE"
NOW="$(date +%s)"
CUTOFF="$((NOW - WINDOW_SECONDS))"
TMP="$LEDGER.tmp.$$"

if [ -f "$LEDGER" ]; then
  awk -v cutoff="$CUTOFF" '$1 >= cutoff { print }' "$LEDGER" > "$TMP"
else
  : > "$TMP"
fi

RECENT="$(wc -l < "$TMP" | tr -d ' ')"
if [ "$RECENT" -ge "$LIMIT" ]; then
  mv "$TMP" "$LEDGER"
  printf 'bootloop: refusing %s launch; %s launches in %ss\n' "$LABEL" "$RECENT" "$WINDOW_SECONDS" >&2
  exit 75
fi

printf '%s %s\n' "$NOW" "$LABEL" >> "$TMP"
mv "$TMP" "$LEDGER"
