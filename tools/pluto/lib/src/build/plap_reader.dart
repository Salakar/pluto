import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pluto_manifest/pluto_manifest.dart';

import '../artifacts/checksums.dart';
import '../artifacts/host_metadata.dart';
import '../errors.dart';
import 'release_pipeline.dart';
import 'tar_writer.dart';

/// One regular file read out of a `.plap` tar archive.
final class PlapEntry {
  /// Creates an archive entry.
  const PlapEntry({required this.path, required this.bytes});

  /// Relative POSIX path inside the archive.
  final String path;

  /// File contents.
  final Uint8List bytes;
}

/// One validated, install-ready target slice in a `.plap` package.
final class PlapTargetSlice {
  /// Creates a validated target slice.
  const PlapTargetSlice({
    required this.target,
    required this.flutterVersion,
    required this.engineCommit,
    required this.buildMode,
    required this.engineFlavor,
    required this.installTarBytes,
    required this.payloadHashes,
  });

  /// Exact target name (`linux-arm` or `linux-arm64`).
  final String target;

  /// Flutter framework version stamped by this slice.
  final String flutterVersion;

  /// Exact engine commit required by this slice.
  final String engineCommit;

  /// Runtime mode stamped by this slice.
  final String buildMode;

  /// Engine flavor stamped by this slice.
  final String engineFlavor;

  /// Flat install tar containing the shared manifest and this slice only.
  final Uint8List installTarBytes;

  /// Integrity hashes keyed by paths in [installTarBytes].
  final Map<String, String> payloadHashes;
}

/// A validated canonical `.plap` package opened on the host.
final class PlapArchive {
  /// Creates a validated package archive.
  const PlapArchive({
    required this.packageTarBytes,
    required this.manifest,
    required this.appId,
    required this.flutterVersion,
    required this.engineCommit,
    required this.buildMode,
    required this.engineFlavor,
    required this.slices,
    required this.payloadHashes,
  });

  /// Decompressed canonical archive, including every target slice.
  final Uint8List packageTarBytes;

  /// Parsed shared top-level `manifest.json`.
  final Map<String, Object?> manifest;

  /// App id declared by the shared manifest.
  final String appId;

  /// Flutter framework version shared by every target slice.
  final String flutterVersion;

  /// Exact engine commit shared by every target slice.
  final String engineCommit;

  /// Runtime mode shared by every target slice.
  final String buildMode;

  /// Engine flavor shared by every target slice.
  final String engineFlavor;

  /// Validated target slices keyed by exact target name.
  final Map<String, PlapTargetSlice> slices;

  /// Integrity hashes keyed by canonical package paths.
  final Map<String, String> payloadHashes;

  /// Decompressed canonical package bytes.
  ///
  /// Install routing must use [sliceForTarget] and upload
  /// [PlapTargetSlice.installTarBytes], not this multi-target archive.
  Uint8List get tarBytes => packageTarBytes;

  /// The sole target in a device-aware single-slice package.
  ///
  /// Multi-target consumers must call [sliceForTarget] explicitly.
  String get target {
    if (slices.length != 1) {
      throw StateError(
        'Package contains ${slices.length} targets; select one explicitly.',
      );
    }
    return slices.keys.single;
  }

  /// Selects the exact slice for a probed device target.
  PlapTargetSlice sliceForTarget(String target) {
    final PlapTargetSlice? slice = slices[target];
    if (slice == null) {
      throw ArtifactVerificationException(
        message:
            'Package has no $target slice (available: '
            '${slices.keys.join(', ')}).',
      );
    }
    return slice;
  }

