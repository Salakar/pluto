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

cat > "$TMP/bin/uname" <<'UNAME'
#!/bin/sh
[ "$1" = -r ] || exit 64
printf '%s\n' "$PLUTO_TEST_KERNEL_RELEASE_OUTPUT"
UNAME
chmod +x "$TMP/bin/uname"

run_identity_refused() {
  build="$1"
  kernel="$2"
  expected="$3"
  printf '%s\n' "$build" > "$TMP/version"
  : > "$TMP/session.log"
  rm -f "$TMP/systemctl.log"
  set +e
  PATH="$TMP/bin:$PATH" \
  PLUTO_ROOT="$TMP/root" \
  PLUTO_PROFILE_FILE="$PROFILE_FILE" \
  PLUTO_TESTING=1 \
  PLUTO_TEST_PROFILE_ID=move \
  PLUTO_MAX_WARM_APPS=1 \
  PLUTO_TEST_FIRMWARE_BUILD_FILE="$TMP/version" \
  PLUTO_TEST_UNAME="$TMP/bin/uname" \
  PLUTO_TEST_KERNEL_RELEASE_OUTPUT="$kernel" \
  PLUTO_TEST_SYSTEMCTL_LOG="$TMP/systemctl.log" \
    sh "$SUPERVISOR" start > "$TMP/session.log" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 78 ] || fail "Move identity refusal returned $rc, expected 78"
  grep -q "$expected" "$TMP/session.log" ||
    fail "Move identity refusal did not name $expected"
  [ ! -s "$TMP/systemctl.log" ] ||
    fail "Move identity refusal touched xochitl.service"
}

run_identity_refused \
  20000101000000 6.12.49+git-imx93-chiappa-gf4c2ab7040e8 'firmware build'
run_identity_refused \
  20260629074044 6.12.49+git-imx93-chiappa-gf4c2ab7040e9 'kernel release'

: > "$TMP/session.log"
rm -f "$TMP/systemctl.log"
set +e
PATH="$TMP/bin:$PATH" \
PLUTO_ROOT="$TMP/root" \
PLUTO_PROFILE_FILE="$PROFILE_FILE" \
PLUTO_TESTING=1 \
PLUTO_TEST_PROFILE_ID=move \
PLUTO_MAX_WARM_APPS=9 \
PLUTO_TEST_SYSTEMCTL_LOG="$TMP/systemctl.log" \
  sh "$SUPERVISOR" start > "$TMP/session.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "invalid resident override returned $rc, expected 78"
grep -q 'resident app limit is invalid' "$TMP/session.log" ||
  fail "invalid resident override was not rejected"
[ ! -s "$TMP/systemctl.log" ] ||
  fail "invalid resident override touched xochitl.service"

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

: > "$TMP/session.log"
rm -f "$TMP/systemctl.log"
set +e
PATH="$TMP/bin:$PATH" \
PLUTO_ROOT="$TMP/root" \
PLUTO_PROFILE_FILE="$PROFILE_FILE" \
PLUTO_MAX_WARM_APPS=1 \
PLUTO_TEST_SYSTEMCTL_LOG="$TMP/systemctl.log" \
  sh "$SUPERVISOR" start > "$TMP/session.log" 2>&1
rc=$?
set -e
[ "$rc" -eq 78 ] || fail "production resident override returned $rc, expected 78"
grep -q 'PLUTO_MAX_WARM_APPS is test-only' "$TMP/session.log" ||
  fail "production resident override was not rejected explicitly"
[ ! -s "$TMP/systemctl.log" ] ||
  fail "production resident override touched xochitl.service"

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
