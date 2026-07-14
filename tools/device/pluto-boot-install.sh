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
PROFILE_FILE="${PLUTO_PROFILE_FILE:-$ROOT/share/device-profiles.sh}"
FW_PRINTENV="${PLUTO_FW_PRINTENV:-/usr/sbin/fw_printenv}"
FW_SETENV="${PLUTO_FW_SETENV:-/usr/sbin/fw_setenv}"
CMDLINE_FILE="${PLUTO_CMDLINE_FILE:-/proc/cmdline}"
SYNC="${PLUTO_SYNC:-sync}"

log() { printf '[pluto-boot %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
rootfs_rw() {
  [ -n "$SYSTEM_ROOT" ] && return 0
  mount -o remount,rw / 2>/dev/null || die "cannot remount rootfs rw"
}
rootfs_ro() {
  "$SYNC" || die "cannot sync rootfs transaction"
  [ -n "$SYSTEM_ROOT" ] || mount -o remount,ro / 2>/dev/null || true
}

# Canonical runtime layout (must match pluto-session.sh): never point the
# boot override at a runtime that cannot come up.
require_payload() {
  [ -x "$ROOT/bin/pluto-embedder" ] || die "missing $ROOT/bin/pluto-embedder"
  [ -x "$ROOT/bin/pluto-session.sh" ] || die "missing $ROOT/bin/pluto-session.sh"
  [ -x "$ROOT/bin/pluto-boot-confirm.sh" ] ||
    die "missing boot-recovery state machine: $ROOT/bin/pluto-boot-confirm.sh"
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
  "$SYNC" || rc=1
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

# Recovery must survive a missing or corrupt /home mount. The payload copy is
# only the installer source; the active state machine, immutable contract, and
# OnFailure service all live in the selected rootfs.
RECOVERY_HANDLER_REL=/usr/libexec/pluto-boot-recovery
RECOVERY_CONFIG_REL=/usr/lib/pluto/boot-recovery.conf
RECOVERY_FAILURE_UNIT_REL="$UNIT_DIR_REL/pluto-boot-failure.service"
RECOVERY_HANDLER="$SYSTEM_ROOT$RECOVERY_HANDLER_REL"
RECOVERY_CONFIG="$SYSTEM_ROOT$RECOVERY_CONFIG_REL"
RECOVERY_FAILURE_UNIT="$SYSTEM_ROOT$RECOVERY_FAILURE_UNIT_REL"

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

# ---- Profile-selected A/B slot awareness --------------------------------
# Move exposes root_a/root_b labels and confirms through its LPGPR helper.
# RM1/RM2 expose the same rescue concept through typed MMC partition numbers
# and U-Boot active/fallback variables. This is the only hardware branch in the
# common boot installer.
load_recovery_profile() {
  [ -n "${PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY:-}" ] && return 0
  [ -r "$PROFILE_FILE" ] || {
    log "generated device profile is missing: $PROFILE_FILE"
    return 1
  }
  # shellcheck source=generated/device-profiles.sh
  . "$PROFILE_FILE"
  if [ -n "${PLUTO_TEST_PROFILE_ID:-}" ]; then
    [ "${PLUTO_TESTING:-0}" = 1 ] &&
      pluto_profile_load "$PLUTO_TEST_PROFILE_ID" || return 1
  else
    pluto_profile_probe || return 1
  fi
}

boot_env_value() {
  [ -x "$FW_PRINTENV" ] || return 1
  value="$("$FW_PRINTENV" -n "$1" 2>/dev/null)" || return 1
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$value"
}

peer_root_dev() {  # echoes the inactive slot's block device, or empty
  load_recovery_profile || return 0
  case "$PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY" in
    lpgpr_counter)
      ra="$(readlink -f /dev/disk/by-partlabel/root_a 2>/dev/null)"
      rb="$(readlink -f /dev/disk/by-partlabel/root_b 2>/dev/null)"
      [ -n "$ra" ] && [ -n "$rb" ] || return 0
      cur="$(sed -n 's/.*[ ]root=\([^ ]*\).*/\1/p' "$CMDLINE_FILE" 2>/dev/null)"
      case "$cur" in
        "$ra") echo "$rb" ;;
        "$rb") echo "$ra" ;;
      esac
      ;;
    uboot_env)
      active="$(boot_env_value active_partition)" || return 0
      fallback="$(boot_env_value fallback_partition)" || return 0
      bootlimit="$(boot_env_value bootlimit)" || return 0
      [ "$bootlimit" = "$PLUTO_PROFILE_RECOVERY_BOOT_LIMIT" ] || return 0
      case ",${PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS}," in
        *",$active,"*) ;;
        *) return 0 ;;
      esac
      case ",${PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS}," in
        *",$fallback,"*) ;;
        *) return 0 ;;
      esac
      [ "$active" != "$fallback" ] || return 0
      cur="$(sed -n 's/.*[ ]root=\([^ ]*\).*/\1/p' "$CMDLINE_FILE" 2>/dev/null)"
      [ "$cur" = "${PLUTO_PROFILE_RECOVERY_MMC_DEVICE}p${active}" ] ||
        return 0
      printf '%s\n' "${PLUTO_PROFILE_RECOVERY_MMC_DEVICE}p${fallback}"
      ;;
    *) return 0 ;;
  esac
}

