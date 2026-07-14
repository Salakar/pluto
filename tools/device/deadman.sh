#!/usr/bin/env bash
# Dead-man switch: arm a systemd transient timer on the device that restarts
# xochitl even if the host loses SSH. AccuracySec=1s is MANDATORY (the systemd
# default 1-min accuracy fired a 3 s dead-man late in the prior project).
#
# Usage:
#   deadman.sh arm <seconds>   # (re)arm: xochitl auto-restarts in <seconds>
#   deadman.sh disarm          # cancel a pending dead-man (call on success)
#   deadman.sh status
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

UNIT="pluto-deadman"

cmd="${1:-}"; secs="${2:-90}"
case "$cmd" in
  arm)
    [ "$secs" -ge 5 ] 2>/dev/null || die "arm needs seconds >= 5 (got '${secs}')"
    log "arming dead-man: xochitl restart in ${secs}s (AccuracySec=1s)"
    rm_usb "systemctl stop ${UNIT}.timer ${UNIT}.service 2>/dev/null || true; \
            systemctl reset-failed '${UNIT}*' 2>/dev/null || true; \
            systemd-run --unit=${UNIT} --on-active=${secs} \
              --timer-property=AccuracySec=1s \
              /bin/sh -c 'systemctl reset-failed xochitl.service 2>/dev/null || true; systemctl restart xochitl.service' \
              >/dev/null; \
            echo armed"
    ;;
  disarm)
    log "disarming dead-man"
    rm_usb "systemctl stop ${UNIT}.timer ${UNIT}.service 2>/dev/null || true; \
            systemctl reset-failed '${UNIT}*' 2>/dev/null || true; echo disarmed"
    ;;
  status)
    rm_usb "systemctl list-timers ${UNIT}.timer --no-pager 2>/dev/null || echo 'no dead-man armed'"
    ;;
  *)
    die "usage: deadman.sh {arm <seconds>|disarm|status}"
    ;;
esac
