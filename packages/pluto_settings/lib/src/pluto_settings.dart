import 'package:meta/meta.dart';
import 'package:pluto_core/pluto_core.dart';

import 'battery.dart';
import 'frontlight.dart';
import 'power.dart';
import 'security.dart';
import 'wifi.dart';

/// Entry point for system settings and telemetry services.
final class PlutoSettings {
  /// Creates settings services backed by [transport].
  @visibleForTesting
  PlutoSettings.withTransport(PlutoTransport transport)
    : frontlight = Frontlight.withTransport(transport),
      wifi = WifiSettings.withTransport(transport),
      power = PowerSettings.withTransport(transport),
      security = SecuritySettings.withTransport(transport),
      battery = BatteryTelemetry.withTransport(transport);

  /// The process-wide settings instance backed by real embedder channels.
  static final PlutoSettings instance = PlutoSettings.withTransport(
    ChannelTransport.shared,
  );

  /// Frontlight controls.
  final Frontlight frontlight;

  /// Wi-Fi controls.
  final WifiSettings wifi;

  /// Power controls.
  final PowerSettings power;

  /// Security controls.
  final SecuritySettings security;

  /// Battery telemetry.
  final BatteryTelemetry battery;
}
