#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE_SCRIPT="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
OFFICIAL_CAPTURE="$SCRIPT_DIR/capture.sh"
CAMERA_DRIVER="$SCRIPT_DIR/camera.py"
ACCEPTANCE_IDENTITY="$SCRIPT_DIR/../../device/diagnostics/acceptance_identity.py"
DEFAULT_CONFIG="$SCRIPT_DIR/../../../.pluto-devices.json"
CAPTURE_OVERRIDE="${PLUTO_CAMERA_CAPTURE:-}"
CONFIG_OVERRIDE="${PLUTO_CAMERA_CONFIG:-}"
RIG="${PLUTO_CAMERA_RIG:-}"
OUTPUT_DIR="${PLUTO_CAMERA_ACCEPTANCE_DIR:-}"
SETTLE_SECONDS="${PLUTO_CAMERA_ACCEPTANCE_SETTLE:-1}"
ALLOW_TEST_HOOKS="${PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS:-0}"
EXPECTED_PROFILE="${PLUTO_ACCEPTANCE_PROFILE_ID:-}"
LABEL="${1:-}"

die() {
  echo "camera acceptance stage: $*" >&2
  exit 2
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

canonical_regular_file() {
  local path="$1"
  local directory basename
  [[ -f "$path" && ! -L "$path" ]] ||
    die "provenance input must be a regular non-symlink file: $path"
  directory="$(cd -P "$(dirname "$path")" && pwd)"
  basename="$(basename "$path")"
  case "$directory/$basename" in
    *$'\t'* | *$'\n'*) die "provenance path contains a tab or newline" ;;
  esac
  printf '%s/%s\n' "$directory" "$basename"
}

write_current_provenance() {
  local destination="$1"
  local stage_path capture_path driver_path config_path config_snapshot
  local stage_sha capture_sha driver_sha config_sha config_snapshot_sha

  stage_path="$(canonical_regular_file "$STAGE_SCRIPT")"
  capture_path="$(canonical_regular_file "$CAPTURE")"
  stage_sha="$(sha256_file "$stage_path")"
  capture_sha="$(sha256_file "$capture_path")"

  if [[ "$CAPTURE_MODE" == repository ]]; then
    driver_path="$(canonical_regular_file "$CAMERA_DRIVER")"
    config_path="$(canonical_regular_file "$CONFIG")"
    driver_sha="$(sha256_file "$driver_path")"
    config_sha="$(sha256_file "$config_path")"
    config_snapshot=camera-config.json
    config_snapshot_sha="$config_sha"
  else
    driver_path=not-applicable
    config_path=not-applicable
    config_snapshot=not-applicable
    driver_sha=not-applicable
    config_sha=not-applicable
    config_snapshot_sha=not-applicable
  fi

  cat > "$destination" <<EOF
test_seam	$ALLOW_TEST_HOOKS
capture_mode	$CAPTURE_MODE
capture_override_requested	$CAPTURE_OVERRIDE_REQUESTED
camera_config_override_requested	$CONFIG_OVERRIDE_REQUESTED
camera_rig	$RIG
camera_profile_id	$CAMERA_PROFILE_ID
camera_stage_hook_path	$stage_path
camera_stage_hook_sha256	$stage_sha
camera_capture_path	$capture_path
camera_capture_sha256	$capture_sha
camera_driver_path	$driver_path
camera_driver_sha256	$driver_sha
camera_config_path	$config_path
camera_config_sha256	$config_sha
camera_config_snapshot	$config_snapshot
camera_config_snapshot_sha256	$config_snapshot_sha
EOF
}

