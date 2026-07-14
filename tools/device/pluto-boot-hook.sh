#!/bin/sh
# Device-side Pluto boot/AppLoad entry point.
#
# This script is intentionally small and conservative: it only stops xochitl
# immediately before launching Pluto's own DRM presenter, and it exits to
# stock behavior on any safety failure.
set -eu

ROOT="${PLUTO_ROOT:-/home/root/pluto}"
STATE="$ROOT/state"
LOGS="$ROOT/logs"
MODE_FILE="$STATE/boot-mode"
DISABLED="$STATE/boot-disabled"
REASON="$STATE/safe-mode-reason"

mkdir -p "$STATE" "$LOGS"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOGS/boot-hook.log" 2>/dev/null || true
}

latch_safe_mode() {
  reason="$1"
  printf '%s\n' "$reason" > "$REASON.tmp"
  mv "$REASON.tmp" "$REASON"
  : > "$DISABLED"
  log "safe-mode latched: $reason"
}

dry_run() {
  [ "${PLUTO_DRY_RUN:-0}" = "1" ]
}

if [ -f "$DISABLED" ]; then
  log "safe mode already latched; exiting"
  exit 0
fi

MODE="$(cat "$MODE_FILE" 2>/dev/null || printf '%s\n' stock)"
case "$MODE" in
  launcher|stock) ;;
  disabled) exit 0 ;;
  *)
    log "unknown boot-mode '$MODE'; treating as stock"
    MODE=stock
    ;;
esac

if ! "$ROOT/bin/pluto-fingerprint-check.sh"; then
  latch_safe_mode "fingerprint-mismatch"
  exit 0
fi

case "${1:-}" in
  launch-launcher)
    if ! "$ROOT/bin/pluto-bootloop-check.sh" launcher; then
      latch_safe_mode "launcher-crash-loop"
      exit 0
    fi
    if dry_run; then
      printf 'would launch the Pluto session supervisor under %s\n' "$ROOT"
      exit 0
    fi
    export PLUTO_RUN_DIR="${PLUTO_RUN_DIR:-/run/pluto}"
    export PLUTO_APPS_DIR="${PLUTO_APPS_DIR:-$ROOT/apps}"
    export PLUTO_DATA_DIR="${PLUTO_DATA_DIR:-$ROOT/appdata}"
    export PLUTO_CONFIG_DIR="${PLUTO_CONFIG_DIR:-$ROOT/state/launcher-config}"
    export PLUTO_APP_ID="${PLUTO_APP_ID:-dev.pluto.launcher}"
    mkdir -p "$PLUTO_RUN_DIR" "$PLUTO_APPS_DIR" "$PLUTO_DATA_DIR" "$PLUTO_CONFIG_DIR"
    rm -f "$PLUTO_RUN_DIR/launch" "$PLUTO_RUN_DIR/home" "$PLUTO_RUN_DIR/stock"
    # The shell supervisor is the canonical, parity-tested implementation for
    # AOT mode selection, launch handoffs, and power-key standby. Never let a
    # stale experimental plutod binary silently bypass those contracts.
    if [ -x "$ROOT/bin/pluto-session.sh" ]; then
      exec "$ROOT/bin/pluto-session.sh" start
    fi
    if [ -x "$ROOT/bin/plutod" ]; then
      exec "$ROOT/bin/plutod" \
        --root="$ROOT" \
        --socket="$STATE/plutod.sock" \
        --launcher-app-dir="$ROOT/launcher"
    fi
    systemctl reset-failed xochitl.service 2>/dev/null || true
    systemctl stop xochitl.service 2>/dev/null || true
    sleep 0.3
    launcher_aot=""
    if [ -f "$ROOT/launcher/bundle/lib/app.so" ]; then
      launcher_aot="$ROOT/launcher/bundle/lib/app.so"
    elif [ -f "$ROOT/launcher/bundle/app.so" ]; then
      launcher_aot="$ROOT/launcher/bundle/app.so"
    fi
    if [ -n "$launcher_aot" ]; then
      exec "$ROOT/bin/pluto-embedder" \
        --release \
        --bundle="$ROOT/launcher/bundle" \
        --aot-elf="$launcher_aot" \
        --engine="$ROOT/engine/release/libflutter_engine.so" \
        --icu-data="$ROOT/launcher/bundle/icudtl.dat" \
        --presenter=swtcon \
        --presenter-options="${PLUTO_PRESENTER_OPTS:-exact_color=1,enable_rails=1,vcom=-0.62,du_mode=7,dither=1,settle_delay_ms=0,full_refresh_every=0,eink=/usr/share/remarkable/GAL3_AAB0AM_IC0801_AC073MC1F2_AD1004-GCA_TC.eink}" \
        --touch \
        --bezel-redraw \
        --run-dir="$PLUTO_RUN_DIR"
    fi
    latch_safe_mode "launcher-is-not-release-aot"
    log "refusing JIT boot launcher; starting stock UI directly"
    exec /usr/bin/xochitl
    ;;
  status)
    printf 'boot-mode=%s\n' "$MODE"
    [ ! -f "$DISABLED" ] || printf 'safe-mode=%s\n' "$(cat "$REASON" 2>/dev/null || printf latched)"
    ;;
  *)
    log "no boot action for '${1:-}'"
    exit 0
    ;;
esac
