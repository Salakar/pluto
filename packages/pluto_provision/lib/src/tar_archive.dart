import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// A regular file entry decoded from an uncompressed tar archive.
final class TarArchiveEntry {
  /// Creates a tar file entry.
  const TarArchiveEntry({required this.path, required this.bytes});

  /// POSIX path inside the archive.
  final String path;

  /// File content.
  final Uint8List bytes;
}

/// Decoded `.plap` transfer archive.
final class PlapArchive {
  /// Creates a decoded archive.
  const PlapArchive({required this.entries, required this.integrity});

  /// File entries keyed by archive path.
  final Map<String, Uint8List> entries;

  /// Parsed `INTEGRITY.json`, when present.
  final Map<String, Object?> integrity;

  /// Decodes an uncompressed tar stream.
  ///
  /// The CLI may store `.plap` as `tar.zst`; doc 07 makes decompression a
  /// host-side transfer concern, so this parser intentionally accepts the plain
  /// tar stream that the device transaction sees.
  static PlapArchive decode(Uint8List tarBytes) {
    final List<TarArchiveEntry> files = decodeTarArchive(tarBytes);
    final Map<String, Uint8List> entries = <String, Uint8List>{};
    for (final TarArchiveEntry file in files) {
      if (entries.containsKey(file.path)) {
        throw const FormatException('Duplicate path in archive.');
      }
      entries[file.path] = file.bytes;
    }
    final Uint8List? integrityBytes = entries['INTEGRITY.json'];
    final Map<String, Object?> integrity = integrityBytes == null
        ? const <String, Object?>{}
        : _decodeIntegrity(integrityBytes);
    _verifyIntegrity(entries, integrity);
    return PlapArchive(
      entries: Map<String, Uint8List>.unmodifiable(entries),
      integrity: integrity,
    );
  }

  /// Returns files mapped to their on-device app directory paths.
  Map<String, Uint8List> installedPayload() {
    final Map<String, Uint8List> payload = <String, Uint8List>{};
    for (final MapEntry<String, Uint8List> entry in entries.entries) {
      final String path = entry.key;
      if (path == 'INTEGRITY.json') {
        continue;
      }
      final String? installed = _installedPath(path);
      if (installed == null) {
        continue;
      }
      payload[installed] = entry.value;
    }
    if (!payload.containsKey('manifest.json')) {
      throw const FormatException('Archive does not contain manifest.json.');
    }
    return Map<String, Uint8List>.unmodifiable(payload);
  }
}

/// Decodes regular files from an uncompressed POSIX tar stream.
List<TarArchiveEntry> decodeTarArchive(Uint8List bytes) {
  const int blockSize = 512;
  if (bytes.length % blockSize != 0) {
    throw const FormatException('Tar archive length is not block-aligned.');
  }
  final List<TarArchiveEntry> entries = <TarArchiveEntry>[];
  var offset = 0;
  while (offset + blockSize <= bytes.length) {
    final Uint8List header = Uint8List.sublistView(
      bytes,
      offset,
      offset + blockSize,
    );
    offset += blockSize;
    if (_isZeroBlock(header)) {
      break;
    }
    final String name = _tarString(header, 0, 100);
    final String prefix = _tarString(header, 345, 155);
    final String path = prefix.isEmpty ? name : '$prefix/$name';
    _validateArchivePath(path);
    final int size = _tarOctal(header, 124, 12);
    final int typeFlag = header[156];
    final int paddedSize = ((size + blockSize - 1) ~/ blockSize) * blockSize;
    if (offset + paddedSize > bytes.length) {
      throw const FormatException('Tar entry extends past archive end.');
    }
    if (typeFlag == 0 || typeFlag == 48) {
      entries.add(
        TarArchiveEntry(
          path: path,
          bytes: Uint8List.fromList(bytes.sublist(offset, offset + size)),
        ),
      );
    }
    offset += paddedSize;
  }
  return entries;
}

Map<String, Object?> _decodeIntegrity(Uint8List bytes) {
  final Object? decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('INTEGRITY.json must be an object.');
  }
  return decoded;
}

void _verifyIntegrity(
  Map<String, Uint8List> entries,
  Map<String, Object?> integrity,
) {
  final Object? rawFiles = integrity['files'];
  if (rawFiles == null) {
    return;
  }
  if (rawFiles is! Map<String, Object?>) {
    throw const FormatException('INTEGRITY.json files must be an object.');
  }
  for (final MapEntry<String, Object?> expected in rawFiles.entries) {
    final Uint8List? bytes = entries[expected.key];
    if (bytes == null) {
      throw FormatException(
        'Integrity entry missing from archive: '
        '${expected.key}',
      );
    }
    final Object? expectedValue = expected.value;
    if (expectedValue is! String) {
      throw const FormatException('Integrity hash must be a string.');
    }
    final String actual = sha256Hex(bytes);
    final String normalized = expectedValue.startsWith('sha256:')
        ? expectedValue.substring('sha256:'.length)
        : expectedValue;
    if (actual != normalized) {
      throw FormatException('Integrity check failed for ${expected.key}.');
    }
  }
}

String? _installedPath(String archivePath) {
  if (archivePath == 'manifest.json') {
    return archivePath;
  }
  if (archivePath.startsWith('bundle/')) {
    return archivePath.substring('bundle/'.length);
  }
  if (archivePath.startsWith('icon/')) {
    final String name = archivePath.substring('icon/'.length);
    return name.isEmpty ? null : name;
  }
  if (archivePath.startsWith('lib/') ||
      archivePath.startsWith('flutter_assets/') ||
      archivePath == 'icon.png' ||
      archivePath == 'iconMono.png') {
    return archivePath;
  }
  return null;
}

String _tarString(Uint8List block, int start, int length) {
  final List<int> bytes = <int>[];
  for (var index = start; index < start + length; index++) {
    final int byte = block[index];
    if (byte == 0) {
      break;
    }
    bytes.add(byte);
  }
  return utf8.decode(bytes);
}

int _tarOctal(Uint8List block, int start, int length) {
  final String raw = _tarString(block, start, length).trim();
  if (raw.isEmpty) {
    return 0;
  }
  return int.parse(raw, radix: 8);
}

bool _isZeroBlock(Uint8List block) {
  for (final int byte in block) {
    if (byte != 0) {
      return false;
    }
  }
  return true;
}

void _validateArchivePath(String path) {
  if (path.isEmpty || path.startsWith('/') || path.contains('..')) {
    throw FormatException('Unsafe archive path: $path');
  }
}

/// Computes a lowercase SHA-256 hex digest.
String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();
