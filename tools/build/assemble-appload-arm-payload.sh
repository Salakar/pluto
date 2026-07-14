#!/usr/bin/env bash
set -euo pipefail

# Assemble the ARMv7 release runtime consumed by the unified Pluto provision
# workflow. The device profile owns backend selection and managed app entries.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLUTTER_VERSION="$(tr -d '[:space:]' < "$ROOT/tools/pluto/pins/flutter.version")"
ENGINE_COMMIT="$(tr -d '[:space:]' < "$ROOT/tools/pluto/pins/engine.version")"
ENGINE_DIR="$ROOT/third_party/engine/$ENGINE_COMMIT/linux-arm-release"
ENGINE="$ENGINE_DIR/libflutter_engine.so"
ICU_DATA="$ENGINE_DIR/icudtl.dat"
EMBEDDER="$ROOT/embedder/build/device-arm/pluto-embedder"
CONTROL_CLIENT="$ROOT/embedder/build/device-arm/pluto-apploadctl"
CONTROL_CLIENT_EXPLICIT=0
CODEX_BIN="$ROOT/.pluto-cache/build/codex-armv7/output/codex"
XOVI_SOURCE="$ROOT/.pluto-cache/xovi/arm32-v19/xovi"
XOVI_SOURCE_EXPLICIT=0
APPLOAD_EXTENSION_327="$ROOT/.pluto-cache/build/appload-pluto-control-3.27-arm32/appload.so"
APPLOAD_EXTENSION_327_EXPLICIT=0
APPLOAD_EXTENSION_328="$ROOT/.pluto-cache/build/appload-pluto-control-arm32/appload.so"
APPLOAD_EXTENSION_328_EXPLICIT=0
APPLOAD_SHIMS="$ROOT/.pluto-cache/xovi/appload-arm32-v0.5.3/shims"
APPLOAD_SHIMS_EXPLICIT=0
QRR_HASHTAB_327="$ROOT/.pluto-cache/evidence/rm1-3.27-hashtab"
QRR_HASHTAB_328="$ROOT/.pluto-cache/evidence/rm2-3.28-hashtab"
OUTPUT="$ROOT/build/pluto-appload-arm"
ARCHIVE=""
ARCHIVE_EXPLICIT=0
DRY_RUN=0
CANDIDATE_INTEGRATION=0

LAUNCHER_LAYOUT="$ROOT/apps/launcher/build/pluto/release-arm"
INK_LAYOUT="$ROOT/apps/ink/build/pluto/release-arm"
CODEX_LAYOUT="$ROOT/apps/codex/build/pluto/release-arm"

readonly PAYLOAD_RUNTIME=/home/root/pluto-arm
readonly DEVICE_RUNTIME=/home/root/pluto
readonly DEVICE_CODEX_BIN="$DEVICE_RUNTIME/bin/codex"
readonly TARGET_PLATFORM=linux-arm
readonly GLIBC_CEILING=2.35
readonly CODEX_VERSION=0.144.1
readonly CODEX_SHA256=df8b6673f48b10356a7cee64b405c14435401a083f5e04ee147f0bd7b6760bdf
readonly FINAL_XOVI_SHA256=2878d88da2dcb37dcf5533fa78aeeb5cc933eb8c7e5b9041213a4e135a7fff14
readonly FINAL_QRR_SHA256=3850e3ceca1a22dd19d0ded854719c45cf553415f909e3cf5aa0e17efab2dbac
readonly FINAL_QTFB_SHIM_32_SHA256=19a9d2c75741113f37f81f7affead40eeb12fa3cc41109b7f41ba154f60799cc
readonly FINAL_QTFB_SHIM_SHA256=4eab5f8f54d5fbaaba86497128b3b5029dc07033ac9dd499a226638cc255e9d2
readonly FINAL_APPLOAD_327_SHA256=16687c359c96720c631362c5aa902be737cf1ad4b5f37c37c0c18d6a29812377
readonly FINAL_APPLOAD_328_SHA256=5539cb400d3ce782214eefa7b2e65e8e69fc27817aacd8c067319a4a14dc4b9d
readonly FINAL_CONTROL_CLIENT_SHA256=dd8e30c09b36f301046d91e8b8db5ca7f15219e5aeec33b0a468e4b3250cee63
readonly QRR_HASHTAB_327_SHA256=01c294ff28a21336814d657e27c5de2c83a8ad0e03b143e9cef6216dacfefc86
readonly QRR_HASHTAB_328_SHA256=b64584f7cd0520be6abe984a6b4c9c0b4ebcead56b66a11c9a96a41139421db6

