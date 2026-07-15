#!/bin/sh
# Read-only, device-side half of the exact-device acceptance evidence collector.
#
# This script is streamed to `sh -s` over SSH. It deliberately creates no
# remote files and sends all evidence to stdout. Human-readable command tracing
# goes to stderr so the host can preserve a separate timestamped transcript.
set -eu

ROOT=${PLUTO_METRICS_ROOT:-/home/root/pluto}
RUN_DIR=${PLUTO_METRICS_RUN_DIR:-/run/pluto}
SAMPLE_COUNT=${PLUTO_METRICS_SAMPLE_COUNT:-5}
SAMPLE_INTERVAL=${PLUTO_METRICS_SAMPLE_INTERVAL:-1}
TEST_ROOT=${PLUTO_METRICS_TEST_ROOT:-}
SYSTEMCTL=${PLUTO_METRICS_SYSTEMCTL:-systemctl}
JOURNALCTL=${PLUTO_METRICS_JOURNALCTL:-journalctl}
UNAME=${PLUTO_METRICS_UNAME:-uname}
SLEEP=${PLUTO_METRICS_SLEEP:-sleep}
DATE=${PLUTO_METRICS_DATE:-date}
STAT=${PLUTO_METRICS_STAT:-stat}
SHA256SUM=${PLUTO_METRICS_SHA256SUM:-sha256sum}

case "$SAMPLE_COUNT" in
  ''|*[!0-9]*) printf 'acceptance metrics: invalid sample count\n' >&2; exit 64 ;;
esac
case "$SAMPLE_INTERVAL" in
  ''|*[!0-9]*) printf 'acceptance metrics: invalid sample interval\n' >&2; exit 64 ;;
esac
[ "$SAMPLE_COUNT" -ge 2 ] && [ "$SAMPLE_COUNT" -le 60 ] || {
  printf 'acceptance metrics: sample count must be in [2,60]\n' >&2
  exit 64
}
[ "$SAMPLE_INTERVAL" -ge 1 ] && [ "$SAMPLE_INTERVAL" -le 30 ] || {
  printf 'acceptance metrics: sample interval must be in [1,30] seconds\n' >&2
  exit 64
}

utc_now() { "$DATE" -u +%Y-%m-%dT%H:%M:%SZ; }
trace() { printf '[remote %s] %s\n' "$(utc_now)" "$*" >&2; }
fail() {
  trace "FAIL $*"
  printf 'acceptance metrics: %s\n' "$*" >&2
  exit 74
}

