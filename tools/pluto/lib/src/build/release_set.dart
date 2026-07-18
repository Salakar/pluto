import 'dart:convert';
import 'dart:io';

import '../artifacts/checksums.dart';
import '../artifacts/host_metadata.dart';
import '../errors.dart';

/// Immutable toolchain inputs frozen into a universal device release.
final class ReleaseSetPins {
  /// Creates an exact release pin set.
  const ReleaseSetPins({
    required this.armSdkPinSha256,
    required this.pinFiles,
    required this.flutterVersion,
    required this.engineCommit,
  });

  /// Digest of the complete authoritative ARMv7 SDK pin file.
  final String armSdkPinSha256;

  /// Digest of every authoritative file under the pins directory.
  final Map<String, String> pinFiles;

  /// Pinned Flutter framework version.
  final String flutterVersion;

  /// Pinned Flutter engine commit.
  final String engineCommit;

  /// Reads the authoritative pin files used by release assembly and provision.
  factory ReleaseSetPins.read(String pinsDirectory) {
    final String flutterVersion = _readRegularText(
      '$pinsDirectory/flutter.version',
    ).trim();
    final String engineCommit = _readRegularText(
      '$pinsDirectory/engine.version',
    ).trim();
    final String armSdkPinPath = '$pinsDirectory/arm-sdk.pin';
    _readRegularText(armSdkPinPath);
    final String armSdkPinSha256 = sha256Bytes(
      File(armSdkPinPath).readAsBytesSync(),
    );
    final Map<String, String> pinFiles = _scanRegularFiles(pinsDirectory);
    if (flutterVersion.isEmpty ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(engineCommit)) {
      throw const ArtifactVerificationException(
        message: 'Flutter or engine release pins are invalid.',
      );
    }
    return ReleaseSetPins(
      armSdkPinSha256: armSdkPinSha256,
      pinFiles: Map<String, String>.unmodifiable(pinFiles),
      flutterVersion: flutterVersion,
      engineCommit: engineCommit,
    );
  }

  /// Encodes the exact release-manifest pin object.
  Map<String, Object?> toJson() => <String, Object?>{
    'armSdkPinSha256': armSdkPinSha256,
    'engineCommit': engineCommit,
    'flutterVersion': flutterVersion,
    'pinFiles': <String, String>{
      for (final String path in pinFiles.keys.toList()..sort())
        path: pinFiles[path]!,
    },
  };

  /// Parses the exact release-manifest pin object.
  static ReleaseSetPins fromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const ArtifactVerificationException(
        message: 'Release manifest pins must be a JSON object.',
      );
    }
    _requireExactKeys(value, const <String>{
      'engineCommit',
      'flutterVersion',
      'armSdkPinSha256',
      'pinFiles',
    }, description: 'Release manifest pins');
    final Object? flutterVersion = value['flutterVersion'];
    final Object? armSdkPinSha256 = value['armSdkPinSha256'];
    final Object? engineCommit = value['engineCommit'];
    final Object? pinFileValue = value['pinFiles'];
    if (armSdkPinSha256 is! String ||
        !_sha256Pattern.hasMatch(armSdkPinSha256) ||
        pinFileValue is! Map<String, Object?> ||
        pinFileValue.isEmpty ||
        flutterVersion is! String ||
        flutterVersion.isEmpty ||
        engineCommit is! String ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(engineCommit)) {
      throw const ArtifactVerificationException(
        message: 'Release manifest pins are incomplete or invalid.',
      );
    }
    final Map<String, String> pinFiles = <String, String>{};
    for (final MapEntry<String, Object?> file in pinFileValue.entries) {
      _validateRelativePath(file.key);
      if (file.value is! String ||
          !_sha256Pattern.hasMatch(file.value! as String)) {
        throw ArtifactVerificationException(
          message: 'Release manifest has an invalid pin digest: ${file.key}.',
        );
      }
      pinFiles[file.key] = file.value! as String;
    }
    return ReleaseSetPins(
      armSdkPinSha256: armSdkPinSha256,
      pinFiles: Map<String, String>.unmodifiable(pinFiles),
      flutterVersion: flutterVersion,
      engineCommit: engineCommit,
    );
  }

  /// Whether every pin equals [other].
  bool matches(ReleaseSetPins other) =>
      armSdkPinSha256 == other.armSdkPinSha256 &&
      _stringMapsEqual(pinFiles, other.pinFiles) &&
      flutterVersion == other.flutterVersion &&
      engineCommit == other.engineCommit;
}

