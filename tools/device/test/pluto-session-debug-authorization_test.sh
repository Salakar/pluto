#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SUPERVISOR="$HERE/../pluto-session.sh"
PROFILE_FILE="$HERE/../generated/device-profiles.sh"
TMP=${TMPDIR:-/tmp}/pluto-session-debug-authorization-test.$$
ROOT="$TMP/root"
CTL="$TMP/run"
MOVE_WAVEFORM=/usr/share/remarkable/GAL3_AAB0AM_IC0801_AC073MC1F2_AD1004-GCA_TC.eink
MOVE_BASE_OPTIONS=exact_color=1,enable_rails=1,vcom=-0.62
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

[ -x "$SUPERVISOR" ] || fail "session supervisor is not executable"

mkdir -p \
  "$TMP/bin" \
  "$ROOT/bin" \
  "$ROOT/engine/debug" \
  "$ROOT/engine/release" \
  "$ROOT/launcher/bundle/lib" \
  "$ROOT/apps/dev.example.debug/bundle/flutter_assets" \
  "$ROOT/apps/dev.example.release/bundle/lib" \
  "$ROOT/apps/dev.pluto.codex/bundle/lib" \
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
: > "$ROOT/apps/dev.pluto.codex/bundle/lib/app.so"
: > "$ROOT/apps/dev.pluto.codex/bundle/icudtl.dat"
: > "$ROOT/bin/codex"
cat > "$ROOT/launcher/manifest.json" <<'JSON'
{"display":{"orientations":["portrait","portraitDown","landscapeLeft","landscapeRight"],"defaultOrientation":"portrait"}}
JSON
cat > "$ROOT/apps/dev.example.release/manifest.json" <<'JSON'
{"display":{"orientations":["portrait"],"defaultOrientation":"portrait"}}
JSON
cat > "$ROOT/apps/dev.pluto.codex/manifest.json" <<'JSON'
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

cat > "$TMP/bin/boot-recovery" <<'BOOT_RECOVERY'
#!/bin/sh
printf '%s\n' "$*" >> "$PLUTO_TEST_RECOVERY_LOG"
case "$1" in
  bind)
    [ "$2" = move ] && [ "$3" -gt 1 ] || exit 64
    printf 'attempt-nonce\n'
    ;;
  foreground)
    [ "$2" = move ] && [ "$5" = attempt-nonce ] || exit 64
    case "$6:$7" in
      *'/boot-ready.attempt-nonce.'*:*'/health.attempt-nonce.'*) ;;
      *) exit 64 ;;
    esac
    if [ -f "$PLUTO_TEST_RECOVERY_CONFIRMED" ]; then
      printf 'state=confirmed/app=%s\n' "$4"
    else
      printf 'state=pending/app=%s\n' "$4"
    fi
    ;;
  confirm)
    count=$(cat "$PLUTO_TEST_BOOT_CONFIRM_COUNT" 2>/dev/null || echo 0)
    printf '%s\n' "$((count + 1))" > "$PLUTO_TEST_BOOT_CONFIRM_COUNT"
    : > "$PLUTO_TEST_RECOVERY_CONFIRMED"
    printf '0\n' > "$PLUTO_TEST_RECOVERY_COUNTER_DIR/roota_errcnt"
    printf 'state=confirmed/profile=move/boot=test/nonce=attempt-nonce/app=%s\n' "$4"
    ;;
  cancel)
    printf 'state=cancelled/profile=move/nonce=attempt-nonce\n'
    ;;
  begin)
    printf 'state=pending/nonce=attempt-nonce/boot=test/profile=move\n'
    ;;
  verify-stock)
    [ "${PLUTO_TEST_STOCK_VERIFY_FAIL:-0}" != 1 ] || exit 1
    printf 'state=stock-verified/profile=move\n'
    ;;
  *) exit 64 ;;
esac
BOOT_RECOVERY
: > "$TMP/zz-pluto.conf"
printf 'fixture-nonce\n' > "$TMP/nonce"

cat > "$ROOT/bin/pluto-embedder" <<'EMBEDDER'
#!/bin/sh
printf '%s %s\n' "$PLUTO_APP_ID" "$*" >> "$PLUTO_TEST_INVOCATIONS"
printf '%s|%s|%s\n' "$PLUTO_APP_ID" "${PAPER_CODEX_BIN:-}" "$PATH" >> \
  "$PLUTO_TEST_ENVIRONMENTS"
ready_file=""
health_file=""
for arg in "$@"; do
  case "$arg" in
    --ready-file=*) ready_file="${arg#*=}" ;;
    --health-file=*) health_file="${arg#*=}" ;;
  esac