# Prefix an absolute device path only in the host-side fixture seam. Production
# never sets TEST_ROOT and therefore reads the real immutable runtime paths.
real_path() {
  case "$1" in
    /*) printf '%s%s\n' "$TEST_ROOT" "$1" ;;
    *) fail "non-absolute evidence path: $1" ;;
  esac
}

logical_path() {
  case "$TEST_ROOT:$1" in
    :*) printf '%s\n' "$1" ;;
    ?*:"$TEST_ROOT"/*) printf '/%s\n' "${1#"$TEST_ROOT"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_int() {
  case "$1" in
    -*) value=${1#-}; case "$value" in ''|*[!0-9]*) return 1 ;; esac ;;
    *[!0-9]*|'') return 1 ;;
  esac
  return 0
}
is_safe_token() {
  case "$1" in ''|*[!A-Za-z0-9_.@:/+=,-]*) return 1 ;; *) return 0 ;; esac
}
single_line() {
  case "$1" in
    *'
'*|*'	'*) return 1 ;;
    *) return 0 ;;
  esac
}

file_mode() {
  "$STAT" -c '%a' "$1" 2>/dev/null || "$STAT" -f '%Lp' "$1" 2>/dev/null
}

file_uid() {
  "$STAT" -c '%u' "$1" 2>/dev/null || "$STAT" -f '%u' "$1" 2>/dev/null
}

require_regular() {
  [ -f "$1" ] && [ ! -L "$1" ] || fail "required regular file missing: $(logical_path "$1")"
}

read_one_line() {
  require_regular "$1"
  count=$(wc -l < "$1" 2>/dev/null | tr -d '[:space:]') || return 1
  [ "$count" = 1 ] || return 1
  value=$(cat "$1") || return 1
  single_line "$value" || return 1
  printf '%s\n' "$value"
}

sha256_file() {
  require_regular "$1"
  digest=$("$SHA256SUM" "$1" 2>/dev/null | awk '{print $1}') || return 1
  case "$digest" in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#digest}" -eq 64 ] || return 1
  printf '%s\n' "$digest"
}

sha256_text() {
  digest=$(printf '%s' "$1" | "$SHA256SUM" 2>/dev/null | awk '{print $1}') || return 1
  case "$digest" in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#digest}" -eq 64 ] || return 1
  printf '%s\n' "$digest"
}

proc_dir() { real_path "/proc/$1"; }

proc_cmdline() {
  file="$(proc_dir "$1")/cmdline"
  require_regular "$file"
  value=$(tr '\000' ' ' < "$file") || return 1
  value=${value% }
  [ -n "$value" ] && single_line "$value" || return 1
  printf '%s\n' "$value"
}

proc_executable() {
  target=$(readlink "$(proc_dir "$1")/exe" 2>/dev/null) || return 1
  [ -n "$target" ] && single_line "$target" || return 1
  logical_path "$target"
}

proc_has_arg() {
  tr '\000' '\n' < "$(proc_dir "$1")/cmdline" 2>/dev/null | grep -Fqx -- "$2"
}

proc_arg_value() {
  prefix=$2
  values=$(tr '\000' '\n' < "$(proc_dir "$1")/cmdline" 2>/dev/null |
    sed -n "s|^$prefix||p") || return 1
  [ -n "$values" ] && single_line "$values" || return 1
  printf '%s\n' "$values"
}

proc_env_value() {
  prefix=$2
  values=$(tr '\000' '\n' < "$(proc_dir "$1")/environ" 2>/dev/null |
    sed -n "s|^$prefix||p") || return 1
  [ -n "$values" ] && single_line "$values" || return 1
  printf '%s\n' "$values"
}

proc_stat_fields() {
  stat_file="$(proc_dir "$1")/stat"
  require_regular "$stat_file"
  process_stat=$(cat "$stat_file") || return 1
  after_comm=${process_stat#*) }
  [ "$after_comm" != "$process_stat" ] || return 1
  set -- $after_comm
  [ "$#" -ge 22 ] || return 1
  state=$1
  shift 11
  utime=$1
  stime=$2
  shift 8
  start_ticks=$1
  shift 2
  rss_pages=$1
  case "$state" in R|S|D|T|t|I) ;; *) return 1 ;; esac
  is_uint "$utime" && is_uint "$stime" && is_uint "$start_ticks" || return 1
  is_int "$rss_pages" || return 1
  printf '%s %s %s %s %s\n' "$state" "$utime" "$stime" "$start_ticks" "$rss_pages"
}

status_field_uint() {
  value=$(awk -v key="$2" '$1 == key ":" {print $2}' "$(proc_dir "$1")/status" 2>/dev/null) || return 1
  [ -n "$value" ] && single_line "$value" && is_uint "$value" || return 1
  printf '%s\n' "$value"
}

proc_fd_count() {
  directory="$(proc_dir "$1")/fd"
  [ -d "$directory" ] || return 1
  count=0
  for descriptor in "$directory"/*; do
    [ -e "$descriptor" ] || [ -L "$descriptor" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

validate_embedder_cmdline() {
  pid=$1
  app_id=$2
  expected_bundle="$ROOT/apps/$app_id/bundle"
  [ "$app_id" = dev.pluto.launcher ] && expected_bundle="$ROOT/launcher/bundle"
  proc_has_arg "$pid" "$ROOT/bin/pluto-embedder" || return 1
  executable=$(proc_executable "$pid") || return 1
  [ "$executable" = "$ROOT/bin/pluto-embedder" ] || return 1
  proc_has_arg "$pid" --release || return 1
  proc_has_arg "$pid" --presenter=native || return 1
  proc_has_arg "$pid" "--engine=$ROOT/engine/release/libflutter_engine.so" || return 1
  proc_has_arg "$pid" "--bundle=$expected_bundle" || return 1
  proc_has_arg "$pid" "--aot-elf=$expected_bundle/lib/app.so" || return 1
  proc_has_arg "$pid" --debug && return 1
  proc_has_arg "$pid" --profile && return 1
  env_app=$(proc_env_value "$pid" PLUTO_APP_ID=) || return 1
  [ "$env_app" = "$app_id" ] || return 1
  return 0
}

service_field() {
  unit=$1
  field=$2
  value=$("$SYSTEMCTL" show "$unit" -p "$field" --value 2>/dev/null) || return 1
  single_line "$value" || return 1
  printf '%s\n' "$value"
}

supervisor_for_unit() {
  candidate_unit=$1
  candidate_active=$(service_field "$candidate_unit" ActiveState 2>/dev/null || true)
  candidate_pid=$(service_field "$candidate_unit" MainPID 2>/dev/null || true)
  [ "$candidate_active" = active ] && is_uint "$candidate_pid" && [ "$candidate_pid" -gt 1 ] || return 1
  proc_has_arg "$candidate_pid" "$ROOT/bin/pluto-session.sh" || return 1
  proc_has_arg "$candidate_pid" start || return 1
  SELECTED_UNIT=$candidate_unit
  SUPERVISOR_PID=$candidate_pid
  return 0
}

read_health() {
  health_real=$1
  expected_pid=$2
  require_regular "$health_real"
  [ "$(file_mode "$health_real")" = 600 ] || return 1
  if [ -z "$TEST_ROOT" ]; then
    [ "$(file_uid "$health_real")" = 0 ] || return 1
  fi
  health_line=$(read_one_line "$health_real") || return 1
  set -- $health_line
  [ "$#" -eq 3 ] || return 1
  [ "$1" = "pid=$expected_pid" ] || return 1
  HEALTH_SEQ=${2#seq=}
  HEALTH_MONO=${3#mono_ms=}
  [ "$2" = "seq=$HEALTH_SEQ" ] && [ "$3" = "mono_ms=$HEALTH_MONO" ] || return 1
  is_uint "$HEALTH_SEQ" && is_uint "$HEALTH_MONO" || return 1
  [ "$health_line" = "pid=$expected_pid seq=$HEALTH_SEQ mono_ms=$HEALTH_MONO" ] || return 1
}

read_temperature() {
  TEMP_SENSOR=
  TEMP_PATH=
  TEMP_MILLIC=
  case "$PLUTO_PROFILE_ID" in
    rm1)
      for zone in "$(real_path /sys/class/thermal)"/thermal_zone*; do
        [ -d "$zone" ] || continue
        name=$(cat "$zone/type" 2>/dev/null || true)
        case "$name" in bq27441*) ;; *) continue ;; esac
        value=$(cat "$zone/temp" 2>/dev/null || true)
        is_int "$value" || continue
        TEMP_SENSOR=$name
        TEMP_PATH=$(logical_path "$zone/temp")
        TEMP_MILLIC=$value
        break
      done
      ;;
    rm2)
      for hwmon in "$(real_path /sys/class/hwmon)"/hwmon*; do
        [ -d "$hwmon" ] || continue
        name=$(cat "$hwmon/name" 2>/dev/null || true)
        [ "$name" = sy7636a_temperature ] || continue
        if value=$(cat "$hwmon/temp0" 2>/dev/null) && is_int "$value"; then
          TEMP_MILLIC=$((value * 1000))
          TEMP_PATH=$(logical_path "$hwmon/temp0")
        elif value=$(cat "$hwmon/temp1_input" 2>/dev/null) && is_int "$value"; then
          TEMP_MILLIC=$value
          TEMP_PATH=$(logical_path "$hwmon/temp1_input")
        else
          continue
        fi
        TEMP_SENSOR=$name
        break
      done
      ;;
    move)
      candidates=
      for hwmon in "$(real_path /sys/class/hwmon)"/hwmon*; do
        [ -d "$hwmon" ] || continue
        input=
        for candidate in "$hwmon"/temp[0-9]*_input; do
          [ -f "$candidate" ] || continue
          input=$candidate
          break
        done
        [ -n "$input" ] || continue
        name=$(cat "$hwmon/name" 2>/dev/null || true)
        safe_name=$(printf '%s' "$name" | tr '[:upper:] ' '[:lower:]_')
        case "$safe_name" in ''|*[!a-z0-9_.-]*) safe_name=unnamed ;; esac
        candidates="$candidates ${safe_name}|${input}"
      done
      selected=
      for preference in epd epaper eink g2194 panel ntc; do
        for candidate in $candidates; do
          name=${candidate%%|*}
          case "$name" in *"$preference"*) selected=$candidate; break ;; esac
        done
        [ -z "$selected" ] || break
      done
      if [ -z "$selected" ]; then
        for candidate in $candidates; do selected=$candidate; break; done
      fi
      if [ -n "$selected" ]; then
        TEMP_SENSOR=${selected%%|*}
        actual=${selected#*|}
        value=$(cat "$actual" 2>/dev/null || true)
        if is_int "$value"; then
          TEMP_MILLIC=$value
          TEMP_PATH=$(logical_path "$actual")
        fi
      fi
      ;;
    *) return 1 ;;
  esac
  [ -n "$TEMP_SENSOR" ] && [ -n "$TEMP_PATH" ] && is_int "$TEMP_MILLIC" || return 1
  [ "$TEMP_MILLIC" -ge -40000 ] && [ "$TEMP_MILLIC" -le 85000 ] || return 1
}

line_field() {
  wanted=$2
  for word in $1; do
    case "$word" in "$wanted"=*) printf '%s\n' "${word#*=}"; return 0 ;; esac
  done
  return 1
}

validate_process_log_binding() {
  app_id=$1
  pid=$2
  expected="$ROOT/logs/$app_id.log"
  actual_expected=$(real_path "$expected")
  require_regular "$actual_expected"
  for descriptor in 1 2; do
    target=$(readlink "$(proc_dir "$pid")/fd/$descriptor" 2>/dev/null) || return 1
    logical=$(logical_path "$target")
    [ "$logical" = "$expected" ] || return 1
  done
}

last_active_log_line() {
  prefix=$1
  found=
  for record in $ACTIVE_LOG_LIST; do
    app_id=${record%%:*}
    logfile=$(real_path "$ROOT/logs/$app_id.log")
    line=$(grep -F "$prefix" "$logfile" 2>/dev/null | tail -n 1 || true)
    [ -z "$line" ] || found=$line
  done
  [ -n "$found" ] || return 1
  single_line "$found" || return 1
  printf '%s\n' "$found"
}

active_log_match_count() {
  pattern=$1
  total=0
  for record in $ACTIVE_LOG_LIST; do
    app_id=${record%%:*}
    logfile=$(real_path "$ROOT/logs/$app_id.log")
    count=$(grep -E -c "$pattern" "$logfile" 2>/dev/null || true)
    is_uint "$count" || return 1
    total=$((total + count))
  done
  printf '%s\n' "$total"
}

slice_path_for_device_path() {
  relative=${1#"$ROOT"/}
  [ "$relative" != "$1" ] || return 1
  case "$relative" in
    bin/pluto-embedder) printf 'pluto-embedder\n' ;;
    bin/*.sh) printf '%s\n' "${relative#bin/}" ;;
    bin/*|engine/*|share/*|launcher/*|apps/*) printf '%s\n' "$relative" ;;
    *) return 1 ;;
  esac
}

emit_installed_hash() {
  logical=$1
  actual=$(real_path "$logical")
  digest=$(sha256_file "$actual") || fail "cannot hash $logical"
  slice=$(slice_path_for_device_path "$logical") || fail "cannot map installed file to release slice: $logical"
  printf 'installed.sha256=%s device_path=%s slice_path=%s\n' "$digest" "$logical" "$slice"
  INSTALLED_HASH_COUNT=$((INSTALLED_HASH_COUNT + 1))
}

emit_process_sample() {
  sample=$1
  role=$2
  app_id=$3
  pid=$4
  fields=$(proc_stat_fields "$pid") || fail "process $pid vanished or has invalid /proc/stat"
  set -- $fields
  state=$1
  utime=$2
  stime=$3
  start_ticks=$4
  rss_pages=$5
  vmrss=$(status_field_uint "$pid" VmRSS) || fail "process $pid has no valid VmRSS"
  vmhwm=$(status_field_uint "$pid" VmHWM) || fail "process $pid has no valid VmHWM"
  threads=$(status_field_uint "$pid" Threads) || fail "process $pid has no valid Threads"
  fds=$(proc_fd_count "$pid") || fail "process $pid has no readable fd table"
  printf 'sample.process index=%s role=%s app_id=%s pid=%s state=%s utime_ticks=%s stime_ticks=%s start_ticks=%s rss_pages=%s vmrss_kb=%s vmhwm_kb=%s threads=%s fds=%s\n' \
    "$sample" "$role" "$app_id" "$pid" "$state" "$utime" "$stime" \
    "$start_ticks" "$rss_pages" "$vmrss" "$vmhwm" "$threads" "$fds"
}

trace 'validate installed device profile and immutable runtime identity'
PROFILE_SCRIPT=$(real_path "$ROOT/share/device-profiles.sh")
require_regular "$PROFILE_SCRIPT"
# shellcheck disable=SC1090
. "$PROFILE_SCRIPT"
command -v pluto_profile_probe >/dev/null 2>&1 || fail 'installed profile probe is missing'
pluto_profile_probe || fail 'installed profile probe rejected the device'
for value in "${PLUTO_PROFILE_ID:-}" "${PLUTO_PROFILE_TARGET:-}" \
  "${PLUTO_PROFILE_DISPLAY_DRIVER:-}" "${PLUTO_PROFILE_FIRMWARE_BUILD:-}" \
  "${PLUTO_PROFILE_KERNEL_RELEASE:-}"; do
  is_safe_token "$value" || fail 'profile contains a malformed required field'
done
case "$PLUTO_PROFILE_ID:$PLUTO_PROFILE_TARGET" in
  rm1:linux-arm|rm2:linux-arm|move:linux-arm64) ;;
  *) fail "unsupported profile/target pair: $PLUTO_PROFILE_ID/$PLUTO_PROFILE_TARGET" ;;
esac

FIRMWARE=$(read_one_line "$(real_path /etc/version)") || fail 'firmware build receipt is malformed'
KERNEL=$("$UNAME" -r 2>/dev/null) || fail 'cannot read kernel release'
ARCH=$("$UNAME" -m 2>/dev/null) || fail 'cannot read device architecture'
[ "$FIRMWARE" = "$PLUTO_PROFILE_FIRMWARE_BUILD" ] || fail 'firmware build does not match profile'
[ "$KERNEL" = "$PLUTO_PROFILE_KERNEL_RELEASE" ] || fail 'kernel release does not match profile'
case "$PLUTO_PROFILE_TARGET:$ARCH" in
  linux-arm:armv7|linux-arm:armv7l|linux-arm64:aarch64|linux-arm64:arm64) ;;
  *) fail "architecture $ARCH does not match $PLUTO_PROFILE_TARGET" ;;
esac
BOOT_ID=$(read_one_line "$(real_path /proc/sys/kernel/random/boot_id)") || fail 'boot ID is malformed'
printf '%s\n' "$BOOT_ID" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || fail 'boot ID has an invalid shape'
MACHINE=$(cat "$(real_path /sys/devices/soc0/machine)" 2>/dev/null || true)
MODEL=$(tr '\000' ' ' < "$(real_path /proc/device-tree/model)" 2>/dev/null || true)
single_line "$MACHINE" && single_line "$MODEL" || fail 'hardware identity contains control characters'

RELEASE_REVISION=$(read_one_line "$(real_path "$ROOT/share/release-revision")") || fail 'installed release revision is missing or malformed'
printf '%s\n' "$RELEASE_REVISION" | grep -Eq '^[0-9a-f]{40}$' || fail 'installed release revision is not a full Git hash'

printf 'format=pluto-acceptance-evidence\n'
printf 'collection.started_utc=%s\n' "$(utc_now)"
printf 'identity.profile_id=%s\n' "$PLUTO_PROFILE_ID"
printf 'identity.target=%s\n' "$PLUTO_PROFILE_TARGET"
printf 'identity.display_driver=%s\n' "$PLUTO_PROFILE_DISPLAY_DRIVER"
printf 'identity.firmware_build=%s\n' "$FIRMWARE"
printf 'identity.kernel_release=%s\n' "$KERNEL"
printf 'identity.architecture=%s\n' "$ARCH"
printf 'identity.boot_id=%s\n' "$BOOT_ID"
printf 'identity.machine=%s\n' "$MACHINE"
printf 'identity.model=%s\n' "$MODEL"
printf 'release.git_revision=%s\n' "$RELEASE_REVISION"

trace 'locate and prove the common Pluto supervisor service process'
SELECTED_UNIT=
SUPERVISOR_PID=
if supervisor_for_unit xochitl.service; then
  :
elif supervisor_for_unit pluto-session-once.service; then
  :
else
  fail 'no active common Pluto supervisor under xochitl.service or pluto-session-once.service'
fi

ACTIVE_STATE=$(service_field "$SELECTED_UNIT" ActiveState) || fail 'cannot read supervisor ActiveState'
SUB_STATE=$(service_field "$SELECTED_UNIT" SubState) || fail 'cannot read supervisor SubState'
RESULT=$(service_field "$SELECTED_UNIT" Result) || fail 'cannot read supervisor Result'
EXEC_STATUS=$(service_field "$SELECTED_UNIT" ExecMainStatus) || fail 'cannot read supervisor ExecMainStatus'
NRESTARTS=$(service_field "$SELECTED_UNIT" NRestarts) || fail 'cannot read supervisor NRestarts'
ACTIVATED=$(service_field "$SELECTED_UNIT" ActiveEnterTimestamp) || fail 'cannot read supervisor activation time'
[ "$ACTIVE_STATE:$SUB_STATE:$RESULT:$EXEC_STATUS" = active:running:success:0 ] || fail 'supervisor service is not healthy'
is_uint "$NRESTARTS" && [ "$NRESTARTS" -eq 0 ] || fail 'supervisor restarted during this activation'
[ -n "$ACTIVATED" ] && single_line "$ACTIVATED" || fail 'supervisor activation timestamp is malformed'
SUPERVISOR_CMD=$(proc_cmdline "$SUPERVISOR_PID") || fail 'supervisor cmdline is unavailable'
SUPERVISOR_FIELDS=$(proc_stat_fields "$SUPERVISOR_PID") || fail 'supervisor process identity vanished'
set -- $SUPERVISOR_FIELDS
SUPERVISOR_START=$4
printf 'service.supervisor.unit=%s\n' "$SELECTED_UNIT"
printf 'service.supervisor.active_state=%s\n' "$ACTIVE_STATE"
printf 'service.supervisor.sub_state=%s\n' "$SUB_STATE"
printf 'service.supervisor.result=%s\n' "$RESULT"
printf 'service.supervisor.exec_main_status=%s\n' "$EXEC_STATUS"
printf 'service.supervisor.restarts=%s\n' "$NRESTARTS"
printf 'service.supervisor.activated=%s\n' "$ACTIVATED"
printf 'process.supervisor.pid=%s\n' "$SUPERVISOR_PID"
printf 'process.supervisor.start_ticks=%s\n' "$SUPERVISOR_START"
printf 'process.supervisor.cmdline=%s\n' "$SUPERVISOR_CMD"

XOCHITL_ACTIVE=$(service_field xochitl.service ActiveState 2>/dev/null || echo unavailable)
XOCHITL_SUB=$(service_field xochitl.service SubState 2>/dev/null || echo unavailable)
printf 'service.xochitl.active_state=%s\n' "$XOCHITL_ACTIVE"
printf 'service.xochitl.sub_state=%s\n' "$XOCHITL_SUB"
[ ! -e "$(real_path "$RUN_DIR/boot-fatal")" ] || fail 'boot-fatal receipt exists'
if [ -f "$(real_path "$ROOT/state/boot-confirmed")" ]; then
  BOOT_CONFIRMED=$(read_one_line "$(real_path "$ROOT/state/boot-confirmed")") || fail 'boot confirmation receipt is malformed'
  [ -n "$BOOT_CONFIRMED" ] && is_safe_token "$(printf '%s' "$BOOT_CONFIRMED" | tr ' ' '/')" || fail 'boot confirmation receipt contains unsafe data'
  printf 'service.boot_confirmed=%s\n' "$BOOT_CONFIRMED"
elif [ "$SELECTED_UNIT" = xochitl.service ]; then
  fail 'boot-first supervisor has no boot-confirmed receipt'
else
  printf 'service.boot_confirmed=not-required-current-boot\n'
fi
if [ "$SELECTED_UNIT" = pluto-session-once.service ]; then
  [ "$PLUTO_PROFILE_ID" = move ] || fail 'one-shot Pluto ownership is accepted only for Move'
  [ "$XOCHITL_ACTIVE" = inactive ] && [ "$XOCHITL_SUB" = dead ] || fail 'stock xochitl is not inactive during one-shot Pluto ownership'
fi

trace 'prove the foreground release/AOT embedder and completion receipts'
FOREGROUND_PID=$(read_one_line "$(real_path "$RUN_DIR/embedder.pid")") || fail 'foreground PID receipt is malformed'
is_uint "$FOREGROUND_PID" && [ "$FOREGROUND_PID" -gt 1 ] || fail 'foreground PID is invalid'
FOREGROUND_APP=$(proc_env_value "$FOREGROUND_PID" PLUTO_APP_ID=) || fail 'foreground app identity is absent'
case "$FOREGROUND_APP" in ''|*[!A-Za-z0-9._-]*) fail 'foreground app identity is unsafe' ;; esac
validate_embedder_cmdline "$FOREGROUND_PID" "$FOREGROUND_APP" || fail 'foreground process is not exact release/AOT native Pluto'
FOREGROUND_CMD=$(proc_cmdline "$FOREGROUND_PID") || fail 'foreground cmdline is unavailable'
HEALTH_LOGICAL=$(proc_arg_value "$FOREGROUND_PID" --health-file=) || fail 'foreground health path is absent or ambiguous'
READY_LOGICAL=$(proc_arg_value "$FOREGROUND_PID" --ready-file=) || fail 'foreground ready path is absent or ambiguous'
case "$HEALTH_LOGICAL:$READY_LOGICAL" in
  "$RUN_DIR"/health.*:"$RUN_DIR"/boot-ready.*) ;;
  *) fail 'foreground ready/health paths are outside the run directory' ;;
esac
HEALTH_REAL=$(real_path "$HEALTH_LOGICAL")
READY_REAL=$(real_path "$READY_LOGICAL")
[ "$(read_one_line "$READY_REAL" 2>/dev/null || true)" = ready ] || fail 'foreground ready receipt is malformed'
read_health "$HEALTH_REAL" "$FOREGROUND_PID" || fail 'foreground health receipt is malformed'
HEALTH_SEQ_START=$HEALTH_SEQ
HEALTH_MONO_START=$HEALTH_MONO
FOREGROUND_FIELDS=$(proc_stat_fields "$FOREGROUND_PID") || fail 'foreground process identity vanished'
set -- $FOREGROUND_FIELDS
FOREGROUND_START=$4
[ "$FOREGROUND_START" -ge "$SUPERVISOR_START" ] || fail 'foreground predates its supervisor activation'
validate_process_log_binding "$FOREGROUND_APP" "$FOREGROUND_PID" || fail 'foreground stdout/stderr are not bound to its exact app log'
ACTIVE_LOG_LIST="$FOREGROUND_APP:$FOREGROUND_PID"
printf 'process.foreground.pid=%s\n' "$FOREGROUND_PID"
printf 'process.foreground.app_id=%s\n' "$FOREGROUND_APP"
printf 'process.foreground.start_ticks=%s\n' "$FOREGROUND_START"
printf 'process.foreground.cmdline=%s\n' "$FOREGROUND_CMD"
printf 'health.path=%s\n' "$HEALTH_LOGICAL"
printf 'health.seq_start=%s\n' "$HEALTH_SEQ_START"
printf 'health.mono_ms_start=%s\n' "$HEALTH_MONO_START"

trace 'enumerate exact warm registry and require stopped non-foreground processes'
WARM_LIST=
WARM_REGISTRY_COUNT=0
WARM_STOPPED_COUNT=0
for pid_file in "$(real_path "$RUN_DIR/warm-apps")"/*.pid; do
  [ -f "$pid_file" ] || continue
  [ ! -L "$pid_file" ] || fail 'warm PID receipt is a symlink'
  app_id=${pid_file##*/}
  app_id=${app_id%.pid}
  case "$app_id" in ''|*[!A-Za-z0-9._-]*) fail 'warm registry app id is unsafe' ;; esac
  pid=$(read_one_line "$pid_file") || fail "warm PID receipt is malformed for $app_id"
  is_uint "$pid" && [ "$pid" -gt 1 ] || fail "warm PID is invalid for $app_id"
  validate_embedder_cmdline "$pid" "$app_id" || fail "warm process is not exact release/AOT Pluto: $app_id"
  fields=$(proc_stat_fields "$pid") || fail "warm process vanished: $app_id"
  set -- $fields
  state=$1
  start_ticks=$4
  [ "$start_ticks" -ge "$SUPERVISOR_START" ] || fail "warm process predates its supervisor activation: $app_id"
  validate_process_log_binding "$app_id" "$pid" || fail "warm stdout/stderr are not bound to its exact app log: $app_id"
  case " $ACTIVE_LOG_LIST " in *" $app_id:$pid "*) ;; *) ACTIVE_LOG_LIST="$ACTIVE_LOG_LIST $app_id:$pid" ;; esac
  WARM_REGISTRY_COUNT=$((WARM_REGISTRY_COUNT + 1))
  if [ "$pid" != "$FOREGROUND_PID" ]; then
    [ "$state" = T ] || fail "non-foreground warm process is not SIGSTOPped: $app_id state=$state"
    WARM_STOPPED_COUNT=$((WARM_STOPPED_COUNT + 1))
    WARM_LIST="$WARM_LIST $app_id:$pid"
    printf 'process.warm.app_id=%s pid=%s state=%s cmdline=%s\n' \
      "$app_id" "$pid" "$state" "$(proc_cmdline "$pid")"
  fi
