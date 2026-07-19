#!/bin/sh
# Rootfs-resident, typed boot-attempt owner and recovery state machine.
#
# Persistent ownership lives beside this script's immutable config. A distinct
# /run record binds each systemd invocation to this boot, profile, session pid,
# foreground pid, and fresh nonce. U-Boot state is never adopted unless the
# persistent Pluto owner record proves Pluto armed it first.
set -u

SYSTEM_ROOT="${PLUTO_SYSTEM_ROOT:-}"
CONFIG="${PLUTO_BOOT_RECOVERY_CONFIG:-$SYSTEM_ROOT/usr/lib/pluto/boot-recovery.conf}"
OWNER_FILE="${PLUTO_BOOT_OWNER_FILE:-$SYSTEM_ROOT/usr/lib/pluto/boot-owner}"
ATTEMPT_FILE="${PLUTO_BOOT_ATTEMPT_FILE:-/run/pluto/boot-attempt}"
ATTEMPT_DIR="$(dirname "$ATTEMPT_FILE")"
LOCK_DIR="${PLUTO_BOOT_LOCK_DIR:-/run/pluto/boot-recovery.lock}"
BOOT_ID_FILE="${PLUTO_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
NONCE_FILE="${PLUTO_NONCE_FILE:-/proc/sys/kernel/random/uuid}"
FW_PRINTENV="${PLUTO_FW_PRINTENV:-/usr/sbin/fw_printenv}"
FW_SETENV="${PLUTO_FW_SETENV:-/usr/sbin/fw_setenv}"
CMDLINE_FILE="${PLUTO_CMDLINE_FILE:-/proc/cmdline}"
SYSTEMCTL="${PLUTO_SYSTEMCTL:-systemctl}"
FORCE_REBOOT="${PLUTO_FORCE_REBOOT:-/sbin/reboot}"
MOUNT="${PLUTO_MOUNT:-mount}"
SYNC="${PLUTO_SYNC:-sync}"
STAT="${PLUTO_STAT:-stat}"
SHA256SUM="${PLUTO_SHA256SUM:-sha256sum}"

fail() {
  printf 'pluto-boot-recovery: %s\n' "$*" >&2
  exit 1
}

is_uint() {
  case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

is_token() {
  case "$1" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; *) return 0 ;; esac
}

write_assignment() {
  escaped="$(printf '%s' "$2" | sed "s/'/'\\\\''/g")" || return 1
  printf "%s='%s'\n" "$1" "$escaped"
}

secure_file() {  # path mode
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  [ "${PLUTO_TESTING:-0}" = 1 ] && return 0
  sf_meta="$("$STAT" -c '%u:%a' "$1" 2>/dev/null)" || return 1
  [ "$sf_meta" = "0:$2" ] || return 1
  sf_parent=$(dirname "$1")
  while :; do
    [ -d "$sf_parent" ] && [ ! -L "$sf_parent" ] || return 1
    sf_parent_meta="$("$STAT" -c '%u:%a' "$sf_parent" 2>/dev/null)" ||
      return 1
    sf_parent_uid=${sf_parent_meta%%:*}
    sf_parent_mode=${sf_parent_meta#*:}
    [ "$sf_parent_uid" = 0 ] || return 1
    case "$sf_parent_mode" in
      *[2367][0-7]|*[0-7][2367]) return 1 ;;
    esac
    [ "$sf_parent" != / ] || break
    sf_parent=$(dirname "$sf_parent")
  done
}

