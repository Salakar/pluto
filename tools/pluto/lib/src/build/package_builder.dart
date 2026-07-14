import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pluto_manifest/pluto_manifest.dart';

import '../artifacts/checksums.dart';
import '../errors.dart';
import 'release_pipeline.dart';
import 'tar_writer.dart';

/// Source file included in a `.plap` package.
final class PackageEntry {
  /// Creates a package entry.
  const PackageEntry({
    required this.path,
    required this.bytes,
    this.executable = false,
  });

  /// Relative POSIX path inside the package source layout.
  final String path;

  /// File bytes.
  final Uint8List bytes;

  /// Whether executable mode should be preserved.
  final bool executable;
}

/// Source of package entries.
abstract interface class PackageSource {
  /// Reads all entries.
  Future<List<PackageEntry>> readEntries();
}

/// In-memory package source for tests and published multi-target builds.
final class MemoryPackageSource implements PackageSource {
  /// Creates an in-memory source.
  const MemoryPackageSource(this.entries);

  /// Entries returned by this source.
  final List<PackageEntry> entries;

  @override
  Future<List<PackageEntry>> readEntries() async => entries;
}

/// Directory-backed package source.
final class DirectoryPackageSource implements PackageSource {
  /// Creates a directory source rooted at [root].
  const DirectoryPackageSource(this.root);

  /// Source root directory.
  final String root;

  @override
  Future<List<PackageEntry>> readEntries() async {
    final Directory directory = Directory(root);
    final List<PackageEntry> entries = <PackageEntry>[];
    await for (final FileSystemEntity entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      final String relative = _relativePath(root, entity.path);
      entries.add(
        PackageEntry(
          path: _toPosix(relative),
          bytes: Uint8List.fromList(await entity.readAsBytes()),
          executable: _isExecutable(entity),
        ),
      );
    }
    return entries;
  }
}

/// Byte compressor used for the tar payload.
abstract interface class ByteCompressor {
  /// Compression name written to `INTEGRITY.json`.
  String get name;

  /// Compresses [input].
  Future<Uint8List> compress(Uint8List input);
}

/// Leaves bytes uncompressed, used by tests.
final class NoopCompressor implements ByteCompressor {
  /// Creates a no-op compressor.
  const NoopCompressor();

  @override
  String get name => 'none';

  @override
  Future<Uint8List> compress(Uint8List input) async => input;
}

/// Uses the host `zstd` executable to produce tar.zst bytes.
final class ExternalZstdCompressor implements ByteCompressor {
  /// Creates a zstd compressor.
  const ExternalZstdCompressor();

  @override
  String get name => 'zstd';

  @override
  Future<Uint8List> compress(Uint8List input) async {
    try {
      final Process process = await Process.start('zstd', <String>[
        '-q',
        '-19',
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
          message: 'zstd failed while creating .plap package.',
          remediation: stderrText.trim().isEmpty ? null : stderrText.trim(),
        );
      }
      return Uint8List.fromList(stdoutBytes);
    } on ProcessException catch (error) {
      throw ArtifactVerificationException(
        message: 'zstd executable not found: ${error.message}',
        remediation: 'Install zstd or use the test-only no-op compressor.',
      );
    }
  }
}

/// Toolchain identity stamped into one target slice.
final class PackageMetadata {
  /// Creates package metadata.
  const PackageMetadata({
    required this.flutterVersion,
    required this.engineCommit,
    required this.plutoVersion,
    this.buildMode = 'release',
    this.engineFlavor = 'release',
    this.target = 'linux-arm64',
  });

  /// Flutter SDK version used to build the app.
  final String flutterVersion;

  /// Engine commit required by the app.
  final String engineCommit;

  /// Pluto CLI version.
  final String plutoVersion;

  /// Runtime mode recorded in the slice's build metadata.
  final String buildMode;

  /// Engine flavor recorded in the slice's build metadata.
  final String engineFlavor;

  /// Exact device target for this slice.
  final String target;
}

/// One source layout used to build a target slice in a published package.
final class PackageSliceSource {
  /// Creates one target slice source.
  const PackageSliceSource({required this.source, required this.metadata});

  /// Layout containing one manifest and target-native payload.
  final PackageSource source;

  /// Exact identity of this layout.
  final PackageMetadata metadata;
}

/// Completed package bytes plus integrity metadata.
final class PlapPackage {
  /// Creates a package result.
  const PlapPackage({required this.bytes, required this.integrity});

  /// Final package bytes.
  final Uint8List bytes;

  /// Integrity document included in the package.
  final Map<String, Object?> integrity;
}

/// Builds the canonical target-sliced `.plap` archive.
final class PlapPackageBuilder {
  /// Creates a package builder.
  const PlapPackageBuilder({
    required this.compressor,
    this.tarWriter = const TarArchiveWriter(),
  });

