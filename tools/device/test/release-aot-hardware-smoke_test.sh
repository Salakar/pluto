#!/bin/bash -p
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SMOKE="$ROOT/tools/device/test/release-aot-hardware-smoke.sh"
VERIFY="$ROOT/tools/device/diagnostics/verify-visual-acceptance.sh"
RECORD="$ROOT/tools/device/diagnostics/record-visual-review.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pluto-release-smoke-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
REVISION=0123456789abcdef0123456789abcdef01234567

fail() {
  echo "release-aot-hardware-smoke_test: FAIL: $*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

refresh_metrics_review_digest() {
  local camera_dir="$1"
  local summary_digest metrics_digest
  summary_digest="$(sha256_file "$camera_dir/metrics/summary.txt")"
  awk -v digest="$summary_digest" \
    '$2 == "summary.txt" {$1 = digest} {print $1 "  " $2}' \
    "$camera_dir/metrics/SHA256SUMS" > "$camera_dir/metrics/SHA256SUMS.new"
  mv "$camera_dir/metrics/SHA256SUMS.new" "$camera_dir/metrics/SHA256SUMS"
  metrics_digest="$(sha256_file "$camera_dir/metrics/SHA256SUMS")"
  awk -F '\t' -v OFS='\t' -v digest="$metrics_digest" \
    '{$7 = digest; print}' "$camera_dir/review.tsv" > "$camera_dir/review.new"
  mv "$camera_dir/review.new" "$camera_dir/review.tsv"
}

command -v ffmpeg >/dev/null 2>&1 || fail 'ffmpeg is required for visual evidence tests'
[[ "$(head -n 1 "$SMOKE")" == '#!/bin/bash -p' &&
  "$(head -n 1 "$VERIFY")" == '#!/bin/bash -p' &&
  "$(head -n 1 "$RECORD")" == '#!/bin/bash -p' ]] ||
  fail 'visual acceptance entrypoints do not use privileged absolute Bash'
for entrypoint in "$SMOKE" "$VERIFY" "$RECORD"; do
  if /bin/bash "$entrypoint" >"$TMP/unprivileged-entry.out" 2>&1; then
    fail "acceptance entrypoint accepted unprivileged Bash: $entrypoint"
  fi
  grep -q 'directly or with /bin/bash -p' "$TMP/unprivileged-entry.out" ||
    fail "acceptance entrypoint did not diagnose unprivileged Bash: $entrypoint"
done
mkdir -p "$TMP/bin" "$TMP/png-fixtures" "$TMP/jpg-fixtures"
cat > "$TMP/release-manifest.json" <<EOF
{"gitRevision":"$REVISION","targets":{"linux-arm":{},"linux-arm64":{}}}
EOF

cat > "$TMP/expected-labels" <<'EOF'
app-dev.pluto.examples.counter
app-dev.pluto.examples.motion_lab
app-dev.pluto.examples.ink_lab
app-dev.pluto.validation_lab
app-dev.pluto.ink-before-switcher
switcher-dev.pluto.ink
switcher-selected-dev.pluto.validation_lab
ink-canvas-before-stroke
ink-stroke
app-dev.pluto.launcher
EOF

sources=(
  apps/launcher/test_goldens/goldens/s02_home_grid.png
  apps/launcher/test_goldens/goldens/s20_app_switcher_portrait.png
  apps/launcher/test_goldens/goldens/s01_welcome.png
  apps/launcher/test_goldens/goldens/s15_about.png
  apps/launcher/test_goldens/goldens/s10_settings.png
  apps/launcher/test_goldens/goldens/s11_wifi_picker.png
  apps/launcher/test_goldens/goldens/s15_about.png
  apps/ink/test_goldens/goldens/g04_editor_default.png
  apps/ink/test_goldens/goldens/g04_editor_default.png
  apps/launcher/test_goldens/goldens/s06_app_info.png
)
fixture_index=0
while IFS= read -r label; do
  source_path="$ROOT/${sources[$fixture_index]}"
  if [[ "$label" == ink-stroke ]]; then
    ffmpeg -v error -nostdin -y -i "$source_path" -vf \
      'scale=954:1696:flags=neighbor,drawbox=x=286:y=897:w=48:h=6:color=black:t=fill,drawbox=x=334:y=898:w=48:h=6:color=black:t=fill,drawbox=x=381:y=890:w=48:h=6:color=black:t=fill,drawbox=x=429:y=875:w=48:h=6:color=black:t=fill,drawbox=x=477:y=855:w=48:h=6:color=black:t=fill,drawbox=x=525:y=840:w=48:h=6:color=black:t=fill,drawbox=x=572:y=832:w=48:h=6:color=black:t=fill,drawbox=x=620:y=830:w=48:h=6:color=black:t=fill' \
      -frames:v 1 "$TMP/png-fixtures/$label.png"
  elif [[ "$label" == ink-canvas-before-stroke ]]; then
    ffmpeg -v error -nostdin -y -i "$source_path" \
      -vf 'scale=954:1696:flags=neighbor' -frames:v 1 \
      "$TMP/png-fixtures/$label.png"
  else
    cp "$source_path" "$TMP/png-fixtures/$label.png"
  fi
  ffmpeg -v error -nostdin -y -i "$TMP/png-fixtures/$label.png" -frames:v 1 \
    "$TMP/jpg-fixtures/$label.jpg"
  fixture_index=$((fixture_index + 1))
done < "$TMP/expected-labels"

cat > "$TMP/bin/pluto" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${PLUTO_ACCEPTANCE_STRICT_SSH:-}" == 1 ]]
[[ "${PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS:-}" == 1 ]]
[[ "${PLUTO_ACCEPTANCE_SSH_BIN:-}" == /* ]]
if [[ -n "${PLUTO_FAKE_CALL_LOG:-}" ]]; then
  printf 'strict_ssh=%s ssh_bin=%s command=%s\n' \
    "$PLUTO_ACCEPTANCE_STRICT_SSH" "$PLUTO_ACCEPTANCE_SSH_BIN" "$*" \
    >> "$PLUTO_FAKE_CALL_LOG"
fi
case "$1" in
  run)
    exit 0
    ;;
  screenshot)
    output=''
    app=''
    surface=''
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        -o) output="$2"; shift 2 ;;
        --app) app="$2"; shift 2 ;;
        --surface) surface="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "${output##*/}" in
      app-dev.pluto.examples.counter.png) expected=dev.pluto.examples.counter ;;
      app-dev.pluto.examples.motion_lab.png) expected=dev.pluto.examples.motion_lab ;;
      app-dev.pluto.examples.ink_lab.png) expected=dev.pluto.examples.ink_lab ;;
      app-dev.pluto.validation_lab.png) expected=dev.pluto.validation_lab ;;
      switcher-selected-dev.pluto.validation_lab.png) expected=dev.pluto.validation_lab ;;
      app-dev.pluto.ink-before-switcher.png | ink-canvas-before-stroke.png | ink-stroke.png) expected=dev.pluto.ink ;;
      switcher-dev.pluto.ink.png | app-dev.pluto.launcher.png) expected=dev.pluto.launcher ;;
      *) exit 65 ;;
    esac
    [[ -n "$output" && "$app" == "$expected" && "$surface" == post-dither ]]
    cp "$PNG_FIXTURE_DIR/${output##*/}" "$output"
    ;;
  *)
    exit 64
    ;;
