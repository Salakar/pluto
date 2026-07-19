#!/bin/sh
# Recover an RM2 CPU-frequency burst left behind by a dead native presenter.
#
# The presenter takes the companion flock lease, snapshots policy0, atomically
# publishes the exact receipt below, and only then raises scaling_min_freq. This
# helper takes the same lease before inspecting anything. It never guesses at a
# malformed or externally mutated policy and removes the receipt only after the
# original minimum has been written and the complete policy has been verified.
set -u

LOGICAL_RECEIPT=/run/pluto/rm2-cpufreq-burst
LOGICAL_LOCK=/run/pluto/rm2-cpufreq-burst.lock
LOGICAL_POLICY=/sys/devices/system/cpu/cpufreq/policy0

log() { printf 'pluto-rm2-cpufreq-restore: %s\n' "$*" >&2; }
fail() { message=$1; status=${2:-74}; log "ERROR: $message"; exit "$status"; }

is_uint() {
  case "$1" in
    0|[1-9]|[1-9][0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

is_governor() {
  case "$1" in
    ''|*[!a-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

file_uid() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null
}

file_links() {
  stat -c '%h' "$1" 2>/dev/null || stat -f '%l' "$1" 2>/dev/null
}

secure_owned_file() {
  [ -f "$1" ] && [ ! -L "$1" ] &&
    [ "$(file_mode "$1")" = 600 ] &&
    [ "$(file_uid "$1")" = "$EFFECTIVE_UID" ] &&
    [ "$(file_links "$1")" = 1 ]
}

secure_owned_directory() {
  [ -d "$1" ] && [ ! -L "$1" ] &&
    [ "$(file_uid "$1")" = "$EFFECTIVE_UID" ] || return 1
  directory_mode=$(file_mode "$1") || return 1
  case "$directory_mode" in
    [0-7][0-7][0-7]) ;;
    *) return 1 ;;
  esac
  [ $((0$directory_mode & 022)) -eq 0 ]
}

read_one_line() {
  value=
  trailing=
  {
    IFS= read -r value || return 1
    if IFS= read -r trailing; then
      return 1
    fi
    [ -z "$trailing" ] || return 1
  } < "$1" || return 1
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

proc_start_ticks() {
  pid=$1
  stat_file="$PROC_ROOT/$pid/stat"
  if ! stat_line=$(cat "$stat_file" 2>/dev/null); then
    [ ! -d "$PROC_ROOT/$pid" ] && return 2
    return 1
  fi
  # The command name is parenthesized and may itself contain ')'. Remove
  # through the final ') ' so the remaining first word is Linux stat field 3.
  stat_tail=${stat_line##*) }
  [ "$stat_tail" != "$stat_line" ] || return 1
  set -- $stat_tail
  [ "$#" -ge 20 ] || return 1
  proc_state=$1
  case "$proc_state" in
    R|S|D|Z|T|t|X|x|K|W|P|I) ;;
    *) return 1 ;;
  esac
  shift 19
  is_uint "$1" || return 1
  [ "$1" != 0 ] || return 1
  printf '%s %s\n' "$proc_state" "$1"
}

map_path() {
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  printf '%s%s\n' "$FS_ROOT" "$1"
}

parse_receipt() {
  secure_owned_file "$RECEIPT" ||
    fail "receipt is not an exact mode-0600 owned regular file at $LOGICAL_RECEIPT"
  receipt_size=$(wc -c < "$RECEIPT" 2>/dev/null | tr -d ' ') ||
    fail "cannot size receipt"
  is_uint "$receipt_size" && [ "$receipt_size" -le 512 ] ||
    fail "receipt size is invalid"
  receipt_lines=$(wc -l < "$RECEIPT" 2>/dev/null | tr -d ' ') ||
    fail "cannot count receipt lines"
  [ "$receipt_lines" = 6 ] || fail "receipt must contain exactly six newline-terminated fields"
  receipt_final_newlines=$(tail -c 1 "$RECEIPT" 2>/dev/null | wc -l | tr -d ' ') ||
    fail "cannot validate receipt terminator"
  [ "$receipt_final_newlines" = 1 ] ||
    fail "receipt does not end at its sixth newline"

  {
    IFS= read -r line_policy &&
      IFS= read -r line_owner_pid &&
      IFS= read -r line_owner_start &&
      IFS= read -r line_original_min &&
      IFS= read -r line_original_max &&
      IFS= read -r line_original_governor
  } < "$RECEIPT" || fail "receipt is truncated or lacks its final newline"

  [ "$line_policy" = "policy=$LOGICAL_POLICY" ] ||
    fail "receipt policy path is not exact policy0"
  case "$line_owner_pid" in owner_pid=*) OWNER_PID=${line_owner_pid#owner_pid=} ;; *) fail "owner_pid field is out of order" ;; esac
  case "$line_owner_start" in owner_start_ticks=*) OWNER_START=${line_owner_start#owner_start_ticks=} ;; *) fail "owner_start_ticks field is out of order" ;; esac
  case "$line_original_min" in original_min_khz=*) ORIGINAL_MIN=${line_original_min#original_min_khz=} ;; *) fail "original_min_khz field is out of order" ;; esac
  case "$line_original_max" in original_max_khz=*) ORIGINAL_MAX=${line_original_max#original_max_khz=} ;; *) fail "original_max_khz field is out of order" ;; esac
  case "$line_original_governor" in original_governor=*) ORIGINAL_GOVERNOR=${line_original_governor#original_governor=} ;; *) fail "original_governor field is out of order" ;; esac

  is_uint "$OWNER_PID" && [ "${#OWNER_PID}" -le 7 ] &&
    [ "$OWNER_PID" -gt 1 ] &&
    [ "$OWNER_PID" -le 4194304 ] || fail "owner_pid is outside the Linux PID range"
  is_uint "$OWNER_START" && [ "${#OWNER_START}" -le 19 ] &&
    [ "$OWNER_START" != 0 ] || fail "owner_start_ticks is invalid"
  is_uint "$ORIGINAL_MIN" && [ "${#ORIGINAL_MIN}" -le 7 ] &&
    [ "$ORIGINAL_MIN" -ge 792000 ] &&
    [ "$ORIGINAL_MIN" -le 1200000 ] || fail "original_min_khz is outside the RM2 range"
  [ "$ORIGINAL_MAX" = 1200000 ] || fail "original_max_khz is not the RM2 ceiling"
  is_governor "$ORIGINAL_GOVERNOR" &&
    [ "${#ORIGINAL_GOVERNOR}" -le 63 ] || fail "original_governor is unsafe"
}

validate_policy() {
  [ -d "$POLICY" ] && [ ! -L "$POLICY" ] ||
    fail "exact policy0 directory is unavailable"
  for leaf in related_cpus scaling_min_freq scaling_max_freq scaling_governor; do
    path="$POLICY/$leaf"
    [ -f "$path" ] && [ ! -L "$path" ] ||
      fail "policy0/$leaf is not a regular non-symlink file"
  done

  related_cpus=$(read_one_line "$POLICY/related_cpus") ||
    fail "policy0 related_cpus is unreadable or ambiguous"
  [ "$related_cpus" = '0 1' ] || fail "policy0 does not own exactly CPUs 0 and 1"
  CURRENT_MIN=$(read_one_line "$POLICY/scaling_min_freq") ||
    fail "policy0 minimum is unreadable or ambiguous"
  CURRENT_MAX=$(read_one_line "$POLICY/scaling_max_freq") ||
    fail "policy0 maximum is unreadable or ambiguous"
  CURRENT_GOVERNOR=$(read_one_line "$POLICY/scaling_governor") ||
    fail "policy0 governor is unreadable or ambiguous"
  is_uint "$CURRENT_MIN" || fail "policy0 minimum is not an unsigned integer"
  # A SIGKILL can land either after receipt publication but before the raise,
  # or after the raise. No third minimum is owned by this protocol.
  [ "$CURRENT_MIN" = "$ORIGINAL_MIN" ] ||
    [ "$CURRENT_MIN" = "$ORIGINAL_MAX" ] ||
    fail "policy0 minimum was mutated by another owner"
  [ "$CURRENT_MAX" = "$ORIGINAL_MAX" ] ||
    fail "policy0 maximum changed after the snapshot"
  [ "$CURRENT_GOVERNOR" = "$ORIGINAL_GOVERNOR" ] ||
    fail "policy0 governor changed after the snapshot"
}

restore_stale_receipt() {
  [ "$#" -eq 0 ] || fail "usage: $0" 64
  if [ "${PLUTO_TESTING:-0}" = 1 ]; then
    FS_ROOT=${PLUTO_TEST_ROOT:-}
    [ -n "$FS_ROOT" ] || fail "PLUTO_TEST_ROOT is required in test mode" 64
    case "$FS_ROOT" in /*) ;; *) fail "PLUTO_TEST_ROOT must be absolute" 64 ;; esac
    case "$FS_ROOT" in
      *[!A-Za-z0-9_./-]*|*/../*|*/..|*/./*|*/.)
        fail "PLUTO_TEST_ROOT is unsafe" 64 ;;
    esac
  else
    [ -z "${PLUTO_TEST_ROOT:-}" ] || fail "test root override is forbidden in production" 64
    FS_ROOT=
  fi
  RECEIPT=$(map_path "$LOGICAL_RECEIPT") || return 64
  LOCK=$(map_path "$LOGICAL_LOCK") || return 64
  POLICY=$(map_path "$LOGICAL_POLICY") || return 64
  PROC_ROOT=$(map_path /proc) || return 64

  command -v flock >/dev/null 2>&1 || fail "flock is required" 69
  EFFECTIVE_UID=$(id -u 2>/dev/null) || fail "cannot determine effective uid" 69
  is_uint "$EFFECTIVE_UID" || fail "effective uid is invalid" 69
  lock_dir=${LOCK%/*}
  secure_owned_directory "$lock_dir" ||
    fail "lock directory is not an owned non-writable directory"
  [ ! -L "$LOCK" ] || fail "lock path is a symlink"
  saved_umask=$(umask)
  umask 077
  # shellcheck disable=SC3045 -- BusyBox ash and dash both support numeric fds.
  exec 9>"$LOCK" || {
    umask "$saved_umask"
    fail "cannot open cpufreq lease lock"
  }
  umask "$saved_umask"
  secure_owned_file "$LOCK" ||
    fail "cpufreq lease lock is not an exact mode-0600 owned regular file"
  flock -n 9 || fail "cpufreq burst lease is still held by a live owner" 75

  if [ ! -e "$RECEIPT" ]; then
    [ ! -L "$RECEIPT" ] || fail "receipt path is a dangling symlink"
    return 0
  fi
  parse_receipt || return $?

  owner_rc=0
  owner_state=$(proc_start_ticks "$OWNER_PID" 2>/dev/null) || owner_rc=$?
  case "$owner_rc" in
    0)
      set -- $owner_state
      [ "$#" -eq 2 ] || fail "receipt owner identity is ambiguous"
      if [ "$2" = "$OWNER_START" ]; then
        case "$1" in
          Z|X|x) ;;
          *) fail "receipt owner pid=$OWNER_PID start_ticks=$OWNER_START is still live" 75 ;;
        esac
      fi
      ;;
    2) ;;
    *) fail "receipt owner identity is ambiguous" ;;
  esac

  validate_policy || return $?
  printf '%s\n' "$ORIGINAL_MIN" > "$POLICY/scaling_min_freq" ||
    fail "could not restore policy0 minimum"

  restored_min=$(read_one_line "$POLICY/scaling_min_freq") ||
    fail "restored policy0 minimum is unreadable"
  restored_max=$(read_one_line "$POLICY/scaling_max_freq") ||
    fail "policy0 maximum vanished during restore"
  restored_governor=$(read_one_line "$POLICY/scaling_governor") ||
    fail "policy0 governor vanished during restore"
  restored_related=$(read_one_line "$POLICY/related_cpus") ||
    fail "policy0 CPU binding vanished during restore"
  [ "$restored_min" = "$ORIGINAL_MIN" ] || fail "policy0 minimum restore did not stick"
  [ "$restored_max" = "$ORIGINAL_MAX" ] || fail "policy0 maximum changed during restore"
  [ "$restored_governor" = "$ORIGINAL_GOVERNOR" ] || fail "policy0 governor changed during restore"
  [ "$restored_related" = '0 1' ] || fail "policy0 CPU binding changed during restore"

  rm -f "$RECEIPT" || fail "verified receipt could not be retired"
  [ ! -e "$RECEIPT" ] || fail "verified receipt remained after removal"
  log "restored stale RM2 policy0 minimum to ${ORIGINAL_MIN} kHz"
}

restore_stale_receipt "$@"
