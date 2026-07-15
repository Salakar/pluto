#!/usr/bin/env bash
# Exact-device suspend/resume and foreground-crash acceptance for a deployed
# release. This is intentionally separate from the visual app smoke so a final
# camera run can happen after all destructive recovery exercises.
set -euo pipefail

DEVICE="${1:-root@10.11.99.1}"
SSH_TARGET="${PLUTO_ACCEPTANCE_SSH_TARGET:-$DEVICE}"
SSH_PORT="${PLUTO_ACCEPTANCE_SSH_PORT:-}"
SSH_BIND_ADDRESS="${PLUTO_ACCEPTANCE_SSH_BIND_ADDRESS:-}"
STAGE_HOOK="${PLUTO_ACCEPTANCE_STAGE_HOOK:-}"
STAGE_DELAY="${PLUTO_ACCEPTANCE_STAGE_DELAY:-0}"
CYCLES="${PLUTO_LIFECYCLE_CYCLES:-20}"
WAKE_SECONDS="${PLUTO_LIFECYCLE_WAKE_SECONDS:-18}"
DOWN_TIMEOUT="${PLUTO_LIFECYCLE_DOWN_TIMEOUT:-45}"
UP_TIMEOUT="${PLUTO_LIFECYCLE_UP_TIMEOUT:-120}"
CRASH_TEST="${PLUTO_LIFECYCLE_CRASH_TEST:-1}"
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
[[ "$CRASH_TEST" == 0 || "$CRASH_TEST" == 1 ]] || {
  echo "release lifecycle smoke: crash test must be 0 or 1" >&2
  exit 64
}
[[ -z "$STAGE_HOOK" || -x "$STAGE_HOOK" ]] || {
  echo "release lifecycle smoke: stage hook is not executable: $STAGE_HOOK" >&2
  exit 64
}
if [[ -n "$SSH_PORT" ]]; then
  is_positive_integer "$SSH_PORT" && ((SSH_PORT <= 65535)) || {
    echo "release lifecycle smoke: invalid SSH port: $SSH_PORT" >&2
    exit 64
  }
  SSH_OPTIONS+=(-p "$SSH_PORT")
fi
if [[ -n "$SSH_BIND_ADDRESS" ]]; then
  [[ "$SSH_BIND_ADDRESS" =~ ^[0-9A-Fa-f:.]+$ ]] || {
    echo "release lifecycle smoke: invalid SSH bind address: $SSH_BIND_ADDRESS" >&2
    exit 64
  }
  SSH_OPTIONS+=(-b "$SSH_BIND_ADDRESS")
fi

remote() {
  ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" "$1"
}

stage() {
  local label="$1"
  if [[ -n "$STAGE_HOOK" ]]; then
    "$STAGE_HOOK" "$label"
  fi
  sleep "$STAGE_DELAY"
}

READY_PROBE='set -eu
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
boot_id=$(cat /proc/sys/kernel/random/boot_id)
foreground_pid=$(cat /run/pluto/embedder.pid 2>/dev/null || true)
case "$foreground_pid" in ""|*[!0-9]*) exit 83 ;; esac
kill -0 "$foreground_pid" 2>/dev/null || exit 84
foreground_cmd=$(tr "\000" " " < "/proc/$foreground_pid/cmdline")
case "$foreground_cmd" in
  *--release*--presenter=native*--aot-elf=*) ;;
  *) exit 85 ;;
esac
app_id=$(tr "\000" "\n" < "/proc/$foreground_pid/environ" |
  sed -n "s/^PLUTO_APP_ID=//p" | sed -n "1p")
case "$app_id" in ""|*[!A-Za-z0-9._-]*) exit 86 ;; esac
health_file=""
for arg in $(tr "\000" "\n" < "/proc/$foreground_pid/cmdline"); do
  case "$arg" in --health-file=*) health_file=${arg#*=} ;; esac
done
case "$health_file" in /run/pluto/health.*) ;; *) exit 87 ;; esac
set -- $(cat "$health_file" 2>/dev/null || true)
[ "$#" -eq 3 ] && [ "$1" = "pid=$foreground_pid" ] || exit 88
health_seq=${2#seq=}
case "$health_seq" in ""|*[!0-9]*) exit 89 ;; esac
wake_count=$(journalctl -u "$selected_unit" -b -o cat --no-pager 2>/dev/null |
  grep -c "suspend target completed after wake" || true)
case "$wake_count" in ""|*[!0-9]*) exit 90 ;; esac
printf "%s|%s|%s|%s|%s|%s|%s\n" \
  "$selected_unit" "$supervisor_pid" "$boot_id" "$foreground_pid" \
  "$app_id" "$health_seq" "$wake_count"'

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

