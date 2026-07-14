#!/bin/sh
# Device-local dead-man timer used by provisioning and recovery paths.
set -eu

UNIT="${PLUTO_DEADMAN_UNIT:-pluto-deadman}"
ROOT="${PLUTO_ROOT:-/home/root/pluto}"
GUARD="$ROOT/bin/pluto-xochitl-guard.sh"

case "${1:-}" in
  arm)
    seconds="${2:-90}"
    [ "$seconds" -ge 5 ] 2>/dev/null || { printf 'arm needs seconds >= 5\n' >&2; exit 64; }
    systemctl stop "$UNIT.timer" "$UNIT.service" 2>/dev/null || true
    systemctl reset-failed "$UNIT.timer" "$UNIT.service" 2>/dev/null || true
    systemd-run --unit="$UNIT" --on-active="$seconds" \
      --timer-property=AccuracySec=1s \
      "$GUARD" restore >/dev/null
    ;;
  disarm)
    systemctl stop "$UNIT.timer" "$UNIT.service" 2>/dev/null || true
    systemctl reset-failed "$UNIT.timer" "$UNIT.service" 2>/dev/null || true
    ;;
  status)
    systemctl list-timers "$UNIT.timer" --no-pager 2>/dev/null || true
    ;;
  *)
    printf 'usage: pluto-deadman.sh {arm <seconds>|disarm|status}\n' >&2
    exit 64
    ;;
esac
