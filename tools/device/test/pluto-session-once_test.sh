#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../pluto-session-once.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pluto-once-test.XXXXXX")"
ROOT="$TMP/root"
RUN="$TMP/run/pluto"
UNITS="$TMP/run/systemd/system"
BIN="$TMP/bin"
EVENTS="$TMP/events"
ACTIVE="$TMP/active"
PROC="$TMP/proc"
FIXTURE_PID=
FIXTURE_UPDATER_PID=
FIXTURE_INITIAL_PID=

stop_foreground_fixture() {
  if [[ -n "$FIXTURE_UPDATER_PID" ]]; then
    kill "$FIXTURE_UPDATER_PID" 2>/dev/null || true
    wait "$FIXTURE_UPDATER_PID" 2>/dev/null || true
    FIXTURE_UPDATER_PID=
  fi
  if [[ -n "$FIXTURE_PID" ]]; then
    kill "$FIXTURE_PID" 2>/dev/null || true
    wait "$FIXTURE_PID" 2>/dev/null || true
    FIXTURE_PID=
  fi
  FIXTURE_INITIAL_PID=
  rm -rf "$RUN" "$PROC"
  mkdir -p "$RUN" "$PROC"
}

cleanup() {
  stop_foreground_fixture
  rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$ROOT/bin" "$ROOT/share" "$ROOT/apps" "$ROOT/launcher/bundle/lib" \
  "$ROOT/engine/release" "$BIN" "$RUN" "$PROC"
cat > "$ROOT/bin/pluto-session.sh" <<'SUPERVISOR'
#!/bin/sh
exit 0
SUPERVISOR
: > "$ROOT/bin/pluto-embedder"
: > "$ROOT/launcher/bundle/icudtl.dat"
: > "$ROOT/launcher/bundle/lib/app.so"
: > "$ROOT/engine/release/libflutter_engine.so"
cp "$SCRIPT" "$ROOT/bin/pluto-session-once.sh"
cat > "$ROOT/share/device-profiles.sh" <<'PROFILES'
pluto_profile_load() {
  case "$1" in
    rm1) PLUTO_PROFILE_DISPLAY_DRIVER=mxcfb_epdc ;;
    rm2) PLUTO_PROFILE_DISPLAY_DRIVER=lcdif_tcon ;;
    move) PLUTO_PROFILE_DISPLAY_DRIVER=gallery3_drm ;;
    *) return 1 ;;
  esac
  PLUTO_PROFILE_NATIVE_SESSION_ENABLED=1
  PLUTO_PROFILE_WAVEFORM_OPTION_KEY=
  PLUTO_PROFILE_PRESENTER_OPTIONS=
  PLUTO_PROFILE_PEN_DEVICE=/dev/input/pen
  PLUTO_PROFILE_TOUCH_DEVICE=/dev/input/touch
  export PLUTO_PROFILE_DISPLAY_DRIVER PLUTO_PROFILE_NATIVE_SESSION_ENABLED
  export PLUTO_PROFILE_WAVEFORM_OPTION_KEY PLUTO_PROFILE_PRESENTER_OPTIONS
  export PLUTO_PROFILE_PEN_DEVICE PLUTO_PROFILE_TOUCH_DEVICE
}
pluto_profile_probe() { return 1; }
PROFILES
cat > "$ROOT/bin/pluto-rm2-cpufreq-restore.sh" <<'RESTORE'
#!/bin/sh
printf 'cpufreq-restore\n' >> "$PLUTO_TEST_EVENTS"
[ "${PLUTO_TEST_FAIL_CPUFREQ:-0}" != 1 ]
RESTORE
chmod 0755 "$ROOT/bin/pluto-session.sh" "$ROOT/bin/pluto-embedder" \
  "$ROOT/bin/pluto-session-once.sh" "$ROOT/bin/pluto-rm2-cpufreq-restore.sh"

cat > "$BIN/systemctl" <<'SYSTEMCTL'
#!/bin/sh
printf '%s\n' "$*" >> "$PLUTO_TEST_EVENTS"
case "$*" in
  'start pluto-session-once.service')
    if [ -n "${PLUTO_TEST_RUN:-}" ]; then
      [ ! -e "$PLUTO_TEST_RUN/embedder.pid" ] &&
        [ ! -L "$PLUTO_TEST_RUN/embedder.pid" ] || exit 95
      printf 'stale-pid-retired-before-start\n' >> "$PLUTO_TEST_EVENTS"
    fi
    [ "${PLUTO_TEST_FAIL_START:-0}" != 1 ] || exit 1
    if [ -n "${PLUTO_TEST_FOREGROUND_PID:-}" ]; then
      printf '%s\n' "$PLUTO_TEST_FOREGROUND_PID" \
        > "$PLUTO_TEST_RUN/embedder.pid"
    fi
    : > "$PLUTO_TEST_ACTIVE"
    ;;
  'stop pluto-session-once.service')
    [ "${PLUTO_TEST_FAIL_STOP:-0}" != 1 ] || exit 1
    rm -f "$PLUTO_TEST_ACTIVE"
    ;;
  'is-active --quiet pluto-session-once.service')
    [ -f "$PLUTO_TEST_ACTIVE" ] || exit 3
    ;;
  'show pluto-session-once.service -p ActiveState --value')
    [ "${PLUTO_TEST_FAIL_SHOW:-0}" != 1 ] || exit 1
    if [ -n "${PLUTO_TEST_ACTIVE_STATE:-}" ]; then
      printf '%s\n' "$PLUTO_TEST_ACTIVE_STATE"
    elif [ -f "$PLUTO_TEST_ACTIVE" ]; then
      printf 'active\n'
    else
      printf 'inactive\n'
    fi
    ;;
  'start xochitl.service')
    [ "${PLUTO_TEST_FAIL_STOCK_START:-0}" != 1 ] || exit 1
    ;;
