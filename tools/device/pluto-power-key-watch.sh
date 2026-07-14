#!/bin/sh
# Watches the generated profile's stable power-key evdev node for one complete
# press.
# A release before the hold threshold atomically requests standby and snapshots
# the frontlight. A continuous hold through the threshold requests the full-screen
# power menu instead. Both paths ask the exact current embedder to hibernate. The
# supervisor deliberately does not start this watcher for the standby launcher,
# so the wake press cannot recursively request standby again.
set -u

RUN_DIR="${PLUTO_RUN_DIR:-/run/pluto}"
EVTEST="${PLUTO_EVTEST:-/usr/bin/evtest}"
HOLD_SECONDS="${PLUTO_POWER_MENU_HOLD_SECONDS:-2}"
PROFILE_FILE="${PLUTO_PROFILE_FILE:-${PLUTO_ROOT:-/home/root/pluto}/share/device-profiles.sh}"
POWER_DEVICE="${PLUTO_POWER_KEY_DEVICE:-${PLUTO_PROFILE_POWER_KEY_DEVICE:-}}"
BACKLIGHT_BRIGHTNESS="${PLUTO_BACKLIGHT_BRIGHTNESS:-${PLUTO_PROFILE_FRONTLIGHT_BRIGHTNESS:-}}"
TARGET_PID=""
APP_ID=""

usage() {
  echo "usage: pluto-power-key-watch.sh --pid=<embedder-pid> --app-id=<app-id> [--device=<evdev>] [--run-dir=<dir>]" >&2
  exit 64
}

for arg in "$@"; do
  case "$arg" in
    --pid=*) TARGET_PID="${arg#*=}" ;;
    --app-id=*) APP_ID="${arg#*=}" ;;
    --device=*) POWER_DEVICE="${arg#*=}" ;;
    --run-dir=*) RUN_DIR="${arg#*=}" ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

case "$TARGET_PID" in
  ''|*[!0-9]*) usage ;;
esac
case "$APP_ID" in
  ''|*[!A-Za-z0-9._-]*) usage ;;
esac
case "$HOLD_SECONDS" in
  ''|*[!0-9.]*|.*|*.*.*|*.) usage ;;
esac
if [ -z "${PLUTO_PROFILE_ID:-}" ]; then
  [ -r "$PROFILE_FILE" ] || {
    echo "pluto-power-key-watch: generated profile is missing: $PROFILE_FILE" >&2
    exit 78
  }
  # shellcheck source=generated/device-profiles.sh
  . "$PROFILE_FILE"
  if [ -n "${PLUTO_TEST_PROFILE_ID:-}" ]; then
    [ "${PLUTO_TESTING:-0}" = 1 ] &&
      pluto_profile_load "$PLUTO_TEST_PROFILE_ID" || {
        echo "pluto-power-key-watch: invalid test profile" >&2
        exit 78
      }
  elif ! pluto_profile_probe; then
    echo "pluto-power-key-watch: immutable device profile mismatch" >&2
    exit 78
  fi
  [ -n "$POWER_DEVICE" ] ||
    POWER_DEVICE="$PLUTO_PROFILE_POWER_KEY_DEVICE"
  [ -n "$BACKLIGHT_BRIGHTNESS" ] ||
    BACKLIGHT_BRIGHTNESS="$PLUTO_PROFILE_FRONTLIGHT_BRIGHTNESS"
fi
case "${PLUTO_PROFILE_ID:-}" in
  ''|*[!a-z0-9_]*)
    echo "pluto-power-key-watch: invalid or missing profile identity" >&2
    exit 78
    ;;
esac
[ -n "$POWER_DEVICE" ] || {
  echo "pluto-power-key-watch: profile has no power-key device" >&2
  exit 78
}
[ -r "$POWER_DEVICE" ] || {
  echo "pluto-power-key-watch: cannot read $POWER_DEVICE" >&2
  exit 66
}
[ -x "$EVTEST" ] || {
  echo "pluto-power-key-watch: evtest is missing: $EVTEST" >&2
  exit 69
}

mkdir -p "$RUN_DIR" || exit 73
EVENT_FIFO="$RUN_DIR/.power-events.$$"
MARKER_TMP="$RUN_DIR/.standby.$$"
LIGHT_TMP="$RUN_DIR/.standby-frontlight.$$"
MENU_TMP="$RUN_DIR/.power-menu.$$"
READER_PID=""
TIMER_PID=""
PRESS_ARMED=0
WATCHER_PID=$$
HOLD_SENTINEL="pluto-power-hold-threshold:$WATCHER_PID"

