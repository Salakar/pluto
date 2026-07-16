#!/bin/sh
# Full device-local Pluto uninstaller. Restores stock behavior.
set -eu

ROOT="${PLUTO_ROOT:-/home/root/pluto}"
RELEASES_ROOT="${PLUTO_RELEASES_ROOT:-${ROOT}.releases}"
DATA_ROOT="${PLUTO_DATA_ROOT:-${ROOT}.data}"
HOME_ROOT="${PLUTO_HOME_ROOT:-/home/root}"
SYSTEM_ROOT="${PLUTO_SYSTEM_ROOT:-}"
SYSTEMCTL="${PLUTO_SYSTEMCTL:-systemctl}"
RUN_DIR="${PLUTO_RUN_DIR:-/run/pluto}"
RUNTIME_UNITS="${PLUTO_SYSTEMD_RUNTIME_DIR:-/run/systemd/system}"
ONCE_UNIT="$RUNTIME_UNITS/pluto-session-once.service"
PROFILE_FILE="${PLUTO_PROFILE_FILE:-$ROOT/share/device-profiles.sh}"
CPU_FREQUENCY_RESTORE="$ROOT/bin/pluto-rm2-cpufreq-restore.sh"
TESTING="${PLUTO_TESTING:-0}"
DISPLAY_DRIVER=
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

safe_token() {
  case "$1" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; *) return 0 ;; esac
}

safe_absolute_path() {
  case "$1" in /*) ;; *) return 1 ;; esac
  [ "$1" != / ] || return 1
  case "$1" in
    *[!A-Za-z0-9_./-]*|*/../*|*/..|*/./*|*/.|*//*) return 1 ;;
  esac
}

load_profile() {
  safe_absolute_path "$PROFILE_FILE" || return 1
  [ -r "$PROFILE_FILE" ] || return 1
  # shellcheck source=generated/device-profiles.sh
  . "$PROFILE_FILE"
  if [ -n "${PLUTO_TEST_PROFILE_ID:-}" ]; then
    [ "$TESTING" = 1 ] && pluto_profile_load "$PLUTO_TEST_PROFILE_ID" ||
      return 1
  else
    pluto_profile_probe || return 1
  fi
  case "${PLUTO_PROFILE_DISPLAY_DRIVER:-}" in
    gallery3_drm | lcdif_tcon | mxcfb_epdc)
      DISPLAY_DRIVER=$PLUTO_PROFILE_DISPLAY_DRIVER
      ;;
    *) return 1 ;;
  esac
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

file_uid() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null
}

validate_ephemeral_layout() {
  safe_absolute_path "$RUN_DIR" && safe_absolute_path "$RUNTIME_UNITS" ||
    return 1
  effective_uid=$(id -u 2>/dev/null) || return 1
  case "$effective_uid" in ''|*[!0-9]*) return 1 ;; esac

  if [ -e "$RUN_DIR" ] || [ -L "$RUN_DIR" ]; then
    [ -d "$RUN_DIR" ] && [ ! -L "$RUN_DIR" ] || return 1
    [ "$(file_uid "$RUN_DIR")" = "$effective_uid" ] || return 1
    run_mode=$(file_mode "$RUN_DIR") || return 1
    case "$run_mode" in [0-7][0-7][0-7]) ;; *) return 1 ;; esac
    [ $((0$run_mode & 022)) -eq 0 ] || return 1
  fi

  if [ -e "$ONCE_UNIT" ] || [ -L "$ONCE_UNIT" ]; then
    [ -f "$ONCE_UNIT" ] && [ ! -L "$ONCE_UNIT" ] || return 1
    [ "$(file_uid "$ONCE_UNIT")" = "$effective_uid" ] || return 1
  fi
}

validate_owned_layout() {
  [ -L "$ROOT" ] || return 1
  active_release="$(readlink "$ROOT" 2>/dev/null)" || return 1
  case "$active_release" in "$RELEASES_ROOT"/*) ;; *) return 1 ;; esac
  release_name=${active_release#"$RELEASES_ROOT"/}
  safe_token "$release_name" || return 1
  case "$release_name" in */*) return 1 ;; esac
  [ -d "$active_release" ] && [ ! -L "$active_release" ] || return 1
  [ -f "$active_release/.pluto-release-owned" ] &&
    [ ! -L "$active_release/.pluto-release-owned" ] || return 1
  [ "$(cat "$active_release/.pluto-release-owned" 2>/dev/null)" = \
    "$release_name" ] || return 1
  [ -d "$RELEASES_ROOT" ] && [ ! -L "$RELEASES_ROOT" ] || return 1
  [ -d "$DATA_ROOT" ] && [ ! -L "$DATA_ROOT" ] || return 1
  for mutable in appdata logs state staging shared; do
    [ -d "$DATA_ROOT/$mutable" ] && [ ! -L "$DATA_ROOT/$mutable" ] ||
      return 1
    [ -L "$active_release/$mutable" ] || return 1
    [ "$(readlink "$active_release/$mutable" 2>/dev/null)" = \
      "$DATA_ROOT/$mutable" ] || return 1
  done
}

load_profile || {
  printf 'ERROR: exact generated device profile is unavailable; refusing uninstall\n' >&2
  exit 1
}

