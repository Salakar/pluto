import 'dart:io';

import 'artifacts/engine_artifacts.dart';
import 'config/paths.dart';
import 'config/pins.dart';
import 'device/remarkable_discovery.dart';
import 'doctor/doctor.dart';
import 'errors.dart';
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
  factory PlutoCliEnvironment.defaults({
    Map<String, String>? processEnvironment,
  }) {
    final PlutoPaths paths = PlutoPaths.defaults();
    final Map<String, String> variables =
        processEnvironment ?? Platform.environment;
    final String strictValue = variables['PLUTO_ACCEPTANCE_STRICT_SSH'] ?? '0';
    final String allowTestHooks =
        variables['PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS'] ?? '0';
    final String? sshOverride = variables['PLUTO_ACCEPTANCE_SSH_BIN'];
    if (strictValue != '0' && strictValue != '1') {
      throw const CliConfigurationException(
        message: 'PLUTO_ACCEPTANCE_STRICT_SSH must be 0 or 1.',
      );
    }
    if (allowTestHooks != '0' && allowTestHooks != '1') {
      throw const CliConfigurationException(
        message: 'PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS must be 0 or 1.',
      );
    }
    final bool acceptanceStrict = strictValue == '1';
    String sshExecutable = acceptanceStrict ? '/usr/bin/ssh' : 'ssh';
    if (acceptanceStrict && sshOverride != null && sshOverride.isNotEmpty) {
      if (allowTestHooks != '1') {
        throw const CliConfigurationException(
          message:
              'PLUTO_ACCEPTANCE_SSH_BIN requires '
              'PLUTO_ACCEPTANCE_ALLOW_TEST_HOOKS=1.',
        );
      }
      final File overrideFile = File(sshOverride);
      if (!overrideFile.isAbsolute ||
          FileSystemEntity.typeSync(sshOverride, followLinks: false) !=
              FileSystemEntityType.file ||
          (FileStat.statSync(sshOverride).mode & 0x49) == 0) {
        throw const CliConfigurationException(
          message:
              'PLUTO_ACCEPTANCE_SSH_BIN must be an absolute executable '
              'regular file.',
        );
      }
      sshExecutable = sshOverride;
    }
    return PlutoCliEnvironment(
      paths: paths,
      hostEnvironment: const ProcessHostEnvironment(),
      transportFactory: (DeviceEndpoint endpoint) => DropbearTransport(
        endpoint: endpoint,
        sshExecutable: sshExecutable,
        acceptanceStrict: acceptanceStrict,
      ),
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
