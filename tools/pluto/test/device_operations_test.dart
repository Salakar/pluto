import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pluto_cli/src/build/package_builder.dart';
import 'package:pluto_cli/src/build/plap_reader.dart';
import 'package:pluto_cli/src/artifacts/checksums.dart';
import 'package:pluto_cli/src/errors.dart';
import 'package:pluto_cli/src/process.dart';
import 'package:pluto_cli/src/run/device_operations.dart';
import 'package:pluto_cli/src/ssh/device_transport.dart';
import 'package:pluto_cli/src/ssh/fake_transport.dart';
import 'package:test/test.dart';

import 'support/aot_fixture.dart';

const String root = LiveDeviceOperations.defaultDeviceRoot;
const String _engineCommit = 'a10d8ac38de835021c8d2f920dbf50a920ccc030';
const List<int> _armIconBytes = <int>[0x41, 0x52, 0x4d];
const List<int> _arm64IconBytes = <int>[0x41, 0x52, 0x4d, 0x36, 0x34];

FakeTransport _deviceTransport(
  String host, {
  String machine = 'imx93-chiappa',
  String architecture = 'aarch64',
  String? compatible,
  String firmwareBuild = '20260629074044',
  String firmwareVersion = '3.28.0.162',
  String? kernelRelease,
  bool kernelReleaseAvailable = true,
  Future<CommandResult> Function(String command)? execHandler,
  FakeDownloadHandler? downloadHandler,
}) => FakeTransport(
  endpoint: DeviceEndpoint(host: host),
  downloadHandler: downloadHandler,
  execHandler: (String command) async {
    if (command == 'cat /sys/devices/soc0/machine') {
      return CommandResult(exitCode: 0, stdout: machine);
    }
    if (command == 'uname -m') {
      return CommandResult(exitCode: 0, stdout: architecture);
    }
    if (command == 'uname -r') {
      if (!kernelReleaseAvailable) {
        return const CommandResult(exitCode: 1);
      }
      final String normalizedMachine = machine.toLowerCase();
      return CommandResult(
        exitCode: 0,
        stdout:
            kernelRelease ??
            (normalizedMachine.contains('remarkable 1') ||
                    normalizedMachine.contains('zero-gravitas')
                ? '5.4.70-v1.6.3-rm10x'
                : normalizedMachine.contains('chiappa')
                ? '6.12.49+git-imx93-chiappa-gf4c2ab7040e8'
                : '5.4.70-v1.6.3-rm11x'),
      );
    }
    if (command == 'cat /proc/device-tree/compatible') {
      return CommandResult(
        exitCode: 0,
        stdout:
            compatible ??
            (machine.toLowerCase().contains('chiappa')
                ? 'fsl,imx93'
                : machine.toLowerCase().contains('remarkable 1') ||
                      machine.toLowerCase().contains('zero-gravitas')
                ? 'remarkable,zero-gravitas\u0000fsl,imx6sl'
                : 'fsl,imx7d-sdb\u0000fsl,imx7d'),
      );
    }
    if (command == 'cat /etc/version') {
      return CommandResult(exitCode: 0, stdout: firmwareBuild);
    }
    if (command == 'cat /usr/share/remarkable/update.conf') {
      return CommandResult(
        exitCode: 0,
        stdout: 'REMARKABLE_RELEASE_VERSION=$firmwareVersion\n',
      );
    }
    return execHandler?.call(command) ?? const CommandResult(exitCode: 0);
  },
);

FakeTransport _moveTransport(
  String host, {
  Future<CommandResult> Function(String command)? execHandler,
  FakeDownloadHandler? downloadHandler,
}) => _deviceTransport(
  host,
  execHandler: execHandler,
  downloadHandler: downloadHandler,
);

Uint8List _pngHeaderFixture(int width, int height) {
  final Uint8List bytes = Uint8List(24);
  bytes.setRange(0, 8, const <int>[137, 80, 78, 71, 13, 10, 26, 10]);
  final ByteData data = ByteData.sublistView(bytes);
  data.setUint32(8, 13, Endian.big);
  data.setUint32(12, 0x49484452, Endian.big);
  data.setUint32(16, width, Endian.big);
  data.setUint32(20, height, Endian.big);
  return bytes;
}

FakeTransport _screenshotTransport({
  required Uint8List png,
  int pid = 4242,
  String appId = 'dev.example.notes',
  String surface = 'logical',
  int width = 37,
  int height = 29,
  int stride = 80,
  String format = 'rgb565',
  String path = '/run/pluto/screenshots/direct-4242-1.png',
  Map<String, Object?> metadataOverrides = const <String, Object?>{},
  Map<String, Object?> responseOverrides = const <String, Object?>{},
  String? responseRequestId,
  CommandResult? postflightResult,
  Uint8List? downloadedPng,
  void Function(Map<String, Object?> request)? onRequest,
  Future<CommandResult> Function(String command)? foregroundHandler,
}) {
  return _moveTransport(
    'device',
    execHandler: (String command) async {
      if (command.contains('PLUTO-FOREGROUND-PID|%s')) {
        if (foregroundHandler != null) {
          return foregroundHandler(command);
        }
        return CommandResult(
          exitCode: 0,
          stdout: 'PLUTO-FOREGROUND-PID|$pid\n',
        );
      }
      if (command.contains('pluto-controlctl') &&
          command.contains('embedder-control.sock') &&
          command.contains('--request')) {
        final RegExpMatch? match = RegExp(
          r"--request '([^']+)'",
        ).firstMatch(command);
        if (match == null) {
          return const CommandResult(exitCode: 64, stderr: 'missing request');
        }
        final Map<String, Object?> request =
            jsonDecode(match.group(1)!) as Map<String, Object?>;
        onRequest?.call(request);
        return CommandResult(
          exitCode: 0,
          stdout: jsonEncode(<String, Object?>{
            'requestId': responseRequestId ?? request['requestId'],
            'ok': true,
            'result': <String, Object?>{
              'path': path,
              'bytes': png.length,
              'sha256': sha256Bytes(png),
              'appId': appId,
              'pid': pid,
              'surface': surface,
              'width': width,
              'height': height,
              'stride': stride,
              'format': format,
              ...metadataOverrides,
            },
            ...responseOverrides,
          }),
        );
      }
      if (postflightResult != null &&
          command.contains(
            'foreground Pluto embedder changed during screenshot transfer',
          )) {
        return postflightResult;
      }
      return const CommandResult(exitCode: 0);
    },
    downloadHandler: (String remotePath) async {
      if (remotePath != path) {
        throw StateError('unexpected download path: $remotePath');
      }
      return downloadedPng ?? png;
    },
  );
}

const Set<String> _provisionProbeCommands = <String>{
  'cat /sys/devices/soc0/machine',
  'cat /proc/device-tree/model',
  'cat /proc/device-tree/compatible',
  'hostname',
  'cat /etc/version',
  'cat /usr/share/remarkable/update.conf',
  'cat /etc/os-release',
  'uname -m',
  'uname -r',
  'test -e "/home/root/pluto/VERSION"',
};

Future<File> _writePlap(
  Directory temp, {
  String appId = 'dev.example.notes',
  bool gzipped = false,
  String buildMode = 'release',
  String target = 'linux-arm64',
  bool includeBothTargets = false,
}) async {
  final bool isDebug = buildMode == 'debug';
  final String runtimeType = isDebug ? 'flutter-kernel' : 'flutter-aot';
  MemoryPackageSource sourceFor(String sliceTarget) =>
      MemoryPackageSource(<PackageEntry>[
        PackageEntry(
          path: 'manifest.json',
          bytes: Uint8List.fromList(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'id': appId,
                'name': 'Notes',
                'version': '1.0.0',
                'icon': 'assets/pluto/icon.png',
                'runtime': <String, Object?>{
                  'type': runtimeType,
                  if (!isDebug) 'appElf': 'lib/app.so',
                  'assets': 'flutter_assets',
                },
                'engine': <String, Object?>{
                  'flutterVersion': '3.44.4',
                  'engineCommit': _engineCommit,
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
            ),
          ),
        ),
        if (isDebug)
          PackageEntry(
            path: 'bundle/flutter_assets/kernel_blob.bin',
            bytes: Uint8List.fromList(<int>[1, 2, 3]),
          )
        else
          PackageEntry(
            path: 'bundle/lib/app.so',
            bytes: sliceTarget == 'linux-arm'
                ? releaseArmAotElf()
                : buildMode == 'profile'
                ? profileAotElf()
                : releaseAotElf(),
          ),
        PackageEntry(
          path: 'bundle/flutter_assets/AssetManifest.bin',
          bytes: Uint8List.fromList(<int>[4, 5, 6]),
        ),
        PackageEntry(
          path: 'assets/pluto/icon.png',
          bytes: Uint8List.fromList(
            sliceTarget == 'linux-arm' ? _armIconBytes : _arm64IconBytes,
          ),
        ),
      ]);
  final List<String> targets = includeBothTargets
      ? const <String>['linux-arm64', 'linux-arm']
      : <String>[target];
  final PlapPackage package =
      await const PlapPackageBuilder(compressor: NoopCompressor()).buildSlices(
        slices: <PackageSliceSource>[
          for (final String sliceTarget in targets)
            PackageSliceSource(
              source: sourceFor(sliceTarget),
              metadata: PackageMetadata(
                flutterVersion: '3.44.4',
                engineCommit: _engineCommit,
                plutoVersion: '0.1.0',
                buildMode: buildMode,
                engineFlavor: buildMode,
                target: sliceTarget,
              ),
            ),
        ],
      );
  final File plap = File('${temp.path}/app.plap');
  await plap.writeAsBytes(gzipped ? gzip.encode(package.bytes) : package.bytes);
  return plap;
}

