#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OFFICIAL_STAGE_HOOK="$ROOT/tools/setup/camera/capture-acceptance-stage.sh"
OFFICIAL_CAMERA_CAPTURE="$ROOT/tools/setup/camera/capture.sh"
OFFICIAL_METRICS_COLLECTOR="$ROOT/tools/device/diagnostics/acceptance-metrics/collect.sh"
ACCEPTANCE_IDENTITY="$ROOT/tools/device/diagnostics/acceptance_identity.py"
DEVICE="${1:-root@10.11.99.1}"
CLI="${PLUTO_CLI:-pluto}"
SSH_TARGET="${PLUTO_ACCEPTANCE_SSH_TARGET:-$DEVICE}"
SSH_PORT="${PLUTO_ACCEPTANCE_SSH_PORT:-}"
STAGE_DELAY="${PLUTO_ACCEPTANCE_STAGE_DELAY:-0}"
STAGE_HOOK="${PLUTO_ACCEPTANCE_STAGE_HOOK:-}"
SCREENSHOT_DIR="${PLUTO_ACCEPTANCE_SCREENSHOT_DIR:-}"
CODEX_REQUEST="${PLUTO_ACCEPTANCE_CODEX_REQUEST:-0}"
REQUIRE_VISUAL="${PLUTO_ACCEPTANCE_REQUIRE_VISUAL:-0}"
CAPTURE_SETTLE="${PLUTO_ACCEPTANCE_CAPTURE_SETTLE:-$REQUIRE_VISUAL}"
EXPECTED_REVISION="${PLUTO_ACCEPTANCE_RELEASE_REVISION:-}"
EXPECTED_PROFILE="${PLUTO_ACCEPTANCE_PROFILE_ID:-}"
CAMERA_DIR="${PLUTO_CAMERA_ACCEPTANCE_DIR:-}"
CAMERA_RIG="${PLUTO_CAMERA_RIG:-}"
RELEASE_MANIFEST="${PLUTO_ACCEPTANCE_RELEASE_MANIFEST:-}"
ALLOW_TEST_HOOKS="${PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS:-0}"
COLLECT_ONLY="${PLUTO_ACCEPTANCE_COLLECT_ONLY:-0}"
METRICS_COLLECTOR="${PLUTO_ACCEPTANCE_METRICS_COLLECTOR:-$OFFICIAL_METRICS_COLLECTOR}"
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=5)