done
[ "$WARM_STOPPED_COUNT" -ge 1 ] || fail 'acceptance run has no stopped warm app to measure'
printf 'warm.registry_count=%s\n' "$WARM_REGISTRY_COUNT"
printf 'warm.stopped_count=%s\n' "$WARM_STOPPED_COUNT"

trace 'hash the exhaustive immutable installed release file set'
INSTALLED_HASH_COUNT=0
for directory in bin engine share launcher apps; do
  actual_directory=$(real_path "$ROOT/$directory")
  [ -d "$actual_directory" ] && [ ! -L "$actual_directory" ] || fail "immutable release directory is missing: $ROOT/$directory"
  NONREGULAR=$(find "$actual_directory" ! -type d ! -type f 2>/dev/null | head -n 1 || true)
  [ -z "$NONREGULAR" ] || fail "immutable release tree contains a non-regular entry: $(logical_path "$NONREGULAR")"
done
IMMUTABLE_FILES=$(find \
  "$(real_path "$ROOT/bin")" \
  "$(real_path "$ROOT/engine")" \
  "$(real_path "$ROOT/share")" \
  "$(real_path "$ROOT/launcher")" \
  "$(real_path "$ROOT/apps")" \
  -type f ! -name install.json 2>/dev/null | sort) || fail 'cannot enumerate immutable installed release files'
