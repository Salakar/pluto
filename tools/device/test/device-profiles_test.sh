#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tools/device/generated/device-profiles.sh"

fail() {
  printf 'device-profiles_test: %s\n' "$*" >&2
  exit 1
}

assert_profile() {
  expected=$1
  shift
  unset PLUTO_PROFILE_ID || true
  pluto_profile_detect "$@" || fail "expected $expected to match"
  [ "$PLUTO_PROFILE_ID" = "$expected" ] ||
    fail "expected $expected, got ${PLUTO_PROFILE_ID:-unset}"
}

assert_rejected() {
  unset PLUTO_PROFILE_ID || true
  if pluto_profile_detect "$@"; then
    fail "unsafe identity matched ${PLUTO_PROFILE_ID:-unset}"
  fi
}

assert_profile rm1 \
  'reMarkable 1.0' 'reMarkable 1.n' \
  'remarkable,zero-gravitas fsl,imx6sl' armv7l
assert_profile rm2 \
  'reMarkable 2.0' 'reMarkable 2.n' \
  'fsl,imx7d-sdb fsl,imx7d' armv7l
assert_profile move \
  'reMarkable Chiappa' 'reMarkable Chiappa' 'fsl,imx93' aarch64

assert_rejected 'reMarkable 1.0' '' '' armv7l
assert_rejected '' '' 'fsl,imx7d-sdb' armv7l
assert_rejected 'reMarkable Chiappa' '' 'fsl,imx93' armv7l
assert_rejected \
  'reMarkable 1.0 reMarkable 2.0' '' \
  'remarkable,zero-gravitas fsl,imx7d-sdb' armv7l

pluto_profile_load rm1 || fail "could not load rm1 runtime profile"
[ "$PLUTO_PROFILE_NATIVE_SESSION_ENABLED" = 0 ] ||
  fail "rm1 native session was enabled before its display gate"
[ "$PLUTO_PROFILE_DISPLAY_DEVICE" = /dev/fb0 ] ||
  fail "rm1 display path drifted"
[ "$PLUTO_PROFILE_SCANOUT_WIDTH:$PLUTO_PROFILE_SCANOUT_HEIGHT" = \
    1404:1872 ] || fail "rm1 scanout geometry drifted"
[ "$PLUTO_PROFILE_VIRTUAL_WIDTH:$PLUTO_PROFILE_VIRTUAL_HEIGHT" = \
    1408:3840 ] || fail "rm1 virtual framebuffer geometry drifted"
[ "$PLUTO_PROFILE_STRIDE_BYTES:$PLUTO_PROFILE_BITS_PER_PIXEL:$PLUTO_PROFILE_FRAMEBUFFER_ROTATION" = \
    2816:16:1 ] || fail "rm1 framebuffer layout drifted"
[ -z "$PLUTO_PROFILE_BUFFER_SLOTS$PLUTO_PROFILE_PHASE_INTERVAL_NS" ] ||
  fail "rm1 incorrectly gained userspace phase scanout fields"
[ "$PLUTO_PROFILE_PEN_DEVICE" = \
    /dev/input/by-path/platform-21a4000.i2c-event-mouse ] ||
  fail "rm1 pen path drifted"
[ "$PLUTO_PROFILE_TOUCH_DEVICE" = \
    /dev/input/by-path/platform-21a8000.i2c-event ] ||
  fail "rm1 touch path drifted"
[ "$PLUTO_PROFILE_POWER_KEY_DEVICE" = \
    /dev/input/by-path/platform-gpio-keys-event ] ||
  fail "rm1 power-key path drifted"
[ -z "$PLUTO_PROFILE_FRONTLIGHT_BRIGHTNESS" ] ||
  fail "rm1 incorrectly gained a frontlight path"
[ "$PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY:$PLUTO_PROFILE_RECOVERY_FAILURE_STRATEGY:$PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED:$PLUTO_PROFILE_RECOVERY_MMC_DEVICE:$PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS:$PLUTO_PROFILE_RECOVERY_BOOT_LIMIT" = \
    'uboot_env:uboot_env_force_reboot:1:/dev/mmcblk1:2,3:1' ] ||
  fail "rm1 U-Boot recovery contract drifted"
[ -z "$PLUTO_PROFILE_RECOVERY_HELPER$PLUTO_PROFILE_RECOVERY_COUNTER_DIR" ] ||
  fail "rm1 incorrectly gained the Move LPGPR helper"

pluto_profile_load rm2 || fail "could not load rm2 runtime profile"
[ "$PLUTO_PROFILE_NATIVE_SESSION_ENABLED" = 0 ] ||
  fail "rm2 native session was enabled before its display gate"
[ "$PLUTO_PROFILE_PANEL_SIGNATURE" = ED103TC2C5 ] ||
  fail "rm2 panel signature drifted"
[ "$PLUTO_PROFILE_SCANOUT_WIDTH:$PLUTO_PROFILE_SCANOUT_HEIGHT" = \
    260:1408 ] || fail "rm2 scanout slot geometry drifted"
[ "$PLUTO_PROFILE_VIRTUAL_WIDTH:$PLUTO_PROFILE_VIRTUAL_HEIGHT" = \
    260:23936 ] || fail "rm2 virtual framebuffer geometry drifted"
