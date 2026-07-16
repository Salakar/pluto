#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
COLLECTOR="$ROOT/tools/device/diagnostics/acceptance-metrics/collect.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/device"
TRANSPORT="$TMP/transport.sh"
REVISION=0123456789abcdef0123456789abcdef01234567

fail() { echo "acceptance-metrics_test: FAIL: $*" >&2; exit 1; }

mkdir -p \
  "$FIXTURE/home/root/pluto/share" \
  "$FIXTURE/home/root/pluto/bin" \
  "$FIXTURE/home/root/pluto/engine/release" \
  "$FIXTURE/home/root/pluto/launcher/bundle/lib" \
  "$FIXTURE/home/root/pluto/apps" \
  "$FIXTURE/home/root/pluto/logs" \
  "$FIXTURE/home/root/pluto/state" \
  "$FIXTURE/home/root/bin" \
  "$FIXTURE/run/pluto/warm-apps" \
  "$FIXTURE/etc" \
  "$FIXTURE/proc/sys/kernel/random" \
  "$FIXTURE/proc/device-tree" \
  "$FIXTURE/sys/devices/soc0" \
  "$FIXTURE/sys/devices/system/cpu" \
  "$FIXTURE/sys/class/thermal/thermal_zone0" \
  "$FIXTURE/sys/class/hwmon/hwmon0" \
  "$FIXTURE/bin"

cat > "$FIXTURE/home/root/pluto/share/device-profiles.sh" <<'EOF'
pluto_profile_probe() {
  mode=$(cat "$PLUTO_METRICS_TEST_ROOT/profile-mode" 2>/dev/null || echo rm1)
  if [ "$mode" = move ]; then
    PLUTO_PROFILE_ID=move
    PLUTO_PROFILE_TARGET=linux-arm64
    PLUTO_PROFILE_DISPLAY_DRIVER=gallery3_drm
    PLUTO_PROFILE_FIRMWARE_BUILD=20260612085811
    PLUTO_PROFILE_KERNEL_RELEASE=6.1.55-move
    PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED=0
  else
    PLUTO_PROFILE_ID=rm1
    PLUTO_PROFILE_TARGET=linux-arm
    PLUTO_PROFILE_DISPLAY_DRIVER=mxcfb_epdc
    PLUTO_PROFILE_FIRMWARE_BUILD=20260612085811
    PLUTO_PROFILE_KERNEL_RELEASE=5.4.70-v1.6.3-rm10x
    PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED=1
  fi
  driver_override=$(cat "$PLUTO_METRICS_TEST_ROOT/driver-mode" 2>/dev/null || true)
  [ -z "$driver_override" ] || PLUTO_PROFILE_DISPLAY_DRIVER=$driver_override
  export PLUTO_PROFILE_ID PLUTO_PROFILE_TARGET PLUTO_PROFILE_DISPLAY_DRIVER
  export PLUTO_PROFILE_FIRMWARE_BUILD PLUTO_PROFILE_KERNEL_RELEASE
  export PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED
}
EOF
printf '%s\n' "$REVISION" > "$FIXTURE/home/root/pluto/share/release-revision"
printf '20260612085811\n' > "$FIXTURE/etc/version"
printf '11111111-2222-3333-4444-555555555555\n' > "$FIXTURE/proc/sys/kernel/random/boot_id"
printf 'reMarkable 1.0\000' > "$FIXTURE/proc/device-tree/model"
printf 'reMarkable 1.0\n' > "$FIXTURE/sys/devices/soc0/machine"
printf '0\n' > "$FIXTURE/sys/devices/system/cpu/online"
printf '0\n' > "$FIXTURE/sys/devices/system/cpu/present"
printf 'bq27441-0\n' > "$FIXTURE/sys/class/thermal/thermal_zone0/type"
printf '26200\n' > "$FIXTURE/sys/class/thermal/thermal_zone0/temp"
printf 'epd-panel\n' > "$FIXTURE/sys/class/hwmon/hwmon0/name"
printf '27100\n' > "$FIXTURE/sys/class/hwmon/hwmon0/temp1_input"
printf 'cpu 100 20 30 400 5 6 7 8 0 0\n' > "$FIXTURE/proc/stat"
printf '100.00 50.00\n' > "$FIXTURE/proc/uptime"
printf '0.01 0.02 0.03 1/100 300\n' > "$FIXTURE/proc/loadavg"
printf 'MemTotal: 1000000 kB\nMemAvailable: 700000 kB\n' > "$FIXTURE/proc/meminfo"

