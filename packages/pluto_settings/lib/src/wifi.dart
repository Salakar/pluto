import 'package:pluto_core/pluto_core.dart';

import 'codec.dart';

/// Wi-Fi control via the device connectivity stack.
final class WifiSettings {
  /// Creates a Wi-Fi service backed by the shared channel transport.
  WifiSettings() : this.withTransport(ChannelTransport.shared);

  /// Creates a Wi-Fi service backed by [transport].
  WifiSettings.withTransport(this._transport);

  final PlutoTransport _transport;

  /// Whether the Wi-Fi radio is enabled.
  Future<bool> isEnabled() async {
    final Object? payload = await _transport.invoke<Object?>(
      channel: plutoSettingsChannel,
      method: wifiIsEnabledMethod,
    );
    if (payload is bool) {
      return payload;
    }
    throw const FormatException('Expected Wi-Fi enabled state.');
  }

  /// Enables or disables the Wi-Fi radio.
  Future<void> setEnabled(bool enabled) async {
    await invokeVoid(
      _transport,
      wifiSetEnabledMethod,
      arguments: <String, Object?>{'enabled': enabled},
    );
  }

  /// Scans and returns visible networks, strongest signal first.
  Future<List<WifiNetwork>> scanNetworks({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final Object? payload = await _transport.invoke<Object?>(
      channel: plutoSettingsChannel,
      method: wifiScanMethod,
      arguments: <String, Object?>{'timeoutMs': timeout.inMilliseconds},
    );
    return <WifiNetwork>[
      for (final Object? item in objectList(payload, 'wifi.scan'))
        WifiNetwork.fromMap(stringMap(item, 'wifi network')),
    ];
  }

  /// Currently active connection, or null when disconnected.
  Future<WifiConnection?> activeConnection() async {
    final Object? payload = await _transport.invoke<Object?>(
      channel: plutoSettingsChannel,
      method: wifiActiveMethod,
    );
    if (payload == null) {
      return null;
    }
    return WifiConnection.fromMap(stringMap(payload, 'wifi.active'));
  }

  /// Connects to [ssid], creating or reusing a saved profile.
  Future<WifiConnection> connect({
    required String ssid,
    String? passphrase,
    bool remember = true,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    try {
      final Map<String, Object?> arguments = <String, Object?>{
        'ssid': ssid,
        'remember': remember,
        'timeoutMs': timeout.inMilliseconds,
      };
      final String? localPassphrase = passphrase;
      if (localPassphrase != null) {
        arguments['passphrase'] = localPassphrase;
      }
      final Object? payload = await _transport.invoke<Object?>(
        channel: plutoSettingsChannel,
        method: wifiConnectMethod,
        arguments: arguments,
      );
      return WifiConnection.fromMap(stringMap(payload, 'wifi.connect'));
    } on PlutoPlatformException catch (error) {
      if (error.code.startsWith('wifi.')) {
        throw WifiConnectException(
          _connectFailureFromCode(error.code),
          ssid: ssid,
          cause: error,
        );
      }
      rethrow;
    }
  }

  /// Disconnects the active Wi-Fi connection.
  Future<void> disconnect() async {
    await invokeVoid(_transport, wifiDisconnectMethod);
  }

  /// Deletes the saved profile for [ssid].
  Future<void> forgetNetwork({required String ssid}) async {
    await invokeVoid(
      _transport,
      wifiForgetMethod,
      arguments: <String, Object?>{'ssid': ssid},
    );
  }

  /// Saved network profiles.
  Future<List<KnownWifiNetwork>> knownNetworks() async {
    final Object? payload = await _transport.invoke<Object?>(
      channel: plutoSettingsChannel,
      method: wifiKnownMethod,
    );
    return <KnownWifiNetwork>[
      for (final Object? item in objectList(payload, 'wifi.known'))
        KnownWifiNetwork.fromMap(stringMap(item, 'known wifi network')),
    ];
  }
}

/// Security type of a Wi-Fi network.
enum WifiSecurity {
  /// Open network.
  open,

  /// WEP-protected network.
  wep,

  /// WPA-PSK network.
  wpaPsk,

  /// WPA Enterprise network.
  wpaEap,

  /// WPA3 SAE network.
  sae,

  /// Unknown security type.
  unknown;

  /// Parses a protocol security name.
  static WifiSecurity parse(String value) {
    for (final WifiSecurity security in WifiSecurity.values) {
      if (security.name == value) {
        return security;
      }
    }
    return WifiSecurity.unknown;
  }
}

/// A visible Wi-Fi network from a scan.
final class WifiNetwork {
  /// Creates a visible network.
  const WifiNetwork({
    required this.ssid,
    required this.signal,
    required this.security,
    required this.isKnown,
    required this.isActive,
  });

  /// Creates a visible network from a protocol map.
  factory WifiNetwork.fromMap(Map<String, Object?> map) {
    requireExactKeys(
      map,
      'wifi network',
      required: const <String>{
        'ssid',
        'signal',
        'security',
        'isKnown',
        'isActive',
      },
    );
    return WifiNetwork(
      ssid: stringAt(map, 'ssid'),
      signal: doubleAt(map, 'signal'),
      security: WifiSecurity.parse(stringAt(map, 'security')),
      isKnown: boolAt(map, 'isKnown'),
      isActive: boolAt(map, 'isActive'),
    );
  }

  /// Network name.
  final String ssid;

  /// Signal strength from 0 to 1.
  final double signal;

  /// Security type.
  final WifiSecurity security;

  /// Whether a saved profile exists.
  final bool isKnown;

  /// Whether this is the active network.
  final bool isActive;
}

/// A saved Wi-Fi profile.
final class KnownWifiNetwork {
  /// Creates a saved network profile.
  const KnownWifiNetwork({required this.ssid, required this.security});

  /// Creates a saved network profile from a protocol map.
  factory KnownWifiNetwork.fromMap(Map<String, Object?> map) {
    requireExactKeys(
      map,
      'known wifi network',
      required: const <String>{'ssid', 'security'},
    );
    return KnownWifiNetwork(
      ssid: stringAt(map, 'ssid'),
      security: WifiSecurity.parse(stringAt(map, 'security')),
    );
  }

  /// Network name.
  final String ssid;

  /// Security type.
  final WifiSecurity security;
}

/// An established Wi-Fi connection.
final class WifiConnection {
  /// Creates an established connection.
  const WifiConnection({
    required this.ssid,
    required this.ipAddress,
    required this.signal,
  });

  /// Creates an established connection from a protocol map.
  factory WifiConnection.fromMap(Map<String, Object?> map) {
    requireExactKeys(
      map,
      'wifi connection',
      required: const <String>{'ssid', 'ipAddress', 'signal'},
    );
    return WifiConnection(
      ssid: stringAt(map, 'ssid'),
      ipAddress: stringAt(map, 'ipAddress'),
      signal: doubleAt(map, 'signal'),
    );
  }

  /// Network name.
  final String ssid;

  /// IPv4 address on `wlan0`.
  final String ipAddress;

  /// Signal strength from 0 to 1.
  final double signal;
}

/// Connection state machine.
sealed class WifiStatus {
  const WifiStatus();

  /// Creates a status value from a protocol map.
  factory WifiStatus.fromMap(Map<String, Object?> map) {
    switch (stringAt(map, 'status')) {
      case 'disabled':
        return const WifiDisabled();
      case 'disconnected':
        return const WifiDisconnected();
      case 'connecting':
        return WifiConnecting(ssid: stringAt(map, 'ssid'));
      case 'connected':
        return WifiConnected(
          connection: WifiConnection.fromMap(
            stringMap(map['connection'], 'wifi connection'),
          ),
        );
      default:
        throw const FormatException('Unknown Wi-Fi status.');
    }
  }
}

/// Wi-Fi radio disabled.
final class WifiDisabled extends WifiStatus {
  /// Creates a disabled status.
  const WifiDisabled();
}

/// Wi-Fi disconnected.
final class WifiDisconnected extends WifiStatus {
  /// Creates a disconnected status.
  const WifiDisconnected();
}

/// Wi-Fi connection attempt in progress.
final class WifiConnecting extends WifiStatus {
  /// Creates a connecting status.
  const WifiConnecting({required this.ssid});

  /// Network name being connected.
  final String ssid;
}

/// Wi-Fi connected.
final class WifiConnected extends WifiStatus {
  /// Creates a connected status.
  const WifiConnected({required this.connection});

  /// Active connection.
  final WifiConnection connection;
}

/// Why a Wi-Fi connection attempt failed.
enum WifiConnectFailure {
  /// Network was not found.
  notFound,

  /// Passphrase was rejected.
  badPassphrase,

  /// Connection timed out.
  timeout,

  /// Radio is disabled.
  radioDisabled,

  /// Unknown failure.
  unknown,
}

/// Typed failure for [WifiSettings.connect].
final class WifiConnectException extends PlutoException {
  /// Creates a typed connection failure.
  WifiConnectException(this.failure, {required String ssid, Object? cause})
    : super('Failed to connect to "$ssid": ${failure.name}', cause: cause);

  /// Failure reason.
  final WifiConnectFailure failure;
}

WifiConnectFailure _connectFailureFromCode(String code) {
  return switch (code) {
    'wifi.not-found' => WifiConnectFailure.notFound,
    'wifi.bad-passphrase' => WifiConnectFailure.badPassphrase,
    'wifi.timeout' => WifiConnectFailure.timeout,
    'wifi.radio-disabled' => WifiConnectFailure.radioDisabled,
    _ => WifiConnectFailure.unknown,
  };
}
