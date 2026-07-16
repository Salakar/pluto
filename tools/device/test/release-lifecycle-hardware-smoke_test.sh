#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SMOKE="$ROOT/tools/device/test/release-lifecycle-hardware-smoke.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pluto-lifecycle-smoke-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
REVISION=0123456789abcdef0123456789abcdef01234567

fail() {
  echo "release-lifecycle-hardware-smoke_test: FAIL: $*" >&2
  exit 1
}

mkdir -p "$TMP/bin" "$TMP/png"
cp "$ROOT/apps/launcher/test_goldens/goldens/s04_home_empty.png" \
  "$TMP/png/ink-canvas-before-stroke.png"
cp "$ROOT/apps/launcher/test_goldens/goldens/s05_app_context_sheet.png" \
  "$TMP/png/ink-stroke.png"
ffmpeg -v error -nostdin -y \
  -i "$TMP/png/ink-canvas-before-stroke.png" -compression_level 9 \
  "$TMP/png/ink-stroke-noop.png"
cmp -s "$TMP/png/ink-canvas-before-stroke.png" \
  "$TMP/png/ink-stroke-noop.png" &&
  fail 'no-op lifecycle PNG fixture did not change its encoded bytes'
cat > "$TMP/bin/pluto" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == screenshot ]]; then
  output=''
  app=''
  surface=''
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -o) output=$2; shift 2 ;;
      --app) app=$2; shift 2 ;;
      --surface) surface=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ "$app" == dev.pluto.ink && "$surface" == post-dither ]]
  case "${output##*/}" in
    ink-canvas-before-stroke.png | ink-stroke.png) ;;
    *) exit 64 ;;
  esac
  fixture="${output##*/}"
  if [[ "$fixture" == ink-stroke.png && "${NO_STROKE_CHANGE:-0}" == 1 ]]; then
    fixture=ink-stroke-noop.png
  fi
  cp "$PNG_FIXTURE_DIR/$fixture" "$output"
  exit 0
fi
[[ "$1" == run && "$2" == --release && "$3" == --device ]]
target=$5
state="$STATE_DIR/state"
. "$state"
save() {
  cat > "$state" <<STATE
unit=$unit
supervisor=$supervisor
boot=$boot
pid=$pid
app=$app
seq=$seq
mono=$mono
wakes=$wakes
revision=$revision
profile=$profile
suspended=$suspended
crashed=$crashed
pending_progress=$pending_progress
ink_pid=$ink_pid
ink_seq=$ink_seq
ink_mono=$ink_mono
home_pid=$home_pid
ink_start=$ink_start
home_start=$home_start
ink_launch=$ink_launch
home_launch=$home_launch
home_seq=$home_seq
home_mono=$home_mono
frontlight_snapshot=$frontlight_snapshot
standby_requests=$standby_requests
STATE
}
if [[ "$app" == dev.pluto.ink ]]; then
  ink_seq=$seq
  ink_mono=$mono
else
  home_seq=$seq
  home_mono=$mono
fi
case "$target" in
  dev.pluto.ink)
    [[ "$ink_pid" != none ]]
    pid=$ink_pid
    app=dev.pluto.ink
    seq=$((ink_seq + 1))
    mono=$((ink_mono + 1000))
    ;;
  dev.pluto.launcher)
    pid=$home_pid
    app=dev.pluto.launcher
    seq=$((home_seq + 1))
    mono=$((home_mono + 1000))
    ;;
  *) exit 64 ;;
esac
save
EOF
chmod 0755 "$TMP/bin/pluto"

cat > "$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${SLEEP_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$SLEEP_LOG"
fi
if [[ "${PLUTO_TEST_NO_SLEEP:-0}" == 1 ]]; then
  exit 0
fi
exec /bin/sleep "$@"
EOF
chmod 0755 "$TMP/bin/sleep"

cat > "$TMP/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${PUBLISH_LOG:-}" ]]; then
  exec /bin/mv "$@"
fi
[[ -n "${PUBLISH_RUN_DIR:-}" && -n "${PUBLISH_EXPECT_FRONTLIGHT:-}" ]] ||
  exit 66
destination=${!#}
case "$destination" in
  "$PUBLISH_RUN_DIR/standby-frontlight")
    [[ "$PUBLISH_EXPECT_FRONTLIGHT" != none ]] || exit 66
    /bin/mv "$@" || exit 66
    [[ -f "$destination" && ! -L "$destination" ]] || exit 66
    [[ "$(cat "$destination")" == "$PUBLISH_EXPECT_FRONTLIGHT" ]] ||
      exit 66
    printf 'frontlight\n' >> "$PUBLISH_LOG" || exit 66
    ;;
  "$PUBLISH_RUN_DIR/standby")
    if [[ "$PUBLISH_EXPECT_FRONTLIGHT" == none ]]; then
      [[ ! -e "$PUBLISH_RUN_DIR/standby-frontlight" &&
        ! -L "$PUBLISH_RUN_DIR/standby-frontlight" ]] || exit 66
    else
      [[ -f "$PUBLISH_RUN_DIR/standby-frontlight" &&
        ! -L "$PUBLISH_RUN_DIR/standby-frontlight" ]] || exit 66
      [[ "$(cat "$PUBLISH_RUN_DIR/standby-frontlight")" == \
        "$PUBLISH_EXPECT_FRONTLIGHT" ]] || exit 66
    fi
    /bin/mv "$@" || exit 66
    printf 'standby\n' >> "$PUBLISH_LOG" || exit 66
    ;;
  *) exec /bin/mv "$@" ;;
