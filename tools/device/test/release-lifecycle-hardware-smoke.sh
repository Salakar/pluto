#!/usr/bin/env bash
# Exact-device suspend/resume and foreground-crash acceptance for a deployed
# release. This is intentionally separate from the visual app smoke so a final
# camera run can happen after all destructive recovery exercises.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OFFICIAL_STAGE_HOOK="$ROOT/tools/setup/camera/capture-acceptance-stage.sh"
OFFICIAL_CAMERA_CAPTURE="$ROOT/tools/setup/camera/capture.sh"
ACCEPTANCE_IDENTITY="$ROOT/tools/device/diagnostics/acceptance_identity.py"
DEVICE="${1:-root@10.11.99.1}"
CLI="${PLUTO_CLI:-pluto}"
SSH_TARGET="${PLUTO_ACCEPTANCE_SSH_TARGET:-$DEVICE}"
SSH_PORT="${PLUTO_ACCEPTANCE_SSH_PORT:-}"
SSH_BIND_ADDRESS="${PLUTO_ACCEPTANCE_SSH_BIND_ADDRESS:-}"
STAGE_HOOK="${PLUTO_ACCEPTANCE_STAGE_HOOK:-}"
STAGE_DELAY="${PLUTO_ACCEPTANCE_STAGE_DELAY:-0}"
CAMERA_DIR="${PLUTO_CAMERA_ACCEPTANCE_DIR:-}"
CAMERA_RIG="${PLUTO_CAMERA_RIG:-}"
SCREENSHOT_DIR="${PLUTO_LIFECYCLE_SCREENSHOT_DIR:-}"
CYCLES="${PLUTO_LIFECYCLE_CYCLES:-20}"
WAKE_SECONDS="${PLUTO_LIFECYCLE_WAKE_SECONDS:-18}"
DOWN_TIMEOUT="${PLUTO_LIFECYCLE_DOWN_TIMEOUT:-45}"
UP_TIMEOUT="${PLUTO_LIFECYCLE_UP_TIMEOUT:-120}"
CRASH_TEST="${PLUTO_LIFECYCLE_CRASH_TEST:-1}"
CRASH_SETTLE_SECONDS="${PLUTO_LIFECYCLE_CRASH_SETTLE_SECONDS:-2}"
EXPECTED_REVISION="${PLUTO_ACCEPTANCE_RELEASE_REVISION:-}"
EXPECTED_PROFILE="${PLUTO_ACCEPTANCE_PROFILE_ID:-}"
EXPECTED_APP_ID=dev.pluto.ink
LAUNCHER_APP_ID=dev.pluto.launcher
ALLOW_TEST_HOOKS="${PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS:-0}"
SSH_OPTIONS=(
  -o BatchMode=yes
  -o ConnectTimeout=3
  -o ServerAliveInterval=2
  -o ServerAliveCountMax=1
)

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_nonnegative_decimal() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

is_positive_integer "$CYCLES" && ((CYCLES <= 100)) || {
  echo "release lifecycle smoke: PLUTO_LIFECYCLE_CYCLES must be in [1,100]" >&2
  exit 64
}
is_positive_integer "$WAKE_SECONDS" && ((WAKE_SECONDS >= 12 && WAKE_SECONDS <= 120)) || {
  echo "release lifecycle smoke: wake seconds must be in [12,120]" >&2
  exit 64
}
is_positive_integer "$DOWN_TIMEOUT" && ((DOWN_TIMEOUT <= 300)) || {
  echo "release lifecycle smoke: invalid down timeout" >&2
  exit 64
}
is_positive_integer "$UP_TIMEOUT" && ((UP_TIMEOUT <= 600)) || {
  echo "release lifecycle smoke: invalid up timeout" >&2
  exit 64
}
is_nonnegative_decimal "$STAGE_DELAY" || {
  echo "release lifecycle smoke: invalid stage delay: $STAGE_DELAY" >&2
  exit 64
}
is_nonnegative_decimal "$CRASH_SETTLE_SECONDS" || {
  echo "release lifecycle smoke: invalid crash settle delay: $CRASH_SETTLE_SECONDS" >&2
  exit 64
}
[[ "$CRASH_TEST" == 0 || "$CRASH_TEST" == 1 ]] || {
  echo "release lifecycle smoke: crash test must be 0 or 1" >&2
  exit 64
}
[[ "$ALLOW_TEST_HOOKS" == 0 || "$ALLOW_TEST_HOOKS" == 1 ]] || {
  echo "release lifecycle smoke: PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS must be 0 or 1" >&2
  exit 64
}
identity_args=(
  endpoint
  --device "$DEVICE"
  --ssh-target "$SSH_TARGET"
  --ssh-port "$SSH_PORT"
)
if [[ "$ALLOW_TEST_HOOKS" == 1 ]]; then
  identity_args+=(--allow-divergence)