assignment_value() {  # file key
  av_count="$(grep -c "^$2='[A-Za-z0-9_.,:/=-]*'$" "$1" 2>/dev/null)" ||
    return 1
  [ "$av_count" -eq 1 ] || return 1
  av_line="$(grep "^$2='[A-Za-z0-9_.,:/=-]*'$" "$1")" || return 1
  av_value=${av_line#*=\'}
  av_value=${av_value%\'}
  printf '%s\n' "$av_value"
}

validate_exact_keys() {  # file expected-key list
  vek_file=$1
  shift
  vek_lines="$(wc -l < "$vek_file" | tr -d '[:space:]')" || return 1
  [ "$vek_lines" -eq "$#" ] || return 1
  for vek_key in "$@"; do
    assignment_value "$vek_file" "$vek_key" >/dev/null || return 1
  done
}

fault() {
  [ "${PLUTO_TESTING:-0}" = 1 ] || return 1
  [ "${PLUTO_TEST_FAILURE_AT:-}" = "$1" ] || return 1
  printf 'pluto-boot-recovery: injected failure at %s\n' "$1" >&2
  return 0
}

power_loss_after() {
  [ "${PLUTO_TESTING:-0}" = 1 ] || return 0
  [ "${PLUTO_TEST_POWER_LOSS_AT:-}" = "$1" ] || return 0
  printf 'pluto-boot-recovery: injected power loss after %s\n' "$1" >&2
  exit 97
}

sync_all() {
  fault "$1" && return 1
  "$SYNC"
}

rootfs_rw() {
  fault "$1" && return 1
  [ -n "$SYSTEM_ROOT" ] && return 0
  "$MOUNT" -o remount,rw /
}

rootfs_ro() {
  rro_ok=1
  sync_all "$1.sync" || rro_ok=0
  if fault "$1"; then
    rro_ok=0
  elif [ -z "$SYSTEM_ROOT" ]; then
    "$MOUNT" -o remount,ro / || rro_ok=0
  fi
  [ "$rro_ok" -eq 1 ]
}

secure_file "$CONFIG" 600 ||
  fail "missing immutable recovery contract: $CONFIG"
validate_exact_keys "$CONFIG" \
  PLUTO_RECOVERY_PROFILE_ID \
  PLUTO_RECOVERY_CONFIRMATION_STRATEGY \
  PLUTO_RECOVERY_FAILURE_STRATEGY \
  PLUTO_RECOVERY_BOOT_DEFAULT_ENABLED \
  PLUTO_RECOVERY_OWNER_NONCE \
  PLUTO_RECOVERY_MMC_DEVICE \
  PLUTO_RECOVERY_ROOT_PARTITIONS \
  PLUTO_RECOVERY_BOOT_LIMIT \
  PLUTO_RECOVERY_HELPER \
  PLUTO_RECOVERY_COUNTER_DIR \
  PLUTO_RECOVERY_STOCK_RESCUE_UNIT \
  PLUTO_RECOVERY_PEER_DEVICE \
  PLUTO_RECOVERY_STOCK_XOCHITL_SHA256 \
  PLUTO_RECOVERY_STOCK_UNIT_SHA256 \
  PLUTO_RECOVERY_PEER_XOCHITL_SHA256 \
  PLUTO_RECOVERY_PEER_UNIT_SHA256 || fail "recovery contract key set is invalid"

PROFILE_ID="$(assignment_value "$CONFIG" PLUTO_RECOVERY_PROFILE_ID)" || fail "profile missing"
CONFIRMATION_STRATEGY="$(assignment_value "$CONFIG" PLUTO_RECOVERY_CONFIRMATION_STRATEGY)" || fail "confirmation missing"
FAILURE_STRATEGY="$(assignment_value "$CONFIG" PLUTO_RECOVERY_FAILURE_STRATEGY)" || fail "failure missing"
BOOT_DEFAULT_ENABLED="$(assignment_value "$CONFIG" PLUTO_RECOVERY_BOOT_DEFAULT_ENABLED)" || fail "boot gate missing"
CONFIG_OWNER_NONCE="$(assignment_value "$CONFIG" PLUTO_RECOVERY_OWNER_NONCE)" || fail "owner missing"
MMC_DEVICE="$(assignment_value "$CONFIG" PLUTO_RECOVERY_MMC_DEVICE)" || fail "MMC field missing"
ROOT_PARTITIONS="$(assignment_value "$CONFIG" PLUTO_RECOVERY_ROOT_PARTITIONS)" || fail "root pair missing"
EXPECTED_BOOT_LIMIT="$(assignment_value "$CONFIG" PLUTO_RECOVERY_BOOT_LIMIT)" || fail "bootlimit missing"
VENDOR_HELPER="$(assignment_value "$CONFIG" PLUTO_RECOVERY_HELPER)" || fail "helper missing"
COUNTER_DIR="$(assignment_value "$CONFIG" PLUTO_RECOVERY_COUNTER_DIR)" || fail "counter missing"
STOCK_RESCUE_UNIT="$(assignment_value "$CONFIG" PLUTO_RECOVERY_STOCK_RESCUE_UNIT)" || fail "rescue unit missing"
STOCK_XOCHITL_SHA="$(assignment_value "$CONFIG" PLUTO_RECOVERY_STOCK_XOCHITL_SHA256)" || fail "stock xochitl pin missing"
STOCK_UNIT_SHA="$(assignment_value "$CONFIG" PLUTO_RECOVERY_STOCK_UNIT_SHA256)" || fail "stock unit pin missing"
PEER_XOCHITL_SHA="$(assignment_value "$CONFIG" PLUTO_RECOVERY_PEER_XOCHITL_SHA256)" || fail "peer xochitl pin missing"
PEER_UNIT_SHA="$(assignment_value "$CONFIG" PLUTO_RECOVERY_PEER_UNIT_SHA256)" || fail "peer unit pin missing"

validate_contract() {
  is_token "$PROFILE_ID" || fail "invalid recovery profile id: $PROFILE_ID"
  is_token "$CONFIG_OWNER_NONCE" || fail "invalid recovery owner nonce"
  case "$BOOT_DEFAULT_ENABLED" in 0|1) ;; *) fail "invalid boot-default gate" ;; esac
  for contract_hash in "$STOCK_XOCHITL_SHA" "$STOCK_UNIT_SHA" \
    "$PEER_XOCHITL_SHA" "$PEER_UNIT_SHA"; do
    [ "${#contract_hash}" -eq 64 ] || fail "invalid recovery identity pin"
    case "$contract_hash" in
      *[!0-9a-f]*) fail "invalid recovery identity pin" ;;
    esac
  done
  case "$CONFIRMATION_STRATEGY:$FAILURE_STRATEGY:$BOOT_DEFAULT_ENABLED" in
    uboot_env:uboot_env_force_reboot:1)
      case "$MMC_DEVICE" in /dev/mmcblk*) ;; *) fail "invalid MMC device" ;; esac
      mmc_suffix=${MMC_DEVICE#/dev/mmcblk}
      is_uint "$mmc_suffix" || fail "invalid MMC device"
      case "$ROOT_PARTITIONS" in *,*) ;; *) fail "root partition set is not a pair" ;; esac
      ROOT_A=${ROOT_PARTITIONS%%,*}
      ROOT_B=${ROOT_PARTITIONS#*,}
      case "$ROOT_B" in *,*) fail "root partition set is not a pair" ;; esac
      is_uint "$ROOT_A" && is_uint "$ROOT_B" &&
        is_uint "$EXPECTED_BOOT_LIMIT" || fail "invalid U-Boot integers"
      [ "$ROOT_A" != "$ROOT_B" ] || fail "root partitions collide"
      [ -z "$VENDOR_HELPER$COUNTER_DIR" ] ||
        fail "U-Boot contract contains LPGPR fields"
      ;;
    lpgpr_counter:unverified:0)
      [ -z "$MMC_DEVICE$ROOT_PARTITIONS$EXPECTED_BOOT_LIMIT" ] ||
        fail "LPGPR contract contains U-Boot fields"
      case "$VENDOR_HELPER:$COUNTER_DIR" in /*:/*) ;; *) fail "invalid LPGPR paths" ;; esac
      [ "$STOCK_RESCUE_UNIT" = pluto-stock-rescue.service ] ||
        fail "invalid stock rescue unit"
      ;;
    *) fail "inconsistent generated recovery contract" ;;
  esac
}

hash_file() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  hf_hash="$("$SHA256SUM" "$1" 2>/dev/null | sed -n '1s/[[:space:]].*//p')" ||
    return 1
  [ "${#hf_hash}" -eq 64 ] || return 1
  case "$hf_hash" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$hf_hash"
}

