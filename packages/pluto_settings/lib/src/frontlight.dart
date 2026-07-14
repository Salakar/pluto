import 'dart:math' as math;

import 'package:pluto_core/pluto_core.dart';

import 'codec.dart';

/// Frontlight reading-light control.
final class Frontlight {
  /// Creates a frontlight service backed by the shared channel transport.
  Frontlight() : this.withTransport(ChannelTransport.shared);

  /// Creates a frontlight service backed by [transport].
  Frontlight.withTransport(this._transport);

  final PlutoTransport _transport;

  /// Current frontlight state.
  Future<FrontlightState> state() async {
    final Object? payload = await _transport.invoke<Object?>(
      channel: plutoSettingsChannel,
      method: frontlightReadMethod,
    );
    return FrontlightState.fromMap(stringMap(payload, 'frontlight'));
  }

  /// Sets brightness as a fraction of the device maximum, clamped to 0..1.
  Future<void> setBrightnessFraction(double fraction) async {
    if (fraction.isNaN) {
      throw ArgumentError.value(fraction, 'fraction', 'must be a number');
    }
    final FrontlightState current = await state();
    final double clamped = math.max(0, math.min(1, fraction));
    await setBrightnessRaw((clamped * current.maxRaw).round());
  }

  /// Sets the raw sysfs brightness value.
  Future<void> setBrightnessRaw(int raw) async {
    final FrontlightState current = await state();
    if (raw < 0 || raw > current.maxRaw) {
      throw RangeError.range(raw, 0, current.maxRaw, 'raw');
    }
    await invokeVoid(
      _transport,
      frontlightWriteMethod,
      arguments: <String, Object?>{'raw': raw},
    );
  }

  /// Emits whenever the brightness changes.
  Stream<FrontlightState> get onChanged {
    return _transport
        .events(
          channel: plutoSettingsEventsChannel,
          arguments: const <String, Object?>{'topic': 'frontlight'},
        )
        .map(
          (Object? event) =>
              FrontlightState.fromMap(stringMap(event, 'frontlight event')),
        );
  }
}

/// Immutable frontlight snapshot.
final class FrontlightState {
  /// Creates a frontlight snapshot.
  const FrontlightState({required this.raw, required this.maxRaw});

  /// Creates a frontlight snapshot from a protocol map.
  factory FrontlightState.fromMap(Map<String, Object?> map) {
    return FrontlightState(
      raw: intAt(map, 'raw'),
      maxRaw: intAt(map, 'maxRaw'),
    );
  }

  /// Raw sysfs value.
  final int raw;

  /// Device maximum from `max_brightness`.
  final int maxRaw;

  /// Normalized brightness from 0 to 1.
  double get fraction => maxRaw == 0 ? 0 : raw / maxRaw;

  /// Whether the light is emitting.
  bool get isOn => raw > 0;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is FrontlightState && raw == other.raw && maxRaw == other.maxRaw;
  }

  @override
  int get hashCode => Object.hash(raw, maxRaw);
}