write_assignment() {  # $1 = fixed key, $2 = generated value
  escaped="$(printf '%s' "$2" | sed "s/'/'\\\\''/g")" || return 1
  printf "%s='%s'\n" "$1" "$escaped"
}

write_recovery_assets_under() {  # active rootfs only
  handler_tmp="$RECOVERY_HANDLER.tmp.$$"
  config_tmp="$RECOVERY_CONFIG.tmp.$$"
  unit_tmp="$RECOVERY_FAILURE_UNIT.tmp.$$"
  mkdir -p "$(dirname "$RECOVERY_HANDLER")" \
    "$(dirname "$RECOVERY_CONFIG")" "$UNIT_DIR" || return 1

  cp "$ROOT/bin/pluto-boot-confirm.sh" "$handler_tmp" || return 1
  chmod 0755 "$handler_tmp" || return 1
  mv "$handler_tmp" "$RECOVERY_HANDLER" || return 1

  {
    write_assignment PLUTO_RECOVERY_SCHEMA 1
    write_assignment PLUTO_RECOVERY_PROFILE_ID "$PLUTO_PROFILE_ID"
    write_assignment PLUTO_RECOVERY_CONFIRMATION_STRATEGY \
      "$PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY"
    write_assignment PLUTO_RECOVERY_FAILURE_STRATEGY \
      "$PLUTO_PROFILE_RECOVERY_FAILURE_STRATEGY"
    write_assignment PLUTO_RECOVERY_BOOT_DEFAULT_ENABLED \
      "$PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED"
    write_assignment PLUTO_RECOVERY_MMC_DEVICE \
      "$PLUTO_PROFILE_RECOVERY_MMC_DEVICE"
    write_assignment PLUTO_RECOVERY_ROOT_PARTITIONS \
      "$PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS"
    write_assignment PLUTO_RECOVERY_BOOT_LIMIT \
      "$PLUTO_PROFILE_RECOVERY_BOOT_LIMIT"
    write_assignment PLUTO_RECOVERY_HELPER \
      "$PLUTO_PROFILE_RECOVERY_HELPER"
    write_assignment PLUTO_RECOVERY_COUNTER_DIR \
      "$PLUTO_PROFILE_RECOVERY_COUNTER_DIR"
  } > "$config_tmp" || return 1
  chmod 0600 "$config_tmp" || return 1
  mv "$config_tmp" "$RECOVERY_CONFIG" || return 1

  cat > "$unit_tmp" <<EOF || return 1
[Unit]
Description=Pluto boot-default failure recovery
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=$RECOVERY_HANDLER_REL failure
EOF
  chmod 0644 "$unit_tmp" || return 1
  mv "$unit_tmp" "$RECOVERY_FAILURE_UNIT" || return 1
}

remove_recovery_assets_under() {
  rm -f "$RECOVERY_FAILURE_UNIT" "$RECOVERY_CONFIG" \
    "$RECOVERY_HANDLER" || return 1
  rmdir "$(dirname "$RECOVERY_CONFIG")" 2>/dev/null || true
}

run_recovery_action() {  # $1 = typed state-machine action
  [ -x "$RECOVERY_HANDLER" ] || {
    log "rootfs recovery handler is missing: $RECOVERY_HANDLER"
    return 1
  }
  [ -f "$RECOVERY_CONFIG" ] && [ ! -L "$RECOVERY_CONFIG" ] || {
    log "rootfs recovery contract is missing: $RECOVERY_CONFIG"
    return 1
  }
  PLUTO_BOOT_RECOVERY_CONFIG="$RECOVERY_CONFIG" \
    PLUTO_FW_PRINTENV="$FW_PRINTENV" \
    PLUTO_FW_SETENV="$FW_SETENV" \
    PLUTO_CMDLINE_FILE="$CMDLINE_FILE" \
    PLUTO_SYSTEMCTL="$SYSTEMCTL" \
    PLUTO_SYNC="$SYNC" \
      "$RECOVERY_HANDLER" "$1"
}

power_loss_at() {
  [ "${PLUTO_TESTING:-0}" = 1 ] || return 0
  [ "${PLUTO_TEST_POWER_LOSS_AT:-}" = "$1" ] || return 0
  log "injected power loss at durable boundary: $1"
  exit 97
}

failure_at() {
  [ "${PLUTO_TESTING:-0}" = 1 ] || return 1
  [ "${PLUTO_TEST_FAILURE_AT:-}" = "$1" ] || return 1
  log "injected transaction failure at: $1"
  return 0
}