esac
exit 0
SYSTEMCTL
chmod 0755 "$BIN/systemctl"

publish_fixture_health() {
  local sequence="$1"
  local monotonic_ms="$2"
  local temporary="$FIXTURE_HEALTH.tmp.$$"
  printf 'pid=%s seq=%s mono_ms=%s\n' \
    "$FIXTURE_PID" "$sequence" "$monotonic_ms" > "$temporary"
  chmod 0600 "$temporary"
  mv "$temporary" "$FIXTURE_HEALTH"
}

write_fixture_cmdline() {
  local bundle="$1"
  local executable="${2:-$ROOT/bin/pluto-embedder}"
  local presenter_options="${PLUTO_TEST_FIXTURE_PRESENTER_OPTIONS:-}"
  local touch_device="${PLUTO_TEST_FIXTURE_TOUCH_DEVICE:-/dev/input/touch}"
  local pen_device="${PLUTO_TEST_FIXTURE_PEN_DEVICE:-/dev/input/pen}"
  shift 2 || true
  printf '%s\0' \
    "$executable" \
    --release \
    "--bundle=$bundle" \
    "--engine=$ROOT/engine/release/libflutter_engine.so" \
    "--icu-data=$bundle/icudtl.dat" \
    --presenter=native \
    "--presenter-options=$presenter_options" \
    "--touch-device=$touch_device" \
    "--pen-device=$pen_device" \
    --rotation=0 \
    --allowed-rotations=0 \
    "--run-dir=$RUN" \
    "--ready-file=$FIXTURE_READY" \
    "--health-file=$FIXTURE_HEALTH" \
    "--aot-elf=$bundle/lib/app.so" \
    --hibernate \
    "$@" \
    > "$PROC/$FIXTURE_PID/cmdline"
}

rename_fixture_receipts() {
  local suffix="$1"
  local replacement_ready="$RUN/boot-ready.$suffix"
  local replacement_health="$RUN/health.$suffix"
  mv "$FIXTURE_READY" "$replacement_ready"
  mv "$FIXTURE_HEALTH" "$replacement_health"
  FIXTURE_READY=$replacement_ready
  FIXTURE_HEALTH=$replacement_health
  write_fixture_cmdline "$ROOT/launcher/bundle" "$ROOT/bin/pluto-embedder"
}

start_foreground_fixture() {
  local mode="$1"
  local suffix
  stop_foreground_fixture
  (
    trap 'exit 0' TERM INT
    while :; do sleep 1; done
  ) &
  FIXTURE_PID=$!
  suffix="manual-11111111-1111-4111-8111-111111111111.22222222-2222-4222-8222-222222222222-1"
  FIXTURE_READY="$RUN/boot-ready.$suffix"
  FIXTURE_HEALTH="$RUN/health.$suffix"
  mkdir -p "$PROC/$FIXTURE_PID"
  printf '%s (pluto-embedder) S 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 424242 0\n' \
    "$FIXTURE_PID" > "$PROC/$FIXTURE_PID/stat"
  printf '0::/system.slice/pluto-session-once.service\n' \
    > "$PROC/$FIXTURE_PID/cgroup"
  ln -s "$ROOT/bin/pluto-embedder" "$PROC/$FIXTURE_PID/exe"
  write_fixture_cmdline "$ROOT/launcher/bundle" "$ROOT/bin/pluto-embedder"
  printf '%s\n' "$FIXTURE_PID" > "$RUN/embedder.pid"
  printf 'ready\n' > "$FIXTURE_READY"
  chmod 0600 "$FIXTURE_READY"
  case "$mode" in
    success)
      publish_fixture_health 1 100
      (
        while [[ ! -f "$ACTIVE" ]]; do sleep 0.01; done
        # Keep the synthetic renderer progressing for the whole service
        # lifetime so a loaded runner cannot begin observing after a fixed
        # publication burst has already ended.
        sequence=2
        while [[ -f "$ACTIVE" ]]; do
          sleep 0.1
          [[ -f "$ACTIVE" ]] || break
          publish_fixture_health "$sequence" "$((sequence * 100))"
          sequence=$((sequence + 1))
        done
      ) &
      FIXTURE_UPDATER_PID=$!
      ;;
    frozen) publish_fixture_health 1 100 ;;
    single-advance)
      publish_fixture_health 1 100
      (
        while [[ ! -f "$ACTIVE" ]]; do sleep 0.01; done
        sleep 0.2
        publish_fixture_health 2 200
      ) &
      FIXTURE_UPDATER_PID=$!
      ;;
    dead-pre-ready | pre-ready-replacement)
      publish_fixture_health 1 100
      # Above every supported host/device pid_max; guaranteed not to name a
      # live process while remaining a canonical positive integer receipt.
      FIXTURE_INITIAL_PID=2147483647
      if [[ "$mode" == pre-ready-replacement ]]; then
        (
          while [[ ! -f "$ACTIVE" ]]; do sleep 0.01; done
          sleep 0.1
          printf '%s\n' "$FIXTURE_PID" > "$RUN/embedder.pid"
          # The replacement remains healthy until the service is stopped;
          # its evidence must not expire according to host scheduling speed.
          sequence=2
          while [[ -f "$ACTIVE" ]]; do
            sleep 0.1
            [[ -f "$ACTIVE" ]] || break
            publish_fixture_health "$sequence" "$((sequence * 100))"
            sequence=$((sequence + 1))
          done
        ) &
        FIXTURE_UPDATER_PID=$!
      fi
      ;;
    malformed)
      printf 'pid=%s seq=broken mono_ms=100\n' "$FIXTURE_PID" > "$FIXTURE_HEALTH"
      chmod 0600 "$FIXTURE_HEALTH"
      ;;
    identity-change)
      publish_fixture_health 1 100
      (
        while [[ ! -f "$ACTIVE" ]]; do sleep 0.01; done
        sleep 0.1
        printf '%s (pluto-embedder) S 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 999999 0\n' \
          "$FIXTURE_PID" > "$PROC/$FIXTURE_PID/stat"
        publish_fixture_health 2 200
      ) &
      FIXTURE_UPDATER_PID=$!
      ;;
    service-death)
      publish_fixture_health 1 100
      (
        while [[ ! -f "$ACTIVE" ]]; do sleep 0.01; done
        sleep 0.1
        rm -f "$ACTIVE"
      ) &
      FIXTURE_UPDATER_PID=$!
      ;;
    *) fail "unknown foreground fixture mode: $mode" ;;
  esac
}

