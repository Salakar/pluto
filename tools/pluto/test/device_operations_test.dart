import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pluto_cli/src/build/package_builder.dart';
import 'package:pluto_cli/src/build/plap_reader.dart';
import 'package:pluto_cli/src/build/tar_writer.dart';
import 'package:pluto_cli/src/artifacts/checksums.dart';
import 'package:pluto_cli/src/errors.dart';
import 'package:pluto_cli/src/process.dart';
import 'package:pluto_cli/src/run/device_operations.dart';
import 'package:pluto_cli/src/ssh/device_transport.dart';
import 'package:pluto_cli/src/ssh/fake_transport.dart';
import 'package:test/test.dart';

import 'support/aot_fixture.dart';

const String root = LiveDeviceOperations.defaultDeviceRoot;
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
  String? responseRequestId,
  CommandResult? postflightResult,
  Uint8List? downloadedPng,
  void Function(Map<String, Object?> request)? onRequest,
}) {
  return _moveTransport(
    'device',
    execHandler: (String command) async {
      if (command.contains('PLUTO-FOREGROUND-PID|%s')) {
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
            'schema': 1,
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
              '{"id":"$appId","name":"Notes",'
              '"icon":"assets/pluto/icon.png","runtime":'
              '{"type":"$runtimeType",'
              '${isDebug ? '' : '"appElf":"lib/app.so",'}'
              '"assets":"flutter_assets"}}',
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
                engineCommit: 'abc',
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

File _writeRawPlap(Directory temp, String name, List<PackageEntry> payload) {
  final Map<String, String> hashes = <String, String>{
    for (final PackageEntry entry in payload)
      entry.path: sha256Bytes(entry.bytes),
  };
  final Uint8List integrity = Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'compression': 'none',
        'createdBy': 'pluto legacy-fixture',
        'files': hashes,
        'treeSha256': sha256Tree(hashes),
      }),
    ),
  );
  final Uint8List bytes = const TarArchiveWriter().write(<TarFileEntry>[
    for (final PackageEntry entry in payload)
      TarFileEntry(path: entry.path, bytes: entry.bytes),
    TarFileEntry(path: 'INTEGRITY.json', bytes: integrity),
  ]);
  return File('${temp.path}/$name.plap')..writeAsBytesSync(bytes);
}

Uint8List _legacyManifest(String runtimeType) => Uint8List.fromList(
  utf8.encode(
    '{"id":"dev.example.notes","runtime":{"type":"$runtimeType",'
    '"appElf":"lib/app.so","assets":"flutter_assets"}}',
  ),
);