validate_active_stock() {
  vas_xochitl="$SYSTEM_ROOT/usr/bin/xochitl"
  vas_unit="$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service"
  [ -f "$vas_xochitl" ] && [ ! -L "$vas_xochitl" ] &&
    [ -x "$vas_xochitl" ] || return 1
  [ -f "$vas_unit" ] && [ ! -L "$vas_unit" ] || return 1
  [ "$(grep -c '^ExecStart=' "$vas_unit" 2>/dev/null)" -eq 1 ] &&
    grep -q '^ExecStart=/usr/bin/xochitl --system$' "$vas_unit" || return 1
  [ "$(hash_file "$vas_xochitl")" = "$STOCK_XOCHITL_SHA" ] &&
    [ "$(hash_file "$vas_unit")" = "$STOCK_UNIT_SHA" ]
}

read_boot_id() {
  boot_id="$(cat "$BOOT_ID_FILE" 2>/dev/null)" || return 1
  is_token "$boot_id" || return 1
  printf '%s\n' "$boot_id"
}

new_nonce() {
  nonce="$(cat "$NONCE_FILE" 2>/dev/null)" || return 1
  is_token "$nonce" || return 1
  printf '%s\n' "$nonce"
}

proc_start_ticks() {
  is_uint "$1" || return 1
  if ! stat="$(cat "/proc/$1/stat" 2>/dev/null)"; then
    [ "${PLUTO_TESTING:-0}" = 1 ] && kill -0 "$1" 2>/dev/null || return 1
    printf '%s\n' "$1"
    return 0
  fi
  after_comm=${stat#*) }
  [ "$after_comm" != "$stat" ] || return 1
  set -- $after_comm
  [ "$#" -ge 20 ] || return 1
  shift 19
  is_uint "$1" || return 1
  printf '%s\n' "$1"
}

pid_matches() {
  [ "$(proc_start_ticks "$1" 2>/dev/null)" = "$2" ]
}

release_lock() {
  [ "${LOCK_HELD:-0}" = 1 ] || return 0
  rm -f "$LOCK_DIR/owner"
  rmdir "$LOCK_DIR" 2>/dev/null || true
  LOCK_HELD=0
}

acquire_lock() {
  lock_parent=$(dirname "$LOCK_DIR")
  mkdir -p "$lock_parent" || return 1
  lock_wait=0
  while [ "$lock_wait" -lt 50 ]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      lock_start="$(proc_start_ticks "$$")" || {
        rmdir "$LOCK_DIR" 2>/dev/null || true
        return 1
      }
      printf '%s %s\n' "$$" "$lock_start" > "$LOCK_DIR/owner" || {
        rm -f "$LOCK_DIR/owner"
        rmdir "$LOCK_DIR" 2>/dev/null || true
        return 1
      }
      LOCK_HELD=1
      trap 'release_lock' 0
      trap 'release_lock; exit 129' HUP
      trap 'release_lock; exit 130' INT
      trap 'release_lock; exit 143' TERM
      return 0
    fi
    lock_pid=0
    lock_start=0
    lock_extra=invalid
    if [ -r "$LOCK_DIR/owner" ] &&
       IFS=' ' read -r lock_pid lock_start lock_extra < \
      "$LOCK_DIR/owner" 2>/dev/null; then
      [ -z "${lock_extra:-}" ] || lock_pid=0
    fi
    if [ "$lock_wait" -gt 0 ] && ! pid_matches "$lock_pid" "$lock_start"; then
      rm -f "$LOCK_DIR/owner"
      rmdir "$LOCK_DIR" 2>/dev/null || true
    else
      sleep 0.1
    fi
    lock_wait=$((lock_wait + 1))
  done
  return 1
}

read_owner() {
  secure_file "$OWNER_FILE" 600 || return 1
  validate_exact_keys "$OWNER_FILE" PLUTO_OWNER_NONCE PLUTO_OWNER_PROFILE \
    PLUTO_OWNER_STATE || return 1
  OWNER_NONCE="$(assignment_value "$OWNER_FILE" PLUTO_OWNER_NONCE)" || return 1
  OWNER_PROFILE="$(assignment_value "$OWNER_FILE" PLUTO_OWNER_PROFILE)" || return 1
  OWNER_STATE="$(assignment_value "$OWNER_FILE" PLUTO_OWNER_STATE)" || return 1
  [ "$OWNER_NONCE" = "$CONFIG_OWNER_NONCE" ] &&
    [ "$OWNER_PROFILE" = "$PROFILE_ID" ] || return 1
  case "$OWNER_STATE" in prepared|armed|idle) ;; *) return 1 ;; esac
}

