#!/bin/sh
# The only Pluto-sanctioned xochitl restarter.
set -eu

ROOT="${PLUTO_ROOT:-/home/root/pluto}"
STATE="$ROOT/state"
LEDGER="$STATE/xochitl-restarts.log"
WINDOW_SECONDS=600
MAX_RECENT=3
ACTION="${1:-restart}"

mkdir -p "$STATE"

dry_run() {
  [ "${PLUTO_DRY_RUN:-0}" = "1" ]
}

recent_count() {
  now="$(date +%s)"
  cutoff="$((now - WINDOW_SECONDS))"
  awk -v cutoff="$cutoff" '$1 >= cutoff { print }' "$LEDGER" 2>/dev/null | wc -l | tr -d ' '
}

case "$ACTION" in
  status)
    printf 'recent=%s window=%ss limit=%s\n' "$(recent_count)" "$WINDOW_SECONDS" "$MAX_RECENT"
    systemctl is-active xochitl.service 2>/dev/null || true
    exit 0
    ;;
  restart|restore) ;;
  *)
    printf 'usage: pluto-xochitl-guard.sh {restart|restore|status}\n' >&2
    exit 64
    ;;
esac

RECENT="$(recent_count)"
if [ "$RECENT" -ge "$MAX_RECENT" ]; then
  printf 'guard: refusing %s; would approach StartLimitBurst=4/600s\n' "$ACTION" >&2
  exit 75
fi

NOW="$(date +%s)"
if dry_run; then
  printf '+ systemctl reset-failed xochitl.service\n'
  printf '+ ledger %s %s %s\n' "$NOW" "$$" "$ACTION"
else
  systemctl reset-failed xochitl.service 2>/dev/null || true
  printf '%s %s %s\n' "$NOW" "$$" "$ACTION" >> "$LEDGER"
fi

case "$ACTION" in
  restart)
    if dry_run; then
      printf '+ systemctl restart xochitl.service\n'
    else
      systemctl restart xochitl.service
    fi
    ;;
  restore)
    if [ -x /home/root/xovi/stock ]; then
      if dry_run; then
        printf '+ /home/root/xovi/stock\n'
      elif command -v bash >/dev/null 2>&1; then
        cd /home/root && bash xovi/stock
      else
        cd /home/root && sh xovi/stock
      fi
    elif dry_run; then
      printf '+ systemctl restart xochitl.service\n'
    else
      systemctl restart xochitl.service
    fi
    ;;
esac
