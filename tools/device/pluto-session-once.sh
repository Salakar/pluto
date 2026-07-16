#!/bin/sh
# Runtime-only Pluto activation for a profile whose persistent boot-default
# recovery gate is closed. The transient service owns the current panel session;
# its stop/failure path restarts stock xochitl, and /run disappears on reboot.
set -u

ROOT="${PLUTO_ROOT:-/home/root/pluto}"
RUN_DIR="${PLUTO_RUN_DIR:-/run/pluto}"
SYSTEMCTL="${PLUTO_SYSTEMCTL:-systemctl}"
RUNTIME_UNITS="${PLUTO_SYSTEMD_RUNTIME_DIR:-/run/systemd/system}"
PROFILE_FILE="${PLUTO_PROFILE_FILE:-$ROOT/share/device-profiles.sh}"
UNIT_NAME=pluto-session-once.service
UNIT="$RUNTIME_UNITS/$UNIT_NAME"
SUPERVISOR="$ROOT/bin/pluto-session.sh"
SESSION_ONCE="$ROOT/bin/pluto-session-once.sh"
CPU_FREQUENCY_RESTORE="$ROOT/bin/pluto-rm2-cpufreq-restore.sh"
DISPLAY_DRIVER=

log() { printf '[pluto-once %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

safe_path() {
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9_./-]*|*/../*|*/..|*/./*|*/.) return 1 ;;
  esac
}

safe_root() {
  safe_path "$ROOT" && safe_path "$RUN_DIR" && safe_path "$PROFILE_FILE"
}

load_profile() {
  safe_root || die "unsafe Pluto runtime path"
  [ -r "$PROFILE_FILE" ] || die "missing generated profile: $PROFILE_FILE"
  # shellcheck source=generated/device-profiles.sh
  . "$PROFILE_FILE"
  if [ -n "${PLUTO_TEST_PROFILE_ID:-}" ]; then
    [ "${PLUTO_TESTING:-0}" = 1 ] ||
      die "test profile override is forbidden outside test mode"
    pluto_profile_load "$PLUTO_TEST_PROFILE_ID" ||
      die "unknown test profile: $PLUTO_TEST_PROFILE_ID"
  else
    pluto_profile_probe || die "device identity did not match one exact profile"
  fi
  [ "${PLUTO_PROFILE_NATIVE_SESSION_ENABLED:-}" = 1 ] ||
    die "native session is not enabled for the exact profile"
  case "${PLUTO_PROFILE_DISPLAY_DRIVER:-}" in
    gallery3_drm | lcdif_tcon | mxcfb_epdc)
      DISPLAY_DRIVER=$PLUTO_PROFILE_DISPLAY_DRIVER
      ;;
    *) die "generated profile has an invalid display driver" ;;
  esac
}

restore_cpu_frequency() {
  [ "$DISPLAY_DRIVER" = lcdif_tcon ] || return 0
  [ -x "$CPU_FREQUENCY_RESTORE" ] || {
    log "ERROR: RM2 CPU-frequency restorer is unavailable"
    return 1
  }
  "$CPU_FREQUENCY_RESTORE"
}

restore_stock() {
  restore_cpu_frequency || {
    log "ERROR: refusing stock restart with an unresolved CPU-frequency receipt"
    return 1
  }
  "$SYSTEMCTL" reset-failed xochitl.service 2>/dev/null || true
  "$SYSTEMCTL" start xochitl.service 2>/dev/null
}

remove_unit() {
  rm -f "$UNIT" "$UNIT.tmp.$$"
  "$SYSTEMCTL" daemon-reload 2>/dev/null || true
}

do_start() {
  [ -x "$SUPERVISOR" ] || die "missing executable supervisor: $SUPERVISOR"
  [ -x "$SESSION_ONCE" ] || die "missing executable session helper: $SESSION_ONCE"
  if [ "$DISPLAY_DRIVER" = lcdif_tcon ]; then
    [ -x "$CPU_FREQUENCY_RESTORE" ] ||
      die "missing executable CPU-frequency restorer: $CPU_FREQUENCY_RESTORE"
  fi
  mkdir -p "$RUNTIME_UNITS" "$RUN_DIR" ||
    die "cannot create transient runtime directories"

  # Retire an earlier one-shot session before replacing its runtime-only unit.
  "$SYSTEMCTL" stop "$UNIT_NAME" 2>/dev/null || true
  rm -f "$UNIT" "$UNIT.tmp.$$"
  cat > "$UNIT.tmp.$$" <<EOF || die "cannot stage transient service"
[Unit]
Description=Pluto current-boot native session
Conflicts=xochitl.service
After=local-fs.target
StartLimitIntervalSec=600
StartLimitBurst=2

[Service]
Type=simple
Environment=PLUTO_ROOT=$ROOT
Environment=PLUTO_RUN_DIR=$RUN_DIR
ExecStart=$SUPERVISOR start
ExecStopPost=$SESSION_ONCE restore-stock
Restart=no
KillMode=control-group
EOF
  chmod 0644 "$UNIT.tmp.$$" || die "cannot secure transient service"
  mv "$UNIT.tmp.$$" "$UNIT" || die "cannot publish transient service"
  "$SYSTEMCTL" daemon-reload || {
    remove_unit
    restore_stock
    die "systemd rejected the transient service"
  }
  "$SYSTEMCTL" reset-failed "$UNIT_NAME" 2>/dev/null || true
  if ! "$SYSTEMCTL" start "$UNIT_NAME" ||
     ! "$SYSTEMCTL" is-active --quiet "$UNIT_NAME"; then
    "$SYSTEMCTL" stop "$UNIT_NAME" 2>/dev/null || true
    remove_unit
    restore_stock
    die "one-shot Pluto supervisor did not become active"
  fi
  log "current-boot Pluto session active; stock remains the next boot default"
}

do_stop() {
  "$SYSTEMCTL" stop "$UNIT_NAME" 2>/dev/null || true
  remove_unit
  restore_stock || die "stock xochitl did not restart"
  log "one-shot Pluto session stopped; stock xochitl requested"
}

case "${1:-status}" in
  start) load_profile; do_start ;;
  stop) load_profile; do_stop ;;
  restore-stock) load_profile; restore_stock ;;
  status)
    load_profile
    if [ -f "$UNIT" ] && "$SYSTEMCTL" is-active --quiet "$UNIT_NAME"; then
      echo "one-shot Pluto session: active"
    else
      echo "one-shot Pluto session: inactive"
    fi
    ;;
  *) echo "usage: $0 {start|stop|restore-stock|status}"; exit 64 ;;
esac
