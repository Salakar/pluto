#ifndef PLUTO_CHANNELS_SERVICE_CHANNELS_H_
#define PLUTO_CHANNELS_SERVICE_CHANNELS_H_

#include <string>

#include "channels/channel_registry.h"

namespace pluto {

// Filesystem and tool endpoints backing the pluto/session, pluto/settings,
// and pluto/apps method channels. Every entry is overridable through an
// environment variable so host tests can point the handlers at temp dirs.
struct ServicePaths {
  // PLUTO_RUN_DIR: control files the session supervisor watches
  // (launch/home/standby/power-menu/poweroff/stock).
  std::string run_dir = "/run/pluto";
  // PLUTO_APPS_DIR: installed app registry, apps/<id>/{manifest.json,bundle}.
  std::string apps_dir = "/home/root/pluto/apps";
  // PLUTO_DATA_DIR: per-app data directories, data/<id>.
  std::string data_dir = "/home/root/pluto/appdata";
  // PLUTO_CONFIG_DIR: launcher state (pin, pinned, standby_ms, rotation).
  std::string config_dir = "/home/root/pluto/state/launcher-config";
  // PLUTO_BACKLIGHT: sysfs backlight class dir with brightness files.
  std::string backlight_dir = "/sys/class/backlight/rm_frontlight";
  // PLUTO_VPDD_LENGTH_FILE: delayed panel-power hold configured before the
  // CRTC is disabled. Standby sets it to zero so suspend is not blocked by the
  // regulator's normal 30-second post-refresh timer.
  std::string vpdd_length_file =
      "/sys/bus/i2c/drivers/g2194-regulator/0-0048/vpdd_length";
  // PLUTO_POWER_SUPPLY: sysfs power-supply class dir for battery telemetry.
  std::string power_supply_dir = "/sys/class/power_supply";
  // PLUTO_WPA_CONTROL_DIR: wpa_supplicant Unix control-socket directory.
  std::string wpa_control_dir = "/var/run/wpa_supplicant";
  // PLUTO_WIFI_SETTINGS_FILE: firmware connectivity preference. A
  // `wifi = off` entry prevents wpa_supplicant.service from starting.
  std::string wifi_settings_file =
      "/home/root/.config/remarkable/csl.conf";
  // PLUTO_SYSTEMCTL: systemd client used only to start/stop the firmware's
  // wpa_supplicant service. Credentials never pass through this command.
  std::string systemctl = "/usr/bin/systemctl";
  // PLUTO_WIFI_IFACE: wpa_supplicant wireless interface.
  std::string wifi_interface = "wlan0";
  // PLUTO_NETWORK_CLASS: sysfs network-interface class directory.
  std::string network_class_dir = "/sys/class/net";
  // PLUTO_USB_IFACE_PREFIX: prefix used by the tablet USB gadget links.
  // Both usb0 and usb1 occur across reMarkable models/configurations.
  std::string usb_interface_prefix = "usb";
  // PLUTO_OS_RELEASE: os-release file used for firmware/os versions.
  std::string os_release_file = "/etc/os-release";
  // PLUTO_SERIAL_CMD: command whose stdout is the device serial; empty
  // disables the lookup.
  std::string serial_command = "devconfig serial_number_epd";
  // PLUTO_HWMON: sysfs hwmon class dir for temperature telemetry.
  std::string hwmon_dir = "/sys/class/hwmon";
  // PLUTO_APP_ID: id of the running app; scopes pluto/paths directories
  // under <data_dir>/<app_id>.
  std::string app_id = "default";
};

ServicePaths service_paths_from_env();

// Registers the pluto/core, pluto/device, pluto/paths,
// pluto/session, pluto/settings, and pluto/apps handlers.
void register_service_channels(ChannelRegistry* registry, ServicePaths paths);

}  // namespace pluto

#endif  // PLUTO_CHANNELS_SERVICE_CHANNELS_H_