write_owner() {  # prepared|armed|idle
  case "$1" in prepared|armed|idle) ;; *) return 1 ;; esac
  rootfs_rw owner.remount_rw || return 1
  owner_tmp="$OWNER_FILE.tmp.$$"
  owner_ok=1
  mkdir -p "$(dirname "$OWNER_FILE")" || owner_ok=0
  if [ "$owner_ok" -eq 1 ]; then
    {
    write_assignment PLUTO_OWNER_NONCE "$CONFIG_OWNER_NONCE"
    write_assignment PLUTO_OWNER_PROFILE "$PROFILE_ID"
    write_assignment PLUTO_OWNER_STATE "$1"
    } > "$owner_tmp" || owner_ok=0
  fi
  [ "$owner_ok" -eq 0 ] || chmod 0600 "$owner_tmp" || owner_ok=0
  [ "$owner_ok" -eq 0 ] || sync_all owner.before_publish || owner_ok=0
  [ "$owner_ok" -eq 0 ] || mv "$owner_tmp" "$OWNER_FILE" || owner_ok=0
  rm -f "$owner_tmp"
  rootfs_ro owner.remount_ro || owner_ok=0
  [ "$owner_ok" -eq 1 ]
}

read_attempt() {
  secure_file "$ATTEMPT_FILE" 600 || return 1
  validate_exact_keys "$ATTEMPT_FILE" \
    PLUTO_ATTEMPT_OWNER_NONCE PLUTO_ATTEMPT_NONCE PLUTO_ATTEMPT_BOOT_ID \
    PLUTO_ATTEMPT_PROFILE PLUTO_ATTEMPT_INVOCATION \
    PLUTO_ATTEMPT_SERVICE_PID PLUTO_ATTEMPT_SERVICE_START \
    PLUTO_ATTEMPT_APP_PID PLUTO_ATTEMPT_APP_START \
    PLUTO_ATTEMPT_READY_FILE PLUTO_ATTEMPT_HEALTH_FILE \
    PLUTO_ATTEMPT_STATE || return 1
  ATTEMPT_OWNER_NONCE="$(assignment_value "$ATTEMPT_FILE" PLUTO_ATTEMPT_OWNER_NONCE)" || return 1
  ATTEMPT_NONCE="$(assignment_value "$ATTEMPT_FILE" PLUTO_ATTEMPT_NONCE)" || return 1
  ATTEMPT_BOOT_ID="$(assignment_value "$ATTEMPT_FILE" PLUTO_ATTEMPT_BOOT_ID)" || return 1
  ATTEMPT_PROFILE="$(assignment_value "$ATTEMPT_FILE" PLUTO_ATTEMPT_PROFILE)" || return 1
  ATTEMPT_INVOCATION="$(assignment_value "$ATTEMPT_FILE" PLUTO_ATTEMPT_INVOCATION)" || return 1
  ATTEMPT_SERVICE_PID="$(assignment_value "$ATTEMPT_FILE" PLUTO_ATTEMPT_SERVICE_PID)" || return 1
  ATTEMPT_SERVICE_START="$(assignment_value "$ATTEMPT_FILE" PLUTO_ATTEMPT_SERVICE_START)" || return 1
  ATTEMPT_APP_PID="$(assignment_value "$ATTEMPT_FILE" PLUTO_ATTEMPT_APP_PID)" || return 1
  ATTEMPT_APP_START="$(assignment_value "$ATTEMPT_FILE" PLUTO_ATTEMPT_APP_START)" || return 1
  ATTEMPT_READY_FILE="$(assignment_value "$ATTEMPT_FILE" PLUTO_ATTEMPT_READY_FILE)" || return 1
  ATTEMPT_HEALTH_FILE="$(assignment_value "$ATTEMPT_FILE" PLUTO_ATTEMPT_HEALTH_FILE)" || return 1
  ATTEMPT_STATE="$(assignment_value "$ATTEMPT_FILE" PLUTO_ATTEMPT_STATE)" || return 1
  [ "$ATTEMPT_OWNER_NONCE" = "$CONFIG_OWNER_NONCE" ] &&
    [ "$ATTEMPT_PROFILE" = "$PROFILE_ID" ] || return 1
  is_token "$ATTEMPT_NONCE" && is_token "$ATTEMPT_BOOT_ID" &&
    is_token "$ATTEMPT_INVOCATION" || return 1
  case "$ATTEMPT_STATE" in pending|confirmed|rescued) ;; *) return 1 ;; esac
  is_uint "$ATTEMPT_SERVICE_PID" && is_uint "$ATTEMPT_SERVICE_START" &&
    is_uint "$ATTEMPT_APP_PID" && is_uint "$ATTEMPT_APP_START" || return 1
}