[ -n "$IMMUTABLE_FILES" ] || fail 'immutable installed release file set is empty'
for actual in $IMMUTABLE_FILES; do
  logical=$(logical_path "$actual")
  case "$logical" in *[[:space:]]*) fail "immutable release path contains whitespace: $logical" ;; esac
  emit_installed_hash "$logical"
done

trace 'validate and separately hash generated install receipts for all standard apps'
GENERATED_HASH_COUNT=0
for app_id in dev.pluto.launcher dev.pluto.examples.counter \
  dev.pluto.examples.motion_lab dev.pluto.examples.ink_lab \
  dev.pluto.validation_lab dev.pluto.codex dev.pluto.ink; do
  app_root="$ROOT/apps/$app_id"
  [ "$app_id" = dev.pluto.launcher ] && app_root="$ROOT/launcher"
  install_real=$(real_path "$app_root/install.json")
  require_regular "$install_real"
  require_regular "$(real_path "$app_root/build-metadata.json")"
  grep -Eq '"buildMode"[[:space:]]*:[[:space:]]*"release"' "$install_real" || fail "$app_id install receipt is not release"
  grep -Eq '"engineFlavor"[[:space:]]*:[[:space:]]*"release"' "$install_real" || fail "$app_id install receipt is not release-engine AOT"
  generated_digest=$(sha256_file "$install_real") || fail "cannot hash generated install receipt for $app_id"
  printf 'generated.sha256=%s device_path=%s/install.json kind=install-receipt\n' "$generated_digest" "$app_root"
  GENERATED_HASH_COUNT=$((GENERATED_HASH_COUNT + 1))
