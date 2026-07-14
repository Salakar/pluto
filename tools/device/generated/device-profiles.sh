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
      PLUTO_PROFILE_SOURCE_PIXEL_FORMAT='rgb565'
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
      PLUTO_PROFILE_SOURCE_PIXEL_FORMAT='rgb565'
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
      PLUTO_PROFILE_SOURCE_PIXEL_FORMAT='rgb565'
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
  export PLUTO_PROFILE_SOURCE_PIXEL_FORMAT
  export PLUTO_PROFILE_BUILD_MODES PLUTO_PROFILE_CAPABILITIES
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