write_attempt() {  # state service_pid service_start app_pid app_start ready health
  attempt_state=$1
  attempt_service_pid=$2
  attempt_service_start=$3
  attempt_app_pid=$4
  attempt_app_start=$5
  attempt_ready=$6
  attempt_health=$7
  case "$attempt_state" in pending|confirmed|rescued) ;; *) return 1 ;; esac
  attempt_tmp="$ATTEMPT_FILE.tmp.$$"
  mkdir -p "$(dirname "$ATTEMPT_FILE")" || return 1
  attempt_ok=1
  {
    write_assignment PLUTO_ATTEMPT_OWNER_NONCE "$CONFIG_OWNER_NONCE"
    write_assignment PLUTO_ATTEMPT_NONCE "$ATTEMPT_NONCE"
    write_assignment PLUTO_ATTEMPT_BOOT_ID "$ATTEMPT_BOOT_ID"
    write_assignment PLUTO_ATTEMPT_PROFILE "$PROFILE_ID"
    write_assignment PLUTO_ATTEMPT_INVOCATION "$ATTEMPT_INVOCATION"
    write_assignment PLUTO_ATTEMPT_SERVICE_PID "$attempt_service_pid"
    write_assignment PLUTO_ATTEMPT_SERVICE_START "$attempt_service_start"
    write_assignment PLUTO_ATTEMPT_APP_PID "$attempt_app_pid"
    write_assignment PLUTO_ATTEMPT_APP_START "$attempt_app_start"
    write_assignment PLUTO_ATTEMPT_READY_FILE "$attempt_ready"
    write_assignment PLUTO_ATTEMPT_HEALTH_FILE "$attempt_health"
    write_assignment PLUTO_ATTEMPT_STATE "$attempt_state"
  } > "$attempt_tmp" || attempt_ok=0
  [ "$attempt_ok" -eq 0 ] || chmod 0600 "$attempt_tmp" || attempt_ok=0
  [ "$attempt_ok" -eq 0 ] || mv "$attempt_tmp" "$ATTEMPT_FILE" || attempt_ok=0
  rm -f "$attempt_tmp"
  [ "$attempt_ok" -eq 1 ]
}

validate_attempt_boot() {
  read_owner || fail "missing or invalid persistent boot owner"
  read_attempt || fail "missing or invalid owned boot attempt"
  [ "$ATTEMPT_BOOT_ID" = "$(read_boot_id)" ] ||
    fail "boot attempt belongs to a different boot"
}

validate_invocation() {
  [ -n "${INVOCATION_ID:-}" ] || fail "systemd invocation identity is missing"
  [ "$ATTEMPT_INVOCATION" = "$INVOCATION_ID" ] ||
    fail "boot attempt belongs to a different service invocation"
}

fw_value() {
  fault "fw_read.$1" && fail "injected U-Boot read failure"
  value="$("$FW_PRINTENV" -n "$1" 2>/dev/null)" ||
    fail "could not read U-Boot variable $1"
  is_uint "$value" || fail "U-Boot variable $1 is not unsigned"
  printf '%s\n' "$value"
}

validate_uboot_topology() {
  [ "$CONFIRMATION_STRATEGY" = uboot_env ] ||
    fail "action requires U-Boot recovery"
  [ -x "$FW_PRINTENV" ] && [ -x "$FW_SETENV" ] ||
    fail "U-Boot environment tools are missing"
  ACTIVE="$(fw_value active_partition)"
  FALLBACK="$(fw_value fallback_partition)"
  case "$ACTIVE:$FALLBACK" in
    "$ROOT_A:$ROOT_B"|"$ROOT_B:$ROOT_A") ;;
    *) fail "active/fallback partitions are outside the generated pair" ;;
  esac
  [ "$(fw_value bootlimit)" = "$EXPECTED_BOOT_LIMIT" ] ||
    fail "unexpected U-Boot bootlimit"
  CURRENT_ROOT="$(sed -n 's/.*[ ]root=\([^ ]*\).*/\1/p' "$CMDLINE_FILE" 2>/dev/null)"
  EXPECTED_ROOT="${MMC_DEVICE}p${ACTIVE}"
  [ "$CURRENT_ROOT" = "$EXPECTED_ROOT" ] ||
    fail "current root does not match active U-Boot partition"
  if [ "${PLUTO_TESTING:-0}" != 1 ]; then
    [ -b "${MMC_DEVICE}p${ROOT_A}" ] && [ -b "${MMC_DEVICE}p${ROOT_B}" ] ||
      fail "generated root partitions are unavailable"
  fi
}

set_uboot_value() {
  fault "fw_set.$1" && fail "injected U-Boot write failure"
  "$FW_SETENV" "$1" "$2" || fail "could not set U-Boot variable $1"
  [ "$(fw_value "$1")" = "$2" ] || fail "$1 readback mismatch"
}

