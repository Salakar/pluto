import 'dart:convert';

import 'package:pluto_manifest/pluto_manifest.dart';
import 'package:test/test.dart';

const String _engineCommit = 'a10d8ac38de835021c8d2f920dbf50a920ccc030';

void main() {
  test('canonical JSON round-trips without format or ABI versions', () {
    final String source = jsonEncode(
      _canonicalManifest(
        id: 'dev.example.sketchpad',
        name: 'Sketchpad',
        permissions: <Object?>['pen.raw', 'touch.raw'],
        refreshProfile: 'drawing',
      ),
    );

    final Result<AppManifest, ManifestError> result = AppManifest.decode(
      source,
    );
    final AppManifest manifest = result.valueOrNull!;
    final String encoded = manifest.encode();
    final Result<AppManifest, ManifestError> roundTrip = AppManifest.decode(
      encoded,
    );
    final Map<String, Object?> document =
        jsonDecode(encoded) as Map<String, Object?>;
    final Map<String, Object?> engine =
        document['engine']! as Map<String, Object?>;

    expect(result.isOk, isTrue);
    expect(roundTrip.isOk, isTrue);
    expect(roundTrip.valueOrNull!.encode(), encoded);
    expect(manifest.id.value, 'dev.example.sketchpad');
    expect(manifest.permissions, contains(AppPermission.penRaw));
    expect(manifest.display.refreshProfile, DisplayRefreshProfile.drawing);
    expect(document, isNot(contains('schema')));
    expect(
      engine.keys,
      unorderedEquals(<String>['flutterVersion', 'engineCommit']),
    );
    expect(encoded, contains('"scale":"auto"'));
  });

  test('authored YAML defaults and round-trips to the one canonical shape', () {
    for (final String displaySource in <String>[
      '',
      '''
display:
  scale: auto
''',
    ]) {
      final Result<AppManifest, ManifestError> result =
          AppManifest.decodeAuthoredYaml(
            '''
id: dev.example.responsive
name: Responsive
version: 1.0.0
$displaySource
''',
            runtime: const FlutterAotRuntime(),
            engine: const EngineRequirement(
              flutterVersion: '3.44.4',
              engineCommit: _engineCommit,
            ),
          );

      expect(result.isOk, isTrue, reason: displaySource);
      final String encoded = result.valueOrNull!.encode();
      final Map<String, Object?> root =
          jsonDecode(encoded) as Map<String, Object?>;
      expect(
        root.keys,
        containsAll(<String>[
          'icon',
          'permissions',
          'display',
          'launch',
          'runtime',
          'engine',
        ]),
      );
      expect(root, isNot(contains('schema')));
      expect(AppManifest.decode(encoded).valueOrNull!.encode(), encoded);
    }
  });

  test('numeric display scale overrides are rejected', () {
    final Result<AppManifest, ManifestError> result =
        AppManifest.decodeAuthoredYaml(
          '''
id: dev.example.fixedscale
name: Fixed scale
version: 1.0.0
display:
  scale: 1.65
''',
          runtime: const FlutterAotRuntime(),
          engine: const EngineRequirement(
            flutterVersion: '3.44.4',
            engineCommit: _engineCommit,
          ),
        );

    expect(result.errorOrNull, isA<ManifestFieldError>());
    expect(
      result.errorOrNull?.message,
      'display.scale: must be auto when provided',
    );
  });

  test('authored YAML accepts no schema or stamped-field override', () {
    for (final String extra in <String>[
      'schema: 1',
      'runtime: {}',
      'engine: {}',
      'futureField: true',
    ]) {
      final Result<AppManifest, ManifestError> result =
          AppManifest.decodeAuthoredYaml(
            '''
id: dev.example.notes
name: Notes
version: 1.0.0
$extra
''',
            runtime: const FlutterKernelRuntime(),
            engine: const EngineRequirement(
              flutterVersion: '3.44.4',
              engineCommit: _engineCommit,
            ),
          );

      expect(result.errorOrNull, isA<ManifestFieldError>(), reason: extra);
      expect(result.errorOrNull?.message, contains('is not supported'));
    }
  });

  test('runtime type and nested object shapes match exactly', () {
    final Map<String, Object?> wrongType = _canonicalManifest();
    wrongType['runtime'] = <String, Object?>{
      'type': 'FlutterAot',
      'appElf': 'lib/app.so',
      'assets': 'flutter_assets',
    };
    final Result<AppManifest, ManifestError> wrongTypeResult =
        AppManifest.decode(jsonEncode(wrongType));
    expect(
      wrongTypeResult.errorOrNull?.message,
      'runtime.type: unknown runtime type',
    );

    for (final Map<String, Object?> runtime in <Map<String, Object?>>[
      <String, Object?>{'type': 'flutter-aot', 'assets': 'flutter_assets'},
      <String, Object?>{
        'type': 'flutter-aot',
        'appElf': 'lib/app.so',
        'assets': 'flutter_assets',
        'fallback': 'kernel_blob.bin',
      },
      <String, Object?>{
        'type': 'flutter-kernel',
        'assets': 'flutter_assets',
        'appElf': 'lib/app.so',
      },
    ]) {
      final Map<String, Object?> document = _canonicalManifest();
      document['runtime'] = runtime;
      expect(
        AppManifest.decode(jsonEncode(document)).errorOrNull,
        isA<ManifestFieldError>(),
        reason: jsonEncode(runtime),
      );
    }
  });

  test('unknown permissions and version fields are rejected', () {
    final Map<String, Object?> unknownPermission = _canonicalManifest();
    unknownPermission['permissions'] = <Object?>['typo.permission'];
    expect(
      AppManifest.decode(jsonEncode(unknownPermission)).errorOrNull,
      isA<ManifestUnknownPermission>(),
    );

    final Map<String, Object?> versionedManifest = _canonicalManifest();
    versionedManifest['schema'] = 1;
    expect(
      AppManifest.decode(jsonEncode(versionedManifest)).errorOrNull?.message,
      'schema: is not supported',
    );

    final Map<String, Object?> versionedEngine = _canonicalManifest();
    (versionedEngine['engine']! as Map<String, Object?>)['plutoAbi'] = 1;
    expect(
      AppManifest.decode(jsonEncode(versionedEngine)).errorOrNull?.message,
      'engine.plutoAbi: is not supported',
    );
  });

  test('canonical manifest rejects every missing or unknown object key', () {
    const List<String> requiredRootKeys = <String>[
      'id',
      'name',
      'version',
      'icon',
      'runtime',
      'engine',
      'permissions',
      'display',
      'launch',
    ];
    for (final String key in requiredRootKeys) {
      final Map<String, Object?> document = _canonicalManifest()..remove(key);
      expect(
        AppManifest.decode(jsonEncode(document)).errorOrNull?.message,
        '$key: is required',
        reason: key,
      );
    }

    final Map<String, Object?> unknownRoot = _canonicalManifest();
    unknownRoot['formatVersion'] = 1;
    expect(
      AppManifest.decode(jsonEncode(unknownRoot)).errorOrNull?.message,
      'formatVersion: is not supported',
    );

    final Map<String, Object?> missingEngine = _canonicalManifest();
    (missingEngine['engine']! as Map<String, Object?>).remove('engineCommit');
    expect(
      AppManifest.decode(jsonEncode(missingEngine)).errorOrNull?.message,
      'engine.engineCommit: is required',
    );

    final Map<String, Object?> unknownDisplay = _canonicalManifest();
    (unknownDisplay['display']! as Map<String, Object?>)['dpi'] = 226;
    expect(
      AppManifest.decode(jsonEncode(unknownDisplay)).errorOrNull?.message,
      'display.dpi: is not supported',
    );

    final Map<String, Object?> missingLaunch = _canonicalManifest();
    (missingLaunch['launch']! as Map<String, Object?>).remove('args');
    expect(
      AppManifest.decode(jsonEncode(missingLaunch)).errorOrNull?.message,
      'launch.args: is required',
    );
  });

  test('field validation rejects invalid id, path, and display defaults', () {
    final Map<String, Object?> badId = _canonicalManifest()..['id'] = 'Bad';
    final Map<String, Object?> badPath = _canonicalManifest()
      ..['icon'] = '../icon.png';
    final Map<String, Object?> badDisplay = _canonicalManifest();
    (badDisplay['display']! as Map<String, Object?>)['defaultOrientation'] =
        'landscapeRight';

    for (final Map<String, Object?> document in <Map<String, Object?>>[
      badId,
      badPath,
      badDisplay,
    ]) {
      expect(
        AppManifest.decode(jsonEncode(document)).errorOrNull,
        isA<ManifestFieldError>(),
      );
    }
  });

  test('install record has one exact unversioned shape', () {
    final Map<String, Object?> document = _installRecord();
    final Result<InstallRecord, ManifestError> result = InstallRecord.decode(
      jsonEncode(document),
    );

    expect(result.isOk, isTrue);
    expect(result.valueOrNull!.appId.value, 'dev.example.app');
    expect(result.valueOrNull!.payload['manifest.json'], 'sha256:abc');

    const List<String> requiredKeys = <String>[
      'appId',
      'installedAt',
      'installedBy',
      'source',
      'buildMode',
      'engineFlavor',
      'sizeBytes',
      'payload',
    ];
    for (final String key in requiredKeys) {
      final Map<String, Object?> missing = _installRecord()..remove(key);
      expect(
        InstallRecord.decode(jsonEncode(missing)).errorOrNull?.message,
        '$key: is required',
        reason: key,
      );
    }

    for (final String field in <String>['schema', 'version', 'format']) {
      final Map<String, Object?> versioned = _installRecord()..[field] = 1;
      expect(
        InstallRecord.decode(jsonEncode(versioned)).errorOrNull?.message,
        '$field: is not supported',
        reason: field,
      );
    }
  });

  test('install record validates identity, sizes, and payload values', () {
    final Map<String, Object?> badId = _installRecord()..['appId'] = '../bad';
    final Map<String, Object?> badSize = _installRecord()..['sizeBytes'] = -1;
    final Map<String, Object?> badPayload = _installRecord()
      ..['payload'] = <String, Object?>{'manifest.json': 42};

    expect(
      InstallRecord.decode(jsonEncode(badId)).errorOrNull?.message,
      startsWith('appId:'),
    );
    expect(
      InstallRecord.decode(jsonEncode(badSize)).errorOrNull?.message,
      'sizeBytes: must not be negative',
    );
    expect(
      InstallRecord.decode(jsonEncode(badPayload)).errorOrNull?.message,
      'payload.manifest.json: must be a string hash',
    );
  });

  test('installed app exposes typed build state', () {
    final InstalledApp app = InstalledApp(
      manifest: AppManifest.decode(
        jsonEncode(_canonicalManifest()),
      ).valueOrNull!,
      record: InstallRecord.decode(jsonEncode(_installRecord())).valueOrNull!,
      appDir: '/home/root/pluto/apps/dev.example.app',
      dataDir: '/home/root/pluto/appdata/dev.example.app',
    );

    expect(app.isDevInstall, isTrue);
    expect(app.manifest.id, app.record.appId);
  });
}

