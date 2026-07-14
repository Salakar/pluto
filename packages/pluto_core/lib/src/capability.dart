/// A feature the current device and embedder combination may support.
enum Capability {
  /// Adjustable frontlight at `/sys/class/backlight/rm_frontlight`.
  frontlight,

  /// Color Gallery 3 panel.
  colorPanel,

  /// Marker battery telemetry from power-supply sysfs.
  markerBattery,

  /// Wi-Fi radio managed by the device connectivity stack.
  wifi,

  /// Hall-effect folio sensors.
  folioSensors,

  /// Type Folio keyboard support.
  folioKeyboard,

  /// Device PIN management.
  devicePin,

  /// Standby and sleep policy control.
  powerPolicy,

  /// High-rate pen shared-memory sample ring.
  penSampleRing,
}
