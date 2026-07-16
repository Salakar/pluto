#!/bin/sh
# Runtime-only Pluto activation for a profile whose persistent boot-default
# recovery gate is closed. The transient service owns the current panel session;
# its stop/failure path restarts stock xochitl, and /run disappears on reboot.
set -u

ROOT="${PLUTO_ROOT:-/home/root/pluto}"
RUN_DIR="${PLUTO_RUN_DIR:-/run/pluto}"
SYSTEMCTL="${PLUTO_SYSTEMCTL:-systemctl}"
RUNTIME_UNITS="${PLUTO_SYSTEMD_RUNTIME_DIR:-/run/systemd/system}"
PROFILE_FILE="${PLUTO_PROFILE_FILE:-$ROOT/share/device-profiles.sh}"
UNIT_NAME=pluto-session-once.service
UNIT="$RUNTIME_UNITS/$UNIT_NAME"
SUPERVISOR="$ROOT/bin/pluto-session.sh"
SESSION_ONCE="$ROOT/bin/pluto-session-once.sh"
CPU_FREQUENCY_RESTORE="$ROOT/bin/pluto-rm2-cpufreq-restore.sh"
DISPLAY_DRIVER=
HEALTH_GATE_ATTEMPTS=45
HEALTH_GATE_POLL_SECONDS=1
PROC_ROOT=/proc
HEALTH_GATE_ERROR=
FOREGROUND_PID=
FOREGROUND_START_TICKS=
FOREGROUND_READY_FILE=
FOREGROUND_HEALTH_FILE=
FOREGROUND_HEALTH_SEQ=
FOREGROUND_HEALTH_MONO=

log() { printf '[pluto-once %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

safe_path() {
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9_./-]*|*/../*|*/..|*/./*|*/.) return 1 ;;
  esac
}

safe_root() {
  safe_path "$ROOT" && safe_path "$RUN_DIR" && safe_path "$PROFILE_FILE"
}

is_uint() {
  case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac
}

is_uuid() {
  [ "${#1}" -eq 36 ] || return 1
  case "$1" in
    ????????-????-????-????-????????????) ;;
    *) return 1 ;;
  esac
  uuid_hex=$(printf '%s' "$1" | tr -d '-')
  [ "${#uuid_hex}" -eq 32 ] || return 1
  case "$uuid_hex" in *[!0-9A-Fa-f]*) return 1 ;; esac
}

rotation_value_valid() {
  case "$1" in 0 | 90 | 180 | 270) return 0 ;; *) return 1 ;; esac
}

rotation_list_valid() {
  case "$1" in '' | ,* | *, | *,,* | *[!0-9,]*) return 1 ;; esac
  rotation_list_value=$1
  rotation_list_old_ifs=$IFS
  IFS=,
  set -- $rotation_list_value
  IFS=$rotation_list_old_ifs
  [ "$#" -ge 1 ] && [ "$#" -le 4 ] || return 1
  rotation_list_seen=,
  for rotation_list_item do
    rotation_value_valid "$rotation_list_item" || return 1
    case "$rotation_list_seen" in
      *,"$rotation_list_item",*) return 1 ;;
    esac
    rotation_list_seen="$rotation_list_seen$rotation_list_item,"
  done
}

rotation_list_contains() {
  case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac
}

