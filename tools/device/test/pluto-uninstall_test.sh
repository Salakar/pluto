#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
UNINSTALLER="$HERE/../pluto-uninstall.sh"
TMP=${TMPDIR:-/tmp}/pluto-uninstall-test.$$
ROOT="$TMP/home/pluto"
HOME_ROOT="$TMP/home"
SYSTEM_ROOT="$TMP/system"
RUN_ROOT="$TMP/run/pluto"
TMP_ROOT="$TMP/tmp"
BIN="$TMP/bin"
EVENTS="$TMP/events"

cleanup() { rm -rf "$TMP"; }
trap cleanup 0

fail() {
  printf 'pluto uninstall test: %s\n' "$*" >&2
  exit 1
}

assert_absent() {
  [ ! -e "$1" ] && [ ! -L "$1" ] || fail "residue remains: $1"
}

mkdir -p \
  "$ROOT/bin" \
  "$HOME_ROOT/xovi/exthome/appload/pluto" \
  "$HOME_ROOT/pluto-arm" \
  "$HOME_ROOT/.pluto-xovi-stage" \
  "$HOME_ROOT/.pluto-integration-receipt" \
  "$HOME_ROOT/.pluto-no-integration-stage" \
  "$HOME_ROOT/.pluto-uninstall-ledger" \
  "$HOME_ROOT/.pluto-restart-ledger" \
  "$SYSTEM_ROOT/etc/systemd/system/xochitl.service.d" \
  "$SYSTEM_ROOT/run/systemd/system/xochitl.service.d" \
  "$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d" \
  "$RUN_ROOT/integration-provision.lock" \
  "$TMP_ROOT" \
  "$BIN"

cat > "$ROOT/bin/pluto-boot-install.sh" <<'SCRIPT'
#!/bin/sh
[ "${1:-}" = uninstall ] || exit 64
for forbidden in \
  "$PLUTO_TEST_HOME_ROOT/xovi" \
  "$PLUTO_TEST_HOME_ROOT/pluto-arm" \
  "$PLUTO_TEST_HOME_ROOT/.pluto-xovi-stage" \
  "$PLUTO_TEST_RUN_ROOT/appload-control.sock" \
  "$PLUTO_TEST_RUN_ROOT/integration-provision.lock" \
  "$PLUTO_TEST_TMP_ROOT/qtfb.sock" \
  "$PLUTO_TEST_XOVI_DROPIN" \
  "$PLUTO_TEST_APPLOAD_DROPIN" \
  "$PLUTO_TEST_QTFB_DROPIN"; do
  [ ! -e "$forbidden" ] && [ ! -L "$forbidden" ] || {
    printf 'boot restore observed legacy residue: %s\n' "$forbidden" >&2
    exit 70
  }
done
printf 'boot-install uninstall\n' >> "$PLUTO_TEST_EVENTS"
exit 0
SCRIPT
cat > "$BIN/systemctl" <<'SCRIPT'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$PLUTO_TEST_EVENTS"
exit 0
SCRIPT
cat > "$BIN/pkill" <<'SCRIPT'
#!/bin/sh
printf 'pkill %s\n' "$*" >> "$PLUTO_TEST_EVENTS"
exit 1
SCRIPT
cat > "$BIN/umount" <<'SCRIPT'
#!/bin/sh
printf 'umount %s\n' "$*" >> "$PLUTO_TEST_EVENTS"
exit 1
SCRIPT
chmod 0755 \
  "$ROOT/bin/pluto-boot-install.sh" \
  "$BIN/systemctl" \
  "$BIN/pkill" \
  "$BIN/umount"

printf 'load xovi extension\n' > \
  "$SYSTEM_ROOT/etc/systemd/system/xochitl.service.d/10-xovi.conf"
printf 'start appload\n' > \
  "$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d/20-appload.conf"
printf 'connect qtfb\n' > \
  "$SYSTEM_ROOT/run/systemd/system/xochitl.service.d/30-qtfb.conf"
printf 'stock override\n' > \
  "$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d/90-stock.conf"
: > "$RUN_ROOT/appload-control.sock"
: > "$RUN_ROOT/integration-provision.lock/owner"
: > "$TMP_ROOT/qtfb.sock"
: > "$TMP_ROOT/qtfb.sock.legacy"
: > "$EVENTS"

env \
  PATH="$BIN:$PATH" \
  PLUTO_ROOT="$ROOT" \
  PLUTO_HOME_ROOT="$HOME_ROOT" \
  PLUTO_SYSTEM_ROOT="$SYSTEM_ROOT" \
  PLUTO_SYSTEMCTL="$BIN/systemctl" \
  PLUTO_UMOUNT="$BIN/umount" \
  PLUTO_RUN_ROOT="$RUN_ROOT" \
  PLUTO_TMP_ROOT="$TMP_ROOT" \
  PLUTO_TEST_EVENTS="$EVENTS" \
  PLUTO_TEST_HOME_ROOT="$HOME_ROOT" \
  PLUTO_TEST_RUN_ROOT="$RUN_ROOT" \
  PLUTO_TEST_TMP_ROOT="$TMP_ROOT" \
  PLUTO_TEST_XOVI_DROPIN="$SYSTEM_ROOT/etc/systemd/system/xochitl.service.d/10-xovi.conf" \
  PLUTO_TEST_APPLOAD_DROPIN="$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d/20-appload.conf" \
  PLUTO_TEST_QTFB_DROPIN="$SYSTEM_ROOT/run/systemd/system/xochitl.service.d/30-qtfb.conf" \
  PLUTO_UNINSTALL_REEXEC=1 \
  sh "$UNINSTALLER" --yes

for forbidden in \
  "$ROOT" \
  "$HOME_ROOT/xovi" \
  "$HOME_ROOT/pluto-arm" \
  "$HOME_ROOT/.pluto-xovi-stage" \
  "$HOME_ROOT/.pluto-integration-receipt" \
  "$HOME_ROOT/.pluto-no-integration-stage" \
  "$HOME_ROOT/.pluto-uninstall-ledger" \
  "$HOME_ROOT/.pluto-restart-ledger" \
  "$SYSTEM_ROOT/etc/systemd/system/xochitl.service.d/10-xovi.conf" \
  "$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d/20-appload.conf" \
  "$SYSTEM_ROOT/run/systemd/system/xochitl.service.d/30-qtfb.conf" \
  "$RUN_ROOT/appload-control.sock" \
  "$RUN_ROOT/integration-provision.lock" \
  "$TMP_ROOT/qtfb.sock" \
  "$TMP_ROOT/qtfb.sock.legacy"; do
  assert_absent "$forbidden"
done

[ -f "$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d/90-stock.conf" ] ||
  fail 'unrelated stock drop-in was removed'
grep -q '^boot-install uninstall$' "$EVENTS" ||
  fail 'stock boot restoration did not run'
cleanup_line=$(grep -n '^umount ' "$EVENTS" | sed -n '1s/:.*//p')
restore_line=$(grep -n '^boot-install uninstall$' "$EVENTS" | sed -n '1s/:.*//p')
[ -n "$cleanup_line" ] && [ -n "$restore_line" ] &&
  [ "$cleanup_line" -lt "$restore_line" ] ||
  fail 'legacy cleanup did not precede stock boot restoration'
grep -q '^systemctl is-active --quiet xochitl.service$' "$EVENTS" ||
  fail 'stock display service was not verified after cleanup'

if sh "$UNINSTALLER" --remove-xovi >/dev/null 2>&1; then
  fail 'removed compatibility flag is still accepted'
fi

printf 'PASS: Pluto uninstall hard-removes retired display integration\n'