  /// Compression implementation.
  final ByteCompressor compressor;

  /// Tar writer.
  final TarArchiveWriter tarWriter;

  /// Builds a device-aware package containing one selected target slice.
  Future<PlapPackage> build({
    required PackageSource source,
    required PackageMetadata metadata,
  }) {
    return buildSlices(
      slices: <PackageSliceSource>[
        PackageSliceSource(source: source, metadata: metadata),
      ],
    );
  }

  /// Builds a published package containing one or more exact target slices.
  ///
  /// Every source must describe the same app and toolchain. The manifest is
  /// stored once at archive root; every other layout file is target-scoped.
  Future<PlapPackage> buildSlices({
    required List<PackageSliceSource> slices,
  }) async {
    if (slices.isEmpty) {
      throw const ArtifactVerificationException(
        message: 'A .plap package must contain at least one target slice.',
      );
    }

    final List<_ValidatedPackageSlice> validated = <_ValidatedPackageSlice>[];
    for (final PackageSliceSource slice in slices) {
      validated.add(
        _validatePackageLayout(
          await slice.source.readEntries(),
          metadata: slice.metadata,
        ),
      );
    }
    _validateSliceSet(validated);

    final _ValidatedPackageSlice first = validated.first;
    final List<PackageEntry> payload = <PackageEntry>[
      PackageEntry(path: 'manifest.json', bytes: first.manifestBytes),
      for (final _ValidatedPackageSlice slice in validated)
        for (final PackageEntry entry in slice.sliceEntries)
          PackageEntry(
            path: 'targets/${slice.metadata.target}/${entry.path}',
            bytes: entry.bytes,
            executable: entry.executable,
          ),
    ];
    payload.sort((PackageEntry a, PackageEntry b) => a.path.compareTo(b.path));

    final Map<String, String> digests = <String, String>{
      for (final PackageEntry entry in payload)
        entry.path: sha256Bytes(entry.bytes),
    };
    final Map<String, Object?> integrity = <String, Object?>{
      'compression': compressor.name,
      'createdBy': 'pluto ${first.metadata.plutoVersion}',
      'files': Map<String, String>.fromEntries(
        digests.entries.toList(growable: false)..sort(
          (MapEntry<String, String> a, MapEntry<String, String> b) =>
              a.key.compareTo(b.key),
        ),
      ),
      'treeSha256': sha256Tree(digests),
    };
    final List<PackageEntry> archiveEntries = <PackageEntry>[
      ...payload,
      PackageEntry(
        path: 'INTEGRITY.json',
        bytes: Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert(integrity)),
        ),
      ),
    ];
    final Uint8List tarBytes = tarWriter.write(
      archiveEntries
          .map(
            (PackageEntry entry) => TarFileEntry(
              path: entry.path,
              bytes: entry.bytes,
              executable: entry.executable,
            ),
          )
          .toList(growable: false),
    );
    return PlapPackage(
      bytes: await compressor.compress(tarBytes),
      integrity: integrity,
    );
  }
}

/// Validates one host layout before archiving it as a target slice.
void validatePackageLayout(
  List<PackageEntry> entries, {
  required PackageMetadata metadata,
}) {
  _validatePackageLayout(entries, metadata: metadata);
}