done
[ -n "$ready_file" ] && [ -n "$health_file" ] || exit 65
printf 'ready\n' > "$ready_file"
printf 'pid=%s seq=1 mono_ms=1\n' "$$" > "$health_file"
chmod 0600 "$health_file"
if [ "${PLUTO_TEST_FREEZE_HEALTH:-0}" = 1 ]; then
  while :; do sleep 1; done
fi
case "$PLUTO_APP_ID" in
  dev.pluto.launcher)
    count=$(cat "$PLUTO_TEST_LAUNCHER_COUNT" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$PLUTO_TEST_LAUNCHER_COUNT"
    case "$count" in
      1)
        wait_count=0
        while [ ! -s "$PLUTO_ROOT/state/boot-confirmed" ] &&
              [ "$wait_count" -lt 60 ]; do
          sleep 0.05
          wait_count=$((wait_count + 1))
        done
        [ -s "$PLUTO_ROOT/state/boot-confirmed" ] || exit 66
        printf 'dev.example.debug\n' > "$PLUTO_RUN_DIR/launch"
        ;;
      2) printf 'dev.example.debug\n' > "$PLUTO_RUN_DIR/debug-launch" ;;
      3) printf 'dev.example.release\n' > "$PLUTO_RUN_DIR/launch" ;;
      4) printf 'dev.pluto.codex\n' > "$PLUTO_RUN_DIR/launch" ;;
      *) : > "$PLUTO_RUN_DIR/stock" ;;
    esac
    ;;
  dev.example.debug)
    # Try to relaunch through the ordinary marker. The one-shot permission
    # must already be consumed, so this second attempt is refused.
    printf 'dev.example.debug\n' > "$PLUTO_RUN_DIR/launch"
    ;;
  dev.example.release)
    printf 'dev.pluto.launcher\n' > "$PLUTO_RUN_DIR/launch"
    ;;
  dev.pluto.codex)
    : > "$PLUTO_RUN_DIR/stock"
    ;;
  *) exit 99 ;;
esac
sleep 0.2
EMBEDDER
chmod +x "$TMP/bin/systemctl" "$TMP/bin/xochitl" \
  "$TMP/bin/boot-recovery" "$ROOT/bin/pluto-embedder" "$ROOT/bin/codex"

start_session() {
  PATH="$TMP/bin:$PATH" \
  PLUTO_ROOT="$ROOT" \
  PLUTO_PROFILE_FILE="$PROFILE_FILE" \
  PLUTO_TESTING=1 \
  PLUTO_TEST_PROFILE_ID=move \
  PLUTO_RUN_DIR="$CTL" \
  PLUTO_BOOT_DROPIN="$TMP/zz-pluto.conf" \
  PLUTO_STOCK_XOCHITL="$TMP/bin/xochitl" \
  PLUTO_BOOT_CONFIRM_DISPATCHER="$TMP/bin/boot-recovery" \
  PLUTO_TEST_RECOVERY_HELPER="$TMP/bin/reset-boot-count" \
  PLUTO_TEST_RECOVERY_COUNTER_DIR="$TMP/lpgpr" \
  PLUTO_NONCE_FILE="$TMP/nonce" \
  PLUTO_BOOT_STABLE_WINDOW=0 \
  PLUTO_BOOT_READY_TIMEOUT=3 \
  PLUTO_RENDERER_HEALTH_STALE_SECONDS=2 \
  PLUTO_RENDERER_HEALTH_POLL_INTERVAL=0.1 \
  PLUTO_POWER_WATCHER="$ROOT/bin/missing-power-watcher" \
  PLUTO_UPTIME_FILE="$TMP/uptime" \
  PLUTO_TEST_INVOCATIONS="$TMP/invocations" \
  PLUTO_TEST_ENVIRONMENTS="$TMP/environments" \
  PLUTO_TEST_LAUNCHER_COUNT="$TMP/launcher-count" \
  PLUTO_TEST_STOCK_PID="$TMP/stock-pid" \
  PLUTO_TEST_STOCK_ARGS="$TMP/stock-args" \
  PLUTO_TEST_BOOT_CONFIRM_COUNT="$TMP/boot-confirm-count" \
  PLUTO_TEST_RECOVERY_CONFIRMED="$TMP/recovery-confirmed" \
  PLUTO_TEST_RECOVERY_LOG="$TMP/recovery.log" \
  PLUTO_TEST_FREEZE_HEALTH="${PLUTO_TEST_FREEZE_HEALTH:-0}" \
  PLUTO_TEST_STOCK_VERIFY_FAIL="${PLUTO_TEST_STOCK_VERIFY_FAIL:-0}" \
    sh "$SUPERVISOR" start > "$TMP/session.log" 2>&1 &
  SESSION_PID=$!
}

start_session
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