  /// Opens and fully validates [path].
  static Future<PlapArchive> read(String path) async {
    final File file = File(path);
    if (!file.existsSync()) {
      throw ArtifactVerificationException(message: 'Package not found: $path');
    }
    final Uint8List raw = Uint8List.fromList(await file.readAsBytes());
    final _DecompressedPackage decompressed = await _decompress(raw);
    final Uint8List tarBytes = decompressed.bytes;
    final List<PlapEntry> entries = readTarEntries(tarBytes);
    final Map<String, PlapEntry> byPath = <String, PlapEntry>{
      for (final PlapEntry entry in entries) entry.path: entry,
    };

    final PlapEntry? manifestEntry = byPath['manifest.json'];
    if (manifestEntry == null) {
      throw ArtifactVerificationException(
        message: 'Package $path has no top-level manifest.json.',
        remediation: 'Rebuild it with `pluto build package`.',
      );
    }
    final Map<String, Object?> manifest = _decodeJsonObject(
      manifestEntry.bytes,
      description: 'Package manifest.json',
    );
    final AppManifest appManifest = _decodeCanonicalManifest(
      manifestEntry.bytes,
      description: 'Package manifest.json',
    );
    final String id = appManifest.id.value;
    final Set<String> iconPaths = <String>{
      appManifest.icon,
      if (appManifest.iconMono != null) appManifest.iconMono!,
    };
    for (final String iconPath in iconPaths) {
      _validateTarPath(iconPath, directory: false);
      if (!iconPath.startsWith('assets/')) {
        throw const ArtifactVerificationException(
          message: 'Package manifest icons must be under assets/.',
        );
      }
    }

    final Map<String, String> hashes = _verifyIntegrity(
      entries,
      _decodeIntegrity(byPath['INTEGRITY.json']),
      actualCompression: decompressed.compression,
    );
    final Map<String, List<PlapEntry>> targetEntries =
        <String, List<PlapEntry>>{};
    for (final PlapEntry entry in entries) {
      if (entry.path == 'manifest.json' || entry.path == 'INTEGRITY.json') {
        continue;
      }
      final List<String> segments = entry.path.split('/');
      if (segments.length < 3 || segments.first != 'targets') {
        throw ArtifactVerificationException(
          message: 'Non-canonical top-level package path: ${entry.path}.',
          remediation:
              'Payload files must be under targets/linux-arm/ or '
              'targets/linux-arm64/.',
        );
      }
      final String target = segments[1];
      if (PlutoTargetPlatform.fromCliName(target) == null) {
        throw ArtifactVerificationException(
          message: 'Package has unsupported target directory "$target".',
        );
      }
      targetEntries.putIfAbsent(target, () => <PlapEntry>[]).add(entry);
    }
    if (targetEntries.isEmpty) {
      throw const ArtifactVerificationException(
        message: 'Package has no target slices.',
      );
    }

    final String runtimeType = appManifest.runtime.kind.wireName;
    final Map<String, PlapTargetSlice> slices = <String, PlapTargetSlice>{};
    _SliceIdentity? commonIdentity;
    for (final MapEntry<String, List<PlapEntry>> target
        in targetEntries.entries) {
      final AppTargetPlatform manifestTarget = AppTargetPlatform.fromWireName(
        target.key,
      )!;
      if (!appManifest.targets.contains(manifestTarget)) {
        throw ArtifactVerificationException(
          message: 'Package manifest does not support target ${target.key}.',
          remediation:
              'Rebuild the package using only its declared target slices.',
        );
      }
      final _ValidatedArchiveSlice validated = _validateTargetSlice(
        target: target.key,
        canonicalEntries: target.value,
        manifestEntry: manifestEntry,
        runtimeType: runtimeType,
        iconPaths: iconPaths,
        canonicalHashes: hashes,
      );
      commonIdentity ??= validated.identity;
      if (validated.identity != commonIdentity) {
        throw ArtifactVerificationException(
          message:
              'Target ${target.key} has a different build/toolchain identity.',
          remediation:
              'Every slice must use the same build mode, Flutter pin, and '
              'engine pin.',
        );
      }
      slices[target.key] = validated.slice;
    }
    final _SliceIdentity identity = commonIdentity!;
    if (appManifest.engine.flutterVersion != identity.flutterVersion ||
        appManifest.engine.engineCommit != identity.engineCommit) {
      throw const ArtifactVerificationException(
        message: 'Package manifest engine identity does not match its slices.',
      );
    }
    return PlapArchive(
      packageTarBytes: tarBytes,
      manifest: Map<String, Object?>.unmodifiable(manifest),
      appId: id,
      flutterVersion: identity.flutterVersion,
      engineCommit: identity.engineCommit,
      buildMode: identity.buildMode,
      engineFlavor: identity.engineFlavor,
      slices: Map<String, PlapTargetSlice>.unmodifiable(slices),
      payloadHashes: Map<String, String>.unmodifiable(hashes),
    );
  }
}

