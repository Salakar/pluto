# GENERATED FILE. Edit config/device_profiles.json, then run
# dart tools/codegen/generate_device_profiles.dart.

pluto_profile_load() {
  case "$1" in
    rm1)
      PLUTO_PROFILE_ID='rm1'
      PLUTO_PROFILE_WIRE_MODEL='remarkable1'
      PLUTO_PROFILE_CODENAME='zero-gravitas'
      PLUTO_PROFILE_TARGET='linux-arm'
      PLUTO_PROFILE_DISPLAY_DRIVER='mxcfb_epdc'
      PLUTO_PROFILE_PANEL_WIDTH=1404
      PLUTO_PROFILE_PANEL_HEIGHT=1872
      PLUTO_PROFILE_PANEL_DPI=226
      PLUTO_PROFILE_PANEL_SIGNATURE='ES103CS1'
      PLUTO_PROFILE_SOURCE_PIXEL_FORMAT='rgb565'
      PLUTO_PROFILE_NATIVE_SESSION_ENABLED=0
      PLUTO_PROFILE_FIRMWARE_BUILD='20260612085811'
      PLUTO_PROFILE_KERNEL_RELEASE='5.4.70-v1.6.3-rm10x'
      PLUTO_PROFILE_DISPLAY_DEVICE='/dev/fb0'
      PLUTO_PROFILE_SCANOUT_WIDTH=1404
      PLUTO_PROFILE_SCANOUT_HEIGHT=1872
      PLUTO_PROFILE_VIRTUAL_WIDTH='1408'
      PLUTO_PROFILE_VIRTUAL_HEIGHT='3840'
      PLUTO_PROFILE_STRIDE_BYTES='2816'
      PLUTO_PROFILE_MAPPING_BYTES='10813440'
      PLUTO_PROFILE_BITS_PER_PIXEL=16
      PLUTO_PROFILE_FRAMEBUFFER_ROTATION='1'
      PLUTO_PROFILE_BUFFER_SLOTS=''
      PLUTO_PROFILE_SLOT_BYTES=''
      PLUTO_PROFILE_DAMAGE_ALIGNMENT=1
      PLUTO_PROFILE_PHASE_INTERVAL_NS=''
      PLUTO_PROFILE_WAVEFORM_OPTION_KEY=''
      PLUTO_PROFILE_PRESENTER_OPTIONS=''
      PLUTO_PROFILE_PEN_DEVICE='/dev/input/by-path/platform-21a4000.i2c-event-mouse'
      PLUTO_PROFILE_PEN_NAME='Wacom I2C Digitizer'
      PLUTO_PROFILE_TOUCH_DEVICE='/dev/input/by-path/platform-21a8000.i2c-event'
      PLUTO_PROFILE_TOUCH_NAME='cyttsp5_mt'
      PLUTO_PROFILE_POWER_KEY_DEVICE='/dev/input/by-path/platform-gpio-keys-event'
      PLUTO_PROFILE_POWER_KEY_NAME='gpio-keys'
      PLUTO_PROFILE_FRONTLIGHT_BRIGHTNESS=''
      PLUTO_PROFILE_VPDD_TIMEOUT=''
      PLUTO_PROFILE_BEZEL_REDRAW_IIO=''
      PLUTO_PROFILE_BEZEL_REDRAW_ENABLE=''
      PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY='uboot_env'
      PLUTO_PROFILE_RECOVERY_FAILURE_STRATEGY='uboot_env_force_reboot'
      PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED='1'
      PLUTO_PROFILE_RECOVERY_MMC_DEVICE='/dev/mmcblk1'
      PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS='2,3'
      PLUTO_PROFILE_RECOVERY_BOOT_LIMIT='1'
      PLUTO_PROFILE_RECOVERY_HELPER=''
      PLUTO_PROFILE_RECOVERY_COUNTER_DIR=''
      PLUTO_PROFILE_SUSPEND_COMMAND='systemctl start --wait suspend.target'
      PLUTO_PROFILE_BUILD_MODES='release'
      PLUTO_PROFILE_CAPABILITIES='pen,touch,refresh-control,real-completion'
      ;;
    rm2)
      PLUTO_PROFILE_ID='rm2'
      PLUTO_PROFILE_WIRE_MODEL='remarkable2'
      PLUTO_PROFILE_CODENAME='zero-sugar'
      PLUTO_PROFILE_TARGET='linux-arm'
      PLUTO_PROFILE_DISPLAY_DRIVER='lcdif_tcon'
      PLUTO_PROFILE_PANEL_WIDTH=1404
      PLUTO_PROFILE_PANEL_HEIGHT=1872
      PLUTO_PROFILE_PANEL_DPI=226
      PLUTO_PROFILE_PANEL_SIGNATURE='ED103TC2C5'
      PLUTO_PROFILE_SOURCE_PIXEL_FORMAT='rgb565'
      PLUTO_PROFILE_NATIVE_SESSION_ENABLED=0
      PLUTO_PROFILE_FIRMWARE_BUILD='20260629074044'
      PLUTO_PROFILE_KERNEL_RELEASE='5.4.70-v1.6.3-rm11x'
      PLUTO_PROFILE_DISPLAY_DEVICE='/dev/fb0'
      PLUTO_PROFILE_SCANOUT_WIDTH=260
      PLUTO_PROFILE_SCANOUT_HEIGHT=1408
      PLUTO_PROFILE_VIRTUAL_WIDTH='260'
      PLUTO_PROFILE_VIRTUAL_HEIGHT='23936'
      PLUTO_PROFILE_STRIDE_BYTES='1040'
      PLUTO_PROFILE_MAPPING_BYTES='33554432'
      PLUTO_PROFILE_BITS_PER_PIXEL=32
      PLUTO_PROFILE_FRAMEBUFFER_ROTATION='0'
      PLUTO_PROFILE_BUFFER_SLOTS='17'
      PLUTO_PROFILE_SLOT_BYTES='1464320'
      PLUTO_PROFILE_DAMAGE_ALIGNMENT=8
      PLUTO_PROFILE_PHASE_INTERVAL_NS='11763000'
      PLUTO_PROFILE_WAVEFORM_OPTION_KEY='wbf'
      PLUTO_PROFILE_PRESENTER_OPTIONS=''
      PLUTO_PROFILE_PEN_DEVICE='/dev/input/by-path/platform-30a20000.i2c-event-mouse'
      PLUTO_PROFILE_PEN_NAME='Wacom I2C Digitizer'
      PLUTO_PROFILE_TOUCH_DEVICE='/dev/input/by-path/platform-30a40000.i2c-event'
      PLUTO_PROFILE_TOUCH_NAME='pt_mt'
      PLUTO_PROFILE_POWER_KEY_DEVICE='/dev/input/by-path/platform-30370000.snvs:snvs-powerkey-event'
      PLUTO_PROFILE_POWER_KEY_NAME='30370000.snvs:snvs-powerkey'
      PLUTO_PROFILE_FRONTLIGHT_BRIGHTNESS=''
      PLUTO_PROFILE_VPDD_TIMEOUT=''
      PLUTO_PROFILE_BEZEL_REDRAW_IIO=''
      PLUTO_PROFILE_BEZEL_REDRAW_ENABLE=''
      PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY='uboot_env'
      PLUTO_PROFILE_RECOVERY_FAILURE_STRATEGY='uboot_env_force_reboot'
      PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED='1'
      PLUTO_PROFILE_RECOVERY_MMC_DEVICE='/dev/mmcblk2'
      PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS='2,3'
      PLUTO_PROFILE_RECOVERY_BOOT_LIMIT='1'
      PLUTO_PROFILE_RECOVERY_HELPER=''
      PLUTO_PROFILE_RECOVERY_COUNTER_DIR=''
      PLUTO_PROFILE_SUSPEND_COMMAND='systemctl start --wait suspend.target'
      PLUTO_PROFILE_BUILD_MODES='release'
      PLUTO_PROFILE_CAPABILITIES='pen,touch,refresh-control,real-completion'
      ;;
    move)
      PLUTO_PROFILE_ID='move'
      PLUTO_PROFILE_WIRE_MODEL='paperProMove'
      PLUTO_PROFILE_CODENAME='chiappa'
      PLUTO_PROFILE_TARGET='linux-arm64'
      PLUTO_PROFILE_DISPLAY_DRIVER='gallery3_drm'
      PLUTO_PROFILE_PANEL_WIDTH=954
      PLUTO_PROFILE_PANEL_HEIGHT=1696
      PLUTO_PROFILE_PANEL_DPI=264
      PLUTO_PROFILE_PANEL_SIGNATURE='AC073MC1F2'
      PLUTO_PROFILE_SOURCE_PIXEL_FORMAT='rgb565'
      PLUTO_PROFILE_NATIVE_SESSION_ENABLED=1
      PLUTO_PROFILE_FIRMWARE_BUILD='20260629074044'
      PLUTO_PROFILE_KERNEL_RELEASE='6.12.49+git-imx93-chiappa-gf4c2ab7040e8'
      PLUTO_PROFILE_DISPLAY_DEVICE='/dev/dri/card0'
      PLUTO_PROFILE_SCANOUT_WIDTH=365
      PLUTO_PROFILE_SCANOUT_HEIGHT=1700
      PLUTO_PROFILE_VIRTUAL_WIDTH=''
      PLUTO_PROFILE_VIRTUAL_HEIGHT=''
      PLUTO_PROFILE_STRIDE_BYTES=''
      PLUTO_PROFILE_MAPPING_BYTES=''
      PLUTO_PROFILE_BITS_PER_PIXEL=16
      PLUTO_PROFILE_FRAMEBUFFER_ROTATION=''
      PLUTO_PROFILE_BUFFER_SLOTS='16'
      PLUTO_PROFILE_SLOT_BYTES='1241000'
      PLUTO_PROFILE_DAMAGE_ALIGNMENT=8
      PLUTO_PROFILE_PHASE_INTERVAL_NS='11764706'
      PLUTO_PROFILE_WAVEFORM_OPTION_KEY='eink'
      PLUTO_PROFILE_PRESENTER_OPTIONS='exact_color=1,enable_rails=1,vcom=-0.62,du_mode=7,dither=1,settle_delay_ms=0,full_refresh_every=0'
      PLUTO_PROFILE_PEN_DEVICE='/dev/input/by-path/platform-44360000.spi-cs-0-event-mouse'
      PLUTO_PROFILE_PEN_NAME='Elan marker input'
      PLUTO_PROFILE_TOUCH_DEVICE='/dev/input/by-path/platform-44360000.spi-cs-0-event'
      PLUTO_PROFILE_TOUCH_NAME='Elan touch input'
      PLUTO_PROFILE_POWER_KEY_DEVICE='/dev/input/by-path/platform-44440000.bbnsm:pwrkey-event'
      PLUTO_PROFILE_POWER_KEY_NAME='44440000.bbnsm:pwrkey'
      PLUTO_PROFILE_FRONTLIGHT_BRIGHTNESS='/sys/class/backlight/rm_frontlight/brightness'
      PLUTO_PROFILE_VPDD_TIMEOUT='/sys/bus/i2c/drivers/g2194-regulator/0-0048/vpdd_timeout_ms'
      PLUTO_PROFILE_BEZEL_REDRAW_IIO='/dev/iio:device3'
      PLUTO_PROFILE_BEZEL_REDRAW_ENABLE='/sys/bus/iio/devices/iio:device3/events/in_accel0_gesture_doubletap_en'
      PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY='lpgpr_counter'
      PLUTO_PROFILE_RECOVERY_FAILURE_STRATEGY='unverified'
      PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED='0'
      PLUTO_PROFILE_RECOVERY_MMC_DEVICE=''
      PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS=''
      PLUTO_PROFILE_RECOVERY_BOOT_LIMIT=''
      PLUTO_PROFILE_RECOVERY_HELPER='/usr/sbin/rm-reset-boot-count.sh'
      PLUTO_PROFILE_RECOVERY_COUNTER_DIR='/sys/devices/platform/lpgpr'
      PLUTO_PROFILE_SUSPEND_COMMAND='systemctl start --wait suspend.target'
      PLUTO_PROFILE_BUILD_MODES='release,profile,debug'
      PLUTO_PROFILE_CAPABILITIES='pen,touch,frontlight,refresh-control,real-completion,color-quantization,overlap-supersession,exact-color-handoff,hot-reload'
      ;;
    *)
      return 1
      ;;
  esac
  export PLUTO_PROFILE_ID PLUTO_PROFILE_WIRE_MODEL
  export PLUTO_PROFILE_CODENAME PLUTO_PROFILE_TARGET
  export PLUTO_PROFILE_DISPLAY_DRIVER PLUTO_PROFILE_PANEL_WIDTH
  export PLUTO_PROFILE_PANEL_HEIGHT PLUTO_PROFILE_PANEL_DPI
  export PLUTO_PROFILE_PANEL_SIGNATURE
  export PLUTO_PROFILE_SOURCE_PIXEL_FORMAT
  export PLUTO_PROFILE_NATIVE_SESSION_ENABLED
  export PLUTO_PROFILE_FIRMWARE_BUILD
  export PLUTO_PROFILE_KERNEL_RELEASE
  export PLUTO_PROFILE_DISPLAY_DEVICE
  export PLUTO_PROFILE_SCANOUT_WIDTH PLUTO_PROFILE_SCANOUT_HEIGHT
  export PLUTO_PROFILE_VIRTUAL_WIDTH PLUTO_PROFILE_VIRTUAL_HEIGHT
  export PLUTO_PROFILE_STRIDE_BYTES PLUTO_PROFILE_BITS_PER_PIXEL
  export PLUTO_PROFILE_MAPPING_BYTES
  export PLUTO_PROFILE_FRAMEBUFFER_ROTATION
  export PLUTO_PROFILE_BUFFER_SLOTS PLUTO_PROFILE_SLOT_BYTES
  export PLUTO_PROFILE_DAMAGE_ALIGNMENT
  export PLUTO_PROFILE_PHASE_INTERVAL_NS
  export PLUTO_PROFILE_WAVEFORM_OPTION_KEY
  export PLUTO_PROFILE_PRESENTER_OPTIONS
  export PLUTO_PROFILE_PEN_DEVICE PLUTO_PROFILE_PEN_NAME
  export PLUTO_PROFILE_TOUCH_DEVICE PLUTO_PROFILE_TOUCH_NAME
  export PLUTO_PROFILE_POWER_KEY_DEVICE PLUTO_PROFILE_POWER_KEY_NAME
  export PLUTO_PROFILE_FRONTLIGHT_BRIGHTNESS
  export PLUTO_PROFILE_VPDD_TIMEOUT
  export PLUTO_PROFILE_BEZEL_REDRAW_IIO
  export PLUTO_PROFILE_BEZEL_REDRAW_ENABLE
  export PLUTO_PROFILE_RECOVERY_CONFIRMATION_STRATEGY
  export PLUTO_PROFILE_RECOVERY_FAILURE_STRATEGY
  export PLUTO_PROFILE_RECOVERY_BOOT_DEFAULT_ENABLED
  export PLUTO_PROFILE_RECOVERY_MMC_DEVICE
  export PLUTO_PROFILE_RECOVERY_ROOT_PARTITIONS
  export PLUTO_PROFILE_RECOVERY_BOOT_LIMIT
  export PLUTO_PROFILE_RECOVERY_HELPER
  export PLUTO_PROFILE_RECOVERY_COUNTER_DIR
  export PLUTO_PROFILE_SUSPEND_COMMAND
  export PLUTO_PROFILE_BUILD_MODES PLUTO_PROFILE_CAPABILITIES
}

