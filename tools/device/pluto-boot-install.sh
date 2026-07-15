#!/bin/sh
# Pluto boot-default transaction. One generated hardware profile selects the
# recovery primitive; all file ordering, ownership, peer-stock validation, and
# rollback logic is shared.
set -u

ROOT="${PLUTO_ROOT:-/home/root/pluto}"
SYSTEM_ROOT="${PLUTO_SYSTEM_ROOT:-}"
UNIT_DIR_REL=/usr/lib/systemd/system
UNIT_DIR="$SYSTEM_ROOT$UNIT_DIR_REL"
STATE="$ROOT/state"
SYSTEMCTL="${PLUTO_SYSTEMCTL:-systemctl}"
MOUNT="${PLUTO_MOUNT:-mount}"
UMOUNT="${PLUTO_UMOUNT:-umount}"
SYNC="${PLUTO_SYNC:-sync}"
SHA256SUM="${PLUTO_SHA256SUM:-sha256sum}"
STAT="${PLUTO_STAT:-stat}"
PEER_ROOT_OVERRIDE="${PLUTO_PEER_ROOT:-}"
PROFILE_FILE="${PLUTO_PROFILE_FILE:-$ROOT/share/device-profiles.sh}"
FW_PRINTENV="${PLUTO_FW_PRINTENV:-/usr/sbin/fw_printenv}"
FW_SETENV="${PLUTO_FW_SETENV:-/usr/sbin/fw_setenv}"
CMDLINE_FILE="${PLUTO_CMDLINE_FILE:-/proc/cmdline}"
NONCE_FILE="${PLUTO_NONCE_FILE:-/proc/sys/kernel/random/uuid}"
INSTALL_LOCK_DIR="${PLUTO_BOOT_INSTALL_LOCK_DIR:-/run/pluto/boot-install.lock}"
RUN_DIR="${PLUTO_RUN_DIR:-/run/pluto}"
ATTEMPT_FILE="$RUN_DIR/boot-attempt"
SUPERVISOR="${PLUTO_SUPERVISOR:-$ROOT/bin/pluto-session.sh}"

DROPIN_DIR_REL="$UNIT_DIR_REL/xochitl.service.d"
DROPIN_REL="$DROPIN_DIR_REL/zz-pluto.conf"
DROPIN="$SYSTEM_ROOT$DROPIN_REL"
RECOVERY_HANDLER_REL=/usr/libexec/pluto-boot-recovery
RECOVERY_CONFIG_REL=/usr/lib/pluto/boot-recovery.conf
RECOVERY_OWNER_REL=/usr/lib/pluto/boot-owner
RECOVERY_FAILURE_UNIT_REL="$UNIT_DIR_REL/pluto-boot-failure.service"
STOCK_RESCUE_UNIT_REL="$UNIT_DIR_REL/pluto-stock-rescue.service"
RECOVERY_HANDLER="$SYSTEM_ROOT$RECOVERY_HANDLER_REL"
RECOVERY_CONFIG="$SYSTEM_ROOT$RECOVERY_CONFIG_REL"
RECOVERY_OWNER="$SYSTEM_ROOT$RECOVERY_OWNER_REL"
RECOVERY_FAILURE_UNIT="$SYSTEM_ROOT$RECOVERY_FAILURE_UNIT_REL"
STOCK_RESCUE_UNIT="$SYSTEM_ROOT$STOCK_RESCUE_UNIT_REL"
STOCK_XOCHITL_REL=/usr/bin/xochitl
STOCK_XOCHITL_UNIT_REL="$UNIT_DIR_REL/xochitl.service"

log() { printf '[pluto-boot %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

fault() {
  [ "${PLUTO_TESTING:-0}" = 1 ] || return 1
  [ "${PLUTO_TEST_FAILURE_AT:-}" = "$1" ] || return 1
  log "injected transaction failure at: $1"
  return 0
}

power_loss_at() {
  [ "${PLUTO_TESTING:-0}" = 1 ] || return 0
  [ "${PLUTO_TEST_POWER_LOSS_AT:-}" = "$1" ] || return 0
  log "injected power loss at durable boundary: $1"
  exit 97
}

rootfs_rw() {  # phase
  fault "$1.remount_rw" && return 1
  [ -n "$SYSTEM_ROOT" ] && return 0
  "$MOUNT" -o remount,rw / 2>/dev/null
}

rootfs_commit() {  # phase
  rfc_ok=1
  if fault "$1.sync"; then
    rfc_ok=0
  else
    "$SYNC" || rfc_ok=0
  fi
  if fault "$1.remount_ro"; then
    rfc_ok=0
  elif [ -z "$SYSTEM_ROOT" ]; then
    "$MOUNT" -o remount,ro / 2>/dev/null || rfc_ok=0
  fi
  [ "$rfc_ok" -eq 1 ]
}

write_assignment() {
  wa_escaped="$(printf '%s' "$2" | sed "s/'/'\\\\''/g")" || return 1
  printf "%s='%s'\n" "$1" "$wa_escaped"
}

is_token() {
  case "$1" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; *) return 0 ;; esac
}