[ "$(grep -c '^dev.pluto.launcher ' "$TMP/invocations")" -eq 4 ] ||
  fail "expected four launcher handoffs"
[ "$(grep -c '^dev.example.debug .*--debug' "$TMP/invocations")" -eq 1 ] ||
  fail "debug embedder must run exactly once for the explicit authorization"
[ "$(grep -c '^dev.example.release .*--release' "$TMP/invocations")" -eq 1 ] ||
  fail "ordinary release AOT launch changed unexpectedly"
[ "$(grep -c '^dev.pluto.codex .*--release' "$TMP/invocations")" -eq 1 ] ||
  fail "Codex release AOT launch changed unexpectedly"
grep -Fq "dev.pluto.codex|$ROOT/bin/codex|$ROOT/bin:" "$TMP/environments" ||
  fail "Codex did not receive the installed target-native binary and runtime PATH"
grep -Fq "dev.example.release||$ROOT/bin:" "$TMP/environments" ||
  fail "ordinary app inherited a Codex override or missed the common runtime PATH"
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
grep -q '^confirm move [0-9][0-9]* [0-9][0-9]* attempt-nonce .*boot-ready\.attempt-nonce\..* .*health\.attempt-nonce\.' \
  "$TMP/recovery.log" ||
  fail "nonce-bound ready/health confirmation tuple was not dispatched"
if grep -q '^cancel ' "$TMP/recovery.log"; then
  fail "intentional stock handoff retired recovery before stock took ownership"
fi
grep -q '^verify-stock$' "$TMP/recovery.log" ||
  fail "intentional stock handoff did not verify the pinned stock identity"
[ "$(grep -c '^foreground ' "$TMP/recovery.log")" -gt 1 ] ||
  fail "post-confirm foregrounds were not rebound to the owned attempt"
grep '^dev.pluto.launcher ' "$TMP/invocations" | grep -q -- \
  '--health-file=.*/health\.attempt-nonce\.' ||
  fail "launcher did not receive a nonce-specific renderer health path"
[ "$(cat "$TMP/stock-pid")" -eq "$EXPECTED_STOCK_PID" ] ||
  fail "stock xochitl did not replace the boot-first supervisor process"
[ "$(cat "$TMP/stock-args")" = '8 --system' ] ||
  fail "stock xochitl did not receive the firmware service environment/arguments"

# A renderer that remains alive but stops replacing its completion-backed
# receipt must fail the service. The owned attempt is deliberately retained so
# systemd OnFailure can select the profile recovery action; it must not be
# cancelled as though this were an intentional stock handoff.
: > "$TMP/recovery.log"
: > "$TMP/invocations"
rm -f "$TMP/launcher-count" "$TMP/boot-confirm-count" \
  "$TMP/recovery-confirmed" "$CTL/boot-fatal"
PLUTO_TEST_FREEZE_HEALTH=1 start_session
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
  21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 \
  41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
  kill -0 "$SESSION_PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$SESSION_PID" 2>/dev/null; then
  fail "stale renderer health did not terminate the supervisor"
fi
if wait "$SESSION_PID"; then
  fail "stale renderer health returned success"
fi
SESSION_PID=""
[ -f "$CTL/boot-fatal" ] || fail "stale health did not publish a fatal receipt"
grep -q 'renderer health deadline expired' "$CTL/boot-fatal" ||
  fail "stale health fatal receipt was not specific"
if grep -q '^cancel ' "$TMP/recovery.log"; then
  fail "stale renderer health cancelled recovery instead of failing closed"
fi

# A stock handoff is also fail-closed: failed pinned-identity proof retains the
# attempt and returns a failing service status so OnFailure can recover it.
: > "$TMP/recovery.log"
: > "$TMP/invocations"
rm -f "$TMP/launcher-count" "$TMP/boot-confirm-count" \
  "$TMP/recovery-confirmed" "$CTL/boot-fatal"
unset PLUTO_TEST_FREEZE_HEALTH
PLUTO_TEST_STOCK_VERIFY_FAIL=1 start_session
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
  21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 \
  41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
  kill -0 "$SESSION_PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$SESSION_PID" 2>/dev/null; then
  fail "failed stock identity proof did not terminate the supervisor"
fi
if wait "$SESSION_PID"; then
  fail "failed stock identity proof returned success"
fi
SESSION_PID=""
grep -q 'stock xochitl failed owned identity verification' "$CTL/boot-fatal" ||
  fail "stock identity failure did not publish a specific fatal receipt"
if grep -q '^cancel ' "$TMP/recovery.log"; then
  fail "stock identity failure cancelled the owned attempt"
fi
unset PLUTO_TEST_STOCK_VERIFY_FAIL

echo "debug authorization supervisor test: PASS"