run_once() {
  local profile="${PLUTO_TEST_PROFILE_ID:-rm1}"
  PLUTO_ROOT="$ROOT" \
  PLUTO_RUN_DIR="$RUN" \
  PLUTO_PROFILE_FILE="${PLUTO_TEST_ONCE_PROFILE_FILE:-$ROOT/share/device-profiles.sh}" \
  PLUTO_SYSTEMCTL="$BIN/systemctl" \
  PLUTO_SYSTEMD_RUNTIME_DIR="$UNITS" \
  PLUTO_TEST_EVENTS="$EVENTS" \
  PLUTO_TEST_ACTIVE="$ACTIVE" \
  PLUTO_TEST_RUN="$RUN" \
  PLUTO_TEST_FOREGROUND_PID="${FIXTURE_INITIAL_PID:-${FIXTURE_PID:-}}" \
  PLUTO_TESTING=1 \
  PLUTO_TEST_ONCE_PROC_ROOT="$PROC" \
  PLUTO_TEST_ONCE_HEALTH_ATTEMPTS="${PLUTO_TEST_GATE_ATTEMPTS:-20}" \
  PLUTO_TEST_ONCE_HEALTH_POLL_SECONDS=0.05 \
  PLUTO_TEST_PROFILE_ID="$profile" \
    sh "$SCRIPT" "$@"
}

expect_gate_rejection() {
  local label="$1"
  local result
  set +e
  run_once start > "$TMP/gate-rejection.out" 2>&1
  result=$?
  set -e
  [[ "$result" -ne 0 ]] || fail "$label returned success"
  [[ ! -e "$UNIT" ]] || fail "$label retained its transient unit"
  [[ ! -e "$ACTIVE" ]] || fail "$label left the service active"
  grep -q '^stop pluto-session-once.service$' "$EVENTS" ||
    fail "$label did not stop the transient service"
  grep -q '^start xochitl.service$' "$EVENTS" ||
    fail "$label did not request stock restore"
}

: > "$EVENTS"
start_foreground_fixture success
run_once start >/dev/null || fail "one-shot session did not start"
UNIT="$UNITS/pluto-session-once.service"
[ "$(cat "$RUN/embedder.pid")" = "$FIXTURE_PID" ] ||
  fail "new transient service did not publish its foreground PID receipt"
grep -q '^stale-pid-retired-before-start$' "$EVENTS" ||
  fail "stale foreground PID receipt survived until transient service start"
[ -f "$UNIT" ] || fail "runtime-only service was not published"
[ "$(stat -c '%a' "$UNIT" 2>/dev/null || stat -f '%Lp' "$UNIT")" = 644 ] ||
  fail "runtime-only service mode is not 0644"
grep -q '^Conflicts=xochitl.service$' "$UNIT" ||
  fail "one-shot service does not own the current stock session"
grep -q "^Environment=PLUTO_ROOT=$ROOT$" "$UNIT" ||
  fail "one-shot service has the wrong Pluto root"
grep -q "^Environment=PLUTO_RUN_DIR=$RUN$" "$UNIT" ||
  fail "one-shot service has the wrong control directory"
grep -q "^ExecStart=$ROOT/bin/pluto-session.sh start$" "$UNIT" ||
  fail "one-shot service does not start the common supervisor"
