import 'dart:async';

import 'package:flutter/services.dart';

import 'capability.dart';
import 'exceptions.dart';
import 'protocol.dart';

/// Low-level transport between the `pluto_*` packages and the embedder.
abstract interface class PlutoTransport {
  /// Invokes [method] on [channel] and returns the decoded result.
  ///
  /// Throws a [PlutoException] subtype on platform failure.
  Future<T?> invoke<T>({
    required String channel,
    required String method,
    Object? arguments,
  });

  /// Subscribes to the event channel [channel] with optional [arguments].
  ///
  /// The returned stream is broadcast and surfaces typed errors when possible.
  Stream<Object?> events({required String channel, Object? arguments});
}

/// Channel-backed production [PlutoTransport].
final class ChannelTransport implements PlutoTransport {
  ChannelTransport._();

  /// Shared channel-backed transport for production package instances.
  static final ChannelTransport shared = ChannelTransport._();

  Future<void>? _handshake;
  PlutoProtocolException? _protocolFailure;

  @override
  Future<T?> invoke<T>({
    required String channel,
    required String method,
    Object? arguments,
  }) async {
    await _ensureHandshake(packageNameForChannel(channel));
    final PlutoProtocolException? protocolFailure = _protocolFailure;
    if (protocolFailure != null) {
      throw protocolFailure;
    }
    try {
      final MethodChannel methodChannel = MethodChannel(channel);
      return await methodChannel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      throw PlutoNotAttachedException();
    } on PlatformException catch (error) {
      throw convertPlatformException(error);
    }
  }

  @override
  Stream<Object?> events({required String channel, Object? arguments}) async* {
    await _ensureHandshake(packageNameForChannel(channel));
    final PlutoProtocolException? protocolFailure = _protocolFailure;
    if (protocolFailure != null) {
      throw protocolFailure;
    }
    final EventChannel eventChannel = EventChannel(channel);
    yield* eventChannel
        .receiveBroadcastStream(arguments)
        .map<Object?>((Object? event) => event)
        .handleError((Object error, StackTrace stackTrace) {
          if (error is PlatformException) {
            throw convertPlatformException(error);
          }
          throw PlutoPlatformException(
            'Event channel failed: $error',
            code: 'event',
            cause: error,
          );
        });
  }

  Future<void> _ensureHandshake(String packageName) {
    return _handshake ??= _performHandshake(packageName);
  }

  Future<void> _performHandshake(String packageName) async {
    try {
      final MethodChannel channel = MethodChannel(plutoCoreChannel);
      final Object? response = await channel
          .invokeMethod<Object?>(coreHandshakeMethod, <String, Object?>{
            'clientProtocol': plutoProtocolVersion,
            'package': packageName,
            'packageVersion': plutoPackageVersion,
          });
      final Map<String, Object?> map = _stringMap(response);
      final int embedderProtocol = _intAt(map, 'protocol');
      if (embedderProtocol != plutoProtocolVersion) {
        _protocolFailure = PlutoProtocolException(
          clientProtocol: plutoProtocolVersion,
          embedderProtocol: embedderProtocol,
        );
      }
    } on MissingPluginException {
      throw PlutoNotAttachedException();
    } on PlatformException catch (error) {
      throw convertPlatformException(error);
    }
  }
}

/// Converts a Flutter [PlatformException] into the Pluto exception hierarchy.
PlutoException convertPlatformException(PlatformException error) {
  final String message = error.message ?? error.code;
  switch (error.code) {
    case 'unsupported':
      return PlutoUnsupportedException(
        _capabilityFromDetails(error.details),
        message: message,
      );
    case 'permission-denied':
      return PlutoPermissionException(message, cause: error);
    case 'protocol':
      final Map<String, Object?> details = _stringMap(error.details);
      return PlutoProtocolException(
        clientProtocol: _intAt(details, 'clientProtocol'),
        embedderProtocol: _intAt(details, 'embedderProtocol'),
      );
    case 'invalid-argument':
      return PlutoPlatformException(message, code: error.code, cause: error);
    default:
      return PlutoPlatformException(message, code: error.code, cause: error);
  }
}

/// Returns the package name associated with a Pluto channel.
String packageNameForChannel(String channel) {
  if (channel.startsWith('pluto/device')) {
    return 'pluto_device';
  }
  if (channel.startsWith('pluto/settings')) {
    return 'pluto_settings';
  }
  if (channel.startsWith('pluto/pen')) {
    return 'pluto_pen';
  }
  if (channel.startsWith('pluto/touch')) {
    return 'pluto_touch';
  }
  return 'pluto_core';
}

Capability _capabilityFromDetails(Object? details) {
  if (details is String) {
    for (final Capability capability in Capability.values) {
      if (capability.name == details) {
        return capability;
      }
    }
  }
  return Capability.penSampleRing;
}

Map<String, Object?> _stringMap(Object? value) {
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
  return const <String, Object?>{};
}

int _intAt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is int) {
    return value;
  }
  return 0;
}