[[ "$LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  die "stage label must contain only letters, numbers, dot, underscore, and dash"
[[ "$RIG" =~ ^[1-9][0-9]*$ ]] || die "PLUTO_CAMERA_RIG must be a positive integer"
[[ -n "$OUTPUT_DIR" ]] || die "PLUTO_CAMERA_ACCEPTANCE_DIR is required"
[[ "$ALLOW_TEST_HOOKS" == 0 || "$ALLOW_TEST_HOOKS" == 1 ]] ||
  die "PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS must be 0 or 1"
[[ "$SETTLE_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
  die "PLUTO_CAMERA_ACCEPTANCE_SETTLE must be a non-negative number"

CAPTURE_OVERRIDE_REQUESTED=0
CONFIG_OVERRIDE_REQUESTED=0
CAPTURE="$OFFICIAL_CAPTURE"
CAPTURE_MODE=repository
CONFIG="${CONFIG_OVERRIDE:-$DEFAULT_CONFIG}"
[[ -z "$CONFIG_OVERRIDE" ]] || CONFIG_OVERRIDE_REQUESTED=1
if [[ -n "$CAPTURE_OVERRIDE" ]]; then
  CAPTURE_OVERRIDE_REQUESTED=1
  if [[ -e "$CAPTURE_OVERRIDE" && "$CAPTURE_OVERRIDE" -ef "$OFFICIAL_CAPTURE" ]]; then
    # Normalize harmless aliases of the repository wrapper so provenance cannot
    # imply that an alternate executable actually ran.
    CAPTURE="$OFFICIAL_CAPTURE"
  elif [[ "$ALLOW_TEST_HOOKS" == 1 ]]; then
    CAPTURE="$CAPTURE_OVERRIDE"
    CAPTURE_MODE=test-override
  else
    die "PLUTO_CAMERA_CAPTURE may only substitute the repository capture command with PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1"
  fi
fi
[[ -x "$CAPTURE" && -f "$CAPTURE" && ! -L "$CAPTURE" ]] ||
  die "camera capture command is not an executable regular file: $CAPTURE"
CAMERA_PROFILE_ID=not-applicable
if [[ "$CAPTURE_MODE" == repository ]]; then
  case "$EXPECTED_PROFILE" in
    rm1 | rm2 | move) ;;
    *) die "PLUTO_ACCEPTANCE_PROFILE_ID must be rm1, rm2, or move" ;;
  esac
  CAMERA_PROFILE_ID="$(python3 "$ACCEPTANCE_IDENTITY" camera-profile \
    --config "$CONFIG" --device "$RIG" --expected-profile "$EXPECTED_PROFILE")" ||
    die "camera rig $RIG is not bound to expected profile $EXPECTED_PROFILE"
fi

case "$OUTPUT_DIR" in
  *$'\t'* | *$'\n'*) die "acceptance output path contains a tab or newline" ;;
esac
[[ ! -L "$OUTPUT_DIR" ]] || die "acceptance output directory must not be a symlink"

mkdir -p "$OUTPUT_DIR"
LOCK_DIR="$OUTPUT_DIR/.capture-acceptance-stage.lock"
mkdir "$LOCK_DIR" 2>/dev/null || die "another capture stage is active or left a stale lock: $LOCK_DIR"
cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
  [[ -z "${PROVENANCE_TMP:-}" ]] || rm -f "$PROVENANCE_TMP"
  [[ -z "${PROVENANCE_AFTER_TMP:-}" ]] || rm -f "$PROVENANCE_AFTER_TMP"
  [[ -z "${CONFIG_SNAPSHOT_TMP:-}" ]] || rm -f "$CONFIG_SNAPSHOT_TMP"
}
trap cleanup EXIT

PROVENANCE="$OUTPUT_DIR/camera-provenance.tsv"
[[ ! -L "$PROVENANCE" ]] || die "camera provenance must not be a symlink"
PROVENANCE_TMP="$(mktemp "$OUTPUT_DIR/.camera-provenance.XXXXXX")"
write_current_provenance "$PROVENANCE_TMP"
CONFIG_SNAPSHOT="$OUTPUT_DIR/camera-config.json"
CONFIG_SNAPSHOT_TMP=""
if [[ "$CAPTURE_MODE" == repository ]]; then
  expected_config_sha="$(awk -F '\t' '$1 == "camera_config_sha256" {print $2}' "$PROVENANCE_TMP")"
  [[ "$expected_config_sha" =~ ^[0-9a-f]{64}$ ]] ||
    die "repository camera provenance lacks a config digest"
  [[ ! -L "$CONFIG_SNAPSHOT" ]] || die "camera config snapshot must not be a symlink"
  if [[ -e "$PROVENANCE" ]]; then
    [[ -f "$CONFIG_SNAPSHOT" ]] ||
      die "existing camera provenance lacks its config snapshot"
    [[ "$(sha256_file "$CONFIG_SNAPSHOT")" == "$expected_config_sha" ]] ||
      die "camera config snapshot does not match the recorded config"
  else
    [[ ! -e "$CONFIG_SNAPSHOT" ]] ||
      die "camera config snapshot exists without camera provenance"
    CONFIG_SNAPSHOT_TMP="$(mktemp "$OUTPUT_DIR/.camera-config.XXXXXX")"
    cp "$CONFIG" "$CONFIG_SNAPSHOT_TMP"
    [[ "$(sha256_file "$CONFIG_SNAPSHOT_TMP")" == "$expected_config_sha" ]] ||
      die "camera config changed while its evidence snapshot was created"
    mv "$CONFIG_SNAPSHOT_TMP" "$CONFIG_SNAPSHOT"
    CONFIG_SNAPSHOT_TMP=""
  fi
