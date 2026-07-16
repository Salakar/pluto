import 'dart:convert';
import 'dart:io';

import 'package:pluto_cli/pluto.dart';
import 'package:test/test.dart';

const String _engine = 'a10d8ac38de835021c8d2f920dbf50a920ccc030';
const String _revision = '0123456789abcdef0123456789abcdef01234567';

void main() {
  late Directory temp;
  late Directory release;
  late Directory pins;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('pluto-release-set-');
    release = Directory('${temp.path}/release')..createSync();
    pins = Directory('${temp.path}/pins')..createSync();
    File('${pins.path}/flutter.version').writeAsStringSync('3.44.4\n');
    File('${pins.path}/engine.version').writeAsStringSync('$_engine\n');
    File('${pins.path}/arm-sdk.pin').writeAsStringSync('''
schema=1
name=test-arm-sdk
sha256=${'b' * 64}
gcc_version=11.5.0
gcc_machine=arm-remarkable-linux-gnueabi
regular_files=1
''');
    File('${pins.path}/codex-armv7.json').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'schema': 1,
        'version': '0.144.1',
        'target': 'linux-arm',
        'sha256': 'a' * 64,
      }),
    );
    for (final String target in ReleaseSetManifest.requiredTargets) {
      File('${release.path}/targets/$target/bin/pluto-embedder')
        ..createSync(recursive: true)
        ..writeAsStringSync('$target embedder');
      File('${release.path}/targets/$target/share/device-profiles.sh')
        ..createSync(recursive: true)
        ..writeAsStringSync('$target profiles');
      File(
        '${release.path}/targets/$target/share/release-revision',
      ).writeAsStringSync('$_revision\n');
    }
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('manifest deterministically freezes revision pins and both slices', () {
    final ReleaseSetPins releasePins = ReleaseSetPins.read(pins.path);
    final ReleaseSetManifest first = ReleaseSetManifest.create(
      root: release.path,
      gitRevision: _revision,
      pins: releasePins,
    )..write();
    final String firstBytes = File(
      '${release.path}/${ReleaseSetManifest.fileName}',
    ).readAsStringSync();
    final ReleaseSetManifest second = ReleaseSetManifest.create(
      root: release.path,
      gitRevision: _revision,
      pins: releasePins,
    )..write();
    final String secondBytes = File(
      '${release.path}/${ReleaseSetManifest.fileName}',
    ).readAsStringSync();

    expect(secondBytes, firstBytes);
    expect(first.gitRevision, _revision);
    expect(second.slices.keys, ReleaseSetManifest.requiredTargets);
    expect(firstBytes, isNot(contains('"schema"')));
    expect(firstBytes, isNot(contains('"version"')));
    for (final String target in ReleaseSetManifest.requiredTargets) {
      expect(
        second.verifyTarget(target).files.keys,
        containsAll(<String>['bin/pluto-embedder', 'share/device-profiles.sh']),
      );
    }
  });

  test('reader rejects a missing peer slice before target selection', () {
    final ReleaseSetPins releasePins = ReleaseSetPins.read(pins.path);
    ReleaseSetManifest.create(
      root: release.path,
      gitRevision: _revision,
      pins: releasePins,
    ).write();
    Directory('${release.path}/targets/linux-arm').deleteSync(recursive: true);
    expect(
      () => ReleaseSetManifest.read(
        root: release.path,
        expectedPins: releasePins,
      ),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('missing or not a regular directory'),
        ),
      ),
    );
  });

  test('byte reader stays bound to one manifest snapshot', () {
    final ReleaseSetPins releasePins = ReleaseSetPins.read(pins.path);
    ReleaseSetManifest.create(
      root: release.path,
      gitRevision: _revision,
      pins: releasePins,
    ).write();
    final File manifest = File(
      '${release.path}/${ReleaseSetManifest.fileName}',
    );
    final List<int> snapshot = manifest.readAsBytesSync();
    final Map<String, Object?> replacement =
        jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
    replacement['gitRevision'] = 'f' * 40;
    manifest.writeAsStringSync(jsonEncode(replacement));

    final ReleaseSetManifest parsed = ReleaseSetManifest.readBytes(
      root: release.path,
      manifestBytes: snapshot,
      expectedPins: releasePins,
    );

    expect(parsed.gitRevision, _revision);
    expect(
      () => ReleaseSetManifest.read(
        root: release.path,
        expectedPins: releasePins,
      ),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('revision receipt does not match'),
        ),
      ),
    );
  });

  test('reader rejects a modified peer slice before target selection', () {
    final ReleaseSetPins releasePins = ReleaseSetPins.read(pins.path);
    ReleaseSetManifest.create(
      root: release.path,
      gitRevision: _revision,
      pins: releasePins,
    ).write();
    File(
      '${release.path}/targets/linux-arm/bin/pluto-embedder',
    ).writeAsStringSync('modified peer');

    expect(
      () => ReleaseSetManifest.read(
        root: release.path,
        expectedPins: releasePins,
      ),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('checksum mismatch'),
        ),
      ),
    );
  });

  test('reader rejects a manifest with a missing target record', () {
    final ReleaseSetPins releasePins = ReleaseSetPins.read(pins.path);
    ReleaseSetManifest.create(
      root: release.path,
      gitRevision: _revision,
      pins: releasePins,
    ).write();
    final File manifest = File(
      '${release.path}/${ReleaseSetManifest.fileName}',
    );
    final Map<String, Object?> document =
        jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
    final Map<String, Object?> targets =
        document['targets']! as Map<String, Object?>;
    targets.remove('linux-arm');
    manifest.writeAsStringSync(jsonEncode(document));

    expect(
      () => ReleaseSetManifest.read(
        root: release.path,
        expectedPins: releasePins,
      ),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('must be exactly'),
        ),
      ),
    );
  });

  test('selected slice rejects missing extra tampered and linked files', () {
    final ReleaseSetPins releasePins = ReleaseSetPins.read(pins.path);

    void reseal() {
      ReleaseSetManifest.create(
        root: release.path,
        gitRevision: _revision,
        pins: releasePins,
      ).write();
    }

    reseal();
    final String selected = '${release.path}/targets/linux-arm64';
    File('$selected/bin/pluto-embedder').writeAsStringSync('tampered');
    expect(
      () => ReleaseSetManifest.read(
        root: release.path,
        expectedPins: releasePins,
      ).verifyTarget('linux-arm64'),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('checksum mismatch'),
        ),
      ),
    );

    File(
      '$selected/bin/pluto-embedder',
    ).writeAsStringSync('linux-arm64 embedder');
    reseal();
    File('$selected/extra').writeAsStringSync('hybrid');
    expect(
      () => ReleaseSetManifest.read(
        root: release.path,
        expectedPins: releasePins,
      ).verifyTarget('linux-arm64'),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('file set does not match'),
        ),
      ),
    );

    File('$selected/extra').deleteSync();
    reseal();
    Link('$selected/linked').createSync('/tmp');
    expect(
      () => ReleaseSetManifest.read(
        root: release.path,
        expectedPins: releasePins,
      ).verifyTarget('linux-arm64'),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('non-regular entry'),
        ),
      ),
    );
  });

  test('reader rejects contradictory pins and compatibility fields', () {
    final ReleaseSetPins releasePins = ReleaseSetPins.read(pins.path);
    ReleaseSetManifest.create(
      root: release.path,
      gitRevision: _revision,
      pins: releasePins,
    ).write();
    final File manifest = File(
      '${release.path}/${ReleaseSetManifest.fileName}',
    );
    final Map<String, Object?> document =
        jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
    final Map<String, Object?> manifestPins =
        document['pins']! as Map<String, Object?>;
    manifestPins['flutterVersion'] = '3.44.5';
    manifest.writeAsStringSync(jsonEncode(document));
    expect(
      () => ReleaseSetManifest.read(
        root: release.path,
        expectedPins: releasePins,
      ),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('do not match'),
        ),
      ),
    );

    document['pins'] = releasePins.toJson();
    document['schema'] = 1;
    manifest.writeAsStringSync(jsonEncode(document));
    expect(
      () => ReleaseSetManifest.read(
        root: release.path,
        expectedPins: releasePins,
      ),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('fields must be exactly'),
        ),
      ),
    );
  });

  test('slice revision receipt is bound to the top-level revision', () {
    final ReleaseSetPins releasePins = ReleaseSetPins.read(pins.path);
    ReleaseSetManifest.create(
      root: release.path,
      gitRevision: _revision,
      pins: releasePins,
    ).write();
    final File manifest = File(
      '${release.path}/${ReleaseSetManifest.fileName}',
    );
    final Map<String, Object?> document =
        jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
    document['gitRevision'] = 'f' * 40;
    manifest.writeAsStringSync(jsonEncode(document));

    expect(
      () => ReleaseSetManifest.read(
        root: release.path,
        expectedPins: releasePins,
      ),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('revision receipt does not match'),
        ),
      ),
    );
  });
}
