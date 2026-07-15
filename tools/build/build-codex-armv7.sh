#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECIPE_DIR="$ROOT/tools/build/codex-armv7"
SDK_FINGERPRINT="$ROOT/tools/build/fingerprint-arm-sdk.sh"
SDK_PIN="$ROOT/tools/pluto/pins/arm-sdk.pin"
BUILD_ROOT="${PLUTO_CODEX_ARMV7_BUILD_ROOT:-$ROOT/.pluto-cache/build/codex-armv7}"
IMAGE="${PLUTO_CODEX_ARMV7_BUILDER_IMAGE:-pluto/codex-armv7-builder:rust1.95}"
SDK_VOLUME="${PLUTO_RM_SDK_VOLUME:-pluto-rm2-sdk-4.4.128-v2}"
SDK_DIR="${PLUTO_RM_SDK_DIR:-}"
SKIP_IMAGE_BUILD=0
DRY_RUN=0
RUN_ID=""
EXPECTED_SHA256=""

readonly SOURCE_URL=https://github.com/openai/codex.git
readonly SOURCE_TAG=rust-v0.144.1
readonly SOURCE_COMMIT=44918ea10c0f99151c6710411b4322c2f5c96bea
readonly RUST_TOOLCHAIN=1.95.0
readonly SOURCE_DATE_EPOCH=1783635027
readonly CANONICAL_SHA256=df8b6673f48b10356a7cee64b405c14435401a083f5e04ee147f0bd7b6760bdf

SOURCE_DIR="$BUILD_ROOT/source-cache/$SOURCE_COMMIT"

usage() {
  cat <<'EOF'
Usage: tools/build/build-codex-armv7.sh [options]

Build the real OpenAI Codex CLI 0.144.1 for the common ARMv7-A NEON
hard-float target used by reMarkable 1 and 2. Every invocation creates a new,
isolated source checkout, Cargo home, target tree, and candidate output under
an input digest. The canonical device-tested binary is never overwritten.

Options:
  --sdk-volume NAME       use an installed SDK Docker volume
  --sdk-dir PATH          use an extracted official SDK directory
  --source-dir PATH       override the clean official-source cache checkout
  --image NAME            override the local linux/amd64 builder image tag
  --run-id NAME           name this fresh isolated run (default: UTC time + PID)
  --expect-sha256 SHA     reject the candidate unless its SHA-256 is SHA
  --skip-image-build      reuse a recipe-keyed builder image
  --dry-run               print the checkout/build/verification plan
  -h, --help              show this help

Candidate output:
  .pluto-cache/build/codex-armv7/runs/<input-key>/<run-id>/output/codex

The accepted canonical output and pin remain unchanged until a separately
reviewed promotion after two isolated candidates match byte-for-byte.
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
  "$@"
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    LC_ALL=C shasum -a 256 "$path" | awk '{print $1}'
  fi
}

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    LC_ALL=C shasum -a 256 | awk '{print $1}'
  fi
}

pin_value() {
  local key="$1"
  local values
  values="$(sed -n "s/^${key}=//p" "$SDK_PIN")"
  [[ -n "$values" && "$values" != *$'\n'* ]] ||
    die "ARM SDK pin must contain exactly one $key field: $SDK_PIN"
  printf '%s\n' "$values"
}

