#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SUPERVISOR="$HERE/../pluto-session.sh"
TMP=${TMPDIR:-/tmp}/pluto-session-switcher-test.$$
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
  echo "app switcher supervisor test: $*" >&2
  [ ! -f "$TMP/session.log" ] || cat "$TMP/session.log" >&2
  exit 1
}

wait_for_value() {
  path="$1" expected="$2"
  for _ in $(seq 1 120); do
    [ "$(cat "$path" 2>/dev/null || true)" = "$expected" ] && return 0
    sleep 0.05
  done
  return 1
}

wait_for_file() {
  path="$1"
  for _ in $(seq 1 120); do
    [ -f "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

mkdir -p "$TMP/bin" "$ROOT/bin" "$ROOT/engine/release" \
  "$ROOT/launcher/bundle/lib" "$ROOT/apps/dev.example.paper/bundle/lib" \
  "$ROOT/apps/dev.example.third/bundle/lib" \
  "$ROOT/logs" "$ROOT/state" "$CTL" "$TMP/starts"
: > "$ROOT/engine/release/libflutter_engine.so"
: > "$ROOT/launcher/bundle/lib/app.so"
: > "$ROOT/launcher/bundle/icudtl.dat"
: > "$ROOT/apps/dev.example.paper/bundle/lib/app.so"
: > "$ROOT/apps/dev.example.paper/bundle/icudtl.dat"
: > "$ROOT/apps/dev.example.third/bundle/lib/app.so"
: > "$ROOT/apps/dev.example.third/bundle/icudtl.dat"
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
hibernate() {
  mkdir -p "$PLUTO_RUN_DIR/hibernated" "$PLUTO_RUN_DIR/previews"
  printf 'BMpreview:%s\n' "$PLUTO_APP_ID" > \
    "$PLUTO_RUN_DIR/previews/$PLUTO_APP_ID.bmp"
  printf 'paused\n' > "$marker.tmp"
  mv -f "$marker.tmp" "$marker"
}
trap hibernate USR1
trap 'rm -f "$marker"' USR2
trap 'rm -f "$marker"; exit 0' TERM INT
: > "$PLUTO_TEST_STARTS/$PLUTO_APP_ID.ready"
while :; do sleep 0.05; done
EMBEDDER
chmod +x "$TMP/bin/systemctl" "$ROOT/bin/pluto-embedder"

PATH="$TMP/bin:$PATH" \
PLUTO_ROOT="$ROOT" \
PLUTO_RUN_DIR="$CTL" \
PLUTO_POWER_WATCHER="$ROOT/bin/missing-power-watcher" \
PLUTO_UPTIME_FILE="$TMP/uptime" \
PLUTO_HIBERNATE_WAIT_TICKS=120 \
PLUTO_RESUME_WAIT_TICKS=120 \
PLUTO_MAX_WARM_APPS=4 \
PLUTO_TEST_STARTS="$TMP/starts" \
PLUTO_TEST_INVOCATIONS="$TMP/invocations" \
  sh "$SUPERVISOR" start > "$TMP/session.log" 2>&1 &
SESSION_PID=$!

for _ in $(seq 1 120); do
  launcher_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$launcher_pid" ] && break
  sleep 0.05
done
[ -n "${launcher_pid:-}" ] || fail "launcher never became foreground"
wait_for_file "$TMP/starts/dev.pluto.launcher.ready" ||
  fail "launcher did not install its signal handlers"

# Home is a valid switcher origin even when it is the only resident process.
# The activation must contain the hidden launcher origin and no cards, while
# the same warm launcher process hosts the empty Flutter state.
printf 'dev.pluto.launcher\n' > "$CTL/switcher"
wait_for_value "$CTL/switcher-active" 'dev.pluto.launcher' ||
  fail "empty switcher activation was not published from Home"
wait_for_value "$CTL/embedder.pid" "$launcher_pid" ||
  fail "empty switcher reconstructed the launcher host"
[ "$(wc -l < "$CTL/switcher-active")" -eq 1 ] ||
  fail "empty switcher unexpectedly published an app card"
: > "$CTL/home"
for _ in $(seq 1 120); do
  [ ! -e "$CTL/switcher-active" ] &&
    [ "$(cat "$CTL/embedder.pid" 2>/dev/null || true)" = "$launcher_pid" ] &&
    break
  sleep 0.05
done
[ ! -e "$CTL/switcher-active" ] ||
  fail "empty switcher did not return to Home"
rm -f "$CTL/system-ui-reset"

printf 'dev.example.paper\n' > "$CTL/launch"
for _ in $(seq 1 120); do
  paper_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$paper_pid" ] && [ "$paper_pid" != "$launcher_pid" ] && break
  sleep 0.05
done
[ -n "${paper_pid:-}" ] || fail "paper app never became foreground"
wait_for_file "$TMP/starts/dev.example.paper.ready" ||
  fail "paper app did not install its signal handlers"

printf 'dev.example.third\n' > "$CTL/launch"
for _ in $(seq 1 120); do
  third_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$third_pid" ] && [ "$third_pid" != "$paper_pid" ] && break
  sleep 0.05
done
[ -n "${third_pid:-}" ] || fail "third app never became foreground"
wait_for_file "$TMP/starts/dev.example.third.ready" ||
  fail "third app did not install its signal handlers"

printf 'dev.example.paper\n' > "$CTL/launch"
wait_for_value "$CTL/embedder.pid" "$paper_pid" ||
  fail "paper app did not resume before opening the switcher"

# This marker is the supervisor-facing result of the native two-finger edge
# recognizer. The supervisor must hibernate the origin without reconstructing
# it, snapshot recency before waking the launcher, and preserve all previews.
printf 'dev.example.paper\n' > "$CTL/switcher"
wait_for_value "$CTL/embedder.pid" "$launcher_pid" ||
  fail "warm launcher did not become the switcher host"
wait_for_file "$CTL/switcher-active" ||
  fail "supervisor did not publish switcher state"

state=$(cat "$CTL/switcher-active")
expected='dev.example.paper
dev.example.third'
[ "$state" = "$expected" ] ||
  fail "switcher order was not origin then MRU third app: $state"
for id in dev.example.paper dev.example.third dev.pluto.launcher; do
  wait_for_file "$CTL/previews/$id.bmp" ||
    fail "missing captured preview for $id"
done
[ "$(cat "$TMP/starts/dev.pluto.launcher")" -eq 1 ] ||
  fail "switcher cold-started an already warm launcher"
kill -0 "$paper_pid" 2>/dev/null || fail "origin was killed by the switcher"
[ -f "$CTL/hibernated/$paper_pid" ] ||
  fail "origin did not remain safely hibernated"

printf 'dev.example.third\n' > "$CTL/launch"
wait_for_value "$CTL/embedder.pid" "$third_pid" ||
  fail "selecting the first preview did not resume its original pid"
[ ! -e "$CTL/switcher-active" ] ||
  fail "selection did not consume active switcher state"
[ "$(cat "$TMP/starts/dev.example.third")" -eq 1 ] ||
  fail "selected app was cold-started instead of resumed"

# Open the switcher again immediately. Temporary launcher hosting must not
# make the launcher more recent than the app we just left.
printf 'dev.example.third\n' > "$CTL/switcher"
wait_for_value "$CTL/embedder.pid" "$launcher_pid" ||
  fail "launcher did not host the second switcher activation"
expected='dev.example.third
dev.example.paper'
wait_for_value "$CTL/switcher-active" "$expected" ||
  fail "temporary launcher hosting polluted second-activation MRU order"

printf 'dev.example.paper\n' > "$CTL/launch"
wait_for_value "$CTL/embedder.pid" "$paper_pid" ||
  fail "second switcher activation did not resume the previous app"

# Kill the switcher host without a selection. The supervisor must consume the
# activation and resume the origin rather than stranding it SIGSTOPped.
printf 'dev.example.paper\n' > "$CTL/switcher"
wait_for_value "$CTL/embedder.pid" "$launcher_pid" ||
  fail "launcher did not host the crash-recovery activation"
kill -TERM "$launcher_pid" 2>/dev/null || true
wait_for_value "$CTL/embedder.pid" "$paper_pid" ||
  fail "switcher-host crash did not resume the origin"
[ ! -e "$CTL/switcher-active" ] ||
  fail "switcher-host crash left stale activation state"

# With the old launcher gone, the next activation exercises the cold-host
# entrypoint argument while preserving the already warm app PIDs.
printf 'dev.example.paper\n' > "$CTL/switcher"
for _ in $(seq 1 120); do
  cold_launcher_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$cold_launcher_pid" ] &&
    [ "$cold_launcher_pid" != "$paper_pid" ] &&
    [ "$cold_launcher_pid" != "$launcher_pid" ] && break
  sleep 0.05
done
[ -n "${cold_launcher_pid:-}" ] && [ "$cold_launcher_pid" != "$paper_pid" ] ||
  fail "cold switcher host never became foreground"
[ "$(cat "$TMP/starts/dev.pluto.launcher")" -eq 2 ] ||
  fail "launcher cold-host start count was not exactly two"
grep '^dev.pluto.launcher ' "$TMP/invocations" | tail -n 1 |
  grep -q -- '--dart-entrypoint-args=--switcher' ||
  fail "cold switcher host did not receive its entrypoint argument"

printf 'dev.example.third\n' > "$CTL/launch"
wait_for_value "$CTL/embedder.pid" "$third_pid" ||
  fail "cold-host selection did not resume the existing target pid"

# The top-edge system status path uses the same warm launcher without touching
# app recency, and a normal selection returns to the exact origin PID.
printf 'dev.example.third\n' > "$CTL/status"
wait_for_value "$CTL/embedder.pid" "$cold_launcher_pid" ||
  fail "warm launcher did not become the status host"
wait_for_value "$CTL/status-active" 'dev.example.third' ||
  fail "status host did not publish its origin"
[ -f "$CTL/hibernated/$third_pid" ] ||
  fail "status shade did not leave the origin safely hibernated"
printf 'dev.example.third\n' > "$CTL/launch"
wait_for_value "$CTL/embedder.pid" "$third_pid" ||
  fail "status dismissal did not resume the origin pid"
[ ! -e "$CTL/status-active" ] ||
  fail "status dismissal left stale active state"

# Host-crash recovery is shared by both system overlays.
printf 'dev.example.third\n' > "$CTL/status"
wait_for_value "$CTL/embedder.pid" "$cold_launcher_pid" ||
  fail "launcher did not host the status crash test"
kill -TERM "$cold_launcher_pid" 2>/dev/null || true
wait_for_value "$CTL/embedder.pid" "$third_pid" ||
  fail "status-host crash did not recover the origin"
[ ! -e "$CTL/status-active" ] ||
  fail "status-host crash left stale active state"

# A missing launcher starts directly on the status entrypoint and remains a
# neutral-recency temporary host.
printf 'dev.example.third\n' > "$CTL/status"
for _ in $(seq 1 120); do
  status_launcher_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$status_launcher_pid" ] &&
    [ "$status_launcher_pid" != "$third_pid" ] &&
    [ "$status_launcher_pid" != "$cold_launcher_pid" ] && break
  sleep 0.05
done
[ -n "${status_launcher_pid:-}" ] &&
  [ "$status_launcher_pid" != "$third_pid" ] ||
  fail "cold status host never became foreground"
[ "$(cat "$TMP/starts/dev.pluto.launcher")" -eq 3 ] ||
  fail "cold status host start count was not exactly three"
grep '^dev.pluto.launcher ' "$TMP/invocations" | tail -n 1 |
  grep -q -- '--dart-entrypoint-args=--status' ||
  fail "cold status host did not receive its entrypoint argument"
grep '^dev.example.third ' "$TMP/invocations" | grep -q -- '--bezel-redraw' ||
  fail "foreground apps did not receive the bezel redraw gesture"
if grep -q -- '--home-tap' "$TMP/invocations"; then
  fail "retired bezel Home argument is still wired"
fi
printf 'dev.example.third\n' > "$CTL/launch"
wait_for_value "$CTL/embedder.pid" "$third_pid" ||
  fail "cold status host did not return to the origin pid"

# Standby while a system host is visible clears the activation, but the warm
# launcher still retains that route. Publish an explicit reset marker so native
# presentation stays gated until Flutter has restored Home after wake.
printf 'dev.example.third\n' > "$CTL/switcher"
wait_for_value "$CTL/embedder.pid" "$status_launcher_pid" ||
  fail "launcher did not host the standby reset scenario"
: > "$CTL/standby"
for _ in $(seq 1 120); do
  standby_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$standby_pid" ] && [ "$standby_pid" != "$status_launcher_pid" ] &&
    break
  sleep 0.05
done
[ -n "${standby_pid:-}" ] && [ "$standby_pid" != "$status_launcher_pid" ] ||
  fail "standby launcher did not replace the warm switcher host"
wait_for_file "$CTL/system-ui-reset" ||
  fail "standby from switcher did not request a stale-route reset"
kill -TERM "$standby_pid" 2>/dev/null || true
wait_for_value "$CTL/embedder.pid" "$status_launcher_pid" ||
  fail "warm launcher did not resume after standby host exit"
rm -f "$CTL/system-ui-reset"
printf 'dev.example.third\n' > "$CTL/launch"
wait_for_value "$CTL/embedder.pid" "$third_pid" ||
  fail "post-standby launcher did not resume the prior app"

# The switcher dismiss gesture writes a force-stop request without handing off
# the launcher host. The supervisor must terminate the selected warm process,
# remove its registration/preview/card, and leave the switcher itself running.
printf 'dev.example.third\n' > "$CTL/switcher"
wait_for_value "$CTL/embedder.pid" "$status_launcher_pid" ||
  fail "launcher did not host the force-stop scenario"
printf 'dev.example.paper\n' > "$CTL/force-stop"
for _ in $(seq 1 120); do
  if ! kill -0 "$paper_pid" 2>/dev/null &&
     [ ! -e "$CTL/warm-apps/dev.example.paper.pid" ]; then
    break
  fi
  sleep 0.05
done
kill -0 "$paper_pid" 2>/dev/null &&
  fail "switcher force-stop left the selected process alive"
[ ! -e "$CTL/warm-apps/dev.example.paper.pid" ] ||
  fail "switcher force-stop left the selected app registered"
wait_for_value "$CTL/switcher-active" 'dev.example.third' ||
  fail "switcher force-stop left a stale preview in active state"
wait_for_value "$CTL/embedder.pid" "$status_launcher_pid" ||
  fail "switcher force-stop tore down the launcher host"
printf 'dev.example.third\n' > "$CTL/launch"
wait_for_value "$CTL/embedder.pid" "$third_pid" ||
  fail "force-stop scenario did not return to the origin app"

: > "$CTL/stock"
kill -TERM "$third_pid" 2>/dev/null || true
for _ in $(seq 1 120); do
  kill -0 "$SESSION_PID" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$SESSION_PID" 2>/dev/null && fail "supervisor did not exit to stock"
wait "$SESSION_PID" || fail "supervisor returned failure"
SESSION_PID=""

echo "app switcher supervisor test: PASS"
