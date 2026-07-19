#!/bin/bash -p
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
STAGE="$ROOT/tools/setup/camera/capture-acceptance-stage.sh"
CAPTURE="$ROOT/tools/setup/camera/capture.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pluto-camera-stage-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "camera acceptance stage test: $*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

assert_provenance_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(awk -F '\t' -v key="$key" '$1 == key {print $2}' "$file")"
  [[ "$actual" == "$expected" ]] ||
    fail "provenance $key was '$actual', expected '$expected'"
}

cat > "$TMP/fake-capture" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" = image && "$2" = --device && "$3" = 2 && "$4" = --output ]]
printf 'fixture image for %s\n' "$5" > "$5"
printf '%s\n' "$5"
FAKE
chmod 0755 "$TMP/fake-capture"

# A capture override is never a production input merely because it is
# executable. The explicit test seam is mandatory.
if PLUTO_CAMERA_CAPTURE="$TMP/fake-capture" \
  PLUTO_CAMERA_RIG=2 \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/rejected-override" \
  PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
  "$STAGE" rejected >/dev/null 2>&1; then
  fail "capture override was accepted without the explicit test seam"
fi

run_test_stage() {
  PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
    PLUTO_CAMERA_CAPTURE="$TMP/fake-capture" \
    PLUTO_CAMERA_RIG=2 \
    PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/test-evidence" \
    PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
    "$STAGE" "$1" >/dev/null
}

run_test_stage app-dev.pluto.launcher
run_test_stage ink-stroke
[[ -s "$TMP/test-evidence/01-app-dev.pluto.launcher.jpg" ]] ||
  fail "first labeled image was not captured"
[[ -s "$TMP/test-evidence/02-ink-stroke.jpg" ]] ||
  fail "second labeled image was not captured"
[[ "$(wc -l < "$TMP/test-evidence/stages.tsv" | tr -d '[:space:]')" = 2 ]] ||
  fail "stage manifest does not contain exactly two rows"
grep -Eq '^01[[:space:]]+app-dev\.pluto\.launcher[[:space:]]+[0-9a-f]{64}[[:space:]]+01-app-dev\.pluto\.launcher\.jpg$' \
  "$TMP/test-evidence/stages.tsv" || fail "first manifest row is invalid"

TEST_PROVENANCE="$TMP/test-evidence/camera-provenance.tsv"
[[ -f "$TEST_PROVENANCE" && ! -L "$TEST_PROVENANCE" ]] ||
  fail "test capture provenance was not recorded as a regular file"
[[ "$(wc -l < "$TEST_PROVENANCE" | tr -d '[:space:]')" = 22 ]] ||
  fail "camera provenance does not contain the exact ordered rows"
[[ "$(cut -f1 "$TEST_PROVENANCE" | sort -u | wc -l | tr -d '[:space:]')" = 22 ]] ||
  fail "camera provenance contains duplicate keys"
assert_provenance_value "$TEST_PROVENANCE" test_seam 1
assert_provenance_value "$TEST_PROVENANCE" capture_mode test-override
assert_provenance_value "$TEST_PROVENANCE" capture_override_requested 1
assert_provenance_value "$TEST_PROVENANCE" camera_config_override_requested 0
assert_provenance_value "$TEST_PROVENANCE" camera_rig 2
assert_provenance_value "$TEST_PROVENANCE" camera_profile_id not-applicable
assert_provenance_value "$TEST_PROVENANCE" camera_capture_sha256 \
  "$(sha256_file "$TMP/fake-capture")"
assert_provenance_value "$TEST_PROVENANCE" camera_driver_path not-applicable
assert_provenance_value "$TEST_PROVENANCE" camera_driver_sha256 not-applicable
assert_provenance_value "$TEST_PROVENANCE" camera_python_binary not-applicable
assert_provenance_value "$TEST_PROVENANCE" camera_python_sha256 not-applicable
assert_provenance_value "$TEST_PROVENANCE" camera_ffmpeg_binary not-applicable
assert_provenance_value "$TEST_PROVENANCE" camera_ffmpeg_sha256 not-applicable
assert_provenance_value "$TEST_PROVENANCE" camera_ffprobe_binary not-applicable
assert_provenance_value "$TEST_PROVENANCE" camera_ffprobe_sha256 not-applicable
assert_provenance_value "$TEST_PROVENANCE" camera_config_path not-applicable
assert_provenance_value "$TEST_PROVENANCE" camera_config_sha256 not-applicable
assert_provenance_value "$TEST_PROVENANCE" camera_config_snapshot not-applicable
assert_provenance_value "$TEST_PROVENANCE" camera_config_snapshot_sha256 not-applicable

