import 'dart:io';

/// Host filesystem locations used by Pluto.
final class PlutoPaths {
  /// Creates a path resolver.
  const PlutoPaths({
    required this.packageRoot,
    required this.homeDirectory,
    this.repositoryRootOverride,
  });

  /// The `tools/pluto` package root.
  final String packageRoot;

  /// The current user's home directory.
  final String homeDirectory;

  /// Explicit repository root, primarily for hermetic tests/embedders.
  final String? repositoryRootOverride;

  /// Creates paths for the current process.
  factory PlutoPaths.defaults() {
    final String? home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    return PlutoPaths(
      packageRoot: Directory.current.path,
      homeDirectory: home ?? Directory.current.path,
    );
  }

  /// Directory containing pinned toolchain metadata.
  String get pinsDirectory {
    final String local = joinPath(packageRoot, <String>['pins']);
    if (Directory(local).existsSync()) {
      return local;
    }
    return joinPath(repositoryRoot, <String>['tools', 'pluto', 'pins']);
  }

  /// Root of the Pluto repository containing `tools/pluto/pins`.
  ///
  /// The CLI is commonly invoked from an app directory, from the repository
  /// root, or from `tools/pluto`. Walk upwards from both configured and
  /// current directories so all three forms resolve the same pinned inputs.
  String get repositoryRoot {
    if (repositoryRootOverride case final String override) {
      return override;
    }
    for (final String start in <String>{packageRoot, Directory.current.path}) {
      Directory current = Directory(start).absolute;
      while (true) {
        final File marker = File(
          joinPath(current.path, <String>[
            'tools',
            'pluto',
            'pins',
            'engine.version',
          ]),
        );
        if (marker.existsSync()) {
          return current.path;
        }
        final Directory parent = current.parent;
        if (parent.path == current.path) {
          break;
        }
        current = parent;
      }
    }
    return packageRoot;
  }

  /// Pluto user configuration directory.
  String get plutoHome => joinPath(homeDirectory, <String>['.pluto']);

  /// Host cache root.
  String get cacheDirectory => joinPath(plutoHome, <String>['cache']);

  /// Engine cache root for [engineHash].
  String engineCacheDirectory(String engineHash) =>
      joinPath(cacheDirectory, <String>['engine', engineHash]);
}

/// Joins a [base] path with [segments] using the platform separator.
String joinPath(String base, List<String> segments) {
  String current = base;
  for (final String segment in segments) {
    if (current.endsWith(Platform.pathSeparator)) {
      current = '$current$segment';
    } else {
      current = '$current${Platform.pathSeparator}$segment';
    }
  }
  return current;
}

/// Expands a leading `~` in a user-facing path.
String expandHome(String path, String homeDirectory) {
  if (path == '~') {
    return homeDirectory;
  }
  if (path.startsWith('~/')) {
    return '$homeDirectory/${path.substring(2)}';
  }
  return path;
}