presenter_options_match_profile() {
  presenter_options_value=$1
  if [ -z "${PLUTO_PROFILE_WAVEFORM_OPTION_KEY:-}" ]; then
    [ "$presenter_options_value" = "${PLUTO_PROFILE_PRESENTER_OPTIONS:-}" ]
    return $?
  fi
  if [ -n "${PLUTO_PROFILE_PRESENTER_OPTIONS:-}" ]; then
    presenter_options_prefix="$PLUTO_PROFILE_PRESENTER_OPTIONS,$PLUTO_PROFILE_WAVEFORM_OPTION_KEY="
  else
    presenter_options_prefix="$PLUTO_PROFILE_WAVEFORM_OPTION_KEY="
  fi
  case "$presenter_options_value" in
    "$presenter_options_prefix"*) ;;
    *) return 1 ;;
  esac
  presenter_waveform=${presenter_options_value#"$presenter_options_prefix"}
  [ -n "$presenter_waveform" ] || return 1
  command -v pluto_profile_waveform_sources >/dev/null 2>&1 || return 1
  presenter_waveform_sources=$(pluto_profile_waveform_sources 2>/dev/null) || return 1
  [ -n "$presenter_waveform_sources" ] || return 1
  presenter_waveform_matches=0
  while IFS='|' read -r presenter_waveform_candidate presenter_waveform_sha \
    presenter_waveform_panel presenter_waveform_extra; do
    [ -n "$presenter_waveform_candidate" ] || continue
    [ -z "$presenter_waveform_extra" ] || return 1
    [ "$presenter_waveform" = "$presenter_waveform_candidate" ] || continue
    [ -n "${PLUTO_PROFILE_PANEL_SIGNATURE:-}" ] &&
      [ "$presenter_waveform_panel" = "$PLUTO_PROFILE_PANEL_SIGNATURE" ] ||
      continue
    [ "${#presenter_waveform_sha}" -eq 64 ] || return 1
    case "$presenter_waveform_sha" in *[!0-9A-Fa-f]*) return 1 ;; esac
    if [ "${PLUTO_TESTING:-0}" != 1 ]; then
      [ -r "$presenter_waveform_candidate" ] || continue
      command -v sha256sum >/dev/null 2>&1 || return 1
      presenter_waveform_actual_sha=$(
        sha256sum "$presenter_waveform_candidate" 2>/dev/null || true
      )
      presenter_waveform_actual_sha=${presenter_waveform_actual_sha%% *}
      [ "$presenter_waveform_actual_sha" = "$presenter_waveform_sha" ] ||
        continue
    fi
    presenter_waveform_matches=$((presenter_waveform_matches + 1))
  done <<EOF
$presenter_waveform_sources
EOF
  [ "$presenter_waveform_matches" -eq 1 ]
}

process_owned_by_transient_unit() {
  process_cgroup_file="$PROC_ROOT/$1/cgroup"
  [ -f "$process_cgroup_file" ] && [ ! -L "$process_cgroup_file" ] ||
    return 1
  process_owned_cgroup=0
  while IFS=: read -r process_cgroup_hierarchy process_cgroup_controllers \
    process_cgroup_path; do
    case "$process_cgroup_path" in */"$UNIT_NAME") process_owned_cgroup=1 ;; esac
  done < "$process_cgroup_file"
  [ "$process_owned_cgroup" -eq 1 ]
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

file_uid() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null
}

one_line() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  line_count=$(wc -l < "$1" 2>/dev/null | tr -d '[:space:]') || return 1
  [ "$line_count" = 1 ] || return 1
  cat "$1" 2>/dev/null
}

process_start_ticks() {
  process_stat=$(cat "$PROC_ROOT/$1/stat" 2>/dev/null) || return 1
  after_comm=${process_stat#*) }
  [ "$after_comm" != "$process_stat" ] || return 1
  set -- $after_comm
  [ "$#" -ge 20 ] || return 1
  shift 19
  is_uint "$1" || return 1
  printf '%s\n' "$1"
}

configure_health_gate() {
  if [ "${PLUTO_TESTING:-0}" = 1 ]; then
    HEALTH_GATE_ATTEMPTS="${PLUTO_TEST_ONCE_HEALTH_ATTEMPTS:-45}"
    HEALTH_GATE_POLL_SECONDS="${PLUTO_TEST_ONCE_HEALTH_POLL_SECONDS:-1}"
    PROC_ROOT="${PLUTO_TEST_ONCE_PROC_ROOT:-/proc}"
  elif [ -n "${PLUTO_TEST_ONCE_HEALTH_ATTEMPTS:-}" ] ||
       [ -n "${PLUTO_TEST_ONCE_HEALTH_POLL_SECONDS:-}" ] ||
       [ -n "${PLUTO_TEST_ONCE_PROC_ROOT:-}" ] ||
       [ -n "${PLUTO_TEST_ONCE_BEFORE_FINAL_FENCE:-}" ]; then
    die "transient health-gate test seams are forbidden outside test mode"
  fi

  is_uint "$HEALTH_GATE_ATTEMPTS" &&
    [ "$HEALTH_GATE_ATTEMPTS" -ge 3 ] &&
    [ "$HEALTH_GATE_ATTEMPTS" -le 45 ] ||
    die "invalid transient health-gate attempt bound"
  case "$HEALTH_GATE_POLL_SECONDS" in
    0.01 | 0.02 | 0.05 | 0.1 | 0.2 | 0.5 | 1) ;;
    *) die "invalid transient health-gate poll interval" ;;
  esac
  safe_path "$PROC_ROOT" || die "unsafe transient health-gate proc root"
}

