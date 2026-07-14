#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
RECOVERY="$HERE/../pluto-boot-confirm.sh"
TMP=${TMPDIR:-/tmp}/pluto-boot-recovery-test.$$
BIN="$TMP/bin"
ENV_DIR="$TMP/env"
CONFIG="$TMP/boot-recovery.conf"
OWNER="$TMP/boot-owner"
ATTEMPT="$TMP/run/boot-attempt"
LOCK="$TMP/run/boot-recovery.lock"
SET_LOG="$TMP/set.log"
SYNC_LOG="$TMP/sync.log"
SYSTEMCTL_LOG="$TMP/systemctl.log"
REBOOT_LOG="$TMP/reboot.log"
INVOCATION=test-invocation
OWNER_NONCE=owner-nonce
APP_PID=
OTHER_PID=

cleanup() {
  if [ -n "$APP_PID" ]; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  if [ -n "$OTHER_PID" ]; then
    kill "$OTHER_PID" 2>/dev/null || true
    wait "$OTHER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup 0

fail() {
  printf 'boot recovery test: %s\n' "$*" >&2
  exit 1
}

assert_eq() { # expected actual message
  [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

assert_exact_keys() { # file key...
  aek_file=$1
  shift
  aek_lines=$(wc -l < "$aek_file" | tr -d '[:space:]')
  assert_eq "$#" "$aek_lines" "$aek_file has the wrong key count"
  for aek_key in "$@"; do
    [ "$(grep -c "^$aek_key='" "$aek_file")" -eq 1 ] ||
      fail "$aek_file does not contain exactly one $aek_key"
  done
}

[ -x "$RECOVERY" ] || fail "recovery handler is not executable"

mkdir -p "$BIN" "$ENV_DIR" "$TMP/run" "$TMP/lpgpr"

# Darwin has no /proc. Shadow only Linux process-stat reads with a fixture that
# first proves the pid is live, then emits a Linux-shaped field 22 start time.
# Every other cat remains the host /bin/cat.
cat > "$BIN/cat" <<'CAT'
#!/bin/sh
case "${1:-}" in
  /proc/[0-9]*/stat)
    [ "$#" -eq 1 ] || exit 64
    pid=${1#/proc/}
    pid=${pid%/stat}
    kill -0 "$pid" 2>/dev/null || exit 1
    printf '%s (pluto-test) S' "$pid"
    i=1
    while [ "$i" -le 18 ]; do
      printf ' 0'
      i=$((i + 1))
    done
    printf ' %s\n' "$pid"
    ;;
  *) exec /bin/cat "$@" ;;
esac
CAT

cat > "$BIN/fw_printenv" <<'FW_PRINTENV'
#!/bin/sh
[ "$1" = -n ] && [ "$#" -eq 2 ] || exit 64
/bin/cat "$PLUTO_TEST_ENV_DIR/$2"
FW_PRINTENV

cat > "$BIN/fw_setenv" <<'FW_SETENV'
#!/bin/sh
[ "$#" -eq 2 ] || exit 64
case "$1:$2" in
  bootcount:0|bootcount:1|upgrade_available:0|upgrade_available:1) ;;
  *) exit 64 ;;
esac
printf '%s %s\n' "$1" "$2" >> "$PLUTO_TEST_SET_LOG"
printf '%s\n' "$2" > "$PLUTO_TEST_ENV_DIR/$1"
FW_SETENV

cat > "$BIN/sync" <<'SYNC'
#!/bin/sh
printf 'sync\n' >> "$PLUTO_TEST_SYNC_LOG"
if [ -n "${PLUTO_TEST_SYNC_BLOCK:-}" ] &&
   [ -e "$PLUTO_TEST_SYNC_BLOCK" ]; then
  : > "$PLUTO_TEST_SYNC_BLOCK.entered"
  while [ -e "$PLUTO_TEST_SYNC_BLOCK" ]; do sleep 0.05; done
fi
SYNC

cat > "$BIN/systemctl" <<'SYSTEMCTL'
#!/bin/sh
printf '%s\n' "$*" >> "$PLUTO_TEST_SYSTEMCTL_LOG"
if [ "${PLUTO_TEST_SYSTEMCTL_FAIL_REBOOT:-0}" = 1 ] &&
   [ "$*" = '--force --force reboot' ]; then
  exit 1
fi
SYSTEMCTL

cat > "$BIN/reboot" <<'REBOOT'
#!/bin/sh
printf '%s\n' "$*" >> "$PLUTO_TEST_REBOOT_LOG"
REBOOT

cat > "$BIN/reset-lpgpr" <<'RESET_LPGPR'
#!/bin/sh
part=$(/bin/cat "$PLUTO_TEST_COUNTER_DIR/root_part") || exit 1
printf '0\n' > "$PLUTO_TEST_COUNTER_DIR/root${part}_errcnt"
RESET_LPGPR

chmod +x "$BIN/cat" "$BIN/fw_printenv" "$BIN/fw_setenv" "$BIN/sync" \
  "$BIN/systemctl" "$BIN/reboot" "$BIN/reset-lpgpr"

printf 'boot-one\n' > "$TMP/boot-id"
printf 'attempt-one\n' > "$TMP/nonce"

write_uboot_config() {
  cat > "$CONFIG" <<EOF
PLUTO_RECOVERY_PROFILE_ID='rm1'
PLUTO_RECOVERY_CONFIRMATION_STRATEGY='uboot_env'
PLUTO_RECOVERY_FAILURE_STRATEGY='uboot_env_force_reboot'
PLUTO_RECOVERY_BOOT_DEFAULT_ENABLED='1'
PLUTO_RECOVERY_OWNER_NONCE='$OWNER_NONCE'
PLUTO_RECOVERY_MMC_DEVICE='/dev/mmcblk1'
PLUTO_RECOVERY_ROOT_PARTITIONS='2,3'
PLUTO_RECOVERY_BOOT_LIMIT='1'
PLUTO_RECOVERY_HELPER=''
PLUTO_RECOVERY_COUNTER_DIR=''
PLUTO_RECOVERY_STOCK_RESCUE_UNIT=''
PLUTO_RECOVERY_PEER_DEVICE='/dev/mmcblk1p3'
PLUTO_RECOVERY_STOCK_XOCHITL_SHA256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PLUTO_RECOVERY_STOCK_UNIT_SHA256='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
PLUTO_RECOVERY_PEER_XOCHITL_SHA256='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
PLUTO_RECOVERY_PEER_UNIT_SHA256='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
EOF
  chmod 0600 "$CONFIG"
}

write_move_config() {
  cat > "$CONFIG" <<EOF
PLUTO_RECOVERY_PROFILE_ID='move'
PLUTO_RECOVERY_CONFIRMATION_STRATEGY='lpgpr_counter'
PLUTO_RECOVERY_FAILURE_STRATEGY='unverified'
PLUTO_RECOVERY_BOOT_DEFAULT_ENABLED='0'
PLUTO_RECOVERY_OWNER_NONCE='$OWNER_NONCE'
PLUTO_RECOVERY_MMC_DEVICE=''
PLUTO_RECOVERY_ROOT_PARTITIONS=''
PLUTO_RECOVERY_BOOT_LIMIT=''
PLUTO_RECOVERY_HELPER='$BIN/reset-lpgpr'
PLUTO_RECOVERY_COUNTER_DIR='$TMP/lpgpr'
PLUTO_RECOVERY_STOCK_RESCUE_UNIT='pluto-stock-rescue.service'
PLUTO_RECOVERY_PEER_DEVICE='/dev/mmcblk0p3'
PLUTO_RECOVERY_STOCK_XOCHITL_SHA256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PLUTO_RECOVERY_STOCK_UNIT_SHA256='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
PLUTO_RECOVERY_PEER_XOCHITL_SHA256='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
PLUTO_RECOVERY_PEER_UNIT_SHA256='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
EOF
  chmod 0600 "$CONFIG"
}

write_owner() { # profile state
  cat > "$OWNER" <<EOF
PLUTO_OWNER_NONCE='$OWNER_NONCE'
PLUTO_OWNER_PROFILE='$1'
PLUTO_OWNER_STATE='$2'
EOF
  chmod 0600 "$OWNER"
}

seed_uboot() { # upgrade_available bootcount [active fallback]
  printf '%s\n' "${3:-2}" > "$ENV_DIR/active_partition"
  printf '%s\n' "${4:-3}" > "$ENV_DIR/fallback_partition"
  printf '1\n' > "$ENV_DIR/bootlimit"
  printf '%s\n' "$1" > "$ENV_DIR/upgrade_available"
  printf '%s\n' "$2" > "$ENV_DIR/bootcount"
  printf 'console=tty root=/dev/mmcblk1p%s rootwait\n' "${3:-2}" > "$TMP/cmdline"
  : > "$SET_LOG"
  : > "$SYNC_LOG"
  : > "$SYSTEMCTL_LOG"
  : > "$REBOOT_LOG"
}

reset_attempt() {
  rm -f "$ATTEMPT" "$ATTEMPT".* "$TMP/run"/boot-ready.* \
    "$TMP/run"/health.* 2>/dev/null || true
  rm -rf "$LOCK"
  printf 'boot-one\n' > "$TMP/boot-id"
  printf 'attempt-one\n' > "$TMP/nonce"
}

run_recovery() {
  PATH="$BIN:$PATH" \
  INVOCATION_ID="${PLUTO_TEST_INVOCATION:-$INVOCATION}" \
  PLUTO_BOOT_RECOVERY_CONFIG="$CONFIG" \
  PLUTO_SYSTEM_ROOT="$TMP/system-root" \
  PLUTO_BOOT_OWNER_FILE="$OWNER" \
  PLUTO_BOOT_ATTEMPT_FILE="$ATTEMPT" \
  PLUTO_BOOT_LOCK_DIR="$LOCK" \
  PLUTO_BOOT_ID_FILE="$TMP/boot-id" \
  PLUTO_NONCE_FILE="$TMP/nonce" \
  PLUTO_TESTING=1 \
  PLUTO_TEST_FAILURE_AT="${PLUTO_TEST_FAILURE_AT:-}" \
  PLUTO_TEST_POWER_LOSS_AT="${PLUTO_TEST_POWER_LOSS_AT:-}" \
  PLUTO_FW_PRINTENV="$BIN/fw_printenv" \
  PLUTO_FW_SETENV="$BIN/fw_setenv" \
  PLUTO_CMDLINE_FILE="$TMP/cmdline" \
  PLUTO_SYNC="$BIN/sync" \
  PLUTO_SYSTEMCTL="$BIN/systemctl" \
  PLUTO_FORCE_REBOOT="$BIN/reboot" \
  PLUTO_TEST_ENV_DIR="$ENV_DIR" \
  PLUTO_TEST_SET_LOG="$SET_LOG" \
  PLUTO_TEST_SYNC_LOG="$SYNC_LOG" \
  PLUTO_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  PLUTO_TEST_REBOOT_LOG="$REBOOT_LOG" \
  PLUTO_TEST_SYSTEMCTL_FAIL_REBOOT="${PLUTO_TEST_SYSTEMCTL_FAIL_REBOOT:-0}" \
  PLUTO_TEST_COUNTER_DIR="$TMP/lpgpr" \
  PLUTO_TEST_SYNC_BLOCK="${PLUTO_TEST_SYNC_BLOCK:-}" \
    "$RECOVERY" "$@"
}

expect_rejected() {
  if run_recovery "$@" > "$TMP/out" 2>&1; then
    fail "unexpected success: $*"
  fi
}

expect_fault() { # point action...
  ef_point=$1
  shift
  if PLUTO_TEST_FAILURE_AT="$ef_point" run_recovery "$@" > "$TMP/out" 2>&1; then
    fail "fault $ef_point did not reject $*"
  fi
  [ ! -s "$SYSTEMCTL_LOG" ] || fail "fault $ef_point rebooted the device"
}

expect_power_loss() { # point action...
  epl_point=$1
  shift
  set +e
  PLUTO_TEST_POWER_LOSS_AT="$epl_point" run_recovery "$@" \
    > "$TMP/out" 2>&1
  epl_status=$?
  set -e
  assert_eq 97 "$epl_status" "$epl_point did not stop at its power boundary"
  [ ! -s "$SYSTEMCTL_LOG" ] || fail "$epl_point rebooted before durability"
}

begin_bound() { # profile
  bb_profile=$1
  begin_receipt=$(run_recovery begin) || fail "$bb_profile begin failed"
  case "$begin_receipt" in
    state=pending/nonce=attempt-one/boot=boot-one/profile="$bb_profile") ;;
    *) fail "$bb_profile begin receipt drifted: $begin_receipt" ;;
  esac
  bb_nonce=$(run_recovery bind "$bb_profile" "$$") ||
    fail "$bb_profile service bind failed"
  assert_eq attempt-one "$bb_nonce" "$bb_profile bind returned wrong nonce"
  kill -0 "$APP_PID" 2>/dev/null || fail "fixture foreground pid is not live"
  READY="$TMP/run/boot-ready.$bb_nonce.launch-one"
  HEALTH="$TMP/run/health.$bb_nonce.launch-one"
  foreground_receipt=$(run_recovery foreground "$bb_profile" "$$" \
    "$APP_PID" "$bb_nonce" "$READY" "$HEALTH") ||
    fail "$bb_profile foreground bind failed"
  assert_eq "state=pending/app=$APP_PID" "$foreground_receipt" \
    "$bb_profile foreground receipt drifted"
}

