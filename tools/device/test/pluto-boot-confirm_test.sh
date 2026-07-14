#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
RECOVERY="$HERE/../pluto-boot-confirm.sh"
PROFILE_FILE="$HERE/../generated/device-profiles.sh"
TMP=${TMPDIR:-/tmp}/pluto-boot-recovery-test.$$
ENV_DIR="$TMP/env"
CONFIG="$TMP/boot-recovery.conf"
SET_LOG="$TMP/set.log"
SYNC_LOG="$TMP/sync.log"
SYSTEMCTL_LOG="$TMP/systemctl.log"

cleanup() { rm -rf "$TMP"; }
trap cleanup 0

fail() {
  printf 'boot recovery test: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP/bin" "$TMP/lpgpr" "$ENV_DIR"
cat > "$TMP/bin/fw_printenv" <<'FW_PRINTENV'
#!/bin/sh
[ "$1" = -n ] && [ "$#" -eq 2 ] || exit 64
cat "$PLUTO_TEST_ENV_DIR/$2"
FW_PRINTENV
cat > "$TMP/bin/fw_setenv" <<'FW_SETENV'
#!/bin/sh
[ "$#" -eq 2 ] || exit 64
case "$1:$2" in
  bootcount:0|bootcount:1|upgrade_available:0|upgrade_available:1) ;;
  *) exit 64 ;;
esac
printf '%s %s\n' "$1" "$2" >> "$PLUTO_TEST_SET_LOG"
printf '%s\n' "$2" > "$PLUTO_TEST_ENV_DIR/$1"
FW_SETENV
cat > "$TMP/bin/sync" <<'SYNC'
#!/bin/sh
printf 'sync\n' >> "$PLUTO_TEST_SYNC_LOG"
SYNC
cat > "$TMP/bin/systemctl" <<'SYSTEMCTL'
#!/bin/sh
printf '%s\n' "$*" >> "$PLUTO_TEST_SYSTEMCTL_LOG"
SYSTEMCTL
cat > "$TMP/bin/reset-lpgpr" <<'RESET_LPGPR'
#!/bin/sh
part=$(cat "$PLUTO_TEST_COUNTER_DIR/root_part")
printf '0\n' > "$PLUTO_TEST_COUNTER_DIR/root${part}_errcnt"
RESET_LPGPR
chmod +x "$TMP/bin/fw_printenv" "$TMP/bin/fw_setenv" "$TMP/bin/sync" \
  "$TMP/bin/systemctl" "$TMP/bin/reset-lpgpr"

. "$PROFILE_FILE"

write_contract() {
  cat > "$CONFIG" <<EOF
PLUTO_RECOVERY_SCHEMA='1'
PLUTO_RECOVERY_PROFILE_ID='$PLUTO_PROFILE_ID'
PLUTO_RECOVERY_CONFIRMATION_STRATEGY='$PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY'
PLUTO_RECOVERY_FAILURE_STRATEGY='$PLUTO_PROFILE_RECOVERY_FAILURE_STRATEGY'
PLUTO_RECOVERY_BOOT_DEFAULT_ENABLED='$PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED'
PLUTO_RECOVERY_MMC_DEVICE='$PLUTO_PROFILE_RECOVERY_MMC_DEVICE'
PLUTO_RECOVERY_ROOT_PARTITIONS='$PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS'
PLUTO_RECOVERY_BOOT_LIMIT='$PLUTO_PROFILE_RECOVERY_BOOT_LIMIT'
PLUTO_RECOVERY_HELPER='$PLUTO_PROFILE_RECOVERY_HELPER'
PLUTO_RECOVERY_COUNTER_DIR='$PLUTO_PROFILE_RECOVERY_COUNTER_DIR'
EOF
}