[[ "$STAGE_DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
  echo "release AOT smoke: invalid PLUTO_ACCEPTANCE_STAGE_DELAY: $STAGE_DELAY" >&2
  exit 64
}
[[ "$CODEX_REQUEST" == 0 || "$CODEX_REQUEST" == 1 ]] || {
  echo "release AOT smoke: PLUTO_ACCEPTANCE_CODEX_REQUEST must be 0 or 1" >&2
  exit 64
}
[[ "$REQUIRE_VISUAL" == 0 || "$REQUIRE_VISUAL" == 1 ]] || {
  echo "release AOT smoke: PLUTO_ACCEPTANCE_REQUIRE_VISUAL must be 0 or 1" >&2
  exit 64
}
[[ "$ALLOW_TEST_HOOKS" == 0 || "$ALLOW_TEST_HOOKS" == 1 ]] || {
  echo "release AOT smoke: PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS must be 0 or 1" >&2
  exit 64
}
identity_args=(
  endpoint
  --device "$DEVICE"
  --ssh-target "$SSH_TARGET"
  --ssh-port "$SSH_PORT"
)
if [[ "$ALLOW_TEST_HOOKS" == 1 ]]; then
  identity_args+=(--allow-divergence)
fi
identity_rows="$(python3 "$ACCEPTANCE_IDENTITY" "${identity_args[@]}")" || {
  echo "release AOT smoke: DEVICE/SSH identity is invalid" >&2
  exit 64
}
[[ "$(printf '%s\n' "$identity_rows" | wc -l | tr -d '[:space:]')" == 4 ]] || {
  echo "release AOT smoke: DEVICE/SSH identity helper returned invalid output" >&2
  exit 64
}
CANONICAL_ENDPOINT="$(printf '%s\n' "$identity_rows" | awk -F '\t' '$1 == "canonical_endpoint" {print $2}')"
SSH_TARGET="$(printf '%s\n' "$identity_rows" | awk -F '\t' '$1 == "ssh_invocation_target" {print $2}')"
SSH_PORT="$(printf '%s\n' "$identity_rows" | awk -F '\t' '$1 == "ssh_port" {print $2}')"
ENDPOINT_DIVERGENT="$(printf '%s\n' "$identity_rows" | awk -F '\t' '$1 == "divergent" {print $2}')"
[[ -n "$CANONICAL_ENDPOINT" && -n "$SSH_TARGET" &&
  "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ &&
  ("$ENDPOINT_DIVERGENT" == 0 || "$ENDPOINT_DIVERGENT" == 1) ]] || {
  echo "release AOT smoke: DEVICE/SSH identity helper returned incomplete output" >&2
  exit 64
}
if [[ "$ALLOW_TEST_HOOKS" == 1 ]]; then
  echo "release AOT smoke: TEST_EVIDENCE test_seam=1 endpoint=$CANONICAL_ENDPOINT endpoint_divergent=$ENDPOINT_DIVERGENT"
fi
[[ "$COLLECT_ONLY" == 0 || "$COLLECT_ONLY" == 1 ]] || {
  echo "release AOT smoke: PLUTO_ACCEPTANCE_COLLECT_ONLY must be 0 or 1" >&2
  exit 64
}
[[ "$CAPTURE_SETTLE" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
  echo "release AOT smoke: invalid PLUTO_ACCEPTANCE_CAPTURE_SETTLE: $CAPTURE_SETTLE" >&2
  exit 64
}
[[ -z "$STAGE_HOOK" || -x "$STAGE_HOOK" ]] || {
  echo "release AOT smoke: stage hook is not executable: $STAGE_HOOK" >&2
  exit 64
}
if [[ "$REQUIRE_VISUAL" == 1 ]]; then
  [[ "$COLLECT_ONLY" == 1 ]] || {
    echo "release AOT smoke: final visual acceptance is two-pass; set PLUTO_ACCEPTANCE_COLLECT_ONLY=1, review every frame, then run the verifier" >&2
    exit 64
  }
  [[ -n "$STAGE_HOOK" ]] || {
    echo "release AOT smoke: final visual acceptance requires a camera stage hook" >&2
    exit 64
  }
  if [[ "$ALLOW_TEST_HOOKS" != 1 && ! "$STAGE_HOOK" -ef "$OFFICIAL_STAGE_HOOK" ]]; then
    echo "release AOT smoke: final visual acceptance requires the repository camera stage hook: $OFFICIAL_STAGE_HOOK" >&2
    exit 64
  fi
  if [[ "$ALLOW_TEST_HOOKS" != 1 && -n "${PLUTO_CAMERA_CAPTURE:-}" &&
    ! "$PLUTO_CAMERA_CAPTURE" -ef "$OFFICIAL_CAMERA_CAPTURE" ]]; then
    echo "release AOT smoke: final visual acceptance forbids a substituted camera capture command" >&2
    exit 64
  fi
  [[ -x "$METRICS_COLLECTOR" ]] || {
    echo "release AOT smoke: exact installed-byte metrics collector is unavailable" >&2
    exit 64
  }
  if [[ "$ALLOW_TEST_HOOKS" != 1 &&
    ! "$METRICS_COLLECTOR" -ef "$OFFICIAL_METRICS_COLLECTOR" ]]; then
    echo "release AOT smoke: final visual acceptance requires the repository metrics collector" >&2
    exit 64
  fi
  [[ -n "$SCREENSHOT_DIR" ]] || {
    echo "release AOT smoke: final visual acceptance requires native screenshots" >&2
    exit 64
  }
  [[ "$CODEX_REQUEST" == 1 ]] || {
    echo "release AOT smoke: final visual acceptance requires a real Codex request" >&2
    exit 64
  }
  [[ "$CAPTURE_SETTLE" =~ ^([1-9][0-9]*([.][0-9]+)?|0[.]0*[1-9][0-9]*)$ ]] || {
    echo "release AOT smoke: final visual acceptance requires a positive pre-capture settle" >&2
    exit 64
  }
  [[ "$EXPECTED_REVISION" =~ ^[0-9a-f]{40}$ ]] || {
    echo "release AOT smoke: final visual acceptance requires the exact release revision" >&2
    exit 64
  }
  case "$EXPECTED_PROFILE" in
    rm1 | rm2 | move) ;;
    *)
      echo "release AOT smoke: final visual acceptance requires the exact profile id" >&2
      exit 64
      ;;
  esac
  [[ "$CAMERA_RIG" =~ ^[1-9][0-9]*$ && -n "$CAMERA_DIR" ]] || {
    echo "release AOT smoke: final visual acceptance requires a camera rig and evidence directory" >&2
    exit 64
  }
  if [[ "$ALLOW_TEST_HOOKS" != 1 ]]; then
    python3 "$ACCEPTANCE_IDENTITY" camera-profile \
      --config "${PLUTO_CAMERA_CONFIG:-$ROOT/.pluto-devices.json}" \
      --device "$CAMERA_RIG" --expected-profile "$EXPECTED_PROFILE" \
      >/dev/null || {
      echo "release AOT smoke: selected camera rig is not bound to $EXPECTED_PROFILE" >&2
      exit 64
    }
  fi
  [[ -f "$RELEASE_MANIFEST" && ! -L "$RELEASE_MANIFEST" ]] || {
    echo "release AOT smoke: final visual acceptance requires PLUTO_ACCEPTANCE_RELEASE_MANIFEST" >&2
    exit 64
  }
  [[ ! -e "$CAMERA_DIR" && ! -L "$CAMERA_DIR" ]] || {
    echo "release AOT smoke: final camera evidence directory must be fresh: $CAMERA_DIR" >&2
    exit 64
  }
  [[ ! -e "$SCREENSHOT_DIR" && ! -L "$SCREENSHOT_DIR" ]] || {
    echo "release AOT smoke: final screenshot evidence directory must be fresh: $SCREENSHOT_DIR" >&2
    exit 64
  }
