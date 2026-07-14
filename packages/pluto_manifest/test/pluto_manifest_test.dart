import 'package:pluto_manifest/pluto_manifest.dart';
import 'package:test/test.dart';

void main() {
  const String engineCommit = 'a10d8ac38de835021c8d2f920dbf50a920ccc030';

  test('canonical JSON round-trips with defaults', () {
    const String source =
        '''
{
  "schema": 1,
  "id": "dev.example.sketchpad",
  "name": "Sketchpad",
  "version": "1.2.0",
  "runtime": {
    "type": "flutter-aot",
    "appElf": "lib/app.so",
    "assets": "flutter_assets"
  },
  "engine": {
    "flutterVersion": "3.44.4",
    "engineCommit": "$engineCommit",
    "plutoAbi": 1
  },
  "permissions": ["pen.raw", "touch.raw"],
  "display": {
    "orientations": ["portrait", "landscapeLeft"],
    "defaultOrientation": "portrait",
    "scale": 1.65,
    "color": "auto",
    "refreshProfile": "drawing"
  }
}
''';

    final Result<AppManifest, ManifestError> result = AppManifest.decode(
      source,
    );
    final AppManifest manifest = result.valueOrNull!;
    final Result<AppManifest, ManifestError> roundTrip = AppManifest.decode(
      manifest.encode(),
    );

    expect(result.isOk, isTrue);
    expect(roundTrip.isOk, isTrue);
    expect(manifest.id.value, 'dev.example.sketchpad');
    expect(manifest.permissions, contains(AppPermission.penRaw));
    expect(manifest.display.scale, 1.65);
    expect(manifest.display.usesAutomaticScale, isFalse);
    expect(manifest.encode(), contains('"scale":1.65'));
    expect(manifest.display.refreshProfile, DisplayRefreshProfile.drawing);
  });

  test('automatic display scale defaults and round-trips canonically', () {
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
schema: 1
id: dev.example.responsive
name: Responsive
version: 1.0.0
$displaySource
''',
            runtime: const FlutterAotRuntime(),
            engine: const EngineRequirement(
              flutterVersion: '3.44.4',
              engineCommit: engineCommit,
              plutoAbi: 1,
            ),
          );

      expect(result.isOk, isTrue, reason: displaySource);
      final AppManifest manifest = result.valueOrNull!;
      expect(manifest.display.scale, isNull, reason: displaySource);
      expect(
        manifest.display.usesAutomaticScale,
        isTrue,
        reason: displaySource,
      );
      final String encoded = manifest.encode();
      expect(encoded, contains('"scale":"auto"'), reason: displaySource);

      final AppManifest roundTrip = AppManifest.decode(encoded).valueOrNull!;
      expect(roundTrip.display.scale, isNull, reason: displaySource);
      expect(roundTrip.display.usesAutomaticScale, isTrue);
      expect(roundTrip.encode(), encoded);
    }
  });

  test('authored YAML is stamped and validated', () {
    const String source = '''
schema: 1
id: dev.example.notes
name: Notes
version: 0.1.0
permissions:
  - settings.read
display:
  orientations: [portrait]
''';

    final Result<AppManifest, ManifestError> result =
        AppManifest.decodeAuthoredYaml(
          source,
          runtime: const FlutterKernelRuntime(),
          engine: const EngineRequirement(
            flutterVersion: '3.44.4',
            engineCommit: engineCommit,
            plutoAbi: 1,
          ),
        );

    expect(result.isOk, isTrue);
    expect(result.valueOrNull!.runtime.kind, AppRuntimeKind.flutterKernel);
  });

  test('legacy enum runtime names decode and re-encode canonically', () {
    for (final (String, AppRuntimeKind, String) fixture
        in <(String, AppRuntimeKind, String)>[
          ('flutterAot', AppRuntimeKind.flutterAot, '"type":"flutter-aot"'),
          (
            'flutterKernel',
            AppRuntimeKind.flutterKernel,
            '"type":"flutter-kernel"',
          ),
        ]) {
      final String runtimeFields = fixture.$2 == AppRuntimeKind.flutterAot
          ? '"appElf":"lib/app.so","assets":"flutter_assets"'
          : '"assets":"flutter_assets"';
      final Result<AppManifest, ManifestError> result = AppManifest.decode('''
{
  "schema": 1,
  "id": "dev.example.legacy",
  "name": "Legacy",
  "version": "1.0.0",
  "runtime": {"type":"${fixture.$1}",$runtimeFields},
  "engine": {
    "flutterVersion": "3.44.4",
    "engineCommit": "$engineCommit",
    "plutoAbi": 1
  }
}
''');

      expect(result.isOk, isTrue, reason: fixture.$1);
      expect(result.valueOrNull?.runtime.kind, fixture.$2);
      expect(result.valueOrNull?.encode(), contains(fixture.$3));
    }
  });

  test('runtime compatibility aliases do not weaken enum validation', () {
    final Result<AppManifest, ManifestError> result = AppManifest.decode('''
{
  "schema": 1,
  "id": "dev.example.lookalike",
  "name": "Lookalike",
  "version": "1.0.0",
  "runtime": {
    "type": "FlutterAot",
    "appElf": "lib/app.so",
    "assets": "flutter_assets"
  },
  "engine": {
    "flutterVersion": "3.44.4",
    "engineCommit": "$engineCommit",
    "plutoAbi": 1
  }
}
''');

    expect(result.errorOrNull, isA<ManifestFieldError>());
    expect(result.errorOrNull?.message, 'runtime.type: unknown runtime type');
  });

  test('unknown permissions and newer schemas are rejected', () {
    final Result<AppManifest, ManifestError> unknown = AppManifest.decode('''
{
  "schema": 1,
  "id": "dev.example.bad",
  "name": "Bad",
  "version": "1.0.0",
  "runtime": {"type": "flutter-kernel", "assets": "flutter_assets"},
  "engine": {
    "flutterVersion": "3.44.4",
    "engineCommit": "$engineCommit",
    "plutoAbi": 1
  },
  "permissions": ["typo.permission"]
}
''');

    final Result<AppManifest, ManifestError> tooNew = AppManifest.decode(
      '{"schema": 2}',
    );

    expect(unknown.errorOrNull, isA<ManifestUnknownPermission>());
    expect(tooNew.errorOrNull, isA<ManifestSchemaTooNew>());
  });

  test('field validation rejects invalid id, path, and display defaults', () {
    final Result<AppManifest, ManifestError> badId = AppManifest.decode('''
{
  "schema": 1,
  "id": "Bad",
  "name": "Bad",
  "version": "1.0.0",
  "runtime": {"type": "flutter-kernel", "assets": "flutter_assets"},
  "engine": {
    "flutterVersion": "3.44.4",
    "engineCommit": "$engineCommit",
    "plutoAbi": 1
  }
}
''');
    final Result<AppManifest, ManifestError> badPath = AppManifest.decode('''
{
  "schema": 1,
  "id": "dev.example.badpath",
  "name": "Bad",
  "version": "1.0.0",
  "icon": "../icon.png",
  "runtime": {"type": "flutter-kernel", "assets": "flutter_assets"},
  "engine": {
    "flutterVersion": "3.44.4",
    "engineCommit": "$engineCommit",
    "plutoAbi": 1
  }
}
''');
    final Result<AppManifest, ManifestError> badDisplay = AppManifest.decode('''
{
  "schema": 1,
  "id": "dev.example.baddisplay",
  "name": "Bad",
  "version": "1.0.0",
  "runtime": {"type": "flutter-kernel", "assets": "flutter_assets"},
  "engine": {
    "flutterVersion": "3.44.4",
    "engineCommit": "$engineCommit",
    "plutoAbi": 1
  },
  "display": {
    "orientations": ["portrait"],
    "defaultOrientation": "landscapeLeft"
  }
}
''');

    expect(badId.errorOrNull, isA<ManifestFieldError>());
    expect(badPath.errorOrNull, isA<ManifestFieldError>());
    expect(badDisplay.errorOrNull, isA<ManifestFieldError>());
  });

  test('install record and installed app parse typed values', () {
    final Result<InstallRecord, ManifestError> record = InstallRecord.decode('''
{
  "schema": 1,
  "installedAt": "2026-07-06T14:22:41Z",
  "installedBy": "pluto 0.1.0",
  "source": "pluto-cli",
  "buildMode": "debug",
  "engineFlavor": "debug",
  "sizeBytes": 42,
  "payload": {"manifest.json": "sha256:abc"}
}
''');

    final InstalledApp app = InstalledApp(
      manifest: AppManifest.decodeAuthoredYaml(
        'schema: 1\nid: dev.example.app\nname: App\nversion: 1.0.0\n',
        runtime: const FlutterKernelRuntime(),
        engine: const EngineRequirement(
          flutterVersion: '3.44.4',
          engineCommit: engineCommit,
          plutoAbi: 1,
        ),
      ).valueOrNull!,
      record: record.valueOrNull!,
      appDir: '/home/root/pluto/apps/dev.example.app',
      dataDir: '/home/root/pluto/appdata/dev.example.app',
    );

    expect(record.isOk, isTrue);
    expect(record.valueOrNull!.payload['manifest.json'], 'sha256:abc');
    expect(app.isDevInstall, isTrue);
  });
}
