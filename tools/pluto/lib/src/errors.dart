import 'exit_codes.dart';

/// Base class for failures that are meant to be shown to CLI users.
sealed class PlutoException implements Exception {
  /// Creates a user-facing Pluto failure.
  const PlutoException({
    required this.message,
    this.remediation,
    this.exitCode = ExitCodes.failure,
  });

  /// What failed.
  final String message;

  /// Concrete next step, when one is known.
  final String? remediation;

  /// Stable process exit code for this failure.
  final int exitCode;

  @override
  String toString() {
    final String remediationText = remediation == null
        ? ''
        : '\nNext step: $remediation';
    return '$message$remediationText';
  }
}

/// Host-side CLI configuration is invalid or unsafe for the requested mode.
final class CliConfigurationException extends PlutoException {
  /// Creates a CLI configuration failure.
  const CliConfigurationException({required super.message, super.remediation})
    : super(exitCode: ExitCodes.usage);
}

/// A device could not be reached over the configured transport.
final class DeviceUnreachableException extends PlutoException {
  /// Creates a device reachability failure.
  const DeviceUnreachableException({required super.message, super.remediation})
    : super(exitCode: ExitCodes.deviceUnreachable);
}

/// A firmware build is outside the tested support matrix.
final class UnsupportedFirmwareException extends PlutoException {
  /// Creates an unsupported-firmware failure.
  const UnsupportedFirmwareException({
    required super.message,
    super.remediation,
  }) : super(exitCode: ExitCodes.provisioningRefused);
}

/// A cached or packaged artifact failed verification.
final class ArtifactVerificationException extends PlutoException {
  /// Creates an artifact verification failure.
  const ArtifactVerificationException({
    required super.message,
    super.remediation,
  });
}
