#!/usr/bin/env bash
set -euo pipefail

readonly TARGET=armv7-unknown-linux-gnueabihf
readonly RUST_TOOLCHAIN=1.95.0
readonly RUST_HOST=1.95.0-x86_64-unknown-linux-gnu
readonly RUSTC_COMMIT=59807616e1fa2540724bfbac14d7976d7e4a3860
readonly SOURCE_DATE_EPOCH=1783635027
readonly SOURCE_COMMIT=44918ea10c0f99151c6710411b4322c2f5c96bea
readonly ORIGINAL_LOCK_SHA256=175793a40a3147db1fee08fd9db0acc59312c344b3513dd7ee316f5446d8119e
readonly NORMALIZED_LOCK_SHA256=3e1588323284356881cc454122e1e4fd256226ae112351b0303d1ef115626e24
readonly PATCHED_LOCK_SHA256=e41d846db258bfa36d5e6a7a4d138ecc61f418504231cbad44f863672095cd52
readonly PAGABLE_ARCHIVE_SHA256=3658968938a4d1eaa1987e69dcd84b01fb067c5b3416dccc8d71373b6ded6821
readonly PAGABLE_PATCHED_TREE_SHA256=284c92953652d9374b4b4962b0114dc12083ad132086e64e3f3170cfa7458f80
readonly SECCOMPILER_ARCHIVE_SHA256=a4ae55de56877481d112a559bbc12667635fdaf5e005712fd4e2b2fa50ffc884
readonly SECCOMPILER_PATCHED_TREE_SHA256=925e5fb1bc60d088d12ebafa2e9238b04d6f56092202d6a3eec6f4233c0b0e0b
readonly SOURCE_ROOT=/src
readonly WORKSPACE=/src/codex-rs
readonly PATCH_ROOT=/pluto-build/patches
readonly SDK_ROOT=/sdk
readonly SDK_HOST="$SDK_ROOT/sysroots/x86_64-codexsdk-linux"
readonly SDK_SYSROOT="$SDK_ROOT/sysroots/cortexa7hf-neon-remarkable-linux-gnueabi"
readonly CROSS_ROOT="$SDK_HOST/usr/bin/arm-remarkable-linux-gnueabi/arm-remarkable-linux-gnueabi"
readonly OUTPUT=/output/codex

