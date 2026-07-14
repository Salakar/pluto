#!/bin/sh
# Pluto session supervisor (device-side). No Dart runtime on device, so this
# native supervisor is the "plutod" that owns the profile-selected display
# handoff between the launcher and app embedders.
#
# App registry:  $ROOT/apps/<app-id>/{manifest.json, bundle/}
# Flavor engines: $ROOT/engine/{release,profile,debug}/libflutter_engine.so;
# debug is accepted only through the explicit one-shot hot-reload control.
# Control files (embedder writes them via the pluto/session channel):
#   /run/pluto/launch  -> app-id to launch next (consumed once)
#   /run/pluto/debug-launch -> one-shot app-id written by `pluto run --debug`
#   /run/pluto/home    -> return to the launcher
#   /run/pluto/standby -> launch the power-key-safe standby experience
#   /run/pluto/switcher -> app id requesting the warm running-app switcher
#   /run/pluto/force-stop -> background app id to terminate in place
#   /run/pluto/status  -> app id requesting the warm system status shade
#   /run/pluto/power-menu -> app id requesting the warm power menu
#   /run/pluto/poweroff -> drain all apps and power the device off
#   /run/pluto/suspend -> standby frame is settled; suspend after child exit
#   /run/pluto/stock   -> exit Pluto, restore stock xochitl
#
# Usage: pluto-session.sh [start|stop]
set -u
ROOT="${PLUTO_ROOT:-/home/root/pluto}"
DEBUG_ENGINE="${PLUTO_DEBUG_ENGINE:-$ROOT/engine/debug/libflutter_engine.so}"
PROFILE_ENGINE="${PLUTO_PROFILE_ENGINE:-$ROOT/engine/profile/libflutter_engine.so}"
RELEASE_ENGINE="${PLUTO_RELEASE_ENGINE:-$ROOT/engine/release/libflutter_engine.so}"
LAUNCHER_ID="dev.pluto.launcher"
CTL="${PLUTO_RUN_DIR:-/run/pluto}"
STATE="$ROOT/state"
BOOT_DROPIN="${PLUTO_BOOT_DROPIN:-/usr/lib/systemd/system/xochitl.service.d/zz-pluto.conf}"
STOCK_XOCHITL="${PLUTO_STOCK_XOCHITL:-/usr/bin/xochitl}"
READY_FILE="${PLUTO_READY_FILE:-$CTL/boot-ready}"
EMBEDDER_PID_FILE="${PLUTO_EMBEDDER_PID_FILE:-$CTL/embedder.pid}"
WARM_DIR="$CTL/warm-apps"
HIBERNATED_DIR="$CTL/hibernated"
# Total resident release/profile processes, including the foreground app.
# Four keeps launcher + three recent apps instant while bounding RAM on the
# device. Set to 1 to retain the protocol but effectively disable caching.
MAX_WARM_APPS="${PLUTO_MAX_WARM_APPS:-4}"
# Native detach owns a 5s optical fence before renderer encoding, atomic tmpfs
# publication, presenter close, and marker publication. Keep the supervisor's
# envelope strictly wider so a safe exact-color close is never killed at its
# own deadline. Ordinary handoffs still acknowledge immediately.
HIBERNATE_WAIT_TICKS="${PLUTO_HIBERNATE_WAIT_TICKS:-240}"
RESUME_WAIT_TICKS="${PLUTO_RESUME_WAIT_TICKS:-120}"
# Non-warm shutdown/stock exits do not perform an exact handoff and retain the
# previous bounded wait. Do not let the wider hibernate transaction envelope
# make those control paths slower.
FOREGROUND_EXIT_WAIT_TICKS="${PLUTO_FOREGROUND_EXIT_WAIT_TICKS:-120}"
BOOT_CONFIRM_DELAY="${PLUTO_BOOT_CONFIRM_DELAY:-30}"
BOOT_CONFIRM_TIMEOUT="${PLUTO_BOOT_CONFIRM_TIMEOUT:-20}"
POWER_WATCHER="${PLUTO_POWER_WATCHER:-$ROOT/bin/pluto-power-key-watch.sh}"
UPTIME_FILE="${PLUTO_UPTIME_FILE:-/proc/uptime}"
VPDD_IDLE_ATTEMPTS="${PLUTO_VPDD_IDLE_ATTEMPTS:-20}"
VPDD_IDLE_INTERVAL="${PLUTO_VPDD_IDLE_INTERVAL:-0.1}"
# `systemctl suspend` is intentionally asynchronous and returns as soon as the
# job is queued. Starting the same target with --wait instead gives us the
# post-resume receipt required before restoring light or launching an embedder.
SUSPEND_QUIESCE_DELAY="${PLUTO_SUSPEND_QUIESCE_DELAY:-0.5}"
POWER_OFF_COMMAND="${PLUTO_POWER_OFF_COMMAND:-systemctl poweroff}"
# Optional boot-default app (written by `pluto install --set-default`).
# Falls back to the launcher when unset or when the app cannot start.
DEFAULT_APP_FILE="$ROOT/state/default-app"
PROFILE_FILE="${PLUTO_PROFILE_FILE:-$ROOT/share/device-profiles.sh}"
BOOT_CONFIRM_DISPATCHER="${PLUTO_BOOT_CONFIRM_DISPATCHER:-$ROOT/bin/pluto-boot-confirm.sh}"
BACKLIGHT_BRIGHTNESS="${PLUTO_BACKLIGHT_BRIGHTNESS:-}"
VPDD_TIMEOUT_FILE="${PLUTO_VPDD_TIMEOUT_FILE:-}"
SUSPEND_COMMAND="${PLUTO_SUSPEND_COMMAND:-}"
WAVEFORM="${PLUTO_WAVEFORM:-}"
WAVEFORM_SHA256=""
WAVEFORM_PANEL_SIGNATURE=""
PRESENTER_OPTS="${PLUTO_PRESENTER_OPTS:-}"
PEN_DEVICE="${PLUTO_PEN_DEVICE:-}"
TOUCH_DEVICE="${PLUTO_TOUCH_DEVICE:-}"
POWER_KEY_DEVICE="${PLUTO_POWER_KEY_DEVICE:-}"
DISPLAY_DEVICE="${PLUTO_DISPLAY_DEVICE:-}"
BEZEL_REDRAW_IIO="${PLUTO_BEZEL_REDRAW_IIO:-}"
BEZEL_REDRAW_ENABLE="${PLUTO_BEZEL_REDRAW_ENABLE:-}"
PROFILE_CONFIGURED=0

