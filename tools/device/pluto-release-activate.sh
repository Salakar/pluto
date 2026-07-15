#!/bin/sh
# Atomically expose one complete Pluto runtime/app release. Immutable release
# content lives below ROOT_LINK.releases; ROOT_LINK is always either absent or
# one symlink to a fully staged release. Mutable data is kept outside the
# release and linked into every candidate before this helper is called.
set -u

ROOT_LINK="${PLUTO_ROOT_LINK:-/home/root/pluto}"
RELEASES_ROOT="${PLUTO_RELEASES_ROOT:-${ROOT_LINK}.releases}"
DATA_ROOT="${PLUTO_DATA_ROOT:-${ROOT_LINK}.data}"
RUN_DIR="${PLUTO_RUN_DIR:-/run/pluto}"
SYSTEMCTL="${PLUTO_SYSTEMCTL:-systemctl}"
SYSTEM_ROOT="${PLUTO_SYSTEM_ROOT:-}"
SYNC="${PLUTO_SYNC:-sync}"
MV="${PLUTO_MV:-mv}"
RM="${PLUTO_RM:-rm}"
TESTING="${PLUTO_TESTING:-0}"
FAILURE_AT="${PLUTO_TEST_FAILURE_AT:-}"
DROPIN="$SYSTEM_ROOT/usr/lib/systemd/system/xochitl.service.d/zz-pluto.conf"

log() { printf '[pluto-release %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

safe_path() {
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in
    *[!A-Za-z0-9_./-]*|*/../*|*/..|*/./*|*/.) return 1 ;;
  esac
}

safe_token() {
  case "$1" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; *) return 0 ;; esac
}

fault() {
  [ "$TESTING" = 1 ] && [ "$FAILURE_AT" = "$1" ] || return 1
  log "injected activation failure at $1"
  return 0
}

require_release() {
  checked_release=$1
  [ -d "$checked_release" ] && [ ! -L "$checked_release" ] || return 1
  case "$checked_release" in "$RELEASES_ROOT"/*) ;; *) return 1 ;; esac
  checked_name=${checked_release#"$RELEASES_ROOT"/}
  safe_token "$checked_name" || return 1
  case "$checked_name" in */*) return 1 ;; esac
  [ -f "$checked_release/.pluto-release-owned" ] &&
    [ ! -L "$checked_release/.pluto-release-owned" ] || return 1
  [ "$(cat "$checked_release/.pluto-release-owned" 2>/dev/null)" = \
    "$checked_name" ] || return 1
  [ -x "$checked_release/bin/pluto-embedder" ] || return 1
  [ -x "$checked_release/bin/pluto-session.sh" ] || return 1
  [ -x "$checked_release/bin/pluto-session-once.sh" ] || return 1
  [ -x "$checked_release/bin/pluto-boot-install.sh" ] || return 1
  [ -x "$checked_release/bin/pluto-release-activate.sh" ] || return 1
  [ -f "$checked_release/engine/release/libflutter_engine.so" ] || return 1
  [ -f "$checked_release/launcher/bundle/lib/app.so" ] || return 1
  [ -f "$checked_release/launcher/manifest.json" ] || return 1
  [ -f "$checked_release/share/device-profiles.sh" ] || return 1
  for mutable in appdata logs state staging shared; do
    [ -L "$checked_release/$mutable" ] || return 1
    [ "$(readlink "$checked_release/$mutable" 2>/dev/null)" = \
      "$DATA_ROOT/$mutable" ] || return 1
    [ -d "$DATA_ROOT/$mutable" ] && [ ! -L "$DATA_ROOT/$mutable" ] ||
      return 1
  done
}

