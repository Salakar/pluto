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

  /// Relative POSIX path inside the package.
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

/// In-memory package source for tests.
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
      // Consume output concurrently with input. Large application bundles can
      // otherwise fill zstd's stdout pipe while Dart is still waiting for the
      // input sink to flush and close.
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

/// Metadata stamped into a package.
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

  /// Runtime mode recorded for install-time engine selection.
  final String buildMode;

  /// Engine flavor recorded for install-time engine selection.
  final String engineFlavor;

  /// Device target recorded for package validation and engine selection.
  final String target;
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

/// Builds `.plap` packages.
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

  /// Builds a package from [source].
  Future<PlapPackage> build({
    required PackageSource source,
    required PackageMetadata metadata,
  }) async {
    final List<PackageEntry> sourceEntries = await source.readEntries();
    validatePackageLayout(sourceEntries, metadata: metadata);
    final Map<String, String> digests = <String, String>{};
    for (final PackageEntry entry in sourceEntries) {
      digests[entry.path] = sha256Bytes(entry.bytes);
    }
    final Map<String, Object?> integrity = <String, Object?>{
      'schema': 1,
      'format': 'plap-tar-zst-v1',
      'compression': compressor.name,
      'createdBy': 'pluto ${metadata.plutoVersion}',
      'flutterVersion': metadata.flutterVersion,
      'engineCommit': metadata.engineCommit,
      'buildMode': metadata.buildMode,
      'engineFlavor': metadata.engineFlavor,
      'target': metadata.target,
      'files': Map<String, String>.fromEntries(
        digests.entries.toList(growable: false)..sort(
          (MapEntry<String, String> a, MapEntry<String, String> b) =>
              a.key.compareTo(b.key),
        ),
      ),
      'treeSha256': sha256Tree(digests),
    };
    final List<PackageEntry> entries = <PackageEntry>[
      ...sourceEntries,
      PackageEntry(
        path: 'INTEGRITY.json',
        bytes: Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert(integrity)),
        ),
      ),
    ];
    final Uint8List tarBytes = tarWriter.write(
      entries
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

/// Validates the host package layout before archiving.
void validatePackageLayout(
  List<PackageEntry> entries, {
  required PackageMetadata metadata,
}) {
  final Set<String> paths = entries
      .map((PackageEntry entry) => entry.path)
      .toSet();
  final bool hasAssets = paths.any(
    (String path) => path.startsWith('bundle/flutter_assets/'),
  );
  final bool hasAotElf =
      paths.contains('bundle/lib/app.so') || paths.contains('bundle/app.so');
  final bool hasKernel = paths.contains(
    'bundle/flutter_assets/kernel_blob.bin',
  );
  final Set<String> modes = <String>{'debug', 'profile', 'release'};
  final PlutoTargetPlatform? targetPlatform = PlutoTargetPlatform.fromCliName(
    metadata.target,
  );
  if (targetPlatform == null) {
    throw ArtifactVerificationException(
      message: 'Package target is invalid: ${metadata.target}.',
    );
  }
  if (!modes.contains(metadata.buildMode) ||
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
      remediation:
          'Build a linux-arm release AOT layout for the cooperative '
          'XOVI/AppLoad/QTFB runtime.',
    );
  }
  final List<String> missing = <String>[
    if (!paths.contains('manifest.json')) 'manifest.json',
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
  if ((metadata.buildMode == 'debug' && hasAotElf) ||
      (metadata.buildMode != 'debug' && hasKernel)) {
    throw ArtifactVerificationException(
      message: metadata.buildMode == 'debug'
          ? 'Debug package cannot contain app.so.'
          : '${metadata.buildMode} AOT package cannot contain '
                'kernel_blob.bin.',
    );
  }

  final PackageEntry manifestEntry = entries.firstWhere(
    (PackageEntry entry) => entry.path == 'manifest.json',
  );
  final Object? manifest;
  try {
    manifest = jsonDecode(utf8.decode(manifestEntry.bytes));
  } on FormatException catch (error) {
    throw ArtifactVerificationException(
      message: 'Package manifest.json is not valid JSON: ${error.message}',
    );
  }
  final Object? runtime = manifest is Map<String, Object?>
      ? manifest['runtime']
      : null;
  final Object? runtimeType = runtime is Map<String, Object?>
      ? runtime['type']
      : null;
  final AppRuntimeKind? runtimeKind = runtimeType is String
      ? AppRuntimeKind.fromWireName(runtimeType)
      : null;
  final bool runtimeMatches = metadata.buildMode == 'debug'
      ? runtimeKind == AppRuntimeKind.flutterKernel
      : runtimeKind == AppRuntimeKind.flutterAot;
  if (!runtimeMatches) {
    throw ArtifactVerificationException(
      message:
          'Package runtime $runtimeType does not match '
          '${metadata.buildMode}.',
      remediation:
          'Debug must use flutter-kernel; profile/release must use '
          'flutter-aot.',
    );
  }
  if (metadata.buildMode != 'debug') {
    final PlutoBuildMode mode = metadata.buildMode == 'profile'
        ? PlutoBuildMode.profile
        : PlutoBuildMode.release;
    final PackageEntry appSo = entries.firstWhere(
      (PackageEntry entry) =>
          entry.path == 'bundle/lib/app.so' || entry.path == 'bundle/app.so',
    );
    verifyAotElfBytesForMode(
      appSo.bytes,
      mode,
      description: appSo.path,
      targetPlatform: targetPlatform,
    );
  }
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
