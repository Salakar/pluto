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
STATE
}
case "$command" in
  *'proc_start_ticks()'*)
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
    ;;
  *'release-lifecycle-stroke'*)
    seq=$((seq + 1))
    mono=$((mono + 1000))
    ink_seq=$seq
    ink_mono=$mono
    save
    ;;
  *'wakealarm'*)
    suspended=1
    save
    printf 'alarm=123456\n'
    ;;
  true)
    if [[ "$suspended" == 1 ]]; then
      suspended=0
      wakes=$((wakes + 1))
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
      esac
      save
      exit 1
    fi
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
  local dir="$1"
  mkdir -p "$dir"
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
profile=rm1
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
EOF
}

run_smoke() {
  local mode="$1" dir="$2"
  STATE_DIR="$dir" FIXTURE_MODE="$mode" PATH="$TMP/bin:$PATH" \
  PNG_FIXTURE_DIR="$TMP/png" \
  PLUTO_CLI=pluto \
  PLUTO_ACCEPTANCE_RELEASE_REVISION="$REVISION" \
  PLUTO_ACCEPTANCE_PROFILE_ID=rm1 \
  PLUTO_LIFECYCLE_CYCLES=1 \
  PLUTO_LIFECYCLE_WAKE_SECONDS=12 \
  PLUTO_LIFECYCLE_DOWN_TIMEOUT=2 \
  PLUTO_LIFECYCLE_UP_TIMEOUT=2 \
  PLUTO_LIFECYCLE_CRASH_SETTLE_SECONDS=0 \
  PLUTO_ACCEPTANCE_STAGE_DELAY=0 \
  PLUTO_ACCEPTANCE_SSH_TARGET="${ACCEPTANCE_SSH_TARGET:-root@fixture-device}" \
  PLUTO_ACCEPTANCE_SSH_PORT="${ACCEPTANCE_SSH_PORT:-}" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS="${ACCEPTANCE_ALLOW_TEST_HOOKS:-0}" \
    "$SMOKE" "${ACCEPTANCE_DEVICE:-root@fixture-device}"
}

reset_state "$TMP/pass"
PLUTO_LIFECYCLE_CRASH_TEST=1 run_smoke normal "$TMP/pass" > "$TMP/pass.out"
grep -q 'PASS cycles=1 crash_test=1' "$TMP/pass.out" ||
  fail 'same-process warm resume and crash recovery did not pass'

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
    PLUTO_LIFECYCLE_CYCLES=1 PLUTO_LIFECYCLE_WAKE_SECONDS=12 \
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
  PLUTO_LIFECYCLE_CYCLES=1 PLUTO_LIFECYCLE_WAKE_SECONDS=12 \
  PLUTO_LIFECYCLE_DOWN_TIMEOUT=2 PLUTO_LIFECYCLE_UP_TIMEOUT=2 \
  PLUTO_LIFECYCLE_CRASH_TEST=0 \
  "$SMOKE" root@fixture-device >/dev/null 2>&1; then
  fail 'wrong installed release revision passed the lifecycle gate'
fi

echo 'release-lifecycle-hardware-smoke_test: PASS'
