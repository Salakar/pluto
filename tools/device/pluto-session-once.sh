#!/bin/sh
# Runtime-only Pluto activation for a profile whose persistent boot-default
# recovery gate is closed. The transient service owns the current panel session;
# its stop/failure path restarts stock xochitl, and /run disappears on reboot.
set -u

ROOT="${PLUTO_ROOT:-/home/root/pluto}"
RUN_DIR="${PLUTO_RUN_DIR:-/run/pluto}"
SYSTEMCTL="${PLUTO_SYSTEMCTL:-systemctl}"
RUNTIME_UNITS="${PLUTO_SYSTEMD_RUNTIME_DIR:-/run/systemd/system}"
UNIT_NAME=pluto-session-once.service
UNIT="$RUNTIME_UNITS/$UNIT_NAME"
SUPERVISOR="$ROOT/bin/pluto-session.sh"

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

safe_root() { safe_path "$ROOT" && safe_path "$RUN_DIR"; }

restore_stock() {
  "$SYSTEMCTL" reset-failed xochitl.service 2>/dev/null || true
  "$SYSTEMCTL" start xochitl.service 2>/dev/null
}

remove_unit() {
  rm -f "$UNIT" "$UNIT.tmp.$$"
  "$SYSTEMCTL" daemon-reload 2>/dev/null || true
}

do_start() {
  safe_root || die "unsafe Pluto root: $ROOT"
  [ -x "$SUPERVISOR" ] || die "missing executable supervisor: $SUPERVISOR"
  mkdir -p "$RUNTIME_UNITS" || die "cannot create transient unit directory"

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
ExecStopPost=/bin/systemctl reset-failed xochitl.service
ExecStopPost=/bin/systemctl --no-block start xochitl.service
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
  start) do_start ;;
  stop) do_stop ;;
  status)
    if [ -f "$UNIT" ] && "$SYSTEMCTL" is-active --quiet "$UNIT_NAME"; then
      echo "one-shot Pluto session: active"
    else
      echo "one-shot Pluto session: inactive"
    fi
    ;;
  *) echo "usage: $0 {start|stop|status}"; exit 64 ;;
esac