fi
identity_rows="$(python3 "$ACCEPTANCE_IDENTITY" "${identity_args[@]}")" || {
  echo "release lifecycle smoke: DEVICE/SSH identity is invalid" >&2
  exit 64
}
[[ "$(printf '%s\n' "$identity_rows" | wc -l | tr -d '[:space:]')" == 4 ]] || {
  echo "release lifecycle smoke: DEVICE/SSH identity helper returned invalid output" >&2
  exit 64
}
CANONICAL_ENDPOINT="$(printf '%s\n' "$identity_rows" | awk -F '\t' '$1 == "canonical_endpoint" {print $2}')"
SSH_TARGET="$(printf '%s\n' "$identity_rows" | awk -F '\t' '$1 == "ssh_invocation_target" {print $2}')"
SSH_PORT="$(printf '%s\n' "$identity_rows" | awk -F '\t' '$1 == "ssh_port" {print $2}')"
ENDPOINT_DIVERGENT="$(printf '%s\n' "$identity_rows" | awk -F '\t' '$1 == "divergent" {print $2}')"
[[ -n "$CANONICAL_ENDPOINT" && -n "$SSH_TARGET" &&
  "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ &&
  ("$ENDPOINT_DIVERGENT" == 0 || "$ENDPOINT_DIVERGENT" == 1) ]] || {
  echo "release lifecycle smoke: DEVICE/SSH identity helper returned incomplete output" >&2
  exit 64
}
if [[ "$ALLOW_TEST_HOOKS" == 1 ]]; then
  echo "release lifecycle smoke: TEST_EVIDENCE test_seam=1 endpoint=$CANONICAL_ENDPOINT endpoint_divergent=$ENDPOINT_DIVERGENT"
fi
[[ "$EXPECTED_REVISION" =~ ^[0-9a-f]{40}$ ]] || {
  echo "release lifecycle smoke: PLUTO_ACCEPTANCE_RELEASE_REVISION must be the exact 40-character release revision" >&2
  exit 64
}
case "$EXPECTED_PROFILE" in
  rm1 | rm2 | move) ;;
  *)
    echo "release lifecycle smoke: PLUTO_ACCEPTANCE_PROFILE_ID must be rm1, rm2, or move" >&2
    exit 64
    ;;
esac
[[ -z "$STAGE_HOOK" || -x "$STAGE_HOOK" ]] || {
  echo "release lifecycle smoke: stage hook is not executable: $STAGE_HOOK" >&2
  exit 64
}
if [[ -n "$STAGE_HOOK" && "$ALLOW_TEST_HOOKS" != 1 &&
  ! "$STAGE_HOOK" -ef "$OFFICIAL_STAGE_HOOK" ]]; then
  echo "release lifecycle smoke: camera evidence requires the repository stage hook" >&2
  exit 64
fi
if [[ -n "$STAGE_HOOK" ]]; then
  [[ "$CAMERA_RIG" =~ ^[1-9][0-9]*$ && -n "$CAMERA_DIR" ]] || {
    echo "release lifecycle smoke: camera evidence requires a rig and directory" >&2
    exit 64
  }
  [[ ! -e "$CAMERA_DIR" && ! -L "$CAMERA_DIR" ]] || {
    echo "release lifecycle smoke: camera evidence directory must be fresh: $CAMERA_DIR" >&2
    exit 64
  }
  if [[ "$ALLOW_TEST_HOOKS" != 1 ]]; then
    python3 "$ACCEPTANCE_IDENTITY" camera-profile \
      --config "${PLUTO_CAMERA_CONFIG:-$ROOT/.pluto-devices.json}" \
      --device "$CAMERA_RIG" --expected-profile "$EXPECTED_PROFILE" \
      >/dev/null || {
      echo "release lifecycle smoke: selected camera rig is not bound to $EXPECTED_PROFILE" >&2
      exit 64
    }
  fi
fi
if [[ -n "$STAGE_HOOK" && "$ALLOW_TEST_HOOKS" != 1 &&
  -n "${PLUTO_CAMERA_CAPTURE:-}" &&
  ! "$PLUTO_CAMERA_CAPTURE" -ef "$OFFICIAL_CAMERA_CAPTURE" ]]; then
  echo "release lifecycle smoke: camera evidence forbids a substituted capture command" >&2
  exit 64
fi
SSH_OPTIONS+=(-p "$SSH_PORT")
if [[ -n "$SSH_BIND_ADDRESS" ]]; then
  [[ "$SSH_BIND_ADDRESS" =~ ^[0-9A-Fa-f:.]+$ ]] || {
    echo "release lifecycle smoke: invalid SSH bind address: $SSH_BIND_ADDRESS" >&2
    exit 64
  }
  SSH_OPTIONS+=(-b "$SSH_BIND_ADDRESS")
fi

REMOVE_SCREENSHOT_DIR=0
if [[ -z "$SCREENSHOT_DIR" ]]; then
  SCREENSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pluto-lifecycle-screenshots.XXXXXX")"
  REMOVE_SCREENSHOT_DIR=1
else
  [[ ! -e "$SCREENSHOT_DIR" && ! -L "$SCREENSHOT_DIR" ]] || {
    echo "release lifecycle smoke: screenshot evidence directory must be fresh: $SCREENSHOT_DIR" >&2
    exit 64
  }
  mkdir -p "$SCREENSHOT_DIR"
fi
cleanup_screenshots() {
  if [[ "$REMOVE_SCREENSHOT_DIR" == 1 ]]; then
    rm -rf "$SCREENSHOT_DIR"
  fi
}
trap cleanup_screenshots EXIT