esac
EOF
chmod 0755 "$TMP/bin/pluto"

cat > "$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${SSH_ARGV_LOG:-}" ]]; then
  printf '%s\n' BEGIN >> "$SSH_ARGV_LOG"
  printf 'arg=%s\n' "$@" >> "$SSH_ARGV_LOG"
fi
command=${!#}
case "$command" in
  *'/home/root/pluto/share/release-revision'*)
    if [[ "${IDENTITY_FAIL:-0}" == 1 ]]; then
      exit 82
    fi
    exit 0
    ;;
  *"sed -n '2p' /run/pluto/switcher-active"*)
    printf 'dev.pluto.validation_lab\n'
    ;;
  *'expected exactly one common Pluto supervisor'*)
    if [[ "${SUPERVISOR_FAIL:-0}" == 1 ]]; then
      printf 'release AOT smoke: expected exactly one common Pluto supervisor, found 0\n' >&2
      exit 84
    fi
    printf 'release AOT smoke: PASS common supervisor unit=xochitl.service pid=100\n'
    ;;
  *'switcher never became ready'*)
    [[ "$command" == *'host_mode=cold'* &&
      "$command" == *'host_mode=warm'* &&
      "$command" == *'/run/pluto/warm-apps/dev.pluto.launcher.pid'* &&
      "$command" == *'--ready-file='* &&
      "$command" == *'--health-file='* ]] ||
      exit 66
    printf 'release AOT smoke: PASS switcher origin=dev.pluto.ink host=200\n'
    ;;
  *'switcher UI did not foreground'*)
    [[ "$command" == *'host_mode=cold'* &&
      "$command" == *'host_mode=warm'* &&
      "$command" == *'/run/pluto/warm-apps/dev.pluto.launcher.pid'* ]] ||
      exit 66
    printf 'release AOT smoke: PASS switcher UI selected dev.pluto.validation_lab pid=201\n'
    ;;
  *'release-aot-prepare-ink'*)
    case "${PREPARE_RECEIPT_MODE:-action}" in
      action)
        receipt='{"requestId":"release-aot-prepare-ink","ok":true,"result":{"appId":"dev.pluto.ink","pid":202,"processStartTicks":404,"canvasReady":true,"actionCount":2,"surfaceGeneration":23,"proofFrameId":17}}'
        ;;
      mounted)
        receipt='{"requestId":"release-aot-prepare-ink","ok":true,"result":{"appId":"dev.pluto.ink","pid":202,"processStartTicks":404,"canvasReady":true,"actionCount":0,"surfaceGeneration":24,"proofFrameId":19}}'
        ;;
      missing-present)
        receipt='{"requestId":"release-aot-prepare-ink","ok":true,"result":{"appId":"dev.pluto.ink","pid":202,"processStartTicks":404,"canvasReady":true,"actionCount":2,"surfaceGeneration":23,"proofFrameId":0}}'
        ;;
      extra-field)
        receipt='{"requestId":"release-aot-prepare-ink","ok":true,"result":{"appId":"dev.pluto.ink","pid":202,"processStartTicks":404,"canvasReady":true,"actionCount":2,"surfaceGeneration":23,"proofFrameId":17,"fixture":true}}'
        ;;
      wrong-start)
        receipt='{"requestId":"release-aot-prepare-ink","ok":true,"result":{"appId":"dev.pluto.ink","pid":202,"processStartTicks":405,"canvasReady":true,"actionCount":2,"surfaceGeneration":23,"proofFrameId":17}}'
        ;;
      presentation-timeout)
        receipt='{"requestId":"release-aot-prepare-ink","ok":false,"error":{"code":"presentation-timeout","message":"Ink canvas did not complete its exact Full panel proof"}}'
        ;;
      *) exit 64 ;;
    esac
    printf 'pid=202\nstart_ticks=404\nresponse=%s\n' "$receipt"
    ;;
  *'prepared Ink process identity changed'*)
    if [[ "${INK_IDENTITY_FAIL:-0}" == 1 ]]; then
      printf 'release AOT smoke: prepared Ink process identity changed\n' >&2
      exit 92
    fi
    ;;
  *'Ink stroke produced no completion-backed present'*)
    printf 'release AOT smoke: PASS Ink stroke pid=202 response={"ok":true,"result":{"appId":"dev.pluto.ink","pid":202,"eventCount":24}}\n'
    ;;
  *'never published matching AOT receipts'*)
    [[ "$command" == *'health_wait=2'* &&
      "$command" == *'health_wait" -le 10'* &&
      "$command" == *'health_advanced=1'* &&
      "$command" == *'current_start_ticks=$(sed'* ]] ||
      exit 67
    printf 'release AOT smoke: PASS app pid=203 present_after=1s\n'
    ;;
  *'debug/JIT state absent'*)
    printf 'release AOT smoke: all supported apps and switcher passed; Ink changed decoded post-dither pixels; debug/JIT state absent\n'
    ;;
  *)
    echo "unexpected fake ssh command: $command" >&2
    exit 65
    ;;
esac
EOF
chmod 0755 "$TMP/bin/ssh"

cat > "$TMP/stage-hook" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
label=$1
camera_dir=$PLUTO_CAMERA_ACCEPTANCE_DIR
screenshot_dir=$PLUTO_ACCEPTANCE_SCREENSHOT_DIR
mkdir -p "$camera_dir"
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
provenance="$camera_dir/camera-provenance.tsv"
if [[ ! -e "$provenance" ]]; then
  stage_path="$(cd -P "$(dirname "$0")" && pwd)/$(basename "$0")"
  capture_path="$(cd -P "$(dirname "$PLUTO_CAMERA_CAPTURE")" && pwd)/$(basename "$PLUTO_CAMERA_CAPTURE")"
  cat > "$provenance" <<PROVENANCE
test_seam	${PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS:-0}
capture_mode	test-override
capture_override_requested	1
camera_config_override_requested	0
camera_rig	$PLUTO_CAMERA_RIG
camera_profile_id	not-applicable
camera_stage_hook_path	$stage_path
camera_stage_hook_sha256	$(sha256_file "$stage_path")
camera_capture_path	$capture_path
camera_capture_sha256	$(sha256_file "$capture_path")
camera_driver_path	not-applicable
camera_driver_sha256	not-applicable
camera_python_binary	not-applicable
camera_python_sha256	not-applicable
camera_ffmpeg_binary	not-applicable
camera_ffmpeg_sha256	not-applicable
camera_ffprobe_binary	not-applicable
camera_ffprobe_sha256	not-applicable
camera_config_path	not-applicable
camera_config_sha256	not-applicable
camera_config_snapshot	not-applicable
camera_config_snapshot_sha256	not-applicable
PROVENANCE
fi
if [[ -f "$camera_dir/stages.tsv" ]]; then
  count=$(wc -l < "$camera_dir/stages.tsv")
else
  count=0