die() {
  echo "error: $*" >&2
  exit 2
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

sha256_stdin() {
  sha256sum | awk '{print $1}'
}

tree_sha256() {
  local root="$1"
  (
    cd "$root"
    while IFS= read -r -d '' file; do
      file_sha="$(sha256_file "$file")"
      printf '%s\0%s\0' "${file#./}" "$file_sha"
    done < <(find . -type f -print0 | LC_ALL=C sort -z)
  ) | sha256_stdin
}

extract_verified_crate() {
  local crate_name="$1"
  local crate_version="$2"
  local expected_archive_sha256="$3"
  local destination="$4"
  local archive
  local extracted="$WORKSPACE/vendor/$crate_name-$crate_version"
  local -a archives=()

  while IFS= read -r -d '' archive; do
    archives+=("$archive")
  done < <(
    find "$CARGO_HOME/registry/cache" -type f \
      -name "$crate_name-$crate_version.crate" -print0
  )
  ((${#archives[@]} == 1)) ||
    die "expected exactly one $crate_name $crate_version archive, found ${#archives[@]}"
  archive="${archives[0]}"
  [[ "$(sha256_file "$archive")" = "$expected_archive_sha256" ]] ||
    die "$crate_name $crate_version archive SHA-256 mismatch"
  [[ ! -e "$destination" && ! -e "$extracted" ]] ||
    die "refusing to replace existing vendored crate: $destination"

  tar -xzf "$archive" -C "$WORKSPACE/vendor"
  mv "$extracted" "$destination"
}

verify_toolchain() {
  local rustc_verbose installed

  rustc_verbose="$(rustc "+$RUST_TOOLCHAIN" -Vv)"
  grep -qx 'release: 1.95.0' <<<"$rustc_verbose" ||
    die "Rust release is not exactly 1.95.0"
  grep -qx "commit-hash: $RUSTC_COMMIT" <<<"$rustc_verbose" ||
    die "Rust compiler commit is not $RUSTC_COMMIT"
  [[ "$(cargo "+$RUST_TOOLCHAIN" -V | awk '{print $2}')" = 1.95.0 ]] ||
    die "Cargo release is not exactly 1.95.0"
  rustfmt "+$RUST_TOOLCHAIN" --version | grep -q '^rustfmt 1\.9\.0-stable ' ||
    die "rustfmt release is not the Rust 1.95.0 component"

  installed="$(rustup component list --toolchain "$RUST_HOST" --installed)"
  grep -qx 'cargo-x86_64-unknown-linux-gnu' <<<"$installed" || die "Cargo component missing"
  grep -qx 'rustc-x86_64-unknown-linux-gnu' <<<"$installed" || die "rustc component missing"
  grep -qx 'rustfmt-x86_64-unknown-linux-gnu' <<<"$installed" || die "rustfmt component missing"
  grep -qx 'rust-std-x86_64-unknown-linux-gnu' <<<"$installed" || die "host std component missing"
  grep -qx 'rust-std-armv7-unknown-linux-gnueabihf' <<<"$installed" ||
    die "ARMv7 std component missing"
  if grep -Eq '^(rust-src|clippy)-' <<<"$installed"; then
    die "unreviewed rust-src or clippy component is installed"
  fi
  [[ ! -e "/usr/local/rustup/toolchains/$RUST_HOST/lib/rustlib/src/rust" ]] ||
    die "rust-src must not be present in the hermetic builder"
}

: "${PLUTO_CODEX_ARMV7_INPUT_KEY:?missing input key}"
: "${PLUTO_CODEX_ARMV7_RECIPE_KEY:?missing recipe key}"
: "${PLUTO_CODEX_ARMV7_SDK_SHA256:?missing SDK fingerprint}"

export LC_ALL=C
export LANG=C
export TZ=UTC
export SOURCE_DATE_EPOCH
export ZERO_AR_DATE=1
export CARGO_INCREMENTAL=0
export CARGO_BUILD_JOBS=4
export CARGO_TERM_COLOR=never
umask 022

[[ "$(uname -m)" = x86_64 ]] ||
  die "the official reMarkable SDK host tools require linux/amd64"
[[ -d "$WORKSPACE" && -f "$WORKSPACE/Cargo.toml" ]] ||
  die "Codex source is not mounted at $SOURCE_ROOT"
[[ -x "$CROSS_ROOT-gcc" && -x "$CROSS_ROOT-strip" ]] ||
  die "the official reMarkable ARM toolchain is missing under $SDK_ROOT"
[[ -d "$SDK_SYSROOT/usr/include" && -d "$SDK_SYSROOT/usr/lib" ]] ||
  die "the official reMarkable target sysroot is incomplete"
[[ "$("$CROSS_ROOT-gcc" -dumpfullversion -dumpversion)" = 11.5.0 ]] ||
  die "official SDK GCC release is not exactly 11.5.0"
for required in \
  openai-codex-0.144.1-armv7.patch \
  pagable-0.4.1-armv7.patch \
  seccompiler-0.5.0-armv7.patch; do
  [[ -f "$PATCH_ROOT/$required" ]] || die "missing patch: $required"
done
verify_toolchain

cd "$WORKSPACE"
[[ "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" = "$SOURCE_COMMIT" ]] ||
  die "Codex source is not exact commit $SOURCE_COMMIT"
[[ -z "$(git -C "$SOURCE_ROOT" status --porcelain --untracked-files=all)" ]] ||
  die "isolated Codex source must start clean"
[[ "$(sha256_file Cargo.lock)" = "$ORIGINAL_LOCK_SHA256" ]] ||
  die "upstream Cargo.lock SHA-256 mismatch"

# Normalize tracked-source mtimes before any build script can observe them.
while IFS= read -r -d '' tracked; do
  touch --date="@$SOURCE_DATE_EPOCH" "$SOURCE_ROOT/$tracked"
done < <(git -C "$SOURCE_ROOT" ls-files -z)

# The release tag manifests use 0.144.1 while its committed workspace lock
# entries still use the development placeholder 0.0.0. Normalize only that
# reviewed field and digest-gate the complete result before locked fetching.
[[ "$(grep -c '^version = "0\.0\.0"$' Cargo.lock)" = 132 ]] ||
  die "unexpected number of upstream workspace lock placeholders"
sed -i 's/^version = "0\.0\.0"$/version = "0.144.1"/' Cargo.lock
[[ "$(sha256_file Cargo.lock)" = "$NORMALIZED_LOCK_SHA256" ]] ||
  die "normalized upstream Cargo.lock SHA-256 mismatch"

# Fetch the complete exact normalized lock before adding local compatibility
# overlays. Omitting --target is deliberate: Cargo then includes every host,
# build, and target dependency needed by the later strictly-offline build.
cargo "+$RUST_TOOLCHAIN" fetch --locked
install -d "$WORKSPACE/vendor"
extract_verified_crate \
  pagable 0.4.1 "$PAGABLE_ARCHIVE_SHA256" "$WORKSPACE/vendor/pagable"
extract_verified_crate \
  seccompiler 0.5.0 "$SECCOMPILER_ARCHIVE_SHA256" "$WORKSPACE/vendor/seccompiler"

patch --batch --forward --fuzz=0 --no-backup-if-mismatch \
  -p1 -d "$WORKSPACE/vendor/pagable" \
  < "$PATCH_ROOT/pagable-0.4.1-armv7.patch"
patch --batch --forward --fuzz=0 --no-backup-if-mismatch \
  -p1 -d "$WORKSPACE/vendor/seccompiler" \
  < "$PATCH_ROOT/seccompiler-0.5.0-armv7.patch"
patch --batch --forward --fuzz=0 --no-backup-if-mismatch \
  -p1 -d "$SOURCE_ROOT" \
  < "$PATCH_ROOT/openai-codex-0.144.1-armv7.patch"

if find "$WORKSPACE/vendor" -type f \
  \( \( -name '*.orig' ! -name 'Cargo.toml.orig' \) -o -name '.cargo-ok' \) \
  -print -quit | grep -q .; then
  die "vendored overlays contain Cargo extraction markers or patch backups"
fi
[[ "$(tree_sha256 "$WORKSPACE/vendor/pagable")" = "$PAGABLE_PATCHED_TREE_SHA256" ]] ||
  die "patched pagable source tree SHA-256 mismatch"
[[ "$(tree_sha256 "$WORKSPACE/vendor/seccompiler")" = "$SECCOMPILER_PATCHED_TREE_SHA256" ]] ||
  die "patched seccompiler source tree SHA-256 mismatch"

# Retain every upstream dependency selection, including already-locked yanked
# releases, and change only the source identity of the two verified overlays.
# Regenerating the complete lock here would incorrectly re-resolve the graph.
for overlay in pagable seccompiler; do
  sed -i "/^name = \"$overlay\"$/,/^$/ { /^source = /d; /^checksum = /d; }" Cargo.lock
done
[[ "$(sha256_file Cargo.lock)" = "$PATCHED_LOCK_SHA256" ]] ||
  die "patched Cargo.lock SHA-256 mismatch"

export CC_armv7_unknown_linux_gnueabihf="$CROSS_ROOT-gcc"
export CXX_armv7_unknown_linux_gnueabihf="$CROSS_ROOT-g++"
export AR_armv7_unknown_linux_gnueabihf="$CROSS_ROOT-ar"
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABIHF_LINKER="$CROSS_ROOT-gcc"
readonly PREFIX_MAP_FLAGS="-ffile-prefix-map=/src=/workspace/openai-codex -ffile-prefix-map=/cargo-home=/workspace/cargo-home -ffile-prefix-map=/sdk=/workspace/remarkable-sdk -fdebug-prefix-map=/src=/workspace/openai-codex -fdebug-prefix-map=/cargo-home=/workspace/cargo-home -fdebug-prefix-map=/sdk=/workspace/remarkable-sdk"
export CFLAGS_armv7_unknown_linux_gnueabihf="--sysroot=$SDK_SYSROOT -march=armv7-a -mfpu=neon -mfloat-abi=hard $PREFIX_MAP_FLAGS"
export CXXFLAGS_armv7_unknown_linux_gnueabihf="$CFLAGS_armv7_unknown_linux_gnueabihf"
export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_SYSROOT_DIR="$SDK_SYSROOT"
export PKG_CONFIG_LIBDIR="$SDK_SYSROOT/usr/lib/pkgconfig:$SDK_SYSROOT/usr/share/pkgconfig"
export RUSTFLAGS="-C target-cpu=generic -C link-arg=--sysroot=$SDK_SYSROOT -C link-arg=-march=armv7-a -C link-arg=-mfpu=neon -C link-arg=-mfloat-abi=hard -C link-arg=-Wl,--build-id=sha1 --remap-path-prefix=/src=/workspace/openai-codex --remap-path-prefix=/cargo-home=/workspace/cargo-home --remap-path-prefix=/target=/workspace/target --remap-path-prefix=/sdk=/workspace/remarkable-sdk --remap-path-prefix=/usr/local/rustup=/workspace/rustup"

cargo "+$RUST_TOOLCHAIN" fmt --all -- --check
cargo "+$RUST_TOOLCHAIN" build \
  --locked \
  --offline \
  --release \
  --target "$TARGET" \
  --package codex-cli \
  --bin codex

unstripped="$CARGO_TARGET_DIR/$TARGET/release/codex"
[[ -x "$unstripped" ]] || die "Cargo did not produce $unstripped"
install -m 0755 "$unstripped" "$OUTPUT"
"$CROSS_ROOT-strip" --strip-debug --strip-unneeded "$OUTPUT"
touch --date="@$SOURCE_DATE_EPOCH" "$OUTPUT"

output_sha256="$(sha256_file "$OUTPUT")"
cat > /output/build-metadata.json <<EOF
{
  "schema": 1,
  "inputKey": "$PLUTO_CODEX_ARMV7_INPUT_KEY",
  "recipeKey": "$PLUTO_CODEX_ARMV7_RECIPE_KEY",
  "sourceCommit": "$SOURCE_COMMIT",
  "sourceDateEpoch": $SOURCE_DATE_EPOCH,
  "rustToolchain": "$RUST_TOOLCHAIN",
  "rustcCommit": "$RUSTC_COMMIT",
  "target": "$TARGET",
  "sdkSha256": "$PLUTO_CODEX_ARMV7_SDK_SHA256",
  "normalizedCargoLockSha256": "$NORMALIZED_LOCK_SHA256",
  "patchedCargoLockSha256": "$PATCHED_LOCK_SHA256",
  "pagableTreeSha256": "$PAGABLE_PATCHED_TREE_SHA256",
  "seccompilerTreeSha256": "$SECCOMPILER_PATCHED_TREE_SHA256",
  "outputSha256": "$output_sha256"
}
EOF
touch --date="@$SOURCE_DATE_EPOCH" /output/build-metadata.json

echo "Codex ARMv7 candidate: $OUTPUT"
echo "SHA-256: $output_sha256"