publish_receipts() {
  printf 'ready\n' > "$READY"
  printf 'pid=%s seq=1 mono_ms=10\n' "$APP_PID" > "$HEALTH"
  chmod 0600 "$READY" "$HEALTH"
}

confirm_bound() { # profile
  cb_profile=$1
  publish_receipts
  confirm_receipt=$(run_recovery confirm "$cb_profile" "$$" "$APP_PID" \
    attempt-one "$READY" "$HEALTH") || fail "$cb_profile confirm failed"
  assert_eq \
    "state=confirmed/profile=$cb_profile/boot=boot-one/nonce=attempt-one/app=$APP_PID" \
    "$confirm_receipt" "$cb_profile confirmation receipt drifted"
}

sleep 300 &
APP_PID=$!
sleep 300 &
OTHER_PID=$!
kill -0 "$$" 2>/dev/null || fail "fixture service pid is not live"
kill -0 "$APP_PID" 2>/dev/null || fail "fixture foreground pid is not live"

write_uboot_config
write_owner rm1 prepared
assert_exact_keys "$CONFIG" \
  PLUTO_RECOVERY_PROFILE_ID PLUTO_RECOVERY_CONFIRMATION_STRATEGY \
  PLUTO_RECOVERY_FAILURE_STRATEGY PLUTO_RECOVERY_BOOT_DEFAULT_ENABLED \
  PLUTO_RECOVERY_OWNER_NONCE PLUTO_RECOVERY_MMC_DEVICE \
  PLUTO_RECOVERY_ROOT_PARTITIONS PLUTO_RECOVERY_BOOT_LIMIT \
  PLUTO_RECOVERY_HELPER PLUTO_RECOVERY_COUNTER_DIR \
  PLUTO_RECOVERY_STOCK_RESCUE_UNIT PLUTO_RECOVERY_PEER_DEVICE \
  PLUTO_RECOVERY_STOCK_XOCHITL_SHA256 PLUTO_RECOVERY_STOCK_UNIT_SHA256 \
  PLUTO_RECOVERY_PEER_XOCHITL_SHA256 PLUTO_RECOVERY_PEER_UNIT_SHA256
