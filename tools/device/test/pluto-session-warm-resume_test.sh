#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SUPERVISOR="$HERE/../pluto-session.sh"
PROFILE_FILE="$HERE/../generated/device-profiles.sh"
TMP=${TMPDIR:-/tmp}/pluto-session-warm-resume-test.$$
ROOT="$TMP/root"
CTL="$TMP/run"
SESSION_PID=""

cleanup() {
  [ -z "$SESSION_PID" ] || kill "$SESSION_PID" 2>/dev/null || true
  for pid_file in "$CTL/warm-apps"/*.pid; do
    [ -f "$pid_file" ] || continue
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [ -z "$pid" ] || { kill -TERM "$pid" 2>/dev/null || true; kill -CONT "$pid" 2>/dev/null || true; }
  done
  rm -rf "$TMP"
}
trap cleanup 0

fail() {
  echo "warm resume supervisor test: $*" >&2
  [ ! -f "$TMP/session.log" ] || cat "$TMP/session.log" >&2
  exit 1
}

grep -Fq 'HIBERNATE_WAIT_TICKS="${PLUTO_HIBERNATE_WAIT_TICKS:-240}"' \
  "$SUPERVISOR" ||
  fail "default hibernate envelope no longer exceeds native detach"

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

wait_for_absent() {
  path="$1"
  for _ in $(seq 1 120); do
    [ ! -e "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

mkdir -p "$TMP/bin" "$ROOT/bin" "$ROOT/engine/release" \
  "$ROOT/launcher/bundle/lib" "$ROOT/apps/dev.example.paper/bundle/lib" \
  "$ROOT/apps/dev.example.third/bundle/lib" \
  "$ROOT/logs" "$ROOT/state" "$CTL"
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
  if [ -f "$PLUTO_TEST_STARTS/$PLUTO_APP_ID.never-hibernate" ]; then
    return
  fi
  slow_token="$PLUTO_TEST_STARTS/.slow-hibernate-used"
  if [ "${PLUTO_TEST_SLOW_HIBERNATE_APP:-}" = "$PLUTO_APP_ID" ] &&
     mkdir "$slow_token" 2>/dev/null; then
    # Prove the supervisor accepts a safe close beyond the old 6s envelope.
    sleep 6.2
  fi
  mkdir -p "$PLUTO_RUN_DIR/hibernated"
  printf "paused\n" > "$marker.tmp"
  mv -f "$marker.tmp" "$marker"
}
trap hibernate USR1
trap 'rm -f "$marker"' USR2
trap 'rm -f "$marker"; exit 0' TERM INT
: > "$PLUTO_TEST_STARTS/$PLUTO_APP_ID.ready"
while :; do sleep 0.05; done
EMBEDDER
chmod +x "$TMP/bin/systemctl" "$ROOT/bin/pluto-embedder"
mkdir -p "$TMP/starts"

PATH="$TMP/bin:$PATH" \
PLUTO_ROOT="$ROOT" \
PLUTO_PROFILE_FILE="$PROFILE_FILE" \
PLUTO_TESTING=1 \
PLUTO_TEST_PROFILE_ID=rm1 \
PLUTO_RUN_DIR="$CTL" \
PLUTO_POWER_WATCHER="$ROOT/bin/missing-power-watcher" \
PLUTO_UPTIME_FILE="$TMP/uptime" \
PLUTO_HIBERNATE_WAIT_TICKS=240 \
PLUTO_RESUME_WAIT_TICKS=120 \
PLUTO_TEST_SLOW_HIBERNATE_APP=dev.pluto.launcher \
PLUTO_TEST_STARTS="$TMP/starts" \
PLUTO_TEST_INVOCATIONS="$TMP/invocations" \
  sh "$SUPERVISOR" start > "$TMP/session.log" 2>&1 &
SESSION_PID=$!

for _ in $(seq 1 220); do
  launcher_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$launcher_pid" ] && break
  sleep 0.05
done
[ -n "${launcher_pid:-}" ] || fail "launcher never became foreground"
grep -q 'profile accepted: rm1 .* resident=2' "$TMP/session.log" ||
  fail "RM1 generated resident-process limit was not applied"
wait_for_value "$TMP/starts/dev.pluto.launcher" 1 ||
  fail "launcher test process did not finish installing signal handlers"
wait_for_file "$TMP/starts/dev.pluto.launcher.ready" ||
  fail "launcher test process did not install signal handlers"

printf 'dev.example.paper\n' > "$CTL/launch"
for _ in $(seq 1 120); do
  paper_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$paper_pid" ] && [ "$paper_pid" != "$launcher_pid" ] && break
  sleep 0.05
done
[ -n "${paper_pid:-}" ] && [ "$paper_pid" != "$launcher_pid" ] ||
  fail "paper app never became foreground"
[ -f "$CTL/hibernated/$launcher_pid" ] ||
  fail "launcher did not acknowledge native-resource quiesce"
grep -q "hibernated 'dev.pluto.launcher' pid=$launcher_pid" \
  "$TMP/session.log" ||
  fail "safe acknowledgement beyond the old 6s envelope fell back cold"
kill -0 "$launcher_pid" 2>/dev/null ||
  fail "launcher process did not remain resident"

: > "$CTL/home"
wait_for_value "$CTL/embedder.pid" "$launcher_pid" ||
  fail "launcher did not resume with its original pid"
[ ! -f "$CTL/hibernated/$launcher_pid" ] ||
  fail "launcher resume acknowledgement was not consumed"
[ "$(cat "$TMP/starts/dev.pluto.launcher")" -eq 1 ] ||
  fail "launcher was cold-started instead of resumed"
[ "$(cat "$TMP/starts/dev.example.paper")" -eq 1 ] ||
  fail "paper app start count changed unexpectedly"
[ -f "$CTL/hibernated/$paper_pid" ] ||
  fail "paper app was not retained in the warm pool"
grep '^dev.pluto.launcher ' "$TMP/invocations" | grep -q -- '--release .*--hibernate' ||
  fail "release launcher did not opt into hibernation"
grep '^dev.example.paper ' "$TMP/invocations" | grep -q -- '--release .*--hibernate' ||
  fail "release app did not opt into hibernation"

printf 'dev.example.third\n' > "$CTL/launch"
for _ in $(seq 1 120); do
  third_pid=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$third_pid" ] && [ "$third_pid" != "$launcher_pid" ] && break
  sleep 0.05
done
[ -n "${third_pid:-}" ] && [ "$third_pid" != "$launcher_pid" ] ||
  fail "third app never became foreground"
for _ in $(seq 1 120); do
  kill -0 "$paper_pid" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$paper_pid" 2>/dev/null &&
  fail "LRU did not evict the oldest app at the RM1 profile limit"
[ ! -e "$CTL/warm-apps/dev.example.paper.pid" ] ||
  fail "LRU left the evicted app registered"
[ "$(find "$CTL/warm-apps" -name '*.pid' -type f | wc -l | tr -d ' ')" -eq 2 ] ||
  fail "warm pool exceeded its total resident limit"

# A release process that never acknowledges still gets a bounded cold
# successor under the widened production timeout. It must not leave a warm
# registration or marker that could later resume an unquiesced owner.
: > "$TMP/starts/dev.example.third.never-hibernate"
: > "$CTL/home"
for _ in $(seq 1 280); do
  recovered_launcher=$(cat "$CTL/embedder.pid" 2>/dev/null || true)
  [ -n "$recovered_launcher" ] && [ "$recovered_launcher" != "$third_pid" ] &&
    break
  sleep 0.05
done
[ -n "${recovered_launcher:-}" ] && [ "$recovered_launcher" != "$third_pid" ] ||
  fail "never-ack process did not fall back to a bounded cold successor"
kill -0 "$third_pid" 2>/dev/null &&
  fail "never-ack process survived the cold fallback"
[ ! -e "$CTL/warm-apps/dev.example.third.pid" ] ||
  fail "never-ack process remained registered in the warm pool"
[ ! -e "$CTL/hibernated/$third_pid" ] ||
  fail "never-ack process left a resumable hibernate marker"
grep -q "hibernate acknowledgement failed for 'dev.example.third' pid=$third_pid; cold fallback" \
  "$TMP/session.log" || fail "never-ack cold fallback was not logged"
wait_for_absent "$CTL/hibernated/$recovered_launcher" ||
  fail "cold successor did not finish its resume acknowledgement"
sleep 0.2

: > "$CTL/stock"
kill -TERM "$third_pid" 2>/dev/null || true
for _ in $(seq 1 180); do
  kill -0 "$SESSION_PID" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$SESSION_PID" 2>/dev/null && fail "supervisor did not exit to stock"
wait "$SESSION_PID" || fail "supervisor returned failure"
SESSION_PID=""
kill -0 "$launcher_pid" 2>/dev/null && fail "stock exit did not drain warm apps"
grep -q "resumed 'dev.pluto.launcher' pid=$launcher_pid" "$TMP/session.log" ||
  fail "same-pid resume was not logged"

echo "warm resume supervisor test: PASS"