foreground_pending() {
  HEALTH_GATE_ERROR=$1
  return 1
}

foreground_malformed() {
  HEALTH_GATE_ERROR=$1
  return 2
}

inspect_foreground() {
  HEALTH_GATE_ERROR=
  pid_file="$RUN_DIR/embedder.pid"
  if [ ! -e "$pid_file" ] && [ ! -L "$pid_file" ]; then
    foreground_pending "foreground PID receipt is not published"
    return $?
  fi
  pid=$(one_line "$pid_file") || {
    foreground_malformed "foreground PID receipt is malformed"
    return $?
  }
  case "$pid" in '' | *[!0-9]* | 0 | 1)
    foreground_malformed "foreground PID receipt is malformed"
    return $?
    ;;
  esac
  kill -0 "$pid" 2>/dev/null || {
    foreground_malformed "foreground process is not live"
    return $?
  }
  start_ticks=$(process_start_ticks "$pid") || {
    foreground_malformed "foreground process identity is malformed"
    return $?
  }

  active_root=$(readlink -f "$ROOT" 2>/dev/null || true)
  expected_exe=$(readlink -f "$ROOT/bin/pluto-embedder" 2>/dev/null || true)
  observed_exe=$(readlink -f "$PROC_ROOT/$pid/exe" 2>/dev/null || true)
  if [ -z "$active_root" ] || [ -z "$expected_exe" ] ||
     [ "$expected_exe" != "$active_root/bin/pluto-embedder" ] ||
     [ "$observed_exe" != "$expected_exe" ]; then
    foreground_malformed "foreground executable is not the active immutable release"
    return $?
  fi
  process_owned_by_transient_unit "$pid" || {
    foreground_malformed "foreground process is outside the transient service"
    return $?
  }

  cmdline_file="$PROC_ROOT/$pid/cmdline"
  [ -f "$cmdline_file" ] && [ ! -L "$cmdline_file" ] || {
    foreground_malformed "foreground command line is unavailable"
    return $?
  }
  cmdline=$(tr '\000' '\n' < "$cmdline_file" 2>/dev/null) || {
    foreground_malformed "foreground command line is unreadable"
    return $?
  }
  command_path=
  command_count=0
  release_count=0
  forbidden_mode=0
  bundle=
  bundle_count=0
  engine=
  engine_count=0
  icu_data=
  icu_count=0
  presenter=
  presenter_count=0
  run_path=
  run_count=0
  ready_file=
  ready_count=0
  health_file=
  health_count=0
  aot_elf=
  aot_count=0
  presenter_options=
  presenter_options_count=0
  touch_device=
  touch_count=0
  pen_device=
  pen_count=0
  rotation=
  rotation_count=0
  allowed_rotations=
  allowed_rotations_count=0
  auto_rotate_count=0
  bezel_redraw_count=0
  hibernate_count=0
  dart_entrypoint_count=0
  unknown_argument=0
  while IFS= read -r arg; do
    command_count=$((command_count + 1))
    if [ "$command_count" -eq 1 ]; then
      command_path=$arg
      continue
    fi
    case "$arg" in
      --release) release_count=$((release_count + 1)) ;;
      --debug | --profile) forbidden_mode=1 ;;
      --bundle=*) bundle=${arg#*=}; bundle_count=$((bundle_count + 1)) ;;
      --engine=*) engine=${arg#*=}; engine_count=$((engine_count + 1)) ;;
      --icu-data=*) icu_data=${arg#*=}; icu_count=$((icu_count + 1)) ;;
      --presenter=*) presenter=${arg#*=}; presenter_count=$((presenter_count + 1)) ;;
      --presenter-options=*)
        presenter_options=${arg#*=}
        presenter_options_count=$((presenter_options_count + 1))
        ;;
      --touch-device=*) touch_device=${arg#*=}; touch_count=$((touch_count + 1)) ;;
      --pen-device=*) pen_device=${arg#*=}; pen_count=$((pen_count + 1)) ;;
      --rotation=*) rotation=${arg#*=}; rotation_count=$((rotation_count + 1)) ;;
      --allowed-rotations=*)
        allowed_rotations=${arg#*=}
        allowed_rotations_count=$((allowed_rotations_count + 1))
        ;;
      --run-dir=*) run_path=${arg#*=}; run_count=$((run_count + 1)) ;;
      --ready-file=*) ready_file=${arg#*=}; ready_count=$((ready_count + 1)) ;;
      --health-file=*) health_file=${arg#*=}; health_count=$((health_count + 1)) ;;
      --aot-elf=*) aot_elf=${arg#*=}; aot_count=$((aot_count + 1)) ;;
      --auto-rotate) auto_rotate_count=$((auto_rotate_count + 1)) ;;
      --bezel-redraw) bezel_redraw_count=$((bezel_redraw_count + 1)) ;;
      --hibernate) hibernate_count=$((hibernate_count + 1)) ;;
      --dart-entrypoint-args=--standby | --dart-entrypoint-args=--switcher | \
        --dart-entrypoint-args=--status | --dart-entrypoint-args=--power-menu)
        dart_entrypoint_count=$((dart_entrypoint_count + 1))
        ;;
      *) unknown_argument=1 ;;
    esac
  done <<EOF
