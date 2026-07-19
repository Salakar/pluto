#!/bin/bash -p
set -euo pipefail
[[ "$-" == *p* ]] || {
  echo "visual acceptance verifier: execute this entrypoint directly or with /bin/bash -p" >&2
  exit 64
}

ALLOW_TEST_EVIDENCE="${PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS:-0}"
[[ "$ALLOW_TEST_EVIDENCE" == 0 || "$ALLOW_TEST_EVIDENCE" == 1 ]] || {
  echo "visual acceptance verifier: PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS must be 0 or 1" >&2
  exit 1
}
LOADER_ENV_NAMES=()
while IFS= read -r loader_name; do
  case "$loader_name" in
    LD_* | DYLD_* | GLIBC_TUNABLES) LOADER_ENV_NAMES+=("$loader_name") ;;
  esac
done < <(compgen -e)
if [[ "$ALLOW_TEST_EVIDENCE" != 1 ]] && ((${#LOADER_ENV_NAMES[@]} > 0)); then
  for loader_name in "${LOADER_ENV_NAMES[@]}"; do
    [[ -z "${!loader_name:-}" ]] || {
      echo "visual acceptance verifier: $loader_name is forbidden for production verification" >&2
      exit 1
    }
  done
fi
unset BASH_ENV ENV CDPATH GLOBIGNORE
if ((${#LOADER_ENV_NAMES[@]} > 0)); then
  for loader_name in "${LOADER_ENV_NAMES[@]}"; do
    unset "$loader_name"
  done
fi
if [[ "$ALLOW_TEST_EVIDENCE" != 1 ]]; then
  PATH=/usr/bin:/bin
  export PATH
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OFFICIAL_STAGE_HOOK="$ROOT/tools/setup/camera/capture-acceptance-stage.sh"
OFFICIAL_CAMERA_CAPTURE="$ROOT/tools/setup/camera/capture.sh"
OFFICIAL_CAMERA_DRIVER="$ROOT/tools/setup/camera/camera.py"
OFFICIAL_METRICS_COLLECTOR="$SCRIPT_DIR/acceptance-metrics/collect.sh"
REMOTE_METRICS_COLLECTOR="$SCRIPT_DIR/acceptance-metrics/remote-collector.sh"
ACCEPTANCE_IDENTITY="$SCRIPT_DIR/acceptance_identity.py"
MANIFEST_VERIFIER="$SCRIPT_DIR/acceptance-metrics/verify_manifest.dart"
PIXEL_VERIFIER="$SCRIPT_DIR/verify_visual_pixels.py"
CAMERA_DIR=""
SCREENSHOT_DIR=""
SDK_OVERRIDE="${PLUTO_SDK:-}"
PYTHON_BIN=/usr/bin/python3
FFMPEG_OVERRIDE="${PLUTO_ACCEPTANCE_FFMPEG_BIN:-}"
FFPROBE_OVERRIDE="${PLUTO_ACCEPTANCE_FFPROBE_BIN:-}"
METRICS_OVERRIDE_NAMES=()
while IFS= read -r override_name; do
  [[ -z "$override_name" ]] || METRICS_OVERRIDE_NAMES+=("$override_name")
done < <(compgen -v PLUTO_METRICS_ || true)

usage() {
  echo "usage: $0 --camera-dir DIR --screenshot-dir DIR" >&2
  exit 64
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --camera-dir)
      [[ "$#" -ge 2 ]] || usage
      CAMERA_DIR="$2"
      shift 2
      ;;
    --screenshot-dir)
      [[ "$#" -ge 2 ]] || usage
      SCREENSHOT_DIR="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

die() {
  echo "visual acceptance verifier: $*" >&2
  exit 1
}

[[ "$ALLOW_TEST_EVIDENCE" == 0 || "$ALLOW_TEST_EVIDENCE" == 1 ]] ||
  die "PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS must be 0 or 1"
[[ -x "$PYTHON_BIN" && -f "$PYTHON_BIN" ]] ||
  die "pinned Python interpreter is unavailable: /usr/bin/python3"
ACCOUNT_HOME="$("$PYTHON_BIN" -I -c \
  'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')" ||
  die "cannot resolve the operating-system account home"
[[ "$ACCOUNT_HOME" == /* && "$ACCOUNT_HOME" != *$'\n'* &&
  "$ACCOUNT_HOME" != *$'\t'* && -d "$ACCOUNT_HOME" ]] ||
  die "operating-system account home is invalid"

sha256_file() {
  if [[ -x /usr/bin/sha256sum ]]; then
    /usr/bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
  elif [[ -x /bin/sha256sum ]]; then
    /bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
  elif [[ -x /usr/bin/shasum ]]; then
    LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
  else
    die "pinned SHA-256 tool is unavailable"
  fi
}

canonical_executable() {
  local candidate="$1"
  local label="$2"
  local resolved
  [[ "$candidate" == /* && "$candidate" != *$'\t'* &&
    "$candidate" != *$'\n'* && -x "$candidate" && -f "$candidate" ]] ||
    die "$label must be an absolute executable regular file: $candidate"
  resolved="$("$PYTHON_BIN" -I -c \
    'import os, sys; print(os.path.realpath(sys.argv[1]))' "$candidate")" ||
    die "cannot resolve $label: $candidate"
  [[ "$resolved" == /* && "$resolved" != *$'\t'* &&
    "$resolved" != *$'\n'* && -x "$resolved" && -f "$resolved" &&
    ! -L "$resolved" ]] || die "$label resolved to an unsafe executable: $resolved"
  printf '%s\n' "$resolved"
}

resolve_media_tool() {
  local name="$1"
  local override="$2"
  local candidate=""
  if [[ -n "$override" ]]; then
    [[ "$ALLOW_TEST_EVIDENCE" == 1 ]] ||
      die "$name override requires PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1"
    candidate="$override"
  else
    for candidate in "/opt/homebrew/bin/$name" "/usr/local/bin/$name" \
      "/usr/bin/$name" "/bin/$name"; do
      [[ -x "$candidate" && -f "$candidate" ]] && break
      candidate=""
    done
    [[ -n "$candidate" ]] || die "$name is unavailable at a supported absolute path"
  fi
  canonical_executable "$candidate" "$name"
}

FFMPEG_BIN="$(resolve_media_tool ffmpeg "$FFMPEG_OVERRIDE")"
FFPROBE_BIN="$(resolve_media_tool ffprobe "$FFPROBE_OVERRIDE")"
FFMPEG_SHA256="$(sha256_file "$FFMPEG_BIN")"
FFPROBE_SHA256="$(sha256_file "$FFPROBE_BIN")"
PIXEL_VERIFIER_SHA256="$(sha256_file "$PIXEL_VERIFIER")"

one_summary_value() {
  local key="$1"
  local file="$2"
  /usr/bin/awk -v key="$key" '
    BEGIN { prefix = key "="; count = 0; value = "" }
    index($0, prefix) == 1 {
      count += 1
      value = substr($0, length(prefix) + 1)
    }
    END {
      if (count != 1 || value == "") exit 1
      print value
    }
  ' "$file"
}

decode_image() {
  local image="$1"
  "$FFMPEG_BIN" -v error -nostdin -i "$image" -map 0:v:0 -f null - \
    </dev/null >/dev/null 2>&1 || die "image is not fully decodable: ${image##*/}"
}

image_dimensions() {
  local image="$1"
  "$FFPROBE_BIN" -v error -select_streams v:0 -show_entries stream=width,height \
    -of csv=s=x:p=0 "$image" 2>/dev/null
}

pixel_difference() {
  local before="$1"
  local after="$2"
  local crop="$3"
  local threshold="$4"
  local value
  value="$("$FFMPEG_BIN" -v error -nostdin -i "$before" -i "$after" \
    -filter_complex \
    "[0:v]${crop}[a];[1:v]${crop}[b];[a][b]blend=all_mode=difference,format=gray,signalstats,metadata=print:file=-" \
    -frames:v 1 -f null - 2>/dev/null |
    /usr/bin/sed -n 's/^lavfi\.signalstats\.YAVG=//p')" || return 1
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  /usr/bin/awk -v value="$value" -v threshold="$threshold" \
    'BEGIN { exit !(value >= threshold) }' || return 1
  printf '%s\n' "$value"
}

[[ -d "$CAMERA_DIR" && ! -L "$CAMERA_DIR" ]] ||
  die "camera directory is missing or is a symlink: $CAMERA_DIR"
[[ -d "$SCREENSHOT_DIR" && ! -L "$SCREENSHOT_DIR" ]] ||
  die "screenshot directory is missing or is a symlink: $SCREENSHOT_DIR"
for acceptance_tool in "$ACCEPTANCE_IDENTITY" "$REMOTE_METRICS_COLLECTOR" \
  "$MANIFEST_VERIFIER"; do
  [[ -f "$acceptance_tool" && ! -L "$acceptance_tool" ]] ||
    die "acceptance tool is missing or is a symlink: ${acceptance_tool##*/}"
done
identity_helper_sha256="$(sha256_file "$ACCEPTANCE_IDENTITY")"
remote_collector_sha256="$(sha256_file "$REMOTE_METRICS_COLLECTOR")"
manifest_verifier_sha256="$(sha256_file "$MANIFEST_VERIFIER")"
python_sha256="$(sha256_file "$PYTHON_BIN")"

camera_manifest="$CAMERA_DIR/stages.tsv"
screenshot_manifest="$SCREENSHOT_DIR/stages.tsv"
metadata_manifest="$CAMERA_DIR/metadata.tsv"
review_manifest="$CAMERA_DIR/review.tsv"
release_manifest="$CAMERA_DIR/release-manifest.json"
camera_provenance="$CAMERA_DIR/camera-provenance.tsv"
metrics_dir="$CAMERA_DIR/metrics"
for artifact in "$camera_manifest" "$screenshot_manifest" \
  "$metadata_manifest" "$review_manifest" "$release_manifest" \
  "$camera_provenance"; do
  [[ -f "$artifact" && ! -L "$artifact" ]] ||
    die "required manifest is missing or is a symlink: ${artifact##*/}"
done
[[ -d "$metrics_dir" && ! -L "$metrics_dir" ]] ||
  die "exact installed-byte metrics bundle is missing or is a symlink"

expected_labels=(
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
)
expected_metadata_keys=(
  release_revision
  profile_id
  release_manifest_sha256
  release_target
  device_endpoint
  camera_rig
  camera_stage_hook_sha256
  camera_capture_sha256
  metrics_collector_sha256
  test_seam
)

metadata_index=0
metadata_values=()
while IFS=$'\t' read -r key value extra; do
  ((metadata_index += 1))
  [[ "$metadata_index" -le 10 ]] || die "metadata contains extra rows"
  expected_key=${expected_metadata_keys[$((metadata_index - 1))]}
  [[ -z "${extra:-}" && "$key" == "$expected_key" && -n "$value" ]] ||
    die "invalid metadata row $metadata_index"
  case "$key" in
    release_revision) [[ "$value" =~ ^[0-9a-f]{40}$ ]] || die "invalid release revision" ;;
    profile_id) [[ "$value" =~ ^(rm1|rm2|move)$ ]] || die "invalid profile id" ;;
    release_manifest_sha256) [[ "$value" =~ ^[0-9a-f]{64}$ ]] || die "invalid release manifest digest" ;;
    release_target) [[ "$value" =~ ^(linux-arm|linux-arm64)$ ]] || die "invalid release target" ;;
    device_endpoint)
      "$PYTHON_BIN" -I "$ACCEPTANCE_IDENTITY" validate-endpoint --endpoint "$value" \
        >/dev/null || die "invalid canonical device endpoint"
      ;;
    camera_rig) [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "invalid camera rig" ;;
    camera_stage_hook_sha256 | camera_capture_sha256 | metrics_collector_sha256)
      [[ "$value" =~ ^[0-9a-f]{64}$ ]] || die "invalid $key" ;;
    test_seam) [[ "$value" == 0 || "$value" == 1 ]] || die "invalid test seam marker" ;;
  esac
  metadata_values+=("$value")
