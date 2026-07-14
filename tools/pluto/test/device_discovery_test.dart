import 'package:pluto_cli/pluto.dart';
import 'package:test/test.dart';

void main() {
  test('discovery returns empty when transport cannot connect', () async {
    final RemarkableDeviceDiscovery discovery = RemarkableDeviceDiscovery(
      transportFactory: (DeviceEndpoint endpoint) =>
          FakeTransport(endpoint: endpoint, reachable: false),
    );

    expect(await discovery.discover(), isEmpty);
  });

  test(
    'discovery probes model, firmware, runtime, xovi, and AppLoad',
    () async {
      late FakeTransport fake;
      final RemarkableDeviceDiscovery discovery = RemarkableDeviceDiscovery(
        transportFactory: (DeviceEndpoint endpoint) {
          fake = FakeTransport(
            endpoint: endpoint,
            execHandler: (String command) async {
              if (command == 'cat /sys/devices/soc0/machine') {
                return const CommandResult(
                  exitCode: 0,
                  stdout: 'imx93-chiappa',
                );
              }
              if (command == 'cat /proc/device-tree/compatible') {
                return const CommandResult(
                  exitCode: 0,
                  stdout: 'fsl,imx93\u0000',
                );
              }
              if (command == 'cat /etc/version') {
                return const CommandResult(
                  exitCode: 0,
                  stdout: '20260629074044',
                );
              }
              if (command == 'cat /usr/share/remarkable/update.conf') {
                return const CommandResult(
                  exitCode: 0,
                  stdout: 'REMARKABLE_RELEASE_VERSION=3.28.0.162\n',
                );
              }
              if (command == 'uname -m') {
                return const CommandResult(exitCode: 0, stdout: 'AARCH64\n');
              }
              if (command.startsWith('test -e')) {
                return const CommandResult(exitCode: 0);
              }
              return const CommandResult(exitCode: 1);
            },
          );
          return fake;
        },
      );

      final List<RemarkableDevice> devices = await discovery.discover(
        probeDetails: true,
      );

      expect(devices, hasLength(1));
      expect(devices.single.model, 'chiappa');
      expect(devices.single.runtimeBackend, PlutoRuntimeBackend.direct);
      expect(devices.single.buildTarget, 'linux-arm64');
      expect(devices.single.buildModes, <String>[
        'release',
        'profile',
        'debug',
      ]);
      expect(devices.single.capabilities, contains('screenshot'));
      expect(devices.single.capabilities, contains('hot-reload'));
      expect(devices.single.architecture, 'aarch64');
      expect(devices.single.firmwareBuild, '20260629074044');
      expect(devices.single.firmwareVersion, '3.28.0.162');
      expect(devices.single.provisioned, isTrue);
      expect(devices.single.xoviAvailable, isTrue);
      expect(devices.single.appLoadAvailable, isTrue);
      expect(fake.commands, contains('cat /etc/version'));
      expect(fake.commands, contains('cat /usr/share/remarkable/update.conf'));
      expect(devices.single.formatSummary(), contains('linux-arm64'));
    },
  );

  test('probe falls back to IMG_VERSION for semantic firmware', () async {
    final FakeTransport transport = FakeTransport(
      endpoint: const DeviceEndpoint(host: 'device'),
      execHandler: (String command) async {
        if (command == 'cat /sys/devices/soc0/machine') {
          return const CommandResult(exitCode: 0, stdout: 'reMarkable 1.0');
        }
        if (command == 'cat /proc/device-tree/compatible') {
          return const CommandResult(
            exitCode: 0,
            stdout: 'remarkable,zero-gravitas\u0000fsl,imx6sl',
          );
        }
        if (command == 'cat /etc/version') {
          return const CommandResult(exitCode: 0, stdout: '20260612085811');
        }
        if (command == 'cat /usr/share/remarkable/update.conf') {
          return const CommandResult(exitCode: 1);
        }
        if (command == 'cat /etc/os-release') {
          return const CommandResult(
            exitCode: 0,
            stdout: 'IMG_VERSION="3.27.3.0"\n',
          );
        }
        if (command == 'uname -m') {
          return const CommandResult(exitCode: 0, stdout: 'armv7l');
        }
        return const CommandResult(exitCode: 1);
      },
    );

    final RemarkableDevice device = await DeviceProbe(
      transport: transport,
    ).probe(id: 'usb', name: 'USB');

    expect(device.firmwareBuild, '20260612085811');
    expect(device.firmwareVersion, '3.27.3.0');
  });

  test('probe normalizes live reMarkable 1 and 2 machine identities', () async {
    for (final ({String machine, String compatible, String model}) fixture
        in <({String machine, String compatible, String model})>[
          (
            machine: 'reMarkable 1.0',
            compatible: 'remarkable,zero-gravitas\u0000fsl,imx6sl',
            model: 'zero-gravitas',
          ),
          (
            machine: 'reMarkable 2.0',
            compatible: 'fsl,imx7d-sdb\u0000fsl,imx7d',
            model: 'zero-sugar',
          ),
        ]) {
      final FakeTransport transport = FakeTransport(
        endpoint: const DeviceEndpoint(host: 'device'),
        execHandler: (String command) async {
          if (command == 'cat /sys/devices/soc0/machine') {
            return CommandResult(exitCode: 0, stdout: fixture.machine);
          }
          if (command == 'uname -m') {
            return const CommandResult(exitCode: 0, stdout: 'armv7l');
          }
          if (command == 'cat /proc/device-tree/compatible') {
            return CommandResult(exitCode: 0, stdout: fixture.compatible);
          }
          return const CommandResult(exitCode: 1);
        },
      );

      final RemarkableDevice device = await DeviceProbe(
        transport: transport,
      ).probe(id: 'usb', name: 'USB');

      expect(device.model, fixture.model, reason: fixture.machine);
      expect(
        device.runtimeBackend,
        PlutoRuntimeBackend.cooperative,
        reason: fixture.machine,
      );
      expect(device.buildTarget, 'linux-arm', reason: fixture.machine);
      expect(device.buildModes, <String>['release'], reason: fixture.machine);
      expect(device.capabilities, isNot(contains('hot-reload')));
      expect(device.architecture, 'armv7l', reason: fixture.machine);
    }
  });

  test(
    'probe accepts device-tree model plus compatible conjunctively',
    () async {
      for (final ({String compatible, String treeModel, String model}) fixture
          in <({String compatible, String treeModel, String model})>[
            (
              compatible: 'remarkable,zero-gravitas\u0000fsl,imx7d',
              treeModel: 'reMarkable 1.n',
              model: 'zero-gravitas',
            ),
            (
              compatible: 'fsl,imx7d-sdb\u0000fsl,imx7d',
              treeModel: 'reMarkable 2.n',
              model: 'zero-sugar',
            ),
          ]) {
        final FakeTransport transport = FakeTransport(
          endpoint: const DeviceEndpoint(host: 'device'),
          execHandler: (String command) async {
            if (command == 'cat /proc/device-tree/compatible') {
              return CommandResult(exitCode: 0, stdout: fixture.compatible);
            }
            if (command == 'cat /proc/device-tree/model') {
              return CommandResult(exitCode: 0, stdout: fixture.treeModel);
            }
            if (command == 'uname -m') {
              return const CommandResult(exitCode: 0, stdout: 'armv7l');
            }
            return const CommandResult(exitCode: 1);
          },
        );

        final RemarkableDevice device = await DeviceProbe(
          transport: transport,
        ).probe(id: 'usb', name: 'USB');

        expect(device.model, fixture.model, reason: fixture.compatible);
      }
    },
  );

  test('write-authorizing probe does not trust hostname identity', () async {
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

    final RemarkableDevice device = await DeviceProbe(
      transport: transport,
    ).probe(id: 'usb', name: 'USB');

    expect(device.model, isNull);
    expect(transport.commands, isNot(contains('hostname')));
  });

  test(
    'probe fails closed when immutable hardware identities conflict',
    () async {
      final FakeTransport transport = FakeTransport(
        endpoint: const DeviceEndpoint(host: 'device'),
        execHandler: (String command) async {
          if (command == 'cat /sys/devices/soc0/machine') {
            return const CommandResult(exitCode: 0, stdout: 'reMarkable 2.0');
          }
          if (command == 'cat /proc/device-tree/model') {
            return const CommandResult(exitCode: 0, stdout: 'reMarkable 1.0');
          }
          if (command == 'cat /proc/device-tree/compatible') {
            return const CommandResult(
              exitCode: 0,
              stdout:
                  'remarkable,zero-gravitas\u0000fsl,imx6sl\u0000'
                  'fsl,imx7d-sdb',
            );
          }
          if (command == 'hostname') {
            return const CommandResult(exitCode: 0, stdout: 'chiappa');
          }
          if (command == 'uname -m') {
            return const CommandResult(exitCode: 0, stdout: 'armv7l');
          }
          return const CommandResult(exitCode: 1);
        },
      );

      final RemarkableDevice device = await DeviceProbe(
        transport: transport,
      ).probe(id: 'usb', name: 'USB');

      expect(device.model, isNull);
      expect(device.runtimeBackend, isNull);
      expect(
        transport.commands,
        containsAll(<String>[
          'cat /sys/devices/soc0/machine',
          'cat /proc/device-tree/model',
          'cat /proc/device-tree/compatible',
        ]),
      );
      expect(transport.commands, isNot(contains('hostname')));
    },
  );

  test('Dart matcher accepts and rejects every generated fixture', () {
    for (final DeviceIdentityFixture fixture
        in generatedAcceptedIdentityFixtures) {
      expect(
        matchDeviceProfile(fixture.evidence)?.id,
        fixture.profileId,
        reason: fixture.machine + fixture.deviceTreeModel,
      );
    }
    for (final DeviceIdentityFixture fixture
        in generatedRejectedIdentityFixtures) {
      expect(
        matchDeviceProfile(fixture.evidence),
        isNull,
        reason: fixture.machine + fixture.deviceTreeModel,
      );
    }
  });
}
