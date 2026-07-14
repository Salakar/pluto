#!/bin/sh
# Pluto boot-first installer (device-side, our own stack — no AppLoad/xovi).
# Overrides xochitl.service so the session supervisor (launcher) owns the panel
# from boot instead of stock xochitl. Idempotent, including migration away from
# the obsolete standalone pluto.service/pluto-fallback.service units.
#
# Usage: pluto-boot-install.sh {install|uninstall|status|validate}
#   install   -> override xochitl on the live slot; keep peer stock for rescue
#   uninstall -> remove Pluto boot artifacts from both slots (back to stock)
#   status    -> report what is installed / what boots
#   validate  -> verify the staged launcher/runtime without changing the device
set -u

ROOT="${PLUTO_ROOT:-/home/root/pluto}"
# The rootfs /usr is the only persistent systemd location: /etc is an overlay
# whose upper (/var/volatile/etc) is wiped every boot, so units written there
# vanish. We install into the rootfs and toggle it read-write around the change.
SYSTEM_ROOT="${PLUTO_SYSTEM_ROOT:-}"
UNIT_DIR_REL=/usr/lib/systemd/system
UNIT_DIR="$SYSTEM_ROOT$UNIT_DIR_REL"
WANTS_DIR="$UNIT_DIR/multi-user.target.wants"
STATE="$ROOT/state"
SYSTEMCTL="${PLUTO_SYSTEMCTL:-systemctl}"
PEER_ROOT_OVERRIDE="${PLUTO_PEER_ROOT:-}"

log() { printf '[pluto-boot %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
rootfs_rw() {
  [ -n "$SYSTEM_ROOT" ] && return 0
  mount -o remount,rw / 2>/dev/null || die "cannot remount rootfs rw"
}
rootfs_ro() {
  sync
  [ -n "$SYSTEM_ROOT" ] || mount -o remount,ro / 2>/dev/null || true
}

# Canonical runtime layout (must match pluto-session.sh): never point the
# boot override at a runtime that cannot come up.
require_payload() {
  [ -x "$ROOT/bin/pluto-embedder" ] || die "missing $ROOT/bin/pluto-embedder"
  [ -x "$ROOT/bin/pluto-session.sh" ] || die "missing $ROOT/bin/pluto-session.sh"
  [ -d "$ROOT/launcher/bundle" ] || die "missing launcher bundle at $ROOT/launcher/bundle"
  [ -f "$ROOT/launcher/bundle/lib/app.so" ] || \
    [ -f "$ROOT/launcher/bundle/app.so" ] || \
    die "boot launcher must be release AOT (missing app.so)"
  [ ! -f "$ROOT/launcher/bundle/flutter_assets/kernel_blob.bin" ] || \
    die "boot launcher must be release AOT (debug kernel present)"
  if [ -f "$ROOT/launcher/install.json" ]; then
    grep -q '"buildMode"[[:space:]]*:[[:space:]]*"release"' \
      "$ROOT/launcher/install.json" || \
      die "boot launcher install record is not release"
    grep -q '"engineFlavor"[[:space:]]*:[[:space:]]*"release"' \
      "$ROOT/launcher/install.json" || \
      die "boot launcher engine flavor is not release"
  fi
  [ -f "$ROOT/engine/release/libflutter_engine.so" ] || \
    die "missing $ROOT/engine/release/libflutter_engine.so"
}

# Edit the persistent BASE /etc (the overlay lowerdir) via a non-recursive bind
# of the rootfs — the boot-time /etc reset restores from here, so changes persist.
with_base_etc() {  # $1 = shell snippet operating on $BW
  local BIND=/home/root/plroot BS BW rc
  mkdir -p "$BIND" || return 1
  mount --bind / "$BIND" || return 1
  BS="$BIND/etc/systemd/system"
  BW="$BS/multi-user.target.wants"
  rc=0
  eval "$1" || rc=1
  sync
  umount "$BIND" 2>/dev/null || rc=1
  rmdir "$BIND" 2>/dev/null || true
  return "$rc"
}

# The reMarkable display service (xochitl.service) starts reliably on boot no
# matter what (base enable, D-Bus/target activation). Rather than fight to
# disable it, we override its ExecStart via a PERSISTENT drop-in in the rootfs
# so that service launches the Pluto supervisor instead of reMarkable's UI.
DROPIN_DIR="$UNIT_DIR/xochitl.service.d"
DROPIN="$DROPIN_DIR/zz-pluto.conf"
DROPIN_DIR_REL="$UNIT_DIR_REL/xochitl.service.d"
DROPIN_REL="$DROPIN_DIR_REL/zz-pluto.conf"
# The supervisor to run at boot. Defaults to the canonical runtime layout; the
# CLI passes PLUTO_SUPERVISOR to match wherever the runtime was staged.
SUPERVISOR="${PLUTO_SUPERVISOR:-$ROOT/bin/pluto-session.sh}"

# Older Pluto revisions installed separate services. Those units race the
# xochitl.service override and can start a second supervisor after boot. Remove
# only these exact Pluto-owned artifacts; no unrelated unit is touched.
remove_legacy_units_under() {  # $1 = root prefix
  local prefix="$1" failed=0 unit path
  for unit in pluto.service pluto-fallback.service; do
    for path in \
      "$prefix$UNIT_DIR_REL/$unit" \
      "$prefix$UNIT_DIR_REL/multi-user.target.wants/$unit" \
      "$prefix/etc/systemd/system/$unit" \
      "$prefix/etc/systemd/system/multi-user.target.wants/$unit"
    do
      if [ -e "$path" ] || [ -L "$path" ]; then
        rm -f "$path" || failed=1
      fi
    done
  done
  [ "$failed" -eq 0 ]
}

# On the live device /etc is an ephemeral overlay. Also remove any enablement
# links from its persistent lower directory so they cannot return after reboot.
remove_legacy_base_etc() {
  [ -n "$SYSTEM_ROOT" ] && return 0
  with_base_etc \
    'rm -f "$BS/pluto.service" "$BS/pluto-fallback.service" \
      "$BW/pluto.service" "$BW/pluto-fallback.service"'
}

# ---- A/B slot awareness (device-verified 2026-07-09) --------------------
# The rootfs is one of two OTA A/B slots (root_a=/dev/…p2, root_b=/dev/…p3).
# The supervisor waits for a successful release-UI present and a stable-start
# delay before invoking the firmware-owned rm-reset-boot-count.sh helper. The
# peer slot is deliberately kept stock: if the selected root cannot confirm
# three boots, U-Boot still has a known-good rescue UI instead of repeating the
# same Pluto failure on both roots.
peer_root_dev() {  # echoes the inactive slot's block device, or empty
  ra="$(readlink -f /dev/disk/by-partlabel/root_a 2>/dev/null)"
  rb="$(readlink -f /dev/disk/by-partlabel/root_b 2>/dev/null)"
  [ -n "$ra" ] && [ -n "$rb" ] || return 0
  cur="$(sed -n 's/.*[ ]root=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null)"
  case "$cur" in
    "$ra") echo "$rb" ;;
    "$rb") echo "$ra" ;;
    *) return 0 ;;  # Unknown current root: refuse to guess which slot is safe.
  esac
}