done

CODEX_LOGICAL=
for candidate in "$ROOT/bin/codex" /home/root/bin/codex /home/root/.local/bin/codex; do
  actual=$(real_path "$candidate")
  [ -x "$actual" ] || continue
  if [ -L "$actual" ]; then
    resolved=$(readlink -f "$actual" 2>/dev/null || true)
    [ -n "$resolved" ] || continue
    actual=$resolved
  fi
  [ -f "$actual" ] || continue
  CODEX_LOGICAL=$candidate
  CODEX_DIGEST=$(sha256_file "$actual") || fail 'cannot hash resolved Codex binary'
  printf 'codex.sha256=%s device_path=%s resolved=%s\n' "$CODEX_DIGEST" "$candidate" "$(logical_path "$actual")"
  break
done
[ -n "$CODEX_LOGICAL" ] || fail 'real Codex binary is absent'
DEBUG_KERNEL_COUNT=$(find "$(real_path "$ROOT")" -type f -name kernel_blob.bin 2>/dev/null | wc -l | tr -d '[:space:]')
[ "$DEBUG_KERNEL_COUNT" = 0 ] || fail 'debug kernel exists in release runtime'
printf 'installed.hash_count=%s\n' "$INSTALLED_HASH_COUNT"
printf 'generated.hash_count=%s\n' "$GENERATED_HASH_COUNT"
printf 'release.debug_kernel_count=0\n'

