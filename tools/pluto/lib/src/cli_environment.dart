import 'dart:io';

import 'artifacts/engine_artifacts.dart';
import 'config/paths.dart';
import 'config/pins.dart';
import 'device/remarkable_discovery.dart';
import 'doctor/doctor.dart';
import 'process.dart';
import 'ssh/device_transport.dart';
import 'ssh/dropbear_transport.dart';

/// Runtime dependencies shared by CLI commands.
final class PlutoCliEnvironment {
  /// Creates an environment.
  const PlutoCliEnvironment({
    required this.paths,
    required this.hostEnvironment,
    required this.transportFactory,
    required this.out,
    required this.err,
  });

  /// Host paths.
  final PlutoPaths paths;

  /// Host process/filesystem access.
  final HostEnvironment hostEnvironment;

  /// Creates transports for device endpoints.
  final TransportFactory transportFactory;

  /// Standard output sink.
  final StringSink out;

  /// Standard error sink.
  final StringSink err;

  /// Creates the default environment.
  factory PlutoCliEnvironment.defaults() {
    final PlutoPaths paths = PlutoPaths.defaults();
    return PlutoCliEnvironment(
      paths: paths,
      hostEnvironment: const ProcessHostEnvironment(),
      transportFactory: (DeviceEndpoint endpoint) =>
          DropbearTransport(endpoint: endpoint),
      out: stdout,
      err: stderr,
    );
  }

  /// Pin repository.
  PinsRepository get pinsRepository => PinsRepository.fromPaths(paths);

  /// Engine artifact resolver.
  EngineArtifactResolver get artifactResolver =>
      EngineArtifactResolver(paths: paths);

  /// Device discovery service.
  RemarkableDeviceDiscovery get deviceDiscovery =>
      RemarkableDeviceDiscovery(transportFactory: transportFactory);

  /// Doctor service.
  DoctorService get doctorService => DoctorService(
    pinsRepository: pinsRepository,
    artifactResolver: artifactResolver,
    hostEnvironment: hostEnvironment,
    deviceDiscovery: deviceDiscovery,
  );
}
