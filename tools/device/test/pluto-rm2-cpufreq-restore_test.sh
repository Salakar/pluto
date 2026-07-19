#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../pluto-rm2-cpufreq-restore.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pluto-rm2-cpufreq-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
umask 077
BIN="$TMP/bin"
mkdir -p "$BIN"

fail() {
  echo "rm2 cpufreq restore test: $*" >&2
  exit 1
}

# macOS has no flock utility. The helper's fd/exit contract is tested here;
# native presenter tests exercise the real flock(2) lease on Linux.
cat > "$BIN/flock" <<'FLOCK'
#!/bin/sh
[ "$1" = -n ] && [ "$2" = 9 ] || exit 64
[ "${PLUTO_TEST_FLOCK_BUSY:-0}" != 1 ]
FLOCK
chmod 0755 "$BIN/flock"

logical_receipt=run/pluto/rm2-cpufreq-burst
logical_lock=run/pluto/rm2-cpufreq-burst.lock
logical_policy=sys/devices/system/cpu/cpufreq/policy0

new_fixture() {
  name=$1
  FIXTURE="$TMP/$name"
  POLICY="$FIXTURE/$logical_policy"
  RECEIPT="$FIXTURE/$logical_receipt"
  LOCK="$FIXTURE/$logical_lock"
  rm -rf "$FIXTURE"
  mkdir -p "$POLICY" "$(dirname "$RECEIPT")" "$FIXTURE/proc"
  printf '0 1\n' > "$POLICY/related_cpus"
  printf '1200000\n' > "$POLICY/scaling_min_freq"
  printf '1200000\n' > "$POLICY/scaling_max_freq"
  printf 'ondemand\n' > "$POLICY/scaling_governor"
}

write_receipt() {
  owner_pid=${1:-4242}
  owner_start=${2:-123456}
  original_min=${3:-792000}
  original_max=${4:-1200000}
  governor=${5:-ondemand}
  cat > "$RECEIPT" <<EOF
policy=/sys/devices/system/cpu/cpufreq/policy0
owner_pid=$owner_pid
owner_start_ticks=$owner_start
original_min_khz=$original_min
original_max_khz=$original_max
original_governor=$governor
EOF
}

write_proc() {
  pid=$1
  start=$2
  state=${3:-S}
  mkdir -p "$FIXTURE/proc/$pid"
  {
    printf '%s (presenter) worker) %s' "$pid" "$state"
    for _ in $(seq 4 21); do printf ' 0'; done
    printf ' %s 0 0\n' "$start"
  } > "$FIXTURE/proc/$pid/stat"
}

run_helper() {
  PATH="$BIN:$PATH" PLUTO_TESTING=1 PLUTO_TEST_ROOT="$FIXTURE" \
    sh "$SCRIPT" "$@"
}

expect_failure() {
  label=$1
  shift
  set +e
  "$@" > "$TMP/$label.out" 2> "$TMP/$label.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$label unexpectedly succeeded"
  [ -e "$RECEIPT" ] || [ -L "$RECEIPT" ] ||
    fail "$label discarded the diagnostic receipt"
}

# No receipt is an idempotent success and still validates/acquires the exact
# companion lock path.
new_fixture idempotent
run_helper || fail 'missing receipt was not idempotent'
[ -f "$LOCK" ] || fail 'helper did not use the exact lease lock path'
lock_mode=$(stat -c '%a' "$LOCK" 2>/dev/null || stat -f '%Lp' "$LOCK")
[ "$lock_mode" = 600 ] || fail 'helper-created lock is incompatible with native lease mode'

# A dead owner after the raise restores the exact minimum, preserves unrelated
# policy fields, and only then removes the receipt.
new_fixture dead_owner
write_receipt
run_helper || fail 'dead owner was not restored'
[ "$(cat "$POLICY/scaling_min_freq")" = 792000 ] || fail 'minimum was not restored'
[ "$(cat "$POLICY/scaling_max_freq")" = 1200000 ] || fail 'maximum was mutated'
[ "$(cat "$POLICY/scaling_governor")" = ondemand ] || fail 'governor was mutated'
[ ! -e "$RECEIPT" ] || fail 'verified dead-owner receipt remained'
run_helper || fail 'second restore was not idempotent'

# The other legitimate SIGKILL window is receipt publication immediately
# before the raise. Rewriting the original value is safe and must recover.
new_fixture before_raise
printf '792000\n' > "$POLICY/scaling_min_freq"
write_receipt
run_helper || fail 'pre-raise crash window was not restored'
[ "$(cat "$POLICY/scaling_min_freq")" = 792000 ] || fail 'pre-raise minimum drifted'

# A reused PID proves the original owner is dead. A matching PID/start tuple is
# live and must never have its lease state stolen, even if the flock is absent.
new_fixture pid_reused
write_receipt 4242 123456
write_proc 4242 654321
run_helper || fail 'PID reuse did not prove a stale owner'
[ ! -e "$RECEIPT" ] || fail 'PID-reuse receipt remained after restore'

new_fixture live_owner
write_receipt 4242 123456
write_proc 4242 123456
expect_failure live_owner run_helper
[ "$(cat "$POLICY/scaling_min_freq")" = 1200000 ] || fail 'live owner policy was changed'

