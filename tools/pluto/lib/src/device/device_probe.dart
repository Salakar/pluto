import '../process.dart';
import '../ssh/device_transport.dart';
import 'device_profile.dart';
import 'remarkable_device.dart';

/// Probes device metadata over SSH.
final class DeviceProbe {
  /// Creates a probe.
  const DeviceProbe({required this.transport});

  /// Device transport used for probe commands.
  final DeviceTransport transport;

  /// Returns a populated device model.
  ///
  Future<RemarkableDevice> probe({
    required String id,
    required String name,
  }) async {
    final String machine =
        await _readFirstSuccessful(const <String>[
          'cat /sys/devices/soc0/machine',
        ]) ??
        '';
    final String deviceTreeModel =
        await _readFirstSuccessful(const <String>[
          'cat /proc/device-tree/model',
        ]) ??
        '';
    final String deviceTreeCompatible =
        await _readFirstSuccessful(const <String>[
          'cat /proc/device-tree/compatible',
        ]) ??
        '';
    final String? architecture = _normalizeArchitecture(
      await _readFirstSuccessful(const <String>['uname -m']),
    );
    final DeviceProfile? profile = matchDeviceProfile(
      DeviceIdentityEvidence(
        machine: machine,
        deviceTreeModel: deviceTreeModel,
        deviceTreeCompatible: deviceTreeCompatible,
        architecture: architecture ?? '',
      ),
    );
    final String? firmware = await _readFirstSuccessful(<String>[
      'cat /etc/version',
    ]);
    final String? firmwareVersion = await _readFirmwareVersion();
    final bool provisioned = await _testPath('/home/root/pluto/VERSION');
    return RemarkableDevice(
      id: id,
      name: name,
      endpoint: transport.endpoint,
      profile: profile,
      architecture: architecture,
      firmwareBuild: firmware?.trim(),
      firmwareVersion: firmwareVersion,
      provisioned: provisioned,
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

  String? _normalizeArchitecture(String? raw) {
    final String normalized = raw?.trim().toLowerCase() ?? '';
    return normalized.isEmpty ? null : normalized;
  }
}