fi
count=${count//[[:space:]]/}
sequence=$((count + 1))
printf -v filename '%02d-%s.jpg' "$sequence" "$label"
cp "$JPG_FIXTURE_DIR/$label.jpg" "$camera_dir/$filename"
if command -v sha256sum >/dev/null 2>&1; then
  camera_digest=$(sha256sum "$camera_dir/$filename" | awk '{print $1}')
  screenshot_digest=$(sha256sum "$screenshot_dir/$label.png" | awk '{print $1}')
  metadata_digest=$(sha256sum "$camera_dir/metadata.tsv" | awk '{print $1}')
else
  camera_digest=$(shasum -a 256 "$camera_dir/$filename" | awk '{print $1}')
  screenshot_digest=$(shasum -a 256 "$screenshot_dir/$label.png" | awk '{print $1}')
  metadata_digest=$(shasum -a 256 "$camera_dir/metadata.tsv" | awk '{print $1}')
fi
printf '%02d\t%s\t%s\t%s\n' "$sequence" "$label" "$camera_digest" "$filename" >> \
  "$camera_dir/stages.tsv"
EOF
chmod 0755 "$TMP/stage-hook"

cat > "$TMP/metrics-collector" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
manifest=''
output=''
device=''
port=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --release-manifest) manifest=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --device) device=$2; shift 2 ;;
    --port) port=$2; shift 2 ;;
    --samples | --interval-seconds) shift 2 ;;
    *) exit 64 ;;
  esac
done
[[ -f "$manifest" && -n "$output" && ! -e "$output" &&
  -n "$device" && "$port" =~ ^[1-9][0-9]{0,4}$ &&
  -n "${FIXTURE_REPO_ROOT:-}" ]]
mkdir -p "$output"
revision=$(sed -n 's/^.*"gitRevision":"\([0-9a-f]\{40\}\)".*$/\1/p' "$manifest")
fixture_sha() {
  if [[ -x /usr/bin/sha256sum ]]; then
    /usr/bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
  elif [[ -x /bin/sha256sum ]]; then
    /bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
  else
    LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
  fi
}
manifest_sha=$(fixture_sha "$manifest")
identity_helper_sha=$(fixture_sha \
  "$FIXTURE_REPO_ROOT/tools/device/diagnostics/acceptance_identity.py")
remote_collector_sha=$(fixture_sha \
  "$FIXTURE_REPO_ROOT/tools/device/diagnostics/acceptance-metrics/remote-collector.sh")
manifest_verifier_sha=$(fixture_sha \
  "$FIXTURE_REPO_ROOT/tools/device/diagnostics/acceptance-metrics/verify_manifest.dart")
python_sha=$(fixture_sha /usr/bin/python3)
printf 'fixture commands\n' > "$output/commands.log"
printf 'format=pluto-acceptance-evidence\ncollection.status=PASS\n' > \
  "$output/device-evidence.txt"
cat > "$output/summary.txt" <<SUMMARY
format=pluto-acceptance-bundle
device=$device
port=$port
transport=test-hook
ssh_binary=not-used
test_seam=1
identity_helper_sha256=$identity_helper_sha
remote_collector_sha256=$remote_collector_sha
manifest_verifier_sha256=$manifest_verifier_sha
python_binary=/usr/bin/python3
python_sha256=$python_sha
dart_binary=/fixture/dart
dart_sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
remote_shell=/bin/sh
profile=move
target=linux-arm64
git_revision=$revision
local_manifest=$manifest_sha
status=PASS
SUMMARY
cat > "$output/manifest-proof.json" <<PROOF
{
  "format": "pluto-acceptance-manifest-proof",
  "gitRevision": "$revision",
  "installedFileCount": 42,
  "manifestSha256": "$manifest_sha",
  "sliceTreeSha256": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
  "status": "PASS",
  "target": "linux-arm64"
}
PROOF
: > "$output/SHA256SUMS"
for file in commands.log device-evidence.txt summary.txt manifest-proof.json; do
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$output/$file" | awk '{print $1}')
  else
    digest=$(shasum -a 256 "$output/$file" | awk '{print $1}')
  fi
  printf '%s  %s\n' "$digest" "$file" >> "$output/SHA256SUMS"
done
EOF
chmod 0755 "$TMP/metrics-collector"

common_env=(
  PATH="$TMP/bin:$PATH"
  FIXTURE_REPO_ROOT="$ROOT"
  PNG_FIXTURE_DIR="$TMP/png-fixtures"
  JPG_FIXTURE_DIR="$TMP/jpg-fixtures"
  PLUTO_ACCEPTANCE_REQUIRE_VISUAL=1
  PLUTO_ACCEPTANCE_COLLECT_ONLY=1
  PLUTO_ACCEPTANCE_CAPTURE_SETTLE=0.001
  PLUTO_ACCEPTANCE_RELEASE_REVISION="$REVISION"
  PLUTO_ACCEPTANCE_PROFILE_ID=move
  PLUTO_ACCEPTANCE_RELEASE_MANIFEST="$TMP/release-manifest.json"
  PLUTO_ACCEPTANCE_METRICS_COLLECTOR="$TMP/metrics-collector"
  PLUTO_ACCEPTANCE_STAGE_HOOK="$TMP/stage-hook"
  PLUTO_CAMERA_CAPTURE="$TMP/stage-hook"
  PLUTO_CAMERA_RIG=2
  PLUTO_ACCEPTANCE_STAGE_DELAY=0
)
fixture_transport_env=(
  PLUTO_CLI="$TMP/bin/pluto"
  PLUTO_ACCEPTANCE_SSH_BIN="$TMP/bin/ssh"
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1
)

if env PLUTO_ACCEPTANCE_REQUIRE_VISUAL=1 \
  PLUTO_ACCEPTANCE_COLLECT_ONLY=1 \
  PLUTO_ACCEPTANCE_TRANSPORT="$TMP/transport.sh" \
  "$SMOKE" root@fixture-device >"$TMP/custom-transport.out" 2>&1; then
  fail 'production visual smoke accepted a custom metrics transport'
fi
grep -q 'final visual acceptance forbids a custom metrics transport' \
  "$TMP/custom-transport.out" ||
  fail 'custom metrics transport did not fail during visual preflight'

if PLUTO_CLI="$TMP/bin/pluto" \
  "$SMOKE" root@fixture-device >"$TMP/cli-override.out" 2>&1; then
  fail 'production smoke accepted a Pluto CLI override'
fi
grep -q 'PLUTO_CLI requires PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1' \
  "$TMP/cli-override.out" ||
  fail 'Pluto CLI override did not require the explicit test seam'

if PLUTO_ACCEPTANCE_SSH_BIN="$TMP/bin/ssh" \
  "$SMOKE" root@fixture-device >"$TMP/ssh-override.out" 2>&1; then
  fail 'production smoke accepted an SSH binary override'
fi
grep -q \
  'PLUTO_ACCEPTANCE_SSH_BIN requires PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1' \
  "$TMP/ssh-override.out" ||
  fail 'SSH binary override did not require the explicit test seam'

mkdir -p "$TMP/no-home" "$TMP/path-shims"
cat > "$TMP/path-shims/pluto" <<EOF
#!/bin/sh
: > '$TMP/path-pluto-used'
exit 0
EOF
cat > "$TMP/path-shims/ssh" <<EOF
#!/bin/sh
: > '$TMP/path-ssh-used'
exit 0
EOF
cat > "$TMP/path-shims/python3" <<EOF
#!/bin/sh
: > '$TMP/path-python-used'
exit 0
EOF
for shim in bash ffmpeg ffprobe dirname awk; do
  cat > "$TMP/path-shims/$shim" <<EOF