esac
EOF
chmod 0755 "$TMP/bin/mv"

cat > "$TMP/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == *'-o cat'* && "$*" == *'--no-pager'* ]]
while IFS= read -r epoch; do
  printf '[pluto-session 02:03:04] suspend-wake-receipt rtc=rtc0 since_epoch=%s\n' \
    "$epoch"
  printf '[pluto-session 02:03:04] suspend target completed after wake\n'
done < "$STATE_DIR/wake-receipts"
EOF
chmod 0755 "$TMP/bin/journalctl"

cat > "$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command=${!#}
state="$STATE_DIR/state"
. "$state"
save() {
  cat > "$state" <<STATE
unit=$unit
supervisor=$supervisor
boot=$boot
pid=$pid
app=$app
seq=$seq
mono=$mono
wakes=$wakes
revision=$revision
profile=$profile
suspended=$suspended
crashed=$crashed
pending_progress=$pending_progress
ink_pid=$ink_pid
ink_seq=$ink_seq
ink_mono=$ink_mono
home_pid=$home_pid
ink_start=$ink_start
home_start=$home_start
ink_launch=$ink_launch
home_launch=$home_launch
home_seq=$home_seq
home_mono=$home_mono
frontlight_snapshot=$frontlight_snapshot
standby_requests=$standby_requests
STATE
}
complete_suspend() {
  suspended=0
  case "$FIXTURE_MODE" in
    normal)
      pending_progress=1
      ;;
    cold)
      home_pid=$((home_pid + 1))
      home_start=$((home_start + 1))
      pid=$home_pid
      seq=$((seq + 1))
      mono=$((mono + 1000))
      home_seq=$seq
      home_mono=$mono
      ;;
    reused)
      home_start=$((home_start + 1))
      seq=$((seq + 1))
      mono=$((mono + 1000))
      home_seq=$seq
      home_mono=$mono
      ;;
    relaunch)
      home_launch=home-relaunch
      seq=$((seq + 1))
      mono=$((mono + 1000))
      home_seq=$seq
      home_mono=$mono
      ;;
    stale) ;;
    *) exit 64 ;;
  esac
  save
}
complete_fixture_wake() {
  accepted_alarm=$(cat "$STATE_DIR/rtc0/wakealarm") || exit 66
  [[ "$accepted_alarm" =~ ^[0-9]+$ ]] || exit 66
  case "${WAKE_FIXTURE_MODE:-rtc}" in
    rtc | rtc-reachable)
      printf '%s\n' "$accepted_alarm" >> "$STATE_DIR/wake-receipts"
      wakes=$((wakes + 1))
      printf '%s\n' "$accepted_alarm" > "$STATE_DIR/rtc0/since_epoch"
      : > "$STATE_DIR/rtc0/wakealarm"
      ;;
    early-delayed)
      ((accepted_alarm >= 30)) || exit 66
      printf '%s\n' "$((accepted_alarm - 30))" >> \
        "$STATE_DIR/wake-receipts"
      wakes=$((wakes + 1))
      # SSH observation is deliberately later than the deadline. Only the
      # supervisor's immutable wake receipt can still prove the early wake.
      printf '%s\n' "$((accepted_alarm + 30))" > \
        "$STATE_DIR/rtc0/since_epoch"
      : > "$STATE_DIR/rtc0/wakealarm"
      ;;
    late-delayed)
      printf '%s\n' "$((accepted_alarm + 30))" >> \
        "$STATE_DIR/wake-receipts"
      wakes=$((wakes + 1))
      printf '%s\n' "$((accepted_alarm + 60))" > \
        "$STATE_DIR/rtc0/since_epoch"
      : > "$STATE_DIR/rtc0/wakealarm"
      ;;
    malformed)
      printf 'not-an-epoch\n' >> "$STATE_DIR/wake-receipts"
      wakes=$((wakes + 1))
      printf '%s\n' "$accepted_alarm" > "$STATE_DIR/rtc0/since_epoch"
      : > "$STATE_DIR/rtc0/wakealarm"
      ;;
    missing)
      printf '%s\n' "$accepted_alarm" > "$STATE_DIR/rtc0/since_epoch"
      : > "$STATE_DIR/rtc0/wakealarm"
      ;;
    *) exit 64 ;;
  esac
  complete_suspend
}
verify_receipt_query() {
  [[ "$command" == *' suspend-wake-receipt '* ]] || exit 66
  [[ "$command" != *'suspend target completed after wake'* ]] || exit 66
}
case "$command" in
  *'proc_start_ticks()'*)
    verify_receipt_query
    receipt_count=$(wc -l < "$STATE_DIR/wake-receipts" | tr -d ' ')
    valid_receipt_count=$(grep -Ec '^[0-9]+$' \
      "$STATE_DIR/wake-receipts" || true)
    [[ "$receipt_count" == "$wakes" &&
      "$valid_receipt_count" == "$receipt_count" ]] || exit 90
    if [[ "$crashed" == 1 ]]; then
      seq=$((seq + 1))
      mono=$((mono + 1000))
      save
    fi
    if [[ "$ink_pid" == none ]]; then
      warm_pid=none
      warm_start=none
      warm_state=none
      warm_ready=none
      warm_health=none
    elif [[ "$app" == dev.pluto.ink ]]; then
      warm_pid=$ink_pid
      warm_start=$ink_start
      warm_state=S
      warm_ready=/run/pluto/boot-ready.$ink_launch
      warm_health=/run/pluto/health.$ink_launch
    else
      warm_pid=$ink_pid
      warm_start=$ink_start
      warm_state=T
      warm_ready=/run/pluto/boot-ready.$ink_launch
      warm_health=/run/pluto/health.$ink_launch
    fi
    if [[ "$app" == dev.pluto.ink ]]; then
      foreground_start=$ink_start
      ready=/run/pluto/boot-ready.$ink_launch
      health=/run/pluto/health.$ink_launch
    else
      foreground_start=$home_start
      ready=/run/pluto/boot-ready.$home_launch
      health=/run/pluto/health.$home_launch
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$unit" "$supervisor" 1000 "$boot" "$pid" "$foreground_start" \
      "$app" "$seq" "$mono" "$wakes" "$revision" "$profile" "$ready" \
      "$health" "$warm_pid" "$warm_start" "$warm_state" "$warm_ready" \
      "$warm_health"
    if [[ "$pending_progress" == 1 ]]; then
      pending_progress=0
      seq=$((seq + 1))
      mono=$((mono + 1000))
      home_seq=$seq
      home_mono=$mono
      save
    fi
    ;;
  *'release-lifecycle-prepare-ink'*)
    if ! printf '%s' "$command" | grep -F -- \
      '"${prepare_prefix}0}}" | "${prepare_prefix}1}}" | "${prepare_prefix}2}}")' \
      >/dev/null; then
      echo 'fake ssh: lifecycle prepare consumer did not require a complete exact JSON receipt' >&2
      exit 66
    fi
    ;;
  *'release-lifecycle-stroke'*)
    seq=$((seq + 1))
    mono=$((mono + 1000))
    ink_seq=$seq
    ink_mono=$mono
    save
    ;;
  *'probe_kind=release-lifecycle-suspend-progress'*)
    if [[ "$suspended" == 1 && "${WAKE_FIXTURE_MODE:-rtc}" != never ]]; then
      complete_fixture_wake
      case "${WAKE_FIXTURE_MODE:-rtc}" in
        rtc | early-delayed | late-delayed | malformed | missing) exit 1 ;;
      esac
    fi
    verify_receipt_query
    /bin/sh -c "$command"
    ;;
  *'wakealarm'*)
    relative_write="printf '+%s\\n' '60' > \"\$wakealarm\""
    clear_write="printf '0\\n' > \"\$wakealarm\""
    frontlight_write='mv -f "$light_tmp" /run/pluto/standby-frontlight'
    marker_write='mv -f "$marker_tmp" /run/pluto/standby'
    publication_block='if [ -n "$PLUTO_PROFILE_FRONTLIGHT_BRIGHTNESS" ]; then
  mv -f "$light_tmp" /run/pluto/standby-frontlight
