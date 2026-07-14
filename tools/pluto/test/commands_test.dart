import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pluto_cli/pluto.dart';
import 'package:pluto_cli/src/build/plap_reader.dart';
import 'package:pluto_cli/src/commands/install_command.dart';
import 'package:test/test.dart';

import 'support/aot_fixture.dart';

const String _engineHash = 'a10d8ac38de835021c8d2f920dbf50a920ccc030';
const String _codexVersion = '0.144.1';

Uint8List _testCodexBinary() => Uint8List.fromList(<int>[
  ...releaseArmAotElf(),
  ...utf8.encode('\nCodex CLI release $_codexVersion\n'),
]);

Future<CommandResult> _moveExecHandler(String command) async {
  if (command == 'cat /sys/devices/soc0/machine') {
    return const CommandResult(exitCode: 0, stdout: 'imx93-chiappa');
  }
  if (command == 'uname -m') {
    return const CommandResult(exitCode: 0, stdout: 'aarch64');
  }
  return const CommandResult(exitCode: 0);
}

Future<CommandResult> _rm2ExecHandler(String command) async {
  if (command == 'cat /sys/devices/soc0/machine') {
    return const CommandResult(exitCode: 0, stdout: 'reMarkable 2.0');
  }
  if (command == 'uname -m') {
    return const CommandResult(exitCode: 0, stdout: 'armv7l');
  }
  if (command == 'cat /etc/version') {
    return const CommandResult(exitCode: 0, stdout: '20260629074044');
  }
  if (command == 'cat /usr/share/remarkable/update.conf') {
    return const CommandResult(
      exitCode: 0,
      stdout: 'REMARKABLE_RELEASE_VERSION=3.28.0.162\n',
    );
  }
  if (command == "sha256sum /usr/bin/xochitl | awk '{print \$1}'") {
    return const CommandResult(
      exitCode: 0,
      stdout:
          'e0fef1de8e4644b6ef6d829436deaa8d8e8a083c14a806f6300b2de248199b18',
    );
  }
  return const CommandResult(exitCode: 0);
}

FakeExecHandler _moveExecWith(FakeExecHandler fallback) =>
    (String command) async {
      if (command == 'cat /sys/devices/soc0/machine' || command == 'uname -m') {
        return _moveExecHandler(command);
      }
      return fallback(command);
    };