#!/bin/sh
: > '$TMP/path-$shim-used'
exit 0
EOF
done
chmod 0755 "$TMP/path-shims/pluto" "$TMP/path-shims/ssh" \
  "$TMP/path-shims/python3" "$TMP/path-shims/bash" \
  "$TMP/path-shims/ffmpeg" "$TMP/path-shims/ffprobe" \
  "$TMP/path-shims/dirname" "$TMP/path-shims/awk"
cat > "$TMP/acceptance-bash-env" <<EOF
: > '$TMP/path-bash-env-used'
EOF
if PATH="$TMP/path-shims:$PATH" BASH_ENV="$TMP/acceptance-bash-env" \
  PLUTO_BIN_DIR="$TMP/path-shims" \
  "$SMOKE" root@127.0.0.1:1 >"$TMP/path-pluto.out" 2>&1; then
  fail 'production smoke unexpectedly reached a device on localhost:1'
fi
[[ ! -e "$TMP/path-pluto-used" ]] ||
  fail 'production smoke executed a Pluto CLI shim from PATH or PLUTO_BIN_DIR'
[[ ! -e "$TMP/path-python-used" ]] ||
  fail 'production smoke executed a Python shim from PATH'
for marker in bash ffmpeg ffprobe dirname awk bash-env; do
  [[ ! -e "$TMP/path-$marker-used" ]] ||
    fail "production smoke executed a $marker startup/PATH shim"
done
if (
  dirname() {
    : > "$TMP/path-exported-function-used"
    /usr/bin/dirname "$@"
  }
  export -f dirname
  PATH="$TMP/path-shims:$PATH" "$SMOKE" root@127.0.0.1:1 >/dev/null 2>&1
); then
  fail 'production smoke unexpectedly reached a device with an exported function'
fi
[[ ! -e "$TMP/path-exported-function-used" ]] ||
  fail 'production smoke imported an exported shell function'

if PATH="$TMP/path-shims:$PATH" \
  "$SMOKE" root@127.0.0.1:1 >"$TMP/path-ssh.out" 2>&1; then
  fail 'production smoke unexpectedly reached a device on localhost:1'
fi
[[ ! -e "$TMP/path-ssh-used" ]] ||
  fail 'production smoke executed an SSH shim from PATH'

if LD_LIBRARY_PATH="$TMP/path-shims" \
  "$SMOKE" root@127.0.0.1:1 >"$TMP/loader-env.out" 2>&1; then
  fail 'production smoke accepted loader-injection environment'
fi
grep -q 'LD_LIBRARY_PATH is forbidden for production acceptance' \
  "$TMP/loader-env.out" ||
  fail 'production smoke did not diagnose loader-injection environment'

if PLUTO_ACCEPTANCE_FFMPEG_BIN="$TMP/path-shims/ffmpeg" \
  "$SMOKE" root@127.0.0.1:1 >"$TMP/ffmpeg-override.out" 2>&1; then
  fail 'production smoke accepted an FFmpeg override'
fi
grep -q 'PLUTO_ACCEPTANCE_FFMPEG_BIN requires' "$TMP/ffmpeg-override.out" ||
  fail 'production smoke did not gate its FFmpeg override'

: > "$TMP/preflight-calls"
set +e
env PATH="$TMP/bin:$PATH" PNG_FIXTURE_DIR="$TMP/png-fixtures" \
  PLUTO_CLI="$TMP/bin/pluto" PLUTO_ACCEPTANCE_SSH_BIN="$TMP/bin/ssh" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 PLUTO_ACCEPTANCE_STAGE_DELAY=0 \
  PLUTO_ACCEPTANCE_CAPTURE_SETTLE=0 SUPERVISOR_FAIL=1 \
  PLUTO_FAKE_CALL_LOG="$TMP/preflight-calls" \
  "$SMOKE" root@fixture-device > "$TMP/preflight.out" 2>&1
preflight_rc=$?
set -e
[[ "$preflight_rc" != 0 ]] ||
  fail 'hardware smoke continued after a failed supervisor preflight'
[[ ! -s "$TMP/preflight-calls" ]] ||
  fail 'hardware smoke launched an app before proving the common supervisor'
grep -q 'expected exactly one common Pluto supervisor' "$TMP/preflight.out" ||
  fail 'supervisor preflight failure did not report the real blocker'

cat > "$TMP/camera-binding.json" <<'JSON'
{"devices":[{"number":2,"profile_id":"rm1"}]}
JSON
for camera_mismatch in '2|move' '3|rm1'; do
  IFS='|' read -r camera_rig camera_profile <<< "$camera_mismatch"
  error_file="$TMP/camera-binding-$camera_rig-$camera_profile.err"
  if env \
    PLUTO_ACCEPTANCE_REQUIRE_VISUAL=1 \
    PLUTO_ACCEPTANCE_COLLECT_ONLY=1 \
    PLUTO_ACCEPTANCE_CAPTURE_SETTLE=0.001 \
    PLUTO_ACCEPTANCE_RELEASE_REVISION="$REVISION" \
    PLUTO_ACCEPTANCE_PROFILE_ID="$camera_profile" \
    PLUTO_ACCEPTANCE_RELEASE_MANIFEST="$TMP/release-manifest.json" \
    PLUTO_ACCEPTANCE_STAGE_HOOK="$ROOT/tools/setup/camera/capture-acceptance-stage.sh" \
    PLUTO_ACCEPTANCE_SCREENSHOT_DIR="$TMP/camera-binding-shots-$camera_rig-$camera_profile" \
    PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/camera-binding-camera-$camera_rig-$camera_profile" \
    PLUTO_CAMERA_CONFIG="$TMP/camera-binding.json" \
    PLUTO_CAMERA_RIG="$camera_rig" \
    "$SMOKE" root@fixture-device >/dev/null 2>"$error_file"; then
    fail "production visual smoke accepted camera mismatch $camera_mismatch"
  fi
  grep -q 'selected camera rig is not bound' "$error_file" ||
    fail "camera mismatch $camera_mismatch did not fail at the rig/profile binding"
done

if env "${common_env[@]}" PLUTO_ACCEPTANCE_COLLECT_ONLY=0 \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
  PLUTO_ACCEPTANCE_SCREENSHOT_DIR="$TMP/one-pass-screenshots" \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/one-pass-camera" \
  "$SMOKE" root@fixture-device >/dev/null 2>&1; then
  fail 'strict visual mode accepted an impossible one-pass review flow'
fi

env PATH="$TMP/bin:$PATH" PNG_FIXTURE_DIR="$TMP/png-fixtures" \
  PLUTO_CLI="$TMP/bin/pluto" PLUTO_ACCEPTANCE_SSH_BIN="$TMP/bin/ssh" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 PLUTO_ACCEPTANCE_STAGE_DELAY=0 \
  PLUTO_ACCEPTANCE_CAPTURE_SETTLE=0 \
  PLUTO_FAKE_CALL_LOG="$TMP/strict-cli-calls" \
  SSH_ARGV_LOG="$TMP/strict-ssh-argv" \
  PREPARE_RECEIPT_MODE=mounted \
  "$SMOKE" root@fixture-device > "$TMP/nonvisual.out" ||
  fail 'ordinary hardware smoke rejected an already-mounted Ink canvas receipt'
