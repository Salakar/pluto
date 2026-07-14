#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
CONFIRM="$HERE/../pluto-boot-confirm.sh"
PROFILE_FILE="$HERE/../generated/device-profiles.sh"
TMP=${TMPDIR:-/tmp}/pluto-boot-confirm-test.$$

cleanup() { rm -rf "$TMP"; }
trap cleanup 0

fail() {
  printf 'boot confirmation test: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP/bin" "$TMP/lpgpr"
cat > "$TMP/bin/fw_printenv" <<'FW_PRINTENV'
#!/bin/sh
[ "$1" = -n ] && [ "$#" -eq 2 ] || exit 64
case "$2" in
  active_partition) printf '%s\n' "$PLUTO_TEST_ACTIVE" ;;
  fallback_partition) printf '%s\n' "$PLUTO_TEST_FALLBACK" ;;
  bootlimit) printf '%s\n' "$PLUTO_TEST_BOOTLIMIT" ;;
  bootcount) cat "$PLUTO_TEST_BOOTCOUNT" ;;
  *) exit 1 ;;
esac
FW_PRINTENV
cat > "$TMP/bin/fw_setenv" <<'FW_SETENV'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = bootcount ] && [ "$2" = 0 ] || exit 64
printf '%s\n' "$*" >> "$PLUTO_TEST_SET_LOG"
printf '0\n' > "$PLUTO_TEST_BOOTCOUNT"
FW_SETENV
cat > "$TMP/bin/reset-lpgpr" <<'RESET_LPGPR'
#!/bin/sh
part=$(cat "$PLUTO_PROFILE_RECOVERY_COUNTER_DIR/root_part")
printf '0\n' > "$PLUTO_PROFILE_RECOVERY_COUNTER_DIR/root${part}_errcnt"
RESET_LPGPR
chmod +x "$TMP/bin/fw_printenv" "$TMP/bin/fw_setenv" \
  "$TMP/bin/reset-lpgpr"

. "$PROFILE_FILE"

run_uboot_success() {
  profile=$1
  mmc=$2
  pluto_profile_load "$profile" || fail "could not load $profile"
  printf 'console=tty root=%sp2 rootwait\n' "$mmc" > "$TMP/cmdline"
  printf '4\n' > "$TMP/bootcount"
  : > "$TMP/set.log"
  receipt=$(PLUTO_TESTING=1 \
    PLUTO_FW_PRINTENV="$TMP/bin/fw_printenv" \
    PLUTO_FW_SETENV="$TMP/bin/fw_setenv" \
    PLUTO_CMDLINE_FILE="$TMP/cmdline" \
    PLUTO_TEST_ACTIVE=2 \
    PLUTO_TEST_FALLBACK=3 \
    PLUTO_TEST_BOOTLIMIT=1 \
    PLUTO_TEST_BOOTCOUNT="$TMP/bootcount" \
    PLUTO_TEST_SET_LOG="$TMP/set.log" \
      "$CONFIRM") || fail "$profile U-Boot confirmation failed"
  [ "$receipt" = "partition=2/root=${mmc}p2" ] ||
    fail "$profile recovery receipt drifted: $receipt"
  [ "$(cat "$TMP/bootcount")" = 0 ] ||
    fail "$profile bootcount was not reset"
  [ "$(cat "$TMP/set.log")" = 'bootcount 0' ] ||
    fail "$profile used an unexpected fw_setenv mutation"
}

run_uboot_success rm1 /dev/mmcblk1
run_uboot_success rm2 /dev/mmcblk2

pluto_profile_load rm1 || fail "could not reload rm1"
printf 'console=tty root=/dev/mmcblk1p3 rootwait\n' > "$TMP/cmdline"
printf '4\n' > "$TMP/bootcount"
: > "$TMP/set.log"
if PLUTO_TESTING=1 \
    PLUTO_FW_PRINTENV="$TMP/bin/fw_printenv" \
    PLUTO_FW_SETENV="$TMP/bin/fw_setenv" \
    PLUTO_CMDLINE_FILE="$TMP/cmdline" \
    PLUTO_TEST_ACTIVE=2 \
    PLUTO_TEST_FALLBACK=3 \
    PLUTO_TEST_BOOTLIMIT=1 \
    PLUTO_TEST_BOOTCOUNT="$TMP/bootcount" \
    PLUTO_TEST_SET_LOG="$TMP/set.log" \
      "$CONFIRM" > "$TMP/out" 2>&1; then
  fail "mismatched current root was confirmed"
fi
[ ! -s "$TMP/set.log" ] ||
  fail "mismatched current root mutated U-Boot environment"

pluto_profile_load move || fail "could not load Move"
PLUTO_PROFILE_RECOVERY_HELPER="$TMP/bin/reset-lpgpr"
PLUTO_PROFILE_RECOVERY_COUNTER_DIR="$TMP/lpgpr"
export PLUTO_PROFILE_RECOVERY_HELPER PLUTO_PROFILE_RECOVERY_COUNTER_DIR
printf 'a\n' > "$TMP/lpgpr/root_part"
printf '2\n' > "$TMP/lpgpr/roota_errcnt"
receipt=$("$CONFIRM") || fail "Move LPGPR confirmation failed"
[ "$receipt" = 'part=a/counter=roota_errcnt' ] ||
  fail "Move recovery receipt drifted: $receipt"
[ "$(cat "$TMP/lpgpr/roota_errcnt")" = 0 ] ||
  fail "Move LPGPR counter was not reset"

printf 'boot confirmation test: PASS\n'
