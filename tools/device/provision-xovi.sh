#!/usr/bin/env bash
# Stage-0 provisioning: install xovi + qt-resource-rebuilder (bundled) + AppLoad
# onto the device and start the tethered xovi session, under a dead-man that runs
# `xovi/stock` (the correct recovery once xovi is extracted).
#
# SAFETY (verified against the upstream start/stock scripts):
#   - xovi is TETHERED: `start` mounts a tmpfs drop-in over
#     /etc/systemd/system/xochitl.service.d setting LD_PRELOAD=.../xovi.so; a
#     REBOOT auto-unmounts it -> stock xochitl. `xovi/stock` unmounts on demand.
#   - Everything lives under /home/root (writable); the read-only rootfs is untouched.
#   - Respects the xochitl StartLimitBurst=4/600s reboot trap (reset-failed first).
#
# Requires: the xovi bundle + appload zip in the local cache (see CACHE below).
# Usage: provision-xovi.sh [install|start|stock|status|uninstall]
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

CACHE="${PLUTO_CACHE:-$(cd ../../.pluto-cache && pwd)}/xovi"
XOVI_TGZ="$CACHE/xovi-aarch64.tar.gz"
APPLOAD_ZIP="$CACHE/appload-aarch64.zip"
DEADMAN_SECS="${DEADMAN_SECS:-90}"

arm_stock_deadman() {
  log "arming dead-man: xovi/stock in ${DEADMAN_SECS}s (restores stock if SSH lost)"
  rm_usb "systemctl stop pluto-deadman.timer pluto-deadman.service 2>/dev/null || true; \
          systemctl reset-failed 'pluto-deadman*' 2>/dev/null || true; \
          systemd-run --unit=pluto-deadman --on-active=${DEADMAN_SECS} \
            --timer-property=AccuracySec=1s \
            /bin/sh -c 'systemctl reset-failed xochitl.service 2>/dev/null||true; \
                        [ -x /home/root/xovi/stock ] && /home/root/xovi/stock || systemctl restart xochitl.service' \
            >/dev/null; echo armed"
}
disarm_deadman() {
  rm_usb "systemctl stop pluto-deadman.timer pluto-deadman.service 2>/dev/null || true; \
          systemctl reset-failed 'pluto-deadman*' 2>/dev/null || true; echo disarmed"
}

do_install() {
  [ -f "$XOVI_TGZ" ] || die "missing $XOVI_TGZ"
  [ -f "$APPLOAD_ZIP" ] || die "missing $APPLOAD_ZIP"
  log "uploading xovi bundle + appload"
  rm_usb 'cat > /tmp/xovi-aarch64.tar.gz' < "$XOVI_TGZ"
  rm_usb 'cat > /tmp/appload-aarch64.zip' < "$APPLOAD_ZIP"
  log "extracting xovi bundle to /home/root (only touches /home/root)"
  rm_usb 'cd /home/root && tar -xzf /tmp/xovi-aarch64.tar.gz'
  log "activating AppLoad extension + exthome"
  rm_usb 'cd /tmp && rm -rf appload && mkdir appload && (command -v unzip >/dev/null && unzip -o appload-aarch64.zip -d appload || bsdtar -xf appload-aarch64.zip -C appload); \
          cp appload/appload.so /home/root/xovi/extensions.d/appload.so; \
          mkdir -p /home/root/xovi/exthome/appload; \
          cp -r appload/shims /home/root/xovi/ 2>/dev/null || true; \
          echo "extensions.d:"; ls -1 /home/root/xovi/extensions.d/'
  log "install staged (xochitl NOT yet modified). Run: provision-xovi.sh start"
}

do_start() {
  log "reset-failed xochitl (clear start-limit counter)"
  rm_usb 'systemctl reset-failed xochitl.service 2>/dev/null || true'
  arm_stock_deadman
  log "running xovi/start (mounts tmpfs drop-in + restarts xochitl)"
  rm_usb 'cd /home/root && bash xovi/start' || { log "start failed; leaving dead-man to recover"; return 1; }
  log "waiting for xochitl to become active"
  rm_usb 'for i in $(seq 1 20); do [ "$(systemctl is-active xochitl.service)" = active ] && break; sleep 1; done; systemctl is-active xochitl.service'
  disarm_deadman
  log "xovi started. Verify on camera, then explore AppLoad. Recovery: provision-xovi.sh stock (or reboot)."
}

do_stock() { log "xovi/stock (unmount drop-in + restart stock xochitl)"; rm_any 'cd /home/root && bash xovi/stock 2>/dev/null || (umount -q /etc/systemd/system/xochitl.service.d; systemctl daemon-reload; systemctl reset-failed xochitl.service 2>/dev/null||true; systemctl restart xochitl.service); systemctl is-active xochitl.service'; }

do_status() {
  rm_usb 'echo "xochitl: $(systemctl is-active xochitl.service)"; \
          echo "xovi extracted: $([ -d /home/root/xovi ] && echo yes || echo no)"; \
          echo "drop-in mounted: $(mount | grep -q "xochitl.service.d" && echo yes || echo no)"; \
          echo "extensions.d: $(ls /home/root/xovi/extensions.d/ 2>/dev/null | tr "\n" " ")"'
}

do_uninstall() {
  do_stock
  log "removing /home/root/xovi (full stock restore)"
  rm_any 'rm -rf /home/root/xovi /tmp/xovi-aarch64.tar.gz /tmp/appload-aarch64.zip /tmp/appload; echo removed'
}

case "${1:-status}" in
  install) do_install ;;
  start)   do_start ;;
  stock)   do_stock ;;
  status)  do_status ;;
  uninstall) do_uninstall ;;
  *) die "usage: provision-xovi.sh {install|start|stock|status|uninstall}" ;;
esac
