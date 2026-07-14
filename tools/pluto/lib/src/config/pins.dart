import 'dart:convert';
import 'dart:io';

import 'paths.dart';

/// Toolchain and firmware pins read from `tools/pluto/pins`.
final class PlutoPins {
  /// Creates immutable pin values.
  const PlutoPins({
    required this.flutterVersion,
    required this.engineVersion,
    required this.supportedOsBuilds,
  });

  /// Pinned Flutter SDK version, for example `3.44.4`.
  final String flutterVersion;

  /// Pinned Flutter engine commit hash.
  final String engineVersion;

  /// Supported reMarkable firmware build identifiers.
  final Set<String> supportedOsBuilds;

  /// Whether [engineVersion] is a concrete 40-character engine hash.
  bool get hasConcreteEngineVersion =>
      RegExp(r'^[0-9a-f]{40}$').hasMatch(engineVersion);

  /// Whether [firmwareBuild] is in the support matrix.
  bool supportsFirmware(String firmwareBuild) =>
      supportedOsBuilds.contains(firmwareBuild);
}

/// Reads Pluto pins from disk.
final class PinsRepository {
  /// Creates a pin repository rooted at [pinsDirectory].
  const PinsRepository({required this.pinsDirectory});

  /// Directory containing `flutter.version`, `engine.version`, and
  /// `supported_os.json`.
  final String pinsDirectory;

  /// Creates a repository from the package path resolver.
  factory PinsRepository.fromPaths(PlutoPaths paths) {
    return PinsRepository(pinsDirectory: paths.pinsDirectory);
  }

  /// Reads all pins.
  PlutoPins readPins() {
    final String flutterVersion = _readTrimmed('flutter.version');
    final String engineVersion = _readTrimmed('engine.version');
    final File supportedOsFile = File(
      joinPath(pinsDirectory, <String>['supported_os.json']),
    );
    final Object? decoded = jsonDecode(supportedOsFile.readAsStringSync());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('supported_os.json must be a JSON object');
    }
    final Object? buildsValue = decoded['supportedOsBuilds'];
    if (buildsValue is! List<Object?>) {
      throw const FormatException(
        'supported_os.json must contain supportedOsBuilds',
      );
    }
    final Set<String> builds = buildsValue.map((Object? value) {
      if (value is! String) {
        throw const FormatException(
          'supportedOsBuilds entries must be strings',
        );
      }
      return value;
    }).toSet();
    return PlutoPins(
      flutterVersion: flutterVersion,
      engineVersion: engineVersion,
      supportedOsBuilds: builds,
    );
  }

  String _readTrimmed(String fileName) {
    return File(
      joinPath(pinsDirectory, <String>[fileName]),
    ).readAsStringSync().trim();
  }
}