Future<CommandResult> _rm2ControlExecHandler(String command) async {
  if (command == 'cat /sys/devices/soc0/machine' ||
      command == 'uname -m' ||
      command == 'cat /etc/version' ||
      command == 'cat /usr/share/remarkable/update.conf' ||
      command == "sha256sum /usr/bin/xochitl | awk '{print \$1}'") {
    return _rm2ExecHandler(command);
  }
  if (command.contains('qt-resource-rebuilder/hashtab') &&
      command.contains('sha256sum')) {
    return const CommandResult(
      exitCode: 0,
      stdout:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
  }
  if (command.contains('PLUTO-ACTIVATION-PREFLIGHT')) {
    return const CommandResult(
      exitCode: 0,
      stdout: 'PLUTO-ACTIVATION-PREFLIGHT|123|absent|absent\n',
    );
  }
  if (command.contains('PLUTO-DEFAULT-STATE|')) {
    return const CommandResult(
      exitCode: 0,
      stdout: 'PLUTO-DEFAULT-STATE|absent\n',
    );
  }
  if (command.contains('pluto-apploadctl') && command.contains('--request')) {
    final RegExpMatch? match = RegExp(
      r"--request '([^']+)'",
    ).firstMatch(command);
    if (match == null) {
      return const CommandResult(exitCode: 64, stderr: 'missing request');
    }
    final Map<String, Object?> request =
        jsonDecode(match.group(1)!) as Map<String, Object?>;
    final String action = request['action']! as String;
    return CommandResult(
      exitCode: 0,
      stdout: jsonEncode(<String, Object?>{
        'schema': 1,
        'requestId': request['requestId'],
        'ok': true,
        'result': <String, Object?>{
          if (action == 'ping') 'protocol': 1,
          if (action == 'stop') 'stopped': false,
          if (action == 'reload') 'entryCount': 1,
        },
      }),
    );
  }
  return const CommandResult(exitCode: 0);
}

void main() {
  test('runner exposes required top-level commands', () {
    final _CommandHarness harness = _CommandHarness();
    addTearDown(harness.dispose);

    final Set<String> commandNames = buildCommandRunner(
      environment: harness.environment,
    ).commands.keys.toSet();

    expect(
      commandNames,
      containsAll(<String>[
        'doctor',
        'devices',
        'run',
        'attach',
        'build',
        'install',
        'provision',
        'uninstall',
        'screenshot',
        'logs',
        'cleanup',
      ]),
    );
  });

  test(
    'devices --probe exposes the selected target and capabilities',
    () async {
      final _CommandHarness harness = _CommandHarness(
        reachable: true,
        execHandler: _rm2ExecHandler,
      );
      addTearDown(harness.dispose);

      final int? exitCode = await buildCommandRunner(
        environment: harness.environment,
      ).run(<String>['devices', '--probe', '--json', '--device', '10.11.99.1']);

      expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
      final List<Object?> decoded =
          jsonDecode(harness.out.toString()) as List<Object?>;
      final Map<String, Object?> device =
          decoded.single! as Map<String, Object?>;
      expect(device['model'], 'zero-sugar');
      expect(device['architecture'], 'armv7l');
      expect(device['firmwareBuild'], '20260629074044');
      expect(device['firmwareVersion'], '3.28.0.162');
      expect(device['target'], 'linux-arm');
      expect(device['buildModes'], <Object?>['release']);
      expect(device['capabilities'] as List<Object?>, contains('screenshot'));
    },
  );

  test('build bundle requires an explicit debug opt-in', () async {
    final _CommandHarness harness = _CommandHarness();
    addTearDown(harness.dispose);

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['build', 'bundle', '--no-live']);

    expect(exitCode, ExitCodes.usage);
    expect(harness.err.toString(), contains('pass --debug explicitly'));
  });

  test('build bundle --debug keeps the hot-reload path available', () async {
    final _CommandHarness harness = _CommandHarness();
    addTearDown(harness.dispose);

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['build', 'bundle', '--debug', '--no-live']);

    expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
    expect(harness.out.toString(), contains('build/pluto/debug'));
  });

  test('unflagged package --from-layout expects release', () async {
    final _CommandHarness harness = _CommandHarness();
    addTearDown(harness.dispose);
    final Directory layout = Directory('${harness.temp.path}/layout')
      ..createSync();
    _writeLayout(
      layout.path,
      appId: 'dev.example.profile',
      mode: PlutoBuildMode.profile,
    );

    final int? exitCode =
        await buildCommandRunner(environment: harness.environment).run(<String>[
          'build',
          'package',
          '--no-live',
          '--from-layout',
          layout.path,
          '--compression',
          'none',
          '-o',
          '${harness.temp.path}/out/app.plap',
        ]);

    expect(exitCode, ExitCodes.failure);
    expect(harness.err.toString(), contains('profile, not release'));
  });

  test('build package --profile preserves the layout profile mode', () async {
    final _CommandHarness harness = _CommandHarness();
    addTearDown(harness.dispose);
    final Directory layout = Directory('${harness.temp.path}/layout')
      ..createSync();
    _writeLayout(
      layout.path,
      appId: 'dev.example.profile',
      mode: PlutoBuildMode.profile,
    );
    final String output = '${harness.temp.path}/out/app.plap';

    final int? exitCode =
        await buildCommandRunner(environment: harness.environment).run(<String>[
          'build',
          'package',
          '--profile',
          '--no-live',
          '--from-layout',
          layout.path,
          '--compression',
          'none',
          '-o',
          output,
        ]);

    expect(exitCode, ExitCodes.ok);
    expect(File(output).existsSync(), isTrue);
    expect((await PlapArchive.read(output)).buildMode, 'profile');
    expect(harness.out.toString(), contains('Wrote'));
  });

  test('build package supports an explicit debug hot-reload payload', () async {
    final _CommandHarness harness = _CommandHarness();
    addTearDown(harness.dispose);
    final Directory layout = Directory('${harness.temp.path}/debug-layout')
      ..createSync();
    _writeLayout(
      layout.path,
      appId: 'dev.example.debug',
      mode: PlutoBuildMode.debug,
    );
    final String output = '${harness.temp.path}/out/debug.plap';

    final int? exitCode =
        await buildCommandRunner(environment: harness.environment).run(<String>[
          'build',
          'package',
          '--debug',
          '--no-live',
          '--from-layout',
          layout.path,
          '--compression',
          'none',
          '-o',
          output,
        ]);

    expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
    final PlapArchive archive = await PlapArchive.read(output);
    expect(archive.buildMode, 'debug');
    expect(
      readTarEntries(archive.tarBytes).map((PlapEntry entry) => entry.path),
      contains('bundle/flutter_assets/kernel_blob.bin'),
    );
  });

  test('build package refuses a mode flag that relabels a layout', () async {
    final _CommandHarness harness = _CommandHarness();
    addTearDown(harness.dispose);
    final Directory layout = Directory('${harness.temp.path}/profile-layout')
      ..createSync();
    _writeLayout(
      layout.path,
      appId: 'dev.example.profile',
      mode: PlutoBuildMode.profile,
    );

    final int? exitCode =
        await buildCommandRunner(environment: harness.environment).run(<String>[
          'build',
          'package',
          '--release',
          '--no-live',
          '--from-layout',
          layout.path,
          '--compression',
          'none',
          '-o',
          '${harness.temp.path}/out/wrong.plap',
        ]);

    expect(exitCode, ExitCodes.failure);
    expect(harness.err.toString(), contains('profile, not release'));
  });

  test('profile app defaults to a mode-named output directory', () async {
    final _CommandHarness harness = _CommandHarness();
    addTearDown(harness.dispose);

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['build', 'app', '--profile', '--no-live']);

    expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
    expect(harness.out.toString(), contains('build/pluto/profile'));
    expect(harness.out.toString(), isNot(contains('build/pluto/release')));
  });

  test('build app accepts the explicit linux-arm target', () async {
    final _CommandHarness harness = _CommandHarness();
    addTearDown(harness.dispose);

    final int? exitCode =
        await buildCommandRunner(environment: harness.environment).run(<String>[
          'build',
          'app',
          '--release',
          '--no-live',
          '--target-platform',
          'linux-arm',
        ]);

    expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
    expect(harness.out.toString(), contains('build/pluto/release'));
  });

  test('build app selects the connected device target automatically', () async {
    final _CommandHarness harness = _CommandHarness(
      reachable: true,
      execHandler: _rm2ExecHandler,
    );
    addTearDown(harness.dispose);

    final int? exitCode =
        await buildCommandRunner(environment: harness.environment).run(<String>[
          'build',
          'app',
          '--release',
          '--no-live',
          '--device',
          '10.11.99.1',
        ]);

    expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
    expect(harness.out.toString(), contains('build/pluto/release-arm'));
  });

  test(
    'build refuses an advanced target override for another device',
    () async {
      final _CommandHarness harness = _CommandHarness(
        reachable: true,
        execHandler: _rm2ExecHandler,
      );
      addTearDown(harness.dispose);

      final int? exitCode =
          await buildCommandRunner(
            environment: harness.environment,
          ).run(<String>[
            'build',
            'app',
            '--no-live',
            '--device',
            '10.11.99.1',
            '--target-platform',
            'linux-arm64',
          ]);

      expect(exitCode, ExitCodes.usage);
      expect(harness.err.toString(), contains('does not match the connected'));
    },
  );

  test('install honors --force/--launch/--set-default and the build '
      'package path', () async {
    final _CommandHarness harness = _CommandHarness(
      reachable: true,
      execHandler: _moveExecHandler,
    );
    addTearDown(harness.dispose);
    final PlapPackage package =
        await const PlapPackageBuilder(compressor: NoopCompressor()).build(
          source: MemoryPackageSource(<PackageEntry>[
            PackageEntry(
              path: 'manifest.json',
              bytes: Uint8List.fromList(
                utf8.encode(
                  '{"id":"dev.example.notes","runtime":'
                  '{"type":"flutter-aot","appElf":"lib/app.so",'
                  '"assets":"flutter_assets"}}',
                ),
              ),
            ),
            PackageEntry(path: 'bundle/lib/app.so', bytes: releaseAotElf()),
            PackageEntry(
              path: 'bundle/flutter_assets/AssetManifest.bin',
              bytes: Uint8List.fromList(<int>[2]),
            ),
          ]),
          metadata: const PackageMetadata(
            flutterVersion: '3.44.4',
            engineCommit: _engineHash,
            plutoVersion: '0.1.0',
          ),
        );
    // Default package location must match `pluto build package -o`.
    final File plap = File('${harness.temp.path}/build/pluto/app.plap')
      ..createSync(recursive: true)
      ..writeAsBytesSync(package.bytes);
    expect(
      plap.path,
      InstallCommand.defaultPackagePath(harness.temp.path),
      reason: 'install --from-build must read where build package writes',
    );

    final int? exitCode =
        await buildCommandRunner(environment: harness.environment).run(<String>[
          'install',
          '--from-build',
          '--force',
          '--launch',
          '--set-default',
          '-d',
          '10.11.99.1',
        ]);

    expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
    expect(harness.out.toString(), contains('Installed dev.example.notes'));
    final FakeTransport transport = harness.transports.single;
    expect(
      transport.commands.any(
        (String c) =>
            c.contains('pluto-install-transaction.sh') &&
            c.contains("commit 'dev.example.notes'"),
      ),
      isTrue,
    );
    expect(
      transport.commands.any((String c) => c.contains("> '/run/pluto/launch'")),
      isTrue,
      reason: '--launch requests a supervisor swap',
    );
    expect(
      transport.commands.any((String c) => c.contains('state/default-app')),
      isTrue,
      reason: '--set-default records the boot default',
    );
    expect(
      transport.commands.any((String c) => c.contains('&& echo exists')),
      isFalse,
      reason: '--force skips the already-installed check',
    );
  });

  test(
    'install rejects an unflagged profile package before device I/O',
    () async {
      final _CommandHarness harness = _CommandHarness(reachable: true);
      addTearDown(harness.dispose);
      final File package = await _writePackageForMode(
        harness.temp,
        appId: 'dev.example.profile',
        mode: PlutoBuildMode.profile,
      );

      final int? exitCode = await buildCommandRunner(
        environment: harness.environment,
      ).run(<String>['install', '-d', '10.11.99.1', package.path]);

      expect(exitCode, ExitCodes.failure);
      expect(harness.err.toString(), contains('profile, not release'));
      expect(harness.transports, isEmpty);
    },
  );

  test('install routes a linux-arm package through AppLoad', () async {
    final _CommandHarness harness = _CommandHarness(
      reachable: true,
      execHandler: _rm2ControlExecHandler,
    );
    addTearDown(harness.dispose);
    final File package = await _writePackageForMode(
      harness.temp,
      appId: 'dev.example.arm',
      mode: PlutoBuildMode.release,
      target: PlutoTargetPlatform.linuxArm,
    );

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['install', '-d', '10.11.99.1', package.path]);

    expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
    expect(harness.out.toString(), contains('Installed dev.example.arm'));
    final FakeTransport transport = harness.transports.single;
    expect(
      transport.uploads.any(
        (FakeUpload upload) =>
            upload.remotePath.startsWith(
              '/home/root/xovi/exthome/appload/'
              '.pluto-dev.example.arm.pluto-new-',
            ) &&
            upload.remotePath.endsWith('/external.manifest.json'),
      ),
      isTrue,
      reason: 'the package is registered with the cooperative AppLoad backend',
    );
    expect(
      transport.commands.any(
        (String command) =>
            command.contains('pluto-apploadctl') &&
            command.contains('"action":"reload"'),
      ),
      isTrue,
    );
    expect(
      transport.commands.any(
        (String command) =>
            command.contains('/run/pluto/launch') ||
            command.contains('pluto-boot-install.sh'),
      ),
      isFalse,
      reason: 'ARMv7 install must not enter the direct-runtime control path',
    );
  });

  test('install --profile explicitly installs a profile AOT package', () async {
    final _CommandHarness harness = _CommandHarness(
      reachable: true,
      execHandler: _moveExecHandler,
    );
    addTearDown(harness.dispose);
    final File package = await _writePackageForMode(
      harness.temp,
      appId: 'dev.example.profile',
      mode: PlutoBuildMode.profile,
    );

    final int? exitCode =
        await buildCommandRunner(environment: harness.environment).run(<String>[
          'install',
          '--profile',
          '--force',
          '-d',
          '10.11.99.1',
          package.path,
        ]);

    expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
    expect(harness.out.toString(), contains('Installed dev.example.profile'));
  });

  test('install --launch requires --debug for a debug package', () async {
    final _CommandHarness harness = _CommandHarness(reachable: true);
    addTearDown(harness.dispose);
    final File package = await _writePackageForMode(
      harness.temp,
      appId: 'dev.example.debug',
      mode: PlutoBuildMode.debug,
    );

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['install', '--launch', '-d', '10.11.99.1', package.path]);

    expect(exitCode, ExitCodes.failure);
    expect(harness.err.toString(), contains('debug, not release'));
    expect(harness.err.toString(), contains('JIT/hot-reload'));
    expect(harness.transports, isEmpty);
  });

  test(
    'install --debug installs without minting a launch authorization',
    () async {
      final _CommandHarness harness = _CommandHarness(
        reachable: true,
        execHandler: _moveExecHandler,
      );
      addTearDown(harness.dispose);
      final File package = await _writePackageForMode(
        harness.temp,
        appId: 'dev.example.debug',
        mode: PlutoBuildMode.debug,
      );

      final int? exitCode =
          await buildCommandRunner(environment: harness.environment).run(
            <String>[
              'install',
              '--debug',
              '--force',
              '-d',
              '10.11.99.1',
              package.path,
            ],
          );

      expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
      expect(
        harness.transports.single.commands.any(
          (String command) =>
              command.contains('/run/pluto/launch') ||
              command.contains('/run/pluto/debug-launch'),
        ),
        isFalse,
      );
    },
  );

  test('install --debug --launch fails before device I/O', () async {
    final _CommandHarness harness = _CommandHarness(reachable: true);
    addTearDown(harness.dispose);
    final File package = await _writePackageForMode(
      harness.temp,
      appId: 'dev.example.debug',
      mode: PlutoBuildMode.debug,
    );

    final int? exitCode =
        await buildCommandRunner(environment: harness.environment).run(<String>[
          'install',
          '--debug',
          '--launch',
          '-d',
          '10.11.99.1',
          package.path,
        ]);

    expect(exitCode, ExitCodes.usage);
    expect(harness.err.toString(), contains('pluto run --debug'));
    expect(harness.transports, isEmpty);
  });

  test(
    'default run uses installed release AOT and never forwards a VM port',
    () async {
      final _CommandHarness harness = _CommandHarness(
        reachable: true,
        execHandler: _moveExecWith((String command) async {
          if (command.contains('buildMode')) {
            return const CommandResult(exitCode: 0, stdout: 'release\n');
          }
          return const CommandResult(exitCode: 0);
        }),
      );
      addTearDown(harness.dispose);

      final int? exitCode = await buildCommandRunner(
        environment: harness.environment,
      ).run(<String>['run', '-d', '10.11.99.1', 'dev.example.notes']);

      expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
      expect(harness.out.toString(), contains('release AOT launch'));
      expect(harness.transports.single.forwards, isEmpty);
      expect(
        harness.transports.single.commands.any(
          (String command) => command.contains('/run/pluto/launch'),
        ),
        isTrue,
      );
      expect(
        harness.transports.single.commands.any(
          (String command) => command.contains('/run/pluto/debug-launch'),
        ),
        isFalse,
        reason: 'ordinary release launches never mint debug authorization',
      );
    },
  );

  test('explicit debug run writes only the one-shot debug control', () async {
    final _CommandHarness harness = _CommandHarness(
      reachable: true,
      execHandler: _moveExecWith(
        (String command) async => command.contains('buildMode')
            ? const CommandResult(exitCode: 0, stdout: 'debug\n')
            : const CommandResult(exitCode: 0),
      ),
    );
    addTearDown(harness.dispose);

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['run', '--debug', '-d', '10.11.99.1', 'dev.example.notes']);

    expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
    expect(harness.out.toString(), contains('debug/JIT launch'));
    final FakeTransport transport = harness.transports.single;
    expect(transport.forwards, hasLength(1));
    expect(
      transport.commands.any(
        (String command) => command.contains('/run/pluto/debug-launch'),
      ),
      isTrue,
    );
    expect(
      transport.commands.any(
        (String command) => command.contains("> '/run/pluto/launch'"),
      ),
      isFalse,
      reason: 'debug authorization bypasses the ordinary launch marker',
    );
  });

  test(
    'explicit debug run refuses an installed release before VM forwarding',
    () async {
      final _CommandHarness harness = _CommandHarness(
        reachable: true,
        execHandler: _moveExecWith(
          (String command) async => command.contains('buildMode')
              ? const CommandResult(exitCode: 0, stdout: 'release\n')
              : const CommandResult(exitCode: 0),
        ),
      );
      addTearDown(harness.dispose);

      final int? exitCode =
          await buildCommandRunner(environment: harness.environment).run(
            <String>['run', '--debug', '-d', '10.11.99.1', 'dev.example.notes'],
          );

      expect(exitCode, ExitCodes.failure);
      expect(
        harness.err.toString(),
        contains('installed as release, not debug'),
      );
      expect(harness.transports.single.forwards, isEmpty);
      expect(
        harness.transports.single.commands.any(
          (String command) => command.contains('/run/pluto/launch'),
        ),
        isFalse,
      );
    },
  );

  test('cleanup prints a dry-run table and totals', () async {
    final _CommandHarness harness = _CommandHarness(
      reachable: true,
      execHandler: (String command) async => const CommandResult(
        exitCode: 0,
        stdout:
            'PLUTO-CLEAN|stale-log|12|/home/root/pluto/logs/old.log\n'
            'PLUTO-CLEAN|bin-backup|2048|'
            '/home/root/pluto/bin/pluto-embedder.bak-1\n',
      ),
    );
    addTearDown(harness.dispose);

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['cleanup', '-d', '10.11.99.1']);

    expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
    final String output = harness.out.toString();
    expect(output, contains('stale-log'));
    expect(output, contains('/home/root/pluto/logs/old.log'));
    expect(output, contains('bin-backup'));
    expect(output, contains('2060 KB'));
    expect(output, contains('Pass --apply to delete'));
    expect(
      harness.transports.single.commands.single,
      contains('APPLY=0'),
      reason: 'dry run must not delete',
    );
  });

  test('cleanup --apply --keep-backups deletes and reports', () async {
    final _CommandHarness harness = _CommandHarness(
      reachable: true,
      execHandler: (String command) async => const CommandResult(
        exitCode: 0,
        stdout: 'PLUTO-CLEAN|staging|340|/home/root/pluto/staging/x\n',
      ),
    );
    addTearDown(harness.dispose);

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['cleanup', '--apply', '--keep-backups', '-d', 'usb']);

    expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
    expect(harness.out.toString(), contains('Removed 1 item(s)'));
    final String command = harness.transports.single.commands.single;
    expect(command, contains('APPLY=1'));
    expect(command, contains('KEEP_BAK=1'));
  });

  test(
    'provision stages the canonical layout and installs boot-first',
    () async {
      final _CommandHarness harness = _CommandHarness(
        reachable: true,
        execHandler: _moveExecHandler,
      );
      addTearDown(harness.dispose);
      final String payload = '${harness.temp.path}/payload';
      _writeProvisionRuntime(payload);
      _writeLayout(
        '$payload/apps/dev.pluto.launcher',
        appId: 'dev.pluto.launcher',
        mode: PlutoBuildMode.release,
      );
      _writeLayout(
        '$payload/apps/dev.example.counter',
        appId: 'dev.example.counter',
        mode: PlutoBuildMode.profile,
      );

      final int? exitCode =
          await buildCommandRunner(environment: harness.environment).run(
            <String>['provision', '--payload-dir', payload, '-d', '10.11.99.1'],
          );

      expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
      final FakeTransport transport = harness.transports.single;
      expect(
        transport.uploads.any(
          (FakeUpload u) =>
              u.remotePath.startsWith(
                '/home/root/pluto/bin/'
                '.pluto-session.sh.pluto-new-',
              ) &&
              !u.executable,
        ),
        isTrue,
        reason: 'supervisor uploaded to a same-filesystem sibling first',
      );
      expect(
        transport.uploads.any(
          (FakeUpload u) =>
              u.remotePath.startsWith(
                '/home/root/pluto/bin/'
                '.pluto-power-key-watch.sh.pluto-new-',
              ) &&
              !u.executable,
        ),
        isTrue,
        reason: 'power-key watcher uploaded without truncating the live file',
      );
      expect(
        transport.uploads.any(
          (FakeUpload u) =>
              u.remotePath.startsWith(
                '/home/root/pluto/bin/.pluto-embedder.pluto-new-',
              ) &&
              !u.executable,
        ),
        isTrue,
      );
      expect(
        transport.uploads.any(
          (FakeUpload u) => u.remotePath.startsWith(
            '/home/root/pluto/engine/profile/'
            '.libflutter_engine.so.pluto-new-',
          ),
        ),
        isTrue,
      );
      expect(
        transport.uploads.any(
          (FakeUpload u) => u.remotePath.startsWith(
            '/home/root/pluto/engine/release/'
            '.libflutter_engine.so.pluto-new-',
          ),
        ),
        isTrue,
      );
      expect(
        transport.directoryUploads.any(
          ((String, String) r) =>
              r.$2.startsWith('/home/root/pluto/.launcher.pluto-new-') &&
              r.$2.endsWith('/bundle'),
        ),
        isTrue,
        reason: 'launcher is complete in a sibling before its directory swap',
      );
      expect(
        transport.uploads.any(
          (FakeUpload upload) =>
              upload.remotePath.startsWith(
                '/home/root/pluto/.launcher.pluto-new-',
              ) &&
              upload.remotePath.endsWith('/assets/pluto/icon.png'),
        ),
        isTrue,
        reason: 'manifest-declared root assets are staged with the launcher',
      );
      final FakeUpload counterInstall = transport.uploads.singleWhere(
        (FakeUpload upload) =>
            upload.remotePath.startsWith(
              '/home/root/pluto/apps/'
              '.dev.example.counter.pluto-new-',
            ) &&
            upload.remotePath.endsWith('/install.json'),
      );
      final String installJson = utf8.decode(counterInstall.bytes);
      expect(installJson, contains('"buildMode": "profile"'));
      expect(installJson, contains('"engineFlavor": "profile"'));
      expect(
        transport.commands.any(
          (String c) =>
              c.contains('pluto-boot-install.sh') &&
              c.contains(' install') &&
              c.contains("PLUTO_ROOT='/home/root/pluto'"),
        ),
        isTrue,
        reason: 'boot-first configured against the canonical root',
      );
    },
  );

  test('provision refuses an arm64 layout on RM2 before writes', () async {
    final _CommandHarness harness = _CommandHarness(
      reachable: true,
      execHandler: _rm2ExecHandler,
    );
    addTearDown(harness.dispose);
    final String payload = '${harness.temp.path}/payload';
    _writeProvisionRuntime(payload);
    _writeLayout(
      '$payload/apps/dev.pluto.launcher',
      appId: 'dev.pluto.launcher',
      mode: PlutoBuildMode.release,
    );

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['provision', '--payload-dir', payload, '-d', '10.11.99.1']);

    expect(exitCode, ExitCodes.usage);
    expect(
      harness.err.toString(),
      contains('does not match the connected device'),
    );
    expect(harness.err.toString(), contains('expected linux-arm'));
    final FakeTransport transport = harness.transports.single;
    expect(transport.uploads, isEmpty);
    expect(transport.directoryUploads, isEmpty);
    expect(
      transport.commands.any(
        (String command) =>
            command.startsWith('mkdir ') ||
            command.contains('pluto-boot-install.sh'),
      ),
      isFalse,
    );
  });

  test('provision routes a linux-arm layout through AppLoad', () async {
    final _CommandHarness harness = _CommandHarness(
      reachable: true,
      execHandler: _rm2ControlExecHandler,
    );
    addTearDown(harness.dispose);
    final String payload = '${harness.temp.path}/payload';
    _writeCooperativeProvisionRuntime(payload);
    _writeLayout(
      '$payload/launcher',
      appId: 'dev.pluto.launcher',
      mode: PlutoBuildMode.release,
      target: PlutoTargetPlatform.linuxArm,
    );

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['provision', '--payload-dir', payload, '-d', '10.11.99.1']);

    expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
    expect(harness.out.toString(), contains('Pluto provisioned'));
    final FakeTransport transport = harness.transports.single;
    expect(
      transport.uploads.any(
        (FakeUpload upload) =>
            upload.remotePath.startsWith(
              '/home/root/xovi/exthome/appload/'
              '.pluto-dev.pluto.launcher.pluto-new-',
            ) &&
            upload.remotePath.endsWith('/external.manifest.json'),
      ),
      isTrue,
      reason: 'the launcher is registered in the cooperative app registry',
    );
    expect(
      transport.uploads.any(
        (FakeUpload upload) => upload.remotePath.startsWith(
          '/home/root/pluto/bin/.pluto-apploadctl.pluto-new-',
        ),
      ),
      isTrue,
      reason: 'the matching control client is part of the target runtime',
    );
    expect(
      transport.uploads.any(
        (FakeUpload upload) =>
            upload.remotePath.startsWith(
              '/home/root/pluto/bin/.codex.pluto-new-',
            ) &&
            upload.bytes.length == _testCodexBinary().length,
      ),
      isTrue,
      reason: 'the SHA-pinned real Codex CLI is promoted with the runtime',
    );
    expect(
      transport.commands.any(
        (String command) =>
            command.contains('pluto-apploadctl') &&
            command.contains('"action":"setDefault"'),
      ),
      isTrue,
    );
    expect(
      transport.commands.any(
        (String command) => command.contains('pluto-boot-install.sh'),
      ),
      isFalse,
      reason: 'cooperative devices never receive the direct boot override',
    );
  });

  test(
    'provision rejects missing or tampered Codex before device I/O',
    () async {
      for (final String failure in <String>['missing', 'tampered']) {
        final _CommandHarness harness = _CommandHarness(
          reachable: true,
          execHandler: _rm2ControlExecHandler,
        );
        addTearDown(harness.dispose);
        final String payload = '${harness.temp.path}/payload';
        _writeCooperativeProvisionRuntime(payload);
        _writeLayout(
          '$payload/launcher',
          appId: 'dev.pluto.launcher',
          mode: PlutoBuildMode.release,
          target: PlutoTargetPlatform.linuxArm,
        );
        final File codex = File('$payload/bin/codex');
        if (failure == 'missing') {
          codex.deleteSync();
        } else {
          codex.writeAsBytesSync(<int>[...codex.readAsBytesSync(), 0]);
        }

        final int? exitCode =
            await buildCommandRunner(environment: harness.environment).run(
              <String>[
                'provision',
                '--payload-dir',
                payload,
                '-d',
                '10.11.99.1',
              ],
            );

        expect(exitCode, ExitCodes.usage, reason: failure);
        expect(harness.transports.single.commands, isEmpty, reason: failure);
        expect(harness.transports.single.uploads, isEmpty, reason: failure);
        expect(
          harness.transports.single.directoryUploads,
          isEmpty,
          reason: failure,
        );
      }
    },
  );

  test('provision without a launcher payload fails host-side', () async {
    final _CommandHarness harness = _CommandHarness(reachable: true);
    addTearDown(harness.dispose);
    final String payload = '${harness.temp.path}/payload';
    _writeProvisionRuntime(payload);

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['provision', '--payload-dir', payload, '-d', '10.11.99.1']);

    expect(exitCode, ExitCodes.usage);
    expect(harness.err.toString(), contains('launcher'));
    for (final FakeTransport transport in harness.transports) {
      expect(
        transport.commands,
        isEmpty,
        reason: 'must fail before touching the device',
      );
      expect(transport.uploads, isEmpty);
    }
  });

  test(
    'provision rejects a mismatched release engine before device I/O',
    () async {
      final _CommandHarness harness = _CommandHarness(reachable: true);
      addTearDown(harness.dispose);
      final String payload = '${harness.temp.path}/payload';
      _writeProvisionRuntime(payload, releaseBytes: <int>[9]);
      _writeLayout(
        '$payload/apps/dev.pluto.launcher',
        appId: 'dev.pluto.launcher',
        mode: PlutoBuildMode.release,
      );

      final int? exitCode =
          await buildCommandRunner(environment: harness.environment).run(
            <String>['provision', '--payload-dir', payload, '-d', '10.11.99.1'],
          );

      expect(exitCode, ExitCodes.usage);
      expect(harness.err.toString(), contains('engine checksum mismatch'));
      expect(harness.transports.single.commands, isEmpty);
      expect(harness.transports.single.uploads, isEmpty);
    },
  );

  test('provision rejects the ambiguous legacy top-level engine', () async {
    final _CommandHarness harness = _CommandHarness(reachable: true);
    addTearDown(harness.dispose);
    final String payload = '${harness.temp.path}/payload';
    _writeProvisionRuntime(payload, legacyRelease: true);

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['provision', '--payload-dir', payload, '-d', '10.11.99.1']);

    expect(exitCode, ExitCodes.usage);
    expect(harness.err.toString(), contains('Ambiguous legacy engine'));
    expect(harness.transports.single.commands, isEmpty);
    expect(harness.transports.single.uploads, isEmpty);
  });

  test('provision requires explicit --debug for a JIT engine', () async {
    final _CommandHarness harness = _CommandHarness(reachable: true);
    addTearDown(harness.dispose);
    final String payload = '${harness.temp.path}/payload';
    _writeProvisionRuntime(payload, includeDebug: true);
    _writeLayout(
      '$payload/apps/dev.pluto.launcher',
      appId: 'dev.pluto.launcher',
      mode: PlutoBuildMode.release,
    );

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['provision', '--payload-dir', payload, '-d', '10.11.99.1']);

    expect(exitCode, ExitCodes.usage);
    expect(harness.err.toString(), contains('requires explicit'));
    expect(harness.transports.single.commands, isEmpty);
    expect(harness.transports.single.uploads, isEmpty);
  });

  test('provision --restore-remarkable restores stock boot only', () async {
    final _CommandHarness harness = _CommandHarness(
      reachable: true,
      execHandler: _moveExecHandler,
    );
    addTearDown(harness.dispose);

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['provision', '--restore-remarkable', '-d', 'usb']);

    expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
    expect(harness.out.toString(), contains('Stock reMarkable UI restored'));
    final FakeTransport transport = harness.transports.single;
    expect(
      transport.commands.any(
        (String c) =>
            c.contains('pluto-boot-install.sh') && c.contains(' uninstall'),
      ),
      isTrue,
    );
    expect(
      transport.commands.any((String c) => c.contains('pluto-uninstall.sh')),
      isFalse,
      reason: 'runtime must stay installed',
    );
  });

  test(
    'install --validate-only checks package existence without device',
    () async {
      final _CommandHarness harness = _CommandHarness();
      addTearDown(harness.dispose);
      final File package = File('${harness.temp.path}/app.plap')
        ..writeAsBytesSync(Uint8List.fromList(utf8.encode('package')));

      final int? exitCode = await buildCommandRunner(
        environment: harness.environment,
      ).run(<String>['install', '--validate-only', package.path]);

      expect(exitCode, ExitCodes.ok);
      expect(harness.out.toString(), contains('host-valid'));
    },
  );
}