usage() {
  cat <<'EOF'
Usage: tools/build/assemble-appload-arm-payload.sh [options]

Validate and assemble the existing RM1/RM2 ARMv7 release-AOT layouts for
Pluto Home, Ink, and Paper Codex into build/pluto-appload-arm. The result is
a validated provision input tree plus a tar archive; this command never
contacts a device and does not itself provision or select a display backend.

Options:
  --embedder PATH         ARMv7 pluto-embedder (default:
                          embedder/build/device-arm/pluto-embedder)
  --control-client PATH   ARMv7 AppLoad control client (default:
                          embedder/build/device-arm/pluto-apploadctl)
  --codex-bin PATH        pinned ARMv7 Codex CLI release input (default:
                          .pluto-cache/build/codex-armv7/output/codex)
  --xovi-root PATH        XOVI v0.3.3 + QRR v19 source tree
  --appload-extension-3.27 PATH
                          control-enabled AppLoad for firmware 3.27.3.0
  --appload-extension-3.28 PATH
                          control-enabled AppLoad for firmware 3.28.0.162
  --appload-shims PATH    directory with both ARMv7 QTFB shim libraries
  --candidate-integration allow an explicit --xovi-root or --appload-shims to
                          differ from device-accepted hashes for deliberate
                          candidate testing; hashes are reported and every ELF
                          still passes architecture and ABI validation
  --qrr-hashtab-3.27 PATH validated QRR hashtab for firmware 3.27.3.0
  --qrr-hashtab-3.28 PATH validated QRR hashtab for firmware 3.28.0.162
  --launcher-layout PATH  existing linux-arm release layout for Pluto Home
  --ink-layout PATH       existing linux-arm release layout for Ink
  --codex-layout PATH     existing linux-arm release layout for Paper Codex
  --output DIR            rootfs staging directory (default:
                          build/pluto-appload-arm)
  --archive PATH          tar path (default: <output>.tar)
  --no-archive            assemble only the deployable directory
  --dry-run               print the plan without validating or writing files
  -h, --help              show this help

The tree stages the target runtime under /home/root/pluto-arm for `pluto
provision` to validate and promote to /home/root/pluto. Managed AppLoad entries
are generated by the provisioner, not embedded here. The SHA-pinned Codex CLI
is promoted to /home/root/pluto/bin/codex; authentication remains user-managed.
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

create_root_owned_archive() {
  local source_root="$1"
  local destination="$2"
  local tar_version

  tar_version="$(LC_ALL=C tar --version 2>/dev/null || true)"
  case "$tar_version" in
    bsdtar*)
      LC_ALL=C COPYFILE_DISABLE=1 tar \
        --uid 0 --gid 0 --uname root --gname root \
        -C "$source_root" -cf "$destination" home
      ;;
    *"GNU tar"*)
      LC_ALL=C tar \
        --owner=0 --group=0 --numeric-owner \
        -C "$source_root" -cf "$destination" home
      ;;
    *)
      die "unsupported tar implementation; root-owned archives require bsdtar or GNU tar"
      ;;
  esac
}

