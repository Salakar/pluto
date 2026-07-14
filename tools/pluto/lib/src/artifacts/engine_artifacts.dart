import 'dart:io';

import '../config/paths.dart';

/// Engine runtime flavor.
enum EngineFlavor {
  /// Debug/JIT engine.
  jit('jit'),

  /// Profile AOT engine.
  profile('profile'),

  /// Release AOT engine.
  release('release');

  const EngineFlavor(this.directoryName);

  /// Directory name used in the Pluto cache.
  final String directoryName;
}

/// Host platform key used under `gen_snapshot/`.
enum HostPlatform {
  /// macOS on arm64.
  darwinArm64('darwin-arm64'),

  /// macOS on x64.
  darwinX64('darwin-x64'),

  /// Linux on x64.
  linuxX64('linux-x64'),

  /// Linux on arm64.
  linuxArm64('linux-arm64'),

  /// Windows on x64.
  windowsX64('windows-x64'),

  /// Unknown host platform.
  unknown('unknown');

  const HostPlatform(this.cacheName);

  /// Cache directory name.
  final String cacheName;

  /// Detects the current host platform.
  static HostPlatform current() {
    final String os = Platform.operatingSystem;
    final String arch = Platform.version.toLowerCase().contains('arm64')
        ? 'arm64'
        : '';
    if (os == 'macos') {
      return arch == 'arm64' ? darwinArm64 : darwinX64;
    }
    if (os == 'linux') {
      return arch == 'arm64' ? linuxArm64 : linuxX64;
    }
    if (os == 'windows') {
      return windowsX64;
    }
    return unknown;
  }
}

/// Resolved cache layout for one engine hash.
final class EngineCacheLayout {
  /// Creates a cache layout.
  const EngineCacheLayout({required this.root, required this.hostPlatform});

  /// Root directory for the engine hash.
  final String root;

  /// Host platform used to resolve gen_snapshot.
  final HostPlatform hostPlatform;

  /// Path to `libflutter_engine.so` for [flavor].
  String engineLibrary(EngineFlavor flavor) {
    final String flavorDirectory = flavor == EngineFlavor.jit
        ? 'linux-arm64-jit'
        : 'linux-arm64-${flavor.directoryName}';
    return joinPath(root, <String>[flavorDirectory, 'libflutter_engine.so']);
  }

  /// Path to `icudtl.dat`.
  String get icuData => joinPath(root, <String>['icudtl.dat']);

  /// Path to release/profile `gen_snapshot`.
  String genSnapshot(EngineFlavor flavor) {
    if (flavor == EngineFlavor.jit) {
      throw ArgumentError.value(flavor, 'flavor', 'JIT has no gen_snapshot');
    }
    return joinPath(root, <String>[
      'gen_snapshot',
      hostPlatform.cacheName,
      'gen_snapshot_${flavor.directoryName}',
    ]);
  }

  /// Path to checksum metadata.
  String get checksums => joinPath(root, <String>['CHECKSUMS.json']);

  /// Returns missing required paths for the requested [flavors].
  List<String> missingArtifacts({
    required Iterable<EngineFlavor> flavors,
    bool includeGenSnapshot = true,
  }) {
    final List<String> missing = <String>[];
    for (final EngineFlavor flavor in flavors) {
      final String library = engineLibrary(flavor);
      if (!File(library).existsSync()) {
        missing.add(library);
      }
      if (includeGenSnapshot && flavor != EngineFlavor.jit) {
        final String snapshot = genSnapshot(flavor);
        if (!File(snapshot).existsSync()) {
          missing.add(snapshot);
        }
      }
    }
    if (!File(icuData).existsSync()) {
      missing.add(icuData);
    }
    return missing;
  }
}

/// Resolves engine artifact cache paths.
final class EngineArtifactResolver {
  /// Creates a resolver using [paths].
  const EngineArtifactResolver({required this.paths, this.hostPlatform});

  /// Pluto host paths.
  final PlutoPaths paths;

  /// Optional host platform override for tests.
  final HostPlatform? hostPlatform;

  /// Returns the cache layout for [engineHash].
  EngineCacheLayout layoutFor(String engineHash) {
    return EngineCacheLayout(
      root: paths.engineCacheDirectory(engineHash),
      hostPlatform: hostPlatform ?? HostPlatform.current(),
    );
  }
}