grep -q "^ExecStopPost=$ROOT/bin/pluto-session-once.sh restore-stock$" "$UNIT" ||
  fail "one-shot service does not use the profile-aware stock handoff"
if grep -q 'rm2-cpufreq' "$UNIT"; then
  fail "RM1 one-shot service embeds an RM2-only helper"
fi
grep -q '^Restart=no$' "$UNIT" ||
  fail "one-shot service can enter a restart loop"
[[ "$UNIT" == "$TMP/run/"* ]] || fail "one-shot service persisted outside /run"
run_once status | grep -q 'active' || fail "active status was not reported"

: > "$EVENTS"
run_once stop >/dev/null || fail "one-shot session did not stop"
[ ! -e "$UNIT" ] || fail "stopped one-shot service remained published"
grep -q '^stop pluto-session-once.service$' "$EVENTS" ||
  fail "stop did not end the transient supervisor"
if grep -q '^cpufreq-restore$' "$EVENTS"; then
  fail "RM1 explicit stop ran RM2 CPU-frequency recovery"
fi
grep -q '^start xochitl.service$' "$EVENTS" ||
  fail "stop did not request stock xochitl"
stop_foreground_fixture

# The supervisor may replace an embedder that exits before publishing any
# complete ready/health identity. A dead pre-ready PID is pending until the
# bounded supervisor retry publishes its replacement; it is not itself enough
# to consume the whole release transaction.
: > "$EVENTS"
start_foreground_fixture pre-ready-replacement
run_once start > "$TMP/pre-ready-replacement.out" 2>&1 || {
  cat "$TMP/pre-ready-replacement.out" >&2
  fail 'healthy replacement after a dead pre-ready PID was rejected'
}
[[ "$(cat "$RUN/embedder.pid")" == "$FIXTURE_PID" ]] ||
  fail 'pre-ready retry did not bind the replacement foreground'
[[ -e "$UNIT" && -e "$ACTIVE" ]] ||
  fail 'healthy pre-ready replacement did not retain the transient session'
run_once stop >/dev/null ||
  fail 'pre-ready replacement session did not stop cleanly'
stop_foreground_fixture

# A vanished process is only pending, never accepted. If the bounded
# supervisor cannot publish a healthy replacement, the fixed gate deadline
# still tears down the transient unit and restores stock.
: > "$EVENTS"
start_foreground_fixture dead-pre-ready
export PLUTO_TEST_GATE_ATTEMPTS=3
expect_gate_rejection 'permanently dead pre-ready foreground'
[[ "$(grep -c '^is-active --quiet pluto-session-once.service$' "$EVENTS")" == 4 ]] ||
  fail 'dead pre-ready foreground did not remain pending for the fixed gate bound'
unset PLUTO_TEST_GATE_ATTEMPTS
stop_foreground_fixture

# Exercise the real path-check/read gap: the receipt exists for the first
# lstat-style check, then vanishes before one_line can securely open it. Before
# any identity is latched this remains pending for the complete fixed bound.
cat > "$BIN/remove-pid-after-path-check" <<'REMOVE_PID_GAP'
#!/bin/sh
rm -f "$1"
REMOVE_PID_GAP
chmod 0755 "$BIN/remove-pid-after-path-check"
: > "$EVENTS"
start_foreground_fixture frozen
export PLUTO_TEST_GATE_ATTEMPTS=3
export PLUTO_TEST_ONCE_AFTER_PID_PATH_CHECK="$BIN/remove-pid-after-path-check"
expect_gate_rejection 'pre-ready PID receipt disappearance during inspection'
[[ "$(grep -c '^is-active --quiet pluto-session-once.service$' "$EVENTS")" == 4 ]] ||
  fail 'pre-ready PID receipt gap did not remain pending for the fixed gate bound'
unset PLUTO_TEST_ONCE_AFTER_PID_PATH_CHECK PLUTO_TEST_GATE_ATTEMPTS
stop_foreground_fixture

# A failed stop may leave the old cgroup live. Its receipt must remain intact
# and the replacement service must not be staged or started.
: > "$EVENTS"
start_foreground_fixture frozen
: > "$ACTIVE"
export PLUTO_TEST_FAIL_STOP=1
set +e
run_once start > "$TMP/active-session-retirement-failure.out" 2>&1
ACTIVE_SESSION_RETIREMENT_FAILURE=$?
set -e
unset PLUTO_TEST_FAIL_STOP
[[ "$ACTIVE_SESSION_RETIREMENT_FAILURE" -ne 0 ]] ||
  fail "active transient service retirement returned success"
grep -q 'cannot retire active or indeterminate transient service' \
  "$TMP/active-session-retirement-failure.out" ||
  fail "active transient service retirement failure was not diagnosed"
[[ "$(cat "$RUN/embedder.pid")" = "$FIXTURE_PID" ]] ||
  fail "active transient service lost its foreground PID receipt"
if grep -q '^start pluto-session-once.service$' "$EVENTS"; then
  fail "active transient service retirement failure started a replacement"
fi
[[ ! -e "$UNIT" ]] ||
  fail "active transient service retirement failure published a replacement unit"