log() { printf '[pluto-session %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

profile_input_name() {
  resolved="$(readlink -f "$1" 2>/dev/null || true)"
  [ -n "$resolved" ] || return 1
  event_node="${resolved##*/}"
  cat "/sys/class/input/$event_node/device/name" 2>/dev/null
}

validate_profile_input() {
  role="$1"
  path="$2"
  expected_name="$3"
  if [ ! -r "$path" ]; then
    log "profile rejected: $role input is not readable at $path"
    return 1
  fi
  actual_name="$(profile_input_name "$path" || true)"
  if [ "$actual_name" != "$expected_name" ]; then
    log "profile rejected: $role input '$actual_name' != '$expected_name' at $path"
    return 1
  fi
}

select_profile_waveform() {
  if ! command -v pluto_profile_waveform_sources >/dev/null 2>&1; then
    log "profile rejected: generated waveform source selector is missing"
    return 78
  fi
  waveform_sources="$(pluto_profile_waveform_sources)" || {
    log "profile rejected: no waveform contract for $PLUTO_PROFILE_ID"
    return 78
  }
  [ -n "$waveform_sources" ] || {
    log "profile rejected: accepted waveform set is empty"
    return 78
  }
  if [ "${PLUTO_TESTING:-0}" != 1 ] &&
     ! command -v sha256sum >/dev/null 2>&1; then
    log "profile rejected: sha256sum is required to verify waveform identity"
    return 78
  fi

  requested_waveform="$WAVEFORM"
  waveform_selected=0
  while IFS='|' read -r candidate_path candidate_sha candidate_panel; do
    [ -n "$candidate_path" ] || continue
    [ "$candidate_panel" = "$PLUTO_PROFILE_PANEL_SIGNATURE" ] || continue
    if [ -n "$requested_waveform" ] &&
       [ "$candidate_path" != "$requested_waveform" ]; then
      continue
    fi
    if [ "${PLUTO_TESTING:-0}" != 1 ]; then
      [ -r "$candidate_path" ] || continue
      candidate_actual_sha="$(sha256sum "$candidate_path" 2>/dev/null || true)"
      candidate_actual_sha="${candidate_actual_sha%% *}"
      [ "$candidate_actual_sha" = "$candidate_sha" ] || continue
    fi
    WAVEFORM="$candidate_path"
    WAVEFORM_SHA256="$candidate_sha"
    WAVEFORM_PANEL_SIGNATURE="$candidate_panel"
    waveform_selected=1
    break
  done <<EOF
$waveform_sources
EOF
  if [ "$waveform_selected" -ne 1 ]; then
    if [ -n "$requested_waveform" ]; then
      log "profile rejected: requested waveform is not an accepted source: $requested_waveform"
    else
      log "profile rejected: no readable waveform matched the accepted path, digest, and panel binding"
    fi
    return 78
  fi
  PLUTO_PROFILE_SELECTED_WAVEFORM_PATH="$WAVEFORM"
  PLUTO_PROFILE_SELECTED_WAVEFORM_SHA256="$WAVEFORM_SHA256"
  PLUTO_PROFILE_SELECTED_WAVEFORM_PANEL="$WAVEFORM_PANEL_SIGNATURE"
  export PLUTO_PROFILE_SELECTED_WAVEFORM_PATH
  export PLUTO_PROFILE_SELECTED_WAVEFORM_SHA256
  export PLUTO_PROFILE_SELECTED_WAVEFORM_PANEL
}

configure_profile() {
  if [ "$PROFILE_CONFIGURED" -eq 1 ]; then
    return 0
  fi
  if [ ! -r "$PROFILE_FILE" ]; then
    log "profile rejected: generated profile fragment is missing: $PROFILE_FILE"
    return 78
  fi
  # shellcheck source=generated/device-profiles.sh
  . "$PROFILE_FILE"
  if [ -n "${PLUTO_TEST_PROFILE_ID:-}" ]; then
    if [ "${PLUTO_TESTING:-0}" != 1 ]; then
      log "profile rejected: test identity override outside test mode"
      return 78
    fi
    if ! pluto_profile_load "$PLUTO_TEST_PROFILE_ID"; then
      log "profile rejected: unknown test profile '$PLUTO_TEST_PROFILE_ID'"
      return 78
    fi
  elif ! pluto_profile_probe; then
    log "profile rejected: immutable machine/model/compatible/architecture did not match exactly one supported device"
    return 78
  fi
  if [ -n "${PLUTO_EXPECTED_PROFILE_ID:-}" ] &&
     [ "$PLUTO_PROFILE_ID" != "$PLUTO_EXPECTED_PROFILE_ID" ]; then
    log "profile rejected: detected '$PLUTO_PROFILE_ID', expected '$PLUTO_EXPECTED_PROFILE_ID'"
    return 78
  fi
  if [ "$PLUTO_PROFILE_NATIVE_SESSION_ENABLED" != 1 ]; then
    log "profile rejected: native session for '$PLUTO_PROFILE_ID' has not passed its device acceptance gate"
    return 78
  fi

  if [ "${PLUTO_TESTING:-0}" = 1 ]; then
    [ -z "${PLUTO_TEST_RECOVERY_HELPER:-}" ] ||
      PLUTO_PROFILE_RECOVERY_HELPER="$PLUTO_TEST_RECOVERY_HELPER"
    [ -z "${PLUTO_TEST_RECOVERY_COUNTER_DIR:-}" ] ||
      PLUTO_PROFILE_RECOVERY_COUNTER_DIR="$PLUTO_TEST_RECOVERY_COUNTER_DIR"
    export PLUTO_PROFILE_RECOVERY_HELPER
    export PLUTO_PROFILE_RECOVERY_COUNTER_DIR
  fi
  [ -n "$BACKLIGHT_BRIGHTNESS" ] ||
    BACKLIGHT_BRIGHTNESS="$PLUTO_PROFILE_FRONTLIGHT_BRIGHTNESS"
  [ -n "$VPDD_TIMEOUT_FILE" ] ||
    VPDD_TIMEOUT_FILE="$PLUTO_PROFILE_VPDD_TIMEOUT"
  [ -n "$SUSPEND_COMMAND" ] ||
    SUSPEND_COMMAND="$PLUTO_PROFILE_SUSPEND_COMMAND"
  [ -n "$PRESENTER_OPTS" ] ||
    PRESENTER_OPTS="$PLUTO_PROFILE_PRESENTER_OPTIONS"
  [ -n "$PEN_DEVICE" ] || PEN_DEVICE="$PLUTO_PROFILE_PEN_DEVICE"
  [ -n "$TOUCH_DEVICE" ] || TOUCH_DEVICE="$PLUTO_PROFILE_TOUCH_DEVICE"
  [ -n "$POWER_KEY_DEVICE" ] ||
    POWER_KEY_DEVICE="$PLUTO_PROFILE_POWER_KEY_DEVICE"
  [ -n "$DISPLAY_DEVICE" ] ||
    DISPLAY_DEVICE="$PLUTO_PROFILE_DISPLAY_DEVICE"
  [ -n "$BEZEL_REDRAW_IIO" ] ||
    BEZEL_REDRAW_IIO="$PLUTO_PROFILE_BEZEL_REDRAW_IIO"
  [ -n "$BEZEL_REDRAW_ENABLE" ] ||
    BEZEL_REDRAW_ENABLE="$PLUTO_PROFILE_BEZEL_REDRAW_ENABLE"
  select_profile_waveform || return $?

  if [ "${PLUTO_TESTING:-0}" != 1 ]; then
    [ -e "$DISPLAY_DEVICE" ] || {
      log "profile rejected: display device is missing: $DISPLAY_DEVICE"
      return 78
    }
    validate_profile_input pen "$PEN_DEVICE" \
      "$PLUTO_PROFILE_PEN_NAME" || return 78
    validate_profile_input touch "$TOUCH_DEVICE" \
      "$PLUTO_PROFILE_TOUCH_NAME" || return 78
    validate_profile_input power-key "$POWER_KEY_DEVICE" \
      "$PLUTO_PROFILE_POWER_KEY_NAME" || return 78
    if [ -n "$BACKLIGHT_BRIGHTNESS" ] &&
       [ ! -r "$BACKLIGHT_BRIGHTNESS" ]; then
      log "profile rejected: frontlight path is unreadable: $BACKLIGHT_BRIGHTNESS"
      return 78
    fi
    if [ -n "$VPDD_TIMEOUT_FILE" ] && [ ! -r "$VPDD_TIMEOUT_FILE" ]; then
      log "profile rejected: regulator idle path is unreadable: $VPDD_TIMEOUT_FILE"
      return 78
    fi
    [ -x "$BOOT_CONFIRM_DISPATCHER" ] || {
      log "profile rejected: boot confirmation dispatcher is missing: $BOOT_CONFIRM_DISPATCHER"
      return 78
    }
  fi
  if [ -n "$WAVEFORM" ]; then
    PRESENTER_OPTS="$PRESENTER_OPTS,eink=$WAVEFORM"
  fi
  export PLUTO_PROFILE_ID PLUTO_PROFILE_WIRE_MODEL PLUTO_PROFILE_CODENAME
  export PLUTO_PROFILE_TARGET PLUTO_PROFILE_DISPLAY_DRIVER
  export PLUTO_PROFILE_PANEL_WIDTH PLUTO_PROFILE_PANEL_HEIGHT
  export PLUTO_PROFILE_PANEL_DPI PLUTO_PROFILE_CAPABILITIES
  export PLUTO_POWER_KEY_DEVICE="$POWER_KEY_DEVICE"
  export PLUTO_BACKLIGHT_BRIGHTNESS="$BACKLIGHT_BRIGHTNESS"
  export PLUTO_BEZEL_REDRAW_IIO="$BEZEL_REDRAW_IIO"
  export PLUTO_BEZEL_REDRAW_ENABLE="$BEZEL_REDRAW_ENABLE"
  PROFILE_CONFIGURED=1
  log "profile accepted: $PLUTO_PROFILE_ID driver=$PLUTO_PROFILE_DISPLAY_DRIVER target=$PLUTO_PROFILE_TARGET"
}

confirm_boot_after_ready() {
  case "$BOOT_CONFIRM_DELAY:$BOOT_CONFIRM_TIMEOUT" in
    *[!0-9:]*|:*|*:)
      log "boot confirmation disabled: invalid delay/timeout"
      return 64
      ;;
  esac
  sleep "$BOOT_CONFIRM_DELAY"
  waited=0
  while [ "$waited" -le "$BOOT_CONFIRM_TIMEOUT" ]; do
    if [ -f "$READY_FILE" ]; then
      if [ ! -x "$BOOT_CONFIRM_DISPATCHER" ]; then
        log "boot confirmation unavailable: missing $BOOT_CONFIRM_DISPATCHER"
        return 69
      fi
      recovery_receipt="$("$BOOT_CONFIRM_DISPATCHER")" || {
        log "boot confirmation strategy failed: $PLUTO_PROFILE_RECOVERY_STRATEGY"
        return 70
      }
      case "$recovery_receipt" in
        ''|*[!A-Za-z0-9_=/.-]*)
          log "boot confirmation failed: unsafe recovery receipt"
          return 71
          ;;
      esac
      mkdir -p "$STATE"
      printf '%s confirmed_at=%s\n' "$recovery_receipt" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE/boot-confirmed"
      log "release UI presented; boot recovery confirmed: $recovery_receipt"
      return 0
    fi
    [ "$waited" -lt "$BOOT_CONFIRM_TIMEOUT" ] || break
    sleep 1
    waited=$((waited + 1))
  done
  log "boot confirmation withheld: no successful present marker after ${BOOT_CONFIRM_DELAY}+${BOOT_CONFIRM_TIMEOUT}s"
  return 73
}

