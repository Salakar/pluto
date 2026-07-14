#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
INSTALLER="$HERE/../pluto-boot-install.sh"
UNINSTALLER="$HERE/../pluto-uninstall.sh"
DROPIN_FIXTURE="$HERE/fixtures/zz-pluto.conf.expected"
TMP=${TMPDIR:-/tmp}/pluto-boot-install-test.$$
ROOT="$TMP/root"
LIVE="$TMP/live"
PEER="$TMP/peer"
DEVICE_HOME="$TMP/home"
BIN="$TMP/bin"
SYSTEMCTL_LOG="$TMP/systemctl.log"

cleanup() { rm -rf "$TMP"; }
trap cleanup 0

fail() {
  echo "boot install test: $*" >&2
  exit 1
}

seed_legacy_units() {
  slot="$1"
  mkdir -p \
    "$slot/usr/lib/systemd/system/multi-user.target.wants" \
    "$slot/etc/systemd/system/multi-user.target.wants"
  for unit in pluto.service pluto-fallback.service; do
    printf 'obsolete %s\n' "$unit" > "$slot/usr/lib/systemd/system/$unit"
    printf 'obsolete %s\n' "$unit" > "$slot/etc/systemd/system/$unit"
    ln -s "../$unit" \
      "$slot/usr/lib/systemd/system/multi-user.target.wants/$unit"
    ln -s "../$unit" \
      "$slot/etc/systemd/system/multi-user.target.wants/$unit"
  done
}

seed_unrelated_unit() {
  slot="$1"
  printf 'keep me\n' > "$slot/usr/lib/systemd/system/unrelated.service"
  ln -s ../unrelated.service \
    "$slot/usr/lib/systemd/system/multi-user.target.wants/unrelated.service"
}

expect_legacy_units_removed() {
  slot="$1"
  label="$2"
  for unit in pluto.service pluto-fallback.service; do
    for path in \
      "$slot/usr/lib/systemd/system/$unit" \
      "$slot/usr/lib/systemd/system/multi-user.target.wants/$unit" \
      "$slot/etc/systemd/system/$unit" \
      "$slot/etc/systemd/system/multi-user.target.wants/$unit"
    do
      if [ -e "$path" ] || [ -L "$path" ]; then
        fail "$label retained legacy artifact $path"
      fi
    done
  done
}

expect_rejected() {
  label="$1"
  if PLUTO_ROOT="$ROOT" sh "$INSTALLER" validate >"$TMP/out" 2>&1; then
    fail "$label was accepted"
  fi
}

mkdir -p \
  "$BIN" \
  "$DEVICE_HOME" \
  "$LIVE/usr/lib/systemd/system" \
  "$PEER/usr/lib/systemd/system" \
  "$ROOT/bin" \
  "$ROOT/engine/release" \
  "$ROOT/launcher/bundle/lib" \
  "$ROOT/launcher/bundle/flutter_assets"
cat > "$BIN/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${PLUTO_TEST_SYSTEMCTL_LOG:?}"
exit 0
SH
cat > "$BIN/pkill" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$BIN/systemctl" "$BIN/pkill"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/pluto-embedder"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/pluto-session.sh"
chmod +x "$ROOT/bin/pluto-embedder" "$ROOT/bin/pluto-session.sh"
: > "$ROOT/engine/release/libflutter_engine.so"
: > "$ROOT/launcher/bundle/lib/app.so"
cat > "$ROOT/launcher/install.json" <<'JSON'
{
  "buildMode": "release",
  "engineFlavor": "release"
}
JSON

PLUTO_ROOT="$ROOT" sh "$INSTALLER" validate >/dev/null ||
  fail "valid release AOT payload was rejected"

: > "$ROOT/launcher/bundle/flutter_assets/kernel_blob.bin"
expect_rejected "mixed AOT/JIT launcher"
rm -f "$ROOT/launcher/bundle/flutter_assets/kernel_blob.bin"

sed 's/"buildMode": "release"/"buildMode": "profile"/' \
  "$ROOT/launcher/install.json" > "$ROOT/launcher/install.json.tmp"
mv "$ROOT/launcher/install.json.tmp" "$ROOT/launcher/install.json"
expect_rejected "profile launcher"

rm -f "$ROOT/launcher/install.json"
PLUTO_ROOT="$ROOT" sh "$INSTALLER" validate >/dev/null ||
  fail "legacy release AOT payload without an install record was rejected"

boot_env() {
  env \
    PATH="$BIN:$PATH" \
    PLUTO_ROOT="$ROOT" \
    PLUTO_SYSTEM_ROOT="$LIVE" \
    PLUTO_PEER_ROOT="$PEER" \
    PLUTO_SYSTEMCTL="$BIN/systemctl" \
    PLUTO_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    "$@"
}

# Install into a live/peer A/B fixture and compare the emitted systemd unit
# byte-for-byte. In particular, OnFailure is a [Unit] directive and must not
# accidentally regress back into [Service].
seed_legacy_units "$LIVE"
seed_legacy_units "$PEER"
seed_unrelated_unit "$LIVE"
seed_unrelated_unit "$PEER"
boot_env sh "$INSTALLER" install >/dev/null ||
  fail "fixture A/B install failed"
sed \
  -e "s|@ROOT@|$ROOT|g" \
  -e "s|@SUPERVISOR@|$ROOT/bin/pluto-session.sh|g" \
  "$DROPIN_FIXTURE" > "$TMP/expected-dropin"
LIVE_DROPIN="$LIVE/usr/lib/systemd/system/xochitl.service.d/zz-pluto.conf"
PEER_DROPIN="$PEER/usr/lib/systemd/system/xochitl.service.d/zz-pluto.conf"
cmp -s "$TMP/expected-dropin" "$LIVE_DROPIN" ||
  fail "live-slot drop-in does not match fixture"
