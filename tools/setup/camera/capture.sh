#!/usr/bin/env bash
# Agent-facing entry point for configured physical-device camera capture.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/camera.py" "$@"