uptime_seconds() {
  cut -d. -f1 "$UPTIME_FILE" 2>/dev/null || date +%s
}

restore_standby_frontlight() {
  light_file="$CTL/standby-frontlight"
  [ -f "$light_file" ] || return 0
  if [ -z "$BACKLIGHT_BRIGHTNESS" ]; then
    rm -f "$light_file"
    log "discarded frontlight snapshot on a profile without frontlight"
    return 0
  fi
  light_raw="$(cat "$light_file" 2>/dev/null || true)"
  case "$light_raw" in
    ''|*[!0-9]*)
      log "invalid standby frontlight snapshot; preserving $light_file"
      return 1
      ;;
  esac
  for _ in 1 2 3 4 5; do
    if printf '%s\n' "$light_raw" 2>/dev/null > "$BACKLIGHT_BRIGHTNESS"; then
      rm -f "$light_file"
      log "restored frontlight raw=$light_raw"
      return 0
    fi
    sleep 0.1
  done
  log "could not restore frontlight raw=$light_raw; preserving snapshot"
  return 1
}

wait_for_vpdd_idle() {
  if [ -z "$VPDD_TIMEOUT_FILE" ]; then
    log "profile requires no supervisor regulator-idle fence"
    return 0
  fi
  case "$VPDD_IDLE_ATTEMPTS" in
    ''|*[!0-9]*|0)
      log "suspend withheld: invalid VPDD idle attempts '$VPDD_IDLE_ATTEMPTS'"
      return 64
      ;;
  esac
  attempt=0
  remaining=""
  while [ "$attempt" -lt "$VPDD_IDLE_ATTEMPTS" ]; do
    remaining="$(cat "$VPDD_TIMEOUT_FILE" 2>/dev/null || true)"
    case "$remaining" in
      0)
        log "VPDD cooldown is idle"
        return 0
        ;;
      ''|*[!0-9]*)
        log "suspend withheld: unreadable VPDD timeout at $VPDD_TIMEOUT_FILE"
        return 75
        ;;
    esac
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$VPDD_IDLE_ATTEMPTS" ] || break
    if ! sleep "$VPDD_IDLE_INTERVAL"; then
      log "suspend withheld: invalid VPDD idle interval '$VPDD_IDLE_INTERVAL'"
      return 64
    fi
  done
  log "suspend withheld: VPDD cooldown still ${remaining}ms"
  return 75
}

suspend_after_standby_exit() {
  suspend_marker="$CTL/suspend"
  [ -f "$suspend_marker" ] || return 1
  rm -f "$suspend_marker"

  # The standby child has already painted and exited. Assert darkness again,
  # then leave the saved raw value untouched until the firmware suspend target
  # returns after wake (or reports a failure).
  if [ -n "$BACKLIGHT_BRIGHTNESS" ]; then
    if ! printf '0\n' 2>/dev/null > "$BACKLIGHT_BRIGHTNESS"; then
      log "suspend withheld: could not keep frontlight at zero"
      restore_standby_frontlight || true
      return 74
    fi
  fi
  if ! wait_for_vpdd_idle; then
    restore_standby_frontlight || true
    return 75
  fi
  log "standby child closed; quiescing ${SUSPEND_QUIESCE_DELAY}s before suspend"
  if ! sleep "$SUSPEND_QUIESCE_DELAY"; then
    log "suspend withheld: invalid quiesce delay '$SUSPEND_QUIESCE_DELAY'"
    restore_standby_frontlight || true
    return 64
  fi

  log "invoking blocking suspend target: $SUSPEND_COMMAND"
  sh -c "$SUSPEND_COMMAND"
  suspend_rc=$?
  if [ "$suspend_rc" -eq 0 ]; then
    log "suspend target completed after wake"
  else
    log "suspend target failed rc=$suspend_rc"
  fi
  restore_standby_frontlight || true
  return "$suspend_rc"
}