trace 'capture profile-selected panel temperature before bounded sampling'
read_temperature || fail 'profile-selected panel temperature is unavailable or invalid'
TEMP_START=$TEMP_MILLIC
printf 'temperature.sensor=%s\n' "$TEMP_SENSOR"
printf 'temperature.path=%s\n' "$TEMP_PATH"
printf 'temperature.millic_start=%s\n' "$TEMP_START"

CPU_ONLINE=$(cat "$(real_path /sys/devices/system/cpu/online)" 2>/dev/null || echo unknown)
CPU_PRESENT=$(cat "$(real_path /sys/devices/system/cpu/present)" 2>/dev/null || echo unknown)
CLK_TCK=100
CLK_SOURCE=linux-user-hz
if command -v getconf >/dev/null 2>&1; then
  candidate=$(getconf CLK_TCK 2>/dev/null || true)
  if is_uint "$candidate" && [ "$candidate" -gt 0 ]; then
    CLK_TCK=$candidate
    CLK_SOURCE=getconf
  fi
fi
printf 'sampling.count=%s\n' "$SAMPLE_COUNT"
printf 'sampling.interval_seconds=%s\n' "$SAMPLE_INTERVAL"
printf 'sampling.requested_elapsed_seconds=%s\n' "$(((SAMPLE_COUNT - 1) * SAMPLE_INTERVAL))"
printf 'sampling.clk_tck=%s\n' "$CLK_TCK"
printf 'sampling.clk_tck_source=%s\n' "$CLK_SOURCE"
printf 'cpu.online=%s\n' "$CPU_ONLINE"
printf 'cpu.present=%s\n' "$CPU_PRESENT"

