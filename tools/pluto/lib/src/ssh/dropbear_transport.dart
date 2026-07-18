import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../errors.dart';
import '../process.dart';
import 'device_transport.dart';

/// Host environment for the tar half of a directory upload.
///
/// macOS tar otherwise synthesizes AppleDouble `._*` entries for extended
/// attributes. Those files are host metadata, not part of a Pluto payload.
Map<String, String> directoryUploadTarEnvironment(
  Map<String, String> hostEnvironment,
) => <String, String>{...hostEnvironment, 'COPYFILE_DISABLE': '1'};

/// OpenSSH-client transport tuned for Dropbear devices.
final class DropbearTransport implements DeviceTransport {
  /// Creates a Dropbear transport.
  DropbearTransport({
    required this.endpoint,
    this.controlPath = '~/.pluto/cm-%r@%h:%p',
    this.preferScp = false,
    this.sshExecutable = 'ssh',
    this.acceptanceStrict = false,
  }) {
    if (acceptanceStrict && !File(sshExecutable).isAbsolute) {
      throw ArgumentError.value(
        sshExecutable,
        'sshExecutable',
        'must be absolute in acceptance-strict mode',
      );
    }
  }

  @override
  final DeviceEndpoint endpoint;

  /// OpenSSH ControlPath used for multiplexing.
  final String controlPath;

  /// Whether single-file uploads should try scp before `cat >`.
  final bool preferScp;

  /// OpenSSH client executable.
  ///
  /// Normal interactive CLI operation intentionally retains PATH lookup.
  /// Acceptance mode pins this to an absolute executable.
  final String sshExecutable;

  /// Whether to isolate SSH from ambient configuration and multiplexing.
  final bool acceptanceStrict;

  @override
  Future<bool> canConnect({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final CommandResult result = await exec('true', timeout: timeout);
      return result.isSuccess;
    } on DeviceUnreachableException {
      return false;
    }
  }

  @override
  Future<CommandResult> exec(
    String command, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final List<String> args = <String>[
      ..._baseSshArgs(timeout),
      endpoint.sshTarget,
      command,
    ];
    try {
      final ProcessResult result = await Process.run(
        sshExecutable,
        args,
      ).timeout(timeout + const Duration(seconds: 1));
      return CommandResult(
        exitCode: result.exitCode,
        stdout: _stringify(result.stdout),
        stderr: _stringify(result.stderr),
      );
    } on TimeoutException catch (error) {
      throw DeviceUnreachableException(
        message: 'Timed out running SSH command on ${endpoint.host}.',
        remediation: 'Check USB networking and key auth, then retry.',
      ).withCause(error);
    } on ProcessException catch (error) {
      throw DeviceUnreachableException(
        message: 'Could not start ssh: ${error.message}',
        remediation: 'Install OpenSSH and make sure `ssh` is on PATH.',
      );
    }
  }

  @override
  Future<void> uploadFileBytes({
    required Uint8List bytes,
    required String remotePath,
    bool executable = false,
  }) async {
    if (preferScp && !acceptanceStrict) {
      final bool uploaded = await _tryScpUpload(
        bytes: bytes,
        remotePath: remotePath,
      );
      if (uploaded) {
        if (executable) {
          await exec('chmod +x ${shellQuote(remotePath)}');
        }
        return;
      }
    }
    await _uploadWithCat(
      bytes: bytes,
      remotePath: remotePath,
      executable: executable,
    );
  }

