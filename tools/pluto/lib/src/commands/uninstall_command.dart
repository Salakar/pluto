import '../run/device_operations.dart';
import '../ssh/device_transport.dart';
import 'base_command.dart';

/// `pluto uninstall` command.
final class UninstallCommand extends PlutoCommand {
  /// Creates the command.
  UninstallCommand(super.environment) {
    addDeviceOption();
    argParser
      ..addFlag(
        'system',
        negatable: false,
        help: 'Remove the full Pluto platform from the device.',
      )
      ..addFlag(
        'purge-data',
        negatable: false,
        help: 'Delete app data immediately.',
      )
      ..addFlag(
        'keep-app-data',
        negatable: false,
        help: 'Keep app data during --system uninstall.',
      )
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Do not ask for interactive confirmation.',
      );
  }

  @override
  String get name => 'uninstall';

  @override
  String get description => 'Uninstall an app or the full Pluto system.';

  @override
  Future<int> run() async {
    return guard(() async {
      final bool system = argResults!['system'] as bool;
      if (!system && argResults!.rest.length != 1) {
        usageException('Provide <app-id>, or pass --system.');
      }
      if (system && argResults!.rest.isNotEmpty) {
        usageException('--system does not take an app id.');
      }
      final DeviceEndpoint? endpoint = endpointFromTarget(
        resolveDeviceTarget(),
      );
      if (endpoint == null) {
        usageException('No device: pass --device <user@host> or connect USB.');
      }
      final LiveDeviceOperations ops = LiveDeviceOperations(
        environment.transportFactory(endpoint),
      );
      final DeviceOperationResult result = system
          ? await ops.uninstallSystem()
          : await ops.uninstallApp(
              argResults!.rest.single,
              purgeData: argResults!['purge-data'] as bool,
            );
      environment.out.writeln(result.message);
      return 0;
    });
  }
}