remote() {
  ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" "$1"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

lifecycle_screenshot() {
  local label="$1"
  local output="$SCREENSHOT_DIR/$label.png"
  [[ ! -e "$output" && ! -L "$output" ]] || return 1
  "$CLI" screenshot --device "$DEVICE" --app "$EXPECTED_APP_ID" \
    --surface post-dither -o "$output"
  [[ -s "$output" && ! -L "$output" ]] || return 1
  sha256_file "$output"
}

central_pixel_difference() {
  local before="$1"
  local after="$2"
  local value
  command -v ffmpeg >/dev/null 2>&1 || return 1
  value="$(ffmpeg -v error -nostdin -i "$before" -i "$after" \
    -filter_complex \
    '[0:v]crop=iw*0.5:ih*0.3:iw*0.25:ih*0.36[a];[1:v]crop=iw*0.5:ih*0.3:iw*0.25:ih*0.36[b];[a][b]blend=all_mode=difference,format=gray,signalstats,metadata=print:file=-' \
    -frames:v 1 -f null - 2>/dev/null |
    sed -n 's/^lavfi\.signalstats\.YAVG=//p')" || return 1
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  awk -v value="$value" 'BEGIN { exit !(value >= 0.05) }' || return 1
  printf '%s\n' "$value"
}

stage() {
  local label="$1"
  if [[ -n "$STAGE_HOOK" ]]; then
    "$STAGE_HOOK" "$label"
  fi
  sleep "$STAGE_DELAY"
}

READY_PROBE='set -eu
proc_start_ticks() {
  sed "s/^.*) //" "/proc/$1/stat" | cut -d " " -f 20
}
. /home/root/pluto/share/device-profiles.sh
pluto_profile_probe
case "$PLUTO_PROFILE_ID" in rm1|rm2|move) ;; *) exit 80 ;; esac
release_revision=$(cat /home/root/pluto/share/release-revision 2>/dev/null || true)
[ "${#release_revision}" -eq 40 ] || exit 80
case "$release_revision" in
  *[!0-9a-f]*) exit 80 ;;
esac
matched=0
selected_unit=""
supervisor_pid=""
for unit in xochitl.service pluto-session-once.service; do
  systemctl is-active --quiet "$unit" 2>/dev/null || continue
  pid=$(systemctl show "$unit" -p MainPID --value 2>/dev/null || true)
  case "$pid" in ""|*[!0-9]*|0|1) continue ;; esac
  kill -0 "$pid" 2>/dev/null || continue
  cmd=$(tr "\000" " " < "/proc/$pid/cmdline")
  case "$cmd" in
    *"/home/root/pluto/bin/pluto-session.sh start"*)
      matched=$((matched + 1))
      selected_unit=$unit
      supervisor_pid=$pid
      ;;
  esac
done
[ "$matched" -eq 1 ] || exit 81
if [ "$selected_unit" = pluto-session-once.service ]; then
  ! systemctl is-active --quiet xochitl.service 2>/dev/null || exit 82
fi
supervisor_start_ticks=$(proc_start_ticks "$supervisor_pid")
case "$supervisor_start_ticks" in ""|*[!0-9]*) exit 82 ;; esac
boot_id=$(cat /proc/sys/kernel/random/boot_id)
foreground_pid=$(cat /run/pluto/embedder.pid 2>/dev/null || true)
case "$foreground_pid" in ""|*[!0-9]*) exit 83 ;; esac
kill -0 "$foreground_pid" 2>/dev/null || exit 84
foreground_start_ticks=$(proc_start_ticks "$foreground_pid")
case "$foreground_start_ticks" in ""|*[!0-9]*) exit 84 ;; esac
foreground_cmd=$(tr "\000" " " < "/proc/$foreground_pid/cmdline")
case "$foreground_cmd" in
  *--release*--presenter=native*--aot-elf=*) ;;
  *) exit 85 ;;
esac
app_id=$(tr "\000" "\n" < "/proc/$foreground_pid/environ" |
  sed -n "s/^PLUTO_APP_ID=//p" | sed -n "1p")
case "$app_id" in ""|*[!A-Za-z0-9._-]*) exit 86 ;; esac
ready_file=""
health_file=""
for arg in $(tr "\000" "\n" < "/proc/$foreground_pid/cmdline"); do
  case "$arg" in
    --ready-file=*) ready_file=${arg#*=} ;;
    --health-file=*) health_file=${arg#*=} ;;
  esac
done
case "$ready_file" in /run/pluto/boot-ready.*) ;; *) exit 87 ;; esac
case "$health_file" in /run/pluto/health.*) ;; *) exit 87 ;; esac
[ "${ready_file#/run/pluto/boot-ready.}" = \
  "${health_file#/run/pluto/health.}" ] || exit 87
