import 'package:meta/meta.dart';
import 'package:pluto_core/pluto_core.dart';

import 'device_info.dart';

/// Entry point for device identity and capability queries.
final class PlutoDevice {
  /// Creates an instance backed by [transport].
  @visibleForTesting
  PlutoDevice.withTransport(PlutoTransport transport) : _transport = transport;

  /// The process-wide instance backed by real embedder channels.
  static final PlutoDevice instance = PlutoDevice.withTransport(
    ChannelTransport.shared,
  );

  final PlutoTransport _transport;
  Future<DeviceInfo>? _deviceInfo;
  Future<DeviceCapabilities>? _capabilities;

  /// Fetches the device description.
  Future<DeviceInfo> deviceInfo() {
    return _deviceInfo ??= _readDeviceInfo();
  }

  /// Compatibility alias for earlier scaffold consumers.
  Future<DeviceInfo> info() => deviceInfo();

  /// Fetches the supported capability set.
  Future<DeviceCapabilities> capabilities() {
    return _capabilities ??= _readCapabilities();
  }

  Future<DeviceInfo> _readDeviceInfo() async {
    final Object? payload = await _transport.invoke<Object?>(
      channel: plutoDeviceChannel,
      method: deviceInfoMethod,
    );
    final Map<String, Object?> map = _stringMap(payload, 'deviceInfo');
    final Map<String, Object?> panel = _stringMap(
      map['panel'],
      'deviceInfo.panel',
    );
    final String modelName = _string(map, 'model');
    final String codename = _string(map, 'codename');
    return DeviceInfo(
      model: RemarkableModel.parse(modelName, codename),
      codename: codename,
      firmwareBuild: _string(map, 'firmwareBuild'),
      osVersion: _string(map, 'osVersion'),
      panel: PanelGeometry(
        width: _int(panel, 'width'),
        height: _int(panel, 'height'),
        dpi: _int(panel, 'dpi'),
        pixelFormat: PanelPixelFormat.parse(_string(panel, 'pixelFormat')),
        colorMode: PanelColorMode.parse(_string(panel, 'colorMode')),
      ),
      serialNumber: _optionalString(map, 'serialNumber'),
    );
  }

  Future<DeviceCapabilities> _readCapabilities() async {
    final Object? payload = await _transport.invoke<Object?>(
      channel: plutoDeviceChannel,
      method: deviceCapabilitiesMethod,
    );
    if (payload is! List<Object?>) {
      throw const FormatException('Expected capabilities list.');
    }
    final Set<Capability> capabilities = <Capability>{};
    for (final Object? value in payload) {
      if (value is String) {
        for (final Capability capability in Capability.values) {
          if (capability.name == value) {
            capabilities.add(capability);
          }
        }
      }
    }
    return DeviceCapabilities(capabilities);
  }
}

Map<String, Object?> _stringMap(Object? value, String path) {
  if (value is Map<Object?, Object?>) {
    final Map<String, Object?> result = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final Object? key = entry.key;
      if (key is String) {
        result[key] = entry.value;
      }
    }
    return result;
  }
  throw FormatException('Expected $path to be a map.');
}

String _string(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is String) {
    return value;
  }
  throw FormatException('Expected $key to be a string.');
}

String? _optionalString(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }
  throw FormatException('Expected $key to be a string.');
}

int _int(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is int) {
    return value;
  }
  throw FormatException('Expected $key to be an int.');
}
