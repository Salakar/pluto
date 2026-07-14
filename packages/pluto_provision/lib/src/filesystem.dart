import 'dart:io';
import 'dart:typed_data';

/// Kind of filesystem entry.
enum ProvisionEntryType {
  /// Regular file.
  file,

  /// Directory.
  directory,
}

/// One direct child in a directory listing.
final class ProvisionPathEntry {
  /// Creates a path entry.
  const ProvisionPathEntry({required this.path, required this.type});

  /// Absolute POSIX path.
  final String path;

  /// Entry kind.
  final ProvisionEntryType type;

  /// Basename of [path].
  String get name => provisionBasename(path);
}

/// Filesystem abstraction used by host tests and device-side transaction code.
abstract interface class ProvisionFileSystem {
  /// Returns true when [path] exists.
  Future<bool> exists(String path);

  /// Returns true when [path] is a regular file.
  Future<bool> isFile(String path);

  /// Returns true when [path] is a directory.
  Future<bool> isDirectory(String path);

  /// Reads all bytes from [path].
  Future<Uint8List> readFile(String path);

  /// Writes [bytes] to [path], creating parent directories when needed.
  Future<void> writeFile(String path, List<int> bytes);

  /// Creates [path].
  Future<void> createDirectory(String path, {bool recursive = true});

  /// Lists direct children of [path].
  Future<List<ProvisionPathEntry>> listDirectory(String path);

  /// Renames [from] to [to], replacing [to] when it already exists.
  Future<void> rename(String from, String to);

  /// Deletes [path]. Missing paths are ignored.
  Future<void> delete(String path, {bool recursive = false});
}

/// Local dart:io-backed filesystem implementation.
final class LocalProvisionFileSystem implements ProvisionFileSystem {
  /// Creates a local filesystem implementation.
  const LocalProvisionFileSystem();

  @override
  Future<void> createDirectory(String path, {bool recursive = true}) {
    Directory(path).createSync(recursive: recursive);
    return Future<void>.value();
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) {
    final File file = File(path);
    if (file.existsSync()) {
      file.deleteSync();
      return Future<void>.value();
    }
    final Directory directory = Directory(path);
    if (directory.existsSync()) {
      directory.deleteSync(recursive: recursive);
    }
    return Future<void>.value();
  }

  @override
  Future<bool> exists(String path) => Future<bool>.value(
    File(path).existsSync() || Directory(path).existsSync(),
  );

  @override
  Future<bool> isDirectory(String path) =>
      Future<bool>.value(Directory(path).existsSync());

  @override
  Future<bool> isFile(String path) =>
      Future<bool>.value(File(path).existsSync());

  @override
  Future<List<ProvisionPathEntry>> listDirectory(String path) {
    final Directory directory = Directory(path);
    if (!directory.existsSync()) {
      return Future<List<ProvisionPathEntry>>.value(
        const <ProvisionPathEntry>[],
      );
    }
    final List<ProvisionPathEntry> entries = <ProvisionPathEntry>[];
    for (final FileSystemEntity entity in directory.listSync(
      recursive: false,
      followLinks: false,
    )) {
      final FileStat stat = entity.statSync();
      final ProvisionEntryType? type = switch (stat.type) {
        FileSystemEntityType.file => ProvisionEntryType.file,
        FileSystemEntityType.directory => ProvisionEntryType.directory,
        _ => null,
      };
      if (type != null) {
        entries.add(ProvisionPathEntry(path: entity.path, type: type));
      }
    }
    entries.sort(
      (ProvisionPathEntry a, ProvisionPathEntry b) => a.path.compareTo(b.path),
    );
    return Future<List<ProvisionPathEntry>>.value(entries);
  }

  @override
  Future<Uint8List> readFile(String path) =>
      Future<Uint8List>.value(File(path).readAsBytesSync());

  @override
  Future<void> rename(String from, String to) {
    final File targetFile = File(to);
    if (targetFile.existsSync()) {
      targetFile.deleteSync();
    }
    final Directory targetDirectory = Directory(to);
    if (targetDirectory.existsSync()) {
      targetDirectory.deleteSync(recursive: true);
    }
    if (File(from).existsSync()) {
      File(from).renameSync(to);
      return Future<void>.value();
    }
    Directory(from).renameSync(to);
    return Future<void>.value();
  }

  @override
  Future<void> writeFile(String path, List<int> bytes) {
    Directory(provisionDirname(path)).createSync(recursive: true);
    File(path).writeAsBytesSync(bytes, flush: true);
    return Future<void>.value();
  }
}

/// In-memory filesystem used by unit tests.
final class MemoryProvisionFileSystem implements ProvisionFileSystem {
  /// Creates an empty in-memory filesystem.
  MemoryProvisionFileSystem() : _directories = <String>{'/'};

  final Set<String> _directories;
  final Map<String, Uint8List> _files = <String, Uint8List>{};

  @override
  Future<void> createDirectory(String path, {bool recursive = true}) async {
    final String normalized = provisionNormalize(path);
    if (recursive) {
      final List<String> pieces = normalized
          .split('/')
          .where((String piece) => piece.isNotEmpty)
          .toList(growable: false);
      var current = '';
      for (final String piece in pieces) {
        current = current.isEmpty ? '/$piece' : '$current/$piece';
        _directories.add(current);
      }
      return;
    }
    final String parent = provisionDirname(normalized);
    if (!_directories.contains(parent)) {
      throw FileSystemException('Parent directory does not exist', parent);
    }
    _directories.add(normalized);
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    final String normalized = provisionNormalize(path);
    if (_files.remove(normalized) != null) {
      return;
    }
    if (!_directories.contains(normalized)) {
      return;
    }
    final String prefix = normalized == '/' ? '/' : '$normalized/';
    final bool hasChildren =
        _files.keys.any((String path) => path.startsWith(prefix)) ||
        _directories.any(
          (String path) => path != normalized && path.startsWith(prefix),
        );
    if (hasChildren && !recursive) {
      throw FileSystemException('Directory is not empty', normalized);
    }
    _files.removeWhere((String path, Uint8List _) => path.startsWith(prefix));
    _directories.removeWhere(
      (String path) => path == normalized || path.startsWith(prefix),
    );
    _directories.add('/');
  }