fi
REMOVE_SCREENSHOT_DIR=0
if [[ -z "$SCREENSHOT_DIR" ]]; then
  SCREENSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pluto-aot-screenshots.XXXXXX")"
  REMOVE_SCREENSHOT_DIR=1
else
  [[ ! -L "$SCREENSHOT_DIR" ]] || {
    echo "release AOT smoke: screenshot directory must not be a symlink: $SCREENSHOT_DIR" >&2
    exit 64
  }
  if [[ "$REQUIRE_VISUAL" != 1 ]]; then
    [[ ! -e "$SCREENSHOT_DIR" ]] || {
      echo "release AOT smoke: screenshot directory must be fresh: $SCREENSHOT_DIR" >&2
      exit 64
    }
  fi
  mkdir -p "$SCREENSHOT_DIR"
fi
cleanup_screenshots() {
  if [[ "$REMOVE_SCREENSHOT_DIR" == 1 ]]; then
    rm -rf "$SCREENSHOT_DIR"
  fi
}
trap cleanup_screenshots EXIT
SSH_OPTIONS+=(-p "$SSH_PORT")

remote() {
  ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" "$1"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

central_pixel_difference() {
  local before="$1"
  local after="$2"
  local value
  command -v ffmpeg >/dev/null 2>&1 || {
    echo "release AOT smoke: ffmpeg is required for decoded framebuffer comparison" >&2
    return 1
  }
  value="$(ffmpeg -v error -nostdin -i "$before" -i "$after" \
    -filter_complex \
    '[0:v]crop=iw*0.5:ih*0.3:iw*0.25:ih*0.36[a];[1:v]crop=iw*0.5:ih*0.3:iw*0.25:ih*0.36[b];[a][b]blend=all_mode=difference,format=gray,signalstats,metadata=print:file=-' \
    -frames:v 1 -f null - 2>/dev/null |
    sed -n 's/^lavfi\.signalstats\.YAVG=//p')" || return 1
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  awk -v value="$value" 'BEGIN { exit !(value >= 0.05) }' || return 1
  printf '%s\n' "$value"
}