assert_exact_keys "$OWNER" PLUTO_OWNER_NONCE PLUTO_OWNER_PROFILE PLUTO_OWNER_STATE

# The hard-removal contract accepts exactly the current key sets. There is no
# schema/version or migration path to accidentally adopt.
seed_uboot 0 7
printf "PLUTO_RECOVERY_SCHEMA='1'\n" >> "$CONFIG"
expect_rejected arm
[ ! -s "$SET_LOG" ] || fail "an inexact config mutated U-Boot"
write_uboot_config
printf "PLUTO_OWNER_SCHEMA='1'\n" >> "$OWNER"
expect_rejected arm
[ ! -s "$SET_LOG" ] || fail "an inexact owner record mutated U-Boot"
write_owner rm1 prepared

# A pre-existing U-Boot upgrade transaction is never adopted without Pluto's
# exact armed owner marker.
for foreign_state in prepared idle; do
  reset_attempt
  write_owner rm1 "$foreign_state"
  seed_uboot 1 4
  expect_rejected arm
  [ ! -s "$SET_LOG" ] || fail "foreign upgrade flag was mutated ($foreign_state)"
  assert_eq 1 "$(/bin/cat "$ENV_DIR/upgrade_available")" \
    "foreign upgrade flag was cleared"
done
rm -f "$OWNER"
seed_uboot 1 4
expect_rejected arm
[ ! -s "$SET_LOG" ] || fail "ownerless upgrade flag was mutated"