for file in pluto-embedder pluto-controlctl pluto-session.sh pluto-session-once.sh \
  pluto-rm2-cpufreq-restore.sh \
  pluto-boot-confirm.sh pluto-boot-install.sh pluto-power-key-watch.sh \
  pluto-app-control.sh pluto-install-transaction.sh pluto-uninstall.sh; do
  printf 'fixture %s\n' "$file" > "$FIXTURE/home/root/pluto/bin/$file"
  chmod 755 "$FIXTURE/home/root/pluto/bin/$file"
done
printf 'fixture engine\n' > "$FIXTURE/home/root/pluto/engine/release/libflutter_engine.so"
printf 'fixture codex\n' > "$FIXTURE/home/root/bin/codex"
chmod 755 "$FIXTURE/home/root/bin/codex"

for app_id in dev.pluto.launcher dev.pluto.examples.counter \
  dev.pluto.examples.motion_lab dev.pluto.examples.ink_lab \
  dev.pluto.validation_lab dev.pluto.codex dev.pluto.ink; do
  app_root="$FIXTURE/home/root/pluto/apps/$app_id"
  [[ "$app_id" == dev.pluto.launcher ]] && app_root="$FIXTURE/home/root/pluto/launcher"
  mkdir -p "$app_root/bundle/lib"
  printf '{"id":"%s"}\n' "$app_id" > "$app_root/manifest.json"
  printf '{"mode":"release","target":"linux-arm"}\n' > "$app_root/build-metadata.json"
  printf '{"buildMode":"release","engineFlavor":"release"}\n' > "$app_root/install.json"
  printf 'aot %s\n' "$app_id" > "$app_root/bundle/lib/app.so"
done

write_proc() {
  local pid="$1" state="$2" app_id="$3" cmdline="$4"
  local proc="$FIXTURE/proc/$pid"
  mkdir -p "$proc/fd"
  printf '%s (fixture) %s 1 1 1 0 0 0 0 0 0 0 100 10 0 0 20 0 1 0 %s 1000000 100\n' \
    "$pid" "$state" "$((pid * 10))" > "$proc/stat"
  printf 'Name:\tfixture\nState:\t%s (fixture)\nVmRSS:\t12000 kB\nVmHWM:\t14000 kB\nThreads:\t3\n' \
    "$state" > "$proc/status"
  printf '%s\000' $cmdline > "$proc/cmdline"
  log_activation="activation-$pid"
  printf 'PLUTO_APP_ID=%s\000PLUTO_LOG_ACTIVATION=%s\000' \
    "$app_id" "$log_activation" > "$proc/environ"
  ln -s /dev/null "$proc/fd/0"
  if [[ "$app_id" == none ]]; then
    ln -s /bin/sh "$proc/exe"
    ln -s /dev/null "$proc/fd/1"
    ln -s /dev/null "$proc/fd/2"
  else
    log="$FIXTURE/home/root/pluto/logs/$app_id.log"
    : > "$log"
    printf 'pluto-log-activation app_id=%s token=%s\n' \
      "$app_id" "$log_activation" >> "$log"
    ln -s "$FIXTURE/home/root/pluto/bin/pluto-embedder" "$proc/exe"
    ln -s "$log" "$proc/fd/1"
    ln -s "$log" "$proc/fd/2"
  fi
}

write_proc 100 S none "/bin/sh /home/root/pluto/bin/pluto-session.sh start"
write_proc 200 S dev.pluto.launcher \
  "/home/root/pluto/bin/pluto-embedder --release --bundle=/home/root/pluto/launcher/bundle --engine=/home/root/pluto/engine/release/libflutter_engine.so --icu-data=/home/root/pluto/launcher/bundle/icudtl.dat --presenter=native --ready-file=/run/pluto/boot-ready.accept.launch --health-file=/run/pluto/health.accept.launch --aot-elf=/home/root/pluto/launcher/bundle/lib/app.so"
