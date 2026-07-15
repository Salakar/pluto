#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
UNINSTALLER="$HERE/../pluto-uninstall.sh"
TMP=${TMPDIR:-/tmp}/pluto-uninstall-test.$$
ROOT="$TMP/home/pluto"
HOME_ROOT="$TMP/home"
SYSTEM_ROOT="$TMP/system"
BIN="$TMP/bin"
EVENTS="$TMP/events"

cleanup() { rm -rf "$TMP"; }
trap cleanup 0

fail() {
  printf 'pluto uninstall test: %s\n' "$*" >&2
  exit 1
}

mkdir -p \
  "$ROOT/bin" \
  "$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d" \
  "$BIN"

cat > "$ROOT/bin/pluto-boot-install.sh" <<'SCRIPT'
#!/bin/sh
[ "${1:-}" = uninstall ] || exit 64
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
chmod 0755 \
  "$ROOT/bin/pluto-boot-install.sh" \
  "$BIN/systemctl" \
  "$BIN/pkill"

printf 'stock override\n' > \
  "$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d/90-stock.conf"
: > "$EVENTS"

env \
  PATH="$BIN:$PATH" \
  PLUTO_ROOT="$ROOT" \
  PLUTO_HOME_ROOT="$HOME_ROOT" \
  PLUTO_SYSTEM_ROOT="$SYSTEM_ROOT" \
  PLUTO_SYSTEMCTL="$BIN/systemctl" \
  PLUTO_TEST_EVENTS="$EVENTS" \
  PLUTO_UNINSTALL_REEXEC=1 \
  sh "$UNINSTALLER" --yes

[ ! -e "$ROOT" ] && [ ! -L "$ROOT" ] || fail "runtime remains: $ROOT"
[ -f "$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d/90-stock.conf" ] ||
  fail 'unrelated stock drop-in was removed'
grep -q '^boot-install uninstall$' "$EVENTS" ||
  fail 'stock boot restoration did not run'
grep -q '^systemctl is-active --quiet xochitl.service$' "$EVENTS" ||
  fail 'stock display service was not verified after uninstall'

printf 'PASS: Pluto uninstall restores stock and removes the runtime\n'