grep -q 'Ink changed decoded post-dither pixels' "$TMP/nonvisual.out" ||
  fail 'ordinary hardware smoke overstated dispatch as visual proof'
grep -q 'action_count=0 surface_generation=24 proof_frame_id=19' \
  "$TMP/nonvisual.out" ||
  fail 'already-mounted Ink canvas did not require a fresh presentation receipt'
grep -q "strict_ssh=1 ssh_bin=$TMP/bin/ssh" "$TMP/strict-cli-calls" ||
  fail 'acceptance-strict SSH mode was not inherited by Pluto CLI commands'
for strict_arg in \
  '-F' '/dev/null' 'StrictHostKeyChecking=yes' 'ProxyCommand=none' \
  'CanonicalizeHostname=no' 'ControlMaster=no' 'ControlPath=none' \
  'ControlPersist=no'; do
  grep -Fqx -- "arg=$strict_arg" "$TMP/strict-ssh-argv" ||
    fail "raw SSH omitted strict argument: $strict_arg"
done

if env PATH="$TMP/bin:$PATH" PNG_FIXTURE_DIR="$TMP/png-fixtures" \
  PLUTO_CLI="$TMP/bin/pluto" PLUTO_ACCEPTANCE_SSH_BIN="$TMP/bin/ssh" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 PLUTO_ACCEPTANCE_STAGE_DELAY=0 \
  PLUTO_ACCEPTANCE_CAPTURE_SETTLE=0 \
  PREPARE_RECEIPT_MODE=missing-present \
  "$SMOKE" root@fixture-device >"$TMP/missing-present.out" 2>&1; then
  fail 'mutating Ink preparation without a native presentation receipt passed'
fi
grep -q 'invalid presentation receipt' "$TMP/missing-present.out" ||
  fail 'missing Ink presentation receipt was rejected for the wrong reason'

if env PATH="$TMP/bin:$PATH" PNG_FIXTURE_DIR="$TMP/png-fixtures" \
  PLUTO_CLI="$TMP/bin/pluto" PLUTO_ACCEPTANCE_SSH_BIN="$TMP/bin/ssh" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 PLUTO_ACCEPTANCE_STAGE_DELAY=0 \
  PLUTO_ACCEPTANCE_CAPTURE_SETTLE=0 \
  PREPARE_RECEIPT_MODE=presentation-timeout \
  "$SMOKE" root@fixture-device >"$TMP/presentation-timeout.out" 2>&1; then
  fail 'failed Ink presentation proof passed'
fi
grep -q 'prepare request failed: presentation-timeout: Ink canvas did not complete its exact Full panel proof' \
  "$TMP/presentation-timeout.out" ||
  fail 'failed Ink presentation proof did not preserve the remote diagnosis'

for invalid_receipt_mode in extra-field wrong-start; do
  if env PATH="$TMP/bin:$PATH" PNG_FIXTURE_DIR="$TMP/png-fixtures" \
    PLUTO_CLI="$TMP/bin/pluto" PLUTO_ACCEPTANCE_SSH_BIN="$TMP/bin/ssh" \
    PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 PLUTO_ACCEPTANCE_STAGE_DELAY=0 \
    PLUTO_ACCEPTANCE_CAPTURE_SETTLE=0 \
    PREPARE_RECEIPT_MODE="$invalid_receipt_mode" \
    "$SMOKE" root@fixture-device \
    >"$TMP/invalid-receipt-$invalid_receipt_mode.out" 2>&1; then
    fail "invalid Ink receipt passed: $invalid_receipt_mode"
  fi
  grep -q 'invalid presentation receipt' \
    "$TMP/invalid-receipt-$invalid_receipt_mode.out" ||
    fail "invalid Ink receipt was rejected for the wrong reason: $invalid_receipt_mode"
done

if env PATH="$TMP/bin:$PATH" PNG_FIXTURE_DIR="$TMP/png-fixtures" \
  PLUTO_CLI="$TMP/bin/pluto" PLUTO_ACCEPTANCE_SSH_BIN="$TMP/bin/ssh" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 PLUTO_ACCEPTANCE_STAGE_DELAY=0 \
  PLUTO_ACCEPTANCE_CAPTURE_SETTLE=0 INK_IDENTITY_FAIL=1 \
  "$SMOKE" root@fixture-device >"$TMP/replaced-ink.out" 2>&1; then
  fail 'hardware smoke accepted an Ink process replacement after preparation'
fi
grep -q 'prepared Ink process identity changed' "$TMP/replaced-ink.out" ||
  fail 'replacement Ink process was rejected for the wrong reason'

env PATH="$TMP/bin:$PATH" PNG_FIXTURE_DIR="$TMP/png-fixtures" \
  PLUTO_CLI="$TMP/bin/pluto" PLUTO_ACCEPTANCE_SSH_BIN="$TMP/bin/ssh" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 PLUTO_ACCEPTANCE_STAGE_DELAY=0 \
  PLUTO_ACCEPTANCE_CAPTURE_SETTLE=0 \
  PLUTO_ACCEPTANCE_SSH_TARGET=root@127.0.0.1 \
  PLUTO_ACCEPTANCE_SSH_PORT=2222 \
  "$SMOKE" root@127.0.0.1:2222 >/dev/null ||
  fail 'equal explicit IPv4 CLI/SSH endpoints were rejected'

env PATH="$TMP/bin:$PATH" PNG_FIXTURE_DIR="$TMP/png-fixtures" \
  PLUTO_CLI="$TMP/bin/pluto" PLUTO_ACCEPTANCE_SSH_BIN="$TMP/bin/ssh" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 PLUTO_ACCEPTANCE_STAGE_DELAY=0 \
  PLUTO_ACCEPTANCE_CAPTURE_SETTLE=0 \
  PLUTO_ACCEPTANCE_SSH_TARGET='root@fe80::1%en7' \
  "$SMOKE" 'root@[fe80::1%en7]' >/dev/null ||
  fail 'equivalent bracketed CLI/raw-SSH IPv6 endpoints were rejected'

for mismatch in \
  'root@device|admin@device|22' \
  'root@device|root@other-device|22' \
  'root@device:2222|root@device|22'; do
  IFS='|' read -r cli_endpoint ssh_endpoint ssh_port <<< "$mismatch"
  if env PATH="$TMP/bin:$PATH" PNG_FIXTURE_DIR="$TMP/png-fixtures" \
    PLUTO_ACCEPTANCE_SSH_TARGET="$ssh_endpoint" \
    PLUTO_ACCEPTANCE_SSH_PORT="$ssh_port" \
    "$SMOKE" "$cli_endpoint" >/dev/null 2>&1; then
    fail "production smoke accepted split endpoint identity: $mismatch"
  fi
done

if env "${common_env[@]}" \
  PLUTO_ACCEPTANCE_SCREENSHOT_DIR="$TMP/unofficial-screenshots" \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/unofficial-camera" \
  "$SMOKE" root@fixture-device >/dev/null 2>&1; then
  fail 'strict visual mode accepted an arbitrary executable camera hook'