parse_state() {
  local state="$1"
  IFS='|' read -r STATE_UNIT STATE_SUPERVISOR_PID STATE_BOOT_ID \
    STATE_FOREGROUND_PID STATE_APP_ID STATE_HEALTH_SEQ STATE_WAKE_COUNT <<< "$state"
  [[ -n "$STATE_UNIT" && -n "$STATE_SUPERVISOR_PID" &&
    -n "$STATE_BOOT_ID" && -n "$STATE_FOREGROUND_PID" &&
    -n "$STATE_APP_ID" && -n "$STATE_HEALTH_SEQ" &&
    -n "$STATE_WAKE_COUNT" ]] || return 1
}

initial="$(wait_ready "$UP_TIMEOUT")" || {
  echo "release lifecycle smoke: no healthy release supervisor on $DEVICE" >&2
  exit 74
}
parse_state "$initial"
INITIAL_UNIT="$STATE_UNIT"
INITIAL_SUPERVISOR_PID="$STATE_SUPERVISOR_PID"
INITIAL_BOOT_ID="$STATE_BOOT_ID"
echo "release lifecycle smoke: initial unit=$INITIAL_UNIT supervisor=$INITIAL_SUPERVISOR_PID boot=$INITIAL_BOOT_ID app=$STATE_APP_ID"
stage lifecycle-initial

for ((cycle = 1; cycle <= CYCLES; cycle += 1)); do
  before="$(wait_ready "$UP_TIMEOUT")" || {
    echo "release lifecycle smoke: cycle $cycle has no healthy pre-suspend state" >&2
    exit 75
  }
  parse_state "$before"
  before_unit="$STATE_UNIT"
  before_supervisor="$STATE_SUPERVISOR_PID"
  before_boot="$STATE_BOOT_ID"
  before_wake_count="$STATE_WAKE_COUNT"
  [[ "$before_unit" == "$INITIAL_UNIT" && "$before_supervisor" == "$INITIAL_SUPERVISOR_PID" &&
    "$before_boot" == "$INITIAL_BOOT_ID" ]] || {
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
  after="$(wait_ready "$UP_TIMEOUT")" || {
    echo "release lifecycle smoke: cycle $cycle did not return healthy after wake" >&2
    exit 79
  }
  parse_state "$after"
  [[ "$STATE_UNIT" == "$before_unit" && "$STATE_SUPERVISOR_PID" == "$before_supervisor" &&
    "$STATE_BOOT_ID" == "$before_boot" ]] || {
    echo "release lifecycle smoke: cycle $cycle rebooted or changed supervisor ownership" >&2
    exit 80
  }
  ((STATE_WAKE_COUNT == before_wake_count + 1)) || {
    echo "release lifecycle smoke: cycle $cycle lacks exactly one completed suspend receipt (before=$before_wake_count after=$STATE_WAKE_COUNT)" >&2
    exit 81
  }
  echo "release lifecycle smoke: PASS cycle=$cycle app=$STATE_APP_ID pid=$STATE_FOREGROUND_PID health_seq=$STATE_HEALTH_SEQ wake_receipts=$STATE_WAKE_COUNT"
  stage "lifecycle-wake-$cycle"
done

if [[ "$CRASH_TEST" == 1 ]]; then
  before="$(wait_ready "$UP_TIMEOUT")"
  parse_state "$before"
  crash_pid="$STATE_FOREGROUND_PID"
  crash_supervisor="$STATE_SUPERVISOR_PID"
  crash_boot="$STATE_BOOT_ID"
  crash_wakes="$STATE_WAKE_COUNT"
  remote "set -eu
[ \"\$(cat /run/pluto/embedder.pid)\" = '$crash_pid' ]
kill -KILL '$crash_pid'" >/dev/null
  after="$(wait_ready "$UP_TIMEOUT")" || {
    echo "release lifecycle smoke: foreground crash did not recover" >&2
    exit 82
  }
  parse_state "$after"
  [[ "$STATE_SUPERVISOR_PID" == "$crash_supervisor" &&
    "$STATE_BOOT_ID" == "$crash_boot" &&
    "$STATE_FOREGROUND_PID" != "$crash_pid" &&
    "$STATE_WAKE_COUNT" == "$crash_wakes" ]] || {
    echo "release lifecycle smoke: foreground crash changed the session or failed to replace the app" >&2
    exit 83
  }
  echo "release lifecycle smoke: PASS foreground crash old_pid=$crash_pid replacement_pid=$STATE_FOREGROUND_PID supervisor=$STATE_SUPERVISOR_PID"
  stage lifecycle-crash-recovered
fi

echo "release lifecycle smoke: PASS cycles=$CYCLES crash_test=$CRASH_TEST unit=$INITIAL_UNIT supervisor=$INITIAL_SUPERVISOR_PID boot=$INITIAL_BOOT_ID"
