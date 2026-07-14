import '../ssh/device_transport.dart';
import 'device_probe.dart';
import 'remarkable_device.dart';

/// Discovers reMarkable devices using the configured transport.
final class RemarkableDeviceDiscovery {
  /// Creates a discovery service.
  const RemarkableDeviceDiscovery({
    required this.transportFactory,
    this.defaultEndpoint = const DeviceEndpoint(host: '10.11.99.1'),
  });

  /// Creates device transports.
  final TransportFactory transportFactory;

  /// Ephemeral USB endpoint.
  final DeviceEndpoint defaultEndpoint;

  /// Returns reachable devices.
  Future<List<RemarkableDevice>> discover({
    bool probeDetails = false,
    DeviceEndpoint? endpoint,
  }) async {
    final DeviceEndpoint target = endpoint ?? defaultEndpoint;
    final DeviceTransport transport = transportFactory(target);
    final bool reachable = await transport.canConnect();
    if (!reachable) {
      return <RemarkableDevice>[];
    }
    if (!probeDetails) {
      return <RemarkableDevice>[
        RemarkableDevice(
          id: target.id,
          name: target.id == 'usb' ? 'reMarkable USB' : target.id,
          endpoint: target,
        ),
      ];
    }
    final DeviceProbe probe = DeviceProbe(transport: transport);
    return <RemarkableDevice>[
      await probe.probe(
        id: target.id,
        name: target.id == 'usb' ? 'reMarkable USB' : target.id,
      ),
    ];
  }
}
