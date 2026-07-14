#!/usr/bin/env bash
set -euo pipefail

DEVICE="${1:-root@10.11.99.1}"
CLI="${PLUTO_CLI:-pluto}"
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=5)

remote() {
  ssh "${SSH_OPTIONS[@]}" "$DEVICE" "$1"
}

verify_app() {
  local app_id="$1"
  local app_root="$2"
  local bundle="$app_root/bundle"
  local aot_elf="$bundle/lib/app.so"

  remote 'rm -f /run/pluto/boot-ready'
  "$CLI" run --release --device "$DEVICE" "$app_id"
  remote "set -eu
i=0
while [ \"\$i\" -lt 30 ] && [ ! -f /run/pluto/boot-ready ]; do
  sleep 1
  i=\$((i + 1))
done
if [ \"\$(cat /run/pluto/boot-ready 2>/dev/null || true)\" != ready ]; then
  echo \"release AOT smoke: $app_id did not present\" >&2
  tail -n 80 /home/root/pluto/logs/current.log >&2 || true
  exit 81
fi
pid=\$(cat /run/pluto/embedder.pid 2>/dev/null || true)
case \"\$pid\" in ''|*[!0-9]*)
  echo \"release AOT smoke: $app_id has no supervisor PID\" >&2
  exit 82 ;;
esac
cmd=\$(tr '\\000' ' ' < \"/proc/\$pid/cmdline\")
case \"\$cmd\" in
  *--release*--bundle=$bundle*--ready-file=/run/pluto/boot-ready*--aot-elf=$aot_elf*) ;;
  *)
    echo \"release AOT smoke: $app_id command is not the expected AOT launch\" >&2
    echo \"\$cmd\" >&2
    exit 83 ;;
esac
grep -q 'mode=release.*aot=true' /home/root/pluto/logs/current.log
sleep 2
kill -0 \"\$pid\"
systemctl is-active --quiet xochitl.service
echo \"release AOT smoke: PASS $app_id pid=\$pid present_after=\${i}s\""
}

verify_app \
  dev.pluto.examples.counter \
  /home/root/pluto/apps/dev.pluto.examples.counter
verify_app \
  dev.pluto.examples.motion_lab \
  /home/root/pluto/apps/dev.pluto.examples.motion_lab
verify_app \
  dev.pluto.examples.ink_lab \
  /home/root/pluto/apps/dev.pluto.examples.ink_lab
verify_app \
  dev.pluto.validation_lab \
  /home/root/pluto/apps/dev.pluto.validation_lab
verify_app \
  dev.pluto.codex \
  /home/root/pluto/apps/dev.pluto.codex
verify_app dev.pluto.launcher /home/root/pluto/launcher

remote 'set -eu
[ ! -d /home/root/pluto/engine/debug ]
[ "$(find /home/root/pluto -type f -name kernel_blob.bin | wc -l)" -eq 0 ]
[ "$(find /home/root/pluto/engine -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ]
systemctl is-active --quiet xochitl.service
echo "release AOT smoke: all standard apps passed; debug/JIT state absent"'