secure_file() {
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

assignment_value() {
  av_count="$(grep -c "^$2='[A-Za-z0-9_.,:/=-]*'$" "$1" 2>/dev/null)" ||
    return 1
  [ "$av_count" -eq 1 ] || return 1
  av_line="$(grep "^$2='[A-Za-z0-9_.,:/=-]*'$" "$1")" || return 1
  av_value=${av_line#*=\'}
  av_value=${av_value%\'}
  printf '%s\n' "$av_value"
}

validate_exact_keys() {
  vek_file=$1
  shift
  vek_lines="$(wc -l < "$vek_file" | tr -d '[:space:]')" || return 1
  [ "$vek_lines" -eq "$#" ] || return 1
  for vek_key in "$@"; do
    assignment_value "$vek_file" "$vek_key" >/dev/null || return 1
  done
}

proc_start_ticks() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  if ! pst_stat="$(cat "/proc/$1/stat" 2>/dev/null)"; then
    [ "${PLUTO_TESTING:-0}" = 1 ] && kill -0 "$1" 2>/dev/null || return 1
    printf '%s\n' "$1"
    return 0
  fi
  pst_after=${pst_stat#*) }
  [ "$pst_after" != "$pst_stat" ] || return 1
  set -- $pst_after
  [ "$#" -ge 20 ] || return 1
  shift 19
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$1"
}

release_install_lock() {
  [ "${INSTALL_LOCK_HELD:-0}" = 1 ] || return 0
  rm -f "$INSTALL_LOCK_DIR/owner"
  rmdir "$INSTALL_LOCK_DIR" 2>/dev/null || true
  INSTALL_LOCK_HELD=0
}

acquire_install_lock() {
  mkdir -p "$(dirname "$INSTALL_LOCK_DIR")" || return 1
  ail_wait=0
  while [ "$ail_wait" -lt 50 ]; do
    if mkdir "$INSTALL_LOCK_DIR" 2>/dev/null; then
      ail_start="$(proc_start_ticks "$$")" || {
        rmdir "$INSTALL_LOCK_DIR" 2>/dev/null || true
        return 1
      }
      printf '%s %s\n' "$$" "$ail_start" > "$INSTALL_LOCK_DIR/owner" ||
        {
          rm -f "$INSTALL_LOCK_DIR/owner"
          rmdir "$INSTALL_LOCK_DIR" 2>/dev/null || true
          return 1
        }
      INSTALL_LOCK_HELD=1
      trap 'release_install_lock' 0
      trap 'release_install_lock; exit 129' HUP
      trap 'release_install_lock; exit 130' INT
      trap 'release_install_lock; exit 143' TERM
      return 0
    fi
    ail_pid=0
    ail_start=0
    ail_extra=invalid
    if [ -r "$INSTALL_LOCK_DIR/owner" ] &&
       IFS=' ' read -r ail_pid ail_start ail_extra < \
      "$INSTALL_LOCK_DIR/owner" 2>/dev/null; then
      [ -z "${ail_extra:-}" ] || ail_pid=0
    fi
    if [ "$ail_wait" -gt 0 ] &&
       [ "$(proc_start_ticks "$ail_pid" 2>/dev/null || true)" != "$ail_start" ]; then
      rm -f "$INSTALL_LOCK_DIR/owner"
      rmdir "$INSTALL_LOCK_DIR" 2>/dev/null || true
    else
      sleep 0.1
    fi
    ail_wait=$((ail_wait + 1))
  done
  return 1
}

require_payload() {
  [ -x "$ROOT/bin/pluto-embedder" ] || return 1
  [ -x "$ROOT/bin/pluto-session.sh" ] || return 1
  [ -x "$ROOT/bin/pluto-boot-confirm.sh" ] || return 1
  [ -d "$ROOT/launcher/bundle" ] || return 1
  [ -f "$ROOT/launcher/bundle/lib/app.so" ] || return 1
  [ ! -f "$ROOT/launcher/bundle/flutter_assets/kernel_blob.bin" ] || return 1
  if [ -f "$ROOT/launcher/install.json" ]; then
    grep -q '"buildMode"[[:space:]]*:[[:space:]]*"release"' \
      "$ROOT/launcher/install.json" || return 1
    grep -q '"engineFlavor"[[:space:]]*:[[:space:]]*"release"' \
      "$ROOT/launcher/install.json" || return 1
  fi
  [ -f "$ROOT/engine/release/libflutter_engine.so" ]
}

load_recovery_profile() {
  [ -n "${PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY:-}" ] && return 0
  [ -r "$PROFILE_FILE" ] || return 1
  # shellcheck source=generated/device-profiles.sh
  . "$PROFILE_FILE"
  if [ -n "${PLUTO_TEST_PROFILE_ID:-}" ]; then
    [ "${PLUTO_TESTING:-0}" = 1 ] &&
      pluto_profile_load "$PLUTO_TEST_PROFILE_ID"
  else
    pluto_profile_probe
  fi
}

boot_env_value() {
  [ -x "$FW_PRINTENV" ] || return 1
  bev_value="$("$FW_PRINTENV" -n "$1" 2>/dev/null)" || return 1
  case "$bev_value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$bev_value"
}

load_slot_topology() {
  case "$PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY" in
    uboot_env)
      ACTIVE_PARTITION="$(boot_env_value active_partition)" || return 1
      FALLBACK_PARTITION="$(boot_env_value fallback_partition)" || return 1
      [ "$(boot_env_value bootlimit)" = \
        "$PLUTO_PROFILE_RECOVERY_BOOT_LIMIT" ] || return 1
      case ",${PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS}," in
        *",$ACTIVE_PARTITION,"*) ;; *) return 1 ;;
      esac
      case ",${PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS}," in
        *",$FALLBACK_PARTITION,"*) ;; *) return 1 ;;
      esac
      [ "$ACTIVE_PARTITION" != "$FALLBACK_PARTITION" ] || return 1
      CURRENT_ROOT="$(sed -n 's/.*[ ]root=\([^ ]*\).*/\1/p' \
        "$CMDLINE_FILE" 2>/dev/null)"
      [ "$CURRENT_ROOT" = \
        "${PLUTO_PROFILE_RECOVERY_MMC_DEVICE}p${ACTIVE_PARTITION}" ] || return 1
      PEER_DEVICE="${PLUTO_PROFILE_RECOVERY_MMC_DEVICE}p${FALLBACK_PARTITION}"
      ;;
    lpgpr_counter)
      ROOT_A_DEVICE="${PLUTO_TEST_ROOT_A:-$(readlink -f /dev/disk/by-partlabel/root_a 2>/dev/null)}"
      ROOT_B_DEVICE="${PLUTO_TEST_ROOT_B:-$(readlink -f /dev/disk/by-partlabel/root_b 2>/dev/null)}"
      [ -n "$ROOT_A_DEVICE" ] && [ -n "$ROOT_B_DEVICE" ] || return 1
      CURRENT_ROOT="$(sed -n 's/.*[ ]root=\([^ ]*\).*/\1/p' \
        "$CMDLINE_FILE" 2>/dev/null)"
      case "$CURRENT_ROOT" in
        "$ROOT_A_DEVICE") PEER_DEVICE=$ROOT_B_DEVICE ;;
        "$ROOT_B_DEVICE") PEER_DEVICE=$ROOT_A_DEVICE ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
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