fi
mv -f "$marker_tmp" /run/pluto/standby'
    marker_first_block='mv -f "$marker_tmp" /run/pluto/standby
if [ -n "$PLUTO_PROFILE_FRONTLIGHT_BRIGHTNESS" ]; then
  mv -f "$light_tmp" /run/pluto/standby-frontlight
fi'
    printf '%s' "$command" | grep -F '. /home/root/pluto/share/device-profiles.sh' \
      >/dev/null || exit 66
    printf '%s' "$command" | grep -F 'pluto_profile_probe' >/dev/null || exit 66
    printf '%s' "$command" | grep -F '[ -z "$cleared" ]' >/dev/null || exit 66
    printf '%s' "$command" | grep -F 'cat "$rtc_dir/since_epoch"' \
      >/dev/null || exit 66
    printf '%s' "$command" | grep -F '[ "$pending" = "$accepted" ]' \
      >/dev/null || exit 66
    printf '%s' "$command" | grep -F \
      '[ "$publish_margin" -ge "$minimum_margin" ]' >/dev/null || exit 66
    printf '%s' "$command" | grep -F \
      'mv -f "$light_tmp" /run/pluto/standby-frontlight' \
      >/dev/null || exit 66
    [[ "$command" == *"$relative_write"* ]] || exit 66
    [[ "$command" != *'alarm=$((now +'* ]] || exit 66

    case "${PUBLICATION_FIXTURE_MODE:-normal}" in
      normal) ;;
      missing-marker)
        [[ "$command" == *"$marker_write"* ]] || exit 66
        command=${command/"$marker_write"/:}
        ;;
      missing-frontlight)
        [[ "$command" == *"$frontlight_write"* ]] || exit 66
        command=${command/"$frontlight_write"/:}
        ;;
      marker-first)
        [[ "$command" == *"$publication_block"* ]] || exit 66
        command=${command/"$publication_block"/"$marker_first_block"}
        ;;
      *) exit 64 ;;
    esac

    rewritten=${command//\/home\/root\/pluto\/share\/device-profiles.sh/$STATE_DIR\/device-profiles.sh}
    rewritten=${rewritten//\/sys\/class\/rtc\/rtc0/$STATE_DIR\/rtc0}
    rewritten=${rewritten//\/run\/pluto/$STATE_DIR\/run}
    case "${RTC_FIXTURE_MODE:-normal}" in
      normal)
        rewritten=${rewritten/"$clear_write"/": > \"\$wakealarm\""}
        rtc_base=$(cat "$STATE_DIR/rtc0/since_epoch") || exit 66
        [[ "$rtc_base" =~ ^[0-9]+$ ]] || exit 66
        accepted_alarm=$((rtc_base + 60))
        ;;
      expired)
        rewritten=${rewritten/"$clear_write"/": > \"\$wakealarm\""}
        rtc_base=$(cat "$STATE_DIR/rtc0/since_epoch") || exit 66
        [[ "$rtc_base" =~ ^[0-9]+$ && "$rtc_base" -gt 0 ]] || exit 66
        accepted_alarm=$((rtc_base - 1))
        ;;
      uncleared)
        rtc_base=$(cat "$STATE_DIR/rtc0/since_epoch") || exit 66
        [[ "$rtc_base" =~ ^[0-9]+$ ]] || exit 66
        accepted_alarm=$((rtc_base + 60))
        ;;
      *) exit 64 ;;
    esac
    replacement_write="printf '%s\\n' '$accepted_alarm' > \"\$wakealarm\""
    rewritten=${rewritten/"$relative_write"/"$replacement_write"}
    : > "$STATE_DIR/publish-order"
    PUBLISH_LOG="$STATE_DIR/publish-order"
    PUBLISH_RUN_DIR="$STATE_DIR/run"
    if [[ "$profile" == move ]]; then
      PUBLISH_EXPECT_FRONTLIGHT=913
    else
      PUBLISH_EXPECT_FRONTLIGHT=none
    fi
    export PUBLISH_LOG PUBLISH_RUN_DIR PUBLISH_EXPECT_FRONTLIGHT
    receipt=$(/bin/sh -c "$rewritten") || exit 66
    expected_marker="release-lifecycle-cycle-$((standby_requests + 1))"
    [[ -f "$STATE_DIR/run/standby" && ! -L "$STATE_DIR/run/standby" ]] ||
      exit 66
    marker_content=$(cat "$STATE_DIR/run/standby") || exit 66
    [[ "$marker_content" == "$expected_marker" ]] || exit 66
    publish_order=$(tr '\n' ',' < "$STATE_DIR/publish-order") || exit 66
    if [[ "$profile" == move ]]; then
      [[ "$publish_order" == 'frontlight,standby,' ]] || exit 66
    else
      [[ "$publish_order" == 'standby,' ]] || exit 66
    fi
    if [[ -f "$STATE_DIR/run/standby-frontlight" ]]; then
      frontlight_snapshot=$(cat "$STATE_DIR/run/standby-frontlight") || exit 66
    else
      frontlight_snapshot=none
    fi
    standby_requests=$((standby_requests + 1))
    suspended=1
    save
    printf '%s\n' "$receipt"
    ;;
  *'kill -KILL'*)
    [[ "$app" == dev.pluto.ink ]]
    ink_pid=none
    pid=$home_pid
    app=dev.pluto.launcher
    seq=$((home_seq + 1))
    mono=$((mono + 1000))
    home_seq=$seq
    home_mono=$mono
    crashed=1
    save
    ;;
  *)
    echo "unexpected fake ssh command: $command" >&2
    exit 65
    ;;
