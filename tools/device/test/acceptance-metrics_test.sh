#!/bin/bash -p
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
COLLECTOR="$ROOT/tools/device/diagnostics/acceptance-metrics/collect.sh"
VISUAL_VERIFIER="$ROOT/tools/device/diagnostics/verify-visual-acceptance.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/device"
TRANSPORT="$TMP/transport.sh"
REVISION=0123456789abcdef0123456789abcdef01234567

fail() { echo "acceptance-metrics_test: FAIL: $*" >&2; exit 1; }

[[ "$(head -n 1 "$COLLECTOR")" == '#!/bin/bash -p' &&
  "$(head -n 1 "$VISUAL_VERIFIER")" == '#!/bin/bash -p' ]] ||
  fail 'acceptance collection/verifier entrypoints do not use privileged absolute Bash'
if /bin/bash "$COLLECTOR" >"$TMP/unprivileged-collector.out" 2>&1; then
  fail 'acceptance collector accepted unprivileged Bash'
fi
grep -q 'directly or with /bin/bash -p' "$TMP/unprivileged-collector.out" ||
  fail 'acceptance collector did not diagnose unprivileged Bash'

host_sha() {
  if [[ -x /usr/bin/sha256sum ]]; then
    /usr/bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
  elif [[ -x /bin/sha256sum ]]; then
    /bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
  else
    LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
  fi
}

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
for app_id in dev.pluto.launcher dev.pluto.examples.counter \
  dev.pluto.examples.motion_lab dev.pluto.examples.ink_lab \
  dev.pluto.validation_lab dev.pluto.ink; do
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

# Production activates an immutable release by repointing /home/root/pluto.
# /proc/PID/exe exposes the resolved transactional path even though argv keeps
# the stable public path. Make the default fixture reproduce that distinction.
mkdir -p "$FIXTURE/home/root/pluto.releases"
mv "$FIXTURE/home/root/pluto" \
  "$FIXTURE/home/root/pluto.releases/accepted-release"
ln -s pluto.releases/accepted-release "$FIXTURE/home/root/pluto"
for pid in 200 201; do
  rm "$FIXTURE/proc/$pid/exe"
  ln -s \
    "$FIXTURE/home/root/pluto.releases/accepted-release/bin/pluto-embedder" \
    "$FIXTURE/proc/$pid/exe"
done

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
case "$device" in
  root@127.0.0.1) ;;
  *) exit 64 ;;
esac
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

# Exercise the exact single-value parser used by the final verifier. In
# particular, command substitution must not hide a duplicate trailing blank
# row by stripping its newlines.
/usr/bin/awk '
  /^one_summary_value\(\) \{/ { emit = 1 }
  emit { print }
  emit && /^}$/ { exit }
' "$VISUAL_VERIFIER" > "$TMP/one-summary-value.sh"
printf 'status=PASS\n' > "$TMP/one-summary-positive.txt"
(
  # shellcheck disable=SC1090
  source "$TMP/one-summary-value.sh"
  [[ "$(one_summary_value status "$TMP/one-summary-positive.txt")" == PASS ]]
) || fail 'visual verifier single-summary parser rejected one nonblank row'
for duplicate_rows in nonblank-then-blank blank-then-nonblank; do
  case "$duplicate_rows" in
    nonblank-then-blank) printf 'status=PASS\nstatus=\n' ;;
    blank-then-nonblank) printf 'status=\nstatus=PASS\n' ;;
  esac > "$TMP/one-summary-duplicate.txt"
  if (
    # shellcheck disable=SC1090
    source "$TMP/one-summary-value.sh"
    one_summary_value status "$TMP/one-summary-duplicate.txt" >/dev/null
  ); then
    fail "visual verifier accepted duplicated blank/nonblank summary rows: $duplicate_rows"
  fi
done

DUPLICATE_TRANSPORT="$TMP/duplicate-transport.sh"
cat > "$DUPLICATE_TRANSPORT" <<EOF
#!/bin/sh
"$TRANSPORT" "\$@" | /usr/bin/awk '
  /^collection.status=PASS\$/ { print "identity.profile_id=" }
  { print }
'
EOF
chmod 755 "$DUPLICATE_TRANSPORT"

