#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SUPERVISOR="$HERE/../pluto-session.sh"
TMP=${TMPDIR:-/tmp}/pluto-session-standby-test.$$
ROOT="$TMP/root"
CTL="$TMP/run"
SESSION_PID=""

cleanup() {
  [ -z "$SESSION_PID" ] || kill "$SESSION_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup 0

fail() {
  echo "standby supervisor test: $*" >&2
  [ ! -f "$TMP/session.log" ] || cat "$TMP/session.log" >&2
  [ ! -f "$TMP/invocations" ] || sed -n 'l' "$TMP/invocations" >&2
  exit 1
}

grep -Fq \
  'SUSPEND_COMMAND="${PLUTO_SUSPEND_COMMAND:-systemctl start --wait suspend.target}"' \
  "$SUPERVISOR" || fail "default suspend command is not blocking through wake"

mkdir -p \
  "$ROOT/bin" \
  "$ROOT/engine/release" \
  "$ROOT/launcher/bundle/lib" \
  "$ROOT/logs" \
  "$ROOT/state" \
  "$CTL"
: > "$ROOT/engine/release/libflutter_engine.so"
: > "$ROOT/launcher/bundle/lib/app.so"
: > "$ROOT/launcher/bundle/icudtl.dat"
printf '100.0 0.0\n' > "$TMP/uptime"
printf '913\n' > "$TMP/brightness"
printf '30000\n' > "$TMP/vpdd-length"
printf '0\n' > "$TMP/vpdd-timeout"
printf 'stale-at-startup\n' > "$CTL/suspend"

cat > "$ROOT/bin/pluto-embedder" <<'EMBEDDER'
#!/bin/sh
standby=0
for arg in "$@"; do
  [ "$arg" != "--dart-entrypoint-args=--standby" ] || standby=1
done
printf '%s\n' "$*" >> "$PLUTO_TEST_INVOCATIONS"
printf '30000\n' > "$PLUTO_VPDD_LENGTH_FILE"
if [ "$standby" -eq 1 ]; then
  [ ! -e "$PLUTO_TEST_WATCHER_ACTIVE" ] || exit 91
  [ ! -e "$PLUTO_RUN_DIR/suspend" ] ||
    : > "$PLUTO_TEST_STALE_ENTRY_FAILURE"
  : > "$PLUTO_TEST_SAW_STANDBY"
  standby_count=$(cat "$PLUTO_TEST_STANDBY_COUNT" 2>/dev/null || echo 0)
  standby_count=$((standby_count + 1))
  printf '%s\n' "$standby_count" > "$PLUTO_TEST_STANDBY_COUNT"
  printf '0\n' > "$PLUTO_BACKLIGHT_BRIGHTNESS"
  if [ "$standby_count" -eq 1 ]; then
    printf '%s\n' "$$" > "$PLUTO_TEST_STANDBY_PID"
    # Model suspendNow changing the delayed VPDD hold before native shutdown.
    printf '0\n' > "$PLUTO_VPDD_LENGTH_FILE"
    printf '0\n' > "$PLUTO_VPDD_TIMEOUT_FILE"
    printf 'standby-ready\n' > "$PLUTO_RUN_DIR/suspend"
    exit 0
  fi
  # Second standby simulates Dart crashing after switching the light off but
  # before it can request suspend. The supervisor must recover brightness
  # without invoking suspend again.
  exit 92
fi
[ ! -e "$PLUTO_RUN_DIR/suspend" ] ||
  : > "$PLUTO_TEST_STALE_STARTUP_FAILURE"
trap 'exit 0' TERM INT
while :; do sleep 1; done
EMBEDDER

cat > "$ROOT/bin/fake-suspend.sh" <<'SUSPEND'
#!/bin/sh
count=$(cat "$PLUTO_TEST_SUSPEND_COUNT" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$PLUTO_TEST_SUSPEND_COUNT"
standby_pid=$(cat "$PLUTO_TEST_STANDBY_PID" 2>/dev/null || true)
if [ -n "$standby_pid" ] && kill -0 "$standby_pid" 2>/dev/null; then
  : > "$PLUTO_TEST_SUSPEND_CHILD_ALIVE"
fi
[ ! -e "$PLUTO_RUN_DIR/embedder.pid" ] ||
  : > "$PLUTO_TEST_SUSPEND_PID_FILE_PRESENT"
[ "$(cat "$PLUTO_BACKLIGHT_BRIGHTNESS")" = 0 ] ||
  : > "$PLUTO_TEST_SUSPEND_LIGHT_FAILURE"
[ "$(cat "$PLUTO_VPDD_LENGTH_FILE")" = 0 ] ||
  : > "$PLUTO_TEST_SUSPEND_VPDD_FAILURE"
[ "$(cat "$PLUTO_VPDD_TIMEOUT_FILE")" = 0 ] ||
  : > "$PLUTO_TEST_SUSPEND_VPDD_FAILURE"
# A blocking suspend target must keep the supervisor from restoring the light
# or launching the next embedder until the wake/failure receipt is available.
sleep 0.2
[ "$(wc -l < "$PLUTO_TEST_INVOCATIONS" | tr -d ' ')" -eq 2 ] ||
  : > "$PLUTO_TEST_SUSPEND_PREMATURE_RELAUNCH"
[ "$(cat "$PLUTO_BACKLIGHT_BRIGHTNESS")" = 0 ] ||
  : > "$PLUTO_TEST_SUSPEND_LIGHT_FAILURE"
exit 0
SUSPEND

cat > "$ROOT/bin/fake-power-watch.sh" <<'WATCHER'
#!/bin/sh
pid=""
run_dir=""
for arg in "$@"; do
  case "$arg" in
    --pid=*) pid="${arg#*=}" ;;
    --run-dir=*) run_dir="${arg#*=}" ;;
  esac
