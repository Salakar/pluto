import 'dart:convert';
import 'dart:io';

import '../../../pluto/lib/src/artifacts/checksums.dart';
import '../../../pluto/lib/src/build/release_set.dart';

Never _usage() {
  stderr.writeln(
    'usage: dart verify_manifest.dart --manifest FILE --pins DIR '
    '--target TARGET --expected-revision HASH --evidence FILE --output FILE',
  );
  exit(64);
}

void main(List<String> arguments) {
  final Map<String, String> values = <String, String>{};
  for (var index = 0; index < arguments.length; index += 1) {
    final String argument = arguments[index];
    if (!argument.startsWith('--') || index + 1 >= arguments.length) {
      _usage();
    }
    values[argument.substring(2)] = arguments[index + 1];
    index += 1;
  }
  const Set<String> expectedArguments = <String>{
    'manifest',
    'pins',
    'target',
    'evidence',
    'output',
    'expected-revision',
  };
  if (values.keys.toSet().difference(expectedArguments).isNotEmpty ||
      values.length != expectedArguments.length) {
    _usage();
  }

  final File manifestFile = File(values['manifest']!);
  if (FileSystemEntity.typeSync(manifestFile.path, followLinks: false) !=
          FileSystemEntityType.file ||
      manifestFile.uri.pathSegments.last != ReleaseSetManifest.fileName) {
    stderr.writeln('acceptance manifest proof: invalid release manifest path');
    exit(66);
  }
  final String releaseRoot = manifestFile.parent.path;
  final ReleaseSetManifest release = ReleaseSetManifest.read(
    root: releaseRoot,
    expectedPins: ReleaseSetPins.read(values['pins']!),
  );
  final String target = values['target']!;
  final String expectedRevision = values['expected-revision']!;
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(expectedRevision) ||
      release.gitRevision != expectedRevision) {
    stderr.writeln(
      'acceptance manifest proof: manifest revision does not match device',
    );
    exit(74);
  }
  final ReleaseSetSlice slice = release.verifyTarget(target);

  final Map<String, _InstalledHash> installed = <String, _InstalledHash>{};
  final File evidenceFile = File(values['evidence']!);
  if (FileSystemEntity.typeSync(evidenceFile.path, followLinks: false) !=
      FileSystemEntityType.file) {
    stderr.writeln('acceptance manifest proof: evidence is not a regular file');
    exit(66);
  }
  final RegExp record = RegExp(
    r'^installed\.sha256=([0-9a-f]{64}) '
    r'device_path=(/home/root/pluto/[A-Za-z0-9._/-]+) '
    r'slice_path=([A-Za-z0-9._/-]+)$',
  );
  for (final String line in const LineSplitter().convert(
    evidenceFile.readAsStringSync(),
  )) {
    if (!line.startsWith('installed.sha256=')) {
      continue;
    }
    final RegExpMatch? match = record.firstMatch(line);
    if (match == null) {
      stderr.writeln('acceptance manifest proof: malformed installed hash');
      exit(74);
    }
    final String slicePath = match.group(3)!;
    if (installed.containsKey(slicePath)) {
      stderr.writeln(
        'acceptance manifest proof: duplicate installed path $slicePath',
      );
      exit(74);
    }
    installed[slicePath] = _InstalledHash(
      digest: match.group(1)!,
      devicePath: match.group(2)!,
    );
  }

  final Set<String> expectedPaths = slice.files.keys.toSet();
  final Set<String> actualPaths = installed.keys.toSet();
  final Set<String> missing = expectedPaths.difference(actualPaths);
  final Set<String> extra = actualPaths.difference(expectedPaths);
  if (missing.isNotEmpty || extra.isNotEmpty) {
    stderr.writeln(
      'acceptance manifest proof: installed immutable file set mismatch '
      '(missing: ${missing.toList()..sort()}, '
      'extra: ${extra.toList()..sort()})',
    );
    exit(74);
  }
  for (final String slicePath in expectedPaths) {
    final _InstalledHash actual = installed[slicePath]!;
    final String expectedDevicePath = _devicePath(slicePath);
    if (actual.devicePath != expectedDevicePath) {
      stderr.writeln(
        'acceptance manifest proof: wrong installed destination for '
        '$slicePath (${actual.devicePath} != $expectedDevicePath)',
      );
      exit(74);
    }
    if (actual.digest != slice.files[slicePath]) {
      stderr.writeln(
        'acceptance manifest proof: installed checksum mismatch: $slicePath',
      );
      exit(74);
    }
  }

  final File output = File(values['output']!);
  if (FileSystemEntity.typeSync(output.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    stderr.writeln('acceptance manifest proof: output already exists');
    exit(73);
  }
  final String manifestDigest = sha256Bytes(manifestFile.readAsBytesSync());
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{'format': 'pluto-acceptance-manifest-proof', 'gitRevision': release.gitRevision, 'installedFileCount': installed.length, 'manifestSha256': manifestDigest, 'sliceTreeSha256': slice.treeSha256, 'status': 'PASS', 'target': target})}\n',
    flush: true,
  );
}

String _devicePath(String slicePath) {
  if (!slicePath.contains('/')) {
    if (slicePath == 'pluto-embedder' || slicePath.endsWith('.sh')) {
      return '/home/root/pluto/bin/$slicePath';
    }
    stderr.writeln(
      'acceptance manifest proof: unsupported slice-root file: $slicePath',
    );
    exit(74);
  }
  return '/home/root/pluto/$slicePath';
}

final class _InstalledHash {
  const _InstalledHash({required this.digest, required this.devicePath});

  final String digest;
  final String devicePath;
}