/// One manifest checksum-verified native runtime slice.
final class ReleaseSetSlice {
  /// Creates one immutable manifest slice record.
  const ReleaseSetSlice({
    required this.target,
    required this.directory,
    required this.files,
    required this.treeSha256,
  });

  /// Exact native target name.
  final String target;

  /// Self-contained slice directory on the host.
  final String directory;

  /// Expected SHA-256 for every regular file in [directory].
  final Map<String, String> files;

  /// Deterministic digest of [files].
  final String treeSha256;
}

/// Frozen universal release manifest used by `pluto provision`.
///
/// This is the sole current layout. It intentionally has no schema, format,
/// compatibility, or version discriminator.
final class ReleaseSetManifest {
  const ReleaseSetManifest._({
    required this.root,
    required this.gitRevision,
    required this.pins,
    required this.slices,
  });

  /// Canonical manifest file name at release-set root.
  static const String fileName = 'release-manifest.json';

  /// Supported target slices emitted by the public release assembler.
  static const Set<String> requiredTargets = <String>{
    'linux-arm',
    'linux-arm64',
  };

  /// Release-set root.
  final String root;

  /// Exact clean source revision from which every slice was assembled.
  final String gitRevision;

  /// Toolchain pins shared by every slice.
  final ReleaseSetPins pins;

  /// Manifest records keyed by exact target name.
  final Map<String, ReleaseSetSlice> slices;