fi
if [[ -e "$PROVENANCE" ]]; then
  [[ -f "$PROVENANCE" ]] || die "camera provenance is not a regular file"
  cmp -s "$PROVENANCE_TMP" "$PROVENANCE" ||
    die "camera capture provenance changed within one evidence directory"
  rm -f "$PROVENANCE_TMP"
  PROVENANCE_TMP=""
else
  mv "$PROVENANCE_TMP" "$PROVENANCE"
  PROVENANCE_TMP=""
fi

MANIFEST="$OUTPUT_DIR/stages.tsv"
[[ ! -L "$MANIFEST" ]] || die "stage manifest must not be a symlink"
if [[ -e "$MANIFEST" ]]; then
  [[ -f "$MANIFEST" ]] || die "stage manifest is not a regular file"
  count="$(wc -l < "$MANIFEST" | tr -d '[:space:]')"
else
  count=0
fi
image_count="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '[0-9][0-9]-*.jpg' |
  wc -l | tr -d '[:space:]')"
[[ "$count" == "$image_count" ]] ||
  die "stage manifest/image count mismatch ($count rows, $image_count images)"
sequence=$((count + 1))
((sequence <= 99)) || die "camera acceptance supports at most 99 stages"
printf -v basename '%02d-%s.jpg' "$sequence" "$LABEL"
output="$OUTPUT_DIR/$basename"
[[ ! -e "$output" && ! -L "$output" ]] || die "capture output already exists: $output"

sleep "$SETTLE_SECONDS"
if [[ "$CAPTURE_MODE" == repository ]]; then
  driver_sha="$(awk -F '\t' '$1 == "camera_driver_sha256" {print $2}' "$PROVENANCE")"
  config_sha="$(awk -F '\t' '$1 == "camera_config_sha256" {print $2}' "$PROVENANCE")"
  PLUTO_CAMERA_EXPECTED_DRIVER_SHA256="$driver_sha" \
    PLUTO_CAMERA_EXPECTED_CONFIG_SHA256="$config_sha" \
    "$CAPTURE" image --device "$RIG" --output "$output"
else
  "$CAPTURE" image --device "$RIG" --output "$output"
fi

[[ -f "$output" && ! -L "$output" && -s "$output" ]] ||
  die "camera capture did not produce a non-empty regular image: $output"

# Re-read every tool and config hash after capture. This closes the gap where
# evidence names one wrapper/config but mutable bytes are swapped during FFmpeg.
PROVENANCE_AFTER_TMP="$(mktemp "$OUTPUT_DIR/.camera-provenance-after.XXXXXX")"
write_current_provenance "$PROVENANCE_AFTER_TMP"
cmp -s "$PROVENANCE_AFTER_TMP" "$PROVENANCE" ||
  die "camera capture provenance changed while the image was captured"
if [[ "$CAPTURE_MODE" == repository ]]; then
  [[ -f "$CONFIG_SNAPSHOT" && ! -L "$CONFIG_SNAPSHOT" ]] ||
    die "camera config snapshot changed type while the image was captured"
  [[ "$(sha256_file "$CONFIG_SNAPSHOT")" == "$config_sha" ]] ||
    die "camera config snapshot changed while the image was captured"
fi
rm -f "$PROVENANCE_AFTER_TMP"
PROVENANCE_AFTER_TMP=""

digest="$(sha256_file "$output")"
printf '%02d\t%s\t%s\t%s\n' "$sequence" "$LABEL" "$digest" "$basename" >> \
  "$MANIFEST"
printf 'camera acceptance stage: PASS sequence=%02d label=%s sha256=%s output=%s\n' \
  "$sequence" "$LABEL" "$digest" "$output"
