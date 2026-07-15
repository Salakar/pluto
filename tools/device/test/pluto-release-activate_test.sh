#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTIVATOR="$HERE/../pluto-release-activate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/pluto"
RELEASES="$ROOT.releases"
DATA="$ROOT.data"
SYSTEM_ROOT="$TMP/system"
DROPIN="$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d/zz-pluto.conf"
RUN="$TMP/run"
EVENTS="$TMP/events"
ONCE_STATE="$TMP/once-state"

fail() {
  echo "pluto-release-activate_test: FAIL: $*" >&2
  [[ ! -f "$EVENTS" ]] || cat "$EVENTS" >&2
  exit 1
}

if mv --help 2>&1 | grep -q -- '-T'; then
  ATOMIC_MV=mv
elif command -v gmv >/dev/null 2>&1; then
  ATOMIC_MV="$(command -v gmv)"
else
  fail 'test host has no mv implementation with atomic -T replacement'
fi

mkdir -p "$RELEASES" "$DATA" "$RUN" \
  "$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d" "$TMP/bin"
for mutable in appdata logs state staging shared; do
  mkdir -p "$DATA/$mutable"
done
: > "$EVENTS"

cat > "$TMP/bin/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$PLUTO_TEST_EVENTS"
case "$1:$2" in
  is-active:--quiet)
    unit=$3
    case "$unit" in
      pluto-session-once.service)
        [ "$(cat "$PLUTO_TEST_ONCE_STATE" 2>/dev/null || true)" = active ]
        ;;
      xochitl.service) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  restart:xochitl.service|reset-failed:xochitl.service) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod 755 "$TMP/bin/systemctl"

make_release() {
  local id="$1"
  local release="$RELEASES/$id"
  mkdir -p "$release/bin" "$release/engine/release" \
    "$release/launcher/bundle/lib" "$release/share" "$release/apps/standard"
  printf '%s\n' "$id" > "$release/.pluto-release-owned"
  printf '%s\n' "$id" > "$release/release-id"
  printf 'embedder-%s\n' "$id" > "$release/bin/pluto-embedder"
  printf 'engine-%s\n' "$id" > "$release/engine/release/libflutter_engine.so"
  printf 'launcher-%s\n' "$id" > "$release/launcher/bundle/lib/app.so"
  printf '{"id":"dev.pluto.launcher"}\n' > "$release/launcher/manifest.json"
  printf 'app-%s\n' "$id" > "$release/apps/standard/payload"
  printf '# profile %s\n' "$id" > "$release/share/device-profiles.sh"
  cp "$ACTIVATOR" "$release/bin/pluto-release-activate.sh"
  cat > "$release/bin/pluto-session.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat > "$release/bin/pluto-session-once.sh" <<'EOF'
#!/bin/sh
id=$(cat "$PLUTO_ROOT/release-id")
printf 'once %s %s\n' "$id" "$1" >> "$PLUTO_TEST_EVENTS"
case "$1" in
  start) printf 'active\n' > "$PLUTO_TEST_ONCE_STATE" ;;
  stop) rm -f "$PLUTO_TEST_ONCE_STATE" ;;
  *) exit 64 ;;
esac
EOF
  cat > "$release/bin/pluto-boot-install.sh" <<'EOF'
#!/bin/sh
id=$(cat "$PLUTO_ROOT/release-id")
printf 'boot %s %s\n' "$id" "$1" >> "$PLUTO_TEST_EVENTS"
case "$1" in
  install)
    mkdir -p "$(dirname "$PLUTO_TEST_DROPIN")"
    printf '%s\n' "$id" > "$PLUTO_TEST_DROPIN"
    ;;
  uninstall) rm -f "$PLUTO_TEST_DROPIN" ;;
  *) exit 64 ;;