rm -f "$ACTIVE"
stop_foreground_fixture

# Neither an intermediate systemd state nor a failed state query proves the
# old cgroup is gone. Both conditions preserve the receipt and abort before a
# replacement is staged.
: > "$EVENTS"
start_foreground_fixture frozen
export PLUTO_TEST_ACTIVE_STATE=deactivating
set +e
run_once start > "$TMP/deactivating-session-retirement.out" 2>&1
DEACTIVATING_SESSION_RETIREMENT=$?
set -e
unset PLUTO_TEST_ACTIVE_STATE
[[ "$DEACTIVATING_SESSION_RETIREMENT" -ne 0 ]] ||
  fail "deactivating transient service retirement returned success"
[[ "$(cat "$RUN/embedder.pid")" = "$FIXTURE_PID" ]] ||
  fail "deactivating transient service lost its foreground PID receipt"
if grep -q '^start pluto-session-once.service$' "$EVENTS"; then
  fail "deactivating transient service retirement started a replacement"
fi
stop_foreground_fixture

: > "$EVENTS"
start_foreground_fixture frozen
export PLUTO_TEST_FAIL_SHOW=1
set +e
run_once start > "$TMP/session-state-query-failure.out" 2>&1
SESSION_STATE_QUERY_FAILURE=$?
set -e
unset PLUTO_TEST_FAIL_SHOW
[[ "$SESSION_STATE_QUERY_FAILURE" -ne 0 ]] ||
  fail "failed transient service state query returned success"
grep -q 'cannot verify earlier transient service retirement' \
  "$TMP/session-state-query-failure.out" ||
  fail "failed transient service state query was not diagnosed"
[[ "$(cat "$RUN/embedder.pid")" = "$FIXTURE_PID" ]] ||
  fail "failed transient service state query removed the foreground PID receipt"
if grep -q '^start pluto-session-once.service$' "$EVENTS"; then
  fail "failed transient service state query started a replacement"
fi
stop_foreground_fixture

: > "$EVENTS"
set +e
PLUTO_ROOT="$ROOT" \
PLUTO_RUN_DIR="$RUN" \
PLUTO_SYSTEMCTL="$BIN/systemctl" \
PLUTO_SYSTEMD_RUNTIME_DIR="$UNITS" \
PLUTO_TEST_EVENTS="$EVENTS" \
PLUTO_TEST_ACTIVE="$ACTIVE" \
PLUTO_TEST_FAIL_START=1 \
PLUTO_TESTING=1 \
PLUTO_TEST_PROFILE_ID=rm1 \
  sh "$SCRIPT" start >/dev/null 2>&1
FAILED_START=$?
set -e
[ "$FAILED_START" -ne 0 ] || fail "failed transient start returned success"
[ ! -e "$UNIT" ] || fail "failed transient start retained its unit"
grep -q '^start xochitl.service$' "$EVENTS" ||
  fail "failed transient start did not restore stock"

# Receipt retirement is fail-closed before the transient service can contend
# with stock for the panel. A directory at the receipt path cannot be removed
# as a file and therefore must abort without starting either display service.
: > "$EVENTS"
mkdir "$RUN/embedder.pid"
set +e
run_once start > "$TMP/stale-pid-retirement-failure.out" 2>&1
STALE_PID_RETIREMENT_FAILURE=$?
set -e
[[ "$STALE_PID_RETIREMENT_FAILURE" -ne 0 ]] ||
  fail "unremovable stale foreground PID receipt returned success"
grep -q 'cannot retire stale foreground PID receipt' \
  "$TMP/stale-pid-retirement-failure.out" ||
  fail "stale foreground PID retirement failure was not diagnosed"
if grep -q '^start pluto-session-once.service$' "$EVENTS"; then
  fail "stale foreground PID retirement failure started Pluto"
fi
if grep -q '^start xochitl.service$' "$EVENTS"; then
  fail "stale foreground PID retirement failure mutated stock ownership"
fi
[[ ! -e "$UNIT" ]] ||
  fail "stale foreground PID retirement failure published a transient unit"
rm -rf "$RUN/embedder.pid"

# A Type=simple service with a frozen renderer receipt must be stopped and
# removed instead of being reported as a successful transient activation.
: > "$EVENTS"
start_foreground_fixture frozen
export PLUTO_TEST_GATE_ATTEMPTS=5
set +e
run_once start >/dev/null 2>&1
FROZEN_START=$?
set -e
unset PLUTO_TEST_GATE_ATTEMPTS
[ "$FROZEN_START" -ne 0 ] || fail "frozen renderer health returned success"
[ ! -e "$UNIT" ] || fail "frozen renderer health retained its transient unit"
[ ! -e "$ACTIVE" ] || fail "frozen renderer health left the service active"
grep -q '^stop pluto-session-once.service$' "$EVENTS" ||
  fail "frozen renderer health did not stop the transient service"
grep -q '^start xochitl.service$' "$EVENTS" ||
  fail "frozen renderer health did not restore stock"
stop_foreground_fixture