# Writes the drop-in under a given root mountpoint ("" = live /). Returns
# nonzero on write failure so callers can report per-slot.
write_dropin_under() {  # $1 = root prefix (e.g. "" or /tmp/pluto-peer)
  d="$1$DROPIN_DIR_REL"
  target="$1$DROPIN_REL"
  temporary="$target.tmp.$$"
  mkdir -p "$d" || return 1
  failure_at boot_override_publish && return 1
  cat > "$temporary" <<EOF || return 1
# Installed by Pluto: run the Pluto session supervisor instead of xochitl.
[Unit]
# The supervisor and all release-AOT payloads live on the persistent home mount.
RequiresMountsFor=$ROOT
# Replace stock failure handling with Pluto's rootfs-resident A/B fallback.
OnFailure=
OnFailure=pluto-boot-failure.service

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
  chmod 0644 "$temporary" || return 1
  mv "$temporary" "$target"
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
  "$SYNC" || removed=0
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

remove_recovery_assets_durable() {
  rootfs_rw
  removed=1
  remove_recovery_assets_under || removed=0
  rootfs_ro
  [ "$removed" -eq 1 ]
}

rollback_armed_install() {
  # Restore the stock unit first. Only after that rootfs change is durable may
  # we clear the U-Boot transaction flag.
  rootfs_rw
  stock_restored=1
  remove_boot_artifacts_under "$SYSTEM_ROOT" || stock_restored=0
  remove_legacy_base_etc || stock_restored=0
  rootfs_ro
  [ "$stock_restored" -eq 1 ] || return 1
  run_recovery_action disarm || return 1
  remove_recovery_assets_durable
}

do_install() {
  mkdir -p "$STATE"
  require_payload
  [ -x "$SUPERVISOR" ] || die "supervisor not found/executable: $SUPERVISOR"
  load_recovery_profile || die "cannot load generated recovery profile"
  [ "$PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED" = 1 ] ||
    die "boot default is gated off for $PLUTO_PROFILE_ID; use --no-boot-default"
  # Preserve the peer as a stock rescue root before changing the selected one.
  # If this cannot be verified, do not install a boot override at all.
  restore_peer_stock_slot || die "cannot preserve peer-slot stock rescue"

  # Transaction phase 1: make the recovery code/config/service durable while
  # stock xochitl is still the live boot target.
  log "staging rootfs boot recovery before arming $PLUTO_PROFILE_ID"
  rootfs_rw
  "$SYSTEMCTL" disable pluto.service pluto-fallback.service 2>/dev/null || true
  staged=1
  remove_legacy_units_under "$SYSTEM_ROOT" || staged=0
  remove_legacy_base_etc || staged=0
  write_recovery_assets_under || staged=0
  rootfs_ro
  if [ "$staged" -ne 1 ]; then
    remove_recovery_assets_durable || true
    die "stage rootfs boot recovery"
  fi
  power_loss_at recovery_handler_durable

  # Transaction phase 2: bootcount is written first and upgrade_available is
  # the commit flag. The stock unit remains live at this boundary.
  if ! run_recovery_action arm; then
    if run_recovery_action disarm; then
      remove_recovery_assets_durable || true
    fi
    die "arm U-Boot fallback transaction"
  fi
  power_loss_at recovery_armed

  # Transaction phase 3: atomically publish the Pluto xochitl override only
  # after the fallback transaction and rootfs failure handler are durable.
  log "installing live-slot boot override: xochitl.service -> $SUPERVISOR"
  rootfs_rw
  install_boot_under "$SYSTEM_ROOT" || {
    rootfs_ro
    rollback_armed_install ||
      die "activation failed and automatic stock rollback was incomplete"
    die "install boot override (live slot)"
  }
  rootfs_ro
  power_loss_at boot_override_durable
  log "live slot: armed boot override installed; legacy units removed"
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
  had_recovery=0
  if [ -e "$RECOVERY_CONFIG" ] || [ -e "$RECOVERY_HANDLER" ] ||
     [ -e "$RECOVERY_FAILURE_UNIT" ]; then
    had_recovery=1
  fi

  # The stock service override must be durably restored before disarming. A
  # power loss at this point boots stock, while leaving the rescue flag armed.
  rootfs_rw
  "$SYSTEMCTL" disable pluto.service pluto-fallback.service 2>/dev/null || true
  live_removed=1
  remove_boot_artifacts_under "$SYSTEM_ROOT" || live_removed=0
  remove_legacy_base_etc || live_removed=0
  rootfs_ro
  [ "$live_removed" -eq 1 ] || die "live-slot boot override removal failed"
  power_loss_at stock_override_durable

  if [ "$had_recovery" -eq 1 ]; then
    run_recovery_action disarm ||
      die "stock is durable but Pluto recovery could not be disarmed"
    power_loss_at recovery_disarmed
  fi
  remove_recovery_assets_durable ||
    die "remove rootfs boot-recovery artifacts"

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
  printf 'rootfs recovery installed: %s\n' \
    "$([ -x "$RECOVERY_HANDLER" ] && [ -f "$RECOVERY_CONFIG" ] && echo yes || echo no)"
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