[ "$(cat "$ready_file" 2>/dev/null || true)" = ready ] || exit 87
set -- $(cat "$health_file" 2>/dev/null || true)
[ "$#" -eq 3 ] && [ "$1" = "pid=$foreground_pid" ] || exit 88
health_seq=${2#seq=}
health_mono=${3#mono_ms=}
case "$health_seq:$health_mono" in
  "":*|*:""|*[!0-9:]*) exit 89 ;;
esac
wake_count=$(journalctl -u "$selected_unit" -b -o cat --no-pager 2>/dev/null |
  grep -c "suspend target completed after wake" || true)
case "$wake_count" in ""|*[!0-9]*) exit 90 ;; esac
warm_ink_pid=none
warm_ink_start_ticks=none
warm_ink_state=none
warm_ink_ready_file=none
warm_ink_health_file=none
warm_file=/run/pluto/warm-apps/dev.pluto.ink.pid
if [ -e "$warm_file" ]; then
  warm_ink_pid=$(cat "$warm_file" 2>/dev/null || true)
  case "$warm_ink_pid" in ""|*[!0-9]*) exit 91 ;; esac
  kill -0 "$warm_ink_pid" 2>/dev/null || exit 91
  warm_cmd=$(tr "\000" " " < "/proc/$warm_ink_pid/cmdline")
  case "$warm_cmd" in *--release*) ;; *) exit 91 ;; esac
  case "$warm_cmd" in
    *--bundle=/home/root/pluto/apps/dev.pluto.ink/bundle*) ;; *) exit 91 ;;
  esac
  case "$warm_cmd" in *--presenter=native*) ;; *) exit 91 ;; esac
  case "$warm_cmd" in
    *--aot-elf=/home/root/pluto/apps/dev.pluto.ink/bundle/lib/app.so*) ;;
    *) exit 91 ;;
  esac
  warm_app_id=$(tr "\000" "\n" < "/proc/$warm_ink_pid/environ" |
    sed -n "s/^PLUTO_APP_ID=//p" | sed -n "1p")
  [ "$warm_app_id" = dev.pluto.ink ] || exit 91
  warm_ink_start_ticks=$(proc_start_ticks "$warm_ink_pid")
  case "$warm_ink_start_ticks" in ""|*[!0-9]*) exit 91 ;; esac
  warm_ink_state=$(sed "s/^.*) //" "/proc/$warm_ink_pid/stat" |
    cut -d " " -f 1)
  case "$warm_ink_state" in R|S|D|T|t) ;; *) exit 91 ;; esac
  for arg in $(tr "\000" "\n" < "/proc/$warm_ink_pid/cmdline"); do
    case "$arg" in
      --ready-file=*) warm_ink_ready_file=${arg#*=} ;;
      --health-file=*) warm_ink_health_file=${arg#*=} ;;
    esac
  done
  case "$warm_ink_ready_file:$warm_ink_health_file" in
    /run/pluto/boot-ready.*:/run/pluto/health.*) ;;
    *) exit 91 ;;
  esac
  [ "${warm_ink_ready_file#/run/pluto/boot-ready.}" = \
    "${warm_ink_health_file#/run/pluto/health.}" ] || exit 91
fi
printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
  "$selected_unit" "$supervisor_pid" "$supervisor_start_ticks" "$boot_id" \
  "$foreground_pid" "$foreground_start_ticks" "$app_id" "$health_seq" \
  "$health_mono" "$wake_count" "$release_revision" "$PLUTO_PROFILE_ID" \
  "$ready_file" "$health_file" "$warm_ink_pid" "$warm_ink_start_ticks" \
  "$warm_ink_state" "$warm_ink_ready_file" "$warm_ink_health_file"'

parse_state() {
  local state="$1"
  IFS='|' read -r STATE_UNIT STATE_SUPERVISOR_PID \
    STATE_SUPERVISOR_START_TICKS STATE_BOOT_ID STATE_FOREGROUND_PID \
    STATE_FOREGROUND_START_TICKS STATE_APP_ID STATE_HEALTH_SEQ \
    STATE_HEALTH_MONO STATE_WAKE_COUNT STATE_RELEASE_REVISION \
    STATE_PROFILE_ID STATE_READY_FILE STATE_HEALTH_FILE STATE_WARM_INK_PID \
    STATE_WARM_INK_START_TICKS STATE_WARM_INK_STATE \
    STATE_WARM_INK_READY_FILE STATE_WARM_INK_HEALTH_FILE <<< "$state"
  [[ -n "$STATE_UNIT" && -n "$STATE_SUPERVISOR_PID" &&
    -n "$STATE_SUPERVISOR_START_TICKS" && -n "$STATE_BOOT_ID" &&
    -n "$STATE_FOREGROUND_PID" && -n "$STATE_FOREGROUND_START_TICKS" &&
    -n "$STATE_APP_ID" && -n "$STATE_HEALTH_SEQ" &&
    -n "$STATE_HEALTH_MONO" && -n "$STATE_WAKE_COUNT" &&
    -n "$STATE_RELEASE_REVISION" && -n "$STATE_PROFILE_ID" &&
    -n "$STATE_READY_FILE" && -n "$STATE_HEALTH_FILE" &&
    -n "$STATE_WARM_INK_PID" && -n "$STATE_WARM_INK_START_TICKS" &&
    -n "$STATE_WARM_INK_STATE" && -n "$STATE_WARM_INK_READY_FILE" &&
    -n "$STATE_WARM_INK_HEALTH_FILE" ]] || return 1
}

