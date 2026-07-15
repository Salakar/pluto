import 'dart:io';

import '../build/package_builder.dart';
import '../build/release_pipeline.dart';
import '../config/pins.dart';
import '../exit_codes.dart';
import '../run/device_operations.dart';
import 'base_command.dart';

mixin _DeviceAwareBuildTarget on PlutoCommand {
  Future<PlutoTargetPlatform> resolveBuildTargetPlatform() async {
    final String? rawExplicit = argResults!.options.contains('target-platform')
        ? argResults!['target-platform'] as String?
        : null;
    final PlutoTargetPlatform? explicit = rawExplicit == null
        ? null
        : PlutoTargetPlatform.fromCliName(rawExplicit);
    final String? requestedDevice = resolveDeviceTarget();
    if (requestedDevice == null) {
      return explicit ?? PlutoTargetPlatform.linuxArm64;
    }
    final endpoint = endpointFromTarget(requestedDevice);
    if (endpoint == null) {
      usageException('Invalid --device value: $requestedDevice.');
    }
    final String target = await LiveDeviceOperations(
      environment.transportFactory(endpoint),
    ).runtimeTarget();
    final PlutoTargetPlatform? detected = PlutoTargetPlatform.fromCliName(
      target,
    );
    if (detected == null) {
      usageException('Connected device selected unsupported target $target.');
    }
    if (explicit != null && explicit != detected) {
      usageException(
        '--target-platform ${explicit.cliName} does not match the connected '
        'device (expected ${detected.cliName}). Omit the advanced override '
        'to select automatically.',
      );
    }
    return detected;
  }

  String defaultLayoutOutput(PlutoBuildMode mode, PlutoTargetPlatform target) =>
      target == PlutoTargetPlatform.linuxArm
      ? 'build/pluto/${mode.cliName}-arm'
      : 'build/pluto/${mode.cliName}';
}

/// `pluto build` command group.
final class BuildCommand extends PlutoCommand {
  /// Creates the command group.
  BuildCommand(super.environment) {
    addSubcommand(BuildBundleCommand(environment));
    addSubcommand(BuildAppCommand(environment));
    addSubcommand(BuildPackageCommand(environment));
  }

  @override
  String get name => 'build';

  @override
  String get description => 'Build Pluto bundles, AOT apps, and packages.';
}

/// `pluto build bundle`.
final class BuildBundleCommand extends PlutoCommand
    with _DeviceAwareBuildTarget {
  /// Creates the command.
  BuildBundleCommand(super.environment) {
    addDeviceOption();
    argParser
      ..addFlag(
        'debug',
        negatable: false,
        help:
            'Explicitly build a debug/JIT flutter_assets bundle for hot '
            'reload.',
      )
      ..addFlag(
        'no-live',
        negatable: false,
        help: 'Plan the build without invoking flutter_tools.',
      )
      ..addOption(
        'target',
        abbr: 't',
        defaultsTo: 'lib/main.dart',
        help: 'Dart entrypoint.',
      )
      ..addOption(
        'output',
        abbr: 'o',
        defaultsTo: 'build/pluto/debug',
        help: 'Output directory.',
      )
      ..addMultiOption(
        'dart-define',
        help: 'Additional Dart defines in K=V form.',
      );
  }

  @override
  String get name => 'bundle';

  @override
  String get description => 'Build a debug asset bundle.';

  @override
  Future<int> run() async {
    return guard(() async {
      if (!(argResults!['debug'] as bool)) {
        usageException(
          '`pluto build bundle` is debug/JIT-only; pass --debug explicitly '
          'for a hot-reload bundle. Use `pluto build app` for release AOT.',
        );
      }
      if (await resolveBuildTargetPlatform() !=
          PlutoTargetPlatform.linuxArm64) {
        usageException(
          'This device uses release AOT builds. Run `pluto build package '
          '--release --device <device>`.',
        );
      }
      final FlutterBuildAdapter adapter = (argResults!['no-live'] as bool)
          ? const NoLiveBuildAdapter()
          : LiveFlutterToolsBuildAdapter(
              environment: environment,
              flutterSdkOverride: globalFlutterSdk,
            );
      final BuildOutput output = await adapter.build(
        BuildRequest(
          projectDirectory: Directory.current.path,
          targetFile: argResults!['target'] as String,
          mode: PlutoBuildMode.debug,
          outputDirectory: argResults!['output'] as String,
          dartDefines: argResults!['dart-define'] as List<String>,
        ),
      );
      environment.out.writeln('Bundle output: ${output.outputDirectory}');
      return ExitCodes.ok;
    });
  }
}

