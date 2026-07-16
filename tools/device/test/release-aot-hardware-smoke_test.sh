#!/usr/bin/env bash
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

command -v ffmpeg >/dev/null 2>&1 || fail 'ffmpeg is required for visual evidence tests'
mkdir -p "$TMP/bin" "$TMP/png-fixtures" "$TMP/jpg-fixtures"
cat > "$TMP/release-manifest.json" <<EOF
{"gitRevision":"$REVISION","targets":{"linux-arm":{},"linux-arm64":{}}}
EOF

cat > "$TMP/expected-labels" <<'EOF'
app-dev.pluto.examples.counter
app-dev.pluto.examples.motion_lab
app-dev.pluto.examples.ink_lab
app-dev.pluto.validation_lab
app-dev.pluto.codex
app-dev.pluto.ink-before-switcher
switcher-dev.pluto.ink
switcher-selected-dev.pluto.codex
ink-canvas-before-stroke
ink-stroke
app-dev.pluto.launcher
EOF

sources=(
  apps/launcher/test_goldens/goldens/s02_home_grid.png
  apps/launcher/test_goldens/goldens/s20_app_switcher_portrait.png
  apps/codex/test_goldens/goldens/g01_empty_keyboard.png
  apps/codex/test_goldens/goldens/g02_conversation_color.png
  apps/codex/test_goldens/goldens/g03_handwriting_draft.png
  apps/launcher/test_goldens/goldens/s10_settings.png
  apps/launcher/test_goldens/goldens/s11_wifi_picker.png
  apps/launcher/test_goldens/goldens/s01_welcome.png
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
if [[ -n "${PLUTO_FAKE_CALL_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$PLUTO_FAKE_CALL_LOG"
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
      app-dev.pluto.codex.png | switcher-selected-dev.pluto.codex.png) expected=dev.pluto.codex ;;
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
command=${!#}
case "$command" in
  *'/home/root/pluto/share/release-revision'*)
    if [[ "${IDENTITY_FAIL:-0}" == 1 ]]; then
      exit 82
    fi
    exit 0
    ;;
  *"sed -n '2p' /run/pluto/switcher-active"*)
    printf 'dev.pluto.codex\n'
    ;;
  *'expected exactly one common Pluto supervisor'*)
    if [[ "${SUPERVISOR_FAIL:-0}" == 1 ]]; then
      printf 'release AOT smoke: expected exactly one common Pluto supervisor, found 0\n' >&2
      exit 84
    fi
    printf 'release AOT smoke: PASS common supervisor unit=xochitl.service pid=100\n'
    ;;
  *'switcher never became ready'*)
    printf 'release AOT smoke: PASS switcher origin=dev.pluto.ink host=200\n'
    ;;
  *'switcher UI did not foreground'*)
    printf 'release AOT smoke: PASS switcher UI selected dev.pluto.codex pid=201\n'
    ;;
  *'release-aot-prepare-ink'*)
    printf 'release AOT smoke: PASS real Ink canvas pid=202 response={"ok":true,"result":{"appId":"dev.pluto.ink","pid":202,"canvasReady":true,"actionCount":2}}\n'
    ;;
  *'Ink stroke produced no completion-backed present'*)
    printf 'release AOT smoke: PASS Ink stroke pid=202 response={"ok":true,"result":{"appId":"dev.pluto.ink","pid":202,"eventCount":24}}\n'
    ;;
  *'Codex app cannot resolve a real binary'*)
    printf 'release AOT smoke: PASS real authenticated Codex request response_sha256=fixture\n'
    ;;
  *'never published matching AOT receipts'*)
    printf 'release AOT smoke: PASS app pid=203 present_after=1s\n'
    ;;
  *'debug/JIT state absent'*)
    printf 'release AOT smoke: all standard apps and switcher passed; Ink changed decoded post-dither pixels; debug/JIT state absent\n'
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
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --release-manifest) manifest=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --device | --samples | --interval-seconds | --port) shift 2 ;;
    *) exit 64 ;;
  esac
done
[[ -f "$manifest" && -n "$output" && ! -e "$output" ]]
mkdir -p "$output"
revision=$(sed -n 's/^.*"gitRevision":"\([0-9a-f]\{40\}\)".*$/\1/p' "$manifest")
if command -v sha256sum >/dev/null 2>&1; then
  manifest_sha=$(sha256sum "$manifest" | awk '{print $1}')
else
  manifest_sha=$(shasum -a 256 "$manifest" | awk '{print $1}')
fi
printf 'fixture commands\n' > "$output/commands.log"
printf 'format=pluto-acceptance-evidence\ncollection.status=PASS\n' > \
  "$output/device-evidence.txt"
cat > "$output/summary.txt" <<SUMMARY
format=pluto-acceptance-bundle
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
  PNG_FIXTURE_DIR="$TMP/png-fixtures"
  JPG_FIXTURE_DIR="$TMP/jpg-fixtures"
  PLUTO_CLI=pluto
  PLUTO_ACCEPTANCE_REQUIRE_VISUAL=1
  PLUTO_ACCEPTANCE_COLLECT_ONLY=1
  PLUTO_ACCEPTANCE_CODEX_REQUEST=1
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

