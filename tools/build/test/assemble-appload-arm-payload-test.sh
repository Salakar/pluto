#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ASSEMBLER="$ROOT/tools/build/assemble-appload-arm-payload.sh"
FLUTTER_VERSION="$(tr -d '[:space:]' < "$ROOT/tools/pluto/pins/flutter.version")"
ENGINE_COMMIT="$(tr -d '[:space:]' < "$ROOT/tools/pluto/pins/engine.version")"
ENGINE_DIR="$ROOT/third_party/engine/$ENGINE_COMMIT/linux-arm-release"
ENGINE="$ENGINE_DIR/libflutter_engine.so"
ICU_DATA="$ENGINE_DIR/icudtl.dat"
CODEX_SHA256=df8b6673f48b10356a7cee64b405c14435401a083f5e04ee147f0bd7b6760bdf
# shellcheck source=../../integration/sources.lock
source "$ROOT/tools/integration/sources.lock"
XOVI_SHA256="$REFERENCE_XOVI_SHA256"
QRR_SHA256="$REFERENCE_QRR_SHA256"
QTFB_SHIM_32_SHA256="$REFERENCE_QTFB_SHIM_32_SHA256"
QTFB_SHIM_SHA256="$REFERENCE_QTFB_SHIM_SHA256"
BAD_SHA256=0000000000000000000000000000000000000000000000000000000000000000
QRR_HASHTAB_327_SHA256=01c294ff28a21336814d657e27c5de2c83a8ad0e03b143e9cef6216dacfefc86
QRR_HASHTAB_328_SHA256=b64584f7cd0520be6abe984a6b4c9c0b4ebcead56b66a11c9a96a41139421db6
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pluto-appload-arm-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >"$TMP/failure.stdout" 2>"$TMP/failure.stderr"; then
    fail "$label unexpectedly succeeded"
  fi
}

write_arm_product_elf() {
  local path="$1"

  # Minimal ELF32 EM_ARM/EABI5 hard-float header. Dart AOT app.so has no libc
  # imports, so this fixture only needs the header and product snapshot marker
  # consumed by the assembler's app-specific gate.
  printf '\177ELF\001\001\001\000\000\000\000\000\000\000\000\000\003\000\050\000\001\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\004\000\005\064\000\000\000\000\000\000\000\000\000\000\000\000' > "$path"
  printf '%s\000' \
    'ace654product no-code_comments no-dwarf_stack_traces_mode dedup_instructions no-asan no-msan no-tsan no-shared_data arm linux no-compressed-pointers' \
    >> "$path"
}

write_layout() {
  local layout="$1"
  local app_id="$2"

  mkdir -p \
    "$layout/assets/pluto" \
    "$layout/bundle/flutter_assets" \
    "$layout/bundle/lib"
  printf 'test icon\n' > "$layout/assets/pluto/icon.png"
  printf 'test assets\n' > "$layout/bundle/flutter_assets/AssetManifest.bin"
  cp "$ICU_DATA" "$layout/bundle/icudtl.dat"
  write_arm_product_elf "$layout/bundle/lib/app.so"
  cat > "$layout/build-metadata.json" <<EOF
{
  "schema": 1,
  "buildMode": "release",
  "engineFlavor": "release",
  "flutterVersion": "$FLUTTER_VERSION",
  "engineCommit": "$ENGINE_COMMIT",
  "target": "linux-arm"
}
EOF
  cat > "$layout/manifest.json" <<EOF
{"schema":1,"id":"$app_id","name":"Fixture","runtime":{"type":"flutter-aot","appElf":"lib/app.so","assets":"flutter_assets"},"engine":{"flutterVersion":"$FLUTTER_VERSION","engineCommit":"$ENGINE_COMMIT"}}
EOF
}

write_integration_fixture() {
  local xovi="$1"
  local appload="$2"
  local shims="$3"

  mkdir -p \
    "$xovi/extensions.d" \
    "$xovi/services/xochitl.service" \
    "$xovi/scripts/debug" \
    "$shims"
  for elf in \
    "$xovi/xovi.so" \
    "$xovi/extensions.d/qt-resource-rebuilder.so" \
    "$appload" \
    "$shims/qtfb-shim-32bit.so" \
    "$shims/qtfb-shim.so"; do
    cp "$ENGINE" "$elf"
  done
  for script in start stock debug rebuild_hashtable; do
    printf '#!/bin/sh\nexit 0\n' > "$xovi/$script"
    chmod 0755 "$xovi/$script"
  done
  printf '[Service]\nQML_DISABLE_DISK_CACHE=1\n' \
    > "$xovi/services/xochitl.service/qt-resource-rebuilder.conf"
  printf '#!/bin/sh\nexit 0\n' \
    > "$xovi/scripts/debug/qt-resource-rebuilder.sh"
  chmod 0755 "$xovi/scripts/debug/qt-resource-rebuilder.sh"
}