capture_stock_identity() {  # root prefix; exports CAPTURED_*
  csi_root=$1
  csi_xochitl="$csi_root$STOCK_XOCHITL_REL"
  csi_unit="$csi_root$STOCK_XOCHITL_UNIT_REL"
  [ -f "$csi_xochitl" ] && [ ! -L "$csi_xochitl" ] &&
    [ -x "$csi_xochitl" ] || return 1
  [ -f "$csi_unit" ] && [ ! -L "$csi_unit" ] || return 1
  [ "$(grep -c '^ExecStart=' "$csi_unit" 2>/dev/null)" -eq 1 ] &&
    grep -q '^ExecStart=/usr/bin/xochitl --system$' "$csi_unit" || return 1
  CAPTURED_XOCHITL_SHA="$(hash_file "$csi_xochitl")" || return 1
  CAPTURED_UNIT_SHA="$(hash_file "$csi_unit")" || return 1
}

read_existing_contract() {
  secure_file "$RECOVERY_CONFIG" 600 || return 1
  validate_exact_keys "$RECOVERY_CONFIG" \
    PLUTO_RECOVERY_PROFILE_ID PLUTO_RECOVERY_CONFIRMATION_STRATEGY \
    PLUTO_RECOVERY_FAILURE_STRATEGY PLUTO_RECOVERY_BOOT_DEFAULT_ENABLED \
    PLUTO_RECOVERY_OWNER_NONCE PLUTO_RECOVERY_MMC_DEVICE \
    PLUTO_RECOVERY_ROOT_PARTITIONS PLUTO_RECOVERY_BOOT_LIMIT \
    PLUTO_RECOVERY_HELPER PLUTO_RECOVERY_COUNTER_DIR \
    PLUTO_RECOVERY_STOCK_RESCUE_UNIT PLUTO_RECOVERY_PEER_DEVICE \
    PLUTO_RECOVERY_STOCK_XOCHITL_SHA256 PLUTO_RECOVERY_STOCK_UNIT_SHA256 \
    PLUTO_RECOVERY_PEER_XOCHITL_SHA256 PLUTO_RECOVERY_PEER_UNIT_SHA256 ||
    return 1
  [ "$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_PROFILE_ID)" = \
    "$PLUTO_PROFILE_ID" ] || return 1
  [ "$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_CONFIRMATION_STRATEGY)" = \
    "$PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY" ] || return 1
  [ "$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_FAILURE_STRATEGY)" = \
    "$PLUTO_PROFILE_RECOVERY_FAILURE_STRATEGY" ] || return 1
  [ "$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_BOOT_DEFAULT_ENABLED)" = \
    "$PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED" ] || return 1
  [ "$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_MMC_DEVICE)" = \
    "$PLUTO_PROFILE_RECOVERY_MMC_DEVICE" ] || return 1
  [ "$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_ROOT_PARTITIONS)" = \
    "$PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS" ] || return 1
  [ "$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_BOOT_LIMIT)" = \
    "$PLUTO_PROFILE_RECOVERY_BOOT_LIMIT" ] || return 1
  [ "$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_HELPER)" = \
    "$PLUTO_PROFILE_RECOVERY_HELPER" ] || return 1
  [ "$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_COUNTER_DIR)" = \
    "$PLUTO_PROFILE_RECOVERY_COUNTER_DIR" ] || return 1
  [ "$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_STOCK_RESCUE_UNIT)" = \
    pluto-stock-rescue.service ] || return 1
  EXISTING_OWNER_NONCE="$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_OWNER_NONCE)" || return 1
  is_token "$EXISTING_OWNER_NONCE" || return 1
  EXISTING_PEER_DEVICE="$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_PEER_DEVICE)" || return 1
  [ "$EXISTING_PEER_DEVICE" = "$PEER_DEVICE" ] || return 1
  EXISTING_STOCK_XOCHITL_SHA="$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_STOCK_XOCHITL_SHA256)" || return 1
  EXISTING_STOCK_UNIT_SHA="$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_STOCK_UNIT_SHA256)" || return 1
  EXISTING_PEER_XOCHITL_SHA="$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_PEER_XOCHITL_SHA256)" || return 1
  EXISTING_PEER_UNIT_SHA="$(assignment_value "$RECOVERY_CONFIG" PLUTO_RECOVERY_PEER_UNIT_SHA256)" || return 1
  [ "${#EXISTING_STOCK_XOCHITL_SHA}" -eq 64 ] &&
    [ "${#EXISTING_STOCK_UNIT_SHA}" -eq 64 ] &&
    [ "${#EXISTING_PEER_XOCHITL_SHA}" -eq 64 ] &&
    [ "${#EXISTING_PEER_UNIT_SHA}" -eq 64 ] || return 1
  case "$EXISTING_STOCK_XOCHITL_SHA$EXISTING_STOCK_UNIT_SHA$EXISTING_PEER_XOCHITL_SHA$EXISTING_PEER_UNIT_SHA" in
    *[!0-9a-f]*) return 1 ;;
  esac
}