_ValidatedPackageSlice _validatePackageLayout(
  List<PackageEntry> sourceEntries, {
  required PackageMetadata metadata,
}) {
  final PlutoTargetPlatform? targetPlatform = PlutoTargetPlatform.fromCliName(
    metadata.target,
  );
  if (targetPlatform == null) {
    throw ArtifactVerificationException(
      message: 'Package target is invalid: ${metadata.target}.',
    );
  }
  if (!const <String>{
        'debug',
        'profile',
        'release',
      }.contains(metadata.buildMode) ||
      metadata.engineFlavor != metadata.buildMode) {
    throw ArtifactVerificationException(
      message:
          'Package buildMode/engineFlavor is invalid: '
          '${metadata.buildMode}/${metadata.engineFlavor}.',
    );
  }
  if (targetPlatform == PlutoTargetPlatform.linuxArm &&
      metadata.buildMode != PlutoBuildMode.release.cliName) {
    throw const ArtifactVerificationException(
      message: 'linux-arm packages are release-only.',
      remediation: 'Build a linux-arm release AOT layout.',
    );
  }

  final Map<String, PackageEntry> entries = <String, PackageEntry>{};
  for (final PackageEntry entry in sourceEntries) {
    _validateLayoutPath(entry.path);
    if (entries[entry.path] != null) {
      throw ArtifactVerificationException(
        message: 'Package source has duplicate entry ${entry.path}.',
      );
    }
    entries[entry.path] = entry;
  }
  final PackageEntry? manifestEntry = entries['manifest.json'];
  if (manifestEntry == null) {
    throw const ArtifactVerificationException(
      message: 'Package layout is incomplete: missing manifest.json.',
    );
  }
  final Map<String, Object?> manifest = _decodeJsonObject(
    manifestEntry.bytes,
    description: 'Package manifest.json',
  );
  final Object? appId = manifest['id'];
  if (appId is! String || !_isSafeAppId(appId)) {
    throw ArtifactVerificationException(
      message: 'Package manifest has no valid "id" (got: $appId).',
    );
  }
  final Object? rawIconPath = manifest['icon'];
  final String? iconPath = rawIconPath is String ? rawIconPath : null;
  if (rawIconPath != null && iconPath == null) {
    throw const ArtifactVerificationException(
      message: 'Package manifest icon must be a relative string path.',
    );
  }
  if (iconPath != null) {
    _validateLayoutPath(iconPath);
    if (!iconPath.startsWith('assets/')) {
      throw const ArtifactVerificationException(
        message: 'Package manifest icon must be under assets/.',
      );
    }
  }

  for (final String path in entries.keys) {
    final bool allowed =
        path == 'manifest.json' ||
        path == BuildLayoutMetadata.fileName ||
        path.startsWith('bundle/') ||
        path == iconPath;
    if (!allowed) {
      throw ArtifactVerificationException(
        message: 'Package layout contains unsupported path $path.',
        remediation:
            'Only manifest.json, build-metadata.json, bundle/**, and the '
            'declared icon are package payloads.',
      );
    }
  }

  final PackageEntry metadataEntry =
      entries[BuildLayoutMetadata.fileName] ??
      PackageEntry(
        path: BuildLayoutMetadata.fileName,
        bytes: _encodeBuildMetadata(metadata),
      );
  _validateBuildMetadataDocument(metadataEntry.bytes, metadata);

  final Set<String> paths = entries.keys.toSet();
  final bool hasAssets = paths.any(
    (String path) => path.startsWith('bundle/flutter_assets/'),
  );
  final bool hasAotElf = paths.contains('bundle/lib/app.so');
  final bool hasLegacyAotElf = paths.contains('bundle/app.so');
  final bool hasKernel = paths.contains(
    'bundle/flutter_assets/kernel_blob.bin',
  );
  final List<String> missing = <String>[
    if (!hasAssets) 'bundle/flutter_assets/',
    if (metadata.buildMode == 'debug' && !hasKernel)
      'bundle/flutter_assets/kernel_blob.bin',
    if (metadata.buildMode != 'debug' && !hasAotElf) 'bundle/lib/app.so',
  ];
  if (missing.isNotEmpty) {
    throw ArtifactVerificationException(
      message: 'Package layout is incomplete: missing ${missing.join(', ')}.',
      remediation: 'Build the requested Pluto layout before packaging.',
    );
  }
  if (hasLegacyAotElf) {
    throw const ArtifactVerificationException(
      message: 'Package layout must use bundle/lib/app.so.',
    );
  }
  if ((metadata.buildMode == 'debug' && hasAotElf) ||
      (metadata.buildMode != 'debug' && hasKernel)) {
    throw ArtifactVerificationException(
      message: metadata.buildMode == 'debug'
          ? 'Debug package cannot contain app.so.'
          : '${metadata.buildMode} AOT package cannot contain '
                'kernel_blob.bin.',
    );
  }

  final Object? runtime = manifest['runtime'];
  final Object? runtimeType = runtime is Map<String, Object?>
      ? runtime['type']
      : null;
  final bool runtimeMatches = metadata.buildMode == 'debug'
      ? runtimeType == AppRuntimeKind.flutterKernel.wireName
      : runtimeType == AppRuntimeKind.flutterAot.wireName;
  if (!runtimeMatches) {
    throw ArtifactVerificationException(
      message:
          'Package runtime $runtimeType does not match ${metadata.buildMode}.',
    );
  }
  if (metadata.buildMode != 'debug') {
    final PlutoBuildMode mode = metadata.buildMode == 'profile'
        ? PlutoBuildMode.profile
        : PlutoBuildMode.release;
    verifyAotElfBytesForMode(
      entries['bundle/lib/app.so']!.bytes,
      mode,
      description: 'bundle/lib/app.so',
      targetPlatform: targetPlatform,
    );
  }

  final List<PackageEntry> sliceEntries = <PackageEntry>[
    metadataEntry,
    for (final PackageEntry entry in sourceEntries)
      if (entry.path != 'manifest.json' &&
          entry.path != BuildLayoutMetadata.fileName)
        entry,
  ];
  sliceEntries.sort(
    (PackageEntry a, PackageEntry b) => a.path.compareTo(b.path),
  );
  return _ValidatedPackageSlice(
    metadata: metadata,
    manifest: manifest,
    manifestBytes: manifestEntry.bytes,
    sliceEntries: sliceEntries,
  );
}