  /// Scans both target slices and creates a deterministic manifest.
  static ReleaseSetManifest create({
    required String root,
    required String gitRevision,
    required ReleaseSetPins pins,
  }) {
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(gitRevision)) {
      throw const ArtifactVerificationException(
        message: 'Release Git revision must be a full 40-character hash.',
      );
    }
    final Map<String, ReleaseSetSlice> slices = <String, ReleaseSetSlice>{};
    for (final String target in requiredTargets.toList()..sort()) {
      final String directory = '$root/targets/$target';
      final Map<String, String> files = _scanRegularFiles(directory);
      if (files.isEmpty) {
        throw ArtifactVerificationException(
          message: 'Release slice $target is empty.',
        );
      }
      _validateRevisionReceipt(directory, gitRevision);
      slices[target] = ReleaseSetSlice(
        target: target,
        directory: directory,
        files: Map<String, String>.unmodifiable(files),
        treeSha256: sha256Tree(files),
      );
    }
    return ReleaseSetManifest._(
      root: root,
      gitRevision: gitRevision,
      pins: pins,
      slices: Map<String, ReleaseSetSlice>.unmodifiable(slices),
    );
  }

  /// Reads a release manifest and validates its exact current shape and pins.
  static ReleaseSetManifest read({
    required String root,
    required ReleaseSetPins expectedPins,
  }) {
    final String manifestPath = '$root/$fileName';
    if (FileSystemEntity.typeSync(manifestPath, followLinks: false) !=
        FileSystemEntityType.file) {
      throw ArtifactVerificationException(
        message: 'Missing regular release input: $manifestPath.',
      );
    }
    return readBytes(
      root: root,
      manifestBytes: File(manifestPath).readAsBytesSync(),
      expectedPins: expectedPins,
    );
  }

  /// Decodes manifest [manifestBytes] and validates its exact shape and pins.
  ///
  /// Callers that must bind a proof digest to the parsed manifest can retain
  /// one byte snapshot and pass it here without reopening [fileName].
  static ReleaseSetManifest readBytes({
    required String root,
    required List<int> manifestBytes,
    required ReleaseSetPins expectedPins,
  }) {
    final String manifestText;
    try {
      manifestText = utf8.decode(manifestBytes);
    } on FormatException catch (error) {
      throw ArtifactVerificationException(
        message: '$fileName is not valid UTF-8: ${error.message}',
      );
    }
    final Map<String, Object?> document = _decodeJsonObject(
      manifestText,
      description: fileName,
    );
    _requireExactKeys(document, const <String>{
      'gitRevision',
      'pins',
      'targets',
    }, description: fileName);
    final Object? revision = document['gitRevision'];
    if (revision is! String || !RegExp(r'^[0-9a-f]{40}$').hasMatch(revision)) {
      throw const ArtifactVerificationException(
        message: 'Release manifest Git revision is invalid.',
      );
    }
    final ReleaseSetPins pins = ReleaseSetPins.fromJson(document['pins']);
    if (!pins.matches(expectedPins)) {
      throw ArtifactVerificationException(
        message:
            'Release manifest toolchain pins do not match this Pluto build.',
        remediation:
            'Assemble the universal release from the current pinned inputs.',
      );
    }
    final Object? targetValue = document['targets'];
    if (targetValue is! Map<String, Object?>) {
      throw const ArtifactVerificationException(
        message: 'Release manifest targets must be a JSON object.',
      );
    }
    if (targetValue.keys.toSet().difference(requiredTargets).isNotEmpty ||
        requiredTargets.difference(targetValue.keys.toSet()).isNotEmpty) {
      throw ArtifactVerificationException(
        message:
            'Release manifest targets must be exactly '
            '${requiredTargets.toList()..sort()} (found: '
            '${targetValue.keys.toList()..sort()}).',
      );
    }
    final Map<String, ReleaseSetSlice> slices = <String, ReleaseSetSlice>{};
    for (final MapEntry<String, Object?> target in targetValue.entries) {
      final Object? recordValue = target.value;
      if (recordValue is! Map<String, Object?>) {
        throw ArtifactVerificationException(
          message: 'Release target ${target.key} must be a JSON object.',
        );
      }
      _requireExactKeys(recordValue, const <String>{
        'files',
        'treeSha256',
      }, description: 'Release target ${target.key}');
      final Object? fileValue = recordValue['files'];
      final Object? treeValue = recordValue['treeSha256'];
      if (fileValue is! Map<String, Object?> ||
          fileValue.isEmpty ||
          treeValue is! String ||
          !_sha256Pattern.hasMatch(treeValue)) {
        throw ArtifactVerificationException(
          message: 'Release target ${target.key} integrity is invalid.',
        );
      }
      final Map<String, String> files = <String, String>{};
      for (final MapEntry<String, Object?> file in fileValue.entries) {
        _validateRelativePath(file.key);
        if (file.value is! String ||
            !_sha256Pattern.hasMatch(file.value! as String)) {
          throw ArtifactVerificationException(
            message:
                'Release target ${target.key} has an invalid digest for '
                '${file.key}.',
          );
        }
        files[file.key] = file.value! as String;
      }
      if (sha256Tree(files) != treeValue) {
        throw ArtifactVerificationException(
          message: 'Release target ${target.key} tree digest is inconsistent.',
        );
      }
      slices[target.key] = ReleaseSetSlice(
        target: target.key,
        directory: '$root/targets/${target.key}',
        files: Map<String, String>.unmodifiable(files),
        treeSha256: treeValue,
      );
    }
    final ReleaseSetManifest manifest = ReleaseSetManifest._(
      root: root,
      gitRevision: revision,
      pins: pins,
      slices: Map<String, ReleaseSetSlice>.unmodifiable(slices),
    );
    // This is one indivisible dual-target release. A consumer may deploy only
    // one selected slice, but a missing or modified peer invalidates the set.
    for (final String target in requiredTargets.toList()..sort()) {
      manifest.verifyTarget(target);
    }
    return manifest;
  }

  /// Writes canonical deterministic JSON at [fileName].
  void write() {
    final Map<String, Object?> targets = <String, Object?>{};
    for (final String target in slices.keys.toList()..sort()) {
      final ReleaseSetSlice slice = slices[target]!;
      targets[target] = <String, Object?>{
        'files': <String, String>{
          for (final String path in slice.files.keys.toList()..sort())
            path: slice.files[path]!,
        },
        'treeSha256': slice.treeSha256,
      };
    }
    final String encoded = const JsonEncoder.withIndent('  ').convert(
      <String, Object?>{
        'gitRevision': gitRevision,
        'pins': pins.toJson(),
        'targets': targets,
      },
    );
    File('$root/$fileName').writeAsStringSync('$encoded\n', flush: true);
  }

  /// Selects and fully verifies the exact self-contained [target] slice.
  ReleaseSetSlice verifyTarget(String target) {
    final ReleaseSetSlice? slice = slices[target];
    if (slice == null) {
      throw ArtifactVerificationException(
        message:
            'Universal release has no $target slice (available: '
            '${slices.keys.toList()..sort()}).',
        remediation: 'Rebuild it with tools/build/assemble-device-release.sh.',
      );
    }
    final Map<String, String> actual = _scanRegularFiles(slice.directory);
    final Set<String> missing = slice.files.keys.toSet().difference(
      actual.keys.toSet(),
    );
    final Set<String> extra = actual.keys.toSet().difference(
      slice.files.keys.toSet(),
    );
    if (missing.isNotEmpty || extra.isNotEmpty) {
      throw ArtifactVerificationException(
        message:
            '$target release slice file set does not match $fileName '
            '(missing: ${missing.toList()..sort()}, '
            'extra: ${extra.toList()..sort()}).',
      );
    }
    for (final MapEntry<String, String> file in actual.entries) {
      if (slice.files[file.key] != file.value) {
        throw ArtifactVerificationException(
          message:
              '$target release slice checksum mismatch: ${file.key}. '
              'Refusing a hybrid or tampered provision.',
        );
      }
    }
    if (sha256Tree(actual) != slice.treeSha256) {
      throw ArtifactVerificationException(
        message: '$target release slice tree checksum mismatch.',
      );
    }
    _validateRevisionReceipt(slice.directory, gitRevision);
    return slice;
  }
}

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