read_existing_owner() {
  secure_file "$RECOVERY_OWNER" 600 || return 1
  validate_exact_keys "$RECOVERY_OWNER" PLUTO_OWNER_NONCE \
    PLUTO_OWNER_PROFILE PLUTO_OWNER_STATE || return 1
  [ "$(assignment_value "$RECOVERY_OWNER" PLUTO_OWNER_NONCE)" = \
    "$EXISTING_OWNER_NONCE" ] &&
    [ "$(assignment_value "$RECOVERY_OWNER" PLUTO_OWNER_PROFILE)" = \
      "$PLUTO_PROFILE_ID" ] || return 1
  EXISTING_OWNER_STATE="$(assignment_value "$RECOVERY_OWNER" PLUTO_OWNER_STATE)" ||
    return 1
  case "$EXISTING_OWNER_STATE" in prepared|armed|idle) ;; *) return 1 ;; esac
}

existing_owner_is_armed() {
  read_existing_contract && read_existing_owner &&
    [ "$EXISTING_OWNER_STATE" = armed ]
}

remove_dropin_under() {
  rdu_root=$1
  rm -f "$rdu_root$DROPIN_REL" "$rdu_root$DROPIN_REL".tmp.* || return 1
  rmdir "$rdu_root$DROPIN_DIR_REL" 2>/dev/null || true
  [ ! -e "$rdu_root$DROPIN_REL" ]
}

remove_recovery_under() {
  rru_root=$1
  rm -f "$rru_root$RECOVERY_FAILURE_UNIT_REL" \
    "$rru_root$STOCK_RESCUE_UNIT_REL" \
    "$rru_root$RECOVERY_CONFIG_REL" \
    "$rru_root$RECOVERY_OWNER_REL" \
    "$rru_root$RECOVERY_HANDLER_REL" \
    "$rru_root$RECOVERY_FAILURE_UNIT_REL".tmp.* \
    "$rru_root$STOCK_RESCUE_UNIT_REL".tmp.* \
    "$rru_root$RECOVERY_CONFIG_REL".tmp.* \
    "$rru_root$RECOVERY_OWNER_REL".tmp.* \
    "$rru_root$RECOVERY_HANDLER_REL".tmp.* || return 1
  rmdir "$rru_root/usr/lib/pluto" 2>/dev/null || true
}

remove_all_pluto_boot_under() {
  remove_dropin_under "$1" && remove_recovery_under "$1"
}

