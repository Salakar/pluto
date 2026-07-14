import '../ssh/device_transport.dart';
import 'device_profile.dart';

/// Runtime backend selected from trusted reMarkable hardware identity.
enum PlutoRuntimeBackend {
  /// Pluto owns the display and boot session directly.
  direct,

  /// Pluto runs inside the stock display session through the cooperative path.
  cooperative,
}

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
    this.xoviAvailable = false,
    this.appLoadAvailable = false,
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

  /// Whether the xovi runtime path was found.
  final bool xoviAvailable;

  /// Whether the AppLoad extension path was found.
  final bool appLoadAvailable;

  /// Backend required by the normalized hardware model, or `null` when the
  /// model is not recognized.
  ///
  /// A write-authorizing caller must obtain [model] from a strict device probe
  /// that disables hostname fallback before using this value.
  PlutoRuntimeBackend? get runtimeBackend => switch (profile?.displayDriver) {
    NativeDisplayDriverKind.gallery3Drm => PlutoRuntimeBackend.direct,
    NativeDisplayDriverKind.mxcfbEpdc ||
    NativeDisplayDriverKind.lcdifTcon => PlutoRuntimeBackend.cooperative,
    _ => null,
  };

  /// Build target selected automatically by device-aware commands.
  String? get buildTarget => profile?.targetSlice.wireName;

  /// Build modes supported by this device's installed runtime family.
  List<String> get buildModes => profile?.buildModes ?? const <String>[];

  /// User-visible operations supported through the common Pluto CLI.
  List<String> get capabilities => runtimeBackend == null
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