seed_uboot() {  # upgrade_available bootcount
  printf '2\n' > "$ENV_DIR/active_partition"
  printf '3\n' > "$ENV_DIR/fallback_partition"
  printf '1\n' > "$ENV_DIR/bootlimit"
  printf '%s\n' "$1" > "$ENV_DIR/upgrade_available"
  printf '%s\n' "$2" > "$ENV_DIR/bootcount"
  : > "$SET_LOG"
  : > "$SYNC_LOG"
  : > "$SYSTEMCTL_LOG"
}

run_action() {  # action [power-loss point]
  PLUTO_BOOT_RECOVERY_CONFIG="$CONFIG" \
  PLUTO_TESTING=1 \
  PLUTO_TEST_POWER_LOSS_AT="${2:-}" \
  PLUTO_FW_PRINTENV="$TMP/bin/fw_printenv" \
  PLUTO_FW_SETENV="$TMP/bin/fw_setenv" \
  PLUTO_CMDLINE_FILE="$TMP/cmdline" \
  PLUTO_SYNC="$TMP/bin/sync" \
  PLUTO_SYSTEMCTL="$TMP/bin/systemctl" \
  PLUTO_TEST_ENV_DIR="$ENV_DIR" \
  PLUTO_TEST_SET_LOG="$SET_LOG" \
  PLUTO_TEST_SYNC_LOG="$SYNC_LOG" \
  PLUTO_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  PLUTO_TEST_COUNTER_DIR="$TMP/lpgpr" \
    "$RECOVERY" "$1"
}

expect_power_loss() {  # action point
  set +e
  run_action "$1" "$2" > "$TMP/out" 2>&1
  result=$?
  set -e
  [ "$result" -eq 97 ] || fail "$1/$2 returned $result instead of 97"
}

load_uboot_profile() {  # profile mmc
  pluto_profile_load "$1" || fail "could not load $1"
  write_contract
  printf 'console=tty root=%sp2 rootwait\n' "$2" > "$TMP/cmdline"
}