verify_peer_stock() {
  load_slot_topology || return 1
  if [ -n "$PEER_ROOT_OVERRIDE" ]; then
    PEER_MOUNT=$PEER_ROOT_OVERRIDE
    PEER_MOUNTED=0
  else
    [ -b "$PEER_DEVICE" ] || return 1
    PEER_MOUNT=/tmp/pluto-peer
    mkdir -p "$PEER_MOUNT" || return 1
    fault peer.mount && return 1
    "$MOUNT" "$PEER_DEVICE" "$PEER_MOUNT" 2>/dev/null || return 1
    PEER_MOUNTED=1
  fi

  peer_ok=1
  if fault peer.remove; then
    peer_ok=0
  else
    remove_all_pluto_boot_under "$PEER_MOUNT" || peer_ok=0
  fi
  if fault peer.sync; then
    peer_ok=0
  else
    "$SYNC" || peer_ok=0
  fi
  if fault peer.identity; then
    peer_ok=0
  else
    capture_stock_identity "$PEER_MOUNT" || peer_ok=0
  fi
  if [ "$peer_ok" -eq 1 ]; then
    PEER_XOCHITL_SHA=$CAPTURED_XOCHITL_SHA
    PEER_UNIT_SHA=$CAPTURED_UNIT_SHA
    if [ "${HAVE_EXISTING_CONTRACT:-0}" -eq 1 ]; then
      [ "$PEER_DEVICE" = "$EXISTING_PEER_DEVICE" ] &&
        [ "$PEER_XOCHITL_SHA" = "$EXISTING_PEER_XOCHITL_SHA" ] &&
        [ "$PEER_UNIT_SHA" = "$EXISTING_PEER_UNIT_SHA" ] || peer_ok=0
    fi
  fi
  [ ! -e "$PEER_MOUNT$DROPIN_REL" ] &&
    [ ! -e "$PEER_MOUNT$RECOVERY_CONFIG_REL" ] &&
    [ ! -e "$PEER_MOUNT$RECOVERY_OWNER_REL" ] &&
    [ ! -e "$PEER_MOUNT$RECOVERY_HANDLER_REL" ] || peer_ok=0

  if [ "$PEER_MOUNTED" -eq 1 ]; then
    if fault peer.unmount; then
      peer_ok=0
    else
      "$UMOUNT" "$PEER_MOUNT" 2>/dev/null || peer_ok=0
    fi
    rmdir "$PEER_MOUNT" 2>/dev/null || true
  fi
  [ "$peer_ok" -eq 1 ]
}

new_owner_nonce() {
  OWNER_NONCE="$(cat "$NONCE_FILE" 2>/dev/null)" || return 1
  is_token "$OWNER_NONCE"
}

write_recovery_assets() {
  mkdir -p "$(dirname "$RECOVERY_HANDLER")" \
    "$(dirname "$RECOVERY_CONFIG")" "$UNIT_DIR" || return 1
  wra_handler_tmp="$RECOVERY_HANDLER.tmp.$$"
  wra_config_tmp="$RECOVERY_CONFIG.tmp.$$"
  wra_owner_tmp="$RECOVERY_OWNER.tmp.$$"
  wra_failure_tmp="$RECOVERY_FAILURE_UNIT.tmp.$$"
  wra_stock_tmp="$STOCK_RESCUE_UNIT.tmp.$$"

  cp "$ROOT/bin/pluto-boot-confirm.sh" "$wra_handler_tmp" || return 1
  chmod 0755 "$wra_handler_tmp" || return 1
  mv "$wra_handler_tmp" "$RECOVERY_HANDLER" || return 1
  {
    write_assignment PLUTO_RECOVERY_PROFILE_ID "$PLUTO_PROFILE_ID"
    write_assignment PLUTO_RECOVERY_CONFIRMATION_STRATEGY \
      "$PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY"
    write_assignment PLUTO_RECOVERY_FAILURE_STRATEGY \
      "$PLUTO_PROFILE_RECOVERY_FAILURE_STRATEGY"
    write_assignment PLUTO_RECOVERY_BOOT_DEFAULT_ENABLED \
      "$PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED"
    write_assignment PLUTO_RECOVERY_OWNER_NONCE "$OWNER_NONCE"
    write_assignment PLUTO_RECOVERY_MMC_DEVICE \
      "$PLUTO_PROFILE_RECOVERY_MMC_DEVICE"
    write_assignment PLUTO_RECOVERY_ROOT_PARTITIONS \
      "$PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS"
    write_assignment PLUTO_RECOVERY_BOOT_LIMIT \
      "$PLUTO_PROFILE_RECOVERY_BOOT_LIMIT"
    write_assignment PLUTO_RECOVERY_HELPER "$PLUTO_PROFILE_RECOVERY_HELPER"
    write_assignment PLUTO_RECOVERY_COUNTER_DIR \
      "$PLUTO_PROFILE_RECOVERY_COUNTER_DIR"
    write_assignment PLUTO_RECOVERY_STOCK_RESCUE_UNIT \
      pluto-stock-rescue.service
    write_assignment PLUTO_RECOVERY_PEER_DEVICE "$PEER_DEVICE"
    write_assignment PLUTO_RECOVERY_STOCK_XOCHITL_SHA256 \
      "$STOCK_XOCHITL_SHA"
    write_assignment PLUTO_RECOVERY_STOCK_UNIT_SHA256 "$STOCK_UNIT_SHA"
    write_assignment PLUTO_RECOVERY_PEER_XOCHITL_SHA256 \
      "$PEER_XOCHITL_SHA"
    write_assignment PLUTO_RECOVERY_PEER_UNIT_SHA256 "$PEER_UNIT_SHA"
  } > "$wra_config_tmp" || return 1
  chmod 0600 "$wra_config_tmp" || return 1
  mv "$wra_config_tmp" "$RECOVERY_CONFIG" || return 1
  {
    write_assignment PLUTO_OWNER_NONCE "$OWNER_NONCE"
    write_assignment PLUTO_OWNER_PROFILE "$PLUTO_PROFILE_ID"
    write_assignment PLUTO_OWNER_STATE prepared
  } > "$wra_owner_tmp" || return 1
  chmod 0600 "$wra_owner_tmp" || return 1
  mv "$wra_owner_tmp" "$RECOVERY_OWNER" || return 1

  cat > "$wra_failure_tmp" <<EOF || return 1
[Unit]
Description=Pluto owned boot-attempt failure recovery
DefaultDependencies=no
RefuseManualStart=yes

[Service]
Type=oneshot
ExecStart=$RECOVERY_HANDLER_REL failure
EOF
  chmod 0644 "$wra_failure_tmp" || return 1
  mv "$wra_failure_tmp" "$RECOVERY_FAILURE_UNIT" || return 1

  cat > "$wra_stock_tmp" <<'EOF' || return 1
[Unit]
Description=Bounded stock reMarkable UI rescue
Conflicts=xochitl.service
StartLimitIntervalSec=600
StartLimitBurst=3

[Service]
Type=simple
ExecStart=/usr/bin/xochitl --system
Restart=on-failure
RestartSec=10
EOF
  chmod 0644 "$wra_stock_tmp" || return 1
  mv "$wra_stock_tmp" "$STOCK_RESCUE_UNIT"
}

