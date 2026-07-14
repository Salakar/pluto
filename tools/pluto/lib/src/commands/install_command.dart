import 'dart:io';

import '../build/plap_reader.dart';
import '../build/release_pipeline.dart';
import '../config/pins.dart';
import '../errors.dart';
import '../exit_codes.dart';
import '../run/device_operations.dart';
import '../ssh/device_transport.dart';
import 'base_command.dart';

/// `pluto install` command.
final class InstallCommand extends PlutoCommand {
  /// Creates the command.
  InstallCommand(super.environment) {
    addDeviceOption();
    argParser
      ..addFlag(
        'debug',
        negatable: false,
        help:
            'Install an explicitly built debug/JIT package for a hot-reload '
            'session.',
      )
      ..addFlag(
        'profile',
        negatable: false,
        help: 'Install an AOT profile package.',
      )
      ..addFlag(
        'release',
        negatable: false,
        help: 'Install an AOT release package (the default).',
      )
      ..addFlag(
        'from-build',
        negatable: false,
        help: 'Install the latest build/pluto package.',
      )
      ..addFlag(
        'launch',
        negatable: false,
        help:
            'Launch an AOT app after installing. Debug installs must be '
            'started separately with `pluto run --debug`.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Replace an existing app without prompting.',
      )
      ..addFlag(
        'set-default',
        negatable: false,
        help:
            'Make the installed app the one the supervisor boots into '
            '(instead of the launcher).',
      )
      ..addFlag(
        'validate-only',
        negatable: false,
        help: 'Validate host-side arguments and package existence only.',
      );
  }

  /// Default package location, matching `pluto build package -o` default.
  static String defaultPackagePath(String repoRoot) =>
      '$repoRoot/build/pluto/app.plap';

  @override
  String get name => 'install';

  @override
  String get description =>
      'Install a .plap package (release AOT by default) on a provisioned device.';

  @override
  Future<int> run() async {
    return guard(() async {
      final PlutoBuildMode expectedMode = _validateMode();
      if (expectedMode == PlutoBuildMode.debug &&
          (argResults!['launch'] as bool)) {
        usageException(
          '`install --debug --launch` cannot establish a hot-reload session. '
          'Install with --debug, then run `pluto run --debug <app-id>`.',
        );
      }
      if (expectedMode == PlutoBuildMode.debug &&
          (argResults!['set-default'] as bool)) {
        usageException(
          'A debug/JIT app cannot be the boot default. Install it without '
          '--set-default, then use `pluto run --debug <app-id>`.',
        );
      }
      final List<String> rest = argResults!.rest;
      final bool fromBuild = argResults!['from-build'] as bool;
      if (rest.isEmpty && !fromBuild) {
        usageException('Provide <path.plap> or --from-build.');
      }
      if (rest.isNotEmpty && fromBuild) {
        usageException('Use either <path.plap> or --from-build, not both.');
      }
      final String? path = rest.isEmpty ? null : rest.single;
      if (path != null && !File(path).existsSync()) {
        usageException('Package not found: $path');
      }
      if (argResults!['validate-only'] as bool) {
        environment.out.writeln('Install request is host-valid.');
        return ExitCodes.ok;
      }
      final String packagePath =
          path ?? defaultPackagePath(environment.paths.packageRoot);
      if (!File(packagePath).existsSync()) {
        usageException(
          'Package not found: $packagePath '
          '(build it first: `pluto build package`).',
        );
      }
      final PlapArchive archive = await PlapArchive.read(packagePath);
      if (archive.buildMode != expectedMode.cliName) {
        throw ArtifactVerificationException(
          message:
              'Package is ${archive.buildMode}, not '
              '${expectedMode.cliName}.',
          remediation: archive.buildMode == PlutoBuildMode.debug.cliName
              ? 'Pass --debug only for an explicit JIT/hot-reload session.'
              : 'Pass --${archive.buildMode} explicitly, or install a release '
                    'AOT package.',
        );
      }
      final DeviceEndpoint? endpoint = endpointFromTarget(
        resolveDeviceTarget(),
      );
      if (endpoint == null) {
        usageException('No device: pass --device <user@host> or connect USB.');
      }
      final LiveDeviceOperations ops = LiveDeviceOperations(
        environment.transportFactory(endpoint),
      );
      final PlutoPins pins = environment.pinsRepository.readPins();
      final DeviceOperationResult result = await ops.installPackage(
        packagePath,
        force: argResults!['force'] as bool,
        launch: argResults!['launch'] as bool,
        setDefault: argResults!['set-default'] as bool,
        expectedFlutterVersion: pins.flutterVersion,
        expectedEngineCommit: pins.engineVersion,
      );
      environment.out.writeln(result.message);
      return result.ok ? ExitCodes.ok : ExitCodes.failure;
    });
  }

  PlutoBuildMode _validateMode() {
    final bool debug = argResults!['debug'] as bool;
    final bool profile = argResults!['profile'] as bool;
    final bool release = argResults!['release'] as bool;
    if (<bool>[debug, profile, release].where((bool value) => value).length >
        1) {
      usageException('Choose only one of --debug, --profile, or --release.');
    }
    return debug
        ? PlutoBuildMode.debug
        : profile
        ? PlutoBuildMode.profile
        : PlutoBuildMode.release;
  }
}
