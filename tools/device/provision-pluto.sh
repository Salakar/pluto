#!/usr/bin/env bash
# Host-side Pluto provisioning orchestrator. It stages device-side scripts and
# payloads under /home/root/pluto, registers the AppLoad entry, and can fully
# uninstall back to stock. Non-dry-run actions use the shared SSH harness.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

ROOT="${PLUTO_DEVICE_ROOT:-/home/root/pluto}"
BOOT_MODE="launcher"
DRY_RUN=0
ACTION="status"

usage() {
  cat >&2 <<EOF
usage: provision-pluto.sh [--dry-run] [--boot-mode=launcher|stock|disabled] {install|status|uninstall}

Payload env vars for install:
  PLUTO_EMBEDDER       host path to pluto-embedder
  PLUTOD               optional host path to plutod
  PLUTO_ENGINE_DIR     host dir containing debug/profile/release flavor dirs
  PLUTO_LAUNCHER_TAR   host tar of launcher payload, extracted into $ROOT/launcher
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --boot-mode=*) BOOT_MODE="${1#*=}" ;;
    install|status|uninstall) ACTION="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
  shift
done

case "$BOOT_MODE" in
  launcher|stock|disabled) ;;
  *) die "invalid boot mode: $BOOT_MODE" ;;
esac

remote() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ ssh %s %q\n' "$RM_USB_HOST" "$*"
  else
    rm_usb "$@"
  fi
}

upload_file() {
  local src="$1"
  local dest="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ upload %s -> %s:%s\n' "$src" "$RM_USB_HOST" "$dest"
  else
    [ -f "$src" ] || die "missing payload: $src"
    rm_usb "mkdir -p '$(dirname "$dest")' && cat > '$dest' && chmod 0755 '$dest'" < "$src"
  fi
}

upload_text() {
  local dest="$1"
  local text="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ write %s:%s\n%s\n' "$RM_USB_HOST" "$dest" "$text"
  else
    rm_usb "mkdir -p '$(dirname "$dest")' && cat > '$dest'" <<< "$text"
  fi
}

install_layout() {
  remote "mkdir -p '$ROOT'/bin '$ROOT'/engine '$ROOT'/apps '$ROOT'/launcher '$ROOT'/appdata '$ROOT'/shared '$ROOT'/staging '$ROOT'/state '$ROOT'/logs '$ROOT'/tmp"
  remote "printf '1 0.1.0\n' > '$ROOT/VERSION'; printf '%s\n' '$BOOT_MODE' > '$ROOT/state/boot-mode'"
}

write_journal() {
  remote "os=\$(head -n 1 /etc/version 2>/dev/null | tr -d '\r'); xo=\$(sha256sum /usr/bin/xochitl | awk '{ print \$1 }'); now=\$(date -u +%Y-%m-%dT%H:%M:%SZ); cat > '$ROOT/provision.json' <<EOF
{
  \"schema\": 1,
  \"cliVersion\": \"0.1.0\",
  \"plutoAbi\": 1,
  \"provisionedAt\": \"\$now\",
  \"device\": { \"osBuild\": \"\$os\", \"xochitlSha256\": \"\$xo\" },
  \"steps\": { \"layout\": { \"status\": \"done\" }, \"boot-hook\": { \"status\": \"done\", \"mechanism\": \"appload-backend-entry\", \"mode\": \"$BOOT_MODE\" } },
  \"ownership\": { \"appload\": \"pre-existing-or-pluto-managed\", \"xovi\": \"pre-existing-or-pluto-managed\" }
}
EOF"
}

install_scripts() {
  upload_file pluto-boot-hook.sh "$ROOT/bin/pluto-boot-hook.sh"
  upload_file pluto-bootloop-check.sh "$ROOT/bin/pluto-bootloop-check.sh"
  upload_file pluto-fingerprint-check.sh "$ROOT/bin/pluto-fingerprint-check.sh"
  upload_file pluto-session.sh "$ROOT/bin/pluto-session.sh"
  upload_file pluto-power-key-watch.sh "$ROOT/bin/pluto-power-key-watch.sh"
  upload_file pluto-xochitl-guard.sh "$ROOT/bin/pluto-xochitl-guard.sh"
  upload_file pluto-app-control.sh "$ROOT/bin/pluto-app-control.sh"
  upload_file pluto-install-transaction.sh "$ROOT/bin/pluto-install-transaction.sh"
  upload_file pluto-deadman.sh "$ROOT/bin/pluto-deadman.sh"
  upload_file pluto-uninstall.sh "$ROOT/bin/pluto-uninstall.sh"
}