write_sha256_test_wrapper() {
  local destination="$1"
  local real_sha256sum=""
  local real_shasum=""

  real_sha256sum="$(command -v sha256sum || true)"
  real_shasum="$(command -v shasum || true)"
  [[ -n "$real_sha256sum" || -n "$real_shasum" ]] ||
    fail "test needs sha256sum or shasum"
  mkdir -p "$destination"
  cat > "$destination/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  "$PLUTO_TEST_CODEX_BIN")
    printf '%s  %s\n' "$PLUTO_TEST_CODEX_SHA256" "$1"
    exit 0
    ;;
  "$PLUTO_TEST_QRR_HASHTAB_327")
    printf '%s  %s\n' "$PLUTO_TEST_QRR_HASHTAB_327_SHA256" "$1"
    exit 0
    ;;
  "$PLUTO_TEST_QRR_HASHTAB_328")
    printf '%s  %s\n' "$PLUTO_TEST_QRR_HASHTAB_328_SHA256" "$1"
    exit 0
    ;;
  "$PLUTO_TEST_XOVI_BIN")
    if [[ -n "${PLUTO_TEST_XOVI_SHA256_OVERRIDE:-}" ]]; then
      printf '%s  %s\n' "$PLUTO_TEST_XOVI_SHA256_OVERRIDE" "$1"
      exit 0
    fi
    ;;
  "$PLUTO_TEST_QRR_BIN")
    if [[ -n "${PLUTO_TEST_QRR_SHA256_OVERRIDE:-}" ]]; then
      printf '%s  %s\n' "$PLUTO_TEST_QRR_SHA256_OVERRIDE" "$1"
      exit 0
    fi
    ;;
  "$PLUTO_TEST_QTFB_SHIM_32")
    if [[ -n "${PLUTO_TEST_QTFB_SHIM_32_SHA256_OVERRIDE:-}" ]]; then
      printf '%s  %s\n' "$PLUTO_TEST_QTFB_SHIM_32_SHA256_OVERRIDE" "$1"
      exit 0
    fi
    ;;
  "$PLUTO_TEST_QTFB_SHIM")
    if [[ -n "${PLUTO_TEST_QTFB_SHIM_SHA256_OVERRIDE:-}" ]]; then
      printf '%s  %s\n' "$PLUTO_TEST_QTFB_SHIM_SHA256_OVERRIDE" "$1"
      exit 0
    fi
    ;;
esac
if [[ -n "${PLUTO_TEST_REAL_SHA256SUM:-}" ]]; then
  exec "$PLUTO_TEST_REAL_SHA256SUM" "$@"
fi
export LC_ALL=C
exec "$PLUTO_TEST_REAL_SHASUM" -a 256 "$@"
EOF
  chmod 0755 "$destination/sha256sum"
  PLUTO_TEST_REAL_SHA256SUM="$real_sha256sum"
  PLUTO_TEST_REAL_SHASUM="$real_shasum"
}

bash -n "$ASSEMBLER"
expect_failure "candidate mode without an explicit integration path" \
  bash "$ASSEMBLER" --candidate-integration --dry-run
grep -q -- '--candidate-integration requires --xovi-root or --appload-shims' \
  "$TMP/failure.stderr" || fail "candidate mode was not explicit-path gated"