if [ "$DRY_RUN" -eq 0 ]; then
  validate_owned_layout || {
    printf 'ERROR: Pluto root/store/data ownership is not exact; refusing destructive uninstall\n' >&2
    exit 1
  }
  validate_ephemeral_layout || {
    printf 'ERROR: Pluto runtime state ownership is not exact; refusing destructive uninstall\n' >&2
    exit 1
  }
fi

# A recovery-gated profile can be running through the runtime-only current-boot
# service. Retire that supervisor before replacing boot policy or deleting its
# binaries. The helper's stop path restores stock; the final check below still
# verifies the result.
ONCE_SESSION="$ROOT/bin/pluto-session-once.sh"
if [ "$DRY_RUN" -eq 1 ] || \
   [ -e "$ONCE_UNIT" ] || \
   "$SYSTEMCTL" is-active --quiet pluto-session-once.service 2>/dev/null; then
  if [ -x "$ONCE_SESSION" ]; then
    run env PLUTO_ROOT="$ROOT" PLUTO_RUN_DIR="$RUN_DIR" \
      PLUTO_SYSTEMD_RUNTIME_DIR="$RUNTIME_UNITS" \
      PLUTO_SYSTEMCTL="$SYSTEMCTL" \
      sh "$ONCE_SESSION" stop
  else
    run "$SYSTEMCTL" stop pluto-session-once.service 2>/dev/null || true
    run "$SYSTEMCTL" reset-failed xochitl.service 2>/dev/null || true
    run "$SYSTEMCTL" start xochitl.service
  fi
fi

run pkill -f pluto-embedder 2>/dev/null || true

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
  if [ "$DISPLAY_DRIVER" = lcdif_tcon ] &&
     { [ "$DRY_RUN" -eq 1 ] || [ -e "$RUN_DIR" ]; }; then
    [ -x "$CPU_FREQUENCY_RESTORE" ] || return 1
    run "$CPU_FREQUENCY_RESTORE" || return 1
  fi
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
  if [ -x "$BOOT_INSTALLER" ]; then
    if env PLUTO_ROOT="$ROOT" PLUTO_RUN_DIR="$RUN_DIR" \
        "$BOOT_INSTALLER" uninstall; then
      return 0
    fi
    return 1
  fi

  # A damaged runtime may lack the installer. Restore stock on the live slot,
  # but report failure so the runtime remains available to any inactive-slot
  # override. Deleting it would turn the next slot flip into a boot with no
  # display service.
  fallback_restore_live_boot || true
  return 1
}

if ! restore_boot_slots; then
  printf 'ERROR: could not verify boot override removal on both A/B slots\n' >&2
  printf 'Pluto runtime preserved at %s; repair peer-slot access or the boot installer and retry\n' \
    "$ROOT" >&2
  exit 1
fi

# The boot transaction has proven stock active and released its runtime lock.
# Revalidate the exact ephemeral root against replacement races, then remove
# all controls, screenshots, locks, and crash receipts in one hard cut.
if [ "$DRY_RUN" -eq 0 ]; then
  validate_ephemeral_layout || {
    printf 'ERROR: Pluto runtime state changed during uninstall; preserving runtime\n' >&2
    exit 1
  }
fi
run rm -rf "$RUN_DIR"

run mkdir -p "$DATA_ROOT/state"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '+ printf disabled > %s/state/boot-mode\n' "$DATA_ROOT"
else
  printf '%s\n' disabled > "$DATA_ROOT/state/boot-mode"
fi

if [ "$KEEP_DATA" -eq 1 ] && [ -d "$DATA_ROOT" ]; then
  backup="$HOME_ROOT/pluto-data-backup-$(date +%Y%m%d%H%M%S)"
  run mkdir -p "$backup"
  [ ! -d "$DATA_ROOT/appdata" ] || run mv "$DATA_ROOT/appdata" "$backup/appdata"
  [ ! -d "$DATA_ROOT/shared" ] || run mv "$DATA_ROOT/shared" "$backup/shared"
fi

run rm -f "$ROOT"

# Delete only release directories carrying their exact per-release ownership
# receipt. Unknown siblings are preserved rather than guessed to be Pluto's.
for release in "$RELEASES_ROOT"/* "$RELEASES_ROOT"/.candidate-*; do
  [ -d "$release" ] && [ ! -L "$release" ] || continue
  name=${release#"$RELEASES_ROOT"/}
  owner=$(cat "$release/.pluto-release-owned" 2>/dev/null || true)
  safe_token "$owner" || continue
  case "$name" in
    "$owner"|.candidate-"$owner") run rm -rf "$release" ;;
  esac
done
run rmdir "$RELEASES_ROOT" 2>/dev/null || true

# These five directories are the mutable roots referenced by every validated
# release. Remove those exact paths, then remove the container only if no
# unknown sibling remains.
for mutable in appdata logs state staging shared; do
  run rm -rf "$DATA_ROOT/$mutable"
done
run rmdir "$DATA_ROOT" 2>/dev/null || true

# pluto-boot-install.sh completed the stock handoff before runtime deletion.
# Verify that service instead of spending another xochitl restart allowance.
run "$SYSTEMCTL" is-active --quiet xochitl.service

printf 'Pluto uninstall finished at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