mkdir -p "$TMP/path-shim"
cat > "$TMP/path-shim/ssh" <<'EOF'
#!/bin/sh
: > "$PATH_SHIM_MARKER"
exit 0
EOF
cat > "$TMP/path-shim/python3" <<'EOF'
#!/bin/sh
: > "$PYTHON_PATH_SHIM_MARKER"
exit 0
EOF
cat > "$TMP/path-shim/sha256sum" <<'EOF'
#!/bin/sh
: > "$SHA_PATH_SHIM_MARKER"
printf '%064d  %s\n' 0 "$1"
EOF
for shim in bash dirname awk; do
  cat > "$TMP/path-shim/$shim" <<EOF
#!/bin/sh
: > '$TMP/path-$shim-used'
exit 0
EOF
done
chmod 755 "$TMP/path-shim/ssh" "$TMP/path-shim/python3" \
  "$TMP/path-shim/sha256sum" "$TMP/path-shim/bash" \
  "$TMP/path-shim/dirname" "$TMP/path-shim/awk"
mkdir -p "$TMP/python-path-shim"
cat > "$TMP/python-path-shim/ipaddress.py" <<EOF
open('$TMP/python-module-shim-used', 'w').close()
raise RuntimeError('acceptance identity imported a PYTHONPATH shim')
EOF
cat > "$TMP/acceptance-bash-env" <<EOF
: > '$TMP/path-bash-env-used'
EOF
if PATH="$TMP/path-shim:$PATH" \
  BASH_ENV="$TMP/acceptance-bash-env" \
  PATH_SHIM_MARKER="$TMP/path-shim-used" \
  PYTHON_PATH_SHIM_MARKER="$TMP/python-path-shim-used" \
  SHA_PATH_SHIM_MARKER="$TMP/sha-path-shim-used" \
  PYTHONPATH="$TMP/python-path-shim" \
  "$COLLECTOR" --device root@127.0.0.1 --port 65534 \
    --samples 3 --interval-seconds 1 --output "$TMP/path-shim-output" \
    >"$TMP/path-shim.out" 2>&1; then
  fail 'production collector unexpectedly completed against a closed local port'
fi
[[ ! -e "$TMP/path-shim-used" ]] ||
  fail 'production collection resolved SSH through PATH instead of /usr/bin/ssh'
[[ ! -e "$TMP/python-path-shim-used" ]] ||
  fail 'production collection resolved Python through PATH instead of /usr/bin/python3'
[[ ! -e "$TMP/sha-path-shim-used" ]] ||
  fail 'production collection resolved SHA-256 through PATH'
[[ ! -e "$TMP/python-module-shim-used" ]] ||
  fail 'production identity validation imported a PYTHONPATH module shim'
for marker in bash dirname awk bash-env; do
  [[ ! -e "$TMP/path-$marker-used" ]] ||
    fail "production collection executed a $marker startup/PATH shim"
done
[[ ! -e "$TMP/path-shim-output" ]] ||
  fail 'failed pinned-SSH probe published an evidence directory'
if (
  dirname() {
    : > "$TMP/path-exported-function-used"
    /usr/bin/dirname "$@"
  }
  export -f dirname
  PATH="$TMP/path-shim:$PATH" \
    "$COLLECTOR" --device root@127.0.0.1 --port 65534 \
    --samples 3 --interval-seconds 1 --output "$TMP/function-shim-output" \
    >/dev/null 2>&1
); then
  fail 'production collector unexpectedly completed with an exported function'
fi
[[ ! -e "$TMP/path-exported-function-used" ]] ||
  fail 'production collector imported an exported shell function'
mkdir -p "$TMP/loader-search"
if LD_LIBRARY_PATH="$TMP/loader-search" \
  "$COLLECTOR" --device root@127.0.0.1 --port 65534 \
  --samples 3 --interval-seconds 1 --output "$TMP/loader-output" \
  >"$TMP/loader.out" 2>&1; then
  fail 'production collector accepted loader-injection environment'
fi
grep -q 'LD_LIBRARY_PATH is forbidden for production collection' \
  "$TMP/loader.out" ||
  fail 'production collector did not diagnose loader-injection environment'

run_collect() {
  local output="$1"
  FIXTURE_ROOT="$FIXTURE" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
  PLUTO_ACCEPTANCE_TRANSPORT="$TRANSPORT" \
    "$COLLECTOR" --device root@127.0.0.1 --port 22202 \
      --samples 3 --interval-seconds 1 --output "$output"
}

