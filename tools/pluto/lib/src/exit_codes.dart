/// Process exit codes promised by the Pluto CLI.
abstract final class ExitCodes {
  /// Successful command.
  static const int ok = 0;

  /// Generic failure.
  static const int failure = 1;

  /// Command line usage error.
  static const int usage = 64;

  /// App or package was not found.
  static const int notFound = 66;

  /// Device was unreachable.
  static const int deviceUnreachable = 69;

  /// Internal tool error.
  static const int toolBug = 70;

  /// Provisioning was refused.
  static const int provisioningRefused = 73;

  /// Transient failure worth retrying.
  static const int transient = 75;
}
