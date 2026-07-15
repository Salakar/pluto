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
}