# Explicit disarm follows the same commit-last rule and leaves a durable idle
# owner record for an uninstall/cancel path.
reset_attempt
write_owner rm1 prepared
seed_uboot 0 9
run_recovery arm >/dev/null || fail "explicit arm before disarm failed"
: > "$SET_LOG"
run_recovery disarm >/dev/null || fail "explicit disarm failed"
assert_eq "bootcount 0
upgrade_available 0" "$(/bin/cat "$SET_LOG")" \
  "disarm ordering drifted"
assert_eq idle "$(sed -n "s/^PLUTO_OWNER_STATE='\([^']*\)'$/\1/p" "$OWNER")" \
  "disarm did not persist idle ownership"

# The full U-Boot boot attempt is bound to a live systemd/service/app tuple and
# fresh nonce paths. Commit flags are last in both arm and confirm directions.
reset_attempt
write_owner rm1 prepared
seed_uboot 0 9
begin_bound rm1
assert_eq "bootcount 0
upgrade_available 1" "$(/bin/cat "$SET_LOG")" \
  "arm ordering drifted"
publish_receipts
confirm_bound rm1
tail -n 2 "$SET_LOG" > "$TMP/confirm-tail"
assert_eq "bootcount 0
upgrade_available 0" "$(/bin/cat "$TMP/confirm-tail")" \
  "confirm ordering drifted"
