#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SUPERVISOR="$HERE/../pluto-session.sh"
PROFILE_FILE="$HERE/../generated/device-profiles.sh"
TMP=${TMPDIR:-/tmp}/pluto-session-profile-test.$$

cleanup() { rm -rf "$TMP"; }
trap cleanup 0

fail() {
  printf 'session profile test: %s\n' "$*" >&2
  [ ! -f "$TMP/session.log" ] || cat "$TMP/session.log" >&2
  exit 1
}

mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'SYSTEMCTL'
#!/bin/sh
printf '%s\n' "$*" >> "$PLUTO_TEST_SYSTEMCTL_LOG"
exit 0
SYSTEMCTL
chmod +x "$TMP/bin/systemctl"

run_refused() {
  profile_id="$1"
  : > "$TMP/session.log"
  rm -f "$TMP/systemctl.log"
  set +e
  PATH="$TMP/bin:$PATH" \
  PLUTO_ROOT="$TMP/root" \
  PLUTO_PROFILE_FILE="$PROFILE_FILE" \
  PLUTO_TESTING=1 \
  PLUTO_TEST_PROFILE_ID="$profile_id" \
  PLUTO_TEST_SYSTEMCTL_LOG="$TMP/systemctl.log" \
    sh "$SUPERVISOR" start > "$TMP/session.log" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 78 ] || fail "$profile_id refusal returned $rc, expected 78"
  [ ! -s "$TMP/systemctl.log" ] ||
    fail "$profile_id refusal touched xochitl.service"
}

run_refused rm1
grep -q "native session for 'rm1' has not passed" "$TMP/session.log" ||
  fail "rm1 acceptance-gate refusal was not explicit"

run_refused rm2
grep -q "native session for 'rm2' has not passed" "$TMP/session.log" ||
  fail "rm2 acceptance-gate refusal was not explicit"

: > "$TMP/session.log"
rm -f "$TMP/systemctl.log"
set +e
PATH="$TMP/bin:$PATH" \
PLUTO_ROOT="$TMP/root" \
PLUTO_PROFILE_FILE="$PROFILE_FILE" \
PLUTO_TESTING=1 \
PLUTO_TEST_PROFILE_ID=move \
PLUTO_WAVEFORM=/usr/share/remarkable/unaccepted-waveform.wbf \
PLUTO_TEST_SYSTEMCTL_LOG="$TMP/systemctl.log" \
  sh "$SUPERVISOR" start > "$TMP/session.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "unaccepted waveform returned $rc, expected 78"
grep -q 'requested waveform is not an accepted source' "$TMP/session.log" ||
  fail "unaccepted waveform refusal was not explicit"
[ ! -s "$TMP/systemctl.log" ] ||
  fail "unaccepted waveform touched xochitl.service"

set +e
PLUTO_ROOT="$TMP/root" \
PLUTO_PROFILE_FILE="$PROFILE_FILE" \
PLUTO_TEST_PROFILE_ID=move \
  sh "$SUPERVISOR" start > "$TMP/session.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "unguarded test override returned $rc, expected 78"
grep -q 'test identity override outside test mode' "$TMP/session.log" ||
  fail "unguarded test override was not rejected"

printf 'session profile test: PASS\n'
