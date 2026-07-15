#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SUPERVISOR="$HERE/../pluto-session.sh"
PROFILE_FILE="$HERE/../generated/device-profiles.sh"
TMP=${TMPDIR:-/tmp}/pluto-session-power-menu-test.$$
ROOT="$TMP/root"
CTL="$TMP/run"
SESSION_PID=""

cleanup() {
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
  echo "power-menu supervisor test: $*" >&2
  [ ! -f "$TMP/session.log" ] || cat "$TMP/session.log" >&2
  [ ! -f "$TMP/invocations" ] || sed -n 'l' "$TMP/invocations" >&2
  exit 1
}

wait_for_value() {
  path="$1" expected="$2"
  ticks=0
  while [ "$ticks" -lt 160 ]; do
    [ "$(cat "$path" 2>/dev/null || true)" = "$expected" ] && return 0
    sleep 0.05
    ticks=$((ticks + 1))
  done
  return 1
}

wait_for_file() {
  path="$1"
  ticks=0
  while [ "$ticks" -lt 160 ]; do
    [ -f "$path" ] && return 0
    sleep 0.05
    ticks=$((ticks + 1))
  done
  return 1
}

wait_for_absent() {
  path="$1"
  ticks=0
  while [ "$ticks" -lt 160 ]; do
    [ ! -e "$path" ] && return 0
    sleep 0.05
    ticks=$((ticks + 1))
  done
  return 1
}

wait_for_dead() {
  pid="$1"
  ticks=0
  while [ "$ticks" -lt 160 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
    ticks=$((ticks + 1))
  done
  return 1
}

grep -Fq \
  'POWER_OFF_COMMAND="${PLUTO_POWER_OFF_COMMAND:-systemctl poweroff}"' \
  "$SUPERVISOR" || fail "default power-off command is not systemctl poweroff"

mkdir -p "$TMP/bin" "$ROOT/bin" "$ROOT/engine/release" \
  "$ROOT/engine/debug" \
  "$ROOT/launcher/bundle/lib" "$ROOT/apps/dev.example.paper/bundle/lib" \
  "$ROOT/apps/dev.example.debug/bundle/flutter_assets" \
  "$ROOT/logs" "$ROOT/state" "$CTL" "$TMP/starts" "$TMP/ready" \
  "$TMP/watcher-active"
: > "$ROOT/engine/release/libflutter_engine.so"
: > "$ROOT/engine/debug/libflutter_engine.so"
: > "$ROOT/launcher/bundle/lib/app.so"
: > "$ROOT/launcher/bundle/icudtl.dat"
: > "$ROOT/apps/dev.example.paper/bundle/lib/app.so"
: > "$ROOT/apps/dev.example.paper/bundle/icudtl.dat"
: > "$ROOT/apps/dev.example.debug/bundle/flutter_assets/kernel_blob.bin"
: > "$ROOT/apps/dev.example.debug/bundle/icudtl.dat"
printf '100.0 0.0\n' > "$TMP/uptime"

cat > "$TMP/bin/systemctl" <<'SYSTEMCTL'
#!/bin/sh
exit 0
SYSTEMCTL

cat > "$ROOT/bin/pluto-embedder" <<'EMBEDDER'
#!/bin/sh
marker="$PLUTO_RUN_DIR/hibernated/$$"
count_file="$PLUTO_TEST_STARTS/$PLUTO_APP_ID"
count=$(cat "$count_file" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$count_file"
printf '%s %s\n' "$PLUTO_APP_ID" "$*" >> "$PLUTO_TEST_INVOCATIONS"
debug=0
standby=0
for arg in "$@"; do
  [ "$arg" != --debug ] || debug=1
  [ "$arg" != --dart-entrypoint-args=--standby ] || standby=1
done
hibernate() {
  mkdir -p "$PLUTO_RUN_DIR/hibernated"
  printf 'paused\n' > "$marker.tmp"
  mv -f "$marker.tmp" "$marker"
  if [ -f "$PLUTO_RUN_DIR/poweroff" ]; then
    : > "$PLUTO_TEST_POWEROFF_HOST_HIBERNATED"
  fi
}
if [ "$debug" -eq 1 ]; then
  # Model a one-shot JIT process that cannot enter the warm pool.
  trap ':' USR1
else
  trap hibernate USR1
fi
trap 'rm -f "$marker"' USR2
trap 'rm -f "$marker"; exit 0' TERM INT
: > "$PLUTO_TEST_READY/$$"
if [ "$standby" -eq 1 ]; then
  sleep 0.15
  [ ! -e "$PLUTO_TEST_WATCHER_ACTIVE_DIR/$$" ] ||
    : > "$PLUTO_TEST_STANDBY_WATCHER_FAILURE"
  : > "$PLUTO_TEST_SAW_STANDBY"
  exit 0
fi
while :; do sleep 0.05; done
EMBEDDER

cat > "$ROOT/bin/fake-power-watch.sh" <<'WATCHER'
#!/bin/sh
pid=""
app_id=""
run_dir=""
for arg in "$@"; do
  case "$arg" in
    --pid=*) pid="${arg#*=}" ;;
    --app-id=*) app_id="${arg#*=}" ;;
    --run-dir=*) run_dir="${arg#*=}" ;;
  esac
