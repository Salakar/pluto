#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SUPERVISOR="$HERE/../pluto-session.sh"
PROFILE_FILE="$HERE/../generated/device-profiles.sh"
TMP=${TMPDIR:-/tmp}/pluto-session-rm2-panel-boundary-test.$$
ROOT="$TMP/root"
CTL="$TMP/run"
SESSION_PID=""
BLANK_WATCHER_PID=""

cleanup() {
  if [ -n "$BLANK_WATCHER_PID" ]; then
    kill "$BLANK_WATCHER_PID" 2>/dev/null || true
    wait "$BLANK_WATCHER_PID" 2>/dev/null || true
  fi
  [ -z "$SESSION_PID" ] || kill "$SESSION_PID" 2>/dev/null || true
  for pid_file in "$CTL/warm-apps"/*.pid; do
    [ -f "$pid_file" ] || continue
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [ -z "$pid" ] || {
      kill -TERM "$pid" 2>/dev/null || true
      kill -CONT "$pid" 2>/dev/null || true
    }
  done
  rm -rf "$TMP"
}
trap cleanup 0

fail() {
  echo "RM2 panel boundary supervisor test: $*" >&2
  [ ! -f "$TMP/session.log" ] || cat "$TMP/session.log" >&2
  [ ! -d "$ROOT/logs" ] || {
    for log_file in "$ROOT/logs"/*.log; do
      [ -f "$log_file" ] || continue
      echo "--- $log_file" >&2
      cat "$log_file" >&2
    done
  }
  exit 1
}

wait_for_value() {
  path="$1"
  expected="$2"
  for _ in $(seq 1 160); do
    [ "$(cat "$path" 2>/dev/null || true)" = "$expected" ] && return 0
    sleep 0.05
  done
  return 1
}

wait_for_absent() {
  path="$1"
  for _ in $(seq 1 160); do
    [ ! -e "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

wait_for_file() {
  path="$1"
  for _ in $(seq 1 160); do
    [ -f "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

mkdir -p "$TMP/bin" "$ROOT/bin" "$ROOT/engine/release" \
  "$ROOT/launcher/bundle/lib" "$ROOT/apps/dev.example.paper/bundle/lib" \
  "$ROOT/logs" "$ROOT/state" "$CTL"
: > "$ROOT/engine/release/libflutter_engine.so"
: > "$ROOT/launcher/bundle/lib/app.so"
: > "$ROOT/launcher/bundle/icudtl.dat"
: > "$ROOT/apps/dev.example.paper/bundle/lib/app.so"
: > "$ROOT/apps/dev.example.paper/bundle/icudtl.dat"
printf '100.0 0.0\n' > "$TMP/uptime"
printf 'OFF\n' > "$TMP/power-good"
: > "$TMP/fb-blank"

cat > "$TMP/bin/systemctl" <<'SYSTEMCTL'
#!/bin/sh
exit 0
SYSTEMCTL

cat > "$ROOT/bin/pluto-rm2-cpufreq-restore.sh" <<'CPUFREQ'
#!/bin/sh
exit 0
CPUFREQ

cat > "$ROOT/bin/pluto-embedder" <<'EMBEDDER'
#!/bin/sh
marker="$PLUTO_RUN_DIR/hibernated/$$"
count_file="$PLUTO_TEST_STARTS/$PLUTO_APP_ID"
count=$(cat "$count_file" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$count_file"

hibernate() {
  mkdir -p "$PLUTO_RUN_DIR/hibernated"
  if [ "$PLUTO_APP_ID" = dev.pluto.launcher ]; then
    # Model an ordinary retained-powered handoff into the temporary owner.
    : > "$PLUTO_GLASS_HANDOFF_FILE"
  else
    # Model chain 7 being consumed: the final owner removes the bundle and
    # requests rail powerdown, whose live PMIC observation settles later.
    rm -f "$PLUTO_GLASS_HANDOFF_FILE"
    printf 'ON\n' > "$PLUTO_TEST_PANEL_POWER_GOOD_FILE"
    (
      sleep 0.25
      printf 'OFF\n' > "$PLUTO_TEST_PANEL_POWER_GOOD_FILE"
    ) &
  fi
  printf 'paused\n' > "$marker.tmp"
  mv -f "$marker.tmp" "$marker"
}

resume() {
  if [ "$PLUTO_APP_ID" = dev.pluto.launcher ] &&
     [ "$(cat "$PLUTO_TEST_PANEL_POWER_GOOD_FILE")" != OFF ]; then
    : > "$PLUTO_TEST_PREMATURE_RESUME"
  fi
  if [ "$PLUTO_APP_ID" = dev.example.paper ]; then
    printf 'ON\n' > "$PLUTO_TEST_PANEL_POWER_GOOD_FILE"
  fi
  rm -f "$marker"
}

trap hibernate USR1
trap resume USR2
trap 'rm -f "$marker"; exit 0' TERM INT
: > "$PLUTO_TEST_STARTS/$PLUTO_APP_ID.ready"
while :; do sleep 0.05; done
EMBEDDER
chmod +x "$TMP/bin/systemctl" "$ROOT/bin/pluto-rm2-cpufreq-restore.sh" \
  "$ROOT/bin/pluto-embedder"
mkdir -p "$TMP/starts"
(
  while :; do
    if [ "$(cat "$TMP/fb-blank" 2>/dev/null || true)" = 4 ]; then
      printf 'OFF\n' > "$TMP/power-good"
      : > "$TMP/fb-blank"
      : > "$TMP/crash-powerdown-observed"
    fi
    sleep 0.01
  done
) &
BLANK_WATCHER_PID=$!

PATH="$TMP/bin:$PATH" \
PLUTO_ROOT="$ROOT" \
PLUTO_PROFILE_FILE="$PROFILE_FILE" \
PLUTO_TESTING=1 \
PLUTO_TEST_PROFILE_ID=rm2 \
PLUTO_RUN_DIR="$CTL" \
PLUTO_POWER_WATCHER="$ROOT/bin/missing-power-watcher" \
PLUTO_UPTIME_FILE="$TMP/uptime" \
PLUTO_TEST_PANEL_POWER_GOOD_FILE="$TMP/power-good" \
PLUTO_TEST_PANEL_BLANK_FILE="$TMP/fb-blank" \
PLUTO_GLASS_HANDOFF_FILE="$CTL/glass.handoff" \
PLUTO_PANEL_POWERDOWN_ATTEMPTS=80 \
PLUTO_PANEL_POWERDOWN_INTERVAL=0.01 \
PLUTO_TEST_STARTS="$TMP/starts" \
PLUTO_TEST_PREMATURE_RESUME="$TMP/premature-resume" \
  sh "$SUPERVISOR" start > "$TMP/session.log" 2>&1 &
SESSION_PID=$!

for _ in $(seq 1 160); do
  launcher_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$launcher_pid" ] && break
  sleep 0.05
done
[ -n "${launcher_pid:-}" ] || fail "launcher never became foreground"
wait_for_value "$TMP/starts/dev.pluto.launcher" 1 ||
  fail "launcher did not install its signal handlers"
wait_for_file "$TMP/starts/dev.pluto.launcher.ready" ||
  fail "launcher readiness marker is missing"

printf 'dev.example.paper\n' > "$CTL/launch"
for _ in $(seq 1 160); do
  paper_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$paper_pid" ] && [ "$paper_pid" != "$launcher_pid" ] && break
  sleep 0.05
done
[ -n "${paper_pid:-}" ] && [ "$paper_pid" != "$launcher_pid" ] ||
  fail "temporary owner never became foreground"
[ -e "$CTL/glass.handoff" ] ||
  fail "ordinary retained-powered handoff was not preserved"

: > "$CTL/home"
wait_for_value "$CTL/embedder.pid" "$launcher_pid" ||
  fail "warm launcher did not resume after the cold electrical boundary"
wait_for_absent "$CTL/hibernated/$launcher_pid" ||
  fail "launcher resume acknowledgement was not consumed"
[ ! -e "$TMP/premature-resume" ] ||
  fail "launcher resumed while RM2 power-good was still ON"
[ "$(cat "$TMP/starts/dev.pluto.launcher")" -eq 1 ] ||
  fail "cold panel fence restarted the warm launcher process"
grep -q 'RM2 cold panel boundary confirmed power_good=OFF' "$TMP/session.log" ||
  fail "stable power-good boundary was not logged"

printf 'dev.example.paper\n' > "$CTL/launch"
wait_for_value "$CTL/embedder.pid" "$paper_pid" ||
  fail "warm temporary owner did not resume for the crash test"
wait_for_value "$TMP/power-good" ON ||
  fail "crash-test owner did not power the panel"
kill -KILL "$paper_pid"
wait_for_value "$CTL/embedder.pid" "$launcher_pid" ||
  fail "warm launcher did not recover after the foreground crash"
wait_for_absent "$CTL/hibernated/$launcher_pid" ||
  fail "crash recovery did not consume the launcher resume acknowledgement"
[ -e "$TMP/crash-powerdown-observed" ] ||
  fail "foreground crash did not request fbdev POWERDOWN"
[ "$(cat "$TMP/power-good")" = OFF ] ||
  fail "foreground crash recovery did not reach the cold PMIC boundary"
grep -q 'RM2 crash recovery requested FBIOBLANK(POWERDOWN)' \
  "$TMP/session.log" ||
  fail "foreground crash powerdown was not logged"
grep -q 'RM2 crash recovery completed at stable power_good=OFF' \
  "$TMP/session.log" ||
  fail "foreground crash completion was not logged"

: > "$CTL/stock"
for _ in $(seq 1 160); do
  kill -0 "$SESSION_PID" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$SESSION_PID" 2>/dev/null &&
  fail "supervisor did not exit to stock"
wait "$SESSION_PID" || fail "supervisor returned failure"
SESSION_PID=""

echo "RM2 panel boundary supervisor test: PASS"
