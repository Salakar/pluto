#!/bin/sh
# Full device-local Pluto uninstaller. Restores stock behavior.
set -eu

ROOT="${PLUTO_ROOT:-/home/root/pluto}"
HOME_ROOT="${PLUTO_HOME_ROOT:-/home/root}"
SYSTEM_ROOT="${PLUTO_SYSTEM_ROOT:-}"
SYSTEMCTL="${PLUTO_SYSTEMCTL:-systemctl}"
DRY_RUN=0
KEEP_DATA=0
REMOVE_XOVI=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --keep-data) KEEP_DATA=1 ;;
    --remove-xovi) REMOVE_XOVI=1 ;;
    --yes) ;;
    *) printf 'usage: pluto-uninstall.sh [--dry-run] [--keep-data] [--remove-xovi] [--yes]\n' >&2; exit 64 ;;
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
  [ "$REMOVE_XOVI" -eq 0 ] || set -- "$@" --remove-xovi
  PLUTO_UNINSTALL_REEXEC=1 exec "$copy" "$@"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  exec >> "$HOME_ROOT/pluto-uninstall.log" 2>&1
fi

printf 'Pluto uninstall started at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

GUARD="/tmp/pluto-xochitl-guard.$$.sh"
if [ -x "$ROOT/bin/pluto-xochitl-guard.sh" ]; then
  run cp "$ROOT/bin/pluto-xochitl-guard.sh" "$GUARD"
  run chmod 755 "$GUARD"
else
  GUARD=""
fi

run pkill -f pluto-embedder 2>/dev/null || true
run pkill -f plutod 2>/dev/null || true
run "$SYSTEMCTL" stop pluto-deadman.timer pluto-deadman.service 2>/dev/null || true
run "$SYSTEMCTL" reset-failed pluto-deadman.timer pluto-deadman.service 2>/dev/null || true

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
run rm -rf "$HOME_ROOT/xovi/exthome/appload/pluto"

if [ "$REMOVE_XOVI" -eq 1 ]; then
  run rm -rf "$HOME_ROOT/xovi"
fi

if [ "$KEEP_DATA" -eq 1 ] && [ -d "$ROOT" ]; then
  backup="$HOME_ROOT/pluto-data-backup-$(date +%Y%m%d%H%M%S)"
  run mkdir -p "$backup"
  [ ! -d "$ROOT/appdata" ] || run mv "$ROOT/appdata" "$backup/appdata"
  [ ! -d "$ROOT/shared" ] || run mv "$ROOT/shared" "$backup/shared"
fi

run rm -rf "$ROOT"

if [ -n "$GUARD" ] && [ -x "$GUARD" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    PLUTO_DRY_RUN=1 "$GUARD" restore
  else
    "$GUARD" restore
  fi
else
  run "$SYSTEMCTL" reset-failed xochitl.service 2>/dev/null || true
  run "$SYSTEMCTL" restart xochitl.service
fi

printf 'Pluto uninstall finished at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