done < "$metadata_manifest"
[[ "$metadata_index" == 10 ]] || die "metadata must contain exactly 10 rows"
case "${metadata_values[1]}:${metadata_values[3]}" in
  rm1:linux-arm | rm2:linux-arm | move:linux-arm64) ;;
  *) die "profile and release target disagree" ;;
esac
[[ "${metadata_values[9]}" == "$ALLOW_TEST_EVIDENCE" ]] ||
  die "verifier hook/evidence test seam mismatch"
if [[ "${metadata_values[9]}" == 0 ]]; then
  [[ -z "$FFMPEG_OVERRIDE" && -z "$FFPROBE_OVERRIDE" ]] ||
    die "media-tool overrides require test-seam visual evidence"
  [[ -z "$SDK_OVERRIDE" ]] ||
    die "PLUTO_SDK override requires test-seam visual evidence"
  ((${#METRICS_OVERRIDE_NAMES[@]} == 0)) ||
    die "PLUTO_METRICS_* overrides require test-seam visual evidence"
fi
if [[ "${metadata_values[9]}" == 0 ]]; then
  [[ -f "$OFFICIAL_STAGE_HOOK" && ! -L "$OFFICIAL_STAGE_HOOK" &&
    "$(sha256_file "$OFFICIAL_STAGE_HOOK")" == "${metadata_values[6]}" ]] ||
    die "camera stage hook provenance does not match this release checkout"
  [[ -f "$OFFICIAL_CAMERA_CAPTURE" && ! -L "$OFFICIAL_CAMERA_CAPTURE" &&
    "$(sha256_file "$OFFICIAL_CAMERA_CAPTURE")" == "${metadata_values[7]}" ]] ||
    die "camera capture provenance does not match this release checkout"
  [[ -f "$OFFICIAL_METRICS_COLLECTOR" && ! -L "$OFFICIAL_METRICS_COLLECTOR" &&
    "$(sha256_file "$OFFICIAL_METRICS_COLLECTOR")" == "${metadata_values[8]}" ]] ||
    die "metrics collector provenance does not match this release checkout"
fi
[[ "$(sha256_file "$release_manifest")" == "${metadata_values[2]}" ]] ||
  die "frozen release manifest digest does not match metadata"
/usr/bin/grep -Eq "\"gitRevision\"[[:space:]]*:[[:space:]]*\"${metadata_values[0]}\"" \
  "$release_manifest" || die "frozen release manifest revision does not match metadata"
/usr/bin/grep -Eq "\"${metadata_values[3]}\"[[:space:]]*:" "$release_manifest" ||
  die "frozen release manifest target does not match metadata"
metadata_digest="$(sha256_file "$metadata_manifest")"

expected_camera_provenance_keys=(
  test_seam
  capture_mode
  capture_override_requested
  camera_config_override_requested
  camera_rig
  camera_profile_id
  camera_stage_hook_path
  camera_stage_hook_sha256
  camera_capture_path
  camera_capture_sha256
  camera_driver_path
  camera_driver_sha256
  camera_python_binary
  camera_python_sha256
  camera_ffmpeg_binary
  camera_ffmpeg_sha256
  camera_ffprobe_binary
  camera_ffprobe_sha256
  camera_config_path
  camera_config_sha256
  camera_config_snapshot
  camera_config_snapshot_sha256
)
camera_provenance_values=()
camera_provenance_index=0
while IFS=$'\t' read -r key value extra; do
  ((camera_provenance_index += 1))
  [[ "$camera_provenance_index" -le 22 ]] ||
    die "camera provenance contains extra rows"
  expected_key=${expected_camera_provenance_keys[$((camera_provenance_index - 1))]}
  [[ -z "${extra:-}" && "$key" == "$expected_key" && -n "$value" ]] ||
    die "invalid camera provenance row $camera_provenance_index"
  camera_provenance_values+=("$value")
done < "$camera_provenance"
[[ "$camera_provenance_index" == 22 ]] ||
  die "camera provenance must contain exactly 22 ordered rows"
[[ "${camera_provenance_values[0]}" == "${metadata_values[9]}" ]] ||
  die "camera provenance test seam disagrees with metadata"
[[ "${camera_provenance_values[2]}" == 0 ||
  "${camera_provenance_values[2]}" == 1 ]] ||
  die "invalid camera capture override marker"
[[ "${camera_provenance_values[3]}" == 0 ||
  "${camera_provenance_values[3]}" == 1 ]] ||
  die "invalid camera config override marker"
[[ "${camera_provenance_values[4]}" == "${metadata_values[5]}" ]] ||
  die "camera provenance rig disagrees with metadata"
[[ "${camera_provenance_values[7]}" == "${metadata_values[6]}" &&
  "${camera_provenance_values[9]}" == "${metadata_values[7]}" ]] ||
  die "camera provenance tool hashes disagree with metadata"
if [[ "${metadata_values[9]}" == 0 ]]; then
  [[ "${camera_provenance_values[5]}" == "${metadata_values[1]}" ]] ||
    die "camera provenance profile disagrees with metadata"
  [[ "${camera_provenance_values[1]}" == repository ]] ||
    die "production camera evidence did not use repository capture mode"
  [[ "${camera_provenance_values[0]}" == 0 ]] ||
    die "production camera evidence records a test seam"
  [[ -f "${camera_provenance_values[6]}" &&
    ! -L "${camera_provenance_values[6]}" &&
    "${camera_provenance_values[6]}" -ef "$OFFICIAL_STAGE_HOOK" ]] ||
    die "camera provenance stage hook is not the repository hook"
  [[ -f "${camera_provenance_values[8]}" &&
    ! -L "${camera_provenance_values[8]}" &&
    "${camera_provenance_values[8]}" -ef "$OFFICIAL_CAMERA_CAPTURE" ]] ||
    die "camera provenance capture wrapper is not the repository wrapper"
  [[ -f "${camera_provenance_values[10]}" &&
    ! -L "${camera_provenance_values[10]}" &&
    "${camera_provenance_values[10]}" -ef "$OFFICIAL_CAMERA_DRIVER" &&
    "${camera_provenance_values[11]}" == "$(sha256_file "$OFFICIAL_CAMERA_DRIVER")" ]] ||
    die "camera provenance driver is not the repository camera driver"
  [[ "${camera_provenance_values[12]}" == "$PYTHON_BIN" &&
    -f "${camera_provenance_values[12]}" &&
    ! -L "${camera_provenance_values[12]}" &&
    -x "${camera_provenance_values[12]}" &&
    "${camera_provenance_values[13]}" == "$python_sha256" ]] ||
    die "camera provenance Python runtime is not the pinned interpreter"
  [[ "${camera_provenance_values[14]}" == "$FFMPEG_BIN" &&
    -f "${camera_provenance_values[14]}" &&
    ! -L "${camera_provenance_values[14]}" &&
    -x "${camera_provenance_values[14]}" &&
    "${camera_provenance_values[15]}" == "$FFMPEG_SHA256" ]] ||
    die "camera provenance FFmpeg runtime differs from the verifier runtime"
  [[ "${camera_provenance_values[16]}" == "$FFPROBE_BIN" &&
    -f "${camera_provenance_values[16]}" &&
    ! -L "${camera_provenance_values[16]}" &&
    -x "${camera_provenance_values[16]}" &&
    "${camera_provenance_values[17]}" == "$FFPROBE_SHA256" ]] ||
    die "camera provenance FFprobe runtime differs from the verifier runtime"
  [[ -f "${camera_provenance_values[18]}" &&
    ! -L "${camera_provenance_values[18]}" &&
    "${camera_provenance_values[19]}" =~ ^[0-9a-f]{64}$ &&
    "$(sha256_file "${camera_provenance_values[18]}")" == "${camera_provenance_values[19]}" ]] ||
    die "camera provenance config path or digest is stale"
  [[ "${camera_provenance_values[20]}" == camera-config.json &&
    "${camera_provenance_values[21]}" == "${camera_provenance_values[19]}" ]] ||
    die "camera provenance config snapshot contract is invalid"
  config_snapshot="$CAMERA_DIR/${camera_provenance_values[20]}"
  [[ -f "$config_snapshot" && ! -L "$config_snapshot" &&
    "$(sha256_file "$config_snapshot")" == "${camera_provenance_values[21]}" ]] ||
    die "frozen camera config snapshot is missing or stale"
  "$PYTHON_BIN" -I "$ACCEPTANCE_IDENTITY" camera-profile --config "$config_snapshot" \
    --device "${metadata_values[5]}" --expected-profile "${metadata_values[1]}" \
    >/dev/null || die "frozen camera rig/profile binding is invalid"
else
  [[ "${camera_provenance_values[1]}" == test-override &&
    "${camera_provenance_values[2]}" == 1 &&
    "${camera_provenance_values[5]}" == not-applicable &&
    "${camera_provenance_values[10]}" == not-applicable &&
    "${camera_provenance_values[11]}" == not-applicable &&
    "${camera_provenance_values[12]}" == not-applicable &&
    "${camera_provenance_values[13]}" == not-applicable &&
    "${camera_provenance_values[14]}" == not-applicable &&
    "${camera_provenance_values[15]}" == not-applicable &&
    "${camera_provenance_values[16]}" == not-applicable &&
    "${camera_provenance_values[17]}" == not-applicable &&
    "${camera_provenance_values[18]}" == not-applicable &&
    "${camera_provenance_values[19]}" == not-applicable &&
    "${camera_provenance_values[20]}" == not-applicable &&
    "${camera_provenance_values[21]}" == not-applicable ]] ||
    die "test camera provenance does not expose its override seam"
fi
camera_provenance_digest="$(sha256_file "$camera_provenance")"

metrics_files=(commands.log device-evidence.txt summary.txt manifest-proof.json)
metrics_sums="$metrics_dir/SHA256SUMS"
[[ -f "$metrics_sums" && ! -L "$metrics_sums" ]] ||
  die "metrics digest manifest is missing or is a symlink"
metrics_index=0
while read -r digest filename extra; do
  ((metrics_index += 1))
  [[ "$metrics_index" -le 4 ]] || die "metrics digest manifest contains extra rows"
  expected_filename=${metrics_files[$((metrics_index - 1))]}
  [[ -z "${extra:-}" && "$digest" =~ ^[0-9a-f]{64}$ &&
    "$filename" == "$expected_filename" ]] ||
    die "invalid metrics digest row $metrics_index"
  metric="$metrics_dir/$filename"
  [[ -f "$metric" && ! -L "$metric" && "$(sha256_file "$metric")" == "$digest" ]] ||
    die "metrics member is missing, linked, or stale: $filename"
done < "$metrics_sums"
[[ "$metrics_index" == 4 ]] || die "metrics digest manifest must contain exactly 4 rows"
metrics_digest="$(sha256_file "$metrics_sums")"
proof="$metrics_dir/manifest-proof.json"
/usr/bin/grep -Fq '"format": "pluto-acceptance-manifest-proof"' "$proof" ||
  die "installed-byte manifest proof format is invalid"
/usr/bin/grep -Eq "\"gitRevision\"[[:space:]]*:[[:space:]]*\"${metadata_values[0]}\"" \
  "$proof" || die "installed-byte proof revision does not match metadata"
/usr/bin/grep -Eq "\"manifestSha256\"[[:space:]]*:[[:space:]]*\"${metadata_values[2]}\"" \
  "$proof" || die "installed-byte proof manifest digest does not match metadata"
/usr/bin/grep -Eq "\"target\"[[:space:]]*:[[:space:]]*\"${metadata_values[3]}\"" \
  "$proof" || die "installed-byte proof target does not match metadata"
installed_file_count="$(/usr/bin/sed -n 's/^[[:space:]]*"installedFileCount"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\),\{0,1\}[[:space:]]*$/\1/p' "$proof")"
[[ "$installed_file_count" =~ ^[0-9]+$ ]] && ((installed_file_count >= 30)) ||
  die "installed-byte proof has an implausible file count"
/usr/bin/grep -Fq '"status": "PASS"' "$proof" || die "installed-byte proof did not pass"
summary="$metrics_dir/summary.txt"
summary_format="$(one_summary_value format "$summary")" ||
  die "metrics summary format is missing or duplicated"
metrics_device="$(one_summary_value device "$summary")" ||
  die "metrics summary device is missing or duplicated"
metrics_port="$(one_summary_value port "$summary")" ||
  die "metrics summary port is missing or duplicated"
metrics_transport="$(one_summary_value transport "$summary")" ||
  die "metrics summary transport is missing or duplicated"
metrics_ssh_binary="$(one_summary_value ssh_binary "$summary")" ||
  die "metrics summary SSH binary is missing or duplicated"
metrics_test_seam="$(one_summary_value test_seam "$summary")" ||
  die "metrics summary test seam is missing or duplicated"
metrics_identity_helper_sha256="$(one_summary_value identity_helper_sha256 "$summary")" ||
  die "metrics summary identity-helper provenance is missing or duplicated"
metrics_remote_collector_sha256="$(one_summary_value remote_collector_sha256 "$summary")" ||
  die "metrics summary remote-collector provenance is missing or duplicated"
metrics_manifest_verifier_sha256="$(one_summary_value manifest_verifier_sha256 "$summary")" ||
  die "metrics summary manifest-verifier provenance is missing or duplicated"
metrics_python_binary="$(one_summary_value python_binary "$summary")" ||
  die "metrics summary Python runtime is missing or duplicated"
metrics_python_sha256="$(one_summary_value python_sha256 "$summary")" ||
  die "metrics summary Python provenance is missing or duplicated"
metrics_dart_binary="$(one_summary_value dart_binary "$summary")" ||
  die "metrics summary Dart runtime is missing or duplicated"
metrics_dart_sha256="$(one_summary_value dart_sha256 "$summary")" ||
  die "metrics summary Dart provenance is missing or duplicated"
metrics_remote_shell="$(one_summary_value remote_shell "$summary")" ||
  die "metrics summary remote shell is missing or duplicated"
[[ "$summary_format" == pluto-acceptance-bundle &&
  "$(one_summary_value git_revision "$summary")" == "${metadata_values[0]}" &&
  "$(one_summary_value profile "$summary")" == "${metadata_values[1]}" &&
  "$(one_summary_value target "$summary")" == "${metadata_values[3]}" &&
  "$(one_summary_value local_manifest "$summary")" == "${metadata_values[2]}" &&
  "$(one_summary_value status "$summary")" == PASS ]] ||
  die "metrics summary does not match the accepted release"
[[ "$metrics_identity_helper_sha256" == "$identity_helper_sha256" &&
  "$metrics_remote_collector_sha256" == "$remote_collector_sha256" &&
  "$metrics_manifest_verifier_sha256" == "$manifest_verifier_sha256" &&
  "$metrics_python_binary" == "$PYTHON_BIN" &&
  "$metrics_python_sha256" == "$python_sha256" &&
  "$metrics_remote_shell" == /bin/sh ]] ||
  die "metrics collection tooling does not match this exact release checkout"
[[ "$metrics_dart_binary" == /* &&
  "$metrics_dart_binary" != *$'\n'* &&
  "$metrics_dart_binary" != *$'\t'* &&
  "$metrics_dart_sha256" =~ ^[0-9a-f]{64}$ ]] ||
  die "metrics summary has invalid Dart provenance"
case "$metrics_transport:$metrics_test_seam:${metadata_values[9]}" in
  ssh:0:0 | ssh:1:1)
    [[ "$metrics_ssh_binary" == /usr/bin/ssh ]] ||
      die "production SSH metrics did not use the pinned /usr/bin/ssh binary"
    ;;
  test-hook:1:1)
    [[ "$metrics_ssh_binary" == not-used || "$metrics_ssh_binary" == /* ]] ||
      die "test-hook metrics do not identify their SSH binary seam"
    ;;
  *) die "metrics transport/test-seam provenance disagrees with visual metadata" ;;
esac
[[ "$metrics_port" =~ ^[1-9][0-9]{0,4}$ ]] ||
  die "metrics summary has an invalid SSH port"
metrics_identity_rows="$("$PYTHON_BIN" -I "$ACCEPTANCE_IDENTITY" endpoint \
  --device "${metadata_values[4]}" --ssh-target "$metrics_device" \
  --ssh-port "$metrics_port")" ||
  die "metrics SSH identity does not match the visual device endpoint"
[[ "$(printf '%s\n' "$metrics_identity_rows" | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == 4 &&
  "$(printf '%s\n' "$metrics_identity_rows" | /usr/bin/awk -F '\t' \
    '$1 == "canonical_endpoint" {print $2}')" == "${metadata_values[4]}" &&
  "$(printf '%s\n' "$metrics_identity_rows" | /usr/bin/awk -F '\t' \
    '$1 == "ssh_invocation_target" {print $2}')" == "$metrics_device" &&
  "$(printf '%s\n' "$metrics_identity_rows" | /usr/bin/awk -F '\t' \
    '$1 == "ssh_port" {print $2}')" == "$metrics_port" &&
  "$(printf '%s\n' "$metrics_identity_rows" | /usr/bin/awk -F '\t' \
    '$1 == "divergent" {print $2}')" == 0 ]] ||
  die "metrics SSH identity is not the exact canonical visual device endpoint"
[[ "$(/usr/bin/tail -n 1 "$metrics_dir/device-evidence.txt")" == collection.status=PASS ]] ||
  die "device metrics evidence has no terminal PASS"
if [[ "${metadata_values[9]}" == 0 ]]; then
  flutter_version="$(/usr/bin/tr -d '[:space:]' < "$ROOT/tools/pluto/pins/flutter.version")"
  dart="$ACCOUNT_HOME/.pluto/sdk/$flutter_version/bin/cache/dart-sdk/bin/dart"
  packages="$ROOT/tools/pluto/.dart_tool/package_config.json"
  [[ -x "$dart" && -f "$dart" && ! -L "$dart" && -f "$packages" ]] ||
    die "pinned installed-byte proof verifier is unavailable"
  [[ "$metrics_dart_binary" == "$dart" &&
    "$metrics_dart_sha256" == "$(sha256_file "$dart")" ]] ||
    die "production metrics did not use the exact pinned Dart runtime"
  recomputed_proof_dir="$(
    /usr/bin/mktemp -d "${TMPDIR:-/tmp}/pluto-manifest-proof.XXXXXX"
  )"
  recomputed_proof="$recomputed_proof_dir/manifest-proof.json"
  trap '/bin/rm -rf "$recomputed_proof_dir"' EXIT
  "$dart" --packages="$packages" "$MANIFEST_VERIFIER" \
    --manifest "$release_manifest" \
    --pins "$ROOT/tools/pluto/pins" \
    --target "${metadata_values[3]}" \
    --expected-revision "${metadata_values[0]}" \
    --evidence "$metrics_dir/device-evidence.txt" \
    --output "$recomputed_proof" >/dev/null 2>&1 ||
    die "exact installed-byte proof could not be recomputed"
  /usr/bin/cmp -s "$recomputed_proof" "$proof" ||
    die "stored installed-byte proof differs from a fresh pinned-Dart proof"
  /bin/rm -rf "$recomputed_proof_dir"
  trap - EXIT
fi

[[ "$(wc -l < "$camera_manifest" | tr -d '[:space:]')" == 10 ]] ||
  die "camera manifest must contain exactly 10 rows"
[[ "$(wc -l < "$screenshot_manifest" | tr -d '[:space:]')" == 10 ]] ||
  die "screenshot manifest must contain exactly 10 rows"
[[ "$(wc -l < "$review_manifest" | tr -d '[:space:]')" == 10 ]] ||
  die "review manifest must contain exactly 10 rows"
[[ "$(find "$CAMERA_DIR" -maxdepth 1 -type f -name '[0-9][0-9]-*.jpg' | wc -l | tr -d '[:space:]')" == 10 ]] ||
  die "camera directory must contain exactly 10 stage JPEGs"
[[ "$(find "$SCREENSHOT_DIR" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d '[:space:]')" == 10 ]] ||
  die "screenshot directory must contain exactly 10 stage PNGs"

camera_digests=()
camera_index=0
previous_digest=""
camera_dimensions=""
while IFS=$'\t' read -r sequence label digest filename extra; do
  ((camera_index += 1))
  expected_sequence=$(printf '%02d' "$camera_index")
  expected_label=${expected_labels[$((camera_index - 1))]}
  [[ -z "${extra:-}" && "$sequence" == "$expected_sequence" &&
    "$label" == "$expected_label" && "$digest" =~ ^[0-9a-f]{64}$ &&
    "$filename" == "$expected_sequence-$expected_label.jpg" ]] ||
    die "invalid camera row $camera_index"
  image="$CAMERA_DIR/$filename"
  [[ -s "$image" && ! -L "$image" ]] || die "missing camera image: $filename"
  [[ "$(od -An -tx1 -N2 "$image" | tr -d '[:space:]')" == ffd8 ]] ||
    die "camera image lacks JPEG magic: $filename"
  [[ "$(sha256_file "$image")" == "$digest" ]] ||
    die "camera digest mismatch: $filename"
  decode_image "$image"
  dimensions="$(image_dimensions "$image")"
  [[ "$dimensions" =~ ^[0-9]+x[0-9]+$ ]] ||
    die "camera dimensions are unavailable: $filename"
  width=${dimensions%x*}
  height=${dimensions#*x}
  ((width >= 480 && height >= 480)) ||
    die "camera image is implausibly small: $filename ($dimensions)"
  if [[ -z "$camera_dimensions" ]]; then
    camera_dimensions="$dimensions"
  else
    [[ "$dimensions" == "$camera_dimensions" ]] ||
      die "camera geometry changed within one acceptance set"
  fi
  [[ -z "$previous_digest" || "$digest" != "$previous_digest" ]] ||
    die "camera returned an unchanged consecutive frame at $label"
  camera_digests+=("$digest")
  previous_digest="$digest"
done < "$camera_manifest"
[[ "$camera_index" == 10 ]] || die "camera stage count changed while verifying"

screenshot_digests=()
screenshot_index=0
previous_digest=""
expected_app_ids=(
  dev.pluto.examples.counter
  dev.pluto.examples.motion_lab
  dev.pluto.examples.ink_lab
  dev.pluto.validation_lab
  dev.pluto.ink
  dev.pluto.launcher
  dev.pluto.validation_lab
  dev.pluto.ink
  dev.pluto.ink
  dev.pluto.launcher
)
case "${metadata_values[1]}" in
  rm1 | rm2) expected_screenshot_dimensions=1404x1872 ;;
  move) expected_screenshot_dimensions=954x1696 ;;
esac
while IFS=$'\t' read -r label digest filename app_id extra; do
  ((screenshot_index += 1))
  expected_label=${expected_labels[$((screenshot_index - 1))]}
  expected_app_id=${expected_app_ids[$((screenshot_index - 1))]}
  [[ -z "${extra:-}" && "$label" == "$expected_label" &&
    "$digest" =~ ^[0-9a-f]{64}$ && "$filename" == "$expected_label.png" &&
    "$app_id" == "$expected_app_id" ]] ||
    die "invalid screenshot row $screenshot_index"
  image="$SCREENSHOT_DIR/$filename"
  [[ -s "$image" && ! -L "$image" ]] || die "missing screenshot: $filename"
  [[ "$(od -An -tx1 -N8 "$image" | tr -d '[:space:]')" == 89504e470d0a1a0a ]] ||
    die "screenshot lacks PNG magic: $filename"
  [[ "$(sha256_file "$image")" == "$digest" ]] ||
    die "screenshot digest mismatch: $filename"
  decode_image "$image"
  [[ "$(image_dimensions "$image")" == "$expected_screenshot_dimensions" ]] ||
    die "screenshot geometry does not match ${metadata_values[1]} at $label"
  [[ -z "$previous_digest" || "$digest" != "$previous_digest" ]] ||
    die "native framebuffer did not change at $label"
  screenshot_digests+=("$digest")
  previous_digest="$digest"
done < "$screenshot_manifest"
[[ "$screenshot_index" == 10 ]] ||
  die "screenshot stage count changed while verifying"

stroke_screenshot_delta="$(pixel_difference \
  "$SCREENSHOT_DIR/ink-canvas-before-stroke.png" \
  "$SCREENSHOT_DIR/ink-stroke.png" \
  'crop=iw*0.5:ih*0.3:iw*0.25:ih*0.36' 0.05)" ||
  die "Ink stroke did not materially change decoded central screenshot pixels"
stroke_camera_delta="$(pixel_difference \
  "$CAMERA_DIR/08-ink-canvas-before-stroke.jpg" \
  "$CAMERA_DIR/09-ink-stroke.jpg" \
  'crop=iw*0.5:ih*0.3:iw*0.25:ih*0.36' 0.02)" ||
  die "Ink stroke did not materially change decoded central camera pixels"

[[ -f "$PIXEL_VERIFIER" && ! -L "$PIXEL_VERIFIER" ]] ||
  die "cross-modal pixel verifier is missing or is a symlink"
"$PYTHON_BIN" -I "$PIXEL_VERIFIER" \
  --camera-dir "$CAMERA_DIR" \
  --screenshot-dir "$SCREENSHOT_DIR" \
  --profile "${metadata_values[1]}" \
  --ffmpeg "$FFMPEG_BIN" \
  --ffprobe "$FFPROBE_BIN" ||
  die "camera/native stage correspondence or Ink stroke proof failed"

review_index=0
reviewer=""
while IFS=$'\t' read -r label camera_digest screenshot_digest verdict \
  row_reviewer row_metadata_digest row_metrics_digest \
  row_camera_provenance_digest extra; do
  ((review_index += 1))
  expected_label=${expected_labels[$((review_index - 1))]}
  [[ -z "${extra:-}" && "$label" == "$expected_label" &&
    "$camera_digest" == "${camera_digests[$((review_index - 1))]}" &&
    "$screenshot_digest" == "${screenshot_digests[$((review_index - 1))]}" &&
    "$verdict" == pass && "$row_reviewer" =~ ^[A-Za-z0-9._@+-]+$ &&
    "$row_metadata_digest" == "$metadata_digest" &&
    "$row_metrics_digest" == "$metrics_digest" &&
    "$row_camera_provenance_digest" == "$camera_provenance_digest" ]] ||
    die "invalid or stale optical review row $review_index"
  if [[ -z "$reviewer" ]]; then
    reviewer="$row_reviewer"
  else
    [[ "$row_reviewer" == "$reviewer" ]] || die "reviewer changed within one acceptance set"
  fi
done < "$review_manifest"
[[ "$review_index" == 10 ]] || die "review stage count changed while verifying"

[[ "$(sha256_file "$ACCEPTANCE_IDENTITY")" == "$identity_helper_sha256" &&
  "$(sha256_file "$REMOTE_METRICS_COLLECTOR")" == "$remote_collector_sha256" &&
  "$(sha256_file "$MANIFEST_VERIFIER")" == "$manifest_verifier_sha256" &&
  "$(sha256_file "$PYTHON_BIN")" == "$python_sha256" &&
  "$(sha256_file "$FFMPEG_BIN")" == "$FFMPEG_SHA256" &&
  "$(sha256_file "$FFPROBE_BIN")" == "$FFPROBE_SHA256" &&
  "$(sha256_file "$PIXEL_VERIFIER")" == "$PIXEL_VERIFIER_SHA256" ]] ||
  die "acceptance tooling changed while visual evidence was being verified"

echo "visual acceptance verifier: PASS stages=10 reviewer=$reviewer revision=${metadata_values[0]} profile=${metadata_values[1]} test_seam=${metadata_values[9]} manifest_sha256=${metadata_values[2]} screenshot_stroke_yavg=$stroke_screenshot_delta camera_stroke_yavg=$stroke_camera_delta python_binary=$PYTHON_BIN python_sha256=$python_sha256 ffmpeg_binary=$FFMPEG_BIN ffmpeg_sha256=$FFMPEG_SHA256 ffprobe_binary=$FFPROBE_BIN ffprobe_sha256=$FFPROBE_SHA256 pixel_verifier_sha256=$PIXEL_VERIFIER_SHA256 camera=$CAMERA_DIR screenshots=$SCREENSHOT_DIR"
