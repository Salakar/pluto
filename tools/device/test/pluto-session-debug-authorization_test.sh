#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SUPERVISOR="$HERE/../pluto-session.sh"
PROFILE_FILE="$HERE/../generated/device-profiles.sh"
TMP=${TMPDIR:-/tmp}/pluto-session-debug-authorization-test.$$
ROOT="$TMP/root"
CTL="$TMP/run"
MOVE_WAVEFORM=/usr/share/remarkable/GAL3_AAB0AM_IC0801_AC073MC1F2_AD1004-GCA_TC.eink
MOVE_BASE_OPTIONS=exact_color=1,enable_rails=1,vcom=-0.62,du_mode=7,dither=1,settle_delay_ms=0,full_refresh_every=0
SESSION_PID=""

cleanup() {
  [ -z "$SESSION_PID" ] || kill "$SESSION_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup 0

fail() {
  echo "debug authorization supervisor test: $*" >&2
  [ ! -f "$TMP/session.log" ] || cat "$TMP/session.log" >&2
  [ ! -f "$TMP/invocations" ] || sed -n 'l' "$TMP/invocations" >&2
  exit 1
}

mkdir -p \
  "$TMP/bin" \
  "$ROOT/bin" \
  "$ROOT/engine/debug" \
  "$ROOT/engine/release" \
  "$ROOT/launcher/bundle/lib" \
  "$ROOT/apps/dev.example.debug/bundle/flutter_assets" \
  "$ROOT/apps/dev.example.release/bundle/lib" \
  "$ROOT/logs" \
  "$ROOT/state" \
  "$TMP/lpgpr" \
  "$CTL"
: > "$ROOT/engine/debug/libflutter_engine.so"
: > "$ROOT/engine/release/libflutter_engine.so"
: > "$ROOT/launcher/bundle/lib/app.so"
: > "$ROOT/launcher/bundle/icudtl.dat"
: > "$ROOT/apps/dev.example.debug/bundle/flutter_assets/kernel_blob.bin"
: > "$ROOT/apps/dev.example.debug/bundle/icudtl.dat"
: > "$ROOT/apps/dev.example.release/bundle/lib/app.so"
: > "$ROOT/apps/dev.example.release/bundle/icudtl.dat"
cat > "$ROOT/launcher/manifest.json" <<'JSON'
{"display":{"orientations":["portrait","portraitDown","landscapeLeft","landscapeRight"],"defaultOrientation":"portrait"}}
JSON
cat > "$ROOT/apps/dev.example.release/manifest.json" <<'JSON'
{"display":{"orientations":["portrait"],"defaultOrientation":"portrait"}}
JSON
printf '100.0 0.0\n' > "$TMP/uptime"
printf 'a\n' > "$TMP/lpgpr/root_part"
printf '2\n' > "$TMP/lpgpr/roota_errcnt"

cat > "$TMP/bin/systemctl" <<'SYSTEMCTL'
#!/bin/sh
exit 0
SYSTEMCTL

cat > "$TMP/bin/xochitl" <<'XOCHITL'
#!/bin/sh
printf '%s\n' "$$" > "$PLUTO_TEST_STOCK_PID"
printf '%s\n' "$MALLOC_ARENA_MAX $*" > "$PLUTO_TEST_STOCK_ARGS"
exit 0
XOCHITL

cat > "$TMP/bin/reset-boot-count" <<'RESET_BOOT_COUNT'
#!/bin/sh
count=$(cat "$PLUTO_TEST_BOOT_CONFIRM_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$PLUTO_TEST_BOOT_CONFIRM_COUNT"
part=$(cat "$PLUTO_TEST_RECOVERY_COUNTER_DIR/root_part")
printf '0\n' > "$PLUTO_TEST_RECOVERY_COUNTER_DIR/root${part}_errcnt"
RESET_BOOT_COUNT
: > "$TMP/zz-pluto.conf"
cat > "$TMP/boot-recovery.conf" <<EOF
PLUTO_RECOVERY_SCHEMA='1'
PLUTO_RECOVERY_PROFILE_ID='move'
PLUTO_RECOVERY_CONFIRMATION_STRATEGY='lpgpr_counter'
PLUTO_RECOVERY_FAILURE_STRATEGY='unverified'
PLUTO_RECOVERY_BOOT_DEFAULT_ENABLED='0'
PLUTO_RECOVERY_MMC_DEVICE=''
PLUTO_RECOVERY_ROOT_PARTITIONS=''
PLUTO_RECOVERY_BOOT_LIMIT=''
PLUTO_RECOVERY_HELPER='$TMP/bin/reset-boot-count'
PLUTO_RECOVERY_COUNTER_DIR='$TMP/lpgpr'
EOF

cat > "$ROOT/bin/pluto-embedder" <<'EMBEDDER'
#!/bin/sh
printf '%s %s\n' "$PLUTO_APP_ID" "$*" >> "$PLUTO_TEST_INVOCATIONS"
for arg in "$@"; do
  case "$arg" in
    --ready-file=*)
      ready_file="${arg#*=}"
      printf 'ready\n' > "$ready_file"
      ;;
  esac
done
case "$PLUTO_APP_ID" in
  dev.pluto.launcher)
    count=$(cat "$PLUTO_TEST_LAUNCHER_COUNT" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$PLUTO_TEST_LAUNCHER_COUNT"
    case "$count" in
      1) printf 'dev.example.debug\n' > "$PLUTO_RUN_DIR/launch" ;;
      2) printf 'dev.example.debug\n' > "$PLUTO_RUN_DIR/debug-launch" ;;
      3) printf 'dev.example.release\n' > "$PLUTO_RUN_DIR/launch" ;;
      *) : > "$PLUTO_RUN_DIR/stock" ;;
    esac
    ;;
  dev.example.debug)
    # Try to relaunch through the ordinary marker. The one-shot permission
    # must already be consumed, so this second attempt is refused.
    printf 'dev.example.debug\n' > "$PLUTO_RUN_DIR/launch"
    ;;
  dev.example.release)
    : > "$PLUTO_RUN_DIR/stock"
    ;;
  *) exit 99 ;;