while (($# > 0)); do
  case "$1" in
    --embedder)
      shift
      (($# > 0)) || die "--embedder requires a value"
      EMBEDDER="$1"
      ;;
    --embedder=*) EMBEDDER="${1#*=}" ;;
    --control-client)
      shift
      (($# > 0)) || die "--control-client requires a value"
      CONTROL_CLIENT="$1"
      CONTROL_CLIENT_EXPLICIT=1
      ;;
    --control-client=*) CONTROL_CLIENT="${1#*=}"; CONTROL_CLIENT_EXPLICIT=1 ;;
    --codex-bin)
      shift
      (($# > 0)) || die "--codex-bin requires a value"
      CODEX_BIN="$1"
      ;;
    --codex-bin=*) CODEX_BIN="${1#*=}" ;;
    --xovi-root)
      shift
      (($# > 0)) || die "--xovi-root requires a value"
      XOVI_SOURCE="${1%/}"
      XOVI_SOURCE_EXPLICIT=1
      ;;
    --xovi-root=*)
      XOVI_SOURCE="${1#*=}"
      XOVI_SOURCE="${XOVI_SOURCE%/}"
      XOVI_SOURCE_EXPLICIT=1
      ;;
    --appload-extension-3.27)
      shift
      (($# > 0)) || die "--appload-extension-3.27 requires a value"
      APPLOAD_EXTENSION_327="$1"
      APPLOAD_EXTENSION_327_EXPLICIT=1
      ;;
    --appload-extension-3.27=*) APPLOAD_EXTENSION_327="${1#*=}"; APPLOAD_EXTENSION_327_EXPLICIT=1 ;;
    --appload-extension-3.28)
      shift
      (($# > 0)) || die "--appload-extension-3.28 requires a value"
      APPLOAD_EXTENSION_328="$1"
      APPLOAD_EXTENSION_328_EXPLICIT=1
      ;;
    --appload-extension-3.28=*) APPLOAD_EXTENSION_328="${1#*=}"; APPLOAD_EXTENSION_328_EXPLICIT=1 ;;
    --appload-shims)
      shift
      (($# > 0)) || die "--appload-shims requires a value"
      APPLOAD_SHIMS="${1%/}"
      APPLOAD_SHIMS_EXPLICIT=1
      ;;
    --appload-shims=*)
      APPLOAD_SHIMS="${1#*=}"
      APPLOAD_SHIMS="${APPLOAD_SHIMS%/}"
      APPLOAD_SHIMS_EXPLICIT=1
      ;;
    --qrr-hashtab-3.27)
      shift
      (($# > 0)) || die "--qrr-hashtab-3.27 requires a value"
      QRR_HASHTAB_327="$1"
      ;;
    --qrr-hashtab-3.27=*) QRR_HASHTAB_327="${1#*=}" ;;
    --qrr-hashtab-3.28)
      shift
      (($# > 0)) || die "--qrr-hashtab-3.28 requires a value"
      QRR_HASHTAB_328="$1"
      ;;
    --qrr-hashtab-3.28=*) QRR_HASHTAB_328="${1#*=}" ;;
    --launcher-layout)
      shift
      (($# > 0)) || die "--launcher-layout requires a value"
      LAUNCHER_LAYOUT="$1"
      ;;
    --launcher-layout=*) LAUNCHER_LAYOUT="${1#*=}" ;;
    --ink-layout)
      shift
      (($# > 0)) || die "--ink-layout requires a value"
      INK_LAYOUT="$1"
      ;;
    --ink-layout=*) INK_LAYOUT="${1#*=}" ;;
    --codex-layout)
      shift
      (($# > 0)) || die "--codex-layout requires a value"
      CODEX_LAYOUT="$1"
      ;;
    --codex-layout=*) CODEX_LAYOUT="${1#*=}" ;;
    --output)
      shift
      (($# > 0)) || die "--output requires a value"
      OUTPUT="${1%/}"
      ;;
    --output=*) OUTPUT="${1#*=}"; OUTPUT="${OUTPUT%/}" ;;
    --archive)
      shift
      (($# > 0)) || die "--archive requires a value"
      ARCHIVE="$1"
      ARCHIVE_EXPLICIT=1
      ;;
    --archive=*) ARCHIVE="${1#*=}"; ARCHIVE_EXPLICIT=1 ;;
    --no-archive) ARCHIVE_EXPLICIT=1; ARCHIVE="" ;;
    --candidate-integration) CANDIDATE_INTEGRATION=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

if ((CANDIDATE_INTEGRATION == 1 &&
  XOVI_SOURCE_EXPLICIT == 0 && APPLOAD_SHIMS_EXPLICIT == 0)); then
  die "--candidate-integration requires --xovi-root or --appload-shims"
fi

[[ -n "$OUTPUT" ]] || die "output directory must not be empty"
case "$OUTPUT" in
  / | . | .. | */. | */.. | "$ROOT" | "$ROOT/" | "$HOME" | "$HOME/")
    die "refusing unsafe output directory: $OUTPUT"
    ;;
esac
if ((ARCHIVE_EXPLICIT == 0)); then
  ARCHIVE="$OUTPUT.tar"