pluto_profile_presenter_options() {
  _pluto_profile_base_options=$1
  _pluto_profile_waveform_path=$2
  if [ -z "$PLUTO_PROFILE_WAVEFORM_OPTION_KEY" ]; then
    printf '%s\n' "$_pluto_profile_base_options"
    return 0
  fi
  [ -n "$_pluto_profile_waveform_path" ] || return 1
  if [ -n "$_pluto_profile_base_options" ]; then
    printf '%s,%s=%s\n' "$_pluto_profile_base_options" "$PLUTO_PROFILE_WAVEFORM_OPTION_KEY" "$_pluto_profile_waveform_path"
  else
    printf '%s=%s\n' "$PLUTO_PROFILE_WAVEFORM_OPTION_KEY" "$_pluto_profile_waveform_path"
  fi
}

pluto_profile_waveform_discovery_paths() {
  case "${PLUTO_PROFILE_ID:-}" in
    rm1)
      printf '%s\n' '/lib/firmware/imx/epdc/epdc_ES103CS1.fw'
      ;;
    rm2)
      printf '%s\n' '/var/lib/uboot/320_R405_AFA011_ED103TC2C5_VB3300-KCD_TC.wbf'
      printf '%s\n' '/usr/share/remarkable/320_R467_AF4731_ED103TC2C6_VB3300-KCD_TC.wbf'
      ;;
    move)
      printf '%s\n' '/usr/share/remarkable/GAL3_AAB0AM_IC0801_AC073MC1F2_AD1004-GCA_TC.eink'
      ;;
    *) return 1 ;;
  esac
}