Uint8List _buildMetadataBytes({
  String target = 'linux-arm64',
  String buildMode = 'release',
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'buildMode': buildMode,
      'engineFlavor': buildMode,
      'flutterVersion': '3.44.4',
      'engineCommit': _engineCommit,
      'target': target,
    }),
  ),
);

String _manifestJson({
  required String appId,
  bool debug = false,
  String icon = 'assets/pluto/icon.png',
  String? iconMono,
}) => jsonEncode(<String, Object?>{
  'id': appId,
  'name': 'Test app',
  'version': '1.0.0',
  'icon': icon,
  'iconMono': ?iconMono,
  'runtime': debug
      ? <String, Object?>{'type': 'flutter-kernel', 'assets': 'flutter_assets'}
      : <String, Object?>{
          'type': 'flutter-aot',
          'appElf': 'lib/app.so',
          'assets': 'flutter_assets',
        },
  'engine': <String, Object?>{
    'flutterVersion': '3.44.4',
    'engineCommit': _engineCommit,
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
  'launch': <String, Object?>{'singleInstance': true, 'args': <Object?>[]},
});

PayloadFile _releaseActivator() => PayloadFile(
  localPath: '${Directory.current.path}/../device/pluto-release-activate.sh',
  remoteRelative: 'bin/pluto-release-activate.sh',
  executable: true,
);

List<PayloadFile> _runtimeWithActivator([
  List<PayloadFile> files = const <PayloadFile>[],
]) => <PayloadFile>[...files, _releaseActivator()];

void main() {
  test(
    'provision stages canonical layout and enforces profile boot policy',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync('pluto_prov');
      addTearDown(() => temp.deleteSync(recursive: true));
      final File embedder = File('${temp.path}/pluto-embedder')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final File engine = File('${temp.path}/libflutter_engine.so')
        ..writeAsBytesSync(<int>[9]);
      final Directory launcherBundle = Directory('${temp.path}/launcher/bundle')
        ..createSync(recursive: true);
      final Directory appBundle = Directory('${temp.path}/app/bundle')
        ..createSync(recursive: true);
      File('${launcherBundle.parent.path}/manifest.json').writeAsStringSync(
        _manifestJson(
          appId: 'dev.pluto.launcher',
          iconMono: 'assets/pluto/icon-mono.png',
        ),
      );
      File('${appBundle.parent.path}/manifest.json').writeAsStringSync(
        _manifestJson(appId: 'dev.example.counter', debug: true),
      );
      final Uint8List launcherMetadata = _buildMetadataBytes();
      final Uint8List appMetadata = _buildMetadataBytes(buildMode: 'debug');
      File(
        '${launcherBundle.parent.path}/build-metadata.json',
      ).writeAsBytesSync(launcherMetadata);
      File(
        '${appBundle.parent.path}/build-metadata.json',
      ).writeAsBytesSync(appMetadata);
      File('${launcherBundle.parent.path}/assets/pluto/icon.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[10, 11]);
      File('${launcherBundle.parent.path}/assets/pluto/icon-mono.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[12, 13]);
      File('${appBundle.parent.path}/assets/pluto/icon.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[14, 15]);
      File('${appBundle.path}/flutter_assets/kernel_blob.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[4, 5, 6]);

      final FakeTransport fake = _moveTransport('10.11.99.1');
      final _RecordingTransport transport = _RecordingTransport(fake);
      final LiveDeviceOperations ops = LiveDeviceOperations(transport);

      final DeviceOperationResult result = await ops.provision(
        runtime: _runtimeWithActivator(<PayloadFile>[
          PayloadFile(
            localPath: embedder.path,
            remoteRelative: 'bin/pluto-embedder',
            executable: true,
          ),
          PayloadFile(
            localPath: engine.path,
            remoteRelative: 'engine/debug/libflutter_engine.so',
          ),
        ]),
        apps: <PayloadApp>[
          PayloadApp(
            appId: LiveDeviceOperations.launcherAppId,
            bundleDir: launcherBundle.path,
            buildMode: 'release',
            engineFlavor: 'release',
            target: 'linux-arm64',
          ),
          PayloadApp(
            appId: 'dev.example.counter',
            bundleDir: appBundle.path,
            buildMode: 'debug',
            engineFlavor: 'debug',
            target: 'linux-arm64',
          ),
        ],
        payloadTarget: 'linux-arm64',
      );

      expect(result.ok, isTrue);
      final FakeUpload embedderUpload = fake.uploads.singleWhere(
        (FakeUpload upload) =>
            upload.remotePath.endsWith('/bin/pluto-embedder'),
      );
      final String stage = embedderUpload.remotePath.substring(
        0,
        embedderUpload.remotePath.length - '/bin/pluto-embedder'.length,
      );
      expect(stage, startsWith('$root.releases/.candidate-'));
      expect(embedderUpload.executable, isTrue);
      expect(
        fake.uploads.any(
          (FakeUpload upload) => upload.remotePath.startsWith('$root/'),
        ),
        isFalse,
        reason: 'no upload may target any path visible through the live link',
      );
      expect(
        fake.uploads.map((FakeUpload upload) => upload.remotePath),
        containsAll(<String>[
          '$stage/bin/pluto-embedder',
          '$stage/bin/pluto-release-activate.sh',
          '$stage/engine/debug/libflutter_engine.so',
        ]),
      );
      final (String, String) launcherUpload = fake.directoryUploads.singleWhere(
        ((String, String) upload) => upload.$2 == '$stage/launcher/bundle',
      );
      final (String, String) appUpload = fake.directoryUploads.singleWhere(
        ((String, String) upload) =>
            upload.$2 == '$stage/apps/dev.example.counter/bundle',
      );
      expect(<String>[
        launcherUpload.$2,
        appUpload.$2,
      ], everyElement(startsWith(stage)));
      expect(
        fake.uploads.map((FakeUpload upload) => upload.remotePath),
        containsAll(<String>[
          '$stage/launcher/manifest.json',
          '$stage/launcher/build-metadata.json',
          '$stage/launcher/install.json',
          '$stage/launcher/assets/pluto/icon.png',
          '$stage/launcher/assets/pluto/icon-mono.png',
          '$stage/apps/dev.example.counter/manifest.json',
          '$stage/apps/dev.example.counter/build-metadata.json',
          '$stage/apps/dev.example.counter/install.json',
          '$stage/apps/dev.example.counter/assets/pluto/icon.png',
        ]),
      );
      expect(
        fake.uploads
            .singleWhere(
              (FakeUpload upload) =>
                  upload.remotePath == '$stage/launcher/build-metadata.json',
            )
            .bytes,
        orderedEquals(launcherMetadata),
      );
      expect(
        fake.uploads
            .singleWhere(
              (FakeUpload upload) =>
                  upload.remotePath ==
                  '$stage/apps/dev.example.counter/build-metadata.json',
            )
            .bytes,
        orderedEquals(appMetadata),
      );
      expect(
        utf8.decode(
          fake.uploads
              .singleWhere(
                (FakeUpload upload) =>
                    upload.remotePath ==
                    '$stage/apps/dev.example.counter/install.json',
              )
              .bytes,
        ),
        contains('"buildMode": "debug"'),
      );
      final String prepare = fake.commands.singleWhere(
        (String command) =>
            command.contains("ln -s '$root.data/appdata'") &&
            command.contains("'$stage/appdata'"),
      );
      final String publish = fake.commands.singleWhere(
        (String command) =>
            command.contains("mv '$stage'") &&
            command.contains("'$root.releases/") &&
            command.contains('nonregular='),
      );
      final RegExpMatch candidateMatch = RegExp(
        "mv '${RegExp.escape(stage)}' '([^']+)'",
      ).firstMatch(publish)!;
      final String candidate = candidateMatch.group(1)!;
      expect(candidate, startsWith('$root.releases/'));
      expect(candidate, isNot(contains('/.candidate-')));
      final String activate = fake.commands.singleWhere(
        (String command) =>
            command.contains("sh '$candidate/bin/pluto-release-activate.sh'") &&
            command.contains("activate '$candidate' 'transient'"),
      );
      expect(
        transport.events.indexOf('exec:$prepare'),
        lessThan(
          transport.events.indexOf('upload-file:${embedderUpload.remotePath}'),
        ),
      );
      expect(
        transport.events.indexOf('upload-dir:${appUpload.$2}'),
        lessThan(transport.events.indexOf('exec:$publish')),
        reason: 'every app is complete before the candidate is published',
      );
      expect(
        transport.events.indexOf('exec:$publish'),
        lessThan(transport.events.indexOf('exec:$activate')),
        reason: 'one whole-release activation follows complete validation',
      );
      expect(result.message, contains('active for this boot'));
    },
  );

  test('provision refuses an unmanaged runtime-root collision', () async {
    final FakeTransport transport = _moveTransport(
      'h',
      execHandler: (String command) async {
        if (command.contains('conflicts with the managed release symlink')) {
          return const CommandResult(
            exitCode: 78,
            stderr: '$root conflicts with the managed release symlink',
          );
        }
        return const CommandResult(exitCode: 0);
      },
    );

    await expectLater(
      LiveDeviceOperations(transport).provision(
        runtime: _runtimeWithActivator(),
        apps: const <PayloadApp>[],
        payloadTarget: 'linux-arm64',
        bootDefault: false,
      ),
      throwsA(
        isA<DeviceOperationException>().having(
          (DeviceOperationException error) => error.message,
          'message',
          'runtime root ownership is unsafe; remove or relocate the '
              'conflicting path',
        ),
      ),
    );
    expect(
      transport.commands,
      contains(contains('conflicts with the managed release symlink')),
    );
    expect(transport.uploads, isEmpty);
    expect(transport.directoryUploads, isEmpty);
  });

  test('provision rejects AppleDouble metadata before device I/O', () async {
    final Directory temp = Directory.systemTemp.createTempSync('pluto_meta');
    addTearDown(() => temp.deleteSync(recursive: true));
    final Directory bundle = Directory('${temp.path}/launcher/bundle')
      ..createSync(recursive: true);
    File(
      '${bundle.parent.path}/manifest.json',
    ).writeAsStringSync(_manifestJson(appId: 'dev.pluto.launcher'));
    File('${bundle.path}/flutter_assets/._AssetManifest.bin')
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1]);
    final FakeTransport transport = _moveTransport('h');

    await expectLater(
      LiveDeviceOperations(transport).provision(
        runtime: _runtimeWithActivator(),
        apps: <PayloadApp>[
          PayloadApp(
            appId: LiveDeviceOperations.launcherAppId,
            bundleDir: bundle.path,
            buildMode: 'release',
            engineFlavor: 'release',
            target: 'linux-arm64',
          ),
        ],
        payloadTarget: 'linux-arm64',
      ),
      throwsA(
        isA<DeviceOperationException>().having(
          (DeviceOperationException error) => error.message,
          'message',
          contains('contains host metadata'),
        ),
      ),
    );
    expect(transport.commands, isEmpty);
    expect(transport.uploads, isEmpty);
    expect(transport.directoryUploads, isEmpty);
  });

  test(
    'provision without bootDefault removes an existing override last',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync('pluto_prov');
      addTearDown(() => temp.deleteSync(recursive: true));
      final File bootInstaller = File('${temp.path}/pluto-boot-install.sh')
        ..writeAsStringSync('#!/bin/sh\n');
      final FakeTransport fake = _moveTransport('h');
      final _RecordingTransport transport = _RecordingTransport(fake);
      final LiveDeviceOperations ops = LiveDeviceOperations(transport);
      final DeviceOperationResult result = await ops.provision(
        runtime: _runtimeWithActivator(<PayloadFile>[
          PayloadFile(
            localPath: bootInstaller.path,
            remoteRelative: 'bin/pluto-boot-install.sh',
            executable: true,
          ),
        ]),
        apps: const <PayloadApp>[],
        payloadTarget: 'linux-arm64',
        bootDefault: false,
      );
      expect(result.ok, isTrue);
      final FakeUpload upload = fake.uploads.singleWhere(
        (FakeUpload item) =>
            item.remotePath.endsWith('/bin/pluto-boot-install.sh'),
      );
      expect(upload.remotePath, startsWith('$root.releases/.candidate-'));
      final String publish = fake.commands.singleWhere(
        (String command) =>
            command.contains('nonregular=') &&
            command.contains('mv ') &&
            command.contains('$root.releases/'),
      );
      final String activate = fake.commands.singleWhere(
        (String command) =>
            command.contains('pluto-release-activate.sh') &&
            command.contains(" 'stock'"),
      );
      expect(
        transport.events.indexOf('upload-file:${upload.remotePath}'),
        lessThan(transport.events.indexOf('exec:$publish')),
        reason:
            'the boot helper is invisible until the complete release exists',
      );
      expect(
        transport.events.indexOf('exec:$publish'),
        lessThan(transport.events.indexOf('exec:$activate')),
        reason: '--no-boot-default is committed by the whole-release helper',
      );
      expect(
        fake.commands.where(
          (String command) =>
              command.contains("sh '$root/bin/pluto-session-once.sh' start"),
        ),
        isEmpty,
        reason: '--no-boot-default must not activate Pluto for this boot',
      );
    },
  );

  test('failed runtime upload never commits over the live target', () async {
    final Directory temp = Directory.systemTemp.createTempSync('pluto_prov');
    addTearDown(() => temp.deleteSync(recursive: true));
    final File embedder = File('${temp.path}/pluto-embedder')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final FakeTransport fake = _moveTransport('h');
    final _RecordingTransport transport = _RecordingTransport(
      fake,
      failFileUpload: true,
    );

    await expectLater(
      LiveDeviceOperations(transport).provision(
        runtime: _runtimeWithActivator(<PayloadFile>[
          PayloadFile(
            localPath: embedder.path,
            remoteRelative: 'bin/pluto-embedder',
            executable: true,
          ),
        ]),
        apps: const <PayloadApp>[],
        payloadTarget: 'linux-arm64',
      ),
      throwsA(isA<StateError>()),
    );

    expect(
      transport.events.any(
        (String event) =>
            event.startsWith('upload-file:$root.releases/.candidate-') &&
            event.endsWith('/bin/pluto-embedder'),
      ),
      isTrue,
      reason: 'the failed upload targeted only a same-directory sibling',
    );
    expect(fake.uploads, isEmpty);
    expect(
      fake.commands.any(
        (String command) =>
            command.contains('pluto-release-activate.sh') &&
            command.contains(' activate '),
      ),
      isFalse,
      reason: 'the live target remains untouched when upload does not finish',
    );
  });

  test('invalid declared icons fail before any device mutation', () async {
    for (final ({String name, String icon, bool create}) fixture
        in <({String name, String icon, bool create})>[
          (name: 'traversal', icon: '../outside.png', create: true),
          (name: 'missing', icon: 'assets/pluto/missing.png', create: false),
        ]) {
      final Directory temp = Directory.systemTemp.createTempSync(
        'pluto_icon_${fixture.name}',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final Directory bundle = Directory('${temp.path}/layout/bundle')
        ..createSync(recursive: true);
      File('${bundle.parent.path}/manifest.json').writeAsStringSync(
        _manifestJson(appId: 'dev.example.icon', icon: fixture.icon),
      );
      File(
        '${bundle.parent.path}/build-metadata.json',
      ).writeAsBytesSync(_buildMetadataBytes());
      if (fixture.create) {
        File('${bundle.parent.path}/${fixture.icon}')
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[1]);
      }
      final File runtime = File('${temp.path}/pluto-embedder')
        ..writeAsBytesSync(<int>[2]);
      final FakeTransport transport = FakeTransport(
        endpoint: const DeviceEndpoint(host: 'h'),
      );

      await expectLater(
        LiveDeviceOperations(transport).provision(
          runtime: _runtimeWithActivator(<PayloadFile>[
            PayloadFile(
              localPath: runtime.path,
              remoteRelative: 'bin/pluto-embedder',
              executable: true,
            ),
          ]),
          apps: <PayloadApp>[
            PayloadApp(
              appId: 'dev.example.icon',
              bundleDir: bundle.path,
              buildMode: 'release',
              engineFlavor: 'release',
              target: 'linux-arm64',
            ),
          ],
          payloadTarget: 'linux-arm64',
        ),
        throwsA(isA<DeviceOperationException>()),
        reason: fixture.name,
      );

      expect(transport.commands, isEmpty, reason: fixture.name);
      expect(transport.uploads, isEmpty, reason: fixture.name);
      expect(transport.directoryUploads, isEmpty, reason: fixture.name);
    }
  });

  test('provision requires regular build metadata before device I/O', () async {
    for (final String fixture in <String>['missing', 'directory', 'symlink']) {
      final Directory temp = Directory.systemTemp.createTempSync(
        'pluto_build_metadata_$fixture',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final Directory bundle = Directory('${temp.path}/layout/bundle')
        ..createSync(recursive: true);
      File(
        '${bundle.parent.path}/manifest.json',
      ).writeAsStringSync(_manifestJson(appId: 'dev.example.notes'));
      final String metadataPath = '${bundle.parent.path}/build-metadata.json';
      if (fixture == 'directory') {
        Directory(metadataPath).createSync();
      } else if (fixture == 'symlink') {
        final File target = File('${temp.path}/metadata-target.json')
          ..writeAsBytesSync(_buildMetadataBytes());
        Link(metadataPath).createSync(target.path);
      }
      final FakeTransport transport = _moveTransport('h');

      await expectLater(
        LiveDeviceOperations(transport).provision(
          runtime: _runtimeWithActivator(),
          apps: <PayloadApp>[
            PayloadApp(
              appId: 'dev.example.notes',
              bundleDir: bundle.path,
              buildMode: 'release',
              engineFlavor: 'release',
              target: 'linux-arm64',
            ),
          ],
          payloadTarget: 'linux-arm64',
        ),
        throwsA(
          isA<DeviceOperationException>().having(
            (DeviceOperationException error) => error.message,
            'message',
            contains('missing build metadata'),
          ),
        ),
        reason: fixture,
      );

      expect(transport.commands, isEmpty, reason: fixture);
      expect(transport.uploads, isEmpty, reason: fixture);
      expect(transport.directoryUploads, isEmpty, reason: fixture);
    }
  });

  test('provision accepts the exact generated target architecture', () async {
    for (final ({String target, String machine, String architecture}) fixture
        in <({String target, String machine, String architecture})>[
          (
            target: 'linux-arm64',
            machine: 'imx93-chiappa',
            architecture: 'aarch64',
          ),
        ]) {
      final FakeTransport transport = _deviceTransport(
        'device',
        machine: fixture.machine,
        architecture: fixture.architecture,
      );

      final DeviceOperationResult result = await LiveDeviceOperations(transport)
          .provision(
            runtime: _runtimeWithActivator(),
            apps: const <PayloadApp>[],
            payloadTarget: fixture.target,
            bootDefault: false,
          );

      expect(result.ok, isTrue, reason: '$fixture');
    }
  });

  test(
    'provision rejects missing or mismatched kernel before mutation',
    () async {
      for (final ({String name, String? release, bool available}) fixture
          in <({String name, String? release, bool available})>[
            (name: 'missing', release: null, available: false),
            (name: 'mismatched', release: '6.12.50-future', available: true),
          ]) {
        final FakeTransport transport = _deviceTransport(
          'device',
          kernelRelease: fixture.release,
          kernelReleaseAvailable: fixture.available,
        );

        await expectLater(
          LiveDeviceOperations(transport).provision(
            runtime: _runtimeWithActivator(),
            apps: const <PayloadApp>[],
            payloadTarget: 'linux-arm64',
          ),
          throwsA(
            isA<DeviceOperationException>().having(
              (DeviceOperationException error) => error.message,
              'message',
              contains('kernel release does not match'),
            ),
          ),
          reason: fixture.name,
        );

        expect(transport.commands, contains('uname -r'), reason: fixture.name);
        expect(
          transport.commands.every(_provisionProbeCommands.contains),
          isTrue,
          reason: 'only read-only probes may run for ${fixture.name}',
        );
        expect(transport.uploads, isEmpty, reason: fixture.name);
        expect(transport.directoryUploads, isEmpty, reason: fixture.name);
      }
    },
  );

  test('provision compatibility refusal occurs before remote writes', () async {
    for (final ({String target, String machine, String architecture}) fixture
        in <({String target, String machine, String architecture})>[
          (
            target: 'linux-arm64',
            machine: 'reMarkable 2.0',
            architecture: 'armv7l',
          ),
          (
            target: 'linux-arm64',
            machine: 'mystery-tablet',
            architecture: 'aarch64',
          ),
          (
            target: 'linux-arm64',
            machine: 'imx93-chiappa',
            architecture: 'x86_64',
          ),
          (
            target: 'linux-arm64',
            machine: 'imx8mm-ferrari',
            architecture: 'aarch64',
          ),
        ]) {
      final FakeTransport transport = _deviceTransport(
        'device',
        machine: fixture.machine,
        architecture: fixture.architecture,
      );

      await expectLater(
        LiveDeviceOperations(transport).provision(
          runtime: _runtimeWithActivator(),
          apps: const <PayloadApp>[],
          payloadTarget: fixture.target,
        ),
        throwsA(isA<DeviceOperationException>()),
        reason: '$fixture',
      );

      expect(transport.commands, isNotEmpty, reason: '$fixture');
      expect(
        transport.commands.every(_provisionProbeCommands.contains),
        isTrue,
        reason: 'only read-only probe commands may run for $fixture',
      );
      expect(transport.uploads, isEmpty, reason: '$fixture');
      expect(transport.directoryUploads, isEmpty, reason: '$fixture');
    }
  });

  test(
    'provision rejects conflicting immutable identities before writes',
    () async {
      final FakeTransport transport = _deviceTransport(
        'device',
        machine: 'reMarkable 2.0',
        architecture: 'armv7l',
        compatible:
            'remarkable,zero-gravitas\u0000fsl,imx6sl\u0000fsl,imx7d-sdb',
        execHandler: (String command) async {
          if (command == 'cat /proc/device-tree/model') {
            return const CommandResult(exitCode: 0, stdout: 'imx93-chiappa');
          }
          return const CommandResult(exitCode: 1);
        },
      );

      await expectLater(
        LiveDeviceOperations(transport).provision(
          runtime: _runtimeWithActivator(),
          apps: const <PayloadApp>[],
          payloadTarget: 'linux-arm',
        ),
        throwsA(isA<DeviceOperationException>()),
      );

      expect(transport.commands, isNotEmpty);
      expect(
        transport.commands.every(_provisionProbeCommands.contains),
        isTrue,
        reason: 'identity conflict must stop at read-only probes',
      );
      expect(transport.uploads, isEmpty);
      expect(transport.directoryUploads, isEmpty);
    },
  );

  test('provision never trusts a hostname that impersonates a Move', () async {
    final FakeTransport transport = FakeTransport(
      endpoint: const DeviceEndpoint(host: 'device'),
      execHandler: (String command) async {
        if (command == 'hostname') {
          return const CommandResult(exitCode: 0, stdout: 'chiappa\n');
        }
        if (command == 'uname -m') {
          return const CommandResult(exitCode: 0, stdout: 'aarch64\n');
        }
        return const CommandResult(exitCode: 1);
      },
    );

    await expectLater(
      LiveDeviceOperations(transport).provision(
        runtime: _runtimeWithActivator(),
        apps: const <PayloadApp>[],
        payloadTarget: 'linux-arm64',
      ),
      throwsA(isA<DeviceOperationException>()),
    );

    expect(transport.commands, isNot(contains('hostname')));
    expect(transport.uploads, isEmpty);
    expect(transport.directoryUploads, isEmpty);
  });

  test(
    'provision rejects unknown or mixed targets before device I/O',
    () async {
      final FakeTransport unknown = _moveTransport('device');
      await expectLater(
        LiveDeviceOperations(unknown).provision(
          runtime: const <PayloadFile>[],
          apps: const <PayloadApp>[],
          payloadTarget: 'linux-riscv64',
        ),
        throwsA(isA<DeviceOperationException>()),
      );
      expect(unknown.commands, isEmpty);
      expect(unknown.uploads, isEmpty);

      final FakeTransport mixed = _moveTransport('device');
      await expectLater(
        LiveDeviceOperations(mixed).provision(
          runtime: const <PayloadFile>[],
          apps: const <PayloadApp>[
            PayloadApp(
              appId: 'dev.example.arm32',
              bundleDir: '/unused',
              buildMode: 'release',
              engineFlavor: 'release',
              target: 'linux-arm',
            ),
          ],
          payloadTarget: 'linux-arm64',
        ),
        throwsA(isA<DeviceOperationException>()),
      );
      expect(mixed.commands, isEmpty);
      expect(mixed.uploads, isEmpty);
      expect(mixed.directoryUploads, isEmpty);
    },
  );

  test(
    'release-only provision rejects a debug app before device I/O',
    () async {
      final FakeTransport transport = FakeTransport(
        endpoint: const DeviceEndpoint(host: 'h'),
      );

      await expectLater(
        LiveDeviceOperations(transport).provision(
          runtime: _runtimeWithActivator(),
          apps: const <PayloadApp>[
            PayloadApp(
              appId: 'dev.example.debug',
              bundleDir: '/unused',
              buildMode: 'debug',
              engineFlavor: 'debug',
              target: 'linux-arm64',
            ),
          ],
          payloadTarget: 'linux-arm64',
        ),
        throwsA(isA<DeviceOperationException>()),
      );

      expect(transport.commands, isEmpty);
      expect(transport.uploads, isEmpty);
      expect(transport.directoryUploads, isEmpty);
    },
  );

  test('restoreStockBoot undoes boot-first but keeps the runtime', () async {
    final FakeTransport transport = _moveTransport('h');
    final LiveDeviceOperations ops = LiveDeviceOperations(transport);
    final DeviceOperationResult result = await ops.restoreStockBoot();
    expect(result.ok, isTrue);
    expect(
      transport.commands.any(
        (String c) =>
            c.contains('pluto-boot-install.sh') && c.contains(' restore'),
      ),
      isTrue,
    );
    final String restore = transport.commands.singleWhere(
      (String command) => command.contains('pluto-boot-install.sh'),
    );
    expect(
      restore.indexOf('pluto-session-once.sh'),
      lessThan(restore.indexOf('pluto-boot-install.sh')),
      reason: 'the transient session must stop before boot policy is restored',
    );
    expect(result.message, contains('restored now'));
    expect(
      transport.commands.any((String c) => c.contains('pluto-uninstall.sh')),
      isFalse,
      reason: 'runtime must be kept installed',
    );
  });

  test(
    'provisionStatus reports the runtime-only current-boot session',
    () async {
      final FakeTransport transport = _moveTransport('h');
      await LiveDeviceOperations(transport).provisionStatus();

      expect(
        transport.commands.last,
        allOf(
          contains('is-active --quiet pluto-session-once.service'),
          contains('current boot: Pluto active (transient)'),
          contains('pluto-boot-install.sh'),
        ),
      );
    },
  );

  test(
    'restoreStockBoot remains available after known-device firmware drift',
    () async {
      final FakeTransport transport = _deviceTransport(
        'h',
        firmwareBuild: 'future-build',
        firmwareVersion: '9.99.0',
      );
      final DeviceOperationResult result = await LiveDeviceOperations(
        transport,
      ).restoreStockBoot();

      expect(result.ok, isTrue);
      expect(
        transport.commands.any(
          (String command) =>
              command.contains('pluto-boot-install.sh') &&
              command.contains(' restore'),
        ),
        isTrue,
        reason: 'recovery must not be disabled by a closed provision gate',
      );
    },
  );

  test('uninstallSystem runs the full device uninstaller', () async {
    final FakeTransport transport = _moveTransport('h');
    final LiveDeviceOperations ops = LiveDeviceOperations(transport);
    final DeviceOperationResult result = await ops.uninstallSystem();
    expect(result.ok, isTrue);
    expect(
      transport.commands.any(
        (String c) => c.contains('pluto-uninstall.sh') && c.contains('--yes'),
      ),
      isTrue,
    );
    final String command = transport.commands.singleWhere(
      (String command) => command.contains('pluto-uninstall.sh'),
    );
    expect(
      command,
      isNot(anyOf(contains('zz-pluto.conf'), contains("rm -rf '$root'"))),
      reason: 'the host has no partial-layout destructive fallback',
    );
    expect(
      command,
      contains('owned release/store/data preserved'),
      reason: 'missing authoritative script fails without partial deletion',
    );
  });

  test('installPackage extracts and commits through the transaction', () async {
    final Directory temp = Directory.systemTemp.createTempSync('pluto_pkg');
    addTearDown(() => temp.deleteSync(recursive: true));
    final File plap = await _writePlap(temp, includeBothTargets: true);
    final PlapTargetSlice selected = (await PlapArchive.read(
      plap.path,
    )).sliceForTarget('linux-arm64');

    final FakeTransport transport = _moveTransport('h');
    final LiveDeviceOperations ops = LiveDeviceOperations(transport);
    final DeviceOperationResult result = await ops.installPackage(plap.path);

    expect(result.ok, isTrue);
    expect(result.message, contains('dev.example.notes'));
    final FakeUpload uploadedTar = transport.uploads.singleWhere(
      (FakeUpload upload) => upload.remotePath.startsWith(
        '$root/staging/.upload-dev.example.notes.',
      ),
    );
    expect(uploadedTar.bytes, orderedEquals(selected.installTarBytes));
    final Map<String, Uint8List> selectedEntries = <String, Uint8List>{
      for (final PlapEntry entry in readTarEntries(uploadedTar.bytes))
        entry.path: entry.bytes,
    };
    expect(selectedEntries.keys.toSet(), <String>{
      'manifest.json',
      'build-metadata.json',
      'bundle/lib/app.so',
      'bundle/flutter_assets/AssetManifest.bin',
      'assets/pluto/icon.png',
    });
    expect(
      selectedEntries.keys.any((String path) => path.startsWith('targets/')),
      isFalse,
    );
    expect(
      selectedEntries['assets/pluto/icon.png'],
      orderedEquals(_arm64IconBytes),
    );
    final Uint8List installedMetadata = selectedEntries['build-metadata.json']!;
    expect(
      sha256Bytes(installedMetadata),
      selected.payloadHashes['build-metadata.json'],
      reason: 'package install uploads the selected metadata byte-for-byte',
    );
    expect(
      jsonDecode(utf8.decode(installedMetadata)),
      containsPair('target', 'linux-arm64'),
    );
    final FakeUpload installUpload = transport.uploads.singleWhere(
      (FakeUpload upload) =>
          upload.remotePath.endsWith('/install.json.pending'),
    );
    final Map<String, Object?> install =
        jsonDecode(utf8.decode(installUpload.bytes)) as Map<String, Object?>;
    expect(install.keys.toSet(), const <String>{
      'appId',
      'installedAt',
      'installedBy',
      'source',
      'buildMode',
      'engineFlavor',
      'sizeBytes',
      'payload',
    });
    expect(install['sizeBytes'], selected.installTarBytes.length);
    expect(install['payload'], selected.payloadHashes);
    expect(
      transport.commands.any(
        (String c) =>
            c.contains('pluto-install-transaction.sh') &&
            c.contains("commit 'dev.example.notes'"),
      ),
      isTrue,
      reason: 'committed through the on-device transaction',
    );
    expect(
      transport.commands.any(
        (String c) => c.contains('$root/state/apps-changed'),
      ),
      isTrue,
      reason: 'running launcher notified',
    );
    expect(
      transport.commands.any((String c) => c.contains('/run/pluto/launch')),
      isFalse,
      reason: 'no launch requested by default',
    );
  });

  test('installPackage refuses to replace an app without force', () async {
    final Directory temp = Directory.systemTemp.createTempSync('pluto_pkg');
    addTearDown(() => temp.deleteSync(recursive: true));
    final File plap = await _writePlap(temp);

    final FakeTransport transport = _moveTransport(
      'h',
      execHandler: (String command) async {
        if (command.contains('&& echo exists')) {
          return const CommandResult(exitCode: 0, stdout: 'exists\n');
        }
        return const CommandResult(exitCode: 0);
      },
    );
    final LiveDeviceOperations ops = LiveDeviceOperations(transport);

    await expectLater(
      ops.installPackage(plap.path),
      throwsA(isA<DeviceOperationException>()),
    );
    expect(
      transport.commands.any(
        (String c) => c.contains('pluto-install-transaction.sh'),
      ),
      isFalse,
      reason: 'nothing committed after the refusal',
    );

    final DeviceOperationResult forced = await ops.installPackage(
      plap.path,
      force: true,
    );
    expect(forced.ok, isTrue);
  });

  test('installPackage honors launch and setDefault', () async {
    final Directory temp = Directory.systemTemp.createTempSync('pluto_pkg');
    addTearDown(() => temp.deleteSync(recursive: true));
    final File plap = await _writePlap(temp);

    final FakeTransport transport = _moveTransport('h');
    final LiveDeviceOperations ops = LiveDeviceOperations(transport);
    final DeviceOperationResult result = await ops.installPackage(
      plap.path,
      launch: true,
      setDefault: true,
    );

    expect(result.ok, isTrue);
    expect(
      transport.commands.any(
        (String c) =>
            c.contains("'dev.example.notes' > '$root/state/default-app'"),
      ),
      isTrue,
      reason: 'boot default recorded for the supervisor',
    );
    expect(
      transport.commands.any(
        (String c) => c.contains("'dev.example.notes' > '/run/pluto/launch'"),
      ),
      isTrue,
      reason: 'launch requested via the supervisor control file',
    );
    expect(
      transport.commands.every(
        (String c) =>
            !c.contains("kill -TERM \"\$pid\"") &&
            !c.contains("kill -KILL \"\$pid\""),
      ),
      isTrue,
      reason: 'release/profile handoff is owned by the warm-process supervisor',
    );
  });

  test(
    'installPackage rejects a debug boot default before device I/O',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync('pluto_pkg');
      addTearDown(() => temp.deleteSync(recursive: true));
      final File plap = await _writePlap(temp, buildMode: 'debug');
      final FakeTransport transport = FakeTransport(
        endpoint: const DeviceEndpoint(host: 'h'),
      );

      await expectLater(
        LiveDeviceOperations(
          transport,
        ).installPackage(plap.path, setDefault: true),
        throwsA(
          isA<DeviceOperationException>().having(
            (DeviceOperationException error) => error.message,
            'message',
            contains('debug app cannot be the boot default'),
          ),
        ),
      );

      expect(transport.commands, isEmpty);
      expect(transport.uploads, isEmpty);
      expect(transport.directoryUploads, isEmpty);
      expect(transport.forwards, isEmpty);
    },
  );

  test('installPackage preserves profile mode in install.json', () async {
    final Directory temp = Directory.systemTemp.createTempSync('pluto_pkg');
    addTearDown(() => temp.deleteSync(recursive: true));
    final File plap = await _writePlap(temp, buildMode: 'profile');
    final FakeTransport transport = _moveTransport('h');

    await LiveDeviceOperations(transport).installPackage(plap.path);

    final FakeUpload install = transport.uploads.singleWhere(
      (FakeUpload upload) =>
          upload.remotePath.endsWith('/install.json.pending'),
    );
    expect(utf8.decode(install.bytes), contains('"buildMode": "profile"'));
    expect(utf8.decode(install.bytes), contains('"engineFlavor": "profile"'));
  });

  test(
    'installPackage selects the linux-arm slice through the native flow',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync('pluto_pkg');
      addTearDown(() => temp.deleteSync(recursive: true));
      final File plap = await _writePlap(temp, includeBothTargets: true);
      final PlapTargetSlice selected = (await PlapArchive.read(
        plap.path,
      )).sliceForTarget('linux-arm');
      final FakeTransport transport = _deviceTransport(
        'device',
        machine: 'reMarkable 2.0',
        architecture: 'armv7l',
      );

      final DeviceOperationResult result = await LiveDeviceOperations(
        transport,
      ).installPackage(plap.path);

      expect(result.ok, isTrue);
      expect(transport.uploads, isNotEmpty);
      expect(transport.directoryUploads, isEmpty);
      final FakeUpload uploadedTar = transport.uploads.singleWhere(
        (FakeUpload upload) =>
            upload.remotePath.contains('/staging/.upload-dev.example.notes.'),
      );
      expect(uploadedTar.bytes, orderedEquals(selected.installTarBytes));
      final Map<String, Uint8List> selectedEntries = <String, Uint8List>{
        for (final PlapEntry entry in readTarEntries(uploadedTar.bytes))
          entry.path: entry.bytes,
      };
      expect(
        selectedEntries['assets/pluto/icon.png'],
        orderedEquals(_armIconBytes),
      );
      expect(
        selectedEntries.keys.any((String path) => path.startsWith('targets/')),
        isFalse,
      );
      final FakeUpload installUpload = transport.uploads.singleWhere(
        (FakeUpload upload) =>
            upload.remotePath.endsWith('/install.json.pending'),
      );
      final Map<String, Object?> install =
          jsonDecode(utf8.decode(installUpload.bytes)) as Map<String, Object?>;
      expect(install['sizeBytes'], selected.installTarBytes.length);
      expect(install['payload'], selected.payloadHashes);
    },
  );

  test(
    'installPackage rejects a package missing the probed target slice',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync('pluto_pkg');
      addTearDown(() => temp.deleteSync(recursive: true));
      final File plap = await _writePlap(temp);
      final FakeTransport transport = _deviceTransport(
        'device',
        machine: 'reMarkable 2.0',
        architecture: 'armv7l',
      );

      await expectLater(
        LiveDeviceOperations(transport).installPackage(plap.path),
        throwsA(
          isA<ArtifactVerificationException>().having(
            (ArtifactVerificationException error) => error.message,
            'message',
            allOf(
              contains('no linux-arm slice'),
              contains('available: linux-arm64'),
            ),
          ),
        ),
      );

      expect(transport.commands, isNotEmpty);
      expect(
        transport.commands.every(_provisionProbeCommands.contains),
        isTrue,
      );
      expect(transport.uploads, isEmpty);
      expect(transport.directoryUploads, isEmpty);
    },
  );

  test(
    'installPackage never trusts a hostname that impersonates a Move',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync('pluto_pkg');
      addTearDown(() => temp.deleteSync(recursive: true));
      final File plap = await _writePlap(temp);
      final FakeTransport transport = FakeTransport(
        endpoint: const DeviceEndpoint(host: 'device'),
        execHandler: (String command) async {
          if (command == 'hostname') {
            return const CommandResult(exitCode: 0, stdout: 'chiappa\n');
          }
          if (command == 'uname -m') {
            return const CommandResult(exitCode: 0, stdout: 'aarch64\n');
          }
          return const CommandResult(exitCode: 1);
        },
      );

      await expectLater(
        LiveDeviceOperations(transport).installPackage(plap.path),
        throwsA(isA<DeviceOperationException>()),
      );

      expect(transport.commands, isNot(contains('hostname')));
      expect(transport.uploads, isEmpty);
      expect(transport.directoryUploads, isEmpty);
    },
  );

  test('installPackage rejects a mismatched pin before device I/O', () async {
    final Directory temp = Directory.systemTemp.createTempSync('pluto_pkg');
    addTearDown(() => temp.deleteSync(recursive: true));
    final File plap = await _writePlap(temp);
    final FakeTransport transport = FakeTransport(
      endpoint: const DeviceEndpoint(host: 'h'),
    );

    await expectLater(
      LiveDeviceOperations(transport).installPackage(
        plap.path,
        expectedFlutterVersion: '3.44.4',
        expectedEngineCommit: 'different',
      ),
      throwsA(isA<DeviceOperationException>()),
    );

    expect(transport.commands, isEmpty);
    expect(transport.uploads, isEmpty);
  });

  test(
    'installPackage rejects tampered payload bytes before device I/O',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync('pluto_pkg');
      addTearDown(() => temp.deleteSync(recursive: true));
      final File plap = await _writePlap(temp);
      final Uint8List bytes = plap.readAsBytesSync();
      final List<int> marker = ascii.encode('ace654289f5abc240509fc941453ebc5');
      final int markerOffset = _findBytes(bytes, marker);
      expect(markerOffset, greaterThanOrEqualTo(0));
      bytes[markerOffset] ^= 1;
      plap.writeAsBytesSync(bytes);
      final FakeTransport transport = FakeTransport(
        endpoint: const DeviceEndpoint(host: 'h'),
      );

      await expectLater(
        LiveDeviceOperations(transport).installPackage(plap.path),
        throwsA(
          isA<ArtifactVerificationException>().having(
            (ArtifactVerificationException error) => error.message,
            'message',
            contains('checksum mismatch'),
          ),
        ),
      );

      expect(transport.commands, isEmpty);
      expect(transport.uploads, isEmpty);
    },
  );

  test(
    'installPackage rejects traversal, duplicate, and link tar entries',
    () async {
      for (final ({String target, String? name, int? type}) mutation
          in <({String target, String? name, int? type})>[
            (target: 'manifest.json', name: '../escape', type: null),
            (
              target:
                  'targets/linux-arm64/bundle/flutter_assets/'
                  'AssetManifest.bin',
              name: 'manifest.json',
              type: null,
            ),
            (
              target: 'targets/linux-arm64/bundle/lib/app.so',
              name: null,
              type: 0x32,
            ),
          ]) {
        final Directory temp = Directory.systemTemp.createTempSync('pluto_pkg');
        addTearDown(() => temp.deleteSync(recursive: true));
        final File plap = await _writePlap(temp);
        _mutateTarHeader(
          plap,
          mutation.target,
          replacementName: mutation.name,
          replacementType: mutation.type,
        );
        final FakeTransport transport = FakeTransport(
          endpoint: const DeviceEndpoint(host: 'h'),
        );

        await expectLater(
          LiveDeviceOperations(transport).installPackage(plap.path),
          throwsA(isA<ArtifactVerificationException>()),
          reason: 'mutation: $mutation',
        );
        expect(transport.commands, isEmpty, reason: 'mutation: $mutation');
        expect(transport.uploads, isEmpty, reason: 'mutation: $mutation');
      }
    },
  );

  test('installPackage hard-rejects gzip before device I/O', () async {
    final Directory temp = Directory.systemTemp.createTempSync('pluto_pkg');
    addTearDown(() => temp.deleteSync(recursive: true));
    final File plap = await _writePlap(temp, gzipped: true);
    final FakeTransport transport = FakeTransport(
      endpoint: const DeviceEndpoint(host: 'h'),
    );

    await expectLater(
      LiveDeviceOperations(transport).installPackage(plap.path),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('Gzip .plap packages are not supported'),
        ),
      ),
    );

    expect(transport.commands, isEmpty);
    expect(transport.uploads, isEmpty);
  });

  test('installPackage rejects the launcher id', () async {
    final Directory temp = Directory.systemTemp.createTempSync('pluto_pkg');
    addTearDown(() => temp.deleteSync(recursive: true));
    final File plap = await _writePlap(
      temp,
      appId: LiveDeviceOperations.launcherAppId,
    );
    final FakeTransport transport = FakeTransport(
      endpoint: const DeviceEndpoint(host: 'h'),
    );
    final LiveDeviceOperations ops = LiveDeviceOperations(transport);
    await expectLater(
      ops.installPackage(plap.path),
      throwsA(isA<DeviceOperationException>()),
    );
  });

  test('uninstallApp clears a matching boot default', () async {
    final FakeTransport transport = _moveTransport('h');
    final LiveDeviceOperations ops = LiveDeviceOperations(transport);
    final DeviceOperationResult result = await ops.uninstallApp(
      'dev.example.notes',
    );
    expect(result.ok, isTrue);
    expect(
      transport.commands.any(
        (String c) => c.contains("rm -rf '$root/apps/dev.example.notes'"),
      ),
      isTrue,
    );
    expect(
      transport.commands.any(
        (String c) => c.contains('$root/state/default-app'),
      ),
      isTrue,
      reason: 'stale boot default must not survive the app',
    );
  });

  test('runDebugApp writes a one-shot debug authorization', () async {
    final FakeTransport transport = _moveTransport('h');
    final LiveDeviceOperations ops = LiveDeviceOperations(transport);
    final Uri uri = await ops.runDebugApp(appId: 'dev.example.notes');
    expect(uri.host, '127.0.0.1');
    final String authorization = transport.commands.singleWhere(
      (String command) => command.contains('/run/pluto/debug-launch'),
    );
    expect(
      authorization,
      allOf(
        contains("mkdir -p '/run/pluto'"),
        contains('.debug-launch.pluto-new-'),
        contains('chmod 0600 "\$tmp"'),
        contains("rm -f '/run/pluto/launch'"),
        contains('mv -f "\$tmp" \'/run/pluto/debug-launch\''),
        isNot(contains("> '/run/pluto/launch'")),
      ),
    );
    expect(transport.forwards, hasLength(1));
    expect(
      transport.commands.any(
        (String command) =>
            command.contains("cat '/run/pluto/embedder.pid'") &&
            command.contains("kill -TERM \"\$pid\"") &&
            command.contains("kill -KILL \"\$pid\"") &&
            !command.contains('pkill -f'),
      ),
      isTrue,
      reason: 'debug/JIT remains a bounded one-shot process',
    );
    final String nudge = transport.commands.singleWhere(
      (String command) => command.contains("cat '/run/pluto/embedder.pid'"),
    );
    final ProcessResult syntax = await Process.run('sh', <String>[
      '-n',
      '-c',
      nudge,
    ]);
    expect(syntax.exitCode, 0, reason: '${syntax.stderr}');
  });

  test('logs tails the canonical log files', () async {
    final FakeTransport transport = _moveTransport(
      'h',
      execHandler: (String command) async =>
          const CommandResult(exitCode: 0, stdout: 'LOGLINE'),
    );
    final LiveDeviceOperations ops = LiveDeviceOperations(transport);
    expect(await ops.logs(), contains('LOGLINE'));
    expect(
      transport.commands.any(
        (String c) => c.contains('$root/logs/current.log'),
      ),
      isTrue,
    );
  });

  test('uninstall rejects unsafe and launcher ids before device I/O', () async {
    for (final String appId in <String>[
      '../dev.pluto.ink',
      'dev.pluto/ink',
      'dev.pluto.ink;reboot',
      LiveDeviceOperations.launcherAppId,
    ]) {
      final FakeTransport transport = _moveTransport('device');

      await expectLater(
        LiveDeviceOperations(transport).uninstallApp(appId),
        throwsA(isA<DeviceOperationException>()),
        reason: appId,
      );

      expect(transport.commands, isEmpty, reason: appId);
      expect(transport.uploads, isEmpty, reason: appId);
      expect(transport.directoryUploads, isEmpty, reason: appId);
    }
  });

  test('native screenshot uses correlated embedder control metadata', () async {
    final Uint8List png = _pngHeaderFixture(73, 41);
    late Map<String, Object?> request;
    final FakeTransport transport = _screenshotTransport(
      png: png,
      appId: 'dev.example.notes',
      surface: 'logical',
      width: 73,
      height: 41,
      stride: 304,
      format: 'xrgb8888',
      onRequest: (Map<String, Object?> value) => request = value,
    );

    expect(
      await LiveDeviceOperations(
        transport,
      ).screenshot(appId: 'dev.example.notes'),
      orderedEquals(png),
    );

    expect(request.keys.toSet(), const <String>{
      'requestId',
      'action',
      'appId',
      'surface',
    });
    expect(request['action'], 'screenshot');
    expect(request['appId'], 'dev.example.notes');
    expect(request['surface'], 'logical');
    expect(request['requestId'], isA<String>());
    final String control = transport.commands.singleWhere(
      (String command) => command.contains('embedder-control.sock'),
    );
    expect(control, contains("client='$root/bin/pluto-controlctl'"));
    expect(control, contains("--socket '/run/pluto/embedder-control.sock'"));
    final String preflight = transport.commands.singleWhere(
      (String command) => command.contains('wc -c < "\$artifact"'),
    );
    expect(preflight, contains("'/run/pluto/embedder.pid'"));
    expect(preflight, isNot(contains('base64')));
    expect(preflight, isNot(contains('sha256sum')));
    expect(transport.downloads, <String>[
      '/run/pluto/screenshots/direct-4242-1.png',
    ]);
    expect(
      transport.commands.any(
        (String command) => command.contains(
          'foreground Pluto embedder changed during screenshot transfer',
        ),
      ),
      isTrue,
    );
    expect(
      transport.commands.any(
        (String command) =>
            command.contains("rm -f '/run/pluto/screenshots/") &&
            command.contains('2>/dev/null || true'),
      ),
      isTrue,
    );
    expect(
      transport.commands.any(
        (String command) =>
            command.contains('--screenshot-base64') ||
            command.contains('last-frame.png'),
      ),
      isFalse,
    );
  });

  test(
    'native screenshot resolves the managed release link for foreground identity',
    () async {
      final Uint8List png = _pngHeaderFixture(37, 29);
      late String foregroundCommand;
      final FakeTransport transport = _screenshotTransport(
        png: png,
        pid: 30113,
        path: '/run/pluto/screenshots/direct-30113-1.png',
        foregroundHandler: (String command) async {
          foregroundCommand = command;
          const String shellFixture = r'''
cat() {
  [ "$1" = '/run/pluto/embedder.pid' ] || return 1
  printf '%s\n' '30113'
}
readlink() {
  if [ "$1" = '-f' ]; then
    [ "$2" = '/home/root/pluto/bin/pluto-embedder' ] || return 1
    printf '%s\n' '/home/root/pluto.releases/release-1/bin/pluto-embedder'
    return 0
  fi
  [ "$1" = '/proc/30113/exe' ] || return 1
  printf '%s\n' '/home/root/pluto.releases/release-1/bin/pluto-embedder'
}
''';
          final ProcessResult result = await Process.run('sh', <String>[
            '-c',
            '$shellFixture\n$command',
          ]);
          return CommandResult(
            exitCode: result.exitCode,
            stdout: '${result.stdout}',
            stderr: '${result.stderr}',
          );
        },
      );

      expect(
        await LiveDeviceOperations(transport).screenshot(),
        orderedEquals(png),
      );
      expect(
        foregroundCommand,
        contains("readlink -f '$root/bin/pluto-embedder'"),
      );
    },
  );

  test(
    'native screenshot accepts dynamic surface formats and strides',
    () async {
      for (final ({String format, int bytesPerPixel}) fixture
          in <({String format, int bytesPerPixel})>[
            (format: 'gray8', bytesPerPixel: 1),
            (format: 'rgb565', bytesPerPixel: 2),
            (format: 'xrgb8888', bytesPerPixel: 4),
          ]) {
        final Uint8List png = _pngHeaderFixture(19, 23);
        final FakeTransport transport = _screenshotTransport(
          png: png,
          surface: 'post-dither',
          width: 19,
          height: 23,
          stride: 19 * fixture.bytesPerPixel + 7,
          format: fixture.format,
        );

        expect(
          await LiveDeviceOperations(
            transport,
          ).screenshot(surface: 'post-dither'),
          orderedEquals(png),
          reason: fixture.format,
        );
      }
    },
  );

  test('screenshot rejects an unsafe app id before device I/O', () async {
    final FakeTransport transport = _moveTransport('device');

    await expectLater(
      LiveDeviceOperations(transport).screenshot(appId: '../dev.pluto.ink'),
      throwsA(
        isA<DeviceOperationException>().having(
          (DeviceOperationException error) => error.message,
          'message',
          contains('invalid app id'),
        ),
      ),
    );

    expect(transport.commands, isEmpty);
  });

  test('native screenshot rejects uncorrelated control responses', () async {
    final Uint8List png = _pngHeaderFixture(37, 29);
    final FakeTransport transport = _screenshotTransport(
      png: png,
      responseRequestId: 'wrong-request',
    );

    await expectLater(
      LiveDeviceOperations(transport).screenshot(),
      throwsA(
        isA<DeviceOperationException>()
            .having(
              (DeviceOperationException error) => error.message,
              'message',
              contains('invalid Pluto device control response'),
            )
            .having(
              (DeviceOperationException error) => error.detail,
              'detail',
              contains('embedder'),
            ),
      ),
    );

    expect(transport.downloads, isEmpty);
  });

  test(
    'native screenshot rejects unknown envelope and result fields',
    () async {
      final Uint8List png = _pngHeaderFixture(37, 29);
      for (final FakeTransport transport in <FakeTransport>[
        _screenshotTransport(
          png: png,
          responseOverrides: const <String, Object?>{'extra': true},
        ),
        _screenshotTransport(
          png: png,
          metadataOverrides: const <String, Object?>{'extra': true},
        ),
      ]) {
        await expectLater(
          LiveDeviceOperations(transport).screenshot(),
          throwsA(
            isA<DeviceOperationException>().having(
              (DeviceOperationException error) => error.message,
              'message',
              contains('invalid Pluto'),
            ),
          ),
        );
        expect(transport.downloads, isEmpty);
      }
    },
  );

  test('native screenshot never removes an unsafe artifact path', () async {
    final Uint8List png = _pngHeaderFixture(37, 29);
    const String unsafe = '/run/pluto/screenshots/../state/boot-ready.png';
    final FakeTransport transport = _screenshotTransport(
      png: png,
      path: unsafe,
    );

    await expectLater(
      LiveDeviceOperations(transport).screenshot(),
      throwsA(isA<DeviceOperationException>()),
    );

    expect(
      transport.commands.any((String command) => command.contains(unsafe)),
      isFalse,
      reason: 'an untrusted response path never enters a shell command',
    );
    expect(
      transport.commands.any(
        (String command) =>
            command.contains('rm -f') && command.contains(unsafe),
      ),
      isFalse,
    );
  });

  test(
    'native screenshot rejects inconsistent metadata and cleans up',
    () async {
      final Uint8List png = _pngHeaderFixture(37, 29);
      final List<Map<String, Object?>> invalid = <Map<String, Object?>>[
        <String, Object?>{'bytes': 0},
        <String, Object?>{'sha256': List<String>.filled(64, 'A').join()},
        <String, Object?>{'appId': 'dev.other.app'},
        <String, Object?>{'pid': 4243},
        <String, Object?>{'surface': 'post-dither'},
        <String, Object?>{'width': 0},
        <String, Object?>{'height': 0},
        <String, Object?>{'stride': 73},
        <String, Object?>{'format': 'rgba8888'},
      ];

      for (final Map<String, Object?> override in invalid) {
        final FakeTransport transport = _screenshotTransport(
          png: png,
          metadataOverrides: override,
        );

        await expectLater(
          LiveDeviceOperations(
            transport,
          ).screenshot(appId: 'dev.example.notes'),
          throwsA(isA<DeviceOperationException>()),
          reason: '$override',
        );
        expect(
          transport.commands.any(
            (String command) => command.contains(
              "rm -f '/run/pluto/screenshots/direct-4242-1.png'",
            ),
          ),
          isTrue,
          reason: '$override',
        );
      }
    },
  );

  test(
    'native screenshot validates PNG signature and IHDR dimensions',
    () async {
      final Uint8List badSignature = _pngHeaderFixture(37, 29)..[0] = 0;
      final FakeTransport signatureTransport = _screenshotTransport(
        png: badSignature,
      );
      await expectLater(
        LiveDeviceOperations(signatureTransport).screenshot(),
        throwsA(
          isA<DeviceOperationException>().having(
            (DeviceOperationException error) => error.message,
            'message',
            contains('invalid screenshot data'),
          ),
        ),
      );

      final Uint8List png = _pngHeaderFixture(37, 29);
      final FakeTransport dimensionsTransport = _screenshotTransport(
        png: png,
        metadataOverrides: const <String, Object?>{'width': 38},
      );
      await expectLater(
        LiveDeviceOperations(dimensionsTransport).screenshot(),
        throwsA(
          isA<DeviceOperationException>().having(
            (DeviceOperationException error) => error.message,
            'message',
            contains('dimensions do not match'),
          ),
        ),
      );
      for (final FakeTransport transport in <FakeTransport>[
        signatureTransport,
        dimensionsTransport,
      ]) {
        expect(
          transport.commands.any(
            (String command) => command.contains(
              "rm -f '/run/pluto/screenshots/direct-4242-1.png'",
            ),
          ),
          isTrue,
        );
      }
    },
  );

  test('native screenshot cleans up when foreground recheck fails', () async {
    final Uint8List png = _pngHeaderFixture(37, 29);
    final FakeTransport transport = _screenshotTransport(
      png: png,
      postflightResult: const CommandResult(
        exitCode: 67,
        stderr: 'foreground Pluto embedder changed during screenshot transfer',
      ),
    );

    await expectLater(
      LiveDeviceOperations(transport).screenshot(),
      throwsA(isA<DeviceOperationException>()),
    );

    final String postflight = transport.commands.singleWhere(
      (String command) => command.contains(
        'foreground Pluto embedder changed during screenshot transfer',
      ),
    );
    expect(postflight, contains("'/run/pluto/embedder.pid'"));
    expect(transport.downloads, hasLength(1));
    expect(
      transport.commands.any(
        (String command) => command.contains(
          "rm -f '/run/pluto/screenshots/direct-4242-1.png'",
        ),
      ),
      isTrue,
    );
  });

  test('cleanup dry-run parses the scan and deletes nothing', () async {
    final FakeTransport transport = FakeTransport(
      endpoint: const DeviceEndpoint(host: 'h'),
      execHandler: (String command) async => const CommandResult(
        exitCode: 0,
        stdout:
            'garbage line\n'
            'PLUTO-CLEAN|stale-log|12|$root/logs/old.log\n'
            'PLUTO-CLEAN|staging|340|$root/staging/app.tmp\n',
      ),
    );
    final LiveDeviceOperations ops = LiveDeviceOperations(transport);
    final CleanupReport report = await ops.cleanup();
    expect(report.applied, isFalse);
    expect(report.items, hasLength(2));
    expect(report.items.first.category, 'stale-log');
    expect(report.items.first.sizeKb, 12);
    expect(report.items.first.path, '$root/logs/old.log');
    expect(report.totalKb, 352);
    expect(transport.commands.single, contains('APPLY=0'));
    expect(transport.commands.single, contains('KEEP_BAK=0'));
    expect(transport.commands.single, contains('! -newer /proc/1'));
  });

  test('cleanup --apply and --keep-backups toggle the device script', () async {
    final FakeTransport transport = FakeTransport(
      endpoint: const DeviceEndpoint(host: 'h'),
      execHandler: (String command) async => const CommandResult(exitCode: 0),
    );
    final LiveDeviceOperations ops = LiveDeviceOperations(transport);
    final CleanupReport report = await ops.cleanup(
      apply: true,
      keepBackups: true,
    );
    expect(report.applied, isTrue);
    expect(report.items, isEmpty);
    expect(transport.commands.single, contains('APPLY=1'));
    expect(transport.commands.single, contains('KEEP_BAK=1'));
  });
}