write_visual_metadata() {
  [[ "$REQUIRE_VISUAL" == 1 ]] || return 0
  local camera_capture frozen_manifest release_manifest_sha release_target
  local stage_hook_sha camera_capture_sha metrics_collector_sha
  case "$EXPECTED_PROFILE" in
    rm1 | rm2) release_target=linux-arm ;;
    move) release_target=linux-arm64 ;;
  esac
  camera_capture="${PLUTO_CAMERA_CAPTURE:-$OFFICIAL_CAMERA_CAPTURE}"
  [[ -f "$STAGE_HOOK" && -f "$camera_capture" && -f "$METRICS_COLLECTOR" ]] ||
    return 64
  stage_hook_sha="$(sha256_file "$STAGE_HOOK")"
  camera_capture_sha="$(sha256_file "$camera_capture")"
  metrics_collector_sha="$(sha256_file "$METRICS_COLLECTOR")"
  mkdir -p "$CAMERA_DIR"
  frozen_manifest="$CAMERA_DIR/release-manifest.json"
  cp "$RELEASE_MANIFEST" "$frozen_manifest"
  grep -Eq "\"gitRevision\"[[:space:]]*:[[:space:]]*\"$EXPECTED_REVISION\"" \
    "$frozen_manifest" || {
    echo "release AOT smoke: release manifest revision does not match $EXPECTED_REVISION" >&2
    return 64
  }
  grep -Eq "\"$release_target\"[[:space:]]*:" "$frozen_manifest" || {
    echo "release AOT smoke: release manifest lacks target $release_target" >&2
    return 64
  }
  release_manifest_sha="$(sha256_file "$frozen_manifest")"
  cat > "$CAMERA_DIR/metadata.tsv" <<EOF
release_revision	$EXPECTED_REVISION
profile_id	$EXPECTED_PROFILE
release_manifest_sha256	$release_manifest_sha
release_target	$release_target
device_endpoint	$CANONICAL_ENDPOINT
camera_rig	$CAMERA_RIG
camera_stage_hook_sha256	$stage_hook_sha
camera_capture_sha256	$camera_capture_sha
metrics_collector_sha256	$metrics_collector_sha
test_seam	$ALLOW_TEST_HOOKS
EOF
}

write_visual_metadata

verify_release_identity() {
  [[ "$REQUIRE_VISUAL" == 1 ]] || return 0
  remote "set -eu
revision=\$(cat /home/root/pluto/share/release-revision 2>/dev/null || true)
[ \"\$revision\" = '$EXPECTED_REVISION' ] || {
  echo \"release AOT smoke: installed revision \$revision does not match $EXPECTED_REVISION\" >&2
  exit 82
}
. /home/root/pluto/share/device-profiles.sh
pluto_profile_probe
[ \"\$PLUTO_PROFILE_ID\" = '$EXPECTED_PROFILE' ] || {
  echo \"release AOT smoke: active profile \$PLUTO_PROFILE_ID does not match $EXPECTED_PROFILE\" >&2
  exit 82
}"
}

stage() {
  local label="$1"
  local app_id="$2"
  local digest
  sleep "$CAPTURE_SETTLE"
  local output="$SCREENSHOT_DIR/$label.png"
  [[ ! -e "$output" && ! -L "$output" ]] || {
    echo "release AOT smoke: screenshot already exists: $output" >&2
    return 73
  }
  "$CLI" screenshot --device "$DEVICE" --app "$app_id" \
    --surface post-dither -o "$output"
  [[ -s "$output" && ! -L "$output" ]] || {
    echo "release AOT smoke: screenshot is empty or linked: $output" >&2
    return 74
  }
  digest="$(sha256_file "$output")"
  printf '%s\t%s\t%s\t%s\n' "$label" "$digest" "${output##*/}" \
    "$app_id" >> "$SCREENSHOT_DIR/stages.tsv"
  if [[ -n "$STAGE_HOOK" ]]; then
    "$STAGE_HOOK" "$label"
  fi
  sleep "$STAGE_DELAY"
}