[ ! -e "$PEER_DROPIN" ] ||
  fail "install replaced the peer slot's stock rescue UI"
if grep -q '^ExecStartPost=' "$LIVE_DROPIN"; then
  fail "boot override confirms before the supervisor's present-ready gate"
fi
expect_legacy_units_removed "$LIVE" "live-slot install"
expect_legacy_units_removed "$PEER" "peer-slot stock rescue"
[ -e "$LIVE/usr/lib/systemd/system/unrelated.service" ] &&
  [ -L "$LIVE/usr/lib/systemd/system/multi-user.target.wants/unrelated.service" ] ||
  fail "live-slot install touched an unrelated unit"
[ -e "$PEER/usr/lib/systemd/system/unrelated.service" ] &&
  [ -L "$PEER/usr/lib/systemd/system/multi-user.target.wants/unrelated.service" ] ||
  fail "peer-slot install touched an unrelated unit"
grep -q '^disable pluto.service pluto-fallback.service$' "$SYSTEMCTL_LOG" ||
  fail "legacy standalone services were not disabled by name"
grep -q '^reset-failed xochitl.service$' "$SYSTEMCTL_LOG" ||
  fail "corrected xochitl override did not clear the inherited start limit"

# Uninstall is independently responsible for migrating any legacy artifacts
# that reappeared between revisions, on both roots.
seed_legacy_units "$LIVE"
seed_legacy_units "$PEER"
boot_env sh "$INSTALLER" uninstall >/dev/null ||
  fail "fixture A/B uninstall failed"
[ ! -e "$LIVE_DROPIN" ] || fail "live-slot drop-in survived uninstall"
[ ! -e "$PEER_DROPIN" ] || fail "peer-slot drop-in survived uninstall"
expect_legacy_units_removed "$LIVE" "live-slot uninstall"
expect_legacy_units_removed "$PEER" "peer-slot uninstall"
[ -e "$LIVE/usr/lib/systemd/system/unrelated.service" ] &&
  [ -L "$LIVE/usr/lib/systemd/system/multi-user.target.wants/unrelated.service" ] ||
  fail "live-slot uninstall touched an unrelated unit"
[ -e "$PEER/usr/lib/systemd/system/unrelated.service" ] &&
  [ -L "$PEER/usr/lib/systemd/system/multi-user.target.wants/unrelated.service" ] ||
  fail "peer-slot uninstall touched an unrelated unit"
grep -q '^restart xochitl.service$' "$SYSTEMCTL_LOG" ||
  fail "stock xochitl was not restarted"

# Full uninstall must delegate to that same A/B flow before deleting ROOT.
boot_env sh "$INSTALLER" install >/dev/null ||
  fail "fixture reinstall failed"
cp "$INSTALLER" "$ROOT/bin/pluto-boot-install.sh"
chmod +x "$ROOT/bin/pluto-boot-install.sh"
boot_env sh "$UNINSTALLER" --dry-run --yes > "$TMP/dry-run"
boot_line=$(grep -n 'pluto-boot-install.sh uninstall' "$TMP/dry-run" |
  sed -n '1s/:.*//p')
remove_line=$(grep -n "rm -rf $ROOT" "$TMP/dry-run" |
  sed -n '1s/:.*//p')
[ -n "$boot_line" ] && [ -n "$remove_line" ] &&
  [ "$boot_line" -lt "$remove_line" ] ||
  fail "dry-run does not restore A/B boot state before deleting ROOT"

boot_env env \
  PLUTO_HOME_ROOT="$DEVICE_HOME" \
  PLUTO_UNINSTALL_REEXEC=1 \
  sh "$UNINSTALLER" --yes
[ ! -e "$ROOT" ] || fail "runtime survived a successful full uninstall"
[ ! -e "$LIVE_DROPIN" ] || fail "full uninstall left live-slot drop-in"
[ ! -e "$PEER_DROPIN" ] || fail "full uninstall left peer-slot drop-in"

# If the authoritative peer cleanup cannot be verified, the live slot falls
# back to stock but ROOT must remain so an inactive-slot override is not broken.
ROOT="$TMP/failure-root"
BROKEN_PEER="$TMP/not-a-rootfs"
mkdir -p "$ROOT/bin" "$ROOT/state" "$BROKEN_PEER" \
  "$LIVE/usr/lib/systemd/system/xochitl.service.d"
cp "$INSTALLER" "$ROOT/bin/pluto-boot-install.sh"
chmod +x "$ROOT/bin/pluto-boot-install.sh"
: > "$LIVE_DROPIN"
if env \
    PATH="$BIN:$PATH" \
    PLUTO_ROOT="$ROOT" \
    PLUTO_HOME_ROOT="$DEVICE_HOME" \
    PLUTO_SYSTEM_ROOT="$LIVE" \
    PLUTO_PEER_ROOT="$BROKEN_PEER" \
    PLUTO_SYSTEMCTL="$BIN/systemctl" \
    PLUTO_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    PLUTO_UNINSTALL_REEXEC=1 \
    sh "$UNINSTALLER" --yes; then
  fail "full uninstall accepted unverifiable peer cleanup"
fi
[ -d "$ROOT" ] || fail "failed peer cleanup deleted the runtime"
[ ! -e "$LIVE_DROPIN" ] || fail "safe fallback did not restore live stock boot"
grep -q 'runtime preserved' "$DEVICE_HOME/pluto-uninstall.log" ||
  fail "safe fallback did not explain retained runtime"

echo "boot install test: PASS"