# One observed increase is still insufficient: activation binds to the same
# process/path tuple until a second independent progress edge is visible.
: > "$EVENTS"
start_foreground_fixture single-advance
export PLUTO_TEST_GATE_ATTEMPTS=10
set +e
run_once start >/dev/null 2>&1
SINGLE_ADVANCE_START=$?
set -e
unset PLUTO_TEST_GATE_ATTEMPTS
[ "$SINGLE_ADVANCE_START" -ne 0 ] ||
  fail "one renderer health advance satisfied the two-advance gate"
[ ! -e "$UNIT" ] || fail "one renderer health advance retained its transient unit"
[ ! -e "$ACTIVE" ] || fail "one renderer health advance left the service active"
grep -q '^start xochitl.service$' "$EVENTS" ||
  fail "one renderer health advance did not restore stock"
stop_foreground_fixture

# A published but malformed health record is a fail-closed error, not startup
# latency that may be ignored until Type=simple happens to report active.
: > "$EVENTS"
start_foreground_fixture malformed
set +e
run_once start >/dev/null 2>&1
MALFORMED_START=$?
set -e
[ "$MALFORMED_START" -ne 0 ] || fail "malformed renderer health returned success"
[ ! -e "$UNIT" ] || fail "malformed renderer health retained its transient unit"
[ ! -e "$ACTIVE" ] || fail "malformed renderer health left the service active"
grep -q '^stop pluto-session-once.service$' "$EVENTS" ||
  fail "malformed renderer health did not stop the transient service"
grep -q '^start xochitl.service$' "$EVENTS" ||
  fail "malformed renderer health did not restore stock"
stop_foreground_fixture

# The health gate binds to the exact active immutable executable and its
# transient service cgroup, not spoofable argv[0] text alone.
: > "$EVENTS"
start_foreground_fixture success
rm -f "$PROC/$FIXTURE_PID/exe"
ln -s /bin/sh "$PROC/$FIXTURE_PID/exe"
expect_gate_rejection 'wrong foreground executable'
stop_foreground_fixture

: > "$EVENTS"
start_foreground_fixture success
printf '0::/system.slice/not-pluto.service\n' > "$PROC/$FIXTURE_PID/cgroup"
expect_gate_rejection 'foreign foreground cgroup'
stop_foreground_fixture

# App containment is one canonical app-id directory. Shell-glob traversal or
# nested bundle paths must not be treated as children of the active release.
: > "$EVENTS"
start_foreground_fixture success
write_fixture_cmdline "$ROOT/apps/../../launcher/bundle" \
  "$ROOT/bin/pluto-embedder"
expect_gate_rejection 'traversing foreground bundle'
stop_foreground_fixture

# Every embedder argument is the supervisor's release-AOT contract. Options
# such as a bounded run duration cannot be smuggled into an otherwise healthy
# current-release process.
: > "$EVENTS"
start_foreground_fixture success
write_fixture_cmdline "$ROOT/launcher/bundle" "$ROOT/bin/pluto-embedder" \
  --run-duration-ms=10
expect_gate_rejection 'unknown foreground option'
stop_foreground_fixture

# Only the exact transient manual UUID pair and launch serial may name the
# ready/health pair; a loose token cannot bind activation evidence.
: > "$EVENTS"
start_foreground_fixture frozen
rename_fixture_receipts 'manual-not-a-uuid.also-not-a-uuid-1'
expect_gate_rejection 'malformed transient receipt nonce'
stop_foreground_fixture

: > "$EVENTS"
start_foreground_fixture frozen
rename_fixture_receipts \
  'manual-11111111-1111-4111-8111-111111111111.22222222-2222-4222-8222-222222222222-0001'
expect_gate_rejection 'noncanonical transient launch serial'
stop_foreground_fixture

: > "$EVENTS"
start_foreground_fixture frozen
rename_fixture_receipts \
  'manual-11111111-1111-4111-8111-111111111111.22222222-2222-4222-8222-222222222222-9999999999999999999999999999999999999999'
expect_gate_rejection 'overflowing transient launch serial'
stop_foreground_fixture

# Receipt symlinks and PID reuse/start-time changes are rejected before two
# progress observations can be credited to a renderer generation.
: > "$EVENTS"
start_foreground_fixture frozen
printf 'ready\n' > "$TMP/linked-ready"
chmod 0600 "$TMP/linked-ready"
rm -f "$FIXTURE_READY"
ln -s "$TMP/linked-ready" "$FIXTURE_READY"
expect_gate_rejection 'symlinked ready receipt'
stop_foreground_fixture

: > "$EVENTS"
start_foreground_fixture identity-change
expect_gate_rejection 'changed foreground start time'
stop_foreground_fixture

# A supervisor foreground replacement that lands during inspection cannot
# credit the old still-live warm process. The final fence re-reads the PID
# receipt after all process, argv, and health evidence has been inspected.
cat > "$BIN/swap-foreground-pid" <<'SWAP_PID'
#!/bin/sh
printf '999999\n' > "$PLUTO_TEST_RUN_DIR/embedder.pid"
SWAP_PID
chmod 0755 "$BIN/swap-foreground-pid"
: > "$EVENTS"
start_foreground_fixture frozen
export PLUTO_TEST_RUN_DIR="$RUN"
export PLUTO_TEST_ONCE_BEFORE_FINAL_FENCE="$BIN/swap-foreground-pid"
expect_gate_rejection 'foreground PID receipt replacement during inspection'
unset PLUTO_TEST_ONCE_BEFORE_FINAL_FENCE PLUTO_TEST_RUN_DIR
stop_foreground_fixture

