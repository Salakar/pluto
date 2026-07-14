import 'package:pluto_core/pluto_core.dart';

import 'codec.dart';

/// A device passcode: 4-8 decimal digits.
extension type const DevicePin._(String _digits) {
  /// Validates [input] and returns a [DevicePin] for 4-8 decimal digits.
  static DevicePin? tryParse(String input) {
    return RegExp(r'^[0-9]{4,8}$').hasMatch(input) ? DevicePin._(input) : null;
  }

  /// The validated digit string.
  String get digits => _digits;
}

/// Device PIN management.
final class SecuritySettings {
  /// Creates a security service backed by the shared channel transport.
  SecuritySettings() : this.withTransport(ChannelTransport.shared);

  /// Creates a security service backed by [transport].
  SecuritySettings.withTransport(this._transport);

  final PlutoTransport _transport;

  /// Whether a PIN is currently set.
  Future<bool> isPinSet() async {
    final Object? payload = await _transport.invoke<Object?>(
      channel: plutoSettingsChannel,
      method: securityIsPinSetMethod,
    );
    if (payload is bool) {
      return payload;
    }
    return boolAt(stringMap(payload, 'security.isPinSet'), 'isPinSet');
  }

  /// Sets or replaces the device PIN.
  Future<void> setPin(DevicePin pin) async {
    await invokeVoid(
      _transport,
      securitySetPinMethod,
      arguments: <String, Object?>{'pin': pin.digits},
    );
  }

  /// Compatibility helper for string PIN callers.
  Future<void> setPinString(String pin) async {
    final DevicePin? parsed = DevicePin.tryParse(pin);
    if (parsed == null) {
      throw ArgumentError.value(pin, 'pin', 'must be 4-8 decimal digits');
    }
    await setPin(parsed);
  }

  /// Removes the device PIN.
  Future<void> removePin() async {
    await invokeVoid(_transport, securityRemovePinMethod);
  }
}

/// Compatibility alias for older docs that used `Security`.
typedef Security = SecuritySettings;