final class _CommandHarness {
  _CommandHarness({this.reachable = false, this.execHandler}) {
    pins.createSync(recursive: true);
    File('${pins.path}/flutter.version').writeAsStringSync('3.44.4');
    File('${pins.path}/engine.version').writeAsStringSync(_engineHash);
    File(
      '${pins.path}/supported_os.json',
    ).writeAsStringSync('{"supportedOsBuilds":["20260629074044"]}');
    final Uint8List codex = _testCodexBinary();
    File('${pins.path}/codex-armv7.json').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'schema': 1,
        'version': _codexVersion,
        'target': 'linux-arm',
        'sha256': sha256Bytes(codex),
      }),
    );
    _writePinnedEngineArtifact(
      root: temp.path,
      mode: 'release',
      bytes: const <int>[2],
    );
    _writePinnedEngineArtifact(
      root: temp.path,
      mode: 'profile',
      bytes: const <int>[3],
    );
    _writePinnedArmEngineArtifact(root: temp.path);
  }

  final bool reachable;

  final FakeExecHandler? execHandler;

  final List<FakeTransport> transports = <FakeTransport>[];

  final Directory temp = Directory.systemTemp.createTempSync('pluto-command-');

  late final Directory pins = Directory('${temp.path}/pins');

  final StringBuffer out = StringBuffer();

  final StringBuffer err = StringBuffer();

  late final PlutoCliEnvironment environment = PlutoCliEnvironment(
    paths: PlutoPaths(
      packageRoot: temp.path,
      homeDirectory: temp.path,
      repositoryRootOverride: temp.path,
    ),
    hostEnvironment: _MinimalHostEnvironment(),
    transportFactory: (DeviceEndpoint endpoint) {
      final FakeTransport transport = FakeTransport(
        endpoint: endpoint,
        reachable: reachable,
        execHandler: execHandler,
      );
      transports.add(transport);
      return transport;
    },
    out: out,
    err: err,
  );

  void dispose() {
    temp.deleteSync(recursive: true);
  }
}

