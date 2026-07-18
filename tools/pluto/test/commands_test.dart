import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pluto_cli/pluto.dart';
import 'package:pluto_cli/src/build/plap_reader.dart';
import 'package:pluto_cli/src/commands/install_command.dart';
import 'package:test/test.dart';

import 'support/aot_fixture.dart';

const String _engineHash = 'a10d8ac38de835021c8d2f920dbf50a920ccc030';

Future<CommandResult> _moveExecHandler(String command) async {
  if (command == 'cat /sys/devices/soc0/machine') {
    return const CommandResult(exitCode: 0, stdout: 'imx93-chiappa');
  }
  if (command == 'uname -m') {
    return const CommandResult(exitCode: 0, stdout: 'aarch64');
  }
  if (command == 'uname -r') {
    return const CommandResult(
      exitCode: 0,
      stdout: '6.12.49+git-imx93-chiappa-gf4c2ab7040e8',
    );
  }
  if (command == 'cat /proc/device-tree/compatible') {
    return const CommandResult(exitCode: 0, stdout: 'fsl,imx93');
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
  return const CommandResult(exitCode: 0);
}

Future<CommandResult> _rm2ExecHandler(String command) async {
  if (command == 'cat /sys/devices/soc0/machine') {
    return const CommandResult(exitCode: 0, stdout: 'reMarkable 2.0');
  }
  if (command == 'uname -m') {
    return const CommandResult(exitCode: 0, stdout: 'armv7l');
  }
  if (command == 'uname -r') {
    return const CommandResult(exitCode: 0, stdout: '5.4.70-v1.6.3-rm11x');
  }
  if (command == 'cat /proc/device-tree/compatible') {
    return const CommandResult(exitCode: 0, stdout: 'fsl,imx7d-sdb');
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
      if (command == 'cat /sys/devices/soc0/machine' ||
          command == 'cat /proc/device-tree/compatible' ||
          command == 'uname -m' ||
          command == 'uname -r' ||
          command == 'cat /etc/version' ||
          command == 'cat /usr/share/remarkable/update.conf') {
        return _moveExecHandler(command);
      }
      return fallback(command);
    };

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
      expect(device['kernelRelease'], '5.4.70-v1.6.3-rm11x');
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
      contains('targets/linux-arm64/bundle/flutter_assets/kernel_blob.bin'),
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

  test('build package --published emits both exact release slices', () async {
    final _CommandHarness harness = _CommandHarness();
    addTearDown(harness.dispose);
    final Directory layouts = Directory('${harness.temp.path}/published')
      ..createSync();
    for (final PlutoTargetPlatform target in PlutoTargetPlatform.values) {
      _writeLayout(
        '${layouts.path}/${target.cliName}',
        appId: 'dev.example.published',
        mode: PlutoBuildMode.release,
        target: target,
      );
    }
    final String output = '${harness.temp.path}/out/published.plap';

    final int? exitCode =
        await buildCommandRunner(environment: harness.environment).run(<String>[
          'build',
          'package',
          '--published',
          '--no-live',
          '--from-layout',
          layouts.path,
          '--compression',
          'none',
          '-o',
          output,
        ]);

    expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
    final PlapArchive archive = await PlapArchive.read(output);
    expect(archive.appId, 'dev.example.published');
    expect(archive.slices.keys, <String>{'linux-arm', 'linux-arm64'});
  });

  test('published package rejects a missing target layout', () async {
    final _CommandHarness harness = _CommandHarness();
    addTearDown(harness.dispose);
    final Directory layouts = Directory('${harness.temp.path}/missing')
      ..createSync();
    _writeLayout(
      '${layouts.path}/linux-arm64',
      appId: 'dev.example.published',
      mode: PlutoBuildMode.release,
    );
    final String output = '${harness.temp.path}/out/missing.plap';

    final int? exitCode =
        await buildCommandRunner(environment: harness.environment).run(<String>[
          'build',
          'package',
          '--published',
          '--no-live',
          '--from-layout',
          layouts.path,
          '--compression',
          'none',
          '-o',
          output,
        ]);

    expect(exitCode, ExitCodes.usage);
    expect(harness.err.toString(), contains('missing the linux-arm layout'));
    expect(File(output).existsSync(), isFalse);
  });

  test('published package emits only the app-declared target slices', () async {
    final _CommandHarness harness = _CommandHarness();
    addTearDown(harness.dispose);
    final Directory layouts = Directory('${harness.temp.path}/arm64-only')
      ..createSync();
    _writeLayout(
      '${layouts.path}/linux-arm64',
      appId: 'dev.example.arm64_only',
      mode: PlutoBuildMode.release,
      targets: const <String>['linux-arm64'],
    );
    final String output = '${harness.temp.path}/out/arm64-only.plap';

    final int? exitCode =
        await buildCommandRunner(environment: harness.environment).run(<String>[
          'build',
          'package',
          '--published',
          '--no-live',
          '--from-layout',
          layouts.path,
          '--compression',
          'none',
          '-o',
          output,
        ]);

    expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
    final PlapArchive archive = await PlapArchive.read(output);
    expect(archive.appId, 'dev.example.arm64_only');
    expect(archive.slices.keys, <String>{'linux-arm64'});
  });

  test('published package rejects contradictory target slices', () async {
    final _CommandHarness harness = _CommandHarness();
    addTearDown(harness.dispose);
    final Directory layouts = Directory('${harness.temp.path}/contradictory')
      ..createSync();
    _writeLayout(
      '${layouts.path}/linux-arm64',
      appId: 'dev.example.published',
      mode: PlutoBuildMode.release,
    );
    _writeLayout(
      '${layouts.path}/linux-arm',
      appId: 'dev.example.published',
      mode: PlutoBuildMode.release,
      target: PlutoTargetPlatform.linuxArm64,
    );

    final int? exitCode =
        await buildCommandRunner(environment: harness.environment).run(<String>[
          'build',
          'package',
          '--published',
          '--no-live',
          '--from-layout',
          layouts.path,
          '--compression',
          'none',
          '-o',
          '${harness.temp.path}/out/contradictory.plap',
        ]);

    expect(exitCode, ExitCodes.failure);
    expect(harness.err.toString(), contains('not linux-arm'));
  });

  test('published package refuses device or target overrides', () async {
    final _CommandHarness harness = _CommandHarness();
    addTearDown(harness.dispose);

    final int? exitCode =
        await buildCommandRunner(environment: harness.environment).run(<String>[
          'build',
          'package',
          '--published',
          '--target-platform',
          'linux-arm',
          '--no-live',
        ]);

    expect(exitCode, ExitCodes.usage);
    expect(
      harness.err.toString(),
      contains('already builds every app-declared target'),
    );
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
              bytes: _manifestBytes(
                appId: 'dev.example.notes',
                mode: PlutoBuildMode.release,
              ),
            ),
            PackageEntry(path: 'bundle/lib/app.so', bytes: releaseAotElf()),
            PackageEntry(
              path: 'bundle/flutter_assets/AssetManifest.bin',
              bytes: Uint8List.fromList(<int>[2]),
            ),
            PackageEntry(
              path: 'assets/pluto/icon.png',
              bytes: Uint8List.fromList(<int>[3]),
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

  test('install routes a linux-arm package through the native flow', () async {
    final _CommandHarness harness = _CommandHarness(
      reachable: true,
      execHandler: _rm2ExecHandler,
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
              '/home/root/pluto/staging/dev.example.arm.',
            ) &&
            upload.remotePath.endsWith('/install.json.pending'),
      ),
      isTrue,
      reason: 'all targets use the canonical native app transaction',
    );
    expect(
      transport.commands.any(
        (String command) =>
            command.contains('pluto-install-transaction.sh') &&
            command.contains("commit 'dev.example.arm'"),
      ),
      isTrue,
    );
  });

  test('install rejects a package missing the probed target slice', () async {
    final _CommandHarness harness = _CommandHarness(
      reachable: true,
      execHandler: _rm2ExecHandler,
    );
    addTearDown(harness.dispose);
    final File package = await _writePackageForMode(
      harness.temp,
      appId: 'dev.example.arm64_only',
      mode: PlutoBuildMode.release,
    );

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['install', '-d', '10.11.99.1', package.path]);

    expect(exitCode, ExitCodes.failure);
    expect(harness.err.toString(), contains('no linux-arm slice'));
    expect(harness.transports.single.uploads, isEmpty);
    expect(harness.transports.single.directoryUploads, isEmpty);
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
    'provision stages the canonical layout and enforces Move boot policy',
    () async {
      final _CommandHarness harness = _CommandHarness(
        reachable: true,
        execHandler: _moveExecHandler,
      );
      addTearDown(harness.dispose);
      final String payload = '${harness.temp.path}/payload';
      final String slice = _writeProvisionRuntime(payload);
      _writeLayout(
        '$slice/apps/dev.pluto.launcher',
        appId: 'dev.pluto.launcher',
        mode: PlutoBuildMode.release,
      );
      _writeLayout(
        '$slice/apps/dev.example.counter',
        appId: 'dev.example.counter',
        mode: PlutoBuildMode.profile,
      );
      _sealReleaseSet(harness, payload);

      final int? exitCode =
          await buildCommandRunner(environment: harness.environment).run(
            <String>['provision', '--payload-dir', payload, '-d', '10.11.99.1'],
          );

      expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
      expect(harness.out.toString(), contains('boot-default recovery gate'));
      final FakeTransport transport = harness.transports.single;
      final Set<String> candidateRoots = transport.uploads
          .map(
            (FakeUpload upload) => RegExp(
              r'^(/home/root/pluto\.releases/\.candidate-[^/]+)/',
            ).firstMatch(upload.remotePath)?.group(1),
          )
          .whereType<String>()
          .toSet();
      expect(candidateRoots, hasLength(1));
      final String stage = candidateRoots.single;
      final String nonce = stage.split('.candidate-').last;
      final String candidate = '/home/root/pluto.releases/$nonce';
      expect(
        transport.uploads.any(
          (FakeUpload u) =>
              u.remotePath == '$stage/bin/pluto-session.sh' && u.executable,
        ),
        isTrue,
        reason: 'the supervisor belongs to the isolated complete release',
      );
      expect(
        transport.uploads.any(
          (FakeUpload u) =>
              u.remotePath == '$stage/bin/pluto-rm2-cpufreq-restore.sh' &&
              u.executable,
        ),
        isFalse,
        reason: 'the Move release must not carry an RM2-only helper',
      );
      expect(
        transport.uploads.any(
          (FakeUpload u) =>
              u.remotePath == '$stage/bin/pluto-power-key-watch.sh' &&
              u.executable,
        ),
        isTrue,
        reason: 'the watcher is staged without touching the active release',
      );
      expect(
        transport.uploads.any(
          (FakeUpload u) =>
              u.remotePath == '$stage/bin/pluto-embedder' && u.executable,
        ),
        isTrue,
      );
      expect(
        transport.uploads.any(
          (FakeUpload u) =>
              u.remotePath == '$stage/engine/profile/libflutter_engine.so',
        ),
        isTrue,
      );
      expect(
        transport.uploads.any(
          (FakeUpload u) =>
              u.remotePath == '$stage/engine/release/libflutter_engine.so',
        ),
        isTrue,
      );
      expect(
        transport.directoryUploads.any(
          ((String, String) r) => r.$2 == '$stage/launcher/bundle',
        ),
        isTrue,
        reason: 'launcher is complete before the whole release is activated',
      );
      expect(
        transport.uploads.any(
          (FakeUpload upload) =>
              upload.remotePath == '$stage/launcher/assets/pluto/icon.png',
        ),
        isTrue,
        reason: 'manifest-declared root assets are staged with the launcher',
      );
      final FakeUpload counterInstall = transport.uploads.singleWhere(
        (FakeUpload upload) =>
            upload.remotePath == '$stage/apps/dev.example.counter/install.json',
      );
      final String installJson = utf8.decode(counterInstall.bytes);
      expect(installJson, contains('"buildMode": "profile"'));
      expect(installJson, contains('"engineFlavor": "profile"'));
      expect(
        transport.commands.where(
          (String command) =>
              command.contains('$candidate/bin/pluto-release-activate.sh') &&
              command.contains("activate '$candidate' 'transient'"),
        ),
        hasLength(1),
        reason:
            'one transaction preserves stock boot and starts the new release',
      );
      expect(
        transport.uploads.any(
          (FakeUpload upload) =>
              upload.remotePath.startsWith('/home/root/pluto/'),
        ),
        isFalse,
        reason: 'provisioning never mutates the active release in place',
      );
      expect(harness.out.toString(), contains('active for this boot'));
    },
  );

  test(
    'provision never fills a release slice from checkout build output',
    () async {
      final _CommandHarness harness = _CommandHarness(
        reachable: true,
        execHandler: _moveExecHandler,
      );
      addTearDown(harness.dispose);
      final String payload = '${harness.temp.path}/payload';
      final String slice = _writeProvisionRuntime(payload);
      File('$slice/bin/pluto-controlctl').deleteSync();
      File('${harness.temp.path}/embedder/build/device-arm64/pluto-controlctl')
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[99]);
      _writeLayout(
        '$slice/apps/dev.pluto.launcher',
        appId: 'dev.pluto.launcher',
        mode: PlutoBuildMode.release,
      );
      _sealReleaseSet(harness, payload);

      final int? exitCode =
          await buildCommandRunner(environment: harness.environment).run(
            <String>['provision', '--payload-dir', payload, '-d', '10.11.99.1'],
          );

      expect(exitCode, ExitCodes.usage);
      expect(harness.err.toString(), contains('$slice/bin/pluto-controlctl'));
      expect(
        RegExp(
          RegExp.escape('$slice/bin/pluto-controlctl'),
        ).allMatches(harness.err.toString()),
        hasLength(1),
        reason: 'one missing integrity-checked file has one actionable error',
      );
      expect(harness.transports.single.uploads, isEmpty);
      expect(harness.transports.single.directoryUploads, isEmpty);
    },
  );

  test('provision refuses a release missing the probed target slice', () async {
    final _CommandHarness harness = _CommandHarness(
      reachable: true,
      execHandler: _rm2ExecHandler,
    );
    addTearDown(harness.dispose);
    final String payload = '${harness.temp.path}/payload';
    final String slice = _writeProvisionRuntime(payload);
    _writeLayout(
      '$slice/apps/dev.pluto.launcher',
      appId: 'dev.pluto.launcher',
      mode: PlutoBuildMode.release,
    );
    _sealReleaseSet(harness, payload);
    Directory('$payload/targets/linux-arm').deleteSync(recursive: true);

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['provision', '--payload-dir', payload, '-d', '10.11.99.1']);

    expect(exitCode, ExitCodes.failure);
    expect(
      harness.err.toString(),
      contains('missing or not a regular directory'),
    );
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

  test(
    'provision routes a linux-arm supported-app layout through the native flow',
    () async {
      final _CommandHarness harness = _CommandHarness(
        reachable: true,
        execHandler: _rm2ExecHandler,
      );
      addTearDown(harness.dispose);
      final String payload = '${harness.temp.path}/payload';
      final String slice = _writeArmProvisionRuntime(payload);
      _writeLayout(
        '$slice/launcher',
        appId: 'dev.pluto.launcher',
        mode: PlutoBuildMode.release,
        target: PlutoTargetPlatform.linuxArm,
      );
      _writeLayout(
        '$slice/apps/dev.pluto.validation_lab',
        appId: 'dev.pluto.validation_lab',
        mode: PlutoBuildMode.release,
        target: PlutoTargetPlatform.linuxArm,
      );
      _sealReleaseSet(harness, payload);

      final int? exitCode =
          await buildCommandRunner(environment: harness.environment).run(
            <String>['provision', '--payload-dir', payload, '-d', '10.11.99.1'],
          );

      expect(exitCode, ExitCodes.ok, reason: harness.err.toString());
      expect(harness.out.toString(), contains('Pluto provisioned'));
      final FakeTransport transport = harness.transports.single;
      final Set<String> candidateRoots = transport.uploads
          .map(
            (FakeUpload upload) => RegExp(
              r'^(/home/root/pluto\.releases/\.candidate-[^/]+)/',
            ).firstMatch(upload.remotePath)?.group(1),
          )
          .whereType<String>()
          .toSet();
      expect(candidateRoots, hasLength(1));
      final String stage = candidateRoots.single;
      final String nonce = stage.split('.candidate-').last;
      final String candidate = '/home/root/pluto.releases/$nonce';
      expect(
        transport.uploads.any(
          (FakeUpload upload) =>
              upload.remotePath == '$stage/launcher/install.json',
        ),
        isTrue,
        reason: 'the launcher is part of the same complete release candidate',
      );
      expect(
        transport.uploads.any(
          (FakeUpload upload) =>
              upload.remotePath == '$stage/bin/pluto-controlctl',
        ),
        isTrue,
        reason: 'the matching control client is part of the target runtime',
      );
      expect(
        transport.uploads.any(
          (FakeUpload upload) =>
              upload.remotePath == '$stage/bin/pluto-rm2-cpufreq-restore.sh' &&
              upload.executable,
        ),
        isTrue,
        reason: 'the shared ARM slice carries the RM2 crash restorer',
      );
      expect(
        transport.uploads.any(
          (FakeUpload upload) =>
              upload.remotePath ==
              '$stage/apps/dev.pluto.validation_lab/'
                  'install.json',
        ),
        isTrue,
        reason: 'the supported validation app is promoted with the ARM runtime',
      );
      expect(
        transport.uploads.any(
          (FakeUpload upload) =>
              upload.remotePath == '$stage/bin/codex' ||
              upload.remotePath.contains('/apps/dev.pluto.codex/'),
        ),
        isFalse,
        reason:
            'linux-arm must not carry a custom Codex binary or Paper Codex app',
      );
      expect(
        transport.commands.any(
          (String command) => command.contains('$stage/engine/profile'),
        ),
        isFalse,
        reason:
            'the release-only ARM slice must not leave an empty profile engine '
            'directory',
      );
      expect(
        transport.commands.any(
          (String command) => command.contains('$stage/engine/release'),
        ),
        isTrue,
        reason: 'runtime uploads create only the engine modes in the slice',
      );
      expect(
        transport.commands.any(
          (String command) =>
              command.contains('$candidate/bin/pluto-release-activate.sh') &&
              command.contains("activate '$candidate' 'transient'"),
        ),
        isTrue,
        reason:
            'the complete ARM release is activated for the current boot through '
            'one commit while the profile recovery gate is closed',
      );
    },
  );

  test('provision without a launcher payload fails host-side', () async {
    final _CommandHarness harness = _CommandHarness(
      reachable: true,
      execHandler: _moveExecHandler,
    );
    addTearDown(harness.dispose);
    final String payload = '${harness.temp.path}/payload';
    _writeProvisionRuntime(payload);
    _sealReleaseSet(harness, payload);

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['provision', '--payload-dir', payload, '-d', '10.11.99.1']);

    expect(exitCode, ExitCodes.usage);
    expect(harness.err.toString(), contains('launcher'));
    for (final FakeTransport transport in harness.transports) {
      expect(transport.uploads, isEmpty);
    }
  });

  test(
    'provision rejects a mismatched release engine before device writes',
    () async {
      final _CommandHarness harness = _CommandHarness(
        reachable: true,
        execHandler: _moveExecHandler,
      );
      addTearDown(harness.dispose);
      final String payload = '${harness.temp.path}/payload';
      final String slice = _writeProvisionRuntime(
        payload,
        releaseBytes: <int>[9],
      );
      _writeLayout(
        '$slice/apps/dev.pluto.launcher',
        appId: 'dev.pluto.launcher',
        mode: PlutoBuildMode.release,
      );
      _sealReleaseSet(harness, payload);

      final int? exitCode =
          await buildCommandRunner(environment: harness.environment).run(
            <String>['provision', '--payload-dir', payload, '-d', '10.11.99.1'],
          );

      expect(exitCode, ExitCodes.usage);
      expect(harness.err.toString(), contains('engine checksum mismatch'));
      expect(harness.transports.single.uploads, isEmpty);
    },
  );

  test('provision requires explicit --debug for a JIT engine', () async {
    final _CommandHarness harness = _CommandHarness(
      reachable: true,
      execHandler: _moveExecHandler,
    );
    addTearDown(harness.dispose);
    final String payload = '${harness.temp.path}/payload';
    final String slice = _writeProvisionRuntime(payload, includeDebug: true);
    _writeLayout(
      '$slice/apps/dev.pluto.launcher',
      appId: 'dev.pluto.launcher',
      mode: PlutoBuildMode.release,
    );
    _sealReleaseSet(harness, payload);

    final int? exitCode = await buildCommandRunner(
      environment: harness.environment,
    ).run(<String>['provision', '--payload-dir', payload, '-d', '10.11.99.1']);

    expect(exitCode, ExitCodes.usage);
    expect(harness.err.toString(), contains('requires explicit'));
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
            c.contains('pluto-boot-install.sh') && c.contains(' restore'),
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
    File('${pins.path}/arm-sdk.pin').writeAsStringSync('''
schema=1
name=test-arm-sdk
sha256=${'b' * 64}
gcc_version=11.5.0
gcc_machine=arm-remarkable-linux-gnueabi
regular_files=1
''');
    File(
      '${pins.path}/supported_os.json',
    ).writeAsStringSync('{"supportedOsBuilds":["20260629074044"]}');
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
  List<String> targets = const <String>['linux-arm', 'linux-arm64'],
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
    utf8.decode(_manifestBytes(appId: appId, mode: mode, targets: targets)),
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

Uint8List _manifestBytes({
  required String appId,
  required PlutoBuildMode mode,
  List<String> targets = const <String>['linux-arm', 'linux-arm64'],
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'id': appId,
      'name': 'Test app',
      'version': '1.0.0',
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
      'engine': <String, Object?>{
        'flutterVersion': '3.44.4',
        'engineCommit': _engineHash,
      },
      'targets': <Object?>[...targets],
      'permissions': <Object?>[],
      'display': <String, Object?>{
        'orientations': <Object?>['portrait'],
        'defaultOrientation': 'portrait',
        'scale': 'auto',
        'color': 'auto',
        'refreshProfile': 'ui',
      },
      'launch': <String, Object?>{'singleInstance': true, 'args': <Object?>[]},
    }),
  ),
);

List<int> _aotElf(PlutoBuildMode mode) =>
    mode == PlutoBuildMode.release ? releaseAotElf() : profileAotElf();

String _writeProvisionRuntime(
  String releaseRoot, {
  List<int> releaseBytes = const <int>[2],
  bool includeDebug = false,
  PlutoTargetPlatform target = PlutoTargetPlatform.linuxArm64,
}) {
  final String payload = '$releaseRoot/targets/${target.cliName}';
  for (final String script in <String>[
    'pluto-session.sh',
    'pluto-session-once.sh',
    'pluto-rm2-cpufreq-restore.sh',
    'pluto-boot-confirm.sh',
    'pluto-power-key-watch.sh',
    'pluto-boot-install.sh',
    'pluto-app-control.sh',
    'pluto-install-transaction.sh',
    'pluto-release-activate.sh',
    'pluto-uninstall.sh',
  ]) {
    File('$payload/$script')
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
  }
  File('$payload/pluto-embedder').writeAsBytesSync(<int>[1]);
  File('$payload/bin/pluto-controlctl')
    ..createSync(recursive: true)
    ..writeAsBytesSync(<int>[8]);
  File('$payload/share/device-profiles.sh')
    ..createSync(recursive: true)
    ..writeAsStringSync('# generated device profiles\n');
  File(
    '$payload/share/release-revision',
  ).writeAsStringSync('0123456789abcdef0123456789abcdef01234567\n');
  File('$payload/engine/release/libflutter_engine.so')
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
  return payload;
}

String _writeArmProvisionRuntime(String releaseRoot) {
  return _writeProvisionRuntime(
    releaseRoot,
    releaseBytes: const <int>[6],
    target: PlutoTargetPlatform.linuxArm,
  );
}

void _sealReleaseSet(_CommandHarness harness, String releaseRoot) {
  final ReleaseSetPins pins = ReleaseSetPins.read(harness.pins.path);
  final Directory targets = Directory('$releaseRoot/targets');
  for (final String target in ReleaseSetManifest.requiredTargets) {
    final File receipt = File('${targets.path}/$target/share/release-revision');
    if (!receipt.existsSync()) {
      receipt
        ..createSync(recursive: true)
        ..writeAsStringSync('0123456789abcdef0123456789abcdef01234567\n');
    }
  }
  final Map<String, Object?> targetRecords = <String, Object?>{};
  for (final FileSystemEntity entity in targets.listSync()) {
    if (entity is! Directory) {
      continue;
    }
    final String target = entity.uri.pathSegments
        .where((String segment) => segment.isNotEmpty)
        .last;
    final Map<String, String> files = <String, String>{};
    for (final FileSystemEntity file in entity.listSync(recursive: true)) {
      if (file is! File) {
        continue;
      }
      final String prefix = '${entity.path}${Platform.pathSeparator}';
      final String relative = file.path
          .substring(prefix.length)
          .replaceAll(Platform.pathSeparator, '/');
      files[relative] = sha256Bytes(file.readAsBytesSync());
    }
    targetRecords[target] = <String, Object?>{
      'files': <String, String>{
        for (final String path in files.keys.toList()..sort())
          path: files[path]!,
      },
      'treeSha256': sha256Tree(files),
    };
  }
  File('$releaseRoot/${ReleaseSetManifest.fileName}').writeAsStringSync(
    jsonEncode(<String, Object?>{
      'gitRevision': '0123456789abcdef0123456789abcdef01234567',
      'pins': pins.toJson(),
      'targets': targetRecords,
    }),
  );
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