Map<String, Object?> _canonicalManifest({
  String id = 'dev.example.app',
  String name = 'Example',
  List<Object?> permissions = const <Object?>[],
  String refreshProfile = 'ui',
}) => <String, Object?>{
  'id': id,
  'name': name,
  'version': '1.2.0',
  'icon': 'icon.png',
  'runtime': <String, Object?>{
    'type': 'flutter-aot',
    'appElf': 'lib/app.so',
    'assets': 'flutter_assets',
  },
  'engine': <String, Object?>{
    'flutterVersion': '3.44.4',
    'engineCommit': _engineCommit,
  },
  'permissions': permissions,
  'display': <String, Object?>{
    'orientations': <Object?>['portrait', 'landscapeLeft'],
    'defaultOrientation': 'portrait',
    'scale': 'auto',
    'color': 'auto',
    'refreshProfile': refreshProfile,
  },
  'launch': <String, Object?>{'singleInstance': true, 'args': <Object?>[]},
};

Map<String, Object?> _installRecord() => <String, Object?>{
  'appId': 'dev.example.app',
  'installedAt': '2026-07-06T14:22:41Z',
  'installedBy': 'pluto 0.1.0',
  'source': 'pluto-cli',
  'buildMode': 'debug',
  'engineFlavor': 'debug',
  'sizeBytes': 42,
  'payload': <String, Object?>{'manifest.json': 'sha256:abc'},
};
