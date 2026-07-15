#!/bin/sh
# Full device-local Pluto uninstaller. Restores stock behavior.
set -eu

ROOT="${PLUTO_ROOT:-/home/root/pluto}"
HOME_ROOT="${PLUTO_HOME_ROOT:-/home/root}"
SYSTEM_ROOT="${PLUTO_SYSTEM_ROOT:-}"
SYSTEMCTL="${PLUTO_SYSTEMCTL:-systemctl}"
UMOUNT="${PLUTO_UMOUNT:-umount}"
RUN_ROOT="${PLUTO_RUN_ROOT:-/run/pluto}"
TMP_ROOT="${PLUTO_TMP_ROOT:-/tmp}"
DRY_RUN=0
KEEP_DATA=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --keep-data) KEEP_DATA=1 ;;
    --yes) ;;
    *) printf 'usage: pluto-uninstall.sh [--dry-run] [--keep-data] [--yes]\n' >&2; exit 64 ;;
  esac
  shift
done

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ %s\n' "$*"
  else
    "$@"
  fi
}

if [ "$DRY_RUN" -eq 0 ] && [ "${PLUTO_UNINSTALL_REEXEC:-0}" != "1" ]; then
  copy="/tmp/pluto-uninstall.$$.sh"
  cp "$0" "$copy"
  chmod 755 "$copy"
  set -- --yes
  [ "$KEEP_DATA" -eq 0 ] || set -- "$@" --keep-data
  PLUTO_UNINSTALL_REEXEC=1 exec "$copy" "$@"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  exec >> "$HOME_ROOT/pluto-uninstall.log" 2>&1
fi

printf 'Pluto uninstall started at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

run pkill -f pluto-embedder 2>/dev/null || true
run pkill -f plutod 2>/dev/null || true
run "$SYSTEMCTL" stop pluto-deadman.timer pluto-deadman.service 2>/dev/null || true
run "$SYSTEMCTL" reset-failed pluto-deadman.timer pluto-deadman.service 2>/dev/null || true

