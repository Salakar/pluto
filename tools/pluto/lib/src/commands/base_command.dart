import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../cli_environment.dart';
import '../errors.dart';
import '../exit_codes.dart';
import '../run/device_operations.dart';
import '../ssh/device_transport.dart';

/// Base class for Pluto commands.
abstract class PlutoCommand extends Command<int> {
  /// Creates a command with shared [environment].
  PlutoCommand(this.environment);

  /// Shared command dependencies.
  final PlutoCliEnvironment environment;

  /// Global `--flutter-sdk`, if provided.
  String? get globalFlutterSdk {
    final ArgResults? results = globalResults;
    if (results == null) {
      return null;
    }
    return results['flutter-sdk'] as String?;
  }

  /// Global `--machine`.
  bool get globalMachine {
    final ArgResults? results = globalResults;
    return results == null ? false : results['machine'] as bool;
  }

  /// Resolves command-local or global `--device`.
  String? resolveDeviceTarget() {
    final ArgResults? local = argResults;
    if (local != null &&
        local.options.contains('device') &&
        local['device'] != null) {
      return local['device'] as String?;
    }
    final ArgResults? global = globalResults;
    if (global != null && global['device'] != null) {
      return global['device'] as String?;
    }
    return null;
  }

  /// Adds common `--device` flag for after-command usage.
  void addDeviceOption() {
    argParser.addOption(
      'device',
      abbr: 'd',
      help: 'Target device id or [user@]host.',
    );
  }

  /// Converts a device target string into an endpoint.
  DeviceEndpoint? endpointFromTarget(String? target) {
    if (target == null || target.isEmpty) {
      return null;
    }
    if (target == 'usb') {
      return const DeviceEndpoint(id: 'usb', host: '10.11.99.1');
    }
    if (target.contains('@') ||
        RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(target)) {
      return DeviceEndpoint.parse(target, id: target);
    }
    return DeviceEndpoint(id: target, host: target);
  }

  /// Runs [operation] and maps known exceptions to exit codes.
  Future<int> guard(Future<int> Function() operation) async {
    try {
      return await operation();
    } on PlutoException catch (error) {
      environment.err.writeln(error.message);
      if (error.remediation != null) {
        environment.err.writeln('Next step: ${error.remediation}');
      }
      return error.exitCode;
    } on DeviceOperationException catch (error) {
      environment.err.writeln(error.message);
      if (error.detail.isNotEmpty) {
        environment.err.writeln(error.detail);
      }
      return ExitCodes.failure;
    } on UsageException catch (error) {
      environment.err.writeln(error);
      return ExitCodes.usage;
    } on UnimplementedError catch (error) {
      environment.err.writeln(error.message ?? error.toString());
      return ExitCodes.toolBug;
    }
  }
}