cleanup() {
  if [ -n "$TIMER_PID" ]; then
    kill "$TIMER_PID" 2>/dev/null || true
    wait "$TIMER_PID" 2>/dev/null || true
  fi
  if [ -n "$READER_PID" ]; then
    kill "$READER_PID" 2>/dev/null || true
    wait "$READER_PID" 2>/dev/null || true
  fi
  rm -f "$EVENT_FIFO" "$MARKER_TMP" "$LIGHT_TMP" "$MENU_TMP"
}
trap cleanup 0
trap 'exit 0' 1 2 15

mkfifo "$EVENT_FIFO" || exit 73
# --grab makes Pluto the sole userspace consumer during a normal app. The
# process and its grab are torn down before the standby launcher starts, so the
# next press remains available as the kernel wake event.
"$EVTEST" --grab "$POWER_DEVICE" > "$EVENT_FIFO" 2>/dev/null &
READER_PID=$!

while kill -0 "$TARGET_PID" 2>/dev/null && IFS= read -r event_line; do
  case "$event_line" in
    *'type 1 (EV_KEY), code 116 (KEY_POWER), value 1'*)
      [ "$PRESS_ARMED" -eq 0 ] || continue
      PRESS_ARMED=1
      # Feed the threshold back through the same FIFO as evtest. If a release
      # is already queued when the parent shell is descheduled around two
      # seconds, that physical event stays ahead of this sentinel and wins the
      # press in kernel/event order rather than scheduler order.
      (
        trap - 0 1 2 15
        sleep "$HOLD_SECONDS" || exit 64
        printf '%s\n' "$HOLD_SENTINEL" > "$EVENT_FIFO"
      ) &
      TIMER_PID=$!
      ;;
    "$HOLD_SENTINEL")
      [ "$PRESS_ARMED" -eq 1 ] || continue
      PRESS_ARMED=0
      wait "$TIMER_PID" 2>/dev/null || true
      TIMER_PID=""
      if printf '%s\n' "$APP_ID" > "$MENU_TMP" &&
          mv -f "$MENU_TMP" "$RUN_DIR/power-menu"; then
        kill -USR1 "$TARGET_PID" 2>/dev/null || true
      else
        echo "pluto-power-key-watch: cannot publish power menu request" >&2
        exit 73
      fi
      # The long-hold transition is complete at the threshold. Leaving now
      # drops the evdev grab; the eventual release has no standby meaning.
      exit 0
      ;;
    *'type 1 (EV_KEY), code 116 (KEY_POWER), value 0'*)
      [ "$PRESS_ARMED" -eq 1 ] || continue
      PRESS_ARMED=0
      kill "$TIMER_PID" 2>/dev/null || true
      wait "$TIMER_PID" 2>/dev/null || true
      TIMER_PID=""
      # Transition only after the key is physically up. This prevents the
      # initiating press from immediately waking `mem`; value-2 long-press
      # repeats never match either branch.
      if [ -n "$BACKLIGHT_BRIGHTNESS" ]; then
        light_raw=$(cat "$BACKLIGHT_BRIGHTNESS" 2>/dev/null || true)
        case "$light_raw" in
          ''|*[!0-9]*)
            echo "pluto-power-key-watch: cannot snapshot frontlight" >&2
            exit 75
            ;;
        esac
        printf '%s\n' "$light_raw" > "$LIGHT_TMP" || exit 73
        mv -f "$LIGHT_TMP" "$RUN_DIR/standby-frontlight" || exit 73
      fi
      printf 'power-button\n' > "$MARKER_TMP" || exit 73
      mv -f "$MARKER_TMP" "$RUN_DIR/standby" || exit 73
      # SIGUSR1 is handled synchronously through the embedder event loop: it
      # sends Flutter paused, releases input/DRM, and publishes its hibernated
      # marker. The supervisor freezes it only after that acknowledgement.
      kill -USR1 "$TARGET_PID" 2>/dev/null || true
      exit 0
      ;;
  esac
done < "$EVENT_FIFO"

if kill -0 "$TARGET_PID" 2>/dev/null; then
  echo "pluto-power-key-watch: evtest stopped before the embedder" >&2
  exit 74
fi
exit 0