# AppLoad/XOVI/QTFB was never a published Pluto contract. Remove it before
# boot restoration so the boot installer's single xochitl restart loads only
# the pure stock unit, never a legacy preload whose files were just unlinked.
remove_retired_display_integration() {
  legacy_dropin_dir="$SYSTEM_ROOT/etc/systemd/system/xochitl.service.d"
  run "$UMOUNT" "$legacy_dropin_dir" 2>/dev/null || true
  for dropin_dir in \
    "$SYSTEM_ROOT/etc/systemd/system/xochitl.service.d" \
    "$SYSTEM_ROOT/run/systemd/system/xochitl.service.d" \
    "$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d"; do
    for dropin in "$dropin_dir"/*; do
      [ -f "$dropin" ] || continue
      if grep -Eiq 'xovi|appload|qtfb' "$dropin"; then
        run rm -f "$dropin"
      fi
    done
    run rmdir "$dropin_dir" 2>/dev/null || true
  done
  run rm -rf \
    "$HOME_ROOT/xovi" \
    "$HOME_ROOT/pluto-arm" \
    "$HOME_ROOT"/.pluto-xovi-* \
    "$HOME_ROOT"/.pluto-integration-* \
    "$HOME_ROOT"/.pluto-no-integration-stage \
    "$HOME_ROOT"/.pluto-uninstall-* \
    "$HOME_ROOT"/.pluto-restart-* \
    "$RUN_ROOT/integration-provision.lock" \
    "$RUN_ROOT/appload-control.sock" \
    "$TMP_ROOT"/qtfb.sock*
}

verify_retired_display_integration_absent() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  for forbidden in \
    "$HOME_ROOT/xovi" \
    "$HOME_ROOT/pluto-arm" \
    "$HOME_ROOT"/.pluto-xovi-* \
    "$HOME_ROOT"/.pluto-integration-* \
    "$HOME_ROOT"/.pluto-no-integration-stage \
    "$HOME_ROOT"/.pluto-uninstall-* \
    "$HOME_ROOT"/.pluto-restart-* \
    "$RUN_ROOT/integration-provision.lock" \
    "$RUN_ROOT/appload-control.sock" \
    "$TMP_ROOT"/qtfb.sock*; do
    if [ -e "$forbidden" ] || [ -L "$forbidden" ]; then
      printf 'ERROR: retired display integration residue remains: %s\n' \
        "$forbidden" >&2
      return 1
    fi
  done
  for dropin_dir in \
    "$SYSTEM_ROOT/etc/systemd/system/xochitl.service.d" \
    "$SYSTEM_ROOT/run/systemd/system/xochitl.service.d" \
    "$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d"; do
    if grep -Eil 'xovi|appload|qtfb' "$dropin_dir"/* >/dev/null 2>&1; then
      printf 'ERROR: retired display integration drop-in remains under %s\n' \
        "$dropin_dir" >&2
      return 1
    fi
  done
}

remove_retired_display_integration
verify_retired_display_integration_absent

# Boot-first drop-in (installed by pluto-boot-install.sh): remove it BEFORE
# deleting $ROOT on BOTH A/B root slots, or a later OTA-slot flip can point
# xochitl.service at a supervisor that no longer exists and boot without a UI.
BOOT_INSTALLER="$ROOT/bin/pluto-boot-install.sh"
DROPIN_DIR="$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d"
DROPIN="$DROPIN_DIR/zz-pluto.conf"

fallback_restore_live_boot() {
  printf 'WARNING: using live-slot-only boot restore fallback\n' >&2
  # The service currently runs OUR supervisor; stop it before restoring.
  run "$SYSTEMCTL" stop xochitl.service 2>/dev/null || true
  run pkill -f pluto-session.sh 2>/dev/null || true
  if [ -n "$SYSTEM_ROOT" ]; then
    run rm -f "$DROPIN"
    run rmdir "$DROPIN_DIR" 2>/dev/null || true
  elif run mount -o remount,rw /; then
    run rm -f "$DROPIN"
    run rmdir "$DROPIN_DIR" 2>/dev/null || true
    run sync
    run mount -o remount,ro / 2>/dev/null || true
  else
    return 1
  fi
  run "$SYSTEMCTL" daemon-reload 2>/dev/null || true
  run "$SYSTEMCTL" reset-failed xochitl.service 2>/dev/null || true
  run "$SYSTEMCTL" restart xochitl.service 2>/dev/null || true
}

restore_boot_slots() {
  # Dry-run remains side-effect-free and prints the authoritative A/B action
  # even when this host-side fixture does not contain a staged runtime.
  if [ "$DRY_RUN" -eq 1 ]; then
    run env PLUTO_ROOT="$ROOT" "$BOOT_INSTALLER" uninstall
    return 0
  fi
  if [ -x "$BOOT_INSTALLER" ] && \
      env PLUTO_ROOT="$ROOT" "$BOOT_INSTALLER" uninstall; then
    return 0
  fi

  # A legacy or damaged runtime may lack the installer. Restore stock on the
  # live slot, but report failure so the runtime remains available to any
  # inactive-slot override. Deleting it would turn the next slot flip into a
  # boot with no display service.
  fallback_restore_live_boot || true
  return 1
}

if ! restore_boot_slots; then
  printf 'ERROR: could not verify boot override removal on both A/B slots\n' >&2
  printf 'Pluto runtime preserved at %s; repair peer-slot access or the boot installer and retry\n' \
    "$ROOT" >&2
  exit 1
fi

run mkdir -p "$ROOT/state"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '+ printf disabled > %s/state/boot-mode\n' "$ROOT"
else
  printf '%s\n' disabled > "$ROOT/state/boot-mode"
fi

if [ "$KEEP_DATA" -eq 1 ] && [ -d "$ROOT" ]; then
  backup="$HOME_ROOT/pluto-data-backup-$(date +%Y%m%d%H%M%S)"
  run mkdir -p "$backup"
  [ ! -d "$ROOT/appdata" ] || run mv "$ROOT/appdata" "$backup/appdata"
  [ ! -d "$ROOT/shared" ] || run mv "$ROOT/shared" "$backup/shared"
fi

run rm -rf "$ROOT"

# pluto-boot-install.sh completed the stock handoff before runtime deletion.
# Verify that service instead of spending another xochitl restart allowance.
run "$SYSTEMCTL" is-active --quiet xochitl.service

printf 'Pluto uninstall finished at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