esac
EOF
chmod 0755 "$TMP/bin/ssh"

cat > "$TMP/camera-binding.json" <<'JSON'
{"devices":[{"number":2,"profile_id":"rm2"}]}
JSON

reset_state() {
  local dir="$1" profile_id="${2:-rm1}" frontlight=''
  mkdir -p "$dir/rtc0" "$dir/run"
  if [[ "$profile_id" == move ]]; then
    frontlight="$dir/frontlight"
    printf '913\n' > "$frontlight"
  fi
  cat > "$dir/device-profiles.sh" <<EOF
pluto_profile_probe() {
  PLUTO_PROFILE_ID='$profile_id'
  PLUTO_PROFILE_FRONTLIGHT_BRIGHTNESS='$frontlight'
  export PLUTO_PROFILE_ID PLUTO_PROFILE_FRONTLIGHT_BRIGHTNESS
}
EOF
  printf '100000\n' > "$dir/rtc0/since_epoch"
  : > "$dir/rtc0/wakealarm"
  : > "$dir/wake-receipts"
  cat > "$dir/state" <<EOF
unit=xochitl.service
supervisor=100
boot=11111111-2222-3333-4444-555555555555
pid=200
app=dev.pluto.ink
seq=10
mono=10000
wakes=0
revision=$REVISION
profile=$profile_id
suspended=0
crashed=0
pending_progress=0
ink_pid=200
ink_start=2000
ink_launch=ink-launch
ink_seq=10
ink_mono=10000
home_pid=300
home_start=3000
home_launch=home-launch
home_seq=20
home_mono=20000
frontlight_snapshot=unset
standby_requests=0
EOF
}

