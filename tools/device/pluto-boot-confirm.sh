#!/bin/sh
# Typed boot-recovery state machine. The boot installer copies this file to
# /usr/libexec/pluto-boot-recovery so confirmation and OnFailure recovery do
# not depend on the mutable /home Pluto runtime.
#
# Usage: pluto-boot-recovery {arm|confirm|disarm|failure}
set -u

CONFIG="${PLUTO_BOOT_RECOVERY_CONFIG:-/usr/lib/pluto/boot-recovery.conf}"
FW_PRINTENV="${PLUTO_FW_PRINTENV:-/usr/sbin/fw_printenv}"
FW_SETENV="${PLUTO_FW_SETENV:-/usr/sbin/fw_setenv}"
CMDLINE_FILE="${PLUTO_CMDLINE_FILE:-/proc/cmdline}"
SYSTEMCTL="${PLUTO_SYSTEMCTL:-systemctl}"
SYNC="${PLUTO_SYNC:-sync}"

fail() {
  printf 'pluto-boot-recovery: %s\n' "$*" >&2
  exit 1
}

[ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] ||
  fail "missing immutable recovery contract: $CONFIG"
# The installer writes only single-quoted values generated from the reviewed
# device profile. Every sourced value is independently constrained below.
# shellcheck disable=SC1090
. "$CONFIG"

SCHEMA="${PLUTO_RECOVERY_SCHEMA:-}"
PROFILE_ID="${PLUTO_RECOVERY_PROFILE_ID:-}"
CONFIRMATION_STRATEGY="${PLUTO_RECOVERY_CONFIRMATION_STRATEGY:-}"
FAILURE_STRATEGY="${PLUTO_RECOVERY_FAILURE_STRATEGY:-}"
BOOT_DEFAULT_ENABLED="${PLUTO_RECOVERY_BOOT_DEFAULT_ENABLED:-}"
MMC_DEVICE="${PLUTO_RECOVERY_MMC_DEVICE:-}"
ROOT_PARTITIONS="${PLUTO_RECOVERY_ROOT_PARTITIONS:-}"
EXPECTED_BOOT_LIMIT="${PLUTO_RECOVERY_BOOT_LIMIT:-}"
VENDOR_HELPER="${PLUTO_RECOVERY_HELPER:-}"
COUNTER_DIR="${PLUTO_RECOVERY_COUNTER_DIR:-}"