assert_eq idle "$(sed -n "s/^PLUTO_OWNER_STATE='\([^']*\)'$/\1/p" "$OWNER")" \
  "confirm did not persist idle ownership"

# A later same-boot service failure is still owned: it re-arms first, then
# requests fallback, durably, before forcing reboot.
: > "$SET_LOG"
: > "$SYSTEMCTL_LOG"
failure_receipt=$(run_recovery failure) || fail "post-confirm failure failed"
assert_eq \
  'state=fallback-requested/profile=rm1/boot=boot-one/nonce=attempt-one' \
  "$failure_receipt" "post-confirm failure receipt drifted"
assert_eq "bootcount 0
upgrade_available 1
bootcount 1" "$(/bin/cat "$SET_LOG")" \
  "post-confirm failure did not re-arm before fallback"
assert_eq 1 "$(/bin/cat "$ENV_DIR/upgrade_available")" \
  "post-confirm failure was not armed"
assert_eq 1 "$(/bin/cat "$ENV_DIR/bootcount")" \
  "post-confirm failure did not request fallback"
assert_eq '--force --force reboot' "$(/bin/cat "$SYSTEMCTL_LOG")" \
  "post-confirm failure did not force reboot"

# If systemd's force reboot fails, the independent reboot -f path is mandatory.
reset_attempt
write_owner rm1 prepared
seed_uboot 0 6
begin_bound rm1
confirm_bound rm1
: > "$SYSTEMCTL_LOG"
PLUTO_TEST_SYSTEMCTL_FAIL_REBOOT=1 run_recovery failure > "$TMP/out" ||
  fail "secondary reboot fallback failed"