Uint8List _releaseMetadata(String target) => Uint8List.fromList(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'schema': 1,
      'buildMode': 'release',
      'engineFlavor': 'release',
      'flutterVersion': '3.44.4',
      'engineCommit': 'abc',
      'target': target,
    }),
  ),
);

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
        '{"id":"dev.pluto.launcher",'
        '"icon":"assets/pluto/icon.png",'
        '"iconMono":"assets/pluto/icon-mono.png","runtime":'
        '{"type":"flutter-aot","appElf":"lib/app.so",'
        '"assets":"flutter_assets"}}',
      );
      File('${appBundle.parent.path}/manifest.json').writeAsStringSync(
        '{"id":"dev.example.counter",'
        '"icon":"assets/pluto/icon.png","runtime":'
        '{"type":"flutter-kernel","assets":"flutter_assets"}}',
      );
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
        runtime: <PayloadFile>[
          PayloadFile(
            localPath: embedder.path,
            remoteRelative: 'bin/pluto-embedder',
            executable: true,
          ),
          PayloadFile(
            localPath: engine.path,
            remoteRelative: 'engine/debug/libflutter_engine.so',
          ),
        ],
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
        (FakeUpload upload) => upload.remotePath.startsWith(
          '$root/bin/.pluto-embedder.pluto-new-',
        ),
      );
      expect(embedderUpload.executable, isFalse);
      final String embedderCommit = fake.commands.singleWhere(
        (String command) =>
            command.contains("chmod 0755 '${embedderUpload.remotePath}'") &&
            command.contains(
              "mv -f '${embedderUpload.remotePath}' "
              "'$root/bin/pluto-embedder'",
            ),
      );
      expect(
        transport.events.indexOf('upload-file:${embedderUpload.remotePath}'),
        lessThan(transport.events.indexOf('exec:$embedderCommit')),
        reason: 'the complete executable is uploaded before the atomic rename',
      );
      expect(
        fake.uploads.any(
          (FakeUpload upload) =>
              upload.remotePath == '$root/bin/pluto-embedder',
        ),
        isFalse,
        reason: 'the live executable must never be an upload target',
      );

      final FakeUpload engineUpload = fake.uploads.singleWhere(
        (FakeUpload upload) => upload.remotePath.startsWith(
          '$root/engine/debug/.libflutter_engine.so.pluto-new-',
        ),
      );
      expect(
        fake.commands.any(
          (String command) =>
              command.contains("chmod 0644 '${engineUpload.remotePath}'") &&
              command.contains(
                "mv -f '${engineUpload.remotePath}' "
                "'$root/engine/debug/libflutter_engine.so'",
              ),
        ),
        isTrue,
        reason: 'the explicit hot-reload engine is atomically installed',
      );

      final (String, String) launcherUpload = fake.directoryUploads.singleWhere(
        ((String, String) upload) =>
            upload.$2.startsWith('$root/.launcher.pluto-new-') &&
            upload.$2.endsWith('/bundle'),
      );
      final String launcherStage = launcherUpload.$2.substring(
        0,
        launcherUpload.$2.length - '/bundle'.length,
      );
      final String launcherBackup = launcherStage.replaceFirst(
        '.pluto-new-',
        '.pluto-old-',
      );
      expect(
        fake.uploads.map((FakeUpload upload) => upload.remotePath),
        containsAll(<String>[
          '$launcherStage/manifest.json',
          '$launcherStage/install.json',
          '$launcherStage/assets/pluto/icon.png',
          '$launcherStage/assets/pluto/icon-mono.png',
        ]),
      );
      final String launcherValidation = fake.commands.singleWhere(
        (String command) =>
            command.contains("[ -d '$launcherStage/bundle' ]") &&
            command.contains("[ -f '$launcherStage/assets/pluto/icon.png' ]") &&
            command.contains(
              "[ -f '$launcherStage/assets/pluto/icon-mono.png' ]",
            ),
      );
      final String launcherSwap = fake.commands.singleWhere(
        (String command) =>
            command.contains("mv '$root/launcher' '$launcherBackup'") &&
            command.contains("mv '$launcherStage' '$root/launcher'") &&
            command.contains("mv '$launcherBackup' '$root/launcher'"),
      );
      expect(
        transport.events.indexOf('upload-dir:${launcherUpload.$2}'),
        lessThan(transport.events.indexOf('exec:$launcherValidation')),
        reason: 'the complete launcher directory precedes validation',
      );
      expect(
        transport.events.indexOf('exec:$launcherValidation'),
        lessThan(transport.events.indexOf('exec:$launcherSwap')),
        reason: 'the complete staged launcher is validated before the swap',
      );
      expect(
        launcherSwap,
        isNot(contains("rm -rf '$root/launcher'")),
        reason: 'the live launcher is renamed, never deleted before upload',
      );

      final (String, String) appUpload = fake.directoryUploads.singleWhere(
        ((String, String) upload) =>
            upload.$2.startsWith(
              '$root/apps/.dev.example.counter.pluto-new-',
            ) &&
            upload.$2.endsWith('/bundle'),
      );
      final String appStage = appUpload.$2.substring(
        0,
        appUpload.$2.length - '/bundle'.length,
      );
      final String appBackup = appStage.replaceFirst(
        '.pluto-new-',
        '.pluto-old-',
      );
      final String appSwap = fake.commands.singleWhere(
        (String command) =>
            command.contains(
              "mv '$root/apps/dev.example.counter' '$appBackup'",
            ) &&
            command.contains(
              "mv '$appStage' '$root/apps/dev.example.counter'",
            ) &&
            command.contains(
              "mv '$appBackup' '$root/apps/dev.example.counter'",
            ),
      );
      expect(
        transport.events.indexOf('upload-dir:${appUpload.$2}'),
        lessThan(transport.events.indexOf('exec:$appSwap')),
        reason: 'the complete app directory precedes the swap',
      );
      expect(
        appSwap,
        isNot(contains("rm -rf '$root/apps/dev.example.counter'")),
        reason: 'the live app remains available until the staged swap',
      );
      expect(
        fake.uploads.any(
          (FakeUpload upload) => upload.remotePath == '$appStage/install.json',
        ),
        isTrue,
        reason: 'the staged app is complete before it becomes live',
      );
      expect(
        fake.uploads
            .singleWhere(
              (FakeUpload upload) =>
                  upload.remotePath == '$appStage/assets/pluto/icon.png',
            )
            .bytes,
        <int>[14, 15],
        reason: 'declared layout assets retain their root-relative paths',
      );
      final FakeUpload installRecord = fake.uploads.singleWhere(
        (FakeUpload upload) => upload.remotePath == '$appStage/install.json',
      );
      expect(
        utf8.decode(installRecord.bytes),
        contains('"buildMode": "debug"'),
      );
      expect(
        fake.uploads.any(
          (FakeUpload upload) => upload.remotePath == '$appStage/manifest.json',
        ),
        isTrue,
        reason: 'the source manifest is part of the staged transaction',
      );
      expect(
        fake.commands.any(
          (String c) =>
              c.contains('pluto-boot-install.sh') &&
              c.contains(' uninstall') &&
              c.contains("PLUTO_ROOT='$root'"),
        ),
        isTrue,
        reason: 'Move cannot bypass its generated boot recovery gate',
      );
      final String oneShot = fake.commands.singleWhere(
        (String command) =>
            command.contains("sh '$root/bin/pluto-session-once.sh' start"),
      );
      expect(
        oneShot,
        contains("PLUTO_RUN_DIR='${LiveDeviceOperations.defaultRunDir}'"),
        reason: 'Move is activated through the common supervisor for this boot',
      );
      expect(result.message, contains('active for this boot'));
      final int bootPolicy = transport.events.indexWhere(
        (String event) =>
            event.startsWith('exec:') &&
            event.contains('pluto-boot-install.sh') &&
            event.contains(' uninstall'),
      );
      expect(
        bootPolicy,
        greaterThan(transport.events.indexOf('exec:$appSwap')),
      );
      expect(
        transport.events.indexOf('exec:$oneShot'),
        greaterThan(bootPolicy),
        reason: 'current-boot activation happens only after stock boot is safe',
      );
    },
  );

  test('provision rejects AppleDouble metadata before device I/O', () async {
    final Directory temp = Directory.systemTemp.createTempSync('pluto_meta');
    addTearDown(() => temp.deleteSync(recursive: true));
    final Directory bundle = Directory('${temp.path}/launcher/bundle')
      ..createSync(recursive: true);
    File('${bundle.parent.path}/manifest.json').writeAsStringSync(
      '{"id":"dev.pluto.launcher","runtime":'
      '{"type":"flutter-aot","appElf":"lib/app.so",'
      '"assets":"flutter_assets"}}',
    );
    File('${bundle.path}/flutter_assets/._AssetManifest.bin')
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1]);
    final FakeTransport transport = _moveTransport('h');

    await expectLater(
      LiveDeviceOperations(transport).provision(
        runtime: const <PayloadFile>[],
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
        runtime: <PayloadFile>[
          PayloadFile(
            localPath: bootInstaller.path,
            remoteRelative: 'bin/pluto-boot-install.sh',
            executable: true,
          ),
        ],
        apps: const <PayloadApp>[],
        payloadTarget: 'linux-arm64',
        bootDefault: false,
      );
      expect(result.ok, isTrue);
      final FakeUpload upload = fake.uploads.singleWhere(
        (FakeUpload item) => item.remotePath.startsWith(
          '$root/bin/.pluto-boot-install.sh.pluto-new-',
        ),
      );
      final String atomicCommit = fake.commands.singleWhere(
        (String command) =>
            command.contains("chmod 0755 '${upload.remotePath}'") &&
            command.contains(
              "mv -f '${upload.remotePath}' "
              "'$root/bin/pluto-boot-install.sh'",
            ),
      );
      final String uninstall = fake.commands.singleWhere(
        (String command) =>
            command.contains('pluto-boot-install.sh') &&
            command.contains(' uninstall'),
      );
      expect(
        transport.events.indexOf('exec:$atomicCommit'),
        lessThan(transport.events.indexOf('exec:$uninstall')),
        reason: 'the newly staged installer removes the existing override last',
      );
      expect(
        fake.commands.last,
        contains('pluto-boot-install.sh'),
        reason: '--no-boot-default actively restores the stock boot default',
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
        runtime: <PayloadFile>[
          PayloadFile(
            localPath: embedder.path,
            remoteRelative: 'bin/pluto-embedder',
            executable: true,
          ),
        ],
        apps: const <PayloadApp>[],
        payloadTarget: 'linux-arm64',
      ),
      throwsA(isA<StateError>()),
    );

    expect(
      transport.events.any(
        (String event) => event.startsWith(
          'upload-file:$root/bin/.pluto-embedder.pluto-new-',
        ),
      ),
      isTrue,
      reason: 'the failed upload targeted only a same-directory sibling',
    );
    expect(fake.uploads, isEmpty);
    expect(
      fake.commands.any(
        (String command) =>
            command.contains('mv -f') &&
            command.contains("'$root/bin/pluto-embedder'"),
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
      File(
        '${bundle.parent.path}/manifest.json',
      ).writeAsStringSync('{"id":"dev.example.icon","icon":"${fixture.icon}"}');
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
          runtime: <PayloadFile>[
            PayloadFile(
              localPath: runtime.path,
              remoteRelative: 'bin/pluto-embedder',
              executable: true,
            ),
          ],
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
            runtime: const <PayloadFile>[],
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
            runtime: const <PayloadFile>[],
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
          runtime: const <PayloadFile>[],
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
          runtime: const <PayloadFile>[],
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
        runtime: const <PayloadFile>[],
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
    'release-only provision scrubs stale JIT without touching AOT data',
    () async {
      final FakeTransport transport = _moveTransport('h');

      await LiveDeviceOperations(transport).provision(
        runtime: const <PayloadFile>[],
        apps: const <PayloadApp>[],
        payloadTarget: 'linux-arm64',
      );

      final String cleanup = transport.commands.singleWhere(
        (String command) => command.contains('flutterKernel'),
      );
      expect(cleanup, contains("'$root/engine'/.*.pluto-new-*"));
      expect(cleanup, contains("'$root/engine'/.*.pluto-old-*"));
      expect(cleanup, contains("'$root/apps'/.*.pluto-new-*"));
      expect(cleanup, contains("'$root/apps'/.*.pluto-old-*"));
      expect(cleanup, contains("'$root'/.launcher.pluto-new-*"));
      expect(cleanup, contains("'$root'/.launcher.pluto-old-*"));
      expect(cleanup, contains(r'"$flavor_dir"/.*.pluto-new-*'));
      expect(cleanup, contains(r'"$flavor_dir"/.*.pluto-old-*'));
      expect(cleanup, contains("for engine in '$root/engine'/*"));
      expect(cleanup, contains(r'case "$flavor" in release|profile'));
      expect(cleanup, contains(r'mv "$engine" "$stale"'));
      expect(cleanup, contains('"(buildMode|engineFlavor)"'));
      expect(cleanup, contains('"(flutter-kernel|flutterKernel)"'));
      expect(cleanup, contains(r'$d/bundle/flutter_assets/kernel_blob.bin'));
      expect(cleanup, contains(r'mv "$d" "$stale"'));
      expect(cleanup, contains('$root/state/default-app'));
      expect(cleanup, contains('$root/state/apps-changed'));
      expect(cleanup, isNot(contains('$root/appdata')));
      expect(
        cleanup,
        isNot(contains("rm -rf '$root/apps'")),
        reason: 'only positively identified debug app directories are removed',
      );
      expect(
        transport.commands.indexOf(cleanup),
        lessThan(
          transport.commands.indexWhere(
            (String command) =>
                command.contains('pluto-boot-install.sh') &&
                command.contains(' uninstall'),
          ),
        ),
        reason: 'stale JIT state cannot survive into final boot policy',
      );
    },
  );

  test(
    'release-only cleanup preserves appdata and unselected AOT apps',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync('pluto_jit');
      addTearDown(() => temp.deleteSync(recursive: true));
      final String deviceRoot = '${temp.path}/pluto';

      void write(String relative, String contents) {
        File('$deviceRoot/$relative')
          ..createSync(recursive: true)
          ..writeAsStringSync(contents);
      }

      write('engine/debug/libflutter_engine.so', 'jit-engine');
      write('engine/current/libflutter_engine.so', 'legacy-jit-engine');
      write('state/default-app', 'dev.example.debug-record\n');
      write(
        'apps/dev.example.debug-record/install.json',
        '{"buildMode":"debug","engineFlavor":"debug"}',
      );
      write(
        'apps/dev.example.legacy/manifest.json',
        '{"runtime":{"type":"flutterKernel"}}',
      );
      write(
        'apps/dev.example.kernel/bundle/flutter_assets/kernel_blob.bin',
        'kernel',
      );
      write(
        'apps/dev.example.release/install.json',
        '{"buildMode":"release","engineFlavor":"release"}',
      );
      write(
        'apps/dev.example.release/manifest.json',
        '{"runtime":{"type":"flutter-aot"}}',
      );
      write('apps/dev.example.release/bundle/lib/app.so', 'release');
      write('apps/dev.example.unrecorded-aot/bundle/lib/app.so', 'aot');
      for (final String appId in <String>[
        'dev.example.debug-record',
        'dev.example.legacy',
        'dev.example.kernel',
        'dev.example.release',
        'dev.example.unrecorded-aot',
      ]) {
        write('appdata/$appId/keep', 'user data');
      }

      final FakeTransport transport = _moveTransport('local');
      await LiveDeviceOperations(transport, deviceRoot: deviceRoot).provision(
        runtime: const <PayloadFile>[],
        apps: const <PayloadApp>[],
        payloadTarget: 'linux-arm64',
      );
      final String cleanup = transport.commands.singleWhere(
        (String command) => command.contains('flutterKernel'),
      );

      final ProcessResult result = await Process.run('sh', <String>[
        '-c',
        cleanup,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(Directory('$deviceRoot/engine/debug').existsSync(), isFalse);
      expect(Directory('$deviceRoot/engine/current').existsSync(), isFalse);
      for (final String appId in <String>[
        'dev.example.debug-record',
        'dev.example.legacy',
        'dev.example.kernel',
      ]) {
        expect(
          Directory('$deviceRoot/apps/$appId').existsSync(),
          isFalse,
          reason: '$appId is stale JIT state',
        );
      }
      for (final String appId in <String>[
        'dev.example.release',
        'dev.example.unrecorded-aot',
      ]) {
        expect(
          Directory('$deviceRoot/apps/$appId').existsSync(),
          isTrue,
          reason: '$appId is an unselected AOT app and must survive',
        );
      }
      expect(File('$deviceRoot/state/default-app').existsSync(), isFalse);
      expect(File('$deviceRoot/state/apps-changed').existsSync(), isTrue);
      for (final FileSystemEntity data in Directory(
        '$deviceRoot/appdata',
      ).listSync()) {
        expect(File('${data.path}/keep').readAsStringSync(), 'user data');
      }
    },
  );

  test(
    'release-only cleanup removes only hidden transaction remnants',
    () async {
      final Directory temp = Directory.systemTemp.createTempSync(
        'pluto_hidden_transactions',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final String deviceRoot = '${temp.path}/pluto';

      void write(String relative, String contents) {
        File('$deviceRoot/$relative')
          ..createSync(recursive: true)
          ..writeAsStringSync(contents);
      }

      write('engine/release/libflutter_engine.so', 'release');
      write('engine/profile/libflutter_engine.so', 'profile');
      write('engine/.debug.pluto-new-interrupted/libflutter_engine.so', 'jit');
      write(
        'engine/.current.pluto-old-interrupted/libflutter_engine.so',
        'jit',
      );
      write(
        'engine/release/.libflutter_engine.so.pluto-new-interrupted',
        'partial-release',
      );
      write(
        'engine/profile/.libflutter_engine.so.pluto-old-interrupted',
        'old-profile',
      );
      write('apps/dev.example.release/bundle/lib/app.so', 'release');
      write(
        'apps/dev.example.release/install.json',
        '{"buildMode":"release","engineFlavor":"release"}',
      );
      write('launcher/bundle/lib/app.so', 'release-launcher');
      write(
        'apps/.dev.example.jit.pluto-new-interrupted/'
            'bundle/flutter_assets/kernel_blob.bin',
        'kernel',
      );
      write(
        'apps/.dev.example.jit.pluto-old-interrupted/install.json',
        '{"buildMode":"debug","engineFlavor":"debug"}',
      );
      write(
        '.launcher.pluto-new-interrupted/'
            'bundle/flutter_assets/kernel_blob.bin',
        'kernel',
      );
      write(
        '.launcher.pluto-old-interrupted/'
            'bundle/flutter_assets/kernel_blob.bin',
        'kernel',
      );
      write('engine/.unrelated-hidden/keep', 'keep');
      write('apps/.unrelated-hidden/keep', 'keep');
      write('.unrelated-hidden/keep', 'keep');
      write('state/.session.pluto-new-keep', 'keep');
      write('appdata/.user.pluto-old-keep/documents/keep', 'keep');

      final FakeTransport transport = _moveTransport('local');
      await LiveDeviceOperations(transport, deviceRoot: deviceRoot).provision(
        runtime: const <PayloadFile>[],
        apps: const <PayloadApp>[],
        payloadTarget: 'linux-arm64',
      );
      final String cleanup = transport.commands.singleWhere(
        (String command) => command.contains('flutterKernel'),
      );

      final ProcessResult result = await Process.run('sh', <String>[
        '-c',
        cleanup,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');

      for (final String removed in <String>[
        'engine/.debug.pluto-new-interrupted',
        'engine/.current.pluto-old-interrupted',
        'engine/release/.libflutter_engine.so.pluto-new-interrupted',
        'engine/profile/.libflutter_engine.so.pluto-old-interrupted',
        'apps/.dev.example.jit.pluto-new-interrupted',
        'apps/.dev.example.jit.pluto-old-interrupted',
        '.launcher.pluto-new-interrupted',
        '.launcher.pluto-old-interrupted',
      ]) {
        expect(
          FileSystemEntity.typeSync('$deviceRoot/$removed'),
          FileSystemEntityType.notFound,
          reason: '$removed is an interrupted transaction remnant',
        );
      }
      for (final String preserved in <String>[
        'engine/release/libflutter_engine.so',
        'engine/profile/libflutter_engine.so',
        'apps/dev.example.release/bundle/lib/app.so',
        'launcher/bundle/lib/app.so',
        'engine/.unrelated-hidden/keep',
        'apps/.unrelated-hidden/keep',
        '.unrelated-hidden/keep',
        'state/.session.pluto-new-keep',
        'appdata/.user.pluto-old-keep/documents/keep',
      ]) {
        expect(
          File('$deviceRoot/$preserved').readAsStringSync(),
          isNotEmpty,
          reason: '$preserved is current AOT or unrelated hidden state',
        );
      }
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
          runtime: const <PayloadFile>[],
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
            c.contains('pluto-boot-install.sh') && c.contains(' uninstall'),
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
              command.contains(' uninstall'),
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
    expect(
      transport.commands.any((String c) => c.contains('zz-pluto.conf')),
      isTrue,
      reason: 'last-resort cleanup removes only the live-slot drop-in',
    );
    final String command = transport.commands.singleWhere(
      (String command) => command.contains('pluto-uninstall.sh'),
    );
    final int bootFallback = command.indexOf(
      "elif [ -x '$root/bin/pluto-boot-install.sh' ]",
    );
    final int safeUninstall = command.indexOf(
      "sh '$root/bin/pluto-boot-install.sh' uninstall",
    );
    final int deleteRuntime = command.indexOf("rm -rf '$root'");
    expect(bootFallback, greaterThanOrEqualTo(0));
    expect(safeUninstall, greaterThan(bootFallback));
    expect(
      deleteRuntime,
      greaterThan(safeUninstall),
      reason: 'runtime deletion follows the authoritative A/B-safe uninstall',
    );
    expect(
      command,
      contains(
        'runtime preserved because a peer-slot boot override may remain',
      ),
      reason: 'missing authoritative scripts must fail without deleting ROOT',
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
    final FakeUpload installUpload = transport.uploads.singleWhere(
      (FakeUpload upload) =>
          upload.remotePath.endsWith('/install.json.pending'),
    );
    final Map<String, Object?> install =
        jsonDecode(utf8.decode(installUpload.bytes)) as Map<String, Object?>;
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
      expect(
        transport.uploads.any(
          (FakeUpload upload) =>
              upload.remotePath.endsWith('/external.manifest.json'),
        ),
        isFalse,
      );
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

  test('installPackage hard-rejects legacy runtime spelling', () async {
    final Directory temp = Directory.systemTemp.createTempSync('pluto_pkg');
    addTearDown(() => temp.deleteSync(recursive: true));
    const String prefix = 'targets/linux-arm64/';
    final File plap = _writeRawPlap(temp, 'legacy-runtime', <PackageEntry>[
      PackageEntry(path: 'manifest.json', bytes: _legacyManifest('flutterAot')),
      PackageEntry(
        path: '${prefix}build-metadata.json',
        bytes: _releaseMetadata('linux-arm64'),
      ),
      PackageEntry(path: '${prefix}bundle/lib/app.so', bytes: releaseAotElf()),
      PackageEntry(
        path: '${prefix}bundle/flutter_assets/AssetManifest.bin',
        bytes: Uint8List.fromList(<int>[1]),
      ),
    ]);
    final FakeTransport transport = FakeTransport(
      endpoint: const DeviceEndpoint(host: 'h'),
    );

    await expectLater(
      LiveDeviceOperations(transport).installPackage(plap.path),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('runtime flutterAot does not match'),
        ),
      ),
    );

    expect(transport.commands, isEmpty);
    expect(transport.uploads, isEmpty);
  });

  test('installPackage hard-rejects the old flat archive layout', () async {
    final Directory temp = Directory.systemTemp.createTempSync('pluto_pkg');
    addTearDown(() => temp.deleteSync(recursive: true));
    final File plap = _writeRawPlap(temp, 'legacy-flat', <PackageEntry>[
      PackageEntry(
        path: 'manifest.json',
        bytes: _legacyManifest('flutter-aot'),
      ),
      PackageEntry(
        path: 'build-metadata.json',
        bytes: _releaseMetadata('linux-arm64'),
      ),
      PackageEntry(path: 'bundle/lib/app.so', bytes: releaseAotElf()),
      PackageEntry(
        path: 'bundle/flutter_assets/AssetManifest.bin',
        bytes: Uint8List.fromList(<int>[1]),
      ),
    ]);
    final FakeTransport transport = FakeTransport(
      endpoint: const DeviceEndpoint(host: 'h'),
    );

    await expectLater(
      LiveDeviceOperations(transport).installPackage(plap.path),
      throwsA(
        isA<ArtifactVerificationException>().having(
          (ArtifactVerificationException error) => error.message,
          'message',
          contains('Non-canonical top-level package path'),
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

    expect(request['schema'], 1);
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