esac
EMBEDDER
chmod +x "$TMP/bin/systemctl" "$TMP/bin/xochitl" \
  "$TMP/bin/reset-boot-count" "$ROOT/bin/pluto-embedder"

PATH="$TMP/bin:$PATH" \
PLUTO_ROOT="$ROOT" \
PLUTO_PROFILE_FILE="$PROFILE_FILE" \
PLUTO_TESTING=1 \
PLUTO_TEST_PROFILE_ID=move \
PLUTO_RUN_DIR="$CTL" \
PLUTO_BOOT_DROPIN="$TMP/zz-pluto.conf" \
PLUTO_STOCK_XOCHITL="$TMP/bin/xochitl" \
PLUTO_BOOT_CONFIRM_DISPATCHER="$HERE/../pluto-boot-confirm.sh" \
PLUTO_BOOT_RECOVERY_CONFIG="$TMP/boot-recovery.conf" \
PLUTO_TEST_RECOVERY_HELPER="$TMP/bin/reset-boot-count" \
PLUTO_TEST_RECOVERY_COUNTER_DIR="$TMP/lpgpr" \
PLUTO_BOOT_CONFIRM_DELAY=0 \
PLUTO_BOOT_CONFIRM_TIMEOUT=2 \
PLUTO_POWER_WATCHER="$ROOT/bin/missing-power-watcher" \
PLUTO_UPTIME_FILE="$TMP/uptime" \
PLUTO_TEST_INVOCATIONS="$TMP/invocations" \
PLUTO_TEST_LAUNCHER_COUNT="$TMP/launcher-count" \
PLUTO_TEST_STOCK_PID="$TMP/stock-pid" \
PLUTO_TEST_STOCK_ARGS="$TMP/stock-args" \
PLUTO_TEST_BOOT_CONFIRM_COUNT="$TMP/boot-confirm-count" \
  sh "$SUPERVISOR" start > "$TMP/session.log" 2>&1 &
SESSION_PID=$!
EXPECTED_STOCK_PID=$SESSION_PID

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
  21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 \
  41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
  kill -0 "$SESSION_PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$SESSION_PID" 2>/dev/null; then
  fail "supervisor did not finish the launch sequence"
