#!/usr/bin/env bash
set -euo pipefail

DEVICE="${1:-root@10.11.99.1}"
CLI="${PLUTO_CLI:-pluto}"
STAGE_DELAY="${PLUTO_ACCEPTANCE_STAGE_DELAY:-0}"
CODEX_REQUEST="${PLUTO_ACCEPTANCE_CODEX_REQUEST:-0}"
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=5)

[[ "$STAGE_DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
  echo "release AOT smoke: invalid PLUTO_ACCEPTANCE_STAGE_DELAY: $STAGE_DELAY" >&2
  exit 64
}
[[ "$CODEX_REQUEST" == 0 || "$CODEX_REQUEST" == 1 ]] || {
  echo "release AOT smoke: PLUTO_ACCEPTANCE_CODEX_REQUEST must be 0 or 1" >&2
  exit 64
}

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

open_switcher() {
  local origin="$1"

  remote "set -eu
printf '%s\\n' '$origin' > /run/pluto/switcher
i=0
while [ \"\$i\" -lt 30 ]; do
  active=\$(sed -n '1p' /run/pluto/switcher-active 2>/dev/null || true)
  pid=\$(cat /run/pluto/embedder.pid 2>/dev/null || true)
  cmd=''
  case \"\$pid\" in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 \"\$pid\" 2>/dev/null; then
        cmd=\$(tr '\\000' ' ' < \"/proc/\$pid/cmdline\")
      fi
      ;;
  esac
  case \"\$active:\$cmd\" in
    '$origin':*--release*--bundle=/home/root/pluto/launcher/bundle*--dart-entrypoint-args=--switcher*)
      origin_pid=\$(cat '/run/pluto/warm-apps/$origin.pid' 2>/dev/null || true)
      case \"\$origin_pid\" in
        ''|*[!0-9]*) ;;
        *)
          kill -0 \"\$origin_pid\" 2>/dev/null && {
            echo \"release AOT smoke: PASS switcher origin=$origin host=\$pid\"
            exit 0
          }
          ;;
      esac
      ;;
  esac
  sleep 1
  i=\$((i + 1))
done
echo \"release AOT smoke: switcher never became ready for $origin\" >&2
echo \"active=\$active cmd=\$cmd\" >&2
exit 87"

  sleep "$STAGE_DELAY"
}

select_switcher_preview() {
  local target
  target="$(remote "sed -n '2p' /run/pluto/switcher-active 2>/dev/null")"
  [[ "$target" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "release AOT smoke: switcher has no selectable non-origin app" >&2
    return 88
  }

  remote "set -eu
target='$target'
launcher_pid=\$(cat /run/pluto/embedder.pid 2>/dev/null || true)
case \"\$launcher_pid\" in ''|*[!0-9]*) exit 89 ;; esac
launcher_cmd=\$(tr '\\000' ' ' < \"/proc/\$launcher_pid/cmdline\")
case \"\$launcher_cmd\" in
  *--release*--bundle=/home/root/pluto/launcher/bundle*--dart-entrypoint-args=--switcher*) ;;
  *) echo \"release AOT smoke: switcher host is not the release launcher\" >&2; exit 90 ;;
esac
response=\$(/home/root/pluto/bin/pluto-controlctl \\
  --socket /run/pluto/embedder-control.sock \\
  --request '{\"schema\":1,\"requestId\":\"release-aot-switch\",\"action\":\"tap-switcher-preview\",\"appId\":\"dev.pluto.launcher\"}')
case \"\$response\" in
  *'\"ok\":true'*'\"appId\":\"dev.pluto.launcher\"'*'\"eventCount\":4'*) ;;
  *) echo \"release AOT smoke: switcher tap failed: \$response\" >&2; exit 91 ;;
