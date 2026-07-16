import 'dart:convert';
import 'dart:io';

import 'package:pluto_manifest/pluto_manifest.dart';

import '../artifacts/checksums.dart';
import '../cli_environment.dart';
import '../config/paths.dart';
import '../config/pins.dart';
import '../errors.dart';
import '../process.dart';

/// Build mode for Pluto app outputs.
enum PlutoBuildMode {
  /// Debug/JIT bundle. This is the only mode that may contain a kernel blob.
  debug,

  /// Profile AOT build.
  profile,

  /// Release/product AOT build.
  release;

  /// CLI spelling used by Flutter and the Pluto install record.
  String get cliName => name;

  /// Engine artifact flavor for this build.
  String get engineFlavor => this == debug ? 'debug' : name;

  /// Whether this mode must produce an AOT ELF.
  bool get isAot => this != debug;
}

/// Linux device target used for engine selection and AOT snapshot validation.
enum PlutoTargetPlatform {
  /// 64-bit ARM Linux used by Paper Pro Move.
  linuxArm64('linux-arm64', 'arm64'),

  /// 32-bit ARM EABI5 hard-float Linux used by reMarkable 1 and 2.
  linuxArm('linux-arm', 'arm');

  const PlutoTargetPlatform(this.cliName, this.snapshotArchitecture);

  /// CLI and artifact-directory spelling.
  final String cliName;

  /// Architecture token embedded in Dart's snapshot feature marker.
  final String snapshotArchitecture;

  /// Parses a CLI/artifact target name.
  static PlutoTargetPlatform? fromCliName(String value) {
    for (final PlutoTargetPlatform target in values) {
      if (target.cliName == value) {
        return target;
      }
    }
    return null;
  }
}

/// Request for a Flutter build.
final class BuildRequest {
  /// Creates a build request.
  const BuildRequest({
    required this.projectDirectory,
    required this.targetFile,
    required this.mode,
    required this.outputDirectory,
    this.dartDefines = const <String>[],
    this.targetPlatform = PlutoTargetPlatform.linuxArm64,
  });

  /// Flutter project directory.
  final String projectDirectory;

  /// Dart entrypoint, relative to [projectDirectory] unless absolute.
  final String targetFile;

  /// Build mode.
  final PlutoBuildMode mode;

  /// Host output directory. The installable layout is written here.
  final String outputDirectory;

  /// `--dart-define` values.
  final List<String> dartDefines;

  /// Device architecture to build for.
  final PlutoTargetPlatform targetPlatform;
}

/// Output of a Flutter build.
final class BuildOutput {
  /// Creates a build output.
  const BuildOutput({required this.outputDirectory, required this.mode});

  /// Directory containing `manifest.json` and `bundle/`.
  final String outputDirectory;

  /// Build mode.
  final PlutoBuildMode mode;
}

/// Exact current metadata written beside `manifest.json` in every Pluto layout.
///
/// An AOT ELF alone cannot distinguish profile from release. Keeping the mode
/// in the layout lets later package and provision commands reject accidental
/// relabelling instead of guessing. This unpublished contract is replaced in
/// place: it has no schema, format, compatibility, or version discriminator.
final class BuildLayoutMetadata {
  /// Creates build-layout metadata.
  const BuildLayoutMetadata({
    required this.buildMode,
    required this.engineFlavor,
    required this.flutterVersion,
    required this.engineCommit,
    this.target = 'linux-arm64',
  });

  /// File name at the root of an installable build layout.
  static const String fileName = 'build-metadata.json';

  static const Set<String> _exactFields = <String>{
    'buildMode',
    'engineFlavor',
    'flutterVersion',
    'engineCommit',
    'target',
  };

  /// Build mode used to create the layout.
  final PlutoBuildMode buildMode;

  /// Exact on-device engine flavor required by this layout.
  final String engineFlavor;

  /// Flutter framework version used for the build.
  final String flutterVersion;

  /// Flutter engine revision used for the build.
  final String engineCommit;

  /// Target platform key.
  final String target;

  /// Creates metadata from the active repository pins.
  factory BuildLayoutMetadata.fromBuild({
    required PlutoBuildMode mode,
    required PlutoPins pins,
    PlutoTargetPlatform targetPlatform = PlutoTargetPlatform.linuxArm64,
  }) {
    return BuildLayoutMetadata(
      buildMode: mode,
      engineFlavor: mode.engineFlavor,
      flutterVersion: pins.flutterVersion,
      engineCommit: pins.engineVersion,
      target: targetPlatform.cliName,
    );
  }