# Once one complete foreground identity has been observed, the same genuine
# PID-receipt disappearance is fail-closed. The first path-check hook is a
# no-op so inspection can latch; the second removes the receipt before read.
cat > "$BIN/remove-pid-after-first-observation" <<'REMOVE_LATCHED_PID'
#!/bin/sh
count=$(cat "$PLUTO_TEST_FENCE_COUNT" 2>/dev/null || printf '0\n')
count=$((count + 1))
printf '%s\n' "$count" > "$PLUTO_TEST_FENCE_COUNT"
[ "$count" -lt 2 ] || rm -f "$1"
REMOVE_LATCHED_PID
chmod 0755 "$BIN/remove-pid-after-first-observation"
: > "$EVENTS"
start_foreground_fixture success
export PLUTO_TEST_FENCE_COUNT="$TMP/latched-fence-count"
export PLUTO_TEST_ONCE_AFTER_PID_PATH_CHECK="$BIN/remove-pid-after-first-observation"
rm -f "$PLUTO_TEST_FENCE_COUNT"
expect_gate_rejection 'vanished latched foreground PID receipt'
[[ "$(cat "$PLUTO_TEST_FENCE_COUNT")" -ge 2 ]] ||
  fail 'latched PID receipt disappearance did not cross two inspections'
unset PLUTO_TEST_ONCE_AFTER_PID_PATH_CHECK PLUTO_TEST_FENCE_COUNT
stop_foreground_fixture

# A whole-poll PID-receipt gap after the identity latch is also fatal, even if
# the same receipt and live process reappear before the gate handles the
# pending result. The post-inspection seam makes both sides of this race
# deterministic: remove after the first complete inspection, then restore the
# identical receipt after the second inspection has observed it missing.
cat > "$BIN/gap-and-restore-latched-pid" <<'GAP_LATCHED_PID'
#!/bin/sh
inspect_rc=$1
pid_file=$2
count=$(cat "$PLUTO_TEST_GAP_COUNT" 2>/dev/null || printf '0\n')
count=$((count + 1))
printf '%s\n' "$count" > "$PLUTO_TEST_GAP_COUNT"
case "$count:$inspect_rc" in
  1:0) rm -f "$pid_file" ;;
  2:1) printf '%s\n' "$PLUTO_TEST_REAPPEAR_PID" > "$pid_file" ;;
  *) exit 1 ;;
esac
GAP_LATCHED_PID
chmod 0755 "$BIN/gap-and-restore-latched-pid"
: > "$EVENTS"
start_foreground_fixture success
export PLUTO_TEST_GAP_COUNT="$TMP/latched-whole-poll-gap-count"
export PLUTO_TEST_REAPPEAR_PID="$FIXTURE_PID"
export PLUTO_TEST_ONCE_AFTER_FOREGROUND_INSPECT="$BIN/gap-and-restore-latched-pid"
rm -f "$PLUTO_TEST_GAP_COUNT"
expect_gate_rejection 'reappearing latched foreground PID receipt'
[[ "$(cat "$PLUTO_TEST_GAP_COUNT")" == 2 ]] ||
  fail 'latched whole-poll PID gap was not rejected on its first missing inspection'
[[ "$(cat "$RUN/embedder.pid")" == "$FIXTURE_PID" ]] ||
  fail 'latched whole-poll PID test did not restore the identical receipt'
unset PLUTO_TEST_ONCE_AFTER_FOREGROUND_INSPECT PLUTO_TEST_REAPPEAR_PID
unset PLUTO_TEST_GAP_COUNT
stop_foreground_fixture

cat > "$BIN/swap-foreground-start-ticks" <<'SWAP_TICKS'
#!/bin/sh
printf '%s (pluto-embedder) S 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 999999 0\n' \
  "$1" > "$PLUTO_TEST_PROC_ROOT/$1/stat"
SWAP_TICKS
chmod 0755 "$BIN/swap-foreground-start-ticks"
: > "$EVENTS"
start_foreground_fixture frozen
export PLUTO_TEST_PROC_ROOT="$PROC"
export PLUTO_TEST_ONCE_BEFORE_FINAL_FENCE="$BIN/swap-foreground-start-ticks"
expect_gate_rejection 'foreground PID reuse during final inspection fence'
unset PLUTO_TEST_ONCE_BEFORE_FINAL_FENCE PLUTO_TEST_PROC_ROOT
stop_foreground_fixture

: > "$EVENTS"
start_foreground_fixture service-death
expect_gate_rejection 'dead transient service'
stop_foreground_fixture

# A failed fail-closed stock handoff is surfaced as the primary recovery
# failure; it is never hidden behind the original health-gate message.
: > "$EVENTS"
start_foreground_fixture frozen
export PLUTO_TEST_GATE_ATTEMPTS=3
export PLUTO_TEST_FAIL_STOCK_START=1
set +e
run_once start > "$TMP/stock-restore-failure.out" 2>&1
STOCK_RESTORE_FAILURE=$?
set -e
unset PLUTO_TEST_FAIL_STOCK_START PLUTO_TEST_GATE_ATTEMPTS
[[ "$STOCK_RESTORE_FAILURE" -ne 0 ]] ||
  fail 'failed stock restore returned success after health rejection'