/// `pluto build app`.
final class BuildAppCommand extends PlutoCommand with _DeviceAwareBuildTarget {
  /// Creates the command.
  BuildAppCommand(super.environment) {
    addDeviceOption();
    argParser
      ..addFlag(
        'release',
        negatable: false,
        help: 'Build a release AOT app.so (the default).',
      )
      ..addFlag(
        'profile',
        negatable: false,
        help: 'Build a profile AOT app.so.',
      )
      ..addFlag(
        'no-live',
        negatable: false,
        help: 'Plan the build without invoking flutter_tools.',
      )
      ..addOption(
        'target',
        abbr: 't',
        defaultsTo: 'lib/main.dart',
        help: 'Dart entrypoint.',
      )
      ..addOption(
        'output',
        abbr: 'o',
        help: 'Output directory. Defaults to build/pluto/<mode>.',
      )
      ..addOption(
        'target-platform',
        allowed: PlutoTargetPlatform.values
            .map((PlutoTargetPlatform target) => target.cliName)
            .toList(growable: false),
        help:
            'Advanced architecture override. With --device, the matching '
            'target is selected automatically.',
      )
      ..addMultiOption(
        'dart-define',
        help: 'Additional Dart defines in K=V form.',
      );
  }

  @override
  String get name => 'app';

  @override
  String get description => 'Build an AOT app.so and assets layout.';

  @override
  Future<int> run() async {
    return guard(() async {
      final FlutterBuildAdapter adapter = (argResults!['no-live'] as bool)
          ? const NoLiveBuildAdapter()
          : LiveFlutterToolsBuildAdapter(
              environment: environment,
              flutterSdkOverride: globalFlutterSdk,
            );
      if ((argResults!['profile'] as bool) &&
          (argResults!['release'] as bool)) {
        usageException('Choose only one of --profile or --release.');
      }
      final PlutoBuildMode mode = (argResults!['profile'] as bool)
          ? PlutoBuildMode.profile
          : PlutoBuildMode.release;
      final PlutoTargetPlatform targetPlatform =
          await resolveBuildTargetPlatform();
      final String outputDirectory =
          (argResults!['output'] as String?) ??
          defaultLayoutOutput(mode, targetPlatform);
      final BuildOutput output = await adapter.build(
        BuildRequest(
          projectDirectory: Directory.current.path,
          targetFile: argResults!['target'] as String,
          mode: mode,
          outputDirectory: outputDirectory,
          dartDefines: argResults!['dart-define'] as List<String>,
          targetPlatform: targetPlatform,
        ),
      );
      environment.out.writeln('App output: ${output.outputDirectory}');
      return ExitCodes.ok;
    });
  }
}