write_dropin() {
  mkdir -p "$SYSTEM_ROOT$DROPIN_DIR_REL" || return 1
  wd_tmp="$DROPIN.tmp.$$"
  fault activate.publish && return 1
  cat > "$wd_tmp" <<EOF || return 1
# Installed by Pluto: common boot-default supervisor and owned recovery.
[Unit]
RequiresMountsFor=$ROOT
OnFailure=
OnFailure=pluto-boot-failure.service
StartLimitIntervalSec=600
StartLimitBurst=2

[Service]
WatchdogSec=0
Restart=no
Environment=PLUTO_ROOT=$ROOT
ExecStartPre=
ExecStartPre=$RECOVERY_HANDLER_REL begin
ExecStart=
ExecStart=$SUPERVISOR start
EOF
  chmod 0644 "$wd_tmp" || return 1
  mv "$wd_tmp" "$DROPIN"
}

run_recovery_action() {
  [ -x "$RECOVERY_HANDLER" ] && [ -f "$RECOVERY_CONFIG" ] &&
    [ -f "$RECOVERY_OWNER" ] || return 1
  PLUTO_SYSTEM_ROOT="$SYSTEM_ROOT" \
  PLUTO_BOOT_RECOVERY_CONFIG="$RECOVERY_CONFIG" \
  PLUTO_BOOT_OWNER_FILE="$RECOVERY_OWNER" \
  PLUTO_FW_PRINTENV="$FW_PRINTENV" \
  PLUTO_FW_SETENV="$FW_SETENV" \
  PLUTO_CMDLINE_FILE="$CMDLINE_FILE" \
  PLUTO_SYSTEMCTL="$SYSTEMCTL" \
  PLUTO_MOUNT="$MOUNT" \
  PLUTO_SYNC="$SYNC" \
    "$RECOVERY_HANDLER" "$1"
}

rollback_install() {
  rollback_ok=1
  rootfs_rw rollback || rollback_ok=0
  if [ "$rollback_ok" -eq 1 ]; then
    remove_dropin_under "$SYSTEM_ROOT" || rollback_ok=0
    rootfs_commit rollback || rollback_ok=0
  fi
  if [ "$rollback_ok" -eq 1 ]; then
    "$SYSTEMCTL" daemon-reload || rollback_ok=0
  fi
  [ "$rollback_ok" -eq 1 ] || return 1
  if [ "${RECOVERY_MAY_BE_ARMED:-0}" -eq 1 ] &&
     [ "$PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY" = uboot_env ] &&
     [ -f "$RECOVERY_CONFIG" ]; then
    run_recovery_action disarm >/dev/null || return 1
  fi
  rootfs_rw rollback_cleanup || return 1
  if ! remove_recovery_under "$SYSTEM_ROOT"; then
    rootfs_commit rollback_cleanup >/dev/null 2>&1 || true
    return 1
  fi
  rootfs_commit rollback_cleanup || return 1
  rm -f "$STATE/boot-mode" "$STATE/boot-first"
}

abort_install() {
  ai_reason=$1
  if [ "${TRANSACTION_STAGED:-0}" -eq 1 ]; then
    if ! rollback_install; then
      die "$ai_reason; stock-first rollback was incomplete"
    fi
  fi
  die "$ai_reason"
}