validate_contract() {
  [ "$SCHEMA" = 1 ] || fail "unsupported recovery contract schema: $SCHEMA"
  case "$PROFILE_ID" in
    ''|*[!a-z0-9_]*) fail "invalid recovery profile id: $PROFILE_ID" ;;
  esac
  case "$CONFIRMATION_STRATEGY" in
    uboot_env|lpgpr_counter) ;;
    *) fail "unsupported confirmation strategy: $CONFIRMATION_STRATEGY" ;;
  esac
  case "$FAILURE_STRATEGY" in
    uboot_env_force_reboot|unverified) ;;
    *) fail "unsupported failure strategy: $FAILURE_STRATEGY" ;;
  esac
  case "$BOOT_DEFAULT_ENABLED" in
    0|1) ;;
    *) fail "invalid boot-default gate: $BOOT_DEFAULT_ENABLED" ;;
  esac

  case "$CONFIRMATION_STRATEGY:$FAILURE_STRATEGY:$BOOT_DEFAULT_ENABLED" in
    uboot_env:uboot_env_force_reboot:1)
      case "$MMC_DEVICE" in
        /dev/mmcblk[0-9]*) ;;
        *) fail "invalid generated MMC device: $MMC_DEVICE" ;;
      esac
      old_ifs=$IFS
      IFS=,
      set -- $ROOT_PARTITIONS
      IFS=$old_ifs
      [ "$#" -eq 2 ] || fail "generated root partition set is not a pair"
      ROOT_A=$1
      ROOT_B=$2
      case "$ROOT_A:$ROOT_B:$EXPECTED_BOOT_LIMIT" in
        *[!0-9:]*) fail "generated U-Boot integers are invalid" ;;
      esac
      [ -n "$ROOT_A" ] && [ -n "$ROOT_B" ] &&
        [ -n "$EXPECTED_BOOT_LIMIT" ] ||
        fail "generated U-Boot integers are empty"
      [ "$ROOT_A" != "$ROOT_B" ] || fail "generated root partitions collide"
      [ -z "$VENDOR_HELPER" ] && [ -z "$COUNTER_DIR" ] ||
        fail "U-Boot recovery contains LPGPR fields"
      ;;
    lpgpr_counter:unverified:0)
      [ -z "$MMC_DEVICE" ] && [ -z "$ROOT_PARTITIONS" ] &&
        [ -z "$EXPECTED_BOOT_LIMIT" ] ||
        fail "LPGPR recovery contains U-Boot fields"
      case "$VENDOR_HELPER:$COUNTER_DIR" in
        /*:/*) ;;
        *) fail "LPGPR recovery paths are invalid" ;;
      esac
      ;;
    *) fail "inconsistent generated recovery contract" ;;
  esac
}

fw_value() {
  value="$("$FW_PRINTENV" -n "$1" 2>/dev/null)" ||
    fail "could not read U-Boot variable $1"
  case "$value" in
    ''|*[!0-9]*) fail "U-Boot variable $1 is not an unsigned integer" ;;
  esac
  printf '%s\n' "$value"
}

validate_uboot_topology() {
  [ "$CONFIRMATION_STRATEGY" = uboot_env ] ||
    fail "action requires the U-Boot recovery contract"
  [ -x "$FW_PRINTENV" ] || fail "missing $FW_PRINTENV"
  [ -x "$FW_SETENV" ] || fail "missing $FW_SETENV"

  ACTIVE="$(fw_value active_partition)"
  FALLBACK="$(fw_value fallback_partition)"
  case "$ACTIVE:$FALLBACK" in
    "$ROOT_A:$ROOT_B"|"$ROOT_B:$ROOT_A") ;;
    *) fail "active/fallback partitions are outside the generated pair" ;;
  esac
  BOOT_LIMIT="$(fw_value bootlimit)"
  [ "$BOOT_LIMIT" = "$EXPECTED_BOOT_LIMIT" ] ||
    fail "bootlimit $BOOT_LIMIT != expected $EXPECTED_BOOT_LIMIT"

  CURRENT_ROOT="$(sed -n 's/.*[ ]root=\([^ ]*\).*/\1/p' "$CMDLINE_FILE" 2>/dev/null)"
  EXPECTED_ROOT="${MMC_DEVICE}p${ACTIVE}"
  [ "$CURRENT_ROOT" = "$EXPECTED_ROOT" ] ||
    fail "current root $CURRENT_ROOT != active U-Boot root $EXPECTED_ROOT"
  if [ "${PLUTO_TESTING:-0}" != 1 ]; then
    [ -b "${MMC_DEVICE}p${ROOT_A}" ] ||
      fail "root partition ${MMC_DEVICE}p${ROOT_A} is not a block device"
    [ -b "${MMC_DEVICE}p${ROOT_B}" ] ||
      fail "root partition ${MMC_DEVICE}p${ROOT_B} is not a block device"
  fi
}

set_uboot_value() {
  variable=$1
  expected=$2
  "$FW_SETENV" "$variable" "$expected" ||
    fail "could not set U-Boot variable $variable"
  actual="$(fw_value "$variable")"
  [ "$actual" = "$expected" ] ||
    fail "$variable readback is $actual, expected $expected"
}

power_loss_after() {
  [ "${PLUTO_TESTING:-0}" = 1 ] || return 0
  [ "${PLUTO_TEST_POWER_LOSS_AT:-}" = "$1" ] || return 0
  printf 'pluto-boot-recovery: injected power loss after %s\n' "$1" >&2
  exit 97
}

sync_environment() {
  "$SYNC" || fail "could not make recovery state durable"
}