fi
wait "$SESSION_PID" || fail "supervisor returned failure"
SESSION_PID=""

[ "$(grep -c '^dev.pluto.launcher ' "$TMP/invocations")" -eq 3 ] ||
  fail "expected three launcher handoffs"
[ "$(grep -c '^dev.example.debug .*--debug' "$TMP/invocations")" -eq 1 ] ||
  fail "debug embedder must run exactly once for the explicit authorization"
[ "$(grep -c '^dev.example.release .*--release' "$TMP/invocations")" -eq 1 ] ||
  fail "ordinary release AOT launch changed unexpectedly"
grep -q '^dev.pluto.launcher .*--rotation=0 .*--allowed-rotations=0,180,90,270 .*--auto-rotate' "$TMP/invocations" ||
  fail "launcher did not receive its four-orientation Auto policy"
grep -q '^dev.example.release .*--rotation=0 .*--allowed-rotations=0 ' "$TMP/invocations" ||
  fail "portrait-only app did not clamp the device orientation policy"
if grep '^dev.example.release ' "$TMP/invocations" | grep -q -- '--auto-rotate'; then
  fail "portrait-only app incorrectly enabled auto rotation"
fi
grep '^dev.pluto.launcher ' "$TMP/invocations" | grep -q -- '--bezel-redraw' ||
  fail "launcher did not receive the in-place bezel redraw gesture"
grep '^dev.pluto.launcher ' "$TMP/invocations" | grep -q -- '--presenter=native' ||
  fail "launcher did not use the common native presenter"
grep '^dev.pluto.launcher ' "$TMP/invocations" | grep -Fq -- \
  "--presenter-options=$MOVE_BASE_OPTIONS,eink=$MOVE_WAVEFORM" ||
  fail "Move launch did not bind the verified waveform through its generated key"
grep '^dev.pluto.launcher ' "$TMP/invocations" | grep -q -- \
  '--touch-device=/dev/input/by-path/platform-44360000.spi-cs-0-event ' ||
  fail "launcher did not receive the profile-selected touch device"
grep '^dev.pluto.launcher ' "$TMP/invocations" | grep -q -- \
  '--pen-device=/dev/input/by-path/platform-44360000.spi-cs-0-event-mouse ' ||
  fail "launcher did not receive the profile-selected pen device"
if grep -q -- '--presenter=swtcon' "$TMP/invocations"; then
  fail "retired Move-specific presenter name is still present"
fi
grep '^dev.example.release ' "$TMP/invocations" | grep -q -- '--bezel-redraw' ||
  fail "ordinary apps did not receive the in-place bezel redraw gesture"
if grep -q -- '--home-tap' "$TMP/invocations"; then
  fail "retired bezel Home wiring is still present"
fi
[ "$(grep -c "is a debug/JIT install; use 'pluto run --debug dev.example.debug'" "$TMP/session.log")" -eq 2 ] ||
  fail "ordinary debug launch attempts were not both refused"
grep -q 'explicit debug/JIT authorization' "$TMP/session.log" ||
  fail "explicit debug control was not consumed"
[ ! -e "$CTL/debug-launch" ] ||
  fail "one-shot debug authorization remained after consumption"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -f "$ROOT/state/boot-confirmed" ] && break
  sleep 0.1
done
[ "$(cat "$TMP/boot-confirm-count")" -eq 1 ] ||
  fail "vendor boot confirmation did not run exactly once"
[ "$(cat "$TMP/lpgpr/roota_errcnt")" -eq 0 ] ||
  fail "vendor boot confirmation did not reset the selected root counter"
grep -q '^state=confirmed/part=a/counter=roota_errcnt confirmed_at=' \
  "$ROOT/state/boot-confirmed" ||
  fail "verified boot confirmation receipt was not recorded"
[ "$(cat "$TMP/stock-pid")" -eq "$EXPECTED_STOCK_PID" ] ||
  fail "stock xochitl did not replace the boot-first supervisor process"
[ "$(cat "$TMP/stock-args")" = '8 --system' ] ||
  fail "stock xochitl did not receive the firmware service environment/arguments"

echo "debug authorization supervisor test: PASS"