app_dir() {
  if [ "$1" = "$LAUNCHER_ID" ]; then
    echo "$ROOT/launcher"
  else
    echo "$ROOT/apps/$1"
  fi
}

is_valid_app_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ -d "$(app_dir "$1")/bundle" ]
}

orientation_degrees() {
  case "$1" in
    portrait) echo 0 ;;
    landscapeLeft) echo 90 ;;
    portraitDown) echo 180 ;;
    landscapeRight) echo 270 ;;
    *) return 1 ;;
  esac
}

# Resolve the global preference inside the app's manifest policy. Results are
# returned in ROTATION_DEG, ALLOWED_ROTATIONS, and AUTO_ROTATE so launch_app can
# pass a complete, auditable contract to the embedder without needing jq on
# the device image.
resolve_orientation_policy() {
  manifest="$1/manifest.json"
  names="portrait"
  default_name="portrait"
  if [ -f "$manifest" ]; then
    parsed="$(sed -n 's/.*"orientations":\[\([^]]*\)\].*/\1/p' "$manifest" | tr -d '"' | tr ',' ' ')"
    [ -z "$parsed" ] || names="$parsed"
    parsed_default="$(sed -n 's/.*"defaultOrientation":"\([^"]*\)".*/\1/p' "$manifest")"
    [ -z "$parsed_default" ] || default_name="$parsed_default"
  fi

  ALLOWED_ROTATIONS=""
  for name in $names; do
    degrees="$(orientation_degrees "$name" 2>/dev/null || true)"
    [ -n "$degrees" ] || continue
    if [ -z "$ALLOWED_ROTATIONS" ]; then
      ALLOWED_ROTATIONS="$degrees"
    else
      ALLOWED_ROTATIONS="$ALLOWED_ROTATIONS,$degrees"
    fi
  done
  [ -n "$ALLOWED_ROTATIONS" ] || ALLOWED_ROTATIONS=0
  default_degrees="$(orientation_degrees "$default_name" 2>/dev/null || echo 0)"
  case ",$ALLOWED_ROTATIONS," in
    *,$default_degrees,*) ;;
    *) default_degrees="${ALLOWED_ROTATIONS%%,*}" ;;
  esac

  preference="$(cat "$STATE/launcher-config/rotation" 2>/dev/null || true)"
  case "$preference" in
    portrait|landscape|auto) ;;
    *) preference=auto ;;
  esac
  ROTATION_DEG="$default_degrees"
  AUTO_ROTATE=0
  case "$preference" in
    portrait)
      case ",$ALLOWED_ROTATIONS," in *',0,'*) ROTATION_DEG=0 ;; esac
      ;;
    landscape)
      case ",$ALLOWED_ROTATIONS," in
        *',90,'*) ROTATION_DEG=90 ;;
        *',270,'*) ROTATION_DEG=270 ;;
      esac
      ;;
    auto)
      case "$ALLOWED_ROTATIONS" in *,*) AUTO_ROTATE=1 ;; esac
      ;;
  esac
}

launch_app() {
  id="$1"
  standby_launch="${2:-0}"
  debug_authorized="${3:-0}"
  system_launch="${4:-none}"
  dir="$(app_dir "$id")"
  if [ ! -d "$dir/bundle" ]; then
    log "app '$id' not found ($dir/bundle); falling back to launcher"
    id="$LAUNCHER_ID"; dir="$(app_dir "$id")"
  fi
  mode=debug
  engine="$DEBUG_ENGINE"
  aot_elf=""
  if [ -f "$dir/bundle/lib/app.so" ]; then
    aot_elf="$dir/bundle/lib/app.so"
  elif [ -f "$dir/bundle/app.so" ]; then
    aot_elf="$dir/bundle/app.so"
  fi
  if [ -n "$aot_elf" ]; then
    mode=release
    engine="$RELEASE_ENGINE"
    if grep -q '"buildMode"[[:space:]]*:[[:space:]]*"profile"' \
        "$dir/install.json" 2>/dev/null; then
      mode=profile
      engine="$PROFILE_ENGINE"
    fi
  elif [ ! -f "$dir/bundle/flutter_assets/kernel_blob.bin" ]; then
    log "app '$id' has neither an AOT ELF nor a debug kernel; refusing launch"
    return 66
  elif [ "$debug_authorized" -ne 1 ]; then
    log "app '$id' is a debug/JIT install; use 'pluto run --debug $id'"
    return 67
  fi
  if [ ! -f "$engine" ]; then
    log "app '$id' requires missing $mode engine: $engine"
    return 66
  fi
  resolve_orientation_policy "$dir"
  log "launch embedder for '$id' ($mode, rotation=$ROTATION_DEG allowed=$ALLOWED_ROTATIONS auto=$AUTO_ROTATE)"
  set -- "$ROOT/bin/pluto-embedder" "--$mode" \
    --bundle="$dir/bundle" \
    --engine="$engine" \
    --icu-data="$dir/bundle/icudtl.dat" \
    --presenter=native \
    --presenter-options="$PRESENTER_OPTS" \
    --touch-device="$TOUCH_DEVICE" \
    --pen-device="$PEN_DEVICE" \
    --rotation="$ROTATION_DEG" \
    --allowed-rotations="$ALLOWED_ROTATIONS" \
    --run-dir="$CTL" \
    --ready-file="$READY_FILE"
  if [ "$AUTO_ROTATE" -eq 1 ]; then
    set -- "$@" --auto-rotate
  fi
  # One persistent foreground worker consumes the hardware double-tap event;
  # it redraws in place and never relaunches, so launcher and apps can both use
  # it without the old stale-event Home loop. Standby deliberately stays dark.
  if [ "$standby_launch" -eq 0 ] && [ -n "$BEZEL_REDRAW_IIO" ] &&
     [ -n "$BEZEL_REDRAW_ENABLE" ]; then
    set -- "$@" --bezel-redraw
  fi
  if [ -n "$aot_elf" ]; then
    set -- "$@" --aot-elf="$aot_elf"
  fi
  if [ "$standby_launch" -eq 1 ]; then
    set -- "$@" --dart-entrypoint-args=--standby
  elif [ "$system_launch" = switcher ]; then
    set -- "$@" --dart-entrypoint-args=--switcher
  elif [ "$system_launch" = status ]; then
    set -- "$@" --dart-entrypoint-args=--status
  elif [ "$system_launch" = power-menu ]; then
    set -- "$@" --dart-entrypoint-args=--power-menu
  fi
  warm=0
  if [ "$standby_launch" -eq 0 ] && [ "$mode" != debug ] && \
     [ "$MAX_WARM_APPS" -gt 0 ] 2>/dev/null; then
    warm=1
    set -- "$@" --hibernate
  fi

  # Run in the background so one power-key watcher can be paired with this
  # exact embedder pid. The standby launcher is deliberately unpaired: its
  # second power press belongs exclusively to the kernel wake path.
  PLUTO_RUN_DIR="$CTL" \
  PLUTO_APPS_DIR="$ROOT/apps" \
  PLUTO_DATA_DIR="$ROOT/appdata" \
  PLUTO_CONFIG_DIR="$ROOT/state/launcher-config" \
  PLUTO_APP_ID="$id" \
    "$@" >"$ROOT/logs/$id.log" 2>&1 &
  app_pid=$!
  ln -sf "$ROOT/logs/$id.log" "$ROOT/logs/current.log"
  APP_PID="$app_pid"
  APP_ID="$id"
  APP_MODE="$mode"
  APP_WARM="$warm"
  if [ "$warm" -eq 1 ]; then
    printf '%s\n' "$app_pid" > "$WARM_DIR/$id.pid"
    if [ "$system_launch" != none ]; then
      # Hosting temporary system UI is not an app use. A cold host still needs
      # a neutral recency file so it can join the pool without becoming MRU.
      [ -f "$WARM_DIR/$id.used" ] || printf '0\n' > "$WARM_DIR/$id.used"
    else
      touch_warm_pid "$id"
    fi
  fi
  return 0
}