LAUNCHER="$TMP/layouts/launcher"
INK="$TMP/layouts/ink"
CODEX="$TMP/layouts/codex"
write_layout "$LAUNCHER" dev.pluto.launcher
write_layout "$INK" dev.pluto.ink
write_layout "$CODEX" dev.pluto.codex
XOVI="$TMP/integration/xovi-source"
APPLOAD_EXTENSION="$TMP/integration/appload.so"
APPLOAD_SHIMS="$TMP/integration/shims"
write_integration_fixture "$XOVI" "$APPLOAD_EXTENSION" "$APPLOAD_SHIMS"
CODEX_BIN="$TMP/integration/codex"
cp "$ENGINE" "$CODEX_BIN"
printf '\nCodex CLI release 0.144.1\n' >> "$CODEX_BIN"
chmod 0755 "$CODEX_BIN"
QRR_HASHTAB_327="$TMP/integration/hashtab-3.27"
QRR_HASHTAB_328="$TMP/integration/hashtab-3.28"
printf 'validated QRR 3.27 test fixture\n' > "$QRR_HASHTAB_327"
printf 'validated QRR 3.28 test fixture\n' > "$QRR_HASHTAB_328"
SHA256_TEST_BIN="$TMP/hash-tools"
write_sha256_test_wrapper "$SHA256_TEST_BIN"
ASSEMBLER_TEST_ENV=(
  env
  "PATH=$SHA256_TEST_BIN:$PATH"
  "PLUTO_TEST_CODEX_BIN=$CODEX_BIN"
  "PLUTO_TEST_CODEX_SHA256=$CODEX_SHA256"
  "PLUTO_TEST_QRR_HASHTAB_327=$QRR_HASHTAB_327"
  "PLUTO_TEST_QRR_HASHTAB_327_SHA256=$QRR_HASHTAB_327_SHA256"
  "PLUTO_TEST_QRR_HASHTAB_328=$QRR_HASHTAB_328"
  "PLUTO_TEST_QRR_HASHTAB_328_SHA256=$QRR_HASHTAB_328_SHA256"
  "PLUTO_TEST_XOVI_BIN=$XOVI/xovi.so"
  "PLUTO_TEST_QRR_BIN=$XOVI/extensions.d/qt-resource-rebuilder.so"
  "PLUTO_TEST_QTFB_SHIM_32=$APPLOAD_SHIMS/qtfb-shim-32bit.so"
  "PLUTO_TEST_QTFB_SHIM=$APPLOAD_SHIMS/qtfb-shim.so"
  "PLUTO_TEST_REAL_SHA256SUM=$PLUTO_TEST_REAL_SHA256SUM"
  "PLUTO_TEST_REAL_SHASUM=$PLUTO_TEST_REAL_SHASUM"
)
QRR_MISMATCH_ENV=(
  env
  "PATH=$SHA256_TEST_BIN:$PATH"
  "PLUTO_TEST_CODEX_BIN=$CODEX_BIN"
  "PLUTO_TEST_CODEX_SHA256=$CODEX_SHA256"
  "PLUTO_TEST_QRR_HASHTAB_327=$TMP/not-the-3.27-input"
  "PLUTO_TEST_QRR_HASHTAB_327_SHA256=$QRR_HASHTAB_327_SHA256"
  "PLUTO_TEST_QRR_HASHTAB_328=$QRR_HASHTAB_328"
  "PLUTO_TEST_QRR_HASHTAB_328_SHA256=$QRR_HASHTAB_328_SHA256"
  "PLUTO_TEST_XOVI_BIN=$XOVI/xovi.so"
  "PLUTO_TEST_QRR_BIN=$XOVI/extensions.d/qt-resource-rebuilder.so"
  "PLUTO_TEST_QTFB_SHIM_32=$APPLOAD_SHIMS/qtfb-shim-32bit.so"
  "PLUTO_TEST_QTFB_SHIM=$APPLOAD_SHIMS/qtfb-shim.so"
  "PLUTO_TEST_REAL_SHA256SUM=$PLUTO_TEST_REAL_SHA256SUM"
  "PLUTO_TEST_REAL_SHASUM=$PLUTO_TEST_REAL_SHASUM"
)
PINNED_INTEGRATION_ARGS=(
  --xovi-root "$XOVI"
  --appload-extension-3.27 "$APPLOAD_EXTENSION"
  --appload-extension-3.28 "$APPLOAD_EXTENSION"
  --appload-shims "$APPLOAD_SHIMS"
  --qrr-hashtab-3.27 "$QRR_HASHTAB_327"
  --qrr-hashtab-3.28 "$QRR_HASHTAB_328"
)
INTEGRATION_ARGS=(
  --candidate-integration
  "${PINNED_INTEGRATION_ARGS[@]}"
)
PINNED_INTEGRATION_HASH_ENV=(
  "${ASSEMBLER_TEST_ENV[@]}"
  "PLUTO_TEST_XOVI_SHA256_OVERRIDE=$XOVI_SHA256"
  "PLUTO_TEST_QRR_SHA256_OVERRIDE=$QRR_SHA256"
  "PLUTO_TEST_QTFB_SHIM_32_SHA256_OVERRIDE=$QTFB_SHIM_32_SHA256"
  "PLUTO_TEST_QTFB_SHIM_SHA256_OVERRIDE=$QTFB_SHIM_SHA256"
)