  @override
  Future<Uint8List> downloadFileBytes({
    required String remotePath,
    int? expectedBytes,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (expectedBytes != null && expectedBytes < 0) {
      throw ArgumentError.value(expectedBytes, 'expectedBytes');
    }
    try {
      final ProcessResult result = await Process.run(
        sshExecutable,
        <String>[
          ..._baseSshArgs(timeout),
          endpoint.sshTarget,
          'cat ${shellQuote(remotePath)}',
        ],
        stdoutEncoding: null,
        stderrEncoding: utf8,
      ).timeout(timeout + const Duration(seconds: 1));
      final Object? stdout = result.stdout;
      final Uint8List bytes = stdout is Uint8List
          ? stdout
          : Uint8List.fromList((stdout as List<int>?) ?? const <int>[]);
      if (result.exitCode != 0 ||
          (expectedBytes != null && bytes.length != expectedBytes)) {
        throw DeviceUnreachableException(
          message: 'Download from ${endpoint.host}:$remotePath failed.',
          remediation: result.stderr.toString().trim().isEmpty
              ? expectedBytes == null
                    ? null
                    : 'Expected $expectedBytes bytes, received ${bytes.length}.'
              : result.stderr.toString().trim(),
        );
      }
      return bytes;
    } on TimeoutException catch (error) {
      throw DeviceUnreachableException(
        message: 'Timed out downloading from ${endpoint.host}.',
        remediation: 'Check USB networking and retry the transfer.',
      ).withCause(error);
    } on ProcessException catch (error) {
      throw DeviceUnreachableException(
        message: 'Could not start ssh: ${error.message}',
        remediation: 'Install OpenSSH and make sure `ssh` is on PATH.',
      );
    }
  }

  @override
  Future<void> uploadDirectory({
    required String localPath,
    required String remotePath,
  }) async {
    final Process tar = await Process.start('tar', <String>[
      '-C',
      localPath,
      '-cf',
      '-',
      '.',
    ], environment: directoryUploadTarEnvironment(Platform.environment));
    final Process ssh = await Process.start(sshExecutable, <String>[
      ..._baseSshArgs(const Duration(seconds: 30)),
      endpoint.sshTarget,
      'mkdir -p ${shellQuote(remotePath)} && '
          'tar -C ${shellQuote(remotePath)} -xf -',
    ]);
    unawaited(tar.stderr.drain<void>());
    unawaited(ssh.stderr.drain<void>());
    await tar.stdout.pipe(ssh.stdin);
    final int tarExit = await tar.exitCode;
    final int sshExit = await ssh.exitCode;
    if (tarExit != 0 || sshExit != 0) {
      throw DeviceUnreachableException(
        message: 'Directory upload failed for ${endpoint.host}.',
        remediation: 'Run `pluto doctor --probe-usb` for transport details.',
      );
    }
  }

  @override
  Future<PortForwardHandle> forwardPort({
    required int hostPort,
    required int devicePort,
    RegExp? successPattern,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final Process process = await Process.start(sshExecutable, <String>[
      ..._baseSshArgs(timeout),
      '-o',
      'ExitOnForwardFailure=yes',
      '-N',
      '-L',
      '127.0.0.1:$hostPort:127.0.0.1:$devicePort',
      endpoint.sshTarget,
    ]);
    final Completer<void> ready = Completer<void>();
    final StringBuffer output = StringBuffer();

    void observeLine(String line) {
      output.writeln(line);
      if (successPattern != null &&
          successPattern.hasMatch(line) &&
          !ready.isCompleted) {
        ready.complete();
      }
    }

    final StreamSubscription<String> stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(observeLine);
    final StreamSubscription<String> stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(observeLine);

    if (successPattern == null) {
      Timer(const Duration(milliseconds: 350), () {
        if (!ready.isCompleted) {
          ready.complete();
        }
      });
    }

    try {
      await ready.future.timeout(timeout);
    } on TimeoutException {
      process.kill();
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      throw DeviceUnreachableException(
        message: 'SSH port forward did not become ready.',
        remediation: output.isEmpty ? null : output.toString().trim(),
      );
    }
    return _SshPortForwardHandle(
      hostPort: hostPort,
      devicePort: devicePort,
      process: process,
      stdoutSubscription: stdoutSubscription,
      stderrSubscription: stderrSubscription,
    );
  }

  List<String> _baseSshArgs(Duration timeout) {
    if (acceptanceStrict) {
      return <String>[
        '-F',
        '/dev/null',
        '-p',
        endpoint.port.toString(),
        '-o',
        'BatchMode=yes',
        '-o',
        'ConnectTimeout=${timeout.inSeconds.clamp(1, 60)}',
        '-o',
        'StrictHostKeyChecking=yes',
        '-o',
        'ProxyCommand=none',
        '-o',
        'CanonicalizeHostname=no',
        '-o',
        'ControlMaster=no',
        '-o',
        'ControlPath=none',
        '-o',
        'ControlPersist=no',
        if (endpoint.identityFile != null) ...<String>[
          '-i',
          endpoint.identityFile!,
        ],
      ];
    }
    return <String>[
      '-p',
      endpoint.port.toString(),
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=${timeout.inSeconds.clamp(1, 60)}',
      '-o',
      'StrictHostKeyChecking=accept-new',
      '-o',
      'ControlMaster=auto',
      '-o',
      'ControlPath=$controlPath',
      '-o',
      'ControlPersist=60',
      if (endpoint.identityFile != null) ...<String>[
        '-i',
        endpoint.identityFile!,
      ],
    ];
  }

  Future<bool> _tryScpUpload({
    required Uint8List bytes,
    required String remotePath,
  }) async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'pluto-scp-',
    );
    final File tempFile = File('${tempDir.path}${Platform.pathSeparator}file');
    try {
      await tempFile.writeAsBytes(bytes);
      final ProcessResult result = await Process.run('scp', <String>[
        '-P',
        endpoint.port.toString(),
        if (endpoint.identityFile != null) ...<String>[
          '-i',
          endpoint.identityFile!,
        ],
        tempFile.path,
        '${endpoint.sshTarget}:${shellQuote(remotePath)}',
      ]);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    } finally {
      await tempDir.delete(recursive: true);
    }
  }