assert_eq '--force --force reboot' "$(/bin/cat "$SYSTEMCTL_LOG")" \
  "primary reboot was not attempted"
assert_eq '-f' "$(/bin/cat "$REBOOT_LOG")" \
  "secondary reboot -f was not attempted"

# Every tuple dimension is fail-closed before U-Boot confirmation.
reset_attempt
write_owner rm1 prepared
seed_uboot 0 5
begin_bound rm1
publish_receipts
: > "$SET_LOG"
expect_rejected confirm move "$$" "$APP_PID" attempt-one "$READY" "$HEALTH"
expect_rejected confirm rm1 "$OTHER_PID" "$APP_PID" attempt-one "$READY" "$HEALTH"
expect_rejected confirm rm1 "$$" "$OTHER_PID" attempt-one "$READY" "$HEALTH"
expect_rejected confirm rm1 "$$" "$APP_PID" wrong-nonce "$READY" "$HEALTH"
expect_rejected confirm rm1 "$$" "$APP_PID" attempt-one "$READY.other" "$HEALTH"
expect_rejected confirm rm1 "$$" "$APP_PID" attempt-one "$READY" "$HEALTH.other"
PLUTO_TEST_INVOCATION=other-invocation expect_rejected confirm rm1 "$$" \
  "$APP_PID" attempt-one "$READY" "$HEALTH"
printf 'boot-two\n' > "$TMP/boot-id"
expect_rejected confirm rm1 "$$" "$APP_PID" attempt-one "$READY" "$HEALTH"
printf 'boot-one\n' > "$TMP/boot-id"
[ ! -s "$SET_LOG" ] || fail "drifted attempt tuple mutated U-Boot"

# Foreground paths must be nonce-paired and stale-free.
reset_attempt
write_owner rm1 prepared
seed_uboot 0 5
run_recovery begin >/dev/null
run_recovery bind rm1 "$$" >/dev/null
expect_rejected foreground rm1 "$$" "$APP_PID" attempt-one \
  "$TMP/run/not-bound" "$TMP/run/not-bound-health"
READY="$TMP/run/boot-ready.attempt-one.stale"
HEALTH="$TMP/run/health.attempt-one.stale"
: > "$READY"
expect_rejected foreground rm1 "$$" "$APP_PID" attempt-one "$READY" "$HEALTH"

# Power-loss points preserve a recoverable flag order.
reset_attempt
write_owner rm1 prepared
seed_uboot 0 7
expect_power_loss arm_owner arm
assert_eq '7:0' "$(/bin/cat "$ENV_DIR/bootcount"):$(/bin/cat "$ENV_DIR/upgrade_available")" \
  "arm owner boundary changed U-Boot"

write_owner rm1 prepared
seed_uboot 0 7
expect_power_loss arm_bootcount arm
assert_eq '0:0' "$(/bin/cat "$ENV_DIR/bootcount"):$(/bin/cat "$ENV_DIR/upgrade_available")" \
  "arm bootcount boundary is unsafe"

write_owner rm1 prepared
seed_uboot 0 7
expect_power_loss arm_upgrade_available arm
assert_eq '0:1' "$(/bin/cat "$ENV_DIR/bootcount"):$(/bin/cat "$ENV_DIR/upgrade_available")" \
  "arm commit boundary is not owned and armed"

write_owner rm1 armed
seed_uboot 1 4
expect_power_loss disarm_bootcount disarm
assert_eq '0:1' "$(/bin/cat "$ENV_DIR/bootcount"):$(/bin/cat "$ENV_DIR/upgrade_available")" \
  "disarm pre-commit boundary disarmed early"

