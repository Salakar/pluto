#!/bin/bash -p
# Agent-facing entry point for configured physical-device camera capture.
set -euo pipefail
[[ "$-" == *p* ]] || {
  echo "pluto-camera: execute this entrypoint directly or with /bin/bash -p" >&2
  exit 2
}

ALLOW_TEST_HOOKS="${PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS:-0}"
[[ "$ALLOW_TEST_HOOKS" == 0 || "$ALLOW_TEST_HOOKS" == 1 ]] || {
  echo "pluto-camera: PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS must be 0 or 1" >&2
  exit 2
}
LOADER_ENV_NAMES=()
while IFS= read -r loader_name; do
  case "$loader_name" in
    LD_* | DYLD_* | GLIBC_TUNABLES) LOADER_ENV_NAMES+=("$loader_name") ;;
  esac
done < <(compgen -e)
if [[ "$ALLOW_TEST_HOOKS" != 1 ]] && ((${#LOADER_ENV_NAMES[@]} > 0)); then
  for loader_name in "${LOADER_ENV_NAMES[@]}"; do
    [[ -z "${!loader_name:-}" ]] || {
      echo "pluto-camera: $loader_name is forbidden for production capture" >&2
      exit 2
    }
  done
fi
unset BASH_ENV ENV CDPATH GLOBIGNORE
if ((${#LOADER_ENV_NAMES[@]} > 0)); then
  for loader_name in "${LOADER_ENV_NAMES[@]}"; do
    unset "$loader_name"
  done
fi
if [[ "$ALLOW_TEST_HOOKS" != 1 ]]; then
  PATH=/usr/bin:/bin
  export PATH
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$SCRIPT_DIR/camera.py"
DEFAULT_CONFIG="$SCRIPT_DIR/../../../.pluto-devices.json"
PYTHON_OVERRIDE="${PLUTO_CAMERA_PYTHON_BIN:-}"
FFMPEG_OVERRIDE="${PLUTO_CAMERA_FFMPEG_BIN:-}"
FFPROBE_OVERRIDE="${PLUTO_CAMERA_FFPROBE_BIN:-}"

die() {
  echo "pluto-camera: $*" >&2
  exit 2
}

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
  # Linux distributions commonly expose this fixed system path as a symlink.
  # The resolved executable below must still be regular, executable, and
  # non-symlinked before its bytes are admitted into acceptance provenance.
  [[ -x /usr/bin/python3 && -f /usr/bin/python3 ]] ||
    die "pinned path resolver is unavailable: /usr/bin/python3"
  resolved="$(/usr/bin/python3 -I -c \
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
    [[ "$ALLOW_TEST_HOOKS" == 1 ]] ||
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

if [[ -n "$PYTHON_OVERRIDE" && "$ALLOW_TEST_HOOKS" != 1 ]]; then
  die "PLUTO_CAMERA_PYTHON_BIN requires PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1"
fi
PYTHON_BIN="$(canonical_executable \
  "${PYTHON_OVERRIDE:-/usr/bin/python3}" "Python interpreter")"
FFMPEG_BIN="$(resolve_media_tool ffmpeg "$FFMPEG_OVERRIDE")"
FFPROBE_BIN="$(resolve_media_tool ffprobe "$FFPROBE_OVERRIDE")"
PYTHON_SHA256="$(sha256_file "$PYTHON_BIN")"
FFMPEG_SHA256="$(sha256_file "$FFMPEG_BIN")"
FFPROBE_SHA256="$(sha256_file "$FFPROBE_BIN")"

if [[ "${1:-}" == --acceptance-toolchain ]]; then
  [[ "$#" == 1 ]] || die "--acceptance-toolchain takes no arguments"
  printf 'camera_python_binary\t%s\n' "$PYTHON_BIN"
  printf 'camera_python_sha256\t%s\n' "$PYTHON_SHA256"
  printf 'camera_ffmpeg_binary\t%s\n' "$FFMPEG_BIN"
  printf 'camera_ffmpeg_sha256\t%s\n' "$FFMPEG_SHA256"
  printf 'camera_ffprobe_binary\t%s\n' "$FFPROBE_BIN"
  printf 'camera_ffprobe_sha256\t%s\n' "$FFPROBE_SHA256"
  exit 0
fi

[[ -f "$DRIVER" && ! -L "$DRIVER" ]] ||
  die "camera driver must be a regular repository file: $DRIVER"

# The acceptance-stage wrapper sets these internal expectations after recording
# its provenance. They ensure the Python driver and rig configuration read by
# the capture are exactly the bytes that the evidence bundle names. Ordinary
# interactive captures leave both variables unset and retain the normal CLI.
EXPECTED_DRIVER_SHA="${PLUTO_CAMERA_EXPECTED_DRIVER_SHA256:-}"
EXPECTED_CONFIG_SHA="${PLUTO_CAMERA_EXPECTED_CONFIG_SHA256:-}"
EXPECTED_PYTHON_BINARY="${PLUTO_CAMERA_EXPECTED_PYTHON_BINARY:-}"
EXPECTED_PYTHON_SHA="${PLUTO_CAMERA_EXPECTED_PYTHON_SHA256:-}"
EXPECTED_FFMPEG_BINARY="${PLUTO_CAMERA_EXPECTED_FFMPEG_BINARY:-}"
EXPECTED_FFMPEG_SHA="${PLUTO_CAMERA_EXPECTED_FFMPEG_SHA256:-}"
EXPECTED_FFPROBE_BINARY="${PLUTO_CAMERA_EXPECTED_FFPROBE_BINARY:-}"
EXPECTED_FFPROBE_SHA="${PLUTO_CAMERA_EXPECTED_FFPROBE_SHA256:-}"
if [[ -n "$EXPECTED_DRIVER_SHA" || -n "$EXPECTED_CONFIG_SHA" ||
  -n "$EXPECTED_PYTHON_BINARY" || -n "$EXPECTED_PYTHON_SHA" ||
  -n "$EXPECTED_FFMPEG_BINARY" || -n "$EXPECTED_FFMPEG_SHA" ||
  -n "$EXPECTED_FFPROBE_BINARY" || -n "$EXPECTED_FFPROBE_SHA" ]]; then
  [[ "$EXPECTED_DRIVER_SHA" =~ ^[0-9a-f]{64}$ ]] ||
    die "invalid PLUTO_CAMERA_EXPECTED_DRIVER_SHA256"
  [[ "$EXPECTED_CONFIG_SHA" =~ ^[0-9a-f]{64}$ ]] ||
    die "invalid PLUTO_CAMERA_EXPECTED_CONFIG_SHA256"
  [[ "$EXPECTED_PYTHON_BINARY" == /* &&
    "$EXPECTED_PYTHON_BINARY" != *$'\t'* &&
    "$EXPECTED_PYTHON_BINARY" != *$'\n'* ]] ||
    die "invalid PLUTO_CAMERA_EXPECTED_PYTHON_BINARY"
  [[ "$EXPECTED_PYTHON_SHA" =~ ^[0-9a-f]{64}$ ]] ||
    die "invalid PLUTO_CAMERA_EXPECTED_PYTHON_SHA256"
  [[ "$EXPECTED_FFMPEG_BINARY" == /* &&
    "$EXPECTED_FFMPEG_BINARY" != *$'\t'* &&
    "$EXPECTED_FFMPEG_BINARY" != *$'\n'* ]] ||
    die "invalid PLUTO_CAMERA_EXPECTED_FFMPEG_BINARY"
  [[ "$EXPECTED_FFMPEG_SHA" =~ ^[0-9a-f]{64}$ ]] ||
    die "invalid PLUTO_CAMERA_EXPECTED_FFMPEG_SHA256"
  [[ "$EXPECTED_FFPROBE_BINARY" == /* &&
    "$EXPECTED_FFPROBE_BINARY" != *$'\t'* &&
    "$EXPECTED_FFPROBE_BINARY" != *$'\n'* ]] ||
    die "invalid PLUTO_CAMERA_EXPECTED_FFPROBE_BINARY"
  [[ "$EXPECTED_FFPROBE_SHA" =~ ^[0-9a-f]{64}$ ]] ||
    die "invalid PLUTO_CAMERA_EXPECTED_FFPROBE_SHA256"

  for argument in "$@"; do
    case "$argument" in
      --config | --config=*)
        die "acceptance capture config must come from PLUTO_CAMERA_CONFIG"
        ;;
    esac
  done

  CONFIG="${PLUTO_CAMERA_CONFIG:-$DEFAULT_CONFIG}"
  [[ -f "$CONFIG" && ! -L "$CONFIG" ]] ||
    die "acceptance camera config must be a regular file: $CONFIG"
  [[ "$(sha256_file "$DRIVER")" == "$EXPECTED_DRIVER_SHA" ]] ||
    die "camera driver changed after acceptance provenance was recorded"
  [[ "$(sha256_file "$CONFIG")" == "$EXPECTED_CONFIG_SHA" ]] ||
    die "camera config changed after acceptance provenance was recorded"
  [[ "$PYTHON_BIN" == "$EXPECTED_PYTHON_BINARY" &&
    "$PYTHON_SHA256" == "$EXPECTED_PYTHON_SHA" ]] ||
    die "Python runtime changed after acceptance provenance was recorded"
  [[ "$FFMPEG_BIN" == "$EXPECTED_FFMPEG_BINARY" &&
    "$FFMPEG_SHA256" == "$EXPECTED_FFMPEG_SHA" ]] ||
    die "FFmpeg changed after acceptance provenance was recorded"
  [[ "$FFPROBE_BIN" == "$EXPECTED_FFPROBE_BINARY" &&
    "$FFPROBE_SHA256" == "$EXPECTED_FFPROBE_SHA" ]] ||
    die "FFprobe changed after acceptance provenance was recorded"
fi

PLUTO_CAMERA_FFMPEG_BIN="$FFMPEG_BIN" \
  PLUTO_CAMERA_FFPROBE_BIN="$FFPROBE_BIN" \
  exec "$PYTHON_BIN" -I "$DRIVER" "$@"