final class _RecordingTransport implements DeviceTransport {
  _RecordingTransport(this.delegate, {this.failFileUpload = false});

  final FakeTransport delegate;
  final bool failFileUpload;
  final List<String> events = <String>[];

  @override
  DeviceEndpoint get endpoint => delegate.endpoint;

  @override
  Future<bool> canConnect({Duration timeout = const Duration(seconds: 2)}) {
    events.add('can-connect');
    return delegate.canConnect(timeout: timeout);
  }

  @override
  Future<CommandResult> exec(
    String command, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    events.add('exec:$command');
    return delegate.exec(command, timeout: timeout);
  }

  @override
  Future<void> uploadFileBytes({
    required Uint8List bytes,
    required String remotePath,
    bool executable = false,
  }) {
    events.add('upload-file:$remotePath');
    if (failFileUpload) {
      return Future<void>.error(StateError('injected upload failure'));
    }
    return delegate.uploadFileBytes(
      bytes: bytes,
      remotePath: remotePath,
      executable: executable,
    );
  }

  @override
  Future<Uint8List> downloadFileBytes({
    required String remotePath,
    int? expectedBytes,
    Duration timeout = const Duration(seconds: 30),
  }) {
    events.add('download-file:$remotePath');
    return delegate.downloadFileBytes(
      remotePath: remotePath,
      expectedBytes: expectedBytes,
      timeout: timeout,
    );
  }