OUTPUT="$TMP/output"
ARCHIVE="$TMP/output.tar"
"${ASSEMBLER_TEST_ENV[@]}" bash "$ASSEMBLER" \
  --embedder "$ENGINE" \
  --control-client "$ENGINE" \
  --codex-bin "$CODEX_BIN" \
  "${INTEGRATION_ARGS[@]}" \
  --launcher-layout "$LAUNCHER" \
  --ink-layout "$INK" \
  --codex-layout "$CODEX" \
  --output "$OUTPUT" \
  --archive "$ARCHIVE" \
  > "$TMP/assemble.log"

grep -q '^Explicit unaccepted XOVI/QRR candidate:' "$TMP/assemble.log" ||
  fail "explicit XOVI/QRR candidate was not reported"
grep -Eq '^  XOVI SHA-256: [0-9a-f]{64}$' "$TMP/assemble.log" ||
  fail "explicit XOVI candidate hash was not reported"
grep -Eq '^  QRR SHA-256: [0-9a-f]{64}$' "$TMP/assemble.log" ||
  fail "explicit QRR candidate hash was not reported"
grep -q '^Explicit unaccepted QTFB shim candidate:' "$TMP/assemble.log" ||
  fail "explicit QTFB shim candidate was not reported"
grep -q \
  '^Explicit integration candidate passed ARM architecture and ABI gates\.$' \
  "$TMP/assemble.log" || fail "candidate ABI validation was not reported"

RUNTIME="$OUTPUT/home/root/pluto-arm"
[[ -x "$RUNTIME/bin/pluto-embedder" ]] || fail "shared embedder is absent"
[[ -x "$RUNTIME/bin/pluto-controlctl" ]] ||
  fail "Pluto control client is absent"
[[ -x "$RUNTIME/bin/codex" ]] || fail "real Codex CLI is absent"
cmp -s "$CODEX_BIN" "$RUNTIME/bin/codex" ||
  fail "packaged Codex CLI differs from its release input"
[[ -s "$RUNTIME/engine/release/libflutter_engine.so" ]] ||
  fail "shared release engine is absent"
[[ -s "$RUNTIME/engine/release/icudtl.dat" ]] || fail "shared ICU data is absent"
INTEGRATION="$RUNTIME/integration"
[[ -s "$INTEGRATION/CHECKSUMS.txt" ]] ||
  fail "cooperative integration checksums are absent"
[[ -s "$INTEGRATION/profiles/3.27.3.0/appload.so" ]] ||
  fail "3.27 control-enabled AppLoad extension is absent"
[[ -s "$INTEGRATION/profiles/3.28.0.162/appload.so" ]] ||
  fail "3.28 control-enabled AppLoad extension is absent"
cmp -s "$QRR_HASHTAB_327" "$INTEGRATION/profiles/3.27.3.0/hashtab" ||
  fail "3.27 profile hashtab is absent or changed"
cmp -s "$QRR_HASHTAB_328" "$INTEGRATION/profiles/3.28.0.162/hashtab" ||
  fail "3.28 profile hashtab is absent or changed"
[[ -s "$INTEGRATION/xovi/extensions.d/qt-resource-rebuilder.so" ]] ||
  fail "QRR extension is absent"
[[ -s "$INTEGRATION/xovi/exthome/appload/shims/qtfb-shim-32bit.so" ]] ||
  fail "32-bit QTFB shim is absent"
[[ "$(readlink "$INTEGRATION/xovi/services/xochitl.service/extensions.d")" = \
  /home/root/xovi/extensions.d ]] || fail "XOVI extension link is wrong"
[[ "$(readlink "$INTEGRATION/xovi/services/xochitl.service/exthome")" = \
  /home/root/xovi/exthome ]] || fail "XOVI exthome link is wrong"
grep -q '^hashtab=profile-matched$' "$INTEGRATION/CHECKSUMS.txt" ||
  fail "integration payload does not declare profile-matched hashtabs"
grep -q '^firmwareProfiles=3.27.3.0,3.28.0.162$' \
  "$INTEGRATION/CHECKSUMS.txt" ||
  fail "integration payload does not declare exact firmware profiles"
grep -q "^$QRR_HASHTAB_327_SHA256  profiles/3.27.3.0/hashtab$" \
  "$INTEGRATION/CHECKSUMS.txt" ||
  fail "3.27 profile hashtab checksum is absent"
