import 'dart:convert';
import 'dart:io';

import 'package:pluto_cli/pluto.dart';
import 'package:test/test.dart';

const String _engineHash = 'a10d8ac38de835021c8d2f920dbf50a920ccc030';

void main() {
  test(
    'release build emits product AOT and removes every JIT payload',
    () async {
      final _BuildFixture fixture = _BuildFixture();
      addTearDown(fixture.dispose);

      final BuildOutput output = await fixture.adapter.build(
        BuildRequest(
          projectDirectory: fixture.project.path,
          targetFile: 'lib/main.dart',
          mode: PlutoBuildMode.release,
          outputDirectory: 'build/pluto/release',
          dartDefines: const <String>['EXAMPLE=yes'],
        ),
      );

      expect(
        File('${output.outputDirectory}/bundle/lib/app.so').existsSync(),
        isTrue,
      );
      expect(
        File(
          '${output.outputDirectory}/bundle/flutter_assets/kernel_blob.bin',
        ).existsSync(),
        isFalse,
      );
      final Map<String, Object?> manifest =
          jsonDecode(
                File(
                  '${output.outputDirectory}/manifest.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(
        (manifest['runtime'] as Map<String, Object?>)['type'],
        'flutter-aot',
      );
      expect(
        fixture.host.commands.any(
          (List<String> command) => command.contains('linux/arm64'),
        ),
        isTrue,
        reason: 'non-Linux/AArch64 hosts run only gen_snapshot in Docker',
      );
      expect(
        fixture.host.commands.firstWhere(
          (List<String> command) => command.contains('bundle'),
        ),
        contains('--release'),
      );
    },
  );

  test(
    'profile fails instead of falling back when profile AOT is absent',
    () async {
      final _BuildFixture fixture = _BuildFixture();
      addTearDown(fixture.dispose);

      await expectLater(
        fixture.adapter.build(
          BuildRequest(
            projectDirectory: fixture.project.path,
            targetFile: 'lib/main.dart',
            mode: PlutoBuildMode.profile,
            outputDirectory: 'build/pluto/profile',
          ),
        ),
        throwsA(
          isA<ArtifactVerificationException>().having(
            (ArtifactVerificationException error) => error.message,
            'message',
            allOf(contains('profile'), contains('Missing hash-matched')),
          ),
        ),
      );
      expect(
        fixture.host.commands.any(
          (List<String> command) => command.contains('gen_snapshot'),
        ),
        isFalse,
      );
    },
  );

  test('linux-arm release selects ARM artifacts and records target', () async {
    final _BuildFixture fixture = _BuildFixture(
      targetPlatform: PlutoTargetPlatform.linuxArm,
    );
    addTearDown(fixture.dispose);

    final BuildOutput output = await fixture.adapter.build(
      BuildRequest(
        projectDirectory: fixture.project.path,
        targetFile: 'lib/main.dart',
        mode: PlutoBuildMode.release,
        outputDirectory: 'build/pluto/release-arm',
        targetPlatform: PlutoTargetPlatform.linuxArm,
      ),
    );

    final BuildLayoutMetadata metadata = BuildLayoutMetadata.read(
      output.outputDirectory,
    );
    expect(metadata.target, PlutoTargetPlatform.linuxArm.cliName);
    metadata.validate(
      output.outputDirectory,
      expectedTargetPlatform: PlutoTargetPlatform.linuxArm,
    );
    expect(
      fixture.host.commands
          .firstWhere((List<String> command) => command.contains('bundle'))
          .contains('--target-platform=linux-arm64'),
      isTrue,
      reason: 'Flutter Tools has no linux-arm assets-only target',
    );
    expect(
      fixture.host.commands
          .expand((List<String> command) => command)
          .any(
            (String argument) =>
                argument.contains('linux-arm-release:/artifacts:ro'),
          ),
      isTrue,
    );
  });

  test('linux-arm rejects profile before invoking build tools', () async {
    final _BuildFixture fixture = _BuildFixture(
      targetPlatform: PlutoTargetPlatform.linuxArm,
    );
    addTearDown(fixture.dispose);

    await expectLater(
      fixture.adapter.build(
        BuildRequest(
          projectDirectory: fixture.project.path,
          targetFile: 'lib/main.dart',
          mode: PlutoBuildMode.profile,
          outputDirectory: 'build/pluto/profile-arm',
          targetPlatform: PlutoTargetPlatform.linuxArm,
        ),
      ),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('release AOT'),
        ),
      ),
    );
    expect(fixture.host.commands, isEmpty);
  });

  test(
    'authored target contract rejects unsupported linux-arm before tools',
    () async {
      final _BuildFixture fixture = _BuildFixture(
        targetPlatform: PlutoTargetPlatform.linuxArm,
        authoredTargets: const <String>['linux-arm64'],
      );
      addTearDown(fixture.dispose);

      await expectLater(
        fixture.adapter.build(
          BuildRequest(
            projectDirectory: fixture.project.path,
            targetFile: 'lib/main.dart',
            mode: PlutoBuildMode.release,
            outputDirectory: 'build/pluto/release-arm',
            targetPlatform: PlutoTargetPlatform.linuxArm,
          ),
        ),
        throwsA(
          isA<ArtifactVerificationException>().having(
            (ArtifactVerificationException error) => error.message,
            'message',
            allOf(contains('Example'), contains('does not support linux-arm')),
          ),
        ),
      );
      expect(fixture.host.commands, isEmpty);
    },
  );

  test('build metadata is unversioned, exact, and strictly decoded', () {
    final Directory temp = Directory.systemTemp.createTempSync(
      'pluto-build-metadata-',
    );
    addTearDown(() => temp.deleteSync(recursive: true));
    const BuildLayoutMetadata metadata = BuildLayoutMetadata(
      buildMode: PlutoBuildMode.release,
      engineFlavor: 'release',
      flutterVersion: '3.44.4',
      engineCommit: _engineHash,
    );
    metadata.write(temp.path);
    final File file = File('${temp.path}/${BuildLayoutMetadata.fileName}');
    final Map<String, Object?> canonical =
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    expect(canonical.keys.toSet(), <String>{
      'buildMode',
      'engineFlavor',
      'flutterVersion',
      'engineCommit',
      'target',
    });
    expect(canonical, isNot(contains('schema')));
    expect(canonical, isNot(contains('format')));
    expect(canonical, isNot(contains('version')));
    expect(BuildLayoutMetadata.read(temp.path).target, 'linux-arm64');

    final List<(String, Map<String, Object?>)>
    invalid = <(String, Map<String, Object?>)>[
      ('schema', <String, Object?>{...canonical, 'schema': 1}),
      ('format version', <String, Object?>{...canonical, 'formatVersion': 1}),
      ('unknown field', <String, Object?>{...canonical, 'legacy': true}),
      ('missing field', <String, Object?>{...canonical}..remove('target')),
      ('wrong type', <String, Object?>{...canonical, 'flutterVersion': 3444}),
      (
        'unknown target',
        <String, Object?>{...canonical, 'target': 'remarkable-2'},
      ),
    ];
    for (final (String name, Map<String, Object?> document) in invalid) {
      file.writeAsStringSync(jsonEncode(document));
      expect(
        () => BuildLayoutMetadata.read(temp.path),
        throwsA(isA<ArtifactVerificationException>()),
        reason: name,
      );
    }
  });

  test('release rejects a committed artifact with a stale checksum', () async {
    final _BuildFixture fixture = _BuildFixture();
    addTearDown(fixture.dispose);
    File(
      '${fixture.releaseArtifacts.path}/icudtl.dat',
    ).writeAsStringSync('changed');

    await expectLater(
      fixture.adapter.build(
        BuildRequest(
          projectDirectory: fixture.project.path,
          targetFile: 'lib/main.dart',
          mode: PlutoBuildMode.release,
          outputDirectory: 'build/pluto/release',
        ),
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

  test('release rejects a manifest whose icon is missing', () async {
    final _BuildFixture fixture = _BuildFixture();
    addTearDown(fixture.dispose);
    File('${fixture.project.path}/icon.png').deleteSync();

    await expectLater(
      fixture.adapter.build(
        BuildRequest(
          projectDirectory: fixture.project.path,
          targetFile: 'lib/main.dart',
          mode: PlutoBuildMode.release,
          outputDirectory: 'build/pluto/release',
        ),
      ),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('Manifest asset does not exist'),
        ),
      ),
    );
    expect(
      fixture.host.commands,
      isEmpty,
      reason: 'missing authored assets must fail before invoking Flutter',
    );
  });

  test(
    'layout validation rejects a removed declared icon or iconMono',
    () async {
      final _BuildFixture fixture = _BuildFixture();
      addTearDown(fixture.dispose);
      final BuildOutput output = await fixture.adapter.build(
        BuildRequest(
          projectDirectory: fixture.project.path,
          targetFile: 'lib/main.dart',
          mode: PlutoBuildMode.release,
          outputDirectory: 'build/pluto/release',
        ),
      );
      final BuildLayoutMetadata metadata = BuildLayoutMetadata.read(
        output.outputDirectory,
      );
      final File icon = File('${output.outputDirectory}/icon.png');

      icon.deleteSync();
      expect(
        () => metadata.validate(output.outputDirectory),
        throwsA(
          isA<ArtifactVerificationException>().having(
            (ArtifactVerificationException error) => error.message,
            'message',
            allOf(
              contains('manifest-declared icon asset'),
              contains('icon.png'),
            ),
          ),
        ),
      );

      icon.writeAsBytesSync(<int>[0x89, 0x50, 0x4e, 0x47]);
      final File manifestFile = File('${output.outputDirectory}/manifest.json');
      final Map<String, Object?> manifest =
          jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>;
      manifest['iconMono'] = 'icon-mono.png';
      manifestFile.writeAsStringSync(jsonEncode(manifest));
      expect(
        () => metadata.validate(output.outputDirectory),
        throwsA(
          isA<ArtifactVerificationException>().having(
            (ArtifactVerificationException error) => error.message,
            'message',
            allOf(
              contains('manifest-declared iconMono asset'),
              contains('icon-mono.png'),
            ),
          ),
        ),
      );
    },
  );

  test('layout validation rejects profile app.so relabelled as release', () {
    final Directory temp = Directory.systemTemp.createTempSync(
      'pluto-layout-mode-',
    );
    addTearDown(() => temp.deleteSync(recursive: true));
    File('${temp.path}/manifest.json').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'id': 'dev.example.app',
        'name': 'Example',
        'version': '1.0.0',
        'icon': 'icon.png',
        'runtime': <String, Object?>{
          'type': 'flutter-aot',
          'appElf': 'lib/app.so',
          'assets': 'flutter_assets',
        },
        'engine': <String, Object?>{
          'flutterVersion': '3.44.4',
          'engineCommit': _engineHash,
        },
        'targets': <Object?>['linux-arm', 'linux-arm64'],
        'permissions': <Object?>[],
        'display': <String, Object?>{
          'orientations': <Object?>['portrait'],
          'defaultOrientation': 'portrait',
          'scale': 'auto',
          'color': 'auto',
          'refreshProfile': 'ui',
        },
        'launch': <String, Object?>{
          'singleInstance': true,
          'args': <Object?>[],
        },
      }),
    );
    File(
      '${temp.path}/icon.png',
    ).writeAsBytesSync(<int>[0x89, 0x50, 0x4e, 0x47]);
    File('${temp.path}/bundle/flutter_assets/AssetManifest.bin')
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1]);
    File('${temp.path}/bundle/lib/app.so')
      ..createSync(recursive: true)
      ..writeAsBytesSync(_profileAarch64Elf());
    const BuildLayoutMetadata metadata = BuildLayoutMetadata(
      buildMode: PlutoBuildMode.release,
      engineFlavor: 'release',
      flutterVersion: '3.44.4',
      engineCommit: _engineHash,
    );

    expect(
      () => metadata.validate(temp.path),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('product/dedup_instructions'),
        ),
      ),
    );
  });
}