/// `pluto build package`.
final class BuildPackageCommand extends PlutoCommand
    with _DeviceAwareBuildTarget {
  /// Creates the command.
  BuildPackageCommand(super.environment) {
    addDeviceOption();
    argParser
      ..addFlag(
        'debug',
        negatable: false,
        help:
            'Build and package a debug/JIT app for an explicit hot-reload '
            'session.',
      )
      ..addFlag(
        'release',
        negatable: false,
        help: 'Build and package a release AOT app (the default).',
      )
      ..addFlag(
        'profile',
        negatable: false,
        help: 'Build and package a profile AOT app.',
      )
      ..addFlag(
        'published',
        negatable: false,
        help:
            'Emit one release package containing both linux-arm and '
            'linux-arm64 slices. With --from-layout, the directory must '
            'contain those two target-named layouts.',
      )
      ..addFlag(
        'no-live',
        negatable: false,
        help: 'Do not invoke flutter_tools; package --from-layout directly.',
      )
      ..addOption(
        'from-layout',
        help:
            'Existing layout containing build-metadata.json, manifest.json, '
            'and bundle/. With --published, a parent containing '
            'linux-arm/ and linux-arm64/.',
      )
      ..addOption(
        'target',
        abbr: 't',
        defaultsTo: 'lib/main.dart',
        help: 'Dart entrypoint used for a live build.',
      )
      ..addOption(
        'layout-output',
        help:
            'Intermediate installable layout for a live build. Defaults to '
            'build/pluto/<mode>.',
      )
      ..addOption(
        'target-platform',
        allowed: PlutoTargetPlatform.values
            .map((PlutoTargetPlatform target) => target.cliName)
            .toList(growable: false),
        help:
            'Advanced architecture override. With --device, the matching '
            'target is selected automatically.',
      )
      ..addMultiOption(
        'dart-define',
        help: 'Additional Dart defines in K=V form.',
      )
      ..addOption(
        'output',
        abbr: 'o',
        defaultsTo: 'build/pluto/app.plap',
        help: 'Output .plap path.',
      )
      ..addOption(
        'compression',
        allowed: <String>['zstd', 'none'],
        defaultsTo: 'zstd',
        help: 'Package compression. `none` is intended for tests.',
      );
  }

  @override
  String get name => 'package';

  @override
  String get description =>
      'Build and create an installable .plap package (release AOT by default).';

  @override
  Future<int> run() async {
    return guard(() async {
      String? source = argResults!['from-layout'] as String?;
      final bool debug = argResults!['debug'] as bool;
      final bool profile = argResults!['profile'] as bool;
      final bool release = argResults!['release'] as bool;
      if (<bool>[
            debug,
            profile,
            release,
          ].where((bool selected) => selected).length >
          1) {
        usageException('Choose only one of --debug, --profile, or --release.');
      }
      final PlutoBuildMode? requestedMode = debug
          ? PlutoBuildMode.debug
          : profile
          ? PlutoBuildMode.profile
          : release
          ? PlutoBuildMode.release
          : null;
      final PlutoBuildMode effectiveMode =
          requestedMode ?? PlutoBuildMode.release;
      final bool published = argResults!['published'] as bool;
      if (published && effectiveMode != PlutoBuildMode.release) {
        usageException('Published dual-slice packages are release AOT only.');
      }
      if (published &&
          (resolveDeviceTarget() != null ||
              argResults!.wasParsed('target-platform'))) {
        usageException(
          '--published already builds both targets; do not pass --device or '
          '--target-platform.',
        );
      }
      final PlutoPins pins = environment.pinsRepository.readPins();
      final ByteCompressor compressor =
          (argResults!['compression'] as String) == 'none'
          ? const NoopCompressor()
          : const ExternalZstdCompressor();
      final PlapPackage package;
      if (published) {
        source = await _resolvePublishedLayouts(
          source: source,
          mode: effectiveMode,
        );
        final List<PackageSliceSource> slices = <PackageSliceSource>[];
        for (final PlutoTargetPlatform target in const <PlutoTargetPlatform>[
          PlutoTargetPlatform.linuxArm,
          PlutoTargetPlatform.linuxArm64,
        ]) {
          final String layout = '$source/${target.cliName}';
          if (FileSystemEntity.typeSync(layout, followLinks: false) !=
              FileSystemEntityType.directory) {
            usageException(
              'Published package is missing the ${target.cliName} layout: '
              '$layout.',
            );
          }
          final BuildLayoutMetadata metadata = BuildLayoutMetadata.read(layout);
          metadata.validate(
            layout,
            pins: pins,
            expectedMode: PlutoBuildMode.release,
            expectedTargetPlatform: target,
          );
          slices.add(
            PackageSliceSource(
              source: DirectoryPackageSource(layout),
              metadata: PackageMetadata(
                flutterVersion: pins.flutterVersion,
                engineCommit: pins.engineVersion,
                plutoVersion: '0.1.0',
                buildMode: metadata.buildMode.cliName,
                engineFlavor: metadata.engineFlavor,
                target: metadata.target,
              ),
            ),
          );
        }
        package = await PlapPackageBuilder(
          compressor: compressor,
        ).buildSlices(slices: slices);
      } else {
        final PlutoTargetPlatform targetPlatform =
            await resolveBuildTargetPlatform();
        if (source == null) {
          if (argResults!['no-live'] as bool) {
            usageException('--from-layout is required with --no-live.');
          }
          final String layoutOutput =
              (argResults!['layout-output'] as String?) ??
              defaultLayoutOutput(effectiveMode, targetPlatform);
          final BuildOutput build =
              await LiveFlutterToolsBuildAdapter(
                environment: environment,
                flutterSdkOverride: globalFlutterSdk,
              ).build(
                BuildRequest(
                  projectDirectory: Directory.current.path,
                  targetFile: argResults!['target'] as String,
                  mode: effectiveMode,
                  outputDirectory: layoutOutput,
                  dartDefines: argResults!['dart-define'] as List<String>,
                  targetPlatform: targetPlatform,
                ),
              );
          source = build.outputDirectory;
        }
        final BuildLayoutMetadata layoutMetadata = BuildLayoutMetadata.read(
          source,
        );
        layoutMetadata.validate(
          source,
          pins: pins,
          expectedMode: effectiveMode,
          expectedTargetPlatform:
              argResults!.wasParsed('target-platform') ||
                  resolveDeviceTarget() != null
              ? targetPlatform
              : null,
        );
        package = await PlapPackageBuilder(compressor: compressor).build(
          source: DirectoryPackageSource(source),
          metadata: PackageMetadata(
            flutterVersion: pins.flutterVersion,
            engineCommit: pins.engineVersion,
            plutoVersion: '0.1.0',
            buildMode: layoutMetadata.buildMode.cliName,
            engineFlavor: layoutMetadata.engineFlavor,
            target: layoutMetadata.target,
          ),
        );
      }
      final File output = File(argResults!['output'] as String);
      await output.parent.create(recursive: true);
      await output.writeAsBytes(package.bytes);
      environment.out.writeln(
        'Wrote ${output.path} (${package.bytes.length} bytes, '
        '${compressor.name}).',
      );
      return ExitCodes.ok;
    });
  }

  Future<String> _resolvePublishedLayouts({
    required String? source,
    required PlutoBuildMode mode,
  }) async {
    if (source != null) {
      return source;
    }
    if (argResults!['no-live'] as bool) {
      usageException('--from-layout is required with --no-live.');
    }
    final String root =
        (argResults!['layout-output'] as String?) ??
        'build/pluto/published-release';
    final LiveFlutterToolsBuildAdapter adapter = LiveFlutterToolsBuildAdapter(
      environment: environment,
      flutterSdkOverride: globalFlutterSdk,
    );
    for (final PlutoTargetPlatform target in const <PlutoTargetPlatform>[
      PlutoTargetPlatform.linuxArm,
      PlutoTargetPlatform.linuxArm64,
    ]) {
      await adapter.build(
        BuildRequest(
          projectDirectory: Directory.current.path,
          targetFile: argResults!['target'] as String,
          mode: mode,
          outputDirectory: '$root/${target.cliName}',
          dartDefines: argResults!['dart-define'] as List<String>,
          targetPlatform: target,
        ),
      );
    }
    return root;
  }
}