if FIXTURE_ROOT="$FIXTURE" \
  PLUTO_ACCEPTANCE_TRANSPORT="$TRANSPORT" \
  "$COLLECTOR" --device root@127.0.0.1 --port 22202 \
    --samples 3 --interval-seconds 1 --output "$TMP/unmarked-transport" \
    >"$TMP/unmarked-transport.out" 2>&1; then
  fail 'collector accepted a custom transport without the test seam'
fi
grep -q 'custom transport requires PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1' \
  "$TMP/unmarked-transport.out" ||
  fail 'unmarked custom transport did not fail during collector preflight'
[[ ! -e "$TMP/unmarked-transport" ]] ||
  fail 'rejected custom transport published an evidence directory'

if PLUTO_SDK="$TMP/untrusted-sdk" \
  "$COLLECTOR" --device root@127.0.0.1 --port 22202 \
    --samples 3 --interval-seconds 1 --output "$TMP/unmarked-sdk" \
    >"$TMP/unmarked-sdk.out" 2>&1; then
  fail 'collector accepted a PLUTO_SDK override as production evidence'
fi
grep -q 'PLUTO_SDK override requires PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1' \
  "$TMP/unmarked-sdk.out" ||
  fail 'unmarked PLUTO_SDK override did not fail during collector preflight'
[[ ! -e "$TMP/unmarked-sdk" ]] ||
  fail 'rejected PLUTO_SDK override published an evidence directory'

if PLUTO_METRICS_SYSTEMCTL="$TMP/untrusted-systemctl" \
  "$COLLECTOR" --device root@127.0.0.1 --port 22202 \
    --samples 3 --interval-seconds 1 --output "$TMP/unmarked-metrics-tool" \
    >"$TMP/unmarked-metrics-tool.out" 2>&1; then
  fail 'collector accepted a PLUTO_METRICS_* tool override as production evidence'
fi
grep -q 'PLUTO_METRICS_\* overrides require PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1' \
  "$TMP/unmarked-metrics-tool.out" ||
  fail 'unmarked PLUTO_METRICS_* override did not fail during collector preflight'
[[ ! -e "$TMP/unmarked-metrics-tool" ]] ||
  fail 'rejected PLUTO_METRICS_* override published an evidence directory'

if PLUTO_ACCEPTANCE_BEFORE_PUBLISH_HOOK="$TMP/untrusted-publish-hook" \
  "$COLLECTOR" --device root@127.0.0.1 --port 22202 \
    --samples 3 --interval-seconds 1 --output "$TMP/unmarked-publish-hook" \
    >"$TMP/unmarked-publish-hook.out" 2>&1; then
  fail 'collector accepted a publication hook as production evidence'
fi
grep -q 'publication hook requires PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1' \
  "$TMP/unmarked-publish-hook.out" ||
  fail 'unmarked publication hook did not fail during collector preflight'
[[ ! -e "$TMP/unmarked-publish-hook" ]] ||
  fail 'rejected publication hook published an evidence directory'

if FIXTURE_ROOT="$FIXTURE" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
  PLUTO_ACCEPTANCE_TRANSPORT="$DUPLICATE_TRANSPORT" \
  "$COLLECTOR" --device root@127.0.0.1 --port 22202 \
    --samples 3 --interval-seconds 1 --output "$TMP/duplicate-evidence-value" \
    >"$TMP/duplicate-evidence-value.out" 2>&1; then
  fail 'collector accepted duplicated nonblank/blank evidence rows'
fi
[[ ! -e "$TMP/duplicate-evidence-value" ]] ||
  fail 'duplicate evidence-row rejection published an evidence directory'

OUT="$TMP/pass"
run_collect "$OUT" >/dev/null
[[ -f "$OUT/device-evidence.txt" ]] || fail 'positive bundle omitted evidence'
[[ "$(tail -n 1 "$OUT/device-evidence.txt")" == collection.status=PASS ]] || fail 'positive bundle omitted terminal PASS'
grep -q '^transport=test-hook$' "$OUT/summary.txt" ||
  fail 'custom transport bundle was not permanently marked'
grep -q '^ssh_binary=not-used$' "$OUT/summary.txt" ||
  fail 'custom transport bundle did not record that SSH was bypassed'
grep -q '^test_seam=1$' "$OUT/summary.txt" ||
  fail 'custom transport bundle omitted its test seam'