done
[ -n "$pid" ] && [ -n "$app_id" ] && [ -n "$run_dir" ] || exit 64
printf '%s %s\n' "$app_id" "$pid" >> "$PLUTO_TEST_WATCHERS"
[ "$(cat "$run_dir/embedder.pid" 2>/dev/null || true)" = "$pid" ] ||
  : > "$PLUTO_TEST_BAD_WATCHER_PID"
mkdir -p "$PLUTO_TEST_WATCHER_ACTIVE_DIR"
: > "$PLUTO_TEST_WATCHER_ACTIVE_DIR/$pid"
trap 'rm -f "$PLUTO_TEST_WATCHER_ACTIVE_DIR/$pid"; exit 0' 1 2 15
while :; do sleep 0.05; done
WATCHER

cat > "$ROOT/bin/fake-poweroff.sh" <<'POWEROFF'
#!/bin/sh
count=$(cat "$PLUTO_TEST_POWEROFF_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$PLUTO_TEST_POWEROFF_COUNT"
for pid_file in "$PLUTO_RUN_DIR/warm-apps"/*.pid; do
  [ ! -f "$pid_file" ] || : > "$PLUTO_TEST_NOT_DRAINED"
done
[ -f "$PLUTO_TEST_POWEROFF_HOST_HIBERNATED" ] ||
  : > "$PLUTO_TEST_POWEROFF_HOST_NOT_HIBERNATED"
[ -f "$PLUTO_TEST_ALLOW_POWEROFF" ] && exit 0
exit 9
POWEROFF

chmod +x "$TMP/bin/systemctl" "$ROOT/bin/pluto-embedder" \
  "$ROOT/bin/fake-power-watch.sh" "$ROOT/bin/fake-poweroff.sh"

PATH="$TMP/bin:$PATH" \
PLUTO_ROOT="$ROOT" \
PLUTO_PROFILE_FILE="$PROFILE_FILE" \
PLUTO_TESTING=1 \
PLUTO_TEST_PROFILE_ID=move \
PLUTO_RUN_DIR="$CTL" \
PLUTO_POWER_WATCHER="$ROOT/bin/fake-power-watch.sh" \
PLUTO_POWER_OFF_COMMAND="$ROOT/bin/fake-poweroff.sh" \
PLUTO_UPTIME_FILE="$TMP/uptime" \
PLUTO_HIBERNATE_WAIT_TICKS=120 \
PLUTO_RESUME_WAIT_TICKS=120 \
PLUTO_TEST_STARTS="$TMP/starts" \
PLUTO_TEST_READY="$TMP/ready" \
PLUTO_TEST_INVOCATIONS="$TMP/invocations" \
PLUTO_TEST_WATCHERS="$TMP/watchers" \
PLUTO_TEST_BAD_WATCHER_PID="$TMP/bad-watcher-pid" \
PLUTO_TEST_POWEROFF_COUNT="$TMP/poweroff-count" \
PLUTO_TEST_NOT_DRAINED="$TMP/not-drained" \
PLUTO_TEST_ALLOW_POWEROFF="$TMP/allow-poweroff" \
PLUTO_TEST_POWEROFF_HOST_HIBERNATED="$TMP/poweroff-host-hibernated" \
PLUTO_TEST_POWEROFF_HOST_NOT_HIBERNATED="$TMP/poweroff-host-not-hibernated" \
PLUTO_TEST_WATCHER_ACTIVE_DIR="$TMP/watcher-active" \
PLUTO_TEST_STANDBY_WATCHER_FAILURE="$TMP/standby-watcher-failure" \
PLUTO_TEST_SAW_STANDBY="$TMP/saw-standby" \
  sh "$SUPERVISOR" start > "$TMP/session.log" 2>&1 &
SESSION_PID=$!

ticks=0
while [ "$ticks" -lt 160 ]; do
  launcher_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$launcher_pid" ] && [ -f "$TMP/ready/$launcher_pid" ] && break
  sleep 0.05
  ticks=$((ticks + 1))
done
[ -n "${launcher_pid:-}" ] && [ -f "$TMP/ready/$launcher_pid" ] ||
  fail "launcher never became foreground"

printf 'dev.example.paper\n' > "$CTL/launch"
ticks=0
while [ "$ticks" -lt 160 ]; do
  paper_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$paper_pid" ] && [ "$paper_pid" != "$launcher_pid" ] &&
    [ -f "$TMP/ready/$paper_pid" ] && break
  sleep 0.05
  ticks=$((ticks + 1))
done
[ -n "${paper_pid:-}" ] && [ "$paper_pid" != "$launcher_pid" ] ||
  fail "paper app never became foreground"
ticks=0
while [ "$ticks" -lt 160 ]; do
  grep -q "^dev.example.paper $paper_pid\$" "$TMP/watchers" 2>/dev/null &&
    break
  sleep 0.05
  ticks=$((ticks + 1))
done
grep -q "^dev.example.paper $paper_pid\$" "$TMP/watchers" 2>/dev/null ||
  fail "supervisor did not pass the current app id to its watcher"
[ ! -e "$TMP/bad-watcher-pid" ] ||
  fail "watcher started before the foreground pid was published"

# A bare/stale shutdown marker is not authority to stop an arbitrary app.
: > "$CTL/poweroff"
wait_for_absent "$CTL/poweroff" ||
  fail "unauthorized poweroff marker was not consumed"
[ "$(cat "$CTL/embedder.pid" 2>/dev/null || true)" = "$paper_pid" ] ||
  fail "unauthorized poweroff disturbed the foreground app"
kill -0 "$paper_pid" 2>/dev/null ||
  fail "unauthorized poweroff terminated the foreground app"
[ ! -e "$TMP/poweroff-count" ] ||
  fail "unauthorized poweroff invoked the platform command"
grep -q 'refused power off request outside active launcher power menu' \
  "$TMP/session.log" || fail "unauthorized poweroff refusal was not logged"

# Remove the background launcher registration so the first power menu must use
# the cold-host entrypoint. The app itself must remain warm throughout.
rm -f "$CTL/warm-apps/dev.pluto.launcher.pid" \
  "$CTL/warm-apps/dev.pluto.launcher.used"
kill -TERM "$launcher_pid" 2>/dev/null || true
kill -CONT "$launcher_pid" 2>/dev/null || true
wait_for_dead "$launcher_pid" || fail "old warm launcher did not exit"
rm -f "$CTL/hibernated/$launcher_pid"

printf 'dev.example.paper\n' > "$CTL/power-menu"
wait_for_value "$CTL/power-menu-active" dev.example.paper ||
  fail "power menu did not publish its cancel origin"
ticks=0
while [ "$ticks" -lt 160 ]; do
  menu_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$menu_pid" ] && [ "$menu_pid" != "$paper_pid" ] &&
    [ -f "$TMP/ready/$menu_pid" ] && break
  sleep 0.05
  ticks=$((ticks + 1))
done
[ -n "${menu_pid:-}" ] && [ "$menu_pid" != "$paper_pid" ] ||
  fail "launcher never became the power-menu host"
[ -f "$CTL/hibernated/$paper_pid" ] ||
  fail "power menu did not hibernate its origin"
kill -0 "$paper_pid" 2>/dev/null ||
  fail "power menu killed its warm origin"
grep '^dev.pluto.launcher ' "$TMP/invocations" | tail -n 1 |
  grep -q -- '--dart-entrypoint-args=--power-menu' ||
  fail "cold power-menu host did not receive its entrypoint argument"

# A short press while the power menu is visible remains the ordinary standby
# path. It clears the power route, publishes a warm-launcher reset, never arms a
# watcher on the standby child, and recovers the normal launcher after exit.
printf 'power-button\n' > "$CTL/standby"
wait_for_file "$TMP/saw-standby" ||
  fail "standby was not launched from the power menu"
wait_for_absent "$CTL/power-menu-active" ||
  fail "standby from power menu left stale active state"
wait_for_file "$CTL/system-ui-reset" ||
  fail "standby from power menu did not request a route reset"
[ ! -e "$TMP/standby-watcher-failure" ] ||
  fail "standby launcher incorrectly received a power watcher"
wait_for_value "$CTL/embedder.pid" "$menu_pid" ||
  fail "normal launcher did not recover after standby child exit"
rm -f "$CTL/system-ui-reset"
printf 'dev.example.paper\n' > "$CTL/launch"
wait_for_value "$CTL/embedder.pid" "$paper_pid" ||
  fail "post-standby launcher did not resume the warm origin"

# Cancel uses the ordinary launch request and must resume the exact origin PID.
printf 'dev.example.paper\n' > "$CTL/power-menu"
wait_for_value "$CTL/power-menu-active" dev.example.paper ||
  fail "power-menu cancel activation was not published"
wait_for_value "$CTL/embedder.pid" "$menu_pid" ||
  fail "launcher did not resume to host the cancel scenario"
printf 'dev.example.paper\n' > "$CTL/launch"
wait_for_value "$CTL/embedder.pid" "$paper_pid" ||
  fail "power-menu cancel did not resume the origin pid"
wait_for_absent "$CTL/power-menu-active" ||
  fail "power-menu cancel left stale active state"
[ "$(cat "$TMP/starts/dev.example.paper")" -eq 1 ] ||
  fail "power-menu cancel cold-started its origin"

# Reopening uses the same warm launcher host. Killing that temporary host must
# recover the same app from power-menu-active without a user selection.
printf 'dev.example.paper\n' > "$CTL/power-menu"
wait_for_value "$CTL/power-menu-active" dev.example.paper ||
  fail "second power-menu activation was not published"
wait_for_value "$CTL/embedder.pid" "$menu_pid" ||
  fail "power menu did not reuse the warm launcher host"
kill -TERM "$menu_pid" 2>/dev/null || true
wait_for_value "$CTL/embedder.pid" "$paper_pid" ||
  fail "power-menu host crash did not recover the origin"
wait_for_absent "$CTL/power-menu-active" ||
  fail "power-menu host crash left stale active state"

# A failed platform poweroff is consumed and recovers Home after the pool has
# been drained. This keeps the panel usable when systemctl rejects the request.
printf 'dev.example.paper\n' > "$CTL/power-menu"
wait_for_value "$CTL/power-menu-active" dev.example.paper ||
  fail "power-menu activation before failed poweroff was not published"
rm -f "$TMP/poweroff-host-hibernated"
printf 'ui\n' > "$CTL/poweroff"
wait_for_value "$TMP/poweroff-count" 1 ||
  fail "failed poweroff command was not invoked"
wait_for_absent "$CTL/poweroff" || fail "failed poweroff marker was not consumed"
kill -0 "$SESSION_PID" 2>/dev/null ||
  fail "failed poweroff terminated the supervisor"
ticks=0
while [ "$ticks" -lt 160 ]; do
  recovered_launcher=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$recovered_launcher" ] &&
    [ -f "$TMP/ready/$recovered_launcher" ] && break
  sleep 0.05
  ticks=$((ticks + 1))
done
[ -n "${recovered_launcher:-}" ] ||
  fail "failed poweroff did not recover the launcher"
[ ! -e "$TMP/not-drained" ] ||
  fail "poweroff command ran before the warm pool was drained"
[ ! -e "$TMP/poweroff-host-not-hibernated" ] ||
  fail "poweroff command ran before the launcher hibernated"
grep -q 'power off command failed rc=9; recovering launcher' \
  "$TMP/session.log" || fail "failed poweroff recovery was not logged"

# A debug/JIT foreground is deliberately not warm-resumable. Opening the menu
# must terminate it promptly (rather than waiting the hibernate timeout), save
# Home as the cancel target, and never register or resume that debug process.
printf 'dev.example.debug\n' > "$CTL/debug-launch"
kill -TERM "$recovered_launcher" 2>/dev/null || true
ticks=0
while [ "$ticks" -lt 160 ]; do
  debug_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$debug_pid" ] && [ "$debug_pid" != "$recovered_launcher" ] &&
    [ -f "$TMP/ready/$debug_pid" ] && break
  sleep 0.05
  ticks=$((ticks + 1))
done
[ -n "${debug_pid:-}" ] && [ "$debug_pid" != "$recovered_launcher" ] ||
  fail "explicit debug app never became foreground"
grep '^dev.example.debug ' "$TMP/invocations" | tail -n 1 |
  grep -q -- '--debug' || fail "debug app did not use the JIT engine mode"
[ ! -e "$CTL/warm-apps/dev.example.debug.pid" ] ||
  fail "debug app entered the warm pool"
printf 'dev.example.debug\n' > "$CTL/power-menu"
ticks=0
while [ "$ticks" -lt 40 ]; do
  active=$(cat "$CTL/power-menu-active" 2>/dev/null || true)
  foreground=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ "$active" = dev.pluto.launcher ] &&
    [ -n "$foreground" ] && [ "$foreground" != "$debug_pid" ] &&
    [ -f "$TMP/ready/$foreground" ] && break
  sleep 0.05
  ticks=$((ticks + 1))
done
[ "$(cat "$CTL/power-menu-active" 2>/dev/null || true)" = \
    dev.pluto.launcher ] ||
  fail "non-warm power menu did not use Home as its safe cancel origin"
[ -n "${foreground:-}" ] && [ "$foreground" != "$debug_pid" ] ||
  fail "non-warm power menu waited for the hibernate timeout"
debug_menu_pid="$foreground"
wait_for_dead "$debug_pid" ||
  fail "non-warm debug origin survived the power-menu handoff"
[ "$(cat "$TMP/starts/dev.example.debug")" -eq 1 ] ||
  fail "non-warm debug origin was relaunched without authorization"
printf 'dev.pluto.launcher\n' > "$CTL/launch"
wait_for_absent "$CTL/power-menu-active" ||
  fail "non-warm power-menu cancel left stale active state"
wait_for_value "$CTL/embedder.pid" "$debug_menu_pid" ||
  fail "non-warm power-menu cancel did not stay on Home"

# Exercise the success receipt separately: the marker is consumed, every warm
# process is drained, the configured command runs, and the supervisor exits 0.
printf 'dev.example.paper\n' > "$CTL/launch"
ticks=0
while [ "$ticks" -lt 160 ]; do
  new_paper_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  registered_paper_pid=$(cat \
    "$CTL/warm-apps/dev.example.paper.pid" 2>/dev/null || true)
  [ -n "$new_paper_pid" ] && [ "$new_paper_pid" = "$registered_paper_pid" ] &&
    [ -f "$TMP/ready/$new_paper_pid" ] && break
  sleep 0.05
  ticks=$((ticks + 1))
done
[ -n "${new_paper_pid:-}" ] &&
  [ "$new_paper_pid" = "${registered_paper_pid:-}" ] ||
  fail "paper app did not relaunch after failed poweroff"
printf 'dev.example.paper\n' > "$CTL/power-menu"
wait_for_value "$CTL/power-menu-active" dev.example.paper ||
  fail "final power-menu activation was not published"
: > "$TMP/allow-poweroff"
rm -f "$TMP/poweroff-host-hibernated"
printf 'ui\n' > "$CTL/poweroff"
ticks=0
while [ "$ticks" -lt 160 ]; do
  kill -0 "$SESSION_PID" 2>/dev/null || break
  sleep 0.05
  ticks=$((ticks + 1))
done
kill -0 "$SESSION_PID" 2>/dev/null &&
  fail "successful poweroff did not exit the supervisor"
wait "$SESSION_PID" || fail "supervisor returned failure after poweroff"
SESSION_PID=""

[ "$(cat "$TMP/poweroff-count")" -eq 2 ] ||
  fail "poweroff command was not invoked exactly twice"
[ ! -e "$TMP/not-drained" ] ||
  fail "successful poweroff ran before the warm pool was drained"
[ ! -e "$TMP/poweroff-host-not-hibernated" ] ||
  fail "successful poweroff ran before the launcher hibernated"
[ ! -e "$CTL/poweroff" ] || fail "successful poweroff marker was not consumed"
[ ! -e "$CTL/power-menu-active" ] ||
  fail "successful poweroff left stale power-menu state"
[ ! -e "$CTL/embedder.pid" ] ||
  fail "successful poweroff left a foreground pid published"
for pid_file in "$CTL/warm-apps"/*.pid; do
  [ ! -f "$pid_file" ] || fail "successful poweroff left a warm registration"
done
grep -q 'power off command accepted; supervisor done' "$TMP/session.log" ||
  fail "successful poweroff exit was not logged"

echo "power-menu supervisor test: PASS"