run_smoke() {
  local mode="$1" dir="$2"
  STATE_DIR="$dir" FIXTURE_MODE="$mode" PATH="$TMP/bin:$PATH" \
  PNG_FIXTURE_DIR="$TMP/png" \
  RTC_FIXTURE_MODE="${RTC_FIXTURE_MODE:-normal}" \
  WAKE_FIXTURE_MODE="${WAKE_FIXTURE_MODE:-rtc}" \
  PUBLICATION_FIXTURE_MODE="${PUBLICATION_FIXTURE_MODE:-normal}" \
  SLEEP_LOG="${SLEEP_LOG:-}" \
  PLUTO_TEST_NO_SLEEP="${PLUTO_TEST_NO_SLEEP:-0}" \
  PLUTO_CLI=pluto \
  PLUTO_ACCEPTANCE_RELEASE_REVISION="$REVISION" \
  PLUTO_ACCEPTANCE_PROFILE_ID="${ACCEPTANCE_PROFILE_ID:-rm1}" \
  PLUTO_LIFECYCLE_CYCLES="${ACCEPTANCE_CYCLES:-1}" \
  PLUTO_LIFECYCLE_WAKE_SECONDS=60 \
  PLUTO_LIFECYCLE_DOWN_TIMEOUT=2 \
  PLUTO_LIFECYCLE_UP_TIMEOUT=2 \
  PLUTO_LIFECYCLE_CRASH_SETTLE_SECONDS=0 \
  PLUTO_ACCEPTANCE_STAGE_DELAY=0 \
  PLUTO_ACCEPTANCE_SSH_TARGET="${ACCEPTANCE_SSH_TARGET:-root@fixture-device}" \
  PLUTO_ACCEPTANCE_SSH_PORT="${ACCEPTANCE_SSH_PORT:-}" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS="${ACCEPTANCE_ALLOW_TEST_HOOKS:-0}" \
    "$SMOKE" "${ACCEPTANCE_DEVICE:-root@fixture-device}"
}

if PLUTO_LIFECYCLE_WAKE_SECONDS=18 \
  "$SMOKE" root@fixture-device >/dev/null 2>"$TMP/short-alarm.err"; then
  fail 'legacy 18-second lifecycle alarm was accepted'
fi
grep -q 'wake seconds must be in \[60,120\]' "$TMP/short-alarm.err" ||
  fail 'legacy alarm rejection did not report the safe minimum'

reset_state "$TMP/pass"
PLUTO_LIFECYCLE_CRASH_TEST=1 run_smoke normal "$TMP/pass" > "$TMP/pass.out"
grep -q 'PASS cycles=1 crash_test=1' "$TMP/pass.out" ||
  fail 'same-process warm resume and crash recovery did not pass'
grep -Eq \
  'requested cleared=1 rtc_now=[0-9]+ system_now=[0-9]+ clock_delta=-?[0-9]+ accepted=[0-9]+ arm_margin=60 publish_rtc=[0-9]+ publish_margin=60 frontlight=none' \
  "$TMP/pass.out" || fail 'RTC clock, accepted-alarm, and margin evidence was not emitted'
grep -Eq \
  'PASS cycle=1 .* wake_epoch=100060 accepted=100060 transport_down_observed=1' \
  "$TMP/pass.out" ||
  fail 'exact wake receipt and observed transport loss were not retained as evidence'
. "$TMP/pass/state"
[[ "$frontlight_snapshot" == none && "$standby_requests" == 1 &&
  "$(tr '\n' ',' < "$TMP/pass/publish-order")" == 'standby,' &&
  "$(cat "$TMP/pass/run/standby")" == 'release-lifecycle-cycle-1' ]] ||
  fail 'RM1 lifecycle fixture did not publish the exact marker-only transaction'

reset_state "$TMP/rm2" rm2
ACCEPTANCE_PROFILE_ID=rm2 PLUTO_LIFECYCLE_CRASH_TEST=0 \
  run_smoke normal "$TMP/rm2" >/dev/null ||
  fail 'RM2 lifecycle fixture no longer passes the common standby flow'
. "$TMP/rm2/state"
[[ "$frontlight_snapshot" == none && "$standby_requests" == 1 &&
  "$(tr '\n' ',' < "$TMP/rm2/publish-order")" == 'standby,' &&
  "$(cat "$TMP/rm2/run/standby")" == 'release-lifecycle-cycle-1' ]] ||
  fail 'RM2 lifecycle fixture did not publish the exact marker-only transaction'

reset_state "$TMP/move" move
ACCEPTANCE_PROFILE_ID=move PLUTO_LIFECYCLE_CRASH_TEST=0 \
  run_smoke normal "$TMP/move" > "$TMP/move.out" ||
  fail 'Move lifecycle fixture no longer passes the common standby flow'
grep -q 'frontlight=913' "$TMP/move.out" ||
  fail 'Move lifecycle receipt omitted the profile-selected frontlight snapshot'