final class _MinimalHostEnvironment implements HostEnvironment {
  @override
  String? executablePath(String executable) => null;

  @override
  Future<CommandResult> run(
    List<String> command, {
    Duration timeout = const Duration(seconds: 30),
    Map<String, String> environment = const <String, String>{},
    String? workingDirectory,
  }) async {
    return const CommandResult(exitCode: 1);
  }

  @override
  bool fileExists(String path) => false;

  @override
  bool directoryExists(String path) => false;

  @override
  String readTextFile(String path) => '';

  @override
  String? environmentVariable(String name) => null;

  @override
  String get operatingSystem => 'macos';
}

void _writeLayout(
  String path, {
  required String appId,
  required PlutoBuildMode mode,
  PlutoTargetPlatform target = PlutoTargetPlatform.linuxArm64,
}) {
  final Directory assets = Directory('$path/bundle/flutter_assets')
    ..createSync(recursive: true);
  File('${assets.path}/AssetManifest.bin').writeAsBytesSync(<int>[1]);
  if (mode.isAot) {
    File('$path/bundle/lib/app.so')
      ..createSync(recursive: true)
      ..writeAsBytesSync(
        target == PlutoTargetPlatform.linuxArm
            ? releaseArmAotElf()
            : _aotElf(mode),
      );
  } else {
    File('${assets.path}/kernel_blob.bin').writeAsBytesSync(<int>[3]);
  }
  File('$path/manifest.json').writeAsStringSync(
    jsonEncode(<String, Object?>{
      'schema': 1,
      'id': appId,
      'icon': 'assets/pluto/icon.png',
      'runtime': mode.isAot
          ? <String, Object?>{
              'type': 'flutter-aot',
              'appElf': 'lib/app.so',
              'assets': 'flutter_assets',
            }
          : <String, Object?>{
              'type': 'flutter-kernel',
              'assets': 'flutter_assets',
            },
    }),
  );
  File('$path/assets/pluto/icon.png')
    ..createSync(recursive: true)
    ..writeAsBytesSync(<int>[4, 5]);
  BuildLayoutMetadata(
    buildMode: mode,
    engineFlavor: mode.engineFlavor,
    flutterVersion: '3.44.4',
    engineCommit: _engineHash,
    target: target.cliName,
  ).write(path);
}