: > "$TMP/preflight-calls"
set +e
env PATH="$TMP/bin:$PATH" PNG_FIXTURE_DIR="$TMP/png-fixtures" \
  PLUTO_CLI=pluto PLUTO_ACCEPTANCE_STAGE_DELAY=0 \
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
    PLUTO_ACCEPTANCE_CODEX_REQUEST=1 \
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
  PLUTO_CLI=pluto PLUTO_ACCEPTANCE_STAGE_DELAY=0 \
  PLUTO_ACCEPTANCE_CAPTURE_SETTLE=0 \
  "$SMOKE" root@fixture-device > "$TMP/nonvisual.out" ||
  fail 'ordinary hardware smoke did not require decoded post-dither Ink change'
grep -q 'Ink changed decoded post-dither pixels' "$TMP/nonvisual.out" ||
  fail 'ordinary hardware smoke overstated dispatch as visual proof'

env PATH="$TMP/bin:$PATH" PNG_FIXTURE_DIR="$TMP/png-fixtures" \
  PLUTO_CLI=pluto PLUTO_ACCEPTANCE_STAGE_DELAY=0 \
  PLUTO_ACCEPTANCE_CAPTURE_SETTLE=0 \
  PLUTO_ACCEPTANCE_SSH_TARGET=root@127.0.0.1 \
  PLUTO_ACCEPTANCE_SSH_PORT=2222 \
  "$SMOKE" root@127.0.0.1:2222 >/dev/null ||
  fail 'equal explicit IPv4 CLI/SSH endpoints were rejected'

env PATH="$TMP/bin:$PATH" PNG_FIXTURE_DIR="$TMP/png-fixtures" \
  PLUTO_CLI=pluto PLUTO_ACCEPTANCE_STAGE_DELAY=0 \
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
    PLUTO_CLI=pluto PLUTO_ACCEPTANCE_SSH_TARGET="$ssh_endpoint" \
    PLUTO_ACCEPTANCE_SSH_PORT="$ssh_port" \
    "$SMOKE" "$cli_endpoint" >/dev/null 2>&1; then
    fail "production smoke accepted split endpoint identity: $mismatch"
  fi
done

if env "${common_env[@]}" PLUTO_ACCEPTANCE_CODEX_REQUEST=0 \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
  PLUTO_ACCEPTANCE_SCREENSHOT_DIR="$TMP/missing-screenshots" \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/missing-camera" \
  "$SMOKE" root@fixture-device >/dev/null 2>&1; then
  fail 'strict visual mode accepted a skipped Codex request'
fi

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
env "${common_env[@]}" IDENTITY_FAIL=1 \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
  PLUTO_ACCEPTANCE_SCREENSHOT_DIR="$TMP/rejected-screenshots" \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/rejected-camera" \
  "$SMOKE" root@fixture-device >/dev/null 2>&1
identity_rc=$?
set -e
[[ "$identity_rc" != 0 ]] ||
  fail 'strict visual mode accepted a mismatched installed release identity'

env "${common_env[@]}" WRITE_REVIEW=0 \
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

env "${common_env[@]}" \
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
  PLUTO_ACCEPTANCE_SSH_TARGET=root@separate-test-fixture \
  PLUTO_ACCEPTANCE_COLLECT_ONLY=1 \
  PLUTO_ACCEPTANCE_SCREENSHOT_DIR="$TMP/screenshots" \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/camera" \
  "$SMOKE" root@fixture-device > "$TMP/stdout"
grep -q $'^device_endpoint\troot@fixture-device:22$' "$TMP/camera/metadata.tsv" ||
  fail 'visual metadata did not record one canonical CLI endpoint'
grep -q $'^test_seam\t1$' "$TMP/camera/metadata.tsv" ||
  fail 'split endpoint test evidence was not permanently marked'

cut -f2 "$TMP/camera/stages.tsv" > "$TMP/camera-labels"
cut -f1 "$TMP/screenshots/stages.tsv" > "$TMP/screenshot-labels"
cmp -s "$TMP/expected-labels" "$TMP/camera-labels" ||
  fail 'camera stages are missing, duplicated, or out of order'
cmp -s "$TMP/expected-labels" "$TMP/screenshot-labels" ||
  fail 'native screenshot stages do not match camera stages'
[[ "$(sort "$TMP/camera-labels" | uniq | wc -l | tr -d '[:space:]')" == 11 ]] ||
  fail 'stage labels are not unique'
[[ "$(find "$TMP/camera" -maxdepth 1 -name '*.jpg' -type f | wc -l | tr -d '[:space:]')" == 11 ]] ||
  fail 'camera evidence does not contain exactly 11 frames'
[[ "$(find "$TMP/screenshots" -maxdepth 1 -name '*.png' -type f | wc -l | tr -d '[:space:]')" == 11 ]] ||
  fail 'native evidence does not contain exactly 11 screenshots'

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
PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" --camera-dir "$TMP/camera" \
  --screenshot-dir "$TMP/screenshots" >/dev/null ||
  fail 'strict evidence verifier rejected complete decoded and reviewed evidence'
if "$VERIFY" --camera-dir "$TMP/camera" --screenshot-dir "$TMP/screenshots" \
  >/dev/null 2>&1; then
  fail 'production verifier accepted evidence collected through test seams'
fi

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

printf 'tamper\n' >> "$TMP/camera/10-ink-stroke.jpg"
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 "$VERIFY" --camera-dir "$TMP/camera" \
  --screenshot-dir "$TMP/screenshots" >/dev/null 2>&1; then
  fail 'evidence verifier accepted a tampered camera frame'
fi

echo 'release-aot-hardware-smoke_test: PASS'
