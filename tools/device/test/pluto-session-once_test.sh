#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../pluto-session-once.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pluto-once-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
ROOT="$TMP/root"
RUN="$TMP/run/pluto"
UNITS="$TMP/run/systemd/system"
BIN="$TMP/bin"
EVENTS="$TMP/events"
ACTIVE="$TMP/active"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$ROOT/bin" "$BIN"
mkdir -p "$ROOT/share"
cat > "$ROOT/bin/pluto-session.sh" <<'SUPERVISOR'
#!/bin/sh
exit 0
SUPERVISOR
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
  export PLUTO_PROFILE_DISPLAY_DRIVER PLUTO_PROFILE_NATIVE_SESSION_ENABLED
}
pluto_profile_probe() { return 1; }
PROFILES
cat > "$ROOT/bin/pluto-rm2-cpufreq-restore.sh" <<'RESTORE'
#!/bin/sh
printf 'cpufreq-restore\n' >> "$PLUTO_TEST_EVENTS"
[ "${PLUTO_TEST_FAIL_CPUFREQ:-0}" != 1 ]
RESTORE
chmod 0755 "$ROOT/bin/pluto-session.sh" "$ROOT/bin/pluto-session-once.sh" \
  "$ROOT/bin/pluto-rm2-cpufreq-restore.sh"

cat > "$BIN/systemctl" <<'SYSTEMCTL'
#!/bin/sh
printf '%s\n' "$*" >> "$PLUTO_TEST_EVENTS"
case "$*" in
  'start pluto-session-once.service')
    [ "${PLUTO_TEST_FAIL_START:-0}" != 1 ] || exit 1
    : > "$PLUTO_TEST_ACTIVE"
    ;;
  'stop pluto-session-once.service') rm -f "$PLUTO_TEST_ACTIVE" ;;
  'is-active --quiet pluto-session-once.service')
    [ -f "$PLUTO_TEST_ACTIVE" ] || exit 3
    ;;
esac
exit 0
SYSTEMCTL
chmod 0755 "$BIN/systemctl"

run_once() {
  local profile="${PLUTO_TEST_PROFILE_ID:-rm1}"
  PLUTO_ROOT="$ROOT" \
  PLUTO_RUN_DIR="$RUN" \
  PLUTO_SYSTEMCTL="$BIN/systemctl" \
  PLUTO_SYSTEMD_RUNTIME_DIR="$UNITS" \
  PLUTO_TEST_EVENTS="$EVENTS" \
  PLUTO_TEST_ACTIVE="$ACTIVE" \
  PLUTO_TESTING=1 \
  PLUTO_TEST_PROFILE_ID="$profile" \
    sh "$SCRIPT" "$@"
}

: > "$EVENTS"
run_once start >/dev/null || fail "one-shot session did not start"
UNIT="$UNITS/pluto-session-once.service"
[ -f "$UNIT" ] || fail "runtime-only service was not published"
[ "$(stat -f '%Lp' "$UNIT" 2>/dev/null || stat -c '%a' "$UNIT")" = 644 ] ||
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

# RM2 alone requires the device-specific receipt recovery. The single
# profile-aware ExecStopPost helper cannot start stock after recovery fails.
: > "$EVENTS"
export PLUTO_TEST_PROFILE_ID=rm2
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

# Move follows the same current-boot flow but does not depend on the RM2 helper.
rm -f "$ROOT/bin/pluto-rm2-cpufreq-restore.sh"
export PLUTO_TEST_PROFILE_ID=move
: > "$EVENTS"
run_once start >/dev/null || fail "Move one-shot session required the RM2 helper"
run_once stop >/dev/null || fail "Move one-shot stop required the RM2 helper"
if grep -q '^cpufreq-restore$' "$EVENTS"; then
  fail "Move one-shot stop ran RM2 CPU-frequency recovery"
fi
unset PLUTO_TEST_PROFILE_ID

if PLUTO_ROOT='../unsafe' PLUTO_SYSTEMCTL="$BIN/systemctl" \
  PLUTO_SYSTEMD_RUNTIME_DIR="$UNITS" PLUTO_TEST_EVENTS="$EVENTS" \
  PLUTO_TEST_ACTIVE="$ACTIVE" PLUTO_TESTING=1 PLUTO_TEST_PROFILE_ID=rm1 \
  sh "$SCRIPT" start >/dev/null 2>&1; then
  fail "unsafe Pluto root was accepted"
fi

echo "PASS: current-boot Pluto session preserves stock next boot"
