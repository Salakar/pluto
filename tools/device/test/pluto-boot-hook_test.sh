#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
HOOK="$HERE/../pluto-boot-hook.sh"
TMP=${TMPDIR:-/tmp}/pluto-boot-hook-test.$$
ROOT="$TMP/root"
RUN_DIR="$TMP/run"
RESULT="$TMP/result"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup 0

fail() {
  echo "boot-hook supervisor test: $*" >&2
  exit 1
}

mkdir -p "$ROOT/bin" "$ROOT/state" "$ROOT/logs" "$RUN_DIR"
printf 'launcher\n' > "$ROOT/state/boot-mode"

cat > "$ROOT/bin/pluto-fingerprint-check.sh" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
cat > "$ROOT/bin/pluto-bootloop-check.sh" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
cat > "$ROOT/bin/pluto-session.sh" <<'SCRIPT'
#!/bin/sh
printf 'session:%s\n' "${1:-}" > "$PLUTO_TEST_RESULT"
SCRIPT
cat > "$ROOT/bin/plutod" <<'SCRIPT'
#!/bin/sh
printf 'plutod\n' > "$PLUTO_TEST_RESULT"
SCRIPT
chmod +x "$ROOT/bin/"*.sh "$ROOT/bin/plutod"

PLUTO_ROOT="$ROOT" \
PLUTO_RUN_DIR="$RUN_DIR" \
PLUTO_TEST_RESULT="$RESULT" \
  sh "$HOOK" launch-launcher

[ -f "$RESULT" ] || fail "boot hook did not execute a supervisor"
[ "$(cat "$RESULT")" = 'session:start' ] ||
  fail "stale plutod took precedence over the canonical session supervisor"

echo "boot-hook supervisor test: PASS"
