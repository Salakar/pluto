#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
STAGE="$ROOT/tools/setup/camera/capture-acceptance-stage.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pluto-camera-stage-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "camera acceptance stage test: $*" >&2
  exit 1
}

cat > "$TMP/fake-capture" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" = image && "$2" = --device && "$3" = 2 && "$4" = --output ]]
printf 'fixture image for %s\n' "$5" > "$5"
printf '%s\n' "$5"
FAKE
chmod 0755 "$TMP/fake-capture"

run_stage() {
  PLUTO_CAMERA_CAPTURE="$TMP/fake-capture" \
  PLUTO_CAMERA_RIG=2 \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/evidence" \
  PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
    "$STAGE" "$1" >/dev/null
}

run_stage app-dev.pluto.launcher
run_stage ink-stroke
[[ -s "$TMP/evidence/01-app-dev.pluto.launcher.jpg" ]] ||
  fail "first labeled image was not captured"
[[ -s "$TMP/evidence/02-ink-stroke.jpg" ]] ||
  fail "second labeled image was not captured"
[[ "$(wc -l < "$TMP/evidence/stages.tsv" | tr -d '[:space:]')" = 2 ]] ||
  fail "stage manifest does not contain exactly two rows"
grep -Eq '^01[[:space:]]+app-dev\.pluto\.launcher[[:space:]]+[0-9a-f]{64}[[:space:]]+01-app-dev\.pluto\.launcher\.jpg$' \
  "$TMP/evidence/stages.tsv" || fail "first manifest row is invalid"

if PLUTO_CAMERA_CAPTURE="$TMP/fake-capture" \
  PLUTO_CAMERA_RIG=2 \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/evidence" \
  PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
  "$STAGE" '../unsafe' >/dev/null 2>&1; then
  fail "unsafe stage label was accepted"
fi

echo "camera acceptance stage test: PASS"