$cmdline
EOF

  if [ "$command_path" != "$ROOT/bin/pluto-embedder" ] ||
     [ "$release_count" -ne 1 ] || [ "$forbidden_mode" -ne 0 ] ||
     [ "$bundle_count" -ne 1 ] || [ "$engine_count" -ne 1 ] ||
     [ "$icu_count" -ne 1 ] || [ "$presenter_count" -ne 1 ] ||
     [ "$presenter_options_count" -ne 1 ] || [ "$touch_count" -ne 1 ] ||
     [ "$pen_count" -ne 1 ] || [ "$rotation_count" -ne 1 ] ||
     [ "$allowed_rotations_count" -ne 1 ] ||
     [ "$run_count" -ne 1 ] || [ "$ready_count" -ne 1 ] ||
     [ "$health_count" -ne 1 ] || [ "$aot_count" -ne 1 ] ||
     [ "$hibernate_count" -ne 1 ] || [ "$auto_rotate_count" -gt 1 ] ||
     [ "$bezel_redraw_count" -gt 1 ] || [ "$dart_entrypoint_count" -gt 1 ] ||
     [ "$unknown_argument" -ne 0 ]; then
    foreground_malformed "foreground command line is not exact release AOT"
    return $?
  fi
  app_id=
  case "$bundle" in
    "$ROOT/launcher/bundle")
      expected_bundle="$active_root/launcher/bundle"
      ;;
    "$ROOT/apps/"*)
      bundle_relative=${bundle#"$ROOT/apps/"}
      app_id=${bundle_relative%/bundle}
      if [ "$bundle_relative" != "$app_id/bundle" ]; then
        foreground_malformed "foreground app bundle is not one exact directory"
        return $?
      fi
      case "$app_id" in
        '' | . | .. | */* | *[!A-Za-z0-9._-]*)
          foreground_malformed "foreground app id is malformed"
          return $?
          ;;
      esac
      expected_bundle="$active_root/apps/$app_id/bundle"
      ;;
    *)
      foreground_malformed "foreground bundle is outside the active release"
      return $?
      ;;
  esac
  resolved_bundle=$(readlink -f "$bundle" 2>/dev/null || true)
  resolved_engine=$(readlink -f "$engine" 2>/dev/null || true)
  resolved_icu=$(readlink -f "$icu_data" 2>/dev/null || true)
  resolved_aot=$(readlink -f "$aot_elf" 2>/dev/null || true)
  if [ "$engine" != "$ROOT/engine/release/libflutter_engine.so" ] ||
     [ "$icu_data" != "$bundle/icudtl.dat" ] ||
     [ "$presenter" != native ] ||
     ! presenter_options_match_profile "$presenter_options" ||
     [ "$touch_device" != "${PLUTO_PROFILE_TOUCH_DEVICE:-}" ] ||
     [ "$pen_device" != "${PLUTO_PROFILE_PEN_DEVICE:-}" ] ||
     ! rotation_value_valid "$rotation" ||
     ! rotation_list_valid "$allowed_rotations" ||
     ! rotation_list_contains "$allowed_rotations" "$rotation" ||
     [ "$run_path" != "$RUN_DIR" ] ||
     [ "$aot_elf" != "$bundle/lib/app.so" ] ||
     [ "$resolved_bundle" != "$expected_bundle" ] ||
     [ "$resolved_engine" != "$active_root/engine/release/libflutter_engine.so" ] ||
     [ "$resolved_icu" != "$expected_bundle/icudtl.dat" ] ||
     [ "$resolved_aot" != "$expected_bundle/lib/app.so" ]; then
    foreground_malformed "foreground release AOT paths do not match"
    return $?
  fi

  case "$ready_file" in
    "$RUN_DIR/boot-ready."*) receipt_suffix=${ready_file#"$RUN_DIR/boot-ready."} ;;
    *)
      foreground_malformed "foreground ready receipt path is outside the run directory"
      return $?
      ;;
  esac
  case "$receipt_suffix" in manual-*) ;; *)
    foreground_malformed "foreground ready receipt is not a transient nonce"
    return $?
    ;;
  esac
  receipt_body=${receipt_suffix#manual-}
  boot_nonce=${receipt_body%%.*}
  launch_and_serial=${receipt_body#"$boot_nonce."}
  launch_serial=${launch_and_serial##*-}
  launch_nonce=${launch_and_serial%-"$launch_serial"}
  if [ "$receipt_body" = "$boot_nonce" ] || ! is_uuid "$boot_nonce" ||
     ! is_uuid "$launch_nonce" || ! is_uint "$launch_serial" ||
     [ "${#launch_serial}" -gt 18 ] ||
     [ "$launch_serial" = 0 ] || [ "${launch_serial#0}" != "$launch_serial" ]; then
    foreground_malformed "foreground ready receipt nonce is malformed"
    return $?
  fi
  [ "$health_file" = "$RUN_DIR/health.$receipt_suffix" ] || {
    foreground_malformed "foreground ready and health receipt nonces differ"
    return $?
  }

  if [ ! -e "$ready_file" ] && [ ! -L "$ready_file" ]; then
    foreground_pending "foreground ready receipt is not published"
    return $?
  fi
  [ "$(one_line "$ready_file" 2>/dev/null || true)" = ready ] || {
    foreground_malformed "foreground ready receipt is malformed"
    return $?
  }
  [ "$(file_mode "$ready_file" 2>/dev/null || true)" = 600 ] || {
    foreground_malformed "foreground ready receipt mode is not private"
    return $?
  }
  if [ "${PLUTO_TESTING:-0}" != 1 ] &&
     [ "$(file_uid "$ready_file" 2>/dev/null || true)" != 0 ]; then
    foreground_malformed "foreground ready receipt is not root-owned"
    return $?
  fi

  if [ ! -e "$health_file" ] && [ ! -L "$health_file" ]; then
    foreground_pending "foreground health receipt is not published"
    return $?
  fi
  health_record=$(one_line "$health_file") || {
    foreground_malformed "foreground health receipt is malformed"
    return $?
  }
  [ "$(file_mode "$health_file" 2>/dev/null || true)" = 600 ] || {
    foreground_malformed "foreground health receipt mode is not private"
    return $?
  }
  if [ "${PLUTO_TESTING:-0}" != 1 ] &&
     [ "$(file_uid "$health_file" 2>/dev/null || true)" != 0 ]; then
    foreground_malformed "foreground health receipt is not root-owned"
    return $?
  fi
  set -- $health_record
  [ "$#" -eq 3 ] || {
    foreground_malformed "foreground health record has the wrong field count"
    return $?
  }
  seq=${2#seq=}
  mono=${3#mono_ms=}
  if [ "$1" != "pid=$pid" ] || [ "$2" != "seq=$seq" ] ||
     [ "$3" != "mono_ms=$mono" ] || ! is_uint "$seq" ||
     ! is_uint "$mono" || [ "$seq" = 0 ] || [ "$mono" = 0 ] ||
     [ "${#seq}" -gt 18 ] || [ "${#mono}" -gt 18 ] ||
     [ "$health_record" != "pid=$pid seq=$seq mono_ms=$mono" ]; then
    foreground_malformed "foreground health record is not exact"
    return $?
  fi
  [ "$(process_start_ticks "$pid" 2>/dev/null || true)" = "$start_ticks" ] || {
    foreground_malformed "foreground process identity changed during inspection"
    return $?
  }
  if [ "${PLUTO_TESTING:-0}" = 1 ] &&
     [ -n "${PLUTO_TEST_ONCE_BEFORE_FINAL_FENCE:-}" ]; then
    "$PLUTO_TEST_ONCE_BEFORE_FINAL_FENCE" "$pid" || {
      foreground_malformed "transient inspection test hook failed"
      return $?
    }
  fi
  [ "$(readlink -f "$ROOT" 2>/dev/null || true)" = "$active_root" ] &&
    [ "$(readlink -f "$PROC_ROOT/$pid/exe" 2>/dev/null || true)" = "$expected_exe" ] &&
    [ "$(one_line "$pid_file" 2>/dev/null || true)" = "$pid" ] &&
    [ "$(process_start_ticks "$pid" 2>/dev/null || true)" = "$start_ticks" ] &&
    [ "$(tr '\000' '\n' < "$cmdline_file" 2>/dev/null || true)" = "$cmdline" ] &&
    process_owned_by_transient_unit "$pid" &&
    "$SYSTEMCTL" is-active --quiet "$UNIT_NAME" 2>/dev/null || {
    foreground_malformed "foreground identity changed during final inspection fence"
    return $?
  }

  FOREGROUND_PID=$pid
  FOREGROUND_START_TICKS=$start_ticks
  FOREGROUND_READY_FILE=$ready_file
  FOREGROUND_HEALTH_FILE=$health_file
  FOREGROUND_HEALTH_SEQ=$seq
  FOREGROUND_HEALTH_MONO=$mono
  return 0
}

wait_for_healthy_foreground() {
  observed_pid=
  observed_start=
  observed_ready=
  observed_health=
  observed_seq=
  observed_mono=
  advances=0
  attempt=0
  while [ "$attempt" -lt "$HEALTH_GATE_ATTEMPTS" ]; do
    "$SYSTEMCTL" is-active --quiet "$UNIT_NAME" 2>/dev/null || {
      HEALTH_GATE_ERROR="transient supervisor stopped during health gating"
      return 1
    }
    inspect_rc=0
    inspect_foreground || inspect_rc=$?
    if [ "$inspect_rc" -eq 0 ]; then
      if [ -z "$observed_pid" ]; then
        observed_pid=$FOREGROUND_PID
        observed_start=$FOREGROUND_START_TICKS
        observed_ready=$FOREGROUND_READY_FILE
        observed_health=$FOREGROUND_HEALTH_FILE
        observed_seq=$FOREGROUND_HEALTH_SEQ
        observed_mono=$FOREGROUND_HEALTH_MONO
      elif [ "$FOREGROUND_PID" != "$observed_pid" ] ||
           [ "$FOREGROUND_START_TICKS" != "$observed_start" ] ||
           [ "$FOREGROUND_READY_FILE" != "$observed_ready" ] ||
           [ "$FOREGROUND_HEALTH_FILE" != "$observed_health" ]; then
        HEALTH_GATE_ERROR="foreground identity or receipt paths changed during health gating"
        return 1
      elif [ "$FOREGROUND_HEALTH_SEQ" -gt "$observed_seq" ] &&
           [ "$FOREGROUND_HEALTH_MONO" -gt "$observed_mono" ]; then
        observed_seq=$FOREGROUND_HEALTH_SEQ
        observed_mono=$FOREGROUND_HEALTH_MONO
        advances=$((advances + 1))
        if [ "$advances" -ge 2 ]; then
          return 0
        fi
      elif [ "$FOREGROUND_HEALTH_SEQ" -ne "$observed_seq" ] ||
           [ "$FOREGROUND_HEALTH_MONO" -ne "$observed_mono" ]; then
        HEALTH_GATE_ERROR="foreground health sequence or monotonic clock regressed"
        return 1
      fi
    elif [ "$inspect_rc" -eq 2 ]; then
      return 1
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -ge "$HEALTH_GATE_ATTEMPTS" ] ||
      sleep "$HEALTH_GATE_POLL_SECONDS"
  done
  HEALTH_GATE_ERROR="${HEALTH_GATE_ERROR:-foreground health did not advance before the fixed deadline}"
  return 1
}

load_profile() {
  safe_root || die "unsafe Pluto runtime path"
  [ -r "$PROFILE_FILE" ] || die "missing generated profile: $PROFILE_FILE"
  # shellcheck source=generated/device-profiles.sh
  . "$PROFILE_FILE"
  if [ -n "${PLUTO_TEST_PROFILE_ID:-}" ]; then
    [ "${PLUTO_TESTING:-0}" = 1 ] ||
      die "test profile override is forbidden outside test mode"
    pluto_profile_load "$PLUTO_TEST_PROFILE_ID" ||
      die "unknown test profile: $PLUTO_TEST_PROFILE_ID"
  else
    pluto_profile_probe || die "device identity did not match one exact profile"
  fi
  [ "${PLUTO_PROFILE_NATIVE_SESSION_ENABLED:-}" = 1 ] ||
    die "native session is not enabled for the exact profile"
  case "${PLUTO_PROFILE_DISPLAY_DRIVER:-}" in
    gallery3_drm | lcdif_tcon | mxcfb_epdc)
      DISPLAY_DRIVER=$PLUTO_PROFILE_DISPLAY_DRIVER
      ;;
    *) die "generated profile has an invalid display driver" ;;
  esac
}

restore_cpu_frequency() {
  [ "$DISPLAY_DRIVER" = lcdif_tcon ] || return 0
  [ -x "$CPU_FREQUENCY_RESTORE" ] || {
    log "ERROR: RM2 CPU-frequency restorer is unavailable"
    return 1
  }
  "$CPU_FREQUENCY_RESTORE"
}

restore_stock() {
  restore_cpu_frequency || {
    log "ERROR: refusing stock restart with an unresolved CPU-frequency receipt"
    return 1
  }
  "$SYSTEMCTL" reset-failed xochitl.service 2>/dev/null || true
  if ! "$SYSTEMCTL" start xochitl.service; then
    log "ERROR: stock xochitl failed to restart"
    return 1
  fi
}

remove_unit() {
  rm -f "$UNIT" "$UNIT.tmp.$$"
  "$SYSTEMCTL" daemon-reload 2>/dev/null || true
}

do_start() {
  configure_health_gate
  [ -x "$SUPERVISOR" ] || die "missing executable supervisor: $SUPERVISOR"
  [ -x "$SESSION_ONCE" ] || die "missing executable session helper: $SESSION_ONCE"
  if [ "$DISPLAY_DRIVER" = lcdif_tcon ]; then
    [ -x "$CPU_FREQUENCY_RESTORE" ] ||
      die "missing executable CPU-frequency restorer: $CPU_FREQUENCY_RESTORE"
  fi
  mkdir -p "$RUNTIME_UNITS" "$RUN_DIR" ||
    die "cannot create transient runtime directories"

  # Retire an earlier one-shot session before replacing its runtime-only unit.
  "$SYSTEMCTL" stop "$UNIT_NAME" 2>/dev/null || true
  previous_state=$(
    "$SYSTEMCTL" show "$UNIT_NAME" -p ActiveState --value 2>/dev/null
  ) || die "cannot verify earlier transient service retirement"
  case "$previous_state" in
    inactive | failed) ;;
    *) die "cannot retire active or indeterminate transient service" ;;
  esac
  stale_pid_file="$RUN_DIR/embedder.pid"
  if [ -e "$stale_pid_file" ] || [ -L "$stale_pid_file" ]; then
    rm -f "$stale_pid_file" ||
      die "cannot retire stale foreground PID receipt"
  fi
  rm -f "$UNIT" "$UNIT.tmp.$$"
  cat > "$UNIT.tmp.$$" <<EOF || die "cannot stage transient service"
[Unit]
Description=Pluto current-boot native session
Conflicts=xochitl.service
After=local-fs.target
StartLimitIntervalSec=600
StartLimitBurst=2

[Service]
Type=simple
Environment=PLUTO_ROOT=$ROOT
Environment=PLUTO_RUN_DIR=$RUN_DIR
ExecStart=$SUPERVISOR start
ExecStopPost=$SESSION_ONCE restore-stock
Restart=no
KillMode=control-group
EOF
  chmod 0644 "$UNIT.tmp.$$" || die "cannot secure transient service"
  mv "$UNIT.tmp.$$" "$UNIT" || die "cannot publish transient service"
  "$SYSTEMCTL" daemon-reload || {
    remove_unit
    restore_stock || die "systemd rejected the transient service and stock xochitl did not restart"
    die "systemd rejected the transient service"
  }
  "$SYSTEMCTL" reset-failed "$UNIT_NAME" 2>/dev/null || true
  if ! "$SYSTEMCTL" start "$UNIT_NAME" ||
     ! "$SYSTEMCTL" is-active --quiet "$UNIT_NAME"; then
    "$SYSTEMCTL" stop "$UNIT_NAME" 2>/dev/null || true
    remove_unit
    restore_stock || die "one-shot Pluto supervisor failed and stock xochitl did not restart"
    die "one-shot Pluto supervisor did not become active"
  fi
  if ! wait_for_healthy_foreground; then
    gate_error=$HEALTH_GATE_ERROR
    "$SYSTEMCTL" stop "$UNIT_NAME" 2>/dev/null || true
    remove_unit
    restore_stock ||
      die "one-shot Pluto supervisor failed its health gate ($gate_error) and stock xochitl did not restart"
    die "one-shot Pluto supervisor failed its health gate: $gate_error"
  fi
  log "current-boot Pluto session healthy; stock remains the next boot default"
}

do_stop() {
  "$SYSTEMCTL" stop "$UNIT_NAME" 2>/dev/null || true
  remove_unit
  restore_stock || die "stock xochitl did not restart"
  log "one-shot Pluto session stopped; stock xochitl requested"
}

case "${1:-status}" in
  start) load_profile; do_start ;;
  stop) load_profile; do_stop ;;
  restore-stock) load_profile; restore_stock ;;
  status)
    load_profile
    if [ -f "$UNIT" ] && "$SYSTEMCTL" is-active --quiet "$UNIT_NAME"; then
      echo "one-shot Pluto session: active"
    else
      echo "one-shot Pluto session: inactive"
    fi
    ;;
  *) echo "usage: $0 {start|stop|restore-stock|status}"; exit 64 ;;
esac