grep -q '^device=root@127.0.0.1$' "$OUT/summary.txt" ||
  fail 'custom transport bundle omitted its validated device identity'
grep -q '^port=22202$' "$OUT/summary.txt" ||
  fail 'custom transport bundle omitted its validated numeric port'
grep -Fqx "identity_helper_sha256=$(host_sha "$ROOT/tools/device/diagnostics/acceptance_identity.py")" \
  "$OUT/summary.txt" || fail 'bundle omitted the exact identity-helper provenance'
grep -Fqx "remote_collector_sha256=$(host_sha "$ROOT/tools/device/diagnostics/acceptance-metrics/remote-collector.sh")" \
  "$OUT/summary.txt" || fail 'bundle omitted the exact remote-collector provenance'
grep -Fqx "manifest_verifier_sha256=$(host_sha "$ROOT/tools/device/diagnostics/acceptance-metrics/verify_manifest.dart")" \
  "$OUT/summary.txt" || fail 'bundle omitted the exact manifest-verifier provenance'
grep -q '^python_binary=/usr/bin/python3$' "$OUT/summary.txt" ||
  fail 'bundle omitted the pinned Python interpreter'
grep -Fqx "python_sha256=$(host_sha /usr/bin/python3)" "$OUT/summary.txt" ||
  fail 'bundle omitted the exact Python interpreter provenance'
grep -q '^dart_binary=not-used$' "$OUT/summary.txt" ||
  fail 'manifest-free bundle did not mark Dart as unused'
grep -q '^dart_sha256=not-used$' "$OUT/summary.txt" ||
  fail 'manifest-free bundle did not mark Dart provenance as unused'
grep -q '^remote_shell=/bin/sh$' "$OUT/summary.txt" ||
  fail 'bundle omitted the exact remote shell contract'
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

# Deterministically substitute the destination after the collector's initial
# nonexistence check but before rename. The post-move inode/device fence must
# reject it, remove any nested staging tree, and never print PASS.
PUBLISH_RACE_HOOK="$TMP/publish-race-hook.sh"
cat > "$PUBLISH_RACE_HOOK" <<'EOF'
#!/bin/sh
mkdir "$1"
printf 'substituted\n' > "$1/sentinel"
EOF
chmod 755 "$PUBLISH_RACE_HOOK"
RACED_OUTPUT="$TMP/raced-output"
if FIXTURE_ROOT="$FIXTURE" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
  PLUTO_ACCEPTANCE_TRANSPORT="$TRANSPORT" \
  PLUTO_ACCEPTANCE_BEFORE_PUBLISH_HOOK="$PUBLISH_RACE_HOOK" \
  "$COLLECTOR" --device root@127.0.0.1 --port 22202 \
    --samples 3 --interval-seconds 1 --output "$RACED_OUTPUT" \
    >"$TMP/publish-race.out" 2>"$TMP/publish-race.err"; then
  fail 'collector accepted a substituted publication destination'
fi
grep -q 'output destination was substituted during publication' \
  "$TMP/publish-race.err" ||
  fail 'publication substitution did not fail at the inode/device fence'
if grep -q 'acceptance metrics: PASS' "$TMP/publish-race.out"; then
  fail 'publication substitution printed a false PASS'
fi
[[ -f "$RACED_OUTPUT/sentinel" ]] ||
  fail 'publication race fixture did not substitute the destination'
[[ ! -e "$RACED_OUTPUT/summary.txt" &&
  ! -e "$RACED_OUTPUT/device-evidence.txt" ]] ||
  fail 'publication substitution exposed an accepted bundle at the destination'
[[ -z "$(find "$RACED_OUTPUT" -mindepth 1 -type d -name '.*.partial.*' -print -quit)" ]] ||
  fail 'publication substitution left its nested staging bundle behind'