fi
if [[ -n "$ARCHIVE" ]]; then
  case "$ARCHIVE" in
    "$OUTPUT" | "$OUTPUT"/*)
      die "archive must be outside the assembled output tree: $ARCHIVE"
      ;;
  esac
fi

APP_IDS=(dev.pluto.launcher dev.pluto.ink dev.pluto.codex)
APP_LAYOUTS=("$LAUNCHER_LAYOUT" "$INK_LAYOUT" "$CODEX_LAYOUT")

require_arm_elf() {
  local elf="$1"
  local label="$2"
  local description
  local elf_class
  local machine_lo
  local machine_hi
  local machine
  local flag_0
  local flag_1
  local flag_2
  local flag_3
  local flags

  [[ -s "$elf" ]] || die "missing $label ELF: $elf"
  description="$(file "$elf")"
  elf_class="$(od -An -tu1 -j4 -N1 "$elf" | tr -d '[:space:]')"
  read -r machine_lo machine_hi <<<"$(od -An -tu1 -j18 -N2 "$elf")"
  machine=$((machine_lo | (machine_hi << 8)))
  read -r flag_0 flag_1 flag_2 flag_3 <<<"$(od -An -tu1 -j36 -N4 "$elf")"
  flags=$((flag_0 | (flag_1 << 8) | (flag_2 << 16) | (flag_3 << 24)))

  [[ "$elf_class" -eq 1 && "$machine" -eq 40 ]] ||
    die "$label must be ELF32 EM_ARM: $description"
  [[ $(((flags >> 24) & 0xff)) -eq 5 ]] ||
    die "$label must use ARM EABI5: $description"
  (( (flags & 0x400) != 0 && (flags & 0x200) == 0 )) ||
    die "$label must use the ARM hard-float ABI: $description"
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    LC_ALL=C LANG=C shasum -a 256 "$path" | awk '{print $1}'
  fi
}

require_sha256() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual="$(sha256_file "$path")"
  [[ "$actual" = "$expected" ]] ||
    die "$label SHA-256 mismatch: expected $expected, got $actual"
}

validate_integration_hash_policy() {
  local xovi="$XOVI_SOURCE/xovi.so"
  local qrr="$XOVI_SOURCE/extensions.d/qt-resource-rebuilder.so"
  local shim32="$APPLOAD_SHIMS/qtfb-shim-32bit.so"
  local shim="$APPLOAD_SHIMS/qtfb-shim.so"

  if ((CANDIDATE_INTEGRATION == 1 && XOVI_SOURCE_EXPLICIT == 1)); then
    echo "Explicit unaccepted XOVI/QRR candidate: $XOVI_SOURCE"
    echo "  XOVI SHA-256: $(sha256_file "$xovi")"
    echo "  QRR SHA-256: $(sha256_file "$qrr")"
  else
    require_sha256 "$xovi" "$FINAL_XOVI_SHA256" \
      "device-accepted XOVI runtime"
    require_sha256 "$qrr" "$FINAL_QRR_SHA256" \
      "device-accepted Qt resource rebuilder"
  fi

  if ((CANDIDATE_INTEGRATION == 1 && APPLOAD_SHIMS_EXPLICIT == 1)); then
    echo "Explicit unaccepted QTFB shim candidate: $APPLOAD_SHIMS"
    echo "  qtfb-shim-32bit.so SHA-256: $(sha256_file "$shim32")"
    echo "  qtfb-shim.so SHA-256: $(sha256_file "$shim")"
  else
    require_sha256 "$shim32" "$FINAL_QTFB_SHIM_32_SHA256" \
      "device-accepted 32-bit QTFB shim"
    require_sha256 "$shim" "$FINAL_QTFB_SHIM_SHA256" \
      "device-accepted QTFB shim"
  fi
}

validate_integration_source() {
  local qrr="$XOVI_SOURCE/extensions.d/qt-resource-rebuilder.so"
  local shim32="$APPLOAD_SHIMS/qtfb-shim-32bit.so"
  local shim="$APPLOAD_SHIMS/qtfb-shim.so"
  local required

  for required in \
    "$XOVI_SOURCE/start" \
    "$XOVI_SOURCE/stock" \
    "$XOVI_SOURCE/debug" \
    "$XOVI_SOURCE/rebuild_hashtable" \
    "$XOVI_SOURCE/services/xochitl.service/qt-resource-rebuilder.conf" \
    "$XOVI_SOURCE/scripts/debug/qt-resource-rebuilder.sh"; do
    [[ -f "$required" && ! -L "$required" ]] ||
      die "missing regular XOVI integration file: $required"
  done
  require_arm_elf "$XOVI_SOURCE/xovi.so" "XOVI runtime"
  require_arm_elf "$qrr" "Qt resource rebuilder"
  require_arm_elf "$APPLOAD_EXTENSION_327" "Pluto AppLoad 3.27 extension"
  require_arm_elf "$APPLOAD_EXTENSION_328" "Pluto AppLoad 3.28 extension"
  require_arm_elf "$shim32" "AppLoad 32-bit QTFB shim"
  require_arm_elf "$shim" "AppLoad QTFB shim"
  [[ -s "$QRR_HASHTAB_327" ]] ||
    die "missing QRR 3.27 hashtab: $QRR_HASHTAB_327"
  [[ -s "$QRR_HASHTAB_328" ]] ||
    die "missing QRR 3.28 hashtab: $QRR_HASHTAB_328"
}

assemble_integration() {
  local destination="$1"
  local xovi="$destination/xovi"
  local profiles="$destination/profiles"
  local checksums="$destination/CHECKSUMS.txt"
  local relative
  local files=(
    xovi.so
    start
    stock
    debug
    rebuild_hashtable
    extensions.d/qt-resource-rebuilder.so
    services/xochitl.service/qt-resource-rebuilder.conf
    scripts/debug/qt-resource-rebuilder.sh
    bin/pluto-apploadctl
    exthome/appload/shims/qtfb-shim-32bit.so
    exthome/appload/shims/qtfb-shim.so
  )

  install -d \
    "$xovi/extensions.d" \
    "$xovi/exthome/appload/shims" \
    "$xovi/exthome/qt-resource-rebuilder" \
    "$xovi/services/xochitl.service" \
    "$xovi/scripts/debug" \
    "$xovi/scripts/pre-start" \
    "$xovi/scripts/post-start" \
    "$xovi/scripts/pre-stock" \
    "$xovi/scripts/post-stock" \
    "$xovi/bin" \
    "$profiles/3.27.3.0" \
    "$profiles/3.28.0.162"
  install -m 0644 "$XOVI_SOURCE/xovi.so" "$xovi/xovi.so"
  install -m 0755 "$XOVI_SOURCE/start" "$xovi/start"
  install -m 0755 "$XOVI_SOURCE/stock" "$xovi/stock"
  install -m 0755 "$XOVI_SOURCE/debug" "$xovi/debug"
  install -m 0755 "$XOVI_SOURCE/rebuild_hashtable" "$xovi/rebuild_hashtable"
  install -m 0644 \
    "$XOVI_SOURCE/extensions.d/qt-resource-rebuilder.so" \
    "$xovi/extensions.d/qt-resource-rebuilder.so"
  install -m 0644 \
    "$APPLOAD_EXTENSION_327" "$profiles/3.27.3.0/appload.so"
  install -m 0644 \
    "$APPLOAD_EXTENSION_328" "$profiles/3.28.0.162/appload.so"
  install -m 0644 "$QRR_HASHTAB_327" "$profiles/3.27.3.0/hashtab"
  install -m 0644 "$QRR_HASHTAB_328" "$profiles/3.28.0.162/hashtab"
  install -m 0644 \
    "$XOVI_SOURCE/services/xochitl.service/qt-resource-rebuilder.conf" \
    "$xovi/services/xochitl.service/qt-resource-rebuilder.conf"
  install -m 0755 \
    "$XOVI_SOURCE/scripts/debug/qt-resource-rebuilder.sh" \
    "$xovi/scripts/debug/qt-resource-rebuilder.sh"
  install -m 0755 "$CONTROL_CLIENT" "$xovi/bin/pluto-apploadctl"
  install -m 0644 \
    "$APPLOAD_SHIMS/qtfb-shim-32bit.so" \
    "$xovi/exthome/appload/shims/qtfb-shim-32bit.so"
  install -m 0644 \
    "$APPLOAD_SHIMS/qtfb-shim.so" \
    "$xovi/exthome/appload/shims/qtfb-shim.so"
  ln -s /home/root/xovi/extensions.d \
    "$xovi/services/xochitl.service/extensions.d"
  ln -s /home/root/xovi/exthome \
    "$xovi/services/xochitl.service/exthome"

  cat > "$checksums" <<EOF
schema=1
target=linux-arm
xovi=0.3.3
qrr=v19
apploadControlProtocol=1
hashtab=profile-matched
firmwareProfiles=3.27.3.0,3.28.0.162

EOF
  for relative in "${files[@]}"; do
    printf '%s  %s\n' "$(sha256_file "$xovi/$relative")" "$relative" \
      >> "$checksums"
  done
  printf '%s  %s\n' \
    "$(sha256_file "$profiles/3.27.3.0/appload.so")" \
    profiles/3.27.3.0/appload.so >> "$checksums"
  printf '%s  %s\n' \
    "$(sha256_file "$profiles/3.28.0.162/appload.so")" \
    profiles/3.28.0.162/appload.so >> "$checksums"
  printf '%s  %s\n' \
    "$QRR_HASHTAB_327_SHA256" \
    profiles/3.27.3.0/hashtab >> "$checksums"
  printf '%s  %s\n' \
    "$QRR_HASHTAB_328_SHA256" \
    profiles/3.28.0.162/hashtab >> "$checksums"
  cat >> "$checksums" <<'EOF'
link services/xochitl.service/extensions.d /home/root/xovi/extensions.d
link services/xochitl.service/exthome /home/root/xovi/exthome
EOF
}

verify_layout() {
  local layout="$1"
  local expected_id="$2"
  local metadata="$layout/build-metadata.json"
  local manifest="$layout/manifest.json"
  local app_elf="$layout/bundle/lib/app.so"
  local kernel

  [[ -s "$metadata" ]] || die "layout has no build-metadata.json: $layout"
  [[ -s "$manifest" ]] || die "layout has no manifest.json: $layout"
  [[ -d "$layout/bundle/flutter_assets" ]] ||
    die "layout has no Flutter assets: $layout"
  [[ -s "$layout/bundle/icudtl.dat" ]] ||
    die "layout has no ICU data: $layout"
  [[ -s "$layout/assets/pluto/icon.png" ]] ||
    die "layout has no AppLoad icon: $layout/assets/pluto/icon.png"
  require_arm_elf "$app_elf" "$expected_id app.so"

  grep -Eq '"schema"[[:space:]]*:[[:space:]]*1[[:space:]]*[,}]' "$metadata" ||
    die "layout metadata schema is not 1: $metadata"
  grep -Eq '"buildMode"[[:space:]]*:[[:space:]]*"release"' "$metadata" ||
    die "layout is not release: $metadata"
  grep -Eq '"engineFlavor"[[:space:]]*:[[:space:]]*"release"' "$metadata" ||
    die "layout does not require the release engine: $metadata"
  grep -Eq '"target"[[:space:]]*:[[:space:]]*"linux-arm"' "$metadata" ||
    die "layout target is not linux-arm: $metadata"
  grep -Eq "\"flutterVersion\"[[:space:]]*:[[:space:]]*\"$FLUTTER_VERSION\"" "$metadata" ||
    die "layout Flutter pin is not $FLUTTER_VERSION: $metadata"
  grep -Eq "\"engineCommit\"[[:space:]]*:[[:space:]]*\"$ENGINE_COMMIT\"" "$metadata" ||
    die "layout engine pin is not $ENGINE_COMMIT: $metadata"
  grep -Eq '"runtime"[[:space:]]*:[[:space:]]*\{[[:space:]]*"type"[[:space:]]*:[[:space:]]*"flutter-aot"' "$manifest" ||
    die "layout runtime is not flutter-aot: $manifest"
  grep -Eq "\"id\"[[:space:]]*:[[:space:]]*\"$expected_id\"" "$manifest" ||
    die "layout manifest id is not $expected_id: $manifest"
  grep -Eq '"appElf"[[:space:]]*:[[:space:]]*"lib/app\.so"' "$manifest" ||
    die "layout manifest does not select bundle/lib/app.so: $manifest"
  grep -Eq '"assets"[[:space:]]*:[[:space:]]*"flutter_assets"' "$manifest" ||
    die "layout manifest does not select flutter_assets: $manifest"
  grep -Eq "\"flutterVersion\"[[:space:]]*:[[:space:]]*\"$FLUTTER_VERSION\"" "$manifest" ||
    die "layout manifest Flutter pin is not $FLUTTER_VERSION: $manifest"
  grep -Eq "\"engineCommit\"[[:space:]]*:[[:space:]]*\"$ENGINE_COMMIT\"" "$manifest" ||
    die "layout manifest engine pin is not $ENGINE_COMMIT: $manifest"
  strings "$app_elf" |
    grep -E 'product .*dedup_instructions .* arm linux' >/dev/null ||
    die "app.so is not an ARM release/product AOT snapshot: $app_elf"
  if objdump -T "$app_elf" 2>/dev/null |
      grep -Eq 'GLIBC(_|XX_)|CXXABI_'; then
    die "Dart AOT app.so unexpectedly imports a host C/C++ ABI: $app_elf"
  fi

  # Dart AOT app.so exports snapshot data and has no libc ABI imports, so it
  # cannot pass verify-device-elf.sh's intentional GLIBC-import requirement.
  # Its architecture/ABI and product marker are checked directly above; the
  # dynamically linked embedder and engine use the full verifier below.
  kernel="$(find "$layout" -type f -name kernel_blob.bin -print -quit)"
  [[ -z "$kernel" ]] || die "release layout contains a JIT kernel: $kernel"
  [[ ! -e "$layout/bundle/flutter_assets/.last_build_id" ]] ||
    die "release layout contains Flutter build-only metadata: $layout"
  cmp -s "$layout/bundle/icudtl.dat" "$ICU_DATA" ||
    die "layout ICU data does not match the exact engine pin: $layout"
}

if ((DRY_RUN == 1)); then
  print_command bash "$ROOT/tools/build/verify-device-elf.sh" \
    "$EMBEDDER" "$GLIBC_CEILING" "$TARGET_PLATFORM"
  print_command bash "$ROOT/tools/build/verify-device-elf.sh" \
    "$CONTROL_CLIENT" "$GLIBC_CEILING" "$TARGET_PLATFORM"
  print_command bash "$ROOT/tools/build/verify-device-elf.sh" \
    "$ENGINE" "$GLIBC_CEILING" "$TARGET_PLATFORM"
  print_command bash "$ROOT/tools/build/verify-device-elf.sh" \
    "$CODEX_BIN" "$GLIBC_CEILING" "$TARGET_PLATFORM"
  echo "+ validate Codex CLI $CODEX_VERSION SHA-256 $CODEX_SHA256"
  if ((CANDIDATE_INTEGRATION == 1 && XOVI_SOURCE_EXPLICIT == 1)); then
    echo "+ validate explicit unaccepted XOVI/QRR candidate $XOVI_SOURCE"
  else
    echo "+ require device-accepted XOVI SHA-256 $FINAL_XOVI_SHA256"
    echo "+ require device-accepted QRR SHA-256 $FINAL_QRR_SHA256"
  fi
  if ((CANDIDATE_INTEGRATION == 1 && APPLOAD_SHIMS_EXPLICIT == 1)); then
    echo "+ validate explicit unaccepted QTFB shim candidate $APPLOAD_SHIMS"
  else
    echo "+ require device-accepted 32-bit QTFB shim SHA-256 $FINAL_QTFB_SHIM_32_SHA256"
    echo "+ require device-accepted QTFB shim SHA-256 $FINAL_QTFB_SHIM_SHA256"
  fi
  echo "+ validate QRR 3.27 hashtab SHA-256 $QRR_HASHTAB_327_SHA256"
  echo "+ validate QRR 3.28 hashtab SHA-256 $QRR_HASHTAB_328_SHA256"
  for index in 0 1 2; do
    echo "+ validate ${APP_LAYOUTS[$index]} as ${APP_IDS[$index]} release/product linux-arm AOT"
  done
  echo "+ assemble rootfs $OUTPUT"
  echo "+ stage shared runtime $PAYLOAD_RUNTIME for $DEVICE_RUNTIME"
  echo "+ install Codex CLI $DEVICE_CODEX_BIN"
  if [[ -n "$ARCHIVE" ]]; then
    print_command tar -C "$OUTPUT" -cf "$ARCHIVE" home
  fi
  echo "No device contacted. Deploy through the unified Pluto provision workflow."
  exit 0
fi

for tool in cmp file find grep install mktemp mv objdump od strings tar; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

# Reuse setup's checksum-manifest parser without requiring a Flutter SDK: this
# assembler consumes completed layouts and must only authenticate the committed
# exact-pin engine artifacts.
# shellcheck source=../setup/setup.sh
source "$ROOT/tools/setup/setup.sh"
validate_engine_artifacts \
  "$ENGINE_DIR" "$FLUTTER_VERSION" "$ENGINE_COMMIT" release linux-arm

bash "$ROOT/tools/build/verify-device-elf.sh" \
  "$EMBEDDER" "$GLIBC_CEILING" "$TARGET_PLATFORM"
bash "$ROOT/tools/build/verify-device-elf.sh" \
  "$CONTROL_CLIENT" "$GLIBC_CEILING" "$TARGET_PLATFORM"
bash "$ROOT/tools/build/verify-device-elf.sh" \
  "$ENGINE" "$GLIBC_CEILING" "$TARGET_PLATFORM"
bash "$ROOT/tools/build/verify-device-elf.sh" \
  "$CODEX_BIN" "$GLIBC_CEILING" "$TARGET_PLATFORM"
CODEX_ACTUAL_SHA256="$(sha256_file "$CODEX_BIN")"
[[ "$CODEX_ACTUAL_SHA256" = "$CODEX_SHA256" ]] ||
  die "Codex CLI SHA-256 mismatch: expected $CODEX_SHA256, got $CODEX_ACTUAL_SHA256"
LC_ALL=C grep -aF -m 1 "$CODEX_VERSION" "$CODEX_BIN" >/dev/null ||
  die "Codex CLI does not contain pinned version $CODEX_VERSION: $CODEX_BIN"
validate_integration_source
validate_integration_hash_policy
[[ "$(sha256_file "$QRR_HASHTAB_327")" = "$QRR_HASHTAB_327_SHA256" ]] ||
  die "QRR 3.27 hashtab does not match the device-validated SHA-256"
[[ "$(sha256_file "$QRR_HASHTAB_328")" = "$QRR_HASHTAB_328_SHA256" ]] ||
  die "QRR 3.28 hashtab does not match the device-validated SHA-256"
if ((APPLOAD_EXTENSION_327_EXPLICIT == 0)); then
  [[ "$(sha256_file "$APPLOAD_EXTENSION_327")" = \
    "$FINAL_APPLOAD_327_SHA256" ]] ||
    die "default AppLoad 3.27 extension is not the device-validated build"
fi
if ((APPLOAD_EXTENSION_328_EXPLICIT == 0)); then
  [[ "$(sha256_file "$APPLOAD_EXTENSION_328")" = \
    "$FINAL_APPLOAD_328_SHA256" ]] ||
    die "default AppLoad extension is not the final device-validated build"
fi
if ((CONTROL_CLIENT_EXPLICIT == 0)); then
  [[ "$(sha256_file "$CONTROL_CLIENT")" = "$FINAL_CONTROL_CLIENT_SHA256" ]] ||
    die "default AppLoad control client is not the final matched build"
fi
for integration_elf in \
  "$XOVI_SOURCE/xovi.so" \
  "$XOVI_SOURCE/extensions.d/qt-resource-rebuilder.so" \
  "$APPLOAD_EXTENSION_327" \
  "$APPLOAD_EXTENSION_328" \
  "$APPLOAD_SHIMS/qtfb-shim-32bit.so" \
  "$APPLOAD_SHIMS/qtfb-shim.so"; do
  bash "$ROOT/tools/build/verify-device-elf.sh" \
    "$integration_elf" "$GLIBC_CEILING" "$TARGET_PLATFORM"
done
if ((CANDIDATE_INTEGRATION == 1)); then
  echo "Explicit integration candidate passed ARM architecture and ABI gates."
  echo "It is not a device-accepted release default and was not promoted."
fi

for index in 0 1 2; do
  verify_layout "${APP_LAYOUTS[$index]}" "${APP_IDS[$index]}"
done

OUTPUT_PARENT="$(dirname "$OUTPUT")"
OUTPUT_BASENAME="$(basename "$OUTPUT")"
install -d "$OUTPUT_PARENT"
STAGING="$(mktemp -d "$OUTPUT_PARENT/.${OUTPUT_BASENAME}.XXXXXX")"
ARCHIVE_TMP=""
cleanup() {
  [[ -z "${STAGING:-}" || ! -d "$STAGING" ]] || rm -rf "$STAGING"
  [[ -z "${ARCHIVE_TMP:-}" || ! -e "$ARCHIVE_TMP" ]] || rm -f "$ARCHIVE_TMP"
}
trap cleanup EXIT HUP INT TERM

RUNTIME_ROOT="$STAGING$PAYLOAD_RUNTIME"
install -d \
  "$RUNTIME_ROOT/bin" \
  "$RUNTIME_ROOT/engine/release" \
  "$RUNTIME_ROOT/apps"
install -m 0755 "$EMBEDDER" "$RUNTIME_ROOT/bin/pluto-embedder"
install -m 0755 "$CONTROL_CLIENT" "$RUNTIME_ROOT/bin/pluto-apploadctl"
install -m 0755 "$CODEX_BIN" "$RUNTIME_ROOT/bin/codex"
install -m 0644 "$ENGINE" "$RUNTIME_ROOT/engine/release/libflutter_engine.so"
install -m 0644 "$ICU_DATA" "$RUNTIME_ROOT/engine/release/icudtl.dat"
assemble_integration "$RUNTIME_ROOT/integration"

for index in 0 1 2; do
  app_id="${APP_IDS[$index]}"
  layout="${APP_LAYOUTS[$index]}"
  app_destination="$RUNTIME_ROOT/apps/$app_id"

  install -d "$app_destination"
  cp -R "$layout/." "$app_destination/"
done

cat > "$RUNTIME_ROOT/COOPERATIVE-PAYLOAD.json" <<EOF
{
  "schema": 1,
  "target": "linux-arm",
  "mode": "release",
  "flutterVersion": "$FLUTTER_VERSION",
  "engineCommit": "$ENGINE_COMMIT",
  "runtimeRoot": "$DEVICE_RUNTIME",
  "displayOwnership": "xochitl-qtfb-cooperative",
  "apps": [
    "dev.pluto.launcher",
    "dev.pluto.ink",
    "dev.pluto.codex"
  ],
  "codex": {
    "version": "$CODEX_VERSION",
    "sha256": "$CODEX_ACTUAL_SHA256",
    "path": "$DEVICE_CODEX_BIN",
    "authentication": "user-managed"
  },
  "cleanupPaths": [
    "$DEVICE_RUNTIME"
  ]
}
EOF

cat > "$STAGING/DEPLOY.txt" <<EOF
Pluto cooperative ARMv7 rootfs payload

This is an internal release payload. Review it, then deploy it through Pluto's
unified provision workflow; the device profile selects the integration backend.

Payload source: $PAYLOAD_RUNTIME
Device runtime: $DEVICE_RUNTIME
Managed app entries are generated transactionally by pluto provision.

Paper Codex uses the included Codex CLI $CODEX_VERSION at $DEVICE_CODEX_BIN.
The binary is release-pinned by SHA-256; authentication stays user-managed.
EOF

for index in 0 1 2; do
  verify_layout \
    "$RUNTIME_ROOT/apps/${APP_IDS[$index]}" "${APP_IDS[$index]}"
done
for forbidden in kernel_blob.bin; do
  found="$(find "$STAGING" -type f -name "$forbidden" -print -quit)"
  [[ -z "$found" ]] || die "assembled payload contains forbidden file: $found"
done
found="$(find "$STAGING" -type f -name external.manifest.json -print -quit)"
[[ -z "$found" ]] ||
  die "payload must not embed unmanaged AppLoad manifest: $found"
cmp -s "$CODEX_BIN" "$RUNTIME_ROOT/bin/codex" ||
  die "packaged Codex CLI differs from the SHA-pinned release input"

rm -rf "$OUTPUT"
mv "$STAGING" "$OUTPUT"
STAGING=""

if [[ -n "$ARCHIVE" ]]; then
  install -d "$(dirname "$ARCHIVE")"
  ARCHIVE_TMP="$ARCHIVE.tmp.$$"
  rm -f "$ARCHIVE_TMP"
  create_root_owned_archive "$OUTPUT" "$ARCHIVE_TMP"
  mv "$ARCHIVE_TMP" "$ARCHIVE"
  ARCHIVE_TMP=""
fi

echo "Assembled cooperative ARMv7 payload: $OUTPUT"
if [[ -n "$ARCHIVE" ]]; then
  echo "Extract-at-/ archive: $ARCHIVE"
fi
echo "Device runtime: $DEVICE_RUNTIME (staged at $PAYLOAD_RUNTIME)"
echo "No device contacted; deploy through the unified Pluto provision workflow."