done
: > "$PLUTO_TEST_WATCHER_ACTIVE"
trap 'rm -f "$PLUTO_TEST_WATCHER_ACTIVE"' 0
[ "$(cat "$run_dir/embedder.pid" 2>/dev/null || true)" = "$pid" ] ||
  : > "$PLUTO_TEST_PID_FILE_FAILURE"
count=$(cat "$PLUTO_TEST_WATCHER_COUNT" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$PLUTO_TEST_WATCHER_COUNT"
if [ "$count" -le 2 ]; then
  if [ "$count" -eq 1 ]; then
    printf 'stale-at-entry\n' > "$run_dir/suspend"
  fi
  cat "$PLUTO_BACKLIGHT_BRIGHTNESS" > "$run_dir/standby-frontlight"
  printf 'power-button\n' > "$run_dir/standby"
else
  : > "$run_dir/stock"
fi
kill -TERM "$pid"
WATCHER
chmod +x "$ROOT/bin/pluto-embedder" "$ROOT/bin/fake-power-watch.sh" \
  "$ROOT/bin/fake-suspend.sh"

PLUTO_ROOT="$ROOT" \
PLUTO_RUN_DIR="$CTL" \
PLUTO_POWER_WATCHER="$ROOT/bin/fake-power-watch.sh" \
PLUTO_UPTIME_FILE="$TMP/uptime" \
PLUTO_BACKLIGHT_BRIGHTNESS="$TMP/brightness" \
PLUTO_VPDD_LENGTH_FILE="$TMP/vpdd-length" \
PLUTO_VPDD_TIMEOUT_FILE="$TMP/vpdd-timeout" \
PLUTO_VPDD_IDLE_INTERVAL=0 \
PLUTO_SUSPEND_COMMAND="$ROOT/bin/fake-suspend.sh" \
PLUTO_SUSPEND_QUIESCE_DELAY=0 \
PLUTO_TEST_INVOCATIONS="$TMP/invocations" \
PLUTO_TEST_SAW_STANDBY="$TMP/saw-standby" \
PLUTO_TEST_WATCHER_ACTIVE="$TMP/watcher-active" \
PLUTO_TEST_WATCHER_COUNT="$TMP/watcher-count" \
PLUTO_TEST_STANDBY_COUNT="$TMP/standby-count" \
PLUTO_TEST_PID_FILE_FAILURE="$TMP/pid-file-failure" \
PLUTO_TEST_STALE_STARTUP_FAILURE="$TMP/stale-startup-failure" \
PLUTO_TEST_STALE_ENTRY_FAILURE="$TMP/stale-entry-failure" \
PLUTO_TEST_STANDBY_PID="$TMP/standby-pid" \
PLUTO_TEST_SUSPEND_COUNT="$TMP/suspend-count" \
PLUTO_TEST_SUSPEND_CHILD_ALIVE="$TMP/suspend-child-alive" \
PLUTO_TEST_SUSPEND_PID_FILE_PRESENT="$TMP/suspend-pid-file-present" \
PLUTO_TEST_SUSPEND_LIGHT_FAILURE="$TMP/suspend-light-failure" \
PLUTO_TEST_SUSPEND_VPDD_FAILURE="$TMP/suspend-vpdd-failure" \
PLUTO_TEST_SUSPEND_PREMATURE_RELAUNCH="$TMP/suspend-premature-relaunch" \
  sh "$SUPERVISOR" start > "$TMP/session.log" 2>&1 &
SESSION_PID=$!

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
  21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 \
  41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
  kill -0 "$SESSION_PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$SESSION_PID" 2>/dev/null; then
  fail "supervisor did not finish the simulated standby cycle"
fi
wait "$SESSION_PID" || fail "supervisor returned failure"
SESSION_PID=""

[ -f "$TMP/saw-standby" ] || fail "standby launcher was never selected"
[ "$(cat "$TMP/brightness")" -eq 913 ] ||
  fail "supervisor did not restore the persisted frontlight after standby"
[ ! -e "$CTL/standby-frontlight" ] ||
  fail "frontlight recovery marker was not consumed after restoration"
[ ! -e "$TMP/pid-file-failure" ] ||
  fail "supervisor did not publish the exact current embedder pid"
[ ! -e "$CTL/embedder.pid" ] ||
  fail "supervisor left a stale embedder pid after the child exited"
[ ! -e "$TMP/stale-startup-failure" ] ||
  fail "supervisor did not clear the stale suspend marker at startup"
[ ! -e "$TMP/stale-entry-failure" ] ||
  fail "supervisor did not clear the stale suspend marker on standby entry"
[ "$(cat "$TMP/suspend-count")" -eq 1 ] ||
  fail "fake suspend was not invoked exactly once"
[ ! -e "$TMP/suspend-child-alive" ] ||
  fail "suspend ran before the standby embedder was fully reaped"
[ ! -e "$TMP/suspend-pid-file-present" ] ||
  fail "suspend ran before the standby embedder pid file was removed"
[ ! -e "$TMP/suspend-light-failure" ] ||
  fail "frontlight was not held at zero while suspend ran"
[ ! -e "$TMP/suspend-vpdd-failure" ] ||
  fail "VPDD was not idle while suspend ran"
[ "$(cat "$TMP/vpdd-length")" -eq 30000 ] ||
  fail "normal launcher did not restore the interactive VPDD hold"
[ ! -e "$TMP/suspend-premature-relaunch" ] ||
  fail "supervisor relaunched before the blocking suspend receipt"
[ "$(cat "$TMP/watcher-count")" -eq 3 ] ||
  fail "watcher was not limited to normal launcher runs"
[ "$(wc -l < "$TMP/invocations" | tr -d ' ')" -eq 5 ] ||
  fail "expected normal/standby cycles followed by resumed normal launcher"
[ "$(grep -c -- '--dart-entrypoint-args=--standby' "$TMP/invocations")" -eq 2 ] ||
  fail "standby Dart argument was not isolated to standby launches"
[ "$(grep -c -- '--pen' "$TMP/invocations")" -eq 5 ] ||
  fail "supervisor did not enable stylus input for every app launch"
[ "$(grep -c -- '--touch' "$TMP/invocations")" -eq 5 ] ||
  fail "supervisor did not enable touch input for every app launch"
grep -q 'power standby requested; launching standby screen' "$TMP/session.log" ||
  fail "supervisor did not consume the standby marker"
grep -q 'suspend target completed after wake' "$TMP/session.log" ||
  fail "supervisor did not log the suspend return"
grep -q 'VPDD cooldown is idle' "$TMP/session.log" ||
  fail "supervisor did not verify the regulator cooldown"
grep -q 'standby child exited without suspend request; recovering frontlight' \
  "$TMP/session.log" || fail "standby crash recovery was not logged"

echo "standby supervisor test: PASS"