verify_common_supervisor() {
  verify_release_identity || return $?
  remote 'set -eu
matched=0
matched_unit=""
matched_pid=""
for unit in xochitl.service pluto-session-once.service; do
  systemctl is-active --quiet "$unit" 2>/dev/null || continue
  pid=$(systemctl show "$unit" -p MainPID 2>/dev/null |
    sed -n "s/^MainPID=//p")
  case "$pid" in ""|*[!0-9]*|0|1) continue ;; esac
  kill -0 "$pid" 2>/dev/null || continue
  cmd=$(tr "\000" " " < "/proc/$pid/cmdline")
  case "$cmd" in
    *"/home/root/pluto/bin/pluto-session.sh start"*)
      matched=$((matched + 1))
      matched_unit=$unit
      matched_pid=$pid
      ;;
  esac
done
[ "$matched" -eq 1 ] || {
  echo "release AOT smoke: expected exactly one common Pluto supervisor, found $matched" >&2
  exit 84
}
if [ "$matched_unit" = pluto-session-once.service ]; then
  ! systemctl is-active --quiet xochitl.service 2>/dev/null || {
    echo "release AOT smoke: stock xochitl and current-boot Pluto both own the session" >&2
    exit 84
  }
fi
echo "release AOT smoke: PASS common supervisor unit=$matched_unit pid=$matched_pid"' || return $?
}