List<int> _aotElf(PlutoBuildMode mode) =>
    mode == PlutoBuildMode.release ? releaseAotElf() : profileAotElf();

void _writeProvisionRuntime(
  String payload, {
  List<int> releaseBytes = const <int>[2],
  bool legacyRelease = false,
  bool includeDebug = false,
}) {
  for (final String script in <String>[
    'pluto-session.sh',
    'pluto-power-key-watch.sh',
    'pluto-boot-install.sh',
    'pluto-app-control.sh',
    'pluto-install-transaction.sh',
    'pluto-uninstall.sh',
  ]) {
    File('$payload/$script')
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
  }
  File('$payload/pluto-embedder').writeAsBytesSync(<int>[1]);
  File('$payload/bin/pluto-apploadctl')
    ..createSync(recursive: true)
    ..writeAsBytesSync(<int>[8]);
  final String releasePath = legacyRelease
      ? '$payload/libflutter_engine.so'
      : '$payload/engine/release/libflutter_engine.so';
  File(releasePath)
    ..createSync(recursive: true)
    ..writeAsBytesSync(releaseBytes);
  File('$payload/engine/profile/libflutter_engine.so')
    ..createSync(recursive: true)
    ..writeAsBytesSync(<int>[3]);
  if (includeDebug) {
    File('$payload/engine/debug/libflutter_engine.so')
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[4]);
  }
}

