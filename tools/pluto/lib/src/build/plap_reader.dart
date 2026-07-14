import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pluto_manifest/pluto_manifest.dart';

import '../artifacts/checksums.dart';
import '../errors.dart';
import 'release_pipeline.dart';

/// One regular file read out of a `.plap` tar archive.
final class PlapEntry {
  /// Creates an archive entry.
  const PlapEntry({required this.path, required this.bytes});

  /// Relative POSIX path inside the archive.
  final String path;

  /// File contents.
  final Uint8List bytes;
}

/// A `.plap` package opened on the host: the decompressed tar bytes plus the
/// parsed `manifest.json`.
final class PlapArchive {
  /// Creates an opened archive.
  const PlapArchive({
    required this.tarBytes,
    required this.manifest,
    required this.appId,
    required this.flutterVersion,
    required this.engineCommit,
    required this.buildMode,
    required this.engineFlavor,
    required this.target,
    required this.payloadHashes,
  });

  /// The decompressed ustar bytes (ready to stream to a device `tar -xf`).
  final Uint8List tarBytes;

  /// Parsed top-level `manifest.json`.
  final Map<String, Object?> manifest;

  /// App id declared by the manifest.
  final String appId;

  /// Flutter framework version stamped by the package builder.
  final String flutterVersion;

  /// Exact engine commit required by the package.
  final String engineCommit;

  /// Runtime mode stamped by the package builder.
  final String buildMode;

  /// Engine flavor stamped by the package builder.
  final String engineFlavor;

  /// Device target stamped by the package builder.
  final String target;

  /// Integrity hashes for the installed payload.
  final Map<String, String> payloadHashes;

