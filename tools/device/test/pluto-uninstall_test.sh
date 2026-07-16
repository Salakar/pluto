#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
UNINSTALLER="$HERE/../pluto-uninstall.sh"
TMP=${TMPDIR:-/tmp}
TMP=${TMP%/}/pluto-uninstall-test.$$
ROOT="$TMP/home/pluto"
RELEASES="$ROOT.releases"
DATA="$ROOT.data"
HOME_ROOT="$TMP/home"
SYSTEM_ROOT="$TMP/system"
BIN="$TMP/bin"
EVENTS="$TMP/events"
RUN_DIR="$TMP/run/pluto"
RUNTIME_UNITS="$TMP/run/systemd"
ONCE_UNIT="$RUNTIME_UNITS/pluto-session-once.service"

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
if [ "$*" = 'is-active --quiet pluto-session-once.service' ] &&
   [ "${PLUTO_TEST_ONCE_INACTIVE:-0}" = 1 ]; then
  exit 3
fi
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
  mkdir -p "$release/bin" "$release/share" "$DATA/appdata" "$DATA/logs" "$DATA/state" \
    "$DATA/staging" "$DATA/shared" "$RUN_DIR/screenshots" "$RUNTIME_UNITS"
  chmod 0700 "$RUN_DIR"
  printf 'launch\n' > "$RUN_DIR/launch"
  printf 'frame\n' > "$RUN_DIR/screenshots/frame.png"
  printf 'stale receipt\n' > "$RUN_DIR/rm2-cpufreq-burst"
  printf '[Service]\n' > "$ONCE_UNIT"
  printf '%s\n' "$id" > "$release/.pluto-release-owned"
  cat > "$release/share/device-profiles.sh" <<'PROFILES'
pluto_profile_load() {
  case "$1" in
    rm1) PLUTO_PROFILE_DISPLAY_DRIVER=mxcfb_epdc ;;
    rm2) PLUTO_PROFILE_DISPLAY_DRIVER=lcdif_tcon ;;
    move) PLUTO_PROFILE_DISPLAY_DRIVER=gallery3_drm ;;
    *) return 1 ;;
  esac
  export PLUTO_PROFILE_DISPLAY_DRIVER
}
pluto_profile_probe() { return 1; }
PROFILES
  for mutable in appdata logs state staging shared; do
    ln -s "$DATA/$mutable" "$release/$mutable"
  done
  cat > "$release/bin/pluto-boot-install.sh" <<'SCRIPT'
#!/bin/sh
[ "${1:-}" = uninstall ] || exit 64
"$PLUTO_ROOT/bin/pluto-rm2-cpufreq-restore.sh" || exit $?
[ "${PLUTO_TEST_BOOT_FAIL:-0}" != 1 ] || exit 74
printf 'boot-install uninstall\n' >> "$PLUTO_TEST_EVENTS"
exit 0
SCRIPT
  cat > "$release/bin/pluto-session-once.sh" <<'SCRIPT'
#!/bin/sh
[ "${1:-}" = stop ] || exit 64
"$PLUTO_ROOT/bin/pluto-rm2-cpufreq-restore.sh" || exit $?
rm -f "$PLUTO_SYSTEMD_RUNTIME_DIR/pluto-session-once.service"
printf 'session-once stop\n' >> "$PLUTO_TEST_EVENTS"
exit 0
SCRIPT
  cat > "$release/bin/pluto-rm2-cpufreq-restore.sh" <<'SCRIPT'
#!/bin/sh
printf 'cpufreq restore\n' >> "$PLUTO_TEST_EVENTS"
[ "${PLUTO_TEST_CPUFREQ_FAIL:-0}" != 1 ] || exit 74
rm -f "$PLUTO_RUN_DIR/rm2-cpufreq-burst"
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
    PLUTO_RUN_DIR="$RUN_DIR" \
    PLUTO_SYSTEMD_RUNTIME_DIR="$RUNTIME_UNITS" \
    PLUTO_TEST_EVENTS="$EVENTS" \
    PLUTO_TEST_ONCE_INACTIVE="${PLUTO_TEST_ONCE_INACTIVE:-0}" \
    PLUTO_TEST_CPUFREQ_FAIL="${PLUTO_TEST_CPUFREQ_FAIL:-0}" \
    PLUTO_TEST_BOOT_FAIL="${PLUTO_TEST_BOOT_FAIL:-0}" \
    PLUTO_TESTING=1 \
    PLUTO_TEST_PROFILE_ID="${PLUTO_TEST_PROFILE_ID:-rm2}" \
    PLUTO_UNINSTALL_REEXEC=1 \
    sh "$UNINSTALLER" --yes "$@"
}