void _writeCooperativeProvisionRuntime(String payload) {
  File('$payload/bin/pluto-embedder')
    ..createSync(recursive: true)
    ..writeAsBytesSync(<int>[6]);
  File('$payload/bin/pluto-apploadctl').writeAsBytesSync(<int>[8]);
  final Uint8List codex = _testCodexBinary();
  File('$payload/bin/codex').writeAsBytesSync(codex);
  File('$payload/engine/release/libflutter_engine.so')
    ..createSync(recursive: true)
    ..writeAsBytesSync(<int>[6]);
  File('$payload/engine/release/icudtl.dat').writeAsBytesSync(<int>[7]);
  File('$payload/COOPERATIVE-PAYLOAD.json').writeAsStringSync(
    jsonEncode(<String, Object?>{
      'schema': 1,
      'target': 'linux-arm',
      'mode': 'release',
      'flutterVersion': '3.44.4',
      'engineCommit': _engineHash,
      'runtimeRoot': '/home/root/pluto',
      'codex': <String, Object?>{
        'version': _codexVersion,
        'sha256': sha256Bytes(codex),
        'path': '/home/root/pluto/bin/codex',
        'authentication': 'user-managed',
      },
    }),
  );
  _writeCooperativeIntegration('$payload/integration');
}

void _writeCooperativeIntegration(String root) {
  const Map<String, bool> files = <String, bool>{
    'xovi.so': false,
    'start': true,
    'stock': true,
    'debug': true,
    'rebuild_hashtable': true,
    'extensions.d/qt-resource-rebuilder.so': false,
    'services/xochitl.service/qt-resource-rebuilder.conf': false,
    'scripts/debug/qt-resource-rebuilder.sh': true,
    'bin/pluto-apploadctl': true,
    'exthome/appload/shims/qtfb-shim-32bit.so': false,
    'exthome/appload/shims/qtfb-shim.so': false,
  };
  final StringBuffer checksums = StringBuffer()
    ..writeln('schema=1')
    ..writeln('target=linux-arm')
    ..writeln('xovi=0.3.3')
    ..writeln('qrr=v19')
    ..writeln('apploadControlProtocol=1')
    ..writeln('hashtab=profile-matched')
    ..writeln('firmwareProfiles=3.27.3.0,3.28.0.162')
    ..writeln();
  var value = 10;
  for (final String relative in files.keys) {
    final List<int> bytes = <int>[value++];
    File('$root/xovi/$relative')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    checksums.writeln('${sha256Bytes(bytes)}  $relative');
  }
  for (final String firmware in <String>['3.27.3.0', '3.28.0.162']) {
    final String relative = 'profiles/$firmware/appload.so';
    final List<int> bytes = <int>[value++];
    File('$root/$relative')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    checksums.writeln('${sha256Bytes(bytes)}  $relative');
    final String hashtabRelative = 'profiles/$firmware/hashtab';
    final List<int> hashtabBytes = <int>[value++];
    File('$root/$hashtabRelative')
      ..createSync(recursive: true)
      ..writeAsBytesSync(hashtabBytes);
    checksums.writeln('${sha256Bytes(hashtabBytes)}  $hashtabRelative');
  }
  Link(
    '$root/xovi/services/xochitl.service/extensions.d',
  ).createSync('/home/root/xovi/extensions.d', recursive: true);
  Link(
    '$root/xovi/services/xochitl.service/exthome',
  ).createSync('/home/root/xovi/exthome', recursive: true);
  checksums
    ..writeln(
      'link services/xochitl.service/extensions.d '
      '/home/root/xovi/extensions.d',
    )
    ..writeln('link services/xochitl.service/exthome /home/root/xovi/exthome');
  File('$root/CHECKSUMS.txt').writeAsStringSync(checksums.toString());
}