write_owner rm1 armed
seed_uboot 1 4
expect_power_loss disarm_upgrade_available disarm
assert_eq '0:0' "$(/bin/cat "$ENV_DIR/bootcount"):$(/bin/cat "$ENV_DIR/upgrade_available")" \
  "disarm commit boundary stayed armed"

write_owner rm1 armed
seed_uboot 1 4
expect_power_loss disarm_owner disarm
assert_eq idle "$(sed -n "s/^PLUTO_OWNER_STATE='\([^']*\)'$/\1/p" "$OWNER")" \
  "disarm owner boundary did not persist idle ownership"

reset_attempt
write_owner rm1 prepared
seed_uboot 0 7
begin_bound rm1
publish_receipts
expect_power_loss confirm_bootcount confirm rm1 "$$" "$APP_PID" attempt-one "$READY" "$HEALTH"
assert_eq '0:1' "$(/bin/cat "$ENV_DIR/bootcount"):$(/bin/cat "$ENV_DIR/upgrade_available")" \
  "confirm pre-commit boundary disarmed early"

reset_attempt
write_owner rm1 prepared
seed_uboot 0 7
begin_bound rm1
publish_receipts
expect_power_loss confirm_upgrade_available confirm rm1 "$$" "$APP_PID" attempt-one "$READY" "$HEALTH"
assert_eq '0:0' "$(/bin/cat "$ENV_DIR/bootcount"):$(/bin/cat "$ENV_DIR/upgrade_available")" \
  "confirm commit boundary stayed armed"

reset_attempt
write_owner rm1 prepared
seed_uboot 0 7
begin_bound rm1
confirm_bound rm1
: > "$SYSTEMCTL_LOG"
expect_power_loss failure_bootcount failure
assert_eq '1:1' "$(/bin/cat "$ENV_DIR/bootcount"):$(/bin/cat "$ENV_DIR/upgrade_available")" \
  "failure counter boundary did not request fallback"

reset_attempt
write_owner rm1 prepared
seed_uboot 0 7
begin_bound rm1
confirm_bound rm1
: > "$SYSTEMCTL_LOG"
expect_power_loss failure_durable failure
assert_eq '1:1' "$(/bin/cat "$ENV_DIR/bootcount"):$(/bin/cat "$ENV_DIR/upgrade_available")" \
  "durable failure boundary lost fallback state"

# Read, write, owner-publish, and durability failures all reject without a
# reboot. The commit flag may only be set when the exact armed owner persists.
for fault_point in \
  fw_read.active_partition fw_read.fallback_partition fw_read.bootlimit \
  fw_read.upgrade_available fw_set.bootcount fw_set.upgrade_available \
  owner.remount_rw owner.before_publish owner.remount_ro.sync \
  owner.remount_ro arm.sync
do
  reset_attempt
  write_owner rm1 prepared
  seed_uboot 0 8
  expect_fault "$fault_point" arm
  if [ "$(/bin/cat "$ENV_DIR/upgrade_available")" = 1 ]; then
    assert_eq armed \
      "$(sed -n "s/^PLUTO_OWNER_STATE='\([^']*\)'$/\1/p" "$OWNER")" \
      "$fault_point set the commit flag without armed ownership"
  fi
done

write_owner rm1 armed
seed_uboot 1 4
expect_fault disarm.sync disarm
assert_eq '0:0' "$(/bin/cat "$ENV_DIR/bootcount"):$(/bin/cat "$ENV_DIR/upgrade_available")" \
  "disarm sync fault left an invalid environment pair"
assert_eq armed "$(sed -n "s/^PLUTO_OWNER_STATE='\([^']*\)'$/\1/p" "$OWNER")" \
  "disarm sync fault discarded ownership before durability"