final class _BuildFixture {
  _BuildFixture({
    this.targetPlatform = PlutoTargetPlatform.linuxArm64,
    this.authoredTargets,
  }) {
    Directory('$rootPath/tools/pluto/pins').createSync(recursive: true);
    File(
      '$rootPath/tools/pluto/pins/flutter.version',
    ).writeAsStringSync('3.44.4');
    File(
      '$rootPath/tools/pluto/pins/engine.version',
    ).writeAsStringSync(_engineHash);
    File(
      '$rootPath/tools/pluto/pins/supported_os.json',
    ).writeAsStringSync('{"supportedOsBuilds":[]}');

    File('$sdkPath/bin/flutter')
      ..createSync(recursive: true)
      ..writeAsStringSync('flutter');
    File('$sdkPath/bin/cache/engine.stamp')
      ..createSync(recursive: true)
      ..writeAsStringSync(_engineHash);
    for (final String path in <String>[
      '$sdkPath/bin/cache/dart-sdk/bin/dartaotruntime',
      '$sdkPath/bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot',
    ]) {
      File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync('tool');
    }
    Directory(
      '$sdkPath/bin/cache/artifacts/engine/common/flutter_patched_sdk_product',
    ).createSync(recursive: true);
    Directory(
      '$sdkPath/bin/cache/artifacts/engine/common/flutter_patched_sdk',
    ).createSync(recursive: true);

    File('${project.path}/pubspec.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('name: example\n');
    File('${project.path}/lib/main.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}\n');
    final String targetsYaml = authoredTargets == null
        ? ''
        : '\ntargets:\n'
              '${authoredTargets!.map((String target) => '  - $target').join('\n')}\n';
    File('${project.path}/pluto.yaml').writeAsStringSync('''
id: dev.example.app
name: Example
version: 1.0.0
${targetsYaml.trimRight()}
''');
    File(
      '${project.path}/icon.png',
    ).writeAsBytesSync(<int>[0x89, 0x50, 0x4e, 0x47]);
    File('${project.path}/.dart_tool/package_config.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"configVersion":2,"packages":[]}');

    releaseArtifacts.createSync(recursive: true);
    final Map<String, String> contents = <String, String>{
      'libflutter_engine.so': 'engine',
      'gen_snapshot': 'snapshotter',
      'icudtl.dat': 'icu',
    };
    for (final MapEntry<String, String> entry in contents.entries) {
      File(
        '${releaseArtifacts.path}/${entry.key}',
      ).writeAsStringSync(entry.value);
    }
    File('${releaseArtifacts.path}/CHECKSUMS.txt').writeAsStringSync('''
schema=1
flutter=3.44.4
engine=$_engineHash
target=${targetPlatform.cliName}
mode=release

${sha256Bytes(utf8.encode(contents['gen_snapshot']!))}  gen_snapshot
${sha256Bytes(utf8.encode(contents['icudtl.dat']!))}  icudtl.dat
${sha256Bytes(utf8.encode(contents['libflutter_engine.so']!))}  libflutter_engine.so
''');
  }

  final PlutoTargetPlatform targetPlatform;

  final List<String>? authoredTargets;

  final Directory temp = Directory.systemTemp.createTempSync('pluto-aot-test-');

  late final String rootPath = temp.path;

  late final String sdkPath = '$rootPath/sdk';

  late final Directory project = Directory('$rootPath/app')..createSync();

  late final Directory releaseArtifacts = Directory(
    '$rootPath/third_party/engine/$_engineHash/'
    '${targetPlatform.cliName}-release',
  );

  late final _BuildHostEnvironment host = _BuildHostEnvironment(targetPlatform);

  late final PlutoCliEnvironment environment = PlutoCliEnvironment(
    paths: PlutoPaths(
      packageRoot: '$rootPath/tools/pluto',
      homeDirectory: rootPath,
      repositoryRootOverride: rootPath,
    ),
    hostEnvironment: host,
    transportFactory: (DeviceEndpoint endpoint) =>
        FakeTransport(endpoint: endpoint),
    out: StringBuffer(),
    err: StringBuffer(),
  );

  late final LiveFlutterToolsBuildAdapter adapter =
      LiveFlutterToolsBuildAdapter(
        environment: environment,
        flutterSdkOverride: sdkPath,
      );

  void dispose() => temp.deleteSync(recursive: true);
}

final class _BuildHostEnvironment implements HostEnvironment {
  _BuildHostEnvironment(this.targetPlatform);