OUT_SCOPED_IPV6="$TMP/scoped-ipv6"
mkdir -p "$TMP/ssh-bin"
cat > "$TMP/ssh-bin/ssh" <<'EOF'
#!/bin/sh
[ "$#" -eq 22 ] || exit 64
[ "$1" = -F ] && [ "$2" = /dev/null ] || exit 64
[ "$3" = -o ] && [ "$4" = BatchMode=yes ] || exit 64
[ "$5" = -o ] && [ "$6" = ConnectTimeout=8 ] || exit 64
[ "$7" = -o ] && [ "$8" = StrictHostKeyChecking=yes ] || exit 64
[ "$9" = -o ] && [ "${10}" = ProxyCommand=none ] || exit 64
[ "${11}" = -o ] && [ "${12}" = CanonicalizeHostname=no ] || exit 64
[ "${13}" = -o ] && [ "${14}" = ControlMaster=no ] || exit 64
[ "${15}" = -o ] && [ "${16}" = ControlPath=none ] || exit 64
[ "${17}" = -o ] && [ "${18}" = ControlPersist=no ] || exit 64
[ "${19}" = -p ] && [ "${20}" = "$EXPECTED_SSH_PORT" ] || exit 64
[ "${21}" = "$EXPECTED_SSH_TARGET" ] || exit 64
expected_remote_command='unset PLUTO_METRICS_ROOT PLUTO_METRICS_RUN_DIR PLUTO_METRICS_TEST_ROOT PLUTO_METRICS_SYSTEMCTL PLUTO_METRICS_JOURNALCTL PLUTO_METRICS_UNAME PLUTO_METRICS_SLEEP PLUTO_METRICS_DATE PLUTO_METRICS_STAT PLUTO_METRICS_SHA256SUM; PLUTO_METRICS_SAMPLE_COUNT=3 PLUTO_METRICS_SAMPLE_INTERVAL=1 /bin/sh -s'
[ "${22}" = "$expected_remote_command" ] ||
  exit 64
PLUTO_METRICS_TEST_ROOT="$FIXTURE_ROOT" \
PLUTO_METRICS_SAMPLE_COUNT=3 \
PLUTO_METRICS_SAMPLE_INTERVAL=1 \
PLUTO_METRICS_SYSTEMCTL="$FIXTURE_ROOT/bin/systemctl" \
PLUTO_METRICS_JOURNALCTL="$FIXTURE_ROOT/bin/journalctl" \
PLUTO_METRICS_UNAME="$FIXTURE_ROOT/bin/uname" \
PLUTO_METRICS_SLEEP="$FIXTURE_ROOT/bin/sleep" \
PLUTO_METRICS_SHA256SUM=sha256sum \
sh -s
EOF
chmod 755 "$TMP/ssh-bin/ssh"
if FIXTURE_ROOT="$FIXTURE" \
  PLUTO_ACCEPTANCE_SSH_BIN="$TMP/ssh-bin/ssh" \
  "$COLLECTOR" --device 'root@fe80::1%en7' --port 22202 \
    --samples 3 --interval-seconds 1 --output "$TMP/unmarked-ssh-override" \
    >"$TMP/unmarked-ssh-override.out" 2>&1; then
  fail 'collector accepted an SSH binary override without the test seam'
fi
grep -q 'SSH binary override requires PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1' \
  "$TMP/unmarked-ssh-override.out" ||
  fail 'unmarked SSH binary override did not fail during collector preflight'
[[ ! -e "$TMP/unmarked-ssh-override" ]] ||
  fail 'rejected SSH binary override published an evidence directory'

FIXTURE_ROOT="$FIXTURE" \
EXPECTED_SSH_TARGET='root@fe80::1%en7' \
EXPECTED_SSH_PORT=22202 \
PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
PLUTO_ACCEPTANCE_SSH_BIN="$TMP/ssh-bin/ssh" \
  "$COLLECTOR" --device 'root@fe80::1%en7' --port 22202 \
    --samples 3 --interval-seconds 1 --output "$OUT_SCOPED_IPV6" >/dev/null
[[ -f "$OUT_SCOPED_IPV6/device-evidence.txt" ]] ||
  fail 'scoped IPv6 collection omitted evidence'
grep -q 'device=root@fe80::1%en7 port=22202' \
  "$OUT_SCOPED_IPV6/commands.log" ||
  fail 'scoped IPv6 endpoint was not preserved as one SSH argument'
grep -q '^transport=test-hook$' "$OUT_SCOPED_IPV6/summary.txt" ||
  fail 'scoped IPv6 SSH override was not permanently marked as a test hook'
grep -Fqx "ssh_binary=$TMP/ssh-bin/ssh" "$OUT_SCOPED_IPV6/summary.txt" ||
  fail 'scoped IPv6 collection omitted the exact SSH binary override'
grep -q '^test_seam=1$' "$OUT_SCOPED_IPV6/summary.txt" ||
  fail 'scoped IPv6 SSH override omitted its test seam'