uninstall_fail_after_stop() {
  ufas_reason=$1
  "$SYSTEMCTL" reset-failed xochitl.service 2>/dev/null || true
  if ! "$SYSTEMCTL" start xochitl.service ||
     ! "$SYSTEMCTL" is-active --quiet xochitl.service; then
    die "$ufas_reason; stock xochitl also failed to restart"
  fi
  die "$ufas_reason; stock xochitl was restarted"
}

rollback_uninstall_to_pluto() {
  rutp_reason=$1
  rutp_ok=1
  rootfs_rw uninstall_rollback || rutp_ok=0
  if [ "$rutp_ok" -eq 1 ]; then
    write_dropin || rutp_ok=0
    rootfs_commit uninstall_rollback || rutp_ok=0
  fi
  if [ "$rutp_ok" -eq 1 ]; then
    "$SYSTEMCTL" daemon-reload || rutp_ok=0
  fi
  "$SYSTEMCTL" reset-failed xochitl.service 2>/dev/null || true
  if "$SYSTEMCTL" start xochitl.service &&
     "$SYSTEMCTL" is-active --quiet xochitl.service; then
    if [ "$rutp_ok" -eq 1 ]; then
      die "$rutp_reason; Pluto supervisor was restored"
    fi
    die "$rutp_reason; a display service was restarted but rollback was incomplete"
  fi
  die "$rutp_reason; Pluto rollback and stock restart both failed"
}

do_install() {
  mkdir -p "$STATE"
  require_payload || die "release boot payload is incomplete"
  [ -x "$SUPERVISOR" ] || die "supervisor is not executable"
  load_recovery_profile || die "cannot load generated recovery profile"
  load_slot_topology || die "device recovery topology is not exact"

  HAVE_EXISTING_CONTRACT=0
  if read_existing_contract && read_existing_owner; then
    HAVE_EXISTING_CONTRACT=1
  elif [ -e "$RECOVERY_CONFIG" ] || [ -e "$RECOVERY_OWNER" ]; then
    die "inexact recovery state; refusing to replace unowned state"
  fi
  if [ "$HAVE_EXISTING_CONTRACT" -eq 1 ] && [ -e "$ATTEMPT_FILE" ]; then
    die "an active boot attempt owns recovery; stop or uninstall it before reinstalling"
  fi
  RETIRE_EXISTING_ARM=0
  if [ "$PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY" = uboot_env ]; then
    UPGRADE_AVAILABLE="$(boot_env_value upgrade_available)" ||
      die "cannot read upgrade_available before recovery staging"
    case "$UPGRADE_AVAILABLE" in
      0) ;;
      1)
        existing_owner_is_armed ||
          die "refusing to commandeer a pre-existing upgrade_available transaction"
        RETIRE_EXISTING_ARM=1
        ;;
      *) die "invalid upgrade_available before recovery staging" ;;
    esac
  fi

  capture_stock_identity "$SYSTEM_ROOT" || die "active stock UI identity is invalid"
  STOCK_XOCHITL_SHA=$CAPTURED_XOCHITL_SHA
  STOCK_UNIT_SHA=$CAPTURED_UNIT_SHA
  if [ "$HAVE_EXISTING_CONTRACT" -eq 1 ]; then
    [ "$STOCK_XOCHITL_SHA" = "$EXISTING_STOCK_XOCHITL_SHA" ] &&
      [ "$STOCK_UNIT_SHA" = "$EXISTING_STOCK_UNIT_SHA" ] ||
      die "active stock UI identity changed"
  fi
  verify_peer_stock || die "peer root is not an exact stock rescue"
  if [ "$RETIRE_EXISTING_ARM" -eq 1 ]; then
    run_recovery_action disarm >/dev/null ||
      die "could not retire the previous owned recovery transaction"
  fi
  new_owner_nonce || die "could not generate fresh recovery ownership"

  TRANSACTION_STAGED=0
  RECOVERY_MAY_BE_ARMED=0
  rootfs_rw stage || die "cannot remount rootfs for recovery staging"
  if ! write_recovery_assets; then
    TRANSACTION_STAGED=1
    rootfs_commit stage >/dev/null 2>&1 || true
    abort_install "could not stage rootfs recovery assets"
  fi
  TRANSACTION_STAGED=1
  rootfs_commit stage || abort_install "could not make recovery staging durable"
  power_loss_at recovery_handler_durable

  if [ "$PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY" = uboot_env ]; then
    RECOVERY_MAY_BE_ARMED=1
    run_recovery_action arm >/dev/null ||
      abort_install "could not arm owned U-Boot fallback"
    power_loss_at recovery_armed
  else
    log "hardware fallback mutation gated; bounded stock rescue remains active"
  fi

  rootfs_rw activate || abort_install "cannot remount rootfs for activation"
  write_dropin || abort_install "could not publish boot override"
  rootfs_commit activate || abort_install "could not make boot override durable"
  power_loss_at boot_override_durable
  "$SYSTEMCTL" daemon-reload || abort_install "systemd rejected boot override"
  "$SYSTEMCTL" reset-failed xochitl.service 2>/dev/null || true
  printf 'launcher\n' > "$STATE/boot-mode" ||
    abort_install "could not publish boot mode state"
  printf 'yes\n' > "$STATE/boot-first" ||
    abort_install "could not publish boot-first state"
  TRANSACTION_STAGED=0
  RECOVERY_MAY_BE_ARMED=0
  log "installed boot default; peer $PEER_DEVICE is hash-pinned stock rescue"
}

