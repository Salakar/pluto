#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
WATCHER="$HERE/../pluto-power-key-watch.sh"
TMP=${TMPDIR:-/tmp}/pluto-power-key-watch-test.$$
FIFO="$TMP/power-event"
RUN_DIR="$TMP/run"
FAKE_EVTEST="$TMP/evtest"
FAKE_TARGET="$TMP/target"
BACKLIGHT="$TMP/brightness"
WATCHER_PID=""
TARGET_PID=""

cleanup() {
  [ -z "$WATCHER_PID" ] || kill -CONT "$WATCHER_PID" 2>/dev/null || true
  [ -z "$WATCHER_PID" ] || kill "$WATCHER_PID" 2>/dev/null || true
  [ -z "$TARGET_PID" ] || kill "$TARGET_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup 0

fail() {
  echo "power-key watcher test: $*" >&2
  exit 1
}

start_target() {
  rm -f "$TMP/hibernate-signal"
  PLUTO_TEST_HIBERNATE_SIGNAL="$TMP/hibernate-signal" "$FAKE_TARGET" &
  TARGET_PID=$!
  # Install the USR1 handler before the watcher can exercise it.
  sleep 0.1
}

start_watcher() {
  hold_seconds="$1"
  PLUTO_EVTEST="$FAKE_EVTEST" \
  PLUTO_BACKLIGHT_BRIGHTNESS="$BACKLIGHT" \
  PLUTO_POWER_MENU_HOLD_SECONDS="$hold_seconds" \
    "$WATCHER" --pid="$TARGET_PID" --app-id=dev.example.paper \
      --device="$FIFO" --run-dir="$RUN_DIR" &
  WATCHER_PID=$!
}

emit_power_event() {
  value="$1"
  printf 'Event: time 1.000000, type 1 (EV_KEY), code 116 (KEY_POWER), value %s\n' \
    "$value" > "$FIFO"
}

mkdir -p "$RUN_DIR"
mkfifo "$FIFO"
printf '913\n' > "$BACKLIGHT"
cat > "$FAKE_EVTEST" <<'EVTEST'
#!/bin/sh
[ "$1" = --grab ] || exit 64
child=""
cleanup() {
  [ -z "$child" ] || kill "$child" 2>/dev/null || true
  [ -z "$child" ] || wait "$child" 2>/dev/null || true
}
trap cleanup 0
trap 'exit 0' 1 2 15
while :; do
  cat "$2" &
  child=$!
  wait "$child" || true
  child=""
done
EVTEST
chmod +x "$FAKE_EVTEST"
cat > "$FAKE_TARGET" <<'TARGET'
#!/bin/sh
trap ': > "$PLUTO_TEST_HIBERNATE_SIGNAL"' USR1
trap 'exit 0' TERM INT
while :; do sleep 1; done
TARGET
chmod +x "$FAKE_TARGET"
grep -Fq 'HOLD_SECONDS="${PLUTO_POWER_MENU_HOLD_SECONDS:-2}"' "$WATCHER" ||
  fail "default power-menu hold threshold is not two seconds"

start_target
start_watcher 0.5

emit_power_event 0
sleep 0.1
kill -0 "$TARGET_PID" 2>/dev/null || fail "release killed the target"
[ ! -e "$RUN_DIR/standby" ] || fail "release requested standby"

emit_power_event 1
sleep 0.1
kill -0 "$TARGET_PID" 2>/dev/null || fail "down edge killed the target"
[ ! -e "$RUN_DIR/standby" ] || fail "down edge requested standby"

emit_power_event 2
sleep 0.25
kill -0 "$TARGET_PID" 2>/dev/null || fail "repeat killed the target"
[ ! -e "$RUN_DIR/standby" ] || fail "repeat requested standby"

# Queue the physical release while the event-loop shell is descheduled, then
# let the threshold sentinel queue behind it. Release must still win in FIFO
# event order; a timer child publishing independently would misclassify this.
kill -STOP "$WATCHER_PID"
emit_power_event 0
sleep 0.3
kill -CONT "$WATCHER_PID"
wait "$WATCHER_PID"
WATCHER_PID=""
[ -f "$RUN_DIR/standby" ] || fail "matching release did not request standby"
[ "$(cat "$RUN_DIR/standby")" = power-button ] || fail "wrong marker content"
[ "$(cat "$RUN_DIR/standby-frontlight")" = 913 ] ||
  fail "exact frontlight value was not persisted"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$TMP/hibernate-signal" ] && break
  sleep 0.1
done
[ -f "$TMP/hibernate-signal" ] ||
  fail "matching release did not request target hibernation"
kill -0 "$TARGET_PID" 2>/dev/null ||
  fail "power watcher terminated the warm target"
kill -TERM "$TARGET_PID" 2>/dev/null || true
wait "$TARGET_PID" 2>/dev/null || true
TARGET_PID=""

rm -f "$RUN_DIR/standby" "$RUN_DIR/standby-frontlight"
start_target
start_watcher 0.4

emit_power_event 1
sleep 0.05
emit_power_event 2
sleep 0.1
[ ! -e "$RUN_DIR/power-menu" ] ||
  fail "autorepeat triggered the power menu before the hold threshold"
[ ! -e "$RUN_DIR/standby" ] ||
  fail "autorepeat requested standby"

# No release follows: crossing the threshold itself must publish the request,
# hibernate the current app, and end this one-shot watcher.
wait "$WATCHER_PID"
WATCHER_PID=""
[ -f "$RUN_DIR/power-menu" ] ||
  fail "continuous hold did not request the power menu"
[ "$(cat "$RUN_DIR/power-menu")" = dev.example.paper ] ||
  fail "power menu request did not identify the current app"
[ ! -e "$RUN_DIR/standby" ] ||
  fail "continuous hold also requested standby"
[ ! -e "$RUN_DIR/standby-frontlight" ] ||
  fail "continuous hold altered the standby frontlight state"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$TMP/hibernate-signal" ] && break
  sleep 0.1
done
[ -f "$TMP/hibernate-signal" ] ||
  fail "continuous hold did not request target hibernation"
kill -0 "$TARGET_PID" 2>/dev/null ||
  fail "power-menu hold terminated the warm target"
kill -TERM "$TARGET_PID" 2>/dev/null || true
wait "$TARGET_PID" 2>/dev/null || true
TARGET_PID=""

echo "power-key watcher test: PASS"
