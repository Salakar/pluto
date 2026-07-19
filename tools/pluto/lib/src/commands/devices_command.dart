import 'dart:convert';

import '../device/remarkable_device.dart';
import '../exit_codes.dart';
import 'base_command.dart';

/// `pluto devices` command.
final class DevicesCommand extends PlutoCommand {
  /// Creates the command.
  DevicesCommand(super.environment) {
    addDeviceOption();
    argParser
      ..addFlag('json', negatable: false, help: 'Emit devices as JSON.')
      ..addFlag(
        'probe',
        negatable: false,
        help: 'Read model, firmware, and runtime markers over SSH.',
      )
      ..addOption(
        'host',
        help: 'Probe an explicit host instead of the USB default.',
      )
      ..addOption('user', defaultsTo: 'root', help: 'SSH user for --host.');
  }

  @override
  String get name => 'devices';

  @override
  String get description => 'List reachable reMarkable devices.';

  @override
  Future<int> run() async {
    return guard(() async {
      final String? host = argResults!['host'] as String?;
      final String? target = resolveDeviceTarget();
      final List<RemarkableDevice> devices = await environment.deviceDiscovery
          .discover(
            probeDetails: argResults!['probe'] as bool,
            endpoint: host == null
                ? endpointFromTarget(target)
                : endpointFromTarget('${argResults!['user']}@$host'),
          );
      if (argResults!['json'] as bool || globalMachine) {
        environment.out.writeln(
          const JsonEncoder.withIndent('  ').convert(
            devices
                .map(
                  (RemarkableDevice device) => <String, Object?>{
                    'id': device.id,
                    'name': device.name,
                    'host': device.endpoint.host,
                    'user': device.endpoint.user,
                    'port': device.endpoint.port,
                    'model': device.model,
                    'architecture': device.architecture,
                    'kernelRelease': device.kernelRelease,
                    'firmwareBuild': device.firmwareBuild,
                    'firmwareVersion': device.firmwareVersion,
                    'target': device.buildTarget,
                    'buildModes': device.buildModes,
                    'capabilities': device.capabilities,
                    'provisioned': device.provisioned,
                    'nativeRuntimeEnabled': device.nativeRuntimeEnabled,
                  },
                )
                .toList(growable: false),
          ),
        );
        return ExitCodes.ok;
      }
      if (devices.isEmpty) {
        environment.out.writeln('No reachable reMarkable devices.');
        return ExitCodes.ok;
      }
      environment.out.writeln('${devices.length} connected device(s):');
      for (final RemarkableDevice device in devices) {
        environment.out.writeln(device.formatSummary());
      }
      return ExitCodes.ok;
    });
  }
}
