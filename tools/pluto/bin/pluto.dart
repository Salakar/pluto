import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:pluto_cli/src/commands.dart';
import 'package:pluto_cli/src/errors.dart';
import 'package:pluto_cli/src/exit_codes.dart';

/// Runs the Pluto command line tool.
Future<void> main(List<String> arguments) async {
  try {
    final int? result = await buildCommandRunner().run(arguments);
    exitCode = result ?? ExitCodes.ok;
  } on UsageException catch (error) {
    stderr.writeln(error);
    exitCode = ExitCodes.usage;
  } on PlutoException catch (error) {
    stderr.writeln(error.message);
    if (error.remediation != null) {
      stderr.writeln('Next step: ${error.remediation}');
    }
    exitCode = error.exitCode;
  }
}