reset_attempt
write_owner rm1 prepared
seed_uboot 0 8
begin_bound rm1
publish_receipts
: > "$SYSTEMCTL_LOG"
expect_fault confirm.sync confirm rm1 "$$" "$APP_PID" attempt-one "$READY" "$HEALTH"
assert_eq '0:0' "$(/bin/cat "$ENV_DIR/bootcount"):$(/bin/cat "$ENV_DIR/upgrade_available")" \
  "confirm sync fault left an invalid environment pair"
assert_eq armed "$(sed -n "s/^PLUTO_OWNER_STATE='\([^']*\)'$/\1/p" "$OWNER")" \
  "confirm sync fault discarded recovery ownership"

reset_attempt
write_owner rm1 prepared
seed_uboot 0 8
begin_bound rm1
confirm_bound rm1
: > "$SYSTEMCTL_LOG"
expect_fault failure.sync failure
assert_eq '1:1' "$(/bin/cat "$ENV_DIR/bootcount"):$(/bin/cat "$ENV_DIR/upgrade_available")" \
  "failure sync fault lost the fallback request"

# A stale action lock is reclaimed. Concurrent transitions remain serialized
# while the first owner is blocked at a durability boundary.
reset_attempt
write_owner rm1 prepared
seed_uboot 0 8
mkdir "$LOCK"
printf '999999 1\n' > "$LOCK/owner"
run_recovery arm >/dev/null || fail "stale recovery lock was not reclaimed"

reset_attempt
write_owner rm1 prepared
seed_uboot 0 8
: > "$TMP/sync-block"
PLUTO_TEST_SYNC_BLOCK="$TMP/sync-block" run_recovery arm > "$TMP/arm-one" 2>&1 &
arm_one=$!
wait_count=0
while [ ! -e "$TMP/sync-block.entered" ] && [ "$wait_count" -lt 100 ]; do
  sleep 0.05
  wait_count=$((wait_count + 1))
done
[ -e "$TMP/sync-block.entered" ] || fail "first transition never reached sync barrier"
PLUTO_TEST_SYNC_BLOCK="$TMP/sync-block" run_recovery arm > "$TMP/arm-two" 2>&1 &
arm_two=$!
sleep 0.2
kill -0 "$arm_two" 2>/dev/null || fail "second transition bypassed the action lock"
rm -f "$TMP/sync-block"
wait "$arm_one" || fail "first serialized transition failed"
wait "$arm_two" || fail "second serialized transition failed"

# Move uses no U-Boot mutation. Its exact LPGPR receipt confirms the boot; a
# later failure starts only the bounded stock rescue service.
reset_attempt
write_move_config
write_owner move prepared
seed_uboot 0 8
printf 'a\n' > "$TMP/lpgpr/root_part"
printf '3\n' > "$TMP/lpgpr/roota_errcnt"
begin_bound move
[ ! -s "$SET_LOG" ] || fail "Move begin mutated U-Boot"
confirm_bound move
assert_eq 0 "$(/bin/cat "$TMP/lpgpr/roota_errcnt")" \
  "Move LPGPR counter was not reset"
[ ! -s "$SET_LOG" ] || fail "Move confirmation mutated U-Boot"
: > "$SYSTEMCTL_LOG"
move_failure=$(run_recovery failure) || fail "Move stock rescue failed"
assert_eq 'state=stock-rescue/profile=move/boot=boot-one/nonce=attempt-one' \
  "$move_failure" "Move stock rescue receipt drifted"
assert_eq 'start --no-block pluto-stock-rescue.service' \
  "$(/bin/cat "$SYSTEMCTL_LOG")" "Move bounded stock rescue was not started"
[ ! -s "$SET_LOG" ] || fail "Move failure mutated U-Boot"
expect_rejected arm
[ ! -s "$SET_LOG" ] || fail "Move arm action mutated U-Boot"

/bin/sh -n "$RECOVERY" || fail "recovery handler is not POSIX-sh parseable"
if command -v dash >/dev/null 2>&1; then
  dash -n "$RECOVERY" || fail "recovery handler is not dash parseable"
fi

printf 'boot recovery test: PASS\n'