  @override
  Future<void> uploadDirectory({
    required String localPath,
    required String remotePath,
  }) {
    events.add('upload-dir:$remotePath');
    return delegate.uploadDirectory(
      localPath: localPath,
      remotePath: remotePath,
    );
  }

  @override
  Future<PortForwardHandle> forwardPort({
    required int hostPort,
    required int devicePort,
    RegExp? successPattern,
    Duration timeout = const Duration(seconds: 5),
  }) {
    events.add('forward:$hostPort:$devicePort');
    return delegate.forwardPort(
      hostPort: hostPort,
      devicePort: devicePort,
      successPattern: successPattern,
      timeout: timeout,
    );
  }
}

int _findBytes(List<int> haystack, List<int> needle) {
  for (int start = 0; start + needle.length <= haystack.length; start += 1) {
    bool matches = true;
    for (int index = 0; index < needle.length; index += 1) {
      if (haystack[start + index] != needle[index]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      return start;
    }
  }
  return -1;
}

void _mutateTarHeader(
  File package,
  String target, {
  String? replacementName,
  int? replacementType,
}) {
  final Uint8List bytes = package.readAsBytesSync();
  int offset = 0;
  while (offset + 512 <= bytes.length) {
    final int nameEnd = bytes.indexOf(0, offset);
    final String name = ascii.decode(
      bytes.sublist(
        offset,
        nameEnd < 0 || nameEnd > offset + 100 ? offset + 100 : nameEnd,
      ),
    );
    final String sizeText = ascii
        .decode(bytes.sublist(offset + 124, offset + 136))
        .replaceAll('\u0000', '')
        .trim();
    final int size = int.tryParse(sizeText, radix: 8) ?? 0;
    if (name == target) {
      if (replacementName != null) {
        final List<int> encoded = ascii.encode(replacementName);
        expect(encoded.length, lessThanOrEqualTo(100));
        bytes.fillRange(offset, offset + 100, 0);
        bytes.setRange(offset, offset + encoded.length, encoded);
      }
      if (replacementType != null) {
        bytes[offset + 156] = replacementType;
      }
      bytes.fillRange(offset + 148, offset + 156, 0x20);
      int checksum = 0;
      for (int index = offset; index < offset + 512; index += 1) {
        checksum += bytes[index];
      }
      final List<int> encodedChecksum = ascii.encode(
        checksum.toRadixString(8).padLeft(6, '0'),
      );
      bytes.setRange(offset + 148, offset + 154, encodedChecksum);
      bytes[offset + 154] = 0;
      bytes[offset + 155] = 0x20;
      package.writeAsBytesSync(bytes);
      return;
    }
    offset += 512 + (size == 0 ? 0 : ((size + 511) ~/ 512) * 512);
  }
  fail('tar entry not found: $target');
}