  /// Opens [path], decompressing zstd/gzip payloads as needed, and validates
  /// that the package carries an installable app manifest.
  static Future<PlapArchive> read(String path) async {
    final File file = File(path);
    if (!file.existsSync()) {
      throw ArtifactVerificationException(message: 'Package not found: $path');
    }
    final Uint8List raw = Uint8List.fromList(await file.readAsBytes());
    final Uint8List tarBytes = await _decompress(raw);
    final List<PlapEntry> entries = readTarEntries(tarBytes);
    PlapEntry? manifestEntry;
    PlapEntry? integrityEntry;
    for (final PlapEntry entry in entries) {
      if (entry.path == 'manifest.json') {
        manifestEntry = entry;
      } else if (entry.path == 'INTEGRITY.json') {
        integrityEntry = entry;
      }
    }
    if (manifestEntry == null) {
      throw ArtifactVerificationException(
        message: 'Package $path has no top-level manifest.json.',
        remediation: 'Rebuild it with `pluto build package`.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(manifestEntry.bytes));
    } on FormatException catch (error) {
      throw ArtifactVerificationException(
        message: 'Package manifest.json is not valid JSON: ${error.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const ArtifactVerificationException(
        message: 'Package manifest.json must be a JSON object.',
      );
    }
    final Object? id = decoded['id'];
    if (id is! String || !isSafeAppId(id)) {
      throw ArtifactVerificationException(
        message: 'Package manifest has no valid "id" (got: $id).',
        remediation:
            'App ids must be reverse-DNS style (e.g. dev.example.notes) '
            'with no path separators.',
      );
    }
    final Map<String, Object?> integrity = _decodeIntegrity(integrityEntry);
    final Map<String, String> hashes = _verifyIntegrity(entries, integrity);
    final Object? runtimeValue = decoded['runtime'];
    final String? runtimeType = runtimeValue is Map<String, Object?>
        ? runtimeValue['type'] as String?
        : null;
    final AppRuntimeKind? runtimeKind = runtimeType == null
        ? null
        : AppRuntimeKind.fromWireName(runtimeType);
    final Object? rawFlutterVersion = integrity['flutterVersion'];
    final Object? rawEngineCommit = integrity['engineCommit'];
    final Object? rawBuildMode = integrity['buildMode'];
    final Object? rawEngineFlavor = integrity['engineFlavor'];
    final Object rawTarget =
        integrity['target'] ?? PlutoTargetPlatform.linuxArm64.cliName;
    if (rawFlutterVersion is! String ||
        rawFlutterVersion.isEmpty ||
        rawEngineCommit is! String ||
        rawEngineCommit.isEmpty ||
        rawBuildMode is! String ||
        rawEngineFlavor is! String ||
        rawTarget is! String) {
      throw const ArtifactVerificationException(
        message: 'Package integrity metadata has no complete build identity.',
        remediation: 'Rebuild it with `pluto build package`.',
      );
    }
    final String buildMode = rawBuildMode;
    final String engineFlavor = rawEngineFlavor;
    final PlutoTargetPlatform? targetPlatform = PlutoTargetPlatform.fromCliName(
      rawTarget,
    );
    if (targetPlatform == null) {
      throw ArtifactVerificationException(
        message: 'Package has unknown target "$rawTarget".',
      );
    }
    if (!const <String>{'debug', 'profile', 'release'}.contains(buildMode)) {
      throw ArtifactVerificationException(
        message: 'Package has unknown buildMode "$buildMode".',
      );
    }
    if (engineFlavor != buildMode) {
      throw ArtifactVerificationException(
        message:
            'Package engineFlavor "$engineFlavor" does not match '
            'buildMode "$buildMode".',
      );
    }
    if (targetPlatform == PlutoTargetPlatform.linuxArm &&
        buildMode != PlutoBuildMode.release.cliName) {
      throw const ArtifactVerificationException(
        message: 'linux-arm packages are release-only.',
        remediation:
            'Build a linux-arm release AOT layout for the cooperative '
            'XOVI/AppLoad/QTFB runtime.',
      );
    }
    final bool aotMode = buildMode != 'debug';
    if ((aotMode && runtimeKind != AppRuntimeKind.flutterAot) ||
        (!aotMode && runtimeKind != AppRuntimeKind.flutterKernel)) {
      throw ArtifactVerificationException(
        message:
            'Package runtime $runtimeType does not match buildMode $buildMode.',
        remediation:
            'Rebuild it; profile/release must use flutter-aot and debug must '
            'use flutter-kernel.',
      );
    }
    final Set<String> paths = entries
        .map((PlapEntry entry) => entry.path)
        .toSet();
    if (aotMode && paths.contains('bundle/flutter_assets/kernel_blob.bin')) {
      throw const ArtifactVerificationException(
        message: 'AOT package unexpectedly contains kernel_blob.bin.',
        remediation: 'Rebuild it with the Pluto AOT pipeline.',
      );
    }
    final bool hasAotElf =
        paths.contains('bundle/lib/app.so') || paths.contains('bundle/app.so');
    final bool hasKernel = paths.contains(
      'bundle/flutter_assets/kernel_blob.bin',
    );
    if ((aotMode && !hasAotElf) || (!aotMode && (!hasKernel || hasAotElf))) {
      throw ArtifactVerificationException(
        message: aotMode
            ? '$buildMode package has no AOT app.so.'
            : 'Debug package must contain kernel_blob.bin and no app.so.',
      );
    }
    if (aotMode) {
      final PlutoBuildMode mode = buildMode == 'profile'
          ? PlutoBuildMode.profile
          : PlutoBuildMode.release;
      final PlapEntry appSo = entries.firstWhere(
        (PlapEntry entry) =>
            entry.path == 'bundle/lib/app.so' || entry.path == 'bundle/app.so',
      );
      verifyAotElfBytesForMode(
        appSo.bytes,
        mode,
        description: appSo.path,
        targetPlatform: targetPlatform,
      );
    }
    return PlapArchive(
      tarBytes: tarBytes,
      manifest: decoded,
      appId: id,
      flutterVersion: rawFlutterVersion,
      engineCommit: rawEngineCommit,
      buildMode: buildMode,
      engineFlavor: engineFlavor,
      target: targetPlatform.cliName,
      payloadHashes: Map<String, String>.unmodifiable(hashes),
    );
  }

  static Map<String, Object?> _decodeIntegrity(PlapEntry? entry) {
    if (entry == null) {
      throw const ArtifactVerificationException(
        message: 'Package has no INTEGRITY.json build metadata.',
        remediation: 'Rebuild it with `pluto build package`.',
      );
    }
    try {
      final Object? decoded = jsonDecode(utf8.decode(entry.bytes));
      return decoded is Map<String, Object?>
          ? decoded
          : const <String, Object?>{};
    } on FormatException {
      throw const ArtifactVerificationException(
        message: 'Package INTEGRITY.json is not valid JSON.',
      );
    }
  }

  static Map<String, String> _verifyIntegrity(
    List<PlapEntry> entries,
    Map<String, Object?> integrity,
  ) {
    if (integrity['schema'] != 1) {
      throw const ArtifactVerificationException(
        message: 'Package INTEGRITY.json must use schema 1.',
      );
    }
    final Object? rawFiles = integrity['files'];
    final Object? rawTree = integrity['treeSha256'];
    if (rawFiles is! Map<String, Object?> ||
        rawTree is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(rawTree)) {
      throw const ArtifactVerificationException(
        message: 'Package INTEGRITY.json has no valid files/treeSha256.',
      );
    }
    final Map<String, String> expected = <String, String>{};
    for (final MapEntry<String, Object?> entry in rawFiles.entries) {
      final Object? digest = entry.value;
      if (digest is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
          entry.key == 'INTEGRITY.json') {
        throw ArtifactVerificationException(
          message: 'Invalid integrity record for ${entry.key}.',
        );
      }
      expected[entry.key] = digest;
    }
    final List<PlapEntry> payload = entries
        .where((PlapEntry entry) => entry.path != 'INTEGRITY.json')
        .toList(growable: false);
    final Set<String> actualPaths = payload
        .map((PlapEntry entry) => entry.path)
        .toSet();
    if (actualPaths.length != expected.length ||
        !actualPaths.containsAll(expected.keys) ||
        !expected.keys.toSet().containsAll(actualPaths)) {
      final Set<String> missing = expected.keys.toSet().difference(actualPaths);
      final Set<String> extra = actualPaths.difference(expected.keys.toSet());
      throw ArtifactVerificationException(
        message:
            'Package payload set does not match INTEGRITY.json '
            '(missing: ${missing.join(', ')}, extra: ${extra.join(', ')}).',
      );
    }
    final Map<String, String> actual = <String, String>{};
    for (final PlapEntry entry in payload) {
      final String digest = sha256Bytes(entry.bytes);
      actual[entry.path] = digest;
      if (expected[entry.path] != digest) {
        throw ArtifactVerificationException(
          message: 'Package payload checksum mismatch: ${entry.path}.',
        );
      }
    }
    final String actualTree = sha256Tree(actual);
    if (actualTree != rawTree) {
      throw const ArtifactVerificationException(
        message: 'Package treeSha256 does not match its payload.',
      );
    }
    return Map<String, String>.unmodifiable(actual);
  }

  static Future<Uint8List> _decompress(Uint8List raw) async {
    if (raw.length >= 4 &&
        raw[0] == 0x28 &&
        raw[1] == 0xb5 &&
        raw[2] == 0x2f &&
        raw[3] == 0xfd) {
      return _zstdDecompress(raw);
    }
    if (raw.length >= 2 && raw[0] == 0x1f && raw[1] == 0x8b) {
      return Uint8List.fromList(gzip.decode(raw));
    }
    return raw;
  }

  static Future<Uint8List> _zstdDecompress(Uint8List input) async {
    try {
      final Process process = await Process.start('zstd', <String>[
        '-d',
        '-q',
        '--stdout',
      ]);
      // Drain both output pipes before writing. A decompressed AOT package is
      // much larger than a pipe buffer; waiting for stdin to close first can
      // deadlock with zstd blocked while writing stdout.
      final Future<List<int>> stdoutFuture = process.stdout.fold<List<int>>(
        <int>[],
        (List<int> previous, List<int> chunk) {
          previous.addAll(chunk);
          return previous;
        },
      );
      final Future<String> stderrFuture = utf8.decodeStream(process.stderr);
      process.stdin.add(input);
      await process.stdin.close();
      final List<int> stdoutBytes = await stdoutFuture;
      final String stderrText = await stderrFuture;
      final int exitCode = await process.exitCode;
      if (exitCode != 0) {
        throw ArtifactVerificationException(
          message: 'zstd failed while reading the .plap package.',
          remediation: stderrText.trim().isEmpty ? null : stderrText.trim(),
        );
      }
      return Uint8List.fromList(stdoutBytes);
    } on ProcessException catch (error) {
      throw ArtifactVerificationException(
        message: 'zstd executable not found: ${error.message}',
        remediation: 'Install zstd to open compressed .plap packages.',
      );
    }
  }
}

/// Matches the device-side `safe_app_id` rules in
/// `pluto-install-transaction.sh`: reverse-DNS style, no separators.
bool isSafeAppId(String id) {
  return id.length <= 128 &&
      RegExp(
        r'^[A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z][A-Za-z0-9_-]*)+$',
      ).hasMatch(id);
}

/// Reads the regular-file entries of a ustar archive.
///
/// Accepts only regular files and harmless directory headers. Links, devices,
/// GNU/pax extension records, unsafe paths, duplicate names, and invalid tar
/// checksums are rejected because the same bytes are later passed to device
/// `tar -xf`.
List<PlapEntry> readTarEntries(Uint8List archive) {
  final List<PlapEntry> entries = <PlapEntry>[];
  final Set<String> names = <String>{};
  int offset = 0;
  while (offset + 512 <= archive.length) {
    final Uint8List header = Uint8List.sublistView(
      archive,
      offset,
      offset + 512,
    );
    if (_isZeroBlock(header)) {
      break;
    }
    _verifyTarChecksum(header);
    final int size = _readOctal(header, 124, 12);
    final int dataStart = offset + 512;
    final int dataEnd = dataStart + size;
    if (dataEnd > archive.length) {
      throw const ArtifactVerificationException(
        message: 'Corrupt .plap package: tar entry exceeds archive size.',
      );
    }
    final int typeFlag = header[156];
    final Uint8List data = Uint8List.sublistView(archive, dataStart, dataEnd);
    final String name = _entryName(header);
    final bool directory = typeFlag == 0x35;
    _validateTarPath(name, directory: directory);
    if (!names.add(name)) {
      throw ArtifactVerificationException(
        message: 'Corrupt .plap package: duplicate tar entry $name.',
      );
    }
    switch (typeFlag) {
      case 0x30: // '0' regular file.
      case 0x00: // legacy regular file.
        entries.add(PlapEntry(path: name, bytes: Uint8List.fromList(data)));
        break;
      case 0x35: // '5' directory.
        if (size != 0) {
          throw ArtifactVerificationException(
            message: 'Corrupt .plap package: directory $name has data.',
          );
        }
        break;
      default:
        throw ArtifactVerificationException(
          message:
              'Unsafe .plap package: tar entry $name has unsupported type '
              '0x${typeFlag.toRadixString(16)}.',
        );
    }
    final int padded = size == 0 ? 0 : ((size + 511) ~/ 512) * 512;
    offset = dataStart + padded;
  }
  return entries;
}

void _validateTarPath(String path, {required bool directory}) {
  final String normalized = directory && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
  final List<String> segments = normalized.split('/');
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      normalized.contains('\\') ||
      normalized.codeUnits.any((int unit) => unit < 0x20 || unit == 0x7f) ||
      segments.any(
        (String segment) =>
            segment.isEmpty || segment == '.' || segment == '..',
      )) {
    throw ArtifactVerificationException(
      message: 'Unsafe .plap package path: $path.',
    );
  }
}