new_fixture zombie_owner
write_receipt 4242 123456
write_proc 4242 123456 Z
run_helper || fail 'zombie owner was not treated as dead'
[ ! -e "$RECEIPT" ] || fail 'zombie-owner receipt remained after restore'

new_fixture ambiguous_owner
write_receipt 4242 123456
mkdir -p "$FIXTURE/proc/4242"
printf 'malformed\n' > "$FIXTURE/proc/4242/stat"
expect_failure ambiguous_owner run_helper

new_fixture held_lease
write_receipt
export PLUTO_TEST_FLOCK_BUSY=1
expect_failure held_lease run_helper
unset PLUTO_TEST_FLOCK_BUSY

# Strict schema: exact order/path, exactly six newline-terminated records,
# unsigned canonical integers, and a lower-case safe governor token.
new_fixture wrong_policy
write_receipt
sed 's|policy=/sys/devices/system/cpu/cpufreq/policy0|policy=/sys/devices/system/cpu/cpufreq/policy1|' \
  "$RECEIPT" > "$RECEIPT.tmp"
mv "$RECEIPT.tmp" "$RECEIPT"
expect_failure wrong_policy run_helper

new_fixture wrong_order
write_receipt
sed 's/^owner_pid=/pid=/' "$RECEIPT" > "$RECEIPT.tmp"
mv "$RECEIPT.tmp" "$RECEIPT"
expect_failure wrong_order run_helper

new_fixture missing_newline
printf '%s\n' policy=/sys/devices/system/cpu/cpufreq/policy0 owner_pid=4242 \
  owner_start_ticks=123456 original_min_khz=792000 \
  original_max_khz=1200000 > "$RECEIPT"
printf '%s' original_governor=ondemand >> "$RECEIPT"
expect_failure missing_newline run_helper

new_fixture extra_line
write_receipt
printf 'extra=1\n' >> "$RECEIPT"
expect_failure extra_line run_helper

new_fixture trailing_junk
write_receipt
printf 'extra=1' >> "$RECEIPT"
expect_failure trailing_junk run_helper

new_fixture unsafe_governor
write_receipt 4242 123456 792000 1200000 'on demand'
expect_failure unsafe_governor run_helper

new_fixture leading_zero_pid
write_receipt 04242 123456
expect_failure leading_zero_pid run_helper

new_fixture low_minimum
write_receipt 4242 123456 791999
expect_failure low_minimum run_helper

new_fixture wrong_ceiling
write_receipt 4242 123456 792000 1199999
expect_failure wrong_ceiling run_helper

# Exact hardware and current-state validation prevents a valid-looking receipt
# from targeting another policy or overwriting a third party's mutation.
new_fixture wrong_cpu_set
write_receipt
printf '0\n' > "$POLICY/related_cpus"
expect_failure wrong_cpu_set run_helper

new_fixture changed_max
write_receipt
printf '1100000\n' > "$POLICY/scaling_max_freq"
expect_failure changed_max run_helper

new_fixture changed_governor
write_receipt
printf 'performance\n' > "$POLICY/scaling_governor"
expect_failure changed_governor run_helper

new_fixture changed_min
write_receipt
printf '1000000\n' > "$POLICY/scaling_min_freq"
expect_failure changed_min run_helper

new_fixture ambiguous_governor_file
write_receipt
printf 'ondemand\n\n' > "$POLICY/scaling_governor"
expect_failure ambiguous_governor_file run_helper

new_fixture policy_symlink
write_receipt
mv "$POLICY" "$FIXTURE/policy-real"
ln -s "$FIXTURE/policy-real" "$POLICY"
expect_failure policy_symlink run_helper

new_fixture receipt_symlink
write_receipt
mv "$RECEIPT" "$RECEIPT.real"
ln -s "$RECEIPT.real" "$RECEIPT"
expect_failure receipt_symlink run_helper

new_fixture receipt_dangling_symlink
write_receipt
rm -f "$RECEIPT"
ln -s "$RECEIPT.missing" "$RECEIPT"
expect_failure receipt_dangling_symlink run_helper

new_fixture receipt_mode
write_receipt
chmod 0644 "$RECEIPT"
expect_failure receipt_mode run_helper

new_fixture receipt_hardlink
write_receipt
ln "$RECEIPT" "$RECEIPT.sibling"
expect_failure receipt_hardlink run_helper

new_fixture lock_mode
write_receipt
: > "$LOCK"
chmod 0644 "$LOCK"
expect_failure lock_mode run_helper

new_fixture writable_runtime_directory
write_receipt
chmod 0777 "$(dirname "$RECEIPT")"
expect_failure writable_runtime_directory run_helper

# Production may not redirect these exact logical paths through a test root.
set +e
PLUTO_TEST_ROOT="$FIXTURE" sh "$SCRIPT" > /dev/null 2> "$TMP/production-override.err"
override_rc=$?
set -e
[ "$override_rc" -ne 0 ] || fail 'production accepted PLUTO_TEST_ROOT'

echo 'PASS: RM2 stale cpufreq receipt restores only a proven dead exact owner'