arm_uboot() {
  validate_uboot_topology
  read_owner || fail "missing Pluto boot owner"
  upgrade_available="$(fw_value upgrade_available)"
  case "$upgrade_available:$OWNER_STATE" in
    1:armed)
      set_uboot_value bootcount 0
      sync_all arm.existing.sync || fail "could not sync existing arm"
      ;;
    0:prepared|0:idle|0:armed)
      write_owner armed || fail "could not persist Pluto arm ownership"
      power_loss_after arm_owner
      set_uboot_value bootcount 0
      power_loss_after arm_bootcount
      set_uboot_value upgrade_available 1
      power_loss_after arm_upgrade_available
      sync_all arm.sync || fail "could not sync armed environment"
      ;;
    1:*) fail "refusing to adopt a non-Pluto upgrade transaction" ;;
    *) fail "invalid owned U-Boot arm state" ;;
  esac
  printf 'state=armed/partition=%s/root=%s\n' "$ACTIVE" "$EXPECTED_ROOT"
}

disarm_uboot() {
  validate_uboot_topology
  read_owner || fail "missing Pluto boot owner"
  upgrade_available="$(fw_value upgrade_available)"
  if [ "$upgrade_available" = 1 ]; then
    [ "$OWNER_STATE" = armed ] ||
      fail "refusing to clear a non-Pluto upgrade transaction"
  elif [ "$upgrade_available" != 0 ]; then
    fail "invalid upgrade_available"
  fi
  set_uboot_value bootcount 0
  power_loss_after disarm_bootcount
  set_uboot_value upgrade_available 0
  power_loss_after disarm_upgrade_available
  sync_all disarm.sync || fail "could not sync disarmed environment"
  write_owner idle || fail "could not persist disarmed ownership"
  power_loss_after disarm_owner
}

begin_attempt() {
  read_owner || fail "missing Pluto boot owner"
  current_boot="$(read_boot_id)" || fail "could not read boot id"
  invocation="${INVOCATION_ID:-}"
  is_token "$invocation" || fail "systemd invocation identity is missing"
  if [ -e "$ATTEMPT_FILE" ] || [ -L "$ATTEMPT_FILE" ]; then
    read_attempt || fail "existing boot attempt is invalid"
    [ "$ATTEMPT_BOOT_ID" != "$current_boot" ] ||
      fail "this boot already has an undisposed owned attempt"
  fi
  ATTEMPT_NONCE="$(new_nonce)" || fail "could not generate attempt nonce"
  ATTEMPT_BOOT_ID=$current_boot
  ATTEMPT_INVOCATION=$invocation
  write_attempt pending 0 0 0 0 '' '' || fail "could not publish boot attempt"
  power_loss_after begin_attempt
  if [ "$CONFIRMATION_STRATEGY" = uboot_env ]; then
    arm_uboot >/dev/null
  fi
  printf 'state=pending/nonce=%s/boot=%s/profile=%s\n' \
    "$ATTEMPT_NONCE" "$ATTEMPT_BOOT_ID" "$PROFILE_ID"
}

bind_service() {  # profile service_pid
  [ "$1" = "$PROFILE_ID" ] || fail "session profile does not match recovery"
  validate_attempt_boot
  validate_invocation
  [ "$ATTEMPT_STATE" = pending ] && [ "$ATTEMPT_SERVICE_PID" = 0 ] ||
    fail "boot attempt is already bound"
  service_start="$(proc_start_ticks "$2")" || fail "invalid session pid"
  write_attempt pending "$2" "$service_start" 0 0 '' '' ||
    fail "could not bind session pid"
  printf '%s\n' "$ATTEMPT_NONCE"
}

validate_existing_ready() {
  secure_file "$1" 600 &&
    [ "$(wc -l < "$1" 2>/dev/null | tr -d '[:space:]')" = 1 ] &&
    [ "$(cat "$1" 2>/dev/null)" = ready ]
}

