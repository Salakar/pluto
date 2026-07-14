import '../process.dart';
import '../ssh/device_transport.dart';
import 'remarkable_device.dart';

/// Probes device metadata over SSH.
final class DeviceProbe {
  /// Creates a probe.
  const DeviceProbe({required this.transport});

  /// Device transport used for probe commands.
  final DeviceTransport transport;

  /// Returns a populated device model.
  ///
  /// Set [allowHostnameFallback] to false before any write-authorizing
  /// operation so a mutable hostname cannot impersonate supported hardware.
  Future<RemarkableDevice> probe({
    required String id,
    required String name,
    bool allowHostnameFallback = true,
  }) async {
    const List<String> immutableModelCommands = <String>[
      'cat /sys/devices/soc0/machine',
      'cat /proc/device-tree/model',
      'cat /proc/device-tree/compatible',
    ];
    final List<String> immutableModelValues = await _readAllSuccessful(
      immutableModelCommands,
    );
    final String? model = immutableModelValues.isNotEmpty
        ? _normalizeModel(immutableModelValues.join(' '))
        : allowHostnameFallback
        ? _normalizeModel(
            await _readFirstSuccessful(const <String>['hostname']),
          )
        : null;
    final String? firmware = await _readFirstSuccessful(<String>[
      'cat /etc/version',
    ]);
    final String? firmwareVersion = await _readFirmwareVersion();
    final String? architecture = await _readFirstSuccessful(<String>[
      'uname -m',
    ]);
    final bool provisioned = await _testPath('/home/root/pluto/VERSION');
    final bool xoviAvailable = await _testPath('/home/root/xovi');
    final bool appLoadAvailable = await _testPath(
      '/home/root/xovi/exthome/appload',
    );
    return RemarkableDevice(
      id: id,
      name: name,
      endpoint: transport.endpoint,
      model: model,
      architecture: _normalizeArchitecture(architecture),
      firmwareBuild: firmware?.trim(),
      firmwareVersion: firmwareVersion,
      provisioned: provisioned,
      xoviAvailable: xoviAvailable,
      appLoadAvailable: appLoadAvailable,
    );
  }

  Future<String?> _readFirstSuccessful(List<String> commands) async {
    for (final String command in commands) {
      final CommandResult result = await transport.exec(command);
      if (result.isSuccess && result.stdout.trim().isNotEmpty) {
        return result.stdout.trim();
      }
    }
    return null;
  }

  Future<List<String>> _readAllSuccessful(List<String> commands) async {
    final List<String> values = <String>[];
    for (final String command in commands) {
      final CommandResult result = await transport.exec(command);
      final String value = result.stdout.trim();
      if (result.isSuccess && value.isNotEmpty) {
        values.add(value);
      }
    }
    return values;
  }

  Future<bool> _testPath(String path) async {
    final CommandResult result = await transport.exec('test -e "$path"');
    return result.isSuccess;
  }

  Future<String?> _readFirmwareVersion() async {
    for (final ({String command, String key}) source
        in const <({String command, String key})>[
          (
            command: 'cat /usr/share/remarkable/update.conf',
            key: 'REMARKABLE_RELEASE_VERSION',
          ),
          (command: 'cat /etc/os-release', key: 'IMG_VERSION'),
        ]) {
      final CommandResult result = await transport.exec(source.command);
      if (!result.isSuccess) {
        continue;
      }
      for (final String rawLine in result.stdout.split('\n')) {
        final String line = rawLine.trim();
        final RegExpMatch? match = RegExp(
          '^${source.key}=(.*)\$',
        ).firstMatch(line);
        if (match == null) {
          continue;
        }
        String value = match.group(1)!.trim();
        if (value.length >= 2 &&
            ((value.startsWith('"') && value.endsWith('"')) ||
                (value.startsWith("'") && value.endsWith("'")))) {
          value = value.substring(1, value.length - 1);
        }
        if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(value)) {
          return value;
        }
      }
    }
    return null;
  }

  String? _normalizeModel(String? raw) {
    if (raw == null) {
      return null;
    }
    final String lower = raw.toLowerCase();
    final List<String> matches = <String>[
      if (lower.contains('chiappa')) 'chiappa',
      if (lower.contains('ferrari')) 'ferrari',
      if (lower.contains('tatsu')) 'tatsu',
      if (lower.contains('zero-sugar') ||
          lower.contains('remarkable 2.0') ||
          lower.contains('fsl,imx7d-sdb'))
        'zero-sugar',
      if (lower.contains('zero-gravitas') ||
          lower.contains('remarkable 1.0') ||
          lower.contains('fsl,imx6sl'))
        'zero-gravitas',
    ];
    return matches.length == 1 ? matches.single : null;
  }

  String? _normalizeArchitecture(String? raw) {
    final String normalized = raw?.trim().toLowerCase() ?? '';
    return normalized.isEmpty ? null : normalized;
  }
}
