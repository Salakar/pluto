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
cat > "$ROOT/bin/pluto-session.sh" <<'SUPERVISOR'
#!/bin/sh
exit 0
SUPERVISOR
chmod 0755 "$ROOT/bin/pluto-session.sh"

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
  PLUTO_ROOT="$ROOT" \
  PLUTO_RUN_DIR="$RUN" \
  PLUTO_SYSTEMCTL="$BIN/systemctl" \
  PLUTO_SYSTEMD_RUNTIME_DIR="$UNITS" \
  PLUTO_TEST_EVENTS="$EVENTS" \
  PLUTO_TEST_ACTIVE="$ACTIVE" \
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
grep -q '^ExecStopPost=/bin/systemctl --no-block start xochitl.service$' "$UNIT" ||
  fail "one-shot service cannot restore stock after exit"
grep -q '^Restart=no$' "$UNIT" ||
  fail "one-shot service can enter a restart loop"
[[ "$UNIT" == "$TMP/run/"* ]] || fail "one-shot service persisted outside /run"
run_once status | grep -q 'active' || fail "active status was not reported"

: > "$EVENTS"
run_once stop >/dev/null || fail "one-shot session did not stop"
[ ! -e "$UNIT" ] || fail "stopped one-shot service remained published"
grep -q '^stop pluto-session-once.service$' "$EVENTS" ||
  fail "stop did not end the transient supervisor"
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
  sh "$SCRIPT" start >/dev/null 2>&1
FAILED_START=$?
set -e
[ "$FAILED_START" -ne 0 ] || fail "failed transient start returned success"
[ ! -e "$UNIT" ] || fail "failed transient start retained its unit"
grep -q '^start xochitl.service$' "$EVENTS" ||
  fail "failed transient start did not restore stock"

if PLUTO_ROOT='../unsafe' PLUTO_SYSTEMCTL="$BIN/systemctl" \
  PLUTO_SYSTEMD_RUNTIME_DIR="$UNITS" PLUTO_TEST_EVENTS="$EVENTS" \
  PLUTO_TEST_ACTIVE="$ACTIVE" sh "$SCRIPT" start >/dev/null 2>&1; then
  fail "unsafe Pluto root was accepted"
fi

echo "PASS: current-boot Pluto session preserves stock next boot"
