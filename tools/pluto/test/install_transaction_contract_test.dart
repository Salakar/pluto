import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pluto_cli/src/build/package_builder.dart';
import 'package:pluto_cli/src/process.dart';
import 'package:pluto_cli/src/run/device_operations.dart';
import 'package:pluto_cli/src/ssh/device_transport.dart';
import 'package:test/test.dart';

import 'support/aot_fixture.dart';

/// Contract test: drives [LiveDeviceOperations.installPackage] against a
/// local `sh` and the REAL `tools/device/pluto-install-transaction.sh`, so
/// the CLI's staging layout and the device-side transaction cannot drift
/// apart again (the pre-rewrite CLI targeted a divergent layout that the
/// script rejected).
void main() {
  late Directory temp;
  late String root;
  late String runDir;
  late _LocalShellTransport transport;
  late LiveDeviceOperations ops;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('pluto_contract');
    root = '${temp.path}/pluto';
    runDir = '${temp.path}/run';
    Directory('$root/bin').createSync(recursive: true);
    final File script = File(
      '${Directory.current.path}/../device/pluto-install-transaction.sh',
    );
    final File appControl = File(
      '${Directory.current.path}/../device/pluto-app-control.sh',
    );
    expect(
      script.existsSync(),
      isTrue,
      reason: 'run tests from tools/pluto (found: ${script.path})',
    );
    script.copySync('$root/bin/pluto-install-transaction.sh');
    appControl.copySync('$root/bin/pluto-app-control.sh');
    await Process.run('chmod', <String>[
      '+x',
      '$root/bin/pluto-install-transaction.sh',
      '$root/bin/pluto-app-control.sh',
    ]);
    transport = _LocalShellTransport(const DeviceEndpoint(host: 'local'));
    ops = LiveDeviceOperations(transport, deviceRoot: root, runDir: runDir);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<File> buildPlap() async {
    final PlapPackage package =
        await const PlapPackageBuilder(compressor: NoopCompressor()).build(
          source: MemoryPackageSource(<PackageEntry>[
            PackageEntry(
              path: 'manifest.json',
              bytes: Uint8List.fromList(
                utf8.encode(
                  '{"id":"dev.example.notes","name":"Notes","runtime":'
                  '{"type":"flutter-aot","appElf":"lib/app.so",'
                  '"assets":"flutter_assets"}}',
                ),
              ),
            ),
            PackageEntry(path: 'bundle/lib/app.so', bytes: releaseAotElf()),
            PackageEntry(
              path: 'bundle/flutter_assets/AssetManifest.bin',
              bytes: Uint8List.fromList(<int>[4]),
            ),
          ]),
          metadata: const PackageMetadata(
            flutterVersion: '3.44.4',
            engineCommit: 'abc',
            plutoVersion: '0.1.0',
          ),
        );
    return File('${temp.path}/app.plap')..writeAsBytesSync(package.bytes);
  }

  test('installPackage commits through the real transaction script', () async {
    final File plap = await buildPlap();
    final DeviceOperationResult result = await ops.installPackage(
      plap.path,
      launch: true,
      setDefault: true,
    );

    expect(result.ok, isTrue);
    final String app = '$root/apps/dev.example.notes';
    expect(File('$app/manifest.json').existsSync(), isTrue);
    expect(File('$app/bundle/lib/app.so').existsSync(), isTrue);
    expect(
      File('$app/install.json').existsSync(),
      isTrue,
      reason: 'pending record must be promoted by the transaction',
    );
    expect(File('$app/install.json.pending').existsSync(), isFalse);
    expect(
      File('$root/state/apps.rev').existsSync(),
      isTrue,
      reason: 'registry revision bumped for the launcher',
    );
    expect(
      Directory(
        '$root/staging',
      ).listSync().where((FileSystemEntity e) => !e.path.contains('.DS_Store')),
      isEmpty,
      reason: 'no staging leftovers after a clean install',
    );
    expect(
      File('$root/state/default-app').readAsStringSync().trim(),
      'dev.example.notes',
    );
    expect(
      File('$runDir/launch').readAsStringSync().trim(),
      'dev.example.notes',
    );
  });

  test('reinstall needs --force and force replaces cleanly', () async {
    final File plap = await buildPlap();
    await ops.installPackage(plap.path);
    await expectLater(
      ops.installPackage(plap.path),
      throwsA(isA<DeviceOperationException>()),
    );
    final Process oldVersion = await Process.start('sh', <String>[
      '-c',
      'exec sleep 1000',
    ]);
    addTearDown(() {
      oldVersion.kill(ProcessSignal.sigkill);
    });
    final Directory warm = Directory('$runDir/warm-apps')
      ..createSync(recursive: true);
    File(
      '${warm.path}/dev.example.notes.pid',
    ).writeAsStringSync('${oldVersion.pid}\n');
    File('${warm.path}/dev.example.notes.used').writeAsStringSync('1\n');
    final Directory hibernated = Directory('$runDir/hibernated')
      ..createSync(recursive: true);
    File('${hibernated.path}/${oldVersion.pid}').writeAsStringSync('paused\n');

    final DeviceOperationResult forced = await ops.installPackage(
      plap.path,
      force: true,
    );
    expect(forced.ok, isTrue);
    await oldVersion.exitCode.timeout(const Duration(seconds: 5));
    expect(File('${warm.path}/dev.example.notes.pid').existsSync(), isFalse);
    expect(File('${hibernated.path}/${oldVersion.pid}').existsSync(), isFalse);
    expect(
      File('$root/apps/dev.example.notes/install.json').existsSync(),
      isTrue,
    );
  });
}

