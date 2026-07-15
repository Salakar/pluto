import '../ssh/device_transport.dart';
import 'device_profile.dart';

/// A discovered reMarkable device.
final class RemarkableDevice {
  /// Creates a device model.
  const RemarkableDevice({
    required this.id,
    required this.name,
    required this.endpoint,
    this.profile,
    this.architecture,
    this.firmwareBuild,
    this.firmwareVersion,
    this.provisioned = false,
  });

  /// CLI-visible id.
  final String id;

  /// Human-readable name.
  final String name;

  /// SSH endpoint for the device.
  final DeviceEndpoint endpoint;

  /// Generated hardware profile selected from immutable evidence.
  final DeviceProfile? profile;

  /// Hardware codename, for example `chiappa`.
  String? get model => profile?.codename;

  /// Kernel machine architecture, for example `aarch64` or `armv7l`.
  final String? architecture;

  /// Firmware build read from `/etc/version`.
  final String? firmwareBuild;

  /// Semantic release version read from the firmware release metadata.
  final String? firmwareVersion;

  /// Panel geometry, absent when immutable identity did not match.
  PanelProfile? get panel => profile?.panel;

  /// Whether Pluto runtime markers were found.
  final bool provisioned;

  /// Whether the matched profile has passed its native-session gate.
  bool get nativeRuntimeEnabled =>
      profile?.runtime.nativeSessionEnabled ?? false;

  /// Build target selected automatically by device-aware commands.
  String? get buildTarget => profile?.targetSlice.wireName;

  /// Build modes supported by this device's installed runtime family.
  List<String> get buildModes => profile?.buildModes ?? const <String>[];

  /// User-visible operations supported through the common Pluto CLI.
  List<String> get capabilities => !nativeRuntimeEnabled
      ? const <String>[]
      : <String>[
          'build',
          'provision',
          'install',
          'run',
          'logs',
          'screenshot',
          'uninstall',
          'pen',
          'touch',
          if (profile!.hasCapability('hot-reload')) 'hot-reload',
        ];

  /// Summary used by `pluto devices`.
  String formatSummary() {
    final String modelText = model == null ? 'unknown model' : model!;
    final String firmwareText = firmwareVersion == null
        ? firmwareBuild == null
              ? 'unknown fw'
              : firmwareBuild!
        : firmwareBuild == null
        ? firmwareVersion!
        : '${firmwareVersion!} ($firmwareBuild)';
    final String state = provisioned ? 'provisioned' : 'unprovisioned';
    final String support = buildTarget == null
        ? 'unsupported target'
        : '$buildTarget ${buildModes.join('/')}';
    return '$id  $name  $modelText  fw $firmwareText  '
        '${endpoint.user}@${endpoint.host}:${endpoint.port}  $state  $support';
  }
}