pid_alive() { kill -0 "$1" 2>/dev/null; }

publish_foreground_pid() {
  pid_tmp="$EMBEDDER_PID_FILE.$$"
  if printf '%s\n' "$1" > "$pid_tmp" &&
      mv -f "$pid_tmp" "$EMBEDDER_PID_FILE"; then
    return 0
  fi
  rm -f "$pid_tmp"
  log "could not publish current embedder pid $1"
  return 1
}

start_power_watcher() {
  WATCHER_PID=""
  [ "$1" -eq 0 ] || return 0
  if [ -x "$POWER_WATCHER" ]; then
    PLUTO_RUN_DIR="$CTL" "$POWER_WATCHER" \
      --pid="$2" --app-id="$3" --device="$POWER_KEY_DEVICE" \
      --run-dir="$CTL" \
      >>"$ROOT/logs/current.log" 2>&1 &
    WATCHER_PID=$!
  else
    log "power watcher missing or not executable: $POWER_WATCHER"
  fi
}

stop_power_watcher() {
  if [ -n "${WATCHER_PID:-}" ]; then
    kill "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
    WATCHER_PID=""
  fi
}

forget_warm_pid() {
  id="$1"
  pid="$2"
  [ "$(cat "$WARM_DIR/$id.pid" 2>/dev/null || true)" != "$pid" ] ||
    rm -f "$WARM_DIR/$id.pid" "$WARM_DIR/$id.used"
  rm -f "$HIBERNATED_DIR/$pid"
}

touch_warm_pid() {
  id="$1"
  sequence=$(cat "$WARM_DIR/sequence" 2>/dev/null || echo 0)
  case "$sequence" in ''|*[!0-9]*) sequence=0 ;; esac
  sequence=$((sequence + 1))
  printf '%s\n' "$sequence" > "$WARM_DIR/sequence"
  printf '%s\n' "$sequence" > "$WARM_DIR/$id.used"
}

terminate_embedder() {
  pid="$1"
  kill -TERM "$pid" 2>/dev/null || true
  kill -CONT "$pid" 2>/dev/null || true
  ticks=0
  while pid_alive "$pid" && [ "$ticks" -lt 40 ]; do
    sleep 0.05
    ticks=$((ticks + 1))
  done
  if pid_alive "$pid"; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

pause_embedder() {
  id="$1"
  pid="$2"
  marker="$HIBERNATED_DIR/$pid"
  ticks=0
  # Session-channel handoffs normally self-quiesce. SIGUSR1 also covers the
  # power watcher and supervisor-originated transitions.
  [ -f "$marker" ] || kill -USR1 "$pid" 2>/dev/null || true
  while pid_alive "$pid" && [ ! -f "$marker" ] &&
        [ "$ticks" -lt "$HIBERNATE_WAIT_TICKS" ]; do
    sleep 0.05
    ticks=$((ticks + 1))
  done
  if pid_alive "$pid" && [ -f "$marker" ]; then
    kill -STOP "$pid" 2>/dev/null || return 1
    [ "${system_host:-none}" != none ] || touch_warm_pid "$id"
    log "hibernated '$id' pid=$pid"
    return 0
  fi
  log "hibernate acknowledgement failed for '$id' pid=$pid; cold fallback"
  terminate_embedder "$pid"
  forget_warm_pid "$id" "$pid"
  return 1
}

resume_embedder() {
  id="$1"
  pid="$2"
  marker="$HIBERNATED_DIR/$pid"
  [ -f "$marker" ] || return 1
  ln -sf "$ROOT/logs/$id.log" "$ROOT/logs/current.log"
  kill -CONT "$pid" 2>/dev/null || return 1
  kill -USR2 "$pid" 2>/dev/null || return 1
  ticks=0
  while pid_alive "$pid" && [ -f "$marker" ] &&
        [ "$ticks" -lt "$RESUME_WAIT_TICKS" ]; do
    sleep 0.05
    ticks=$((ticks + 1))
  done
  if pid_alive "$pid" && [ ! -f "$marker" ]; then
    APP_PID="$pid"
    APP_ID="$id"
    APP_MODE=release
    APP_WARM=1
    [ "${system_host:-none}" != none ] || touch_warm_pid "$id"
    log "resumed '$id' pid=$pid"
    return 0
  fi
  log "resume failed for '$id' pid=$pid; cold fallback"
  terminate_embedder "$pid"
  forget_warm_pid "$id" "$pid"
  return 1
}

evict_warm_excess() {
  while :; do
    count=0
    oldest_id=""
    oldest_used=""
    for pid_file in "$WARM_DIR"/*.pid; do
      [ -f "$pid_file" ] || continue
      id=${pid_file##*/}; id=${id%.pid}
      pid=$(cat "$pid_file" 2>/dev/null || true)
      if [ -z "$pid" ] || ! pid_alive "$pid"; then
        forget_warm_pid "$id" "$pid"
        continue
      fi
      count=$((count + 1))
      used=$(cat "$WARM_DIR/$id.used" 2>/dev/null || echo 0)
      case "$used" in ''|*[!0-9]*) used=0 ;; esac
      # A neutral-recency cold launcher may be the foreground switcher host.
      # Count it toward the limit, but never evict the process owning input and
      # DRM; an actual background victim is selected instead.
      [ "$pid" != "${APP_PID:-}" ] || continue
      if [ -z "$oldest_id" ] || [ "$used" -lt "$oldest_used" ]; then
        oldest_id="$id"; oldest_used="$used"; oldest_pid="$pid"
      fi
    done
    [ "$count" -le "$MAX_WARM_APPS" ] && return 0
    log "evicting least-recent warm app '$oldest_id' pid=$oldest_pid"
    terminate_embedder "$oldest_pid"
    forget_warm_pid "$oldest_id" "$oldest_pid"
  done
}

prepare_switcher_state() {
  origin="$1"
  case "$origin" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  order="$CTL/.switcher-order.$$"
  sorted="$CTL/.switcher-sorted.$$"
  state="$CTL/.switcher-active.$$"
  : > "$order" || return 1
  for pid_file in "$WARM_DIR"/*.pid; do
    [ -f "$pid_file" ] || continue
    id=${pid_file##*/}; id=${id%.pid}
    [ "$id" != "$origin" ] || continue
    [ "$id" != "$LAUNCHER_ID" ] || continue
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [ -n "$pid" ] && pid_alive "$pid" || continue
    used=$(cat "$WARM_DIR/$id.used" 2>/dev/null || echo 0)
    case "$used" in ''|*[!0-9]*) used=0 ;; esac
    printf '%012d %s\n' "$used" "$id" >> "$order"
  done
  sort -rn "$order" > "$sorted" || {
    rm -f "$order" "$sorted" "$state"
    return 1
  }
  printf '%s\n' "$origin" > "$state" || {
    rm -f "$order" "$sorted" "$state"
    return 1
  }
  while read -r _ id; do
    [ -z "${id:-}" ] || printf '%s\n' "$id" >> "$state"
  done < "$sorted"
  rm -f "$order" "$sorted"
  mv -f "$state" "$CTL/switcher-active"
}