write_proc 201 T dev.pluto.ink \
  "/home/root/pluto/bin/pluto-embedder --release --bundle=/home/root/pluto/apps/dev.pluto.ink/bundle --engine=/home/root/pluto/engine/release/libflutter_engine.so --icu-data=/home/root/pluto/apps/dev.pluto.ink/bundle/icudtl.dat --presenter=native --ready-file=/run/pluto/boot-ready.accept.ink --health-file=/run/pluto/health.accept.ink --aot-elf=/home/root/pluto/apps/dev.pluto.ink/bundle/lib/app.so"

printf '200\n' > "$FIXTURE/run/pluto/embedder.pid"
printf '200\n' > "$FIXTURE/run/pluto/warm-apps/dev.pluto.launcher.pid"
printf '201\n' > "$FIXTURE/run/pluto/warm-apps/dev.pluto.ink.pid"
printf 'ready\n' > "$FIXTURE/run/pluto/boot-ready.accept.launch"
printf 'pid=200 seq=10 mono_ms=10000\n' > "$FIXTURE/run/pluto/health.accept.launch"
chmod 600 "$FIXTURE/run/pluto/health.accept.launch"
printf 'state=confirmed confirmed_at=2026-07-15T00:00:00Z\n' > "$FIXTURE/home/root/pluto/state/boot-confirmed"
printf 'mxcfb: damage telemetry updates=7 requested_px=1000 driven_px=1200 amplified=2 full=1 regional_full=1 legacy_full_px_avoided=500 max_amp_milli=1500\n' \
  >> "$FIXTURE/home/root/pluto/logs/dev.pluto.ink.log"
printf 'swtcon stats: builds=9 build_p50_us=10 build_p95_us=20 build_max_us=30 completions=9 dropped=0 color_fault=0 hold_rescans=2 neutral_frames=3\n' \
  >> "$FIXTURE/home/root/pluto/logs/dev.pluto.ink.log"

cat > "$FIXTURE/bin/uname" <<'EOF'
#!/bin/sh
mode=$(cat "$FIXTURE_ROOT/profile-mode" 2>/dev/null || echo rm1)
case "$mode:$1" in
  move:-r) echo 6.1.55-move ;;
  move:-m) echo aarch64 ;;
  rm1:-r) echo 5.4.70-v1.6.3-rm10x ;;
  rm1:-m) echo armv7l ;;
  *) exit 64 ;;
esac
EOF
chmod 755 "$FIXTURE/bin/uname"

cat > "$FIXTURE/bin/systemctl" <<'EOF'
#!/bin/sh
unit=$2
field=$4
[ "$1" = show ] && [ "$5" = --value ] || exit 64
mode=$(cat "$FIXTURE_ROOT/service-mode" 2>/dev/null || echo boot-first)
if [ "$mode" = one-shot ] && [ "$unit" = xochitl.service ]; then
  case "$field" in
    ActiveState) echo inactive ;;
    SubState) echo dead ;;
    Result) echo success ;;
    ExecMainStatus) echo 0 ;;
    NRestarts) echo 0 ;;
    MainPID) echo 0 ;;
    ActiveEnterTimestamp) echo 'Wed 2026-07-15 00:00:00 UTC' ;;
    *) exit 1 ;;
  esac
elif { [ "$mode" = boot-first ] && [ "$unit" = xochitl.service ]; } ||
     { [ "$mode" = one-shot ] && [ "$unit" = pluto-session-once.service ]; }; then
  case "$field" in
    ActiveState) echo active ;;
    SubState) echo running ;;
    Result) echo success ;;
    ExecMainStatus) echo 0 ;;
    NRestarts) echo 0 ;;
    MainPID) echo 100 ;;
    ActiveEnterTimestamp) echo 'Wed 2026-07-15 00:00:00 UTC' ;;
    *) exit 1 ;;
  esac
else
  exit 1
fi
EOF
chmod 755 "$FIXTURE/bin/systemctl"

cat > "$FIXTURE/bin/journalctl" <<'EOF'
#!/bin/sh
case " $* " in
  *' -k '*) echo '2026-07-15T00:00:01+0000 kernel: panel ready' ;;
  *) echo '2026-07-15T00:00:01+0000 pluto-session: profile accepted' ;;
esac
EOF
chmod 755 "$FIXTURE/bin/journalctl"