  final PlutoTargetPlatform targetPlatform;

  final List<List<String>> commands = <List<String>>[];

  @override
  String? executablePath(String executable) =>
      executable == 'docker' ? '/usr/local/bin/docker' : null;

  @override
  Future<CommandResult> run(
    List<String> command, {
    Duration timeout = const Duration(seconds: 30),
    Map<String, String> environment = const <String, String>{},
    String? workingDirectory,
  }) async {
    commands.add(List<String>.of(command));
    if (command.first == 'uname') {
      return const CommandResult(exitCode: 0, stdout: 'arm64\n');
    }
    if (command.length > 2 && command[1] == 'build' && command[2] == 'bundle') {
      final String assets = command
          .firstWhere((String value) => value.startsWith('--asset-dir='))
          .substring('--asset-dir='.length);
      File('$assets/kernel_blob.bin')
        ..createSync(recursive: true)
        ..writeAsStringSync('must be removed');
      File('$assets/AssetManifest.bin').writeAsBytesSync(<int>[0]);
      return const CommandResult(exitCode: 0);
    }
    if (command.first.endsWith('/dartaotruntime')) {
      final int output = command.indexOf('--output-dill');
      File(command[output + 1]).writeAsStringSync('dill');
      return const CommandResult(exitCode: 0);
    }
    if (command.contains('linux/arm64')) {
      final String mount = command.firstWhere(
        (String value) => value.endsWith(':/build'),
      );
      final String build = mount.substring(0, mount.length - ':/build'.length);
      File('$build/app.so').writeAsBytesSync(
        targetPlatform == PlutoTargetPlatform.linuxArm
            ? _productArmElf()
            : _productAarch64Elf(),
      );
      return const CommandResult(exitCode: 0);
    }
    return const CommandResult(exitCode: 0);
  }