esac
i=0
while [ \"\$i\" -lt 30 ]; do
  pid=\$(cat /run/pluto/embedder.pid 2>/dev/null || true)
  case \"\$pid\" in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 \"\$pid\" 2>/dev/null; then
        cmd=\$(tr '\\000' ' ' < \"/proc/\$pid/cmdline\")
        case \"\$cmd\" in
          *--release*--bundle=/home/root/pluto/apps/\$target/bundle*)
            if [ ! -e /run/pluto/switcher-active ]; then
              ready_file=''
              health_file=''
              for arg in \$(tr '\\000' '\\n' < \"/proc/\$pid/cmdline\"); do
                case \"\$arg\" in
                  --ready-file=*) ready_file=\${arg#*=} ;;
                  --health-file=*) health_file=\${arg#*=} ;;
                esac
              done
              if [ -n \"\$ready_file\" ] && [ -n \"\$health_file\" ] &&
                 [ \"\$(cat \"\$ready_file\" 2>/dev/null || true)\" = ready ]; then
                set -- \$(cat \"\$health_file\" 2>/dev/null || true)
                if [ \"\$#\" -eq 3 ] && [ \"\$1\" = \"pid=\$pid\" ]; then
                  seq_before=\${2#seq=}
                  sleep 2
                  set -- \$(cat \"\$health_file\" 2>/dev/null || true)
                  [ \"\$#\" -eq 3 ] && [ \"\${2#seq=}\" -gt \"\$seq_before\" ] || exit 92
                  echo \"release AOT smoke: PASS switcher UI selected \$target pid=\$pid response=\$response\"
                  exit 0
                fi
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
echo \"release AOT smoke: switcher UI did not foreground \$target\" >&2
exit 93"

  sleep "$STAGE_DELAY"
}

inject_ink_stroke() {
  remote "set -eu
pid=\$(cat /run/pluto/embedder.pid 2>/dev/null || true)
case \"\$pid\" in ''|*[!0-9]*) exit 89 ;; esac
cmd=\$(tr '\\000' ' ' < \"/proc/\$pid/cmdline\")
case \"\$cmd\" in
  *--release*--bundle=/home/root/pluto/apps/dev.pluto.ink/bundle*) ;;
  *) echo \"release AOT smoke: Ink is not the foreground release process\" >&2; exit 90 ;;
esac
health_file=''
for arg in \$(tr '\\000' '\\n' < \"/proc/\$pid/cmdline\"); do
  case \"\$arg\" in --health-file=*) health_file=\${arg#*=} ;; esac
done
[ -n \"\$health_file\" ] || exit 91
set -- \$(cat \"\$health_file\" 2>/dev/null || true)
[ \"\$#\" -eq 3 ] || exit 92
seq_before=\${2#seq=}
response=\$(/home/root/pluto/bin/pluto-controlctl \\
  --socket /run/pluto/embedder-control.sock \\
  --request '{\"schema\":1,\"requestId\":\"release-aot-stroke\",\"action\":\"draw-stroke\",\"appId\":\"dev.pluto.ink\"}')
case \"\$response\" in
  *'\"ok\":true'*'\"appId\":\"dev.pluto.ink\"'*'\"eventCount\":24'*) ;;
  *) echo \"release AOT smoke: Ink stroke failed: \$response\" >&2; exit 93 ;;
esac
i=0
while [ \"\$i\" -lt 30 ]; do
  set -- \$(cat \"\$health_file\" 2>/dev/null || true)
  if [ \"\$#\" -eq 3 ] && [ \"\${2#seq=}\" -gt \"\$seq_before\" ]; then
    echo \"release AOT smoke: PASS Ink stroke pid=\$pid response=\$response\"
    exit 0
  fi
  sleep 1
  i=\$((i + 1))
done
echo \"release AOT smoke: Ink stroke produced no completion-backed present\" >&2
exit 94"

  sleep "$STAGE_DELAY"
}

verify_real_codex() {
  remote "set -eu
pid=\$(cat /run/pluto/embedder.pid 2>/dev/null || true)
case \"\$pid\" in ''|*[!0-9]*) exit 95 ;; esac
cmd=\$(tr '\\000' ' ' < \"/proc/\$pid/cmdline\")
case \"\$cmd\" in
  *--release*--bundle=/home/root/pluto/apps/dev.pluto.codex/bundle*) ;;
  *) echo \"release AOT smoke: Codex is not the foreground release process\" >&2; exit 96 ;;
esac
configured=\$(tr '\\000' '\\n' < \"/proc/\$pid/environ\" |
  sed -n 's/^PAPER_CODEX_BIN=//p' | sed -n '1p')
binary=''
if [ -n \"\$configured\" ] && [ -x \"\$configured\" ]; then
  binary=\$configured
else
  for candidate in /home/root/bin/codex /home/root/.local/bin/codex; do
    if [ -x \"\$candidate\" ]; then binary=\$candidate; break; fi
  done
fi
[ -n \"\$binary\" ] || {
  echo \"release AOT smoke: Codex app cannot resolve a real binary\" >&2
  exit 97
}
version=\$(\"\$binary\" --version)
HOME=/home/root \"\$binary\" login status >/dev/null 2>&1 || {
  echo \"release AOT smoke: Codex authentication is unavailable\" >&2
  exit 98
}
if [ '$CODEX_REQUEST' -eq 1 ]; then
  output=''
  if ! output=\$(printf '%s\\n' \
      'Reply with exactly PLUTO-CODEX-OK and no other text.' |
      HOME=/home/root \"\$binary\" exec --json --skip-git-repo-check \
        --sandbox read-only -C /home/root - 2>&1); then
    echo \"release AOT smoke: real Codex request failed\" >&2
    printf '%s\\n' \"\$output\" | tail -n 12 >&2
    exit 99
  fi
  printf '%s\\n' \"\$output\" | grep -Fq '\"type\":\"agent_message\"' || exit 100
  printf '%s\\n' \"\$output\" | grep -Fq '\"text\":\"PLUTO-CODEX-OK\"' || exit 101
  printf '%s\\n' \"\$output\" | grep -Fq '\"type\":\"turn.completed\"' || exit 102
  digest=\$(printf '%s\\n' \"\$output\" | sha256sum | cut -d ' ' -f 1)
  echo \"release AOT smoke: PASS real authenticated Codex request binary=\$binary version=\$version response_sha256=\$digest\"
else
  echo \"release AOT smoke: PASS real Codex binary/auth binary=\$binary version=\$version request=skipped\"
fi"
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
verify_real_codex
verify_app dev.pluto.ink /home/root/pluto/apps/dev.pluto.ink

open_switcher dev.pluto.ink
select_switcher_preview
verify_app dev.pluto.ink /home/root/pluto/apps/dev.pluto.ink
inject_ink_stroke
verify_app dev.pluto.launcher /home/root/pluto/launcher
sleep "$STAGE_DELAY"

remote 'set -eu
[ ! -d /home/root/pluto/engine/debug ]
[ "$(find /home/root/pluto -type f -name kernel_blob.bin | wc -l)" -eq 0 ]
. /home/root/pluto/share/device-profiles.sh
pluto_profile_probe
expected_engine_flavors=1
case ",$PLUTO_PROFILE_BUILD_MODES," in
  *,profile,*) expected_engine_flavors=$((expected_engine_flavors + 1)) ;;
esac
[ "$(find /home/root/pluto/engine -mindepth 1 -maxdepth 1 -type d | wc -l)" \
  -eq "$expected_engine_flavors" ]
systemctl is-active --quiet xochitl.service
echo "release AOT smoke: all standard apps, switcher, and Ink stroke passed; debug/JIT state absent"'
