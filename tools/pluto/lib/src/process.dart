import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A completed process invocation.
final class CommandResult {
  /// Creates a result for a process invocation.
  const CommandResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });

  /// Exit code reported by the process.
  final int exitCode;

  /// Text captured from standard output.
  final String stdout;

  /// Text captured from standard error.
  final String stderr;

  /// Whether [exitCode] is zero.
  bool get isSuccess => exitCode == 0;
}

/// Host-side process and filesystem surface used by testable services.
abstract interface class HostEnvironment {
  /// Returns the absolute executable path found on PATH, or null.
  String? executablePath(String executable);

  /// Runs a host process and captures its text output.
  Future<CommandResult> run(
    List<String> command, {
    Duration timeout = const Duration(seconds: 30),
    Map<String, String> environment = const <String, String>{},
    String? workingDirectory,
  });

  /// Returns true when [path] is an existing regular file.
  bool fileExists(String path);

  /// Returns true when [path] is an existing directory.
  bool directoryExists(String path);

  /// Reads a UTF-8 text file.
  String readTextFile(String path);

  /// Reads a host environment variable.
  String? environmentVariable(String name);

  /// Host operating system identifier from `dart:io`.
  String get operatingSystem;
}

/// Real host environment backed by `dart:io`.
final class ProcessHostEnvironment implements HostEnvironment {
  /// Creates a host environment backed by local processes and files.
  const ProcessHostEnvironment();

  @override
  String? executablePath(String executable) => which(executable);

  @override
  Future<CommandResult> run(
    List<String> command, {
    Duration timeout = const Duration(seconds: 30),
    Map<String, String> environment = const <String, String>{},
    String? workingDirectory,
  }) async {
    if (command.isEmpty) {
      throw ArgumentError.value(command, 'command', 'must not be empty');
    }
    final ProcessResult result = await Process.run(
      command.first,
      command.skip(1).toList(growable: false),
      environment: environment.isEmpty ? null : environment,
      workingDirectory: workingDirectory,
    ).timeout(timeout);
    return CommandResult(
      exitCode: result.exitCode,
      stdout: _stringifyProcessOutput(result.stdout),
      stderr: _stringifyProcessOutput(result.stderr),
    );
  }

  @override
  bool fileExists(String path) => File(path).existsSync();

  @override
  bool directoryExists(String path) => Directory(path).existsSync();

  @override
  String readTextFile(String path) => File(path).readAsStringSync();

  @override
  String? environmentVariable(String name) => Platform.environment[name];

  @override
  String get operatingSystem => Platform.operatingSystem;
}

/// Finds [executable] on PATH.
String? which(String executable, {Map<String, String>? environment}) {
  final String? path = (environment ?? Platform.environment)['PATH'];
  if (path == null || path.isEmpty) {
    return null;
  }
  final List<String> extensions = Platform.isWindows
      ? <String>['.exe', '.bat', '.cmd', '']
      : <String>[''];
  for (final String directory in path.split(Platform.isWindows ? ';' : ':')) {
    if (directory.isEmpty) {
      continue;
    }
    for (final String extension in extensions) {
      final String candidate =
          '$directory${Platform.pathSeparator}'
          '$executable$extension';
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
  }
  return null;
}

String _stringifyProcessOutput(Object? output) {
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
