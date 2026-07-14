import '../run/device_operations.dart';
import '../ssh/device_transport.dart';
import 'base_command.dart';

/// `pluto logs` command.
final class LogsCommand extends PlutoCommand {
  /// Creates the command.
  LogsCommand(super.environment) {
    addDeviceOption();
    argParser
      ..addFlag(
        'follow',
        abbr: 'f',
        negatable: false,
        help: 'Follow log output.',
      )
      ..addOption('app', help: 'App id to filter logs.')
      ..addFlag(
        'system',
        negatable: false,
        help: 'Include xochitl, swupdate, and kernel logs.',
      )
      ..addOption(
        'since',
        defaultsTo: '10m',
        help: 'journalctl-compatible time window.',
      )
      ..addFlag('json', negatable: false, help: 'Emit journal fields as JSON.');
  }

  @override
  String get name => 'logs';

  @override
  String get description => 'Stream Pluto and device logs.';

  @override
  Future<int> run() async {
    return guard(() async {
      final DeviceEndpoint? endpoint = endpointFromTarget(
        resolveDeviceTarget(),
      );
      if (endpoint == null) {
        usageException('No device: pass --device <user@host> or connect USB.');
      }
      final LiveDeviceOperations ops = LiveDeviceOperations(
        environment.transportFactory(endpoint),
      );
      if (argResults!['follow'] as bool) {
        usageException(
          'Live follow is not available through this transport yet. Omit '
          '--follow for a target-filtered snapshot.',
        );
      }
      environment.out.write(
        await ops.logs(
          appId: argResults!['app'] as String?,
          includeSystem: argResults!['system'] as bool,
          since: argResults!['since'] as String,
          json: argResults!['json'] as bool,
        ),
      );
      return 0;
    });
  }
}