void _verifyTarChecksum(Uint8List header) {
  final int expected = _readOctal(header, 148, 8);
  int actual = 0;
  for (int index = 0; index < header.length; index += 1) {
    actual += index >= 148 && index < 156 ? 0x20 : header[index];
  }
  if (expected != actual) {
    throw const ArtifactVerificationException(
      message: 'Corrupt .plap package: invalid tar header checksum.',
    );
  }
}

String _entryName(Uint8List header) {
  final String name = _readString(header, 0, 100);
  final String prefix = _readString(header, 345, 155);
  return prefix.isEmpty ? name : '$prefix/$name';
}

bool _isZeroBlock(Uint8List block) {
  for (final int byte in block) {
    if (byte != 0) {
      return false;
    }
  }
  return true;
}

String _readString(Uint8List bytes, int offset, int length) {
  final int end = offset + length > bytes.length
      ? bytes.length
      : offset + length;
  int stop = offset;
  while (stop < end && bytes[stop] != 0) {
    stop += 1;
  }
  return ascii.decode(bytes.sublist(offset, stop), allowInvalid: true);
}

int _readOctal(Uint8List bytes, int offset, int length) {
  final String text = _readString(bytes, offset, length).trim();
  if (text.isEmpty) {
    return 0;
  }
  return int.tryParse(text, radix: 8) ?? 0;
}
