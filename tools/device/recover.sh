#!/usr/bin/env bash
# The universal recovery primitive: clear the xochitl start-limit counter and
# restart it, re-initializing SWTCON + the panel and repainting the stock UI.
# USB first, Wi-Fi fallback.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

log "recover: reset-failed + restart xochitl.service"
rm_any 'systemctl reset-failed xochitl.service 2>/dev/null || true; systemctl restart xochitl.service; sleep 1; systemctl is-active xochitl.service'
log "recover: done"