do_uninstall() {
  load_recovery_profile || die "cannot load generated recovery profile"
  load_slot_topology || die "device recovery topology is not exact"
  HAD_CONTRACT=0
  if read_existing_contract && read_existing_owner; then
    HAD_CONTRACT=1
    HAVE_EXISTING_CONTRACT=1
  elif [ -e "$RECOVERY_CONFIG" ] || [ -e "$RECOVERY_OWNER" ]; then
    die "inexact recovery state; refusing unowned removal"
  else
    HAVE_EXISTING_CONTRACT=0
  fi
  capture_stock_identity "$SYSTEM_ROOT" ||
    die "active stock UI identity is invalid before uninstall"
  if [ "$HAD_CONTRACT" -eq 1 ]; then
    [ "$CAPTURED_XOCHITL_SHA" = "$EXISTING_STOCK_XOCHITL_SHA" ] &&
      [ "$CAPTURED_UNIT_SHA" = "$EXISTING_STOCK_UNIT_SHA" ] ||
      die "active stock UI identity changed before uninstall"
  fi
  verify_peer_stock || die "peer root is not an exact stock rescue"

  rootfs_rw uninstall_stock || die "cannot remount rootfs to restore stock"
  if ! remove_dropin_under "$SYSTEM_ROOT"; then
    rootfs_commit uninstall_stock >/dev/null 2>&1 || true
    die "could not remove live boot override"
  fi
  rootfs_commit uninstall_stock || die "could not make stock override durable"
  power_loss_at stock_override_durable

  # Make the stock unit definition effective and stop the owned supervisor
  # before disarming recovery. A concurrent confirmer can otherwise clear or
  # re-arm U-Boot while uninstall is removing its ownership records.
  "$SYSTEMCTL" daemon-reload ||
    die "stock is durable but systemd rejected the restored unit"
  "$SYSTEMCTL" stop xochitl.service ||
    rollback_uninstall_to_pluto \
      "stock is durable but the Pluto supervisor could not be stopped cleanly"

  if [ "$HAD_CONTRACT" -eq 1 ] &&
     [ "$PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY" = uboot_env ]; then
    run_recovery_action arm >/dev/null ||
      rollback_uninstall_to_pluto \
        "could not protect the stock-start handoff with owned fallback"
  fi

  "$SYSTEMCTL" reset-failed xochitl.service 2>/dev/null || true
  if ! "$SYSTEMCTL" start xochitl.service ||
     ! "$SYSTEMCTL" is-active --quiet xochitl.service; then
    rollback_uninstall_to_pluto "stock xochitl did not become active"
  fi

  if [ "$HAD_CONTRACT" -eq 1 ] &&
     [ "$PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY" = uboot_env ]; then
    run_recovery_action disarm >/dev/null ||
      uninstall_fail_after_stop \
        "stock is durable but owned U-Boot recovery could not be disarmed"
    power_loss_at recovery_disarmed
  fi
  rm -f "$ATTEMPT_FILE" "$RUN_DIR"/boot-ready.* "$RUN_DIR"/health.* ||
    uninstall_fail_after_stop "could not retire runtime recovery receipts"
  rootfs_rw uninstall_cleanup ||
    uninstall_fail_after_stop "cannot remount rootfs for cleanup"
  if ! remove_recovery_under "$SYSTEM_ROOT"; then
    rootfs_commit uninstall_cleanup >/dev/null 2>&1 || true
    uninstall_fail_after_stop "could not remove recovery assets"
  fi
  rootfs_commit uninstall_cleanup ||
    uninstall_fail_after_stop "could not make recovery cleanup durable"

  rm -f "$STATE/boot-mode" "$STATE/boot-first"
  log "stock xochitl restored; peer stock identity verified"
}

do_status() {
  installed=no
  [ -f "$DROPIN" ] && installed=yes
  printf 'pluto boot override installed (persistent): %s\n' "$installed"
  printf 'boots first: %s\n' "$([ "$installed" = yes ] && echo Pluto || echo xochitl)"
  printf 'owned recovery installed: %s\n' \
    "$([ -f "$RECOVERY_CONFIG" ] && [ -f "$RECOVERY_OWNER" ] && echo yes || echo no)"
}

case "${1:-status}" in
  install)
    acquire_install_lock || die "another boot transaction owns the installer lock"
    do_install
    ;;
  uninstall)
    acquire_install_lock || die "another boot transaction owns the installer lock"
    do_uninstall
    ;;
  status) do_status ;;
  validate)
    require_payload || die "release boot payload is incomplete"
    log "release AOT launcher payload validated"
    ;;
  *) echo "usage: $0 {install|uninstall|status|validate}"; exit 64 ;;
esac