OUT_EMBEDDED_PORT="$TMP/embedded-port"
FIXTURE_ROOT="$FIXTURE" \
EXPECTED_SSH_TARGET=root@127.0.0.1 \
EXPECTED_SSH_PORT=22202 \
PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
PLUTO_ACCEPTANCE_SSH_BIN="$TMP/ssh-bin/ssh" \
  "$COLLECTOR" --device root@127.0.0.1:22202 \
    --samples 3 --interval-seconds 1 --output "$OUT_EMBEDDED_PORT" >/dev/null
grep -q '^device=root@127.0.0.1$' "$OUT_EMBEDDED_PORT/summary.txt" ||
  fail 'embedded-port collection did not canonicalize the SSH invocation target'
grep -q '^port=22202$' "$OUT_EMBEDDED_PORT/summary.txt" ||
  fail 'embedded parsed port was not propagated to the invocation and summary'
grep -q 'device=root@127.0.0.1 port=22202' "$OUT_EMBEDDED_PORT/commands.log" ||
  fail 'embedded parsed port was not propagated to the transcript'

if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
  PLUTO_ACCEPTANCE_SSH_BIN="$TMP/ssh-bin/ssh" \
  "$COLLECTOR" --device root@127.0.0.1:22202 --port 22203 \
    --samples 3 --interval-seconds 1 --output "$TMP/conflicting-port" \
    >/dev/null 2>&1; then
  fail 'collector accepted conflicting embedded and explicit ports'
fi
[[ ! -e "$TMP/conflicting-port" ]] ||
  fail 'conflicting port rejection published an evidence directory'

invalid_scope_index=0
for invalid_scope_target in \
  'root@example%en7' \
  'root@127.0.0.1%en7' \
  'root@fe80::1%en7;bad' \
  'root@fe80::1%-oProxyCommand=x' \
  'root@fe80::1%en7%extra' \
  'root@fe80::1%abcdefghijklmnop' \
  'root@fe80::1%_en7' \
  'root@fe80::1%'; do
  invalid_scope_index=$((invalid_scope_index + 1))
  invalid_output="$TMP/invalid-scope-$invalid_scope_index"
  if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
    PLUTO_ACCEPTANCE_SSH_BIN="$TMP/ssh-bin/ssh" \
    "$COLLECTOR" --device "$invalid_scope_target" --port 22202 \
      --samples 3 --interval-seconds 1 --output "$invalid_output" \
      >/dev/null 2>&1; then
    fail "collector accepted unsafe IPv6 scope: $invalid_scope_target"
  fi
  [[ ! -e "$invalid_output" ]] ||
    fail "unsafe IPv6 scope rejection published evidence: $invalid_scope_target"
done

printf 'one-shot\n' > "$FIXTURE/service-mode"
if run_collect "$TMP/rm1-one-shot" >/dev/null 2>&1; then
  fail 'one-shot ownership was accepted while the boot-default recovery gate was enabled'
fi
[[ ! -e "$TMP/rm1-one-shot" ]] || fail 'rejected RM1 one-shot run published a partial bundle'
printf 'move\n' > "$FIXTURE/profile-mode"
printf 'fixture codex\n' > "$FIXTURE/home/root/bin/codex"
chmod 755 "$FIXTURE/home/root/bin/codex"
mkdir -p "$FIXTURE/home/root/pluto/apps/dev.pluto.codex/bundle/lib"
printf '{"id":"dev.pluto.codex"}\n' \
  > "$FIXTURE/home/root/pluto/apps/dev.pluto.codex/manifest.json"
printf '{"mode":"release","target":"linux-arm64"}\n' \
  > "$FIXTURE/home/root/pluto/apps/dev.pluto.codex/build-metadata.json"
printf '{"buildMode":"release","engineFlavor":"release"}\n' \
  > "$FIXTURE/home/root/pluto/apps/dev.pluto.codex/install.json"
printf 'aot dev.pluto.codex\n' \
  > "$FIXTURE/home/root/pluto/apps/dev.pluto.codex/bundle/lib/app.so"
OUT_ONCE="$TMP/pass-once"
run_collect "$OUT_ONCE" >/dev/null
grep -q '^service.supervisor.unit=pluto-session-once.service$' \
  "$OUT_ONCE/device-evidence.txt" || fail 'one-shot supervisor was not accepted by exact process identity'