esac
EOF
  chmod 755 "$release/bin"/*.sh "$release/bin/pluto-embedder"
  for mutable in appdata logs state staging shared; do
    ln -s "$DATA/$mutable" "$release/$mutable"
  done
}

run_activation() {
  local candidate="$1" mode="$2" failure="${3:-}"
  PLUTO_ROOT_LINK="$ROOT" \
  PLUTO_RELEASES_ROOT="$RELEASES" \
  PLUTO_DATA_ROOT="$DATA" \
  PLUTO_RUN_DIR="$RUN" \
  PLUTO_SYSTEM_ROOT="$SYSTEM_ROOT" \
  PLUTO_SYSTEMCTL="$TMP/bin/systemctl" \
  PLUTO_SYNC=/usr/bin/true \
  PLUTO_MV="$ATOMIC_MV" \
  PLUTO_RM="${PLUTO_TEST_RM:-rm}" \
  PLUTO_TESTING=1 \
  PLUTO_TEST_FAILURE_AT="$failure" \
  PLUTO_TEST_EVENTS="$EVENTS" \
  PLUTO_TEST_ONCE_STATE="$ONCE_STATE" \
  PLUTO_TEST_DROPIN="$DROPIN" \
    sh "$candidate/bin/pluto-release-activate.sh" \
      activate "$candidate" "$mode"
}

make_release old
make_release interrupted
ln -s "$RELEASES/old" "$ROOT"
printf 'old\n' > "$DROPIN"

# An interruption after the one atomic root flip must restore the complete old
# runtime/app pair and its active persistent policy. No file-by-file hybrid is
# representable through ROOT.
if run_activation "$RELEASES/interrupted" persistent after_switch \
  > "$TMP/interrupted.log" 2>&1; then
  fail 'injected post-switch interruption unexpectedly succeeded'
fi
[[ "$(readlink "$ROOT")" == "$RELEASES/old" ]] ||
  fail 'interrupted activation did not restore the old root link'
[[ "$(cat "$ROOT/bin/pluto-embedder")" == embedder-old ]] ||
  fail 'interrupted activation exposed a new runtime under the old release'
[[ "$(cat "$ROOT/apps/standard/payload")" == app-old ]] ||
  fail 'interrupted activation exposed a new app under the old release'
[[ "$(cat "$DROPIN")" == old ]] ||
  fail 'interrupted activation did not restore persistent ownership'
grep -q '^boot old uninstall$' "$EVENTS" ||
  fail 'active old persistent Pluto was not retired before switching'
grep -q '^boot old install$' "$EVENTS" ||
  fail 'active old persistent Pluto was not restored after interruption'

# A currently active transient Pluto session gets the same rollback guarantee.
rm -f "$DROPIN"
printf 'active\n' > "$ONCE_STATE"
: > "$EVENTS"
if run_activation "$RELEASES/interrupted" transient after_policy \
  > "$TMP/transient-interrupted.log" 2>&1; then
  fail 'injected transient policy interruption unexpectedly succeeded'
fi
[[ "$(readlink "$ROOT")" == "$RELEASES/old" ]] ||
  fail 'active transient rollback did not restore the old release'
[[ "$(cat "$ONCE_STATE")" == active ]] ||
  fail 'active transient rollback did not restart the old session'
grep -q '^once old stop$' "$EVENTS" ||
  fail 'old transient session was not stopped before the release flip'
grep -q '^once interrupted start$' "$EVENTS" ||
  fail 'new transient session was not started after the release flip'
grep -q '^once interrupted stop$' "$EVENTS" ||
  fail 'failed new transient session was not stopped during rollback'
grep -q '^once old start$' "$EVENTS" ||
  fail 'old transient session was not restored after rollback'

# Successful activation removes only prior/interrupted directories carrying a
# matching ownership marker. An unrelated sibling is never guessed to be ours.
rm -f "$ONCE_STATE"
make_release final
mkdir -p "$RELEASES/.candidate-stale" "$RELEASES/orphan" "$RELEASES/unowned"
printf 'stale\n' > "$RELEASES/.candidate-stale/.pluto-release-owned"
printf 'orphan\n' > "$RELEASES/orphan/.pluto-release-owned"
printf 'keep\n' > "$RELEASES/unowned/user-file"
: > "$EVENTS"
run_activation "$RELEASES/final" transient > "$TMP/final.log"
[[ "$(readlink "$ROOT")" == "$RELEASES/final" ]] ||
  fail 'successful activation did not expose the final complete release'
[[ "$(cat "$ROOT/bin/pluto-embedder")" == embedder-final ]] ||
  fail 'final runtime does not come from the active release'
[[ "$(cat "$ROOT/apps/standard/payload")" == app-final ]] ||
  fail 'final app does not come from the active release'
[[ "$(cat "$ONCE_STATE")" == active ]] ||
  fail 'final transient session is not active'
for removed in old interrupted .candidate-stale orphan; do
  [[ ! -e "$RELEASES/$removed" ]] ||
    fail "owned stale release survived successful activation: $removed"
done
[[ "$(cat "$RELEASES/unowned/user-file")" == keep ]] ||
  fail 'safe release GC deleted an unowned sibling'

# GC is maintenance after the atomic commit. A deletion failure must leave the
# new complete release active and return success with an exact warning; claiming
# rollback here would make the host's view disagree with the device.
make_release gcwarn
cat > "$TMP/bin/rm-gc-fail" <<EOF
#!/bin/sh
for arg in "\$@"; do
  [ "\$arg" != "$RELEASES/final" ] || exit 1
done
exec rm "\$@"
EOF
chmod 755 "$TMP/bin/rm-gc-fail"
: > "$EVENTS"
PLUTO_TEST_RM="$TMP/bin/rm-gc-fail" \
  run_activation "$RELEASES/gcwarn" transient > "$TMP/gcwarn.log" 2>&1 ||
  fail 'post-commit GC failure was incorrectly reported as activation failure'
[[ "$(readlink "$ROOT")" == "$RELEASES/gcwarn" ]] ||
  fail 'post-commit GC failure changed the committed active release'
[[ -d "$RELEASES/final" ]] ||
  fail 'GC failure fixture unexpectedly removed the prior release'
grep -q 'WARNING: complete release is active; owned stale release cleanup' \
  "$TMP/gcwarn.log" || fail 'post-commit GC failure did not report an exact warning'
grep -q '^PLUTO-RELEASE-ACTIVE|' "$TMP/gcwarn.log" ||
  fail 'post-commit GC failure omitted the committed active-release receipt'

echo 'pluto-release-activate_test: PASS'