pluto_profile_waveform_sources() {
  case "${PLUTO_PROFILE_ID:-}" in
    rm1)
      printf '%s|%s|%s\n' '/lib/firmware/imx/epdc/epdc_ES103CS1.fw' '185515bebf37d3e9d99ffa1f13a2804bbb2b64464fa6fc5067475fb6f65ff6b0' 'ES103CS1'
      ;;
    rm2)
      printf '%s|%s|%s\n' '/var/lib/uboot/320_R405_AFA011_ED103TC2C5_VB3300-KCD_TC.wbf' '79783d751ba066af12c6ac5aca46279fe7c79d4ef834105bd46824f870f9c6f8' 'ED103TC2C5'
      ;;
    move)
      printf '%s|%s|%s\n' '/usr/share/remarkable/GAL3_AAB0AM_IC0801_AC073MC1F2_AD1004-GCA_TC.eink' '80b8174773effceefbc16b54722cc0afd2187bd9a7c260a71bfbf92baeae8b67' 'AC073MC1F2'
      ;;
    *) return 1 ;;
  esac
}

pluto_profile_detect() {
  _pluto_board=$(printf '%s %s' "$1" "$2" | tr '[:upper:]' '[:lower:]')
  _pluto_compatible=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')
  _pluto_arch=$(printf '%s' "$4" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  _pluto_matches=''
  case "$_pluto_arch" in
    "armv7l")
      case "$_pluto_board" in
        *"remarkable 1.0"*|*"remarkable 1.n"*|*"zero-gravitas"*)
          case "$_pluto_compatible" in
            *"remarkable,zero-gravitas"*|*"fsl,imx6sl"*) _pluto_matches="$_pluto_matches rm1" ;;
          esac
          ;;
      esac
      ;;
  esac
  case "$_pluto_arch" in
    "armv7l")
      case "$_pluto_board" in
        *"remarkable 2.0"*|*"remarkable 2.n"*|*"zero-sugar"*)
          case "$_pluto_compatible" in
            *"fsl,imx7d-sdb"*) _pluto_matches="$_pluto_matches rm2" ;;
          esac
          ;;
      esac
      ;;
  esac
  case "$_pluto_arch" in
    "aarch64")
      case "$_pluto_board" in
        *"chiappa"*)
          case "$_pluto_compatible" in
            *"fsl,imx93"*) _pluto_matches="$_pluto_matches move" ;;
          esac
          ;;
      esac
      ;;
  esac
  case "$_pluto_matches" in
    " rm1") pluto_profile_load rm1 ;;
    " rm2") pluto_profile_load rm2 ;;
    " move") pluto_profile_load move ;;
    *) return 1 ;;
  esac
}

pluto_profile_probe() {
  _pluto_machine=$(cat /sys/devices/soc0/machine 2>/dev/null || true)
  _pluto_model=$(tr '\000' ' ' </proc/device-tree/model 2>/dev/null || true)
  _pluto_compatible=$(tr '\000' ' ' </proc/device-tree/compatible 2>/dev/null || true)
  _pluto_arch=$(uname -m 2>/dev/null || true)
  pluto_profile_detect "$_pluto_machine" "$_pluto_model" "$_pluto_compatible" "$_pluto_arch"
}
