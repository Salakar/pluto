import 'package:args/command_runner.dart';

import 'cli_environment.dart';
import 'runner.dart';

/// Builds the Pluto command dispatcher.
CommandRunner<int> buildCommandRunner({PlutoCliEnvironment? environment}) {
  return PlutoCommandRunner(environment ?? PlutoCliEnvironment.defaults());
}
