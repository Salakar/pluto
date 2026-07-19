#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/build/verify-device-elf.sh ELF [GLIBC_CEILING] [TARGET]

TARGET is linux-arm64 (the default) or linux-arm. The linux-arm target uses
the common RM1/RM2 ceilings: GLIBC 2.35, GLIBCXX 3.4.29, and CXXABI 1.3.13.
PLUTO_GLIBCXX_CEILING and PLUTO_CXXABI_CEILING override the C++ ABI ceilings.
PLUTO_ELF_ALLOW_NO_GLIBC=1 permits a target-native self-contained AOT snapshot
with no GLIBC imports; native executables and shared runtimes keep the default
requirement.
EOF
}

die() {
  echo "error: $*" >&2
  exit 2
}

version_lte() {
  local candidate="$1"
  local ceiling="$2"
  [[ "$(printf '%s\n%s\n' "$candidate" "$ceiling" | LC_ALL=C sort -V | tail -1)" == "$ceiling" ]]
}

valid_version() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)+$ ]]
}

audit_version_family() {
  local family="$1"
  local ceiling="$2"
  local required="$3"
  local symbols
  local maximum
  local maximum_version

  symbols="$(
    objdump -T "$ELF" 2>/dev/null |
      grep -oE "${family}_[0-9]+(\\.[0-9]+)+" || true
  )"
  if [[ -z "$symbols" ]]; then
    [[ "$required" -eq 0 ]] || die "no versioned $family imports found in $ELF"
    echo "$family gate: PASS (no versioned imports)"
    return 0
  fi

  maximum="$(printf '%s\n' "$symbols" | LC_ALL=C sort -Vu | tail -1)"
  maximum_version="${maximum#${family}_}"
  if [[ -z "$ceiling" ]]; then
    echo "$family audit: $maximum (no ceiling configured)"
    return 0
  fi
  version_lte "$maximum_version" "$ceiling" ||
    die "$ELF requires $maximum, newer than target ceiling ${family}_$ceiling"
  echo "$family gate: PASS ($maximum <= ${family}_$ceiling)"
}

if (($# < 1 || $# > 3)); then
  usage >&2
  exit 2
fi

ELF="$1"
TARGET="${3:-${PLUTO_ELF_TARGET:-linux-arm64}}"
case "$TARGET" in
  linux-arm64)
    DEFAULT_GLIBC_CEILING=2.39
    DEFAULT_GLIBCXX_CEILING=3.4.32
    DEFAULT_CXXABI_CEILING=1.3.14
    ;;
  linux-arm)
    DEFAULT_GLIBC_CEILING=2.35
    DEFAULT_GLIBCXX_CEILING=3.4.29
    DEFAULT_CXXABI_CEILING=1.3.13
    ;;
  *) die "unsupported ELF target: $TARGET" ;;
esac
GLIBC_CEILING="${2:-${PLUTO_GLIBC_CEILING:-$DEFAULT_GLIBC_CEILING}}"
GLIBCXX_CEILING="${PLUTO_GLIBCXX_CEILING:-$DEFAULT_GLIBCXX_CEILING}"
CXXABI_CEILING="${PLUTO_CXXABI_CEILING:-$DEFAULT_CXXABI_CEILING}"
ALLOW_NO_GLIBC="${PLUTO_ELF_ALLOW_NO_GLIBC:-0}"
[[ -f "$ELF" ]] || die "ELF does not exist: $ELF"
valid_version "$GLIBC_CEILING" ||
  die "invalid GLIBC ceiling: $GLIBC_CEILING"
valid_version "$GLIBCXX_CEILING" ||
  die "invalid GLIBCXX ceiling: $GLIBCXX_CEILING"
valid_version "$CXXABI_CEILING" ||
  die "invalid CXXABI ceiling: $CXXABI_CEILING"
[[ "$ALLOW_NO_GLIBC" == 0 || "$ALLOW_NO_GLIBC" == 1 ]] ||
  die "PLUTO_ELF_ALLOW_NO_GLIBC must be 0 or 1"

for tool in file objdump od sort; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

FILE_DESCRIPTION="$(file "$ELF")"
MAGIC="$(od -An -tx1 -N4 "$ELF" | tr -d '[:space:]')"
[[ "$MAGIC" == 7f454c46 ]] || die "not an ELF file: $FILE_DESCRIPTION"
ELF_CLASS="$(od -An -tu1 -j4 -N1 "$ELF" | tr -d '[:space:]')"
read -r MACHINE_LO MACHINE_HI <<<"$(od -An -tu1 -j18 -N2 "$ELF")"
ELF_MACHINE=$((MACHINE_LO | (MACHINE_HI << 8)))

case "$TARGET" in
  linux-arm64)
    [[ "$ELF_CLASS" -eq 2 && "$ELF_MACHINE" -eq 183 ]] ||
      die "expected ELF64 EM_AARCH64, found: $FILE_DESCRIPTION"
    echo "linux-arm64 gate: PASS (ELF64 EM_AARCH64)"
    ;;
  linux-arm)
    [[ "$ELF_CLASS" -eq 1 && "$ELF_MACHINE" -eq 40 ]] ||
      die "expected ELF32 EM_ARM, found: $FILE_DESCRIPTION"
    read -r FLAG_0 FLAG_1 FLAG_2 FLAG_3 <<<"$(od -An -tu1 -j36 -N4 "$ELF")"
    ELF_FLAGS=$((FLAG_0 | (FLAG_1 << 8) | (FLAG_2 << 16) | (FLAG_3 << 24)))
    EABI_VERSION=$(((ELF_FLAGS >> 24) & 0xff))
    [[ "$EABI_VERSION" -eq 5 ]] ||
      die "expected ARM EABI5, found EABI$EABI_VERSION"
    (( (ELF_FLAGS & 0x400) != 0 )) ||
      die "expected ARM hard-float ABI flag (e_flags=0x$(printf '%08x' "$ELF_FLAGS"))"
    (( (ELF_FLAGS & 0x200) == 0 )) ||
      die "ARM ELF sets the soft-float ABI flag"
    printf 'linux-arm gate: PASS (ELF32 EM_ARM EABI5 hard-float, e_flags=0x%08x)\n' \
      "$ELF_FLAGS"
    ;;
esac

audit_version_family GLIBC "$GLIBC_CEILING" "$((1 - ALLOW_NO_GLIBC))"
audit_version_family GLIBCXX "$GLIBCXX_CEILING" 0
audit_version_family CXXABI "$CXXABI_CEILING" 0

echo "dynamic dependencies:"
if command -v readelf >/dev/null 2>&1; then
  readelf -d "$ELF" | awk '/\(NEEDED\)/ {print "  " $NF}'
else
  objdump -p "$ELF" | awk '$1 == "NEEDED" {print "  [" $2 "]"}'
fi
