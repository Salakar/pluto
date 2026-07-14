import 'package:pluto_core/pluto_core.dart';

import 'codec.dart';

/// Standby/sleep policy and immediate power actions.
final class PowerSettings {
  /// Creates a power service backed by the shared channel transport.
  PowerSettings() : this.withTransport(ChannelTransport.shared);

  /// Creates a power service backed by [transport].
  PowerSettings.withTransport(this._transport);

  final PlutoTransport _transport;

  /// Current power policy.
  Future<PowerPolicy> policy() async {
    final Object? payload = await _transport.invoke<Object?>(
      channel: plutoSettingsChannel,
      method: powerPolicyMethod,
    );
    return PowerPolicy.fromMap(stringMap(payload, 'power.policy'));
  }

  /// Sets how long the device stays awake with no input before suspending.
  Future<void> setIdleSuspendDelay(Duration delay) async {
    await invokeVoid(
      _transport,
      powerSetIdleSuspendDelayMethod,
      arguments: <String, Object?>{'ms': delay.inMilliseconds},
    );
  }

  /// Sets how long the device stays suspended before powering off fully.
  Future<void> setSuspendPowerOffDelay(Duration delay) async {
    await invokeVoid(
      _transport,
      powerSetSuspendPowerOffDelayMethod,
      arguments: <String, Object?>{'ms': delay.inMilliseconds},
    );
  }

  /// Suspends the device immediately.
  Future<void> suspendNow() async {
    await invokeVoid(_transport, powerSuspendNowMethod);
  }

  /// Compatibility alias for earlier scaffold consumers.
  Future<void> suspend() => suspendNow();
}

/// Compatibility alias for older docs that used `Power`.
typedef Power = PowerSettings;

/// Immutable power policy snapshot.
final class PowerPolicy {
  /// Creates a power policy snapshot.
  const PowerPolicy({
    required this.idleSuspendDelay,
    required this.suspendPowerOffDelay,
  });

  /// Creates a power policy from a protocol map.
  factory PowerPolicy.fromMap(Map<String, Object?> map) {
    return PowerPolicy(
      idleSuspendDelay: Duration(
        milliseconds: intAt(map, 'idleSuspendDelayMs'),
      ),
      suspendPowerOffDelay: Duration(
        milliseconds: intAt(map, 'suspendPowerOffDelayMs'),
      ),
    );
  }

  /// Input-idle duration before automatic suspend.
  final Duration idleSuspendDelay;

  /// Suspended duration before full power-off.
  final Duration suspendPowerOffDelay;

  /// Returns a copy with selected fields replaced.
  PowerPolicy copyWith({
    Duration? idleSuspendDelay,
    Duration? suspendPowerOffDelay,
  }) {
    return PowerPolicy(
      idleSuspendDelay: idleSuspendDelay ?? this.idleSuspendDelay,
      suspendPowerOffDelay: suspendPowerOffDelay ?? this.suspendPowerOffDelay,
    );
  }
}
