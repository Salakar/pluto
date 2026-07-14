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
BOOT_ENV_DIR="$TMP/boot-env"
BOOT_SET_LOG="$TMP/boot-set.log"

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
  "$BOOT_ENV_DIR" \
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
cat > "$BIN/fw_printenv" <<'SH'
#!/bin/sh
[ "$1" = -n ] && [ "$#" -eq 2 ] || exit 64
cat "$PLUTO_TEST_BOOT_ENV_DIR/$2"
SH
cat > "$BIN/fw_setenv" <<'SH'
#!/bin/sh
[ "$#" -eq 2 ] || exit 64
case "$1:$2" in
  bootcount:0|bootcount:1|upgrade_available:0|upgrade_available:1) ;;
  *) exit 64 ;;
esac
printf '%s %s\n' "$1" "$2" >> "$PLUTO_TEST_BOOT_SET_LOG"
printf '%s\n' "$2" > "$PLUTO_TEST_BOOT_ENV_DIR/$1"
SH
cat > "$BIN/sync" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$BIN/systemctl" "$BIN/pkill" "$BIN/fw_printenv" \
  "$BIN/fw_setenv" "$BIN/sync"
printf '2\n' > "$BOOT_ENV_DIR/active_partition"
printf '3\n' > "$BOOT_ENV_DIR/fallback_partition"
printf '1\n' > "$BOOT_ENV_DIR/bootlimit"
printf '0\n' > "$BOOT_ENV_DIR/bootcount"
printf '0\n' > "$BOOT_ENV_DIR/upgrade_available"
: > "$BOOT_SET_LOG"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/pluto-embedder"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/pluto-session.sh"
cp "$HERE/../pluto-boot-confirm.sh" "$ROOT/bin/pluto-boot-confirm.sh"
chmod +x "$ROOT/bin/pluto-embedder" "$ROOT/bin/pluto-session.sh" \
  "$ROOT/bin/pluto-boot-confirm.sh"
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

# Without the fixture peer override, the installer derives the inactive root
# solely from the generated U-Boot recovery boundary. The host fixture cannot
# manufacture a block device, so it must fail before writing the live root and
# report the exact RM1 fallback partition it selected.
printf 'console=tty root=/dev/mmcblk1p2 rootwait\n' > "$TMP/cmdline"
if env \
    PATH="$BIN:$PATH" \
    PLUTO_ROOT="$ROOT" \
    PLUTO_SYSTEM_ROOT="$LIVE" \
    PLUTO_SYSTEMCTL="$BIN/systemctl" \
    PLUTO_PROFILE_FILE="$HERE/../generated/device-profiles.sh" \
    PLUTO_TESTING=1 \
    PLUTO_TEST_PROFILE_ID=rm1 \
    PLUTO_FW_PRINTENV="$BIN/fw_printenv" \
    PLUTO_TEST_BOOT_ENV_DIR="$BOOT_ENV_DIR" \
    PLUTO_CMDLINE_FILE="$TMP/cmdline" \
      sh "$INSTALLER" install > "$TMP/uboot-peer.out" 2>&1; then
  fail "non-block U-Boot peer partition was accepted"
fi
grep -q 'peer slot /dev/mmcblk1p3 is not a block device' \
  "$TMP/uboot-peer.out" ||
  fail "RM1 U-Boot fallback partition was not selected from its profile"
[ ! -e "$LIVE/usr/lib/systemd/system/xochitl.service.d/zz-pluto.conf" ] ||
  fail "failed U-Boot peer validation mutated the live boot root"