  @override
  bool fileExists(String path) => File(path).existsSync();

  @override
  bool directoryExists(String path) => Directory(path).existsSync();

  @override
  String readTextFile(String path) => File(path).readAsStringSync();

  @override
  String? environmentVariable(String name) => null;

  @override
  String get operatingSystem => 'macos';
}

List<int> _productAarch64Elf() {
  return _aarch64Elf(
    'product no-code_comments dedup_instructions no-asan arm64 linux',
  );
}

List<int> _profileAarch64Elf() {
  return _aarch64Elf(
    'release no-code_comments no-dedup_instructions no-asan arm64 linux',
  );
}

List<int> _productArmElf() {
  return _armElf(
    'product no-code_comments dedup_instructions no-asan arm linux',
  );
}

List<int> _armElf(String features) {
  final List<int> bytes = List<int>.filled(64, 0);
  bytes
    ..[0] = 0x7f
    ..[1] = 0x45
    ..[2] = 0x4c
    ..[3] = 0x46
    ..[4] = 1
    ..[5] = 1
    ..[18] = 0x28
    ..[37] = 0x04
    ..[39] = 0x05;
  return <int>[
    ...bytes,
    ...latin1.encode('ace654289f5abc240509fc941453ebc5$features\u0000'),
  ];
}

List<int> _aarch64Elf(String features) {
  final List<int> bytes = List<int>.filled(64, 0);
  bytes
    ..[0] = 0x7f
    ..[1] = 0x45
    ..[2] = 0x4c
    ..[3] = 0x46
    ..[4] = 2
    ..[5] = 1
    ..[18] = 0xb7;
  return <int>[
    ...bytes,
    ...latin1.encode('ace654289f5abc240509fc941453ebc5$features\u0000'),
  ];
}
