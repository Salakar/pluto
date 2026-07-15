#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
UNINSTALLER="$HERE/../pluto-uninstall.sh"
TMP=${TMPDIR:-/tmp}/pluto-uninstall-test.$$
ROOT="$TMP/home/pluto"
RELEASES="$ROOT.releases"
DATA="$ROOT.data"
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
  "$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d" \
  "$BIN"

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
chmod 0755 "$BIN/systemctl" "$BIN/pkill"

printf 'stock override\n' > \
  "$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d/90-stock.conf"

make_layout() {
  id=$1
  release="$RELEASES/$id"
  mkdir -p "$release/bin" "$DATA/appdata" "$DATA/logs" "$DATA/state" \
    "$DATA/staging" "$DATA/shared"
  printf '%s\n' "$id" > "$release/.pluto-release-owned"
  for mutable in appdata logs state staging shared; do
    ln -s "$DATA/$mutable" "$release/$mutable"
  done
  cat > "$release/bin/pluto-boot-install.sh" <<'SCRIPT'
#!/bin/sh
[ "${1:-}" = uninstall ] || exit 64
printf 'boot-install uninstall\n' >> "$PLUTO_TEST_EVENTS"
exit 0
SCRIPT
  cat > "$release/bin/pluto-session-once.sh" <<'SCRIPT'
#!/bin/sh
[ "${1:-}" = stop ] || exit 64
printf 'session-once stop\n' >> "$PLUTO_TEST_EVENTS"
exit 0
SCRIPT
  chmod 0755 "$release/bin"/*.sh
  ln -s "$release" "$ROOT"
}

run_uninstall() {
  env \
    PATH="$BIN:$PATH" \
    PLUTO_ROOT="$ROOT" \
    PLUTO_RELEASES_ROOT="$RELEASES" \
    PLUTO_DATA_ROOT="$DATA" \
    PLUTO_HOME_ROOT="$HOME_ROOT" \
    PLUTO_SYSTEM_ROOT="$SYSTEM_ROOT" \
    PLUTO_SYSTEMCTL="$BIN/systemctl" \
    PLUTO_TEST_EVENTS="$EVENTS" \
    PLUTO_UNINSTALL_REEXEC=1 \
    sh "$UNINSTALLER" --yes "$@"
}

make_layout first
mkdir -p "$RELEASES/unowned" "$DATA/unowned"
printf 'release-neighbor\n' > "$RELEASES/unowned/user-file"
printf 'data-neighbor\n' > "$DATA/unowned/user-file"
: > "$EVENTS"
run_uninstall

[ ! -e "$ROOT" ] && [ ! -L "$ROOT" ] || fail "active release link remains: $ROOT"
[ ! -e "$RELEASES/first" ] || fail "owned release remains: $RELEASES/first"
[ "$(cat "$RELEASES/unowned/user-file")" = release-neighbor ] ||
  fail 'uninstaller deleted an unowned release-store sibling'
[ "$(cat "$DATA/unowned/user-file")" = data-neighbor ] ||
  fail 'uninstaller deleted an unowned data-root sibling'
[ -f "$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d/90-stock.conf" ] ||
  fail 'unrelated stock drop-in was removed'
grep -q '^boot-install uninstall$' "$EVENTS" ||
  fail 'stock boot restoration did not run'
grep -q '^session-once stop$' "$EVENTS" ||
  fail 'current-boot Pluto session was not retired'
ONCE_LINE=$(grep -n '^session-once stop$' "$EVENTS" | cut -d: -f1)
BOOT_LINE=$(grep -n '^boot-install uninstall$' "$EVENTS" | cut -d: -f1)
[ "$ONCE_LINE" -lt "$BOOT_LINE" ] ||
  fail 'current-boot session remained active during boot restoration'
grep -q '^systemctl is-active --quiet xochitl.service$' "$EVENTS" ||
  fail 'stock display service was not verified after uninstall'
rm -rf "$RELEASES/unowned" "$DATA/unowned"
rmdir "$RELEASES" "$DATA"

# --keep-data moves the actual persistent directories, never the release's
# symlinks, and still removes every owned runtime/data residue.
make_layout keep
mkdir -p "$DATA/appdata/dev.example.notes" "$DATA/shared/documents"
printf 'note\n' > "$DATA/appdata/dev.example.notes/note.txt"
printf 'shared\n' > "$DATA/shared/documents/shared.txt"
printf 'discard\n' > "$DATA/state/runtime-state"
: > "$EVENTS"
run_uninstall --keep-data
backup=$(find "$HOME_ROOT" -maxdepth 1 -type d -name 'pluto-data-backup-*' -print -quit)
[ -n "$backup" ] || fail '--keep-data did not create a backup'
[ "$(cat "$backup/appdata/dev.example.notes/note.txt")" = note ] ||
  fail '--keep-data did not preserve actual appdata'
[ "$(cat "$backup/shared/documents/shared.txt")" = shared ] ||
  fail '--keep-data did not preserve actual shared data'
[ ! -L "$backup/appdata" ] && [ ! -L "$backup/shared" ] ||
  fail '--keep-data backed up release symlinks instead of actual data'
[ ! -e "$ROOT" ] && [ ! -e "$RELEASES" ] && [ ! -e "$DATA" ] ||
  fail '--keep-data left owned runtime/store/data residue'

# Destructive removal is fail-closed if any ownership edge is inexact.
make_layout inexact
printf 'wrong-owner\n' > "$RELEASES/inexact/.pluto-release-owned"
: > "$EVENTS"
if run_uninstall >/dev/null 2>&1; then
  fail 'inexact release ownership was accepted'
fi
[ -L "$ROOT" ] && [ -d "$RELEASES/inexact" ] && [ -d "$DATA" ] ||
  fail 'inexact layout was partially deleted'
[ ! -s "$EVENTS" ] || fail 'boot/display state changed before ownership validation'

printf 'PASS: Pluto uninstall restores stock and removes exact owned release/store/data\n'