/// Runs "device" commands with the local `sh` and materializes uploads to
/// the local filesystem, so device scripts execute for real.
final class _LocalShellTransport implements DeviceTransport {
  _LocalShellTransport(this.endpoint);

  @override
  final DeviceEndpoint endpoint;

  @override
  Future<bool> canConnect({
    Duration timeout = const Duration(seconds: 2),
  }) async => true;

  @override
  Future<CommandResult> exec(
    String command, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (command == 'cat /sys/devices/soc0/machine') {
      return const CommandResult(exitCode: 0, stdout: 'imx93-chiappa\n');
    }
    if (command == 'uname -m') {
      return const CommandResult(exitCode: 0, stdout: 'aarch64\n');
    }
    if (command == 'cat /proc/device-tree/compatible') {
      return const CommandResult(exitCode: 0, stdout: 'fsl,imx93\n');
    }
    final ProcessResult result = await Process.run('sh', <String>[
      '-c',
      command,
    ]);
    return CommandResult(
      exitCode: result.exitCode,
      stdout: result.stdout as String,
      stderr: result.stderr as String,
    );
  }

  @override
  Future<void> uploadFileBytes({
    required Uint8List bytes,
    required String remotePath,
    bool executable = false,
  }) async {
    final File file = File(remotePath)..parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    if (executable) {
      await Process.run('chmod', <String>['+x', remotePath]);
    }
  }

  @override
  Future<Uint8List> downloadFileBytes({
    required String remotePath,
    int? expectedBytes,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final Uint8List bytes = await File(remotePath).readAsBytes();
    if (expectedBytes != null && bytes.length != expectedBytes) {
      throw StateError('unexpected local download length');
    }
    return bytes;
  }

  @override
  Future<void> uploadDirectory({
    required String localPath,
    required String remotePath,
  }) async {
    Directory(remotePath).createSync(recursive: true);
    final ProcessResult result = await Process.run('sh', <String>[
      '-c',
      "tar -C '$localPath' -cf - . | tar -C '$remotePath' -xf -",
    ]);
    if (result.exitCode != 0) {
      throw StateError('local dir copy failed: ${result.stderr}');
    }
  }

  @override
  Future<PortForwardHandle> forwardPort({
    required int hostPort,
    required int devicePort,
    RegExp? successPattern,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    throw UnimplementedError('no port forwarding in the local shell fake');
  }
}