validate_existing_health() {  # path app_pid
  veh_pid=$2
  secure_file "$1" 600 || return 1
  [ "$(wc -l < "$1" 2>/dev/null | tr -d '[:space:]')" = 1 ] || return 1
  veh_line="$(cat "$1" 2>/dev/null)" || return 1
  set -- $veh_line
  [ "$#" -eq 3 ] || return 1
  veh_seq=${2#seq=}
  veh_mono=${3#mono_ms=}
  [ "$1" = "pid=$veh_pid" ] && [ "$2" = "seq=$veh_seq" ] &&
    [ "$3" = "mono_ms=$veh_mono" ] || return 1
  is_uint "$veh_seq" && is_uint "$veh_mono" &&
    [ "$veh_line" = "pid=$veh_pid seq=$veh_seq mono_ms=$veh_mono" ]
}

bind_foreground() {  # profile service_pid app_pid nonce ready health
  [ "$1" = "$PROFILE_ID" ] || fail "foreground profile mismatch"
  validate_attempt_boot
  validate_invocation
  [ "$ATTEMPT_NONCE" = "$4" ] || fail "foreground nonce mismatch"
  [ "$ATTEMPT_SERVICE_PID" = "$2" ] &&
    pid_matches "$2" "$ATTEMPT_SERVICE_START" || fail "session identity drifted"
  app_start="$(proc_start_ticks "$3")" || fail "invalid foreground pid"
  ready_prefix="$ATTEMPT_DIR/boot-ready.$ATTEMPT_NONCE."
  health_prefix="$ATTEMPT_DIR/health.$ATTEMPT_NONCE."
  case "$5" in "$ready_prefix"*) ;; *) fail "ready receipt is not nonce-bound" ;; esac
  launch_nonce=${5#"$ready_prefix"}
  is_token "$launch_nonce" || fail "invalid foreground launch nonce"
  [ "$6" = "$health_prefix$launch_nonce" ] ||
    fail "health receipt does not match the foreground launch nonce"
  if [ -e "$5" ] || [ -L "$5" ]; then
    validate_existing_ready "$5" || fail "existing ready receipt is invalid"
  fi
  if [ -e "$6" ] || [ -L "$6" ]; then
    validate_existing_health "$6" "$3" ||
      fail "existing health receipt is invalid"
  fi
  write_attempt "$ATTEMPT_STATE" "$2" "$ATTEMPT_SERVICE_START" \
    "$3" "$app_start" "$5" "$6" || fail "could not bind foreground"
  printf 'state=%s/app=%s\n' "$ATTEMPT_STATE" "$3"
}

validate_bound_attempt() {  # profile service_pid app_pid nonce ready health
  [ "$1" = "$PROFILE_ID" ] || fail "attempt profile mismatch"
  validate_attempt_boot
  validate_invocation
  [ "$ATTEMPT_NONCE" = "$4" ] &&
    [ "$ATTEMPT_SERVICE_PID" = "$2" ] &&
    [ "$ATTEMPT_APP_PID" = "$3" ] &&
    [ "$ATTEMPT_READY_FILE" = "$5" ] &&
    [ "$ATTEMPT_HEALTH_FILE" = "$6" ] || fail "attempt tuple drifted"
  pid_matches "$2" "$ATTEMPT_SERVICE_START" || fail "session pid was reused"
  pid_matches "$3" "$ATTEMPT_APP_START" || fail "foreground pid was reused"
}

confirm_attempt() {  # profile service_pid app_pid nonce ready health
  validate_bound_attempt "$@"
  [ "$ATTEMPT_STATE" = pending ] || fail "boot attempt is not pending"
  [ -f "$5" ] && [ ! -L "$5" ] && [ "$(cat "$5" 2>/dev/null)" = ready ] ||
    fail "fresh ready receipt is missing"
  [ -f "$6" ] && [ ! -L "$6" ] || fail "renderer health receipt is missing"
  if [ "$CONFIRMATION_STRATEGY" = uboot_env ]; then
    validate_uboot_topology
    read_owner && [ "$OWNER_STATE" = armed ] || fail "Pluto arm ownership is absent"
    [ "$(fw_value upgrade_available)" = 1 ] || fail "Pluto recovery is not armed"
    set_uboot_value bootcount 0
    power_loss_after confirm_bootcount
    set_uboot_value upgrade_available 0
    power_loss_after confirm_upgrade_available
    sync_all confirm.sync || fail "could not sync confirmed environment"
    write_owner idle || fail "could not persist confirmed ownership"
  else
    [ -x "$VENDOR_HELPER" ] && [ -d "$COUNTER_DIR" ] ||
      fail "LPGPR confirmation mechanism is unavailable"
    part="$(cat "$COUNTER_DIR/root_part" 2>/dev/null)"
    case "$part" in a|b) ;; *) fail "invalid LPGPR root part" ;; esac
    before="$(cat "$COUNTER_DIR/root${part}_errcnt" 2>/dev/null)"
    is_uint "$before" || fail "invalid LPGPR counter"
    "$VENDOR_HELPER" || fail "LPGPR confirmation helper failed"
    [ "$(cat "$COUNTER_DIR/root_part" 2>/dev/null)" = "$part" ] ||
      fail "LPGPR root selection changed during confirmation"
    [ "$(cat "$COUNTER_DIR/root${part}_errcnt" 2>/dev/null)" = 0 ] ||
      fail "LPGPR confirmation readback failed"
  fi
  write_attempt confirmed "$ATTEMPT_SERVICE_PID" "$ATTEMPT_SERVICE_START" \
    "$ATTEMPT_APP_PID" "$ATTEMPT_APP_START" "$ATTEMPT_READY_FILE" \
    "$ATTEMPT_HEALTH_FILE" || fail "could not publish confirmation"
  printf 'state=confirmed/profile=%s/boot=%s/nonce=%s/app=%s\n' \
    "$PROFILE_ID" "$ATTEMPT_BOOT_ID" "$ATTEMPT_NONCE" "$ATTEMPT_APP_PID"
}

cancel_attempt() {  # profile service_pid nonce
  [ "$1" = "$PROFILE_ID" ] || fail "cancel profile mismatch"
  validate_attempt_boot
  validate_invocation
  [ "$ATTEMPT_NONCE" = "$3" ] && [ "$ATTEMPT_SERVICE_PID" = "$2" ] &&
    pid_matches "$2" "$ATTEMPT_SERVICE_START" || fail "cancel tuple drifted"
  if [ "$CONFIRMATION_STRATEGY" = uboot_env ]; then
    disarm_uboot || fail "could not disarm cancelled attempt"
  fi
  rm -f "$ATTEMPT_READY_FILE" "$ATTEMPT_HEALTH_FILE"
  attempt_tmp="$ATTEMPT_FILE.cancelled.$$"
  mv "$ATTEMPT_FILE" "$attempt_tmp" || fail "could not retire boot attempt"
  rm -f "$attempt_tmp" || fail "could not remove retired boot attempt"
  printf 'state=cancelled/profile=%s/nonce=%s\n' "$PROFILE_ID" "$3"
}

