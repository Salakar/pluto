#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTURE="${PLUTO_CAMERA_CAPTURE:-$SCRIPT_DIR/capture.sh}"
RIG="${PLUTO_CAMERA_RIG:-}"
OUTPUT_DIR="${PLUTO_CAMERA_ACCEPTANCE_DIR:-}"
SETTLE_SECONDS="${PLUTO_CAMERA_ACCEPTANCE_SETTLE:-1}"
LABEL="${1:-}"

die() {
  echo "camera acceptance stage: $*" >&2
  exit 2
}

[[ "$LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  die "stage label must contain only letters, numbers, dot, underscore, and dash"
[[ "$RIG" =~ ^[1-9][0-9]*$ ]] || die "PLUTO_CAMERA_RIG must be a positive integer"
[[ -n "$OUTPUT_DIR" ]] || die "PLUTO_CAMERA_ACCEPTANCE_DIR is required"
[[ "$SETTLE_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
  die "PLUTO_CAMERA_ACCEPTANCE_SETTLE must be a non-negative number"
[[ -x "$CAPTURE" ]] || die "camera capture command is not executable: $CAPTURE"

mkdir -p "$OUTPUT_DIR"
count="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '[0-9][0-9]-*.jpg' |
  wc -l | tr -d '[:space:]')"
sequence=$((count + 1))
printf -v basename '%02d-%s.jpg' "$sequence" "$LABEL"
output="$OUTPUT_DIR/$basename"
[[ ! -e "$output" ]] || die "capture output already exists: $output"

sleep "$SETTLE_SECONDS"
"$CAPTURE" image --device "$RIG" --output "$output"

if command -v sha256sum >/dev/null 2>&1; then
  digest="$(sha256sum "$output" | awk '{print $1}')"
else
  digest="$(shasum -a 256 "$output" | awk '{print $1}')"
fi
printf '%02d\t%s\t%s\t%s\n' "$sequence" "$LABEL" "$digest" "$basename" >> \
  "$OUTPUT_DIR/stages.tsv"
printf 'camera acceptance stage: PASS sequence=%02d label=%s sha256=%s output=%s\n' \
  "$sequence" "$LABEL" "$digest" "$output"