# Writes the drop-in under a given root mountpoint ("" = live /). Returns
# nonzero on write failure so callers can report per-slot.
write_dropin_under() {  # $1 = root prefix (e.g. "" or /tmp/pluto-peer)
  d="$1$DROPIN_DIR_REL"
  mkdir -p "$d" || return 1
  cat > "$1$DROPIN_REL" <<EOF || return 1
# Installed by Pluto: run the Pluto session supervisor instead of xochitl.
[Unit]
# The supervisor and all release-AOT payloads live on the persistent home mount.
RequiresMountsFor=$ROOT
# Never drop to emergency.target if Pluto exits; the supervisor self-recovers.
OnFailure=

[Service]
# Stock xochitl expects sd_notify watchdog heartbeats and restarts on failure.
# The Pluto supervisor has its own recovery policy, so clear both inherited
# behaviors rather than entering a 60-second watchdog/start-limit loop.
WatchdogSec=0
Restart=no
Environment=PLUTO_ROOT=$ROOT
ExecStart=
ExecStart=$SUPERVISOR start
EOF
  return 0
}

install_boot_under() {  # $1 = root prefix
  remove_legacy_units_under "$1" || return 1
  write_dropin_under "$1"
}

remove_boot_artifacts_under() {  # $1 = root prefix
  local failed=0
  remove_dropin_under "$1" || failed=1
  remove_legacy_units_under "$1" || failed=1
  [ "$failed" -eq 0 ]
}

remove_dropin_under() {  # $1 = root prefix
  rm -f "$1$DROPIN_REL" || return 1
  rmdir "$1$DROPIN_DIR_REL" 2>/dev/null || true
  [ ! -e "$1$DROPIN_REL" ]
}