trace "collect $SAMPLE_COUNT CPU/RSS/HWM/thread/fd samples at ${SAMPLE_INTERVAL}s cadence"
SAMPLE_INDEX=0
SAMPLE_UPTIME_START=
SAMPLE_UPTIME_END=
WALL_START=$("$DATE" +%s)
while [ "$SAMPLE_INDEX" -lt "$SAMPLE_COUNT" ]; do
  PROC_STAT=$(head -n 1 "$(real_path /proc/stat)" 2>/dev/null) || fail 'cannot read aggregate CPU ticks'
  set -- $PROC_STAT
  [ "${1:-}" = cpu ] || fail 'aggregate CPU record is malformed'
  shift
  CPU_TOTAL=0
  for ticks in "$@"; do
    is_uint "$ticks" || fail 'aggregate CPU tick is malformed'
    CPU_TOTAL=$((CPU_TOTAL + ticks))
  done
  UPTIME=$(awk '{print $1}' "$(real_path /proc/uptime)" 2>/dev/null) || fail 'cannot read uptime'
  LOADAVG=$(cat "$(real_path /proc/loadavg)" 2>/dev/null) || fail 'cannot read load average'
  MEM_AVAILABLE=$(awk '$1 == "MemAvailable:" {print $2}' "$(real_path /proc/meminfo)" 2>/dev/null) || fail 'cannot read available memory'
  is_uint "$MEM_AVAILABLE" || fail 'available memory is malformed'
  single_line "$UPTIME" && single_line "$LOADAVG" || fail 'sampling clock/load contains control characters'
  [ -n "$SAMPLE_UPTIME_START" ] || SAMPLE_UPTIME_START=$UPTIME
  SAMPLE_UPTIME_END=$UPTIME
  printf 'sample.index=%s utc=%s uptime_seconds=%s cpu_total_ticks=%s mem_available_kb=%s loadavg=%s\n' \
    "$SAMPLE_INDEX" "$(utc_now)" "$UPTIME" "$CPU_TOTAL" "$MEM_AVAILABLE" "$LOADAVG"
  emit_process_sample "$SAMPLE_INDEX" supervisor none "$SUPERVISOR_PID"
  emit_process_sample "$SAMPLE_INDEX" foreground "$FOREGROUND_APP" "$FOREGROUND_PID"
  for record in $WARM_LIST; do
    app_id=${record%%:*}
    pid=${record#*:}
    fields=$(proc_stat_fields "$pid") || fail "warm process vanished during sampling: $app_id"
    set -- $fields
    [ "$1" = T ] || fail "warm process resumed during sampling: $app_id state=$1"
    emit_process_sample "$SAMPLE_INDEX" warm-stopped "$app_id" "$pid"
  done
  read_health "$HEALTH_REAL" "$FOREGROUND_PID" || fail 'health receipt became malformed during sampling'
  [ "$HEALTH_SEQ" -ge "$HEALTH_SEQ_START" ] && [ "$HEALTH_MONO" -ge "$HEALTH_MONO_START" ] || fail 'health receipt regressed during sampling'
  printf 'health.sample index=%s seq=%s mono_ms=%s\n' "$SAMPLE_INDEX" "$HEALTH_SEQ" "$HEALTH_MONO"
  SAMPLE_INDEX=$((SAMPLE_INDEX + 1))
  [ "$SAMPLE_INDEX" -ge "$SAMPLE_COUNT" ] || "$SLEEP" "$SAMPLE_INTERVAL"
done
WALL_END=$("$DATE" +%s)
printf 'sampling.uptime_start_seconds=%s\n' "$SAMPLE_UPTIME_START"
printf 'sampling.uptime_end_seconds=%s\n' "$SAMPLE_UPTIME_END"
printf 'sampling.wall_elapsed_seconds=%s\n' "$((WALL_END - WALL_START))"

read_health "$HEALTH_REAL" "$FOREGROUND_PID" || fail 'final health receipt is malformed'
HEALTH_SEQ_END=$HEALTH_SEQ
HEALTH_MONO_END=$HEALTH_MONO
[ "$HEALTH_SEQ_END" -gt "$HEALTH_SEQ_START" ] && [ "$HEALTH_MONO_END" -gt "$HEALTH_MONO_START" ] || fail 'completion-backed health did not progress during sampling'
printf 'health.seq_end=%s\n' "$HEALTH_SEQ_END"
printf 'health.mono_ms_end=%s\n' "$HEALTH_MONO_END"
printf 'health.seq_delta=%s\n' "$((HEALTH_SEQ_END - HEALTH_SEQ_START))"

read_temperature || fail 'final profile-selected panel temperature is unavailable or invalid'
printf 'temperature.millic_end=%s\n' "$TEMP_MILLIC"
printf 'temperature.delta_millic=%s\n' "$((TEMP_MILLIC - TEMP_START))"

trace 'collect and validate backend-specific presenter timing/fault telemetry'
case "$PLUTO_PROFILE_ID" in
  rm1)
    TELEMETRY=$(last_active_log_line 'mxcfb: damage telemetry ') || fail 'RM1 damage/update telemetry receipt is absent from an activation-bound process log'
    for field in updates requested_px driven_px amplified full regional_full legacy_full_px_avoided max_amp_milli; do
      value=$(line_field "$TELEMETRY" "$field") || fail "RM1 telemetry field is missing: $field"
      is_uint "$value" || fail "RM1 telemetry field is malformed: $field"
      eval "RM1_$field=\$value"
    done
    [ "$RM1_updates" -gt 0 ] && [ "$RM1_requested_px" -gt 0 ] && [ "$RM1_driven_px" -gt 0 ] || fail 'RM1 telemetry contains no accepted update work'
    REJECTIONS=$(active_log_match_count '^mxcfb: .*rejected') || fail 'cannot count RM1 rejections'
    printf 'telemetry.rm1.raw=%s\n' "$TELEMETRY"
    printf 'telemetry.rm1.rejection_count=%s\n' "$REJECTIONS"
    ;;
  rm2)
    TELEMETRY=$(last_active_log_line 'lcdif_tcon: telemetry ') || fail 'RM2 timing/fault telemetry receipt is absent from an activation-bound process log'
    for field in jobs phases encode_p50_us encode_p95_us encode_p99_us encode_max_us missed_deadlines underflows safe_holds hardware_faults; do
      value=$(line_field "$TELEMETRY" "$field") || fail "RM2 telemetry field is missing: $field"
      is_uint "$value" || fail "RM2 telemetry field is malformed: $field"
      eval "RM2_$field=\$value"
    done
    [ "$RM2_jobs" -gt 0 ] && [ "$RM2_phases" -gt 0 ] && [ "$RM2_safe_holds" -gt 0 ] || fail 'RM2 telemetry contains no completed phase/safe-hold work'
    [ "$RM2_missed_deadlines" -eq 0 ] && [ "$RM2_underflows" -eq 0 ] && [ "$RM2_hardware_faults" -eq 0 ] || fail 'RM2 timing/fault telemetry is not clean'
    printf 'telemetry.rm2.raw=%s\n' "$TELEMETRY"
    ;;
  move)
    TELEMETRY=$(last_active_log_line 'swtcon stats: ') || fail 'Move presenter timing/fault telemetry receipt is absent from an activation-bound process log'
    for field in builds build_p50_us build_p95_us build_max_us completions dropped color_fault hold_rescans neutral_frames; do
      value=$(line_field "$TELEMETRY" "$field") || fail "Move telemetry field is missing: $field"
      is_uint "$value" || fail "Move telemetry field is malformed: $field"
      eval "MOVE_$field=\$value"
    done
    [ "$MOVE_builds" -gt 0 ] && [ "$MOVE_completions" -gt 0 ] || fail 'Move telemetry contains no completed presenter work'
    [ "$MOVE_dropped" -eq 0 ] && [ "$MOVE_color_fault" -eq 0 ] || fail 'Move presenter telemetry is not clean'
    printf 'telemetry.move.raw=%s\n' "$TELEMETRY"
    ;;
