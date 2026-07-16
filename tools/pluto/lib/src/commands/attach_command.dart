import '../run/device_operations.dart';
import '../ssh/device_transport.dart';
import 'base_command.dart';

/// `pluto attach` command.
final class AttachCommand extends PlutoCommand {
  /// Creates the command.
  AttachCommand(super.environment) {
    addDeviceOption();
    argParser
      ..addOption(
        'app',
        help: 'Running app id. Defaults to the foreground Pluto app.',
      )
      ..addOption(
        'debug-url',
        help: 'Full Dart VM Service URL, including auth token.',
      )
      ..addFlag(
        'forward-ssh',
        negatable: false,
        help: 'Forward the VM service through ssh -L before attaching.',
      );
  }

  @override
  String get name => 'attach';

  @override
  String get description => 'Attach hot reload to an already-running app.';

  @override
  Future<int> run() async {
    return guard(() async {
      final String? url = argResults!['debug-url'] as String?;
      if (url != null && Uri.tryParse(url)?.hasScheme != true) {
        usageException('--debug-url must be an absolute URI.');
      }
      if (url != null) {
        environment.out.writeln(
          'Attach to $url with: flutter attach --debug-url=$url',
        );
        return 0;
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
      final Uri vmUri = await ops.attachApp();
      environment.out.writeln('VM service forwarded to $vmUri');
      environment.out.writeln('Attach with: flutter attach --debug-url=$vmUri');
      return 0;
    });
  }
}