grep -q "^$QRR_HASHTAB_328_SHA256  profiles/3.28.0.162/hashtab$" \
  "$INTEGRATION/CHECKSUMS.txt" ||
  fail "3.28 profile hashtab checksum is absent"

for app_id in dev.pluto.launcher dev.pluto.ink dev.pluto.codex; do
  [[ -s "$RUNTIME/apps/$app_id/bundle/lib/app.so" ]] ||
    fail "$app_id release AOT snapshot is absent"
  [[ ! -e "$RUNTIME/apps/$app_id/bundle/flutter_assets/kernel_blob.bin" ]] ||
    fail "$app_id contains a JIT kernel"
done

[[ ! -d "$OUTPUT/home/root/xovi" ]] ||
  fail "payload embedded legacy unmanaged AppLoad entries"
if find "$OUTPUT" -type f -name external.manifest.json -print -quit |
    grep -q .; then
  fail "payload embedded an unmanaged external AppLoad manifest"
fi
grep -q '"version": "0.144.1"' "$RUNTIME/COOPERATIVE-PAYLOAD.json" ||
  fail "payload metadata omitted the Codex version pin"
grep -q "\"sha256\": \"$CODEX_SHA256\"" \
  "$RUNTIME/COOPERATIVE-PAYLOAD.json" ||
  fail "payload metadata omitted the Codex SHA-256 pin"
grep -q '"path": "/home/root/pluto/bin/codex"' \
  "$RUNTIME/COOPERATIVE-PAYLOAD.json" ||
  fail "payload metadata uses a non-canonical Codex path"
if grep -q 'PAPER_CODEX_FAKE\|codexAcceptanceMode' \
    "$RUNTIME/COOPERATIVE-PAYLOAD.json"; then
  fail "payload metadata still claims fake Codex acceptance"
fi

[[ -s "$ARCHIVE" ]] || fail "deploy archive was not created"
archive_uid="$(
  LC_ALL=C dd if="$ARCHIVE" bs=1 skip=108 count=8 2>/dev/null |
    LC_ALL=C tr -d '\000 '
)"
archive_gid="$(
  LC_ALL=C dd if="$ARCHIVE" bs=1 skip=116 count=8 2>/dev/null |
    LC_ALL=C tr -d '\000 '
)"
[[ -n "$archive_uid" && "$archive_uid" =~ ^0+$ &&
  -n "$archive_gid" && "$archive_gid" =~ ^0+$ ]] ||
  fail "deploy archive root entry is not owned by uid/gid 0"
LC_ALL=C tar -tf "$ARCHIVE" | grep -q '^home/root/pluto-arm/bin/pluto-embedder$' ||
  fail "archive omitted the provision runtime"
LC_ALL=C tar -tf "$ARCHIVE" | grep -q '^home/root/pluto-arm/bin/codex$' ||
  fail "archive omitted the real Codex CLI"
if LC_ALL=C tar -tf "$ARCHIVE" | grep -q 'external.manifest.json$'; then
  fail "archive embedded an unmanaged AppLoad entry"
fi

expect_integration_hash_failure() {
  local label="$1"
  local override="$2"
  local expected_error="$3"
  local output="$4"

  expect_failure "$label" \
    "${PINNED_INTEGRATION_HASH_ENV[@]}" "$override" \
    bash "$ASSEMBLER" \
      --embedder "$ENGINE" \
      --control-client "$ENGINE" \
      --codex-bin "$CODEX_BIN" \
      "${PINNED_INTEGRATION_ARGS[@]}" \
      --launcher-layout "$LAUNCHER" \
      --ink-layout "$INK" \
      --codex-layout "$CODEX" \
      --output "$output" \
      --no-archive
  grep -F "$expected_error" "$TMP/failure.stderr" >/dev/null ||
    fail "$label failed for an unexpected reason"
  [[ ! -e "$output" ]] || fail "$label left a partial output tree"
}

expect_integration_hash_failure \
  "drifted device-accepted XOVI" \
  "PLUTO_TEST_XOVI_SHA256_OVERRIDE=$BAD_SHA256" \
  "device-accepted XOVI runtime SHA-256 mismatch" \
  "$TMP/rejected-xovi"
expect_integration_hash_failure \
  "drifted device-accepted QRR" \
  "PLUTO_TEST_QRR_SHA256_OVERRIDE=$BAD_SHA256" \
  "device-accepted Qt resource rebuilder SHA-256 mismatch" \
  "$TMP/rejected-qrr"
