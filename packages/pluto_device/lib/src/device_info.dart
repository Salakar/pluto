import 'dart:ui';

import 'package:pluto_core/pluto_core.dart';

import 'generated/remarkable_models.g.dart';

/// Panel pixel formats Pluto renders to.
enum PanelPixelFormat {
  /// 16-bit RGB565 panel buffer.
  rgb565,

  /// 8-bit grayscale panel buffer.
  gray8;

  /// Parses a protocol pixel-format name.
  static PanelPixelFormat parse(String value) {
    for (final PanelPixelFormat format in PanelPixelFormat.values) {
      if (format.name == value) {
        return format;
      }
    }
    throw FormatException('Unknown panel pixel format: $value');
  }
}

/// Color capability class of the panel.
enum PanelColorMode {
  /// Monochrome Carta-family film.
  monochrome,

  /// E Ink Gallery 3 color film.
  gallery3;

  /// Parses a protocol color-mode name.
  static PanelColorMode parse(String value) {
    for (final PanelColorMode mode in PanelColorMode.values) {
      if (mode.name == value) {
        return mode;
      }
    }
    throw FormatException('Unknown panel color mode: $value');
  }
}

/// Immutable physical panel description.
final class PanelGeometry {
  /// Creates panel geometry.
  const PanelGeometry({
    required this.width,
    required this.height,
    required this.dpi,
    required this.pixelFormat,
    required this.colorMode,
  });

  /// Portrait width in physical pixels.
  final int width;

  /// Portrait height in physical pixels.
  final int height;

  /// Pixel density in dots per inch.
  final int dpi;

  /// Native panel-space pixel format.
  final PanelPixelFormat pixelFormat;

  /// Monochrome vs Gallery 3 color.
  final PanelColorMode colorMode;

  /// Physical size in millimetres, derived from pixels and dpi.
  Size get physicalSizeMm => Size(width * 25.4 / dpi, height * 25.4 / dpi);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PanelGeometry &&
            width == other.width &&
            height == other.height &&
            dpi == other.dpi &&
            pixelFormat == other.pixelFormat &&
            colorMode == other.colorMode;
  }

  @override
  int get hashCode => Object.hash(width, height, dpi, pixelFormat, colorMode);
}

/// Immutable device identity snapshot.
final class DeviceInfo {
  /// Creates a device identity snapshot.
  const DeviceInfo({
    required this.model,
    required this.codename,
    required this.firmwareBuild,
    required this.osVersion,
    required this.panel,
    this.serialNumber,
  });

  /// Exact model accepted by the generated release profile table.
  final RemarkableModel model;

  /// Raw board codename.
  final String codename;

  /// Firmware build tag.
  final String firmwareBuild;

  /// reMarkable OS version.
  final String osVersion;

  /// Physical panel description.
  final PanelGeometry panel;

  /// Device serial, when readable.
  final String? serialNumber;

  /// Whether the panel renders color.
  bool get isColor => panel.colorMode == PanelColorMode.gallery3;

  /// Portrait panel size in physical pixels.
  Size get size => Size(panel.width.toDouble(), panel.height.toDouble());

  /// Panel density in dots per inch.
  int get dpi => panel.dpi;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is DeviceInfo &&
            model == other.model &&
            codename == other.codename &&
            firmwareBuild == other.firmwareBuild &&
            osVersion == other.osVersion &&
            panel == other.panel &&
            serialNumber == other.serialNumber;
  }

  @override
  int get hashCode => Object.hash(
    model,
    codename,
    firmwareBuild,
    osVersion,
    panel,
    serialNumber,
  );
}

/// The set of [Capability] values supported on this device and embedder.
final class DeviceCapabilities {
  /// Creates an immutable capability set.
  DeviceCapabilities(Iterable<Capability> supported)
    : _supported = Set<Capability>.unmodifiable(Set<Capability>.of(supported));

  final Set<Capability> _supported;

  /// Whether [capability] is supported.
  bool supports(Capability capability) => _supported.contains(capability);

  /// All supported capabilities.
  Set<Capability> get all => Set<Capability>.of(_supported);
}
