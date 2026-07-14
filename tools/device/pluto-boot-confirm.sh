#!/bin/sh
# Confirms a stable Pluto boot through the generated device recovery strategy.
# The session supervisor calls this only after a real release frame has been
# accepted and the stable-start delay has elapsed.
set -u

STRATEGY="${PLUTO_PROFILE_RECOVERY_STRATEGY:-}"
MMC_DEVICE="${PLUTO_PROFILE_RECOVERY_MMC_DEVICE:-}"
ROOT_PARTITIONS="${PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS:-}"
EXPECTED_BOOT_LIMIT="${PLUTO_PROFILE_RECOVERY_BOOT_LIMIT:-}"
VENDOR_HELPER="${PLUTO_PROFILE_RECOVERY_HELPER:-}"
COUNTER_DIR="${PLUTO_PROFILE_RECOVERY_COUNTER_DIR:-}"
FW_PRINTENV="${PLUTO_FW_PRINTENV:-/usr/sbin/fw_printenv}"
FW_SETENV="${PLUTO_FW_SETENV:-/usr/sbin/fw_setenv}"
CMDLINE_FILE="${PLUTO_CMDLINE_FILE:-/proc/cmdline}"

fail() {
  printf 'pluto-boot-confirm: %s\n' "$*" >&2
  exit 1
}

fw_value() {
  value="$("$FW_PRINTENV" -n "$1" 2>/dev/null)" ||
    fail "could not read U-Boot variable $1"
  case "$value" in
    ''|*[!0-9]*) fail "U-Boot variable $1 is not an unsigned integer" ;;
  esac
  printf '%s\n' "$value"
}

confirm_uboot_env() {
  [ -x "$FW_PRINTENV" ] || fail "missing $FW_PRINTENV"
  [ -x "$FW_SETENV" ] || fail "missing $FW_SETENV"
  case "$MMC_DEVICE" in
    /dev/mmcblk[0-9]*) ;;
    *) fail "invalid generated MMC device: $MMC_DEVICE" ;;
  esac
  old_ifs=$IFS
  IFS=,
  set -- $ROOT_PARTITIONS
  IFS=$old_ifs
  [ "$#" -eq 2 ] || fail "generated root partition set is not a pair"
  root_a=$1
  root_b=$2
  case "$root_a:$root_b" in
    *[!0-9:]*|:*|*:|*:*:*) fail "generated root partitions are invalid" ;;
  esac
  [ "$root_a" != "$root_b" ] || fail "generated root partitions collide"

  active="$(fw_value active_partition)"
  fallback="$(fw_value fallback_partition)"
  case "$active:$fallback" in
    "$root_a:$root_b"|"$root_b:$root_a") ;;
    *) fail "active/fallback partitions are outside the generated pair" ;;
  esac
  bootlimit="$(fw_value bootlimit)"
  [ "$bootlimit" = "$EXPECTED_BOOT_LIMIT" ] ||
    fail "bootlimit $bootlimit != expected $EXPECTED_BOOT_LIMIT"

  current_root="$(sed -n 's/.*[ ]root=\([^ ]*\).*/\1/p' "$CMDLINE_FILE" 2>/dev/null)"
  expected_root="${MMC_DEVICE}p${active}"
  [ "$current_root" = "$expected_root" ] ||
    fail "current root $current_root != active U-Boot root $expected_root"
  if [ "${PLUTO_TESTING:-0}" != 1 ]; then
    [ -b "${MMC_DEVICE}p${root_a}" ] ||
      fail "root partition ${MMC_DEVICE}p${root_a} is not a block device"
    [ -b "${MMC_DEVICE}p${root_b}" ] ||
      fail "root partition ${MMC_DEVICE}p${root_b} is not a block device"
  fi

  "$FW_SETENV" bootcount 0 || fail "could not reset U-Boot bootcount"
  bootcount="$(fw_value bootcount)"
  [ "$bootcount" = 0 ] || fail "bootcount readback is $bootcount"
  printf 'partition=%s/root=%s\n' "$active" "$expected_root"
}

confirm_lpgpr_helper() {
  [ -x "$VENDOR_HELPER" ] || fail "missing $VENDOR_HELPER"
  [ -d "$COUNTER_DIR" ] || fail "missing counter directory $COUNTER_DIR"
  "$VENDOR_HELPER" || fail "vendor boot confirmation helper failed"
  part="$(cat "$COUNTER_DIR/root_part" 2>/dev/null)"
  case "$part" in
    a|b) ;;
    *) fail "invalid LPGPR root part: $part" ;;
  esac
  remaining="$(cat "$COUNTER_DIR/root${part}_errcnt" 2>/dev/null)"
  [ "$remaining" = 0 ] ||
    fail "root${part}_errcnt readback is $remaining"
  printf 'part=%s/counter=root%s_errcnt\n' "$part" "$part"
}

case "$STRATEGY" in
  uboot_env) confirm_uboot_env ;;
  lpgpr_helper) confirm_lpgpr_helper ;;
  *) fail "unsupported generated recovery strategy: $STRATEGY" ;;
esac
