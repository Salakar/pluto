import 'capability.dart';

/// Base type for all failures surfaced by `pluto_*` packages.
base class PlutoException implements Exception {
  /// Creates a Pluto exception with a human-readable [message].
  const PlutoException(this.message, {this.cause});

  /// Human-readable, actionable description.
  final String message;

  /// Underlying error, if any.
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

/// The device or embedder does not support the requested feature.
final class PlutoUnsupportedException extends PlutoException {
  /// Creates an exception for an unsupported [capability].
  PlutoUnsupportedException(this.capability, {String? message})
    : super(message ?? 'Capability not supported: ${capability.name}');

  /// The missing capability.
  final Capability capability;
}

/// The operation was rejected by system policy.
final class PlutoPermissionException extends PlutoException {
  /// Creates a permission failure.
  const PlutoPermissionException(super.message, {super.cause});
}

/// The embedder and Dart package protocol versions are incompatible.
final class PlutoProtocolException extends PlutoException {
  /// Creates a protocol-version mismatch failure.
  PlutoProtocolException({
    required this.clientProtocol,
    required this.embedderProtocol,
  }) : super(
         'Pluto protocol mismatch: package speaks $clientProtocol, '
         'embedder speaks $embedderProtocol. Re-run `pluto provision`.',
       );

  /// Protocol version spoken by the Dart package.
  final int clientProtocol;

  /// Protocol version spoken by the embedder.
  final int embedderProtocol;
}

/// A platform-side I/O or state error.
final class PlutoPlatformException extends PlutoException {
  /// Creates a platform failure with a stable machine-readable [code].
  const PlutoPlatformException(
    super.message, {
    required this.code,
    super.cause,
  });

  /// Stable machine-readable code from the wire error envelope.
  final String code;
}

/// No Pluto embedder is servicing the platform channels.
final class PlutoNotAttachedException extends PlutoException {
  /// Creates a not-attached failure.
  PlutoNotAttachedException()
    : super(
        'No Pluto embedder answered. Run on a provisioned device via '
        '`pluto run`, in host preview, or inject a FakePlutoTransport '
        'in tests.',
      );
}