_ValidatedArchiveSlice _validateTargetSlice({
  required String target,
  required List<PlapEntry> canonicalEntries,
  required PlapEntry manifestEntry,
  required String runtimeType,
  required Set<String> iconPaths,
  required Map<String, String> canonicalHashes,
}) {
  final String prefix = 'targets/$target/';
  final Map<String, PlapEntry> entries = <String, PlapEntry>{};
  for (final PlapEntry canonical in canonicalEntries) {
    final String path = canonical.path.substring(prefix.length);
    final bool allowed =
        path == BuildLayoutMetadata.fileName ||
        path.startsWith('bundle/') ||
        iconPaths.contains(path);
    if (!allowed) {
      throw ArtifactVerificationException(
        message: 'Unsupported path in $target slice: $path.',
      );
    }
    entries[path] = PlapEntry(path: path, bytes: canonical.bytes);
  }
  final PlapEntry? metadataEntry = entries[BuildLayoutMetadata.fileName];
  if (metadataEntry == null) {
    throw ArtifactVerificationException(
      message: '$target slice has no ${BuildLayoutMetadata.fileName}.',
    );
  }
  for (final String iconPath in iconPaths) {
    if (!entries.containsKey(iconPath)) {
      throw ArtifactVerificationException(
        message: '$target slice has no declared icon $iconPath.',
      );
    }
  }
  final BuildLayoutMetadata metadata = BuildLayoutMetadata.decodeBytes(
    metadataEntry.bytes,
    description: '$target ${BuildLayoutMetadata.fileName}',
  );
  if (metadata.target != target) {
    throw ArtifactVerificationException(
      message: '$target slice has incomplete or conflicting build metadata.',
    );
  }
  final String rawFlutterVersion = metadata.flutterVersion;
  final String rawEngineCommit = metadata.engineCommit;
  final String buildMode = metadata.buildMode.cliName;
  final String engineFlavor = metadata.engineFlavor;
  final PlutoTargetPlatform targetPlatform = PlutoTargetPlatform.fromCliName(
    target,
  )!;

  final bool aotMode = buildMode != 'debug';
  final String expectedRuntime = aotMode
      ? AppRuntimeKind.flutterAot.wireName
      : AppRuntimeKind.flutterKernel.wireName;
  if (runtimeType != expectedRuntime) {
    throw ArtifactVerificationException(
      message:
          'Package runtime $runtimeType does not match $target $buildMode.',
    );
  }
  final Set<String> paths = entries.keys.toSet();
  final bool hasAotElf = paths.contains('bundle/lib/app.so');
  final bool hasKernel = paths.contains(
    'bundle/flutter_assets/kernel_blob.bin',
  );
  final bool hasAssets = paths.any(
    (String path) => path.startsWith('bundle/flutter_assets/'),
  );
  if (!hasAssets ||
      (aotMode && (!hasAotElf || hasKernel)) ||
      (!aotMode && (!hasKernel || hasAotElf))) {
    throw ArtifactVerificationException(
      message: '$target $buildMode slice has an invalid runtime payload.',
    );
  }
  if (aotMode) {
    final PlutoBuildMode mode = buildMode == 'profile'
        ? PlutoBuildMode.profile
        : PlutoBuildMode.release;
    verifyAotElfBytesForMode(
      entries['bundle/lib/app.so']!.bytes,
      mode,
      description: '${prefix}bundle/lib/app.so',
      targetPlatform: targetPlatform,
    );
  }

  final List<PlapEntry> flattened = <PlapEntry>[
    PlapEntry(path: 'manifest.json', bytes: manifestEntry.bytes),
    ...entries.values,
  ]..sort((PlapEntry a, PlapEntry b) => a.path.compareTo(b.path));
  final Uint8List installTar = const TarArchiveWriter().write(
    flattened
        .map(
          (PlapEntry entry) =>
              TarFileEntry(path: entry.path, bytes: entry.bytes),
        )
        .toList(growable: false),
  );
  final Map<String, String> flatHashes = <String, String>{
    'manifest.json': canonicalHashes['manifest.json']!,
    for (final PlapEntry entry in canonicalEntries)
      entry.path.substring(prefix.length): canonicalHashes[entry.path]!,
  };
  final _SliceIdentity identity = _SliceIdentity(
    flutterVersion: rawFlutterVersion,
    engineCommit: rawEngineCommit,
    buildMode: buildMode,
    engineFlavor: engineFlavor,
  );
  return _ValidatedArchiveSlice(
    identity: identity,
    slice: PlapTargetSlice(
      target: target,
      flutterVersion: rawFlutterVersion,
      engineCommit: rawEngineCommit,
      buildMode: buildMode,
      engineFlavor: engineFlavor,
      installTarBytes: installTar,
      payloadHashes: Map<String, String>.unmodifiable(flatHashes),
    ),
  );
}