make_layout first
mkdir -p "$RELEASES/unowned" "$DATA/unowned"
printf 'release-neighbor\n' > "$RELEASES/unowned/user-file"
printf 'data-neighbor\n' > "$DATA/unowned/user-file"
: > "$EVENTS"
if ! run_uninstall; then
  [ ! -f "$HOME_ROOT/pluto-uninstall.log" ] ||
    cat "$HOME_ROOT/pluto-uninstall.log" >&2
  fail 'exact owned uninstall failed'
fi

[ ! -e "$ROOT" ] && [ ! -L "$ROOT" ] || fail "active release link remains: $ROOT"
[ ! -e "$RUN_DIR" ] && [ ! -L "$RUN_DIR" ] ||
  fail "runtime controls/screenshots/receipts remain: $RUN_DIR"
[ ! -e "$ONCE_UNIT" ] && [ ! -L "$ONCE_UNIT" ] ||
  fail "transient one-shot unit remains: $ONCE_UNIT"
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
[ ! -e "$RUN_DIR" ] && [ ! -e "$ONCE_UNIT" ] ||
  fail '--keep-data left ephemeral runtime residue'

# An inactive but stale runtime unit is removed by the same one-shot helper;
# service activity is not used as a reason to leave an alternate launch path.
make_layout inactive_once
: > "$EVENTS"
PLUTO_TEST_ONCE_INACTIVE=1 run_uninstall
grep -q '^session-once stop$' "$EVENTS" ||
  fail 'inactive stale one-shot unit was not retired'
[ ! -e "$ONCE_UNIT" ] || fail 'inactive stale one-shot unit remains'
unset PLUTO_TEST_ONCE_INACTIVE

# A restorer failure is terminal: retain the exact runtime, diagnostic receipt,
# and owned release, and do not fall through to the live-slot stock fallback.
make_layout restore_failure
: > "$EVENTS"
if PLUTO_TEST_CPUFREQ_FAIL=1 run_uninstall >/dev/null 2>&1; then
  fail 'cpufreq restore failure was accepted'
fi
[ -L "$ROOT" ] && [ -d "$RELEASES/restore_failure" ] &&
  [ -f "$RUN_DIR/rm2-cpufreq-burst" ] ||
  fail 'cpufreq failure did not preserve runtime and receipt'
if grep -q '^boot-install uninstall$' "$EVENTS"; then
  fail 'cpufreq failure continued into boot restoration'
fi
rm -rf "$RUN_DIR" "$RUNTIME_UNITS"
rm -f "$ROOT"
rm -rf "$RELEASES/restore_failure" "$DATA"

# An authoritative boot-uninstall failure is never reinterpreted as a missing
# installer and cannot enter the weaker live-slot fallback.
make_layout boot_failure
: > "$EVENTS"
if PLUTO_TEST_BOOT_FAIL=1 run_uninstall >/dev/null 2>&1; then
  fail 'boot transaction failure was accepted'
fi
[ -L "$ROOT" ] && [ -d "$RELEASES/boot_failure" ] ||
  fail 'boot transaction failure deleted the owned runtime'
if grep -q '^systemctl stop xochitl.service$' "$EVENTS"; then
  fail 'boot transaction failure entered the live-slot fallback'
fi
rm -rf "$RUN_DIR" "$RUNTIME_UNITS"
rm -f "$ROOT"
rm -rf "$RELEASES/boot_failure" "$DATA"

# Unsafe ephemeral roots are rejected before the session, boot, or display
# state is touched.
make_layout unsafe_run
rm -rf "$RUN_DIR"
ln -s "$TMP/outside" "$RUN_DIR"
: > "$EVENTS"
if run_uninstall >/dev/null 2>&1; then
  fail 'symlinked runtime directory was accepted'
fi
[ -L "$ROOT" ] && [ -d "$RELEASES/unsafe_run" ] ||
  fail 'unsafe runtime path partially deleted the release'
[ ! -s "$EVENTS" ] || fail 'unsafe runtime path changed service or boot state'
rm -f "$RUN_DIR" "$ROOT"
rm -rf "$RELEASES/unsafe_run" "$DATA" "$RUNTIME_UNITS"

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