verify_app() {
  local app_id="$1"
  local app_root="$2"
  local stage_label="$3"
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
start_ticks=\$(sed 's/^.*) //' \"/proc/\$pid/stat\" | cut -d ' ' -f 20)
case \"\$start_ticks\" in ''|*[!0-9]*) exit 84 ;; esac
app_env=\$(tr '\\000' '\\n' < \"/proc/\$pid/environ\" |
  sed -n 's/^PLUTO_APP_ID=//p' | sed -n '1p')
[ \"\$app_env\" = '$app_id' ] || exit 84
grep -q 'mode=release.*aot=true' /home/root/pluto/logs/current.log
sleep 2
kill -0 \"\$pid\"
[ \"\$(cat /run/pluto/embedder.pid 2>/dev/null)\" = \"\$pid\" ] || exit 85
current_start_ticks=\$(sed 's/^.*) //' \"/proc/\$pid/stat\" | cut -d ' ' -f 20)
[ \"\$current_start_ticks\" = \"\$start_ticks\" ] || exit 85
current_cmd=\$(tr '\\000' ' ' < \"/proc/\$pid/cmdline\")
[ \"\$current_cmd\" = \"\$cmd\" ] || exit 85
current_ready=''
current_health=''
for arg in \$(tr '\\000' '\\n' < \"/proc/\$pid/cmdline\"); do
  case \"\$arg\" in
    --ready-file=*) current_ready=\${arg#*=} ;;
    --health-file=*) current_health=\${arg#*=} ;;
  esac
done
[ \"\$current_ready\" = \"\$ready_file\" ] &&
  [ \"\$current_health\" = \"\$health_file\" ] &&
  [ \"\$(cat \"\$current_ready\" 2>/dev/null || true)\" = ready ] || exit 85
set -- \$(cat \"\$health_file\" 2>/dev/null || true)
[ \"\$#\" -eq 3 ] && [ \"\$1\" = \"pid=\$pid\" ] || exit 85
seq_after=\${2#seq=}
mono_after=\${3#mono_ms=}
[ \"\$seq_after\" -gt \"\$seq_before\" ] &&
  [ \"\$mono_after\" -gt \"\$mono_before\" ] || exit 86
echo \"release AOT smoke: PASS $app_id pid=\$pid start_ticks=\$start_ticks ready=\$ready_file health=\$health_file present_after=\${i}s\"" || return $?
  verify_common_supervisor || return $?
  if [[ -n "$stage_label" ]]; then
    stage "$stage_label" "$app_id" || return $?
  fi
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
exit 87" || return $?

  stage "switcher-$origin" dev.pluto.launcher || return $?
}

select_switcher_preview() {
  local target
  target="$(remote "sed -n '2p' /run/pluto/switcher-active 2>/dev/null")" ||
    return $?
  [[ "$target" == dev.pluto.codex ]] || {
    echo "release AOT smoke: switcher did not expose deterministic Codex target (got: $target)" >&2
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
  --request '{\"requestId\":\"release-aot-switch\",\"action\":\"tap-switcher-preview\",\"appId\":\"dev.pluto.launcher\"}')
expected_response='{\"requestId\":\"release-aot-switch\",\"ok\":true,\"result\":{\"appId\":\"dev.pluto.launcher\",\"pid\":'"\$launcher_pid"',\"eventCount\":4}}'
[ \"\$response\" = \"\$expected_response\" ] || {
  echo \"release AOT smoke: switcher tap returned unbound metadata: \$response\" >&2
  exit 91
}
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
exit 93" || return $?

  stage "switcher-selected-$target" "$target" || return $?
}

prepare_ink_canvas() {
  remote "set -eu
pid=\$(cat /run/pluto/embedder.pid 2>/dev/null || true)
case \"\$pid\" in ''|*[!0-9]*) exit 89 ;; esac
start_ticks=\$(sed 's/^.*) //' \"/proc/\$pid/stat\" | cut -d ' ' -f 20)
case \"\$start_ticks\" in ''|*[!0-9]*) exit 89 ;; esac
cmd=\$(tr '\\000' ' ' < \"/proc/\$pid/cmdline\")
case \"\$cmd\" in
  *--release*--bundle=/home/root/pluto/apps/dev.pluto.ink/bundle*) ;;
  *) echo \"release AOT smoke: Ink is not the foreground release process\" >&2; exit 90 ;;
esac
request=\$(printf '%s' \
  '{\"requestId\":\"release-aot-prepare-ink\",\"action\":\"prepare-ink-canvas\",\"appId\":\"dev.pluto.ink\",\"expectedPid\":'\"\$pid\"'}')
response=\$(/home/root/pluto/bin/pluto-controlctl \\
  --socket /run/pluto/embedder-control.sock --request \"\$request\")
expected_prefix='{\"requestId\":\"release-aot-prepare-ink\",\"ok\":true,\"result\":{\"appId\":\"dev.pluto.ink\",\"pid\":'"\$pid"',\"canvasReady\":true,\"actionCount\":'
case \"\$response\" in
  \"\${expected_prefix}0}\" | \"\${expected_prefix}1}\" | \"\${expected_prefix}2}\") ;;
  *) echo \"release AOT smoke: Ink canvas preparation returned unbound metadata: \$response\" >&2; exit 91 ;;
esac
[ \"\$(cat /run/pluto/embedder.pid 2>/dev/null)\" = \"\$pid\" ] || exit 92
kill -0 \"\$pid\" 2>/dev/null || exit 92
[ \"\$(sed 's/^.*) //' \"/proc/\$pid/stat\" | cut -d ' ' -f 20)\" = \
  \"\$start_ticks\" ] || exit 92
echo \"release AOT smoke: PASS real Ink canvas pid=\$pid start_ticks=\$start_ticks response=\$response\"" || return $?
}

inject_ink_stroke() {
  remote "set -eu
pid=\$(cat /run/pluto/embedder.pid 2>/dev/null || true)
case \"\$pid\" in ''|*[!0-9]*) exit 89 ;; esac
start_ticks=\$(sed 's/^.*) //' \"/proc/\$pid/stat\" | cut -d ' ' -f 20)
case \"\$start_ticks\" in ''|*[!0-9]*) exit 89 ;; esac
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
  --request '{\"requestId\":\"release-aot-stroke\",\"action\":\"draw-stroke\",\"appId\":\"dev.pluto.ink\",\"expectedPid\":'\"\$pid\"'}')
expected_response='{\"requestId\":\"release-aot-stroke\",\"ok\":true,\"result\":{\"appId\":\"dev.pluto.ink\",\"pid\":'"\$pid"',\"eventCount\":24}}'
[ \"\$response\" = \"\$expected_response\" ] || {
  echo \"release AOT smoke: Ink stroke response is not exact and PID-bound: \$response\" >&2
  exit 93
}
i=0
while [ \"\$i\" -lt 30 ]; do
  [ \"\$(cat /run/pluto/embedder.pid 2>/dev/null)\" = \"\$pid\" ] || exit 94
  [ \"\$(sed 's/^.*) //' \"/proc/\$pid/stat\" | cut -d ' ' -f 20)\" = \
    \"\$start_ticks\" ] || exit 94
  set -- \$(cat \"\$health_file\" 2>/dev/null || true)
  if [ \"\$#\" -eq 3 ] && [ \"\${2#seq=}\" -gt \"\$seq_before\" ]; then
    echo \"release AOT smoke: PASS Ink stroke pid=\$pid start_ticks=\$start_ticks response=\$response\"
    exit 0
  fi
  sleep 1
  i=\$((i + 1))
done
echo \"release AOT smoke: Ink stroke produced no completion-backed present\" >&2
exit 94" || return $?

  stage "ink-stroke" dev.pluto.ink || return $?
  local before after pixel_delta
  before="$SCREENSHOT_DIR/ink-canvas-before-stroke.png"
  after="$SCREENSHOT_DIR/ink-stroke.png"
  pixel_delta="$(central_pixel_difference "$before" "$after")" || {
    echo "release AOT smoke: Ink stroke did not materially change decoded central post-dither pixels" >&2
    return 95
  }
  echo "release AOT smoke: PASS Ink decoded central pixel delta YAVG=$pixel_delta"
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
fi" || return $?
}

verify_app \
  dev.pluto.examples.counter \
  /home/root/pluto/apps/dev.pluto.examples.counter \
  app-dev.pluto.examples.counter
verify_app \
  dev.pluto.examples.motion_lab \
  /home/root/pluto/apps/dev.pluto.examples.motion_lab \
  app-dev.pluto.examples.motion_lab
verify_app \
  dev.pluto.examples.ink_lab \
  /home/root/pluto/apps/dev.pluto.examples.ink_lab \
  app-dev.pluto.examples.ink_lab
verify_app \
  dev.pluto.validation_lab \
  /home/root/pluto/apps/dev.pluto.validation_lab \
  app-dev.pluto.validation_lab
verify_app \
  dev.pluto.codex \
  /home/root/pluto/apps/dev.pluto.codex \
  app-dev.pluto.codex
verify_real_codex
verify_app \
  dev.pluto.ink \
  /home/root/pluto/apps/dev.pluto.ink \
  app-dev.pluto.ink-before-switcher

open_switcher dev.pluto.ink
select_switcher_preview
verify_app \
  dev.pluto.ink \
  /home/root/pluto/apps/dev.pluto.ink \
  ''
prepare_ink_canvas
stage ink-canvas-before-stroke dev.pluto.ink
inject_ink_stroke
verify_app \
  dev.pluto.launcher \
  /home/root/pluto/launcher \
  app-dev.pluto.launcher

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
echo "release AOT smoke: all standard apps and switcher passed; Ink changed decoded post-dither pixels; debug/JIT state absent"'
verify_common_supervisor
if [[ "$REQUIRE_VISUAL" == 1 ]]; then
  metrics_args=(
    --device "$SSH_TARGET"
    --samples 5
    --interval-seconds 1
    --release-manifest "$RELEASE_MANIFEST"
    --output "$CAMERA_DIR/metrics"
  )
  if [[ -n "$SSH_PORT" ]]; then
    metrics_args+=(--port "$SSH_PORT")
  fi
  "$METRICS_COLLECTOR" "${metrics_args[@]}"
  echo "release AOT smoke: COLLECTED_NOT_ACCEPTED optical review receipt and final verifier still required"
fi
