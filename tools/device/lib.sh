#!/usr/bin/env bash
# Shared helpers for the Pluto device safety harness.
# Sourced by the other tools/device/*.sh scripts.
#
# Invariants:
#  - USB SSH (root@10.11.99.1, Dropbear) is the control channel; Wi-Fi is fallback.
#  - `systemctl reset-failed xochitl.service` before every (re)start.
#  - xochitl StartLimitBurst=4 / StartLimitIntervalSec=600 -> exceeding reboots
#    the device. Keep >=3 min between stop/start cycles; batch experiments.
#  - e-ink is bistable: a crash freezes the last image; restart xochitl to recover.
set -euo pipefail

RM_USB_HOST="${RM_USB_HOST:-root@10.11.99.1}"
RM_WIFI_HOST="${RM_WIFI_HOST:-root@192.168.1.74}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)

log() { printf '[harness %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# rmssh <host> <remote-command...> : run a command over SSH (key auth).
rmssh() { local host="$1"; shift; ssh "${SSH_OPTS[@]}" "$host" "$@"; }

# rm <remote-command...> : run on the USB host (the default control channel).
rm_usb() { rmssh "$RM_USB_HOST" "$@"; }
rm_wifi() { rmssh "$RM_WIFI_HOST" "$@"; }

# rm_any <remote-command...> : USB first, Wi-Fi fallback.
rm_any() {
  if rm_usb "$@" 2>/dev/null; then return 0; fi
  log "USB channel failed; trying Wi-Fi fallback"
  rm_wifi "$@"
}

# reachable <host> : true if the host answers a trivial command.
reachable() { rmssh "$1" 'echo ok' >/dev/null 2>&1; }
