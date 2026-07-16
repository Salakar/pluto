#!/usr/bin/env bash
set -euo pipefail

CAMERA_DIR=""
SCREENSHOT_DIR=""
REVIEWER=""
CONFIRMED=0

usage() {
  cat >&2 <<EOF
usage: $0 --camera-dir DIR --screenshot-dir DIR --reviewer NAME --confirm-all-visible

Run this only after viewing every paired camera JPEG and native PNG and
confirming that each labelled state is visible on the named physical device.
EOF
  exit 64
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --camera-dir) [[ "$#" -ge 2 ]] || usage; CAMERA_DIR="$2"; shift 2 ;;
    --screenshot-dir) [[ "$#" -ge 2 ]] || usage; SCREENSHOT_DIR="$2"; shift 2 ;;
    --reviewer) [[ "$#" -ge 2 ]] || usage; REVIEWER="$2"; shift 2 ;;
    --confirm-all-visible) CONFIRMED=1; shift ;;
    *) usage ;;
  esac
done

die() {
  echo "visual review recorder: $*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

[[ "$CONFIRMED" == 1 ]] || die "explicit --confirm-all-visible is required"
[[ "$REVIEWER" =~ ^[A-Za-z0-9._@+-]+$ ]] || die "invalid reviewer identity"
[[ -d "$CAMERA_DIR" && ! -L "$CAMERA_DIR" ]] || die "invalid camera directory"
[[ -d "$SCREENSHOT_DIR" && ! -L "$SCREENSHOT_DIR" ]] || die "invalid screenshot directory"

camera_manifest="$CAMERA_DIR/stages.tsv"
screenshot_manifest="$SCREENSHOT_DIR/stages.tsv"
metadata_manifest="$CAMERA_DIR/metadata.tsv"
review_manifest="$CAMERA_DIR/review.tsv"
metrics_sums="$CAMERA_DIR/metrics/SHA256SUMS"
camera_provenance="$CAMERA_DIR/camera-provenance.tsv"
for artifact in "$camera_manifest" "$screenshot_manifest" "$metadata_manifest"; do
  [[ -f "$artifact" && ! -L "$artifact" ]] ||
    die "required manifest is missing or is a symlink: ${artifact##*/}"
done
[[ -f "$metrics_sums" && ! -L "$metrics_sums" ]] ||
  die "exact installed-byte metrics bundle must pass before visual review"
[[ -f "$camera_provenance" && ! -L "$camera_provenance" ]] ||
  die "camera capture provenance must exist before visual review"
[[ ! -e "$review_manifest" && ! -L "$review_manifest" ]] ||
  die "review receipt already exists: $review_manifest"

expected_labels=(
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
)

camera_digests=()
camera_index=0
while IFS=$'\t' read -r sequence label digest filename extra; do
  ((camera_index += 1))
  expected_sequence=$(printf '%02d' "$camera_index")
  expected_label=${expected_labels[$((camera_index - 1))]}
  [[ -z "${extra:-}" && "$sequence" == "$expected_sequence" &&
    "$label" == "$expected_label" && "$digest" =~ ^[0-9a-f]{64}$ &&
    "$filename" == "$expected_sequence-$expected_label.jpg" ]] ||
    die "invalid camera row $camera_index"
  image="$CAMERA_DIR/$filename"
  [[ -s "$image" && ! -L "$image" && "$(sha256_file "$image")" == "$digest" ]] ||
    die "camera image or digest is invalid: $filename"
  camera_digests+=("$digest")
done < "$camera_manifest"
[[ "$camera_index" == 11 ]] || die "camera manifest must contain exactly 11 rows"

screenshot_digests=()
screenshot_index=0
while IFS=$'\t' read -r label digest filename app_id extra; do
  ((screenshot_index += 1))
  expected_label=${expected_labels[$((screenshot_index - 1))]}
  [[ -z "${extra:-}" && "$label" == "$expected_label" &&
    "$digest" =~ ^[0-9a-f]{64}$ && "$filename" == "$expected_label.png" &&
    "$app_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] ||
    die "invalid screenshot row $screenshot_index"
  image="$SCREENSHOT_DIR/$filename"
  [[ -s "$image" && ! -L "$image" && "$(sha256_file "$image")" == "$digest" ]] ||
    die "native screenshot or digest is invalid: $filename"
  screenshot_digests+=("$digest")
done < "$screenshot_manifest"
[[ "$screenshot_index" == 11 ]] || die "screenshot manifest must contain exactly 11 rows"

metadata_digest="$(sha256_file "$metadata_manifest")"
metrics_digest="$(sha256_file "$metrics_sums")"
camera_provenance_digest="$(sha256_file "$camera_provenance")"
temporary="$CAMERA_DIR/.review.tsv.$$"
trap 'rm -f "$temporary"' EXIT
: > "$temporary"
for ((index = 0; index < 11; index += 1)); do
  printf '%s\t%s\t%s\tpass\t%s\t%s\t%s\t%s\n' \
    "${expected_labels[$index]}" "${camera_digests[$index]}" \
    "${screenshot_digests[$index]}" "$REVIEWER" "$metadata_digest" \
    "$metrics_digest" "$camera_provenance_digest" >> \
    "$temporary"
done
mv "$temporary" "$review_manifest"
trap - EXIT

echo "visual review recorder: RECORDED reviewer=$REVIEWER stages=11 receipt=$review_manifest"