fi

if env "${common_env[@]}" \
  PLUTO_ACCEPTANCE_STAGE_HOOK="$ROOT/tools/setup/camera/capture-acceptance-stage.sh" \
  PLUTO_CAMERA_CAPTURE="$TMP/stage-hook" \
  PLUTO_ACCEPTANCE_SCREENSHOT_DIR="$TMP/substituted-screenshots" \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/substituted-camera" \
  "$SMOKE" root@fixture-device >/dev/null 2>&1; then
  fail 'strict visual mode accepted a substituted camera capture command'
fi

set +e
env "${common_env[@]}" "${fixture_transport_env[@]}" IDENTITY_FAIL=1 \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
  PLUTO_ACCEPTANCE_SCREENSHOT_DIR="$TMP/rejected-screenshots" \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/rejected-camera" \
  "$SMOKE" root@fixture-device >/dev/null 2>&1
identity_rc=$?
set -e
[[ "$identity_rc" != 0 ]] ||
  fail 'strict visual mode accepted a mismatched installed release identity'

env "${common_env[@]}" "${fixture_transport_env[@]}" WRITE_REVIEW=0 \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
  PLUTO_ACCEPTANCE_COLLECT_ONLY=1 \
  PLUTO_ACCEPTANCE_SCREENSHOT_DIR="$TMP/collect-screenshots" \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/collect-camera" \
  "$SMOKE" root@fixture-device > "$TMP/collect.out"
grep -q 'COLLECTED_NOT_ACCEPTED' "$TMP/collect.out" ||
  fail 'collect-only mode did not identify the evidence as unaccepted'
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" --camera-dir "$TMP/collect-camera" \
  --screenshot-dir "$TMP/collect-screenshots" >/dev/null 2>&1; then
  fail 'unreviewed collect-only evidence passed the final verifier'
fi

env "${common_env[@]}" "${fixture_transport_env[@]}" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
  PLUTO_ACCEPTANCE_SSH_TARGET=root@fixture-device \
  PLUTO_ACCEPTANCE_COLLECT_ONLY=1 \
  PLUTO_ACCEPTANCE_SCREENSHOT_DIR="$TMP/screenshots" \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/camera" \
  "$SMOKE" root@fixture-device > "$TMP/stdout"
grep -q $'^device_endpoint\troot@fixture-device:22$' "$TMP/camera/metadata.tsv" ||
  fail 'visual metadata did not record one canonical CLI endpoint'
grep -q $'^test_seam\t1$' "$TMP/camera/metadata.tsv" ||
  fail 'test-hook evidence was not permanently marked'
grep -q '^device=root@fixture-device$' "$TMP/camera/metrics/summary.txt" ||
  fail 'metrics summary was not collected from the visual device endpoint'
grep -q '^port=22$' "$TMP/camera/metrics/summary.txt" ||
  fail 'metrics summary did not record the visual device port'

cut -f2 "$TMP/camera/stages.tsv" > "$TMP/camera-labels"
cut -f1 "$TMP/screenshots/stages.tsv" > "$TMP/screenshot-labels"
cmp -s "$TMP/expected-labels" "$TMP/camera-labels" ||
  fail 'camera stages are missing, duplicated, or out of order'
cmp -s "$TMP/expected-labels" "$TMP/screenshot-labels" ||
  fail 'native screenshot stages do not match camera stages'
[[ "$(sort "$TMP/camera-labels" | uniq | wc -l | tr -d '[:space:]')" == 10 ]] ||
  fail 'stage labels are not unique'
[[ "$(find "$TMP/camera" -maxdepth 1 -name '*.jpg' -type f | wc -l | tr -d '[:space:]')" == 10 ]] ||
  fail 'camera evidence does not contain exactly 10 frames'
[[ "$(find "$TMP/screenshots" -maxdepth 1 -name '*.png' -type f | wc -l | tr -d '[:space:]')" == 10 ]] ||
  fail 'native evidence does not contain exactly 10 screenshots'

cp -R "$TMP/camera" "$TMP/noncanonical-endpoint-camera"
awk -F '\t' -v OFS='\t' \
  '$1 == "device_endpoint" {$2 = "root@fixture-device"} {print}' \
  "$TMP/noncanonical-endpoint-camera/metadata.tsv" > \
  "$TMP/noncanonical-endpoint-camera/metadata.new"
mv "$TMP/noncanonical-endpoint-camera/metadata.new" \
  "$TMP/noncanonical-endpoint-camera/metadata.tsv"
"$RECORD" --camera-dir "$TMP/noncanonical-endpoint-camera" \
  --screenshot-dir "$TMP/screenshots" --reviewer fixture-reviewer \
  --confirm-all-visible >/dev/null
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" \
  --camera-dir "$TMP/noncanonical-endpoint-camera" \
  --screenshot-dir "$TMP/screenshots" >/dev/null 2>&1; then
  fail 'verifier accepted a noncanonical recorded endpoint'
fi

cp -R "$TMP/camera" "$TMP/wrong-camera-profile-provenance"
awk -F '\t' -v OFS='\t' \
  '$1 == "camera_profile_id" {$2 = "move"} {print}' \
  "$TMP/wrong-camera-profile-provenance/camera-provenance.tsv" > \
  "$TMP/wrong-camera-profile-provenance/camera-provenance.new"
mv "$TMP/wrong-camera-profile-provenance/camera-provenance.new" \
  "$TMP/wrong-camera-profile-provenance/camera-provenance.tsv"
"$RECORD" --camera-dir "$TMP/wrong-camera-profile-provenance" \
  --screenshot-dir "$TMP/screenshots" --reviewer fixture-reviewer \
  --confirm-all-visible >/dev/null
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" \
  --camera-dir "$TMP/wrong-camera-profile-provenance" \
  --screenshot-dir "$TMP/screenshots" >/dev/null 2>&1; then
  fail 'verifier accepted a fabricated test camera profile binding'
fi

"$RECORD" --camera-dir "$TMP/camera" --screenshot-dir "$TMP/screenshots" \
  --reviewer fixture-reviewer --confirm-all-visible >/dev/null ||
  fail 'review recorder rejected the complete evidence set'
mkdir -p "$TMP/media-path-shims"
for shim in bash python3 ffmpeg ffprobe; do
  cat > "$TMP/media-path-shims/$shim" <<EOF
#!/bin/sh
: > '$TMP/verifier-$shim-shim-used'
exit 0
EOF
  chmod 0755 "$TMP/media-path-shims/$shim"
done
PATH="$TMP/media-path-shims:/usr/bin:/bin" \
  BASH_ENV="$TMP/acceptance-bash-env" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" \
  --camera-dir "$TMP/camera" \
  --screenshot-dir "$TMP/screenshots" >"$TMP/verify-pass.out" ||
  fail 'strict evidence verifier rejected complete decoded and reviewed evidence'
for marker in bash python3 ffmpeg ffprobe; do
  [[ ! -e "$TMP/verifier-$marker-shim-used" ]] ||
    fail "visual verifier executed a $marker PATH shim"
done
[[ ! -e "$TMP/path-bash-env-used" ]] ||
  fail 'visual verifier sourced BASH_ENV before isolating production tools'