  /// Reads and validates the metadata document in [layoutDirectory].
  factory BuildLayoutMetadata.read(String layoutDirectory) {
    final File file = File('$layoutDirectory/$fileName');
    if (!file.existsSync()) {
      throw ArtifactVerificationException(
        message: 'Build layout has no $fileName: $layoutDirectory',
        remediation:
            'Rebuild the layout with `pluto build app`, `pluto build '
            'bundle --debug`, or `pluto build package`.',
      );
    }
    return BuildLayoutMetadata.decodeBytes(file.readAsBytesSync());
  }

  /// Decodes and validates the one current metadata object from [bytes].
  factory BuildLayoutMetadata.decodeBytes(
    List<int> bytes, {
    String description = fileName,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException catch (error) {
      throw ArtifactVerificationException(
        message: '$description is not valid UTF-8 JSON: ${error.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw ArtifactVerificationException(
        message: '$description must be a JSON object.',
      );
    }
    if (decoded.keys.toSet().difference(_exactFields).isNotEmpty ||
        _exactFields.difference(decoded.keys.toSet()).isNotEmpty) {
      throw ArtifactVerificationException(
        message:
            '$description fields must be exactly '
            '${_exactFields.toList()..sort()}; format discriminators and '
            'unknown fields are not supported.',
      );
    }
    final Object? rawMode = decoded['buildMode'];
    final PlutoBuildMode? mode = PlutoBuildMode.values
        .where((PlutoBuildMode candidate) => candidate.cliName == rawMode)
        .firstOrNull;
    final Object? engineFlavor = decoded['engineFlavor'];
    final Object? flutterVersion = decoded['flutterVersion'];
    final Object? engineCommit = decoded['engineCommit'];
    final Object? target = decoded['target'];
    if (mode == null ||
        engineFlavor is! String ||
        engineFlavor.isEmpty ||
        flutterVersion is! String ||
        flutterVersion.isEmpty ||
        engineCommit is! String ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(engineCommit) ||
        target is! String ||
        PlutoTargetPlatform.fromCliName(target) == null) {
      throw ArtifactVerificationException(
        message:
            '$description has invalid build identity field types or values.',
      );
    }
    final BuildLayoutMetadata metadata = BuildLayoutMetadata(
      buildMode: mode,
      engineFlavor: engineFlavor,
      flutterVersion: flutterVersion,
      engineCommit: engineCommit,
      target: target,
    );
    metadata._validateIdentity(description);
    return metadata;
  }

  /// Encodes this identity as the one canonical metadata JSON document.
  String encode() {
    _validateIdentity(fileName);
    final Map<String, Object?> document = <String, Object?>{
      'buildMode': buildMode.cliName,
      'engineFlavor': engineFlavor,
      'flutterVersion': flutterVersion,
      'engineCommit': engineCommit,
      'target': target,
    };
    return '${const JsonEncoder.withIndent('  ').convert(document)}\n';
  }

  /// Writes this metadata to [layoutDirectory].
  void write(String layoutDirectory) {
    File('$layoutDirectory/$fileName').writeAsStringSync(encode());
  }

  /// Verifies mode, pin, manifest runtime, and payload shape as one unit.
  void validate(
    String layoutDirectory, {
    PlutoPins? pins,
    PlutoBuildMode? expectedMode,
    PlutoTargetPlatform? expectedTargetPlatform,
  }) {
    final PlutoTargetPlatform targetPlatform = _validateIdentity(fileName);
    if (expectedTargetPlatform != null &&
        targetPlatform != expectedTargetPlatform) {
      throw ArtifactVerificationException(
        message:
            'Build layout target is $target, not '
            '${expectedTargetPlatform.cliName}.',
      );
    }
    if (expectedMode != null && buildMode != expectedMode) {
      throw ArtifactVerificationException(
        message:
            'Build layout is ${buildMode.cliName}, not '
            '${expectedMode.cliName}.',
        remediation:
            'Use the matching mode flag or rebuild the requested layout.',
      );
    }
    if (pins != null &&
        (flutterVersion != pins.flutterVersion ||
            engineCommit != pins.engineVersion)) {
      throw ArtifactVerificationException(
        message:
            'Build layout pin $flutterVersion/$engineCommit does not match '
            '${pins.flutterVersion}/${pins.engineVersion}.',
        remediation: 'Rebuild with the pinned Flutter SDK in this checkout.',
      );
    }

    final File manifestFile = File('$layoutDirectory/manifest.json');
    _requireLayoutFile(manifestFile, 'manifest.json');
    final Result<AppManifest, ManifestError> manifestResult =
        AppManifest.decode(manifestFile.readAsStringSync());
    final AppManifest? manifest = manifestResult.valueOrNull;
    if (manifest == null) {
      throw ArtifactVerificationException(
        message:
            'Layout manifest.json is not canonical: '
            '${manifestResult.errorOrNull!.message}',
        remediation: 'Rebuild the layout from the current pluto.yaml format.',
      );
    }
    if (manifest.engine.flutterVersion != flutterVersion ||
        manifest.engine.engineCommit != engineCommit) {
      throw const ArtifactVerificationException(
        message: 'Layout manifest engine identity does not match metadata.',
      );
    }
    _requireDeclaredManifestAsset(
      layoutDirectory,
      manifest.icon,
      field: 'icon',
    );
    final String? iconMono = manifest.iconMono;
    if (iconMono != null) {
      _requireDeclaredManifestAsset(
        layoutDirectory,
        iconMono,
        field: 'iconMono',
      );
    }
    final AppRuntimeKind runtimeKind = manifest.runtime.kind;
    final bool hasAot = File('$layoutDirectory/bundle/lib/app.so').existsSync();
    final bool hasKernel = File(
      '$layoutDirectory/bundle/flutter_assets/kernel_blob.bin',
    ).existsSync();
    if (!Directory('$layoutDirectory/bundle/flutter_assets').existsSync()) {
      throw const ArtifactVerificationException(
        message: 'Build layout has no bundle/flutter_assets directory.',
      );
    }
    if (buildMode.isAot) {
      if (runtimeKind != AppRuntimeKind.flutterAot || !hasAot || hasKernel) {
        throw ArtifactVerificationException(
          message:
              '${buildMode.cliName} layout must use flutter-aot, contain '
              'app.so, and contain no kernel_blob.bin.',
        );
      }
      verifyAotElfForMode(
        '$layoutDirectory/bundle/lib/app.so',
        buildMode,
        targetPlatform: targetPlatform,
      );
    } else if (runtimeKind != AppRuntimeKind.flutterKernel ||
        !hasKernel ||
        hasAot) {
      throw const ArtifactVerificationException(
        message:
            'Debug layout must use flutter-kernel, contain kernel_blob.bin, '
            'and contain no app.so.',
      );
    }
  }

  PlutoTargetPlatform _validateIdentity(String description) {
    final PlutoTargetPlatform? targetPlatform = PlutoTargetPlatform.fromCliName(
      target,
    );
    if (engineFlavor != buildMode.engineFlavor ||
        engineFlavor.isEmpty ||
        flutterVersion.isEmpty ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(engineCommit) ||
        targetPlatform == null) {
      throw ArtifactVerificationException(
        message: '$description has invalid or contradictory build identity.',
      );
    }
    if (targetPlatform == PlutoTargetPlatform.linuxArm &&
        buildMode != PlutoBuildMode.release) {
      throw const ArtifactVerificationException(
        message: 'linux-arm build metadata is release-only.',
      );
    }
    return targetPlatform;
  }

  static void _requireLayoutFile(File file, String description) {
    if (!file.existsSync()) {
      throw ArtifactVerificationException(
        message: 'Build layout has no $description: ${file.path}',
      );
    }
  }

  static void _requireDeclaredManifestAsset(
    String layoutDirectory,
    String rawPath, {
    required String field,
  }) {
    if (!_isSafeRelativeLayoutPath(rawPath)) {
      throw ArtifactVerificationException(
        message: 'Layout manifest $field must be a safe relative path.',
        remediation: 'Rebuild the layout from a valid pluto.yaml.',
      );
    }
    final File asset = File('$layoutDirectory/$rawPath');
    if (FileSystemEntity.typeSync(asset.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw ArtifactVerificationException(
        message:
            'Build layout is missing a regular manifest-declared $field asset: '
            '$rawPath.',
        remediation:
            'Restore the declared asset inside the layout or rebuild it with '
            '`pluto build app`.',
      );
    }
  }

  static bool _isSafeRelativeLayoutPath(String value) {
    if (value.isEmpty ||
        value.startsWith('/') ||
        value.contains('\\') ||
        value.contains('\u0000')) {
      return false;
    }
    return value
        .split('/')
        .every(
          (String segment) =>
              segment.isNotEmpty && segment != '.' && segment != '..',
        );
  }
}

/// Thin adapter around the pinned Flutter toolchain.
abstract interface class FlutterBuildAdapter {
  /// Builds an app and returns its output.
  Future<BuildOutput> build(BuildRequest request);
}

/// Live build adapter for Pluto's generic Linux ARM embedders.
///
/// Flutter's normal `build bundle` target is used for assets. Profile and
/// release then compile an AOT kernel and run the hash/target-matched AArch64
/// host `gen_snapshot`. Non-AArch64 hosts execute that one step in Docker.
final class LiveFlutterToolsBuildAdapter implements FlutterBuildAdapter {
  /// Creates the live adapter.
  const LiveFlutterToolsBuildAdapter({
    required this.environment,
    this.flutterSdkOverride,
  });

  /// Shared CLI environment.
  final PlutoCliEnvironment environment;

  /// Explicit Flutter SDK root from `--flutter-sdk`.
  final String? flutterSdkOverride;

  @override
  Future<BuildOutput> build(BuildRequest request) async {
    if (request.targetPlatform == PlutoTargetPlatform.linuxArm &&
        request.mode != PlutoBuildMode.release) {
      throw const ArtifactVerificationException(
        message: 'linux-arm currently supports release AOT builds only.',
        remediation:
            'Use --release, or add exact-pin linux-arm profile/JIT artifacts '
            'before enabling those modes.',
      );
    }
    final PlutoPins pins = environment.pinsRepository.readPins();
    final String project = Directory(request.projectDirectory).absolute.path;
    final String output = _absoluteFrom(project, request.outputDirectory);
    final String target = _absoluteFrom(project, request.targetFile);
    final String sdk = _resolveFlutterSdk(pins);

    _requireFile('$project/pubspec.yaml', 'Flutter project pubspec.yaml');
    _requireFile(target, 'Dart entrypoint');
    _verifySdkPin(sdk, pins);

    final Directory outputDirectory = Directory(output);
    if (outputDirectory.existsSync()) {
      outputDirectory.deleteSync(recursive: true);
    }
    final String assets = '$output/bundle/flutter_assets';
    Directory(assets).createSync(recursive: true);

    // Validate authored metadata and declared icons before invoking Flutter or
    // gen_snapshot so a missing repository asset fails immediately.
    _writeManifest(
      project: project,
      output: output,
      mode: request.mode,
      pins: pins,
    );

    await _buildAssets(
      sdk: sdk,
      project: project,
      target: target,
      assets: assets,
      request: request,
    );

    final _AotArtifacts releaseArtifacts = _resolveAotArtifacts(
      pins,
      PlutoBuildMode.release,
      request.targetPlatform,
      requireSnapshotter: request.mode == PlutoBuildMode.release,
    );
    File(releaseArtifacts.icuData).copySync('$output/bundle/icudtl.dat');

    if (request.mode.isAot) {
      final _AotArtifacts artifacts = request.mode == PlutoBuildMode.release
          ? releaseArtifacts
          : _resolveAotArtifacts(
              pins,
              request.mode,
              request.targetPlatform,
              requireSnapshotter: true,
            );
      await _buildAot(
        sdk: sdk,
        project: project,
        target: target,
        output: output,
        request: request,
        artifacts: artifacts,
      );
      _removeJitPayload(assets);
    } else {
      _requireFile('$assets/kernel_blob.bin', 'debug kernel_blob.bin');
      final File accidentalAot = File('$output/bundle/lib/app.so');
      if (accidentalAot.existsSync()) {
        accidentalAot.deleteSync();
      }
    }

    final BuildLayoutMetadata metadata = BuildLayoutMetadata.fromBuild(
      mode: request.mode,
      pins: pins,
      targetPlatform: request.targetPlatform,
    );
    metadata.write(output);
    metadata.validate(output, pins: pins, expectedMode: request.mode);
    return BuildOutput(outputDirectory: output, mode: request.mode);
  }

  Future<void> _buildAssets({
    required String sdk,
    required String project,
    required String target,
    required String assets,
    required BuildRequest request,
  }) async {
    // Flutter Tools 3.44.4 has no linux-arm TargetPlatform. This bundle step
    // only produces assets; the standalone frontend/gen_snapshot path below
    // determines the actual AOT architecture. Native-assets users must wait
    // for upstream linux-arm support instead of treating this surrogate as a
    // 32-bit native-assets build.
    final String flutterBundleTarget =
        request.targetPlatform == PlutoTargetPlatform.linuxArm
        ? PlutoTargetPlatform.linuxArm64.cliName
        : request.targetPlatform.cliName;
    final List<String> command = <String>[
      '$sdk/bin/flutter',
      'build',
      'bundle',
      '--${request.mode.cliName}',
      '--target-platform=$flutterBundleTarget',
      '--target=$target',
      '--asset-dir=$assets',
      for (final String define in request.dartDefines) '--dart-define=$define',
    ];
    await _runChecked(
      command,
      workingDirectory: project,
      timeout: const Duration(minutes: 15),
      purpose: '${request.mode.cliName} Flutter asset build',
    );
  }

  Future<void> _buildAot({
    required String sdk,
    required String project,
    required String target,
    required String output,
    required BuildRequest request,
    required _AotArtifacts artifacts,
  }) async {
    final String intermediate = '$output/.intermediate';
    Directory(intermediate).createSync(recursive: true);
    final String packageConfig = _findPackageConfig(project);
    final bool product = request.mode == PlutoBuildMode.release;
    final String patchedSdk = product
        ? '$sdk/bin/cache/artifacts/engine/common/flutter_patched_sdk_product'
        : '$sdk/bin/cache/artifacts/engine/common/flutter_patched_sdk';
    final List<String> frontend = <String>[
      '$sdk/bin/cache/dart-sdk/bin/dartaotruntime',
      '$sdk/bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot',
      '--sdk-root',
      '$patchedSdk/',
      '--target=flutter',
      '--no-print-incremental-dependencies',
      for (final String define in request.dartDefines) '-D$define',
      '-Ddart.vm.profile=${request.mode == PlutoBuildMode.profile}',
      '-Ddart.vm.product=$product',
      '--delete-tostring-package-uri=dart:ui',
      '--delete-tostring-package-uri=package:flutter',
      '--aot',
      '--tfa',
      '--target-os',
      'linux',
      '--packages',
      packageConfig,
      '--output-dill',
      '$intermediate/app.dill',
      '--depfile',
      '$intermediate/kernel_snapshot_program.d',
      '--verbosity=error',
      target,
    ];
    await _runChecked(
      frontend,
      workingDirectory: project,
      timeout: const Duration(minutes: 10),
      purpose: '${request.mode.cliName} AOT kernel build',
    );
    _requireFile('$intermediate/app.dill', 'AOT kernel output');

    final String appSo = '$intermediate/app.so';
    final CommandResult uname = await environment.hostEnvironment.run(<String>[
      'uname',
      '-m',
    ]);
    final bool nativeArm64Linux =
        environment.hostEnvironment.operatingSystem == 'linux' &&
        <String>{
          'aarch64',
          'arm64',
        }.contains(uname.stdout.trim().toLowerCase());
    if (nativeArm64Linux) {
      await _runChecked(
        _genSnapshotArguments(
          executable: artifacts.genSnapshot,
          elf: appSo,
          dill: '$intermediate/app.dill',
        ),
        timeout: const Duration(minutes: 10),
        purpose: '${request.mode.cliName} gen_snapshot',
      );
    } else {
      final String? docker = environment.hostEnvironment.executablePath(
        'docker',
      );
      if (docker == null) {
        throw ArtifactVerificationException(
          message:
              '${request.mode.cliName} AOT needs Docker on this host because '
              'the pinned gen_snapshot is Linux/AArch64.',
          remediation:
              'Install/start Docker, or build on an AArch64 Linux host.',
        );
      }
      final String artifactDirectory = File(
        artifacts.genSnapshot,
      ).parent.absolute.path;
      await _runChecked(
        <String>[
          docker,
          'run',
          '--rm',
          '--platform',
          'linux/arm64',
          '-v',
          '$artifactDirectory:/artifacts:ro',
          '-v',
          '${Directory(intermediate).absolute.path}:/build',
          'ubuntu:24.04',
          '/artifacts/${File(artifacts.genSnapshot).uri.pathSegments.last}',
          '--deterministic',
          '--snapshot_kind=app-aot-elf',
          '--elf=/build/app.so',
          '--strip',
          '/build/app.dill',
        ],
        timeout: const Duration(minutes: 10),
        purpose: '${request.mode.cliName} gen_snapshot container',
      );
    }

    verifyAotElfForMode(
      appSo,
      request.mode,
      targetPlatform: request.targetPlatform,
    );
    final File destination = File('$output/bundle/lib/app.so');
    destination.parent.createSync(recursive: true);
    File(appSo).copySync(destination.path);
    Directory(intermediate).deleteSync(recursive: true);
  }

  List<String> _genSnapshotArguments({
    required String executable,
    required String elf,
    required String dill,
  }) => <String>[
    executable,
    '--deterministic',
    '--snapshot_kind=app-aot-elf',
    '--elf=$elf',
    '--strip',
    dill,
  ];

  Future<void> _runChecked(
    List<String> command, {
    required String purpose,
    String? workingDirectory,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final CommandResult result = await environment.hostEnvironment.run(
      command,
      timeout: timeout,
      workingDirectory: workingDirectory,
    );
    if (!result.isSuccess) {
      final String detail = result.stderr.trim().isNotEmpty
          ? result.stderr.trim()
          : result.stdout.trim();
      throw ArtifactVerificationException(
        message: '$purpose failed (exit ${result.exitCode}).',
        remediation: detail.isEmpty ? null : detail,
      );
    }
  }

  String _resolveFlutterSdk(PlutoPins pins) {
    final List<String> candidates = <String>[
      if (flutterSdkOverride != null)
        expandHome(flutterSdkOverride!, environment.paths.homeDirectory),
      '${environment.paths.homeDirectory}/.pluto/sdk/${pins.flutterVersion}',
    ];
    final String? flutter = environment.hostEnvironment.executablePath(
      'flutter',
    );
    if (flutter != null) {
      candidates.add(File(flutter).parent.parent.path);
    }
    for (final String candidate in candidates) {
      if (File('$candidate/bin/flutter').existsSync()) {
        return Directory(candidate).absolute.path;
      }
    }
    throw ArtifactVerificationException(
      message: 'Pinned Flutter SDK ${pins.flutterVersion} was not found.',
      remediation:
          'Install it at ~/.pluto/sdk/${pins.flutterVersion} or pass '
          '--flutter-sdk <path>.',
    );
  }

  void _verifySdkPin(String sdk, PlutoPins pins) {
    final File stamp = File('$sdk/bin/cache/engine.stamp');
    _requireFile(stamp.path, 'Flutter SDK engine stamp');
    final String actual = stamp.readAsStringSync().trim();
    if (actual != pins.engineVersion) {
      throw ArtifactVerificationException(
        message:
            'Flutter SDK engine $actual does not match the Pluto pin '
            '${pins.engineVersion}.',
        remediation: 'Use the pinned Flutter ${pins.flutterVersion} SDK.',
      );
    }
  }

  _AotArtifacts _resolveAotArtifacts(
    PlutoPins pins,
    PlutoBuildMode mode,
    PlutoTargetPlatform targetPlatform, {
    required bool requireSnapshotter,
  }) {
    final String flavor = mode.cliName;
    final String hash = pins.engineVersion;
    final String target = targetPlatform.cliName;
    final List<String> roots = <String>[
      '${environment.paths.repositoryRoot}/third_party/engine/$hash/'
          '$target-$flavor',
      '${environment.paths.repositoryRoot}/.pluto-cache/engine/$hash/'
          '$target-$flavor',
      '${environment.paths.engineCacheDirectory(hash)}/$target-$flavor',
    ];
    for (final String root in roots) {
      if (!Directory(root).existsSync()) {
        continue;
      }
      final String engine = '$root/libflutter_engine.so';
      final String snapshot = '$root/gen_snapshot';
      final String icu = '$root/icudtl.dat';
      if (File(engine).existsSync() &&
          File(icu).existsSync() &&
          (!requireSnapshotter || File(snapshot).existsSync())) {
        _verifyArtifactManifest(
          root: root,
          pins: pins,
          mode: mode,
          targetPlatform: targetPlatform,
          requireSnapshotter: requireSnapshotter,
        );
        return _AotArtifacts(
          engineLibrary: engine,
          genSnapshot: snapshot,
          icuData: icu,
        );
      }
      throw ArtifactVerificationException(
        message: 'Pinned artifact directory is incomplete: $root',
        remediation:
            'Restore it from version control or rebuild the exact pin.',
      );
    }
    throw ArtifactVerificationException(
      message: 'Missing hash-matched $target $flavor artifacts for $hash.',
      remediation: mode == PlutoBuildMode.profile
          ? 'Provide third_party/engine/$hash/$target-profile/{'
                'libflutter_engine.so,gen_snapshot,icudtl.dat}. Profile never '
                'falls back to JIT or release artifacts.'
          : targetPlatform == PlutoTargetPlatform.linuxArm64
          ? 'Run tools/engine/build-aarch64-aot.sh.'
          : 'Restore third_party/engine/$hash/linux-arm-release.',
    );
  }

  void _verifyArtifactManifest({
    required String root,
    required PlutoPins pins,
    required PlutoBuildMode mode,
    required PlutoTargetPlatform targetPlatform,
    required bool requireSnapshotter,
  }) {
    final File manifest = File('$root/CHECKSUMS.txt');
    _requireFile(manifest.path, 'artifact CHECKSUMS.txt');
    final Map<String, String> metadata = <String, String>{};
    final Map<String, String> digests = <String, String>{};
    for (final String line in const LineSplitter().convert(
      manifest.readAsStringSync(),
    )) {
      final RegExpMatch? digest = RegExp(
        r'^([0-9a-f]{64})  ([A-Za-z0-9._-]+)$',
      ).firstMatch(line);
      if (digest != null) {
        digests[digest.group(2)!] = digest.group(1)!;
        continue;
      }
      final int equals = line.indexOf('=');
      if (equals > 0) {
        metadata[line.substring(0, equals)] = line.substring(equals + 1);
      }
    }
    final Map<String, String> expectedMetadata = <String, String>{
      'schema': '1',
      'flutter': pins.flutterVersion,
      'engine': pins.engineVersion,
      'target': targetPlatform.cliName,
      'mode': mode.cliName,
    };
    for (final MapEntry<String, String> expected in expectedMetadata.entries) {
      if (metadata[expected.key] != expected.value) {
        throw ArtifactVerificationException(
          message:
              'Artifact metadata mismatch in ${manifest.path}: '
              '${expected.key}=${metadata[expected.key]} '
              '(expected ${expected.value}).',
          remediation: 'Restore the artifact for the pinned Flutter engine.',
        );
      }
    }
    for (final String name in <String>[
      'libflutter_engine.so',
      'icudtl.dat',
      if (requireSnapshotter) 'gen_snapshot',
    ]) {
      final String? expected = digests[name];
      final File file = File('$root/$name');
      if (expected == null || !file.existsSync()) {
        throw ArtifactVerificationException(
          message: 'CHECKSUMS.txt does not cover required artifact $name.',
        );
      }
      final String actual = sha256Bytes(file.readAsBytesSync());
      if (actual != expected) {
        throw ArtifactVerificationException(
          message: 'Artifact checksum mismatch: ${file.path}',
          remediation:
              'Restore it from version control; do not use this build.',
        );
      }
    }
  }

  void _writeManifest({
    required String project,
    required String output,
    required PlutoBuildMode mode,
    required PlutoPins pins,
  }) {
    final File authored = File('$project/pluto.yaml');
    _requireFile(authored.path, 'pluto.yaml');
    final Result<AppManifest, ManifestError> decoded =
        AppManifest.decodeAuthoredYaml(
          authored.readAsStringSync(),
          runtime: mode.isAot
              ? const FlutterAotRuntime(
                  appElf: 'lib/app.so',
                  assets: 'flutter_assets',
                )
              : const FlutterKernelRuntime(assets: 'flutter_assets'),
          engine: EngineRequirement(
            flutterVersion: pins.flutterVersion,
            engineCommit: pins.engineVersion,
          ),
        );
    final AppManifest? manifest = decoded.valueOrNull;
    if (manifest == null) {
      throw ArtifactVerificationException(
        message: 'pluto.yaml is invalid: ${decoded.errorOrNull!.message}',
        remediation: 'Fix the authored app manifest and rebuild.',
      );
    }
    File('$output/manifest.json').writeAsStringSync('${manifest.encode()}\n');
    for (final String icon in <String>[
      manifest.icon,
      if (manifest.iconMono != null) manifest.iconMono!,
    ]) {
      final File source = File('$project/$icon');
      if (!source.existsSync()) {
        throw ArtifactVerificationException(
          message: 'Manifest asset does not exist: ${source.path}.',
          remediation:
              'Add the declared icon to the app or correct its path in '
              'pluto.yaml.',
        );
      }
      final File destination = File('$output/$icon');
      destination.parent.createSync(recursive: true);
      source.copySync(destination.path);
    }
  }

  String _findPackageConfig(String project) {
    Directory current = Directory(project);
    while (true) {
      final File candidate = File(
        '${current.path}/.dart_tool/package_config.json',
      );
      if (candidate.existsSync()) {
        return candidate.path;
      }
      final Directory parent = current.parent;
      if (parent.path == current.path) {
        break;
      }
      current = parent;
    }
    throw const ArtifactVerificationException(
      message: 'Flutter did not produce .dart_tool/package_config.json.',
      remediation: 'Run `flutter pub get` in the app and retry.',
    );
  }

  void _removeJitPayload(String assets) {
    for (final String name in <String>[
      '.last_build_id',
      'kernel_blob.bin',
      'vm_snapshot_data',
      'isolate_snapshot_data',
    ]) {
      final File file = File('$assets/$name');
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
  }

  void _requireFile(String path, String description) {
    if (!File(path).existsSync()) {
      throw ArtifactVerificationException(
        message: 'Missing $description: $path',
      );
    }
  }
}

/// Verifies that [path] matches [targetPlatform] and [mode]'s exact Dart
/// snapshot feature set.
///
/// Both profile and release use `app.so`, so checking only its presence can
/// silently pair a copied layout with the wrong engine. Dart embeds a
/// NUL-terminated snapshot feature string prefixed by a 32-hex snapshot hash;
/// use that bounded marker rather than unrelated words from application data.
void verifyAotElfForMode(
  String path,
  PlutoBuildMode mode, {
  PlutoTargetPlatform targetPlatform = PlutoTargetPlatform.linuxArm64,
}) {
  if (!mode.isAot) {
    throw ArgumentError.value(mode, 'mode', 'Debug does not use an AOT ELF');
  }
  final File file = File(path);
  if (!file.existsSync()) {
    throw ArtifactVerificationException(message: 'Missing AOT app.so: $path');
  }
  verifyAotElfBytesForMode(
    file.readAsBytesSync(),
    mode,
    description: path,
    targetPlatform: targetPlatform,
  );
}

/// Byte-oriented form of [verifyAotElfForMode] for package validation.
void verifyAotElfBytesForMode(
  List<int> bytes,
  PlutoBuildMode mode, {
  String description = 'AOT app.so',
  PlutoTargetPlatform targetPlatform = PlutoTargetPlatform.linuxArm64,
}) {
  if (!mode.isAot) {
    throw ArgumentError.value(mode, 'mode', 'Debug does not use an AOT ELF');
  }
  final bool elfMagic =
      bytes.length > 40 &&
      bytes[0] == 0x7f &&
      bytes[1] == 0x45 &&
      bytes[2] == 0x4c &&
      bytes[3] == 0x46 &&
      bytes[5] == 1;
  final int machine = elfMagic ? bytes[18] | (bytes[19] << 8) : -1;
  final int flags = elfMagic
      ? bytes[36] | (bytes[37] << 8) | (bytes[38] << 16) | (bytes[39] << 24)
      : 0;
  final bool matchesTarget =
      elfMagic &&
      switch (targetPlatform) {
        PlutoTargetPlatform.linuxArm64 => bytes[4] == 2 && machine == 183,
        PlutoTargetPlatform.linuxArm =>
          bytes[4] == 1 &&
              machine == 40 &&
              ((flags >> 24) & 0xff) == 5 &&
              (flags & 0x400) != 0 &&
              (flags & 0x200) == 0,
      };
  if (!elfMagic || !matchesTarget) {
    throw ArtifactVerificationException(
      message:
          'AOT app.so does not match ${targetPlatform.cliName} '
          '${targetPlatform == PlutoTargetPlatform.linuxArm ? '(ELF32 EM_ARM EABI5 hard-float)' : '(ELF64 EM_AARCH64)'}.',
      remediation:
          'Check that the pinned ${targetPlatform.cliName} artifact was used.',
    );
  }
  final String contents = latin1.decode(bytes, allowInvalid: true);
  final String architecture = targetPlatform.snapshotArchitecture;
  final List<RegExpMatch> featureMatches = RegExp(
    '[0-9a-f]{32}(product|release)[^\\x00\\r\\n]{0,512}'
    '${RegExp.escape(architecture)} linux',
  ).allMatches(contents).toList(growable: false);
  final String expectedRuntime = mode == PlutoBuildMode.release
      ? 'product'
      : 'release';
  final String expectedDedup = mode == PlutoBuildMode.release
      ? 'dedup_instructions'
      : 'no-dedup_instructions';
  final bool matchesMode = featureMatches.any((RegExpMatch match) {
    final String marker = match.group(0)!;
    final bool dedupMatches = mode == PlutoBuildMode.release
        ? marker.contains(' dedup_instructions ') &&
              !marker.contains(' no-dedup_instructions ')
        : marker.contains(' no-dedup_instructions ');
    return match.group(1) == expectedRuntime && dedupMatches;
  });
  if (!matchesMode) {
    throw ArtifactVerificationException(
      message:
          '$description (${mode.cliName}) does not have the expected '
          '$expectedRuntime/$expectedDedup AOT feature marker.',
      remediation:
          'Rebuild it with the pinned ${mode.cliName} gen_snapshot; do not '
          'edit or copy build-metadata.json between layouts.',
    );
  }
}

/// Host-only build planner used by `--no-live` tests and dry runs.
final class NoLiveBuildAdapter implements FlutterBuildAdapter {
  /// Creates a no-live adapter.
  const NoLiveBuildAdapter();

  @override
  Future<BuildOutput> build(BuildRequest request) async {
    return BuildOutput(
      outputDirectory: request.outputDirectory,
      mode: request.mode,
    );
  }
}

final class _AotArtifacts {
  const _AotArtifacts({
    required this.engineLibrary,
    required this.genSnapshot,
    required this.icuData,
  });

  final String engineLibrary;
  final String genSnapshot;
  final String icuData;
}

String _absoluteFrom(String base, String path) {
  if (File(path).isAbsolute) {
    return path;
  }
  return File('$base/$path').absolute.path;
}