. "$TMP/move/state"
[[ "$frontlight_snapshot" == 913 && "$standby_requests" == 1 &&
  "$(tr '\n' ',' < "$TMP/move/publish-order")" == \
    'frontlight,standby,' &&
  "$(cat "$TMP/move/run/standby")" == 'release-lifecycle-cycle-1' ]] ||
  fail 'Move brightness was not visibly published before the exact standby marker'

reset_state "$TMP/missing-marker"
if PUBLICATION_FIXTURE_MODE=missing-marker PLUTO_TEST_NO_SLEEP=1 \
  PLUTO_LIFECYCLE_CRASH_TEST=0 \
  run_smoke normal "$TMP/missing-marker" >/dev/null \
    2>"$TMP/missing-marker.err"; then
  fail 'missing final standby publication passed lifecycle acceptance'
fi
grep -q 'could not arm RTC and request standby' "$TMP/missing-marker.err" ||
  fail 'missing standby publication did not fail the arming transaction'
. "$TMP/missing-marker/state"
[[ "$suspended" == 0 && "$standby_requests" == 0 &&
  ! -e "$TMP/missing-marker/run/standby" ]] ||
  fail 'fixture simulated suspend without an exact published standby marker'

reset_state "$TMP/missing-frontlight" move
if ACCEPTANCE_PROFILE_ID=move PUBLICATION_FIXTURE_MODE=missing-frontlight \
  PLUTO_TEST_NO_SLEEP=1 PLUTO_LIFECYCLE_CRASH_TEST=0 \
  run_smoke normal "$TMP/missing-frontlight" >/dev/null \
    2>"$TMP/missing-frontlight.err"; then
  fail 'missing Move frontlight publication passed lifecycle acceptance'
fi
grep -q 'could not arm RTC and request standby' \
  "$TMP/missing-frontlight.err" ||
  fail 'missing Move frontlight publication did not fail before standby'
. "$TMP/missing-frontlight/state"
[[ "$suspended" == 0 && "$standby_requests" == 0 &&
  ! -e "$TMP/missing-frontlight/run/standby" ]] ||
  fail 'fixture suspended Move without a published frontlight snapshot'

reset_state "$TMP/marker-first" move
if ACCEPTANCE_PROFILE_ID=move PUBLICATION_FIXTURE_MODE=marker-first \
  PLUTO_TEST_NO_SLEEP=1 PLUTO_LIFECYCLE_CRASH_TEST=0 \
  run_smoke normal "$TMP/marker-first" >/dev/null \
    2>"$TMP/marker-first.err"; then
  fail 'Move marker-first publication order passed lifecycle acceptance'
fi
grep -q 'could not arm RTC and request standby' "$TMP/marker-first.err" ||
  fail 'Move marker-first order did not fail before standby publication'
. "$TMP/marker-first/state"
[[ "$suspended" == 0 && "$standby_requests" == 0 &&
  ! -e "$TMP/marker-first/run/standby" &&
  ! -e "$TMP/marker-first/run/standby-frontlight" ]] ||
  fail 'fixture suspended before Move frontlight publication became visible'

reset_state "$TMP/dwell"
: > "$TMP/dwell-sleeps"
SLEEP_LOG="$TMP/dwell-sleeps" PLUTO_TEST_NO_SLEEP=1 ACCEPTANCE_CYCLES=2 \
  PLUTO_LIFECYCLE_CRASH_TEST=0 run_smoke normal "$TMP/dwell" >/dev/null ||
  fail 'two-cycle lifecycle dwell fixture did not pass'
[[ "$(grep -c '^3$' "$TMP/dwell-sleeps")" == 1 ]] ||
  fail 'multi-cycle lifecycle flow did not dwell once between two wakes'

reset_state "$TMP/rtc-reachable"
WAKE_FIXTURE_MODE=rtc-reachable PLUTO_TEST_NO_SLEEP=1 \
  PLUTO_LIFECYCLE_CRASH_TEST=0 \
  run_smoke normal "$TMP/rtc-reachable" > "$TMP/rtc-reachable.out" ||
  fail 'on-time RTC wake failed when slow SSH never observed transport loss'
grep -Eq \
  'PASS cycle=1 .* wake_epoch=100060 accepted=100060 transport_down_observed=0' \
  "$TMP/rtc-reachable.out" ||
  fail 'reachable on-time RTC wake omitted its exact receipt evidence'

reset_state "$TMP/early-delayed"
if WAKE_FIXTURE_MODE=early-delayed PLUTO_TEST_NO_SLEEP=1 \
  PLUTO_LIFECYCLE_CRASH_TEST=0 \
  run_smoke normal "$TMP/early-delayed" >/dev/null \
    2>"$TMP/early-delayed.err"; then
  fail 'early external wake passed after delayed SSH observation'
fi
grep -q \
  'completed suspend early before the armed RTC deadline (wake_epoch=100030 accepted=100060 tolerance=2 wake_receipts=1)' \
  "$TMP/early-delayed.err" ||
  fail 'delayed observation did not retain the supervisor early-wake epoch'
