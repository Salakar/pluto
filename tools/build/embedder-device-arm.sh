#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/tools/build"
IMAGE="${PLUTO_ARM_EMBEDDER_BUILDER_IMAGE:-pluto/embedder-builder:ubuntu24.04-amd64-rm-sdk}"
SDK_VOLUME="${PLUTO_RM_SDK_VOLUME:-pluto-rm2-sdk-4.4.128-v2}"
SDK_DIR="${PLUTO_RM_SDK_DIR:-}"
JOBS="${PLUTO_BUILD_JOBS:-}"
DRY_RUN=0
SKIP_IMAGE_BUILD=0
CLEAN_FIRST=0

usage() {
  cat <<'EOF'
Usage: tools/build/embedder-device-arm.sh [options]

Cross-build the release pluto-embedder for the common reMarkable 1/2
ARMv7-A NEON hard-float baseline with the official reMarkable SDK, then gate
the result against the RM1/RM2 ABI ceilings.

Options:
  --sdk-volume NAME   use an installed SDK Docker volume
  --sdk-dir PATH      use an extracted SDK directory on the host
  --image NAME        override the local linux/amd64 builder image tag
  --skip-image-build  reuse an already-built builder image
  --clean-first       clean the CMake target before building
  --dry-run           print Docker and verification commands without running
  -h, --help          show this help

Environment:
  PLUTO_RM_SDK_VOLUME, PLUTO_RM_SDK_DIR, and
  PLUTO_ARM_EMBEDDER_BUILDER_IMAGE select the local inputs.
  PLUTO_BUILD_JOBS controls CMake build parallelism when set.
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

print_command() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
}

run() {
  print_command "$@"
  if ((DRY_RUN == 0)); then
    "$@"
  fi
}

while (($# > 0)); do
  case "$1" in
    --sdk-volume)
      shift
      (($# > 0)) || die "--sdk-volume requires a value"
      SDK_VOLUME="$1"
      SDK_DIR=""
      ;;
    --sdk-volume=*)
      SDK_VOLUME="${1#*=}"
      SDK_DIR=""
      ;;
    --sdk-dir)
      shift
      (($# > 0)) || die "--sdk-dir requires a value"
      SDK_DIR="$1"
      SDK_VOLUME=""
      ;;
    --sdk-dir=*)
      SDK_DIR="${1#*=}"
      SDK_VOLUME=""
      ;;
    --image)
      shift
      (($# > 0)) || die "--image requires a value"
      IMAGE="$1"
      ;;
    --image=*) IMAGE="${1#*=}" ;;
    --skip-image-build) SKIP_IMAGE_BUILD=1 ;;
    --clean-first) CLEAN_FIRST=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[[ -n "$IMAGE" ]] || die "builder image tag must not be empty"
if [[ -n "$JOBS" && ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  die "PLUTO_BUILD_JOBS must be a positive integer"
fi
[[ -f "$BUILD_DIR/Dockerfile.embedder-device" ]] ||
  die "missing $BUILD_DIR/Dockerfile.embedder-device"
[[ -f "$BUILD_DIR/embedder-device-arm-container.sh" ]] ||
  die "missing $BUILD_DIR/embedder-device-arm-container.sh"

if [[ -n "$SDK_DIR" ]]; then
  if ((DRY_RUN == 0)); then
    [[ -d "$SDK_DIR" ]] || die "reMarkable SDK directory does not exist: $SDK_DIR"
    SDK_DIR="$(cd "$SDK_DIR" && pwd)"
    [[ -f "$SDK_DIR/environment-setup-cortexa7hf-neon-remarkable-linux-gnueabi" ]] ||
      die "not an installed reMarkable SDK directory: $SDK_DIR"
  fi
  SDK_MOUNT_SOURCE="$SDK_DIR"
else
  [[ -n "$SDK_VOLUME" ]] ||
    die "select an SDK with --sdk-volume or --sdk-dir"
  SDK_MOUNT_SOURCE="$SDK_VOLUME"
fi

if ((DRY_RUN == 0)); then
  command -v docker >/dev/null 2>&1 || die "Docker is required"
  docker info >/dev/null 2>&1 ||
    die "Docker is installed, but its daemon is not available"
  if [[ -z "$SDK_DIR" ]] && ! docker volume inspect "$SDK_VOLUME" >/dev/null 2>&1; then
    die "reMarkable SDK Docker volume '$SDK_VOLUME' is not installed; pass --sdk-volume NAME or --sdk-dir PATH"
  fi
fi

if ((SKIP_IMAGE_BUILD == 0)); then
  run docker build \
    --platform linux/amd64 \
    --file "$BUILD_DIR/Dockerfile.embedder-device" \
    --tag "$IMAGE" \
    "$BUILD_DIR"
fi

DOCKER_RUN=(
  docker run --rm
  --platform linux/amd64
  --user "$(id -u):$(id -g)"
  --env HOME=/tmp
  --env "PLUTO_BUILD_JOBS=$JOBS"
  --env "PLUTO_DEVICE_CLEAN_FIRST=$CLEAN_FIRST"
  --env PLUTO_RM_SDK_ROOT=/sdk
  --volume "$SDK_MOUNT_SOURCE:/sdk:ro"
  --volume "$ROOT:/work"
  --workdir /work
  "$IMAGE"
  bash tools/build/embedder-device-arm-container.sh
)
run "${DOCKER_RUN[@]}"

OUTPUT="$ROOT/embedder/build/device-arm/pluto-embedder"
run bash "$ROOT/tools/build/verify-device-elf.sh" "$OUTPUT" 2.35 linux-arm
CONTROL_CLIENT="$ROOT/embedder/build/device-arm/pluto-apploadctl"
run bash "$ROOT/tools/build/verify-device-elf.sh" \
  "$CONTROL_CLIENT" 2.35 linux-arm

if ((DRY_RUN == 0)); then
  echo "ARMv7 device embedder: $OUTPUT"
  echo "ARMv7 AppLoad control client: $CONTROL_CLIENT"
fi