grep -Eq 'python_binary=/usr/bin/python3 python_sha256=[0-9a-f]{64}' \
  "$TMP/verify-pass.out" || fail 'visual verifier omitted Python provenance'
grep -Eq 'ffmpeg_binary=/[^ ]+ ffmpeg_sha256=[0-9a-f]{64}' \
  "$TMP/verify-pass.out" || fail 'visual verifier omitted FFmpeg provenance'
grep -Eq 'ffprobe_binary=/[^ ]+ ffprobe_sha256=[0-9a-f]{64}' \
  "$TMP/verify-pass.out" || fail 'visual verifier omitted FFprobe provenance'
grep -q ' test_seam=1 ' "$TMP/verify-pass.out" ||
  fail 'visual verifier PASS omitted the exact test seam'
if "$VERIFY" --camera-dir "$TMP/camera" --screenshot-dir "$TMP/screenshots" \
  >/dev/null 2>&1; then
  fail 'production verifier accepted evidence collected through test seams'
fi

# A leftover test-hook environment cannot relax verification of a bundle that
# claims to be production evidence. The exact seam equality gate must fire
# before any later provenance inconsistency in this adversarial copy.
cp -R "$TMP/camera" "$TMP/production-metadata-with-test-hook"
awk -F '\t' -v OFS='\t' \
  '$1 == "test_seam" {$2 = "0"} {print}' \
  "$TMP/production-metadata-with-test-hook/metadata.tsv" > \
  "$TMP/production-metadata-with-test-hook/metadata.new"
mv "$TMP/production-metadata-with-test-hook/metadata.new" \
  "$TMP/production-metadata-with-test-hook/metadata.tsv"
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" \
  --camera-dir "$TMP/production-metadata-with-test-hook" \
  --screenshot-dir "$TMP/screenshots" \
  >"$TMP/production-metadata-with-test-hook.out" 2>&1; then
  fail 'leftover verifier test hook accepted production-marked metadata'
fi
grep -q 'verifier hook/evidence test seam mismatch' \
  "$TMP/production-metadata-with-test-hook.out" ||
  fail 'leftover verifier test hook did not fail at exact seam equality'

if PLUTO_ACCEPTANCE_FFMPEG_BIN="$TMP/media-path-shims/ffmpeg" \
  "$VERIFY" --camera-dir "$TMP/camera" --screenshot-dir "$TMP/screenshots" \
  >"$TMP/verifier-media-override.out" 2>&1; then
  fail 'production verifier accepted an FFmpeg override'
fi
grep -q 'ffmpeg override requires PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1' \
  "$TMP/verifier-media-override.out" ||
  fail 'production verifier did not diagnose its FFmpeg override gate'
if LD_LIBRARY_PATH="$TMP/media-path-shims" \
  "$VERIFY" --camera-dir "$TMP/camera" --screenshot-dir "$TMP/screenshots" \
  >"$TMP/verifier-loader.out" 2>&1; then
  fail 'production verifier accepted loader-injection environment'
fi
grep -q 'LD_LIBRARY_PATH is forbidden for production verification' \
  "$TMP/verifier-loader.out" ||
  fail 'production verifier did not diagnose loader-injection environment'

cp -R "$TMP/camera" "$TMP/split-device-metrics"
awk -F '=' \
  '$1 == "device" {$2 = "root@separate-test-fixture"} {print $1 "=" $2}' \
  "$TMP/split-device-metrics/metrics/summary.txt" > \
  "$TMP/split-device-metrics/metrics/summary.new"
mv "$TMP/split-device-metrics/metrics/summary.new" \
  "$TMP/split-device-metrics/metrics/summary.txt"
refresh_metrics_review_digest "$TMP/split-device-metrics"
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" \
  --camera-dir "$TMP/split-device-metrics" \
  --screenshot-dir "$TMP/screenshots" >"$TMP/split-device-metrics.out" 2>&1; then
  fail 'verifier accepted metrics collected from a different device endpoint'
fi
grep -q 'metrics SSH identity does not match the visual device endpoint' \
  "$TMP/split-device-metrics.out" ||
  fail 'split-device metrics were rejected for the wrong reason'

cp -R "$TMP/camera" "$TMP/substituted-production-ssh"
awk -F '=' \
  '$1 == "transport" {$2 = "ssh"} $1 == "ssh_binary" {$2 = "/tmp/fake-ssh"} {print $1 "=" $2}' \
  "$TMP/substituted-production-ssh/metrics/summary.txt" > \
  "$TMP/substituted-production-ssh/metrics/summary.new"
mv "$TMP/substituted-production-ssh/metrics/summary.new" \
  "$TMP/substituted-production-ssh/metrics/summary.txt"
refresh_metrics_review_digest "$TMP/substituted-production-ssh"
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" \
  --camera-dir "$TMP/substituted-production-ssh" \
  --screenshot-dir "$TMP/screenshots" \
  >"$TMP/substituted-production-ssh.out" 2>&1; then
  fail 'verifier accepted an SSH tuple with a substituted production binary'
fi
grep -q 'production SSH metrics did not use the pinned /usr/bin/ssh binary' \
  "$TMP/substituted-production-ssh.out" ||
  fail 'substituted production SSH binary was rejected for the wrong reason'

cp -R "$TMP/camera" "$TMP/inconsistent-metrics-provenance"
awk -F '=' \
  '$1 == "transport" {$2 = "ssh"} $1 == "test_seam" {$2 = "0"} \
   {print $1 "=" $2}' \
  "$TMP/inconsistent-metrics-provenance/metrics/summary.txt" > \
  "$TMP/inconsistent-metrics-provenance/metrics/summary.new"
mv "$TMP/inconsistent-metrics-provenance/metrics/summary.new" \
  "$TMP/inconsistent-metrics-provenance/metrics/summary.txt"
summary_digest="$(sha256_file \
  "$TMP/inconsistent-metrics-provenance/metrics/summary.txt")"
awk -v digest="$summary_digest" \
  '$2 == "summary.txt" {$1 = digest} {print $1 "  " $2}' \
  "$TMP/inconsistent-metrics-provenance/metrics/SHA256SUMS" > \
  "$TMP/inconsistent-metrics-provenance/metrics/SHA256SUMS.new"
mv "$TMP/inconsistent-metrics-provenance/metrics/SHA256SUMS.new" \
  "$TMP/inconsistent-metrics-provenance/metrics/SHA256SUMS"
metrics_digest="$(sha256_file \
  "$TMP/inconsistent-metrics-provenance/metrics/SHA256SUMS")"
awk -F '\t' -v OFS='\t' -v digest="$metrics_digest" \
  '{$7 = digest; print}' \
  "$TMP/inconsistent-metrics-provenance/review.tsv" > \
  "$TMP/inconsistent-metrics-provenance/review.new"
mv "$TMP/inconsistent-metrics-provenance/review.new" \
  "$TMP/inconsistent-metrics-provenance/review.tsv"
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" \
  --camera-dir "$TMP/inconsistent-metrics-provenance" \
  --screenshot-dir "$TMP/screenshots" \
  >"$TMP/inconsistent-metrics-provenance.out" 2>&1; then
  fail 'verifier accepted internally consistent metrics/metadata seam disagreement'