restore_peer_stock_slot() {
  if [ -n "$PEER_ROOT_OVERRIDE" ]; then
    [ -d "$PEER_ROOT_OVERRIDE$UNIT_DIR_REL" ] || {
      log "peer fixture: not a rootfs; cannot preserve stock rescue"
      return 1
    }
    if remove_boot_artifacts_under "$PEER_ROOT_OVERRIDE"; then
      log "peer fixture: stock rescue preserved; Pluto artifacts removed"
      return 0
    fi
    log "peer fixture: stock-rescue cleanup failed"
    return 1
  fi
  peer="$(peer_root_dev)"
  [ -n "$peer" ] || {
    log "peer slot: none detected; cannot verify stock rescue"
    return 1
  }
  [ -b "$peer" ] || {
    log "peer slot $peer is not a block device; cannot verify stock rescue"
    return 1
  }
  PM=/tmp/pluto-peer
  mkdir -p "$PM"
  if ! mount "$peer" "$PM" 2>/dev/null; then
    log "peer slot $peer: mount failed; cannot verify stock rescue"
    rmdir "$PM" 2>/dev/null || true
    return 1
  fi
  removed=0
  if [ -d "$PM$UNIT_DIR_REL" ] && remove_boot_artifacts_under "$PM"; then
    removed=1
  else
    log "peer slot $peer: stock-rescue cleanup failed"
  fi
  sync
  unmounted=0
  if umount "$PM" 2>/dev/null || umount -l "$PM" 2>/dev/null; then
    unmounted=1
  else
    log "peer slot $peer: unmount failed"
  fi
  rmdir "$PM" 2>/dev/null || true
  if [ "$removed" -eq 1 ] && [ "$unmounted" -eq 1 ]; then
    log "peer slot $peer: stock rescue verified; Pluto artifacts removed"
    return 0
  fi
  return 1
}

do_install() {
  mkdir -p "$STATE"
  require_payload
  [ -x "$SUPERVISOR" ] || die "supervisor not found/executable: $SUPERVISOR"
  # Preserve the peer as a stock rescue root before changing the selected one.
  # If this cannot be verified, do not install a boot override at all.
  restore_peer_stock_slot || die "cannot preserve peer-slot stock rescue"
  log "installing live-slot boot override: xochitl.service -> $SUPERVISOR"
  rootfs_rw
  # Disable by name first so systemd drops any overlay enablement link. Do not
  # stop a currently running legacy session mid-provision; deletion plus the
  # daemon reload prevents it from returning on the next boot.
  "$SYSTEMCTL" disable pluto.service pluto-fallback.service 2>/dev/null || true
  install_boot_under "$SYSTEM_ROOT" || {
    rootfs_ro
    die "install boot override / remove legacy units (live slot)"
  }
  remove_legacy_base_etc || {
    rootfs_ro
    die "remove persistent legacy service enablement (live slot)"
  }
  rootfs_ro
  log "live slot: boot override installed; legacy units removed"
  "$SYSTEMCTL" daemon-reload || true
  # A previous watchdog loop may have exhausted the firmware unit's start
  # limit. The corrected non-restarting override must be startable immediately.
  "$SYSTEMCTL" reset-failed xochitl.service 2>/dev/null || true
  "$SYSTEMCTL" reset-failed pluto.service pluto-fallback.service 2>/dev/null || true
  echo launcher > "$STATE/boot-mode"; echo yes > "$STATE/boot-first"
  log "installed. Normal boots use Pluto; the peer A/B root remains stock"
  log "for rescue. 'exit to stock' / --uninstall restore live xochitl too."
}

do_uninstall() {
  log "restoring stock reMarkable UI (removing boot override, both slots)"
  rootfs_rw
  "$SYSTEMCTL" disable pluto.service pluto-fallback.service 2>/dev/null || true
  live_removed=1
  remove_boot_artifacts_under "$SYSTEM_ROOT" || live_removed=0
  remove_legacy_base_etc || live_removed=0
  rootfs_ro
  [ "$live_removed" -eq 1 ] || die "live-slot boot override removal failed"
  peer_removed=0
  restore_peer_stock_slot && peer_removed=1
  "$SYSTEMCTL" daemon-reload || true
  "$SYSTEMCTL" reset-failed xochitl.service 2>/dev/null || true
  "$SYSTEMCTL" restart xochitl.service 2>/dev/null || true
  [ "$peer_removed" -eq 1 ] || \
    die "peer-slot stock rescue could not be verified; keeping Pluto runtime"
  rm -f "$STATE/boot-mode" "$STATE/boot-first"
  log "uninstalled. Stock xochitl restored on both slots."
}

do_status() {
  installed=no
  [ -f "$DROPIN" ] && installed=yes
  printf 'pluto boot override installed (persistent): %s\n' "$installed"
  printf 'display service (xochitl.service) runs: %s\n' \
    "$([ "$installed" = yes ] && echo 'Pluto supervisor' || echo 'stock xochitl')"
  printf 'xochitl.service active: %s\n' "$("$SYSTEMCTL" is-active xochitl.service 2>/dev/null)"
  printf 'boots first: %s\n' "$([ "$installed" = yes ] && echo Pluto || echo xochitl)"
  [ -f "$STATE/boot-mode" ] && printf 'boot-mode: %s\n' "$(cat "$STATE/boot-mode")"
}

case "${1:-status}" in
  install) do_install ;;
  uninstall) do_uninstall ;;
  status) do_status ;;
  validate)
    require_payload
    log "release AOT launcher payload validated"
    ;;
  *) echo "usage: $0 {install|uninstall|status|validate}"; exit 64 ;;
esac