cat > "$FIXTURE/bin/sleep" <<'EOF'
#!/bin/sh
health="$FIXTURE_ROOT/run/pluto/health.accept.launch"
set -- $(cat "$health")
seq=${2#seq=}
mono=${3#mono_ms=}
printf 'pid=200 seq=%s mono_ms=%s\n' "$((seq + 1))" "$((mono + 1000))" > "$health"
chmod 600 "$health"
set -- $(cat "$FIXTURE_ROOT/proc/stat")
printf 'cpu %s %s %s %s %s %s %s %s %s %s\n' \
  "$(( $2 + 10 ))" "$3" "$4" "$(( $5 + 80 ))" "$6" "$7" "$8" "$9" "${10}" "${11}" \
  > "$FIXTURE_ROOT/proc/stat"
EOF
chmod 755 "$FIXTURE/bin/sleep"

cat > "$TRANSPORT" <<'EOF'
#!/bin/sh
device=$1
port=$2
samples=$3
interval=$4
collector=$5
[ "$device" = root@127.0.0.1 ] || exit 64
[ "$port" = 22202 ] || exit 64
PLUTO_METRICS_TEST_ROOT="$FIXTURE_ROOT" \
PLUTO_METRICS_SAMPLE_COUNT="$samples" \
PLUTO_METRICS_SAMPLE_INTERVAL="$interval" \
PLUTO_METRICS_SYSTEMCTL="$FIXTURE_ROOT/bin/systemctl" \
PLUTO_METRICS_JOURNALCTL="$FIXTURE_ROOT/bin/journalctl" \
PLUTO_METRICS_UNAME="$FIXTURE_ROOT/bin/uname" \
PLUTO_METRICS_SLEEP="$FIXTURE_ROOT/bin/sleep" \
PLUTO_METRICS_SHA256SUM=sha256sum \
sh "$collector"
EOF
chmod 755 "$TRANSPORT"

run_collect() {
  local output="$1"
  FIXTURE_ROOT="$FIXTURE" \
  PLUTO_ACCEPTANCE_TRANSPORT="$TRANSPORT" \
    bash "$COLLECTOR" --device root@127.0.0.1 --port 22202 \
      --samples 3 --interval-seconds 1 --output "$output"
}

OUT="$TMP/pass"
run_collect "$OUT" >/dev/null
[[ -f "$OUT/device-evidence.txt" ]] || fail 'positive bundle omitted evidence'
[[ "$(tail -n 1 "$OUT/device-evidence.txt")" == collection.status=PASS ]] || fail 'positive bundle omitted terminal PASS'
grep -q '^warm.stopped_count=1$' "$OUT/device-evidence.txt" || fail 'warm stopped process was not measured'
grep -q '^health.seq_delta=2$' "$OUT/device-evidence.txt" || fail 'health progression was not measured'
[[ "$(grep -c '^sample.process .* role=warm-stopped ' "$OUT/device-evidence.txt")" -eq 3 ]] || fail 'warm process samples are incomplete'
(
  cd "$OUT"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c SHA256SUMS >/dev/null
  else
    shasum -a 256 -c SHA256SUMS >/dev/null
  fi
) || fail 'bundle digest manifest did not verify'

printf 'one-shot\n' > "$FIXTURE/service-mode"
if run_collect "$TMP/rm1-one-shot" >/dev/null 2>&1; then
  fail 'one-shot ownership was accepted while the boot-default recovery gate was enabled'
fi
[[ ! -e "$TMP/rm1-one-shot" ]] || fail 'rejected RM1 one-shot run published a partial bundle'
printf 'move\n' > "$FIXTURE/profile-mode"
OUT_ONCE="$TMP/pass-once"
run_collect "$OUT_ONCE" >/dev/null
grep -q '^service.supervisor.unit=pluto-session-once.service$' \
  "$OUT_ONCE/device-evidence.txt" || fail 'one-shot supervisor was not accepted by exact process identity'
grep -q '^identity.profile_id=move$' \
  "$OUT_ONCE/device-evidence.txt" || fail 'one-shot fixture did not use the closed-gate profile'
grep -q '^service.xochitl.active_state=inactive$' \
  "$OUT_ONCE/device-evidence.txt" || fail 'one-shot evidence did not prove stock xochitl inactive'
rm -f "$FIXTURE/service-mode" "$FIXTURE/profile-mode"

printf 'gallery3_drm\n' > "$FIXTURE/driver-mode"
if run_collect "$TMP/contradictory-driver" >/dev/null 2>&1; then
  fail 'RM1 was accepted with a contradictory generated display driver'
fi
[[ ! -e "$TMP/contradictory-driver" ]] ||
  fail 'contradictory driver rejection published a partial bundle'
rm -f "$FIXTURE/driver-mode"

printf 'pid=200 seq=broken mono_ms=10000\n' > "$FIXTURE/run/pluto/health.accept.launch"
chmod 600 "$FIXTURE/run/pluto/health.accept.launch"
if run_collect "$TMP/bad-health" >/dev/null 2>&1; then
  fail 'malformed health receipt was accepted'
fi
[[ ! -e "$TMP/bad-health" ]] || fail 'failed health run published a partial bundle'
printf 'pid=200 seq=20 mono_ms=20000\n' > "$FIXTURE/run/pluto/health.accept.launch"
chmod 600 "$FIXTURE/run/pluto/health.accept.launch"

: > "$TMP/rm1.log"
cp "$FIXTURE/home/root/pluto/logs/dev.pluto.ink.log" "$TMP/rm1.log"
printf 'pluto-log-activation app_id=dev.pluto.ink token=activation-201\n' \
  > "$FIXTURE/home/root/pluto/logs/dev.pluto.ink.log"
if run_collect "$TMP/no-telemetry" >/dev/null 2>&1; then
  fail 'missing RM1 telemetry was accepted'
fi
[[ ! -e "$TMP/no-telemetry" ]] || fail 'failed telemetry run published a partial bundle'
cp "$TMP/rm1.log" "$FIXTURE/home/root/pluto/logs/dev.pluto.ink.log"

# Old good telemetry cannot satisfy the current live process. Conversely, an
# old fatal line before the current process-bound marker cannot poison a clean
# current activation.
cat > "$FIXTURE/home/root/pluto/logs/dev.pluto.ink.log" <<'EOF'
pluto-log-activation app_id=dev.pluto.ink token=retired-activation
mxcfb: damage telemetry updates=99 requested_px=99 driven_px=99 amplified=0 full=0 regional_full=0 legacy_full_px_avoided=0 max_amp_milli=1000
pluto-log-activation app_id=dev.pluto.ink token=activation-201
EOF
if run_collect "$TMP/stale-good-only" >/dev/null 2>&1; then
  fail 'stale good telemetry before the current activation caused a false pass'
fi
[[ ! -e "$TMP/stale-good-only" ]] || fail 'stale-good rejection published a partial bundle'

cat > "$FIXTURE/home/root/pluto/logs/dev.pluto.ink.log" <<'EOF'
pluto-log-activation app_id=dev.pluto.ink token=retired-activation
presenter completion exceeded deadline
mxcfb: update rejected
pluto-log-activation app_id=dev.pluto.ink token=activation-201
mxcfb: damage telemetry updates=7 requested_px=1000 driven_px=1200 amplified=2 full=1 regional_full=1 legacy_full_px_avoided=500 max_amp_milli=1500
EOF
OUT_STALE_FAULT="$TMP/stale-fault-before-current"
run_collect "$OUT_STALE_FAULT" >/dev/null
grep -q '^telemetry.presenter_fatal_count=0$' \
  "$OUT_STALE_FAULT/device-evidence.txt" ||
  fail 'stale fatal telemetry before the current activation caused a false fail'
grep -q '^telemetry.rm1.rejection_count=0$' \
  "$OUT_STALE_FAULT/device-evidence.txt" ||
  fail 'stale rejection before the current activation was counted'

# A newer boundary proves the PID no longer owns the tail of the log, even if
# its stale environment token and descriptor still exist.
printf 'pluto-log-activation app_id=dev.pluto.ink token=newer-process\n' \
  >> "$FIXTURE/home/root/pluto/logs/dev.pluto.ink.log"
if run_collect "$TMP/replaced-log-owner" >/dev/null 2>&1; then
  fail 'a live PID whose activation marker was superseded was accepted'
fi
[[ ! -e "$TMP/replaced-log-owner" ]] || fail 'replaced-log rejection published a partial bundle'
cp "$TMP/rm1.log" "$FIXTURE/home/root/pluto/logs/dev.pluto.ink.log"

sed 's/) T /) S /' "$FIXTURE/proc/201/stat" > "$TMP/stat"
mv "$TMP/stat" "$FIXTURE/proc/201/stat"
if run_collect "$TMP/warm-running" >/dev/null 2>&1; then
  fail 'non-stopped warm process was accepted'
fi
[[ ! -e "$TMP/warm-running" ]] || fail 'failed warm-state run published a partial bundle'

# The exact Dart verifier must compare the complete installed immutable set,
# not merely trust a revision/tree string parsed by the host shell.
FLUTTER_VERSION="$(tr -d '[:space:]' < "$ROOT/tools/pluto/pins/flutter.version")"
DART="${PLUTO_SDK:-$HOME/.pluto/sdk/$FLUTTER_VERSION}/bin/cache/dart-sdk/bin/dart"
PACKAGES="$ROOT/tools/pluto/.dart_tool/package_config.json"
WRITE_MANIFEST="$ROOT/tools/pluto/tool/write_release_manifest.dart"
VERIFY_MANIFEST="$ROOT/tools/device/diagnostics/acceptance-metrics/verify_manifest.dart"
[[ -x "$DART" && -f "$PACKAGES" ]] || fail 'pinned Dart setup is unavailable'
RELEASE="$TMP/release"
for target in linux-arm linux-arm64; do
  mkdir -p "$RELEASE/targets/$target/share"
  printf 'embedder-%s\n' "$target" > "$RELEASE/targets/$target/pluto-embedder"
  printf '%s\n' "$REVISION" > "$RELEASE/targets/$target/share/release-revision"
done
mkdir -p "$TMP/dart-home"
HOME="$TMP/dart-home" DART_SUPPRESS_ANALYTICS=1 \
  "$DART" --packages="$PACKAGES" "$WRITE_MANIFEST" \
    --release-root "$RELEASE" --pins-dir "$ROOT/tools/pluto/pins" \
    --git-revision "$REVISION" >/dev/null
sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
ARM_EMBEDDER_SHA="$(sha "$RELEASE/targets/linux-arm/pluto-embedder")"
ARM_REVISION_SHA="$(sha "$RELEASE/targets/linux-arm/share/release-revision")"
cat > "$TMP/manifest-evidence.txt" <<EOF
format=pluto-acceptance-evidence
installed.sha256=$ARM_EMBEDDER_SHA device_path=/home/root/pluto/bin/pluto-embedder slice_path=pluto-embedder
installed.sha256=$ARM_REVISION_SHA device_path=/home/root/pluto/share/release-revision slice_path=share/release-revision
collection.status=PASS
EOF
HOME="$TMP/dart-home" DART_SUPPRESS_ANALYTICS=1 \
  "$DART" --packages="$PACKAGES" "$VERIFY_MANIFEST" \
    --manifest "$RELEASE/release-manifest.json" \
    --pins "$ROOT/tools/pluto/pins" --target linux-arm \
    --expected-revision "$REVISION" --evidence "$TMP/manifest-evidence.txt" \
    --output "$TMP/manifest-proof.json"
grep -q '"format": "pluto-acceptance-manifest-proof"' \
  "$TMP/manifest-proof.json" || fail 'manifest proof omitted its exact format marker'
grep -q '"status": "PASS"' "$TMP/manifest-proof.json" || fail 'manifest proof did not pass'
sed "s/$ARM_EMBEDDER_SHA/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/" \
  "$TMP/manifest-evidence.txt" > "$TMP/tampered-evidence.txt"
if HOME="$TMP/dart-home" DART_SUPPRESS_ANALYTICS=1 \
  "$DART" --packages="$PACKAGES" "$VERIFY_MANIFEST" \
    --manifest "$RELEASE/release-manifest.json" \
    --pins "$ROOT/tools/pluto/pins" --target linux-arm \
    --expected-revision "$REVISION" --evidence "$TMP/tampered-evidence.txt" \
    --output "$TMP/tampered-proof.json" >/dev/null 2>&1; then
  fail 'manifest verifier accepted a tampered installed hash'
fi
[[ ! -e "$TMP/tampered-proof.json" ]] || fail 'failed manifest proof left a PASS artifact'

echo 'acceptance-metrics_test: PASS'