install_payloads() {
  if [ -n "${PLUTO_EMBEDDER:-}" ]; then
    upload_file "$PLUTO_EMBEDDER" "$ROOT/bin/pluto-embedder"
  else
    log "PLUTO_EMBEDDER not set; skipping embedder upload"
  fi
  if [ -n "${PLUTOD:-}" ]; then
    upload_file "$PLUTOD" "$ROOT/bin/plutod"
  else
    log "PLUTOD not set; pluto-boot-hook will fall back to pluto-embedder"
  fi
  if [ -n "${PLUTO_ENGINE_DIR:-}" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '+ tar %s -> %s:%s/engine\n' "$PLUTO_ENGINE_DIR" "$RM_USB_HOST" "$ROOT"
    else
      [ -d "$PLUTO_ENGINE_DIR" ] || die "missing PLUTO_ENGINE_DIR: $PLUTO_ENGINE_DIR"
      tar -C "$PLUTO_ENGINE_DIR" -cf - . | rm_usb "tar -C '$ROOT/engine' -xf -"
    fi
  else
    log "PLUTO_ENGINE_DIR not set; skipping engine upload"
  fi
  if [ -n "${PLUTO_LAUNCHER_TAR:-}" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '+ extract launcher tar %s -> %s:%s/launcher\n' "$PLUTO_LAUNCHER_TAR" "$RM_USB_HOST" "$ROOT"
    else
      [ -f "$PLUTO_LAUNCHER_TAR" ] || die "missing PLUTO_LAUNCHER_TAR: $PLUTO_LAUNCHER_TAR"
      rm_usb "rm -rf '$ROOT/launcher' && mkdir -p '$ROOT/launcher'"
      rm_usb "tar -C '$ROOT/launcher' -xf -" < "$PLUTO_LAUNCHER_TAR"
    fi
  else
    log "PLUTO_LAUNCHER_TAR not set; skipping launcher upload"
  fi
}

register_appload() {
  local app_dir="/home/root/xovi/exthome/appload/pluto"
  upload_text "$app_dir/external.manifest.json" '{
  "name": "Pluto",
  "application": "backend/entry",
  "qtfb": true,
  "aspectRatio": "move",
  "disablesWindowedMode": true
}'
  upload_text "$app_dir/manifest.json" '{
  "id": "dev.pluto.launcher",
  "name": "Pluto",
  "loadsBackend": true,
  "entry": "/ui/main.qml",
  "supportsScaling": false,
  "canHaveMultipleFrontends": false,
  "aspectRatio": "move"
}'
  upload_text "$app_dir/backend/entry" '#!/bin/sh
exec /home/root/pluto/bin/pluto-boot-hook.sh launch-launcher "$@"
'
  remote "chmod 0755 '$app_dir/backend/entry'"
}

do_install() {
  install_layout
  install_scripts
  install_payloads
  register_appload
  write_journal
  log "Pluto provision path staged; boot-mode=$BOOT_MODE"
}

do_status() {
  remote "printf 'pluto root: '; [ -d '$ROOT' ] && echo present || echo missing; [ ! -f '$ROOT/state/boot-mode' ] || printf 'boot-mode: %s\n' \"\$(cat '$ROOT/state/boot-mode')\"; [ ! -f '$ROOT/state/boot-disabled' ] || printf 'safe-mode: %s\n' \"\$(cat '$ROOT/state/safe-mode-reason' 2>/dev/null || echo latched)\"; [ -S '$ROOT/state/plutod.sock' ] && echo 'plutod: socket present' || true"
}

do_uninstall() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ %s/bin/pluto-uninstall.sh --dry-run --yes\n' "$ROOT"
  else
    rm_usb "'$ROOT/bin/pluto-uninstall.sh' --yes"
  fi
}

case "$ACTION" in
  install) do_install ;;
  status) do_status ;;
  uninstall) do_uninstall ;;
esac