cancel_unbound_attempt() {
  validate_attempt_boot
  validate_invocation
  [ "$ATTEMPT_STATE" = pending ] && [ "$ATTEMPT_SERVICE_PID" = 0 ] ||
    fail "boot attempt is already bound"
  if [ "$CONFIRMATION_STRATEGY" = uboot_env ]; then
    disarm_uboot || fail "could not disarm unbound attempt"
  fi
  rm -f "$ATTEMPT_FILE" || fail "could not retire unbound boot attempt"
  printf 'state=cancelled-unbound/profile=%s/nonce=%s\n' \
    "$PROFILE_ID" "$ATTEMPT_NONCE"
}

failure_attempt() {
  validate_attempt_boot
  case "$CONFIRMATION_STRATEGY:$ATTEMPT_STATE" in
    uboot_env:pending|uboot_env:confirmed|\
    lpgpr_counter:pending|lpgpr_counter:confirmed|lpgpr_counter:rescued) ;;
    *) fail "invalid attempt state for recovery strategy" ;;
  esac
  if [ "$ATTEMPT_SERVICE_PID" != 0 ] &&
     pid_matches "$ATTEMPT_SERVICE_PID" "$ATTEMPT_SERVICE_START" &&
     [ "${PLUTO_TESTING:-0}" != 1 ]; then
    fail "refusing failure recovery while the owned session is still alive"
  fi

  if [ "$CONFIRMATION_STRATEGY" = uboot_env ]; then
    # Pending attempts are already armed. Confirmed attempts were disarmed but
    # retain this same-boot owned marker, so re-arm before requesting fallback.
    upgrade_available="$(fw_value upgrade_available)"
    if [ "$upgrade_available" = 0 ]; then
      arm_uboot >/dev/null
    elif [ "$upgrade_available" = 1 ]; then
      read_owner && [ "$OWNER_STATE" = armed ] ||
        fail "refusing to adopt a non-Pluto upgrade transaction"
      validate_uboot_topology
    else
      fail "invalid upgrade_available"
    fi
    set_uboot_value bootcount 1
    power_loss_after failure_bootcount
    sync_all failure.sync || fail "could not sync fallback request"
    power_loss_after failure_durable
    if ! "$SYSTEMCTL" --force --force reboot; then
      [ -x "$FORCE_REBOOT" ] || fail "both force reboot paths are unavailable"
      "$FORCE_REBOOT" -f || fail "both force reboot paths failed"
    fi
    printf 'state=fallback-requested/profile=%s/boot=%s/nonce=%s\n' \
      "$PROFILE_ID" "$ATTEMPT_BOOT_ID" "$ATTEMPT_NONCE"
  else
    validate_active_stock || fail "active stock identity no longer matches its pins"
    "$SYSTEMCTL" start --no-block "$STOCK_RESCUE_UNIT" ||
      fail "could not start bounded stock rescue"
    write_attempt rescued "$ATTEMPT_SERVICE_PID" "$ATTEMPT_SERVICE_START" \
      "$ATTEMPT_APP_PID" "$ATTEMPT_APP_START" "$ATTEMPT_READY_FILE" \
      "$ATTEMPT_HEALTH_FILE" || fail "could not mark stock rescue"
    printf 'state=stock-rescue/profile=%s/boot=%s/nonce=%s\n' \
      "$PROFILE_ID" "$ATTEMPT_BOOT_ID" "$ATTEMPT_NONCE"
  fi
}

verify_stock() {
  read_owner || fail "missing Pluto boot owner"
  validate_active_stock || fail "active stock identity no longer matches its pins"
  printf 'state=stock-verified/profile=%s\n' "$PROFILE_ID"
}

validate_contract
acquire_lock || fail "another recovery transition owns the action lock"
case "${1:-}" in
  arm) arm_uboot ;;
  begin) begin_attempt ;;
  bind)
    [ "$#" -eq 3 ] || fail "bind requires profile and service pid"
    bind_service "$2" "$3"
    ;;
  foreground)
    [ "$#" -eq 7 ] || fail "foreground requires the owned attempt tuple"
    bind_foreground "$2" "$3" "$4" "$5" "$6" "$7"
    ;;
  confirm)
    [ "$#" -eq 7 ] || fail "confirm requires the owned attempt tuple"
    confirm_attempt "$2" "$3" "$4" "$5" "$6" "$7"
    ;;
  cancel)
    [ "$#" -eq 4 ] || fail "cancel requires profile, session pid, and nonce"
    cancel_attempt "$2" "$3" "$4"
    ;;
  cancel-unbound)
    [ "$#" -eq 1 ] || fail "cancel-unbound takes no tuple"
    cancel_unbound_attempt
    ;;
  verify-stock)
    [ "$#" -eq 1 ] || fail "verify-stock takes no tuple"
    verify_stock
    ;;
  disarm) disarm_uboot ;;
  failure) failure_attempt ;;
  *) fail "usage: $0 {arm|begin|bind|foreground|confirm|cancel|cancel-unbound|verify-stock|disarm|failure}" ;;
esac
