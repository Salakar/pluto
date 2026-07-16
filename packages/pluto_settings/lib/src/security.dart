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
    throw const FormatException('Expected security.isPinSet to be a bool.');
  }

  /// Sets or replaces the device PIN.
  Future<void> setPin(DevicePin pin) async {
    await invokeVoid(
      _transport,
      securitySetPinMethod,
      arguments: <String, Object?>{'pin': pin.digits},
    );
  }

  /// Removes the device PIN.
  Future<void> removePin() async {
    await invokeVoid(_transport, securityRemovePinMethod);
  }
}
