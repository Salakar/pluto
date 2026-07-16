#!/usr/bin/env bash
# Agent-facing entry point for configured physical-device camera capture.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$SCRIPT_DIR/camera.py"
DEFAULT_CONFIG="$SCRIPT_DIR/../../../.pluto-devices.json"

die() {
  echo "pluto-camera: $*" >&2
  exit 2
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

[[ -f "$DRIVER" && ! -L "$DRIVER" ]] ||
  die "camera driver must be a regular repository file: $DRIVER"

# The acceptance-stage wrapper sets these internal expectations after recording
# its provenance. They ensure the Python driver and rig configuration read by
# the capture are exactly the bytes that the evidence bundle names. Ordinary
# interactive captures leave both variables unset and retain the normal CLI.
EXPECTED_DRIVER_SHA="${PLUTO_CAMERA_EXPECTED_DRIVER_SHA256:-}"
EXPECTED_CONFIG_SHA="${PLUTO_CAMERA_EXPECTED_CONFIG_SHA256:-}"
if [[ -n "$EXPECTED_DRIVER_SHA" || -n "$EXPECTED_CONFIG_SHA" ]]; then
  [[ "$EXPECTED_DRIVER_SHA" =~ ^[0-9a-f]{64}$ ]] ||
    die "invalid PLUTO_CAMERA_EXPECTED_DRIVER_SHA256"
  [[ "$EXPECTED_CONFIG_SHA" =~ ^[0-9a-f]{64}$ ]] ||
    die "invalid PLUTO_CAMERA_EXPECTED_CONFIG_SHA256"

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
fi

exec python3 "$DRIVER" "$@"