fi
grep -q 'metrics transport/test-seam provenance disagrees' \
  "$TMP/inconsistent-metrics-provenance.out" ||
  fail 'metrics provenance disagreement was rejected for the wrong reason'

cp -R "$TMP/camera" "$TMP/no-review-camera"
rm "$TMP/no-review-camera/review.tsv"
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" --camera-dir "$TMP/no-review-camera" \
  --screenshot-dir "$TMP/screenshots" >/dev/null 2>&1; then
  fail 'evidence verifier accepted frames without an optical review receipt'
fi
"$RECORD" --camera-dir "$TMP/no-review-camera" \
  --screenshot-dir "$TMP/screenshots" --reviewer fixture-reviewer \
  --confirm-all-visible >/dev/null || fail 'review recorder rejected complete evidence'
PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" --camera-dir "$TMP/no-review-camera" \
  --screenshot-dir "$TMP/screenshots" >/dev/null ||
  fail 'verifier rejected the newly bound optical review receipt'
if "$RECORD" --camera-dir "$TMP/no-review-camera" \
  --screenshot-dir "$TMP/screenshots" --reviewer replacement-reviewer \
  --confirm-all-visible >/dev/null 2>&1; then
  fail 'review recorder overwrote an existing review receipt'
fi

cp -R "$TMP/camera" "$TMP/stale-provenance-camera"
awk -F '\t' -v OFS='\t' \
  '$1 == "camera_stage_hook_path" {$2 = $2 ".changed"} {print}' \
  "$TMP/stale-provenance-camera/camera-provenance.tsv" > \
  "$TMP/stale-provenance-camera/camera-provenance.new"
mv "$TMP/stale-provenance-camera/camera-provenance.new" \
  "$TMP/stale-provenance-camera/camera-provenance.tsv"
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" \
  --camera-dir "$TMP/stale-provenance-camera" \
  --screenshot-dir "$TMP/screenshots" >/dev/null 2>&1; then
  fail 'evidence verifier accepted camera provenance changed after review'
fi

cp -R "$TMP/camera" "$TMP/bad-manifest-camera"
printf '\n' >> "$TMP/bad-manifest-camera/release-manifest.json"
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" --camera-dir "$TMP/bad-manifest-camera" \
  --screenshot-dir "$TMP/screenshots" >/dev/null 2>&1; then
  fail 'evidence verifier accepted a release manifest that changed after binding'
fi

cp -R "$TMP/camera" "$TMP/bad-jpeg-camera"
printf '\377\330not-a-decodable-jpeg\n' > \
  "$TMP/bad-jpeg-camera/01-app-dev.pluto.examples.counter.jpg"
bad_digest=$(sha256_file "$TMP/bad-jpeg-camera/01-app-dev.pluto.examples.counter.jpg")
awk -F '\t' -v OFS='\t' -v digest="$bad_digest" \
  'NR == 1 {$3 = digest} {print}' "$TMP/bad-jpeg-camera/stages.tsv" > \
  "$TMP/bad-jpeg-camera/stages.new"
mv "$TMP/bad-jpeg-camera/stages.new" "$TMP/bad-jpeg-camera/stages.tsv"
awk -F '\t' -v OFS='\t' -v digest="$bad_digest" \
  'NR == 1 {$2 = digest} {print}' "$TMP/bad-jpeg-camera/review.tsv" > \
  "$TMP/bad-jpeg-camera/review.new"
mv "$TMP/bad-jpeg-camera/review.new" "$TMP/bad-jpeg-camera/review.tsv"
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" --camera-dir "$TMP/bad-jpeg-camera" \
  --screenshot-dir "$TMP/screenshots" >/dev/null 2>&1; then
  fail 'evidence verifier accepted JPEG magic without a decodable image'
fi

cp -R "$TMP/screenshots" "$TMP/bad-png-screenshots"
cp -R "$TMP/camera" "$TMP/bad-png-camera"
printf '\211PNG\r\n\032\nnot-a-decodable-png\n' > \
  "$TMP/bad-png-screenshots/app-dev.pluto.examples.counter.png"
bad_digest=$(sha256_file "$TMP/bad-png-screenshots/app-dev.pluto.examples.counter.png")
awk -F '\t' -v OFS='\t' -v digest="$bad_digest" \
  'NR == 1 {$2 = digest} {print}' "$TMP/bad-png-screenshots/stages.tsv" > \
  "$TMP/bad-png-screenshots/stages.new"
mv "$TMP/bad-png-screenshots/stages.new" "$TMP/bad-png-screenshots/stages.tsv"
awk -F '\t' -v OFS='\t' -v digest="$bad_digest" \
  'NR == 1 {$3 = digest} {print}' "$TMP/bad-png-camera/review.tsv" > \
  "$TMP/bad-png-camera/review.new"
mv "$TMP/bad-png-camera/review.new" "$TMP/bad-png-camera/review.tsv"
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" --camera-dir "$TMP/bad-png-camera" \
  --screenshot-dir "$TMP/bad-png-screenshots" >/dev/null 2>&1; then
  fail 'evidence verifier accepted PNG magic without a decodable image'
fi

cp -R "$TMP/screenshots" "$TMP/no-pixel-change-screenshots"
cp -R "$TMP/camera" "$TMP/no-pixel-change-camera"
ffmpeg -v error -nostdin -y \
  -i "$TMP/screenshots/ink-canvas-before-stroke.png" \
  -compression_level 9 \
  "$TMP/no-pixel-change-screenshots/ink-stroke.png"
unchanged_digest=$(sha256_file "$TMP/no-pixel-change-screenshots/ink-stroke.png")
before_digest=$(sha256_file "$TMP/screenshots/ink-canvas-before-stroke.png")
[[ "$unchanged_digest" != "$before_digest" ]] ||
  fail 're-encoded no-op PNG fixture did not change its encoded digest'
awk -F '\t' -v OFS='\t' -v digest="$unchanged_digest" \
  '$1 == "ink-stroke" {$2 = digest} {print}' \
  "$TMP/no-pixel-change-screenshots/stages.tsv" > \
  "$TMP/no-pixel-change-screenshots/stages.new"
mv "$TMP/no-pixel-change-screenshots/stages.new" \
  "$TMP/no-pixel-change-screenshots/stages.tsv"
awk -F '\t' -v OFS='\t' -v digest="$unchanged_digest" \
  '$1 == "ink-stroke" {$3 = digest} {print}' \
  "$TMP/no-pixel-change-camera/review.tsv" > \
  "$TMP/no-pixel-change-camera/review.new"
mv "$TMP/no-pixel-change-camera/review.new" \
  "$TMP/no-pixel-change-camera/review.tsv"
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" \
  --camera-dir "$TMP/no-pixel-change-camera" \
  --screenshot-dir "$TMP/no-pixel-change-screenshots" >/dev/null 2>&1; then
  fail 'evidence verifier accepted encoded hash change without decoded Ink pixels'
fi

printf 'tamper\n' >> "$TMP/camera/09-ink-stroke.jpg"
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" --camera-dir "$TMP/camera" \
  --screenshot-dir "$TMP/screenshots" >/dev/null 2>&1; then
  fail 'evidence verifier accepted a tampered camera frame'
fi

echo 'release-aot-hardware-smoke_test: PASS'