void _writePinnedEngineArtifact({
  required String root,
  required String mode,
  required List<int> bytes,
}) {
  final Directory artifact = Directory(
    '$root/third_party/engine/$_engineHash/linux-arm64-$mode',
  )..createSync(recursive: true);
  File('${artifact.path}/libflutter_engine.so').writeAsBytesSync(bytes);
  File('${artifact.path}/CHECKSUMS.txt').writeAsStringSync('''
schema=1
flutter=3.44.4
engine=$_engineHash
target=linux-arm64
mode=$mode

${sha256Bytes(bytes)}  libflutter_engine.so
''');
}

void _writePinnedArmEngineArtifact({required String root}) {
  const List<int> engine = <int>[6];
  const List<int> icu = <int>[7];
  final Directory artifact = Directory(
    '$root/third_party/engine/$_engineHash/linux-arm-release',
  )..createSync(recursive: true);
  File('${artifact.path}/libflutter_engine.so').writeAsBytesSync(engine);
  File('${artifact.path}/icudtl.dat').writeAsBytesSync(icu);
  File('${artifact.path}/CHECKSUMS.txt').writeAsStringSync('''
schema=1
flutter=3.44.4
engine=$_engineHash
target=linux-arm
mode=release

${sha256Bytes(engine)}  libflutter_engine.so
${sha256Bytes(icu)}  icudtl.dat
''');
}

Future<File> _writePackageForMode(
  Directory temp, {
  required String appId,
  required PlutoBuildMode mode,
  PlutoTargetPlatform target = PlutoTargetPlatform.linuxArm64,
}) async {
  final Directory layout = Directory('${temp.path}/${mode.cliName}-install')
    ..createSync(recursive: true);
  _writeLayout(layout.path, appId: appId, mode: mode, target: target);
  final PlapPackage package =
      await const PlapPackageBuilder(compressor: NoopCompressor()).build(
        source: DirectoryPackageSource(layout.path),
        metadata: PackageMetadata(
          flutterVersion: '3.44.4',
          engineCommit: _engineHash,
          plutoVersion: '0.1.0',
          buildMode: mode.cliName,
          engineFlavor: mode.engineFlavor,
          target: target.cliName,
        ),
      );
  return File('${temp.path}/${mode.cliName}.plap')
    ..writeAsBytesSync(package.bytes);
}