[[ "$(cat "$TMP/early-delayed/rtc0/since_epoch")" == 100090 ]] ||
  fail 'early-wake fixture did not delay observation past the alarm epoch'

reset_state "$TMP/late-delayed"
if WAKE_FIXTURE_MODE=late-delayed PLUTO_TEST_NO_SLEEP=1 \
  PLUTO_LIFECYCLE_CRASH_TEST=0 \
  run_smoke normal "$TMP/late-delayed" >/dev/null \
    2>"$TMP/late-delayed.err"; then
  fail 'materially late wake passed after delayed SSH observation'
fi
grep -q \
  'completed suspend late after the armed RTC deadline (wake_epoch=100090 accepted=100060 tolerance=2 wake_receipts=1)' \
  "$TMP/late-delayed.err" ||
  fail 'delayed observation did not retain the supervisor late-wake epoch'
[[ "$(cat "$TMP/late-delayed/rtc0/since_epoch")" == 100120 ]] ||
  fail 'late-wake fixture did not delay observation beyond its wake receipt'

reset_state "$TMP/malformed-wake-receipt"
if WAKE_FIXTURE_MODE=malformed PLUTO_TEST_NO_SLEEP=1 \
  PLUTO_LIFECYCLE_CRASH_TEST=0 \
  run_smoke normal "$TMP/malformed-wake-receipt" >/dev/null \
    2>"$TMP/malformed-wake-receipt.err"; then
  fail 'malformed supervisor wake epoch passed lifecycle acceptance'
fi
grep -q 'returned malformed post-wake progress evidence' \
  "$TMP/malformed-wake-receipt.err" ||
  fail 'malformed supervisor wake epoch did not fail closed'

reset_state "$TMP/missing-wake-receipt"
if WAKE_FIXTURE_MODE=missing PLUTO_TEST_NO_SLEEP=1 \
  PLUTO_LIFECYCLE_CRASH_TEST=0 \
  run_smoke normal "$TMP/missing-wake-receipt" >/dev/null \
    2>"$TMP/missing-wake-receipt.err"; then
  fail 'missing supervisor wake receipt passed lifecycle acceptance'
fi
grep -q 'did not publish its completed suspend receipt after transport loss' \
  "$TMP/missing-wake-receipt.err" ||
  fail 'missing supervisor wake receipt did not fail closed'

reset_state "$TMP/never-suspended"
if WAKE_FIXTURE_MODE=never PLUTO_TEST_NO_SLEEP=1 \
  PLUTO_LIFECYCLE_CRASH_TEST=0 \
  run_smoke normal "$TMP/never-suspended" >/dev/null \
    2>"$TMP/never-suspended.err"; then
  fail 'device with no transport loss or completed wake receipt passed'
fi
grep -q \
  'never became unreachable and published no completed suspend receipt' \
  "$TMP/never-suspended.err" ||
  fail 'never-suspended device was confused with an early completed wake'

reset_state "$TMP/expired"
if RTC_FIXTURE_MODE=expired PLUTO_LIFECYCLE_CRASH_TEST=0 \
  run_smoke normal "$TMP/expired" >/dev/null 2>"$TMP/expired.err"; then
  fail 'expired RTC alarm passed lifecycle standby acceptance'
fi
grep -q 'could not arm RTC and request standby' "$TMP/expired.err" ||
  fail 'expired RTC alarm did not fail at standby publication'
[[ ! -e "$TMP/expired/run/standby" ]] ||
  fail 'expired RTC alarm published a standby marker'
. "$TMP/expired/state"
[[ "$frontlight_snapshot" == unset ]] ||
  fail 'expired RTC alarm published frontlight state'

reset_state "$TMP/uncleared"
if RTC_FIXTURE_MODE=uncleared PLUTO_LIFECYCLE_CRASH_TEST=0 \
  run_smoke normal "$TMP/uncleared" >/dev/null 2>"$TMP/uncleared.err"; then
  fail 'uncleared prior RTC alarm passed lifecycle standby acceptance'
fi
grep -q 'could not arm RTC and request standby' "$TMP/uncleared.err" ||
  fail 'uncleared RTC alarm did not fail before standby publication'
[[ ! -e "$TMP/uncleared/run/standby" ]] ||
  fail 'uncleared RTC alarm published a standby marker'

for camera_mismatch in '2|rm1' '3|rm2'; do
  IFS='|' read -r camera_rig camera_profile <<< "$camera_mismatch"
  error_file="$TMP/lifecycle-camera-$camera_rig-$camera_profile.err"
  if PATH="$TMP/bin:$PATH" PLUTO_CLI=pluto \
    PLUTO_ACCEPTANCE_RELEASE_REVISION="$REVISION" \
    PLUTO_ACCEPTANCE_PROFILE_ID="$camera_profile" \
    PLUTO_ACCEPTANCE_STAGE_HOOK="$ROOT/tools/setup/camera/capture-acceptance-stage.sh" \
    PLUTO_CAMERA_CONFIG="$TMP/camera-binding.json" \
    PLUTO_CAMERA_RIG="$camera_rig" \
    PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/lifecycle-camera-$camera_rig-$camera_profile" \
    PLUTO_LIFECYCLE_CYCLES=1 PLUTO_LIFECYCLE_WAKE_SECONDS=60 \
    "$SMOKE" root@fixture-device >/dev/null 2>"$error_file"; then
    fail "lifecycle smoke accepted camera mismatch $camera_mismatch"
  fi
  grep -q 'selected camera rig is not bound' "$error_file" ||
    fail "lifecycle camera mismatch did not fail at profile binding: $camera_mismatch"
