#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT="$ROOT/build/pluto-release"
DRY_RUN=0
FLUTTER_VERSION="$(tr -d '[:space:]' < "$ROOT/tools/pluto/pins/flutter.version")"
SDK="${PLUTO_SDK:-$HOME/.pluto/sdk/$FLUTTER_VERSION}"
DART="$SDK/bin/cache/dart-sdk/bin/dart"
PACKAGES="$ROOT/tools/pluto/.dart_tool/package_config.json"
MANIFEST_TOOL="$ROOT/tools/pluto/tool/write_release_manifest.dart"
SLICE_WORKER="$ROOT/tools/build/assemble-device-payload.sh"
STAGE=""

usage() {
  cat <<'EOF'
Usage: tools/build/assemble-device-release.sh [options]

Build one universal release set containing the common Pluto app set on
linux-arm and linux-arm64, plus apps whose manifests declare the selected
target. Target compilers and payload workers remain private; the resulting
release manifest freezes one clean Git revision, all toolchain pins, and the
SHA-256 of every file in both self-contained slices.

Options:
  --output DIR  override build/pluto-release
  --dry-run     print the complete two-target build without changing files
  -h, --help    show this help
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

write_revision_receipt() {
  local target="$1"
  local path="$STAGE/targets/$target/share/release-revision"
  print_command write-release-revision "$REVISION" "$path"
  if ((DRY_RUN == 0)); then
    printf '%s\n' "$REVISION" > "$path"
  fi
}

cleanup() {
  if ((DRY_RUN == 0)) && [[ -n "$STAGE" && -e "$STAGE" ]]; then
    rm -rf "$STAGE"
  fi
}
trap cleanup EXIT HUP INT TERM

require_clean_revision() {
  local current_revision
  current_revision="$(git -C "$ROOT" rev-parse --verify HEAD)"
  [[ "$current_revision" == "$REVISION" ]] ||
    die "source HEAD changed during release assembly ($REVISION -> $current_revision)"
  git -C "$ROOT" diff --quiet --ignore-submodules -- ||
    die "tracked source is dirty; commit the exact release revision first"
  git -C "$ROOT" diff --cached --quiet --ignore-submodules -- ||
    die "the index is dirty; commit the exact release revision first"
  [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] ||
    die "the source tree has uncommitted files; freeze one clean revision first"
}

while (($# > 0)); do
  case "$1" in
    --output)
      shift
      (($# > 0)) || die "--output requires a value"
      OUTPUT="${1%/}"
      ;;
    --output=*)
      OUTPUT="${1#*=}"
      OUTPUT="${OUTPUT%/}"
      ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[[ -n "$OUTPUT" ]] || die "output directory must not be empty"
case "$OUTPUT" in
  / | . | .. | */. | */.. | "$ROOT" | "$ROOT/" | "$HOME" | "$HOME/")
    die "refusing unsafe output directory: $OUTPUT"
    ;;
esac

for input in "$SLICE_WORKER" "$MANIFEST_TOOL" "$PACKAGES"; do
  [[ -f "$input" ]] || die "missing release input: $input"
done
[[ -x "$DART" ]] || die "missing pinned Dart SDK; run tools/setup/setup.sh"

REVISION="$(git -C "$ROOT" rev-parse --verify HEAD)"
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve a full Git revision"
if ((DRY_RUN == 0)); then
  require_clean_revision
fi

STAGE="${OUTPUT}.pluto-stage-$$"
OLD="${OUTPUT}.pluto-old-$$"
run rm -rf "$STAGE" "$OLD"
run install -d "$STAGE/targets"

# Both architecture builds are deliberately below this single public command.
if ((DRY_RUN == 1)); then
  run bash "$ROOT/tools/build/embedder-device.sh" --dry-run
  run bash "$ROOT/tools/build/embedder-device-arm.sh" --dry-run
else
  run bash "$ROOT/tools/build/embedder-device.sh"
  run bash "$ROOT/tools/build/embedder-device-arm.sh"
fi

ARM64_ARGS=(
  bash "$SLICE_WORKER"
  --target-platform linux-arm64
  --standard
  --output "$STAGE/targets/linux-arm64"
)
ARM_ARGS=(
  bash "$SLICE_WORKER"
  --target-platform linux-arm
  --standard
  --output "$STAGE/targets/linux-arm"
)
if ((DRY_RUN == 1)); then
  ARM64_ARGS+=(--dry-run)
  ARM_ARGS+=(--dry-run)
fi
run "${ARM64_ARGS[@]}"
run "${ARM_ARGS[@]}"
write_revision_receipt linux-arm64
write_revision_receipt linux-arm

if ((DRY_RUN == 0)); then
  require_clean_revision
fi

run "$DART" --packages="$PACKAGES" "$MANIFEST_TOOL" \
  --release-root "$STAGE" \
  --pins-dir "$ROOT/tools/pluto/pins" \
  --git-revision "$REVISION"

if ((DRY_RUN == 0)); then
  require_clean_revision
  [[ ! -L "$OUTPUT" ]] || die "refusing symlink release output: $OUTPUT"
  if [[ -e "$OUTPUT" ]]; then
    run mv "$OUTPUT" "$OLD"
  fi
  print_command mv "$STAGE" "$OUTPUT"
  if ! mv "$STAGE" "$OUTPUT"; then
    if [[ -e "$OLD" && ! -e "$OUTPUT" ]]; then
      mv "$OLD" "$OUTPUT" || true
    fi
    die "could not atomically promote the universal release"
  fi
  STAGE=""
  run rm -rf "$OLD"
  echo "Assembled universal release: $OUTPUT"
  echo "Revision: $REVISION"
fi

echo "Universal release handoff: pluto provision --payload-dir $OUTPUT"