Map<String, String> _scanRegularFiles(String directoryPath) {
  if (FileSystemEntity.typeSync(directoryPath, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw ArtifactVerificationException(
      message:
          'Release slice is missing or not a regular directory: $directoryPath.',
    );
  }
  final Map<String, String> files = <String, String>{};
  for (final FileSystemEntity entity in Directory(
    directoryPath,
  ).listSync(recursive: true, followLinks: false)) {
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      entity.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.directory) {
      continue;
    }
    if (type != FileSystemEntityType.file) {
      throw ArtifactVerificationException(
        message: 'Release slice contains a non-regular entry: ${entity.path}.',
      );
    }
    final String relative = _relativePath(directoryPath, entity.path);
    _validateRelativePath(relative);
    files[relative] = sha256Bytes(File(entity.path).readAsBytesSync());
  }
  return <String, String>{
    for (final String path in files.keys.toList()..sort()) path: files[path]!,
  };
}

bool _stringMapsEqual(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) {
    return false;
  }
  for (final MapEntry<String, String> entry in left.entries) {
    if (right[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

void _validateRevisionReceipt(String sliceDirectory, String gitRevision) {
  final String path = '$sliceDirectory/share/release-revision';
  final String actual = _readRegularText(path).trim();
  if (actual != gitRevision) {
    throw ArtifactVerificationException(
      message:
          'Release revision receipt does not match its manifest '
          '($actual vs $gitRevision): $path.',
    );
  }
}

String _relativePath(String root, String path) {
  final String prefix = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  if (!path.startsWith(prefix)) {
    throw ArtifactVerificationException(
      message: 'Release file escaped its target slice: $path.',
    );
  }
  return path.substring(prefix.length).replaceAll(Platform.pathSeparator, '/');
}

void _validateRelativePath(String path) {
  final List<String> segments = path.split('/');
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.codeUnits.any((int unit) => unit < 0x20 || unit == 0x7f) ||
      segments.any(
        (String segment) =>
            segment.isEmpty || segment == '.' || segment == '..',
      ) ||
      isHostMetadataPath(path)) {
    throw ArtifactVerificationException(
      message: 'Unsafe release slice path: $path.',
    );
  }
}

String _readRegularText(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw ArtifactVerificationException(
      message: 'Missing regular release input: $path.',
    );
  }
  return File(path).readAsStringSync();
}

Map<String, Object?> _decodeJsonObject(
  String text, {
  required String description,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
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

void _requireExactKeys(
  Map<String, Object?> value,
  Set<String> expected, {
  required String description,
}) {
  if (value.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(value.keys.toSet()).isNotEmpty) {
    throw ArtifactVerificationException(
      message:
          '$description fields must be exactly '
          '${expected.toList()..sort()}.',
    );
  }
}
