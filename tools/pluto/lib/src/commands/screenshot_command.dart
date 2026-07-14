import 'dart:io';
import 'dart:typed_data';

import '../run/device_operations.dart';
import '../ssh/device_transport.dart';
import 'base_command.dart';

/// `pluto screenshot` command.
final class ScreenshotCommand extends PlutoCommand {
  /// Creates the command.
  ScreenshotCommand(super.environment) {
    addDeviceOption();
    argParser
      ..addOption(
        'output',
        abbr: 'o',
        defaultsTo: 'shot.png',
        help: 'Output PNG path.',
      )
      ..addOption(
        'surface',
        allowed: <String>['logical', 'post-dither'],
        defaultsTo: 'logical',
        help: 'Renderer surface to capture.',
      )
      ..addOption(
        'app',
        help: 'Running app id. Defaults to the foreground surface.',
      );
  }

  @override
  String get name => 'screenshot';

  @override
  String get description => 'Capture the current Pluto surface as PNG.';

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
      final Uint8List bytes = await ops.screenshot(
        appId: argResults!['app'] as String?,
        surface: argResults!['surface'] as String,
      );
      final String output = argResults!['output'] as String;
      File(output).writeAsBytesSync(bytes);
      environment.out.writeln('Saved ${bytes.length} bytes to $output');
      return 0;
    });
  }
}