esac
PRESENTER_FATAL_COUNT=$(active_log_match_count 'device lost|health publication failed|presenter completion exceeded|fail-closed:|scan loop stopped:') || fail 'cannot count activation-bound presenter faults'
printf 'telemetry.presenter_fatal_count=%s\n' "$PRESENTER_FATAL_COUNT"
[ "$PRESENTER_FATAL_COUNT" -eq 0 ] || fail 'activation-bound presenter log contains a fatal condition'

trace 'capture activation-scoped service and kernel fault journals'
SERVICE_JOURNAL=$("$JOURNALCTL" -u "$SELECTED_UNIT" --since "$ACTIVATED" -n 500 --no-pager -o short-iso 2>/dev/null) || fail 'cannot read supervisor journal since activation'
KERNEL_JOURNAL=$("$JOURNALCTL" -k --since "$ACTIVATED" -n 500 --no-pager -o short-iso 2>/dev/null) || fail 'cannot read kernel journal since activation'
SERVICE_JOURNAL_DIGEST=$(sha256_text "$SERVICE_JOURNAL") || fail 'cannot hash supervisor journal'
KERNEL_JOURNAL_DIGEST=$(sha256_text "$KERNEL_JOURNAL") || fail 'cannot hash kernel journal'
SERVICE_JOURNAL_LINES=$(printf '%s\n' "$SERVICE_JOURNAL" | awk 'NF {count++} END {print count+0}')
KERNEL_JOURNAL_LINES=$(printf '%s\n' "$KERNEL_JOURNAL" | awk 'NF {count++} END {print count+0}')
SERVICE_FAULT_LINES=$(printf '%s\n' "$SERVICE_JOURNAL" | grep -Ei 'boot attempt failed closed|renderer health.*(invalid|stale|deadline)|device lost|segmentation fault|core dumped|failed with result|main process exited' || true)
KERNEL_FAULT_LINES=$(printf '%s\n' "$KERNEL_JOURNAL" | grep -Ei 'BUG:|Oops:|kernel panic|watchdog.*lockup|segfault|underflow|lcdif.*(fail|error)|epdc.*(fail|error)|drm.*(fail|error)' || true)
SERVICE_FAULT_COUNT=$(printf '%s\n' "$SERVICE_FAULT_LINES" | awk 'NF {count++} END {print count+0}')
KERNEL_FAULT_COUNT=$(printf '%s\n' "$KERNEL_FAULT_LINES" | awk 'NF {count++} END {print count+0}')
printf 'journal.service.sha256=%s\n' "$SERVICE_JOURNAL_DIGEST"
printf 'journal.service.lines=%s\n' "$SERVICE_JOURNAL_LINES"
printf 'journal.service.fault_count=%s\n' "$SERVICE_FAULT_COUNT"
printf 'journal.kernel.sha256=%s\n' "$KERNEL_JOURNAL_DIGEST"
printf 'journal.kernel.lines=%s\n' "$KERNEL_JOURNAL_LINES"
printf 'journal.kernel.fault_count=%s\n' "$KERNEL_FAULT_COUNT"
if [ "$SERVICE_FAULT_COUNT" -ne 0 ]; then
  printf '%s\n' "$SERVICE_FAULT_LINES" | while IFS= read -r line; do printf 'journal.service.fault=%s\n' "$line"; done
  fail 'supervisor journal contains an activation-scoped fault'
fi
if [ "$KERNEL_FAULT_COUNT" -ne 0 ]; then
  printf '%s\n' "$KERNEL_FAULT_LINES" | while IFS= read -r line; do printf 'journal.kernel.fault=%s\n' "$line"; done
  fail 'kernel journal contains an activation-scoped display/system fault'
fi

FINAL_SUPERVISOR_FIELDS=$(proc_stat_fields "$SUPERVISOR_PID") || fail 'supervisor vanished before final identity check'
set -- $FINAL_SUPERVISOR_FIELDS
[ "$4" = "$SUPERVISOR_START" ] || fail 'supervisor PID was reused during collection'
FINAL_FOREGROUND_FIELDS=$(proc_stat_fields "$FOREGROUND_PID") || fail 'foreground vanished before final identity check'
set -- $FINAL_FOREGROUND_FIELDS
[ "$4" = "$FOREGROUND_START" ] || fail 'foreground PID was reused during collection'
[ "$(read_one_line "$(real_path "$RUN_DIR/embedder.pid")" 2>/dev/null || true)" = "$FOREGROUND_PID" ] || fail 'foreground ownership changed during collection'

printf 'collection.completed_utc=%s\n' "$(utc_now)"
printf 'collection.status=PASS\n'
trace 'PASS exact-device acceptance evidence is complete'
