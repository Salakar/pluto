#!/bin/sh
# Process lifecycle control shared by installs and the warm-app supervisor.
set -eu

ROOT="${PLUTO_ROOT:-/home/root/pluto}"
RUN_DIR="${PLUTO_RUN_DIR:-/run/pluto}"
WARM_DIR="$RUN_DIR/warm-apps"
HIBERNATED_DIR="$RUN_DIR/hibernated"

safe_app_id() {
  case "$1" in
    *..*|/*|*/*|''|dev.pluto.launcher) return 1 ;;
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}

pid_alive() {
  kill -0 "$1" 2>/dev/null
}

terminate_pid() {
  pid="$1"
  pid_alive "$pid" || return 0
  kill -TERM "$pid" 2>/dev/null || true
  # A hibernated process is SIGSTOPped, so TERM cannot run until it continues.
  kill -CONT "$pid" 2>/dev/null || true
  ticks=0
  while pid_alive "$pid" && [ "$ticks" -lt 40 ]; do
    sleep 0.05
    ticks=$((ticks + 1))
  done
  if pid_alive "$pid"; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

pid_matches_app() {
  pid="$1"
  app_id="$2"
  environ="/proc/$pid/environ"
  [ -r "$environ" ] || return 1
  tr '\000' '\n' < "$environ" 2>/dev/null |
    grep -Fqx "PLUTO_APP_ID=$app_id"
}

stop_app() {
  app_id="$1"
  safe_app_id "$app_id" || {
    printf 'invalid app id: %s\n' "$app_id" >&2
    exit 64
  }

  registered_pid="$(cat "$WARM_DIR/$app_id.pid" 2>/dev/null || true)"
  foreground_pid="$(cat "$RUN_DIR/embedder.pid" 2>/dev/null || true)"
  candidates=""
  [ -z "$registered_pid" ] || candidates="$candidates $registered_pid"
  if [ -n "$foreground_pid" ] && pid_matches_app "$foreground_pid" "$app_id"; then
    candidates="$candidates $foreground_pid"
    # Move the session to Home before terminating its foreground child. If we
    # killed it in place, the supervisor could immediately cold-start the old
    # bundle in the small interval before the transaction promotes its stage.
    : > "$RUN_DIR/home" 2>/dev/null || true
    ticks=0
    while [ "$(cat "$RUN_DIR/embedder.pid" 2>/dev/null || true)" = "$foreground_pid" ] &&
          pid_alive "$foreground_pid" && [ "$ticks" -lt 160 ]; do
      sleep 0.05
      ticks=$((ticks + 1))
    done
  fi
  # Catch orphaned or multiply-registered old versions as well as the normal
  # warm-pool and foreground entries. This branch is Linux-only by nature;
  # an absent /proc simply yields no additional candidates.
  for environ in /proc/[0-9]*/environ; do
    [ -r "$environ" ] || continue
    pid="${environ#/proc/}"
    pid="${pid%/environ}"
    pid_matches_app "$pid" "$app_id" || continue
    candidates="$candidates $pid"
  done

  seen=" "
  for pid in $candidates; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$seen" in *" $pid "*) continue ;; esac
    seen="$seen$pid "
    terminate_pid "$pid"
    rm -f "$HIBERNATED_DIR/$pid"
  done

  rm -f "$WARM_DIR/$app_id.pid" "$WARM_DIR/$app_id.used" \
    "$RUN_DIR/previews/$app_id.bmp"
  if [ -n "$foreground_pid" ] && ! pid_alive "$foreground_pid" &&
     [ "$(cat "$RUN_DIR/embedder.pid" 2>/dev/null || true)" = "$foreground_pid" ]; then
    rm -f "$RUN_DIR/embedder.pid"
  fi
}

case "${1:-}" in
  stop)
    [ "$#" -eq 2 ] || {
      printf 'usage: %s stop <app-id>\n' "$0" >&2
      exit 64
    }
    stop_app "$2"
    ;;
  *)
    printf 'usage: %s stop <app-id>\n' "$0" >&2
    exit 64
    ;;
esac