  Future<void> _uploadWithCat({
    required Uint8List bytes,
    required String remotePath,
    required bool executable,
  }) async {
    final String parent = remoteDirname(remotePath);
    final Process process = await Process.start(sshExecutable, <String>[
      ..._baseSshArgs(const Duration(seconds: 30)),
      endpoint.sshTarget,
      'mkdir -p ${shellQuote(parent)} && cat > ${shellQuote(remotePath)}'
          '${executable ? ' && chmod +x ${shellQuote(remotePath)}' : ''}',
    ]);
    process.stdin.add(bytes);
    await process.stdin.close();
    final String stderrText = await utf8.decodeStream(process.stderr);
    unawaited(process.stdout.drain<void>());
    final int exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw DeviceUnreachableException(
        message: 'Upload to ${endpoint.host}:$remotePath failed.',
        remediation: stderrText.trim().isEmpty ? null : stderrText.trim(),
      );
    }
  }
}

/// Quotes a string for a POSIX shell command.
String shellQuote(String value) {
  return "'${value.replaceAll("'", "'\"'\"'")}'";
}

/// Returns the remote parent directory for a POSIX path.
String remoteDirname(String path) {
  final int index = path.lastIndexOf('/');
  if (index <= 0) {
    return '.';
  }
  return path.substring(0, index);
}

String _stringify(Object? output) {
  if (output == null) {
    return '';
  }
  if (output is String) {
    return output;
  }
  if (output is List<int>) {
    return utf8.decode(output);
  }
  return output.toString();
}

final class _SshPortForwardHandle implements PortForwardHandle {
  _SshPortForwardHandle({
    required this.hostPort,
    required this.devicePort,
    required this.process,
    required this.stdoutSubscription,
    required this.stderrSubscription,
  });

  @override
  final int hostPort;

  @override
  final int devicePort;

  final Process process;
  final StreamSubscription<String> stdoutSubscription;
  final StreamSubscription<String> stderrSubscription;

  @override
  Future<void> close() async {
    process.kill();
    await stdoutSubscription.cancel();
    await stderrSubscription.cancel();
  }
}

extension on DeviceUnreachableException {
  DeviceUnreachableException withCause(Object error) =>
      DeviceUnreachableException(
        message: '$message (${error.runtimeType})',
        remediation: remediation,
      );
}
