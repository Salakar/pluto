#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EMBEDDER_DIR="$ROOT/embedder"
PRESET="${PLUTO_HOST_CMAKE_PRESET:-host-debug}"
DRY_RUN=0
RUN_TESTS=1
CLEAN_FIRST=0

usage() {
  cat <<'EOF'
Usage: tools/build/embedder-host.sh [options]

Build the host embedder with a checked-in CMake preset and run its tests.

Options:
  --preset NAME   host-debug (default), host-release, host-asan, or host-tsan
  --no-tests      build without running CTest
  --clean-first   clean the preset's targets before building
  --dry-run       print commands without configuring or building
  -h, --help      show this help
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
    --preset)
      shift
      (($# > 0)) || die "--preset requires a value"
      PRESET="$1"
      ;;
    --preset=*) PRESET="${1#*=}" ;;
    --no-tests) RUN_TESTS=0 ;;
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

case "$PRESET" in
  host-debug | host-release | host-asan | host-tsan) ;;
  *) die "unsupported host preset: $PRESET" ;;
esac

[[ -f "$EMBEDDER_DIR/CMakePresets.json" ]] ||
  die "missing $EMBEDDER_DIR/CMakePresets.json"

if ((DRY_RUN == 0)); then
  command -v cmake >/dev/null 2>&1 || die "cmake 3.27 or newer is required"
  command -v ninja >/dev/null 2>&1 || die "ninja is required"
  if ((RUN_TESTS == 1)); then
    command -v ctest >/dev/null 2>&1 || die "ctest is required unless --no-tests is used"
  fi
fi

printf '+ cd %q\n' "$EMBEDDER_DIR"
cd "$EMBEDDER_DIR"

run cmake --preset "$PRESET"

BUILD_COMMAND=(cmake --build --preset "$PRESET" --parallel)
if ((CLEAN_FIRST == 1)); then
  BUILD_COMMAND+=(--clean-first)
fi
run "${BUILD_COMMAND[@]}"

if ((RUN_TESTS == 1)); then
  run ctest --preset "$PRESET" --output-on-failure
fi

if ((DRY_RUN == 0)); then
  echo "host embedder: $EMBEDDER_DIR/build/$PRESET/pluto-embedder"
fi
