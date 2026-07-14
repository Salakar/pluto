import 'package:args/command_runner.dart';

import 'cli_environment.dart';
import 'commands/attach_command.dart';
import 'commands/build_command.dart';
import 'commands/cleanup_command.dart';
import 'commands/devices_command.dart';
import 'commands/doctor_command.dart';
import 'commands/install_command.dart';
import 'commands/logs_command.dart';
import 'commands/provision_command.dart';
import 'commands/run_command.dart';
import 'commands/screenshot_command.dart';
import 'commands/uninstall_command.dart';

/// Pluto command runner with global options.
final class PlutoCommandRunner extends CommandRunner<int> {
  /// Creates the command runner.
  PlutoCommandRunner(this.environment)
    : super('pluto', 'Tools for building Pluto apps.') {
    argParser
      ..addOption(
        'device',
        abbr: 'd',
        help:
            'Target device id or host. Commands also accept this flag after '
            'the command name.',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Print verbose diagnostics.',
      )
      ..addFlag(
        'machine',
        negatable: false,
        help: 'Emit machine-readable JSON where supported.',
      )
      ..addOption('flutter-sdk', help: 'Explicit Flutter SDK root.')
      ..addFlag('no-color', negatable: false, help: 'Disable ANSI styling.');
    addCommand(DoctorCommand(environment));
    addCommand(DevicesCommand(environment));
    addCommand(RunCommand(environment));
    addCommand(AttachCommand(environment));
    addCommand(BuildCommand(environment));
    addCommand(InstallCommand(environment));
    addCommand(ProvisionCommand(environment));
    addCommand(UninstallCommand(environment));
    addCommand(ScreenshotCommand(environment));
    addCommand(LogsCommand(environment));
    addCommand(CleanupCommand(environment));
  }

  /// Shared CLI dependencies.
  final PlutoCliEnvironment environment;
}