done

reset_state "$TMP/ipv4"
ACCEPTANCE_DEVICE=root@127.0.0.1:2222 \
  ACCEPTANCE_SSH_TARGET=root@127.0.0.1 ACCEPTANCE_SSH_PORT=2222 \
  PLUTO_LIFECYCLE_CRASH_TEST=0 run_smoke normal "$TMP/ipv4" >/dev/null ||
  fail 'lifecycle smoke rejected equal explicit IPv4 endpoints'

reset_state "$TMP/ipv6"
ACCEPTANCE_DEVICE='root@[fe80::1%en7]' \
  ACCEPTANCE_SSH_TARGET='root@fe80::1%en7' \
  PLUTO_LIFECYCLE_CRASH_TEST=0 run_smoke normal "$TMP/ipv6" >/dev/null ||
  fail 'lifecycle smoke rejected equivalent bracketed/raw IPv6 endpoints'

mismatch_index=0
for mismatch in \
  'root@device|admin@device|22' \
  'root@device|root@other-device|22' \
  'root@device:2222|root@device|22'; do
  mismatch_index=$((mismatch_index + 1))
  reset_state "$TMP/mismatch-$mismatch_index"
  IFS='|' read -r cli_endpoint ssh_endpoint ssh_port <<< "$mismatch"
  if ACCEPTANCE_DEVICE="$cli_endpoint" ACCEPTANCE_SSH_TARGET="$ssh_endpoint" \
    ACCEPTANCE_SSH_PORT="$ssh_port" PLUTO_LIFECYCLE_CRASH_TEST=0 \
    run_smoke normal "$TMP/mismatch-$mismatch_index" >/dev/null 2>&1; then
    fail "lifecycle smoke accepted split endpoint identity: $mismatch"
  fi
done

reset_state "$TMP/test-divergence"
ACCEPTANCE_DEVICE=root@device ACCEPTANCE_SSH_TARGET=root@test-double \
  ACCEPTANCE_ALLOW_TEST_HOOKS=1 PLUTO_LIFECYCLE_CRASH_TEST=0 \
  run_smoke normal "$TMP/test-divergence" >"$TMP/test-divergence.out" ||
  fail 'explicit test seam did not allow lifecycle split-device fixtures'
grep -q 'TEST_EVIDENCE test_seam=1.*endpoint_divergent=1' \
  "$TMP/test-divergence.out" ||
  fail 'split lifecycle endpoint was not visibly marked as test evidence'

reset_state "$TMP/no-pixels"
if NO_STROKE_CHANGE=1 PLUTO_LIFECYCLE_CRASH_TEST=0 \
  run_smoke normal "$TMP/no-pixels" >/dev/null 2>&1; then
  fail 're-encoded unchanged Ink pixels passed lifecycle stroke acceptance'
fi

reset_state "$TMP/cold"
if PLUTO_LIFECYCLE_CRASH_TEST=0 run_smoke cold "$TMP/cold" >/dev/null 2>&1; then
  fail 'cold Home fallback/replaced foreground PID passed as warm resume'
fi

reset_state "$TMP/stale"
if PLUTO_LIFECYCLE_CRASH_TEST=0 run_smoke stale "$TMP/stale" >/dev/null 2>&1; then
  fail 'stale health sequence and monotonic receipt passed resume'
fi

reset_state "$TMP/reused"
if PLUTO_LIFECYCLE_CRASH_TEST=0 run_smoke reused "$TMP/reused" >/dev/null 2>&1; then
  fail 'reused numeric PID with changed process start ticks passed warm resume'
fi

reset_state "$TMP/relaunch"
if PLUTO_LIFECYCLE_CRASH_TEST=0 run_smoke relaunch "$TMP/relaunch" >/dev/null 2>&1; then
  fail 'changed launch-specific ready and health paths passed warm resume'
fi

reset_state "$TMP/revision"
if STATE_DIR="$TMP/revision" FIXTURE_MODE=normal PATH="$TMP/bin:$PATH" \
  PLUTO_CLI=pluto \
  PLUTO_ACCEPTANCE_RELEASE_REVISION=ffffffffffffffffffffffffffffffffffffffff \
  PLUTO_ACCEPTANCE_PROFILE_ID=rm1 \
  PLUTO_LIFECYCLE_CYCLES=1 PLUTO_LIFECYCLE_WAKE_SECONDS=60 \
  PLUTO_LIFECYCLE_DOWN_TIMEOUT=2 PLUTO_LIFECYCLE_UP_TIMEOUT=2 \
  PLUTO_LIFECYCLE_CRASH_TEST=0 \
  "$SMOKE" root@fixture-device >/dev/null 2>&1; then
  fail 'wrong installed release revision passed the lifecycle gate'
fi

echo 'release-lifecycle-hardware-smoke_test: PASS'
