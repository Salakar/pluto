import 'package:pluto_core/pluto_core.dart';

import 'codec.dart';

/// Battery and marker telemetry.
final class BatteryTelemetry {
  /// Creates a battery service backed by the shared channel transport.
  BatteryTelemetry() : this.withTransport(ChannelTransport.shared);

  /// Creates a battery service backed by [transport].
  BatteryTelemetry.withTransport(this._transport);

  final PlutoTransport _transport;

  /// Snapshot of the device battery.
  Future<BatteryStatus> deviceBattery() async {
    final Object? payload = await _transport.invoke<Object?>(
      channel: plutoSettingsChannel,
      method: batteryDeviceMethod,
    );
    return BatteryStatus.fromMap(stringMap(payload, 'battery.device'));
  }

  /// Snapshot of the marker battery, or null when unavailable.
  Future<MarkerBatteryStatus?> markerBattery() async {
    final Object? payload = await _transport.invoke<Object?>(
      channel: plutoSettingsChannel,
      method: batteryMarkerMethod,
    );
    if (payload == null) {
      return null;
    }
    return MarkerBatteryStatus.fromMap(stringMap(payload, 'battery.marker'));
  }

  /// Periodic device-battery updates.
  Stream<BatteryStatus> deviceBatteryUpdates({
    Duration interval = const Duration(seconds: 30),
  }) {
    return _transport
        .events(
          channel: plutoSettingsEventsChannel,
          arguments: <String, Object?>{
            'topic': 'battery.device',
            'intervalMs': interval.inMilliseconds,
          },
        )
        .map(
          (Object? event) =>
              BatteryStatus.fromMap(stringMap(event, 'battery device event')),
        );
  }

  /// Periodic marker-battery updates.
  Stream<MarkerBatteryStatus?> markerBatteryUpdates({
    Duration interval = const Duration(seconds: 60),
  }) {
    return _transport
        .events(
          channel: plutoSettingsEventsChannel,
          arguments: <String, Object?>{
            'topic': 'battery.marker',
            'intervalMs': interval.inMilliseconds,
          },
        )
        .map((Object? event) {
          if (event == null) {
            return null;
          }
          return MarkerBatteryStatus.fromMap(
            stringMap(event, 'battery marker event'),
          );
        });
  }

  /// Compatibility percentage getter for earlier scaffold consumers.
  Future<int> get levelPercent async {
    final BatteryStatus status = await deviceBattery();
    return (status.level * 100).round();
  }
}

/// Compatibility alias for older docs that used `Battery`.
typedef Battery = BatteryTelemetry;

/// Charging state from kernel power-supply status.
enum BatteryChargingState {
  /// Battery is charging.
  charging,

  /// Battery is discharging.
  discharging,

  /// Battery is full.
  full,

  /// Battery is not charging.
  notCharging,

  /// Status is unknown.
  unknown;

  /// Parses a protocol charging-state name.
  static BatteryChargingState parse(String value) {
    for (final BatteryChargingState state in BatteryChargingState.values) {
      if (state.name == value) {
        return state;
      }
    }
    return BatteryChargingState.unknown;
  }
}

/// Immutable device-battery snapshot.
final class BatteryStatus {
  /// Creates a battery snapshot.
  const BatteryStatus({
    required this.level,
    required this.state,
    required this.isUsbPowerPresent,
  });

  /// Creates a battery snapshot from a protocol map.
  factory BatteryStatus.fromMap(Map<String, Object?> map) {
    return BatteryStatus(
      level: doubleAt(map, 'level'),
      state: BatteryChargingState.parse(stringAt(map, 'state')),
      isUsbPowerPresent: boolAt(map, 'isUsbPowerPresent'),
    );
  }

  /// Charge level from 0 to 1.
  final double level;

  /// Charging state.
  final BatteryChargingState state;

  /// Whether USB charger input reports power.
  final bool isUsbPowerPresent;
}

/// Immutable marker battery snapshot.
final class MarkerBatteryStatus {
  /// Creates a marker battery snapshot.
  const MarkerBatteryStatus({required this.level, this.nfcCellLevel});

  /// Creates a marker battery snapshot from a protocol map.
  factory MarkerBatteryStatus.fromMap(Map<String, Object?> map) {
    return MarkerBatteryStatus(
      level: doubleAt(map, 'level'),
      nfcCellLevel: optionalDoubleAt(map, 'nfcCellLevel'),
    );
  }

  /// Main marker cell level from 0 to 1.
  final double level;

  /// Secondary NFC cell level, when reported.
  final double? nfcCellLevel;
}