remove_switcher_app() {
  app_id="$1"
  active="$CTL/switcher-active"
  [ -f "$active" ] || return 0
  next="$CTL/.switcher-active.$$"
  : > "$next" || return 1
  while IFS= read -r id; do
    [ "$id" = "$app_id" ] || printf '%s\n' "$id" >> "$next"
  done < "$active"
  mv -f "$next" "$active"
}

handle_force_stop_request() {
  request="$CTL/force-stop"
  [ -s "$request" ] || return 0
  app_id=$(sed -n '1p' "$request" 2>/dev/null || true)
  rm -f "$request"
  if [ "$app_id" = "$LAUNCHER_ID" ] || [ "$app_id" = "${APP_ID:-}" ] ||
     ! is_valid_app_id "$app_id"; then
    log "refused invalid or foreground force-stop '$app_id'"
    return 1
  fi
  pid=$(cat "$WARM_DIR/$app_id.pid" 2>/dev/null || true)
  if [ -n "$pid" ] && pid_alive "$pid"; then
    terminate_embedder "$pid"
  fi
  if [ -n "$pid" ]; then
    # This request is authoritative: clear the selected app's registration
    # even if it raced with process exit/reaping while terminate_embedder ran.
    rm -f "$WARM_DIR/$app_id.pid" "$WARM_DIR/$app_id.used" \
      "$HIBERNATED_DIR/$pid"
  else
    rm -f "$WARM_DIR/$app_id.pid" "$WARM_DIR/$app_id.used"
  fi
  rm -f "$CTL/previews/$app_id.bmp"
  remove_switcher_app "$app_id" || true
  log "force-stopped '$app_id' pid=${pid:-none}"
  return 0
}

authorized_poweroff_request() {
  [ -f "$CTL/poweroff" ] &&
    [ "${system_host:-none}" = power-menu ] &&
    [ "${APP_ID:-}" = "$LAUNCHER_ID" ] &&
    [ -s "$CTL/power-menu-active" ] &&
    [ "$(sed -n '1p' "$CTL/poweroff" 2>/dev/null || true)" = ui ]
}

discard_unauthorized_poweroff() {
  [ -f "$CTL/poweroff" ] || return 0
  authorized_poweroff_request && return 0
  rm -f "$CTL/poweroff"
  log "refused power off request outside active launcher power menu"
}

monitor_foreground() {
  # Keep this name distinct from lifecycle helpers, which are POSIX-sh
  # functions and therefore share variable scope with their caller.
  monitor_pid="$1"
  while pid_alive "$monitor_pid"; do
    handle_force_stop_request || true
    discard_unauthorized_poweroff
    if [ -s "$CTL/launch" ] || [ -s "$CTL/debug-launch" ] ||
       [ -f "$CTL/home" ] || [ -f "$CTL/standby" ] ||
       [ -s "$CTL/switcher" ] || [ -s "$CTL/status" ] ||
       [ -s "$CTL/power-menu" ] || authorized_poweroff_request ||
       [ -f "$CTL/suspend" ] || [ -f "$CTL/stock" ]; then
      return 0
    fi
    sleep 0.05
  done
  return 0
}

wait_foreground_exit() {
  pid="$1"
  ticks=0
  while pid_alive "$pid" && [ "$ticks" -lt "$FOREGROUND_EXIT_WAIT_TICKS" ]; do
    sleep 0.05
    ticks=$((ticks + 1))
  done
  pid_alive "$pid" || return 0
  terminate_embedder "$pid"
}

drain_warm_pool() {
  for pid_file in "$WARM_DIR"/*.pid; do
    [ -f "$pid_file" ] || continue
    id=${pid_file##*/}; id=${id%.pid}
    pid=$(cat "$pid_file" 2>/dev/null || true)
    [ -z "$pid" ] || terminate_embedder "$pid"
    forget_warm_pid "$id" "$pid"
  done
}

# When boot-first is installed, xochitl.service is overridden to run THIS
# supervisor, so we must not stop/start that service to reach it (that would
# stop ourselves / loop). Detect the override and drive the stock binary direct.
hijacked() { [ -f "$BOOT_DROPIN" ]; }

restore_stock() {
  drain_warm_pool
  log "restoring stock xochitl"
  if hijacked; then
    # Keep stock xochitl in the service's main process. Backgrounding it and
    # returning lets systemd's default KillMode=control-group reap it when the
    # supervisor exits, leaving the panel without an owner.
    exec env MALLOC_ARENA_MAX=8 "$STOCK_XOCHITL" --system
  else
    systemctl reset-failed xochitl.service 2>/dev/null || true
    systemctl start xochitl.service 2>/dev/null || true
  fi
}

