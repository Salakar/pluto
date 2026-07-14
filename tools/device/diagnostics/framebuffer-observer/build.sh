#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SOURCE_DIR/../../../.." && pwd)"
BUILD_ROOT="${PLUTO_FB_OBSERVER_BUILD_DIR:-$ROOT/.pluto-cache/diagnostics/framebuffer-observer}"
IMAGE="${PLUTO_ARM_EMBEDDER_BUILDER_IMAGE:-pluto/embedder-builder:ubuntu24.04-amd64-rm-sdk}"
SDK_VOLUME="${PLUTO_RM_SDK_VOLUME:-pluto-rm2-sdk-4.4.128-v2}"
SDK_DIR="${PLUTO_RM_SDK_DIR:-}"
RUN_TESTS=0
BUILD_ARM=0
DRY_RUN=0
SKIP_IMAGE_BUILD=0

usage() {
  cat <<'EOF'
Usage: tools/device/diagnostics/framebuffer-observer/build.sh [options]

Build and test the diagnostics-only framebuffer observer. With no options,
only the host unit tests run. ARM output stays under .pluto-cache and is never
added to a Pluto product payload.

Options:
  --test              compile and run host C and Python decoder tests
  --arm               cross-build the ARMv7 LD_PRELOAD shared object
  --all               run tests and cross-build the shared object
  --sdk-volume NAME   use an installed reMarkable SDK Docker volume
  --sdk-dir PATH      use an extracted reMarkable SDK directory
  --image NAME        override the linux/amd64 builder image
  --skip-image-build  reuse an already-built builder image
  --dry-run           print ARM Docker and ELF-gate commands only
  -h, --help          show this help
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

run_arm_command() {
  print_command "$@"
  if ((DRY_RUN == 0)); then
    "$@"
  fi
}

while (($# > 0)); do
  case "$1" in
    --test) RUN_TESTS=1 ;;
    --arm) BUILD_ARM=1 ;;
    --all)
      RUN_TESTS=1
      BUILD_ARM=1
      ;;
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
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

if ((RUN_TESTS == 0 && BUILD_ARM == 0)); then
  RUN_TESTS=1
fi

if ((RUN_TESTS == 1)); then
  HOST_DIR="$BUILD_ROOT/host"
  mkdir -p "$HOST_DIR"
  HOST_COMPILER="${CC:-cc}"
  print_command "$HOST_COMPILER" -std=c11 -O2 -g -Wall -Wextra -Werror \
    -I"$SOURCE_DIR/include" -I"$SOURCE_DIR/src" \
    "$SOURCE_DIR/src/fb_observer_core.c" \
    "$SOURCE_DIR/test/observer_test.c" \
    -o "$HOST_DIR/observer_test"
  "$HOST_COMPILER" -std=c11 -O2 -g -Wall -Wextra -Werror \
    -I"$SOURCE_DIR/include" -I"$SOURCE_DIR/src" \
    "$SOURCE_DIR/src/fb_observer_core.c" \
    "$SOURCE_DIR/test/observer_test.c" \
    -o "$HOST_DIR/observer_test"
  "$HOST_DIR/observer_test"
  python3 -m unittest discover -s "$SOURCE_DIR/test" -p 'test_*.py' -v
fi

if ((BUILD_ARM == 0)); then
  exit 0
fi

[[ -n "$IMAGE" ]] || die "builder image tag must not be empty"
[[ -f "$ROOT/tools/build/Dockerfile.embedder-device" ]] ||
  die "missing tools/build/Dockerfile.embedder-device"

if [[ -n "$SDK_DIR" ]]; then
  if ((DRY_RUN == 0)); then
    [[ -d "$SDK_DIR" ]] || die "SDK directory does not exist: $SDK_DIR"
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
  docker info >/dev/null 2>&1 || die "Docker daemon is not available"
  if [[ -z "$SDK_DIR" ]] &&
    ! docker volume inspect "$SDK_VOLUME" >/dev/null 2>&1; then
    die "reMarkable SDK Docker volume is not installed: $SDK_VOLUME"
  fi
fi

if ((SKIP_IMAGE_BUILD == 0)); then
  run_arm_command docker build \
    --platform linux/amd64 \
    --file "$ROOT/tools/build/Dockerfile.embedder-device" \
    --tag "$IMAGE" \
    "$ROOT/tools/build"
fi

ARM_OUTPUT="$BUILD_ROOT/arm"
mkdir -p "$ARM_OUTPUT"
run_arm_command docker run --rm \
  --platform linux/amd64 \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --env PLUTO_RM_SDK_ROOT=/sdk \
  --env PLUTO_WORKSPACE=/work \
  --env PLUTO_FB_OBSERVER_OUTPUT_DIR=/observer-output/arm \
  --volume "$SDK_MOUNT_SOURCE:/sdk:ro" \
  --volume "$ROOT:/work" \
  --volume "$BUILD_ROOT:/observer-output" \
  --workdir /work \
  "$IMAGE" \
  bash tools/device/diagnostics/framebuffer-observer/build-arm-container.sh

run_arm_command bash "$ROOT/tools/build/verify-device-elf.sh" \
  "$ARM_OUTPUT/libpluto-fb-observer.so" 2.35 linux-arm

if ((DRY_RUN == 0)); then
  EXPORTED_SYMBOLS="$(
    objdump -T "$ARM_OUTPUT/libpluto-fb-observer.so" |
      awk '$4 == ".text" {print $NF}'
  )"
  for symbol in open open64 close ioctl mmap mmap64 munmap; do
    grep -qx "$symbol" <<<"$EXPORTED_SYMBOLS" ||
      die "ARM observer does not export required interposer symbol: $symbol"
  done
  echo "interposer export gate: PASS (open/open64/close/ioctl/mmap/mmap64/munmap)"
  echo "ARMv7 framebuffer observer: $ARM_OUTPUT/libpluto-fb-observer.so"
fi