expect_integration_hash_failure \
  "drifted device-accepted 32-bit QTFB shim" \
  "PLUTO_TEST_QTFB_SHIM_32_SHA256_OVERRIDE=$BAD_SHA256" \
  "device-accepted 32-bit QTFB shim SHA-256 mismatch" \
  "$TMP/rejected-shim32"
expect_integration_hash_failure \
  "drifted device-accepted QTFB shim" \
  "PLUTO_TEST_QTFB_SHIM_SHA256_OVERRIDE=$BAD_SHA256" \
  "device-accepted QTFB shim SHA-256 mismatch" \
  "$TMP/rejected-shim"

expect_failure "unpinned Codex CLI" \
  bash "$ASSEMBLER" \
    --embedder "$ENGINE" \
    --control-client "$ENGINE" \
    --codex-bin "$CODEX_BIN" \
    "${INTEGRATION_ARGS[@]}" \
    --launcher-layout "$LAUNCHER" \
    --ink-layout "$INK" \
    --codex-layout "$CODEX" \
    --output "$TMP/rejected-codex" \
    --no-archive
grep -q 'Codex CLI SHA-256 mismatch' "$TMP/failure.stderr" ||
  fail "unpinned Codex CLI failed for an unexpected reason"
[[ ! -e "$TMP/rejected-codex" ]] ||
  fail "rejected Codex CLI left a partial output tree"

expect_failure "unmatched 3.27 QRR hashtab" \
  "${QRR_MISMATCH_ENV[@]}" bash "$ASSEMBLER" \
    --embedder "$ENGINE" \
    --control-client "$ENGINE" \
    --codex-bin "$CODEX_BIN" \
    "${INTEGRATION_ARGS[@]}" \
    --launcher-layout "$LAUNCHER" \
    --ink-layout "$INK" \
    --codex-layout "$CODEX" \
    --output "$TMP/rejected-hashtab" \
    --no-archive
grep -q 'QRR 3.27 hashtab does not match' "$TMP/failure.stderr" ||
  fail "unmatched QRR hashtab failed for an unexpected reason"
[[ ! -e "$TMP/rejected-hashtab" ]] ||
  fail "rejected QRR hashtab left a partial output tree"

BAD_LAYOUT="$TMP/layouts/wrong-target"
cp -R "$LAUNCHER" "$BAD_LAYOUT"
sed 's/"target": "linux-arm"/"target": "linux-arm64"/' \
  "$BAD_LAYOUT/build-metadata.json" > "$BAD_LAYOUT/build-metadata.invalid"
mv "$BAD_LAYOUT/build-metadata.invalid" "$BAD_LAYOUT/build-metadata.json"
expect_failure "wrong-target layout" \
  "${ASSEMBLER_TEST_ENV[@]}" bash "$ASSEMBLER" \
    --embedder "$ENGINE" \
    --control-client "$ENGINE" \
    --codex-bin "$CODEX_BIN" \
    "${INTEGRATION_ARGS[@]}" \
    --launcher-layout "$BAD_LAYOUT" \
    --ink-layout "$INK" \
    --codex-layout "$CODEX" \
    --output "$TMP/rejected" \
    --no-archive
grep -q 'layout target is not linux-arm' "$TMP/failure.stderr" ||
  fail "wrong target failed for an unexpected reason"
[[ ! -e "$TMP/rejected" ]] || fail "rejected layout left a partial output tree"

KERNEL_LAYOUT="$TMP/layouts/with-kernel"
cp -R "$LAUNCHER" "$KERNEL_LAYOUT"
printf 'forbidden JIT fixture\n' \
  > "$KERNEL_LAYOUT/bundle/flutter_assets/kernel_blob.bin"
expect_failure "release layout with JIT kernel" \
  "${ASSEMBLER_TEST_ENV[@]}" bash "$ASSEMBLER" \
    --embedder "$ENGINE" \
    --control-client "$ENGINE" \
    --codex-bin "$CODEX_BIN" \
    "${INTEGRATION_ARGS[@]}" \
    --launcher-layout "$KERNEL_LAYOUT" \
    --ink-layout "$INK" \
    --codex-layout "$CODEX" \
    --output "$TMP/rejected-kernel" \
    --no-archive
grep -q 'release layout contains a JIT kernel' "$TMP/failure.stderr" ||
  fail "JIT kernel failed for an unexpected reason"

echo "PASS: cooperative AppLoad ARMv7 payload assembly"