start() {
  configure_profile || return $?
  mkdir -p "$CTL" "$WARM_DIR" "$HIBERNATED_DIR" "$CTL/previews" \
    "$ROOT/logs"
  case "$MAX_WARM_APPS:$HIBERNATE_WAIT_TICKS:$RESUME_WAIT_TICKS:$FOREGROUND_EXIT_WAIT_TICKS" in
    *[!0-9:]*|:*|*::*|*:) log "invalid warm-pool configuration"; return 64 ;;
  esac
  rm -f "$STATE/boot-confirmed"
  # Recover from a prior supervisor/launcher crash before discarding control
  # markers. The persisted raw value is removed only after a successful write.
  restore_standby_frontlight || true
  rm -f "$CTL/launch" "$CTL/debug-launch" "$CTL/home" "$CTL/standby" \
    "$CTL/suspend" "$CTL/stock" "$CTL/switcher" "$CTL/status" \
    "$CTL/power-menu" "$CTL/poweroff" \
    "$CTL/force-stop" \
    "$CTL/switcher-active" "$CTL/status-active" \
    "$CTL/power-menu-active" "$CTL/system-ui-reset" \
    "$READY_FILE" \
    "$EMBEDDER_PID_FILE"
  # A supervisor restart cannot adopt old children safely because it does not
  # know whether their presenter/input quiesce completed. Drain them and start
  # a new in-memory pool; a full device reboot clears the same state naturally.
  for stale_pid in $(pgrep -f "$ROOT/bin/pluto-embedder" 2>/dev/null || true); do
    kill -TERM "$stale_pid" 2>/dev/null || true
    kill -CONT "$stale_pid" 2>/dev/null || true
  done
  sleep 0.1
  for stale_pid in $(pgrep -f "$ROOT/bin/pluto-embedder" 2>/dev/null || true); do
    kill -KILL "$stale_pid" 2>/dev/null || true
  done
  rm -f "$WARM_DIR"/*.pid "$WARM_DIR"/*.used "$WARM_DIR/sequence" \
    "$HIBERNATED_DIR"/* "$CTL/previews"/* 2>/dev/null || true
  if hijacked; then
    # We ARE xochitl.service (boot-first override): no stock xochitl to stop.
    log "boot-first: this supervisor is xochitl.service; taking the panel"
    pkill -x xochitl 2>/dev/null || true
    if [ -x "$BOOT_CONFIRM_DISPATCHER" ]; then
      confirm_boot_after_ready &
    else
      log "boot confirmation dispatcher is unavailable"
    fi
  else
    log "stopping xochitl to take over the panel"
    systemctl reset-failed xochitl.service 2>/dev/null || true
    systemctl stop xochitl.service 2>/dev/null || true
  fi
  sleep 0.3
  current="$(cat "$DEFAULT_APP_FILE" 2>/dev/null || true)"
  if [ -n "$current" ] && [ "$current" != "$LAUNCHER_ID" ]; then
    log "boot default app: $current"
  else
    current="$LAUNCHER_ID"
  fi
  standby=0
  debug_authorized=0
  system_host=none
  fails=0
  while :; do
    t0=$(uptime_seconds)
    was_standby="$standby"
    # A suspend request belongs to exactly one standby child. Clear anything
    # stale before entry; a fresh marker may only be consumed after the prior
    # standby child has been reaped and its published pid removed.
    if [ "$was_standby" -eq 1 ]; then
      rm -f "$CTL/suspend"
    fi
    APP_PID=""
    APP_ID="$current"
    APP_MODE=""
    APP_WARM=0
    launch_rc=0
    warm_pid=""
    if [ "$standby" -eq 0 ] && [ "$debug_authorized" -eq 0 ]; then
      warm_pid=$(cat "$WARM_DIR/$current.pid" 2>/dev/null || true)
      if [ -n "$warm_pid" ] && pid_alive "$warm_pid"; then
        resume_embedder "$current" "$warm_pid" || warm_pid=""
      else
        [ -z "$warm_pid" ] || forget_warm_pid "$current" "$warm_pid"
        warm_pid=""
      fi
    fi
    if [ -z "$warm_pid" ]; then
      launch_app "$current" "$standby" "$debug_authorized" \
        "$system_host" || launch_rc=$?
    fi
    # A refused debug/JIT launch or missing app has no foreground child. Keep
    # the one-shot semantics and recover through the launcher immediately.
    if [ "$launch_rc" -ne 0 ] || [ -z "$APP_PID" ]; then
      debug_authorized=0
      standby=0
      if [ "$current" != "$LAUNCHER_ID" ]; then
        current="$LAUNCHER_ID"
        rm -f "$CTL/launch"
        sleep 0.1
        continue
      fi
      fails=$((fails + 1))
      [ "$fails" -lt 3 ] || { restore_stock; return 1; }
      sleep 1
      continue
    fi
    current="$APP_ID"
    # launch_app/resume_embedder marks the foreground as most-recent, so LRU
    # eviction can enforce the total resident limit without selecting it.
    evict_warm_excess
    publish_foreground_pid "$APP_PID" || true
    start_power_watcher "$standby" "$APP_PID" "$APP_ID"
    monitor_foreground "$APP_PID"
    stop_power_watcher
    discard_unauthorized_poweroff

    controlled_exit=0
    if [ -s "$CTL/launch" ] || [ -s "$CTL/debug-launch" ] ||
       [ -f "$CTL/home" ] || [ -f "$CTL/standby" ] ||
       [ -s "$CTL/switcher" ] || [ -s "$CTL/status" ] ||
       [ -s "$CTL/power-menu" ] || authorized_poweroff_request ||
       [ -f "$CTL/suspend" ] || [ -f "$CTL/stock" ]; then
      controlled_exit=1
    fi
    if pid_alive "$APP_PID"; then
      if authorized_poweroff_request && [ "$APP_WARM" -ne 1 ]; then
        terminate_embedder "$APP_PID"
      elif [ -s "$CTL/power-menu" ] && [ "$APP_WARM" -ne 1 ]; then
        # Debug/JIT and explicitly cache-disabled processes cannot be resumed
        # without violating their launch authorization. End them immediately;
        # waiting for a hibernate acknowledgement would add the full timeout
        # after the physical two-second hold.
        terminate_embedder "$APP_PID"
      elif [ "$APP_WARM" -eq 1 ] && [ "$was_standby" -eq 0 ] &&
         { [ -s "$CTL/launch" ] || [ -f "$CTL/home" ] ||
           [ -f "$CTL/standby" ] || [ -s "$CTL/switcher" ] ||
           [ -s "$CTL/status" ] || [ -s "$CTL/power-menu" ] ||
           authorized_poweroff_request; }; then
        pause_embedder "$APP_ID" "$APP_PID" || true
      else
        wait_foreground_exit "$APP_PID"
      fi
    fi
    if ! pid_alive "$APP_PID"; then
      wait "$APP_PID" 2>/dev/null || true
      forget_warm_pid "$APP_ID" "$APP_PID"
      log "embedder for '$APP_ID' exited"
    fi
    if [ "$(cat "$EMBEDDER_PID_FILE" 2>/dev/null || true)" = "$APP_PID" ]; then
      rm -f "$EMBEDDER_PID_FILE"
    fi
    if [ "$was_standby" -eq 1 ]; then
      cp "$ROOT/logs/current.log" "$ROOT/logs/standby-last.log" \
        2>/dev/null || true
    fi
    # A debug authorization applies to exactly one launch attempt, including
    # an attempt that fails before the embedder starts.
    debug_authorized=0
    dt=$(( $(uptime_seconds) - t0 ))
    standby_handoff=0
    if [ "$was_standby" -eq 1 ]; then
      if [ -f "$CTL/suspend" ]; then
        standby_handoff=1
        # The foreground child (and its watcher, if any) is fully reaped, so no
        # embedder owns the panel while the firmware suspend target runs.
        suspend_after_standby_exit || true
      else
        log "standby child exited without suspend request; recovering frontlight"
        restore_standby_frontlight || true
      fi
    fi
    [ "$standby_handoff" -eq 0 ] || controlled_exit=1
    # A quick, requested handoff is success, not a crash. Classifying it as a
    # fast failure used to sleep for one second before reading CTL/launch,
    # making taps during the launcher's first three seconds visibly slower.
    if [ "$dt" -lt 3 ] && [ "$controlled_exit" -eq 0 ]; then
      fails=$((fails + 1))
      log "embedder exited after ${dt}s (fail $fails/3)"
      if [ "$fails" -ge 3 ]; then
        log "too many fast failures; restoring stock"
        restore_stock
        return 1
      fi
      if [ "$current" != "$LAUNCHER_ID" ]; then
        log "app '$current' failed fast; falling back to the launcher"
        current="$LAUNCHER_ID"
        # Discard any pending relaunch request from the crashed app.
        rm -f "$CTL/launch"
      fi
      sleep 1
    else
      fails=0
    fi
    if authorized_poweroff_request; then
      rm -f "$CTL/poweroff" "$CTL/power-menu" "$CTL/launch" \
        "$CTL/debug-launch" "$CTL/home" "$CTL/standby" "$CTL/suspend" \
        "$CTL/switcher" "$CTL/status" "$CTL/switcher-active" \
        "$CTL/status-active" "$CTL/power-menu-active"
      : > "$CTL/system-ui-reset"
      drain_warm_pool
      log "power off requested; invoking: $POWER_OFF_COMMAND"
      sh -c "$POWER_OFF_COMMAND"
      poweroff_rc=$?
      if [ "$poweroff_rc" -eq 0 ]; then
        log "power off command accepted; supervisor done"
        return 0
      fi
      log "power off command failed rc=$poweroff_rc; recovering launcher"
      current="$LAUNCHER_ID"
      standby=0
      debug_authorized=0
      system_host=none
      fails=0
      continue
    fi
    if [ -f "$CTL/stock" ]; then
      rm -f "$CTL/stock" "$CTL/switcher-active" "$CTL/status-active" \
        "$CTL/power-menu-active" "$CTL/system-ui-reset"
      restore_stock
      log "exited to stock; supervisor done"
      return 0
    fi
    if [ -f "$CTL/standby" ]; then
      if [ "$system_host" != none ]; then
        : > "$CTL/system-ui-reset"
      fi
      rm -f "$CTL/standby" "$CTL/suspend" "$CTL/launch" \
        "$CTL/debug-launch" "$CTL/home" "$CTL/switcher" "$CTL/status" \
        "$CTL/power-menu" "$CTL/switcher-active" "$CTL/status-active" \
        "$CTL/power-menu-active"
      current="$LAUNCHER_ID"
      standby=1
      debug_authorized=0
      system_host=none
      fails=0
      log "power standby requested; launching standby screen"
      continue
    fi
    if [ -s "$CTL/debug-launch" ]; then
      current="$(cat "$CTL/debug-launch" 2>/dev/null)"
      # Consume both controls so a concurrent ordinary tap cannot be replayed
      # after this explicit one-shot request.
      rm -f "$CTL/debug-launch" "$CTL/launch" "$CTL/switcher-active" \
        "$CTL/status-active" "$CTL/power-menu-active"
      standby=0
      debug_authorized=1
      system_host=none
      log "next app: $current (explicit debug/JIT authorization)"
      continue
    fi
    if [ -s "$CTL/power-menu" ]; then
      request_origin=$(sed -n '1p' "$CTL/power-menu" 2>/dev/null || true)
      rm -f "$CTL/power-menu"
      if [ "$request_origin" = "$APP_ID" ] &&
         is_valid_app_id "$request_origin"; then
        if [ "$APP_WARM" -eq 1 ]; then
          menu_origin="$request_origin"
        else
          # A non-warm origin was terminated above and debug/JIT may only be
          # relaunched by a fresh explicit authorization. Cancel safely to Home.
          menu_origin="$LAUNCHER_ID"
        fi
        # If another temporary launcher surface owns the panel, retain its
        # underlying app as the power menu's cancel target instead of losing
        # that warm origin to Home.
        case "$system_host" in
          switcher)
            prior_origin=$(sed -n '1p' "$CTL/switcher-active" \
              2>/dev/null || true)
            ;;
          status)
            prior_origin=$(sed -n '1p' "$CTL/status-active" \
              2>/dev/null || true)
            ;;
          power-menu)
            prior_origin=$(sed -n '1p' "$CTL/power-menu-active" \
              2>/dev/null || true)
            ;;
          *) prior_origin="" ;;
        esac
        if [ -n "$prior_origin" ] && is_valid_app_id "$prior_origin"; then
          menu_origin="$prior_origin"
        fi
        printf '%s\n' "$menu_origin" > "$CTL/.power-menu-active.$$" &&
          mv -f "$CTL/.power-menu-active.$$" "$CTL/power-menu-active"
        if [ -s "$CTL/power-menu-active" ]; then
          if [ "$system_host" != none ]; then
            : > "$CTL/system-ui-reset"
          fi
          rm -f "$CTL/switcher-active" "$CTL/status-active"
          current="$LAUNCHER_ID"
          standby=0
          debug_authorized=0
          system_host=power-menu
          fails=0
          log "power menu requested by '$menu_origin'"
          continue
        fi
      fi
      rm -f "$CTL/.power-menu-active.$$" "$CTL/power-menu-active"
      log "invalid power menu request from '$request_origin' while '$APP_ID' was foreground; returning home"
    fi
    if [ -s "$CTL/switcher" ]; then
      origin=$(sed -n '1p' "$CTL/switcher" 2>/dev/null || true)
      rm -f "$CTL/switcher"
      if [ "$origin" = "$APP_ID" ] && prepare_switcher_state "$origin"; then
        current="$LAUNCHER_ID"
        standby=0
        debug_authorized=0
        system_host=switcher
        fails=0
        log "app switcher requested by '$origin'"
        continue
      fi
      log "invalid app switcher request from '$origin' while '$APP_ID' was foreground; returning home"
      rm -f "$CTL/switcher-active"
    fi
    if [ -s "$CTL/status" ]; then
      origin=$(sed -n '1p' "$CTL/status" 2>/dev/null || true)
      rm -f "$CTL/status"
      if [ "$origin" = "$APP_ID" ] && is_valid_app_id "$origin"; then
        printf '%s\n' "$origin" > "$CTL/.status-active.$$" &&
          mv -f "$CTL/.status-active.$$" "$CTL/status-active"
        if [ -s "$CTL/status-active" ]; then
          current="$LAUNCHER_ID"
          standby=0
          debug_authorized=0
          system_host=status
          fails=0
          log "status shade requested by '$origin'"
          continue
        fi
      fi
      rm -f "$CTL/.status-active.$$" "$CTL/status-active"
      log "invalid status request from '$origin' while '$APP_ID' was foreground; returning home"
    fi
    if [ -s "$CTL/launch" ]; then
      current="$(cat "$CTL/launch" 2>/dev/null)"
      rm -f "$CTL/launch" "$CTL/switcher-active" "$CTL/status-active" \
        "$CTL/power-menu-active"
      standby=0
      debug_authorized=0
      system_host=none
      log "next app: $current"
      continue
    fi
    if [ -f "$CTL/home" ]; then
      if [ "$system_host" != none ]; then
        : > "$CTL/system-ui-reset"
      fi
      rm -f "$CTL/home" "$CTL/switcher-active" "$CTL/status-active"
      rm -f "$CTL/power-menu-active"
      log "returning to launcher home"
    fi
    if [ "$system_host" != none ]; then
      # If a temporary launcher host disappears without a selection, recover
      # the app that yielded the panel and discard stale system UI state.
      case "$system_host" in
        switcher)
          origin=$(sed -n '1p' "$CTL/switcher-active" \
            2>/dev/null || true)
          ;;
        status)
          origin=$(sed -n '1p' "$CTL/status-active" \
            2>/dev/null || true)
          ;;
        power-menu)
          origin=$(sed -n '1p' "$CTL/power-menu-active" \
            2>/dev/null || true)
          ;;
        *) origin="" ;;
      esac
      rm -f "$CTL/switcher-active" "$CTL/status-active" \
        "$CTL/power-menu-active"
      if is_valid_app_id "$origin"; then
        current="$origin"
        log "$system_host host exited; resuming origin '$origin'"
      else
        current="$LAUNCHER_ID"
        log "$system_host host exited without a valid origin; returning home"
      fi
      standby=0
      debug_authorized=0
      system_host=none
      continue
    fi
    # App self-exit, standby failure, or home request -> normal launcher.
    standby=0
    debug_authorized=0
    system_host=none
    current="$LAUNCHER_ID"
  done
}

case "${1:-start}" in
  start) start ;;
  stop)
    log "stop requested"
    drain_warm_pool
    pkill -f "$ROOT/bin/pluto-embedder" 2>/dev/null || true
    restore_stock ;;
  *) echo "usage: $0 [start|stop]"; exit 2 ;;
esac
