#!/bin/sh
# Device-side app transaction helper for already-staged payloads.
set -eu

ROOT="${PLUTO_ROOT:-/home/root/pluto}"
APPS="$ROOT/apps"
APPDATA="$ROOT/appdata"
STAGING="$ROOT/staging"
STATE="$ROOT/state"
APP_CONTROL="$ROOT/bin/pluto-app-control.sh"
DRY_RUN=0

if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ %s\n' "$*"
  else
    "$@"
  fi
}

safe_app_id() {
  case "$1" in
    *..*|/*|*/*|''|dev.pluto.launcher) return 1 ;;
    *.*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_layout() {
  run mkdir -p "$APPS" "$APPDATA" "$STAGING" "$STATE"
}

bump_rev() {
  current=0
  if [ -f "$STATE/apps.rev" ]; then
    current="$(cat "$STATE/apps.rev")"
  fi
  next="$((current + 1))"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ printf "%%s\\n" "%s" > %s/apps.rev.tmp && mv %s/apps.rev.tmp %s/apps.rev\n' "$next" "$STATE" "$STATE" "$STATE"
  else
    printf '%s\n' "$next" > "$STATE/apps.rev.tmp"
    mv "$STATE/apps.rev.tmp" "$STATE/apps.rev"
  fi
}

hidden_app_id() {
  name="$1"
  prefix="$2"
  rest="${name#"$prefix"}"
  case "$rest" in
    "$name"|*.*) printf '%s\n' "${rest%.*}" ;;
    *) return 1 ;;
  esac
}

# Cleans interrupted transactions. $1 (optional) names a staging entry to
# KEEP — the stage a commit is about to promote must survive its own repair
# pass.
repair() {
  keep="${1:-}"
  ensure_layout
  for app in "$APPS"/*; do
    [ -d "$app" ] || continue
    [ -f "$app/install.json" ] && continue
    id="${app##*/}"
    old=""
    for candidate in "$STAGING/.old-$id".*; do
      [ -d "$candidate" ] || continue
      old="$candidate"
      break
    done
    run rm -rf "$app"
    if [ -n "$old" ]; then
      run mv "$old" "$app"
    fi
  done
  for entry in "$STAGING"/* "$STAGING"/.[!.]*; do
    [ -d "$entry" ] || continue
    name="${entry##*/}"
    [ -n "$keep" ] && [ "$name" = "$keep" ] && continue
    case "$name" in
      .old-*)
        id="$(hidden_app_id "$name" .old- || true)"
        if [ -n "$id" ] && [ ! -e "$APPS/$id" ]; then
          run mv "$entry" "$APPS/$id"
        else
          run rm -rf "$entry"
        fi
        ;;
      *) run rm -rf "$entry" ;;
    esac
  done
}

commit_app() {
  app_id="$1"
  nonce="$2"
  hashes="${3:-}"
  install_json="${4:-}"
  safe_app_id "$app_id" || { printf 'invalid app id: %s\n' "$app_id" >&2; exit 64; }
  ensure_layout
  repair "$app_id.$nonce"
  stage="$STAGING/$app_id.$nonce"
  old="$STAGING/.old-$app_id.$nonce"
  app="$APPS/$app_id"
  [ -d "$stage" ] || { printf 'missing stage: %s\n' "$stage" >&2; exit 66; }
  [ -f "$stage/manifest.json" ] || { printf 'missing manifest in stage\n' >&2; exit 66; }
  if [ -n "$hashes" ] && [ "$hashes" != "-" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '+ cd %s && sha256sum -c %s\n' "$stage" "$hashes"
    else
      (cd "$stage" && sha256sum -c "$hashes")
    fi
  fi
  [ -x "$APP_CONTROL" ] || {
    printf 'missing app lifecycle helper: %s\n' "$APP_CONTROL" >&2
    exit 69
  }
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ PLUTO_ROOT=%s PLUTO_RUN_DIR=%s sh %s stop %s\n' \
      "$ROOT" "${PLUTO_RUN_DIR:-/run/pluto}" "$APP_CONTROL" "$app_id"
  else
    PLUTO_ROOT="$ROOT" \
    PLUTO_RUN_DIR="${PLUTO_RUN_DIR:-/run/pluto}" \
      sh "$APP_CONTROL" stop "$app_id"
  fi
  run rm -rf "$old"
  if [ -e "$app" ]; then
    run mv "$app" "$old"
  fi
  run mv "$stage" "$app"
  run mkdir -p "$APPDATA/$app_id"
  if [ -z "$install_json" ]; then
    install_json="$app/install.json.pending"
  fi
  [ -f "$install_json" ] || { printf 'missing install record: %s\n' "$install_json" >&2; exit 66; }
  run mv "$install_json" "$app/install.json"
  run rm -rf "$old"
  bump_rev
}

uninstall_app() {
  app_id="$1"
  nonce="$2"
  purge="${3:-keep-data}"
  safe_app_id "$app_id" || { printf 'invalid app id: %s\n' "$app_id" >&2; exit 64; }
  ensure_layout
  repair
  app="$APPS/$app_id"
  removed="$STAGING/.rm-$app_id.$nonce"
  [ -x "$APP_CONTROL" ] || {
    printf 'missing app lifecycle helper: %s\n' "$APP_CONTROL" >&2
    exit 69
  }
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ PLUTO_ROOT=%s PLUTO_RUN_DIR=%s sh %s stop %s\n' \
      "$ROOT" "${PLUTO_RUN_DIR:-/run/pluto}" "$APP_CONTROL" "$app_id"
  else
    PLUTO_ROOT="$ROOT" \
    PLUTO_RUN_DIR="${PLUTO_RUN_DIR:-/run/pluto}" \
      sh "$APP_CONTROL" stop "$app_id"
  fi
  if [ ! -e "$app" ]; then
    run rm -rf "$removed"
    exit 0
  fi
  run rm -rf "$removed"
  run mv "$app" "$removed"
  bump_rev
  run rm -rf "$removed"
  if [ "$purge" = "--purge-data" ]; then
    run rm -rf "$APPDATA/$app_id"
  else
    run mkdir -p "$APPDATA/$app_id"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '+ touch %s/.uninstalled-$(date +%%s)\n' "$APPDATA/$app_id"
    else
      : > "$APPDATA/$app_id/.uninstalled-$(date +%s)"
    fi
  fi
}

case "${1:-}" in
  repair) repair ;;
  commit)
    [ "$#" -ge 3 ] || { printf 'usage: %s commit <app-id> <nonce> [hashes|-] [install-json]\n' "$0" >&2; exit 64; }
    commit_app "$2" "$3" "${4:-}" "${5:-}"
    ;;
  uninstall)
    [ "$#" -ge 3 ] || { printf 'usage: %s uninstall <app-id> <nonce> [--purge-data]\n' "$0" >&2; exit 64; }
    uninstall_app "$2" "$3" "${4:-keep-data}"
    ;;
  *)
    printf 'usage: %s [--dry-run] {repair|commit|uninstall} ...\n' "$0" >&2
    exit 64
    ;;
esac