grep -q 'stock xochitl did not restart' "$TMP/stock-restore-failure.out" ||
  fail 'failed stock restore was hidden behind the health-gate error'
[[ ! -e "$UNIT" ]] || fail 'failed stock restore retained its transient unit'
stop_foreground_fixture

# Bind the transient activation check to the generated RM2 accepted waveform
# source, not its broader discovery list. The inactive stock-panel waveform is
# discoverable for diagnostics but must never authenticate a native session.
export PLUTO_TEST_ONCE_PROFILE_FILE="$(cd "$HERE/../generated" && pwd)/device-profiles.sh"
export PLUTO_TEST_PROFILE_ID=rm2
export PLUTO_TEST_FIXTURE_TOUCH_DEVICE=/dev/input/by-path/platform-30a40000.i2c-event
export PLUTO_TEST_FIXTURE_PEN_DEVICE=/dev/input/by-path/platform-30a20000.i2c-event-mouse
export PLUTO_TEST_FIXTURE_PRESENTER_OPTIONS='wbf=/var/lib/uboot/320_R405_AFA011_ED103TC2C5_VB3300-KCD_TC.wbf'
: > "$EVENTS"
start_foreground_fixture success
if ! run_once start > "$TMP/rm2-accepted-waveform.out" 2>&1; then
  cat "$TMP/rm2-accepted-waveform.out" >&2
  fail 'generated RM2 accepted waveform failed the health gate'
fi
run_once stop >/dev/null || fail 'generated RM2 accepted waveform session did not stop'
stop_foreground_fixture

export PLUTO_TEST_FIXTURE_PRESENTER_OPTIONS='wbf=/usr/share/remarkable/320_R467_AF4731_ED103TC2C6_VB3300-KCD_TC.wbf'
: > "$EVENTS"
start_foreground_fixture frozen
expect_gate_rejection 'generated RM2 inactive discovery waveform'
stop_foreground_fixture
unset PLUTO_TEST_ONCE_PROFILE_FILE PLUTO_TEST_PROFILE_ID
unset PLUTO_TEST_FIXTURE_TOUCH_DEVICE PLUTO_TEST_FIXTURE_PEN_DEVICE
unset PLUTO_TEST_FIXTURE_PRESENTER_OPTIONS

# RM2 alone requires the device-specific receipt recovery. The single
# profile-aware ExecStopPost helper cannot start stock after recovery fails.
: > "$EVENTS"
export PLUTO_TEST_PROFILE_ID=rm2
start_foreground_fixture success
run_once start >/dev/null || fail "one-shot session did not restart"
export PLUTO_TEST_FAIL_CPUFREQ=1
set +e
run_once stop >/dev/null 2>&1
FAILED_RESTORE=$?
set -e
unset PLUTO_TEST_FAIL_CPUFREQ
[ "$FAILED_RESTORE" -ne 0 ] || fail "cpufreq recovery failure returned success"
grep -q '^cpufreq-restore$' "$EVENTS" || fail "failed recovery was not attempted"
if grep -q '^start xochitl.service$' "$EVENTS"; then
  fail "direct fallback started stock after cpufreq recovery failed"
fi

unset PLUTO_TEST_FAIL_CPUFREQ
: > "$EVENTS"
run_once stop >/dev/null || fail "RM2 one-shot stop did not retry recovery"
grep -q '^cpufreq-restore$' "$EVENTS" ||
  fail "RM2 explicit stop did not run CPU-frequency recovery"
grep -q '^start xochitl.service$' "$EVENTS" ||
  fail "RM2 explicit stop did not restore stock"
unset PLUTO_TEST_PROFILE_ID
stop_foreground_fixture

# Move follows the same current-boot flow but does not depend on the RM2 helper.
rm -f "$ROOT/bin/pluto-rm2-cpufreq-restore.sh"
export PLUTO_TEST_PROFILE_ID=move
: > "$EVENTS"
start_foreground_fixture success
run_once start >/dev/null || fail "Move one-shot session required the RM2 helper"
run_once stop >/dev/null || fail "Move one-shot stop required the RM2 helper"
if grep -q '^cpufreq-restore$' "$EVENTS"; then
  fail "Move one-shot stop ran RM2 CPU-frequency recovery"
fi
unset PLUTO_TEST_PROFILE_ID
stop_foreground_fixture

if PLUTO_ROOT='../unsafe' PLUTO_SYSTEMCTL="$BIN/systemctl" \
  PLUTO_SYSTEMD_RUNTIME_DIR="$UNITS" PLUTO_TEST_EVENTS="$EVENTS" \
  PLUTO_TEST_ACTIVE="$ACTIVE" PLUTO_TESTING=1 PLUTO_TEST_PROFILE_ID=rm1 \
  sh "$SCRIPT" start >/dev/null 2>&1; then
  fail "unsafe Pluto root was accepted"
fi

echo "PASS: current-boot Pluto session preserves stock next boot"
