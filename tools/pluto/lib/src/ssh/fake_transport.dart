import 'dart:typed_data';

import '../process.dart';
import 'device_transport.dart';

/// Function used by [FakeTransport] to answer an exec request.
typedef FakeExecHandler = Future<CommandResult> Function(String command);

/// Function used by [FakeTransport] to answer a binary download request.
typedef FakeDownloadHandler = Future<Uint8List> Function(String remotePath);

/// Uploaded file captured by [FakeTransport].
final class FakeUpload {
  /// Creates an upload record.
  const FakeUpload({
    required this.remotePath,
    required this.bytes,
    required this.executable,
  });

  /// Remote target path.
  final String remotePath;

  /// Uploaded bytes.
  final Uint8List bytes;

  /// Whether executable mode was requested.
  final bool executable;
}

/// In-memory transport for host-only tests.
final class FakeTransport implements DeviceTransport {
  /// Creates a fake transport.
  FakeTransport({
    required this.endpoint,
    this.reachable = true,
    Map<String, CommandResult>? responses,
    this.execHandler,
    this.downloadHandler,
  }) : responses = responses ?? <String, CommandResult>{};

  @override
  final DeviceEndpoint endpoint;

  /// Whether [canConnect] succeeds.
  bool reachable;

  /// Exact command responses.
  final Map<String, CommandResult> responses;

  /// Optional dynamic exec handler.
  final FakeExecHandler? execHandler;

  /// Optional dynamic binary download handler.
  final FakeDownloadHandler? downloadHandler;

  /// Commands executed so far.
  final List<String> commands = <String>[];

  /// Files uploaded so far.
  final List<FakeUpload> uploads = <FakeUpload>[];

  /// Remote paths downloaded by the caller.
  final List<String> downloads = <String>[];

  /// Directory upload requests.
  final List<(String localPath, String remotePath)> directoryUploads =
      <(String, String)>[];

  /// Port forwards started so far.
  final List<FakePortForwardHandle> forwards = <FakePortForwardHandle>[];

  @override
  Future<bool> canConnect({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    return reachable;
  }

  @override
  Future<CommandResult> exec(
    String command, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    commands.add(command);
    if (!reachable) {
      return const CommandResult(exitCode: 255, stderr: 'unreachable');
    }
    if (execHandler != null) {
      return execHandler!(command);
    }
    return responses[command] ?? const CommandResult(exitCode: 0);
  }

  @override
  Future<void> uploadFileBytes({
    required Uint8List bytes,
    required String remotePath,
    bool executable = false,
  }) async {
    uploads.add(
      FakeUpload(
        remotePath: remotePath,
        bytes: Uint8List.fromList(bytes),
        executable: executable,
      ),
    );
  }

  @override
  Future<Uint8List> downloadFileBytes({
    required String remotePath,
    int? expectedBytes,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    downloads.add(remotePath);
    final Uint8List bytes = downloadHandler == null
        ? Uint8List(0)
        : await downloadHandler!(remotePath);
    if (expectedBytes != null && bytes.length != expectedBytes) {
      throw StateError(
        'expected $expectedBytes bytes from $remotePath, got ${bytes.length}',
      );
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> uploadDirectory({
    required String localPath,
    required String remotePath,
  }) async {
    directoryUploads.add((localPath, remotePath));
  }

  @override
  Future<PortForwardHandle> forwardPort({
    required int hostPort,
    required int devicePort,
    RegExp? successPattern,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final FakePortForwardHandle handle = FakePortForwardHandle(
      hostPort: hostPort,
      devicePort: devicePort,
    );
    forwards.add(handle);
    return handle;
  }
}

/// In-memory port forward handle.
final class FakePortForwardHandle implements PortForwardHandle {
  /// Creates a fake forward handle.
  FakePortForwardHandle({required this.hostPort, required this.devicePort});

  @override
  final int hostPort;

  @override
  final int devicePort;

  /// Whether [close] has been called.
  bool isClosed = false;

  @override
  Future<void> close() async {
    isClosed = true;
  }
}
