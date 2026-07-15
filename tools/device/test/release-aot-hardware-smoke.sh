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

  "$CLI" run --release --device "$DEVICE" "$app_id"
  remote "set -eu
i=0
pid=''
cmd=''
ready_file=''
health_file=''
seq_before=''
matched=0
while [ \"\$i\" -lt 30 ]; do
  pid=\$(cat /run/pluto/embedder.pid 2>/dev/null || true)
  case \"\$pid\" in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 \"\$pid\" 2>/dev/null; then
        cmd=\$(tr '\\000' ' ' < \"/proc/\$pid/cmdline\")
        case \"\$cmd\" in
          *--release*--bundle=$bundle*--ready-file=/run/pluto/boot-ready.*--health-file=/run/pluto/health.*--aot-elf=$aot_elf*)
            ready_file=''
            health_file=''
            for arg in \$(tr '\\000' '\\n' < \"/proc/\$pid/cmdline\"); do
              case \"\$arg\" in
                --ready-file=*) ready_file=\${arg#*=} ;;
                --health-file=*) health_file=\${arg#*=} ;;
              esac
            done
            if [ -n \"\$ready_file\" ] && [ -n \"\$health_file\" ] &&
               [ \"\${ready_file#/run/pluto/boot-ready.}\" = \
                 \"\${health_file#/run/pluto/health.}\" ] &&
               [ \"\$(cat \"\$ready_file\" 2>/dev/null || true)\" = ready ]; then
              set -- \$(cat \"\$health_file\" 2>/dev/null || true)
              if [ \"\$#\" -eq 3 ] && [ \"\$1\" = \"pid=\$pid\" ]; then
                seq_before=\${2#seq=}
                mono_before=\${3#mono_ms=}
                case \"\$seq_before:\$mono_before\" in
                  *[!0-9:]*|:*|*:) ;;
                  *) matched=1; break ;;
                esac
              fi
            fi
            ;;
        esac
      fi
      ;;
  esac
  sleep 1
  i=\$((i + 1))
done
[ \"\$matched\" -eq 1 ] || {
  echo \"release AOT smoke: $app_id never published matching AOT receipts\" >&2
  echo \"\$cmd\" >&2
  exit 83
}
grep -q 'mode=release.*aot=true' /home/root/pluto/logs/current.log
sleep 2
kill -0 \"\$pid\"
set -- \$(cat \"\$health_file\" 2>/dev/null || true)
[ \"\$#\" -eq 3 ] && [ \"\$1\" = \"pid=\$pid\" ] || exit 85
seq_after=\${2#seq=}
[ \"\$seq_after\" -gt \"\$seq_before\" ] || exit 86
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