grep -q '^identity.profile_id=move$' \
  "$OUT_ONCE/device-evidence.txt" || fail 'one-shot fixture did not use the closed-gate profile'
grep -q '^service.xochitl.active_state=inactive$' \
  "$OUT_ONCE/device-evidence.txt" || fail 'one-shot evidence did not prove stock xochitl inactive'
rm -f "$FIXTURE/service-mode" "$FIXTURE/profile-mode"
rm -f "$FIXTURE/home/root/bin/codex"
rm -rf "$FIXTURE/home/root/pluto/apps/dev.pluto.codex"

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

# The collector must not publish when its verifier returns a digest for a
# different manifest generation, even if the verifier exits successfully.
sed 's/) S /) T /' "$FIXTURE/proc/201/stat" > "$TMP/stat"
mv "$TMP/stat" "$FIXTURE/proc/201/stat"
FAKE_SDK="$TMP/fake-sdk"
FAKE_DART="$FAKE_SDK/bin/cache/dart-sdk/bin/dart"
mkdir -p "$(dirname "$FAKE_DART")"
cat > "$FAKE_DART" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
manifest=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    --manifest) manifest=$2; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$output" && -n "$manifest" ]]
case "${FAKE_DART_MODE:?}" in
  inconsistent-proof)
    proof_sha=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
    ;;
  replace-manifest)
    mv "$FAKE_REPLACEMENT_MANIFEST" "$manifest"
    proof_sha=$FAKE_PROOF_SHA
    ;;
  *) exit 64 ;;
esac
cat > "$output" <<PROOF
{
  "format": "pluto-acceptance-manifest-proof",
  "manifestSha256": "$proof_sha",
  "status": "PASS"
}
PROOF
EOF
chmod 755 "$FAKE_DART"

run_fenced_collect() {
  local mode="$1" manifest="$2" output="$3" error="$4"
  FIXTURE_ROOT="$FIXTURE" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
  PLUTO_ACCEPTANCE_TRANSPORT="$TRANSPORT" \
  PLUTO_SDK="$FAKE_SDK" \
  FAKE_DART_MODE="$mode" \
  FAKE_REPLACEMENT_MANIFEST="${FAKE_REPLACEMENT_MANIFEST:-}" \
  FAKE_PROOF_SHA="${FAKE_PROOF_SHA:-}" \
    "$COLLECTOR" --device root@127.0.0.1 --port 22202 \
      --samples 3 --interval-seconds 1 --release-manifest "$manifest" \
      --output "$output" >/dev/null 2>"$error"
}

FENCED_MANIFEST="$TMP/fenced-release-manifest.json"
printf '{"generation":"first"}\n' > "$FENCED_MANIFEST"
if run_fenced_collect inconsistent-proof "$FENCED_MANIFEST" \
  "$TMP/inconsistent-proof" "$TMP/inconsistent-proof.err"; then
  fail 'collector accepted a proof for a different manifest digest'
fi
[[ ! -e "$TMP/inconsistent-proof" ]] ||
  fail 'inconsistent manifest proof published a partial bundle'
grep -q 'proof digest does not match the fenced manifest' \
  "$TMP/inconsistent-proof.err" ||
  fail 'inconsistent manifest proof did not fail at digest binding'

# Even a proof that repeats the pre-verification digest cannot hide an atomic
# replacement of the manifest while the verifier is running.
printf '{"generation":"first"}\n' > "$FENCED_MANIFEST"
REPLACEMENT="$TMP/replacement-release-manifest.json"
printf '{"generation":"second"}\n' > "$REPLACEMENT"
FAKE_REPLACEMENT_MANIFEST="$REPLACEMENT" \
FAKE_PROOF_SHA="$(sha "$FENCED_MANIFEST")" \
  run_fenced_collect replace-manifest "$FENCED_MANIFEST" \
    "$TMP/replaced-manifest" "$TMP/replaced-manifest.err" &&
  fail 'collector accepted a manifest replaced during verification'
[[ ! -e "$TMP/replaced-manifest" ]] ||
  fail 'manifest replacement published a partial bundle'
grep -q 'release manifest changed during verification' \
  "$TMP/replaced-manifest.err" ||
  fail 'manifest replacement did not fail at the identity/digest fence'

echo 'acceptance-metrics_test: PASS'