garbage_collect_owned_releases() {
  gc_ok=1
  for release in "$RELEASES_ROOT"/* "$RELEASES_ROOT"/.candidate-*; do
    [ -e "$release" ] || [ -L "$release" ] || continue
    [ "$release" != "$CANDIDATE" ] || continue
    [ -d "$release" ] && [ ! -L "$release" ] || continue
    name=${release#"$RELEASES_ROOT"/}
    owner=$(cat "$release/.pluto-release-owned" 2>/dev/null || true)
    safe_token "$owner" || continue
    case "$name" in
      "$owner"|.candidate-"$owner") "$RM" -rf "$release" || gc_ok=0 ;;
    esac
  done
  "$RM" -f "$RELEASES_ROOT"/.active-link.* 2>/dev/null || gc_ok=0
  [ "$gc_ok" -eq 1 ]
}

atomic_link() {
  destination=$1
  target=$2
  link_tmp="$RELEASES_ROOT/.active-link.$$"
  rm -f "$link_tmp" || return 1
  ln -s "$target" "$link_tmp" || return 1
  # BusyBox mv supports -T. It is mandatory here: plain `mv source link-to-dir`
  # follows the destination symlink and moves inside the old release instead
  # of atomically replacing the link.
  if ! "$MV" -Tf "$link_tmp" "$destination"; then
    rm -f "$link_tmp"
    return 1
  fi
  [ -L "$destination" ] &&
    [ "$(readlink "$destination" 2>/dev/null)" = "$target" ]
}

old_boot_install() {
  PLUTO_ROOT="$ROOT_LINK" PLUTO_RUN_DIR="$RUN_DIR" \
    sh "$ROOT_LINK/bin/pluto-boot-install.sh" "$1"
}

old_once() {
  PLUTO_ROOT="$ROOT_LINK" PLUTO_RUN_DIR="$RUN_DIR" \
    PLUTO_SYSTEMCTL="$SYSTEMCTL" \
    sh "$ROOT_LINK/bin/pluto-session-once.sh" "$1"
}

new_boot_install() {
  PLUTO_ROOT="$ROOT_LINK" PLUTO_RUN_DIR="$RUN_DIR" \
    sh "$ROOT_LINK/bin/pluto-boot-install.sh" "$1"
}

new_once() {
  PLUTO_ROOT="$ROOT_LINK" PLUTO_RUN_DIR="$RUN_DIR" \
    PLUTO_SYSTEMCTL="$SYSTEMCTL" \
    sh "$ROOT_LINK/bin/pluto-session-once.sh" "$1"
}

restore_previous_policy() {
  [ -n "$OLD_TARGET" ] || return 0
  restore_ok=1
  if [ "$PRIOR_PERSISTENT" -eq 1 ]; then
    old_boot_install install || restore_ok=0
    if [ "$restore_ok" -eq 1 ] && [ "$PRIOR_XOCHITL_ACTIVE" -eq 1 ]; then
      "$SYSTEMCTL" reset-failed xochitl.service 2>/dev/null || true
      "$SYSTEMCTL" restart xochitl.service || restore_ok=0
      "$SYSTEMCTL" is-active --quiet xochitl.service || restore_ok=0
    fi
  elif [ "$PRIOR_ONCE" -eq 1 ]; then
    old_once start || restore_ok=0
  fi
  [ "$restore_ok" -eq 1 ]
}

rollback() {
  rollback_ok=1
  trap - 0 HUP INT TERM
  if [ "$SWITCHED" -eq 1 ]; then
    case "$NEW_POLICY" in
      transient) new_once stop >/dev/null 2>&1 || rollback_ok=0 ;;
      persistent) new_boot_install uninstall >/dev/null 2>&1 || rollback_ok=0 ;;
    esac
    if [ -n "$OLD_TARGET" ]; then
      atomic_link "$ROOT_LINK" "$OLD_TARGET" || rollback_ok=0
    else
      rm -f "$ROOT_LINK" || rollback_ok=0
    fi
  fi
  if [ "$RETIRED" -eq 1 ]; then
    restore_previous_policy || rollback_ok=0
  fi
  if [ "$rollback_ok" -eq 1 ]; then
    log "previous complete release and display policy restored"
  else
    log "ERROR: release rollback was incomplete; stock recovery may be required" >&2
  fi
  [ "$rollback_ok" -eq 1 ]
}

case "${1:-}" in
  activate) ;;
  *) echo 'usage: pluto-release-activate.sh activate CANDIDATE {persistent|transient|stock}' >&2; exit 64 ;;
esac
CANDIDATE=${2:-}
MODE=${3:-}

safe_path "$ROOT_LINK" && safe_path "$RELEASES_ROOT" &&
  safe_path "$DATA_ROOT" && safe_path "$RUN_DIR" && safe_path "$CANDIDATE" ||
  die 'activation paths are unsafe'
[ "$ROOT_LINK" != / ] && [ "$RELEASES_ROOT" != / ] && [ "$DATA_ROOT" != / ] ||
  die 'activation roots cannot be /'
case "$MODE" in persistent|transient|stock) ;; *) die "invalid activation mode: $MODE" ;; esac
require_release "$CANDIDATE" || die "candidate release is incomplete: $CANDIDATE"

OLD_TARGET=
if [ -L "$ROOT_LINK" ]; then
  OLD_TARGET=$(readlink "$ROOT_LINK" 2>/dev/null) || die 'cannot read active release link'
  case "$OLD_TARGET" in "$RELEASES_ROOT"/*) ;; *) die 'active release link is outside the release store' ;; esac
  require_release "$OLD_TARGET" || die 'active release ownership or payload is incomplete'
elif [ -e "$ROOT_LINK" ]; then
  die "$ROOT_LINK must be absent or an atomic release symlink; remove the unpublished legacy layout first"
fi
[ "$OLD_TARGET" != "$CANDIDATE" ] || die 'candidate release is already active'

PRIOR_ONCE=0
PRIOR_PERSISTENT=0
PRIOR_XOCHITL_ACTIVE=0
"$SYSTEMCTL" is-active --quiet pluto-session-once.service 2>/dev/null && PRIOR_ONCE=1
[ -f "$DROPIN" ] && PRIOR_PERSISTENT=1
"$SYSTEMCTL" is-active --quiet xochitl.service 2>/dev/null && PRIOR_XOCHITL_ACTIVE=1
[ "$PRIOR_ONCE" -eq 0 ] || [ "$PRIOR_PERSISTENT" -eq 0 ] ||
  die 'both transient and persistent Pluto ownership are active'
if [ -z "$OLD_TARGET" ] && { [ "$PRIOR_ONCE" -eq 1 ] || [ "$PRIOR_PERSISTENT" -eq 1 ]; }; then
  die 'display ownership exists without an active complete release'
fi

RETIRED=0
SWITCHED=0
NEW_POLICY=none
COMMITTED=0
trap 'rc=$?; if [ "$COMMITTED" -ne 1 ]; then rollback || true; fi; exit "$rc"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$PRIOR_ONCE" -eq 1 ]; then
  RETIRED=1
  old_once stop || die 'could not retire the active transient release'
elif [ "$PRIOR_PERSISTENT" -eq 1 ]; then
  RETIRED=1
  old_boot_install uninstall || die 'could not retire the active persistent release'
fi
fault after_retire && die 'injected failure after retiring the previous release'

"$SYNC" || die 'could not make the staged release durable'
atomic_link "$ROOT_LINK" "$CANDIDATE" || die 'could not atomically activate the complete release link'
SWITCHED=1
fault after_switch && die 'injected failure after the atomic release switch'

case "$MODE" in
  persistent)
    NEW_POLICY=persistent
    new_boot_install install || die 'new release boot policy failed'
    ;;
  transient)
    NEW_POLICY=transient
    new_once start || die 'new release transient session failed'
    ;;
  stock) ;;
esac
fault after_policy && die 'injected failure after the new display policy'
"$SYNC" || die 'could not make the active release durable'

COMMITTED=1
trap - 0 HUP INT TERM
if ! garbage_collect_owned_releases; then
  log 'WARNING: complete release is active; owned stale release cleanup will retry on the next provision' >&2
fi
printf 'PLUTO-RELEASE-ACTIVE|root=%s|candidate=%s|mode=%s\n' \
  "$ROOT_LINK" "$CANDIDATE" "$MODE"