# An override cannot swap bytes after the first capture in an evidence bundle.
printf '# changed\n' >> "$TMP/fake-capture"
if run_test_stage changed-capture >/dev/null 2>&1; then
  fail "changed capture override was accepted in an existing evidence bundle"
fi

if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
  PLUTO_CAMERA_CAPTURE="$TMP/fake-capture" \
  PLUTO_CAMERA_RIG=2 \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/unsafe-label" \
  PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
  "$STAGE" '../unsafe' >/dev/null 2>&1; then
  fail "unsafe stage label was accepted"
fi

if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=invalid \
  PLUTO_CAMERA_CAPTURE="$TMP/fake-capture" \
  PLUTO_CAMERA_RIG=2 \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/invalid-test-seam" \
  PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
  "$STAGE" invalid-seam >/dev/null 2>&1; then
  fail "invalid test-seam value was accepted"
fi

# Build an isolated copy of the repository camera path. The real capture.sh is
# exercised, while a tiny local camera.py stands in for FFmpeg hardware.
FIXTURE_ROOT="$TMP/repository"
FIXTURE_CAMERA="$FIXTURE_ROOT/tools/setup/camera"
FIXTURE_DIAGNOSTICS="$FIXTURE_ROOT/tools/device/diagnostics"
mkdir -p "$FIXTURE_CAMERA" "$FIXTURE_DIAGNOSTICS"
cp "$STAGE" "$FIXTURE_CAMERA/capture-acceptance-stage.sh"
cp "$CAPTURE" "$FIXTURE_CAMERA/capture.sh"
cp "$ROOT/tools/device/diagnostics/acceptance_identity.py" "$FIXTURE_DIAGNOSTICS/"
chmod 0755 "$FIXTURE_CAMERA/capture-acceptance-stage.sh" "$FIXTURE_CAMERA/capture.sh"
cat > "$FIXTURE_CAMERA/camera.py" <<'PYTHON'
#!/usr/bin/env python3
from pathlib import Path
import sys

arguments = sys.argv[1:]
assert arguments[0:4] == ["image", "--device", "3", "--output"]
output = Path(arguments[4])
output.write_bytes((f"repository camera fixture {output.name}\n").encode())
print(output)
PYTHON
cat > "$FIXTURE_ROOT/.pluto-devices.json" <<'JSON'
{"schema_version":6,"camera":{"name":"fixture"},"devices":[{"number":3,"profile_id":"rm2"}]}
JSON

FIXTURE_STAGE="$FIXTURE_CAMERA/capture-acceptance-stage.sh"
run_repository_stage() {
  PLUTO_CAMERA_RIG=3 \
    PLUTO_ACCEPTANCE_PROFILE_ID=rm2 \
    PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/repository-evidence" \
    PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
    "$FIXTURE_STAGE" "$1" >/dev/null
}

run_repository_stage home
run_repository_stage counter
REPOSITORY_PROVENANCE="$TMP/repository-evidence/camera-provenance.tsv"
assert_provenance_value "$REPOSITORY_PROVENANCE" test_seam 0
assert_provenance_value "$REPOSITORY_PROVENANCE" capture_mode repository
assert_provenance_value "$REPOSITORY_PROVENANCE" capture_override_requested 0
assert_provenance_value "$REPOSITORY_PROVENANCE" camera_config_override_requested 0
assert_provenance_value "$REPOSITORY_PROVENANCE" camera_rig 3
assert_provenance_value "$REPOSITORY_PROVENANCE" camera_profile_id rm2
assert_provenance_value "$REPOSITORY_PROVENANCE" camera_stage_hook_sha256 \
  "$(sha256_file "$FIXTURE_STAGE")"
