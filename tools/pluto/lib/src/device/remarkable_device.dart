import '../ssh/device_transport.dart';

/// Runtime backend selected from trusted reMarkable hardware identity.
enum PlutoRuntimeBackend {
  /// Pluto owns the display and boot session directly.
  direct,

  /// Pluto runs inside the stock display session through the cooperative path.
  cooperative,
}

/// Basic panel geometry discovered from a reMarkable device.
final class PanelInfo {
  /// Creates panel information.
  const PanelInfo({
    required this.width,
    required this.height,
    required this.dpi,
    required this.pixelFormat,
  });

  /// Physical panel width in pixels.
  final int width;

  /// Physical panel height in pixels.
  final int height;

  /// Nominal dots per inch.
  final int dpi;

  /// Pixel format expected by Pluto.
  final String pixelFormat;
}

/// A discovered reMarkable device.
final class RemarkableDevice {
  /// Creates a device model.
  const RemarkableDevice({
    required this.id,
    required this.name,
    required this.endpoint,
    this.model,
    this.architecture,
    this.firmwareBuild,
    this.firmwareVersion,
    this.panel = const PanelInfo(
      width: 954,
      height: 1696,
      dpi: 264,
      pixelFormat: 'rgb565',
    ),
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

  /// Hardware codename, for example `chiappa`.
  final String? model;

  /// Kernel machine architecture, for example `aarch64` or `armv7l`.
  final String? architecture;

  /// Firmware build read from `/etc/version`.
  final String? firmwareBuild;

  /// Semantic release version read from the firmware release metadata.
  final String? firmwareVersion;

  /// Panel geometry.
  final PanelInfo panel;

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
  PlutoRuntimeBackend? get runtimeBackend => switch (model) {
    'chiappa' => PlutoRuntimeBackend.direct,
    'zero-sugar' || 'zero-gravitas' => PlutoRuntimeBackend.cooperative,
    _ => null,
  };

  /// Build target selected automatically by device-aware commands.
  String? get buildTarget => switch (runtimeBackend) {
    PlutoRuntimeBackend.direct => 'linux-arm64',
    PlutoRuntimeBackend.cooperative => 'linux-arm',
    null => null,
  };

  /// Build modes supported by this device's installed runtime family.
  List<String> get buildModes => switch (runtimeBackend) {
    PlutoRuntimeBackend.direct => const <String>['release', 'profile', 'debug'],
    PlutoRuntimeBackend.cooperative => const <String>['release'],
    null => const <String>[],
  };

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
          if (runtimeBackend == PlutoRuntimeBackend.direct) 'hot-reload',
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
