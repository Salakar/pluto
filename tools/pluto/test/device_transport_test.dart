import 'dart:io';

import 'package:pluto_cli/src/cli_environment.dart';
import 'package:pluto_cli/src/errors.dart';
import 'package:pluto_cli/src/ssh/device_transport.dart';
import 'package:pluto_cli/src/ssh/dropbear_transport.dart';
import 'package:test/test.dart';

void main() {
  group('DeviceEndpoint.parse', () {
    test('uses the default root user and SSH port', () {
      final DeviceEndpoint endpoint = DeviceEndpoint.parse('10.11.99.1');

      expect(endpoint.user, 'root');
      expect(endpoint.host, '10.11.99.1');
      expect(endpoint.port, 22);
    });

    test('parses an explicit user and port', () {
      final DeviceEndpoint endpoint = DeviceEndpoint.parse(
        'root@127.0.0.1:22201',
      );

      expect(endpoint.user, 'root');
      expect(endpoint.host, '127.0.0.1');
      expect(endpoint.port, 22201);
    });

    test('parses bracketed IPv6 with a scope and port', () {
      final DeviceEndpoint endpoint = DeviceEndpoint.parse(
        'root@[fe80::1%en18]:22201',
      );

      expect(endpoint.host, 'fe80::1%en18');
      expect(endpoint.port, 22201);
    });

    test('keeps an unbracketed IPv6 address on the default port', () {
      final DeviceEndpoint endpoint = DeviceEndpoint.parse('root@fe80::1%en18');

      expect(endpoint.host, 'fe80::1%en18');
      expect(endpoint.port, 22);
    });

    test('rejects malformed or out-of-range ports', () {
      expect(
        () => DeviceEndpoint.parse('root@localhost:not-a-port'),
        throwsFormatException,
      );
      expect(
        () => DeviceEndpoint.parse('root@localhost:65536'),
        throwsFormatException,
      );
    });
  });

  test('directory uploads disable macOS AppleDouble synthesis', () {
    final Map<String, String> environment = directoryUploadTarEnvironment(
      const <String, String>{'PATH': '/usr/bin:/bin', 'COPYFILE_DISABLE': '0'},
    );

    expect(environment['PATH'], '/usr/bin:/bin');
    expect(environment['COPYFILE_DISABLE'], '1');
  });

  group('acceptance-strict SSH', () {
    test('rejects PATH lookup in the strict transport itself', () {
      expect(
        () => DropbearTransport(
          endpoint: DeviceEndpoint.parse('root@10.11.99.1'),
          acceptanceStrict: true,
        ),
        throwsArgumentError,
      );
    });

    test('CLI environment pins /usr/bin/ssh instead of PATH lookup', () {
      final PlutoCliEnvironment environment = PlutoCliEnvironment.defaults(
        processEnvironment: const <String, String>{
          'PLUTO_ACCEPTANCE_STRICT_SSH': '1',
        },
      );
      final DropbearTransport transport =
          environment.transportFactory(DeviceEndpoint.parse('root@10.11.99.1'))
              as DropbearTransport;

      expect(transport.acceptanceStrict, isTrue);
      expect(transport.sshExecutable, '/usr/bin/ssh');
    });

    test('CLI SSH override requires an explicit test seam', () {
      expect(
        () => PlutoCliEnvironment.defaults(
          processEnvironment: const <String, String>{
            'PLUTO_ACCEPTANCE_STRICT_SSH': '1',
            'PLUTO_ACCEPTANCE_SSH_BIN': '/tmp/path-ssh-shim',
          },
        ),
        throwsA(isA<CliConfigurationException>()),
      );
    });

    test('strict transport passes isolated OpenSSH options', () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'pluto-strict-ssh-',
      );
      final File ssh = File('${temp.path}/ssh-fixture');
      final File arguments = File('${ssh.path}.args');
      try {
        await ssh.writeAsString('''#!/bin/sh
printf '%s\\n' "\$@" > "\$0.args"
''');
        final ProcessResult chmod = await Process.run('/bin/chmod', <String>[
          '0755',
          ssh.path,
        ]);
        expect(chmod.exitCode, 0);

        final PlutoCliEnvironment environment = PlutoCliEnvironment.defaults(
          processEnvironment: <String, String>{
            'PLUTO_ACCEPTANCE_STRICT_SSH': '1',
            'PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS': '1',
            'PLUTO_ACCEPTANCE_SSH_BIN': ssh.path,
          },
        );
        final DropbearTransport transport =
            environment.transportFactory(
                  DeviceEndpoint.parse('root@127.0.0.1:2222'),
                )
                as DropbearTransport;

        expect((await transport.exec('true')).isSuccess, isTrue);
        expect(await arguments.readAsLines(), <String>[
          '-F',
          '/dev/null',
          '-p',
          '2222',
          '-o',
          'BatchMode=yes',
          '-o',
          'ConnectTimeout=30',
          '-o',
          'StrictHostKeyChecking=yes',
          '-o',
          'ProxyCommand=none',
          '-o',
          'CanonicalizeHostname=no',
          '-o',
          'ControlMaster=no',
          '-o',
          'ControlPath=none',
          '-o',
          'ControlPersist=no',
          'root@127.0.0.1',
          'true',
        ]);
      } finally {
        await temp.delete(recursive: true);
      }
    });
  });
}
