import 'dart:typed_data';

import '../process.dart';

/// Connection details for one SSH-reachable device.
final class DeviceEndpoint {
  /// Creates a device endpoint.
  const DeviceEndpoint({
    required this.host,
    this.id = 'usb',
    this.user = 'root',
    this.port = 22,
    this.identityFile,
  });

  /// Device id used by the CLI.
  final String id;

  /// Hostname or IP address.
  final String host;

  /// SSH username.
  final String user;

  /// SSH port.
  final int port;

  /// Optional private key path.
  final String? identityFile;

  /// Parses `[user@]host[:port]` or `[user@][ipv6][:port]`.
  factory DeviceEndpoint.parse(
    String value, {
    String id = 'device',
    int port = 22,
    String? identityFile,
  }) {
    final int separator = value.indexOf('@');
    final String user = separator == -1
        ? 'root'
        : value.substring(0, separator);
    final String address = separator == -1
        ? value
        : value.substring(separator + 1);
    if (user.isEmpty || address.isEmpty) {
      throw FormatException('Invalid SSH device endpoint: $value');
    }

    String host = address;
    int resolvedPort = port;
    if (address.startsWith('[')) {
      final int closingBracket = address.indexOf(']');
      if (closingBracket <= 1) {
        throw FormatException('Invalid SSH device endpoint: $value');
      }
      host = address.substring(1, closingBracket);
      final String suffix = address.substring(closingBracket + 1);
      if (suffix.isNotEmpty) {
        if (!suffix.startsWith(':')) {
          throw FormatException('Invalid SSH device endpoint: $value');
        }
        resolvedPort = _parsePort(suffix.substring(1), value);
      }
    } else if (':'.allMatches(address).length == 1) {
      final int portSeparator = address.lastIndexOf(':');
      host = address.substring(0, portSeparator);
      resolvedPort = _parsePort(address.substring(portSeparator + 1), value);
    }
    if (host.isEmpty) {
      throw FormatException('Invalid SSH device endpoint: $value');
    }

    return DeviceEndpoint(
      id: id,
      user: user,
      host: host,
      port: resolvedPort,
      identityFile: identityFile,
    );
  }

  /// `user@host` as accepted by OpenSSH.
  String get sshTarget => '$user@$host';
}

int _parsePort(String raw, String endpoint) {
  final int? parsed = int.tryParse(raw);
  if (parsed == null || parsed < 1 || parsed > 65535) {
    throw FormatException('Invalid SSH port in device endpoint: $endpoint');
  }
  return parsed;
}

/// Handle for an active port forward.
abstract interface class PortForwardHandle {
  /// Host-side forwarded port.
  int get hostPort;

  /// Device-side target port.
  int get devicePort;

  /// Stops forwarding.
  Future<void> close();
}

/// Transport operations used by Pluto device code.
abstract interface class DeviceTransport {
  /// Device endpoint backing this transport.
  DeviceEndpoint get endpoint;

  /// Executes [command] on the device.
  Future<CommandResult> exec(
    String command, {
    Duration timeout = const Duration(seconds: 30),
  });

  /// Returns true when a simple command can run on the device.
  Future<bool> canConnect({Duration timeout = const Duration(seconds: 2)});

  /// Uploads a single file by content.
  Future<void> uploadFileBytes({
    required Uint8List bytes,
    required String remotePath,
    bool executable = false,
  });

  /// Downloads one remote file without text transcoding.
  Future<Uint8List> downloadFileBytes({
    required String remotePath,
    int? expectedBytes,
    Duration timeout = const Duration(seconds: 30),
  });

  /// Uploads a directory tree.
  Future<void> uploadDirectory({
    required String localPath,
    required String remotePath,
  });

  /// Starts a local SSH port forward.
  Future<PortForwardHandle> forwardPort({
    required int hostPort,
    required int devicePort,
    RegExp? successPattern,
    Duration timeout = const Duration(seconds: 5),
  });
}

/// Creates transports for endpoints.
typedef TransportFactory = DeviceTransport Function(DeviceEndpoint endpoint);
