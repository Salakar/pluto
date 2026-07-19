#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR="$HERE/../pluto-session.sh"
PROFILE_FILE="$HERE/../generated/device-profiles.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pluto-session-rm2-cpufreq.XXXXXX")"
SESSION_PID=''

cleanup() {
  if [[ -n "$SESSION_PID" ]]; then
    kill "$SESSION_PID" 2>/dev/null || true
    wait "$SESSION_PID" 2>/dev/null || true
  fi
  pkill -f "$TMP/root/bin/pluto-embedder" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "RM2 cpufreq supervisor test: $*" >&2
  [[ ! -f "$TMP/session.log" ]] || cat "$TMP/session.log" >&2
  exit 1
}

ROOT="$TMP/root"
CTL="$TMP/run"
EVENTS="$TMP/events"
mkdir -p "$TMP/bin" "$ROOT/bin" "$ROOT/engine/release" \
  "$ROOT/launcher/bundle/lib" "$ROOT/logs" "$ROOT/state" "$CTL"
: > "$ROOT/engine/release/libflutter_engine.so"
: > "$ROOT/launcher/bundle/lib/app.so"
: > "$ROOT/launcher/bundle/icudtl.dat"
printf '100.0 0.0\n' > "$TMP/uptime"
printf 'OFF\n' > "$TMP/power-good"
: > "$TMP/fb-blank"

cat > "$TMP/bin/systemctl" <<'SYSTEMCTL'
#!/bin/sh
exit 0
SYSTEMCTL

cat > "$ROOT/bin/pluto-rm2-cpufreq-restore.sh" <<'RESTORE'
#!/bin/sh
count=$(cat "$PLUTO_TEST_CPUFREQ_COUNT" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$PLUTO_TEST_CPUFREQ_COUNT"
printf 'restore %s\n' "$count" >> "$PLUTO_TEST_EVENTS"
[ "${PLUTO_TEST_CPUFREQ_FAIL_AT:-0}" -ne "$count" ]
RESTORE

cat > "$ROOT/bin/pluto-embedder" <<'EMBEDDER'
#!/bin/sh
count=$(cat "$PLUTO_TEST_EMBEDDER_COUNT" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$PLUTO_TEST_EMBEDDER_COUNT"
printf 'launch %s\n' "$count" >> "$PLUTO_TEST_EVENTS"
if [ "${PLUTO_TEST_CRASH_FIRST:-0}" = 1 ] && [ "$count" -eq 1 ]; then
  sleep 0.15
  exit 23
fi
trap 'exit 0' TERM INT
while :; do sleep 0.05; done
EMBEDDER
chmod 0755 "$TMP/bin/systemctl" "$ROOT/bin/pluto-embedder" \
  "$ROOT/bin/pluto-rm2-cpufreq-restore.sh"

run_session() {
  profile=$1
  fail_at=${2:-0}
  crash_first=${3:-1}
  : > "$EVENTS"
  rm -f "$TMP/cpufreq-count" "$TMP/embedder-count"
  PATH="$TMP/bin:$PATH" \
  PLUTO_ROOT="$ROOT" \
  PLUTO_PROFILE_FILE="$PROFILE_FILE" \
  PLUTO_TESTING=1 \
  PLUTO_TEST_PROFILE_ID="$profile" \
  PLUTO_TEST_PANEL_POWER_GOOD_FILE="$TMP/power-good" \
  PLUTO_TEST_PANEL_BLANK_FILE="$TMP/fb-blank" \
  PLUTO_PANEL_POWERDOWN_ATTEMPTS=2 \
  PLUTO_PANEL_POWERDOWN_INTERVAL=0 \
  PLUTO_TEST_CPU_FREQUENCY_RESTORE="$ROOT/bin/pluto-rm2-cpufreq-restore.sh" \
  PLUTO_RUN_DIR="$CTL" \
  PLUTO_POWER_WATCHER="$ROOT/bin/missing-power-watcher" \
  PLUTO_UPTIME_FILE="$TMP/uptime" \
  PLUTO_TEST_CPUFREQ_COUNT="$TMP/cpufreq-count" \
  PLUTO_TEST_EMBEDDER_COUNT="$TMP/embedder-count" \
  PLUTO_TEST_CPUFREQ_FAIL_AT="$fail_at" \
  PLUTO_TEST_CRASH_FIRST="$crash_first" \
  PLUTO_TEST_EVENTS="$EVENTS" \
    sh "$SUPERVISOR" start > "$TMP/session.log" 2>&1 &
  SESSION_PID=$!
}

wait_for_launches() {
  expected=$1
  for _ in $(seq 1 100); do
    [[ "$(grep -c '^launch ' "$EVENTS" 2>/dev/null || true)" -ge "$expected" ]] &&
      return 0
    sleep 0.05
  done
  return 1
}

stop_session() {
  kill "$SESSION_PID" 2>/dev/null || true
  wait "$SESSION_PID" 2>/dev/null || true
  SESSION_PID=''
  pkill -f "$ROOT/bin/pluto-embedder" 2>/dev/null || true
}

# RM2 cleanup runs once during supervisor startup and again at every foreground
# boundary. Therefore the replacement after an uncontrolled crash cannot launch
# until the stale receipt helper has completed successfully.
run_session rm2 0 1
wait_for_launches 2 || fail 'replacement foreground never launched'
stop_session
[[ "$(cat "$TMP/cpufreq-count")" -ge 3 ]] ||
  fail 'startup and foreground-boundary cleanup calls were not all made'
second_launch_line=$(grep -n '^launch 2$' "$EVENTS" | cut -d: -f1)
last_restore_line=$(awk -F: -v limit="$second_launch_line" \
  '/^restore / { line=NR } END { if (line < limit) print line }' "$EVENTS")
[[ -n "$last_restore_line" && "$last_restore_line" -lt "$second_launch_line" ]] ||
  fail 'replacement foreground preceded stale receipt cleanup'

# A cleanup error after the first crash stops the supervisor and blocks the
# second panel owner. The receipt helper's nonzero status is not downgraded.
run_session rm2 3 1
set +e
wait "$SESSION_PID"
session_rc=$?
set -e
SESSION_PID=''
[[ "$session_rc" -ne 0 ]] || fail 'cleanup failure returned supervisor success'
[[ "$(grep -c '^launch ' "$EVENTS" 2>/dev/null || true)" -eq 1 ]] ||
  fail 'foreground launched after RM2 cleanup failed'
grep -q 'CPU-frequency recovery failed closed at foreground-boundary' \
  "$TMP/session.log" || fail 'cleanup failure was not explicit in the log'

# The hook is profile-gated. A non-RM2 native session does not call the helper,
# even when that helper would fail its first invocation.
run_session rm1 1 0
wait_for_launches 1 || fail 'non-RM2 foreground never launched'
stop_session
[[ ! -e "$TMP/cpufreq-count" ]] || fail 'non-RM2 profile invoked the RM2 helper'

echo 'PASS: common supervisor gates RM2 startup and crash replacement on cpufreq recovery'
