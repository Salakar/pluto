import 'dart:async';

import 'package:flutter/services.dart';

import 'capability.dart';
import 'exceptions.dart';

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
///
/// Calls use the release's exact channel contract without runtime negotiation.
final class ChannelTransport implements PlutoTransport {
  ChannelTransport._();

  /// Shared channel-backed transport for production package instances.
  static final ChannelTransport shared = ChannelTransport._();

  @override
  Future<T?> invoke<T>({
    required String channel,
    required String method,
    Object? arguments,
  }) async {
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
    case 'invalid-argument':
      return PlutoPlatformException(message, code: error.code, cause: error);
    default:
      return PlutoPlatformException(message, code: error.code, cause: error);
  }
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