boot_env() {
  env \
    PATH="$BIN:$PATH" \
    PLUTO_ROOT="$ROOT" \
    PLUTO_SYSTEM_ROOT="$LIVE" \
    PLUTO_PEER_ROOT="$PEER" \
    PLUTO_SYSTEMCTL="$BIN/systemctl" \
    PLUTO_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    PLUTO_PROFILE_FILE="$HERE/../generated/device-profiles.sh" \
    PLUTO_TESTING=1 \
    PLUTO_TEST_PROFILE_ID="${PLUTO_TEST_PROFILE_ID:-rm1}" \
    PLUTO_FW_PRINTENV="$BIN/fw_printenv" \
    PLUTO_FW_SETENV="$BIN/fw_setenv" \
    PLUTO_CMDLINE_FILE="$TMP/cmdline" \
    PLUTO_SYNC="$BIN/sync" \
    PLUTO_TEST_BOOT_ENV_DIR="$BOOT_ENV_DIR" \
    PLUTO_TEST_BOOT_SET_LOG="$BOOT_SET_LOG" \
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
RECOVERY_HANDLER="$LIVE/usr/libexec/pluto-boot-recovery"
RECOVERY_CONFIG="$LIVE/usr/lib/pluto/boot-recovery.conf"
RECOVERY_UNIT="$LIVE/usr/lib/systemd/system/pluto-boot-failure.service"
[ -x "$RECOVERY_HANDLER" ] && [ -f "$RECOVERY_CONFIG" ] &&
  [ -f "$RECOVERY_UNIT" ] ||
  fail "rootfs recovery handler/config/service were not installed"
if grep -F "$ROOT" "$RECOVERY_HANDLER" "$RECOVERY_CONFIG" \
    "$RECOVERY_UNIT" >/dev/null; then
  fail "rootfs failure recovery retained a /home runtime dependency"
fi
grep -q '^ExecStart=/usr/libexec/pluto-boot-recovery failure$' \
  "$RECOVERY_UNIT" || fail "failure service does not use the rootfs handler"
grep -q '^OnFailure=pluto-boot-failure.service$' "$LIVE_DROPIN" ||
  fail "boot override does not route failure to Pluto recovery"
[ "$(cat "$BOOT_ENV_DIR/upgrade_available")" = 1 ] ||
  fail "boot override was published without an armed U-Boot transaction"
tail -n 2 "$BOOT_SET_LOG" > "$TMP/install-arm-tail"
[ "$(cat "$TMP/install-arm-tail")" = "bootcount 0
upgrade_available 1" ] || fail "installer did not commit arm flag last"
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
[ ! -e "$RECOVERY_HANDLER" ] && [ ! -e "$RECOVERY_CONFIG" ] &&
  [ ! -e "$RECOVERY_UNIT" ] ||
  fail "rootfs recovery artifacts survived uninstall"
[ "$(cat "$BOOT_ENV_DIR/upgrade_available")" = 0 ] ||
  fail "uninstall did not disarm after restoring stock"
tail -n 2 "$BOOT_SET_LOG" > "$TMP/uninstall-disarm-tail"
[ "$(cat "$TMP/uninstall-disarm-tail")" = "bootcount 0
upgrade_available 0" ] || fail "uninstall did not clear recovery flag last"
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

reset_boot_environment() {
  printf '0\n' > "$BOOT_ENV_DIR/bootcount"
  printf '0\n' > "$BOOT_ENV_DIR/upgrade_available"
  : > "$BOOT_SET_LOG"
}

expect_installer_power_loss() {  # action boundary
  action=$1
  boundary=$2
  set +e
  PLUTO_TEST_POWER_LOSS_AT="$boundary" \
    boot_env sh "$INSTALLER" "$action" > "$TMP/power-loss.out" 2>&1
  result=$?
  set -e
  [ "$result" -eq 97 ] ||
    fail "$action/$boundary returned $result instead of 97"
}

# Installation power-loss boundaries never expose an unarmed Pluto override.
reset_boot_environment
expect_installer_power_loss install recovery_handler_durable
[ ! -e "$LIVE_DROPIN" ] ||
  fail "handler staging boundary exposed the Pluto override"
[ "$(cat "$BOOT_ENV_DIR/upgrade_available")" = 0 ] ||
  fail "handler staging boundary armed recovery early"
[ -x "$RECOVERY_HANDLER" ] && [ -f "$RECOVERY_CONFIG" ] ||
  fail "handler staging boundary is not rootfs durable"
boot_env sh "$INSTALLER" uninstall >/dev/null ||
  fail "could not recover handler staging boundary"

reset_boot_environment
expect_installer_power_loss install recovery_armed
[ ! -e "$LIVE_DROPIN" ] ||
  fail "armed boundary exposed the Pluto override early"
[ "$(cat "$BOOT_ENV_DIR/upgrade_available")" = 1 ] ||
  fail "armed boundary did not commit fallback"
boot_env sh "$INSTALLER" uninstall >/dev/null ||
  fail "could not recover armed installation boundary"

reset_boot_environment
expect_installer_power_loss install boot_override_durable
[ -f "$LIVE_DROPIN" ] || fail "override durable boundary lost override"
[ "$(cat "$BOOT_ENV_DIR/upgrade_available")" = 1 ] ||
  fail "override was durable without armed fallback"
boot_env sh "$INSTALLER" uninstall >/dev/null ||
  fail "could not recover override durable boundary"

# A normal activation error runs the rollback transaction: publish stock,
# disarm flag-last, then remove the rootfs recovery assets.
reset_boot_environment
if PLUTO_TEST_FAILURE_AT=boot_override_publish \
    boot_env sh "$INSTALLER" install > "$TMP/rollback.out" 2>&1; then
  fail "injected boot-override activation failure was accepted"
fi
[ ! -e "$LIVE_DROPIN" ] || fail "activation rollback retained override"
[ "$(cat "$BOOT_ENV_DIR/upgrade_available")" = 0 ] ||
  fail "activation rollback retained armed recovery"
[ ! -e "$RECOVERY_HANDLER" ] && [ ! -e "$RECOVERY_CONFIG" ] &&
  [ ! -e "$RECOVERY_UNIT" ] ||
  fail "activation rollback retained rootfs recovery artifacts"
unset PLUTO_TEST_FAILURE_AT

# Uninstall keeps recovery armed until the stock override is durable, and does
# not remove rootfs recovery assets until after the disarm commit.
reset_boot_environment
boot_env sh "$INSTALLER" install >/dev/null ||
  fail "fixture install before uninstall fault failed"
expect_installer_power_loss uninstall stock_override_durable
[ ! -e "$LIVE_DROPIN" ] || fail "stock durable boundary retained override"
[ "$(cat "$BOOT_ENV_DIR/upgrade_available")" = 1 ] ||
  fail "stock durable boundary disarmed too early"
[ -x "$RECOVERY_HANDLER" ] && [ -f "$RECOVERY_CONFIG" ] ||
  fail "stock durable boundary removed recovery assets early"
boot_env sh "$INSTALLER" uninstall >/dev/null ||
  fail "could not resume stock durable uninstall"

reset_boot_environment
boot_env sh "$INSTALLER" install >/dev/null ||
  fail "fixture reinstall before disarm fault failed"
expect_installer_power_loss uninstall recovery_disarmed
[ ! -e "$LIVE_DROPIN" ] || fail "disarm boundary retained override"
[ "$(cat "$BOOT_ENV_DIR/upgrade_available")" = 0 ] ||
  fail "disarm boundary did not clear fallback"
[ -x "$RECOVERY_HANDLER" ] && [ -f "$RECOVERY_CONFIG" ] ||
  fail "disarm boundary removed recovery assets before its commit"
boot_env sh "$INSTALLER" uninstall >/dev/null ||
  fail "could not resume disarm boundary uninstall"

# Move can still be staged and explicitly run, but boot-default activation is
# fail-closed until its failure/reboot behavior is measured on hardware.
reset_boot_environment
PLUTO_TEST_PROFILE_ID=move boot_env sh "$INSTALLER" validate >/dev/null ||
  fail "Move manual/no-boot-default payload staging was rejected"
if PLUTO_TEST_PROFILE_ID=move boot_env sh "$INSTALLER" install \
    > "$TMP/move-install.out" 2>&1; then
  fail "Move accepted boot-default activation with unverified failure recovery"
fi
grep -q 'boot default is gated off for move' "$TMP/move-install.out" ||
  fail "Move boot-default rejection did not explain the recovery gate"
[ ! -e "$LIVE_DROPIN" ] || fail "Move gate wrote a boot override"
[ ! -s "$BOOT_SET_LOG" ] || fail "Move gate mutated U-Boot state"
PLUTO_TEST_PROFILE_ID=move boot_env sh "$INSTALLER" uninstall >/dev/null ||
  fail "Move no-boot-default stock staging failed"
[ ! -s "$BOOT_SET_LOG" ] ||
  fail "Move --no-boot-default path armed or disarmed recovery"
unset PLUTO_TEST_PROFILE_ID

# The same stock-staging path on a fresh RM root must not touch a vendor/stock
# U-Boot transaction that Pluto does not own.
reset_boot_environment
boot_env sh "$INSTALLER" uninstall >/dev/null ||
  fail "RM no-boot-default stock staging failed"
[ ! -s "$BOOT_SET_LOG" ] ||
  fail "fresh RM --no-boot-default path mutated U-Boot recovery"

# Full uninstall must delegate to that same A/B flow before deleting ROOT.
reset_boot_environment
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