Map<String, Object?> _decodeJsonObject(
  Uint8List bytes, {
  required String description,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException catch (error) {
    throw ArtifactVerificationException(
      message: '$description is not valid JSON: ${error.message}',
    );
  }
  if (decoded is! Map<String, Object?>) {
    throw ArtifactVerificationException(
      message: '$description must be a JSON object.',
    );
  }
  return decoded;
}

AppManifest _decodeCanonicalManifest(
  Uint8List bytes, {
  required String description,
}) {
  final String source;
  try {
    source = utf8.decode(bytes);
  } on FormatException catch (error) {
    throw ArtifactVerificationException(
      message: '$description is not valid UTF-8: ${error.message}',
    );
  }
  final Result<AppManifest, ManifestError> result = AppManifest.decode(source);
  final AppManifest? manifest = result.valueOrNull;
  if (manifest == null) {
    throw ArtifactVerificationException(
      message: '$description is not canonical: ${result.errorOrNull!.message}',
      remediation: 'Rebuild the package with the current Pluto builder.',
    );
  }
  return manifest;
}

Map<String, Object?> _decodeIntegrity(PlapEntry? entry) {
  if (entry == null) {
    throw const ArtifactVerificationException(
      message: 'Package has no INTEGRITY.json.',
      remediation: 'Rebuild it with `pluto build package`.',
    );
  }
  return _decodeJsonObject(entry.bytes, description: 'Package INTEGRITY.json');
}

Map<String, String> _verifyIntegrity(
  List<PlapEntry> entries,
  Map<String, Object?> integrity, {
  required String actualCompression,
}) {
  const Set<String> exactFields = <String>{
    'compression',
    'createdBy',
    'files',
    'treeSha256',
  };
  if (integrity.keys.toSet().difference(exactFields).isNotEmpty ||
      exactFields.difference(integrity.keys.toSet()).isNotEmpty) {
    throw const ArtifactVerificationException(
      message:
          'Package INTEGRITY.json must contain only compression, createdBy, '
          'files, and treeSha256; schema/version fields are not supported.',
    );
  }
  final Object? rawCompression = integrity['compression'];
  final Object? rawCreatedBy = integrity['createdBy'];
  final Object? rawFiles = integrity['files'];
  final Object? rawTree = integrity['treeSha256'];
  if (rawCompression != actualCompression ||
      rawCreatedBy is! String ||
      rawCreatedBy.isEmpty ||
      rawFiles is! Map<String, Object?> ||
      rawTree is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(rawTree)) {
    throw const ArtifactVerificationException(
      message: 'Package INTEGRITY.json has invalid package identity.',
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
  if (sha256Tree(actual) != rawTree) {
    throw const ArtifactVerificationException(
      message: 'Package treeSha256 does not match its payload.',
    );
  }
  return Map<String, String>.unmodifiable(actual);
}

Future<_DecompressedPackage> _decompress(Uint8List raw) async {
  if (raw.length >= 4 &&
      raw[0] == 0x28 &&
      raw[1] == 0xb5 &&
      raw[2] == 0x2f &&
      raw[3] == 0xfd) {
    return _DecompressedPackage(
      bytes: await _zstdDecompress(raw),
      compression: 'zstd',
    );
  }
  if (raw.length >= 2 && raw[0] == 0x1f && raw[1] == 0x8b) {
    throw const ArtifactVerificationException(
      message: 'Gzip .plap packages are not supported.',
      remediation: 'Rebuild the package in the canonical zstd format.',
    );
  }
  return _DecompressedPackage(bytes: raw, compression: 'none');
}

Future<Uint8List> _zstdDecompress(Uint8List input) async {
  try {
    final Process process = await Process.start('zstd', <String>[
      '-d',
      '-q',
      '--stdout',
    ]);
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

/// Matches the device-side safe app-id rules.
bool isSafeAppId(String id) {
  return id.length <= 128 &&
      RegExp(
        r'^[A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z][A-Za-z0-9_-]*)+$',
      ).hasMatch(id);
}

/// Reads the regular-file entries of a ustar archive.
///
/// Accepts only regular files and harmless directory headers. Links, devices,
/// extension records, unsafe paths, duplicate names, and invalid checksums are
/// rejected because selected slice bytes are later passed to device `tar -xf`.
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
      case 0x30:
      case 0x00:
        entries.add(PlapEntry(path: name, bytes: Uint8List.fromList(data)));
        break;
      case 0x35:
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
  if (isHostMetadataPath(normalized)) {
    throw ArtifactVerificationException(
      message: 'Package contains forbidden host metadata: $path.',
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

final class _DecompressedPackage {
  const _DecompressedPackage({required this.bytes, required this.compression});

  final Uint8List bytes;
  final String compression;
}

final class _ValidatedArchiveSlice {
  const _ValidatedArchiveSlice({required this.identity, required this.slice});

  final _SliceIdentity identity;
  final PlapTargetSlice slice;
}

final class _SliceIdentity {
  const _SliceIdentity({
    required this.flutterVersion,
    required this.engineCommit,
    required this.buildMode,
    required this.engineFlavor,
  });

  final String flutterVersion;
  final String engineCommit;
  final String buildMode;
  final String engineFlavor;

  @override
  bool operator ==(Object other) {
    return other is _SliceIdentity &&
        other.flutterVersion == flutterVersion &&
        other.engineCommit == engineCommit &&
        other.buildMode == buildMode &&
        other.engineFlavor == engineFlavor;
  }

  @override
  int get hashCode =>
      Object.hash(flutterVersion, engineCommit, buildMode, engineFlavor);
}