wait_ready() {
  local timeout="$1"
  local elapsed=0
  local state=""
  while ((elapsed < timeout)); do
    if state="$(remote "$READY_PROBE" 2>/dev/null)"; then
      printf '%s\n' "$state"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

wait_matching() {
  local timeout="$1"
  local expected_pid="$2"
  local expected_app="$3"
  local min_seq="$4"
  local min_mono="$5"
  local expected_wake="$6"
  local expected_warm_pid="$7"
  local expected_warm_state="$8"
  local elapsed=0
  local state=""
  while ((elapsed < timeout)); do
    if state="$(remote "$READY_PROBE" 2>/dev/null)" && parse_state "$state"; then
      if [[ "$STATE_RELEASE_REVISION" == "$EXPECTED_REVISION" &&
        "$STATE_PROFILE_ID" == "$EXPECTED_PROFILE" ]] &&
        { [[ "$expected_pid" == any ]] ||
          [[ "$STATE_FOREGROUND_PID" == "$expected_pid" ]]; } &&
        { [[ "$expected_app" == any ]] ||
          [[ "$STATE_APP_ID" == "$expected_app" ]]; } &&
        { [[ "$min_seq" == any ]] ||
          ((STATE_HEALTH_SEQ > min_seq)); } &&
        { [[ "$min_mono" == any ]] ||
          ((STATE_HEALTH_MONO > min_mono)); } &&
        { [[ "$expected_wake" == any ]] ||
          ((STATE_WAKE_COUNT == expected_wake)); } &&
        { [[ "$expected_warm_pid" == any ]] ||
          [[ "$STATE_WARM_INK_PID" == "$expected_warm_pid" ]]; } &&
        { [[ "$expected_warm_state" == any ]] ||
          [[ "$STATE_WARM_INK_STATE" == "$expected_warm_state" ]]; }; then
        printf '%s\n' "$state"
        return 0
      fi
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

wait_down() {
  local elapsed=0
  while ((elapsed < DOWN_TIMEOUT)); do
    if ! remote 'true' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

"$CLI" run --release --device "$DEVICE" "$EXPECTED_APP_ID"
initial="$(wait_matching "$UP_TIMEOUT" any "$EXPECTED_APP_ID" any any any any any)" || {
  echo "release lifecycle smoke: no healthy release supervisor on $DEVICE" >&2
  exit 74
}
parse_state "$initial"
[[ "$STATE_RELEASE_REVISION" == "$EXPECTED_REVISION" ]] || {
  echo "release lifecycle smoke: installed release revision is $STATE_RELEASE_REVISION, expected $EXPECTED_REVISION" >&2
  exit 74
}
[[ "$STATE_PROFILE_ID" == "$EXPECTED_PROFILE" ]] || {
  echo "release lifecycle smoke: active profile is $STATE_PROFILE_ID, expected $EXPECTED_PROFILE" >&2
  exit 74
}
[[ "$STATE_APP_ID" == "$EXPECTED_APP_ID" ]] || {
  echo "release lifecycle smoke: expected Ink foreground, found $STATE_APP_ID" >&2
  exit 74
}

stroke_pid="$STATE_FOREGROUND_PID"
stroke_start_ticks="$STATE_FOREGROUND_START_TICKS"
stroke_ready_file="$STATE_READY_FILE"
stroke_health_file="$STATE_HEALTH_FILE"
stroke_seq="$STATE_HEALTH_SEQ"
stroke_mono="$STATE_HEALTH_MONO"
remote "set -eu
[ \"\$(cat /run/pluto/embedder.pid 2>/dev/null)\" = '$stroke_pid' ]
prepare_request='{\"requestId\":\"release-lifecycle-prepare-ink\",\"action\":\"prepare-ink-canvas\",\"appId\":\"$EXPECTED_APP_ID\",\"expectedPid\":$stroke_pid}'
prepare_response=\$(/home/root/pluto/bin/pluto-controlctl \\
  --socket /run/pluto/embedder-control.sock --request \"\$prepare_request\")
prepare_prefix='{\"requestId\":\"release-lifecycle-prepare-ink\",\"ok\":true,\"result\":{\"appId\":\"$EXPECTED_APP_ID\",\"pid\":$stroke_pid,\"canvasReady\":true,\"actionCount\":'
case \"\$prepare_response\" in
  \"\${prepare_prefix}0}}\" | \"\${prepare_prefix}1}}\" | \"\${prepare_prefix}2}}\") ;;
  *) echo \"release lifecycle smoke: Ink canvas preparation returned unbound metadata: \$prepare_response\" >&2; exit 91 ;;
esac
[ \"\$(cat /run/pluto/embedder.pid 2>/dev/null)\" = '$stroke_pid' ]" >/dev/null
sleep 1
prepared="$(wait_matching "$UP_TIMEOUT" "$stroke_pid" "$EXPECTED_APP_ID" \
  any any any any any)" || {
  echo "release lifecycle smoke: Ink canvas preparation did not settle in the same process" >&2
  exit 74
}
parse_state "$prepared"
[[ "$STATE_FOREGROUND_START_TICKS" == "$stroke_start_ticks" &&
  "$STATE_READY_FILE" == "$stroke_ready_file" &&
  "$STATE_HEALTH_FILE" == "$stroke_health_file" ]] || {
  echo "release lifecycle smoke: Ink canvas preparation changed launch identity" >&2
  exit 74
}
stroke_seq="$STATE_HEALTH_SEQ"
stroke_mono="$STATE_HEALTH_MONO"
before_stroke_digest="$(lifecycle_screenshot ink-canvas-before-stroke)" || {
  echo "release lifecycle smoke: could not capture the prepared post-dither canvas" >&2
  exit 74
}
remote "set -eu
[ \"\$(cat /run/pluto/embedder.pid 2>/dev/null)\" = '$stroke_pid' ]
response=\$(/home/root/pluto/bin/pluto-controlctl \\
  --socket /run/pluto/embedder-control.sock \\
  --request '{\"requestId\":\"release-lifecycle-stroke\",\"action\":\"draw-stroke\",\"appId\":\"$EXPECTED_APP_ID\",\"expectedPid\":$stroke_pid}')
expected_response='{\"requestId\":\"release-lifecycle-stroke\",\"ok\":true,\"result\":{\"appId\":\"$EXPECTED_APP_ID\",\"pid\":$stroke_pid,\"eventCount\":24}}'
[ \"\$response\" = \"\$expected_response\" ] || {
  echo \"release lifecycle smoke: Ink stroke returned unbound metadata: \$response\" >&2
  exit 91
}" >/dev/null
initial="$(wait_matching "$UP_TIMEOUT" "$stroke_pid" "$EXPECTED_APP_ID" \
  "$stroke_seq" "$stroke_mono" any any any)" || {
  echo "release lifecycle smoke: Ink stroke did not leave a healthy foreground" >&2
  exit 74
}
parse_state "$initial"
[[ "$STATE_FOREGROUND_START_TICKS" == "$stroke_start_ticks" &&
  "$STATE_READY_FILE" == "$stroke_ready_file" &&
  "$STATE_HEALTH_FILE" == "$stroke_health_file" ]] || {
  echo "release lifecycle smoke: Ink canvas/stroke changed launch identity" >&2
  exit 74
}
INK_PID="$STATE_FOREGROUND_PID"
INK_START_TICKS="$STATE_FOREGROUND_START_TICKS"
INK_READY_FILE="$STATE_READY_FILE"
INK_HEALTH_FILE="$STATE_HEALTH_FILE"
INK_HEALTH_SEQ="$STATE_HEALTH_SEQ"
INK_HEALTH_MONO="$STATE_HEALTH_MONO"
after_stroke_digest="$(lifecycle_screenshot ink-stroke)" || {
  echo "release lifecycle smoke: could not capture the stroked post-dither canvas" >&2
  exit 74
}
stroke_pixel_delta="$(central_pixel_difference \
  "$SCREENSHOT_DIR/ink-canvas-before-stroke.png" \
  "$SCREENSHOT_DIR/ink-stroke.png")" || {
  echo "release lifecycle smoke: Ink stroke did not materially change decoded central post-dither pixels" >&2
  exit 74
}
echo "release lifecycle smoke: PASS Ink decoded central pixel delta YAVG=$stroke_pixel_delta"
stage lifecycle-ink-stroke

"$CLI" run --release --device "$DEVICE" "$LAUNCHER_APP_ID"
initial="$(wait_matching "$UP_TIMEOUT" any "$LAUNCHER_APP_ID" any any any \
  "$INK_PID" T)" || {
  echo "release lifecycle smoke: Home did not foreground with the stroked Ink process stopped warm" >&2
  exit 74
}
parse_state "$initial"
INITIAL_UNIT="$STATE_UNIT"
INITIAL_SUPERVISOR_PID="$STATE_SUPERVISOR_PID"
INITIAL_SUPERVISOR_START_TICKS="$STATE_SUPERVISOR_START_TICKS"
INITIAL_BOOT_ID="$STATE_BOOT_ID"
INITIAL_RELEASE_REVISION="$STATE_RELEASE_REVISION"
INITIAL_PROFILE_ID="$STATE_PROFILE_ID"
HOME_PID="$STATE_FOREGROUND_PID"
HOME_START_TICKS="$STATE_FOREGROUND_START_TICKS"
HOME_READY_FILE="$STATE_READY_FILE"
HOME_HEALTH_FILE="$STATE_HEALTH_FILE"
[[ "$STATE_WARM_INK_START_TICKS" == "$INK_START_TICKS" &&
  "$STATE_WARM_INK_READY_FILE" == "$INK_READY_FILE" &&
  "$STATE_WARM_INK_HEALTH_FILE" == "$INK_HEALTH_FILE" ]] || {
  echo "release lifecycle smoke: warm Ink launch identity changed while foregrounding Home" >&2
  exit 74
}
echo "release lifecycle smoke: initial unit=$INITIAL_UNIT supervisor=$INITIAL_SUPERVISOR_PID supervisor_start=$INITIAL_SUPERVISOR_START_TICKS boot=$INITIAL_BOOT_ID home_pid=$HOME_PID home_start=$HOME_START_TICKS warm_ink_pid=$INK_PID ink_start=$INK_START_TICKS revision=$INITIAL_RELEASE_REVISION profile=$INITIAL_PROFILE_ID"
stage lifecycle-home-before-suspend

for ((cycle = 1; cycle <= CYCLES; cycle += 1)); do
  before="$(wait_matching "$UP_TIMEOUT" "$HOME_PID" "$LAUNCHER_APP_ID" \
    any any any "$INK_PID" T)" || {
    echo "release lifecycle smoke: cycle $cycle has no healthy pre-suspend state" >&2
    exit 75
  }
  parse_state "$before"
  before_unit="$STATE_UNIT"
  before_supervisor="$STATE_SUPERVISOR_PID"
  before_supervisor_start="$STATE_SUPERVISOR_START_TICKS"
  before_boot="$STATE_BOOT_ID"
  before_foreground_pid="$STATE_FOREGROUND_PID"
  before_foreground_start="$STATE_FOREGROUND_START_TICKS"
  before_ready_file="$STATE_READY_FILE"
  before_health_file="$STATE_HEALTH_FILE"
  before_app_id="$STATE_APP_ID"
  before_health_seq="$STATE_HEALTH_SEQ"
  before_health_mono="$STATE_HEALTH_MONO"
  before_wake_count="$STATE_WAKE_COUNT"
  [[ "$before_unit" == "$INITIAL_UNIT" &&
    "$before_supervisor" == "$INITIAL_SUPERVISOR_PID" &&
    "$before_supervisor_start" == "$INITIAL_SUPERVISOR_START_TICKS" &&
    "$before_boot" == "$INITIAL_BOOT_ID" &&
    "$before_foreground_start" == "$HOME_START_TICKS" &&
    "$before_ready_file" == "$HOME_READY_FILE" &&
    "$before_health_file" == "$HOME_HEALTH_FILE" &&
    "$STATE_RELEASE_REVISION" == "$INITIAL_RELEASE_REVISION" &&
    "$STATE_PROFILE_ID" == "$INITIAL_PROFILE_ID" &&
    "$before_app_id" == "$LAUNCHER_APP_ID" &&
    "$STATE_WARM_INK_PID" == "$INK_PID" &&
    "$STATE_WARM_INK_START_TICKS" == "$INK_START_TICKS" &&
    "$STATE_WARM_INK_READY_FILE" == "$INK_READY_FILE" &&
    "$STATE_WARM_INK_HEALTH_FILE" == "$INK_HEALTH_FILE" &&
    "$STATE_WARM_INK_STATE" == T ]] || {
    echo "release lifecycle smoke: ownership changed before cycle $cycle" >&2
    exit 76
  }

  receipt="$(remote "set -eu
rtc=/sys/class/rtc/rtc0/wakealarm
[ -f \"\$rtc\" ] && [ -w \"\$rtc\" ]
now=\$(date +%s)
alarm=\$((now + $WAKE_SECONDS))
printf '0\\n' > \"\$rtc\"
printf '%s\\n' \"\$alarm\" > \"\$rtc\"
accepted=\$(cat \"\$rtc\")
[ \"\$accepted\" = \"\$alarm\" ]
tmp=/run/pluto/.standby.acceptance.\$\$
printf 'release-lifecycle-cycle-%s\\n' '$cycle' > \"\$tmp\"
mv \"\$tmp\" /run/pluto/standby
printf 'alarm=%s\\n' \"\$accepted\"")" || {
    echo "release lifecycle smoke: cycle $cycle could not arm RTC and request standby" >&2
    exit 77
  }
  echo "release lifecycle smoke: cycle=$cycle requested $receipt"

  wait_down || {
    echo "release lifecycle smoke: cycle $cycle never entered an unreachable suspended state" >&2
    exit 78
  }
  expected_wake=$((before_wake_count + 1))
  after="$(wait_matching "$UP_TIMEOUT" "$HOME_PID" "$LAUNCHER_APP_ID" \
    "$before_health_seq" "$before_health_mono" "$expected_wake" \
    "$INK_PID" T)" || {
    echo "release lifecycle smoke: cycle $cycle did not return healthy after wake" >&2
    exit 79
  }
  parse_state "$after"
  [[ "$STATE_UNIT" == "$before_unit" &&
    "$STATE_SUPERVISOR_PID" == "$before_supervisor" &&
    "$STATE_SUPERVISOR_START_TICKS" == "$before_supervisor_start" &&
    "$STATE_BOOT_ID" == "$before_boot" &&
    "$STATE_FOREGROUND_PID" == "$before_foreground_pid" &&
    "$STATE_FOREGROUND_START_TICKS" == "$before_foreground_start" &&
    "$STATE_READY_FILE" == "$before_ready_file" &&
    "$STATE_HEALTH_FILE" == "$before_health_file" &&
    "$STATE_APP_ID" == "$before_app_id" &&
    "$STATE_RELEASE_REVISION" == "$INITIAL_RELEASE_REVISION" &&
    "$STATE_PROFILE_ID" == "$INITIAL_PROFILE_ID" &&
    "$STATE_WARM_INK_PID" == "$INK_PID" &&
    "$STATE_WARM_INK_START_TICKS" == "$INK_START_TICKS" &&
    "$STATE_WARM_INK_READY_FILE" == "$INK_READY_FILE" &&
    "$STATE_WARM_INK_HEALTH_FILE" == "$INK_HEALTH_FILE" &&
    "$STATE_WARM_INK_STATE" == T ]] || {
    echo "release lifecycle smoke: cycle $cycle rebooted or changed supervisor ownership" >&2
    exit 80
  }
  ((STATE_HEALTH_SEQ > before_health_seq &&
    STATE_HEALTH_MONO > before_health_mono)) || {
    echo "release lifecycle smoke: cycle $cycle did not preserve and advance the foreground health receipt" >&2
    exit 81
  }
  ((STATE_WAKE_COUNT == before_wake_count + 1)) || {
    echo "release lifecycle smoke: cycle $cycle lacks exactly one completed suspend receipt (before=$before_wake_count after=$STATE_WAKE_COUNT)" >&2
    exit 81
  }
  echo "release lifecycle smoke: PASS cycle=$cycle app=$STATE_APP_ID pid=$STATE_FOREGROUND_PID health_seq=$STATE_HEALTH_SEQ wake_receipts=$STATE_WAKE_COUNT"
  stage "lifecycle-wake-$cycle"
done

"$CLI" run --release --device "$DEVICE" "$EXPECTED_APP_ID"
restored="$(wait_matching "$UP_TIMEOUT" "$INK_PID" "$EXPECTED_APP_ID" \
  "$INK_HEALTH_SEQ" "$INK_HEALTH_MONO" any any any)" || {
  echo "release lifecycle smoke: stroked Ink process did not resume after the standby soak" >&2
  exit 82
}
parse_state "$restored"
[[ "$STATE_UNIT" == "$INITIAL_UNIT" &&
  "$STATE_SUPERVISOR_PID" == "$INITIAL_SUPERVISOR_PID" &&
  "$STATE_SUPERVISOR_START_TICKS" == "$INITIAL_SUPERVISOR_START_TICKS" &&
  "$STATE_BOOT_ID" == "$INITIAL_BOOT_ID" &&
  "$STATE_FOREGROUND_PID" == "$INK_PID" &&
  "$STATE_FOREGROUND_START_TICKS" == "$INK_START_TICKS" &&
  "$STATE_READY_FILE" == "$INK_READY_FILE" &&
  "$STATE_HEALTH_FILE" == "$INK_HEALTH_FILE" &&
  "$STATE_RELEASE_REVISION" == "$INITIAL_RELEASE_REVISION" &&
  "$STATE_PROFILE_ID" == "$INITIAL_PROFILE_ID" ]] || {
  echo "release lifecycle smoke: Ink restoration changed the accepted session identity" >&2
  exit 82
}
echo "release lifecycle smoke: PASS restored stroked Ink pid=$INK_PID health_seq=$STATE_HEALTH_SEQ"
stage lifecycle-ink-restored

if [[ "$CRASH_TEST" == 1 ]]; then
  before="$restored"
  parse_state "$before"
  crash_pid="$STATE_FOREGROUND_PID"
  crash_supervisor="$STATE_SUPERVISOR_PID"
  crash_supervisor_start="$STATE_SUPERVISOR_START_TICKS"
  crash_boot="$STATE_BOOT_ID"
  crash_wakes="$STATE_WAKE_COUNT"
  crash_revision="$STATE_RELEASE_REVISION"
  crash_profile="$STATE_PROFILE_ID"
  remote "set -eu
[ \"\$(cat /run/pluto/embedder.pid)\" = '$crash_pid' ]
kill -KILL '$crash_pid'" >/dev/null
  after="$(wait_matching "$UP_TIMEOUT" any "$LAUNCHER_APP_ID" any any \
    "$crash_wakes" none none)" || {
    echo "release lifecycle smoke: foreground crash did not recover" >&2
    exit 82
  }
  parse_state "$after"
  [[ "$STATE_SUPERVISOR_PID" == "$crash_supervisor" &&
    "$STATE_SUPERVISOR_START_TICKS" == "$crash_supervisor_start" &&
    "$STATE_BOOT_ID" == "$crash_boot" &&
    "$STATE_FOREGROUND_PID" != "$crash_pid" &&
    "$STATE_WAKE_COUNT" == "$crash_wakes" &&
    "$STATE_RELEASE_REVISION" == "$crash_revision" &&
    "$STATE_PROFILE_ID" == "$crash_profile" &&
    "$STATE_APP_ID" == "$LAUNCHER_APP_ID" &&
    "$STATE_WARM_INK_PID" == none &&
    "$STATE_WARM_INK_STATE" == none ]] || {
    echo "release lifecycle smoke: Ink crash did not recover to clean Home" >&2
    exit 83
  }
  replacement_pid="$STATE_FOREGROUND_PID"
  replacement_start="$STATE_FOREGROUND_START_TICKS"
  replacement_ready_file="$STATE_READY_FILE"
  replacement_health_file="$STATE_HEALTH_FILE"
  replacement_seq="$STATE_HEALTH_SEQ"
  replacement_mono="$STATE_HEALTH_MONO"
  sleep "$CRASH_SETTLE_SECONDS"
  settled="$(wait_matching "$UP_TIMEOUT" "$replacement_pid" \
    "$LAUNCHER_APP_ID" "$replacement_seq" "$replacement_mono" \
    "$crash_wakes" none none)" || {
    echo "release lifecycle smoke: replacement foreground stopped reporting health" >&2
    exit 84
  }
  parse_state "$settled"
  [[ "$STATE_FOREGROUND_PID" == "$replacement_pid" &&
    "$STATE_FOREGROUND_START_TICKS" == "$replacement_start" &&
    "$STATE_READY_FILE" == "$replacement_ready_file" &&
    "$STATE_HEALTH_FILE" == "$replacement_health_file" &&
    "$STATE_SUPERVISOR_START_TICKS" == "$crash_supervisor_start" &&
    "$STATE_APP_ID" == "$LAUNCHER_APP_ID" &&
    "$STATE_RELEASE_REVISION" == "$crash_revision" &&
    "$STATE_PROFILE_ID" == "$crash_profile" &&
    "$STATE_HEALTH_SEQ" -gt "$replacement_seq" &&
    "$STATE_HEALTH_MONO" -gt "$replacement_mono" ]] || {
    echo "release lifecycle smoke: replacement foreground health did not progress" >&2
    exit 84
  }
  echo "release lifecycle smoke: PASS Ink crash old_pid=$crash_pid Home_pid=$STATE_FOREGROUND_PID supervisor=$STATE_SUPERVISOR_PID"
  stage lifecycle-crash-home
fi

echo "release lifecycle smoke: PASS cycles=$CYCLES crash_test=$CRASH_TEST unit=$INITIAL_UNIT supervisor=$INITIAL_SUPERVISOR_PID boot=$INITIAL_BOOT_ID endpoint=$CANONICAL_ENDPOINT test_seam=$ALLOW_TEST_HOOKS"