void _validateSliceSet(List<_ValidatedPackageSlice> slices) {
  final _ValidatedPackageSlice first = slices.first;
  final Set<String> targets = <String>{};
  for (final _ValidatedPackageSlice slice in slices) {
    if (!targets.add(slice.metadata.target)) {
      throw ArtifactVerificationException(
        message: 'Package has duplicate ${slice.metadata.target} slices.',
      );
    }
    if (!_jsonEquivalent(slice.manifest, first.manifest)) {
      throw ArtifactVerificationException(
        message:
            'Target ${slice.metadata.target} has a different app manifest.',
        remediation: 'All target layouts must describe exactly one app.',
      );
    }
    final PackageMetadata actual = slice.metadata;
    final PackageMetadata expected = first.metadata;
    if (actual.flutterVersion != expected.flutterVersion ||
        actual.engineCommit != expected.engineCommit ||
        actual.plutoVersion != expected.plutoVersion ||
        actual.buildMode != expected.buildMode ||
        actual.engineFlavor != expected.engineFlavor) {
      throw ArtifactVerificationException(
        message:
            'Target ${actual.target} has a different build/toolchain identity.',
        remediation:
            'All target slices must use the same mode, Flutter pin, engine '
            'pin, and Pluto builder.',
      );
    }
  }
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

void _validateBuildMetadataDocument(Uint8List bytes, PackageMetadata expected) {
  final Map<String, Object?> document = _decodeJsonObject(
    bytes,
    description: BuildLayoutMetadata.fileName,
  );
  final Map<String, Object?> identity = <String, Object?>{
    'schema': BuildLayoutMetadata.schema,
    'buildMode': expected.buildMode,
    'engineFlavor': expected.engineFlavor,
    'flutterVersion': expected.flutterVersion,
    'engineCommit': expected.engineCommit,
    'target': expected.target,
  };
  for (final MapEntry<String, Object?> field in identity.entries) {
    if (document[field.key] != field.value) {
      throw ArtifactVerificationException(
        message:
            '${BuildLayoutMetadata.fileName} ${field.key} does not match '
            'the package slice (${document[field.key]} vs ${field.value}).',
      );
    }
  }
}

Uint8List _encodeBuildMetadata(PackageMetadata metadata) {
  return Uint8List.fromList(
    utf8.encode(
      '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{'schema': BuildLayoutMetadata.schema, 'buildMode': metadata.buildMode, 'engineFlavor': metadata.engineFlavor, 'flutterVersion': metadata.flutterVersion, 'engineCommit': metadata.engineCommit, 'target': metadata.target})}\n',
    ),
  );
}

bool _jsonEquivalent(Object? a, Object? b) {
  return _canonicalJson(a) == _canonicalJson(b);
}

String _canonicalJson(Object? value) {
  if (value is Map<String, Object?>) {
    final List<String> keys = value.keys.toList(growable: false)..sort();
    return '{${keys.map((String key) => '${jsonEncode(key)}:'
        '${_canonicalJson(value[key])}').join(',')}}';
  }
  if (value is List<Object?>) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}

void _validateLayoutPath(String path) {
  final List<String> segments = path.split('/');
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.codeUnits.any((int unit) => unit < 0x20 || unit == 0x7f) ||
      segments.any(
        (String segment) =>
            segment.isEmpty || segment == '.' || segment == '..',
      )) {
    throw ArtifactVerificationException(
      message: 'Unsafe package layout path: $path.',
    );
  }
}

bool _isSafeAppId(String id) {
  return id.length <= 128 &&
      RegExp(
        r'^[A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z][A-Za-z0-9_-]*)+$',
      ).hasMatch(id);
}

final class _ValidatedPackageSlice {
  const _ValidatedPackageSlice({
    required this.metadata,
    required this.manifest,
    required this.manifestBytes,
    required this.sliceEntries,
  });

  final PackageMetadata metadata;
  final Map<String, Object?> manifest;
  final Uint8List manifestBytes;
  final List<PackageEntry> sliceEntries;
}

String _relativePath(String root, String path) {
  final String normalizedRoot = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  if (!path.startsWith(normalizedRoot)) {
    return path;
  }
  return path.substring(normalizedRoot.length);
}

String _toPosix(String path) => path.replaceAll(Platform.pathSeparator, '/');

bool _isExecutable(File file) {
  if (Platform.isWindows) {
    return false;
  }
  final FileStat stat = file.statSync();
  return (stat.mode & 0x49) != 0;
}