  @override
  Future<bool> exists(String path) async {
    final String normalized = provisionNormalize(path);
    return _files.containsKey(normalized) || _directories.contains(normalized);
  }

  @override
  Future<bool> isDirectory(String path) async =>
      _directories.contains(provisionNormalize(path));

  @override
  Future<bool> isFile(String path) async =>
      _files.containsKey(provisionNormalize(path));

  @override
  Future<List<ProvisionPathEntry>> listDirectory(String path) async {
    final String normalized = provisionNormalize(path);
    if (!_directories.contains(normalized)) {
      return const <ProvisionPathEntry>[];
    }
    final String prefix = normalized == '/' ? '/' : '$normalized/';
    final Map<String, ProvisionPathEntry> entries =
        <String, ProvisionPathEntry>{};
    for (final String directory in _directories) {
      if (directory == normalized || !directory.startsWith(prefix)) {
        continue;
      }
      final String rest = directory.substring(prefix.length);
      if (!rest.contains('/')) {
        entries[directory] = ProvisionPathEntry(
          path: directory,
          type: ProvisionEntryType.directory,
        );
      }
    }
    for (final String file in _files.keys) {
      if (!file.startsWith(prefix)) {
        continue;
      }
      final String rest = file.substring(prefix.length);
      if (!rest.contains('/')) {
        entries[file] = ProvisionPathEntry(
          path: file,
          type: ProvisionEntryType.file,
        );
      }
    }
    final List<ProvisionPathEntry> result = entries.values.toList();
    result.sort(
      (ProvisionPathEntry a, ProvisionPathEntry b) => a.path.compareTo(b.path),
    );
    return result;
  }

  @override
  Future<Uint8List> readFile(String path) async {
    final Uint8List? bytes = _files[provisionNormalize(path)];
    if (bytes == null) {
      throw FileSystemException('File does not exist', path);
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> rename(String from, String to) async {
    final String source = provisionNormalize(from);
    final String destination = provisionNormalize(to);
    await delete(destination, recursive: true);
    await createDirectory(provisionDirname(destination));
    final Uint8List? file = _files.remove(source);
    if (file != null) {
      _files[destination] = Uint8List.fromList(file);
      return;
    }
    if (!_directories.contains(source)) {
      throw FileSystemException('Path does not exist', source);
    }
    if (destination.startsWith('$source/')) {
      throw FileSystemException('Cannot move a directory into itself', source);
    }
    final String sourcePrefix = source == '/' ? '/' : '$source/';
    final List<String> dirsToMove = _directories
        .where((String path) => path == source || path.startsWith(sourcePrefix))
        .toList(growable: false);
    final Map<String, Uint8List> filesToMove = <String, Uint8List>{};
    for (final MapEntry<String, Uint8List> entry in _files.entries) {
      if (entry.key.startsWith(sourcePrefix)) {
        filesToMove[entry.key] = entry.value;
      }
    }
    for (final String path in dirsToMove) {
      _directories.remove(path);
    }
    for (final String path in filesToMove.keys) {
      _files.remove(path);
    }
    for (final String path in dirsToMove) {
      _directories.add(_replacePrefix(path, source, destination));
    }
    for (final MapEntry<String, Uint8List> entry in filesToMove.entries) {
      _files[_replacePrefix(entry.key, source, destination)] =
          Uint8List.fromList(entry.value);
    }
    _directories.add('/');
  }

  @override
  Future<void> writeFile(String path, List<int> bytes) async {
    final String normalized = provisionNormalize(path);
    await createDirectory(provisionDirname(normalized));
    _files[normalized] = Uint8List.fromList(bytes);
  }
}

String _replacePrefix(String path, String from, String to) {
  if (path == from) {
    return to;
  }
  return '$to${path.substring(from.length)}';
}

/// Normalizes an absolute POSIX path.
String provisionNormalize(String path) {
  final bool absolute = path.startsWith('/');
  final List<String> pieces = <String>[];
  for (final String piece in path.split('/')) {
    if (piece.isEmpty || piece == '.') {
      continue;
    }
    if (piece == '..') {
      if (pieces.isNotEmpty) {
        pieces.removeLast();
      }
      continue;
    }
    pieces.add(piece);
  }
  final String joined = pieces.join('/');
  if (absolute) {
    return joined.isEmpty ? '/' : '/$joined';
  }
  return joined.isEmpty ? '.' : joined;
}

/// Joins POSIX path [parts].
String provisionJoin(Iterable<String> parts) {
  final String raw = parts.where((String part) => part.isNotEmpty).join('/');
  return provisionNormalize(raw);
}

/// Returns the POSIX dirname for [path].
String provisionDirname(String path) {
  final String normalized = provisionNormalize(path);
  if (normalized == '/') {
    return '/';
  }
  final int slash = normalized.lastIndexOf('/');
  if (slash <= 0) {
    return normalized.startsWith('/') ? '/' : '.';
  }
  return normalized.substring(0, slash);
}

/// Returns the POSIX basename for [path].
String provisionBasename(String path) {
  final String normalized = provisionNormalize(path);
  if (normalized == '/') {
    return '/';
  }
  final int slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}
