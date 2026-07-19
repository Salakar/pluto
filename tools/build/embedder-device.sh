#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/tools/build"
IMAGE="${PLUTO_EMBEDDER_BUILDER_IMAGE:-pluto/embedder-builder:ubuntu24.04-arm64}"
JOBS="${PLUTO_BUILD_JOBS:-}"
DRY_RUN=0
SKIP_IMAGE_BUILD=0
CLEAN_FIRST=0

usage() {
  cat <<'EOF'
Usage: tools/build/embedder-device.sh [options]

Build pluto-embedder natively in an Ubuntu 24.04 arm64 container, then
verify that the result is AArch64 and requires no GLIBC newer than 2.39.

Options:
  --image NAME         override the local builder image tag
  --skip-image-build   reuse an already-built builder image
  --clean-first        clean the CMake target before building
  --dry-run            print Docker commands without running them
  -h, --help           show this help

Environment:
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
[[ -f "$BUILD_DIR/embedder-device-container.sh" ]] ||
  die "missing $BUILD_DIR/embedder-device-container.sh"

if ((DRY_RUN == 0)); then
  command -v docker >/dev/null 2>&1 || die "Docker is required"
  docker info >/dev/null 2>&1 ||
    die "Docker is installed, but its daemon is not available"
fi

if ((SKIP_IMAGE_BUILD == 0)); then
  run docker build \
    --platform linux/arm64 \
    --file "$BUILD_DIR/Dockerfile.embedder-device" \
    --tag "$IMAGE" \
    "$BUILD_DIR"
fi

DOCKER_RUN=(
  docker run --rm
  --platform linux/arm64
  --user "$(id -u):$(id -g)"
  --env HOME=/tmp
  --env "PLUTO_BUILD_JOBS=$JOBS"
  --env "PLUTO_DEVICE_CLEAN_FIRST=$CLEAN_FIRST"
  --env PLUTO_GLIBC_CEILING=2.39
  --volume "$ROOT:/work"
  --workdir /work
  "$IMAGE"
  bash tools/build/embedder-device-container.sh
)
run "${DOCKER_RUN[@]}"

if ((DRY_RUN == 0)); then
  echo "device embedder: $ROOT/embedder/build/device-arm64/pluto-embedder"
  echo "device control client: $ROOT/embedder/build/device-arm64/pluto-controlctl"
fi