assert_provenance_value "$REPOSITORY_PROVENANCE" camera_capture_sha256 \
  "$(sha256_file "$FIXTURE_CAMERA/capture.sh")"
assert_provenance_value "$REPOSITORY_PROVENANCE" camera_driver_sha256 \
  "$(sha256_file "$FIXTURE_CAMERA/camera.py")"
TOOLCHAIN_ROWS="$("$FIXTURE_CAMERA/capture.sh" --acceptance-toolchain)"
toolchain_value() {
  local key="$1"
  printf '%s\n' "$TOOLCHAIN_ROWS" | awk -F '\t' -v key="$key" \
    '$1 == key {print $2}'
}
CANONICAL_SYSTEM_PYTHON="$(toolchain_value camera_python_binary)"
[[ "$CANONICAL_SYSTEM_PYTHON" == /* &&
  -f "$CANONICAL_SYSTEM_PYTHON" && ! -L "$CANONICAL_SYSTEM_PYTHON" &&
  -x "$CANONICAL_SYSTEM_PYTHON" ]] ||
  fail "system Python was not resolved to a canonical executable"
if [[ -L /usr/bin/python3 && "$CANONICAL_SYSTEM_PYTHON" == /usr/bin/python3 ]]; then
  fail "system Python symlink was not resolved before provenance"
fi
assert_provenance_value "$REPOSITORY_PROVENANCE" camera_python_binary \
  "$CANONICAL_SYSTEM_PYTHON"
assert_provenance_value "$REPOSITORY_PROVENANCE" camera_python_sha256 \
  "$(toolchain_value camera_python_sha256)"
assert_provenance_value "$REPOSITORY_PROVENANCE" camera_ffmpeg_binary \
  "$(toolchain_value camera_ffmpeg_binary)"
assert_provenance_value "$REPOSITORY_PROVENANCE" camera_ffmpeg_sha256 \
  "$(toolchain_value camera_ffmpeg_sha256)"
assert_provenance_value "$REPOSITORY_PROVENANCE" camera_ffprobe_binary \
  "$(toolchain_value camera_ffprobe_binary)"
assert_provenance_value "$REPOSITORY_PROVENANCE" camera_ffprobe_sha256 \
  "$(toolchain_value camera_ffprobe_sha256)"
assert_provenance_value "$REPOSITORY_PROVENANCE" camera_config_sha256 \
  "$(sha256_file "$FIXTURE_ROOT/.pluto-devices.json")"
assert_provenance_value "$REPOSITORY_PROVENANCE" camera_config_snapshot \
  camera-config.json
assert_provenance_value "$REPOSITORY_PROVENANCE" camera_config_snapshot_sha256 \
  "$(sha256_file "$FIXTURE_ROOT/.pluto-devices.json")"
[[ "$(sha256_file "$TMP/repository-evidence/camera-config.json")" == \
  "$(sha256_file "$FIXTURE_ROOT/.pluto-devices.json")" ]] ||
  fail "frozen camera config does not match the captured config"

# Production capture is entered through /bin/bash -p, clears loader controls,
# fixes its PATH, and resolves Python/FFmpeg/FFprobe without command lookup.
[[ "$(head -n 1 "$FIXTURE_STAGE")" == '#!/bin/bash -p' &&
  "$(head -n 1 "$FIXTURE_CAMERA/capture.sh")" == '#!/bin/bash -p' ]] ||
  fail "production camera entrypoints do not use privileged absolute Bash"
if /bin/bash "$FIXTURE_STAGE" hardened-entry \
  >"$TMP/unprivileged-stage.out" 2>&1; then
  fail "camera stage accepted an unprivileged Bash invocation"
fi
grep -q 'directly or with /bin/bash -p' "$TMP/unprivileged-stage.out" ||
  fail "camera stage did not diagnose an unprivileged Bash invocation"
mkdir -p "$TMP/path-shims" "$TMP/loader-search"
PATH_MARKER="$TMP/path-shim-used"
for shim in bash python3 ffmpeg ffprobe dirname awk shasum sha256sum; do
  cat > "$TMP/path-shims/$shim" <<EOF
#!/bin/sh
printf '%s\n' '$shim' >> '$PATH_MARKER'
exit 91
EOF
  chmod 0755 "$TMP/path-shims/$shim"
done
cat > "$TMP/bash-env" <<EOF
printf '%s\n' BASH_ENV >> '$PATH_MARKER'
EOF
(
  dirname() {
    printf '%s\n' exported-function >> "$PATH_MARKER"
    /usr/bin/dirname "$@"
  }
  export -f dirname
  PATH="$TMP/path-shims:$PATH" \
    BASH_ENV="$TMP/bash-env" \
    PLUTO_CAMERA_RIG=3 \
    PLUTO_ACCEPTANCE_PROFILE_ID=rm2 \
    PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/hardened-production-evidence" \
    PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
    "$FIXTURE_STAGE" hardened-entry >/dev/null
)
[[ ! -e "$PATH_MARKER" ]] ||
  fail "production camera capture executed a PATH/BASH_ENV/function shim"

if LD_LIBRARY_PATH="$TMP/loader-search" \
  PLUTO_CAMERA_RIG=3 \
  PLUTO_ACCEPTANCE_PROFILE_ID=rm2 \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/loader-injected-evidence" \
  PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
  "$FIXTURE_STAGE" loader-injected >/dev/null 2>&1; then
  fail "production camera capture accepted loader-injection environment"
fi
if PLUTO_CAMERA_FFMPEG_BIN="$TMP/path-shims/ffmpeg" \
  PLUTO_CAMERA_RIG=3 \
  PLUTO_ACCEPTANCE_PROFILE_ID=rm2 \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/media-override-evidence" \
  PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
  "$FIXTURE_STAGE" media-override >/dev/null 2>&1; then
  fail "production camera capture accepted an unmarked FFmpeg override"
fi

# Enabling a test seam is itself evidence, even with the repository capture.
PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
  PLUTO_CAMERA_RIG=3 \
  PLUTO_ACCEPTANCE_PROFILE_ID=rm2 \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/repository-test-seam" \
  PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
  "$FIXTURE_STAGE" seam-visible >/dev/null
assert_provenance_value \
  "$TMP/repository-test-seam/camera-provenance.tsv" test_seam 1
assert_provenance_value \
  "$TMP/repository-test-seam/camera-provenance.tsv" capture_mode repository

# A selected alternate rig config is visible and bound by digest. It remains a
# production capture, because multi-rig configs are a supported operator input.
cp "$FIXTURE_ROOT/.pluto-devices.json" "$TMP/alternate-camera-config.json"
PLUTO_CAMERA_CONFIG="$TMP/alternate-camera-config.json" \
  PLUTO_CAMERA_RIG=3 \
  PLUTO_ACCEPTANCE_PROFILE_ID=rm2 \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/alternate-config-evidence" \
  PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
  "$FIXTURE_STAGE" alternate-config >/dev/null
ALTERNATE_PROVENANCE="$TMP/alternate-config-evidence/camera-provenance.tsv"
assert_provenance_value "$ALTERNATE_PROVENANCE" test_seam 0
assert_provenance_value "$ALTERNATE_PROVENANCE" capture_mode repository
assert_provenance_value "$ALTERNATE_PROVENANCE" camera_config_override_requested 1
assert_provenance_value "$ALTERNATE_PROVENANCE" camera_config_sha256 \
  "$(sha256_file "$TMP/alternate-camera-config.json")"
assert_provenance_value "$ALTERNATE_PROVENANCE" camera_config_snapshot_sha256 \
  "$(sha256_file "$TMP/alternate-camera-config.json")"

printf 'tampered snapshot\n' > "$TMP/alternate-config-evidence/camera-config.json"
if PLUTO_CAMERA_CONFIG="$TMP/alternate-camera-config.json" \
  PLUTO_CAMERA_RIG=3 \
  PLUTO_ACCEPTANCE_PROFILE_ID=rm2 \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/alternate-config-evidence" \
  PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
  "$FIXTURE_STAGE" tampered-snapshot >/dev/null 2>&1; then
  fail "tampered camera config snapshot was accepted"
fi

# Config bytes and seam status are immutable over one evidence directory.
printf ' \n' >> "$FIXTURE_ROOT/.pluto-devices.json"
if run_repository_stage changed-config >/dev/null 2>&1; then
  fail "changed camera config was accepted in an existing evidence bundle"
fi
if PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1 \
  PLUTO_CAMERA_RIG=3 \
  PLUTO_ACCEPTANCE_PROFILE_ID=rm2 \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/repository-evidence" \
  PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
  "$FIXTURE_STAGE" changed-seam >/dev/null 2>&1; then
  fail "test seam was hidden by toggling it within an evidence bundle"
fi

ln -s "$TMP/alternate-camera-config.json" "$TMP/camera-config-link.json"
if PLUTO_CAMERA_CONFIG="$TMP/camera-config-link.json" \
  PLUTO_CAMERA_RIG=3 \
  PLUTO_ACCEPTANCE_PROFILE_ID=rm2 \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/symlink-config-evidence" \
  PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
  "$FIXTURE_STAGE" symlink-config >/dev/null 2>&1; then
  fail "symlink camera config was accepted for production evidence"
fi

mkdir -p "$TMP/provenance-target" "$TMP/provenance-symlink-evidence"
printf 'not provenance\n' > "$TMP/provenance-target/file"
ln -s "$TMP/provenance-target/file" \
  "$TMP/provenance-symlink-evidence/camera-provenance.tsv"
if PLUTO_CAMERA_RIG=3 \
  PLUTO_ACCEPTANCE_PROFILE_ID=rm2 \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/provenance-symlink-evidence" \
  PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
  "$FIXTURE_STAGE" symlink-provenance >/dev/null 2>&1; then
  fail "symlink provenance file was accepted"
fi

if PLUTO_CAMERA_RIG=3 \
  PLUTO_ACCEPTANCE_PROFILE_ID=rm1 \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/wrong-profile-evidence" \
  PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
  "$FIXTURE_STAGE" wrong-profile >/dev/null 2>&1; then
  fail "camera rig bound to rm2 was accepted for rm1"
fi
if PLUTO_CAMERA_RIG=4 \
  PLUTO_ACCEPTANCE_PROFILE_ID=rm2 \
  PLUTO_CAMERA_ACCEPTANCE_DIR="$TMP/wrong-rig-evidence" \
  PLUTO_CAMERA_ACCEPTANCE_SETTLE=0 \
  "$FIXTURE_STAGE" wrong-rig >/dev/null 2>&1; then
  fail "unconfigured camera rig was accepted"
fi

# The repository wrapper independently refuses a driver/config mismatch and an
# explicit --config that could differ from the stage's recorded environment.
DRIVER_SHA="$(sha256_file "$FIXTURE_CAMERA/camera.py")"
CONFIG_SHA="$(sha256_file "$FIXTURE_ROOT/.pluto-devices.json")"
if PLUTO_CAMERA_EXPECTED_DRIVER_SHA256="$(printf '0%.0s' {1..64})" \
  PLUTO_CAMERA_EXPECTED_CONFIG_SHA256="$CONFIG_SHA" \
  "$FIXTURE_CAMERA/capture.sh" image --device 3 --output "$TMP/bad-driver.jpg" \
  >/dev/null 2>&1; then
  fail "capture wrapper accepted a mismatched camera driver digest"
fi
if PLUTO_CAMERA_EXPECTED_DRIVER_SHA256="$DRIVER_SHA" \
  PLUTO_CAMERA_EXPECTED_CONFIG_SHA256="$(printf '0%.0s' {1..64})" \
  "$FIXTURE_CAMERA/capture.sh" image --device 3 --output "$TMP/bad-config.jpg" \
  >/dev/null 2>&1; then
  fail "capture wrapper accepted a mismatched camera config digest"
fi
if PLUTO_CAMERA_EXPECTED_DRIVER_SHA256="$DRIVER_SHA" \
  PLUTO_CAMERA_EXPECTED_CONFIG_SHA256="$CONFIG_SHA" \
  "$FIXTURE_CAMERA/capture.sh" --config "$TMP/alternate-camera-config.json" \
  image --device 3 --output "$TMP/explicit-config.jpg" >/dev/null 2>&1; then
  fail "acceptance capture wrapper accepted an explicit config argument"
fi

echo "camera acceptance stage test: PASS"