# Both U-Boot profiles run the complete arm -> confirm transition. The commit
# flag is last in both directions.
for profile_mmc in 'rm1:/dev/mmcblk1' 'rm2:/dev/mmcblk2'; do
  profile=${profile_mmc%%:*}
  mmc=${profile_mmc#*:}
  load_uboot_profile "$profile" "$mmc"
  seed_uboot 0 9
  arm_receipt=$(run_action arm) || fail "$profile arm failed"
  [ "$arm_receipt" = "state=armed/partition=2/root=${mmc}p2" ] ||
    fail "$profile arm receipt drifted: $arm_receipt"
  [ "$(cat "$SET_LOG")" = "bootcount 0
upgrade_available 1" ] || fail "$profile arm ordering drifted"
  confirm_receipt=$(run_action confirm) || fail "$profile confirm failed"
  [ "$confirm_receipt" = "state=confirmed/partition=2/root=${mmc}p2" ] ||
    fail "$profile confirm receipt drifted: $confirm_receipt"
  tail -n 2 "$SET_LOG" > "$TMP/confirm-tail"
  [ "$(cat "$TMP/confirm-tail")" = "bootcount 0
upgrade_available 0" ] || fail "$profile confirm ordering drifted"
done

load_uboot_profile rm1 /dev/mmcblk1

# Every U-Boot environment write boundary is power-loss injected. Before an
# arm commit the flag stays clear; before confirm/disarm commit it stays armed.
seed_uboot 0 7
expect_power_loss arm arm_bootcount
[ "$(cat "$ENV_DIR/bootcount"):$(cat "$ENV_DIR/upgrade_available")" = 0:0 ] ||
  fail "arm bootcount boundary is unsafe"

seed_uboot 0 7
expect_power_loss arm arm_upgrade_available
[ "$(cat "$ENV_DIR/bootcount"):$(cat "$ENV_DIR/upgrade_available")" = 0:1 ] ||
  fail "arm commit boundary is not fully armed"

seed_uboot 1 4
expect_power_loss confirm confirm_bootcount
[ "$(cat "$ENV_DIR/bootcount"):$(cat "$ENV_DIR/upgrade_available")" = 0:1 ] ||
  fail "confirm pre-commit boundary disarmed recovery"

seed_uboot 1 4
expect_power_loss confirm confirm_upgrade_available
[ "$(cat "$ENV_DIR/bootcount"):$(cat "$ENV_DIR/upgrade_available")" = 0:0 ] ||
  fail "confirm commit boundary is not disarmed"

seed_uboot 1 4
expect_power_loss disarm disarm_bootcount
[ "$(cat "$ENV_DIR/bootcount"):$(cat "$ENV_DIR/upgrade_available")" = 0:1 ] ||
  fail "uninstall pre-commit boundary disarmed recovery early"

seed_uboot 1 4
expect_power_loss disarm disarm_upgrade_available
[ "$(cat "$ENV_DIR/bootcount"):$(cat "$ENV_DIR/upgrade_available")" = 0:0 ] ||
  fail "uninstall commit boundary is not disarmed"

seed_uboot 1 0
expect_power_loss failure failure_bootcount
[ "$(cat "$ENV_DIR/bootcount"):$(cat "$ENV_DIR/upgrade_available")" = 1:1 ] ||
  fail "failure counter boundary did not request fallback"
[ ! -s "$SYSTEMCTL_LOG" ] || fail "failure reboot ran before durable state"

seed_uboot 1 0
expect_power_loss failure failure_durable
[ "$(cat "$ENV_DIR/bootcount"):$(cat "$ENV_DIR/upgrade_available")" = 1:1 ] ||
  fail "durable failure boundary lost fallback state"
[ ! -s "$SYSTEMCTL_LOG" ] || fail "failure reboot ran before durable boundary"

seed_uboot 1 0
failure_receipt=$(run_action failure) || fail "failure transition failed"
[ "$failure_receipt" = \
    'state=fallback-requested/partition=2/root=/dev/mmcblk1p2' ] ||
  fail "failure receipt drifted"
[ "$(cat "$SYSTEMCTL_LOG")" = '--force --force reboot' ] ||
  fail "failure path did not use the immediate force reboot action"

# A topology mismatch must fail before any environment mutation.
seed_uboot 1 3
printf 'console=tty root=/dev/mmcblk1p3 rootwait\n' > "$TMP/cmdline"
if run_action confirm > "$TMP/out" 2>&1; then
  fail "mismatched current root was confirmed"
fi
[ ! -s "$SET_LOG" ] || fail "mismatched current root mutated U-Boot"

# Move keeps its explicit LPGPR confirmation mechanism, but arm/failure remain
# rejected until that device's failure and reboot behavior is re-probed.
pluto_profile_load move || fail "could not load Move"
PLUTO_PROFILE_RECOVERY_HELPER="$TMP/bin/reset-lpgpr"
PLUTO_PROFILE_RECOVERY_COUNTER_DIR="$TMP/lpgpr"
export PLUTO_PROFILE_RECOVERY_HELPER PLUTO_PROFILE_RECOVERY_COUNTER_DIR
write_contract
printf 'a\n' > "$TMP/lpgpr/root_part"
printf '2\n' > "$TMP/lpgpr/roota_errcnt"
move_receipt=$(run_action confirm) || fail "Move LPGPR confirmation failed"
[ "$move_receipt" = 'state=confirmed/part=a/counter=roota_errcnt' ] ||
  fail "Move confirmation receipt drifted: $move_receipt"
[ "$(cat "$TMP/lpgpr/roota_errcnt")" = 0 ] ||
  fail "Move LPGPR counter was not reset"
if run_action arm > "$TMP/out" 2>&1; then
  fail "Move armed an unverified boot-default fallback"
fi
if run_action failure > "$TMP/out" 2>&1; then
  fail "Move accepted an unverified boot failure action"
fi

printf 'boot recovery test: PASS\n'