while (($# > 0)); do
  case "$1" in
    --sdk-volume)
      shift
      (($# > 0)) || die "--sdk-volume requires a value"
      SDK_VOLUME="$1"
      SDK_DIR=""
      ;;
    --sdk-volume=*) SDK_VOLUME="${1#*=}"; SDK_DIR="" ;;
    --sdk-dir)
      shift
      (($# > 0)) || die "--sdk-dir requires a value"
      SDK_DIR="$1"
      SDK_VOLUME=""
      ;;
    --sdk-dir=*) SDK_DIR="${1#*=}"; SDK_VOLUME="" ;;
    --source-dir)
      shift
      (($# > 0)) || die "--source-dir requires a value"
      SOURCE_DIR="$1"
      ;;
    --source-dir=*) SOURCE_DIR="${1#*=}" ;;
    --image)
      shift
      (($# > 0)) || die "--image requires a value"
      IMAGE="$1"
      ;;
    --image=*) IMAGE="${1#*=}" ;;
    --run-id)
      shift
      (($# > 0)) || die "--run-id requires a value"
      RUN_ID="$1"
      ;;
    --run-id=*) RUN_ID="${1#*=}" ;;
    --expect-sha256)
      shift
      (($# > 0)) || die "--expect-sha256 requires a value"
      EXPECTED_SHA256="$1"
      ;;
    --expect-sha256=*) EXPECTED_SHA256="${1#*=}" ;;
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

[[ -n "$IMAGE" ]] || die "builder image tag must not be empty"
if [[ -n "$RUN_ID" && ! "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  die "--run-id must contain only letters, numbers, dot, underscore, and dash"
fi
if [[ -n "$EXPECTED_SHA256" && ! "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  die "--expect-sha256 must be 64 lowercase hexadecimal characters"
fi

for required in \
  Dockerfile \
  build-container.sh \
  patches/openai-codex-0.144.1-armv7.patch \
  patches/pagable-0.4.1-armv7.patch \
  patches/seccompiler-0.5.0-armv7.patch; do
  [[ -f "$RECIPE_DIR/$required" ]] || die "missing Codex recipe input: $required"
done
[[ -x "$RECIPE_DIR/build-container.sh" ]] ||
  die "missing executable Codex container build script"
[[ -x "$SDK_FINGERPRINT" ]] ||
  die "missing common ARM SDK fingerprint script"
[[ -f "$SDK_PIN" ]] || die "missing authoritative ARM SDK pin"
bash "$ROOT/tools/build/verify-arm-sdk.sh" --pin-only >/dev/null

recipe_key="$({
  printf 'source-url=%s\n' "$SOURCE_URL"
  printf 'source-tag=%s\n' "$SOURCE_TAG"
  printf 'source-commit=%s\n' "$SOURCE_COMMIT"
  printf 'rust-toolchain=%s\n' "$RUST_TOOLCHAIN"
  printf 'source-date-epoch=%s\n' "$SOURCE_DATE_EPOCH"
  for input in \
    Dockerfile \
    build-container.sh \
    patches/openai-codex-0.144.1-armv7.patch \
    patches/pagable-0.4.1-armv7.patch \
    patches/seccompiler-0.5.0-armv7.patch; do
    printf '%s=%s\n' "$input" "$(sha256_file "$RECIPE_DIR/$input")"
  done
  printf 'fingerprint-arm-sdk.sh=%s\n' "$(sha256_file "$SDK_FINGERPRINT")"
  printf 'arm-sdk.pin=%s\n' "$(sha256_file "$SDK_PIN")"
} | sha256_stdin)"

if [[ -n "$SDK_DIR" ]]; then
  if ((DRY_RUN == 0)); then
    [[ -d "$SDK_DIR" ]] || die "reMarkable SDK directory does not exist: $SDK_DIR"
    SDK_DIR="$(cd "$SDK_DIR" && pwd)"
    [[ -f "$SDK_DIR/environment-setup-cortexa7hf-neon-remarkable-linux-gnueabi" ]] ||
      die "not an installed official reMarkable SDK directory: $SDK_DIR"
  fi
  SDK_MOUNT_SOURCE="$SDK_DIR"
else
  [[ -n "$SDK_VOLUME" ]] || die "select an SDK with --sdk-volume or --sdk-dir"
  SDK_MOUNT_SOURCE="$SDK_VOLUME"
fi

if ((DRY_RUN == 1)); then
  run_id="${RUN_ID:-<automatic-utc-pid>}"
  echo "+ checkout $SOURCE_URL tag $SOURCE_TAG at $SOURCE_COMMIT into clean cache $SOURCE_DIR"
  echo "+ docker build --platform linux/amd64 --build-arg PLUTO_CODEX_RECIPE_DIGEST=$recipe_key --tag $IMAGE $RECIPE_DIR"
  echo "+ fingerprint complete read-only SDK input $SDK_MOUNT_SOURCE:/sdk:ro"
  echo "+ reject SDK unless it matches $SDK_PIN"
  echo "+ create fresh isolated run $BUILD_ROOT/runs/<input-key>/$run_id"
  echo "+ docker run with cargo +$RUST_TOOLCHAIN and fixed /src /cargo-home /target /output mounts"
  echo "+ bash $ROOT/tools/build/verify-device-elf.sh <candidate>/output/codex 2.35 linux-arm"
  exit 0
fi

command -v docker >/dev/null 2>&1 || die "Docker is required"
command -v git >/dev/null 2>&1 || die "Git is required"
docker info >/dev/null 2>&1 || die "Docker daemon is not available"
if [[ -z "$SDK_DIR" ]] && ! docker volume inspect "$SDK_VOLUME" >/dev/null 2>&1; then
  die "official reMarkable SDK Docker volume '$SDK_VOLUME' is not installed"
fi

if [[ ! -e "$SOURCE_DIR" ]]; then
  run install -d "$(dirname "$SOURCE_DIR")"
  run git clone --depth 1 --branch "$SOURCE_TAG" "$SOURCE_URL" "$SOURCE_DIR"
fi
[[ -d "$SOURCE_DIR/.git" ]] || die "source cache is not a Git checkout: $SOURCE_DIR"
[[ "$(git -C "$SOURCE_DIR" remote get-url origin)" = "$SOURCE_URL" ]] ||
  die "Codex source cache origin is not $SOURCE_URL"
[[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = "$SOURCE_COMMIT" ]] ||
  die "Codex source cache is not exact commit $SOURCE_COMMIT"
[[ -z "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=all)" ]] ||
  die "Codex source cache must be clean: $SOURCE_DIR"

if ((SKIP_IMAGE_BUILD == 0)); then
  run docker build \
    --platform linux/amd64 \
    --build-arg "PLUTO_CODEX_RECIPE_DIGEST=$recipe_key" \
    --file "$RECIPE_DIR/Dockerfile" \
    --tag "$IMAGE" \
    "$RECIPE_DIR"
fi

image_id="$(docker image inspect --format '{{.Id}}' "$IMAGE")"
image_arch="$(docker image inspect --format '{{.Architecture}}' "$IMAGE")"
image_recipe_key="$(docker image inspect \
  --format '{{index .Config.Labels "dev.pluto.codex-armv7.recipe-digest"}}' "$IMAGE")"
[[ "$image_arch" = amd64 ]] || die "Codex builder image must be linux/amd64, got $image_arch"
[[ "$image_recipe_key" = "$recipe_key" ]] ||
  die "builder image recipe key mismatch; rebuild without --skip-image-build"

sdk_metadata="$(docker run --rm \
  --platform linux/amd64 \
  --volume "$SDK_MOUNT_SOURCE:/sdk:ro" \
  --volume "$ROOT/tools/build:/pluto-tools:ro" \
  "$IMAGE" \
  bash /pluto-tools/fingerprint-arm-sdk.sh)"
sdk_sha256="$(printf '%s\n' "$sdk_metadata" | sed -n 's/^SDK_SHA256=//p')"
sdk_gcc_version="$(printf '%s\n' "$sdk_metadata" | sed -n 's/^GCC_VERSION=//p')"
sdk_gcc_machine="$(printf '%s\n' "$sdk_metadata" | sed -n 's/^GCC_MACHINE=//p')"
sdk_regular_files="$(printf '%s\n' "$sdk_metadata" | sed -n 's/^SDK_REGULAR_FILES=//p')"
[[ "$sdk_sha256" =~ ^[0-9a-f]{64}$ ]] || die "SDK fingerprint did not return a SHA-256"
[[ "$sdk_sha256" = "$(pin_value sha256)" ]] ||
  die "official SDK content does not match the authoritative pin"
[[ "$sdk_gcc_version" = "$(pin_value gcc_version)" ]] ||
  die "official SDK GCC version does not match the authoritative pin"
[[ "$sdk_gcc_machine" = "$(pin_value gcc_machine)" ]] ||
  die "official SDK machine does not match the authoritative pin"
[[ "$sdk_regular_files" = "$(pin_value regular_files)" ]] ||
  die "official SDK file count does not match the authoritative pin"

input_key="$({
  printf 'recipe-key=%s\n' "$recipe_key"
  printf 'image-id=%s\n' "$image_id"
  printf 'sdk-sha256=%s\n' "$sdk_sha256"
} | sha256_stdin)"

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
RUN_ROOT="$BUILD_ROOT/runs/$input_key/$RUN_ID"
WORK_SOURCE_DIR="$RUN_ROOT/source"
CARGO_HOME_DIR="$RUN_ROOT/cargo-home"
TARGET_DIR="$RUN_ROOT/target"
OUTPUT_DIR="$RUN_ROOT/output"
OUTPUT="$OUTPUT_DIR/codex"

[[ ! -e "$RUN_ROOT" ]] || die "isolated run already exists: $RUN_ROOT"
run install -d "$(dirname "$RUN_ROOT")"
run git clone --quiet --no-hardlinks --no-checkout "$SOURCE_DIR" "$WORK_SOURCE_DIR"
run git -C "$WORK_SOURCE_DIR" checkout --quiet --detach "$SOURCE_COMMIT"
run git -C "$WORK_SOURCE_DIR" remote set-url origin "$SOURCE_URL"
run install -d "$CARGO_HOME_DIR" "$TARGET_DIR" "$OUTPUT_DIR"

{
  printf 'RECIPE_KEY=%s\n' "$recipe_key"
  printf 'INPUT_KEY=%s\n' "$input_key"
  printf 'RUN_ID=%s\n' "$RUN_ID"
  printf 'SOURCE_COMMIT=%s\n' "$SOURCE_COMMIT"
  printf 'SOURCE_DATE_EPOCH=%s\n' "$SOURCE_DATE_EPOCH"
  printf 'RUST_TOOLCHAIN=%s\n' "$RUST_TOOLCHAIN"
  printf 'IMAGE_ID=%s\n' "$image_id"
  printf 'SDK_SHA256=%s\n' "$sdk_sha256"
  printf '%s\n' "$sdk_metadata"
} > "$RUN_ROOT/input-manifest.txt"

DOCKER_RUN=(
  docker run --rm
  --platform linux/amd64
  --user "$(id -u):$(id -g)"
  --env HOME=/tmp
  --env CARGO_HOME=/cargo-home
  --env CARGO_TARGET_DIR=/target
  --env "PLUTO_CODEX_ARMV7_INPUT_KEY=$input_key"
  --env "PLUTO_CODEX_ARMV7_RECIPE_KEY=$recipe_key"
  --env "PLUTO_CODEX_ARMV7_SDK_SHA256=$sdk_sha256"
  --volume "$SDK_MOUNT_SOURCE:/sdk:ro"
  --volume "$WORK_SOURCE_DIR:/src"
  --volume "$CARGO_HOME_DIR:/cargo-home"
  --volume "$TARGET_DIR:/target"
  --volume "$OUTPUT_DIR:/output"
  --volume "$RECIPE_DIR:/pluto-build:ro"
  "$image_id"
  bash /pluto-build/build-container.sh
)
run "${DOCKER_RUN[@]}"

run bash "$ROOT/tools/build/verify-device-elf.sh" "$OUTPUT" 2.35 linux-arm
actual_sha256="$(sha256_file "$OUTPUT")"
if [[ -n "$EXPECTED_SHA256" && "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
  die "Codex candidate SHA-256 mismatch: expected $EXPECTED_SHA256, got $actual_sha256"
fi

install -m 0644 "$WORK_SOURCE_DIR/LICENSE" "$OUTPUT_DIR/LICENSE.openai-codex"
install -m 0644 "$WORK_SOURCE_DIR/NOTICE" "$OUTPUT_DIR/NOTICE.openai-codex"
install -m 0644 "$RECIPE_DIR/PROVENANCE.md" "$OUTPUT_DIR/PROVENANCE.md"

echo "Codex ARMv7 candidate: $OUTPUT"
echo "Input key: $input_key"
echo "Run ID: $RUN_ID"
echo "SHA-256: $actual_sha256"
if [[ "$actual_sha256" = "$CANONICAL_SHA256" ]]; then
  echo "Candidate matches the current device-tested canonical SHA-256."
else
  echo "Canonical output remains unchanged at SHA-256 $CANONICAL_SHA256."
fi