arm_uboot() {
  [ "$BOOT_DEFAULT_ENABLED" = 1 ] ||
    fail "boot default is gated off for $PROFILE_ID"
  validate_uboot_topology
  upgrade_available="$(fw_value upgrade_available)"
  case "$upgrade_available" in 0|1) ;; *) fail "invalid upgrade_available" ;; esac
  # The flag is the transaction commit: a loss before it leaves stock boot
  # behavior unchanged; a loss after it leaves a fully armed fallback.
  set_uboot_value bootcount 0
  power_loss_after arm_bootcount
  set_uboot_value upgrade_available 1
  power_loss_after arm_upgrade_available
  sync_environment
  printf 'state=armed/partition=%s/root=%s\n' "$ACTIVE" "$EXPECTED_ROOT"
}

confirm_uboot() {
  validate_uboot_topology
  [ "$(fw_value upgrade_available)" = 1 ] ||
    fail "Pluto recovery is not armed"
  # Disarm flag last. A loss before the flag keeps fallback recovery armed.
  set_uboot_value bootcount 0
  power_loss_after confirm_bootcount
  set_uboot_value upgrade_available 0
  power_loss_after confirm_upgrade_available
  sync_environment
  printf 'state=confirmed/partition=%s/root=%s\n' "$ACTIVE" "$EXPECTED_ROOT"
}

disarm_uboot() {
  validate_uboot_topology
  upgrade_available="$(fw_value upgrade_available)"
  case "$upgrade_available" in 0|1) ;; *) fail "invalid upgrade_available" ;; esac
  set_uboot_value bootcount 0
  power_loss_after disarm_bootcount
  set_uboot_value upgrade_available 0
  power_loss_after disarm_upgrade_available
  sync_environment
  printf 'state=disarmed/partition=%s/root=%s\n' "$ACTIVE" "$EXPECTED_ROOT"
}

fail_uboot() {
  [ "$BOOT_DEFAULT_ENABLED" = 1 ] &&
    [ "$FAILURE_STRATEGY" = uboot_env_force_reboot ] ||
    fail "boot failure handling is not accepted for $PROFILE_ID"
  validate_uboot_topology
  [ "$(fw_value upgrade_available)" = 1 ] ||
    fail "refusing fallback mutation because Pluto recovery is not armed"
  set_uboot_value bootcount 1
  power_loss_after failure_bootcount
  sync_environment
  power_loss_after failure_durable
  # Two --force flags request the systemd immediate-reboot path. This avoids a
  # dead display service holding the machine in an unbootable userspace state.
  "$SYSTEMCTL" --force --force reboot || fail "force reboot failed"
  printf 'state=fallback-requested/partition=%s/root=%s\n' \
    "$ACTIVE" "$EXPECTED_ROOT"
}

confirm_lpgpr_counter() {
  [ -x "$VENDOR_HELPER" ] || fail "missing $VENDOR_HELPER"
  [ -d "$COUNTER_DIR" ] || fail "missing counter directory $COUNTER_DIR"
  "$VENDOR_HELPER" || fail "vendor boot confirmation helper failed"
  part="$(cat "$COUNTER_DIR/root_part" 2>/dev/null)"
  case "$part" in a|b) ;; *) fail "invalid LPGPR root part: $part" ;; esac
  remaining="$(cat "$COUNTER_DIR/root${part}_errcnt" 2>/dev/null)"
  [ "$remaining" = 0 ] ||
    fail "root${part}_errcnt readback is $remaining"
  printf 'state=confirmed/part=%s/counter=root%s_errcnt\n' "$part" "$part"
}

validate_contract
case "${1:-}" in
  arm) arm_uboot ;;
  confirm)
    case "$CONFIRMATION_STRATEGY" in
      uboot_env) confirm_uboot ;;
      lpgpr_counter) confirm_lpgpr_counter ;;
    esac
    ;;
  disarm) disarm_uboot ;;
  failure) fail_uboot ;;
  *) fail "usage: $0 {arm|confirm|disarm|failure}" ;;
esac