[ "$PLUTO_PROFILE_STRIDE_BYTES:$PLUTO_PROFILE_BITS_PER_PIXEL:$PLUTO_PROFILE_FRAMEBUFFER_ROTATION" = \
    1040:32:0 ] || fail "rm2 framebuffer layout drifted"
[ "$PLUTO_PROFILE_BUFFER_SLOTS:$PLUTO_PROFILE_SLOT_BYTES" = \
    17:1464320 ] || fail "rm2 scanout ring geometry drifted"
[ "$PLUTO_PROFILE_DAMAGE_ALIGNMENT:$PLUTO_PROFILE_PHASE_INTERVAL_NS" = \
    8:11763000 ] || fail "rm2 alignment or phase interval drifted"
rm2_discovery=$(pluto_profile_waveform_discovery_paths) ||
  fail "rm2 waveform discovery contract is missing"
case "$rm2_discovery" in
  *'/var/lib/uboot/320_R405_AFA011_ED103TC2C5_VB3300-KCD_TC.wbf'*\
*'/usr/share/remarkable/320_R467_AF4731_ED103TC2C6_VB3300-KCD_TC.wbf'*) ;;
  *) fail "rm2 waveform discovery candidates drifted" ;;
esac
rm2_sources=$(pluto_profile_waveform_sources) ||
  fail "rm2 accepted waveform contract is missing"
[ "$rm2_sources" = \
    '/var/lib/uboot/320_R405_AFA011_ED103TC2C5_VB3300-KCD_TC.wbf|79783d751ba066af12c6ac5aca46279fe7c79d4ef834105bd46824f870f9c6f8|ED103TC2C5' ] ||
  fail "rm2 accepted waveform binding drifted"
case "$rm2_sources" in
  *R467*|*ED103TC2C6*)
    fail "rm2 inactive stock waveform became an accepted source"
    ;;
esac
[ "$PLUTO_PROFILE_POWER_KEY_DEVICE" = \
    /dev/input/by-path/platform-30370000.snvs:snvs-powerkey-event ] ||
  fail "rm2 power-key path drifted"
[ "$PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY:$PLUTO_PROFILE_RECOVERY_FAILURE_STRATEGY:$PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED:$PLUTO_PROFILE_RECOVERY_MMC_DEVICE:$PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS:$PLUTO_PROFILE_RECOVERY_BOOT_LIMIT" = \
    'uboot_env:uboot_env_force_reboot:1:/dev/mmcblk2:2,3:1' ] ||
  fail "rm2 U-Boot recovery contract drifted"

pluto_profile_load move || fail "could not load Move runtime profile"
[ "$PLUTO_PROFILE_NATIVE_SESSION_ENABLED" = 1 ] ||
  fail "Move native session is not enabled"
[ "$PLUTO_PROFILE_DISPLAY_DEVICE" = /dev/dri/card0 ] ||
  fail "Move display path drifted"
[ "$PLUTO_PROFILE_SCANOUT_WIDTH:$PLUTO_PROFILE_SCANOUT_HEIGHT:$PLUTO_PROFILE_BITS_PER_PIXEL" = \
    365:1700:16 ] || fail "Move DRM scanout geometry drifted"
[ -z "$PLUTO_PROFILE_VIRTUAL_WIDTH$PLUTO_PROFILE_VIRTUAL_HEIGHT$PLUTO_PROFILE_STRIDE_BYTES$PLUTO_PROFILE_FRAMEBUFFER_ROTATION" ] ||
  fail "Move incorrectly gained fixed fbdev layout fields"
[ "$PLUTO_PROFILE_BUFFER_SLOTS:$PLUTO_PROFILE_SLOT_BYTES" = \
    16:1241000 ] || fail "Move DRM buffer-ring geometry drifted"
[ "$PLUTO_PROFILE_DAMAGE_ALIGNMENT:$PLUTO_PROFILE_PHASE_INTERVAL_NS" = \
    8:11764706 ] || fail "Move alignment or phase interval drifted"
move_sources=$(pluto_profile_waveform_sources) ||
  fail "Move accepted waveform contract is missing"
[ "$move_sources" = \
    '/usr/share/remarkable/GAL3_AAB0AM_IC0801_AC073MC1F2_AD1004-GCA_TC.eink|80b8174773effceefbc16b54722cc0afd2187bd9a7c260a71bfbf92baeae8b67|AC073MC1F2' ] ||
  fail "Move waveform identity drifted"
[ "$PLUTO_PROFILE_FRONTLIGHT_BRIGHTNESS" = \
    /sys/class/backlight/rm_frontlight/brightness ] ||
  fail "Move frontlight path drifted"
[ "$PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY:$PLUTO_PROFILE_RECOVERY_FAILURE_STRATEGY:$PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED" = \
    lpgpr_counter:unverified:0 ] ||
  fail "Move gated recovery strategies drifted"
[ "$PLUTO_PROFILE_RECOVERY_HELPER" = \
    /usr/sbin/rm-reset-boot-count.sh ] ||
  fail "Move boot-confirmation helper drifted"
[ "$PLUTO_PROFILE_RECOVERY_COUNTER_DIR" = \
    /sys/devices/platform/lpgpr ] ||
  fail "Move boot-counter directory drifted"

printf 'device-profiles_test: ok\n'
