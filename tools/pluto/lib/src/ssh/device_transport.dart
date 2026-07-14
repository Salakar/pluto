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

  /// Parses `[user@]host`.
  factory DeviceEndpoint.parse(
    String value, {
    String id = 'device',
    int port = 22,
    String? identityFile,
  }) {
    final int separator = value.indexOf('@');
    if (separator == -1) {
      return DeviceEndpoint(
        id: id,
        host: value,
        port: port,
        identityFile: identityFile,
      );
    }
    return DeviceEndpoint(
      id: id,
      user: value.substring(0, separator),
      host: value.substring(separator + 1),
      port: port,
      identityFile: identityFile,
    );
  }

  /// `user@host` as accepted by OpenSSH.
  String get sshTarget => '$user@$host';
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
